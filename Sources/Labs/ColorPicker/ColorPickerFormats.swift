import Foundation

/// The text formats a color can be copied as. Order is the order of the
/// rows in the drawer and of the "Copy As" menu.
enum CPFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case hex
    case rgb
    case hsl
    case hsb
    case oklch
    case displayP3
    case swiftUI
    case uiKit
    case appKit
    case tailwind

    var id: String { rawValue }

    /// Row label.
    var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .hsb: "HSB"
        case .oklch: "OKLCH"
        case .displayP3: "P3"
        case .swiftUI: "SwiftUI"
        case .uiKit: "UIKit"
        case .appKit: "AppKit"
        case .tailwind: "Tailwind"
        }
    }

    /// Menu label.
    var menuTitle: String {
        switch self {
        case .hex: "HEX (#3B82F6)"
        case .rgb: "RGB (rgb(59 130 246))"
        case .hsl: "HSL (hsl(217 91% 60%))"
        case .hsb: "HSB (217°, 76%, 96%)"
        case .oklch: "OKLCH (oklch(62.3% 0.188 259.8))"
        case .displayP3: "CSS Display P3 (color(display-p3 …))"
        case .swiftUI: "SwiftUI Color"
        case .uiKit: "UIKit UIColor"
        case .appKit: "AppKit NSColor"
        case .tailwind: "Tailwind Class (blue-500)"
        }
    }
}

/// Output options (gear menu and the drawer's ⋯ menu).
struct CPFormatOptions: Codable, Equatable, Sendable {
    var lowercaseHex = false
    var hexHash = true
    /// `rgb(59, 130, 246)` / `hsl(217, 91%, 60%)` instead of the CSS Color 4 space syntax.
    var legacyCSS = false
    /// HSL and HSB get decimals when whole numbers would not read back to
    /// the same hex (`hsl(217.2 91.2% 59.8%)`). Off: whole numbers, rounded.
    var preciseHSL = false

    init(lowercaseHex: Bool = false, hexHash: Bool = true, legacyCSS: Bool = false, preciseHSL: Bool = false) {
        self.lowercaseHex = lowercaseHex
        self.hexHash = hexHash
        self.legacyCSS = legacyCSS
        self.preciseHSL = preciseHSL
    }

    /// Missing keys keep their defaults, so options saved by an older build
    /// still load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowercaseHex = try c.decodeIfPresent(Bool.self, forKey: .lowercaseHex) ?? false
        hexHash = try c.decodeIfPresent(Bool.self, forKey: .hexHash) ?? true
        legacyCSS = try c.decodeIfPresent(Bool.self, forKey: .legacyCSS) ?? false
        preciseHSL = try c.decodeIfPresent(Bool.self, forKey: .preciseHSL) ?? false
    }
}

