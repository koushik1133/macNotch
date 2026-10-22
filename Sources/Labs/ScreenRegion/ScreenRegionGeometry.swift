import CoreGraphics
import Foundation

// Screen Region: pure geometry (no AppKit state), unit-tested.
//
// Coordinate spaces:
// * AppKit global points: origin at the bottom-left of the primary screen
//   (NSScreen.screens[0]), y up. NSScreen.frame, NSEvent.mouseLocation.
// * Quartz global points: origin at the top-left of the primary screen, y
//   down. CGDisplayBounds, CGWindowListCopyWindowInfo bounds, SCWindow.frame.
// * Display-local points, top-left origin: SCStreamConfiguration.sourceRect.
// * Image pixels, top-left origin: a CGImage of the display (points × scale).

/// One display as the overlay sees it.
struct ScreenRegionDisplay: Sendable, Equatable {
    var id: UInt32
    /// AppKit global points.
    var frame: CGRect
    /// Backing scale (2 on Retina).
    var scale: CGFloat
}

/// What the user picked.
enum ScreenRegionSelection: Sendable, Equatable {
    /// A dragged rectangle, in AppKit global points, inside `display`.
    case region(rect: CGRect, display: ScreenRegionDisplay)
    /// A whole window. `frame` in AppKit global points.
    case window(id: UInt32, frame: CGRect, display: ScreenRegionDisplay, appName: String?, title: String?)

    /// The selected area in AppKit global points (for anchoring the panel).
    var appKitRect: CGRect {
        switch self {
        case .region(let rect, _): rect
        case .window(_, let frame, _, _, _): frame
        }
    }

    var display: ScreenRegionDisplay {
        switch self {
        case .region(_, let display): display
        case .window(_, _, let display, _, _): display
        }
    }
}

/// An on-screen window for window-pick mode.
struct ScreenRegionWindowInfo: Sendable, Equatable {
    var id: UInt32
    /// AppKit global points.
    var frame: CGRect
    var ownerPID: Int32
    var appName: String?
    var title: String?
}

enum ScreenRegionGeometry {
    /// Drags shorter than this are clicks (pick the window under the pointer).
    static let clickThreshold: CGFloat = 4
    /// Smallest region worth capturing, in points.
    static let minimumSide: CGFloat = 6

    // MARK: Rects

    /// The rectangle spanned by two drag points, in any order.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The drag rectangle clamped to `bounds` (the display the drag began on).
    static func clampedRect(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        return rect(from: clamp(a), to: clamp(b))
    }

    static func isClick(from a: CGPoint, to b: CGPoint) -> Bool {
        abs(a.x - b.x) < clickThreshold && abs(a.y - b.y) < clickThreshold
    }

    static func isCapturable(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }

    // MARK: AppKit ↔ Quartz

    /// AppKit global → Quartz global. `primaryHeight` is the height of
    /// NSScreen.screens[0] (the screen whose AppKit origin is (0, 0)).
    static func quartzRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Quartz global → AppKit global (the same flip; it is its own inverse).
    static func appKitRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func quartzPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: Capture rects

