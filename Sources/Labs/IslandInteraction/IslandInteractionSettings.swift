import AppKit
import Combine
import SwiftUI

/// Everything Island Interaction reads, as one value. Views, the window
/// controller and the nonisolated `NotchMetrics` read it through
/// `IslandInteractionStore.current` (lock-protected, so the spring and the
/// drawer width can be read from any context).
struct IslandInteractionSnapshot: Equatable, Sendable {
    var openTrigger: IslandOpenTrigger = .hover
    var openDelay: IslandOpenDelay = .automatic
    var closeDelay: IslandCloseDelay = .half
    var swipeGestures = true
    var clickOutsideCloses = true
    var escapeCloses = true
    var returnsFocus = true
    var toggleHotkeyEnabled = false
    var motionStyle: IslandMotionStyle = .calm
    var motionSpeed: IslandMotionSpeed = .standard
    var drawerSize: IslandDrawerSize = .standard
    var closedWidth: IslandClosedWidth = .standard
    var compactNowPlaying = false
    var avoidMenuBarItems = true
    var stepAsideForMenuBarManagers = true
    var warnAboutOtherNotchApps = true
    var haptics: IslandHapticsLevel = .gentle

    var motion: IslandMotionTuning { IslandMotionTuning(style: motionStyle, speed: motionSpeed) }

    /// The saved settings (defaults for anything never set).
    static func load(from defaults: UserDefaults) -> IslandInteractionSnapshot {
        typealias K = IslandInteractionKeys
        var s = IslandInteractionSnapshot()
        func string<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func int<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == Int {
            defaults.object(forKey: key) == nil ? fallback : (T(rawValue: defaults.integer(forKey: key)) ?? fallback)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        s.openTrigger = string(K.openTrigger, s.openTrigger)
        s.openDelay = int(K.openDelay, s.openDelay)
        s.closeDelay = int(K.closeDelay, s.closeDelay)
        s.swipeGestures = bool(K.swipeGestures, s.swipeGestures)
        s.clickOutsideCloses = bool(K.clickOutsideCloses, s.clickOutsideCloses)
        s.escapeCloses = bool(K.escapeCloses, s.escapeCloses)
        s.returnsFocus = bool(K.returnsFocus, s.returnsFocus)
        s.toggleHotkeyEnabled = bool(K.toggleHotkey, s.toggleHotkeyEnabled)
        s.motionStyle = string(K.motionStyle, s.motionStyle)
        s.motionSpeed = string(K.motionSpeed, s.motionSpeed)
        s.drawerSize = string(K.drawerSize, s.drawerSize)
        s.closedWidth = string(K.closedWidth, s.closedWidth)
        s.compactNowPlaying = bool(K.compactNowPlaying, s.compactNowPlaying)
        s.avoidMenuBarItems = bool(K.avoidMenuBarItems, s.avoidMenuBarItems)
        s.stepAsideForMenuBarManagers = bool(K.stepAside, s.stepAsideForMenuBarManagers)
        s.warnAboutOtherNotchApps = bool(K.warnOtherApps, s.warnAboutOtherNotchApps)
        s.haptics = string(K.haptics, s.haptics)
        return s
    }
}

enum IslandInteractionStore {
    private static let lock = NSLock()
    /// Read from UserDefaults on first use, so `NotchMetrics` has the
    /// user's spring and drawer width before the settings object exists.
    nonisolated(unsafe) private static var value = IslandInteractionSnapshot.load(from: .standard)
    nonisolated(unsafe) private static var clearance = IslandWingClearance.unlimited

    static var current: IslandInteractionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func set(_ snapshot: IslandInteractionSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    /// How far the closed island's wings may reach (menu bar items).
    static var wingClearance: IslandWingClearance {
        lock.lock()
        defer { lock.unlock() }
        return value.avoidMenuBarItems ? clearance : .unlimited
    }

    /// Now Playing beside the notch shows only its level bars: the
    /// setting, or too little room before the nearest menu bar item.
    static var compactNowPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        if value.compactNowPlaying { return true }
        return value.avoidMenuBarItems && clearance.trailing < tightRoom
    }

    /// Less room than this on the right: the title marquee doesn't fit.
    static let tightRoom: CGFloat = 80

    static func setWingClearance(_ value: IslandWingClearance) {
        lock.lock()
        clearance = value
        lock.unlock()
    }
}

/// User settings for opening, closing, motion, size, menu bar and haptics.
/// UserDefaults keys start with `IslandInteraction.`; nothing leaves the Mac.
@MainActor
final class IslandInteractionSettings: ObservableObject {
    static let shared = IslandInteractionSettings()

    typealias Key = IslandInteractionKeys

