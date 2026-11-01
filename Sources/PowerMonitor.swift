import AppKit
import Combine
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.ps
import SwiftUI

/// Battery and Bluetooth-audio HUDs: a short band when the charger goes in or
/// out (with the charger's wattage), low-battery warnings at the thresholds
/// the user picked (20 % and 10 % by default), a critical alert that stays in
/// the wings until the charger goes in, and the AirPods (or any Bluetooth
/// headset) battery when one connects. Also keeps the battery's health
/// (maximum capacity, cycle count, condition) and Low Power Mode for the
/// Status page.
///
/// Event driven only: IOKit power-source notifications, Low Power Mode's
/// `NSProcessInfoPowerStateDidChange`, IOBluetooth connect notifications.
/// The battery registry (health, cycles) is read on plug / unplug, when the
/// Status page opens and at most every 10 minutes from those notifications.
///
/// Bluetooth needs the TCC "Bluetooth" permission. Registering IOBluetooth
/// notifications while that permission is undetermined shows the system
/// prompt, so `start()` only registers when it is already granted;
/// otherwise call `requestBluetoothAccess()` from a user action (it also runs
/// when `isEnabled` is switched back on).
@MainActor
final class PowerMonitor: ObservableObject {
    enum BluetoothAccess: Equatable {
        case notDetermined, allowed, denied
    }

    /// The running monitor (set in `init`), for settings sections and the
    /// Status page, which take no arguments.
    static weak var current: PowerMonitor?

