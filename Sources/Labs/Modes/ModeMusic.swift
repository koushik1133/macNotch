import AppKit
import AVFoundation

// Background music for SparkV Modes.
//
// A YouTube study stream plays in its own new Safari window that SparkV opens
// without bringing Safari forward, then minimizes once the page has started.
// That is the approach Keyboard Maestro and Shortcuts users rely on ("open URL
// in a new window in the background"): a real Safari page keeps the user's
// YouTube sign-in, Premium (no ads) and autoplay choices, and audio keeps
// playing in a minimized window. SparkV remembers the window it made and, when
// the mode ends, closes only the tab(s) it opened there, never the user's own
// windows. Safari is never quit.
//
// Other sources: "music-playlist:Name" plays a playlist in the Music app, and
// a direct audio stream URL (.mp3, .aac, .m4a, .m3u8 …) plays inside SparkV
// with AVPlayer.
//
// Every side effect goes through `ModeMusicEnvironment`, so tests can drive
// the player with a recording fake that never sends an Apple Event.

// MARK: - Errors

enum ModeMusicError: LocalizedError, Equatable, Sendable {
    case emptyURL
    case invalidURL(String)
    case unsupportedURL(String)
    case unavailable(String)
    case automationDenied(app: String)
    case appMissing(String)
    case noWindow
    case scriptFailed(code: Int, message: String)
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL: "Choose music or paste a link."
        case .invalidURL(let url): "\"\(url)\" isn't a web address."
        case .unsupportedURL(let url): "SparkV can't play \(url). Use a YouTube or other web link, an audio stream, or music-playlist:Name."
        case .unavailable(let title): "\"\(title)\" is no longer available on YouTube. Choose other music for this mode."
        case .automationDenied(let app):
            "SparkV isn't allowed to control \(app). Turn on \(app) for SparkV in System Settings > Privacy & Security > Automation."
        case .appMissing(let app): "\(app) isn't installed."
        case .noWindow: "Safari didn't open a window for the music."
        case .scriptFailed(let code, let message):
            message.isEmpty ? "Safari reported error \(code)." : message
        case .streamFailed(let reason): "The audio stream didn't start: \(reason)"
        }
    }
}

/// An AppleScript failure from the environment (code is the OSA error number).
struct ModeScriptError: Error, Equatable, Sendable {
    var code: Int
    var message: String
}

// MARK: - Source

enum ModeMusicSource: Equatable, Sendable {
    /// A web page opened in its own Safari window (YouTube, SoundCloud …).
    case safari(URL)
    /// A playlist in the Music app, by name.
    case musicPlaylist(String)
    /// A direct audio stream or file played in SparkV.
    case stream(URL)

    static let playlistPrefix = "music-playlist:"
    static let streamExtensions: Set<String> = ["mp3", "aac", "m4a", "mp4a", "wav", "aif", "aiff", "caf", "m3u8", "flac"]

    static func parse(_ raw: String) throws -> ModeMusicSource {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModeMusicError.emptyURL }
        guard !text.contains(where: { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false) }) else {
            throw ModeMusicError.invalidURL(text)
        }

        if text.lowercased().hasPrefix(playlistPrefix) {
            let name = text.dropFirst(playlistPrefix.count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ModeMusicError.invalidURL(text) }
            return .musicPlaylist(name)
        }

        // "youtube.com/watch?v=…" without a scheme.
        var candidate = text
        if !candidate.contains("://"), candidate.contains("."), !candidate.hasPrefix("/") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else {
            throw ModeMusicError.invalidURL(text)
        }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { throw ModeMusicError.invalidURL(text) }
            return streamExtensions.contains(url.pathExtension.lowercased()) ? .stream(url) : .safari(url)
        case "file":
            guard streamExtensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.isReadableFile(atPath: url.path)
            else { throw ModeMusicError.unsupportedURL(text) }
            return .stream(url)
        default:
            throw ModeMusicError.unsupportedURL(text)
        }
    }
}

// MARK: - Library

struct ModeMusicLibraryEntry: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case lofi = "Lofi"
        case focus = "Deep Focus"
        case classical = "Classical"
        case jazz = "Jazz"
        case nature = "Rain & Nature"
        case noise = "Noise"
    }

    let id: String
    let title: String
    let channel: String
    let category: Category
    let symbol: String
    /// A normal youtube.com watch URL.
    let url: String
    /// Tried in order when `url` has gone away (24/7 streams get replaced).
    let alternates: [String]
    let isLive: Bool
    /// Old links to the same stream (ended live streams). A mode saved with
    /// one of these plays `url` instead.
    var formerURLs: [String] = []

    var choice: ModeMusicChoice { ModeMusicChoice(title: title, url: url, volume: nil, openInBackground: true) }
}