    @Published var openTrigger: IslandOpenTrigger { didSet { save(openTrigger.rawValue, Key.openTrigger) } }
    @Published var openDelay: IslandOpenDelay { didSet { save(openDelay.rawValue, Key.openDelay) } }
    @Published var closeDelay: IslandCloseDelay { didSet { save(closeDelay.rawValue, Key.closeDelay) } }
    @Published var swipeGestures: Bool { didSet { save(swipeGestures, Key.swipeGestures) } }
    @Published var clickOutsideCloses: Bool { didSet { save(clickOutsideCloses, Key.clickOutsideCloses) } }
    @Published var escapeCloses: Bool { didSet { save(escapeCloses, Key.escapeCloses) } }
    @Published var returnsFocus: Bool { didSet { save(returnsFocus, Key.returnsFocus) } }
    @Published var toggleHotkeyEnabled: Bool { didSet { save(toggleHotkeyEnabled, Key.toggleHotkey) } }
    @Published var motionStyle: IslandMotionStyle { didSet { save(motionStyle.rawValue, Key.motionStyle) } }
    @Published var motionSpeed: IslandMotionSpeed { didSet { save(motionSpeed.rawValue, Key.motionSpeed) } }
    @Published var drawerSize: IslandDrawerSize { didSet { save(drawerSize.rawValue, Key.drawerSize) } }
    @Published var closedWidth: IslandClosedWidth { didSet { save(closedWidth.rawValue, Key.closedWidth) } }
    @Published var compactNowPlaying: Bool { didSet { save(compactNowPlaying, Key.compactNowPlaying) } }
    @Published var avoidMenuBarItems: Bool { didSet { save(avoidMenuBarItems, Key.avoidMenuBarItems) } }
    @Published var stepAsideForMenuBarManagers: Bool { didSet { save(stepAsideForMenuBarManagers, Key.stepAside) } }
    @Published var warnAboutOtherNotchApps: Bool { didSet { save(warnAboutOtherNotchApps, Key.warnOtherApps) } }
    @Published var haptics: IslandHapticsLevel { didSet { save(haptics.rawValue, Key.haptics) } }
    /// Apps whose "also at the notch" notice the user dismissed.
    @Published private(set) var dismissedConflicts: Set<String>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = IslandInteractionSnapshot.load(from: defaults)
        openTrigger = d.openTrigger
        openDelay = d.openDelay
        closeDelay = d.closeDelay
        swipeGestures = d.swipeGestures
        clickOutsideCloses = d.clickOutsideCloses
        escapeCloses = d.escapeCloses
        returnsFocus = d.returnsFocus
        toggleHotkeyEnabled = d.toggleHotkeyEnabled
        motionStyle = d.motionStyle
        motionSpeed = d.motionSpeed
        drawerSize = d.drawerSize
        closedWidth = d.closedWidth
        compactNowPlaying = d.compactNowPlaying
        avoidMenuBarItems = d.avoidMenuBarItems
        stepAsideForMenuBarManagers = d.stepAsideForMenuBarManagers
        warnAboutOtherNotchApps = d.warnAboutOtherNotchApps
        haptics = d.haptics
        dismissedConflicts = Set(defaults.stringArray(forKey: Key.dismissedApps) ?? [])
        IslandInteractionStore.set(snapshot)
    }

    var snapshot: IslandInteractionSnapshot {
        IslandInteractionSnapshot(
            openTrigger: openTrigger, openDelay: openDelay, closeDelay: closeDelay,
            swipeGestures: swipeGestures, clickOutsideCloses: clickOutsideCloses, escapeCloses: escapeCloses,
            returnsFocus: returnsFocus, toggleHotkeyEnabled: toggleHotkeyEnabled,
            motionStyle: motionStyle, motionSpeed: motionSpeed, drawerSize: drawerSize, closedWidth: closedWidth,
            compactNowPlaying: compactNowPlaying, avoidMenuBarItems: avoidMenuBarItems,
            stepAsideForMenuBarManagers: stepAsideForMenuBarManagers,
            warnAboutOtherNotchApps: warnAboutOtherNotchApps, haptics: haptics
        )
    }

    func dismissConflict(_ key: String) {
        dismissedConflicts.insert(key)
        defaults.set(Array(dismissedConflicts).sorted(), forKey: Key.dismissedApps)
    }

    func resetDismissedConflicts() {
        dismissedConflicts = []
        defaults.removeObject(forKey: Key.dismissedApps)
    }

