import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

/// Records a meeting as two live, on-device transcripts:
/// - the microphone (AVAudioEngine input tap) as speaker `.me`;
/// - system audio (what Zoom / Meet / Teams / the browser play, i.e. the other
///   participants) via ScreenCaptureKit as speaker `.others`.
///
/// Each stream has its own `MeetingTranscriber`, so speakers stay labeled.
/// Segments arrive through `onSegment` on the main actor, volatile ones first,
/// then the final version with the same id.
///
/// Permissions are requested on the first `start()`: Microphone and Speech
/// Recognition are required; without Screen Recording the meeting is recorded
/// from the microphone only and `lastError` says so.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// 0...1 meter levels, updated ~15 times a second while recording.
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// Non-fatal problems (screen recording denied, a device vanished, …).
    @Published private(set) var lastError: String?
    /// True while other participants (system audio) are being captured.
    @Published private(set) var isCapturingSystemAudio = false

    /// Called on the main actor for volatile AND final segments; a phrase
    /// keeps its id until its final version arrives.
    var onSegment: ((TranscriptSegment) -> Void)?

    static let screenRecordingMessage = "Allow Screen Recording to capture other participants"
    /// A Screen Recording grant only applies after SparkV restarts.
    static let screenRecordingRelaunchMessage = "Restart SparkV to capture other participants"

    private static var screenRecordingProblem: String {
        PermissionCenter.shared.screenRecordingNeedsRelaunch ? screenRecordingRelaunchMessage : screenRecordingMessage
    }

    private final class Session {
        let clock: MeetingClock
        var mic: MeetingMicCapture?
        var micTranscriber: MeetingTranscriber?
        var system: MeetingSystemAudioCapture?
        var systemPipeline: MeetingStreamPipeline?
        var systemTranscriber: MeetingTranscriber?
        var systemRestarts = 0

        init(clock: MeetingClock) {
            self.clock = clock
        }
    }

    private var session: Session?
    private var generation = 0
    private var isStarting = false
    private var isStopping = false

    init() {}

    // MARK: Start

    /// Requests permissions on first use, then starts both captures. Throws
    /// when the microphone or speech recognition is unavailable; system audio
    /// problems only set `lastError`.
    func start() async throws {
        guard !isRecording, !isStarting, !isStopping else { return }
        isStarting = true
        defer { isStarting = false }
        generation += 1
        let token = generation
        lastError = nil

        try await MeetingPermissions.ensureMicrophoneAndSpeech()
        try checkCurrent(token)
        let systemAllowed = await MeetingPermissions.prepareScreenCapture()
        try checkCurrent(token)

        let clock = MeetingClock()
        let session = Session(clock: clock)

        // Microphone (required).
        let micTranscriber = MeetingTranscriber(speaker: .me, clock: clock, onSegment: makeEmitter())
        try await micTranscriber.begin()
        guard token == generation else {
            await micTranscriber.cancel()
            throw CancellationError()
        }
        let micPipeline = MeetingStreamPipeline(
            gatesSilence: false,
            voiceRMS: 0.008,
            input: micTranscriber.input,
            now: { clock.now },
            onLevel: makeLevelHandler(system: false)
        )
        let mic = MeetingMicCapture()
        do {
            try await mic.start(
                onBuffer: { buffer in micPipeline.process(buffer) },
                onRestart: { micPipeline.resetContinuity() },
                onFailure: makeMicFailureHandler()
            )
        } catch {
            await mic.stop()
            await micTranscriber.cancel()
            throw error
        }
        guard token == generation else {
            await mic.stop()
            await micTranscriber.cancel()
            throw CancellationError()
        }
        session.mic = mic
        session.micTranscriber = micTranscriber
        self.session = session
        isRecording = true
        AppLog.log("Meeting: recording started (mic: \(micTranscriber.backendName))")

        // System audio (best effort).
        if systemAllowed {
            await startSystemAudio(session: session, token: token)
        } else {
            lastError = Self.screenRecordingProblem
            AppLog.log("Meeting: screen recording not allowed, recording the microphone only")
        }
    }

    private func checkCurrent(_ token: Int) throws {
        if token != generation { throw CancellationError() }
    }

    private func startSystemAudio(session: Session, token: Int) async {
        let transcriber: MeetingTranscriber
        if let existing = session.systemTranscriber {
            transcriber = existing
        } else {
            transcriber = MeetingTranscriber(speaker: .others, clock: session.clock, onSegment: makeEmitter())
            do {
                try await transcriber.begin()
            } catch {
                AppLog.log("Meeting: system audio transcriber failed: \(error)")
                lastError = "Couldn't transcribe other participants"
                return
            }
            guard token == generation, self.session === session else {
                await transcriber.cancel()
                return
            }
            session.systemTranscriber = transcriber
        }

        let pipeline: MeetingStreamPipeline
        if let existing = session.systemPipeline {
            pipeline = existing
        } else {
            let clock = session.clock
            pipeline = MeetingStreamPipeline(
                gatesSilence: true,
                voiceRMS: 0.003,
                input: transcriber.input,
                now: { clock.now },
                onLevel: makeLevelHandler(system: true)
            )
            session.systemPipeline = pipeline
        }

        let capture = MeetingSystemAudioCapture()
        do {
            try await capture.start(
                onBuffer: { buffer in pipeline.process(buffer) },
                onStop: makeSystemStopHandler(token: token)
            )
        } catch {
            await capture.stop()
            AppLog.log("Meeting: system audio capture failed: \(error)")
            let message = MeetingPermissions.isScreenCaptureDenial(error)
                ? Self.screenRecordingProblem
                : "Couldn't capture system audio: \(error.localizedDescription)"
            if self.session === session { lastError = message }
            return
        }
        guard token == generation, self.session === session else {
            await capture.stop()
            return
        }
        session.system = capture
        isCapturingSystemAudio = true
        AppLog.log("Meeting: system audio capture started (\(transcriber.backendName))")
    }

    // MARK: Stop

    /// Stops both captures, flushes the final segments, then returns.
    func stop() async {
        generation += 1
        guard let session, !isStopping else { return }
        isStopping = true
        self.session = nil

        let mic = session.mic
        let system = session.system
        await withTaskGroup(of: Void.self) { group in
            if let mic { group.addTask { await mic.stop() } }
            if let system { group.addTask { await system.stop() } }
        }

        let transcribers = [session.micTranscriber, session.systemTranscriber].compactMap { $0 }
        await withTaskGroup(of: Void.self) { group in
            for transcriber in transcribers {
                group.addTask { await transcriber.finish() }
            }
        }

        micLevel = 0
        systemLevel = 0
        isCapturingSystemAudio = false
        isRecording = false
        isStopping = false
        AppLog.log("Meeting: recording stopped")
    }

    // MARK: Callbacks

    private func makeEmitter() -> @MainActor (TranscriptSegment) -> Void {
        return { [weak self] segment in
            self?.onSegment?(segment)
        }
    }

    private func makeLevelHandler(system: Bool) -> @Sendable (Float) -> Void {
        let box = MeetingWeak(self)
        return { level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let recorder = box.value, recorder.isRecording else { return }
                    if system {
                        recorder.systemLevel = level
                    } else {
                        recorder.micLevel = level
                    }
                }
            }
        }
    }

    private func makeMicFailureHandler() -> @Sendable (String) -> Void {
        let box = MeetingWeak(self)
        return { message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let recorder = box.value, recorder.isRecording else { return }
                    recorder.micLevel = 0
                    recorder.lastError = message
                }
            }
        }
    }

    /// ScreenCaptureKit stopped the stream (display change, permission
    /// revoked, …): try once more, then keep recording the microphone only.
    private func makeSystemStopHandler(token: Int) -> @Sendable (String) -> Void {
        let box = MeetingWeak(self)
        return { message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value?.systemStreamStopped(message, token: token)
                }
            }
        }
    }

    private func systemStreamStopped(_ message: String, token: Int) {
        guard token == generation, let session, isRecording else { return }
        AppLog.log("Meeting: system audio stream stopped: \(message)")
        let stopped = session.system
        session.system = nil
        isCapturingSystemAudio = false
        systemLevel = 0
        session.systemPipeline?.resetContinuity()
        Task { await stopped?.stop() }
        guard session.systemRestarts < 2 else {
            lastError = "System audio stopped: \(message)"
            return
        }
        session.systemRestarts += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, token == self.generation, self.session === session else { return }
            await self.startSystemAudio(session: session, token: token)
        }
    }
}