    /// Persisted; when false no band is posted and Bluetooth is not watched
    /// (the battery reading stays live for the Status page).
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            applyEnabled(userInitiated: true)
        }
    }

    /// Low-battery warnings, in percent, highest first (each fires once per
    /// discharge). Change with `setLowThresholds(_:)`.
    @Published private(set) var lowThresholds: [Int]

    /// At or below this level on battery, a red alert stays in the wings
    /// until the charger goes in; 0 is off. Change with `setCriticalLevel(_:)`.
    @Published private(set) var criticalLevel: Int

    /// Show the charger's wattage in the plug-in band.
    @Published var showsWattage: Bool {
        didSet { UserDefaults.standard.set(showsWattage, forKey: Self.wattageKey) }
    }

    /// Bluetooth permission as last seen (for a settings row).
    @Published private(set) var bluetoothAccess: BluetoothAccess
    /// Latest internal-battery reading; nil on Macs without a battery.
    @Published private(set) var battery: BatteryReading?
    /// Health, cycles, charger and charge-hold details; nil until read (and
    /// on Macs without a battery).
    @Published private(set) var details: BatteryDetails?
    /// Low Power Mode as macOS reports it right now.
    @Published private(set) var isLowPowerMode: Bool
    /// The Bluetooth headset that connected last and is still connected.
    @Published private(set) var connectedAudio: BluetoothAudioDevice?

    static let enabledKey = "power.isEnabled"
    static let thresholdsKey = "power.lowThresholds"
    static let criticalKey = "power.criticalLevel"
    static let wattageKey = "power.showsWattage"
    static let batteryActivityID = "battery"
    static let criticalActivityID = "battery.critical"
    static let airPodsActivityID = "airpods"
    static let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")

    private static let plugDuration: TimeInterval = 3
    private static let lowDuration: TimeInterval = 4
    private static let airPodsDuration: TimeInterval = 4
    /// Health and cycle counts change slowly: re-read at most this often
    /// from power-source notifications.
    private static let detailsRefreshInterval: TimeInterval = 600

    private let activities: ActivityCenter
    private var isStarted = false

    // Battery
    private var runLoopSource: CFRunLoopSource?
    private var tracker: BatteryTransitionTracker
    /// The plug-in band currently on screen, so a time-to-full estimate (or
    /// the charger's wattage) that arrives a moment later can fill it in.
    private var plugBand: (expires: Date, hadTime: Bool, hadWatts: Bool, mode: BatteryActivityMode, hold: BatteryHoldReason?)?
    /// Level the critical alert shows, while it is up.
    private var criticalShownLevel: Int?
    private var detailsReadAt: Date?
    private var powerStateObserver: NSObjectProtocol?

    // Bluetooth
    private var bluetooth: BluetoothConnectionObserver?
    private var accessRequest: Task<Void, Never>?
    /// Starts the AirPods HUD when Bluetooth is granted in System Settings.
    private var bluetoothWatch: AnyCancellable?
    private var lookupTask: Task<Void, Never>?
    private var shownAudioAddress: String?

    init(activities: ActivityCenter) {
        self.activities = activities
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let thresholds = BatteryThresholds.sanitize(defaults.array(forKey: Self.thresholdsKey) as? [Int] ?? BatteryThresholds.defaultLow)
        lowThresholds = thresholds
        let critical = BatteryThresholds.sanitizeCritical(defaults.object(forKey: Self.criticalKey) as? Int ?? BatteryThresholds.defaultCritical)
        criticalLevel = critical
        showsWattage = defaults.object(forKey: Self.wattageKey) as? Bool ?? true
        tracker = BatteryTransitionTracker(thresholds: thresholds)
        bluetoothAccess = Self.currentBluetoothAccess()
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        Self.current = self
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        bluetoothWatch = PermissionCenter.shared.onChange(of: .bluetooth) { [weak self] _ in
            guard let self else { return }
            self.bluetoothAccess = Self.currentBluetoothAccess()
            if self.bluetoothAccess == .allowed { self.startBluetooth() }
        }
        // Low Power Mode: posted on an arbitrary thread when it flips.
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let on = ProcessInfo.processInfo.isLowPowerModeEnabled
                if self.isLowPowerMode != on {
                    self.isLowPowerMode = on
                    AppLog.log("Power: Low Power Mode \(on ? "on" : "off")")
                }
            }
        }
        applyEnabled(userInitiated: false)
    }

    func stop() {
        isStarted = false
        bluetoothWatch = nil
        if let powerStateObserver { NotificationCenter.default.removeObserver(powerStateObserver) }
        powerStateObserver = nil
        stopMonitoring()
    }

    /// Shows the Bluetooth permission prompt if it hasn't been answered (one
    /// system prompt at a time, through PermissionCenter), then starts the
    /// AirPods HUD once granted. When it was refused, opens the Bluetooth
    /// pane in System Settings instead. Call from a user action.
    func requestBluetoothAccess() {
        bluetoothAccess = Self.currentBluetoothAccess()
        if bluetoothAccess == .allowed {
            startBluetooth()
            return
        }
        guard accessRequest == nil else { return }
        AppLog.log("Power: requesting Bluetooth access")
        accessRequest = Task { [weak self] in
            _ = await PermissionCenter.shared.request(.bluetooth, from: "AirPods battery")
            guard let self else { return }
            self.accessRequest = nil
            self.bluetoothAccess = Self.currentBluetoothAccess()
            AppLog.log("Power: Bluetooth access now \(self.bluetoothAccess)")
            if self.bluetoothAccess == .allowed, self.isEnabled, self.isStarted {
                self.startBluetooth()
            }
        }
    }

    func setLowThresholds(_ values: [Int]) {
        let clean = BatteryThresholds.sanitize(values)
        guard clean != lowThresholds else { return }
        lowThresholds = clean
        UserDefaults.standard.set(clean, forKey: Self.thresholdsKey)
        tracker.thresholds = clean
        AppLog.log("Power: low-battery warnings at \(BatteryThresholds.summary(clean))")
    }

    /// Adds or removes one threshold (the settings checkboxes).
    func setLowThreshold(_ value: Int, enabled: Bool) {
        var set = Set(lowThresholds)
        if enabled { set.insert(value) } else { set.remove(value) }
        setLowThresholds(Array(set))
    }

    func setCriticalLevel(_ value: Int) {
        let clean = BatteryThresholds.sanitizeCritical(value)
        guard clean != criticalLevel else { return }
        criticalLevel = clean
        UserDefaults.standard.set(clean, forKey: Self.criticalKey)
        if let battery { updateCritical(battery) }
    }

    /// Re-reads the battery, its health and Low Power Mode once (the Status
    /// page calls this when it appears). Works while the HUD is off too.
    func refreshForDisplay() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let reading = Self.readBattery()
        if battery != reading { battery = reading }
        refreshDetails(force: true)
    }

    /// Opens System Settings › Battery (Low Power Mode, Optimized Charging,
    /// the charge limit and "Charge to Full Now" live there or in the
    /// battery menu).
    func openBatterySettings() {
        guard let url = Self.batterySettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    private func applyEnabled(userInitiated: Bool) {
        guard isStarted else { return }
        // The reading itself (one IOPS notification source, no polling) runs
        // whenever the monitor is started, so the Status page and the hub
        // badge stay current with the HUD off; only the bands are gated.
        startBattery()
        guard isEnabled else {
            stopBands()
            return
        }
        // Fresh baseline: the HUD coming back on is not a plug event.
        tracker = BatteryTransitionTracker(thresholds: lowThresholds)
        if let battery { _ = tracker.update(battery); updateCritical(battery) }
        bluetoothAccess = Self.currentBluetoothAccess()
        switch bluetoothAccess {
        case .allowed:
            startBluetooth()
        case .notDetermined:
            if userInitiated {
                requestBluetoothAccess()
            } else {
                AppLog.log("Power: Bluetooth access not determined; AirPods HUD waits for requestBluetoothAccess()")
            }
        case .denied:
            AppLog.log("Power: Bluetooth access denied; AirPods HUD off")
        }
    }

    private func stopMonitoring() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        stopBands()
    }

    /// HUD off: Bluetooth and every band go; the battery reading stays.
    private func stopBands() {
        bluetooth?.stop()
        bluetooth = nil
        accessRequest?.cancel()
        accessRequest = nil
        lookupTask?.cancel()
        lookupTask = nil
        plugBand = nil
        criticalShownLevel = nil
        shownAudioAddress = nil
        connectedAudio = nil
        activities.dismiss(id: Self.batteryActivityID)
        activities.dismiss(id: Self.criticalActivityID)
        activities.dismiss(id: Self.airPodsActivityID)
    }

    private static func currentBluetoothAccess() -> BluetoothAccess {
        // PermissionCenter reads CBManager.authorization, which never prompts.
        let center = PermissionCenter.shared
        if center.isGranted(.bluetooth) { return .allowed }
        return center.status(.bluetooth) == .notDetermined ? .notDetermined : .denied
    }

    // MARK: - Battery

    private func startBattery() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            // The source is on the main run loop, so this runs on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().powerSourcesChanged()
            }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            AppLog.log("Power: could not create the power-source run loop source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        tracker = BatteryTransitionTracker(thresholds: lowThresholds)
        powerSourcesChanged()
    }

    private func powerSourcesChanged() {
        guard runLoopSource != nil else { return }
        let reading = Self.readBattery()
        if battery != reading { battery = reading }
        guard let reading else { return }
        guard isEnabled else {
            // HUD off: keep the plug-event health re-read for the Status page.
            if let last = tracker.last, last.isOnAC != reading.isOnAC { refreshDetails(force: true) }
            _ = tracker.update(reading)
            return
        }

        let event = tracker.update(reading)
        // Plug / unplug changes the charger and the hold state: read now.
        refreshDetails(force: event == .pluggedIn || event == .unplugged)

        switch event {
        case .pluggedIn:
            AppLog.log("Power: plugged in at \(reading.level)%\(details?.adapter?.watts.map { " (\($0) W)" } ?? "")")
            let watts = adapterWatts()
            let mode = BatteryActivityMode(chargingReading: reading)
            postBattery(reading, mode: mode, duration: Self.plugDuration, watts: watts)
            plugBand = (Date().addingTimeInterval(Self.plugDuration), reading.minutesToFull != nil, watts != nil,
                        mode, holdFor(reading, mode: mode))
        case .unplugged:
            AppLog.log("Power: unplugged at \(reading.level)%")
            plugBand = nil
            postBattery(reading, mode: .onBattery, duration: Self.plugDuration)
        case .low(let threshold):
            plugBand = nil
            // The critical alert covers levels at or under its own threshold.
            if !BatteryCriticalPolicy.isCritical(reading, criticalLevel: criticalLevel) {
                AppLog.log("Power: low battery \(reading.level)% (threshold \(threshold)%)")
                postBattery(reading, mode: .low, duration: Self.lowDuration)
            }
        case nil:
            // The charger estimate and wattage usually land a second after
            // plugging in, and IOPS can say "not charging" for a moment
            // before charging starts: re-post when any of that changes.
            if let band = plugBand, reading.isOnAC {
                let watts = adapterWatts()
                let mode = BatteryActivityMode(chargingReading: reading)
                if mode != band.mode { refreshDetails(force: true) }
                let hold = holdFor(reading, mode: mode)
                let newTime = !band.hadTime && reading.minutesToFull != nil
                let newWatts = !band.hadWatts && watts != nil
                let remaining = band.expires.timeIntervalSinceNow
                if newTime || newWatts || mode != band.mode || hold != band.hold, remaining > 0.5 {
                    postBattery(reading, mode: mode, duration: remaining, watts: watts)
                    plugBand = (band.expires, band.hadTime || newTime, band.hadWatts || newWatts, mode, hold)
                }
            }
        }
        updateCritical(reading)
    }

    /// Wattage for the band, when the user wants it and macOS reports it.
    private func adapterWatts() -> Int? {
        guard showsWattage else { return nil }
        return PowerAdapterReading.current()?.watts
    }

    /// Shows, updates or clears the critical alert for `reading`.
    private func updateCritical(_ reading: BatteryReading) {
        guard isEnabled, isStarted else { return }
        if BatteryCriticalPolicy.isCritical(reading, criticalLevel: criticalLevel) {
            guard criticalShownLevel != reading.level else { return }
            if criticalShownLevel == nil {
                AppLog.log("Power: critical battery \(reading.level)% (at or under \(criticalLevel)%)")
            }
            criticalShownLevel = reading.level
            postCritical(reading)
        } else if criticalShownLevel != nil {
            criticalShownLevel = nil
            activities.dismiss(id: Self.criticalActivityID)
        }
    }

    private func holdFor(_ reading: BatteryReading, mode: BatteryActivityMode) -> BatteryHoldReason? {
        mode == .notCharging ? details?.holdReason(for: reading) : nil
    }

    private func postBattery(_ reading: BatteryReading, mode: BatteryActivityMode, duration: TimeInterval, watts: Int? = nil) {
        let hold = holdFor(reading, mode: mode)
        activities.post(LiveActivity(
            id: Self.batteryActivityID,
            kind: .battery,
            priority: 50,
            duration: duration
        ) {
            BatteryActivityView(reading: reading, mode: mode, watts: watts, hold: hold)
        }
        .announcing(ActivityAnnouncementText.battery(reading, mode: mode), as: .charging,
                    important: ActivityAnnouncementText.isImportant(mode)))
    }

    /// Persistent: introduces itself in the band each time the level drops,
    /// then rests in the wings as a red battery and the percentage, so it
    /// never covers the menu bar for long. Cleared when the charger goes in.
    private func postCritical(_ reading: BatteryReading) {
        let level = reading.level
        activities.post(LiveActivity(
            id: Self.criticalActivityID,
            kind: .battery,
            priority: 85,
            duration: nil,
            symbol: "battery.0percent",
            tint: SparkVTheme.destructive,
            compactText: "\(level)%",
            peekKey: "\(level)"
        ) {
            BatteryActivityView(reading: reading, mode: .critical)
        }
        .announcing(ActivityAnnouncementText.battery(reading, mode: .critical), as: .charging, important: true)
        .compact {
            BatteryGlyph(level: level, isCharging: false, tint: SparkVTheme.destructive)
                .accessibilityLabel("Battery critically low")
        } trailing: {
            Text("\(level)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.destructive)
                .fixedSize()
        }
        .minimal {
            Image(systemName: "battery.0percent")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(SparkVTheme.destructive)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SparkVTheme.destructive.opacity(0.18)))
                .accessibilityLabel("Battery \(level) percent")
        }
        .titled("Battery Critically Low"))
    }

    /// Health and charger details, throttled (see `detailsRefreshInterval`).
    private func refreshDetails(force: Bool) {
        if !force, let at = detailsReadAt, Date().timeIntervalSince(at) < Self.detailsRefreshInterval { return }
        detailsReadAt = Date()
        let fresh = BatteryDetails.read()
        if details != fresh { details = fresh }
    }

    /// The internal battery from IOKit power sources, or nil without one.
    nonisolated static func readBattery() -> BatteryReading? {
        powerSourceDescription().flatMap(BatteryReading.init(description:))
    }

    /// The IOPS description of the internal battery, or nil without one.
    nonisolated static func powerSourceDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            if description["Type"] as? String == "InternalBattery" { return description }
        }
        return nil
    }

    // MARK: - Bluetooth audio

    private func startBluetooth() {
        guard bluetooth == nil, isEnabled, isStarted else { return }
        let observer = BluetoothConnectionObserver(
            onConnect: { [weak self] device, refresh in
                self?.audioDeviceConnected(device, refresh: refresh)
            },
            onDisconnect: { [weak self] address in
                self?.audioDeviceDisconnected(address)
            }
        )
        observer.start()
        bluetooth = observer
        AppLog.log("Power: watching Bluetooth audio connections")
    }

    private func audioDeviceConnected(
        _ device: BluetoothAudioDevice,
        refresh: @escaping @MainActor () -> AudioBatteries
    ) {
        guard isEnabled else { return }
        AppLog.log("Power: Bluetooth audio connected: \(device.name) \(device.batteries.summary)")
        let connectedAt = Date()
        postAirPods(device, duration: Self.airPodsDuration)

        lookupTask?.cancel()
        guard device.batteries.isEmpty else { return }
        // AirPods report battery a moment after the link comes up; try the
        // device again, then fall back to system_profiler (slow, off main).
        lookupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            var batteries = refresh()
            if batteries.isEmpty {
                let profiled = await SystemProfilerBluetooth.connectedDevices()
                guard !Task.isCancelled else { return }
                batteries = SystemProfilerBluetooth.match(profiled, address: device.address, name: device.name)
                    ?? AudioBatteries()
            }
            guard let self, self.isEnabled, !batteries.isEmpty,
                  self.shownAudioAddress == device.address
            else { return }
            AppLog.log("Power: \(device.name) battery \(batteries.summary)")
            var updated = device
            updated.batteries = batteries
            let remaining = Self.airPodsDuration - Date().timeIntervalSince(connectedAt)
            self.postAirPods(updated, duration: max(2.5, remaining))
        }
    }

    private func audioDeviceDisconnected(_ address: String) {
        if connectedAudio?.address == address { connectedAudio = nil }
        guard shownAudioAddress == address else { return }
        lookupTask?.cancel()
        lookupTask = nil
        shownAudioAddress = nil
        activities.dismiss(id: Self.airPodsActivityID)
    }

    private func postAirPods(_ device: BluetoothAudioDevice, duration: TimeInterval) {
        shownAudioAddress = device.address
        connectedAudio = device
        activities.post(LiveActivity(
            id: Self.airPodsActivityID,
            kind: .airPods,
            priority: 55,
            duration: duration
        ) {
            AirPodsActivityView(device: device)
        }
        .announcing(ActivityAnnouncementText.airPods(device), as: .charging))
    }
}

