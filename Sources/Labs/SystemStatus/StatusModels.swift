import CoreGraphics
import Foundation

// Pure logic for the System Status package (peripheral batteries, privacy
// indicators, keep awake, connectivity alerts, mic mute, Caps Lock, quick
// toggles). Foundation and CoreGraphics only, so the test harness compiles
// this file alone.

// MARK: - Peripheral batteries

enum PeripheralKind: String, Sendable, Codable, CaseIterable {
    case mouse, keyboard, trackpad, gameController, pencil, headset, other

    var symbol: String {
        switch self {
        case .mouse: "magicmouse.fill"
        case .keyboard: "keyboard.fill"
        case .trackpad: "rectangle.and.hand.point.up.left.fill"
        case .gameController: "gamecontroller.fill"
        case .pencil: "applepencil"
        case .headset: "headphones"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    var title: String {
        switch self {
        case .mouse: "Mouse"
        case .keyboard: "Keyboard"
        case .trackpad: "Trackpad"
        case .gameController: "Controller"
        case .pencil: "Pencil"
        case .headset: "Headset"
        case .other: "Device"
        }
    }

    /// By product name ("Magic Mouse", "Magic Keyboard with Touch ID",
    /// "Magic Trackpad", "DualSense Wireless Controller").
    static func classify(product: String) -> PeripheralKind {
        let name = product.lowercased()
        if name.contains("trackpad") { return .trackpad }
        if name.contains("mouse") { return .mouse }
        if name.contains("keyboard") { return .keyboard }
        if name.contains("controller") || name.contains("gamepad") || name.contains("dualsense")
            || name.contains("dualshock") || name.contains("xbox") || name.contains("joy-con") { return .gameController }
        if name.contains("pencil") { return .pencil }
        if name.contains("headset") || name.contains("headphone") { return .headset }
        return .other
    }
}

/// One battery-powered peripheral, as plain values.
struct PeripheralBattery: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case hid, gameController }

    /// Stable across reconnects: Bluetooth address, serial, or the product name.
    var id: String
    var name: String
    var kind: PeripheralKind
    /// 0...100, nil when the device doesn't say.
    var percent: Int?
    var isCharging: Bool
    var source: Source

    init(id: String, name: String, kind: PeripheralKind, percent: Int?, isCharging: Bool = false, source: Source = .hid) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percent = percent
        self.isCharging = isCharging
        self.source = source
    }

    /// For bands: "Magic Keyboard with Touch ID" → "Magic Keyboard".
    var bandName: String {
        guard let range = name.range(of: " with ") else { return name }
        return String(name[..<range.lowerBound])
    }

    /// For narrow lists: "Magic Keyboard with Touch ID" → "Keyboard".
    var shortName: String { PeripheralBattery.shortName(name, kind: kind) }

    /// Drops an owner ("Ann's "), "Magic ", "with …" and "Wireless"; falls
    /// back to the kind's name when it is still long.
    static func shortName(_ name: String, kind: PeripheralKind, limit: Int = 14) -> String {
        var short = name
        for apostrophe in ["’s ", "'s "] {
            if let range = short.range(of: apostrophe) { short = String(short[range.upperBound...]) }
        }
        if short.hasPrefix("Magic ") { short = String(short.dropFirst("Magic ".count)) }
        if let range = short.range(of: " with ") { short = String(short[..<range.lowerBound]) }
        short = short.replacingOccurrences(of: "Wireless ", with: "").trimmingCharacters(in: .whitespaces)
        if short.isEmpty || short.count > limit { return kind == .other && !name.isEmpty && name.count <= limit ? name : kind.title }
        return short.prefix(1).uppercased() + short.dropFirst()
    }
}

/// Reads AppleDeviceManagementHIDEventService property dictionaries. The
/// keys are undocumented and differ on older and USB-C peripherals, so a
/// missing key means "unknown", never zero.
enum PeripheralRegistryParser {
    /// Registry keys read per service (single-key reads, no full dump).
    static let keys = ["Product", "BatteryPercent", "BatteryStatusFlags", "DeviceAddress", "SerialNumber", "Built-In", "Transport"]

