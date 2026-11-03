import AppKit
import SwiftUI

/// What happened to one ingest request (for UI feedback).
enum SpaceIngestOutcome: Sendable, Equatable {
    /// An agent filed it into a Space.
    case filed(itemID: UUID, spaceID: UUID, spaceName: String)
    /// Saved, waiting in the Inbox (maybe with a suggestion).
    case inbox(itemID: UUID)
    /// Nothing saved: source off, duplicate, nothing worth filing…
    case skipped(String)
    case failed(String)
}

/// Feeds Spaces from the rest of the app: meetings, dictations and notes,
/// Tray items, new screenshots, watched folders, the current web page and
/// the selected Mail message. Connectors build `SpaceIngestInput`s
/// (`SpaceConnectors`); this class gates them on `enabledSources`, runs them
/// one at a time into `SpaceStore.ingest`, and posts a small live activity
/// when something is auto-filed (at most one every few seconds).
///
/// Nothing prompts at launch: Apple Events only run from the explicit
/// web/mail actions, and the screenshot watcher waits for the user's go-ahead
/// when the screenshot folder is privacy-protected (Desktop by default).
@MainActor
final class SpaceIngestCenter: ObservableObject {
    /// The running center; the static helpers route through it.
    private(set) static weak var current: SpaceIngestCenter?

    /// Every source the center knows about (SpaceItemSource isn't CaseIterable).
    nonisolated static let allSources: [SpaceItemSource] = [.meetings, .flow, .tray, .screenshots, .files, .web, .mail, .clipboard, .jobs, .manual]
    nonisolated static let defaultSources: Set<SpaceItemSource> = Set(allSources).subtracting([.clipboard])

    /// Sources allowed to auto-file. Explicit user actions (save web page,
    /// save mail, dropping a file) work regardless. Persisted.
    @Published var enabledSources: Set<SpaceItemSource> {
        didSet {
            guard enabledSources != oldValue else { return }
            Self.defaults.set(enabledSources.map(\.rawValue).sorted(), forKey: Keys.enabledSources)
            // Turning screenshots on by hand is the go-ahead to watch a protected folder.
            if enabledSources.contains(.screenshots), !oldValue.contains(.screenshots) {
                Self.recordScreenshotConsent()
            }
            updateWatchers()
        }
    }

    /// Folders watched recursively for new files (source `.files`). Persisted.
    @Published private(set) var watchedFolders: [URL]
    /// Where screenshots land (com.apple.screencapture location, default ~/Desktop).
    @Published private(set) var screenshotFolder: URL
    /// True when screenshots are on but the folder is privacy-protected and
    /// the user hasn't said go yet: show a button that calls `allowScreenshotWatching()`.
    @Published private(set) var screenshotWatchNeedsConsent = false
    @Published private(set) var isWatchingScreenshots = false
    /// A user-triggered action (web page, mail) is running.
    @Published private(set) var isWorking = false
    @Published private(set) var lastOutcome: SpaceIngestOutcome?

    let store: SpaceStore
    let activities: ActivityCenter

    private enum Keys {
        static let enabledSources = "Spaces.Ingest.enabledSources"
        static let watchedFolders = "Spaces.Ingest.watchedFolders"
        static let screenshotConsent = "Spaces.Ingest.screenshotConsent"
        /// The code signature the go-ahead was given under. macOS keys the
        /// Files & Folders grant on it, so after a re-sign or a move the
        /// watcher would prompt by itself: it waits for a new go-ahead.
        static let screenshotConsentSignature = "Spaces.Ingest.screenshotConsentSignature"
    }

    private static func recordScreenshotConsent() {
        defaults.set(true, forKey: Keys.screenshotConsent)
        defaults.set(PermissionSignature.current, forKey: Keys.screenshotConsentSignature)
    }

