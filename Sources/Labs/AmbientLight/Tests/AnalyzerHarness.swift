import Foundation
import QuartzCore

// Offline checks for AmbientSpectralAnalyzer on synthesized audio (no
// capture, no window). Run with Tests/run-tests.sh.

struct Signal {
    var samples: [Float]
    var beats: [Double]      // ground-truth quarter-note times
    var bpm: Double
    var name: String
}

/// Deterministic noise.
struct LCG {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    }
}

enum Synth {
    static let sr = 48_000.0

    /// Kick: pitch sweep 150 → 45 Hz with an exponential decay.
    static func kick(_ out: inout [Float], at t: Double, gain: Float) {
        let start = Int(t * sr)
        var phase = 0.0
        for i in 0..<Int(0.35 * sr) where start + i < out.count {
            let time = Double(i) / sr
            let freq = 45 + 105 * exp(-time * 28)
            phase += 2 * .pi * freq / sr
            out[start + i] += gain * Float(sin(phase) * exp(-time * 9))
        }
    }

    static func snare(_ out: inout [Float], at t: Double, gain: Float, rng: inout LCG) {
        let start = Int(t * sr)
        for i in 0..<Int(0.2 * sr) where start + i < out.count {
            let time = Double(i) / sr
            let env = Float(exp(-time * 22))
            let body = Float(sin(2 * .pi * 190 * time)) * 0.5
            out[start + i] += gain * env * (rng.next() * 0.8 + body)
        }
    }

    static func hat(_ out: inout [Float], at t: Double, gain: Float, rng: inout LCG) {
        let start = Int(t * sr)
        var previous: Float = 0
        for i in 0..<Int(0.05 * sr) where start + i < out.count {
            let time = Double(i) / sr
            let n = rng.next()
            let high = n - previous // crude high-pass
            previous = n
            out[start + i] += gain * Float(exp(-time * 90)) * high
        }
    }

    /// `pattern`: "four" (kick every beat) or "rock" (kick 1/3, snare 2/4).
    static func drumLoop(bpm: Double, seconds: Double, pattern: String, gain: Float = 0.5,
                         pad: Bool = true, hats: Bool = true, swingNoise: Double = 0) -> Signal {
        var out = [Float](repeating: 0, count: Int(seconds * sr))
        var rng = LCG(state: 42)
        let period = 60 / bpm
        var beats: [Double] = []
        var beat = 0
        var t = 0.05
        while t < seconds - 0.4 {
            let jitter = swingNoise > 0 ? Double(rng.next()) * swingNoise : 0
            let at = t + jitter
            beats.append(at)
            switch pattern {
            case "rock":
                if beat % 2 == 0 { kick(&out, at: at, gain: gain) } else { snare(&out, at: at, gain: gain * 0.7, rng: &rng) }
            default:
                kick(&out, at: at, gain: gain)
                if beat % 2 == 1 { snare(&out, at: at, gain: gain * 0.45, rng: &rng) }
            }
            if hats {
                hat(&out, at: at, gain: gain * 0.25, rng: &rng)
                hat(&out, at: at + period / 2, gain: gain * 0.2, rng: &rng)
            }
            beat += 1
            t += period
        }
        if pad {
            // Sustained bass and chord so the spectrum is never empty.
            for i in out.indices {
                let time = Double(i) / sr
                let chord = sin(2 * .pi * 220 * time) + 0.8 * sin(2 * .pi * 277.2 * time) + 0.7 * sin(2 * .pi * 329.6 * time)
                out[i] += gain * Float(0.05 * sin(2 * .pi * 55 * time) + 0.03 * chord)
            }
        }
        return Signal(samples: out, beats: beats, bpm: bpm, name: "\(pattern) \(Int(bpm)) BPM")
    }

    static func sweep(seconds: Double, gain: Float = 0.3) -> Signal {
        var out = [Float](repeating: 0, count: Int(seconds * sr))
        var phase = 0.0
        for i in out.indices {
            let time = Double(i) / sr
            let freq = 20 * pow(1000.0, time / seconds) // 20 Hz → 20 kHz
            phase += 2 * .pi * freq / sr
            out[i] = gain * Float(sin(phase))
        }
        return Signal(samples: out, beats: [], bpm: 0, name: "sine sweep 20 Hz-20 kHz")
    }
}

