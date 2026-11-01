import SwiftUI

/// Fixed geometry for the 16-inch MacBook Pro notch and the expanded drawer.
enum NotchMetrics {
    /// Resting frame that overlaps the physical camera cutout.
    static let collapsedSize = CGSize(width: 220, height: 38)
    /// Fully expanded drawer: 540 pt wide by default, wider with Settings ›
    /// Appearance › Island Size (Labs/IslandInteraction). The height is the
    /// standard tab's; tall tabs and the Agents hub set their own below.
    static var expandedSize: CGSize {
        CGSize(width: IslandInteractionStore.current.drawerSize.width, height: 115)
    }
    static let bottomCornerRadius: CGFloat = 12
    /// Silhouette radii (values from glance). The flare is drawn outside the
    /// body, so the panel is `expandedSize.width + 2 * openFlareRadius` wide.
    static let closedFlareRadius: CGFloat = 8
    static let closedBottomRadius: CGFloat = 12
    static let activityFlareRadius: CGFloat = 10
    static let activityBottomRadius: CGFloat = 18
    static let openFlareRadius: CGFloat = 16
    static let openBottomRadius: CGFloat = 32
    /// Pill style (no flare): corner radius of the open drawer and of the
    /// band under a closed pill. At rest the pill is a capsule.
    static let pillOpenRadius: CGFloat = 26
    static let pillBandRadius: CGFloat = 20
    /// The open drawer's header row is at least this tall on a pill, so
    /// the 22 pt header icons keep a little air under a slim pill.
    static let pillHeaderMinHeight: CGFloat = 28
    /// The Tray's, the converter's and the clipboard's large cards (and the
    /// Agents hub, Search results and Downloads list) need a taller drawer
    /// than the other tabs.
    static let trayExpandedHeight: CGFloat = 160
    /// Tabs that use the tall drawer.
    static let tallTabs: Set<NotchState.Tab> = [.tray, .converter, .clipboard, .search, .downloads, .widgets, .replyDrafter, .fans, .status, .colorPicker]
    /// The Agents hub grows with its rows of tiles: header band, rows and
    /// the drawer's bottom padding (`AgentHubMetrics`).
    static var agentsExpandedHeight: CGFloat {
        // Category bar, rows of tiles (+4 for two-line labels), see AgentHubMetrics.
        return collapsedSize.height + AgentHubMetrics.contentHeight + drawerBottomPadding
    }
    /// Space under the tab content inside the open drawer.
    static let drawerBottomPadding: CGFloat = 8
    /// The Dev tab: an approval card plus three session rows.
    static let devStatusExpandedHeight: CGFloat = 200
    /// The Menu Bar tab: its header and two rows of icon tiles.
    static var menuBarExpandedHeight: CGFloat {
        collapsedSize.height + MenuBarOverflowMetrics.contentHeight + drawerBottomPadding
    }

    static func expandedSize(for tab: NotchState.Tab) -> CGSize {
        let height: CGFloat = if tab == .agents {
            agentsExpandedHeight
        } else if tab == .devStatus {
            devStatusExpandedHeight
        } else if tab == .menuBar {
            menuBarExpandedHeight
        } else if tallTabs.contains(tab) {
            trayExpandedHeight
        } else if tab == .today {
            // The Planner (Labs/Planner): rail and pages, 508×114 pt.
            trayExpandedHeight
        } else {
            expandedSize.height
        }
        // Text Size: the content area grows with the zoom (Look & Layout).
        return LookDrawerMetrics.zoomed(CGSize(width: expandedSize.width, height: height),
                                        header: collapsedSize.height, bottomInset: drawerBottomPadding)
    }

    /// Window size for a tab: the open drawer plus its flare on both sides.
    static func panelSize(for tab: NotchState.Tab) -> CGSize {
        let body = expandedSize(for: tab)
        return CGSize(width: body.width + 2 * openFlareRadius, height: body.height)
    }

