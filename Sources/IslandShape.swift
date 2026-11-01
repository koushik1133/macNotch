import SwiftUI

/// The island silhouette, from glance's `NotchShape` (github.com/jonnyoo/glance,
/// MIT): concave top corners flare the panel into the menu bar like the
/// hardware notch's shoulders, and the bottom corners use Apple's real
/// `.continuous` curve. The drawable rect includes `topRadius` of flare on each
/// side, so the visible body is `width - 2 * topRadius` wide.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        notchPath(in: rect)
    }

    private func notchPath(in rect: CGRect) -> Path {
        // Clamp so a small closed size can't produce self-intersecting
        // curves when the radii exceed half the available width/height.
        let top = max(0, min(topRadius, rect.width / 2))
        let bottom = max(0, min(bottomRadius, min(rect.width / 2 - top, rect.height)))

        var path = Path()

        // Top-left: flare outward to meet the screen edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        if let corners = IslandContinuousCorner.bottomCorners(
            bodyRect: CGRect(x: rect.minX + top, y: rect.minY, width: rect.width - 2 * top, height: rect.height),
            radius: bottom
        ) {
            // Not simply `rect.maxY - bottom` — continuous corners reach further up
            // the straight edge than a circular corner of the same radius would.
            path.addLine(to: corners.leftEdgeReach)
            for segment in corners.left {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            path.addLine(to: corners.bottomEdgeRightReach)
            for segment in corners.right {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        } else {
            // Fallback if a future OS version changes how UnevenRoundedRectangle
            // emits its path: the original quad-curve approximation.
            path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        }

        // Top-right flare.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

/// The island's outline for either surface: the notch silhouette above,
/// or a continuous-corner capsule (the Pill style, and Minimal on a
/// display without a notch). Both radii animate, so the island can spring
/// between resting, band and open sizes in either shape.
struct IslandSilhouette: Shape {
    var shape: IslandSurface.Shape
    /// Shoulder flare (notch only; 0 for a pill).
    var topRadius: CGFloat
    /// Bottom corners (notch) or every corner (pill).
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .notch:
            return IslandShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: rect)
        case .pill:
            let radius = max(0, min(bottomRadius, rect.height / 2, rect.width / 2))
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        }
    }
}

/// There's no public API for "just the geometry of one continuous corner," so this
/// builds a reference rect with only the two corners wanted (others pinned to 0)
/// and reads its emitted path elements back out. Not memoized, so it stays exact
/// through animated radius changes.
private enum IslandContinuousCorner {
    struct Segment {
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    struct BottomCorners {
        /// Where the left edge's straight run ends and the corner's curvature begins.
        let leftEdgeReach: CGPoint
        /// Bottom-left corner, left edge → bottom edge (3 segments).
        let left: [Segment]
        /// Where the straight run between the two corners ends and the right corner begins.
        let bottomEdgeRightReach: CGPoint
        /// Bottom-right corner, bottom edge → right edge (3 segments).
        let right: [Segment]
    }

    /// `bodyRect` is the notch's inset-by-flare body, so extracted points already land
    /// on our own edges. Returns `nil` if a future OS version changes how the corner is emitted.
    static func bottomCorners(bodyRect: CGRect, radius: CGFloat) -> BottomCorners? {
        let reference = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        ).path(in: bodyRect)

        var elements: [Path.Element] = []
        reference.forEach { elements.append($0) }

        // Emitted order (verified empirically): move → line down the right edge (to p1,
        // where curvature begins) → 3 curves (bottom-right) → line across the bottom →
        // 3 curves (bottom-left) → line up the left edge → degenerate top-corner curves → close.
        guard elements.count >= 9,
              case .line(let p1) = elements[1],
              case .curve(let p2, let c2a, let c2b) = elements[2],
              case .curve(let p3, let c3a, let c3b) = elements[3],
              case .curve(let p4, let c4a, let c4b) = elements[4],
              case .line(let l5) = elements[5],
              case .curve(let p6, let c6a, let c6b) = elements[6],
              case .curve(let p7, let c7a, let c7b) = elements[7],
              case .curve(let p8, let c8a, let c8b) = elements[8]
        else { return nil }