enum CPFormatter {
    /// The text for `format`. Colors outside sRGB use their P3 values in the
    /// Swift initializers (nothing is clipped there); CSS sRGB formats clamp.
    static func string(_ color: CPColor, _ format: CPFormat, options: CPFormatOptions = CPFormatOptions()) -> String {
        switch format {
        case .hex:
            var hex = String(format: "%06X", color.hexValue)
            if options.lowercaseHex { hex = hex.lowercased() }
            return (options.hexHash ? "#" : "") + hex
        case .rgb:
            let c = color.rgb8
            return options.legacyCSS ? "rgb(\(c.r), \(c.g), \(c.b))" : "rgb(\(c.r) \(c.g) \(c.b))"
        case .hsl:
            // Whole numbers by default (they can be up to 3 steps off per
            // channel when read back); "Precise HSL" adds decimals only when needed.
            let h = color.hsl
            let d = options.preciseHSL ? digits { d in
                CPColor.fromHSL(h: round(h.h, d), s: round(h.s * 100, d) / 100, l: round(h.l * 100, d) / 100).hexValue == color.hexValue
            } : 0
            let hue = hueText(h.h, d), s = percentText(h.s, d), l = percentText(h.l, d)
            return options.legacyCSS ? "hsl(\(hue), \(s)%, \(l)%)" : "hsl(\(hue) \(s)% \(l)%)"
        case .hsb:
            let h = color.hsb
            let d = options.preciseHSL ? digits { d in
                CPColor.fromHSB(h: round(h.h, d), s: round(h.s * 100, d) / 100, b: round(h.b * 100, d) / 100).hexValue == color.hexValue
            } : 0
            return "\(hueText(h.h, d))°, \(percentText(h.s, d))%, \(percentText(h.b, d))%"
        case .oklch:
            // Short (62.3% 0.188 259.8) when that reads back to the same
            // color, else more digits, so a copied value never drifts: the
            // same hex for an sRGB color, the same Display P3 values (within
            // half an 8-bit step) for a wide-gamut one.
            let o = color.oklch
            let hue = o.c < 0.0005 ? 0 : o.h
            for (ld, cd, hd) in [(1, 3, 1), (2, 4, 2), (3, 5, 3)] {
                let text = "oklch(\(fixed(o.l * 100, ld))% \(fixed(o.c, cd)) \(fixed(hue, hd)))"
                let back = CPColor.fromOklch(CPOklch(l: round(o.l * 100, ld) / 100, c: round(o.c, cd), h: round(hue, hd)))
                if (ld, cd, hd) == (3, 5, 3) || readsBack(back, as: color) {
                    return text
                }
            }
            return ""
        case .displayP3:
            let p = color.displayP3
            let digits = CPColor.fromDisplayP3(round(CPMath.clamp01(p.r), 3), round(CPMath.clamp01(p.g), 3), round(CPMath.clamp01(p.b), 3)).hexValue == color.hexValue ? 3 : 4
            return "color(display-p3 \(unit(p.r, digits)) \(unit(p.g, digits)) \(unit(p.b, digits)))"
        case .swiftUI:
            if color.isInSRGBGamut {
                let c = color.clamped
                return "Color(red: \(fixed(c.red, 3)), green: \(fixed(c.green, 3)), blue: \(fixed(c.blue, 3)))"
            }
            let p = color.displayP3
            return "Color(.displayP3, red: \(unit(p.r)), green: \(unit(p.g)), blue: \(unit(p.b)))"
        case .uiKit:
            if color.isInSRGBGamut {
                let c = color.clamped
                return "UIColor(red: \(fixed(c.red, 3)), green: \(fixed(c.green, 3)), blue: \(fixed(c.blue, 3)), alpha: 1)"
            }
            let p = color.displayP3
            return "UIColor(displayP3Red: \(unit(p.r)), green: \(unit(p.g)), blue: \(unit(p.b)), alpha: 1)"
        case .appKit:
            // srgbRed, never the ambiguous calibrated / device initializers.
            if color.isInSRGBGamut {
                let c = color.clamped
                return "NSColor(srgbRed: \(fixed(c.red, 3)), green: \(fixed(c.green, 3)), blue: \(fixed(c.blue, 3)), alpha: 1)"
            }
            let p = color.displayP3
            return "NSColor(displayP3Red: \(unit(p.r)), green: \(unit(p.g)), blue: \(unit(p.b)), alpha: 1)"
        case .tailwind:
            return CPTailwind.nearest(color).name
        }
    }

    /// What a row or menu shows: the copied text, except that a Tailwind
    /// class that is only the nearest match reads "≈ red-500" (the copy
    /// stays "red-500").
    static func display(_ color: CPColor, _ format: CPFormat, options: CPFormatOptions = CPFormatOptions()) -> String {
        guard format == .tailwind else { return string(color, format, options: options) }
        let match = CPTailwind.nearest(color)
        return (match.isExact ? "" : "≈ ") + match.name
    }

    /// True when `back` (a rounded text read back) is the same color as
    /// `color`: the same hex inside sRGB, the same Display P3 components
    /// within half an 8-bit step outside it (where the hex is clipped).
    static func readsBack(_ back: CPColor, as color: CPColor) -> Bool {
        guard !color.isInSRGBGamut else { return back.hexValue == color.hexValue }
        let p = color.displayP3, q = back.displayP3
        let tolerance = 0.5 / 255
        return abs(p.r - q.r) <= tolerance && abs(p.g - q.g) <= tolerance && abs(p.b - q.b) <= tolerance
    }

    /// The fewest decimals (0, 1 or 2) for which `fits` holds; 2 if none does.
    static func digits(_ fits: (Int) -> Bool) -> Int {
        for d in 0..<2 where fits(d) { return d }
        return 2
    }

