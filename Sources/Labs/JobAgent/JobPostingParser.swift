import CoreGraphics
import Foundation

/// Deterministic job-posting extraction from OCR text plus the browser's
/// URL and page title. Field names follow schema.org `JobPosting`.
enum JobPostingParser {
    // MARK: Shared patterns

    static let roleWordRegex: NSRegularExpression = {
        let words = "engineer|engineering manager|developer|designer|manager|analyst|scientist|specialist|lead|director|intern|internship|architect|consultant|coordinator|administrator|associate|representative|technician|writer|recruiter|programmer|officer|head of|vp|vice president|strategist|researcher|editor|accountant|advisor|executive|assistant|product owner|sre|devops|tester|marketer|producer|artist|teacher|nurse|operator|planner|buyer|controller|counsel|attorney|paralegal|swe|sde|staff|principal|fellow"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "\\b(?:" + words + ")s?\\b", options: [.caseInsensitive])
    }()

    static func hasRoleWord(_ text: String) -> Bool {
        roleWordRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    enum Header: String { case requirements, preferred, responsibilities, other }

    static let headerKeys: [(Header, [String])] = [
        (.preferred, ["preferred qualifications", "preferred skills", "preferred experience", "nice to have", "nice to haves",
                      "nice-to-have", "nice-to-haves", "bonus points", "bonus", "pluses", "preferred", "it would be great if",
                      "extra credit", "even better if", "ideally you have", "good to have", "desired qualifications", "desired skills"]),
        (.requirements, ["requirements", "qualifications", "minimum qualifications", "basic qualifications", "required qualifications",
                         "what you'll need", "what you will need", "what we're looking for", "what we are looking for", "what you bring",
                         "what you'll bring", "you have", "you might be a fit if", "who you are", "must have", "must haves", "must-haves",
                         "skills and experience", "about you", "your experience", "required skills", "what you need", "skills & experience",
                         "experience and skills", "requirements and qualifications", "job requirements", "your profile", "what you'll need to succeed",
                         "we'd love to hear from you if", "you're a great fit if", "you will have", "key qualifications", "skills"]),
        (.responsibilities, ["responsibilities", "what you'll do", "what you will do", "the role", "about the role", "your role",
                             "in this role", "key responsibilities", "day to day", "your responsibilities", "job description",
                             "role overview", "what you'll be doing", "the opportunity", "about the job", "overview", "duties"]),
        (.other, ["benefits", "perks", "perks & benefits", "about us", "about the company", "compensation", "salary", "pay range",
                  "equal opportunity", "equal employment opportunity", "why join", "why join us", "what we offer", "how to apply",
                  "our values", "who we are", "about the team", "life at", "our benefits", "total rewards", "location", "eeo statement",
                  "pay transparency", "additional information", "apply for this job", "similar jobs", "more jobs", "people also viewed"]),
    ]

    static func normalizedHeader(_ line: String) -> String {
        line.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'+")))
    }

    static func header(of line: String) -> Header? {
        let n = normalizedHeader(line)
        guard !n.isEmpty, n.count <= 200, !line.hasPrefix("•"), !line.hasPrefix("-") else { return nil }
        let lowerLine = line.lowercased().replacingOccurrences(of: "’", with: "'")
        for (header, keys) in headerKeys {
            for key in keys {
                if n == key { return header }
                // "Requirements:" / "Requirements: 5 years Swift" (the caller keeps the tail),
                // or a short decorated variant ("Requirements (must have)").
                if lowerLine.hasPrefix(key + ":") || (n.hasPrefix(key) && n.count <= key.count + 4) {
                    return header
                }
            }
        }
        if n.hasPrefix("about ") && n.count <= 40 && !hasRoleWord(n) { return .other }
        return nil
    }

    // MARK: URL

    struct URLInfo: Sendable, Equatable {
        var source = ""
        var companySlug = ""
        var jobID = ""
        var host = ""
        var isConfirmationPath = false
        var isApplyPath = false
    }

    static func urlInfo(_ raw: String) -> URLInfo {
        var info = URLInfo()
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), let host = url.host?.lowercased() else { return info }
        info.host = host
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
        let lowerPath = url.path.lowercased()
        info.isConfirmationPath = lowerPath.hasSuffix("/confirmation") || lowerPath.hasSuffix("/thanks") || lowerPath.hasSuffix("/thank-you")
            || lowerPath.contains("post-apply") || lowerPath.contains("/applied") || lowerPath.contains("application-submitted")
            || lowerPath.contains("/success")
        info.isApplyPath = lowerPath.hasSuffix("/apply") || lowerPath.hasSuffix("/application") || lowerPath.contains("/apply/")

        if host.contains("greenhouse.io") {
            info.source = "Greenhouse"
            if let jobs = parts.firstIndex(of: "jobs") {
                if jobs > 0 { info.companySlug = parts[jobs - 1] }
                if jobs + 1 < parts.count { info.jobID = parts[jobs + 1] }
            }
            if info.companySlug.isEmpty { info.companySlug = q("for") }
            if info.jobID.isEmpty { info.jobID = q("token") }
        } else if !q("gh_jid").isEmpty {
            info.source = "Greenhouse"
            info.jobID = q("gh_jid")
        } else if host.hasSuffix("lever.co") {
            info.source = "Lever"
            if parts.count >= 1 { info.companySlug = parts[0] }
            if parts.count >= 2 { info.jobID = parts[1] }
        } else if host.hasSuffix("ashbyhq.com") {
            info.source = "Ashby"
            if parts.count >= 1 { info.companySlug = parts[0] }
            if parts.count >= 2 { info.jobID = parts[1] }
        } else if host.contains("myworkdayjobs.com") || host.contains("myworkday.com") {
            info.source = "Workday"
            info.companySlug = String(host.split(separator: ".").first ?? "")
            if let last = parts.last, let range = last.range(of: "_[A-Za-z0-9\\-]+$", options: .regularExpression) {
                info.jobID = String(last[range].dropFirst())
            }
        } else if host.contains("linkedin.com") {
            info.source = "LinkedIn"
            if let view = parts.firstIndex(of: "view"), view + 1 < parts.count {
                info.jobID = parts[view + 1].components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.last ?? ""
            }
            if info.jobID.isEmpty { info.jobID = q("currentJobId") }
        } else if host.contains("indeed.") {
            info.source = "Indeed"
            info.jobID = q("jk").isEmpty ? q("vjk") : q("jk")
        } else if host.contains("smartrecruiters.com") {
            info.source = "SmartRecruiters"
            if parts.count >= 1 { info.companySlug = parts[0] }
            if parts.count >= 2 { info.jobID = parts[1].split(separator: "-").first.map(String.init) ?? parts[1] }
        } else if host.contains("workable.com") {
            info.source = "Workable"
            if parts.count >= 1 { info.companySlug = parts[0] }
            if let j = parts.firstIndex(of: "j"), j + 1 < parts.count { info.jobID = parts[j + 1] }
        } else if host.contains("icims.com") {
            info.source = "iCIMS"
            info.companySlug = host.split(separator: ".").first.map { String($0).replacingOccurrences(of: "careers-", with: "") } ?? ""
            if let jobs = parts.firstIndex(of: "jobs"), jobs + 1 < parts.count { info.jobID = parts[jobs + 1] }
        } else if host.contains("jobvite.com") {
            info.source = "Jobvite"
            if parts.count >= 1 { info.companySlug = parts[0] }
            if let job = parts.firstIndex(of: "job"), job + 1 < parts.count { info.jobID = parts[job + 1] }
        } else if host.contains("bamboohr.com") {
            info.source = "BambooHR"
            info.companySlug = String(host.split(separator: ".").first ?? "")
            info.jobID = parts.last ?? ""
        } else if host.contains("taleo.net") {
            info.source = "Taleo"
            info.jobID = q("job")
        } else if host.contains("successfactors") {
            info.source = "SuccessFactors"
        } else if host.contains("wellfound.com") || host.contains("angel.co") {
            info.source = "Wellfound"
            if let jobs = parts.firstIndex(of: "jobs"), jobs + 1 < parts.count {
                info.jobID = parts[jobs + 1].split(separator: "-").first.map(String.init) ?? ""
            }
        } else if host.contains("glassdoor.") {
            info.source = "Glassdoor"
            info.jobID = q("jobListingId")
        } else {
            // Company career site: the registrable domain names the company.
            let labels = host.split(separator: ".").map(String.init).filter { !["www", "jobs", "careers", "boards", "apply", "career"].contains($0) }
            if labels.count >= 2 { info.companySlug = labels[labels.count - 2] }
            info.jobID = parts.last { $0.rangeOfCharacter(from: .decimalDigits) != nil && $0.count >= 4 } ?? ""
        }
        return info
    }

    /// "acme-robotics" → "Acme Robotics".
    static func prettySlug(_ slug: String) -> String {
        let cleaned = slug.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\d+$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Page title

    /// (title, company, location) from common page-title shapes.
    static func parsePageTitle(_ raw: String, source: String) -> (title: String, company: String, location: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // Drop unread-count prefixes "(3) ".
        text = text.replacingOccurrences(of: "^\\(\\d+\\)\\s*", with: "", options: .regularExpression)
        for suffix in [" | LinkedIn", " - LinkedIn", " | Indeed.com", " - Indeed.com", " | Indeed", " | Glassdoor", " - Glassdoor",
                       " | Wellfound", " | Built In", " - Workday", " | Workday", " | Greenhouse"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        func captures(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? "" }
        }
        if let c = captures("^job application for (.+?) at (.+)$") { return (c[0], c[1], "") }
        if let c = captures("^(.+?) hiring (.+?) in (.+)$") { return (c[1], c[0], c[2]) }
        if let c = captures("^(.+?) \\| (.+?) \\| (.+)$") {
            // LinkedIn "Title | Company | Location" / generic.
            return hasRoleWord(c[0]) ? (c[0], c[1], c[2]) : (c[1], c[0], c[2])
        }
        if let c = captures("^(.+?) @ (.+)$") { return (c[0], c[1], "") }
        if let c = captures("^(.+?) at (.+?)(?: [-|–] .*)?$"), hasRoleWord(c[0]) { return (c[0], c[1], "") }
        if source == "Indeed", let c = captures("^(.+?) - (.+?)(?: - (.+))?$") { return (c[0], "", c[1]) }
        if let c = captures("^(.+?) [-–|] (.+)$") {
            if hasRoleWord(c[1]) && !hasRoleWord(c[0]) { return (c[1], c[0], "") }   // Lever "Company - Title"
            if hasRoleWord(c[0]) && !hasRoleWord(c[1]) { return (c[0], c[1], "") }
        }
        return (hasRoleWord(text) && text.count <= 90 ? text : "", "", "")
    }

    // MARK: Text cleanup

    static func cleanLines(_ text: String) -> [String] {
        var seen: [String: Int] = [:]
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2 else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("http") || lower.range(of: "^[a-z0-9.-]+\\.(com|io|co|org|net)(/\\S*)?$", options: .regularExpression) != nil { continue }
            // Repeated nav chrome.
            seen[lower, default: 0] += 1
            if seen[lower]! > 2 { continue }
            out.append(line)
        }
        return out
    }

    // MARK: Parse

    static func parse(text rawText: String, lines ocrLines: [JobOCRLine] = [], url: String = "", pageTitle: String = "") -> JobPosting {
        var posting = JobPosting()
        posting.sourceURL = url
        posting.pageTitle = pageTitle
        let info = urlInfo(url)
        posting.source = info.source
        posting.jobID = info.jobID

        // A sidebar left of the title's column (LinkedIn/Indeed job lists) is
        // other jobs, not this posting: drop it when it is substantial.
        // Geometry only when the lines carry real boxes (pasted text doesn't).
        var ocrLines = ocrLines.contains { $0.rect.height > 0 } ? ocrLines : []
        var lines = cleanLines(rawText)
        if let anchor = titleCandidate(lines: lines, ocrLines: ocrLines)?.line {
            let sidebar = ocrLines.filter { $0.rect.maxX < anchor.rect.minX - 10 && $0.rect.minY > anchor.rect.minY - anchor.rect.height * 8 }
            if sidebar.count >= 5 {
                ocrLines = ocrLines.filter { $0.rect.maxX >= anchor.rect.minX - 10 }
                lines = cleanLines(ocrLines.map(\.text).joined(separator: "\n"))
            }
        }
        posting.text = String(lines.joined(separator: "\n").prefix(20_000))

        let fromTitle = parsePageTitle(pageTitle, source: info.source)
        posting.title = fromTitle.title
        posting.company = fromTitle.company
        posting.location = fromTitle.location

        // Title: the largest role-like line near the top, else the first role-like line.
        var rawTitle = posting.title
        var titleLine: JobOCRLine?
        if posting.title.isEmpty, let candidate = titleCandidate(lines: lines, ocrLines: ocrLines) {
            rawTitle = candidate.text
            titleLine = candidate.line
            posting.title = recase(rawTitle, using: lines)
        }
        let near = neighbors(of: rawTitle, titleLine: titleLine, lines: lines, ocrLines: ocrLines)
        if posting.company.isEmpty {
            posting.company = companyCandidate(lines: lines, title: rawTitle, near: near) ?? ""
        }
        if posting.company.isEmpty, !info.companySlug.isEmpty {
            posting.company = prettySlug(info.companySlug)
        }
        if fromTitle.company.isEmpty { posting.company = reconcileName(posting.company, in: lines) }
        if posting.location.isEmpty { posting.location = location(in: lines, near: near) ?? "" }
        posting.salary = salary(in: lines) ?? ""
        posting.employmentType = employmentType(in: lines) ?? ""
        posting.deadline = deadline(in: lines) ?? ""

        let sections = sectionize(lines)
        posting.requirements = sections.requirements
        posting.preferred = sections.preferred

        // "Acme Robotics" must not make "Robotics" a required skill.
        let company = posting.company
        func withoutCompany(_ text: String) -> String {
            company.count < 3 ? text : text.replacingOccurrences(of: company, with: " ", options: .caseInsensitive)
        }
        let requirementText = withoutCompany(posting.requirements.joined(separator: "\n"))
        let preferredText = withoutCompany(posting.preferred.joined(separator: "\n"))
        var required = JobSkills.names(in: requirementText)
        if required.isEmpty {
            // No requirement section recognised: skills anywhere in the JD body count as required.
            required = JobSkills.names(in: withoutCompany((sections.responsibilities + sections.body).joined(separator: "\n")))
        } else {
            // Skills only named in responsibilities still matter (as preferred-weight).
            let responsibilitySkills = JobSkills.names(in: withoutCompany(sections.responsibilities.joined(separator: "\n")))
            posting.preferredSkills = responsibilitySkills.filter { !required.contains($0) }
        }
        posting.requiredSkills = required
        let preferred = JobSkills.names(in: preferredText).filter { !required.contains($0) }
        posting.preferredSkills = Array(NSOrderedSet(array: preferred + posting.preferredSkills).compactMap { $0 as? String })

        posting.minYears = minYears(in: posting.requirements.isEmpty ? lines : posting.requirements)
        let education = educationRequirement(posting.requirements.isEmpty ? lines : posting.requirements)
        posting.educationLevel = education.level
        posting.educationFlexible = education.flexible
        posting.postingConfidence = postingConfidence(lines: lines, sections: sections, posting: posting)
        posting.extractedBy = "rules"
        return posting
    }

    static func titleCandidate(lines: [String], ocrLines: [JobOCRLine]) -> (text: String, line: JobOCRLine?)? {
        func acceptable(_ line: String) -> Bool {
            let lower = line.lowercased()
            return line.count >= 5 && line.count <= 90 && hasRoleWord(line) && !line.hasSuffix(":")
                && !line.hasPrefix("•") && !lower.contains("jobs") && !lower.contains("similar") && !lower.contains("apply")
                && !lower.contains("we are") && !lower.contains("you will") && !lower.contains("you'll")
                && line.filter({ $0 == "," }).count <= 1 && !lower.hasPrefix("as a") && !lower.hasPrefix("the ")
                && line.split(separator: " ").count <= 10
        }
        if !ocrLines.isEmpty {
            let top = ocrLines.prefix(80).filter { acceptable($0.text) }
            if let best = top.max(by: { $0.rect.height < $1.rect.height }) { return (best.text, best) }
        }
        return lines.prefix(60).first(where: acceptable).map { ($0, nil) }
    }

    /// Lines next to the title: spatially (same column, a few line heights
    /// away, below first) when OCR geometry is known, else by text order.
    static func neighbors(of title: String, titleLine: JobOCRLine?, lines: [String], ocrLines: [JobOCRLine]) -> [String] {
        if let titleLine {
            let t = titleLine.rect
            let band = max(t.height, 12) * 6
            let near = ocrLines.filter { line in
                guard line != titleLine else { return false }
                let r = line.rect
                let sameColumn = abs(r.minX - t.minX) < max(60, t.height * 3) || (r.minX < t.maxX && r.maxX > t.minX && abs(r.minX - t.minX) < t.width * 0.5)
                return sameColumn && abs(r.midY - t.midY) <= band
            }
            return near.sorted { a, b in
                let da = a.rect.midY - t.midY, db = b.rect.midY - t.midY
                return (da > 0 ? da * 0.8 : -da) < (db > 0 ? db * 0.8 : -db)
            }.map(\.text)
        }
        guard let index = lines.firstIndex(of: title) else { return [] }
        return [1, -1, 2, 3, -2, 4, 5, 6, 7, 8].compactMap { lines.indices.contains(index + $0) ? lines[index + $0] : nil }
    }

    /// Fixes OCR casing ("Senior IOS EngIneer" → "Senior iOS Engineer") from
    /// known skill spellings and the casing used elsewhere in the text.
    static func recase(_ title: String, using lines: [String]) -> String {
        guard !title.isEmpty else { return title }
        let body = lines.filter { $0 != title }.joined(separator: " ")
        let bodyWords = body.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "#" }).map(String.init)
        var variants: [String: [String: Int]] = [:]
        for word in bodyWords { variants[word.lowercased(), default: [:]][word, default: 0] += 1 }
        let words = title.split(separator: " ", omittingEmptySubsequences: false).map { raw -> String in
            let word = String(raw)
            if let skill = JobSkills.canonical(word), skill.lowercased() == word.lowercased() { return skill }
            if let known = variants[word.lowercased()]?.filter({ $0.key.first?.isUppercase == true }).max(by: { $0.value < $1.value })?.key {
                return known
            }
            let inner = word.dropFirst()
            if inner.contains(where: \.isUppercase), inner.contains(where: \.isLowercase) {
                return word.prefix(1).uppercased() + inner.lowercased()
            }
            return word
        }
        return words.joined(separator: " ")
    }

    static func companyCandidate(lines: [String], title: String, near: [String]) -> String? {
        let lowerLines = lines.map { $0.lowercased() }
        // "Company: Acme" / "Company Acme".
        for line in lines.prefix(120) {
            if let range = line.range(of: "^(?:company|employer|organization|hiring company)\\s*[:\\-]\\s*", options: [.regularExpression, .caseInsensitive]) {
                let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value.count <= 60 { return value }
            }
        }
        // "Senior iOS Engineer at Acme" inside the text.
        if !title.isEmpty {
            for line in lines.prefix(120) where line.count <= 120 {
                if let range = line.range(of: NSRegularExpression.escapedPattern(for: title) + "\\s+(?:at|@)\\s+([A-Z][\\w&.' -]{1,40})", options: [.regularExpression]) {
                    let tail = line[range].replacingOccurrences(of: "^.*?\\s+(?:at|@)\\s+", with: "", options: .regularExpression)
                    return cleanCompany(tail)
                }
            }
        }
        // "Acme is hiring a …" / "Join Acme".
        for line in lines.prefix(60) {
            if let range = line.range(of: "^(?-i:[A-Z][\\w&.'-]*(?:\\s+[A-Z][\\w&.'-]*){0,3})(?=\\s+is\\s+(?:hiring|looking|seeking))", options: [.regularExpression]) {
                return String(line[range])
            }
            if let range = line.range(of: "(?<=^Join\\s)(?-i:[A-Z][\\w&.'-]*(?:\\s+[A-Z][\\w&.'-]*){0,3})", options: [.regularExpression]),
               !hasRoleWord(String(line[range])), !["Us", "Our", "The"].contains(String(line[range])) {
                return String(line[range])
            }
        }
        // "About Acme" header.
        for (index, lower) in lowerLines.enumerated() where lower.hasPrefix("about ") && lines[index].count <= 40 {
            let name = String(lines[index].dropFirst(6)).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if !name.isEmpty, !["the role", "the job", "you", "us", "the team", "the company", "this role", "the position"].contains(name.lowercased()) {
                return name
            }
        }
        // Line right below/above the title (LinkedIn, Ashby, Lever layouts).
        for line in near.prefix(3) {
            let candidate = line.components(separatedBy: CharacterSet(charactersIn: "·•|")).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if candidate.count >= 2, candidate.count <= 40, !hasRoleWord(candidate), candidate.first?.isUppercase == true,
               location(in: [candidate], near: []) == nil, header(of: candidate) == nil,
               candidate.rangeOfCharacter(from: .decimalDigits) == nil,
               !["Apply", "Save", "Easy Apply", "Share", "Back"].contains(candidate) {
                return cleanCompany(candidate)
            }
        }
        return nil
    }

    /// OCR slips in one spot ("Acm Robotics") are fixed by the spelling used
    /// elsewhere on the page when that one is more common.
    static func reconcileName(_ name: String, in lines: [String]) -> String {
        let n = name.split(separator: " ").count
        guard n >= 1, n <= 5, name.count >= 3 else { return name }
        var counts: [String: Int] = [:]
        for line in lines {
            let words = line.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
            guard words.count >= n else { continue }
            for start in 0...(words.count - n) {
                let phrase = words[start..<(start + n)].joined(separator: " ")
                guard phrase.first?.isUppercase == true, abs(phrase.count - name.count) <= 2 else { continue }
                let distance = JobConfirmation.levenshtein(phrase.lowercased(), name.lowercased())
                if distance <= max(1, name.count / 6) { counts[phrase, default: 0] += 1 }
            }
        }
        var wordFrequency: [String: Int] = [:]
        for line in lines {
            for word in line.split(separator: " ") { wordFrequency[word.trimmingCharacters(in: .punctuationCharacters), default: 0] += 1 }
        }
        func score(_ phrase: String) -> Int {
            (counts[phrase] ?? 0) * 10 + phrase.split(separator: " ").map { wordFrequency[String($0)] ?? 0 }.reduce(0, +)
        }
        guard let best = counts.keys.max(by: { score($0) < score($1) }), best != name, score(best) > score(name) else { return name }
        return best
    }

    static func cleanCompany(_ raw: String) -> String {
        raw.replacingOccurrences(of: "[,.]?\\s*(?:is hiring|careers|jobs)$", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;|-"))
    }

    static let usStates = Set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC".split(separator: " ").map(String.init))

    static func location(in lines: [String], near: [String]) -> String? {
        for line in lines.prefix(150) {
            if let range = line.range(of: "^(?:location|locations|office|based in|job location)\\s*[:\\-]\\s*", options: [.regularExpression, .caseInsensitive]) {
                let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value.count <= 80 { return value }
            }
        }
        let window = Array(near.prefix(8)) + Array(lines.prefix(30))
        for line in window where line.count <= 90 {
            // "San Francisco, CA" (optionally "(Hybrid)").
            if let regex = try? NSRegularExpression(pattern: "([A-Z][a-zA-Z.' ]+),\\s*([A-Z]{2})\\b(\\s*\\((?:Remote|Hybrid|On-?site)\\))?"),
               let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range, in: line), let st = Range(m.range(at: 2), in: line), usStates.contains(String(line[st])) {
                return String(line[r]).trimmingCharacters(in: .whitespaces)
            }
            if let r = line.range(of: "\\b(?:Remote|Hybrid)(?:\\s*[-–(,]\\s*[A-Z][A-Za-z ]+\\)?)?", options: .regularExpression),
               line.count <= 60 {
                return String(line[r]).trimmingCharacters(in: .whitespaces)
            }
            if let r = line.range(of: "\\b(London|Berlin|Paris|Toronto|Vancouver|Bangalore|Bengaluru|Hyderabad|Dublin|Amsterdam|Singapore|Sydney|Tokyo|Remote)(?:,\\s*[A-Z][A-Za-z ]+)?", options: .regularExpression) {
                return String(line[r]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static let salaryRegex: NSRegularExpression? = {
        let amount = "(?:[$€£₹]|USD|EUR|GBP|CAD|INR)\\s?\\d[\\d,]*(?:\\.\\d+)?\\s?[kK]?"
        let tail = "(?:\\s*(?:/|per|a|an)\\s*(?:year|yr|annum|hour|hr|month|mo))?(?:\\s*(?:USD|EUR|GBP|CAD))?"
        // "$220K/yr - $280K/yr": the unit may follow each amount.
        let pattern = amount + tail + "(?:\\s*(?:-|–|—|to)\\s*(?:[$€£₹]|USD|EUR|GBP|CAD|INR)?\\s?\\d[\\d,]*(?:\\.\\d+)?\\s?[kK]?)?" + tail
        return try? NSRegularExpression(pattern: pattern)
    }()

    static func salary(in lines: [String]) -> String? {
        guard let regex = salaryRegex else { return nil }
        var best: String?
        for line in lines {
            let lower = line.lowercased()
            // Skip benefit amounts ("$500 learning budget", "401k").
            if lower.contains("budget") || lower.contains("stipend") || lower.contains("bonus of") || lower.contains("referral") { continue }
            for m in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let r = Range(m.range, in: line) else { continue }
                let value = String(line[r]).trimmingCharacters(in: .whitespaces)
                let digits = value.filter(\.isNumber)
                let isRange = value.contains("-") || value.contains("–") || value.contains("—") || value.lowercased().contains(" to ")
                let looksAnnual = digits.count >= 5 || value.lowercased().contains("k")
                let hourly = value.lowercased().contains("hour") || value.lowercased().contains("hr")
                guard looksAnnual || hourly else { continue }
                if isRange { return value }
                if best == nil { best = value }
            }
        }
        return best
    }

    static func employmentType(in lines: [String]) -> String? {
        let types: [(String, String)] = [
            ("contract[- ]to[- ]hire", "Contract-to-hire"), ("full[- ]?time", "Full-time"), ("part[- ]?time", "Part-time"),
            ("internship|\\bintern\\b", "Internship"), ("\\bcontract(?:or)?\\b", "Contract"), ("temporary|\\btemp\\b", "Temporary"),
            ("freelance", "Freelance"),
        ]
        let head = lines.prefix(80).joined(separator: "\n")
        for (pattern, name) in types where head.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return name
        }
        return nil
    }

    static func deadline(in lines: [String]) -> String? {
        let date = "(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s*\\d{4}|\\d{1,2}\\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\\.?\\s+\\d{4}|\\d{4}-\\d{2}-\\d{2}|\\d{1,2}/\\d{1,2}/\\d{2,4})"
        for line in lines where line.range(of: "apply by|deadline|applications? close|closing date|apply before|posting end|valid through|accepting applications until|open until", options: [.regularExpression, .caseInsensitive]) != nil {
            if let r = line.range(of: date, options: [.regularExpression, .caseInsensitive]) { return String(line[r]) }
        }
        return nil
    }

    private static let deadlineFormatters: [DateFormatter] = ["MMMM d yyyy", "MMM d yyyy", "d MMMM yyyy", "d MMM yyyy", "yyyy-MM-dd", "M/d/yyyy", "M/d/yy"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        formatter.isLenient = false
        return formatter
    }

    /// "March 15, 2027" / "15th Mar 2027" / "2027-03-15" / "3/15/2027" → end of that day.
    static func deadlineDate(_ text: String) -> Date? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "(\\d)(?:st|nd|rd|th)\\b", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "Sept", with: "Sep")
            .replacingOccurrences(of: "[.,]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        for formatter in deadlineFormatters {
            if let date = formatter.date(from: cleaned), (2000...2100).contains(Calendar.current.component(.year, from: date)) {
                return Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: date)
            }
        }
        return nil
    }

    struct Sections: Sendable {
        var requirements: [String] = []
        var preferred: [String] = []
        var responsibilities: [String] = []
        var body: [String] = []
        var headersFound: Set<String> = []
    }

    static func sectionize(_ lines: [String]) -> Sections {
        var sections = Sections()
        var current: Header?
        func add(_ text: String) {
            // Long prose lines hold several requirements: classify sentence by sentence.
            for item in text.count > 80 ? sentences(text) : [text] {
                // Inline "Preferred: …" / "… is a plus" inside a requirements list.
                if current == .requirements,
                   item.range(of: "^(?:preferred|nice to have|bonus|plus)\\b", options: [.regularExpression, .caseInsensitive]) != nil
                    || item.range(of: "\\b(?:is a plus|a plus|nice to have|preferred|is a bonus)\\.?$", options: [.regularExpression, .caseInsensitive]) != nil {
                    sections.preferred.append(item)
                } else if let current {
                    append(item, to: current, in: &sections)
                } else {
                    sections.body.append(item)
                }
            }
        }
        for line in lines {
            if let header = header(of: line) {
                current = header
                sections.headersFound.insert(header.rawValue)
                // "Requirements: 5+ years of Swift" — keep the tail.
                if let colon = line.firstIndex(of: ":"), line.index(after: colon) < line.endIndex {
                    let tail = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if tail.count > 3 { add(tail) }
                }
                continue
            }
            let item = line.drop { "•-*–▪·● ".contains($0) }.trimmingCharacters(in: .whitespaces)
            if !item.isEmpty { add(item) }
        }
        return sections
    }

    static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: "([.!?;])\\s+(?=[A-Z0-9])", with: "$1\n", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func append(_ item: String, to header: Header, in sections: inout Sections) {
        switch header {
        case .requirements: sections.requirements.append(item)
        case .preferred: sections.preferred.append(item)
        case .responsibilities: sections.responsibilities.append(item)
        case .other: break
        }
    }

    static func minYears(in lines: [String]) -> Double? {
        guard let regex = try? NSRegularExpression(
            pattern: "(\\d{1,2})(?:\\.\\d)?\\s*\\+?\\s*(?:(?:-|–|to)\\s*\\d{1,2}\\s*)?\\+?\\s*(?:years|yrs)", options: [.caseInsensitive]
        ) else { return nil }
        var found: [Double] = []
        for line in lines {
            let lower = line.lowercased()
            guard !lower.contains("old"), !lower.contains("401"), !lower.contains("vest"), !lower.contains("anniversary") else { continue }
            for m in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let r = Range(m.range(at: 1), in: line), let value = Double(line[r]), value <= 25 {
                    // Experience-ish context weighs more; plain "years" is still accepted.
                    found.append(value)
                }
            }
        }
        // The most demanding hard requirement is usually the first/headline one; use the max of the first two.
        return found.prefix(2).max()
    }

    static func educationRequirement(_ lines: [String]) -> (level: Int, flexible: Bool) {
        var levels: [Int] = []
        var flexible = false
        for line in lines {
            let found = JobResumeParser.degreeLevels(line)
            guard !found.isEmpty else { continue }
            levels.append(found.min() ?? 0)
            if line.range(of: "or equivalent|equivalent (?:practical |work )?experience|or related experience|or comparable", options: [.regularExpression, .caseInsensitive]) != nil {
                flexible = true
            }
        }
        return (levels.min() ?? 0, flexible)
    }

    static func postingConfidence(lines: [String], sections: Sections, posting: JobPosting) -> Double {
        var score = 0.0
        score += min(0.45, Double(sections.headersFound.count) * 0.15)
        if !posting.title.isEmpty { score += 0.15 }
        if !posting.requiredSkills.isEmpty { score += 0.1 }
        if !posting.salary.isEmpty || !posting.employmentType.isEmpty { score += 0.1 }
        let all = lines.joined(separator: " ").lowercased()
        if all.contains("apply") { score += 0.1 }
        if all.contains("equal opportunity") || all.contains("benefits") { score += 0.05 }
        if posting.source.isEmpty == false { score += 0.05 }
        return min(1, score)
    }
}
