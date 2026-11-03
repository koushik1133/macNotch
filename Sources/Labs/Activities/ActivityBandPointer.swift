import AppKit

/// Where the pointer is relative to the closed island's band, and what the
/// notch panel should do about it. Pure, so the window controller's pointer
/// handling stays a few lines and can be tested without a screen.
///
/// - Over a band with buttons (`LiveActivity.isInteractive`): the panel
///   takes clicks while the pointer is there, and hovering never opens the
///   drawer (the user is reaching for Reply, Accept or Mute).
/// - Over any other band: nothing changes, except that the alert's clock
///   waits (`ActivityCenter.setHovered`).
enum ActivityBandPointer {
    enum Decision: Equatable {
        /// Not over a band (or the drawer is open): normal hover handling.
        case none
        /// Over a band without buttons: hold its clock, carry on as usual.
        case hover
        /// Over a band with buttons: hold its clock, take clicks, don't open.
        case interact
    }

    /// Screen rect of the band under the notch: centered under the camera,
    /// `layout.size.width` wide, below the resting island.
    static func bandRect(layout: IslandClosedLayout, notchRect: NSRect) -> NSRect? {
        guard let band = layout.band, band > 0 else { return nil }
        let width = layout.size.width
        let midX = notchRect.midX + layout.xOffset
        return NSRect(x: midX - width / 2, y: notchRect.maxY - notchRect.height - band, width: width, height: band)
    }

    static func decide(
        mouse: NSPoint,
        bandRect: NSRect?,
        isExpanded: Bool,
        bandOwnedByActivity: Bool,
        isInteractive: Bool
    ) -> Decision {
        guard !isExpanded, let rect = bandRect else { return .none }
        // The band's top edge meets the notch row (which keeps opening the
        // drawer); a point of slack on the sides and bottom only.
        let zone = NSRect(x: rect.minX - 1, y: rect.minY - 1, width: rect.width + 2, height: rect.height + 1)
        guard zone.contains(mouse) else { return .none }
        guard bandOwnedByActivity else { return .none }
        return isInteractive ? .interact : .hover
    }
}
