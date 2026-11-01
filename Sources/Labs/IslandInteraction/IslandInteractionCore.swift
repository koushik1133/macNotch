import CoreGraphics
import Foundation

// Pure logic for how the island opens, closes, moves and sizes. No AppKit
// or SwiftUI here, so the unit harness compiles this file on its own.

// MARK: - Choices

/// How the closed island opens.
enum IslandOpenTrigger: String, CaseIterable, Identifiable, Sendable {
    case hover
    case click
    case hoverOrClick
    case pressAndHold
    case swipeDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click"
        case .hoverOrClick: "Hover or Click"
        case .pressAndHold: "Press and Hold"
        case .swipeDown: "Swipe Down"
        }
    }

    var detail: String {
        switch self {
        case .hover: "Rest the pointer on the notch."
        case .click: "Click the notch. Hovering only shows it is ready."
        case .hoverOrClick: "Hover, or click to open at once."
        case .pressAndHold: "Hold the button on the notch for a moment."
        case .swipeDown: "Two fingers down on the trackpad over the notch."
        }
    }

    var opensOnHover: Bool { self == .hover || self == .hoverOrClick }
    var opensOnClick: Bool { self == .click || self == .hoverOrClick }
    var opensOnPress: Bool { self == .pressAndHold }
    /// The closed island takes the button while the pointer is on it.
    var takesClicks: Bool { opensOnClick || opensOnPress }
}

/// How long the pointer rests on the notch before the drawer opens.
enum IslandOpenDelay: Int, CaseIterable, Identifiable, Sendable {
    /// A short intent pause (about 0.1 s) that stops brush-past flicker,
    /// or the notch theme's own dwell when that is longer.
    case automatic = -1
    case instant = 0
    case short = 100
    case medium = 200
    case relaxed = 350
    case long = 500
    case veryLong = 1000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .instant: "Instantly"
        case .short: "0.1 s"
        case .medium: "0.2 s"
        case .relaxed: "0.35 s"
        case .long: "0.5 s"
        case .veryLong: "1 s"
        }
    }
}

/// How long the drawer waits after the pointer leaves before it closes.
enum IslandCloseDelay: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case quarter = 250
    case half = 500
    case second = 1000
    case twoSeconds = 2000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: "Right Away"
        case .quarter: "0.25 s"
        case .half: "0.5 s"
        case .second: "1 s"
        case .twoSeconds: "2 s"
        }
    }
}

/// The island's open/close spring.
enum IslandMotionStyle: String, CaseIterable, Identifiable, Sendable {
    /// Apple-like, a hint of settle (the original island spring).
    case calm
    /// Shorter and firmer.
    case snappy
    /// Critically damped: no overshoot at all.
    case gentle
    /// No animation: the drawer appears and goes at once.
    case instant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calm: "Calm"
        case .snappy: "Snappy"
        case .gentle: "No Bounce"
        case .instant: "Instant"
        }
    }

    var detail: String {
        switch self {
        case .calm: "A soft spring with a hint of settle."
        case .snappy: "Quicker and firmer."
        case .gentle: "Eases in place, never overshoots."
        case .instant: "No animation."
        }
    }
}

/// Standard is the slowest: every spring stays at or under the original
/// 0.35 s response (a saved "relaxed" from an earlier build reads as Standard).
enum IslandMotionSpeed: String, CaseIterable, Identifiable, Sendable {
    case standard
    case quick
    case fastest

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .standard: 1
        case .quick: 1.25
        case .fastest: 1.5
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .quick: "Quick"
        case .fastest: "Fastest"
        }
    }
}

/// Width of the open drawer. Heights stay per tab: the content of every
/// tab is laid out for them.
enum IslandDrawerSize: String, CaseIterable, Identifiable, Sendable {
    case standard
    case wide
    case extraWide

    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .standard: 540
        case .wide: 600
        case .extraWide: 660
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .wide: "Wide"
        case .extraWide: "Extra Wide"
        }
    }
}

