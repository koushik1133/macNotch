import AppKit
import Combine
import GlanceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var terminationSource: DispatchSourceSignal?
    private var faceUnlockGate: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: Info.plist already sets LSUIElement, this keeps the
        // app out of the Dock even when launched as a bare executable.
        NSApp.setActivationPolicy(.accessory)

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
        Task { @MainActor in
            await controller.finishWorkBeforeQuit(timeout: .seconds(5))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        notchController?.tearDown()
        SpaceStore.shared.flush()
    }
}
