import Foundation

/// A named color and how far the picked color is from it.
struct CPNamedMatch: Equatable, Sendable {
    let name: String
    let color: CPColor
    /// ΔE in Oklab.
    let distance: Double

    /// Close enough to call it the same color (well under a JND).
    var isExact: Bool { distance < 0.001 }
}

// MARK: - CSS named colors

/// The 148 CSS Color 4 keywords. Lookup by name accepts every spelling;
/// nearest-name search skips the synonyms (grey, aqua, fuchsia).
enum CPNamedColors {
    static let all: [(name: String, hex: UInt32)] = [
        ("aliceblue", 0xF0F8FF), ("antiquewhite", 0xFAEBD7), ("aqua", 0x00FFFF), ("aquamarine", 0x7FFFD4),
        ("azure", 0xF0FFFF), ("beige", 0xF5F5DC), ("bisque", 0xFFE4C4), ("black", 0x000000),
        ("blanchedalmond", 0xFFEBCD), ("blue", 0x0000FF), ("blueviolet", 0x8A2BE2), ("brown", 0xA52A2A),
        ("burlywood", 0xDEB887), ("cadetblue", 0x5F9EA0), ("chartreuse", 0x7FFF00), ("chocolate", 0xD2691E),
        ("coral", 0xFF7F50), ("cornflowerblue", 0x6495ED), ("cornsilk", 0xFFF8DC), ("crimson", 0xDC143C),
        ("cyan", 0x00FFFF), ("darkblue", 0x00008B), ("darkcyan", 0x008B8B), ("darkgoldenrod", 0xB8860B),
        ("darkgray", 0xA9A9A9), ("darkgreen", 0x006400), ("darkgrey", 0xA9A9A9), ("darkkhaki", 0xBDB76B),
        ("darkmagenta", 0x8B008B), ("darkolivegreen", 0x556B2F), ("darkorange", 0xFF8C00), ("darkorchid", 0x9932CC),
        ("darkred", 0x8B0000), ("darksalmon", 0xE9967A), ("darkseagreen", 0x8FBC8F), ("darkslateblue", 0x483D8B),
        ("darkslategray", 0x2F4F4F), ("darkslategrey", 0x2F4F4F), ("darkturquoise", 0x00CED1), ("darkviolet", 0x9400D3),
        ("deeppink", 0xFF1493), ("deepskyblue", 0x00BFFF), ("dimgray", 0x696969), ("dimgrey", 0x696969),
        ("dodgerblue", 0x1E90FF), ("firebrick", 0xB22222), ("floralwhite", 0xFFFAF0), ("forestgreen", 0x228B22),
        ("fuchsia", 0xFF00FF), ("gainsboro", 0xDCDCDC), ("ghostwhite", 0xF8F8FF), ("gold", 0xFFD700),
        ("goldenrod", 0xDAA520), ("gray", 0x808080), ("green", 0x008000), ("greenyellow", 0xADFF2F),
        ("grey", 0x808080), ("honeydew", 0xF0FFF0), ("hotpink", 0xFF69B4), ("indianred", 0xCD5C5C),
        ("indigo", 0x4B0082), ("ivory", 0xFFFFF0), ("khaki", 0xF0E68C), ("lavender", 0xE6E6FA),
        ("lavenderblush", 0xFFF0F5), ("lawngreen", 0x7CFC00), ("lemonchiffon", 0xFFFACD), ("lightblue", 0xADD8E6),
        ("lightcoral", 0xF08080), ("lightcyan", 0xE0FFFF), ("lightgoldenrodyellow", 0xFAFAD2), ("lightgray", 0xD3D3D3),
        ("lightgreen", 0x90EE90), ("lightgrey", 0xD3D3D3), ("lightpink", 0xFFB6C1), ("lightsalmon", 0xFFA07A),
        ("lightseagreen", 0x20B2AA), ("lightskyblue", 0x87CEFA), ("lightslategray", 0x778899), ("lightslategrey", 0x778899),
        ("lightsteelblue", 0xB0C4DE), ("lightyellow", 0xFFFFE0), ("lime", 0x00FF00), ("limegreen", 0x32CD32),
        ("linen", 0xFAF0E6), ("magenta", 0xFF00FF), ("maroon", 0x800000), ("mediumaquamarine", 0x66CDAA),
        ("mediumblue", 0x0000CD), ("mediumorchid", 0xBA55D3), ("mediumpurple", 0x9370DB), ("mediumseagreen", 0x3CB371),
        ("mediumslateblue", 0x7B68EE), ("mediumspringgreen", 0x00FA9A), ("mediumturquoise", 0x48D1CC), ("mediumvioletred", 0xC71585),
        ("midnightblue", 0x191970), ("mintcream", 0xF5FFFA), ("mistyrose", 0xFFE4E1), ("moccasin", 0xFFE4B5),
        ("navajowhite", 0xFFDEAD), ("navy", 0x000080), ("oldlace", 0xFDF5E6), ("olive", 0x808000),
        ("olivedrab", 0x6B8E23), ("orange", 0xFFA500), ("orangered", 0xFF4500), ("orchid", 0xDA70D6),
        ("palegoldenrod", 0xEEE8AA), ("palegreen", 0x98FB98), ("paleturquoise", 0xAFEEEE), ("palevioletred", 0xDB7093),
        ("papayawhip", 0xFFEFD5), ("peachpuff", 0xFFDAB9), ("peru", 0xCD853F), ("pink", 0xFFC0CB),
        ("plum", 0xDDA0DD), ("powderblue", 0xB0E0E6), ("purple", 0x800080), ("rebeccapurple", 0x663399),
        ("red", 0xFF0000), ("rosybrown", 0xBC8F8F), ("royalblue", 0x4169E1), ("saddlebrown", 0x8B4513),
        ("salmon", 0xFA8072), ("sandybrown", 0xF4A460), ("seagreen", 0x2E8B57), ("seashell", 0xFFF5EE),
        ("sienna", 0xA0522D), ("silver", 0xC0C0C0), ("skyblue", 0x87CEEB), ("slateblue", 0x6A5ACD),
        ("slategray", 0x708090), ("slategrey", 0x708090), ("snow", 0xFFFAFA), ("springgreen", 0x00FF7F),
        ("steelblue", 0x4682B4), ("tan", 0xD2B48C), ("teal", 0x008080), ("thistle", 0xD8BFD8),
        ("tomato", 0xFF6347), ("turquoise", 0x40E0D0), ("violet", 0xEE82EE), ("wheat", 0xF5DEB3),
        ("white", 0xFFFFFF), ("whitesmoke", 0xF5F5F5), ("yellow", 0xFFFF00), ("yellowgreen", 0x9ACD32),
    ]

