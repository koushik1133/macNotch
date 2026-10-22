import AppKit
import SwiftUI

enum UniversalSearchPanelMetrics {
    static let cardSize = CGSize(width: 680, height: 468)
    /// Transparent margin for the card's shadow.
    static let margin: CGFloat = 22
    static var panelSize: CGSize {
        CGSize(width: cardSize.width + 2 * margin, height: cardSize.height + 2 * margin)
    }
}

/// Spotlight/Raycast-style launcher window: a non-activating floating panel
/// (the pattern of Cindori's FloatingPanel and of Alfred/Raycast), so it
/// takes keystrokes without activating SparkV and the app you were in stays
/// frontmost — ⌘↩ "Paste" lands there. Clicking elsewhere closes it.
final class UniversalSearchPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = "SparkV Search"
        appearance = NSAppearance(named: .darkAqua)
        // SparkV is an agent app that is never active; without this the
        // chips' and buttons' help tags never appear.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Shows and hides the panel for a `UniversalSearchController`, and handles
/// the ⌘ shortcuts (this agent app has no Edit menu, so ⌘V/⌘X/⌘A/⌘Z are
/// forwarded to the field editor, as Prompt Refiner does).
@MainActor
final class UniversalSearchPanelController: NSObject {
    private weak var controller: UniversalSearchController?
    private var panel: UniversalSearchPanel?
    private var recordMonitor: Any?
    private var closing = false

    var isOpen: Bool { panel?.isVisible ?? false }
    var window: NSWindow? { panel }

    init(controller: UniversalSearchController) {
        self.controller = controller
        super.init()
        controller.requestOpen = { [weak self] in self?.show() }
        controller.requestClose = { [weak self] in self?.hide() }
    }

    func show() {
        guard let controller else { return }
        let panel = panel ?? makePanel(controller)
        self.panel = panel
        let wasVisible = panel.isVisible
        if !wasVisible {
            panel.setFrame(initialFrame(), display: false)
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        installRecordMonitor()
    }

    func hide() {
        removeRecordMonitor()
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        panel.orderOut(nil)
        closing = false
        if controller?.isPanelOpen == true { controller?.closePanel() }
    }

    private func makePanel(_ controller: UniversalSearchController) -> UniversalSearchPanel {
        let size = UniversalSearchPanelMetrics.panelSize
        let panel = UniversalSearchPanel(contentRect: NSRect(origin: .zero, size: size))
        let hosting = NotchHostingView(rootView: UniversalSearchPanelView(controller: controller).followsAppearance())
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.onCancel = { [weak controller] in controller?.escape() }
        panel.onResignKey = { [weak self] in
            // Clicking elsewhere closes it, like Spotlight. Ignore the
            // resign that ordering out itself causes.
            guard let self, !self.closing, self.panel?.isVisible == true,
                  self.controller?.isRecordingShortcut != true else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
                self.controller?.closePanel()
            }
        }
        panel.onKeyEquivalent = { [weak self] event in
            let key = UniversalSearchKeyPress(event)
            return MainActor.assumeIsolated { self?.handle(key) ?? false }
        }
        return panel
    }

    /// Upper third of the screen under the pointer, below the notch.
    private func initialFrame() -> NSRect {
        let size = UniversalSearchPanelMetrics.panelSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return NSRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        let x = (screen.frame.midX - size.width / 2).rounded()
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top + 60, screen.frame.height * 0.16)
        let y = max(visible.minY, top - size.height + UniversalSearchPanelMetrics.margin)
        return NSRect(x: max(visible.minX, min(x, visible.maxX - size.width)), y: y, width: size.width, height: size.height)
    }

    // MARK: Keys

    func handle(_ key: UniversalSearchKeyPress) -> Bool {
        guard let controller, let panel, panel.isVisible else { return false }
        let flags = key.flags
        if controller.isRecordingShortcut { return false }
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        if flags.contains(.option) { return false }
        switch key.keyCode {
        case 36, 76: // Return / Enter
            controller.submit(alternate: true)
            return true
        case 126: // Up
            controller.jumpSection(-1)
            return true
        case 125: // Down
            controller.jumpSection(1)
            return true
        default:
            break
        }
        if let digit = Int(key.characters), (0...UniversalSearchSource.allCases.count).contains(digit) {
            controller.setSourceFilter(digit == 0 ? nil : UniversalSearchSource.allCases[digit - 1])
            return true
        }
        let selector: Selector
        switch key.characters {
        case "c":
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
                selector = #selector(NSText.copy(_:))
            } else {
                controller.copySelected()
                return true
            }
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "d":
            controller.cycleDateFilter()
            return true
        case "w":
            controller.closePanel()
            return true
        case "/", "?":
            controller.toggleAsk()
            return true
        default:
            return false
        }
        return NSApp.sendAction(selector, to: nil, from: panel)
    }

    /// While recording a new shortcut, the next key press is the shortcut.
    private func installRecordMonitor() {
        guard recordMonitor == nil else { return }
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = UniversalSearchKeyPress(event)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let controller = self.controller, controller.isRecordingShortcut,
                      key.windowNumber == self.panel?.windowNumber else { return false }
                return controller.recordShortcut(keyCode: key.keyCode, modifiers: key.flags)
            }
            return consumed ? nil : event
        }
    }

    private func removeRecordMonitor() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
    }
}

