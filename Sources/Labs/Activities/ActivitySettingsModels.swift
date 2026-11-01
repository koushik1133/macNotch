import Foundation
import SwiftUI

// MARK: - Timing

/// How long the closed island shows things, chosen by the user
/// (Settings › Activities › Timing and gear menu › Live Activities › Timing).
/// UserDefaults keys start with "Activity.".
///
/// - peek: a persistent activity's first appearance in the band (4 s).
/// - track title: how long a new song's title rides in the wings (8 s), or
///   always.
/// - notifications and the volume/brightness HUD: at most
///   `NotchMetrics.alertMaxDuration` (8 s), so they stay queued alerts.
/// - pause on hover: an alert in the band waits while the pointer is on it
///   (at most `hoverHoldCap`).
@MainActor
final class ActivityTimingSettings: ObservableObject {
    static let shared = ActivityTimingSettings()

    enum Keys {
        static let peekSeconds = "Activity.peekSeconds"
        static let titlePeekSeconds = "Activity.titlePeekSeconds"
        static let alwaysShowTitle = "Activity.alwaysShowTitle"
        static let titleWidth = "Activity.titleWidth"
        static let notificationSeconds = "Activity.notificationSeconds"
        static let hudSeconds = "Activity.hudSeconds"
        static let peekOnTrackChange = "Activity.peekOnTrackChange"
        static let peekOnPlayPause = "Activity.peekOnPlayPause"
        static let pausesOnHover = "Activity.pauseOnHover"
    }

    nonisolated static let peekChoices: [TimeInterval] = [2, 4, 6, 8]
    nonisolated static let titlePeekChoices: [TimeInterval] = [3, 5, 8, 12]
    nonisolated static let notificationChoices: [TimeInterval] = [3, 5, 8]
    nonisolated static let hudChoices: [TimeInterval] = [1, 1.6, 2.5, 4]
    /// A hovered alert never waits longer than this.
    nonisolated static let hoverHoldCap: TimeInterval = 30

    nonisolated static let defaultPeek: TimeInterval = 4
    nonisolated static let defaultTitlePeek: TimeInterval = 8
    nonisolated static let defaultNotification: TimeInterval = 5
    nonisolated static let defaultHUD: TimeInterval = 1.6

    /// Width of the track title in the now-playing wing. Clamped so the
    /// wing (title, 6 pt gap, 14 pt level bars, 18 pt padding) stays within
    /// `NotchMetrics.maxWingWidth`.
    enum TitleWidth: String, CaseIterable, Identifiable {
        case narrow, standard, wide
        var id: String { rawValue }
        var points: CGFloat {
            switch self {
            case .narrow: 40
            case .standard: 58
            case .wide: ActivityTimingSettings.maxTitleWidth
            }
        }
        var label: String {
            switch self {
            case .narrow: "Narrow"
            case .standard: "Standard"
            case .wide: "Wide"
            }
        }
    }

    /// Room for the title in the widest wing (112 − 18 padding − 20 bars).
    nonisolated static var maxTitleWidth: CGFloat {
        NotchMetrics.maxWingWidth - NotchMetrics.wingInnerPadding - NotchMetrics.wingOuterPadding - 14 - 6
    }

    /// Title width when a minimal icon (18 pt + 7 pt gap) shares the wing.
    nonisolated static func titleWidth(_ width: CGFloat, besideMinimal: Bool) -> CGFloat {
        let room = maxTitleWidth - (besideMinimal ? 25 : 0)
        return max(0, min(width, room))
    }

