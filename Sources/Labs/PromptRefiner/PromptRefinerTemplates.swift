import Foundation

// Deterministic fallback for Prompt Refiner: keyword domain detection, a bank
// of clarifying questions per domain, and a template that turns the rough
// prompt plus answers into a PromptSpec / ImagePromptSpec. Used when no model
// is available, when a model step fails, and to fill fields a model left empty.

enum PromptRefinerTemplates {
    // MARK: Domain

    private static let keywords: [(PromptDomain, [String])] = [
        (.image, ["image", "picture", "photo", "photograph", "logo", "illustration", "poster", "wallpaper",
                  "render", "drawing", "painting", "icon art", "thumbnail", "midjourney", "dall-e", "artwork"]),
        (.web, ["landing page", "website", "web page", "webpage", "homepage", "web app", "html", "css",
                "tailwind", "portfolio site", "ui", "ux", "frontend", "front-end", "dashboard design", "page for"]),
        (.code, ["code", "bug", "fix", "function", "script", "api", "error", "crash", "refactor", "test",
                 "compile", "build", "deploy", "swift", "python", "javascript", "typescript", "react", "sql query",
                 "repo", "endpoint", "class", "method", "debug", "exception", "regex", "cli", "app"]),
        (.writing, ["email", "e-mail", "write", "blog", "post", "essay", "letter", "copy", "tweet", "linkedin",
                    "cover letter", "newsletter", "caption", "story", "article", "speech", "message", "reply",
                    "rewrite", "headline", "bio", "proposal"]),
        (.data, ["analyze", "analyse", "data", "csv", "spreadsheet", "excel", "chart", "dataset", "metrics",
                 "statistics", "sql", "table", "kpi"]),
        (.planning, ["plan", "strategy", "roadmap", "marketing", "pitch", "business", "launch", "schedule",
                     "itinerary", "workout", "meal plan", "okr", "budget"]),
        (.research, ["explain", "research", "compare", "learn", "summarize", "summarise", "what is", "how does",
                     "why", "teach", "overview", "pros and cons", "difference between"]),
    ]

