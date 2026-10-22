import AppKit
import SwiftUI

// Motion family: Magnetic Ripple, Aurora, Particle Spark, Minimal Hairline.
// Ported from docs/notch-themes/*.html. Every layer draws BEHIND the black
// island body, so strokes that sit on the island edge are drawn twice as wide
// as in the demos: the inner half is covered by the body and the outer half is
// the visible line. Effects never reach more than `NotchThemeMetrics.maxOutset`
// outside the island; they fade out before that edge instead of being cut.

// MARK: - Shared geometry

/// Island geometry a Motion layer draws around.
private struct MotionIsland: Equatable {
    var bodyWidth: CGFloat
    var bodyHeight: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    init(_ context: NotchThemeContext) {
        bodyWidth = context.bodySize.width
        bodyHeight = context.bodySize.height
        topRadius = context.topRadius
        bottomRadius = context.bottomRadius
    }

    typealias Data = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>

    var data: Data {
        get { AnimatablePair(AnimatablePair(bodyWidth, bodyHeight), AnimatablePair(topRadius, bottomRadius)) }
        set {
            bodyWidth = newValue.first.first
            bodyHeight = newValue.first.second
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }
}

/// The island placed in a layer of a given size (centered, as the host
/// centers the layer on the island).
private struct MotionFrame {
    let size: CGSize
    let island: MotionIsland
    /// IslandShape's drawable rect: the body plus `topRadius` of flare per side.
    let shapeRect: CGRect

    init(size: CGSize, island: MotionIsland) {
        self.size = size
        self.island = island
        let w = island.bodyWidth + 2 * island.topRadius
        shapeRect = CGRect(x: (size.width - w) / 2, y: (size.height - island.bodyHeight) / 2,
                           width: w, height: island.bodyHeight)
    }

    var bodyRect: CGRect { shapeRect.insetBy(dx: island.topRadius, dy: 0) }

    var closedPath: Path {
        IslandShape(topRadius: island.topRadius, bottomRadius: island.bottomRadius).path(in: shapeRect)
    }

    /// The visible edge only: IslandShape without the closing line across the
    /// top of the screen (the demos' `dOpen`).
    var edgePath: Path {
        var out = Path()
        closedPath.forEach { element in
            switch element {
            case .move(let p): out.move(to: p)
            case .line(let p): out.addLine(to: p)
            case .quadCurve(let p, let c): out.addQuadCurve(to: p, control: c)
            case .curve(let p, let c1, let c2): out.addCurve(to: p, control1: c1, control2: c2)
            case .closeSubpath: break
            }
        }
        return out
    }

    /// Where the demos park the pointer when there is none: 70% across, near the bottom.
    func pointer(_ p: CGPoint?) -> CGPoint {
        if let p { return p }
        let body = bodyRect
        return CGPoint(x: body.minX + body.width * 0.7, y: body.minY + min(27, body.height * 0.71))
    }

    /// Region effects may light: the island grown by `maxOutset`, open at the
    /// top (that side is off screen), with a soft falloff so nothing is cut.
    var reachPath: Path {
        let grow = NotchThemeMetrics.maxOutset - Self.reachSoftness
        let rect = CGRect(x: shapeRect.minX - grow, y: min(0, shapeRect.minY) - 40,
                          width: shapeRect.width + 2 * grow,
                          height: shapeRect.maxY + grow - (min(0, shapeRect.minY) - 40))
        let r = island.bottomRadius + grow
        return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                      bottomTrailingRadius: r, topTrailingRadius: 0,
                                      style: .continuous).path(in: rect)
    }

    static let reachSoftness: CGFloat = 9

    /// Multiplies what is already in `ctx` by the reach region.
    func applyReach(_ ctx: inout GraphicsContext) {
        let path = reachPath
        ctx.blendMode = .destinationIn
        ctx.drawLayer { mask in
            mask.addFilter(.blur(radius: Self.reachSoftness / 2.4))
            mask.fill(path, with: .color(.white))
        }
        ctx.blendMode = .normal
    }

    func unit(_ p: CGPoint) -> UnitPoint {
        UnitPoint(x: size.width > 0 ? p.x / size.width : 0.5, y: size.height > 0 ? p.y / size.height : 0.5)
    }
}

/// Lays the island out in the layer and interpolates its geometry with the
/// host's transaction, so rims follow the body's spring instead of jumping.
private struct MotionStage<Content: View>: View, Animatable {
    var island: MotionIsland
    let content: (MotionFrame) -> Content

    init(island: MotionIsland, @ViewBuilder content: @escaping (MotionFrame) -> Content) {
        self.island = island
        self.content = content
    }

    nonisolated var animatableData: MotionIsland.Data {
        get { island.data }
        set { island.data = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            content(MotionFrame(size: proxy.size, island: island))
        }
    }
}

