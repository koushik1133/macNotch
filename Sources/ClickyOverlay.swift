import AppKit
import SwiftUI

// MARK: - Geometry

/// Conversions between the three coordinate spaces Clicky uses:
/// - screenshot pixels: origin top-left of the captured display, y down,
///   in the (downscaled) image's pixel size;
/// - global screen points: AppKit's space, origin bottom-left of the main
///   display, y up (`NSEvent.mouseLocation`, `NSScreen.frame`);
/// - overlay-local points: SwiftUI inside the full-screen overlay panel,
///   origin top-left of that display, y down.
enum ClickyGeometry {
    static func screenPoint(fromPixel pixel: CGPoint, imageSize: CGSize, screenFrame: CGRect) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGPoint(x: screenFrame.midX, y: screenFrame.midY) }
        let sx = screenFrame.width / imageSize.width
        let sy = screenFrame.height / imageSize.height
        return CGPoint(
            x: screenFrame.minX + pixel.x * sx,
            y: screenFrame.maxY - pixel.y * sy
        )
    }

    static func pixel(fromScreenPoint point: CGPoint, imageSize: CGSize, screenFrame: CGRect) -> CGPoint {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let sx = imageSize.width / screenFrame.width
        let sy = imageSize.height / screenFrame.height
        return CGPoint(
            x: (point.x - screenFrame.minX) * sx,
            y: (screenFrame.maxY - point.y) * sy
        )
    }

    static func local(fromScreenPoint point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }

    /// Pixel size of an image downscaled so its long edge is at most `maxLongEdge`.
    static func fittedPixelSize(_ size: CGSize, maxLongEdge: CGFloat) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge, longEdge > 0 else {
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
        let scale = maxLongEdge / longEdge
        return CGSize(
            width: max(1, (size.width * scale).rounded(.down)),
            height: max(1, (size.height * scale).rounded(.down))
        )
    }
}

// MARK: - Overlay window

/// Full-screen, click-through, non-activating panel that flies a pointer from
/// the mouse to the element Clicky is talking about and labels it.
/// Dismisses itself after a few seconds, on Esc, or on any mouse click.
@MainActor
final class ClickyOverlay {
    static let displayDuration: TimeInterval = 6

    private var panel: NSPanel?
    private let model = ClickyPointerModel()
    private var dismissTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var generation = 0

    var isVisible: Bool { panel?.isVisible == true }

    /// `start` and `target` are global screen points; `screenFrame` is the
    /// frame of the display they are on.
    func show(from start: CGPoint, to target: CGPoint, label: String, screenFrame: CGRect) {
        generation += 1
        let current = generation
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screenFrame, display: false)
        panel.alphaValue = 1

        var startLocal = ClickyGeometry.local(fromScreenPoint: start, screenFrame: screenFrame)
        let targetLocal = ClickyGeometry.local(fromScreenPoint: target, screenFrame: screenFrame)
        // Mouse on another display: launch from the nearest edge instead.
        if !screenFrame.contains(start) {
            startLocal = CGPoint(x: screenFrame.width / 2, y: 0)
        }
        model.reset(start: startLocal, target: targetLocal, label: label, size: screenFrame.size)
        panel.orderFrontRegardless()

