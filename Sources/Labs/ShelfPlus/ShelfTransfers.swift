import AppKit
import Combine
import SwiftUI

/// One copy or send in flight (or just finished). Finder reports moves
/// between disks as copies.
struct ShelfTransfer: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case copying, duplicating, decompressing, uploading, localSend

        var verb: String {
            switch self {
            case .copying: "Copying"
            case .duplicating: "Duplicating"
            case .decompressing: "Expanding"
            case .uploading: "Uploading"
            case .localSend: "Sending"
            }
        }

        var pastTense: String {
            switch self {
            case .copying: "Copied"
            case .duplicating: "Duplicated"
            case .decompressing: "Expanded"
            case .uploading: "Uploaded"
            case .localSend: "Sent"
            }
        }

        var symbol: String {
            switch self {
            case .copying, .duplicating: "doc.on.doc.fill"
            case .decompressing: "archivebox.fill"
            case .uploading: "icloud.and.arrow.up.fill"
            case .localSend: "wave.3.right"
            }
        }

        /// The NSProgress file operation this kind stands for (nil: SparkV's own).
        init?(operation: Progress.FileOperationKind) {
            switch operation {
            case .copying: self = .copying
            case .duplicating: self = .duplicating
            case .decompressingAfterDownloading: self = .decompressing
            case .uploading: self = .uploading
            default:
                // Downloads and AirDrop receives belong to the download watcher.
                return nil
            }
        }
    }

    enum Phase: String, Sendable {
        case running, paused, finished, cancelled, failed
    }

    let id: UUID
    var kind: Kind
    /// The item's name ("Holiday.mov", "3 files").
    var name: String
    /// Where it's going ("Backup", "Pixel 8").
    var destination: String
    /// The file or folder it lands in, for Reveal (nil for sends).
    var url: URL?
    var completed: Int64
    var total: Int64
    var bytesPerSecond: Double
    var startedAt: Date
    var finishedAt: Date?
    var phase: Phase
    var canCancel: Bool
    var canPause: Bool
    var message: String?

    var isActive: Bool { phase == .running || phase == .paused }

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var etaSeconds: Double? {
        guard total > 0, bytesPerSecond > 1, phase == .running else { return nil }
        return Double(max(0, total - completed)) / bytesPerSecond
    }

    /// "Copying to Backup", "Sent to Pixel 8".
    var title: String {
        switch phase {
        case .finished: "\(kind.pastTense) to \(destination)"
        case .cancelled: "Cancelled"
        case .failed: message ?? "Didn't finish"
        case .running, .paused: "\(kind.verb) to \(destination)"
        }
    }

    /// "42% · 31 MB/s · 12 s left".
    var progressLine: String {
        if phase == .paused { return ["Paused", fraction.map(DownloadFormat.percent)].compactMap { $0 }.joined(separator: " · ") }
        var parts: [String] = []
        if let fraction { parts.append(DownloadFormat.percent(fraction)) } else if completed > 0 { parts.append(DownloadFormat.bytes(completed)) }
        if bytesPerSecond >= 1, phase == .running { parts.append(DownloadFormat.speed(bytesPerSecond)) }
        if let eta = etaSeconds { parts.append(DownloadFormat.eta(eta)) }
        if parts.isEmpty, phase == .running { parts.append(message ?? "Starting…") }
        return parts.joined(separator: " · ")
    }
}

/// Smoothed transfer rate from (time, bytes) samples, fed by progress
/// notifications (no timer).
struct ShelfRateMeter: Equatable, Sendable {
    private(set) var lastTime: TimeInterval?
    private(set) var lastBytes: Int64 = 0
    private(set) var rate: Double = 0

    mutating func add(bytes: Int64, at time: TimeInterval) {
        defer { lastTime = time; lastBytes = bytes }
        guard let lastTime, time > lastTime, bytes >= lastBytes else { return }
        let instant = Double(bytes - lastBytes) / (time - lastTime)
        // Exponential smoothing; the first real sample sets the rate.
        rate = rate == 0 ? instant : rate * 0.7 + instant * 0.3
    }
}