    private static let synonyms: Set<String> = ["aqua", "fuchsia", "grey", "darkgrey", "dimgrey", "lightgrey", "darkslategrey", "lightslategrey", "slategrey"]

    /// Precomputed Oklab of each searchable name.
    private static let searchable: [(name: String, color: CPColor, lab: CPOklab)] = all
        .filter { !synonyms.contains($0.name) }
        .map { entry in
            let color = CPColor(hex: entry.hex)
            return (entry.name, color, color.oklab)
        }

    private static let byName: [String: UInt32] = Dictionary(all.map { ($0.name, $0.hex) }, uniquingKeysWith: { first, _ in first })

    static func color(named name: String) -> CPColor? {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        if key == "transparent" { return CPColor(red: 0, green: 0, blue: 0, alpha: 0) }
        return byName[key].map { CPColor(hex: $0) }
    }

    /// Nearest keyword by ΔE in Oklab (perceptual, unlike RGB distance).
    /// Measured from the color as picked (a wide-gamut color is not clipped
    /// first), so a P3 red is never called exactly "red".
    static func nearest(_ color: CPColor) -> CPNamedMatch {
        let lab = color.oklab
        var best = searchable[0]
        var bestDistance = Double.infinity
        for entry in searchable {
            let dl = entry.lab.l - lab.l, da = entry.lab.a - lab.a, db = entry.lab.b - lab.b
            let d = dl * dl + da * da + db * db
            if d < bestDistance {
                bestDistance = d
                best = entry
            }
        }
        return CPNamedMatch(name: best.name, color: best.color, distance: bestDistance.squareRoot())
    }
}

// MARK: - Tailwind v3

