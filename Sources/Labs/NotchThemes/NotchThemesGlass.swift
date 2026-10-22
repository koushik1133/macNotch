import AppKit
import SwiftUI

// Glass family of notch hover themes (docs/notch-themes G1-G4):
// Liquid Glass Bubble, Frosted Halo, Dewdrop and Glass Pill.
//
// Every layer is drawn BEHIND the black island, in a frame of
// bodySize + 2 * NotchThemeMetrics.maxOutset (plus the flare), centered on the
// island, so anything inside the body is hidden by it and only the band
// around the body shows. Layers never take clicks and never change the body.
//
// Geometry animates with the host's transaction: change `context` inside
// `withAnimation` and the rims grow, shrink and follow the body in step with it.
//
// See-through parts use the system: Liquid Glass (`glassEffect`) on macOS 26+,
// a SwiftUI material on macOS 15. Both sample what is behind the transparent
// notch panel, so no screen capture is needed.

// MARK: - Debug backdrop

/// Offscreen renders cannot show system glass (it is composited by the window
/// server). Test harnesses set `backdrop` to the picture that sits under the
/// layer frame; the glass parts then draw that picture through a software
/// version of each theme's lens instead. Always nil in the app.
enum NotchGlassThemesDebug {
    @MainActor static var backdrop: NSImage?
    /// Clock override for renderers that do not advance TimelineView.
    @MainActor static var now: Date?
}

// MARK: - Geometry

/// Island outline grown by an outset `e`, following the demos' `dims()`:
/// body width + 2e, height + e, flare radius + 0.8e, bottom radius + e.
private struct GlassNotchGeometry {
    var cx: CGFloat
    var top: CGFloat
    var bodyW: CGFloat
    var bodyH: CGFloat
    var topR: CGFloat
    var bottomR: CGFloat

    struct Dims {
        var L: CGFloat, R: CGFloat, B: CGFloat
        var W: CGFloat, H: CGFloat
        var rt: CGFloat, rb: CGFloat
    }

    init(cx: CGFloat, top: CGFloat, bodyW: CGFloat, bodyH: CGFloat, topR: CGFloat, bottomR: CGFloat) {
        self.cx = cx
        self.top = top
        self.bodyW = bodyW
        self.bodyH = bodyH
        self.topR = topR
        self.bottomR = bottomR
    }

    /// The layer frame is centered on the island body.
    init(size: CGSize, context: NotchThemeContext, bottomR: CGFloat? = nil) {
        self.init(
            cx: size.width / 2,
            top: size.height / 2 - context.bodySize.height / 2,
            bodyW: context.bodySize.width,
            bodyH: context.bodySize.height,
            topR: context.topRadius,
            bottomR: bottomR ?? context.bottomRadius
        )
    }

    func dims(_ outset: CGFloat) -> Dims {
        let e = max(-1, outset)
        let W = max(1, bodyW + 2 * e)
        let H = max(1, bodyH + e)
        let rt = max(0.01, topR + e * 0.8)
        let rb = max(0.01, min(bottomR + e, H - rt - 0.5, W / 2))
        return Dims(L: cx - W / 2, R: cx + W / 2, B: top + H, W: W, H: H, rt: rt, rb: rb)
    }

    /// Closed silhouette (top edge glued to the screen edge).
    func filled(_ e: CGFloat) -> Path {
        let d = dims(e)
        let rect = CGRect(x: d.L - d.rt, y: top, width: d.W + 2 * d.rt, height: d.H)
        return IslandShape(topRadius: d.rt, bottomRadius: d.rb).path(in: rect)
    }

    /// Same outline without the top edge, for strokes.
    func outline(_ e: CGFloat) -> Path {
        let closed = filled(e)
        var open = Path()
        closed.forEach { element in
            switch element {
            case .move(let p): open.move(to: p)
            case .line(let p): open.addLine(to: p)
            case .quadCurve(let p, let c): open.addQuadCurve(to: p, control: c)
            case .curve(let p, let c1, let c2): open.addCurve(to: p, control1: c1, control2: c2)
            case .closeSubpath: break
            }
        }
        return open
    }

    /// Approximate length of `outline(e)`, for trimming.
    func outlineLength(_ e: CGFloat) -> CGFloat {
        let d = dims(e)
        let flare = 1.15 * d.rt
        let side = max(0, d.H - d.rt - d.rb)
        let corner = CGFloat.pi * d.rb / 2
        let bottom = max(0, d.W - 2 * d.rb)
        return 2 * flare + 2 * side + 2 * corner + bottom
    }

