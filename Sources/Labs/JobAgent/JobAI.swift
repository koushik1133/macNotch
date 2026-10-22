import Foundation

/// Model refinement for resumes and postings. The deterministic parsers run
/// first; a model may then fill gaps, but every value it returns must be
/// grounded in the source text or it is dropped.
///
/// Order: Groq only when the user turned on "Use Groq for job analysis" and a
/// key exists (text only, never the screenshot); otherwise the on-device
/// Apple Intelligence model when enabled and available; otherwise rules only.
enum JobAI {
    enum Engine: String, Sendable { case rules, onDevice = "on-device", groq }

    struct Options: Sendable {
        var useOnDevice: Bool
        var useGroq: Bool
        var groqKey: String?

        static func current() -> Options {
            let useGroq = JobAgentSettings.useGroq && ClickyKeychain.hasKey()
            return Options(
                useOnDevice: JobAgentSettings.useOnDeviceModel,
                useGroq: useGroq,
                // Read only when the user opted in (may show the keychain prompt once after a rebuild).
                groqKey: useGroq ? ClickyKeychain.load() : nil
            )
        }

        var engine: Engine {
            if useGroq, !(groqKey ?? "").isEmpty { return .groq }
            if useOnDevice, MeetingAIBackend.onDeviceAvailable { return .onDevice }
            return .rules
        }
    }

    // MARK: Schemas

    static let profileSchema = MeetingAISchema.object(name: "ResumeProfile", properties: [
        .init(name: "name", description: "The candidate's full name as written at the top", schema: .string),
        .init(name: "headline", description: "The candidate's current or target job title as written", schema: .string),
        .init(name: "yearsExperience", description: "Total years of professional experience as a number, or empty", schema: .string),
        .init(name: "skills", description: "Skills, tools, languages and frameworks named in the resume, exactly as written", schema: .array(.string, maxItems: 40)),
        .init(name: "experience", description: "Jobs held, most recent first", schema: .array(.object(name: "Role", properties: [
            .init(name: "title", description: "Job title as written", schema: .string),
            .init(name: "company", description: "Employer as written", schema: .string),
            .init(name: "start", description: "Start date as written, e.g. Mar 2021", schema: .string),
            .init(name: "end", description: "End date as written, or Present", schema: .string),
        ]), maxItems: 8)),
        .init(name: "education", description: "Degrees", schema: .array(.object(name: "Degree", properties: [
            .init(name: "degree", description: "Degree as written, e.g. B.S.", schema: .string),
            .init(name: "field", description: "Field of study", schema: .string),
            .init(name: "school", description: "School name", schema: .string),
            .init(name: "year", description: "Graduation year", schema: .string),
        ]), maxItems: 4)),
    ])

    static let postingSchema = MeetingAISchema.object(name: "JobPosting", properties: [
        .init(name: "company", description: "Hiring company name as written on the page", schema: .string),
        .init(name: "title", description: "Job title as written", schema: .string),
        .init(name: "location", description: "Location as written (city, Remote, Hybrid)", schema: .string),
        .init(name: "salary", description: "Salary or pay range exactly as written, or empty", schema: .string),
        .init(name: "employmentType", description: "Full-time, Part-time, Contract, Internship, or empty", schema: .string),
        .init(name: "deadline", description: "Application deadline as written, or empty", schema: .string),
        .init(name: "requirements", description: "Required qualifications, one per item, copied from the text", schema: .array(.string, maxItems: 15)),
        .init(name: "niceToHave", description: "Preferred / nice-to-have qualifications, copied from the text", schema: .array(.string, maxItems: 8)),
    ])

    static let extractionRules = """
    Copy values exactly as they appear in the text. Never guess, infer or add anything that isn't written. \
    Leave a field empty when the text doesn't state it. Ignore website navigation, ads and other job listings.
    """

    // MARK: Profile

