import SwiftUI

// MARK: - Glow family: Red Rim, Conic Sweep, Breathing Pulse, Neon Tube
//
// Ports of docs/notch-themes/{sparkv-red-rim, conic-sweep, breathing-pulse,
// neon-tube}.html. Every layer is drawn BEHIND the black island body in a
// frame of (body + flare) + 2 * NotchThemeMetrics.maxOutset, with the island
// rect inset by maxOutset on every side. Because the body covers the inner
// half of any stroke centred on the outline, lines that straddle the edge in
// the HTML demos are drawn here as bands just outside the edge, at the same
// visible thickness. Effects fade to nothing at the island's top edge (the
// demos' 9 pt "topfade" mask) and softly at the frame edge, so nothing is
// clipped hard. Nothing runs per frame at .resting: timed parts live inside
// views that only exist while hovered or open, driven by TimelineView.

// MARK: Shared geometry

/// Frame and island rect for a glow layer.
struct NotchGlowGeometry {
    static let outset = NotchThemeMetrics.maxOutset

    let size: CGSize
    let island: CGRect

    init(_ context: NotchThemeContext) {
        let o = Self.outset
        let w = context.bodySize.width + 2 * context.topRadius
        let h = context.bodySize.height
        size = CGSize(width: w + 2 * o, height: h + 2 * o)
        island = CGRect(x: o, y: o, width: w, height: h)
    }
}

/// The island outline without its closing top edge (the demos' `outline`
/// path), laid out in the layer frame. Optionally scaled about the island's
/// top centre, for the Breathing Pulse rings. Radii animate with the island.
struct NotchGlowOutline: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), AnimatablePair(scaleX, scaleY)) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            scaleX = newValue.second.first
            scaleY = newValue.second.second
        }
    }

    init(_ context: NotchThemeContext, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        topRadius = context.topRadius
        bottomRadius = context.bottomRadius
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    func path(in rect: CGRect) -> Path {
        let o = NotchGlowGeometry.outset
        let island = rect.insetBy(dx: o, dy: o)
        guard island.width > 0, island.height > 0 else { return Path() }
        let closed = IslandShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: island)
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
        guard scaleX != 1 || scaleY != 1 else { return open }
        let transform = CGAffineTransform(translationX: island.midX, y: island.minY)
            .scaledBy(x: scaleX, y: scaleY)
            .translatedBy(x: -island.midX, y: -island.minY)
        return open.applying(transform)
    }
}

/// A line from `inner` to `outer` points outside the island edge. The inner
/// part of the doubled stroke falls under the black body; when `inner` > 0 it
/// is also cut out so the band floats off the edge (the neon core).
struct NotchGlowBand<Style: ShapeStyle>: View {
    let shape: NotchGlowOutline
    let style: Style
    var inner: CGFloat = 0
    let outer: CGFloat