/// Well-known long study streams and mixes. Each URL was checked against
/// YouTube's oEmbed endpoint (200 with a title) on 2026-10-21; the player
/// re-checks at start and falls back to the alternates.
enum ModeMusicLibrary {
    static let verifiedOn = "2026-10-21"
    static let customURLTitle = "Custom URL"

    static let lofiStudyID = "lofi-girl-study"
    static let classicalStudyID = "classical-mozart-study"
    static let rainID = "rain-woods"
    static let deepFocusID = "deep-focus"

    static let entries: [ModeMusicLibraryEntry] = [
        ModeMusicLibraryEntry(
            id: lofiStudyID, title: "lofi hip hop radio – beats to relax/study to", channel: "Lofi Girl",
            category: .lofi, symbol: "headphones",
            url: "https://www.youtube.com/watch?v=rFZHOHl-L8A",
            alternates: ["https://www.youtube.com/watch?v=7NOSDKb0HlU", "https://www.youtube.com/watch?v=5yx6BWlEVcY"],
            isLive: true,
            // The 2022-2025 stream, ended (oEmbed answers 200 with no title).
            formerURLs: ["https://www.youtube.com/watch?v=jfKfPfyJRdk"]),
        ModeMusicLibraryEntry(
            id: "lofi-girl-sleep", title: "lofi hip hop radio – beats to sleep/chill to", channel: "Lofi Girl",
            category: .lofi, symbol: "moon.zzz",
            url: "https://www.youtube.com/watch?v=JD-kMIpDfnY",
            alternates: ["https://www.youtube.com/watch?v=rFZHOHl-L8A"],
            isLive: true,
            formerURLs: ["https://www.youtube.com/watch?v=28KRPhVzCus"]),
        ModeMusicLibraryEntry(
            id: "lofi-girl-jazz", title: "jazz lofi radio – beats to chill/study to", channel: "Lofi Girl",
            category: .lofi, symbol: "music.note",
            url: "https://www.youtube.com/watch?v=E2vONfzoyRI",
            alternates: ["https://www.youtube.com/watch?v=rFZHOHl-L8A"],
            isLive: true),
        ModeMusicLibraryEntry(
            id: "lofi-girl-synthwave", title: "synthwave radio – beats to chill/game to", channel: "Lofi Girl",
            category: .lofi, symbol: "waveform",
            url: "https://www.youtube.com/watch?v=4xDzrJKXOOY",
            alternates: ["https://www.youtube.com/watch?v=rFZHOHl-L8A"],
            isLive: true),
        ModeMusicLibraryEntry(
            id: "chillhop-radio", title: "Chillhop Radio – jazzy & lofi hip hop beats", channel: "Chillhop Music",
            category: .lofi, symbol: "cup.and.saucer",
            url: "https://www.youtube.com/watch?v=5yx6BWlEVcY",
            alternates: ["https://www.youtube.com/watch?v=7NOSDKb0HlU"],
            isLive: true),
        ModeMusicLibraryEntry(
            id: deepFocusID, title: "4 Hours of Deep Focus Music for Studying", channel: "Quiet Quest - Study Music",
            category: .focus, symbol: "brain.head.profile",
            url: "https://www.youtube.com/watch?v=Ie5GGRkjSXE",
            alternates: ["https://www.youtube.com/watch?v=hpltvTEiRrY", "https://www.youtube.com/watch?v=sjkrrmBnpGE"],
            isLive: false),
        ModeMusicLibraryEntry(
            id: "ambient-study", title: "Ambient Study Music To Concentrate – 4 Hours", channel: "Quiet Quest - Study Music",
            category: .focus, symbol: "sparkles",
            url: "https://www.youtube.com/watch?v=sjkrrmBnpGE",
            alternates: ["https://www.youtube.com/watch?v=4GnVDPD01as"],
            isLive: false),
        ModeMusicLibraryEntry(
            id: "relaxing-piano-radio", title: "relaxing piano radio – calm music to focus to", channel: "Lofi Girl",
            category: .focus, symbol: "pianokeys",
            url: "https://www.youtube.com/watch?v=N0snMcR6aaA",
            alternates: ["https://www.youtube.com/watch?v=WLWJy1eXX2c"],
            isLive: true),
        ModeMusicLibraryEntry(
            id: classicalStudyID, title: "Mozart – Classical Music for Studying, Working & Brain Power", channel: "HALIDONMUSIC",
            category: .classical, symbol: "music.quarternote.3",
            url: "https://www.youtube.com/watch?v=3AkZazth0a0",
            alternates: ["https://www.youtube.com/watch?v=51Gm5q6Z07E", "https://www.youtube.com/watch?v=iUohO2MSot8"],
            isLive: false),
        ModeMusicLibraryEntry(
            id: "classical-piano-8h", title: "8 Hours Classical Piano – Chopin, Debussy, Mozart, Bach", channel: "HALIDONMUSIC",
            category: .classical, symbol: "pianokeys.inverse",
            url: "https://www.youtube.com/watch?v=WLWJy1eXX2c",
            alternates: ["https://www.youtube.com/watch?v=3AkZazth0a0"],
            isLive: false),
        ModeMusicLibraryEntry(
            id: "coffee-shop-jazz", title: "Cozy Coffee Shop – Smooth Piano Jazz for Studying", channel: "Relaxing Jazz Piano",
            category: .jazz, symbol: "cup.and.saucer.fill",
            url: "https://www.youtube.com/watch?v=MYPVQccHhAQ",
            alternates: ["https://www.youtube.com/watch?v=E2vONfzoyRI"],
            isLive: false),
        ModeMusicLibraryEntry(
            id: rainID, title: "Rain Sounds in the Woods – 10 Hours", channel: "Relaxing White Noise",
            category: .nature, symbol: "cloud.rain",
            url: "https://www.youtube.com/watch?v=9oc8Fa7tb8c",
            alternates: ["https://www.youtube.com/watch?v=yIQd2Ya0Ziw", "https://www.youtube.com/watch?v=ekXFslHOvZ8"],
            isLive: false),
        ModeMusicLibraryEntry(
            id: "rainstorm-calm", title: "Rainstorm Sounds for Relaxing, Focus or Deep Sleep – 8 Hours", channel: "Calm",
            category: .nature, symbol: "cloud.bolt.rain",
            url: "https://www.youtube.com/watch?v=yIQd2Ya0Ziw",
            alternates: ["https://www.youtube.com/watch?v=9oc8Fa7tb8c"],
            isLive: false),
        ModeMusicLibraryEntry(
            id: "brown-noise", title: "Deep Layered Brown Noise – 10 Hours", channel: "crysknife007",
            category: .noise, symbol: "waveform.path",
            url: "https://www.youtube.com/watch?v=GrwTSN2Saak",
            alternates: ["https://www.youtube.com/watch?v=hXetO_bYcMo"],
            isLive: false),
    ]

