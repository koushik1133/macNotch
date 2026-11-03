import Foundation
import QuartzCore

/// Runs capture and analysis: a source fills the ring buffer, a timer on a
/// high-priority serial queue drains it hop by hop through
/// `AmbientSpectralAnalyzer`, and the newest features land in `mailbox` for
/// the renderers. When analysis falls behind (a stalled queue, a sleeping
/// Mac) it skips to the newest audio, so the light never lags the music.
@MainActor
final class AmbientAudioEngine {
    let mailbox = AmbientFeatureMailbox()
    private(set) var isRunning = false
    private(set) var sourceName: String?
    /// True after a few seconds of digital zeros while running.
    private(set) var isReceivingDigitalSilence = false
    /// Called on the main queue when digital silence starts or stops.
    var onDigitalSilenceChange: ((Bool) -> Void)?
    /// True while the analyzer hears sound (music from any app, whether or
    /// not it reports Now Playing). Turns on after ~0.3 s of continuous
    /// sound, off after the analyzer's silence hold (~1.2 s).
    private(set) var isHearingAudio = false
    /// Called on the main queue when `isHearingAudio` changes (transitions
    /// only, never per hop).
    var onAudibleChange: ((Bool) -> Void)?
    /// A kick in the audio: strength 0...1 and when it was captured (host
    /// time). Called on the analysis queue, at the analyzer's hop rate.
    var onKick: (@Sendable (Float, Double) -> Void)? {
        didSet { pump?.onKick = onKick }
    }
    /// Called on the main queue when the output device changed and capture
    /// should be restarted.
    var onRouteChange: (() -> Void)?

    private var source: AmbientAudioSource?
    private var pump: AmbientAnalysisPump?
    private var generation = 0
    /// When the running capture started (for the stalled-IO check).
    private(set) var startedAt: Double = 0
    /// A process-tap start timed out and is still inside Core Audio. New tap
    /// starts fail fast (`halBusy`) until it returns, instead of queueing up
    /// behind it.
    private(set) var isHALWedged = false
    /// Called on the main queue when an abandoned start finally returned
    /// (Core Audio is responsive again).
    var onHALRecovered: (() -> Void)?
    /// A start that takes longer than this is abandoned.
    nonisolated static let startTimeout: Double = 4

    enum Backend: String, Sendable {
        case processTap
        case screenCapture
    }

    /// Starts `backend` (stopping whatever ran). Throws when capture fails,
    /// and `CancellationError` when a later `start` / `stop` superseded it.
    func start(_ backend: Backend) async throws {
        stop()
        generation += 1
        let myGeneration = generation
        // A fresh ring per start: a previous source that is still winding
        // down (SCStream stops asynchronously) can never become a second
        // producer on the single-producer ring the new source writes.
        let ring = AmbientSampleRing(capacity: 1 << 16)
        let newSource: AmbientAudioSource
        switch backend {
        case .processTap:
            let tap = AmbientProcessTapSource(ring: ring)
            tap.onRouteChange = { [weak self] in
                Task { @MainActor in
                    // Not for a tap that is already winding down.
                    guard let self, self.generation == myGeneration else { return }
                    self.onRouteChange?()
                }
            }
            newSource = tap
        case .screenCapture:
            newSource = AmbientScreenCaptureSource(ring: ring)
        }
        let sampleRate: Double
        do {
            sampleRate = try await startWithTimeout(newSource)
        } catch {
            // Never a HAL call on the main thread: the source tears down on
            // the HAL queue (behind its own start, which already cleaned up).
            Self.tearDown(newSource)
            throw myGeneration == generation ? error : CancellationError()
        }
        guard myGeneration == generation else {
            Self.tearDown(newSource)
            throw CancellationError()
        }
        startedAt = CACurrentMediaTime()
        source = newSource
        sourceName = newSource.name
        let pump = AmbientAnalysisPump(ring: ring, mailbox: mailbox, sampleRate: sampleRate)
        pump.onDigitalSilenceChange = { [weak self] silent in
            Task { @MainActor in
                guard let self, self.generation == myGeneration else { return }
                self.isReceivingDigitalSilence = silent
                self.onDigitalSilenceChange?(silent)
            }
        }
        pump.onAudibleChange = { [weak self] audible in
            Task { @MainActor in
                guard let self, self.generation == myGeneration, self.isHearingAudio != audible else { return }
                self.isHearingAudio = audible
                self.onAudibleChange?(audible)
            }
        }
        pump.onKick = onKick
        pump.start()
        self.pump = pump
        isRunning = true
        AppLog.log("AmbientLight: capture started (\(newSource.name), \(Int(sampleRate)) Hz)")
    }

    /// Seconds since the analyzer last got audio (any, silence included)
    /// while running; grows when the IO stopped (a dead tap after
    /// coreaudiod restarted, a device that vanished). nil when not running.
    var secondsSinceAudio: Double? {
        guard isRunning else { return nil }
        let now = CACurrentMediaTime()
        let last = max(mailbox.load().time, startedAt)
        return now - last
    }