    /// Points along the visible rim (sides and bottom) with outward normals.
    func rimSamples(_ e: CGFloat, count n: Int) -> [(p: CGPoint, n: CGVector)] {
        let d = dims(e)
        let sideTop = top + d.rt
        let sideLen = max(0, d.H - d.rb - d.rt)
        let arc = CGFloat.pi * d.rb / 2
        let bot = max(0, d.W - 2 * d.rb)
        let segs: [CGFloat] = [sideLen, arc, bot, arc, sideLen]
        let total = segs.reduce(0, +)
        var pts: [(p: CGPoint, n: CGVector)] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            var s = CGFloat(i) / CGFloat(n) * total
            for (k, len) in segs.enumerated() {
                if s <= len || k == 4 {
                    let t = len > 0 ? min(1, max(0, s / len)) : 0
                    switch k {
                    case 0:
                        pts.append((CGPoint(x: d.L, y: sideTop + t * sideLen), CGVector(dx: -1, dy: 0)))
                    case 1:
                        let a = CGFloat.pi - t * .pi / 2
                        pts.append((CGPoint(x: d.L + d.rb + d.rb * cos(a), y: d.B - d.rb + d.rb * sin(a)), CGVector(dx: cos(a), dy: sin(a))))
                    case 2:
                        pts.append((CGPoint(x: d.L + d.rb + t * bot, y: d.B), CGVector(dx: 0, dy: 1)))
                    case 3:
                        let a = CGFloat.pi / 2 - t * .pi / 2
                        pts.append((CGPoint(x: d.R - d.rb + d.rb * cos(a), y: d.B - d.rb + d.rb * sin(a)), CGVector(dx: cos(a), dy: sin(a))))
                    default:
                        pts.append((CGPoint(x: d.R, y: d.B - d.rb - t * sideLen), CGVector(dx: 1, dy: 0)))
                    }
                    break
                }
                s -= len
            }
        }
        return pts
    }
}

/// The island outline grown by `outset`, as an animatable shape so rims move
/// in step with the body when the host animates the context.
private struct GlassNotchShape: Shape {
    enum Kind {
        /// Closed silhouette.
        case filled
        /// Sides and bottom only (no top edge), for strokes.
        case outline
        /// The two flared shoulders of the outline (bubble's specular arcs).
        case shoulders
        /// Band between `outset` and this inner outset.
        case ring(inner: CGFloat)
        /// Everything outside the silhouette: keeps drop shadows from showing
        /// through the see-through glass above them.
        case outside
        /// Bubble's window-reflection glints on the upper sides.
        case glintLeft
        case glintRight
    }

    var bodyW: CGFloat
    var bodyH: CGFloat
    var topR: CGFloat
    var bottomR: CGFloat
    var outset: CGFloat
    var kind: Kind

    init(_ context: NotchThemeContext, outset: CGFloat, bottomR: CGFloat? = nil, kind: Kind = .filled) {
        bodyW = context.bodySize.width
        bodyH = context.bodySize.height
        topR = context.topRadius
        self.bottomR = bottomR ?? context.bottomRadius
        self.outset = outset
        self.kind = kind
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(bodyW, bodyH), AnimatablePair(AnimatablePair(topR, bottomR), outset)) }
        set {
            bodyW = newValue.first.first
            bodyH = newValue.first.second
            topR = newValue.second.first.first
            bottomR = newValue.second.first.second
            outset = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let geo = GlassNotchGeometry(
            cx: rect.midX, top: rect.midY - bodyH / 2,
            bodyW: bodyW, bodyH: bodyH, topR: topR, bottomR: bottomR
        )
        let e = outset
        switch kind {
        case .filled:
            return geo.filled(e)
        case .outline:
            return geo.outline(e)
        case .ring(let inner):
            return geo.filled(e).subtracting(geo.filled(inner))
        case .outside:
            return Path(rect.insetBy(dx: -NotchThemeMetrics.maxOutset, dy: -NotchThemeMetrics.maxOutset))
                .subtracting(geo.filled(e))
        case .shoulders:
            let d = geo.dims(e)
            let len = max(1, geo.outlineLength(e))
            let s1: CGFloat = 1
            let s2 = min(len / 2 - 1, d.rt * 1.4 + 9)
            guard s2 > s1 else { return Path() }
            let outline = geo.outline(e)
            var p = outline.trimmedPath(from: s1 / len, to: s2 / len)
            p.addPath(outline.trimmedPath(from: 1 - s2 / len, to: 1 - s1 / len))
            return p
        case .glintLeft:
            let d = geo.dims(e)
            let c = CGPoint(x: d.L + max(0.8, e * 0.5), y: geo.top + d.rt + 7)
            let rx = max(0.5, e * 0.16), ry = min(7, bodyH * 0.16)
            return Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
        case .glintRight:
            let d = geo.dims(e)
            let c = CGPoint(x: d.R - max(0.8, e * 0.5), y: geo.top + d.rt + 9)
            let rx = max(0.4, e * 0.12), ry = min(4.5, bodyH * 0.1)
            return Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
        }
    }
}