    static func entry(id: String) -> ModeMusicLibraryEntry? {
        entries.first { $0.id == id }
    }

    /// The library entry whose main URL or an alternate is the same video.
    static func entry(matching url: String) -> ModeMusicLibraryEntry? {
        let key = youTubeVideoID(from: url) ?? url
        return entries.first { entry in
            ([entry.url] + entry.alternates + entry.formerURLs).contains { (youTubeVideoID(from: $0) ?? $0) == key }
        }
    }

    /// Every curated choice, in library order (for pickers).
    static var all: [ModeMusicChoice] { entries.map(\.choice) }

    static func entries(in category: ModeMusicLibraryEntry.Category) -> [ModeMusicLibraryEntry] {
        entries.filter { $0.category == category }
    }

    // Choices the built-in modes use.
    static var lofiStudy: ModeMusicChoice { entry(id: lofiStudyID)!.choice }
    static var classicalStudy: ModeMusicChoice { entry(id: classicalStudyID)!.choice }
    static var rainSounds: ModeMusicChoice { entry(id: rainID)!.choice }
    static var deepFocus: ModeMusicChoice { entry(id: deepFocusID)!.choice }

    /// A choice for a link the user pasted. Throws when SparkV can't play it.
    static func customChoice(url: String, title: String? = nil, volume: Double? = nil) throws -> ModeMusicChoice {
        _ = try ModeMusicSource.parse(url)
        let name = title?.trimmingCharacters(in: .whitespaces)
        return ModeMusicChoice(
            title: (name?.isEmpty == false ? name : nil) ?? customURLTitle,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            volume: volume,
            openInBackground: true
        )
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// "rFZHOHl-L8A" from watch?v=, youtu.be/, /live/, /embed/ or /shorts/ links.
    static func youTubeVideoID(from raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), isYouTube(url) else { return nil }
        let isID: (String) -> Bool = { id in
            id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        if url.host?.lowercased() == "youtu.be" {
            let id = String(url.path.dropFirst())
            return isID(id) ? id : nil
        }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           isID(v) {
            return v
        }
        let parts = url.pathComponents
        if parts.count >= 3, ["live", "embed", "shorts", "v"].contains(parts[1]), isID(parts[2]) {
            return parts[2]
        }
        return nil
    }

    /// YouTube playlist id ("list=…"), for links without a video.
    static func youTubePlaylistID(from raw: String) -> String? {
        guard let url = URL(string: raw), isYouTube(url) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "list" })?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func oEmbedURL(for url: String) -> URL? {
        // URLComponents leaves "&" and "=" alone in query values, so encode
        // the whole link by hand.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json")
    }
}

// MARK: - Link check