        if SparkVMotion.reduceMotion {
            // Reduce Motion: no flight or ripple; the pointer and its label
            // fade in at the target.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.progress = 1 }
            withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut())) { model.arrived = true }
        } else {
            // Let the first frame render at the start position, then fly.
            // Moving across the screen: strong ease-in-out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    withAnimation(SparkVMotion.easeInOut(ClickyPointerModel.flightDuration)) {
                        self.model.progress = 1
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 + ClickyPointerModel.flightDuration * 0.85) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    // The label pops in like a tooltip: ease-out, 180 ms.
                    withAnimation(SparkVMotion.easeOut(SparkVMotion.Duration.small)) { self.model.arrived = true }
                    // Constant ripple: ease-out reads as a wave spreading.
                    if !SparkVMotion.reduceMotion, !SparkVEnergy.shared.pausesDecoration {
                        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { self.model.pulse = true }
                    }
                }
            }
        }

        installMonitors()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.dismiss()
        }
        AppLog.log("Clicky: pointing at \(label)")
    }

    func dismiss(animated: Bool = true) {
        dismissTask?.cancel()
        dismissTask = nil
        removeMonitors()
        guard let panel, panel.isVisible else { return }
        generation += 1
        let current = generation
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = SparkVMotion.Duration.small
            context.timingFunction = LiveBandMotion.easeOutTiming
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the notch panel (.statusBar) so the pointer can reach the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        let host = NSHostingView(rootView: ClickyPointerView(model: model).followsAppearance())
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse.union(.keyDown), handler: { [weak self] event in
            let isEscapeOrMouse = event.type != .keyDown || event.keyCode == 53
            MainActor.assumeIsolated {
                if isEscapeOrMouse { self?.dismiss() }
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse.union(.keyDown), handler: { [weak self] event in
            let isEscapeOrMouse = event.type != .keyDown || event.keyCode == 53
            MainActor.assumeIsolated {
                if isEscapeOrMouse { self?.dismiss() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}

// MARK: - Pointer view

@MainActor
final class ClickyPointerModel: ObservableObject {
    /// Explanatory motion (rare, across the screen), so longer than UI motion.
    static let flightDuration: TimeInterval = 0.7

    @Published var start: CGPoint = .zero
    @Published var target: CGPoint = .zero
    @Published var label = ""
    @Published var size: CGSize = .zero
    @Published var progress: CGFloat = 0
    @Published var arrived = false
    @Published var pulse = false

    func reset(start: CGPoint, target: CGPoint, label: String, size: CGSize) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.start = start
            self.target = target
            self.label = label
            self.size = size
            self.progress = 0
            self.arrived = false
            self.pulse = false
        }
    }
}

private struct ClickyPointerView: View {
    @ObservedObject var model: ClickyPointerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if model.arrived {
                TargetPulse(pulse: model.pulse)
                    .position(model.target)
                    .transition(.opacity)

                LabelBubble(text: model.label)
                    .fixedSize()
                    .modifier(BubblePlacement(target: model.target, area: model.size))
                    .transition(.sparkVEnter)
            }

            FlyingPointer(progress: model.progress, start: model.start, target: model.target)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Moves the pointer along an arc from `start` to `target`. Animating
/// `progress` animates the whole path (position, heading and trail).
private struct FlyingPointer: View, Animatable {
    var progress: CGFloat
    let start: CGPoint
    let target: CGPoint

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = min(max(progress, 0), 1)
        let tip = Self.point(at: t, start: start, target: target)
        ZStack(alignment: .topLeading) {
            // Fading trail behind the pointer while it flies.
            ForEach(1..<6, id: \.self) { i in
                let lag = t - CGFloat(i) * 0.045
                if lag > 0, t < 1 {
                    let p = Self.point(at: lag, start: start, target: target)
                    Circle()
                        .fill(ClickyPalette.tint.opacity(0.35 - Double(i) * 0.05))
                        .frame(width: 9 - CGFloat(i), height: 9 - CGFloat(i))
                        .position(p)
                }
            }

            PointerGlyph()
                .rotationEffect(.radians(Self.heading(at: t, start: start, target: target)), anchor: .topLeading)
                .offset(x: tip.x, y: tip.y)
        }
    }

    /// Quadratic Bézier with the control point lifted to one side of the
    /// straight line, so the flight curves instead of sliding.
    static func point(at t: CGFloat, start: CGPoint, target: CGPoint) -> CGPoint {
        let c = control(start: start, target: target)
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * c.x + t * t * target.x,
            y: u * u * start.y + 2 * u * t * c.y + t * t * target.y
        )
    }

    static func control(start: CGPoint, target: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (start.x + target.x) / 2, y: (start.y + target.y) / 2)
        let dx = target.x - start.x, dy = target.y - start.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        let lift = min(160, length * 0.3)
        // Perpendicular, biased upward on screen.
        var nx = -dy / length, ny = dx / length
        if ny > 0 { nx = -nx; ny = -ny }
        return CGPoint(x: mid.x + nx * lift, y: mid.y + ny * lift)
    }

    /// Rotation of the glyph: nose-first along the path while flying, easing
    /// back to the classic resting pose on arrival.
    static func heading(at t: CGFloat, start: CGPoint, target: CGPoint) -> Double {
        let c = control(start: start, target: target)
        let u = 1 - t
        let tx = 2 * u * (c.x - start.x) + 2 * t * (target.x - c.x)
        let ty = 2 * u * (c.y - start.y) + 2 * t * (target.y - c.y)
        guard abs(tx) + abs(ty) > 0.001 else { return 0 }
        // The resting glyph's nose points up and slightly left.
        let rest = atan2(-1.0, -0.4)
        var angle = atan2(Double(ty), Double(tx)) - rest
        while angle > .pi { angle -= 2 * .pi }
        while angle < -.pi { angle += 2 * .pi }
        let settle = smoothstep(0.65, 1, Double(t))
        return angle * (1 - settle)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// An original arrow pointer (tip at the frame's top-left corner) with a
/// soft red glow (SparkV brand).
private struct PointerGlyph: View {
    var body: some View {
        ArrowShape()
            .fill(
                LinearGradient(
                    colors: SparkVTheme.isApple
                        ? [Color(red: 0.45, green: 0.95, blue: 1.0), Color(red: 0.15, green: 0.45, blue: 1.0)]
                        : [Color(red: 1.0, green: 0.36, blue: 0.40), SparkVTheme.redDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(ArrowShape().stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)))
            .frame(width: 22, height: 30, alignment: .topLeading)
            .shadow(color: ClickyPalette.tint.opacity(0.85), radius: 10)
            .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Unit design on a 13 x 20 grid, tip at (0, 0).
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: 17),
            CGPoint(x: 4.3, y: 13.2),
            CGPoint(x: 7.2, y: 19.6),
            CGPoint(x: 9.9, y: 18.4),
            CGPoint(x: 7.1, y: 12.2),
            CGPoint(x: 12.8, y: 12.2),
        ]
        let sx = rect.width / 13, sy = rect.height / 20
        let scale = min(sx, sy)
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) })
        path.closeSubpath()
        return path
    }
}