    static func refineProfile(_ base: ResumeProfile, text: String, options: Options) async -> ResumeProfile {
        let engine = options.engine
        guard engine != .rules else { return base }
        let source = String(text.prefix(engine == .groq ? 24_000 : 6_500))
        let instructions = "You extract structured data from a resume. " + extractionRules
        guard let object = await run(engine: engine, options: options, instructions: instructions,
                                     prompt: "Resume:\n\"\"\"\n\(source)\n\"\"\"", schema: profileSchema, maxTokens: 900) else {
            return base
        }
        var profile = base
        let lower = text.lowercased()
        func grounded(_ value: String?) -> String? {
            guard let value, value.count >= 2, lower.contains(value.lowercased()) else { return nil }
            return value
        }
        if profile.name.isEmpty, let name = grounded(MeetingAIJSON.string(object["name"])) { profile.name = name }
        if profile.headline.isEmpty, let headline = grounded(MeetingAIJSON.string(object["headline"])) { profile.headline = headline }
        for raw in MeetingAIJSON.strings(object["skills"], limit: 40) {
            guard grounded(raw) != nil else { continue }
            let name = JobSkills.canonical(raw) ?? raw
            if !profile.skills.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { profile.skills.append(name) }
        }
        if profile.experience.isEmpty {
            for role in MeetingAIJSON.objects(object["experience"]) {
                guard let title = grounded(MeetingAIJSON.string(role["title"])) else { continue }
                let company = grounded(MeetingAIJSON.string(role["company"])) ?? ""
                let start = MeetingAIJSON.string(role["start"]) ?? ""
                let end = MeetingAIJSON.string(role["end"]) ?? ""
                let range = JobResumeParser.parseRange("\(start) - \(end)")
                profile.experience.append(ResumeExperience(title: title, company: company, start: start, end: end,
                                                           months: range?.months, highlights: []))
            }
            if profile.yearsExperience == nil { profile.yearsExperience = JobResumeParser.totalYears(profile.experience) }
        }
        if profile.education.isEmpty {
            for entry in MeetingAIJSON.objects(object["education"]) {
                guard let degree = grounded(MeetingAIJSON.string(entry["degree"])) else { continue }
                let level = JobResumeParser.degreeLevel(degree + " degree")
                profile.education.append(ResumeEducation(
                    degree: degree, field: grounded(MeetingAIJSON.string(entry["field"])) ?? "",
                    school: grounded(MeetingAIJSON.string(entry["school"])) ?? "",
                    year: grounded(MeetingAIJSON.string(entry["year"])) ?? "", level: level
                ))
            }
        }
        if profile.yearsExperience == nil, let raw = MeetingAIJSON.string(object["yearsExperience"]), let years = Double(raw.filter { $0.isNumber || $0 == "." }),
           years > 0, years < 50, lower.contains(raw.lowercased().filter { $0.isNumber }) {
            profile.yearsExperience = years
        }
        profile.source = engine.rawValue
        return profile
    }

    // MARK: Posting

