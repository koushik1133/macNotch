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
