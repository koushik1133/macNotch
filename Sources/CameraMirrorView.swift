import AppKit
import AVFoundation
import SwiftUI

// MARK: - SwiftUI bridge

/// Live camera preview sized to fill its frame (circle in the drawer, a
/// rounded card in the pop-out). Mirrored like a real mirror unless the
/// user picked the natural (as others see you) view.
struct CameraMirrorView: NSViewRepresentable {
    let session: AVCaptureSession
    /// nil: follow the saved choice (Settings › Media › Mirror).
    var mirrored: Bool? = nil

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session, mirrored: mirrored ?? CameraMirrorSettings.shared.isMirrored)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.mirrored = mirrored ?? CameraMirrorSettings.shared.isMirrored
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    var mirrored: Bool {
        didSet { if mirrored != oldValue { applyMirroring() } }
    }

    init(session: AVCaptureSession, mirrored: Bool = true) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.mirrored = mirrored
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        // Fill the frame edge to edge without stretching the feed.
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        applyMirroring()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        applyMirroring()
    }

    /// Mirrored: moving your right hand moves it on the right, like a mirror.
    /// Natural: the picture the other side of a call sees.
    func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        if connection.automaticallyAdjustsVideoMirroring {
            connection.automaticallyAdjustsVideoMirroring = false
        }
        if connection.isVideoMirrored != mirrored {
            connection.isVideoMirrored = mirrored
        }
    }

    // Let clicks reach the SwiftUI button that wraps the preview.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Settings

/// Saved mirror choices (UserDefaults "Mirror.*").
@MainActor
final class CameraMirrorSettings: ObservableObject {
    static let shared = CameraMirrorSettings()

    /// The chosen camera's uniqueID; nil: the built-in camera.
    @Published var cameraID: String? { didSet { defaults.set(cameraID, forKey: "Mirror.cameraID") } }
    @Published var isMirrored: Bool { didSet { defaults.set(isMirrored, forKey: "Mirror.mirrored") } }
    /// Pop the large mirror out when a call app turns the camera on.
    @Published var popsOutWhenCameraStarts: Bool { didSet { defaults.set(popsOutWhenCameraStarts, forKey: "Mirror.autoPopOut") } }
    /// Seconds the automatic pop-out stays (unless hovered).
    @Published var autoPopOutSeconds: Int { didSet { defaults.set(autoPopOutSeconds, forKey: "Mirror.autoPopOutSeconds") } }
    @Published var popOutSize: PopOutSize { didSet { defaults.set(popOutSize.rawValue, forKey: "Mirror.popOutSize") } }

    enum PopOutSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var size: CGSize {
            switch self {
            case .small: CGSize(width: 240, height: 150)
            case .medium: CGSize(width: 320, height: 200)
            case .large: CGSize(width: 440, height: 270)
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cameraID = defaults.string(forKey: "Mirror.cameraID")
        isMirrored = defaults.object(forKey: "Mirror.mirrored") == nil ? true : defaults.bool(forKey: "Mirror.mirrored")
        popsOutWhenCameraStarts = defaults.bool(forKey: "Mirror.autoPopOut")
        let seconds = defaults.integer(forKey: "Mirror.autoPopOutSeconds")
        autoPopOutSeconds = seconds == 0 ? 15 : min(max(seconds, 5), 60)
        popOutSize = PopOutSize(rawValue: defaults.string(forKey: "Mirror.popOutSize") ?? "") ?? .medium
    }
}

/// A camera the mirror can use.
struct CameraChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: Kind

    enum Kind: Sendable, Equatable {
        case builtIn, external, continuity

        var symbol: String {
            switch self {
            case .builtIn: "laptopcomputer"
            case .external: "web.camera"
            case .continuity: "iphone"
            }
        }
    }

