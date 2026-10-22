import Darwin
import Foundation

/// Turns file-system events and published NSProgress updates for one folder
/// into download lifecycles: started → progress (bytes, speed, ETA) →
/// finished or cancelled.
///
/// Completion is matched by inode: Chromium renames `x.crdownload` to `x`,
/// Firefox renames `x.part` over its placeholder and Safari moves the data
/// file out of its `.download` package, so the file that appears keeps the
/// inode of the file that was growing. When that fails (a copy instead of a
/// move), a file with the expected final name that appeared after the
/// download started counts. Other files that grow in place (curl, other
/// apps) are tracked too and finish once their size stops changing.
///
/// Main-actor and synchronous: each event batch `lstat`s only the changed
/// entries, and `tick` (once a second, only while something is in flight)
/// samples the sizes of the in-flight files.
@MainActor
final class DownloadsTracker {
    struct Timing {
        /// A growing file with no partial suffix is done after this long unchanged.
        var stable: TimeInterval = 2.5
        /// A vanished partial with no finished file is cancelled after this.
        var cancelGrace: TimeInterval = 4
        /// No new bytes for this long shows "Paused".
        var paused: TimeInterval = 12
        /// A new zero-byte file is dropped after this long.
        var emptyGiveUp: TimeInterval = 15
        /// NSProgress values older than this are ignored for byte counts.
        var progressFresh: TimeInterval = 6
        /// Minimum spacing between speed samples.
        var rateSample: TimeInterval = 0.5
        /// Smoothing of the transfer rate (Chromium-style moving average).
        var rateSmoothing: Double = 0.3
        /// Paths the tracker finished stay ignored this long (browsers keep
        /// writing attributes to the finished file for a moment).
        var finishedQuiet: TimeInterval = 10
    }

    private struct Entry {
        var item: DownloadItem
        /// The partial download (`.crdownload`, `.part`, Safari package); nil for a generic file.
        var partialPath: String?
        /// The file whose size grows.
        var dataPath: String?
        var fileID: DownloadFileID?
        var firstSeen: Date
        var lastGrowthAt: Date
        var stableSince: Date
        var lastSize: Int64 = -1
        var rateBaseBytes: Int64 = -1
        var rateBaseAt: Date
        var missingSince: Date?
        var progressCompleted: Int64?
        var progressTotal: Int64?
        var progressAt: Date?
        var progressEnded = false
        var plistTotal: Int64?
        /// Generic files become visible only once they grow (or a browser
        /// publishes progress for them).
        var announced: Bool
        var isGeneric: Bool { partialPath == nil }
    }

    let folder: URL
    let rootPath: String
    var timing: Timing

    /// In-flight downloads changed (only announced ones, oldest first).
    var onActiveChanged: (([DownloadItem]) -> Void)?
    var onFinished: ((DownloadItem) -> Void)?
    var onCancelled: ((DownloadItem) -> Void)?
    /// True when the controller already lists a file at this path (moved back
    /// by Undo, seeded at start), so a create event for it isn't a new download.
    var isKnownPath: ((String) -> Bool)?
    /// Reads provenance for finished files (a seam for tests).
    var readMetadata: (URL) -> (whereFroms: [String], agent: String?) = { url in
        (DownloadMetadata.whereFroms(url), DownloadMetadata.quarantineAgent(url))
    }

    private var entries: [UUID: Entry] = [:]
    private var ignored: [String: Date] = [:]

    init(folder: URL, timing: Timing = Timing()) {
        let real = DownloadsPath.real(folder.path)
        self.folder = URL(fileURLWithPath: real, isDirectory: true)
        self.rootPath = real
        self.timing = timing
    }

    /// Something is being tracked, so `tick` should keep running.
    var needsTicks: Bool { !entries.isEmpty }

    var activeItems: [DownloadItem] {
        entries.values.filter(\.announced).map(\.item).sorted { $0.startedAt < $1.startedAt }
    }

    /// Ignore events for `path` for a while (SparkV's own moves and Undo).
    func ignore(path: String, for seconds: TimeInterval = 6, now: Date = Date()) {
        ignored[DownloadsPath.real(path)] = now.addingTimeInterval(seconds)
    }

    func reset() {
        entries.removeAll()
        ignored.removeAll()
        onActiveChanged?([])
    }

    // MARK: Input

    /// Picks up downloads already in progress when watching starts (names of
    /// the folder's entries). Finished files already there are not tracked.
    func prime(entryNames: [String], now: Date = Date()) {
        for name in entryNames where !DownloadPartials.isIgnoredName(name) && DownloadPartials.isPartialName(name) {
            let path = rootPath + "/" + name
            guard let stat = DownloadFileStat.of(path) else { continue }
            process(name: name, stat: stat, createdOrRenamed: false, now: now)
        }
        publishActive()
    }

