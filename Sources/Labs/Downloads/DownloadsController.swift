import AppKit
import SwiftUI

/// Download watcher: shows progress for files arriving in ~/Downloads in the
/// band under the notch, then offers Open, Reveal, Add to Tray, Send to Space
/// and Sort (rules first, on-device AI second) with Undo.
///
/// Off by default. ~/Downloads is privacy-protected, so nothing touches it
/// until the user turns the watcher on; that first listing is what makes
/// macOS ask, and a refusal shows "Allow in Privacy & Security" instead of
/// failing quietly. Watching costs one FSEvents stream (kernel-coalesced
/// paths, only the changed entries are `lstat`ed), one NSProgress
/// subscription, and a 1 s size sample only while something is in flight.
@MainActor
final class DownloadsController: ObservableObject {
    enum Status: Equatable {
        case off
        case starting
        case running
        /// macOS refused access to the folder (Files & Folders).
        case denied
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    /// Newest first; in-flight downloads stay on top.
    @Published private(set) var items: [DownloadItem] = []
    /// Primary suggestion per finished item (rule first, else the model).
    @Published private(set) var suggestions: [UUID: DownloadSuggestion] = [:]
    /// What the on-device model picked, when it differs from the rule.
    @Published private(set) var aiPicks: [UUID: DownloadDestination] = [:]
    /// Items the model is still thinking about.
    @Published private(set) var thinking: Set<UUID> = []
    /// Short feedback line in the drawer ("Moved to Images").
    @Published private(set) var notice: String?
    /// Item whose last move the header's Undo puts back.
    @Published private(set) var undoItemID: UUID?
    /// Folders directly inside Downloads (sort targets).
    @Published private(set) var subfolders: [URL] = []
    /// Cancel / Pause the browser offers for each in-flight download (from
    /// its published progress; empty for browsers that publish none).
    @Published private(set) var controls: [UUID: DownloadsProgressSubscriber.Controls] = [:]

    /// The app's controller, for Settings sections.
    private(set) static weak var current: DownloadsController?

    @Published private(set) var isEnabled: Bool
    @Published var showsActivity: Bool {
        didSet { defaults.set(showsActivity, forKey: Keys.showsActivity); if !showsActivity { dismissActivities() } else { updateProgressActivity() } }
    }
    @Published var suggestsWithAI: Bool {
        didSet { defaults.set(suggestsWithAI, forKey: Keys.suggestsWithAI) }
    }

    let rules: DownloadRuleStore
    /// The watched folder (~/Downloads in the app).
    let folder: URL

    /// Tab the bands open when hovered (set by the app).
    var opensTab: NotchState.Tab?
    /// Opens the drawer on the Downloads tab (set by the app).
    var onOpenTab: (() -> Void)?
    /// Puts a file on the Tray (set by the app: `tray.addFile`).
    var onAddToTray: ((URL) -> Void)?
    /// Sends a file to Spaces; the ingest center's agents pick the Space.
    var sendToSpaceHandler: (URL) -> Void = { SpaceIngestCenter.file($0, userInitiated: true) }
    var airDropHandler: ([URL]) -> Void = { AirDrop.share(urls: $0) }
    /// On-device folder pick among names (a seam for tests).
    var folderSuggester: (DownloadItem, [String]) async -> String? = { item, names in
        await DownloadsAI.suggestFolder(name: item.name, category: item.category, domain: item.sourceDomain,
                                        size: item.totalBytes ?? item.bytesReceived, folders: names)
    }
    var aiAvailable: () -> Bool = { DownloadsAI.isAvailable }
    /// Wait before an auto-sort rule moves a file (browsers finish writing
    /// attributes right after the rename).
    var autoSortDelay: TimeInterval = 1.5
    /// Standard folders offered as sort targets.
    var standardFolders: [String] = ["~/Documents", "~/Pictures", "~/Movies", "~/Music", "~/Desktop"]

    static let maxItems = 30
    static let seedWindow: TimeInterval = 48 * 3600
    static let seedCount = 6
    static let progressActivityID = "downloads.progress"
    static let doneActivityID = "downloads.done"

    private enum Keys {
        static let enabled = "Downloads.enabled"
        static let showsActivity = "Downloads.showsActivity"
        static let suggestsWithAI = "Downloads.suggestsWithAI"
        /// Code signature the folder was last read under. macOS keys the
        /// Files & Folders grant on it; after a re-sign or a move the first
        /// read would prompt by itself, so launch waits for Try Again.
        static let readSignature = "Downloads.readSignature"
    }