    /// Built-in first, then by name.
    static func ordered(_ choices: [CameraChoice]) -> [CameraChoice] {
        choices.sorted { a, b in
            if (a.kind == .builtIn) != (b.kind == .builtIn) { return a.kind == .builtIn }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - UI-facing controller

@MainActor
final class CameraController: ObservableObject {
    /// The app's mirror controller (hub tile, menus, pop-out).
    static weak var current: CameraController?

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isDenied = false
    @Published private(set) var errorMessage: String?
    /// The system camera prompt is on screen. The drawer stays open meanwhile,
    /// since moving to the prompt takes the pointer out of the hot zone.
    @Published private(set) var isAwaitingPermission = false
    /// Cameras attached right now (built-in, external, Continuity).
    @Published private(set) var cameras: [CameraChoice] = []
    /// The camera the session uses (resolved: the saved one, else built-in).
    @Published private(set) var activeCameraID: String?
    /// The large floating mirror is open (it keeps the camera on after the
    /// drawer closes, until you close it).
    @Published private(set) var isPoppedOut = false
    /// Center Stage is available on the active camera.
    @Published private(set) var supportsCenterStage = false
    @Published private(set) var isCenterStageOn = AVCaptureDevice.isCenterStageEnabled

    private let engine = CaptureEngine()
    /// Bumped by every start and stop. A permission answer or session start
    /// that arrives after a newer request is ignored, so a drawer that closed
    /// mid-start can never leave the camera running.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var inUseObservations: [NSKeyValueObservation] = []
    private var autoCloseTask: Task<Void, Never>?
    private let settings = CameraMirrorSettings.shared

    var session: AVCaptureSession { engine.session }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: engine.session,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated { self?.sessionFailed(message) }
        })
        // Posted when another app takes the camera or the lid closes.
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: engine.session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionFailed("The camera is in use by another app or unavailable.") }
        })
        // Webcams and iPhones come and go.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.object as? AVCaptureDevice)?.uniqueID
                let connected = name == AVCaptureDevice.wasConnectedNotification
                MainActor.assumeIsolated { self?.devicesChanged(connectedID: connected ? id : nil, disconnectedID: connected ? nil : id) }
            })
        }
        Self.current = self
        refreshCameras()
        updateAutoPopOutWatch()
    }

    func toggle() {
        (isRunning || isStarting) ? stop() : start()
    }

    func start() {
        generation += 1
        let request = generation
        errorMessage = nil

        let permissions = PermissionCenter.shared
        switch permissions.isGranted(.camera) ? .granted : permissions.status(.camera) {
        case .granted:
            activate(request)
        case .notDetermined:
            isStarting = true
            isAwaitingPermission = true
            // Queued behind any other system prompt; shown once.
            Task { [weak self] in
                let status = await permissions.request(.camera, from: "Camera mirror")
                guard let self else { return }
                self.isAwaitingPermission = false
                guard status.isGranted else {
                    // Recording a denial never starts the camera, so it
                    // applies even if a stop superseded this request.
                    if self.generation == request { self.isStarting = false }
                    // Still undetermined: the prompt was deferred, not refused.
                    if status != .notDetermined {
                        self.markDenied(message: Self.deniedMessage, openSettings: false)
                    }
                    return
                }
                guard self.generation == request else { return }
                self.refreshCameras()
                self.activate(request)
            }
        case .denied:
            // The user tapped the slashed camera after an earlier denial:
            // take them to the switch that fixes it.
            markDenied(message: Self.deniedMessage, openSettings: true)
        case .restricted:
            markDenied(message: "Camera access is restricted on this Mac.", openSettings: false)
        default:
            markDenied(message: Self.deniedMessage, openSettings: false)
        }
    }

    /// Stops the camera everywhere (the drawer circle and the pop-out).
    /// Safe to call at any time, including while a start is still pending:
    /// the stop is queued behind it on the capture queue.
    func stop() {
        generation += 1
        isStarting = false
        isRunning = false
        autoCloseTask?.cancel()
        autoCloseTask = nil
        if isPoppedOut {
            isPoppedOut = false
            CameraMirrorPopOutController.shared.close()
        }
        engine.stop()
    }

    /// The Home tab's mirror circle is on screen (it shows the camera
    /// whenever it runs), so closing the large mirror keeps the camera on.
    private(set) var drawerPreviewVisible = false

    /// The Home tab's mirror circle appeared.
    func drawerPreviewAppeared() {
        drawerPreviewVisible = true
    }

    /// The drawer closed or left the Home tab: stop, unless the pop-out
    /// still shows the camera.
    func releaseDrawerPreview() {
        drawerPreviewVisible = false
        guard !isPoppedOut else { return }
        stop()
    }

    private static let deniedMessage =
        "Camera access is off. Enable SparkV in System Settings › Privacy & Security › Camera."

    private func activate(_ request: Int) {
        isStarting = true
        isDenied = false
        let preferred = settings.cameraID
        let preset: AVCaptureSession.Preset = isPoppedOut ? .high : .medium
        engine.start(preferredID: preferred, preset: preset) { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == request else { return }
                self.isStarting = false
                switch result {
                case .success(let info):
                    self.isRunning = true
                    self.activeCameraID = info.cameraID
                    self.supportsCenterStage = info.supportsCenterStage
                    self.isCenterStageOn = AVCaptureDevice.isCenterStageEnabled
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func sessionFailed(_ message: String?) {
        guard isRunning || isStarting else { return }
        generation += 1
        isStarting = false
        isRunning = false
        errorMessage = message ?? "The camera stopped unexpectedly."
        engine.reset()
    }

    private func markDenied(message: String, openSettings: Bool) {
        isDenied = true
        isRunning = false
        errorMessage = message
        if openSettings {
            PermissionCenter.shared.openSettings(.camera, from: "Camera mirror")
        }
    }

    // MARK: Cameras

    func refreshCameras() {
        // Names and IDs only: listing devices needs no camera access.
        cameras = CameraChoice.ordered(CaptureEngine.discover().map(CameraChoice.init(device:)))
        updateAutoPopOutWatch()
    }

    /// Switches the mirror to another camera (on the capture queue, while running).
    func selectCamera(_ id: String?) {
        settings.cameraID = id
        guard isRunning || isStarting else { return }
        let request = generation
        engine.switchCamera(to: id) { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == request else { return }
                switch result {
                case .success(let info):
                    self.activeCameraID = info.cameraID
                    self.supportsCenterStage = info.supportsCenterStage
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func devicesChanged(connectedID: String?, disconnectedID: String?) {
        refreshCameras()
        // The saved camera came back: use it again.
        if let connectedID, connectedID == settings.cameraID, activeCameraID != connectedID, isRunning {
            selectCamera(connectedID)
        }
        // The active camera left: fall back to the built-in one.
        if let disconnectedID, disconnectedID == activeCameraID, isRunning {
            engine.switchCamera(to: nil) { [weak self] result in
                Task { @MainActor in
                    if case .success(let info) = result { self?.activeCameraID = info.cameraID }
                }
            }
        }
    }

    var activeCameraName: String {
        cameras.first { $0.id == activeCameraID }?.name ?? cameras.first?.name ?? "Camera"
    }

    // MARK: Center Stage and effects

    /// Center Stage keeps you framed (supported cameras; the app controls it).
    func setCenterStage(_ on: Bool) {
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = on
        isCenterStageOn = AVCaptureDevice.isCenterStageEnabled
    }

    /// macOS's own Video Effects panel (Portrait, Studio Light, backgrounds).
    func showVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    // MARK: Pop-out

    /// The large floating mirror under the notch. It stays after the drawer
    /// closes; close it with its × (or the menu).
    func popOut(autoClose: TimeInterval? = nil) {
        // Asked for by the user (not the automatic pop-out on a call): close
        // the drawer so the mirror is what you see.
        if autoClose == nil { ExtrasIslandCover.userWillShowPanel() }
        isPoppedOut = true
        engine.setPreset(.high)
        CameraMirrorPopOutController.shared.show(controller: self)
        if !(isRunning || isStarting) { start() }
        autoCloseTask?.cancel()
        autoCloseTask = nil
        if let autoClose {
            autoCloseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(autoClose))
                guard !Task.isCancelled, let self, self.isPoppedOut else { return }
                if CameraMirrorPopOutController.shared.isHovered {
                    // Hovered: wait until the pointer leaves.
                    self.autoCloseTask = nil
                    CameraMirrorPopOutController.shared.closeWhenUnhovered = true
                    return
                }
                self.closePopOut()
            }
        }
    }

    /// Back to the drawer circle (or off, when the drawer is closed).
    func closePopOut() {
        guard isPoppedOut else { return }
        isPoppedOut = false
        autoCloseTask?.cancel()
        autoCloseTask = nil
        CameraMirrorPopOutController.shared.close()
        engine.setPreset(.medium)
        // The Home circle still shows the camera: keep it on there.
        // Otherwise nothing shows the camera now.
        if !drawerPreviewVisible { stop() }
    }

    func togglePopOut() {
        isPoppedOut ? closePopOut() : popOut()
    }

    /// Cancels an automatic close (the user is looking).
    func keepPopOut() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
    }

    // MARK: Pop out when a call starts (opt-in)

    /// Watches `isInUseByAnotherApplication` (KVO, no polling) on every
    /// camera while the option is on; when a call app turns one on, the
    /// pop-out appears for a few seconds so you can check yourself.
    func updateAutoPopOutWatch() {
        inUseObservations.forEach { $0.invalidate() }
        inUseObservations.removeAll()
        guard settings.popsOutWhenCameraStarts else { return }
        for device in CaptureEngine.discover() {
            let observation = device.observe(\.isInUseByAnotherApplication, options: [.new]) { [weak self] device, _ in
                let inUse = device.isInUseByAnotherApplication
                Task { @MainActor in self?.otherAppCamera(inUse: inUse) }
            }
            inUseObservations.append(observation)
        }
    }

    private func otherAppCamera(inUse: Bool) {
        guard settings.popsOutWhenCameraStarts, inUse, !isPoppedOut, !isRunning, !isStarting,
              PermissionCenter.shared.isGranted(.camera) else { return }
        AppLog.log("Mirror: another app turned the camera on; popping the mirror out")
        popOut(autoClose: TimeInterval(settings.autoPopOutSeconds))
    }
}

extension CameraChoice {
    init(device: AVCaptureDevice) {
        let kind: Kind = switch device.deviceType {
        case .builtInWideAngleCamera: .builtIn
        case .continuityCamera: .continuity
        default: .external
        }
        self.init(id: device.uniqueID, name: device.localizedName, kind: kind)
    }
}

// MARK: - Capture backend

enum CameraError: LocalizedError {
    case noCamera
    case unavailable
    case cannotAddInput
    case notRunning
    case input(Error)

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera was found."
        case .unavailable: "The camera is unavailable. Is the lid closed?"
        case .cannotAddInput: "The camera could not be attached to the capture session."
        case .notRunning: "The camera did not start. Another app may be using it."
        case .input(let error): "Camera error: \(error.localizedDescription)"
        }
    }
}

