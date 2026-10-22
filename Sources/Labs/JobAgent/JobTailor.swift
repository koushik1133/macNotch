import Foundation

/// Truthful resume tailoring: every suggestion is built from text already
/// in the resume (reordering, surfacing, mirroring the JD's wording for a
/// skill the resume already shows). Gaps are listed, never filled in.
enum JobTailor {
    static func suggestions(profile: ResumeProfile, resumeText: String, posting: JobPosting, fit: JobFitReport) -> [TailorSuggestion] {
        var result: [TailorSuggestion] = []
        let jdSkills = posting.requiredSkills + posting.preferredSkills
        let jdKeywords = fit.matchedKeywords + fit.missingKeywords
        let resumeMatches = Dictionary(JobSkills.find(in: resumeText).map { ($0.skill, $0) }, uniquingKeysWith: { a, _ in a })
        let jdMatches = Dictionary(JobSkills.find(in: posting.text).map { ($0.skill, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Reorder bullets inside each role by relevance to the JD.
        for role in profile.experience where role.highlights.count >= 2 {
            let scored = role.highlights.enumerated().map { (index, bullet) in
                (index, bullet, relevance(bullet, skills: jdSkills, keywords: jdKeywords))
            }
            let reordered = scored.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
            guard reordered.map(\.0) != scored.map(\.0), let top = reordered.first, top.2 > 0, top.0 != 0 else { continue }
            result.append(TailorSuggestion(
                kind: .reorder,
                location: roleLabel(role),
                before: role.highlights.first ?? "",
                after: top.1,
                reason: "Lead with the bullet that shows \(matchedTerms(top.1, skills: jdSkills).prefix(3).joined(separator: ", ")), which this posting asks for."
            ))
        }

        // 2. Skills shown in experience but missing from the Skills section.
        if !profile.declaredSkills.isEmpty {
            let declared = Set(profile.declaredSkills)
            let shownElsewhere = fit.matchingSkills.filter { !declared.contains($0) && resumeMatches[$0] != nil }
            if !shownElsewhere.isEmpty {
                let current = profile.declaredSkills.prefix(10).joined(separator: ", ")
                result.append(TailorSuggestion(
                    kind: .addToSkills,
                    location: "Skills",
                    before: current,
                    after: (shownElsewhere + profile.declaredSkills).prefix(14).joined(separator: ", "),
                    reason: "Your experience already mentions \(shownElsewhere.joined(separator: ", ")); list \(shownElsewhere.count == 1 ? "it" : "them") in Skills (and first) so ATS keyword filters see \(shownElsewhere.count == 1 ? "it" : "them")."
                ))
            }
        }

        // 3. Mirror the JD's wording for skills the resume shows under another alias.
        for skill in fit.matchingSkills {
            guard let mine = resumeMatches[skill], let theirs = jdMatches[skill],
                  mine.surface.caseInsensitiveCompare(theirs.surface) != .orderedSame else { continue }
            result.append(TailorSuggestion(
                kind: .mirrorKeyword,
                location: "Wherever you wrote \"\(mine.surface)\"",
                before: mine.surface,
                after: "\(theirs.surface) (\(mine.surface))",
                reason: "The posting says \"\(theirs.surface)\"; ATS matching is often literal, so use its wording for the experience you already have."
            ))
        }

        // 4. Emphasize: the strongest matching bullet across roles, for the summary.
        let allBullets = profile.experience.flatMap { role in role.highlights.map { (role, $0) } }
        if let best = allBullets.max(by: { relevance($0.1, skills: jdSkills, keywords: jdKeywords) < relevance($1.1, skills: jdSkills, keywords: jdKeywords) }),
           relevance(best.1, skills: jdSkills, keywords: jdKeywords) >= 2 {
            result.append(TailorSuggestion(
                kind: .emphasize,
                location: roleLabel(best.0),
                before: best.1,
                after: best.1,
                reason: "Your most relevant achievement for this role; consider quoting it in your summary or cover letter."
            ))
        }

        // 5. Summary rebuilt from facts in the profile only.
        let topSkills = fit.matchingSkills.prefix(5)
        if !topSkills.isEmpty {
            var line = ""
            let role = profile.titles.first ?? profile.headline
            if !role.isEmpty { line += role } else { line += "Professional" }
            if let years = profile.yearsExperience, years >= 1 { line += " with \(Int(years.rounded(.down)))+ years of experience" }
            line += " in " + listJoin(Array(topSkills))
            if let best = allBullets.first(where: { relevance($0.1, skills: jdSkills, keywords: jdKeywords) >= 2 }) {
                line += ". " + best.1.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
            line += "."
            result.append(TailorSuggestion(
                kind: .summary,
                location: "Summary",
                before: profile.summary.isEmpty ? "(no summary)" : profile.summary,
                after: line,
                reason: "Built only from your own titles, years and skills that this posting asks for."
            ))
        }

        // 6. Gaps: never added for you.
        for skill in fit.missingSkills.prefix(6) {
            result.append(TailorSuggestion(
                kind: .gap,
                location: "Missing",
                before: "",
                after: skill,
                reason: "Required by the posting and not in your resume. Add it only if you've genuinely used it (a project, course or role); otherwise address it in your cover letter."
            ))
        }
        return result
    }

    static func roleLabel(_ role: ResumeExperience) -> String {
        [role.company, role.title].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func relevance(_ text: String, skills: [String], keywords: [String]) -> Int {
        let found = Set(JobSkills.names(in: text))
        let stems = JobKeywords.stems(text)
        return found.intersection(skills).count * 2 + keywords.filter { JobKeywords.present($0, inStems: stems) }.count
    }

    static func matchedTerms(_ text: String, skills: [String]) -> [String] {
        let found = JobSkills.names(in: text)
        return found.filter { skills.contains($0) }
    }

    static func listJoin(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    // MARK: Grounding for model rewording

    /// True when `rewrite` adds nothing that isn't in `original` or the resume:
    /// no new numbers, no new dictionary skills, no new capitalised names.
    static func isGrounded(rewrite: String, original: String, resumeText: String) -> Bool {
        let source = original + "\n" + resumeText
        let numbers = { (s: String) -> Set<String> in
            Set(s.components(separatedBy: CharacterSet(charactersIn: "0123456789.%$,").inverted).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            }.filter { $0.rangeOfCharacter(from: .decimalDigits) != nil })
        }
        guard numbers(rewrite).isSubset(of: numbers(source)) else { return false }
        let newSkills = Set(JobSkills.names(in: rewrite)).subtracting(JobSkills.names(in: source))
        guard newSkills.isEmpty else { return false }
        let sourceWords = Set(JobKeywords.words(source))
        let properNouns = rewrite.split(separator: " ").dropFirst().filter { $0.first?.isUppercase == true }
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        return properNouns.allSatisfy { $0.isEmpty || sourceWords.contains($0) }
    }
}
