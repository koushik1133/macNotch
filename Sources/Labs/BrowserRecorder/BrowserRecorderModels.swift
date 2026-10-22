import Foundation

// MARK: - JSON passthrough

/// Arbitrary JSON (the element fingerprint the runner records), kept as-is
/// so the Swift side round-trips it without knowing its shape.
enum BRJSON: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: BRJSON])
    case array([BRJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BRJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BRJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> BRJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

// MARK: - Flow model (mirrors Vendor/browser-recorder/PROTOCOL.md, schema 1)

/// One way to find the step's element, tried in order during replay.
struct BRSelector: Codable, Equatable, Hashable, Sendable {
    /// testid | role | label | placeholder | text | alt | title | css | xpath
    var kind: String
    var role: String?
    var name: String?
    var text: String?
    var value: String?
    var attr: String?

    var summary: String {
        switch kind {
        case "role": "\(role ?? "?") “\(name ?? "")”"
        case "testid": "\(attr ?? "data-testid")=\(value ?? "")"
        case "css": value ?? ""
        case "xpath": value ?? ""
        default: "\(kind) “\(text ?? "")”"
        }
    }
}

struct BRSelectOption: Codable, Equatable, Hashable, Sendable {
    var value: String
    var label: String
}

enum BRStepKind: String, CaseIterable, Sendable {
    case navigate, click, dblclick, hover, fill, press, select, check, uncheck, upload, scroll
    case waitFor, waitText, waitURL, delay, comment

    var label: String {
        switch self {
        case .navigate: "Open page"
        case .click: "Click"
        case .dblclick: "Double-click"
        case .hover: "Hover"
        case .fill: "Type"
        case .press: "Press key"
        case .select: "Select"
        case .check: "Check"
        case .uncheck: "Uncheck"
        case .upload: "Upload"
        case .scroll: "Scroll"
        case .waitFor: "Wait for element"
        case .waitText: "Wait for text"
        case .waitURL: "Wait for URL"
        case .delay: "Delay"
        case .comment: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .navigate: "globe"
        case .click, .dblclick: "cursorarrow.click"
        case .hover: "cursorarrow"
        case .fill: "character.cursor.ibeam"
        case .press: "keyboard"
        case .select: "list.bullet"
        case .check: "checkmark.square"
        case .uncheck: "square"
        case .upload: "arrow.up.doc"
        case .scroll: "arrow.up.and.down"
        case .waitFor: "eye"
        case .waitText: "text.magnifyingglass"
        case .waitURL: "link"
        case .delay: "hourglass"
        case .comment: "text.bubble"
        }
    }

    /// Group used to color graph cards (Automa-style categories).
    var group: BRStepGroup {
        switch self {
        case .navigate: .browser
        case .click, .dblclick, .hover, .press, .scroll: .interaction
        case .fill, .select, .check, .uncheck, .upload: .forms
        case .waitFor, .waitText, .waitURL, .delay: .control
        case .comment: .note
        }
    }
}

enum BRStepGroup: Sendable { case browser, interaction, forms, control, note }

struct BRStep: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    /// Raw type string; unknown future types survive a round trip.
    var type: String
    var title: String?
    var pageIndex: Int?
    var selectors: [BRSelector]?
    var fingerprint: BRJSON?
    var value: String?
    var masked: Bool?
    /// Target of a `navigate` step.
    var url: String?
    /// Origin + path of the page the step happened on (informational).
    var pageURL: String?
    var key: String?
    var ms: Double?
    var x: Double?
    var y: Double?
    var checked: Bool?
    var options: [BRSelectOption]?
    var fileNames: [String]?
    var timeout: Double?
    var button: Int?
    var modifiers: [String]?
    var disabled: Bool?
    var optional: Bool?
    var t: Double?

    init(id: String = UUID().uuidString, type: BRStepKind, title: String? = nil) {
        self.id = id
        self.type = type.rawValue
        self.title = title
    }

    var kind: BRStepKind? { BRStepKind(rawValue: type) }
    var isDisabled: Bool { disabled ?? false }
    var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? kind?.label ?? type }

    /// One-line detail under the title.
    var detail: String {
        switch kind {
        case .navigate: return url ?? ""
        case .fill: return masked == true ? "•••••• \(value ?? "")" : (value ?? "")
        case .press: return key ?? "Enter"
        case .select: return (options ?? []).map(\.label).joined(separator: ", ")
        case .upload: return value ?? (fileNames ?? []).joined(separator: ", ")
        case .scroll: return "y = \(Int(y ?? 0))"
        case .delay: return String(format: "%.1f s", (ms ?? 1000) / 1000)
        case .waitText, .waitURL, .comment: return value ?? ""
        default: return selectors?.first?.summary ?? ""
        }
    }

    /// Fields where `{{variables}}` are substituted.
    var templatedFields: [String] {
        var out: [String] = []
        if let value { out.append(value) }
        if let url { out.append(url) }
        for option in options ?? [] { out.append(option.value); out.append(option.label) }
        return out
    }

    static func delay(seconds: Double) -> BRStep {
        var step = BRStep(type: .delay, title: String(format: "Delay %.1f s", seconds))
        step.ms = seconds * 1000
        return step
    }

    static func waitText(_ text: String) -> BRStep {
        var step = BRStep(type: .waitText, title: "Wait for “\(text)”")
        step.value = text
        step.timeout = 15000
        return step
    }

    static func waitURL(_ fragment: String) -> BRStep {
        var step = BRStep(type: .waitURL, title: "Wait for URL containing “\(fragment)”")
        step.value = fragment
        step.timeout = 15000
        return step
    }

    /// Waits for the same element another step targets.
    static func waitFor(targetOf other: BRStep) -> BRStep {
        var step = BRStep(type: .waitFor, title: "Wait for \(other.selectors?.first?.summary ?? "element")")
        step.selectors = other.selectors
        step.fingerprint = other.fingerprint
        step.pageIndex = other.pageIndex
        step.timeout = 15000
        return step
    }
}

