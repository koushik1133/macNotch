import CoreGraphics
import Foundation

// Pure logic for the volume and brightness HUD: styles, step sizes, scroll
// and drag math, which display a brightness key belongs to, and where the
// interactive parts of the closed island are. No AppKit, no I/O, so the
// test harness compiles this file on its own.

// MARK: - Styles

/// How the HUD draws on a display.
enum HUDStyle: String, CaseIterable, Identifiable, Sendable {
    /// Icon left of the camera housing, level bar and percentage right of it
    /// (the resting form; nothing below the menu bar is covered).
    case inline
    /// Icon left of the housing, a small ring and percentage right of it.
    case ring
    /// The band under the notch: icon, wide bar, percentage.
    case band
    /// An iOS-style floating capsule near the top of the screen.
    case pill
    /// A slim vertical bar at the side of the screen.
    case edgeBar
    /// No SparkV HUD on this display.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inline: "Beside the Notch"
        case .ring: "Ring"
        case .band: "Under the Notch"
        case .pill: "Floating Pill"
        case .edgeBar: "Edge Bar"
        case .hidden: "Off"
        }
    }

    /// One word for tiles and tight menus.
    var shortTitle: String {
        switch self {
        case .inline: "Inline"
        case .ring: "Ring"
        case .band: "Band"
        case .pill: "Pill"
        case .edgeBar: "Edge"
        case .hidden: "Off"
        }
    }

    var detail: String {
        switch self {
        case .inline: "Level and percentage in the menu bar, either side of the camera."
        case .ring: "A compact ring with the percentage beside the camera."
        case .band: "A wide bar in a band under the notch."
        case .pill: "A floating capsule below the menu bar, like iOS."
        case .edgeBar: "A slim vertical bar at the edge of the screen."
        case .hidden: "SparkV shows nothing on this display."
        }
    }

    var systemImage: String {
        switch self {
        case .inline: "rectangle.topthird.inset.filled"
        case .ring: "circle.dashed.inset.filled"
        case .band: "rectangle.tophalf.inset.filled"
        case .pill: "capsule.fill"
        case .edgeBar: "rectangle.righthalf.inset.filled"
        case .hidden: "eye.slash"
        }
    }

    /// Drawn by the island itself (only the display that has it).
    var usesIsland: Bool { self == .inline || self == .ring || self == .band }

    /// Choices for the display that hosts the island.
    static let islandChoices: [HUDStyle] = [.inline, .ring, .band, .pill, .edgeBar]
    /// Choices for every other display (no island there).
    static let otherDisplayChoices: [HUDStyle] = [.pill, .edgeBar, .hidden]
}

/// Side of the screen for the edge bar.
enum HUDEdge: String, CaseIterable, Identifiable, Sendable {
    case right, left
    var id: String { rawValue }
    var title: String { self == .right ? "Right" : "Left" }
}

/// Whether the island can show a HUD right now (Island Placement may hide
/// it for full screen, an excluded app, ⌃⌥H or clamshell).
enum HUDIslandAvailability: Equatable, Sendable {
    /// On screen as usual.
    case shown
    /// Hidden, but ordered in for a band (Island Placement's "show the HUD
    /// while hidden"): wing styles use the band then.
    case passesBand
    /// Hidden with no HUD: macOS's own pop-up shows instead.
    case hidden
}

enum HUDStyleResolver {
    /// The form an island style takes while the island is hidden: the band
    /// when Island Placement passes it through, else none (nil). Other
    /// styles are unaffected.
    static func whileIslandHidden(_ style: HUDStyle, availability: HUDIslandAvailability) -> HUDStyle? {
        guard style.usesIsland else { return style }
        switch availability {
        case .shown: return style
        case .passesBand: return .band
        case .hidden: return nil
        }
    }


    /// The style a HUD uses on a display.
    ///
    /// - `islandStyle`: the user's choice for the island's display.
    /// - `otherStyle`: the choice for displays without the island.
    /// - `override`: a per-display choice, if the user made one.
    ///
    /// A display without the island can't draw island styles, so those fall
    /// back to the pill there.
    static func resolve(islandStyle: HUDStyle, otherStyle: HUDStyle, override: HUDStyle?, isIslandScreen: Bool) -> HUDStyle {
        let chosen = override ?? (isIslandScreen ? islandStyle : otherStyle)
        if !isIslandScreen, chosen.usesIsland { return .pill }
        return chosen
    }
}

// MARK: - Steps, scrolling and dragging

enum HUDStepMath {
    /// Steps from 0 to 100 %: 16 is macOS's own.
    static let divisionChoices = [10, 16, 20, 32, 50]
    static let defaultDivisions = 16

    static func clampDivisions(_ divisions: Int) -> Int {
        divisionChoices.contains(divisions) ? divisions : defaultDivisions
    }