/// Extra width of the closed island beside the camera housing.
enum IslandClosedWidth: String, CaseIterable, Identifiable, Sendable {
    case standard
    case wider
    case widest

    var id: String { rawValue }

    /// Points added in total (half each side).
    var extra: CGFloat {
        switch self {
        case .standard: 0
        case .wider: 16
        case .widest: 32
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .wider: "Wider"
        case .widest: "Widest"
        }
    }
}

enum IslandHapticsLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    /// Every tap becomes the lightest one, and a run of taps becomes one.
    case gentle
    /// As each feature designed it.
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .gentle: "Gentle"
        case .standard: "Standard"
        }
    }
}

// MARK: - Motion

/// The spring the island, its theme layers and the Ambient Light outline
/// share, from the style and speed settings.
struct IslandMotionTuning: Equatable, Sendable {
    var style: IslandMotionStyle
    var speed: IslandMotionSpeed

    static let baseResponse = 0.35

    var isInstant: Bool { style == .instant }

    /// SwiftUI `.spring(response:dampingFraction:)` response, seconds.
    var response: Double {
        let base: Double = switch style {
        case .calm: Self.baseResponse
        case .snappy: 0.28
        case .gentle: 0.32
        case .instant: 0
        }
        return min(Self.baseResponse, base / speed.multiplier)
    }

    var dampingFraction: Double {
        switch style {
        case .calm: 0.8
        case .snappy: 0.86
        case .gentle, .instant: 1
        }
    }

    /// `CASpringAnimation(perceptualDuration:bounce:)` for the Ambient
    /// Light outline; nil jumps (Instant).
    var coreAnimationResponse: Double? { isInstant ? nil : response }

    var coreAnimationBounce: Double {
        switch style {
        case .calm: 0.15
        case .snappy: 0.1
        case .gentle, .instant: 0
        }
    }

    /// How long the drawer's height takes to settle: the panel shrinks to
    /// a shorter tab only after this (420 ms for the original spring).
    var settleMilliseconds: Int {
        guard !isInstant else { return 0 }
        let factor = dampingFraction >= 1 ? 1.35 : 1.2
        return Int((response * factor * 1000).rounded())
    }

    static let standard = IslandMotionTuning(style: .calm, speed: .standard)
}

// MARK: - Pointer

/// Pointer speed from the stream of mouse-moved events, allocation free
/// (the global monitor fires up to 120 times a second).
struct IslandPointerTracker: Sendable {
    private(set) var lastX: Double = 0
    private(set) var lastY: Double = 0
    private(set) var lastTime: Double = -1
    /// Smoothed velocity, points per second.
    private(set) var vx: Double = 0
    private(set) var vy: Double = 0
    /// The velocity holds a real measurement (false at the start and
    /// after the pointer rested).
    private var hasVelocity = false

    /// After this long without an event the pointer counts as still.
    static let stillAfter: Double = 0.1

    mutating func note(x: Double, y: Double, time: Double) {
        guard lastTime >= 0 else {
            lastX = x; lastY = y; lastTime = time
            return
        }
        let dt = time - lastTime
        guard dt > 0.0005 else { return }
        defer { lastX = x; lastY = y; lastTime = time }
        let ix = (x - lastX) / dt
        let iy = (y - lastY) / dt
        if dt > Self.stillAfter || !hasVelocity {
            // The first move after a rest: start over from it.
            vx = ix
            vy = iy
            hasVelocity = true
        } else {
            vx = vx * 0.5 + ix * 0.5
            vy = vy * 0.5 + iy * 0.5
        }
    }

    func speed(at now: Double) -> Double {
        guard lastTime >= 0, now - lastTime <= Self.stillAfter else { return 0 }
        return (vx * vx + vy * vy).squareRoot()
    }

    func horizontalSpeed(at now: Double) -> Double {
        guard lastTime >= 0, now - lastTime <= Self.stillAfter else { return 0 }
        return abs(vx)
    }
}

