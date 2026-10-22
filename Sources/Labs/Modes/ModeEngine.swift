import Foundation

/// Time source for the auto-end timer (a fast fake in tests).
struct ModeClock: Sendable {
    var now: @Sendable () -> Date
    var sleep: @Sendable (TimeInterval) async throws -> Void

    static let live = ModeClock(
        now: { Date() },
        sleep: { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    )
}

/// Runs modes: applies a mode's actions in order, remembers what they
/// changed, and puts it all back when the mode ends (Stop, switching to
/// another mode, auto-end, quitting SparkV, or at the next launch after a
/// crash). One failing action never stops the others; failures are
/// collected in `failures` and summed up in `lastError`.
@MainActor
final class ModeEngine: ObservableObject {
    static let shared = ModeEngine(system: LiveModeSystem.shared, store: ModeStore())

    @Published var modes: [SparkMode] {
        didSet {
            guard modes != oldValue else { return }
            saveLibrary()
        }
    }
    @Published private(set) var activeModeID: UUID?
    @Published private(set) var log: [String] = []
    @Published var lastError: String?
    /// Every action that failed in the last activation or restore.
    @Published private(set) var failures: [ModeActionFailure] = []
    @Published private(set) var activeSince: Date?
    /// When auto-end will stop the mode.
    @Published private(set) var endsAt: Date?
    /// True while a mode is being applied or restored.
    @Published private(set) var isBusy = false

    /// Called with "Concentration on · 42 min" while a mode is on (and
    /// whenever that text changes), and with nil when it ends.
    var onActivityText: ((String?) -> Void)?

    let system: ModeSystem
    let store: ModeStore
    private let clock: ModeClock

    private var approvedQuitApps: Set<String>
    private var seededBuiltIns: [UUID]
    private var snapshot: ModeSnapshot?
    private var queue: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastActivityText: String?
    private var didStart = false
    private var shortcutLibrary: (names: [String], at: Date)?

    static let logLimit = 200
    /// How often the band text and the auto-end deadline are checked.
    static let tickInterval: TimeInterval = 30

    init(system: ModeSystem, store: ModeStore, clock: ModeClock = .live) {
        self.system = system
        self.store = store
        self.clock = clock
        let file = store.loadLibrary()
        modes = file.modes
        approvedQuitApps = Set(file.approvedQuitApps)
        seededBuiltIns = file.seededBuiltIns
        if let error = store.lastError { lastError = error }
    }

    var activeMode: SparkMode? {
        activeModeID.flatMap { id in modes.first { $0.id == id } }
    }

    func mode(_ id: UUID) -> SparkMode? { modes.first { $0.id == id } }

    func isBuiltIn(_ id: UUID) -> Bool { ModePresets.isBuiltIn(id) }

    // MARK: Lifecycle

    /// Call once at launch: undoes a mode that was still on when SparkV
    /// quit unexpectedly (its snapshot is still on disk).
    func start() async {
        guard !didStart else { return }
        didStart = true
        await serialized {
            guard let saved = self.store.loadSnapshot() else { return }
            self.record("Restoring what \(saved.modeName) changed before SparkV last quit")
            self.failures = []
            self.snapshot = saved
            await self.restore(saved, reason: "recovery")
            self.lastError = self.failures.isEmpty
                ? "\(saved.modeName) was still on when SparkV quit, so your previous setup was restored."
                : "\(saved.modeName) was still on when SparkV quit. Some settings couldn't be restored: " + self.failureSummary
        }
    }

    /// Call when SparkV is quitting (applicationShouldTerminate): restores
    /// the active mode. If this doesn't finish, the next launch does it.
    func prepareForQuit() async {
        await deactivate()
    }

    // MARK: Activate / deactivate

    func activate(_ id: UUID) async {
        // A crash snapshot still on disk is restored first, never overwritten.
        if !didStart { await start() }
        await serialized {
            guard let mode = self.mode(id) else {
                self.lastError = "That mode no longer exists."
                return
            }
            guard self.activeModeID != id else { return }
            if self.snapshot != nil { await self.performDeactivate(reason: "switching to \(mode.name)") }
            await self.performActivate(mode)
        }
    }

    func deactivate() async {
        await serialized {
            await self.performDeactivate(reason: "stopped")
        }
    }