    /// Back to how the island always behaved: every setting here, haptics
    /// and the coexistence switches included. Dismissed "also at the
    /// notch" notices stay dismissed (`resetDismissedConflicts` clears them).
    func resetToDefaults() {
        let d = IslandInteractionSnapshot()
        openTrigger = d.openTrigger
        openDelay = d.openDelay
        closeDelay = d.closeDelay
        swipeGestures = d.swipeGestures
        clickOutsideCloses = d.clickOutsideCloses
        escapeCloses = d.escapeCloses
        returnsFocus = d.returnsFocus
        motionStyle = d.motionStyle
        motionSpeed = d.motionSpeed
        drawerSize = d.drawerSize
        closedWidth = d.closedWidth
        compactNowPlaying = d.compactNowPlaying
        avoidMenuBarItems = d.avoidMenuBarItems
        toggleHotkeyEnabled = d.toggleHotkeyEnabled
        stepAsideForMenuBarManagers = d.stepAsideForMenuBarManagers
        warnAboutOtherNotchApps = d.warnAboutOtherNotchApps
        haptics = d.haptics
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        IslandInteractionStore.set(snapshot)
    }
}

/// UserDefaults keys (outside the main-actor class, so the nonisolated
/// snapshot loader can use them).
enum IslandInteractionKeys {
    static let prefix = "IslandInteraction."
    static let openTrigger = prefix + "openTrigger"
    static let openDelay = prefix + "openDelayMs"
    static let closeDelay = prefix + "closeDelayMs"
    static let swipeGestures = prefix + "swipeGestures"
    static let clickOutsideCloses = prefix + "clickOutsideCloses"
    static let escapeCloses = prefix + "escapeCloses"
    static let returnsFocus = prefix + "returnsFocus"
    static let toggleHotkey = prefix + "toggleHotkeyEnabled"
    static let motionStyle = prefix + "motionStyle"
    static let motionSpeed = prefix + "motionSpeed"
    static let drawerSize = prefix + "drawerSize"
    static let closedWidth = prefix + "closedWidth"
    static let compactNowPlaying = prefix + "compactNowPlaying"
    static let avoidMenuBarItems = prefix + "avoidMenuBarItems"
    static let stepAside = prefix + "stepAsideForMenuBarManagers"
    static let warnOtherApps = prefix + "warnAboutOtherNotchApps"
    static let dismissedApps = prefix + "dismissedConflicts"
    static let haptics = "SparkVHaptics.level"
}

/// The wings' menu bar room and whether Now Playing beside the notch is
/// down to its level bars, for the views that draw them.
@MainActor
final class IslandWingRoom: ObservableObject {
    static let shared = IslandWingRoom()

    @Published private(set) var compactNowPlaying = IslandInteractionStore.compactNowPlaying
    /// The room the wings have before the nearest menu bar item.
    @Published private(set) var clearance = IslandInteractionStore.wingClearance

    func refresh() {
        let value = IslandInteractionStore.compactNowPlaying
        if value != compactNowPlaying { compactNowPlaying = value }
        let room = IslandInteractionStore.wingClearance
        if room != clearance { clearance = room }
    }
}

// MARK: - Haptics

/// The one gate for trackpad haptics in SparkV (Settings › Accessibility ›
/// Trackpad Haptics). Haptics are felt only with a finger on a Force Touch
/// trackpad; nothing happens on a mouse, so the gate costs nothing.
/// Never used for plain hover: only for gestures, drops and presses.
enum SparkVHaptics {
    static var level: IslandHapticsLevel { IslandInteractionStore.current.haptics }

    static var isEnabled: Bool { level != .off }

    /// One tap. Gentle turns every pattern into the lightest one.
    @MainActor
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        switch level {
        case .off: return
        case .gentle: NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .standard: NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    /// A run of taps (Focus's start kick). Gentle plays only the first,
    /// as the lightest tap.
    @MainActor
    static func performSequence(_ patterns: [NSHapticFeedbackManager.FeedbackPattern], gaps: [Double]) {
        guard let first = patterns.first else { return }
        switch level {
        case .off:
            return
        case .gentle:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .standard:
            let performer = NSHapticFeedbackManager.defaultPerformer
            performer.perform(first, performanceTime: .now)
            let rest = Array(patterns.dropFirst())
            Task { @MainActor in
                for (index, pattern) in rest.enumerated() {
                    try? await Task.sleep(for: .seconds(index < gaps.count ? gaps[index] : 0.12))
                    guard level == .standard else { return }
                    performer.perform(pattern, performanceTime: .now)
                }
            }
        }
    }
}

// MARK: - Geometry

extension IslandGeometry {
    /// The closed island with the Closed Width setting's extra shoulders,
    /// for the notch and the pill alike. An island that rests hidden
    /// (Minimal, an auto-hidden menu bar) stays as it is; the height never
    /// changes (on a notched display it is the hardware notch).
    func widened(by extra: CGFloat) -> IslandGeometry {
        guard extra > 0, !restsHidden else { return self }
        var copy = self
        copy.collapsedSize.width = IslandSizing.collapsedWidth(collapsedSize.width, extra: extra, scale: backingScale)
        return copy
    }
}
