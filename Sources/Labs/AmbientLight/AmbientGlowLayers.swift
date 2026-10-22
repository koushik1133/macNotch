import QuartzCore

// Core Animation layer trees for Ambient Light. Per display frame the
// renderer only sets a handful of layer properties (opacity, a color, a
// rotation) inside one action-free transaction; the blur, gradients and
// compositing happen in the window server on the GPU. Shadows always get an
// explicit `shadowPath`, so nothing is rendered offscreen to find the shape.

/// Rounds so tiny changes don't touch the layer (and the render server).
@inline(__always)
private func quantize(_ value: Double, _ step: Double) -> Double { (value / step).rounded() * step }

// MARK: - Notch outline glow

/// A glow that hugs a closed outline (the island): a wide blurred halo, a
/// conic gradient band for Wave that travels around the outline, and a thin
/// bright core line. Sits behind the island, so the island's black body hides
/// the inner half and the light seems to spill out from under it.
@MainActor
final class AmbientOutlineGlow {
    let root = CALayer()
    private let halo = CAShapeLayer()
    private let waveHost = CALayer()
    private let waveMask = CAShapeLayer()
    private let waveGradient = CAGradientLayer()
    private let core = CAShapeLayer()

    private var path: CGPath?
    private var outlineBounds = CGRect.zero
    // Last applied values (skip unchanged writes).
    private var applied = (opacity: -1.0, radius: -1.0, colorIndex: -1, waveOpacity: -1.0, rotation: -1.0,
                           waveIndex: -1, sparkle: -1.0, discoPalette: false)

    init() {
        root.masksToBounds = false
        for layer in [halo, core] {
            layer.fillColor = nil
            layer.lineJoin = .round
            layer.lineCap = .round
        }
        halo.lineWidth = 5
        halo.shadowOpacity = 1
        halo.shadowOffset = .zero
        core.lineWidth = 1.2
        core.opacity = 0
        waveMask.fillColor = nil
        waveMask.strokeColor = CGColor(gray: 1, alpha: 1)
        waveMask.lineWidth = 3.5
        waveMask.lineJoin = .round
        waveHost.mask = waveMask
        waveGradient.type = .conic
        waveGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        waveGradient.endPoint = CGPoint(x: 0.5, y: 0)
        waveHost.addSublayer(waveGradient)
        waveHost.opacity = 0
        root.addSublayer(halo)
        root.addSublayer(waveHost)
        root.addSublayer(core)
        disableImplicitAnimations()
    }

