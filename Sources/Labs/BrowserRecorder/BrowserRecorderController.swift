import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-step replay state shown in the step list and the graph.
enum BRStepStatus: Equatable, Sendable {
    case pending, running, done, healed, failed
}

/// Live state of the replay that is running (or the last one that finished).
struct BRReplayProgress: Equatable {
    var flowID: String
    var flowName: String
    var totalSteps: Int
    /// Ids of the steps this run executes, in order (disabled steps and,
    /// for "Replay from Here", earlier steps are left out).
    var runStepIDs: [String] = []
    var rows: Int = 1
    var row: Int = 0
    var currentIndex: Int?
    var currentStepID: String?
    var currentTitle: String = ""
    var completedInRow: Int = 0
    var statuses: [String: BRStepStatus] = [:]
    var healedCount: Int = 0
    var lastMessage: String?
    var failureScreenshot: URL?
    var finished = false
    var ok = false

    var fraction: Double {
        let total = max(1, totalSteps * rows)
        return min(1, Double(row * totalSteps + completedInRow) / Double(total))
    }

    /// 1-based position of the running step among the steps this run executes
    /// (so "3/10" never exceeds the total when disabled steps are skipped).
    var position: Int? {
        guard let currentStepID, let i = runStepIDs.firstIndex(of: currentStepID) else { return nil }
        return i + 1
    }
}

/// Values the user supplies before a replay: flow variables, maybe a CSV.
struct BRPendingRun: Identifiable, Equatable {
    let id = UUID()
    var flowID: String
    /// "Replay from Here": the first step to run (earlier steps are skipped).
    var fromStepID: String?
    var csvURL: URL?
    var csvColumns: [String] = []
    var csvRows: Int = 0
    /// Variables the user still has to fill in (not covered by CSV columns).
    var variables: [String]
    var values: [String: String]
}

