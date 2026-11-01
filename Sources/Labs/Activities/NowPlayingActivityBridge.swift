import AppKit
import Combine
import SwiftUI

/// Makes the music playing a live activity like the others, so it can rest
/// beside a timer or a call instead of disappearing (as a small artwork
/// icon), be picked for the wings, and peek on track changes or play/pause
/// when the user asks for that (Settings › Activities › Timing).
///
/// Follows `MediaEngine`'s published values (no polling). While music has
/// the wings, the island draws them exactly as before (artwork, title
/// marquee, level bars, album glow): see `NotchActivityView.wingsSource`.
@MainActor
final class NowPlayingActivityBridge: ObservableObject {
    static let activityID = "media"
    static let pausedActivityID = "media.paused"
    /// The peek band when music isn't kept as an activity of its own.
    static let peekActivityID = "media.peek"
    /// Lowest: anything else running takes the wings first.
    static let priority = 5
    static let bandHeight: CGFloat = 44

    private let media: MediaEngine
    private let activities: ActivityCenter
    private let settings: LiveActivitiesSettings
    private let timing: ActivityTimingSettings
    private let announcer: ActivityAnnouncer
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false
    private var isPosted = false
    private var postedTrackKey: String?
    private var lastTrackKey: String?
    private var wasPlaying = false
    private var syncScheduled = false

    init(
        media: MediaEngine,
        activities: ActivityCenter,
        settings: LiveActivitiesSettings? = nil,
        timing: ActivityTimingSettings? = nil,
        announcer: ActivityAnnouncer? = nil
    ) {
        self.media = media
        self.activities = activities
        self.settings = settings ?? .shared
        self.timing = timing ?? .shared
        self.announcer = announcer ?? .shared
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        wasPlaying = media.isPlaying
        lastTrackKey = media.trackKey
        // @Published fires before the value is stored: read on the next turn.
        let changes: [AnyPublisher<Void, Never>] = [
            media.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            media.$title.map { _ in () }.eraseToAnyPublisher(),
            media.$artist.map { _ in () }.eraseToAnyPublisher(),
            media.$source.map { _ in () }.eraseToAnyPublisher(),
            media.$showsInClosedNotch.map { _ in () }.eraseToAnyPublisher(),
            settings.$keepsNowPlayingAlongside.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.scheduleSync() }
            .store(in: &cancellables)
        sync()
    }

    func stop() {
        isStarted = false
        cancellables.removeAll()
        dismiss()
        activities.dismiss(id: Self.pausedActivityID)
        activities.dismiss(id: Self.peekActivityID)
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.syncScheduled = false
                self?.sync()
            }
        }
    }

    /// Posts, updates or removes the activity for the current state.
    func sync() {
        guard isStarted else { return }
        let playing = media.isPlaying && media.source != .none
        let key = media.trackKey
        let trackChanged = key != nil && lastTrackKey != nil && key != lastTrackKey
        let showing = settings.keepsNowPlayingAlongside && media.isShowingClosedActivity

        let peekForTrack = trackChanged && timing.peekOnTrackChange
        let peekForPlay = !trackChanged && !wasPlaying && playing && timing.peekOnPlayPause
        if showing {
            if !isPosted || key != postedTrackKey { post(trackKey: key) }
            if peekForTrack {
                activities.peek(id: Self.activityID, for: timing.titlePeekSeconds)
            } else if peekForPlay {
                activities.peek(id: Self.activityID)
            }
        } else {
            if isPosted { dismiss() }
            // Music isn't kept beside other activities: the expand-on
            // settings still work, with a band of their own.
            if media.isShowingClosedActivity, peekForTrack || peekForPlay {
                postPeek(seconds: peekForTrack ? timing.titlePeekSeconds : timing.peekSeconds)
            }
        }

        // Paused: the wings go away, so say so for a moment if asked to.
        if wasPlaying, !playing, media.source != .none, media.showsInClosedNotch, timing.peekOnPlayPause {
            postPaused()
        } else if playing {
            activities.dismiss(id: Self.pausedActivityID)
        }

        if trackChanged, playing {
            announcer.announce(
                ActivityAnnouncementText.nowPlaying(title: media.title, artist: media.artist),
                id: Self.activityID, category: .media
            )
        }
        if key != nil { lastTrackKey = key }
        wasPlaying = playing
    }

    private func post(trackKey: String?) {
        isPosted = true
        postedTrackKey = trackKey
        let title = media.title
        let artist = media.artist
        activities.post(LiveActivity(
            id: Self.activityID,
            kind: .media,
            priority: Self.priority,
            duration: nil,
            height: Self.bandHeight,
            presentation: .compact
        ) {
            NowPlayingPeekBand(isPaused: false)
        }
        .compact {
            NowPlayingCompactLeading()
        } trailing: {
            NowPlayingCompactTrailing()
        }
        .minimal {
            NowPlayingMinimalArtwork()
        }
        .titled(title.isEmpty ? "Now Playing" : "Now Playing: \(title)")
        .accessibility(artist.isEmpty ? "Now playing: \(title)" : "Now playing: \(title) by \(artist)"))
    }

    private func postPeek(seconds: TimeInterval) {
        let title = media.title
        activities.post(LiveActivity(
            id: Self.peekActivityID,
            kind: .media,
            priority: 40,
            duration: min(seconds, NotchMetrics.alertMaxDuration),
            height: Self.bandHeight
        ) {
            NowPlayingPeekBand(isPaused: false)
        }
        .titled(title.isEmpty ? "Now Playing" : "Now Playing: \(title)")
        .accessibility("Now playing: \(title)"))
    }

    private func postPaused() {
        let title = media.title
        activities.post(LiveActivity(
            id: Self.pausedActivityID,
            kind: .media,
            priority: 40,
            duration: 2.5,
            height: Self.bandHeight
        ) {
            NowPlayingPeekBand(isPaused: true)
        }
        .titled("Paused")
        .accessibility("Paused: \(title)"))
    }

    private func dismiss() {
        guard isPosted else { return }
        isPosted = false
        postedTrackKey = nil
        activities.dismiss(id: Self.activityID)
    }
}

// MARK: - Views

/// The band when music peeks (track change, play, pause): artwork, title
/// over artist, and the play state.
struct NowPlayingPeekBand: View {
    @EnvironmentObject private var media: MediaEngine
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 10) {
            NowPlayingArtwork(size: 30, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(media.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isPaused {
                HStack(spacing: 4) {
                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold))
                    Text("Paused").font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
            } else {
                MediaLiveLevelBars(isAnimating: media.isPlaying)
                    .frame(width: 16, height: 14)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Paused: \(media.title)" : NowPlayingAccessibility.label(media))
    }
}

/// Artwork, else the player's icon, else a note.
struct NowPlayingArtwork: View {
    @EnvironmentObject private var media: MediaEngine
    var size: CGFloat = 20
    var cornerRadius: CGFloat = 5

    var body: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = media.sourceIcon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    SparkVTheme.surfaceHover
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Music beside another activity: a small round artwork.
struct NowPlayingMinimalArtwork: View {
    @EnvironmentObject private var media: MediaEngine

    var body: some View {
        NowPlayingArtwork(size: 18, cornerRadius: 9)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityLabel(NowPlayingAccessibility.label(media))
    }
}
