import AppKit
import Combine
import CoreBluetooth
import IOBluetooth
import IOKit.ps
import SwiftUI

/// Battery and Bluetooth-audio HUDs: a short band when the charger goes in or
/// out, low-battery warnings at 20% and 10%, and the AirPods (or any Bluetooth
/// headset) battery when one connects.
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

    /// Persisted; when false nothing is posted and nothing is monitored.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            applyEnabled(userInitiated: true)
        }
    }

    /// Bluetooth permission as last seen (for a settings row).
    @Published private(set) var bluetoothAccess: BluetoothAccess
    /// Latest internal-battery reading; nil on Macs without a battery.
    @Published private(set) var battery: BatteryReading?

    static let enabledKey = "power.isEnabled"
    static let batteryActivityID = "battery"
    static let airPodsActivityID = "airpods"

    private static let plugDuration: TimeInterval = 3
    private static let lowDuration: TimeInterval = 4
    private static let airPodsDuration: TimeInterval = 4

    private let activities: ActivityCenter
    private var isStarted = false

    // Battery
    private var runLoopSource: CFRunLoopSource?
    private var tracker = BatteryTransitionTracker()
    /// The plug-in band currently on screen, so a time-to-full estimate that
    /// arrives a moment later can fill it in.
    private var plugBand: (expires: Date, hadTime: Bool)?

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
        bluetoothAccess = Self.currentBluetoothAccess()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        bluetoothWatch = PermissionCenter.shared.onChange(of: .bluetooth) { [weak self] _ in
            guard let self else { return }
            self.bluetoothAccess = Self.currentBluetoothAccess()
            if self.bluetoothAccess == .allowed { self.startBluetooth() }
        }
        applyEnabled(userInitiated: false)
    }

    func stop() {
        isStarted = false
        bluetoothWatch = nil
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

    // MARK: - Lifecycle

    private func applyEnabled(userInitiated: Bool) {
        guard isStarted else { return }
        guard isEnabled else {
            stopMonitoring()
            return
        }
        startBattery()
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
        bluetooth?.stop()
        bluetooth = nil
        accessRequest?.cancel()
        accessRequest = nil
        lookupTask?.cancel()
        lookupTask = nil
        plugBand = nil
        shownAudioAddress = nil
        activities.dismiss(id: Self.batteryActivityID)
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
        tracker = BatteryTransitionTracker()
        powerSourcesChanged()
    }

    private func powerSourcesChanged() {
        guard isEnabled, runLoopSource != nil else { return }
        let reading = Self.readBattery()
        if battery != reading { battery = reading }
        guard let reading else { return }

        switch tracker.update(reading) {
        case .pluggedIn:
            AppLog.log("Power: plugged in at \(reading.level)%")
            postBattery(reading, mode: BatteryActivityMode(chargingReading: reading), duration: Self.plugDuration)
            plugBand = (Date().addingTimeInterval(Self.plugDuration), reading.minutesToFull != nil)
        case .unplugged:
            AppLog.log("Power: unplugged at \(reading.level)%")
            plugBand = nil
            postBattery(reading, mode: .onBattery, duration: Self.plugDuration)
        case .low(let threshold):
            AppLog.log("Power: low battery \(reading.level)% (threshold \(threshold)%)")
            plugBand = nil
            postBattery(reading, mode: .low, duration: Self.lowDuration)
        case nil:
            // The charger estimate usually lands a second after plugging in.
            if let band = plugBand, !band.hadTime, reading.isOnAC, reading.minutesToFull != nil {
                let remaining = band.expires.timeIntervalSinceNow
                if remaining > 0.5 {
                    postBattery(reading, mode: BatteryActivityMode(chargingReading: reading), duration: remaining)
                    plugBand = (band.expires, true)
                }
            }
        }
    }

    private func postBattery(_ reading: BatteryReading, mode: BatteryActivityMode, duration: TimeInterval) {
        activities.post(LiveActivity(
            id: Self.batteryActivityID,
            kind: .battery,
            priority: 50,
            duration: duration
        ) {
            BatteryActivityView(reading: reading, mode: mode)
        })
    }

    /// The internal battery from IOKit power sources, or nil without one.
    private static func readBattery() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            if let reading = BatteryReading(description: description) { return reading }
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
        guard shownAudioAddress == address else { return }
        lookupTask?.cancel()
        lookupTask = nil
        shownAudioAddress = nil
        activities.dismiss(id: Self.airPodsActivityID)
    }

    private func postAirPods(_ device: BluetoothAudioDevice, duration: TimeInterval) {
        shownAudioAddress = device.address
        activities.post(LiveActivity(
            id: Self.airPodsActivityID,
            kind: .airPods,
            priority: 55,
            duration: duration
        ) {
            AirPodsActivityView(device: device)
        })
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

    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
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

/// Turns a stream of readings into plug / unplug / low-battery events. Low
/// warnings fire once per threshold per discharge; plugging in re-arms them.
struct BatteryTransitionTracker {
    enum Event: Equatable {
        case pluggedIn, unplugged, low(threshold: Int)
    }

    static let thresholds = [20, 10]
    private(set) var last: BatteryReading?
    private var alerted: Set<Int> = []

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
        Set(Self.thresholds.filter { level <= $0 })
    }
}

enum BatteryActivityMode: Equatable, Sendable {
    case charging, charged, notCharging, onBattery, low

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