    /// One key press: 1/divisions, or a quarter of that with Option+Shift
    /// (macOS's fine step: 1/64 with the default 16).
    static func step(divisions: Int, fine: Bool) -> Float {
        let base = 1 / Float(clampDivisions(divisions))
        return fine ? base / 4 : base
    }

    /// The step a media key moves by, or nil to leave the key to macOS:
    /// Option alone opens Sound / Displays settings there.
    static func keyStep(option: Bool, shift: Bool, divisions: Int) -> Float? {
        if option, !shift { return nil }
        return step(divisions: divisions, fine: option && shift)
    }

    /// Next level one step up or down, snapped to the step grid: 0.53 goes
    /// to 0.5625 or 0.5 with 1/16 steps, never skipping a notch. Clamped to 0...1.
    static func stepped(_ current: Float, step: Float, up: Bool) -> Float {
        guard step > 0, current.isFinite else { return up ? step : 0 }
        let position = min(1, max(0, current)) / step
        let nearest = position.rounded()
        // Float noise (0.4999 for 0.5) counts as being on the grid.
        let base = abs(position - nearest) < 0.02 ? nearest : position
        let index = up ? base.rounded(.down) + 1 : base.rounded(.up) - 1
        return min(1, max(0, index * step))
    }

    /// Points of trackpad scrolling for the full 0...100 % range.
    static let preciseScrollRange: Double = 320
    /// Points of horizontal drag for the full range when the drag is relative
    /// (the ring, which has no track to point at).
    static let relativeDragRange: Double = 140

    /// Level change for one scroll event. Physical "up" and "right" raise the
    /// level whatever the natural-scrolling setting. A mouse wheel moves one
    /// step per notch; a trackpad moves smoothly.
    static func scrollChange(deltaX: Double, deltaY: Double, precise: Bool, inverted: Bool, divisions: Int) -> Double {
        // Natural scrolling flips the deltas; undo that to get the fingers' direction.
        let up = deltaY * (inverted ? -1 : 1)
        let right = deltaX * (inverted ? 1 : -1)
        let amount = abs(up) >= abs(right) ? up : right
        guard amount != 0 else { return 0 }
        if precise { return amount / preciseScrollRange }
        return (amount > 0 ? 1 : -1) * Double(step(divisions: divisions, fine: false))
    }

    /// Level for a pointer at `x` over a track spanning `minX...maxX`.
    static func level(atX x: Double, minX: Double, maxX: Double) -> Double {
        guard maxX > minX else { return 0 }
        return min(1, max(0, (x - minX) / (maxX - minX)))
    }

    /// Level after a relative drag of `dx` points from `startLevel`.
    static func level(startLevel: Double, dragX dx: Double) -> Double {
        min(1, max(0, startLevel + dx / relativeDragRange))
    }

    /// Whole percent for display: 0.625 → 63.
    static func percent(_ level: Double) -> Int {
        Int((min(1, max(0, level)) * 100).rounded())
    }

    /// "63%", or "Muted".
    static func percentText(_ level: Double, muted: Bool = false) -> String {
        muted ? "Muted" : "\(percent(level))%"
    }
}

// MARK: - Brightness keys and displays

/// What SparkV knows about one display, refreshed when screens change.
struct HUDDisplayFacts: Equatable, Sendable {
    var id: CGDirectDisplayID
    var isBuiltin: Bool
    var isActive: Bool
    /// DisplayServices can set this display's brightness (the built-in panel,
    /// Apple Studio Display, Pro Display XDR, LG UltraFine).
    var canSetBrightness: Bool
}

enum HUDBrightnessRoute: Equatable, Sendable {
    /// SparkV applies the key to this display and swallows it.
    case apply(CGDirectDisplayID)
    /// SparkV leaves the key alone: macOS, BetterDisplay, Lunar or
    /// MonitorControl handle it.
    case passThrough(HUDPassReason)
}

enum HUDPassReason: Equatable, Sendable {
    /// No display SparkV could aim at (lid closed and nothing under the pointer).
    case noDisplay
    /// A display tool is running and the user lets it handle this display.
    case displayApp
    /// A DDC / third-party monitor SparkV can't set (no public API).
    case cannotControl
}

