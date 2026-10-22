import AVFoundation
import CoreMedia
import Foundation
import Speech

// Live, on-device transcription for the meeting assistant. One
// `MeetingTranscriber` runs per audio stream (microphone = .me, system audio =
// .others). It prefers SpeechAnalyzer/SpeechTranscriber (macOS 26+, long-form,
// volatile + final results with audio time ranges) and falls back to
// SFSpeechRecognizer on-device, rotating recognition tasks every ~50 s so the
// per-task limit never cuts a meeting short.
//
// Audio enters through `MeetingTranscriber.input` on the capture thread as mono
// Float32 buffers stamped with their start time (seconds since the recording
// started). Segments leave through `onSegment` on the main actor: a phrase keeps
// one id while it is volatile and is replaced in place by its final version.

// MARK: - Clock

/// Seconds since the recording started, from the monotonic system clock.
struct MeetingClock: Sendable {
    let startUptime: TimeInterval

    init(startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startUptime = startUptime
    }

    var now: TimeInterval { max(0, ProcessInfo.processInfo.systemUptime - startUptime) }
}

// MARK: - Audio format helpers

enum MeetingAudio {
    /// Mono, deinterleaved Float32 at `sampleRate`: the format every pipeline
    /// stage hands to the transcribers.
    static func monoFloatFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Copies the PCM audio of a ScreenCaptureKit (or any Core Media) audio
    /// sample buffer into a new AVAudioPCMBuffer in the same format.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    /// Root mean square of the first channel (mono after the mixer).
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let channels = buffer.floatChannelData {
            let samples = channels[0]
            for index in 0..<frames { sum += samples[index] * samples[index] }
        } else if let channels = buffer.int16ChannelData {
            let samples = channels[0]
            for index in 0..<frames {
                let value = Float(samples[index]) / Float(Int16.max)
                sum += value * value
            }
        } else {
            return 0
        }
        return (sum / Float(frames)).squareRoot()
    }

    /// RMS mapped to a 0...1 meter value: -55 dB (room tone) ... -10 dB (loud speech).
    static func meterLevel(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 55) / 45))
    }

    static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        let rate = buffer.format.sampleRate
        return rate > 0 ? Double(buffer.frameLength) / rate : 0
    }
}

/// Downmixes any PCM buffer to a new mono Float32 buffer at the same sample
/// rate (the result never aliases the input, so taps may reuse theirs).
/// Not thread-safe: use from one capture thread at a time.
final class MeetingMonoMixer {
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    func mix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        let frames = buffer.frameLength
        guard frames > 0, source.sampleRate > 0, source.channelCount > 0,
              let target = MeetingAudio.monoFloatFormat(sampleRate: source.sampleRate),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames),
              let destination = output.floatChannelData?[0] else {
            return nil
        }

        // Fast path: deinterleaved Float32 (AVAudioEngine taps, ScreenCaptureKit).
        if source.commonFormat == .pcmFormatFloat32, !source.isInterleaved, let channels = buffer.floatChannelData {
            let channelCount = Int(source.channelCount)
            let count = Int(frames)
            let scale = 1 / Float(channelCount)
            for index in 0..<count {
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][index] }
                destination[index] = value * scale
            }
            output.frameLength = frames
            return output
        }

        // Anything else (interleaved, Int16, Int32, Float64): AVAudioConverter.
        if converter == nil || converterSource != source {
            converter = AVAudioConverter(from: source, to: target)
            converter?.downmix = true
            converterSource = source
        }
        guard let converter else { return nil }
        do {
            try converter.convert(to: output, from: buffer)
        } catch {
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}

/// Sample-rate/format converter that keeps its state across buffers so the
/// resampled stream stays continuous. Not thread-safe.
final class MeetingResampler {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return nil }
        if converter == nil || converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            converterSource = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - Timeline

/// Maps the transcriber's audio timeline (seconds of audio actually fed, which
/// skips silence and device restarts) back to seconds since the recording
/// started. Written on the capture thread, read on the main actor.
final class MeetingTimeline: @unchecked Sendable {
    private struct Anchor {
        let fed: TimeInterval
        let recording: TimeInterval
    }

    private let lock = NSLock()
    private var anchors: [Anchor] = []
    private var fed: TimeInterval = 0

