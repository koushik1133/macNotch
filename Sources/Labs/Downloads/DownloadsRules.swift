import Foundation

// Hazel-style sorting rules: each rule has conditions on the file (kind,
// extension, name, source domain, size, browser), matched all/any, and a
// destination. Rules run top to bottom and the first match wins (Hazel stops
// at the first rule that moves the file). Nothing moves on its own unless the
// user ticks "Sort automatically" on that rule.

struct DownloadCondition: Identifiable, Codable, Equatable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable, Identifiable {
        case kind, fileExtension, name, sourceDomain, sourceURL, sizeMB, browser
        var id: String { rawValue }

        var title: String {
            switch self {
            case .kind: "Kind"
            case .fileExtension: "Extension"
            case .name: "Name"
            case .sourceDomain: "Source domain"
            case .sourceURL: "Source URL"
            case .sizeMB: "Size (MB)"
            case .browser: "Downloaded with"
            }
        }

        var operators: [Op] {
            switch self {
            case .kind, .browser: [.is, .isNot]
            case .fileExtension: [.is, .isNot]
            case .name, .sourceURL: [.contains, .doesNotContain, .beginsWith, .endsWith, .is]
            case .sourceDomain: [.is, .isNot, .contains]
            case .sizeMB: [.greaterThan, .lessThan]
            }
        }

        /// Placeholder for the value field.
        var hint: String {
            switch self {
            case .kind: ""
            case .fileExtension: "pdf, docx"
            case .name: "invoice"
            case .sourceDomain: "github.com"
            case .sourceURL: "/releases/"
            case .sizeMB: "100"
            case .browser: ""
            }
        }
    }

    enum Op: String, Codable, CaseIterable, Sendable, Identifiable {
        case `is`, isNot, contains, doesNotContain, beginsWith, endsWith, greaterThan, lessThan
        var id: String { rawValue }

        var title: String {
            switch self {
            case .is: "is"
            case .isNot: "is not"
            case .contains: "contains"
            case .doesNotContain: "does not contain"
            case .beginsWith: "begins with"
            case .endsWith: "ends with"
            case .greaterThan: "is greater than"
            case .lessThan: "is less than"
            }
        }
    }

    var id = UUID()
    var field: Field
    var op: Op
    var value: String

    init(id: UUID = UUID(), field: Field, op: Op, value: String) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }

    /// Keeps `op` and `value` valid after the field changes.
    mutating func normalize() {
        if !field.operators.contains(op) { op = field.operators[0] }
        switch field {
        case .kind where DownloadCategory(rawValue: value) == nil: value = DownloadCategory.document.rawValue
        case .browser where DownloadBrowser(rawValue: value) == nil: value = DownloadBrowser.safari.rawValue
        default: break
        }
    }

    /// "Kind is Image", "Source domain is github.com".
    var summary: String {
        let shown: String
        switch field {
        case .kind: shown = DownloadCategory(rawValue: value)?.singular ?? value
        case .browser: shown = DownloadBrowser(rawValue: value)?.displayName ?? value
        default: shown = value
        }
        return "\(field.title) \(op.title) \(shown)"
    }
}

struct DownloadRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var isEnabled = true
    /// Move matching downloads as soon as they finish (off: just suggest).
    var sortsAutomatically = false
    /// All conditions must match (Hazel "all"), else any.
    var matchAll = true
    var conditions: [DownloadCondition]
    var destination: DownloadDestination

    init(id: UUID = UUID(), name: String, isEnabled: Bool = true, sortsAutomatically: Bool = false,
         matchAll: Bool = true, conditions: [DownloadCondition], destination: DownloadDestination) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sortsAutomatically = sortsAutomatically
        self.matchAll = matchAll
        self.conditions = conditions
        self.destination = destination
    }
}

/// The facts rules look at, taken from a finished download.
struct DownloadRuleSubject: Sendable, Equatable {
    var name: String
    var fileExtension: String
    var category: DownloadCategory
    var sourceDomain: String?
    var sourceURL: String?
    var sizeBytes: Int64
    var browser: DownloadBrowser

    init(item: DownloadItem) {
        name = item.name
        fileExtension = item.fileExtension
        category = item.category
        sourceDomain = item.sourceDomain
        sourceURL = item.sourceURL
        sizeBytes = item.totalBytes ?? item.bytesReceived
        browser = item.browser
    }
}

enum DownloadRuleEngine {
    static func matches(_ condition: DownloadCondition, _ subject: DownloadRuleSubject) -> Bool {
        let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        switch condition.field {
        case .kind:
            let equal = subject.category.rawValue == value
            return condition.op == .isNot ? !equal : equal
        case .browser:
            let equal = subject.browser.rawValue == value
            return condition.op == .isNot ? !equal : equal
        case .fileExtension:
            let list = lowered.split(whereSeparator: { $0 == "," || $0 == " " })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                .filter { !$0.isEmpty }
            let inList = list.contains(subject.fileExtension)
            return condition.op == .isNot ? !inList : inList
        case .name:
            return text(subject.name.lowercased(), condition.op, lowered)
        case .sourceURL:
            guard let url = subject.sourceURL?.lowercased() else { return condition.op == .doesNotContain }
            return text(url, condition.op, lowered)
        case .sourceDomain:
            guard let domain = subject.sourceDomain?.lowercased() else { return condition.op == .isNot }
            let target = lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
            switch condition.op {
            case .is: return domain == target || domain.hasSuffix("." + target)
            case .isNot: return !(domain == target || domain.hasSuffix("." + target))
            default: return text(domain, condition.op, target)
            }
        case .sizeMB:
            guard let limit = Double(value.replacingOccurrences(of: ",", with: ".")) else { return false }
            let mb = Double(subject.sizeBytes) / 1_000_000
            return condition.op == .lessThan ? mb < limit : mb > limit
        }
    }

