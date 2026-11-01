import SwiftUI

/// The notch's hover look. `.plain` is the original black island with no
/// highlight and stays the default; the others are opt-in in Settings.
enum NotchThemeID: String, CaseIterable, Codable, Identifiable {
    case plain
    case liquidGlassBubble
    case frostedHalo
    case dewdrop
    case glassPill
    case redRim
    case conicSweep
    case breathingPulse
    case neonTube
    case magneticRipple
    case aurora
    case particleSpark
    case minimalHairline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Plain"
        case .liquidGlassBubble: "Liquid Glass Bubble"
        case .frostedHalo: "Frosted Halo"
        case .dewdrop: "Dewdrop"
        case .glassPill: "Glass Pill"
        case .redRim: "SparkV Red Rim"
        case .conicSweep: "Conic Sweep"
        case .breathingPulse: "Breathing Pulse"
        case .neonTube: "Neon Tube"
        case .magneticRipple: "Magnetic Ripple"
        case .aurora: "Aurora"
        case .particleSpark: "Particle Spark"
        case .minimalHairline: "Minimal Hairline"
        }
    }

    enum Family: String { case basic = "Basic", glass = "Glass", glow = "Glow", motion = "Motion" }

    var family: Family {
        switch self {
        case .plain: .basic
        case .liquidGlassBubble, .frostedHalo, .dewdrop, .glassPill: .glass
        case .redRim, .conicSweep, .breathingPulse, .neonTube: .glow
        case .magneticRipple, .aurora, .particleSpark, .minimalHairline: .motion
        }
    }
}

/// Where the island is in its hover cycle.
enum NotchThemePhase: Equatable {
    /// Pointer elsewhere: the island sits flush with the camera notch.
    case resting
    /// Pointer on the notch, drawer not open yet: the highlight is fully on.
    case hovered
    /// Drawer open.
    case open
}

/// Everything a theme layer needs to draw around the island.
struct NotchThemeContext: Equatable {
    var phase: NotchThemePhase
    /// Size of the black island body (without the flared shoulders).
    var bodySize: CGSize
    /// Flare radius of the shoulders and radius of the bottom corners, as
    /// `IslandShape` draws them for the current phase.
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Pointer position in the layer's coordinate space, when it is over or
    /// near the island (for Dewdrop and Magnetic Ripple).
    var pointer: CGPoint?
    var reduceMotion: Bool
    var reduceTransparency: Bool
    /// Low Power Mode or a warm Mac (`SparkVEnergy.isConstrained`): animated
    /// layers draw at half their frame rate.
    var lowPower: Bool = false

    /// A layer's minimum frame interval (nil: display rate), doubled while
    /// `lowPower`.
    func frameInterval(_ base: Double?) -> Double? {
        guard lowPower else { return base }
        return (base ?? 1.0 / 60) * 2
    }
}

/// What fills the island behind its content.
enum NotchBackgroundStyle: String, CaseIterable, Codable, Identifiable {
    /// A warm gradient tinted from the playing track's album art (opt-in).
    case albumGlow
    /// Solid black, the original look and the default.
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albumGlow: "Album Glow"
        case .black: "Black"
        }
    }
}

/// The user's choices, saved in UserDefaults ("NotchTheme", "NotchBackground").
@MainActor
final class NotchThemeSettings: ObservableObject {
    static let shared = NotchThemeSettings()
    static let defaultsKey = "NotchTheme"
    static let backgroundKey = "NotchBackground"

    @Published var theme: NotchThemeID {
        didSet { defaults.set(theme.rawValue, forKey: Self.defaultsKey) }
    }

    @Published var background: NotchBackgroundStyle {
        didSet { defaults.set(background.rawValue, forKey: Self.backgroundKey) }
    }

    /// The theme the notch draws: Plain while Appearance › Decorative Glows
    /// is off (the chosen theme is kept for when it comes back on).
    var effectiveTheme: NotchThemeID {
        LookOptions.current.themesAllowed ? theme : .plain
    }

    /// The island background in effect: Black while Decorative Glows is off,
    /// with Reduce Transparency, and with higher contrast.
    var effectiveBackground: NotchBackgroundStyle {
        LookOptions.current.albumGlowAllowed ? background : .black
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.defaultsKey).flatMap(NotchThemeID.init(rawValue:)) ?? .plain
        background = defaults.string(forKey: Self.backgroundKey).flatMap(NotchBackgroundStyle.init(rawValue:)) ?? .black
    }
}

/// How far a theme's effects may reach outside the island body, so the notch
/// window can leave room for glows and rims without clipping them.
enum NotchThemeMetrics {
    static let maxOutset: CGFloat = 28
}
