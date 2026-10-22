import Foundation

// Data shared by the UI audit controller, window and drawer tab. The runner
// (Vendor/ui-audit/audit.mjs) streams JSON lines whose shapes are mirrored
// here; every field is optional so a newer runner never breaks decoding.

/// What the audit checks. Raw values are the runner's `--mode` values.
enum UIAuditMode: String, CaseIterable, Identifiable, Sendable {
    case ui
    case forms
    case a11y
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ui: return "UI audit"
        case .forms: return "Forms only"
        case .a11y: return "Accessibility"
        case .full: return "Full frontend"
        }
    }

    var shortLabel: String {
        switch self {
        case .ui: return "UI"
        case .forms: return "Forms"
        case .a11y: return "A11y"
        case .full: return "Full"
        }
    }

    var detail: String {
        switch self {
        case .ui: return "Layout at 1440/390, clipped and overlapping text, tap targets, images, broken links, console errors, failed requests, dead buttons."
        case .forms: return "Labels and placeholders, required markers, fills realistic test data, probes wrong-type values and validation messages."
        case .a11y: return "axe-core (WCAG 2.2 A/AA), keyboard-only navigation, visible focus, tap targets, images, form labelling."
        case .full: return "Everything: UI, forms, accessibility, keyboard, console and network."
        }
    }
}

enum UIAuditSeverity: String, CaseIterable, Comparable, Sendable {
    case critical, high, medium, low, info

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 9 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    var label: String { rawValue.capitalized }
}

/// One issue, exactly as the runner writes it to report.json.
struct UIAuditFinding: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var rule: String
    var category: String
    var severity: String
    var title: String
    var page: String
    var viewport: String?
    var selector: String?
    var locator: String?
    var evidence: String?
    var expected: String?
    var actual: String?
    var steps: [String]?
    var fix: String?
    var acceptance: [String]?
    var helpUrl: String?
    var screenshot: String?
    var alsoOn: [String]?
    var axeId: String?

    var severityLevel: UIAuditSeverity { UIAuditSeverity(rawValue: severity) ?? .medium }
    var isIssue: Bool { severityLevel != .info }
    /// "axe:color-contrast" or the runner's rule id.
    var ruleLabel: String { axeId.map { "axe:\($0)" } ?? rule }
}

struct UIAuditSummaryCounts: Codable, Sendable, Equatable {
    var total: Int?
    var issues: Int?
    var bySeverity: [String: Int]?
    var byCategory: [String: Int]?

    func count(_ severity: UIAuditSeverity) -> Int { bySeverity?[severity.rawValue] ?? 0 }
}

/// One JSON line from the runner. `type` is one of plan, state, page, step,
/// finding, page-done, log, error, done.
struct UIAuditEvent: Decodable, Sendable {
    var type: String
    var message: String?
    var level: String?
    var index: Int?
    var total: Int?
    var url: String?
    var depth: Int?
    var status: Int?
    var issues: Int?
    var counts: [String: Int]?
    var finding: UIAuditFinding?
    var state: String?
    var fatal: Bool?
    // plan
    var startURL: String?
    var modeLabel: String?
    var allowedOrigins: [String]?
    var submission: String?
    var dangerousClicks: String?
    var maxPages: Int?
    var outDir: String?
    // done
    var jsonPath: String?
    var mdPath: String?
    var htmlPath: String?
    var summary: UIAuditSummaryCounts?
    var pages: Int?
    var stopped: Bool?
    var stopReason: String?
    var durationMs: Double?

    static func decode(_ line: Data) -> UIAuditEvent? {
        try? JSONDecoder().decode(UIAuditEvent.self, from: line)
    }
}

/// The parts of report.json the app reads back (last report, fix prompt).
struct UIAuditReportFile: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        var startURL: String
        var mode: String?
        var modeLabel: String?
        var startedAt: String?
        var durationMs: Double?
        var stopped: Bool?
        var stopReason: String?
        var submitPolicy: String?
        var allowedOrigins: [String]?
        var outDir: String?
        var viewports: [Viewport]?
    }

    struct Viewport: Decodable, Sendable {
        var width: Int
        var height: Int
    }

    struct Page: Decodable, Sendable, Identifiable {
        var url: String
        var status: Int?
        var title: String?
        var issues: Int?
        var id: String { url }
    }

    var meta: Meta
    var summary: UIAuditSummaryCounts
    var pages: [Page]
    var findings: [UIAuditFinding]
}

/// A finished (or stopped) run the UI can show and act on.
struct UIAuditReport: Sendable {
    var file: UIAuditReportFile
    var jsonURL: URL
    var directory: URL { jsonURL.deletingLastPathComponent() }
    var markdownURL: URL { directory.appendingPathComponent("report.md") }
    var htmlURL: URL { directory.appendingPathComponent("report.html") }

