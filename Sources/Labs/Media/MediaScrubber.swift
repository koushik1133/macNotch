import AppKit
import SwiftUI

/// "1:23", "12:05" or "1:02:09" for a playback position.
enum MediaTimeFormat {
    static func string(_ seconds: TimeInterval, hours: Bool = false) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if hours || h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Remaining time with a leading minus, rounded up like Apple Music does,
    /// so elapsed + remaining always adds up to the length.
    static func remaining(_ seconds: TimeInterval, hours: Bool = false) -> String {
        "-" + string(max(0, seconds).rounded(.up), hours: hours)
    }
}

/// Hover and drag state of one scrubber.
@MainActor
final class ScrubberInteraction: ObservableObject {
    @Published var isHovering = false
    /// 0...1 while the knob is being dragged, nil otherwise.
    @Published var dragFraction: Double?
}

/// Thin progress line under the track info that turns into a slider on
/// hover (Dynamic Island / NotchNook style): the bar thickens, a knob
/// appears and dragging or clicking seeks. Bookmarks show as ticks; a click
/// near one, or a drag that passes close to it, snaps to it exactly.
///
/// Position is interpolated from `MediaEngine.timing` in a 30 fps
/// `TimelineView` that pauses with playback, so nothing republishes per frame.
struct MediaScrubber: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject var bookmarks: MediaBookmarkStore
    /// Fill color of the elapsed part.
    var tint: Color = .white
    var showsLabels = true
    /// Fixed clock for offscreen renders and tests.
    var previewDate: Date? = nil
    /// Forces the hover look (offscreen renders).
    var previewHover = false

    @StateObject private var interaction = ScrubberInteraction()

    static let idleBarHeight: CGFloat = 3
    static let activeBarHeight: CGFloat = 5
    static let knobSize: CGFloat = 9
    /// Ticks within this many points of the pointer catch it.
    static let snapDistance: CGFloat = 6
    static let height: CGFloat = 14

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    var body: some View {
        let timing = media.timing
        let ticks = bookmarks.bookmarks(forTrack: media.trackKey).map(\.position)
        let animating = previewDate == nil && timing.rate > 0 && interaction.dragFraction == nil
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            let now = previewDate ?? context.date
            let live = timing.position(at: now)
            let position = interaction.dragFraction.map { $0 * timing.duration } ?? live
            content(timing: timing, position: position, ticks: ticks)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValue(timing: timing))
        .accessibilityAdjustableAction { direction in
            guard media.canSeek else { return }
            switch direction {
            case .increment: media.skip(by: 10)
            case .decrement: media.skip(by: -10)
            @unknown default: break
            }
        }
    }

    private func accessibilityValue(timing: PlaybackTiming) -> String {
        guard timing.isKnown else { return media.isPlaying ? "Live" : "" }
        let now = previewDate ?? Date()
        let hours = timing.duration >= 3600
        return "\(MediaTimeFormat.string(timing.position(at: now), hours: hours)) of \(MediaTimeFormat.string(timing.duration, hours: hours))"
    }

    @ViewBuilder
    private func content(timing: PlaybackTiming, position: TimeInterval, ticks: [TimeInterval]) -> some View {
        let active = (interaction.isHovering || previewHover || interaction.dragFraction != nil) && media.canSeek
        let hours = timing.duration >= 3600
        // Sized for the widest remaining time ("-8:88:88"), so labels never truncate.
        let labelWidth = MarqueeText.textWidth(hours ? "-8:88:88" : "-88:88", font: Self.labelFont) + 1
        let labelColor = Color.white.opacity(active ? 0.8 : 0.45)

        HStack(spacing: 6) {
            if showsLabels {
                Text(timing.isKnown || position > 0 ? MediaTimeFormat.string(position, hours: hours) : "")
                    .font(Font(Self.labelFont as CTFont))
                    .foregroundStyle(labelColor)
                    .frame(width: labelWidth, alignment: .leading)
            }
            bar(timing: timing, position: position, ticks: ticks, active: active)
            if showsLabels {
                Text(trailingLabel(timing: timing, position: position, hours: hours))
                    .font(Font(Self.labelFont as CTFont))
                    .foregroundStyle(labelColor)
                    .frame(width: labelWidth, alignment: .trailing)
            }
        }
        // Hover thickens the bar and brings in the knob: strong ease-out, 180 ms.
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: active)
    }

    private func trailingLabel(timing: PlaybackTiming, position: TimeInterval, hours: Bool) -> String {
        if timing.isKnown { return MediaTimeFormat.remaining(timing.duration - position, hours: hours) }
        return media.isPlaying && media.source != .none ? "LIVE" : ""
    }

    private func bar(timing: PlaybackTiming, position: TimeInterval, ticks: [TimeInterval], active: Bool) -> some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let fraction = timing.isKnown ? min(1, max(0, position / timing.duration)) : 0
            let barHeight = active ? Self.activeBarHeight : Self.idleBarHeight
            let midY = geometry.size.height / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(timing.isKnown ? 0.2 : 0.1))
                    .frame(width: width, height: barHeight)

                Capsule()
                    .fill(tint)
                    .frame(width: max(barHeight, width * fraction), height: barHeight)
                    .opacity(timing.isKnown ? 1 : 0)

                if timing.isKnown {
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        let x = width * min(1, max(0, tick / timing.duration))
                        Capsule()
                            .fill(tick <= position ? Color.black.opacity(0.55) : Color.white.opacity(0.9))
                            .frame(width: 2, height: barHeight + 4)
                            .shadow(color: .black.opacity(0.4), radius: 0.5)
                            .position(x: min(max(1, x), width - 1), y: midY)
                    }
                }

                if active {
                    Circle()
                        .fill(Color.white)
                        .frame(width: Self.knobSize, height: Self.knobSize)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .position(x: min(max(Self.knobSize / 2, width * fraction), width - Self.knobSize / 2), y: midY)
                        // Grows out of the bar's own thickness (5 of 9 pt),
                        // not from a dot; fade only under Reduce Motion.
                        .transition(SparkVMotion.reduceMotion
                            ? .opacity
                            : .scale(scale: Self.activeBarHeight / Self.knobSize).combined(with: .opacity))
                }
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onHover { interaction.isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard media.canSeek else { return }
                        let fraction = Self.fraction(
                            atX: value.location.x, width: width, duration: timing.duration, ticks: ticks
                        )
                        if interaction.dragFraction == nil {
                            // A click jumps the knob with a quick ease-out;
                            // the drag that may follow tracks the pointer 1:1
                            // and retargets that motion at once.
                            withAnimation(SparkVMotion.reduceMotion ? nil : SparkVMotion.easeOut(SparkVMotion.Duration.hover)) {
                                interaction.dragFraction = fraction
                            }
                        } else {
                            interaction.dragFraction = fraction
                        }
                    }
                    .onEnded { value in
                        guard media.canSeek else { return }
                        let target = Self.fraction(atX: value.location.x, width: width, duration: timing.duration, ticks: ticks)
                        media.seek(to: target * timing.duration)
                        interaction.dragFraction = nil
                    }
            )
            .help(media.canSeek ? "Drag to seek" : "")
        }
    }

    /// Pointer x to 0...1, snapping to a bookmark tick within `snapDistance`.
    static func fraction(atX x: CGFloat, width: CGFloat, duration: TimeInterval, ticks: [TimeInterval]) -> Double {
        guard width > 0 else { return 0 }
        let raw = Double(min(max(0, x / width), 1))
        guard duration > 0 else { return raw }
        let nearest = ticks
            .map { min(1, max(0, $0 / duration)) }
            .min { abs($0 - raw) < abs($1 - raw) }
        if let nearest, abs(nearest - raw) * Double(width) <= Double(snapDistance) {
            return nearest
        }
        return raw
    }
}