struct Result {
    var detected: [Double] = []
    var frames: [AmbientAudioFeatures] = []
    var microsecondsPerHop: Double = 0
}

func analyze(_ signal: Signal, hop: Int = 512) -> Result {
    let analyzer = AmbientSpectralAnalyzer(sampleRate: Synth.sr, hopSize: hop)
    var result = Result()
    var lastCount: UInt64 = 0
    var elapsed: Double = 0
    signal.samples.withUnsafeBufferPointer { all in
        var index = 0
        while index + hop <= all.count {
            let slice = UnsafeBufferPointer(rebasing: all[index..<(index + hop)])
            let time = Double(index + hop) / Synth.sr
            let start = CACurrentMediaTime()
            let f = analyzer.process(hop: slice, at: time)
            elapsed += CACurrentMediaTime() - start
            if f.beatCount != lastCount {
                lastCount = f.beatCount
                result.detected.append(f.lastBeatTime)
            }
            result.frames.append(f)
            index += hop
        }
    }
    result.microsecondsPerHop = elapsed / Double(max(1, result.frames.count)) * 1e6
    return result
}

/// Precision / recall against the ground truth with a ±tolerance window,
/// after a warm-up.
func score(_ signal: Signal, _ result: Result, tolerance: Double = 0.07, warmUp: Double = 1.5)
    -> (precision: Double, recall: Double, f1: Double, meanOffsetMs: Double) {
    let truth = signal.beats.filter { $0 >= warmUp }
    let detected = result.detected.filter { $0 >= warmUp - tolerance }
    var used = Set<Int>()
    var matched = 0
    var offsets: [Double] = []
    for d in detected {
        if let (i, t) = truth.enumerated().filter({ !used.contains($0.offset) && abs($0.element - d) <= tolerance })
            .min(by: { abs($0.element - d) < abs($1.element - d) }) {
            used.insert(i); matched += 1; offsets.append(d - t)
        }
    }
    let precision = detected.isEmpty ? 0 : Double(matched) / Double(detected.count)
    let recall = truth.isEmpty ? 0 : Double(matched) / Double(truth.count)
    let f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    let meanOffset = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count) * 1000
    return (precision, recall, f1, meanOffset)
}

func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

