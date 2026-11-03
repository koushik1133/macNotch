import Foundation
import os

// Pure layout logic for the drawer header and the Agents hub: which controls
// show, in what order, where pinned hub tiles go, and how many rows the hub
// needs. Foundation only, so the test harness compiles it on its own.

// MARK: - Hub categories

/// The Agents hub's category switcher, in bar order. `all` shows every
/// visible tile; every tile belongs to exactly one other category.
enum HubCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, write, screen, focus, files, media, system, developer, planner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .write: "Write"
        case .screen: "Screen"
        case .focus: "Focus"
        case .files: "Files"
        case .media: "Media"
        case .system: "System"
        case .developer: "Developer"
        case .planner: "Planner"
        }
    }

    /// For VoiceOver and tooltips.
    var detail: String {
        switch self {
        case .all: "Every tile"
        case .write: "Replies, prompts, clipboard and dictation"
        case .screen: "Ask about the screen, copy text, record"
        case .focus: "Focus sessions, modes and screen distance"
        case .files: "Search, capture, files, downloads and sync"
        case .media: "Music, light and live captions"
        case .system: "Widgets, fans, moments, look and setup"
        case .developer: "UI audits, browser flows and the canvas"
        case .planner: "Meetings, jobs and today"
        }
    }
}

// MARK: - Header

enum HeaderSide: String, Codable, Sendable {
    /// Places (tabs), left of the camera housing.
    case left
    /// Actions, right of the camera housing (the gear always ends it).
    case right
}

/// One control the drawer header can show.
struct HeaderItemInfo: Equatable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let side: HeaderSide
    /// Agents can't be hidden: it is the way to everything that is.
    let canHide: Bool
    /// Tooltip, as the header has always shown it.
    let help: String
    /// The hub tile that stands in for this control while it is hidden from
    /// the header (nil when the hub already has one, e.g. Focus, Widgets).
    let hubStandIn: String?
}

/// The header's controls and its space budget. Each side of the camera
/// housing has 161.5 pt on the 14- and 16-inch MacBook Pro (508 pt header,
/// 185 pt housing); a control takes 24 pt plus 2 pt spacing, so six fit a
/// side. The gear is always the last control on the right.
enum HeaderCatalog {
    static let slotsPerSide = 6
    /// Hub tiles that can be pinned to the header at once.
    static let maxPins = 4

    static let items: [HeaderItemInfo] = [
        HeaderItemInfo(id: "home", title: "Home", systemImage: "house.fill", side: .left, canHide: true,
                       help: "Home: media, shortcuts and mirror", hubStandIn: "tab.home"),
        HeaderItemInfo(id: "widgets", title: "Widgets", systemImage: "rectangle.3.group.fill", side: .left, canHide: true,
                       help: "Widgets: world clocks, volume, habits, system and network", hubStandIn: nil),
        HeaderItemInfo(id: "tray", title: "Tray", systemImage: "tray.full.fill", side: .left, canHide: true,
                       help: "Tray: screenshots, text and files", hubStandIn: "tab.tray"),
        HeaderItemInfo(id: "today", title: "Today", systemImage: "calendar", side: .left, canHide: true,
                       help: "Today: meetings, agenda, reminders, timers, weather and launcher", hubStandIn: "tab.today"),
        HeaderItemInfo(id: "converter", title: "Convert", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard", side: .left, canHide: true,
                       help: "Convert: drop a file, pick a format", hubStandIn: "tab.converter"),
        HeaderItemInfo(id: "spaces", title: "Spaces", systemImage: "square.stack.3d.up.fill", side: .left, canHide: true,
                       help: "Spaces: knowledge folders per organization", hubStandIn: "tab.spaces"),
        HeaderItemInfo(id: "focus", title: "Focus", systemImage: "moon.fill", side: .right, canHide: true,
                       help: "Focus: start a session or see the time left", hubStandIn: nil),
        HeaderItemInfo(id: "record", title: "Record Meeting", systemImage: "record.circle", side: .right, canHide: true,
                       help: "Record this meeting (transcript, tasks and minutes)", hubStandIn: "tab.meeting"),
        HeaderItemInfo(id: "agents", title: "Agents", systemImage: "square.grid.2x2.fill", side: .right, canHide: false,
                       help: "Agents: search, focus, capture, reply, screen, prompts, clipboard, files, downloads and more", hubStandIn: nil),
        HeaderItemInfo(id: "flow", title: "Flow", systemImage: "waveform", side: .right, canHide: true,
                       help: "Flow: dictation history and notes", hubStandIn: "tab.flow"),
        HeaderItemInfo(id: "clicky", title: "Clicky", systemImage: "cursorarrow.rays", side: .right, canHide: true,
                       help: "Clicky: ask about your screen", hubStandIn: "tab.clicky"),
    ]