/// Owns the AVCaptureSession. Every session call happens on one serial queue
/// that targets the global user-initiated queue, so the blocking
/// `startRunning()` never touches the main thread, and a stop queued after a
/// start always runs after it.
final class CaptureEngine: @unchecked Sendable {
    struct Info: Sendable {
        let cameraID: String
        let supportsCenterStage: Bool
    }

    let session = AVCaptureSession()

    private let queue = DispatchQueue(
        label: "SparkV.CaptureEngine",
        qos: .userInitiated,
        target: .global(qos: .userInitiated)
    )
    // Only touched on `queue`.
    private var device: AVCaptureDevice?
    private var preset: AVCaptureSession.Preset = .medium

    /// Built-in, external (USB, display) and Continuity cameras.
    static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    func start(preferredID: String?, preset: AVCaptureSession.Preset,
               completion: @escaping @Sendable (Result<Info, CameraError>) -> Void) {
        queue.async { [self] in
            do {
                self.preset = preset
                // A disconnected AVCaptureDevice instance never reconnects; a
                // returning camera appears as a new instance, so rediscover it.
                if let cached = self.device, !cached.isConnected || (preferredID != nil && cached.uniqueID != preferredID) {
                    removeInputs()
                }
                let device = try self.device ?? configure(preferredID: preferredID)
                applyPreset()
                guard device.isConnected else { throw CameraError.unavailable }
                if !session.isRunning {
                    session.startRunning()
                }
                // startRunning() reports failure only through this flag and
                // the runtime-error notification.
                guard session.isRunning else { throw CameraError.notRunning }
                completion(.success(Info(cameraID: device.uniqueID, supportsCenterStage: device.activeFormat.isCenterStageSupported)))
            } catch let error as CameraError {
                completion(.failure(error))
            } catch {
                completion(.failure(.input(error)))
            }
        }
    }

