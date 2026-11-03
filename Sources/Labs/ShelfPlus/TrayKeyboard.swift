import AppKit
import Combine
import Quartz
import SwiftUI

/// Keyboard control of the Tray, Finder style:
///
/// - Space: Quick Look (again or Esc: close) · ← →: previous / next
///   (⇧ extends the selection) · ⌘A: select all · Delete: remove (⌘Z puts
///   it back) · Return: open · ⌘C: copy · Esc: deselect.
///
/// The notch panel never takes the keyboard on hover. A click on a card
/// makes a tiny invisible key panel (`TrayKeyPanel`, non-activating, so
/// the frontmost app stays active) key, with the responder view as its
/// content; a local key monitor, alive only while the Tray is on screen,
/// handles keys only while that responder is first. When the drawer
/// closes, that key panel is ordered out, which hands key status back to
/// the app the user was in. The notch panel itself is never re-ordered,
/// so its level and stacking against the other SparkV panels (camera
/// mirror, live bands) stay put and no occlusion change fires.
@MainActor
final class TrayKeyboard: ObservableObject {
    static let shared = TrayKeyboard()

    /// Keystrokes go to the Tray right now (drawn as a hint in the header).
    @Published private(set) var hasFocus = false

    /// What the keys act on. Set by TrayView.
    weak var tray: TrayStore?

    private weak var responder: TrayKeyResponderView?
    /// The notch panel hosting the Tray (where the key panel sits).
    private weak var anchor: NSWindow?
    private var keyPanel: TrayKeyPanel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var collapse: AnyCancellable?

    // MARK: Lifetime (TrayView appears / disappears)

