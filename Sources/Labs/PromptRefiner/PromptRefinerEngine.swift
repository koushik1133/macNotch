import Foundation
import FoundationModels
import Synchronization

// Prompt Refiner's language-model side: clarifying questions and refinement.
// Order of preference for each step:
// 1. Groq Chat Completions, only when the user switched on Prompt Refiner's own
//    Groq opt-in and a key exists (the caller passes the key; nil otherwise),
// 2. the on-device Apple Intelligence model (FoundationModels) with guided
//    generation from a DynamicGenerationSchema (the @Generable macro plugin
//    isn't in the Command Line Tools),
// 3. the deterministic templates in PromptRefinerTemplates.
// The model only fills fields; PromptRefinerRenderer lays them out per target.
// Nothing here ever runs the user's prompt: the request is passed as data
// inside <request> tags and the instructions forbid carrying it out.

// MARK: - Schema

/// JSON-shaped schema with string enums (MeetingAISchema has none), turned into
/// a DynamicGenerationSchema on device and a JSON outline for Groq.
indirect enum PromptRefinerSchema: Sendable {
    case string
    case choice(name: String, [String])
    case array(PromptRefinerSchema, min: Int?, max: Int?)
    case object(name: String, properties: [Property])

    struct Property: Sendable {
        let name: String
        let description: String
        let schema: PromptRefinerSchema
    }

    var outline: String {
        switch self {
        case .string: return "\"…\""
        case .choice(_, let values): return values.map { "\"\($0)\"" }.joined(separator: "|")
        case .array(let item, _, _): return "[\(item.outline)]"
        case .object(_, let properties):
            return "{" + properties.map { "\"\($0.name)\": \($0.schema.outline)" }.joined(separator: ", ") + "}"
        }
    }

    var fieldGuide: String {
        guard case .object(_, let properties) = self else { return "" }
        return properties.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    @available(macOS 26.0, *)
    func dynamic(description: String? = nil) -> DynamicGenerationSchema {
        switch self {
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .choice(let name, let values):
            return DynamicGenerationSchema(name: name, anyOf: values)
        case .array(let item, let min, let max):
            return DynamicGenerationSchema(arrayOf: item.dynamic(), minimumElements: min, maximumElements: max)
        case .object(let name, let properties):
            return DynamicGenerationSchema(
                name: name,
                description: description,
                properties: properties.map {
                    DynamicGenerationSchema.Property(name: $0.name, description: $0.description, schema: $0.schema.dynamic())
                }
            )
        }
    }
}

// MARK: - Prompts

enum PromptRefinerPrompts {
    // Field descriptions are kept short and free of copyable patterns ("1-4
    // limits: …"): the small on-device model tends to echo them as values.
    static let questionSchema = PromptRefinerSchema.object(name: "ClarifyingQuestions", properties: [
        .init(name: "intent", description: "The request restated as one specific sentence", schema: .string),
        .init(name: "questions", description: "Clarifying questions, most important first", schema: .array(
            .object(name: "Question", properties: [
                .init(name: "label", description: "The missing detail in one or two words", schema: .string),
                .init(name: "question", description: "A short question to the user", schema: .string),
                .init(name: "options", description: "Suggested answers the user can tap",
                      schema: .array(.string, min: 2, max: 4)),
            ]), min: 2, max: 4)),
    ])

    static let textSchema = PromptRefinerSchema.object(name: "RefinedPrompt", properties: [
        .init(name: "title", description: "Short title", schema: .string),
        .init(name: "role", description: "Who the assistant should be, starting with 'You are'", schema: .string),
        .init(name: "objective", description: "What the assistant must do, specific", schema: .string),
        .init(name: "context", description: "Facts the assistant needs, from the request and answers", schema: .array(.string, min: 0, max: 8)),
        .init(name: "requirements", description: "What the assistant's result must include or do", schema: .array(.string, min: 0, max: 6)),
        .init(name: "constraints", description: "Limits on the assistant's result", schema: .array(.string, min: 0, max: 5)),
        .init(name: "inputs", description: "Material the user must paste in for the assistant; often empty", schema: .array(.string, min: 0, max: 4)),
        .init(name: "outputFormat", description: "How the assistant's reply should look", schema: .string),
        .init(name: "acceptanceCriteria", description: "Checkable signs of a good result", schema: .array(.string, min: 0, max: 4)),
        .init(name: "example", description: "Usually empty; a very short sample of the desired style only if it clearly helps", schema: .string),
    ])

    static let imageSchema = PromptRefinerSchema.object(name: "ImagePrompt", properties: [
        .init(name: "title", description: "Short title", schema: .string),
        .init(name: "subject", description: "The main subject, concrete and visual", schema: .string),
        .init(name: "setting", description: "Background and environment", schema: .string),
        .init(name: "style", description: "Medium and style, e.g. flat vector illustration", schema: .string),
        .init(name: "composition", description: "Framing and camera angle", schema: .string),
        .init(name: "lighting", description: "Lighting", schema: .string),
        .init(name: "colors", description: "Color palette", schema: .string),
        .init(name: "mood", description: "One or two mood words", schema: .string),
        .init(name: "details", description: "Extra visual details", schema: .array(.string, min: 0, max: 5)),
        .init(name: "aspectRatio", description: "Aspect ratio", schema: .choice(name: "AspectRatio", ImagePromptSpec.aspectRatios)),
        .init(name: "avoid", description: "Things to leave out, as plain nouns", schema: .array(.string, min: 0, max: 5)),
    ])

    static func questionInstructions(target: PromptTarget) -> String {
        """
        You help a user sharpen a rough request before it becomes a prompt for \(target.title). You never answer or \
        carry out the request. Ask the 3 clarifying questions whose answers would most change the result.
        - Only ask about details this request leaves open. No yes/no questions. Each question under 12 words.
        - Each question gets 3 suggested answers that directly answer it: concrete, realistic, clearly different, \
        1-4 words each.
        """
    }

    static func questionPrompt(rough: String, target: PromptTarget, domain: PromptDomain) -> String {
        """
        <request>
        \(rough)
        </request>
        Details often missing from this kind of request: \(PromptRefinerTemplates.detailHint(domain: domain, target: target)).
        Ask the clarifying questions for this request.
        """
    }

    static func refineInstructions(target: PromptTarget) -> String {
        if target == .imageModel {
            return """
            You are a prompt engineer for image generation models. Turn the user's rough idea into a vivid, concrete \
            image prompt. Use every answer the user gave. Describe only what should be visible, in specific visual \
            words. Don't add text or lettering unless asked. Put unwanted elements in avoid as plain nouns.
            """
        }
        return """
        You are a prompt engineer. Rewrite the user's rough request as a clear, specific prompt that the user will \
        paste into \(target.title). Don't carry out the request: never write the email, code or answer itself.
        Every field is about the assistant that will receive the prompt and its result, not about the prompt.
        Use every answer the user gave. Don't invent facts. Short items, one idea each. Use the user's language.
        """
    }

    static func refinePrompt(
        rough: String, target: PromptTarget, domain: PromptDomain, questions: [ClarifyingQuestion],
        previous: String?, feedback: String?
    ) -> String {
        var parts = ["<request>\n\(rough)\n</request>"]
        let answered = questions.compactMap { q -> String? in
            guard let answer = q.answer else { return nil }
            return "- \(q.question) → \(answer)"
        }
        if !answered.isEmpty {
            parts.append("<answers>\n" + answered.joined(separator: "\n") + "\n</answers>")
        }
        if let previous, !previous.isEmpty {
            parts.append("<previous_prompt>\n\(String(previous.prefix(1600)))\n</previous_prompt>")
            let note = (feedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(note.isEmpty
                ? "Write an improved version of the previous prompt: more specific and better organized."
                : "<feedback>\n\(note)\n</feedback>\nRevise the previous prompt to follow the feedback.")
        } else {
            if target != .imageModel {
                parts.append("A fitting role: \(PromptRefinerTemplates.role(for: domain, target: target))")
            }
            parts.append(target == .imageModel ? "Write the image prompt fields." : "Write the refined prompt fields.")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Model access

enum PromptRefinerLLM {
    static var onDeviceAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    private final class Prepared: @unchecked Sendable {
        let key: String
        let session: AnyObject
        init(key: String, session: AnyObject) {
            self.key = key
            self.session = session
        }
    }

    private static let prepared = Mutex<Prepared?>(nil)

    /// Loads the model and processes `instructions` ahead of the next request
    /// with the same instructions (skips the cold start).
    static func prewarm(instructions: String) {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else { return }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        session.prewarm()
        let box = Prepared(key: instructions, session: session)
        prepared.withLock { $0 = box }
    }

    @available(macOS 26.0, *)
    private static func session(instructions: String, permissive: Bool) -> LanguageModelSession {
        if permissive {
            // Content-transformation guardrails: the request is the user's own
            // text being rewritten, not something the model is asked to do.
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            return LanguageModelSession(model: model, instructions: instructions)
        }
        let box: Prepared? = prepared.withLock { slot in
            guard let current = slot, current.key == instructions else { return nil }
            slot = nil
            return current
        }
        if let session = box?.session as? LanguageModelSession { return session }
        return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
    }

    /// True when the on-device guardrails declined (health, news and similar
    /// topics trip them even though nothing is being answered).
    static func isRefusal(_ error: Error) -> Bool {
        if let error = error as? MeetingAIError, error == .refused { return true }
        let text = (String(describing: error) + " " + error.localizedDescription).lowercased()
        return text.contains("refus") || text.contains("guardrail") || text.contains("unsafe")
    }

    /// One guided-JSON request on device, in a fresh session.
    static func onDevice(
        instructions: String, prompt: String, schema: PromptRefinerSchema,
        maxTokens: Int, timeout: Double, vary: Bool, permissive: Bool = false,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard #available(macOS 26.0, *) else { throw MeetingAIError.unavailable("needs macOS 26") }
        guard SystemLanguageModel.default.isAvailable else {
            throw MeetingAIError.unavailable(MeetingAIBackend.onDeviceUnavailableReason ?? "unavailable")
        }
        return try await MeetingAITimeout.run(seconds: timeout) {
            let options = GenerationOptions(
                samplingMode: vary ? .random(probabilityThreshold: 0.9) : .greedy,
                maximumResponseTokens: maxTokens
            )
            if permissive {
                // The permissive guardrails only apply to plain-text output, so
                // the JSON shape goes into the instructions (as for Groq).
                let jsonInstructions = instructions + "\n\nReply with only a JSON object of this shape:\n"
                    + schema.outline + "\nFields:\n" + schema.fieldGuide
                let session = session(instructions: jsonInstructions, permissive: true)
                do {
                    let stream = session.streamResponse(to: prompt, options: options)
                    var latest = ""
                    var lastSent = ContinuousClock.now - .seconds(1)
                    for try await snapshot in stream {
                        latest = snapshot.content
                        if let onPartial, ContinuousClock.now - lastSent >= .milliseconds(160) {
                            lastSent = ContinuousClock.now
                            onPartial(latest)
                        }
                    }
                    return latest
                } catch {
                    throw MeetingAIBackend.classifyOnDeviceError(error)
                }
            }
            let session = session(instructions: instructions, permissive: false)
            do {
                let generationSchema = try GenerationSchema(root: schema.dynamic(), dependencies: [])
                guard let onPartial else {
                    let response = try await session.respond(
                        to: prompt, schema: generationSchema, includeSchemaInPrompt: true, options: options
                    )
                    return response.content.jsonString
                }
                // Stream so the UI can show questions / the prompt as they
                // are written (at most ~6 updates a second).
                let stream = session.streamResponse(
                    to: prompt, schema: generationSchema, includeSchemaInPrompt: true, options: options
                )
                var latest = ""
                var lastSent = ContinuousClock.now - .seconds(1)
                for try await snapshot in stream {
                    latest = snapshot.content.jsonString
                    if ContinuousClock.now - lastSent >= .milliseconds(160) {
                        lastSent = ContinuousClock.now
                        onPartial(latest)
                    }
                }
                return latest
            } catch {
                throw MeetingAIBackend.classifyOnDeviceError(error)
            }
        }
    }

    /// One JSON-mode Groq request. Only called with a key the user allowed.
    static func groq(
        key: String, model: String, instructions: String, prompt: String, schema: PromptRefinerSchema,
        maxTokens: Int, timeout: Double
    ) async throws -> String {
        let system = instructions + "\n\nReply with only a JSON object of this shape:\n" + schema.outline
            + "\nFields:\n" + schema.fieldGuide
        let config = MeetingAIConfig(useGroq: true, groqKey: key, groqModel: model)
        return try await MeetingAIBackend.groq(
            config: config, system: system, user: prompt, json: true,
            maxTokens: maxTokens, reasoningEffort: "low", timeout: timeout
        )
    }
}

// MARK: - Engine

struct PromptRefinerEngine: Sendable {
    /// Groq key, passed only when Prompt Refiner's Groq opt-in is on.
    var groqKey: String?
    var groqModel: String = MeetingAIConfig.defaultGroqModel
    /// Off in tests that want the template path only.
    var useOnDevice = true

    static let questionTimeout: Double = 30
    static let refineTimeout: Double = 60

    private var groqReady: Bool { !(groqKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// Which engine the next step will try first.
    var preferredSource: PromptRefinerSource {
        if groqReady { return .groq }
        if useOnDevice, PromptRefinerLLM.onDeviceAvailable { return .onDevice }
        return .template
    }

    // MARK: Questions

    /// `onPartial` gets the questions written so far (on-device streaming only;
    /// display them read-only, the final set may differ).
    func questions(
        for rough: String, target: PromptTarget,
        onPartial: (@Sendable ([ClarifyingQuestion]) -> Void)? = nil
    ) async throws -> PromptQuestionSet {
        let started = ContinuousClock.now
        let domain = PromptRefinerTemplates.domain(for: rough, target: target)
        let instructions = PromptRefinerPrompts.questionInstructions(target: target)
        let prompt = PromptRefinerPrompts.questionPrompt(rough: rough, target: target, domain: domain)
        var note: String?

        for source in modelSources() {
            do {
                var partial: (@Sendable (String) -> Void)?
                if let onPartial {
                    partial = { @Sendable raw in
                        if let set = Self.parseQuestions(raw, domain: domain, target: target, topUp: false) {
                            onPartial(set.questions)
                        }
                    }
                }
                let raw = try await run(source, instructions: instructions, prompt: prompt,
                                        schema: PromptRefinerPrompts.questionSchema, maxTokens: 700,
                                        timeout: Self.questionTimeout, vary: false, onPartial: partial)
                if var set = Self.parseQuestions(raw, domain: domain, target: target) {
                    set.questions = Self.ensuringVerification(set.questions, domain: domain, target: target)
                    return PromptQuestionSet(intent: set.intent, domain: domain, questions: set.questions,
                                             source: source, latency: seconds(since: started), note: note)
                }
                note = "\(source.label) gave no usable questions"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                note = "\(source.label): \(error.localizedDescription)"
                AppLog.log("Prompt Refiner: questions via \(source.rawValue) failed: \(error.localizedDescription)")
            }
            try Task.checkCancellation()
        }
        let questions = PromptRefinerTemplates.questions(for: domain, target: target)
        return PromptQuestionSet(intent: PromptRefinerTemplates.sentence(rough), domain: domain, questions: questions,
                                 source: .template, latency: seconds(since: started), note: note)
    }

    // MARK: Refinement

    func refine(
        rough: String, target: PromptTarget, questions: [ClarifyingQuestion],
        previous: String? = nil, feedback: String? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> PromptRefinement {
        let started = ContinuousClock.now
        let domain = PromptRefinerTemplates.domain(for: rough, target: target)
        let instructions = PromptRefinerPrompts.refineInstructions(target: target)
        let prompt = PromptRefinerPrompts.refinePrompt(
            rough: rough, target: target, domain: domain, questions: questions, previous: previous, feedback: feedback
        )
        let schema = target == .imageModel ? PromptRefinerPrompts.imageSchema : PromptRefinerPrompts.textSchema
        let vary = previous != nil && (feedback ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        var note: String?

        for source in modelSources() {
            do {
                var partial: (@Sendable (String) -> Void)?
                if let onPartial {
                    partial = { @Sendable raw in
                        if let preview = Self.partialPreview(raw, target: target) { onPartial(preview) }
                    }
                }
                let raw = try await run(source, instructions: instructions, prompt: prompt, schema: schema,
                                        maxTokens: 1100, timeout: Self.refineTimeout, vary: vary, onPartial: partial)
                if let result = Self.parseRefinement(raw, rough: rough, domain: domain, target: target,
                                                     questions: questions, feedback: feedback) {
                    return PromptRefinement(title: result.title, text: result.text, source: source,
                                            latency: seconds(since: started), note: note)
                }
                note = "\(source.label) gave an unusable prompt"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                note = "\(source.label): \(error.localizedDescription)"
                AppLog.log("Prompt Refiner: refine via \(source.rawValue) failed: \(error.localizedDescription)")
            }
            try Task.checkCancellation()
        }
        let result = Self.templateRefinement(rough: rough, domain: domain, target: target, questions: questions,
                                             feedback: feedback)
        return PromptRefinement(title: result.title, text: result.text, source: .template,
                                latency: seconds(since: started), note: note)
    }

    static func templateRefinement(
        rough: String, domain: PromptDomain, target: PromptTarget, questions: [ClarifyingQuestion], feedback: String? = nil
    ) -> (title: String, text: String) {
        if target == .imageModel {
            var spec = PromptRefinerTemplates.imageSpec(rough: rough, questions: questions)
            if let feedback = nonEmpty(feedback) { spec.details.append(feedback) }
            return (spec.title, PromptRefinerRenderer.render(spec))
        }
        var spec = PromptRefinerTemplates.spec(rough: rough, domain: domain, target: target, questions: questions)
        if let feedback = nonEmpty(feedback) { spec.constraints.append(feedback) }
        return (spec.title, PromptRefinerRenderer.render(spec, target: target))
    }

    // MARK: Plumbing

    private func modelSources() -> [PromptRefinerSource] {
        var sources: [PromptRefinerSource] = []
        if groqReady { sources.append(.groq) }
        if useOnDevice, PromptRefinerLLM.onDeviceAvailable { sources.append(.onDevice) }
        return sources
    }

    private func run(
        _ source: PromptRefinerSource, instructions: String, prompt: String, schema: PromptRefinerSchema,
        maxTokens: Int, timeout: Double, vary: Bool, onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        switch source {
        case .groq:
            return try await PromptRefinerLLM.groq(
                key: groqKey ?? "", model: groqModel, instructions: instructions, prompt: prompt,
                schema: schema, maxTokens: maxTokens + 600, timeout: timeout
            )
        case .onDevice:
            do {
                return try await PromptRefinerLLM.onDevice(
                    instructions: instructions, prompt: prompt, schema: schema,
                    maxTokens: maxTokens, timeout: timeout, vary: vary, onPartial: onPartial
                )
            } catch let error where !(error is CancellationError) && PromptRefinerLLM.isRefusal(error) {
                // Rewriting the user's own request is a content transformation:
                // retry once with the matching guardrails.
                AppLog.log("Prompt Refiner: on-device guardrails declined; retrying with content-transformation guardrails")
                return try await PromptRefinerLLM.onDevice(
                    instructions: instructions, prompt: prompt, schema: schema,
                    maxTokens: maxTokens, timeout: timeout, vary: vary, permissive: true, onPartial: onPartial
                )
            }
        case .template:
            throw MeetingAIError.unavailable("template")
        }
    }

    private func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: Parsing

    static func nonEmpty(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || MeetingAIText.isPlaceholder(trimmed) ? nil : trimmed
    }

    /// A long string field (MeetingAIJSON.string caps items at 320 chars).
    static func text(_ value: Any?, limit: Int = 1200) -> String {
        guard let raw = value as? String, let text = nonEmpty(raw) else { return "" }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func list(_ value: Any?, limit: Int) -> [String] {
        MeetingAIJSON.strings(value, limit: limit)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ;")) }
            .filter { !$0.isEmpty }
    }

    /// True when a field talks about the prompt itself ("acceptanceCriteria",
    /// "sections: title, role…", "Keep the title 3-6 words").
    static func looksLikeMeta(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "acceptancecriteria", "acceptance criteria", "outputformat", "title, role", "role, objective",
            "objective, context", "requirements, constraints", "the prompt", "this prompt", "structured prompt",
            "3-6 word", "1-4 limits", "keep the title", "field", "json", "skipped the questions", "sensible defaults",
            "previous prompt", "refined prompt", "<request>", "</",
        ]
        return markers.contains { lowered.contains($0) }
    }

    static func parseQuestions(_ raw: String, domain: PromptDomain, target: PromptTarget, topUp: Bool = true)
        -> (intent: String, questions: [ClarifyingQuestion])? {
        guard let json = MeetingAIJSON.object(from: raw) else { return nil }
        var questions: [ClarifyingQuestion] = []
        for item in MeetingAIJSON.objects(json["questions"]) {
            guard var question = nonEmpty(item["question"] as? String) else { continue }
            question = MeetingAIText.collapse(question)
            if !question.hasSuffix("?") { question = question.trimmingCharacters(in: .punctuationCharacters) + "?" }
            guard question.count <= 160 else { continue }
            var options: [String] = []
            for option in list(item["options"], limit: 6) {
                let cleaned = option.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
                guard cleaned.count <= 48,
                      !options.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else { continue }
                options.append(cleaned)
            }
            // A label is only kept when it reads as a noun phrase ("Audience");
            // otherwise the question itself is used in the prompt.
            var label = (nonEmpty(item["label"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "?:. "))
            let firstWord = label.split(separator: " ").first.map { $0.lowercased() } ?? ""
            let questionWords: Set<String> = ["what", "who", "how", "which", "where", "when", "why", "is", "are", "do", "does", "should", "will", "can"]
            if label.split(separator: " ").count > 3 || questionWords.contains(firstWord) { label = "" }
            if let first = label.first, first.isLowercase { label = first.uppercased() + label.dropFirst() }
            if questions.contains(where: { MeetingAIText.similarity($0.question, question) >= 0.75 }) { continue }
            questions.append(ClarifyingQuestion(label: label, question: question, options: Array(options.prefix(4))))
        }
        guard !questions.isEmpty else { return nil }
        // Top up thin model output with template questions on other topics.
        if topUp, questions.count < 2 {
            for extra in PromptRefinerTemplates.questions(for: domain, target: target) where questions.count < 3 {
                let overlaps = questions.contains {
                    MeetingAIText.similarity($0.question, extra.question) >= 0.5
                        || $0.label.caseInsensitiveCompare(extra.label) == .orderedSame
                }
                if !overlaps { questions.append(extra) }
            }
        }
        let intent = nonEmpty(json["intent"] as? String) ?? ""
        return (intent, Array(questions.prefix(5)))
    }

    /// Claude Code works best when it can check its own work, so its
    /// questions always include how to verify the result.
    static func ensuringVerification(_ questions: [ClarifyingQuestion], domain: PromptDomain, target: PromptTarget)
        -> [ClarifyingQuestion] {
        guard target == .claudeCode else { return questions }
        let words = ["verif", "test", "check", "confirm", "validate", "screenshot"]
        let asks = questions.contains { q in
            let text = (q.label + " " + q.question).lowercased()
            return words.contains { text.contains($0) }
        }
        guard !asks,
              let verify = PromptRefinerTemplates.questions(for: domain, target: target).first(where: { $0.label == "Verification" })
        else { return questions }
        return Array(questions.prefix(4)) + [verify]
    }

    static func parseRefinement(
        _ raw: String, rough: String, domain: PromptDomain, target: PromptTarget, questions: [ClarifyingQuestion],
        feedback: String? = nil
    ) -> (title: String, text: String)? {
        guard let json = MeetingAIJSON.object(from: raw) else { return nil }
        if target == .imageModel {
            return parseImage(json, rough: rough, questions: questions)
        }
        let fallback = PromptRefinerTemplates.spec(rough: rough, domain: domain, target: target, questions: questions)
        var spec = PromptSpec()
        spec.title = text(json["title"], limit: 60)
        spec.role = text(json["role"], limit: 300)
        spec.objective = text(json["objective"], limit: 900)
        spec.context = list(json["context"], limit: 8)
        spec.requirements = list(json["requirements"], limit: 7)
        spec.constraints = list(json["constraints"], limit: 5)
        spec.inputs = list(json["inputs"], limit: 4)
        spec.outputFormat = text(json["outputFormat"], limit: 500)
        spec.acceptanceCriteria = list(json["acceptanceCriteria"], limit: 5)
        spec.example = text(json["example"], limit: 500)

        // Drop items where the model wrote about the prompt instead of the task
        // (echoed field names or schema wording).
        spec.context.removeAll(where: looksLikeMeta)
        spec.requirements.removeAll(where: looksLikeMeta)
        spec.constraints.removeAll(where: looksLikeMeta)
        spec.acceptanceCriteria.removeAll(where: looksLikeMeta)
        spec.inputs.removeAll(where: looksLikeMeta)
        if looksLikeMeta(spec.outputFormat) { spec.outputFormat = "" }
        if looksLikeMeta(spec.example) { spec.example = "" }
        // Items that only restate the request add nothing (the model likes
        // to list the request itself as an input).
        let restatesRequest: (String) -> Bool = { MeetingAIText.similarity($0, rough) >= 0.9 && $0.count <= rough.count + 12 }
        spec.context.removeAll(where: restatesRequest)
        spec.inputs.removeAll(where: restatesRequest)
        // An input is something the user pastes; a fragment of the request is not.
        spec.inputs.removeAll { MeetingAIText.similarity($0, rough) >= 0.6 }
        // Inputs are short names of material to paste, never pasted text (the
        // model sometimes copies the previous prompt or the feedback there).
        spec.inputs.removeAll { input in
            input.count > 90 || input.contains("#")
                || (feedback.map { MeetingAIText.similarity(input, $0) >= 0.6 } ?? false)
        }
        // "Write a refined cold email": the word leaks from our instructions.
        if !rough.lowercased().contains("refine") {
            let strip: (String) -> String = {
                $0.replacingOccurrences(of: #"\b[Rr]efined\s+"#, with: "", options: .regularExpression)
            }
            spec.objective = strip(spec.objective)
            spec.requirements = spec.requirements.map(strip)
        }
        // A bare answer ("Beginner") as context says nothing: label it.
        spec.context = spec.context.map { item in
            guard let question = questions.first(where: { $0.answer?.caseInsensitiveCompare(item) == .orderedSame }),
                  let line = PromptRefinerTemplates.contextLines([question]).first else { return item }
            return line
        }
        // JSON-looking samples confuse chat targets; one-word formats say nothing.
        if spec.example.hasPrefix("{") || spec.example.hasPrefix("[") { spec.example = "" }
        if spec.outputFormat.count < 16 { spec.outputFormat = "" }

        // The model must describe the task, not do it: a code block or a very
        // long objective means it started answering. Use the template's.
        if spec.objective.isEmpty || spec.objective.contains("```") || spec.objective.count > 700 {
            spec.objective = fallback.objective
        }
        if spec.example.contains("```"), target != .claudeCode, domain != .code { spec.example = "" }
        if spec.title.isEmpty { spec.title = fallback.title }
        if spec.role.isEmpty || !spec.role.lowercased().hasPrefix("you") { spec.role = fallback.role }
        spec.role = PromptRefinerTemplates.sentence(spec.role)
        spec.objective = PromptRefinerTemplates.sentence(spec.objective)
        if spec.outputFormat.isEmpty { spec.outputFormat = fallback.outputFormat }
        if spec.acceptanceCriteria.isEmpty { spec.acceptanceCriteria = fallback.acceptanceCriteria }
        if spec.inputs.isEmpty { spec.inputs = fallback.inputs }
        // After "Refine again" the model tends to copy the criteria and the
        // output format into the requirements as well.
        let format = spec.outputFormat
        let formatWords = MeetingAIText.contentWords(format)
        let criteria = spec.acceptanceCriteria
        spec.requirements.removeAll { item in
            let words = MeetingAIText.contentWords(item)
            return MeetingAIText.similarity(item, format) >= 0.9 || (words.count >= 2 && words.isSubset(of: formatWords))
                || criteria.contains { MeetingAIText.similarity($0, item) >= 0.9 }
        }
        // The closing line is added by the renderer; copies of it are noise.
        let closing = PromptRefinerRenderer.claudeCodeClosing + " " + PromptRefinerRenderer.chatGPTClosing
        let closingWords = MeetingAIText.contentWords(closing)
        let copiesClosing: (String) -> Bool = { item in
            let words = MeetingAIText.contentWords(item)
            return words.count >= 3 && Double(words.intersection(closingWords).count) / Double(words.count) >= 0.75
        }
        spec.requirements.removeAll(where: copiesClosing)
        spec.constraints.removeAll(where: copiesClosing)
        spec.acceptanceCriteria.removeAll(where: copiesClosing)
        spec.requirements = MeetingAIText.dedupe(spec.requirements, threshold: 0.9)
        if spec.requirements.isEmpty { spec.requirements = fallback.requirements }
        // Feedback is an instruction, not a fact: keep it out of the context
        // and, when the model didn't apply it anywhere, add it as a constraint.
        if let note = nonEmpty(feedback) {
            spec.context.removeAll { MeetingAIText.similarity($0, note) >= 0.6 }
            let applied = MeetingAIText.contentWords(note).isSubset(of: MeetingAIText.contentWords(
                ([spec.objective, spec.outputFormat] + spec.requirements + spec.constraints).joined(separator: " ")))
            if !applied, !looksLikeMeta(note) { spec.constraints.append(PromptRefinerTemplates.sentence(note)) }
        }

        // Context that repeats another field (common after "Refine again").
        let elsewhere = [spec.role] + spec.requirements + spec.constraints + spec.acceptanceCriteria
        spec.context.removeAll { item in elsewhere.contains { MeetingAIText.similarity($0, item) >= 0.8 } }
        spec.acceptanceCriteria.removeAll { item in spec.requirements.contains { MeetingAIText.similarity($0, item) >= 0.9 } }
        if spec.acceptanceCriteria.isEmpty { spec.acceptanceCriteria = fallback.acceptanceCriteria }

        // Every answer the user gave must survive into the prompt.
        let written = MeetingAIText.contentWords(
            ([spec.role, spec.objective, spec.outputFormat] + spec.context + spec.requirements + spec.constraints)
                .joined(separator: " ")
        )
        for question in questions {
            guard let answer = question.answer else { continue }
            let covered = answer.split(separator: ";").allSatisfy { part in
                MeetingAIText.contentWords(String(part)).isSubset(of: written)
            }
            if !covered, let line = PromptRefinerTemplates.contextLines([question]).first { spec.context.append(line) }
        }
        guard !spec.objective.isEmpty else { return nil }
        return (spec.title, PromptRefinerRenderer.render(spec, target: target))
    }

    /// The prompt as written so far, laid out without template fallbacks
    /// (shown while streaming; the final result replaces it).
    static func partialPreview(_ raw: String, target: PromptTarget) -> String? {
        guard let json = MeetingAIJSON.object(from: raw) else { return nil }
        if target == .imageModel {
            var spec = ImagePromptSpec()
            spec.subject = text(json["subject"], limit: 300)
            guard !spec.subject.isEmpty else { return nil }
            spec.setting = text(json["setting"], limit: 240)
            spec.style = text(json["style"], limit: 120)
            spec.composition = text(json["composition"], limit: 160)
            spec.lighting = text(json["lighting"], limit: 160)
            spec.colors = text(json["colors"], limit: 160)
            spec.mood = text(json["mood"], limit: 60)
            spec.details = list(json["details"], limit: 5)
            spec.avoid = list(json["avoid"], limit: 5)
            let ratio = text(json["aspectRatio"], limit: 8)
            if ImagePromptSpec.aspectRatios.contains(ratio) { spec.aspectRatio = ratio }
            return PromptRefinerRenderer.render(spec)
        }
        var spec = PromptSpec()
        spec.role = text(json["role"], limit: 300)
        spec.objective = text(json["objective"], limit: 900)
        guard !spec.objective.isEmpty else { return nil }
        spec.context = list(json["context"], limit: 8)
        spec.requirements = list(json["requirements"], limit: 7)
        spec.constraints = list(json["constraints"], limit: 5)
        spec.inputs = list(json["inputs"], limit: 4)
        spec.outputFormat = text(json["outputFormat"], limit: 500)
        spec.acceptanceCriteria = list(json["acceptanceCriteria"], limit: 5)
        return PromptRefinerRenderer.render(spec, target: target)
    }

    private static func parseImage(_ json: [String: Any], rough: String, questions: [ClarifyingQuestion]) -> (title: String, text: String)? {
        let fallback = PromptRefinerTemplates.imageSpec(rough: rough, questions: questions)
        var spec = ImagePromptSpec()
        spec.title = text(json["title"], limit: 60)
        spec.subject = text(json["subject"], limit: 300)
        spec.setting = text(json["setting"], limit: 240)
        spec.style = text(json["style"], limit: 120)
        spec.composition = text(json["composition"], limit: 160)
        spec.lighting = text(json["lighting"], limit: 160)
        spec.colors = text(json["colors"], limit: 160)
        spec.mood = text(json["mood"], limit: 60)
        spec.details = list(json["details"], limit: 5)
        spec.avoid = list(json["avoid"], limit: 5)
        let ratio = text(json["aspectRatio"], limit: 8)
        spec.aspectRatio = ImagePromptSpec.aspectRatios.contains(ratio) ? ratio : fallback.aspectRatio
        // An explicit answer wins over the model's guess.
        if let picked = questions.first(where: { $0.label == "Aspect ratio" })?.answer,
           let match = ImagePromptSpec.aspectRatios.first(where: { picked.hasPrefix($0) }) {
            spec.aspectRatio = match
        }
        if spec.subject.isEmpty { spec.subject = fallback.subject }
        if spec.style.isEmpty { spec.style = fallback.style }
        if spec.title.isEmpty { spec.title = fallback.title }
        if spec.avoid.isEmpty { spec.avoid = fallback.avoid }
        return (spec.title, PromptRefinerRenderer.render(spec))
    }
}