    func toggle(_ id: UUID) async {
        if !didStart { await start() }
        await serialized {
            if self.activeModeID == id {
                await self.performDeactivate(reason: "stopped")
            } else if let mode = self.mode(id) {
                if self.snapshot != nil { await self.performDeactivate(reason: "switching to \(mode.name)") }
                await self.performActivate(mode)
            } else {
                self.lastError = "That mode no longer exists."
            }
        }
    }

    /// Runs operations one at a time, in the order they were requested.
    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        await task.value
    }

    private func performActivate(_ mode: SparkMode) async {
        isBusy = true
        defer { isBusy = false }
        failures = []
        lastError = nil
        let start = clock.now()
        var snap = ModeSnapshot(mode: mode, startedAt: start)
        // Saved before anything changes, so a crash from here on is undone.
        snapshot = snap
        store.saveSnapshot(snap)
        activeModeID = mode.id
        activeSince = start
        endsAt = snap.endsAt
        record("\(mode.name) on")

        for action in mode.actions {
            do {
                try await apply(action, mode: mode, snapshot: &snap)
            } catch {
                fail(action.title, error)
            }
            snapshot = snap
            store.saveSnapshot(snap)
        }
        snap.isApplying = false
        snapshot = snap
        store.saveSnapshot(snap)

        if !failures.isEmpty {
            lastError = "\(mode.name) is on, but \(failures.count == 1 ? "one step" : "\(failures.count) steps") didn't work: " + failureSummary
        }
        publishActivity()
        startTicker()
    }

    private func performDeactivate(reason: String) async {
        guard let snap = snapshot else { return }
        isBusy = true
        defer { isBusy = false }
        failures = []
        ticker?.cancel()
        ticker = nil
        record("\(snap.modeName) off (\(reason))")
        await restore(snap, reason: reason)
        if !failures.isEmpty {
            lastError = "\(snap.modeName) ended, but some settings couldn't be put back: " + failureSummary
        }
    }

    /// Puts back what the snapshot recorded, newest change first, then
    /// forgets the mode. Session things (music, focus session, Do Not
    /// Disturb, previews) always end; the rest only with restoreOnExit.
    private func restore(_ snap: ModeSnapshot, reason: String) async {
        // Undoing never shows an Automation prompt (see ModeAutomation).
        ModeAutomation.isRestoring = true
        defer { ModeAutomation.isRestoring = false }
        var remaining = snap
        var order = snap.applied.reversed().compactMap(ModeStepKind.init(rawValue:))
        // Anything recorded but missing from the order (older snapshot) last.
        for kind in ModeStepKind.allCases where !order.contains(kind) { order.append(kind) }
        for kind in order {
            await restoreStep(kind, from: &remaining)
            if remaining != snapshot { snapshot = remaining; store.saveSnapshot(remaining) }
        }
        snapshot = nil
        store.clearSnapshot()
        activeModeID = nil
        activeSince = nil
        endsAt = nil
        lastActivityText = nil
        onActivityText?(nil)
    }

    // MARK: Apply

