import AppKit
import Combine
import Foundation
import SystemConfiguration

/// "Sync to iPhone (iCloud Drive)": keeps iCloud Drive › SparkV up to date
/// with SparkV's content, readable in the iPhone Files app, and imports what
/// the iPhone drops into SparkV/Inbox.
///
/// Opt-in and off by default. Nothing touches iCloud Drive until the user
/// turns it on, so the one macOS privacy prompt (if any) appears right then.
/// Changes are debounced (3 s of quiet, at most 45 s), runs never overlap,
/// all file work happens off the main thread, and a run with nothing new
/// only compares sizes and dates.
@MainActor
final class CloudSyncController: ObservableObject {
    static let shared = CloudSyncController()

    struct ActivityLine: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var settings: CloudSyncSettings
    @Published private(set) var status: CloudSyncStatus = .off
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastReport: CloudSyncReport?
    /// The folder being written (iCloud Drive/SparkV, or this Mac's subfolder).
    @Published private(set) var destination: URL?
    @Published private(set) var heldRemovals = 0
    @Published private(set) var trackedFiles = 0
    @Published private(set) var activity: [ActivityLine] = []
    /// macOS refused access; nothing runs again until the user retries.
    @Published private(set) var isBlockedByPrivacy = false

    /// Called after something arrived from the iPhone ("Imported 2 items"),
    /// so the notch can show it. Optional.
    var onImport: ((String) -> Void)?

    // Connected sources (not singletons in the app).
    private weak var meetingAssistant: MeetingAssistant?
    private weak var tray: TrayStore?
    private weak var clipboard: ClipboardController?
    private weak var focus: FocusController?

    let modeLog: CloudSyncModeLog
    private let supportDirectory: URL
    private let iCloudRoot: URL
    private let deviceName: String
    private let launchedAt = Date()

    private var subscriptions: [AnyCancellable] = []
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var inboxScanTask: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedInbox: URL?
    private var isRunning = false
    private var rerunFull: Bool?
    private var pendingSince: Date?
    private var allowMassRemovalOnce = false
    private var allowRecreateOnce = false
    private var isActive = false
    private var didStart = false
    private var lastPrune = Date.distantPast

    /// Quiet time after a change before syncing, and the longest a change waits.
    static let quietDelay: TimeInterval = 3
    static let maxDelay: TimeInterval = 45
    /// Inbox fallback poll and full re-check intervals.
    static let pollInterval: TimeInterval = 60
    static let fullCheckInterval: TimeInterval = 15 * 60
    /// Right after launch a store can still be loading; an empty category
    /// does not remove files from iCloud Drive during this time.
    static let launchGrace: TimeInterval = 120

    init(supportDirectory: URL = CloudSyncPaths.supportDirectory, iCloudRoot: URL = CloudSyncPaths.iCloudDriveRoot,
         deviceName: String? = nil) {
        self.supportDirectory = supportDirectory
        self.iCloudRoot = iCloudRoot
        self.deviceName = deviceName ?? Self.computerName
        settings = Self.loadSettings(from: supportDirectory)
        modeLog = CloudSyncModeLog(fileURL: supportDirectory.appendingPathComponent("mode-sessions.json"))
    }