/// Tailwind CSS v3.4 default palette (22 hues × 50…950, plus black and
/// white). Nearest class by ΔE in Oklab.
enum CPTailwind {
    static let steps = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]

    static let palette: [(name: String, shades: [UInt32])] = [
        ("slate", [0xF8FAFC, 0xF1F5F9, 0xE2E8F0, 0xCBD5E1, 0x94A3B8, 0x64748B, 0x475569, 0x334155, 0x1E293B, 0x0F172A, 0x020617]),
        ("gray", [0xF9FAFB, 0xF3F4F6, 0xE5E7EB, 0xD1D5DB, 0x9CA3AF, 0x6B7280, 0x4B5563, 0x374151, 0x1F2937, 0x111827, 0x030712]),
        ("zinc", [0xFAFAFA, 0xF4F4F5, 0xE4E4E7, 0xD4D4D8, 0xA1A1AA, 0x71717A, 0x52525B, 0x3F3F46, 0x27272A, 0x18181B, 0x09090B]),
        ("neutral", [0xFAFAFA, 0xF5F5F5, 0xE5E5E5, 0xD4D4D4, 0xA3A3A3, 0x737373, 0x525252, 0x404040, 0x262626, 0x171717, 0x0A0A0A]),
        ("stone", [0xFAFAF9, 0xF5F5F4, 0xE7E5E4, 0xD6D3D1, 0xA8A29E, 0x78716C, 0x57534E, 0x44403C, 0x292524, 0x1C1917, 0x0C0A09]),
        ("red", [0xFEF2F2, 0xFEE2E2, 0xFECACA, 0xFCA5A5, 0xF87171, 0xEF4444, 0xDC2626, 0xB91C1C, 0x991B1B, 0x7F1D1D, 0x450A0A]),
        ("orange", [0xFFF7ED, 0xFFEDD5, 0xFED7AA, 0xFDBA74, 0xFB923C, 0xF97316, 0xEA580C, 0xC2410C, 0x9A3412, 0x7C2D12, 0x431407]),
        ("amber", [0xFFFBEB, 0xFEF3C7, 0xFDE68A, 0xFCD34D, 0xFBBF24, 0xF59E0B, 0xD97706, 0xB45309, 0x92400E, 0x78350F, 0x451A03]),
        ("yellow", [0xFEFCE8, 0xFEF9C3, 0xFEF08A, 0xFDE047, 0xFACC15, 0xEAB308, 0xCA8A04, 0xA16207, 0x854D0E, 0x713F12, 0x422006]),
        ("lime", [0xF7FEE7, 0xECFCCB, 0xD9F99D, 0xBEF264, 0xA3E635, 0x84CC16, 0x65A30D, 0x4D7C0F, 0x3F6212, 0x365314, 0x1A2E05]),
        ("green", [0xF0FDF4, 0xDCFCE7, 0xBBF7D0, 0x86EFAC, 0x4ADE80, 0x22C55E, 0x16A34A, 0x15803D, 0x166534, 0x14532D, 0x052E16]),
        ("emerald", [0xECFDF5, 0xD1FAE5, 0xA7F3D0, 0x6EE7B7, 0x34D399, 0x10B981, 0x059669, 0x047857, 0x065F46, 0x064E3B, 0x022C22]),
        ("teal", [0xF0FDFA, 0xCCFBF1, 0x99F6E4, 0x5EEAD4, 0x2DD4BF, 0x14B8A6, 0x0D9488, 0x0F766E, 0x115E59, 0x134E4A, 0x042F2E]),
        ("cyan", [0xECFEFF, 0xCFFAFE, 0xA5F3FC, 0x67E8F9, 0x22D3EE, 0x06B6D4, 0x0891B2, 0x0E7490, 0x155E75, 0x164E63, 0x083344]),
        ("sky", [0xF0F9FF, 0xE0F2FE, 0xBAE6FD, 0x7DD3FC, 0x38BDF8, 0x0EA5E9, 0x0284C7, 0x0369A1, 0x075985, 0x0C4A6E, 0x082F49]),
        ("blue", [0xEFF6FF, 0xDBEAFE, 0xBFDBFE, 0x93C5FD, 0x60A5FA, 0x3B82F6, 0x2563EB, 0x1D4ED8, 0x1E40AF, 0x1E3A8A, 0x172554]),
        ("indigo", [0xEEF2FF, 0xE0E7FF, 0xC7D2FE, 0xA5B4FC, 0x818CF8, 0x6366F1, 0x4F46E5, 0x4338CA, 0x3730A3, 0x312E81, 0x1E1B4B]),
        ("violet", [0xF5F3FF, 0xEDE9FE, 0xDDD6FE, 0xC4B5FD, 0xA78BFA, 0x8B5CF6, 0x7C3AED, 0x6D28D9, 0x5B21B6, 0x4C1D95, 0x2E1065]),
        ("purple", [0xFAF5FF, 0xF3E8FF, 0xE9D5FF, 0xD8B4FE, 0xC084FC, 0xA855F7, 0x9333EA, 0x7E22CE, 0x6B21A8, 0x581C87, 0x3B0764]),
        ("fuchsia", [0xFDF4FF, 0xFAE8FF, 0xF5D0FE, 0xF0ABFC, 0xE879F9, 0xD946EF, 0xC026D3, 0xA21CAF, 0x86198F, 0x701A75, 0x4A044E]),
        ("pink", [0xFDF2F8, 0xFCE7F3, 0xFBCFE8, 0xF9A8D4, 0xF472B6, 0xEC4899, 0xDB2777, 0xBE185D, 0x9D174D, 0x831843, 0x500724]),
        ("rose", [0xFFF1F2, 0xFFE4E6, 0xFECDD3, 0xFDA4AF, 0xFB7185, 0xF43F5E, 0xE11D48, 0xBE123C, 0x9F1239, 0x881337, 0x4C0519]),
    ]

    private static let entries: [(name: String, color: CPColor, lab: CPOklab)] = {
        var list: [(String, CPColor, CPOklab)] = []
        for (hue, shades) in palette {
            for (i, hex) in shades.enumerated() {
                let c = CPColor(hex: hex)
                list.append(("\(hue)-\(steps[i])", c, c.oklab))
            }
        }
        list.append(("black", .black, CPColor.black.oklab))
        list.append(("white", .white, CPColor.white.oklab))
        return list
    }()

    static var classCount: Int { entries.count }

    /// "blue-500" → color; also accepts "bg-blue-500", "text-blue-500/50".
    static func color(forClass raw: String) -> CPColor? {
        var name = raw.lowercased()
        if let slash = name.firstIndex(of: "/") { name = String(name[..<slash]) }
        for prefix in ["bg-", "text-", "border-", "ring-", "fill-", "stroke-", "from-", "to-", "via-", "decoration-", "outline-", "accent-", "caret-", "shadow-", "divide-"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        return entries.first { $0.name == name }?.color
    }

    /// Nearest class by ΔE in Oklab, from the color as picked (not clipped).
    static func nearest(_ color: CPColor) -> CPNamedMatch {
        let lab = color.oklab
        var best = entries[0]
        var bestDistance = Double.infinity
        for entry in entries {
            let dl = entry.lab.l - lab.l, da = entry.lab.a - lab.a, db = entry.lab.b - lab.b
            let d = dl * dl + da * da + db * db
            if d < bestDistance {
                bestDistance = d
                best = entry
            }
        }
        return CPNamedMatch(name: best.name, color: best.color, distance: bestDistance.squareRoot())
    }
}