// MARK: - Errors and permissions

enum MeetingRecorderError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Allow Microphone for SparkV to record meetings"
        case .speechDenied: "Allow Speech Recognition for SparkV to transcribe meetings"
        case .noMicrophone: "No microphone found"
        }
    }
}

extension MeetingTranscriberError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: "Speech recognition is unavailable right now"
        }
    }
}

/// Every check and request goes through PermissionCenter: one system prompt
/// at a time, never at launch, and refused permissions open System Settings.
@MainActor
enum MeetingPermissions {
    private static let feature = "Meeting recorder"

    /// Call from a user action (Record).
    static func ensureMicrophoneAndSpeech() async throws {
        let center = PermissionCenter.shared
        guard await center.ensure(.microphone, from: feature) else { throw MeetingRecorderError.microphoneDenied }
        guard await center.ensure(.speech, from: feature) else { throw MeetingRecorderError.speechDenied }
    }

    /// True when system audio capture should be attempted. Asks for Screen
    /// Recording only while it was never asked with this signature; a refusal
    /// is not re-asked on every recording (the meeting records the microphone
    /// only and says so). Never calls ScreenCaptureKit without the grant, so
    /// ScreenCaptureKit can't bring up its own dialog.
    static func prepareScreenCapture() async -> Bool {
        let center = PermissionCenter.shared
        if center.isGranted(.screenRecording) { return true }
        guard center.status(.screenRecording) == .notDetermined else { return false }
        AppLog.log("Meeting: requesting Screen Recording")
        return await center.request(.screenRecording, from: feature).isGranted
    }