    nonisolated static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
    }

    // MARK: - Wiring

    /// Hands over the stores that are not singletons. Call once, before `start()`.
    func connect(meetings: MeetingAssistant?, tray: TrayStore?, clipboard: ClipboardController?, focus: FocusController?) {
        meetingAssistant = meetings
        self.tray = tray
        self.clipboard = clipboard
        self.focus = focus
        if isActive { resubscribe() }
    }

    /// Call once at launch. Does nothing unless the user turned sync on.
    func start() {
        guard !didStart else { return }
        didStart = true
        if settings.isEnabled { activate(initialDelay: 8) } else { status = .off }
    }

    func stop() {
        deactivate()
    }

    // MARK: - Settings

    func setEnabled(_ on: Bool) {
        guard settings.isEnabled != on else { return }
        settings.isEnabled = on
        if on { settings.isPaused = false }
        saveSettings()
        if on {
            log("Sync turned on")
            activate(initialDelay: 0)
        } else {
            log("Sync turned off; files in iCloud Drive stay as they are")
            deactivate()
            status = .off
        }
    }

    func setPaused(_ paused: Bool) {
        guard settings.isEnabled, settings.isPaused != paused else { return }
        settings.isPaused = paused
        saveSettings()
        if paused {
            deactivate()
            status = .paused(nil)
        } else {
            activate(initialDelay: 0)
        }
    }

    func setCategory(_ category: CloudSyncCategory, _ on: Bool) {
        guard settings.categories.contains(category) != on else { return }
        if on { settings.categories.insert(category) } else { settings.categories.remove(category) }
        saveSettings()
        reconfigure()
    }

    func isOn(_ category: CloudSyncCategory) -> Bool { settings.categories.contains(category) }

    func setIncludesTranscripts(_ on: Bool) { update { $0.includesTranscripts = on } }
    func setIncludesSpaceAttachments(_ on: Bool) { update { $0.includesSpaceAttachments = on } }
    func setImportsInbox(_ on: Bool) { update { $0.importsInbox = on } }

    /// Lets the user pick another folder (any synced folder works the same:
    /// Dropbox, Google Drive, an external drive). SparkV writes into a
    /// SparkV subfolder there.
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Sync Here"
        panel.message = "SparkV will keep a “SparkV” folder up to date inside the folder you choose."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        update { $0.customFolderPath = url.path }
        log("Syncing to \(url.path)")
        return true
    }

    func useICloudDrive() {
        guard settings.customFolderPath != nil else { return }
        update { $0.customFolderPath = nil }
        log("Syncing to iCloud Drive")
    }

    func syncNow() {
        guard settings.isEnabled else { return }
        if settings.isPaused { setPaused(false); return }
        isBlockedByPrivacy = false
        if !isActive {
            activate(initialDelay: 0)
        } else {
            if pollTask == nil { startPolling() }
            schedule(full: true, after: 0)
        }
    }

    /// Confirms removals held back because they looked like a loading failure.
    func applyHeldRemovals() {
        allowMassRemovalOnce = true
        heldRemovals = 0
        schedule(full: true, after: 0)
    }

    /// After the SparkV folder was deleted from iCloud Drive: write it again.
    func recreateFolder() {
        allowRecreateOnce = true
        if settings.isPaused { settings.isPaused = false; saveSettings() }
        activate(initialDelay: 0)
    }

    var locationDescription: String {
        if let custom = settings.customFolderPath { return (custom as NSString).abbreviatingWithTildeInPath + "/SparkV" }
        return "iCloud Drive › SparkV"
    }

    func revealInFinder() {
        if let destination, FileManager.default.fileExists(atPath: destination.path) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func revealTrash() {
        guard let destination else { return }
        let trash = destination.appendingPathComponent(CloudSyncPaths.trash, isDirectory: true)
        if FileManager.default.fileExists(atPath: trash.path) { NSWorkspace.shared.open(trash) } else { revealInFinder() }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    private func update(_ change: (inout CloudSyncSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        saveSettings()
        reconfigure()
    }

    private func reconfigure() {
        guard isActive else { return }
        resubscribe()
        schedule(full: true, after: 0.5)
    }

    // MARK: - Lifecycle

    private func activate(initialDelay: TimeInterval) {
        guard settings.isEnabled else { return }
        guard !settings.isPaused else { status = .paused(nil); return }
        isActive = true
        isBlockedByPrivacy = false
        resubscribe()
        startPolling()
        schedule(full: true, after: initialDelay)
    }

    private func deactivate() {
        isActive = false
        subscriptions = []
        debounceTask?.cancel()
        debounceTask = nil
        pollTask?.cancel()
        pollTask = nil
        inboxScanTask?.cancel()
        inboxScanTask = nil
        stopWatchingInbox()
        modeLog.stop()
        pendingSince = nil
    }

    /// Listens to the stores of the categories that are on.
    private func resubscribe() {
        subscriptions = []
        let on = settings.categories
        var signals: [AnyPublisher<Void, Never>] = []
        func add<P: Publisher>(_ p: P) where P.Failure == Never {
            signals.append(p.dropFirst().map { _ in () }.eraseToAnyPublisher())
        }
        if on.contains(.meetings), let m = meetingAssistant { add(m.$library) }
        if on.contains(.flowNotes) { add(FlowStore.shared.$notes) }
        if on.contains(.dictations) { add(FlowStore.shared.$history) }
        if on.contains(.spaces) {
            let s = SpaceStore.shared
            add(s.$items)
            add(s.$spaces)
            add(s.$currentPersonaID)
        }
        if on.contains(.tray), let tray { add(tray.$items) }
        if on.contains(.clipboard), let clipboard { add(clipboard.$items) }
        if on.contains(.focus), let focus { add(focus.store.$sessions) }
        if on.contains(.habits) {
            add(HabitStore.shared.$habits)
            add(HabitStore.shared.$done)
        }
        if on.contains(.modes) {
            modeLog.start()
            add(modeLog.$sessions)
        } else {
            modeLog.stop()
        }
        for signal in signals {
            signal.receive(on: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.noteChange() } }
                .store(in: &subscriptions)
        }
    }

    /// Something changed: sync after a short quiet period.
    func noteChange() {
        guard isActive, !isBlockedByPrivacy else { return }
        let now = Date()
        let since = pendingSince ?? now
        pendingSince = since
        let wait = min(Self.quietDelay, max(0, Self.maxDelay - now.timeIntervalSince(since)))
        schedule(full: true, after: wait)
    }

    private func schedule(full: Bool, after delay: TimeInterval) {
        guard isActive, !isBlockedByPrivacy else { return }
        if full {
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                await self?.run(full: true)
            }
        } else {
            guard inboxScanTask == nil else { return }
            inboxScanTask = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                self?.inboxScanTask = nil
                await self?.run(full: false)
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var lastFull = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(lastFull) >= Self.fullCheckInterval {
                    lastFull = Date()
                    self.schedule(full: true, after: 0)
                } else if self.settings.importsInbox {
                    self.schedule(full: false, after: 0)
                }
            }
        }
    }

    // MARK: - Inbox watching

    private func watchInbox(at inbox: URL) {
        guard settings.importsInbox else { stopWatchingInbox(); return }
        guard watchedInbox != inbox || watcher == nil else { return }
        stopWatchingInbox()
        let fd = open(inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let events = self.watcher?.data ?? []
                if events.contains(.delete) || events.contains(.rename) {
                    // The Inbox itself moved or went away: re-create it on the next run.
                    self.stopWatchingInbox()
                    self.schedule(full: false, after: 2)
                } else {
                    self.schedule(full: false, after: 2.5)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        watchedInbox = inbox
    }

    private func stopWatchingInbox() {
        watcher?.cancel()
        watcher = nil
        watchedInbox = nil
    }

    // MARK: - A run

    private func run(full: Bool) async {
        guard isActive, !isBlockedByPrivacy else { return }
        if isRunning {
            rerunFull = (rerunFull ?? false) || full
            return
        }
        guard full || settings.importsInbox else { return }

        let base: URL
        switch CloudSyncLocation.resolve(settings, iCloudRoot: iCloudRoot) {
        case .ready(let url):
            base = url
        case .iCloudDriveOff:
            status = .attention("iCloud Drive is off on this Mac. Turn it on in System Settings, or choose another folder.")
            return
        case .folderMissing(let path):
            status = .attention("The folder \((path as NSString).abbreviatingWithTildeInPath) is not available.")
            return
        }

        isRunning = true
        if full {
            pendingSince = nil
            status = .syncing
        }
        let job = CloudSyncJob(
            base: base, deviceID: settings.deviceID, deviceName: deviceName,
            manifestURL: manifestURL(for: base),
            receivedDirectory: supportDirectory.appendingPathComponent("Received", isDirectory: true),
            input: full ? makeInput() : nil,
            importsInbox: settings.importsInbox,
            allowMassRemoval: full && allowMassRemovalOnce,
            allowRecreate: full && allowRecreateOnce,
            graceCategories: full ? graceCategories() : []
        )
        if full {
            allowMassRemovalOnce = false
            allowRecreateOnce = false
        }

        let outcome = await Task.detached(priority: .utility) { CloudSyncJob.perform(job) }.value
        isRunning = false
        finish(outcome, full: full)

        if let again = rerunFull {
            rerunFull = nil
            schedule(full: again, after: 1)
        }
    }

    private func finish(_ outcome: CloudSyncJob.Outcome, full: Bool) {
        switch outcome {
        case .rootGone:
            settings.isPaused = true
            saveSettings()
            deactivate()
            status = .paused("The SparkV folder was removed from iCloud Drive")
            log("Paused: the SparkV folder was removed from iCloud Drive")
        case .failed(let message, let permission):
            if permission { blockForPrivacy() } else { status = .failed(message) }
            log(message)
        case .waiting(let message):
            // Another Mac's owner file is still downloading: try again soon
            // rather than claim its folder.
            status = .failed(message)
            log(message)
            schedule(full: true, after: 30)
        case .done(let dest, let report, let arrivals, let pending, let tracked):
            destination = dest
            trackedFiles = tracked
            if full { lastReport = report; heldRemovals = report.heldRemovals }
            lastSync = Date()
            watchInbox(at: CloudSyncInbox.inboxURL(in: dest))
            deliver(arrivals)
            if report.changedCount > 0 { log(summary(report)) }
            for error in report.errors.prefix(3) { log(error) }
            if report.permissionDenied {
                blockForPrivacy()
            } else if heldRemovals > 0 {
                status = .attention("\(heldRemovals) files would move to the SparkV trash. Check, then confirm.")
            } else if let error = report.errors.first {
                status = .failed(error)
            } else {
                status = .idle
            }
            if pending > 0, settings.importsInbox { schedule(full: false, after: 3) }
            if full { pruneReceived() }
        }
    }

    private func blockForPrivacy() {
        isBlockedByPrivacy = true
        debounceTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
        stopWatchingInbox()
        status = .attention("macOS blocked SparkV from this folder. Allow it in Privacy & Security › Files & Folders, then Retry.")
    }

    // MARK: - Input

    private func makeInput() -> CloudSyncInput {
        let on = settings.categories
        var input = CloudSyncInput(settings: settings)
        if on.contains(.meetings), let meetingAssistant { input.meetings = meetingAssistant.library }
        if on.contains(.flowNotes) { input.flowNotes = FlowStore.shared.notes }
        if on.contains(.dictations) { input.dictations = FlowStore.shared.history }
        if on.contains(.spaces) {
            let store = SpaceStore.shared
            // In-memory fallback (database failed to open): don't mirror an empty store.
            if store.database != nil, let persona = store.personas.first(where: { $0.id == store.currentPersonaID }) {
                var attachments: [UUID: URL] = [:]
                if settings.includesSpaceAttachments {
                    for item in store.items where item.attachmentPath != nil {
                        if let url = store.attachmentURL(for: item) { attachments[item.id] = url }
                    }
                }
                input.spaces = .init(personaID: persona.id, personaName: persona.name,
                                     hasSeveralPersonas: store.personas.count > 1,
                                     spaces: store.spaces, items: store.items, attachments: attachments)
            }
        }
        if on.contains(.tray), let tray { input.tray = tray.items }
        if on.contains(.clipboard), let clipboard { input.clipboardPinned = clipboard.items.filter(\.isPinned) }
        if on.contains(.focus), let focus { input.focusSessions = focus.store.sessions }
        if on.contains(.modes) { input.modeSessions = modeLog.sessions }
        if on.contains(.habits) {
            input.habits = .init(habits: HabitStore.shared.habits, done: HabitStore.shared.done)
        }
        return input
    }

    /// Categories that are empty right after launch (maybe still loading).
    private func graceCategories() -> Set<CloudSyncCategory> {
        guard Date().timeIntervalSince(launchedAt) < Self.launchGrace else { return [] }
        let on = settings.categories
        var empty: Set<CloudSyncCategory> = []
        if on.contains(.meetings), meetingAssistant?.library.isEmpty ?? false { empty.insert(.meetings) }
        if on.contains(.flowNotes), FlowStore.shared.notes.isEmpty { empty.insert(.flowNotes) }
        if on.contains(.dictations), FlowStore.shared.history.isEmpty { empty.insert(.dictations) }
        if on.contains(.spaces), SpaceStore.shared.items.isEmpty { empty.insert(.spaces) }
        if on.contains(.focus), focus?.store.sessions.isEmpty ?? false { empty.insert(.focus) }
        return empty
    }

    // MARK: - Imports

    private func deliver(_ arrivals: [CloudSyncInbox.Arrival]) {
        var imported = 0
        for arrival in arrivals {
            guard !arrival.isDuplicate else {
                log("“\(arrival.name)” was already imported; moved to Inbox/Imported")
                continue
            }
            switch arrival.kind {
            case .text:
                guard let text = arrival.text else { continue }
                SpaceStore.shared.addManual(title: arrival.title, text: text, url: nil, spaceID: nil, kind: .note)
                log("Imported “\(arrival.name)” into the Spaces Inbox")
            case .link:
                guard let link = arrival.link else { continue }
                SpaceStore.shared.addManual(title: arrival.title, text: link.absoluteString, url: link, spaceID: nil, kind: .link)
                log("Imported link “\(arrival.title)” into the Spaces Inbox")
            case .image, .file:
                guard let copy = arrival.localCopy else { continue }
                if let tray {
                    // The Tray hands new items to Spaces itself when that source is on.
                    tray.addFile(copy)
                    log("Put “\(arrival.name)” on the Tray")
                } else {
                    SpaceIngestCenter.file(copy, userInitiated: true)
                    log("Imported “\(arrival.name)” into Spaces")
                }
            }
            imported += 1
        }
        if imported > 0 {
            AppLog.log("CloudSync: imported \(imported) item(s) from the iCloud Drive Inbox")
            onImport?(imported == 1 ? "1 item arrived from iPhone" : "\(imported) items arrived from iPhone")
        }
    }

    /// SparkV's local copies of imported files are only needed while the
    /// Tray points at them (images are copied into the Tray's own storage,
    /// Spaces copies attachments into its store). The originals stay in
    /// iCloud Drive › SparkV › Inbox › Imported.
    private func pruneReceived(olderThan age: TimeInterval = 30 * 24 * 3600) {
        guard Date().timeIntervalSince(lastPrune) > 3600 else { return }
        lastPrune = Date()
        let referenced = Set((tray?.items ?? []).compactMap { $0.url?.standardizedFileURL.deletingLastPathComponent().path })
        let folder = supportDirectory.appendingPathComponent("Received", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-age)
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for entry in entries where !referenced.contains(entry.standardizedFileURL.path) {
                let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
                if date < cutoff { try? fm.removeItem(at: entry) }
            }
        }
    }

    // MARK: - Log and persistence

    private func log(_ text: String) {
        activity.insert(ActivityLine(date: Date(), text: text), at: 0)
        if activity.count > 40 { activity.removeLast(activity.count - 40) }
        AppLog.log("CloudSync: \(text)")
    }

    private func summary(_ r: CloudSyncReport) -> String {
        var parts: [String] = []
        if r.written > 0 { parts.append("\(r.written) updated") }
        if r.renamed > 0 { parts.append("\(r.renamed) renamed") }
        if r.trashed > 0 { parts.append("\(r.trashed) moved to trash") }
        if r.preserved > 0 { parts.append("\(r.preserved) edited copies kept in Conflicts") }
        if r.imported > 0 { parts.append("\(r.imported) imported") }
        return "Synced: " + parts.joined(separator: ", ")
    }

    private func manifestURL(for base: URL) -> URL {
        let id = CloudSyncEngine.sha256(Data(base.standardizedFileURL.path.utf8)).prefix(16)
        return supportDirectory.appendingPathComponent("manifest-\(id).json")
    }

    private static func loadSettings(from directory: URL) -> CloudSyncSettings {
        let url = directory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url) else { return CloudSyncSettings() }
        return (try? JSONDecoder.cloudSync.decode(CloudSyncSettings.self, from: data)) ?? CloudSyncSettings()
    }

    private func saveSettings() {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder.cloudSync.encode(settings).write(to: supportDirectory.appendingPathComponent("settings.json"), options: .atomic)
        } catch {
            AppLog.log("CloudSync: could not save settings: \(error.localizedDescription)")
        }
    }
}