    static func battery(from properties: [String: Any], registryID: UInt64) -> PeripheralBattery? {
        if (properties["Built-In"] as? NSNumber)?.boolValue == true { return nil }
        guard let raw = (properties["BatteryPercent"] as? NSNumber)?.intValue else { return nil }
        let product = (properties["Product"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = product.isEmpty ? "Accessory" : product
        let address = (properties["DeviceAddress"] as? String).map { $0.uppercased().replacingOccurrences(of: "-", with: ":") }
        let serial = properties["SerialNumber"] as? String
        let id = [address, serial].compactMap { $0 }.first { !$0.isEmpty } ?? (product.isEmpty ? "hid.\(registryID)" : "product.\(product)")
        // BatteryStatusFlags 3 = on its cable (charging) on Magic devices.
        let flags = (properties["BatteryStatusFlags"] as? NSNumber)?.intValue
        return PeripheralBattery(
            id: id, name: name, kind: .classify(product: name),
            percent: (0...100).contains(raw) ? raw : nil,
            isCharging: flags == 3, source: .hid
        )
    }

    /// One entry per device (a keyboard exposes several HID services), the
    /// lowest-percent copy winning, sorted by kind then name.
    static func dedupe(_ devices: [PeripheralBattery]) -> [PeripheralBattery] {
        var byID: [String: PeripheralBattery] = [:]
        for device in devices {
            if let existing = byID[device.id] {
                if (device.percent ?? 101) < (existing.percent ?? 101) { byID[device.id] = device }
            } else {
                byID[device.id] = device
            }
        }
        let order = PeripheralKind.allCases
        return byID.values.sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.kind) ?? 0
            let r = order.firstIndex(of: rhs.kind) ?? 0
            return l == r ? lhs.name < rhs.name : l < r
        }
    }

    /// GameController's 0...1 level, or nil for an unknown level.
    static func percent(fromLevel level: Float) -> Int? {
        guard level.isFinite, level >= 0 else { return nil }
        return Int((min(1, max(0, level)) * 100).rounded())
    }
}

/// Low-battery alerts per device: once per discharge. A device re-arms when
/// it charges or climbs 10 points above the threshold.
struct PeripheralLowTracker {
    var threshold: Int
    private(set) var alerted: Set<String> = []

    init(threshold: Int) { self.threshold = threshold }

    /// True when `device` should alert now.
    mutating func update(_ device: PeripheralBattery, isBaseline: Bool = false) -> Bool {
        guard threshold > 0, let percent = device.percent else { return false }
        if device.isCharging || percent >= threshold + 10 {
            alerted.remove(device.id)
            return false
        }
        guard percent <= threshold, !alerted.contains(device.id) else { return false }
        alerted.insert(device.id)
        return !isBaseline
    }

    mutating func forget(_ id: String) { alerted.remove(id) }
}

// MARK: - Privacy indicators

/// An app (or process) using a sensor.
struct PrivacyApp: Equatable, Hashable, Sendable {
    var name: String
    var bundleID: String?
    var pid: Int32?