    private static func text(_ haystack: String, _ op: DownloadCondition.Op, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        switch op {
        case .is: return haystack == needle
        case .isNot: return haystack != needle
        case .contains: return haystack.contains(needle)
        case .doesNotContain: return !haystack.contains(needle)
        case .beginsWith: return haystack.hasPrefix(needle)
        case .endsWith: return haystack.hasSuffix(needle)
        case .greaterThan, .lessThan: return false
        }
    }

    static func matches(_ rule: DownloadRule, _ subject: DownloadRuleSubject) -> Bool {
        guard rule.isEnabled, !rule.conditions.isEmpty else { return false }
        return rule.matchAll
            ? rule.conditions.allSatisfy { matches($0, subject) }
            : rule.conditions.contains { matches($0, subject) }
    }

    /// First enabled rule that matches, top to bottom.
    static func firstMatch(in rules: [DownloadRule], for subject: DownloadRuleSubject) -> DownloadRule? {
        rules.first { matches($0, subject) }
    }

    /// Default rules: one per kind into a subfolder of Downloads (Hazel's
    /// classic "sort Downloads by kind" recipe), plus a disabled example of a
    /// name rule. None sorts automatically.
    static func defaultRules() -> [DownloadRule] {
        func kind(_ category: DownloadCategory) -> DownloadRule {
            DownloadRule(name: category.title,
                         conditions: [DownloadCondition(field: .kind, op: .is, value: category.rawValue)],
                         destination: .folder("~/Downloads/\(category.title)"))
        }
        return [
            DownloadRule(name: "Invoices and receipts", isEnabled: false, matchAll: false,
                         conditions: [
                             DownloadCondition(field: .name, op: .contains, value: "invoice"),
                             DownloadCondition(field: .name, op: .contains, value: "receipt"),
                         ],
                         destination: .folder("~/Documents/Invoices")),
            kind(.image), kind(.document), kind(.video), kind(.audio),
            kind(.archive), kind(.installer), kind(.code),
        ]
    }
}

/// Persists the rules as JSON (Application Support/SparkV/Downloads/rules.json).
@MainActor
final class DownloadRuleStore: ObservableObject {
    @Published var rules: [DownloadRule] {
        didSet { if rules != oldValue { save() } }
    }

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DownloadRule].self, from: data) {
            rules = saved
        } else {
            rules = DownloadRuleEngine.defaultRules()
        }
    }

    func firstMatch(for item: DownloadItem) -> DownloadRule? {
        DownloadRuleEngine.firstMatch(in: rules, for: DownloadRuleSubject(item: item))
    }

    @discardableResult
    func addRule(after id: UUID? = nil) -> DownloadRule {
        let rule = DownloadRule(name: "New rule",
                                conditions: [DownloadCondition(field: .sourceDomain, op: .is, value: "")],
                                destination: .folder("~/Downloads"))
        if let id, let index = rules.firstIndex(where: { $0.id == id }) {
            rules.insert(rule, at: index + 1)
        } else {
            rules.append(rule)
        }
        return rule
    }

    @discardableResult
    func duplicate(_ id: UUID) -> DownloadRule? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = rules[index]
        copy.id = UUID()
        copy.name += " copy"
        copy.sortsAutomatically = false
        copy.conditions = copy.conditions.map { DownloadCondition(field: $0.field, op: $0.op, value: $0.value) }
        rules.insert(copy, at: index + 1)
        return copy
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
    }

    func resetToDefaults() {
        rules = DownloadRuleEngine.defaultRules()
    }

    /// A rule that sends files from `domain` (or of this kind) to `destination`,
    /// created from the drawer's "Always sort like this".
    @discardableResult
    func addRule(like item: DownloadItem, destination: DownloadDestination) -> DownloadRule {
        let condition: DownloadCondition = if let domain = item.sourceDomain {
            DownloadCondition(field: .sourceDomain, op: .is, value: domain)
        } else {
            DownloadCondition(field: .kind, op: .is, value: item.category.rawValue)
        }
        let name = item.sourceDomain.map { "From \($0)" } ?? item.category.title
        let rule = DownloadRule(name: "\(name) → \(destination.displayName)", conditions: [condition], destination: destination)
        // Specific rules go above the generic kind rules.
        rules.insert(rule, at: 0)
        return rule
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.log("Downloads: couldn't save rules (\(error.localizedDescription))")
        }
    }
}
