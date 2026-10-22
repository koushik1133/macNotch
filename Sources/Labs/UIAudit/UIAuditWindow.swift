import AppKit
import SwiftUI

/// The full UI audit window: inputs, live log, findings with screenshots,
/// report buttons and the fix-prompt "P" button. SparkV is an agent app,
/// so while the window is open the app is made regular and active (as the
/// Tray AI panel does) for keyboard input; closing it returns to accessory
/// unless another real window is still open.
@MainActor
final class UIAuditWindowController: NSObject, NSWindowDelegate {
    private weak var controller: UIAuditController?
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(controller: UIAuditController) {
        self.controller = controller
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        guard let controller else { return }
        let window = window ?? makeWindow(controller: controller)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        window?.close()
    }

    private func makeWindow(controller: UIAuditController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "UI Audit"
        window.titlebarAppearsTransparent = true
        LabsBrand.styleWindow(window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.contentView = NSHostingView(rootView: UIAuditWindowView(controller: controller))
        window.setFrameAutosaveName("SparkV.UIAuditWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        let closing = notification.object as? NSWindow
        let stillOpen = NSApp.windows.contains { $0 !== closing && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: Keys

    /// Cmd-C/V/X/A/Z work in text fields even though the agent app has no Edit
    /// menu to provide those key equivalents; Cmd-W closes; Cmd-Return starts.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = UIAuditKeyPress(
                windowNumber: event.windowNumber, keyCode: event.keyCode,
                flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                characters: event.charactersIgnoringModifiers?.lowercased() ?? ""
            )
            let consumed = MainActor.assumeIsolated { self?.handleKey(key) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ key: UIAuditKeyPress) -> Bool {
        guard let window, window.isVisible, key.windowNumber == window.windowNumber else { return false }
        let flags = key.flags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let selector: Selector
        switch key.characters {
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "w":
            window.close()
            return true
        default:
            if key.keyCode == 36, let controller { // Return
                controller.isRunning ? controller.stopAudit() : controller.runAudit()
                return true
            }
            return false
        }
        return NSApp.sendAction(selector, to: nil, from: window)
    }
}

/// The parts of a key event the window looks at (NSEvent isn't Sendable).
private struct UIAuditKeyPress: Sendable {
    let windowNumber: Int
    let keyCode: UInt16
    let flags: NSEvent.ModifierFlags
    let characters: String
}

// MARK: - Window content

/// View-local state (no @State: the Command Line Tools lack its macro).
@MainActor
final class UIAuditWindowState: ObservableObject {
    enum Grouping: String, CaseIterable, Identifiable {
        case severity = "Severity"
        case page = "Page"
        var id: String { rawValue }
    }

    @Published var grouping: Grouping = .severity
    @Published var expanded: Set<String> = []
    @Published var minimumSeverity: UIAuditSeverity = .info
    @Published var showAdvanced = false
}

struct UIAuditWindowView: View {
    @ObservedObject var controller: UIAuditController
    @StateObject private var ui = UIAuditWindowState()

    var body: some View {
        VStack(spacing: 0) {
            inputs
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 10)
            Divider().overlay(SparkVTheme.stroke)
            statusBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider().overlay(SparkVTheme.stroke)
            HStack(spacing: 0) {
                logPane
                    .frame(width: 340)
                Divider().overlay(SparkVTheme.stroke)
                findingsPane
            }
            Divider().overlay(SparkVTheme.stroke)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .labsWindowRoot()
    }

    // MARK: Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(controller.isRunning ? LabsTint.feature : SparkVTheme.text)
                TextField("https://your-site.example or http://localhost:3000", text: $controller.urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { if !controller.isRunning { controller.runAudit() } }
                Picker("Mode", selection: $controller.mode) {
                    ForEach(UIAuditMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 400)
                startStopButton
            }
            .disabled(controller.phase == .stopping)

            HStack(spacing: 14) {
                Stepper("Max pages: \(controller.maxPages)", value: $controller.maxPages, in: 1...100)
                    .fixedSize()
                Stepper("Depth: \(controller.maxDepth)", value: $controller.maxDepth, in: 0...6)
                    .fixedSize()
                Toggle("Allow form submission", isOn: $controller.allowSubmission)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .help("This run only. Always on for localhost, 127.0.0.1, ::1, *.localhost, *.test and *.local hosts. Off: fields are filled and validated, nothing is sent (all non-GET requests are blocked).")
                Toggle("Allow risky clicks", isOn: $controller.allowRiskyClicks)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(SparkVTheme.destructive)
                    .fixedSize()
                    .help("This run only. Lets the audit click controls that look like pay, checkout, delete, remove, cancel subscription, transfer or log out. Leave off on real accounts.")
                Spacer()
                Button(ui.showAdvanced ? "Hide options" : "More options") { ui.showAdvanced.toggle() }
                    .buttonStyle(.plain)
                    .font(SparkVTheme.caption(11))
                    .foregroundStyle(SparkVTheme.link)
            }
            .font(.system(size: 12))
            .disabled(controller.isRunning)

            if ui.showAdvanced {
                HStack(spacing: 10) {
                    TextField("Extra allowed origins, e.g. https://api.example.com (comma-separated)", text: $controller.extraOrigins)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Toggle("Use Groq for summaries", isOn: $controller.useGroqSummaries)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Off by default. When on, a compact list of findings (titles and page paths) is sent to Groq with Clicky's API key to write the summary. Off: summaries are on-device or rule-based.")
                }
                .disabled(controller.isRunning)
            }

            Text("\(controller.mode.detail)  ·  \(controller.submissionPolicyText)")
                .font(SparkVTheme.body(11))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(2)
        }
    }

    private var startStopButton: some View {
        Group {
            if controller.isRunning {
                Button(role: .destructive) { controller.stopAudit() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(minWidth: 70)
                }
                .buttonStyle(LabsSecondaryButtonStyle())
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { controller.runAudit() } label: {
                    Label("Start", systemImage: "play.fill").frame(minWidth: 70)
                }
                .buttonStyle(LabsPrimaryButtonStyle())
                .disabled(controller.normalizedURL == nil)
            }
        }
        .controlSize(.large)
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.progressText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusTextColor)
                    .lineLimit(1)
                if controller.isRunning, !controller.currentStep.isEmpty || !controller.currentURL.isEmpty {
                    Text(controller.currentStep.isEmpty ? controller.currentURL : "\(UIAuditURL.shortPath(controller.currentURL)) — \(controller.currentStep)")
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            UIAuditCountChips(counts: currentCounts)
            if controller.phase == .running {
                Button { controller.pauseAudit() } label: { Label("Take over", systemImage: "hand.raised.fill") }
                    .buttonStyle(LabsSecondaryButtonStyle())
                    .help("Pause the agent between actions so you can use the browser window yourself")
            } else if controller.phase == .paused {
                Button { controller.resumeAudit() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(LabsPrimaryButtonStyle())
            }
            if controller.isRunning, controller.pageTotal > 0 {
                ProgressView(value: Double(controller.pageIndex), total: Double(max(controller.pageTotal, 1)))
                    .tint(LabsTint.feature)
                    .frame(width: 120)
            }
        }
    }

    private var currentCounts: [UIAuditSeverity: Int] {
        var out: [UIAuditSeverity: Int] = [:]
        for f in controller.findings { out[f.severityLevel, default: 0] += 1 }
        return out
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch controller.phase {
        case .idle: return SparkVTheme.textTertiary
        case .starting, .running: return LabsTint.feature
        case .paused, .stopping: return SparkVTheme.warning
        case .finished: return SparkVTheme.success
        case .failed: return SparkVTheme.destructive
        }
    }

    private var statusTextColor: Color {
        switch controller.phase {
        case .idle, .starting, .running: return SparkVTheme.text
        case .paused, .stopping: return SparkVTheme.warning
        case .finished: return SparkVTheme.success
        case .failed: return LabsTint.errorText
        }
    }

    // MARK: Log

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabsEyebrow("Live log")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if !controller.planText.isEmpty {
                Text(controller.planText)
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .labsCard(SparkVTheme.cornerSmall, fill: SparkVTheme.choose(apple: Color.cyan.opacity(0.10), sparkv: SparkVTheme.accentSoft.opacity(0.6)), stroke: SparkVTheme.choose(apple: Color.cyan.opacity(0.18), sparkv: SparkVTheme.brandRed.opacity(0.25)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.log) { line in
                            Text(line.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(color(for: line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: controller.log.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .background(Color.white.opacity(0.02))
    }

    private func color(for level: String) -> Color {
        switch level {
        case "error": return LabsTint.errorText
        case "warn": return SparkVTheme.warning
        case "finding": return SparkVTheme.warning.opacity(0.85)
        case "step": return SparkVTheme.textTertiary
        default: return SparkVTheme.textSecondary
        }
    }

    // MARK: Findings

    private var findingsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Findings")
                    .font(SparkVTheme.headline(15))
                    .tracking(-0.2)
                    .foregroundStyle(SparkVTheme.text)
                Text("\(visibleFindings.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textTertiary)
                Spacer()
                Picker("Minimum severity", selection: $ui.minimumSeverity) {
                    ForEach(UIAuditSeverity.allCases, id: \.self) { level in
                        Text(level == .info ? "All" : "\(level.label)+").tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Picker("Group by", selection: $ui.grouping) {
                    ForEach(UIAuditWindowState.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if visibleFindings.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: controller.isRunning ? "hourglass" : "checkmark.seal")
                        .font(.system(size: 26))
                        .foregroundStyle(SparkVTheme.textTertiary)
                    Text(controller.isRunning ? "Findings appear here as pages are audited." : "No findings yet. Enter your site's URL and press Start.")
                        .font(.system(size: 12))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.title) { group in
                            Section {
                                ForEach(group.items) { finding in
                                    UIAuditFindingRow(
                                        finding: finding,
                                        expanded: ui.expanded.contains(finding.id),
                                        screenshot: controller.screenshotURL(for: finding),
                                        showPage: ui.grouping == .severity,
                                        toggle: { toggle(finding.id) },
                                        openScreenshot: { controller.openScreenshot(finding) }
                                    )
                                }
                            } header: {
                                HStack {
                                    Text(group.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(group.color)
                                    Text("\(group.items.count)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(SparkVTheme.textTertiary)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                                .background(SparkVTheme.background)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if ui.expanded.contains(id) { ui.expanded.remove(id) } else { ui.expanded.insert(id) }
    }

    private var visibleFindings: [UIAuditFinding] {
        controller.findings.filter { $0.severityLevel <= ui.minimumSeverity }
    }

    private struct FindingGroup {
        let title: String
        let color: Color
        let items: [UIAuditFinding]
    }

    private var groups: [FindingGroup] {
        let items = visibleFindings
        switch ui.grouping {
        case .severity:
            return UIAuditSeverity.allCases.compactMap { level in
                let matching = items.filter { $0.severityLevel == level }.sorted(by: UIAuditPromptBuilder.order)
                return matching.isEmpty ? nil : FindingGroup(title: level.label, color: UIAuditStyle.color(level), items: matching)
            }
        case .page:
            return UIAuditPromptBuilder.groupedByPage(items).map { page, list in
                FindingGroup(title: page, color: SparkVTheme.text, items: list)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if controller.isSummarizing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing…").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                    }
                } else if !controller.summaryText.isEmpty {
                    Text(controller.summaryText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(controller.summaryText)
                    Text(controller.summarySource)
                        .font(.system(size: 9.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                } else {
                    Text("Reports are saved in ~/Library/Application Support/SparkV/UIAudit.")
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { controller.summarize() } label: { Label("Summarize", systemImage: "sparkles") }
                .buttonStyle(LabsSecondaryButtonStyle())
                .disabled(controller.lastReport == nil || controller.isSummarizing)
            Button { controller.openReport() } label: { Label("Open report", systemImage: "doc.richtext") }
                .buttonStyle(LabsSecondaryButtonStyle())
                .disabled(controller.lastReport == nil)
            Menu {
                Button("Open report.md") { controller.openMarkdownReport() }
                Button("Show in Finder") { controller.revealReport() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(controller.lastReport == nil)
            UIAuditPromptButton(controller: controller, size: 28)
        }
    }
}

// MARK: - Shared pieces

enum UIAuditStyle {
    static func color(_ level: UIAuditSeverity) -> Color {
        switch level {
        case .critical: return SparkVTheme.choose(apple: Color(red: 1, green: 0.27, blue: 0.38), sparkv: SparkVTheme.brandRed)
        case .high: return SparkVTheme.warning
        case .medium: return SparkVTheme.choose(apple: Color.yellow, sparkv: Color(red: 1, green: 0.86, blue: 0.45))
        case .low: return SparkVTheme.choose(apple: Color(red: 0.39, green: 0.82, blue: 1), sparkv: SparkVTheme.textSecondary)
        case .info: return SparkVTheme.textTertiary
        }
    }
}

struct UIAuditSeverityChip: View {
    let level: UIAuditSeverity

    var body: some View {
        Text(level.rawValue.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(level == .critical ? Color.white : Color.black)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(UIAuditStyle.color(level)))
    }
}

struct UIAuditCountChips: View {
    let counts: [UIAuditSeverity: Int]
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach([UIAuditSeverity.critical, .high, .medium, .low], id: \.self) { level in
                if let n = counts[level], n > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(UIAuditStyle.color(level)).frame(width: 6, height: 6)
                        Text("\(n)")
                            .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                            .foregroundStyle(SparkVTheme.text)
                    }
                    .padding(.horizontal, compact ? 4 : 6)
                    .frame(height: compact ? 15 : 18)
                    .background(Capsule().fill(SparkVTheme.surface))
                    .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                    .help("\(n) \(level.rawValue)")
                }
            }
        }
    }
}

/// The "P" button: copies a precise fix prompt for a coding agent, then
/// confirms inline.
struct UIAuditPromptButton: View {
    @ObservedObject var controller: UIAuditController
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            if controller.promptCopiedAt != nil {
                Label("Copied fix prompt (\(controller.promptCopiedCount) issue\(controller.promptCopiedCount == 1 ? "" : "s"))", systemImage: "checkmark.circle.fill")
                    .font(.system(size: size > 24 ? 11 : 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.success)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button { controller.copyFixPrompt() } label: {
                Text("P")
                    .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(controller.lastReport == nil ? SparkVTheme.textTertiary : Color.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(controller.lastReport == nil ? SparkVTheme.surface : SparkVTheme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.lastReport == nil || (controller.lastReport?.issueCount ?? 0) == 0)
            .help("Copy a self-contained fix prompt for a coding agent (grouped by page, with selectors, repro steps, expected vs actual and acceptance criteria)")
        }
    }
}

struct UIAuditFindingRow: View {
    let finding: UIAuditFinding
    let expanded: Bool
    let screenshot: URL?
    let showPage: Bool
    let toggle: () -> Void
    let openScreenshot: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    UIAuditSeverityChip(level: finding.severityLevel)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SparkVTheme.text)
                            .lineLimit(expanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if screenshot != nil {
                        Image(systemName: "photo")
                            .font(.system(size: 10))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { details }
        }
        .padding(8)
        .labsCard(SparkVTheme.cornerSmall, fill: expanded ? SparkVTheme.surfaceHover : SparkVTheme.surface)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showPage { parts.append(UIAuditURL.shortPath(finding.page)) }
        if let s = finding.selector, !s.isEmpty { parts.append(s) }
        parts.append(finding.ruleLabel)
        if let also = finding.alsoOn, !also.isEmpty { parts.append("+\(also.count) page\(also.count == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            field("Page", finding.page + (finding.viewport.map { $0.isEmpty ? "" : " (\($0))" } ?? ""))
            if let locator = finding.locator, !locator.isEmpty { field("Locator", locator, mono: true) }
            if let evidence = finding.evidence, !evidence.isEmpty { field("Evidence", evidence) }
            if let expected = finding.expected, !expected.isEmpty { field("Expected", expected) }
            if let actual = finding.actual, !actual.isEmpty { field("Actual", actual) }
            if let steps = finding.steps, !steps.isEmpty {
                field("Repro", steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            }
            if let fix = finding.fix, !fix.isEmpty { field("Fix", fix) }
            if let also = finding.alsoOn, !also.isEmpty { field("Also on", also.prefix(6).joined(separator: "\n")) }
            if let help = finding.helpUrl, let url = URL(string: help) {
                Link("Rule documentation", destination: url).font(.system(size: 10.5)).foregroundStyle(SparkVTheme.link)
            }
            if let screenshot, let image = NSImage(contentsOf: screenshot) {
                Button(action: openScreenshot) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 520, maxHeight: 220, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
                }
                .buttonStyle(.plain)
                .help("Open screenshot")
            }
        }
        .padding(.leading, 4)
    }

    private func field(_ name: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                .foregroundStyle(SparkVTheme.text.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