    /// The outline in `root`'s coordinates. `springResponse` animates the
    /// change with the island's own spring (pass nil to jump).
    func setOutline(_ newPath: CGPath, in bounds: CGRect, springResponse: Double?) {
        let old = path
        path = newPath
        outlineBounds = bounds
        let stroked = newPath.copy(strokingWithWidth: halo.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.path = newPath
        halo.shadowPath = stroked
        core.path = newPath
        waveMask.path = newPath
        waveHost.frame = root.bounds
        waveMask.frame = waveHost.bounds
        let side = hypot(bounds.width, bounds.height) + 40
        waveGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        waveGradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()

        if let old, let response = springResponse, old != newPath {
            for (layer, key) in [(halo, "path"), (core, "path"), (waveMask, "path"), (halo, "shadowPath")] {
                let spring = CASpringAnimation(perceptualDuration: response, bounce: 0.15)
                spring.keyPath = key
                spring.fromValue = key == "shadowPath"
                    ? old.copy(strokingWithWidth: halo.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 4)
                    : old
                spring.toValue = key == "shadowPath" ? stroked : newPath
                layer.add(spring, forKey: key)
            }
        }
    }

    func render(_ frame: AmbientVisualFrame, palette: AmbientLightPalette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let opacity = quantize(frame.brightness, 1.0 / 255)
        if opacity != applied.opacity {
            applied.opacity = opacity
            root.opacity = Float(opacity)
        }
        guard opacity > 0 else { return }

        let radius = quantize(5 + 15 * frame.bloom, 0.5)
        if radius != applied.radius {
            applied.radius = radius
            halo.shadowRadius = radius
        }
        let colorIndex = AmbientLightPalette.rampIndex(frame.colorPosition + frame.wavePhase * frame.spread)
        if colorIndex != applied.colorIndex || frame.usesDiscoPalette != applied.discoPalette {
            applied.colorIndex = colorIndex
            applied.discoPalette = frame.usesDiscoPalette
            let color = palette.color(index: colorIndex)
            halo.strokeColor = color
            halo.shadowColor = color
            core.strokeColor = color
        }
        let sparkle = quantize(0.35 + 0.65 * frame.sparkle, 1.0 / 64)
        if sparkle != applied.sparkle {
            applied.sparkle = sparkle
            core.opacity = Float(sparkle)
        }

        // Wave band: the full palette spread around, turning.
        let waveOpacity = frame.spread > 0.5 ? quantize((frame.spread - 0.5) * 2, 1.0 / 64) : 0
        if waveOpacity != applied.waveOpacity {
            applied.waveOpacity = waveOpacity
            waveHost.opacity = Float(waveOpacity)
            halo.opacity = Float(1 - 0.35 * waveOpacity)
        }
        if waveOpacity > 0 {
            let waveIndex = AmbientLightPalette.rampIndex(frame.colorPosition)
            if waveIndex != applied.waveIndex {
                applied.waveIndex = waveIndex
                var colors: [CGColor] = []
                colors.reserveCapacity(9)
                for k in 0...8 { colors.append(palette.color(at: frame.colorPosition + Double(k) / 8)) }
                waveGradient.colors = colors
            }
            let turns = frame.wavePhase - floor(frame.wavePhase)
            let rotation = quantize(turns * 2 * .pi, 2 * .pi / 1440)
            if rotation != applied.rotation {
                applied.rotation = rotation
                waveGradient.transform = CATransform3DMakeRotation(CGFloat(rotation), 0, 0, 1)
            }
        }
    }

    /// Forces the next render to write everything (after a palette change).
    func invalidate() {
        applied = (-1, -1, -1, -1, -1, -1, -1, false)
    }

    private func disableImplicitAnimations() {
        let none: [String: any CAAction] = [
            "opacity": NSNull(), "strokeColor": NSNull(), "shadowColor": NSNull(), "shadowRadius": NSNull(),
            "transform": NSNull(), "colors": NSNull(), "path": NSNull(), "shadowPath": NSNull(),
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "locations": NSNull(),
        ]
        for layer in [root, halo, waveHost, waveMask, waveGradient, core] { layer.actions = none }
    }
}

// MARK: - Screen edge strips

/// Four thin light strips along the edges of a screen (the "door light"
/// look): each strip is a gradient along its length (colors around the
/// perimeter, clockwise from the top-left corner) masked by a fade from the
/// edge inward.
@MainActor
final class AmbientEdgeStrips {
    let root = CALayer()
    private var strips: [(color: CAGradientLayer, mask: CAGradientLayer)] = []
    private var applied = (opacity: -1.0, colorIndex: -1, phaseIndex: -1, bloom: -1.0, discoPalette: false, spread: -1.0)

    /// Perimeter range (0...1, clockwise from top-left) each strip covers:
    /// top, right, bottom, left.
    private static let spans: [(Double, Double)] = [(0, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 1)]

