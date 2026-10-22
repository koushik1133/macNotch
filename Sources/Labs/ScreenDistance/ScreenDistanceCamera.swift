import AVFoundation
import CoreVideo
import Foundation
import Vision

enum ScreenDistanceCameraError: Error, Equatable, Sendable {
    case noCamera
    /// Another app (or another session in this app) holds the camera.
    case inUse
    case cannotConfigure
    case notRunning
    /// The session ran but no frame arrived before the timeout.
    case noFrames
    /// A burst or stream is already running.
    case busy
}

/// What the controller needs from a camera. The real one is
/// `ScreenDistanceCamera`; the harness injects a fake.
protocol ScreenDistanceSampling: AnyObject, Sendable {
    /// Starts the camera, analyses `frames` frames (after a short warm-up),
    /// stops the camera and calls back on an arbitrary queue.
    func captureBurst(
        frames: Int,
        timeout: TimeInterval,
        completion: @escaping @Sendable (Result<[ScreenDistanceFrame], ScreenDistanceCameraError>) -> Void
    )
    /// Keeps the camera on and delivers about `framesPerSecond` analysed
    /// frames until `stopAll()`. Used only while the notice is on screen.
    func startStream(
        framesPerSecond: Double,
        onFrame: @escaping @Sendable (ScreenDistanceFrame) -> Void,
        onFailure: @escaping @Sendable (ScreenDistanceCameraError) -> Void
    )
    /// Ends any burst (delivering what it has) or stream and turns the camera off.
    func stopAll()
}