    private func apply(_ action: ModeAction, mode: SparkMode, snapshot snap: inout ModeSnapshot) async throws {
        switch action {
        case .wallpaper(let choice):
            let screens = system.screens()
            guard !screens.isEmpty else { throw ModeSystemError.unavailable("No display found.") }
            snap.noteApplied(.wallpaper)
            for screen in screens where snap.wallpapers[screen.id] == nil {
                if let current = system.wallpaper(screenID: screen.id) { snap.wallpapers[screen.id] = current }
            }
            store.saveSnapshot(snap)
            var errors: [String] = []
            for screen in screens {
                do {
                    let url = try await system.renderWallpaperImage(for: choice, size: screen.pixelSize)
                    try system.setWallpaper(Self.wallpaperState(url, choice: choice, previous: snap.wallpapers[screen.id]), screenID: screen.id)
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            if !errors.isEmpty { throw ModeSystemError.failed(Array(Set(errors)).sorted().joined(separator: " ")) }
            record("Wallpaper: \(choice.title)")

        case .music(let choice):
            guard !choice.url.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ModeSystemError.unavailable("No music link chosen.")
            }
            snap.noteApplied(.music)
            // Marked before starting: a half-opened tab is still closed on restore.
            snap.startedMusic = true
            store.saveSnapshot(snap)
            try await system.startMusic(choice)
            record("Music: \(choice.title)")

        case .volume(let value):
            if snap.volume == nil {
                guard let current = system.outputVolume() else {
                    throw ModeSystemError.unavailable("This output device has no volume control.")
                }
                snap.volume = current
                // Setting a level unmutes the output; ending puts the mute back.
                snap.volumeWasMuted = system.outputMuted()
            }
            snap.noteApplied(.volume)
            store.saveSnapshot(snap)
            try system.setOutputVolume(value)
            record("Volume \(ModeAction.percent(value)) %")

        case .doNotDisturb(let on):
            let pair: (on: String, off: String)
            do {
                pair = try await doNotDisturbPair()
            } catch ModeSystemError.unavailable(let message) where !on {
                // Turning it off without the shortcuts set up isn't worth an error.
                record("Do Not Disturb off skipped (\(message.prefix(60))…)")
                return
            }
            snap.noteApplied(.doNotDisturb)
            if on {
                snap.doNotDisturbOffShortcut = pair.off
                store.saveSnapshot(snap)
                try await system.runShortcut(pair.on)
            } else {
                try await system.runShortcut(pair.off)
            }
            record("Do Not Disturb \(on ? "on" : "off")")

        case .openApps(let apps):
            var errors: [String] = []
            for app in apps where !app.isEmpty {
                do { try await system.openApp(app, activate: true) } catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty { throw ModeSystemError.failed(errors.joined(separator: " ")) }
            if !apps.isEmpty { record("Opened \(apps.map(ModeAppNames.displayName).joined(separator: ", "))") }

        case .hideApps(let identifiers):
            let targets = hideTargets(identifiers)
            snap.noteApplied(.hideApps)
            var hidden: [String] = []
            for app in targets where !app.isHidden && !snap.hiddenApps.contains(app.bundleID) {
                snap.hiddenApps.append(app.bundleID)
                store.saveSnapshot(snap)
                if system.hideApp(bundleID: app.bundleID) {
                    hidden.append(app.name)
                } else {
                    snap.hiddenApps.removeAll { $0 == app.bundleID }
                }
            }
            if !hidden.isEmpty { record("Hid \(hidden.joined(separator: ", "))") }

        case .quitApps(let identifiers):
            let running = system.runningApps()
            snap.noteApplied(.quitApps)
            var errors: [String] = []
            for identifier in identifiers {
                for app in running where app.matches(identifier) && !Self.neverQuit(app.bundleID, own: system.ownBundleID) {
                    if !approvedQuitApps.contains(app.bundleID) {
                        guard await system.confirmQuit(appName: app.name, modeName: mode.name) else {
                            record("Kept \(app.name) open")
                            continue
                        }
                        approvedQuitApps.insert(app.bundleID)
                        saveLibrary()
                    }
                    if system.quitApp(bundleID: app.bundleID) {
                        snap.quitApps.append(ModeQuitRecord(bundleID: app.bundleID, name: app.name, path: app.path))
                        record("Asked \(app.name) to quit")
                    } else {
                        errors.append("\(app.name) didn't quit.")
                    }
                }
            }
            if !errors.isEmpty { throw ModeSystemError.failed(errors.joined(separator: " ")) }

        case .openURLs(let links):
            var errors: [String] = []
            for link in links {
                let trimmed = link.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let url = Self.webURL(trimmed) else {
                    errors.append("“\(trimmed)” isn't a link.")
                    continue
                }
                do { try system.openURL(url) } catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty { throw ModeSystemError.failed(errors.joined(separator: " ")) }

        case .runShortcut(let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw ModeSystemError.unavailable("No shortcut chosen.") }
            try await system.runShortcut(trimmed)
            record("Ran shortcut \(trimmed)")

        case .darkMode(let on):
            let current = system.isDarkMode()
            guard current != on else {
                record("Appearance already \(on ? "dark" : "light")")
                return
            }
            if snap.darkMode == nil, let current { snap.darkMode = current }
            snap.noteApplied(.darkMode)
            store.saveSnapshot(snap)
            try await system.setDarkMode(on)
            record("Appearance \(on ? "dark" : "light")")

        case .pomodoro(let focus, let rest):
            try startFocus(focusMinutes: focus, breakMinutes: rest, snapshot: &snap)

        case .focusSession:
            try startFocus(focusMinutes: nil, breakMinutes: nil, snapshot: &snap)

        case .brightness(let value):
            if snap.brightness == nil {
                guard let current = system.brightness() else {
                    throw ModeSystemError.unavailable("Brightness works on the built-in display only.")
                }
                snap.brightness = current
            }
            snap.noteApplied(.brightness)
            store.saveSnapshot(snap)
            try system.setBrightness(value)
            record("Brightness \(ModeAction.percent(value)) %")

        case .muteNotificationsPreviews(let mute):
            guard let current = system.notificationPreviewsEnabled() else {
                throw ModeSystemError.unavailable("SparkV notification previews aren't available.")
            }
            if snap.previewsWereEnabled == nil { snap.previewsWereEnabled = current }
            snap.noteApplied(.muteNotificationsPreviews)
            store.saveSnapshot(snap)
            try system.setNotificationPreviewsEnabled(!mute)
            record("SparkV previews \(mute ? "muted" : "shown")")
        }
    }

    /// Rendered images are exactly screen-sized, so they fill; a picked
    /// file keeps the scaling the user had.
    static func wallpaperState(_ url: URL, choice: ModeWallpaperChoice, previous: ModeWallpaperState?) -> ModeWallpaperState {
        if case .file = choice {
            return ModeWallpaperState(path: url.path, scaling: previous?.scaling, allowClipping: previous?.allowClipping, fillColorHex: previous?.fillColorHex)
        }
        return ModeWallpaperState(path: url.path, scaling: 3 /* NSImageScaling.scaleProportionallyUpOrDown */, allowClipping: true, fillColorHex: nil)
    }

    private func startFocus(focusMinutes: Int?, breakMinutes: Int?, snapshot snap: inout ModeSnapshot) throws {
        snap.noteApplied(.pomodoro)
        if system.isFocusSessionActive() {
            record("A focus session is already running; left as is")
            return
        }
        if try system.startFocusSession(focusMinutes: focusMinutes, breakMinutes: breakMinutes) {
            snap.startedFocusSession = true
            if let focusMinutes, let breakMinutes {
                record("Pomodoro \(focusMinutes)/\(breakMinutes) started")
            } else {
                record("Focus session started")
            }
        }
    }

    /// The on/off shortcuts, checked against the user's library (cached a minute).
    private func doNotDisturbPair() async throws -> (on: String, off: String) {
        let preferred = system.doNotDisturbShortcuts()
        let names: [String]
        if let cached = shortcutLibrary, clock.now().timeIntervalSince(cached.at) < 60,
           ModeDoNotDisturbNames.resolve(preferred: preferred, library: cached.names) != nil {
            names = cached.names
        } else {
            do {
                names = try await system.shortcutNames()
            } catch {
                throw ModeSystemError.failed("Couldn't read your Shortcuts library (\(error.localizedDescription)).")
            }
            shortcutLibrary = (names, clock.now())
        }
        guard let pair = ModeDoNotDisturbNames.resolve(preferred: preferred, library: names) else {
            throw ModeSystemError.unavailable(ModeDoNotDisturbNames.missingMessage(preferred))
        }
        return pair
    }

    private func hideTargets(_ identifiers: [String]) -> [ModeRunningApp] {
        let own = system.ownBundleID
        let running = system.runningApps().filter { $0.bundleID != own }
        if identifiers.contains(ModeAction.allOtherApps) {
            return running.filter { !$0.isActive }
        }
        return running.filter { app in identifiers.contains { app.matches($0) } }
    }

    private static func neverQuit(_ bundleID: String, own: String) -> Bool {
        bundleID == own || bundleID == "com.apple.finder" || bundleID == "com.apple.loginwindow"
    }

    /// Accepts "https://…", other schemes ("shortcuts://", "notion://"), and bare "example.com".
    static func webURL(_ text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty, scheme.lowercased() != "file" {
            return url
        }
        guard !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil else { return nil }
        return url
    }

    // MARK: Restore

    private func restoreStep(_ kind: ModeStepKind, from snap: inout ModeSnapshot) async {
        let environment = snap.restoreOnExit
        switch kind {
        case .wallpaper:
            guard !snap.wallpapers.isEmpty else { return }
            if environment {
                let connected = Set(system.screens().map(\.id))
                for (screenID, state) in snap.wallpapers.sorted(by: { $0.key < $1.key }) {
                    guard connected.contains(screenID) else { continue }
                    do { try system.setWallpaper(state, screenID: screenID) } catch { fail("Restore Wallpaper", error) }
                }
                record("Wallpaper restored")
            }
            snap.wallpapers = [:]

        case .music:
            guard snap.startedMusic else { return }
            await system.stopMusic()
            snap.startedMusic = false
            record("Music stopped")

        case .volume:
            guard let volume = snap.volume else { return }
            if environment {
                do { try system.setOutputVolume(volume); record("Volume back to \(ModeAction.percent(volume)) %") } catch { fail("Restore Volume", error) }
                if snap.volumeWasMuted == true {
                    do { try system.setOutputMuted(true); record("Sound muted again") } catch { fail("Restore Mute", error) }
                }
            }
            snap.volume = nil
            snap.volumeWasMuted = nil

        case .doNotDisturb:
            guard let off = snap.doNotDisturbOffShortcut else { return }
            do { try await system.runShortcut(off); record("Do Not Disturb off") } catch { fail("Turn Off Do Not Disturb", error) }
            snap.doNotDisturbOffShortcut = nil

        case .hideApps:
            guard !snap.hiddenApps.isEmpty else { return }
            if environment {
                let running = Set(system.runningApps().map(\.bundleID))
                for bundleID in snap.hiddenApps.reversed() where running.contains(bundleID) {
                    _ = system.unhideApp(bundleID: bundleID)
                }
                record("Hidden apps shown again")
            }
            snap.hiddenApps = []

        case .quitApps:
            guard !snap.quitApps.isEmpty else { return }
            if environment {
                let running = Set(system.runningApps().map(\.bundleID))
                for app in snap.quitApps where !running.contains(app.bundleID) {
                    do { try await system.openApp(app.path ?? app.bundleID, activate: false) } catch { fail("Reopen \(app.name)", error) }
                }
                record("Reopened \(snap.quitApps.map(\.name).joined(separator: ", "))")
            }
            snap.quitApps = []

        case .darkMode:
            guard let dark = snap.darkMode else { return }
            if environment, system.isDarkMode() != dark {
                do { try await system.setDarkMode(dark); record("Appearance back to \(dark ? "dark" : "light")") } catch { fail("Restore Appearance", error) }
            }
            snap.darkMode = nil

        case .pomodoro, .focusSession:
            guard snap.startedFocusSession else { return }
            if system.isFocusSessionActive() { system.endFocusSession() }
            snap.startedFocusSession = false
            record("Focus session ended")

        case .brightness:
            guard let level = snap.brightness else { return }
            if environment {
                do { try system.setBrightness(level); record("Brightness back to \(ModeAction.percent(level)) %") } catch { fail("Restore Brightness", error) }
            }
            snap.brightness = nil

        case .muteNotificationsPreviews:
            guard let enabled = snap.previewsWereEnabled else { return }
            do { try system.setNotificationPreviewsEnabled(enabled) } catch { fail("Restore SparkV Previews", error) }
            snap.previewsWereEnabled = nil

        case .openApps, .openURLs, .runShortcut:
            // Opened apps and links stay open; nothing to undo.
            break
        }
    }

    // MARK: Auto-end and the band

    private func startTicker() {
        ticker?.cancel()
        guard snapshot != nil else { return }
        let clock = clock
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let wait: TimeInterval
                if let endsAt = self?.endsAt {
                    wait = max(0, min(Self.tickInterval, endsAt.timeIntervalSince(clock.now())))
                } else {
                    wait = Self.tickInterval
                }
                do { try await clock.sleep(wait) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if await self.checkAutoEnd() { return }
                self.publishActivity()
            }
        }
    }

    /// Ends the mode once its time is up (also catches up after sleep).
    @discardableResult
    func checkAutoEnd() async -> Bool {
        guard let endsAt, clock.now() >= endsAt, let id = activeModeID else { return false }
        await serialized {
            guard self.activeModeID == id, let endsAt = self.endsAt, self.clock.now() >= endsAt else { return }
            await self.performDeactivate(reason: "time's up")
        }
        return true
    }

    /// "Concentration on · 42 min" or "Meeting on · 18 min left".
    func activityText(at date: Date? = nil) -> String? {
        guard let snapshot, let since = activeSince else { return nil }
        let now = date ?? clock.now()
        if let endsAt {
            let left = max(0, Int((endsAt.timeIntervalSince(now) / 60).rounded(.up)))
            return "\(snapshot.modeName) on · \(left) min left"
        }
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        return minutes < 1 ? "\(snapshot.modeName) on" : "\(snapshot.modeName) on · \(Self.duration(minutes))"
    }

    private static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func publishActivity() {
        let text = activityText()
        guard text != lastActivityText else { return }
        lastActivityText = text
        onActivityText?(text)
    }

    // MARK: Editing

    func add(_ mode: SparkMode) {
        var mode = mode
        if modes.contains(where: { $0.id == mode.id }) { mode.id = UUID() }
        modes.append(mode)
    }

    /// Changes apply the next time the mode is turned on.
    func update(_ mode: SparkMode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index] = mode
    }

    /// Deleting the active mode ends it first (the snapshot restores it).
    func delete(_ id: UUID) {
        if activeModeID == id {
            Task { @MainActor in await self.deactivate() }
        }
        modes.removeAll { $0.id == id }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var copy = modes
        let moving = source.sorted().filter { $0 < copy.count }.map { copy[$0] }
        for index in source.sorted(by: >) where index < copy.count { copy.remove(at: index) }
        let before = source.filter { $0 < destination }.count
        let target = min(copy.count, max(0, destination - before))
        copy.insert(contentsOf: moving, at: target)
        modes = copy
    }

    @discardableResult
    func duplicate(_ id: UUID) -> SparkMode? {
        guard let index = modes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = modes[index]
        copy.id = UUID()
        copy.name = Self.copyName(copy.name, existing: Set(modes.map(\.name)))
        modes.insert(copy, at: index + 1)
        return copy
    }

    /// Puts every built-in mode back to how SparkV ships it (re-adding any
    /// that were deleted). The user's own modes are untouched.
    func resetBuiltIns() {
        var copy = modes
        for preset in ModePresets.all {
            if let index = copy.firstIndex(where: { $0.id == preset.id }) {
                copy[index] = preset
            } else {
                copy.append(preset)
            }
        }
        seededBuiltIns = Array(Set(seededBuiltIns).union(ModePresets.ids)).sorted { $0.uuidString < $1.uuidString }
        modes = copy
        saveLibrary()
    }

    /// The editor's "Reset" for one built-in mode.
    func resetBuiltIn(_ id: UUID) {
        guard let preset = ModePresets.builtIn(id) else { return }
        if let index = modes.firstIndex(where: { $0.id == id }) { modes[index] = preset } else { modes.append(preset) }
    }

    /// Lets the user take back "quit without asking" for an app.
    func forgetQuitApproval(_ bundleID: String) {
        approvedQuitApps.remove(bundleID)
        saveLibrary()
    }

    var quitApprovals: [String] { approvedQuitApps.sorted() }

    private static func copyName(_ name: String, existing: Set<String>) -> String {
        var candidate = "\(name) Copy"
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(name) Copy \(n)"
            n += 1
        }
        return candidate
    }

    // MARK: Helpers

    private func saveLibrary() {
        store.saveLibrary(ModeLibraryFile(modes: modes, approvedQuitApps: approvedQuitApps.sorted(), seededBuiltIns: seededBuiltIns))
        if let error = store.lastError { lastError = error }
    }

    private func fail(_ step: String, _ error: Error) {
        let message = error.localizedDescription
        failures.append(ModeActionFailure(step: step, message: message))
        record("\(step) failed: \(message)")
    }

    private var failureSummary: String {
        failures.map(\.text).joined(separator: " ")
    }

    private func record(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        AppLog.log("Modes: \(line.prefix(160))")
    }
}
