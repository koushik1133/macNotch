import AppKit
import Combine
import SwiftUI

/// Every Island Placement setting, saved in UserDefaults under
/// "IslandPlacement.". Nothing here sends anything off the Mac.
@MainActor
final class IslandPlacementSettings: ObservableObject {
    static let shared = IslandPlacementSettings()

    enum Key {
        static let prefix = "IslandPlacement."
        static let displayMode = prefix + "displayMode"
        static let displayUUID = prefix + "displayUUID"
        static let displayName = prefix + "displayName"
        static let presets = prefix + "stylePresets"
        static let notchFit = prefix + "notchFit"
        static let pillHeight = prefix + "pillHeight"
        static let pillTopMargin = prefix + "pillTopMargin"
        static let minimalHairline = prefix + "minimalHairline"
        static let showOnDisplaysWithoutNotch = prefix + "showOnDisplaysWithoutNotch"
        static let hideInClamshell = prefix + "hideInClamshell"
        static let hideInFullScreen = prefix + "hideInFullScreen"
        static let revealAtTopEdge = prefix + "revealAtTopEdge"
        static let showsHUDWhileHidden = prefix + "showsHUDWhileHidden"
        static let showsVoiceWhileHidden = prefix + "showsVoiceWhileHidden"
        static let excludedBundleIDs = prefix + "excludedBundleIDs"
        static let exclusionBehavior = prefix + "exclusionBehavior"
        static let hidesInMissionControl = prefix + "hidesInMissionControl"
        static let menuBarAutoHide = prefix + "menuBarAutoHide"
        static let hideFromCapture = prefix + "hideFromCapture"
        static let blackMenuBar = prefix + "blackMenuBar"
        static let hotkeyEnabled = prefix + "hotkeyEnabled"
    }

    private let defaults: UserDefaults

    // MARK: Display

    @Published var displayMode: IslandDisplayMode { didSet { save(displayMode.rawValue, Key.displayMode) } }
    /// The display picked for `.specific` (stable UUID string).
    @Published var displayUUID: String? { didSet { save(displayUUID, Key.displayUUID) } }
    /// Its name, so Settings can say which display it waits for.
    @Published var displayName: String? { didSet { save(displayName, Key.displayName) } }

    // MARK: Style

    /// Display UUID → preset. A display not listed gets
    /// `IslandStylePreset.defaultPreset(hasNotch:)`.
    @Published private(set) var presets: [String: IslandStylePreset] {
        didSet { defaults.set(presets.mapValues(\.rawValue), forKey: Key.presets) }
    }
    @Published var notchFit: IslandNotchFit { didSet { save(notchFit.rawValue, Key.notchFit) } }
    @Published var pillHeight: Double { didSet { defaults.set(pillHeight, forKey: Key.pillHeight) } }
    @Published var pillTopMargin: Double { didSet { defaults.set(pillTopMargin, forKey: Key.pillTopMargin) } }
    @Published var minimalHairline: Bool { didSet { defaults.set(minimalHairline, forKey: Key.minimalHairline) } }

    // MARK: Visibility

