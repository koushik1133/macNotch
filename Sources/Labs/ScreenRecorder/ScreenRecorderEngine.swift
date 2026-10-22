import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Starts and stops one recording. The controller talks to this protocol so
/// tests can drive the state machine without capturing the screen.
@MainActor
protocol ScreenRecorderEngine: AnyObject {
    /// The stream ended without `stop()` (display gone, permission revoked,
    /// the system's "Stop Sharing"). The file so far is finalized when possible.
    var onUnexpectedStop: ((Error?) -> Void)? { get set }
    /// Returns once the first frame is being written to `url`.
    func start(target: ScreenRecorderTarget, plan: ScreenRecorderPlan, url: URL) async throws
    /// Returns once the file is finished.
    func stop() async throws
}

enum ScreenRecorderError: LocalizedError, Equatable {
    case permissionDenied
    case noDisplay
    case windowGone
    case startTimedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow Screen Recording for SparkV in System Settings"
        case .noDisplay: "That display isn't connected any more"
        case .windowGone: "That window closed before recording started"
        case .startTimedOut: "Recording didn't start. Try again"
        case .failed(let message): "Recording failed: \(message)"
        }
    }
}

// MARK: - ScreenCaptureKit engine

/// `SCStream` + `SCRecordingOutput` (macOS 15): ScreenCaptureKit encodes and
/// writes the movie itself, with system audio and the microphone on their
/// own tracks, the cursor, and click circles (`showMouseClicks`, BGRA only).
/// SparkV's own windows (the notch, the region frame) are excluded.
@MainActor
final class ScreenCaptureRecorderEngine: ScreenRecorderEngine {
    var onUnexpectedStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var bridge: ScreenRecorderStreamBridge?
    private var startWaiter: ScreenRecorderWaiter?
    private var finishWaiter: ScreenRecorderWaiter?
    private var stopping = false
    private let sampleQueue = DispatchQueue(label: "SparkV.ScreenRecorder.samples", qos: .userInitiated)

    private static func contains(_ target: ScreenRecorderTarget, in content: SCShareableContent) -> Bool {
        switch target {
        case .display(let display), .region(_, let display): content.displays.contains { $0.displayID == display.id }
        case .window(let id, _, _, _, _): content.windows.contains { $0.windowID == id }
        }
    }

    func start(target: ScreenRecorderTarget, plan: ScreenRecorderPlan, url: URL) async throws {
        let center = PermissionCenter.shared
        guard center.isGranted(.screenRecording) else { throw ScreenRecorderError.permissionDenied }
        // Cached, preflight-gated window list: never prompts by itself.
        var content: SCShareableContent
        do {
            content = try await center.shareableContent(from: "Screen Recorder")
            if !Self.contains(target, in: content) {
                // Newer than the cached list (a window just opened).
                center.invalidateShareableContent()
                content = try await center.shareableContent(from: "Screen Recorder")
            }
        } catch {
            throw ScreenRecorderError.permissionDenied
        }
        center.noteScreenCaptureUse(from: "Screen Recorder")

        let filter: SCContentFilter
        switch target {
        case .display(let display), .region(_, let display):
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { throw ScreenRecorderError.noDisplay }
            let pid = ProcessInfo.processInfo.processIdentifier
            filter = SCContentFilter(display: scDisplay, excludingApplications: content.applications.filter { $0.processID == pid }, exceptingWindows: [])
        case .window(let id, _, _, _, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw ScreenRecorderError.windowGone }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = Self.configuration(for: plan)
        let bridge = ScreenRecorderStreamBridge(
            onStart: { [weak self] in Task { @MainActor in self?.startWaiter?.finish(nil) } },
            onFinish: { [weak self] in Task { @MainActor in self?.finishWaiter?.finish(nil) } },
            onFail: { [weak self] message in
                Task { @MainActor in self?.recordingFailed(ScreenRecorderError.failed(message)) }
            },
            onStreamStop: { [weak self] message in
                Task { @MainActor in self?.streamStopped(message.map { ScreenRecorderError.failed($0) }) }
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: bridge)
        do {
            try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: sampleQueue)
            if plan.options.recordsSystemAudio {
                try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if plan.options.recordsMicrophone {
                try stream.addStreamOutput(bridge, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
        } catch {
            throw ScreenRecorderError.failed(error.localizedDescription)
        }

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = plan.options.format.fileType
        let codec: AVVideoCodecType = plan.codec == .hevc ? .hevc : .h264
        recordingConfiguration.videoCodecType = recordingConfiguration.availableVideoCodecTypes.contains(codec) ? codec : .h264
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: bridge)
        do {
            try stream.addRecordingOutput(output)
        } catch {
            throw ScreenRecorderError.failed(error.localizedDescription)
        }

        self.stream = stream
        self.output = output
        self.bridge = bridge
        stopping = false
        let waiter = ScreenRecorderWaiter()
        startWaiter = waiter
        finishWaiter = ScreenRecorderWaiter()
        do {
            try await Self.startCapture(stream)
        } catch {
            teardown()
            throw ScreenRecorderError.failed(error.localizedDescription)
        }
        let result = await waiter.wait(timeout: .seconds(6))
        startWaiter = nil
        switch result {
        case .some(nil):
            AppLog.log("Screen Recorder: recording \(plan.width)x\(plan.height) \(plan.codec.rawValue) @\(plan.options.framesPerSecond) fps")
        case .some(let error?):
            teardown()
            throw error
        case nil:
            teardown()
            throw ScreenRecorderError.startTimedOut
        }
    }

    func stop() async throws {
        guard let stream, let output else { return }
        stopping = true
        let waiter = finishWaiter ?? ScreenRecorderWaiter()
        finishWaiter = waiter
        // Removing the recording output finishes the file (Apple's
        // "Capturing screen content in macOS" sample); then stop the stream.
        do {
            try stream.removeRecordingOutput(output)
        } catch {
            AppLog.log("Screen Recorder: remove output failed: \(error.localizedDescription)")
        }
        let result = await waiter.wait(timeout: .seconds(8))
        try? await Self.stopCapture(stream)
        teardown()
        if case .some(let error?) = result { throw error }
        if result == nil { AppLog.log("Screen Recorder: finish callback timed out") }
    }

    // MARK: Private

    static func configuration(for plan: ScreenRecorderPlan) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = plan.width
        configuration.height = plan.height
        if let source = plan.sourceRect { configuration.sourceRect = source }
        configuration.scalesToFit = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, plan.options.framesPerSecond)))
        configuration.queueDepth = 6
        // Click circles are only drawn for BGRA output.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = plan.options.showsCursor
        configuration.showMouseClicks = plan.options.highlightsClicks
        configuration.capturesAudio = plan.options.recordsSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = plan.options.recordsMicrophone
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private func recordingFailed(_ error: Error) {
        AppLog.log("Screen Recorder: \(error.localizedDescription)")
        if let startWaiter {
            startWaiter.finish(error)
        } else if stopping {
            finishWaiter?.finish(error)
        } else {
            finishWaiter?.finish(error)
            let callback = onUnexpectedStop
            teardownStreamAsync()
            callback?(error)
        }
    }

