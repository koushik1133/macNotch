import Foundation

/// Classifies a captured page or email: application confirmation,
/// rejection, interview invite, offer, or none; and checks whether a
/// confirmation belongs to a saved job.
enum JobConfirmation {
    enum Kind: String, Sendable, Equatable {
        case confirmation, rejection, interview, offer, none
    }

    struct Detection: Sendable, Equatable {
        var kind: Kind
        /// 0…1.
        var confidence: Double
        /// Phrases that matched (for the evidence note).
        var evidence: [String]
        /// "Your application was sent to Acme" → "Acme".
        var mentionedCompany: String
        /// "…for the Senior iOS Engineer position" → title.
        var mentionedTitle: String
        var looksLikeEmail: Bool
    }

    static let confirmationPhrases: [(String, Double)] = [
        ("application submitted", 0.9), ("application has been submitted", 0.95), ("application was submitted", 0.95),
        ("your application has been received", 0.95), ("we have received your application", 0.95), ("we've received your application", 0.95),
        ("we received your application", 0.95), ("received your application", 0.85), ("application received", 0.85),
        ("thank you for applying", 0.9), ("thanks for applying", 0.9), ("thank you for your application", 0.9),
        ("thanks for your application", 0.9), ("thank you for your interest", 0.45), ("your application was sent", 0.95),
        ("application was sent to", 0.95), ("you applied", 0.6), ("applied on", 0.5), ("you have submitted", 0.85),
        ("you have successfully applied", 0.95), ("successfully applied", 0.85), ("successfully submitted", 0.85),
        ("submission received", 0.8), ("application complete", 0.85), ("we'll be in touch", 0.4), ("someone will be in touch", 0.5),
        ("if there is a fit", 0.45), ("we will review your application", 0.6), ("our team will review", 0.5),
        ("application status: submitted", 0.9), ("thank you for submitting", 0.85), ("your application is complete", 0.9),
    ]

    static let rejectionPhrases: [(String, Double)] = [
        ("not to move forward", 0.95), ("not moving forward", 0.9), ("decided to move forward with other candidates", 0.95),
        ("pursue other candidates", 0.9), ("other candidates whose", 0.85), ("unfortunately", 0.35), ("we regret to inform", 0.95),
        ("will not be moving forward", 0.95), ("position has been filled", 0.85), ("not selected", 0.8), ("no longer under consideration", 0.95),
        ("not be proceeding", 0.9), ("unable to offer you", 0.85), ("we won't be moving", 0.9),
    ]

    static let interviewPhrases: [(String, Double)] = [
        ("schedule an interview", 0.9), ("schedule a call", 0.7), ("invite you to interview", 0.95), ("interview invitation", 0.9),
        ("next steps in the process", 0.5), ("phone screen", 0.75), ("technical interview", 0.8), ("availability for", 0.5),
        ("calendly.com", 0.6), ("would like to speak with you", 0.8), ("move you forward to", 0.8), ("onsite interview", 0.85),
        ("recruiter screen", 0.8), ("book a time", 0.6), ("like to invite you", 0.85),
    ]

    static let offerPhrases: [(String, Double)] = [
        ("pleased to offer you", 0.95), ("offer letter", 0.85), ("extend an offer", 0.95), ("offer of employment", 0.95),
        ("we are delighted to offer", 0.95), ("congratulations! we", 0.6), ("your offer", 0.5),
    ]

    /// An un-submitted form is still on screen.
    static let formMarkers = ["submit application", "submit your application", "* required", "upload resume", "attach resume",
                              "resume/cv *", "first name *", "review your application", "apply now", "easy apply", "next step"]

    static func detect(text: String, url: String = "") -> Detection {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\n", with: " ")
        let info = JobPostingParser.urlInfo(url)
        func best(_ phrases: [(String, Double)]) -> (Double, [String]) {
            var hits: [String] = []
            var score = 0.0
            for (phrase, weight) in phrases where lower.contains(phrase) {
                hits.append(phrase)
                // Noisy-OR combination.
                score = 1 - (1 - score) * (1 - weight)
            }
            return (score, hits)
        }
        var (confirm, confirmHits) = best(confirmationPhrases)
        let (reject, rejectHits) = best(rejectionPhrases)
        let (interview, interviewHits) = best(interviewPhrases)
        let (offer, offerHits) = best(offerPhrases)

        if info.isConfirmationPath {
            confirm = 1 - (1 - confirm) * (1 - 0.7)
            confirmHits.append("confirmation URL")
        }
        // Form still visible and no strong phrase: probably not submitted yet.
        let formHits = formMarkers.filter { lower.contains($0) }.count
        if formHits >= 2 && confirm < 0.9 { confirm *= 0.5 }
        // "Submit application" alone must not count as "application submitted".
        if confirmHits == ["application submitted"] && lower.contains("submit application") && !info.isConfirmationPath { confirm *= 0.6 }

        let looksLikeEmail = ["from:", "to:", "subject:", "reply", "inbox", "unsubscribe", "sent from", "noreply", "no-reply", "do not reply"]
            .filter { lower.contains($0) }.count >= 2

        let candidates: [(Kind, Double, [String])] = [
            (.offer, offer, offerHits), (.rejection, reject, rejectHits), (.interview, interview, interviewHits),
            (.confirmation, confirm, confirmHits),
        ]
        // Later-stage messages win when comparably strong (a rejection email often also says "thank you for applying").
        var chosen: (Kind, Double, [String]) = (.none, 0, [])
        for candidate in candidates where candidate.1 >= 0.6 {
            if chosen.0 == .none || candidate.1 > chosen.1 + 0.15 { chosen = candidate }
        }
        let (company, title) = mentioned(in: text)
        return Detection(kind: chosen.0, confidence: chosen.1, evidence: chosen.2, mentionedCompany: company,
                         mentionedTitle: title, looksLikeEmail: looksLikeEmail)
    }

