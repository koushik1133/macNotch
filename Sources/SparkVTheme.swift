import QuartzCore
import SwiftUI

/// Colors and type for both looks (`AppearanceStyle`). Every token resolves
/// for the look in effect when it is read, so call sites stay the same:
///
/// - **Apple** (default): the native macOS / Dynamic Island look. Pure
///   black island, white text, grey secondary glyphs, white 16 % pill on the
///   active tab, per-agent tint colors, system blue (`Color.accentColor`)
///   for primary buttons, toggles, selection and links, iOS semantic
///   green / orange, and red only for recording and destructive actions.
/// - **SparkV Red**: matched to sparkv.si. Near-black ground, off-white
///   text, one signal red for accents, active tabs, focus and live state.
///
/// Views read these in `body`; roots wrap themselves in
/// `followsAppearance()` so a switch rebuilds them.
enum SparkVTheme {
    // MARK: Look

    /// The look in effect (UserDefaults "AppearanceStyle"; Apple when unset).
    static var style: AppearanceStyle { AppearanceStyle.current }
    /// True in the Apple look.
    static var isApple: Bool { style == .apple }

    /// Picks the value for the look in effect: `SparkVTheme.choose(apple: .cyan, sparkv: red)`.
    static func choose<T>(apple: T, sparkv: T) -> T {
        isApple ? apple : sparkv
    }

    // MARK: Colors (same names in both looks)

    /// Panel and window ground: a neutral macOS dark (#1C1C1E) in Apple,
    /// #09090A in SparkV Red. The island itself is `islandBackground`.
    static var background: Color {
        isApple ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : Color(red: 9 / 255, green: 9 / 255, blue: 10 / 255)
    }
    /// Raised surfaces: cards, rows, tiles.
    static var surface: Color { Color.white.opacity(isApple ? 0.08 : 0.06) }
    /// Hovered or pressed surface.
    static var surfaceHover: Color { Color.white.opacity(isApple ? 0.14 : 0.11) }
    /// Hairline borders and dividers.
    static var stroke: Color { Color.white.opacity(isApple ? 0.09 : 0.10) }
    /// Primary text (white in Apple, #F7F7F5 in SparkV Red).
    static var text: Color { isApple ? Color.white : Color(red: 247 / 255, green: 247 / 255, blue: 245 / 255) }
    /// Secondary text and inactive icons.
    static var textSecondary: Color { Color.white.opacity(isApple ? 0.58 : 0.62) }
    /// Captions, placeholders, disabled.
    static var textTertiary: Color { Color.white.opacity(isApple ? 0.38 : 0.40) }
    /// The accent under its historical name: system blue in Apple, brand
    /// red (#F01822) in SparkV Red. For recording / destructive red in both
    /// looks use `recording` / `destructive`.
    static var red: Color { accent }
    /// Pressed / darker accent.
    static var redDeep: Color { accentPressed }
    /// Accent wash behind selected items.
    static var redSoft: Color { accentSoft }

    // Semantic colors keep their meaning and are used only for status.
    static var success: Color { isApple ? Color.green : Color(red: 0.30, green: 0.80, blue: 0.50) }
    static var warning: Color { isApple ? Color.orange : Color(red: 1.0, green: 0.70, blue: 0.25) }

    /// The soft red glow sparkv.si puts behind its hero. Clear in Apple.
    static var glow: RadialGradient {
        RadialGradient(colors: [glowColor.opacity(isApple ? 0 : 0.28), glowColor.opacity(0.0)], center: .topTrailing, startRadius: 0, endRadius: 320)
    }

    // MARK: Colors (explicit per-look tokens)

    /// The interactive accent: primary buttons, toggles, selection, links,
    /// progress. `Color.accentColor` (the user's system accent, blue by
    /// default) in Apple; brand red in SparkV Red.
    static var accent: Color { isApple ? Color.accentColor : brandRed }
    /// Pressed / darker accent.
    static var accentPressed: Color { isApple ? Color.accentColor.opacity(0.78) : Color(red: 215 / 255, green: 19 / 255, blue: 29 / 255) }
    /// Accent wash behind selected items.
    static var accentSoft: Color { isApple ? Color.accentColor.opacity(0.22) : brandRed.opacity(0.16) }
    /// Links in text.
    static var link: Color { accent }

    /// Recording and live-capture red: system red in Apple, brand red in
    /// SparkV Red. Red in both looks.
    static var recording: Color { isApple ? Color.red : brandRed }
    /// Soft wash behind recording state.
    static var recordingSoft: Color { recording.opacity(isApple ? 0.22 : 0.16) }
    /// Destructive actions (Delete, Stop, Clear): red in both looks.
    static var destructive: Color { recording }

    /// The island's own ground: pure black in both looks.
    static let islandBackground = Color.black
    /// Window ground (same as `background`).
    static var windowBackground: Color { background }

    /// Active header tab: white glyph on a soft white 16 % pill in Apple; red
    /// glyph on a red wash with a red hairline in SparkV Red.
    static var activeTabFill: Color { isApple ? Color.white.opacity(0.16) : accentSoft }
    static var activeTabStroke: Color { isApple ? Color.clear : brandRed.opacity(0.35) }
    /// Glyph color of an active tab or selected control.
    static var activeGlyph: Color { isApple ? Color.white : brandRed }
    /// Glyph color of an inactive header tab.
    static var inactiveGlyph: Color { isApple ? Color.white.opacity(0.55) : textSecondary }
    /// Soft hover fill for icon buttons and rows.
    static var hoverFill: Color { isApple ? Color.white.opacity(0.08) : surface }