    func attach(tray: TrayStore, state: NotchState) {
        self.tray = tray
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // NSEvent isn't Sendable: hand over just what's needed.
                let press = TrayKeyPress(windowNumber: event.windowNumber, keyCode: event.keyCode,
                                         modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
                let used = MainActor.assumeIsolated { self?.handle(press) ?? false }
                return used ? nil : event
            }
        }
        // The drawer closing hands the keyboard back, even when the Tray is
        // no longer the visible tab by then.
        collapse = state.$isExpanded.removeDuplicates().dropFirst().sink { [weak self] expanded in
            guard !expanded else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.releaseFocus() } }
        }
    }

    /// The Tray left the screen. With the drawer closed, the panel stops
    /// being key; on a tab switch it stays key (text fields elsewhere).
    func detach(drawerOpen: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hasFocus = false
        if !drawerOpen { releaseFocus() }
    }

    func register(_ view: TrayKeyResponderView) {
        responder = view
    }

    /// The Tray's anchor view moved into the notch panel.
    func registerAnchor(_ window: NSWindow?) {
        anchor = window
    }

    /// The key panel, built on first use, holding the responder.
    func makeKeyPanel() -> TrayKeyPanel {
        if let keyPanel { return keyPanel }
        let panel = TrayKeyPanel()
        let view = TrayKeyResponderView(frame: NSRect(origin: .zero, size: TrayKeyPanel.size))
        panel.contentView = view
        register(view)
        keyPanel = panel
        return panel
    }

    /// A click on a card: the Tray takes the keyboard (through the key
    /// panel, placed inside the notch panel's frame).
    func focus(near window: NSWindow?) {
        guard let window, window.isVisible else { return }
        let panel = makeKeyPanel()
        panel.setFrameOrigin(NSPoint(x: window.frame.midX, y: window.frame.maxY - TrayKeyPanel.size.height))
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !panel.isKeyWindow { panel.makeKey() }
        if let responder, panel.firstResponder !== responder { panel.makeFirstResponder(responder) }
        hasFocus = panel.isKeyWindow
        watchKeyStatus(of: panel)
    }

    /// A press on a card.
    func focusFromClick() {
        focus(near: anchor)
    }

    /// The rename field closed: the Tray takes the keys again.
    func returnFocusAfterEditing() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.focus(near: self.anchor) }
        }
    }

    /// Gives key status back: the drawer never keeps the keyboard once it
    /// closes. Ordering the invisible key panel out makes AppKit pass key
    /// focus back to the active app; the notch panel isn't touched.
    func releaseFocus() {
        hasFocus = false
        TrayQuickLook.shared.close()
        guard let panel = keyPanel, panel.isVisible else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        AppLog.log("Tray: keyboard handed back to the frontmost app")
    }

    /// True while the key panel is on screen (tests).
    var isKeyPanelVisible: Bool { keyPanel?.isVisible ?? false }

    private func watchKeyStatus(of window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The user clicked into another app: drop the panel too, so
                // it never lingers as an invisible key target.
                self?.hasFocus = false
                self?.keyPanel?.orderOut(nil)
            }
        })
    }

    // MARK: Keys

    private func owns(windowNumber: Int) -> Bool {
        guard let responder, let window = responder.window, window.windowNumber == windowNumber,
              window.isKeyWindow, window.firstResponder === responder else { return false }
        return true
    }

    /// Key codes (kVK_*), layout independent.
    enum Key {
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let a: UInt16 = 0
        static let c: UInt16 = 8
        static let z: UInt16 = 6
    }

    /// What a key press means, independent of AppKit (tests drive this).
    enum Command: Equatable {
        case quickLook, close, previous(extend: Bool), next(extend: Bool), selectAll, remove, open, copy, undo
    }

    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, quickLookOpen: Bool) -> Command? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        switch keyCode {
        case Key.space where flags.isEmpty: return .quickLook
        case Key.escape: return .close
        case Key.left where !flags.contains(.command), Key.up where !flags.contains(.command):
            return .previous(extend: flags.contains(.shift))
        case Key.right where !flags.contains(.command), Key.down where !flags.contains(.command):
            return .next(extend: flags.contains(.shift))
        case Key.a where flags == .command: return .selectAll
        case Key.c where flags == .command: return .copy
        case Key.z where flags == .command: return .undo
        case Key.delete where flags.isEmpty || flags == .command, Key.forwardDelete where flags.isEmpty:
            return .remove
        case Key.returnKey where flags.isEmpty, Key.enter where flags.isEmpty:
            return quickLookOpen ? .close : .open
        default: return nil
        }
    }

    /// Quick Look on the keyboard targets: a multi-selection previews just
    /// those (as Finder does), otherwise every item, opened on the focused one.
    static func showQuickLook(_ tray: TrayStore, startingAt item: TrayItem? = nil, fromKeyboard: Bool = false) {
        let targets = item.map { [$0] } ?? tray.keyboardTargets
        let pool = targets.count > 1 ? targets : tray.items
        let entries = tray.quickLookEntries(for: pool)
        guard !entries.isEmpty else { return }
        let start = entries.firstIndex { $0.id == targets.first?.id } ?? 0
        let quickLook = TrayQuickLook.shared
        quickLook.onIndexChange = { [weak tray] index in
            guard let tray, quickLook.itemIDs.indices.contains(index) else { return }
            tray.focus(id: quickLook.itemIDs[index])
        }
        quickLook.show(urls: entries.map(\.url), itemIDs: entries.map(\.id), start: start, fromKeyboard: fromKeyboard)
    }

    /// Returns true when the key was used.
    @discardableResult
    func handle(_ press: TrayKeyPress) -> Bool {
        guard owns(windowNumber: press.windowNumber), let tray,
              let command = Self.command(keyCode: press.keyCode, modifiers: press.modifiers,
                                         quickLookOpen: TrayQuickLook.shared.isVisible) else { return false }
        return perform(command, on: tray)
    }

    @discardableResult
    func perform(_ command: Command, on tray: TrayStore) -> Bool {
        let quickLook = TrayQuickLook.shared
        switch command {
        case .quickLook:
            if quickLook.isVisible {
                quickLook.close()
            } else {
                guard !tray.keyboardTargets.isEmpty else { return false }
                TrayKeyboard.showQuickLook(tray, fromKeyboard: true)
            }
        case .close:
            if quickLook.isVisible {
                quickLook.close()
            } else if !tray.selection.isEmpty {
                tray.clearSelection()
            } else {
                return false
            }
        case .previous(let extend), .next(let extend):
            let forward = if case .next = command { true } else { false }
            tray.keyboardChange()
            tray.moveFocus(forward: forward, extending: extend)
            if quickLook.isVisible, let id = tray.focusedID, let index = quickLook.itemIDs.firstIndex(of: id) {
                quickLook.select(index: index)
            }
        case .selectAll:
            tray.keyboardChange()
            tray.selectAll()
        case .remove:
            let targets = tray.keyboardTargets
            guard !targets.isEmpty else { return false }
            tray.keyboardChange()
            quickLook.close()
            tray.remove(ids: targets.map(\.id))
        case .open:
            let targets = tray.keyboardTargets.filter { $0.kind != .text }
            guard !targets.isEmpty else { return false }
            targets.compactMap(\.url).forEach { NSWorkspace.shared.open($0) }
        case .copy:
            let targets = tray.keyboardTargets
            guard !targets.isEmpty else { return false }
            tray.copyToClipboard(targets)
        case .undo:
            guard tray.undo != nil else { return false }
            tray.keyboardChange()
            tray.undoLast()
        }
        return true
    }
}

/// Invisible first responder for the Tray: the keyboard target while the
/// Tray has focus, and the Quick Look panel's controller (the panel looks
/// for one up the key window's responder chain).
final class TrayKeyResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }


    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Quick Look calls this on the main thread.
        MainActor.assumeIsolated {
            panel?.dataSource = TrayQuickLook.shared
            panel?.delegate = TrayQuickLook.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // The data source stays set: the panel may look for a new controller
        // when the user clicks into it, and should keep showing the items.
    }
}

/// The tiny invisible panel that takes key status for the Tray: borderless,
/// non-activating, clear, never under the mouse, on every Space. Ordering
/// it out returns the keyboard without moving the notch panel.
final class TrayKeyPanel: NSPanel {
    static let size = CGSize(width: 2, height: 2)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        alphaValue = 0
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        title = "SparkV Tray Keys"
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Marks where the Tray lives (zero size, behind the Tray): tells the
/// keyboard which notch panel to sit in.
final class TrayKeyAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { TrayKeyboard.shared.registerAnchor(window) }
    }
}

/// SwiftUI host for the anchor.
struct TrayKeyResponder: NSViewRepresentable {
    func makeNSView(context: Context) -> TrayKeyAnchorView { TrayKeyAnchorView() }
    func updateNSView(_ view: TrayKeyAnchorView, context: Context) {}
}

/// The parts of a key event the Tray looks at (NSEvent isn't Sendable).
struct TrayKeyPress: Sendable {
    let windowNumber: Int
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}
