import Foundation

/// Live help during a meeting: spots questions other participants ask
/// (`detectQuestion`, a fast heuristic run on every final segment) and drafts
/// a short reply the user can say (`answer`), grounded in the last few
/// minutes of the transcript.
struct QuestionAnswerer: Sendable {
    let config: MeetingAIConfig

    init(config: MeetingAIConfig) {
        self.config = config
    }

    // MARK: - Detection

    private static let interrogatives: Set<String> = [
        "what", "what's", "whats", "how", "how's", "why", "when", "when's", "where", "where's", "who", "who's",
        "whom", "which", "whose",
    ]

    /// Openers that make a sentence a question even without a "?".
    private static let questionOpeners = [
        "can you", "could you", "would you", "will you", "do you", "did you", "are you", "have you", "were you",
        "is there", "are there", "is it", "was it", "should we", "shall we", "can we", "could we", "do we", "does",
        "did we", "have we", "is that", "are we", "any thoughts", "any update", "any updates", "any idea",
        "thoughts", "what do you think", "how about", "do you think", "would it", "is this", "can i ask",
    ]

    /// Questions that don't need an answer from the user.
    private static let ignoredQuestions = [
        "can you hear me", "can everyone hear", "can you see my screen", "can you see it", "is my screen",
        "can everyone see", "are you there", "are you still there", "am i audible", "is my audio", "am i on mute",
        "is my mic", "how are you", "how's it going", "how are things", "what's up", "how was your weekend",
        "does that make sense", "make sense", "you know what i mean", "is that clear", "are we good", "shall we start",
        "should we get started", "can we get started", "who just joined", "who joined", "everyone here",
        "can you see me", "is everyone here", "are we recording", "is this recording",
    ]

    /// Tag questions ("…, right?") that are statements in disguise.
    private static let tagEndings = [
        "right?", "yeah?", "no?", "okay?", "ok?", "you know?", "isn't it?", "correct?", "huh?", "eh?", "yes?", "alright?",
    ]

    private static let leadingFillers = #"^(?:(?:so|um+|uh+|er+|okay|ok|and|well|alright|all right|right|yeah|hey|now|hmm+|anyway|also|but|like)[,.]?\s+)+"#

    /// The question in `segment` the user should answer, cleaned, or nil.
    /// Only final segments from other participants count; questions aimed at
    /// someone else by name, small talk, tag questions and very short
    /// fragments are ignored.
    static func detectQuestion(in segment: TranscriptSegment, recent: [TranscriptSegment], userName: String) -> String? {
        guard segment.isFinal, segment.speaker == .others else { return nil }
        let userFirst = MeetingAIText.firstName(userName)
        let text = MeetingAIText.collapse(segment.text)
        guard text.count >= 6 else { return nil }

        let sentences = MeetingAIText.sentences(text)
        // The question is usually the last one asked in the segment.
        var best: (text: String, score: Int)?
        for (index, sentence) in sentences.enumerated().reversed() {
            var candidate = sentence
            // "Thoughts?" alone needs the sentence before it.
            if MeetingAIText.words(candidate).count < 4, index > 0 {
                candidate = sentences[index - 1] + " " + candidate
            }
            guard let score = score(candidate, userFirst: userFirst) else { continue }
            if score > (best?.score ?? 0) { best = (candidate, score) }
            if best != nil { break }
        }
        guard let best else { return nil }

        // Already asked a moment ago (a repeat or a re-recognized phrase).
        let previous = recent.filter { $0.id != segment.id && $0.speaker == .others && $0.isFinal && segment.start - $0.end < 90 }
        if previous.contains(where: { MeetingAIText.similarity($0.text, best.text) >= 0.85 }) { return nil }
        // An echo of what the user just said, picked up through system audio.
        let mine = recent.filter { $0.speaker == .me && abs($0.end - segment.end) < 8 }
        if mine.contains(where: { MeetingAIText.similarity($0.text, best.text) >= 0.8 }) { return nil }

        return clean(best.text)
    }

