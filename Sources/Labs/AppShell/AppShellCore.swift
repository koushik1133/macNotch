import Foundation

// Pure logic for the app shell (Settings window, updates, diagnostics,
// reset, automation). Foundation only, so the test harness compiles this
// file on its own. Nothing here touches the network, the disk or AppKit.

// MARK: - Versions

/// A release version such as "1.2", "v1.2.3" or "1.3.0-beta.2".
/// Build metadata ("+45") is ignored; a pre-release sorts before its release.
struct SparkVVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sparkv ", "sparkv-", "version ", "release "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("v") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        text = text.trimmingCharacters(in: .whitespaces)
        // "1.3 beta 2" and "1.3b2" read like "1.3-beta.2".
        var core = text
        var pre = ""
        if let dash = text.firstIndex(where: { $0 == "-" || $0 == " " }) {
            core = String(text[..<dash])
            pre = String(text[text.index(after: dash)...])
        } else if let letter = text.firstIndex(where: { $0.isLetter }) {
            core = String(text[..<letter])
            pre = String(text[letter...])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.numbers = numbers
        self.prerelease = Self.identifiers(pre)
    }

    /// "beta2", "beta.2", "beta 2" → ["beta", "2"].
    private static func identifiers(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentIsDigit: Bool?
        for ch in raw {
            if ch == "." || ch == "-" || ch == " " || ch == "_" {
                if !current.isEmpty { out.append(current) }
                current = ""
                currentIsDigit = nil
                continue
            }
            let digit = ch.isNumber
            if let was = currentIsDigit, was != digit, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current.append(ch)
            currentIsDigit = digit
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let base = numbers.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: SparkVVersion, rhs: SparkVVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<count {
            let a = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let b = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if a != b { return a < b }
        }
        // Same numbers: a release beats any of its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func == (lhs: SparkVVersion, rhs: SparkVVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }
}

// MARK: - GitHub releases

/// One entry of `GET /repos/{owner}/{repo}/releases`.
struct GitHubRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: URL
    let prerelease: Bool
    let draft: Bool
    let publishedAt: Date?
    let assets: [Asset]

    var version: SparkVVersion? { SparkVVersion(tagName) ?? name.flatMap(SparkVVersion.init) }

    /// "SparkV 1.2" or the tag.
    var displayVersion: String { version?.description ?? tagName }

    /// The disk image if there is one, else the zip.
    var preferredAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }
}

enum UpdatePolicy {
    static let owner = "koushik1133"
    static let repository = "macNotch"
    /// Automatic checks run at most this often.
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// An automatic check that failed is tried again after this long.
    static let retryAfterFailure: TimeInterval = 90 * 60