/// A precomputed path as a Shape.
private struct MotionPathShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// Arc-length sampling along the island edge (sparks orbit it).
private struct MotionEdgeSampler {
    private(set) var points: [CGPoint] = []
    private(set) var lengths: [CGFloat] = []
    private(set) var total: CGFloat = 1

    init(path: Path) {
        var pts: [CGPoint] = []
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let p):
                pts.append(p); current = p
            case .line(let p):
                pts.append(p); current = p
            case .quadCurve(let p, let c):
                let a = current
                for i in 1...12 {
                    let t = CGFloat(i) / 12, u = 1 - t
                    pts.append(CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * p.x,
                                       y: u * u * a.y + 2 * u * t * c.y + t * t * p.y))
                }
                current = p
            case .curve(let p, let c1, let c2):
                let a = current
                for i in 1...12 {
                    let t = CGFloat(i) / 12, u = 1 - t
                    let b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
                    pts.append(CGPoint(x: b0 * a.x + b1 * c1.x + b2 * c2.x + b3 * p.x,
                                       y: b0 * a.y + b1 * c1.y + b2 * c2.y + b3 * p.y))
                }
                current = p
            case .closeSubpath:
                break
            }
        }
        var lens: [CGFloat] = []
        var acc: CGFloat = 0
        for (i, p) in pts.enumerated() {
            if i > 0 { acc += hypot(p.x - pts[i - 1].x, p.y - pts[i - 1].y) }
            lens.append(acc)
        }
        points = pts
        lengths = lens
        total = max(acc, 1)
    }

    /// Point and unit tangent at arc length `l`.
    func sample(_ l: CGFloat) -> (point: CGPoint, tangent: CGVector) {
        guard points.count > 1 else { return (points.first ?? .zero, CGVector(dx: 1, dy: 0)) }
        let l = min(max(0, l), total)
        var lo = 0, hi = lengths.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lengths[mid] < l { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let seg = max(lengths[hi] - lengths[lo], 0.0001)
        let f = (l - lengths[lo]) / seg
        let dx = b.x - a.x, dy = b.y - a.y
        let m = max(hypot(dx, dy), 0.0001)
        return (CGPoint(x: a.x + dx * f, y: a.y + dy * f), CGVector(dx: dx / m, dy: dy / m))
    }

    /// Fraction along the edge closest to `p` (81 probes, like the demo).
    func nearestFraction(to p: CGPoint) -> CGFloat {
        var best: CGFloat = 0.5, bestD = CGFloat.infinity
        for i in 0...80 {
            let q = sample(total * CGFloat(i) / 80).point
            let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if d < bestD { bestD = d; best = CGFloat(i) / 80 }
        }
        return best
    }
}

/// Small deterministic RNG so renders are repeatable.
private struct MotionRandom {
    var state: UInt64
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
}

private enum MotionColor {
    /// The motion themes' warm accent: an ember orange-red in Apple, the
    /// brand red in SparkV Red.
    static var red: Color { SparkVTheme.choose(apple: Color(.sRGB, red: 1.0, green: 0.42, blue: 0.22, opacity: 1), sparkv: SparkVTheme.brandRed) }
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

// MARK: - Magnetic Ripple

/// Glass rings spread from the pointer and run along the island edge with a
/// red/cyan fringe; the rim glows brightest under the pointer. Opening sends
/// one larger ring, then only the rim stays.
struct MagneticRippleNotchLayer: View {
    var context: NotchThemeContext
    /// Fixed clock for offscreen renders; nil uses the live timeline.
    var debugTime: TimeInterval?

    @StateObject private var model = MagneticRippleModel()
    @Environment(\.colorSchemeContrast) private var contrast

    init(context: NotchThemeContext, debugTime: TimeInterval? = nil) {
        self.context = context
        self.debugTime = debugTime
    }

    private var layerOpacity: Double {
        switch context.phase {
        case .resting: 0
        case .hovered: 1
        case .open: 0.7
        }
    }

    private var paused: Bool {
        debugTime != nil || context.phase == .resting || context.reduceMotion
            || (context.phase == .open && model.settledIn == .open)
    }

    var body: some View {
        MotionStage(island: MotionIsland(context)) { frame in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { timeline in
                let now = debugTime ?? timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    if !context.reduceTransparency {
                        // The demo bends the menu bar with a displaced copy of it.
                        // A window can't read the real menu bar, so the ring's
                        // wake blurs what is behind the panel instead.
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask {
                                Canvas { ctx, _ in drawWake(&ctx, frame: frame, now: now) }
                            }
                    }
                    Canvas { ctx, _ in drawRipple(&ctx, frame: frame, now: now) }
                }
            }
        }
        .animation(.easeOut(duration: context.phase == .resting ? 0.45 : 0.18)) { $0.opacity(layerOpacity) }
        .onChange(of: context.phase) { _, _ in model.settledIn = nil }
        .allowsHitTesting(false)
    }

