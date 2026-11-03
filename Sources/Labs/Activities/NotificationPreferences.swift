import AppKit
import SwiftUI

/// What the mirrored notifications show and for which apps
/// (Settings › Activities › Notifications). UserDefaults keys start with
/// "notificationPreview." like the existing on/off and Hide Message Text.
///
/// Apps are identified by the name Notification Center shows on the banner
/// (all Accessibility gives), compared without case.
@MainActor
final class NotificationPreferences: ObservableObject {
    static let shared = NotificationPreferences()

    enum Keys {
        static let filterMode = "notificationPreview.filterMode"
        static let allowedApps = "notificationPreview.allowedApps"
        static let mutedApps = "notificationPreview.mutedApps"
        static let seenApps = "notificationPreview.seenApps"
        static let hidesSender = "notificationPreview.hidesSender"
        static let showsActions = "notificationPreview.showsActions"
    }

    enum FilterMode: String, CaseIterable, Identifiable {
        /// Every app except the muted ones.
        case allExceptMuted
        /// Only the apps on the allow list.
        case onlyAllowed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .allExceptMuted: "All Apps Except Muted"
            case .onlyAllowed: "Only Apps I Choose"
            }
        }
    }

    @Published var filterMode: FilterMode { didSet { defaults.set(filterMode.rawValue, forKey: Keys.filterMode) } }
    @Published private(set) var allowedApps: [String]
    @Published private(set) var mutedApps: [String]
    /// Apps seen on a banner lately (names only, newest first, at most
    /// `maxSeen`), so Settings can offer them.
    @Published private(set) var seenApps: [String]
    /// With Hide Message Text on: also hide who it's from ("Messages ·
    /// New message").
    @Published var hidesSender: Bool { didSet { defaults.set(hidesSender, forKey: Keys.hidesSender) } }
    /// Reply, Open and Dismiss buttons on the band (they press the banner's
    /// own buttons through Accessibility).
    @Published var showsActions: Bool { didSet { defaults.set(showsActions, forKey: Keys.showsActions) } }

    static let maxSeen = 24
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        filterMode = defaults.string(forKey: Keys.filterMode).flatMap(FilterMode.init(rawValue:)) ?? .allExceptMuted
        allowedApps = defaults.stringArray(forKey: Keys.allowedApps) ?? []
        mutedApps = defaults.stringArray(forKey: Keys.mutedApps) ?? []
        seenApps = defaults.stringArray(forKey: Keys.seenApps) ?? []
        hidesSender = defaults.object(forKey: Keys.hidesSender) as? Bool ?? false
        showsActions = defaults.object(forKey: Keys.showsActions) as? Bool ?? true
    }

    // MARK: Filter

    /// Whether a banner from `app` is mirrored. A banner whose app is
    /// unknown is shown unless the user allows only chosen apps.
    func allows(app: String?) -> Bool {
        NotificationAppFilter.allows(app: app, mode: filterMode, allowed: allowedApps, muted: mutedApps)
    }

    func isMuted(_ app: String) -> Bool { NotificationAppFilter.contains(mutedApps, app) }
    func isAllowed(_ app: String) -> Bool { NotificationAppFilter.contains(allowedApps, app) }

    func mute(_ app: String) {
        guard !isMuted(app) else { return }
        mutedApps = (mutedApps + [app]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        defaults.set(mutedApps, forKey: Keys.mutedApps)
        AppLog.log("Notifications: muted \(app)")
    }

    func unmute(_ app: String) {
        mutedApps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
        defaults.set(mutedApps, forKey: Keys.mutedApps)
    }

    func setAllowed(_ app: String, _ allowed: Bool) {
        allowedApps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
        if allowed {
            allowedApps = (allowedApps + [app]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        defaults.set(allowedApps, forKey: Keys.allowedApps)
    }

    /// Shown in the current mode: allowed (allow list) or not muted.
    func isShown(_ app: String) -> Bool {
        switch filterMode {
        case .allExceptMuted: !isMuted(app)
        case .onlyAllowed: isAllowed(app)
        }
    }

    func setShown(_ app: String, _ shown: Bool) {
        switch filterMode {
        case .allExceptMuted: shown ? unmute(app) : mute(app)
        case .onlyAllowed: setAllowed(app, shown)
        }
    }

    func shownBinding(_ app: String) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.isShown(app) ?? true }, set: { [weak self] in self?.setShown(app, $0) })
    }

    /// Remembers that `app` sent a banner (name only, never content).
    func noteSeen(_ app: String?) {
        guard let app, NotificationParser.isPlausibleAppName(app) else { return }
        let updated = NotificationAppFilter.noting(app, in: seenApps, max: Self.maxSeen)
        guard updated != seenApps else { return }
        seenApps = updated
        defaults.set(seenApps, forKey: Keys.seenApps)
    }

    /// Apps for the Settings list: seen, muted and allowed ones, A–Z.
    var knownApps: [String] {
        var all: [String] = []
        for app in seenApps + mutedApps + allowedApps where !NotificationAppFilter.contains(all, app) { all.append(app) }
        return all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func forgetSeenApps() {
        seenApps = []
        defaults.removeObject(forKey: Keys.seenApps)
    }

    /// Adds an app picked in an Open panel (its display name) to the list
    /// and to the allow list when only chosen apps are shown.
    func add(appAt url: URL) {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        noteSeen(name)
        if filterMode == .onlyAllowed { setAllowed(name, true) }
    }

    /// What the band and VoiceOver may show of a notification.
    var privacy: NotificationPrivacy {
        let hidesBody = NotificationMonitor.current?.hidesMessageBody
            ?? (defaults.object(forKey: "notificationPreview.hidesBody") as? Bool ?? false)
        if !hidesBody { return .full }
        return hidesSender ? .appOnly : .senderOnly
    }
}

/// How much of a notification the band shows.
enum NotificationPrivacy: Equatable, Sendable {
    case full
    /// Sender and app, no message text.
    case senderOnly
    /// The app only.
    case appOnly
}

/// Pure list logic behind `NotificationPreferences`.
enum NotificationAppFilter {
    static func contains(_ list: [String], _ app: String) -> Bool {
        list.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }

    static func allows(app: String?, mode: NotificationPreferences.FilterMode, allowed: [String], muted: [String]) -> Bool {
        switch mode {
        case .allExceptMuted:
            guard let app else { return true }
            return !contains(muted, app)
        case .onlyAllowed:
            guard let app else { return false }
            return contains(allowed, app)
        }
    }

    /// `list` with `app` moved to the front, capped at `max`.
    static func noting(_ app: String, in list: [String], max: Int) -> [String] {
        var result = list.filter { $0.caseInsensitiveCompare(app) != .orderedSame }
        result.insert(app, at: 0)
        if result.count > max { result.removeLast(result.count - max) }
        return result
    }
}