    /// The go-ahead applies to this build. A go-ahead saved before signatures
    /// were recorded is adopted for the current build once.
    private static var hasScreenshotConsent: Bool {
        guard defaults.bool(forKey: Keys.screenshotConsent) else { return false }
        guard let signature = defaults.string(forKey: Keys.screenshotConsentSignature) else {
            defaults.set(PermissionSignature.current, forKey: Keys.screenshotConsentSignature)
            return true
        }
        return signature == PermissionSignature.current
    }

    private static var defaults: UserDefaults { .standard }
    /// Minimum gap between "Filed to …" activities.
    static let announceInterval: TimeInterval = 4
    static let activityID = "spaces.ingest"

    private var isRunning = false
    private var screenshotWatcher: SpaceDirectoryWatcher?
    private var screenshotPrefix: String?
    private var screenshotExtension = "png"
    private var folderWatcher: SpaceFolderWatcher?
    private var locationRefreshTask: Task<Void, Never>?
    /// Holds the watchers back during PermissionCenter's launch quiet period:
    /// the first read of a protected folder can show a system prompt.
    private var launchDelayTask: Task<Void, Never>?
    /// Serializes ingestion so the store sees one input at a time.
    private var tail: Task<Void, Never>?
    /// Paths seen this session by the watchers (avoids re-OCR on repeat events).
    private var seenPaths: Set<String> = []
    private var pendingFolderPaths: Set<String> = []
    private var folderFlushTask: Task<Void, Never>?

    private struct Announcement {
        var spaceName: String
        var detail: String
        var color: Color
        var icon: String
    }

    private var lastAnnounced: Date = .distantPast
    private var pendingAnnouncements: [Announcement] = []
    private var announceTask: Task<Void, Never>?

    init(store: SpaceStore, activities: ActivityCenter) {
        self.store = store
        self.activities = activities
        if let saved = Self.defaults.array(forKey: Keys.enabledSources) as? [String] {
            enabledSources = Set(saved.compactMap(SpaceItemSource.init(rawValue:)))
        } else {
            enabledSources = Self.defaultSources
        }
        let paths = Self.defaults.array(forKey: Keys.watchedFolders) as? [String] ?? []
        watchedFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        screenshotFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        Self.current = self
    }

    // MARK: - Lifecycle