    static var panelSize: CGSize { panelSize(for: .nook) }
    /// Grace period before a top-edge reveal ends after the pointer leaves.
    /// The drawer's own close delay is a setting (Island Interaction:
    /// Close After, 0.5 s by default).
    static let collapseDelay: Duration = .milliseconds(500)
    /// The island's open/close and hover spring: interruptible (it keeps
    /// its velocity when the pointer reverses mid-motion). Calm by default
    /// (response 0.35 / damping 0.8, bounce about 0.2); Settings ›
    /// Appearance › Island Motion picks Calm, Snappy, No Bounce or Instant
    /// and a speed. The Core Animation spring of the Ambient Light outline
    /// and `NotchThemeTiming.islandSpring` follow the same tuning.
    /// Reduce Motion: a short ease-out with no overshoot.
    static var hoverAnimation: Animation {
        SparkVMotion.respecting(IslandInteractionStore.current.motion.animation)
    }
    /// Expanded live activity (the band under the notch) while the drawer is closed.
    static let activityWidth: CGFloat = 400
    static let activityBandHeight: CGFloat = 30
    /// Taller band for a Clicky answer, which gets two lines.
    static let activityAnswerBandHeight: CGFloat = 46
    /// While music plays and the drawer is closed, the island widens by this
    /// much on each side to show the artwork (left) and a level meter (right)
    /// beside the camera housing.
    static let nowPlayingFlankWidth: CGFloat = 30

    // MARK: Compact live activities (wings beside the camera housing)

    /// Camera housing of the display the island is on; compact content
    /// stays outside it. 185 pt on the 14- and 16-inch MacBook Pro at
    /// default scaling; NotchWindowController measures the real width from
    /// the screen's auxiliary top areas whenever it lays the island out
    /// (written on the main thread only).
    nonisolated(unsafe) static var cameraHousingWidth: CGFloat = 185
    /// Gap between the housing and the compact content.
    static let wingInnerPadding: CGFloat = 8
    /// Gap between the compact content and the island's outer edge, enough
    /// to clear the bottom corner curve.
    static let wingOuterPadding: CGFloat = 10
    /// Wing width (housing edge to island edge) clamps.
    static let minWingWidth: CGFloat = 30
    static let maxWingWidth: CGFloat = 112
    /// Wings closer than this in width are drawn equal, so the island looks
    /// balanced unless one side really needs more room.
    static let wingBalanceTolerance: CGFloat = 14
    /// How long a persistent activity shows expanded when it first appears
    /// (or its `peekKey` changes) before tucking into the wings.
    static let activityPeekDuration: TimeInterval = 4
    /// Alerts up to this long are queued (their time runs only on screen);
    /// longer ones behave like persistent activities that expire.
    static let alertMaxDuration: TimeInterval = 8
    /// A queued alert that waited this long is dropped as stale.
    static let alertQueueMaxWait: TimeInterval = 12
    /// A preempted alert with less time than this left isn't brought back.
    static let alertMinResume: TimeInterval = 0.8
    /// How long the closed island's now-playing wing shows a new track's
    /// title before slimming back to the level bars.
    static let nowPlayingTitlePeek: Duration = .seconds(8)
    /// Crossfade between drawer tabs (enter/exit: strong ease-out, 220 ms).
    /// The drawer's height still follows `hoverAnimation`.
    static var tabAnimation: Animation { SparkVMotion.easeOut(SparkVMotion.Duration.standard) }
    /// The selection pill sliding between header tabs (on-screen movement:
    /// strong ease-in-out). Reduce Motion: no slide, the pill just moves.
    static var tabPillAnimation: Animation? {
        SparkVMotion.reduceMotion ? nil : SparkVMotion.easeInOut(SparkVMotion.Duration.standard)
    }
    /// The panel shrinks to a shorter tab only after the drawer's height
    /// animation has played, so it isn't cut off (420 ms for the Calm
    /// spring; it follows the Island Motion setting).
    static var tabShrinkDelay: Duration {
        .milliseconds(SparkVMotion.reduceMotion ? 200 : IslandInteractionStore.current.motion.settleMilliseconds)
    }

    /// How often the open drawer checks whether glance has taken over the notch.
    static let faceUnlockPollInterval: Duration = .milliseconds(500)
}

@MainActor
final class NotchState: ObservableObject {
    enum Tab: Hashable {
        case nook
        case tray
        /// Dictation history and notes.
        case flow
        /// Voice assistant.
        case clicky
        /// Upcoming meetings and the timer.
        case today
        /// iLovePDF-style file converter.
        case converter
        /// Knowledge Spaces: organization folders with their own agents.
        case spaces
        /// Hub for the agents below, which share one header icon.
        case agents
        case uiAudit
        case jobs
        case screen
        case promptRefiner
        case browser
        case clipboard
        case screenDistance
        /// Focus sessions: timer, distraction blocking, recap.
        case focus
        /// Universal search (Agents hub tile; ⌥Space opens the panel).
        case search
        /// Reply drafter (⌃⌥R).
        case replyDrafter
        /// File drop actions: rename, compress, convert, Space, AirDrop.
        case fileDrop
        /// Download watcher: progress, recent downloads, sorting.
        case downloads
        /// Notch widgets: world clocks, volume knob, habits, system gauges,
        /// network speed (header icon next to Home, and a hub tile).
        case widgets
        /// Fan Control: fan speeds, temperatures, presets (Agents hub tile).
        case fans
        /// Developer: coding agents, local servers, GitHub Actions, scripts
        /// (Agents hub tiles; approval bands open it).
        case devStatus
        /// Menu bar icons hidden by the notch (Agents hub tile, ⌃⌥B).
        case menuBar
        /// Status: battery and health, accessories, privacy dots, quick
        /// toggles (Agents hub tile; Labs/SystemStatus).
        case status
        /// Color Picker: formats, contrast, shades, palettes (Agents hub tile; ⌃⌥P picks).
        case colorPicker