enum ModeLinkStatus: Equatable, Sendable {
    case available(title: String)
    /// Removed, private or an ended stream.
    case gone
    /// Offline, timed out or not a YouTube link: play it anyway.
    case unknown

    /// Reads an oEmbed response. YouTube answers 200 with no title for
    /// streams that ended, 401 for videos that can't be embedded (they still
    /// play on youtube.com) and 400/404 for missing ones.
    static func fromOEmbed(status: Int, body: Data) -> ModeLinkStatus {
        switch status {
        case 200:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let title = json?["title"] as? String, !title.isEmpty, json?["author_name"] as? String != nil {
                return .available(title: title)
            }
            return .gone
        case 401, 403:
            return .available(title: "")
        case 400, 404, 410:
            return .gone
        default:
            return .unknown
        }
    }
}

// MARK: - AppleScript text

/// Builds every AppleScript the player sends. Pure functions, so tests can
/// check the text without running it.
enum ModeSafariScript {
    static let safariBundleID = "com.apple.Safari"
    static let musicBundleID = "com.apple.Music"

    /// An AppleScript string literal (quotes and backslashes escaped).
    static func literal(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n", "\r", "\t": escaped += " "
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Opens `url` in a new Safari window and returns that window's id. The
    /// window is found by comparing window ids before and after, so it works
    /// even when Safari restores other windows at the same moment.
    static func openWindow(url: URL, matchToken: String, activate: Bool) -> String {
        """
        with timeout of 30 seconds
            tell application id "\(safariBundleID)"
                set beforeIDs to id of every window
                make new document with properties {URL:\(literal(url.absoluteString))}
                set found to missing value
                repeat 50 times
                    set newIDs to {}
                    repeat with w in windows
                        set wid to id of w
                        if beforeIDs does not contain wid then set end of newIDs to wid
                    end repeat
                    if (count of newIDs) is 1 then
                        set found to item 1 of newIDs
                    else if (count of newIDs) > 1 then
                        repeat with wref in newIDs
                            set candidateID to contents of wref
                            try
                                if (URL of current tab of window id candidateID as text) contains \(literal(matchToken)) then
                                    set found to candidateID
                                    exit repeat
                                end if
                            end try
                        end repeat
                        if found is missing value then set found to item 1 of newIDs
                    end if
                    if found is not missing value then exit repeat
                    delay 0.1
                end repeat
                \(activate ? "activate" : "")
                if found is missing value then return "nowindow"
                return found as text
            end tell
        end timeout
        """
    }

    /// Minimizes SparkV's window unless the user brought it forward.
    static func minimize(windowID: Int) -> String {
        guarded("""
            if exists window id \(windowID) then
                if not (frontmost and index of window id \(windowID) is 1) then
                    set miniaturized of window id \(windowID) to true
                    return "minimized"
                end if
                return "front"
            end if
            return "gone"
            """)
    }

    /// Best effort: starts the video and sets its volume when Safari allows
    /// JavaScript from Apple Events (Develop menu). Returns "playing",
    /// "paused" or "novideo"; fails harmlessly when JavaScript is off.
    static func nudgePlayback(windowID: Int, volume: Double?) -> String {
        let volumeLine = volume.map { "v.volume=\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), min(max($0, 0), 1)));" } ?? ""
        let javaScript = "(function(){var v=document.querySelector('video');if(!v){return 'novideo';}\(volumeLine)if(v.paused){v.play();}return v.paused?'paused':'playing';})()"
        return guarded("""
            if exists window id \(windowID) then
                return do JavaScript \(literal(javaScript)) in current tab of window id \(windowID)
            end if
            return "gone"
            """)
    }

    /// Closes SparkV's music. A window with only SparkV's tab is closed
    /// while that tab still shows SparkV's music (its video, or the same
    /// site, since YouTube moves on to the next video by itself); if the
    /// user took the window over for another site it stays open. In a
    /// window where the user opened more tabs only the tabs showing SparkV's
    /// video are closed and the rest stay. Returns "closed-window",
    /// "closed-tabs N", "left-open" or "gone". Never launches Safari.
    static func close(windowID: Int, matchTokens: [String], siteTokens: [String] = []) -> String {
        let tokens = matchTokens.filter { !$0.isEmpty }
        let tokenList = "{" + tokens.map(literal).joined(separator: ", ") + "}"
        let ownList = "{" + (tokens + siteTokens.filter { !$0.isEmpty }).map(literal).joined(separator: ", ") + "}"
        return guarded("""
            if not (exists window id \(windowID)) then return "gone"
            set w to window id \(windowID)
            set tabCount to count of tabs of w
            if tabCount is 1 then
                set onlyURL to ""
                try
                    set onlyURL to (URL of tab 1 of w) as text
                end try
                set ours to (onlyURL is "" or onlyURL is "missing value")
                repeat with token in \(ownList)
                    if onlyURL contains (contents of token) then set ours to true
                end repeat
                if not ours then return "left-open"
                close w
                return "closed-window"
            end if
            set tokens to \(tokenList)
            set closedCount to 0
            repeat with i from tabCount to 1 by -1
                set tabURL to ""
                try
                    set tabURL to (URL of tab i of w) as text
                end try
                repeat with token in tokens
                    if tabURL contains (contents of token) then
                        close tab i of w
                        set closedCount to closedCount + 1
                        exit repeat
                    end if
                end repeat
            end repeat
            if closedCount is 0 then return "left-open"
            return "closed-tabs " & closedCount
            """)
    }

    /// Plays a Music playlist and returns Music's previous sound volume.
    static func playPlaylist(name: String, volume: Double?) -> String {
        let volumeLine = volume.map { "set sound volume to \(Int((min(max($0, 0), 1) * 100).rounded()))" } ?? ""
        return """
        with timeout of 20 seconds
            tell application id "\(musicBundleID)"
                set previousVolume to sound volume
                \(volumeLine)
                play playlist \(literal(name))
                return previousVolume as text
            end tell
        end timeout
        """
    }

    /// Pauses Music only if it is still playing SparkV's playlist, then puts
    /// its volume back. Never launches Music.
    static func stopPlaylist(name: String, restoreVolume: Int?) -> String {
        let restoreLine = restoreVolume.map { "set sound volume to \($0)" } ?? ""
        return """
        if application id "\(musicBundleID)" is running then
            with timeout of 10 seconds
                tell application id "\(musicBundleID)"
                    set outcome to "other"
                    try
                        if player state is playing and (name of current playlist) is \(literal(name)) then
                            pause
                            set outcome to "paused"
                        end if
                    end try
                    \(restoreLine)
                    return outcome
                end tell
            end timeout
        end if
        return "notrunning"
        """
    }

    private static func guarded(_ body: String) -> String {
        """
        if application id "\(safariBundleID)" is running then
            with timeout of 10 seconds
                tell application id "\(safariBundleID)"
                    \(body)
                end tell
            end timeout
        end if
        return "notrunning"
        """
    }
}

// MARK: - Session

/// What SparkV started, saved so a relaunch can still stop it.
struct ModeMusicSession: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case safari, musicPlaylist, stream }

    var id = UUID()
    /// SparkV's process id. A session saved by an earlier SparkV process is
    /// an orphan: the next start() or stop() cleans it up.
    var ownerPID: Int32 = 0

    var kind: Kind
    var choice: ModeMusicChoice
    /// The URL actually opened (may be a library alternate).
    var openedURL: String
    var startedAt: Date
    var safariWindowID: Int?
    /// Safari's process id when the window was made; window ids restart
    /// with Safari, so a different pid means the window is gone.
    var safariPID: Int32?
    var matchTokens: [String]
    var playlistName: String?
    var previousMusicVolume: Int?
}

