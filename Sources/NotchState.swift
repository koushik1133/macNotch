import SwiftUI

/// Fixed geometry for the 16-inch MacBook Pro notch and the expanded drawer.
enum NotchMetrics {
    /// Resting frame that overlaps the physical camera cutout.
    static let collapsedSize = CGSize(width: 220, height: 38)
    /// Fully expanded drawer.
    static let expandedSize = CGSize(width: 540, height: 115)
    static let bottomCornerRadius: CGFloat = 12
    /// Silhouette radii (values from glance). The flare is drawn outside the
    /// body, so the panel is `expandedSize.width + 2 * openFlareRadius` wide.
    static let closedFlareRadius: CGFloat = 8
    static let closedBottomRadius: CGFloat = 12
    static let activityFlareRadius: CGFloat = 10
    static let activityBottomRadius: CGFloat = 18
    static let openFlareRadius: CGFloat = 16
    static let openBottomRadius: CGFloat = 32
    /// The Tray's, the converter's and the clipboard's large cards (and the
    /// Agents hub, Search results and Downloads list) need a taller drawer
    /// than the other tabs.
    static let trayExpandedHeight: CGFloat = 160
    /// Tabs that use the tall drawer.
    static let tallTabs: Set<NotchState.Tab> = [.tray, .converter, .clipboard, .search, .downloads, .widgets, .replyDrafter, .fans]
    /// The Agents hub grows with its rows of tiles: header band, rows and
    /// the drawer's bottom padding (`AgentHubMetrics`).
    static var agentsExpandedHeight: CGFloat {
        let rows = CGFloat(AgentHubMetrics.rows)
        // +4: tiles with two-line labels grow a few points past tileHeight.
        return collapsedSize.height + rows * AgentHubMetrics.tileHeight + (rows - 1) * AgentHubMetrics.spacing + drawerBottomPadding + 4
    }
    /// Space under the tab content inside the open drawer.
    static let drawerBottomPadding: CGFloat = 8

    static func expandedSize(for tab: NotchState.Tab) -> CGSize {
        let height: CGFloat = if tab == .agents {
            agentsExpandedHeight
        } else if tallTabs.contains(tab) {
            trayExpandedHeight
        } else {
            expandedSize.height
        }
        return CGSize(width: expandedSize.width, height: height)
    }

    /// Window size for a tab: the open drawer plus its flare on both sides.
    static func panelSize(for tab: NotchState.Tab) -> CGSize {
        let body = expandedSize(for: tab)
        return CGSize(width: body.width + 2 * openFlareRadius, height: body.height)
    }

    static var panelSize: CGSize { panelSize(for: .nook) }
    /// Grace period before the drawer closes after the pointer leaves it.
    static let collapseDelay: Duration = .milliseconds(500)
    static let hoverAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.8)
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

    /// Camera housing of the 14- and 16-inch MacBook Pro (measured 185 pt);
    /// compact content stays outside it.
    static let cameraHousingWidth: CGFloat = 185
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
    /// Crossfade between drawer tabs.
    static let tabAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.86)
    /// The panel shrinks to a shorter tab only after the drawer's height
    /// animation has played, so it isn't cut off.
    static let tabShrinkDelay: Duration = .milliseconds(420)

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

        /// Tabs opened from the Agents hub rather than the header.
        static let agentTabs: Set<Tab> = [
            .agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance,
            .focus, .search, .replyDrafter, .fileDrop, .downloads, .fans,
        ]
    }

    @Published var isExpanded = false
    @Published var tab: Tab = .nook
    /// Width stays at the spec's 220pt; height follows the real safe-area
    /// inset of the screen so the resting shape matches the hardware notch.
    @Published var collapsedSize = NotchMetrics.collapsedSize

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

/// Small piece of view-local UI state (hover, drop targeting). Used instead of
/// `@State`, which the macOS 27 SDK implements as a macro whose plugin ships
/// only with Xcode, so this keeps `build.sh` working with the Command Line Tools.
@MainActor
final class ViewFlag: ObservableObject {
    @Published var isOn = false
}
