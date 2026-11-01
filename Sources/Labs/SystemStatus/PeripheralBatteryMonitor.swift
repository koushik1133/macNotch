import AppKit
import Combine
import GameController
import IOKit
import SwiftUI

/// Battery levels of Magic Mouse, Keyboard and Trackpad (and other HID
/// peripherals that report one) plus game controllers, with a short band
/// when one connects and a low-battery alert once per discharge.
///
/// - Magic peripherals: the IOKit registry's AppleDeviceManagementHIDEventService
///   entries carry `BatteryPercent`. Public IOKit, no Bluetooth permission, and
///   reading the registry never wakes the radio. Connects and disconnects
///   arrive as IOKit matching notifications on the main run loop; levels are
///   re-read every 15 minutes (tolerant timer) only while a device is
///   connected, and after wake.
/// - Game controllers: GameController's connect notifications and
///   `GCDeviceBattery`.
///
/// Third-party mice usually expose no battery; they simply don't appear.
@MainActor
final class PeripheralBatteryMonitor: ObservableObject {
    static let shared = PeripheralBatteryMonitor()

    static let enabledKey = "peripherals.isEnabled"
    static let thresholdKey = "peripherals.lowThreshold"
    static let controllersKey = "peripherals.gameControllers"
    static let connectBandKey = "peripherals.connectBand"
    static let thresholdChoices = [0, 5, 10, 15, 20, 30]

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            StatusDefaults.set(isEnabled, Self.enabledKey)
            applyEnabled()
        }
    }

    /// Alert at or under this level (0 = never).
    @Published var lowThreshold: Int {
        didSet {
            StatusDefaults.set(lowThreshold, Self.thresholdKey)
            tracker.threshold = lowThreshold
        }
    }

    @Published var includesGameControllers: Bool {
        didSet {
            guard includesGameControllers != oldValue else { return }
            StatusDefaults.set(includesGameControllers, Self.controllersKey)
            if isRunning { includesGameControllers ? startControllers() : stopControllers(); rescan() }
        }
    }

    /// A short band when a peripheral connects.
    @Published var showsConnectBand: Bool {
        didSet { StatusDefaults.set(showsConnectBand, Self.connectBandKey) }
    }

    /// Connected peripherals that report a battery, sorted by kind.
    @Published private(set) var devices: [PeripheralBattery] = []
    @Published private(set) var lastRefresh: Date?

    private var isStarted = false
    private var isRunning = false
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var rescanTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var tracker: PeripheralLowTracker
    /// Ids already seen, so a connect band shows only for new arrivals.
    private var known: Set<String> = []
    private var hasBaseline = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var controllerObservers: [NSObjectProtocol] = []

    /// Registry classes that carry `BatteryPercent` (the first on current
    /// macOS; the others on older peripherals and systems).
    private static let serviceClasses = [
        "AppleDeviceManagementHIDEventService", "AppleBluetoothHIDKeyboard", "BNBMouseDevice", "BNBTrackpadDevice",
    ]
    private static let refreshInterval: TimeInterval = 15 * 60

    private init() {
        isEnabled = StatusDefaults.bool(Self.enabledKey, default: true)
        let threshold = StatusDefaults.int(Self.thresholdKey, default: 15)
        lowThreshold = threshold
        includesGameControllers = StatusDefaults.bool(Self.controllersKey, default: true)
        showsConnectBand = StatusDefaults.bool(Self.connectBandKey, default: true)
        tracker = PeripheralLowTracker(threshold: threshold)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        applyEnabled()
    }

    func stop() {
        isStarted = false
        stopRunning()
    }

    /// Re-reads every level now (the Status page calls this on appear).
    func refresh() {
        guard isRunning else { return }
        rescan()
    }

    // MARK: Lifecycle

    private func applyEnabled() {
        guard isStarted else { return }
        if isEnabled { startRunning() } else { stopRunning() }
    }

    private func startRunning() {
        guard !isRunning else { return }
        isRunning = true
        hasBaseline = false
        known = []
        installIOKitNotifications()
        if includesGameControllers { startControllers() }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRescan(after: 5) }
        }
        observers.append((NSWorkspace.shared.notificationCenter, wake))
        rescan()
        AppLog.log("Peripherals: watching \(devices.count) device(s)")
    }

    private func stopRunning() {
        guard isRunning else { return }
        isRunning = false
        rescanTask?.cancel()
        rescanTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
        stopControllers()
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        for device in devices { SystemStatusCenter.shared.dismiss(id: Self.activityID(device.id)) }
        devices = []
    }

    // MARK: IOKit notifications

    private func installIOKitNotifications() {
        guard port == nil, let newPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = newPort
        if let source = IONotificationPortGetRunLoopSource(newPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain, or IOKit stops sending notifications for this iterator.
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let refcon else { return }
            // The port's source is on the main run loop.
            MainActor.assumeIsolated {
                let monitor = Unmanaged<PeripheralBatteryMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // A new device reports its battery a moment after it appears.
                monitor.scheduleRescan(after: 0.4)
                monitor.scheduleRescan(after: 3, replacing: false)
            }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // Each call consumes one reference to its matching dictionary.
            let result = IOServiceAddMatchingNotification(
                newPort, type, IOServiceMatching(Self.serviceClasses[0]), callback, refcon, &iterator
            )
            guard result == KERN_SUCCESS else {
                AppLog.log("Peripherals: IOKit notification failed (\(result))")
                continue
            }
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            iterators.append(iterator)
        }
    }

    /// Coalesced rescan; `replacing: false` adds a later one instead of
    /// moving the pending one.
    private func scheduleRescan(after delay: TimeInterval, replacing: Bool = true) {
        guard isRunning else { return }
        if replacing { rescanTask?.cancel() }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.rescan()
        }
        if replacing { rescanTask = task }
    }

    // MARK: Reading

    private func rescan() {
        guard isRunning else { return }
        var found = Self.readHIDBatteries()
        if includesGameControllers { found += Self.readControllers() }
        let current = PeripheralRegistryParser.dedupe(found)
        apply(current)
        lastRefresh = Date()
        scheduleRefreshTimer()
    }

    private func apply(_ current: [PeripheralBattery]) {
        let baseline = !hasBaseline
        hasBaseline = true
        let previousIDs = Set(devices.map(\.id))
        for device in current {
            let isNew = !known.contains(device.id) && !previousIDs.contains(device.id)
            known.insert(device.id)
            let shouldAlert = tracker.update(device, isBaseline: baseline || isNew)
            if isNew, !baseline, showsConnectBand {
                AppLog.log("Peripherals: \(device.name) connected (\(device.percent.map { "\($0)%" } ?? "battery unknown"))")
                post(device, mode: .connected)
            } else if shouldAlert {
                AppLog.log("Peripherals: \(device.name) low (\(device.percent ?? -1)%)")
                post(device, mode: .low)
            }
        }
        // Gone: forget, so the next connect shows a band again.
        let currentIDs = Set(current.map(\.id))
        for id in previousIDs.subtracting(currentIDs) {
            known.remove(id)
            tracker.forget(id)
        }
        if devices != current { devices = current }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard isRunning, !devices.isEmpty else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Every registry service of the battery classes, read key by key.
    private static func readHIDBatteries() -> [PeripheralBattery] {
        var result: [PeripheralBattery] = []
        for name in serviceClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: [String: Any] = [:]
                for key in PeripheralRegistryParser.keys {
                    if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                        properties[key] = value
                    }
                }
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &entryID)
                if let battery = PeripheralRegistryParser.battery(from: properties, registryID: entryID) {
                    result.append(battery)
                }
            }
        }
        return result
    }

    // MARK: Game controllers

    private func startControllers() {
        guard controllerObservers.isEmpty else { return }
        // SparkV is an agent app that is never frontmost.
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            controllerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRescan(after: 0.5) }
            })
        }
    }

    private func stopControllers() {
        controllerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        controllerObservers.removeAll()
    }

    private static func readControllers() -> [PeripheralBattery] {
        GCController.controllers().compactMap { controller in
            guard let battery = controller.battery else { return nil }
            let name = controller.vendorName ?? controller.productCategory
            let state = battery.batteryState
            let percent = state == .unknown ? nil : PeripheralRegistryParser.percent(fromLevel: battery.batteryLevel)
            return PeripheralBattery(
                // Stable while connected: the controller object's identity
                // (an index shifts when another controller disconnects).
                id: "gc.\(name).\(UInt(bitPattern: ObjectIdentifier(controller).hashValue))", name: name, kind: .gameController, percent: percent,
                isCharging: state == .charging || state == .full, source: .gameController
            )
        }
    }

    // MARK: Bands

    static func activityID(_ id: String) -> String { "peripheral.\(id)" }

    private func post(_ device: PeripheralBattery, mode: PeripheralActivityView.Mode) {
        SystemStatusCenter.shared.post(LiveActivity(
            id: Self.activityID(device.id),
            kind: .airPods,
            priority: mode == .low ? 52 : 50,
            duration: mode == .low ? 4 : 3,
            opensTab: SystemStatusCenter.shared.statusTab,
            symbol: device.kind.symbol
        ) {
            PeripheralActivityView(device: device, mode: mode)
        }
        .titled("Accessory Battery"))
    }
}
