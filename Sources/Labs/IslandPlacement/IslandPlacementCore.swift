import CoreGraphics
import Foundation

// Island placement and visibility: the pure decisions (no AppKit), so the
// test harness can compile this file on its own.
//
// - Which display shows the island (`IslandDisplayResolver`).
// - Where it sits and how big it is there (`IslandGeometry`): the real
//   notch width from the screen's auxiliary top areas, a floating pill, or
//   nothing at rest (Minimal).
// - Whether it shows at all (`IslandVisibility`): full screen, excluded
//   apps, clamshell, displays without a notch, a manual hide, a quiet
//   Smart Moment, and what still shows while it is hidden.
// - Which displays are covered by a full-screen window
//   (`IslandFullScreenDetector`), from window bounds alone.

// MARK: - Style presets

/// How the island looks on one display. Saved per display (by its UUID).
enum IslandStylePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The black notch silhouette, flaring into the menu bar.
    case notch
    /// A detached Dynamic Island capsule.
    case pill
    /// Nothing at rest: the island appears for live activities and when
    /// the pointer reaches it.
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: "Notch"
        case .pill: "Pill"
        case .minimal: "Minimal"
        }
    }

    var summary: String {
        switch self {
        case .notch: "Grows out of the camera notch"
        case .pill: "A floating Dynamic Island capsule"
        case .minimal: "Hidden until something happens"
        }
    }

    var systemImage: String {
        switch self {
        case .notch: "rectangle.topthird.inset.filled"
        case .pill: "capsule.fill"
        case .minimal: "minus"
        }
    }

    /// Notch on a notched built-in display, a pill everywhere else (a fake
    /// notch on a display without one only covers the menu bar).
    static func defaultPreset(hasNotch: Bool) -> IslandStylePreset {
        hasNotch ? .notch : .pill
    }
}

/// How snugly the resting island wraps the camera housing.
enum IslandNotchFit: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 17.5 pt of island on each side of the housing (the 220 pt island on
    /// a 16-inch MacBook Pro).
    case standard
    /// Exactly the housing: at rest the island is indistinguishable from
    /// the hardware notch.
    case snug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .snug: "Exact Notch"
        }
    }

    /// Island beside each edge of the housing, in points.
    var shoulder: CGFloat {
        switch self {
        case .standard: 17.5
        case .snug: 1
        }
    }
}

/// Which display the island lives on.
enum IslandDisplayMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The built-in display while it is on, else the main display.
    case automatic
    /// Only the built-in display; hidden while the lid is closed.
    case builtIn
    /// The display with the menu bar (System Settings › Displays).
    case main
    /// One display the user picked, remembered by its UUID.
    case specific
    /// Moves to the display the pointer is on (only while closed, after a second).
    case followPointer
    /// An island on every display; the one you reach for opens.
    case allDisplays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .builtIn: "Built-in Display Only"
        case .main: "Main Display"
        case .specific: "A Specific Display"
        case .followPointer: "Follow the Pointer"
        case .allDisplays: "All Displays"
        }
    }

    var summary: String {
        switch self {
        case .automatic: "The built-in display while it is open, otherwise the main display."
        case .builtIn: "Only the MacBook's own screen. Hidden while the lid is closed."
        case .main: "The display with the menu bar."
        case .specific: "Always the display you pick. If it is unplugged, the island waits on the main display and moves back when it returns."
        case .followPointer: "Moves to the display the pointer is on, a second after you arrive, never while it is open."
        case .allDisplays: "An island on every display. The one you reach for opens; the others mirror it."
        }
    }

    /// The island moves with the pointer.
    var followsPointer: Bool { self == .followPointer || self == .allDisplays }
}

/// What an excluded app does to the island.
enum IslandExclusionBehavior: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The island stays visible but never opens on hover or a drag.
    case ignoreHover
    /// The island hides while the app is in front.
    case hide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ignoreHover: "Don’t Open on Hover"
        case .hide: "Hide the Island"
        }
    }
}

