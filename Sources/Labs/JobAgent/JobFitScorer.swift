import Foundation

/// Resume ↔ JD fit, Jobscan-style priorities (hard skills weigh most, then
/// experience, keywords, education, title) with a Jobright-style breakdown.
/// Components without data are left out and the remaining weights
/// renormalised, and the explanation says what could not be checked.
enum JobFitScorer {
    static let weights: [String: Double] = [
        "Hard skills": 0.45, "Experience": 0.20, "Keywords": 0.15, "Education": 0.10, "Title": 0.10,
    ]

    static func score(profile: ResumeProfile, resumeText: String, posting: JobPosting) -> JobFitReport {
        let resumeSkills = Set(profile.skills).union(JobSkills.names(in: resumeText))
        let jdText = posting.text

        // MARK: Hard skills (required count 2×, preferred 1×; repeated JD terms up to +50 %).
        let counts = Dictionary(JobSkills.find(in: jdText).map { ($0.skill, $0.count) }, uniquingKeysWith: max)
        func weight(_ skill: String) -> Double { 1 + min(Double((counts[skill] ?? 1) - 1), 2) * 0.25 }
        let requiredHard = posting.requiredSkills.filter { !JobSkills.isSoft($0) }
        let preferredHard = posting.preferredSkills.filter { !JobSkills.isSoft($0) && !requiredHard.contains($0) }
        let matching = requiredHard.filter { resumeSkills.contains($0) }
        let missing = requiredHard.filter { !resumeSkills.contains($0) }
        let matchingPreferred = preferredHard.filter { resumeSkills.contains($0) }
        let missingPreferred = preferredHard.filter { !resumeSkills.contains($0) }
        var hardScore: Double?
        let denominator = requiredHard.map { 2 * weight($0) }.reduce(0, +) + preferredHard.map(weight).reduce(0, +)
        if denominator > 0 {
            let numerator = matching.map { 2 * weight($0) }.reduce(0, +) + matchingPreferred.map(weight).reduce(0, +)
            hardScore = numerator / denominator
        }
        var hardDetail: String
        if requiredHard.isEmpty && preferredHard.isEmpty {
            hardDetail = "No specific tools or technologies were recognised in the posting."
        } else {
            hardDetail = "\(matching.count) of \(requiredHard.count) required"
            if !preferredHard.isEmpty { hardDetail += ", \(matchingPreferred.count) of \(preferredHard.count) nice-to-have" }
            hardDetail += " skills found in your resume."
        }

        // MARK: Experience
        var experienceScore: Double?
        var experienceNote = ""
        if let required = posting.minYears, required > 0 {
            if let have = profile.yearsExperience {
                experienceScore = min(1, have / required)
                if have >= required {
                    experienceNote = "Asks for \(format(required))+ years; your resume shows about \(format(have))."
                } else {
                    experienceNote = "Asks for \(format(required))+ years; your resume shows about \(format(have)) (\(format(required - have)) short)."
                }
            } else {
                experienceNote = "Asks for \(format(required))+ years, but the dates in your resume couldn't be read, so this wasn't scored."
            }
        } else {
            experienceNote = "No years-of-experience requirement found."
        }
        // Seniority words as a soft cap (an intern resume for a Staff role).
        let seniority = seniorityGap(jobTitle: posting.title, profile: profile)
        if let gap = seniority, let current = experienceScore {
            experienceScore = max(0, current - gap)
        } else if let gap = seniority, gap > 0 {
            experienceScore = max(0, 1 - gap)
            experienceNote += " The title is more senior than your recent roles."
        }

        // MARK: Keywords
        // The company's own name ("acme") is not a keyword to put on a resume.
        let companyWords = Set(JobKeywords.words(posting.company).map(JobKeywords.stem))
        let keywords = JobKeywords.top(in: jdText, limit: 24)
            .filter { keyword in !keyword.split(separator: " ").contains { companyWords.contains(JobKeywords.stem(String($0))) } }
            .prefix(20).map { $0 }
        let stems = JobKeywords.stems(resumeText)
        let matchedKeywords = keywords.filter { JobKeywords.present($0, inStems: stems) }
        let missingKeywords = keywords.filter { !JobKeywords.present($0, inStems: stems) }
        let keywordScore: Double? = keywords.isEmpty ? nil : Double(matchedKeywords.count) / Double(keywords.count)

        // MARK: Education
        var educationScore: Double?
        var educationDetail = "No degree requirement found."
        if posting.educationLevel > 0 {
            let have = profile.highestEducationLevel
            let names = [0: "no degree listed", 1: "an associate degree", 2: "a bachelor's", 3: "a master's", 4: "a doctorate"]
            if have >= posting.educationLevel {
                educationScore = 1
                educationDetail = "Asks for \(names[posting.educationLevel] ?? "a degree"); you have \(names[have] ?? "a degree")."
            } else if posting.educationFlexible {
                educationScore = 0.7
                educationDetail = "Asks for \(names[posting.educationLevel] ?? "a degree") or equivalent experience; your resume shows \(names[have] ?? "no degree")."
            } else {
                educationScore = have == 0 ? 0.2 : 0.5
                educationDetail = "Asks for \(names[posting.educationLevel] ?? "a degree"); your resume shows \(names[have] ?? "no degree")."
            }
        }

        // MARK: Title
        var titleScore: Double?
        var titleDetail = "No job title to compare."
        if !posting.title.isEmpty, !(profile.titles.isEmpty && profile.headline.isEmpty) {
            let candidates = profile.titles + (profile.headline.isEmpty ? [] : [profile.headline])
            let best = candidates.map { titleSimilarity(posting.title, $0) }.max() ?? 0
            titleScore = best
            let closest = candidates.max { titleSimilarity(posting.title, $0) < titleSimilarity(posting.title, $1) } ?? ""
            titleDetail = best >= 0.6 ? "Your title \"\(closest)\" is close to \"\(posting.title)\"."
                : "None of your titles closely match \"\(posting.title)\"."
        }

        // MARK: Combine
        let components = [
            JobFitComponent(name: "Hard skills", score: hardScore, weight: weights["Hard skills"]!, detail: hardDetail),
            JobFitComponent(name: "Experience", score: experienceScore, weight: weights["Experience"]!, detail: experienceNote),
            JobFitComponent(name: "Keywords", score: keywordScore, weight: weights["Keywords"]!,
                            detail: keywords.isEmpty ? "Too little posting text to extract keywords."
                                : "\(matchedKeywords.count) of \(keywords.count) frequent posting keywords appear in your resume."),
            JobFitComponent(name: "Education", score: educationScore, weight: weights["Education"]!, detail: educationDetail),
            JobFitComponent(name: "Title", score: titleScore, weight: weights["Title"]!, detail: titleDetail),
        ]
        let scored = components.filter { $0.score != nil }
        let totalWeight = scored.map(\.weight).reduce(0, +)
        var overall = totalWeight > 0 ? scored.map { $0.score! * $0.weight }.reduce(0, +) / totalWeight : 0
        // Very little evidence: pull toward the middle rather than claim certainty.
        if totalWeight < 0.4 { overall = overall * 0.6 + 0.5 * 0.4 }
        let overallInt = Int((overall * 100).rounded())

        let explanation = explain(overall: overallInt, matching: matching, missing: missing, missingPreferred: missingPreferred,
                                  components: components, posting: posting, keywordsMatched: matchedKeywords.count,
                                  keywordsTotal: keywords.count, unscored: components.filter { $0.score == nil }.map(\.name))
        return JobFitReport(
            overall: overallInt,
            matchingSkills: matching + matchingPreferred,
            missingSkills: missing,
            missingPreferred: missingPreferred,
            keywordCoverage: keywordScore ?? 0,
            matchedKeywords: matchedKeywords,
            missingKeywords: missingKeywords,
            experienceNote: experienceNote,
            components: components,
            explanation: explanation
        )
    }