    /// A score when `sentence` reads as a question for the user, nil otherwise.
    private static func score(_ sentence: String, userFirst: String) -> Int? {
        let lowered = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        let body = lowered.replacingOccurrences(of: leadingFillers, with: "", options: .regularExpression)
        let words = MeetingAIText.words(body)
        let addressed = MeetingAIText.containsWord(sentence, userFirst)
        guard words.count >= 3 || (addressed && words.count >= 2) else { return nil }

        if ignoredQuestions.contains(where: { body.contains($0) }) { return nil }
        if tagEndings.contains(where: { body.hasSuffix($0) }), !startsLikeQuestion(body) { return nil }
        // Rhetorical openers.
        if body.range(of: #"^(who knows|guess what|you know what|why not|what if i told you|how cool|isn't that)"#, options: .regularExpression) != nil {
            return nil
        }
        // Addressed to someone else by name: "Priya, can you…".
        if let match = sentence.range(of: #"^(?:(?:so|okay|and|hey)[,]?\s+)?([A-Z][a-z]+),\s"#, options: .regularExpression) {
            let name = sentence[match].components(separatedBy: CharacterSet(charactersIn: ", ")).filter { !$0.isEmpty }.last ?? ""
            let notNames: Set<String> = ["So", "Okay", "And", "Hey", "Well", "Now", "Also", "Yeah", "Right", "Alright", "Sorry",
                                         "Actually", "Honestly", "Basically", "Guys", "Folks", "Everyone", "Team", "Then", "But",
                                         "Quick", "Look", "Listen", "Sure", "Yes", "No", "Great", "Cool", "Thanks"]
            if !notNames.contains(name), name.lowercased() != userFirst.lowercased() { return nil }
        }

        var score = 0
        let hasMark = sentence.hasSuffix("?")
        let tail = MeetingAIText.sentences(body).last ?? body
        let opener = startsLikeQuestion(body) || startsLikeQuestion(tail)
        if hasMark { score += 2 }
        if opener { score += 2 }
        guard hasMark || opener else { return nil }
        if body.range(of: #"\b(you|your|you're|you've|you'd)\b"#, options: .regularExpression) != nil { score += 1 }
        if addressed { score += 3 }
        if body.contains("what do you think") || body.contains("any thoughts") || body.contains("your take")
            || body.contains("your thoughts") || body.contains("your opinion") { score += 1 }
        if words.count < 4, !addressed { score -= 1 }
        // Recognizers sometimes drop the "?" on longer questions.
        if !hasMark, opener, words.count >= 5 { score += 1 }
        return score >= (addressed ? 3 : 4) ? score : nil
    }

    private static func startsLikeQuestion(_ body: String) -> Bool {
        let words = MeetingAIText.words(body)
        if let first = body.split(separator: " ").first.map({ String($0).trimmingCharacters(in: .punctuationCharacters) }),
           interrogatives.contains(first) { return true }
        if let first = words.first, interrogatives.contains(first) { return true }
        if questionOpeners.contains(where: { body.hasPrefix($0) }) { return true }
        // "Koushik, what's the status?" / "and Koushik, can you…".
        if let comma = body.firstIndex(of: ","), body.distance(from: body.startIndex, to: comma) < 24 {
            let rest = body[body.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if let first = MeetingAIText.words(rest).first, interrogatives.contains(first) { return true }
            if questionOpeners.contains(where: { rest.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// Drops leading fillers and makes it read as a question.
    static func clean(_ question: String) -> String {
        var text = MeetingAIText.collapse(question)
        text = text.replacingOccurrences(of: leadingFillers, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\b(um+|uh+|er+)\b[,]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = MeetingAIText.collapse(text)
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        if !text.hasSuffix("?") {
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!, ")) + "?"
        }
        return text
    }

    // MARK: - Answering

    /// How much transcript before the question grounds the answer.
    static let contextWindow: TimeInterval = 180

    static func instructions(userFirst: String) -> String {
        """
        You help \(userFirst) in a live meeting. Someone just asked \(userFirst) a question. Write the reply \(userFirst) can say \
        out loud right now: first person as \(userFirst), natural and spoken, 1 to 3 short sentences, direct answer first.
        The transcript between <transcript> tags is the recent conversation; "\(userFirst)" lines are \(userFirst), "Others" \
        are other participants. Ground the reply in it. Never invent facts, numbers, dates, names or commitments that are \
        not in the transcript, and never claim \(userFirst) did something the transcript doesn't say. When the facts are \
        missing, say briefly that \(userFirst) will check and follow up, or ask one clarifying question. Stay on the question.
        Output only the reply text: no quotes, labels, preamble or options.
        """
    }

    static func prompt(question: String, context: [TranscriptSegment], userFirst: String, maxChars: Int) -> String {
        let segments = MeetingAIText.latestSegments(context)
        let latest = segments.last?.end ?? 0
        let window = segments.filter { latest - $0.end <= contextWindow }
        var lines = MeetingAIText.turns(window, maxChars: 600).map { MeetingAIText.line($0, userFirst: userFirst) }
        // Keep the newest lines within the budget.
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        while total > maxChars, lines.count > 1 {
            total -= lines.removeFirst().count + 1
        }
        let transcript = lines.joined(separator: "\n")
        return "<transcript>\n\(String(transcript.suffix(maxChars)))\n</transcript>\nQuestion for \(userFirst): \(question)\nReply as \(userFirst):"
    }

    /// Call when recording starts: loads the on-device model and prepares a
    /// session so the first answer skips the cold start.
    static func prewarm(userName: String) {
        MeetingAIBackend.prewarm(instructions: instructions(userFirst: MeetingAIText.firstName(userName)))
    }

    /// A 1-3 sentence reply in the user's voice. Groq (when allowed) first,
    /// else the on-device model; each attempt is time-limited.
    func answer(question: String, context: [TranscriptSegment], userName: String) async throws -> String {
        let userFirst = MeetingAIText.firstName(userName)
        let system = Self.instructions(userFirst: userFirst)
        let started = Date()
        var lastError: Error = MeetingAIError.unavailable(MeetingAIBackend.onDeviceUnavailableReason ?? "no model")

        if config.groqEnabled {
            do {
                let reply = try await MeetingAIBackend.groq(
                    config: config, system: system,
                    user: Self.prompt(question: question, context: context, userFirst: userFirst, maxChars: 12000),
                    json: false, maxTokens: 700, reasoningEffort: "low", timeout: 3.5
                )
                if let cleaned = Self.cleanAnswer(reply, userFirst: userFirst) {
                    AppLog.log("Meetings AI: answer by Groq in \(Self.milliseconds(since: started)) ms")
                    return cleaned
                }
                lastError = MeetingAIError.badResponse
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Meetings AI: Groq answer failed (\(error.localizedDescription))")
                lastError = error
            }
        }

        if MeetingAIBackend.onDeviceAvailable {
            do {
                let reply = try await MeetingAIBackend.onDevice(
                    instructions: system,
                    prompt: Self.prompt(question: question, context: context, userFirst: userFirst, maxChars: 3000),
                    schema: nil, maxTokens: 120, timeout: config.groqEnabled ? 4 : 8, permissive: false
                )
                // Have a warm session ready for the next question.
                MeetingAIBackend.prewarm(instructions: system)
                if let cleaned = Self.cleanAnswer(reply, userFirst: userFirst) {
                    AppLog.log("Meetings AI: answer on-device in \(Self.milliseconds(since: started)) ms")
                    return cleaned
                }
                lastError = MeetingAIError.badResponse
            } catch is CancellationError {
                throw CancellationError()
            } catch MeetingAIError.contextTooLarge {
                // Retry once with less context.
                let reply = try await MeetingAIBackend.onDevice(
                    instructions: system,
                    prompt: Self.prompt(question: question, context: context, userFirst: userFirst, maxChars: 1500),
                    schema: nil, maxTokens: 120, timeout: 4, permissive: false
                )
                if let cleaned = Self.cleanAnswer(reply, userFirst: userFirst) { return cleaned }
                lastError = MeetingAIError.badResponse
            } catch {
                AppLog.log("Meetings AI: on-device answer failed (\(error.localizedDescription))")
                lastError = error
            }
        }
        throw lastError
    }

    /// Strips labels, quotes and assistant chatter; at most three sentences.
    static func cleanAnswer(_ raw: String, userFirst: String) -> String? {
        var text = MeetingAIJSON.stripReasoning(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON despite the instructions.
        if text.hasPrefix("{"), let object = MeetingAIJSON.object(from: text) {
            text = ["answer", "reply", "response", "text"].lazy.compactMap { object[$0] as? String }.first ?? text
        }
        let labels = "(?:answer|reply|response|suggested reply|suggestion|\(NSRegularExpression.escapedPattern(for: userFirst))|me|you could say|you can say)"
        text = text.replacingOccurrences(of: "^\\**\(labels)\\**\\s*[:：-]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?transcript>"#, with: "", options: .regularExpression)
        text = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        let lowered = text.lowercased()
        if ["as an ai", "i'm sorry, but i can't", "i cannot help", "i can't assist"].contains(where: { lowered.hasPrefix($0) }) {
            return nil
        }
        let sentences = MeetingAIText.sentences(text)
        text = sentences.prefix(3).joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 2 ? text : nil
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
