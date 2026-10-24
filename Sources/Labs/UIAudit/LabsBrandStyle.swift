import AppKit
import SwiftUI

// Small brand helpers shared by the lab windows and drawer tabs (UI Audit,
// Job Agent, Browser Flows, Flow Canvas, Prompt Refiner, Screen Region,
// Screen Recorder, Reply Drafter). Colors, radii and type come from
// SparkVTheme; these only package the recurring combinations.

enum LabsBrand {
    /// Dark chrome for a lab NSWindow / NSPanel: forced dark appearance and
    /// the look's window ground behind the SwiftUI content. The ground
    /// follows later changes of the look (gear menu > Appearance).
    @MainActor
    static func styleWindow(_ window: NSWindow, opaque: Bool = true) {
        window.appearance = NSAppearance(named: .darkAqua)
        guard opaque else { return }
        window.backgroundColor = NSColor(SparkVTheme.background)
        NotificationCenter.default.addObserver(forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                window?.backgroundColor = NSColor(SparkVTheme.background)
            }
        }
    }
}

/// Lab colors that differ by look beyond the shared SparkVTheme tokens. In
/// Apple each feature gets back the system tint it had before the sparkv.si
/// restyle; in SparkV Red every one of them is the brand red, as today.
enum LabsTint {
    /// AI / agent feature glyphs (UI Audit, Prompt Refiner, Clicky-style
    /// sparkles): cyan in Apple.
    static var feature: Color { SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.brandRed) }
    /// Soft wash behind a feature glyph.
    static var featureSoft: Color { SparkVTheme.choose(apple: Color.cyan.opacity(0.15), sparkv: SparkVTheme.redSoft) }
    /// Selected row / tab / chip wash: neutral white in Apple.
    static var selectionFill: Color { SparkVTheme.activeTabFill }
    /// Hairline on a selected row / tab (none in Apple).
    static var selectionStroke: Color { SparkVTheme.activeTabStroke }
    /// Error and failure text: soft coral in Apple (readable on dark),
    /// brand red in SparkV Red.
    static var errorText: Color { SparkVTheme.choose(apple: Color(red: 1, green: 0.62, blue: 0.55), sparkv: SparkVTheme.brandRed) }
    /// Determinate / indeterminate progress tint.
    static var progress: Color { SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.brandRed) }
}

extension View {
    /// Root of a lab window: the look's ground, dark scheme, the accent
    /// (system blue / brand red) as the control tint; redrawn when the look
    /// changes.
    func labsWindowRoot() -> some View {
        AppearanceRoot {
            self
                .background(SparkVTheme.background)
                .environment(\.colorScheme, .dark)
                .tint(SparkVTheme.accent)
        }
    }

    /// Raised card: white 6 % fill and a white 10 % hairline.
    func labsCard(_ radius: CGFloat = SparkVTheme.cornerMedium, fill: Color = SparkVTheme.surface, stroke: Color = SparkVTheme.stroke) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke))
    }

    /// Plain text-field well used in the compact drawer tabs.
    func labsFieldWell(_ radius: CGFloat = SparkVTheme.cornerSmall, focused: Bool = false) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(SparkVTheme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? SparkVTheme.accent.opacity(0.7) : SparkVTheme.stroke)
            )
    }
}

/// Small uppercase section label. SparkV Red: the sparkv.si eyebrow, a
/// short red dash and a monospaced label ("— LIVE LOG"). Apple: a plain
/// SF Pro semibold label, as macOS section headers are.
struct LabsEyebrow: View {
    let text: String
    var color: Color = SparkVTheme.textSecondary

    init(_ text: String, color: Color = SparkVTheme.textSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: 6) {
            if !SparkVTheme.isApple {
                Capsule().fill(SparkVTheme.eyebrowDash).frame(width: 10, height: 2)
            }
            Text(text.uppercased())
                .font(SparkVTheme.eyebrow())
                .tracking(1.2)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

/// Small filled pill for counts and "new" badges (system red in Apple, as
/// macOS badges are; brand red in SparkV Red).
struct LabsBadge: View {
    let text: String
    var fill: Color = SparkVTheme.destructive

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .background(Capsule().fill(fill))
    }
}

/// SparkVPrimaryButtonStyle that also dims when disabled (the theme styles
/// draw the same either way) and gives press feedback.
struct LabsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabsEnabledDimmer(content: SparkVPrimaryButtonStyle().makeBody(configuration: configuration), isPressed: configuration.isPressed)
    }
}

/// SparkVSecondaryButtonStyle that also dims when disabled and gives press
/// feedback.
struct LabsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabsEnabledDimmer(content: SparkVSecondaryButtonStyle().makeBody(configuration: configuration), isPressed: configuration.isPressed)
    }
}

/// Emil: a pressed button shrinks to 0.97 in 100 ms and releases in 160 ms
/// (strong ease-out, asymmetric). Disabled buttons don't move; Reduce
/// Motion keeps only the fill change the theme style already draws.
private struct LabsEnabledDimmer<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let content: Content
    var isPressed = false

    var body: some View {
        let pressed = isPressed && isEnabled && !SparkVMotion.reduceMotion
        content
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(pressed ? SparkVMotion.pressedScale : 1)
            .animation(
                SparkVMotion.easeOut(isPressed ? SparkVMotion.Duration.press : SparkVMotion.Duration.release),
                value: isPressed
            )
    }
}

extension AnyTransition {
    /// Bottom toast / message pill in a lab window: fades in from 96 % with
    /// a 6 pt rise from its bottom edge, reverses on exit (pair with
    /// `SparkVMotion.easeOut()`). Reduce Motion: fade only.
    static var labsToastRise: AnyTransition {
        if SparkVMotion.reduceMotion { return .opacity }
        return .opacity
            .combined(with: .scale(scale: SparkVMotion.enterScale, anchor: .bottom))
            .combined(with: .offset(y: 6))
    }
}