    static func explain(overall: Int, matching: [String], missing: [String], missingPreferred: [String],
                        components: [JobFitComponent], posting: JobPosting, keywordsMatched: Int, keywordsTotal: Int,
                        unscored: [String]) -> String {
        var parts: [String] = []
        let verdict: String
        switch overall {
        case 80...: verdict = "Strong fit"
        case 65..<80: verdict = "Good fit"
        case 50..<65: verdict = "Partial fit"
        default: verdict = "Weak fit"
        }
        parts.append("\(verdict) (\(overall)%).")
        if !matching.isEmpty {
            parts.append("You match \(matching.count) required skill\(matching.count == 1 ? "" : "s"): \(matching.prefix(6).joined(separator: ", "))\(matching.count > 6 ? "…" : ".")")
        }
        if !missing.isEmpty {
            parts.append("Missing from your resume: \(missing.prefix(6).joined(separator: ", "))\(missing.count > 6 ? "…" : ".")")
        }
        if !missingPreferred.isEmpty {
            parts.append("Nice-to-haves you don't show: \(missingPreferred.prefix(4).joined(separator: ", ")).")
        }
        if let experience = components.first(where: { $0.name == "Experience" }), !experience.detail.isEmpty {
            parts.append(experience.detail)
        }
        if let education = components.first(where: { $0.name == "Education" }), education.score != nil {
            parts.append(education.detail)
        }
        if keywordsTotal > 0 {
            parts.append("Keyword coverage \(Int((Double(keywordsMatched) / Double(keywordsTotal) * 100).rounded()))%.")
        }
        if !unscored.isEmpty {
            parts.append("Not scored (no data): \(unscored.joined(separator: ", ")).")
        }
        if posting.postingConfidence < 0.35 {
            parts.append("Low confidence: the captured text doesn't look like a complete job description (scroll to show the requirements and capture again).")
        }
        parts.append("This is a keyword-based estimate, not a hiring prediction.")
        return parts.joined(separator: " ")
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Title helpers

    static let seniorityWords: [(String, Int)] = [
        ("intern", 0), ("junior", 1), ("associate", 1), ("entry", 1), ("mid", 2), ("senior", 3), ("sr", 3), ("lead", 4),
        ("staff", 4), ("principal", 5), ("director", 5), ("head", 5), ("vp", 6),
    ]

    static func seniority(_ title: String) -> Int? {
        let words = Set(JobKeywords.words(title))
        return seniorityWords.filter { words.contains($0.0) }.map(\.1).max()
    }

    /// 0 when fine, up to 0.4 when the job is several levels above the user's recent titles.
    static func seniorityGap(jobTitle: String, profile: ResumeProfile) -> Double? {
        guard let job = seniority(jobTitle) else { return nil }
        let mine = profile.titles.prefix(2).compactMap(seniority).max() ?? (profile.yearsExperience.map { $0 >= 8 ? 4 : $0 >= 5 ? 3 : $0 >= 2 ? 2 : 1 } ?? 2)
        let gap = job - mine
        return gap >= 2 ? min(0.4, Double(gap - 1) * 0.2) : 0
    }

    /// Token Dice similarity, ignoring seniority words and filler.
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let ignore: Set<String> = ["senior", "sr", "junior", "jr", "lead", "staff", "principal", "ii", "iii", "iv", "i", "the", "and", "of", "-", "remote"]
        let synonyms: [String: String] = ["developer": "engineer", "dev": "engineer", "programmer": "engineer", "swe": "engineer",
                                          "sde": "engineer", "ios": "ios", "frontend": "front-end", "backend": "back-end"]
        func tokens(_ s: String) -> Set<String> {
            Set(JobKeywords.words(s).filter { !ignore.contains($0) }.map { synonyms[$0] ?? JobKeywords.stem($0) })
        }
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }
}