    /// One FSEvents batch.
    func handle(events: [DownloadsFSEvent], now: Date = Date()) {
        var roots: [String: Bool] = [:]  // entry name → created/renamed seen at the top level
        var rescan = false
        for event in events {
            if event.mustRescan { rescan = true }
            guard let entry = rootEntry(for: event.path) else { continue }
            roots[entry.name] = (roots[entry.name] ?? false) || (entry.direct && event.isCreateOrRename)
        }
        if rescan {
            // Events were dropped: look at every partial again, and at the
            // tracked ones (a vanished partial is caught by the missing check).
            let names = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
            for name in names where DownloadPartials.isPartialName(name) && roots[name] == nil { roots[name] = false }
            for entry in entries.values {
                guard let partial = entry.partialPath else { continue }
                let name = (partial as NSString).lastPathComponent
                if roots[name] == nil { roots[name] = false }
            }
        }
        expireIgnored(now: now)

        var missing: [String] = []
        for (name, createdOrRenamed) in roots.sorted(by: { $0.key < $1.key }) {
            guard !DownloadPartials.isIgnoredName(name) else { continue }
            if let stat = DownloadFileStat.of(rootPath + "/" + name) {
                process(name: name, stat: stat, createdOrRenamed: createdOrRenamed, now: now)
            } else {
                missing.append(name)
            }
        }
        for name in missing { processMissing(name: name, now: now) }
        resolveMissing(now: now, allowCancel: false)
        publishActive()
    }

    /// A progress update a browser published for a file in the folder.
    func handle(progress update: DownloadsProgressSubscriber.Update, now: Date = Date()) {
        let path = DownloadsPath.real(update.path)
        var id = entryID { $0.partialPath == path || $0.dataPath == path || (self.rootPath + "/" + $0.item.name) == path }
        if id == nil, !update.ended, (path as NSString).deletingLastPathComponent == rootPath,
           let stat = DownloadFileStat.of(path), ignored[path] == nil {
            let name = (path as NSString).lastPathComponent
            process(name: name, stat: stat, createdOrRenamed: true, now: now)
            id = entryID { $0.partialPath == path || $0.dataPath == path }
        }
        guard let id, var entry = entries[id] else { return }
        if update.total > 0 { entry.progressTotal = update.total }
        if update.completed >= 0 { entry.progressCompleted = update.completed }
        entry.progressAt = now
        if entry.item.sourceURL == nil, let source = update.sourceURL { entry.item.sourceURL = source }
        if update.ended { entry.progressEnded = true }
        entry.announced = true
        entries[id] = entry
        sample(id, now: now)
        if update.ended { resolveMissing(now: now, allowCancel: false) }
        publishActive()
    }

    /// Samples sizes, updates speed/ETA, finishes stable generic files and
    /// cancels partials that vanished without a finished file.
    func tick(now: Date = Date()) {
        expireIgnored(now: now)
        for id in Array(entries.keys) {
            guard let entry = entries[id] else { continue }
            if entry.missingSince != nil { continue }
            if let partial = entry.partialPath, DownloadFileStat.of(partial) == nil {
                entries[id]?.missingSince = now
                continue
            }
            if entry.item.browser == .safari, entry.dataPath == nil || entry.fileID == nil, let partial = entry.partialPath {
                refreshSafari(id, bundle: partial)
            }
            sample(id, now: now)
            guard let current = entries[id], current.isGeneric else { continue }
            if current.lastSize <= 0 {
                if now.timeIntervalSince(current.firstSeen) > timing.emptyGiveUp { drop(id) }
            } else if now.timeIntervalSince(current.stableSince) >= timing.stable, let path = current.dataPath {
                if current.announced || hasProvenance(URL(fileURLWithPath: path)) {
                    finish(id, at: path, now: now)
                } else {
                    entries[id] = nil  // a local file that was copied in, not a download
                }
            }
        }
        resolveMissing(now: now, allowCancel: true)
        publishActive()
    }

    // MARK: Processing

    /// The top-level entry an event path belongs to; `direct` is false for
    /// changes inside a Safari package (they count as package changes).
    private func rootEntry(for path: String) -> (name: String, direct: Bool)? {
        let real = path.hasPrefix(rootPath + "/") ? path : DownloadsPath.real(path)
        guard real.hasPrefix(rootPath + "/") else { return nil }
        let relative = real.dropFirst(rootPath.count + 1)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        if parts.count == 1 { return (String(first), true) }
        if parts.count == 2, first.lowercased().hasSuffix(".download") { return (String(first), false) }
        return nil
    }

    private func entryID(where predicate: (Entry) -> Bool) -> UUID? {
        entries.first { predicate($0.value) }?.key
    }

