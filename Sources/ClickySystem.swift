import AppKit
import Combine
import ScreenCaptureKit

// The real implementations behind ClickyController's seams. Everything that
// touches permissions goes through PermissionCenter.

extension ClickyController {
    /// The app's Clicky: dictation's command capture, ScreenCaptureKit via
    /// PermissionCenter, the login keychain, the pointer overlay and system
    /// speech.
    convenience init(dictation: DictationController) {
        self.init(
            speech: dictation,
            screen: ClickySystemScreen(),
            keyStore: ClickySystemKeyStore(),
            makeBackend: ClickyController.systemBackend,
            overlay: ClickyOverlay(),
            speaker: ClickySpeaker(),
            hotkey: ClickySystemHotkey(),
            haptic: ClickyController.systemHaptic,
            prewarm: VisionClient.prewarm
        )
    }

    static func systemBackend(_ choice: ClickyBackendChoice) -> any ClickyAnswering {
        switch choice {
        case .groq(let key, let model):
            ClickyGroqBackend(client: VisionClient(apiKey: key, model: model))
        case .onDevice:
            ClickyOnDeviceBackend()
        }
    }

    /// A light trackpad tick (only felt with a finger on a Force Touch trackpad).
    static func systemHaptic(_ haptic: ClickyHaptic) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = haptic == .listen ? .alignment : .levelChange
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

// MARK: - Speech

extension DictationController: ClickySpeechInput {
    var capturingChanges: AnyPublisher<Bool, Never> { $isCapturingCommand.eraseToAnyPublisher() }
    var liveTextChanges: AnyPublisher<String, Never> { $liveText.eraseToAnyPublisher() }

    var permissionProblem: String? { DictationPermissions.deniedMessage() }

    var isReadyWithoutPrompt: Bool {
        PermissionCenter.shared.isGranted(.microphone) && PermissionCenter.shared.isGranted(.speech)
    }

    var isDictating: Bool { isActive }

    var isShowingFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    func openPermissionSettings() {
        Task { try? await DictationPermissions.ensure(from: "Clicky") }
    }
}

// MARK: - Hotkey

/// ⌃⌥ hold monitor that follows Accessibility through PermissionCenter and
/// re-creates its monitors on a grant (ones added before it stay deaf).
@MainActor
final class ClickySystemHotkey: ClickyHotkeySource {
    var onEvent: (@MainActor (ClickyHotkeyEvent) -> Void)? {
        didSet { monitor.onEvent = onEvent }
    }
    var onTrustChange: (@MainActor (Bool) -> Void)?

    private let monitor = ClickyHotkeyMonitor()
    private var trustWatch: AnyCancellable?

    var isTrusted: Bool { PermissionCenter.shared.isGranted(.accessibility) }

    func start() {
        monitor.start()
        guard trustWatch == nil else { return }
        trustWatch = PermissionCenter.shared.onChange(of: .accessibility) { [weak self] status in
            guard let self else { return }
            if status.isGranted { self.monitor.restart() }
            self.onTrustChange?(status.isGranted)
        }
    }

    func stop() {
        trustWatch = nil
        monitor.stop()
    }

    func reset() {
        monitor.reset()
    }
}

// MARK: - Keychain

@MainActor
final class ClickySystemKeyStore: ClickyKeyStore {
    func hasKey() -> Bool { ClickyKeychain.hasKey() }
    /// Off the main thread: after a rebuild macOS may ask whether SparkV may
    /// use the item, and the read waits for that answer.
    func load() async -> String? {
        await Task.detached(priority: .userInitiated) { ClickyKeychain.load() }.value
    }
    func save(_ key: String) -> Bool { ClickyKeychain.save(key) }
    func delete() { ClickyKeychain.delete() }
}

// MARK: - Overlay

extension ClickyOverlay: ClickyPointerPresenting {}

// MARK: - Screen

@MainActor
final class ClickySystemScreen: ClickyScreenSource {
    var onAccessChange: (@MainActor (Bool) -> Void)?
    private var watch: AnyCancellable?

    init() {
        // Re-read when any app activates (coming back from Settings); no poll.
        watch = PermissionCenter.shared.onChange(of: .screenRecording, poll: false) { [weak self] status in
            self?.onAccessChange?(status.isGranted)
        }
    }

    var hasScreenAccess: Bool { PermissionCenter.shared.isGranted(.screenRecording) }
    var needsRelaunch: Bool { PermissionCenter.shared.screenRecordingNeedsRelaunch }

    func requestScreenAccess() {
        Task { _ = await PermissionCenter.shared.request(.screenRecording, from: "Clicky") }
    }

    func capture() async throws -> ClickyCapture {
        try await ClickyScreenCapture.captureUnderMouse()
    }
}

enum ClickyScreenCapture {
    static let maxLongEdge: CGFloat = 1568

    /// Captures the display under the mouse, without SparkV's own windows,
    /// downscaled to `maxLongEdge` (Retina pixels in, at most 1568 px out).
    @MainActor
    static func captureUnderMouse() async throws -> ClickyCapture {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw ClickyCaptureFailure.noDisplay }

        let permissions = PermissionCenter.shared
        guard permissions.isGranted(.screenRecording) else { throw ClickyCaptureFailure.permissionDenied }

        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        var content = try await shareableContent(permissions)
        var display = content.displays.first(where: { $0.displayID == displayID })
        if display == nil {
            // A display connected after the cached list was read.
            permissions.invalidateShareableContent()
            content = try await shareableContent(permissions)
            display = content.displays.first(where: { $0.displayID == displayID })
        }
        guard let display else { throw ClickyCaptureFailure.noDisplay }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let nativePixels = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
        let target = ClickyGeometry.fittedPixelSize(nativePixels, maxLongEdge: maxLongEdge)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.width)
        configuration.height = Int(target.height)
        configuration.showsCursor = false
        configuration.scalesToFit = true

        var image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            if PermissionCenter.isCaptureDenial(error) { throw ClickyCaptureFailure.permissionDenied }
            throw error
        }
        if CGFloat(max(image.width, image.height)) > maxLongEdge {
            image = ClickyImage.downscale(image, to: ClickyGeometry.fittedPixelSize(
                CGSize(width: image.width, height: image.height), maxLongEdge: maxLongEdge
            )) ?? image
        }
        guard let jpeg = ClickyImage.sendableJPEG(image) else { throw ClickyCaptureFailure.encodingFailed }

        let imageSize = CGSize(width: image.width, height: image.height)
        let cursor = ClickyGeometry.pixel(fromScreenPoint: mouse, imageSize: imageSize, screenFrame: screenFrame)
        AppLog.log("Clicky: captured display \(displayID) \(image.width)x\(image.height) (\(jpeg.count / 1024) KB)")
        return ClickyCapture(image: image, jpeg: jpeg, imageSize: imageSize, screenFrame: screenFrame, cursorPixel: cursor)
    }

    @MainActor
    private static func shareableContent(_ permissions: PermissionCenter) async throws -> SCShareableContent {
        do {
            // Cached and preflight-gated: fewer macOS 15 capture reminders.
            return try await permissions.shareableContent(from: "Clicky")
        } catch {
            AppLog.log("Clicky: shareable content failed: \(error)")
            throw ClickyCaptureFailure.permissionDenied
        }
    }
}