    var body: some View {
        if inner <= 0 {
            shape.stroke(style, style: Self.stroke(2 * outer))
        } else {
            ZStack {
                shape.stroke(style, style: Self.stroke(2 * outer))
                shape.stroke(Color.black, style: Self.stroke(2 * inner)).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }

    static func stroke(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// Alpha mask: nothing above the island top, a 9 pt fade-in below it (the
/// demos' topfade), and a 6 pt fade at the other frame edges.
struct NotchGlowEdgeMask: View {
    let size: CGSize

    var body: some View {
        let o = NotchGlowGeometry.outset
        let h = max(size.height, 1)
        let w = max(size.width, 1)
        let edge: CGFloat = 6
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: o / h),
            .init(color: .white, location: min(1, (o + 9) / h)),
            .init(color: .white, location: max(0, (h - edge) / h)),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: edge / w),
                .init(color: .white, location: 1 - edge / w),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .frame(width: size.width, height: size.height)
    }
}

// MARK: Shared timing

/// Remembers when its view was inserted: the start of the hover, since the
/// timed views only exist while the island is hovered or open.
final class NotchGlowClock: ObservableObject {
    let start = Date()
}

/// Ticks at `interval` from now, stopping at `start + duration` when given
/// (the last entry lands exactly on the end, so the final frame is steady).
struct NotchGlowSchedule: TimelineSchedule {
    let start: Date
    let interval: TimeInterval
    let duration: TimeInterval?

    struct Entries: Sequence, IteratorProtocol {
        var current: Date?
        let step: TimeInterval
        let end: Date?

        mutating func next() -> Date? {
            guard let date = current else { return nil }
            if let end, date >= end {
                current = nil
            } else {
                let following = date.addingTimeInterval(step)
                if let end { current = Swift.min(following, end) } else { current = following }
            }
            return date
        }
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let step = mode == .lowFrequency ? 1.0 : interval
        return Entries(current: startDate, step: step, end: duration.map { start.addingTimeInterval($0) })
    }
}

/// A TimelineView whose content gets seconds since the hover began.
struct NotchGlowTimeline<Content: View>: View {
    let interval: TimeInterval
    let duration: TimeInterval?
    let content: (Double) -> Content
    @StateObject private var clock = NotchGlowClock()
    @ObservedObject private var energy = SparkVEnergy.shared

    init(interval: TimeInterval = 1.0 / 30.0, duration: TimeInterval? = nil, @ViewBuilder content: @escaping (Double) -> Content) {
        self.interval = interval
        self.duration = duration
        self.content = content
    }

    var body: some View {
        let start = clock.start
        // Half the frame rate in Low Power Mode or on a warm Mac.
        let step = energy.isConstrained ? interval * 2 : interval
        TimelineView(NotchGlowSchedule(start: start, interval: step, duration: duration)) { timeline in
            content(max(0, timeline.date.timeIntervalSince(start)))
        }
    }
}

/// Interpolates CSS-style keyframes. `stops` are (offset 0...1, value).
/// `easeInOut` applies CSS ease-in-out to each segment, as an
/// `animation-timing-function` does; `linear` interpolates straight.
func notchGlowKeyframes(_ x: Double, _ stops: [(Double, Double)], easeInOut: Bool) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if x <= first.0 { return first.1 }
    for i in 1..<stops.count {
        let a = stops[i - 1], b = stops[i]
        if x <= b.0 {
            let span = b.0 - a.0
            let u = span > 0 ? (x - a.0) / span : 1
            let e = easeInOut ? notchGlowEaseInOut(u) : u
            return a.1 + (b.1 - a.1) * e
        }
    }
    return last.1
}

/// CSS `ease-in-out`: cubic-bezier(0.42, 0, 0.58, 1).
func notchGlowEaseInOut(_ x: Double) -> Double {
    func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }
    var lo = 0.0, hi = 1.0
    for _ in 0..<24 {
        let mid = (lo + hi) / 2
        if bezier(mid, 0.42, 0.58) < x { lo = mid } else { hi = mid }
    }
    let t = (lo + hi) / 2
    return bezier(t, 0, 1)
}

private func glowHex(_ value: UInt32, _ alpha: Double = 1) -> Color {
    Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255,
        opacity: alpha
    )
}

private let glowRed = glowHex(0xF01822)
private let glowPaper = glowHex(0xF7F7F5)

// MARK: - SparkV Red Rim

/// A 1.7 pt signal-red rim traces the outline from the bottom centre up both
/// sides in 460 ms, over a soft red bloom and a tight halo, with a white-hot
/// specular core at the lowest point. Then it holds still (0 frames idle).
/// Open: bloom 42 %, halo 70 %, specular 60 %. Reduce Motion: no trace, a
/// 150 ms crossfade. Reduce Transparency: no bloom; a solid halo.
struct RedRimNotchLayer: View {
    let context: NotchThemeContext