// MARK: - Background job

/// The file work of one run, done off the main thread.
struct CloudSyncJob: Sendable {
    enum Outcome: Sendable {
        case done(destination: URL, report: CloudSyncReport, arrivals: [CloudSyncInbox.Arrival], pendingInbox: Int, trackedFiles: Int)
        case rootGone
        case failed(String, permission: Bool)
        /// iCloud Drive hasn't downloaded the folder's owner file yet.
        case waiting(String)
    }

    var base: URL
    var deviceID: UUID
    var deviceName: String
    var manifestURL: URL
    var receivedDirectory: URL
    /// nil: Inbox scan only.
    var input: CloudSyncInput?
    var importsInbox: Bool
    var allowMassRemoval: Bool
    var allowRecreate: Bool
    var graceCategories: Set<CloudSyncCategory>
    var now = Date()

    static func perform(_ job: CloudSyncJob) -> Outcome {
        let fm = FileManager.default
        var manifest = loadManifest(job.manifestURL)
        let loaded = manifest

        // The user deleted the whole folder (maybe on purpose, from the
        // iPhone): don't silently put everything back.
        if !manifest.entries.isEmpty, !fm.fileExists(atPath: job.base.path), !job.allowRecreate {
            return .rootGone
        }
        if job.allowRecreate, !fm.fileExists(atPath: job.base.path) {
            manifest.entries = [:]
        }

        let destination: URL
        do {
            destination = try CloudSyncOwner.destination(base: job.base, deviceID: job.deviceID, deviceName: job.deviceName,
                                                         now: job.now)
        } catch let wait as CloudSyncOwner.NotDownloaded {
            return .waiting(wait.localizedDescription)
        } catch {
            return .failed("Can't use \(job.base.lastPathComponent): \(error.localizedDescription)",
                           permission: CloudSyncEngine.isPermissionDenied(error))
        }

        var report = CloudSyncReport()
        if let input = job.input {
            let rendering = CloudSyncRenderer.render(input)
            // Right after launch, an empty category with files already in
            // iCloud Drive is treated as "not loaded yet".
            let frozen = job.graceCategories.filter { category in
                manifest.entries.values.contains { $0.sourceKey.hasPrefix(category.rawValue + ":") }
            }
            let scopes = rendering.scopes.filter { scope in !frozen.contains { scope.hasPrefix($0.rawValue + ":") } }
            report = CloudSyncEngine(root: destination, now: job.now)
                .mirror(rendering.files, scopes: scopes, manifest: &manifest, allowMassRemoval: job.allowMassRemoval)
            report.skipped += rendering.skipped
        }

        var arrivals: [CloudSyncInbox.Arrival] = []
        var pending = 0
        if job.importsInbox, !report.permissionDenied {
            let inbox = CloudSyncInbox.collect(root: destination, receivedDirectory: job.receivedDirectory,
                                               manifest: &manifest, now: job.now)
            arrivals = inbox.arrivals
            pending = inbox.pending
            report.imported = arrivals.filter { !$0.isDuplicate }.count
            report.skipped += inbox.skipped
            report.errors += inbox.errors
        }

        if manifest != loaded { saveManifest(manifest, to: job.manifestURL) }
        report.finishedAt = Date()
        return .done(destination: destination, report: report, arrivals: arrivals, pendingInbox: pending,
                     trackedFiles: manifest.entries.count)
    }