// MARK: - Environment

/// Every side effect the player has. `LiveModeMusicEnvironment` talks to
/// macOS; tests use a recording fake.
@MainActor
protocol ModeMusicEnvironment: AnyObject {
    func runAppleScript(_ source: String) async throws -> String
    /// Whether scripts to `bundleID` may run now. `mayAsk` (starting music,
    /// a user action) may show the Automation prompt once through
    /// PermissionCenter; stopping and orphan cleanup never ask.
    func automationReady(bundleID: String, mayAsk: Bool) async -> Bool
    func isRunning(bundleID: String) -> Bool
    func processIdentifier(bundleID: String) -> Int32?
    func isInstalled(bundleID: String) -> Bool
    /// Launches without activating (no window is brought forward).
    func launchInBackground(bundleID: String) async throws
    var frontmostProcessIdentifier: Int32? { get }
    func activate(processIdentifier: Int32)
    func wait(seconds: Double) async
    func checkLink(_ url: URL) async -> ModeLinkStatus
    func playStream(_ url: URL, volume: Double?) throws
    func stopStream()
    var isStreamPlaying: Bool { get }
    /// SparkV's own process id.
    var currentProcessIdentifier: Int32 { get }
    /// Sessions of every player, saved across launches.
    func loadSessions() -> [ModeMusicSession]
    func saveSessions(_ sessions: [ModeMusicSession])
}

extension ModeMusicEnvironment {
    /// Fakes: always allowed.
    func automationReady(bundleID: String, mayAsk: Bool) async -> Bool { true }
}

// MARK: - Player

@MainActor
final class ModeMusicPlayer: ObservableObject {
    static let shared = ModeMusicPlayer()

