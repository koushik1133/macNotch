import AppKit
import SwiftUI

/// Clipboard history for the notch: polls the general pasteboard's change
/// count, records copies (text, rich text, links, images, files) under the
/// privacy rules in `ClipboardPolicy`, keeps the last 30 (plus pins) on
/// disk, and copies or pastes them back.
///
/// Off until the user turns it on (`setEnabled(true)`), so SparkV never
/// reads the clipboard, or trips macOS's "Paste from Other Apps" alert,
/// before the user asked for history. See DESIGN.md.
@MainActor
final class ClipboardController: ObservableObject {
    enum Status: Equatable {
        /// History is turned off (the default).
        case off
        case running
        case paused
        /// macOS is set to ask before each read; allow it in Settings.
        case needsPermission
        /// macOS denies SparkV clipboard access.
        case denied
    }

    /// Newest first (pinned ones wherever their last copy puts them).
    @Published private(set) var items: [ClipboardItem] = []
    /// Image previews, keyed by item id.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var status: Status = .off
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isPaused: Bool
    /// The latest copy was skipped for this reason (e.g. a password), so the
    /// clipboard holds something the history doesn't show. Nil otherwise.
    @Published private(set) var hiddenReason: ClipboardPolicy.SkipReason?
    /// The clipboard changed since the newest history item was recorded and
    /// that copy wasn't recorded (paused, ignored, private, too large…).
    @Published private(set) var hasUnrecordedCopy = false
    /// The next copy will not be recorded.
    @Published private(set) var isIgnoringNextCopy = false
    /// Item that was just copied from the UI (drives the ✓ flash).
    @Published private(set) var flashedItemID: UUID?
    @Published private(set) var excludedBundleIDs: Set<String>
    /// Keep history across restarts (on by default once history is on).
    @Published private(set) var persistsHistory: Bool
    /// Also show the "Copied" band for copies made in other apps.
    @Published private(set) var showsBannerForEveryCopy: Bool
    @Published private(set) var ignoresUniversalClipboard: Bool
    /// ⌘ + digit + V pastes history item N (default on; only acts while
    /// history is on and has N items).
    @Published private(set) var stackChordEnabled: Bool
    /// ⌘⇧V opens the clipboard stack panel (default on).
    @Published private(set) var stackPanelShortcutEnabled: Bool

    /// Set by the lead: opens the drawer on the Clipboard tab ("Show All…").
    var onOpenTab: (() -> Void)?
    /// Posts ⌘V into the frontmost app. Injectable so the test harness never
    /// synthesises keystrokes.
    var pasteKeystroke: @MainActor () async -> ClipboardPaster.Outcome = { await ClipboardPaster.pasteIntoFrontmostApp() }
    /// Same, for the stack: the app the panel opened over, and whether the
    /// user may still hold ⌘ (the ⌘+N+V chord). Injectable for tests.
    var pasteKeystrokeInto: @MainActor (_ target: NSRunningApplication?, _ keepCommand: Bool) async -> ClipboardPaster.Outcome = {
        await ClipboardPaster.pasteIntoFrontmostApp(target: $0, keepCommand: $1)
    }
    /// Opens URLs and reveals files for smart actions. Injectable for tests.
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealPath: @MainActor (String) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
    /// Installs the global ⌘+N+V / ⌘⇧V tap in `start()`. Off by default for
    /// test pasteboards, so a harness never intercepts real keys.
    var installsStackHotkeys: Bool
    /// Asks before something is deleted (Clear, turning persistence off).
    /// Injectable for tests; the app shows an NSAlert.
    var confirm: @MainActor (_ title: String, _ detail: String, _ button: String) -> Bool = ClipboardController.runConfirmAlert

    static let pollInterval: Duration = .milliseconds(500)
    static let activityID = "clipboard.copied"

    private let activities: ActivityCenter
    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    let store: ClipboardDiskStore
    private var history = ClipboardHistory()
    private var policy = ClipboardPolicy()

