import AppKit
import Combine
import SwiftUI

/// Starts and stops the Media package's controllers. One call each from
/// NotchWindowController (see INTEGRATION.md):
///
///     MediaPlus.start(media: media, activities: activities)
///     MediaPlus.stop()
///
/// Nothing here polls: outputs and app volumes listen to Core Audio, lyrics
/// wake once per line while shown, the visualizer captures only while its
/// bars are visible and music plays.
@MainActor
enum MediaPlus {
    /// The app's media engine, for settings sections and windows that live
    /// outside the island's environment.
    private(set) static weak var media: MediaEngine?
    private static var likesWatch: AnyCancellable?

    static func start(media: MediaEngine, activities: ActivityCenter) {
        self.media = media
        LyricsWindow.media = media
        media.spotifyLibrary = SpotifyLibraryClient.shared
        // Hidden heart: no favorite reads (Apple Events, Spotify Web API).
        likesWatch = MediaPlusSettings.shared.$showsLikeButton
            .removeDuplicates()
            .sink { [weak media] shown in media?.likesEnabled = shown }
        AudioOutputController.shared.start()
        AppVolumeController.shared.start()
        LyricsController.shared.attach(media: media, activities: activities)
        MediaVisualizerController.shared.start(media: media)
        AppLog.log("Media: sources, outputs, app volumes, lyrics and visualizer ready")
    }

    /// Synchronous where it matters: app-volume taps are gone when it returns.
    static func stop() {
        likesWatch = nil
        AppVolumeController.shared.stop()
        MediaVisualizerController.shared.stop()
        LyricsController.shared.detach()
        AudioOutputController.shared.stop()
    }
}

// MARK: - Sound output hub tile

/// Agents hub tile (Media): a menu of outputs with the current one checked.
struct SoundOutputHubTile: View {
    @ObservedObject private var outputs = AudioOutputController.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let current = outputs.current
        Menu {
            SoundOutputMenuItems()
        } label: {
            MPHubTileFace(title: current?.name ?? "Output", systemImage: current?.symbol ?? "hifispeaker.fill",
                          tint: .blue, isHovered: hover.isOn)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover.isOn = $0 }
        .help("Sound output: \(current?.name ?? "unknown"). Click to switch.")
        .accessibilityLabel("Sound output, \(current?.name ?? "unknown")")
    }
}