    static func loadManifest(_ url: URL) -> CloudSyncManifest {
        guard let data = try? Data(contentsOf: url) else { return CloudSyncManifest() }
        if let manifest = try? JSONDecoder.cloudSync.decode(CloudSyncManifest.self, from: data) { return manifest }
        // Damaged: keep it for inspection and start over. Starting over is
        // safe: files already in place are recognized by their content, and
        // anything unrecognized is preserved in Conflicts before a write.
        let aside = url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        AppLog.log("CloudSync: manifest was damaged; moved aside to \(aside.lastPathComponent)")
        return CloudSyncManifest()
    }

    static func saveManifest(_ manifest: CloudSyncManifest, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: url, options: .atomic)
        } catch {
            AppLog.log("CloudSync: could not save manifest: \(error.localizedDescription)")
        }
    }
}

// MARK: - Mode sessions

/// Records when each Mode ran (the Modes engine keeps only the active one),
/// while sync of Modes is on. Saved in Application Support/SparkV/CloudSync.
@MainActor
final class CloudSyncModeLog: ObservableObject {
    @Published private(set) var sessions: [CloudSyncModeSession] = []
    static let limit = 2000
    /// Shorter runs (a quick toggle) are not worth a line.
    static let minimumDuration: TimeInterval = 60