    init(name: String, bundleID: String? = nil, pid: Int32? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

/// One CoreAudio process object running input, as plain values.
struct PrivacyAudioProcess: Equatable, Sendable {
    var pid: Int32
    var bundleID: String?
    /// The outermost .app the executable lives in (helpers name their app).
    var ownerBundleID: String?
    var executable: String
    var isRunningInput: Bool
}

/// What is in use right now.
struct PrivacySnapshot: Equatable, Sendable {
    var microphone: [PrivacyApp] = []
    /// The input device runs but no process could be named (older macOS).
    var microphoneUnattributed = false
    var camera = false
    /// Inferred: no public API names the app that holds the camera.
    var cameraLikelyApp: PrivacyApp?
    var screen = false
    var screenApp: String?

    static let idle = PrivacySnapshot()

    var micInUse: Bool { !microphone.isEmpty || microphoneUnattributed }
    var isIdle: Bool { !micInUse && !camera && !screen }

    /// Sensors in use, in the order the dots are drawn (camera green first,
    /// like macOS; then the orange mic; then screen).
    var sensors: [PrivacySensor] {
        var result: [PrivacySensor] = []
        if camera { result.append(.camera) }
        if micInUse { result.append(.microphone) }
        if screen { result.append(.screen) }
        return result
    }

    /// The app to show beside the dots: the mic app, else the camera's guess,
    /// else the sharer.
    var leadApp: PrivacyApp? {
        microphone.first ?? cameraLikelyApp ?? screenApp.map { PrivacyApp(name: $0) }
    }

    /// "Microphone · Zoom", "Camera & Microphone · FaceTime",
    /// "Camera · likely Zoom", "Screen shared · Teams".
    var headline: String {
        let names = sensors.map(\.title)
        let label: String
        switch names.count {
        case 0: return "Nothing in use"
        case 1: label = names[0]
        case 2: label = "\(names[0]) & \(names[1])"
        default: label = names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
        }
        if let mic = microphone.first {
            let more = microphone.count > 1 ? " +\(microphone.count - 1)" : ""
            return "\(label) · \(mic.name)\(more)"
        }
        if camera, let guess = cameraLikelyApp { return "\(label) · likely \(guess.name)" }
        if screen, let app = screenApp { return "\(label) · \(app)" }
        return label
    }

    /// True when `self` adds a sensor or an app that `previous` didn't have
    /// (what makes the band peek again; something stopping doesn't).
    func adds(over previous: PrivacySnapshot) -> Bool {
        if !Set(sensors).isSubset(of: Set(previous.sensors)) { return true }
        let before = Set(previous.microphone.map(\.name))
        return microphone.contains { !before.contains($0.name) }
    }
}

enum PrivacySensor: String, Sendable, Hashable {
    case camera, microphone, screen

    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screen: "Screen shared"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screen: "rectangle.inset.filled.on.rectangle"
        }
    }
}

enum PrivacyAttribution {
    /// System helpers that hold the input for their own reasons and that
    /// macOS doesn't flag with the orange dot either.
    static let ignoredExecutables: Set<String> = [
        "corespeechd", "coreaudiod", "audiomxd", "SpeechRecognitionCore", "siriactionsd", "assistantd",
        "AudioComponentRegistrar", "heard", "systemsoundserverd",
    ]

    /// Folds processes into apps: helpers count as their app, SparkV's own
    /// process (dictation, meeting notes, Clicky) and system helpers drop out.
    static func microphoneApps(
        _ processes: [PrivacyAudioProcess],
        ownPID: Int32,
        ownBundleID: String?,
        name: (PrivacyAudioProcess) -> PrivacyApp
    ) -> [PrivacyApp] {
        var seen: Set<String> = []
        var result: [PrivacyApp] = []
        for process in processes where process.isRunningInput && process.pid != ownPID {
            if let own = ownBundleID, process.bundleID == own || process.ownerBundleID == own { continue }
            if ignoredExecutables.contains(process.executable) { continue }
            let app = name(process)
            let key = app.bundleID ?? app.name
            guard seen.insert(key).inserted else { continue }
            result.append(app)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The camera's likely user: an app on the mic (a call), else the front
    /// app (never SparkV).
    static func cameraGuess(micApps: [PrivacyApp], frontmost: PrivacyApp?, ownBundleID: String?) -> PrivacyApp? {
        if let call = micApps.first { return call }
        guard let front = frontmost, front.bundleID == nil || front.bundleID != ownBundleID else { return nil }
        return front
    }
}

// MARK: - Keep awake

enum KeepAwakeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Display and Mac stay awake (Caffeine / Amphetamine default).
    case display
    /// The Mac stays awake; the display may sleep (downloads, renders).
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Keep the Display On"
        case .system: "Keep the Mac Awake, Let the Display Sleep"
        }
    }
}

