import AppKit
import Combine
import Foundation
import os

// Ambient Light: car-style mood lighting for the notch (and optionally the
// screen edges) that follows the music, like the "Groove Me" light show of
// the Mahindra BE 6, Mercedes ambient light sync or a Hue / DreamView bar.
// This file holds the contract: modes, settings and the audio feature
// snapshot shared by the analyzer and the renderers.
// See INTEGRATION.md in this folder.

/// How the light moves.
enum AmbientLightMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Slow breathing in the album colors.
    case ambient
    /// Brightness and halo follow the bass.
    case pulse
    /// Hue jumps on every beat, with a photosensitivity-safe flash limit.
    case disco
    /// Colors travel around the outline in time with the tempo.
    case wave
    /// Nothing is drawn and nothing is captured.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ambient: "Ambient"
        case .pulse: "Pulse"
        case .disco: "Disco"
        case .wave: "Wave"
        case .off: "Off"
        }
    }

    var systemImage: String {
        switch self {
        case .ambient: "sun.haze.fill"
        case .pulse: "waveform.path.ecg"
        case .disco: "sparkles"
        case .wave: "water.waves"
        case .off: "lightbulb.slash"
        }
    }

    var blurb: String {
        switch self {
        case .ambient: "A slow, breathing glow in the colors of the album art."
        case .pulse: "The glow swells with the kick drum and bass."
        case .disco: "A new color on every beat. Flashes are capped at 3 per second."
        case .wave: "Colors chase around the border at the song's tempo."
        case .off: "No light."
        }
    }

    /// Modes that need the audio analysis (Ambient only needs it lightly,
    /// but uses loudness so the glow fades during quiet passages).
    var needsAudio: Bool { self != .off }

    static let lit: [AmbientLightMode] = [.ambient, .pulse, .disco, .wave]
}

/// Where the light is drawn.
enum AmbientLightScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case notchOnly
    case notchAndEdges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notchOnly: "Notch Only"
        case .notchAndEdges: "Notch + Screen Edges"
        }
    }
}

/// A fallback color set used when there is no album art or the art is
/// monochrome (also the source of Disco's extra hues).
enum AmbientBrandPalette: String, CaseIterable, Codable, Identifiable, Sendable {
    /// SparkV red into magenta and amber.
    case sparkV
    /// Cool cyan, electric blue and violet (EV cabin look).
    case electric
    /// Warm sunset: amber, coral, rose.
    case sunset
    /// Green-teal aurora.
    case aurora

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sparkV: "SparkV"
        case .electric: "Electric"
        case .sunset: "Sunset"
        case .aurora: "Aurora"
        }
    }

    /// sRGB components, bright enough to read as light.
    var rgb: [(Double, Double, Double)] {
        switch self {
        case .sparkV: [(1.0, 0.16, 0.20), (1.0, 0.18, 0.62), (1.0, 0.55, 0.12), (0.62, 0.20, 1.0)]
        case .electric: [(0.10, 0.85, 1.0), (0.18, 0.40, 1.0), (0.62, 0.25, 1.0), (0.10, 1.0, 0.80)]
        case .sunset: [(1.0, 0.62, 0.10), (1.0, 0.35, 0.30), (1.0, 0.25, 0.55), (1.0, 0.80, 0.35)]
        case .aurora: [(0.15, 1.0, 0.55), (0.10, 0.85, 0.85), (0.35, 0.55, 1.0), (0.70, 1.0, 0.30)]
        }
    }
}

/// The user's choices, saved in UserDefaults under "AmbientLight.*".
/// Everything is off until the user turns it on.
@MainActor
final class AmbientLightSettings: ObservableObject {
    static let shared = AmbientLightSettings()

    enum Keys {
        static let enabled = "AmbientLight.enabled"
        static let mode = "AmbientLight.mode"
        static let intensity = "AmbientLight.intensity"
        static let scope = "AmbientLight.scope"
        static let syncAlbum = "AmbientLight.syncToAlbumColors"
        static let palette = "AmbientLight.palette"
        static let edgeWidth = "AmbientLight.edgeWidth"
        static let startedCaptureOnce = "AmbientLight.startedCaptureOnce"
    }

