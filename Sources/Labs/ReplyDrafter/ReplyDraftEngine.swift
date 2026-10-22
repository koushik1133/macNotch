import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes and reworks drafts: Groq only when the feature's own opt-in is on
/// and a key exists, otherwise the on-device Apple Intelligence model
/// (guided JSON through `MeetingAIBackend`), otherwise `ReplyTemplate`.
/// Never logs message text or keys.
struct ReplyDraftEngine: Sendable {
    static let onDeviceName = "Apple Intelligence (on-device)"
    static let groqName = "Groq"

    /// nil unless the user allowed Groq for the Reply Drafter and a key exists.
    var groq: MeetingAIConfig?
    /// Seam for tests: replaces the on-device call (instructions, prompt, schema) → raw JSON/text.
    var onDeviceOverride: (@Sendable (String, String, MeetingAISchema?) async throws -> String)?

    init(groq: MeetingAIConfig? = nil) {
        self.groq = groq
    }

    /// Label for the engine that will be tried first.
    var engineLabel: String {
        if groq?.groqEnabled == true { return Self.groqName }
        return MeetingAIBackend.onDeviceAvailable || onDeviceOverride != nil ? Self.onDeviceName : ReplyTemplate.producedBy
    }

    func draft(_ request: ReplyDraftRequest) async throws -> ReplyDraft {
        let instructions = ReplyPromptBuilder.instructions(kind: request.conversation.kind, tone: request.tone)
        let schema = ReplyPromptBuilder.schema(wantsSubject: request.wantsSubject)
        let prompts = [ReplyPromptBuilder.prompt(request), ReplyPromptBuilder.prompt(request, conversationBudget: ReplyPromptBuilder.conversationBudget / 2)]
        if let draft = try await generate(instructions: instructions, prompts: prompts, schema: schema, request: request) {
            return draft
        }
        return ReplyTemplate.draft(request)
    }

    func revise(_ request: ReplyDraftRequest, current: ReplyDraft, revision: ReplyRevision) async throws -> ReplyDraft {
        if revision == .regenerate {
            var next = request
            next.variation = max(1, request.variation)
            next.previousDraft = current.body
            var draft = try await draft(next)
            // Short chat replies can come back word for word even with
            // sampling: one more try with the next variation hint.
            if ReplyTextLocator.normalizedEqual(draft.body, current.body), draft.producedBy != ReplyTemplate.producedBy {
                next.variation += 1
                let again = try await self.draft(next)
                if !ReplyTextLocator.normalizedEqual(again.body, current.body) { draft = again }
            }
            if draft.subject == nil { draft.subject = current.subject }
            return draft
        }
        let instructions = ReplyPromptBuilder.instructions(kind: request.conversation.kind, tone: request.tone)
        let schema = ReplyPromptBuilder.schema(wantsSubject: false)
        let prompt = ReplyPromptBuilder.revisionPrompt(request, current: current.body, revision: revision)
        var compact = request
        compact.conversation.messages = Array(request.conversation.messages.suffix(3))
        let fallbackPrompt = ReplyPromptBuilder.revisionPrompt(compact, current: current.body, revision: revision)
        if var draft = try await generate(instructions: instructions, prompts: [prompt, fallbackPrompt], schema: schema, request: request) {
            draft.subject = current.subject
            return draft
        }
        var draft = current
        draft.body = ReplyTemplate.revise(current.body, revision: revision, kind: request.conversation.kind)
        draft.producedBy = ReplyTemplate.producedBy
        return draft
    }