    static var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=15")!
    }

    static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    enum Decision: Equatable, Sendable {
        /// Nothing newer (`latest` is the newest published version, if any).
        case upToDate(latest: String?)
        case available(GitHubRelease)
        /// Newer, but the user chose "Skip This Version" for it.
        case skipped(GitHubRelease)
    }

    static func decodeReleases(_ data: Data) throws -> [GitHubRelease] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }

    /// The newest published release newer than `current`. Drafts never
    /// count; pre-releases only with `includePrereleases`.
    static func decide(
        current: SparkVVersion,
        releases: [GitHubRelease],
        includePrereleases: Bool,
        skippedVersion: String?
    ) -> Decision {
        let eligible = releases
            .filter { !$0.draft && (includePrereleases || !$0.prerelease) }
            .compactMap { release in release.version.map { (release, $0) } }
            .filter { includePrereleases || !$0.1.isPrerelease }
        guard let newest = eligible.max(by: { $0.1 < $1.1 }) else { return .upToDate(latest: nil) }
        guard current < newest.1 else { return .upToDate(latest: newest.1.description) }
        if let skippedVersion, let skipped = SparkVVersion(skippedVersion), skipped == newest.1 {
            return .skipped(newest.0)
        }
        return .available(newest.0)
    }

    /// True when an automatic check is due.
    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards shouldn't block checks for months.
        if lastCheck > now.addingTimeInterval(60) { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

// MARK: - Release notes

/// GitHub release notes (Markdown) as simple blocks the update window draws
/// natively. Inline Markdown (bold, code, links) stays in the text.
enum ReleaseNotesBlock: Equatable, Sendable {
    case heading(String, level: Int)
    case paragraph(String)
    case bullet(String, depth: Int)
    case rule
}

enum ReleaseNotes {
    static func parse(_ markdown: String, maxBlocks: Int = 120) -> [ReleaseNotesBlock] {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // HTML comments (release templates) never show.
        while let start = text.range(of: "<!--") {
            if let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        var inFence = false
        var fence: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    blocks.append(.paragraph(fence.joined(separator: "\n")))
                    fence.removeAll()
                    inFence = false
                } else {
                    flush()
                    inFence = true
                }
                continue
            }
            if inFence { fence.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("#") {
                flush()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let title = trimmed.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                if !title.isEmpty { blocks.append(.heading(title, level: min(level, 4))) }
                continue
            }
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let ch = trimmed.first, "-*_".contains(ch) {
                flush()
                blocks.append(.rule)
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            if let bullet = bulletText(trimmed) {
                flush()
                blocks.append(.bullet(bullet, depth: min(indent / 2, 3)))
                continue
            }
            // A wrapped bullet line continues the bullet above it.
            if indent >= 2, paragraph.isEmpty, case .bullet(let previous, let depth)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(previous + " " + trimmed, depth: depth)
                continue
            }
            paragraph.append(trimmed)
        }
        if inFence, !fence.isEmpty { blocks.append(.paragraph(fence.joined(separator: "\n"))) }
        flush()
        return Array(blocks.prefix(maxBlocks))
    }

    /// "- x", "* x", "+ x", "1. x", "- [x] y" → the item text.
    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            var item = String(line.dropFirst(marker.count))
            for box in ["[ ] ", "[x] ", "[X] "] where item.hasPrefix(box) { item = String(item.dropFirst(box.count)) }
            return item.trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return digits + ". " + rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

// MARK: - Automation (sparkv:// URLs)

/// A live activity requested by another tool through
/// `sparkv://activity?...`, already cleaned and clamped.
struct ExternalActivityRequest: Equatable, Sendable {
    /// Namespaced so it can never replace one of SparkV's own activities.
    let id: String
    let title: String
    let subtitle: String?
    /// SF Symbol name (validated against the system later).
    let symbol: String?
    /// 0...1, nil for none.
    let progress: Double?
    /// Seconds; nil stays until dismissed (capped at `maxDuration`).
    let duration: TimeInterval?
    /// One of `AutomationText.tintNames`.
    let tint: String?
    /// Short text for the compact form ("42%", "3/7").
    let compactText: String?

    static let defaultDuration: TimeInterval = 6
    static let maxDuration: TimeInterval = 8 * 60 * 60
    static let idPrefix = "ext."
}

enum AutomationCommand: Equatable, Sendable {
    case openSettings(pane: String?)
    case openDrawer(tab: String?)
    case closeDrawer
    case toggleDrawer
    case startTimer(minutes: Int)
    case startPomodoro
    case pauseTimer
    case resetTimer
    case startFocus(minutes: Int?)
    case endFocus
    case postActivity(ExternalActivityRequest)
    case dismissActivity(id: String)
    /// nil toggles.
    case setFeature(name: String, on: Bool?)
    case setAppearance(String)
    case pickColor
    case checkForUpdates
    case showAbout
    case showDiagnostics
    case openMeeting(UUID)

    /// Navigation (open a window or a tab) always works; anything that
    /// changes state or shows something on the island needs Automation on.
    var requiresAutomationEnabled: Bool {
        switch self {
        case .openSettings, .showAbout, .showDiagnostics, .openMeeting: false
        default: true
        }
    }

    /// The "Automation is off" band: a fixed phrase per kind of command.
    /// Never text from the link itself, so a blocked link can't put its
    /// own words on the island.
    var blockedPhrase: String {
        switch self {
        case .openSettings, .showAbout, .showDiagnostics, .openMeeting: "open a window"
        case .openDrawer, .closeDrawer, .toggleDrawer: "open or close the drawer"
        case .startTimer, .startPomodoro, .pauseTimer, .resetTimer: "control the timer"
        case .startFocus, .endFocus: "control Focus"
        case .postActivity, .dismissActivity: "show a live activity"
        case .setFeature: "change a setting"
        case .setAppearance: "change the look"
        case .pickColor: "open the color picker"
        case .checkForUpdates: "open Software Update"
        }
    }

    /// For logs and the Recent links list (Settings › Advanced).
    var summary: String {
        switch self {
        case .openSettings(let pane): "open Settings" + (pane.map { " (\($0))" } ?? "")
        case .openDrawer(let tab): "open the drawer" + (tab.map { " on \($0)" } ?? "")
        case .closeDrawer: "close the drawer"
        case .toggleDrawer: "open or close the drawer"
        case .startTimer(let minutes): "start a \(minutes)-minute timer"
        case .startPomodoro: "start a Pomodoro"
        case .pauseTimer: "pause or resume the timer"
        case .resetTimer: "reset the timer"
        case .startFocus(let minutes): "start Focus" + (minutes.map { " for \($0) min" } ?? "")
        case .endFocus: "end Focus"
        case .postActivity(let request): "show “\(request.title)” on the island"
        case .dismissActivity: "remove an island activity"
        case .setFeature(let name, let on): (on.map { $0 ? "turn on " : "turn off " } ?? "toggle ") + name
        case .setAppearance(let look): "switch the look to \(look)"
        case .pickColor: "open the color picker"
        case .checkForUpdates: "open Software Update"
        case .showAbout: "show About SparkV"
        case .showDiagnostics: "show diagnostics"
        case .openMeeting: "open a meeting"
        }
    }
}

enum AutomationParseError: Error, Equatable, Sendable {
    case notSparkV
    case unknownCommand(String)
    case missingParameter(String)
    case invalidParameter(String)

    var message: String {
        switch self {
        case .notSparkV: "Not a sparkv:// link."
        case .unknownCommand(let c): "Unknown command “\(c)”."
        case .missingParameter(let p): "Missing “\(p)”."
        case .invalidParameter(let p): "“\(p)” has a value SparkV can’t use."
        }
    }
}

enum AutomationURL {
    static let scheme = "sparkv"
    /// Longest URL SparkV reads (Shortcuts can build very long ones).
    static let maxLength = 2048

    /// The app's old name; only its meeting links are still honored.
    static let legacyScheme = "notchisland"

    static func parse(_ url: URL) -> Result<AutomationCommand, AutomationParseError> {
        let urlScheme = url.scheme?.lowercased()
        if urlScheme == legacyScheme {
            guard url.host?.lowercased() == "meeting" else { return .failure(.notSparkV) }
        } else if urlScheme != scheme {
            return .failure(.notSparkV)
        }
        guard url.absoluteString.count <= maxLength else { return .failure(.invalidParameter("url")) }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in parts?.queryItems ?? [] {
            let key = item.name.lowercased()
            if query[key] == nil { query[key] = item.value ?? "" }
        }
        // sparkv://timer/start → host "timer", path ["start"]; also accept
        // sparkv:timer/start and sparkv:///timer/start.
        var segments: [String] = []
        if let host = url.host, !host.isEmpty { segments.append(host) }
        segments += url.path.split(separator: "/").map { String($0) }
        if segments.isEmpty, let opaque = parts?.path, !opaque.isEmpty {
            segments = opaque.split(separator: "/").map(String.init)
        }
        segments = segments.map { $0.removingPercentEncoding ?? $0 }
        guard let command = segments.first?.lowercased() else { return .failure(.unknownCommand("")) }
        let sub = segments.count > 1 ? segments[1].lowercased() : nil

        switch command {
        case "settings", "preferences":
            return .success(.openSettings(pane: AutomationText.slug(query["pane"] ?? sub)))
        case "open", "tab":
            return .success(.openDrawer(tab: AutomationText.slug(query["tab"] ?? sub)))
        case "drawer", "island":
            switch sub ?? "toggle" {
            case "open", "show": return .success(.openDrawer(tab: AutomationText.slug(query["tab"])))
            case "close", "hide": return .success(.closeDrawer)
            case "toggle": return .success(.toggleDrawer)
            default: return .failure(.unknownCommand("\(command)/\(sub ?? "")"))
            }
        case "toggle":
            return .success(.toggleDrawer)
        case "close":
            return .success(.closeDrawer)
        case "timer":
            switch sub ?? "start" {
            case "start":
                guard let raw = query["minutes"] ?? query["min"] ?? (segments.count > 2 ? segments[2] : nil) else {
                    return .failure(.missingParameter("minutes"))
                }
                guard let minutes = Int(raw.trimmingCharacters(in: .whitespaces)), (1...600).contains(minutes) else {
                    return .failure(.invalidParameter("minutes"))
                }
                return .success(.startTimer(minutes: minutes))
            case "pomodoro": return .success(.startPomodoro)
            case "pause", "resume", "toggle": return .success(.pauseTimer)
            case "reset", "stop", "cancel": return .success(.resetTimer)
            default: return .failure(.unknownCommand("timer/\(sub ?? "")"))
            }
        case "pomodoro":
            return .success(.startPomodoro)
        case "focus":
            switch sub ?? "start" {
            case "start":
                if let raw = query["minutes"] {
                    guard let minutes = Int(raw), (5...240).contains(minutes) else { return .failure(.invalidParameter("minutes")) }
                    return .success(.startFocus(minutes: minutes))
                }
                return .success(.startFocus(minutes: nil))
            case "end", "stop": return .success(.endFocus)
            default: return .failure(.unknownCommand("focus/\(sub ?? "")"))
            }
        case "activity", "live-activity":
            if sub == "dismiss" || sub == "end" {
                guard let id = query["id"] else { return .failure(.missingParameter("id")) }
                return .success(.dismissActivity(id: ExternalActivityRequest.idPrefix + AutomationText.identifier(id)))
            }
            return activity(query)
        case "dismiss":
            guard let id = query["id"] ?? sub else { return .failure(.missingParameter("id")) }
            return .success(.dismissActivity(id: ExternalActivityRequest.idPrefix + AutomationText.identifier(id)))
        case "feature", "set":
            guard let name = AutomationText.slug(sub ?? query["name"]) else { return .failure(.missingParameter("name")) }
            let raw = query["on"] ?? query["enabled"] ?? query["value"] ?? (segments.count > 2 ? segments[2] : nil)
            guard let raw else { return .success(.setFeature(name: name, on: nil)) }
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return .success(.setFeature(name: name, on: true))
            case "0", "false", "no", "off": return .success(.setFeature(name: name, on: false))
            case "toggle", "": return .success(.setFeature(name: name, on: nil))
            default: return .failure(.invalidParameter("on"))
            }
        case "appearance", "look":
            guard let look = AutomationText.slug(query["look"] ?? query["style"] ?? sub) else {
                return .failure(.missingParameter("look"))
            }
            switch look {
            case "apple", "default": return .success(.setAppearance("apple"))
            case "sparkv-red", "sparkvred", "red", "sparkv": return .success(.setAppearance("sparkvRed"))
            default: return .failure(.invalidParameter("look"))
            }
        case "color-picker", "pick-color", "colorpicker", "color":
            return .success(.pickColor)
        case "updates", "update", "check-updates", "check-for-updates":
            return .success(.checkForUpdates)
        case "about":
            return .success(.showAbout)
        case "diagnostics", "reports":
            return .success(.showDiagnostics)
        case "meeting":
            guard let raw = segments.count > 1 ? segments[1] : query["id"], let id = UUID(uuidString: raw) else {
                return .failure(.invalidParameter("id"))
            }
            return .success(.openMeeting(id))
        default:
            return .failure(.unknownCommand(command))
        }
    }

    private static func activity(_ query: [String: String]) -> Result<AutomationCommand, AutomationParseError> {
        guard let rawTitle = query["title"] ?? query["text"] else { return .failure(.missingParameter("title")) }
        let title = AutomationText.clean(rawTitle, max: AutomationText.titleLimit)
        guard !title.isEmpty else { return .failure(.missingParameter("title")) }
        let subtitle = query["subtitle"].map { AutomationText.clean($0, max: AutomationText.subtitleLimit) }.flatMap { $0.isEmpty ? nil : $0 }
        var progress: Double?
        if let raw = query["progress"] {
            guard let value = AutomationText.progress(raw) else { return .failure(.invalidParameter("progress")) }
            progress = value
        }
        var duration: TimeInterval? = ExternalActivityRequest.defaultDuration
        if let raw = query["duration"]?.lowercased() {
            if raw == "0" || raw == "none" || raw == "persistent" || raw == "until-dismissed" {
                duration = nil
            } else if let seconds = Double(raw), seconds.isFinite, seconds > 0 {
                duration = min(max(seconds, 1), ExternalActivityRequest.maxDuration)
            } else {
                return .failure(.invalidParameter("duration"))
            }
        }
        let symbol = query["symbol"].flatMap(AutomationText.symbolName)
        let tint = query["tint"].flatMap { AutomationText.tintNames.contains($0.lowercased()) ? $0.lowercased() : nil }
        let compact = query["compact"].map { AutomationText.clean($0, max: AutomationText.compactLimit) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? progress.map { "\(Int(($0 * 100).rounded()))%" }
        return .success(.postActivity(ExternalActivityRequest(
            id: ExternalActivityRequest.idPrefix + AutomationText.identifier(query["id"] ?? "default"),
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            progress: progress,
            duration: duration,
            tint: tint,
            compactText: compact
        )))
    }
}

/// Cleaning for text that arrives in URLs from other apps and web pages.
enum AutomationText {
    static let titleLimit = 60
    static let subtitleLimit = 90
    static let compactLimit = 8
    static let tintNames: Set<String> = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "gray", "grey", "white"]

    /// No control or bidi-override characters, one line, at most `max`
    /// characters (an ellipsis marks the cut).
    static func clean(_ raw: String, max: Int) -> String {
        var out = ""
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let isControl = CharacterSet.controlCharacters.contains(scalar)
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                || v == 0x200E || v == 0x200F || v == 0xFEFF
            let isSpace = isControl || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSpace {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > max {
            out = String(out.prefix(Swift.max(1, max - 1))).trimmingCharacters(in: .whitespaces) + "…"
        }
        return out
    }

    /// Activity ids: letters, digits, ".", "-" and "_", at most 48.
    static func identifier(_ raw: String) -> String {
        let allowed = raw.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
        let id = String(String.UnicodeScalarView(allowed).prefix(48))
        return id.isEmpty ? "default" : id
    }

    /// Lowercased names for panes, tabs and features ("Now Playing" → "now-playing").
    static func slug(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == "-" || scalar == "_" || scalar == " " {
                if !out.isEmpty, out.last != "-" { out.append("-") }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : String(out.prefix(40))
    }

    /// SF Symbol names look like "checkmark.seal.fill".
    static func symbolName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }),
              !name.hasPrefix("."), !name.hasSuffix(".") else { return nil }
        return name
    }

    /// "0.4", "40", "40%" → 0.4.
    static func progress(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var percent = false
        if text.hasSuffix("%") { text.removeLast(); percent = true }
        guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
        let fraction = percent || value > 1 ? value / 100 : value
        return min(max(fraction, 0), 1)
    }
}