    private func drawRipple(_ ctx: inout GraphicsContext, frame: MotionFrame, now: TimeInterval) {
        let pointer = frame.pointer(context.pointer)
        let edge = frame.edgePath
        let highContrast = contrast == .increased

        if context.reduceTransparency {
            // Solid 1 pt white rim at 60%, no rings, no blur.
            ctx.stroke(edge, with: .color(.white.opacity(highContrast ? 1 : 0.6)), lineWidth: 2)
            return
        }

        let rings: [MagneticRippleModel.Drawn]
        if context.reduceMotion {
            rings = context.phase == .hovered ? MagneticRippleModel.staticRings : []
        } else {
            model.update(now: now, phase: context.phase, pointer: pointer)
            rings = model.drawnRings(now: now)
            if context.phase == .open, model.rings.isEmpty, model.settledIn == nil, debugTime == nil,
               now - model.phaseStart > 0.5 {
                // The open drawer keeps only the rim: stop the timeline.
                let model = model
                Task { @MainActor in model.settledIn = .open }
            }
        }

        if !rings.isEmpty {
            let origin = context.reduceMotion ? pointer : nil
            ctx.drawLayer { layer in
                for ring in rings {
                    let c = origin ?? ring.origin
                    layer.opacity = ring.alpha
                    layer.stroke(Self.circle(c, ring.radius), with: .color(.white), lineWidth: ring.big ? 2 : 1.6)
                    if !highContrast {
                        layer.stroke(Self.circle(c, ring.radius + 2.6),
                                     with: .color(MotionColor.red.opacity(0.75)), lineWidth: 1.1)
                        layer.stroke(Self.circle(c, max(0, ring.radius - 2.2)),
                                     with: .color(MotionColor.rgb(143, 233, 255, 0.65)), lineWidth: 1)
                    }
                }
                layer.opacity = 1
                // Rings live on the edge band plus a faint pool around the pointer.
                layer.blendMode = .destinationIn
                layer.drawLayer { mask in
                    mask.addFilter(.blur(radius: 5))
                    // The demo's band is 28 pt; here it spans the whole reach,
                    // since rings can't spread wider than 28 pt anyway.
                    mask.stroke(edge, with: .color(.white), lineWidth: 2 * NotchThemeMetrics.maxOutset)
                    mask.fill(Self.circle(pointer, 190), with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.38), .white.opacity(0)]),
                        center: pointer, startRadius: 0, endRadius: 190))
                }
                frame.applyReach(&layer)
            }
        }

        // The magnetic rim: brightest under the pointer.
        let rim = Gradient(stops: [
            .init(color: .white, location: 0),
            .init(color: MotionColor.rgb(198, 243, 255, highContrast ? 1 : 0.55), location: 0.45),
            .init(color: .white.opacity(highContrast ? 1 : 0.16), location: 1),
        ])
        ctx.stroke(edge, with: .radialGradient(rim, center: pointer, startRadius: 0, endRadius: 130), lineWidth: 2.6)
    }

    /// Blur mask: a disc around the pointer that grows with the youngest ring
    /// and fades as it dies (the demo's displacement amplitude and radius).
    private func drawWake(_ ctx: inout GraphicsContext, frame: MotionFrame, now: TimeInterval) {
        let pointer = frame.pointer(context.pointer)
        let wake: (strength: Double, radius: CGFloat)
        if context.reduceMotion {
            wake = context.phase == .hovered ? (0.25, 150) : (0, 0)
        } else {
            wake = model.wake(now: now)
        }
        guard wake.strength > 0.01, wake.radius > 1 else { return }
        ctx.drawLayer { layer in
            layer.opacity = min(1, wake.strength)
            layer.fill(Self.circle(pointer, wake.radius), with: .radialGradient(
                Gradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.45),
                                 .init(color: .white.opacity(0), location: 1)]),
                center: pointer, startRadius: 0, endRadius: wake.radius))
            layer.opacity = 1
            frame.applyReach(&layer)
        }
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}

@MainActor
final class MagneticRippleModel: ObservableObject {
    struct Ring {
        var origin: CGPoint
        var t0: TimeInterval
        var duration: TimeInterval
        var reach: CGFloat
        var big: Bool
    }

    struct Drawn {
        var origin: CGPoint
        var radius: CGFloat
        var alpha: Double
        var big: Bool
    }

    /// Reduce Motion: a still ring pattern around the pointer.
    static let staticRings: [Drawn] = [
        Drawn(origin: .zero, radius: 30, alpha: 0.95, big: false),
        Drawn(origin: .zero, radius: 74, alpha: 0.6, big: false),
        Drawn(origin: .zero, radius: 124, alpha: 0.32, big: false),
    ]