    /// Records `frames` of fed audio that started at `recordingStart`. A
    /// non-contiguous buffer (after a gap) starts a new anchor.
    func advance(frames: AVAudioFrameCount, sampleRate: Double, recordingStart: TimeInterval, contiguous: Bool) {
        guard sampleRate > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if !contiguous || anchors.isEmpty {
            anchors.append(Anchor(fed: fed, recording: recordingStart))
        }
        fed += Double(frames) / sampleRate
    }

    var fedSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return fed
    }

    func recordingTime(forFed time: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let first = anchors.first else { return max(0, time) }
        var anchor = first
        for candidate in anchors.reversed() where candidate.fed <= time {
            anchor = candidate
            break
        }
        return max(0, anchor.recording + (time - anchor.fed))
    }
}

// MARK: - Transcriber input

/// Receives mono Float32 buffers on the capture thread. `start` is seconds
/// since the recording started; `contiguous` is false after a gap (skipped
/// silence, device change); `voiced` is true when the buffer has speech-level
/// energy. The sink owns `buffer` from then on.
protocol MeetingAudioSink: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer, start: TimeInterval, contiguous: Bool, voiced: Bool)
}

/// The transcriber's stable entry point. Forwards to the active engine's
/// sink, so the engine can be swapped (SpeechAnalyzer -> SFSpeechRecognizer)
/// mid-meeting without touching the capture side.
final class MeetingTranscriberInput: MeetingAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (any MeetingAudioSink)?

    func append(_ buffer: AVAudioPCMBuffer, start: TimeInterval, contiguous: Bool, voiced: Bool) {
        lock.lock()
        let target = self.target
        lock.unlock()
        target?.append(buffer, start: start, contiguous: contiguous, voiced: voiced)
    }

    func setTarget(_ target: (any MeetingAudioSink)?) {
        lock.lock(); defer { lock.unlock() }
        self.target = target
    }
}

// MARK: - Transcriber

/// A phrase update from an engine. Times are seconds since recording start.
struct MeetingPhrase: Sendable {
    let id: UUID
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let isFinal: Bool
}

@MainActor
protocol MeetingSpeechEngine: AnyObject {
    var sink: any MeetingAudioSink { get }
    var name: String { get }
    func begin() async throws
    /// Ends input and waits (bounded) for the last final results.
    func finish() async
    func cancel() async
}

enum MeetingTranscriberError: Error {
    case recognizerUnavailable
}

@MainActor
final class MeetingTranscriber {
    let speaker: MeetingSpeaker
    /// Feed audio here from the capture thread.
    nonisolated let input = MeetingTranscriberInput()
    /// "SpeechAnalyzer" or "SFSpeechRecognizer" once started.
    private(set) var backendName = ""

    private let clock: MeetingClock
    private let onSegment: @MainActor (TranscriptSegment) -> Void
    private var engine: (any MeetingSpeechEngine)?
    private var isEnding = false
    /// Last text emitted per phrase, so a final never blanks a phrase that was shown.
    private var lastText: [UUID: String] = [:]

    init(speaker: MeetingSpeaker, clock: MeetingClock, onSegment: @escaping @MainActor (TranscriptSegment) -> Void) {
        self.speaker = speaker
        self.clock = clock
        self.onSegment = onSegment
    }

    /// Starts the best available engine. Throws when no recognizer can run.
    func begin() async throws {
        guard engine == nil else { return }
        if #available(macOS 26.0, *),
           let analyzer = await MeetingAnalyzerEngine.make(
               label: speaker.rawValue,
               onPhrase: { [weak self] in self?.emit($0) },
               onFailure: { [weak self] engine, error in self?.engineFailed(engine, error: error) }
           ) {
            do {
                try await analyzer.begin()
                install(analyzer)
                return
            } catch {
                AppLog.log("Meeting[\(speaker.rawValue)]: SpeechAnalyzer failed to start (\(error)), using SFSpeechRecognizer")
                await analyzer.cancel()
            }
        }
        try await startLegacy()
    }

    func finish() async {
        isEnding = true
        guard let engine else { return }
        await engine.finish()
        input.setTarget(nil)
        self.engine = nil
        lastText.removeAll()
    }

    func cancel() async {
        isEnding = true
        input.setTarget(nil)
        guard let engine else { return }
        self.engine = nil
        await engine.cancel()
        lastText.removeAll()
    }