    var issueCount: Int { file.findings.filter(\.isIssue).count }

    func screenshotURL(for finding: UIAuditFinding) -> URL? {
        guard let rel = finding.screenshot, !rel.isEmpty else { return nil }
        return directory.appendingPathComponent(rel)
    }

    /// "7 pages · 76 issues (3 critical, 18 high)"
    var oneLine: String {
        let s = file.summary
        var severe: [String] = []
        for level in [UIAuditSeverity.critical, .high] where s.count(level) > 0 {
            severe.append("\(s.count(level)) \(level.rawValue)")
        }
        let pages = file.pages.count
        var text = "\(pages) page\(pages == 1 ? "" : "s") · \(issueCount) issue\(issueCount == 1 ? "" : "s")"
        if !severe.isEmpty { text += " (\(severe.joined(separator: ", ")))" }
        return text
    }

    static func load(from url: URL) throws -> UIAuditReport {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(UIAuditReportFile.self, from: data)
        return UIAuditReport(file: file, jsonURL: url)
    }
}

/// Persistent preferences. The per-run toggles (form submission, risky
/// clicks) are deliberately not stored: they reset to off after every run.
enum UIAuditSettings {
    static let lastURLKey = "uiAudit.lastURL"
    static let modeKey = "uiAudit.mode"
    static let maxPagesKey = "uiAudit.maxPages"
    static let maxDepthKey = "uiAudit.maxDepth"
    static let extraOriginsKey = "uiAudit.extraOrigins"
    static let lastReportKey = "uiAudit.lastReportPath"
    /// Opt-in: send a compact list of findings to Groq (Clicky's key) for a
    /// summary. Off by default; the keychain is not read while it is off.
    static let useGroqKey = "uiAudit.useGroqSummaries"
    /// Developer overrides.
    static let nodePathKey = "uiAudit.nodePath"
    static let runnerDirKey = "uiAudit.runnerDir"
    static let headlessKey = "uiAudit.headless"

    private static var defaults: UserDefaults { .standard }

    static var lastURL: String {
        get { defaults.string(forKey: lastURLKey) ?? "http://localhost:3000" }
        set { defaults.set(newValue, forKey: lastURLKey) }
    }

    static var mode: UIAuditMode {
        get { UIAuditMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .full }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    static var maxPages: Int {
        get { let v = defaults.integer(forKey: maxPagesKey); return v > 0 ? min(v, 200) : 12 }
        set { defaults.set(newValue, forKey: maxPagesKey) }
    }

    static var maxDepth: Int {
        get { defaults.object(forKey: maxDepthKey) == nil ? 3 : max(0, min(defaults.integer(forKey: maxDepthKey), 10)) }
        set { defaults.set(newValue, forKey: maxDepthKey) }
    }

    static var extraOrigins: String {
        get { defaults.string(forKey: extraOriginsKey) ?? "" }
        set { defaults.set(newValue, forKey: extraOriginsKey) }
    }

    static var useGroqSummaries: Bool {
        get { defaults.bool(forKey: useGroqKey) }
        set { defaults.set(newValue, forKey: useGroqKey) }
    }

    static var headless: Bool { defaults.bool(forKey: headlessKey) }

    static var lastReportPath: String? {
        get { defaults.string(forKey: lastReportKey) }
        set { defaults.set(newValue, forKey: lastReportKey) }
    }

    /// Clicky's Groq key, only when the user opted in for audit summaries.
    static func groqKeyIfAllowed() -> String? {
        guard useGroqSummaries else { return nil }
        return ClickyKeychain.load()
    }

    /// Where runs are written: ~/Library/Application Support/SparkV/UIAudit.
    static var runsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SparkV/UIAudit", isDirectory: true)
    }
}

/// URL helpers shared by the controller and views.
enum UIAuditURL {
    /// Adds a scheme when missing (http for local hosts, https otherwise) and
    /// rejects anything that isn't http(s) with a host.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let hostPart = text.split(separator: "/").first.map(String.init) ?? text
            let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
            text = (isTestHost(host) || host.hasPrefix("192.168.") || host.hasPrefix("10.") ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Mirrors `isTestHost` in audit.mjs: hosts where forms are always
    /// submitted (this machine and local-only names). Remote hosts, staging
    /// and dev ones included, need the per-run "Allow form submission".
    static func isTestHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.first == "127", octets.allSatisfy({ Int($0) != nil }) { return true }
        return host.hasSuffix(".localhost") || host.hasSuffix(".test") || host.hasSuffix(".local")
    }

    /// Path + query for compact display ("/signup").
    static func shortPath(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { path += "?" + q }
        return path
    }
}
