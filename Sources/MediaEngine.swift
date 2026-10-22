import AppKit
import ApplicationServices
import SwiftUI

/// System-wide "now playing" reader and transport controller.
///
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` only describe and receive
/// commands for *this* process, and since macOS 15.4 the MediaRemote framework
/// refuses third-party callers. So the primary source is `NowPlayingAdapter`:
/// Apple's own `/usr/bin/perl` loads a small bundled framework that is allowed
/// to read MediaRemote, and streams JSON for whatever is playing — Safari,
/// Chrome, Music, Spotify, Podcasts, anything.
///
/// If the adapter ever stops working (a future macOS closing the gap), the
/// engine falls back to Apple Events for Music and Spotify, and to hardware
/// media-key events for transport (needs Accessibility).
@MainActor
final class MediaEngine: ObservableObject {
    enum Command: Sendable {
        case togglePlayPause
        case nextTrack
        case previousTrack

        /// MRCommand IDs understood by `mediaremote-adapter.pl send`.
        var adapterID: Int {
            switch self {
            case .togglePlayPause: 2
            case .nextTrack: 4
            case .previousTrack: 5
            }
        }

        var mediaKeyCode: Int32 {
            switch self {
            case .togglePlayPause: 16 // NX_KEYTYPE_PLAY
            case .nextTrack: 17 // NX_KEYTYPE_NEXT
            case .previousTrack: 18 // NX_KEYTYPE_PREVIOUS
            }
        }
    }

    enum Source: Equatable {
        case none
        /// Any app reported by the system Now Playing service.
        case app(bundleID: String)
        case player(ScriptablePlayer)
        /// The player is open but SparkV hasn't been allowed to automate it yet.
        case needsPermission(ScriptablePlayer)
        /// Automation for the player was turned off in System Settings.
        case denied(ScriptablePlayer)

        var badgeColor: Color {
            switch self {
            case .player(.spotify): Color(red: 0.11, green: 0.73, blue: 0.33)
            case .player(.music), .app: Color(red: 0.98, green: 0.24, blue: 0.33)
            case .needsPermission, .denied: SparkVTheme.warning
            case .none: Color(white: 0.35)
            }
        }
    }

    @Published private(set) var title = "Not Playing"
    @Published private(set) var artist = "Play something in any app"
    @Published private(set) var artwork: NSImage? {
        didSet {
            guard artwork !== oldValue else { return }
            artworkTint = artwork.flatMap(ArtworkPalette.glowColor(for:))
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var source: Source = .none
    /// Icon of the app that owns Now Playing (Safari, Music, …), for the badge.
    @Published private(set) var sourceIcon: NSImage?
    /// Where playback is, as an anchor the UI extrapolates from (see
    /// `PlaybackTiming`). Published only when the player reports a change, a
    /// seek or a play/pause, never per frame: views read the live position
    /// with `elapsedTime(at:)` inside a `TimelineView`.
    @Published private(set) var timing: PlaybackTiming = .unknown
    /// Vibrant color pulled from the artwork, for the island's glow
    /// (boring.notch style). Nil without artwork.
    @Published private(set) var artworkTint: NSColor?

    /// Playback position right now, interpolated from the last report.
    var elapsedTime: TimeInterval { timing.position(at: Date()) }
    /// Track length in seconds; 0 when the player doesn't say (live streams).
    var duration: TimeInterval { timing.duration }
    func elapsedTime(at date: Date) -> TimeInterval { timing.position(at: date) }
    /// The player reported a length and a position, so a scrubber makes sense.
    var canSeek: Bool { source != .none && timing.isKnown }

    /// Bundle id of the app that owns Now Playing, when known.
    var sourceBundleID: String? {
        switch source {
        case .app(let bundleID): bundleID.isEmpty ? nil : bundleID
        case .player(let player): player.bundleID
        case .none, .needsPermission, .denied: nil
        }
    }

    /// Stable identity of the current track (app + title + artist), used to
    /// key bookmarks. Nil when nothing is playing.
    var trackKey: String? {
        guard let app = sourceBundleID else { return nil }
        return Self.trackKey(app: app, title: title, artist: artist)
    }

    nonisolated static func trackKey(app: String, title: String, artist: String) -> String {
        func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        return [app.lowercased(), normalize(title), normalize(artist)].joined(separator: "\u{1F}")
    }
    /// Show the artwork and a level meter beside the closed notch while
    /// something plays (gear menu › Live Activities). On by default.
    @Published var showsInClosedNotch: Bool {
        didSet { UserDefaults.standard.set(showsInClosedNotch, forKey: Self.closedNotchKey) }
    }

    /// Something is playing and the closed island should say so.
    var isShowingClosedActivity: Bool {
        showsInClosedNotch && isPlaying && source != .none
    }

    private static let closedNotchKey = "NowPlaying.showsInClosedNotch"

    private let adapter = NowPlayingAdapter()
    /// The adapter is streaming. Cleared if it keeps failing, which switches
    /// on the Apple Events fallback.
    private var adapterHealthy: Bool
    private var lastArtworkVersion = -1
    /// Play state as the adapter last reported it; `send` flips `isPlaying`
    /// ahead of the adapter and falls back to this if nothing confirms it.
    private var lastReportedIsPlaying = false
    /// Bumped on every adapter update, so a pending revert can tell whether
    /// one arrived after the command.
    private var adapterUpdateGeneration = 0
    private var revertTask: Task<Void, Never>?
    private var iconCache: [String: NSImage] = [:]

    private let players = PlayerBridge()
    private var isActive = false
    private var pollTimer: Timer?
    /// A player poll is in flight; timer ticks are skipped until it returns.
    private var isPollingPlayers = false
    private var artworkKey: String?
    private var artworkAttempts = 0
    private var artworkTask: Task<Void, Never>?
    /// A seek the player hasn't confirmed yet: reports that still show the
    /// old position are ignored until it lands or the deadline passes, so the
    /// scrubber doesn't snap back.
    private var pendingSeek: (target: TimeInterval, issuedAt: Date)?
    /// Bumped per seek, so a late revert can tell it belongs to an older one.
    private var seekGeneration = 0
    private var seekRevertTask: Task<Void, Never>?
    /// Timing as the adapter last reported it, even while a seek is pending:
    /// what the player really says, to fall back on if a seek never lands.
    private var lastAdapterTiming: PlaybackTiming?
    /// Elapsed/timestamp pair of the last adapter report, to notice a pause
    /// that arrives without a fresh position.
    private var lastReportedAnchor: (elapsed: TimeInterval, date: Date, rate: Double)?

    init() {
        showsInClosedNotch = UserDefaults.standard.object(forKey: Self.closedNotchKey) as? Bool ?? true
        adapterHealthy = adapter != nil
        guard let adapter else {
            AppLog.log("Media: Now Playing adapter missing from the app bundle; using the Apple Events fallback")
            return
        }
        adapter.onUpdate = { [weak self] info in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.show(info) }
            }
        }
        adapter.onFailure = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.adapterFailed() }
            }
        }
        adapter.start()
    }

    /// The adapter streams continuously; polling is only needed for the fallback.
    func setActive(_ active: Bool) {
        isActive = active
        pollTimer?.invalidate()
        pollTimer = nil
        guard active, !adapterHealthy else { return }

        refreshFromPlayers()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromPlayers() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        adapter?.stop()
        setActive(false)
    }

    func send(_ command: Command) {
        if adapterHealthy, let adapter {
            if case .app = source, command == .togglePlayPause {
                isPlaying.toggle()
                reanchorTiming(playing: isPlaying)
                scheduleRevertIfUnconfirmed()
            }
            adapter.send(command.adapterID) { [weak self] status in
                guard status != 0 else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.revertOptimisticPlayState() }
                }
            }
            return
        }

        switch source {
        case .needsPermission(let player):
            // PermissionCenter asks off the main thread, one prompt at a time,
            // and opens Settings instead once the user has answered.
            Task {
                _ = await PermissionCenter.shared.request(.automation(bundleID: player.bundleID), from: "Media")
                refreshFromPlayers()
            }
            return
        case .denied(let player):
            PermissionCenter.shared.openSettings(.automation(bundleID: player.bundleID), from: "Media")
            return
        case .player(let player):
            if command == .togglePlayPause {
                isPlaying.toggle()
                reanchorTiming(playing: isPlaying)
            }
            Task {
                await players.send(command, to: player)
                try? await Task.sleep(for: .milliseconds(400))
                refreshFromPlayers()
            }
            return
        case .app, .none:
            break
        }

        if PermissionCenter.shared.isGranted(.accessibility) {
            MediaKey.post(command.mediaKeyCode)
        } else {
            // A tap is a user action: the prompt shows once per signature,
            // later taps open the Accessibility pane instead of re-prompting.
            Task { _ = await PermissionCenter.shared.request(.accessibility, from: "Media keys") }
        }
    }

    // MARK: - Seeking

    /// Moves playback to `position` seconds. The scrubber jumps there at once;
    /// the player's own report confirms it a moment later.
    func seek(to position: TimeInterval) {
        guard canSeek, position.isFinite else { return }
        let target = min(max(0, position), max(0, timing.duration - 0.25))
        let now = Date()
        pendingSeek = (target, now)
        timing = PlaybackTiming(elapsed: target, anchor: now, rate: timing.rate, duration: timing.duration)

        if adapterHealthy, let adapter, case .app(let bundleID) = source {
            scheduleSeekRevertIfUnconfirmed()
            let fallbackPlayer = ScriptablePlayer.allCases.first { $0.bundleID == bundleID }
            adapter.seek(toMicros: Int64((target * 1_000_000).rounded())) { [weak self] status in
                guard status != 0 else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // The adapter couldn't do it; Music and Spotify can
                        // still be told directly if they're already allowed.
                        if let fallbackPlayer {
                            Task { _ = await self.players.seek(fallbackPlayer, to: target) }
                        } else {
                            self.pendingSeek = nil
                        }
                    }
                }
            }
            return
        }

        if case .player(let player) = source {
            Task {
                _ = await players.seek(player, to: target)
                try? await Task.sleep(for: .milliseconds(300))
                refreshFromPlayers()
            }
        }
    }

    /// Jumps forward (positive) or back (negative) by `seconds`.
    func skip(by seconds: TimeInterval) {
        seek(to: elapsedTime + seconds)
    }

    /// The adapter only reports changes, and `seek` exits 0 even when the
    /// player ignores it (MRMediaRemoteSetElapsedTime has no result). Without
    /// this the scrubber would stay at the optimistic spot forever; after the
    /// pending window it goes back to what the player last said.
    private func scheduleSeekRevertIfUnconfirmed() {
        seekGeneration += 1
        let generation = seekGeneration
        seekRevertTask?.cancel()
        seekRevertTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled, let self, self.seekGeneration == generation,
                  self.pendingSeek != nil else { return }
            self.pendingSeek = nil
            guard self.adapterHealthy, let reported = self.lastAdapterTiming else { return }
            let now = Date()
            let rate: Double = self.isPlaying ? (reported.rate > 0 ? reported.rate : 1) : 0
            let restored = reported.reanchored(at: now, rate: rate)
            if abs(restored.position(at: now) - self.timing.position(at: now)) > 1.5 {
                AppLog.log("Media: seek not confirmed by Now Playing; showing the player's position again")
            }
            self.timing = restored
        }
    }

    /// Keeps the position where it is now and continues at the new rate.
    private func reanchorTiming(playing: Bool) {
        guard timing.isKnown || timing.elapsed > 0 else { return }
        timing = timing.reanchored(at: Date(), rate: playing ? 1 : 0)
    }

    /// Accepts a player-reported timing unless it contradicts a seek that is
    /// still in flight.
    private func applyReportedTiming(_ reported: PlaybackTiming) {
        let now = Date()
        if let pending = pendingSeek {
            let landed = abs(reported.position(at: now) - (pending.target + now.timeIntervalSince(pending.issuedAt) * reported.rate)) < 1.5
            if landed || now.timeIntervalSince(pending.issuedAt) > 2.5 {
                pendingSeek = nil
            } else {
                // Still the old position; keep the optimistic one but follow
                // play/pause and length changes.
                let current = timing.reanchored(at: now, rate: reported.rate)
                timing = PlaybackTiming(elapsed: current.elapsed, anchor: now, rate: reported.rate, duration: reported.duration)
                return
            }
        }
        if timing != reported { timing = reported }
    }

    // MARK: - Previews

    /// Puts the engine into a fixed state for offscreen renders, previews and
    /// tests. Not used by the running app.
    func showPreview(
        title: String,
        artist: String,
        artwork: NSImage?,
        isPlaying: Bool,
        bundleID: String = "com.apple.Music",
        timing: PlaybackTiming
    ) {
        apply(title: title, artist: artist, isPlaying: isPlaying, source: .app(bundleID: bundleID))
        self.artwork = artwork
        self.timing = timing
    }

    // MARK: - Adapter

    /// The adapter only emits when something changes, so a command that had
    /// no effect would leave the optimistic play/pause icon wrong forever.
    private func scheduleRevertIfUnconfirmed() {
        revertTask?.cancel()
        let generation = adapterUpdateGeneration
        revertTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.adapterUpdateGeneration == generation else { return }
            self.revertOptimisticPlayState()
        }
    }

    private func revertOptimisticPlayState() {
        revertTask?.cancel()
        revertTask = nil
        guard adapterHealthy, isPlaying != lastReportedIsPlaying else { return }
        AppLog.log("Media: play/pause not confirmed by Now Playing; showing \(lastReportedIsPlaying ? "playing" : "paused") again")
        isPlaying = lastReportedIsPlaying
        reanchorTiming(playing: isPlaying)
    }

    private func show(_ info: NowPlayingAdapter.Info?) {
        guard adapterHealthy else { return }
        adapterUpdateGeneration += 1
        lastReportedIsPlaying = info?.isPlaying ?? false
        revertTask?.cancel()
        revertTask = nil
        guard let info else {
            apply(title: "Not Playing", artist: "Play something in any app", isPlaying: false, source: .none)
            if artwork != nil { artwork = nil }
            lastArtworkVersion = -1
            sourceIcon = nil
            pendingSeek = nil
            lastReportedAnchor = nil
            lastAdapterTiming = nil
            if timing != .unknown { timing = .unknown }
            return
        }

        let owner = info.parentBundleID ?? info.bundleID ?? ""
        let trackChanged = info.title != title || source != .app(bundleID: owner)
        if trackChanged {
            AppLog.log("Media: now playing “\(info.title)” from \(owner) (playing: \(info.isPlaying))")
            pendingSeek = nil
        }
        let reported = adapterTiming(for: info, trackChanged: trackChanged)
        lastAdapterTiming = reported
        applyReportedTiming(reported)
        apply(
            title: info.title,
            artist: info.artist.isEmpty ? (info.album.isEmpty ? appName(for: owner) : info.album) : info.artist,
            isPlaying: info.isPlaying,
            source: .app(bundleID: owner)
        )
        sourceIcon = icon(for: owner)

        if info.artworkVersion != lastArtworkVersion {
            lastArtworkVersion = info.artworkVersion
            artwork = info.artworkData.flatMap(NSImage.init(data:))
        }
    }

    /// MediaRemote reports the elapsed time at a timestamp plus a playback
    /// rate; the live position is `elapsed + (now - timestamp) * rate`.
    private func adapterTiming(for info: NowPlayingAdapter.Info, trackChanged: Bool) -> PlaybackTiming {
        let duration = max(0, info.duration ?? 0)
        // Paused players often keep reporting rate 1, and some web players
        // omit the rate entirely.
        let rate: Double = info.isPlaying ? max(0, info.playbackRate ?? 1) : 0
        let now = Date()

        guard let elapsed = info.elapsed else {
            // No position: keep extrapolating the old one for the same track.
            if !trackChanged, timing.isKnown || timing.elapsed > 0 {
                return PlaybackTiming(elapsed: timing.position(at: now), anchor: now, rate: rate, duration: duration)
            }
            return PlaybackTiming(elapsed: 0, anchor: now, rate: rate, duration: duration)
        }

        let anchorDate = info.timestamp ?? now
        // Play state flipped but the player sent the same anchor as before:
        // pause or resume from where the old report says playback is now
        // instead of jumping back to the old anchor.
        if !trackChanged, let last = lastReportedAnchor,
           abs(last.elapsed - elapsed) < 0.001, abs(last.date.timeIntervalSince(anchorDate)) < 0.001,
           last.rate != rate {
            // Continue from the position already derived (it has followed
            // every earlier stale-anchor pause/resume); recomputing from the
            // stale anchor would jump back after a pause and resume that
            // both arrived without a new position.
            let previous = PlaybackTiming(elapsed: last.elapsed, anchor: last.date, rate: last.rate, duration: duration)
            let position = (timing.isKnown || timing.elapsed > 0) ? timing.position(at: now) : previous.position(at: now)
            lastReportedAnchor = (elapsed, anchorDate, rate)
            return PlaybackTiming(elapsed: position, anchor: now, rate: rate, duration: duration)
        }
        if let last = lastReportedAnchor, !trackChanged,
           abs(last.elapsed - elapsed) < 0.001, abs(last.date.timeIntervalSince(anchorDate)) < 0.001,
           last.rate == rate, timing.anchor > anchorDate {
            // Nothing new about the position (e.g. only the artwork changed):
            // keep the re-anchored timing we already derived.
            return PlaybackTiming(elapsed: timing.elapsed, anchor: timing.anchor, rate: rate, duration: duration)
        }
        lastReportedAnchor = (elapsed, anchorDate, rate)
        return PlaybackTiming(elapsed: elapsed, anchor: anchorDate, rate: rate, duration: duration)
    }

    private func adapterFailed() {
        guard adapterHealthy else { return }
        AppLog.log("Media: Now Playing adapter keeps failing; switching to the Apple Events fallback")
        adapterHealthy = false
        clear()
        setActive(isActive)
    }

    private func icon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Apple Events fallback

    private func refreshFromPlayers() {
        guard !isPollingPlayers else { return }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        // Only query players that are already open; scripting a closed app would launch it.
        let candidates = ScriptablePlayer.allCases.filter { running.contains($0.bundleID) }
        guard !candidates.isEmpty else {
            clear()
            return
        }

        isPollingPlayers = true
        Task {
            let readings = await players.read(candidates)
            isPollingPlayers = false
            guard !adapterHealthy else { return }
            show(readings)
        }
    }

    private func show(_ readings: [PlayerReading]) {
        let snapshots = readings.compactMap { reading -> ScriptablePlayer.Snapshot? in
            if case .track(let snapshot) = reading { return snapshot }
            return nil
        }

        if let snapshot = snapshots.first(where: \.isPlaying) ?? snapshots.first {
            apply(
                title: snapshot.title,
                artist: snapshot.artist,
                isPlaying: snapshot.isPlaying,
                source: .player(snapshot.player)
            )
            applyPlayerTiming(snapshot)
            sourceIcon = icon(for: snapshot.player.bundleID)
            loadArtworkIfNeeded(for: snapshot)
            return
        }

        resetArtwork(for: nil)
        if timing != .unknown { timing = .unknown }
        // A player that can be controlled outranks one that is waiting for or
        // was refused Automation access.
        for reading in readings {
            if case .stopped(let player) = reading {
                apply(title: player.name, artist: "Not playing", isPlaying: false, source: .player(player))
                sourceIcon = icon(for: player.bundleID)
                return
            }
        }
        for reading in readings {
            if case .needsPermission(let player) = reading {
                apply(title: "Connect \(player.name)", artist: "Press play to allow access",
                      isPlaying: false, source: .needsPermission(player))
                return
            }
        }
        for reading in readings {
            if case .denied(let player) = reading {
                apply(title: "\(player.name) Access Off", artist: "Allow in Privacy › Automation",
                      isPlaying: false, source: .denied(player))
                return
            }
        }
        clear()
    }

    /// AppleScript polls every 2 s; re-anchor only when the extrapolation
    /// drifted, so the scrubber doesn't tick back and forth by the poll latency.
    private func applyPlayerTiming(_ snapshot: ScriptablePlayer.Snapshot) {
        guard let position = snapshot.position else {
            if timing != .unknown { timing = .unknown }
            return
        }
        let now = Date()
        let reported = PlaybackTiming(
            elapsed: position,
            anchor: now,
            rate: snapshot.isPlaying ? 1 : 0,
            duration: snapshot.duration ?? 0
        )
        let drift = abs(timing.position(at: now) - position)
        if drift > 0.75 || timing.rate != reported.rate || abs(timing.duration - reported.duration) > 0.5 {
            applyReportedTiming(reported)
        } else {
            pendingSeek = nil
        }
    }

    private func loadArtworkIfNeeded(for snapshot: ScriptablePlayer.Snapshot) {
        let key = [
            snapshot.player.bundleID,
            snapshot.title,
            snapshot.artist,
            snapshot.artworkURL?.absoluteString ?? "",
        ].joined(separator: "|")
        if key != artworkKey {
            resetArtwork(for: key)
        }

        // Retry a few times: players often report a new track before its artwork is ready.
        guard artwork == nil, artworkTask == nil, artworkAttempts < 3 else { return }
        if snapshot.player == .spotify, snapshot.artworkURL == nil { return }
        artworkAttempts += 1

        let players = players
        artworkTask = Task { [weak self] in
            let data: Data? = switch snapshot.player {
            case .music:
                await players.musicArtwork()
            case .spotify:
                if let url = snapshot.artworkURL {
                    try? await URLSession.shared.data(from: url).0
                } else {
                    nil
                }
            }
            guard let self, !Task.isCancelled, self.artworkKey == key else { return }
            self.artworkTask = nil
            if let data, let image = NSImage(data: data) {
                self.artwork = image
            }
        }
    }

    private func resetArtwork(for key: String?) {
        artworkKey = key
        artworkAttempts = 0
        artworkTask?.cancel()
        artworkTask = nil
        if artwork != nil { artwork = nil }
    }

    // MARK: - State helpers

    private func apply(title: String, artist: String, isPlaying: Bool, source: Source) {
        if self.title != title { self.title = title }
        if self.artist != artist { self.artist = artist }
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
        if self.source != source { self.source = source }
    }

    private func clear() {
        apply(title: "Not Playing", artist: "Play something in any app", isPlaying: false, source: .none)
        if timing != .unknown { timing = .unknown }
        pendingSeek = nil
        sourceIcon = nil
        resetArtwork(for: nil)
    }
}

// MARK: - Playback timing

/// A playback position as players report it: `elapsed` seconds at `anchor`,
/// advancing at `rate` (0 while paused). The live position is extrapolated
/// on demand, the way MediaRemote clients (boring.notch, NotchNook) do it.
struct PlaybackTiming: Equatable, Sendable {
    var elapsed: TimeInterval
    var anchor: Date
    var rate: Double
    /// Track length in seconds; 0 when unknown (live streams, some web players).
    var duration: TimeInterval

    static let unknown = PlaybackTiming(elapsed: 0, anchor: .distantPast, rate: 0, duration: 0)

    /// A length is known, so progress and seeking make sense.
    var isKnown: Bool { duration > 0 }

    func position(at date: Date) -> TimeInterval {
        let advanced = elapsed + max(0, date.timeIntervalSince(anchor)) * rate
        let clamped = max(0, advanced)
        return duration > 0 ? min(clamped, duration) : clamped
    }

    /// 0...1 through the track, or 0 when the length is unknown.
    func progress(at date: Date) -> Double {
        duration > 0 ? position(at: date) / duration : 0
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, duration - position(at: date))
    }

    /// Same position at `date`, continuing at a new rate from there.
    func reanchored(at date: Date, rate newRate: Double) -> PlaybackTiming {
        PlaybackTiming(elapsed: position(at: date), anchor: date, rate: newRate, duration: duration)
    }
}

// MARK: - Artwork palette

/// Picks the color the island glows with from album art: the most
/// prominent *vibrant* hue rather than the plain average (which turns most
/// covers into mud). Hue-bucketed and saturation-weighted over a 32x32
/// thumbnail, like Android's Palette "vibrant" swatch; covers without any
/// color fall back to a soft neutral of their average brightness.
enum ArtworkPalette {
    static func glowColor(for image: NSImage) -> NSColor? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return glowColor(for: cgImage)
    }

    static func glowColor(for image: CGImage) -> NSColor? {
        guard let pixels = thumbnailPixels(image) else { return nil }
        return glowColor(fromRGBA: pixels)
    }

    /// Core of the extraction, on raw sRGB RGBA8 pixels (for tests).
    static func glowColor(fromRGBA pixels: [UInt8]) -> NSColor? {
        let bucketCount = 18
        var weights = [Double](repeating: 0, count: bucketCount)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bucketCount)
        var total: (r: Double, g: Double, b: Double, n: Double) = (0, 0, 0, 0)

        var index = 0
        while index + 3 < pixels.count {
            let alpha = Double(pixels[index + 3]) / 255
            if alpha > 0.5 {
                // Pixels are premultiplied; undo it for the true color.
                let r = Double(pixels[index]) / 255 / alpha
                let g = Double(pixels[index + 1]) / 255 / alpha
                let b = Double(pixels[index + 2]) / 255 / alpha
                total.r += r; total.g += g; total.b += b; total.n += 1

                let (hue, saturation, brightness) = hsb(r, g, b)
                // Skip near-black, near-white and gray pixels.
                if saturation > 0.22, brightness > 0.2 {
                    let bucket = min(bucketCount - 1, Int(hue * Double(bucketCount)))
                    // Favor rich, bright pixels; very dark ones count less.
                    let weight = saturation * saturation * (0.35 + brightness)
                    weights[bucket] += weight
                    sums[bucket].r += r * weight
                    sums[bucket].g += g * weight
                    sums[bucket].b += b * weight
                }
            }
            index += 4
        }
        guard total.n > 0 else { return nil }

        // Merge each bucket with its neighbors so a hue split across a
        // bucket border still wins.
        var best = -1
        var bestScore = 0.0
        for bucket in 0..<bucketCount {
            let score = weights[bucket]
                + 0.5 * weights[(bucket + 1) % bucketCount]
                + 0.5 * weights[(bucket + bucketCount - 1) % bucketCount]
            if score > bestScore { bestScore = score; best = bucket }
        }

        // Vibrant pixels must cover a meaningful part of the cover (about 3 %
        // of it at full saturation); otherwise treat the art as monochrome.
        if best >= 0, bestScore > total.n * 0.03 {
            var r = 0.0, g = 0.0, b = 0.0, w = 0.0
            for bucket in [(best + bucketCount - 1) % bucketCount, best, (best + 1) % bucketCount] {
                r += sums[bucket].r; g += sums[bucket].g; b += sums[bucket].b; w += weights[bucket]
            }
            let (hue, saturation, brightness) = hsb(r / w, g / w, b / w)
            return NSColor(
                calibratedHue: hue,
                saturation: min(1, max(0.55, saturation * 1.2)),
                brightness: min(0.95, max(0.7, brightness * 1.1)),
                alpha: 1
            ).usingColorSpace(.sRGB)
        }

        let (_, _, brightness) = hsb(total.r / total.n, total.g / total.n, total.b / total.n)
        return NSColor(white: min(0.85, max(0.55, brightness)), alpha: 1).usingColorSpace(.sRGB)
    }

    private static func thumbnailPixels(_ image: CGImage) -> [UInt8]? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue > 0 ? delta / maxValue : 0
        return (hue, saturation, maxValue)
    }
}

// MARK: - Now Playing adapter

/// Runs `/usr/bin/perl mediaremote-adapter.pl <framework> stream` and turns its
/// JSON lines into `Info` values. Everything except the callbacks happens on
/// one private serial queue.
final class NowPlayingAdapter: @unchecked Sendable {
    struct Info: Sendable {
        let title: String
        let artist: String
        let album: String
        let isPlaying: Bool
        let bundleID: String?
        /// Set for media playing inside a host app, e.g. Safari for a web player.
        let parentBundleID: String?
        let artworkData: Data?
        /// Bumped whenever the artwork changes, so the UI decodes it only then.
        let artworkVersion: Int
        /// Track length in seconds, when the player reports one.
        var duration: TimeInterval? = nil
        /// Position in seconds at `timestamp`.
        var elapsed: TimeInterval? = nil
        /// When `elapsed` was measured.
        var timestamp: Date? = nil
        /// 1 while playing at normal speed, 0 while paused; nil if unreported.
        var playbackRate: Double? = nil
    }

    var onUpdate: (@Sendable (Info?) -> Void)?
    var onFailure: (@Sendable () -> Void)?

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private let scriptPath: String
    private let frameworkPath: String
    private let queue = DispatchQueue(label: "SparkV.NowPlayingAdapter", qos: .userInitiated)

    // Only touched on `queue`.
    private var process: Process?
    private var buffer = Data()
    private var payload: [String: Any] = [:]
    private var artworkData: Data?
    private var artworkVersion = 0
    private var isStopping = false
    private var quickFailures = 0
    private var launchedAt = Date.distantPast

    init?() {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework").path
        guard FileManager.default.fileExists(atPath: script),
              FileManager.default.fileExists(atPath: framework)
        else { return nil }
        scriptPath = script
        frameworkPath = framework
    }

    func start() {
        queue.async { [self] in
            isStopping = false
            reapOrphanedStreams()
            launch()
        }
    }

    /// Synchronous, so the stream is signalled before the app goes on to
    /// quit; an async hop could be dropped at exit and orphan the stream.
    func stop() {
        queue.sync { [self] in
            isStopping = true
            if let process, process.isRunning {
                process.terminate()
            }
            process = nil
        }
    }

    /// Sends an MRCommand (2 = toggle play/pause, 4 = next, 5 = previous).
    /// `completion` gets the sender's exit status (-1 if it couldn't start),
    /// on an arbitrary queue.
    func send(_ commandID: Int, completion: (@Sendable (Int32) -> Void)? = nil) {
        run(["send", String(commandID)], label: "command \(commandID)", completion: completion)
    }

    /// Moves the Now Playing app to `micros` microseconds
    /// (MRMediaRemoteSetElapsedTime through `mediaremote-adapter.pl seek`).
    func seek(toMicros micros: Int64, completion: (@Sendable (Int32) -> Void)? = nil) {
        run(["seek", String(max(0, micros))], label: "seek", completion: completion)
    }

    private func run(_ arguments: [String], label: String, completion: (@Sendable (Int32) -> Void)?) {
        queue.async { [self] in
            let sender = Process()
            sender.executableURL = Self.perl
            sender.arguments = [scriptPath, frameworkPath] + arguments
            sender.standardOutput = FileHandle.nullDevice
            sender.standardError = FileHandle.nullDevice
            sender.terminationHandler = { finished in
                let status = finished.terminationStatus
                if status != 0 {
                    AppLog.log("Media: \(label) exited with status \(status)")
                }
                completion?(status)
            }
            do {
                try sender.run()
            } catch {
                sender.terminationHandler = nil
                AppLog.log("Media: could not send \(label): \(error.localizedDescription)")
                completion?(-1)
            }
        }
    }

    // MARK: Queue-confined

    /// A crash or force-quit leaves the previous stream running, reparented
    /// to launchd. Ends any of ours whose parent is pid 1.
    private func reapOrphanedStreams() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // pkill -f matches an extended regex; the bundle path can contain
        // "(", "[", "+" and so on, so it has to match literally.
        let pattern = Self.literalRegex("\(scriptPath) \(frameworkPath) stream")
        pkill.arguments = ["-P", "1", "-f", pattern]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        do {
            try pkill.run()
            pkill.waitUntilExit()
        } catch {
            AppLog.log("Media: could not check for orphaned adapters: \(error.localizedDescription)")
        }
    }

    /// Escapes every character POSIX extended regexes treat specially outside
    /// a bracket expression ("]" and "}" are literal there on their own).
    static func literalRegex(_ text: String) -> String {
        let special: Set<Character> = ["\\", "^", "$", ".", "[", "|", "(", ")", "*", "+", "?", "{"]
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if special.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private func launch() {
        let stream = Process()
        stream.executableURL = Self.perl
        // --micros: exact elapsed/timestamp values (the plain keys round the
        // timestamp to whole seconds), needed for a smooth scrubber.
        stream.arguments = [scriptPath, frameworkPath, "stream", "--micros", "--debounce=50"]
        stream.standardInput = FileHandle.nullDevice
        stream.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        stream.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            self.queue.async { self.consume(chunk) }
        }
        stream.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async { self.streamEnded(finished) }
        }

        buffer.removeAll()
        payload.removeAll()
        launchedAt = Date()
        do {
            try stream.run()
            process = stream
            AppLog.log("Media: Now Playing adapter started (pid \(stream.processIdentifier))")
        } catch {
            AppLog.log("Media: could not start the Now Playing adapter: \(error.localizedDescription)")
            onFailure?()
        }
    }

    private func streamEnded(_ finished: Process) {
        guard finished === process, !isStopping else { return }
        process = nil
        AppLog.log("Media: Now Playing adapter exited with status \(finished.terminationStatus)")

        // A stream that dies right after launch is broken, not just interrupted.
        quickFailures = Date().timeIntervalSince(launchedAt) < 5 ? quickFailures + 1 : 0
        if quickFailures >= 3 {
            onFailure?()
            return
        }
        let delay = min(30, pow(2, Double(quickFailures)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping, self.process == nil else { return }
            self.launch()
        }
    }

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              message["type"] as? String == "data",
              let update = message["payload"] as? [String: Any]
        else { return }

        // Full payloads replace the state; diffs only carry changed keys, with
        // null meaning "removed".
        if message["diff"] as? Bool == true {
            for (key, value) in update {
                if value is NSNull {
                    payload.removeValue(forKey: key)
                } else {
                    payload[key] = value
                }
            }
        } else {
            payload = update
        }

        if update.keys.contains("artworkData") || message["diff"] as? Bool != true {
            let decoded = (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
            if decoded != artworkData {
                artworkData = decoded
                artworkVersion += 1
            }
        }

        guard let title = payload["title"] as? String, !title.isEmpty else {
            onUpdate?(nil)
            return
        }
        onUpdate?(Info(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            isPlaying: payload["playing"] as? Bool ?? false,
            bundleID: payload["bundleIdentifier"] as? String,
            parentBundleID: payload["parentApplicationBundleIdentifier"] as? String,
            artworkData: artworkData,
            artworkVersion: artworkVersion,
            duration: Self.seconds(payload["durationMicros"]),
            elapsed: Self.seconds(payload["elapsedTimeMicros"]),
            timestamp: Self.seconds(payload["timestampEpochMicros"]).map { Date(timeIntervalSince1970: $0) },
            playbackRate: (payload["playbackRate"] as? NSNumber)?.doubleValue
        ))
    }

    /// Microseconds (a JSON number) to seconds; nil if absent or not finite.
    static func seconds(_ micros: Any?) -> TimeInterval? {
        guard let number = micros as? NSNumber else { return nil }
        let value = number.doubleValue / 1_000_000
        return value.isFinite && value >= 0 ? value : nil
    }
}

// MARK: - Scriptable players

enum ScriptablePlayer: CaseIterable, Equatable, Sendable {
    case spotify
    case music

    struct Snapshot: Sendable {
        let player: ScriptablePlayer
        let title: String
        let artist: String
        let isPlaying: Bool
        let artworkURL: URL?
        /// Seconds into the track when the snapshot was read.
        var position: TimeInterval? = nil
        /// Track length in seconds.
        var duration: TimeInterval? = nil
    }

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    var name: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        }
    }

    /// Wraps a `tell` body so it never relaunches a player the user just quit
    /// (`is running` doesn't launch) and can't block for AppleScript's default
    /// two-minute timeout on a hung player.
    fileprivate func script(_ body: String) -> String {
        """
        if application id "\(bundleID)" is running then
            with timeout of 3 seconds
                tell application id "\(bundleID)"
                    \(body)
                end tell
            end timeout
        else
            return "notrunning"
        end if
        """
    }

    fileprivate var snapshotScript: String {
        let artworkExpression = self == .spotify ? "(artwork url of t)" : "\"\""
        // Spotify reports the duration in milliseconds, Music in seconds.
        return script("""
            if player state is stopped then return "stopped"
            set t to current track
            set pos to ""
            set len to ""
            try
                set pos to (player position as text)
            end try
            try
                set len to (duration of t as text)
            end try
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & \(artworkExpression) & linefeed & pos & linefeed & len
            """)
    }

    /// Track length from the snapshot script's text, in seconds.
    func durationSeconds(fromScriptValue value: Double) -> TimeInterval {
        self == .spotify ? value / 1000 : value
    }

    fileprivate func seekScript(to seconds: TimeInterval) -> String {
        // AppleScript source always uses "." as the decimal separator.
        script("set player position to \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds))")
    }

    /// Parses an AppleScript number coerced to text, which follows the
    /// user's locale ("12,5" in many of them).
    static func number(fromScriptText text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    fileprivate func commandScript(_ command: MediaEngine.Command) -> String {
        switch command {
        case .togglePlayPause: script("playpause")
        case .nextTrack: script("next track")
        case .previousTrack: script("previous track")
        }
    }

    fileprivate static var musicArtworkScript: String {
        ScriptablePlayer.music.script("""
            if (count of artworks of current track) is 0 then return ""
            return raw data of artwork 1 of current track
            """)
    }
}

enum PlayerReading: Sendable {
    case track(ScriptablePlayer.Snapshot)
    case stopped(ScriptablePlayer)
    case needsPermission(ScriptablePlayer)
    case denied(ScriptablePlayer)
    case unavailable(ScriptablePlayer)
}

/// Sends Apple Events to Music and Spotify from one serial background queue.
///
/// A slow player, or the Automation consent prompt, therefore never blocks the
/// main thread. Each NSAppleScript instance is created and run only on this
/// queue, which keeps AppleScript's one-thread-per-instance rule.
private final class PlayerBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.PlayerBridge", qos: .userInitiated)
    // Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]
    private var reportedErrors: Set<String> = []

    func read(_ players: [ScriptablePlayer]) async -> [PlayerReading] {
        await perform { players.map(self.readNow) }
    }

    func send(_ command: MediaEngine.Command, to player: ScriptablePlayer) async {
        await perform { _ = self.execute(player.commandScript(command), for: player) }
    }

    /// Sets the player position. Never asks for Automation consent (only
    /// PermissionCenter asks); fails quietly if it isn't granted.
    func seek(_ player: ScriptablePlayer, to seconds: TimeInterval) async -> Bool {
        await perform {
            guard self.permission(for: player) == noErr else { return false }
            if case .success = self.execute(player.seekScript(to: seconds), for: player) { return true }
            return false
        }
    }

    func musicArtwork() async -> Data? {
        await perform {
            guard case .success(let result) = self.execute(ScriptablePlayer.musicArtworkScript, for: .music) else {
                return nil
            }
            let data = result.data
            return data.isEmpty ? nil : data
        }
    }

    // MARK: Queue-confined work

    private func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func readNow(_ player: ScriptablePlayer) -> PlayerReading {
        // Never trigger the consent prompt from a background poll.
        switch Int(permission(for: player)) {
        case Int(noErr):
            break
        case errAEEventWouldRequireUserConsent:
            return .needsPermission(player)
        case errAEEventNotPermitted:
            return .denied(player)
        default:
            return .unavailable(player)
        }

        switch execute(player.snapshotScript, for: player) {
        case .failure(let failure):
            return failure.code == errAEEventNotPermitted ? .denied(player) : .unavailable(player)
        case .success(let result):
            guard let output = result.stringValue else { return .unavailable(player) }
            let lines = output.components(separatedBy: "\n")
            guard lines.count >= 3 else {
                return output == "stopped" ? .stopped(player) : .unavailable(player)
            }
            return .track(ScriptablePlayer.Snapshot(
                player: player,
                title: lines[1],
                artist: lines[2],
                isPlaying: lines[0] == "playing",
                artworkURL: lines.count > 3 && !lines[3].isEmpty ? URL(string: lines[3]) : nil,
                position: lines.count > 4 ? ScriptablePlayer.number(fromScriptText: lines[4]) : nil,
                duration: lines.count > 5
                    ? ScriptablePlayer.number(fromScriptText: lines[5]).map(player.durationSeconds(fromScriptValue:))
                    : nil
            ))
        }
    }

    /// Status only (askUserIfNeeded = false): never shows the consent prompt.
    private func permission(for player: ScriptablePlayer) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        guard let address = target.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
    }

    private func execute(_ source: String, for player: ScriptablePlayer) -> Result<NSAppleEventDescriptor, ScriptFailure> {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return .failure(ScriptFailure(code: 0)) }
            compiled[source] = fresh
            script = fresh
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if reportedErrors.insert("\(player.bundleID)|\(code)").inserted {
                NSLog("SparkV: AppleScript error \(code) from \(player.name): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            return .failure(ScriptFailure(code: code))
        }
        return .success(result)
    }
}

private struct ScriptFailure: Error {
    let code: Int
}

/// Posts the same system-defined events as the keyboard's media keys.
private enum MediaKey {
    static func post(_ key: Int32) {
        post(key, keyDown: true)
        post(key, keyDown: false)
    }

    private static func post(_ key: Int32, keyDown: Bool) {
        let state: Int32 = keyDown ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: Int((key << 16) | (state << 8)),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