    private func startLegacy() async throws {
        let legacy = try MeetingLegacyEngine(
            label: speaker.rawValue,
            clock: clock,
            onPhrase: { [weak self] in self?.emit($0) },
            onFailure: { [weak self] engine, error in self?.engineFailed(engine, error: error) }
        )
        try await legacy.begin()
        install(legacy)
    }

    private func install(_ engine: any MeetingSpeechEngine) {
        self.engine = engine
        backendName = engine.name
        input.setTarget(engine.sink)
        AppLog.log("Meeting[\(speaker.rawValue)]: \(engine.name) started")
    }

    private func emit(_ phrase: MeetingPhrase) {
        var text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // A final for a phrase that was shown keeps its last text; empty
            // phrases that were never shown are dropped.
            guard phrase.isFinal, let previous = lastText[phrase.id] else { return }
            text = previous
        }
        if phrase.isFinal {
            lastText[phrase.id] = nil
        } else {
            lastText[phrase.id] = text
        }
        let start = max(0, phrase.start)
        let segment = TranscriptSegment(
            id: phrase.id,
            speaker: speaker,
            text: text,
            start: start,
            end: max(start, phrase.end),
            isFinal: phrase.isFinal
        )
        onSegment(segment)
    }

    /// An engine died mid-meeting: SpeechAnalyzer falls back to
    /// SFSpeechRecognizer; a failing SFSpeechRecognizer stops this stream.
    private func engineFailed(_ failed: any MeetingSpeechEngine, error: String) {
        guard !isEnding, let engine, engine === failed else { return }
        AppLog.log("Meeting[\(speaker.rawValue)]: \(failed.name) failed: \(error)")
        input.setTarget(nil)
        self.engine = nil
        let wasAnalyzer = failed.name == MeetingAnalyzerName.value
        Task { [weak self] in
            await failed.cancel()
            guard let self, !self.isEnding, wasAnalyzer else { return }
            do {
                try await self.startLegacy()
            } catch {
                AppLog.log("Meeting[\(self.speaker.rawValue)]: no fallback recognizer: \(error)")
            }
        }
    }
}

enum MeetingAnalyzerName {
    static let value = "SpeechAnalyzer"
}

/// Waits for `operation` at most `seconds`; nil on timeout. The operation is
/// cancelled when time runs out.
enum MeetingTimeout {
    static func run<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - SpeechAnalyzer engine (macOS 26+)

@available(macOS 26.0, *)
@MainActor
final class MeetingAnalyzerEngine: MeetingSpeechEngine {
    let sink: any MeetingAudioSink
    let name = MeetingAnalyzerName.value

    private let label: String
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerSink: MeetingAnalyzerSink
    private let timeline = MeetingTimeline()
    private let onPhrase: @MainActor (MeetingPhrase) -> Void
    private let onFailure: @MainActor (any MeetingSpeechEngine, String) -> Void
    private var resultsTask: Task<Void, Never>?
    private var isEnding = false

    private var phraseID: UUID?
    private var phraseStart: TimeInterval = 0
    private var phraseEnd: TimeInterval = 0

    private static var isInstallingAssets = false

    private init(
        label: String,
        analyzer: SpeechAnalyzer,
        format: AVAudioFormat,
        onPhrase: @escaping @MainActor (MeetingPhrase) -> Void,
        onFailure: @escaping @MainActor (any MeetingSpeechEngine, String) -> Void
    ) {
        self.label = label
        self.analyzer = analyzer
        self.format = format
        self.onPhrase = onPhrase
        self.onFailure = onFailure
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
        let analyzerSink = MeetingAnalyzerSink(format: format, continuation: continuation, timeline: timeline)
        self.analyzerSink = analyzerSink
        sink = analyzerSink
    }

