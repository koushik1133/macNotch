import AppKit
import CoreImage
import QuartzCore

// Focus screen effects: a glowing, breathing border around every screen when
// a session starts, switches to a break and ends, with a short "kick" (shake
// and pulse) and, on trackpads, a haptic tap.
//
// The approach follows the edge light Apple draws for Siri on macOS 15: a
// rounded-rect stroke filled with a slowly turning conic gradient, a wide
// blurred copy of it for the bloom, all in a borderless click-through window
// above every app. Everything is Core Animation, so the render server does
// the animating and SparkV's main thread stays idle while the border is up.

// MARK: - Moods

enum FocusGlowMood: String, Sendable, CaseIterable {
    /// SparkV Red: signal red, from ember to a warm white-hot highlight.
    /// Apple: indigo and violet.
    case focus
    /// Warm green and amber, for breaks.
    case relax
    /// Red, white and amber, for the end of a session.
    case celebrate

    /// Conic-gradient stops; the first and last match so the seam is invisible.
    var colors: [CGColor] {
        let apple = SparkVTheme.isApple
        let rgb: [(CGFloat, CGFloat, CGFloat)] = switch self {
        // Apple: indigo to violet with a cool white highlight (the macOS
        // Focus color).
        case .focus where apple: [
            (0.37, 0.36, 0.90), (0.55, 0.36, 0.96), (0.35, 0.60, 1.00),
            (0.80, 0.78, 1.00), (0.45, 0.30, 0.86), (0.37, 0.36, 0.90),
        ]
        case .celebrate where apple: [
            (0.37, 0.36, 0.90), (1.00, 0.72, 0.26), (0.97, 0.97, 0.98),
            (0.35, 0.60, 1.00), (0.30, 0.82, 0.50), (0.37, 0.36, 0.90),
        ]
        case .focus: [
            (0.94, 0.09, 0.13), (0.84, 0.07, 0.11), (1.00, 0.36, 0.32),
            (0.97, 0.62, 0.58), (0.72, 0.05, 0.10), (0.94, 0.09, 0.13),
        ]
        case .relax: [
            (0.30, 0.86, 0.52), (0.62, 0.90, 0.32), (1.00, 0.72, 0.26),
            (1.00, 0.56, 0.30), (0.40, 0.88, 0.62), (0.30, 0.86, 0.52),
        ]
        case .celebrate: [
            (0.94, 0.09, 0.13), (1.00, 0.70, 0.25), (0.97, 0.97, 0.96),
            (1.00, 0.36, 0.32), (0.30, 0.80, 0.50), (0.94, 0.09, 0.13),
        ]
        }
        return rgb.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .relax: "Break"
        case .celebrate: "End"
        }
    }
}

/// What a burst does, decided by the controller from the settings.
struct FocusGlowOptions: Equatable, Sendable {
    var shake = true
    var haptics = true
    var confetti = false
    var reduceMotion = false
}

/// Timings and shapes, kept pure so the harness can check them.
enum FocusGlowTiming {
    /// Fade in.
    static let rise: CFTimeInterval = 0.28
    /// The kick: shake plus pulse.
    static let kick: CFTimeInterval = 0.6
    /// Envelope level while the border stays up during a phase.
    static let restOpacity: Float = 0.45
    /// Reduce Motion: a plain fade in, hold, fade out.
    static let reducedDuration: CFTimeInterval = 1.8

    static func burstDuration(_ mood: FocusGlowMood, reduceMotion: Bool) -> CFTimeInterval {
        if reduceMotion { return reducedDuration }
        return mood == .celebrate ? 4.2 : 3.0
    }

    /// Horizontal offsets of the kick (points); a decaying wobble.
    static let shakeX: [CGFloat] = [0, -10, 9, -7.5, 6, -4.5, 3, -1.5, 0]
    static let shakeY: [CGFloat] = [0, 2, -2, 1.5, -1.2, 0.8, -0.5, 0.2, 0]
    /// The border squeezes in and springs back while it shakes.
    static let shakeScale: [CGFloat] = [1, 0.988, 1.006, 0.994, 1.003, 0.998, 1.001, 1, 1]

    /// Outer screen corners of the built-in display (points).
    static let cornerRadius: CGFloat = 11
}

// MARK: - Layer