/// Where on the closed island the pointer is.
enum IslandHoverZone: Equatable, Sendable {
    /// Over the camera housing (or the resting pill): opening is the point.
    case housing
    /// Over a live-activity wing in the menu-bar row: menu bar items may
    /// be the real target, so it waits longer and not while moving sideways.
    case wing
    /// The band under the notch that leads to a tab.
    case band
}

enum IslandHoverPlan: Equatable, Sendable {
    case openNow
    case wait(milliseconds: Int)
}

/// Hover intent: how long to wait before a hover opens the drawer, and
/// whether the pointer has settled enough when that time is up.
enum IslandHoverIntent {
    /// Automatic's pause that stops a brush-past from opening the drawer.
    static let intentMilliseconds = 110
    /// The wings sit in the menu-bar row: a longer, deliberate pause.
    static let wingMilliseconds = 320
    /// Faster than this when the wait ends: just passing through.
    static let passThroughSpeed: Double = 1500
    /// Sideways faster than this over a wing: heading for a menu bar item.
    static let sidewaysSpeed: Double = 260

    struct Inputs: Equatable, Sendable {
        var zone: IslandHoverZone
        /// The pointer is pushed against the screen's top edge.
        var atTopEdge: Bool
        var delay: IslandOpenDelay
        /// The notch theme's own hover dwell (0 for Plain).
        var themeDwellMilliseconds: Int
        /// A floor from the context (full screen 400 ms, a Minimal island
        /// woken from the top-edge strip 250 ms).
        var floorMilliseconds: Int
    }

    static func plan(_ i: Inputs) -> IslandHoverPlan {
        var wait: Int
        switch i.delay {
        case .automatic:
            // Pushed against the edge over the notch: no doubt about intent.
            wait = i.atTopEdge && i.zone == .housing
                ? i.themeDwellMilliseconds
                : max(i.themeDwellMilliseconds, intentMilliseconds)
        default:
            wait = i.delay.rawValue
        }
        if i.zone == .wing, i.delay != .instant { wait = max(wait, wingMilliseconds) }
        wait = max(wait, i.floorMilliseconds)
        return wait <= 0 ? .openNow : .wait(milliseconds: wait)
    }

    /// At the end of the wait: open only if the pointer has settled (and,
    /// over a wing, isn't sliding along the menu bar).
    static func settled(zone: IslandHoverZone, speed: Double, horizontalSpeed: Double) -> Bool {
        if speed > passThroughSpeed { return false }
        if zone == .wing, horizontalSpeed > sidewaysSpeed { return false }
        return true
    }
}

// MARK: - Closing

enum IslandCloseTiming {
    /// A close delay of 0 still waits this long, so crossing a theme's glow
    /// margin or a one-pixel gap doesn't flicker the drawer.
    static let floorMilliseconds = 80
    /// A drawer opened by hover stays at least this long, so a brush-past
    /// can't snap it shut mid-spring.
    static let minimumOpenMilliseconds = 350

    /// - Parameters:
    ///   - openedAt: when the drawer opened (seconds, any monotonic clock).
    static func delayMilliseconds(setting: IslandCloseDelay, openedAt: Double?, now: Double) -> Int {
        let base = max(setting.rawValue, floorMilliseconds)
        guard let openedAt else { return base }
        let remaining = minimumOpenMilliseconds - Int(((now - openedAt) * 1000).rounded())
        return max(base, remaining)
    }
}

/// After an explicit close (Esc, a click on the notch, a swipe up, ⌃⌥O)
/// hover can't reopen the drawer until the pointer has left the island once.
struct IslandCloseLatch: Sendable {
    private(set) var isLatched = false

    mutating func closedOnRequest() { isLatched = true }

    /// Every pointer pass: true while hover must not open (or prime) the island.
    mutating func suppressesHover(pointerOnIsland: Bool) -> Bool {
        if isLatched, !pointerOnIsland { isLatched = false }
        return isLatched
    }