    /// A hue in degrees, 0..<360, with up to `digits` decimals (whole
    /// numbers round half up, as before; "217.0" is written "217").
    static func hueText(_ h: Double, _ digits: Int) -> String {
        guard digits > 0 else { return "\(Int(h.rounded()) % 360)" }
        let v = round(h, digits)
        return trimmed(fixed(v >= 360 ? v - 360 : v, digits))
    }

    /// A 0…1 fraction as a percentage number, with up to `digits` decimals.
    static func percentText(_ v: Double, _ digits: Int) -> String {
        guard digits > 0 else { return "\(Int((v * 100).rounded()))" }
        return trimmed(fixed(v * 100, digits))
    }

    /// "59.80" → "59.8", "217.0" → "217".
    static func trimmed(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = Substring(s)
        while t.hasSuffix("0") { t = t.dropLast() }
        if t.hasSuffix(".") { t = t.dropLast() }
        return String(t)
    }

    /// "0.231": three decimals, trailing zeros kept so columns line up.
    static func fixed(_ v: Double, _ digits: Int) -> String {
        let s = String(format: "%.\(digits)f", v)
        return s == "-0." + String(repeating: "0", count: digits) ? String(s.dropFirst()) : s
    }

    /// A 0…1 component, clamped, three decimals.
    static func unit(_ v: Double, _ digits: Int = 3) -> String { fixed(CPMath.clamp01(v), digits) }

    static func round(_ v: Double, _ digits: Int) -> Double {
        let p = pow(10.0, Double(digits))
        return (v * p).rounded() / p
    }
}

// MARK: - Parsing

/// Reads a color from text: `#3B82F6`, `#38f`, `3B82F6`, `rgb(…)`, `rgba(…)`,
/// `hsl(…)`, `oklch(…)`, `oklab(…)`, `lab(…)`, `color(display-p3 …)`,
/// `color(srgb …)`, SwiftUI `Color(red:…)` / `Color(.displayP3, red:…)`,
/// `UIColor(red:…)`, `NSColor(srgbRed:…)`, `NSColor(displayP3Red:…)`,
/// `hsb(…)` / `hsv(…)` and the HSB row's own `217°, 76%, 96%`, a CSS color
/// name or a Tailwind class (`blue-500`). The shape decides the format.
///
/// As CSS does, rgb(), hsl(), hex and color(srgb …) clamp to 0…1, and
/// oklch(), oklab() and lab() clamp lightness and map a color outside
/// Display P3 into it (chroma reduced, hue and lightness kept). Anything
/// that still isn't finite and within -0.5…1.5 (P3 fits well inside) is
/// refused, so a pasted value can never poison the saved history.
enum CPParser {
    static func parse(_ raw: String) -> CPColor? {
        guard let color = parseUnchecked(raw), color.isWellFormed else { return nil }
        return color
    }

