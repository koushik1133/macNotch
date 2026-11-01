import AppKit
import SwiftUI

/// Expanded live activity: the band that grows out of the notch while the
/// drawer is closed, the way the Dynamic Island expands. Dictation while you
/// talk, otherwise Clicky while it listens, thinks or answers, otherwise the
/// `ActivityCenter` activity that currently owns the band. Dictation wins
/// when both are busy, which only happens briefly since they share the
/// microphone.
struct NotchActivityView: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var clicky: ClickyController
    @EnvironmentObject private var activities: ActivityCenter

    var body: some View {
        // One band replacing another crossfades with a light blur (Sonner-like
        // swap, interruptible). Key-driven owners (the HUD, dictation, Clicky)
        // swap instantly: they repeat many times a day.
        ZStack {
            if dictation.phase != .idle {
                DictationActivityView()
                    .transition(.sparkVCrossfade)
            } else if clicky.phase != .idle {
                ClickyActivityView()
                    .transition(.sparkVCrossfade)
            } else if let activity = activities.current {
                // HUDs, battery, timer, meetings and notifications.
                activity.view()
                    .padding(.horizontal, 16)
                    // A re-post of the band's own activity (or a new owner)
                    // rebuilds it; unrelated posts leave its hover and press
                    // state alone.
                    .id(activities.bandRevision)
                    .transition(.sparkVCrossfade)
            }
        }
        .animation(swapAnimation, value: owner)
    }

    /// Who draws in the band; a change of owner is a band swap.
    private var owner: String {
        if dictation.phase != .idle { return "dictation" }
        if clicky.phase != .idle { return "clicky" }
        return activities.current?.id ?? ""
    }

    private var swapAnimation: Animation? {
        guard dictation.phase == .idle, clicky.phase == .idle,
              let activity = activities.current, !activity.kind.isLiveFeedback
        else { return nil }
        return SparkVMotion.respecting(SparkVMotion.easeOut())
    }

    /// Height of the band below the notch, or nil when nothing is expanded.
    static func bandHeight(dictation: DictationController, clicky: ClickyController, activities: ActivityCenter) -> CGFloat? {
        if dictation.phase != .idle { return NotchMetrics.activityBandHeight }
        switch clicky.phase {
        case .idle: return activities.current?.height
        case .answering: return NotchMetrics.activityAnswerBandHeight
        case .listening, .thinking, .failed: return NotchMetrics.activityBandHeight
        }
    }

    /// True while dictation or Clicky draws in the band.
    static func isBandHeld(dictation: DictationController, clicky: ClickyController) -> Bool {
        dictation.phase != .idle || clicky.phase != .idle
    }

    /// What the wings beside the camera housing show, if anything. Now
    /// Playing posted as a live activity (`NowPlayingActivityBridge`) keeps
    /// its own wings (artwork, title, level bars, album glow).
    static func wingsSource(activities: ActivityCenter, media: MediaEngine) -> IslandWingsSource? {
        if let compact = activities.compact {
            return compact.kind == .media && media.isShowingClosedActivity ? .nowPlaying : .activity
        }
        // Music peeking in the band already shows itself there.
        if activities.current?.kind == .media { return nil }
        if media.isShowingClosedActivity { return .nowPlaying }
        return nil
    }

    /// Geometry of the closed island, or nil when it rests at the notch.
    /// Shared by the view and the window controller's hover hot zone.
    static func closedLayout(
        resting: CGSize,
        dictation: DictationController,
        clicky: ClickyController,
        activities: ActivityCenter,
        media: MediaEngine
    ) -> IslandClosedLayout? {
        let band = bandHeight(dictation: dictation, clicky: clicky, activities: activities)
        let wings = wingsSource(activities: activities, media: media)
        guard band != nil || wings != nil else { return nil }
        return .make(resting: resting, band: band, wings: wings == nil ? nil : activities.measuredWings)
    }
}

enum IslandWingsSource: Equatable {
    /// `ActivityCenter.compact`.
    case activity
    /// Artwork and a title marquee while music plays.
    case nowPlaying
}

// MARK: - Closed island

