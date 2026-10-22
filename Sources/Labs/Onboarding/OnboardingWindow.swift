import AppKit
import SwiftUI

/// The onboarding window: a fixed-size dark window, centered, with a
/// transparent title bar (like CleanShot X and Raycast's setup windows).
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
        if !window.isVisible { window.center() }
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
        window.center()
        window.delegate = self
        return window
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
        Button("Permissions & Setup…") { OnboardingController.shared.show(step: .permissions) }
        Button("Terms & Privacy…") { OnboardingController.shared.show(step: .terms) }
    }
}
