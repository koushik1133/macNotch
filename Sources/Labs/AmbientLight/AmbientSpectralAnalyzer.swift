import Accelerate
import Foundation

/// The music analysis behind Ambient Light: an FFT every hop (2048-point
/// window, 512-sample hop, about 94 analyses per second at 48 kHz) that
/// yields bass / mid / treble levels, an onset strength, beats (spectral
/// flux against an adaptive threshold) and a tempo estimate
/// (autocorrelation of the onset envelope).
///
/// Not thread-safe: one instance is driven from one serial queue. It never
/// allocates after `init`, so it is cheap to run continuously (about 15 µs
/// per hop on Apple silicon, see Tests/).
final class AmbientSpectralAnalyzer {
    struct Tuning: Sendable {
        /// Band edges in Hz.
        var bassRange: ClosedRange<Double> = 25...160
        var midRange: ClosedRange<Double> = 160...2_500
        var trebleRange: ClosedRange<Double> = 2_500...12_000
        /// Frequencies that count as "kick / bass" for beat detection.
        var beatLowRange: ClosedRange<Double> = 30...220
        /// Envelope time constants in seconds (attack, release), one-pole
        /// exponential. A kick reaches ~95 % in three attack constants
        /// (~60 ms for bass) and fades over ~3 release constants, so hits
        /// read as distinct swells instead of 10 ms spikes, without flicker.
        var bassEnvelope: (Double, Double) = (0.022, 0.26)
        var midEnvelope: (Double, Double) = (0.03, 0.30)
        var trebleEnvelope: (Double, Double) = (0.015, 0.20)
        var levelEnvelope: (Double, Double) = (0.04, 0.40)
        /// Dynamic range mapped to 0...1 under the running peak, in dB.
        var dynamicRange: Float = 34
        /// How fast the automatic gain's peak falls, dB per second, after it
        /// has been held for `peakHold` seconds. A quiet song (or a lower
        /// app volume) is brought back to full range within a few seconds;
        /// the hold keeps the gain from pumping up between bars.
        var peakDecayPerSecond: Float = 4
        var peakHold: Double = 1.5
        /// Adaptive threshold: mean + k * standard deviation of the recent
        /// onset values, over `thresholdWindow` seconds.
        var thresholdK: Float = 1.25
        var thresholdWindow: Double = 1.0
        /// Shortest gap between two beats, in seconds (and as a fraction of
        /// the beat period once the tempo is known).
        var minBeatGap: Double = 0.2
        var minBeatGapOfPeriod: Double = 0.55
        /// An onset this many times its threshold counts as strong.
        var strongOnsetRatio: Float = 1.8
        /// Tempo search range and the prior's center.
        var bpmRange: ClosedRange<Double> = 70...180
        var bpmPriorCenter: Double = 120
        /// Seconds of onset envelope used for the tempo.
        var tempoWindow: Double = 6
        /// Below this RMS (dBFS) the input counts as silence.
        var silenceFloorDB: Float = -66
        var silenceHold: Double = 1.2
        var digitalSilenceHold: Double = 3
    }

    let sampleRate: Double
    let fftSize: Int
    let hopSize: Int
    let tuning: Tuning
    /// Analyses per second.
    var frameRate: Double { sampleRate / Double(hopSize) }

    // FFT state.
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringWrite = 0
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var logMag: [Float]
    private var previousLogMag: [Float]

    // Band bin ranges.
    private let bassBins: Range<Int>
    private let midBins: Range<Int>
    private let trebleBins: Range<Int>
    private let beatBins: Range<Int>

    // Gain and envelopes.
    private var peakDB: (bass: Float, mid: Float, treble: Float, level: Float) = (-60, -60, -60, -60)
    private var envelope: (bass: Float, mid: Float, treble: Float, level: Float) = (0, 0, 0, 0)
    private let coefficients: (bass: (Float, Float), mid: (Float, Float), treble: (Float, Float), level: (Float, Float))