    private static func parseUnchecked(_ raw: String) -> CPColor? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";,\"'`")))
        guard !text.isEmpty, text.count < 200 else { return nil }
        let lower = text.lowercased()

        if let hex = parseHex(lower) { return hex }
        if let open = lower.firstIndex(of: "("), lower.hasSuffix(")") {
            let name = String(lower[..<open]).trimmingCharacters(in: .whitespaces)
            let inner = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
            switch name {
            case "rgb", "rgba": return parseRGB(inner)
            case "hsl", "hsla": return parseHSL(inner)
            case "oklch": return parseOklch(inner)
            case "oklab": return parseOklab(inner)
            case "lab": return parseLab(inner)
            case "hsb", "hsba", "hsv", "hsva": return parseHSB(inner)
            default: break
            }
            if name.hasSuffix("color") {
                // CSS color(display-p3 …) has no labels; Swift initializers do.
                if name == "color", !inner.contains(":") { return parseColorFunction(inner) }
                return parseInitializer(name: name, inner: inner)
            }
        }
        if let named = CPNamedColors.color(named: lower) { return named }
        if let tw = CPTailwind.color(forClass: lower) { return tw }
        if let hsb = parseHSBTriple(lower) { return hsb }
        return nil
    }

    private static func parseHex(_ s: String) -> CPColor? {
        var body = s
        if body.hasPrefix("#") { body.removeFirst() } else if body.hasPrefix("0x") { body.removeFirst(2) } else {
            // Bare hex only when it's exactly 6 (or 8) hex digits: "add" or
            // "bed" stay words.
            guard body.count == 6 || body.count == 8 else { return nil }
        }
        guard [3, 4, 6, 8].contains(body.count), body.allSatisfy(\.isHexDigit) else { return nil }
        if body.count <= 4 { body = body.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(body, radix: 16) else { return nil }
        if body.count == 8 {
            var c = CPColor(hex: UInt32(value >> 8))
            c.alpha = Double(value & 0xFF) / 255
            return c
        }
        return CPColor(hex: UInt32(value))
    }

    /// Splits "59 130 246 / 50%" or "59, 130, 246, 0.5" into number tokens
    /// (with the alpha last, if present).
    private static func tokens(_ inner: String) -> [String] {
        inner.replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }

    /// A number with an optional % (scaled by `percentOf`) or deg.
    private static func number(_ token: String, percentOf: Double = 100) -> Double? {
        var t = token
        var scale = 1.0
        if t.hasSuffix("%") { t.removeLast(); scale = percentOf / 100 }
        else if t.hasSuffix("deg") { t.removeLast(3) }
        else if t.hasSuffix("°") { t.removeLast() }
        if t == "none" { return 0 }
        guard let v = Double(t), v.isFinite else { return nil }
        return v * scale
    }

    private static func alpha(_ list: [String], at index: Int) -> Double {
        guard list.count > index, let a = number(list[index], percentOf: 1) else { return 1 }
        return CPMath.clamp01(a)
    }

    private static func parseRGB(_ inner: String) -> CPColor? {
        let t = tokens(inner)
        guard t.count >= 3, let r = number(t[0], percentOf: 255), let g = number(t[1], percentOf: 255),
              let b = number(t[2], percentOf: 255) else { return nil }
        return CPColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha(t, at: 3)).clamped
    }

    private static func parseHSL(_ inner: String) -> CPColor? {
        let t = tokens(inner)
        guard t.count >= 3, let h = number(t[0]), let s = number(t[1]), let l = number(t[2]) else { return nil }
        return CPColor.fromHSL(h: h, s: s / 100, l: l / 100, alpha: alpha(t, at: 3)).clamped
    }

    /// `hsb(217 76% 96%)`, `hsv(217, 76%, 96%)`.
    private static func parseHSB(_ inner: String) -> CPColor? {
        let t = tokens(inner)
        guard t.count >= 3, let h = number(t[0]), let s = number(t[1]), let b = number(t[2]) else { return nil }
        return CPColor.fromHSB(h: h, s: s / 100, b: b / 100, alpha: alpha(t, at: 3)).clamped
    }

    /// The HSB row's own text, `217°, 76%, 96%`: exactly three numbers,
    /// a degree sign on the first and % on the others (so "217, 76, 96"
    /// stays unread).
    private static func parseHSBTriple(_ text: String) -> CPColor? {
        let t = tokens(text)
        guard t.count == 3, t[0].hasSuffix("°") || t[0].hasSuffix("deg"), t[1].hasSuffix("%"), t[2].hasSuffix("%") else { return nil }
        return parseHSB(text)
    }

    private static func parseOklch(_ inner: String) -> CPColor? {
        let t = tokens(inner)
        guard t.count >= 3, let l = number(t[0], percentOf: 1), let c = number(t[1], percentOf: 0.4),
              let h = number(t[2]) else { return nil }
        return fittingP3(CPOklch(l: l, c: c, h: h), alpha: alpha(t, at: 3))
    }

    private static func parseOklab(_ inner: String) -> CPColor? {
        let t = tokens(inner)
        guard t.count >= 3, let l = number(t[0], percentOf: 1), let a = number(t[1], percentOf: 0.4),
              let b = number(t[2], percentOf: 0.4) else { return nil }
        return fittingP3(CPOklab(l: l, a: a, b: b).lch, alpha: alpha(t, at: 3))
    }

    private static func parseLab(_ inner: String) -> CPColor? {
        let t = tokens(inner)
        guard t.count >= 3, let l = number(t[0], percentOf: 100), let a = number(t[1], percentOf: 125),
              let b = number(t[2], percentOf: 125) else { return nil }
        // CSS clamps L to 0…100; a and b are open-ended, so scale a huge
        // chroma down first (no display reaches 300) to keep the math finite.
        let chroma = hypot(a, b)
        let k = chroma > 300 ? 300 / chroma : 1
        let lab = CPColor.fromCIELab(l: min(max(l, 0), 100), a: a * k, b: b * k, alpha: alpha(t, at: 3))
        return lab.isInP3Gamut ? lab : fittingP3(lab.oklch, alpha: lab.alpha)
    }

    /// OKLCH as CSS reads it (lightness 0…1, chroma ≥ 0), mapped into
    /// Display P3 by reducing chroma when it falls outside.
    static func fittingP3(_ lch: CPOklch, alpha: Double = 1) -> CPColor {
        // A NaN lightness stays NaN, so `isWellFormed` refuses it.
        guard lch.l.isFinite else { return CPColor(red: .nan, green: .nan, blue: .nan, alpha: alpha) }
        let l = CPMath.clamp01(lch.l)
        let h = lch.h.isFinite ? lch.h : 0
        // No Display P3 color has a chroma near 0.5, so a larger one maps to
        // the same edge color.
        let c = lch.c.isNaN ? 0 : min(max(lch.c, 0), 0.5)
        if l >= 0.99999 { return CPColor(red: 1, green: 1, blue: 1, alpha: alpha) }
        if l <= 0.00001 { return CPColor(red: 0, green: 0, blue: 0, alpha: alpha) }
        let direct = CPColor.fromOklch(CPOklch(l: l, c: c, h: h), alpha: alpha)
        if direct.isInP3Gamut { return direct }
        var low = 0.0, high = c
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if CPColor.fromOklch(CPOklch(l: l, c: mid, h: h)).isInP3Gamut { low = mid } else { high = mid }
        }
        return CPColor.fromOklch(CPOklch(l: l, c: low, h: h), alpha: alpha)
    }

    private static func parseColorFunction(_ inner: String) -> CPColor? {
        var t = tokens(inner)
        guard t.count >= 4 else { return nil }
        let space = t.removeFirst()
        guard let r = number(t[0], percentOf: 1), let g = number(t[1], percentOf: 1), let b = number(t[2], percentOf: 1) else { return nil }
        let a = alpha(t, at: 3)
        let c = CPMath.clamp01
        switch space {
        case "display-p3": return CPColor.fromDisplayP3(c(r), c(g), c(b), alpha: a)
        case "srgb": return CPColor(red: c(r), green: c(g), blue: c(b), alpha: a)
        case "srgb-linear": return CPColor.fromLinearSRGB(c(r), c(g), c(b), alpha: a)
        default: return nil
        }
    }

    /// `Color(red: 0.2, green: 0.5, blue: 0.9)`, `Color(.displayP3, red:…)`,
    /// `UIColor(displayP3Red:…)`, `NSColor(srgbRed:…)`, `NSColor(calibratedRed:…)`.
    private static func parseInitializer(name: String, inner: String) -> CPColor? {
        var values: [String: Double] = [:]
        var isP3 = inner.contains(".displayp3") || inner.contains("displayp3red")
        for part in inner.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let v = Double(pair[1]) else { continue }
            var key = pair[0]
            if key.hasSuffix("red") { key = "red" }
            values[key] = v
        }
        if name == "cgcolor", inner.contains("displayp3") { isP3 = true }
        guard let r = values["red"], let g = values["green"], let b = values["blue"] else { return nil }
        let a = CPMath.clamp01(values["alpha"] ?? values["opacity"] ?? 1)
        return isP3 ? CPColor.fromDisplayP3(r, g, b, alpha: a) : CPColor(red: r, green: g, blue: b, alpha: a)
    }
}

extension CPColor {
    /// Finite, alpha in 0…1, and every channel within -0.5…1.5 (Display P3
    /// sits well inside), so it can be shown, converted and saved as JSON.
    var isWellFormed: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && $0 >= -0.5 && $0 <= 1.5 } && alpha.isFinite && alpha >= 0 && alpha <= 1
    }
}