/// On a display without a notch whose menu bar hides itself.
enum IslandMenuBarAutoHideBehavior: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Hide with the menu bar; pushing the pointer to the top brings it back.
    case hideWithMenuBar
    /// Keep the resting island over the top of the screen.
    case keepVisible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hideWithMenuBar: "Hide with the Menu Bar"
        case .keepVisible: "Keep Showing"
        }
    }
}

// MARK: - Displays

/// One connected display, as the resolver sees it.
struct IslandDisplayInfo: Equatable, Sendable, Identifiable {
    /// CGDirectDisplayID (changes across reboots and replugs: never saved).
    var id: UInt32
    /// Stable identity (CGDisplayCreateUUIDFromDisplayID), saved in settings.
    var uuid: String
    var name: String
    var isBuiltIn: Bool
    var hasNotch: Bool
    /// The display with the menu bar.
    var isMain: Bool
}

struct IslandDisplayResolution: Equatable, Sendable {
    /// Where the island is, or nil (hidden: e.g. Built-in Only with the lid closed).
    var island: IslandDisplayInfo?
    /// Mirrors on the other displays (All Displays only).
    var mirrors: [IslandDisplayInfo] = []
    /// The saved display is missing; the island waits elsewhere.
    var isFallback = false
}

enum IslandDisplayResolver {
    /// The built-in display while it is active, else the main one, else the first.
    static func automatic(_ displays: [IslandDisplayInfo]) -> IslandDisplayInfo? {
        displays.first(where: \.isBuiltIn) ?? displays.first(where: \.isMain) ?? displays.first
    }

    /// Never moves on its own: only the mode, the saved display, the
    /// pointer (follow modes) and the display set decide.
    static func resolve(
        mode: IslandDisplayMode,
        savedUUID: String?,
        displays: [IslandDisplayInfo],
        pointerDisplayID: UInt32?,
        currentDisplayID: UInt32?
    ) -> IslandDisplayResolution {
        guard !displays.isEmpty else { return IslandDisplayResolution(island: nil) }
        switch mode {
        case .automatic:
            return IslandDisplayResolution(island: automatic(displays))
        case .builtIn:
            return IslandDisplayResolution(island: displays.first(where: \.isBuiltIn))
        case .main:
            return IslandDisplayResolution(island: displays.first(where: \.isMain) ?? displays.first)
        case .specific:
            if let savedUUID, let match = displays.first(where: { $0.uuid == savedUUID }) {
                return IslandDisplayResolution(island: match)
            }
            // Wait on the automatic display without forgetting the choice,
            // so the island returns when the monitor reconnects.
            return IslandDisplayResolution(island: automatic(displays), isFallback: savedUUID != nil)
        case .followPointer, .allDisplays:
            let island = pointerDisplayID.flatMap { id in displays.first { $0.id == id } }
                ?? currentDisplayID.flatMap { id in displays.first { $0.id == id } }
                ?? automatic(displays)
            let mirrors = mode == .allDisplays ? displays.filter { $0.id != island?.id } : []
            return IslandDisplayResolution(island: island, mirrors: mirrors)
        }
    }
}

// MARK: - Geometry

/// What the controller reads off an NSScreen (all in points, AppKit
/// coordinates with the origin at the bottom left of the main display).
struct IslandScreenMetrics: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    /// Widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (nil
    /// without a notch).
    var auxLeftWidth: CGFloat?
    var auxRightWidth: CGFloat?
    var backingScale: CGFloat
}

struct IslandGeometryOptions: Equatable, Sendable {
    var style: IslandStylePreset = .notch
    var fit: IslandNotchFit = .standard
    /// Pill height on a display without a notch.
    var pillHeight: CGFloat = IslandGeometry.defaultPillHeight
    /// Gap between the screen's top edge and the pill (0 allowed).
    var pillTopMargin: CGFloat = IslandGeometry.defaultPillTopMargin
    var menuBarAutoHide: IslandMenuBarAutoHideBehavior = .hideWithMenuBar
    /// Minimal: a 3 pt hairline at rest instead of nothing.
    var minimalHairline = true
}