    /// Company/title phrases common to confirmation pages and emails.
    static func mentioned(in text: String) -> (company: String, title: String) {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "’", with: "'")
        func capture(_ pattern: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: flat) else { return "" }
            return String(flat[r]).trimmingCharacters(in: CharacterSet(charactersIn: " .,!:;\"'"))
        }
        // Case-sensitive inside the case-insensitive pattern: capitalised words only.
        let name = "((?-i:[A-Z][\\w&'.-]*(?:\\s+(?:of\\s+|&\\s+)?[A-Z][\\w&'.-]*){0,4}))"
        var company = capture("application was sent to " + name)
        if company.isEmpty { company = capture("(?:thank you|thanks) for applying to " + name + "(?:[.!,]|\\s+for|\\s+and|$)") }
        if company.isEmpty { company = capture("(?:applying|applied|application) (?:to|at|with) " + name + "(?:[.!,]|\\s+for|\\s+and|\\s+has|$)") }
        if company.isEmpty { company = capture("interest in (?:joining |working at )?" + name + "(?:[.!,]|\\s+and|$)") }
        if company.isEmpty { company = capture("(?:position|role|job|opening|opportunity) (?:at|with) " + name + "(?:[.!,]|\\s+and|\\s+has|$)") }
        if company.isEmpty { company = capture("(?:the )?" + name + " (?:recruiting|talent acquisition|hiring) team") }
        let roleNoun = "(?:position|role|job|opening|opportunity)"
        var title = capture("for (?:the|our) ([A-Z][\\w/&+#.,' -]{2,70}?) " + roleNoun)
        if title.isEmpty { title = capture("(?:position|role) of ([A-Z][\\w/&+#.' -]{2,70}?)(?:[.!,]| at | with |$)") }
        if title.isEmpty { title = capture("applying (?:for|to) (?:the )?([A-Z][\\w/&+#.' -]{2,70}?)(?: " + roleNoun + ")? at ") }
        if title.isEmpty { title = capture("job application for ([A-Z][\\w/&+#.' -]{2,70}?) at ") }
        if !title.isEmpty, !JobPostingParser.hasRoleWord(title) { title = "" }
        // Lines are joined with spaces, so the next sentence's first word can stick to the name.
        let sentenceStarts: Set<String> = ["You", "We", "Your", "Our", "The", "This", "Thank", "Thanks", "If", "Please", "Check",
                                           "Track", "View", "Back", "Apply", "Application", "Someone", "A", "An", "Hi", "Hello"]
        var words = company.split(separator: " ").map(String.init)
        // "Acme Robotics Hi Priya": cut at a greeting that started the next line.
        if let greeting = words.indices.dropFirst().first(where: { ["Hi", "Hello", "Dear", "Hey"].contains(words[$0]) }) {
            words = Array(words[..<greeting])
        }
        while words.count > 1, let last = words.last, sentenceStarts.contains(last) { words.removeLast() }
        company = words.joined(separator: " ")
        // A company capture that is actually a sentence word.
        if sentenceStarts.contains(company) || ["Us"].contains(company) { company = "" }
        return (company, title)
    }

    // MARK: Same job

    enum Verdict: Sendable, Equatable {
        case same(Double, String)
        case different(String)
        case uncertain(String)
    }

    /// Compares a captured confirmation (its URL, page title, OCR text) with a saved job.
    static func verify(job: JobPosting, confirmationText: String, url: String, pageTitle: String, detection: Detection) -> Verdict {
        let saved = JobPostingParser.urlInfo(job.sourceURL)
        let now = JobPostingParser.urlInfo(url)
        var reasons: [String] = []
        var score = 0.0

        // URL: same ATS host and the same job id, or the confirmation URL extends the posting URL.
        if !saved.host.isEmpty, saved.host == now.host {
            if !saved.jobID.isEmpty, saved.jobID == now.jobID {
                return .same(0.97, "Same job ID in the URL (\(saved.jobID)).")
            }
            if let a = URL(string: job.sourceURL)?.path, let b = URL(string: url)?.path, a.count > 8, b.hasPrefix(a) {
                return .same(0.95, "The confirmation URL continues the posting URL.")
            }
            if !saved.companySlug.isEmpty, saved.companySlug == now.companySlug {
                score += 0.35
                reasons.append("same company board")
            }
            if !saved.jobID.isEmpty, !now.jobID.isEmpty, saved.jobID != now.jobID, saved.source != "" {
                return .different("Different job ID in the URL (\(now.jobID) vs saved \(saved.jobID)).")
            }
        }

        let parsedNow = JobPostingParser.parse(text: confirmationText, url: url, pageTitle: pageTitle)
        let companyCandidates = [detection.mentionedCompany, parsedNow.company, JobPostingParser.prettySlug(now.companySlug)].filter { !$0.isEmpty }
        let titleCandidates = [detection.mentionedTitle, parsedNow.title].filter { !$0.isEmpty }

        let companyScore = companyCandidates.map { companySimilarity($0, job.company) }.max()
        // The saved company's name anywhere in the text also counts.
        let companyInText = !job.company.isEmpty && normalizeCompany(confirmationText).contains(normalizeCompany(job.company))
            && normalizeCompany(job.company).count >= 3
        let titleScore = titleCandidates.map { JobFitScorer.titleSimilarity($0, job.title) }.max()
        let titleInText = !job.title.isEmpty && confirmationText.lowercased().contains(job.title.lowercased())

        if let companyScore {
            if companyScore >= 0.8 { score += 0.45; reasons.append("company matches") }
            else if companyScore < 0.4 && !companyInText {
                return .different("The confirmation mentions \(companyCandidates.first ?? "another company"), not \(job.company).")
            }
        }
        if companyInText, (companyScore ?? 0) < 0.8 { score += 0.35; reasons.append("company named on page") }
        if (companyScore ?? 0) >= 0.8 || companyInText, titleCandidates.isEmpty, !titleInText {
            score += 0.15
            reasons.append("role not shown on the page")
        }
        if let titleScore {
            if titleScore >= 0.75 { score += 0.35; reasons.append("title matches") }
            else if titleScore < 0.3 && !titleInText && (companyScore ?? 0) >= 0.8 {
                return .different("Same company, but the role looks different (\(titleCandidates.first ?? "?") vs \(job.title)).")
            }
        }
        if titleInText, (titleScore ?? 0) < 0.75 { score += 0.3; reasons.append("title named on page") }

        if score >= 0.6 { return .same(min(0.95, score), capitalizeFirst(reasons.joined(separator: ", ")) + ".") }
        if score > 0 { return .uncertain("Only partly matches (\(reasons.joined(separator: ", ")))." ) }
        return .uncertain("The confirmation doesn't name the company or role, so it can't be tied to \(job.title) @ \(job.company).")
    }

    static let companySuffixes = ["inc", "inc.", "llc", "ltd", "ltd.", "corp", "corp.", "corporation", "co", "co.", "gmbh", "plc",
                                  "limited", "technologies", "technology", "labs", "group", "holdings", "the", "company", "hq", "ai", "io"]

    static func normalizeCompany(_ name: String) -> String {
        JobKeywords.words(name).filter { !companySuffixes.contains($0) }.joined(separator: " ")
    }

    /// 0…1: token containment or edit-distance ratio on the normalised names.
    static func companySimilarity(_ a: String, _ b: String) -> Double {
        let x = normalizeCompany(a), y = normalizeCompany(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        let xs = x.replacingOccurrences(of: " ", with: ""), ys = y.replacingOccurrences(of: " ", with: "")
        if xs == ys { return 1 }
        if xs.count >= 3, ys.count >= 3, xs.hasPrefix(ys) || ys.hasPrefix(xs) { return 0.85 }
        let tx = Set(x.split(separator: " ")), ty = Set(y.split(separator: " "))
        let containment = Double(tx.intersection(ty).count) / Double(min(tx.count, ty.count))
        return max(containment * 0.9, 1 - Double(levenshtein(xs, ys)) / Double(max(xs.count, ys.count)))
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func capitalizeFirst(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    // MARK: Expected response

    /// Days until a response is typical, by ATS/source.
    static func expectedResponseDays(source: String) -> Int {
        switch source {
        case "Greenhouse", "Lever", "Ashby", "Workable", "Wellfound", "BambooHR", "SmartRecruiters": 7
        case "LinkedIn", "Indeed", "Glassdoor": 10
        case "Workday", "iCIMS", "Taleo", "SuccessFactors", "Jobvite": 14
        default: 14
        }
    }
}