// MARK: - Coarse family name

/// A plain-words name ("Dark Blue", "Light Gray") from OKLCH, for the band
/// and VoiceOver, where a CSS keyword like "cornflowerblue" reads badly.
enum CPColorFamily {
    static func name(_ color: CPColor) -> String {
        let c = color.clamped
        let lch = c.oklch
        if lch.l > 0.985, lch.c < 0.02 { return "White" }
        if lch.l < 0.12 { return "Black" }
        let tone: String
        switch lch.l {
        case ..<0.36: tone = "Very Dark "
        case ..<0.52: tone = "Dark "
        case ..<0.78: tone = ""
        // Vivid light hues (pure yellow, lime, cyan) are just their hue.
        case _ where lch.c >= 0.14: tone = ""
        case ..<0.9: tone = "Light "
        default: tone = "Pale "
        }
        if lch.c < 0.035 {
            return lch.c < 0.012 || lch.l > 0.9 ? tone + "Gray" : tone + warmOrCool(lch.h) + " Gray"
        }
        return tone + hueName(lch, rgb: c)
    }

    private static func warmOrCool(_ h: Double) -> String {
        (h > 30 && h < 120) ? "Warm" : (h >= 180 && h < 300 ? "Cool" : "Warm")
    }

    private static func hueName(_ lch: CPOklch, rgb: CPColor) -> String {
        let h = lch.h
        switch h {
        case ..<15: return "Pink"
        case ..<40:
            // Rust and maroon-browns (Tailwind orange-900) read as brown.
            return h >= 30 && lch.l < 0.55 && lch.c < 0.13 ? "Brown" : "Red"
        case ..<70:
            // Dark, muted oranges read as brown.
            return lch.l < 0.6 && lch.c < 0.16 ? "Brown" : "Orange"
        case ..<100:
            return lch.l < 0.65 ? "Brown" : (lch.l < 0.78 ? "Amber" : "Yellow")
        case ..<115: return lch.l < 0.6 ? "Olive" : "Yellow"
        case ..<145: return "Lime"
        case ..<170: return "Green"
        case ..<195: return "Teal"
        case ..<230: return "Cyan"
        case ..<250: return "Sky Blue"
        case ..<275: return "Blue"
        case ..<295: return "Indigo"
        case ..<315: return "Purple"
        case ..<340: return "Magenta"
        default: return "Pink"
        }
    }
}