/// Offered durations, in minutes; nil is "until I turn it off".
enum KeepAwakeDurations {
    static let choices: [Int?] = [15, 30, 60, 120, 240, nil]

    static func title(_ minutes: Int?) -> String {
        guard let minutes else { return "Until Turned Off" }
        if minutes < 60 { return "\(minutes) Minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 Hour" : "\(hours) Hours"
    }

    static func short(_ minutes: Int?) -> String {
        guard let minutes else { return "∞" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }
}

/// Why keep-awake is on.
enum KeepAwakeReason: Equatable, Sendable {
    case manual
    /// One of the chosen apps is running.
    case app(name: String)
}

struct KeepAwakeSession: Equatable, Sendable {
    var startedAt: Date
    /// Nil: until turned off (or the app condition ends).
    var until: Date?
    var reason: KeepAwakeReason
    var mode: KeepAwakeMode
}

enum KeepAwakeEnd: Equatable, Sendable {
    case expired
    case lowBattery(level: Int)
}

enum KeepAwakePolicy {
    /// Battery cutoff choices (0 = never).
    static let cutoffChoices = [0, 10, 20, 30, 50]

    /// Whether a running session should end now.
    static func end(_ session: KeepAwakeSession, now: Date, battery: (level: Int, onBattery: Bool)?, cutoff: Int) -> KeepAwakeEnd? {
        if let until = session.until, until <= now { return .expired }
        if cutoff > 0, let battery, battery.onBattery, battery.level <= cutoff { return .lowBattery(level: battery.level) }
        return nil
    }

    /// May a session start at all (a manual start below the cutoff on
    /// battery would end at once)?
    static func canStart(battery: (level: Int, onBattery: Bool)?, cutoff: Int) -> Bool {
        guard cutoff > 0, let battery, battery.onBattery else { return true }
        return battery.level > cutoff
    }

    /// The first watched app that is running, by the watched order.
    static func triggeringApp(running: Set<String>, watched: [String]) -> String? {
        watched.first { running.contains($0) }
    }
}

// MARK: - Connectivity

enum NetworkInterfaceKind: String, Sendable, Equatable {
    case wifi, ethernet, cellular, other, none

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .cellular: "Cellular"
        case .other: "Network"
        case .none: "No network"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "network"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .other: "network"
        case .none: "wifi.slash"
        }
    }
}

/// One NWPath update plus the tunnel scan, as plain values.
struct NetworkObservation: Equatable, Sendable {
    var isOnline: Bool
    var interface: NetworkInterfaceKind
    var isExpensive: Bool
    /// Active tunnel interfaces (utun, ipsec, ppp…) with a routable address.
    var tunnels: Set<String>

    init(isOnline: Bool, interface: NetworkInterfaceKind, isExpensive: Bool = false, tunnels: Set<String> = []) {
        self.isOnline = isOnline
        self.interface = interface
        self.isExpensive = isExpensive
        self.tunnels = tunnels
    }

    /// iPhone Personal Hotspot over Wi-Fi marks the path expensive.
    var isHotspot: Bool { isOnline && interface == .wifi && isExpensive }
}

enum ConnectivityEvent: Equatable, Sendable {
    case offline
    case online(NetworkInterfaceKind)
    case vpnConnected
    case vpnDisconnected
    case hotspot
    case driveEjected(name: String)
    case driveRemovedUnsafely(name: String)
}

/// Turns path updates into alerts: the first update is a baseline; going
/// offline must last `offlineDelay` before it alerts (Wi-Fi roaming blips);
/// nothing alerts within `wakeGrace` of waking; "Back online" only follows
/// an offline alert.
struct ConnectivityTracker {
    var offlineDelay: TimeInterval = 4
    var wakeGrace: TimeInterval = 10