    struct Options: Sendable {
        /// Open the page in a window behind the user's app.
        var minimizeAfterStart = true
        /// How long the page gets to load and start before it is minimized
        /// (WebKit doesn't autoplay in a page that is hidden from the start).
        var settleSeconds: Double = 6
        var nudgePlaybackWithJavaScript = true
        /// Check YouTube links with oEmbed first and use an alternate if gone.
        var checkLinks = true
    }

    static let autoplayHint = "If the music doesn't start, open the SparkV music window in Safari, choose Safari > Settings for youtube.com… and set Auto-Play to Allow All Auto-Play."

    @Published private(set) var isPlaying = false
    @Published private(set) var current: ModeMusicChoice?
    /// One line for the editor's Test button and the activity band.
    @Published private(set) var statusText: String?

    private(set) var session: ModeMusicSession? {
        didSet { persist(old: oldValue) }
    }

    private let environment: ModeMusicEnvironment
    private var options: Options
    private var followUp: Task<Void, Never>?

    /// Each player (the mode's, the editor's Test button) keeps its own
    /// music; stopping one never touches another's window.
    init(environment: ModeMusicEnvironment? = nil, options: Options = Options()) {
        self.environment = environment ?? LiveModeMusicEnvironment()
        self.options = options
    }

    private func persist(old: ModeMusicSession?) {
        var all = environment.loadSessions()
        if let old { all.removeAll { $0.id == old.id } }
        if let session {
            all.removeAll { $0.id == session.id }
            all.append(session)
        }
        environment.saveSessions(all)
    }

    /// Stops music left by an earlier SparkV process (a crash or relaunch
    /// while a mode was on). Called by start() and stop(); the integration
    /// can also call it at launch.
    func cleanUpOrphans() async {
        let me = environment.currentProcessIdentifier
        let saved = environment.loadSessions()
        let orphans = saved.filter { $0.ownerPID != me }
        guard !orphans.isEmpty else { return }
        environment.saveSessions(saved.filter { $0.ownerPID == me })
        for orphan in orphans {
            _ = await end(orphan)
        }
    }

