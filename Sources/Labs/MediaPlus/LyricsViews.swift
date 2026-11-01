import AppKit
import SwiftUI

// MARK: - Media column (Home)

/// The current line (bright) and the next one (dim), in the media column's
/// title/artist slot. Line changes crossfade upward; Reduce Motion fades.
/// Falls back to the title and artist when there's nothing to sing.
struct MediaLyricsLines: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var lyrics = LyricsController.shared
    var previewElapsed: TimeInterval? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch lyrics.state {
            case .synced:
                let current = lyrics.currentLine
                let next = lyrics.nextLine
                Group {
                    line(current.map(text) ?? "♪", primary: true)
                    if media.notice == nil {
                        line(next.map(text) ?? "", primary: false)
                    }
                }
                .id(lyrics.currentIndex ?? -1)
                .transition(lineTransition)
                // A failed action ("Add to Library first") takes the next
                // line's place for its few seconds.
                if let notice = media.notice {
                    Text(notice)
                        .font(Font(MediaColumnV2.artistFont as CTFont))
                        .foregroundStyle(SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.opacity)
                }
            case .loading:
                line(media.title, primary: true)
                line("Finding lyrics…", primary: false)
            case .instrumental:
                line(media.title, primary: true)
                line("Instrumental", primary: false)
            case .plain:
                line(media.title, primary: true)
                line("Lyrics aren’t synced · open the Lyrics window", primary: false)
            case .notFound, .failed, .idle, .off:
                line(media.title, primary: true)
                line(statusText, primary: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: lyrics.currentIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var statusText: String {
        switch lyrics.state {
        case .notFound: "No lyrics found"
        case .failed(let message): message
        default: media.artist
        }
    }

    private var accessibilityText: String {
        if let notice = media.notice { return notice }
        if lyrics.state == .synced, let line = lyrics.currentLine, !line.isGap { return "Lyrics: \(line.text)" }
        return "\(media.title), \(statusText)"
    }

    private func text(_ line: LyricLine) -> String { line.isGap ? "♪" : line.text }

    private var lineTransition: AnyTransition {
        if SparkVMotion.reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity.combined(with: .offset(y: -6)))
    }

    private func line(_ text: String, primary: Bool) -> some View {
        MarqueeText(
            text: text,
            font: primary ? MediaColumnV2.titleFont : MediaColumnV2.artistFont,
            color: primary ? SparkVTheme.text : SparkVTheme.textSecondary,
            previewElapsed: previewElapsed
        )
    }
}

// MARK: - Band under the notch

/// One line under the closed notch: the current lyric, centred; the band
/// crossfades between lines.
struct LyricsBandView: View {
    @ObservedObject private var lyrics = LyricsController.shared

    var body: some View {
        let line = lyrics.currentLine
        // Icon and line centred together under the notch.
        HStack(spacing: 7) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
                .accessibilityHidden(true)
            Text(line.map { $0.isGap ? "♪" : $0.text } ?? "♪")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .truncationMode(.tail)
                .id(lyrics.currentIndex ?? -1)
                .transition(.sparkVCrossfade)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: lyrics.currentIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.map { "Lyrics: \($0.text)" } ?? "Lyrics")
    }
}

/// Leading wing while the lyrics activity rides in the wings: the artwork,
/// like the now-playing wing.
/// The Lyrics band's wing bars: they rest while playback is paused.
struct LyricsCompactBars: View {
    @EnvironmentObject private var media: MediaEngine

    var body: some View {
        MediaLiveLevelBars(isAnimating: media.isPlaying)
    }
}

struct LyricsCompactArtwork: View {
    @EnvironmentObject private var media: MediaEngine

    var body: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    SparkVTheme.surfaceHover
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityLabel("Lyrics for \(media.title)")
    }
}

// MARK: - Lyrics window (karaoke view)

