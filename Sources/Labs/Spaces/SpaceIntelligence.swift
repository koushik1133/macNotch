import Foundation
import NaturalLanguage

// On-device intelligence behind Spaces (owned by spaces-core):
// - entity extraction: NLTagger (.nameType) for people, organizations and
//   places, NSDataDetector for links, phone numbers and dates, regexes for
//   emails and domains, plus an organization-suffix heuristic ("… Events",
//   "… Inc") because NLTagger often tags small company names as people;
// - embeddings: NLEmbedding.sentenceEmbedding(.english), else a mean-pooled
//   NLContextualEmbedding (only when its assets are already on disk: nothing
//   is ever downloaded), else hashed bag-of-words TF vectors;
// - the routing agent (rules + learned entity profile + semantic similarity),
//   Inbox clustering for "create Space" proposals, and the extractive helpers
//   used by Q&A and Space memory when the language model isn't available.
//
// Everything here is pure and nonisolated, safe to call from any thread.

enum SpaceIntelligence {
    // MARK: - Entities

    enum EntityKind: String, Codable, Sendable, CaseIterable {
        case person, organization, place, email, domain, url, phone, date
    }

    struct Entity: Codable, Hashable, Sendable {
        var kind: EntityKind
        var value: String

        var key: String { value.lowercased() }

        /// Entities that tell one organization's items apart from another's.
        var isDiscriminative: Bool {
            switch kind {
            case .person, .organization, .email: return true
            case .domain: return !SpaceIntelligence.isGenericDomain(value)
            case .place, .url, .phone, .date: return false
            }
        }

        /// How much a shared entity of this kind says about belonging together.
        var weight: Double {
            switch kind {
            case .organization, .domain: return 1.0
            case .email: return 0.8
            case .person: return 0.7
            default: return 0.2
            }
        }
    }

    struct Analysis: Sendable {
        var entities: [Entity]
        var vector: [Float]
        var model: String
    }

    /// Entities + embedding for one item.
    static func analyze(title: String, text: String, hints: [String: String]) -> Analysis {
        let entities = extractEntities(title: title, text: text, hints: hints)
        let embedded = embed(embeddingText(title: title, text: text))
        return Analysis(entities: entities, vector: embedded.vector, model: embedded.model)
    }

    /// Title + the first ~1500 characters of the body.
    static func embeddingText(title: String, text: String) -> String {
        let body = text.count > 1500 ? String(text.prefix(1500)) : text
        return title.isEmpty ? body : title + "\n" + body
    }