    // Onset detection.
    private var onsetHistory: [Float]
    private var onsetHistoryIndex = 0
    private var onsetHistoryFilled = 0
    private var lowFluxScale: Float = 1e-3
    // Kick detector for Music Haptics: kick-band flux only, its own
    // adaptive threshold (last ~1 s) and peak picking, so every kick
    // counts even when the full-band beat tracker merges or skips one.
    private var kickHistory = [Float](repeating: 0, count: 90)
    private var kickHistoryIndex = 0
    private var kickPrevious: Float = 0
    private var kickPreviousPrevious: Float = 0
    private var kickPreviousThreshold: Float = 1
    private var lastKickTime: Double = 0
    private(set) var kickCount: UInt64 = 0
    private(set) var kickStrength: Float = 0
    private(set) var kickTime: Double = 0
    private var fullFluxScale: Float = 1e-3
    private var previousOnset: Float = 0
    private var previousPreviousOnset: Float = 0
    private var previousThreshold: Float = 0
    private var lastBeatTime: Double = -10
    private var beatCount: UInt64 = 0

    // Tempo.
    private var tempoEnvelope: [Float]
    private var tempoWriteIndex = 0
    private var tempoFilled = 0
    private var tempoScratch: [Float]
    private var hopsSinceTempo = 0
    private var bpm: Float = 0
    private var tempoConfidence: Float = 0
    private var pendingBPM: Float = 0

    // Silence.
    private var quietTime: Double = 0
    private var zeroTime: Double = 0
    private var peakAge: (bass: Double, mid: Double, treble: Double, level: Double) = (0, 0, 0, 0)
    /// Seconds the input has stayed above the silence floor (dips shorter
    /// than `soundGapBridge` don't reset it). The pump uses it to tell music
    /// from a single click or notification ding.
    private(set) var soundTime: Double = 0
    private let soundGapBridge: Double = 0.25

    init(sampleRate: Double, fftSize: Int = 2048, hopSize: Int = 512, tuning: Tuning = Tuning()) {
        precondition(fftSize.nonzeroBitCount == 1 && hopSize <= fftSize)
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.tuning = tuning
        log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        let half = fftSize / 2
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
        power = [Float](repeating: 0, count: half)
        logMag = [Float](repeating: 0, count: half)
        previousLogMag = [Float](repeating: 0, count: half)

        let binHz = sampleRate / Double(fftSize)
        func bins(_ range: ClosedRange<Double>) -> Range<Int> {
            let low = max(1, Int((range.lowerBound / binHz).rounded(.down)))
            let high = min(half - 1, max(low + 1, Int((range.upperBound / binHz).rounded(.up))))
            return low..<high
        }
        bassBins = bins(tuning.bassRange)
        midBins = bins(tuning.midRange)
        trebleBins = bins(tuning.trebleRange)
        beatBins = bins(tuning.beatLowRange)

        let hopSeconds = Double(hopSize) / sampleRate
        func coefficient(_ tau: Double) -> Float { Float(exp(-hopSeconds / max(tau, 1e-4))) }
        func pair(_ times: (Double, Double)) -> (Float, Float) { (coefficient(times.0), coefficient(times.1)) }
        coefficients = (pair(tuning.bassEnvelope), pair(tuning.midEnvelope), pair(tuning.trebleEnvelope), pair(tuning.levelEnvelope))

        let rate = sampleRate / Double(hopSize)
        onsetHistory = [Float](repeating: 0, count: max(8, Int(tuning.thresholdWindow * rate)))
        let tempoCount = max(64, Int(tuning.tempoWindow * rate))
        tempoEnvelope = [Float](repeating: 0, count: tempoCount)
        tempoScratch = [Float](repeating: 0, count: tempoCount)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Forgets everything (new track, capture restarted).
    func reset() {
        for i in ring.indices { ring[i] = 0 }
        for i in previousLogMag.indices { previousLogMag[i] = 0 }
        for i in onsetHistory.indices { onsetHistory[i] = 0 }
        for i in tempoEnvelope.indices { tempoEnvelope[i] = 0 }
        ringWrite = 0
        onsetHistoryIndex = 0; onsetHistoryFilled = 0
        tempoWriteIndex = 0; tempoFilled = 0; hopsSinceTempo = 0
        peakDB = (-60, -60, -60, -60)
        envelope = (0, 0, 0, 0)
        previousOnset = 0; previousPreviousOnset = 0; previousThreshold = 0
        lowFluxScale = 1e-3; fullFluxScale = 1e-3
        bpm = 0; tempoConfidence = 0; pendingBPM = 0
        quietTime = 0; zeroTime = 0; soundTime = 0
        peakAge = (0, 0, 0, 0)
        lastBeatTime = -10
    }

    /// Feeds exactly `hopSize` mono samples ending at `time` (seconds, any
    /// monotonic clock) and returns the features after this hop.
    func process(hop samples: UnsafeBufferPointer<Float>, at time: Double) -> AmbientAudioFeatures {
        let count = min(samples.count, hopSize)
        let hopSeconds = Double(hopSize) / sampleRate

        // Silence bookkeeping on the raw hop.
        var meanSquare: Float = 0
        var maxMagnitude: Float = 0
        if let base = samples.baseAddress, count > 0 {
            vDSP_measqv(base, 1, &meanSquare, vDSP_Length(count))
            vDSP_maxmgv(base, 1, &maxMagnitude, vDSP_Length(count))
        }
        let rmsDB = 10 * log10(meanSquare + 1e-20)
        quietTime = rmsDB < tuning.silenceFloorDB ? quietTime + hopSeconds : 0
        zeroTime = maxMagnitude == 0 ? zeroTime + hopSeconds : 0
        if quietTime == 0 { soundTime += hopSeconds } else if quietTime > soundGapBridge { soundTime = 0 }

        // Slide the hop into the circular window buffer.
        if let base = samples.baseAddress {
            var remaining = count
            var source = base
            while remaining > 0 {
                let chunk = min(remaining, fftSize - ringWrite)
                ring.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: ringWrite).update(from: source, count: chunk)
                }
                ringWrite = (ringWrite + chunk) % fftSize
                source = source.advanced(by: chunk)
                remaining -= chunk
            }
        }