/// The whole effect for one screen, as a plain CALayer tree (so the harness
/// can render it offscreen with CARenderer at any moment of the animation).
@MainActor
final class FocusEdgeGlowLayer {
    /// The tree's root; hosted by the panel's content view.
    let root = CALayer()
    private let envelope = CALayer()
    private let shaker = CALayer()
    private let breath = CALayer()
    private let halo = FocusGlowStrand(lineWidth: 14, blur: 16, maskScale: 0.25)
    private let core = FocusGlowStrand(lineWidth: 6, blur: 1, maskScale: 1)
    private let wash = FocusGlowStrand(lineWidth: 60, blur: 70, maskScale: 0.125)
    private let confetti = CAEmitterLayer()
    private(set) var mood: FocusGlowMood = .focus

    init() {
        envelope.opacity = 0
        wash.layer.opacity = 0
        halo.layer.opacity = 0.95
        root.addSublayer(envelope)
        envelope.addSublayer(shaker)
        shaker.addSublayer(breath)
        breath.addSublayer(halo.layer)
        breath.addSublayer(core.layer)
        shaker.addSublayer(wash.layer)
        envelope.addSublayer(confetti)
        confetti.birthRate = 0
        confetti.renderMode = .unordered
        setColors(mood.colors, animated: false)
    }

    /// Lays the tree out for a screen of `size` points at `scale`.
    func configure(size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: size)
        root.bounds = bounds
        root.contentsScale = scale
        for layer in [envelope, shaker, breath] {
            layer.frame = bounds
        }
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: FocusGlowTiming.cornerRadius, cornerHeight: FocusGlowTiming.cornerRadius,
            transform: nil
        )
        for strand in [halo, core, wash] {
            strand.layer.frame = bounds
            strand.configure(path: path, size: size, scale: scale)
        }
        confetti.frame = bounds
        confetti.emitterShape = .line
        confetti.emitterPosition = CGPoint(x: size.width / 2, y: size.height + 12)
        confetti.emitterSize = CGSize(width: size.width, height: 1)
        confetti.emitterCells = Self.confettiCells()
        CATransaction.commit()
    }

    var envelopeOpacity: Float { envelope.opacity }

    /// Fades in, kicks, holds and settles to `rest` (0 hides). Returns how
    /// long the burst lasts.
    @discardableResult
    func burst(_ mood: FocusGlowMood, rest: Float, options: FocusGlowOptions) -> CFTimeInterval {
        let reduce = options.reduceMotion
        let duration = FocusGlowTiming.burstDuration(mood, reduceMotion: reduce)
        let now = CACurrentMediaTime()
        let from = envelope.presentation()?.opacity ?? envelope.opacity
        setColors(mood.colors, animated: from > 0.05 && self.mood != mood)
        self.mood = mood

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Envelope: up, hold, down to the resting level.
        let env = CAKeyframeAnimation(keyPath: "opacity")
        env.values = [from, 1, 1, rest]
        env.keyTimes = [0, NSNumber(value: FocusGlowTiming.rise / duration), 0.62, 1]
        env.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        env.duration = duration
        envelope.opacity = rest
        envelope.add(env, forKey: "burst")

        shaker.removeAnimation(forKey: "kick")
        wash.layer.removeAnimation(forKey: "flash")
        if reduce {
            stopMotion()
        } else {
            startMotion(fast: true)
            // The flash of colour washing in from the edges.
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, mood == .celebrate ? 0.75 : 0.55, 0]
            flash.keyTimes = [0, 0.2, 1]
            flash.duration = mood == .celebrate ? 1.5 : 1.1
            // Decays like light: fast, then slow (never ease-in).
            flash.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
            wash.layer.add(flash, forKey: "flash")

            if options.shake {
                let kick = CAKeyframeAnimation(keyPath: "transform")
                kick.values = zip(FocusGlowTiming.shakeX, zip(FocusGlowTiming.shakeY, FocusGlowTiming.shakeScale)).map { x, ys in
                    NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(x, ys.0, 0), ys.1, ys.1, 1))
                }
                kick.duration = FocusGlowTiming.kick
                kick.beginTime = now + 0.05
                kick.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shaker.add(kick, forKey: "kick")
            }
            if options.confetti {
                confetti.beginTime = now
                confetti.birthRate = 0
                let rain = CAKeyframeAnimation(keyPath: "birthRate")
                rain.values = [1, 1, 0]
                rain.keyTimes = [0, 0.99, 1]
                rain.duration = 0.9
                confetti.add(rain, forKey: "rain")
            }
        }
        CATransaction.commit()
        return duration
    }

    /// Holds the border at `rest` (0 hides) without a kick, e.g. on relaunch,
    /// pause or a settings change.
    func settle(_ mood: FocusGlowMood, rest: Float, reduceMotion: Bool, duration: CFTimeInterval = 0.7) {
        let from = envelope.presentation()?.opacity ?? envelope.opacity
        setColors(mood.colors, animated: from > 0.05 && self.mood != mood)
        self.mood = mood
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = rest
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        envelope.opacity = rest
        envelope.add(fade, forKey: "burst")
        if rest > 0, !reduceMotion { startMotion(fast: false) } else if reduceMotion { stopMotion() }
        CATransaction.commit()
    }

    /// The slow "always on" motion after a burst: calmer breathing and
    /// rotation at a low frame rate, so a 25 minute session costs little.
    func calmDown(reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reduceMotion { stopMotion() } else { startMotion(fast: false) }
        CATransaction.commit()
    }

    func stopAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        envelope.removeAllAnimations()
        envelope.opacity = 0
        shaker.removeAllAnimations()
        wash.layer.removeAllAnimations()
        confetti.removeAllAnimations()
        confetti.birthRate = 0
        stopMotion()
        CATransaction.commit()
    }

    // MARK: Pieces

    private func startMotion(fast: Bool) {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = fast ? 0.7 : 0.55
        breathe.duration = fast ? 1.1 : 3.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if !fast { Self.lowFrameRate(breathe) }
        breath.add(breathe, forKey: "breathe")
        for strand in [halo, core, wash] {
            strand.spin(period: fast ? 7 : 40, lowFrameRate: !fast)
        }
    }

    private func stopMotion() {
        breath.removeAnimation(forKey: "breathe")
        for strand in [halo, core, wash] { strand.spin(period: nil, lowFrameRate: false) }
    }

    private func setColors(_ colors: [CGColor], animated: Bool) {
        for strand in [halo, core, wash] { strand.setColors(colors, animated: animated) }
    }

    private static func lowFrameRate(_ animation: CAAnimation) {
        if #available(macOS 12.0, *) {
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
        }
    }

    private static func confettiCells() -> [CAEmitterCell] {
        let colors = FocusGlowMood.celebrate.colors.dropLast() + [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]
        return colors.enumerated().map { index, color in
            let cell = CAEmitterCell()
            cell.contents = confettiPiece(color: color, round: index % 3 == 2)
            cell.birthRate = 40
            cell.lifetime = 4.5
            cell.velocity = 210
            cell.velocityRange = 120
            cell.yAcceleration = -260
            cell.xAcceleration = index.isMultiple(of: 2) ? 12 : -12
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 4
            cell.spin = 3
            cell.spinRange = 8
            cell.scale = 0.55
            cell.scaleRange = 0.3
            cell.alphaSpeed = -0.18
            return cell
        }
    }

    private static func confettiPiece(color: CGColor, round: Bool) -> CGImage? {
        let w = round ? 14 : 20, h = round ? 14 : 10
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(color)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if round { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        return ctx.makeImage()
    }
}