// MARK: - Shared pieces

private func glassHex(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    Color(
        .sRGB,
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255,
        opacity: alpha
    )
}

private func unit(_ p: CGPoint, in size: CGSize) -> UnitPoint {
    UnitPoint(x: p.x / max(1, size.width), y: p.y / max(1, size.height))
}

/// Which system glass a theme asks for.
private enum GlassThemeMaterial {
    case clear
    case regular(tint: Double)
}

/// A see-through region in `shape`: Liquid Glass on macOS 26+, a material on
/// macOS 15, or (offscreen renders only) the debug backdrop through `lens`.
private struct GlassThemeBackdrop<S: Shape, Lens: View>: View {
    let shape: S
    let material: GlassThemeMaterial
    let active: Bool
    let lens: (Image) -> Lens

    init(shape: S, material: GlassThemeMaterial, active: Bool, @ViewBuilder lens: @escaping (Image) -> Lens) {
        self.shape = shape
        self.material = material
        self.active = active
        self.lens = lens
    }

    var body: some View {
        if let picture = NotchGlassThemesDebug.backdrop {
            lens(Image(nsImage: picture).resizable())
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(glass, in: shape)
        } else if active {
            shape.fill(.ultraThinMaterial)
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        guard active else { return .identity }
        switch material {
        case .clear: return .clear
        case .regular(let tint): return .regular.tint(.white.opacity(tint))
        }
    }
}

/// Fine grain for the frost (Frosted Halo), built once.
@MainActor
private enum GlassGrain {
    static let image: Image = {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 9
        for i in 0..<(side * side) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let r = Double(seed) / Double(UInt32.max)
            let a = UInt8(max(0, min(1, 1.4 * r - 0.5)) * 255)
            pixels[i * 4 + 0] = a // premultiplied white
            pixels[i * 4 + 1] = a
            pixels[i * 4 + 2] = a
            pixels[i * 4 + 3] = a
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let cg: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let cg else { return Image(systemName: "circle.fill") }
        return Image(decorative: cg, scale: 2)
    }()
}

// MARK: - G1 Liquid Glass Bubble

/// A soap-bubble rim: refracted glass band, rotating thin-film sheen, white
/// specular arcs on the shoulders, inner shadow and two window glints.
/// Resting: nothing. Hovered: 9 pt rim at full strength, sheen turning.
/// Open: the same rim at 85 %.
struct LiquidGlassBubbleNotchLayer: View {
    let context: NotchThemeContext

    /// The demo swells the body 220x38 -> 236x44 on hover; capped at the
    /// contract's 6 %. The host applies it to the body if it wants the swell.
    static let hoverSwell: CGFloat = 1.06

    private static let iridescent: [Color] = [
        glassHex(0x7AF7FF), glassHex(0xA98BFF), glassHex(0xFF7AD8),
        glassHex(0xFFD66B), glassHex(0x7DFFC6), glassHex(0x7AF7FF),
    ]

    var body: some View {
        GeometryReader { geo in
            // The sheen turns ~22 deg/s: 30 fps is plenty and halves the cost.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: context.phase == .resting || context.reduceMotion)) { timeline in
                rim(size: geo.size, time: (NotchGlassThemesDebug.now ?? timeline.date).timeIntervalSinceReferenceDate)
            }
        }
        .animation(NotchThemeTiming.islandSpring, value: context.phase)
        .allowsHitTesting(false)
    }

