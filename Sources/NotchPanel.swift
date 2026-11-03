import AppKit
import SwiftUI

/// Borderless, non-activating panel that sits on top of the hardware notch.
///
/// It floats above the menu bar, full-screen Spaces and normal app windows,
/// never steals focus from the frontmost app, and lets clicks fall through
/// while the island is collapsed.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // isFloatingPanel resets `level` to .floating, so it must come first.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Agent apps are never active, and AppKit hides tooltips for inactive apps by default.
        allowsToolTipsWhenApplicationIsInactive = true

        // Resting state: completely click-through.
        ignoresMouseEvents = true
    }

    /// Mission Control and Exposé: `.transient` lets macOS hide the panel
    /// there (no second notch over the Spaces strip); `.stationary` keeps
    /// it on screen like the desktop. Both stay on every Space and over
    /// full-screen apps.
    func setHidesInMissionControl(_ hides: Bool) {
        let behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, hides ? .transient : .stationary, .ignoresCycle,
        ]
        if collectionBehavior != behavior { collectionBehavior = behavior }
    }

    /// Esc while the drawer has the keyboard (a search or note field):
    /// Island Interaction closes the drawer (Settings › Island › Esc
    /// closes the drawer). A field that uses Esc itself (clearing a
    /// completion) gets it first through the responder chain.
    static let escapeNotification = Notification.Name("SparkV.NotchPanel.escape")

    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.escapeNotification, object: self)
    }

    /// Keyboard navigation between the drawer's tabs (a key no field took):
    /// userInfo "move" (-1/+1) or "index" (0-based header position).
    static let navigateNotification = Notification.Name("SparkV.NotchPanel.navigate")

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Esc with no field focused reaches the window as a key down.
        if event.keyCode == 53, flags.isEmpty {
            cancelOperation(nil)
            return
        }
        if DrawerShortcutStore.shared.keyboardNavigation, let info = Self.navigation(for: event, flags: flags) {
            NotificationCenter.default.post(name: Self.navigateNotification, object: self, userInfo: info)
            return
        }
        super.keyDown(with: event)
    }

    /// ← → move between tabs; Tab / ⇧Tab too unless Full Keyboard Access
    /// is on (then Tab walks the controls); ⌃Tab / ⌃⇧Tab always; ⌘1–⌘9 jump.
    private static func navigation(for event: NSEvent, flags: NSEvent.ModifierFlags) -> [String: Int]? {
        switch event.keyCode {
        case 123 where flags.isEmpty: return ["move": -1]
        case 124 where flags.isEmpty: return ["move": 1]
        case 48 where flags == [.control]: return ["move": 1]
        case 48 where flags == [.control, .shift]: return ["move": -1]
        case 48 where !NSApp.isFullKeyboardAccessEnabled && (flags.isEmpty || flags == [.shift]):
            return ["move": flags.contains(.shift) ? -1 : 1]
        default:
            break
        }
        guard flags == [.command] else { return nil }
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        return digits[event.keyCode].map { ["index": $0] }
    }

    // Lets SwiftUI controls (menus, buttons) work without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit normally pushes windows below the menu bar / safe area.
    /// The island must sit at the absolute top edge of the screen, so the
    /// requested frame is returned untouched.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that reacts to the first click even though the panel is
/// never the key window of an active app.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