    private func streamStopped(_ error: Error?) {
        guard !stopping, stream != nil else { return }
        AppLog.log("Screen Recorder: stream stopped by the system \(error?.localizedDescription ?? "")")
        if let startWaiter {
            startWaiter.finish(error ?? ScreenRecorderError.startTimedOut)
            return
        }
        onUnexpectedStop?(error)
    }

    /// Tears down after a failure outside `stop()`.
    private func teardownStreamAsync() {
        guard let stream else { return }
        teardown()
        Task { try? await Self.stopCapture(stream) }
    }

    private func teardown() {
        stream = nil
        output = nil
        bridge = nil
        startWaiter = nil
    }

    // Completion-handler forms: SCStream isn't Sendable, so its async
    // methods can't be awaited from the main actor under Swift 6.
    private static func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func stopCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// Receives ScreenCaptureKit callbacks on its queues and forwards them.
/// Immutable after init, so it is safe to share.
final class ScreenRecorderStreamBridge: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    private let onStart: @Sendable () -> Void
    private let onFinish: @Sendable () -> Void
    private let onFail: @Sendable (String) -> Void
    private let onStreamStop: @Sendable (String?) -> Void

    init(onStart: @escaping @Sendable () -> Void, onFinish: @escaping @Sendable () -> Void,
         onFail: @escaping @Sendable (String) -> Void, onStreamStop: @escaping @Sendable (String?) -> Void) {
        self.onStart = onStart
        self.onFinish = onFinish
        self.onFail = onFail
        self.onStreamStop = onStreamStop
    }

    // SCStreamOutput: frames are written by SCRecordingOutput; these outputs
    // exist so the stream has a consumer for every enabled sample type.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamStop(error.localizedDescription)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        onStart()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        onFail(error.localizedDescription)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        onFinish()
    }
}

/// A one-shot wait with a timeout, on the main actor. `wait` returns
/// `.some(nil)` on success, `.some(error)` on failure, nil on timeout.
@MainActor
final class ScreenRecorderWaiter {
    private var continuation: CheckedContinuation<Error??, Never>?
    private var result: Error??

    func finish(_ error: Error?) {
        guard result == nil else { return }
        result = .some(error)
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: .some(error))
        }
    }

    func wait(timeout: Duration) async -> Error?? {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(returning: nil)
            }
        }
    }
}