    /// nil when SpeechTranscriber cannot run right now (unsupported locale,
    /// model not installed yet); a missing model is downloaded in the
    /// background for the next meeting.
    static func make(
        label: String,
        onPhrase: @escaping @MainActor (MeetingPhrase) -> Void,
        onFailure: @escaping @MainActor (any MeetingSpeechEngine, String) -> Void
    ) async -> MeetingAnalyzerEngine? {
        // Live Translation's "Others Speak" setting (nil: the Mac's language).
        let wanted = LiveTranslationSpokenLanguage.transcriberLocale(speakerLabel: label) ?? Locale.current
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            AppLog.log("Meeting[\(label)]: SpeechTranscriber unavailable for \(wanted.identifier)")
            return nil
        }
        let transcriber = makeModule(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            AppLog.log("Meeting[\(label)]: speech model for \(locale.identifier) is \(status)")
            if status == .supported || status == .downloading { installAssets(for: locale) }
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return nil
        }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let engine = MeetingAnalyzerEngine(
            label: label, analyzer: analyzer, format: format, onPhrase: onPhrase, onFailure: onFailure
        )
        engine.consume(transcriber.results)
        return engine
    }

    /// Long-form transcription with volatile results and audio time ranges.
    nonisolated private static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    func begin() async throws {
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
    }

    func finish() async {
        isEnding = true
        analyzerSink.close()
        continuation.finish()
        let analyzer = self.analyzer
        let finalized = await MeetingTimeout.run(seconds: 4) {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            } catch {
                return false
            }
        }
        if finalized != true { await analyzer.cancelAndFinishNow() }
        if let resultsTask {
            _ = await MeetingTimeout.run(seconds: 1.5) {
                await resultsTask.value
                return true
            }
            resultsTask.cancel()
        }
        closeOpenPhrase()
    }

    func cancel() async {
        isEnding = true
        analyzerSink.close()
        continuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
        closeOpenPhrase()
    }

    private func consume<Results: AsyncSequence & Sendable>(_ results: Results)
    where Results.Element == SpeechTranscriber.Result {
        resultsTask = Task { [weak self] in
            do {
                for try await result in results {
                    self?.handle(
                        text: String(result.text.characters),
                        start: result.range.start,
                        end: result.range.end,
                        isFinal: result.isFinal
                    )
                }
            } catch {
                guard let self, !self.isEnding else { return }
                self.onFailure(self, "\(error)")
            }
        }
    }

    private func handle(text: String, start: CMTime, end: CMTime, isFinal: Bool) {
        let startSeconds = start.isNumeric ? timeline.recordingTime(forFed: start.seconds) : phraseEnd
        let endSeconds = end.isNumeric ? timeline.recordingTime(forFed: end.seconds) : startSeconds
        let id: UUID
        if let phraseID {
            id = phraseID
            phraseStart = min(phraseStart, startSeconds)
        } else {
            id = UUID()
            phraseID = id
            phraseStart = startSeconds
        }
        phraseEnd = max(endSeconds, phraseStart)
        onPhrase(MeetingPhrase(id: id, text: text, start: phraseStart, end: phraseEnd, isFinal: isFinal))
        if isFinal { phraseID = nil }
    }

    /// A phrase still volatile at the very end becomes final as last heard.
    private func closeOpenPhrase() {
        guard let phraseID else { return }
        self.phraseID = nil
        onPhrase(MeetingPhrase(id: phraseID, text: "", start: phraseStart, end: phraseEnd, isFinal: true))
    }

    private static func installAssets(for locale: Locale) {
        guard !isInstallingAssets else { return }
        isInstallingAssets = true
        AppLog.log("Meeting: downloading speech model for \(locale.identifier)")
        Task.detached(priority: .utility) {
            do {
                _ = try? await AssetInventory.reserve(locale: locale)
                let module = MeetingAnalyzerEngine.makeModule(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
                AppLog.log("Meeting: speech model installed")
            } catch {
                AppLog.log("Meeting: speech model download failed: \(error)")
            }
            await MainActor.run { MeetingAnalyzerEngine.isInstallingAssets = false }
        }
    }
}

/// Converts mono buffers to the analyzer's format (16 kHz Int16 mono), keeps
/// the fed-audio timeline and feeds the analyzer's input stream.
@available(macOS 26.0, *)
final class MeetingAnalyzerSink: MeetingAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private let resampler: MeetingResampler
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let timeline: MeetingTimeline
    private var isClosed = false

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, timeline: MeetingTimeline) {
        resampler = MeetingResampler(target: format)
        self.continuation = continuation
        self.timeline = timeline
    }

    func append(_ buffer: AVAudioPCMBuffer, start: TimeInterval, contiguous: Bool, voiced: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed, let output = resampler.convert(buffer) else { return }
        timeline.advance(
            frames: output.frameLength,
            sampleRate: output.format.sampleRate,
            recordingStart: start,
            contiguous: contiguous
        )
        continuation.yield(AnalyzerInput(buffer: output))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
    }
}

