import AppKit
import SwiftUI

/// Runs the UI / frontend audit of the user's own website: spawns
/// `node audit.mjs` (Vendor/ui-audit), follows its JSON-lines progress,
/// keeps the findings, posts a live activity under the notch
/// ("UI audit: page 3/12 · 7 issues"), and turns the report into a fix
/// prompt for a coding agent.
///
/// Lifecycle (`start()` / `stop()`) is the app's; a single audit is
/// `runAudit()` / `stopAudit()`.
@MainActor
final class UIAuditController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        /// The user took over the browser; the runner waits between actions.
        case paused
        case stopping
        case finished
        case failed(String)

        var isActive: Bool {
            switch self {
            case .starting, .running, .paused, .stopping: return true
            default: return false
            }
        }
    }

    struct LogLine: Identifiable, Equatable {
        let id: Int
        let date: Date
        let level: String
        let text: String
    }

    // Inputs (persisted, except the per-run safety toggles).
    @Published var urlText: String { didSet { UIAuditSettings.lastURL = urlText } }
    @Published var mode: UIAuditMode { didSet { UIAuditSettings.mode = mode } }
    @Published var maxPages: Int { didSet { UIAuditSettings.maxPages = maxPages } }
    @Published var maxDepth: Int { didSet { UIAuditSettings.maxDepth = maxDepth } }
    @Published var extraOrigins: String { didSet { UIAuditSettings.extraOrigins = extraOrigins } }
    /// Per run: submit forms on hosts that aren't local/test. Resets to off.
    @Published var allowSubmission = false
    /// Per run: allow clicking pay/delete/logout-like controls. Resets to off.
    @Published var allowRiskyClicks = false
    @Published var useGroqSummaries: Bool { didSet { UIAuditSettings.useGroqSummaries = useGroqSummaries } }

    // Run state.
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageTotal = 0
    @Published private(set) var currentURL = ""
    @Published private(set) var currentStep = ""
    @Published private(set) var liveCounts: [String: Int] = [:]
    @Published private(set) var findings: [UIAuditFinding] = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var planText = ""
    @Published private(set) var runDirectory: URL?

    // Results.
    @Published private(set) var lastReport: UIAuditReport?
    @Published private(set) var summaryText = ""
    @Published private(set) var summarySource = ""
    @Published private(set) var isSummarizing = false
    /// Set when the fix prompt was copied; views show a confirmation.
    @Published private(set) var promptCopiedAt: Date?
    @Published private(set) var promptCopiedCount = 0

    /// The drawer tab hovering the band opens, once the lead adds one.
    var activityTab: NotchState.Tab?
    /// The live-activity kind used for the band (switch to a dedicated case
    /// when LiveActivity.Kind gets one).
    var activityKind: LiveActivity.Kind = .notification
    static let activityID = "uiAudit"
    static let activityPriority = 25

    private let activities: ActivityCenter
    private var process: UIAuditProcess?
    private var logSeq = 0
    private var summaryTask: Task<Void, Never>?
    private var windowController: UIAuditWindowController?

    init(activities: ActivityCenter) {
        self.activities = activities
        urlText = UIAuditSettings.lastURL
        mode = UIAuditSettings.mode
        maxPages = UIAuditSettings.maxPages
        maxDepth = UIAuditSettings.maxDepth
        extraOrigins = UIAuditSettings.extraOrigins
        useGroqSummaries = UIAuditSettings.useGroqSummaries
    }

    // MARK: Lifecycle

    /// Loads the last report so the drawer can show it. Spawns nothing.
    func start() {
        guard lastReport == nil, let path = UIAuditSettings.lastReportPath else { return }
        let url = URL(fileURLWithPath: path)
        Task { [weak self] in
            let report = await Task.detached(priority: .utility) { try? UIAuditReport.load(from: url) }.value
            guard let self, let report, self.lastReport == nil else { return }
            self.lastReport = report
            self.findings = report.file.findings
            self.summaryText = UIAuditSummarizer.deterministic(report)
            self.summarySource = "Rule-based"
        }
    }

    /// App is quitting or the feature is turned off: end any run now.
    func stop() {
        summaryTask?.cancel()
        if let process {
            process.send("stop")
            process.kill()
        }
        process = nil
        activities.dismiss(id: Self.activityID)
        windowController?.close()
        if phase.isActive { phase = .idle }
    }

    /// Opens (or focuses) the full UI audit window.
    func showWindow() {
        let controller = windowController ?? UIAuditWindowController(controller: self)
        windowController = controller
        controller.show()
    }

    // MARK: Derived

    var isRunning: Bool { phase.isActive }

    var normalizedURL: URL? { UIAuditURL.normalize(urlText) }

    /// What will happen to forms on this host, shown next to the toggle.
    var submissionPolicyText: String {
        guard let host = normalizedURL?.host else { return "Enter your site's URL" }
        if UIAuditURL.isTestHost(host) { return "Local/test host: forms are filled and submitted" }
        return allowSubmission
            ? "Forms on \(host) WILL be submitted with test data"
            : "Forms on \(host) are filled and validated, never submitted"
    }

    var issueCount: Int {
        if isRunning { return liveCounts["issues"] ?? findings.filter(\.isIssue).count }
        return findings.filter(\.isIssue).count
    }

    var progressText: String {
        switch phase {
        case .idle: return lastReport.map { "Last audit: \($0.oneLine)" } ?? "Ready"
        case .starting: return "Starting browser…"
        case .running, .paused:
            let pages = pageTotal > 0 ? "page \(pageIndex)/\(pageTotal)" : "starting"
            return "\(phase == .paused ? "Paused (you have control) · " : "")\(pages) · \(issueCount) issue\(issueCount == 1 ? "" : "s")"
        case .stopping: return "Stopping and writing the report…"
        case .finished: return lastReport.map { "Done: \($0.oneLine)" } ?? "Done"
        case .failed(let message): return message
        }
    }

    // MARK: Run

    func runAudit() {
        guard !isRunning else { return }
        guard let url = normalizedURL else {
            phase = .failed("Enter an http(s) URL of your own site")
            return
        }
        guard let node = UIAuditRunnerLocator.nodeExecutable() else {
            phase = .failed("Node.js not found. Install Node 20+ or set the path in defaults (uiAudit.nodePath).")
            return
        }
        guard let runner = UIAuditRunnerLocator.runnerDirectory() else {
            phase = .failed("UI audit runner missing: run `npm ci` in Vendor/ui-audit (or bundle it into Resources/ui-audit).")
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let host = (url.host ?? "site").replacingOccurrences(of: ":", with: "_")
        let dir = UIAuditSettings.runsDirectory.appendingPathComponent("\(stamp)-\(host)", isDirectory: true)
        let origins = extraOrigins.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map(String.init).filter { !$0.isEmpty }
        let config: [String: Any] = [
            "startURL": url.absoluteString,
            "mode": mode.rawValue,
            "maxPages": maxPages,
            "maxDepth": maxDepth,
            "allowSubmit": allowSubmission,
            "allowDangerous": allowRiskyClicks,
            "allowedOrigins": origins,
            "headless": UIAuditSettings.headless,
            "outDir": dir.path,
            "rateLimitMs": 600,
            "maxRunSeconds": 900,
        ]
        let configURL = dir.appendingPathComponent("run-config.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL)
        } catch {
            phase = .failed("Couldn't create the report folder: \(error.localizedDescription)")
            return
        }

        resetRunState()
        runDirectory = dir
        urlText = url.absoluteString
        phase = .starting
        appendLog("Auditing \(url.absoluteString) (\(mode.label), up to \(maxPages) pages). \(submissionPolicyText).")
        if allowRiskyClicks { appendLog("Risky clicks are allowed for this run.", level: "warn") }

        let process = UIAuditProcess(
            node: node,
            script: runner.appendingPathComponent("audit.mjs"),
            arguments: ["--config", configURL.path, "--stdin-control"],
            onEvent: { [weak self] event in self?.handle(event) },
            onExit: { [weak self] status, stderr in self?.processExited(status: status, stderr: stderr) }
        )
        do {
            try process.start()
        } catch {
            phase = .failed("Couldn't start node: \(error.localizedDescription)")
            return
        }
        self.process = process
        // Per-run safety toggles never carry over to the next run.
        allowSubmission = false
        allowRiskyClicks = false
        postActivity()
        AppLog.log("UI audit: started \(url.host ?? "?") mode=\(mode.rawValue) pages=\(maxPages)")
    }

    /// Stop button: the runner writes a partial report, then exits.
    func stopAudit() {
        guard let process, isRunning else { return }
        phase = .stopping
        appendLog("Stopping…")
        process.stop()
        postActivity()
    }

    /// "Take over": the runner pauses between actions so the user can use the
    /// browser window; `resumeAudit()` continues.
    func pauseAudit() {
        guard phase == .running else { return }
        process?.send("pause")
    }

    func resumeAudit() {
        guard phase == .paused else { return }
        process?.send("resume")
    }

    private func resetRunState() {
        summaryTask?.cancel()
        pageIndex = 0
        pageTotal = 0
        currentURL = ""
        currentStep = ""
        liveCounts = [:]
        findings = []
        log = []
        planText = ""
        summaryText = ""
        summarySource = ""
        isSummarizing = false
        promptCopiedAt = nil
    }

    // MARK: Events

    private func handle(_ event: UIAuditEvent) {
        switch event.type {
        case "plan":
            planText = "Plan: \(event.modeLabel ?? mode.label) · up to \(event.maxPages ?? maxPages) pages within \((event.allowedOrigins ?? []).joined(separator: ", ")) · form submission \(event.submission ?? "off") · risky clicks \(event.dangerousClicks ?? "blocked")"
            appendLog(planText)
        case "state":
            if event.state == "paused" { phase = .paused } else if event.state == "running", phase != .stopping { phase = .running }
            postActivity()
        case "page":
            if phase == .starting { phase = .running }
            pageIndex = event.index ?? pageIndex
            pageTotal = event.total ?? pageTotal
            currentURL = event.url ?? ""
            appendLog("Page \(pageIndex)/\(pageTotal): \(currentURL)")
            postActivity()
        case "step":
            currentStep = event.message ?? ""
            appendLog(currentStep, level: "step")
            if let total = event.total, total != pageTotal {
                pageTotal = max(total, pageIndex)
                postActivity()
            }
        case "finding":
            if let f = event.finding {
                findings.append(f)
                if f.isIssue { appendLog("[\(f.severity)] \(f.title) — \(UIAuditURL.shortPath(f.page))\(f.selector.map { " \($0)" } ?? "")", level: "finding") }
            }
            if let counts = event.counts { liveCounts = counts }
            postActivity()
        case "page-done":
            if let counts = event.counts { liveCounts = counts }
            postActivity()
        case "log":
            appendLog(event.message ?? "", level: event.level ?? "info")
        case "error":
            appendLog(event.message ?? "Error", level: "error")
            if event.fatal == true {
                let message = event.message ?? "The audit failed"
                phase = .failed(Self.friendlyError(message) ?? message)
            }
        case "done":
            if let path = event.jsonPath { loadReport(at: URL(fileURLWithPath: path), stopped: event.stopped ?? false, reason: event.stopReason) }
        default:
            break
        }
    }

    private func loadReport(at url: URL, stopped: Bool, reason: String?) {
        do {
            let report = try UIAuditReport.load(from: url)
            lastReport = report
            findings = report.file.findings
            UIAuditSettings.lastReportPath = url.path
            summaryText = UIAuditSummarizer.deterministic(report)
            summarySource = "Rule-based"
            appendLog("Report: \(report.markdownURL.path)\(stopped ? " (stopped: \(reason ?? "by user"))" : "")")
        } catch {
            appendLog("Couldn't read the report: \(error.localizedDescription)", level: "error")
        }
    }

    private func processExited(status: Int32, stderr: String) {
        process = nil
        if case .failed = phase {
            // keep the error
        } else if lastReport != nil, lastReport?.directory == runDirectory {
            phase = .finished
        } else {
            let hint = Self.friendlyError(stderr)
            phase = .failed(hint ?? "The audit exited (\(status)) without a report")
            if !stderr.isEmpty { appendLog(String(stderr.suffix(600)), level: "error") }
        }
        AppLog.log("UI audit: runner exited \(status), \(findings.count) finding(s)")
        postFinalActivity()
        // Local (or opted-in Groq) summary; the rule-based one is already shown.
        if phase == .finished, lastReport?.issueCount ?? 0 > 0,
           UIAuditSettings.useGroqSummaries || TrayAIOnDevice.unavailableReason == nil {
            summarize()
        }
    }

    static func friendlyError(_ stderr: String) -> String? {
        if stderr.contains("Executable doesn't exist") || stderr.contains("browserType.launch") {
            return "Playwright's Chromium is missing: in Terminal run `npx playwright-core install chromium` inside Vendor/ui-audit."
        }
        if stderr.contains("ERR_MODULE_NOT_FOUND") || stderr.contains("Cannot find package") {
            return "Runner dependencies are missing: run `npm ci` in Vendor/ui-audit."
        }
        if stderr.contains("SyntaxError") && stderr.contains("Unexpected token") {
            return "Node is too old for the audit runner (needs Node 20+)."
        }
        return nil
    }

    private func appendLog(_ text: String, level: String = "info") {
        guard !text.isEmpty else { return }
        logSeq += 1
        log.append(LogLine(id: logSeq, date: Date(), level: level, text: text))
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    // MARK: Live activity

    private func postActivity() {
        let text: String
        switch phase {
        case .starting: text = "UI audit: starting…"
        case .paused: text = "UI audit paused · you have control"
        case .stopping: text = "UI audit: stopping…"
        default:
            text = pageTotal > 0 ? "UI audit: page \(pageIndex)/\(pageTotal) · \(issueCount) issue\(issueCount == 1 ? "" : "s")" : "UI audit: starting…"
        }
        let severe = (liveCounts["critical"] ?? 0) + (liveCounts["high"] ?? 0)
        let progress = pageTotal > 0 ? Double(pageIndex) / Double(pageTotal) : 0
        let paused = phase == .paused
        activities.post(LiveActivity(
            id: Self.activityID, kind: activityKind, priority: Self.activityPriority,
            duration: nil, opensTab: activityTab
        ) {
            UIAuditActivityBand(text: text, progress: progress, severe: severe, paused: paused)
        })
    }

    private func postFinalActivity() {
        let text: String
        var severe = 0
        if let report = lastReport, report.directory == runDirectory {
            text = "UI audit done · \(report.issueCount) issue\(report.issueCount == 1 ? "" : "s")"
            severe = report.file.summary.count(.critical) + report.file.summary.count(.high)
        } else if case .failed = phase {
            text = "UI audit failed"
        } else {
            text = "UI audit stopped"
        }
        activities.post(LiveActivity(
            id: Self.activityID, kind: activityKind, priority: Self.activityPriority,
            duration: 6, opensTab: activityTab
        ) {
            UIAuditActivityBand(text: text, progress: 1, severe: severe, paused: false)
        })
    }

    // MARK: Results

    /// Copies the coding-agent fix prompt for the last report ("P" button).
    func copyFixPrompt(to pasteboard: NSPasteboard = .general) {
        guard let report = lastReport else { return }
        let prompt = UIAuditPromptBuilder.build(report: report)
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        promptCopiedCount = min(report.issueCount, UIAuditPromptBuilder.maxFindings)
        promptCopiedAt = Date()
        AppLog.log("UI audit: fix prompt copied (\(prompt.count) chars, \(promptCopiedCount) issues)")
        let stamp = promptCopiedAt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.promptCopiedAt == stamp else { return }
            self.promptCopiedAt = nil
        }
    }

    var fixPromptPreview: String? {
        lastReport.map { UIAuditPromptBuilder.build(report: $0) }
    }

    func openReport() {
        guard let report = lastReport else { return }
        NSWorkspace.shared.open(report.htmlURL)
    }

    func openMarkdownReport() {
        guard let report = lastReport else { return }
        NSWorkspace.shared.open(report.markdownURL)
    }

    func revealReport() {
        guard let report = lastReport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([report.htmlURL])
    }

    func openScreenshot(_ finding: UIAuditFinding) {
        guard let url = lastReport?.screenshotURL(for: finding) ?? runDirectory?.appendingPathComponent(finding.screenshot ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func screenshotURL(for finding: UIAuditFinding) -> URL? {
        guard let rel = finding.screenshot, !rel.isEmpty else { return nil }
        if let report = lastReport, report.file.findings.contains(where: { $0.id == finding.id }) {
            return report.screenshotURL(for: finding)
        }
        return runDirectory?.appendingPathComponent(rel)
    }

    /// Summary via Groq (opt-in) or on-device; deterministic otherwise.
    func summarize() {
        guard let report = lastReport, !isSummarizing else { return }
        isSummarizing = true
        summaryTask = Task { [weak self] in
            let result = await UIAuditSummarizer.summarize(report)
            guard let self, !Task.isCancelled else { return }
            self.summaryText = result.text
            self.summarySource = result.source
            self.isSummarizing = false
        }
    }
}

/// Band under the notch while an audit runs (~360×30, dark).
struct UIAuditActivityBand: View {
    let text: String
    let progress: Double
    let severe: Int
    let paused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: paused ? "hand.raised.fill" : "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(paused ? SparkVTheme.warning : LabsTint.feature)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if severe > 0 {
                LabsBadge(text: "\(severe)")
                    .help("\(severe) critical/high")
            }
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(LabsTint.feature)
                .frame(width: 46)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
