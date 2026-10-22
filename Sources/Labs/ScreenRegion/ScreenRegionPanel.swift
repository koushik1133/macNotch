import AppKit
import SwiftUI

// The results panel: a small dark glass panel anchored beside the selection
// with quick actions, a question field, the streamed answer and Copy.

enum ScreenRegionPanelMetrics {
    static let size = CGSize(width: 400, height: 480)
}

/// Borderless, key-capable floating panel; Esc closes it.
final class ScreenRegionResultsPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = "Ask about screen"
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Shows/hides the results panel. While it is open the app is regular and
/// active (as TrayAIPanelController does) so the question field gets keys;
/// closing goes back to `.accessory` and re-activates the app that was in
/// front before the selection.
@MainActor
final class ScreenRegionPanelController {
    var onClose: (() -> Void)?
    private var panel: ScreenRegionResultsPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    var isOpen: Bool { panel?.isVisible ?? false }
    /// The app to return to when the panel closes.
    var returnApp: NSRunningApplication? { previousApp }

    func show(_ session: ScreenRegionSession, controller: ScreenRegionController, previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
        let size = ScreenRegionPanelMetrics.size
        let panel = panel ?? ScreenRegionResultsPanel(contentRect: NSRect(origin: .zero, size: size))
        self.panel = panel
        panel.onCancel = { [weak self] in self?.close() }
        let hosting = NotchHostingView(rootView: ScreenRegionResultsView(session: session, controller: controller).followsAppearance())
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(size)

        let anchor = session.capture.selection.appKitRect
        let screen = ScreenRegionCapture.screen(for: session.capture.selection.display) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -size.width, dy: -size.height)
        panel.setFrame(ScreenRegionGeometry.panelFrame(size: size, beside: anchor, in: visible), display: false)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    /// `reactivating: false` when a new selection starts right away.
    func close(reactivating: Bool = true) {
        removeKeyMonitor()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        let stillOpen = NSApp.windows.contains { $0 !== panel && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        if reactivating, let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
        onClose?()
    }

    // MARK: Keys

    /// Esc and ⌘W close; ⌘C/V/X/A/Z reach the text views (the agent app has
    /// no Edit menu to supply those key equivalents).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = ScreenRegionKeyPress(
                windowNumber: event.windowNumber,
                keyCode: event.keyCode,
                flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                characters: event.charactersIgnoringModifiers?.lowercased() ?? ""
            )
            let consumed = MainActor.assumeIsolated { self?.handle(key) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ key: ScreenRegionKeyPress) -> Bool {
        guard let panel, panel.isVisible, key.windowNumber == panel.windowNumber else { return false }
        if key.keyCode == 53 {
            close()
            return true
        }
        guard key.flags.contains(.command), !key.flags.contains(.control), !key.flags.contains(.option) else { return false }
        let selector: Selector
        switch key.characters {
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = key.flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "w":
            close()
            return true
        default:
            return false
        }
        return NSApp.sendAction(selector, to: nil, from: panel)
    }
}

private struct ScreenRegionKeyPress: Sendable {
    let windowNumber: Int
    let keyCode: UInt16
    let flags: NSEvent.ModifierFlags
    let characters: String
}

// MARK: - Views