    private func process(name: String, stat: DownloadFileStat, createdOrRenamed: Bool, now: Date) {
        let path = rootPath + "/" + name
        if let until = ignored[path], until > now { return }
        let url = URL(fileURLWithPath: path, isDirectory: stat.isDirectory)

        if let partial = DownloadPartials.inspect(url, stat: stat) {
            if let id = entryID(where: { $0.partialPath == path }) {
                entries[id]?.missingSince = nil
                if partial.browser == .safari {
                    refreshSafari(id, bundle: path)
                }
                sample(id, now: now)
            } else {
                startPartial(partial, now: now)
            }
            return
        }
        guard stat.isRegularFile else { return }

        // A finished download: the growing file reappeared under its final name.
        if let id = entryID(where: { $0.fileID == stat.id && $0.partialPath != nil && $0.partialPath != path && $0.dataPath != path }) {
            finish(id, at: path, now: now)
            return
        }
        if DownloadPartials.isFirefoxPlaceholder(url, stat: stat) { return }
        if let id = entryID(where: { $0.isGeneric && $0.dataPath == path }) {
            sample(id, now: now)
            return
        }
        if let id = entryID(where: { $0.missingSince != nil && $0.item.name == name }) {
            finish(id, at: path, now: now)
            return
        }
        guard createdOrRenamed, !(isKnownPath?(path) ?? false) else { return }
        let item = DownloadItem(name: name, url: url, phase: .downloading, browser: .other,
                                bytesReceived: stat.size, startedAt: now)
        entries[item.id] = Entry(item: item, partialPath: nil, dataPath: path, fileID: stat.id, firstSeen: now,
                                 lastGrowthAt: now, stableSince: now, lastSize: stat.size,
                                 rateBaseBytes: stat.size, rateBaseAt: now, announced: false)
    }

    private func startPartial(_ partial: DownloadPartialInfo, now: Date) {
        let dataStat = partial.dataURL.flatMap { DownloadFileStat.of($0.path) }
        var item = DownloadItem(name: partial.finalName, url: partial.partialURL, phase: .downloading,
                                browser: partial.browser, bytesReceived: dataStat?.size ?? 0,
                                totalBytes: partial.plistTotal, startedAt: now, sourceURL: partial.plistSourceURL)
        if let received = partial.plistReceived { item.bytesReceived = max(item.bytesReceived, received) }
        // Firefox's placeholder (or an older copy) at the final path isn't a separate download.
        let finalPath = rootPath + "/" + partial.finalName
        if let generic = entryID(where: { $0.isGeneric && $0.dataPath == finalPath }) { entries[generic] = nil }
        entries[item.id] = Entry(item: item, partialPath: partial.partialURL.path, dataPath: partial.dataURL?.path,
                                 fileID: dataStat?.id, firstSeen: now, lastGrowthAt: now, stableSince: now,
                                 lastSize: dataStat?.size ?? -1, rateBaseBytes: item.bytesReceived, rateBaseAt: now,
                                 plistTotal: partial.plistTotal, announced: true)
    }

    private func refreshSafari(_ id: UUID, bundle: String) {
        guard var entry = entries[id] else { return }
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let dataExists = entry.dataPath.map { DownloadFileStat.of($0) != nil } ?? false
        if !dataExists, let data = DownloadPartials.safariDataFile(in: bundleURL, finalName: entry.item.name) {
            entry.dataPath = data.path
        }
        if let data = entry.dataPath, let stat = DownloadFileStat.of(data) { entry.fileID = stat.id }
        if let plist = DownloadPartials.safariInfo(bundle: bundleURL) {
            if let total = plist.total { entry.plistTotal = total }
            if entry.item.sourceURL == nil { entry.item.sourceURL = plist.sourceURL }
        }
        entries[id] = entry
    }

    private func processMissing(name: String, now: Date) {
        let path = rootPath + "/" + name
        if let id = entryID(where: { $0.partialPath == path }) {
            if entries[id]?.missingSince == nil { entries[id]?.missingSince = now }
        } else if let id = entryID(where: { $0.isGeneric && $0.dataPath == path }) {
            drop(id)
        }
    }

    /// Vanished partials: finish at the final name when it's there, cancel
    /// after the grace period otherwise.
    private func resolveMissing(now: Date, allowCancel: Bool) {
        for (id, entry) in entries {
            let ended = entry.progressEnded && (entry.progressTotal ?? 0) > 0 && (entry.progressCompleted ?? -1) >= (entry.progressTotal ?? 0)
            guard entry.missingSince != nil || ended else { continue }
            let candidate = rootPath + "/" + entry.item.name
            if candidate != entry.dataPath, let stat = DownloadFileStat.of(candidate), stat.isRegularFile, stat.size > 0 {
                let sameFile = stat.id == entry.fileID
                let appearedSinceStart = stat.modified >= entry.firstSeen.addingTimeInterval(-2)
                if sameFile || (entry.missingSince != nil && appearedSinceStart) {
                    finish(id, at: candidate, now: now)
                    continue
                }
            }
            if allowCancel, let since = entry.missingSince, now.timeIntervalSince(since) >= timing.cancelGrace {
                let item = entries.removeValue(forKey: id)?.item
                if var item, entry.announced {
                    item.phase = .cancelled
                    onCancelled?(item)
                }
            }
        }
    }