    private(set) var last: NetworkObservation?
    private(set) var offlineSince: Date?
    private(set) var announcedOffline = false
    private var wokeAt: Date?
    /// Between `noteSleep()` and `noteWake(at:)`: nothing is armed.
    private(set) var isAsleep = false

    init(offlineDelay: TimeInterval = 4, wakeGrace: TimeInterval = 10) {
        self.offlineDelay = offlineDelay
        self.wakeGrace = wakeGrace
    }

    /// The Mac is going to sleep: drop a pending offline alert, so a
    /// deadline armed just before sleep can't fire on wake.
    mutating func noteSleep() {
        isAsleep = true
        offlineSince = nil
    }

    /// Awake again. Still offline: re-armed from now, so it can only alert
    /// after the wake grace (and only if it is still offline then).
    mutating func noteWake(at now: Date) {
        isAsleep = false
        wokeAt = now
        if last?.isOnline == false, !announcedOffline { offlineSince = now }
    }

    func isInWakeGrace(_ now: Date) -> Bool {
        guard let wokeAt else { return false }
        return now.timeIntervalSince(wokeAt) < wakeGrace
    }

    /// Events for a new observation. Call `tick(now:)` when `nextDeadline`
    /// passes.
    mutating func update(_ observation: NetworkObservation, at now: Date) -> [ConnectivityEvent] {
        defer { last = observation }
        if isAsleep { return [] }
        guard let previous = last else {
            if !observation.isOnline { offlineSince = now }
            return []
        }
        var events: [ConnectivityEvent] = []
        let quiet = isInWakeGrace(now)

        if observation.isOnline {
            offlineSince = nil
            if announcedOffline {
                announcedOffline = false
                events.append(.online(observation.interface))
            }
        } else if previous.isOnline || offlineSince == nil {
            offlineSince = now
        }

        if observation.isOnline, !quiet {
            let hadTunnel = !previous.tunnels.isEmpty
            let hasTunnel = !observation.tunnels.isEmpty
            if hasTunnel, !hadTunnel { events.append(.vpnConnected) }
            if !hasTunnel, hadTunnel, previous.isOnline { events.append(.vpnDisconnected) }
            if observation.isHotspot, !previous.isHotspot { events.append(.hotspot) }
        }
        return events
    }

    /// When the pending offline alert is due (offline delay, or the end of
    /// the wake grace, whichever is later).
    var nextDeadline: Date? {
        guard !isAsleep, let since = offlineSince, !announcedOffline else { return nil }
        var due = since.addingTimeInterval(offlineDelay)
        if let wokeAt { due = max(due, wokeAt.addingTimeInterval(wakeGrace)) }
        return due
    }

    mutating func tick(now: Date) -> [ConnectivityEvent] {
        guard let due = nextDeadline, now >= due.addingTimeInterval(-0.05), last?.isOnline == false else { return [] }
        announcedOffline = true
        return [.offline]
    }
}

/// Ejected or pulled? A requested unmount or eject goes through
/// DiskArbitration's approval callbacks first (always before the unmount
/// itself); a drive yanked out never does. So the answer does not depend
/// on which notification lands first:
/// - requested → "ejected · safe to remove";
/// - not requested and the disk is still there (a bare `umount`) → safe;
/// - not requested and the disk disappeared → "removed without ejecting".
/// Entries are keyed by BSD name, which macOS reuses (disk4 …), so a mount
/// clears them and they expire after `window`.
struct DriveRemovalTracker {
    enum Outcome: Equatable, Sendable { case ejected, removedUnsafely }

    var window: TimeInterval = 30
    private(set) var requested: [String: Date] = [:]
    private(set) var disappeared: [String: Date] = [:]

    init(window: TimeInterval = 30) { self.window = window }