    /// Controls added after the six-per-side budget was used up start
    /// hidden, on a fresh install too (the user can swap them in); list such
    /// a control's id here when adding it to `items`. A side that still ends
    /// up over budget hides its last controls (they get their hub stand-ins).
    static let hiddenByDefault: Set<String> = []

    /// The catalog as a value, so tests can try other catalogs.
    static let standard = HeaderCatalogSpec(items: items, hiddenByDefault: hiddenByDefault)

    static func info(_ id: String) -> HeaderItemInfo? { items.first { $0.id == id } }

    static var defaultLeft: [String] { standard.defaults(.left) }
    static var defaultRight: [String] { standard.defaults(.right) }

    /// Controls on a side besides the listed items (the gear on the right).
    static func fixedSlots(_ side: HeaderSide) -> Int { side == .right ? 1 : 0 }
    /// Slots left for listed items and pins on a side.
    static func capacity(_ side: HeaderSide) -> Int { slotsPerSide - fixedSlots(side) }
}

/// The header controls a layout is checked against (`HeaderCatalog.standard`
/// in the app).
struct HeaderCatalogSpec: Sendable {
    var items: [HeaderItemInfo]
    var hiddenByDefault: Set<String>

    func info(_ id: String) -> HeaderItemInfo? { items.first { $0.id == id } }
    func defaults(_ side: HeaderSide) -> [String] { items.filter { $0.side == side }.map(\.id) }
}

/// The user's header: order per side, hidden controls and pinned hub tiles.
struct HeaderLayout: Equatable, Codable, Sendable {
    var left: [String] = HeaderCatalog.defaultLeft
    var right: [String] = HeaderCatalog.defaultRight
    var hidden: Set<String> = HeaderCatalog.hiddenByDefault
    /// Hub tile ids, in pin order.
    var pins: [String] = []
    /// Controls whose feature is switched off (Customize Layout › Features):
    /// not drawn, no hub stand-in, not saved with the layout.
    var featureOff: Set<String> = []

    static let standard = HeaderLayout()

    /// The layout as saved (nil: never saved, a fresh install), sanitized.
    /// On a fresh install the catalog's `hiddenByDefault` controls start
    /// hidden; after that, controls the saved layout has never seen do.
    static func restored(left: [String]?, right: [String]?, hidden: [String]?, pins: [String]?,
                         knownPins: Set<String>? = nil, catalog: HeaderCatalogSpec = HeaderCatalog.standard) -> HeaderLayout {
        let fresh = left == nil && right == nil
        let layout = HeaderLayout(
            left: left ?? catalog.defaults(.left),
            right: right ?? catalog.defaults(.right),
            hidden: Set(hidden ?? []).union(fresh || hidden == nil ? catalog.hiddenByDefault : []),
            pins: pins ?? []
        )
        return layout.sanitized(knownPins: knownPins, catalog: catalog)
    }