    /// Starts `choice`, stopping SparkV's previous music first.
    func start(_ choice: ModeMusicChoice) async throws {
        let source = try ModeMusicSource.parse(choice.url)
        if session != nil || isPlaying { await stop() } else { await cleanUpOrphans() }

        statusText = "Starting \(choice.title)…"
        do {
            switch source {
            case .safari(let url):
                try await startSafari(url, choice: choice)
            case .musicPlaylist(let name):
                try await startPlaylist(name, choice: choice)
            case .stream(let url):
                do {
                    try environment.playStream(url, volume: choice.volume)
                } catch {
                    throw ModeMusicError.streamFailed(error.localizedDescription)
                }
                session = ModeMusicSession(ownerPID: environment.currentProcessIdentifier, kind: .stream,
                                           choice: choice, openedURL: url.absoluteString,
                                           startedAt: Date(), matchTokens: [])
                statusText = "Playing \(choice.title)"
            }
        } catch {
            statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
        current = choice
        isPlaying = true
    }

    /// Stops what SparkV started: closes only its Safari tab or window,
    /// pauses Music only if it still plays SparkV's playlist, or stops the
    /// stream. Never quits an app or launches one.
    func stop() async {
        followUp?.cancel()
        followUp = nil
        let ending = session
        if ending != nil { session = nil }
        isPlaying = false
        current = nil
        if let ending {
            let outcome = await end(ending)
            statusText = outcome == "left-open"
                ? "SparkV left its Safari window open because it has your tabs in it."
                : nil
        } else {
            statusText = nil
        }
        await cleanUpOrphans()
    }

    /// Undoes one session. Returns the close script's answer for Safari.
    private func end(_ session: ModeMusicSession) async -> String? {
        switch session.kind {
        case .safari:
            // Window ids restart with Safari: only a window made by this
            // same Safari process can be SparkV's.
            guard let windowID = session.safariWindowID,
                  let pid = environment.processIdentifier(bundleID: ModeSafariScript.safariBundleID),
                  pid == session.safariPID,
                  await environment.automationReady(bundleID: ModeSafariScript.safariBundleID, mayAsk: false)
            else { return nil }
            return try? await environment.runAppleScript(
                ModeSafariScript.close(windowID: windowID, matchTokens: session.matchTokens,
                                       siteTokens: Self.siteTokens(for: [session.openedURL, session.choice.url]))
            )
        case .musicPlaylist:
            guard let name = session.playlistName,
                  environment.isRunning(bundleID: ModeSafariScript.musicBundleID),
                  await environment.automationReady(bundleID: ModeSafariScript.musicBundleID, mayAsk: false) else { return nil }
            return try? await environment.runAppleScript(
                ModeSafariScript.stopPlaylist(name: name, restoreVolume: session.previousMusicVolume)
            )
        case .stream:
            // Only this process's own AVPlayer can be stopped.
            if session.ownerPID == environment.currentProcessIdentifier { environment.stopStream() }
            return nil
        }
    }

    /// For the editor's Test button: plays `choice` until `stop()`.
    func test(_ choice: ModeMusicChoice) async throws {
        try await start(choice)
    }

    /// Waits for the minimize/nudge step after a background start (tests).
    func waitForFollowUp() async {
        await followUp?.value
    }

    // MARK: Safari

    private func startSafari(_ requested: URL, choice: ModeMusicChoice) async throws {
        let url = try await reachableURL(for: requested, title: choice.title)
        let safari = ModeSafariScript.safariBundleID
        guard environment.isInstalled(bundleID: safari) else { throw ModeMusicError.appMissing("Safari") }

        let previousFront = environment.frontmostProcessIdentifier
        if !environment.isRunning(bundleID: safari) {
            if choice.openInBackground {
                try await environment.launchInBackground(bundleID: safari)
            }
        }

        guard await environment.automationReady(bundleID: safari, mayAsk: true) else {
            throw ModeMusicError.automationDenied(app: "Safari")
        }
        let tokens = Self.matchTokens(for: url, requested: requested)
        let output: String
        do {
            output = try await environment.runAppleScript(
                ModeSafariScript.openWindow(url: url, matchToken: tokens.first ?? url.absoluteString,
                                            activate: !choice.openInBackground)
            )
        } catch let error as ModeScriptError {
            throw Self.mapScriptError(error, app: "Safari")
        }
        guard let windowID = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ModeMusicError.noWindow
        }
        let safariPID = environment.processIdentifier(bundleID: safari)

        // Opening a document can bring Safari forward; give focus back.
        if choice.openInBackground, let previousFront, let safariPID, previousFront != safariPID,
           environment.frontmostProcessIdentifier == safariPID {
            environment.activate(processIdentifier: previousFront)
        }

        session = ModeMusicSession(ownerPID: environment.currentProcessIdentifier, kind: .safari, choice: choice, openedURL: url.absoluteString, startedAt: Date(),
                                   safariWindowID: windowID, safariPID: safariPID, matchTokens: tokens)
        statusText = choice.openInBackground
            ? "Playing \(choice.title) in a background Safari window"
            : "Playing \(choice.title) in Safari"

        guard choice.openInBackground else { return }
        let options = self.options
        let volume = choice.volume
        followUp = Task { [weak self] in
            guard let self else { return }
            await self.environment.wait(seconds: options.settleSeconds)
            guard !Task.isCancelled, self.session?.safariWindowID == windowID else { return }
            if options.nudgePlaybackWithJavaScript {
                let state = try? await self.environment.runAppleScript(
                    ModeSafariScript.nudgePlayback(windowID: windowID, volume: volume)
                )
                guard !Task.isCancelled, self.session?.safariWindowID == windowID else { return }
                if state == "paused" { self.statusText = Self.autoplayHint }
            }
            if options.minimizeAfterStart {
                _ = try? await self.environment.runAppleScript(ModeSafariScript.minimize(windowID: windowID))
            }
        }
    }

    /// The requested URL, or a library alternate when YouTube says the
    /// requested video is gone. Network trouble never blocks playback.
    private func reachableURL(for requested: URL, title: String) async throws -> URL {
        // A link to an ended stream the library knows about (a mode saved
        // with the old Lofi Girl link) plays the current stream, even offline.
        var url = requested
        if let id = ModeMusicLibrary.youTubeVideoID(from: requested.absoluteString),
           let entry = ModeMusicLibrary.entry(matching: requested.absoluteString),
           entry.formerURLs.contains(where: { ModeMusicLibrary.youTubeVideoID(from: $0) == id }),
           let current = URL(string: entry.url) {
            url = current
        }
        guard options.checkLinks, ModeMusicLibrary.isYouTube(url) else { return url }
        if await environment.checkLink(url) != .gone { return url }
        let entry = ModeMusicLibrary.entry(matching: url.absoluteString)
        let alternates = entry.map { [$0.url] + $0.alternates } ?? []
        for alternate in alternates {
            guard let candidate = URL(string: alternate), candidate != url else { continue }
            if await environment.checkLink(candidate) != .gone { return candidate }
        }
        throw ModeMusicError.unavailable(title)
    }