    /// Swaps the input while the session keeps running.
    func switchCamera(to id: String?, completion: @escaping @Sendable (Result<Info, CameraError>) -> Void) {
        queue.async { [self] in
            do {
                removeInputs()
                let device = try configure(preferredID: id)
                applyPreset()
                completion(.success(Info(cameraID: device.uniqueID, supportsCenterStage: device.activeFormat.isCenterStageSupported)))
            } catch let error as CameraError {
                completion(.failure(error))
            } catch {
                completion(.failure(.input(error)))
            }
        }
    }

    /// .medium for the small circle (a Continuity camera at .high drains its
    /// battery), .high for the pop-out.
    func setPreset(_ preset: AVCaptureSession.Preset) {
        queue.async { [self] in
            self.preset = preset
            applyPreset()
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// Tears the session down so the next start re-discovers the camera.
    func reset() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
            removeInputs()
        }
    }

    /// Must run on `queue`.
    private func applyPreset() {
        guard session.sessionPreset != preset, session.canSetSessionPreset(preset) else { return }
        session.beginConfiguration()
        session.sessionPreset = preset
        session.commitConfiguration()
    }

    /// Must run on `queue`.
    private func removeInputs() {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        device = nil
    }

    /// Must run on `queue`. The preferred camera when attached, else the
    /// front built-in camera, else any.
    private func configure(preferredID: String?) throws -> AVCaptureDevice {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }

        let devices = Self.discover()
        let builtIn = devices.filter { $0.deviceType == .builtInWideAngleCamera }
        guard let device = devices.first(where: { $0.uniqueID == preferredID && $0.isConnected })
            ?? builtIn.first(where: { $0.position == .front })
            ?? builtIn.first
            ?? devices.first
        else {
            throw CameraError.noCamera
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.input(error)
        }
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        self.device = device
        return device
    }
}

// MARK: - Pop-out panel

/// The large mirror: a rounded card hanging just under the notch, above
/// other windows and full-screen apps, kept out of screen sharing
/// (best effort: some capture tools ignore `sharingType`).
@MainActor
final class CameraMirrorPopOutController {
    static let shared = CameraMirrorPopOutController()

    private var panel: NSPanel?
    let hover = ViewFlag()
    var isHovered: Bool { hover.isOn }
    /// Set when an automatic close waited for the pointer to leave.
    var closeWhenUnhovered = false

    func show(controller: CameraController) {
        let size = CameraMirrorSettings.shared.popOutSize.size
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // isFloatingPanel resets the level, so it comes first. One level
            // below the island, so the open drawer and bands draw on top.
            panel.isFloatingPanel = true
            panel.level = ExtrasIslandCover.panelLevel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.sharingType = .none
            panel.setAccessibilityLabel("SparkV mirror")
            let host = ExtrasPanelHostingView(rootView: AnyView(CameraMirrorPopOutView(controller: controller, hover: hover).followsAppearance()))
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
        }
        guard let panel else { return }
        panel.setContentSize(size)
        place(panel, size: size)
        reveal(panel)
    }

    /// Fades the panel in where it is (unless the open drawer covers it:
    /// then it appears when the drawer closes).
    private func reveal(_ panel: NSPanel) {
        guard !ExtrasIslandCover.islandExpanded else { return }
        let wasVisible = panel.isVisible && panel.alphaValue > 0.01
        if !wasVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SparkVMotion.reduceMotion ? 0.12 : SparkVMotion.Duration.standard
                context.timingFunction = .sparkVEaseOut
                panel.animator().alphaValue = 1
            }
        }
    }

    /// The drawer opened over the mirror (it steps aside) or closed (it
    /// comes back, if it is still open).
    func islandCoverChanged(_ covered: Bool) {
        if covered {
            fadeOut()
        } else if let panel, CameraController.current?.isPoppedOut == true {
            // Where the user left it (it can be dragged).
            reveal(panel)
        }
    }

    func panelLevelChanged(_ level: NSWindow.Level) {
        guard let panel, panel.level != level else { return }
        panel.level = level
    }

    func close() {
        closeWhenUnhovered = false
        fadeOut()
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = SparkVMotion.Duration.small
            context.timingFunction = .sparkVEaseOut
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                guard panel.alphaValue < 0.01 else { return }
                panel.orderOut(nil)
            }
        })
    }

    func hoverChanged(_ hovering: Bool) {
        hover.isOn = hovering
        if !hovering, closeWhenUnhovered {
            closeWhenUnhovered = false
            CameraController.current?.closePopOut()
        }
    }

    /// Centered under the notch (or the menu bar of the main display).
    private func place(_ panel: NSPanel, size: CGSize) {
        guard let screen = ExtrasScreens.notchedOrMain else { return }
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 8
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: top - size.height))
    }
}

