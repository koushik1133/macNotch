import Foundation

/// A picked or typed color, stored as **extended sRGB** (gamma-encoded,
/// D65). Components may sit outside 0…1 when the color is outside the sRGB
/// gamut (a Display P3 pixel, say), so nothing is lost; every sRGB output
/// (hex, rgb(), hsl(), WCAG) clamps first. Pure value type: no AppKit, so
/// the math is testable on its own.
struct CPColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 0xRRGGBB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// 8-bit sRGB channels.
    init(r8: Int, g8: Int, b8: Int) {
        self.init(red: Double(r8) / 255, green: Double(g8) / 255, blue: Double(b8) / 255)
    }

    static let white = CPColor(red: 1, green: 1, blue: 1)
    static let black = CPColor(red: 0, green: 0, blue: 0)

    // MARK: sRGB (clamped)

    /// Components clamped to 0…1 (what an sRGB-only output can show).
    var clamped: CPColor {
        CPColor(red: CPMath.clamp01(red), green: CPMath.clamp01(green), blue: CPMath.clamp01(blue), alpha: CPMath.clamp01(alpha))
    }

    /// 8-bit channels: clamp **before** rounding (an out-of-range channel
    /// must not overflow), and round rather than truncate.
    var rgb8: (r: Int, g: Int, b: Int) {
        (CPMath.to8(red), CPMath.to8(green), CPMath.to8(blue))
    }

    /// 0xRRGGBB of the clamped color.
    var hexValue: UInt32 {
        let c = rgb8
        return UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
    }

    /// "#3B82F6".
    var hexString: String { String(format: "#%06X", hexValue) }

    /// The same color quantized to 8-bit sRGB (what a hex round-trip gives).
    var quantized: CPColor { CPColor(hex: hexValue) }

    /// True when every channel is within sRGB (half an 8-bit step of slack,
    /// so a value that rounds into range counts as in gamut).
    var isInSRGBGamut: Bool {
        let slack = 0.5 / 255
        return [red, green, blue].allSatisfy { $0 >= -slack && $0 <= 1 + slack }
    }

    /// Any channel above 1.0 (EDR / HDR white).
    var exceedsSDR: Bool { max(red, green, blue) > 1 + 0.5 / 255 }

    // MARK: Linear light

    /// Linear-light extended sRGB (sign-preserving transfer function).
    var linearSRGB: (r: Double, g: Double, b: Double) {
        (CPMath.srgbToLinear(red), CPMath.srgbToLinear(green), CPMath.srgbToLinear(blue))
    }

    static func fromLinearSRGB(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> CPColor {
        CPColor(red: CPMath.linearToSRGB(r), green: CPMath.linearToSRGB(g), blue: CPMath.linearToSRGB(b), alpha: alpha)
    }

    // MARK: Display P3

    /// Gamma-encoded Display P3 components (same transfer curve as sRGB).
    var displayP3: (r: Double, g: Double, b: Double) {
        let l = linearSRGB
        let m = CPMath.srgbToP3
        let pr = m[0] * l.r + m[1] * l.g + m[2] * l.b
        let pg = m[3] * l.r + m[4] * l.g + m[5] * l.b
        let pb = m[6] * l.r + m[7] * l.g + m[8] * l.b
        return (CPMath.linearToSRGB(pr), CPMath.linearToSRGB(pg), CPMath.linearToSRGB(pb))
    }

    static func fromDisplayP3(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> CPColor {
        let lr = CPMath.srgbToLinear(r), lg = CPMath.srgbToLinear(g), lb = CPMath.srgbToLinear(b)
        let m = CPMath.p3ToSRGB
        return fromLinearSRGB(
            m[0] * lr + m[1] * lg + m[2] * lb,
            m[3] * lr + m[4] * lg + m[5] * lb,
            m[6] * lr + m[7] * lg + m[8] * lb,
            alpha: alpha
        )
    }

    /// Inside the Display P3 gamut (small slack).
    var isInP3Gamut: Bool {
        let p = displayP3
        let slack = 0.5 / 255
        return [p.r, p.g, p.b].allSatisfy { $0 >= -slack && $0 <= 1 + slack }
    }

    // MARK: Oklab / OKLCH (Björn Ottosson, absolute: independent of the display)

    var oklab: CPOklab {
        let l = linearSRGB
        let lc = 0.4122214708 * l.r + 0.5363325363 * l.g + 0.0514459929 * l.b
        let mc = 0.2119034982 * l.r + 0.6806995451 * l.g + 0.1073969566 * l.b
        let sc = 0.0883024619 * l.r + 0.2817188376 * l.g + 0.6299787005 * l.b
        let l_ = cbrt(lc), m_ = cbrt(mc), s_ = cbrt(sc)
        return CPOklab(
            l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    static func fromOklab(_ lab: CPOklab, alpha: Double = 1) -> CPColor {
        let l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return fromLinearSRGB(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
            alpha: alpha
        )
    }

    var oklch: CPOklch { oklab.lch }

    static func fromOklch(_ lch: CPOklch, alpha: Double = 1) -> CPColor {
        fromOklab(lch.lab, alpha: alpha)
    }

    /// OKLCH with chroma reduced (hue and lightness kept) until the color
    /// fits sRGB: the CSS Color 4 approach without the JND shortcut.
    static func fittingSRGB(_ lch: CPOklch, alpha: Double = 1) -> CPColor {
        let l = CPMath.clamp01(lch.l)
        if l >= 0.99999 { return CPColor(red: 1, green: 1, blue: 1, alpha: alpha) }
        if l <= 0.00001 { return CPColor(red: 0, green: 0, blue: 0, alpha: alpha) }
        let direct = fromOklch(CPOklch(l: l, c: lch.c, h: lch.h), alpha: alpha)
        if direct.isStrictlyInSRGB { return direct }
        var low = 0.0, high = max(lch.c, 0)
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if fromOklch(CPOklch(l: l, c: mid, h: lch.h)).isStrictlyInSRGB { low = mid } else { high = mid }
        }
        return fromOklch(CPOklch(l: l, c: low, h: lch.h), alpha: alpha).clamped
    }

    var isStrictlyInSRGB: Bool {
        let e = 1e-7
        return [red, green, blue].allSatisfy { $0 >= -e && $0 <= 1 + e }
    }

    // MARK: CIELAB (D50, as CSS lab())

    var cieLab: (l: Double, a: Double, b: Double) {
        let x = linearSRGB
        let m = CPMath.linearSRGBToXYZD50
        let X = m[0] * x.r + m[1] * x.g + m[2] * x.b
        let Y = m[3] * x.r + m[4] * x.g + m[5] * x.b
        let Z = m[6] * x.r + m[7] * x.g + m[8] * x.b
        let w = CPMath.d50White
        let fx = CPMath.labF(X / w.x), fy = CPMath.labF(Y / w.y), fz = CPMath.labF(Z / w.z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func fromCIELab(l: Double, a: Double, b: Double, alpha: Double = 1) -> CPColor {
        let fy = (l + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        let w = CPMath.d50White
        let X = CPMath.labFInverse(fx) * w.x
        let Y = CPMath.labFInverse(fy) * w.y
        let Z = CPMath.labFInverse(fz) * w.z
        let m = CPMath.xyzD50ToLinearSRGB
        return fromLinearSRGB(
            m[0] * X + m[1] * Y + m[2] * Z,
            m[3] * X + m[4] * Y + m[5] * Z,
            m[6] * X + m[7] * Y + m[8] * Z,
            alpha: alpha
        )
    }

    // MARK: HSL / HSB (of the clamped sRGB color)

    /// Hue in degrees (0..<360), saturation and lightness 0…1.
    var hsl: (h: Double, s: Double, l: Double) {
        let c = clamped
        let maxV = max(c.red, c.green, c.blue), minV = min(c.red, c.green, c.blue)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 1e-9 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        return (CPMath.hue(c, maxV: maxV, delta: d), min(max(s, 0), 1), l)
    }

    /// Hue in degrees, saturation and brightness 0…1.
    var hsb: (h: Double, s: Double, b: Double) {
        let c = clamped
        let maxV = max(c.red, c.green, c.blue), minV = min(c.red, c.green, c.blue)
        let d = maxV - minV
        guard maxV > 1e-9 else { return (0, 0, 0) }
        let s = d / maxV
        return (d > 1e-9 ? CPMath.hue(c, maxV: maxV, delta: d) : 0, s, maxV)
    }

    static func fromHSL(h: Double, s: Double, l: Double, alpha: Double = 1) -> CPColor {
        let s = CPMath.clamp01(s), l = CPMath.clamp01(l)
        let c = (1 - abs(2 * l - 1)) * s
        let hp = CPMath.normalizedHue(h) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b) = CPMath.huePrime(hp, c: c, x: x)
        let m = l - c / 2
        return CPColor(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    static func fromHSB(h: Double, s: Double, b: Double, alpha: Double = 1) -> CPColor {
        let s = CPMath.clamp01(s), v = CPMath.clamp01(b)
        let c = v * s
        let hp = CPMath.normalizedHue(h) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, bl) = CPMath.huePrime(hp, c: c, x: x)
        let m = v - c
        return CPColor(red: r + m, green: g + m, blue: bl + m, alpha: alpha)
    }

    // MARK: Distance

    /// ΔE in Oklab (Euclidean): about 0.02 is a just-noticeable difference.
    func deltaE(_ other: CPColor) -> Double {
        let p = oklab, q = other.oklab
        let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

struct CPOklab: Hashable, Sendable {
    var l: Double
    var a: Double
    var b: Double

    var lch: CPOklch {
        let c = (a * a + b * b).squareRoot()
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return CPOklch(l: l, c: c, h: c < 1e-6 ? 0 : h)
    }
}

struct CPOklch: Hashable, Sendable {
    /// Lightness 0…1.
    var l: Double
    /// Chroma (0 to about 0.37 for real colors).
    var c: Double
    /// Hue in degrees.
    var h: Double

    var lab: CPOklab {
        let r = h * .pi / 180
        return CPOklab(l: l, a: c * cos(r), b: c * sin(r))
    }
}

/// Number crunching shared by the color types.
enum CPMath {
    static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }

    /// Clamp, then round to the nearest 8-bit step.
    static func to8(_ v: Double) -> Int {
        Int((clamp01(v) * 255).rounded())
    }

    static func srgbToLinear(_ v: Double) -> Double {
        let a = abs(v)
        let lin = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -lin : lin
    }

    static func linearToSRGB(_ v: Double) -> Double {
        let a = abs(v)
        let enc = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return v < 0 ? -enc : enc
    }

    static func normalizedHue(_ h: Double) -> Double {
        guard h.isFinite else { return 0 }
        let r = h.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    static func hue(_ c: CPColor, maxV: Double, delta d: Double) -> Double {
        var h: Double
        if maxV == c.red {
            h = ((c.green - c.blue) / d).truncatingRemainder(dividingBy: 6)
        } else if maxV == c.green {
            h = (c.blue - c.red) / d + 2
        } else {
            h = (c.red - c.green) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return h >= 360 ? h - 360 : h
    }

    static func huePrime(_ hp: Double, c: Double, x: Double) -> (Double, Double, Double) {
        switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
    }

    /// Linear sRGB → linear Display P3 (both D65), row-major.
    static let srgbToP3: [Double] = [
        0.8224621209, 0.1775378791, 0.0000000000,
        0.0331941989, 0.9668058011, 0.0000000000,
        0.0170826307, 0.0723974407, 0.9105199286,
    ]

    /// Linear Display P3 → linear sRGB, row-major.
    static let p3ToSRGB: [Double] = [
        1.2249401763, -0.2249401763, 0.0000000000,
        -0.0420569547, 1.0420569547, 0.0000000000,
        -0.0196375546, -0.0786360456, 1.0982736001,
    ]

    /// Linear sRGB → XYZ D50 (Bradford-adapted), as CSS Color 4.
    static let linearSRGBToXYZD50: [Double] = [
        0.4360747, 0.3850649, 0.1430804,
        0.2225045, 0.7168786, 0.0606169,
        0.0139322, 0.0971045, 0.7141733,
    ]

    static let xyzD50ToLinearSRGB: [Double] = [
        3.1338561, -1.6168667, -0.4906146,
        -0.9787684, 1.9161415, 0.0334540,
        0.0719453, -0.2289914, 1.4052427,
    ]

    static let d50White = (x: 0.3457 / 0.3585, y: 1.0, z: (1.0 - 0.3457 - 0.3585) / 0.3585)

    static func labF(_ t: Double) -> Double {
        let e = 216.0 / 24389.0, k = 24389.0 / 27.0
        return t > e ? cbrt(t) : (k * t + 16) / 116
    }

    static func labFInverse(_ f: Double) -> Double {
        let e = 216.0 / 24389.0, k = 24389.0 / 27.0
        let f3 = f * f * f
        return f3 > e ? f3 : (116 * f - 16) / k
    }
}

// MARK: - Contrast

/// WCAG 2.x contrast (and APCA, shown as an extra, not yet a standard).
enum CPContrast {
    /// WCAG relative luminance from **clamped, linearized sRGB**.
    static func luminance(_ color: CPColor) -> Double {
        let c = color.clamped
        return 0.2126 * CPMath.srgbToLinear(c.red) + 0.7152 * CPMath.srgbToLinear(c.green) + 0.0722 * CPMath.srgbToLinear(c.blue)
    }

    /// (L1 + 0.05) / (L2 + 0.05), lighter over darker: 1…21.
    static func ratio(_ a: CPColor, _ b: CPColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The ratio as WCAG tools print it, two decimals ("3.68:1"), rounded
    /// down near a threshold so 4.499 never reads as a pass.
    static func ratioText(_ r: Double) -> String {
        var shown = (r * 100).rounded() / 100
        // Rounding must never turn a fail into a pass (4.496 is not 4.50).
        if [3.0, 4.5, 7.0].contains(where: { r < $0 && shown >= $0 }) {
            shown = (r * 100).rounded(.down) / 100
        }
        return String(format: "%.2f:1", shown)
    }

    enum Level: String, CaseIterable, Identifiable, Sendable {
        case aaNormal, aaLarge, aaaNormal, aaaLarge, nonText

        var id: String { rawValue }

        var threshold: Double {
            switch self {
            case .aaNormal: 4.5
            case .aaLarge: 3
            case .aaaNormal: 7
            case .aaaLarge: 4.5
            case .nonText: 3
            }
        }

        var title: String {
            switch self {
            case .aaNormal: "AA"
            case .aaLarge: "AA Large"
            case .aaaNormal: "AAA"
            case .aaaLarge: "AAA Large"
            case .nonText: "UI"
            }
        }

        var detail: String {
            switch self {
            case .aaNormal: "Normal text, at least 4.5:1 (WCAG 1.4.3)"
            case .aaLarge: "Large text (24 px, or 18.66 px bold), at least 3:1 (WCAG 1.4.3)"
            case .aaaNormal: "Normal text, at least 7:1 (WCAG 1.4.6)"
            case .aaaLarge: "Large text, at least 4.5:1 (WCAG 1.4.6)"
            case .nonText: "Icons, borders and controls, at least 3:1 (WCAG 1.4.11)"
            }
        }
    }

    static func passes(_ level: Level, ratio: Double) -> Bool {
        ratio + 1e-9 >= level.threshold
    }

    /// APCA 0.0.98G-4g lightness contrast Lc (text on background). Positive
    /// for dark text on a light background, negative for light on dark.
    static func apca(text: CPColor, background: CPColor) -> Double {
        func y(_ c: CPColor) -> Double {
            let k = c.clamped
            let v = 0.2126729 * pow(k.red, 2.4) + 0.7151522 * pow(k.green, 2.4) + 0.0721750 * pow(k.blue, 2.4)
            return v < 0.022 ? v + pow(0.022 - v, 1.414) : v
        }
        let yt = y(text), yb = y(background)
        guard abs(yb - yt) >= 0.0005 else { return 0 }
        if yb > yt {
            let s = (pow(yb, 0.56) - pow(yt, 0.57)) * 1.14
            return s < 0.1 ? 0 : (s - 0.027) * 100
        } else {
            let s = (pow(yb, 0.65) - pow(yt, 0.62)) * 1.14
            return s > -0.1 ? 0 : (s + 0.027) * 100
        }
    }

    /// A foreground close to `foreground` (same OKLCH hue, chroma reduced
    /// only to stay in sRGB) that reaches `target` against `background`.
    /// Tries darker and lighter and returns the smaller lightness change;
    /// nil when it already passes or neither direction can.
    static func suggestion(foreground: CPColor, background: CPColor, target: Double = 4.5) -> CPColor? {
        guard ratio(foreground, background) + 1e-9 < target else { return nil }
        let base = foreground.oklch
        func search(towards end: Double) -> CPColor? {
            let endColor = CPColor.fittingSRGB(CPOklch(l: end, c: base.c, h: base.h)).quantized
            guard ratio(endColor, background) >= target else { return nil }
            var near = base.l, far = end
            for _ in 0..<30 {
                let mid = (near + far) / 2
                let c = CPColor.fittingSRGB(CPOklch(l: mid, c: base.c, h: base.h)).quantized
                if ratio(c, background) >= target { far = mid } else { near = mid }
            }
            // Quantized to 8-bit so the hex the user copies really passes.
            var result = CPColor.fittingSRGB(CPOklch(l: far, c: base.c, h: base.h)).quantized
            var steps = 0
            while ratio(result, background) < target, steps < 8 {
                far += end > base.l ? 0.003 : -0.003
                result = CPColor.fittingSRGB(CPOklch(l: far, c: base.c, h: base.h)).quantized
                steps += 1
            }
            return ratio(result, background) >= target ? result : nil
        }
        let darker = search(towards: 0)
        let lighter = search(towards: 1)
        switch (darker, lighter) {
        case let (d?, l?):
            return abs(d.oklch.l - base.l) <= abs(l.oklch.l - base.l) ? d : l
        case let (d?, nil): return d
        case let (nil, l?): return l
        default: return nil
        }
    }
}

// MARK: - Shades and tints

enum CPShades {
    /// Five tints, the base, five shades: OKLCH lightness steps (hue kept,
    /// chroma reduced only to stay in sRGB), lightest first.
    static func tintsAndShades(_ base: CPColor, count: Int = 5) -> [CPColor] {
        let lch = base.clamped.oklch
        var result: [CPColor] = []
        let top = 0.97, bottom = 0.18
        for i in stride(from: count, to: 0, by: -1) {
            let t = Double(i) / Double(count + 1)
            let l = lch.l + (top - lch.l) * t
            result.append(CPColor.fittingSRGB(CPOklch(l: l, c: lch.c * (1 - 0.6 * t), h: lch.h)))
        }
        result.append(base.clamped)
        for i in 1...count {
            let t = Double(i) / Double(count + 1)
            let l = lch.l - (lch.l - bottom) * t
            result.append(CPColor.fittingSRGB(CPOklch(l: l, c: lch.c * (1 - 0.35 * t), h: lch.h)))
        }
        return result
    }

    /// Tailwind-style steps.
    static let scaleSteps = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]
    /// Target OKLCH lightness per step (close to Tailwind v4's palette).
    static let scaleLightness: [Double] = [0.975, 0.94, 0.885, 0.81, 0.715, 0.63, 0.55, 0.48, 0.41, 0.36, 0.27]
    /// Chroma relative to the base's, per step.
    static let scaleChroma: [Double] = [0.12, 0.25, 0.45, 0.7, 0.9, 1.0, 0.98, 0.88, 0.75, 0.62, 0.45]

    /// A 50…950 scale around the base's hue and chroma, with the base
    /// itself at its nearest step (so `blue-500`-like picks sit at 500).
    static func scale(_ base: CPColor) -> [(step: Int, color: CPColor)] {
        let lch = base.clamped.oklch
        // Greys stay grey; chroma gets a floor so a muted base still gives a usable scale.
        let chroma = lch.c < 0.02 ? lch.c : max(lch.c, 0.08)
        let baseStep = nearestStep(base)
        return scaleSteps.indices.map { i in
            if scaleSteps[i] == baseStep { return (scaleSteps[i], base.clamped) }
            return (scaleSteps[i], CPColor.fittingSRGB(CPOklch(l: scaleLightness[i], c: chroma * scaleChroma[i], h: lch.h)))
        }
    }

    /// The step of the scale closest in lightness to the base itself.
    static func nearestStep(_ base: CPColor) -> Int {
        let l = base.clamped.oklch.l
        var best = 0
        for i in scaleLightness.indices where abs(scaleLightness[i] - l) < abs(scaleLightness[best] - l) {
            best = i
        }
        return scaleSteps[best]
    }
}
