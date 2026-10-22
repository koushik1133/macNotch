import Foundation

/// What the user picked before, for ranking. Two signals, as in Raycast's
/// root search ("how often you open every element" plus "whether you typed a
/// previously triggered search term or a prefix of it") and Alfred's
/// Knowledge:
/// - frecency per item: open count weighted by Mozilla's Places recency
///   buckets (4 days 100, 14 days 70, 31 days 50, 90 days 30, older 10),
/// - query memory: the item chosen for a query gets a strong boost when the
///   box holds that query or a prefix of it again.
struct UniversalSearchKnowledge: Codable, Sendable, Equatable {
    struct Usage: Codable, Sendable, Equatable {
        var count: Int
        var last: Date
    }

    struct Pick: Codable, Sendable, Equatable {
        /// Folded query text the item was opened from.
        var query: String
        var itemID: String
        var count: Int
        var last: Date
    }

    var usage: [String: Usage] = [:]
    var picks: [Pick] = []

    static let maxItems = 400
    static let maxPicks = 300

    mutating func record(itemID: String, query: String, now: Date = Date()) {
        var u = usage[itemID] ?? Usage(count: 0, last: now)
        u.count += 1
        u.last = now
        usage[itemID] = u
        let q = UniversalSearchText.foldString(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            if let i = picks.firstIndex(where: { $0.query == q && $0.itemID == itemID }) {
                picks[i].count += 1
                picks[i].last = now
            } else {
                picks.append(Pick(query: q, itemID: itemID, count: 1, last: now))
            }
        }
        prune()
    }

    mutating func forget(itemID: String) {
        usage[itemID] = nil
        picks.removeAll { $0.itemID == itemID }
    }

    private mutating func prune() {
        if usage.count > Self.maxItems {
            let keep = usage.sorted { $0.value.last > $1.value.last }.prefix(Self.maxItems)
            usage = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if picks.count > Self.maxPicks {
            picks = Array(picks.sorted { $0.last > $1.last }.prefix(Self.maxPicks))
        }
    }

    static func recencyWeight(_ last: Date, now: Date) -> Double {
        let days = now.timeIntervalSince(last) / 86_400
        switch days {
        case ..<4: return 100
        case ..<14: return 70
        case ..<31: return 50
        case ..<90: return 30
        default: return 10
        }
    }

    /// Frecency of an item (0 when never opened).
    func frecency(_ itemID: String, now: Date) -> Double {
        guard let u = usage[itemID] else { return 0 }
        return Double(u.count) * Self.recencyWeight(u.last, now: now)
    }

    /// Ranking boost for `itemID` given the current folded query text.
    /// Frecency is log-scaled and capped so a strong text match still wins;
    /// a remembered query (or one this query is a prefix of) adds more.
    func boost(_ itemID: String, foldedQuery: String, now: Date) -> Double {
        var b = 0.0
        let f = frecency(itemID, now: now)
        if f > 0 { b += min(30, 6 * log2(1 + f / 10)) }
        if !foldedQuery.isEmpty {
            var best = 0.0
            for p in picks where p.itemID == itemID && p.query.hasPrefix(foldedQuery) {
                let exact = p.query == foldedQuery ? 1.0 : 0.6
                let w = Self.recencyWeight(p.last, now: now) / 100
                best = max(best, exact * w * min(1, 0.7 + Double(p.count) * 0.3))
            }
            // Alfred/Raycast: what you picked for this query comes first
            // next time, even over a better text match.
            b += 120 * best
        }
        return b
    }

    /// Most-used items, best first.
    func topItems(limit: Int, now: Date) -> [String] {
        usage.keys.sorted { frecency($0, now: now) > frecency($1, now: now) }.prefix(limit).map { $0 }
    }
}

/// Saves the knowledge as JSON in Application Support/SparkV/UniversalSearch.
struct UniversalSearchKnowledgeFile: Sendable {
    let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/UniversalSearch/knowledge.json")
    }

    func load() -> UniversalSearchKnowledge {
        guard let data = try? Data(contentsOf: url),
              let k = try? Self.decoder.decode(UniversalSearchKnowledge.self, from: data) else { return UniversalSearchKnowledge() }
        return k
    }

    func save(_ k: UniversalSearchKnowledge) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(k).write(to: url, options: .atomic)
        } catch {
            AppLog.log("Universal Search: couldn't save ranking data (\(error.localizedDescription))")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Saves and deletes run in order on one queue, so a save still in flight
    /// can't bring the file back after Clear Search History.
    private static let queue = DispatchQueue(label: "SparkV.UniversalSearch.knowledge", qos: .utility)

    func saveInBackground(_ k: UniversalSearchKnowledge) {
        Self.queue.async { save(k) }
    }

    func deleteInBackground() {
        Self.queue.async { delete() }
    }

    /// Waits for pending saves and deletes (tests).
    static func flush() {
        queue.sync {}
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