/// The silhouette the view draws.
enum IslandSurfaceKind: String, Equatable, Sendable {
    /// Concave shoulders flaring into the top edge (glance's NotchShape).
    case notch
    /// A capsule with every corner rounded.
    case pill
}

/// Where the island sits on one display and how big it is at rest.
struct IslandGeometry: Equatable, Sendable {
    /// Camera housing of the 14- and 16-inch MacBook Pro at default
    /// scaling, used when a notched screen reports no auxiliary areas.
    static let fallbackHousing: CGFloat = 185
    /// The empty middle of a pill on a display without a camera: compact
    /// content sits either side of it, as it does around a real housing.
    static let pillHousing: CGFloat = 150
    static let defaultPillHeight: CGFloat = 22
    static let defaultPillTopMargin: CGFloat = 0
    static let pillHeightRange: ClosedRange<CGFloat> = 14...40
    static let pillTopMarginRange: ClosedRange<CGFloat> = 0...48
    /// A housing outside this range is a bad reading; use the fallback.
    static let plausibleHousing: ClosedRange<CGFloat> = 100...320
    /// Height of the top-edge strip that reveals a hidden resting island.
    static let revealStripHeight: CGFloat = 3

    var hasNotch: Bool
    var housingWidth: CGFloat
    /// Screen x of the camera's center (or the screen's center).
    var centerX: CGFloat
    /// The screen's top edge.
    var screenTop: CGFloat
    /// Gap between the top edge and the island (pill on a display without a notch).
    var topInset: CGFloat
    var collapsedSize: CGSize
    var menuBarHeight: CGFloat
    /// The menu bar hides itself on this display (no notch, frame.maxY ==
    /// visibleFrame.maxY).
    var menuBarAutoHidden: Bool
    var surface: IslandSurfaceKind
    /// Nothing is drawn at rest (Minimal, or with an auto-hidden menu bar).
    var restsHidden: Bool
    var showsHairline: Bool
    var style: IslandStylePreset
    var backingScale: CGFloat

    static func make(_ m: IslandScreenMetrics, _ o: IslandGeometryOptions) -> IslandGeometry {
        let scale = max(1, m.backingScale)
        let hasNotch = m.safeAreaTop > 0
        let menuBar = max(0, m.frame.maxY - m.visibleFrame.maxY)
        let autoHidden = !hasNotch && m.visibleFrame.maxY >= m.frame.maxY - 0.5

        // Real notch width: the screen minus the two usable top areas.
        var housing = fallbackHousing
        var centerX = m.frame.midX
        if hasNotch, let left = m.auxLeftWidth, let right = m.auxRightWidth {
            let measured = m.frame.width - left - right
            if plausibleHousing.contains(measured) {
                housing = measured
                centerX = m.frame.minX + left + measured / 2
            }
        }

        let surface: IslandSurfaceKind
        var topInset: CGFloat = 0
        let size: CGSize
        if hasNotch {
            let height = m.safeAreaTop
            surface = o.style == .pill ? .pill : .notch
            // A pill's rounded top corners must stay outside the housing.
            let shoulder = o.style == .pill ? max(o.fit.shoulder, height / 2 + 1) : o.fit.shoulder
            size = CGSize(width: housing + 2 * shoulder, height: height)
        } else if o.style == .notch {
            // Today's island on an external display: the 220 pt notch
            // shape, resting inside the menu bar.
            housing = fallbackHousing
            surface = .notch
            size = CGSize(width: housing + 2 * IslandNotchFit.standard.shoulder, height: menuBar > 0 ? menuBar : 24)
        } else {
            housing = pillHousing
            surface = .pill
            let height = min(max(o.pillHeight, pillHeightRange.lowerBound), pillHeightRange.upperBound)
            topInset = min(max(o.pillTopMargin, pillTopMarginRange.lowerBound), pillTopMarginRange.upperBound)
            size = CGSize(width: housing + 2 * IslandNotchFit.standard.shoulder, height: height)
        }

        let hidesWithMenuBar = autoHidden && o.menuBarAutoHide == .hideWithMenuBar
        let restsHidden = o.style == .minimal || hidesWithMenuBar
        return IslandGeometry(
            hasNotch: hasNotch,
            housingWidth: round(housing, scale),
            centerX: round(centerX, scale),
            screenTop: m.frame.maxY,
            topInset: round(topInset, scale),
            collapsedSize: CGSize(width: round(size.width, scale), height: round(size.height, scale)),
            menuBarHeight: menuBar,
            menuBarAutoHidden: autoHidden,
            surface: surface,
            restsHidden: restsHidden,
            // The hardware notch already marks the spot on a notched display.
            showsHairline: restsHidden && o.style == .minimal && o.minimalHairline && !hasNotch,
            style: o.style,
            backingScale: scale
        )
    }

