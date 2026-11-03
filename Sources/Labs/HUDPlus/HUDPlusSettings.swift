import Combine
import Foundation

/// The volume and brightness HUD's choices, persisted under the `HUD.`
/// prefix. (The two older switches, `HUDEnabled` and `HUDReplacesSystem`,
/// stay on `HUDController`.) Nothing here sends anything off the Mac.
@MainActor
final class HUDPlusSettings: ObservableObject {
    static let shared = HUDPlusSettings()

    enum Key {
        static let style = "HUD.style"
        static let otherDisplaysStyle = "HUD.otherDisplaysStyle"
        static let styleByDisplay = "HUD.styleByDisplay"
        static let edge = "HUD.edge"
        static let stepDivisions = "HUD.stepDivisions"
        static let showsPercent = "HUD.showsPercent"
        static let interactive = "HUD.interactive"
        static let brightnessFollowsPointer = "HUD.brightnessFollowsPointer"
        static let showsOnPointerDisplay = "HUD.showsOnPointerDisplay"
        static let stepAsideForDisplayApps = "HUD.stepAsideForDisplayApps"
        static let displayAppsHandleBuiltIn = "HUD.displayAppsHandleBuiltIn"
    }

    private let defaults: UserDefaults

    /// Style on the display that hosts the island.
    @Published var style: HUDStyle { didSet { defaults.set(style.rawValue, forKey: Key.style) } }
    /// Style on displays without the island.
    @Published var otherDisplaysStyle: HUDStyle { didSet { defaults.set(otherDisplaysStyle.rawValue, forKey: Key.otherDisplaysStyle) } }
    /// Per-display choices keyed by the display's UUID (stable across
    /// reconnects, unlike its CGDirectDisplayID).
    @Published private(set) var styleByDisplay: [String: HUDStyle] {
        didSet { defaults.set(styleByDisplay.mapValues(\.rawValue), forKey: Key.styleByDisplay) }
    }
    /// Which side the edge bar sits on.
    @Published var edge: HUDEdge { didSet { defaults.set(edge.rawValue, forKey: Key.edge) } }
    /// Key steps from 0 to 100 % while SparkV replaces the macOS pop-up.
    @Published var stepDivisions: Int {
        didSet {
            let clamped = HUDStepMath.clampDivisions(stepDivisions)
            if clamped != stepDivisions { stepDivisions = clamped; return }
            defaults.set(stepDivisions, forKey: Key.stepDivisions)
        }
    }
    @Published var showsPercent: Bool { didSet { defaults.set(showsPercent, forKey: Key.showsPercent) } }
    /// Drag, scroll or click the HUD beside the notch to change the level.
    @Published var isInteractive: Bool { didSet { defaults.set(isInteractive, forKey: Key.interactive) } }
    /// Brightness keys change the display under the pointer.
    @Published var brightnessFollowsPointer: Bool { didSet { defaults.set(brightnessFollowsPointer, forKey: Key.brightnessFollowsPointer) } }
    /// The volume HUD shows on the display with the pointer.
    @Published var showsOnPointerDisplay: Bool { didSet { defaults.set(showsOnPointerDisplay, forKey: Key.showsOnPointerDisplay) } }
    /// Leave external displays' keys to BetterDisplay, Lunar or MonitorControl.
    @Published var stepAsideForDisplayApps: Bool { didSet { defaults.set(stepAsideForDisplayApps, forKey: Key.stepAsideForDisplayApps) } }
    /// Leave the built-in panel's keys to them as well.
    @Published var displayAppsHandleBuiltIn: Bool { didSet { defaults.set(displayAppsHandleBuiltIn, forKey: Key.displayAppsHandleBuiltIn) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Key.style).flatMap(HUDStyle.init(rawValue:)).flatMap { $0 == .hidden ? nil : $0 } ?? .inline
        otherDisplaysStyle = defaults.string(forKey: Key.otherDisplaysStyle).flatMap(HUDStyle.init(rawValue:))
            .flatMap { HUDStyle.otherDisplayChoices.contains($0) ? $0 : nil } ?? .pill
        let stored = defaults.dictionary(forKey: Key.styleByDisplay) as? [String: String] ?? [:]
        styleByDisplay = stored.compactMapValues(HUDStyle.init(rawValue:))
        edge = defaults.string(forKey: Key.edge).flatMap(HUDEdge.init(rawValue:)) ?? .right
        stepDivisions = HUDStepMath.clampDivisions(defaults.object(forKey: Key.stepDivisions) as? Int ?? HUDStepMath.defaultDivisions)
        showsPercent = defaults.object(forKey: Key.showsPercent) as? Bool ?? true
        isInteractive = defaults.object(forKey: Key.interactive) as? Bool ?? true
        brightnessFollowsPointer = defaults.object(forKey: Key.brightnessFollowsPointer) as? Bool ?? true
        showsOnPointerDisplay = defaults.object(forKey: Key.showsOnPointerDisplay) as? Bool ?? true
        stepAsideForDisplayApps = defaults.object(forKey: Key.stepAsideForDisplayApps) as? Bool ?? true
        displayAppsHandleBuiltIn = defaults.object(forKey: Key.displayAppsHandleBuiltIn) as? Bool ?? false
    }

    /// The per-display choice, or nil to follow the defaults.
    func override(forDisplayUUID uuid: String?) -> HUDStyle? {
        uuid.flatMap { styleByDisplay[$0] }
    }

    func setOverride(_ style: HUDStyle?, forDisplayUUID uuid: String) {
        if let style { styleByDisplay[uuid] = style } else { styleByDisplay.removeValue(forKey: uuid) }
    }

    /// The style for a display.
    func resolvedStyle(forDisplayUUID uuid: String?, isIslandScreen: Bool) -> HUDStyle {
        HUDStyleResolver.resolve(
            islandStyle: style,
            otherStyle: otherDisplaysStyle,
            override: override(forDisplayUUID: uuid),
            isIslandScreen: isIslandScreen
        )
    }

    /// Back to the shipped choices.
    func resetToDefaults() {
        style = .inline
        otherDisplaysStyle = .pill
        styleByDisplay = [:]
        edge = .right
        stepDivisions = HUDStepMath.defaultDivisions
        showsPercent = true
        isInteractive = true
        brightnessFollowsPointer = true
        showsOnPointerDisplay = true
        stepAsideForDisplayApps = true
        displayAppsHandleBuiltIn = false
    }
}
