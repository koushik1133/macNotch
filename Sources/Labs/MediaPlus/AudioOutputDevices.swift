import AppKit
import CoreAudio
import IOBluetooth

// Sound output switching: lists what can play sound (speakers, headphones,
// displays, AirPlay receivers, paired Bluetooth headphones that aren't
// connected yet) and makes one the default output. Core Audio work runs on a
// private serial queue (the first HAL call can take 100+ ms); listeners for
// hot-plug and default-device changes keep the list current without polling.

/// Something the picker can switch to.
struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A Core Audio output device.
        case device(AudioObjectID)
        /// One receiver behind macOS's AirPlay device (a data source).
        case airPlay(device: AudioObjectID, source: UInt32)
        /// Paired Bluetooth headphones that aren't connected (selecting them
        /// connects first).
        case bluetooth(address: String)
    }

    let id: String
    let kind: Kind
    let name: String
    let transport: HUDOutputTransport
    var isCurrent: Bool

    var symbol: String { transport.symbol(deviceName: name) }

    var subtitle: String? {
        switch kind {
        case .bluetooth: "Not connected"
        case .airPlay: "AirPlay"
        case .device: nil
        }
    }
}

/// Core Audio property reads for the output list. Thread-agnostic; callers
/// stay on one queue.
enum MPAudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func defaultOutput() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static func defaultSystemOutput() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func transport(of device: AudioObjectID) -> (HUDOutputTransport, isAggregate: Bool) {
        let raw = uint32(device, kAudioDevicePropertyTransportType) ?? 0
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return (.builtIn, false)
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return (.bluetooth, false)
        case kAudioDeviceTransportTypeUSB: return (.usb, false)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return (.display, false)
        case kAudioDeviceTransportTypeAirPlay: return (.airPlay, false)
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return (.other, true)
        default: return (.other, false)
        }
    }

    /// Receivers behind the AirPlay device: (id, name).
    static func dataSources(of device: AudioObjectID) -> [(UInt32, String)] {
        var address = address(kAudioDevicePropertyDataSources, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in dataSourceName(device, id).map { (id, $0) } }
    }

    static func dataSourceName(_ device: AudioObjectID, _ source: UInt32) -> String? {
        var address = address(kAudioDevicePropertyDataSourceNameForIDCFString, kAudioObjectPropertyScopeOutput)
        var input = source
        var name: Unmanaged<CFString>?
        let status: OSStatus = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(inputPointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePointer),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let name else { return nil }
        let string = name.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func currentDataSource(of device: AudioObjectID) -> UInt32? {
        uint32(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
    }

    @discardableResult
    static func setDefaultOutput(_ device: AudioObjectID, alsoSystemOutput: Bool) -> OSStatus {
        var value = device
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        if status == noErr, alsoSystemOutput {
            var systemAddress = self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(system, &systemAddress, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        }
        return status
    }

    @discardableResult
    static func setDataSource(_ source: UInt32, on device: AudioObjectID) -> OSStatus {
        var value = source
        var address = address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Everything the picker offers, current first in each group's order.
    static func outputs() -> [AudioOutputDevice] {
        let current = defaultOutput()
        var result: [AudioOutputDevice] = []
        for device in objects(system, kAudioHardwarePropertyDevices) {
            guard hasOutputStreams(device) else { continue }
            let name = string(device, kAudioObjectPropertyName) ?? ""
            let uid = string(device, kAudioDevicePropertyDeviceUID) ?? ""
            let hidden = (uint32(device, kAudioDevicePropertyIsHidden) ?? 0) != 0
            let (transport, isAggregate) = transport(of: device)
            guard AudioDeviceFilter.isUserFacing(name: name, uid: uid, isHidden: hidden, hasOutput: true, isAggregate: isAggregate) else { continue }
            if transport == .airPlay {
                let sources = dataSources(of: device)
                if !sources.isEmpty {
                    let selected = currentDataSource(of: device)
                    for (source, sourceName) in sources {
                        result.append(AudioOutputDevice(
                            id: "airplay.\(uid).\(source)",
                            kind: .airPlay(device: device, source: source),
                            name: sourceName,
                            transport: .airPlay,
                            isCurrent: device == current && selected == source
                        ))
                    }
                    continue
                }
            }
            result.append(AudioOutputDevice(id: uid.isEmpty ? "device.\(device)" : uid, kind: .device(device),
                                             name: name, transport: transport, isCurrent: device == current))
        }
        return sorted(result)
    }

    /// Built-in first, then headphones, displays, USB, AirPlay, others;
    /// alphabetical inside a group.
    static func sorted(_ devices: [AudioOutputDevice]) -> [AudioOutputDevice] {
        func rank(_ device: AudioOutputDevice) -> Int {
            if case .bluetooth = device.kind { return 7 }
            switch device.transport {
            case .builtIn: return 0
            case .bluetooth: return 1
            case .display: return 2
            case .usb: return 3
            case .other: return 4
            case .airPlay: return 5
            }
        }
        return devices.sorted { lhs, rhs in
            rank(lhs) == rank(rhs) ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : rank(lhs) < rank(rhs)
        }
    }
}

// MARK: - Controller

/// The output list and switching. `start()` adds the Core Audio listeners
/// (hot-plug, default device); nothing polls.
@MainActor
final class AudioOutputController: ObservableObject {
    static let shared = AudioOutputController()

    @Published private(set) var devices: [AudioOutputDevice] = []
    /// A device being connected or switched to (shows a spinner).
    @Published private(set) var pendingID: String?
    @Published private(set) var lastError: String?

    var current: AudioOutputDevice? { devices.first(where: \.isCurrent) }

    /// Fixed list for offscreen renders.
    func showPreview(_ list: [AudioOutputDevice], pending: String? = nil) {
        isPreviewing = true
        devices = list
        pendingID = pending
    }

    private var isPreviewing = false

    private let queue = DispatchQueue(label: "SparkV.MediaPlus.outputs", qos: .userInitiated)
    private var listener: AudioObjectPropertyListenerBlock?
    private var isRunning = false
    private var refreshQueued = false
    /// Bluetooth headphones being connected: switch to them once Core Audio
    /// lists them.
    private var pendingConnect: (name: String, until: Date)?
    private var errorTask: Task<Void, Never>?
    /// Kept alive until IOBluetooth calls back.
    private var connectDelegate: MPBluetoothConnectDelegate?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block
        let queue = queue
        let box = MPListenerBox(block)
        // Async: the first HAL call can take a while at launch. stop()
        // removes synchronously on the same serial queue, after this.
        queue.async {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                var address = MPAudioHAL.address(selector)
                let status = AudioObjectAddPropertyListenerBlock(MPAudioHAL.system, &address, queue, box.block)
                if status != noErr { AppLog.log("Media: output listener \(selector) failed (\(status))") }
            }
        }
        refresh()
    }

    /// Synchronous, so the listeners are gone before the app quits.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let block = listener {
            queue.sync {
                for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                    var address = MPAudioHAL.address(selector)
                    AudioObjectRemovePropertyListenerBlock(MPAudioHAL.system, &address, self.queue, block)
                }
            }
        }
        listener = nil
    }

    /// Re-reads the list (coalesced; Core Audio sends bursts on hot-plug).
    func refresh() {
        guard !refreshQueued, !isPreviewing else { return }
        refreshQueued = true
        // IOBluetooth is a main-run-loop API; listing paired devices is cheap.
        let paired = PermissionCenter.shared.isGranted(.bluetooth) ? Self.pairedBluetoothOutputs() : []
        queue.async { [weak self] in
            var list = MPAudioHAL.outputs()
            if !paired.isEmpty {
                let names = Set(list.map(\.name))
                list = MPAudioHAL.sorted(list + paired.filter { !names.contains($0.name) })
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshQueued = false
                    if self.devices != list { self.devices = list }
                    self.finishPendingConnect()
                }
            }
        }
    }

    /// Makes `device` the output. Bluetooth headphones are connected first;
    /// AirPlay receivers are picked on the AirPlay device, which then becomes
    /// the output. Alerts follow when they were following the output.
    func select(_ device: AudioOutputDevice) {
        guard !device.isCurrent else { return }
        AppLog.log("Media: switching output to “\(device.name)”")
        switch device.kind {
        case .device(let id):
            pendingID = device.id
            queue.async { [weak self] in
                let followed = MPAudioHAL.defaultSystemOutput() == MPAudioHAL.defaultOutput()
                let status = MPAudioHAL.setDefaultOutput(id, alsoSystemOutput: followed)
                self?.finishSwitch(device, status: status)
            }
        case .airPlay(let id, let source):
            pendingID = device.id
            queue.async { [weak self] in
                var status = MPAudioHAL.setDataSource(source, on: id)
                if status == noErr {
                    let followed = MPAudioHAL.defaultSystemOutput() == MPAudioHAL.defaultOutput()
                    status = MPAudioHAL.setDefaultOutput(id, alsoSystemOutput: followed)
                }
                self?.finishSwitch(device, status: status)
            }
        case .bluetooth(let address):
            connectBluetooth(address: address, name: device.name, id: device.id)
        }
    }

    private nonisolated func finishSwitch(_ device: AudioOutputDevice, status: OSStatus) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.pendingID = nil
                if status != noErr {
                    AppLog.log("Media: switching to “\(device.name)” failed (\(status))")
                    self.show(error: "Couldn’t switch to \(device.name)")
                }
                self.refresh()
            }
        }
    }

    private func connectBluetooth(address: String, name: String, id: String) {
        guard PermissionCenter.shared.isGranted(.bluetooth) else {
            Task { _ = await PermissionCenter.shared.request(.bluetooth, from: "Sound Output") }
            return
        }
        pendingID = id
        pendingConnect = (name, Date().addingTimeInterval(12))
        // Asynchronous open on the main run loop (IOBluetooth's own thread
        // model); the delegate reports the result.
        let finish: @MainActor (IOReturn) -> Void = { [weak self] status in
            guard let self else { return }
            self.connectDelegate = nil
            if status != kIOReturnSuccess {
                AppLog.log("Media: connecting “\(name)” failed (\(status))")
                self.pendingConnect = nil
                self.pendingID = nil
                self.show(error: "Couldn’t connect \(name)")
            }
            self.refresh()
            // Core Audio lists the headphones a moment after they connect.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12.5))
                self?.expirePendingConnect()
            }
        }
        guard let device = IOBluetoothDevice(addressString: address) else {
            finish(kIOReturnNotFound)
            return
        }
        let delegate = MPBluetoothConnectDelegate(finish)
        connectDelegate = delegate
        let status = device.openConnection(delegate)
        if status != kIOReturnSuccess { finish(status) }
    }

    private func finishPendingConnect() {
        guard let pending = pendingConnect else { return }
        if let device = devices.first(where: {
            if case .device = $0.kind { return $0.name == pending.name }
            return false
        }) {
            pendingConnect = nil
            pendingID = nil
            select(device)
        }
    }

    private func expirePendingConnect() {
        guard let pending = pendingConnect, Date() >= pending.until else { return }
        pendingConnect = nil
        pendingID = nil
        show(error: "\(pending.name) didn’t show up as a speaker")
    }

    private func show(error: String) {
        lastError = error
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    /// Paired audio devices that aren't connected (and so aren't Core Audio
    /// devices yet). Only called when Bluetooth access is granted.
    private static func pairedBluetoothOutputs() -> [AudioOutputDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.compactMap { device in
            guard !device.isConnected(), isAudio(device), let address = device.addressString else { return nil }
            let name = device.name ?? device.nameOrAddress ?? "Headphones"
            return AudioOutputDevice(id: "bt.\(address)", kind: .bluetooth(address: address), name: name,
                                     transport: .bluetooth, isCurrent: false)
        }
    }

    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        if Int(device.deviceClassMajor) == Int(kBluetoothDeviceClassMajorAudio) { return true }
        let name = (device.name ?? "").lowercased()
        return ["airpods", "beats", "buds", "headphone", "headset", "speaker"].contains { name.contains($0) }
    }
}

/// Target for `IOBluetoothDevice.openConnection(_:)`: IOBluetooth calls
/// `connectionComplete(_:status:)` on the main run loop.
final class MPBluetoothConnectDelegate: NSObject {
    private let finish: @MainActor (IOReturn) -> Void

    init(_ finish: @escaping @MainActor (IOReturn) -> Void) {
        self.finish = finish
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let finish = finish
        if Thread.isMainThread {
            MainActor.assumeIsolated { finish(status) }
        } else {
            DispatchQueue.main.async { finish(status) }
        }
    }
}
