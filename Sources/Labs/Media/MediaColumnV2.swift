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
}

/// Redesigned Nook media column for the 115 pt drawer (about 170 x 69 pt):
/// artwork with the playing app's badge, scrolling title and artist, one
/// play/pause toggle between previous and next, a bookmark menu, and a
/// scrubber with bookmark ticks across the full width underneath.
struct MediaColumnV2: View {
    @EnvironmentObject private var media: MediaEngine
    /// Defaults to the shared store; tests pass a scratch one.
    @ObservedObject var bookmarks: MediaBookmarkStore = .shared
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
                    MarqueeText(text: media.title, font: Self.titleFont, previewElapsed: previewMarqueeElapsed)
                    MarqueeText(text: media.artist, font: Self.artistFont, color: SparkVTheme.textSecondary,
                                previewElapsed: previewMarqueeElapsed)
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
        .onAppear {
            if let position = previewNotePosition { model.notePosition = position }
        }
        .onChange(of: media.trackKey) { _, _ in
            // A note started for the previous track would land on the wrong one.
            model.notePosition = nil
        }
    }

    /// The elapsed part is white in Apple (iOS / macOS Now Playing) and
    /// SparkV red in SparkV Red; the artwork's own color stays in the glow
    /// behind the island (MediaGlowBackground).
    private var scrubberTint: Color { SparkVTheme.progressTint }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 0) {
            MediaControlButton(systemImage: "backward.fill", help: "Previous") { media.send(.previousTrack) }
            Spacer(minLength: 0)
            MediaControlButton(systemImage: media.isPlaying ? "pause.fill" : "play.fill", size: 15,
                               help: media.isPlaying ? "Pause" : "Play") {
                media.send(.togglePlayPause)
            }
            Spacer(minLength: 0)
            MediaControlButton(systemImage: "forward.fill", help: "Next") { media.send(.nextTrack) }
            Spacer(minLength: 0)
            bookmarkMenu
        }
        .frame(height: 20)
    }

    private var currentBookmarks: [MediaBookmark] {
        bookmarks.bookmarks(forTrack: media.trackKey)
    }

    private var bookmarkMenu: some View {
        let list = currentBookmarks
        let hours = media.duration >= 3600
        return Menu {
            Button("Bookmark This Moment") { addBookmark(note: "") }
            Button("Bookmark with Note…") {
                model.noteDraft = ""
                model.notePosition = media.elapsedTime
                noteFocused = true
            }
            if !list.isEmpty {
                Divider()
                Section("Jump To") {
                    ForEach(list) { bookmark in
                        Button(Self.menuTitle(bookmark, hours: hours)) { media.seek(to: bookmark.position) }
                    }
                }
                Divider()
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
        } label: {
            Image(systemName: list.isEmpty ? "bookmark" : "bookmark.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(media.canSeek ? (currentBookmarks.isEmpty ? SparkVTheme.textSecondary : SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red)) : SparkVTheme.textTertiary.opacity(0.7))
                .symbolEffect(.bounce, value: model.savedCount)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!media.canSeek || media.trackKey == nil)
        .help(list.isEmpty ? "Bookmark this moment" : "\(list.count) bookmark\(list.count == 1 ? "" : "s")")
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
            .buttonStyle(.plain)
            .help("Save bookmark")
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
        ZStack(alignment: .bottomTrailing) {
            artwork
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .scaleEffect(hover.isOn && media.sourceBundleID != nil ? 1.04 : 1)
                .shadow(color: glowColor.opacity(0.45), radius: 6)

            badgeView
                .frame(width: badge, height: badge)
                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                .offset(x: badge * 0.28, y: badge * 0.28)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onHover { hover.isOn = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.isOn)
        .onTapGesture { openSourceApp() }
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Compact ticker

/// One-line "Title · Artist" that scrolls, for the compact pill or the
/// live-activity band: tiny artwork, the marquee, and an optional thin
/// progress line along the bottom.
struct MediaTicker: View {
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
        return TimelineView(.animation(minimumInterval: 1.0 / 15, paused: previewDate != nil || timing.rate == 0)) { context in
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