    /// "disk4s1" → "disk4".
    static func wholeDisk(_ bsd: String) -> String {
        guard let range = bsd.range(of: #"^disk\d+"#, options: .regularExpression) else { return bsd }
        return String(bsd[range])
    }

    mutating func noteMounted(_ bsd: String) {
        let whole = Self.wholeDisk(bsd)
        for key in [bsd, whole] {
            requested[key] = nil
            disappeared[key] = nil
        }
    }

    /// An unmount or eject approval for `bsd` (partition or whole disk).
    mutating func noteRequested(_ bsd: String, at now: Date) {
        prune(now)
        requested[bsd] = now
    }

    mutating func noteDisappeared(_ bsd: String, at now: Date) {
        prune(now)
        disappeared[bsd] = now
    }

    /// Decide for a volume on `bsd` that unmounted at `unmountedAt`
    /// (call a moment later, so a pull's disappearance has landed).
    func outcome(for bsd: String?, unmountedAt: Date, now: Date) -> Outcome {
        guard let bsd else { return .ejected }
        let keys = [bsd, Self.wholeDisk(bsd)]
        let recent: (Date) -> Bool = { date in
            date >= unmountedAt.addingTimeInterval(-window) && date <= now.addingTimeInterval(1)
        }
        if keys.contains(where: { requested[$0].map(recent) == true }) { return .ejected }
        // Only a disappearance near the unmount counts as a pull.
        let near: (Date) -> Bool = { date in abs(date.timeIntervalSince(unmountedAt)) <= 3 || (date >= unmountedAt && date <= now) }
        if keys.contains(where: { disappeared[$0].map(near) == true }) { return .removedUnsafely }
        return .ejected
    }

    private mutating func prune(_ now: Date) {
        requested = requested.filter { now.timeIntervalSince($0.value) < window * 2 }
        disappeared = disappeared.filter { now.timeIntervalSince($0.value) < window * 2 }
    }
}

/// One interface address from getifaddrs, as plain values.
struct InterfaceAddress: Equatable, Sendable {
    var name: String
    var isIPv4: Bool
    var address: String
    var isUp: Bool
}

enum TunnelInterfaceFilter {
    static let prefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "zt"]

    /// Tunnels that carry a VPN: up, with an IPv4 address (not link-local)
    /// or a global IPv6. macOS's own utun0-3 (iCloud Private Relay, Back to
    /// My Mac) only have fe80:: addresses, so they drop out.
    static func activeTunnels(_ addresses: [InterfaceAddress]) -> Set<String> {
        var result: Set<String> = []
        for entry in addresses where entry.isUp && prefixes.contains(where: { entry.name.hasPrefix($0) }) {
            let address = entry.address.lowercased()
            if entry.isIPv4 {
                if address.hasPrefix("169.254.") || address.isEmpty { continue }
            } else if address.hasPrefix("fe80") || address.isEmpty || address == "::1" {
                continue
            }
            result.insert(entry.name)
        }
        return result
    }
}

// MARK: - Microphone mute

/// What SparkV changed to mute the mic, saved so a crash can't leave the
/// microphone silently dead: the next launch puts it back.
struct MicMuteRecord: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable { case mute, volume }
    var deviceUID: String
    var method: Method
    /// Per-channel input volumes before muting (volume method only).
    var savedVolumes: [Int: Float]
    var at: Date

    static let defaultsKey = "micMute.record"

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data?) -> MicMuteRecord? {
        data.flatMap { try? JSONDecoder().decode(MicMuteRecord.self, from: $0) }
    }
}

/// Pure rules for reading and lifting a mic mute (tested).
enum MicMutePolicy {
    /// Muted when every mute element reads on, or, on devices without a
    /// mute, when every input volume is at zero. Unreadable elements count
    /// as unmuted / full volume, so a flaky read never shows "Muted".
    static func isMuted(mute: [UInt32?], volume: [Float?]) -> Bool {
        if !mute.isEmpty { return mute.allSatisfy { ($0 ?? 0) != 0 } }
        guard !volume.isEmpty else { return false }
        return volume.allSatisfy { ($0 ?? 1) <= 0.001 }
    }