    var body: some View {
        let geo = NotchGlowGeometry(context)
        let outline = NotchGlowOutline(context)
        let on = context.phase != .resting
        let open = context.phase == .open
        let rm = context.reduceMotion
        let rt = context.reduceTransparency
        let fade = Animation.easeOut(duration: 0.15)
        // Leaving is quicker than arriving and never eases in: a strong
        // ease-out, so the glow answers the pointer leaving at once.
        let leave = SparkVMotion.easeOut(SparkVMotion.Duration.standard)

        // rrGrad / rrSpec are userSpaceOnUse: x ±170 and ±110 from the centre.
        let w = geo.size.width
        let rimGradient = LinearGradient(
            stops: [
                .init(color: glowRed, location: 0),
                .init(color: glowHex(0xFF5A61), location: 0.5),
                .init(color: glowRed, location: 1),
            ],
            startPoint: UnitPoint(x: (w / 2 - 170) / w, y: 0.5),
            endPoint: UnitPoint(x: (w / 2 + 170) / w, y: 0.5)
        )
        let specGradient = LinearGradient(
            stops: [
                .init(color: glowHex(0xFFE1E2, 0), location: 0),
                .init(color: glowHex(0xFFE1E2, 0.95), location: 0.5),
                .init(color: glowHex(0xFFE1E2, 0), location: 1),
            ],
            startPoint: UnitPoint(x: (w / 2 - 110) / w, y: 0.5),
            endPoint: UnitPoint(x: (w / 2 + 110) / w, y: 0.5)
        )
        let trace: CGFloat = (on || rm) ? 1 : 0

        ZStack {
            if !rt {
                // .rr-bloom: 16 pt red stroke, blur 16.
                // Animations are scoped to opacity (and to the trace mask
                // below) so the outline itself keeps following the island's
                // spring when the drawer opens or closes.
                outline
                    .stroke(glowRed, lineWidth: 16)
                    .blur(radius: 14)
                    .animation(rm ? fade : (on ? .easeInOut(duration: 0.55).delay(0.14) : leave)) {
                        $0.opacity(on ? (open ? 0.42 : 0.8) : 0)
                    }
            }

            // .rr-halo: 4 pt #FF2A33, blur 3 (solid 2.4 pt under Reduce Transparency).
            Group {
                if rt {
                    NotchGlowBand(shape: outline, style: glowHex(0xFF2A33), outer: 2.4)
                } else {
                    outline.stroke(glowHex(0xFF2A33), lineWidth: 4).blur(radius: 3)
                }
            }
            .animation(rm ? fade : (on ? .easeInOut(duration: 0.4).delay(0.1) : leave)) {
                $0.opacity(on ? (rt ? 1 : (open ? 0.7 : 0.9)) : 0)
            }

            // .rr-rim: two half-outlines drawn from the bottom centre. The
            // rim follows the island; only a wide trimmed mask traces it, so
            // the trace's timing never bends the outline mid-spring.
            outline
                .stroke(rimGradient, style: NotchGlowBand<Color>.stroke(3.4))
                .mask(
                    outline
                        .trim(from: 0.5 - 0.5 * trace, to: 0.5 + 0.5 * trace)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 24, lineCap: .butt, lineJoin: .round))
                        .animation(on ? .timingCurve(0.25, 0.8, 0.25, 1, duration: 0.46) : SparkVMotion.easeOut(0.3), value: on)
                )
                .animation(rm ? fade : (on ? .linear(duration: 0.06) : SparkVMotion.easeOut(SparkVMotion.Duration.small).delay(0.12))) {
                    $0.opacity(on ? 1 : 0)
                }

            // .rr-spec: 0.8 pt white-hot core, brightest at the bottom centre.
            NotchGlowBand(shape: outline, style: specGradient, inner: 0.45, outer: 1.25)
                .animation(rm ? fade : (on ? .easeInOut(duration: 0.35).delay(0.32) : SparkVMotion.easeOut(SparkVMotion.Duration.small))) {
                    $0.opacity(on ? (open ? 0.6 : 1) : 0)
                }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .mask(NotchGlowEdgeMask(size: geo.size))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Conic Sweep

/// Hovered/open: a red -> white -> red conic gradient orbits a 2 pt border once
/// every 5.6 s (a white highlight passes every 2.8 s), over a blurred copy for
/// the halo. Open: halo 70 %. Resting: nothing exists. Reduce Motion: frozen
/// with the highlight at the bottom centre. Reduce Transparency: no halo.
struct ConicSweepNotchLayer: View {
    let context: NotchThemeContext

    /// CSS `--cs-a` at rest: puts the first white highlight at the bottom centre.
    static let restAngle: Double = 119
    static let period: Double = 5.6

