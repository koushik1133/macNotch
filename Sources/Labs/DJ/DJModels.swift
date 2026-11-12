import Foundation

// SparkV DJ: presets, the 10-band EQ layout and the saved settings.
// Nothing here touches audio; DJAudioEngine applies it.

/// The EQ's centre frequencies (Hz). Band 0 is a low shelf, band 9 a high
/// shelf, the rest are one-octave peaking filters: the classic ISO 10-band.
enum DJBands {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let count = frequencies.count
    /// ±12 dB per band.
    static let range: ClosedRange<Float> = -12...12

    static func label(_ index: Int) -> String {
        let hz = frequencies[index]
        return hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))"
    }
}

/// The room the reverb simulates (maps to AVAudioUnitReverbPreset).
enum DJRoom: String, Codable, Sendable {
    case none, smallRoom, mediumHall, largeHall, cathedral
}

/// One sound: EQ gains, stereo width, reverb and a bass "punch" boost.
struct DJSound: Equatable, Codable, Sendable {
    var gains: [Float] = Array(repeating: 0, count: DJBands.count)
    /// 1 = untouched, 0 = mono, up to 2 = very wide (mid/side).
    var width: Float = 1
    var room: DJRoom = .none
    /// Reverb wet mix 0…100 (%).
    var reverbMix: Float = 0

    static let flat = DJSound()
}

enum DJPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case flat, bass, vocal, spatial, concert, club, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Flat"
        case .bass: "Bass Boost"
        case .vocal: "Vocal"
        case .spatial: "Spatial"
        case .concert: "Concert"
        case .club: "Club"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .flat: "equal"
        case .bass: "speaker.wave.3.fill"
        case .vocal: "music.mic"
        case .spatial: "dot.radiowaves.left.and.right"
        case .concert: "building.columns.fill"
        case .club: "sparkles"
        case .custom: "slider.vertical.3"
        }
    }

    var help: String {
        switch self {
        case .flat: "No coloring: hear the track as mixed"
        case .bass: "Warm, deep low end"
        case .vocal: "Voices and dialogue forward, less boom"
        case .spatial: "A wider, more open stage (like Dolby's virtualizer)"
        case .concert: "Hall reverb, wide stage and a little extra bass, like a live show"
        case .club: "Punchy kick, crisp highs, a small room"
        case .custom: "Your own EQ"
        }
    }

    /// The sound at 100 % intensity. `.custom` returns nil (the saved bands).
    var sound: DJSound? {
        switch self {
        case .flat:
            return .flat
        case .bass:
            return DJSound(gains: [7, 6, 4.5, 2, 0, 0, 0, 0, 0.5, 0.5], width: 1)
        case .vocal:
            return DJSound(gains: [-3, -2.5, -1.5, 0, 1.5, 3, 3.5, 2.5, 0.5, -1], width: 0.95)
        case .spatial:
            return DJSound(gains: [2, 1.5, 0, -0.5, -1, 0, 1, 2, 3, 3], width: 1.65,
                           room: .smallRoom, reverbMix: 9)
        case .concert:
            return DJSound(gains: [4, 3.5, 1.5, 0, -0.5, -1, 0, 1, 2, 1.5], width: 1.45,
                           room: .largeHall, reverbMix: 24)
        case .club:
            return DJSound(gains: [6, 5, 1.5, -1, -1.5, 0, 1, 2.5, 3.5, 2.5], width: 1.2,
                           room: .smallRoom, reverbMix: 6)
        case .custom:
            return nil
        }
    }
}

/// Saved choices (UserDefaults). The on/off switch is deliberately NOT
/// saved: SparkV DJ is always off at launch and only the user turns it on.
@MainActor
final class DJSettings: ObservableObject {
    static let shared = DJSettings()

    private enum Key {
        static let preset = "DJ.preset"
        static let intensity = "DJ.intensity"
        static let custom = "DJ.customSound"
    }

    @Published var preset: DJPreset { didSet { defaults.set(preset.rawValue, forKey: Key.preset) } }
    /// 0…1: how strongly the preset applies.
    @Published var intensity: Double { didSet { defaults.set(intensity, forKey: Key.intensity) } }
    @Published var custom: DJSound {
        didSet {
            if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Key.custom) }
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        preset = DJPreset(rawValue: defaults.string(forKey: Key.preset) ?? "") ?? .concert
        let saved = defaults.object(forKey: Key.intensity) as? Double
        intensity = min(1, max(0, saved ?? 0.8))
        if let data = defaults.data(forKey: Key.custom),
           let sound = try? JSONDecoder().decode(DJSound.self, from: data),
           sound.gains.count == DJBands.count {
            custom = sound
        } else {
            custom = .flat
        }
    }

    /// The sound the engine should play right now.
    var sound: DJSound {
        let base = preset.sound ?? custom
        return DJMath.scaled(base, by: Float(intensity))
    }
}

enum DJMath {
    /// Intensity scales every deviation from flat.
    static func scaled(_ sound: DJSound, by amount: Float) -> DJSound {
        let k = min(1, max(0, amount))
        var out = sound
        out.gains = sound.gains.map { $0 * k }
        out.width = 1 + (sound.width - 1) * k
        out.reverbMix = sound.reverbMix * k
        out.room = k > 0.001 ? sound.room : .none
        return out
    }

    /// Pre-gain (dB): some headroom for boosted bands (about a third of the
    /// strongest boost; the limiter catches the rest, so presets don't just
    /// sound quieter), plus make-up for the dry level the reverb's wet mix
    /// takes away.
    static func headroom(for gains: [Float], reverbMix: Float = 0) -> Float {
        let boost = gains.max() ?? 0
        return -max(0, boost) * 0.35 + min(3, reverbMix / 100 * 6)
    }
}