        spectrum()

        // Band energies → dB → automatic gain → envelopes.
        let bassDB = bandDB(bassBins)
        let midDB = bandDB(midBins)
        let trebleDB = bandDB(trebleBins)
        let levelDB = bandDB(bassBins.lowerBound..<trebleBins.upperBound)
        let decay = tuning.peakDecayPerSecond * Float(hopSeconds)
        let gate: Float = rmsDB < tuning.silenceFloorDB ? 0 : 1
        // The automatic gain doesn't adapt to silence (a pause would pull the
        // peak down and make the next bar blinding).
        if gate > 0 {
            peakDB.bass = trackPeak(peakDB.bass, bassDB, age: &peakAge.bass, decay: decay, dt: hopSeconds)
            peakDB.mid = trackPeak(peakDB.mid, midDB, age: &peakAge.mid, decay: decay, dt: hopSeconds)
            peakDB.treble = trackPeak(peakDB.treble, trebleDB, age: &peakAge.treble, decay: decay, dt: hopSeconds)
            peakDB.level = trackPeak(peakDB.level, levelDB, age: &peakAge.level, decay: decay, dt: hopSeconds)
        }
        let silent = quietTime >= tuning.silenceHold
        envelope.bass = follow(envelope.bass, gate * normalize(bassDB, peak: peakDB.bass), coefficients.bass)
        envelope.mid = follow(envelope.mid, gate * normalize(midDB, peak: peakDB.mid), coefficients.mid)
        envelope.treble = follow(envelope.treble, gate * normalize(trebleDB, peak: peakDB.treble), coefficients.treble)
        envelope.level = follow(envelope.level, gate * normalize(levelDB, peak: peakDB.level), coefficients.level)