    mutating func reset() { isLatched = false }
}

// MARK: - Gestures

enum IslandScrollPhase: Sendable {
    case began
    case changed
    case ended
    /// Momentum, mouse wheels and anything else: ignored.
    case other
}

enum IslandSwipe: Equatable, Sendable {
    case down
    case up
}

/// Two-finger swipes on the trackpad: down over the closed island opens it,
/// up over the open drawer's header closes it. One result per gesture.
struct IslandSwipeTracker: Sendable {
    static let threshold: CGFloat = 30

    private(set) var isTracking = false
    private(set) var fingerTravel: CGFloat = 0
    private(set) var fired = false

    /// - Parameters:
    ///   - deltaY: `scrollingDeltaY` (precise deltas only).
    ///   - inverted: `isDirectionInvertedFromDevice` (natural scrolling).
    ///   - inZone: the pointer is where this gesture counts (checked at its start).
    mutating func feed(phase: IslandScrollPhase, deltaY: CGFloat, inverted: Bool, inZone: Bool) -> IslandSwipe? {
        switch phase {
        case .began:
            isTracking = inZone
            fingerTravel = 0
            fired = false
            if isTracking { return accumulate(deltaY, inverted: inverted) }
            return nil
        case .changed:
            guard isTracking else { return nil }
            return accumulate(deltaY, inverted: inverted)
        case .ended:
            reset()
            return nil
        case .other:
            return nil
        }
    }

    mutating func reset() {
        isTracking = false
        fingerTravel = 0
        fired = false
    }

    private mutating func accumulate(_ deltaY: CGFloat, inverted: Bool) -> IslandSwipe? {
        // Natural scrolling: fingers down give a positive delta.
        fingerTravel += inverted ? deltaY : -deltaY
        guard !fired else { return nil }
        if fingerTravel >= Self.threshold {
            fired = true
            return .down
        }
        if fingerTravel <= -Self.threshold {
            fired = true
            return .up
        }
        return nil
    }
}

/// Press and Hold: the button stays down on the island for `holdSeconds`
/// without moving more than `slop`.
struct IslandPressTracker: Sendable {
    static let holdSeconds: Double = 0.4
    static let slop: Double = 4

    private(set) var downX: Double = 0
    private(set) var downY: Double = 0
    private(set) var downTime: Double?

    var isPressing: Bool { downTime != nil }

    mutating func down(x: Double, y: Double, time: Double) {
        downX = x
        downY = y
        downTime = time
    }

    /// False once it moved too far (the press is over).
    mutating func moved(x: Double, y: Double) -> Bool {
        guard downTime != nil else { return false }
        let dx = x - downX, dy = y - downY
        if (dx * dx + dy * dy).squareRoot() > Self.slop {
            downTime = nil
            return false
        }
        return true
    }

    func isHeld(now: Double) -> Bool {
        guard let downTime else { return false }
        return now - downTime >= Self.holdSeconds
    }

    mutating func up() { downTime = nil }
}

// MARK: - Menu bar items

/// How far each wing may reach before it would cover a menu bar item.
struct IslandWingClearance: Equatable, Sendable {
    /// Points from the housing's left edge to the nearest thing on the left.
    var leading: CGFloat
    /// Points from the housing's right edge to the nearest item on the right.
    var trailing: CGFloat

    static let unlimited = IslandWingClearance(leading: .greatestFiniteMagnitude, trailing: .greatestFiniteMagnitude)

    /// Gap kept between a wing and the item next to it.
    static let margin: CGFloat = 6

    var isLimited: Bool { leading < 10_000 || trailing < 10_000 }