/// Browser Task Recorder: records browser work once with a Playwright
/// runner (Vendor/browser-recorder), keeps it as an editable flow, and
/// replays it on demand with self-healing selectors.
///
/// Nothing ever runs on its own: recording and replay start only from a
/// button. Flows that mention purchase / payment / delete words ask first.
/// Password-like fields are never recorded (the page script masks them).
@MainActor
final class BrowserRecorderController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case replaying
        case checking
    }

    enum DetailMode: Hashable { case steps, graph }

    // Flows
    @Published private(set) var flows: [BRFlow] = []
    @Published var selectedFlowID: String?
    @Published var detailMode: DetailMode = .steps
    /// Start page for the next recording (optional).
    @Published var recordStartURL: String = ""

    // Runs
    @Published private(set) var phase: Phase = .idle
    /// Steps arriving while recording.
    @Published private(set) var liveSteps: [BRStep] = []
    @Published private(set) var progress: BRReplayProgress?
    @Published private(set) var lastError: String?
    @Published private(set) var lastNotice: String?
    /// Set when a replay needs values first; the window shows a sheet for it.
    @Published var pendingRun: BRPendingRun?
    @Published private(set) var runtimeStatus: String = ""

    /// Drawer tab the band opens when hovered (the lead sets it once the tab exists).
    var opensTab: NotchState.Tab?
    /// Called to show the editor window; defaults to the shared window controller.
    var openWindowHandler: (() -> Void)?

    static let activityID = "browserRecorder"
    static let useChromeKey = "BrowserRecorder.useInstalledChrome"
    static let autoApplyHealingKey = "BrowserRecorder.autoApplyHealing"

    nonisolated static var profileDirectory: URL {
        BrowserFlowStore.baseDirectory.appendingPathComponent("BrowserRecorder/Profile", isDirectory: true)
    }

    nonisolated static var runsDirectory: URL {
        BrowserFlowStore.baseDirectory.appendingPathComponent("BrowserRecorder/Runs", isDirectory: true)
    }

    private let activities: ActivityCenter
    private let store: BrowserFlowStore
    private var runner: BRRunnerProcess?
    private var runningFlowID: String?
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var started = false
    private var sawTerminalEvent = false
    /// The user pressed Stop: the runner may be killed, which is not an error.
    private var userStopped = false
    /// A recording's flow arrived and its "Flow saved" band is showing.
    private var recordedFlowSaved = false

    init(activities: ActivityCenter, store: BrowserFlowStore? = nil) {
        self.activities = activities
        self.store = store ?? BrowserFlowStore()
        UserDefaults.standard.register(defaults: [Self.autoApplyHealingKey: true])
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        reloadFlows()
        refreshRuntimeStatus()
        AppLog.log("BrowserRecorder: started with \(flows.count) flow(s); \(runtimeStatus)")
    }

    /// Stops any recording or replay and writes pending edits.
    func stop() {
        flushSaves()
        if phase == .recording, !liveSteps.isEmpty, !sawTerminalEvent {
            // The app is going away before the runner can send its flow: keep what arrived.
            sawTerminalEvent = true
            saveRecordedFlow(BRFlow(name: "Recording \(Self.timestamp())", steps: liveSteps))
        }
        if let runner {
            runner.stop(grace: 3)
            AppLog.log("BrowserRecorder: stopping runner on shutdown")
        }
        activities.dismiss(id: Self.activityID)
        started = false
    }

    func reloadFlows() {
        flows = store.loadAll()
        if let selectedFlowID, !flows.contains(where: { $0.id == selectedFlowID }) {
            self.selectedFlowID = flows.first?.id
        } else if selectedFlowID == nil {
            selectedFlowID = flows.first?.id
        }
    }

    var selectedFlow: BRFlow? { flows.first { $0.id == selectedFlowID } }
    var isBusy: Bool { phase != .idle }
    var runtimeAvailable: Bool { BRRunnerLocator.runnerDirectory() != nil && BRRunnerLocator.nodeExecutable() != nil }

    func openWindow() {
        if let openWindowHandler { openWindowHandler() } else { BrowserRecorderWindowController.shared.show(controller: self) }
    }

    func clearMessages() {
        lastError = nil
        lastNotice = nil
    }

    private func refreshRuntimeStatus() {
        let node = BRRunnerLocator.nodeExecutable()
        let dir = BRRunnerLocator.runnerDirectory()
        switch (node, dir) {
        case (nil, _): runtimeStatus = "Node.js not found (set BrowserRecorder.nodePath)"
        case (_, nil): runtimeStatus = "Recorder runtime missing from the app bundle"
        case (let node?, _): runtimeStatus = "Node at \(node.path)"
        }
    }

    // MARK: Runtime check (spawns node; no network)

    /// Runs `runner.mjs check`: confirms the pinned Playwright and its Chromium are installed.
    func checkRuntime() {
        guard phase == .idle else { return }
        clearMessages()
        guard launch(arguments: ["check"], phase: .checking) else { return }
    }

    // MARK: Recording

    func startRecording() {
        guard phase == .idle else { return }
        clearMessages()
        liveSteps = []
        var args = ["record", "--profile", Self.profileDirectory.path]
        let trimmed = recordStartURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
                lastError = "That start page isn't a web address."
                return
            }
            args += ["--url", url]
        }
        args += browserArguments()
        guard launch(arguments: args, phase: .recording) else { return }
        postRecordingActivity()
        AppLog.log("BrowserRecorder: recording started")
    }

    func stopRecording() {
        guard phase == .recording, let runner else { return }
        runner.stop()
    }

    // MARK: Replay

    /// Replays a flow once. Asks for variables first when it has any.
    /// With `fromStepID`, earlier steps are skipped ("Replay from Here").
    func replay(flowID: String, fromStepID: String? = nil) {
        guard phase == .idle, let flow = flows.first(where: { $0.id == flowID }) else { return }
        clearMessages()
        let variables = Self.runPart(of: flow, from: fromStepID).variables
        if variables.isEmpty {
            confirmAndRun(flowID: flowID, values: [:], csvURL: nil, fromStepID: fromStepID)
        } else {
            let defaults = flow.defaults ?? [:]
            pendingRun = BRPendingRun(
                flowID: flowID,
                fromStepID: fromStepID,
                variables: variables,
                values: Dictionary(uniqueKeysWithValues: variables.map { ($0, BRTemplate.isSecret($0) ? "" : defaults[$0] ?? "") })
            )
            if !BrowserRecorderWindowController.shared.isOpen { openWindow() }
        }
    }

    /// Picks a CSV and replays once per row; columns fill `{{header}}` variables.
    func replayWithData(flowID: String) {
        guard phase == .idle, let flow = flows.first(where: { $0.id == flowID }) else { return }
        clearMessages()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a CSV for “\(flow.name)”"
        panel.message = "The first row names the columns; each other row is one replay. Columns fill {{variables}} with the same name."
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let header = BRCSV.header(of: url), header.rows > 0 else {
            lastError = "That CSV has no data rows."
            return
        }
        let remaining = flow.variables.filter { !header.columns.contains($0) }
        let defaults = flow.defaults ?? [:]
        let run = BRPendingRun(
            flowID: flowID, csvURL: url, csvColumns: header.columns, csvRows: header.rows,
            variables: remaining,
            values: Dictionary(uniqueKeysWithValues: remaining.map { ($0, BRTemplate.isSecret($0) ? "" : defaults[$0] ?? "") })
        )
        if remaining.isEmpty {
            confirmAndRun(flowID: flowID, values: [:], csvURL: url)
        } else {
            pendingRun = run
            if !BrowserRecorderWindowController.shared.isOpen { openWindow() }
        }
    }

    /// Called by the variables sheet.
    func submitPendingRun(_ run: BRPendingRun) {
        pendingRun = nil
        // Remember non-secret values for next time.
        updateFlow(run.flowID, save: true) { flow in
            var defaults = flow.defaults ?? [:]
            for (key, value) in run.values where !BRTemplate.isSecret(key) { defaults[key] = value }
            flow.defaults = defaults
        }
        confirmAndRun(flowID: run.flowID, values: run.values, csvURL: run.csvURL, fromStepID: run.fromStepID)
    }

    func cancelPendingRun() { pendingRun = nil }

    func cancelReplay() {
        guard phase == .replaying, let runner else { return }
        userStopped = true
        runner.stop(grace: 4)
        progress?.lastMessage = "Stopping…"
    }

    /// The part of a flow a replay runs: from `stepID` on (all of it when nil).
    static func runPart(of flow: BRFlow, from stepID: String?) -> BRFlow {
        guard let stepID, let index = flow.steps.firstIndex(where: { $0.id == stepID }) else { return flow }
        var part = flow
        part.steps = Array(flow.steps[index...])
        return part
    }

    private func confirmAndRun(flowID: String, values: [String: String], csvURL: URL?, fromStepID: String? = nil) {
        guard let flow = flows.first(where: { $0.id == flowID }) else { return }
        let part = Self.runPart(of: flow, from: fromStepID)
        let words = part.riskyWords
        var allowRisky = false
        if !words.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replay “\(flow.name)”?"
            alert.informativeText = "This flow contains actions that may spend money or delete things (\(words.joined(separator: ", "))). It will run in your browser profile, signed in as you. Only continue if you expect that."
            alert.addButton(withTitle: "Replay")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else {
                AppLog.log("BrowserRecorder: risky replay of \(flow.id) cancelled")
                return
            }
            allowRisky = true
        }
        flushSave(flowID)
        let runDir = Self.runsDirectory.appendingPathComponent("\(flowID.prefix(8))-\(Self.timestamp())", isDirectory: true)
        var args = ["replay", "--flow", store.url(for: flowID).path, "--profile", Self.profileDirectory.path,
                    "--shots", runDir.path, "--vars-stdin"]
        if let csvURL { args += ["--csv", csvURL.path, "--continue-on-error"] }
        if let fromStepID, part.steps.count != flow.steps.count { args += ["--from", fromStepID] }
        if allowRisky { args.append("--allow-risky") }
        args += browserArguments()
        runningFlowID = flowID
        let enabled = part.steps.filter { !$0.isDisabled }
        progress = BRReplayProgress(flowID: flowID, flowName: flow.name, totalSteps: enabled.count,
                                    runStepIDs: enabled.map(\.id),
                                    statuses: Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, .pending) }))
        guard launch(arguments: args, phase: .replaying) else {
            progress = nil
            runningFlowID = nil
            return
        }
        // Secrets go over stdin, never on the command line.
        runner?.send(["vars": values])
        postReplayActivity()
        AppLog.log("BrowserRecorder: replay of \(flowID) started\(csvURL == nil ? "" : " with CSV")")
    }

    private func browserArguments() -> [String] {
        UserDefaults.standard.bool(forKey: Self.useChromeKey) ? ["--browser", "chrome"] : []
    }

    // MARK: Process

    @discardableResult
    private func launch(arguments: [String], phase newPhase: Phase) -> Bool {
        guard let node = BRRunnerLocator.nodeExecutable() else {
            lastError = "Node.js wasn't found. Install Node 18+ or set the BrowserRecorder.nodePath default."
            return false
        }
        guard let dir = BRRunnerLocator.runnerDirectory() else {
            lastError = "The recorder runtime (BrowserRecorder resources) is missing."
            return false
        }
        try? FileManager.default.createDirectory(at: Self.profileDirectory, withIntermediateDirectories: true)
        let process = BRRunnerProcess(
            node: node,
            script: dir.appendingPathComponent("runner.mjs"),
            arguments: arguments,
            onEvent: { [weak self] event in self?.handle(event) },
            onExit: { [weak self] status, tail in self?.runnerExited(status: status, stderrTail: tail) }
        )
        do {
            try process.start()
        } catch {
            lastError = "Couldn't start the recorder: \(error.localizedDescription)"
            AppLog.log("BrowserRecorder: launch failed: \(error)")
            return false
        }
        sawTerminalEvent = false
        userStopped = false
        recordedFlowSaved = false
        runner = process
        phase = newPhase
        return true
    }

    private func handle(_ event: BRRunnerEvent) {
        switch event.type {
        case "check":
            sawTerminalEvent = true
            lastNotice = event.ok == true
                ? "Ready: Playwright \(event.playwright ?? "?") with its Chromium."
                : "Playwright \(event.playwright ?? "?") is installed but its Chromium is missing (\(event.chromium ?? "")). Install it with: npx playwright-core install chromium"

        case "recording":
            break
        case "step":
            if let step = event.step { liveSteps.append(step) }
            postRecordingActivity()
        case "stepUpdated":
            if let step = event.step, let index = event.index, liveSteps.indices.contains(index) { liveSteps[index] = step }
        case "stepRemoved":
            if let index = event.index, liveSteps.indices.contains(index) { liveSteps.remove(at: index) }
        case "flow":
            sawTerminalEvent = true
            if let flow = event.flow { saveRecordedFlow(flow) }

        case "start":
            progress?.rows = event.rows ?? 1
        case "rowStart":
            progress?.row = event.row ?? 0
            progress?.completedInRow = 0
            if var statuses = progress?.statuses {
                for key in statuses.keys { statuses[key] = .pending }
                progress?.statuses = statuses
            }
            postReplayActivity()
        case "stepStart":
            progress?.currentIndex = event.index
            progress?.currentStepID = event.stepId
            progress?.currentTitle = event.title ?? ""
            if let id = event.stepId { progress?.statuses[id] = .running }
            postReplayActivity()
        case "retry":
            progress?.lastMessage = "Retrying (\(event.attempt ?? 1)): \(event.message ?? "")"
        case "healed":
            progress?.healedCount += 1
            if let id = event.stepId { progress?.statuses[id] = .healed }
            applyHealing(event)
        case "stepDone":
            if let id = event.stepId, progress?.statuses[id] != .healed { progress?.statuses[id] = .done }
            progress?.completedInRow += 1
            postReplayActivity()
        case "stepFailed":
            if let id = event.stepId { progress?.statuses[id] = .failed }
            progress?.lastMessage = event.message
            if let shot = event.screenshot { progress?.failureScreenshot = URL(fileURLWithPath: shot) }
        case "done":
            sawTerminalEvent = true
            progress?.finished = true
            progress?.ok = event.ok ?? false
            let rows = event.rows ?? 1
            let healed = event.healed ?? 0
            lastNotice = (event.ok ?? false)
                ? "Replayed \(rows) row\(rows == 1 ? "" : "s")\(healed > 0 ? ", healed \(healed) selector\(healed == 1 ? "" : "s")" : "")."
                : (event.stopped == true ? "Replay stopped." : "Replay failed: \(event.failedRows ?? 0) of \(rows) row(s).")
        case "stopped":
            progress?.lastMessage = event.reason == "timeLimit" ? "Stopped at the 60-minute limit." : "Stopped by you."

        case "warning":
            AppLog.log("BrowserRecorder: \(event.message ?? "")")
            progress?.lastMessage = event.message
        case "error":
            sawTerminalEvent = true
            lastError = errorText(for: event)
            AppLog.log("BrowserRecorder: runner error \(event.code ?? "") \(event.message ?? "")")
        default:
            break
        }
    }

    private func errorText(for event: BRRunnerEvent) -> String {
        switch event.code {
        case "browserMissing": "Chromium for Playwright isn't installed. Run: npx playwright-core@1.64.1 install chromium"
        case "profileInUse": "The recorder's browser profile is already open. Close that browser window and try again."
        case "missingVariables": event.message ?? "Some variables have no value."
        case "needsConfirmation": "This flow needs confirmation before replaying."
        default: event.message ?? "The recorder stopped with an error."
        }
    }

    private func runnerExited(status: Int32, stderrTail: String) {
        let previous = phase
        runner = nil
        phase = .idle
        if userStopped, previous == .replaying, !sawTerminalEvent {
            // Killed after Stop before it could report: that is what the user asked for.
            lastNotice = "Replay stopped."
            progress?.lastMessage = "Stopped by you."
        } else if !sawTerminalEvent, status != 0 {
            let detail = stderrTail.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            lastError = "The recorder quit unexpectedly: \(detail)"
            AppLog.log("BrowserRecorder: runner exited \(status): \(stderrTail)")
        }
        switch previous {
        case .recording:
            // Keep the "Flow saved" band; drop the live "Recording" one.
            if !recordedFlowSaved { activities.dismiss(id: Self.activityID) }
            if !liveSteps.isEmpty, !sawTerminalEvent {
                // The runner died before sending the flow: keep what arrived.
                saveRecordedFlow(BRFlow(name: "Recovered recording \(Self.timestamp())", steps: liveSteps))
            }
        case .replaying:
            if progress?.finished != true { progress?.finished = true }
            postReplayFinishedActivity()
            runningFlowID = nil
        default:
            break
        }
    }

    private func saveRecordedFlow(_ flow: BRFlow) {
        activities.dismiss(id: Self.activityID)
        guard !flow.steps.isEmpty else {
            lastNotice = "Nothing was recorded."
            return
        }
        var flow = flow
        flow.trigger = "manual"
        // Defense in depth: masked fields never carry a typed value.
        for index in flow.steps.indices where flow.steps[index].masked == true {
            let value = flow.steps[index].value ?? ""
            if BRTemplate.names(in: value).isEmpty { flow.steps[index].value = "{{password}}" }
        }
        store.save(flow)
        flows.insert(flow, at: 0)
        selectedFlowID = flow.id
        recordedFlowSaved = true
        lastNotice = "Saved “\(flow.name)” with \(BRTemplate.stepCount(flow.steps.count))."
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: 3, opensTab: opensTab) {
            BrowserRecorderBandView(symbol: "checkmark.circle.fill", tint: SparkVTheme.success, title: "Flow saved", detail: BRTemplate.stepCount(flow.steps.count), progress: nil)
        })
        AppLog.log("BrowserRecorder: saved recorded flow \(flow.id) (\(flow.steps.count) steps)")
    }

    /// Healenium-style write-back: the selectors that worked go first; the
    /// old ones stay behind them as fallbacks.
    private func applyHealing(_ event: BRRunnerEvent) {
        guard UserDefaults.standard.bool(forKey: Self.autoApplyHealingKey),
              let flowID = runningFlowID, let stepID = event.stepId,
              let newSelectors = event.selectors, !newSelectors.isEmpty else { return }
        updateFlow(flowID, save: true, touch: false) { flow in
            guard let index = flow.steps.firstIndex(where: { $0.id == stepID }) else { return }
            var merged: [BRSelector] = []
            for selector in newSelectors + (flow.steps[index].selectors ?? []) where !merged.contains(selector) {
                merged.append(selector)
            }
            flow.steps[index].selectors = Array(merged.prefix(12))
            if let fingerprint = event.fingerprint { flow.steps[index].fingerprint = fingerprint }
        }
        AppLog.log("BrowserRecorder: healed step \(stepID) via \(event.via ?? "?") score \(event.score.map { String(format: "%.2f", $0) } ?? "-")")
    }

    // MARK: Live activity

    private func postRecordingActivity() {
        let count = liveSteps.count
        let last = liveSteps.last?.displayTitle ?? "Use the browser window; press Stop when done"
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 75, duration: nil, opensTab: opensTab) {
            BrowserRecorderBandView(symbol: "record.circle.fill", tint: SparkVTheme.recording, title: "Recording · \(count) step\(count == 1 ? "" : "s")", detail: last, progress: nil)
        })
    }

    private func postReplayActivity() {
        guard let progress else { return }
        let step = progress.position.map { "\($0)/\(progress.totalSteps)" } ?? "–/\(progress.totalSteps)"
        let rowText = progress.rows > 1 ? " · row \(progress.row + 1)/\(progress.rows)" : ""
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: nil, opensTab: opensTab) {
            BrowserRecorderBandView(symbol: "play.circle.fill", tint: SparkVTheme.accent, title: progress.flowName, detail: progress.currentTitle,
                                    progress: progress.fraction, counter: step + rowText)
        })
    }

    private func postReplayFinishedActivity() {
        guard let progress else { activities.dismiss(id: Self.activityID); return }
        let ok = progress.ok
        let healed = progress.healedCount
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: 4, opensTab: opensTab) {
            BrowserRecorderBandView(
                symbol: ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                tint: ok ? SparkVTheme.success : SparkVTheme.warning,
                title: ok ? "\(progress.flowName) done" : "\(progress.flowName) stopped",
                detail: ok ? (healed > 0 ? "Self-healed \(healed) step\(healed == 1 ? "" : "s")" : "All steps passed") : (progress.lastMessage ?? "See the recorder window"),
                progress: nil
            )
        })
    }

    // MARK: Editing

    func updateFlow(_ id: String, save: Bool = true, touch: Bool = true, _ change: (inout BRFlow) -> Void) {
        guard let index = flows.firstIndex(where: { $0.id == id }) else { return }
        var flow = flows[index]
        change(&flow)
        guard flow != flows[index] else { return }
        if touch { flow.updatedAt = Date().timeIntervalSince1970 * 1000 }
        flows[index] = flow
        if save { scheduleSave(id) }
    }

    func updateStep(flowID: String, stepID: String, _ change: (inout BRStep) -> Void) {
        updateFlow(flowID) { flow in
            guard let index = flow.steps.firstIndex(where: { $0.id == stepID }) else { return }
            change(&flow.steps[index])
        }
    }

    func renameFlow(_ id: String, to name: String) {
        updateFlow(id) { $0.name = name }
    }

    /// Asks first, then moves the flow file to the Trash.
    func confirmDeleteFlow(_ id: String) {
        guard runningFlowID != id, let flow = flows.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(flow.name)” to the Trash?"
        alert.informativeText = "The flow (\(BRTemplate.stepCount(flow.steps.count))) goes to the Trash, where you can still recover the file."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteFlow(id)
    }

    func deleteFlow(_ id: String) {
        guard runningFlowID != id else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        store.delete(id: id)
        flows.removeAll { $0.id == id }
        if selectedFlowID == id { selectedFlowID = flows.first?.id }
    }

    func duplicateFlow(_ id: String) {
        guard let original = flows.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID().uuidString
        copy.name = original.name + " copy"
        copy.createdAt = Date().timeIntervalSince1970 * 1000
        copy.updatedAt = copy.createdAt
        copy.steps = original.steps.map { step in
            var step = step
            step.id = UUID().uuidString
            return step
        }
        store.save(copy)
        flows.insert(copy, at: 0)
        selectedFlowID = copy.id
    }

    // MARK: Import / export (flow JSON, schema 1)

    /// Writes the flow as JSON. Remembered secret values are never in it.
    func exportFlow(_ id: String) {
        flushSave(id)
        guard var flow = flows.first(where: { $0.id == id }) else { return }
        flow.defaults = flow.defaults?.filter { !BRTemplate.isSecret($0.key) }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Export “\(flow.name)”"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Self.fileName(for: flow.name) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(flow).write(to: url, options: .atomic)
            lastNotice = "Exported “\(flow.name)”."
        } catch {
            lastError = "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// Reads flow JSON files (from Export or the Flows folder) as new flows.
    func importFlows() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Import Flows"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let result = importFlows(from: panel.urls)
        if result.imported > 0 { lastNotice = "Imported \(result.imported) flow\(result.imported == 1 ? "" : "s")." }
        if result.failed > 0 { lastError = "\(result.failed) file\(result.failed == 1 ? " isn't a" : "s aren't") SparkV flow\(result.failed == 1 ? "" : "s")." }
    }

    @discardableResult
    func importFlows(from urls: [URL]) -> (imported: Int, failed: Int) {
        var imported = 0, failed = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  var flow = try? JSONDecoder().decode(BRFlow.self, from: data),
                  flow.steps.count <= 2000 else { failed += 1; continue }
            // Always a new flow: never overwrite one that is already here.
            flow.id = UUID().uuidString
            flow.trigger = "manual"
            let now = Date().timeIntervalSince1970 * 1000
            flow.updatedAt = now
            var seen = Set<String>()
            for i in flow.steps.indices where !seen.insert(flow.steps[i].id).inserted || flow.steps[i].id.isEmpty {
                flow.steps[i].id = UUID().uuidString
            }
            store.save(flow)
            flows.insert(flow, at: 0)
            selectedFlowID = flow.id
            imported += 1
        }
        return (imported, failed)
    }

    private static func fileName(for name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Flow" : String(cleaned.prefix(80))
    }

    func deleteStep(flowID: String, stepID: String) {
        updateFlow(flowID) { $0.steps.removeAll { $0.id == stepID } }
    }

    func moveStep(flowID: String, stepID: String, by offset: Int) {
        updateFlow(flowID) { flow in
            guard let index = flow.steps.firstIndex(where: { $0.id == stepID }) else { return }
            let target = index + offset
            guard flow.steps.indices.contains(target) else { return }
            flow.steps.swapAt(index, target)
        }
    }

    func moveSteps(flowID: String, from source: IndexSet, to destination: Int) {
        updateFlow(flowID) { $0.steps.move(fromOffsets: source, toOffset: destination) }
    }

    /// Inserts after `stepID`, or at the end when nil.
    func insertStep(_ step: BRStep, flowID: String, after stepID: String?) {
        updateFlow(flowID) { flow in
            if let stepID, let index = flow.steps.firstIndex(where: { $0.id == stepID }) {
                flow.steps.insert(step, at: index + 1)
            } else {
                flow.steps.append(step)
            }
        }
    }

    /// Replaces a fill step's literal value with `{{name}}`, remembering the
    /// literal as the default (unless the name looks secret).
    func makeVariable(flowID: String, stepID: String) {
        updateFlow(flowID) { flow in
            guard let index = flow.steps.firstIndex(where: { $0.id == stepID }) else { return }
            let step = flow.steps[index]
            let literal = step.value ?? ""
            guard BRTemplate.names(in: literal).isEmpty else { return }
            var name = BRTemplate.suggestedName(for: step)
            let existing = Set(flow.variables)
            var n = 2
            while existing.contains(name) { name = "\(BRTemplate.suggestedName(for: step))_\(n)"; n += 1 }
            flow.steps[index].value = "{{\(name)}}"
            if !BRTemplate.isSecret(name), step.masked != true {
                var defaults = flow.defaults ?? [:]
                defaults[name] = literal
                flow.defaults = defaults
            }
        }
    }

    func revealScreenshot() {
        guard let url = progress?.failureScreenshot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Saving

    private func scheduleSave(_ id: String) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushSave(id)
        }
    }

    private func flushSave(_ id: String) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        if let flow = flows.first(where: { $0.id == id }) { store.save(flow) }
    }

    func flushSaves() {
        for id in Array(saveTasks.keys) { flushSave(id) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