    /// Free-mail and platform domains that say nothing about an organization.
    static let genericDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com",
        "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com", "zoho.com",
        "yandex.com", "mail.com", "google.com", "apple.com", "microsoft.com", "zoom.us", "teams.microsoft.com",
        "meet.google.com", "docs.google.com", "drive.google.com", "calendar.google.com", "linkedin.com",
        "github.com", "slack.com", "notion.so", "dropbox.com", "youtube.com", "x.com", "twitter.com",
        "facebook.com", "instagram.com", "example.com", "localhost",
    ]

    static func isGenericDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        if genericDomains.contains(d) { return true }
        return genericDomains.contains { d.hasSuffix("." + $0) }
    }

    /// "https://www.Helm.events/x" or "@helm.events" → "helm.events".
    static func normalizeDomain(_ raw: String) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where d.hasPrefix(prefix) { d.removeFirst(prefix.count) }
        if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        if let colon = d.firstIndex(of: ":") { d = String(d[..<colon]) }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        while d.hasSuffix(".") { d.removeLast() }
        return d
    }

    private final class Patterns: @unchecked Sendable {
        // NSRegularExpression is immutable and thread-safe once built.
        let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,24}"#)
        let domain = try! NSRegularExpression(
            pattern: #"(?<![@\w.\-])(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+(?:com|net|org|io|ai|co|dev|app|events|in|uk|us|de|fr|es|it|nl|se|ch|au|ca|jp|sg|me|so|xyz|tech|studio|agency|design|cloud|gg|tv|edu|gov|biz|info|health|finance|capital|ventures|media|global|world|travel|shop|store)(?![\w\-])"#,
            options: [.caseInsensitive]
        )
        let organization = try! NSRegularExpression(
            pattern: #"\b((?:[A-Z][\w&'\-]*[ \t]+){0,3}[A-Z][\w&'\-]*[ \t]+(?:Inc|Corp|Corporation|Ltd|Limited|LLC|LLP|GmbH|PLC|Events|Labs|Technologies|Tech|Group|Studios?|Partners|Capital|Bank|University|Foundation|Agency|Solutions|Systems|Media|Ventures|Holdings|Consulting|Industries|Logistics|Health|Pharma|Motors|Airlines|Hotels|Realty|Networks|Software|Analytics|Robotics|Foods|Entertainment|Insurance|Energy))\b\.?"#
        )
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
                | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
                | NSTextCheckingResult.CheckingType.date.rawValue
        )
    }

    private static let patterns = Patterns()

    private static let nameStopwords: Set<String> = [
        "the", "a", "an", "hi", "hello", "dear", "thanks", "thank", "regards", "best", "team", "meeting",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "re", "fwd", "fw", "subject", "from", "to", "cc", "notes", "agenda", "q1", "q2",
        "q3", "q4", "ok", "yes", "no", "i", "we", "you", "me", "my", "our",
    ]

    /// People, organizations, places, emails, domains, links, phones and dates.
    static func extractEntities(title: String, text: String, hints: [String: String]) -> [Entity] {
        let hintText = hints.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
        var body = title + "\n" + text
        if body.count > 20_000 { body = String(body.prefix(20_000)) }
        let full = body + (hintText.isEmpty ? "" : "\n" + hintText)
        let ns = full as NSString
        let range = NSRange(location: 0, length: ns.length)

        var found: [Entity] = []
        var seen: Set<String> = []
        func add(_ kind: EntityKind, _ raw: String) {
            let value = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            guard value.count >= 2, value.count <= 80 else { return }
            let key = kind.rawValue + ":" + value.lowercased()
            guard seen.insert(key).inserted else { return }
            found.append(Entity(kind: kind, value: value))
        }

        // Emails and their domains.
        var emailRanges: [NSRange] = []
        for match in patterns.email.matches(in: full, range: range) {
            let email = ns.substring(with: match.range).lowercased()
            emailRanges.append(match.range)
            add(.email, email)
            add(.domain, normalizeDomain(email))
        }

        // Links, phone numbers, dates.
        if let detector = patterns.detector {
            for match in detector.matches(in: full, range: range) {
                if emailRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                switch match.resultType {
                case .link:
                    guard let url = match.url, let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https", let host = url.host else { continue }
                    add(.url, url.absoluteString)
                    add(.domain, normalizeDomain(host))
                case .phoneNumber:
                    let digits = (match.phoneNumber ?? "").filter(\.isNumber)
                    if digits.count >= 7 { add(.phone, match.phoneNumber ?? "") }
                case .date:
                    add(.date, ns.substring(with: match.range))
                default:
                    break
                }
            }
        }

        // Bare domains ("helm.events") not already seen through emails/links.
        for match in patterns.domain.matches(in: full, range: range) {
            add(.domain, normalizeDomain(ns.substring(with: match.range)))
        }

        // "Helm Events", "Acme Corp": suffix heuristic.
        var organizations: [String] = []
        for match in patterns.organization.matches(in: full, range: NSRange(location: 0, length: min(ns.length, 20_000))) {
            var name = ns.substring(with: match.range(at: 1))
            // Drop a leading sentence word such as "Met Helm Events".
            let words = name.split(separator: " ")
            if words.count > 2, let first = words.first, nameStopwords.contains(first.lowercased()) || leadingVerbs.contains(first.lowercased()) {
                name = words.dropFirst().joined(separator: " ")
            }
            organizations.append(name)
            add(.organization, name)
        }

        // NLTagger names.
        let tagger = NLTagger(tagSchemes: [.nameType])
        let tagged = String(full.prefix(12_000))
        tagger.string = tagged
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: tagged.startIndex..<tagged.endIndex, unit: .word, scheme: .nameType, options: options) { tag, r in
            guard let tag else { return true }
            var name = String(tagged[r])
            // "Contact Rahul Sharma" → "Rahul Sharma".
            let words = name.split(separator: " ")
            if words.count > 1, let first = words.first,
               leadingVerbs.contains(first.lowercased()) || nameStopwords.contains(first.lowercased()) {
                name = words.dropFirst().joined(separator: " ")
            }
            let lower = name.lowercased()
            guard name.count >= 2, !nameStopwords.contains(lower), name.first?.isUppercase == true else { return true }
            // OCR'd or shouted words ("BANGALORE") are rarely names.
            if name.count > 4, name == name.uppercased() { return true }
            // Part of a recognized organization ("Helm" in "Helm Events").
            if organizations.contains(where: { $0.lowercased().contains(lower) }) { return true }
            switch tag {
            case .personalName: add(.person, name)
            case .organizationName: add(.organization, name)
            case .placeName: add(.place, name)
            default: break
            }
            return true
        }

        if found.count > 48 { found = Array(found.prefix(48)) }
        return found
    }

    private static let leadingVerbs: Set<String> = [
        "met", "call", "called", "with", "for", "from", "at", "about", "and", "or", "by", "via", "per", "emailed", "joined",
        "contact", "ask", "email", "ping", "tell", "remind", "thank", "cc", "dear", "hey", "invite", "meet",
    ]

    // MARK: - Embeddings

    private final class Embedder: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false
        private var sentence: NLEmbedding?
        private var contextual: NLContextualEmbedding?
        private(set) var modelID = "hash.bow.512"

        private func load() {
            guard !loaded else { return }
            loaded = true
            if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
                sentence = embedding
                modelID = "nl.sentence.en.r\(embedding.revision).d\(embedding.dimension)"
                return
            }
            // Only use contextual embeddings whose assets are already on disk.
            if let embedding = NLContextualEmbedding(language: .english), embedding.hasAvailableAssets,
               (try? embedding.load()) != nil {
                contextual = embedding
                modelID = "nl.contextual.en.r\(embedding.revision).d\(embedding.dimension)"
            }
        }

        var currentModelID: String {
            lock.lock()
            defer { lock.unlock() }
            load()
            return modelID
        }

        func embed(_ text: String) -> (vector: [Float], model: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock()
            defer { lock.unlock() }
            load()
            guard !trimmed.isEmpty else { return ([], modelID) }
            if let sentence {
                if let vector = sentence.vector(for: trimmed) {
                    return (SpaceIntelligence.normalized(vector.map(Float.init)), modelID)
                }
                return ([], modelID)
            }
            if let contextual, let result = try? contextual.embeddingResult(for: trimmed, language: .english) {
                var sum = [Double](repeating: 0, count: contextual.dimension)
                var count = 0
                result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
                    for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
                    count += 1
                    return true
                }
                guard count > 0 else { return ([], modelID) }
                return (SpaceIntelligence.normalized(sum.map { Float($0 / Double(count)) }), modelID)
            }
            return (SpaceIntelligence.hashedVector(trimmed), modelID)
        }
    }

    private static let embedder = Embedder()

    /// Identifies the vector space in use; vectors from another model are re-made.
    static var embeddingModelID: String { embedder.currentModelID }

    static func embed(_ text: String) -> (vector: [Float], model: String) {
        embedder.embed(text)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine similarity (vectors are stored normalized; still safe if not).
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        var n: Float = 0
        for v in vectors where v.count == first.count {
            for i in 0..<v.count { sum[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return nil }
        return normalized(sum.map { $0 / n })
    }

    /// Maps a raw cosine to 0…1 "how related", calibrated per model
    /// (sentence embeddings: unrelated ≈ 0.45, related ≈ 0.7).
    static func semanticScore(_ cosine: Double, model: String) -> Double {
        let (low, high): (Double, Double)
        if model.hasPrefix("nl.sentence") {
            (low, high) = (0.48, 0.78)
        } else if model.hasPrefix("nl.contextual") {
            (low, high) = (0.80, 0.96)
        } else {
            (low, high) = (0.08, 0.55)
        }
        return min(1, max(0, (cosine - low) / (high - low)))
    }

    /// Feature-hashed bag of words (log TF), 512 buckets; the last fallback.
    static func hashedVector(_ text: String, dimension: Int = 512) -> [Float] {
        var counts: [Int: Float] = [:]
        for term in terms(of: text) {
            let h = fnv1a(term)
            let bucket = Int(h % UInt64(dimension))
            let sign: Float = (h >> 32) & 1 == 0 ? 1 : -1
            counts[bucket, default: 0] += sign
        }
        var v = [Float](repeating: 0, count: dimension)
        for (bucket, c) in counts {
            v[bucket] = c >= 0 ? log(1 + c) : -log(1 - c)
        }
        return normalized(v)
    }

    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    // MARK: - Terms

    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are", "as", "at", "be",
        "because", "been", "before", "being", "below", "between", "both", "but", "by", "can", "could", "did", "do",
        "does", "doing", "down", "during", "each", "few", "for", "from", "further", "had", "has", "have", "having",
        "he", "her", "here", "hers", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "me",
        "more", "most", "my", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other", "our",
        "out", "over", "own", "same", "she", "should", "so", "some", "such", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "those", "through", "to", "too", "under", "until", "up", "very",
        "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would",
        "you", "your", "yours", "also", "get", "got", "let", "us", "re", "fwd", "hi", "hello", "thanks", "please",
        "tell", "know", "say", "said", "did", "does", "anything", "something", "everything",
    ]

    /// Lowercased content words with a light plural strip.
    static func terms(of text: String) -> [String] {
        var out: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            var word = String(raw)
            guard word.count >= 2, !stopwords.contains(word) else { continue }
            if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            out.append(word)
        }
        return out
    }

    /// Whole-word / whole-phrase containment (case-insensitive haystack expected lowercased).
    static func containsPhrase(_ haystack: String, _ phrase: String) -> Bool {
        let needle = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: [], range: searchRange) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !isWordChar(haystack[haystack.index(before: found.lowerBound)])
            let afterOK = found.upperBound == haystack.endIndex || !isWordChar(haystack[found.upperBound])
            if beforeOK && afterOK { return true }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    // MARK: - Routing agent

    /// What a Space's agent knows: its rules, its learned entity profile and
    /// where its items sit in embedding space.
    struct SpaceProfile: Sendable {
        var space: Space
        /// Nearest parent first.
        var ancestorIDs: [UUID]
        var aboutVector: [Float]?
        var centroid: [Float]?
        var itemCount: Int
        /// Entity key → number of this Space's items containing it.
        var entityCounts: [String: Int]
        var entityLabels: [String: String]
    }

    struct RoutingItem: Sendable {
        var title: String
        var text: String
        var hints: [String: String]
        var entities: [Entity]
        var vector: [Float]
        var model: String
    }

    struct SpaceScore: Sendable {
        var spaceID: UUID
        var own: Double
        var effective: Double
        var evidence: [Evidence]
    }

    struct Evidence: Sendable {
        enum Verb: String, Sendable { case mentions, from, shares, reads }
        var verb: Verb
        var label: String
        var weight: Double
        /// Rule/profile evidence (not just semantic resemblance).
        var concrete: Bool
    }

    struct RouteDecision: Sendable {
        var spaceID: UUID
        var confidence: Double
        var reason: String
        var threshold: Double
        /// Backed by rules or shared entities, not only semantic resemblance.
        var concrete: Bool
        var autoFile: Bool { confidence >= threshold }
    }

    private static func noisyOr(_ weights: [Double]) -> Double {
        1 - weights.reduce(1) { $0 * (1 - min(0.99, max(0, $1))) }
    }

    /// Scores every Space; nil when nothing matches at all.
    /// - `entitySpaceCounts`: entity key → number of Spaces whose items contain it.
    static func route(
        _ item: RoutingItem,
        profiles: [SpaceProfile],
        entitySpaceCounts: [String: Int]
    ) -> RouteDecision? {
        let scores = score(item, profiles: profiles, entitySpaceCounts: entitySpaceCounts)
        guard let top = scores.max(by: { $0.effective < $1.effective }), top.effective > 0.05,
              let profile = profiles.first(where: { $0.space.id == top.spaceID })
        else { return nil }
        // Competitors exclude the winner's own ancestors and descendants.
        let lineage = Set(profile.ancestorIDs + [top.spaceID])
        let second = scores
            .filter { s in
                guard !lineage.contains(s.spaceID) else { return false }
                let ancestors = profiles.first { $0.space.id == s.spaceID }?.ancestorIDs ?? []
                return !ancestors.contains(top.spaceID)
            }
            .map(\.effective).max() ?? 0
        let ratio = top.effective > 0 ? second / top.effective : 0
        let confidence = top.effective * (1 - 0.5 * ratio * ratio)
        return RouteDecision(
            spaceID: top.spaceID,
            confidence: (confidence * 1000).rounded() / 1000,
            reason: reason(from: top.evidence),
            threshold: profile.space.rules.autoFileThreshold,
            concrete: top.evidence.contains(where: \.concrete) || (profile.ancestorIDs.first.flatMap { pid in
                scores.first { $0.spaceID == pid }?.evidence.contains(where: \.concrete) } ?? false)
        )
    }

    static func score(
        _ item: RoutingItem,
        profiles: [SpaceProfile],
        entitySpaceCounts: [String: Int]
    ) -> [SpaceScore] {
        var haystack = (item.title + "\n" + item.text).lowercased()
        if haystack.count > 30_000 { haystack = String(haystack.prefix(30_000)) }
        let hintValues = item.hints.values.map { $0.lowercased() }
        let entityValues = item.entities.map { $0.value.lowercased() }
        let hayWithHints = haystack + "\n" + hintValues.joined(separator: "\n") + "\n" + entityValues.joined(separator: "\n")
        let itemAliases = Set(item.entities.compactMap(organizationAlias))
        var itemDomains = Set(item.entities.filter { $0.kind == .domain || $0.kind == .email }.map { normalizeDomain($0.value) })
        for value in hintValues where value.contains(".") && !value.contains(" ") {
            itemDomains.insert(normalizeDomain(value))
        }
        let discriminative = Dictionary(
            item.entities.filter(\.isDiscriminative).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }
        )

        var own: [UUID: (Double, [Evidence])] = [:]
        for profile in profiles {
            var evidence: [Evidence] = []
            let rules = profile.space.rules

            for raw in rules.domains {
                let d = normalizeDomain(raw)
                guard !d.isEmpty else { continue }
                if itemDomains.contains(where: { $0 == d || $0.hasSuffix("." + d) }) || containsPhrase(hayWithHints, d) {
                    evidence.append(Evidence(verb: .mentions, label: d, weight: 0.8, concrete: true))
                }
            }
            for raw in rules.people {
                let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard p.count >= 2 else { continue }
                if containsPhrase(hayWithHints, p) {
                    evidence.append(Evidence(verb: .mentions, label: p, weight: 0.7, concrete: true))
                } else if let first = p.split(separator: " ").first.map(String.init), first.count >= 4, first != p,
                          containsPhrase(haystack, first) {
                    // "send Rahul the floor plan" for rule "Rahul Sharma".
                    evidence.append(Evidence(verb: .mentions, label: first, weight: 0.3, concrete: true))
                }
            }
            // The Space's own name as an organization ("Helm Events", "acmecorp.com" for "Acme Corp").
            if let alias = nameAlias(profile.space.name),
               itemAliases.contains(where: { aliasesMatch($0, alias) }),
               !evidence.contains(where: { $0.weight >= 0.8 }) {
                evidence.append(Evidence(verb: .mentions, label: profile.space.name, weight: 0.72, concrete: true))
            }
            for raw in rules.apps {
                let app = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !app.isEmpty else { continue }
                if hintValues.contains(where: { $0 == app }) {
                    evidence.append(Evidence(verb: .from, label: raw, weight: 0.7, concrete: true))
                }
            }
            var keywordHits = 0
            for raw in rules.keywords where keywordHits < 3 {
                let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard k.count >= 2 else { continue }
                if containsPhrase(haystack, k) {
                    keywordHits += 1
                    evidence.append(Evidence(verb: .mentions, label: "“\(k)”", weight: 0.35, concrete: true))
                }
            }

            // Learned profile: entities this Space's items share with the item.
            var learned: [Evidence] = []
            for (key, entity) in discriminative {
                guard let count = profile.entityCounts[key], count > 0 else { continue }
                // Already a rule hit? Don't count it twice.
                if evidence.contains(where: { $0.label.lowercased() == key }) { continue }
                let support = min(1, Double(count) / 3)
                let exclusivity = 1 / Double(max(1, entitySpaceCounts[key] ?? 1))
                let w = (entity.kind == .person ? 0.4 : 0.5) * support * exclusivity
                guard w > 0.05 else { continue }
                let label = profile.entityLabels[key] ?? entity.value
                learned.append(Evidence(verb: .shares, label: "\(label)|\(count)", weight: w, concrete: true))
            }
            evidence += learned.sorted { $0.weight > $1.weight }.prefix(4)

            // Semantic: the Space's description and the centroid of its items.
            if !item.vector.isEmpty {
                var best = 0.0
                if let about = profile.aboutVector { best = max(best, semanticScore(cosine(item.vector, about), model: item.model)) }
                if let centroid = profile.centroid, profile.itemCount >= 2 {
                    best = max(best, semanticScore(cosine(item.vector, centroid), model: item.model))
                }
                if best > 0 {
                    evidence.append(Evidence(verb: .reads, label: "", weight: 0.5 * best, concrete: false))
                }
            }
            own[profile.space.id] = (noisyOr(evidence.map(\.weight)), evidence)
        }

        // Folders build on their parent: a subfolder with its own concrete
        // evidence inherits the parent's score; otherwise the parent wins.
        var effective: [UUID: Double] = [:]
        func effectiveScore(_ profile: SpaceProfile) -> Double {
            if let cached = effective[profile.space.id] { return cached }
            let (ownScore, evidence) = own[profile.space.id] ?? (0, [])
            var value = ownScore
            let concrete = noisyOr(evidence.filter(\.concrete).map(\.weight))
            if concrete >= 0.15, let parentID = profile.ancestorIDs.first,
               let parent = profiles.first(where: { $0.space.id == parentID }) {
                let parentScore = effectiveScore(parent)
                value = 1 - (1 - ownScore) * (1 - 0.85 * parentScore)
            }
            effective[profile.space.id] = value
            return value
        }
        return profiles.map { profile in
            let (ownScore, evidence) = own[profile.space.id] ?? (0, [])
            return SpaceScore(spaceID: profile.space.id, own: ownScore, effective: effectiveScore(profile), evidence: evidence)
        }
    }

    /// "mentions helm.events and Rahul Sharma; shares Helm Events with 4 items here".
    static func reason(from evidence: [Evidence]) -> String {
        let sorted = evidence.sorted { $0.weight > $1.weight }
        var mentions: [String] = []
        var from: [String] = []
        var shares: [String] = []
        var reads = false
        for e in sorted {
            switch e.verb {
            case .mentions: if mentions.count < 3 { mentions.append(e.label) }
            case .from: if from.count < 1 { from.append(e.label) }
            case .shares:
                if shares.count < 2 {
                    let parts = e.label.split(separator: "|", maxSplits: 1).map(String.init)
                    let count = Int(parts.last ?? "") ?? 0
                    shares.append("\(parts.first ?? "") with \(count) item\(count == 1 ? "" : "s") here")
                }
            case .reads: reads = true
            }
        }
        var parts: [String] = []
        if !mentions.isEmpty { parts.append("mentions " + list(mentions)) }
        if !from.isEmpty { parts.append("from " + list(from)) }
        if !shares.isEmpty { parts.append("shares " + list(shares)) }
        if parts.isEmpty && reads { parts.append("reads like this Space") }
        return parts.joined(separator: "; ")
    }

    static func list(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return values[0] + " and " + values[1]
        default: return values.dropLast().joined(separator: ", ") + " and " + values[values.count - 1]
        }
    }

    // MARK: - Organization aliases

    /// A short key tying an organization to its domain: "Bluefin Labs" →
    /// "bluefin", "bluefin.io" → "bluefin", "acmecorp.com" → "acmecorp".
    static func organizationAlias(_ entity: Entity) -> String? {
        switch entity.kind {
        case .organization:
            return nameAlias(entity.value)
        case .domain:
            guard !isGenericDomain(entity.value) else { return nil }
            var labels = normalizeDomain(entity.value).split(separator: ".").map(String.init)
            guard labels.count >= 2 else { return nil }
            labels.removeLast()
            if ["co", "com", "org", "net", "ac", "gov"].contains(labels.last ?? ""), labels.count >= 2 { labels.removeLast() }
            guard let core = labels.last, core.count >= 3 else { return nil }
            return core
        default:
            return nil
        }
    }

    /// First distinctive word of a name, lowercased ("The Helm Events" → "helm").
    static func nameAlias(_ name: String) -> String? {
        let words = name.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        return words.first { $0.count >= 3 && !stopwords.contains($0) && !nameStopwords.contains($0) }
    }

    /// Same alias, or one a prefix of the other ("acme" / "acmecorp").
    static func aliasesMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    // MARK: - Clustering (Inbox → "create Space" proposals)

    struct ClusterCandidate: Sendable {
        var id: UUID
        var title: String
        var entities: [Entity]
        var vector: [Float]
        var model: String
    }

    struct ClusterProposal: Sendable {
        var name: String
        var itemIDs: [UUID]
        var reason: String
    }

    /// Average-linkage agglomerative clustering on a blend of shared
    /// discriminative entities and embedding cosine; clusters of ≥ 3 items
    /// (≥ 2 when they share an organization or domain) become proposals named
    /// after their dominant organization / domain.
    static func cluster(
        _ candidates: [ClusterCandidate],
        existingNames: Set<String>,
        reservedTerms: Set<String> = [],
        threshold: Double = 0.33
    ) -> [ClusterProposal] {
        let items = Array(candidates.prefix(300))
        let n = items.count
        guard n >= 2 else { return [] }

        // Entity document frequency: very common entities (the user's own name)
        // carry little signal.
        var df: [String: Int] = [:]
        // Canonical aliases: "acmecorp" folds into "acme" when both occur.
        let rawAliases = Set(items.flatMap { $0.entities.compactMap(organizationAlias) })
        func canonical(_ alias: String) -> String {
            rawAliases.filter { $0.count < alias.count && aliasesMatch($0, alias) }.min { $0.count < $1.count } ?? alias
        }
        let entitySets: [[String: Entity]] = items.map { item in
            var set = Dictionary(item.entities.filter(\.isDiscriminative).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            for alias in Set(item.entities.compactMap(organizationAlias).map(canonical)) {
                set["~" + alias] = Entity(kind: .organization, value: "~" + alias)
            }
            return set
        }
        for set in entitySets { for key in set.keys { df[key, default: 0] += 1 } }
        func idf(_ key: String) -> Double {
            let fraction = Double(df[key] ?? 1) / Double(n)
            return fraction > 0.6 && n >= 6 ? 0.2 : 1
        }
        let norms: [Double] = entitySets.map { set in set.values.reduce(0) { $0 + $1.weight * idf($1.key) } }

        var sim = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var shared = 0.0
                for (key, e) in entitySets[i] where entitySets[j][key] != nil { shared += e.weight * idf(key) }
                let entitySim = norms[i] > 0 && norms[j] > 0 ? min(1, shared / (norms[i] * norms[j]).squareRoot()) : 0
                let sem = semanticScore(cosine(items[i].vector, items[j].vector), model: items[i].model)
                let s = entitySim > 0 ? 0.7 * entitySim + 0.3 * sem : 0.35 * sem
                sim[i][j] = s
                sim[j][i] = s
            }
        }

        // Linkage = mean of average and maximum pair similarity: average
        // linkage alone splits an organization whose items share different
        // people; single linkage alone chains unrelated groups.
        var maxSim = sim
        var members: [[Int]] = (0..<n).map { [$0] }
        var active = [Bool](repeating: true, count: n)
        while true {
            var best = threshold
            var pair: (Int, Int)?
            for i in 0..<n where active[i] {
                for j in (i + 1)..<n where active[j] {
                    let linkage = 0.5 * (sim[i][j] + maxSim[i][j])
                    if linkage >= best {
                        best = linkage
                        pair = (i, j)
                    }
                }
            }
            guard let (a, b) = pair else { break }
            let sa = Double(members[a].count), sb = Double(members[b].count)
            for k in 0..<n where active[k] && k != a && k != b {
                let merged = (sa * sim[a][k] + sb * sim[b][k]) / (sa + sb)
                sim[a][k] = merged
                sim[k][a] = merged
                let m = max(maxSim[a][k], maxSim[b][k])
                maxSim[a][k] = m
                maxSim[k][a] = m
            }
            members[a] += members[b]
            members[b] = []
            active[b] = false
        }

        var byName: [String: (name: String, ids: [UUID], reasons: [String])] = [:]
        let taken = Set(existingNames.map { $0.lowercased() })
        let takenAliases = existingNames.compactMap(nameAlias)
        let reserved = Set(reservedTerms.map { $0.lowercased() })
        for i in 0..<n where active[i] && members[i].count >= 2 {
            let group = members[i]
            var coverage: [String: (entity: Entity, count: Int)] = [:]
            for index in group {
                for (key, entity) in entitySets[index] where !key.hasPrefix("~") {
                    coverage[key, default: (entity, 0)].count += 1
                }
            }
            let size = Double(group.count)
            let ranked = coverage.values.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.entity.weight > $1.entity.weight
            }
            let org = ranked.first { $0.entity.kind == .organization && Double($0.count) / size >= 0.5 }
            let domain = ranked.first { $0.entity.kind == .domain && Double($0.count) / size >= 0.5 }
            let person = ranked.first { $0.entity.kind == .person && Double($0.count) / size >= 0.6 }
            let strong = org != nil || domain != nil
            guard group.count >= 3 || (strong && group.count >= 2) else { continue }

            let name: String
            if let org { name = org.entity.value }
            else if let domain { name = prettyName(forDomain: domain.entity.value) }
            else if let person { name = person.entity.value }
            else if let keyword = dominantKeyword(group.map { items[$0].title }) { name = keyword.capitalized }
            else { continue }
            // Already a Space (or one of its rules): those items get .file suggestions instead.
            guard !taken.contains(name.lowercased()), !reserved.contains(name.lowercased()) else { continue }
            if let alias = nameAlias(name), takenAliases.contains(where: { aliasesMatch($0, alias) }) { continue }

            let labels = [org?.entity.value, domain?.entity.value, person?.entity.value].compactMap { $0 }
            let reason = labels.isEmpty
                ? "\(group.count) Inbox items read alike"
                : "\(group.count) Inbox items mention " + list(Array(labels.prefix(2)))
            let key = name.lowercased()
            var entry = byName[key] ?? (name, [], [])
            entry.ids += group.map { items[$0].id }
            entry.reasons.append(reason)
            byName[key] = entry
        }
        return byName.values
            .map { entry in
                let reason = entry.reasons.count == 1
                    ? entry.reasons[0]
                    : "\(entry.ids.count) Inbox items mention \(entry.name)"
                return ClusterProposal(name: entry.name, itemIDs: entry.ids, reason: reason)
            }
            .sorted { $0.itemIDs.count > $1.itemIDs.count }
    }

    /// "helm.events" → "Helm Events"; "acmecorp.com" → "Acmecorp"; "mail.acme.co.uk" → "Acme".
    static func prettyName(forDomain domain: String) -> String {
        let d = normalizeDomain(domain)
        var labels = d.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return d.capitalized }
        let tld = labels.removeLast()
        if ["co", "com", "org", "net", "ac", "gov"].contains(labels.last ?? ""), labels.count >= 2 { labels.removeLast() }
        let core = labels.last ?? d
        let wordTLDs: Set<String> = ["events", "studio", "agency", "design", "capital", "ventures", "media", "health", "finance", "travel"]
        return wordTLDs.contains(tld) ? "\(core.capitalized) \(tld.capitalized)" : core.capitalized
    }

    private static func dominantKeyword(_ titles: [String]) -> String? {
        var counts: [String: Int] = [:]
        for title in titles { for term in Set(terms(of: title)) where term.count >= 4 { counts[term, default: 0] += 1 } }
        guard let best = counts.max(by: { $0.value < $1.value }), Double(best.value) >= Double(titles.count) * 0.6 else { return nil }
        return best.key
    }

    // MARK: - Passages & extractive answers

    static func sentences(of text: String, limit: Int = 400) -> [String] {
        var out: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for paragraph in text.components(separatedBy: .newlines) {
            let p = paragraph.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            tokenizer.string = p
            tokenizer.enumerateTokens(in: p.startIndex..<p.endIndex) { r, _ in
                let s = p[r].trimmingCharacters(in: .whitespacesAndNewlines)
                if s.count >= 3 { out.append(s) }
                return out.count < limit
            }
            if out.count >= limit { break }
        }
        return out
    }

    static func sentenceScore(_ sentence: String, terms queryTerms: Set<String>) -> Double {
        guard !queryTerms.isEmpty else { return 0 }
        let words = terms(of: sentence)
        guard !words.isEmpty else { return 0 }
        let hits = Set(words).intersection(queryTerms).count
        guard hits > 0 else { return 0 }
        return Double(hits) / Double(queryTerms.count) + 0.15 * Double(hits) / Double(words.count).squareRoot()
    }

    /// The parts of `text` most relevant to `queryTerms`, in reading order,
    /// within `budget` characters (the beginning when nothing matches).
    static func passage(of text: String, terms queryTerms: Set<String>, budget: Int) -> String {
        guard text.count > budget else { return text }
        let all = sentences(of: text)
        let scored = all.enumerated().map { ($0.offset, sentenceScore($0.element, terms: queryTerms)) }
        guard scored.contains(where: { $0.1 > 0 }) else { return String(text.prefix(budget)) }
        var chosen: Set<Int> = []
        var used = 0
        for (index, score) in scored.sorted(by: { $0.1 > $1.1 }) where score > 0 {
            // Take the sentence and its neighbour for context.
            for i in [index, index + 1] where i < all.count && !chosen.contains(i) {
                let cost = all[i].count + 1
                if used + cost > budget { continue }
                chosen.insert(i)
                used += cost
            }
            if used >= budget - 40 { break }
        }
        if chosen.isEmpty { return String(text.prefix(budget)) }
        var out: [String] = []
        var last = -2
        for i in chosen.sorted() {
            if last >= 0 && i != last + 1 { out.append("…") }
            out.append(all[i])
            last = i
        }
        return out.joined(separator: " ")
    }

    struct Source: Sendable {
        var number: Int
        var itemID: UUID
        var title: String
        var text: String
    }

    /// Best-matching sentences with [n] citations; used when the model is unavailable.
    static func extractiveAnswer(question: String, sources: [Source]) -> (text: String, cited: [UUID]) {
        let queryTerms = Set(terms(of: question))
        var scored: [(score: Double, sentence: String, source: Source)] = []
        for source in sources {
            for sentence in sentences(of: source.title + ". " + source.text, limit: 300) {
                let s = sentenceScore(sentence, terms: queryTerms)
                if s > 0 { scored.append((s - Double(source.number) * 0.001, sentence, source)) }
            }
        }
        scored.sort { $0.score > $1.score }
        var picked: [(String, Source)] = []
        var seen: Set<String> = []
        for entry in scored where picked.count < 3 {
            let key = entry.sentence.lowercased()
            guard seen.insert(key).inserted else { continue }
            picked.append((entry.sentence, entry.source))
        }
        guard !picked.isEmpty else {
            if let first = sources.first {
                return ("I couldn't find that directly. The closest item is “\(first.title)” [\(first.number)].", [first.itemID])
            }
            return ("I couldn't find anything about that.", [])
        }
        var cited: [UUID] = []
        let lines = picked.map { sentence, source -> String in
            if !cited.contains(source.itemID) { cited.append(source.itemID) }
            var s = sentence
            if s.count > 320 { s = String(s.prefix(320)) + "…" }
            return "\(s) [\(source.number)]"
        }
        return (lines.joined(separator: " "), cited)
    }

    /// Citation numbers in a model reply: "[1]", "[2, 3]", "[1][4]".
    static func citations(in text: String) -> [Int] {
        var numbers: [Int] = []
        var i = text.startIndex
        while let open = text[i...].firstIndex(of: "[") {
            guard let close = text[open...].firstIndex(of: "]") else { break }
            let inside = text[text.index(after: open)..<close]
            for part in inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }) {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)), !numbers.contains(n) { numbers.append(n) }
            }
            i = text.index(after: close)
        }
        return numbers
    }

    /// Rewrites the [n] markers so they count the cited items in order of
    /// first appearance (1, 2, 3…), matching the citation list shown under
    /// the answer; markers that point at no source are dropped.
    static func renumberCitations(_ text: String, sources: [Source]) -> (text: String, cited: [UUID]) {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*[,;]\s*\d{1,3})*)\]"#) else { return (text, []) }
        let ns = text as NSString
        var cited: [UUID] = []
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            var numbers: [Int] = []
            for part in ns.substring(with: match.range(at: 1)).split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
                guard let n = Int(part), let source = sources.first(where: { $0.number == n }) else { continue }
                if !cited.contains(source.itemID) { cited.append(source.itemID) }
                if let index = cited.firstIndex(of: source.itemID), !numbers.contains(index + 1) { numbers.append(index + 1) }
            }
            if numbers.isEmpty {
                // Drop the marker and the space before it.
                while output.hasSuffix(" ") { output.removeLast() }
            } else {
                output += numbers.map { "[\($0)]" }.joined()
            }
        }
        output += ns.substring(from: cursor)
        return (output, cited)
    }

    /// Memory without the model: who and what the Space is about, plus recent items.
    static func extractiveMemory(spaceName: String, itemCount: Int, entities: [Entity], recentTitles: [String]) -> String {
        var counts: [EntityKind: [String: Int]] = [:]
        var labels: [String: String] = [:]
        for e in entities where e.isDiscriminative || e.kind == .place {
            counts[e.kind, default: [:]][e.key, default: 0] += 1
            labels[e.key] = labels[e.key] ?? e.value
        }
        func top(_ kind: EntityKind, _ k: Int) -> [String] {
            (counts[kind] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(k).compactMap { labels[$0.key] }
        }
        var lines = ["\(spaceName): \(itemCount) item\(itemCount == 1 ? "" : "s")."]
        let orgs = top(.organization, 3), people = top(.person, 4), domains = top(.domain, 3)
        if !orgs.isEmpty { lines.append("Organizations: " + orgs.joined(separator: ", ") + ".") }
        if !people.isEmpty { lines.append("People: " + people.joined(separator: ", ") + ".") }
        if !domains.isEmpty { lines.append("Domains: " + domains.joined(separator: ", ") + ".") }
        if !recentTitles.isEmpty { lines.append("Recent: " + recentTitles.prefix(5).joined(separator: "; ") + ".") }
        return lines.joined(separator: "\n")
    }
}