/// Every line, the current one large and bright, the rest dim; click a line
/// to jump there. Scrolls to keep the current line in view (instantly under
/// Reduce Motion). Unsynced lyrics show as plain text.
struct LyricsPanelView: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var lyrics = LyricsController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 34)
                .padding(.bottom, 12)
            Divider().overlay(SparkVTheme.stroke)
            content
        }
        .frame(minWidth: 360, minHeight: 420)
        .background(LabsBWindowGround())
        // Window-aware: closing the Lyrics window stops lookups and line
        // timing even though the window (and this view) are kept around.
        .mpReportsOnScreen { LyricsController.shared.setViewVisible($0) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let art = media.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        SparkVTheme.surface
                        Image(systemName: "music.note").foregroundStyle(SparkVTheme.textTertiary)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(media.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SparkVTheme.text).lineLimit(1)
                Text(media.artist).font(.system(size: 12)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
            }
            Spacer()
            if let source = lyrics.sourceName {
                Text(source.uppercased())
                    .font(SparkVTheme.eyebrow(9))
                    .tracking(LabsBStyle.eyebrowTracking(1.0))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !lyrics.isEnabled {
            consent
        } else {
            switch lyrics.state {
            case .synced:
                synced
            case .plain:
                ScrollView {
                    Text(lyrics.plainText ?? "")
                        .font(.system(size: 15, weight: .medium))
                        .lineSpacing(6)
                        .foregroundStyle(SparkVTheme.text.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(22)
                }
            case .loading:
                placeholder("Finding lyrics…", systemImage: "text.magnifyingglass")
            case .instrumental:
                placeholder("Instrumental", systemImage: "pianokeys")
            case .notFound:
                placeholder("No lyrics for this track on LRCLIB", systemImage: "text.badge.xmark")
            case .failed(let message):
                placeholder(message, systemImage: "wifi.exclamationmark")
            case .idle, .off:
                placeholder(media.source == .none ? "Play something to see its lyrics" : "Lyrics appear here", systemImage: "quote.bubble")
            }
        }
    }

    private var synced: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        LyricsPanelLine(line: line, isCurrent: index == lyrics.currentIndex,
                                        isPast: (lyrics.currentIndex ?? -1) > index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 26)
            }
            .onChange(of: lyrics.currentIndex) { _, index in
                guard let index else { return }
                if SparkVMotion.reduceMotion {
                    proxy.scrollTo(index, anchor: .center)
                } else {
                    withAnimation(SparkVMotion.easeInOut(0.28)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .onAppear { if let index = lyrics.currentIndex { proxy.scrollTo(index, anchor: .center) } }
        }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synced lyrics come from LRCLIB, a free, community-run lyrics library.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
            MPPrivacyNote(text: "When on, the title, artist, album and length of a playing track are sent to lrclib.net, once per track and only while lyrics are on screen. Lyrics saved in Music are read on your Mac first.")
            Button("Turn On Lyrics") { lyrics.isEnabled = true }
                .buttonStyle(SparkVPrimaryButtonStyle())
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(SparkVTheme.textTertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(SparkVTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LyricsPanelLine: View {
    let line: LyricLine
    let isCurrent: Bool
    let isPast: Bool
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            LyricsController.shared.seek(to: line)
        } label: {
            Text(line.isGap ? "♪" : line.text)
                .font(.system(size: isCurrent ? 20 : 16, weight: isCurrent ? .bold : .semibold))
                .foregroundStyle(isCurrent ? SparkVTheme.text : SparkVTheme.text.opacity(hover.isOn ? 0.7 : (isPast ? 0.32 : 0.45)))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: isCurrent)
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle(scale: 0.99))
        .onHover { hover.isOn = $0 }
        .help("Play from here")
        .accessibilityLabel(line.isGap ? "Instrumental" : line.text)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint("Plays from this line")
    }
}

/// The lyrics window (hub tile, gear menu).
@MainActor
enum LyricsWindow {
    /// Needs the app's MediaEngine: set by MediaPlus.start.
    static weak var media: MediaEngine?

    static let shared = MPWindowController(
        title: "Lyrics — SparkV", autosave: "SparkV.Lyrics",
        size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 420)
    ) {
        if let media = LyricsWindow.media {
            AnyView(LyricsPanelView().environmentObject(media).followsAppearance())
        } else {
            AnyView(Text("Lyrics need the media engine").padding())
        }
    }
}

// MARK: - Hub tile

/// Agents hub tile (Media): opens the lyrics window. Lit while lyrics are on.
struct LyricsHubTile: View {
    @ObservedObject private var lyrics = LyricsController.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            LyricsWindow.shared.show()
        } label: {
            MPHubTileFace(title: "Lyrics", systemImage: "quote.bubble.fill", tint: .pink,
                          isActive: lyrics.isEnabled && lyrics.state == .synced, isHovered: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu { LyricsMenuItems() }
        .help(lyrics.isEnabled ? "Synced lyrics for what's playing. Right-click for options." : "Synced lyrics (off). Click to set up.")
    }
}
