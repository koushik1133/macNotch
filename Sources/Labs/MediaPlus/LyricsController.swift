import AppKit
import Combine
import CryptoKit
import SwiftUI

/// Synced lyrics from LRCLIB (lrclib.net: free, no key, no account).
///
/// Privacy: off until the user turns it on. When on, the title, artist,
/// album and length of a track go to lrclib.net, once per track and only
/// while lyrics are on screen (the drawer's lyrics view, the lyrics window,
/// or the band under the notch while music plays). Answers, including "no
/// lyrics", are cached in Application Support, so a track is asked about at
/// most once a week. Music's own lyrics (local files) are used first and
/// never leave the Mac.
///
/// The current line is found with a binary search and the next change is
/// scheduled for the moment it's due: one wake-up per line, none while
/// paused or hidden.
@MainActor
final class LyricsController: ObservableObject {
    static let shared = LyricsController()

    enum State: Equatable {
        /// Lyrics are turned off (nothing is fetched).
        case off
        /// Nothing playing, or nothing asked yet.
        case idle
        case loading
        case synced
        /// Only unsynced text exists.
        case plain
        case instrumental
        case notFound
        case failed(String)
    }

    // MARK: Settings

    /// The user's consent to look lyrics up on lrclib.net.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            AppLog.log("Lyrics: \(isEnabled ? "on (LRCLIB)" : "off")")
            if !isEnabled { reset() }
            evaluate()
        }
    }
    /// Home's media column shows the current and next line instead of
    /// title and artist.
    @Published var showsInDrawer: Bool {
        didSet { defaults.set(showsInDrawer, forKey: Keys.drawer); evaluate() }
    }
    /// A one-line band under the closed notch while music plays.
    @Published var showsUnderNotch: Bool {
        didSet { defaults.set(showsUnderNotch, forKey: Keys.band); evaluate() }
    }

    // MARK: Published state

    @Published private(set) var state: State
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainText: String?
    /// Line being sung; nil before the first one.
    @Published private(set) var currentIndex: Int?
    /// Where the lyrics came from ("LRCLIB", "Music").
    @Published private(set) var sourceName: String?

    var currentLine: LyricLine? { currentIndex.map { lines[$0] } }
    var nextLine: LyricLine? {
        let next = (currentIndex ?? -1) + 1
        return next < lines.count ? lines[next] : nil
    }

    private enum Keys {
        static let enabled = "Lyrics.enabled"
        static let drawer = "Lyrics.showsInDrawer"
        static let band = "Lyrics.showsUnderNotch"
    }

    private let defaults: UserDefaults
    private weak var media: MediaEngine?
    private weak var activities: ActivityCenter?
    private var cancellables: Set<AnyCancellable> = []
    private var visibleViews = 0
    private var loadedKey: String?
    private var fetchTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var isBandPosted = false
    /// A failed lookup isn't retried for a minute (offline, LRCLIB down).
    private var retryAfter: [String: Date] = [:]
    private let cache = LyricsCache()
    private let client = LRCLIBClient()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Keys.enabled)
        isEnabled = enabled
        showsInDrawer = defaults.object(forKey: Keys.drawer) as? Bool ?? true
        showsUnderNotch = defaults.bool(forKey: Keys.band)
        state = enabled ? .idle : .off
    }

    // MARK: Wiring

    /// Call once (MediaPlus.start does).
    func attach(media: MediaEngine, activities: ActivityCenter?) {
        self.media = media
        self.activities = activities
        cancellables.removeAll()
        media.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.mediaChanged() }
            .store(in: &cancellables)
        evaluate()
    }

    func detach() {
        cancellables.removeAll()
        tickTask?.cancel()
        fetchTask?.cancel()
        dismissBand()
        media = nil
    }

    /// Views that show lyrics register while on screen (fetching and line
    /// timing only run while someone looks).
    func setViewVisible(_ visible: Bool) {
        visibleViews = max(0, visibleViews + (visible ? 1 : -1))
        evaluate()
    }

    /// Jumps playback to a line (tap a line in the lyrics window).
    func seek(to line: LyricLine) {
        media?.seek(to: line.time + 0.05)
    }

    // MARK: Evaluation

    private var bandWanted: Bool {
        guard isEnabled, showsUnderNotch, let media else { return false }
        return media.isPlaying && media.source != .none
    }

    private var wantsLyrics: Bool {
        isEnabled && (visibleViews > 0 || bandWanted)
    }

    private var lastSeenKey: String?
    private var lastTiming: PlaybackTiming?
    private var lastPlaying: Bool?

    private func mediaChanged() {
        guard let media else { return }
        let key = media.trackKey
        let timing = media.timing
        let playing = media.isPlaying
        guard key != lastSeenKey || timing != lastTiming || playing != lastPlaying else { return }
        lastSeenKey = key
        lastTiming = timing
        lastPlaying = playing
        evaluate()
    }

    private func evaluate() {
        guard isEnabled else {
            if state != .off { state = .off }
            tickTask?.cancel()
            dismissBand()
            return
        }
        if state == .off { state = .idle }
        guard let media else { return }
        if wantsLyrics, let key = media.trackKey, !media.isAdvertisement {
            if key != loadedKey, (retryAfter[key] ?? .distantPast) < Date() { load(key: key, media: media) }
        } else if media.trackKey == nil {
            reset()
            state = .idle
        }
        scheduleTick()
        updateBand()
    }

    private func reset() {
        fetchTask?.cancel()
        fetchTask = nil
        tickTask?.cancel()
        loadedKey = nil
        lines = []
        plainText = nil
        currentIndex = nil
        sourceName = nil
        state = isEnabled ? .idle : .off
    }

    // MARK: Loading

    private func load(key: String, media: MediaEngine) {
        fetchTask?.cancel()
        loadedKey = key
        lines = []
        plainText = nil
        currentIndex = nil
        sourceName = nil
        state = .loading
        let query = LRCLIBClient.Query(title: media.title, artist: media.artist, album: media.album,
                                       duration: media.duration > 0 ? media.duration : nil)
        let cache = cache
        let client = client
        fetchTask = Task { [weak self] in
            // Players report the title a beat before artist and length settle.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            if let entry = await cache.entry(for: key) {
                self.apply(entry, key: key)
                return
            }
            // Music's own lyrics (embedded in the file) stay on the Mac.
            if let local = await self.media?.musicLyrics(), !local.isEmpty {
                let synced = LRCParser.parse(local)
                let entry = LyricsCache.Entry(synced: synced.isEmpty ? nil : local, plain: synced.isEmpty ? local : nil,
                                              instrumental: false, source: "Music", fetchedAt: Date())
                self.apply(entry, key: key)
                return
            }
            do {
                let result = try await client.lookup(query)
                guard !Task.isCancelled else { return }
                let entry = LyricsCache.Entry(synced: result?.synced, plain: result?.plain,
                                              instrumental: result?.instrumental ?? false,
                                              source: result == nil ? nil : "LRCLIB", fetchedAt: Date())
                await cache.store(entry, for: key)
                self.apply(entry, key: key)
            } catch {
                guard !Task.isCancelled, self.loadedKey == key else { return }
                AppLog.log("Lyrics: lookup failed: \(error.localizedDescription)")
                self.state = .failed("Couldn’t reach LRCLIB")
                // Try again a minute later, next time this track is shown.
                self.loadedKey = nil
                self.retryAfter[key] = Date().addingTimeInterval(60)
            }
        }
    }

    private func apply(_ entry: LyricsCache.Entry, key: String) {
        guard loadedKey == key else { return }
        sourceName = entry.source
        if let synced = entry.synced, case let parsed = LRCParser.parse(synced), !parsed.isEmpty {
            lines = parsed
            plainText = entry.plain
            state = .synced
        } else if entry.instrumental {
            state = .instrumental
        } else if let plain = entry.plain, !plain.isEmpty {
            plainText = plain
            state = .plain
        } else {
            state = .notFound
        }
        scheduleTick()
        updateBand()
    }

    // MARK: Line timing

    /// Sets the current line and sleeps until the next one is due.
    private func scheduleTick() {
        tickTask?.cancel()
        tickTask = nil
        guard let media, state == .synced, !lines.isEmpty else {
            if currentIndex != nil, state != .synced { currentIndex = nil }
            return
        }
        let timing = media.timing
        let now = Date()
        let position = timing.position(at: now)
        let index = LyricsTimeline.index(at: position, in: lines)
        if index != currentIndex { currentIndex = index }
        // Hidden or paused: one update is enough.
        guard wantsLyrics, timing.rate > 0,
              let wait = LyricsTimeline.timeUntilNextLine(at: position, in: lines) else { return }
        let delay = wait / timing.rate + 0.02
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.scheduleTick()
        }
    }

    // MARK: Band under the notch

    private func updateBand() {
        let show = bandWanted && (state == .synced)
        if show, !isBandPosted { postBand() }
        if !show { dismissBand() }
    }

    private func postBand() {
        guard let activities else { return }
        isBandPosted = true
        let activity = LiveActivity(
            id: Self.bandID,
            kind: .media,
            priority: 25,
            duration: nil,
            height: NotchMetrics.activityBandHeight,
            opensTab: .nook,
            presentation: .expanded,
            symbol: "quote.bubble.fill"
        ) {
            LyricsBandView()
        }
        // While dictation holds the band, the wings keep the now-playing look.
        .compact(leading: { LyricsCompactArtwork() }, trailing: { LyricsCompactBars().frame(width: 14, height: 13) })
        // Listed as "Lyrics" (Live Activities settings, Show in Wings).
        .titled("Lyrics")
        activities.post(activity)
    }

    private func dismissBand() {
        guard isBandPosted else { return }
        isBandPosted = false
        activities?.dismiss(id: Self.bandID)
    }

    static let bandID = "media.lyrics"

    /// Fixed lyrics for offscreen renders and tests.
    func showPreview(lines: [LyricLine], currentIndex: Int?, state: State = .synced, source: String? = "LRCLIB") {
        isEnabled = true
        self.lines = lines
        self.currentIndex = currentIndex
        self.state = state
        sourceName = source
        loadedKey = media?.trackKey
    }
}

