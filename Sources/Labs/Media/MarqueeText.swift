import AppKit
import SwiftUI

/// One line of text that scrolls when it doesn't fit, like the Dynamic
/// Island and Apple Music's now-playing title: it rests at the start, glides
/// left at a steady speed, and wraps seamlessly into a second copy, then
/// rests again. Text that fits is drawn still. While it scrolls, both edges
/// fade softly and the text never leaves its own frame (it can't slide under
/// a neighbour such as the album art).
///
/// The width is measured with AppKit (the same CoreText shaping SwiftUI
/// uses), so the decision is made in a single layout pass; that keeps long
/// Telugu, Devanagari or CJK titles from being cut to "…".
struct MarqueeText: View {
    let text: String
    let font: NSFont
    var color: Color = .white
    /// Scroll speed in points per second.
    var speed: CGFloat = 30
    /// Rest at the start of every cycle, in seconds.
    var pause: TimeInterval = 2
    /// Space between the end of the text and the next copy.
    var gap: CGFloat = 32
    var fadeWidth: CGFloat = 14
    /// False keeps the text still (and truncated), e.g. while the drawer animates.
    var isActive = true
    /// Fixed time into the animation, for offscreen renders and tests.
    var previewElapsed: TimeInterval? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var clock = MarqueeClock()
    @ObservedObject private var energy = SparkVEnergy.shared

    var body: some View {
        let width = Self.textWidth(text, font: font)
        GeometryReader { geometry in
            let available = geometry.size.width
            let scrolls = isActive && !reduceMotion && !energy.pausesDecoration && width > available + 0.5
            Group {
                if scrolls {
                    TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 30))) { context in
                        let offset = Self.offset(
                            elapsed: previewElapsed ?? context.date.timeIntervalSince(clock.start(for: text, now: context.date)),
                            textWidth: width, gap: gap, speed: speed, pause: pause
                        )
                        HStack(spacing: gap) {
                            label
                            label
                        }
                        .fixedSize()
                        .offset(x: -offset)
                        .frame(width: available, height: geometry.size.height, alignment: .leading)
                        .compositingGroup()
                        // Soft fade on both edges; the mask is exactly the
                        // column's width, so nothing draws outside it.
                        .mask(fadeMask(width: available, height: geometry.size.height))
                    }
                } else {
                    Text(text)
                        .font(Font(font as CTFont))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: available, alignment: .leading)
                }
            }
            .frame(width: available, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: Self.lineHeight(font))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(Font(font as CTFont))
            .foregroundStyle(color)
            .fixedSize()
    }

    /// A horizontal gradient that fades both edges over `fadeWidth`, sized
    /// to the column. It is taller than the line (centered on it) so tall
    /// scripts' vowel signs aren't clipped vertically.
    private func fadeMask(width: CGFloat, height: CGFloat) -> some View {
        let edge = width > 0 ? min(0.45, fadeWidth / width) : 0
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: edge),
                .init(color: .black, location: 1 - edge),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width, height: height + 16)
        .frame(width: width, height: height)
    }

    // MARK: Geometry (pure, for tests)

    /// Horizontal scroll offset `elapsed` seconds into the animation:
    /// rest for `pause`, then move one text-plus-gap width, then repeat.
    /// At the end of a cycle the second copy sits exactly where the first
    /// started, so the wrap is invisible.
    static func offset(elapsed: TimeInterval, textWidth: CGFloat, gap: CGFloat, speed: CGFloat, pause: TimeInterval) -> CGFloat {
        guard speed > 0, textWidth > 0, elapsed > 0 else { return 0 }
        let distance = Double(textWidth + gap)
        let velocity = Double(speed)
        // Speed ramps up and down over `ramp` seconds at each end, so the
        // start and stop don't jolt. Travel time grows by `ramp` for it.
        let ramp = min(0.4, distance / velocity)
        let travel = distance / velocity + ramp
        let cycle = pause + travel
        let t = elapsed.truncatingRemainder(dividingBy: cycle) - pause
        guard t > 0 else { return 0 }
        let covered: Double
        if t < ramp {
            covered = velocity * t * t / (2 * ramp)
        } else if t < travel - ramp {
            covered = velocity * ramp / 2 + velocity * (t - ramp)
        } else {
            let left = travel - t
            covered = distance - velocity * left * left / (2 * ramp)
        }
        return CGFloat(min(distance, max(0, covered)))
    }

    /// Length of one rest-and-scroll cycle, in seconds.
    static func cycleDuration(textWidth: CGFloat, gap: CGFloat, speed: CGFloat, pause: TimeInterval) -> TimeInterval {
        let distance = Double(textWidth + gap)
        return pause + distance / Double(speed) + min(0.4, distance / Double(speed))
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.width)
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 1
    }
}

/// When the current text started scrolling; resets when the text changes,
/// so every new title begins at rest. Not published: the TimelineView
/// redraws on its own.
@MainActor
final class MarqueeClock: ObservableObject {
    private var text: String?
    private var started = Date()

    func start(for text: String, now: Date) -> Date {
        if text != self.text {
            self.text = text
            started = now
        }
        return started
    }
}
