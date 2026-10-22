import Foundation

/// Ranking, grouping and excerpts. Pure and Sendable-only, so the
/// controller runs it on a background task for every keystroke.
///
/// Matching (per query term, all terms must match, as in fzf's extended
/// search and Raycast/Alfred): fzf fuzzy score on the title and on hidden
/// keywords, or a word-prefix / substring hit in the body (full-text, as
/// Spotlight and Rewind do; fuzzy over long text matches noise). Ranking
/// adds a phrase bonus, a gentle recency boost and the user's frecency /
/// remembered-query boost (`UniversalSearchKnowledge`).
enum UniversalSearchEngine {
    enum Mode: Sendable {
        /// Every term must match (typing in the box).
        case all
        /// Any non-stopword term may match (retrieval for Ask).
        case any
    }

    struct Options: Sendable {
        var sources: Set<UniversalSearchSource> = Set(UniversalSearchSource.allCases)
        var date: UniversalSearchDateFilter = .any
        var mode: Mode = .all
        var limit = 200
        var now = Date()
    }

    // MARK: Search

    static func search(_ query: UniversalSearchQuery, in docs: [UniversalSearchDocument],
                       options: Options, knowledge: UniversalSearchKnowledge) -> [UniversalSearchResult] {
        var terms = query.terms
        if options.mode == .any {
            let content = terms.filter { !stopwords.contains($0) && $0.count > 1 }
            if !content.isEmpty { terms = content }
        }
        guard !terms.isEmpty else { return [] }
        let patterns = terms.map { Array($0) }
        let termBytes = terms.map { Array($0.utf8) }
        let phrase = terms.joined(separator: " ")
        let phraseBytes = Array(phrase.utf8)
        let foldedQuery = UniversalSearchText.foldString(query.text).trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [UniversalSearchResult] = []
        results.reserveCapacity(64)

        for doc in docs {
            if Task.isCancelled { return [] }
            guard options.sources.contains(doc.source), options.date.contains(doc.date, now: options.now) else { continue }
            var total = 0.0
            var matched = 0
            var highlights: Set<Int> = []
            for i in terms.indices {
                let s = termScore(bytes: termBytes[i], pattern: patterns[i], doc: doc)
                if s.score <= 0 {
                    if options.mode == .all { total = -1; break }
                    continue
                }
                matched += 1
                total += s.score
                highlights.formUnion(s.titlePositions)
            }
            guard total > 0, matched > 0 else { continue }
            if options.mode == .any { total *= Double(matched) / Double(terms.count) }

            // Phrase bonuses (Spotlight ranks title-prefix hits first).
            if doc.titleFoldedString.hasPrefix(phrase) {
                total += 40
            } else if terms.count > 1, doc.titleFoldedString.contains(phrase) {
                total += 24
            } else if terms.count > 1, UniversalSearchText.find(phraseBytes, in: doc.bodyBytes) != nil {
                total += 14
            }
            // Recency: up to +18 for today, half-life two weeks.
            let ageDays = max(0, options.now.timeIntervalSince(doc.date) / 86_400)
            total += 18 * pow(0.5, ageDays / 14)
            total += knowledge.boost(doc.id, foldedQuery: foldedQuery, now: options.now)

            results.append(UniversalSearchResult(
                document: doc, score: total, titleHighlights: highlights.sorted(),
                snippet: nil, snippetHighlights: []
            ))
        }
        results.sort { a, b in
            a.score != b.score ? a.score > b.score : a.document.date > b.document.date
        }
        if results.count > options.limit { results = Array(results.prefix(options.limit)) }
        // Excerpts only for what can be shown.
        for i in results.indices.prefix(60) {
            let (snippet, ranges) = excerpt(results[i].document, terms: terms)
            results[i].snippet = snippet
            results[i].snippetHighlights = ranges
        }
        return results
    }

    struct TermScore {
        var score: Double
        var titlePositions: [Int]
        var inBody: Bool
    }