/// Everything the closed island draws: the compact wings beside the camera
/// housing (inside the menu-bar height) and, when expanded, the band under
/// the notch.
struct ClosedIslandContent: View {
    @EnvironmentObject private var activities: ActivityCenter
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var clicky: ClickyController
    @EnvironmentObject private var media: MediaEngine
    let layout: IslandClosedLayout
    let restingHeight: CGFloat
    let source: IslandWingsSource?

    var body: some View {
        ZStack(alignment: .top) {
            if let source {
                IslandWingsRow(layout: layout, height: restingHeight, source: source)
                    .transition(.opacity)
            }
            if let band = layout.band {
                NotchActivityView()
                    .frame(height: band)
                    .padding(.top, restingHeight)
                    .transition(bandTransition)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        // One VoiceOver element for wings and band, unless the band has its
        // own buttons (or dictation / Clicky speak for themselves).
        .accessibilityElement(children: readsChildren ? .contain : .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var readsChildren: Bool {
        if NotchActivityView.isBandHeld(dictation: dictation, clicky: clicky) { return true }
        return layout.band != nil && activities.current?.isInteractive == true
    }

    /// The band's activity, then the wings', then the minimal icons'.
    private var accessibilityLabel: String {
        var parts: [String] = []
        var seen: Set<String> = []
        for activity in [activities.current, activities.compact, activities.secondary, activities.tertiary].compactMap({ $0 }) {
            guard seen.insert(activity.id).inserted else { continue }
            if activity.kind == .media {
                parts.append(NowPlayingAccessibility.label(media))
            } else {
                parts.append(activity.resolvedAccessibilityText)
            }
        }
        if source == .nowPlaying, !seen.contains(where: { activities.activity(id: $0)?.kind == .media }) {
            parts.append(NowPlayingAccessibility.label(media))
        }
        return parts.isEmpty ? "SparkV" : parts.joined(separator: ". ")
    }

    /// The band grows out of the notch: 96 % + fade, anchored at the top.
    /// Key-driven bands (volume / brightness HUD, hold-to-talk dictation and
    /// Clicky) only fade, so they feel instant.
    private var bandTransition: AnyTransition {
        if NotchActivityView.isBandHeld(dictation: dictation, clicky: clicky) { return .opacity }
        if let activity = activities.current, activity.kind.isLiveFeedback { return .opacity }
        return .sparkVEnter
    }
}

/// Compact content swapping in the wings: blur-masked fade from 90 % (never
/// from a speck). Reduce Motion: fade only.
private var wingSwapTransition: AnyTransition {
    if SparkVMotion.reduceMotion { return .opacity }
    return AnyTransition.sparkVCrossfade.combined(with: .scale(scale: 0.9))
}

/// Leading content right of the left wing's edge, trailing content left of
/// the right wing's, the housing in between. Content keeps its intrinsic
/// size; its width is measured and reported so the island fits it.
private struct IslandWingsRow: View {
    @EnvironmentObject private var activities: ActivityCenter
    @EnvironmentObject private var media: MediaEngine
    /// Menu bar room for the wings (Labs/IslandInteraction).
    @ObservedObject private var wingRoom = IslandWingRoom.shared
    let layout: IslandClosedLayout
    let height: CGFloat
    let source: IslandWingsSource

    var body: some View {
        HStack(spacing: 0) {
            leading
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    report(leading: width)
                }
                .padding(.trailing, NotchMetrics.wingInnerPadding)
                .frame(width: layout.leadingWing, height: height, alignment: .trailing)
                .islandWingFit(content: activities.measuredWings.leading, wing: layout.leadingWing, edge: .leading)
            Color.clear
                .frame(width: NotchMetrics.cameraHousingWidth, height: height)
            trailing
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    report(trailing: width)
                }
                .padding(.leading, NotchMetrics.wingInnerPadding)
                .frame(width: layout.trailingWing, height: height, alignment: .leading)
                .islandWingFit(content: activities.measuredWings.trailing, wing: layout.trailingWing, edge: .trailing)
        }
        .frame(height: height)
        .accessibilityElement(children: .combine)
    }

    private func report(leading: CGFloat? = nil, trailing: CGFloat? = nil) {
        var wings = activities.measuredWings
        if let leading { wings.leading = leading }
        if let trailing { wings.trailing = trailing }
        activities.reportWings(wings)
    }

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: 7) {
            // A third running activity rides on the left, mirrored.
            if let third = activities.tertiary {
                MinimalActivityView(activity: third)
                    .id(third.id)
                    .transition(wingSwapTransition)
            }
            switch source {
            case .activity:
                if let activity = activities.compact {
                    CompactLeadingView(activity: activity)
                        .id(activity.id)
                        .transition(wingSwapTransition)
                }
            case .nowPlaying:
                NowPlayingCompactLeading()
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch source {
        case .activity:
            if let activity = activities.compact {
                HStack(spacing: 7) {
                    // Leave room for the minimal icon inside the widest wing.
                    CompactTrailingView(
                        activity: activity,
                        maxTextWidth: min(activities.secondary == nil
                            ? CompactTrailingView.textWidth
                            : CompactTrailingView.textWidthBesideMinimal,
                            wingRoom.trailingTextRoom(besideMinimal: activities.secondary != nil))
                    )
                    if let other = activities.secondary {
                        MinimalActivityView(activity: other)
                            .transition(wingSwapTransition)
                    }
                }
                .id(activity.id)
                .transition(wingSwapTransition)
            }
        case .nowPlaying:
            HStack(spacing: 7) {
                NowPlayingCompactTrailing(besideMinimal: minimalBesideNowPlaying != nil)
                if let other = minimalBesideNowPlaying {
                    MinimalActivityView(activity: other)
                        .id(other.id)
                        .transition(wingSwapTransition)
                }
            }
        }
    }

    /// While music has the wings, the next running activity (the media
    /// activity itself excluded) rides beside the level bars.
    private var minimalBesideNowPlaying: LiveActivity? {
        guard let other = activities.secondary, other.kind != .media else { return nil }
        return other
    }
}

// MARK: Compact and minimal forms

/// The activity's own compact leading view, or its symbol.
struct CompactLeadingView: View {
    let activity: LiveActivity

    var body: some View {
        Group {
            if let leading = activity.compactLeading {
                leading()
            } else {
                Image(systemName: activity.resolvedSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activity.resolvedTint)
            }
        }
        .frame(height: 22)
    }
}

/// The activity's own compact trailing view, its short text, or a dot.
struct CompactTrailingView: View {
    let activity: LiveActivity
    var maxTextWidth: CGFloat = Self.textWidth

    /// Room for content in the widest wing (112 pt less both paddings).
    static let textWidth = NotchMetrics.maxWingWidth - NotchMetrics.wingInnerPadding - NotchMetrics.wingOuterPadding - 10
    /// The same less a minimal icon (18 pt) and its 7 pt gap.
    static let textWidthBesideMinimal = textWidth - 25

    var body: some View {
        Group {
            if let trailing = activity.compactTrailing {
                // Custom views get the same room as text (a few points of
                // slack for a glyph), so a crowded wing never outgrows
                // the island's widest wing.
                trailing()
                    .frame(maxWidth: maxTextWidth + 10, alignment: .leading)
                    .clipped()
            } else if let text = activity.compactText {
                Text(text)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(activity.tint ?? SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxTextWidth, alignment: .leading)
            } else {
                Circle()
                    .fill(activity.resolvedTint)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(height: 22)
    }
}

/// Single icon for a second activity sharing the wings.
struct MinimalActivityView: View {
    let activity: LiveActivity

    var body: some View {
        Group {
            if let minimal = activity.minimal {
                minimal()
            } else {
                Image(systemName: activity.resolvedSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(activity.resolvedTint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(SparkVTheme.surfaceHover))
            }
        }
        .frame(height: 22)
    }
}

// MARK: Compact now playing

/// What VoiceOver reads for music in the closed island.
@MainActor
enum NowPlayingAccessibility {
    static func label(_ media: MediaEngine) -> String {
        let artist = media.artist.trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? "Now playing: \(media.title)" : "Now playing: \(media.title) by \(artist)"
    }
}

/// Artwork (or the player's icon) left of the camera housing.
struct NowPlayingCompactLeading: View {
    @EnvironmentObject private var media: MediaEngine
    /// Compact Now Playing, or too little menu bar room (Labs/IslandInteraction).
    @ObservedObject private var wingRoom = IslandWingRoom.shared

    var body: some View {
        if !wingRoom.compactNowPlaying {
            artwork
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityLabel("Now playing: \(media.title)")
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = media.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let icon = media.sourceIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                SparkVTheme.surfaceHover
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
        }
    }
}

/// Bouncing level bars right of the housing. When the track changes, its
/// title scrolls past in a tiny marquee for a few seconds (a sneak peek),
/// then the wing slims back to the bars so it covers less of the menu bar.
/// Settings › Activities › Timing sets how long, how wide, or always.
struct NowPlayingCompactTrailing: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var timing = ActivityTimingSettings.shared
    @StateObject private var peek = TrackTitlePeek()
    @ObservedObject private var wingRoom = IslandWingRoom.shared
    /// A minimal icon shares the wing: the title gets less room.
    var besideMinimal = false

    var body: some View {
        let width = ActivityTimingSettings.titleWidth(timing.titleWidth.points, besideMinimal: besideMinimal)
        // Beside another activity's icon the title only shows when the user
        // asked for it always; a few clipped letters are no title.
        // Compact Now Playing (Labs/IslandInteraction): only the level bars.
        let showsTitle = !wingRoom.compactNowPlaying && TrackTitlePolicy.showsTitle(
            peeking: peek.showsTitle, always: timing.alwaysShowTitle, besideMinimal: besideMinimal, width: width
        )
        HStack(spacing: 6) {
            if showsTitle {
                CompactMarquee(text: media.title, maxWidth: width, isAnimating: media.isPlaying)
                    .transition(.opacity)
            }
            MediaLiveLevelBars(isAnimating: media.isPlaying)
                .frame(width: 14, height: 13)
        }
        .animation(NotchMetrics.hoverAnimation, value: showsTitle)
        .onAppear { peek.update(title: media.title, for: timing.titlePeekSeconds) }
        .onChange(of: media.title) { _, title in peek.update(title: title, for: timing.titlePeekSeconds) }
    }
}

/// Shows the title for a while (default `NotchMetrics.nowPlayingTitlePeek`)
/// after it changes.
@MainActor
final class TrackTitlePeek: ObservableObject {
    @Published private(set) var showsTitle = false
    private var title: String?
    private var hideTask: Task<Void, Never>?

    func update(title newTitle: String, for seconds: TimeInterval? = nil) {
        guard newTitle != title else { return }
        title = newTitle
        showsTitle = true
        hideTask?.cancel()
        let delay: Duration = seconds.map { .milliseconds(Int($0 * 1000)) } ?? NotchMetrics.nowPlayingTitlePeek
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.showsTitle = false
        }
    }
}

/// One line of small text that, when it doesn't fit `maxWidth`, rests,
/// glides left and wraps into a second copy. Fits: drawn still.
struct CompactMarquee: View {
    let text: String
    let maxWidth: CGFloat
    var isAnimating = true
    var font: NSFont = .systemFont(ofSize: 11, weight: .medium)
    var color: Color = .white.opacity(0.78)
    /// Fixed time into the animation, for offscreen renders.
    var previewElapsed: TimeInterval?

    private static let gap: CGFloat = 24
    private static let speed: CGFloat = 22
    private static let pause: TimeInterval = 1.6
    /// Scroll a new title this many times, then rest on its start: an
    /// always-shown title doesn't redraw for the hours a song plays.
    private static let cycles = 3
    @ObservedObject private var energy = SparkVEnergy.shared
    @StateObject private var clock = CompactMarqueeClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = Self.width(of: text, font: font)
        let scrolls = width > maxWidth + 0.5
        let box = min(width, maxWidth)
        Group {
            // Reduce Motion: the still, faded title (no scroll at all).
            if scrolls, !reduceMotion || previewElapsed != nil {
                let moving = isAnimating && !energy.pausesDecoration && !clock.finished
                TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 30), paused: !moving)) { context in
                    // Paused: rest at the start rather than freeze mid-glide.
                    let elapsed = previewElapsed ?? (moving ? context.date.timeIntervalSinceReferenceDate - clock.start : 0)
                    let offset = Self.offset(elapsed: elapsed, textWidth: width)
                    HStack(spacing: Self.gap) {
                        label
                        label
                    }
                    .fixedSize()
                    .offset(x: -offset)
                    .frame(width: box, alignment: .leading)
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: offset > 0.5 ? 6 : 0)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 8)
                        }
                    )
                }
            } else if scrolls {
                label
                    .frame(width: box, alignment: .leading)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 8)
                        }
                    )
            } else {
                label
            }
        }
        .frame(width: box, height: 14, alignment: .leading)
        .clipped()
        .onAppear { restartClock(width: width) }
        .onChange(of: text) { _, _ in restartClock(width: Self.width(of: text, font: font)) }
    }

    private func restartClock(width: CGFloat) {
        let distance = Double(width + Self.gap)
        clock.restart(after: Double(Self.cycles) * (Self.pause + distance / Double(Self.speed)))
    }

    private var label: some View {
        Text(text)
            .font(Font(font as CTFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Rest for `pause`, then move one text-plus-gap width; repeat.
    static func offset(elapsed: TimeInterval, textWidth: CGFloat) -> CGFloat {
        let distance = Double(textWidth + gap)
        let cycle = pause + distance / Double(speed)
        let t = elapsed.truncatingRemainder(dividingBy: cycle) - pause
        guard t > 0 else { return 0 }
        return CGFloat(min(distance, t * Double(speed)))
    }
}

/// Four bars that bounce while playing. A coarse 4 Hz timeline with eased
/// steps keeps the closed island cheap to draw.
struct CompactLevelBars: View {
    let isAnimating: Bool
    @ObservedObject private var energy = SparkVEnergy.shared

    var body: some View {
        // Decorative: Reduce Motion, a hot Mac or sleeping displays rest the
        // bars instead of bouncing them; Low Power Mode steps them slower.
        Group {
            if isAnimating && !SparkVMotion.reduceMotion && !energy.pausesDecoration {
                let period = energy.interval(0.25)
                TimelineView(.periodic(from: .now, by: period)) { context in
                    bars(tick: Int(context.date.timeIntervalSinceReferenceDate / period))
                }
            } else {
                bars(tick: nil)
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(tick: Int?) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<4, id: \.self) { bar in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2.5)
                    .scaleEffect(y: tick.map { Self.level(tick: $0, bar: bar) } ?? 0.25, anchor: .center)
            }
        }
        // Shorter than the tick, so the island is idle between steps.
        .animation(.easeInOut(duration: 0.16), value: tick)
    }

    /// Deterministic pseudo-random level in 0.3...1 per bar and tick.
    static func level(tick: Int, bar: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: tick &* 31 &+ bar &* 7919)
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        return 0.3 + 0.7 * CGFloat(x % 1000) / 999
    }
}

