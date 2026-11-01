import AppKit
import Combine
import SwiftUI

/// Quick capture to Spaces: one global hotkey (default ⌃⌥C) grabs the
/// current context and files it into the right Space at once.
///
/// What it grabs, in order: the text selected in the front app (read through
/// Accessibility, never with a synthetic ⌘C), else the front browser tab,
/// else an interactive screenshot (OCR'd on device). The item goes through
/// `SpaceStore.ingest`, so the Space agents route it; when they aren't sure,
/// the store's own filing suggestion (or the last-used Space, if the user
/// picked that) is applied. The band under the notch says where it went and
/// a small action strip below it offers Change Space, Open and Undo — the
/// "act first, offer undo" pattern of Gmail's Undo Send and CleanShot's
/// quick-access overlay rather than a destination picker before saving.
@MainActor
final class QuickCaptureController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case readingSelection
        case savingPage
        case screenshot
        case filing
    }

    @Published private(set) var phase: Phase = .idle
    /// The capture the action strip refers to (nil once dismissed).
    @Published private(set) var lastRecord: QuickCaptureRecord?
    /// Set when macOS refused the shortcut (another app owns it).
    @Published private(set) var hotkeyProblem: String?
    @Published private(set) var lastProblem: String?

    let settings: QuickCaptureSettings
    let store: SpaceStore
    let activities: ActivityCenter

    static let activityID = "quickcapture"
    /// How long the band and the action strip stay (hovering the strip pauses it).
    static let toastDuration: TimeInterval = 6

    /// Seams for tests: the Apple Events read of the front tab and the page download.
    var tabReader: (SpaceConnectors.Browser, _ askUser: Bool) async -> Result<SpaceConnectors.BrowserTab, QuickCaptureError> = { browser, askUser in
        await QuickCaptureController.readTab(browser, askUser: askUser)
    }
    var pageFetcher: (URL) async -> TrayAIWebPage? = { url in try? await TrayAIWeb.fetch(url) }
    /// Seam for tests: no floating strip in headless runs.
    var showsActionStrip = true
    /// Seam for tests: the Screen Recording request. PermissionCenter shows
    /// the system prompt at most once per code signature, then Settings.
    var requestScreenPermission: () -> Void = { ScreenRegionCapture.requestPermission(from: "Quick Capture") }

    private let hotkey = ScreenRegionHotkey()
    private var isRunning = false
    private var cancellables: Set<AnyCancellable> = []
    private lazy var toast = QuickCaptureToastController(controller: self)
    private var requestedScreenPermission = false

    init(store: SpaceStore? = nil, activities: ActivityCenter, settings: QuickCaptureSettings? = nil) {
        self.store = store ?? .shared
        self.activities = activities
        self.settings = settings ?? QuickCaptureSettings()
        hotkey.onPress = { [weak self] in self?.captureNow() }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        settings.$isEnabled.combineLatest(settings.$shortcut)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateHotkey() }
            .store(in: &cancellables)
        updateHotkey()
        prewarmVisionIfNeeded()
    }

    /// Vision's accurate text recognizer loads its models on first use in a
    /// process, which took 90 s and more on a busy Mac in testing (0.2 s once
    /// warm). Load it once in the background, a while after launch, so the
    /// first screenshot capture files in about a second.
    private static var didPrewarm = false
    var prewarmDelay: Duration = .seconds(45)

    private func prewarmVisionIfNeeded() {
        guard !Self.didPrewarm, settings.isEnabled, settings.capturesScreenshot else { return }
        Self.didPrewarm = true
        let delay = prewarmDelay
        Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            guard let image = QuickCaptureController.prewarmImage() else { return }
            let start = Date()
            _ = TrayAIOCR.analyzeSync(image)
            AppLog.log("Quick Capture: OCR ready (\(Int(Date().timeIntervalSince(start))) s)")
        }
    }

    nonisolated static func prewarmImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 8, y: 8, width: 4, height: 16))
        return context.makeImage()
    }

    func stop() {
        isRunning = false
        cancellables.removeAll()
        hotkey.unregister()
        toast.hide()
    }

    /// True while the settings recorder listens, so pressing the current
    /// shortcut records it instead of capturing.
    private var isHotkeySuspended = false

    func setHotkeySuspended(_ suspended: Bool) {
        isHotkeySuspended = suspended
        updateHotkey()
    }

    private func updateHotkey() {
        guard isRunning, settings.isEnabled, !isHotkeySuspended else {
            hotkey.unregister()
            hotkeyProblem = nil
            return
        }
        if hotkey.shortcut == settings.shortcut, hotkey.isRegistered { return }
        if hotkey.register(settings.shortcut) {
            hotkeyProblem = nil
        } else {
            hotkeyProblem = "\(settings.shortcut.displayString) is used by another app"
        }
    }

    /// Changes the shortcut (from the settings recorder). False when invalid.
    @discardableResult
    func setShortcut(_ shortcut: ScreenRegionShortcut) -> Bool {
        guard shortcut.isValidGlobal else { return false }
        isHotkeySuspended = false
        settings.shortcut = shortcut
        updateHotkey()
        return hotkeyProblem == nil
    }

    var isBusy: Bool { phase != .idle }

    // MARK: - Capture

    /// Hotkey / menu entry point.
    func captureNow() {
        guard !isBusy else { return }
        Task { await capture() }
    }

    /// Captures and files. Returns the record (nil when nothing was saved).
    @discardableResult
    func capture() async -> QuickCaptureRecord? {
        guard !isBusy else { return nil }
        lastProblem = nil
        phase = .readingSelection
        defer { phase = .idle }

        let snapshot = settings.snapshot
        let focus = snapshot.capturesSelection ? await QuickCaptureSelectionReader.read() : await Self.frontAppOnly()
        if focus.isSecure {
            AppLog.log("Quick Capture: focused field is a password field; skipping the selection")
        }
        let ownID = Bundle.main.bundleIdentifier
        let frontID = focus.appBundleID == ownID ? nil : focus.appBundleID
        let plan = QuickCapturePlanner.plan(selection: focus.isSecure ? nil : focus.selectedText,
                                            frontBundleID: frontID, settings: snapshot)
        switch plan {
        case .selection(let text):
            AppLog.log("Quick Capture: selection (\(text.count) chars) from \(frontID ?? "?")")
            var page: SpaceConnectors.BrowserTab?
            if settings.selectionIncludesPage, let front = frontID,
               let browser = SpaceConnectors.Browser.all.first(where: { $0.bundleID == front }) {
                // Only when Automation is already allowed: never prompts for a selection.
                if case .success(let tab) = await tabReader(browser, false) { page = tab }
            }
            let input = QuickCapturePlanner.selectionInput(
                text, appBundleID: frontID, appName: focus.appName, windowTitle: focus.windowTitle, page: page
            )
            return await file(input, kind: .selection)

        case .webPage(let browser):
            phase = .savingPage
            switch await tabReader(browser, true) {
            case .failure(let error):
                return problem(error.message)
            case .success(let tab):
                AppLog.log("Quick Capture: web page from \(browser.name)")
                if tab.url.isFileURL {
                    guard let input = await SpaceConnectors.fileInput(tab.url, source: .web) else {
                        return problem("Couldn't read that file")
                    }
                    return await file(input, kind: .webPage)
                }
                postBand(headline: "Saving page…", detail: tab.title.isEmpty ? (SpaceConnectors.domain(of: tab.url) ?? "") : tab.title,
                         color: .white, icon: "safari", duration: 30)
                let page = await pageFetcher(tab.url)
                return await file(SpaceConnectors.webInput(tab: tab, page: page), kind: .webPage)
            }

        case .screenshot:
            phase = .screenshot
            let hints = Self.appHints(bundleID: frontID, name: focus.appName)
            switch await QuickCaptureScreenshot.capture() {
            case .cancelled:
                AppLog.log("Quick Capture: screenshot cancelled")
                return nil
            case .needsPermission:
                if ScreenRegionCapture.needsRelaunch {
                    return problem("Restart SparkV so Screen Recording takes effect")
                }
                // The hotkey is the user action; asks (or opens Settings) at
                // most once per launch, never on its own.
                if !requestedScreenPermission {
                    requestedScreenPermission = true
                    requestScreenPermission()
                }
                return problem("Allow Screen Recording for SparkV, then press \(settings.shortcut.displayString) again")
            case .failed(let reason):
                return problem(reason)
            case .captured(let url):
                defer { QuickCaptureScreenshot.discard(url) }
                phase = .filing
                // OCR can take a few seconds (longer the first time Vision loads).
                postBand(headline: "Reading screenshot…", detail: "filing to Spaces", color: .white,
                         icon: "text.viewfinder", duration: 90)
                guard var input = await SpaceConnectors.imageInput(
                    at: url, kind: .screenshot, source: .screenshots, createdAt: Date(), hints: hints
                ) else { return problem("Couldn't read the screenshot") }
                // Vision occasionally returns nothing while its models are still
                // loading; one retry is cheap once they are (≈0.2 s).
                let baseName = url.deletingPathExtension().lastPathComponent
                if input.text == baseName, let again = await SpaceConnectors.imageInput(
                    at: url, kind: .screenshot, source: .screenshots, createdAt: input.createdAt, hints: hints
                ), again.text != baseName {
                    input = again
                }
                // The store copies the attachment, so the temp file can go afterwards.
                return await file(input, kind: .screenshot)
            }

        case .nothing:
            return problem(focus.isSecure ? "Nothing to capture in a password field" : "Turn on a capture source in Quick Capture settings")
        }
    }

    /// Files `input` and announces it. Internal for the tests.
    func file(_ input: SpaceIngestInput, kind: QuickCaptureKind) async -> QuickCaptureRecord? {
        phase = .filing
        let existing = input.sourceKey.isEmpty ? nil : store.items.first { $0.sourceKey == input.sourceKey }
        guard let item = await store.ingest(input) else {
            postBand(headline: "Nothing new to save", detail: input.title, color: .gray, icon: "checkmark.circle", duration: 2.5)
            return nil
        }
        var filedBy = item.spaceID == nil ? "inbox" : "auto"
        var spaceID = item.spaceID
        if let existing {
            // Already in Spaces: keep the user's filing, just confirm it.
            filedBy = "existing"
            spaceID = existing.spaceID ?? item.spaceID
        } else if item.spaceID == nil,
                  let target = QuickCapturePlanner.fallbackSpace(
                    for: item.id, suggestions: store.suggestions, spaces: store.spaces,
                    fallback: settings.fallback, lastUsed: settings.lastUsedSpaceID) {
            if let suggestion = target.suggestion {
                store.accept(suggestion)
                filedBy = "suggested"
            } else {
                store.move(itemID: item.id, to: target.spaceID)
                filedBy = "last used"
            }
            spaceID = store.item(item.id)?.spaceID ?? target.spaceID
        }
        if let spaceID { settings.lastUsedSpaceID = spaceID }
        let record = QuickCaptureRecord(
            itemID: item.id, kind: kind, title: item.title, spaceID: spaceID, createdItem: existing == nil,
            previousSpaceID: existing?.spaceID, filedBy: filedBy, date: Date()
        )
        lastRecord = record
        announce(record, headline: existing == nil ? nil : "Already in \(spaceName(spaceID))")
        AppLog.log("Quick Capture: \(kind.rawValue) → \(spaceID == nil ? "Inbox" : "Space") (\(filedBy))")
        return record
    }

    // MARK: - Undo / Change Space

    /// Removes the capture (or puts an existing item back where it was).
    func undo() {
        guard let record = lastRecord else { return }
        if record.createdItem {
            store.delete(itemID: record.itemID)
        } else if store.item(record.itemID)?.spaceID != record.previousSpaceID {
            store.move(itemID: record.itemID, to: record.previousSpaceID)
        }
        lastRecord = nil
        toast.hide()
        postBand(headline: "Capture undone", detail: record.title, color: .gray, icon: "arrow.uturn.backward", duration: 2.5)
        AppLog.log("Quick Capture: undone")
    }

    /// Re-files the last capture (nil = Inbox). The agents learn from it.
    func changeSpace(to spaceID: UUID?) {
        guard var record = lastRecord, store.item(record.itemID) != nil else { return }
        store.move(itemID: record.itemID, to: spaceID)
        record.spaceID = spaceID
        record.filedBy = "you"
        lastRecord = record
        if let spaceID { settings.lastUsedSpaceID = spaceID }
        announce(record, headline: spaceID == nil ? "Moved to Inbox" : "Moved to \(spaceName(spaceID))")
    }

    func openLastCapture() {
        let spaceID = lastRecord?.spaceID
        dismissToast()
        SpacesWindowController.shared.show(spaceID: spaceID)
    }

    func dismissToast() {
        toast.hide()
        activities.dismiss(id: Self.activityID)
    }

    /// Spaces for the Change Space menu: depth-first with indentation levels.
    func spaceMenuEntries() -> [(space: Space, depth: Int)] {
        var result: [(Space, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for space in store.children(of: parent) {
                result.append((space, depth))
                if depth < 4 { walk(space.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return result
    }

    func spaceName(_ id: UUID?) -> String {
        guard let id else { return "Inbox" }
        return store.space(id)?.name ?? "Space"
    }

    // MARK: - Band

    private func announce(_ record: QuickCaptureRecord, headline: String?) {
        let space = record.spaceID.flatMap { store.space($0) }
        let title = headline ?? (space.map { "Saved to \($0.name)" } ?? "Saved to Inbox")
        postBand(headline: title, detail: record.kind.label,
                 color: space.map { SpaceIngestCenter.color(hex: $0.color) } ?? .white,
                 icon: space?.icon ?? "tray.and.arrow.down.fill", duration: Self.toastDuration)
        if showsActionStrip { toast.show(record) }
    }

    /// Re-posts the band so it lives as long as a hovered action strip.
    func extendBand() {
        guard let record = lastRecord else { return }
        let space = record.spaceID.flatMap { store.space($0) }
        postBand(headline: space.map { "Saved to \($0.name)" } ?? "Saved to Inbox", detail: record.kind.label,
                 color: space.map { SpaceIngestCenter.color(hex: $0.color) } ?? .white,
                 icon: space?.icon ?? "tray.and.arrow.down.fill", duration: Self.toastDuration)
    }

    private func postBand(headline: String, detail: String, color: Color, icon: String, duration: TimeInterval) {
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 46, duration: duration) {
            SpaceFiledActivityView(headline: headline, detail: detail, color: color, icon: icon)
        })
    }

    private func problem(_ message: String) -> QuickCaptureRecord? {
        lastProblem = message
        AppLog.log("Quick Capture: \(message)")
        postBand(headline: "Couldn't capture", detail: message, color: SparkVTheme.warning, icon: "exclamationmark.triangle.fill", duration: 4)
        return nil
    }

    // MARK: - Helpers

    private static func frontAppOnly() async -> QuickCaptureFocus {
        let app = NSWorkspace.shared.frontmostApplication
        return QuickCaptureFocus(appBundleID: app?.bundleIdentifier, appName: app?.localizedName)
    }

    static func appHints(bundleID: String?, name: String?) -> [String: String] {
        var hints: [String: String] = ["capture": "screenshot"]
        if let bundleID { hints["app"] = bundleID }
        if let name, bundleID != nil { hints["appName"] = name }
        return hints
    }

    /// Browsers whose Automation pane was already opened this launch (so a
    /// repeated hotkey doesn't open System Settings every time).
    private static var openedAutomationSettings: Set<String> = []

    /// Reads the front tab over Apple Events (same script and checks Spaces
    /// uses). The check never prompts; with `askUser` (the capture hotkey)
    /// the consent alert goes through PermissionCenter's queue, and a denied
    /// browser opens Settings › Automation once per launch.
    static func readTab(_ browser: SpaceConnectors.Browser, askUser: Bool) async -> Result<SpaceConnectors.BrowserTab, QuickCaptureError> {
        let center = PermissionCenter.shared
        let permission = PermissionCenter.Permission.automation(bundleID: browser.bundleID)
        let notAllowed = "Allow SparkV to control \(browser.name) in System Settings › Privacy & Security › Automation"
        var status = await center.freshStatus(permission)
        if askUser, status == .notDetermined {
            status = await center.request(permission, from: "Quick Capture")
        }
        switch status {
        case .granted: break
        case .denied, .restricted:
            if askUser, !openedAutomationSettings.contains(browser.bundleID) {
                openedAutomationSettings.insert(browser.bundleID)
                center.openSettings(permission, from: "Quick Capture")
            }
            return .failure(.init(notAllowed))
        case .notDetermined, .limited: return .failure(.init("SparkV needs permission to read \(browser.name)"))
        case .appNotRunning, .appNotInstalled: return .failure(.init("\(browser.name) isn't running"))
        case .unknown: if !askUser { return .failure(.init("No access")) }
        }
        switch await SpaceAppleEvents.shared.run(browser.tabScript, timeout: askUser ? 7 : 3) {
        case .failure(let failure):
            switch failure {
            case .notRunning: return .failure(.init("\(browser.name) isn't running"))
            case .notPermitted: return .failure(.init("Allow SparkV to control \(browser.name) in System Settings › Privacy & Security › Automation"))
            case .timedOut: return .failure(.init("\(browser.name) didn't answer in time"))
            case .script(let code, let message): return .failure(.init(message.isEmpty ? "\(browser.name) returned error \(code)" : "\(browser.name): \(message)"))
            }
        case .success(let output):
            switch SpaceConnectors.parseBrowserOutput(output, browser: browser.name) {
            case .privateWindow: return .failure(.init("Private windows aren't saved"))
            case .nothing: return .failure(.init("No page open in \(browser.name)"))
            case .tab(let tab): return .success(tab)
            }
        }
    }
}

struct QuickCaptureError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
