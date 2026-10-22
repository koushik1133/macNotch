import Foundation

/// Apple silicon temperature sensors published through the IOHIDEventSystem
/// (the "PMU tdie", "pACC MTR", "NAND CH0 temp", "gas gauge battery"
/// services). The same idea Stats uses; the functions are IOKit SPI, so they
/// are looked up at run time and everything degrades to "no sensors" when a
/// symbol is missing. Reading needs no permission and no root.
///
/// Not thread safe: use from one queue (`FanSensorSampler` owns it).
final class FanHIDTemperatures: @unchecked Sendable {
    struct Reading: Sendable, Equatable {
        let name: String
        let celsius: Double
    }

    private typealias CreateClient = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloat = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private let copyServices: CopyServices?
    private let copyProperty: CopyProperty?
    private let copyEvent: CopyEvent?
    private let getFloat: GetFloat?
    private var client: UnsafeMutableRawPointer?
    /// Services and their names, fetched once (they do not change while running).
    private var services: [(service: AnyObject, pointer: UnsafeMutableRawPointer, name: String)]?

    /// kIOHIDEventTypeTemperature and its level field.
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func symbol<T>(_ name: String, as: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        let create = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self)
        let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self)
        copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self)
        copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self)
        copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
        getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloat.self)
        guard let create, let setMatching, let client = create(kCFAllocatorDefault) else { return }
        // Vendor page 0xff00, usage 5: the temperature sensors.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        self.client = client
    }

    deinit {
        if let client { Unmanaged<AnyObject>.fromOpaque(client).release() }
    }

    var isAvailable: Bool { client != nil && copyEvent != nil && getFloat != nil }

    private func loadServices() -> [(service: AnyObject, pointer: UnsafeMutableRawPointer, name: String)] {
        if let services { return services }
        var found: [(AnyObject, UnsafeMutableRawPointer, String)] = []
        if let client, let copyServices, let copyProperty, let raw = copyServices(client) {
            let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
            for i in 0..<CFArrayGetCount(array) {
                guard let value = CFArrayGetValueAtIndex(array, i) else { continue }
                let pointer = UnsafeMutableRawPointer(mutating: value)
                let service = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                guard let nameRaw = copyProperty(pointer, "Product" as CFString) else { continue }
                let name = Unmanaged<AnyObject>.fromOpaque(nameRaw).takeRetainedValue() as? String
                guard let name, !name.isEmpty else { continue }
                found.append((service, pointer, name))
            }
        }
        services = found
        return found
    }

    /// One reading per service; implausible values (sensor off, -1, 0) are skipped.
    func read() -> [Reading] {
        guard let copyEvent, let getFloat else { return [] }
        var out: [Reading] = []
        for entry in loadServices() {
            guard let event = copyEvent(entry.pointer, Self.temperatureEvent, 0, 0) else { continue }
            let value = getFloat(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            withExtendedLifetime(entry.service) {}
            guard FanSensorCatalog.isPlausible(value) else { continue }
            out.append(Reading(name: entry.name, celsius: value))
        }
        return out
    }
}