struct ScreenRegionResultsView: View {
    @ObservedObject var session: ScreenRegionSession
    @ObservedObject var controller: ScreenRegionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScreenRegionFlowLayout(spacing: 6) {
                ForEach(ScreenRegionAction.quickActions) { action in
                    ScreenRegionChip(
                        title: action.chipTitle, systemImage: action.systemImage,
                        isActive: session.running == action
                    ) { session.run(action) }
                    .disabled(session.isRunning && session.running != action)
                }
                translateMenu
            }
            questionField
            result
            footer
        }
        .padding(14)
        .frame(width: ScreenRegionPanelMetrics.size.width, height: ScreenRegionPanelMetrics.size.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SparkVTheme.background.opacity(SparkVTheme.isApple ? 0.62 : 0.88)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SparkVTheme.stroke))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
        .tint(SparkVTheme.accent)
        .foregroundStyle(SparkVTheme.text)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: session.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
                .help("The captured selection. Click to copy the image")
                .onTapGesture { session.copyImage() }
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask about screen").font(SparkVTheme.headline(14)).tracking(-0.2)
                Text(session.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            ScreenRegionIconButton(systemImage: "viewfinder", help: "Select again") { controller.beginSelection() }
            if controller.canOpenInTrayAI {
                ScreenRegionIconButton(systemImage: "sparkles.rectangle.stack", help: "Open in Tray AI") { controller.openInTrayAI(session) }
            }
            ScreenRegionIconButton(systemImage: "xmark", help: "Close (Esc)") { controller.closePanel() }
        }
    }

    private var translateMenu: some View {
        Menu {
            ForEach(TrayAISettings.languages, id: \.self) { language in
                Button(language) {
                    TrayAISettings.translateTarget = language
                    session.run(.translate(language))
                }
            }
        } label: {
            Text("into \(TrayAISettings.translateTarget)")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .tint(SparkVTheme.text)
        .fixedSize()
        .help("Translate into another language")
        .disabled(session.isRunning)
    }

    private var questionField: some View {
        HStack(spacing: 6) {
            TextField("Ask anything about this selection…", text: $session.question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { session.ask() }
            Button {
                session.isRunning ? session.cancel() : session.ask()
            } label: {
                Image(systemName: session.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.question.isEmpty && !session.isRunning ? SparkVTheme.textTertiary : SparkVTheme.accent)
            .help(session.isRunning ? "Stop" : "Ask")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .labsFieldWell(SparkVTheme.cornerMedium)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let action = session.lastAction {
                        Text(action.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let error = session.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(SparkVTheme.warning)
                    } else if !session.text.isEmpty {
                        Text(session.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if session.lastAction == nil {
                        Text("Pick an action or ask a question. Everything runs on this Mac unless you turn on Groq below.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let status = session.status {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if session.openURL != nil {
                        Button { session.openSearch() } label: {
                            Label("Open search in browser", systemImage: "safari")
                        }
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: .infinity)
            .labsCard(SparkVTheme.cornerMedium)

            if !session.detected.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.detected) { item in
                            ScreenRegionChip(title: String(item.text.prefix(36)), systemImage: item.systemImage, isActive: false) {
                                session.use(item)
                            }
                            .help(item.url != nil ? "Open \(item.text)" : "Copy \(item.text)")
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $controller.allowGroq) {
                Text(controller.groqKeySaved ? "Groq" : "Groq (no key)")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .fixedSize()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Off: everything stays on this Mac. On: the selection image and its text are sent to Groq with Clicky's API key.")
            if let producedBy = session.producedBy {
                Text(producedBy).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    .help(producedBy)
            }
            Spacer(minLength: 4)
            if controller.canSaveToTray {
                Button("Save to Tray") { controller.saveToTray(session) }
                    .buttonStyle(LabsSecondaryButtonStyle())
            }
            Button(session.justCopied ? "Copied" : "Copy") { session.copyAnswer() }
                .buttonStyle(LabsPrimaryButtonStyle())
                .disabled(session.text.isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }
}

struct ScreenRegionChip: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isActive {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hover.isOn ? SparkVTheme.accent : SparkVTheme.textSecondary)
                }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isActive ? SparkVTheme.accentSoft : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(Capsule().strokeBorder(isActive ? SparkVTheme.accent.opacity(0.5) : hover.isOn ? SparkVTheme.choose(apple: Color.white.opacity(0.18), sparkv: SparkVTheme.brandRed.opacity(0.5)) : SparkVTheme.stroke))
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}

struct ScreenRegionIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .background(Circle().fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
                .overlay(Circle().strokeBorder(SparkVTheme.stroke))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover.isOn = $0 }
    }
}

/// Wrapping row layout for the action chips.
struct ScreenRegionFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 400
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        for row in rows {
            for (index, x) in zip(row.indices, row.xs) {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var xs: [CGFloat] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                let previous = rows[rows.count - 1]
                rows.append(Row(y: previous.y + previous.height + spacing))
                x = 0
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].xs.append(x)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}
