import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI

/// One-tap keep-awake (Caffeine / Amphetamine style) through a public
/// IOKit power assertion, with a duration, a battery cutoff and "while
/// these apps run".
///
/// - The assertion is `PreventUserIdleDisplaySleep` (display and Mac stay
///   awake) or `PreventUserIdleSystemSleep` (the display may sleep), named
///   "SparkV Keep Awake…" in `pmset -g assertions`. Timed sessions also give
///   the assertion a kernel timeout, so it ends even if SparkV hangs; macOS
///   drops it when SparkV quits or crashes, and "until turned off" is never
///   restored at launch.
/// - Battery cutoff: listens to IOKit power-source notifications only while
///   a session runs.
/// - Apps: NSWorkspace launch / quit notifications.
/// - Closing the lid still sleeps a MacBook on battery: only root
///   `pmset disablesleep` can stop that, which SparkV doesn't do.
@MainActor
final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()

    static let modeKey = "keepAwake.mode"
    static let minutesKey = "keepAwake.defaultMinutes"
    static let cutoffKey = "keepAwake.batteryCutoff"
    static let appsKey = "keepAwake.apps"
    static let showsKey = "keepAwake.showsActivity"
    static let activityID = "keepAwake"
    static let endedActivityID = "keepAwake.ended"

    /// The running session, or nil while off.
    @Published private(set) var session: KeepAwakeSession?

    @Published var mode: KeepAwakeMode {
        didSet {
            guard mode != oldValue else { return }
            StatusDefaults.set(mode.rawValue, Self.modeKey)
            // Swap the assertion type in place.
            if let session { begin(until: session.until, reason: session.reason) }
        }
    }

    /// What one tap starts (nil: until turned off).
    @Published var defaultMinutes: Int? {
        didSet { StatusDefaults.set(defaultMinutes ?? 0, Self.minutesKey) }
    }

    /// End on battery at or under this level (0 = never).
    @Published var batteryCutoff: Int {
        didSet {
            StatusDefaults.set(batteryCutoff, Self.cutoffKey)
            updateBatteryWatch()
            checkBattery()
        }
    }

    /// Bundle IDs: keep awake while any of them runs.
    @Published private(set) var watchedApps: [String]

    /// Cup and time left beside the notch while on.
    @Published var showsInNotch: Bool {
        didSet {
            StatusDefaults.set(showsInNotch, Self.showsKey)
            postActivity(peek: false)
        }
    }

    var isActive: Bool { session != nil }

    private var isStarted = false
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var deadlineTask: Task<Void, Never>?
    private var powerSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// The user turned off a session an app started: stay off until that
    /// app quits.
    private var snoozedApp: String?

    private init() {
        let defaults = UserDefaults.standard
        mode = KeepAwakeMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .display
        let minutes = defaults.object(forKey: Self.minutesKey) as? Int ?? 60
        defaultMinutes = minutes > 0 ? minutes : nil
        batteryCutoff = defaults.object(forKey: Self.cutoffKey) as? Int ?? 20
        watchedApps = defaults.stringArray(forKey: Self.appsKey) ?? []
        showsInNotch = defaults.object(forKey: Self.showsKey) as? Bool ?? true
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        updateAppWatch()
        evaluateApps()
    }

    /// Releases the assertion and every observer.
    func stop() {
        isStarted = false
        end(reason: nil, announce: false)
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    // MARK: User actions

    /// One tap: on for `defaultMinutes`, or off.
    func toggle() {
        if isActive { turnOff() } else { turnOn(minutes: defaultMinutes) }
    }

    func turnOn(minutes: Int?) {
        let reading = PowerMonitor.readBattery()
        guard KeepAwakePolicy.canStart(battery: reading.map { ($0.level, !$0.isOnAC) }, cutoff: batteryCutoff) else {
            AppLog.log("Keep Awake: not started, battery at \(reading?.level ?? -1)% (cutoff \(batteryCutoff)%)")
            announce(title: "Battery under \(batteryCutoff)%", detail: "Keep Awake stays off", symbol: "battery.25percent")
            return
        }
        snoozedApp = nil
        begin(until: minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }, reason: .manual)
    }

    /// Off now. A watched app that is still running doesn't switch it back
    /// on until it quits and launches again.
    func turnOff() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        snoozedApp = KeepAwakePolicy.triggeringApp(running: running, watched: watchedApps).map(Self.appName)
        end(reason: nil, announce: false)
    }

    /// Adds time to a timed session (or starts one).
    func extend(minutes: Int) {
        guard let session else { turnOn(minutes: minutes); return }
        let base = max(Date(), session.until ?? Date())
        begin(until: session.until == nil ? nil : base.addingTimeInterval(TimeInterval(minutes * 60)), reason: session.reason)
    }

    func setWatchedApps(_ bundleIDs: [String]) {
        var seen: Set<String> = []
        watchedApps = bundleIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        StatusDefaults.set(watchedApps, Self.appsKey)
        updateAppWatch()
        evaluateApps()
    }

    func addWatchedApp(at url: URL) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        setWatchedApps(watchedApps + [bundleID])
    }

    func removeWatchedApp(_ bundleID: String) {
        setWatchedApps(watchedApps.filter { $0 != bundleID })
    }

    /// Display name for a watched bundle ID.
    static func appName(_ bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let name = running.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: Assertion

    private func begin(until: Date?, reason: KeepAwakeReason) {
        releaseAssertion()
        let type = mode == .display ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        let name: String
        switch reason {
        case .manual:
            name = until.map { "SparkV Keep Awake (until \(Self.clock.string(from: $0)))" } ?? "SparkV Keep Awake (until turned off)"
        case .app(let app):
            name = "SparkV Keep Awake (while \(app) runs)"
        }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        guard result == kIOReturnSuccess else {
            AppLog.log("Keep Awake: assertion failed (\(result))")
            session = nil
            postActivity(peek: false)
            return
        }
        assertionID = id
        hasAssertion = true
        if let until {
            // Kernel-side safety net: the assertion lapses on its own.
            let seconds = max(1, until.timeIntervalSinceNow)
            IOPMAssertionSetProperty(id, "TimeoutSeconds" as CFString, NSNumber(value: seconds))
            IOPMAssertionSetProperty(id, "TimeoutAction" as CFString, "TimeoutActionRelease" as CFString)
        }
        let wasActive = session != nil
        session = KeepAwakeSession(startedAt: session?.startedAt ?? Date(), until: until, reason: reason, mode: mode)
        AppLog.log("Keep Awake: on (\(mode.rawValue), \(until.map { "until \(Self.clock.string(from: $0))" } ?? "until off"))")
        scheduleDeadline()
        updateBatteryWatch()
        // An app starting it is news; a tap is not (the drawer is open).
        if case .app = reason, !wasActive { postActivity(peek: true) } else { postActivity(peek: false) }
    }

    private func end(reason: KeepAwakeEnd?, announce: Bool) {
        let wasActive = session != nil
        releaseAssertion()
        deadlineTask?.cancel()
        deadlineTask = nil
        session = nil
        updateBatteryWatch()
        SystemStatusCenter.shared.dismiss(id: Self.activityID)
        guard wasActive else { return }
        switch reason {
        case .expired?:
            AppLog.log("Keep Awake: time is up")
            if announce { self.announce(title: "Keep Awake ended", detail: "Your Mac can sleep again", symbol: "cup.and.saucer") }
        case .lowBattery(let level)?:
            AppLog.log("Keep Awake: ended at \(level)% battery")
            if announce { self.announce(title: "Keep Awake off", detail: "Battery at \(level)%", symbol: "battery.25percent") }
        case nil:
            AppLog.log("Keep Awake: off")
        }
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
        assertionID = 0
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let until = session?.until else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, until.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let session = self.session else { return }
            if KeepAwakePolicy.end(session, now: Date().addingTimeInterval(0.5), battery: nil, cutoff: 0) == .expired {
                self.end(reason: .expired, announce: true)
                self.evaluateApps()
            }
        }
    }

    // MARK: Battery cutoff

    private func updateBatteryWatch() {
        let wants = isActive && batteryCutoff > 0 && PowerMonitor.powerSourceDescription() != nil
        if wants, powerSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOPowerSourceCallbackType = { context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<KeepAwakeController>.fromOpaque(context).takeUnretainedValue().checkBattery()
                }
            }
            if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                powerSource = source
            }
        } else if !wants, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }
    }

    private func checkBattery() {
        guard let session, let reading = PowerMonitor.readBattery() else { return }
        if case .lowBattery(let level)? = KeepAwakePolicy.end(session, now: Date(), battery: (reading.level, !reading.isOnAC), cutoff: batteryCutoff) {
            end(reason: .lowBattery(level: level), announce: true)
        }
    }

    // MARK: Apps

    private func updateAppWatch() {
        let center = NSWorkspace.shared.notificationCenter
        if watchedApps.isEmpty || !isStarted {
            workspaceObservers.forEach { center.removeObserver($0) }
            workspaceObservers.removeAll()
            return
        }
        guard workspaceObservers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self, let bundleID, self.watchedApps.contains(bundleID) else { return }
                    self.evaluateApps()
                }
            })
        }
    }

    /// Starts or ends the app-driven session from what is running.
    private func evaluateApps() {
        guard isStarted, !watchedApps.isEmpty || session?.reason != .manual else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let trigger = KeepAwakePolicy.triggeringApp(running: running, watched: watchedApps)
        let triggerName = trigger.map(Self.appName)
        if let snoozed = snoozedApp, triggerName != snoozed { snoozedApp = nil }
        switch session?.reason {
        case .manual?:
            return
        case .app?:
            if trigger == nil { end(reason: nil, announce: false) }
        case nil:
            guard let triggerName, snoozedApp == nil else { return }
            let reading = PowerMonitor.readBattery()
            guard KeepAwakePolicy.canStart(battery: reading.map { ($0.level, !$0.isOnAC) }, cutoff: batteryCutoff) else { return }
            begin(until: nil, reason: .app(name: triggerName))
        }
    }

    // MARK: Island

    private func postActivity(peek: Bool) {
        guard let session, showsInNotch else {
            SystemStatusCenter.shared.dismiss(id: Self.activityID)
            return
        }
        let tint = KeepAwakePalette.tint
        var activity = LiveActivity(
            id: Self.activityID,
            kind: .timer,
            priority: 16,
            duration: nil,
            opensTab: SystemStatusCenter.shared.statusTab,
            symbol: "cup.and.saucer.fill",
            tint: tint
        ) {
            KeepAwakeActivityView(session: session)
        }
        .titled("Keep Awake")
        .accessibility("Keep Awake is on")
        .compact {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityLabel("Keep Awake is on")
        } trailing: {
            KeepAwakeCompactTime(until: session.until)
        }
        .minimal {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SparkVTheme.surfaceHover))
                .accessibilityLabel("Keep Awake is on")
        }
        if peek { activity = activity.peeking(on: "\(session.startedAt.timeIntervalSince1970)") }
        SystemStatusCenter.shared.post(activity)
    }

    private func announce(title: String, detail: String, symbol: String) {
        SystemStatusCenter.shared.post(LiveActivity(id: Self.endedActivityID, kind: .timer, priority: 40, duration: 3) {
            StatusBand(symbol: symbol, tint: KeepAwakePalette.tint, title: title, detail: detail)
        }
        .titled("Keep Awake"))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
