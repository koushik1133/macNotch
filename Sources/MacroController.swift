import AppKit
import Foundation
import UniformTypeIdentifiers

/// The two action capsules in the drawer, and the Planner's launcher grid
/// (up to 12 pinned apps, shortcuts and SparkV actions). Each slot runs a
/// built-in SparkV action, a shortcut from the user's library or an app,
/// chosen from a menu and saved in UserDefaults.
@MainActor
final class MacroController: ObservableObject {
    enum BuiltInAction: String, CaseIterable, Identifiable {
        case dictate
        case captureToTray
        case recordMeeting

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictate: "Dictate"
            case .captureToTray: "Capture to Tray"
            case .recordMeeting: "Record Meeting"
            }
        }

        var systemImage: String {
            switch self {
            case .dictate: "mic.fill"
            case .captureToTray: "camera.viewfinder"
            case .recordMeeting: "record.circle"
            }
        }
    }

    enum Assignment: Equatable {
        case builtIn(BuiltInAction)
        /// Exact name of the shortcut in the Shortcuts app.
        case shortcut(String)
        /// An app to open: its bundle identifier, where it was when picked
        /// (the identifier finds it again after a move) and its Finder name.
        case app(bundleID: String, path: String, name: String)

        var title: String {
            switch self {
            case .builtIn(let action): action.title
            case .shortcut(let name): name
            case .app(_, _, let name): name
            }
        }

        var isApp: Bool {
            if case .app = self { return true }
            return false
        }

        /// Saved form: "builtin:dictate", "shortcut:Name", "app:{json}".
        var storageValue: String {
            switch self {
            case .builtIn(let action): return "builtin:\(action.rawValue)"
            case .shortcut(let name): return "shortcut:\(name)"
            case .app(let bundleID, let path, let name):
                let stored = StoredApp(bundleID: bundleID, path: path, name: name)
                let json = (try? JSONEncoder().encode(stored)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return "app:\(json)"
            }
        }

        init?(storageValue value: String) {
            if value.isEmpty { return nil }
            if value.hasPrefix("builtin:") {
                guard let action = BuiltInAction(rawValue: String(value.dropFirst("builtin:".count))) else { return nil }
                self = .builtIn(action)
            } else if value.hasPrefix("shortcut:") {
                self = .shortcut(String(value.dropFirst("shortcut:".count)))
            } else if value.hasPrefix("app:") {
                guard let data = value.dropFirst("app:".count).data(using: .utf8),
                      let stored = try? JSONDecoder().decode(StoredApp.self, from: data),
                      !stored.bundleID.isEmpty || !stored.path.isEmpty else { return nil }
                self = .app(bundleID: stored.bundleID, path: stored.path, name: stored.name)
            } else {
                // Saved by an earlier version, which only stored shortcut names.
                self = .shortcut(value)
            }
        }

        /// Whether `value` was written by this format (prefixed) rather than
        /// the original one, which stored bare shortcut names or "".
        fileprivate static func isCurrentFormat(_ value: String) -> Bool {
            value.hasPrefix("builtin:") || value.hasPrefix("shortcut:") || value.hasPrefix("app:")
        }

        private struct StoredApp: Codable {
            var bundleID: String
            var path: String
            var name: String
        }
    }

    /// One tile of the launcher grid.
    struct LauncherItem: Identifiable, Equatable, Codable {
        let id: UUID
        /// `Assignment.storageValue`.
        var value: String
        /// Shortcuts: the identifier, which survives renames.
        var shortcutID: String?

        var assignment: Assignment? { Assignment(storageValue: value) }
    }

    struct Slot: Identifiable, Equatable {
        let id: Int
        /// nil until the user picks something.
        var assignment: Assignment?
    }

    enum Status: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
        /// Nothing chosen for this slot yet.
        case unassigned
        /// The chosen shortcut is no longer in the user's library.
        case missing
    }

    @Published private(set) var slots: [Slot]
    /// Every shortcut in the user's library, in library order.
    @Published private(set) var library: [String] = []
    /// The same, with identifiers (when the CLI gives them).
    @Published private(set) var libraryEntries: [ShortcutInfo] = []
    @Published private var statuses: [Int: Status] = [:]
    /// The launcher grid, in order.
    @Published private(set) var launcher: [LauncherItem]
    @Published private var launcherStatuses: [UUID: Status] = [:]

    /// Runs built-in actions; set by the window controller, which owns the
    /// tray and the dictation engine.
    var performBuiltIn: ((BuiltInAction) -> Void)?

    /// Most recently created controller, for Settings and menus without an
    /// environment. Weak.
    static weak var current: MacroController?

    /// nil until the first `shortcuts list` succeeds; until then every chosen
    /// shortcut is assumed present.
    private var availableNames: Set<String>?
    private var lastLibraryCheck: ContinuousClock.Instant?
    private var isCheckingLibrary = false
    private var resetTasks: [Int: Task<Void, Never>] = [:]
    private var launcherResetTasks: [UUID: Task<Void, Never>] = [:]
    private let runner = ShortcutRunner()

    private static let defaultsKey = "MacroSlots"
    /// Set once the slots are saved in the prefixed format, so an all-empty
    /// array saved by this version isn't mistaken for the original format.
    /// 3 adds "app:" values; earlier versions read them as shortcut names
    /// that are missing, so nothing breaks when going back.
    private static let formatKey = "MacroSlots.format"
    private static let currentFormat = 3
    /// The first versioned format. Only arrays saved before it (no format
    /// stored) are the original unprefixed format; a format-2 array of
    /// empty slots means the user removed both buttons and stays empty.
    private static let firstVersionedFormat = 2
    /// Home capsules. The launcher grid has its own list.
    private static let slotCount = 2
    private static let launcherKey = "MacroLauncher.items"
    static let maxLauncherItems = 12
    /// A first look at the launcher: apps every Mac has.
    private static let defaultLauncherApps = ["com.apple.iCal", "com.apple.reminders", "com.apple.Notes", "com.apple.shortcuts"]
    /// Out of the box: the two built-ins, which work without any setup.
    private static let defaultAssignments: [Assignment] = [.builtIn(.dictate), .builtIn(.captureToTray)]

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: Self.defaultsKey)
        let isLegacy = saved.map { values in
            defaults.integer(forKey: Self.formatKey) < Self.firstVersionedFormat
                && !values.contains(where: Assignment.isCurrentFormat)
        } ?? false

        slots = (0..<Self.slotCount).map { index in
            guard let saved else {
                return Slot(id: index, assignment: Self.defaultAssignments[index])
            }
            let value = index < saved.count ? saved[index] : ""
            if isLegacy {
                // The original format: "" meant "never chosen", which now
                // gets the built-in default instead of an empty capsule.
                return Slot(id: index, assignment: value.isEmpty ? Self.defaultAssignments[index] : .shortcut(value))
            }
            return Slot(id: index, assignment: Assignment(storageValue: value))
        }

        if let data = defaults.data(forKey: Self.launcherKey),
           let items = try? JSONDecoder().decode([LauncherItem].self, from: data) {
            launcher = Array(items.filter { $0.assignment != nil }.prefix(Self.maxLauncherItems))
        } else {
            launcher = Self.defaultLauncherApps.compactMap { bundleID in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                      let assignment = Self.appAssignment(for: url) else { return nil }
                return LauncherItem(id: UUID(), value: assignment.storageValue, shortcutID: nil)
            }
        }

        if isLegacy {
            AppLog.log("Shortcuts: migrated capsule slots \(saved ?? []) to \(slots.map { $0.assignment?.storageValue ?? "" })")
            saveSlots()
        } else if saved != nil, defaults.integer(forKey: Self.formatKey) < Self.currentFormat {
            defaults.set(Self.currentFormat, forKey: Self.formatKey)
        }
        Self.current = self
        refreshLibrary()
    }

    private func saveSlots() {
        UserDefaults.standard.set(slots.map { $0.assignment?.storageValue ?? "" }, forKey: Self.defaultsKey)
        UserDefaults.standard.set(Self.currentFormat, forKey: Self.formatKey)
    }

    func status(for slot: Slot) -> Status {
        if let status = statuses[slot.id], status != .idle {
            return status
        }
        switch slot.assignment {
        case nil:
            return .unassigned
        case .builtIn:
            return .idle
        case .shortcut(let name):
            if let availableNames, !availableNames.contains(Self.normalized(name)) {
                return .missing
            }
            return .idle
        case .app(let bundleID, let path, _):
            return Self.appURL(bundleID: bundleID, path: path) == nil ? .missing : .idle
        }
    }

    func assign(_ assignment: Assignment?, to slotID: Int) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].assignment = assignment
        resetTasks[slotID]?.cancel()
        statuses[slotID] = nil
        saveSlots()
    }

    func run(_ slot: Slot) {
        switch slot.assignment {
        case nil:
            return
        case .builtIn(let action):
            performBuiltIn?(action)
        case .shortcut(let name):
            runShortcut(name, in: slot)
        case .app(let bundleID, let path, let name):
            let opened = Self.openApp(bundleID: bundleID, path: path)
            if !opened { AppLog.log("Shortcuts: app for a capsule is missing") }
            flash(opened ? .succeeded : .failed("“\(name)” couldn’t be found"), slotID: slot.id)
        }
    }

    private func flash(_ status: Status, slotID: Int) {
        resetTasks[slotID]?.cancel()
        statuses[slotID] = status
        let hold: Duration = status == .succeeded ? .seconds(1.5) : .seconds(6)
        resetTasks[slotID] = Task {
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            statuses[slotID] = .idle
        }
    }

    private func runShortcut(_ name: String, in slot: Slot) {
        guard status(for: slot) != .running else { return }

        resetTasks[slot.id]?.cancel()
        statuses[slot.id] = .running

        Task {
            let outcome: Status
            do {
                _ = try await runner.run(name)
                outcome = .succeeded
            } catch {
                outcome = .failed(error.localizedDescription)
                AppLog.log("Shortcuts: “\(name)” failed: \(error.localizedDescription)")
                // It may have been renamed or deleted since the last check.
                refreshLibrary()
            }
            statuses[slot.id] = outcome

            // Success flashes briefly; failures stay long enough to read.
            let hold: Duration = outcome == .succeeded ? .seconds(2.5) : .seconds(6)
            resetTasks[slot.id] = Task {
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                statuses[slot.id] = .idle
            }
        }
    }

    func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        // Pick up anything the user creates there on the next expand.
        lastLibraryCheck = nil
    }

    /// Re-reads the Shortcuts library at most every 30 seconds.
    func refreshLibraryIfStale() {
        if let lastLibraryCheck, ContinuousClock.now - lastLibraryCheck < .seconds(30) {
            return
        }
        refreshLibrary()
    }

    func refreshLibrary() {
        guard !isCheckingLibrary else { return }
        isCheckingLibrary = true
        Task {
            defer { isCheckingLibrary = false }
            do {
                // One process: names and identifiers together.
                let entries = try await runner.listShortcutsWithIdentifiers()
                let names = entries.map(\.name)
                library = names
                libraryEntries = entries
                availableNames = Set(names.map(Self.normalized))
                lastLibraryCheck = .now
                followRenames(entries)
            } catch {
                AppLog.log("Shortcuts: could not list shortcuts: \(error.localizedDescription)")
            }
        }
    }

    /// Launcher tiles pinned by identifier keep the shortcut's current name.
    private func followRenames(_ entries: [ShortcutInfo]) {
        var changed = false
        for index in launcher.indices {
            guard let id = launcher[index].shortcutID,
                  case .shortcut(let name)? = launcher[index].assignment,
                  let entry = entries.first(where: { $0.identifier == id }),
                  entry.name != name else { continue }
            launcher[index].value = Assignment.shortcut(entry.name).storageValue
            changed = true
        }
        if changed {
            AppLog.log("Shortcuts: a pinned shortcut was renamed; following it")
            saveLauncher()
        }
    }

    // MARK: Launcher grid

    var canAddToLauncher: Bool { launcher.count < Self.maxLauncherItems }

    func launcherStatus(for item: LauncherItem) -> Status {
        if let status = launcherStatuses[item.id], status != .idle { return status }
        switch item.assignment {
        case nil:
            return .unassigned
        case .builtIn:
            return .idle
        case .shortcut(let name):
            if let id = item.shortcutID, libraryEntries.contains(where: { $0.identifier == id }) { return .idle }
            if let availableNames, !availableNames.contains(Self.normalized(name)) { return .missing }
            return .idle
        case .app(let bundleID, let path, _):
            return Self.appURL(bundleID: bundleID, path: path) == nil ? .missing : .idle
        }
    }

    func isPinned(_ assignment: Assignment) -> Bool {
        launcher.contains { $0.assignment == assignment }
    }

    func addToLauncher(_ assignment: Assignment, shortcutID: String? = nil) {
        guard canAddToLauncher, !isPinned(assignment) else { return }
        let identifier = shortcutID ?? {
            if case .shortcut(let name) = assignment {
                return libraryEntries.first { Self.normalized($0.name) == Self.normalized(name) }?.identifier
            }
            return nil
        }()
        launcher.append(LauncherItem(id: UUID(), value: assignment.storageValue, shortcutID: identifier))
        saveLauncher()
    }

    func removeFromLauncher(_ id: UUID) {
        launcher.removeAll { $0.id == id }
        launcherStatuses[id] = nil
        saveLauncher()
    }

    func moveLauncherItem(_ id: UUID, by offset: Int) {
        guard let index = launcher.firstIndex(where: { $0.id == id }), launcher.indices.contains(index + offset) else { return }
        launcher.swapAt(index, index + offset)
        saveLauncher()
    }

    func runLauncher(_ item: LauncherItem) {
        guard launcherStatus(for: item) != .running else { return }
        switch item.assignment {
        case nil:
            return
        case .builtIn(let action):
            performBuiltIn?(action)
        case .app(let bundleID, let path, let name):
            let opened = Self.openApp(bundleID: bundleID, path: path)
            setLauncherStatus(opened ? .succeeded : .failed("“\(name)” couldn’t be found"), for: item.id)
        case .shortcut(let name):
            launcherResetTasks[item.id]?.cancel()
            launcherStatuses[item.id] = .running
            // By identifier when known: survives a rename between list checks.
            let target = item.shortcutID ?? name
            Task {
                let outcome: Status
                do {
                    _ = try await runner.run(target)
                    outcome = .succeeded
                } catch {
                    outcome = .failed(error.localizedDescription)
                    AppLog.log("Shortcuts: a pinned shortcut failed: \(error.localizedDescription)")
                    refreshLibrary()
                }
                setLauncherStatus(outcome, for: item.id)
            }
        }
    }

    private func setLauncherStatus(_ status: Status, for id: UUID) {
        launcherResetTasks[id]?.cancel()
        launcherStatuses[id] = status
        let hold: Duration = status == .succeeded ? .seconds(1.5) : .seconds(6)
        launcherResetTasks[id] = Task {
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            launcherStatuses[id] = .idle
        }
    }

    private func saveLauncher() {
        if let data = try? JSONEncoder().encode(launcher) {
            UserDefaults.standard.set(data, forKey: Self.launcherKey)
        }
    }

    /// Picks an app with an open panel (Applications first). Calls back
    /// with nil when cancelled.
    func chooseApp(_ completion: @escaping @MainActor (Assignment?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        // The notch panel doesn't activate SparkV; the open panel needs it.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return completion(nil) }
                completion(Self.appAssignment(for: url))
            }
        }
    }

    /// Apps running now (regular ones, not SparkV), for the "Add" menus.
    /// Menus rebuild with their views, so the list is read once and kept
    /// until an app launches or quits (NSWorkspace notifications, no polling).
    var runningApps: [Assignment] {
        if let runningAppsCache { return runningAppsCache }
        watchRunningApps()
        let apps = Self.readRunningApps()
        runningAppsCache = apps
        return apps
    }

    private var runningAppsCache: [Assignment]?
    private var runningAppsObservers: [NSObjectProtocol] = []

    /// Registered the first time a menu asks for the list.
    private func watchRunningApps() {
        guard runningAppsObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        runningAppsObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runningAppsCache = nil }
            }
        }
    }

    private static func readRunningApps() -> [Assignment] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> Assignment? in
                guard let url = app.bundleURL, let assignment = Self.appAssignment(for: url),
                      seen.insert(url.path).inserted else { return nil }
                return assignment
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func appAssignment(for url: URL) -> Assignment? {
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        guard !bundleID.isEmpty || FileManager.default.fileExists(atPath: url.path) else { return nil }
        return .app(bundleID: bundleID, path: url.path, name: name)
    }

    /// Where the app is now: its saved path, else wherever its bundle
    /// identifier points (it was moved or updated). Views ask on every
    /// update, so the answer is kept for half a minute per app.
    static func appURL(bundleID: String, path: String) -> URL? {
        let key = "\(bundleID)|\(path)"
        let now = Date()
        if let cached = appURLCache[key], now.timeIntervalSince(cached.date) < appURLCacheLifetime { return cached.url }
        let url = lookUpAppURL(bundleID: bundleID, path: path)
        if appURLCache.count > 128 {
            appURLCache = appURLCache.filter { now.timeIntervalSince($0.value.date) < appURLCacheLifetime }
        }
        appURLCache[key] = (now, url)
        return url
    }

    private static let appURLCacheLifetime: TimeInterval = 30
    private static var appURLCache: [String: (date: Date, url: URL?)] = [:]

    private static func lookUpAppURL(bundleID: String, path: String) -> URL? {
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard !bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    @discardableResult
    static func openApp(bundleID: String, path: String) -> Bool {
        guard let url = appURL(bundleID: bundleID, path: path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { AppLog.log("Shortcuts: couldn't open an app: \(error.localizedDescription)") }
        }
        return true
    }

    /// Shortcuts and the CLI may disagree on Unicode composition ("Laís").
    private static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }
}

/// App icons for launcher tiles, read once per app and kept at 64 px (32 pt
/// on Retina), never in `body`.
@MainActor
enum LauncherIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for assignment: MacroController.Assignment) -> NSImage? {
        guard case .app(let bundleID, let path, _) = assignment else { return nil }
        // The saved path first: no file-system call for an icon already drawn.
        if let cached = cache[path] { return cached }
        guard let url = MacroController.appURL(bundleID: bundleID, path: path) else { return nil }
        if let cached = cache[url.path] { return cached }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        if cache.count >= 128 { cache.removeAll() }
        // Drawn once now, so later uses are a small cached bitmap.
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = NSSize(width: 32, height: 32)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(origin: .zero, size: NSSize(width: 32, height: 32)), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let bitmap = NSImage(size: NSSize(width: 32, height: 32))
            bitmap.addRepresentation(rep)
            cache[url.path] = bitmap
            return bitmap
        }
        cache[url.path] = source
        return source
    }
}
