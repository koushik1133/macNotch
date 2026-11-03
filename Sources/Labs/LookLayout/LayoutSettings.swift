import AppKit
import SwiftUI

/// The tab the drawer opens on when the pointer opens it (an activity's own
/// tab, e.g. a meeting band, still wins).
enum DrawerOpenTab: String, CaseIterable, Identifiable, Sendable {
    case lastUsed, home, widgets, tray, today, spaces, agents, flow, clicky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastUsed: "Last Used"
        case .home: "Home"
        case .widgets: "Widgets"
        case .tray: "Tray"
        case .today: "Today"
        case .spaces: "Spaces"
        case .agents: "Agents"
        case .flow: "Flow"
        case .clicky: "Clicky"
        }
    }

    /// nil for Last Used.
    var tab: NotchState.Tab? {
        switch self {
        case .lastUsed: nil
        case .home: .nook
        case .widgets: .widgets
        case .tray: .tray
        case .today: .today
        case .spaces: .spaces
        case .agents: .agents
        case .flow: .flow
        case .clicky: .clicky
        }
    }
}

/// The drawer tab behind a header control id ("tray" → `.tray`).
enum HeaderTabs {
    static func tab(for id: String) -> NotchState.Tab? {
        switch id {
        case "home": .nook
        case "widgets": .widgets
        case "tray": .tray
        case "today": .today
        case "converter": .converter
        case "spaces": .spaces
        case "agents": .agents
        case "flow": .flow
        case "clicky": .clicky
        default: nil
        }
    }
}

/// The user's layout: header controls (order, hidden, pinned hub tiles),
/// the Agents hub (order, hidden tiles, category), the tab the drawer opens
/// on, and whether empty shortcut buttons show on Home. Saved in
/// UserDefaults under "SparkV.layout.*".
@MainActor
final class LayoutSettings: ObservableObject {
    static let shared = LayoutSettings()

    /// Posted on the main thread after the header or the hub's tile set
    /// changes, so the notch window can resize (the hub's height follows
    /// its rows).
    static let didChangeNotification = Notification.Name("SparkV.LayoutDidChange")

    enum Key {
        static let headerLeft = "SparkV.layout.headerLeft"
        static let headerRight = "SparkV.layout.headerRight"
        static let headerHidden = "SparkV.layout.headerHidden"
        static let headerPins = "SparkV.layout.headerPins"
        static let hubOrder = "SparkV.layout.hubOrder"
        static let hubHidden = "SparkV.layout.hubHidden"
        static let hubCategory = "SparkV.layout.hubCategory"
        static let openOn = "SparkV.layout.openOn"
        static let hidesEmptyShortcuts = "SparkV.layout.hidesEmptyShortcuts"
    }

    @Published var header: HeaderLayout {
        didSet {
            guard header != oldValue else { return }
            saveHeader()
            changed()
        }
    }

    @Published var hub: HubLayout {
        didSet {
            guard hub != oldValue else { return }
            saveHub()
            // Order, hidden tiles and the category all change the hub's rows.
            changed()
        }
    }

    @Published var openOn: DrawerOpenTab {
        didSet { if openOn != oldValue { defaults.set(openOn.rawValue, forKey: Key.openOn) } }
    }

    /// Home's shortcut capsules with nothing assigned stay hidden instead of
    /// showing a quiet + (right-click the column › Add Shortcut to assign one).
    @Published var hidesEmptyShortcuts: Bool {
        didSet { if hidesEmptyShortcuts != oldValue { defaults.set(hidesEmptyShortcuts, forKey: Key.hidesEmptyShortcuts) } }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Nothing saved yet (a fresh install): `hiddenByDefault` controls
        // start hidden.
        header = HeaderLayout.restored(
            left: defaults.stringArray(forKey: Key.headerLeft),
            right: defaults.stringArray(forKey: Key.headerRight),
            hidden: defaults.stringArray(forKey: Key.headerHidden),
            pins: defaults.stringArray(forKey: Key.headerPins),
            knownPins: HubCatalog.pinnableIDs
        )
        hub = HubLayout(
            order: defaults.stringArray(forKey: Key.hubOrder) ?? [],
            hidden: Set(defaults.stringArray(forKey: Key.hubHidden) ?? []),
            category: defaults.string(forKey: Key.hubCategory).flatMap(HubCategory.init(rawValue:)) ?? .all
        )
        openOn = defaults.string(forKey: Key.openOn).flatMap(DrawerOpenTab.init(rawValue:)) ?? .lastUsed
        hidesEmptyShortcuts = defaults.bool(forKey: Key.hidesEmptyShortcuts)
        refreshSnapshot()
    }

    // MARK: Features