/// Keeps a misbehaving script or web page from flooding the island
/// without losing the state a well-behaved script ends on.
///
/// - Per key (one activity id, one switch, one timer command): at most one
///   delivery every `minInterval`. A request inside that interval is not
///   dropped but deferred to the interval's end, and a newer request for the
///   same key replaces the deferred one (trailing edge), so the last
///   progress post, "done" or dismiss always lands.
/// - Overall: at most `burst` distinct keys per `window`. Posting again to a
///   key already in use never spends budget, so one progress bar can be
///   updated as often as it likes. Exempt requests (dismiss) never drop.
struct AutomationRateLimiter: Sendable {
    enum Decision: Equatable, Sendable {
        case now
        /// Deliver at this time (the newest request for the key wins).
        case later(Date)
        case drop
    }

    var minInterval: TimeInterval = 0.25
    var burst = 20
    var window: TimeInterval = 60
    private var lastDelivered: [String: Date] = [:]
    /// Keys in use, with the last time each was asked for.
    private var activeKeys: [String: Date] = [:]

    init(minInterval: TimeInterval = 0.25, burst: Int = 20, window: TimeInterval = 60) {
        self.minInterval = minInterval
        self.burst = burst
        self.window = window
    }

    mutating func decide(_ key: String, now: Date, exempt: Bool = false) -> Decision {
        activeKeys = activeKeys.filter { now.timeIntervalSince($0.value) < window }
        if activeKeys[key] == nil, !exempt, activeKeys.count >= burst { return .drop }
        activeKeys[key] = now
        if let last = lastDelivered[key], now >= last, now.timeIntervalSince(last) < minInterval {
            return .later(last.addingTimeInterval(minInterval))
        }
        lastDelivered[key] = now
        if lastDelivered.count > 400 { lastDelivered = lastDelivered.filter { now.timeIntervalSince($0.value) < window } }
        return .now
    }