    /// - Parameters:
    ///   - housing: the camera housing (or the resting island's middle) in
    ///     screen coordinates (AppKit, y up).
    ///   - menuBar: the menu-bar row of that display.
    ///   - items: status item frames, AppKit coordinates.
    ///   - appMenusMaxX: right edge of the front app's menus, when known.
    static func compute(housing: CGRect, menuBar: CGRect, items: [CGRect], appMenusMaxX: CGFloat?) -> IslandWingClearance {
        var leadingEdge = -CGFloat.greatestFiniteMagnitude
        var trailingEdge = CGFloat.greatestFiniteMagnitude
        for item in items {
            // Only the menu-bar row of this display, and only items beside
            // the housing (macOS hides the ones it would cover).
            guard item.intersects(menuBar), item.width > 0 else { continue }
            if item.minX >= housing.maxX - 1 {
                trailingEdge = min(trailingEdge, item.minX)
            } else if item.maxX <= housing.minX + 1 {
                leadingEdge = max(leadingEdge, item.maxX)
            }
        }
        if let appMenusMaxX, appMenusMaxX <= housing.minX + 1 {
            leadingEdge = max(leadingEdge, appMenusMaxX)
        }
        let leading = leadingEdge.isFinite && leadingEdge > -1e12
            ? max(0, housing.minX - leadingEdge - margin) : CGFloat.greatestFiniteMagnitude
        let trailing = trailingEdge < 1e12
            ? max(0, trailingEdge - housing.maxX - margin) : CGFloat.greatestFiniteMagnitude
        return IslandWingClearance(leading: leading, trailing: trailing)
    }

    /// A wing of `width` points, held to the clearance on its side but
    /// never narrower than `floor` (the resting shoulder).
    static func cap(_ width: CGFloat, clearance: CGFloat, floor: CGFloat) -> CGFloat {
        max(floor, min(width, clearance))
    }
}

/// CoreGraphics window bounds (top-left origin on the primary display) to
/// AppKit screen coordinates (bottom-left origin).
enum IslandScreenCoordinates {
    static func appKitRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Other apps at the notch

/// One window of another app, from the window list (bounds, owner and
/// layer need no Screen Recording permission; names do and aren't used).
struct IslandForeignWindow: Equatable, Sendable {
    var pid: Int32
    var layer: Int
    /// AppKit coordinates.
    var bounds: CGRect
    var ownerName: String
    var bundleID: String?
}

enum IslandKnownApps {
    /// Menu bar managers. IDs from each project's published app bundle;
    /// Wispr Flow's was read from the installed copy with `mdls`.
    static let menuBarManagers: [String: String] = [
        "com.jordanbaird.Ice": "Ice",
        "com.surteesstudios.Bartender": "Bartender",
        "com.dwarvesv.minimalbar": "Hidden Bar",
        "com.mortennn.Dozer": "Dozer",
        "net.matthewpalmer.Vanilla": "Vanilla",
        "cn.better365.iBar": "iBar",
    ]

    /// Other notch / HUD apps that draw at the same spot.
    static let notchApps: [String: String] = [
        "theboringteam.boringnotch": "boring.notch",
        "lo.cafe.NotchNook": "NotchNook",
        "com.henrikruscon.Alcove": "Alcove",
        "com.tweety.MediaMate": "MediaMate",
        "pl.maketheweb.TopNotch": "TopNotch",
    ]

    /// Names to match when a bundle ID differs between editions.
    static let menuBarManagerNames: Set<String> = ["Ice", "Bartender 4", "Bartender 5", "Bartender", "Hidden Bar", "Dozer", "Vanilla", "iBar"]
    static let notchAppNames: Set<String> = ["boring.notch", "NotchNook", "Alcove", "MediaMate", "Atoll", "TopNotch", "DynamicLake"]

    /// Uses fn for its own dictation (verified: the installed Wispr Flow).
    static let fnDictationApps: [String: String] = ["com.electron.wispr-flow": "Wispr Flow"]

    static func isMenuBarManager(bundleID: String?, name: String?) -> Bool {
        if let bundleID, menuBarManagers[bundleID] != nil { return true }
        if let name, menuBarManagerNames.contains(name) { return true }
        return false
    }