    /// Rounds to the display's pixel grid so no hairline shows at the edges.
    static func round(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    private func px(_ value: CGFloat) -> CGFloat { Self.round(value, backingScale) }

    /// Screen rect of the resting island: the hover hot zone.
    var notchRect: CGRect {
        CGRect(
            x: px(centerX - collapsedSize.width / 2),
            y: px(screenTop - topInset - collapsedSize.height),
            width: collapsedSize.width,
            height: collapsedSize.height
        )
    }

    /// The thin strip at the top edge that wakes a resting island that
    /// draws nothing (Minimal without a notch, an auto-hidden menu bar).
    var revealStrip: CGRect {
        CGRect(x: notchRect.minX, y: screenTop - Self.revealStripHeight, width: notchRect.width, height: Self.revealStripHeight)
    }

    /// Panel frame for an open drawer of `expanded` size (flare included)
    /// plus a theme's glow `outset` on the left, right and bottom. It always
    /// reaches the top edge: a pill's top margin is inside it, so the open
    /// drawer and bands can fill the gap (no menu-bar sliver above them).
    func panelFrame(expanded: CGSize, outset: CGFloat) -> CGRect {
        CGRect(
            x: px(centerX - expanded.width / 2 - outset),
            y: px(screenTop - topInset - expanded.height - outset),
            width: px(expanded.width + 2 * outset),
            height: px(expanded.height + outset + topInset)
        )
    }

    /// A hover zone grown up to the top edge across its width, so a pointer
    /// pushed against the edge above a floating pill (or a revealed Minimal
    /// island) is still on it: the edge stays a Fitts target.
    func reachingTopEdge(_ zone: CGRect) -> CGRect {
        guard !hasNotch, zone.maxY < screenTop else { return zone }
        return CGRect(x: zone.minX, y: zone.minY, width: zone.width, height: screenTop - zone.minY)
    }
}

// MARK: - Visibility

/// Why the island is hidden right now.
enum IslandHideReason: String, CaseIterable, Sendable, Comparable {
    case sessionInactive
    case noDisplay
    case noNotch
    case clamshell
    case fullScreen
    case excludedApp
    case quiet
    case manual

    static func < (lhs: IslandHideReason, rhs: IslandHideReason) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Short status for Settings and the gear menu.
    var title: String {
        switch self {
        case .sessionInactive: "Another user is active"
        case .noDisplay: "The chosen display isn’t connected"
        case .noNotch: "This display has no notch"
        case .clamshell: "The lid is closed"
        case .fullScreen: "An app is full screen"
        case .excludedApp: "An excluded app is in front"
        case .quiet: "Quieted by a Smart Moment"
        case .manual: "You hid it"
        }
    }