    /// Set once the open drawer's ring has died, to pause the timeline.
    @Published var settledIn: NotchThemePhase?

    private(set) var rings: [Ring] = []
    private(set) var phaseStart: TimeInterval = 0
    private var lastPhase: NotchThemePhase = .resting
    private var lastEmit: TimeInterval = -100
    private var lastPoint: CGPoint = .zero

    func update(now: TimeInterval, phase: NotchThemePhase, pointer: CGPoint) {
        if phase != lastPhase {
            if phase == .hovered { emit(at: pointer, now: now, big: false) }
            if phase == .open { emit(at: pointer, now: now, big: true) }
            lastPhase = phase
            phaseStart = now
        }
        if phase == .hovered {
            let moved = hypot(pointer.x - lastPoint.x, pointer.y - lastPoint.y) > 30
            if now - lastEmit > 1.15 || (now - lastEmit > 0.26 && moved) {
                emit(at: pointer, now: now, big: false)
            }
        }
        rings.removeAll { now - $0.t0 >= $0.duration || now < $0.t0 }
    }

    private func emit(at p: CGPoint, now: TimeInterval, big: Bool) {
        rings.append(Ring(origin: p, t0: now, duration: big ? 1.9 : 1.5, reach: big ? 340 : 200, big: big))
        if rings.count > 6 { rings.removeFirst(rings.count - 6) }
        lastEmit = now
        lastPoint = p
    }

    func drawnRings(now: TimeInterval) -> [Drawn] {
        rings.compactMap { ring in
            let p = (now - ring.t0) / ring.duration
            guard p >= 0, p < 1 else { return nil }
            let e = 1 - pow(1 - p, 3)
            return Drawn(origin: ring.origin, radius: 5 + CGFloat(e) * ring.reach,
                         alpha: pow(1 - p, 1.35), big: ring.big)
        }
    }

    /// The demo's displacement: amplitude (1 - p) of the youngest ring, radius r + 46.
    func wake(now: TimeInterval) -> (strength: Double, radius: CGFloat) {
        var amp = 0.0, radius: CGFloat = 0
        for ring in rings {
            let p = (now - ring.t0) / ring.duration
            guard p >= 0, p < 1 else { continue }
            amp = max(amp, 1 - p)
            radius = max(radius, 5 + CGFloat(1 - pow(1 - p, 3)) * ring.reach + 46)
        }
        return (amp * 0.5, radius)
    }
}

// MARK: - Aurora

/// A blurred conic aurora (red, magenta, violet, deep blue) turns slowly
/// behind the edge and spills onto the menu bar; a 1 pt rim with flowing
/// colour outlines the island. Open dims it to about 60%.
struct AuroraNotchLayer: View {
    var context: NotchThemeContext
    var debugTime: TimeInterval?

    @Environment(\.colorSchemeContrast) private var contrast

    init(context: NotchThemeContext, debugTime: TimeInterval? = nil) {
        self.context = context
        self.debugTime = debugTime
    }

    private static let glowStops: [Gradient.Stop] = [
        .init(color: MotionColor.rgb(240, 24, 34), location: 0),
        .init(color: MotionColor.rgb(255, 46, 136), location: 0.16),
        .init(color: MotionColor.rgb(155, 44, 255), location: 0.33),
        .init(color: MotionColor.rgb(43, 61, 255), location: 0.5),
        .init(color: MotionColor.rgb(14, 28, 143), location: 0.62),
        .init(color: MotionColor.rgb(106, 28, 201), location: 0.75),
        .init(color: MotionColor.rgb(224, 19, 111), location: 0.88),
        .init(color: MotionColor.rgb(240, 24, 34), location: 1),
    ]

    private static let rimColors: [(Color, Double)] = [
        (MotionColor.rgb(240, 24, 34), 0), (MotionColor.rgb(255, 61, 154), 0.22),
        (MotionColor.rgb(139, 92, 255), 0.46), (MotionColor.rgb(39, 71, 255), 0.7),
        (MotionColor.rgb(196, 26, 124), 0.86), (MotionColor.rgb(240, 24, 34), 1),
    ]

    private var paused: Bool { debugTime != nil || context.phase == .resting || context.reduceMotion }

    private func value(_ hovered: Double, _ open: Double) -> Double {
        switch context.phase {
        case .resting: 0
        case .hovered: hovered
        case .open: open
        }
    }