struct BRFlow: Codable, Identifiable, Equatable, Hashable, Sendable {
    var schema: Int = 1
    var id: String
    var name: String
    /// Milliseconds since 1970 (what the runner writes).
    var createdAt: Double
    var updatedAt: Double
    var startURL: String?
    /// Always "manual": flows never run on their own.
    var trigger: String?
    /// Remembered values for non-secret variables.
    var defaults: [String: String]?
    var steps: [BRStep]

    init(id: String = UUID().uuidString, name: String, steps: [BRStep] = []) {
        let now = Date().timeIntervalSince1970 * 1000
        self.id = id
        self.name = name
        self.createdAt = now
        self.updatedAt = now
        self.trigger = "manual"
        self.steps = steps
    }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    /// `{{name}}` placeholders in enabled steps, in first-use order.
    var variables: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for step in steps where !step.isDisabled {
            for field in step.templatedFields {
                for name in BRTemplate.names(in: field) where seen.insert(name).inserted {
                    out.append(name)
                }
            }
        }
        return out
    }

    /// Purchase / payment / delete words found anywhere a replay would act on.
    var riskyWords: [String] {
        var found = Set<String>()
        func scan(_ text: String?) {
            guard let text else { return }
            for word in BRSafety.riskyWords(in: text) { found.insert(word) }
        }
        scan(name)
        for step in steps where !step.isDisabled {
            scan(step.title)
            scan(step.url)
            scan(step.value)
            for selector in step.selectors ?? [] {
                scan(selector.name)
                scan(selector.text)
                scan(selector.value)
            }
            scan(step.fingerprint?["name"]?.stringValue)
            scan(step.fingerprint?["text"]?.stringValue)
        }
        return found.sorted()
    }
}

// MARK: - Templates, safety

enum BRTemplate {
    /// "1 step", "3 steps".
    static func stepCount(_ n: Int) -> String { n == 1 ? "1 step" : "\(n) steps" }

    static func names(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([\w.-]+)\s*\}\}"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Variables whose values are never saved to disk (asked at replay time).
    static func isSecret(_ name: String) -> Bool {
        name.range(of: #"pass|pwd|secret|token|otp|cvv|cvc|card|pin|ssn|key"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A variable name from a step title such as `Type into “Email address”`.
    static func suggestedName(for step: BRStep) -> String {
        let source = step.selectors?.first(where: { $0.kind == "label" || $0.kind == "placeholder" })?.text
            ?? step.selectors?.first?.name
            ?? step.displayTitle
        let words = source.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["type", "into", "the", "a", "your"].contains($0) }
        let name = words.prefix(3).joined(separator: "_")
        return name.isEmpty ? "value" : name
    }
}

enum BRSafety {
    /// Same word list as `RISKY` in runner.mjs (the runner checks again).
    static let riskyPattern = #"\b(buy|purchase|order|checkout|check[\s-]?out|pay|payment|place[\s-]?order|subscribe|donate|transfer|send[\s-]?money|wire|delete|remove|destroy|erase|wipe|unsubscribe|cancel[\s-]?(account|subscription)|close[\s-]?account)\b"#

    static func riskyWords(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: riskyPattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { text[$0].lowercased() }
        }
    }
}

/// Minimal RFC 4180 reader, used only to show the CSV's columns and row count
/// before a data replay (the runner parses the file itself).
enum BRCSV {
    static func header(of url: URL) -> (columns: [String], rows: Int)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let rows = parse(text)
        guard let first = rows.first else { return nil }
        return (first.map { $0.trimmingCharacters(in: .whitespaces) }, max(0, rows.count - 1))
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.replacingOccurrences(of: "\u{FEFF}", with: "")).makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }
}

// MARK: - Store

/// Flows as JSON files in ~/Library/Application Support/SparkV/Flows/<id>.json.
/// (Unrelated to `FlowStore`, which keeps dictation history.)
@MainActor
final class BrowserFlowStore {
    nonisolated static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV", isDirectory: true)
    }

    nonisolated static var defaultDirectory: URL {
        baseDirectory.appendingPathComponent("Flows", isDirectory: true)
    }

    let directory: URL

    init(directory: URL = BrowserFlowStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "_", options: .regularExpression)
        return directory.appendingPathComponent("\(safe).json")
    }

    func loadAll() -> [BRFlow] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> BRFlow? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                do {
                    return try decoder.decode(BRFlow.self, from: data)
                } catch {
                    AppLog.log("BrowserRecorder: skipping unreadable flow \(file.lastPathComponent): \(error)")
                    return nil
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Writes atomically. Secret variables' remembered values are stripped first.
    @discardableResult
    func save(_ flow: BRFlow) -> Bool {
        var flow = flow
        flow.defaults = flow.defaults?.filter { !BRTemplate.isSecret($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(flow)
            try data.write(to: url(for: flow.id), options: .atomic)
            return true
        } catch {
            AppLog.log("BrowserRecorder: could not save flow \(flow.id): \(error)")
            return false
        }
    }

    /// Moves the flow file to the Trash (recoverable).
    func delete(id: String) {
        let file = url(for: id)
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } catch {
            AppLog.log("BrowserRecorder: could not trash \(file.lastPathComponent): \(error)")
        }
    }
}