    /// A reveal (top edge, hotkey) can't bring the island back for these.
    var isHard: Bool { self == .sessionInactive || self == .noDisplay }
}

/// What ⌃⌥H does, given the island's state.
enum IslandHotkeyAction: Equatable, Sendable {
    /// Shown for now over a hide (top edge, hotkey, an opened drawer): end it.
    case endReveal
    /// Hidden by the user: show it again and open it.
    case unhideAndOpen
    /// Hidden for full screen, an excluded app or a Smart Moment: show it
    /// for now and open it.
    case revealAndOpen
    /// Nothing can bring it back (no display, another user).
    case none
    /// Showing: hide it.
    case hide

    static func decide(isRevealed: Bool, isManuallyHidden: Bool, decision: IslandVisibilityDecision) -> IslandHotkeyAction {
        if isManuallyHidden { return .unhideAndOpen }
        if isRevealed { return .endReveal }
        if decision.reasons.contains(where: \.isHard) { return .none }
        if decision.isHidden { return .revealAndOpen }
        return .hide
    }
}

/// Capture privacy: which windows belong to their owner.
enum IslandCaptureRule {
    /// A window already excluded from capture that SparkV's setting neither
    /// set nor was asked to manage hides itself on purpose (Clicky's
    /// pointer, the edge glows): never touch it, on or off.
    static func isOwnerManaged(isManagedByUs: Bool, isRegistered: Bool, alreadyHidden: Bool) -> Bool {
        !isManagedByUs && !isRegistered && alreadyHidden
    }
}

struct IslandVisibilityInputs: Equatable, Sendable {
    var sessionActive = true
    var hasDisplay = true
    var displayHasNotch = true
    var showOnDisplaysWithoutNotch = true
    var builtInDisplayActive = true
    var hideInClamshell = false
    var isFullScreen = false
    var hideInFullScreen = true
    var frontAppExcluded = false
    var exclusionBehavior: IslandExclusionBehavior = .ignoreHover
    var manuallyHidden = false
    var quiet = false
    /// The pointer pushed against the top edge or the hotkey brought it back.
    /// Never overrides a manual hide (only the hotkey or the menu undoes that).
    var revealed = false
    /// The drawer was opened from the keyboard or another feature (a
    /// clipboard hotkey, a link, a Smart Moment) while the island was hidden:
    /// it shows until the drawer closes, a manual hide included.
    var drawerRevealed = false
    /// The drawer is open and a drag or menu is in progress: never pull it away.
    var isInteracting = false
    /// A volume or brightness band is on the island.
    var hudShowing = false
    var showsHUDWhileHidden = true
    /// SparkV swallows the volume/brightness keys: without its band there
    /// would be no feedback at all, so it always shows.
    var systemHUDReplaced = false
    /// Dictation or Clicky is listening, thinking or answering.
    var voiceShowing = false
    var showsVoiceWhileHidden = true
    /// A call is ringing (Labs/Activities): its band shows through a soft
    /// hide such as full screen, like a HUD, so it can be answered.
    var callRinging = false
    /// The island has no display of its own but is laid out on the main
    /// display for the volume/brightness band (see `needsHUDFallback`).
    var hasHUDFallbackDisplay = false
}

struct IslandVisibilityDecision: Equatable, Sendable {
    /// Empty when the island is shown normally.
    var reasons: [IslandHideReason] = []
    /// Hidden, but ordered in for a HUD or voice band (no hover).
    var isPassThrough = false
    /// Visible, but hovering and drags don't open it.
    var ignoresHover = false
    /// The island has no display, yet SparkV replaces the system volume and
    /// brightness HUD: the keys must go back to macOS (or the band must show
    /// elsewhere), or the user gets no feedback at all.
    var needsHUDFallback = false

    var isHidden: Bool { !reasons.isEmpty }
    /// The panel is ordered in.
    var isOnScreen: Bool { reasons.isEmpty || isPassThrough }