    /// nil when no model could be used (the caller falls back to the template).
    private func generate(instructions: String, prompts: [String], schema: MeetingAISchema, request: ReplyDraftRequest) async throws -> ReplyDraft? {
        if let groq, groq.groqEnabled {
            do {
                let system = instructions + "\n\nAnswer only with a JSON object: \(schema.outline)\n" + schema.fieldGuide
                let raw = try await MeetingAIBackend.groq(
                    config: groq, system: system, user: prompts[0], json: true, maxTokens: 900,
                    reasoningEffort: "low", timeout: 25
                )
                if let draft = parse(raw, request: request, producedBy: Self.groqName) { return draft }
                AppLog.log("Reply Drafter: Groq reply unreadable; trying on device")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Reply Drafter: Groq failed (\(Self.category(error))); trying on device")
            }
        }
        guard onDeviceOverride != nil || MeetingAIBackend.onDeviceAvailable else { return nil }
        // Plain text keeps the model's paragraphs; guided JSON squeezes the
        // reply onto one line, so it is used only when a subject is needed.
        let onDeviceSchema: MeetingAISchema? = request.wantsSubject ? schema : nil
        // Too long → the shorter prompt; refused → the content-transformation
        // guardrails (it is the user's own conversation). At most 3 tries.
        var queue: [(prompt: String, permissive: Bool)] = [(prompts[0], false)]
        var usedShort = false
        var usedPermissive = false
        var lastError: Error?
        while !queue.isEmpty {
            let (prompt, permissive) = queue.removeFirst()
            do {
                let raw: String
                if let onDeviceOverride {
                    raw = try await onDeviceOverride(instructions, prompt, onDeviceSchema)
                } else if request.variation > 0, onDeviceSchema == nil {
                    // Regenerate: sampled instead of greedy, so it differs.
                    raw = try await ReplyOnDevice.sampled(instructions: instructions, prompt: prompt, maxTokens: ReplyPromptBuilder.maxReplyTokens, permissive: permissive)
                } else {
                    raw = try await MeetingAIBackend.onDevice(
                        instructions: instructions, prompt: prompt, schema: onDeviceSchema,
                        maxTokens: ReplyPromptBuilder.maxReplyTokens, timeout: 45, permissive: permissive
                    )
                }
                if let draft = parse(raw, request: request, producedBy: Self.onDeviceName) { return draft }
                lastError = MeetingAIError.badResponse
            } catch is CancellationError {
                throw CancellationError()
            } catch MeetingAIError.contextTooLarge {
                lastError = MeetingAIError.contextTooLarge
                if !usedShort, prompts.count > 1 {
                    usedShort = true
                    queue.append((prompts[1], permissive))
                }
            } catch MeetingAIError.refused {
                lastError = MeetingAIError.refused
                if !usedPermissive {
                    usedPermissive = true
                    queue.append((prompt, true))
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { AppLog.log("Reply Drafter: no model draft (\(Self.category(lastError))); using the template") }
        return nil
    }

    /// Model output (JSON, or plain text) → a cleaned draft.
    func parse(_ raw: String, request: ReplyDraftRequest, producedBy: String) -> ReplyDraft? {
        var body: String?
        var subject: String?
        let looksJSON = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            || raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
        if looksJSON || request.wantsSubject, let object = MeetingAIJSON.object(from: raw) {
            body = (object["reply"] as? String) ?? (object["body"] as? String) ?? (object["message"] as? String)
            subject = object["subject"] as? String
        } else if !looksJSON {
            body = raw
        }
        guard let body else { return nil }
        let cleaned = ReplyDraftCleaner.clean(body, kind: request.conversation.kind, tone: request.tone, conversation: request.conversation)
        guard cleaned.count >= 2 else { return nil }
        var finalSubject: String?
        if request.wantsSubject {
            if let thread = request.conversation.subject, !request.conversation.messages.isEmpty {
                finalSubject = thread.lowercased().hasPrefix("re:") ? thread : "Re: \(thread)"
            } else {
                finalSubject = ReplyDraftCleaner.cleanSubject(subject)
            }
        }
        return ReplyDraft(body: cleaned, subject: finalSubject, producedBy: producedBy)
    }

    /// Error kind for the log (never the message).
    static func category(_ error: Error) -> String {
        if let error = error as? MeetingAIError {
            switch error {
            case .unavailable: return "unavailable"
            case .timedOut: return "timed out"
            case .contextTooLarge: return "context too large"
            case .refused: return "refused"
            case .invalidKey: return "invalid key"
            case .rateLimited: return "rate limited"
            case .requestTooLarge: return "request too large"
            case .http(let code, _): return "HTTP \(code)"
            case .network: return "network"
            case .badResponse: return "bad response"
            }
        }
        return String(describing: type(of: error))
    }
}

/// A sampled (non-greedy) on-device request, for Regenerate. The shared
/// backend always decodes greedily, which returns the same draft again.
enum ReplyOnDevice {
    static func sampled(instructions: String, prompt: String, maxTokens: Int, permissive: Bool) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw MeetingAIError.unavailable("needs macOS 26") }
        if let reason = MeetingAIBackend.onDeviceUnavailableReason { throw MeetingAIError.unavailable(reason) }
        return try await MeetingAITimeout.run(seconds: 45) {
            let model = SystemLanguageModel(useCase: .general, guardrails: permissive ? .permissiveContentTransformations : .default)
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(samplingMode: .random(top: 40), temperature: 0.85, maximumResponseTokens: maxTokens)
            do {
                return try await session.respond(to: prompt, options: options).content
            } catch {
                throw MeetingAIBackend.classifyOnDeviceError(error)
            }
        }
        #else
        throw MeetingAIError.unavailable("Apple Intelligence isn't available in this build")
        #endif
    }
}