    private let fileURL: URL
    private var subscription: AnyCancellable?
    private var current: (id: UUID, name: String, since: Date)?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder.cloudSync.decode([CloudSyncModeSession].self, from: data) {
            sessions = saved
        }
    }

    func start(engine given: ModeEngine? = nil) {
        guard subscription == nil else { return }
        let engine = given ?? ModeEngine.shared
        subscription = engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak engine] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine else { return }
                    self.observe(activeID: engine.activeMode?.id, name: engine.activeMode?.name, since: engine.activeSince)
                }
            }
        observe(activeID: engine.activeMode?.id, name: engine.activeMode?.name, since: engine.activeSince)
    }

    func stop() {
        subscription = nil
        current = nil
    }

    /// Feeds the current state; a change of active Mode closes the last run.
    func observe(activeID: UUID?, name: String?, since: Date?, now: Date = Date()) {
        if let running = current, running.id != activeID {
            if now.timeIntervalSince(running.since) >= Self.minimumDuration {
                sessions.insert(CloudSyncModeSession(id: UUID(), modeID: running.id, name: running.name,
                                                     startedAt: running.since, endedAt: now), at: 0)
                if sessions.count > Self.limit { sessions.removeLast(sessions.count - Self.limit) }
                save()
            }
            current = nil
        }
        if current == nil, let activeID {
            current = (activeID, name ?? "Mode", since ?? now)
        }
    }

    private func save() {
        let list = sessions
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder.cloudSync.encode(list).write(to: url, options: .atomic)
        }
    }
}