    /// Apple draws each agent tile and feature glyph in its own tint color;
    /// SparkV Red draws them monochrome and lights them red.
    static var usesTileTints: Bool { isApple }
    /// The dash or dot in front of eyebrow labels ("— AGENTS").
    static var eyebrowDash: Color { isApple ? textTertiary : brandRed }
    /// Default progress / spinner tint.
    static var progressTint: Color { isApple ? Color.white : brandRed }

    /// Brand red, the same in both looks: for SparkV marks that must stay
    /// red (the logo), not for UI accents.
    static let brandRed = Color(red: 240 / 255, green: 24 / 255, blue: 34 / 255)
    private static var glowColor: Color { brandRed }

    // MARK: Shapes

    static let cornerSmall: CGFloat = 8
    static let cornerMedium: CGFloat = 12
    static let cornerLarge: CGFloat = 16

    // MARK: Type (SF Pro; tight tracking on large titles in SparkV Red)

    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: isApple ? .bold : .semibold) }
    static func headline(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .regular) }
    static func caption(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .medium) }
    /// Small uppercase label ("SPARKV / AGENTS"), used with `.tracking(1.2)`:
    /// SF Mono in SparkV Red, SF Pro semibold in Apple.
    static func eyebrow(_ size: CGFloat = 9.5) -> Font {
        isApple ? .system(size: size + 0.5, weight: .semibold) : .system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// A filled primary button: system blue in Apple, red in SparkV Red
/// (sparkv.si "Start a Project"). Hover brightens the fill (ease, 150 ms);
/// press darkens it and scales to 0.97 (100 ms in, 160 ms out).
struct SparkVPrimaryButtonStyle: ButtonStyle {
    /// Fill other than the accent, e.g. `SparkVTheme.recording` for Record
    /// and Stop (red in both looks).
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SparkVStyledButtonBody(configuration: configuration, primary: true, tint: tint)
    }
}

/// A secondary button: a grey macOS bordered button in Apple, frosted with a
/// hairline in SparkV Red (sparkv.si "Explore What We Build"). Same hover and
/// press feedback as the primary style.
struct SparkVSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SparkVStyledButtonBody(configuration: configuration, primary: false, tint: nil)
    }
}

/// Shared body for the two filled styles: a view (not a style) so it can own
/// its hover flag without `@State`.
private struct SparkVStyledButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    let tint: Color?
    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let apple = SparkVTheme.isApple
        let pressed = configuration.isPressed
        let hovering = hover.isOn && isEnabled
        let shape = RoundedRectangle(cornerRadius: apple ? 7 : SparkVTheme.cornerSmall, style: .continuous)
        configuration.label
            .font(apple ? .system(size: 12, weight: .medium) : SparkVTheme.headline(12))
            .foregroundStyle(primary ? Color.white : SparkVTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, apple ? 5 : 6)
            .background(shape.fill(fill(apple: apple, pressed: pressed, hovering: hovering)))
            // Hover lifts a filled button a touch, like the macOS default button.
            .overlay(shape.fill(Color.white.opacity(primary && hovering && !pressed ? 0.08 : 0)))
            .overlay(
                Group {
                    if primary {
                        // The faint top highlight macOS puts on default buttons.
                        shape.strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(apple ? 0.22 : 0), Color.white.opacity(0)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5
                        )
                    } else {
                        shape.strokeBorder(apple ? Color.white.opacity(0.06) : SparkVTheme.stroke)
                    }
                }
            )
            .contentShape(shape)
            .scaleEffect(pressed && !SparkVMotion.reduceMotion ? SparkVMotion.pressedScale : 1)
            .animation(SparkVMotion.hover(), value: hovering)
            .animation(
                SparkVMotion.easeOut(pressed ? SparkVMotion.Duration.press : SparkVMotion.Duration.release),
                value: pressed
            )
            .onHover { hover.isOn = $0 }
    }

    private func fill(apple: Bool, pressed: Bool, hovering: Bool) -> AnyShapeStyle {
        if primary {
            let base = tint ?? SparkVTheme.accent
            if pressed { return AnyShapeStyle(apple || tint != nil ? base.opacity(0.78) : SparkVTheme.accentPressed) }
            return AnyShapeStyle(base)
        }
        if pressed { return AnyShapeStyle(apple ? Color.white.opacity(0.24) : SparkVTheme.surfaceHover) }
        if hovering { return AnyShapeStyle(apple ? Color.white.opacity(0.19) : SparkVTheme.surfaceHover) }
        return AnyShapeStyle(apple ? Color.white.opacity(0.14) : SparkVTheme.surface)
    }
}

// MARK: - AppKit window fades

extension CAMediaTimingFunction {
    /// `SparkVMotion.easeOut`'s curve, cubic-bezier(0.23, 1, 0.32, 1), for
    /// `NSAnimationContext` window fades (whose default curve is weaker).
    static var sparkVEaseOut: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    }
}

// MARK: - Staggered entrance

extension View {
    /// One item of a staggered entrance: fades in with a 4 pt rise (strong
    /// ease-out, 180 ms), 40 ms after the item before it (capped at 8), once
    /// `shown` turns on. Hit testing is untouched, so nothing waits on it.
    /// Reduce Motion: a plain fade, no delay.
    func sparkVStaggeredEntrance(_ shown: Bool, index: Int) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || SparkVMotion.reduceMotion ? 0 : 4)
            .animation(
                SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))
                    .delay(shown ? SparkVMotion.stagger(index) : 0),
                value: shown
            )
    }
}
