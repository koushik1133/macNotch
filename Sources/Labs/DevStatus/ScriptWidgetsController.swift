import AppKit
import SwiftUI

/// Script widgets: shell commands you add yourself, run with /bin/zsh -lc,
/// their output shown as text (xbar conventions). A command runs only after
/// you saw it and chose Run; it runs while its widget is on screen, at most
/// once per interval (60 s floor), with a timeout (30 s ceiling). A script you
/// pin to the island wings also refreshes while the drawer is closed, still
/// at its interval, and pauses while the Mac sleeps, is locked or in Low
/// Power Mode. Commands live only in this Mac's UserDefaults; nothing syncs,
/// imports or runs them from elsewhere.
@MainActor
final class ScriptWidgetsController: ObservableObject {
    static let shared = ScriptWidgetsController()

    struct RunState: Equatable {
        var output = ScriptOutput()
        var lastRun: Date?
        var isRunning = false
        var error: String?
        var exitCode: Int32 = 0
    }

    @Published private(set) var configs: [ScriptWidgetConfig]
    @Published private(set) var states: [UUID: RunState] = [:]

    var opensTab: NotchState.Tab?
    private weak var activities: ActivityCenter?
    private let defaults: UserDefaults
    private var viewers = 0
    private var viewingLoop: Task<Void, Never>?
    private var wingLoop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isPaused = false
    private var isRunning = false