// MARK: - SFSpeechRecognizer engine (fallback)

/// Routes audio to the current recognition request; swapped on rotation.
final class MeetingLegacySink: MeetingAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lastVoicedUptime: TimeInterval = 0

    func append(_ buffer: AVAudioPCMBuffer, start: TimeInterval, contiguous: Bool, voiced: Bool) {
        lock.lock(); defer { lock.unlock() }
        if voiced { lastVoicedUptime = ProcessInfo.processInfo.systemUptime }
        request?.append(buffer)
    }

    /// Installs `request` (nil stops routing) and returns the previous one.
    @discardableResult
    func swap(_ request: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        let previous = self.request
        self.request = request
        return previous
    }

    /// Seconds since a buffer with speech-level energy arrived.
    var secondsSinceVoice: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastVoicedUptime
    }
}

@MainActor
final class MeetingLegacyEngine: MeetingSpeechEngine {
    let sink: any MeetingAudioSink
    let name = "SFSpeechRecognizer"

    /// Rotate at the first pause after this age, and unconditionally at `forceRotateAge`.
    static let rotateAge: TimeInterval = 50
    static let forceRotateAge: TimeInterval = 57
    /// A pause this long (no voiced audio) closes the current phrase.
    static let phrasePause: TimeInterval = 1.1
    static let maxPhraseWords = 40

    private final class TaskState {
        let number: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        let startedAt: TimeInterval
        var words: [String] = []
        var committed = 0
        var phraseID = UUID()
        var phraseStart: TimeInterval?
        var lastUpdate: TimeInterval
        var endRequestedAt: TimeInterval?
        var producedText = false

        init(number: Int, request: SFSpeechAudioBufferRecognitionRequest, now: TimeInterval) {
            self.number = number
            self.request = request
            startedAt = now
            lastUpdate = now
        }
    }

    private let label: String
    private let legacySink = MeetingLegacySink()
    private let recognizer: SFSpeechRecognizer
    private let clock: MeetingClock
    private let onPhrase: @MainActor (MeetingPhrase) -> Void
    private let onFailure: @MainActor (any MeetingSpeechEngine, String) -> Void
    private var tasks: [Int: TaskState] = [:]
    private var currentNumber = 0
    private var nextNumber = 0
    private var ticker: Task<Void, Never>?
    private var isEnding = false
    private var quickFailures = 0