    /// A deferred request was delivered at `date`.
    mutating func noteDelivered(_ key: String, at date: Date) {
        lastDelivered[key] = date
    }
}

// MARK: - Reset and uninstall

/// What "Reset SparkV…" and "Uninstall SparkV…" move to the Trash.
enum ResetPlan {
    /// SparkV and its old name.
    static let bundleIDs = ["com.sparkv.app", "com.notchisland.app"]

    struct Item: Equatable, Sendable {
        let url: URL
        /// "Application Support › SparkV"
        let label: String
    }

    /// Every location SparkV writes in the user's Library, whether or not it
    /// exists right now (the caller filters).
    static func items(home: URL) -> [Item] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        func at(_ path: String, _ label: String) -> Item {
            Item(url: library.appendingPathComponent(path), label: label)
        }
        var items: [Item] = [
            at("Application Support/SparkV", "Application Support › SparkV: meeting notes and transcripts, Spaces, Flow notes, reports"),
            at("Application Support/NotchIsland", "Application Support › NotchIsland (old name)"),
        ]
        for id in bundleIDs {
            items.append(at("Caches/\(id)", "Caches › \(id)"))
            items.append(at("HTTPStorages/\(id)", "HTTPStorages › \(id)"))
            items.append(at("HTTPStorages/\(id).binarycookies", "HTTPStorages › \(id).binarycookies"))
            items.append(at("WebKit/\(id)", "WebKit › \(id)"))
            items.append(at("Saved Application State/\(id).savedState", "Saved Application State › \(id)"))
        }
        for log in ["SparkV.log", "SparkV.1.log", "SparkV.2.log", "NotchIsland.log"] {
            items.append(at("Logs/\(log)", "Logs › \(log)"))
        }
        return items
    }

    /// Preference files, removed through `removePersistentDomain` (listed
    /// so the confirmation shows them too).
    static func preferenceFiles(home: URL) -> [Item] {
        bundleIDs.map {
            Item(url: home.appendingPathComponent("Library/Preferences/\($0).plist"), label: "Preferences › \($0).plist")
        }
    }

    /// Keychain items SparkV created: Groq key, Face Unlock, Cloud Sync.
    /// Items of other apps never match.
    static func isOwnKeychainService(_ service: String) -> Bool {
        let s = service.lowercased()
        return bundleIDs.contains { s == $0 || s.hasPrefix($0 + ".") } || s.hasPrefix("com.sparkv.")
    }

    /// The Terminal command for a Homebrew install.
    static let brewZapCommand = "brew uninstall --zap --cask sparkv"

    /// What is deleted for good (not moved to the Trash), for the
    /// confirmation's second list.
    static let permanentItems: [String] = [
        "Settings (preferences of SparkV and its old name)",
        "Keychain items: Groq API key, Face Unlock login password, Spotify sign-in, Cloud Sync",
        "The login item",
        "Privacy permissions (camera, microphone, screen recording…)",
    ]

    /// SparkV can move its own app to the Trash only from a writable place:
    /// not under App Translocation (a quarantined app opened from Downloads
    /// runs from a read-only copy), not from a disk image.
    static func canMoveAppToTrash(bundlePath: String, parentWritable: Bool) -> Bool {
        !bundlePath.contains("/AppTranslocation/") && !bundlePath.hasPrefix("/Volumes/") && parentWritable
    }

    /// "Work notes" → "Work notes.sparkvspace", safe for any folder.
    static func spaceExportName(_ name: String, taken: Set<String>) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Space" : String(cleaned.prefix(80))
        var candidate = base + ".sparkvspace"
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(n).sparkvspace"
            n += 1
        }
        return candidate
    }
}