    static func refinePosting(_ base: JobPosting, options: Options) async -> JobPosting {
        let engine = options.engine
        guard engine != .rules, base.text.count >= 200 else { return base }
        let source = String(base.text.prefix(engine == .groq ? 24_000 : 6_500))
        var context = ""
        if !base.pageTitle.isEmpty { context += "Page title: \(base.pageTitle)\n" }
        if !base.sourceURL.isEmpty { context += "URL: \(base.sourceURL)\n" }
        let instructions = "You extract a job posting from text read off a screenshot. " + extractionRules
        guard let object = await run(engine: engine, options: options, instructions: instructions,
                                     prompt: context + "Text:\n\"\"\"\n\(source)\n\"\"\"", schema: postingSchema, maxTokens: 900) else {
            return base
        }
        var posting = base
        let haystack = (base.text + "\n" + base.pageTitle).lowercased()
        func grounded(_ key: String) -> String? {
            guard let value = MeetingAIJSON.string(object[key]), value.count >= 2, haystack.contains(value.lowercased()) else { return nil }
            return value
        }
        // Rules win where they found something; the model fills gaps.
        if posting.company.isEmpty, let v = grounded("company") { posting.company = v }
        if posting.title.isEmpty, let v = grounded("title"), JobPostingParser.hasRoleWord(v) { posting.title = v }
        if posting.location.isEmpty, let v = grounded("location") { posting.location = v }
        if posting.salary.isEmpty, let v = grounded("salary"), v.rangeOfCharacter(from: .decimalDigits) != nil { posting.salary = v }
        if posting.employmentType.isEmpty, let v = grounded("employmentType") { posting.employmentType = v }
        if posting.deadline.isEmpty, let v = grounded("deadline") { posting.deadline = v }

        func groundedLines(_ key: String, limit: Int) -> [String] {
            MeetingAIJSON.strings(object[key], limit: limit).filter { line in
                let words = JobKeywords.words(line).filter { $0.count > 2 }
                guard !words.isEmpty else { return false }
                let found = words.filter { haystack.contains($0) }.count
                return Double(found) / Double(words.count) >= 0.8
            }
        }
        if posting.requirements.isEmpty {
            posting.requirements = groundedLines("requirements", limit: 15)
            let skills = JobSkills.names(in: posting.requirements.joined(separator: "\n"))
            if !skills.isEmpty {
                posting.requiredSkills = skills
                posting.preferredSkills.removeAll { skills.contains($0) }
            }
        }
        if posting.preferred.isEmpty {
            posting.preferred = groundedLines("niceToHave", limit: 8)
            for skill in JobSkills.names(in: posting.preferred.joined(separator: "\n")) where !posting.requiredSkills.contains(skill) && !posting.preferredSkills.contains(skill) {
                posting.preferredSkills.append(skill)
            }
        }
        if posting.minYears == nil { posting.minYears = JobPostingParser.minYears(in: posting.requirements) }
        posting.extractedBy = "rules+" + engine.rawValue
        return posting
    }

    // MARK: Rewording (tailoring)

    /// One bullet reworded to use the posting's vocabulary, or nil when the
    /// model is off/unavailable or the rewrite adds anything not in the resume.
    static func reword(_ bullet: String, keywords: [String], resumeText: String, options: Options) async -> String? {
        let engine = options.engine
        guard engine != .rules else { return nil }
        let instructions = """
        You edit one resume bullet. Keep every fact, number and technology exactly as in the original. \
        Do not add skills, tools, numbers, employers or results that are not in the original bullet. \
        You may reorder words and use these posting terms only where the original already describes the same thing. \
        Reply with the edited bullet only.
        """
        let prompt = "Posting terms: \(keywords.prefix(10).joined(separator: ", "))\nOriginal bullet: \(bullet)"
        let reply: String?
        switch engine {
        case .groq:
            reply = try? await MeetingAIBackend.groq(
                config: MeetingAIConfig(useGroq: true, groqKey: options.groqKey), system: instructions, user: prompt,
                json: false, maxTokens: 200, reasoningEffort: "low", timeout: 20
            )
        case .onDevice:
            reply = try? await MeetingAIBackend.onDevice(instructions: instructions, prompt: prompt, schema: nil,
                                                          maxTokens: 160, timeout: 20, permissive: true)
        case .rules:
            reply = nil
        }
        guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"•-"))),
              !text.isEmpty, text != bullet, text.count <= bullet.count * 2,
              JobTailor.isGrounded(rewrite: text, original: bullet, resumeText: resumeText) else { return nil }
        return text
    }

    // MARK: Plumbing

    private static func run(engine: Engine, options: Options, instructions: String, prompt: String,
                            schema: MeetingAISchema, maxTokens: Int) async -> [String: Any]? {
        do {
            let raw: String
            switch engine {
            case .groq:
                let system = instructions + "\nReply with one JSON object shaped like \(schema.outline).\n" + schema.fieldGuide
                raw = try await MeetingAIBackend.groq(
                    config: MeetingAIConfig(useGroq: true, groqKey: options.groqKey), system: system, user: prompt,
                    json: true, maxTokens: maxTokens + 400, reasoningEffort: "low", timeout: 30
                )
            case .onDevice:
                raw = try await MeetingAIBackend.onDevice(instructions: instructions, prompt: prompt, schema: schema,
                                                          maxTokens: maxTokens, timeout: 40, permissive: true)
            case .rules:
                return nil
            }
            return MeetingAIJSON.object(from: raw)
        } catch {
            AppLog.log("Job Agent: \(engine.rawValue) extraction failed: \(error.localizedDescription)")
            return nil
        }
    }
}