struct CameraMirrorPopOutView: View {
    @ObservedObject var controller: CameraController
    @ObservedObject var hover: ViewFlag
    @ObservedObject private var settings = CameraMirrorSettings.shared
    @ObservedObject private var assistive = SparkVAssistive.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            shape.fill(Color.black)
            if controller.isRunning {
                CameraMirrorView(session: controller.session, mirrored: settings.isMirrored)
                    .clipShape(shape)
                    .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    if controller.isStarting {
                        ProgressView().controlSize(.small).tint(SparkVTheme.progressTint)
                    } else {
                        Image(systemName: controller.isDenied ? "video.slash.fill" : "video.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                    Text(controller.errorMessage ?? (controller.isStarting ? "Starting the camera…" : "Camera off"))
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            // Shown under the pointer, or always for VoiceOver and Full
            // Keyboard Access (the pop-out's × and options need no hover).
            controls
                .sparkVHoverRevealed(hover.isOn, assistive: assistive)
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(shape)
        .contentShape(shape)
        .onHover { hovering in
            CameraMirrorPopOutController.shared.hoverChanged(hovering)
            if hovering { controller.keepPopOut() }
        }
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.standard), value: controller.isRunning)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera mirror")
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 6) {
                Menu {
                    CameraMirrorCameraPicker(controller: controller)
                } label: {
                    Label(controller.activeCameraName, systemImage: "camera.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .accessibilityLabel("Camera: \(controller.activeCameraName)")
                Spacer()
                CameraMirrorChip(systemImage: "xmark", label: "Close the mirror") { controller.closePopOut() }
            }
            Spacer()
            HStack(spacing: 6) {
                CameraMirrorChip(systemImage: settings.isMirrored ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill" : "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                 label: settings.isMirrored ? "Mirrored: tap for natural view" : "Natural view: tap to mirror",
                                 text: settings.isMirrored ? "Mirrored" : "Natural") {
                    settings.isMirrored.toggle()
                }
                if controller.supportsCenterStage {
                    CameraMirrorChip(systemImage: "person.crop.rectangle", label: "Center Stage",
                                     text: "Center", isOn: controller.isCenterStageOn) {
                        controller.setCenterStage(!controller.isCenterStageOn)
                    }
                }
                Spacer()
                CameraMirrorChip(systemImage: "wand.and.stars", label: "Video Effects") { controller.showVideoEffects() }
            }
        }
        .padding(8)
    }
}

/// A dark translucent chip over the video.
struct CameraMirrorChip: View {
    let systemImage: String
    let label: String
    var text: String? = nil
    var isOn = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                if let text { Text(text).font(.system(size: 10.5, weight: .medium)) }
            }
            .foregroundStyle(isOn ? Color.black : Color.white)
            .padding(.horizontal, text == nil ? 0 : 8)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(isOn ? Color.white : Color.black.opacity(hover.isOn ? 0.75 : 0.55)))
            .contentShape(Capsule())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "")
    }
}

// MARK: - Menus, hub tile, settings

/// Camera choices, for a Menu.
struct CameraMirrorCameraPicker: View {
    @ObservedObject var controller: CameraController
    @ObservedObject private var settings = CameraMirrorSettings.shared

    var body: some View {
        ForEach(controller.cameras) { camera in
            Button {
                controller.selectCamera(camera.kind == .builtIn ? nil : camera.id)
            } label: {
                let chosen = (settings.cameraID ?? controller.cameras.first { $0.kind == .builtIn }?.id) == camera.id
                if chosen { Label(camera.name, systemImage: "checkmark") } else { Label(camera.name, systemImage: camera.kind.symbol) }
            }
        }
        if controller.cameras.isEmpty {
            Text("No cameras found")
        }
        Divider()
        Button("Refresh Cameras") { controller.refreshCameras() }
    }
}

/// Gear menu (`Menu("Mirror") { CameraMirrorMenuItems() }`) and the drawer
/// circle's right-click menu.
struct CameraMirrorMenuItems: View {
    @ObservedObject private var settings = CameraMirrorSettings.shared