    var body: some View {
        let geo = NotchGlowGeometry(context)
        ZStack {
            if context.phase != .resting {
                Group {
                    if context.reduceMotion {
                        ConicSweepGlowFrame(context: context, angle: Self.restAngle)
                    } else {
                        NotchGlowTimeline { t in
                            ConicSweepGlowFrame(
                                context: context,
                                angle: Self.restAngle + 360 * (t / Self.period).truncatingRemainder(dividingBy: 1)
                            )
                        }
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: context.reduceMotion ? 0.15 : 0.33)))
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One frame of the sweep at a CSS conic angle (degrees clockwise from 12 o'clock).
struct ConicSweepGlowFrame: View {
    let context: NotchThemeContext
    let angle: Double

    var body: some View {
        let geo = NotchGlowGeometry(context)
        let outline = NotchGlowOutline(context)
        let open = context.phase == .open
        // conic-gradient(... at 50% 42%) of the outline box padded by 14 pt.
        let boxTop = geo.island.minY - 14
        let boxHeight = geo.island.height + 28
        let center = UnitPoint(x: 0.5, y: (boxTop + 0.42 * boxHeight) / geo.size.height)
        let red = glowRed, light = glowHex(0xFF6A70), deep = glowHex(0x8F0C13)
        let sweep = AngularGradient(
            stops: [
                .init(color: red, location: 0), .init(color: light, location: 0.10),
                .init(color: glowPaper, location: 0.17), .init(color: light, location: 0.24),
                .init(color: red, location: 0.34), .init(color: deep, location: 0.42),
                .init(color: red, location: 0.50), .init(color: light, location: 0.60),
                .init(color: glowPaper, location: 0.67), .init(color: light, location: 0.74),
                .init(color: red, location: 0.84), .init(color: deep, location: 0.92),
                .init(color: red, location: 1),
            ],
            center: center,
            // CSS conic starts at 12 o'clock; SwiftUI's angle 0 is 3 o'clock.
            angle: .degrees(angle - 90)
        )

        ZStack {
            if !context.reduceTransparency {
                // .cs-glow: 8 pt ring, blur 7.
                outline
                    .stroke(sweep, style: NotchGlowBand<Color>.stroke(8))
                    .blur(radius: 7)
                    .animation(.easeInOut(duration: 0.35)) { $0.opacity(open ? 0.7 : 1) }
            }
            // .cs-thin: the crisp 2.2 pt border.
            NotchGlowBand(shape: outline, style: sweep, outer: 2.2)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .mask(NotchGlowEdgeMask(size: geo.size))
    }
}

// MARK: - Breathing Pulse

/// Hovered: a heartbeat every 2.4 s. A red ring, then a white ring 260 ms
/// later, grow 26 pt outward from the edge (scaled from the top anchor) and
/// fade, while a blurred red glow swells (lub-dub) and settles, and a 1.3 pt
/// red rim brightens with it. Open: rings stop; a slow 4.8 s breath stays and
/// the rim holds at 70 %. Resting: nothing exists. Reduce Motion: no rings,
/// one steady glow and rim. Reduce Transparency: no blurred glow.
struct BreathingPulseNotchLayer: View {
    let context: NotchThemeContext

    var body: some View {
        let geo = NotchGlowGeometry(context)
        ZStack {
            if context.phase != .resting {
                Group {
                    if context.reduceMotion {
                        BreathingPulseGlowFrame(context: context, time: 0)
                    } else {
                        // Restart the beat when the drawer opens (the CSS swaps animations).
                        NotchGlowTimeline(interval: context.phase == .open ? 1.0 / 20.0 : 1.0 / 30.0) { t in
                            BreathingPulseGlowFrame(context: context, time: t)
                        }
                        .id(context.phase)
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: context.reduceMotion ? 0.2 : 0.3)))
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One frame of the pulse, `time` seconds into the current phase.
struct BreathingPulseGlowFrame: View {
    let context: NotchThemeContext
    let time: Double

    static let period = 2.4
    static let dubDelay = 0.26
    /// How far the rings travel past the edge (26 pt closed, 34 pt open in the demo).
    static let reach: CGFloat = 26

    struct Ring { var progress: CGFloat; var alpha: Double }

    /// bpRing / bpRing2, linear: offset -> (fraction of the reach, opacity).
    static func ring(_ x: Double, peak: Double) -> Ring {
        let travel: [(Double, Double)] = [(0, 0), (0.04, 0.08), (0.25, 0.6), (0.45, 0.88), (0.64, 1), (1, 1)]
        let scale = peak / 1.0
        let alpha: [(Double, Double)] = [(0, 0), (0.04, 1 * scale), (0.25, 0.75 * scale), (0.45, 0.38 * scale), (0.64, 0), (1, 0)]
        return Ring(
            progress: CGFloat(notchGlowKeyframes(x, travel, easeInOut: false)),
            alpha: notchGlowKeyframes(x, alpha, easeInOut: false)
        )
    }

    /// (breath opacity, breath stroke width, rim opacity) at `time`.
    static func glow(time: Double, open: Bool, rm: Bool, rt: Bool) -> (Double, Double, Double) {
        if rm {
            return (open ? 0.4 : 0.6, 18, open ? 0.7 : 0.85)
        }
        if open {
            let x = (time / 4.8).truncatingRemainder(dividingBy: 1)
            return (
                notchGlowKeyframes(x, [(0, 0.25), (0.5, 0.6), (1, 0.25)], easeInOut: true),
                notchGlowKeyframes(x, [(0, 8), (0.5, 22), (1, 8)], easeInOut: true),
                0.7
            )
        }
        let x = (time / period).truncatingRemainder(dividingBy: 1)
        return (
            notchGlowKeyframes(x, [(0, 0.3), (0.05, 0.8), (0.11, 0.5), (0.17, 0.9), (0.7, 0.36), (1, 0.3)], easeInOut: true),
            notchGlowKeyframes(x, [(0, 6), (0.05, 20), (0.11, 14), (0.17, 28), (0.7, 10), (1, 6)], easeInOut: true),
            rt ? 1 : notchGlowKeyframes(x, [(0, 0.55), (0.04, 1), (0.10, 0.7), (0.15, 1), (0.6, 0.6), (1, 0.55)], easeInOut: true)
        )
    }

    var body: some View {
        let geo = NotchGlowGeometry(context)
        let outline = NotchGlowOutline(context)
        let open = context.phase == .open
        let rm = context.reduceMotion
        let rt = context.reduceTransparency

        // Glow and rim values for this frame.
        let (breathAlpha, breathWidth, rimAlpha) = Self.glow(time: time, open: open, rm: rm, rt: rt)

        // Ring scale from the top anchor: (bw + 2d) / bw sideways, (h + d) / h down.
        let bw = max(geo.island.width, 1)
        let bh = max(geo.island.height, 1)
        let ringWidth: CGFloat = rt ? 1.6 : 2
        let showRings = !rm && !open
        let lub = Self.ring((time / Self.period).truncatingRemainder(dividingBy: 1), peak: 1)
        let dubTime = time - Self.dubDelay
        let dub = dubTime >= 0 ? Self.ring((dubTime / Self.period).truncatingRemainder(dividingBy: 1), peak: 0.85) : Ring(progress: 0, alpha: 0)

        ZStack {
            if !rt {
                // .bp-breath: red stroke 6...28 pt, blur 10.
                outline
                    .stroke(glowRed, style: NotchGlowBand<Color>.stroke(breathWidth))
                    .blur(radius: 10)
                    .opacity(breathAlpha)
            }
            if showRings {
                ForEach(0..<2, id: \.self) { index in
                    let ring = index == 0 ? lub : dub
                    let d = Self.reach * ring.progress
                    NotchGlowOutline(context, scaleX: (bw + 2 * d) / bw, scaleY: (bh + d) / bh)
                        .stroke(index == 0 ? glowRed : glowPaper, style: NotchGlowBand<Color>.stroke(ringWidth))
                        .opacity(ring.alpha)
                }
            }
            // .bp-rim: 1.3 pt #FF3640 on the edge.
            NotchGlowBand(shape: outline, style: glowHex(0xFF3640), outer: 1.3)
                .opacity(rimAlpha)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .mask(NotchGlowEdgeMask(size: geo.size))
    }
}

// MARK: - Neon Tube

/// Resting: an unlit glass tube, a faint 3 pt pink line, static. Hovered: the
/// tube strikes like a sign (three flickers over 1.1 s), then glows steady red
/// with a pink-white core and spills red light onto the wallpaper around the
/// island, with a faint hum that stops after ~8 s. Open: same tube on the
/// drawer outline, outer glow at 42 %. Reduce Motion: no flicker or hum, a
/// 200 ms fade on. Reduce Transparency: no spill or blurred glows.
struct NeonTubeNotchLayer: View {
    let context: NotchThemeContext

    static let strike = 1.1
    static let humPeriod = 3.4
    /// Two hum cycles after the strike: the timeline stops at ~8 s.
    static let duration = strike + 2 * humPeriod

    var body: some View {
        let geo = NotchGlowGeometry(context)
        ZStack {
            // .nt-glass: always there, never animates.
            NotchGlowBand(shape: NotchGlowOutline(context), style: glowHex(0xFFBEBE, 0.11), outer: 3)
                .mask(NotchGlowEdgeMask(size: geo.size))

            if context.phase != .resting {
                Group {
                    if context.reduceMotion {
                        NeonTubeGlowFrame(context: context, lamp: 1)
                    } else {
                        NotchGlowTimeline(duration: Self.duration) { t in
                            NeonTubeGlowFrame(context: context, lamp: Self.lamp(at: t))
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: context.reduceMotion ? .opacity.animation(.easeOut(duration: 0.2)) : .identity,
                    removal: context.reduceMotion ? .opacity.animation(.easeOut(duration: 0.2)) : .identity
                ))
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Lamp brightness `t` seconds after the pointer arrives: ntOn, then ntHum.
    static func lamp(at t: Double) -> Double {
        if t < strike {
            return notchGlowKeyframes(t / strike, [
                (0, 0), (0.05, 0.85), (0.08, 0.08), (0.14, 0.9), (0.17, 0.05),
                (0.26, 1), (0.29, 0.4), (0.36, 1), (1, 1),
            ], easeInOut: false)
        }
        if t >= duration { return 1 }
        let x = ((t - strike) / humPeriod).truncatingRemainder(dividingBy: 1)
        return notchGlowKeyframes(x, [(0, 1), (0.46, 1), (0.47, 0.82), (0.48, 0.97), (0.49, 0.88), (0.5, 1), (1, 1)], easeInOut: false)
    }
}

/// The lit tube at a lamp brightness 0...1 (the unlit glass is drawn by the layer).
struct NeonTubeGlowFrame: View {
    let context: NotchThemeContext
    let lamp: Double

    var body: some View {
        let geo = NotchGlowGeometry(context)
        let outline = NotchGlowOutline(context)
        let open = context.phase == .open
        let rt = context.reduceTransparency
        let round = NotchGlowBand<Color>.stroke

        ZStack {
            if !rt {
                // .nt-spill: red light thrown on the wall, from the top centre.
                let reachX = geo.size.width / 2
                let reachY = geo.size.height - geo.island.minY
                RadialGradient(stops: [
                    .init(color: glowRed.opacity(0.55), location: 0),
                    .init(color: glowRed.opacity(0.45), location: 0.5),
                    .init(color: glowRed.opacity(0.18), location: 0.8),
                    .init(color: glowRed.opacity(0), location: 1),
                ], center: .center, startRadius: 0, endRadius: 50)
                .frame(width: 100, height: 100)
                .scaleEffect(x: reachX / 50, y: reachY / 50)
                .position(x: geo.size.width / 2, y: geo.island.minY)

                // .nt-g3 / g2 / g1: three glows, outermost first.
                outline.stroke(glowRed, style: round(12)).blur(radius: 14)
                    .animation(.easeInOut(duration: 0.3)) { $0.opacity(open ? 0.42 : 0.6) }
                outline.stroke(glowHex(0xFF2530), style: round(6)).blur(radius: 6).opacity(0.85)
                outline.stroke(glowHex(0xFF3B44), style: round(4)).blur(radius: 3)
            }
            // .nt-tube: the 3 pt tube, and .nt-core: a 1.1 pt pink-white core
            // running down its middle.
            NotchGlowBand(shape: outline, style: glowHex(0xFF2B35), outer: 3)
            NotchGlowBand(shape: outline, style: glowHex(0xFFE4E5), inner: 0.95, outer: 2.05)
        }
        .compositingGroup()
        .opacity(lamp)
        .frame(width: geo.size.width, height: geo.size.height)
        .mask(NotchGlowEdgeMask(size: geo.size))
    }
}