    /// The sites SparkV's window may still show when it closes it
    /// ("youtube.com/", or the page's host without "www.").
    nonisolated static func siteTokens(for urls: [String]) -> [String] {
        var tokens: [String] = []
        for raw in urls {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased() else { continue }
            if ModeMusicLibrary.isYouTube(url) {
                tokens += ["youtube.com/", "youtu.be/"]
            } else {
                tokens.append(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
        }
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }

    /// Strings that identify SparkV's tab when closing it: the video id
    /// (YouTube rewrites the rest of the URL), else the playlist id, else
    /// the URL without its scheme.
    static func matchTokens(for url: URL, requested: URL) -> [String] {
        var tokens: [String] = []
        for candidate in [url, requested] {
            let text = candidate.absoluteString
            if let id = ModeMusicLibrary.youTubeVideoID(from: text) {
                tokens.append(id)
            } else if let list = ModeMusicLibrary.youTubePlaylistID(from: text) {
                tokens.append("list=\(list)")
            } else if let host = candidate.host {
                tokens.append(host + candidate.path)
            }
        }
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }

    // MARK: Music app

    private func startPlaylist(_ name: String, choice: ModeMusicChoice) async throws {
        let music = ModeSafariScript.musicBundleID
        guard environment.isInstalled(bundleID: music) else { throw ModeMusicError.appMissing("Music") }
        if !environment.isRunning(bundleID: music) {
            try await environment.launchInBackground(bundleID: music)
        }
        guard await environment.automationReady(bundleID: music, mayAsk: true) else {
            throw ModeMusicError.automationDenied(app: "Music")
        }
        let output: String
        do {
            output = try await environment.runAppleScript(ModeSafariScript.playPlaylist(name: name, volume: choice.volume))
        } catch let error as ModeScriptError {
            throw Self.mapScriptError(error, app: "Music")
        }
        session = ModeMusicSession(ownerPID: environment.currentProcessIdentifier, kind: .musicPlaylist, choice: choice, openedURL: choice.url, startedAt: Date(),
                                   matchTokens: [], playlistName: name,
                                   previousMusicVolume: choice.volume == nil ? nil : Int(output.trimmingCharacters(in: .whitespaces)))
        statusText = "Playing \(name) in Music"
    }

    static func mapScriptError(_ error: ModeScriptError, app: String) -> ModeMusicError {
        switch error.code {
        case -1743, -1744: .automationDenied(app: app)
        case -600, -10814: .appMissing(app)
        default: .scriptFailed(code: error.code, message: error.message)
        }
    }
}

// MARK: - Live environment

@MainActor
final class LiveModeMusicEnvironment: ModeMusicEnvironment {
    private static let sessionKey = "SparkV.Modes.MusicSessions"
    private let defaults: UserDefaults
    private let scripts = ModeAppleScriptQueue()
    private var player: AVPlayer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func runAppleScript(_ source: String) async throws -> String {
        try await scripts.run(source)
    }

    func automationReady(bundleID: String, mayAsk: Bool) async -> Bool {
        await ModeAutomation.ready(bundleID: bundleID, mayAsk: mayAsk, feature: "Modes music")
    }

    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func processIdentifier(bundleID: String) -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func launchInBackground(bundleID: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ModeMusicError.appMissing(bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // Give it a moment to accept Apple Events.
        for _ in 0..<20 where !isRunning(bundleID: bundleID) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    var frontmostProcessIdentifier: Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func activate(processIdentifier: Int32) {
        guard let target = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        if let front = NSWorkspace.shared.frontmostApplication {
            target.activate(from: front, options: [])
        } else {
            target.activate()
        }
    }

    func wait(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }

    func checkLink(_ url: URL) async -> ModeLinkStatus {
        guard let endpoint = ModeMusicLibrary.oEmbedURL(for: url.absoluteString) else { return .unknown }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unknown }
        return ModeLinkStatus.fromOEmbed(status: http.statusCode, body: data)
    }

    func playStream(_ url: URL, volume: Double?) throws {
        stopStream()
        let player = AVPlayer(url: url)
        if let volume { player.volume = Float(min(max(volume, 0), 1)) }
        player.play()
        self.player = player
    }

    func stopStream() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    var isStreamPlaying: Bool {
        player?.timeControlStatus == .playing || player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    var currentProcessIdentifier: Int32 { ProcessInfo.processInfo.processIdentifier }

    func loadSessions() -> [ModeMusicSession] {
        guard let data = defaults.data(forKey: Self.sessionKey) else { return [] }
        return (try? JSONDecoder().decode([ModeMusicSession].self, from: data)) ?? []
    }

    func saveSessions(_ sessions: [ModeMusicSession]) {
        if !sessions.isEmpty, let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: Self.sessionKey)
        } else {
            defaults.removeObject(forKey: Self.sessionKey)
        }
    }
}

/// Runs NSAppleScript on one serial background queue (NSAppleScript isn't
/// thread-safe, and a slow Safari must not block the main thread).
final class ModeAppleScriptQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sparkv.modes.applescript", qos: .userInitiated)

    func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: ModeScriptError(code: 0, message: "Couldn't compile the script."))
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? ""
                    continuation.resume(throwing: ModeScriptError(code: code, message: message))
                } else {
                    continuation.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }
}