// MARK: - Battery registry and charger (IOKit)

extension BatteryDetails {
    /// Reads AppleSmartBattery (cycle count, capacities, condition), the
    /// IOPS description and the external adapter. A handful of single-key
    /// registry reads: cheap, but only on plug events and on demand.
    static func read() -> BatteryDetails? {
        guard let source = PowerMonitor.powerSourceDescription() else { return nil }
        var registry: [String: Any] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            for key in BatteryHealthReading.registryKeys {
                if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                    registry[key] = value
                }
            }
        }
        return BatteryDetails(
            health: BatteryHealthReading(registry: registry, powerSource: source),
            adapter: PowerAdapterReading.current(),
            isOptimizedChargingEngaged: BatteryDetails.optimizedFlag(in: source),
            lowPowerModeActive: (source["LPM Active"] as? NSNumber)?.boolValue
        )
    }
}

extension PowerAdapterReading {
    /// The connected charger, or nil on battery.
    static func current() -> PowerAdapterReading? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else { return nil }
        return PowerAdapterReading(details: details)
    }
}

// MARK: - IOBluetooth plumbing

/// Receives IOBluetooth connect/disconnect notifications (delivered on the
/// main run loop) and forwards audio devices as plain values.
@MainActor
private final class BluetoothConnectionObserver: NSObject {
    private let onConnect: @MainActor (BluetoothAudioDevice, @escaping @MainActor () -> AudioBatteries) -> Void
    private let onDisconnect: @MainActor (String) -> Void
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// IOBluetooth replays a connect for every device already connected when
    /// the notification is registered; those aren't new connections.
    private var registeredAt = Date.distantPast

