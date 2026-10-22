import AppKit
import CoreGraphics

/// The light's colors: up to four vivid hues, plus a 256-step cyclic ramp
/// through them prebuilt as CGColors, so the renderers pick colors per frame
/// without allocating.
struct AmbientLightPalette: @unchecked Sendable {
    struct RGB: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double
    }

    let colors: [RGB]
    /// Where the colors came from, for the settings view.
    let fromArtwork: Bool
    private let ramp: [CGColor]
    private let cgColors: [CGColor]
    static let rampSize = 256

    init(colors: [RGB], fromArtwork: Bool) {
        let usable = colors.isEmpty ? [RGB(r: 1, g: 0.16, b: 0.2)] : Array(colors.prefix(4))
        self.colors = usable
        self.fromArtwork = fromArtwork
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func make(_ c: RGB) -> CGColor {
            CGColor(colorSpace: space, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), 1])!
        }
        cgColors = usable.map(make)
        var ramp: [CGColor] = []
        ramp.reserveCapacity(Self.rampSize)
        for step in 0..<Self.rampSize {
            let position = Double(step) / Double(Self.rampSize) * Double(usable.count)
            let index = Int(position) % usable.count
            let next = (index + 1) % usable.count
            // Smoothstep between neighbors: long holds, soft transitions.
            let t = position - Double(Int(position))
            let s = t * t * (3 - 2 * t)
            let a = usable[index], b = usable[next]
            ramp.append(make(RGB(r: a.r + (b.r - a.r) * s, g: a.g + (b.g - a.g) * s, b: a.b + (b.b - a.b) * s)))
        }
        self.ramp = ramp
    }

    /// Color at `position` around the cycle (wraps; 0 and 1 are the first color).
    func color(at position: Double) -> CGColor {
        let wrapped = position - floor(position)
        return ramp[min(Self.rampSize - 1, Int(wrapped * Double(Self.rampSize)))]
    }

    /// Ramp index for `position`, so callers can skip updates when unchanged.
    static func rampIndex(_ position: Double) -> Int {
        let wrapped = position - floor(position)
        return min(rampSize - 1, Int(wrapped * Double(rampSize)))
    }

    func color(index: Int) -> CGColor { ramp[((index % Self.rampSize) + Self.rampSize) % Self.rampSize] }

    /// One of the palette's own colors (cycling).
    func swatch(_ index: Int) -> CGColor { cgColors[((index % cgColors.count) + cgColors.count) % cgColors.count] }

    var count: Int { cgColors.count }

    static func brand(_ brand: AmbientBrandPalette) -> AmbientLightPalette {
        AmbientLightPalette(colors: brand.rgb.map { RGB(r: $0.0, g: $0.1, b: $0.2) }, fromArtwork: false)
    }

    /// Disco: the album (or brand) colors interleaved with hues spread around
    /// the wheel, so consecutive beats always land on clearly different colors.
    static func disco(base: AmbientLightPalette) -> AmbientLightPalette {
        var colors: [RGB] = []
        let wheel: [Double] = [0.0, 0.33, 0.66, 0.16, 0.5, 0.83]
        let baseHue = base.colors.first.map { hsb($0).h } ?? 0
        for (i, offset) in wheel.prefix(4).enumerated() {
            if i < base.colors.count, i % 2 == 0 {
                colors.append(base.colors[i])
            } else {
                colors.append(rgb(h: (baseHue + offset).truncatingRemainder(dividingBy: 1), s: 0.85, b: 1))
            }
        }
        return AmbientLightPalette(colors: colors, fromArtwork: base.fromArtwork)
    }

    // MARK: Artwork

    /// Up to four vivid colors from the album art, the first one matching
    /// the island's own glow (`ArtworkPalette.glowColor`). Nil for
    /// monochrome art (the caller uses the brand palette).
    static func fromArtwork(_ image: NSImage) -> AmbientLightPalette? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var colors = dominantColors(cgImage)
        if let tint = ArtworkPalette.glowColor(for: cgImage)?.usingColorSpace(.sRGB) {
            let primary = lightened(RGB(r: Double(tint.redComponent), g: Double(tint.greenComponent), b: Double(tint.blueComponent)))
            colors.removeAll { hueDistance(hsb($0).h, hsb(primary).h) < 0.06 }
            colors.insert(primary, at: 0)
        }
        guard !colors.isEmpty else { return nil }
        if colors.count == 1 {
            // A single hue: add close neighbors so the light still moves.
            let h = hsb(colors[0])
            colors.append(rgb(h: (h.h + 0.07).truncatingRemainder(dividingBy: 1), s: max(0.55, h.s * 0.85), b: 1))
            colors.append(rgb(h: (h.h + 0.94).truncatingRemainder(dividingBy: 1), s: min(1, h.s * 1.05), b: 1))
        }
        return AmbientLightPalette(colors: Array(colors.prefix(4)), fromArtwork: true)
    }

    /// Hue histogram of a 24×24 thumbnail, local maxima at least two buckets
    /// apart, each made bright enough to read as light.
    static func dominantColors(_ image: CGImage) -> [RGB] {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return dominantColors(rgba: pixels)
    }

    static func dominantColors(rgba pixels: [UInt8]) -> [RGB] {
        let buckets = 12
        var weights = [Double](repeating: 0, count: buckets)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: buckets)
        var total = 0.0
        var i = 0
        while i + 3 < pixels.count {
            let alpha = Double(pixels[i + 3]) / 255
            if alpha > 0.5 {
                let c = RGB(r: Double(pixels[i]) / 255 / alpha, g: Double(pixels[i + 1]) / 255 / alpha, b: Double(pixels[i + 2]) / 255 / alpha)
                let h = hsb(c)
                total += 1
                if h.s > 0.25, h.b > 0.18 {
                    let bucket = min(buckets - 1, Int(h.h * Double(buckets)))
                    let w = h.s * h.s * (0.3 + h.b)
                    weights[bucket] += w
                    sums[bucket].r += c.r * w; sums[bucket].g += c.g * w; sums[bucket].b += c.b * w
                }
            }
            i += 4
        }
        guard total > 0, let best = weights.max(), best > total * 0.02 else { return [] }
        let order = weights.indices.sorted { weights[$0] > weights[$1] }
        var picked: [Int] = []
        for bucket in order where weights[bucket] >= best * 0.12 {
            let distance = picked.map { min(abs($0 - bucket), buckets - abs($0 - bucket)) }.min() ?? buckets
            if distance >= 2 { picked.append(bucket) }
            if picked.count == 4 { break }
        }
        return picked.map { bucket in
            let w = weights[bucket]
            return lightened(RGB(r: sums[bucket].r / w, g: sums[bucket].g / w, b: sums[bucket].b / w))
        }
    }

    /// Full brightness and at least medium saturation: LEDs, not paint.
    static func lightened(_ c: RGB) -> RGB {
        let h = hsb(c)
        return rgb(h: h.h, s: min(1, max(0.6, h.s * 1.1)), b: 1)
    }

    // MARK: Color math

    static func hsb(_ c: RGB) -> (h: Double, s: Double, b: Double) {
        let maxV = max(c.r, c.g, c.b), minV = min(c.r, c.g, c.b)
        let delta = maxV - minV
        var hue = 0.0
        if delta > 1e-9 {
            if maxV == c.r { hue = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == c.g { hue = (c.b - c.r) / delta + 2 }
            else { hue = (c.r - c.g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxV > 0 ? delta / maxV : 0, maxV)
    }

    static func rgb(h: Double, s: Double, b: Double) -> RGB {
        let h6 = (h - floor(h)) * 6
        let c = b * s
        let x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (r, g, bl): (Double, Double, Double)
        switch Int(h6) {
        case 0: (r, g, bl) = (c, x, 0)
        case 1: (r, g, bl) = (x, c, 0)
        case 2: (r, g, bl) = (0, c, x)
        case 3: (r, g, bl) = (0, x, c)
        case 4: (r, g, bl) = (x, 0, c)
        default: (r, g, bl) = (c, 0, x)
        }
        return RGB(r: r + m, g: g + m, b: bl + m)
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    /// Relative luminance (WCAG), for the flash limiter.
    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}
