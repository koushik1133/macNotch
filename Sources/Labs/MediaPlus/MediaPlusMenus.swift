import AppKit
import SwiftUI

// Menu items (usable inside `Menu { }`) for the gear menu, the media
// column's "More" menu, the volume knob and the hub tiles.

// MARK: - Sound output

/// One checkable item per output; picking one switches to it.
/// `Menu("Sound Output") { SoundOutputMenuItems() }`.
struct SoundOutputMenuItems: View {
    @ObservedObject private var outputs = AudioOutputController.shared

    var body: some View {
        if outputs.devices.isEmpty {
            Text("No outputs found")
        }
        ForEach(outputs.devices) { device in
            Toggle(isOn: Binding(get: { device.isCurrent }, set: { if $0 { outputs.select(device) } })) {
                Label(device.subtitle.map { "\(device.name) (\($0))" } ?? device.name, systemImage: device.symbol)
            }
        }
        Divider()
        Button("Sound Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        }
        .onAppear { outputs.refresh() }
    }
}

// MARK: - Sources

/// Per-app "may drive the island" toggles and the preferred player.
/// `Menu("Media Sources") { MediaSourcesMenuItems() }`.
struct MediaSourcesMenuItems: View {
    @EnvironmentObject private var media: MediaEngine

    var body: some View {
        let sources = MediaSourceList.sources(seen: media.seenSources, excluded: media.excludedSources)
        Section("Show in the Island") {
            if sources.isEmpty {
                Text("Apps appear here once they play")
            }
            ForEach(sources, id: \.self) { bundleID in
                let info = media.appInfo(for: bundleID)
                Toggle(info.name, isOn: Binding(
                    get: { !media.excludedSources.contains(bundleID) },
                    set: { media.setSource(bundleID, allowed: $0) }
                ))
            }
        }
        Section("When Two Apps Play") {
            Picker("Prefer", selection: Binding(get: { media.preferredSource ?? "" },
                                                set: { media.preferredSource = $0.isEmpty ? nil : $0 })) {
                Text("Whichever Played Last").tag("")
                ForEach(ScriptablePlayer.allCases, id: \.bundleID) { player in
                    Text(player.name).tag(player.bundleID)
                }
            }
        }
    }
}

// MARK: - Playback

/// Shuffle, repeat and 15 s skips for the current player.
struct MediaPlaybackMenuItems: View {
    @EnvironmentObject private var media: MediaEngine

    var body: some View {
        Toggle(isOn: Binding(get: { media.shuffleMode?.isOn ?? false }, set: { media.setShuffle($0) })) {
            Label("Shuffle", systemImage: "shuffle")
        }
        .disabled(!media.canShuffle)
        Picker(selection: Binding(get: { media.repeatMode ?? .off }, set: { media.setRepeat($0) })) {
            ForEach([MediaEngine.RepeatMode.off, .all, .one], id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            Label("Repeat", systemImage: (media.repeatMode ?? .off).systemImage)
        }
        .disabled(!media.canRepeat)
        Divider()
        Button { media.send(.skipBackward15) } label: { Label("Back 15 Seconds", systemImage: "gobackward.15") }
            .disabled(!media.canSkip15)
        Button { media.send(.skipForward15) } label: { Label("Forward 15 Seconds", systemImage: "goforward.15") }
            .disabled(!media.canSkip15)
    }
}

// MARK: - Lyrics

struct LyricsMenuItems: View {
    @ObservedObject private var lyrics = LyricsController.shared

    var body: some View {
        Toggle("Look Up Lyrics (LRCLIB)", isOn: $lyrics.isEnabled)
        Toggle("Lyrics in Home", isOn: $lyrics.showsInDrawer)
            .disabled(!lyrics.isEnabled)
        Toggle("Lyrics Under the Notch", isOn: $lyrics.showsUnderNotch)
            .disabled(!lyrics.isEnabled)
        Button("Lyrics Window…") { LyricsWindow.shared.show() }
        Divider()
        Text("Sends title, artist, album and length to lrclib.net")
    }
}

// MARK: - Gear menu

/// The gear menu's Media submenu: `Menu("Media") { MediaPlusMenuItems() }`.
struct MediaPlusMenuItems: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var settings = MediaPlusSettings.shared
    @ObservedObject private var appVolumes = AppVolumeController.shared

    var body: some View {
        Menu("Sound Output") { SoundOutputMenuItems() }
        Button("App Volumes…") { AppVolumeWindow.shared.show() }
        Divider()
        Menu("Media Sources") { MediaSourcesMenuItems() }
        Menu("Playback") {
            MediaPlaybackMenuItems()
            Divider()
            Picker("Skip Buttons", selection: $settings.skipStyle) {
                ForEach(MediaSkipStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Two-Finger Swipe", selection: $settings.swipeAction) {
                ForEach(MediaSwipeAction.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Reverse Swipe Direction", isOn: $settings.swipeReversed)
                .disabled(settings.swipeAction == .off)
            Toggle("Show Favorite Button", isOn: $settings.showsLikeButton)
        }
        Menu("Lyrics") { LyricsMenuItems() }
        Menu("Home When Nothing Plays") {
            Toggle("Show Media Controls", isOn: $settings.showsMediaControls)
            Picker("When Nothing Plays", selection: $settings.idleMode) {
                ForEach(IdleHomeMode.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!settings.showsMediaControls)
        }
        Menu("Closed Island") {
            Toggle("Now Playing Beside the Notch", isOn: $media.showsInClosedNotch)
            Toggle("Live Level Bars", isOn: Binding(get: { settings.liveBars },
                                                    set: { MediaVisualizerController.shared.setLiveBars($0) }))
            Toggle("Album Color Bars", isOn: $settings.tintsBars)
            Toggle("Track Progress Under the Island", isOn: $settings.showsTrackProgress)
        }
    }
}