/// One stroke of the border: a conic gradient seen through a (blurred) mask
/// of the screen outline. The sharp line uses a vector shape mask; the soft
/// ones a small blurred bitmap, built once per screen size and reused.
@MainActor
final class FocusGlowStrand {
    let layer = CALayer()
    private let gradient = CAGradientLayer()
    private let maskLayer = CALayer()
    private let shapeMask = CAShapeLayer()
    private let lineWidth: CGFloat
    private let blur: CGFloat
    private let maskScale: CGFloat

    init(lineWidth: CGFloat, blur: CGFloat, maskScale: CGFloat) {
        self.lineWidth = lineWidth
        self.blur = blur
        self.maskScale = maskScale
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer.addSublayer(gradient)
        if usesShapeMask {
            shapeMask.fillColor = nil
            shapeMask.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            shapeMask.lineWidth = lineWidth
            layer.mask = shapeMask
        } else {
            layer.mask = maskLayer
        }
    }

    /// A line this sharp needs no blur: a full-resolution bitmap of it would
    /// cost ~30 MB per screen and ~50 ms to draw, a shape layer next to nothing.
    private var usesShapeMask: Bool { blur <= 1 }

    func configure(path: CGPath, size: CGSize, scale: CGFloat) {
        // A square as wide as the diagonal, so turning it never shows a corner.
        let side = ceil(hypot(size.width, size.height))
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: size.width / 2, y: size.height / 2)
        if usesShapeMask {
            shapeMask.frame = CGRect(origin: .zero, size: size)
            shapeMask.contentsScale = scale
            shapeMask.path = path
            return
        }
        maskLayer.frame = CGRect(origin: .zero, size: size)
        maskLayer.contents = Self.cachedMaskImage(path: path, size: size, lineWidth: lineWidth, blur: blur,
                                                  pixelsPerPoint: scale * maskScale)
        maskLayer.contentsGravity = .resize
        maskLayer.minificationFilter = .linear
        maskLayer.magnificationFilter = .linear
    }

    func setColors(_ colors: [CGColor], animated: Bool) {
        if animated {
            let fade = CABasicAnimation(keyPath: "colors")
            fade.fromValue = gradient.presentation()?.colors ?? gradient.colors
            fade.toValue = colors
            fade.duration = 0.6
            gradient.add(fade, forKey: "colors")
        }
        gradient.colors = colors
    }

    /// Turns the gradient once per `period` seconds; nil stops it where it is.
    func spin(period: CFTimeInterval?, lowFrameRate: Bool) {
        let current = (gradient.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        gradient.removeAnimation(forKey: "spin")
        guard let period else {
            gradient.setValue(current, forKeyPath: "transform.rotation.z")
            return
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = current
        spin.toValue = current - 2 * .pi
        spin.duration = period
        spin.repeatCount = .infinity
        if lowFrameRate, #available(macOS 12.0, *) {
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
        }
        gradient.add(spin, forKey: "spin")
    }

    /// Blurred masks by screen size and strand: the panels are rebuilt on
    /// every burst, and blurring costs tens of milliseconds on the main thread.
    private static var maskCache: [String: CGImage] = [:]
    /// One Core Image context for every mask (creating one is expensive).
    private static let ciContext: CIContext = {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let space = CGColorSpace(name: CGColorSpace.sRGB) { options[.workingColorSpace] = space }
        return CIContext(options: options)
    }()

    static func cachedMaskImage(path: CGPath, size: CGSize, lineWidth: CGFloat, blur: CGFloat, pixelsPerPoint: CGFloat) -> CGImage? {
        let key = "\(size.width)x\(size.height)@\(pixelsPerPoint)/\(lineWidth)/\(blur)"
        if let hit = maskCache[key] { return hit }
        guard let image = maskImage(path: path, size: size, lineWidth: lineWidth, blur: blur, pixelsPerPoint: pixelsPerPoint) else { return nil }
        // A few screens' worth (two strands each); a new set of screens starts over.
        if maskCache.count >= 8 { maskCache.removeAll() }
        maskCache[key] = image
        return image
    }

    static var cachedMaskCount: Int { maskCache.count }

    /// The outline drawn once into a small bitmap and blurred with Core
    /// Image, then stretched by Core Animation: soft strands are rendered at a
    /// fraction of the screen resolution, so the masks cost a few MB.
    static func maskImage(path: CGPath, size: CGSize, lineWidth: CGFloat, blur: CGFloat, pixelsPerPoint: CGFloat) -> CGImage? {
        let w = max(1, Int((size.width * pixelsPerPoint).rounded())), h = max(1, Int((size.height * pixelsPerPoint).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path)
        ctx.strokePath()
        guard let sharp = ctx.makeImage() else { return nil }
        guard blur > 0 else { return sharp }
        // Clamped first, so the screen edge reads as light continuing past it.
        let input = CIImage(cgImage: sharp)
        let radius = blur * pixelsPerPoint
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent) ?? sharp
    }
}