        /// Tabs opened from the Agents hub rather than the header.
        static let agentTabs: Set<Tab> = [
            .agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance,
            .focus, .search, .replyDrafter, .fileDrop, .downloads, .fans, .devStatus, .menuBar, .colorPicker,
            .status,
        ]
    }

    @Published var isExpanded = false
    @Published var tab: Tab = .nook
    /// Resting size: the measured camera housing plus a shoulder on each
    /// side (220 pt on a 16-inch MacBook Pro); height follows the real
    /// safe-area inset so the resting shape matches the hardware notch.
    /// A pill on a display without a notch uses its own height.
    @Published var collapsedSize = NotchMetrics.collapsedSize
    /// How the island is drawn on its display (style preset, notch or not).
    @Published var surface = IslandSurface()
    /// A resting island that draws nothing (Minimal, an auto-hidden menu
    /// bar) is showing because the pointer reached it.
    @Published var isRestingRevealed = false
    /// Keep Drawer Open: the pointer leaving, a click outside or a Space
    /// switch don't close the drawer (Esc, a click on the notch, the pinned
    /// bar or choosing it again do).
    @Published var isPinned = false
    /// Open by Click or Press and Hold: the pointer is on the closed
    /// island, which grows a little to show it is ready.
    @Published var isHoverPrimed = false
    /// Bumped when the menu bar room for the wings changes, so the closed
    /// island lays its wings out again.
    @Published var wingClearanceRevision = 0

    /// True while a file drag hovers anywhere over the open drawer. A drag
    /// over any other tab (except those with their own drop targets) flips to the Tray so the drop
    /// lands on the shelf.
    @Published var isDropTargeted = false {
        didSet {
            guard isDropTargeted, tab != .tray, tab != .converter, tab != .spaces, tab != .jobs, tab != .fileDrop else { return }
            tabBeforeDrag = tab
            tab = .tray
        }
    }

    /// Set when a drag, not a click, opened the Tray: the tab the user had
    /// chosen before, which closing the drawer goes back to.
    private var tabBeforeDrag: Tab?

    func select(_ newTab: Tab) {
        tab = newTab
        tabBeforeDrag = nil
    }

    /// Every tab the user picked (Flow and Clicky included) survives a close;
    /// only a Tray opened by a drag reverts.
    func didCollapse() {
        isDropTargeted = false
        if let previous = tabBeforeDrag {
            tab = previous
            tabBeforeDrag = nil
        }
    }
}

/// How the island is drawn on the display it is on (Labs/IslandPlacement
/// decides; NotchNookLayoutView draws it).
struct IslandSurface: Equatable {
    enum Shape: Equatable {
        /// glance-style silhouette flaring into the top edge.
        case notch
        /// A capsule with every corner rounded (no flare).
        case pill
    }

    var shape: Shape = .notch
    var hasNotch = true
    var housingWidth: CGFloat = NotchMetrics.collapsedSize.width - 35
    /// Nothing is drawn at rest: the island appears for live activities and
    /// when the pointer reaches it.
    var restsHidden = false
    /// With `restsHidden`, a faint 3 pt hairline marks where it is.
    var showsHairline = false
    /// A pill's gap below the top edge (0 on a notched display). The panel
    /// reaches the edge; the resting pill sits this far below it, and an
    /// open drawer or a band fills the gap, so no menu-bar sliver shows
    /// above the black body.
    var topInset: CGFloat = 0
}

/// Small piece of view-local UI state (hover, drop targeting). Used instead of
/// `@State`, which the macOS 27 SDK implements as a macro whose plugin ships
/// only with Xcode, so this keeps `build.sh` working with the Command Line Tools.
@MainActor
final class ViewFlag: ObservableObject {
    @Published var isOn = false
}
