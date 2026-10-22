import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Mirrors notification banners (Messages, Slack, Mail, ...) into the notch
/// band for a few seconds.
///
/// macOS has no public API to read other apps' notifications, so this watches
/// the Notification Center process (`com.apple.notificationcenterui`) through
/// Accessibility: an `AXObserver` reports windows / elements being created,
/// destroyed or re-laid out, and each burst of events triggers a read-only
/// scan of its AX tree on a background queue. Banners and alerts are the
/// elements whose subrole is `AXNotificationCenterBanner`, `...Alert`,
/// `...BannerStack` or `...AlertStack`; their static texts (identifiers
/// `title` / `subtitle` / `body` when present, otherwise in order) and their
/// accessibility description ("App, Title, Body") give the content.
///
/// Limits: needs the Accessibility permission (never prompted from here; it
/// starts on its own once granted), only sees banners that actually appear
/// (Focus / Do Not Disturb / "None" alert style mean nothing to mirror), can't
/// suppress the original banner, and depends on private AX structure that may
/// change in any macOS update.
@MainActor
final class NotificationMonitor: ObservableObject {
    static let activityID = "notification"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                if isStarted { beginMonitoring() }
            } else {
                endMonitoring()
                activities.dismiss(id: Self.activityID)
            }
        }
    }

    /// Privacy: show only the app and the sender, never the message text.
    @Published var hidesMessageBody: Bool {
        didSet {
            guard hidesMessageBody != oldValue else { return }
            UserDefaults.standard.set(hidesMessageBody, forKey: Keys.hidesBody)
            if hidesMessageBody { activities.dismiss(id: Self.activityID) }
        }
    }

    /// The last banner mirrored, for the settings UI or debugging.
    @Published private(set) var lastNotification: NotificationContent?

    private enum Keys {
        static let enabled = "notificationPreview.enabled"
        static let hidesBody = "notificationPreview.hidesBody"
    }

    private nonisolated static let bundleID = "com.apple.notificationcenterui"
    private static let displayDuration: TimeInterval = 5
    private static let bandHeight: CGFloat = 44
    /// More notifications than this at once means the Notification Center
    /// list is open (history), not new banners.
    private static let maxSimultaneousBanners = 4

    private let activities: ActivityCenter
    private let scanQueue = DispatchQueue(label: "SparkV.NotificationMonitor", qos: .userInitiated)

    private var isStarted = false
    private var isMonitoring = false
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedWindows: [AXUIElement] = []
    /// Follows Accessibility (no polling): attaches on a grant, detaches
    /// when the user switches it off.
    private var trustWatch: AnyCancellable?
    private var scanDebounce: Task<Void, Never>?
    private var followUpScan: Task<Void, Never>?
    private var visiblePoll: Task<Void, Never>?
    private var isScanning = false
    private var needsRescan = false
    private var workspaceTokens: [NSObjectProtocol] = []

    /// Signatures of banners on screen in the last scan.
    private var visibleSignatures: Set<String> = []
    /// When each signature was last mirrored, to absorb scan flicker.
    private var recentlyPosted: [String: Date] = [:]
    private var iconCache: [String: NSImage] = [:]
    private var loggedNoBanners = false

    init(activities: ActivityCenter) {
        self.activities = activities
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        hidesMessageBody = defaults.object(forKey: Keys.hidesBody) as? Bool ?? false
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard bundle == NotificationMonitor.bundleID else { return }
            MainActor.assumeIsolated { self?.notificationCenterRelaunched() }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard bundle == NotificationMonitor.bundleID else { return }
            MainActor.assumeIsolated { self?.detachObserver() }
        })
        if isEnabled { beginMonitoring() }
    }

    func stop() {
        isStarted = false
        endMonitoring()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        activities.dismiss(id: Self.activityID)
    }

    // MARK: - Lifecycle

    private func beginMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        watchTrust()
        if PermissionCenter.shared.isGranted(.accessibility) {
            attachObserver()
        } else {
            // Never prompt from here: the app's other features ask for
            // Accessibility. Just wait quietly until it is granted.
            AppLog.log("Notifications: waiting for Accessibility")
        }
    }

    private func endMonitoring() {
        isMonitoring = false
        trustWatch = nil
        detachObserver()
        visibleSignatures.removeAll()
    }

    private func watchTrust() {
        guard trustWatch == nil else { return }
        trustWatch = PermissionCenter.shared.onChange(of: .accessibility) { [weak self] status in
            guard let self, self.isMonitoring else { return }
            // An AX observer made before the switch was flipped stays deaf.
            self.detachObserver()
            if status.isGranted {
                AppLog.log("Notifications: Accessibility granted")
                self.attachObserver()
            }
        }
    }

    private func notificationCenterRelaunched() {
        guard isMonitoring else { return }
        detachObserver()
        // Give the new process a moment to build its AX tree.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.isMonitoring else { return }
            self.attachObserver()
        }
    }

    private func attachObserver() {
        guard isMonitoring, observer == nil else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            AppLog.log("Notifications: Notification Center not running")
            return
        }
        let pid = app.processIdentifier
        var created: AXObserver?
        let error = AXObserverCreate(pid, notificationMonitorAXCallback, &created)
        guard error == .success, let created else {
            AppLog.log("Notifications: AXObserverCreate failed (\(error.rawValue))")
            // Not trusted (or a stale grant): trustWatch re-attaches on a grant.
            if error == .apiDisabled { AppLog.log("Notifications: Accessibility API disabled, waiting for a grant") }
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in Self.observedNotifications {
            if AXObserverAddNotification(created, appElement, name as CFString, refcon) == .success {
                registered += 1
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = pid
        AppLog.log("Notifications: watching Notification Center (pid \(pid), \(registered) events)")
        // Learn what's already there (and mark it seen) without mirroring it.
        scheduleScan(after: 0.05, mirrorsNew: false)
    }

    private func detachObserver() {
        scanDebounce?.cancel()
        followUpScan?.cancel()
        visiblePoll?.cancel()
        scanDebounce = nil
        followUpScan = nil
        visiblePoll = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
        observedWindows.removeAll()
    }

    private static let observedNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXLayoutChangedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    private static let windowNotifications: [String] = [
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXLayoutChangedNotification,
        kAXValueChangedNotification,
    ]

    /// Some events only fire on the window, not the application element.
    private func observeWindows(_ windows: [AXUIElement]) {
        guard let observer else { return }
        observedWindows.removeAll { old in !windows.contains { CFEqual($0, old) } }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in windows where !observedWindows.contains(where: { CFEqual($0, window) }) {
            for name in Self.windowNotifications {
                _ = AXObserverAddNotification(observer, window, name as CFString, refcon)
            }
            observedWindows.append(window)
        }
    }

    // MARK: - Events and scanning

    fileprivate func handleAXEvent(_ name: String) {
        guard isMonitoring, isEnabled else { return }
        scheduleScan(after: 0.15, mirrorsNew: true)
        // Banner content can fill in after its window appears; one more scan
        // once the events settle.
        followUpScan?.cancel()
        followUpScan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.runScan(mirrorsNew: true)
        }
    }

    /// Throttled, not debounced: banner animations send a steady stream of
    /// layout events, and a debounce would keep pushing the scan back.
    private func scheduleScan(after delay: TimeInterval, mirrorsNew: Bool) {
        guard scanDebounce == nil else { return }
        scanDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.scanDebounce = nil
            self.runScan(mirrorsNew: mirrorsNew)
        }
    }

    private func runScan(mirrorsNew: Bool) {
        guard isMonitoring, observedPID != 0 else { return }
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        let pid = observedPID
        scanQueue.async { [weak self] in
            let result = NotificationAXScanner.scan(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isScanning = false
                    self.apply(result, mirrorsNew: mirrorsNew)
                    if self.needsRescan {
                        self.needsRescan = false
                        self.scheduleScan(after: 0.1, mirrorsNew: true)
                    }
                }
            }
        }
    }

    private func apply(_ result: NotificationScanResult, mirrorsNew: Bool) {
        guard isMonitoring else { return }
        observeWindows(result.windows.map(\.element))

        if result.banners.isEmpty, !result.sawNotificationSubrole, !loggedNoBanners, !result.windows.isEmpty, mirrorsNew {
            // Not an error by itself (desktop widgets also live here); noted
            // once so a structure change after an OS update is visible in logs.
            loggedNoBanners = true
            AppLog.log("Notifications: event without banner elements (\(result.windows.count) windows)")
        }

        let current = result.banners.filter { !$0.isInHistoryList }
        let signatures = Set(current.map(\.signature))
        let fresh = current.filter { !visibleSignatures.contains($0.signature) }
        visibleSignatures = signatures

        let now = Date()
        recentlyPosted = recentlyPosted.filter { now.timeIntervalSince($0.value) < 30 }

        if mirrorsNew, current.count <= Self.maxSimultaneousBanners {
            // Newest banner is on top; mirror only that one.
            if let newest = fresh.min(by: { $0.top < $1.top }),
               (recentlyPosted[newest.signature].map { now.timeIntervalSince($0) > 4 } ?? true) {
                recentlyPosted[newest.signature] = now
                mirror(newest.content)
            }
        } else if current.count > Self.maxSimultaneousBanners, !fresh.isEmpty {
            AppLog.log("Notifications: \(current.count) notifications visible, treating as Notification Center list")
        }

        // Destroyed events aren't always delivered; while something is on
        // screen, re-check now and then so it can be seen to go away.
        visiblePoll?.cancel()
        if !signatures.isEmpty {
            visiblePoll = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self?.runScan(mirrorsNew: true)
            }
        }
    }

    // MARK: - Posting

    /// Shows `content` in the band. Also usable to preview the band from settings.
    func mirror(_ content: NotificationContent) {
        guard isEnabled else { return }
        lastNotification = content
        let icon = content.appName.flatMap(icon(forAppNamed:))
        let hidesBody = hidesMessageBody
        AppLog.log("Notifications: mirroring banner from \(content.appName ?? "unknown app")")
        activities.post(LiveActivity(
            id: Self.activityID,
            kind: .notification,
            priority: 70,
            duration: Self.displayDuration,
            height: Self.bandHeight
        ) {
            NotificationActivityView(content: content, icon: icon, hidesBody: hidesBody)
        })
    }

    private func icon(forAppNamed name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        var found: NSImage?
        let running = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
        if let running, let image = running.icon {
            found = image
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let folders = [
                "/Applications", "/System/Applications", "/System/Applications/Utilities",
                "\(home)/Applications", "/System/Library/CoreServices", "/Applications/Utilities",
            ]
            for folder in folders {
                let path = "\(folder)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    found = NSWorkspace.shared.icon(forFile: path)
                    break
                }
            }
        }
        if let found { iconCache[name] = found }
        return found
    }
}

