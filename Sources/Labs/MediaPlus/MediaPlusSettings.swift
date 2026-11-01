import Foundation
import SwiftUI

/// Settings of the Media package, saved in UserDefaults under feature
/// prefixes (`MediaControls.`, `MediaGestures.`, `Home.`, `MediaVisualizer.`).
/// Lyrics, App Volumes and Spotify keep their own stores; the source filter
/// lives on `MediaEngine` (`NowPlaying.`).
@MainActor
final class MediaPlusSettings: ObservableObject {
    static let shared = MediaPlusSettings()

    private let defaults: UserDefaults

    // MARK: Controls

    @Published var skipStyle: MediaSkipStyle {
        didSet { defaults.set(skipStyle.rawValue, forKey: Keys.skipStyle) }
    }
    /// The heart in the media column (Music, and Spotify once connected).
    @Published var showsLikeButton: Bool {
        didSet { defaults.set(showsLikeButton, forKey: Keys.showsLike) }
    }
    /// ← / → skip 15 s and Space plays / pauses while the pointer is over
    /// the media column and the island has keyboard focus.
    @Published var arrowKeysSkip: Bool {
        didSet { defaults.set(arrowKeysSkip, forKey: Keys.arrowKeys) }
    }

    // MARK: Gestures

    @Published var swipeAction: MediaSwipeAction {
        didSet { defaults.set(swipeAction.rawValue, forKey: Keys.swipeAction) }
    }
    @Published var swipeReversed: Bool {
        didSet { defaults.set(swipeReversed, forKey: Keys.swipeReversed) }
    }

    // MARK: Home when idle

    /// Off: Home never shows the media player (the idle column instead).
    @Published var showsMediaControls: Bool {
        didSet { defaults.set(showsMediaControls, forKey: Keys.showsMedia) }
    }
    @Published var idleMode: IdleHomeMode {
        didSet { defaults.set(idleMode.rawValue, forKey: Keys.idleMode) }
    }

    // MARK: Closed island

    /// Bars beside the notch follow the real sound (needs System Audio
    /// Recording; shares Ambient Light's capture when that is on).
    @Published var liveBars: Bool {
        didSet { defaults.set(liveBars, forKey: Keys.liveBars) }
    }
    /// Bars take the album art's color instead of white.
    @Published var tintsBars: Bool {
        didSet { defaults.set(tintsBars, forKey: Keys.tintsBars) }
    }
    /// A thin progress line along the bottom of the closed island.
    @Published var showsTrackProgress: Bool {
        didSet { defaults.set(showsTrackProgress, forKey: Keys.trackProgress) }
    }

    enum Keys {
        static let skipStyle = "MediaControls.skipStyle"
        static let showsLike = "MediaControls.showsLikeButton"
        static let arrowKeys = "MediaControls.arrowKeysSkip"
        static let swipeAction = "MediaGestures.swipeAction"
        static let swipeReversed = "MediaGestures.swipeReversed"
        static let showsMedia = "Home.showsMedia"
        static let idleMode = "Home.idleMode"
        static let liveBars = "MediaVisualizer.liveBars"
        static let tintsBars = "MediaVisualizer.tintsBars"
        static let trackProgress = "MediaVisualizer.showsTrackProgress"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skipStyle = MediaSkipStyle(rawValue: defaults.string(forKey: Keys.skipStyle) ?? "") ?? .automatic
        showsLikeButton = defaults.object(forKey: Keys.showsLike) as? Bool ?? true
        arrowKeysSkip = defaults.object(forKey: Keys.arrowKeys) as? Bool ?? true
        swipeAction = MediaSwipeAction(rawValue: defaults.string(forKey: Keys.swipeAction) ?? "") ?? .tracks
        swipeReversed = defaults.bool(forKey: Keys.swipeReversed)
        showsMediaControls = defaults.object(forKey: Keys.showsMedia) as? Bool ?? true
        idleMode = IdleHomeMode(rawValue: defaults.string(forKey: Keys.idleMode) ?? "") ?? .upNext
        liveBars = defaults.bool(forKey: Keys.liveBars)
        tintsBars = defaults.object(forKey: Keys.tintsBars) as? Bool ?? false
        showsTrackProgress = defaults.bool(forKey: Keys.trackProgress)
    }
}