    private func rim(size: CGSize, time: TimeInterval) -> some View {
        let phase = context.phase
        let e: CGFloat = phase == .resting ? 0 : 9
        let strength: Double = switch phase {
        case .resting: 0
        case .hovered: 1
        case .open: 0.85
        }
        let rt = context.reduceTransparency
        let geo = GlassNotchGeometry(size: size, context: context)
        let d = geo.dims(e)
        let shape = { (outset: CGFloat, kind: GlassNotchShape.Kind) in
            GlassNotchShape(context, outset: outset, kind: kind)
        }

        // Thin-film sheen: a linear rainbow whose axis turns ~22 deg/s.
        let angle = context.reduceMotion ? 0.7 : (time * 1000 / 2600).truncatingRemainder(dividingBy: 2 * .pi)
        let radius = d.W / 2
        let cy = geo.top + geo.bodyH / 2
        let sheen = LinearGradient(
            colors: Self.iridescent,
            startPoint: unit(CGPoint(x: geo.cx - cos(angle) * radius, y: cy - sin(angle) * radius), in: size),
            endPoint: unit(CGPoint(x: geo.cx + cos(angle) * radius, y: cy + sin(angle) * radius), in: size)
        )
        let specular = LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white.opacity(0.4), location: 0.3),
                .init(color: .white.opacity(0), location: 0.62),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: unit(CGPoint(x: geo.cx, y: geo.top), in: size),
            endPoint: unit(CGPoint(x: geo.cx, y: geo.top + d.H), in: size)
        )
        let caustic = RadialGradient(
            stops: [
                .init(color: .white.opacity(0.9), location: 0),
                .init(color: .white.opacity(0.3), location: 0.5),
                .init(color: .white.opacity(0), location: 1),
            ],
            center: unit(CGPoint(x: geo.cx, y: geo.top + d.H), in: size),
            startRadius: 0, endRadius: d.W * 0.48
        )
        // Lens: wallpaper seen through 7 pt of glass, pushed outward at the rim.
        let lensAnchor = unit(CGPoint(x: geo.cx, y: geo.top), in: size)
        let lensX = (d.W / 2) / (d.W / 2 + 7)
        let lensY = d.H / (d.H + 7)

        return ZStack {
            // Soft drop shadow lifting the bubble off the desktop.
            shape(e, .filled)
                .fill(Color.black.opacity(0.55))
                .offset(y: 5)
                .blur(radius: 6)
                .mask(shape(e, .outside))

            if rt {
                // Reduce Transparency: opaque graphite ring, same lines.
                shape(e, .filled).fill(glassHex(0x2A2A30))
            } else {
                GlassThemeBackdrop(shape: shape(e, .filled), material: .clear, active: phase != .resting) { picture in
                    picture
                        .scaleEffect(x: lensX, y: lensY, anchor: lensAnchor)
                        .saturation(1.7)
                        .brightness(0.04)
                        .contrast(1.12)
                        .mask(shape(e, .filled))
                }
                // Thin film tint over the glass.
                shape(e, .filled)
                    .fill(sheen)
                    .opacity(0.16)
                    .blendMode(.screen)
                // Inner shadow where the rim meets the black body.
                shape(0, .outline)
                    .stroke(Color.black, lineWidth: 6)
                    .blur(radius: 2)
                    .opacity(0.75)
                    .mask(shape(e, .filled))
            }

            shape(0.4, .outline).stroke(Color.white.opacity(0.16), lineWidth: 0.8)
            if !rt {
                shape(e * 0.45, .outline)
                    .stroke(sheen, lineWidth: 1)
                    .opacity(0.35)
                    .blendMode(.screen)
                shape(max(0, e - 1.3), .outline)
                    .stroke(sheen, lineWidth: 2.4)
                    .opacity(0.8)
                    .blendMode(.screen)
            }
            shape(max(0, e - 0.35), .outline).stroke(Color.white.opacity(0.3), lineWidth: 0.7)
            shape(max(0, e - 0.75), .outline)
                .stroke(specular, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            // Bright specular arcs on both shoulders.
            shape(max(0, e - 0.75), .shoulders)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .blur(radius: 0.7)
            shape(max(0, e - 1.1), .outline)
                .stroke(caustic, lineWidth: 2.2)
                .blur(radius: 0.7)
            shape(e, .glintLeft).fill(Color.white).blur(radius: 0.7).opacity(0.85)
            shape(e, .glintRight).fill(Color.white).blur(radius: 0.7).opacity(0.5)
        }
        .frame(width: size.width, height: size.height)
        .opacity(strength)
    }
}

// MARK: - G2 Frosted Halo

/// A frosted-glass ring blooms out of the notch: heavy blur, 12 % white,
/// grain, top light and hairlines, with one light pulse on hover entry.
/// Resting: nothing. Hovered: 15 pt halo. Open: 12 pt frame at 90 %.
struct FrostedHaloNotchLayer: View {
    let context: NotchThemeContext
    @StateObject private var pulse = FrostedHaloPulse()

    /// Demo: the island barely grows (220x38 -> 224x40).
    static let hoverSwell: CGFloat = 1.02

