import AppKit
import SwiftUI

/// Note entry state of the media column.
@MainActor
final class MediaColumnModel: ObservableObject {
    /// Position the note will be saved at; non-nil while the note field shows.
    @Published var notePosition: TimeInterval?
    @Published var noteDraft = ""
    /// Bumped on every save, for the bookmark icon's bounce.
    @Published var savedCount = 0
    /// The user's Music playlists, for "Add to Playlist" (read only when
    /// Music may already be scripted; never prompts).
    @Published var playlists: [String] = []
    private var playlistsLoadedAt = Date.distantPast

    func loadPlaylistsIfNeeded(media: MediaEngine) {
        guard media.scriptablePlayer == .music, Date().timeIntervalSince(playlistsLoadedAt) > 300 else { return }
        playlistsLoadedAt = Date()
        Task { [weak self] in
            let names = await media.musicPlaylists()
            self?.playlists = names
        }
    }
}

/// Redesigned Nook media column for the 115 pt drawer (about 170 x 69 pt):
/// artwork with the playing app's badge, scrolling title and artist (or the
/// current lyric), a heart, previous / play-pause / next (±15 s for spoken
/// word), a "More" menu (bookmarks, shuffle, repeat, sound output, lyrics,
/// playlists, hide this app), and a scrubber with bookmark ticks across the
/// full width underneath. Two-finger swipes and ←/→ work while the pointer
/// is over it.
struct MediaColumnV2: View {
    @EnvironmentObject private var media: MediaEngine
    /// Defaults to the shared store; tests pass a scratch one.
    @ObservedObject var bookmarks: MediaBookmarkStore = .shared
    @ObservedObject private var settings = MediaPlusSettings.shared
    @ObservedObject private var lyrics = LyricsController.shared
    @StateObject private var model = MediaColumnModel()
    @FocusState private var noteFocused: Bool

    /// Fixed clock and hover look for offscreen renders.
    var previewDate: Date? = nil
    var previewHover = false
    var previewMarqueeElapsed: TimeInterval? = nil
    /// Opens the note field at this position on appear (offscreen renders).
    var previewNotePosition: TimeInterval? = nil