    /// Master switch (default off). Turning it on from the UI is the only
    /// moment SparkV asks for System Audio Recording.
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    @Published var mode: AmbientLightMode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    /// 0.2...1: overall brightness and glow size.
    @Published var intensity: Double { didSet { defaults.set(intensity, forKey: Keys.intensity) } }
    @Published var scope: AmbientLightScope { didSet { defaults.set(scope.rawValue, forKey: Keys.scope) } }
    /// Colors from the album art; off uses `palette` only.
    @Published var syncToAlbumColors: Bool { didSet { defaults.set(syncToAlbumColors, forKey: Keys.syncAlbum) } }
    @Published var palette: AmbientBrandPalette { didSet { defaults.set(palette.rawValue, forKey: Keys.palette) } }
    /// Screen-edge strip thickness in points (6...40).
    @Published var edgeWidth: Double { didSet { defaults.set(edgeWidth, forKey: Keys.edgeWidth) } }

    /// The tap was started once after the user turned the feature on, so the
    /// system prompt has been shown and later automatic starts can't prompt.
    var hasStartedCaptureOnce: Bool {
        get { defaults.bool(forKey: Keys.startedCaptureOnce) }
        set { defaults.set(newValue, forKey: Keys.startedCaptureOnce) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        mode = defaults.string(forKey: Keys.mode).flatMap(AmbientLightMode.init(rawValue:)) ?? .ambient
        let storedIntensity = defaults.object(forKey: Keys.intensity) as? Double
        intensity = min(1, max(0.2, storedIntensity ?? 0.75))
        scope = defaults.string(forKey: Keys.scope).flatMap(AmbientLightScope.init(rawValue:)) ?? .notchOnly
        syncToAlbumColors = (defaults.object(forKey: Keys.syncAlbum) as? Bool) ?? true
        palette = defaults.string(forKey: Keys.palette).flatMap(AmbientBrandPalette.init(rawValue:)) ?? .sparkV
        let storedWidth = defaults.object(forKey: Keys.edgeWidth) as? Double
        edgeWidth = min(40, max(6, storedWidth ?? 16))
    }

    /// Lit and drawing something.
    var isActive: Bool { isEnabled && mode != .off }
}

/// One analysis result, published by the analyzer at its hop rate
/// (~94 per second) and read by the renderers each display frame.
/// All levels are normalized to 0...1 with automatic gain, so the output
/// volume does not matter.
struct AmbientAudioFeatures: Equatable, Sendable {
    /// Smoothed band levels (attack / release envelopes).
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// Overall loudness envelope.
    var level: Float = 0
    /// Raw onset strength of the latest hop (0...1).
    var onset: Float = 0
    /// Increments on every detected beat; renderers compare it to the last
    /// value they saw, so no beat is lost between display frames.
    var beatCount: UInt64 = 0
    /// Host time (seconds, `CACurrentMediaTime` clock) of the last beat.
    var lastBeatTime: Double = 0
    /// Tempo estimate, 0 until known.
    var bpm: Float = 0
    /// 0...1 confidence of `bpm`.
    var tempoConfidence: Float = 0
    /// Below the noise floor for a while (paused, silent intro, denied).
    var isSilent: Bool = true
    /// Only digital zeros arrived for a while: usually System Audio
    /// Recording is off for SparkV (macOS then delivers silence, no error).
    var isDigitalSilence: Bool = false
    /// When this snapshot was made (`CACurrentMediaTime` clock).
    var time: Double = 0

    static let idle = AmbientAudioFeatures()
}

/// Thread-safe mailbox between the analysis queue and the main thread.
/// A plain unfair lock around a small struct: no allocation, no actor hop.
final class AmbientFeatureMailbox: @unchecked Sendable {
    private var value = AmbientAudioFeatures.idle
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func store(_ features: AmbientAudioFeatures) {
        os_unfair_lock_lock(lock)
        value = features
        os_unfair_lock_unlock(lock)
    }

    func load() -> AmbientAudioFeatures {
        os_unfair_lock_lock(lock)
        let copy = value
        os_unfair_lock_unlock(lock)
        return copy
    }
}

/// Why the light is hidden right now, for the settings view.
enum AmbientLightStatus: Equatable, Sendable {
    case off
    /// On, waiting for music.
    case waitingForMusic
    /// Asking macOS for System Audio Recording.
    case requestingPermission
    /// System Audio Recording is off for SparkV.
    case needsPermission
    /// Capturing and lit.
    case running(source: String)
    /// Capture failed (with a short reason).
    case failed(String)

    var text: String {
        switch self {
        case .off: "Off"
        case .waitingForMusic: "Waiting for music"
        case .requestingPermission: "Asking for System Audio Recording…"
        case .needsPermission: "Allow System Audio Recording for SparkV in System Settings › Privacy & Security."
        case .running(let source): "Listening (\(source))"
        case .failed(let reason): "Couldn't listen: \(reason)"
        }
    }
}
