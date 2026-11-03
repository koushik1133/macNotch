import AppKit
import ApplicationServices
import Foundation

// MARK: - Pure accumulator

/// Time per app and per window/document while focusing. A "segment" is the
/// stretch since the last switch; closing it credits its seconds.
struct FocusUsageSnapshot: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var bundleID: String
        var appName: String
        var title: String?
        var since: Date
    }

    var apps: [String: FocusAppUsage] = [:]
    var documents: [String: FocusDocumentUsage] = [:]
    /// Nil while not counting (break, pause, ignored app).
    var current: Segment?

    /// Segments shorter than this (alt-tab flicker) still count, but a
    /// window title needs this long before it's listed as a document.
    static let documentMinimum: TimeInterval = 20

    mutating func switchTo(bundleID: String, appName: String, title: String?, at date: Date) {
        if let c = current, c.bundleID == bundleID, c.title == title { return }
        close(at: date)
        current = Segment(bundleID: bundleID, appName: appName, title: title, since: date)
    }

    /// Stops counting until the next `switchTo`.
    mutating func pause(at date: Date) {
        close(at: date)
        current = nil
    }

    /// Credits the open segment up to `date` and keeps it open from there.
    mutating func checkpoint(at date: Date) {
        guard let c = current else { return }
        close(at: date)
        current = Segment(bundleID: c.bundleID, appName: c.appName, title: c.title, since: date)
    }

    private mutating func close(at date: Date) {
        guard let c = current else { return }
        let seconds = max(0, date.timeIntervalSince(c.since))
        guard seconds > 0 else { return }
        apps[c.bundleID, default: FocusAppUsage(bundleID: c.bundleID, name: c.appName, seconds: 0)].seconds += seconds
        if let title = c.title, !title.isEmpty {
            let key = c.appName + "\u{1F}" + title
            documents[key, default: FocusDocumentUsage(title: title, appName: c.appName, seconds: 0)].seconds += seconds
        }
    }

    /// Apps by time, most first; anything under 5 s is dropped.
    func topApps(limit: Int = 8) -> [FocusAppUsage] {
        Array(apps.values.filter { $0.seconds >= 5 }.sorted { $0.seconds > $1.seconds }.prefix(limit))
    }

    func topDocuments(limit: Int = 8) -> [FocusDocumentUsage] {
        Array(documents.values.filter { $0.seconds >= Self.documentMinimum }
            .sorted { $0.seconds > $1.seconds }.prefix(limit))
    }
}

// MARK: - Window titles (Accessibility)

enum FocusWindowReader {
    /// Apps whose window titles are never read (secrets, system UI).
    static let privateBundleIDs: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
        "com.apple.SecurityAgent",
    ]

    /// Apps that are not "work" and never counted (SparkV itself, the Dock…).
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.dock", "com.apple.notificationcenterui",
        "com.apple.controlcenter", "com.apple.SecurityAgent",
    ]

    /// Title of the focused window: the document's file name when the window
    /// reports one (AXDocument), otherwise its title. Read-only, with a short
    /// messaging timeout so a hung app can't stall the main thread.
    @MainActor
    static func focusedTitle(pid: pid_t) -> String? {
        // Preflight only (never prompts).
        guard PermissionCenter.shared.isGranted(.accessibility) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        var documentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef) == .success,
           let path = documentRef as? String, let name = documentName(path) {
            return name
        }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return cleanTitle(title)
    }

    /// "file:///Users/me/Report%20Q3.pages" → "Report Q3.pages".
    static func documentName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed) ?? URL(fileURLWithPath: trimmed)
        let name = url.isFileURL ? url.lastPathComponent : (url.host ?? trimmed)
        return name.isEmpty ? nil : FocusText.clip(name, 80)
    }

    /// Drops empty titles and the app-name-only titles some apps use.
    static func cleanTitle(_ title: String) -> String? {
        let t = FocusText.clip(title, 80)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Live tracker

/// Follows the frontmost app (NSWorkspace) and, with Accessibility already
/// granted, the focused window's title, crediting time to a
/// `FocusUsageSnapshot`. Never prompts for any permission.
@MainActor
final class FocusActivityTracker {
    private(set) var usage = FocusUsageSnapshot()
    var tracksWindowTitles = true
    /// Called when another app comes to the front (and once on resume).
    var onFrontmostChange: ((NSRunningApplication) -> Void)?

    private var token: NSObjectProtocol?
    private var poll: Task<Void, Never>?
    private(set) var isCounting = false
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "SparkV"

    static let titlePollInterval: Duration = .seconds(5)

    func begin(with snapshot: FocusUsageSnapshot = FocusUsageSnapshot()) {
        usage = snapshot
        usage.current = nil
        if token == nil {
            token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let app else { return }
                    self.frontmostChanged(app)
                }
            }
        }
        resume()
    }

    /// Breaks and pauses don't count as focus time.
    func suspend() {
        guard isCounting else { return }
        isCounting = false
        usage.pause(at: Date())
        poll?.cancel()
        poll = nil
    }

    func resume() {
        guard !isCounting else { return }
        isCounting = true
        if let app = NSWorkspace.shared.frontmostApplication { frontmostChanged(app) }
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SparkVEnergy.shared.duration(Self.titlePollInterval))
                guard !Task.isCancelled else { return }
                self?.refreshTitle()
            }
        }
    }

    /// Stops observing and returns the final numbers.
    func finish() -> FocusUsageSnapshot {
        suspend()
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
        return usage
    }

    /// Credits the running segment so a saved snapshot is up to date.
    func checkpoint() -> FocusUsageSnapshot {
        if isCounting { usage.checkpoint(at: Date()) }
        return usage
    }

    private func frontmostChanged(_ app: NSRunningApplication) {
        onFrontmostChange?(app)
        guard isCounting else { return }
        record(app)
    }

    private func refreshTitle() {
        guard isCounting, let app = NSWorkspace.shared.frontmostApplication else { return }
        record(app)
    }

    private func record(_ app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let now = Date()
        if bundleID == ownBundleID || FocusWindowReader.ignoredBundleIDs.contains(bundleID) {
            // Time over SparkV's own windows still belongs to the previous app.
            return
        }
        let name = app.localizedName ?? bundleID
        var title: String?
        if tracksWindowTitles, !FocusWindowReader.privateBundleIDs.contains(bundleID) {
            title = FocusWindowReader.focusedTitle(pid: app.processIdentifier)
            if title == name { title = nil }
        }
        usage.switchTo(bundleID: bundleID, appName: name, title: title, at: now)
    }
}