    static func termScore(bytes: [UInt8], pattern: [Character], doc: UniversalSearchDocument) -> TermScore {
        let m = pattern.count
        var best = TermScore(score: 0, titlePositions: [], inBody: false)
        // Title (fuzzy).
        if let t = UniversalSearchFuzzy.match(pattern, text: doc.titleChars, folded: doc.titleFolded),
           accepts(t, length: m) {
            best = TermScore(score: Double(t.score), titlePositions: t.positions, inBody: false)
        }
        // Hidden keywords (fuzzy, weighted down).
        if let k = UniversalSearchFuzzy.match(pattern, text: doc.keywordsChars, folded: doc.keywordsFolded),
           accepts(k, length: m) {
            let s = Double(k.score) * 0.7
            if s > best.score { best = TermScore(score: s, titlePositions: [], inBody: false) }
        }
        // Body (word prefix > substring).
        if best.score < Double(m * UniversalSearchFuzzy.scoreMatch) {
            let b = bodyScore(bytes, length: m, in: doc.bodyBytes)
            if b > best.score { best = TermScore(score: b, titlePositions: best.titlePositions, inBody: true) }
        }
        return best
    }

    /// Raycast-style sensitivity: scattered letters across a long title
    /// don't count. One-letter terms must start a word.
    static func accepts(_ match: UniversalSearchFuzzy.Match, length m: Int) -> Bool {
        if m == 1 { return match.firstBonus >= UniversalSearchFuzzy.bonusBoundary }
        if m == 2 {
            // Two letters: adjacent, or both on word starts.
            let adjacent = match.positions.count == 2 && match.positions[1] == match.positions[0] + 1
            return adjacent || match.score >= 2 * UniversalSearchFuzzy.scoreMatch + 2 * UniversalSearchFuzzy.bonusBoundary
        }
        guard match.firstBonus > 0 || isContiguous(match.positions) else {
            // Starting mid-word is fine only when tight.
            return match.score >= m * UniversalSearchFuzzy.scoreMatch
        }
        return match.score >= m * (UniversalSearchFuzzy.scoreMatch / 2)
    }

    private static func isContiguous(_ p: [Int]) -> Bool {
        guard let first = p.first, let last = p.last else { return false }
        return last - first == p.count - 1
    }

    /// Word-prefix hit (whole word scores a little more) > substring hit.
    static func bodyScore(_ term: [UInt8], length m: Int, in body: [UInt8]) -> Double {
        var from = 0
        var found = false
        var looked = 0
        while looked < 40, let at = UniversalSearchText.find(term, in: body, from: from) {
            found = true
            if at == 0 || !UniversalSearchText.isWordByte(body[at - 1]) {
                let end = at + term.count
                let whole = end == body.count || !UniversalSearchText.isWordByte(body[end])
                return Double(m * UniversalSearchFuzzy.scoreMatch) * (whole ? 0.62 : 0.55) + 8
            }
            looked += 1
            from = at + 1
        }
        return found && m >= 3 ? Double(m * UniversalSearchFuzzy.scoreMatch) * 0.35 : 0
    }

    // MARK: Excerpts

