import Foundation

/// A feature that can be switched off as a whole (Customize Layout ›
/// Features). Off, its controller is stopped (its hotkey, monitors and
/// watchers go away, so it costs nothing), its header control and hub
/// stand-in disappear, and the drawer never opens on it. Hiding a header
/// control is the lighter choice: the feature keeps running and its tile
/// stays in the hub.
enum LayoutFeature: String, CaseIterable, Identifiable, Sendable {
    case flow, clicky, spaces, today, converter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flow: "Flow"
        case .clicky: "Clicky"
        case .spaces: "Spaces"
        case .today: "Today"
        case .converter: "Convert"
        }
    }

    /// What switching it off stops.
    var detail: String {
        switch self {
        case .flow: "Dictation: the push-to-talk key, its key monitor and the dictation history page."
        case .clicky: "Voice questions about your screen: its hotkey and listener."
        case .spaces: "Knowledge folders: the Spaces page and its folder, mail and web watchers."
        case .today: "Upcoming meetings: the calendar watcher, its hotkey and the Today page."
        case .converter: "The Convert page. It runs nothing in the background."
        }
    }

    var systemImage: String { HeaderCatalog.info(headerID)?.systemImage ?? "circle" }

    /// The header control it owns.
    var headerID: String {
        switch self {
        case .flow: "flow"
        case .clicky: "clicky"
        case .spaces: "spaces"
        case .today: "today"
        case .converter: "converter"
        }
    }

    /// The feature behind a header control id, if it can be switched off.
    static func owning(headerID id: String) -> LayoutFeature? { allCases.first { $0.headerID == id } }

    /// Saved as the list of features that are off ("SparkV.layout.featuresOff").
    static let defaultsKey = "SparkV.layout.featuresOff"
}

/// The on/off state of each `LayoutFeature` and the hooks that start and
/// stop its controller. The notch window connects each controller once at
/// launch (`connect`), which starts it only if its feature is on; a switch
/// then stops or starts it right away. Everything is on by default.
@MainActor
final class FeatureSwitches: ObservableObject {
    static let shared = FeatureSwitches()

    @Published private(set) var off: Set<LayoutFeature>

    private struct Hooks {
        let start: @MainActor () -> Void
        let stop: @MainActor () -> Void
    }
    private var hooks: [LayoutFeature: Hooks] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        off = Set((defaults.stringArray(forKey: LayoutFeature.defaultsKey) ?? []).compactMap(LayoutFeature.init(rawValue:)))
    }

    func isOn(_ feature: LayoutFeature) -> Bool { !off.contains(feature) }

    /// Header control ids of the features that are off.
    var offHeaderIDs: Set<String> { Set(off.map(\.headerID)) }

    /// Registers `feature`'s controller and starts it now if the feature is on.
    func connect(_ feature: LayoutFeature, start: @escaping @MainActor () -> Void, stop: @escaping @MainActor () -> Void) {
        hooks[feature] = Hooks(start: start, stop: stop)
        if isOn(feature) { start() }
    }

    /// Switches `feature` on or off: starts or stops its controller and
    /// updates the header and hub.
    func set(_ feature: LayoutFeature, on: Bool) {
        guard on != isOn(feature) else { return }
        if on { off.remove(feature) } else { off.insert(feature) }
        defaults.set(off.map(\.rawValue).sorted(), forKey: LayoutFeature.defaultsKey)
        AppLog.log("Features: \(feature.title) \(on ? "on" : "off")")
        if let hooks = hooks[feature] { on ? hooks.start() : hooks.stop() }
        if self === FeatureSwitches.shared { LayoutSettings.shared.featuresDidChange() }
    }
}