// MARK: - Diagnostics

enum DiagnosticKind: String, Sendable, CaseIterable {
    case crash, hang, cpu, diskWrites, launch, report

    var title: String {
        switch self {
        case .crash: "Crash"
        case .hang: "Hang"
        case .cpu: "High CPU"
        case .diskWrites: "Disk Writes"
        case .launch: "Slow Launch"
        case .report: "Report"
        }
    }

    var symbol: String {
        switch self {
        case .crash: "exclamationmark.octagon.fill"
        case .hang: "hourglass"
        case .cpu: "cpu"
        case .diskWrites: "internaldrive"
        case .launch: "timer"
        case .report: "doc.text"
        }
    }
}

/// A MetricKit diagnostic payload saved by SparkV, summarized.
struct MetricKitSummary: Equatable, Sendable {
    var counts: [DiagnosticKind: Int] = [:]
    var begin: Date?
    var end: Date?
    /// "EXC_BAD_ACCESS (SIGSEGV)" for the first crash, if any.
    var headline: String?
    var appVersion: String?

    var primaryKind: DiagnosticKind {
        for kind in [DiagnosticKind.crash, .hang, .cpu, .diskWrites, .launch] where (counts[kind] ?? 0) > 0 { return kind }
        return .report
    }

    var countText: String {
        let parts = DiagnosticKind.allCases.compactMap { kind -> String? in
            guard let n = counts[kind], n > 0 else { return nil }
            let noun = kind.title.lowercased()
            return n == 1 ? "1 \(noun)" : "\(n) \(noun == "high cpu" ? "high CPU reports" : noun + "s")"
        }
        return parts.isEmpty ? "No diagnostics" : parts.joined(separator: ", ")
    }