// MARK: - Window

/// Borderless, click-through, non-activating panel covering one screen.
@MainActor
final class FocusEdgeGlowPanel: NSPanel {
    let glow = FocusEdgeGlowLayer()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // isFloatingPanel resets `level`, so it comes first.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        // A personal cue: keep it out of screenshots, recordings and screen shares.
        sharingType = .none
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = glow.root
        view.wantsLayer = true
        contentView = view
        fit(to: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func fit(to screen: NSScreen) {
        setFrame(screen.frame, display: false)
        glow.configure(size: screen.frame.size, scale: screen.backingScaleFactor)
    }

    /// In front of everything except SparkV's own island, so the island
    /// stays crisp and the light seems to come from behind it.
    func present() {
        if let notch = NSApp.windows.first(where: { $0 is NotchPanel && $0.isVisible }), notch.screen == screen {
            order(.below, relativeTo: notch.windowNumber)
        } else {
            orderFrontRegardless()
        }
    }
}

// MARK: - Controller

/// Shows the border on every screen. One instance, owned by FocusController.
@MainActor
final class FocusEdgeGlowController {
    /// The mood held at rest between bursts (nil: hidden between bursts).
    private(set) var resting: FocusGlowMood?
    private(set) var lastBurst: FocusGlowMood?
    private var panels: [CGDirectDisplayID: FocusEdgeGlowPanel] = [:]
    private var generation = 0
    private var settleTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    /// The border is up (or fading) on the screens.
    private(set) var isVisible = false
    /// Off in the harness: panels are built and animated but never ordered in.
    var ordersWindows = true
    /// Screens the border was last laid out for.
    var panelCount: Int { panels.count }