    private let activities: ActivityCenter
    private let defaults: UserDefaults
    private let historyURL: URL
    private var tracker: DownloadsTracker?
    private var stream: DownloadsFolderStream?
    private var progressSubscriber: DownloadsProgressSubscriber?
    private var tickTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var progressPosted = false
    private var tickGeneration = 0

    /// `folder`, `defaults` and `storage` are test seams; the app uses
    /// ~/Downloads, the standard defaults and Application Support/SparkV/Downloads.
    init(activities: ActivityCenter, folder: URL? = nil, defaults: UserDefaults = .standard, storage: URL? = nil) {
        self.activities = activities
        self.defaults = defaults
        self.folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Downloads", isDirectory: true)
        historyURL = storage.appendingPathComponent("history.json")
        rules = DownloadRuleStore(fileURL: storage.appendingPathComponent("rules.json"))
        isEnabled = defaults.bool(forKey: Keys.enabled)
        showsActivity = defaults.object(forKey: Keys.showsActivity) as? Bool ?? true
        suggestsWithAI = defaults.object(forKey: Keys.suggestsWithAI) as? Bool ?? true
        loadHistory()
        Self.current = self
    }

    // MARK: Lifecycle

    /// Starts watching if the user turned the watcher on earlier. Never
    /// prompts: it waits out PermissionCenter's launch quiet period, and
    /// doesn't read the folder when the grant belongs to another build.
    func start() {
        guard isEnabled else { return }
        // Only the real ~/Downloads is privacy-protected (tests use a temp folder).
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard folder.standardizedFileURL == downloads.standardizedFileURL else { return beginWatching() }
        let readSignature = defaults.string(forKey: Keys.readSignature)
        if let readSignature, readSignature != PermissionSignature.current {
            status = .failed("SparkV changed since Downloads was allowed. Click Try Again to allow it for this version.")
            AppLog.log("Downloads: not reading the folder at launch (allowed under a different signature)")
            return
        }
        let permissions = PermissionCenter.shared
        if readSignature == nil, !permissions.hasAsked(.downloadsFolder) {
            // Never read successfully and never asked: the read would be the
            // prompt, which only a click may show.
            status = .failed("Click Try Again to let SparkV read your Downloads folder.")
            AppLog.log("Downloads: not reading the folder at launch (never allowed)")
            return
        }
        let wait = permissions.launchQuietRemaining
        guard wait > 0 else { return beginWatching() }
        status = .starting
        startTask?.cancel()
        startTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            self.beginWatching()
        }
    }

    func stop() {
        endWatching()
        dismissActivities()
    }

    /// The switch in the drawer, the rules window and the settings menu.
    func setEnabled(_ on: Bool) {
        guard on != isEnabled || (on && status != .running) else { return }
        isEnabled = on
        defaults.set(on, forKey: Keys.enabled)
        if on { askThenWatch() } else { endWatching(); status = .off }
    }

    /// Asks again after the user changed Privacy & Security.
    func retry() {
        guard isEnabled else { return setEnabled(true) }
        endWatching()
        askThenWatch()
    }

