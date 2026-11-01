import AppKit
import Combine
import Foundation

/// The helper connection as the controller sees it (a fake in tests).
protocol FanHelperTransport: AnyObject, Sendable {
    var isInstalled: Bool { get }
    func send(_ command: FanCommand, completion: @escaping @Sendable (Result<FanHelperResponse, FanHelperClientError>) -> Void)
    func sendAndWait(_ command: FanCommand) -> Result<FanHelperResponse, FanHelperClientError>
    func disconnect()
}

extension FanHelperClient: FanHelperTransport {}

/// What the live activity shows (FanActivity.swift turns it into a LiveActivity).
struct FanActivityState: Equatable {
    var manualFans: Int
    var rpms: [Double?]
    var hottest: Double?
    var hottestName: String?
    var fahrenheit: Bool
    var failsafe: String?
}

/// Fan Control: reads fans and temperatures, follows the user's modes and
/// curves, and asks the root helper to set speeds. Auto is the default and
/// every path that loses track of SparkV (quit, crash, sleep, a hung main
/// thread, a lost helper) ends with the fans on Auto.
@MainActor
final class FanController: ObservableObject {
    static let shared = FanController()

    @Published private(set) var snapshot = FanSnapshot()
    /// The user's mode per fan, by index.
    @Published private(set) var modes: [FanControlMode] = []
    @Published private(set) var helperState: FanHelperState = .notInstalled
    @Published private(set) var helperStatus: FanHelperStatus?
    private var helperStatusDate = Date.distantPast
    /// The last problem worth showing (a refusal, a missing sensor).
    @Published private(set) var notice: String?
    @Published private(set) var activePresetID: String? = "builtin.auto"
    @Published private(set) var isInstallingHelper = false
    @Published var settings: FanSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if settings.activity != oldValue.activity { publishActivity(); updateLoop() }
            if settings.showAllSensors != oldValue.showAllSensors { tick() }
        }
    }

    /// LiveActivity hook (set by FanActivity.swift's `connect(activities:)`).
    var activitySink: ((FanActivityState?) -> Void)?

    private let sampler: FanSensorSampler
    private let helper: FanHelperTransport
    private let store: FanSettingsStore
    private let observesSystem: Bool
    private var followers: [Int: FanCurveFollower] = [:]
    private var lastSent: [Int: Double] = [:]
    private var inFlight = 0
    private var sampling = false
    private var viewers = 0
    private var started = false
    private var sleeping = false
    private var restoredModes = false
    private var loop: Task<Void, Never>?
    private var loopInterval: TimeInterval?
    private var appNapToken: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var energyObserver: NSObjectProtocol?
    private var lastActivity: FanActivityState??

    init(sampler: FanSensorSampler = FanSensorSampler(),
         helper: FanHelperTransport = FanHelperClient(),
         store: FanSettingsStore = FanUserDefaultsStore(),
         observesSystem: Bool = true) {
        self.sampler = sampler
        self.helper = helper
        self.store = store
        self.observesSystem = observesSystem
        settings = store.load()
    }

    // MARK: Read-outs

    var fans: [FanInfo] { snapshot.fans }
    var hasFans: Bool { !snapshot.fans.isEmpty }
    var presets: [FanPreset] { FanPreset.builtins + settings.customPresets }

    func name(for fan: Int) -> String {
        snapshot.fans.count == 1 ? "Fan" : "Fan \(fan + 1)"
    }

    func mode(for fan: Int) -> FanControlMode {
        modes.indices.contains(fan) ? modes[fan] : .auto
    }

    /// The helper holds this fan in manual mode right now.
    func isManual(_ fan: Int) -> Bool {
        helperStatus?.fans.first { $0.index == fan }?.manual ?? false
    }

    /// Fans under manual control (helper truth).
    var manualFanCount: Int { helperStatus?.fans.filter(\.manual).count ?? 0 }

    /// Apps that also set fan speeds. Two controllers on one fan fight
    /// (each re-asserts its own target), so SparkV stays off such fans.
    static let otherFanApps: [(bundlePrefix: String, name: String)] = [
        ("com.crystalidea.macsfancontrol", "Macs Fan Control"),
        ("com.tunabellysoftware.tgpro", "TG Pro"),
        ("eu.exelban.Stats", "Stats"),
        ("com.eidac.smcFanControl", "smcFanControl"),
        ("com.bjango.istatmenus", "iStat Menus"),
    ]

    /// The first running app from `otherFanApps` (checked at most every 10 s).
    @Published private(set) var otherFanApp: String?
    private var otherAppCheckedAt = Date.distantPast

    private func checkOtherFanApps(now: Date) {
        guard now.timeIntervalSince(otherAppCheckedAt) >= 10 else { return }
        otherAppCheckedAt = now
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let found = Self.otherFanApps.first { app in running.contains { $0.hasPrefix(app.bundlePrefix) } }?.name
        if found != otherFanApp { otherFanApp = found }
    }

    /// The fan is in manual mode, but not through SparkV's helper: another
    /// fan app holds it.
    func isControlledElsewhere(_ fan: Int) -> Bool {
        // The helper reads the SMC when it answers; whichever reading is
        // newer wins (a fan SparkV just released still shows mode 1 in the
        // previous snapshot).
        let mode: Int?
        if let status = helperStatus, helperStatusDate > snapshot.date,
           let entry = status.fans.first(where: { $0.index == fan }) {
            mode = entry.mode
        } else {
            mode = snapshot.fans.first { $0.index == fan }?.mode
        }
        guard mode == 1 else { return false }
        return !isManual(fan) && lastSent[fan] == nil
    }

    /// "Macs Fan Control is controlling Fan 1 and Fan 2", or nil.
    var conflictText: String? {
        let names = snapshot.fans.map(\.index).filter(isControlledElsewhere).map(name(for:))
        guard !names.isEmpty else { return nil }
        let who = otherFanApp ?? "Another app"
        return "\(who) controls \(names.joined(separator: " and ")). Set it to Auto there first."
    }
    var wantsManual: Bool { modes.contains { $0.isManual } }
    var failsafeText: String? { helperStatus?.failsafe }

    func temperatureText(_ celsius: Double?) -> String {
        FanFormat.temperature(celsius, fahrenheit: settings.fahrenheit)
    }

    /// Sensors for the curve picker: group summaries first, then single sensors.
    var curveSensors: [FanSensorReading] {
        snapshot.sensors.filter(\.isAggregate) + snapshot.sensors.filter { !$0.isAggregate }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        helperState = helper.isInstalled ? .notRunning : .notInstalled
        if observesSystem { observeSystem() }
        // One pass to learn the fans; then the loop runs only while needed.
        tick()
        if helper.isInstalled { send(.status) }
    }

    /// App quit: every fan back to Auto before SparkV goes.
    func stop() {
        guard started else { return }
        started = false
        loop?.cancel()
        loop = nil
        loopInterval = nil
        if helperState.canControl || wantsManual || manualFanCount > 0 {
            _ = helper.sendAndWait(.allAuto)
        }
        helper.disconnect()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let energyObserver { NotificationCenter.default.removeObserver(energyObserver) }
        energyObserver = nil
        endAppNapGuard()
        activitySink?(nil)
    }

    /// Views on screen call these so sampling runs only while something shows it.
    func attachViewer() {
        viewers += 1
        if viewers == 1 { tick() }
        updateLoop()
    }

    func detachViewer() {
        viewers = max(0, viewers - 1)
        updateLoop()
    }

    // MARK: User actions

    /// Returns false (and leaves the fan on Auto) when manual control is
    /// impossible right now; `notice` says why.
    @discardableResult
    func setMode(_ mode: FanControlMode, for fan: Int) -> Bool {
        guard snapshot.fans.indices.contains(fan) else { return false }
        let sanitized = sanitize(mode, fan: snapshot.fans[fan])
        if sanitized.isManual {
            guard helper.isInstalled else {
                notice = "Install the fan helper to set speeds. Fans stay on Auto."
                helperState = .notInstalled
                return false
            }
            guard snapshot.fans[fan].validLimits != nil else {
                notice = "\(name(for: fan)) does not report its speed limits, so it stays on Auto."
                return false
            }
            guard !isControlledElsewhere(fan) else {
                notice = "\(otherFanApp ?? "Another app") is controlling \(name(for: fan)). Set it to Auto there (or quit it) first."
                return false
            }
        }
        padModes()
        modes[fan] = sanitized
        followers[fan] = FanCurveFollower()
        lastSent[fan] = nil
        activePresetID = presets.first { $0.modes(for: snapshot.fans) == modes }?.id
        modesChanged()
        return true
    }

    func applyPreset(_ preset: FanPreset) {
        // Fans another app holds stay on Auto (SparkV never fights over a fan).
        let wanted = preset.modes(for: snapshot.fans).enumerated().map { pair in
            isControlledElsewhere(pair.offset) ? .auto : sanitize(pair.element, fan: snapshot.fans[pair.offset])
        }
        if wanted.contains(where: \.isManual), !helper.isInstalled {
            notice = "Install the fan helper to use \(preset.name). Fans stay on Auto."
            helperState = .notInstalled
            return
        }
        modes = wanted
        followers.removeAll()
        lastSent.removeAll()
        activePresetID = preset.id
        modesChanged()
    }

    func resetAllToAuto() {
        applyPreset(FanPreset.builtins[0])
        send(.allAuto)
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        padModes()
        let preset = FanPreset(id: "custom.\(UUID().uuidString)", name: String(trimmed.prefix(40)), builtin: nil, modes: modes)
        settings.customPresets.append(preset)
        activePresetID = preset.id
    }

    func deletePreset(_ id: String) {
        settings.customPresets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
    }

    /// Re-reads the helper's state (after installing or uninstalling it).
    func refreshHelper() {
        helperState = helper.isInstalled ? .notRunning : .notInstalled
        if helper.isInstalled { send(.status) } else { helperStatus = nil }
    }

    func setInstalling(_ busy: Bool) { isInstallingHelper = busy }

    func clearNotice() { notice = nil }

    func report(_ message: String) { notice = message }

    // MARK: Modes

    private func padModes() {
        if modes.count < snapshot.fans.count {
            modes += Array(repeating: .auto, count: snapshot.fans.count - modes.count)
        }
    }

    private func sanitize(_ mode: FanControlMode, fan: FanInfo) -> FanControlMode {
        switch mode {
        case .auto:
            return .auto
        case .constant(let rpm):
            guard let limits = fan.validLimits else { return .auto }
            return .constant(rpm: FanCurveMath.quantize(rpm, limits: limits))
        case .sensor(let id, let startC, let maxC):
            let curve = FanCurveMath.sanitizedCurve(startC: startC, maxC: maxC)
            return .sensor(id: id, startC: curve.startC, maxC: curve.maxC)
        }
    }

    private func modesChanged() {
        settings.lastModes = modes
        if wantsManual { notice = nil }
        updateAppNapGuard()
        updateLoop()
        tick()
    }

    // MARK: Loop

    private var desiredInterval: TimeInterval? {
        if viewers > 0 { return 1.5 }
        if wantsManual || manualFanCount > 0 { return 2 }
        // Background watching (nobody looking, Auto fans): slower in Low
        // Power Mode; a warm Mac keeps the normal pace so fan curves react.
        if settings.activity == .always, hasFans { return SparkVEnergy.shared.isLowPowerMode ? 9 : 3 }
        return nil
    }

    private func updateLoop() {
        let wanted = started ? desiredInterval : nil
        guard wanted != loopInterval else { return }
        loop?.cancel()
        loop = nil
        loopInterval = wanted
        guard let wanted else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(wanted * 1000)))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private var scope: FanSampleScope {
        if viewers > 0 { return settings.showAllSensors ? .all : .standard }
        var ids: Set<String> = ["agg.cpu.max"]
        for case .sensor(let id, _, _) in modes { ids.insert(id) }
        return .minimal(ids)
    }

    /// One sampling pass; control and the activity follow its result.
    func tick() {
        guard !sampling else { return }
        sampling = true
        sampler.sample(scope) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.sampling = false
                self.apply(snapshot)
            }
        }
    }

    /// Applies a reading (public for tests and harnesses).
    func apply(_ newSnapshot: FanSnapshot) {
        snapshot = newSnapshot
        padModes()
        if !restoredModes, !newSnapshot.fans.isEmpty {
            restoredModes = true
            if settings.restoreOnLaunch, settings.lastModes.contains(where: \.isManual), helper.isInstalled {
                modes = (0..<newSnapshot.fans.count).map { i in
                    settings.lastModes.indices.contains(i) ? sanitize(settings.lastModes[i], fan: newSnapshot.fans[i]) : .auto
                }
                activePresetID = presets.first { $0.modes(for: newSnapshot.fans) == modes }?.id
                updateAppNapGuard()
                updateLoop()
            }
        }
        checkOtherFanApps(now: newSnapshot.date)
        if !sleeping { control(now: newSnapshot.date) }
        publishActivity()
    }

    // MARK: Control

    private func control(now _: Date) {
        guard inFlight == 0 else { return }
        let helperManual = Set(helperStatus?.fans.filter(\.manual).map(\.index) ?? [])
        guard wantsManual || !helperManual.isEmpty || !lastSent.isEmpty else { return }
        guard helper.isInstalled else {
            helperState = .notInstalled
            return
        }
        var commands: [FanCommand] = []
        var problems: [String] = []
        for fan in snapshot.fans {
            let i = fan.index
            let mode = self.mode(for: i)
            var target: Double?
            switch mode {
            case .auto:
                break
            case .constant(let rpm):
                if let limits = fan.validLimits {
                    target = FanCurveMath.quantize(rpm, limits: limits)
                } else {
                    problems.append("\(name(for: i)) reports no speed limits")
                }
            case .sensor(let id, let startC, let maxC):
                if let limits = fan.validLimits, let temp = snapshot.sensor(id)?.celsius {
                    var follower = followers[i] ?? FanCurveFollower()
                    target = follower.next(temperature: temp, startC: startC, maxC: maxC, limits: limits)
                    followers[i] = follower
                } else {
                    problems.append("\(name(for: i)): sensor unavailable")
                    followers[i]?.reset()
                }
            }
            if target != nil, isControlledElsewhere(i) {
                problems.append("\(otherFanApp ?? "another app") is controlling \(name(for: i))")
                target = nil
            }
            if let target {
                if lastSent[i] != target || !helperManual.contains(i) {
                    commands.append(.setTarget(fan: i, rpm: target))
                    lastSent[i] = target
                }
            } else if helperManual.contains(i) || lastSent[i] != nil {
                commands.append(.auto(fan: i))
                lastSent[i] = nil
            }
        }
        if !problems.isEmpty { notice = problems.joined(separator: " · ") + ". SparkV leaves those fans alone." }
        // While anything is manual, every pass talks to the helper: the
        // heartbeat keeps its 10 s failsafe from firing, and its answer
        // (status) shows a failsafe or a reclaimed fan within one pass.
        if commands.isEmpty, wantsManual || !helperManual.isEmpty {
            commands.append(.heartbeat)
        }
        for command in commands { send(command) }
    }

    private func send(_ command: FanCommand) {
        inFlight += 1
        helper.send(command) { [weak self] result in
            Task { @MainActor in self?.handle(result, for: command) }
        }
    }

    private func handle(_ result: Result<FanHelperResponse, FanHelperClientError>, for command: FanCommand) {
        inFlight = max(0, inFlight - 1)
        switch result {
        case .success(let response):
            helperState = .connected
            if let status = response.status {
                helperStatus = status
                helperStatusDate = Date()
            }
            if response.ok {
                if command.takesManualControl, notice?.hasPrefix("Helper") == true { notice = nil }
            } else {
                if case .setTarget(let fan, _) = command { lastSent[fan] = nil }
                notice = response.error.map { "Fans on Auto: \($0)" }
            }
        case .failure(let error):
            helperState = error.state
            helperStatus = nil
            lastSent.removeAll()
            if wantsManual { notice = "\(error.state.title). Fans are on Auto." }
        }
        updateLoop()
        publishActivity()
    }

    // MARK: System events

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        // Low Power Mode changes the background pace (`desiredInterval`).
        energyObserver = NotificationCenter.default.addObserver(forName: SparkVEnergy.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLoop() }
        }
    }

    /// Sleep: the helper also returns fans to Auto on its own; doing it here
    /// too covers a helper that missed the power notification.
    func willSleep() {
        sleeping = true
        if wantsManual || manualFanCount > 0 { _ = helper.sendAndWait(.allAuto) }
        lastSent.removeAll()
        followers.removeAll()
        helperStatus = nil
    }

    /// Wake: wait for the SMC and thermalmonitord to settle, then re-apply.
    func didWake(delay: Duration = .seconds(5)) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.sleeping else { return }
            self.sleeping = false
            self.tick()
        }
    }

    // MARK: App Nap

    /// While SparkV controls a fan its heartbeats must not be delayed by App
    /// Nap (a late heartbeat makes the helper fall back to Auto).
    private func updateAppNapGuard() {
        if wantsManual {
            if appNapToken == nil {
                appNapToken = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "SparkV is controlling fan speeds")
            }
        } else {
            endAppNapGuard()
        }
    }

    private func endAppNapGuard() {
        if let token = appNapToken { ProcessInfo.processInfo.endActivity(token) }
        appNapToken = nil
    }

    // MARK: Live activity

    var activityState: FanActivityState? {
        guard hasFans else { return nil }
        let manual = manualFanCount
        switch settings.activity {
        case .never: return nil
        case .whileManual: if manual == 0 && failsafeText == nil { return nil }
        case .always: break
        }
        let hottest = snapshot.hottestCPU
        return FanActivityState(manualFans: manual, rpms: snapshot.fans.map(\.actual),
                                hottest: hottest?.celsius, hottestName: hottest?.group.title,
                                fahrenheit: settings.fahrenheit, failsafe: failsafeText)
    }

    private func publishActivity() {
        let state = activityState
        if let last = lastActivity, last == state { return }
        lastActivity = .some(state)
        activitySink?(state)
    }
}