    /// Runs `source.start()` off the main actor (the process tap on the
    /// serial HAL queue) and gives up after `startTimeout`. An abandoned
    /// start tears down whatever it created when it finally returns.
    private func startWithTimeout(_ source: AmbientAudioSource) async throws -> Double {
        let isTap = source is AmbientProcessTapSource
        if isTap, isHALWedged { throw AmbientCaptureError.halBusy }
        let race = AmbientStartRace()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            let finish: @Sendable (Result<Double, Error>) -> Void = { [weak self] result in
                if race.claim() {
                    continuation.resume(with: result)
                    return
                }
                // Late: the caller already got `timedOut`.
                if case .success = result { Self.tearDown(source) }
                AppLog.log("AmbientLight: abandoned capture start returned \(Self.describe(result)); cleaned up")
                if isTap {
                    Task { @MainActor in
                        self?.isHALWedged = false
                        self?.onHALRecovered?()
                    }
                }
            }
            if let tap = source as? AmbientProcessTapSource {
                Self.halQueue.async {
                    do { finish(.success(try tap.startBlocking())) } catch { finish(.failure(error)) }
                }
            } else {
                Task.detached {
                    do { finish(.success(try await source.start())) } catch { finish(.failure(error)) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
                guard race.claim() else { return }
                continuation.resume(throwing: AmbientCaptureError.timedOut)
                if isTap { Task { @MainActor in self?.isHALWedged = true } }
            }
        }
    }

    nonisolated private static func describe(_ result: Result<Double, Error>) -> String {
        switch result {
        case .success: "late"
        case .failure(let error): "an error (\(error.localizedDescription))"
        }
    }

    func stop() {
        generation += 1
        pump?.stop()
        pump = nil
        if let source {
            Self.tearDown(source)
            AppLog.log("AmbientLight: capture stopped")
        }
        source = nil
        sourceName = nil
        isRunning = false
        isReceivingDigitalSilence = false
        isHearingAudio = false
        mailbox.store(.idle)
    }
}

extension AmbientAudioEngine {
    /// Serial: every process-tap HAL call (create, start, stop, destroy)
    /// runs here in order, never on the main thread.
    nonisolated static let halQueue = DispatchQueue(label: "SparkV.AmbientLight.hal", qos: .userInitiated)

    /// Stops a source off the main thread: destroying the aggregate device
    /// and the tap are synchronous HAL calls that can stall for a long time
    /// while coreaudiod is busy (a device switch, AirPods connecting). Each
    /// start uses its own ring and source, so a source still winding down
    /// can't touch the next one.
    nonisolated static func tearDown(_ source: AmbientAudioSource) {
        halQueue.async { source.stop() }
    }
}

/// First caller wins: the start's completion or its timeout.
final class AmbientStartRace: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// The analysis loop on its own queue.
final class AmbientAnalysisPump: @unchecked Sendable {
    var onDigitalSilenceChange: (@Sendable (Bool) -> Void)?
    var onKick: (@Sendable (Float, Double) -> Void)?
    private var lastKick: UInt64 = 0
    var onAudibleChange: (@Sendable (Bool) -> Void)?
    /// Continuous sound needed before the input counts as audible.
    static let audibleAfter: Double = 0.3

    private let ring: AmbientSampleRing
    private let mailbox: AmbientFeatureMailbox
    private let analyzer: AmbientSpectralAnalyzer
    private let queue = DispatchQueue(label: "SparkV.AmbientLight.analysis", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let hop: UnsafeMutablePointer<Float>
    private let hopSize: Int
    private let sampleRate: Double
    private var lastDigitalSilence = false
    private var audible = false

    init(ring: AmbientSampleRing, mailbox: AmbientFeatureMailbox, sampleRate: Double) {
        self.ring = ring
        self.mailbox = mailbox
        self.sampleRate = sampleRate
        // ~10.7 ms hops at 48 kHz, ~11.6 ms at 44.1 kHz; 1024 above 96 kHz.
        let hopSize = sampleRate > 90_000 ? 1024 : 512
        let fftSize = sampleRate > 90_000 ? 4096 : 2048
        self.hopSize = hopSize
        analyzer = AmbientSpectralAnalyzer(sampleRate: sampleRate, fftSize: fftSize, hopSize: hopSize)
        hop = .allocate(capacity: hopSize)
        hop.initialize(repeating: 0, count: hopSize)
    }

    deinit {
        hop.deallocate()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(hopSize) / sampleRate
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func drain() {
        // Never more than ~60 ms behind: older audio is skipped.
        ring.skip(keeping: hopSize * 6)
        var latest: AmbientAudioFeatures?
        while ring.available >= hopSize, ring.read(into: hop, count: hopSize) {
            // The hop ended `available` samples ago.
            let delay = Double(ring.available) / sampleRate
            let time = CACurrentMediaTime() - delay
            latest = analyzer.process(hop: UnsafeBufferPointer(start: hop, count: hopSize), at: time)
            if analyzer.kickCount != lastKick {
                let first = lastKick == 0
                lastKick = analyzer.kickCount
                if !first, let latest, !latest.isSilent { onKick?(analyzer.kickStrength, analyzer.kickTime) }
            }
        }
        guard let latest else { return }
        mailbox.store(latest)
        if latest.isDigitalSilence != lastDigitalSilence {
            lastDigitalSilence = latest.isDigitalSilence
            onDigitalSilenceChange?(latest.isDigitalSilence)
        }
        let hearing = audible ? !latest.isSilent : analyzer.soundTime >= Self.audibleAfter
        if hearing != audible {
            audible = hearing
            onAudibleChange?(hearing)
        }
    }
}
