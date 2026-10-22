import Foundation

/// Deterministic resume → `ResumeProfile`: section headers, date ranges for
/// roles (total years = union of intervals), degree lines, the skills
/// dictionary plus the resume's own Skills section.
enum JobResumeParser {
    enum Section: String {
        case header, summary, experience, education, skills, projects, other
    }

    static let sectionHeaders: [(Section, [String])] = [
        (.summary, ["summary", "professional summary", "profile", "about me", "objective", "career summary", "overview"]),
        (.experience, ["experience", "work experience", "professional experience", "employment", "employment history",
                       "work history", "career history", "relevant experience"]),
        (.education, ["education", "education and training", "academic background", "academics"]),
        (.skills, ["skills", "technical skills", "core skills", "key skills", "technologies", "tech stack", "core competencies",
                   "competencies", "tools", "skills & tools", "skills and tools", "languages & tools", "expertise"]),
        (.projects, ["projects", "selected projects", "personal projects", "side projects", "open source"]),
        (.other, ["certifications", "certificates", "awards", "publications", "volunteering", "volunteer experience",
                  "interests", "references", "languages", "honors", "activities", "leadership"]),
    ]

    static func section(forHeader line: String) -> Section? {
        let cleaned = line.lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "&")))
            .replacingOccurrences(of: "  ", with: " ")
        guard !cleaned.isEmpty, cleaned.count <= 34 else { return nil }
        for (section, names) in sectionHeaders where names.contains(cleaned) { return section }
        return nil
    }

    static func split(_ text: String) -> [(Section, [String])] {
        var result: [(Section, [String])] = [(.header, [])]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let section = section(forHeader: line) {
                result.append((section, []))
                continue
            }
            if line.isEmpty { continue }
            result[result.count - 1].1.append(line)
        }
        return result
    }

    static func parse(_ text: String, fileName: String = "") -> ResumeProfile {
        var profile = ResumeProfile()
        profile.fileName = fileName
        let sections = split(text)
        let header = sections.first { $0.0 == .header }?.1 ?? []
        profile.name = guessName(header)
        profile.headline = header.dropFirst().first { line in
            !looksLikeContact(line) && line.count <= 80 && JobPostingParser.roleWordRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        } ?? ""
        profile.summary = sections.filter { $0.0 == .summary }.flatMap(\.1).joined(separator: " ")

        let skillLines = sections.filter { $0.0 == .skills }.flatMap(\.1)
        profile.declaredSkills = declaredSkills(skillLines)

        let experienceLines = sections.filter { $0.0 == .experience }.flatMap(\.1)
        profile.experience = parseExperience(experienceLines.isEmpty ? text.components(separatedBy: "\n") : experienceLines)

        let educationLines = sections.filter { $0.0 == .education }.flatMap(\.1)
        profile.education = parseEducation(educationLines.isEmpty ? text.components(separatedBy: "\n") : educationLines)

        var skills = JobSkills.names(in: text)
        for declared in profile.declaredSkills where !skills.contains(declared) { skills.append(declared) }
        profile.skills = skills

        let fromRoles = totalYears(profile.experience)
        let stated = statedYears(profile.summary.isEmpty ? String(text.prefix(1500)) : profile.summary)
        switch (fromRoles, stated) {
        case let (roles?, stated?): profile.yearsExperience = max(roles, stated)
        case let (roles?, nil): profile.yearsExperience = roles
        case let (nil, stated?): profile.yearsExperience = stated
        default: profile.yearsExperience = nil
        }
        profile.source = "dictionary"
        return profile
    }

    // MARK: Header

    static func looksLikeContact(_ line: String) -> Bool {
        line.contains("@") || line.range(of: "\\d{3}[\\s.\\-)]+\\d{3}[\\s.\\-]+\\d{4}", options: .regularExpression) != nil
            || line.lowercased().contains("linkedin.com") || line.lowercased().contains("github.com")
            || line.lowercased().hasPrefix("http")
    }

    static func guessName(_ header: [String]) -> String {
        for line in header.prefix(4) {
            let words = line.split(separator: " ")
            guard (2...4).contains(words.count), !looksLikeContact(line), line.count <= 40 else { continue }
            if words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || $0 == "-" || $0 == "." || $0 == "'" } }) {
                return line
            }
        }
        return ""
    }

    // MARK: Skills section

    static func declaredSkills(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            // "Languages: Swift, Kotlin" → drop the label.
            let body = line.range(of: ":").map { String(line[$0.upperBound...]) } ?? line
            let items = body.components(separatedBy: CharacterSet(charactersIn: ",;|•·/"))
            for item in items {
                let trimmed = item.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.count <= 32 else { continue }
                let name = JobSkills.canonical(trimmed) ?? (trimmed.split(separator: " ").count <= 3 && trimmed.first?.isLetter == true ? trimmed : nil)
                if let name, !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    result.append(name)
                }
            }
        }
        // Dictionary hits inside long skill sentences.
        for name in JobSkills.names(in: lines.joined(separator: "\n")) where !result.contains(name) {
            result.append(name)
        }
        return result
    }

    // MARK: Experience

    static let monthNames: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12,
    ]

    static let datePattern = "(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?\\s+\\d{4}|\\d{1,2}/\\d{4}|\\d{4})"
    static let rangeRegex = try? NSRegularExpression(
        pattern: "(" + datePattern + ")\\s*(?:-|–|—|to|until)\\s*(" + datePattern + "|present|current|now|today)",
        options: [.caseInsensitive]
    )

    /// (start, end) as month indices (year*12+month-1).
    static func parseRange(_ line: String, now: Date = Date()) -> (start: String, end: String, months: Int)? {
        guard let regex = rangeRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(match.range(at: 1), in: line), let r2 = Range(match.range(at: 2), in: line) else { return nil }
        let startText = String(line[r1]), endText = String(line[r2])
        guard let start = monthIndex(startText, isEnd: false, now: now), let end = monthIndex(endText, isEnd: true, now: now),
              end >= start, end - start < 12 * 50 else { return nil }
        return (startText, endText, end - start + 1)
    }

    static func monthIndex(_ text: String, isEnd: Bool, now: Date) -> Int? {
        let lower = text.lowercased()
        let calendar = Calendar(identifier: .gregorian)
        if ["present", "current", "now", "today"].contains(lower) {
            let c = calendar.dateComponents([.year, .month], from: now)
            return (c.year ?? 2026) * 12 + (c.month ?? 1) - 1
        }
        if lower.contains("/") {
            let parts = lower.split(separator: "/")
            guard parts.count == 2, let m = Int(parts[0]), let y = Int(parts[1]), (1...12).contains(m) else { return nil }
            return y * 12 + m - 1
        }
        let words = lower.split(separator: " ")
        if words.count == 2, let y = Int(words[1]) {
            let key = String(words[0].prefix(4)).replacingOccurrences(of: ".", with: "")
            let month = monthNames[key] ?? monthNames[String(key.prefix(3))] ?? 1
            return y * 12 + month - 1
        }
        if let y = Int(lower), (1950...2100).contains(y) { return y * 12 + (isEnd ? 11 : 0) }
        return nil
    }

    static func parseExperience(_ lines: [String]) -> [ResumeExperience] {
        var roles: [ResumeExperience] = []
        var previousNonBullet: String?
        for (index, line) in lines.enumerated() {
            let isBullet = line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("–") || line.hasPrefix("▪")
            if !isBullet, let range = parseRange(line) {
                var stripped = stripRange(line)
                // "Data Engineer at Northwind (2020 to now): built …" — the tail is a highlight.
                var inlineHighlight: String?
                if let cut = stripped.range(of: "\\s*(?:\\(\\s*\\)|\\(|:|;|\\.\\s|,\\s*\\.\\s)", options: .regularExpression),
                   stripped.distance(from: stripped.startIndex, to: cut.lowerBound) >= 3 {
                    let tail = String(stripped[cut.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ():;.,"))
                    if tail.count > 15 { inlineHighlight = tail }
                    stripped = String(stripped[..<cut.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                }
                var (title, company) = splitTitleCompany(stripped)
                if title.isEmpty, company.isEmpty, let previous = previousNonBullet {
                    (title, company) = splitTitleCompany(previous)
                } else if company.isEmpty, let previous = previousNonBullet, roles.last?.title != previous,
                          index > 0, lines[index - 1] == previous {
                    // "Acme Corp" on the line above, "Senior Engineer  Jan 2020 – Present" here.
                    company = previous
                }
                roles.append(ResumeExperience(title: title, company: company, start: range.start, end: range.end,
                                              months: range.months, highlights: inlineHighlight.map { [$0] } ?? []))
            } else if isBullet, !roles.isEmpty {
                let bullet = line.drop { "•-*–▪ ".contains($0) }
                roles[roles.count - 1].highlights.append(String(bullet).trimmingCharacters(in: .whitespaces))
            } else if !roles.isEmpty, line.count > 60, roles[roles.count - 1].highlights.count < 12,
                      index + 1 < lines.count, parseRange(lines[index + 1]) == nil, line.first?.isUppercase == true {
                // Sentence-style highlight without a bullet glyph.
                roles[roles.count - 1].highlights.append(line)
            }
            if !isBullet { previousNonBullet = line }
        }
        return roles
    }

    static func stripRange(_ line: String) -> String {
        guard let regex = rangeRegex else { return line }
        let stripped = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        return stripped.trimmingCharacters(in: CharacterSet(charactersIn: " ,|·•()–—-\t"))
    }

    /// "Senior iOS Engineer, Acme Corp" / "Acme Corp — Senior iOS Engineer" / "Senior iOS Engineer at Acme".
    static func splitTitleCompany(_ text: String) -> (String, String) {
        let separators = [" at ", " @ ", " | ", " — ", " – ", " - ", ", ", " · "]
        for separator in separators {
            guard let range = text.range(of: separator) else { continue }
            let a = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let b = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,|·"))
            let aRole = isRoleLike(a), bRole = isRoleLike(b)
            if aRole && !bRole { return (a, b) }
            if bRole && !aRole { return (b, a) }
            return separator == " at " || separator == " @ " ? (a, b) : (a, b)
        }
        return isRoleLike(text) ? (text, "") : ("", text)
    }

    static func isRoleLike(_ text: String) -> Bool {
        JobPostingParser.roleWordRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Union of role intervals in years (overlaps counted once).
    static func totalYears(_ roles: [ResumeExperience], now: Date = Date()) -> Double? {
        var intervals: [(Int, Int)] = []
        for role in roles {
            guard let s = monthIndex(role.start, isEnd: false, now: now), let e = monthIndex(role.end, isEnd: true, now: now) else { continue }
            intervals.append((s, e))
        }
        guard !intervals.isEmpty else { return nil }
        intervals.sort { $0.0 < $1.0 }
        var total = 0
        var current = intervals[0]
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 + 1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0 + 1
                current = interval
            }
        }
        total += current.1 - current.0 + 1
        return (Double(total) / 12 * 10).rounded() / 10
    }

    /// "8+ years of experience" in the summary.
    static func statedYears(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,2}(?:\\.\\d)?)\\+?\\s*(?:years|yrs)", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    // MARK: Education

    /// Spelled-out degrees (any case).
    static let degreeWords: [(String, Int)] = [
        ("ph\\.?\\s?d|doctorate|doctor of", 4),
        ("master(?:'s|s)?|mba", 3),
        ("bachelor(?:'s|s)?|undergraduate degree", 2),
        ("associate(?:'s)? degree", 1),
    ]
    /// Abbreviations (case-sensitive), counted only with education context.
    static let degreeAbbreviations: [(String, Int)] = [
        ("M\\.?S\\.?c?|M\\.?A\\.|M\\.?Eng|M\\.?Tech|MSc|MEng", 3),
        ("B\\.?S\\.?c?|B\\.?A\\.|B\\.?Eng|B\\.?Tech|B\\.?E\\.|BSc|BEng|BTech", 2),
        ("A\\.?A\\.?S?\\.", 1),
    ]

    /// Highest degree named on the line (0 none).
    static func degreeLevel(_ line: String) -> Int {
        degreeLevels(line).max() ?? 0
    }

    /// Every degree level named on the line ("BS/MS in CS" → [2, 3]).
    static func degreeLevels(_ raw: String) -> [Int] {
        let line = raw.replacingOccurrences(of: "(?i)scrum master|master data|webmaster|master branch|masterclass", with: "", options: .regularExpression)
        var levels: Set<Int> = []
        for (pattern, level) in degreeWords
        where line.range(of: "(?<![A-Za-z])(?:" + pattern + ")(?![A-Za-z])", options: [.regularExpression, .caseInsensitive]) != nil {
            levels.insert(level)
        }
        let context = line.range(of: "\\b(in|of)\\s+[A-Z]|University|College|Institute|School|[Dd]egree|PhD|Ph\\.D", options: .regularExpression) != nil
        if context || !levels.isEmpty {
            for (pattern, level) in degreeAbbreviations
            where line.range(of: "(?<![A-Za-z])(?:" + pattern + ")(?![A-Za-z])", options: .regularExpression) != nil {
                levels.insert(level)
            }
        }
        return levels.sorted()
    }

    static func parseEducation(_ lines: [String]) -> [ResumeEducation] {
        var result: [ResumeEducation] = []
        for (index, line) in lines.enumerated() {
            let level = degreeLevel(line)
            guard level > 0, line.count <= 160 else { continue }
            let year = line.range(of: "(19|20)\\d{2}", options: .regularExpression).map { String(line[$0]) } ?? ""
            var field = ""
            if let range = line.range(of: "(?:in|of)\\s+([A-Z][A-Za-z &]+)", options: .regularExpression) {
                field = String(line[range]).replacingOccurrences(of: "^(in|of)\\s+", with: "", options: .regularExpression)
                field = field.components(separatedBy: CharacterSet(charactersIn: ",|–—")).first?.trimmingCharacters(in: .whitespaces) ?? field
            }
            var school = ""
            let candidates = [line] + (index + 1 < lines.count ? [lines[index + 1]] : []) + (index > 0 ? [lines[index - 1]] : [])
            for candidate in candidates {
                if let range = candidate.range(of: "[A-Z][A-Za-z.&' ]*(University|College|Institute|School|Academy|Polytechnic)[A-Za-z.&' ]*", options: .regularExpression) {
                    school = String(candidate[range]).trimmingCharacters(in: .whitespaces)
                    break
                }
                if let range = candidate.range(of: "(University|Institute) of [A-Z][A-Za-z ]+", options: .regularExpression) {
                    school = String(candidate[range]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            var degree = line.components(separatedBy: CharacterSet(charactersIn: ",|–—")).first?.trimmingCharacters(in: .whitespaces) ?? line
            degree = degree.replacingOccurrences(of: "^(?i:education|degree)\\s*:\\s*", with: "", options: .regularExpression)
            result.append(ResumeEducation(degree: degree, field: field, school: school, year: year, level: level))
        }
        return result
    }
}