    var body: some View {
        MotionStage(island: MotionIsland(context)) { frame in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                let now = context.reduceMotion ? 0 : (debugTime ?? timeline.date.timeIntervalSinceReferenceDate)
                ZStack {
                    if !context.reduceTransparency {
                        Canvas { ctx, _ in drawVeil(&ctx, frame: frame, now: now) }
                            .animation(.easeOut(duration: context.reduceMotion ? 0.2 : 0.7)) {
                                $0.opacity(value(0.8, 0.35))
                            }
                        Canvas { ctx, _ in drawGlow(&ctx, frame: frame, now: now) }
                            .animation(.easeOut(duration: context.reduceMotion ? 0.2 : 0.55)) {
                                $0.opacity(value(0.95, 0.6))
                            }
                            .animation(context.reduceMotion ? nil : .timingCurve(0.2, 0.9, 0.25, 1.1, duration: 0.7)) {
                                $0.scaleEffect(context.phase == .resting && !context.reduceMotion ? 0.9 : 1,
                                               anchor: frame.unit(CGPoint(x: frame.shapeRect.midX, y: frame.shapeRect.minY - 14)))
                            }
                    }
                    Canvas { ctx, _ in drawRim(&ctx, frame: frame, now: now) }
                        .animation(.easeOut(duration: context.reduceMotion ? 0.2 : 0.35)) {
                            $0.opacity(value(1, 0.8))
                        }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The conic glow. The demo grows it 20/22 pt past the island with a 15 pt
    /// blur; that is scaled to stay inside the 28 pt reach.
    private func drawGlow(_ ctx: inout GraphicsContext, frame: MotionFrame, now: TimeInterval) {
        let s = frame.shapeRect
        let rect = CGRect(x: s.minX - 12, y: s.minY - 14, width: s.width + 24, height: s.height + 14 + 12)
        let r = frame.island.bottomRadius + 14
        let path = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                          bottomTrailingRadius: r, topTrailingRadius: 0,
                                          style: .continuous).path(in: rect)
        let turn = (now / 6).truncatingRemainder(dividingBy: 1) * 360
        ctx.drawLayer { layer in
            layer.drawLayer { glow in
                glow.addFilter(.blur(radius: 9))
                // CSS conic angles start at 12 o'clock; SwiftUI's at 3 o'clock.
                glow.fill(path, with: .conicGradient(Gradient(stops: Self.glowStops),
                                                     center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.35),
                                                     angle: .degrees(turn - 90)))
            }
            frame.applyReach(&layer)
        }
    }

    /// Soft drifting stripes (the demo's veil), masked to an ellipse under the island.
    private func drawVeil(_ ctx: inout GraphicsContext, frame: MotionFrame, now: TimeInterval) {
        let s = frame.shapeRect
        let veil = CGRect(x: s.minX - 64, y: s.minY, width: s.width + 128, height: s.height + 50)
        let period: CGFloat = 34
        let drift = CGFloat((now / 4.5).truncatingRemainder(dividingBy: 1)) * 340
        let shift = drift.truncatingRemainder(dividingBy: period)
        let stripe = Gradient(stops: [
            .init(color: MotionColor.rgb(255, 46, 136, 0), location: 0),
            .init(color: MotionColor.rgb(255, 46, 136, 0), location: 10 / 34),
            .init(color: MotionColor.rgb(255, 46, 136, 0.55), location: 16 / 34),
            .init(color: MotionColor.rgb(120, 70, 255, 0.4), location: 24 / 34),
            .init(color: MotionColor.rgb(43, 61, 255, 0), location: 1),
        ])
        ctx.drawLayer { layer in
            layer.drawLayer { stripes in
                stripes.addFilter(.blur(radius: 4))
                stripes.clip(to: Path(veil))
                stripes.translateBy(x: veil.midX, y: veil.midY)
                // CSS 96deg: the gradient runs 6 degrees below horizontal.
                stripes.rotate(by: .degrees(6))
                let half = max(veil.width, veil.height) / 2 + period * 2
                var x = -half - period + shift
                while x < half {
                    stripes.fill(Path(CGRect(x: x, y: -half, width: period, height: 2 * half)),
                                 with: .linearGradient(stripe, startPoint: CGPoint(x: x, y: 0),
                                                       endPoint: CGPoint(x: x + period, y: 0)))
                    x += period
                }
            }
            // radial-gradient(58% 80% at 50% 20%, #000 28%, transparent 72%)
            layer.blendMode = .destinationIn
            layer.drawLayer { mask in
                mask.translateBy(x: veil.midX, y: veil.minY + veil.height * 0.2)
                mask.scaleBy(x: veil.width * 0.58, y: veil.height * 0.8)
                mask.fill(Path(CGRect(x: -2, y: -2, width: 4, height: 4)), with: .radialGradient(
                    Gradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.28),
                                     .init(color: .white.opacity(0), location: 0.72)]),
                    center: .zero, startRadius: 0, endRadius: 1))
            }
            frame.applyReach(&layer)
        }
    }

    /// 1 pt flowing gradient rim, faded into the menu bar at the shoulders.
    private func drawRim(_ ctx: inout GraphicsContext, frame: MotionFrame, now: TimeInterval) {
        let edge = frame.edgePath
        let period: CGFloat = 640
        let shift = CGFloat((now / 5).truncatingRemainder(dividingBy: 1)) * period
        // A repeating gradient: three periods cover any island width.
        let start = frame.shapeRect.minX - period + shift
        var stops: [Gradient.Stop] = []
        for k in 0..<3 {
            for (color, loc) in Self.rimColors {
                stops.append(.init(color: color, location: (CGFloat(k) + CGFloat(loc)) / 3))
            }
        }
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: stops), startPoint: CGPoint(x: start, y: 0), endPoint: CGPoint(x: start + 3 * period, y: 0))
        let width: CGFloat = context.reduceTransparency || contrast == .increased ? 3.2 : 2.6
        let top = frame.shapeRect.minY
        ctx.drawLayer { layer in
            layer.stroke(edge, with: shading, lineWidth: width)
            layer.blendMode = .destinationIn
            layer.fill(Path(CGRect(origin: .zero, size: frame.size)), with: .linearGradient(
                Gradient(colors: [.white.opacity(0), .white]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + 16)))
        }
    }
}

