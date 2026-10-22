import Foundation
import FoundationModels
import Synchronization

// Language-model plumbing for the meeting assistant (MeetingSummarizer,
// QuestionAnswerer):
// - the on-device Apple Intelligence model (FoundationModels, 4096-token
//   context) with guided generation built from `MeetingAISchema` (the
//   @Generable macro plugin is not part of the Command Line Tools, so schemas
//   are built with DynamicGenerationSchema),
// - optional Groq Chat Completions, used only when the user allowed it and a
//   key exists (`MeetingAIConfig.groqEnabled`),
// - time limits, tolerant JSON parsing, transcript formatting and chunking.

struct MeetingAIConfig: Sendable {
    /// Current Groq production text model (console.groq.com/docs/models:
    /// 131k context, JSON object mode, `reasoning_effort`).
    static let defaultGroqModel = "openai/gpt-oss-120b"

    var useGroq: Bool
    var groqKey: String?
    var groqModel: String = MeetingAIConfig.defaultGroqModel

    /// Groq is used only when the user allowed it and a key is present.
    var groqEnabled: Bool {
        useGroq && !(groqKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum MeetingAIError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case timedOut
    case contextTooLarge
    case refused
    case invalidKey
    case rateLimited(retryAfter: Double?)
    case requestTooLarge
    case http(Int, String)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Apple Intelligence isn't available (\(reason))"
        case .timedOut: "The model took too long"
        case .contextTooLarge: "The transcript part was too long for the model"
        case .refused: "The model declined"
        case .invalidKey: "The Groq key was rejected"
        case .rateLimited: "Groq is rate limiting requests"
        case .requestTooLarge: "The request was too large for Groq"
        case .http(let code, let message): "Groq error \(code) \(message)"
        case .network(let message): "Network error: \(message)"
        case .badResponse: "Couldn't read the model's answer"
        }
    }
}

// MARK: - Schema