        // Onset strength: half-wave rectified spectral flux of the log
        // spectrum, the low (kick) band weighted up, each part normalized by
        // its own slowly adapting scale so mixes with little bass still work.
        var lowFlux: Float = 0
        var fullFlux: Float = 0
        // SuperFlux-style: compare against the maximum of the previous
        // spectrum over neighboring bins, so gliding tones (sweeps, vibrato,
        // pitch bends) don't read as onsets while drum hits still do.
        let upper = trebleBins.upperBound
        for bin in 1..<upper {
            let radius = bin < beatBins.upperBound ? 1 : 2
            var reference = previousLogMag[bin]
            for neighbor in max(0, bin - radius)...min(upper, bin + radius) where previousLogMag[neighbor] > reference {
                reference = previousLogMag[neighbor]
            }
            let rise = logMag[bin] - reference
            if rise > 0 {
                fullFlux += rise
                if beatBins.contains(bin) { lowFlux += rise }
            }
        }
        swap(&logMag, &previousLogMag)
        lowFlux /= Float(max(1, beatBins.count))
        fullFlux /= Float(max(1, trebleBins.upperBound - 1))
        lowFluxScale = max(lowFluxScale * 0.9985, lowFlux, 1e-4)
        fullFluxScale = max(fullFluxScale * 0.9985, fullFlux, 1e-4)
        var onset = gate * (0.65 * lowFlux / lowFluxScale + 0.35 * fullFlux / fullFluxScale)
        detectKick(gate * lowFlux / lowFluxScale, at: time)
        if !onset.isFinite { onset = 0 }

        // Adaptive threshold over the last second.
        let (mean, deviation) = historyStatistics()
        let threshold = max(0.12, mean + tuning.thresholdK * deviation)
        onsetHistory[onsetHistoryIndex] = onset
        onsetHistoryIndex = (onsetHistoryIndex + 1) % onsetHistory.count
        onsetHistoryFilled = min(onsetHistory.count, onsetHistoryFilled + 1)

        // Peak picking with one hop of delay: the previous value is a beat
        // when it was a local maximum above its threshold.
        let peakTime = time - hopSeconds
        let period = bpm > 0 ? 60 / Double(bpm) : 0
        // Weak onsets (hi-hats, off-beat ghost notes) must also respect a gap
        // tied to the tempo; strong ones (kick, snare) only the hard minimum,
        // so a tempo estimate an octave low can't hide every other beat.
        let strong = previousOnset > previousThreshold * tuning.strongOnsetRatio
        let tempoGap = tempoConfidence > 0.25 && !strong ? period * tuning.minBeatGapOfPeriod : 0
        let gap = max(tuning.minBeatGap, tempoGap)
        if onsetHistoryFilled > onsetHistory.count / 4,
           previousOnset > previousThreshold,
           previousOnset >= onset,
           previousOnset > previousPreviousOnset,
           peakTime - lastBeatTime >= gap {
            lastBeatTime = peakTime
            beatCount &+= 1
        }
        previousPreviousOnset = previousOnset
        previousOnset = onset
        previousThreshold = threshold

        // Tempo from the onset envelope.
        tempoEnvelope[tempoWriteIndex] = onset
        tempoWriteIndex = (tempoWriteIndex + 1) % tempoEnvelope.count
        tempoFilled = min(tempoEnvelope.count, tempoFilled + 1)
        hopsSinceTempo += 1
        if hopsSinceTempo >= 24, tempoFilled >= tempoEnvelope.count / 2 {
            hopsSinceTempo = 0
            estimateTempo()
        }
        if silent {
            tempoConfidence *= 0.98
        }

