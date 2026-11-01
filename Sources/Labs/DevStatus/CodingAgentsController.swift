import AppKit
import SwiftUI

/// Coding Agents: which Claude Code, Codex and Cursor sessions run on this
/// Mac, which wait for you and which just finished, with Allow / Deny from
/// the island for tools you point at SparkV's local hook.
///
/// Two sources, both off until you turn them on:
/// - **Session folders** (read-only): ~/.claude/sessions and ~/.claude/projects,
///   ~/.codex/sessions, ~/.cursor/projects (`AgentSessionScanner`).
/// - **Hook endpoint** (optional): HTTP on 127.0.0.1 that your own tool config
///   calls through SparkV's `agent-hook` script. SparkV shows the lines to
///   add; it never edits ~/.claude, ~/.codex or ~/.cursor.
///
/// Nothing leaves the Mac. Prompts, messages and tool input are never
/// logged or stored; an approval's command is shown only in the drawer.
@MainActor
final class CodingAgentsController: ObservableObject {
    static let shared = CodingAgentsController()

    struct PendingApproval: Identifiable, Equatable {
        let id: UUID
        let event: AgentHookEvent
        let receivedAt: Date
        let deadline: Date

        static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool { lhs.id == rhs.id }
        var title: String {
            "\(event.kind.shortTitle) wants to \(verb)"
        }

        /// "Run a command" (the agent's icon says which agent).
        var shortTitle: String {
            verb.prefix(1).uppercased() + verb.dropFirst()
        }

        private var verb: String {
            switch event.toolName {
            case "Bash"?, "Shell"?: "run a command"
            case "Edit"?, "MultiEdit"?, "Write"?, "NotebookEdit"?: "edit a file"
            case "Read"?: "read a file"
            case "WebFetch"?: "fetch a page"
            case let tool?: "use \(ToolSummary.mcpName(tool))"
            case nil: "continue"
            }
        }
    }

    /// A long shell command that finished (zsh hook).
    struct FinishedCommand: Identifiable, Equatable {
        let id = UUID()
        let event: ShellCommandEvent
        let at: Date
    }

    // MARK: Settings (UserDefaults "SparkV.agents.*")

    @Published var isEnabled: Bool { didSet { save(isEnabled, "enabled"); apply() } }
    @Published var watchClaude: Bool { didSet { save(watchClaude, "claude"); apply() } }
    @Published var watchCodex: Bool { didSet { save(watchCodex, "codex"); apply() } }
    @Published var watchCursor: Bool { didSet { save(watchCursor, "cursor"); apply() } }
    /// Opt-in: today's token count from local transcripts.
    @Published var countTokens: Bool { didSet { save(countTokens, "countTokens"); apply() } }
    @Published var hookEnabled: Bool { didSet { save(hookEnabled, "hook"); applyHook() } }
    /// Seconds an approval waits in SparkV before the tool asks on its own.
    @Published var decisionTimeout: Int { didSet { save(decisionTimeout, "decisionTimeout") } }
    @Published var playsSounds: Bool { didSet { save(playsSounds, "sounds") } }
    @Published var showsFinishedBand: Bool { didSet { save(showsFinishedBand, "finishedBand") } }
    @Published var showsWings: Bool { didSet { save(showsWings, "wings"); postSummaryActivity() } }
    @Published var longCommandsEnabled: Bool { didSet { save(longCommandsEnabled, "longCommands") } }
    @Published var longCommandSeconds: Int { didSet { save(longCommandSeconds, "longCommandSeconds") } }

    // MARK: State

    @Published private(set) var sessions: [CodingAgentSession] = []
    @Published private(set) var approvals: [PendingApproval] = []
    @Published private(set) var hookState: AgentHookServer.State = .stopped
    @Published private(set) var recentCommands: [FinishedCommand] = []
    @Published private(set) var isRunning = false