        // The reference traces right→left; our path needs left→right, so everything
        // is reversed: segment order flips within each corner, control points swap,
        // and the two corners swap ends.
        return BottomCorners(
            leftEdgeReach: p8,
            left: [
                Segment(control1: c8b, control2: c8a, to: p7),
                Segment(control1: c7b, control2: c7a, to: p6),
                Segment(control1: c6b, control2: c6a, to: l5),
            ],
            bottomEdgeRightReach: p4,
            right: [
                Segment(control1: c4b, control2: c4a, to: p3),
                Segment(control1: c3b, control2: c3a, to: p2),
                Segment(control1: c2b, control2: c2a, to: p1),
            ]
        )
    }
}


// MARK: - Closed island geometry

/// Where the closed island's body sits, shared by the view (which draws it)
/// and `NotchWindowController` (whose hover hot zone must match it).
///
/// Compact: the body grows sideways inside the menu-bar height, a wing on
/// each side of the camera housing fitted to its content, so nothing below
/// the menu bar is covered, and stopping short of the nearest menu bar
/// item (`IslandInteractionStore.wingClearance`). The wings may differ in width; the body then
/// shifts so the housing stays centered over the camera.
/// Expanded: a symmetric band under the notch, at least
/// `NotchMetrics.activityWidth` wide.
struct IslandClosedLayout: Equatable {
    /// Body size without the shoulder flare.
    var size: CGSize
    /// Horizontal offset of the body's center from the camera's center.
    var xOffset: CGFloat
    /// Width from each housing edge to the body's edge.
    var leadingWing: CGFloat
    var trailingWing: CGFloat
    /// Height of the band under the notch, or nil when compact.
    var band: CGFloat?
    var hasWings: Bool

    static func make(
        resting: CGSize,
        housing: CGFloat = NotchMetrics.cameraHousingWidth,
        band: CGFloat?,
        wings: IslandWings?
    ) -> IslandClosedLayout {
        let restingWing = max(0, (resting.width - housing) / 2)
        var leading = restingWing
        var trailing = restingWing
        if let wings {
            leading = wingWidth(content: wings.leading, resting: restingWing)
            trailing = wingWidth(content: wings.trailing, resting: restingWing)
            if abs(leading - trailing) < NotchMetrics.wingBalanceTolerance {
                leading = max(leading, trailing)
                trailing = leading
            }
            // Never over a menu bar item (Labs/IslandInteraction measures
            // the room on each side; unlimited when that is off).
            let room = IslandInteractionStore.wingClearance
            leading = IslandWingClearance.cap(leading, clearance: room.leading, floor: restingWing)
            trailing = IslandWingClearance.cap(trailing, clearance: room.trailing, floor: restingWing)
        }
        if let band {
            // Symmetric: the band is centered under the camera.
            let side = max((NotchMetrics.activityWidth - housing) / 2, leading, trailing)
            return IslandClosedLayout(
                size: CGSize(width: housing + 2 * side, height: resting.height + band),
                xOffset: 0, leadingWing: side, trailingWing: side, band: band, hasWings: wings != nil
            )
        }
        return IslandClosedLayout(
            size: CGSize(width: housing + leading + trailing, height: resting.height),
            xOffset: (trailing - leading) / 2, leadingWing: leading, trailingWing: trailing,
            band: nil, hasWings: wings != nil
        )
    }

    /// Content plus padding, clamped; never narrower than the resting island.
    static func wingWidth(content: CGFloat, resting: CGFloat) -> CGFloat {
        let padded = content > 0 ? content + NotchMetrics.wingInnerPadding + NotchMetrics.wingOuterPadding : 0
        return max(resting, min(NotchMetrics.maxWingWidth, max(NotchMetrics.minWingWidth, padded)))
    }
}