    @Published var peekSeconds: TimeInterval { didSet { store(peekSeconds, Keys.peekSeconds) } }
    @Published var titlePeekSeconds: TimeInterval { didSet { store(titlePeekSeconds, Keys.titlePeekSeconds) } }
    @Published var alwaysShowTitle: Bool { didSet { store(alwaysShowTitle, Keys.alwaysShowTitle) } }
    @Published var titleWidth: TitleWidth { didSet { store(titleWidth.rawValue, Keys.titleWidth) } }
    @Published var notificationSeconds: TimeInterval { didSet { store(notificationSeconds, Keys.notificationSeconds) } }
    @Published var hudSeconds: TimeInterval { didSet { store(hudSeconds, Keys.hudSeconds) } }
    @Published var peekOnTrackChange: Bool { didSet { store(peekOnTrackChange, Keys.peekOnTrackChange) } }
    @Published var peekOnPlayPause: Bool { didSet { store(peekOnPlayPause, Keys.peekOnPlayPause) } }
    @Published var pausesOnHover: Bool { didSet { store(pausesOnHover, Keys.pausesOnHover) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        peekSeconds = Self.nearest(defaults.object(forKey: Keys.peekSeconds) as? Double ?? Self.defaultPeek, in: Self.peekChoices)
        titlePeekSeconds = Self.nearest(defaults.object(forKey: Keys.titlePeekSeconds) as? Double ?? Self.defaultTitlePeek, in: Self.titlePeekChoices)
        alwaysShowTitle = defaults.object(forKey: Keys.alwaysShowTitle) as? Bool ?? false
        titleWidth = (defaults.string(forKey: Keys.titleWidth)).flatMap(TitleWidth.init(rawValue:)) ?? .standard
        notificationSeconds = Self.nearest(defaults.object(forKey: Keys.notificationSeconds) as? Double ?? Self.defaultNotification, in: Self.notificationChoices)
        hudSeconds = Self.nearest(defaults.object(forKey: Keys.hudSeconds) as? Double ?? Self.defaultHUD, in: Self.hudChoices)
        peekOnTrackChange = defaults.object(forKey: Keys.peekOnTrackChange) as? Bool ?? false
        peekOnPlayPause = defaults.object(forKey: Keys.peekOnPlayPause) as? Bool ?? false
        pausesOnHover = defaults.object(forKey: Keys.pausesOnHover) as? Bool ?? true
    }

    /// Everything back to the built-in timing.
    func resetToDefaults() {
        peekSeconds = Self.defaultPeek
        titlePeekSeconds = Self.defaultTitlePeek
        alwaysShowTitle = false
        titleWidth = .standard
        notificationSeconds = Self.defaultNotification
        hudSeconds = Self.defaultHUD
        peekOnTrackChange = false
        peekOnPlayPause = false
        pausesOnHover = true
    }

    var isDefault: Bool {
        peekSeconds == Self.defaultPeek && titlePeekSeconds == Self.defaultTitlePeek && !alwaysShowTitle
            && titleWidth == .standard && notificationSeconds == Self.defaultNotification && hudSeconds == Self.defaultHUD
            && !peekOnTrackChange && !peekOnPlayPause && pausesOnHover
    }

    /// The choice nearest to `value` (a stored value from an older choice
    /// list snaps to a current one).
    nonisolated static func nearest(_ value: TimeInterval, in choices: [TimeInterval]) -> TimeInterval {
        choices.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// "1.6 s", "8 s".
    nonisolated static func label(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

// MARK: - Several activities at once

/// How several running activities share the closed island
/// (Settings › Activities › Live Activities). Keys start with "LiveActivities.".
@MainActor
final class LiveActivitiesSettings: ObservableObject {
    static let shared = LiveActivitiesSettings()

    enum Keys {
        static let maxVisible = "LiveActivities.maxVisible"
        static let nowPlayingAlongside = "LiveActivities.nowPlayingAlongside"
        static let cycleHotkey = "LiveActivities.cycleHotkey"
    }

    /// 2: compact + one minimal icon; 3: compact + a minimal icon on each side.
    @Published var maxVisible: Int { didSet { defaults.set(maxVisible, forKey: Keys.maxVisible) } }
    /// Music stays beside a timer or a call (as a small artwork icon)
    /// instead of disappearing while another activity runs.
    @Published var keepsNowPlayingAlongside: Bool { didSet { defaults.set(keepsNowPlayingAlongside, forKey: Keys.nowPlayingAlongside) } }
    /// ⌃⌥A shows the next running activity in the wings.
    @Published var cycleHotkeyEnabled: Bool { didSet { defaults.set(cycleHotkeyEnabled, forKey: Keys.cycleHotkey) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Keys.maxVisible) as? Int ?? 3
        maxVisible = min(3, max(2, stored))
        keepsNowPlayingAlongside = defaults.object(forKey: Keys.nowPlayingAlongside) as? Bool ?? true
        cycleHotkeyEnabled = defaults.object(forKey: Keys.cycleHotkey) as? Bool ?? true
    }
}

// MARK: - VoiceOver announcements

/// What SparkV says to VoiceOver on its own (Settings › Accessibility).
/// Only ever speaks while VoiceOver is running. Keys start with "Announce.".
@MainActor
final class ActivityAnnouncementSettings: ObservableObject {
    static let shared = ActivityAnnouncementSettings()

    enum Keys {
        static let enabled = "Announce.enabled"
        static let readsNotificationText = "Announce.readsNotificationText"
        static func category(_ category: ActivityAnnouncement.Category) -> String { "Announce.\(category.rawValue)" }
    }

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    /// Off by default: a notification is announced as app and sender only.
    @Published var readsNotificationText: Bool { didSet { defaults.set(readsNotificationText, forKey: Keys.readsNotificationText) } }
    @Published private(set) var enabledCategories: Set<ActivityAnnouncement.Category>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        readsNotificationText = defaults.object(forKey: Keys.readsNotificationText) as? Bool ?? false
        var on: Set<ActivityAnnouncement.Category> = []
        for category in ActivityAnnouncement.Category.allCases {
            if defaults.object(forKey: Keys.category(category)) as? Bool ?? category.isOnByDefault { on.insert(category) }
        }
        enabledCategories = on
    }

    func isOn(_ category: ActivityAnnouncement.Category) -> Bool { enabledCategories.contains(category) }

    func set(_ category: ActivityAnnouncement.Category, _ on: Bool) {
        if on { enabledCategories.insert(category) } else { enabledCategories.remove(category) }
        defaults.set(on, forKey: Keys.category(category))
    }

    func binding(_ category: ActivityAnnouncement.Category) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.isOn(category) ?? false }, set: { [weak self] in self?.set(category, $0) })
    }
}

/// A sentence for VoiceOver, attached to a `LiveActivity`.
struct ActivityAnnouncement: Equatable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case charging, timer, meeting, notification, call, media, general
        var id: String { rawValue }

        var label: String {
            switch self {
            case .charging: "Charging and AirPods"
            case .timer: "Timers finishing"
            case .meeting: "Meetings starting soon"
            case .notification: "Notifications"
            case .call: "Calls"
            case .media: "Song changes"
            case .general: "Other live activities"
            }
        }

        /// Song changes are opt-in: music can change every three minutes.
        var isOnByDefault: Bool { self != .media }
    }

    var text: String
    var category: Category
    /// Spoken at high priority (VoiceOver may otherwise drop it while
    /// SparkV, an accessory app, isn't in front).
    var isImportant: Bool
}
