import Foundation
import SwiftUI

// Universal search: one box over Spaces, meeting notes, Flow, clipboard
// history and the Tray. Plain value types only (Sendable), so ranking runs
// off the main thread. See DESIGN.md.

/// Where a result comes from. Order is the default section order and the
/// ⌘1…⌘5 filter shortcut.
enum UniversalSearchSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case spaces
    case meetings
    case flow
    case clipboard
    case tray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaces: "Spaces"
        case .meetings: "Meetings"
        case .flow: "Flow"
        case .clipboard: "Clipboard"
        case .tray: "Tray"
        }
    }

    var symbol: String {
        switch self {
        case .spaces: "square.stack.3d.up.fill"
        case .meetings: "person.2.wave.2.fill"
        case .flow: "waveform"
        case .clipboard: "doc.on.clipboard.fill"
        case .tray: "tray.full.fill"
        }
    }

    /// Apple: each source keeps the previous version's color. SparkV Red: one red.
    var tint: Color {
        guard SparkVTheme.usesTileTints else { return SparkVTheme.red }
        switch self {
        case .spaces: return Color(red: 0.55, green: 0.45, blue: 1.0)
        case .meetings: return Color(red: 0.36, green: 0.62, blue: 1.0)
        case .flow: return Color(red: 0.25, green: 0.80, blue: 0.62)
        case .clipboard: return Color(red: 1.0, green: 0.45, blue: 0.62)
        case .tray: return Color(red: 1.0, green: 0.66, blue: 0.25)
        }
    }

    /// ⌘ digit that filters to this source.
    var digit: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// `in:` token names ("in:meet", "in:clip", …): any prefix of these.
    var tokenNames: [String] {
        switch self {
        case .spaces: ["spaces", "space"]
        case .meetings: ["meetings", "meeting", "notes"]
        case .flow: ["flow", "dictation", "dictations"]
        case .clipboard: ["clipboard", "clips"]
        case .tray: ["tray", "files", "shelf"]
        }
    }
}

/// Date filter chip (Rewind/Limitless-style time scoping).
enum UniversalSearchDateFilter: String, CaseIterable, Codable, Sendable, Identifiable {
    case any
    case today
    case yesterday
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any Time"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "Past 7 Days"
        case .month: "Past 30 Days"
        case .year: "Past Year"
        }
    }

    var shortTitle: String {
        switch self {
        case .any: "Any time"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "7 days"
        case .month: "30 days"
        case .year: "Year"
        }
    }

    func contains(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .any: return true
        case .today: return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            guard let y = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            return calendar.isDate(date, inSameDayAs: y)
        case .week: return date >= now.addingTimeInterval(-7 * 86_400)
        case .month: return date >= now.addingTimeInterval(-30 * 86_400)
        case .year: return date >= now.addingTimeInterval(-365 * 86_400)
        }
    }
}

/// What Enter opens.
enum UniversalSearchTarget: Hashable, Sendable {
    case spaceItem(UUID)
    case meeting(UUID)
    case flowEntry(UUID)
    case flowNote(UUID)
    case clipboard(UUID)
    case trayItem(UUID)
}

/// One searchable thing, with the folded (lowercased, diacritics removed)
/// copies the matcher needs computed once per corpus build.
struct UniversalSearchDocument: Sendable, Identifiable {
    /// Stable key ("flow:<uuid>"), also the frecency key.
    let id: String
    let source: UniversalSearchSource
    let target: UniversalSearchTarget
    let title: String
    /// Second line in the row ("Dictation · Slack", "Acme › Contracts").
    let subtitle: String
    /// Extra fields matched fuzzily but not shown (space names, tags, app).
    let keywords: String
    let body: String
    let date: Date
    let symbol: String
    /// What ⌘C copies (nil: the controller resolves it, e.g. clipboard images).
    let copyText: String?

    let titleChars: [Character]
    let titleFolded: [Character]
    let titleFoldedString: String
    let keywordsChars: [Character]
    let keywordsFolded: [Character]
    /// Folded body as UTF-8 bytes, searched with memmem (fast enough to scan
    /// megabytes of meeting transcripts per keystroke).
    let bodyBytes: [UInt8]

    static let maxTitle = 160
    static let maxKeywords = 240
    static let maxBody = 150_000

    init(id: String, source: UniversalSearchSource, target: UniversalSearchTarget, title: String,
         subtitle: String, keywords: String = "", body: String, date: Date, symbol: String, copyText: String?) {
        let cleanTitle = UniversalSearchText.singleLine(title, limit: Self.maxTitle)
        self.id = id
        self.source = source
        self.target = target
        self.title = cleanTitle.isEmpty ? "Untitled" : cleanTitle
        self.subtitle = subtitle
        self.keywords = keywords
        self.body = body.count > Self.maxBody ? String(body.prefix(Self.maxBody)) : body
        self.date = date
        self.symbol = symbol
        self.copyText = copyText
        titleChars = Array(self.title)
        titleFolded = titleChars.map(UniversalSearchText.fold)
        titleFoldedString = String(titleFolded)
        keywordsChars = Array(String(keywords.prefix(Self.maxKeywords)))
        keywordsFolded = keywordsChars.map(UniversalSearchText.fold)
        bodyBytes = Array(UniversalSearchText.foldString(self.body).utf8)
    }
}

