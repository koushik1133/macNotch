import CoreServices
import Foundation

/// One FSEvents record: a changed path and its kFSEventStreamEventFlag bits.
struct DownloadsFSEvent: Sendable, Equatable {
    let path: String
    let flags: UInt32

    /// Created in, or renamed/moved into (or out of), the folder.
    var isCreateOrRename: Bool {
        flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
    }

    /// The changed item is a folder.
    var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }

    /// Events were dropped; the folder must be rescanned.
    var mustRescan: Bool {
        flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
    }
}

/// FSEvents stream on one folder with file-level events, coalesced by the
/// kernel (`latency`) and delivered on a private serial queue. The handler
/// gets the changed paths; the tracker `lstat`s only those, so a big
/// Downloads folder costs nothing while nothing changes.
final class DownloadsFolderStream: @unchecked Sendable {
    typealias Handler = @Sendable ([DownloadsFSEvent]) -> Void

    private let path: String
    private let latency: CFTimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "SparkV.Downloads.FSEvents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(path: String, latency: CFTimeInterval = 0.3, handler: @escaping Handler) {
        self.path = path
        self.latency = latency
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit { stop() }

    /// False when the stream can't be created (bad path).
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<DownloadsFolderStream>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(rawPaths, to: NSArray.self)
            var events: [DownloadsFSEvent] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, array.count) {
                guard let path = array[index] as? String else { continue }
                events.append(DownloadsFSEvent(path: path, flags: flags[index]))
            }
            if !events.isEmpty { me.handler(events) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // A callback may already be running on the queue with an unretained
        // pointer to self: wait for it before the stream (and self) go away.
        // Skipped when stop() runs on the queue itself (deinit from a callback).
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil { queue.sync {} }
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let queueKey = DispatchSpecificKey<Bool>()
}

/// Listens for NSProgress objects that browsers publish for files in a
/// folder (the mechanism Finder and the Dock use to draw download progress;
/// Chromium's `download_status_updater_mac.mm` publishes one per download
/// with NSProgressFileURLKey and the downloading kind). Gives exact
/// received/total bytes and the source URL when the browser provides them.
///
/// The progress objects it receives are live proxies of the browser's own:
/// `cancel()`, `pause()` and `resume()` on them reach the browser, exactly
/// like the ✕ on a downloading file's icon in Finder. Which of those a
/// browser supports it says itself (`isCancellable`, `isPausable`).
@MainActor
final class DownloadsProgressSubscriber {
    struct Update: Sendable, Equatable {
        let path: String
        let completed: Int64
        let total: Int64
        let sourceURL: String?
        /// The publisher unpublished (finished, cancelled or quit).
        let ended: Bool
        var cancellable = false
        var pausable = false
        var paused = false
    }

    /// What the browser lets SparkV do with one download.
    struct Controls: Equatable, Sendable {
        var canCancel: Bool
        var canPause: Bool
        var isPaused: Bool

        static let none = Controls(canCancel: false, canPause: false, isPaused: false)
    }

    private let folder: URL
    private let onUpdate: (Update) -> Void
    private var subscriber: Any?
    /// KVO tokens per published progress proxy.
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var lastSent: [ObjectIdentifier: Date] = [:]
    /// Published progress proxies, for the final snapshot on unpublish and
    /// for Cancel / Pause / Resume.
    private var proxies: [ObjectIdentifier: Progress] = [:]
    /// The file each proxy is about (standardized path).
    private var paths: [ObjectIdentifier: String] = [:]

    /// Updates more frequent than this are dropped (the last one is always sent).
    static let minInterval: TimeInterval = 0.25

    init(folder: URL, onUpdate: @escaping (Update) -> Void) {
        self.folder = folder
        self.onUpdate = onUpdate
    }