    static func parse(_ data: Data) -> MetricKitSummary? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var summary = MetricKitSummary()
        let map: [(String, DiagnosticKind)] = [
            ("crashDiagnostics", .crash), ("hangDiagnostics", .hang),
            ("cpuExceptionDiagnostics", .cpu), ("diskWriteExceptionDiagnostics", .diskWrites),
            ("appLaunchDiagnostics", .launch),
        ]
        for (key, kind) in map {
            if let list = json[key] as? [Any], !list.isEmpty { summary.counts[kind] = list.count }
        }
        summary.begin = date(json["timeStampBegin"])
        summary.end = date(json["timeStampEnd"])
        if let crash = (json["crashDiagnostics"] as? [[String: Any]])?.first {
            let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
            summary.appVersion = meta["appVersion"] as? String
            let exception = exceptionName(meta["exceptionType"])
            let signal = signalName(meta["signal"])
            summary.headline = [exception, signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            if summary.headline?.isEmpty == true { summary.headline = (meta["terminationReason"] as? String).map { String($0.prefix(80)) } }
        } else if let hang = (json["hangDiagnostics"] as? [[String: Any]])?.first,
                  let meta = hang["diagnosticMetaData"] as? [String: Any] {
            summary.appVersion = meta["appVersion"] as? String
            if let duration = meta["hangDuration"] as? String { summary.headline = "Not responding for \(duration)" }
        }
        return summary
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formats = ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd'T'HH:mm:ssZ"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func exceptionName(_ value: Any?) -> String? {
        guard let code = (value as? NSNumber)?.intValue else { return nil }
        let names = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
                     5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
        return names[code] ?? "Exception \(code)"
    }

    private static func signalName(_ value: Any?) -> String? {
        guard let code = (value as? NSNumber)?.intValue else { return nil }
        let names = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM"]
        return names[code] ?? "signal \(code)"
    }
}

/// macOS's own crash, hang and resource reports in
/// ~/Library/Logs/DiagnosticReports (.ips, .diag, .hang, .spin, .crash).
enum SystemReportFiles {
    static let processNames = ["SparkV", "NotchIsland", "com.sparkv.fanhelper"]

    /// True for SparkV's reports ("SparkV-2026-10-20-102211.ips").
    static func isOwnReport(_ name: String) -> Bool {
        let lower = name.lowercased()
        let extensions = [".ips", ".crash", ".diag", ".hang", ".spin"]
        guard extensions.contains(where: { lower.hasSuffix($0) }) else { return false }
        return processNames.contains { process in
            let p = process.lowercased()
            return lower.hasPrefix(p + "-") || lower.hasPrefix(p + "_") || lower.hasPrefix(p + ".")
        }
    }

    /// Kind from the file name, then the .ips header's bug_type.
    static func kind(name: String, header: String?) -> DiagnosticKind {
        let lower = name.lowercased()
        if lower.hasSuffix(".hang") || lower.hasSuffix(".spin") { return .hang }
        if lower.contains("cpu_resource") { return .cpu }
        if lower.contains("diskwrites_resource") { return .diskWrites }
        if lower.hasSuffix(".crash") { return .crash }
        if let header, let type = bugType(header) {
            switch type {
            case "109", "309": return .crash
            case "288", "298": return .hang
            case "202", "385": return .cpu
            case "145": return .diskWrites
            default: return .report
            }
        }
        return .report
    }