/// AXObserver C callback; the observer's source is on the main run loop.
private func notificationMonitorAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ name: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let event = name as String
    MainActor.assumeIsolated {
        let monitor = Unmanaged<NotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleAXEvent(event)
    }
}

// MARK: - Content

/// What a banner says.
struct NotificationContent: Equatable, Sendable {
    var appName: String?
    var title: String
    var subtitle: String?
    var body: String?

    var signature: String {
        [appName ?? "", title, subtitle ?? "", body ?? ""].joined(separator: "\u{1F}")
    }
}

/// Turns the texts of one banner element into `NotificationContent`.
/// Pure, so it can be checked without Accessibility.
enum NotificationParser {
    struct Text: Sendable {
        var identifier: String?
        var value: String
    }

    static func parse(texts rawTexts: [Text], description: String?, imageDescriptions: [String]) -> NotificationContent? {
        let texts = rawTexts
            .map { Text(identifier: $0.identifier?.lowercased(), value: clean($0.value)) }
            .filter { !$0.value.isEmpty && !isChrome($0.value) }

        var title = texts.first { $0.identifier == "title" }?.value
        var subtitle = texts.first { $0.identifier == "subtitle" }?.value
        var body = texts.first { $0.identifier == "body" }?.value

        if title == nil && body == nil {
            let plain = texts.filter { $0.identifier == nil || !["title", "subtitle", "body"].contains($0.identifier!) }
                .map(\.value)
            switch plain.count {
            case 0: break
            case 1: title = plain[0]
            case 2: title = plain[0]; body = plain[1]
            default:
                title = plain[0]
                subtitle = plain[1]
                body = plain[2...].joined(separator: " ")
            }
        }

        let label = description.map(stripLabelSuffixes) ?? ""
        var appName: String?

        if let title, !label.isEmpty, let range = label.range(of: ", " + title), range.lowerBound > label.startIndex {
            let prefix = String(label[label.startIndex..<range.lowerBound])
            if isPlausibleAppName(prefix) { appName = prefix }
        }
        if appName == nil {
            appName = imageDescriptions.map(clean).first { isPlausibleAppName($0) && $0 != title }
        }
        if title == nil, !label.isEmpty {
            // Nothing but the label: "App, Title, Body".
            let parts = label.components(separatedBy: ", ")
            if parts.count >= 3 {
                appName = appName ?? parts[0]
                title = parts[1]
                body = parts[2...].joined(separator: ", ")
            } else if parts.count == 2 {
                appName = appName ?? parts[0]
                title = parts[1]
            } else {
                title = parts[0]
            }
        }

        guard let finalTitle = title ?? appName, !finalTitle.isEmpty else { return nil }
        if subtitle == finalTitle { subtitle = nil }
        if body == finalTitle || body == subtitle { body = nil }
        return NotificationContent(
            appName: appName,
            title: finalTitle,
            subtitle: subtitle?.isEmpty == true ? nil : subtitle,
            body: body?.isEmpty == true ? nil : body
        )
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripLabelSuffixes(_ label: String) -> String {
        var result = clean(label)
        for suffix in [", stacked, from iPhone", ", from iPhone", ", stacked"] where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result
    }

    static func isPlausibleAppName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && !text.contains(", ") && !isChrome(text)
    }