    private var started = false
    private var pollTask: Task<Void, Never>?
    /// Serialises ingest, copy-back and saving.
    private var chain: Task<Void, Never>?
    private var lastChangeCount = -1
    /// Change count at which `history.latest` was recorded or written back.
    /// When the pasteboard's count differs, the clipboard holds something the
    /// history doesn't (a password, a copy made while paused, before launch…).
    private var syncedChangeCount = -1
    private var appIcons: [String: NSImage] = [:]
    private var appNames: [String: String] = [:]
    private var thumbnailsLoading: Set<UUID> = []
    private var flashTask: Task<Void, Never>?
    let hotkeys = ClipboardHotkeys()
    private var stackPanelController: ClipboardStackPanelController?
    /// Smart content per item, keyed by id (and its fingerprint, so an
    /// edited item is re-detected).
    private var smartCache: [UUID: (fingerprint: String, content: ClipboardSmartContent?)] = [:]

    private enum Key {
        static let enabled = "Clipboard.enabled"
        static let paused = "Clipboard.paused"
        static let excluded = "Clipboard.excludedBundleIDs"
        static let persists = "Clipboard.persistsHistory"
        static let banner = "Clipboard.bannerForEveryCopy"
        static let universal = "Clipboard.ignoreUniversalClipboard"
        static let stackChord = "Clipboard.stackChordEnabled"
        static let stackPanel = "Clipboard.stackPanelShortcutEnabled"
    }

    /// `pasteboard`, `defaults` and `directory` are injectable for tests;
    /// the app uses the defaults.
    init(activities: ActivityCenter,
         pasteboard: NSPasteboard = .general,
         defaults: UserDefaults = .standard,
         directory: URL = ClipboardDiskStore.defaultDirectory) {
        self.activities = activities
        self.pasteboard = pasteboard
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        isPaused = defaults.bool(forKey: Key.paused)
        let persists = defaults.object(forKey: Key.persists) as? Bool ?? true
        persistsHistory = persists
        showsBannerForEveryCopy = defaults.bool(forKey: Key.banner)
        ignoresUniversalClipboard = defaults.bool(forKey: Key.universal)
        excludedBundleIDs = (defaults.array(forKey: Key.excluded) as? [String]).map(Set.init)
            ?? ClipboardPolicy.defaultExcludedBundleIDs
        stackChordEnabled = defaults.object(forKey: Key.stackChord) as? Bool ?? true
        stackPanelShortcutEnabled = defaults.object(forKey: Key.stackPanel) as? Bool ?? true
        installsStackHotkeys = pasteboard.name == NSPasteboard.general.name
        store = ClipboardDiskStore(directory: directory, persistsIndex: persists)
        applyPolicy()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let store = store
        enqueue { [weak self] in
            let loaded = await store.load()
            guard let self else { return }
            self.history = ClipboardHistory(items: loaded)
            self.publish()
            AppLog.log("Clipboard: loaded \(loaded.count) item(s)")
        }
        if isEnabled { beginPolling(readNow: false) } else { status = .off }
        hotkeys.onCommand = { [weak self] command in self?.handleStackCommand(command) }
        // Refreshes `stackShortcutsNeedAccessibility` when the tap appears
        // after an Accessibility grant (or goes away on a revoke).
        hotkeys.onRunningChange = { [weak self] _ in self?.objectWillChange.send() }
        syncHotkeys()
        if installsStackHotkeys, stackChordEnabled || stackPanelShortcutEnabled { hotkeys.start() }
    }