    init(
        label: String,
        clock: MeetingClock,
        onPhrase: @escaping @MainActor (MeetingPhrase) -> Void,
        onFailure: @escaping @MainActor (any MeetingSpeechEngine, String) -> Void
    ) throws {
        // Live Translation's "Others Speak" setting (nil: the Mac's language).
        let wanted = LiveTranslationSpokenLanguage.transcriberLocale(speakerLabel: label)
        guard let recognizer = wanted.flatMap({ SFSpeechRecognizer(locale: $0) }) ?? SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw MeetingTranscriberError.recognizerUnavailable
        }
        if !recognizer.supportsOnDeviceRecognition {
            AppLog.log("Meeting[\(label)]: on-device recognition unavailable for \(recognizer.locale.identifier)")
        }
        // Results arrive on a background queue, then hop to the main actor.
        recognizer.queue = OperationQueue()
        self.label = label
        self.recognizer = recognizer
        self.clock = clock
        self.onPhrase = onPhrase
        self.onFailure = onFailure
        sink = legacySink
    }

    func begin() async throws {
        startTask()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func finish() async {
        isEnding = true
        ticker?.cancel()
        ticker = nil
        legacySink.swap(nil)
        for state in tasks.values {
            state.request.endAudio()
            state.endRequestedAt = clock.now
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        while !tasks.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        for state in tasks.values.sorted(by: { $0.number < $1.number }) {
            state.task?.cancel()
            commitPhrase(state)
        }
        tasks.removeAll()
    }

    func cancel() async {
        isEnding = true
        ticker?.cancel()
        ticker = nil
        legacySink.swap(nil)
        for state in tasks.values.sorted(by: { $0.number < $1.number }) {
            state.task?.cancel()
            state.request.endAudio()
            commitPhrase(state)
        }
        tasks.removeAll()
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .unspecified
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        return request
    }

    /// Starts a new recognition task and routes audio to it. The previous
    /// request (if any) is returned so the caller can end it after the switch.
    @discardableResult
    private func startTask() -> TaskState? {
        let previous = tasks[currentNumber]
        let request = makeRequest()
        nextNumber += 1
        let number = nextNumber
        let state = TaskState(number: number, request: request, now: clock.now)
        tasks[number] = state
        currentNumber = number
        state.task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(number: number, engine: self))
        legacySink.swap(request)
        return previous
    }

    /// Switches to a fresh task, then lets the old one finish its last words.
    private func rotate(reason: String) {
        guard let previous = startTask() else { return }
        commitIfPaused(previous, force: false)
        previous.request.endAudio()
        previous.endRequestedAt = clock.now
        AppLog.log("Meeting[\(label)]: rotated recognition task (\(reason))")
    }

    nonisolated private static func makeHandler(
        number: Int, engine: MeetingLegacyEngine
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        let box = MeetingWeak(engine)
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error.map { "\($0.localizedDescription) (\(($0 as NSError).code))" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value?.handle(number: number, text: text, isFinal: isFinal, error: message)
                }
            }
        }
    }

    private func handle(number: Int, text: String?, isFinal: Bool, error: String?) {
        guard let state = tasks[number] else { return }
        let now = clock.now
        if let text {
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if words != state.words {
                state.words = words
                state.lastUpdate = now
                state.committed = min(state.committed, words.count)
                if words.count > state.committed {
                    state.producedText = true
                    if state.phraseStart == nil { state.phraseStart = max(0, now - 1) }
                    emitTail(state, isFinal: false)
                }
            }
        }
        guard isFinal || error != nil else { return }

        // The task ended: its tail is final.
        commitPhrase(state)
        tasks[number] = nil
        guard number == currentNumber, !isEnding else { return }

        // The current task ended on its own (silence timeout, error): keep listening.
        let lived = now - state.startedAt
        if let error { AppLog.log("Meeting[\(label)]: recognition task ended: \(error)") }
        if lived < 2, !state.producedText {
            quickFailures += 1
        } else {
            quickFailures = 0
        }
        if quickFailures >= 8 {
            isEnding = true
            ticker?.cancel()
            legacySink.swap(nil)
            onFailure(self, error ?? "recognition keeps ending")
            return
        }
        startTask()
    }

    private func tick() {
        guard !isEnding else { return }
        let now = clock.now
        if let state = tasks[currentNumber] {
            commitIfPaused(state, force: false)
            let age = now - state.startedAt
            let silentFor = legacySink.secondsSinceVoice
            if age >= Self.forceRotateAge {
                rotate(reason: "time limit")
            } else if age >= Self.rotateAge, silentFor >= 0.4 {
                rotate(reason: "pause")
            }
        } else {
            startTask()
        }
        // Old tasks that never delivered their final result.
        for state in tasks.values where state.number != currentNumber {
            if let requested = state.endRequestedAt, now - requested > 4 {
                state.task?.cancel()
                commitPhrase(state)
                tasks[state.number] = nil
            }
        }
    }

    /// Closes the current phrase at a pause or when it grows long.
    private func commitIfPaused(_ state: TaskState, force: Bool) {
        let pending = state.words.count - state.committed
        guard pending > 0 else { return }
        let paused = legacySink.secondsSinceVoice >= Self.phrasePause && clock.now - state.lastUpdate >= 0.5
        if force || paused || pending >= Self.maxPhraseWords {
            commitPhrase(state)
        }
    }

    private func commitPhrase(_ state: TaskState) {
        guard state.words.count > state.committed else { return }
        emitTail(state, isFinal: true)
        state.committed = state.words.count
        state.phraseID = UUID()
        state.phraseStart = nil
    }

    private func emitTail(_ state: TaskState, isFinal: Bool) {
        let tail = state.words[state.committed...].joined(separator: " ")
        let start = state.phraseStart ?? max(0, state.lastUpdate - 1)
        onPhrase(MeetingPhrase(id: state.phraseID, text: tail, start: start, end: max(start, state.lastUpdate), isFinal: isFinal))
    }
}

/// Weak reference that can cross concurrency domains.
final class MeetingWeak<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
