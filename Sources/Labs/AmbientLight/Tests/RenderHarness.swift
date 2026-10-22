import AppKit
import QuartzCore

// Per-frame cost of the light: choreographer + notch outline glow + screen
// edge strips, on an offscreen layer tree (nothing is shown on screen), fed
// with real analyzer output from a synthesized drum loop. Also checks the
// photosensitivity limit, Reduce Motion and the fade-out.

enum AmbientRenderHarness {
    @MainActor
    static func run(check: (Bool, String) -> Void) {
        print("== Renderer cost (offscreen layers, analyzer-driven) ==")
        let signal = Synth.drumLoop(bpm: 128, seconds: 12, pattern: "four")
        let analysis = analyze(signal)
        let features = analysis.frames
        let hopSeconds = 512 / Synth.sr

        // Island-like outline: 300 × 38 body with a 120 pt drawer band.
        let glow = AmbientOutlineGlow()
        glow.root.frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
        let island = CGRect(x: 400, y: 28, width: 300, height: 38)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: island.minX, y: island.minY))
        path.addLine(to: CGPoint(x: island.minX, y: island.maxY - 12))
        path.addQuadCurve(to: CGPoint(x: island.minX + 12, y: island.maxY), control: CGPoint(x: island.minX, y: island.maxY))
        path.addLine(to: CGPoint(x: island.maxX - 12, y: island.maxY))
        path.addQuadCurve(to: CGPoint(x: island.maxX, y: island.maxY - 12), control: CGPoint(x: island.maxX, y: island.maxY))
        path.addLine(to: CGPoint(x: island.maxX, y: island.minY))
        glow.setOutline(path, in: island, springResponse: nil)
        let strips = AmbientEdgeStrips()
        strips.layout(bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), topInset: 37, thickness: 16)
        let host = CALayer()
        host.addSublayer(glow.root)
        host.addSublayer(strips.root)

        let palette = AmbientLightPalette.brand(.sparkV)
        let disco = AmbientLightPalette.disco(base: palette)

        for mode in AmbientLightMode.lit {
            var choreographer = AmbientLightChoreographer()
            let fps = 120.0
            let frames = Int(10 * fps)
            var total = 0.0
            var worst = 0.0
            for i in 0..<frames {
                let now = Double(i) / fps
                let hop = min(features.count - 1, Int(now / hopSeconds))
                var f = features[hop]
                f.time = now
                let start = CACurrentMediaTime()
                let frame = choreographer.step(.init(features: f, mode: mode, intensity: 0.8, isLive: true, reduceMotion: false, now: now))
                let p = frame.usesDiscoPalette ? disco : palette
                glow.render(frame, palette: p)
                strips.render(frame, palette: p)
                CATransaction.flush()
                let dt = CACurrentMediaTime() - start
                total += dt
                worst = max(worst, dt)
            }
            let mean = total / Double(frames) * 1e6
            let cpu = mean * fps / 1e6 * 100
            print(String(format: "  %-8@ mean %.1f µs/frame, worst %.0f µs  → %.3f%% of one core at 120 fps", mode.title as NSString, mean, worst * 1e6, cpu))
            check(cpu < 2, "\(mode.title) renderer < 2% CPU at 120 fps")
            if mode == .disco {
                let flashes = choreographer.maxFlashesPerSecond()
                check(flashes <= 3, "Disco at 128 BPM: at most 3 flashes in any second (\(flashes))")
            }
        }

        print("== Safety and accessibility ==")
        do {
            // A 16th-note hi-hat storm: 8 beats per second.
            var choreographer = AmbientLightChoreographer()
            var count: UInt64 = 0
            var minBrightness = 1.0
            for i in 0..<1200 {
                let now = Double(i) / 120
                var f = AmbientAudioFeatures()
                if i % 15 == 0 { count += 1 }
                f.beatCount = count
                f.lastBeatTime = now
                f.bass = 0.8; f.level = 0.8; f.isSilent = false
                let frame = choreographer.step(.init(features: f, mode: .disco, intensity: 1, isLive: true, reduceMotion: false, now: now))
                if now > 1 { minBrightness = min(minBrightness, frame.brightness) }
            }
            check(choreographer.maxFlashesPerSecond() <= 3, "8 beats/s input → \(choreographer.maxFlashesPerSecond()) flashes/s (≤ 3)")
            check(minBrightness >= 0.39, String(format: "Disco never drops below 40%% between flashes (min %.2f)", minBrightness))
        }
        // The guard must not flatten normal music: Pulse on the 128 BPM loop
        // still swings by ≥ 0.2 on most beats.
        do {
            var choreographer = AmbientLightChoreographer()
            var extreme = 0.0, falling = false, drops = 0
            for i in 0..<(120 * 10) {
                let now = Double(i) / 120
                var f = features[min(features.count - 1, Int(now / hopSeconds))]
                f.time = now
                let b = choreographer.step(.init(features: f, mode: .pulse, intensity: 1, isLive: true, reduceMotion: false, now: now)).brightness
                guard now > 1 else { extreme = b; continue }
                if falling { if b < extreme { extreme = b } else if b - extreme >= 0.2 { falling = false; extreme = b } }
                else { if b > extreme { extreme = b } else if extreme - b >= 0.2 { falling = true; drops += 1; extreme = b } }
            }
            check(drops >= 15, "Pulse at 128 BPM still pulses on the beat (\(drops) swings in 9 s, ~19 beats)")
        }
        // Adversarial input for every mode: an 8 Hz square-wave bassline plus
        // 8 beats per second. Counts big brightness drops (≥ 0.2, the dark
        // half of a flash) in every one-second window.
        for mode in AmbientLightMode.lit {
            for rate in [5.0, 8.0, 12.0] {
                var choreographer = AmbientLightChoreographer()
                var count: UInt64 = 0
                var drops: [Double] = []
                var extreme = 0.0
                var falling = false
                var lastBeat = -1
                for i in 0..<(120 * 6) {
                    let now = Double(i) / 120
                    var f = AmbientAudioFeatures()
                    let cycle = Int(now * rate)
                    if cycle != lastBeat { lastBeat = cycle; count += 1; f.lastBeatTime = now }
                    f.beatCount = count
                    f.lastBeatTime = Double(cycle) / rate
                    let on = (now * rate).truncatingRemainder(dividingBy: 1) < 0.5
                    f.bass = on ? 1 : 0; f.mid = 0.5; f.treble = on ? 1 : 0
                    f.level = 0.9; f.isSilent = false; f.bpm = Float(rate * 60 / 2); f.tempoConfidence = 0.9
                    let b = choreographer.step(.init(features: f, mode: mode, intensity: 1, isLive: true, reduceMotion: false, now: now)).brightness
                    guard now > 1 else { extreme = b; continue }
                    if falling {
                        if b < extreme { extreme = b } else if b - extreme >= 0.2 { falling = false; extreme = b }
                    } else {
                        if b > extreme { extreme = b } else if extreme - b >= 0.2 { falling = true; drops.append(now); extreme = b }
                    }
                }
                let worst = drops.indices.map { i in drops[i...].prefix { $0 < drops[i] + 1 }.count }.max() ?? 0
                check(worst <= 3, "\(mode.title), \(Int(rate)) Hz bass + beats: \(worst) big drops in any second (≤ 3)")
            }
        }
        do {
            var choreographer = AmbientLightChoreographer()
            var values: Set<Int> = []
            for i in 0..<1200 {
                let now = Double(i) / 120
                let hop = min(features.count - 1, Int(now / hopSeconds))
                let frame = choreographer.step(.init(features: features[hop], mode: .disco, intensity: 1, isLive: true, reduceMotion: true, now: now))
                if now > 4 { values.insert(Int(frame.brightness * 1000)); values.insert(Int(frame.colorPosition * 1000)) }
            }
            check(values.count <= 2, "Reduce Motion: steady light, no beat response (\(values.count) distinct values)")
        }
        do {
            var choreographer = AmbientLightChoreographer()
            var darkAt: Double?
            for i in 0..<600 {
                let now = Double(i) / 60
                let live = now < 3
                _ = choreographer.step(.init(features: features[min(features.count - 1, i * 3)], mode: .pulse, intensity: 1,
                                            isLive: live, reduceMotion: false, now: now))
                if !live, darkAt == nil, choreographer.isDark { darkAt = now - 3 }
            }
            check((darkAt ?? 99) < 4, String(format: "fades out and goes dark %.1f s after the music stops", darkAt ?? -1))
        }

        print("== Album colors ==")
        do {
            // Left half red, right half teal: two vivid colors.
            var pixels = [UInt8](repeating: 0, count: 24 * 24 * 4)
            for y in 0..<24 { for x in 0..<24 {
                let i = (y * 24 + x) * 4
                let c: (UInt8, UInt8, UInt8) = x < 12 ? (220, 30, 40) : (20, 180, 190)
                pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
            } }
            let colors = AmbientLightPalette.dominantColors(rgba: pixels)
            let hues = colors.map { AmbientLightPalette.hsb($0).h }
            print("  hues:", hues.map { String(format: "%.2f", $0) }.joined(separator: ", "))
            check(colors.count == 2 && hues.contains { $0 < 0.05 || $0 > 0.95 } && hues.contains { abs($0 - 0.51) < 0.05 },
                  "red + teal cover gives red and teal")
            let gray = [UInt8](repeating: 128, count: 24 * 24 * 4)
            check(AmbientLightPalette.dominantColors(rgba: gray).isEmpty, "gray cover gives no colors (brand palette used)")
        }
    }
}
