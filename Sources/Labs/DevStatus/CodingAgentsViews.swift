import AppKit
import SwiftUI

// MARK: - Colors

enum CodingAgentStyle {
    /// Apple: each tool in its own color. SparkV Red: monochrome text, red for "needs you".
    static func tint(_ kind: CodingAgentKind) -> Color {
        guard SparkVTheme.isApple else { return SparkVTheme.text.opacity(0.88) }
        return switch kind {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.55, green: 0.62, blue: 1.0)
        case .cursor: Color(white: 0.85)
        }
    }

    static func tint(_ state: CodingAgentState) -> Color {
        switch state {
        case .waiting: SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red)
        case .working: SparkVTheme.choose(apple: Color.accentColor, sparkv: SparkVTheme.text)
        case .finished: SparkVTheme.success
        case .idle: SparkVTheme.textTertiary
        }
    }
}

// MARK: - Bands and wings

/// The urgent band while an agent waits for Allow / Deny. The island's
/// band doesn't take clicks, so it says where to answer: hovering it opens
/// the drawer on the agents page, where the buttons are.
struct CodingAgentApprovalBand: View {
    let approval: CodingAgentsController.PendingApproval
    let queued: Int

    var body: some View {
        let tint = CodingAgentStyle.tint(.waiting)
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.22))
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(approval.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    if queued > 0 {
                        ExtrasPill(text: "+\(queued)", tint: tint)
                    }
                }
                Text(ExtrasPrivacy.isScreenShared ? "Details hidden while sharing" : (approval.event.toolSummary ?? "Hover to answer"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 9, weight: .semibold))
                Text("Hover to answer")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(SparkVTheme.textTertiary)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(approval.title). \(approval.event.toolSummary ?? ""). Open the island to allow or deny.")
    }
}

/// A short one-line band: an agent finished, a command finished, CI failed.
struct CodingAgentEventBand: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .layoutPriority(1)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}

/// The band when the agents summary peeks.
struct CodingAgentsSummaryBand: View {
    let running: Int
    let waiting: Int

    var body: some View {
        HStack(spacing: 10) {
            CodingAgentsWingLeading(waiting: waiting > 0)
            Text(summary)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
            Spacer(minLength: 0)
            CodingAgentsWingTrailing(running: running, waiting: waiting)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if running > 0 { parts.append("\(running) working") }
        return "Agents: " + parts.joined(separator: ", ")
    }
}

/// Left wing: a soft pulsing spark (static under Reduce Motion).
struct CodingAgentsWingLeading: View {
    let waiting: Bool

    var body: some View {
        let tint = waiting ? CodingAgentStyle.tint(.waiting) : CodingAgentStyle.tint(.claude)
        Image(systemName: waiting ? "hand.raised.fill" : "sparkles")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            // One bounce when an agent starts waiting for you, nothing
            // repeating: the closed island stays idle for hours of work.
            .symbolEffect(.bounce, options: .nonRepeating, value: waiting)
            .accessibilityHidden(true)
    }
}

/// Right wing: "2 ◐ 1 ✋" counts.
struct CodingAgentsWingTrailing: View {
    let running: Int
    let waiting: Int