@main
struct AmbientHarness {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            print((ok ? "  PASS " : "  FAIL ") + message)
            if !ok { failures += 1 }
        }

        print("== Beat detection on synthesized drum loops ==")
        var f1s: [Double] = []
        var bpmErrors: [Double] = []
        var cpu: [Double] = []
        let cases: [(Double, String, Float, Double)] = [
            (90, "rock", 0.5, 0), (100, "four", 0.5, 0), (120, "four", 0.5, 0), (120, "rock", 0.5, 0),
            (128, "four", 0.5, 0), (140, "rock", 0.5, 0), (160, "four", 0.5, 0), (174, "rock", 0.5, 0),
            (124, "four", 0.05, 0),          // -20 dB quieter
            (110, "rock", 0.5, 0.012),       // ±12 ms human timing
        ]
        for (bpm, pattern, gain, swing) in cases {
            var signal = Synth.drumLoop(bpm: bpm, seconds: 20, pattern: pattern, gain: gain, swingNoise: swing)
            if gain < 0.1 { signal.name += " (-20 dB)" }
            if swing > 0 { signal.name += " (±12 ms jitter)" }
            let r = analyze(signal)
            let s = score(signal, r)
            let estimate = Double(r.frames.last?.bpm ?? 0)
            // Accept the tempo or its double / half (octave errors are common
            // and harmless for lighting), but report the raw error.
            let candidates = [estimate, estimate * 2, estimate / 2]
            let err = candidates.map { abs($0 - bpm) / bpm }.min() ?? 1
            f1s.append(s.f1); bpmErrors.append(err); cpu.append(r.microsecondsPerHop)
            print(String(format: "  %-30@ P %@  R %@  F1 %@  offset %+.0f ms  BPM %.1f (err %.1f%%, conf %.2f)  %.1f µs/hop",
                         signal.name as NSString, pct(s.precision), pct(s.recall), pct(s.f1), s.meanOffsetMs,
                         estimate, err * 100, Double(r.frames.last?.tempoConfidence ?? 0), r.microsecondsPerHop))
        }
        let meanF1 = f1s.reduce(0, +) / Double(f1s.count)
        check(meanF1 >= 0.9, "mean beat F1 \(pct(meanF1)) ≥ 90%")
        check(f1s.allSatisfy { $0 >= 0.8 }, "every loop F1 ≥ 80% (min \(pct(f1s.min() ?? 0)))")
        let tempoOK = bpmErrors.filter { $0 < 0.03 }.count
        check(tempoOK >= bpmErrors.count - 1, "tempo within 3% (octave-folded) on \(tempoOK)/\(bpmErrors.count) loops")

        print("== Tempo change 100 → 140 BPM ==")
        do {
            let a = Synth.drumLoop(bpm: 100, seconds: 12, pattern: "four")
            let b = Synth.drumLoop(bpm: 140, seconds: 12, pattern: "four")
            let joined = Signal(samples: a.samples + b.samples, beats: a.beats + b.beats.map { $0 + 12 }, bpm: 140, name: "change")
            let r = analyze(joined)
            let at10 = r.frames[Int(10 * Synth.sr / 512)].bpm
            let end = r.frames.last!.bpm
            print(String(format: "  BPM at 10 s: %.1f, at 24 s: %.1f", at10, end))
            check(abs(Double(at10) - 100) < 3 && abs(Double(end) - 140) < 4, "tempo follows the change")
            let s = score(joined, r)
            print("  beats F1 across the change: \(pct(s.f1))")
        }

        print("== Sine sweep (no beats; bands move bass → mid → treble) ==")
        do {
            let signal = Synth.sweep(seconds: 12)
            let r = analyze(signal)
            func band(at seconds: Double) -> (Float, Float, Float) {
                let f = r.frames[min(r.frames.count - 1, Int(seconds * Synth.sr / 512))]
                return (f.bass, f.mid, f.treble)
            }
            // 20 * 1000^(t/12): 60 Hz at 1.9 s, 600 Hz at 5.9 s, 6 kHz at 9.9 s.
            let low = band(at: 1.9), mid = band(at: 5.9), high = band(at: 9.9)
            print(String(format: "  at 60 Hz b/m/t %.2f %.2f %.2f; 600 Hz %.2f %.2f %.2f; 6 kHz %.2f %.2f %.2f",
                         low.0, low.1, low.2, mid.0, mid.1, mid.2, high.0, high.1, high.2))
            check(low.0 > low.1 && low.0 > low.2, "60 Hz is bass")
            check(mid.1 > mid.0 && mid.1 > mid.2, "600 Hz is mid")
            check(high.2 > high.0 && high.2 > high.1, "6 kHz is treble")
            let beatsPerSecond = Double(r.detected.count) / 12
            print(String(format: "  beats on a sweep: %d (%.2f/s)", r.detected.count, beatsPerSecond))
            check(beatsPerSecond < 0.5, "sweep makes < 0.5 false beats per second")
        }

        print("== Silence and digital zeros ==")
        do {
            let silent = Signal(samples: [Float](repeating: 0, count: Int(5 * Synth.sr)), beats: [], bpm: 0, name: "zeros")
            let r = analyze(silent)
            check(r.detected.isEmpty, "no beats in silence")
            check(r.frames.last!.isSilent && r.frames.last!.isDigitalSilence, "silence and digital silence flagged")
            var rng = LCG(state: 7)
            let hiss = Signal(samples: (0..<Int(5 * Synth.sr)).map { _ in rng.next() * 0.0002 }, beats: [], bpm: 0, name: "hiss")
            let r2 = analyze(hiss)
            check(r2.detected.isEmpty && r2.frames.last!.isSilent && !r2.frames.last!.isDigitalSilence,
                  "-74 dBFS hiss: silent, not digital zeros, no beats (\(r2.detected.count))")
        }

        let meanCPU = cpu.reduce(0, +) / Double(cpu.count)
        let hopsPerSecond = Synth.sr / 512
        let cpuPercent = meanCPU * hopsPerSecond / 1e6 * 100
        print(String(format: "== Analyzer cost: %.1f µs per hop × %.0f hops/s = %.3f%% of one core ==", meanCPU, hopsPerSecond, cpuPercent))
        check(cpuPercent < 0.5, "analyzer < 0.5% of one core")

        AmbientRenderHarness.run(check: check)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