    /// Unknown ids dropped, catalog items missing from a side added back at
    /// their default position, Agents never hidden, a side over its budget
    /// hides its last hideable controls, pins capped and unique.
    func sanitized(knownPins: Set<String>? = nil, catalog: HeaderCatalogSpec = HeaderCatalog.standard) -> HeaderLayout {
        var copy = self
        // A control this layout has never seen that starts hidden.
        let known = Set(left + right)
        for id in catalog.hiddenByDefault where !known.contains(id) { copy.hidden.insert(id) }
        copy.left = Self.merge(saved: left, defaults: catalog.defaults(.left))
        copy.right = Self.merge(saved: right, defaults: catalog.defaults(.right))
        copy.hidden = copy.hidden.filter { catalog.info($0)?.canHide == true }
        // Over budget (a new control, an old saved layout): hide from the end.
        for side in [HeaderSide.left, .right] {
            var shown = copy.order(side).filter { !copy.hidden.contains($0) }
            while shown.count > HeaderCatalog.capacity(side),
                  let last = shown.last(where: { catalog.info($0)?.canHide == true }) {
                copy.hidden.insert(last)
                shown.removeAll { $0 == last }
            }
        }
        var seen = Set<String>()
        copy.pins = pins.filter { id in
            guard !seen.contains(id), knownPins?.contains(id) ?? true else { return false }
            seen.insert(id)
            return true
        }
        if copy.pins.count > HeaderCatalog.maxPins { copy.pins = Array(copy.pins.prefix(HeaderCatalog.maxPins)) }
        return copy
    }

    /// `saved` order of the ids in `defaults`, then any default it lacks,
    /// inserted after the default that precedes it.
    static func merge(saved: [String], defaults: [String]) -> [String] {
        var result: [String] = []
        for id in saved where defaults.contains(id) && !result.contains(id) { result.append(id) }
        for (index, id) in defaults.enumerated() where !result.contains(id) {
            if index > 0, let anchor = result.firstIndex(of: defaults[index - 1]) {
                result.insert(id, at: anchor + 1)
            } else {
                result.insert(id, at: 0)
            }
        }
        return result
    }

    func order(_ side: HeaderSide) -> [String] { side == .left ? left : right }

    /// Visible controls on a side, without pins (hidden ones and switched-off
    /// features left out).
    func visible(_ side: HeaderSide) -> [String] { order(side).filter { !hidden.contains($0) && !featureOff.contains($0) } }

    /// What the header draws, left to right on each side: visible controls
    /// with pinned tiles placed where there is room. Pins go on the right,
    /// just before Agents; when the right is full they go at the end of the
    /// left. While a meeting records, its timer pill needs about two slots:
    /// Focus steps aside first (as it always has), then the last pin on the
    /// right. Pins that don't fit stay in the hub.
    func placement(recording: Bool = false) -> (left: [String], right: [String]) {
        var left = visible(.left)
        var right = visible(.right)
        var rightCapacity = HeaderCatalog.capacity(.right)
        if recording, right.contains("record") {
            // The "● 12:34" pill is about two slots wide.
            rightCapacity -= 1
            right.removeAll { $0 == "focus" }
        }
        let leftCapacity = HeaderCatalog.capacity(.left)
        // `sanitized` keeps each side within its budget (overflow is hidden
        // and gets its hub stand-in); this only trims while recording.
        if left.count > leftCapacity { left = Array(left.prefix(leftCapacity)) }
        if right.count > rightCapacity { right = Array(right.prefix(rightCapacity)) }
        var rightPins: [String] = []
        var leftPins: [String] = []
        for pin in pins {
            if right.count + rightPins.count < rightCapacity {
                rightPins.append(pin)
            } else if left.count + leftPins.count < leftCapacity {
                leftPins.append(pin)
            }
        }
        if let agents = right.firstIndex(of: "agents") {
            right.insert(contentsOf: rightPins, at: agents)
        } else {
            right.append(contentsOf: rightPins)
        }
        left.append(contentsOf: leftPins)
        return (left, right)
    }

    /// Free slots for pins on both sides together (not recording).
    var freeSlots: Int {
        let used = visible(.left).count + visible(.right).count + pins.count
        return HeaderCatalog.capacity(.left) + HeaderCatalog.capacity(.right) - used
    }

    /// One more tile can be pinned: under the pin limit and a slot is free.
    var canPinMore: Bool { pins.count < HeaderCatalog.maxPins && freeSlots > 0 }

    /// Hub stand-ins for hidden controls ("tab.tray" while Tray is hidden),
    /// none for a switched-off feature.
    var hubStandIns: [String] {
        HeaderCatalog.items.compactMap { item in
            hidden.contains(item.id) && !featureOff.contains(item.id) ? item.hubStandIn : nil
        }
    }

    // MARK: Edits

    mutating func setHidden(_ id: String, _ isHidden: Bool) {
        guard HeaderCatalog.info(id)?.canHide == true else { return }
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
    }