/// Live progress for Finder copies and moves (and SparkV's own LocalSend
/// sends) under the notch, with Pause, Cancel and Reveal.
///
/// Finder, like every app using NSFileManager / NSFileCoordinator copies,
/// publishes an NSProgress per item it writes, keyed by the destination
/// file. `Progress.addSubscriber(forFileURL:)` on a folder delivers those
/// for items landing directly in it, with live counts and working
/// cancel / pause handlers: the mechanism Finder and the Dock use for
/// their own progress bars. SparkV subscribes to the folders the user
/// picked and to the top level of every external drive, re-subscribing as
/// drives come and go. No folder is listed or read and nothing polls:
/// updates arrive by key-value observation.
@MainActor
final class ShelfTransfersMonitor: ObservableObject {
    static let shared = ShelfTransfersMonitor()

    /// Newest first; in-flight ones on top.
    @Published private(set) var transfers: [ShelfTransfer] = []

    /// Tab the bands open when hovered (the integrator sets `.downloads`).
    var opensTab: NotchState.Tab?
    private weak var activities: ActivityCenter?

    static let progressActivityID = "transfers.progress"
    static let doneActivityID = "transfers.done"
    static let maxFinished = 6
    /// Updates more frequent than this are coalesced.
    static let minInterval: TimeInterval = 0.25

    private let settings: ShelfSettings
    private var subscribers: [String: Any] = [:]
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var proxies: [ObjectIdentifier: Progress] = [:]
    private var transferIDs: [ObjectIdentifier: UUID] = [:]
    private var meters: [UUID: ShelfRateMeter] = [:]
    private var lastDelivered: [UUID: Date] = [:]
    /// Cancel / pause for SparkV's own transfers (LocalSend).
    private var ownControls: [UUID: (cancel: () -> Void, pause: (() -> Void)?, resume: (() -> Void)?)] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var settingsObservers: Set<AnyCancellable> = []
    private var progressPosted = false
    private var isRunning = false

    init(settings: ShelfSettings? = nil) {
        self.settings = settings ?? .shared
    }

    /// Wiring from the window controller.
    func connect(activities: ActivityCenter, opensTab: NotchState.Tab?) {
        self.activities = activities
        self.opensTab = opensTab
    }