    /// Opens the Screen Recording pane (for a "Capture other participants" action).
    static func openScreenRecordingSettings() {
        PermissionCenter.shared.openSettings(.screenRecording, from: feature)
    }

    static func isScreenCaptureDenial(_ error: any Error) -> Bool {
        if case PermissionCenter.PermissionError.notGranted = error { return true }
        return PermissionCenter.isCaptureDenial(error) || !PermissionCenter.shared.isGranted(.screenRecording)
    }

    /// ScreenCaptureKit's window list through the cached, preflight-gated
    /// helper (boxed so it can leave the main actor).
    static func shareableContent() async throws -> ShareableContentBox {
        ShareableContentBox(try await PermissionCenter.shared.shareableContent(from: feature))
    }

    static func noteStream() {
        PermissionCenter.shared.noteScreenCaptureUse(from: feature)
    }
}

// MARK: - Stream pipeline

/// Per-stream processing on the capture thread: downmix to mono Float32,
/// level meter, silence gate (system audio) and timeline continuity, then
/// hand-off to the transcriber input.
final class MeetingStreamPipeline: @unchecked Sendable {
    /// Silence is still fed for this long after speech so the recognizer can
    /// finalize the phrase.
    static let hangover: TimeInterval = 1.5
    /// Audio kept from just before speech resumes, so the first syllable is not clipped.
    static let preroll: TimeInterval = 0.3
    /// Gaps shorter than this between buffers count as contiguous (arrival jitter).
    static let jitterTolerance: TimeInterval = 0.5

    private let lock = NSLock()
    private let gatesSilence: Bool
    private let voiceRMS: Float
    private let input: any MeetingAudioSink
    private let now: @Sendable () -> TimeInterval
    private let onLevel: @Sendable (Float) -> Void
    private let mixer = MeetingMonoMixer()

    private var lastEnd: TimeInterval?
    private var lastFedEnd: TimeInterval?
    private var lastVoicedEnd: TimeInterval = -.greatestFiniteMagnitude
    private var pending: [(buffer: AVAudioPCMBuffer, start: TimeInterval)] = []
    private var lastLevelReport: TimeInterval = -.greatestFiniteMagnitude
    private var peakSinceReport: Float = 0

    /// Fed/skipped counters, for tests and diagnostics.
    private(set) var fedBuffers = 0
    private(set) var skippedBuffers = 0

    init(
        gatesSilence: Bool,
        voiceRMS: Float,
        input: any MeetingAudioSink,
        now: @escaping @Sendable () -> TimeInterval,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.gatesSilence = gatesSilence
        self.voiceRMS = voiceRMS
        self.input = input
        self.now = now
        self.onLevel = onLevel
    }

    /// Capture thread. Accepts any PCM format.
    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let mono = mixer.mix(buffer) else { return }
        let duration = MeetingAudio.duration(of: mono)
        guard duration > 0 else { return }

        // Start time: contiguous with the previous buffer unless a real gap
        // (device restart, stalled stream) shows up in arrival times.
        let arrivalStart = max(0, now() - duration)
        let start: TimeInterval
        if let lastEnd, arrivalStart - lastEnd < Self.jitterTolerance {
            start = lastEnd
        } else {
            start = arrivalStart
        }
        lastEnd = start + duration

        let rms = MeetingAudio.rms(mono)
        let voiced = rms >= voiceRMS
        reportLevel(MeetingAudio.meterLevel(rms: rms), at: start + duration)
        if voiced { lastVoicedEnd = start + duration }

        let open = !gatesSilence || voiced || start - lastVoicedEnd < Self.hangover
        guard open else {
            // Near-silent system audio: keep a short pre-roll, skip the rest.
            pending.append((mono, start))
            var kept: TimeInterval = pending.reduce(0) { $0 + MeetingAudio.duration(of: $1.buffer) }
            while kept > Self.preroll, let first = pending.first {
                kept -= MeetingAudio.duration(of: first.buffer)
                pending.removeFirst()
                skippedBuffers += 1
            }
            return
        }

