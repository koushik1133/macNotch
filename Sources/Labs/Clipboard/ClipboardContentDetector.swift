import Foundation

// Smart content types for clipboard items: what a copied string *is*
// (a link, an email address, a phone number, a colour, a file path, code),
// so the stack panel, the Clipboard tab and the C menu can offer the one
// action that fits ("Open", "Compose", "Call via FaceTime", a swatch,
// "Reveal in Finder", monospaced text). Raycast and Paste do the same with
// colours and links; detection follows Apple's NSDataDetector for links and
// phone numbers plus plain regexes. Pure: no AppKit, no UI, unit-tested by
// the harness in the scratch folder.

/// An sRGB colour with alpha, all components 0...1.
struct ClipboardColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    enum Format: String, CaseIterable, Sendable {
        case hex, rgb, hsl, swiftUI
        var label: String {
            switch self {
            case .hex: "HEX"
            case .rgb: "RGB"
            case .hsl: "HSL"
            case .swiftUI: "SwiftUI"
            }
        }
    }

    private static func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }

    /// "#FF8800", or "#FF880080" with alpha.
    var hex: String {
        let rgb = String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
        return alpha < 0.999 ? rgb + String(format: "%02X", Self.byte(alpha)) : rgb
    }

    /// "rgb(255, 136, 0)" or "rgba(255, 136, 0, 0.5)".
    var rgbString: String {
        let parts = "\(Self.byte(red)), \(Self.byte(green)), \(Self.byte(blue))"
        return alpha < 0.999 ? "rgba(\(parts), \(Self.trim(alpha)))" : "rgb(\(parts))"
    }

    /// "hsl(32, 100%, 50%)" or "hsla(32, 100%, 50%, 0.5)".
    var hslString: String {
        let (h, s, l) = hsl
        let parts = "\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
        return alpha < 0.999 ? "hsla(\(parts), \(Self.trim(alpha)))" : "hsl(\(parts))"
    }

    /// "Color(red: 1, green: 0.533, blue: 0)".
    var swiftUIString: String {
        let base = "Color(red: \(Self.trim(red)), green: \(Self.trim(green)), blue: \(Self.trim(blue))"
        return alpha < 0.999 ? base + ", opacity: \(Self.trim(alpha)))" : base + ")"
    }

    func string(in format: Format) -> String {
        switch format {
        case .hex: hex
        case .rgb: rgbString
        case .hsl: hslString
        case .swiftUI: swiftUIString
        }
    }

    /// Hue in degrees 0..<360, saturation and lightness 0...1.
    var hsl: (Double, Double, Double) {
        let maxV = max(red, green, blue), minV = min(red, green, blue)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0.000_001 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if maxV == red { h = ((green - blue) / d).truncatingRemainder(dividingBy: 6) }
        else if maxV == green { h = (blue - red) / d + 2 }
        else { h = (red - green) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, min(1, s), l)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hue: Double, saturation s: Double, lightness l: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    /// Short number without trailing zeros: 1, 0.5, 0.533.
    static func trim(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

/// What a copied item is, beyond its pasteboard kind.
enum ClipboardSmartContent: Equatable, Sendable {
    /// A web (or other-scheme) link.
    case link(URL)
    case email(String)
    /// `display` as copied, `dialable` digits with an optional leading "+".
    case phone(display: String, dialable: String)
    /// The colour and the format it was copied in.
    case color(ClipboardColor, ClipboardColor.Format)
    /// An existing file or folder (tilde expanded).
    case filePath(String)
    /// Source code or a terminal command; `language` is a best guess.
    case code(language: String?)

    var symbol: String {
        switch self {
        case .link: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .color: "paintpalette"
        case .filePath: "folder"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    var label: String {
        switch self {
        case .link: "Link"
        case .email: "Email"
        case .phone: "Phone"
        case .color: "Colour"
        case .filePath: "Path"
        case .code(let language): language.map { $0 } ?? "Code"
        }
    }

    /// Shown in a monospaced font.
    var isMonospaced: Bool {
        switch self {
        case .code, .color, .filePath: true
        case .link, .email, .phone: false
        }
    }
}

/// One action for a smart item ("Open", "Call via FaceTime"…).
struct ClipboardSmartAction: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        /// Open this URL (link, mailto:, facetime-audio:, tel:).
        case open(URL)
        /// Show this path in Finder.
        case reveal(String)
        /// Put this text on the clipboard (a colour in another format).
        case copyText(String)
    }

    var title: String
    var symbol: String
    var kind: Kind
    var id: String { title }
}

enum ClipboardContentDetector {
    /// Longer strings are never treated as a single link, colour or number.
    static let maxTokenLength = 2048
    /// Code is detected in strings up to this length.
    static let maxCodeLength = 200_000

    /// Detects what `text` is. `fileExists` is injectable for tests.
    static func detect(_ text: String,
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ClipboardSmartContent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isSingleLine = !trimmed.contains(where: \.isNewline)
        if isSingleLine, trimmed.count <= maxTokenLength {
            if let (color, format) = color(trimmed) { return .color(color, format) }
            if let path = filePath(trimmed, fileExists: fileExists) { return .filePath(path) }
            if let email = email(trimmed) { return .email(email) }
            if let url = link(trimmed) { return .link(url) }
            if let phone = phone(trimmed) { return .phone(display: trimmed, dialable: phone) }
        }
        if trimmed.count <= maxCodeLength, let language = code(trimmed) { return .code(language: language) }
        return nil
    }

    /// Detects a history item: links come from the item kind, files are
    /// already files, images have no text.
    static func detect(_ item: ClipboardItem,
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ClipboardSmartContent? {
        switch item.kind {
        case .url:
            guard let text = item.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return .link(url)
        case .text, .richText:
            return item.text.flatMap { detect($0, fileExists: fileExists) }
        case .image, .file:
            return nil
        }
    }

    /// The actions offered for `content`, best first.
    static func actions(for content: ClipboardSmartContent) -> [ClipboardSmartAction] {
        switch content {
        case .link(let url):
            return [ClipboardSmartAction(title: "Open", symbol: "safari", kind: .open(url))]
        case .email(let address):
            guard let url = URL(string: "mailto:\(address)") else { return [] }
            return [ClipboardSmartAction(title: "Compose", symbol: "square.and.pencil", kind: .open(url))]
        case .phone(_, let dialable):
            var result: [ClipboardSmartAction] = []
            if let url = URL(string: "facetime-audio:\(dialable)") {
                result.append(ClipboardSmartAction(title: "Call via FaceTime", symbol: "phone.fill", kind: .open(url)))
            }
            return result
        case .color(let color, let format):
            return ClipboardColor.Format.allCases.filter { $0 != format }.map { other in
                ClipboardSmartAction(title: "Copy as \(other.label)", symbol: "eyedropper",
                                     kind: .copyText(color.string(in: other)))
            }
        case .filePath(let path):
            return [ClipboardSmartAction(title: "Reveal in Finder", symbol: "folder", kind: .reveal(path))]
        case .code:
            return []
        }
    }

    // MARK: Colours

    private static let hexDigits = Set("0123456789abcdefABCDEF")

    /// "#F80", "#FF8800", "#FF880080", "0xFF8800", "ff8800" (bare hex needs
    /// both letters and digits, so "123456" and "decade" stay text),
    /// rgb()/rgba(), hsl()/hsla().
    static func color(_ text: String) -> (ClipboardColor, ClipboardColor.Format)? {
        let s = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let lower = s.lowercased()
        if lower.hasPrefix("rgb") { return rgb(lower).map { ($0, .rgb) } }
        if lower.hasPrefix("hsl") { return hslColor(lower).map { ($0, .hsl) } }

        var digits = Substring(s)
        var explicit = false
        if digits.hasPrefix("#") { digits = digits.dropFirst(); explicit = true }
        else if lower.hasPrefix("0x") { digits = digits.dropFirst(2); explicit = true }
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(hexDigits.contains) else { return nil }
        if !explicit {
            guard digits.count == 6 || digits.count == 8,
                  digits.contains(where: \.isLetter), digits.contains(where: \.isNumber) else { return nil }
        }
        var expanded = String(digits)
        if expanded.count <= 4 { expanded = expanded.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        let r = Double((value >> (16 + shift)) & 0xFF) / 255
        let g = Double((value >> (8 + shift)) & 0xFF) / 255
        let b = Double((value >> shift) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return (ClipboardColor(red: r, green: g, blue: b, alpha: a), .hex)
    }

    /// Numbers inside "name(...)", separated by commas, spaces or "/".
    private static func arguments(_ text: String, names: [String]) -> [String]? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")"),
              names.contains(String(text[..<open]).trimmingCharacters(in: .whitespaces)) else { return nil }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
        return parts.isEmpty ? nil : parts
    }

    /// "50%" -> 0.5 of `scale`, "128" -> 128 / scale (when `scale` given).
    private static func component(_ raw: String, scale: Double) -> Double? {
        if raw.hasSuffix("%") {
            guard let value = Double(raw.dropLast()), (0...100).contains(value) else { return nil }
            return value / 100
        }
        guard let value = Double(raw), value >= 0, value <= scale else { return nil }
        return value / scale
    }

    private static func rgb(_ text: String) -> ClipboardColor? {
        guard let parts = arguments(text, names: ["rgb", "rgba"]), parts.count == 3 || parts.count == 4,
              let r = component(parts[0], scale: 255), let g = component(parts[1], scale: 255),
              let b = component(parts[2], scale: 255) else { return nil }
        let a = parts.count == 4 ? component(parts[3], scale: 1) : 1
        guard let a else { return nil }
        return ClipboardColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func hslColor(_ text: String) -> ClipboardColor? {
        guard let parts = arguments(text, names: ["hsl", "hsla"]), parts.count == 3 || parts.count == 4,
              let hue = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
              parts[1].hasSuffix("%"), parts[2].hasSuffix("%"),
              let s = component(parts[1], scale: 100), let l = component(parts[2], scale: 100) else { return nil }
        let a = parts.count == 4 ? component(parts[3], scale: 1) : 1
        guard let a else { return nil }
        return ClipboardColor(hue: hue, saturation: s, lightness: l, alpha: a)
    }

    // MARK: Links, emails, phones

    // NSDataDetector / NSRegularExpression are immutable and thread-safe.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let phoneDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// The NSDataDetector match of `type` that covers the whole string.
    private static func wholeMatch(_ text: String, _ detector: NSDataDetector?) -> NSTextCheckingResult? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        guard matches.count == 1, let match = matches.first, match.range == range else { return nil }
        return match
    }

    private static let emailPattern = try? NSRegularExpression(
        pattern: #"^(?:mailto:)?([A-Z0-9._%+'-]+@[A-Z0-9.-]+\.[A-Z]{2,63})$"#, options: [.caseInsensitive])

    static func email(_ text: String) -> String? {
        guard !text.contains(" "), let regex = emailPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        let address = String(text[captured])
        guard !address.contains(".."), !address.hasPrefix(".") else { return nil }
        return address
    }

    /// A single link: http(s) and other schemes as copied, or a bare
    /// "www.example.com" / "example.com/path" (NSDataDetector adds http://).
    static func link(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        if let url = ClipboardCapture.webLink(text) { return url }
        guard let match = wholeMatch(text, linkDetector), let url = match.url else { return nil }
        // mailto: is an email; file: is a path.
        guard let scheme = url.scheme?.lowercased(), scheme != "mailto", scheme != "file" else { return nil }
        // A bare word with a dot ("file.txt", "v1.2") isn't worth an Open button.
        if !text.contains("://"), !text.lowercased().hasPrefix("www."), !text.contains("/") {
            let tld = text.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
            guard commonTLDs.contains(tld) else { return nil }
        }
        return url
    }

    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "co", "me", "edu", "gov", "in", "uk", "de", "fr", "jp",
        "us", "ca", "au", "info", "xyz", "so", "gg", "tv", "ly", "sh", "to", "fm", "page", "site", "tech",
    ]

    /// Dialable form ("+14155550123") of a phone number that is the whole
    /// string: 7 to 15 digits (E.164), only phone punctuation around them.
    static func phone(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn: "0123456789+-(). \u{00A0}")
        guard text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let digits = text.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        // A plain run of digits needs a "+" or separators to count (otherwise
        // it's an order number, a timestamp, a PIN…).
        let hasPlus = text.hasPrefix("+")
        let hasSeparators = text.contains(where: { "-(). ".contains($0) })
        guard hasPlus || hasSeparators else { return nil }
        // Dates and decimals: "2026.10.21", "3.14159".
        if text.filter({ $0 == "." }).count >= 1, !text.contains(where: { "-() +".contains($0) }) { return nil }
        guard wholeMatch(text, phoneDetector) != nil else { return nil }
        return (hasPlus ? "+" : "") + digits
    }

    // MARK: Paths

    /// An absolute or ~ path (or a file:// URL) to something that exists.
    static func filePath(_ text: String, fileExists: (String) -> Bool) -> String? {
        var path = text
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count > 2 { path = String(path.dropFirst().dropLast()) }
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        }
        if path == "~" || path.hasPrefix("~/") { path = NSString(string: path).expandingTildeInPath }
        guard path.hasPrefix("/"), path.count > 1, !path.contains("://") else { return nil }
        // Shell-escaped spaces ("My\ File.txt").
        let unescaped = path.replacingOccurrences(of: "\\ ", with: " ")
        if fileExists(unescaped) { return unescaped }
        return fileExists(path) ? path : nil
    }

    // MARK: Code

    private static let codeKeywords: [(String, String)] = [
        ("func ", "Swift"), ("let ", "Swift"), ("var ", "Swift"), ("import SwiftUI", "Swift"), ("guard ", "Swift"),
        ("const ", "JavaScript"), ("function ", "JavaScript"), ("=> ", "JavaScript"), ("console.log", "JavaScript"),
        ("export ", "JavaScript"), ("interface ", "TypeScript"),
        ("def ", "Python"), ("import ", "Python"), ("elif ", "Python"), ("print(", "Python"), ("self.", "Python"),
        ("#include", "C"), ("int main", "C"), ("std::", "C++"), ("public class ", "Java"), ("fn ", "Rust"),
        ("SELECT ", "SQL"), ("FROM ", "SQL"), ("WHERE ", "SQL"), ("INSERT INTO", "SQL"),
        ("package main", "Go"), ("func main()", "Go"),
        ("<div", "HTML"), ("</", "HTML"),
    ]

    private static let shellPrefixes = [
        "$ ", "sudo ", "npm ", "npx ", "yarn ", "pnpm ", "brew ", "git ", "cd ", "ls ", "curl ", "pip ", "pip3 ",
        "python3 ", "swift ", "xcrun ", "docker ", "kubectl ", "make ", "export ", "chmod ", "mkdir ", "rm ", "cargo ",
    ]

    /// A language guess ("Swift", "JSON", "Shell"…, "Code" when unsure) for
    /// text that reads as code, or nil for prose.
    static func code(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        // JSON objects and arrays.
        if let first = trimmed.first, first == "{" || first == "[", trimmed.count >= 2,
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return "JSON"
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        if lines.count == 1 {
            let line = lines[0]
            if shellPrefixes.contains(where: { line.hasPrefix($0) }), line.count < 400,
               line.contains(where: { "-/.|&=$".contains($0) }) || line.split(separator: " ").count >= 2 {
                // "git commit -m" is a command; "cd into the folder" is prose.
                let words = line.split(separator: " ")
                let proseWords = words.filter { $0.count > 2 && $0.allSatisfy(\.isLetter) && $0.first?.isLowercase == true }
                if proseWords.count < max(4, words.count - 1) || line.contains(" -") || line.contains("|") { return "Shell" }
            }
        }
        // Score structural signals.
        var score = 0
        var votes: [String: Int] = [:]
        for (keyword, language) in codeKeywords where trimmed.contains(keyword) {
            votes[language, default: 0] += 1
        }
        let symbols = trimmed.filter { "{}();=<>[]".contains($0) }.count
        let density = Double(symbols) / Double(max(trimmed.count, 1))
        if density > 0.04 { score += 2 } else if density > 0.02 { score += 1 }
        let codeLineEnds = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix("{") || t.hasSuffix("}") || t.hasSuffix(";") || t.hasSuffix(":") || t.hasSuffix(")")
        }.count
        if lines.count > 1, Double(codeLineEnds) / Double(lines.count) >= 0.4 { score += 2 }
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        if lines.count > 2, indented >= 1 { score += 1 }
        let keywordHits = votes.values.reduce(0, +)
        score += min(keywordHits, 3)
        if trimmed.contains("->") || trimmed.contains("==") || trimmed.contains("!=") || trimmed.contains("&&") { score += 1 }
        // Prose signals: sentences.
        let sentenceEnds = trimmed.components(separatedBy: ". ").count - 1
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        if sentenceEnds >= 2, density < 0.03 { score -= 3 }
        if words > 8, density < 0.01 { score -= 2 }
        guard score >= 4 else { return nil }
        if votes.keys.contains("SQL"), trimmed.uppercased().contains("SELECT"), trimmed.uppercased().contains("FROM") { return "SQL" }
        let best = votes.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }
        return best?.key ?? "Code"
    }
}