struct UniversalSearchKeyPress: Sendable {
    let windowNumber: Int
    let keyCode: UInt16
    let flags: NSEvent.ModifierFlags
    let characters: String

    init(_ event: NSEvent) {
        windowNumber = event.windowNumber
        keyCode = event.keyCode
        flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
    }

    init(windowNumber: Int, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String) {
        self.windowNumber = windowNumber
        self.keyCode = keyCode
        self.flags = flags
        self.characters = characters
    }
}

// MARK: - Search field

/// An NSTextField so arrow keys, Return, Tab and Esc can drive the list
/// through the field editor's commands (`control(_:textView:doCommandBy:)`,
/// the standard way Spotlight-style fields do it; ⌃N/⌃P map to moveDown:/
/// moveUp: in the Cocoa key bindings, as Raycast's Emacs keys do).
struct UniversalSearchField: NSViewRepresentable {
    @ObservedObject var controller: UniversalSearchController
    var fontSize: CGFloat = 19
    var placeholder: String
    /// In the notch drawer: Enter/Tab ask in the panel, Esc only clears.
    var inDrawer = false

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, inDrawer: inDrawer) }

    func makeNSView(context: Context) -> NSTextField {
        let field = UniversalSearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isBezeled = false
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.textColor = NSColor(SparkVTheme.text)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.handlesEditingKeys = inDrawer
        field.onCopyResult = { [weak controller] in controller?.copySelected() }
        field.stringValue = controller.query
        field.setAccessibilityLabel("Search")
        applyPlaceholder(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.controller = controller
        if field.stringValue != controller.query {
            field.stringValue = controller.query
        }
        applyPlaceholder(field)
        if context.coordinator.focusToken != controller.focusToken {
            context.coordinator.focusToken = controller.focusToken
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                if window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                    // Put the caret at the end instead of selecting it all.
                    if let editor = field.currentEditor() {
                        editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
                    }
                }
            }
        }
    }

    private func applyPlaceholder(_ field: NSTextField) {
        guard field.placeholderAttributedString?.string != placeholder else { return }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.36),
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
        ])
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var controller: UniversalSearchController
        let inDrawer: Bool
        var focusToken = -1

        init(controller: UniversalSearchController, inDrawer: Bool = false) {
            self.controller = controller
            self.inDrawer = inDrawer
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            controller.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                controller.move(-1)
            case #selector(NSResponder.moveDown(_:)):
                controller.move(1)
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                controller.move(-6)
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                controller.move(6)
            case #selector(NSResponder.moveToBeginningOfDocument(_:)):
                controller.jumpSection(-1)
            case #selector(NSResponder.moveToEndOfDocument(_:)):
                controller.jumpSection(1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                let alternate = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                if inDrawer { controller.submitFromDrawer(alternate: alternate) } else { controller.submit(alternate: alternate) }
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                if inDrawer { controller.askInPanel() } else { controller.toggleAsk() }
            case #selector(NSResponder.cancelOperation(_:)):
                if inDrawer {
                    if controller.query.isEmpty { return false }
                    controller.query = ""
                } else {
                    controller.escape()
                }
            default:
                return false
            }
            return true
        }
    }
}

final class UniversalSearchTextField: NSTextField {
    /// In the notch drawer: the notch panel has no Edit menu and no key
    /// equivalents of its own, so ⌘V/⌘X/⌘A/⌘Z (and ⌘C) are handled here
    /// while this field is being edited. The floating panel does the same in
    /// its `performKeyEquivalent`.
    var handlesEditingKeys = false
    /// ⌘C with no text selected copies the selected result.
    var onCopyResult: (() -> Void)?
    private var keyMonitor: Any?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SparkV Red: a red caret, like the brand's focus color. Apple: the system caret.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = SparkVTheme.isApple ? NSColor.textColor : NSColor(SparkVTheme.brandRed)
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, handlesEditingKeys { installKeyMonitor() } else { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = UniversalSearchKeyPress(event)
            let consumed = MainActor.assumeIsolated { self?.handleEditingKey(key) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// True when the key was used.
    func handleEditingKey(_ key: UniversalSearchKeyPress) -> Bool {
        guard handlesEditingKeys, let window, window.isKeyWindow, key.windowNumber == window.windowNumber,
              let editor = currentEditor() as? NSTextView, window.firstResponder === editor else { return false }
        let flags = key.flags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let selector: Selector
        switch key.characters {
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "c":
            if editor.selectedRange().length > 0 {
                selector = #selector(NSText.copy(_:))
            } else if let onCopyResult {
                onCopyResult()
                return true
            } else {
                return false
            }
        default:
            return false
        }
        return NSApp.sendAction(selector, to: editor, from: self) || NSApp.sendAction(selector, to: nil, from: self)
    }
}