    init(
        onConnect: @escaping @MainActor (BluetoothAudioDevice, @escaping @MainActor () -> AudioBatteries) -> Void,
        onDisconnect: @escaping @MainActor (String) -> Void
    ) {
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func start() {
        guard connectNotification == nil else { return }
        registeredAt = Date()
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        if connectNotification == nil {
            AppLog.log("Power: IOBluetooth connect notification registration failed")
        }
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.isAudio(device) else { return }
        let address = BluetoothAudioDevice.normalize(address: device.addressString ?? "")
        if disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDisconnected(_:device:))
            )
        }
        guard Date().timeIntervalSince(registeredAt) > 2 else { return }

        let snapshot = BluetoothAudioDevice(
            name: device.name ?? device.nameOrAddress ?? "Headphones",
            address: address,
            batteries: Self.batteries(of: device)
        )
        onConnect(snapshot) { Self.batteries(of: device) }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = BluetoothAudioDevice.normalize(address: device.addressString ?? "")
        disconnectNotifications.removeValue(forKey: address)?.unregister()
        onDisconnect(address)
    }

    static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        if Int(device.deviceClassMajor) == Int(kBluetoothDeviceClassMajorAudio) { return true }
        let name = (device.name ?? "").lowercased()
        return ["airpods", "beats", "buds", "headphone", "headset"].contains { name.contains($0) }
    }

    /// AirPods battery from IOBluetoothDevice's private `batteryPercent*`
    /// getters (unsigned char, 0 = unknown). Guarded so a missing selector
    /// can't raise NSUndefinedKeyException.
    private static func batteries(of device: IOBluetoothDevice) -> AudioBatteries {
        func percent(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let number = device.value(forKey: key) as? NSNumber
            else { return nil }
            return AudioBatteries.valid(number.intValue, zeroIsUnknown: true)
        }
        return AudioBatteries(
            left: percent("batteryPercentLeft"),
            right: percent("batteryPercentRight"),
            case: percent("batteryPercentCase"),
            single: percent("batteryPercentSingle") ?? percent("batteryPercentCombined")
        )
    }
}