// MARK: - Particle Spark

/// Sixteen sparks burst from the pointer and orbit the outline both ways:
/// white-hot heads, short red trails, falling embers, a faint hot rim.
struct ParticleSparkNotchLayer: View {
    var context: NotchThemeContext
    var debugTime: TimeInterval?

    @StateObject private var model = ParticleSparkModel()
    @Environment(\.colorSchemeContrast) private var contrast

    init(context: NotchThemeContext, debugTime: TimeInterval? = nil) {
        self.context = context
        self.debugTime = debugTime
    }

    private var paused: Bool { debugTime != nil || context.phase == .resting || context.reduceMotion }

    var body: some View {
        MotionStage(island: MotionIsland(context)) { frame in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { timeline in
                let now = debugTime ?? timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, _ in
                    let edge = frame.edgePath
                    let sampler = model.sampler(for: frame, edge: edge)
                    let pointer = frame.pointer(context.pointer)
                    model.update(now: now, phase: context.phase, pointer: pointer, sampler: sampler,
                                 shapeTop: frame.shapeRect.minY, still: context.reduceMotion,
                                 embers: !context.reduceTransparency)
                    draw(&ctx, frame: frame, edge: edge, sampler: sampler, now: context.reduceMotion ? 0 : now)
                }
            }
        }
        // Leaving: the frozen frame fades over 0.3 s (the demo's fade-out),
        // with the timeline already stopped.
        .animation(context.phase == .resting ? .easeOut(duration: 0.3) : nil) {
            $0.opacity(context.phase == .resting ? 0 : 1)
        }
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, frame: MotionFrame, edge: Path,
                      sampler: MotionEdgeSampler, now: TimeInterval) {
        let alpha = model.alpha
        guard alpha > 0.001 else { return }
        let highContrast = contrast == .increased
        let L = sampler.total
        let red = MotionColor.red

        ctx.drawLayer { layer in
            layer.opacity = alpha

            if context.reduceTransparency {
                // No glow: a solid red hairline with solid dots.
                layer.stroke(edge, with: .color(red), lineWidth: 2)
                for spark in model.sparks {
                    let s = sampler.sample(spark.u * L)
                    let p = Self.outward(s, by: 1)
                    let r: CGFloat = highContrast ? 2.4 : 1.8
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(red))
                }
                return
            }

            // Faint hot rim.
            layer.drawLayer { rim in
                rim.addFilter(.shadow(color: MotionColor.rgb(240, 24, 34, 0.9), radius: 3.5))
                rim.stroke(edge, with: .color(red.opacity(highContrast ? 1 : 0.6)), lineWidth: 2)
            }

            layer.blendMode = .plusLighter
            let fadeLen: CGFloat = 16
            let steps = 11
            let sizeBoost: CGFloat = highContrast ? 1.4 : 1
            for spark in model.sparks {
                let l = spark.u * L
                let edgeFade = Double(max(0, min(1, l / fadeLen, (L - l) / fadeLen)))
                guard edgeFade > 0 else { continue }
                let flicker = 0.75 + 0.25 * sin(now * 1000 / 60 + spark.flick)
                let size = spark.size * sizeBoost
                var pts: [CGPoint] = []
                for i in 0..<steps {
                    let li = l - spark.dir * CGFloat(i) * (2.4 + spark.speed / 120)
                    if li < 0 || li > L { break }
                    pts.append(Self.outward(sampler.sample(li), by: 1))
                }
                if pts.count > 1 {
                    for i in stride(from: pts.count - 1, to: 0, by: -1) {
                        let k = 1 - Double(i) / Double(steps)
                        let color: Color = i < 2
                            ? MotionColor.rgb(255, 214, 200, 0.9 * k * edgeFade)
                            : i < 5 ? MotionColor.rgb(255, 92, 72, 0.85 * k * edgeFade)
                            : MotionColor.rgb(240, 24, 34, 0.7 * k * edgeFade)
                        var seg = Path()
                        seg.move(to: pts[i])
                        seg.addLine(to: pts[i - 1])
                        layer.stroke(seg, with: .color(color),
                                     style: StrokeStyle(lineWidth: (2.4 * CGFloat(k) + 0.3) * size, lineCap: .round))
                    }
                }
                if let h = pts.first {
                    let gr = 9 * size
                    layer.fill(Path(ellipseIn: CGRect(x: h.x - gr, y: h.y - gr, width: 2 * gr, height: 2 * gr)),
                               with: .radialGradient(Gradient(colors: [MotionColor.rgb(255, 120, 90, 0.75 * edgeFade * flicker),
                                                                       MotionColor.rgb(240, 24, 34, 0)]),
                                                     center: h, startRadius: 0, endRadius: gr))
                    let hr = 1.25 * size
                    layer.fill(Path(ellipseIn: CGRect(x: h.x - hr, y: h.y - hr, width: 2 * hr, height: 2 * hr)),
                               with: .color(MotionColor.rgb(255, 246, 240, edgeFade)))
                }
            }
            for ember in model.embers {
                let a = max(0, 1 - ember.age / ember.life)
                let r = ember.r * CGFloat(0.5 + a * 0.5)
                layer.fill(Path(ellipseIn: CGRect(x: ember.x - r, y: ember.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(MotionColor.rgb(255, 120 + 100 * a, 80 * a, a)))
            }
            layer.blendMode = .normal
            frame.applyReach(&layer)
        }
    }

    /// Nudges a point on the edge outward so the half hidden behind the body
    /// doesn't eat the spark (outward normal of a clockwise edge is (-ty, tx)).
    private static func outward(_ s: (point: CGPoint, tangent: CGVector), by d: CGFloat) -> CGPoint {
        CGPoint(x: s.point.x - s.tangent.dy * d, y: s.point.y + s.tangent.dx * d)
    }
}