    private func sample(_ id: UUID, now: Date) {
        guard var entry = entries[id] else { return }
        let size = entry.dataPath.flatMap { DownloadFileStat.of($0)?.size }
        if let size {
            if size != entry.lastSize {
                if entry.isGeneric, entry.lastSize >= 0, size > entry.lastSize, !entry.announced {
                    entry.announced = true
                }
                if size > entry.lastSize { entry.lastGrowthAt = now }
                entry.stableSince = now
                entry.lastSize = size
            }
        }
        let progressFresh = entry.progressAt.map { now.timeIntervalSince($0) <= timing.progressFresh } ?? false
        var received = max(size ?? 0, 0)
        if progressFresh, let completed = entry.progressCompleted { received = max(received, completed) }
        if received > entry.item.bytesReceived { entry.lastGrowthAt = now }
        entry.item.bytesReceived = max(received, entry.item.bytesReceived)

        if progressFresh, let total = entry.progressTotal, total > 0 {
            entry.item.totalBytes = total
        } else if let total = entry.plistTotal {
            entry.item.totalBytes = total
        }

        let elapsed = now.timeIntervalSince(entry.rateBaseAt)
        if entry.rateBaseBytes < 0 {
            entry.rateBaseBytes = entry.item.bytesReceived
            entry.rateBaseAt = now
        } else if elapsed >= timing.rateSample {
            let delta = Double(entry.item.bytesReceived - entry.rateBaseBytes)
            if delta > 0 {
                let rate = delta / elapsed
                let a = timing.rateSmoothing
                entry.item.bytesPerSecond = entry.item.bytesPerSecond <= 0 ? rate : a * rate + (1 - a) * entry.item.bytesPerSecond
            } else if now.timeIntervalSince(entry.lastGrowthAt) > 3 {
                entry.item.bytesPerSecond *= 0.5
                if entry.item.bytesPerSecond < 1 { entry.item.bytesPerSecond = 0 }
            }
            entry.rateBaseBytes = entry.item.bytesReceived
            entry.rateBaseAt = now
        }
        if !entry.isGeneric {
            entry.item.phase = now.timeIntervalSince(entry.lastGrowthAt) > timing.paused ? .paused : .downloading
        }
        entries[id] = entry
    }

    private func finish(_ id: UUID, at path: String, now: Date) {
        guard var entry = entries.removeValue(forKey: id) else { return }
        // Any generic candidate for the same file is the same download.
        for (other, value) in entries where value.isGeneric && value.dataPath == path { entries[other] = nil }
        let url = URL(fileURLWithPath: path)
        let size = DownloadFileStat.of(path)?.size ?? entry.item.bytesReceived
        entry.item.url = url
        entry.item.name = url.lastPathComponent
        entry.item.phase = .finished
        entry.item.bytesReceived = size
        entry.item.totalBytes = size
        entry.item.finishedAt = now
        let meta = readMetadata(url)
        if let first = meta.whereFroms.first { entry.item.sourceURL = first }
        if meta.whereFroms.count > 1 { entry.item.referrerURL = meta.whereFroms[1] }
        entry.item.agentName = meta.agent
        ignored[path] = now.addingTimeInterval(timing.finishedQuiet)
        onFinished?(entry.item)
    }

    private func drop(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if entry.announced {
            var item = entry.item
            item.phase = .cancelled
            onCancelled?(item)
        }
    }

    private func hasProvenance(_ url: URL) -> Bool {
        let meta = readMetadata(url)
        return !meta.whereFroms.isEmpty || meta.agent != nil
    }

    private func expireIgnored(now: Date) {
        ignored = ignored.filter { $0.value > now }
    }

    private var lastPublished: [DownloadItem] = []

    private func publishActive() {
        let active = activeItems
        guard active != lastPublished else { return }
        lastPublished = active
        onActiveChanged?(active)
    }
}

enum DownloadsPath {
    /// realpath(3) of the parent folder plus the last component, so
    /// `/tmp/x` and `/private/tmp/x` compare equal even when `x` is gone.
    /// (URL.resolvingSymlinksInPath strips `/private`, the opposite of what
    /// FSEvents reports.)
    static func real(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if let full = realpath(standardized) { return full }
        let parent = (standardized as NSString).deletingLastPathComponent
        let name = (standardized as NSString).lastPathComponent
        guard let resolvedParent = realpath(parent) else { return standardized }
        return (resolvedParent as NSString).appendingPathComponent(name)
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