    /// The level to put back: what was saved, or 0.75 when nothing usable
    /// was saved (a volume saved at zero would leave the mic dead).
    static func restoredVolume(saved: Float?) -> Float {
        guard let saved, saved > 0.001 else { return 0.75 }
        return min(1, saved)
    }
}

// MARK: - Quick toggles

enum QuickToggleKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case keepAwake, micMute, darkMode, desktopIcons, nightShift, airPods, lowPower, screenSaver

    var id: String { rawValue }

    /// For settings and VoiceOver.
    var longTitle: String {
        switch self {
        case .keepAwake: "Keep Awake"
        case .micMute: "Mute Microphone"
        case .darkMode: "Dark Mode"
        case .desktopIcons: "Hide Desktop Icons"
        case .nightShift: "Night Shift"
        case .airPods: "Connect AirPods"
        case .lowPower: "Low Power Mode"
        case .screenSaver: "Screen Saver"
        }
    }

    /// The tile's label (up to two short lines).
    var title: String {
        switch self {
        case .keepAwake: "Keep Awake"
        case .micMute: "Mute Mic"
        case .darkMode: "Dark Mode"
        case .desktopIcons: "Hide Icons"
        case .nightShift: "Night Shift"
        case .airPods: "AirPods"
        case .lowPower: "Low Power"
        case .screenSaver: "Screen Saver"
        }
    }

    var symbol: String {
        switch self {
        case .keepAwake: "cup.and.saucer.fill"
        case .micMute: "mic.fill"
        case .darkMode: "circle.lefthalf.filled"
        case .desktopIcons: "eye.slash.fill"
        case .nightShift: "sun.horizon.fill"
        case .airPods: "airpods"
        case .lowPower: "leaf.fill"
        case .screenSaver: "sparkles.tv"
        }
    }

    /// The glyph for a state: the mic shows "slashed" only while muted.
    func symbol(isOn: Bool) -> String {
        self == .micMute && isOn ? "mic.slash.fill" : symbol
    }

    static let defaultOrder: [QuickToggleKind] = [.keepAwake, .micMute, .darkMode, .desktopIcons, .nightShift, .airPods, .lowPower, .screenSaver]

    /// Stored raw values in order, unknown ones dropped; nil = every toggle.
    static func visible(from stored: [String]?) -> [QuickToggleKind] {
        guard let stored else { return defaultOrder }
        var seen: Set<QuickToggleKind> = []
        return stored.compactMap(QuickToggleKind.init(rawValue:)).filter { seen.insert($0).inserted }
    }
}

/// Where the wallpaper image goes inside a screen for the desktop cover,
/// following the wallpaper's own scaling.
enum DesktopCoverGeometry {
    enum Scaling: Sendable { case fill, fit, stretch, center }

    static func imageRect(image: CGSize, screen: CGSize, scaling: Scaling) -> CGRect {
        guard image.width > 0, image.height > 0, screen.width > 0, screen.height > 0 else {
            return CGRect(origin: .zero, size: screen)
        }
        switch scaling {
        case .stretch:
            return CGRect(origin: .zero, size: screen)
        case .center:
            return CGRect(x: (screen.width - image.width) / 2, y: (screen.height - image.height) / 2,
                          width: image.width, height: image.height)
        case .fill, .fit:
            let sx = screen.width / image.width
            let sy = screen.height / image.height
            let scale = scaling == .fill ? max(sx, sy) : min(sx, sy)
            let size = CGSize(width: image.width * scale, height: image.height * scale)
            return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
    }
}

// MARK: - Formatting

enum StatusFormat {
    /// Time left until `until`: "1h 05m", "12m", "<1m".
    static func remaining(until: Date, now: Date) -> String {
        let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        if seconds < 60 { return "<1m" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// Compact form for the wings: "1:05", "12m", "∞".
    static func compactRemaining(until: Date?, now: Date) -> String {
        guard let until else { return "∞" }
        let minutes = max(0, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(max(1, minutes))m" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