        var features = AmbientAudioFeatures()
        features.bass = envelope.bass
        features.mid = envelope.mid
        features.treble = envelope.treble
        features.level = envelope.level
        features.onset = min(1, onset / max(threshold * 2, 0.25))
        features.beatCount = beatCount
        features.lastBeatTime = lastBeatTime
        features.bpm = bpm
        features.tempoConfidence = tempoConfidence
        features.isSilent = silent
        features.isDigitalSilence = zeroTime >= tuning.digitalSilenceHold
        features.time = time
        return features
    }

    private func detectKick(_ value: Float, at time: Double) {
        var sum: Float = 0, squares: Float = 0
        for v in kickHistory { sum += v; squares += v * v }
        let n = Float(kickHistory.count)
        let mean = sum / n
        let deviation = max(0, squares / n - mean * mean).squareRoot()
        let threshold = max(0.2, mean + 1.1 * deviation)
        kickHistory[kickHistoryIndex] = value
        kickHistoryIndex = (kickHistoryIndex + 1) % kickHistory.count
        // One hop of delay: the previous hop is a kick when it peaked above
        // its threshold.
        let peakTime = time - Double(hopSize) / sampleRate
        if kickPrevious > kickPreviousThreshold, kickPrevious >= value, kickPrevious > kickPreviousPrevious,
           peakTime - lastKickTime >= 0.15 {
            lastKickTime = peakTime
            kickTime = peakTime
            kickStrength = min(1, (kickPrevious - kickPreviousThreshold) / max(kickPreviousThreshold, 0.2))
            kickCount &+= 1
        }
        kickPreviousPrevious = kickPrevious
        kickPrevious = value
        kickPreviousThreshold = threshold
    }

    // MARK: Steps

    /// Windowed FFT of the circular buffer into `power` and `logMag`.
    private func spectrum() {
        // Unroll the circular buffer (oldest sample first) while windowing.
        let tail = fftSize - ringWrite
        ring.withUnsafeBufferPointer { src in
            window.withUnsafeBufferPointer { win in
                windowed.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmul(src.baseAddress! + ringWrite, 1, win.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(tail))
                    if ringWrite > 0 {
                        vDSP_vmul(src.baseAddress!, 1, win.baseAddress! + tail, 1, dst.baseAddress! + tail, 1, vDSP_Length(ringWrite))
                    }
                }
            }
        }
        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                im.baseAddress![0] = 0 // Nyquist packed into DC's imaginary part
                power.withUnsafeMutableBufferPointer { out in
                    vDSP_zvmags(&split, 1, out.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        // zrip returns 2x the DFT; scale power to amplitude^2 of a full-scale sine ≈ 1.
        var scale = Float(1) / Float(fftSize * fftSize)
        vDSP_vsmul(power, 1, &scale, &power, 1, vDSP_Length(half))
        // log(1 + c * magnitude): compresses loudness, keeps quiet partials.
        for bin in 0..<half {
            logMag[bin] = log1pf(1_000 * sqrtf(power[bin]))
        }
    }

    private func bandDB(_ bins: Range<Int>) -> Float {
        var sum: Float = 0
        power.withUnsafeBufferPointer { p in
            vDSP_sve(p.baseAddress! + bins.lowerBound, 1, &sum, vDSP_Length(bins.count))
        }
        return 10 * log10(sum + 1e-14)
    }

    /// Peak follower with hold: rises at once, holds, then falls linearly in dB.
    private func trackPeak(_ peak: Float, _ db: Float, age: inout Double, decay: Float, dt: Double) -> Float {
        if db >= peak {
            age = 0
            return db
        }
        age += dt
        let falling = age > tuning.peakHold ? peak - decay : peak
        return max(db, falling, -70)
    }

    private func normalize(_ db: Float, peak: Float) -> Float {
        let value = (db - (peak - tuning.dynamicRange)) / tuning.dynamicRange
        let clamped = min(1, max(0, value))
        return clamped * clamped
    }

    private func follow(_ current: Float, _ target: Float, _ coefficients: (Float, Float)) -> Float {
        let c = target > current ? coefficients.0 : coefficients.1
        return target + (current - target) * c
    }

    private func historyStatistics() -> (Float, Float) {
        let n = onsetHistoryFilled
        guard n > 1 else { return (0, 0) }
        var mean: Float = 0
        var deviation: Float = 0
        onsetHistory.withUnsafeBufferPointer { h in
            vDSP_normalize(h.baseAddress!, 1, nil, 1, &mean, &deviation, vDSP_Length(n))
        }
        return (mean, deviation.isFinite ? deviation : 0)
    }

    /// Autocorrelation of the mean-removed onset envelope over the tempo
    /// range, weighted by a log-normal prior around 120 BPM and helped by
    /// the double-period lag, then parabolic interpolation of the peak.
    private func estimateTempo() {
        let n = tempoFilled
        let rate = frameRate
        // Oldest first into the scratch buffer.
        let start = tempoFilled < tempoEnvelope.count ? 0 : tempoWriteIndex
        for i in 0..<n {
            tempoScratch[i] = tempoEnvelope[(start + i) % tempoEnvelope.count]
        }
        var mean: Float = 0
        tempoScratch.withUnsafeMutableBufferPointer { s in
            vDSP_meanv(s.baseAddress!, 1, &mean, vDSP_Length(n))
            var negative = -mean
            vDSP_vsadd(s.baseAddress!, 1, &negative, s.baseAddress!, 1, vDSP_Length(n))
        }
        func autocorrelation(_ lag: Int) -> Float {
            guard lag > 0, lag < n else { return 0 }
            var dot: Float = 0
            tempoScratch.withUnsafeBufferPointer { s in
                vDSP_dotpr(s.baseAddress!, 1, s.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
            }
            return dot / Float(n - lag)
        }
        var energy: Float = 0
        tempoScratch.withUnsafeBufferPointer { s in
            vDSP_dotpr(s.baseAddress!, 1, s.baseAddress!, 1, &energy, vDSP_Length(n))
        }
        energy /= Float(n)
        guard energy > 1e-6 else { return }

        let minLag = max(2, Int((60 / tuning.bpmRange.upperBound * rate).rounded(.down)))
        let maxLag = min(n / 2, Int((60 / tuning.bpmRange.lowerBound * rate).rounded(.up)))
        guard maxLag > minLag + 2 else { return }
        var bestLag = 0
        var bestScore: Float = -.infinity
        var bestRaw: Float = 0
        var neighbor: (Float, Float, Float) = (0, 0, 0)
        var lastScore: Float = 0
        for lag in minLag...maxLag {
            let raw = autocorrelation(lag)
            let harmonic = 0.5 * autocorrelation(2 * lag) + 0.25 * autocorrelation(lag / 2)
            let bpmAtLag = 60 * rate / Double(lag)
            let octaves = log2(bpmAtLag / tuning.bpmPriorCenter)
            let prior = Float(exp(-0.5 * (octaves / 0.9) * (octaves / 0.9)))
            let score = (raw + harmonic) * (0.55 + 0.45 * prior)
            if score > bestScore {
                bestScore = score
                bestLag = lag
                bestRaw = raw
                neighbor = (lastScore, score, 0)
            } else if lag == bestLag + 1 {
                neighbor.2 = score
            }
            lastScore = score
        }
        guard bestLag > 0, bestScore > 0 else { return }
        // Parabolic interpolation around the peak.
        var refined = Double(bestLag)
        let denominator = neighbor.0 - 2 * neighbor.1 + neighbor.2
        if bestLag > minLag, bestLag < maxLag, abs(denominator) > 1e-9 {
            refined += Double(0.5 * (neighbor.0 - neighbor.2) / denominator)
        }
        let candidate = Float(60 * rate / refined)
        let confidence = min(1, max(0, bestRaw / energy))

        if bpm == 0 || abs(candidate - bpm) / bpm < 0.04 {
            bpm = bpm == 0 ? candidate : bpm * 0.7 + candidate * 0.3
            tempoConfidence = tempoConfidence * 0.6 + confidence * 0.4
            pendingBPM = 0
        } else if pendingBPM > 0, abs(candidate - pendingBPM) / pendingBPM < 0.04 {
            // Two estimates in a row agree on a new tempo: switch.
            bpm = candidate
            tempoConfidence = confidence * 0.7
            pendingBPM = 0
        } else {
            pendingBPM = candidate
            tempoConfidence *= 0.9
        }
    }
}