    /// Shows a hidden control only when its side has room and a slot is
    /// free (unpinning the last pin first if needed would surprise; the
    /// editor says why instead).
    func canShow(_ id: String) -> Bool {
        guard hidden.contains(id) else { return true }
        guard let side = HeaderCatalog.info(id)?.side else { return false }
        return visible(side).count < HeaderCatalog.capacity(side) && freeSlots > 0
    }

    mutating func pin(_ id: String) {
        guard !pins.contains(id), canPinMore else { return }
        pins.append(id)
    }

    mutating func unpin(_ id: String) {
        pins.removeAll { $0 == id }
    }

    mutating func move(_ side: HeaderSide, fromOffsets source: IndexSet, toOffset destination: Int) {
        if side == .left {
            left = LayoutMath.moving(left, fromOffsets: source, toOffset: destination)
        } else {
            right = LayoutMath.moving(right, fromOffsets: source, toOffset: destination)
        }
    }

    mutating func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        pins = LayoutMath.moving(pins, fromOffsets: source, toOffset: destination)
    }
}

// MARK: - Hub

/// The user's hub: tile order, hidden tiles and the selected category.
struct HubLayout: Equatable, Codable, Sendable {
    /// Saved order; tiles not in it follow in catalog order.
    var order: [String] = []
    var hidden: Set<String> = []
    var category: HubCategory = .all

    static let standard = HubLayout()

    /// `catalog` (the default order) rearranged by the saved order. New
    /// tiles (another feature added one) keep their catalog position
    /// relative to the tile before them.
    func arranged(_ catalog: [String]) -> [String] {
        HeaderLayout.merge(saved: order, defaults: catalog)
    }

    /// Arranged ids without the hidden ones.
    func visible(_ catalog: [String]) -> [String] {
        arranged(catalog).filter { !hidden.contains($0) }
    }

    /// Moves `id` one place earlier (-1) or later (+1) among the visible
    /// tiles, keeping hidden tiles where they were.
    mutating func move(_ id: String, by offset: Int, catalog: [String]) {
        let all = arranged(catalog)
        let shown = all.filter { !hidden.contains($0) }
        guard let index = shown.firstIndex(of: id) else { return }
        let target = index + offset
        guard shown.indices.contains(target) else { return }
        let neighbor = shown[target]
        var result = all
        guard let a = result.firstIndex(of: id), let b = result.firstIndex(of: neighbor) else { return }
        result.swapAt(a, b)
        order = result
    }

    /// List-style move over the full arranged order.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, catalog: [String]) {
        order = LayoutMath.moving(arranged(catalog), fromOffsets: source, toOffset: destination)
    }

    mutating func setHidden(_ id: String, _ isHidden: Bool) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
    }
}

// MARK: - Metrics snapshot

/// What the (nonisolated) drawer metrics need from the hub, kept as a
/// lock-protected copy like `AppearanceStyle.current`.
struct LayoutSnapshot: Equatable, Sendable {
    /// Rows the hub's selected category needs (1 ... `maxRows`).
    var hubRows = 4
    /// The grid scrolls because more rows exist than fit.
    var hubScrolls = false

    static var current: LayoutSnapshot {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    private static let storage = OSAllocatedUnfairLock<LayoutSnapshot>(initialState: LayoutSnapshot())

    /// Rows for `count` tiles in `columns` columns, at least one and at most
    /// `maxRows` (more scroll).
    static func rows(for count: Int, columns: Int, maxRows: Int) -> (rows: Int, scrolls: Bool) {
        let needed = max(1, Int((Double(max(0, count)) / Double(max(1, columns))).rounded(.up)))
        return (min(needed, maxRows), needed > maxRows)
    }
}

// MARK: - Helpers

enum LayoutMath {
    /// `Array.move(fromOffsets:toOffset:)` without SwiftUI.
    static func moving<T>(_ array: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let moving = source.sorted().filter { array.indices.contains($0) }.map { array[$0] }
        var result = array.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let removedBefore = source.filter { $0 < destination }.count
        let insertAt = min(max(0, destination - removedBefore), result.count)
        result.insert(contentsOf: moving, at: insertAt)
        return result
    }
}