    /// Best-guess domain from keywords; the target breaks ties (an image
    /// model is always `.image`, Claude Code leans to `.code`).
    static func domain(for rough: String, target: PromptTarget) -> PromptDomain {
        if target == .imageModel { return .image }
        let text = " " + rough.lowercased() + " "
        var best: (PromptDomain, Int) = (.general, 0)
        for (domain, words) in keywords {
            let score = words.reduce(0) { $0 + (containsWord(text, $1) ? ($1.contains(" ") ? 2 : 1) : 0) }
            if score > best.1 { best = (domain, score) }
        }
        if target == .claudeCode, best.0 != .web { return .code }
        return best.0
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "\\b\(escaped)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Questions

    static func questions(for domain: PromptDomain, target: PromptTarget) -> [ClarifyingQuestion] {
        func q(_ label: String, _ question: String, _ options: [String]) -> ClarifyingQuestion {
            ClarifyingQuestion(label: label, question: question, options: options)
        }
        var list: [ClarifyingQuestion]
        switch domain {
        case .code:
            list = [
                q("Programming language / framework", "Which programming language, framework or part of the codebase is this about?",
                  ["Swift / SwiftUI", "Python", "TypeScript / React", "Other (type it)"]),
                q("Exact symptom or error", "What exactly is wrong or should change?",
                  ["It crashes or throws", "Wrong output", "Build or type errors", "New feature"]),
                q("Verification", "How should the result be verified?",
                  ["Run the existing tests", "Write a failing test first", "Build must pass", "Manual check steps"]),
                q("Scope", "Any limits on the change?",
                  ["Smallest possible change", "Refactoring is OK", "Keep the public API", "No new dependencies"]),
            ]
        case .web:
            list = [
                q("Product & audience", "What is the page for, and who is it aimed at?",
                  ["SaaS product", "Mobile app", "Agency / services", "Personal portfolio"]),
                q("Call to action", "What should visitors do?",
                  ["Sign up", "Book a demo", "Join a waitlist", "Buy now"]),
                q("Tech stack", "How should it be built?",
                  ["Plain HTML + CSS", "React + Tailwind", "Next.js", "Design only, no code"]),
                q("Visual style", "What look and feel?",
                  ["Minimal and clean", "Bold and colorful", "Dark and techy", "Playful"]),
            ]
        case .writing:
            list = [
                q("Audience", "Who is going to read it?",
                  ["A prospective client", "A hiring manager", "A colleague", "General public"]),
                q("Goal", "What should the reader do or feel afterwards?",
                  ["Reply or book a call", "Buy or sign up", "Understand an update", "Be persuaded"]),
                q("Tone", "What tone?",
                  ["Friendly", "Professional", "Bold and direct", "Warm and personal"]),
                q("Length", "How long?",
                  ["Under 100 words", "About 150-200 words", "One page", "Long-form"]),
            ]
        case .image:
            list = [
                q("Subject", "What is the main subject, in a few words?",
                  ["A person", "A product", "A landscape", "An abstract scene"]),
                q("Style", "Which visual style?",
                  ["Photorealistic", "3D render", "Flat illustration", "Watercolor"]),
                q("Aspect ratio", "What shape should the image be?",
                  ["1:1 square", "16:9 wide", "9:16 tall", "4:3"]),
                q("Mood", "What mood or lighting?",
                  ["Bright and cheerful", "Moody and cinematic", "Soft and calm", "Dramatic contrast"]),
            ]
        case .data:
            list = [
                q("Data", "What data will you provide?",
                  ["CSV file", "Spreadsheet", "SQL database", "JSON"]),
                q("Question", "What question should the analysis answer?",
                  ["Trends over time", "Compare groups", "Find anomalies", "Forecast"]),
                q("Output", "What should come back?",
                  ["Summary + key numbers", "Charts", "Python code", "SQL query"]),
            ]
        case .research:
            list = [
                q("Audience level", "Who is the explanation for?",
                  ["Beginner", "Intermediate", "Expert"]),
                q("Depth", "How deep should it go?",
                  ["Quick overview", "Step by step", "Deep dive with sources"]),
                q("Format", "What format works best?",
                  ["Bullet summary", "Report with headings", "Comparison table"]),
            ]
        case .planning:
            list = [
                q("Goal", "What outcome should the plan achieve?",
                  ["Grow revenue", "Launch something", "Save time", "Personal goal"]),
                q("Timeframe", "Over what timeframe?",
                  ["This week", "30 days", "This quarter", "A year"]),
                q("Constraints", "What constraints apply?",
                  ["Small budget", "Solo / small team", "Fixed deadline", "None in particular"]),
                q("Format", "What format?",
                  ["Step-by-step checklist", "Week-by-week table", "Short strategy memo"]),
            ]
        case .general:
            list = [
                q("Goal", "What is the result for, and who will use it?",
                  ["For me", "For my team", "For customers", "For a class / school"]),
                q("Format", "What format should the answer take?",
                  ["Short answer", "Bullet points", "Step-by-step", "Detailed report"]),
                q("Tone", "What tone?",
                  ["Neutral", "Friendly", "Formal", "Concise and direct"]),
            ]
        }
        if target == .claudeCode, domain == .web {
            list[2] = q("Verification", "How should the result be checked?",
                        ["Screenshot and compare", "Run the dev server", "Lighthouse / a11y check", "Unit tests"])
        }
        return list
    }

    /// What the model should consider asking about, from the template bank
    /// ("audience, goal, tone, length").
    static func detailHint(domain: PromptDomain, target: PromptTarget) -> String {
        var labels = questions(for: domain, target: target).map { $0.label.lowercased() }
        if target == .claudeCode, !labels.contains("verification") { labels.append("how to check the result") }
        if let index = labels.firstIndex(of: "verification") { labels[index] = "how to verify the result (tests, build, screenshot)" }
        return labels.joined(separator: ", ")
    }

    // MARK: Text template

    static func role(for domain: PromptDomain, target: PromptTarget) -> String {
        switch domain {
        case .code:
            return target == .claudeCode
                ? "You are a senior software engineer working in this repository."
                : "You are a senior software engineer and careful code reviewer."
        case .web: return "You are a senior product designer and front-end engineer who builds high-converting web pages."
        case .writing: return "You are an expert writer and editor who adapts tone to the audience."
        case .image: return "You are an art director."
        case .data: return "You are a senior data analyst."
        case .research: return "You are a patient expert teacher and researcher."
        case .planning: return "You are an experienced strategist and planner."
        case .general: return "You are a knowledgeable, practical assistant."
        }
    }

    static func defaultOutputFormat(for domain: PromptDomain, target: PromptTarget) -> String {
        switch domain {
        case .code:
            return target == .claudeCode
                ? "Make the change in the codebase, then report what changed (files and a one-line reason each) and the verification output."
                : "A short diagnosis, then the corrected code in one code block, then a brief explanation of the change."
        case .web: return "A complete, responsive page: section-by-section structure with final copy, then the code (or the design spec if no code)."
        case .writing: return "The finished text only, ready to send, with a subject line if it is an email."
        case .image: return "One image."
        case .data: return "Key findings first as bullets with numbers, then the method and any code used."
        case .research: return "Short headings with concise paragraphs or bullets; end with a 2-3 line summary."
        case .planning: return "A numbered plan with owners or timing for each step, then the top risks."
        case .general: return "A clear, well-structured answer with headings or bullets where they help."
        }
    }

    static func defaultCriteria(for domain: PromptDomain, target: PromptTarget) -> [String] {
        switch domain {
        case .code:
            return target == .claudeCode
                ? ["The change addresses the root cause, not just the symptom", "Existing tests and the build pass", "No unrelated files are changed"]
                : ["The code compiles and handles edge cases", "The explanation names the root cause"]
        case .web: return ["Works on mobile and desktop widths", "The call to action is visible without scrolling", "Copy is specific to the product, no lorem ipsum"]
        case .writing: return ["Matches the requested tone and length", "Has one clear call to action", "No clichés or filler sentences"]
        case .image: return []
        case .data: return ["Every claim is backed by a number from the data", "Assumptions and data issues are stated"]
        case .research: return ["Accurate and appropriate for the audience level", "Uncertain points are flagged instead of guessed"]
        case .planning: return ["Each step is concrete and actionable", "Fits the stated timeframe and constraints"]
        case .general: return ["Directly answers the request", "No unnecessary preamble"]
        }
    }

    static func defaultInputs(for domain: PromptDomain, target: PromptTarget) -> [String] {
        switch domain {
        case .code: return target == .claudeCode ? ["The relevant file paths (@path/to/file)", "The exact error message or failing test"] : ["The code", "The exact error message"]
        case .data: return ["The data (or a sample of it) and column descriptions"]
        default: return []
        }
    }

    static func sentence(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let first = text.first else { return text }
        if first.isLowercase { text = first.uppercased() + text.dropFirst() }
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text
    }

    static func title(from rough: String) -> String {
        // Up to six words, without a dangling "to a" / "for my" at the end.
        var words = rough.split(whereSeparator: { $0.isWhitespace }).prefix(6).map(String.init)
        let dangling: Set<String> = ["a", "an", "the", "to", "for", "of", "my", "our", "your", "and", "or", "with", "in", "on", "at", "about", "that"]
        while words.count > 1, let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        let cleaned = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        guard let first = cleaned.first else { return "Refined prompt" }
        return first.uppercased() + cleaned.dropFirst()
    }

    /// "Label: answer" lines for the answered questions.
    static func contextLines(_ questions: [ClarifyingQuestion]) -> [String] {
        questions.compactMap { question in
            guard let answer = question.answer else { return nil }
            guard !question.label.isEmpty else { return "\(question.question) \(answer)" }
            return "\(question.label.trimmingCharacters(in: CharacterSet(charactersIn: "?: "))): \(answer)"
        }
    }

    static func spec(rough: String, domain: PromptDomain, target: PromptTarget, questions: [ClarifyingQuestion]) -> PromptSpec {
        var spec = PromptSpec()
        spec.title = title(from: rough)
        spec.role = role(for: domain, target: target)
        spec.context = contextLines(questions)
        spec.objective = sentence(rough) + (spec.context.isEmpty ? "" : " Tailor it to the details below.")
        spec.requirements = requirements(domain: domain, target: target, questions: questions)
        spec.constraints = constraints(domain: domain, target: target, questions: questions)
        spec.inputs = defaultInputs(for: domain, target: target)
        spec.outputFormat = defaultOutputFormat(for: domain, target: target)
        spec.acceptanceCriteria = defaultCriteria(for: domain, target: target)
        return spec
    }

    private static func answer(_ questions: [ClarifyingQuestion], _ label: String) -> String? {
        questions.first { $0.label == label }?.answer
    }

    private static func requirements(domain: PromptDomain, target: PromptTarget, questions: [ClarifyingQuestion]) -> [String] {
        switch domain {
        case .code:
            var items = ["Find the root cause before changing code", "Explain the cause in one or two sentences"]
            if target == .claudeCode {
                items.insert("Explore the relevant files first; if the change touches several files, outline a short plan before editing", at: 0)
            }
            if let check = answer(questions, "Verification") { items.append("Verify by: \(check)") }
            return items
        case .web:
            return ["Hero with a specific headline and subheadline", "Benefits, social proof and FAQ sections", "One primary call to action repeated at the end"]
        case .writing:
            return ["Open with a specific, relevant first line", "Keep paragraphs short"]
        case .data:
            return ["Check the data for missing or odd values first", "Show the numbers behind each finding"]
        case .research:
            return ["Define key terms the first time they appear", "Use a concrete example"]
        case .planning:
            return ["Break the goal into milestones", "Make every step start with a verb"]
        case .image, .general:
            return []
        }
    }

    private static func constraints(domain: PromptDomain, target: PromptTarget, questions: [ClarifyingQuestion]) -> [String] {
        var items: [String] = []
        if let scope = answer(questions, "Scope") { items.append(scope) }
        switch domain {
        case .code: items.append("Don't change behavior outside the task")
        case .writing: items.append("No generic filler or exaggerated claims")
        case .research: items.append("Say when something is uncertain instead of guessing")
        default: break
        }
        return items
    }

    // MARK: Image template

    static func imageSpec(rough: String, questions: [ClarifyingQuestion]) -> ImagePromptSpec {
        var spec = ImagePromptSpec()
        spec.title = title(from: rough)
        var subject = rough.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["make an image of", "make a picture of", "generate an image of", "create an image of", "draw", "make", "create", "generate"]
        where subject.lowercased().hasPrefix(prefix + " ") {
            subject = String(subject.dropFirst(prefix.count + 1))
            break
        }
        if let detail = answer(questions, "Subject"), !detail.isEmpty { subject += ", " + detail.lowercased() }
        spec.subject = subject
        spec.style = answer(questions, "Style") ?? "High-quality digital artwork"
        spec.mood = answer(questions, "Mood") ?? ""
        if let ratio = answer(questions, "Aspect ratio"),
           let match = ImagePromptSpec.aspectRatios.first(where: { ratio.hasPrefix($0) }) {
            spec.aspectRatio = match
        }
        spec.composition = "Clear focal point on the subject, uncluttered background"
        spec.lighting = "Soft, natural light"
        spec.details = ["Sharp focus", "High detail"]
        spec.avoid = ["text", "watermarks", "distorted hands or faces", "extra limbs"]
        return spec
    }
}
