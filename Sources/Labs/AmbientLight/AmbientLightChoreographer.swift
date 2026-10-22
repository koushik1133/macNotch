import Foundation

/// What the renderers draw this display frame. Plain numbers, so the notch
/// glow and the screen edges stay in step and nothing is recomputed twice.
struct AmbientVisualFrame: Equatable, Sendable {
    /// Overall light level, 0...1 (layer opacity).
    var brightness: Double = 0
    /// Glow size, 0...1 (halo blur radius and strip depth).
    var bloom: Double = 0
    /// Main color, as a position on the palette ramp (wraps).
    var colorPosition: Double = 0
    /// Wave: rotation of the traveling colors, in turns (wraps).
    var wavePhase: Double = 0
    /// 0 = one color all around, 1 = the full palette spread around.
    var spread: Double = 0
    /// Whiteness of the thin core line (treble sparkle), 0...1.
    var sparkle: Double = 0
    /// Use the Disco palette instead of the album one.
    var usesDiscoPalette = false
    /// The fade in / out of the whole effect, 0...1 (already applied to
    /// `brightness`; renderers stop their display link at 0).
    var presence: Double = 0

    static let dark = AmbientVisualFrame()
}

/// Turns audio features into light, per mode. Pure logic driven by the
/// renderer's display link (any frame rate: everything is time-based), and
/// covered by the harness in Tests/.
///
/// Photosensitivity: Disco changes color or flashes at most 3 times per
/// second (WCAG 2.3.1 "three flashes"), never drops below 40 % brightness
/// between flashes, and each flash eases out over ~150 ms instead of
/// strobing on/off. Every mode also goes through `FlashGuard`: the light may
/// rise at once, but a drop of more than `FlashGuard.bigDrop` counts as a
/// flash and may happen at most once per 1/3 s; in between, the light can
/// only fade slowly (Disco's bass glow always fades slowly). So a fast bassline
/// or 16th-note kicks can't strobe Pulse / Wave / Disco faster than 3 Hz.
/// Reduce Motion gives a steady glow with no beat response.
struct AmbientLightChoreographer {
    struct Input {
        var features: AmbientAudioFeatures
        var mode: AmbientLightMode
        var intensity: Double
        /// Music playing, feature on, nothing suppressing it.
        var isLive: Bool
        var reduceMotion: Bool
        /// Display-link timestamp (seconds, same clock as features.time).
        var now: Double
    }

    /// Shortest time between two Disco color changes / flashes.
    static let minFlashInterval: Double = 1.0 / 3.0
    static let discoFloor: Double = 0.4

    private(set) var frame = AmbientVisualFrame.dark
    private var lastNow: Double?
    private var lastBeatCount: UInt64 = 0
    private var discoIndex = 0
    private var discoFrom = 0.0
    private var discoChangeTime = -10.0
    private var flash = 0.0
    private var beatBoost = 0.0
    private var drift = 0.0
    private var wave = 0.0
    private var smoothedBass = 0.0
    private var smoothedLevel = 0.0
    private(set) var flashTimes: [Double] = []
    private var flashGuard = FlashGuard()
    private var discoBass = 0.0

    /// True when the effect is fully faded out and nothing is pending.
    var isDark: Bool { frame.presence <= 0.001 }