    var body: some View {
        HStack(spacing: 5) {
            if running > 0 {
                HStack(spacing: 2) {
                    Text("\(running)")
                    Image(systemName: "circle.dotted").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(SparkVTheme.text)
            }
            if waiting > 0 {
                HStack(spacing: 2) {
                    Text("\(waiting)")
                    Image(systemName: "hand.raised.fill").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(CodingAgentStyle.tint(.waiting))
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(running) agents working, \(waiting) waiting")
    }
}

// MARK: - Drawer page

/// The Agents page of the Dev drawer tab: approvals first, then sessions.
struct CodingAgentsPage: View {
    @ObservedObject var controller: CodingAgentsController
    @StateObject private var appeared = ViewFlag()

    @MainActor init(controller: CodingAgentsController? = nil) {
        self.controller = controller ?? .shared
    }

    var body: some View {
        Group {
            if !controller.isEnabled && controller.approvals.isEmpty && !controller.hookEnabled {
                ExtrasNotice(symbol: "sparkles.rectangle.stack",
                             title: "Coding Agents is off",
                             detail: "See which Claude Code, Codex and Cursor sessions run, wait for you or finished. Reads their local session folders only; nothing leaves your Mac.",
                             action: ("Turn On", { controller.isEnabled = true }))
            } else if controller.approvals.isEmpty && controller.sessions.isEmpty {
                ExtrasNotice(symbol: "moon.zzz",
                             title: "No agent sessions right now",
                             detail: controller.hookEnabled
                                ? "Start Claude Code, Codex or Cursor. Approvals from tools you set up appear here with Allow and Deny."
                                : "Start Claude Code, Codex or Cursor. To answer approvals here, turn on the hook in Settings › Extras.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(Array(controller.approvals.enumerated()), id: \.element.id) { index, approval in
                            CodingAgentApprovalCard(approval: approval, controller: controller)
                                .transition(.sparkVEnter)
                                .sparkVStaggeredEntrance(appeared.isOn, index: index)
                        }
                        ForEach(Array(controller.sessions.enumerated()), id: \.element.id) { index, session in
                            CodingAgentRow(session: session, controller: controller)
                                .sparkVStaggeredEntrance(appeared.isOn, index: index + controller.approvals.count)
                        }
                    }
                    .padding(6)
                    .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: controller.approvals.map(\.id))
                }
            }
        }
        .onAppear {
            appeared.isOn = true
            controller.refresh()
        }
        .onDisappear { appeared.isOn = false }
    }
}

/// Allow / Deny for one pending approval. Allow is never the default
/// button and never bound to a key: it takes an explicit click.
struct CodingAgentApprovalCard: View {
    let approval: CodingAgentsController.PendingApproval
    @ObservedObject var controller: CodingAgentsController