    var body: some View {
        if let controller = CameraController.current {
            CameraMirrorMenuContent(controller: controller, settings: settings)
        }
    }
}

private struct CameraMirrorMenuContent: View {
    @ObservedObject var controller: CameraController
    @ObservedObject var settings: CameraMirrorSettings

    var body: some View {
        Button(controller.isPoppedOut ? "Close Large Mirror" : "Open Large Mirror") { controller.togglePopOut() }
        Menu("Camera") { CameraMirrorCameraPicker(controller: controller) }
        Toggle("Mirror Image", isOn: $settings.isMirrored)
        if controller.supportsCenterStage {
            Toggle("Center Stage", isOn: Binding(get: { controller.isCenterStageOn }, set: { controller.setCenterStage($0) }))
        }
        Button("Video Effects…") { controller.showVideoEffects() }
        Divider()
        Toggle("Pop Out When a Call Turns the Camera On", isOn: Binding(
            get: { settings.popsOutWhenCameraStarts },
            set: { settings.popsOutWhenCameraStarts = $0; controller.updateAutoPopOutWatch() }
        ))
    }
}

/// Media category: opens (or closes) the large mirror.
struct CameraMirrorHubTile: View {
    @ObservedObject private var settings = CameraMirrorSettings.shared
    /// Its id in the Agents hub: adds the hub's Pin / Hide / Move items.
    var hubID: String? = nil

    var body: some View {
        if let controller = CameraController.current {
            CameraMirrorHubTileFace(controller: controller, hubID: hubID)
        }
    }
}

private struct CameraMirrorHubTileFace: View {
    @ObservedObject var controller: CameraController
    let hubID: String?

    var body: some View {
        ExtrasHubTileFace(
            title: controller.isPoppedOut ? "Mirror On" : "Mirror",
            systemImage: controller.isPoppedOut ? "person.crop.square.fill" : "person.crop.square",
            tint: .green,
            isActive: controller.isPoppedOut,
            help: controller.isPoppedOut ? "Close the large mirror" : "Check yourself before a call: a large mirror under the notch"
        ) {
            controller.togglePopOut()
        }
        .contextMenu {
            CameraMirrorMenuItems()
            ExtrasHubMenuTail(hubID: hubID)
        }
    }
}

/// Media pane.
struct CameraMirrorSettingsSection: View {
    @ObservedObject private var settings = CameraMirrorSettings.shared

    var body: some View {
        ExtrasSettingsCard(title: "Mirror",
                           subtitle: "Check yourself before a call. The camera runs only while a mirror shows; the green light tells you when.",
                           systemImage: "person.crop.square") {
            VStack(alignment: .leading, spacing: 2) {
                if let controller = CameraController.current {
                    ExtrasControlRow(title: "Camera", detail: "Built-in, external webcams and Continuity Camera iPhones.") {
                        Menu(controller.cameras.first { $0.id == (settings.cameraID ?? controller.cameras.first { $0.kind == .builtIn }?.id) }?.name ?? "Built-in Camera") {
                            CameraMirrorCameraPicker(controller: controller)
                        }
                        .fixedSize()
                    }
                }
                ExtrasToggleRow(title: "Mirror Image",
                                detail: "On: like a mirror. Off: the natural view, as others see you.",
                                isOn: $settings.isMirrored)
                ExtrasControlRow(title: "Large Mirror Size") {
                    ExtrasSegmented(options: CameraMirrorSettings.PopOutSize.allCases.map { ($0, $0.title) },
                                    selection: $settings.popOutSize, label: "Large mirror size", compact: true)
                        .frame(width: 200)
                }
                ExtrasDivider()
                ExtrasToggleRow(title: "Pop Out When a Call Turns the Camera On",
                                detail: "When Zoom, FaceTime or a browser starts the camera, the large mirror shows for \(settings.autoPopOutSeconds) seconds. Watches the camera's in-use flag; no polling.",
                                isOn: Binding(get: { settings.popsOutWhenCameraStarts },
                                              set: { settings.popsOutWhenCameraStarts = $0; CameraController.current?.updateAutoPopOutWatch() }))
                ExtrasNote(text: "The large mirror is hidden from screen sharing where macOS allows it; some capture tools ignore that, so share a window rather than the whole screen.",
                           systemImage: "eye.slash")
            }
        }
    }
}