    /// The first line of an .ips file is a JSON header with "bug_type".
    static func bugType(_ header: String) -> String? {
        guard let data = header.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = json["bug_type"] as? String { return s }
        if let n = json["bug_type"] as? NSNumber { return n.stringValue }
        return nil
    }

    /// "app_version" from the header, if present.
    static func appVersion(_ header: String) -> String? {
        guard let data = header.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let short = json["app_version"] as? String
        let build = json["build_version"] as? String
        switch (short, build) {
        case let (s?, b?) where !b.isEmpty: return "\(s) (\(b))"
        case let (s?, _): return s
        default: return nil
        }
    }
}

/// Removes personal details from text SparkV exports.
///
/// Two profiles, because a crash report is JSON a developer has to read:
/// - `.report` (.ips and MetricKit JSON): only the home folder, /Users/<name>,
///   e-mail addresses, the user's and the Mac's names, and the per-Mac
///   identifiers (crashReporterKey, sleepWakeUUID, …). Keys, exception
///   types, frames and binary UUIDs stay, so the report can be symbolicated.
/// - `.log` (SparkV.log): all of that plus the paths and queries of web
///   addresses, quoted text (“…”, ‘…’, "…": window titles, meeting names,
///   file names) and device names such as "Anna’s AirPods". File names the
///   log mentions without quotes can remain; the export says so.
enum DiagnosticsRedactor {
    enum Profile: Sendable { case log, report }

    /// Per-Mac identifiers in .ips headers and MetricKit payloads.
    static let identifierKeys = ["crashReporterKey", "sleepWakeUUID", "deviceIdentifierForVendor", "bootSessionUUID", "rootsInstalled_uuid"]