/// FaceTime camera + Vision face landmarks at 640×480. Frames are analysed
/// in memory and dropped: nothing is written to disk or kept after the
/// eye positions are read. The session is stopped between bursts so the
/// camera (and its green light) is on only about a second at a time.
final class ScreenDistanceCamera: NSObject, ScreenDistanceSampling, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    /// Frames dropped after the session starts while auto-exposure settles.
    static let warmUpFrames = 4

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "SparkV.ScreenDistance.session", qos: .utility)
    private let videoQueue = DispatchQueue(label: "SparkV.ScreenDistance.video", qos: .utility)

    // Only touched on `sessionQueue`.
    private var device: AVCaptureDevice?
    private var isConfigured = false

    // Guarded by `lock`.
    private let lock = NSLock()
    private var mode: Mode = .idle
    private var generation = 0
    private var fieldOfView: Double = 0
    /// The running device, read per frame for Center Stage.
    private var activeDevice: AVCaptureDevice?

    private enum Mode {
        case idle
        case starting
        case burst(Burst)
        case stream(Stream)
    }

    private struct Burst {
        var wanted: Int
        var skipped = 0
        var frames: [ScreenDistanceFrame] = []
        var completion: @Sendable (Result<[ScreenDistanceFrame], ScreenDistanceCameraError>) -> Void
    }

    private struct Stream {
        var minInterval: TimeInterval
        var skipped = 0
        var lastEmit: Date = .distantPast
        var onFrame: @Sendable (ScreenDistanceFrame) -> Void
    }

    // MARK: ScreenDistanceSampling

    func captureBurst(
        frames: Int,
        timeout: TimeInterval,
        completion: @escaping @Sendable (Result<[ScreenDistanceFrame], ScreenDistanceCameraError>) -> Void
    ) {
        guard let gen = claim() else { completion(.failure(.busy)); return }
        sessionQueue.async { [self] in
            if let error = startSession() {
                release(gen)
                completion(.failure(error))
                return
            }
            guard setMode(.burst(Burst(wanted: max(1, frames), completion: completion)), ifGeneration: gen) else {
                // stopAll() ran while the camera was starting.
                if session.isRunning { session.stopRunning() }
                completion(.failure(.busy))
                return
            }
            sessionQueue.asyncAfter(deadline: .now() + timeout) { [self] in
                finishBurst(generation: gen, timedOut: true)
            }
        }
    }

    func startStream(
        framesPerSecond: Double,
        onFrame: @escaping @Sendable (ScreenDistanceFrame) -> Void,
        onFailure: @escaping @Sendable (ScreenDistanceCameraError) -> Void
    ) {
        guard let gen = claim() else { onFailure(.busy); return }
        sessionQueue.async { [self] in
            if let error = startSession() {
                release(gen)
                onFailure(error)
                return
            }
            let interval = 1 / max(0.5, min(15, framesPerSecond))
            if !setMode(.stream(Stream(minInterval: interval, onFrame: onFrame)), ifGeneration: gen), session.isRunning {
                session.stopRunning()
            }
        }
    }

    func stopAll() {
        lock.lock()
        let previous = mode
        mode = .idle
        generation &+= 1
        lock.unlock()
        if case .burst(let burst) = previous {
            burst.completion(burst.frames.isEmpty ? .failure(.noFrames) : .success(burst.frames))
        }
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: Mode bookkeeping

    /// Reserves the camera for a new burst or stream; nil if one is running.
    private func claim() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard case .idle = mode else { return nil }
        generation &+= 1
        mode = .starting
        return generation
    }

    private func release(_ gen: Int) {
        lock.lock()
        if generation == gen { mode = .idle }
        lock.unlock()
    }

    private func setMode(_ newMode: Mode, ifGeneration gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == gen, case .starting = mode else { return false }
        mode = newMode
        return true
    }

    private func finishBurst(generation gen: Int, timedOut: Bool) {
        lock.lock()
        guard generation == gen, case .burst(let burst) = mode else { lock.unlock(); return }
        mode = .idle
        lock.unlock()
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        if burst.frames.isEmpty, timedOut {
            burst.completion(.failure(.noFrames))
        } else {
            burst.completion(.success(burst.frames))
        }
    }

    // MARK: Session (sessionQueue only)

    private func startSession() -> ScreenDistanceCameraError? {
        if let cached = device, !cached.isConnected {
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
            device = nil
            isConfigured = false
        }
        if !isConfigured {
            if let error = configure() { return error }
        }
        guard let device else { return .noCamera }
        // Never fight a call or a recording for the camera.
        if !session.isRunning, device.isInUseByAnotherApplication { return .inUse }
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else { return .notRunning }
        let fov = Self.horizontalFOV(of: device.activeFormat)
        lock.lock(); fieldOfView = fov; activeDevice = device; lock.unlock()
        return nil
    }

    private func configure() -> ScreenDistanceCameraError? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        )
        guard let camera = discovery.devices.first(where: { $0.position == .front }) ?? discovery.devices.first else {
            return .noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            return .cannotConfigure
        }
        session.addInput(input)

        // The smallest native 16:9 format keeps the full field of view (a
        // 4:3 preset would crop the sides); frames are then scaled to 640 px
        // wide, which is plenty for eye landmarks and cheap for Vision.
        var aspect = 16.0 / 9.0
        if let format = Self.preferredFormat(of: camera), (try? camera.lockForConfiguration()) != nil {
            camera.activeFormat = format
            camera.unlockForConfiguration()
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        if dims.width > 0, dims.height > 0 { aspect = Double(dims.width) / Double(dims.height) }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: Self.analysisWidth,
            kCVPixelBufferHeightKey as String: Int((Double(Self.analysisWidth) / aspect).rounded()),
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return .cannotConfigure }
        session.addOutput(output)

        device = camera
        isConfigured = true
        return nil
    }

    static let analysisWidth = 640

    /// Smallest 16:9 format at least 640 px wide, else the smallest one.
    static func preferredFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let sized = device.formats.map { format -> (AVCaptureDevice.Format, Int32, Int32) in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (format, d.width, d.height)
        }
        .filter { $0.1 >= 640 && $0.2 > 0 }
        let wide = sized.filter { abs(Double($0.1) / Double($0.2) - 16.0 / 9.0) < 0.02 }
        return (wide.isEmpty ? sized : wide).min { $0.1 < $1.1 }?.0
    }

    /// The format's own horizontal FOV extension when present (rare for live
    /// cameras), else the nominal value for its aspect ratio.
    static func horizontalFOV(of format: AVCaptureDevice.Format) -> Double {
        let description = format.formatDescription
        if let value = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_HorizontalFieldOfView
        ) as? NSNumber, value.doubleValue > 1000 {
            return value.doubleValue / 1000
        }
        let d = CMVideoFormatDescriptionGetDimensions(description)
        guard d.width > 0, d.height > 0 else { return ScreenDistanceMath.fallbackHorizontalFOVDegrees }
        return ScreenDistanceMath.nominalHorizontalFOV(aspectRatio: Double(d.width) / Double(d.height))
    }

    // MARK: Frames (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let gen = generation
        let fov = fieldOfView
        let device = activeDevice
        var shouldAnalyze = false
        switch mode {
        case .burst(var burst):
            if burst.skipped < Self.warmUpFrames {
                burst.skipped += 1
                mode = .burst(burst)
            } else {
                shouldAnalyze = true
            }
        case .stream(var stream):
            if stream.skipped < Self.warmUpFrames {
                stream.skipped += 1
                mode = .stream(stream)
            } else if Date().timeIntervalSince(stream.lastEmit) >= stream.minInterval {
                stream.lastEmit = Date()
                mode = .stream(stream)
                shouldAnalyze = true
            }
        case .idle, .starting:
            break
        }
        lock.unlock()
        guard shouldAnalyze, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var frame = ScreenDistanceVision.analyze(pixelBuffer: pixelBuffer, horizontalFOVDegrees: fov, timestamp: Date())
        // Center Stage pans and zooms, so the field of view (and with it the
        // focal length) is unknown: the controller pauses instead of guessing.
        if device?.isCenterStageActive == true { frame.isReframed = true }

        lock.lock()
        guard generation == gen else { lock.unlock(); return }
        switch mode {
        case .burst(var burst):
            burst.frames.append(frame)
            let done = burst.frames.count >= burst.wanted
            mode = .burst(burst)
            lock.unlock()
            if done { finishBurst(generation: gen, timedOut: false) }
        case .stream(let stream):
            lock.unlock()
            stream.onFrame(frame)
        case .idle, .starting:
            lock.unlock()
        }
    }
}

