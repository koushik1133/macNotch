import SwiftUI

/// The Agents tab: one tile per agent, so the header needs a single icon.
/// A tile opens the agent's own drawer page (or runs it right away); the
/// header icon comes back here.
struct AgentsHubView: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var universalSearch: UniversalSearchController
    @EnvironmentObject private var quickCapture: QuickCaptureController
    @EnvironmentObject private var screenRegion: ScreenRegionController
    @EnvironmentObject private var clipboard: ClipboardController

    /// Eight columns by three rows (24 slots) across the 508 pt content
    /// width: tiles are ~58 pt wide; long labels shrink to fit. The
    /// drawer's height follows the row count (`NotchMetrics.agentsExpandedHeight`).
    static let columns = AgentHubMetrics.columns

    private struct Agent: Identifiable {
        let tab: NotchState.Tab?
        let title: String
        let systemImage: String
        let tint: Color
        var help: String? = nil
        /// Agents that live in their own window (or run at once) do this
        /// instead of opening a tab.
        var open: (@MainActor () -> Void)? = nil
        var id: String { title }
    }

    /// Cells in grid order. Focus and Translate have their own tiles, and
    /// the "C" capsule takes the last cell.
    private enum Cell: Identifiable {
        case agent(Agent)
        case focus
        case translate
        case record
        case modes
        case clipboard
        case fans
        case smartMoments
        case ambientLight
        var id: String {
            switch self {
            case .agent(let agent): agent.id
            case .focus: "focus"
            case .translate: "translate"
            case .record: "record"
            case .modes: "modes"
            case .clipboard: "clipboard"
            case .fans: "fans"
            case .smartMoments: "smartMoments"
            case .ambientLight: "ambientLight"
            }
        }
    }

    private var cells: [Cell] {
        // Row 1: everyday actions. Row 2: clipboard, screen and files.
        // Row 3: tools, watchers and setup; the "C" capsule follows (row 4).
        [
            .agent(Agent(tab: nil, title: "Search", systemImage: "magnifyingglass", tint: .indigo,
                         help: "Search everything (⌥Space)",
                         open: { [universalSearch] in universalSearch.openPanel() })),
            .focus,
            .modes,
            .ambientLight,
            .agent(Agent(tab: nil, title: "Capture", systemImage: "square.and.arrow.down.on.square.fill", tint: .orange,
                         open: { [quickCapture] in quickCapture.captureNow() })),
            .agent(Agent(tab: nil, title: "Copy Text", systemImage: "text.viewfinder", tint: .green,
                         help: "Copy text from anywhere on screen (\(screenRegion.textGrab.settings.shortcut.displayString))",
                         open: { [screenRegion] in screenRegion.textGrab.begin() })),
            .agent(Agent(tab: .replyDrafter, title: "Reply", systemImage: "arrowshape.turn.up.left.fill", tint: .cyan)),
            .agent(Agent(tab: .screen, title: "Ask Screen", systemImage: "viewfinder", tint: .cyan)),
            .agent(Agent(tab: .promptRefiner, title: "Prompt", systemImage: "wand.and.stars", tint: .purple)),
            .agent(Agent(tab: .clipboard, title: "Clipboard", systemImage: "doc.on.clipboard", tint: .pink)),
            .agent(Agent(tab: nil, title: "Paste Stack", systemImage: "square.stack.3d.down.right.fill", tint: .pink,
                         help: "Clipboard stack (⌘⇧V). Hold ⌘, tap a number, tap V to paste that copy.",
                         open: { [clipboard] in clipboard.showStackPanel() })),
            .record,
            .agent(Agent(tab: .widgets, title: "Widgets", systemImage: "rectangle.3.group.fill", tint: .orange,
                         help: "World clocks, volume knob, habits, CPU/RAM and network speed")),
            .agent(Agent(tab: .fileDrop, title: "File Drop", systemImage: "arrow.down.doc.fill", tint: .yellow)),
            .agent(Agent(tab: .downloads, title: "Downloads", systemImage: "arrow.down.circle", tint: .blue)),
            .translate,
            .agent(Agent(tab: .uiAudit, title: "UI Audit", systemImage: "checklist", tint: .green)),
            .agent(Agent(tab: .jobs, title: "Jobs", systemImage: "briefcase.fill", tint: .orange)),
            .agent(Agent(tab: .browser, title: "Browser", systemImage: "play.rectangle.on.rectangle", tint: .blue, help: "Browser Flows")),
            .agent(Agent(tab: .screenDistance, title: "Distance", systemImage: "eye", tint: .mint)),
            .agent(Agent(tab: nil, title: "Canvas", systemImage: "point.3.connected.trianglepath.dotted", tint: .teal,
                         open: { FlowCanvasWindowController.shared.show() })),
            .agent(Agent(tab: nil, title: "Setup", systemImage: "checkmark.shield.fill", tint: Color(white: 0.72),
                         help: "Permissions & Setup: see and allow what SparkV needs",
                         open: { OnboardingController.shared.show(step: .permissions) })),
            .agent(Agent(tab: nil, title: "iPhone", systemImage: "iphone.and.arrow.forward", tint: .blue,
                         help: "Sync to iPhone: keeps iCloud Drive › SparkV up to date for the Files app",
                         open: { CloudSyncWindowController.shared.show() })),
            .smartMoments,
            .fans,
            .clipboard,
        ]
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AgentHubMetrics.spacing), count: Self.columns),
            spacing: AgentHubMetrics.spacing
        ) {
            ForEach(cells) { cell in
                switch cell {
                case .agent(let agent):
                    AgentTile(title: agent.title, systemImage: agent.systemImage, tint: agent.tint, help: agent.help) {
                        if let open = agent.open {
                            open()
                        } else if let tab = agent.tab {
                            withAnimation(.easeOut(duration: 0.15)) { state.select(tab) }
                        }
                    }
                case .focus:
                    FocusHubTile(onOpen: { withAnimation(.easeOut(duration: 0.15)) { state.select(.focus) } })
                case .translate:
                    TranslateHubTile()
                case .modes:
                    // One click lists the modes; pick one to switch, or Stop / Edit Modes…
                    ModesHubTile()
                case .record:
                    RecordHubTile()
                case .smartMoments:
                    if let smartMoments = SmartMomentsWiring.current {
                        SmartMomentsHubTile(settings: smartMoments.settings)
                    }
                case .fans:
                    FanHubTile(onOpen: { withAnimation(.easeOut(duration: 0.15)) { state.select(.fans) } })
                case .ambientLight:
                    // Click: on/off. Right-click: modes, edges, settings.
                    AmbientLightHubTile()
                case .clipboard:
                    // The "C" capsule: one click pastes what's on the clipboard.
                    ClipboardButton(maxWidth: 58, height: 24)
                        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum AgentHubMetrics {
    /// Matches `FocusHubTile`'s height, so every row lines up.
    static let tileHeight: CGFloat = 48
    static let spacing: CGFloat = 6
    static let columns = 8
    /// 26 cells in `AgentsHubView.cells` (32 slots; the fourth row has room).
    static let rows = 4
}

/// One-click screen recording: opens the red selection overlay (drag an
/// area, click a window, Return for the whole display); while recording it
/// turns into a red Stop tile with the elapsed time.
private struct RecordHubTile: View {
    @EnvironmentObject private var recorder: ScreenRecorderController

    var body: some View {
        if case .recording(let since) = recorder.phase {
            TimelineView(.periodic(from: since, by: 1)) { context in
                AgentTile(title: "Stop " + ScreenRecording.durationText(context.date.timeIntervalSince(since)),
                          systemImage: "stop.circle.fill", tint: .red, isHighlighted: true,
                          help: "Stop recording (\(recorder.shortcut.displayString))") {
                    recorder.stop()
                }
            }
        } else {
            AgentTile(title: "Record", systemImage: "record.circle", tint: .red,
                      help: "Record the screen to the Desktop (\(recorder.shortcut.displayString))") {
                recorder.toggle()
            }
            .disabled(recorder.phase == .starting || recorder.phase == .stopping)
        }
    }
}

/// Live Translation has no page of its own (it runs only while a meeting is
/// recorded), so its tile switches it on or off; right-click for the
/// caption window and the language.
private struct TranslateHubTile: View {
    @EnvironmentObject private var liveTranslation: LiveTranslationController

    var body: some View {
        let on = liveTranslation.isEnabled
        AgentTile(title: on ? "Translate On" : "Translate", systemImage: "captions.bubble.fill", tint: .green,
                  isHighlighted: on, help: on
                    ? "Live Translation is on: meeting captions in \(LiveTranslationLanguages.displayName(liveTranslation.targetLanguage)). Click to turn off."
                    : "Translate meeting captions live. Click to turn on.") {
            liveTranslation.isEnabled.toggle()
        }
        .contextMenu {
            Toggle("Translate Meetings Live", isOn: $liveTranslation.isEnabled)
            Picker("Translate To", selection: $liveTranslation.targetLanguage) {
                ForEach(liveTranslation.targets, id: \.self) { id in
                    Text(LiveTranslationLanguages.displayName(id)).tag(id)
                }
            }
            Button("Open Caption Window") { liveTranslation.openCaptionWindow() }
        }
    }
}

private struct AgentTile: View {
    let title: String
    let systemImage: String
    /// The agent's own color. Apple draws the glyph in it (and washes the
    /// tile with it while the agent is on); SparkV Red draws every tile
    /// monochrome and lights it red on hover or while the agent is on.
    let tint: Color
    /// Lit while the agent is on (e.g. Live Translation, a recording).
    var isHighlighted = false
    var help: String? = nil
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        Button(action: action) {
            if SparkVTheme.usesTileTints {
                appleFace(shape)
            } else {
                sparkvFace(shape)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help ?? title)
    }

    /// Apple: a dark Control Center tile, the glyph in the agent's color, a
    /// white label; hover lifts the tile, an active agent gets a tint wash.
    private func appleFace(_ shape: RoundedRectangle) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(isHighlighted || hover.isOn ? 1 : 0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(
            shape.fill(isHighlighted ? tint.opacity(0.24) : Color.white.opacity(hover.isOn ? 0.14 : 0.08))
        )
        .overlay(
            shape.strokeBorder(isHighlighted ? tint.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(shape)
        .animation(.easeOut(duration: 0.12), value: hover.isOn)
    }

    /// SparkV Red: monochrome tiles lit red (sparkv.si).
    private func sparkvFace(_ shape: RoundedRectangle) -> some View {
        let lit = isHighlighted || hover.isOn
        return VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(lit ? SparkVTheme.red : SparkVTheme.text.opacity(0.88))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(lit ? SparkVTheme.text : SparkVTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(
            shape.fill(isHighlighted ? SparkVTheme.redSoft : (hover.isOn ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface))
        )
        .overlay(
            shape.strokeBorder(lit ? SparkVTheme.red.opacity(isHighlighted ? 0.55 : 0.35) : SparkVTheme.stroke, lineWidth: 1)
        )
        .contentShape(shape)
    }
}