    var body: some View {
        GeometryReader { geo in
            ZStack {
                halo(size: geo.size)
                TimelineView(.animation(minimumInterval: nil, paused: pulse.start == nil)) { timeline in
                    pulseRing(at: NotchGlassThemesDebug.now ?? timeline.date)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(NotchThemeTiming.islandSpring, value: context.phase)
        .allowsHitTesting(false)
        .onChange(of: context.phase) { old, new in
            if old == .resting, new == .hovered, !context.reduceMotion { pulse.fire() }
        }
    }

    private var outset: CGFloat {
        switch context.phase {
        case .resting: 0
        case .hovered: 15
        case .open: 12
        }
    }

    private func halo(size: CGSize) -> some View {
        let phase = context.phase
        let e = outset
        let strength: Double = switch phase {
        case .resting: 0
        case .hovered: 1
        case .open: 0.9
        }
        let rt = context.reduceTransparency
        let geo = GlassNotchGeometry(size: size, context: context)
        let d = geo.dims(e)
        let shape = { (outset: CGFloat, kind: GlassNotchShape.Kind) in
            GlassNotchShape(context, outset: outset, kind: kind)
        }
        let topLight = LinearGradient(
            stops: [
                .init(color: .white.opacity(0.22), location: 0),
                .init(color: .white.opacity(0.04), location: 0.6),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: unit(CGPoint(x: geo.cx, y: geo.top), in: size),
            endPoint: unit(CGPoint(x: geo.cx, y: geo.top + d.H), in: size)
        )

        return ZStack {
            if !rt {
                // Soft light spill just outside the frost.
                shape(e + 3, .filled).fill(Color.white.opacity(0.16)).blur(radius: 5)
            }
            shape(e, .filled)
                .fill(glassHex(0x1A1030, 0.35))
                .offset(y: 4)
                .blur(radius: 4)
                .mask(shape(e, .outside))

            if rt {
                shape(e, .filled).fill(glassHex(0x3A3A40))
            } else {
                GlassThemeBackdrop(shape: shape(e, .filled), material: .regular(tint: 0.12), active: phase != .resting) { picture in
                    picture
                        .blur(radius: 9)
                        .saturation(1.35)
                        .brightness(0.03)
                        .mask(shape(e, .filled))
                }
                shape(e, .filled).fill(Color.white.opacity(0.12))
                GlassGrain.image
                    .resizable(resizingMode: .tile)
                    .opacity(0.08)
                    .mask(shape(e, .filled))
                shape(e, .filled).fill(topLight)
            }

            shape(0.35, .outline).stroke(Color.white.opacity(0.22), lineWidth: 0.7)
            shape(max(0, e - 0.45), .outline).stroke(Color.white.opacity(0.6), lineWidth: 0.9)
            if !rt {
                shape(max(0, e - 1), .outline)
                    .stroke(Color.white.opacity(0.35), lineWidth: 2.5)
                    .blur(radius: 0.8)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(strength)
    }

    /// One thin light ring that expands from the halo edge to the edge of the
    /// allowed outset and fades over 0.7 s.
    @ViewBuilder
    private func pulseRing(at date: Date) -> some View {
        if let start = pulse.start {
            let p = min(1, max(0, date.timeIntervalSince(start) / FrostedHaloPulse.duration))
            let q = 1 - pow(1 - p, 3)
            let from: CGFloat = 16
            let to = NotchThemeMetrics.maxOutset - 1
            GlassNotchShape(context, outset: from + (to - from) * q, kind: .outline)
                .stroke(Color.white, lineWidth: 1.8 * (1 - p) + 0.3)
                .opacity(0.55 * (1 - p))
                .transaction { $0.animation = nil }
        }
    }
}

@MainActor
private final class FrostedHaloPulse: ObservableObject {
    static let duration: TimeInterval = 0.7
    @Published private(set) var start: Date?
    private var token = 0

    func fire() {
        token += 1
        let mine = token
        start = NotchGlassThemesDebug.now ?? Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(760))
            guard let self, self.token == mine else { return }
            self.start = nil
        }
    }
}

// MARK: - G3 Dewdrop

/// A drop of water rides the rim and follows the pointer: a lens with
/// specular dots, meniscus and caustic, a wet rim lit near the drop and four
/// micro beads. Resting: nothing. Hovered: 21 pt drop. Open: 24 pt drop.
struct DewdropNotchLayer: View {
    let context: NotchThemeContext
    @StateObject private var motion = DewdropMotion()

    /// Demo: 220x38 -> 224x40.
    static let hoverSwell: CGFloat = 1.02

    private static let microBeads: [Double] = [0.1, 0.27, 0.71, 0.9]

    var body: some View {
        GeometryReader { geo in
            let target = dropTarget(size: geo.size)
            let paused = context.phase == .resting || context.reduceMotion || !motion.needsTicks(toward: target)
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
                let position = motion.advance(
                    to: target,
                    at: NotchGlassThemesDebug.now ?? timeline.date,
                    springy: !context.reduceMotion,
                    resting: context.phase == .resting
                )
                scene(size: geo.size, drop: position, velocity: motion.velocity)
            }
        }
        .animation(NotchThemeTiming.islandSpring, value: context.phase)
        .allowsHitTesting(false)
    }

    private var dew: CGFloat {
        switch context.phase {
        case .resting: 0
        case .hovered: 1
        case .open: 12 / 10.5
        }
    }

    private var radius: CGFloat { 10.5 * max(dew, 0.6) }

    /// Nearest rim point to the pointer, pushed out along the normal.
    private func dropTarget(size: CGSize) -> CGPoint {
        let geo = GlassNotchGeometry(size: size, context: context)
        let samples = geo.rimSamples(0, count: 140)
        let pointer = context.pointer ?? motion.lastPointer ?? CGPoint(x: geo.cx + 40, y: geo.top + geo.bodyH)
        if context.pointer != nil { motion.lastPointer = context.pointer }
        var best = samples[0]
        var bestDistance = CGFloat.infinity
        for s in samples {
            let dd = (s.p.x - pointer.x) * (s.p.x - pointer.x) + (s.p.y - pointer.y) * (s.p.y - pointer.y)
            if dd < bestDistance { bestDistance = dd; best = s }
        }
        // The layer sits behind the black body, so the drop hangs just
        // outside the rim (the demo drew it over the body edge).
        let off = radius * 0.85 + 0.5
        return CGPoint(x: best.p.x + best.n.dx * off, y: best.p.y + best.n.dy * off)
    }

    private func scene(size: CGSize, drop: CGPoint, velocity: CGVector) -> some View {
        let rt = context.reduceTransparency
        let wet: Double = switch context.phase {
        case .resting: 0
        case .hovered: 1
        case .open: 0.85
        }
        let r = radius
        let geo = GlassNotchGeometry(size: size, context: context)
        let beads = geo.rimSamples(0.9, count: 100)
        let wetStroke: AnyShapeStyle = rt
            ? AnyShapeStyle(Color.white.opacity(0.4))
            : AnyShapeStyle(RadialGradient(
                stops: [
                    .init(color: glassHex(0xDFF8FF, 0.8), location: 0),
                    .init(color: glassHex(0xDFF8FF, 0.28), location: 0.35),
                    .init(color: glassHex(0xDFF8FF, 0.07), location: 1),
                ],
                center: unit(drop, in: size), startRadius: 0, endRadius: 95
            ))
        let speed = hypot(velocity.dx, velocity.dy)
        let stretch = context.reduceMotion ? 0 : min(0.28, speed / 900)
        let heading = Angle(radians: atan2(velocity.dy, velocity.dx))

        return ZStack {
            // Wet rim, brightest near the drop.
            GlassNotchShape(context, outset: 0.6, kind: .outline)
                .stroke(wetStroke, lineWidth: 1.2)
                .opacity(wet)

            // Micro dew beads fixed on the rim.
            ForEach(Array(Self.microBeads.enumerated()), id: \.offset) { _, fraction in
                let p = beads[min(beads.count - 1, Int((fraction * 100).rounded()))].p
                ZStack {
                    Circle()
                        .fill(Color(.sRGB, red: 170 / 255, green: 230 / 255, blue: 1, opacity: 0.35))
                        .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 0.4))
                        .frame(width: 3.8, height: 3.8)
                    Circle().fill(Color.white).frame(width: 1.2, height: 1.2).offset(x: -0.6, y: -0.6)
                }
                .position(p)
                .opacity(wet * 0.9)
            }

            // Drop shadow.
            Ellipse()
                .fill(Color.black.opacity(0.45))
                .frame(width: 2 * r * 0.95, height: 2 * r * 0.75)
                .blur(radius: 2.2)
                .position(x: drop.x + 1.2, y: drop.y + 3)

            // Lens.
            if !rt, NotchGlassThemesDebug.backdrop != nil {
                GlassThemeBackdrop(shape: Circle(), material: .clear, active: true) { picture in
                    // Wallpaper under the drop, magnified 1.65x and upside down.
                    picture
                        .scaleEffect(-1.65, anchor: unit(drop, in: size))
                        .saturation(1.5)
                        .brightness(0.05)
                        .contrast(1.2)
                        .mask(Circle().frame(width: 2 * r, height: 2 * r).position(drop))
                }
            }
            dropBody(radius: r, transparent: !rt)
                .rotationEffect(-heading)
                .scaleEffect(x: 1 + stretch, y: 1 - stretch * 0.5)
                .rotationEffect(heading)
                .position(drop)
        }
        .frame(width: size.width, height: size.height)
        .opacity(Double(min(1, dew * 1.2)))
    }

    /// The drop itself in a local square centered on the drop.
    private func dropBody(radius r: CGFloat, transparent: Bool) -> some View {
        let side = 2 * r
        let c = CGPoint(x: r, y: r)
        let rc = r * 0.72
        let caustic = Path { p in
            p.addArc(center: c, radius: rc, startAngle: .radians(0.2), endAngle: .radians(1.45), clockwise: false)
        }
        return ZStack {
            if !transparent {
                Circle().fill(glassHex(0x2C2C31))
            } else if NotchGlassThemesDebug.backdrop == nil {
                GlassThemeBackdrop(shape: Circle(), material: .clear, active: context.phase != .resting) { _ in EmptyView() }
            }
            if transparent {
                // Meniscus: darker toward the edge, a little light top-left.
                Circle().fill(RadialGradient(
                    stops: [
                        .init(color: .white.opacity(0.10), location: 0),
                        .init(color: .black.opacity(0), location: 0.55),
                        .init(color: Color(.sRGB, red: 0, green: 10 / 255, blue: 20 / 255, opacity: 0.32), location: 0.86),
                        .init(color: Color(.sRGB, red: 0, green: 10 / 255, blue: 20 / 255, opacity: 0.7), location: 1),
                    ],
                    center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: r * 1.18
                ))
                caustic
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .opacity(0.6)
                    .blur(radius: 0.6)
            }
            Circle().stroke(Color.white.opacity(0.7), lineWidth: 0.7)
            Ellipse()
                .fill(Color.white.opacity(0.95))
                .frame(width: r * 0.52, height: r * 0.30)
                .rotationEffect(.degrees(-38))
                .position(x: r - r * 0.38, y: r - r * 0.42)
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: r * 0.18, height: r * 0.18)
                .position(x: r + r * 0.34, y: r + r * 0.38)
        }
        .frame(width: side, height: side)
    }
}