    /// Follows the setting: subscribes while copy progress is on.
    func start() {
        guard settingsObservers.isEmpty else { return }
        settings.$transfersEnabled.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resubscribe() } }
        }.store(in: &settingsObservers)
        settings.$transferFolders.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resubscribe() } }
        }.store(in: &settingsObservers)
        settings.$transferVolumes.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resubscribe() } }
        }.store(in: &settingsObservers)
    }

    func stop() {
        settingsObservers.removeAll()
        unsubscribeAll()
        dismissBands()
    }

    // MARK: Subscriptions

    /// The folders watched right now (picked folders, then external drives).
    func watchedFolders() -> [URL] {
        var folders = settings.transferFolderURLs()
        if settings.transferVolumes {
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRootFileSystemKey],
                                                               options: [.skipHiddenVolumes]) ?? []
            folders += volumes.filter { url in
                let isRoot = (try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem ?? false
                return !isRoot && url.path != "/"
            }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func resubscribe() {
        guard settings.transfersEnabled else {
            unsubscribeAll()
            return
        }
        isRunning = true
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resubscribe() }
                })
            }
        }
        let wanted = watchedFolders()
        let wantedPaths = Set(wanted.map { $0.standardizedFileURL.path })
        for (path, subscriber) in subscribers where !wantedPaths.contains(path) {
            Progress.removeSubscriber(subscriber)
            subscribers[path] = nil
        }
        for folder in wanted {
            let path = folder.standardizedFileURL.path
            guard subscribers[path] == nil else { continue }
            let destination = Self.destinationName(folder)
            subscribers[path] = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
                // Documented to run on the main thread.
                let key = ObjectIdentifier(progress)
                MainActor.assumeIsolated { self?.published(progress, destination: destination, folder: folder) }
                return { [weak self] in
                    MainActor.assumeIsolated { self?.unpublished(key) }
                }
            }
        }
        AppLog.log("Transfers: watching \(subscribers.count) folder(s) for copy progress")
    }

    private func unsubscribeAll() {
        subscribers.values.forEach(Progress.removeSubscriber)
        subscribers.removeAll()
        observations.removeAll()
        proxies.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        isRunning = false
        // In-flight Finder copies we can no longer see: drop them.
        let finderIDs = Set(transferIDs.values)
        transferIDs.removeAll()
        transfers.removeAll { finderIDs.contains($0.id) && $0.isActive }
        updateBand()
    }

    /// A subscriber's proxy carries the kind only in its userInfo (its
    /// `fileOperationKind` property reads nil).
    nonisolated static func operation(of progress: Progress) -> Progress.FileOperationKind? {
        if let kind = progress.fileOperationKind { return kind }
        let raw = progress.userInfo[.fileOperationKindKey]
        if let kind = raw as? Progress.FileOperationKind { return kind }
        return (raw as? String).map(Progress.FileOperationKind.init(rawValue:))
    }

    static func destinationName(_ folder: URL) -> String {
        let name = FileManager.default.displayName(atPath: folder.path)
        return name.isEmpty ? folder.lastPathComponent : name
    }

    private func published(_ progress: Progress, destination: String, folder: URL) {
        guard let operation = Self.operation(of: progress), let kind = ShelfTransfer.Kind(operation: operation) else { return }
        let key = ObjectIdentifier(progress)
        let id = UUID()
        proxies[key] = progress
        transferIDs[key] = id
        let url = progress.fileURL ?? (progress.userInfo[.fileURLKey] as? URL)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? "Items"
        let transfer = ShelfTransfer(id: id, kind: kind, name: name.isEmpty ? (url?.lastPathComponent ?? "Item") : name,
                                     destination: destination, url: url, completed: max(0, progress.completedUnitCount),
                                     total: max(0, progress.totalUnitCount), bytesPerSecond: 0, startedAt: Date(),
                                     finishedAt: nil, phase: progress.isPaused ? .paused : .running,
                                     canCancel: progress.isCancellable, canPause: progress.isPausable, message: nil)
        transfers.insert(transfer, at: 0)
        let handler: @Sendable (Progress, NSKeyValueObservedChange<Int64>) -> Void = { [weak self] progress, _ in
            let snapshot = (completed: progress.completedUnitCount, total: progress.totalUnitCount,
                            paused: progress.isPaused, cancellable: progress.isCancellable, pausable: progress.isPausable)
            let key = ObjectIdentifier(progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.update(key: key, completed: snapshot.completed, total: snapshot.total, paused: snapshot.paused,
                                 cancellable: snapshot.cancellable, pausable: snapshot.pausable, force: false)
                }
            }
        }
        let flags: @Sendable (Progress, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] progress, _ in
            let snapshot = (completed: progress.completedUnitCount, total: progress.totalUnitCount,
                            paused: progress.isPaused, cancellable: progress.isCancellable, pausable: progress.isPausable)
            let key = ObjectIdentifier(progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.update(key: key, completed: snapshot.completed, total: snapshot.total, paused: snapshot.paused,
                                 cancellable: snapshot.cancellable, pausable: snapshot.pausable, force: true)
                }
            }
        }
        observations[key] = [
            progress.observe(\.completedUnitCount, options: [], changeHandler: handler),
            progress.observe(\.totalUnitCount, options: [], changeHandler: handler),
            progress.observe(\.isPaused, options: [], changeHandler: flags),
        ]
        meters[id] = ShelfRateMeter()
        AppLog.log("Transfers: \(kind.rawValue) into \(destination) started")
        trimFinished()
        updateBand()
    }

    private func update(key: ObjectIdentifier, completed: Int64, total: Int64, paused: Bool, cancellable: Bool, pausable: Bool, force: Bool) {
        guard let id = transferIDs[key] else { return }
        update(id: id, force: force) { transfer in
            transfer.completed = max(0, completed)
            transfer.total = max(0, total)
            transfer.phase = paused ? .paused : .running
            transfer.canCancel = cancellable
            transfer.canPause = pausable
        }
    }

    private func unpublished(_ key: ObjectIdentifier) {
        observations[key] = nil
        let progress = proxies.removeValue(forKey: key)
        guard let id = transferIDs.removeValue(forKey: key) else { return }
        let cancelled = progress?.isCancelled ?? false
        let done = progress.map { $0.totalUnitCount > 0 && $0.completedUnitCount >= $0.totalUnitCount } ?? false
        finish(id: id, phase: done && !cancelled ? .finished : (cancelled ? .cancelled : (progress?.fractionCompleted ?? 0) >= 0.999 ? .finished : .cancelled))
    }

    // MARK: SparkV's own transfers

    /// Adds a transfer SparkV runs itself (LocalSend). Returns its id.
    @discardableResult
    func begin(kind: ShelfTransfer.Kind, name: String, destination: String, total: Int64,
               cancel: @escaping () -> Void) -> UUID {
        let id = UUID()
        transfers.insert(ShelfTransfer(id: id, kind: kind, name: name, destination: destination, url: nil, completed: 0,
                                       total: total, bytesPerSecond: 0, startedAt: Date(), finishedAt: nil, phase: .running,
                                       canCancel: true, canPause: false, message: nil), at: 0)
        ownControls[id] = (cancel, nil, nil)
        meters[id] = ShelfRateMeter()
        trimFinished()
        updateBand()
        return id
    }

    func progress(id: UUID, completed: Int64, message: String? = nil) {
        update(id: id, force: message != nil) { transfer in
            transfer.completed = completed
            if let message { transfer.message = message }
        }
    }

    func setMessage(id: UUID, _ message: String?) {
        update(id: id, force: true) { $0.message = message }
    }

    func finish(id: UUID, phase: ShelfTransfer.Phase, message: String? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].phase = phase
        transfers[index].finishedAt = Date()
        transfers[index].canCancel = false
        transfers[index].canPause = false
        transfers[index].bytesPerSecond = 0
        if let message { transfers[index].message = message }
        if phase == .finished, transfers[index].total > 0 { transfers[index].completed = transfers[index].total }
        ownControls[id] = nil
        meters[id] = nil
        lastDelivered[id] = nil
        let transfer = transfers[index]
        AppLog.log("Transfers: \(transfer.kind.rawValue) \(phase.rawValue)")
        updateBand()
        if phase == .finished { postDone(transfer) }
        trimFinished()
    }

    // MARK: Controls

    func cancel(_ id: UUID) {
        if let own = ownControls[id] { return own.cancel() }
        guard let key = transferIDs.first(where: { $0.value == id })?.key, let progress = proxies[key], progress.isCancellable else { return }
        progress.cancel()
        AppLog.log("Transfers: cancelled a copy")
    }

    func togglePause(_ id: UUID) {
        guard let key = transferIDs.first(where: { $0.value == id })?.key, let progress = proxies[key], progress.isPausable else { return }
        if progress.isPaused { progress.resume() } else { progress.pause() }
    }

    func reveal(_ id: UUID) {
        guard let url = transfers.first(where: { $0.id == id })?.url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func forget(_ id: UUID) {
        transfers.removeAll { $0.id == id && !$0.isActive }
    }

    func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    var activeTransfers: [ShelfTransfer] { transfers.filter(\.isActive) }

    // MARK: Internals

    private func update(id: UUID, force: Bool, _ change: (inout ShelfTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        var transfer = transfers[index]
        change(&transfer)
        let now = Date()
        meters[id]?.add(bytes: transfer.completed, at: now.timeIntervalSinceReferenceDate)
        transfer.bytesPerSecond = meters[id]?.rate ?? 0
        let done = transfer.total > 0 && transfer.completed >= transfer.total
        if !force, !done, let last = lastDelivered[id], now.timeIntervalSince(last) < Self.minInterval { return }
        lastDelivered[id] = now
        if transfers[index] != transfer { transfers[index] = transfer }
    }

    private func trimFinished() {
        let finished = transfers.filter { !$0.isActive }
        guard finished.count > Self.maxFinished else { return }
        let drop = Set(finished.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }.dropFirst(Self.maxFinished).map(\.id))
        transfers.removeAll { drop.contains($0.id) }
    }

    private func updateBand() {
        guard let activities else { return }
        let active = transfers.contains(where: \.isActive)
        if !active {
            if progressPosted {
                activities.dismiss(id: Self.progressActivityID)
                progressPosted = false
            }
            return
        }
        guard !progressPosted else { return }
        progressPosted = true
        activities.post(LiveActivity(id: Self.progressActivityID, kind: .notification, priority: 44, duration: nil,
                                     height: NotchMetrics.activityBandHeight, opensTab: opensTab) {
            ShelfTransfersBand(monitor: ShelfTransfersMonitor.shared)
        })
    }

    private func postDone(_ transfer: ShelfTransfer) {
        guard let activities else { return }
        activities.post(LiveActivity(id: Self.doneActivityID, kind: .notification, priority: 65, duration: 4,
                                     height: NotchMetrics.activityBandHeight, opensTab: opensTab) {
            ShelfTransferDoneBand(transfer: transfer)
        })
    }

    private func dismissBands() {
        activities?.dismiss(id: Self.progressActivityID)
        activities?.dismiss(id: Self.doneActivityID)
        progressPosted = false
    }
}
