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
    /// Called on the main queue when the output device changed and capture
    /// should be restarted.
    var onRouteChange: (() -> Void)?

    private var source: AmbientAudioSource?
    private var pump: AmbientAnalysisPump?
    private var generation = 0

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
                Task { @MainActor in self?.onRouteChange?() }
            }
            newSource = tap
        case .screenCapture:
            newSource = AmbientScreenCaptureSource(ring: ring)
        }
        let sampleRate: Double
        do {
            sampleRate = try await newSource.start()
        } catch {
            newSource.stop()
            throw myGeneration == generation ? error : CancellationError()
        }
        guard myGeneration == generation else {
            newSource.stop()
            throw CancellationError()
        }
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
        pump.start()
        self.pump = pump
        isRunning = true
        AppLog.log("AmbientLight: capture started (\(newSource.name), \(Int(sampleRate)) Hz)")
    }

    func stop() {
        generation += 1
        pump?.stop()
        pump = nil
        source?.stop()
        if source != nil { AppLog.log("AmbientLight: capture stopped") }
        source = nil
        sourceName = nil
        isRunning = false
        isReceivingDigitalSilence = false
        mailbox.store(.idle)
    }
}

/// The analysis loop on its own queue.
final class AmbientAnalysisPump: @unchecked Sendable {
    var onDigitalSilenceChange: (@Sendable (Bool) -> Void)?

    private let ring: AmbientSampleRing
    private let mailbox: AmbientFeatureMailbox
    private let analyzer: AmbientSpectralAnalyzer
    private let queue = DispatchQueue(label: "SparkV.AmbientLight.analysis", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let hop: UnsafeMutablePointer<Float>
    private let hopSize: Int
    private let sampleRate: Double
    private var lastDigitalSilence = false

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
        }
        guard let latest else { return }
        mailbox.store(latest)
        if latest.isDigitalSilence != lastDigitalSilence {
            lastDigitalSilence = latest.isDigitalSilence
            onDigitalSilenceChange?(latest.isDigitalSilence)
        }
    }
}