/// When a CompactMarquee's title started, and whether its few scroll
/// cycles are over (one-shot timer, restarted when the title changes).
final class CompactMarqueeClock: ObservableObject {
    @Published private(set) var finished = false
    private(set) var start = Date().timeIntervalSinceReferenceDate
    private var task: Task<Void, Never>?

    @MainActor func restart(after seconds: TimeInterval) {
        task?.cancel()
        start = Date().timeIntervalSinceReferenceDate
        if finished { finished = false }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.finished = true
        }
    }

    deinit { task?.cancel() }
}

// MARK: - Dictation

/// Waveform on the left, the words so far in the middle, and the current
/// state on the right.
private struct DictationActivityView: View {
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        HStack(spacing: 10) {
            Waveform(level: dictation.level, isAnimating: dictation.phase == .listening)
                .frame(width: 34, height: 16)

            Text(caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(captionColor)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, 16)
    }

    private var caption: String {
        switch dictation.phase {
        case .listening:
            dictation.liveText.isEmpty ? "Listening…" : dictation.liveText
        case .formatting:
            "Formatting…"
        case .done(let text):
            text
        case .failed(let message):
            message
        case .idle:
            ""
        }
    }

    private var captionColor: Color {
        switch dictation.phase {
        case .failed: SparkVTheme.warning
        case .listening where dictation.liveText.isEmpty: SparkVTheme.textSecondary
        default: SparkVTheme.text
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch dictation.phase {
        case .listening:
            Text(dictation.isHandsFree ? dictation.hotkeyHint : "release")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        case .formatting:
            ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(SparkVTheme.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SparkVTheme.warning)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Clicky

/// The question as you speak it, then "Thinking…", then the answer (two
/// lines in a taller band) or the error.
private struct ClickyActivityView: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var clicky: ClickyController

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 34, height: 16)

            Text(caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(captionColor)
                .lineLimit(isAnswer ? 2 : 1)
                .truncationMode(isAnswer ? .tail : .head)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, 16)
    }

    private var isAnswer: Bool {
        if case .answering = clicky.phase { return true }
        return false
    }

    /// Words heard so far: the live transcript while the command capture
    /// runs, otherwise whatever Clicky has kept of the question.
    private var heardText: String {
        if dictation.isCapturingCommand, !dictation.liveText.isEmpty {
            return dictation.liveText
        }
        return clicky.liveQuestion
    }

    @ViewBuilder
    private var leading: some View {
        switch clicky.phase {
        case .listening:
            Waveform(level: dictation.level, isAnimating: true)
        default:
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red))
        }
    }

    private var caption: String {
        switch clicky.phase {
        case .listening:
            heardText.isEmpty ? "Ask Clicky…" : heardText
        case .thinking:
            "Thinking…"
        case .answering(let answer):
            answer
        case .failed(let message):
            message
        case .idle:
            ""
        }
    }

    private var captionColor: Color {
        switch clicky.phase {
        case .failed: SparkVTheme.warning
        case .thinking: SparkVTheme.textSecondary
        case .listening where heardText.isEmpty: SparkVTheme.textSecondary
        default: SparkVTheme.text
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch clicky.phase {
        case .listening:
            // Clicky can listen from the hold key or its panel's button, so
            // name it rather than guess how the user will stop.
            Text("CLICKY")
                .font(SparkVTheme.eyebrow(9.5))
                .tracking(0.6)
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
        case .thinking:
            ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
        case .answering:
            Image(systemName: "sparkles").foregroundStyle(SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SparkVTheme.warning)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Waveform

/// Five bars driven by the microphone level, with a gentle idle sway.
private struct Waveform: View {
    let level: Float
    let isAnimating: Bool

    private static let weights: [CGFloat] = [0.45, 0.8, 1, 0.75, 0.5]
    @ObservedObject private var energy = SparkVEnergy.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 30), paused: !isAnimating || energy.pausesDecoration)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(Self.weights.indices, id: \.self) { index in
                    let sway = (sin(time * 9 + Double(index) * 1.3) + 1) / 2
                    let amplitude = max(0.15, CGFloat(level)) * Self.weights[index]
                    Capsule()
                        .fill(isAnimating ? SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red) : SparkVTheme.textSecondary)
                        .frame(width: 3, height: 4 + 12 * amplitude * (0.6 + 0.4 * sway))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Compact building blocks for feature activities

/// Thin level bar for a compact trailing view (volume, brightness, battery),
/// like boring.notch's inline OSD.
struct CompactLevelBar: View {
    let level: Double
    var tint: Color = SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red)
    var width: CGFloat = 52

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(SparkVTheme.surfaceHover)
            Capsule().fill(tint).frame(width: width * min(1, max(0, level)))
        }
        .frame(width: width, height: 5)
        .accessibilityValue("\(Int((min(1, max(0, level)) * 100).rounded())) percent")
    }
}

/// Small progress ring for a compact view (downloads, a timer's progress).
struct CompactProgressRing: View {
    let progress: Double
    var tint: Color = SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red)
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(SparkVTheme.surfaceHover, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
