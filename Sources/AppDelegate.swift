import AppKit
import Combine
import GlanceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var terminationSource: DispatchSourceSignal?
    private var faceUnlockGate: AnyCancellable?

    /// The main menu exists before any window can open, so ⌘, ⌘W and
    /// copy/paste work in every SparkV window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppShellMenus.installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything logs: keep ~/Library/Logs/SparkV.log under 5 MB.
        AppShellLogMaintenance.rotateIfNeeded()
        // Starts the Low Power / thermal / display-sleep / memory-pressure
        // listeners every feature paces itself by (event-driven, no polling).
        _ = SparkVEnergy.shared

        // Belt and braces: Info.plist already sets LSUIElement, this keeps the
        // app out of the Dock even when launched as a bare executable.
        NSApp.setActivationPolicy(.accessory)
        // While a SparkV window is open SparkV shows in the Dock and ⌘-Tab;
        // without a bundle icon that would be the generic executable icon.
        SparkVAppInfo.installDockIconIfNeeded()

        // `kill`, logout and launchd send SIGTERM, which would otherwise skip
        // applicationWillTerminate and orphan the Now Playing adapter.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source

        // Before any feature starts: the one place that checks and asks for
        // permissions begins following Accessibility / activation changes
        // now, and its launch quiet period keeps features from prompting.
        _ = PermissionCenter.shared

        let controller = NotchWindowController()
        controller.showWindow(nil)
        notchController = controller

        // First launch / new terms version / an Accessibility grant that
        // belonged to an earlier build: Welcome → Terms → Permissions.
        OnboardingController.shared.showIfNeeded()

        // Face unlock (glance): watches for lock/wake and, on first run, walks
        // through enrollment in the notch.
        startFaceUnlock()

        // Settings window, menu bar icon, updates, crash reports and
        // sparkv:// links (links that arrived during launch run now).
        AppShellController.shared.start()
    }

    /// Opening SparkV again (Finder, Spotlight, Launchpad, the Dock icon
    /// while a window is open). The island's panel always counts as a
    /// visible window, so the flag is ignored and SparkV always answers:
    /// Settings by default, or the drawer (General › Menu Bar).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppShellController.shared.handleReopen()
        return false
    }

    /// sparkv:// links from Shortcuts, Terminal (`open -g`), Reminders and
    /// other apps. See Sources/Labs/AppShell/AUTOMATION.md.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppShellController.shared.handle(urls: urls)
    }

    /// First-run enrollment asks for the camera. While onboarding is open it
    /// has its own prompts, so enrollment waits until that window closes
    /// (one system prompt at a time). Once set up, it starts right away.
    private func startFaceUnlock() {
        let onboarding = OnboardingController.shared
        guard onboarding.isVisible, !FaceUnlock.isSetUp else {
            FaceUnlock.start()
            return
        }
        AppLog.log("Face unlock: enrollment waits for onboarding to close")
        faceUnlockGate = onboarding.$isVisible
            .first { !$0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.faceUnlockGate = nil
                    FaceUnlock.start()
                }
            }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A screen recording still running is finished (the movie written and
    /// moved to the Desktop) before SparkV quits, for up to 5 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = notchController, controller.hasWorkToFinishBeforeQuit else { return .terminateNow }
        // Off the main thread: a stuck main actor can never block Quit.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
            AppLog.log("Quit: work before quit took over 8 s; exiting")
            exit(0)
        }
        Task { @MainActor in
            await controller.finishWorkBeforeQuit(timeout: .seconds(5))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppShellController.shared.stop()
        notchController?.tearDown()
        SpaceStore.shared.flush()
    }
}