        let batch = pending + [(mono, start)]
        pending.removeAll()
        for item in batch {
            let itemDuration = MeetingAudio.duration(of: item.buffer)
            let contiguous = lastFedEnd.map { abs(item.start - $0) < 0.001 } ?? false
            input.append(item.buffer, start: item.start, contiguous: contiguous, voiced: voiced && item.start == start)
            lastFedEnd = item.start + itemDuration
            fedBuffers += 1
        }
    }

    /// After a device restart: the next buffer starts a new timeline anchor.
    func resetContinuity() {
        lock.lock(); defer { lock.unlock() }
        lastEnd = nil
        pending.removeAll()
    }

    private func reportLevel(_ level: Float, at time: TimeInterval) {
        peakSinceReport = max(peakSinceReport, level)
        guard time - lastLevelReport >= 1.0 / 15 else { return }
        lastLevelReport = time
        let value = peakSinceReport
        peakSinceReport = 0
        onLevel(value)
    }
}

// MARK: - Microphone capture

/// AVAudioEngine microphone tap. Engine work runs on a private serial queue,
/// never on the main thread. Restarts itself when the input device or its
/// format changes (AVAudioEngineConfigurationChange).
final class MeetingMicCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.Meeting.Mic", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onRestart: (@Sendable () -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var isRunning = false
    private var restartAttempts = 0

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onRestart: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    self.onBuffer = onBuffer
                    self.onRestart = onRestart
                    self.onFailure = onFailure
                    try self.startEngine()
                    self.isRunning = true
                    continuation.resume()
                } catch {
                    self.teardown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isRunning = false
                self.teardown()
                self.onBuffer = nil
                self.onRestart = nil
                self.onFailure = nil
                continuation.resume()
            }
        }
    }

    /// Queue only.
    private func startEngine() throws {
        guard let onBuffer else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingRecorderError.noMicrophone }

        if #available(macOS 27.0, *) {
            try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                onBuffer(AVAudioPCMBuffer(copying: buffer))
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTapBlock(onBuffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restart() }
        }
        AppLog.log("Meeting: microphone \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    /// Queue only. The device changed (AirPods connected, USB mic unplugged, …).
    private func restart() {
        guard isRunning else { return }
        AppLog.log("Meeting: audio configuration changed, restarting microphone")
        teardown()
        onRestart?()
        do {
            try startEngine()
            restartAttempts = 0
        } catch {
            restartAttempts += 1
            AppLog.log("Meeting: microphone restart failed (\(error)), attempt \(restartAttempts)")
            if restartAttempts >= 10 {
                isRunning = false
                onFailure?("Microphone disconnected")
                return
            }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart() }
        }
    }

    /// Queue only.
    private func teardown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
    }

    /// Built outside any actor: the block runs on the realtime audio thread.
    private static func makeTapBlock(_ handle: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in handle(buffer) }
    }
}

// MARK: - System audio capture

/// System audio through ScreenCaptureKit: a display stream with a 2×2,
/// 1 fps video track (ignored) and audio enabled, excluding NotchIsland's
/// own sounds.
final class MeetingSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "SparkV.Meeting.SystemAudio", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "SparkV.Meeting.SystemVideo", qos: .utility)
    private let lock = NSLock()
    private var stream: SCStream?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onStop: (@Sendable (String) -> Void)?

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onStop: @escaping @Sendable (String) -> Void
    ) async throws {
        let content = try await MeetingPermissions.shareableContent().content
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw NSError(domain: "SparkV.Meeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture audio from"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = Self.makeConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // A screen output too, so ScreenCaptureKit doesn't log dropped frames.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)

        install(stream: stream, onBuffer: onBuffer, onStop: onStop)
        try await stream.startCapture()
        await MeetingPermissions.noteStream()
    }

    func stop() async {
        guard let stream = takeStream() else { return }
        do {
            try await stream.stopCapture()
        } catch {
            AppLog.log("Meeting: stopping system audio: \(error.localizedDescription)")
        }
    }

    private func install(
        stream: SCStream,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onStop: @escaping @Sendable (String) -> Void
    ) {
        lock.lock(); defer { lock.unlock() }
        self.onBuffer = onBuffer
        self.onStop = onStop
        self.stream = stream
    }

    private func takeStream() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        let stream = self.stream
        self.stream = nil
        onBuffer = nil
        onStop = nil
        return stream
    }

    static func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        return configuration
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lock.lock()
        let onBuffer = self.onBuffer
        lock.unlock()
        guard let onBuffer, let buffer = MeetingAudio.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        let onStop = self.onStop
        let isCurrent = self.stream === stream
        lock.unlock()
        guard isCurrent else { return }
        onStop?(error.localizedDescription)
    }
}