    /// One-line excerpt (~150 characters) around the first body hit of the
    /// longest term that appears in the body, with every term highlighted.
    static func excerpt(_ doc: UniversalSearchDocument, terms: [String], width: Int = 150) -> (String?, [Range<Int>]) {
        guard !doc.body.isEmpty else { return (nil, []) }
        var body = Substring(doc.body)
        // Bodies that open with the title (dictations, clippings, notes)
        // would repeat the first line: excerpt from after it.
        let trimmedBody = body.drop { $0.isWhitespace || $0.isNewline }
        if doc.title.count >= 4,
           let lead = trimmedBody.range(of: doc.title, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) {
            body = trimmedBody[lead.upperBound...].drop { $0.isWhitespace || $0.isNewline || $0.isPunctuation }
            if body.count < 8 { return (nil, []) }
        }
        var anchor: Range<Substring.Index>?
        for term in terms.sorted(by: { $0.count > $1.count }) where term.count >= 2 {
            if let r = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                anchor = r
                break
            }
        }
        let start: String.Index
        if let anchor {
            start = body.index(anchor.lowerBound, offsetBy: -45, limitedBy: body.startIndex) ?? body.startIndex
        } else {
            // The match was in the title only: show the start of the body,
            // unless it just repeats the title.
            start = body.startIndex
        }
        let end = body.index(start, offsetBy: width + 40, limitedBy: body.endIndex) ?? body.endIndex
        var text = UniversalSearchText.singleLine(String(body[start..<end]), limit: width)
        if start != body.startIndex {
            // Start on a word.
            if let space = text.firstIndex(of: " "), text.distance(from: text.startIndex, to: space) < 18 {
                text = String(text[text.index(after: space)...])
            }
            text = "…" + text
        }
        if end != body.endIndex || text.count >= width { text += "…" }
        return (text, highlightRanges(in: text, terms: terms))
    }

    static func highlightRanges(in text: String, terms: [String]) -> [Range<Int>] {
        let chars = Array(text)
        let folded = chars.map(UniversalSearchText.fold)
        var ranges: [Range<Int>] = []
        for term in terms where term.count >= 2 {
            let p = Array(term)
            guard p.count <= folded.count else { continue }
            var i = 0
            while i <= folded.count - p.count {
                if folded[i] == p[0], Array(folded[i..<(i + p.count)]) == p {
                    let boundary = i == 0 || !UniversalSearchText.isWordChar(chars[i - 1])
                    if boundary || p.count >= 3 { ranges.append(i..<(i + p.count)) }
                    i += p.count
                } else {
                    i += 1
                }
            }
        }
        return merge(ranges)
    }

    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: Sections

    /// Spotlight layout: "Top Hit" (the best result, when it clearly leads),
    /// then one section per source ordered by its best score. With one source
    /// filtered, a single long section.
    static func sections(_ results: [UniversalSearchResult], perSource: Int, singleSource: Bool) -> [UniversalSearchSection] {
        guard !results.isEmpty else { return [] }
        if singleSource {
            let source = results[0].source
            return [UniversalSearchSection(id: "only", title: source.title, source: source, results: results)]
        }
        var out: [UniversalSearchSection] = []
        var rest = results
        let top = results[0]
        let runnerUp = results.count > 1 ? results[1].score : 0
        if results.count > 2, top.score >= runnerUp * 1.12 || top.score - runnerUp >= 25 {
            out.append(UniversalSearchSection(id: "top", title: "Top Hit", source: nil, results: [top]))
            rest.removeFirst()
        }
        var order: [UniversalSearchSource] = []
        var groups: [UniversalSearchSource: [UniversalSearchResult]] = [:]
        for r in rest {
            if groups[r.source] == nil { order.append(r.source) }
            groups[r.source, default: []].append(r)
        }
        for source in order {
            let all = groups[source] ?? []
            out.append(UniversalSearchSection(
                id: source.rawValue, title: source.title, source: source,
                results: Array(all.prefix(perSource)), hiddenCount: max(0, all.count - perSource)
            ))
        }
        return out
    }

    /// What the empty box shows: frequently opened items, then the latest
    /// few from each source.
    static func recents(_ docs: [UniversalSearchDocument], options: Options, knowledge: UniversalSearchKnowledge,
                        perSource: Int) -> [UniversalSearchSection] {
        let visible = docs.filter { options.sources.contains($0.source) && options.date.contains($0.date, now: options.now) }
        var sections: [UniversalSearchSection] = []
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let frequent = knowledge.topItems(limit: 12, now: options.now).compactMap { byID[$0] }.prefix(options.sources.count == 1 ? 0 : 4)
        if !frequent.isEmpty {
            sections.append(UniversalSearchSection(id: "frequent", title: "Frequently Used", source: nil,
                                                   results: frequent.map { result($0, score: 0) }))
        }
        let shown = Set(frequent.map(\.id))
        let latest = visible.filter { !shown.contains($0.id) }.sorted { $0.date > $1.date }
        var order: [UniversalSearchSource] = []
        var groups: [UniversalSearchSource: [UniversalSearchDocument]] = [:]
        for d in latest {
            if groups[d.source] == nil { order.append(d.source) }
            if groups[d.source, default: []].count < perSource { groups[d.source, default: []].append(d) }
        }
        for source in order {
            sections.append(UniversalSearchSection(id: source.rawValue, title: "Recent \(source.title)", source: source,
                                                   results: (groups[source] ?? []).map { result($0, score: 0) }))
        }
        return sections
    }

    static func result(_ doc: UniversalSearchDocument, score: Double) -> UniversalSearchResult {
        let (snippet, _) = excerpt(doc, terms: [])
        return UniversalSearchResult(document: doc, score: score, titleHighlights: [], snippet: snippet, snippetHighlights: [])
    }

    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "did", "do", "does", "for", "from", "had", "has",
        "have", "how", "i", "in", "is", "it", "its", "me", "my", "of", "on", "or", "our", "say", "said", "so",
        "that", "the", "their", "them", "there", "they", "this", "to", "was", "we", "were", "what", "when",
        "where", "which", "who", "why", "will", "with", "you", "your", "about", "tell", "show", "find", "any",
        "all", "get", "got", "us", "should", "would", "could", "last", "s",
    ]
}