    /// Starts the watchers for enabled sources. Never prompts.
    func start() {
        Self.current = self
        guard !isRunning else { return }
        isRunning = true
        let wait = PermissionCenter.shared.launchQuietRemaining
        if wait > 0 {
            launchDelayTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.launchDelayTask = nil
                self.updateWatchers()
            }
        } else {
            updateWatchers()
        }
        // The screenshot location can change in the Screenshot app; re-read it now and then.
        locationRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SparkVEnergy.shared.duration(.seconds(120)))
                guard !Task.isCancelled, let self else { return }
                // Only matters while screenshots are collected and someone can take one.
                guard self.enabledSources.contains(.screenshots), !SparkVEnergy.shared.screensAsleep else { continue }
                self.updateScreenshotWatcher()
            }
        }
        AppLog.log("Spaces ingest: started (\(enabledSources.map(\.rawValue).sorted().joined(separator: ", ")))")
    }

    func stop() {
        isRunning = false
        launchDelayTask?.cancel()
        launchDelayTask = nil
        locationRefreshTask?.cancel()
        locationRefreshTask = nil
        folderFlushTask?.cancel()
        folderFlushTask = nil
        pendingFolderPaths.removeAll()
        updateWatchers()
    }

    func isEnabled(_ source: SpaceItemSource) -> Bool { enabledSources.contains(source) }

    func setEnabled(_ source: SpaceItemSource, _ enabled: Bool) {
        if enabled { enabledSources.insert(source) } else { enabledSources.remove(source) }
    }

    /// The user's go-ahead to watch a privacy-protected screenshot folder
    /// (may show the Files & Folders prompt once).
    func allowScreenshotWatching() {
        Self.recordScreenshotConsent()
        enabledSources.insert(.screenshots)
        updateScreenshotWatcher()
    }

    /// Re-reads the screenshot location (e.g. after the user changed it).
    func refreshScreenshotLocation() {
        updateScreenshotWatcher()
    }

    // MARK: - Static helpers (called from existing features)

    /// A finished meeting (call after notes are generated; calling again is
    /// harmless, the store de-dupes by "meeting:<id>").
    static func meeting(_ record: MeetingRecord, attendees: [String] = []) {
        guard let center = current, center.isEnabled(.meetings),
              let input = SpaceConnectors.meetingInput(record, attendees: attendees) else { return }
        center.enqueue(input, userInitiated: false)
    }

    /// A finished dictation (short ones are skipped).
    static func flow(_ entry: FlowEntry) {
        guard let center = current, center.isEnabled(.flow), let input = SpaceConnectors.flowInput(entry) else { return }
        center.enqueue(input, userInitiated: false)
    }

    /// A Scratchpad note.
    static func flow(_ note: FlowNote) {
        guard let center = current, center.isEnabled(.flow), let input = SpaceConnectors.flowNoteInput(note) else { return }
        center.enqueue(input, userInitiated: false)
    }

    /// A new Tray item: text, image (OCR + copy) or file (text + reference).
    static func tray(_ item: TrayItem) {
        guard let center = current, center.isEnabled(.tray) else { return }
        center.enqueue(userInitiated: false) { await SpaceConnectors.trayInput(item) }
    }

    /// A file the user handed over (drop, Open panel). With
    /// `userInitiated: false` it is gated on `.files` like the folder watcher.
    static func file(_ url: URL, userInitiated: Bool = true) {
        guard let center = current, userInitiated || center.isEnabled(.files) else { return }
        center.enqueue(userInitiated: userInitiated) { await SpaceConnectors.fileInput(url, source: .files) }
    }

    /// A dropped .eml file (same as `file(_:)`, which detects .eml too).
    static func mailFile(_ url: URL) {
        guard let center = current else { return }
        center.enqueue(userInitiated: true) { await SpaceConnectors.fileInput(url, source: .mail) }
    }

    /// Copied text (only when `.clipboard` is on; off by default).
    static func clipboard(_ text: String, appBundleID: String?, appName: String?) {
        guard let center = current, center.isEnabled(.clipboard),
              let input = SpaceConnectors.clipboardInput(text, appBundleID: appBundleID, appName: appName) else { return }
        center.enqueue(input, userInitiated: false)
    }

    /// Saves the frontmost browser tab (Safari, Chrome, Arc, Edge, Brave).
    static func saveCurrentWebPage() {
        guard let center = current else { return AppLog.log("Spaces ingest: not running, can't save web page") }
        Task { await center.saveFrontmostWebPage() }
    }

    /// Saves the message(s) selected in Mail.
    static func saveSelectedMail() {
        guard let center = current else { return AppLog.log("Spaces ingest: not running, can't save mail") }
        Task { await center.saveMailSelection() }
    }

    // MARK: - Web

    @discardableResult
    func saveFrontmostWebPage() async -> SpaceIngestOutcome {
        guard !isWorking else { return .skipped("Busy") }
        isWorking = true
        defer { isWorking = false }

        let workspace = NSWorkspace.shared
        guard let browser = SpaceConnectors.Browser.target(
            frontmostBundleID: workspace.frontmostApplication?.bundleIdentifier,
            runningBundleIDs: workspace.runningApplications.compactMap(\.bundleIdentifier)
        ) else {
            return fail("Open the page in Safari, Chrome, Arc, Edge or Brave first")
        }
        if let problem = await automationProblem(bundleID: browser.bundleID, appName: browser.name) {
            return fail(problem)
        }

        let tab: SpaceConnectors.BrowserTab
        switch await SpaceAppleEvents.shared.run(browser.tabScript, timeout: 7) {
        case .failure(let failure):
            return fail(message(for: failure, appName: browser.name))
        case .success(let output):
            switch SpaceConnectors.parseBrowserOutput(output, browser: browser.name) {
            case .privateWindow: return fail("Private windows aren't saved")
            case .nothing: return fail("No page open in \(browser.name)")
            case .tab(let found): tab = found
            }
        }

        if tab.url.isFileURL {
            guard let input = await SpaceConnectors.fileInput(tab.url, source: .web) else { return fail("Couldn't read that file") }
            return await submitSerially(input, userInitiated: true)
        }

        post(headline: "Saving page…", detail: tab.title.isEmpty ? (SpaceConnectors.domain(of: tab.url) ?? "") : tab.title,
             color: .white, icon: "safari", duration: 30)
        var page: TrayAIWebPage?
        do {
            page = try await TrayAIWeb.fetch(tab.url)
        } catch {
            // Still save the title and URL; the page may need a login.
            AppLog.log("Spaces ingest: page fetch failed: \(error.localizedDescription)")
        }
        return await submitSerially(SpaceConnectors.webInput(tab: tab, page: page), userInitiated: true)
    }

    // MARK: - Mail

    @discardableResult
    func saveMailSelection() async -> SpaceIngestOutcome {
        guard !isWorking else { return .skipped("Busy") }
        isWorking = true
        defer { isWorking = false }

        let bundleID = SpaceConnectors.mailBundleID
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else {
            return fail("Open Mail and select a message first")
        }
        if let problem = await automationProblem(bundleID: bundleID, appName: "Mail") { return fail(problem) }

        switch await SpaceAppleEvents.shared.run(SpaceConnectors.mailSelectionScript, timeout: 12) {
        case .failure(let failure):
            return fail(message(for: failure, appName: "Mail"))
        case .success(let output):
            let messages = SpaceConnectors.parseMailScriptOutput(output)
            guard !messages.isEmpty else { return fail("Select a message in Mail first") }
            var last: SpaceIngestOutcome = .skipped("Nothing saved")
            for message in messages {
                last = await submitSerially(SpaceConnectors.mailInput(message, source: .mail, attachment: nil), userInitiated: true)
            }
            return last
        }
    }

    /// nil when Apple Events to the app are allowed (asks the first time,
    /// which is fine here: the user just triggered the action).
    private func automationProblem(bundleID: String, appName: String) async -> String? {
        let status = Int(await SpaceAppleEvents.shared.permission(bundleID: bundleID, askUser: true))
        switch status {
        case Int(noErr): return nil
        case Int(errAEEventNotPermitted):
            return "Allow SparkV to control \(appName) in System Settings › Privacy & Security › Automation"
        case Int(errAEEventWouldRequireUserConsent): return "SparkV needs permission to read \(appName)"
        case Int(procNotFound): return "\(appName) isn't running"
        default: return nil // Unknown: let the script itself report.
        }
    }

    private func message(for failure: SpaceAppleEvents.Failure, appName: String) -> String {
        switch failure {
        case .notRunning: "\(appName) isn't running"
        case .notPermitted: "Allow SparkV to control \(appName) in System Settings › Privacy & Security › Automation"
        case .timedOut: "\(appName) didn't answer in time"
        case .script(let code, let message):
            message.isEmpty ? "\(appName) returned error \(code)" : "\(appName): \(message)"
        }
    }

    private func fail(_ reason: String) -> SpaceIngestOutcome {
        AppLog.log("Spaces ingest: \(reason)")
        let outcome = SpaceIngestOutcome.failed(reason)
        lastOutcome = outcome
        post(headline: "Couldn't save", detail: reason, color: SparkVTheme.warning, icon: "exclamationmark.triangle.fill", duration: 4)
        return outcome
    }

    // MARK: - Ingestion

    private func enqueue(_ input: SpaceIngestInput, userInitiated: Bool) {
        enqueue(userInitiated: userInitiated) { input }
    }

    /// Builds the input (OCR, file reading run off the main actor inside
    /// `make`) and submits it after everything queued before it.
    private func enqueue(userInitiated: Bool, _ make: @escaping @Sendable () async -> SpaceIngestInput?) {
        let previous = tail
        tail = Task { [weak self] in
            let input = await make()
            await previous?.value
            guard let self, let input else { return }
            _ = await self.submit(input, userInitiated: userInitiated)
        }
    }

    /// Waits for queued work, then submits.
    private func submitSerially(_ input: SpaceIngestInput, userInitiated: Bool) async -> SpaceIngestOutcome {
        let previous = tail
        let task = Task { [weak self] () -> SpaceIngestOutcome in
            await previous?.value
            guard let self else { return .skipped("Stopped") }
            return await self.submit(input, userInitiated: userInitiated)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    @discardableResult
    func submit(_ input: SpaceIngestInput, userInitiated: Bool) async -> SpaceIngestOutcome {
        guard userInitiated || enabledSources.contains(input.source) else { return .skipped("\(input.source.rawValue) is off") }
        // The store returns (and refreshes) the existing item for a known key;
        // don't announce those again.
        let existed = !input.sourceKey.isEmpty && store.items.contains { $0.sourceKey == input.sourceKey }
        let result = await store.ingest(input)
        if existed, let item = result {
            let outcome: SpaceIngestOutcome = item.spaceID.map { id in
                .filed(itemID: item.id, spaceID: id, spaceName: store.spaces.first { $0.id == id }?.name ?? "")
            } ?? .inbox(itemID: item.id)
            lastOutcome = outcome
            if userInitiated {
                post(headline: "Already in Spaces", detail: "updated · \(Self.label(for: item.kind))",
                     color: .gray, icon: "checkmark.circle", duration: 2.5)
            }
            return outcome
        }
        guard let item = result else {
            // Empty input, or the same key is being filed right now.
            let outcome = SpaceIngestOutcome.skipped("Nothing new to save")
            lastOutcome = outcome
            if userInitiated {
                post(headline: "Nothing new to save", detail: input.title, color: .gray, icon: "checkmark.circle", duration: 2.5)
            }
            return outcome
        }
        let label = Self.label(for: item.kind)
        if let spaceID = item.spaceID, let space = store.spaces.first(where: { $0.id == spaceID }) {
            let outcome = SpaceIngestOutcome.filed(itemID: item.id, spaceID: space.id, spaceName: space.name)
            lastOutcome = outcome
            announce(Announcement(spaceName: space.name, detail: label, color: Self.color(hex: space.color), icon: space.icon),
                     force: userInitiated)
            return outcome
        }
        let outcome = SpaceIngestOutcome.inbox(itemID: item.id)
        lastOutcome = outcome
        if userInitiated {
            post(headline: "Saved to Inbox", detail: label, color: .white, icon: "tray.and.arrow.down.fill", duration: 3)
        }
        return outcome
    }

    static func label(for kind: SpaceItemKind) -> String {
        switch kind {
        case .meeting: "meeting notes"
        case .note: "note"
        case .dictation: "dictation"
        case .screenshot: "screenshot"
        case .file: "file"
        case .webPage: "web page"
        case .email: "email"
        case .clipboard: "clipboard"
        case .job: "job"
        case .contact: "contact"
        case .link: "link"
        case .manual: "note"
        }
    }

    // MARK: - Watchers

    private func updateWatchers() {
        // Still inside the launch quiet period: the delayed start runs these.
        guard launchDelayTask == nil || !isRunning else { return }
        updateScreenshotWatcher()
        updateFolderWatcher()
    }

    private func updateScreenshotWatcher() {
        let wanted = isRunning && enabledSources.contains(.screenshots)
        let location = SpaceConnectors.ScreenshotLocation.current()
        screenshotFolder = location.folder
        screenshotPrefix = location.prefix
        screenshotExtension = location.fileExtension
        let protected = SpaceConnectors.ScreenshotLocation.isPrivacyProtected(location.folder)
        let consented = Self.hasScreenshotConsent
        screenshotWatchNeedsConsent = wanted && protected && !consented

        guard wanted, !protected || consented else {
            screenshotWatcher?.stop()
            screenshotWatcher = nil
            isWatchingScreenshots = false
            return
        }
        if screenshotWatcher?.url == location.folder { return }
        screenshotWatcher?.stop()
        let watcher = SpaceDirectoryWatcher(url: location.folder) { urls in
            Task { @MainActor in SpaceIngestCenter.current?.screenshotsAppeared(urls) }
        }
        watcher.start()
        screenshotWatcher = watcher
        isWatchingScreenshots = true
        AppLog.log("Spaces ingest: watching screenshots in \(location.folder.path)")
    }

    private func screenshotsAppeared(_ urls: [URL]) {
        guard isRunning, enabledSources.contains(.screenshots) else { return }
        // The app the user was in when they took it (good routing hint).
        let front = NSWorkspace.shared.frontmostApplication
        var hints: [String: String] = [:]
        if let id = front?.bundleIdentifier, id != Bundle.main.bundleIdentifier { hints["app"] = id }
        if let name = front?.localizedName, hints["app"] != nil { hints["appName"] = name }
        let prefix = screenshotPrefix
        let fileExtension = screenshotExtension

        for url in urls where !seenPaths.contains(url.path) {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let byName = SpaceConnectors.ScreenshotLocation.isScreenshotName(name, customPrefix: prefix, fileExtension: fileExtension)
            seenPaths.insert(url.path)
            let frozenHints = hints
            enqueue(userInitiated: false) {
                guard await Self.waitUntilStable(url) else { return nil }
                guard byName || SpaceConnectors.ScreenshotLocation.hasScreenCaptureAttribute(url) else { return nil }
                return await SpaceConnectors.imageInput(at: url, kind: .screenshot, source: .screenshots,
                                                        createdAt: Date(), hints: frozenHints)
            }
        }
    }

    /// Waits until the file exists with a non-zero size that stopped
    /// changing (screenshots and downloads are written in steps).
    nonisolated static func waitUntilStable(_ url: URL, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize = -1
        while Date() < deadline {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if size > 0, size == lastSize { return true }
            lastSize = size
            try? await Task.sleep(for: .milliseconds(600))
        }
        return false
    }

    // Watched folders

    /// Adds a folder to watch (the user picked it, so a Files & Folders
    /// prompt here is expected). Existing files are not imported.
    func addWatchedFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        guard !watchedFolders.contains(where: { $0.path == folder.path }) else { return }
        watchedFolders.append(folder)
        persistFolders()
        enabledSources.insert(.files)
        updateFolderWatcher(force: true)
    }

    func removeWatchedFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        watchedFolders.removeAll { $0.path == path }
        persistFolders()
        updateFolderWatcher(force: true)
    }

    /// Imports a folder's current files once (explicit action).
    func importFolderNow(_ url: URL, limit: Int = 200) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var count = 0
        for case let file as URL in enumerator {
            guard count < limit else { break }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  Self.isIngestibleFile(file.path) else { continue }
            count += 1
            enqueue(userInitiated: false) { await SpaceConnectors.fileInput(file, source: .files) }
        }
    }

    private func persistFolders() {
        Self.defaults.set(watchedFolders.map(\.path), forKey: Keys.watchedFolders)
    }

    private func updateFolderWatcher(force: Bool = false) {
        let paths = watchedFolders.map(\.path)
        let wanted = isRunning && enabledSources.contains(.files) && !paths.isEmpty
        guard wanted else {
            folderWatcher?.stop()
            folderWatcher = nil
            return
        }
        if !force, folderWatcher?.paths == paths { return }
        folderWatcher?.stop()
        let watcher = SpaceFolderWatcher(paths: paths) { files in
            Task { @MainActor in SpaceIngestCenter.current?.folderFilesChanged(files) }
        }
        watcher.start()
        folderWatcher = watcher
    }

    private func folderFilesChanged(_ paths: [String]) {
        guard isRunning, enabledSources.contains(.files) else { return }
        pendingFolderPaths.formUnion(paths.filter(Self.isIngestibleFile))
        guard !pendingFolderPaths.isEmpty else { return }
        // Debounce: a save often fires several events.
        folderFlushTask?.cancel()
        folderFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flushFolderFiles()
        }
    }

    private func flushFolderFiles() {
        let paths = pendingFolderPaths
        pendingFolderPaths.removeAll()
        for path in paths.sorted() where !seenPaths.contains(path) {
            seenPaths.insert(path)
            let url = URL(fileURLWithPath: path)
            enqueue(userInitiated: false) {
                guard await Self.waitUntilStable(url) else { return nil }
                return await SpaceConnectors.fileInput(url, source: .files)
            }
        }
    }

    /// Skips hidden, temporary and partial-download files and anything in
    /// hidden folders or Library.
    nonisolated static func isIngestibleFile(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let name = components.last, !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        if name.hasPrefix("~$") || name.hasSuffix("~") { return false }
        if path.contains("/Library/") || path.contains(".app/") { return false }
        let ext = (String(name) as NSString).pathExtension.lowercased()
        let skipped: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "temp", "icloud", "swp", "lock", "ds_store", "localized", "dmg", "pkg", "zip", "app"]
        return !skipped.contains(ext)
    }

    // MARK: - Live activity

    /// Auto-filed items: at most one activity per `announceInterval`; items
    /// filed meanwhile are summed up in the next one. User actions show at once.
    private func announce(_ announcement: Announcement, force: Bool) {
        let now = Date()
        if force || (pendingAnnouncements.isEmpty && now.timeIntervalSince(lastAnnounced) >= Self.announceInterval) {
            postFiled([announcement])
            return
        }
        pendingAnnouncements.append(announcement)
        guard announceTask == nil else { return }
        let delay = max(0.2, Self.announceInterval - now.timeIntervalSince(lastAnnounced))
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.flushAnnouncements()
        }
    }

    private func flushAnnouncements() {
        announceTask = nil
        let batch = pendingAnnouncements
        pendingAnnouncements.removeAll()
        guard !batch.isEmpty else { return }
        postFiled(batch)
    }

    private func postFiled(_ batch: [Announcement]) {
        lastAnnounced = Date()
        guard let first = batch.first else { return }
        if batch.count == 1 {
            post(headline: "Filed to \(first.spaceName)", detail: first.detail, color: first.color, icon: first.icon, duration: 3)
            return
        }
        var names: [String] = []
        for item in batch where !names.contains(item.spaceName) { names.append(item.spaceName) }
        let detail = names.count == 1 ? names[0] : names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")
        let headline = names.count == 1 ? "Filed \(batch.count) items to \(names[0])" : "Filed \(batch.count) items"
        post(headline: headline, detail: names.count == 1 ? Self.summary(of: batch) : detail,
             color: first.color, icon: names.count == 1 ? first.icon : "square.stack.3d.up.fill", duration: 3.5)
    }

    private static func summary(of batch: [Announcement]) -> String {
        var counts: [(String, Int)] = []
        for item in batch {
            if let index = counts.firstIndex(where: { $0.0 == item.detail }) { counts[index].1 += 1 } else { counts.append((item.detail, 1)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.1) \($0.0)s" : $0.0 }.joined(separator: ", ")
    }

    private func post(headline: String, detail: String, color: Color, icon: String, duration: TimeInterval) {
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 45, duration: duration) {
            SpaceFiledActivityView(headline: headline, detail: detail, color: color, icon: icon)
        })
    }

    /// "#4F8EF7" → Color (SparkV red when unparseable).
    static func color(hex: String) -> Color {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return SparkVTheme.red }
        return Color(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255, blue: Double(number & 0xFF) / 255)
    }
}

/// Band under the notch: Space icon, "Filed to Helm Events · meeting notes".
struct SpaceFiledActivityView: View {
    let headline: String
    let detail: String
    let color: Color
    /// SF Symbol name or emoji.
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 18, height: 18)
            Text(headline)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .layoutPriority(1)
            if !detail.isEmpty {
                Text("· \(detail)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var iconView: some View {
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        } else if !icon.isEmpty {
            Text(icon).font(.system(size: 13))
        } else {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }
}
