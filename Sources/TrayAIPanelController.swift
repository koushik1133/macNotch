import AppKit
import SwiftUI

/// Floating, movable panel that takes keyboard input (the message field).
/// Borderless so the two glass cards float on their own; Esc closes it.
final class TrayAIPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // isFloatingPanel resets `level` to .floating, so it must come first.
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // The cards draw their own shadows; a window shadow would outline
        // the transparent margin around them.
        hasShadow = false
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = "Tray AI"
        // The reference panel is dark frosted glass in both system appearances.
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    /// Main-capable, so other windows' "is anything still open?" checks keep
    /// the Dock icon while this panel is up.
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Shows the Tray AI panel: the selected tray item(s) on the left, AI
/// actions on the right. NotchIsland is an agent app, so while the panel is
/// open the app is made regular and active (as the Face Unlock settings
/// window does) so the message field gets keystrokes; closing it goes back
/// to `.accessory` unless another real window is still open.
@MainActor
final class TrayAIPanelController: NSObject {
    static let shared = TrayAIPanelController()

    /// Saves a result into the tray as a text item. Wire to `TrayStore.addText`.
    var onSaveToTray: ((String) -> Void)? {
        didSet { model.onSaveToTray = onSaveToTray }
    }

    private let model = TrayAIPanelModel()
    private var panel: TrayAIPanel?
    private var keyMonitor: Any?

    var isOpen: Bool { panel?.isVisible ?? false }

    private override init() {
        super.init()
        model.onClose = { [weak self] in self?.close() }
    }

    func open(items: [TrayItem], initialAction: TrayAIAction? = nil) {
        guard !items.isEmpty else {
            AppLog.log("Tray AI: open with no items ignored")
            return
        }
        model.onSaveToTray = onSaveToTray
        model.load(items)

        let panel = panel ?? makePanel()
        let wasVisible = panel.isVisible
        self.panel = panel
        if !wasVisible {
            panel.setFrame(initialFrame(), display: false)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        installKeyMonitor()
        AppLog.log("Tray AI: panel open with \(items.count) item(s)")

        if let initialAction {
            model.run(initialAction)
        }
    }

    func close() {
        model.cancel()
        removeKeyMonitor()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        let stillOpen = NSApp.windows.contains { $0 !== panel && $0.canBecomeMain && $0.isVisible }
        if !stillOpen {
            NSApp.setActivationPolicy(.accessory)
        }
        AppLog.log("Tray AI: panel closed")
    }

    // MARK: Window

    private func makePanel() -> TrayAIPanel {
        let size = TrayAIPanelMetrics.panelSize
        let panel = TrayAIPanel(contentRect: NSRect(origin: .zero, size: size))
        let hosting = NotchHostingView(rootView: TrayAIPanelView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    /// Top center of the screen under the pointer, just below the menu bar
    /// (and the notch drawer hanging from it).
    private func initialFrame() -> NSRect {
        let size = TrayAIPanelMetrics.panelSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return NSRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        // Leave room for the open notch drawer on notched displays.
        let notchClearance: CGFloat = screen.safeAreaInsets.top > 0 ? 70 : 8
        let x = (screen.frame.midX - size.width / 2).rounded()
        let y = max(visible.minY, visible.maxY - size.height - notchClearance + TrayAIPanelMetrics.margin)
        return NSRect(x: max(visible.minX, min(x, visible.maxX - size.width)), y: y, width: size.width, height: size.height)
    }

    // MARK: Keys

    /// Esc closes; Cmd-C/V/X/A/Z work in the text views even though this
    /// agent app has no Edit menu to supply those key equivalents; Cmd-W
    /// closes.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = TrayAIKeyPress(
                windowNumber: event.windowNumber,
                keyCode: event.keyCode,
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

    /// Returns true when the key was handled here.
    private func handleKey(_ key: TrayAIKeyPress) -> Bool {
        guard let panel, panel.isVisible, key.windowNumber == panel.windowNumber else { return false }
        if key.keyCode == 53 { // Escape
            close()
            return true
        }
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
            close()
            return true
        default:
            return false
        }
        return NSApp.sendAction(selector, to: nil, from: panel)
    }
}

/// The parts of a key event the panel looks at (NSEvent isn't Sendable).
private struct TrayAIKeyPress: Sendable {
    let windowNumber: Int
    let keyCode: UInt16
    let flags: NSEvent.ModifierFlags
    let characters: String
}