// MARK: - system_profiler fallback

enum SystemProfilerBluetooth {
    /// Runs `system_profiler SPBluetoothDataType -json` off the main thread
    /// (it takes a second or more) and returns the connected devices.
    static func connectedDevices() async -> [ProfiledBluetoothDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = runSystemProfiler()
                continuation.resume(returning: data.map(BluetoothProfileParser.connectedDevices(from:)) ?? [])
            }
        }
    }

    static func match(_ devices: [ProfiledBluetoothDevice], address: String, name: String) -> AudioBatteries? {
        let found = devices.first { !address.isEmpty && $0.address == address }
            ?? devices.first { $0.name == name }
        guard let found, !found.batteries.isEmpty else { return nil }
        return found.batteries
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    private static func runSystemProfiler() -> Data? {
        let box = ProcessBox()
        let pipe = Pipe()
        box.process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        box.process.arguments = ["SPBluetoothDataType", "-json"]
        box.process.standardOutput = pipe
        box.process.standardError = FileHandle.nullDevice
        do {
            try box.process.run()
        } catch {
            AppLog.log("Power: system_profiler failed to start: \(error.localizedDescription)")
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            if box.process.isRunning { box.process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        box.process.waitUntilExit()
        return box.process.terminationStatus == 0 ? data : nil
    }
}

// MARK: - Pure logic (BEGIN harness)

/// One reading of the internal battery.
struct BatteryReading: Equatable, Sendable {
    var level: Int
    var isOnAC: Bool
    var isCharging: Bool
    var isCharged: Bool
    /// Minutes, when the system has an estimate.
    var minutesToFull: Int?
    var minutesToEmpty: Int?

    /// From an IOPSGetPowerSourceDescription dictionary; nil unless it is a
    /// present internal battery.
    init?(description: [String: Any]) {
        guard description["Type"] as? String == "InternalBattery",
              description["Is Present"] as? Bool ?? true,
              let current = (description["Current Capacity"] as? NSNumber)?.intValue
        else { return nil }
        let maximum = (description["Max Capacity"] as? NSNumber)?.intValue ?? 100
        level = maximum > 0 ? min(100, max(0, Int((Double(current) * 100 / Double(maximum)).rounded()))) : 0
        isOnAC = description["Power Source State"] as? String == "AC Power"
        isCharging = description["Is Charging"] as? Bool ?? false
        isCharged = description["Is Charged"] as? Bool ?? (isOnAC && !isCharging && level >= 100)
        let full = (description["Time to Full Charge"] as? NSNumber)?.intValue ?? -1
        let empty = (description["Time to Empty"] as? NSNumber)?.intValue ?? -1
        minutesToFull = isOnAC && isCharging && (1..<(24 * 60)).contains(full) ? full : nil
        minutesToEmpty = !isOnAC && (1..<(48 * 60)).contains(empty) ? empty : nil
    }

    init(level: Int, isOnAC: Bool, isCharging: Bool = false, isCharged: Bool = false,
         minutesToFull: Int? = nil, minutesToEmpty: Int? = nil) {
        self.level = level
        self.isOnAC = isOnAC
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty
    }
}

/// The user's low-battery thresholds and the critical level.
enum BatteryThresholds {
    static let defaultLow = [20, 10]
    static let defaultCritical = 5
    /// Offered in the pickers.
    static let lowChoices = [50, 40, 30, 25, 20, 15, 10]
    static let criticalChoices = [0, 3, 5, 7, 10]

    /// Distinct, 1...99, highest first, at most four.
    static func sanitize(_ values: [Int]) -> [Int] {
        Array(Set(values.filter { (1...99).contains($0) })).sorted(by: >).prefix(4).map { $0 }
    }

    /// 0 (off) or 1...25.
    static func sanitizeCritical(_ value: Int) -> Int {
        value <= 0 ? 0 : min(25, value)
    }

    /// "20 % and 10 %", "Off".
    static func summary(_ values: [Int]) -> String {
        let clean = sanitize(values)
        guard !clean.isEmpty else { return "Off" }
        let parts = clean.map { "\($0)%" }
        if parts.count == 1 { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

/// Turns a stream of readings into plug / unplug / low-battery events. Low
/// warnings fire once per threshold per discharge; plugging in re-arms them.
struct BatteryTransitionTracker {
    enum Event: Equatable {
        case pluggedIn, unplugged, low(threshold: Int)
    }

    /// The defaults; the live thresholds are `thresholds`.
    static let thresholds = BatteryThresholds.defaultLow
    var thresholds: [Int]
    private(set) var last: BatteryReading?
    private var alerted: Set<Int> = []

    init(thresholds: [Int] = BatteryTransitionTracker.thresholds) {
        self.thresholds = BatteryThresholds.sanitize(thresholds)
    }

    mutating func update(_ reading: BatteryReading) -> Event? {
        defer { last = reading }
        guard let previous = last else {
            // First reading at launch: a baseline, never a HUD.
            alerted = reading.isOnAC ? [] : passed(at: reading.level)
            return nil
        }
        if reading.isOnAC, !previous.isOnAC {
            alerted = []
            return .pluggedIn
        }
        if !reading.isOnAC, previous.isOnAC {
            // The unplug band already shows a low level in color.
            alerted = passed(at: reading.level)
            return .unplugged
        }
        guard !reading.isOnAC else { return nil }
        let crossed = passed(at: reading.level).subtracting(alerted)
        guard let lowest = crossed.min() else { return nil }
        alerted.formUnion(crossed)
        return .low(threshold: lowest)
    }

    private func passed(at level: Int) -> Set<Int> {
        Set(thresholds.filter { level <= $0 })
    }
}

/// The persistent critical alert: on battery at or under the critical level.
enum BatteryCriticalPolicy {
    static func isCritical(_ reading: BatteryReading, criticalLevel: Int) -> Bool {
        criticalLevel > 0 && !reading.isOnAC && reading.level <= criticalLevel
    }
}

enum BatteryActivityMode: Equatable, Sendable {
    case charging, charged, notCharging, onBattery, low, critical

    init(chargingReading reading: BatteryReading) {
        if reading.isCharging {
            self = .charging
        } else if reading.isCharged || reading.level >= 100 {
            self = .charged
        } else {
            // On power but held (Optimized Battery Charging or a charge limit).
            self = .notCharging
        }
    }
}

/// Why the battery isn't charging on power.
enum BatteryHoldReason: Equatable, Sendable {
    /// Optimized Battery Charging is waiting (macOS learns your routine).
    case optimized
    /// Held at a charge limit (macOS 26's limit, or one set by another app).
    case chargeLimit
    /// On power, but not charging for another reason (heat, a weak charger).
    case other

    var title: String {
        switch self {
        case .optimized: "Optimized Charging"
        case .chargeLimit: "Charge limit"
        case .other: "Not charging"
        }
    }
}

/// Battery health from the AppleSmartBattery registry entry and the IOPS
/// description. Key names differ between Intel and Apple silicon and
/// between macOS versions, so every value is optional.
struct BatteryHealthReading: Equatable, Sendable {
    enum Condition: String, Equatable, Sendable {
        case normal, serviceRecommended, unknown
    }

    var cycleCount: Int?
    var designCycleCount: Int?
    /// mAh.
    var designCapacity: Int?
    /// mAh the battery holds when full today (Apple's "nominal" capacity).
    var fullChargeCapacity: Int?
    /// Celsius.
    var temperature: Double?
    var condition: Condition
    /// ChargerData › NotChargingReason (0 = charging is allowed).
    var notChargingReason: Int?

    static let registryKeys = [
        "CycleCount", "DesignCycleCount9C", "DesignCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity",
        "MaxCapacity", "BatteryData", "Temperature", "ChargerData", "PermanentFailureStatus",
    ]

    init(cycleCount: Int? = nil, designCycleCount: Int? = nil, designCapacity: Int? = nil, fullChargeCapacity: Int? = nil,
         temperature: Double? = nil, condition: Condition = .unknown, notChargingReason: Int? = nil) {
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.temperature = temperature
        self.condition = condition
        self.notChargingReason = notChargingReason
    }

    init(registry: [String: Any], powerSource: [String: Any]?) {
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        let data = registry["BatteryData"] as? [String: Any] ?? [:]
        cycleCount = int(registry["CycleCount"]).flatMap { $0 >= 0 && $0 < 100_000 ? $0 : nil }
        designCycleCount = int(registry["DesignCycleCount9C"]) ?? int(powerSource?["DesignCycleCount"])
        designCapacity = (int(registry["DesignCapacity"]) ?? int(data["DesignCapacity"])).flatMap { $0 > 100 ? $0 : nil }
        // Apple silicon: NominalChargeCapacity (top level on older macOS, in
        // BatteryData on newer). Intel: MaxCapacity is mAh there (on Apple
        // silicon it is a percentage, so only values over 100 count).
        let maxCapacity = int(registry["MaxCapacity"]).flatMap { $0 > 100 ? $0 : nil }
        fullChargeCapacity = (int(registry["NominalChargeCapacity"]) ?? int(data["NominalChargeCapacity"])
            ?? int(registry["AppleRawMaxCapacity"]) ?? maxCapacity).flatMap { $0 > 0 ? $0 : nil }
        // Hundredths of a degree on both architectures.
        temperature = (int(registry["Temperature"]) ?? int(data["Temperature"]) ?? int(registry["VirtualTemperature"])).flatMap { raw in
            let celsius = Double(raw) / 100
            return (-20...90).contains(celsius) ? celsius : nil
        }
        notChargingReason = int((registry["ChargerData"] as? [String: Any])?["NotChargingReason"])
        let failure = int(registry["PermanentFailureStatus"]) ?? int(data["PermanentFailureStatus"]) ?? 0
        let health = (powerSource?["BatteryHealth"] as? String)?.lowercased()
        let healthCondition = (powerSource?["BatteryHealthCondition"] as? String)?.lowercased()
        condition = Self.classify(failure: failure, health: health, healthCondition: healthCondition,
                                   maximumCapacityPercent: Self.percent(full: fullChargeCapacity, design: designCapacity))
    }

    /// Only what macOS reports: a failure flag, a health string, or a
    /// maximum capacity under 80 % (where System Settings says "Service
    /// Recommended"). Apple silicon reports no health key, so a healthy
    /// battery there is `.unknown`, not a guessed "Normal".
    static func classify(failure: Int, health: String?, healthCondition: String?, maximumCapacityPercent: Int?) -> Condition {
        if failure != 0 || healthCondition?.contains("fail") == true || healthCondition?.contains("check") == true
            || healthCondition?.contains("service") == true || health == "poor" || health == "check battery" {
            return .serviceRecommended
        }
        if let percent = maximumCapacityPercent, percent < 80 { return .serviceRecommended }
        if health == "good" || healthCondition == "good" { return .normal }
        return .unknown
    }

    static func percent(full: Int?, design: Int?) -> Int? {
        guard let design, design > 0, let full else { return nil }
        let percent = (Double(full) * 100 / Double(design)).rounded(.up)
        return Int(min(100, max(1, percent)))
    }

    /// Full-charge capacity against design, as System Settings shows it
    /// ("Maximum Capacity"), rounded up like Settings rounds. Nil when either
    /// is missing.
    var maximumCapacityPercent: Int? {
        Self.percent(full: fullChargeCapacity, design: designCapacity)
    }
}

/// The external power adapter (IOPSCopyExternalPowerAdapterDetails).
struct PowerAdapterReading: Equatable, Sendable {
    var watts: Int?
    var name: String?
    var isWireless: Bool

    init(watts: Int?, name: String? = nil, isWireless: Bool = false) {
        self.watts = watts
        self.name = name
        self.isWireless = isWireless
    }

    init?(details: [String: Any]) {
        let watts = (details["Watts"] as? NSNumber)?.intValue
        let name = (details["Name"] as? String) ?? (details["Description"] as? String)
        guard watts != nil || name != nil else { return nil }
        self.watts = watts.flatMap { (1...500).contains($0) ? $0 : nil }
        self.name = name
        isWireless = (details["IsWireless"] as? NSNumber)?.boolValue ?? false
    }
}

/// Everything the Status page's battery card shows beyond the level.
struct BatteryDetails: Equatable, Sendable {
    var health: BatteryHealthReading
    var adapter: PowerAdapterReading?
    /// IOPS "Optimized Battery Charging Engaged", when macOS reports it.
    var isOptimizedChargingEngaged: Bool?
    /// IOPS "LPM Active".
    var lowPowerModeActive: Bool?

    static func optimizedFlag(in description: [String: Any]) -> Bool? {
        for key in ["Optimized Battery Charging Engaged", "OptimizedBatteryChargingEngaged"] {
            if let value = description[key] as? NSNumber { return value.boolValue }
        }
        return nil
    }

    /// Why a reading on power isn't charging; nil while it charges or is full.
    func holdReason(for reading: BatteryReading) -> BatteryHoldReason? {
        guard reading.isOnAC, !reading.isCharging, !reading.isCharged, reading.level < 100 else { return nil }
        return Self.holdReason(level: reading.level, optimized: isOptimizedChargingEngaged,
                               notChargingReason: health.notChargingReason)
    }

    /// A hold is reported only when macOS says so: the optimized flag, or a
    /// non-zero ChargerData › NotChargingReason. Right after plugging in,
    /// IOPS briefly reports "on AC, not charging" with reason 0 (or none):
    /// that is `.other` ("Not Charging"), never a made-up charge limit.
    static func holdReason(level: Int, optimized: Bool?, notChargingReason: Int?) -> BatteryHoldReason {
        if optimized == true { return .optimized }
        guard let reason = notChargingReason, reason != 0 else { return .other }
        // Charging is blocked on purpose; high in the range that is a limit
        // (macOS 26's charge limit, or another app's), lower down it is heat
        // or the charger.
        return level >= 50 ? .chargeLimit : .other
    }
}

/// Left / right / case battery for earbuds, or a single value for a headset.
struct AudioBatteries: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var `case`: Int?
    var single: Int?

    init(left: Int? = nil, right: Int? = nil, case: Int? = nil, single: Int? = nil) {
        self.left = left
        self.right = right
        self.case = `case`
        self.single = single
    }

    var isEmpty: Bool { left == nil && right == nil && self.case == nil && single == nil }

    /// Ordered (label, percent) pairs to draw. Earbud values win over the
    /// combined one when both exist.
    var items: [(label: String, percent: Int)] {
        var result: [(String, Int)] = []
        if let left { result.append(("L", left)) }
        if let right { result.append(("R", right)) }
        if let value = self.case { result.append(("Case", value)) }
        if result.isEmpty, let single { result.append(("", single)) }
        return result
    }

    var summary: String {
        isEmpty ? "(battery unknown)" : items.map { "\($0.label.isEmpty ? "" : $0.label + " ")\($0.percent)%" }.joined(separator: ", ")
    }

    /// The lowest earbud (or the single) value, for a one-number summary.
    var lowest: Int? {
        [left, right, single].compactMap { $0 }.min()
    }

    static func valid(_ value: Int, zeroIsUnknown: Bool) -> Int? {
        let lower = zeroIsUnknown ? 1 : 0
        return (lower...100).contains(value) ? value : nil
    }

    /// "85%", "85", " 85 % " -> 85.
    static func parsePercent(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return valid(number.intValue, zeroIsUnknown: false) }
        guard let text = raw as? String else { return nil }
        let digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Int(digits).flatMap { valid($0, zeroIsUnknown: false) }
    }
}

/// A connected Bluetooth audio device, as plain values.
struct BluetoothAudioDevice: Equatable, Sendable {
    var name: String
    /// Upper-case, colon-separated ("AA:BB:CC:DD:EE:FF").
    var address: String
    var batteries: AudioBatteries

    static func normalize(address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    /// SF Symbol for the device, by name.
    var symbolName: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") && !lower.contains("buds") { return "beats.headphones" }
        if lower.contains("buds") { return "earbuds" }
        return "headphones"
    }
}

struct ProfiledBluetoothDevice: Equatable, Sendable {
    var name: String
    var address: String
    var batteries: AudioBatteries
}

/// Parses `system_profiler SPBluetoothDataType -json`:
/// `{"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{"device_address":…,
/// "device_batteryLevelLeft":"80%",…}}]}]}`.
enum BluetoothProfileParser {
    static func connectedDevices(from data: Data) -> [ProfiledBluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        var devices: [ProfiledBluetoothDevice] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let properties = value as? [String: Any] else { continue }
                    let batteries = AudioBatteries(
                        left: AudioBatteries.parsePercent(properties["device_batteryLevelLeft"]),
                        right: AudioBatteries.parsePercent(properties["device_batteryLevelRight"]),
                        case: AudioBatteries.parsePercent(properties["device_batteryLevelCase"]),
                        single: AudioBatteries.parsePercent(properties["device_batteryLevelMain"])
                            ?? AudioBatteries.parsePercent(properties["device_batteryLevel"])
                    )
                    devices.append(ProfiledBluetoothDevice(
                        name: name,
                        address: BluetoothAudioDevice.normalize(address: properties["device_address"] as? String ?? ""),
                        batteries: batteries
                    ))
                }
            }
        }
        return devices
    }
}

enum PowerFormat {
    /// 45 -> "45m", 65 -> "1h 5m", 120 -> "2h".
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

// MARK: - Pure logic (END harness)