/// Spring that pulls the drop toward its rim target (response 0.25, damping
/// 0.7, as in the demo). Ticks only while the drop is moving.
@MainActor
private final class DewdropMotion: ObservableObject {
    private(set) var position: CGPoint?
    private(set) var velocity = CGVector.zero
    var lastPointer: CGPoint?
    private var lastDate: Date?
    private var settled = true
    private var snapNext = true

    func needsTicks(toward target: CGPoint) -> Bool {
        guard let position else { return true }
        return !settled || hypot(position.x - target.x, position.y - target.y) > 0.05
    }

    func advance(to target: CGPoint, at date: Date, springy: Bool, resting: Bool) -> CGPoint {
        if resting {
            // Keep drawing where it was while it fades; start fresh next hover.
            snapNext = true
            lastDate = nil
            velocity = .zero
            return position ?? target
        }
        defer { lastDate = date }
        guard springy, !snapNext, let p = position, let last = lastDate else {
            snapNext = false
            position = target
            velocity = .zero
            settled = true
            return target
        }
        let dt = min(max(date.timeIntervalSince(last), 0), 1.0 / 30)
        guard dt > 0 else { return p }
        let w = 2 * Double.pi / 0.25
        let k = w * w, c = 2 * 0.7 * w
        let n = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Double(n)
        var x = Double(p.x), y = Double(p.y)
        var vx = Double(velocity.dx), vy = Double(velocity.dy)
        for _ in 0..<n {
            vx += (-k * (x - Double(target.x)) - c * vx) * h
            vy += (-k * (y - Double(target.y)) - c * vy) * h
            x += vx * h
            y += vy * h
        }
        let moving = hypot(x - Double(target.x), y - Double(target.y)) > 0.05 || hypot(vx, vy) > 1
        if moving {
            position = CGPoint(x: x, y: y)
            velocity = CGVector(dx: vx, dy: vy)
            settled = false
        } else {
            position = target
            velocity = .zero
            if !settled {
                settled = true
                // Re-render once so the timeline pauses.
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
        }
        return position ?? target
    }
}

// MARK: - G4 Glass Pill

/// A clear Liquid Glass shell around the island with pill-round bottom
/// corners, rim light on two opposite edges and a soft lifted shadow.
/// Resting: nothing. Hovered: 11 pt shell, pill bottom. Open: 12 pt shell.
struct GlassPillNotchLayer: View {
    let context: NotchThemeContext

