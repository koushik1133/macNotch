import AppKit
import SwiftUI

/// What the overlay panel draws.
@MainActor
final class HUDOverlayModel: ObservableObject {
    @Published var content = HUDContent(style: .volume(muted: false, deviceName: nil), level: 0)
    @Published var style: HUDStyle = .pill
    @Published var showsPercent = true
}

/// Root of the overlay panel: the pill or the edge bar, centered in a margin
/// that leaves room for the shadow. Redrawn when the look changes.
private struct HUDOverlayRoot: View {
    @ObservedObject var model: HUDOverlayModel

    var body: some View {
        Group {
            switch model.style {
            case .edgeBar:
                HUDEdgeBarView(content: model.content, showsPercent: model.showsPercent)
            default:
                HUDPillView(content: model.content, showsPercent: model.showsPercent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

/// A borderless, click-through panel for HUDs that aren't drawn by the island:
/// the pill and edge bar styles, and every display that has no island.
/// Same window traits as the island's panel (all Spaces, over full-screen
/// apps, never key, never in the window cycle).
final class HUDOverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Shows the overlay HUD on a screen and hides it after a while. The panel is
/// made on first use and kept; nothing runs while it is hidden.
@MainActor
final class HUDOverlayPresenter {
    private var panel: HUDOverlayPanel?
    private let model = HUDOverlayModel()
    private var hideTask: Task<Void, Never>?
    private(set) var isShowing = false

    /// Shows `content` in `style` (pill or edge bar) on `screen` for
    /// `duration` seconds. Key presses show it at once (keyboard-triggered UI
    /// doesn't animate in); hiding fades out.
    func show(_ content: HUDContent, style: HUDStyle, on screen: NSScreen, edge: HUDEdge, showsPercent: Bool, duration: TimeInterval) {
        let panel = panel ?? makePanel()
        let overlayStyle: HUDStyle = style == .edgeBar ? .edgeBar : .pill
        model.content = content
        model.style = overlayStyle
        model.showsPercent = showsPercent

        let frame = Self.frame(style: overlayStyle, screen: screen.frame, visible: screen.visibleFrame, edge: edge)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        // Cut short a fade-out still running from the last hide.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        if !isShowing || !panel.isVisible { panel.orderFrontRegardless() }
        isShowing = true

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide(animated: Bool = true) {
        hideTask?.cancel()
        hideTask = nil
        guard isShowing, let panel else { return }
        isShowing = false
        if animated {
            LiveBandMotion.fadeOut(panel, duration: SparkVMotion.Duration.hover)
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    /// Panel frame for a style on a screen (AppKit coordinates).
    static func frame(style: HUDStyle, screen: CGRect, visible: CGRect, edge: HUDEdge) -> CGRect {
        HUDOverlayLayout.frame(style: style, screen: screen, visible: visible, edge: edge)
    }

    private func makePanel() -> HUDOverlayPanel {
        let panel = HUDOverlayPanel()
        let host = NSHostingView(rootView: HUDOverlayRoot(model: model).followsAppearance())
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}