// MARK: - LRCLIB

/// The Media package's network session: ephemeral, no URL cache, no cookies,
/// so request URLs (song titles) and responses never land in
/// ~/Library/Caches. Lyrics are kept only in LyricsCache, which "Clear Saved
/// Lyrics" empties.
enum MPNetwork {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
}

/// GET https://lrclib.net/api/get (exact match by title, artist, album and
/// length), then /api/search as a fallback. A descriptive User-Agent, as
/// LRCLIB asks of clients.
struct LRCLIBClient: Sendable {
    struct Query: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval?
    }

    struct Result: Sendable {
        var synced: String?
        var plain: String?
        var instrumental: Bool
    }

    private static let base = URL(string: "https://lrclib.net/api/")!
    static let userAgent = "SparkV/1.0 (macOS notch app; lyrics view)"

    /// nil when LRCLIB has nothing for the track (404 or no plausible match).
    func lookup(_ query: Query) async throws -> Result? {
        if let exact = try await get(query) { return exact }
        return try await search(query)
    }

    private func get(_ query: Query) async throws -> Result? {
        guard !query.title.isEmpty, !query.artist.isEmpty else { return nil }
        var components = URLComponents(url: Self.base.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist)]
        if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
        if let duration = query.duration { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        let (data, status) = try await fetch(url)
        if status == 404 { return nil }
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return Self.result(from: object)
    }

    private func search(_ query: Query) async throws -> Result? {
        guard !query.title.isEmpty else { return nil }
        var components = URLComponents(url: Self.base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "track_name", value: LyricsMatch.stripDecorations(query.title))]
        if !query.artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: query.artist)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        let (data, status) = try await fetch(url)
        guard status == 200, let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if status == 404 { return nil }
            throw URLError(.badServerResponse)
        }
        let candidates = array.compactMap { item -> (LyricsMatch.Candidate, [String: Any])? in
            guard let id = item["id"] as? Int else { return nil }
            return (LyricsMatch.Candidate(
                id: id,
                trackName: item["trackName"] as? String ?? "",
                artistName: item["artistName"] as? String ?? "",
                duration: (item["duration"] as? NSNumber)?.doubleValue,
                hasSynced: !((item["syncedLyrics"] as? String) ?? "").isEmpty,
                hasPlain: !((item["plainLyrics"] as? String) ?? "").isEmpty,
                instrumental: item["instrumental"] as? Bool ?? false
            ), item)
        }
        guard let best = LyricsMatch.best(candidates.map(\.0), title: query.title, artist: query.artist, duration: query.duration),
              let item = candidates.first(where: { $0.0.id == best.id })?.1 else { return nil }
        return Self.result(from: item)
    }

    private func fetch(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await MPNetwork.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func result(from object: [String: Any]) -> Result? {
        let synced = (object["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plain = (object["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let instrumental = object["instrumental"] as? Bool ?? false
        guard synced != nil || plain != nil || instrumental else { return nil }
        return Result(synced: synced, plain: plain, instrumental: instrumental)
    }
}

// MARK: - Cache

/// One JSON file per track in ~/Library/Application Support/SparkV/Lyrics,
/// named by a hash of the track key. Misses are kept for a week.
actor LyricsCache {
    struct Entry: Codable, Sendable {
        var synced: String?
        var plain: String?
        var instrumental: Bool
        var source: String?
        var fetchedAt: Date

        var isMiss: Bool { synced == nil && plain == nil && !instrumental }
    }

    private let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SparkV/Lyrics", isDirectory: true)

    private func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".json")
    }

    func entry(for key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if entry.isMiss, Date().timeIntervalSince(entry.fetchedAt) > 7 * 24 * 3600 { return nil }
        return entry
    }

    func store(_ entry: Entry, for key: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url(for: key), options: .atomic)
        } catch {
            AppLog.log("Lyrics: couldn’t cache: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}

extension LyricsController {
    /// Deletes every cached lyric (Settings › Media › Lyrics).
    func clearCache() {
        let cache = cache
        Task { await cache.clear() }
        loadedKey = nil
        evaluate()
    }
}
