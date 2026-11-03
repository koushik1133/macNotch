import AppKit
import SwiftUI

enum ReplyBarMetrics {
    static let cardSize = CGSize(width: 590, height: 196)
    static let margin: CGFloat = 12
    static var panelSize: CGSize { CGSize(width: cardSize.width + 2 * margin, height: cardSize.height + 2 * margin) }
}

/// A floating bar that never takes focus: clicks on it leave the other app
/// (and its message box) active, the way Grammarly's floating button works,
/// so pasting and ⌘Z go to the right field.
final class ReplyBarPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = "Reply Drafter"
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ReplyDrafterBarController {
    private weak var controller: ReplyDrafterController?
    private var panel: ReplyBarPanel?
    /// The user dragged the bar: keep their position for this session.
    private var userMoved = false
    private var moveObserver: NSObjectProtocol?
    private var programmaticMove = false

    init(controller: ReplyDrafterController) {
        self.controller = controller
    }

    func show() {
        guard let controller else { return }
        let panel = panel ?? makePanel(controller)
        self.panel = panel
        userMoved = false
        place(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // Shortcut-triggered: a quick ease-out fade, no movement.
            LiveBandMotion.fadeIn(panel, duration: 0.14)
        }
    }

    func reposition() {
        guard let panel, panel.isVisible, !userMoved else { return }
        place(panel)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(_ controller: ReplyDrafterController) -> ReplyBarPanel {
        let size = ReplyBarMetrics.panelSize
        let panel = ReplyBarPanel(size: size)
        let hosting = NotchHostingView(rootView: ReplyDrafterBarView(controller: controller).followsAppearance())
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.programmaticMove else { return }
                self.userMoved = true
            }
        }
        return panel
    }

    private func place(_ panel: ReplyBarPanel) {
        guard let controller else { return }
        let size = ReplyBarMetrics.panelSize
        let anchor = controller.anchor
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let reference = (anchor.field ?? anchor.window).map { CGPoint(x: $0.midX, y: primaryHeight - $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(reference) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = ReplyBarGeometry.frame(
            forField: anchor.field, window: anchor.window, barSize: size, visible: screen.visibleFrame, primaryHeight: primaryHeight, gap: 2
        )
        programmaticMove = true
        panel.setFrame(frame, display: true)
        programmaticMove = false
    }
}

// MARK: - Bar view

struct ReplyDrafterBarView: View {
    @ObservedObject var controller: ReplyDrafterController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let notice = noticeText {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !isFailed { actions }
        }
        .padding(12)
        .frame(width: ReplyBarMetrics.cardSize.width, height: ReplyBarMetrics.cardSize.height)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SparkVTheme.background.opacity(0.97))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SparkVTheme.stroke))
        .padding(ReplyBarMetrics.margin)
        .environment(\.colorScheme, .dark)
        .tint(SparkVTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: controller.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LabsTint.feature)
            Text("Reply")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
            Text(controller.contextLine)
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let space = controller.spaceName {
                ReplyChip(systemImage: "square.stack.3d.up.fill", text: space)
            }
            if controller.readFromScreen {
                ReplyChip(systemImage: "text.viewfinder", text: "Read on screen")
            }
            if !controller.engineLabel.isEmpty, controller.draft != nil {
                ReplyChip(systemImage: controller.engineLabel == ReplyDraftEngine.groqName ? "cloud" : "lock.fill",
                          text: controller.engineLabel == ReplyDraftEngine.onDeviceName ? "On this Mac" : controller.engineLabel)
            }
            ReplyIconButton(systemImage: "xmark", help: "Close (the text stays as it is)") { controller.close() }
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle, .reading, .drafting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text(controller.phase == .reading ? "Reading the conversation…" : "Drafting a reply in your tone…")
                    .font(.system(size: 12))
                    .foregroundStyle(SparkVTheme.text.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(message).font(.system(size: 12)).foregroundStyle(SparkVTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(SparkVTheme.warning)
                }
                HStack(spacing: 6) {
                    if controller.needsAccessibility {
                        ReplyActionButton(title: "Open Accessibility Settings", systemImage: "hand.raised.fill", isPrimary: true) {
                            controller.openAccessibilitySettings()
                        }
                    }
                    if controller.suggestsScreenRecording {
                        ReplyActionButton(title: "Allow Screen Recording", systemImage: "rectangle.dashed.badge.record", isPrimary: true) {
                            controller.allowScreenRecording()
                        }
                    }
                    ReplyActionButton(title: "Try Again", systemImage: "arrow.clockwise") { controller.draftReply() }
                }
            }
        case .ready, .revising, .writing:
            VStack(alignment: .leading, spacing: 4) {
                if let subject = controller.draft?.subject, !subject.isEmpty {
                    HStack(spacing: 4) {
                        Text("Subject").font(.system(size: 10, weight: .semibold)).foregroundStyle(SparkVTheme.textTertiary)
                        Text(subject).font(.system(size: 11, weight: .medium)).foregroundStyle(SparkVTheme.text).lineLimit(1)
                    }
                }
                ScrollView(.vertical, showsIndicators: true) {
                    Text(controller.draft?.body ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(SparkVTheme.text.opacity(controller.isInField || !(controller.draft?.body.isEmpty ?? true) ? 0.95 : 0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .labsCard(SparkVTheme.cornerSmall)
                .overlay(alignment: .bottomTrailing) {
                    if case .revising(let revision) = controller.phase {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text(revision.title + "…").font(.system(size: 10)).foregroundStyle(SparkVTheme.textSecondary)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(SparkVTheme.background.opacity(0.85)))
                        .padding(5)
                    }
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    private var noticeText: String? {
        switch controller.phase {
        case .ready, .revising, .writing: controller.notice
        default: nil
        }
    }

    private var actions: some View {
        let ready = controller.phase == .ready
        let hasDraft = controller.draft != nil
        return HStack(spacing: 4) {
            ReplyActionButton(title: "Undo", systemImage: "arrow.uturn.backward") { controller.undo() }
                .disabled(!ready || !controller.canUndo)
            ReplyActionButton(title: "Redo", systemImage: "arrow.uturn.forward") { controller.redo() }
                .disabled(!ready || !controller.canRedo)
            Rectangle().fill(SparkVTheme.stroke).frame(width: 1, height: 16).padding(.horizontal, 2)
            ForEach(ReplyRevision.allCases, id: \.self) { revision in
                ReplyActionButton(title: revision.title, systemImage: nil) { controller.revise(revision) }
                    .disabled(!ready || !hasDraft)
            }
            Spacer(minLength: 0)
            if hasDraft, !controller.isInField {
                ReplyActionButton(title: "Insert", systemImage: "text.insert", isPrimary: true) { controller.insertIntoField() }
                    .disabled(!ready)
            }
            ReplyIconButton(systemImage: "doc.on.doc", help: "Copy the draft") { controller.copyDraft() }
                .disabled(!hasDraft)
        }
    }
}

struct ReplyChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8.5, weight: .semibold))
            Text(text.count > 22 ? String(text.prefix(21)) + "…" : text).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(SparkVTheme.textSecondary)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
        .fixedSize()
    }
}

struct ReplyActionButton: View {
    let title: String
    let systemImage: String?
    var isPrimary = false
    let action: () -> Void

    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 9.5, weight: .semibold)) }
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(isPrimary ? Color.white.opacity(isEnabled ? 1 : 0.6) : SparkVTheme.text.opacity(isEnabled ? 0.92 : 0.35))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                Capsule().fill(isPrimary ? SparkVTheme.accent.opacity(isEnabled ? 1 : 0.4) : (hover.isOn && isEnabled ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(Capsule().strokeBorder(isPrimary ? Color.clear : (hover.isOn && isEnabled ? SparkVTheme.choose(apple: Color.white.opacity(0.18), sparkv: SparkVTheme.brandRed.opacity(0.45)) : SparkVTheme.stroke)))
            .contentShape(Capsule())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(title)
    }
}

struct ReplyIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isEnabled ? (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary) : Color.white.opacity(0.3))
                .frame(width: 24, height: 22)
                .background(Circle().fill(hover.isOn && isEnabled ? SparkVTheme.surfaceHover : Color.clear))
                .contentShape(Rectangle())
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Band under the notch while drafting (~360×30 pt, dark).
struct ReplyDrafterActivityView: View {
    let text: String
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LabsTint.feature)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