    func start() {
        guard subscriber == nil else { return }
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            // Documented to run on the main thread.
            let key = ObjectIdentifier(progress)
            MainActor.assumeIsolated { self?.published(progress) }
            return { [weak self] in
                MainActor.assumeIsolated { self?.unpublished(key) }
            }
        }
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        observations.removeAll()
        lastSent.removeAll()
        proxies.removeAll()
        paths.removeAll()
    }

    // MARK: Controls

    private func proxy(matching candidates: Set<String>) -> Progress? {
        guard let key = paths.first(where: { candidates.contains($0.value) })?.key else { return nil }
        return proxies[key]
    }

    /// The browser's own Cancel / Pause support for a download, by any of
    /// its paths (the partial file or the final name).
    func controls(matching candidates: Set<String>) -> Controls {
        guard let progress = proxy(matching: candidates) else { return .none }
        return Controls(canCancel: progress.isCancellable, canPause: progress.isPausable, isPaused: progress.isPaused)
    }

    /// Cancels in the browser. False when it doesn't allow that.
    @discardableResult
    func cancel(matching candidates: Set<String>) -> Bool {
        guard let progress = proxy(matching: candidates), progress.isCancellable else { return false }
        progress.cancel()
        return true
    }

    /// Pauses or resumes in the browser. False when it doesn't allow that.
    @discardableResult
    func togglePause(matching candidates: Set<String>) -> Bool {
        guard let progress = proxy(matching: candidates), progress.isPausable else { return false }
        if progress.isPaused { progress.resume() } else { progress.pause() }
        return true
    }

    private func published(_ progress: Progress) {
        // A subscriber's proxy has the kind only in its userInfo. Finder
        // copies into Downloads are the copy monitor's, not downloads.
        if let kind = ShelfTransfersMonitor.operation(of: progress), kind != .downloading, kind != .receiving { return }
        let key = ObjectIdentifier(progress)
        proxies[key] = progress
        if let url = progress.fileURL ?? (progress.userInfo[.fileURLKey] as? URL) {
            paths[key] = DownloadsPath.real(url.standardizedFileURL.path)
        }
        let handler: @Sendable (Progress, NSKeyValueObservedChange<Int64>) -> Void = { [weak self] progress, _ in
            let update = Self.snapshot(progress, ended: false)
            let id = ObjectIdentifier(progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(update, key: id, force: false) }
            }
        }
        // Pause / resume (from SparkV, Finder or the browser) shows at once.
        let flags: @Sendable (Progress, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] progress, _ in
            let update = Self.snapshot(progress, ended: false)
            let id = ObjectIdentifier(progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(update, key: id, force: true) }
            }
        }
        observations[key] = [
            progress.observe(\.completedUnitCount, options: [], changeHandler: handler),
            progress.observe(\.totalUnitCount, options: [], changeHandler: handler),
            progress.observe(\.isPaused, options: [], changeHandler: flags),
        ]
        deliver(Self.snapshot(progress, ended: false), key: key, force: true)
    }

    private func unpublished(_ key: ObjectIdentifier) {
        observations[key] = nil
        lastSent[key] = nil
        paths[key] = nil
        guard let progress = proxies.removeValue(forKey: key) else { return }
        deliver(Self.snapshot(progress, ended: true), key: key, force: true)
    }

    private func deliver(_ update: Update?, key: ObjectIdentifier, force: Bool) {
        guard let update else { return }
        let now = Date()
        if !force, let last = lastSent[key], now.timeIntervalSince(last) < Self.minInterval,
           update.total <= 0 || update.completed < update.total { return }
        lastSent[key] = now
        onUpdate(update)
    }

    nonisolated private static func snapshot(_ progress: Progress, ended: Bool) -> Update? {
        let url = progress.fileURL ?? (progress.userInfo[.fileURLKey] as? URL)
        guard let url else { return nil }
        let source = progress.userInfo[ProgressUserInfoKey("NSProgressFileDownloadingSourceURLKey")]
        let sourceText = (source as? URL)?.absoluteString ?? (source as? String)
        return Update(path: url.standardizedFileURL.path, completed: progress.completedUnitCount,
                      total: progress.totalUnitCount, sourceURL: sourceText, ended: ended,
                      cancellable: progress.isCancellable, pausable: progress.isPausable, paused: progress.isPaused)
    }
}