    var body: some View {
        let tint = CodingAgentStyle.tint(.waiting)
        HStack(spacing: 8) {
            Image(systemName: approval.event.kind.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CodingAgentStyle.tint(approval.event.kind))
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.18)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(approval.shortTitle + (approval.event.cwd.map { " · " + ExtrasFormat.folderName($0) } ?? ""))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Text(approval.event.toolSummary ?? approval.event.toolName ?? "")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(approval.event.toolSummary ?? "")
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: approval.receivedAt, by: 1)) { context in
                let left = max(0, Int(approval.deadline.timeIntervalSince(context.date).rounded()))
                Text("\(left)s")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .accessibilityLabel("\(left) seconds left")
            }
            ExtrasCapsuleButton(title: "Deny", tint: SparkVTheme.destructive) { controller.resolve(approval.id, .deny) }
                .help("Deny: the agent is told you said no")
            ExtrasCapsuleButton(title: "Ask There") { controller.resolve(approval.id, .ask); controller.jump(to: approval) }
                .help("Answer in the agent's own window")
            ExtrasCapsuleButton(title: "Allow", systemImage: "checkmark", prominent: true,
                                tint: SparkVTheme.choose(apple: Color.green.opacity(0.85), sparkv: SparkVTheme.success.opacity(0.9))) {
                controller.resolve(approval.id, .allow)
            }
            .help("Allow this once")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(SparkVTheme.isApple ? 0.12 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(approval.title): \(approval.event.toolSummary ?? "")")
    }
}

struct CodingAgentRow: View {
    let session: CodingAgentSession
    @ObservedObject var controller: CodingAgentsController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind.symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(CodingAgentStyle.tint(session.kind))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .help(session.kind.title)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.name.map { "\(session.project) · \($0)" } ?? session.project)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    if let branch = session.branch {
                        Text(branch)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let percent = session.limitPercent {
                ExtrasPill(text: "\(Int(percent.rounded()))% limit", tint: percent >= 80 ? SparkVTheme.warning : SparkVTheme.textSecondary)
                    .help("Codex rate-limit window used")
            }
            if let tokens = session.tokensToday, tokens > 0 {
                ExtrasPill(text: ExtrasFormat.compactCount(tokens), tint: SparkVTheme.textSecondary, symbol: "number")
                    .help("Tokens today (from local transcripts)")
            }
            ExtrasPill(text: session.state.title, tint: CodingAgentStyle.tint(session.state), symbol: session.state.symbol)
            ExtrasIconButton(systemImage: "arrow.up.forward.app", label: "Go to \(session.kind.shortTitle)") {
                controller.jump(to: session)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .sparkVHoverFill(hover.isOn, cornerRadius: 8)
        .onHover { hover.isOn = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.jump(to: session) }
        .contextMenu {
            Button("Go to \(session.kind.shortTitle)") { controller.jump(to: session) }
            if let cwd = session.cwd {
                Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
                Button("Copy Folder Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cwd, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.kind.title), \(session.project), \(session.state.title)")
        .accessibilityAction(named: "Go to \(session.kind.shortTitle)") { controller.jump(to: session) }
    }

    private var subtitle: String {
        var parts = [session.kind.shortTitle]
        if let detail = session.detail { parts.append(detail) }
        parts.append(ExtrasFormat.ago(session.updatedAt))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Hub tile

/// Developer category. Lit while an agent works; a badge counts those
/// waiting for you. Click: the agents page. Right-click: settings.
struct CodingAgentsHubTile: View {
    @ObservedObject private var controller = CodingAgentsController.shared
    var onOpen: (() -> Void)? = nil
    /// Its id in the Agents hub: adds the hub's Pin / Hide / Move items.
    var hubID: String? = nil

    var body: some View {
        let waiting = controller.waitingCount
        let running = controller.runningCount
        ExtrasHubTileFace(
            title: running > 0 ? "\(running) Working" : "Coding",
            systemImage: waiting > 0 ? "hand.raised.fill" : "sparkles.rectangle.stack",
            tint: Color(red: 0.85, green: 0.47, blue: 0.34),
            isActive: running + waiting > 0,
            badge: waiting > 0 ? "\(waiting)" : nil,
            badgeTint: CodingAgentStyle.tint(.waiting),
            help: "Coding Agents: Claude Code, Codex and Cursor sessions"
        ) {
            DevStatusNavigator.shared.section = .agents
            (onOpen ?? DevStatusNavigator.shared.openDrawer)()
        }
        .contextMenu {
            CodingAgentsMenuItems()
            ExtrasHubMenuTail(hubID: hubID)
        }
    }
}

// MARK: - Gear menu

struct CodingAgentsMenuItems: View {
    @ObservedObject private var controller = CodingAgentsController.shared

    var body: some View {
        Toggle("Watch Coding Agents", isOn: $controller.isEnabled)
        Toggle("Answer Approvals in the Island (Hook)", isOn: $controller.hookEnabled)
        Toggle("Sounds", isOn: $controller.playsSounds)
        Toggle("Show Agents Beside the Notch", isOn: $controller.showsWings)
        if !controller.approvals.isEmpty {
            Divider()
            Text("\(controller.approvals.count) waiting for approval")
        }
        Divider()
        Button("Show Agents") {
            DevStatusNavigator.shared.section = .agents
            DevStatusNavigator.shared.openDrawer()
        }
        Button("Reveal Hook Script…") { controller.revealHookScript() }
    }
}

// MARK: - Settings (Extras pane)

struct CodingAgentsSettingsSection: View {
    @ObservedObject private var controller = CodingAgentsController.shared
    @ObservedObject private var setup = ExtrasSetupTab.agents

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtrasSettingsCard(title: "Coding Agents",
                               subtitle: "Claude Code, Codex and Cursor sessions in the island: working, waiting for you, done. Reads their session folders read-only; nothing leaves your Mac.",
                               systemImage: "sparkles.rectangle.stack") {
                VStack(alignment: .leading, spacing: 2) {
                    ExtrasToggleRow(title: "Watch Coding Agents",
                                    detail: "~/.claude, ~/.codex and ~/.cursor session files, read-only. Prompts and code are never stored or logged.",
                                    isOn: $controller.isEnabled)
                    Group {
                        ExtrasToggleRow(title: "Claude Code", isOn: $controller.watchClaude, indent: 14)
                        ExtrasToggleRow(title: "Codex", isOn: $controller.watchCodex, indent: 14)
                        ExtrasToggleRow(title: "Cursor", detail: "Cursor writes no timestamps; SparkV goes by when its transcript last changed.",
                                        isOn: $controller.watchCursor, indent: 14)
                        ExtrasToggleRow(title: "Count Today's Tokens",
                                        detail: "Adds up usage from local transcripts (Claude Code, Codex). There's no public API for plan limits; Codex reports its own limit use, shown when present.",
                                        isOn: $controller.countTokens, indent: 14)
                    }
                    .disabled(!controller.isEnabled)
                    ExtrasDivider()
                    ExtrasToggleRow(title: "Show Agents Beside the Notch", detail: "Counts of working and waiting sessions in the wings.", isOn: $controller.showsWings)
                    ExtrasToggleRow(title: "Band When an Agent Finishes", isOn: $controller.showsFinishedBand)
                    ExtrasToggleRow(title: "Sounds", detail: "Glass when an agent needs you, Ping when one finishes.", isOn: $controller.playsSounds)
                }
            }

            ExtrasSettingsCard(title: "Approvals from the Island",
                               subtitle: "An optional local hook: your tool asks SparkV, you click Allow or Deny in the drawer. HTTP on 127.0.0.1 only, with a per-install token; browsers are refused.",
                               systemImage: "hand.raised") {
                VStack(alignment: .leading, spacing: 6) {
                    ExtrasToggleRow(title: "Hook Endpoint", detail: hookDetail, isOn: $controller.hookEnabled)
                    ExtrasControlRow(title: "Wait for My Answer",
                                     detail: "After this, the tool asks in its own window as usual.") {
                        Picker("", selection: $controller.decisionTimeout) {
                            ForEach([15, 30, 45, 55], id: \.self) { Text("\($0) s").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        .accessibilityLabel("Wait for my answer")
                    }
                    .disabled(!controller.hookEnabled)
                    if controller.hookEnabled {
                        HStack(spacing: 8) {
                            Button("Reveal Hook Script") { controller.revealHookScript() }
                                .buttonStyle(SparkVSecondaryButtonStyle())
                            Button("New Token") { controller.resetToken() }
                                .buttonStyle(SparkVSecondaryButtonStyle())
                                .help("Hooks read the token from SparkV's folder each time, so nothing else changes.")
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        ExtrasNote(text: "Add these lines to your own config. SparkV never edits ~/.claude, ~/.codex or ~/.cursor. When SparkV isn't running, the hook exits at once and your tool asks as it always does.",
                                   systemImage: "doc.badge.gearshape")
                        ExtrasSegmented(options: [(ExtrasSetupTab.Tool.claude, "Claude Code"), (.codex, "Codex"), (.cursor, "Cursor")],
                                        selection: $setup.tool, label: "Setup for", compact: true)
                            .padding(.horizontal, 8)
                        switch setup.tool {
                        case .claude:
                            ExtrasCodeBlock(title: "~/.claude/settings.json (merge into \"hooks\")", code: controller.claudeSnippet)
                        case .codex:
                            ExtrasCodeBlock(title: "~/.codex/config.toml (Codex reports finished turns; it has no approval hook)", code: controller.codexSnippet, maxHeight: 50)
                        case .cursor:
                            ExtrasCodeBlock(title: "~/.cursor/hooks.json", code: controller.cursorSnippet)
                        }
                    }
                }
            }

            ExtrasSettingsCard(title: "Long Commands",
                               subtitle: "A band when a command in your terminal finishes after a while and the terminal isn't in front. Needs the hook endpoint and a few lines in ~/.zshrc.",
                               systemImage: "terminal") {
                VStack(alignment: .leading, spacing: 6) {
                    ExtrasToggleRow(title: "Tell Me When Long Commands Finish", isOn: $controller.longCommandsEnabled)
                        .disabled(!controller.hookEnabled)
                    ExtrasControlRow(title: "Longer Than") {
                        Picker("", selection: $controller.longCommandSeconds) {
                            ForEach([10, 30, 60, 120, 300], id: \.self) { Text(ExtrasFormat.duration(Double($0))).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        .accessibilityLabel("Longer than")
                    }
                    .disabled(!controller.longCommandsEnabled || !controller.hookEnabled)
                    if controller.hookEnabled {
                        ExtrasCodeBlock(title: "~/.zshrc", code: controller.zshSnippet, maxHeight: 130)
                    }
                }
            }
        }
    }

    private var hookDetail: String {
        switch controller.hookState {
        case .listening: "Listening on \(controller.hookPortText)."
        case .starting: "Starting…"
        case .failed(let reason): reason
        case .stopped: controller.hookEnabled ? "Starts with SparkV." : "Off. Nothing listens."
        }
    }
}

/// Which tool's setup lines the settings card shows (per viewer, not saved).
@MainActor
final class ExtrasSetupTab: ObservableObject {
    enum Tool: Hashable { case claude, codex, cursor }
    static let agents = ExtrasSetupTab()
    @Published var tool: Tool = .claude
}