@MainActor
final class ParticleSparkModel: ObservableObject {
    struct Spark {
        var u: CGFloat
        var dir: CGFloat
        var cruise: CGFloat
        var speed: CGFloat
        var size: CGFloat
        var flick: Double
    }

    struct Ember {
        var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat
        var age: Double, life: Double, r: CGFloat
    }

    static let count = 16

    private(set) var sparks: [Spark] = []
    private(set) var embers: [Ember] = []
    private(set) var alpha: Double = 0
    private var lastPhase: NotchThemePhase = .resting
    private var lastTime: TimeInterval?
    private var wasStill = false
    private var random = MotionRandom(state: 0x9E37_79B9_7F4A_7C15)
    private var cachedKey: [CGFloat] = []
    private var cachedSampler: MotionEdgeSampler?

    fileprivate func sampler(for frame: MotionFrame, edge: Path) -> MotionEdgeSampler {
        let key = [frame.shapeRect.minX, frame.shapeRect.minY, frame.shapeRect.width, frame.shapeRect.height,
                   frame.island.topRadius, frame.island.bottomRadius]
        if key == cachedKey, let cachedSampler { return cachedSampler }
        let s = MotionEdgeSampler(path: edge)
        cachedKey = key
        cachedSampler = s
        return s
    }

    private func target(_ phase: NotchThemePhase) -> Double {
        switch phase {
        case .resting: 0
        case .hovered: 1
        case .open: 0.85
        }
    }

    fileprivate func update(now: TimeInterval, phase: NotchThemePhase, pointer: CGPoint,
                            sampler: MotionEdgeSampler, shapeTop: CGFloat, still: Bool, embers allowEmbers: Bool) {
        if still {
            // Reduce Motion: evenly spaced glowing dots, no orbit, no embers.
            if !wasStill || sparks.count != Self.count { spawn(from: 0, still: true) }
            wasStill = true
            embers = []
            alpha = target(phase)
            lastPhase = phase
            lastTime = nil
            return
        }
        if wasStill { sparks = []; wasStill = false }

        if phase != lastPhase {
            if phase != .resting && (lastPhase == .resting || sparks.isEmpty) {
                spawn(from: sampler.nearestFraction(to: pointer), still: false)
                lastTime = now
            }
            if phase == .open { for i in sparks.indices { sparks[i].speed = max(sparks[i].speed, 220) } }
            lastPhase = phase
        }
        guard phase != .resting else { return }

        var elapsed = min(0.5, max(0, now - (lastTime ?? now)))
        lastTime = now
        // Substeps keep the motion right when frames are far apart.
        while elapsed > 0 {
            let dt = min(elapsed, 1.0 / 60)
            elapsed -= dt
            step(dt: dt, phase: phase, sampler: sampler, shapeTop: shapeTop, allowEmbers: allowEmbers)
        }
    }