    init() {
        let none: [String: any CAAction] = ["opacity": NSNull(), "colors": NSNull(), "locations": NSNull(),
                                             "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.actions = none
        for side in 0..<4 {
            let color = CAGradientLayer()
            let mask = CAGradientLayer()
            color.actions = none
            mask.actions = none
            // Along the strip's length.
            switch side {
            case 0: color.startPoint = CGPoint(x: 0, y: 0.5); color.endPoint = CGPoint(x: 1, y: 0.5)   // top: left → right
            case 1: color.startPoint = CGPoint(x: 0.5, y: 1); color.endPoint = CGPoint(x: 0.5, y: 0)   // right: top → bottom
            case 2: color.startPoint = CGPoint(x: 1, y: 0.5); color.endPoint = CGPoint(x: 0, y: 0.5)   // bottom: right → left
            default: color.startPoint = CGPoint(x: 0.5, y: 0); color.endPoint = CGPoint(x: 0.5, y: 1) // left: bottom → top
            }
            // From the edge inward (layer y points up in AppKit-hosted layers).
            switch side {
            case 0: mask.startPoint = CGPoint(x: 0.5, y: 1); mask.endPoint = CGPoint(x: 0.5, y: 0)
            case 1: mask.startPoint = CGPoint(x: 1, y: 0.5); mask.endPoint = CGPoint(x: 0, y: 0.5)
            case 2: mask.startPoint = CGPoint(x: 0.5, y: 0); mask.endPoint = CGPoint(x: 0.5, y: 1)
            default: mask.startPoint = CGPoint(x: 0, y: 0.5); mask.endPoint = CGPoint(x: 1, y: 0.5)
            }
            mask.colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.45), CGColor(gray: 1, alpha: 0)]
            mask.locations = [0, 0.35, 1]
            color.mask = mask
            root.addSublayer(color)
            strips.append((color, mask))
        }
    }

    /// `bounds`: the screen in the panel's coordinates; `topInset`: the menu
    /// bar's height (the top strip runs just below it); `thickness`: strip depth.
    func layout(bounds: CGRect, topInset: CGFloat, thickness: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        let t = thickness
        let top = bounds.height - topInset
        let frames = [
            CGRect(x: 0, y: top - t, width: bounds.width, height: t),
            CGRect(x: bounds.width - t, y: 0, width: t, height: top),
            CGRect(x: 0, y: 0, width: bounds.width, height: t),
            CGRect(x: 0, y: 0, width: t, height: top),
        ]
        for (strip, frame) in zip(strips, frames) {
            strip.color.frame = frame
            strip.mask.frame = CGRect(origin: .zero, size: frame.size)
        }
        CATransaction.commit()
        invalidate()
    }

    func render(_ frame: AmbientVisualFrame, palette: AmbientLightPalette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let opacity = quantize(frame.brightness * 0.9, 1.0 / 255)
        if opacity != applied.opacity {
            applied.opacity = opacity
            root.opacity = Float(opacity)
        }
        guard opacity > 0 else { return }

        let bloom = quantize(frame.bloom, 1.0 / 32)
        if bloom != applied.bloom {
            applied.bloom = bloom
            let middle = NSNumber(value: 0.15 + 0.45 * bloom)
            for strip in strips { strip.mask.locations = [0, middle, 1] }
        }

        let colorIndex = AmbientLightPalette.rampIndex(frame.colorPosition)
        let phaseIndex = AmbientLightPalette.rampIndex(frame.wavePhase)
        let spread = quantize(frame.spread, 1.0 / 32)
        guard colorIndex != applied.colorIndex || phaseIndex != applied.phaseIndex || spread != applied.spread
                || frame.usesDiscoPalette != applied.discoPalette else { return }
        applied.colorIndex = colorIndex
        applied.phaseIndex = phaseIndex
        applied.spread = spread
        applied.discoPalette = frame.usesDiscoPalette
        // Wave sends the colors around the screen (clockwise); the other
        // modes keep one color with a gentle spread along the perimeter.
        let base = frame.colorPosition - frame.wavePhase
        for (index, strip) in strips.enumerated() {
            let span = Self.spans[index]
            var colors: [CGColor] = []
            colors.reserveCapacity(5)
            for k in 0..<5 {
                let s = span.0 + (span.1 - span.0) * Double(k) / 4
                colors.append(palette.color(at: base + spread * s))
            }
            strip.color.colors = colors
        }
    }

    func invalidate() {
        applied = (-1, -1, -1, -1, false, -1)
    }
}