    static let shown = IslandVisibilityDecision()
}

enum IslandVisibility {
    static func decide(_ i: IslandVisibilityInputs) -> IslandVisibilityDecision {
        var reasons: [IslandHideReason] = []
        if !i.sessionActive { reasons.append(.sessionInactive) }
        if !i.hasDisplay { reasons.append(.noDisplay) }
        if i.hasDisplay, !i.displayHasNotch, !i.showOnDisplaysWithoutNotch { reasons.append(.noNotch) }
        if !i.builtInDisplayActive, i.hideInClamshell { reasons.append(.clamshell) }
        if i.isFullScreen, i.hideInFullScreen { reasons.append(.fullScreen) }
        if i.frontAppExcluded, i.exclusionBehavior == .hide { reasons.append(.excludedApp) }
        if i.quiet { reasons.append(.quiet) }
        if i.manuallyHidden { reasons.append(.manual) }

        // Soft reasons give way to an opened drawer and an interaction in
        // progress; a top-edge or hotkey reveal leaves a manual hide alone.
        if i.drawerRevealed || i.isInteracting {
            reasons.removeAll { !$0.isHard }
        } else if i.revealed {
            reasons.removeAll { !$0.isHard && $0 != .manual }
        }

        var decision = IslandVisibilityDecision(reasons: reasons)
        if decision.isHidden, !reasons.contains(where: \.isHard) {
            let hud = i.hudShowing && (i.showsHUDWhileHidden || i.systemHUDReplaced)
            let voice = i.voiceShowing && i.showsVoiceWhileHidden
            decision.isPassThrough = hud || voice || i.callRinging
        }
        // No display for the island while SparkV swallows the volume and
        // brightness keys: something else must show the feedback.
        decision.needsHUDFallback = reasons.contains(.noDisplay) && i.sessionActive && i.systemHUDReplaced
        if decision.needsHUDFallback, i.hasHUDFallbackDisplay, i.hudShowing { decision.isPassThrough = true }
        decision.ignoresHover = decision.isPassThrough
            || (!decision.isHidden && i.frontAppExcluded && i.exclusionBehavior == .ignoreHover && !i.revealed)
        return decision
    }
}

// MARK: - Excluded apps

enum IslandExclusions {
    /// SparkV itself never counts: its own settings windows make it the
    /// front app for a moment.
    static func isExcluded(bundleID: String?, list: [String], ownBundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty, bundleID != ownBundleID else { return false }
        return list.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Adds (at the end) or removes, keeping the list free of duplicates.
    static func toggled(_ bundleID: String, in list: [String], on: Bool) -> [String] {
        var result = list.filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
        if on, !bundleID.isEmpty { result.append(bundleID) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Full-screen detection

/// One on-screen window from CGWindowListCopyWindowInfo (CG coordinates:
/// origin at the top left of the main display, y down).
struct IslandWindowSample: Equatable, Sendable {
    var number: Int
    var pid: Int32
    var owner: String
    var layer: Int
    var alpha: Double
    var bounds: CGRect
}

/// One display in CG coordinates (`CGDisplayBounds`).
struct IslandDisplayBounds: Equatable, Sendable {
    var id: UInt32
    var bounds: CGRect
    /// Notch height (0 without a notch).
    var safeAreaTop: CGFloat
}

enum IslandFullScreenDetector {
    /// System UI that covers a display without being "full screen":
    /// Mission Control and Launchpad (Dock), the lock screen, the menu bar.
    static let systemOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center",
        "WindowManager", "Spotlight", "loginwindow", "TextInputMenuAgent", "Wallpaper",
        "screencaptureui", "Screenshot",
    ]
    static let tolerance: CGFloat = 1.5

    enum Coverage: Equatable, Sendable {
        /// Edge to edge, menu bar area included: a game, an in-place video,
        /// a slideshow, Quick Look full screen, a native full-screen
        /// window on a display without a notch.
        case exact
        /// Full width from just below the notch to the bottom: native full
        /// screen on a notched display, but also a zoomed window when the
        /// Dock hides itself. Needs confirming.
        case belowNotch
    }

    struct Candidate: Equatable, Sendable {
        var displayID: UInt32
        var window: IslandWindowSample
        var coverage: Coverage
    }

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < tolerance }

    static func coverage(of w: CGRect, on d: IslandDisplayBounds) -> Coverage? {
        let spansWidth = near(w.minX, d.bounds.minX) && near(w.width, d.bounds.width)
        guard spansWidth, near(w.maxY, d.bounds.maxY) else { return nil }
        if near(w.minY, d.bounds.minY) { return .exact }
        if d.safeAreaTop > 0, near(w.minY, d.bounds.minY + d.safeAreaTop) { return .belowNotch }
        return nil
    }

    static func isCandidateWindow(_ w: IslandWindowSample, ownPID: Int32) -> Bool {
        w.pid != ownPID && w.layer >= 0 && w.alpha > 0.5 && !systemOwners.contains(w.owner)
            && w.bounds.width > 100 && w.bounds.height > 100
    }

    static func candidates(windows: [IslandWindowSample], displays: [IslandDisplayBounds], ownPID: Int32) -> [Candidate] {
        var result: [Candidate] = []
        for window in windows where isCandidateWindow(window, ownPID: ownPID) {
            for display in displays {
                if let coverage = coverage(of: window.bounds, on: display) {
                    result.append(Candidate(displayID: display.id, window: window, coverage: coverage))
                }
            }
        }
        return result
    }

    /// Displays covered by a full-screen window. `confirm` decides the
    /// ambiguous below-the-notch case (Accessibility's AXFullScreen when
    /// allowed, else a Dock heuristic).
    static func fullScreenDisplays(
        windows: [IslandWindowSample],
        displays: [IslandDisplayBounds],
        ownPID: Int32,
        confirm: (Candidate) -> Bool
    ) -> Set<UInt32> {
        var covered: Set<UInt32> = []
        for candidate in candidates(windows: windows, displays: displays, ownPID: ownPID)
            where !covered.contains(candidate.displayID) {
            if candidate.coverage == .exact || confirm(candidate) { covered.insert(candidate.displayID) }
        }
        return covered
    }

    /// Apps that go full screen (a slideshow, a player's full-screen mode)
    /// without a Space change and without a large window first.
    static let presenterBundleIDs: Set<String> = [
        "com.apple.iWork.Keynote", "com.microsoft.Powerpoint", "com.apple.Preview",
        "com.apple.QuickTimePlayerX", "com.colliderli.iina", "org.videolan.vlc",
    ]

    static func isPresenter(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return presenterBundleIDs.contains(bundleID)
    }

    /// Displays whose desktop picture is on screen (owner "Wallpaper", or
    /// the Dock's desktop window on older systems, below layer 0, covering
    /// the display). nil when none is listed at all: the hint is unavailable.
    static func wallpaperDisplays(windows: [IslandWindowSample], displays: [IslandDisplayBounds]) -> Set<UInt32>? {
        var result: Set<UInt32> = []
        var sawAny = false
        for window in windows where window.layer < 0 && (window.owner == "Wallpaper" || window.owner == "Dock") {
            for display in displays where coverage(of: window.bounds, on: display) == .exact {
                sawAny = true
                result.insert(display.id)
            }
        }
        return sawAny ? result : nil
    }

    /// The ambiguous below-the-notch candidate: Accessibility's answer when
    /// there is one; else a window reaching past a visible Dock can only be
    /// full screen; with the Dock hidden, a display without its desktop
    /// picture is in a full-screen Space. No hint at all: not full screen.
    static func confirmBelowNotch(ax: Bool?, dockHides: Bool, wallpaperDisplays: Set<UInt32>?, displayID: UInt32) -> Bool {
        if let ax { return ax }
        if !dockHides { return true }
        guard let wallpaperDisplays else { return false }
        return !wallpaperDisplays.contains(displayID)
    }

    /// True when `pid` has a window filling nearly all of one of `displays`:
    /// full screen may follow in place (a video's own full-screen button),
    /// so the watcher keeps a slow, tolerant check running. A merely
    /// maximized browser or editor (menu bar and Dock visible) stays under
    /// the threshold.
    static func hasLargeWindow(pid: Int32?, windows: [IslandWindowSample], displays: [IslandDisplayBounds], fraction: CGFloat = 0.97) -> Bool {
        guard let pid else { return false }
        for window in windows where window.pid == pid && window.layer >= 0 {
            for display in displays {
                let overlap = window.bounds.intersection(display.bounds)
                guard !overlap.isNull, display.bounds.width > 0, display.bounds.height > 0 else { continue }
                // It must also reach the menu-bar row: a window zoomed with
                // the green button (menu bar still showing) can pass 97% on
                // a laptop with the Dock hidden, and would hold the poll on.
                guard window.bounds.minY <= display.bounds.minY + 1 else { continue }
                if overlap.width * overlap.height >= fraction * display.bounds.width * display.bounds.height { return true }
            }
        }
        return false
    }
}

// MARK: - Black menu bar

enum IslandBlackBarGeometry {
    /// NSImageScaling raw values (AppKit's enum, kept numeric here).
    static let scaleProportionallyDown: UInt = 0
    static let scaleAxesIndependently: UInt = 1
    static let scaleNone: UInt = 2
    static let scaleProportionallyUpOrDown: UInt = 3

    /// Where the original picture lands on a canvas of `canvas` pixels,
    /// the way the desktop draws it with these options (CG coordinates,
    /// origin bottom left). Unknown options fill the screen, like macOS.
    static func drawRect(image: CGSize, canvas: CGSize, scaling: UInt?, allowClipping: Bool?) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let fill = max(canvas.width / image.width, canvas.height / image.height)
        let fit = min(canvas.width / image.width, canvas.height / image.height)
        let factor: CGFloat
        switch scaling ?? scaleProportionallyUpOrDown {
        case scaleAxesIndependently:
            return CGRect(origin: .zero, size: canvas)
        case scaleNone:
            factor = 1
        case scaleProportionallyDown:
            factor = min(1, allowClipping == true ? fill : fit)
        default:
            factor = allowClipping == false ? fit : fill
        }
        let size = CGSize(width: image.width * factor, height: image.height * factor)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The black band in pixels: the notch height (the menu bar on a
    /// notched display), rounded up so no wallpaper row peeks through.
    static func bandPixels(safeAreaTop: CGFloat, menuBarHeight: CGFloat, scale: CGFloat) -> Int {
        Int((max(safeAreaTop, menuBarHeight) * max(1, scale)).rounded(.up))
    }

    /// Aerial and other live wallpapers are bundles or movies; a still copy
    /// would silently replace them, so they are left alone.
    static func canComposite(pathExtension ext: String) -> Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"].contains(ext.lowercased())
    }
}

/// Black Menu Bar's restore records and generated pictures.
enum IslandBlackBarRecords {
    /// The record keys to keep: every one in use, then the newest by
    /// `savedAt` up to `limit` in all.
    static func kept(savedAt: [String: Double], limit: Int, inUse: Set<String>) -> Set<String> {
        var keep = Set(savedAt.keys.filter { inUse.contains($0) })
        let rest = savedAt.filter { !inUse.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (key, _) in rest where keep.count < limit { keep.insert(key) }
        return keep
    }

    /// Generated pictures to delete: those no record or screen uses.
    static func unusedPictures(_ paths: [String], keep: Set<String>) -> [String] {
        paths.filter { !keep.contains($0) }.sorted()
    }
}

/// Clamshell: a Mac with a lid whose built-in panel isn't lit.
enum IslandClamshell {
    static func builtInActive(builtInLit: Bool, hasLid: Bool) -> Bool {
        builtInLit || !hasLid
    }
}
