import AppKit
import SwiftUI

enum PromptRefinerPanelMetrics {
    static let cardSize = CGSize(width: 580, height: 560)
    static let margin: CGFloat = 16
    static var panelSize: CGSize {
        CGSize(width: cardSize.width + 2 * margin, height: cardSize.height + 2 * margin)
    }
}

/// The floating glass panel for the question-and-answer loop. Reuses the Tray
/// AI panel window (borderless, floating, movable, Esc closes). While it is
/// open the agent app is made regular and active so the text views get
/// keystrokes, as Tray AI does; closing goes back to `.accessory` unless
/// another real window is open.
@MainActor
final class PromptRefinerPanelController: NSObject {
    private weak var controller: PromptRefinerController?
    private var panel: TrayAIPanel?
    private var keyMonitor: Any?

    var isOpen: Bool { panel?.isVisible ?? false }

    init(controller: PromptRefinerController) {
        self.controller = controller
        super.init()
    }

    func open() {
        guard let controller else { return }
        let panel = panel ?? makePanel(controller)
        let wasVisible = panel.isVisible
        self.panel = panel
        if !wasVisible { panel.setFrame(initialFrame(), display: false) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SparkVMotion.Duration.release
                // Strong ease-out (cubic-bezier(0.23, 1, 0.32, 1)).
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                panel.animator().alphaValue = 1

            }
        }
        installKeyMonitor()
        AppLog.log("Prompt Refiner: panel open")
    }

    func close() {
        removeKeyMonitor()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        let stillOpen = NSApp.windows.contains { $0 !== panel && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        AppLog.log("Prompt Refiner: panel closed")
    }

    private func makePanel(_ controller: PromptRefinerController) -> TrayAIPanel {
        let size = PromptRefinerPanelMetrics.panelSize
        let panel = TrayAIPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.title = "Prompt Refiner"
        let hosting = NotchHostingView(rootView: PromptRefinerPanelView(controller: controller).followsAppearance())
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.onCancel = { [weak self] in self?.controller?.closePanel() }
        return panel
    }

    /// Top center of the screen under the pointer, below the notch drawer.
    private func initialFrame() -> NSRect {
        let size = PromptRefinerPanelMetrics.panelSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return NSRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        let notchClearance: CGFloat = screen.safeAreaInsets.top > 0 ? 70 : 8
        let x = (screen.frame.midX - size.width / 2).rounded()
        let y = max(visible.minY, visible.maxY - size.height - notchClearance + PromptRefinerPanelMetrics.margin)
        return NSRect(x: max(visible.minX, min(x, visible.maxX - size.width)), y: y, width: size.width, height: size.height)
    }

    // MARK: Keys

    /// Esc / Cmd-W close; Cmd-Return runs the primary action; Cmd-C/V/X/A/Z
    /// work in the text views (this agent app has no Edit menu).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = PromptRefinerKeyPress(
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

    private func handle(_ key: PromptRefinerKeyPress) -> Bool {
        guard let panel, panel.isVisible, key.windowNumber == panel.windowNumber else { return false }
        if key.keyCode == 53 { // Escape
            controller?.closePanel()
            return true
        }
        let flags = key.flags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        if key.keyCode == 36 || key.keyCode == 76 { // Return / Enter
            controller?.primaryAction()
            return true
        }
        let selector: Selector
        switch key.characters {
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "w":
            controller?.closePanel()
            return true
        default:
            return false
        }
        return NSApp.sendAction(selector, to: nil, from: panel)
    }
}

private struct PromptRefinerKeyPress: Sendable {
    let windowNumber: Int
    let keyCode: UInt16
    let flags: NSEvent.ModifierFlags
    let characters: String
}

extension PromptRefinerController {
    /// Cmd-Return: whatever the main button of the current step does.
    func primaryAction() {
        if showsHistory {
            showsHistory = false
            return
        }
        switch phase {
        case .compose, .failed: refine()
        case .answering: submitAnswers()
        case .done: copyRefined()
        case .askingQuestions, .refining: break
        }
    }
}