private struct TargetPulse: View {
    let pulse: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(ClickyPalette.tint.opacity(pulse ? 0 : 0.9), lineWidth: 2.5)
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 2.6 : 0.8)
            Circle()
                .fill(ClickyPalette.tint.opacity(0.18))
                .frame(width: 30, height: 30)
        }
        .frame(width: 80, height: 80)
    }
}

private struct LabelBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ClickyPalette.tint)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: SparkVTheme.isApple ? .rounded : .default))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(SparkVTheme.isApple ? Color.black.opacity(0.82) : SparkVTheme.background.opacity(0.92))
                .overlay(Capsule(style: .continuous).strokeBorder(ClickyPalette.tint.opacity(0.6), lineWidth: 1))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
    }
}

/// Places the bubble below-right of the pointer, flipping toward the inside
/// near the right or bottom edge of the screen.
private struct BubblePlacement: ViewModifier {
    let target: CGPoint
    let area: CGSize

    func body(content: Content) -> some View {
        let nearRight = target.x > area.width - 220
        let nearBottom = target.y > area.height - 80
        content
            .alignmentGuide(.leading) { d in nearRight ? d.width + 12 : -28 }
            .alignmentGuide(.top) { d in nearBottom ? d.height + 14 : -34 }
            .offset(x: target.x, y: target.y)
    }
}

/// Clicky's pointer color: the original cyan in Apple, brand red in SparkV Red.
private enum ClickyPalette {
    static var tint: Color { SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red) }
}