    static func notchAppName(bundleID: String?, name: String?) -> String? {
        if let bundleID, let known = notchApps[bundleID] { return known }
        if let name, notchAppNames.contains(name) { return name }
        return nil
    }
}

enum IslandCoexistenceRules {
    /// `CGWindowLevelForKey(.statusWindow)`, macOS's status-bar level (25).
    static let statusLevel = 25
    /// `CGWindowLevelForKey(.mainMenuWindow)` (24).
    static let mainMenuLevel = 24

    /// Windows of other (non-Apple) apps parked over the notch at or above
    /// the menu bar: another notch app fighting for the same spot.
    /// Full-screen overlays (screen dimmers, cursor highlighters, capture
    /// and presentation tools) and a manager's stretched divider are not
    /// islands: anything wider than half the screen, or reaching more than
    /// `maxDepth` below the menu bar, is skipped. A `nil` bundle ID passes,
    /// so the caller can look IDs up only for the windows that survive and
    /// run the rule again.
    static func notchOccupants(_ windows: [IslandForeignWindow], notchRect: CGRect, ownPID: Int32,
                               screenWidth: CGFloat = .greatestFiniteMagnitude) -> [IslandForeignWindow] {
        guard notchRect.width > 0, notchRect.height > 0 else { return [] }
        let center = CGPoint(x: notchRect.midX, y: notchRect.midY)
        return windows.filter { w in
            guard w.pid != ownPID, w.layer >= statusLevel, !(w.bundleID?.hasPrefix("com.apple.") ?? false) else { return false }
            guard w.bounds.width <= screenWidth * 0.5, w.bounds.minY >= notchRect.minY - maxDepth else { return false }
            let overlap = w.bounds.intersection(notchRect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return false }
            // A status item next to the notch overlaps a sliver; another
            // island sits across the middle or covers a good part of it.
            return w.bounds.contains(center) || overlap.width * overlap.height >= 0.25 * notchRect.width * notchRect.height
        }
    }

    /// How far below the menu bar another app's island may reach (an open
    /// notch drawer); deeper windows are overlays, not islands.
    static let maxDepth: CGFloat = 400

    /// A menu bar manager's own bar (Ice Bar, Bartender Bar…) hanging under
    /// or over the island. Status-item-shaped windows in the menu bar row
    /// are not bars: Ice, Hidden Bar and Dozer hide items by stretching a
    /// divider item to about 10,000 pt, which sits across the notch while
    /// the hidden section is collapsed (their normal state). So a bar must
    /// reach below the menu bar row, be narrower than 80 % of the screen,
    /// and overlap the island horizontally while touching it vertically.
    static func managerBarCovers(_ windows: [IslandForeignWindow], managerPIDs: Set<Int32>, zone: CGRect,
                                 menuBar: CGRect) -> Bool {
        guard !managerPIDs.isEmpty, zone.width > 0, menuBar.width > 0 else { return false }
        return windows.contains { w in
            let b = w.bounds
            guard managerPIDs.contains(w.pid), w.layer >= mainMenuLevel, b.width > 1, b.height > 1 else { return false }
            guard b.minY < menuBar.minY - 1, b.width <= menuBar.width * 0.8 else { return false }
            return b.maxX > zone.minX && b.minX < zone.maxX && b.maxY >= zone.minY - 8 && b.minY < zone.maxY
        }
    }

    /// The step-aside re-check: twice a second, at most this many times
    /// (10 s), then the island comes back until the pointer next arrives.
    static let stepAsideRecheckLimit = 20
    static let stepAsideRecheckMilliseconds = 500
}

// MARK: - Sizing

enum IslandSizing {
    /// The closed island grown by `extra` points (half on each side),
    /// rounded to the pixel grid.
    static func collapsedWidth(_ base: CGFloat, extra: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(1, scale)
        return ((base + max(0, extra)) * s).rounded() / s
    }

    /// The hover cue in Click and Press and Hold: the resting island grows
    /// this much while the pointer is on it.
    static let primedGrowth = CGSize(width: 10, height: 2)
}