    static func redact(_ text: String, home: String, names: [String] = [], profile: Profile = .log) -> String {
        var out = text
        if !home.isEmpty, home != "/" {
            out = out.replacingOccurrences(of: home, with: "~")
        }
        out = replace(#"/Users/[^/\s"']+"#, in: out, with: "/Users/[user]")
        out = replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: out, with: "[email]")
        out = redactNames(names, in: out)
        switch profile {
        case .report:
            let keys = identifierKeys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            out = replace(#"("(?:"# + keys + #")"\s*:\s*)"[^"\n]*""#, in: out, with: "$1\"[removed]\"")
        case .log:
            out = replace(#"(https?://[^/\s"'<>]+)[^\s"'<>]*"#, in: out, with: "$1/[…]")
            out = replace(#"[\p{L}\p{N}\-]+[’']s (?:AirPods(?: Pro| Max)?|iPhone|iPad|iMac|MacBook(?: Pro| Air)?|Mac(?: mini| Studio| Pro)?|Apple Watch|Beats[\p{L} ]{0,14}|Magic (?:Keyboard|Mouse|Trackpad)|Vision Pro)"#, in: out, with: "[device]")
            out = replace(#"“[^”\n]{1,200}”"#, in: out, with: "“[text]”")
            out = replace(#"‘[^’\n]{1,200}’"#, in: out, with: "‘[text]’")
            out = replace(#""[^"\n]{1,200}""#, in: out, with: "\"[text]\"")
        }
        return out
    }

    /// The user's and the Mac's names in every spelling the system uses:
    /// "Anna Berg", "Anna", "Berg", "Anna’s MacBook Pro", "Annas-MacBook-Pro".
    /// Longest first, so a full name goes before its parts.
    static func nameVariants(fullName: String, shortName: String, hostNames: [String]) -> [String] {
        var names: Set<String> = []
        let full = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.count >= 3 { names.insert(full) }
        for part in full.split(whereSeparator: { $0 == " " || $0 == "-" }) where part.count >= 3 { names.insert(String(part)) }
        if shortName.count >= 3 { names.insert(shortName) }
        for host in hostNames {
            var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if h.hasSuffix(".local") { h.removeLast(6) }
            guard h.count >= 3 else { continue }
            names.insert(h)
            names.insert(h.replacingOccurrences(of: "’", with: "'"))
            let hyphenated = h.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
                .split(separator: " ").joined(separator: "-")
            names.insert(hyphenated)
        }
        return names.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// Whole words only, ignoring case.
    private static func redactNames(_ names: [String], in text: String) -> String {
        var out = text
        for name in names where !name.isEmpty {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[name]")
        }
        return out
    }

    /// Exported report file name without the computer's name that macOS
    /// puts in hang and spin reports: "crash-2026-10-25-101010.ips".
    static func exportFileName(kind: DiagnosticKind, date: Date, pathExtension: String, taken: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let ext = pathExtension.isEmpty ? "txt" : pathExtension
        let base = "\(kind.rawValue)-\(formatter.string(from: date))"
        var name = "\(base).\(ext)"
        var n = 2
        while taken.contains(name) {
            name = "\(base)-\(n).\(ext)"
            n += 1
        }
        return name
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// Size-based rotation for ~/Library/Logs/SparkV.log: past `limit` bytes the
/// log becomes SparkV.1.log (the previous .1 becomes .2, the oldest goes).
enum LogRotation {
    static let limit = 5 * 1024 * 1024
    static let keep = 2

    /// The renames to perform, oldest first, for a log of `size` bytes.
    static func plan(log: URL, size: Int, limit: Int = limit, keep: Int = keep) -> [(from: URL, to: URL?)] {
        guard size > limit, keep > 0 else { return [] }
        let base = log.deletingPathExtension().lastPathComponent
        let ext = log.pathExtension
        let folder = log.deletingLastPathComponent()
        func numbered(_ n: Int) -> URL { folder.appendingPathComponent("\(base).\(n).\(ext)") }
        var steps: [(URL, URL?)] = [(numbered(keep), nil)]
        if keep > 1 {
            for n in stride(from: keep - 1, through: 1, by: -1) { steps.append((numbered(n), numbered(n + 1))) }
        }
        steps.append((log, numbered(1)))
        return steps
    }
}

// MARK: - Automation catalog (the in-app guide and AUTOMATION.md)

struct AutomationExample: Equatable, Sendable {
    let url: String
    let title: String
    let detail: String
}

struct AutomationGroup: Equatable, Sendable {
    let title: String
    /// Works while Automation is off (navigation only).
    let alwaysAllowed: Bool
    let items: [AutomationExample]
}

enum AutomationCatalog {
    static let groups: [AutomationGroup] = [
        AutomationGroup(title: "Windows", alwaysAllowed: true, items: [
            AutomationExample(url: "sparkv://settings", title: "Open Settings", detail: "On the last pane used."),
            AutomationExample(url: "sparkv://settings/advanced", title: "Open a Settings pane", detail: "general, island, media, system, activities, planner, shelf, extras, appearance, accessibility, advanced."),
            AutomationExample(url: "sparkv://about", title: "About SparkV", detail: "Version and licenses."),
            AutomationExample(url: "sparkv://diagnostics", title: "Crash & Hang Reports", detail: "The local report viewer."),
        ]),
        AutomationGroup(title: "Drawer", alwaysAllowed: false, items: [
            AutomationExample(url: "sparkv://open?tab=tray", title: "Open the drawer on a tab", detail: "home, widgets, tray, today, converter, spaces, agents, flow, clicky, clipboard, focus, search, downloads, fans, files."),
            AutomationExample(url: "sparkv://drawer/close", title: "Close the drawer", detail: ""),
            AutomationExample(url: "sparkv://toggle", title: "Open or close the drawer", detail: ""),
        ]),
        AutomationGroup(title: "Timer and Focus", alwaysAllowed: false, items: [
            AutomationExample(url: "sparkv://timer/start?minutes=25", title: "Start a timer", detail: "1 to 600 minutes."),
            AutomationExample(url: "sparkv://timer/pomodoro", title: "Start a Pomodoro", detail: ""),
            AutomationExample(url: "sparkv://timer/pause", title: "Pause or resume the timer", detail: ""),
            AutomationExample(url: "sparkv://timer/reset", title: "Reset the timer", detail: ""),
            AutomationExample(url: "sparkv://focus/start?minutes=50", title: "Start Focus", detail: "minutes is optional (5 to 240)."),
            AutomationExample(url: "sparkv://focus/end", title: "End Focus", detail: ""),
        ]),
        AutomationGroup(title: "Live activities from your tools", alwaysAllowed: false, items: [
            AutomationExample(url: "sparkv://activity?id=build&title=Build%20passed&subtitle=main%20%C2%B7%2042%20s&symbol=checkmark.seal.fill&tint=green", title: "Show a band on the island", detail: "title (60 chars), subtitle (90), symbol (SF Symbol), tint, progress (0–1 or 40%), duration in seconds (0 = until dismissed, 8 h at most), id to update it in place."),
            AutomationExample(url: "sparkv://activity?id=export&title=Exporting&progress=40%25&duration=0", title: "Show progress", detail: "Post again with the same id to move the bar."),
            AutomationExample(url: "sparkv://dismiss?id=export", title: "Remove it", detail: ""),
        ]),
        AutomationGroup(title: "Switches and looks", alwaysAllowed: false, items: [
            AutomationExample(url: "sparkv://feature/ambient-light?on=1", title: "Turn a feature on or off", detail: "on=1, on=0, or leave it out to toggle. Names are listed in Settings › Advanced. Switches that send data off the Mac or show other apps’ content (notifications) can only be turned off by a link."),
            AutomationExample(url: "sparkv://appearance?look=sparkv-red", title: "Switch the look", detail: "apple or sparkv-red."),
            AutomationExample(url: "sparkv://color-picker", title: "Pick a color", detail: "When the color picker is installed."),
            AutomationExample(url: "sparkv://updates/check", title: "Open Software Update", detail: "Shows the update window. GitHub is contacted only when you click Check Now there."),
        ]),
    ]
}
