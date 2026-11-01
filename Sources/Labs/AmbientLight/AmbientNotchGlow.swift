import AppKit
import SwiftUI

// The notch glow: an AppKit view hosting `AmbientOutlineGlow`, placed behind
// the island exactly like a notch theme layer (see INTEGRATION.md). SwiftUI
// only tells it the island's geometry when that changes; the per-frame light
// comes from `AmbientLightController`'s display link straight into Core
// Animation, so SwiftUI never re-evaluates a view for the effect.

/// Fixed canvas around the island. The island is drawn top-centered in it,
/// `NotchThemeMetrics.maxOutset` below the canvas top (that margin lies above
/// the screen edge and is clipped by the panel, as for themes). Fixed so the
/// island's own spring never resizes the view: only the outline animates.
enum AmbientNotchGlowMetrics {
    static var outset: CGFloat { NotchThemeMetrics.maxOutset }
    static let canvasSize = CGSize(width: 1_100, height: 760)
    /// Matches `NotchMetrics.hoverAnimation` / `NotchThemeTiming.islandSpring`.
    /// nil with Island Motion › Instant: the outline jumps.
    static var springResponse: Double? { IslandInteractionStore.current.motion.coreAnimationResponse }

    /// The island outline (`IslandShape`) for the given geometry in the
    /// canvas, without the closing segment along the screen edge (that edge
    /// is under the menu bar and must not glow).
    static func outline(bodySize: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) -> (CGPath, CGRect) {
        let width = bodySize.width + 2 * topRadius
        let rect = CGRect(x: (canvasSize.width - width) / 2, y: outset, width: width, height: bodySize.height)
        let closed = IslandShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: rect).cgPath
        return (openPath(closed), rect)
    }

    /// The same path with `closeSubpath` dropped.
    static func openPath(_ path: CGPath) -> CGPath {
        let open = CGMutablePath()
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint: open.move(to: points[0])
            case .addLineToPoint: open.addLine(to: points[0])
            case .addQuadCurveToPoint: open.addQuadCurve(to: points[1], control: points[0])
            case .addCurveToPoint: open.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return open
    }
}

/// Click-through, flipped (y down like SwiftUI) layer host.
final class AmbientNotchGlowView: NSView {
    let glow: AmbientOutlineGlow
    private var geometry: (CGSize, CGFloat, CGFloat)?

    override init(frame frameRect: NSRect) {
        glow = AmbientOutlineGlow()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(glow.root)
        glow.root.frame = CGRect(origin: .zero, size: AmbientNotchGlowMetrics.canvasSize)
        glow.root.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            AmbientLightController.shared.register(self)
        } else {
            AmbientLightController.shared.unregister(self)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        glow.root.contentsScale = scale
    }

    func setGeometry(bodySize: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) {
        let new = (bodySize, topRadius, bottomRadius)
        if let geometry, geometry.0 == new.0, geometry.1 == new.1, geometry.2 == new.2 { return }
        let animate = geometry != nil && window != nil
        geometry = new
        let (path, rect) = AmbientNotchGlowMetrics.outline(bodySize: bodySize, topRadius: topRadius, bottomRadius: bottomRadius)
        glow.setOutline(path, in: rect, springResponse: animate ? AmbientNotchGlowMetrics.springResponse : nil)
    }
}

private struct AmbientNotchGlowRepresentable: NSViewRepresentable {
    var bodySize: CGSize
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func makeNSView(context: Context) -> AmbientNotchGlowView {
        AmbientNotchGlowView(frame: CGRect(origin: .zero, size: AmbientNotchGlowMetrics.canvasSize))
    }

    func updateNSView(_ view: AmbientNotchGlowView, context: Context) {
        view.setGeometry(bodySize: bodySize, topRadius: topRadius, bottomRadius: bottomRadius)
    }
}

/// Put this behind the island, next to `NotchThemeBackdrop` (see
/// INTEGRATION.md). Draws nothing (and costs nothing) while Ambient Light is
/// off; the light itself fades in and out on its own.
struct AmbientNotchGlowBackdrop: View {
    var bodySize: CGSize
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    @ObservedObject private var settings = AmbientLightSettings.shared

    var body: some View {
        if settings.isActive {
            AmbientNotchGlowRepresentable(bodySize: bodySize, topRadius: topRadius, bottomRadius: bottomRadius)
                .frame(width: AmbientNotchGlowMetrics.canvasSize.width, height: AmbientNotchGlowMetrics.canvasSize.height)
                .offset(y: -AmbientNotchGlowMetrics.outset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