    /// From a click: the first read of the real ~/Downloads is macOS's
    /// prompt, so it goes through PermissionCenter's queue (one system
    /// alert at a time) before the watcher reads the folder.
    private func askThenWatch() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard folder.standardizedFileURL == downloads.standardizedFileURL else { return beginWatching() }
        startTask?.cancel()
        status = .starting
        startTask = Task { [weak self] in
            let result = await PermissionCenter.shared.request(.downloadsFolder, from: "Downloads", openingSettings: false)
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            if result == .notDetermined {
                // Held back (SparkV just launched) or another alert is up.
                self.status = .failed("Click Try Again to let SparkV read your Downloads folder.")
                return
            }
            self.beginWatching()
        }
    }

    func openPrivacySettings() {
        PermissionCenter.shared.openSettings(.downloadsFolder, from: "Downloads")
    }

    /// Only the real ~/Downloads is privacy-protected (tests use a temp folder).
    private var isRealDownloads: Bool {
        folder.standardizedFileURL == FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].standardizedFileURL
    }

    private struct FolderEntry: Sendable {
        let name: String
        let added: Date?
        let isRegularFile: Bool
        let isDirectory: Bool
        let isPackage: Bool
    }

    private enum ListResult: Sendable {
        case ok([FolderEntry])
        case denied
        case failed(String)
    }

    nonisolated private static func list(_ folder: URL) -> ListResult {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
            return .ok(urls.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return FolderEntry(name: url.lastPathComponent, added: values?.addedToDirectoryDate,
                                   isRegularFile: values?.isRegularFile ?? false, isDirectory: values?.isDirectory ?? false,
                                   isPackage: values?.isPackage ?? false)
            })
        } catch {
            return isPermissionError(error) ? .denied : .failed((error as NSError).localizedDescription)
        }
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    private func beginWatching() {
        startTask?.cancel()
        status = .starting
        let folder = folder
        startTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.list(folder) }.value
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            switch result {
            case .denied:
                self.status = .denied
                if self.isRealDownloads { PermissionCenter.shared.recordAsked(.downloadsFolder) }
                AppLog.log("Downloads: access to the Downloads folder was denied")
            case .failed(let reason):
                self.status = .failed(reason)
                AppLog.log("Downloads: can't read the Downloads folder (\(reason))")
            case .ok(let entries):
                self.defaults.set(PermissionSignature.current, forKey: Keys.readSignature)
                if self.isRealDownloads { PermissionCenter.shared.recordAsked(.downloadsFolder) }
                self.startWatching(entries: entries)
            }
        }
    }

    private func startWatching(entries: [FolderEntry]) {
        let tracker = DownloadsTracker(folder: folder)
        tracker.isKnownPath = { [weak self] path in
            self?.items.contains { DownloadsPath.real($0.url.path) == path } ?? false
        }
        tracker.onActiveChanged = { [weak self] active in self?.activeChanged(active) }
        tracker.onFinished = { [weak self] item in self?.finished(item) }
        tracker.onCancelled = { [weak self] item in self?.cancelled(item) }
        self.tracker = tracker
        tracker.prime(entryNames: entries.map(\.name))
        pruneMissing()
        seedRecent(entries)
        subfolders = Self.subfolderURLs(entries, in: tracker.folder)

        let stream = DownloadsFolderStream(path: tracker.rootPath) { [weak self] events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let tracker = self.tracker else { return }
                    tracker.handle(events: events)
                    // A folder appeared, moved or vanished at the top level: refresh the sort targets.
                    if events.contains(where: { $0.isDirectory && $0.isCreateOrRename
                        && ($0.path as NSString).deletingLastPathComponent == tracker.rootPath
                        && !DownloadPartials.isPartialName(($0.path as NSString).lastPathComponent) }) {
                        self.refreshSubfolders()
                    }
                    self.ensureTicking()
                }
            }
        }
        guard stream.start() else {
            status = .failed("Couldn't watch the Downloads folder")
            self.tracker = nil
            return
        }
        self.stream = stream
        let subscriber = DownloadsProgressSubscriber(folder: tracker.folder) { [weak self] update in
            self?.tracker?.handle(progress: update)
            self?.refreshControls()
            self?.ensureTicking()
        }
        subscriber.start()
        progressSubscriber = subscriber
        status = .running
        ensureTicking()
        AppLog.log("Downloads: watching started")
    }

    private func endWatching() {
        startTask?.cancel()
        startTask = nil
        stream?.stop()
        stream = nil
        progressSubscriber?.stop()
        progressSubscriber = nil
        tickTask?.cancel()
        tickTask = nil
        tracker = nil
        items.removeAll { $0.isActive }
        controls = [:]
        dismissActivities()
    }

    private func ensureTicking() {
        guard tickTask == nil, tracker?.needsTicks == true else { return }
        tickGeneration &+= 1
        let generation = tickGeneration
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let tracker = self.tracker else { break }
                tracker.tick()
                if !tracker.needsTicks { break }
            }
            // Only clear our own handle: a restart may already have started a newer loop.
            if self?.tickGeneration == generation { self?.tickTask = nil }
        }
    }

    // MARK: Folder contents

    nonisolated private static func subfolderURLs(_ entries: [FolderEntry], in folder: URL) -> [URL] {
        entries
            .filter { $0.isDirectory && !$0.isPackage && !DownloadPartials.isIgnoredName($0.name) && !DownloadPartials.isPartialName($0.name) }
            .map { folder.appendingPathComponent($0.name, isDirectory: true) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(24)
            .map { $0 }
    }

    private func refreshSubfolders() {
        guard let tracker else { return }
        let folder = tracker.folder
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.list(folder) }.value
            guard case .ok(let entries) = result else { return }
            self?.subfolders = Self.subfolderURLs(entries, in: folder)
        }
    }

    /// The last few downloads added to Downloads before watching started, so
    /// the drawer isn't empty. They're never sorted automatically.
    private func seedRecent(_ entries: [FolderEntry]) {
        let cutoff = Date().addingTimeInterval(-Self.seedWindow)
        let known = Set(items.map { DownloadsPath.real($0.url.path) })
        guard let tracker else { return }
        let recent = entries
            .filter { $0.isRegularFile && !DownloadPartials.isIgnoredName($0.name) && !DownloadPartials.isPartialName($0.name) }
            .compactMap { entry -> (FolderEntry, Date)? in entry.added.flatMap { $0 >= cutoff ? (entry, $0) : nil } }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.seedCount)
        var added: [DownloadItem] = []
        for (entry, date) in recent {
            let url = tracker.folder.appendingPathComponent(entry.name)
            guard !known.contains(url.path), let stat = DownloadFileStat.of(url.path) else { continue }
            let froms = DownloadMetadata.whereFroms(url)
            let agent = DownloadMetadata.quarantineAgent(url)
            // Only files that came from the internet (browsers tag them); not
            // files the user copied or saved into Downloads.
            guard !froms.isEmpty || agent != nil else { continue }
            var item = DownloadItem(name: entry.name, url: url, phase: .finished, browser: .other,
                                    bytesReceived: stat.size, totalBytes: stat.size, startedAt: date,
                                    finishedAt: date, sourceURL: froms.first,
                                    referrerURL: froms.count > 1 ? froms[1] : nil,
                                    agentName: agent, isSeeded: true)
            item.browser = Self.browser(forAgent: item.agentName)
            added.append(item)
        }
        guard !added.isEmpty else { return }
        items = (items + added).sorted(by: Self.order)
        trim()
        added.forEach { computeSuggestion(for: $0) }
    }

    private static func browser(forAgent agent: String?) -> DownloadBrowser {
        guard let agent = agent?.lowercased() else { return .other }
        if agent.contains("safari") { return .safari }
        if agent.contains("firefox") { return .firefox }
        if ["chrome", "edge", "brave", "arc", "vivaldi", "opera", "chromium"].contains(where: agent.contains) { return .chromium }
        return .other
    }

    private static func order(_ a: DownloadItem, _ b: DownloadItem) -> Bool {
        if a.isActive != b.isActive { return a.isActive }
        return (a.finishedAt ?? a.startedAt) > (b.finishedAt ?? b.startedAt)
    }

    // MARK: Tracker events

    var activeItems: [DownloadItem] { items.filter(\.isActive) }

    private func activeChanged(_ active: [DownloadItem]) {
        var list = items
        for item in active {
            if let index = list.firstIndex(where: { $0.id == item.id }) {
                list[index] = item
            } else {
                list.insert(item, at: 0)
            }
        }
        let activeIDs = Set(active.map(\.id))
        // In-flight items the tracker no longer reports were finished or cancelled separately.
        list.removeAll { $0.isActive && !activeIDs.contains($0.id) }
        items = list.sorted(by: Self.order)
        refreshControls()
        updateProgressActivity()
    }

    // MARK: Cancel / Pause (the browser's own, through its progress)

    /// The paths a download is known by: the partial file now, the final name.
    private func progressPaths(for item: DownloadItem) -> Set<String> {
        let root = tracker?.rootPath ?? DownloadsPath.real(folder.path)
        return [DownloadsPath.real(item.url.path), root + "/" + item.name]
    }

    private func refreshControls() {
        guard let progressSubscriber else {
            if !controls.isEmpty { controls = [:] }
            return
        }
        var next: [UUID: DownloadsProgressSubscriber.Controls] = [:]
        for item in items where item.isActive {
            let found = progressSubscriber.controls(matching: progressPaths(for: item))
            if found != .none { next[item.id] = found }
        }
        if next != controls { controls = next }
    }

    /// Cancels a download in the browser that's downloading it.
    func cancelDownload(_ id: UUID) {
        guard let item = item(id), item.isActive, let progressSubscriber else { return }
        if progressSubscriber.cancel(matching: progressPaths(for: item)) {
            AppLog.log("Downloads: cancelled a download in \(item.browser.displayName)")
            show("Cancelling \(item.name)…")
        } else {
            show("\(item.browser.displayName) doesn't let other apps cancel this download")
        }
    }

    /// Pauses or resumes a download in its browser.
    func togglePause(_ id: UUID) {
        guard let item = item(id), item.isActive, let progressSubscriber else { return }
        if !progressSubscriber.togglePause(matching: progressPaths(for: item)) {
            show("\(item.browser.displayName) doesn't let other apps pause this download")
        }
        refreshControls()
    }

    private func finished(_ item: DownloadItem) {
        controls[item.id] = nil
        var item = item
        if item.browser == .other { item.browser = Self.browser(forAgent: item.agentName) }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        items.sort(by: Self.order)
        trim()
        saveHistory()
        updateProgressActivity()
        AppLog.log("Downloads: a download finished (\(item.category.rawValue))")

        computeSuggestion(for: item)
        if rules.firstMatch(for: item)?.sortsAutomatically != true {
            postDoneActivity(for: item.id)
        }
        // Browsers write kMDItemWhereFroms/quarantine around the final rename
        // (Chromium annotates right after it), so the first read can miss
        // them. Read again after a moment, then decide on auto-sort with the
        // full provenance, so a source-domain auto rule still fires.
        let id = item.id
        let size = item.bytesReceived
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.autoSortDelay ?? 1.5))
            guard let self else { return }
            self.refreshProvenance(id)
            guard let current = self.items.first(where: { $0.id == id }), current.move == nil,
                  let rule = self.rules.firstMatch(for: current), rule.sortsAutomatically,
                  DownloadFileStat.of(current.url.path)?.size == size else { return }
            self.sort(id: id, to: rule.destination, ruleName: rule.name, automatic: true)
        }
    }

    /// Re-reads where-froms and the quarantine agent of a just-finished file;
    /// updates the suggestion when the matching rule changed.
    private func refreshProvenance(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].move == nil, !items[index].isActive else { return }
        let url = items[index].url
        let froms = DownloadMetadata.whereFroms(url)
        let agent = DownloadMetadata.quarantineAgent(url)
        var updated = items[index]
        if let first = froms.first { updated.sourceURL = first }
        if froms.count > 1 { updated.referrerURL = froms[1] }
        if updated.agentName == nil { updated.agentName = agent }
        if updated.browser == .other { updated.browser = Self.browser(forAgent: updated.agentName) }
        guard updated != items[index] else { return }
        let ruleBefore = rules.firstMatch(for: items[index])?.id
        items[index] = updated
        saveHistory()
        if rules.firstMatch(for: updated)?.id != ruleBefore { computeSuggestion(for: updated) }
    }

    private func cancelled(_ item: DownloadItem) {
        items.removeAll { $0.id == item.id }
        controls[item.id] = nil
        updateProgressActivity()
    }

    // MARK: Suggestions

    /// A sort target with the name the menu and the model see.
    struct Choice: Identifiable, Hashable {
        let name: String
        let destination: DownloadDestination
        var id: String { name + "|" + destination.displayPath }
    }

    /// Rule folders, Downloads subfolders and standard folders, de-duplicated
    /// by path (Spaces is separate).
    func folderChoices(excluding current: URL? = nil) -> [Choice] {
        var seen: Set<String> = []
        var names: Set<String> = []
        var result: [Choice] = []
        let currentFolder = current.map { DownloadsPath.real($0.deletingLastPathComponent().path) }
        func add(_ destination: DownloadDestination) {
            guard let url = destination.folderURL() else { return }
            let path = DownloadsPath.real(url.path)
            guard path != currentFolder, seen.insert(path).inserted else { return }
            var name = destination.displayName
            if names.contains(name) {
                name = "\(name) (\(url.deletingLastPathComponent().lastPathComponent))"
            }
            names.insert(name)
            result.append(Choice(name: name, destination: destination))
        }
        rules.rules.filter(\.isEnabled).map(\.destination).forEach(add)
        subfolders.map { DownloadDestination.folder(url: $0) }.forEach(add)
        standardFolders.map { DownloadDestination.folder($0) }.forEach(add)
        return result
    }

    private func computeSuggestion(for item: DownloadItem) {
        let rule = rules.firstMatch(for: item)
        if let rule {
            suggestions[item.id] = DownloadSuggestion(destination: rule.destination, origin: .rule(rule.name))
        } else {
            suggestions[item.id] = nil
        }
        guard suggestsWithAI, !item.isSeeded, item.move == nil, rule?.sortsAutomatically != true, aiAvailable() else { return }
        let choices = folderChoices(excluding: item.url)
        guard !choices.isEmpty else { return }
        let id = item.id
        // A kind-only rule is generic; a specific folder from the model wins over it.
        let ruleIsGeneric = rule.map { $0.conditions.allSatisfy { $0.field == .kind } } ?? true
        thinking.insert(id)
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.folderSuggester(item, choices.map(\.name))
            self.thinking.remove(id)
            guard let answer, let choice = choices.first(where: { $0.name == answer }),
                  let current = self.items.first(where: { $0.id == id }), current.move == nil else { return }
            if choice.destination != self.suggestions[id]?.destination {
                self.aiPicks[id] = choice.destination
            }
            if self.suggestions[id] == nil || (ruleIsGeneric && choice.destination != self.suggestions[id]?.destination
                                                && !self.isKindFolder(choice.destination)) {
                self.suggestions[id] = DownloadSuggestion(destination: choice.destination, origin: .ai)
            }
        }
    }

    /// One of the default per-kind folders (a generic pick, not worth overriding a rule).
    private func isKindFolder(_ destination: DownloadDestination) -> Bool {
        rules.rules.contains { rule in
            rule.destination == destination && rule.conditions.allSatisfy { $0.field == .kind }
        }
    }

    // MARK: Actions

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    func open(_ id: UUID) {
        guard let item = item(id) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ id: UUID) {
        guard let item = item(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func addToTray(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isActive else { return }
        guard let onAddToTray else { return show("The Tray isn't available") }
        onAddToTray(items[index].url)
        items[index].addedToTray = true
        saveHistory()
        show("Added to the Tray")
    }

    func sendToSpace(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isActive else { return }
        guard FileManager.default.fileExists(atPath: items[index].url.path) else { return show("\(items[index].name) isn't there any more") }
        sendToSpaceHandler(items[index].url)
        items[index].sentToSpace = true
        saveHistory()
        show("Sent to Spaces, filing it now")
    }

    func airDrop(_ id: UUID) {
        guard let item = item(id), !item.isActive else { return }
        airDropHandler([item.url])
    }

    /// Sorts with the current suggestion.
    func sortWithSuggestion(_ id: UUID) {
        guard let suggestion = suggestions[id] else { return }
        let ruleName: String? = if case .rule(let name) = suggestion.origin { name } else { nil }
        sort(id: id, to: suggestion.destination, ruleName: ruleName, automatic: false)
    }

    /// Moves a finished file (or sends it to Spaces). Undo puts it back.
    func sort(id: UUID, to destination: DownloadDestination, ruleName: String? = nil, automatic: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        guard !item.isActive else { return }
        if destination == .space {
            sendToSpace(id)
            if automatic { postMovedActivity(name: item.name, folder: "Spaces", id: id) }
            return
        }
        guard let folderURL = destination.folderURL() else { return show("That folder can't be used") }
        tracker?.ignore(path: item.url.path)
        do {
            let newURL = try DownloadsSorter.move(item.url, toFolder: folderURL)
            let move = DownloadMove(from: item.url, to: newURL, destination: destination, date: Date(),
                                    ruleName: ruleName, automatic: automatic)
            items[index].url = newURL
            items[index].name = newURL.lastPathComponent
            items[index].move = move
            undoItemID = id
            suggestions[id] = nil
            aiPicks[id] = nil
            saveHistory()
            refreshSubfolders()
            show("Moved to \(destination.displayName)")
            if automatic { postMovedActivity(name: item.name, folder: destination.displayName, id: id) }
            AppLog.log("Downloads: sorted a file\(automatic ? " automatically" : "")")
        } catch {
            show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Picks a folder with the standard Open panel, then sorts there.
    func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sort(id: id, to: .folder(url: url))
    }

    var canUndo: Bool { undoItemID.flatMap(item)?.move != nil }

    func undoLast() {
        guard let id = undoItemID else { return }
        undo(id)
    }

    /// Moves a sorted file back to where it was downloaded.
    func undo(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let move = items[index].move else { return }
        tracker?.ignore(path: move.from.path)
        do {
            let restored = try DownloadsSorter.undo(move)
            items[index].url = restored
            items[index].name = restored.lastPathComponent
            items[index].move = nil
            if undoItemID == id { undoItemID = nil }
            saveHistory()
            refreshSubfolders()
            computeSuggestion(for: items[index])
            show("Put back in \(restored.deletingLastPathComponent().lastPathComponent)")
        } catch {
            show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Removes the entry from the list (the file stays).
    func forget(_ id: UUID) {
        items.removeAll { $0.id == id && !$0.isActive }
        suggestions[id] = nil
        aiPicks[id] = nil
        if undoItemID == id { undoItemID = nil }
        saveHistory()
    }

    func clearFinished() {
        let finished = items.filter { !$0.isActive }.map(\.id)
        items.removeAll { !$0.isActive }
        finished.forEach { suggestions[$0] = nil; aiPicks[$0] = nil }
        undoItemID = nil
        saveHistory()
    }

    /// Adds a rule that sorts files like this one to `destination` and opens the editor on it.
    func makeRule(from id: UUID, destination: DownloadDestination) {
        guard let item = item(id) else { return }
        let rule = rules.addRule(like: item, destination: destination)
        DownloadsRulesWindowController.shared.show(controller: self, selecting: rule.id)
    }

    func openRulesEditor() {
        DownloadsRulesWindowController.shared.show(controller: self)
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Live activities

    private func updateProgressActivity() {
        let hasActive = items.contains(where: \.isActive)
        guard showsActivity, hasActive else {
            if progressPosted {
                activities.dismiss(id: Self.progressActivityID)
                progressPosted = false
            }
            return
        }
        guard !progressPosted else { return }
        progressPosted = true
        activities.post(LiveActivity(id: Self.progressActivityID, kind: .notification, priority: 45, duration: nil,
                                     height: NotchMetrics.activityBandHeight, opensTab: opensTab) { [unowned self] in
            DownloadsProgressBand(controller: self)
        })
    }

    private func postDoneActivity(for id: UUID) {
        guard showsActivity else { return }
        activities.post(LiveActivity(id: Self.doneActivityID, kind: .notification, priority: 66, duration: 6,
                                     height: NotchMetrics.activityBandHeight, opensTab: opensTab) { [unowned self] in
            DownloadsDoneBand(controller: self, itemID: id)
        })
    }

    private func postMovedActivity(name: String, folder: String, id: UUID) {
        guard showsActivity else { return }
        activities.post(LiveActivity(id: Self.doneActivityID, kind: .notification, priority: 66, duration: 5,
                                     height: NotchMetrics.activityBandHeight, opensTab: opensTab) {
            DownloadsMovedBand(name: name, folder: folder)
        })
    }

    private func dismissActivities() {
        activities.dismiss(id: Self.progressActivityID)
        activities.dismiss(id: Self.doneActivityID)
        progressPosted = false
    }

    // MARK: History

    private struct History: Codable {
        var items: [DownloadItem]
        var undoItemID: UUID?
    }

    private func trim() {
        let active = items.filter(\.isActive)
        let rest = items.filter { !$0.isActive }.prefix(max(0, Self.maxItems - active.count))
        let kept = active + rest
        if kept.count != items.count {
            let keep = Set(kept.map(\.id))
            for id in items.map(\.id) where !keep.contains(id) {
                suggestions[id] = nil
                aiPicks[id] = nil
            }
            items = kept
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode(History.self, from: data) else { return }
        items = history.items.filter { $0.phase == .finished }
        undoItemID = history.undoItemID.flatMap { id in items.contains { $0.id == id && $0.move != nil } ? id : nil }
        // Checking the files means looking inside ~/Downloads: only when the
        // user has the watcher on (otherwise it's done when they turn it on).
        if isEnabled { pruneMissing() }
    }

    /// Drops history entries whose file is gone (deleted or moved by hand).
    private func pruneMissing() {
        let before = items.count
        items.removeAll { !$0.isActive && !FileManager.default.fileExists(atPath: $0.url.path) }
        guard items.count != before else { return }
        let ids = Set(items.map(\.id))
        suggestions = suggestions.filter { ids.contains($0.key) }
        aiPicks = aiPicks.filter { ids.contains($0.key) }
        if let undo = undoItemID, !ids.contains(undo) { undoItemID = nil }
    }

    private func saveHistory() {
        let history = History(items: items.filter { $0.phase == .finished }, undoItemID: undoItemID)
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        } catch {
            AppLog.log("Downloads: couldn't save history (\(error.localizedDescription))")
        }
    }
}