    static var systemReduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Fades in, kicks and settles to `rest` (or hides).
    func burst(_ mood: FocusGlowMood, rest: FocusGlowMood?, options: FocusGlowOptions) {
        generation &+= 1
        let token = generation
        resting = rest
        lastBurst = mood
        settleTask?.cancel()
        var longest: CFTimeInterval = 0
        isVisible = true
        for panel in ensurePanels() {
            if ordersWindows { panel.present() }
            let d = panel.glow.burst(mood, rest: rest == nil ? 0 : FocusGlowTiming.restOpacity,
                                     options: options)
            longest = max(longest, d)
        }
        if options.haptics && options.shake && !options.reduceMotion && ordersWindows { Self.hapticKick() }
        let reduce = options.reduceMotion
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(longest + 0.1))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            if self.resting == nil {
                self.orderOutAll()
            } else {
                // Same mood colours; just calmer motion.
                self.panels.values.forEach { $0.glow.calmDown(reduceMotion: reduce) }
            }
        }
    }

    /// Holds the border at rest in `mood`, or fades it out (nil), without a kick.
    func rest(_ mood: FocusGlowMood?, reduceMotion: Bool) {
        guard mood != resting || (mood != nil && !isVisible) else { return }
        generation &+= 1
        let token = generation
        resting = mood
        settleTask?.cancel()
        if let mood {
            isVisible = true
            for panel in ensurePanels() {
                if ordersWindows { panel.present() }
                panel.glow.settle(mood, rest: FocusGlowTiming.restOpacity, reduceMotion: reduceMotion)
            }
        } else {
            guard isVisible else { return }
            panels.values.forEach { $0.glow.settle($0.glow.mood, rest: 0, reduceMotion: reduceMotion, duration: 0.6) }
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.7))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.orderOutAll()
            }
        }
    }

    /// Teardown: gone at once.
    func hideNow() {
        generation &+= 1
        settleTask?.cancel()
        resting = nil
        orderOutAll()
    }

    // MARK: Internals

    private func ensurePanels() -> [FocusEdgeGlowPanel] {
        var live: [CGDirectDisplayID: FocusEdgeGlowPanel] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.focusDisplayID else { continue }
            if let existing = panels[id] {
                if existing.frame != screen.frame { existing.fit(to: screen) }
                live[id] = existing
            } else {
                live[id] = FocusEdgeGlowPanel(screen: screen)
            }
        }
        for (id, panel) in panels where live[id] == nil {
            panel.glow.stopAll()
            panel.orderOut(nil)
        }
        panels = live
        return Array(live.values)
    }

    private func orderOutAll() {
        isVisible = false
        for panel in panels.values {
            panel.glow.stopAll()
            panel.orderOut(nil)
        }
        // Rebuilt on the next burst (screens may change meanwhile).
        panels.removeAll()
    }

    private func screensChanged() {
        guard isVisible else { return }
        if let resting {
            let reduce = Self.systemReduceMotion
            for panel in ensurePanels() {
                if ordersWindows { panel.present() }
                panel.glow.settle(resting, rest: FocusGlowTiming.restOpacity, reduceMotion: reduce, duration: 0.3)
            }
        } else {
            orderOutAll()
        }
    }

    /// Three quick taps: felt only while a finger rests on a Force Touch trackpad.
    private static func hapticKick() {
        // Gentle (the default): one light tap instead of three.
        SparkVHaptics.performSequence([.levelChange, .generic, .generic], gaps: [0.12, 0.14])
    }
}

extension NSScreen {
    var focusDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