    /// Demo: 220x38 -> 238x42 (capped at 6 %).
    static let hoverSwell: CGFloat = 1.06
    /// The demo also rounds the body's own bottom corners into a pill
    /// (radius = height / 2) while hovered. The layer cannot change the body;
    /// the host may pass this to IslandShape for the full morph.
    static func hoveredBodyBottomRadius(bodyHeight: CGFloat) -> CGFloat { bodyHeight / 2 }

    private static let bands = 5
    private static let maxDisplacement: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            shell(size: geo.size)
        }
        .animation(NotchThemeTiming.islandSpring, value: context.phase)
        .allowsHitTesting(false)
    }

    private func shell(size: CGSize) -> some View {
        let phase = context.phase
        let e: CGFloat = switch phase {
        case .resting: 0
        case .hovered: 11
        case .open: 12
        }
        let strength: Double = phase == .resting ? 0 : 1
        let rt = context.reduceTransparency
        // Outer shell is a pill while hovered.
        let pillBottom = phase == .hovered ? context.bodySize.height / 2 : context.bottomRadius
        let geo = GlassNotchGeometry(size: size, context: context, bottomR: pillBottom)
        let d = geo.dims(e)
        let shape = { (outset: CGFloat, kind: GlassNotchShape.Kind) in
            GlassNotchShape(context, outset: outset, bottomR: pillBottom, kind: kind)
        }
        let rimLight = LinearGradient(
            stops: [
                .init(color: .white.opacity(0.95), location: 0),
                .init(color: .white.opacity(0.25), location: 0.2),
                .init(color: .white.opacity(0.06), location: 0.5),
                .init(color: .white.opacity(0.3), location: 0.8),
                .init(color: .white.opacity(0.9), location: 1),
            ],
            startPoint: unit(CGPoint(x: d.L - d.rt, y: geo.top), in: size),
            endPoint: unit(CGPoint(x: d.R + d.rt, y: geo.top + d.H), in: size)
        )
        let bottomLight = LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0), location: 0.6),
                .init(color: .white.opacity(0.45), location: 1),
            ],
            startPoint: unit(CGPoint(x: geo.cx, y: geo.top), in: size),
            endPoint: unit(CGPoint(x: geo.cx, y: geo.top + d.H), in: size)
        )

        return ZStack {
            // Large soft shadow plus a tight contact shadow.
            shape(e, .filled)
                .fill(glassHex(0x00081C, 0.42))
                .offset(y: 5)
                .blur(radius: 6)
                .mask(shape(e, .outside))
            shape(e, .filled)
                .fill(glassHex(0x00081C, 0.3))
                .offset(y: 1.5)
                .blur(radius: 2.5)
                .mask(shape(e, .outside))

            if rt {
                shape(e, .filled).fill(glassHex(0x3C3C42))
            } else {
                GlassThemeBackdrop(shape: shape(e, .filled), material: .clear, active: phase != .resting) { picture in
                    // Five concentric bands sample the wallpaper from farther
                    // out toward the edge, so lines bend like thick glass.
                    ZStack {
                        ForEach(0..<Self.bands, id: \.self) { i in
                            let e0 = e * CGFloat(i) / CGFloat(Self.bands)
                            let e1 = e * CGFloat(i + 1) / CGFloat(Self.bands)
                            let k = (CGFloat(i) + 0.5) / CGFloat(Self.bands)
                            let disp = Self.maxDisplacement * k * k * (e / 11)
                            let dd = geo.dims(e1)
                            picture
                                .scaleEffect(
                                    x: (dd.W / 2) / (dd.W / 2 + disp),
                                    y: dd.H / (dd.H + disp),
                                    anchor: unit(CGPoint(x: geo.cx, y: geo.top), in: size)
                                )
                                .saturation(1.25)
                                .brightness(0.03)
                                .mask(shape(e1 + (i == Self.bands - 1 ? 0 : 0.4), .ring(inner: e0)))
                        }
                    }
                }
                // Clear body: very light tint.
                shape(e, .filled).fill(Color.white.opacity(0.06))
            }

            // Dark line where glass meets the black body (real body corners).
            GlassNotchShape(context, outset: 0.2, kind: .outline)
                .stroke(Color.black.opacity(0.7), lineWidth: 1.6)
            shape(e * 0.35, .outline).stroke(Color.white.opacity(0.14), lineWidth: 0.6)
            if !rt {
                shape(max(0, e - 2.5), .outline)
                    .stroke(bottomLight, lineWidth: 3)
                    .blur(radius: 1.5)
            }
            // Rim light, brightest top-left and bottom-right.
            shape(max(0, e - 0.65), .outline).stroke(rimLight, lineWidth: 1.3)
        }
        .frame(width: size.width, height: size.height)
        .opacity(strength)
    }
}