enum HUDBrightnessRouter {
    /// Which display a brightness key changes, and whether SparkV does it.
    ///
    /// - `pointer`: the display under the pointer.
    /// - `builtIn`: the built-in panel, nil in clamshell mode.
    /// - `followsPointer`: keys change the display under the pointer.
    /// - `displayAppRunning`: BetterDisplay, Lunar or MonitorControl is open.
    /// - `stepAside`: let those apps handle external displays.
    /// - `appsHandleBuiltIn`: let them handle the built-in panel too.
    static func route(
        pointer: HUDDisplayFacts?,
        builtIn: HUDDisplayFacts?,
        followsPointer: Bool,
        displayAppRunning: Bool,
        stepAside: Bool,
        appsHandleBuiltIn: Bool
    ) -> HUDBrightnessRoute {
        let activeBuiltIn = builtIn.flatMap { $0.isActive ? $0 : nil }
        let target: HUDDisplayFacts?
        if followsPointer {
            target = pointer ?? activeBuiltIn
        } else {
            // Keys always mean the built-in panel; in clamshell mode macOS
            // and the display tools keep them.
            target = activeBuiltIn
        }
        guard let target, target.isActive else { return .passThrough(.noDisplay) }
        if target.isBuiltin {
            if displayAppRunning, appsHandleBuiltIn { return .passThrough(.displayApp) }
            return target.canSetBrightness ? .apply(target.id) : .passThrough(.cannotControl)
        }
        if displayAppRunning, stepAside { return .passThrough(.displayApp) }
        if target.canSetBrightness { return .apply(target.id) }
        // A monitor nobody here can set (DDC, no display tool running): the
        // key changes the built-in panel, as it did before SparkV followed
        // the pointer, so the macOS pop-up never comes back for it.
        if !displayAppRunning, let panel = activeBuiltIn, panel.canSetBrightness { return .apply(panel.id) }
        return .passThrough(.cannotControl)
    }

    /// Whether SparkV should draw a HUD for a brightness change on a display
    /// that a display tool is handling (it shows its own).
    static func showsHUD(for display: HUDDisplayFacts, displayAppRunning: Bool, stepAside: Bool, appsHandleBuiltIn: Bool) -> Bool {
        guard displayAppRunning else { return true }
        return display.isBuiltin ? !appsHandleBuiltIn : !stepAside
    }
}

/// Display tools that drive external monitors over DDC and handle the
/// brightness keys themselves.
enum HUDDisplayApps {
    static let bundleIDs: [String: String] = [
        "pro.betterdisplay.BetterDisplay": "BetterDisplay",
        "fyi.lunar.Lunar": "Lunar",
        "me.guillaumeb.MonitorControl": "MonitorControl",
        "app.monitorcontrol.MonitorControl": "MonitorControl",
    ]

    static func name(for bundleID: String?) -> String? {
        bundleID.flatMap { bundleIDs[$0] }
    }

    /// "BetterDisplay", "BetterDisplay and Lunar", or nil.
    static func runningSummary(_ bundleIDs: [String?]) -> String? {
        let names = Array(Set(bundleIDs.compactMap(name(for:)))).sorted()
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

// MARK: - Interactive zones on the closed island

/// Which part of the HUD the pointer is over.
enum HUDHitPart: Equatable, Sendable {
    /// The icon: a click mutes / unmutes.
    case icon
    /// The level: click or drag to set it, scroll to nudge it.
    case level
    case none
}

/// Where the HUD sits on the island in screen coordinates (y up, like
/// `NSEvent.mouseLocation`).
struct HUDInteractionZones: Equatable, Sendable {
    /// Clicking here mutes.
    var icon: CGRect
    /// Dragging and scrolling here changes the level.
    var level: CGRect
    /// The track a click points at, or nil when dragging is relative.
    var track: ClosedRange<Double>?

    /// Small slop so the 5 pt bar isn't fiddly to grab.
    static let slop: CGFloat = 3

    func part(at point: CGPoint) -> HUDHitPart {
        if level.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) { return .level }
        if icon.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) { return .icon }
        return .none
    }

    func contains(_ point: CGPoint) -> Bool { part(at: point) != .none }
}

/// The HUD's geometry on the closed island, shared by the views (which draw
/// it) and the hit testing (which must match them).
enum HUDIslandGeometry {
    /// Width of the level bar in the trailing wing.
    static let wingBarWidth: CGFloat = 46
    /// Gap between the bar (or ring) and the percentage.
    static let wingGap: CGFloat = 6
    /// Ring diameter in the trailing wing.
    static let ringSize: CGFloat = 16
    /// The percentage's fixed column after the bar or ring.
    static let wingPercentWidth: CGFloat = 32
    /// The icon in the leading wing.
    static let wingIconSize: CGFloat = 22
    /// Extra room around the icon and level that still counts as on them.
    static let wingHitPad: CGFloat = 4

    /// Width of the trailing wing's HUD content (bar or ring, then the
    /// percentage when it shows).
    static func wingLevelWidth(ring: Bool, showsPercent: Bool) -> CGFloat {
        (ring ? ringSize : wingBarWidth) + (showsPercent ? wingGap + wingPercentWidth : 0)
    }
    /// Band layout: outer padding (the band's 16 plus the view's 16), icon
    /// column, gaps and the percentage column of `HUDActivityView`.
    static let bandInset: CGFloat = 32
    static let bandIcon: CGFloat = 34
    static let bandGap: CGFloat = 10
    static let bandPercent: CGFloat = 36