    /// AppKit global rect → display-local points with a top-left origin, the
    /// space of `SCStreamConfiguration.sourceRect`. Clipped to the display.
    static func sourceRect(forAppKit rect: CGRect, displayFrame: CGRect) -> CGRect {
        let clipped = rect.intersection(displayFrame)
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        return CGRect(
            x: clipped.minX - displayFrame.minX,
            y: displayFrame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    /// Display-local points (top-left) → pixel rect in an image of the whole
    /// display, rounded outward to whole pixels and clipped to the image.
    /// `imagePixelSize` is the captured image size; the scale is derived from
    /// it (so a downscaled capture still crops the right area).
    static func pixelRect(forSourceRect source: CGRect, displayPointSize: CGSize, imagePixelSize: CGSize) -> CGRect {
        guard displayPointSize.width > 0, displayPointSize.height > 0 else { return .zero }
        let sx = imagePixelSize.width / displayPointSize.width
        let sy = imagePixelSize.height / displayPointSize.height
        let scaled = CGRect(x: source.minX * sx, y: source.minY * sy, width: source.width * sx, height: source.height * sy)
        let outward = integralOutward(scaled)
        let clipped = outward.intersection(CGRect(origin: .zero, size: imagePixelSize))
        return clipped.isNull ? .zero : clipped
    }

    /// Output pixel size for a direct `sourceRect` capture at `scale`.
    static func outputPixelSize(forSourceRect source: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: max(1, (source.width * scale).rounded(.up)), height: max(1, (source.height * scale).rounded(.up)))
    }

    /// Rounds a rect outward to whole numbers, tolerating float noise
    /// (100.0000001 stays 100 instead of growing to 101).
    static func integralOutward(_ rect: CGRect, tolerance: CGFloat = 0.001) -> CGRect {
        let minX = (rect.minX + tolerance).rounded(.down)
        let minY = (rect.minY + tolerance).rounded(.down)
        let maxX = (rect.maxX - tolerance).rounded(.up)
        let maxY = (rect.maxY - tolerance).rounded(.up)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    // MARK: Displays and windows

    /// The display containing `point` (AppKit global), else the nearest.
    static func display(containing point: CGPoint, in displays: [ScreenRegionDisplay]) -> ScreenRegionDisplay? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) { return hit }
        return displays.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    /// The display a window mostly sits on.
    static func display(for rect: CGRect, in displays: [ScreenRegionDisplay]) -> ScreenRegionDisplay? {
        let best = displays.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
        if let best, area(best.frame.intersection(rect)) > 0 { return best }
        return display(containing: CGPoint(x: rect.midX, y: rect.midY), in: displays)
    }

    /// Frontmost window under `point`. `windows` is front-to-back.
    static func window(at point: CGPoint, in windows: [ScreenRegionWindowInfo]) -> ScreenRegionWindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    /// Parses CGWindowListCopyWindowInfo rows (front-to-back) into pickable
    /// windows: normal layer, not ours, not tiny.
    static func windows(fromWindowList list: [[String: Any]], primaryHeight: CGFloat, excludingPID: Int32) -> [ScreenRegionWindowInfo] {
        list.compactMap { row in
            guard let number = row["kCGWindowNumber"] as? NSNumber,
                  let pid = row["kCGWindowOwnerPID"] as? NSNumber,
                  (row["kCGWindowLayer"] as? NSNumber)?.intValue == 0,
                  pid.int32Value != excludingPID,
                  let bounds = row["kCGWindowBounds"] as? [String: Any],
                  let quartz = rect(fromBoundsDictionary: bounds)
            else { return nil }
            if let alpha = row["kCGWindowAlpha"] as? NSNumber, alpha.doubleValue <= 0.01 { return nil }
            guard quartz.width >= 40, quartz.height >= 40 else { return nil }
            return ScreenRegionWindowInfo(
                id: number.uint32Value,
                frame: appKitRect(fromQuartz: quartz, primaryHeight: primaryHeight),
                ownerPID: pid.int32Value,
                appName: row["kCGWindowOwnerName"] as? String,
                title: (row["kCGWindowName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    static func rect(fromBoundsDictionary bounds: [String: Any]) -> CGRect? {
        func value(_ key: String) -> CGFloat? { (bounds[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = value("X"), let y = value("Y"), let w = value("Width"), let h = value("Height") else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Results panel placement

    /// Where to put a panel of `size` next to `anchor` (both AppKit global),
    /// inside `visible` (the screen's visibleFrame): right of the selection,
    /// then left, below, above; otherwise clamped over it.
    static func panelFrame(size: CGSize, beside anchor: CGRect, in visible: CGRect, gap: CGFloat = 12) -> CGRect {
        func fits(_ r: CGRect) -> Bool { visible.insetBy(dx: -0.5, dy: -0.5).contains(r) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, visible.minY), visible.maxY - size.height) }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX), visible.maxX - size.width) }
        // Top-aligned with the selection, as a popover would be.
        let topY = clampY(anchor.maxY - size.height)
        let right = CGRect(x: anchor.maxX + gap, y: topY, width: size.width, height: size.height)
        if fits(right) { return right }
        let left = CGRect(x: anchor.minX - gap - size.width, y: topY, width: size.width, height: size.height)
        if fits(left) { return left }
        let centerX = clampX(anchor.midX - size.width / 2)
        let below = CGRect(x: centerX, y: anchor.minY - gap - size.height, width: size.width, height: size.height)
        if fits(below) { return below }
        let above = CGRect(x: centerX, y: anchor.maxY + gap, width: size.width, height: size.height)
        if fits(above) { return above }
        return CGRect(x: clampX(anchor.maxX - size.width), y: clampY(anchor.maxY - size.height), width: size.width, height: size.height)
    }

    // MARK: Badge

    /// "640 × 320" in points, as the system screenshot tool shows.
    static func badgeText(for rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    /// Badge origin (view coordinates, y up): below-right of the selection,
    /// moved inside when there's no room.
    static func badgeOrigin(badgeSize: CGSize, selection: CGRect, bounds: CGRect, gap: CGFloat = 6) -> CGPoint {
        var x = selection.maxX - badgeSize.width
        var y = selection.minY - gap - badgeSize.height
        if y < bounds.minY + 2 { y = selection.minY + gap }
        x = min(max(x, bounds.minX + 2), bounds.maxX - badgeSize.width - 2)
        y = min(max(y, bounds.minY + 2), bounds.maxY - badgeSize.height - 2)
        return CGPoint(x: x, y: y)
    }

    // MARK: Helpers

    static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }

    static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Long edge capped at `maxLongEdge`, aspect kept.
    static func fitted(_ size: CGSize, maxLongEdge: CGFloat) -> CGSize {
        let long = max(size.width, size.height)
        guard long > maxLongEdge, long > 0 else { return size }
        let factor = maxLongEdge / long
        return CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
    }
}