    func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
        hotkeys.stop()
        stackPanelController?.hide()
    }

    // MARK: Settings

    /// Turning history on is the only path to the first clipboard read; call
    /// it from a user action. Reads the current clipboard right away, so a
    /// macOS alert (if any) appears in response to the click.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        AppLog.log("Clipboard: history turned \(enabled ? "on" : "off")")
        if enabled {
            if started { beginPolling(readNow: true) }
        } else {
            pollTask?.cancel()
            pollTask = nil
            status = .off
            hiddenReason = nil
        }
        syncHotkeys()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        defaults.set(paused, forKey: Key.paused)
        if isEnabled, status == .running || status == .paused { status = paused ? .paused : .running }
        AppLog.log("Clipboard: history \(paused ? "paused" : "resumed")")
    }

    /// Skips recording the next copy (e.g. before copying something private).
    func ignoreNextCopy() {
        isIgnoringNextCopy = true
    }

    /// Turning persistence off deletes the saved copy on disk, so it asks first.
    func setPersistsHistory(_ value: Bool) {
        if !value, persistsHistory, !history.items.isEmpty,
           !confirm("Stop keeping clipboard history after restart?",
                    "The saved copy of your history is removed from this Mac now. Current items stay until SparkV quits.",
                    "Remove Saved History") {
            return
        }
        persistsHistory = value
        defaults.set(value, forKey: Key.persists)
        let store = store
        let snapshot = history.items
        enqueue {
            await store.setPersistsIndex(value)
            if value { await store.save(snapshot) }
        }
    }

    func setShowsBannerForEveryCopy(_ value: Bool) {
        showsBannerForEveryCopy = value
        defaults.set(value, forKey: Key.banner)
    }

    func setStackChordEnabled(_ value: Bool) {
        stackChordEnabled = value
        defaults.set(value, forKey: Key.stackChord)
        syncHotkeys()
        updateHotkeyInstallation()
        AppLog.log("Clipboard: ⌘+number+V \(value ? "on" : "off")")
    }

    func setStackPanelShortcutEnabled(_ value: Bool) {
        stackPanelShortcutEnabled = value
        defaults.set(value, forKey: Key.stackPanel)
        syncHotkeys()
        updateHotkeyInstallation()
        AppLog.log("Clipboard: ⌘⇧V stack shortcut \(value ? "on" : "off")")
    }

    /// The tap only exists while one of the shortcuts is on.
    private func updateHotkeyInstallation() {
        guard started, installsStackHotkeys else { return }
        if stackChordEnabled || stackPanelShortcutEnabled { hotkeys.start() } else { hotkeys.stop() }
    }

    /// Tells the tap what it may intercept: nothing while history is off.
    private func syncHotkeys() {
        let count = isEnabled ? history.items.count : 0
        let chord = stackChordEnabled
        let panel = stackPanelShortcutEnabled
        let open = stackPanelController?.isOpen ?? false
        hotkeys.update {
            $0.chordEnabled = chord
            $0.panelShortcutEnabled = panel
            $0.stackCount = count
            $0.panelOpen = open
        }
    }

    func setIgnoresUniversalClipboard(_ value: Bool) {
        ignoresUniversalClipboard = value
        defaults.set(value, forKey: Key.universal)
        applyPolicy()
    }

    func exclude(bundleID: String) {
        excludedBundleIDs.insert(bundleID)
        defaults.set(Array(excludedBundleIDs).sorted(), forKey: Key.excluded)
        applyPolicy()
        AppLog.log("Clipboard: excluding \(bundleID)")
    }

    func include(bundleID: String) {
        excludedBundleIDs.remove(bundleID)
        defaults.set(Array(excludedBundleIDs).sorted(), forKey: Key.excluded)
        applyPolicy()
    }

    /// Exclusions the user added on top of the built-in password managers.
    var userExcludedBundleIDs: [String] {
        excludedBundleIDs.subtracting(ClipboardPolicy.defaultExcludedBundleIDs).sorted()
    }

    /// A stack shortcut is on but its tap isn't running: Accessibility is
    /// missing or stale (an ad hoc rebuild). The tap starts by itself as soon
    /// as PermissionCenter sees the grant; until then the C menu says why.
    var stackShortcutsNeedAccessibility: Bool {
        started && installsStackHotkeys && (stackChordEnabled || stackPanelShortcutEnabled) && !hotkeys.isRunning
    }

    /// From the "Allow Accessibility" button: shows the system prompt the
    /// first time for this build's signature, otherwise opens the
    /// Accessibility pane (PermissionCenter decides; never repeats prompts).
    func openAccessibilitySettings() {
        Task { await PermissionCenter.shared.request(.accessibility, from: "Clipboard stack shortcuts") }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    private func applyPolicy() {
        policy.excludedBundleIDs = excludedBundleIDs
        policy.ignoresRemoteClipboard = ignoresUniversalClipboard
    }

    // MARK: Queries

    /// What's on the clipboard now, as far as the history knows.
    var current: ClipboardItem? { history.latest }
    var pinned: [ClipboardItem] { history.pinned }

    func filtered(query: String, filter: ClipboardFilter) -> [ClipboardItem] {
        history.filtered(query: query, kinds: filter.kinds, pinnedOnly: filter == .pinned)
    }

    func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = appIcons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }

    func appName(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let cached = appNames[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        appNames[bundleID] = name
        return name
    }

    // MARK: Actions

    /// Puts `item` back on the clipboard (all representations, or plain text).
    func copy(_ item: ClipboardItem, plainText: Bool = false) {
        enqueue { [weak self] in
            guard let self, await self.writeBack(item, plainText: plainText) else { return }
            self.flash(item.id)
            self.postBand(for: item, title: "Copied")
        }
    }

    /// Copies `item` with every representation, then pastes it into the
    /// frontmost app with ⌘V (as Maccy does), so rich text, images and files
    /// paste as themselves. Without Accessibility the item is left on the
    /// clipboard with a hint.
    /// `target`: the app to paste into (the stack panel's). `keepCommand`:
    /// the ⌘+N+V chord, where ⌘ may still be down. `bandTitle` overrides
    /// "Pasted" ("Pasted #3").
    func paste(_ item: ClipboardItem, plainText: Bool = false, target: NSRunningApplication? = nil,
               keepCommand: Bool = false, bandTitle: String? = nil) {
        enqueue { [weak self] in
            guard let self, await self.writeBack(item, plainText: plainText) else { return }
            self.flash(item.id)
            let outcome = target == nil && !keepCommand
                ? await self.pasteKeystroke()
                : await self.pasteKeystrokeInto(target, keepCommand)
            switch outcome {
            case .pasted:
                self.postBand(for: item, title: bandTitle ?? "Pasted")
            case .notPasted(let message):
                self.postBand(for: item, title: "Copied", detailOverride: message)
            }
        }
    }

    /// True when the pasteboard still holds `current` (nothing was copied
    /// since it was recorded or written back). Reads only the change count.
    var clipboardMatchesCurrent: Bool {
        current != nil && pasteboard.changeCount == syncedChangeCount
    }

    /// The "C" button's click: pastes the current clipboard item (⌥: only
    /// copies it). When the clipboard holds something the history doesn't
    /// show (a password, a copy made while paused or before history was on),
    /// that is what's current: it's pasted as is, without being read, and
    /// never replaced by an older history item.
    func useCurrent(pasting: Bool) {
        guard isEnabled else {
            onOpenTab?()
            return
        }
        if let item = current, clipboardMatchesCurrent {
            pasting ? paste(item) : copy(item)
            return
        }
        let detail = hiddenReason != nil ? "Private copy (not in history)" : "Clipboard contents"
        guard pasting else {
            postNotice(symbol: "doc.on.clipboard", title: "Already on the clipboard", detail: detail, tint: .green)
            return
        }
        enqueue { [weak self] in
            guard let self else { return }
            switch await self.pasteKeystroke() {
            case .pasted:
                self.postNotice(symbol: "doc.on.clipboard", title: "Pasted", detail: detail, tint: .green)
            case .notPasted(let message):
                self.postNotice(symbol: "doc.on.clipboard", title: "Not pasted", detail: message)
            }
        }
    }

    func togglePin(_ item: ClipboardItem) {
        let result = history.setPinned(id: item.id, !item.isPinned)
        if !result.ok {
            postNotice(symbol: "pin.slash", title: "Pin limit reached", detail: "Unpin something first")
            return
        }
        discard(result.removed)
        publishAndSave()
    }

    func delete(_ item: ClipboardItem) {
        guard let removed = history.remove(id: item.id) else { return }
        discard([removed])
        publishAndSave()
    }

    /// Menu "Clear History": asks first, as Maccy and Raycast do.
    func confirmAndClear(includingPinned: Bool = false) {
        let count = includingPinned ? history.items.count : history.unpinned.count
        guard count > 0 else { return }
        let title = includingPinned ? "Clear all clipboard history, including pinned items?" : "Clear clipboard history?"
        let detail = "\(count) item\(count == 1 ? "" : "s") will be deleted from this Mac."
            + (includingPinned || history.pinned.isEmpty ? "" : " Pinned items are kept.")
        guard confirm(title, detail, "Clear") else { return }
        clear(includingPinned: includingPinned)
    }

    static func runConfirmAlert(title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func clear(includingPinned: Bool = false) {
        let removed = history.clear(keepingPinned: !includingPinned)
        hiddenReason = nil
        let store = store
        let keep = history.items
        if history.items.isEmpty {
            enqueue { await store.removeAll() }
        } else {
            discard(removed)
        }
        publish()
        enqueue { await store.save(keep) }
        AppLog.log("Clipboard: cleared \(removed.count) item(s)\(includingPinned ? " including pins" : "")")
    }

    func revealInFinder(_ item: ClipboardItem) {
        if let urls = item.fileURLs, !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func open(_ item: ClipboardItem) {
        switch item.kind {
        case .url:
            if let text = item.text, let url = ClipboardCapture.webLink(text) { NSWorkspace.shared.open(url) }
        case .file:
            item.fileURLs?.first.map { _ = NSWorkspace.shared.open($0) }
        case .image:
            if let url = store.imageFileURL(for: item) { NSWorkspace.shared.open(url) }
        case .text, .richText:
            break
        }
    }

    /// What dragging a card out carries.
    func dragPayloads(for item: ClipboardItem) -> [TrayDragPayload] {
        let image = ClipboardDragImage.make(for: item, thumbnail: thumbnails[item.id], controller: self)
        switch item.kind {
        case .text, .richText:
            return [TrayDragPayload(writer: (item.text ?? "") as NSString, image: image)]
        case .url:
            guard let text = item.text, let url = ClipboardCapture.webLink(text) else {
                return [TrayDragPayload(writer: (item.text ?? "") as NSString, image: image)]
            }
            return [TrayDragPayload(writer: url as NSURL, image: image)]
        case .image:
            guard let url = store.imageFileURL(for: item), FileManager.default.fileExists(atPath: url.path) else { return [] }
            return [TrayDragPayload(writer: url as NSURL, image: image)]
        case .file:
            return (item.fileURLs ?? [])
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { url in
                    TrayDragPayload(writer: url as NSURL, image: ClipboardDragImage.fileIcon(url))
                }
        }
    }

    // MARK: Stack

    /// The stack, newest first: item 1 is the most recent copy.
    var stackItems: [ClipboardItem] { history.items }

    /// The clipboard stack panel (⌘⇧V), created on first use.
    var stackPanel: ClipboardStackPanelController {
        if let stackPanelController { return stackPanelController }
        let panel = ClipboardStackPanelController(clipboard: self)
        panel.onOpenChange = { [weak self] _ in self?.syncHotkeys() }
        stackPanelController = panel
        return panel
    }

    var isStackPanelOpen: Bool { stackPanelController?.isOpen ?? false }

    /// Opens the stack panel at the text caret (from the C menu, a hotkey…).
    func showStackPanel() {
        guard isEnabled else {
            onOpenTab?()
            return
        }
        stackPanel.show()
    }

    func toggleStackPanel() {
        guard isEnabled else {
            onOpenTab?()
            return
        }
        stackPanel.toggle()
    }

    /// ⌘ + N + V: pastes item N of the stack (1 = newest) into the
    /// frontmost app. False when there is no such item.
    @discardableResult
    func pasteStackItem(number: Int) -> Bool {
        guard isEnabled, number >= 1, history.items.indices.contains(number - 1) else { return false }
        let item = history.items[number - 1]
        AppLog.log("Clipboard: ⌘+\(number)+V pastes stack item \(number)")
        paste(item, keepCommand: true, bandTitle: "Pasted #\(number)")
        return true
    }

    private func handleStackCommand(_ command: ClipboardChordMachine.Command) {
        switch command {
        case .paste(let number):
            if !pasteStackItem(number: number) {
                postNotice(symbol: "number", title: "Nothing at #\(number)", detail: "The stack has \(history.items.count) item(s)")
            }
        case .openPanel:
            toggleStackPanel()
        }
    }

    // MARK: Smart content

    /// What the item is (link, email, phone, colour, path, code), cached.
    func smartContent(for item: ClipboardItem) -> ClipboardSmartContent? {
        if let cached = smartCache[item.id], cached.fingerprint == item.fingerprint { return cached.content }
        let content = ClipboardContentDetector.detect(item)
        smartCache[item.id] = (item.fingerprint, content)
        return content
    }

    func smartActions(for item: ClipboardItem) -> [ClipboardSmartAction] {
        smartContent(for: item).map(ClipboardContentDetector.actions(for:)) ?? []
    }

    /// Runs a smart action: opens the link / mail / FaceTime URL, reveals
    /// the path, or copies the colour in another format (a new copy, so it
    /// joins the history as item 1).
    func perform(_ action: ClipboardSmartAction, for item: ClipboardItem) {
        switch action.kind {
        case .open(let url):
            openURL(url)
            AppLog.log("Clipboard: \(action.title) (\(url.scheme ?? "link"))")
        case .reveal(let path):
            revealPath(path)
        case .copyText(let text):
            copyText(text)
            postNotice(symbol: "eyedropper", title: "Copied", detail: text, tint: .green)
        }
    }

    /// Puts plain text on the clipboard as an ordinary copy (recorded by the
    /// history like any other copy).
    func copyText(_ text: String) {
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setString(text, forType: .string)
        if let bundleID = Bundle.main.bundleIdentifier {
            entry.setString(bundleID, forType: NSPasteboard.PasteboardType(ClipboardPolicy.sourceType))
        }
        pasteboard.writeObjects([entry])
    }

    // MARK: Polling

    private func beginPolling(readNow: Bool) {
        pollTask?.cancel()
        // Like Maccy: what was on the clipboard before launch isn't recorded,
        // unless the user just turned history on.
        lastChangeCount = readNow ? -1 : pasteboard.changeCount
        status = isPaused ? .paused : .running
        if !readNow {
            // Still reflect a denied/ask state without reading anything.
            updateStatus(for: ClipboardAccess.of(pasteboard))
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: ClipboardController.pollInterval, tolerance: .milliseconds(100))
            }
        }
    }

    private func poll() {
        guard isEnabled else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        handleChange()
    }

    private func handleChange() {
        if isPaused {
            status = .paused
            hasUnrecordedCopy = true
            return
        }
        if isIgnoringNextCopy {
            isIgnoringNextCopy = false
            hasUnrecordedCopy = true
            AppLog.log("Clipboard: ignored one copy on request")
            return
        }
        let access = ClipboardAccess.of(pasteboard)
        updateStatus(for: access)
        guard access.permitsAutomaticRead else {
            hasUnrecordedCopy = true
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        switch ClipboardReader.read(pasteboard, policy: policy, frontmostBundleID: frontmost) {
        case .skipped(let reason):
            // Our own write-back is already the newest item.
            if reason != .ownWrite { hasUnrecordedCopy = true }
            switch reason {
            case .concealed, .ignoredType, .excludedApp:
                // The clipboard now holds a secret; the C button says so
                // instead of showing an older item as "current".
                hiddenReason = reason
                AppLog.log("Clipboard: skipped a copy (\(reason.rawValue))")
            case .transient, .autoGenerated, .ownWrite, .remoteClipboard, .empty, .tooLarge:
                if reason == .tooLarge { AppLog.log("Clipboard: skipped an oversized copy") }
            }
        case .capture(let capture):
            hiddenReason = nil
            ingest(capture)
        }
    }

    private func updateStatus(for access: ClipboardAccess) {
        guard isEnabled else { status = .off; return }
        switch access {
        case .allowed, .firstUse: status = isPaused ? .paused : .running
        case .ask: status = .needsPermission
        case .denied: status = .denied
        }
    }

    private func ingest(_ capture: ClipboardCapture) {
        let store = store
        enqueue { [weak self] in
            guard let item = await store.ingest(capture) else { return }
            guard let self else { return }
            guard self.isEnabled else {
                await store.discard([item])
                return
            }
            let removed = self.history.insert(item)
            if self.history.latest?.id == item.id, self.pasteboard.changeCount == capture.changeCount {
                self.syncedChangeCount = capture.changeCount
                self.hasUnrecordedCopy = false
            }
            self.discard(removed)
            self.publishAndSave()
            if item.kind == .image, item.recognizedText == nil { self.recognizeText(in: item) }
            if self.showsBannerForEveryCopy, let latest = self.history.latest {
                self.postBand(for: latest, title: "Copied")
            }
        }
    }

    // MARK: Writing back

    /// Writes `item` to the pasteboard and moves it to the top without the
    /// poller re-reading it. False when there was nothing to write.
    private func writeBack(_ item: ClipboardItem, plainText: Bool) async -> Bool {
        if item.kind == .file,
           !(item.fileURLs ?? []).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            postNotice(symbol: "questionmark.folder", title: "File not found", detail: item.displayTitle)
            return false
        }
        let payload = await store.payload(for: item)
        if item.kind == .image, payload.data.isEmpty {
            postNotice(symbol: "photo", title: "Image no longer stored", detail: item.displayTitle)
            return false
        }
        let count = ClipboardWriter.write(payload, to: pasteboard, plainTextOnly: plainText)
        lastChangeCount = count
        hiddenReason = nil
        history.bump(id: item.id)
        if history.latest?.id == item.id {
            syncedChangeCount = count
            hasUnrecordedCopy = false
        }
        publishAndSave()
        return true
    }

    // MARK: Plumbing

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func publish() {
        items = history.items
        let live = Set(items.map(\.id))
        smartCache = smartCache.filter { live.contains($0.key) }
        syncHotkeys()
        thumbnails = thumbnails.filter { live.contains($0.key) }
        thumbnailsLoading.formIntersection(live)
        items.forEach(loadThumbnailIfNeeded)
    }

    private func publishAndSave() {
        publish()
        let store = store
        let snapshot = history.items
        enqueue { await store.save(snapshot) }
    }

    private func discard(_ removed: [ClipboardItem]) {
        guard !removed.isEmpty else { return }
        let store = store
        enqueue { await store.discard(removed) }
    }

    /// Reads the text in a copied image on this Mac (Vision) so the search
    /// field finds screenshots by their words, as Raycast does. Runs beside
    /// the ingest queue, so a slow recognition never delays later copies.
    private func recognizeText(in item: ClipboardItem) {
        guard let url = store.imageFileURL(for: item) else { return }
        let width = item.pixelWidth ?? 0
        let height = item.pixelHeight ?? 0
        let id = item.id
        Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .utility) {
                ClipboardDiskStore.recognizeText(at: url, pixelWidth: width, pixelHeight: height)
            }.value
            guard let self, let text, self.history.setRecognizedText(id: id, text) else { return }
            self.publishAndSave()
        }
    }

    private func loadThumbnailIfNeeded(_ item: ClipboardItem) {
        guard item.thumbnailBlob != nil, thumbnails[item.id] == nil, !thumbnailsLoading.contains(item.id) else { return }
        thumbnailsLoading.insert(item.id)
        let store = store
        let id = item.id
        Task { @MainActor [weak self] in
            let data = await Task.detached(priority: .userInitiated) { store.thumbnailData(for: item) }.value
            guard let self, self.thumbnailsLoading.remove(id) != nil else { return }
            if let data, let image = NSImage(data: data) { self.thumbnails[id] = image }
        }
    }

    private func flash(_ id: UUID) {
        flashedItemID = id
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flashedItemID = nil
        }
    }

    private func postBand(for item: ClipboardItem, title: String, detailOverride: String? = nil) {
        let detail = detailOverride ?? Self.bandDetail(for: item)
        let thumbnail = item.kind == .image ? thumbnails[item.id] : nil
        let symbol = Self.symbol(for: item.kind)
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 40, duration: 1.8) {
            ClipboardActivityView(symbol: symbol, title: title, detail: detail, thumbnail: thumbnail)
        })
    }

    private func postNotice(symbol: String, title: String, detail: String, tint: Color = .orange) {
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 40, duration: 2.2) {
            ClipboardActivityView(symbol: symbol, title: title, detail: detail, thumbnail: nil, tint: tint)
        })
    }

    static func bandDetail(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text, .richText:
            let flat = (item.text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            return String(flat.trimmingCharacters(in: .whitespaces).prefix(80))
        case .url: return item.text ?? item.displayTitle
        case .image, .file: return item.displayTitle
        }
    }

    static func symbol(for kind: ClipboardItem.Kind) -> String {
        switch kind {
        case .text: "doc.plaintext"
        case .richText: "doc.richtext"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

/// Kind filter for the Clipboard tab.
enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all, text, links, images, files, pinned

    var id: String { rawValue }

    var kinds: Set<ClipboardItem.Kind>? {
        switch self {
        case .all, .pinned: nil
        case .text: [.text, .richText]
        case .links: [.url]
        case .images: [.image]
        case .files: [.file]
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .text: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .files: "doc"
        case .pinned: "pin"
        }
    }

    var help: String {
        switch self {
        case .all: "Everything"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        case .pinned: "Pinned"
        }
    }
}
