import AppKit
import AVFoundation
import SwiftUI

// MARK: - SwiftUI bridge

/// Live, mirrored FaceTime HD preview sized to fill its (circular) frame.
struct CameraMirrorView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.applyMirroring()
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        // Fill the circle edge to edge without stretching the 16:9 feed.
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

    /// Mirror like a real mirror, so moving your right hand moves it on the right.
    func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        if connection.automaticallyAdjustsVideoMirroring {
            connection.automaticallyAdjustsVideoMirroring = false
        }
        if !connection.isVideoMirrored {
            connection.isVideoMirrored = true
        }
    }

    // Let clicks reach the SwiftUI button that wraps the preview.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - UI-facing controller

@MainActor
final class CameraController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isDenied = false
    @Published private(set) var errorMessage: String?
    /// The system camera prompt is on screen. The drawer stays open meanwhile,
    /// since moving to the prompt takes the pointer out of the hot zone.
    @Published private(set) var isAwaitingPermission = false

    private let engine = CaptureEngine()
    /// Bumped by every start and stop. A permission answer or session start
    /// that arrives after a newer request is ignored, so a drawer that closed
    /// mid-start can never leave the camera running.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

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

    /// Safe to call at any time, including while a start is still pending:
    /// the stop is queued behind it on the capture queue.
    func stop() {
        generation += 1
        isStarting = false
        isRunning = false
        engine.stop()
    }

    private static let deniedMessage =
        "Camera access is off. Enable SparkV in System Settings › Privacy & Security › Camera."

    private func activate(_ request: Int) {
        isStarting = true
        isDenied = false
        engine.start { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == request else { return }
                self.isStarting = false
                switch result {
                case .success:
                    self.isRunning = true
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
        case .noCamera: "No built-in FaceTime HD camera was found."
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
    let session = AVCaptureSession()

    private let queue = DispatchQueue(
        label: "SparkV.CaptureEngine",
        qos: .userInitiated,
        target: .global(qos: .userInitiated)
    )
    // Only touched on `queue`.
    private var device: AVCaptureDevice?

    func start(completion: @escaping @Sendable (Result<Void, CameraError>) -> Void) {
        queue.async { [self] in
            do {
                // A disconnected AVCaptureDevice instance never reconnects; a
                // returning camera appears as a new instance, so rediscover it.
                if let cached = self.device, !cached.isConnected {
                    removeInputs()
                }
                let device = try self.device ?? configure()
                guard device.isConnected else { throw CameraError.unavailable }
                if !session.isRunning {
                    session.startRunning()
                }
                // startRunning() reports failure only through this flag and
                // the runtime-error notification.
                guard session.isRunning else { throw CameraError.notRunning }
                completion(.success(()))
            } catch let error as CameraError {
                completion(.failure(error))
            } catch {
                completion(.failure(.input(error)))
            }
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
    private func removeInputs() {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        device = nil
    }

    private func configure() throws -> AVCaptureDevice {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first(where: { $0.position == .front })
            ?? discovery.devices.first
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