    @Published var showOnDisplaysWithoutNotch: Bool { didSet { defaults.set(showOnDisplaysWithoutNotch, forKey: Key.showOnDisplaysWithoutNotch) } }
    @Published var hideInClamshell: Bool { didSet { defaults.set(hideInClamshell, forKey: Key.hideInClamshell) } }
    @Published var hideInFullScreen: Bool { didSet { defaults.set(hideInFullScreen, forKey: Key.hideInFullScreen) } }
    @Published var revealAtTopEdge: Bool { didSet { defaults.set(revealAtTopEdge, forKey: Key.revealAtTopEdge) } }
    @Published var showsHUDWhileHidden: Bool { didSet { defaults.set(showsHUDWhileHidden, forKey: Key.showsHUDWhileHidden) } }
    @Published var showsVoiceWhileHidden: Bool { didSet { defaults.set(showsVoiceWhileHidden, forKey: Key.showsVoiceWhileHidden) } }
    @Published var hidesInMissionControl: Bool { didSet { defaults.set(hidesInMissionControl, forKey: Key.hidesInMissionControl) } }
    @Published var menuBarAutoHide: IslandMenuBarAutoHideBehavior { didSet { save(menuBarAutoHide.rawValue, Key.menuBarAutoHide) } }
    /// ⌃⌥H hides and shows the island (off until the user turns it on).
    @Published var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled) } }

    // MARK: Apps

    @Published var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: Key.excludedBundleIDs) } }
    @Published var exclusionBehavior: IslandExclusionBehavior { didSet { save(exclusionBehavior.rawValue, Key.exclusionBehavior) } }

    // MARK: Privacy and appearance

    /// Off by default, so screenshots and bug reports still show the island.
    @Published var hideFromCapture: Bool { didSet { defaults.set(hideFromCapture, forKey: Key.hideFromCapture) } }
    /// Writes a wallpaper copy with a black top band. Off until turned on.
    @Published var blackMenuBar: Bool { didSet { defaults.set(blackMenuBar, forKey: Key.blackMenuBar) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: key) as? Double ?? fallback }

        displayMode = string(Key.displayMode).flatMap(IslandDisplayMode.init) ?? .automatic
        displayUUID = string(Key.displayUUID)
        displayName = string(Key.displayName)
        let rawPresets = defaults.dictionary(forKey: Key.presets) as? [String: String] ?? [:]
        presets = rawPresets.compactMapValues(IslandStylePreset.init)
        notchFit = string(Key.notchFit).flatMap(IslandNotchFit.init) ?? .standard
        pillHeight = double(Key.pillHeight, Double(IslandGeometry.defaultPillHeight))
        pillTopMargin = double(Key.pillTopMargin, Double(IslandGeometry.defaultPillTopMargin))
        minimalHairline = bool(Key.minimalHairline, true)
        showOnDisplaysWithoutNotch = bool(Key.showOnDisplaysWithoutNotch, true)
        hideInClamshell = bool(Key.hideInClamshell, false)
        hideInFullScreen = bool(Key.hideInFullScreen, true)
        revealAtTopEdge = bool(Key.revealAtTopEdge, true)
        showsHUDWhileHidden = bool(Key.showsHUDWhileHidden, true)
        showsVoiceWhileHidden = bool(Key.showsVoiceWhileHidden, true)
        hidesInMissionControl = bool(Key.hidesInMissionControl, true)
        menuBarAutoHide = string(Key.menuBarAutoHide).flatMap(IslandMenuBarAutoHideBehavior.init) ?? .hideWithMenuBar
        hotkeyEnabled = bool(Key.hotkeyEnabled, false)
        excludedBundleIDs = defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []
        exclusionBehavior = string(Key.exclusionBehavior).flatMap(IslandExclusionBehavior.init) ?? .ignoreHover
        hideFromCapture = bool(Key.hideFromCapture, false)
        blackMenuBar = bool(Key.blackMenuBar, false)
    }

    private func save(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    // MARK: Presets per display

    func preset(for display: IslandDisplayInfo) -> IslandStylePreset {
        presets[display.uuid] ?? .defaultPreset(hasNotch: display.hasNotch)
    }

    func setPreset(_ preset: IslandStylePreset, for display: IslandDisplayInfo) {
        if preset == .defaultPreset(hasNotch: display.hasNotch) {
            presets[display.uuid] = nil
        } else {
            presets[display.uuid] = preset
        }
    }

    /// Geometry options for one display.
    func geometryOptions(for display: IslandDisplayInfo) -> IslandGeometryOptions {
        IslandGeometryOptions(
            style: preset(for: display),
            fit: notchFit,
            pillHeight: CGFloat(pillHeight),
            pillTopMargin: CGFloat(pillTopMargin),
            menuBarAutoHide: menuBarAutoHide,
            minimalHairline: minimalHairline
        )
    }

    // MARK: Display choice

    func choose(_ mode: IslandDisplayMode) {
        displayMode = mode
    }

    /// Pins the island to one display (remembered by UUID across
    /// restarts, sleep, replugs and KVM switches).
    func choose(display: IslandDisplayInfo) {
        displayUUID = display.uuid
        displayName = display.name
        displayMode = .specific
    }

    // MARK: Excluded apps

    func isExcluded(_ bundleID: String?) -> Bool {
        IslandExclusions.isExcluded(bundleID: bundleID, list: excludedBundleIDs, ownBundleID: Bundle.main.bundleIdentifier)
    }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        excludedBundleIDs = IslandExclusions.toggled(bundleID, in: excludedBundleIDs, on: excluded)
    }

    /// Back to the defaults (Settings › Reset).
    func resetLayout() {
        displayMode = .automatic
        displayUUID = nil
        displayName = nil
        presets = [:]
        notchFit = .standard
        pillHeight = Double(IslandGeometry.defaultPillHeight)
        pillTopMargin = Double(IslandGeometry.defaultPillTopMargin)
        minimalHairline = true
    }
}