    /// Set by the integrator: the drawer tab the bands open on hover.
    var opensTab: NotchState.Tab?
    /// Set by the integrator: opens the drawer on the agents page.
    var onOpenDrawer: (() -> Void)?

    private weak var activities: ActivityCenter?
    private let defaults: UserDefaults
    private let scanner = AgentSessionScanner()
    private let server = AgentHookServer()
    private var replies: [UUID: AgentHookServer.Reply] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    /// Live state reported by hooks, newer than what the files say.
    private var hookStates: [String: (state: CodingAgentState, detail: String?, at: Date, cwd: String?, pid: Int32?)] = [:]
    private var scanned: [CodingAgentSession] = []
    private var previousStates: [String: CodingAgentState] = [:]
    private var hookToken = ""

    static let defaultPorts: [UInt16] = Array(47821...47830)
    private static let prefix = "SparkV.agents."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: Self.prefix + key) == nil ? fallback : defaults.bool(forKey: Self.prefix + key)
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: Self.prefix + key) == nil ? fallback : defaults.integer(forKey: Self.prefix + key)
        }
        isEnabled = bool("enabled", false)
        watchClaude = bool("claude", true)
        watchCodex = bool("codex", true)
        watchCursor = bool("cursor", true)
        countTokens = bool("countTokens", false)
        hookEnabled = bool("hook", false)
        decisionTimeout = min(max(int("decisionTimeout", 30), 10), 55)
        playsSounds = bool("sounds", true)
        showsFinishedBand = bool("finishedBand", true)
        showsWings = bool("wings", true)
        longCommandsEnabled = bool("longCommands", false)
        longCommandSeconds = min(max(int("longCommandSeconds", 30), 5), 3600)

        scanner.onUpdate = { [weak self] sessions in self?.scannerUpdated(sessions) }
        server.onState = { [weak self] state in self?.serverChanged(state) }
        server.onClientGone = { [weak self] id in self?.resolve(id, .ask, silently: true) }
        server.onRequest = { [weak self] request, reply in
            guard let self else { reply(status: 503); return }
            self.handle(request, reply: reply)
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }

    // MARK: Lifecycle

    /// Connects the band and wings (integrator: once, at launch).
    func connect(activities: ActivityCenter, opensTab: NotchState.Tab?) {
        self.activities = activities
        self.opensTab = opensTab
    }

    func start() {
        isRunning = true
        apply()
        applyHook()
    }

    func stop() {
        isRunning = false
        scanner.stop()
        // A later start() starts the scanner again (update() on a stopped
        // scanner is ignored).
        scannerStarted = false
        server.stop()
        removePortFile()
        for approval in approvals { resolve(approval.id, .ask, silently: true) }
        activities?.dismiss(id: Self.summaryID)
        activities?.dismiss(id: Self.approvalID)
    }

    /// Rescans now (the drawer page appeared).
    func refresh() {
        guard isRunning, isEnabled else { return }
        scanner.refresh()
    }

    private var scannerOptions: AgentSessionScanner.Options {
        .init(claude: watchClaude, codex: watchCodex, cursor: watchCursor, countTokens: countTokens)
    }

    private var scannerStarted = false

    private func apply() {
        guard isRunning else { return }
        if isEnabled {
            if scannerStarted { scanner.update(scannerOptions) } else { scanner.start(scannerOptions) }
            scannerStarted = true
        } else if scannerStarted {
            scanner.stop()
            scannerStarted = false
            scanned = []
            rebuild()
        }
    }

    // MARK: Hook endpoint

    /// SparkV's own folder: the hook script, its port and token header.
    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SparkV", isDirectory: true)
    }

    static var hookScriptURL: URL { supportFolder.appendingPathComponent("agent-hook") }
    private static var portFileURL: URL { supportFolder.appendingPathComponent("agent-hook.port") }
    private static var headerFileURL: URL { supportFolder.appendingPathComponent("agent-hook.header") }

    private func applyHook() {
        guard isRunning else { return }
        if hookEnabled {
            prepareHookFiles()
            server.start(ports: Self.defaultPorts, token: hookToken)
        } else {
            server.stop()
            removePortFile()
            for approval in approvals { resolve(approval.id, .ask, silently: true) }
        }
    }

    /// Writes the script (0755) and the token header (0600) if missing or stale.
    private func prepareHookFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        let script = Data(AgentSetupSnippets.hookScript.utf8)
        if (try? Data(contentsOf: Self.hookScriptURL)) != script {
            try? script.write(to: Self.hookScriptURL, options: .atomic)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.hookScriptURL.path)
        // Reuse a token only from a regular file this user owns, mode 0600:
        // one written loose (an old build, by hand) or swapped by another
        // process gets a fresh token through PrivateFile.
        var info = stat()
        let isPrivate = lstat(Self.headerFileURL.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && (info.st_mode & 0o777) == 0o600
        if isPrivate, let existing = try? String(contentsOf: Self.headerFileURL, encoding: .utf8),
           let token = existing.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines), token.count == 64 {
            hookToken = token
        } else {
            writeToken(AgentHTTP.makeToken())
        }
    }

    private func writeToken(_ token: String) {
        hookToken = token
        let header = Data("X-SparkV-Token: \(token)\n".utf8)
        // Never readable by others, not even for a moment: a 0600 temp
        // file renamed over the old one.
        if !PrivateFile.write(header, to: Self.headerFileURL) {
            AppLog.log("Agents: couldn't write the hook token file")
        }
    }

    /// A new token: hooks pick it up on their next run (they read the file).
    func resetToken() {
        writeToken(AgentHTTP.makeToken())
        server.updateToken(hookToken)
        AppLog.log("Agents: hook token reset")
    }

    private func removePortFile() {
        try? FileManager.default.removeItem(at: Self.portFileURL)
    }

    private func serverChanged(_ state: AgentHookServer.State) {
        hookState = state
        switch state {
        case .listening(let port):
            try? Data("\(port)\n".utf8).write(to: Self.portFileURL, options: .atomic)
            AppLog.log("Agents: hook endpoint on 127.0.0.1:\(port)")
        case .failed(let reason):
            removePortFile()
            AppLog.log("Agents: hook endpoint failed: \(reason)")
        case .stopped:
            removePortFile()
        case .starting:
            break
        }
    }

    var hookPortText: String {
        if case .listening(let port) = hookState { return "127.0.0.1:\(port)" }
        return "—"
    }

    // MARK: Requests

    private func handle(_ request: AgentHTTPRequest, reply: AgentHookServer.Reply) {
        let pid = request.headers["x-sparkv-ppid"].flatMap { Int32($0) }
        let term = request.headers["x-sparkv-term"]
        if request.path == "/v1/command" {
            reply(status: 204)
            if let event = ShellCommandEvent.parse(request.body) { commandFinished(event, callerPID: pid) }
            return
        }
        guard let event = AgentHookEvent.parse(body: request.body, source: request.headers["x-sparkv-source"],
                                               callerPID: pid, terminalProgram: term) else {
            reply(status: 400)
            return
        }
        let watchesKind: Bool = switch event.kind {
        case .claude: watchClaude
        case .codex: watchCodex
        case .cursor: watchCursor
        }
        let watching = isEnabled && watchesKind
        // Approvals still work with session watching off: the user pointed
        // the tool at SparkV.
        if event.phase == .needsApproval, event.replyStyle != .none {
            enqueueApproval(event, reply: reply)
            return
        }
        reply(status: 200)
        guard watching || hookEnabled else { return }
        record(event)
    }

    private func record(_ event: AgentHookEvent) {
        let key = event.kind.rawValue + ":" + event.sessionID
        let now = Date()
        switch event.phase {
        case .ended:
            hookStates[key] = nil
        case .started, .working:
            hookStates[key] = (.working, nil, now, event.cwd, event.callerPID)
        case .needsApproval:
            hookStates[key] = (.waiting, event.toolSummary.map { "Waiting to \($0)" } ?? "Waiting for approval", now, event.cwd, event.callerPID)
        case .needsInput:
            hookStates[key] = (.waiting, "Waiting for your input", now, event.cwd, event.callerPID)
        case .finished:
            hookStates[key] = (.finished, "Turn finished", now, event.cwd, event.callerPID)
        case .other:
            return
        }
        rebuild()
        if isEnabled { scanner.refresh() }
    }

    // MARK: Approvals

    private func enqueueApproval(_ event: AgentHookEvent, reply: AgentHookServer.Reply) {
        let id = reply.id
        let now = Date()
        let approval = PendingApproval(id: id, event: event, receivedAt: now,
                                       deadline: now.addingTimeInterval(TimeInterval(decisionTimeout)))
        approvals.append(approval)
        replies[id] = reply
        timeouts[id] = Task { @MainActor [weak self, timeout = decisionTimeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resolve(id, .ask, silently: true)
        }
        record(event)
        // Hovering the band opens the drawer right on the buttons.
        DevStatusNavigator.shared.section = .agents
        if playsSounds { NSSound(named: "Glass")?.play() }
        postApprovalActivity()
        AppLog.log("Agents: \(event.kind.shortTitle) asked for approval (\(event.toolName ?? "tool"))")
    }

    /// The user's explicit click. `.ask` hands the question back to the tool.
    func resolve(_ id: UUID, _ decision: AgentDecision, silently: Bool = false) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = approvals.remove(at: index)
        timeouts.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?(status: 200, body: approval.event.replyBody(decision))
        let key = approval.event.kind.rawValue + ":" + approval.event.sessionID
        if decision != .ask {
            hookStates[key] = (.working, nil, Date(), approval.event.cwd, approval.event.callerPID)
        }
        rebuild()
        postApprovalActivity()
        if !silently {
            AppLog.log("Agents: approval answered (\(decision.rawValue))")
        }
    }

    private static let approvalID = "agents.approval"
    private static let summaryID = "agents.summary"
    private static let finishedID = "agents.finished"
    private static let commandID = "agents.command"

    private func postApprovalActivity() {
        guard let activities else { return }
        guard let first = approvals.first else {
            activities.dismiss(id: Self.approvalID)
            return
        }
        let count = approvals.count
        let tint = SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red)
        activities.post(LiveActivity(
            id: Self.approvalID, kind: .notification, priority: 82, duration: nil,
            height: NotchMetrics.activityAnswerBandHeight, opensTab: opensTab, presentation: .expanded, urgent: true,
            symbol: "hand.raised.fill", tint: tint, compactText: count > 1 ? "\(count)" : "Allow?",
            peekKey: first.id.uuidString
        ) {
            CodingAgentApprovalBand(approval: first, queued: count - 1)
        })
    }

    // MARK: Sessions

    private func scannerUpdated(_ sessions: [CodingAgentSession]) {
        scanned = sessions
        rebuild()
    }

    private func rebuild() {
        let now = Date()
        var byID: [String: CodingAgentSession] = [:]
        for session in scanned { byID[session.id] = session }
        for (key, live) in hookStates {
            // Hook news older than 20 minutes has been superseded by the files.
            guard now.timeIntervalSince(live.at) < 20 * 60 else { hookStates[key] = nil; continue }
            if var session = byID[key] {
                if live.at >= session.updatedAt.addingTimeInterval(-2) || session.state == .idle {
                    session.state = live.state
                    session.detail = live.detail ?? session.detail
                    session.updatedAt = max(session.updatedAt, live.at)
                }
                if session.pid == nil { session.pid = live.pid }
                byID[key] = session
            } else {
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kind = CodingAgentKind(rawValue: parts[0]) else { continue }
                byID[key] = CodingAgentSession(kind: kind, sessionID: parts[1], name: nil, cwd: live.cwd, branch: nil,
                                               state: live.state, detail: live.detail, updatedAt: live.at, pid: live.pid)
            }
        }
        // Pending approvals always show their session as waiting.
        for approval in approvals {
            let key = approval.event.kind.rawValue + ":" + approval.event.sessionID
            byID[key]?.state = .waiting
            byID[key]?.detail = approval.event.toolSummary.map { "Waiting to \($0)" } ?? "Waiting for approval"
        }
        let next = CodingAgentSession.ordered(Array(byID.values))
        announceTransitions(next)
        if next != sessions { sessions = next }
        postSummaryActivity()
    }

    /// Sounds and a short band when a session starts waiting or finishes.
    private func announceTransitions(_ next: [CodingAgentSession]) {
        var states: [String: CodingAgentState] = [:]
        for session in next {
            states[session.id] = session.state
            guard let before = previousStates[session.id], before != session.state else { continue }
            if session.state == .finished, before == .working {
                if playsSounds { NSSound(named: "Ping")?.play() }
                if showsFinishedBand { postFinished(session) }
            } else if session.state == .waiting, before != .waiting, approvals.isEmpty {
                if playsSounds { NSSound(named: "Glass")?.play() }
                postWaiting(session)
            }
        }
        previousStates = states
    }

    var runningCount: Int { sessions.filter { $0.state == .working }.count }
    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count + max(0, approvals.count - sessions.filter { $0.state == .waiting }.count) }

    private func postSummaryActivity() {
        guard let activities else { return }
        let running = runningCount
        let waiting = waitingCount
        guard isRunning, showsWings, running + waiting > 0 else {
            activities.dismiss(id: Self.summaryID)
            return
        }
        let tint = waiting > 0 ? SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red) : SparkVTheme.choose(apple: Color(red: 0.85, green: 0.47, blue: 0.34), sparkv: SparkVTheme.text)
        activities.post(LiveActivity(
            id: Self.summaryID, kind: .notification, priority: 18, duration: nil, opensTab: opensTab, presentation: .compact,
            symbol: waiting > 0 ? "hand.raised.fill" : "sparkles", tint: tint,
            compactText: nil, peekKey: nil
        ) {
            CodingAgentsSummaryBand(running: running, waiting: waiting)
        }.compact(leading: {
            CodingAgentsWingLeading(waiting: waiting > 0)
        }, trailing: {
            CodingAgentsWingTrailing(running: running, waiting: waiting)
        }))
    }

    private func postFinished(_ session: CodingAgentSession) {
        activities?.post(LiveActivity(id: Self.finishedID, kind: .notification, priority: 64, duration: 4, opensTab: opensTab,
                                      symbol: "checkmark.circle.fill", tint: SparkVTheme.success) {
            CodingAgentEventBand(symbol: "checkmark.circle.fill", tint: SparkVTheme.success,
                                 title: "\(session.kind.shortTitle) finished", detail: CodingAgentsController.redacted(session.project))
        })
    }

    private func postWaiting(_ session: CodingAgentSession) {
        let tint = SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red)
        activities?.post(LiveActivity(id: Self.finishedID, kind: .notification, priority: 70, duration: 6, opensTab: opensTab,
                                      symbol: "hand.raised.fill", tint: tint) {
            CodingAgentEventBand(symbol: "hand.raised.fill", tint: tint,
                                 title: "\(session.kind.shortTitle) needs you", detail: CodingAgentsController.redacted(session.project))
        })
    }

    /// Folder names stay off the band while the screen is shared or recorded.
    static func redacted(_ text: String) -> String {
        ExtrasPrivacy.isScreenShared ? "Hidden while sharing" : text
    }

    // MARK: Long commands (zsh hook)

    private func commandFinished(_ event: ShellCommandEvent, callerPID: Int32?) {
        guard longCommandsEnabled, event.duration >= Double(longCommandSeconds) else { return }
        // Skip when the terminal it ran in is the front app: you saw it.
        if let pid = callerPID, let host = LocalProcesses.hostingApp(of: pid),
           host.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return
        }
        recentCommands.insert(FinishedCommand(event: event, at: Date()), at: 0)
        if recentCommands.count > 8 { recentCommands.removeLast(recentCommands.count - 8) }
        let ok = event.exitCode == 0
        let tint = ok ? SparkVTheme.success : SparkVTheme.destructive
        if playsSounds { NSSound(named: ok ? "Glass" : "Basso")?.play() }
        activities?.post(LiveActivity(id: Self.commandID, kind: .notification, priority: 62, duration: 5, opensTab: opensTab,
                                      symbol: ok ? "terminal.fill" : "xmark.octagon.fill", tint: tint) {
            CodingAgentEventBand(symbol: ok ? "terminal.fill" : "xmark.octagon.fill", tint: tint,
                                 title: ok ? "Finished in \(ExtrasFormat.duration(event.duration))" : "Failed (exit \(event.exitCode)) after \(ExtrasFormat.duration(event.duration))",
                                 detail: ExtrasPrivacy.isScreenShared ? "Command hidden while sharing" : event.command)
        })
    }

    // MARK: Jump

    /// Brings the terminal, IDE or app running a session to the front; with
    /// Automation consent, selects the exact Terminal or iTerm2 tab.
    func jump(to session: CodingAgentSession) {
        if let pid = session.pid, let app = LocalProcesses.hostingApp(of: pid) {
            app.activate()
            if let tty = LocalProcesses.terminal(of: pid) { selectTab(tty: tty, in: app) }
            return
        }
        for id in session.kind.appBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                return
            }
        }
        if let cwd = session.cwd { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
    }

    func jump(to approval: PendingApproval) {
        if let session = sessions.first(where: { $0.kind == approval.event.kind && $0.sessionID == approval.event.sessionID }) {
            jump(to: session)
        } else if let pid = approval.event.callerPID, let app = LocalProcesses.hostingApp(of: pid) {
            app.activate()
        }
    }

    private func selectTab(tty: String, in app: NSRunningApplication) {
        guard let bundle = app.bundleIdentifier else { return }
        let script: String
        switch bundle {
        case "com.apple.Terminal":
            script = """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default:
            return
        }
        // Only with consent the user already gave (Setup or this button's
        // own prompt); otherwise activating the app is enough.
        Task { @MainActor in
            guard await PermissionCenter.shared.ensure(.automation(bundleID: bundle), from: "Coding Agents: jump to tab") else { return }
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error != nil { AppLog.log("Agents: couldn't select the terminal tab") }
        }
    }

    // MARK: Setup text

    var claudeSnippet: String { AgentSetupSnippets.claudeSettings(script: Self.hookScriptURL.path) }
    var codexSnippet: String { AgentSetupSnippets.codexConfig(script: Self.hookScriptURL.path) }
    var cursorSnippet: String { AgentSetupSnippets.cursorHooks(script: Self.hookScriptURL.path) }
    var zshSnippet: String { AgentSetupSnippets.zshLongCommand(script: Self.hookScriptURL.path, minimumSeconds: 5) }

    func revealHookScript() {
        prepareHookFiles()
        NSWorkspace.shared.activateFileViewerSelecting([Self.hookScriptURL])
    }
}

/// Is another app sharing the screen right now? Read from Smart Moments'
/// screen-sharing detector (call apps' and browsers' "sharing" windows),
/// so it is best effort and only live while Smart Moments watches sharing.
@MainActor
enum ExtrasPrivacy {
    static var isScreenShared: Bool {
        SmartMomentsWiring.current?.sources.isScreenSharing ?? false
    }
}