/// A small JSON-shaped schema, turned into a DynamicGenerationSchema for the
/// on-device model and into a JSON outline for prompts (Groq, text fallback).
indirect enum MeetingAISchema: Sendable {
    case string
    case array(MeetingAISchema, maxItems: Int?)
    case object(name: String, properties: [Property])

    struct Property: Sendable {
        let name: String
        let description: String
        let schema: MeetingAISchema
    }

    /// `{"summary": "<…>", "keyPoints": ["<…>"]}`-style outline.
    var outline: String {
        switch self {
        case .string: return "string"
        case .array(let item, _): return "[\(item.outline)]"
        case .object(_, let properties):
            let fields = properties.map { "\"\($0.name)\": \($0.schema.outline)" }
            return "{" + fields.joined(separator: ", ") + "}"
        }
    }

    /// Field-by-field explanation for prompts.
    var fieldGuide: String {
        guard case .object(_, let properties) = self else { return "" }
        return properties.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    @available(macOS 26.0, *)
    func dynamicSchema(description: String? = nil) -> DynamicGenerationSchema {
        switch self {
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .array(let item, let maxItems):
            return DynamicGenerationSchema(arrayOf: item.dynamicSchema(), minimumElements: nil, maximumElements: maxItems)
        case .object(let name, let properties):
            return DynamicGenerationSchema(
                name: name,
                description: description,
                properties: properties.map {
                    DynamicGenerationSchema.Property(
                        name: $0.name, description: $0.description, schema: $0.schema.dynamicSchema()
                    )
                }
            )
        }
    }
}

// MARK: - Backend

enum MeetingAIBackend {
    // MARK: On-device

    /// True when the on-device Apple Intelligence model can be used now.
    static var onDeviceAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    /// Why the on-device model can't be used, or nil when it can.
    static var onDeviceUnavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "needs macOS 26" }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "this Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off"
        case .unavailable(.modelNotReady): return "the model is still downloading"
        case .unavailable: return "unavailable"
        }
    }

    /// A session created and prewarmed ahead of time (instructions already
    /// processed), used by the next request with the same instructions.
    private final class PreparedSession: @unchecked Sendable {
        let key: String
        let session: AnyObject
        init(key: String, session: AnyObject) {
            self.key = key
            self.session = session
        }
    }

    private static let prepared = Mutex<PreparedSession?>(nil)

    private static func sessionKey(_ instructions: String, permissive: Bool) -> String {
        (permissive ? "p:" : "d:") + instructions
    }

    /// Loads the on-device model and processes `instructions` ahead of the
    /// next request with the same instructions, so it skips the cold start
    /// (~5 s) and most of the instruction prefill.
    static func prewarm(instructions: String, permissive: Bool = false) {
        guard #available(macOS 26.0, *) else { return }
        guard SystemLanguageModel.default.isAvailable else { return }
        let session = LanguageModelSession(model: systemModel(permissive: permissive), instructions: instructions)
        session.prewarm()
        let box = PreparedSession(key: sessionKey(instructions, permissive: permissive), session: session)
        prepared.withLock { $0 = box }
    }

    @available(macOS 26.0, *)
    private static func systemModel(permissive: Bool) -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: permissive ? .permissiveContentTransformations : .default)
    }

    @available(macOS 26.0, *)
    private static func makeSession(instructions: String, permissive: Bool) -> LanguageModelSession {
        let key = sessionKey(instructions, permissive: permissive)
        let box: PreparedSession? = prepared.withLock { slot in
            guard let current = slot, current.key == key else { return nil }
            slot = nil
            return current
        }
        if let session = box?.session as? LanguageModelSession { return session }
        return LanguageModelSession(model: systemModel(permissive: permissive), instructions: instructions)
    }

    /// One on-device request in a fresh session. With a schema the reply is
    /// guided JSON (`GeneratedContent.jsonString`), otherwise plain text.
    /// `permissive` uses the content-transformation guardrails, meant for
    /// summarizing the user's own content.
    static func onDevice(
        instructions: String,
        prompt: String,
        schema: MeetingAISchema?,
        maxTokens: Int,
        timeout: Double,
        permissive: Bool
    ) async throws -> String {
        guard #available(macOS 26.0, *) else { throw MeetingAIError.unavailable("needs macOS 26") }
        if let reason = onDeviceUnavailableReason { throw MeetingAIError.unavailable(reason) }
        return try await MeetingAITimeout.run(seconds: timeout) {
            let session = makeSession(instructions: instructions, permissive: permissive)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
            do {
                if let schema {
                    let generationSchema = try GenerationSchema(root: schema.dynamicSchema(), dependencies: [])
                    let response = try await session.respond(
                        to: prompt, schema: generationSchema, includeSchemaInPrompt: true, options: options
                    )
                    return response.content.jsonString
                }
                return try await session.respond(to: prompt, options: options).content
            } catch {
                throw classifyOnDeviceError(error)
            }
        }
    }

    /// Maps FoundationModels errors (GenerationError on macOS 26,
    /// LanguageModelError on 27) without depending on either type.
    static func classifyOnDeviceError(_ error: Error) -> Error {
        if error is CancellationError || error is MeetingAIError { return error }
        let text = String(describing: error)
        if text.contains("contextSizeExceeded") || text.contains("exceededContextWindowSize") {
            return MeetingAIError.contextTooLarge
        }
        if text.contains("guardrailViolation") || text.contains("refusal") {
            return MeetingAIError.refused
        }
        if text.contains("assetsUnavailable") {
            return MeetingAIError.unavailable("model assets unavailable")
        }
        if text.contains("timeout") { return MeetingAIError.timedOut }
        return error
    }

    // MARK: Groq

    static let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    /// Request body as JSON data (separate so it can be checked offline).
    static func groqBody(
        model: String, system: String, user: String, json: Bool, maxTokens: Int, reasoningEffort: String?
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_completion_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        // gpt-oss / qwen reason before answering: keep that short and out of
        // the reply (console.groq.com/docs/reasoning).
        if isReasoningModel(model) {
            if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
            body["include_reasoning"] = false
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func isReasoningModel(_ model: String) -> Bool {
        model.hasPrefix("openai/gpt-oss") || model.hasPrefix("qwen/")
    }

    /// One Chat Completions request. The key is sent only to api.groq.com.
    static func groq(
        config: MeetingAIConfig,
        system: String,
        user: String,
        json: Bool,
        maxTokens: Int,
        reasoningEffort: String?,
        timeout: Double
    ) async throws -> String {
        guard config.groqEnabled, let key = config.groqKey?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MeetingAIError.unavailable("Groq isn't allowed for meetings")
        }
        var request = URLRequest(url: groqEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.httpBody = try groqBody(
            model: config.groqModel, system: system, user: user, json: json,
            maxTokens: maxTokens, reasoningEffort: reasoningEffort
        )
        let body = request
        return try await MeetingAITimeout.run(seconds: timeout + 1) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: body)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                throw MeetingAIError.timedOut
            } catch {
                throw MeetingAIError.network(error.localizedDescription)
            }
            let http = response as? HTTPURLResponse
            let retryAfter = (http?.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
            return try parseGroqResponse(data: data, status: http?.statusCode ?? 0, retryAfter: retryAfter)
        }
    }

    /// Interprets a Chat Completions response (any status code).
    static func parseGroqResponse(data: Data, status: Int, retryAfter: Double?) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            AppLog.log("Meetings AI: Groq HTTP \(status) \(message.prefix(160))")
            switch status {
            case 401, 403: throw MeetingAIError.invalidKey
            case 413: throw MeetingAIError.requestTooLarge
            case 429:
                // Groq answers 429 for both rate and per-request token limits.
                if message.localizedCaseInsensitiveContains("request too large") { throw MeetingAIError.requestTooLarge }
                throw MeetingAIError.rateLimited(retryAfter: retryAfter)
            default: throw MeetingAIError.http(status, String(message.prefix(80)))
            }
        }
        guard let json,
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else { throw MeetingAIError.badResponse }
        if let usage = json["usage"] as? [String: Any] {
            AppLog.log("Meetings AI: \(json["model"] as? String ?? "?") in=\(usage["prompt_tokens"] ?? "?") out=\(usage["completion_tokens"] ?? "?") finish=\(choice["finish_reason"] as? String ?? "?")")
        }
        let text = MeetingAIJSON.stripReasoning(message["content"] as? String ?? "")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingAIError.badResponse }
        return text
    }
}