    static let artworkSide: CGFloat = 48
    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let artistFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 9) {
                MediaArtworkView(side: Self.artworkSide)
                VStack(alignment: .leading, spacing: 0) {
                    if showsLyrics, lyrics.state == .synced {
                        MediaLyricsLines(previewElapsed: previewMarqueeElapsed)
                    } else {
                        MarqueeText(text: media.title, font: Self.titleFont, previewElapsed: previewMarqueeElapsed)
                        if let notice = media.notice {
                            Text(notice)
                                .font(Font(Self.artistFont as CTFont))
                                .foregroundStyle(SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .transition(.opacity)
                                .accessibilityLabel(notice)
                        } else {
                            MarqueeText(text: media.artist, font: Self.artistFont, color: SparkVTheme.textSecondary,
                                        previewElapsed: previewMarqueeElapsed)
                        }
                    }
                    Spacer(minLength: 0)
                    if let position = model.notePosition {
                        noteField(position: position)
                    } else {
                        controls
                    }
                }
                // The marquee scrolls inside this column only (its own fade
                // mask), never under the artwork beside it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.artworkSide)
            }
            MediaScrubber(
                bookmarks: bookmarks,
                tint: scrubberTint,
                previewDate: previewDate,
                previewHover: previewHover
            )
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: media.notice)
        // Lyrics are looked up only while this column wants them.
        .background { if showsLyrics { LyricsVisibility() } }
        .mediaPointerControls()
        .onAppear {
            if let position = previewNotePosition { model.notePosition = position }
            model.loadPlaylistsIfNeeded(media: media)
        }
        .onChange(of: media.trackKey) { _, _ in
            // A note started for the previous track would land on the wrong one.
            model.notePosition = nil
            model.loadPlaylistsIfNeeded(media: media)
        }
    }

    /// Lyrics replace title and artist (when on, and something plays).
    private var showsLyrics: Bool {
        lyrics.isEnabled && lyrics.showsInDrawer && media.source != .none && previewNotePosition == nil
    }

    /// ±15 s instead of previous / next (Settings › Media › Playback Controls).
    private var skipsSeconds: Bool {
        settings.skipStyle.usesSeconds(bundleID: media.sourceBundleID, duration: media.duration,
                                       reportsSkip15: media.reportsSkip15, canSeek: media.canSeek)
    }

    private var showsHeart: Bool { settings.showsLikeButton && media.canLike }

    /// The elapsed part is white in Apple (iOS / macOS Now Playing) and
    /// SparkV red in SparkV Red; the artwork's own color stays in the glow
    /// behind the island (MediaGlowBackground).
    private var scrubberTint: Color { SparkVTheme.progressTint }

    // MARK: Controls

    private var controls: some View {
        let seconds = skipsSeconds
        return HStack(spacing: 0) {
            if showsHeart {
                MediaLikeButton()
                Spacer(minLength: 0)
            }
            if seconds {
                MediaControlButton(systemImage: "gobackward.15", size: 13, help: "Back 15 seconds") { media.send(.skipBackward15) }
            } else {
                MediaControlButton(systemImage: "backward.fill", help: "Previous") { media.send(.previousTrack) }
            }
            Spacer(minLength: 0)
            MediaControlButton(systemImage: media.isPlaying ? "pause.fill" : "play.fill", size: 15,
                               help: media.isPlaying ? "Pause" : "Play") {
                media.send(.togglePlayPause)
            }
            Spacer(minLength: 0)
            if seconds {
                MediaControlButton(systemImage: "goforward.15", size: 13, help: "Forward 15 seconds") { media.send(.skipForward15) }
            } else {
                MediaControlButton(systemImage: "forward.fill", help: "Next") { media.send(.nextTrack) }
            }
            Spacer(minLength: 0)
            moreMenu
        }
        .frame(height: 20)
    }

    private var currentBookmarks: [MediaBookmark] {
        bookmarks.bookmarks(forTrack: media.trackKey)
    }

    private var moreMenu: some View {
        let list = currentBookmarks
        let hours = media.duration >= 3600
        let canBookmark = media.canSeek && media.trackKey != nil
        return Menu {
            Section("Bookmarks") {
                Button("Bookmark This Moment") { addBookmark(note: "") }
                    .disabled(!canBookmark)
                Button("Bookmark with Note…") {
                    model.noteDraft = ""
                    model.notePosition = media.elapsedTime
                    noteFocused = true
                }
                .disabled(!canBookmark)
                if !list.isEmpty {
                    Menu("Jump To") {
                        ForEach(list) { bookmark in
                            Button(Self.menuTitle(bookmark, hours: hours)) { media.seek(to: bookmark.position) }
                        }
                    }
                    Menu("Remove") {
                        ForEach(list) { bookmark in
                            Button(Self.menuTitle(bookmark, hours: hours)) { bookmarks.remove(bookmark.id) }
                        }
                        Divider()
                        Button("Remove All for This Track") {
                            if let key = media.trackKey { bookmarks.removeAll(forTrack: key) }
                        }
                    }
                }
            }
            Section("Playback") {
                MediaPlaybackMenuItems()
            }
            Divider()
            Menu("Sound Output") { SoundOutputMenuItems() }
            if lyrics.isEnabled {
                Toggle("Show Lyrics Here", isOn: $lyrics.showsInDrawer)
            }
            Button(lyrics.isEnabled ? "Lyrics Window…" : "Lyrics…") { LyricsWindow.shared.show() }
            if media.scriptablePlayer == .music {
                Menu("Add to Playlist") {
                    if model.playlists.isEmpty {
                        Button("Load Playlists") {
                            Task {
                                model.playlists = await media.musicPlaylists()
                                if model.playlists.isEmpty { media.post(notice: "Allow control of Music") }
                            }
                        }
                    }
                    ForEach(model.playlists, id: \.self) { name in
                        Button(name) { media.addCurrentTrack(toPlaylist: name) }
                    }
                }
            }
            if let id = media.sourceBundleID {
                Divider()
                Button("Hide \(media.appInfo(for: id).name) in the Island") { media.setSource(id, allowed: false) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .symbolEffect(.bounce, value: model.savedCount)
                .frame(width: 22, height: 20)
                .overlay(alignment: .topTrailing) {
                    // A dot while the track has bookmarks.
                    if !list.isEmpty {
                        Circle()
                            .fill(SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red))
                            .frame(width: 5, height: 5)
                            .offset(x: -2, y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(media.source == .none)
        .help(list.isEmpty ? "More: bookmarks, shuffle, repeat, output, lyrics" : "More (\(list.count) bookmark\(list.count == 1 ? "" : "s"))")
        .accessibilityLabel("More")
    }

    static func menuTitle(_ bookmark: MediaBookmark, hours: Bool) -> String {
        let time = MediaTimeFormat.string(bookmark.position, hours: hours)
        return bookmark.note.isEmpty ? time : "\(time)  \(bookmark.note)"
    }

    private func addBookmark(note: String, at position: TimeInterval? = nil) {
        guard let key = media.trackKey, let app = media.sourceBundleID else { return }
        let saved = bookmarks.add(
            trackKey: key,
            title: media.title,
            artist: media.artist,
            appBundleID: app,
            position: position ?? media.elapsedTime,
            note: note
        )
        if saved != nil { model.savedCount += 1 }
    }

    // MARK: Note entry

    private func noteField(position: TimeInterval) -> some View {
        HStack(spacing: 4) {
            TextField(
                "",
                text: $model.noteDraft,
                prompt: Text("Note at \(MediaTimeFormat.string(position))").foregroundColor(Color.white.opacity(0.4))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .focused($noteFocused)
            .onSubmit { saveNote(position: position) }
            .onExitCommand { model.notePosition = nil }

            Button {
                saveNote(position: position)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(SparkVTheme.accent))
            }
            .buttonStyle(SparkVPressStyle())
            .help("Save bookmark")
            .accessibilityLabel("Save bookmark")
        }
        .padding(.leading, 7)
        .padding(.trailing, 1)
        .frame(height: 20)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(SparkVTheme.accent.opacity(0.5), lineWidth: 1))
        // The island is a non-activating panel that only becomes key when
        // a click needs it; a field opened from a menu would otherwise not
        // take typing until clicked.
        .background(MakeWindowKey())
        .onAppear {
            noteFocused = true
            // Again once the window is key, which happens in the same pass.
            Task { @MainActor in noteFocused = true }
        }
    }

    private func saveNote(position: TimeInterval) {
        addBookmark(note: model.noteDraft, at: position)
        model.notePosition = nil
        model.noteDraft = ""
    }
}

/// Makes its window key when it appears, if that window can be key and
/// isn't already. Used only while the bookmark note field is showing.
private struct MakeWindowKey: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { KeyRequestingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyRequestingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.isVisible, window.canBecomeKey, !window.isKeyWindow else { return }
            window.makeKey()
        }
    }
}

// MARK: - Artwork

/// Album art (or a placeholder) with the playing app's icon as a badge;
/// clicking it brings that app forward.
struct MediaArtworkView: View {
    @EnvironmentObject private var media: MediaEngine
    let side: CGFloat
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let badge = max(14, side * 0.34)
        Button(action: openSourceApp) {
            ZStack(alignment: .bottomTrailing) {
                artwork
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .scaleEffect(hover.isOn && media.sourceBundleID != nil && !SparkVMotion.reduceMotion ? 1.03 : 1)
                    .shadow(color: glowColor.opacity(0.45), radius: 6)

                badgeView
                    .frame(width: badge, height: badge)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    .offset(x: badge * 0.28, y: badge * 0.28)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        // A click presses the art down to 97 %; hover lifts it with a plain
        // ease (no spring wobble on something passed over many times a day).
        // Nothing to open without a source app, so no press either.
        .buttonStyle(SparkVPressStyle(scale: media.sourceBundleID == nil ? 1 : SparkVMotion.pressedScale))
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(media.sourceBundleID == nil ? "" : "Open the playing app")
        .accessibilityLabel(media.artwork == nil ? "No artwork" : "Artwork for \(media.title)")
    }

    private var glowColor: Color {
        guard let tint = media.artworkTint, media.isShowingGlow else { return .clear }
        return Color(nsColor: tint)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = media.artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                SparkVTheme.surface
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.38, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        if let icon = media.sourceIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .background(Circle().fill(Color.black))
                .clipShape(Circle())
        } else {
            Circle()
                .fill(media.source.badgeColor)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.17, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    private func openSourceApp() {
        guard let bundleID = media.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Buttons

/// Transport button with a soft hover circle; symbol changes cross-morph.
struct MediaControlButton: View {
    let systemImage: String
    var size: CGFloat = 12
    var help: String = ""
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(hover.isOn ? LabsBStyle.hoverGlyph : SparkVTheme.text)
                .frame(width: 26, height: 20)
                .background(Circle().fill(hover.isOn ? LabsBStyle.hoverFill : Color.clear).frame(width: 22, height: 22))
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The heart: Favorite in Music, Save to Your Library in Spotify. Bounces
/// when it changes; dimmed while the state is unknown.
struct MediaLikeButton: View {
    @EnvironmentObject private var media: MediaEngine
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let liked = media.isLiked == true
        Button {
            media.toggleLike()
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(liked ? SparkVTheme.choose(apple: Color.pink, sparkv: SparkVTheme.red)
                                       : (hover.isOn ? LabsBStyle.hoverGlyph : SparkVTheme.textSecondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hover.isOn ? LabsBStyle.hoverFill : Color.clear).frame(width: 20, height: 20))
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(liked ? "Remove from Favorites" : (media.scriptablePlayer == .spotify ? "Save to Your Library" : "Favorite"))
        .accessibilityLabel(liked ? "Remove from Favorites" : "Favorite")
        .accessibilityAddTraits(liked ? .isSelected : [])
    }
}

/// Registers interest in lyrics while on screen.
struct LyricsVisibility: View {
    var body: some View {
        Color.clear
            .mpReportsOnScreen { LyricsController.shared.setViewVisible($0) }
            .accessibilityHidden(true)
    }
}

// MARK: - Compact ticker

/// One-line "Title · Artist" that scrolls, for the compact pill or the
/// live-activity band: tiny artwork, the marquee, and an optional thin
/// progress line along the bottom.
struct MediaTicker: View {
    @ObservedObject private var energy = SparkVEnergy.shared
    @EnvironmentObject private var media: MediaEngine
    var artworkSide: CGFloat = 16
    var showsProgress = true
    var previewDate: Date? = nil
    var previewMarqueeElapsed: TimeInterval? = nil

    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)

    var body: some View {
        HStack(spacing: 7) {
            artwork
                .frame(width: artworkSide, height: artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: artworkSide * 0.25, style: .continuous))
            VStack(spacing: 2) {
                MarqueeText(text: line, font: Self.font, speed: 26, previewElapsed: previewMarqueeElapsed)
                if showsProgress, media.timing.isKnown {
                    progress
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing: \(line)")
    }

    private var line: String {
        media.artist.isEmpty ? media.title : "\(media.title) · \(media.artist)"
    }

    private var progress: some View {
        let timing = media.timing
        return TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 15), paused: previewDate != nil || timing.rate == 0 || energy.pausesDecoration)) { context in
            let fraction = timing.progress(at: previewDate ?? context.date)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(SparkVTheme.progressTint)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 2)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = media.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let icon = media.sourceIcon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: artworkSide * 0.55, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }
}
