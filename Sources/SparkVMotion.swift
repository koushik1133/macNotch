import AppKit
import SwiftUI

/// One set of motion tokens for the whole app (Emil Kowalski's rules):
///
/// - Entering / exiting: strong ease-out. Moving on screen: strong ease-in-out.
///   Hover and color: plain ease. Constant motion: linear. Never ease-in.
/// - UI motion stays under 300 ms; drawers and the island may take a spring.
/// - Nothing appears from scale 0: start at 0.96 with opacity 0.
/// - Presses scale to 0.97 fast and release a little slower (asymmetric).
/// - Keyboard-triggered actions don't animate.
/// - Reduce Motion keeps fades and drops movement.
enum SparkVMotion {
    // MARK: Curves

    /// cubic-bezier(0.23, 1, 0.32, 1): strong ease-out for entrances and exits.
    static func easeOut(_ duration: Double = Duration.standard) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    /// cubic-bezier(0.77, 0, 0.175, 1): strong ease-in-out for things that
    /// move or morph on screen (a selection pill sliding between tabs).
    static func easeInOut(_ duration: Double = Duration.standard) -> Animation {
        .timingCurve(0.77, 0, 0.175, 1, duration: duration)
    }

    /// cubic-bezier(0.32, 0.72, 0, 1): the iOS drawer curve, for panels.
    static func drawer(_ duration: Double = Duration.drawer) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }

    /// cubic-bezier(0.25, 0.1, 0.25, 1) (CSS `ease`): hover and color changes.
    static func hover(_ duration: Double = Duration.hover) -> Animation {
        .timingCurve(0.25, 0.1, 0.25, 1, duration: duration)
    }

    /// Apple-style spring for "alive" surfaces (the island, drags): carries
    /// velocity when interrupted. Bounce stays subtle.
    static let island: Animation = .spring(duration: 0.42, bounce: 0.18)
    /// Crisper spring for small interruptible state (toggles, chips).
    static let snappy: Animation = .spring(duration: 0.28, bounce: 0.1)

    // MARK: Durations (seconds)

    enum Duration {
        /// Press-down feedback.
        static let press: Double = 0.1
        /// Press release (a touch slower than the press).
        static let release: Double = 0.16
        /// Hover fills and tint changes.
        static let hover: Double = 0.15
        /// Tooltips, small popovers, chips.
        static let small: Double = 0.18
        /// Dropdowns, bands, content swaps.
        static let standard: Double = 0.22
        /// Drawers and windows.
        static let drawer: Double = 0.32
        /// Gap between items in a staggered entrance.
        static let stagger: Double = 0.04
    }

    // MARK: Values

    /// Scale a pressed control shrinks to.
    static let pressedScale: CGFloat = 0.97
    /// Scale an entering element starts from (never 0).
    static let enterScale: CGFloat = 0.96

    // MARK: Reduce Motion

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `animation`, or a short fade-friendly ease when Reduce Motion is on.
    static func respecting(_ animation: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : animation
    }

    /// Staggered delay for the item at `index` (capped so long lists don't drag).
    static func stagger(_ index: Int, cap: Int = 8) -> Double {
        reduceMotion ? 0 : Double(min(index, cap)) * Duration.stagger
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// Fade in from 96 % with a small rise; reverse on exit. Reduce Motion: fade only.
    static var sparkVEnter: AnyTransition {
        if SparkVMotion.reduceMotion { return .opacity }
        return .opacity
            .combined(with: .scale(scale: SparkVMotion.enterScale, anchor: .top))
            .combined(with: .offset(y: -4))
    }

    /// Fade with a light blur: hides the double exposure of a crossfade.
    static var sparkVCrossfade: AnyTransition {
        .modifier(active: SparkVBlurFade(amount: 1), identity: SparkVBlurFade(amount: 0))
    }
}

private struct SparkVBlurFade: ViewModifier {
    var amount: Double
    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: SparkVMotion.reduceMotion ? 0 : 2 * amount)
    }
}

// MARK: - Press feedback

/// Any pressable: shrinks to 0.97 quickly, springs back a little slower.
struct SparkVPressStyle: ButtonStyle {
    var scale: CGFloat = SparkVMotion.pressedScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !SparkVMotion.reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(
                SparkVMotion.easeOut(configuration.isPressed ? SparkVMotion.Duration.press : SparkVMotion.Duration.release),
                value: configuration.isPressed
            )
    }
}

extension View {
    /// Soft hover fill for icon buttons and rows (ease, 150 ms).
    func sparkVHoverFill(_ hovering: Bool, cornerRadius: CGFloat = 8) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(SparkVTheme.hoverFill.opacity(hovering ? 1 : 0))
        )
        .animation(SparkVMotion.hover(), value: hovering)
    }
}