    /// Zones for the wings beside the camera housing.
    ///
    /// - `notch`: the resting island rect (its height is the menu-bar row).
    /// - `cameraMidX`: the camera's x (the housing is centered on it).
    /// - `housing`, `leadingWing`, `trailingWing`, `innerPadding`: as laid out
    ///   by `IslandClosedLayout`.
    /// - `ring`: the ring style (relative drag) instead of the bar.
    /// - `showsPercent`: the percentage follows the bar or ring.
    ///
    /// The zones cover only the HUD's own icon and level (plus a little
    /// room), never the rest of a wing, so nothing else the wing may hold
    /// is taken over.
    static func wings(
        notch: CGRect,
        cameraMidX: CGFloat,
        housing: CGFloat,
        leadingWing: CGFloat,
        trailingWing: CGFloat,
        innerPadding: CGFloat,
        ring: Bool,
        showsPercent: Bool = true
    ) -> HUDInteractionZones {
        let row = (minY: notch.minY, height: notch.height)
        let housingMin = cameraMidX - housing / 2
        let housingMax = cameraMidX + housing / 2
        let iconWidth = min(leadingWing, innerPadding + wingIconSize + wingHitPad)
        let levelWidth = min(trailingWing, innerPadding + wingLevelWidth(ring: ring, showsPercent: showsPercent) + wingHitPad)
        let icon = CGRect(x: housingMin - iconWidth, y: row.minY, width: iconWidth, height: row.height)
        let level = CGRect(x: housingMax, y: row.minY, width: levelWidth, height: row.height)
        let trackMin = Double(housingMax + innerPadding)
        let track: ClosedRange<Double>? = ring ? nil : trackMin...(trackMin + Double(wingBarWidth))
        return HUDInteractionZones(icon: icon, level: level, track: track)
    }

    /// Zones for the band under the notch.
    ///
    /// - `bodyWidth`: the island body's width with the band showing.
    /// - `bandHeight`: the band's height; `restingHeight` the menu-bar row.
    /// - `hasCaption`: a device name sits before the bar, so a click can't
    ///   point at the track and the drag is relative.
    static func band(
        notch: CGRect,
        cameraMidX: CGFloat,
        bodyWidth: CGFloat,
        bandHeight: CGFloat,
        hasCaption: Bool
    ) -> HUDInteractionZones {
        let minX = cameraMidX - bodyWidth / 2
        let maxX = cameraMidX + bodyWidth / 2
        let y = notch.minY - bandHeight
        let iconMaxX = minX + bandInset + bandIcon + bandGap / 2
        let icon = CGRect(x: minX, y: y, width: iconMaxX - minX, height: bandHeight)
        let level = CGRect(x: iconMaxX, y: y, width: maxX - iconMaxX, height: bandHeight)
        let trackMin = Double(minX + bandInset + bandIcon + bandGap)
        let trackMax = Double(maxX - bandInset - bandPercent - bandGap)
        return HUDInteractionZones(icon: icon, level: level, track: hasCaption || trackMax <= trackMin ? nil : trackMin...trackMax)
    }
}

// MARK: - Overlay placement

/// Where the overlay panel (pill or edge bar) sits on a screen.
enum HUDOverlayLayout {
    static let pillSize = CGSize(width: 264, height: 46)
    static let edgeBarSize = CGSize(width: 44, height: 200)
    /// Room around the pill / bar for its shadow.
    static let margin: CGFloat = 18
    /// Gap from the menu bar (pill) or the screen edge (edge bar).
    static let inset: CGFloat = 10

    /// The panel frame in AppKit coordinates (y up). The pill hangs centered
    /// below the menu bar (at the top in a full-screen Space, where the menu
    /// bar hides); the edge bar sits vertically centered inside the visible
    /// frame, so it clears the Dock (not Stage Manager's strip, which has no
    /// public frame).
    static func frame(style: HUDStyle, screen: CGRect, visible: CGRect, edge: HUDEdge) -> CGRect {
        let size = style == .edgeBar ? edgeBarSize : pillSize
        let width = size.width + 2 * margin
        let height = size.height + 2 * margin
        let top = min(visible.maxY, screen.maxY)
        if style == .edgeBar {
            let x = edge == .right ? visible.maxX - inset - size.width - margin : visible.minX + inset - margin
            return CGRect(x: x.rounded(), y: (visible.midY - height / 2).rounded(), width: width, height: height)
        }
        return CGRect(x: (screen.midX - width / 2).rounded(), y: (top - inset - size.height - margin).rounded(), width: width, height: height)
    }
}