    /// The header as it draws: the user's layout without the controls of
    /// switched-off features (Customize Layout › Features).
    var effectiveHeader: HeaderLayout {
        var copy = header
        copy.featureOff = FeatureSwitches.shared.offHeaderIDs
        return copy
    }

    /// A feature was switched on or off: the header, the hub's stand-ins
    /// and its rows change.
    func featuresDidChange() {
        objectWillChange.send()
        changed()
    }

    // MARK: Hub

    /// Every hub tile id in the user's order (hidden ones included).
    var hubArrangedIDs: [String] { hub.arranged(HubCatalog.defaultOrder(header: effectiveHeader)) }

    /// The tiles the hub shows, in order.
    var visibleHubIDs: [String] { hub.visible(HubCatalog.defaultOrder(header: effectiveHeader)) }

    /// A stand-in tile is the only way to a hidden header control, so it
    /// can't be hidden itself (show the control again, or switch the
    /// feature off, instead).
    func canHideTile(_ id: String) -> Bool { !HubCatalog.isStandIn(id) }

    func hideTile(_ id: String) {
        guard canHideTile(id) else { return }
        hub.setHidden(id, true)
        if header.pins.contains(id) { header.unpin(id) }
    }

    func showTile(_ id: String) { hub.setHidden(id, false) }

    func moveTile(_ id: String, by offset: Int) {
        hub.move(id, by: offset, catalog: HubCatalog.defaultOrder(header: effectiveHeader))
    }

    func canMoveTile(_ id: String, by offset: Int) -> Bool {
        let shown = visibleHubIDs
        guard let index = shown.firstIndex(of: id) else { return false }
        return shown.indices.contains(index + offset)
    }

    func moveTiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        hub.move(fromOffsets: source, toOffset: destination, catalog: HubCatalog.defaultOrder(header: effectiveHeader))
    }

    // MARK: Header

    func pin(_ id: String) {
        guard HubCatalog.info(id)?.pinnable == true else { return }
        if hub.hidden.contains(id) { hub.setHidden(id, false) }
        header.pin(id)
    }

    func unpin(_ id: String) { header.unpin(id) }

    func setHeaderItem(_ id: String, visible: Bool) {
        if visible, !header.canShow(id) { return }
        header.setHidden(id, !visible)
    }

    /// The tab to select when the pointer opens the drawer, or nil to keep
    /// the last one (also when the chosen tab's feature is switched off).
    var openTab: NotchState.Tab? {
        if let feature = LayoutFeature.owning(headerID: openOn.rawValue), !FeatureSwitches.shared.isOn(feature) { return nil }
        return openOn.tab
    }

    // MARK: Reset

    func resetHeader() { header = .standard }

    func resetHub() {
        let category = hub.category
        hub = HubLayout(order: [], hidden: [], category: category)
    }

    func resetAll() {
        resetHeader()
        resetHub()
        openOn = .lastUsed
        hidesEmptyShortcuts = false
    }

    // MARK: Snapshot

    /// The category the hub shows: the saved one, or All when it has no
    /// visible tiles.
    var effectiveHubCategory: HubCategory {
        let category = hub.category
        guard category != .all else { return .all }
        return visibleHubIDs.contains { HubCatalog.category(of: $0) == category } ? category : .all
    }

    /// Tiles the hub shows for the selected category.
    var shownHubIDs: [String] {
        let category = effectiveHubCategory
        let visible = visibleHubIDs
        return category == .all ? visible : visible.filter { HubCatalog.category(of: $0) == category }
    }

    /// Refreshes the copy the drawer metrics read: the rows of the selected
    /// category (the drawer springs to fit when the category changes). With
    /// `announce`, a change posts `didChangeNotification` so the notch window
    /// resizes.
    @discardableResult
    func refreshSnapshot(announce: Bool = false) -> Bool {
        let (rows, scrolls) = LayoutSnapshot.rows(
            for: shownHubIDs.count, columns: AgentHubMetrics.columns, maxRows: AgentHubMetrics.maxRows
        )
        let fresh = LayoutSnapshot(hubRows: rows, hubScrolls: scrolls)
        guard fresh != LayoutSnapshot.current else { return false }
        LayoutSnapshot.current = fresh
        if announce { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        return true
    }

    // MARK: Private

    private func changed() {
        refreshSnapshot()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func saveHeader() {
        defaults.set(header.left, forKey: Key.headerLeft)
        defaults.set(header.right, forKey: Key.headerRight)
        defaults.set(Array(header.hidden).sorted(), forKey: Key.headerHidden)
        defaults.set(header.pins, forKey: Key.headerPins)
    }

    private func saveHub() {
        defaults.set(hub.order, forKey: Key.hubOrder)
        defaults.set(Array(hub.hidden).sorted(), forKey: Key.hubHidden)
        defaults.set(hub.category.rawValue, forKey: Key.hubCategory)
    }
}
