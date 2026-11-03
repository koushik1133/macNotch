import AppKit
import SwiftUI

/// The onboarding window: a fixed-size dark window with a transparent title
/// bar (like CleanShot X and Raycast's setup windows). It opens on the
/// island's screen (wherever Island Placement put it, `LookIsland`),
/// centered below the space the open drawer takes, so Try It can open the
/// drawer without the window covering it.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private weak var controller: OnboardingController?

    func show(controller: OnboardingController) {
        self.controller = controller
        let window = window ?? makeWindow(controller: controller)
        self.window = window
        // SparkV is an agent app (no Dock icon); become a regular app while
        // the window is open so it can take focus and show in ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { place(window) }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow(controller: OnboardingController) -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingRootView(controller: controller).followsAppearance())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to SparkV"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.isReleasedWhenClosed = false
        window.setContentSize(OnboardingStyle.windowSize)
        place(window)
        window.delegate = self
        return window
    }

    /// Room left above the window for the open drawer (the tallest common
    /// drawer is about 160 pt; text size can make it taller).
    static let drawerClearance: CGFloat = 190

    /// On the island's screen, centered, its top `drawerClearance` below the
    /// menu bar; on a short screen it slides up as little as possible.
    private func place(_ window: NSWindow) {
        guard let screen = LookIsland.screen else {
            window.center()
            return
        }
        window.setFrame(Self.frame(for: window.frame.size, in: screen.visibleFrame), display: false)
    }

    /// The window frame for `size` in `visible` (a screen's visible frame).
    static func frame(for size: CGSize, in visible: CGRect) -> CGRect {
        let x = visible.midX - size.width / 2
        let preferredTop = visible.maxY - drawerClearance
        let top = max(min(preferredTop, visible.maxY), visible.minY + size.height)
        return CGRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.windowDidClose()
        OnboardingDragHelper.shared.close()
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Gear-menu entries; drop `OnboardingMenuItems()` into `SettingsMenu`.
struct OnboardingMenuItems: View {
    var body: some View {
        Button("Welcome Tour…") { OnboardingController.shared.show(step: .welcome) }
        Button("Permissions & Setup…") { OnboardingController.shared.show(step: .permissions) }
        Button("Terms & Privacy…") { OnboardingController.shared.show(step: .terms) }
    }
}

// MARK: - Settings section

/// Settings › General: the way back into the tour and the terms. Launch at
/// Login and the menu bar icon are AppShell's own sections in the same pane
/// (`AppShellLoginItem`, `StatusItemController`), which the tour's Finish
/// step also uses; Permissions & Setup is in Settings › System.
struct OnboardingSettingsSection: View {
    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Terms & Privacy…") { OnboardingController.shared.show(step: .terms) }
                    Button("Welcome Tour…") { OnboardingController.shared.show(step: .welcome) }
                }
            } label: {
                Text("Welcome Tour")
                Text("Try the notch again, review the terms, pick a look and text size.")
            }
        } header: {
            Text("Tour")
        }
    }
}
