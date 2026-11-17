import AVFoundation
import Foundation

// Offline check of the SparkV DJ signal path: DJRealtimeState.process (the
// IO block body) pulling DJEffectsChain (AVAudioEngine, realtime manual
// rendering) on synthesized tones. Prints the gain per preset and band.

@main
enum DJHarness {
    static let rate = 48_000.0
    static let frames = 512

    static func run(_ sound: DJSound, tone: Double, wet: Float = 1, seconds: Double = 0.6) -> (inRMS: Float, outRMS: Float, tail: Float, peak: Float) {
        let ring = AmbientSampleRing(capacity: 1 << 16)
        let state = DJRealtimeState(ring: ring)
        state.sampleRate = rate
        state.tapInterleaved = true
        state.tapChannels = 2
        let chain = try! DJEffectsChain(sampleRate: rate, state: state)
        chain.set(room: sound.room)
        chain.set(gains: sound.gains, globalGain: DJMath.headroom(for: sound.gains, reverbMix: sound.reverbMix), reverbMix: sound.reverbMix)
        state.set(width: sound.width)
        state.set(wet: wet)
        state.set(master: 1)

        let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { input.deallocate(); output.deallocate() }
        var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: input))
        var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: output))
        var phase = 0.0
        var inSum: Double = 0, outSum: Double = 0, count = 0
        var tail: Float = 0, peak: Float = 0
        let cycles = Int(seconds * rate) / frames
        for cycle in 0..<(cycles + 40) {
            let silent = cycle >= cycles
            for i in 0..<frames {
                let v = silent ? 0 : Float(0.25 * sin(phase))
                phase += 2 * .pi * tone / rate
                input[2 * i] = v
                input[2 * i + 1] = silent ? 0 : Float(0.25 * sin(phase * 1.003)) // slightly decorrelated R
            }
            outList.mBuffers.mDataByteSize = UInt32(frames * 8)
            state.process(input: &inList, output: &outList)
            for i in 0..<(frames * 2) {
                peak = max(peak, abs(output[i]))
                if silent { tail = max(tail, abs(output[i])) }
                else if cycle > cycles / 3 {
                    inSum += Double(input[i] * input[i]); outSum += Double(output[i] * output[i]); count += 1
                }
            }
        }
        chain.stop()
        assert(state.renderFailures.load(ordering: .relaxed) == 0, "render failed")
        return (Float(sqrt(inSum / Double(max(1, count)))), Float(sqrt(outSum / Double(max(1, count)))), tail, peak)
    }

    static func db(_ x: Float, _ y: Float) -> String { String(format: "%+5.1f dB", 20 * log10(max(1e-9, y) / max(1e-9, x))) }

    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  " : "  FAIL", what); if !ok { failures += 1 } }
        let tones: [Double] = [60, 250, 1_000, 3_000, 10_000]
        print("gain per tone (output vs input RMS)")
        var table: [DJPreset: [Float]] = [:]
        for preset in DJPreset.allCases where preset != .custom {
            let sound = preset.sound!
            var row = "\(preset.title.padding(toLength: 11, withPad: " ", startingAt: 0))"
            var gains: [Float] = []
            for tone in tones {
                let r = run(sound, tone: tone)
                gains.append(20 * log10(r.outRMS / r.inRMS))
                row += "  \(Int(tone))Hz " + db(r.inRMS, r.outRMS)
            }
            table[preset] = gains
            print(row)
        }
        let flat = table[.flat]!
        check(flat.allSatisfy { abs($0) < 0.5 }, "Flat is transparent (±0.5 dB)")
        check(table[.bass]![0] - table[.bass]![2] > 4, "Bass Boost lifts 60 Hz well above 1 kHz")
        check(table[.vocal]![3] - table[.vocal]![0] > 4, "Vocal lifts 3 kHz above 60 Hz")
        check(table[.club]![0] - table[.club]![2] > 3, "Club has a punchy low end")
        let concert = run(DJPreset.concert.sound!, tone: 1_000)
        let dryTail = run(.flat, tone: 1_000)
        print(String(format: "reverb tail after stop: concert %.4f, flat %.4f", concert.tail, dryTail.tail))
        check(concert.tail > 0.005 && dryTail.tail < 0.0005, "Concert leaves a hall tail; Flat doesn't")
        let bypass = run(DJPreset.bass.sound!, tone: 60, wet: 0)
        check(abs(20 * log10(bypass.outRMS / bypass.inRMS)) < 0.5, "Bypass (A/B) plays the untouched sound")
        let loud = run(DJSound(gains: Array(repeating: 12, count: DJBands.count)), tone: 60)
        check(loud.peak <= 1.0, String(format: "Limiter keeps +12 dB everywhere under full scale (peak %.3f)", loud.peak))
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