// MARK: - Time limits

enum MeetingAITimeout {
    /// Runs `operation`, throwing `MeetingAIError.timedOut` after `seconds`
    /// without waiting for the operation to notice its cancellation.
    static func run<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = MeetingAITimeoutGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                let work = Task {
                    do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    gate.finish(.failure(MeetingAIError.timedOut))
                }
                gate.attach(work: work, timer: timer)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

final class MeetingAITimeoutGate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var pending: Result<T, Error>?
        var done = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = state.withLock { state in
            if let pending = state.pending {
                state.pending = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            if state.done { return true }
            state.tasks = [work, timer]
            return false
        }
        if cancelNow {
            work.cancel()
            timer.cancel()
        }
    }

    /// First result wins; later ones are ignored.
    func finish(_ result: Result<T, Error>) {
        let (continuation, tasks): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = state.withLock { state in
            guard !state.done else { return (nil, []) }
            state.done = true
            let tasks = state.tasks
            state.tasks = []
            if let continuation = state.continuation {
                state.continuation = nil
                return (continuation, tasks)
            }
            state.pending = result
            return (nil, tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

// MARK: - JSON

/// Tolerant JSON extraction for model replies: reasoning tags, code fences,
/// prose around the object, smart quotes, trailing commas and truncated
/// output are all handled.
enum MeetingAIJSON {
    static func stripReasoning(_ text: String) -> String {
        var text = text
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        return text
    }

    static func object(from raw: String) -> [String: Any]? {
        var text = stripReasoning(raw)
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = text.firstIndex(of: "{") else { return nil }
        let candidate = String(text[start...])
        if let object = parse(balancedPrefix(candidate) ?? candidate) { return object }
        let repaired = repair(candidate)
        if let object = parse(repaired) { return object }
        return parseTruncated(repaired)
    }

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// The text up to the brace closing the first object, ignoring braces in strings.
    private static func balancedPrefix(_ text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let char = text[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return String(text[...index]) }
            default: break
            }
        }
        return nil
    }

    private static func repair(_ text: String) -> String {
        var text = balancedPrefix(text) ?? text
        text = text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        text = text.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        return text
    }

    /// Cuts a truncated reply back to its last complete value and closes
    /// every open bracket.
    private static func parseTruncated(_ text: String) -> [String: Any]? {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var cuts: [(String.Index, [Character])] = []
        for index in text.indices {
            let char = text[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" {
                    inString = false
                    cuts.append((text.index(after: index), stack))
                }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
                cuts.append((text.index(after: index), stack))
            default: break
            }
        }
        for (cut, open) in cuts.reversed().prefix(40) {
            var candidate = String(text[..<cut])
            candidate = candidate.replacingOccurrences(of: #",\s*$"#, with: "", options: .regularExpression)
            candidate += String(open.reversed())
            candidate = candidate.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
            if let object = parse(candidate) { return object }
        }
        return nil
    }

    /// A string field (trimmed, nil when empty or a "none"-style placeholder).
    static func string(_ value: Any?) -> String? {
        let text: String
        switch value {
        case let value as String: text = value
        case let value as NSNumber: text = value.stringValue
        default: return nil
        }
        let cleaned = MeetingAIText.cleanItem(text)
        return MeetingAIText.isPlaceholder(cleaned) ? nil : cleaned
    }

    /// A list of strings: accepts an array of strings, an array of objects
    /// with a text-like field, or one string with bullet lines.
    static func strings(_ value: Any?, limit: Int) -> [String] {
        var items: [String] = []
        switch value {
        case let array as [Any]:
            for element in array {
                if let dict = element as? [String: Any] {
                    let text = ["text", "point", "item", "decision", "question", "step", "value"]
                        .lazy.compactMap { string(dict[$0]) }.first
                    if let text { items.append(text) }
                } else if let text = string(element) {
                    items.append(text)
                }
            }
        case let text as String:
            items = text.components(separatedBy: .newlines).compactMap { string($0) }
        default: break
        }
        return Array(MeetingAIText.dedupe(items).prefix(limit))
    }

    /// Objects of a list field (others are skipped).
    static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
}

// MARK: - Text and transcript helpers

enum MeetingAIText {
    /// The user's first name ("Koushik" from "Koushik Goud Shaganti"); falls
    /// back to the macOS account's full name, then "Me".
    static func firstName(_ userName: String) -> String {
        for candidate in [userName, NSFullUserName()] {
            if let first = candidate.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, !first.isEmpty {
                return String(first)
            }
        }
        return "Me"
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Latest version of each segment (volatile ones replaced by their final
    /// text), non-empty, in time order.
    static func latestSegments(_ segments: [TranscriptSegment], finalOnly: Bool = false) -> [TranscriptSegment] {
        var order: [UUID] = []
        var latest: [UUID: TranscriptSegment] = [:]
        for segment in segments {
            if latest[segment.id] == nil { order.append(segment.id) }
            latest[segment.id] = segment
        }
        return order.compactMap { latest[$0] }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!finalOnly || $0.isFinal) }
            .sorted { $0.start < $1.start }
    }

    struct Turn: Sendable, Equatable {
        var speaker: MeetingSpeaker
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// Consecutive segments of one speaker merged into turns (long turns are
    /// split at sentence ends around `maxChars`).
    static func turns(_ segments: [TranscriptSegment], maxChars: Int = 900, mergeGap: TimeInterval = 6) -> [Turn] {
        var turns: [Turn] = []
        for segment in latestSegments(segments) {
            let text = collapse(segment.text)
            if var last = turns.last, last.speaker == segment.speaker,
               segment.start - last.end <= mergeGap, last.text.count + text.count < maxChars {
                last.text += " " + text
                last.end = max(last.end, segment.end)
                turns[turns.count - 1] = last
            } else if text.count > maxChars {
                var piece = ""
                for sentence in sentences(text) {
                    if !piece.isEmpty, piece.count + sentence.count > maxChars {
                        turns.append(Turn(speaker: segment.speaker, start: segment.start, end: segment.end, text: piece))
                        piece = ""
                    }
                    piece += piece.isEmpty ? sentence : " " + sentence
                }
                if !piece.isEmpty {
                    turns.append(Turn(speaker: segment.speaker, start: segment.start, end: segment.end, text: piece))
                }
            } else {
                turns.append(Turn(speaker: segment.speaker, start: segment.start, end: segment.end, text: text))
            }
        }
        return turns
    }

    static let othersLabel = "Others"

    static func speakerLabel(_ speaker: MeetingSpeaker, userFirst: String) -> String {
        speaker == .me ? userFirst : othersLabel
    }

    static func line(_ turn: Turn, userFirst: String) -> String {
        "[\(timestamp(turn.start))] \(speakerLabel(turn.speaker, userFirst: userFirst)): \(turn.text)"
    }

    struct Chunk: Sendable, Equatable {
        /// Lines repeated from the end of the previous chunk, for context.
        var context: [String]
        var lines: [String]
        var start: TimeInterval
        var end: TimeInterval
        var text: String { lines.joined(separator: "\n") }
        var characterCount: Int { lines.reduce(0) { $0 + $1.count + 1 } }
    }

    /// Splits turns into chunks of at most `maxChars` characters of lines,
    /// carrying the last `overlap` lines of the previous chunk as context.
    static func chunks(_ turns: [Turn], userFirst: String, maxChars: Int, overlap: Int = 2) -> [Chunk] {
        var chunks: [Chunk] = []
        var current = Chunk(context: [], lines: [], start: turns.first?.start ?? 0, end: 0)
        for turn in turns {
            let line = line(turn, userFirst: userFirst)
            if !current.lines.isEmpty, current.characterCount + line.count + 1 > maxChars {
                chunks.append(current)
                let carried = Array(current.lines.suffix(overlap)).map { String($0.prefix(300)) }
                current = Chunk(context: carried, lines: [], start: turn.start, end: turn.end)
            }
            if current.lines.isEmpty { current.start = turn.start }
            current.lines.append(line)
            current.end = turn.end
        }
        if !current.lines.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Splits a chunk in two (used when it did not fit the model's context).
    static func split(_ chunk: Chunk) -> [Chunk] {
        guard chunk.lines.count > 1 else {
            // One very long line: halve it.
            guard let line = chunk.lines.first, line.count > 400 else { return [chunk] }
            let middle = line.index(line.startIndex, offsetBy: line.count / 2)
            var first = chunk, second = chunk
            first.lines = [String(line[..<middle])]
            second.lines = [String(line[middle...])]
            second.context = []
            return [first, second]
        }
        let half = chunk.lines.count / 2
        var first = chunk, second = chunk
        first.lines = Array(chunk.lines[..<half])
        second.lines = Array(chunk.lines[half...])
        second.context = Array(first.lines.suffix(2)).map { String($0.prefix(300)) }
        return [first, second]
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sentences of `text` (split after . ? ! followed by a space).
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(collapse(text))
        for (index, char) in chars.enumerated() {
            current.append(char)
            if ".?!".contains(char), index + 1 == chars.count || chars[index + 1] == " " {
                // Keep "e.g." / "Mr." / "3.5" together.
                let lastWord = current.split(separator: " ").last.map(String.init)?.lowercased() ?? ""
                if char == ".", ["mr.", "mrs.", "ms.", "dr.", "e.g.", "i.e.", "vs.", "etc."].contains(lastWord) { continue }
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// One list item: bullets, numbering and wrapping quotes removed,
    /// first letter capitalized.
    static func cleanItem(_ text: String) -> String {
        var text = collapse(text)
        text = text.replacingOccurrences(of: #"^([-*•·]+|\d+[.)])\s*"#, with: "", options: .regularExpression)
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        if text.count > 320 { text = String(text.prefix(317)) + "…" }
        return text
    }

    static func isPlaceholder(_ text: String) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return lowered.isEmpty || [
            "none", "n/a", "na", "null", "nil", "no", "nothing", "not mentioned", "not specified", "unspecified",
            "unknown", "not stated", "no due date", "none mentioned", "none stated", "tbd", "-", "string",
        ].contains(lowered)
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "for", "with", "at", "by", "from", "is",
        "are", "was", "were", "be", "been", "it", "this", "that", "these", "those", "we", "i", "you", "they",
        "he", "she", "will", "would", "should", "can", "could", "do", "does", "did", "so", "as", "about", "up",
        "our", "my", "your", "their", "its", "has", "have", "had", "just", "also", "then", "than", "into", "out",
        "need", "needs", "going", "get", "make", "sure", "all", "any", "some", "there", "here", "what", "which",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func contentWords(_ text: String) -> Set<String> {
        Set(words(text).filter { !stopWords.contains($0) }.map(stem))
    }

    /// Crude stemming so "sending"/"sends"/"send" compare equal.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Overlap of content words (0…1), relative to the shorter text.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = contentWords(a), wb = contentWords(b)
        guard !wa.isEmpty, !wb.isEmpty else { return a.lowercased() == b.lowercased() ? 1 : 0 }
        let shared = Double(wa.intersection(wb).count)
        let jaccard = shared / Double(wa.union(wb).count)
        let containment = shared / Double(min(wa.count, wb.count))
        return max(jaccard, containment * 0.85)
    }

    /// Drops near-duplicates, keeping the longer wording of each.
    static func dedupe(_ items: [String], threshold: Double = 0.7) -> [String] {
        var kept: [String] = []
        for item in items {
            if let index = kept.firstIndex(where: { similarity($0, item) >= threshold }) {
                if item.count > kept[index].count { kept[index] = item }
            } else {
                kept.append(item)
            }
        }
        return kept
    }

    /// True when `phrase` occurs in `text` as whole words (case-insensitive).
    static func containsWord(_ text: String, _ phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return text.range(of: "\\b\(escaped)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