    mutating func step(_ input: Input) -> AmbientVisualFrame {
        let dt = min(0.1, max(0, input.now - (lastNow ?? input.now)))
        lastNow = input.now
        let f = input.features

        // Fade the whole effect in and out (time constants 0.45 s, 0.4 s).
        let target = input.isLive && input.mode != .off ? 1.0 : 0.0
        let tau = target > frame.presence ? 0.45 : 0.4
        var presence = approach(frame.presence, target, dt: dt, tau: tau)
        // Below one 8-bit opacity step the light is invisible: snap.
        if abs(presence - target) < 0.004 { presence = target }

        // Light smoothing on top of the analyzer's envelopes so 30 fps and
        // 120 fps look the same.
        smoothedBass = approach(smoothedBass, Double(f.bass), dt: dt, tau: f.bass > Float(smoothedBass) ? 0.012 : 0.09)
        smoothedLevel = approach(smoothedLevel, Double(f.level), dt: dt, tau: 0.25)
        let newBeat = f.beatCount != lastBeatCount
        lastBeatCount = f.beatCount
        let tempoKnown = f.bpm > 0 && f.tempoConfidence > 0.3
        let quiet = f.isSilent ? 0.55 : 1.0

        var next = AmbientVisualFrame()
        next.presence = presence
        let intensity = min(1, max(0.2, input.intensity))

        if input.reduceMotion {
            next.brightness = 0.6
            next.bloom = 0.6
            next.colorPosition = 0
            next.spread = 0.35
            frame = finish(next, intensity: intensity)
            return frame
        }

        beatBoost = max(0, beatBoost - dt / 0.14)
        if newBeat, input.now - f.lastBeatTime < 0.25 { beatBoost = 1 }
        flash = approach(flash, 0, dt: dt, tau: 0.15)

        switch input.mode {
        case .ambient:
            let period = tempoKnown ? min(9, max(4, 8 * 60 / Double(f.bpm))) : 6
            let breath = 0.5 + 0.5 * sin(2 * .pi * input.now / period)
            drift += dt / 40
            next.brightness = (0.42 + 0.33 * breath) * (0.65 + 0.35 * smoothedLevel) * quiet
            next.bloom = 0.55 + 0.25 * breath
            next.colorPosition = drift
            next.spread = 0.45
            next.sparkle = 0.15

        case .pulse:
            drift += dt / 30
            let kick = max(smoothedBass, 0.7 * beatBoost)
            next.brightness = 0.16 + 0.84 * pow(kick, 0.8)
            next.bloom = 0.35 + 0.65 * kick
            next.colorPosition = drift + 0.08 * Double(f.mid)
            next.spread = 0.25
            next.sparkle = 0.6 * Double(f.treble)

        case .disco:
            if newBeat, input.now - discoChangeTime >= Self.minFlashInterval {
                discoFrom = Double(discoIndex)
                discoIndex += 1
                discoChangeTime = input.now
                flash = 1
                flashTimes.append(input.now)
                if flashTimes.count > 16 { flashTimes.removeFirst(flashTimes.count - 16) }
            }
            // 60 ms ease into the new color (still one change per beat).
            let t = min(1, (input.now - discoChangeTime) / 0.06)
            let index = discoFrom + (Double(discoIndex) - discoFrom) * (t * t * (3 - 2 * t))
            next.usesDiscoPalette = true
            next.colorPosition = index / 4
            // The bass part may rise at once but only fades slowly, so it
            // never adds flashes of its own between the capped beat flashes.
            let bassTarget = 0.5 * smoothedBass
            discoBass = bassTarget >= discoBass ? bassTarget : max(bassTarget, discoBass - FlashGuard.lockedFallRate * dt)
            let bassGlow = discoBass
            next.brightness = Self.discoFloor + (1 - Self.discoFloor) * max(flash, bassGlow)
            next.bloom = 0.45 + 0.55 * flash
            next.spread = 0.1
            next.sparkle = 0.5 * flash

        case .wave:
            // One lap per 4 beats, capped so a point on the border never sees
            // more than ~2 bright/dark color cycles per second.
            let lapsPerSecond = tempoKnown ? min(0.5, Double(f.bpm) / 60 / 4) : 0.12
            wave += dt * lapsPerSecond * (1 + 0.6 * smoothedBass)
            drift += dt / 45
            next.wavePhase = wave
            next.colorPosition = drift
            next.brightness = (0.45 + 0.4 * smoothedBass + 0.15 * beatBoost) * quiet
            next.bloom = 0.45 + 0.35 * smoothedBass
            next.spread = 1
            next.sparkle = 0.3 * Double(f.treble)

        case .off:
            next.brightness = 0
        }
        if input.mode != .disco {
            next.brightness = flashGuard.apply(next.brightness, now: input.now, dt: dt)
        }

        frame = finish(next, intensity: intensity)
        return frame
    }

    private func finish(_ value: AmbientVisualFrame, intensity: Double) -> AmbientVisualFrame {
        var v = value
        v.brightness = min(1, max(0, v.brightness)) * (0.35 + 0.65 * intensity) * v.presence
        v.bloom = min(1, max(0, v.bloom)) * (0.5 + 0.5 * intensity)
        v.sparkle = min(1, max(0, v.sparkle))
        return v
    }

    /// Exponential approach (frame-rate independent).
    private func approach(_ current: Double, _ target: Double, dt: Double, tau: Double) -> Double {
        guard dt > 0 else { return current }
        return target + (current - target) * exp(-dt / tau)
    }

    /// The most flashes in any one-second window so far (for tests).
    func maxFlashesPerSecond() -> Int {
        var best = 0
        for (i, start) in flashTimes.enumerated() {
            let count = flashTimes[i...].prefix { $0 < start + 1 }.count
            best = max(best, count)
        }
        return best
    }
}

/// Limits big brightness drops (the dark half of a flash) to one per
/// `AmbientLightChoreographer.minFlashInterval`. Rises pass through at once;
/// a drop of more than `bigDrop` from the last rise is allowed (and counted)
/// when no flash happened in the last 1/3 s, otherwise the light may only
/// fade at `lockedFallRate`.
struct FlashGuard {
    static let bigDrop: Double = 0.15
    static let lockedFallRate: Double = 0.45
    private(set) var value: Double = 0
    private var peak: Double = 0
    var lastFlash: Double = -10

    mutating func apply(_ target: Double, now: Double, dt: Double) -> Double {
        if target >= value {
            value = target
            peak = target
            return value
        }
        if now - lastFlash >= AmbientLightChoreographer.minFlashInterval {
            if peak - target > Self.bigDrop { lastFlash = now }
            value = target
        } else {
            value = max(target, value - Self.lockedFallRate * dt)
        }
        return value
    }
}