    private static let storeKey = "SparkV.scripts.configs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([ScriptWidgetConfig].self, from: data) {
            configs = saved.map { $0.normalized() }
        } else {
            configs = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configs) { defaults.set(data, forKey: Self.storeKey) }
    }

    func connect(activities: ActivityCenter, opensTab: NotchState.Tab?) {
        self.activities = activities
        self.opensTab = opensTab
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(false) }
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true) }
        })
        observers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(false) }
        })
        // Low Power Mode on stops the loops; off brings them back (the
        // pinned wing script would otherwise stay stale until a re-pin).
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.setPaused(self.isPaused)
            }
        })
        restartWingLoop()
    }

    func stop() {
        isRunning = false
        viewingLoop?.cancel()
        viewingLoop = nil
        wingLoop?.cancel()
        wingLoop = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        activities?.dismiss(id: Self.wingID)
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            viewingLoop?.cancel()
            viewingLoop = nil
            wingLoop?.cancel()
            wingLoop = nil
        } else {
            if viewers > 0 { startViewingLoop() }
            restartWingLoop()
        }
    }

    private var mayRun: Bool { isRunning && !isPaused && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    // MARK: Editing (only from SparkV's own editor)

    func add(_ config: ScriptWidgetConfig) {
        var item = config.normalized()
        item.approvedCommand = nil
        configs.append(item)
        save()
    }

    func update(_ config: ScriptWidgetConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        var item = config.normalized()
        // A changed command must be confirmed again.
        if item.command != configs[index].approvedCommand { item.approvedCommand = nil }
        else { item.approvedCommand = configs[index].approvedCommand }
        configs[index] = item
        save()
        restartWingLoop()
    }

    func remove(_ id: UUID) {
        configs.removeAll { $0.id == id }
        states[id] = nil
        save()
        restartWingLoop()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard configs.indices.contains(target) else { return }
        configs.swapAt(index, target)
        save()
        restartWingLoop()
    }

    /// The user saw the command and chose Run.
    func approveAndRun(_ id: UUID) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        configs[index].approvedCommand = configs[index].command
        save()
        AppLog.log("Scripts: a script was approved to run")
        runNow(id)
        restartWingLoop()
    }

    func setShowsInWings(_ id: UUID, _ on: Bool) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        for i in configs.indices { configs[i].showsInWings = false }
        configs[index].showsInWings = on
        save()
        restartWingLoop()
    }

    // MARK: Running

    func runNow(_ id: UUID) {
        guard let config = configs.first(where: { $0.id == id }), config.isApproved else { return }
        guard states[id]?.isRunning != true else { return }
        states[id, default: RunState()].isRunning = true
        Task { [weak self] in
            let result = await ScriptRunner.run(config.command, timeout: TimeInterval(config.timeoutSeconds), outputLimit: ScriptOutput.byteLimit)
            self?.finished(id, result)
        }
    }

    private func finished(_ id: UUID, _ result: ScriptRunner.Result) {
        guard configs.contains(where: { $0.id == id }) else { return }
        var state = states[id] ?? RunState()
        state.isRunning = false
        state.lastRun = Date()
        state.exitCode = result.exitCode
        if result.timedOut {
            state.error = "Timed out"
        } else if result.exitCode != 0, result.output.isEmpty {
            state.error = result.errorOutput.isEmpty ? "Exit \(result.exitCode)" : String(ScriptOutput.stripANSI(result.errorOutput).prefix(160))
        } else {
            state.error = nil
            state.output = ScriptOutput.parse(result.output)
        }
        states[id] = state
        if configs.first(where: { $0.id == id })?.showsInWings == true { postWing() }
    }

    /// Scripts are due when never run or older than their interval.
    private func due(_ config: ScriptWidgetConfig, now: Date) -> Bool {
        guard config.isApproved else { return false }
        guard let last = states[config.id]?.lastRun else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(config.intervalSeconds)
    }

    /// Reference-counted: the Scripts page and widget cells call these.
    func beginViewing() {
        viewers += 1
        if viewers == 1 { startViewingLoop() }
    }

    func endViewing() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            viewingLoop?.cancel()
            viewingLoop = nil
        }
    }

    private func startViewingLoop() {
        viewingLoop?.cancel()
        guard mayRun else { return }
        viewingLoop = Task { [weak self] in
            while !Task.isCancelled, let self, self.mayRun {
                let now = Date()
                for config in self.configs where self.due(config, now: now) { self.runNow(config.id) }
                // Wake at the next due time (at least 5 s apart).
                let next = self.configs.filter(\.isApproved).map { config -> TimeInterval in
                    guard let last = self.states[config.id]?.lastRun else { return 5 }
                    return TimeInterval(config.intervalSeconds) - now.timeIntervalSince(last)
                }.min() ?? 60
                try? await Task.sleep(for: .seconds(max(5, next)))
            }
        }
    }

    // MARK: Wings

    private static let wingID = "scripts.wing"

    var wingScript: ScriptWidgetConfig? { configs.first { $0.showsInWings && $0.isApproved } }

    private func restartWingLoop() {
        wingLoop?.cancel()
        wingLoop = nil
        guard let config = wingScript, mayRun else {
            if wingScript == nil { activities?.dismiss(id: Self.wingID) }
            return
        }
        let id = config.id
        wingLoop = Task { [weak self] in
            while !Task.isCancelled, let self, self.mayRun, let current = self.configs.first(where: { $0.id == id }), current.showsInWings {
                if self.due(current, now: Date()) { self.runNow(id) }
                try? await Task.sleep(for: .seconds(max(ScriptWidgetConfig.minimumInterval, current.intervalSeconds)))
            }
        }
        postWing()
    }

    private func postWing() {
        guard let activities, let config = wingScript else { return }
        let headline = states[config.id]?.output.headline?.text ?? config.title
        // Whole entries only ("BTC 67k ▼1.2%", not "BTC 67k ▼1.2%  E").
        let text = ExtrasFormat.wingText(headline, limit: 18)
        activities.post(LiveActivity(id: Self.wingID, kind: .notification, priority: 14, duration: nil, opensTab: opensTab,
                                     presentation: .compact, symbol: "terminal.fill", tint: SparkVTheme.textSecondary,
                                     compactText: text) {
            ScriptWingBand(title: config.title, text: headline)
        }.compact(leading: {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
        }, trailing: {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .frame(maxWidth: 96)
                .fixedSize()
        }))
    }

    // MARK: Presets

    func addPreset(_ preset: ScriptPresets.Preset) -> ScriptWidgetConfig {
        let config = ScriptPresets.config(from: preset)
        add(config)
        return configs.last ?? config
    }
}

/// The band when the wing peeks: the script's name and its first line.
struct ScriptWingBand: View {
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}