    /// Timestamps, button titles and stack counters that aren't content.
    static func isChrome(_ text: String) -> Bool {
        let lower = text.lowercased()
        let fixed: Set<String> = [
            "now", "yesterday", "show more", "show less", "options", "clear", "close",
            "clear all", "reply", "mark as read", "delete", "archive", "notification",
        ]
        if fixed.contains(lower) { return true }
        let patterns = [
            #"^\d+\s?(m|h|d|w|min|mins|hr|hrs)( ago)?$"#,
            #"^\d+ (second|seconds|minute|minutes|hour|hours|day|days|week|weeks) ago$"#,
            #"^\d{1,2}:\d{2}(\s?[ap]\.?m\.?)?$"#,
            #"^\d+ more notifications?$"#,
            #"^\+\d+$"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

// MARK: - AX scanning (background queue)

struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

struct NotificationBanner: Sendable {
    var content: NotificationContent
    /// Screen y of the element's top edge (smaller is higher on screen).
    var top: CGFloat
    /// Inside the open Notification Center list rather than a fresh banner.
    var isInHistoryList: Bool
    var signature: String { content.signature }
}

struct NotificationScanResult: Sendable {
    var windows: [AXElementBox] = []
    var banners: [NotificationBanner] = []
    var sawNotificationSubrole = false
}

/// Read-only walk of Notification Center's AX tree. Only copies attributes;
/// never performs actions.
enum NotificationAXScanner {
    private static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner", "AXNotificationCenterAlert",
    ]
    private static let stackSubroles: Set<String> = [
        "AXNotificationCenterBannerStack", "AXNotificationCenterAlertStack",
    ]
    private static let listMarker = "AXNotificationListItems"
    private static let maxDepth = 14
    private static let maxNodes = 1500

    nonisolated static func scan(pid: pid_t) -> NotificationScanResult {
        var result = NotificationScanResult()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let windows: [AXUIElement] = elements(app, kAXWindowsAttribute)
        result.windows = windows.map(AXElementBox.init)
        var budget = maxNodes
        for window in windows {
            walk(window, depth: 0, inList: false, budget: &budget, into: &result)
        }
        return result
    }

    private nonisolated static func walk(
        _ element: AXUIElement, depth: Int, inList: Bool,
        budget: inout Int, into result: inout NotificationScanResult
    ) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let identifier = string(element, kAXIdentifierAttribute) ?? ""
        let roleDescription = string(element, kAXRoleDescriptionAttribute) ?? ""
        let listHere = inList || subrole == listMarker || identifier == listMarker || roleDescription == listMarker

        if bannerSubroles.contains(subrole) || stackSubroles.contains(subrole) {
            result.sawNotificationSubrole = true
            if stackSubroles.contains(subrole) {
                // A stack may hold its notifications as children; prefer them.
                let before = result.banners.count
                for child in elements(element, kAXChildrenAttribute) {
                    walk(child, depth: depth + 1, inList: listHere, budget: &budget, into: &result)
                }
                if result.banners.count > before { return }
            }
            if let content = extract(element) {
                let top = point(element, kAXPositionAttribute)?.y ?? 0
                result.banners.append(NotificationBanner(content: content, top: top, isInHistoryList: listHere))
            }
            return
        }

        for child in elements(element, kAXChildrenAttribute) {
            walk(child, depth: depth + 1, inList: listHere, budget: &budget, into: &result)
        }
    }

    private nonisolated static func extract(_ banner: AXUIElement) -> NotificationContent? {
        var texts: [NotificationParser.Text] = []
        var images: [String] = []
        var budget = 120
        collect(banner, depth: 0, isRoot: true, texts: &texts, images: &images, budget: &budget)
        let label = string(banner, kAXDescriptionAttribute) ?? string(banner, kAXTitleAttribute)
        return NotificationParser.parse(texts: texts, description: label, imageDescriptions: images)
    }

    private nonisolated static func collect(
        _ element: AXUIElement, depth: Int, isRoot: Bool,
        texts: inout [NotificationParser.Text], images: inout [String], budget: inout Int
    ) {
        guard depth <= 8, budget > 0 else { return }
        budget -= 1
        let role = string(element, kAXRoleAttribute) ?? ""
        if !isRoot {
            let subrole = string(element, kAXSubroleAttribute) ?? ""
            // Don't read into nested notifications (rest of a stack).
            if bannerSubroles.contains(subrole) || stackSubroles.contains(subrole) { return }
        }
        switch role {
        case kAXStaticTextRole:
            let value = string(element, kAXValueAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
            if !value.isEmpty {
                texts.append(.init(identifier: string(element, kAXIdentifierAttribute), value: value))
            }
            return
        case kAXImageRole:
            if let description = string(element, kAXDescriptionAttribute), !description.isEmpty {
                images.append(description)
            }
            return
        case kAXButtonRole, kAXMenuButtonRole, kAXTextFieldRole, kAXTextAreaRole:
            // Actions ("Reply", "Options", "Show more") and inline reply fields.
            return
        default:
            break
        }
        for child in elements(element, kAXChildrenAttribute) {
            collect(child, depth: depth + 1, isRoot: false, texts: &texts, images: &images, budget: &budget)
        }
    }

    // MARK: AX helpers

    private nonisolated static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private nonisolated static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = raw as! CFArray
        var result: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let item = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            if CFGetTypeID(item) == AXUIElementGetTypeID() {
                result.append(item as! AXUIElement)
            }
        }
        return result
    }

    private nonisolated static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }
}