/// Vision face landmarks → eye positions. Shared by the camera and the
/// harness (which runs it on still images).
enum ScreenDistanceVision {
    static func analyze(pixelBuffer: CVPixelBuffer, horizontalFOVDegrees: Double, timestamp: Date) -> ScreenDistanceFrame {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return analyze(handler: handler, imageSize: size, horizontalFOVDegrees: horizontalFOVDegrees, timestamp: timestamp)
    }

    static func analyze(cgImage: CGImage, horizontalFOVDegrees: Double, timestamp: Date = Date()) -> ScreenDistanceFrame {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        return analyze(handler: handler, imageSize: size, horizontalFOVDegrees: horizontalFOVDegrees, timestamp: timestamp)
    }

    static func analyze(
        handler: VNImageRequestHandler, imageSize: CGSize, horizontalFOVDegrees: Double, timestamp: Date
    ) -> ScreenDistanceFrame {
        let request = VNDetectFaceLandmarksRequest()
        var faces: [ScreenDistanceFace] = []
        if (try? handler.perform([request])) != nil {
            faces = (request.results ?? []).compactMap { face(from: $0, imageSize: imageSize) }
        }
        return ScreenDistanceFrame(
            faces: faces, frameWidthPixels: Double(imageSize.width),
            horizontalFOVDegrees: horizontalFOVDegrees, timestamp: timestamp
        )
    }

    static func face(from observation: VNFaceObservation, imageSize: CGSize) -> ScreenDistanceFace? {
        guard let landmarks = observation.landmarks,
              let left = eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let right = eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize)
        else { return nil }
        return ScreenDistanceFace(leftEye: left, rightEye: right, yaw: observation.yaw?.doubleValue)
    }

    private static func eyeCenter(pupil: VNFaceLandmarkRegion2D?, eye: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> CGPoint? {
        if let pupil, pupil.pointCount > 0, let point = pupil.pointsInImage(imageSize: imageSize).first {
            return point
        }
        guard let eye, eye.pointCount > 0 else { return nil }
        let points = eye.pointsInImage(imageSize: imageSize)
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