/// One ranked hit.
struct UniversalSearchResult: Identifiable, Sendable, Equatable {
    let document: UniversalSearchDocument
    var score: Double
    /// Character offsets in `document.title` to highlight.
    var titleHighlights: [Int]
    /// Body excerpt around the first body match (single line).
    var snippet: String?
    /// Character ranges in `snippet` to highlight.
    var snippetHighlights: [Range<Int>]
    /// Came only from Spaces' semantic search (no keyword match).
    var isRelated = false

    var id: String { document.id }
    var source: UniversalSearchSource { document.source }

    static func == (a: UniversalSearchResult, b: UniversalSearchResult) -> Bool {
        a.id == b.id && a.score == b.score && a.snippet == b.snippet && a.titleHighlights == b.titleHighlights
            && a.isRelated == b.isRelated
    }
}

/// A titled group of results (Spotlight's "Top Hit", then one per source).
struct UniversalSearchSection: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let source: UniversalSearchSource?
    var results: [UniversalSearchResult]
    /// Results left out of this section by the per-section limit.
    var hiddenCount: Int = 0
}

/// The parsed search box: free text plus `in:` and `date:` tokens.
struct UniversalSearchQuery: Sendable, Equatable {
    /// Text without the tokens, trimmed.
    var text: String
    /// Folded terms (AND-matched).
    var terms: [String]
    var sources: Set<UniversalSearchSource>?
    var date: UniversalSearchDateFilter?

    var isEmpty: Bool { terms.isEmpty }

    static func parse(_ raw: String) -> UniversalSearchQuery {
        var words: [String] = []
        var sources: Set<UniversalSearchSource>?
        var date: UniversalSearchDateFilter?
        for word in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lower = word.lowercased()
            if lower.hasPrefix("in:"), lower.count > 3 {
                let name = String(lower.dropFirst(3))
                let hits = UniversalSearchSource.allCases.filter { s in s.tokenNames.contains { $0.hasPrefix(name) } }
                if !hits.isEmpty {
                    sources = (sources ?? []).union(hits)
                    continue
                }
            }
            if lower.hasPrefix("date:"), lower.count > 5 {
                let name = String(lower.dropFirst(5))
                let map: [(String, UniversalSearchDateFilter)] = [
                    ("today", .today), ("yesterday", .yesterday), ("week", .week),
                    ("7d", .week), ("month", .month), ("30d", .month), ("year", .year),
                ]
                if let hit = map.first(where: { $0.0.hasPrefix(name) }) {
                    date = hit.1
                    continue
                }
            }
            words.append(word)
        }
        let text = words.joined(separator: " ")
        var seen: Set<String> = []
        let terms = words.map(UniversalSearchText.foldString)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "#@$"))) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return UniversalSearchQuery(text: text, terms: terms, sources: sources, date: date)
    }
}

/// Text helpers shared by the corpus, matcher and views.
enum UniversalSearchText {
    /// Lowercased, diacritic-free, one Character in, one out (so offsets
    /// into the folded copy are offsets into the original).
    static func fold(_ c: Character) -> Character {
        if let a = c.asciiValue {
            return (65...90).contains(a) ? Character(UnicodeScalar(a + 32)) : c
        }
        let folded = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.first ?? c
    }

    static func foldString(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whitespace and newlines collapsed to single spaces, trimmed, capped.
    static func singleLine(_ s: String, limit: Int) -> String {
        var out = ""
        out.reserveCapacity(min(s.utf8.count, limit + 8))
        var lastWasSpace = true
        for c in s {
            if out.count >= limit { break }
            if c.isWhitespace || c.isNewline {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func firstLine(_ s: String, limit: Int = 120) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return singleLine(line, limit: limit)
    }

    static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Word character in folded UTF-8 (non-ASCII bytes count as letters).
    static func isWordByte(_ b: UInt8) -> Bool {
        (48...57).contains(b) || (97...122).contains(b) || (65...90).contains(b) || b >= 0x80
    }

    /// Offset of `needle` in `haystack` at or after `from` (memmem).
    static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int = 0) -> Int? {
        let n = needle.count, h = haystack.count
        guard n > 0, from >= 0, h - from >= n else { return nil }
        return haystack.withUnsafeBufferPointer { hb -> Int? in
            needle.withUnsafeBufferPointer { nb -> Int? in
                guard let hBase = hb.baseAddress, let nBase = nb.baseAddress,
                      let hit = memmem(hBase + from, h - from, nBase, n) else { return nil }
                return UnsafeRawPointer(hBase).distance(to: UnsafeRawPointer(hit))
            }
        }
    }

    /// Path with the home folder as ~.
    static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "now", "5m", "3h", "Yesterday", "Mon", "Mar 3", "Mar 3, 2024".
    static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Yesterday"
        }
        let f = DateFormatter()
        f.locale = .current
        if seconds < 6 * 86_400 {
            f.setLocalizedDateFormatFromTemplate("EEE")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            f.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        }
        return f.string(from: date)
    }
}

/// Background work that stops when the caller is cancelled. A plain
/// `Task.detached` ignores its parent's cancellation, so every superseded
/// keystroke's search would otherwise scan the whole corpus to the end.
enum UniversalSearchBackground {
    static func run<T: Sendable>(priority: TaskPriority = .userInitiated,
                                 _ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: priority) { work() }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
