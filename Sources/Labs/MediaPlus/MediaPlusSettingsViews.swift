import AppKit
import SwiftUI

// Settings sections (no arguments; `.shared` stores inside). Panes:
//   Media:  MediaControlsSettingsSection, MediaSourcesSettingsSection,
//           MediaGesturesSettingsSection, LyricsSettingsSection,
//           SpotifyLikesSettingsSection
//   System: SoundOutputSettingsSection, AppVolumeSettingsSection
//   Island: ClosedIslandMediaSettingsSection, IdleHomeSettingsSection

/// Wraps a section that needs the app's MediaEngine (set by MediaPlus.start).
private struct WithMedia<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let media = MediaPlus.media {
            content().environmentObject(media)
        } else {
            MPNote(text: "Available once SparkV’s island is running.")
        }
    }
}

// MARK: - Media pane

struct MediaControlsSettingsSection: View {
    @ObservedObject private var settings = MediaPlusSettings.shared

    var body: some View {
        MPSettingsSection(title: "Playback Controls",
                          summary: "What the buttons beside play/pause do, and the favorite button.",
                          systemImage: "playpause.fill") {
            VStack(alignment: .leading, spacing: 10) {
                MPRow(label: "Skip Buttons") {
                    Picker("Skip Buttons", selection: $settings.skipStyle) {
                        ForEach(MediaSkipStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                MPNote(text: "Automatic: previous / next for music, back / forward 15 s for podcasts, audiobooks and anything 20 minutes or longer.")
                Toggle("Show Favorite Button (Music; Spotify once connected)", isOn: $settings.showsLikeButton)
                Toggle("← / → Skip 15 s and Space Plays / Pauses (pointer over the player)", isOn: $settings.arrowKeysSkip)
                MPNote(text: "Shuffle, repeat and Add to Playlist are in the player’s ••• menu. Favorites, shuffle and repeat for Music and Spotify ask once to control the app.")
            }
        }
    }
}

struct MediaSourcesSettingsSection: View {
    var body: some View {
        WithMedia { MediaSourcesSettingsContent() }
    }
}

private struct MediaSourcesSettingsContent: View {
    @EnvironmentObject private var media: MediaEngine

    var body: some View {
        let sources = MediaSourceList.sources(seen: media.seenSources, excluded: media.excludedSources)
        MPSettingsSection(title: "Media Sources",
                          summary: "Choose which apps can show in the island, and which player wins when two play at once.",
                          systemImage: "music.note.list") {
            VStack(alignment: .leading, spacing: 10) {
                if sources.isEmpty {
                    MPNote(text: "Apps appear here after they play something.")
                } else {
                    VStack(spacing: 2) {
                        ForEach(sources, id: \.self) { bundleID in
                            sourceRow(bundleID)
                        }
                    }
                }
                MPRow(label: "When two apps play, prefer") {
                    Picker("Prefer", selection: Binding(get: { media.preferredSource ?? "" },
                                                        set: { media.preferredSource = $0.isEmpty ? nil : $0 })) {
                        Text("Whichever played last").tag("")
                        ForEach(ScriptablePlayer.allCases, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                MPNote(text: "A hidden app (say, a browser playing previews) never shows or gets your play/pause; Music or Spotify shows instead if one is open. That check reads the player every 2 s only while the hidden app owns Now Playing. A preferred player is checked at most every 3 s when another app starts playing, and read every 2 s only while it plays over that app.")
            }
        }
    }

    private func sourceRow(_ bundleID: String) -> some View {
        let info = media.appInfo(for: bundleID)
        return HStack(spacing: 8) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            .frame(width: 18, height: 18)
            Text(info.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Toggle("Show \(info.name)", isOn: Binding(get: { !media.excludedSources.contains(bundleID) },
                                                    set: { media.setSource(bundleID, allowed: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.03)))
        .contextMenu { Button("Forget \(info.name)") { media.forgetSource(bundleID) } }
    }
}

struct MediaGesturesSettingsSection: View {
    @ObservedObject private var settings = MediaPlusSettings.shared
    @ObservedObject private var mediaShows = ClosedNotchToggle()

    var body: some View {
        MPSettingsSection(title: "Gestures",
                          summary: "Swipe two fingers sideways over the player in the open island.",
                          systemImage: "hand.draw") {
            VStack(alignment: .leading, spacing: 10) {
                MPRow(label: "Two-finger swipe") {
                    Picker("Two-finger swipe", selection: $settings.swipeAction) {
                        ForEach(MediaSwipeAction.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Toggle("Reverse Direction", isOn: $settings.swipeReversed)
                    .disabled(settings.swipeAction == .off)
                MPNote(text: "Swipe left for next (follows your scroll direction setting). Up and down scrolling is left alone. The closed island doesn’t take swipes: hovering it opens the drawer, and watching every scroll on the Mac would cost battery.")
                if let toggle = mediaShows.binding {
                    Toggle("Show Now Playing Beside the Closed Notch", isOn: toggle)
                }
            }
        }
    }
}

/// The closed-notch toggle lives on MediaEngine; this reaches it without
/// an environment object.
@MainActor
private final class ClosedNotchToggle: ObservableObject {
    var binding: Binding<Bool>? {
        guard let media = MediaPlus.media else { return nil }
        return Binding(get: { media.showsInClosedNotch }, set: { media.showsInClosedNotch = $0; self.objectWillChange.send() })
    }
}

struct LyricsSettingsSection: View {
    @ObservedObject private var lyrics = LyricsController.shared

    var body: some View {
        MPSettingsSection(title: "Lyrics",
                          summary: "Synced lyrics in Home, under the notch, and in the Lyrics window.",
                          systemImage: "quote.bubble.fill",
                          accessory: { MPHeaderSwitch(label: "Lyrics", isOn: $lyrics.isEnabled) }) {
            VStack(alignment: .leading, spacing: 10) {
                MPPrivacyNote(text: "Off until you turn it on. Then the title, artist, album and length of a track go to lrclib.net (free, no account), once per track and only while lyrics are on screen. Lyrics saved in Music are read on this Mac first.")
                Toggle("Show the Current Line in Home", isOn: $lyrics.showsInDrawer)
                    .disabled(!lyrics.isEnabled)
                Toggle("Show the Current Line Under the Notch While Music Plays", isOn: $lyrics.showsUnderNotch)
                    .disabled(!lyrics.isEnabled)
                HStack(spacing: 8) {
                    Button("Open Lyrics Window") { LyricsWindow.shared.show() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                    Button("Clear Saved Lyrics") { lyrics.clearCache() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                    Spacer()
                }
            }
        }
    }
}

struct SpotifyLikesSettingsSection: View {
    @ObservedObject private var spotify = SpotifyLibraryClient.shared

    var body: some View {
        MPSettingsSection(title: "Spotify Favorites",
                          summary: "Let the heart save Spotify tracks to Your Library (Music works without this).",
                          systemImage: "heart.fill",
                          accessory: {
                              if spotify.isConnected {
                                  Text("Connected").font(.system(size: 11, weight: .medium)).foregroundStyle(SparkVTheme.success)
                              }
                          }) {
            VStack(alignment: .leading, spacing: 10) {
                MPPrivacyNote(text: "Uses Spotify’s Web API: the id of the playing Spotify track goes to api.spotify.com when it starts and when you tap the heart. Your sign-in stays in the keychain.")
                if spotify.isConnected {
                    HStack {
                        MPStatusLine(text: "Hearts save to Your Library.", color: SparkVTheme.success)
                        Spacer()
                        Button("Disconnect") { spotify.disconnect() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                } else {
                    MPNote(text: "1. At developer.spotify.com, create an app with the redirect URI \(SpotifyLibraryClient.redirectURI).\n2. Paste its Client ID below.\n3. Connect.")
                    HStack(spacing: 8) {
                        // Label hidden so the Form doesn't turn it into a
                        // (monospaced) row title; the prompt says what goes in.
                        TextField("Client ID", text: $spotify.clientID, prompt: Text("Paste Client ID"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .accessibilityLabel("Spotify Client ID")
                        let blocked = spotify.isConnecting || spotify.clientID.trimmingCharacters(in: .whitespaces).isEmpty
                        Button(spotify.isConnecting ? "Connecting…" : "Connect Spotify") { spotify.connect() }
                            .buttonStyle(SparkVPrimaryButtonStyle())
                            .disabled(blocked)
                            .opacity(blocked ? 0.45 : 1)
                    }
                }
                if let error = spotify.lastError {
                    MPStatusLine(text: error, color: SparkVTheme.warning)
                }
            }
        }
    }
}

// MARK: - System pane

struct SoundOutputSettingsSection: View {
    @ObservedObject private var outputs = AudioOutputController.shared

    var body: some View {
        MPSettingsSection(title: "Sound Output",
                          summary: "Where sound plays. Also in the gear menu and the player’s ••• menu.",
                          systemImage: "hifispeaker.2.fill") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outputs.devices) { device in
                    SoundOutputRow(device: device, isPending: outputs.pendingID == device.id) { outputs.select(device) }
                }
                if outputs.devices.isEmpty {
                    MPNote(text: "No outputs found.")
                }
                if let error = outputs.lastError {
                    MPStatusLine(text: error, color: SparkVTheme.warning)
                }
                if !PermissionCenter.shared.isGranted(.bluetooth) {
                    HStack {
                        MPNote(text: "Allow Bluetooth to also list paired headphones that aren’t connected.")
                        Spacer()
                        Button("Allow Bluetooth…") {
                            Task {
                                _ = await PermissionCenter.shared.request(.bluetooth, from: "Sound Output")
                                outputs.refresh()
                            }
                        }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                    .padding(.top, 4)
                }
                MPNote(text: "macOS may move to AirPods on its own when they connect (Bluetooth settings › Connect to This Mac).")
                    .padding(.top, 4)
            }
        }
        .onAppear { outputs.refresh() }
    }
}

struct SoundOutputRow: View {
    let device: AudioOutputDevice
    var isPending = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(device.isCurrent ? SparkVTheme.accent : SparkVTheme.textSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name).font(.system(size: 12, weight: device.isCurrent ? .semibold : .regular))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    if let subtitle = device.subtitle {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                    }
                }
                Spacer()
                if isPending {
                    ProgressView().controlSize(.small)
                } else if device.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SparkVTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: device.subtitle == nil ? 28 : 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(device.isCurrent ? LabsBStyle.selectedFill : (hover.isOn ? SparkVTheme.surfaceHover : Color.clear))
            )
            .contentShape(Rectangle())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle(scale: 0.99))
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(device.name)
        .accessibilityValue(device.isCurrent ? "Current output" : (device.subtitle ?? ""))
        .accessibilityAddTraits(device.isCurrent ? .isSelected : [])
    }
}

// MARK: - Island pane

struct ClosedIslandMediaSettingsSection: View {
    @ObservedObject private var settings = MediaPlusSettings.shared
    @ObservedObject private var visualizer = MediaVisualizerController.shared

    var body: some View {
        MPSettingsSection(title: "Closed Island Music",
                          summary: "The level bars beside the notch and a progress line under it.",
                          systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Live Level Bars (Follow the Real Sound)", isOn: Binding(
                    get: { settings.liveBars }, set: { visualizer.setLiveBars($0) }))
                if settings.liveBars {
                    MPStatusLine(text: statusText, color: statusColor)
                }
                MPNote(text: "Live bars listen to what the Mac plays (System Audio Recording) while music plays and the bars are visible; with Ambient Light on they share its capture. Analyzed on this Mac, never recorded. Off in Low Power Mode; still under Reduce Motion.")
                Toggle("Color the Bars with the Album Art", isOn: $settings.tintsBars)
                Toggle("Show Track Progress Under the Closed Island", isOn: $settings.showsTrackProgress)
            }
        }
    }

    private var statusText: String {
        switch visualizer.status {
        case .off: "Off"
        case .sharingAmbientLight: "Using Ambient Light’s audio"
        case .capturing: "Listening"
        case .waiting: "Waits for music"
        case .needsPermission: "Allow System Audio Recording in Privacy & Security"
        case .paused(let why): "Paused: \(why)"
        }
    }

    private var statusColor: Color {
        switch visualizer.status {
        case .capturing, .sharingAmbientLight: SparkVTheme.success
        case .needsPermission, .paused: SparkVTheme.warning
        case .off, .waiting: SparkVTheme.textTertiary
        }
    }
}

struct IdleHomeSettingsSection: View {
    @ObservedObject private var settings = MediaPlusSettings.shared

    var body: some View {
        MPSettingsSection(title: "Home When Nothing Plays",
                          summary: "Swap the music player for something useful when it’s idle.",
                          systemImage: "house.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show Media Controls in Home", isOn: $settings.showsMediaControls)
                MPRow(label: "When nothing plays, show") {
                    Picker("When nothing plays", selection: $settings.idleMode) {
                        ForEach(IdleHomeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .disabled(!settings.showsMediaControls)
                }
                MPNote(text: settings.showsMediaControls
                       ? "Applies when no app has a track (or Music and Spotify are stopped); a paused track stays so you can resume it. The swap waits 3 seconds so a gap between tracks doesn’t flicker. Meetings need calendar access (Live Activities › Meetings)."
                       : "Home shows the next meeting (or a clock) and quick timers instead of a music player.")
            }
        }
    }
}
