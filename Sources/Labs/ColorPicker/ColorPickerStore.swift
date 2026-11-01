import Foundation

/// One pick in the history.
struct CPHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Extended sRGB, so a P3 pick keeps its out-of-sRGB components.
    var color: CPColor
    var date: Date
    /// The color space NSColorSampler reported (e.g. "Color LCD"), if any.
    var sourceSpace: String?
    /// The app in front when the pick started (never a screenshot or a window title).
    var appName: String?
}

/// A named, ordered set of colors.
struct CPPalette: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var colors: [CPColor] = []
}

/// The contrast checker's two slots.
struct CPContrastPair: Codable, Equatable, Sendable {
    var foreground: CPColor
    var background: CPColor

    static let initial = CPContrastPair(foreground: CPColor(hex: 0x3B82F6), background: .white)
}

/// Pure history and palette rules (no I/O), so they can be tested alone.
enum CPCollections {
    static let historyLimit = 30
    static let paletteLimit = 24
    static let colorsPerPaletteLimit = 64

    /// Newest first; a color already in the list (same 8-bit sRGB hex and
    /// gamut, so a P3 pick that clips to the same hex stays distinct) moves
    /// to the front instead of being listed twice.
    static func inserting(_ entry: CPHistoryEntry, into history: [CPHistoryEntry], limit: Int = historyLimit) -> [CPHistoryEntry] {
        var list = history.filter { !sameColor($0.color, entry.color) }
        list.insert(entry, at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        return list
    }

    /// Undo: puts removed entries back by date (the list is newest first),
    /// skipping any whose color is listed again by now, so picks made since
    /// stay where they are; keeps the newest `limit`.
    static func restoring(_ removed: [CPHistoryEntry], into history: [CPHistoryEntry], limit: Int = historyLimit) -> [CPHistoryEntry] {
        var list = history
        for entry in removed where !list.contains(where: { $0.id == entry.id || sameColor($0.color, entry.color) }) {
            let index = list.firstIndex(where: { $0.date < entry.date }) ?? list.count
            list.insert(entry, at: index)
        }
        if list.count > limit { list.removeLast(list.count - limit) }
        return list
    }

    static func sameColor(_ a: CPColor, _ b: CPColor) -> Bool {
        a.hexValue == b.hexValue && a.isInSRGBGamut == b.isInSRGBGamut && (a.isInSRGBGamut || a.deltaE(b) < 0.002)
    }

    /// "Palette", "Palette 2", … not already taken.
    static func uniqueName(_ base: String, existing: [CPPalette]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Palette" : trimmed
        let taken = Set(existing.map { $0.name.lowercased() })
        if !taken.contains(root.lowercased()) { return root }
        var n = 2
        while taken.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }

    static func adding(_ color: CPColor, to palette: CPPalette) -> CPPalette {
        var copy = palette
        guard !copy.colors.contains(where: { sameColor($0, color) }), copy.colors.count < colorsPerPaletteLimit else { return copy }
        copy.colors.append(color)
        return copy
    }
}

/// Exports a palette as code.
enum CPPaletteExport: String, CaseIterable, Identifiable, Sendable {
    case css, tailwind, json, swift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .css: "CSS Variables"
        case .tailwind: "Tailwind theme.colors"
        case .json: "JSON"
        case .swift: "Swift extension Color"
        }
    }

    func text(for palette: CPPalette) -> String {
        let slug = Self.slug(palette.name)
        let names = Self.colorNames(palette)
        switch self {
        case .css:
            let lines = zip(names, palette.colors).map { name, c in "  --\(slug)-\(name): \(CPFormatter.string(c, .hex, options: CPFormatOptions(lowercaseHex: true)));" }
            return ":root {\n" + lines.joined(separator: "\n") + "\n}"
        case .tailwind:
            let lines = zip(names, palette.colors).map { name, c in "    '\(name)': '\(CPFormatter.string(c, .hex, options: CPFormatOptions(lowercaseHex: true)))'," }
            return "colors: {\n  '\(slug)': {\n" + lines.joined(separator: "\n") + "\n  },\n}"
        case .json:
            let items = zip(names, palette.colors).map { name, c in "    { \"name\": \"\(name)\", \"hex\": \"\(c.hexString)\" }" }
            return "{\n  \"name\": \"\(Self.jsonEscaped(palette.name))\",\n  \"colors\": [\n" + items.joined(separator: ",\n") + "\n  ]\n}"
        case .swift:
            let ident = Self.camel(palette.name)
            let lines = zip(names, palette.colors).map { name, c in
                "    static let \(ident)\(Self.identifierSuffix(name)) = \(CPFormatter.string(c, .swiftUI))"
            }
            return "import SwiftUI\n\nextension Color {\n" + lines.joined(separator: "\n") + "\n}"
        }
    }

    /// Names for the colors: their Tailwind-ish step when the palette is a
    /// scale, otherwise "1", "2", …
    static func colorNames(_ palette: CPPalette) -> [String] {
        palette.colors.indices.map { "\($0 + 1)" }
    }

    static func slug(_ s: String) -> String {
        let allowed = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "palette" : collapsed
    }

    static func camel(_ s: String) -> String {
        let parts = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = parts.first else { return "palette" }
        var result = first.lowercased() + parts.dropFirst().map { $0.lowercased().capitalizedFirst }.joined()
        if let c = result.first, c.isNumber { result = "c" + result }
        return result
    }

    /// "1" → "1", "dark blue" → "DarkBlue": appended to an identifier, so no prefix.
    static func identifierSuffix(_ s: String) -> String {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased().capitalizedFirst }.joined()
    }

    static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension String {
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// UserDefaults persistence under `ColorPicker.*`.
struct CPDefaults {
    enum Keys {
        static let history = "ColorPicker.history"
        static let palettes = "ColorPicker.palettes"
        static let selectedPalette = "ColorPicker.selectedPalette"
        static let defaultFormat = "ColorPicker.defaultFormat"
        static let options = "ColorPicker.formatOptions"
        static let contrast = "ColorPicker.contrast"
        static let shortcut = "ColorPicker.shortcut"
        static let hotkeyEnabled = "ColorPicker.hotkeyEnabled"
        static let section = "ColorPicker.section"
        static let rememberApp = "ColorPicker.rememberApp"
        /// Set after the user reset a stuck pick: later picks start the loupe
        /// with SparkV active (see `CPSystemSampler`).
        static let compatibilityStart = "ColorPicker.needsActivationWorkaround"
    }

    let defaults: UserDefaults
    /// Where a failed save is reported (the controller passes AppLog).
    var report: (String) -> Void = { _ in }

    func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            report("Color Picker: couldn't read \(key): \(error)")
            return nil
        }
    }

    /// False (and reported) when the value can't be encoded; the previous
    /// saved value is kept.
    @discardableResult
    func save<T: Encodable>(_ value: T, _ key: String) -> Bool {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
            return true
        } catch {
            report("Color Picker: couldn't save \(key): \(error)")
            return false
        }
    }
}