    private func spawn(from u0: CGFloat, still: Bool) {
        sparks = (0..<Self.count).map { i in
            let dir: CGFloat = i % 5 == 4 ? -1 : (i % 2 == 1 ? 1 : -1)
            let cruise = CGFloat(70 + random.next() * 70)
            let u = still ? (CGFloat(i) + 0.5) / CGFloat(Self.count)
                          : u0 + CGFloat(random.next() - 0.5) * 0.01
            return Spark(u: u, dir: dir, cruise: cruise,
                         speed: still ? cruise : CGFloat(260 + random.next() * 260),
                         size: CGFloat(0.8 + random.next() * 0.7), flick: random.next() * 6.28)
        }
        embers = []
        alpha = still ? alpha : 0
    }

    private func step(dt: Double, phase: NotchThemePhase, sampler: MotionEdgeSampler,
                      shapeTop: CGFloat, allowEmbers: Bool) {
        let t = target(phase)
        alpha += (t - alpha) * min(1, dt * (t > alpha ? 6 : 4))
        if abs(t - alpha) < 0.004 { alpha = t }

        let L = sampler.total
        let cdt = CGFloat(dt)
        for i in sparks.indices {
            var s = sparks[i]
            let cruise = phase == .open ? s.cruise * 1.25 : s.cruise
            s.speed += (cruise - s.speed) * min(1, cdt * 1.6)
            s.u += s.dir * s.speed * cdt / L
            if s.u > 1 { s.u -= 1 }
            if s.u < 0 { s.u += 1 }
            sparks[i] = s
            if allowEmbers, random.next() < dt * (phase == .hovered ? 5 : 2.5) {
                let l = s.u * L
                let sample = sampler.sample(l)
                let p = sample.point, tan = sample.tangent
                let nx = -tan.dy, ny = tan.dx
                let sp = CGFloat(18 + random.next() * 40)
                if p.y > shapeTop + 3 {
                    embers.append(Ember(x: p.x, y: p.y, vx: nx * sp + tan.dx * s.dir * s.speed * 0.25, vy: ny * sp,
                                        age: 0, life: 0.45 + random.next() * 0.5,
                                        r: CGFloat(0.7 + random.next() * 0.9)))
                }
            }
        }
        for i in embers.indices {
            embers[i].age += dt
            embers[i].vy += 70 * cdt
            embers[i].vx *= 1 - cdt * 1.5
            embers[i].x += embers[i].vx * cdt
            embers[i].y += embers[i].vy * cdt
        }
        embers.removeAll { $0.age >= $0.life }
        if embers.count > 90 { embers.removeFirst(embers.count - 90) }
    }
}

// MARK: - Minimal Hairline

/// A 1 px white hairline fades in along the sides and bottom (fading out into
/// the menu bar at the shoulders) and a soft shadow lifts the island. Only
/// opacity changes; nothing runs per frame.
struct MinimalHairlineNotchLayer: View {
    var context: NotchThemeContext

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    init(context: NotchThemeContext) {
        self.context = context
    }

    private var lineOpacity: Double {
        switch context.phase {
        case .resting: 0
        case .hovered: contrast == .increased ? 1 : 0.9
        case .open: contrast == .increased ? 1 : 0.5
        }
    }

    /// The demo's drop shadows (0 8 16 / 0 16 34), kept inside the 28 pt reach.
    private var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch context.phase {
        case .resting: (0, 8, 8)
        case .hovered: (0.42, 8, 8)
        case .open: (0.5, 10, 10)
        }
    }

    private var contactOpacity: Double {
        switch context.phase {
        case .resting: 0
        case .hovered: 0.35
        case .open: 0.3
        }
    }

    var body: some View {
        MotionStage(island: MotionIsland(context)) { frame in
            let top = frame.shapeRect.minY
            let height = max(frame.size.height, 1)
            let hairline = contrast == .increased ? 2.0 : 2 / max(displayScale, 1)
            ZStack {
                // The fill is the body's exact silhouette, so only its shadow shows.
                MotionPathShape(path: frame.closedPath)
                    .fill(Color.black)
                    .animation(.easeOut(duration: 0.22)) {
                        $0.shadow(color: .black.opacity(contactOpacity), radius: 1, y: 1)
                            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
                    }
                MotionPathShape(path: frame.edgePath)
                    .stroke(Color.white, lineWidth: hairline)
                    .mask {
                        LinearGradient(colors: [.clear, .white],
                                       startPoint: UnitPoint(x: 0.5, y: (top + 2) / height),
                                       endPoint: UnitPoint(x: 0.5, y: (top + 18) / height))
                    }
                    .animation(.easeOut(duration: 0.2)) { $0.opacity(lineOpacity) }
            }
        }
        .allowsHitTesting(false)
    }
}
