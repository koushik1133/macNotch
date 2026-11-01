import AppKit

/// Keeps the floating panels that hang under the notch (the teleprompter
/// and the large mirror) out of the open drawer's way.
///
/// - They sit one window level below the island, so the island (and its
///   bands) always draws on top of them, in full screen too (the island
///   drops to `.floating` there; the panels follow it down).
/// - While the drawer is open they step aside (fade out; the teleprompter
///   also pauses) and come back when it closes.
/// - Showing one of them from inside the open drawer (a hub tile, a menu
///   item, ⌃⌥⇧T) closes the drawer first, so the panel is what you see.
///
/// The integrator calls `islandChanged(expanded:level:)` from
/// `NotchWindowController.updateLevel()` and sets `collapseIsland`.
@MainActor
enum ExtrasIslandCover {
    /// The island's drawer is open.
    private(set) static var islandExpanded = false
    /// The island panel's current level (`.statusBar`, or `.floating` while
    /// lowered in full screen).
    private(set) static var islandLevel: NSWindow.Level = .statusBar
    /// Closes the island's drawer (the integrator's `forceCollapse`).
    static var collapseIsland: (() -> Void)?

    /// One level below the island.
    static var panelLevel: NSWindow.Level { level(below: islandLevel) }

    nonisolated static func level(below island: NSWindow.Level) -> NSWindow.Level {
        NSWindow.Level(rawValue: island.rawValue - 1)
    }

    /// Called whenever the island opens, closes or changes level.
    static func islandChanged(expanded: Bool, level: NSWindow.Level) {
        let coverChanged = expanded != islandExpanded
        let levelChanged = level != islandLevel
        islandExpanded = expanded
        islandLevel = level
        if levelChanged {
            TeleprompterController.shared.panelLevelChanged(panelLevel)
            CameraMirrorPopOutController.shared.panelLevelChanged(panelLevel)
        }
        if coverChanged {
            TeleprompterController.shared.islandCoverChanged(expanded)
            CameraMirrorPopOutController.shared.islandCoverChanged(expanded)
        }
    }

    /// A panel is about to appear because the user asked for it: close the
    /// drawer so it isn't hidden behind (or by) it. Returns whether the
    /// drawer still covers the panel (not wired, or it can't close).
    @discardableResult
    static func userWillShowPanel() -> Bool {
        if islandExpanded { collapseIsland?() }
        return islandExpanded
    }
}
