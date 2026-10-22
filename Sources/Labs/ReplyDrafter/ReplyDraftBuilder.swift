import Foundation

// Pure draft-building steps: learn the user's tone from their own messages,
// pick the most relevant Space context, build the model prompt within the
// on-device context budget, and clean the model's reply. Also the
// deterministic template used when no model is available.

// MARK: - Tone

enum ReplyToneLearner {
    static let signOffs = [
        "best regards", "kind regards", "warm regards", "warmly", "best wishes", "many thanks", "thanks so much",
        "thank you", "thanks again", "thanks", "thx", "cheers", "best", "regards", "talk soon", "speak soon", "sincerely",
        "all the best", "ty",
    ]

    static func learn(
        from messages: [ReplyMessage], kind: ReplyAppKind, userName: String, preference: String, signOff: String
    ) -> ReplyToneProfile {
        var profile = ReplyToneProfile(userName: userName)
        profile.preference = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = messages.filter(\.isFromMe).map(\.text).filter { !$0.isEmpty }
        let setSignOff = signOff.trimmingCharacters(in: .whitespacesAndNewlines)
        if !setSignOff.isEmpty { profile.signOff = setSignOff }
        guard !own.isEmpty else { return profile }

        var greetings: [String] = []
        var closings: [String] = []
        for text in own {
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let first = lines.first, let greeting = greeting(of: first) { greetings.append(greeting) }
            if kind.isEmail, let closing = closing(of: lines) { closings.append(closing) }
        }
        profile.greeting = mostCommon(greetings)
        if profile.signOff == nil { profile.signOff = mostCommon(closings) }
        profile.usesEmoji = own.contains { containsEmoji($0) }
        let letters = own.compactMap { $0.first(where: \.isLetter) }
        profile.startsLowercase = !letters.isEmpty && Double(letters.filter(\.isLowercase).count) / Double(letters.count) >= 0.6
        profile.usesExclamations = Double(own.filter { $0.contains("!") }.count) / Double(own.count) >= 0.4
        let counts = own.map { $0.split { $0 == " " || $0 == "\n" }.count }.sorted()
        profile.typicalWords = counts[counts.count / 2]
        profile.examples = own.reversed()
            .filter { (3...80).contains($0.split(separator: " ").count) }
            .prefix(3)
            .map { String($0.prefix(280)) }
            .reversed()
        return profile
    }

    /// "Hi Sarah," → "Hi"; "hey!" → "Hey".
    static func greeting(of line: String) -> String? {
        let pattern = #"^(hi|hey|hello|dear|good morning|good afternoon|morning|hiya|yo)\b[^.!?\n]{0,30}[,!]?$"#
        guard let range = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let word = line[range].split(whereSeparator: { $0 == " " || $0 == "," || $0 == "!" }).first.map(String.init) ?? ""
        guard !word.isEmpty else { return nil }
        let lower = word.lowercased()
        if lower == "good" { return line.lowercased().hasPrefix("good morning") ? "Good morning" : "Good afternoon" }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// The sign-off line ("Best,") near the end of an email.
    static func closing(of lines: [String]) -> String? {
        for line in lines.suffix(3).reversed() {
            let lower = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.! "))
            if let match = signOffs.first(where: { lower == $0 }) {
                return match.prefix(1).uppercased() + match.dropFirst() + ","
            }
        }
        return nil
    }

    static func containsEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2100 && $0.value != 0x2122) }
    }

    private static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// Bullet points describing the style, for the prompt.
    static func styleNotes(_ profile: ReplyToneProfile, kind: ReplyAppKind) -> [String] {
        var notes: [String] = []
        if !profile.preference.isEmpty { notes.append("Tone they asked for: \(profile.preference)") }
        if profile.typicalWords > 0 {
            let words = kind.isEmail ? max(profile.typicalWords, 25) : profile.typicalWords
            notes.append("Their messages are usually about \(words) words long.")
        }
        if kind.isEmail {
            if let greeting = profile.greeting { notes.append("They open emails with \"\(greeting) <first name>,\".") }
            if let signOff = profile.signOff { notes.append("They sign off with \"\(signOff)\" and their first name.") }
        } else if let greeting = profile.greeting, greeting == "Hey" || greeting == "Hi" {
            notes.append("They sometimes start with \"\(greeting)\".")
        }
        if profile.startsLowercase { notes.append("They often write in lowercase.") }
        if profile.usesExclamations { notes.append("They use exclamation marks.") }
        if !profile.examples.isEmpty || profile.typicalWords > 0 {
            notes.append(profile.usesEmoji ? "They use emoji now and then." : "They don't use emoji.")
        }
        return notes
    }
}

// MARK: - Space context

enum ReplySpaceContextBuilder {
    /// Search text for SpaceStore.search: the subject and the latest incoming
    /// message first (Spaces' keyword search ORs the first 12 terms).
    static func query(for conversation: ReplyConversation) -> String {
        var parts: [String] = []
        if let subject = conversation.subject { parts.append(subject) }
        if !conversation.title.isEmpty, conversation.title != conversation.subject { parts.append(conversation.title) }
        if let last = conversation.lastIncoming { parts.append(String(last.text.suffix(400))) }
        if !conversation.existingDraft.isEmpty { parts.append(conversation.existingDraft) }
        parts.append(contentsOf: conversation.participants.prefix(3))
        var seen = Set<String>()
        var terms: [String] = []
        for word in parts.joined(separator: " ").split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let w = String(word)
            let lower = w.lowercased()
            guard w.count >= 3, !stopWords.contains(lower), seen.insert(lower).inserted else { continue }
            terms.append(w)
            if terms.count >= 12 { break }
        }
        return terms.joined(separator: " ")
    }

    /// "sam.patel@vendorco.com" → "Sam"; "Sam Patel <sam@x.com>" → "Sam".
    static func displayName(forAddress raw: String) -> String {
        let name = raw.replacingOccurrences(of: #"\s*<[^>]*>$"#, with: "", options: .regularExpression)
        if !name.contains("@") { return name.split(separator: " ").first.map(String.init) ?? name }
        let local = name.split(separator: "@").first.map(String.init) ?? name
        let first = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).first.map(String.init) ?? local
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "this", "that", "are", "was", "have", "has", "can", "will", "would",
        "could", "should", "just", "about", "what", "when", "where", "which", "there", "here", "from", "they", "them",
        "our", "out", "but", "not", "all", "any", "get", "got", "let", "know", "thanks", "thank", "please", "hey",
        "hello", "regards", "best", "also", "some", "then", "than", "into", "been", "were", "its", "it's", "i'm", "re",
        "fwd", "today", "tomorrow", "yesterday", "okay", "their", "these", "those", "did", "does", "update",
    ]

    /// The Space most hits belong to (rank-weighted), and snippets from its
    /// items that best match the query, within `budget` characters.
    static func pick(
        hits: [SpaceItem], spaces: [Space], query: String, background: (UUID) -> String?, budget: Int = 1_200
    ) -> ReplySpaceContext {
        guard !hits.isEmpty else { return ReplySpaceContext() }
        var scores: [UUID: Double] = [:]
        for (rank, item) in hits.prefix(10).enumerated() {
            guard let spaceID = item.spaceID else { continue }
            scores[spaceID, default: 0] += 1 / Double(rank + 1)
        }
        let best = scores.max { $0.value == $1.value ? $0.key.uuidString > $1.key.uuidString : $0.value < $1.value }?.key
        let chosen = hits.filter { best == nil ? true : $0.spaceID == best }.prefix(3)
        var context = ReplySpaceContext(spaceID: best, spaceName: best.flatMap { id in spaces.first { $0.id == id }?.name })
        if let best, let memory = background(best)?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            context.background = String(memory.prefix(300))
        }
        let terms = Set(query.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        var remaining = budget - (context.background?.count ?? 0)
        for item in chosen where remaining > 80 {
            let snippet = bestSentences(item.text, terms: terms, limit: min(420, remaining - item.title.count))
            guard !snippet.isEmpty else { continue }
            context.snippets.append(.init(title: String(item.title.prefix(80)), text: snippet))
            remaining -= snippet.count + item.title.count + 6
        }
        return context
    }

    /// The sentences sharing the most words with the query, in text order.
    static func bestSentences(_ text: String, terms: Set<String>, limit: Int) -> String {
        guard limit > 40 else { return "" }
        let sentences = text.replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 }
        guard !sentences.isEmpty else { return String(text.prefix(limit)) }
        let scored = sentences.enumerated().map { index, sentence -> (Int, Int) in
            let words = Set(sentence.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
            return (index, words.intersection(terms).count)
        }
        // Only sentences that share words with the query (all of them if none do).
        let matching = scored.filter { $0.1 > 0 }
        let ranked = (matching.isEmpty ? Array(scored.prefix(2)) : matching).sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var picked: [Int] = []
        var length = 0
        for (index, _) in ranked {
            let s = sentences[index]
            if length + s.count + 2 > limit { continue }
            picked.append(index)
            length += s.count + 2
            if picked.count >= 4 { break }
        }
        if picked.isEmpty { return String(sentences[0].prefix(limit)) }
        return picked.sorted().map { sentences[$0] + "." }.joined(separator: " ")
    }
}

// MARK: - Prompt

struct ReplyDraftRequest: Sendable, Equatable {
    var conversation: ReplyConversation
    var tone: ReplyToneProfile
    var space: ReplySpaceContext
    /// Ask the model for a subject (email with an empty Subject field).
    var wantsSubject: Bool
    /// Bumped by Regenerate so greedy decoding gives a different draft.
    var variation = 0
    /// The draft Regenerate replaces (the model is asked for a different one).
    var previousDraft: String?
}

enum ReplyPromptBuilder {
    /// The on-device model has a 4,096-token context (prompt + reply); about
    /// 3.5 characters per token leaves room for a 450-token reply.
    static let conversationBudget = 3_600
    static let maxReplyTokens = 450

    static func firstName(_ tone: ReplyToneProfile) -> String {
        tone.userName.split(separator: " ").first.map(String.init) ?? "Me"
    }

    static func instructions(kind: ReplyAppKind, tone: ReplyToneProfile) -> String {
        let name = firstName(tone)
        let medium = kind.isEmail ? "email thread" : "chat"
        let format = kind.isEmail
            ? "Format: an email body only: a greeting line, one to three short paragraphs, then a sign-off line and the name \(name). Never write a subject line inside the body."
            : "Format: one chat message of one to three short sentences, plain text, with no greeting line and no sign-off."
        return """
        You draft replies for \(name). Write the reply \(name) would send next in this \(medium), in \(name)'s own voice, as \(name) (first person).
        Use only facts from the conversation, the notes and \(name)'s intent. Never invent dates, times, numbers, prices, links, attachments or promises. If something needed is unknown, ask for it briefly or keep it general.
        Never claim something is done, decided or agreed unless the conversation or the intent says so.
        Answer the latest message from the other person. Do not repeat or quote the conversation. No placeholders in brackets. Never say you are an AI.
        \(format)
        """
    }

    static func schema(wantsSubject: Bool) -> MeetingAISchema {
        var properties = [
            MeetingAISchema.Property(name: "reply", description: "The complete reply text exactly as it will be sent", schema: .string),
        ]
        if wantsSubject {
            properties.append(.init(name: "subject", description: "A short email subject line of 3 to 8 words", schema: .string))
        }
        return .object(name: "ReplyDraft", properties: properties)
    }

    /// Latest messages that fit `budget`, oldest first.
    static func transcript(_ messages: [ReplyMessage], budget: Int) -> String {
        var lines: [String] = []
        var used = 0
        for message in messages.reversed() {
            var text = message.text.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            if text.count > 900 { text = String(text.prefix(880)) + " …" }
            let line = "\(message.isFromMe ? "Me" : message.author): \(text)"
            if used + line.count > budget {
                if lines.isEmpty { lines.append(String(line.suffix(budget))) }
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    static func prompt(_ request: ReplyDraftRequest, conversationBudget budget: Int = conversationBudget) -> String {
        let c = request.conversation
        let name = firstName(request.tone)
        var sections: [String] = []
        var header = "App: \(c.kind.displayName)"
        if !c.title.isEmpty { header += c.kind.isEmail ? " · Subject: \(c.subject ?? c.title)" : " · \(c.title)" }
        if !c.recipients.isEmpty { header += " · To: " + c.recipients.joined(separator: ", ") }
        sections.append(header)
        if !c.messages.isEmpty {
            sections.append("Conversation, oldest first (\"Me\" is \(name)):\n<conversation>\n\(transcript(c.messages, budget: budget))\n</conversation>")
        }
        if !request.space.isEmpty {
            var notes: [String] = []
            if let background = request.space.background { notes.append("- Background: \(background)") }
            for snippet in request.space.snippets { notes.append("- \(snippet.title): \(snippet.text)") }
            let where_ = request.space.spaceName.map { " from the \"\($0)\" Space" } ?? ""
            sections.append("Notes\(where_) (use only what is relevant):\n<notes>\n\(notes.joined(separator: "\n"))\n</notes>")
        }
        let style = ReplyToneLearner.styleNotes(request.tone, kind: c.kind)
        if !style.isEmpty { sections.append("\(name)'s style:\n" + style.map { "- \($0)" }.joined(separator: "\n")) }
        if !request.tone.examples.isEmpty {
            let examples = request.tone.examples.joined(separator: "\n---\n")
            sections.append("Messages \(name) wrote (match this voice, don't copy them):\n<examples>\n\(examples)\n</examples>")
        }
        if !c.existingDraft.isEmpty {
            sections.append("What \(name) wants to say (follow it, expand it into the reply):\n<intent>\n\(String(c.existingDraft.prefix(800)))\n</intent>")
        }
        sections.append(task(request))
        return sections.joined(separator: "\n\n")
    }

    private static func task(_ request: ReplyDraftRequest) -> String {
        let c = request.conversation
        let name = firstName(request.tone)
        var task: String
        if c.messages.isEmpty {
            let to = c.recipients.first.map { " to \(ReplySpaceContextBuilder.displayName(forAddress: $0))" } ?? ""
            task = "Task: Write the \(c.kind.isEmail ? "email" : "message") \(name) sends\(to). The intent is \(name)'s own shorthand note: turn it into the message itself, written from \(name) directly to the recipient."
        } else if let last = c.lastIncoming {
            let author = last.author == "Them" ? "the other person" : last.author
            task = "Task: Write \(name)'s reply to \(author)'s latest message. If it asks \(name) to do something, acknowledge it and say what \(name) will do; don't say it is already done."
            if c.messages.last?.isFromMe == true {
                task += " \(name) already wrote after it, so write a short follow-up that adds to \(name)'s last message."
            }
        } else {
            task = "Task: Write a short follow-up from \(name) to the conversation."
        }
        if request.wantsSubject { task += " Also give a short subject line." }
        if request.variation > 0 {
            let styles = ["Use a different opening and different wording.", "Try another angle, still accurate.", "Phrase it differently from before."]
            task += " Variation \(request.variation + 1): " + styles[(request.variation - 1) % styles.count]
        }
        if let previous = request.previousDraft, !previous.isEmpty {
            task = "Earlier draft (write a clearly different one):\n<previous>\n\(String(previous.prefix(1_000)))\n</previous>\n\n" + task
        }
        return task
    }

    /// The rewrite step: a little context, the current draft, one instruction.
    /// Style notes are left out for formal/casual so they don't pull the
    /// rewrite back to the old tone.
    static func revisionPrompt(_ request: ReplyDraftRequest, current: String, revision: ReplyRevision) -> String {
        let c = request.conversation
        let name = firstName(request.tone)
        var sections: [String] = ["App: \(c.kind.displayName)" + (c.title.isEmpty ? "" : " · \(c.title)")]
        if !c.messages.isEmpty {
            sections.append("Conversation for context (\"Me\" is \(name)):\n<conversation>\n\(transcript(Array(c.messages.suffix(4)), budget: 1_600))\n</conversation>")
        }
        if revision == .shorter || revision == .longer {
            let style = ReplyToneLearner.styleNotes(request.tone, kind: c.kind).filter { !$0.hasPrefix("Their messages are usually") }
            if !style.isEmpty { sections.append("\(name)'s style:\n" + style.map { "- \($0)" }.joined(separator: "\n")) }
        }
        sections.append("Current draft by \(name):\n<draft>\n\(String(current.prefix(1_500)))\n</draft>")
        sections.append("Task: \(revision.instruction) Keep every fact from the draft and add none. Output only the rewritten \(c.kind.isEmail ? "email body" : "message").")
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Cleaning

enum ReplyDraftCleaner {
    /// The model's reply → the text to insert.
    static func clean(_ raw: String, kind: ReplyAppKind, tone: ReplyToneProfile, conversation: ReplyConversation) -> String {
        var text = MeetingAIJSON.stripReasoning(raw)
        text = text.replacingOccurrences(of: #"```[a-z]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // "Here's a draft reply:" / "Reply:" labels.
        text = text.replacingOccurrences(
            of: #"^(here(’|')?s|here is)\s+(a|the|your|my)\s+[^\n:]{0,40}:\s*"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"^(reply|draft|response|message)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"^subject\s*:[^\n]*\n+"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = unquote(text)
        // Small models sometimes write line breaks as " / " or double spaces.
        if !text.contains("\n"), text.components(separatedBy: " / ").count >= 3 {
            text = text.replacingOccurrences(of: " / ", with: "\n")
        }
        if !text.contains("\n"), text.contains("  ") {
            text = text.replacingOccurrences(of: #" {2,}"#, with: "\n\n", options: .regularExpression)
        }
        if kind.isEmail, !text.contains("\n") { text = splitOneLineEmail(text, tone: tone) }
        let first = ReplyPromptBuilder.firstName(tone)
        text = text.replacingOccurrences(of: #"\[(your|my) (first )?name\]|<your name>|\{your name\}"#, with: first, options: [.regularExpression, .caseInsensitive])
        let recipient = conversation.lastIncoming.map { ReplyConversationReader.cleanAuthor($0.author) }
            .flatMap { $0 == "Them" ? nil : $0.split(separator: " ").first.map(String.init) }
            ?? conversation.recipients.first.map(ReplySpaceContextBuilder.displayName(forAddress:))
        if let recipient {
            text = text.replacingOccurrences(of: #"\[(recipient('s)?( name)?|name|their name|first name)\]"#, with: recipient, options: [.regularExpression, .caseInsensitive])
        } else {
            text = text.replacingOccurrences(of: #"\s*\[(recipient('s)?( name)?|name|their name|first name)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        var lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix(">") }
        // Drop a quoted copy of the conversation the model may echo.
        if let cut = lines.firstIndex(where: { ReplyConversationReader.isQuoteIntro($0) }) { lines = Array(lines[..<cut]) }
        text = lines.joined(separator: "\n")
        if kind.isEmail {
            text = ensureSignOff(text, tone: tone)
            if let signature = conversation.signature { text = trimForSignature(text, signature: signature, tone: tone) }
        } else {
            text = stripChatSignOff(text, tone: tone)
        }
        if !tone.usesEmoji, tone.examples.count >= 2 { text = stripEmoji(text) }
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 2_400 { text = String(text.prefix(2_400)) }
        return text
    }

    /// "Hi Sam, Could you … Best regards, Koushik" → greeting, body and
    /// sign-off on their own lines.
    static func splitOneLineEmail(_ text: String, tone: ReplyToneProfile) -> String {
        var t = text
        let greeting = #"^((hi|hello|hey|dear|good morning|good afternoon)\b[^,!.\n]{0,40}[,!])\s+"#
        if let range = t.range(of: greeting, options: [.regularExpression, .caseInsensitive]) {
            let head = t[range].trimmingCharacters(in: .whitespaces)
            t = head + "\n\n" + t[range.upperBound...]
        }
        let first = NSRegularExpression.escapedPattern(for: ReplyPromptBuilder.firstName(tone))
        let closings = ReplyToneLearner.signOffs.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let signOff = #"\s+("# + closings + #")([,!.]?)\s+("# + first + #")\.?\s*$"#
        if let regex = try? NSRegularExpression(pattern: signOff, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let whole = Range(match.range, in: t), let word = Range(match.range(at: 1), in: t), let name = Range(match.range(at: 3), in: t) {
            let closing = String(t[word])
            t = String(t[..<whole.lowerBound]) + "\n\n" + closing.prefix(1).uppercased() + closing.dropFirst() + ",\n" + String(t[name])
        }
        return t
    }

    static func cleanSubject(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: #"^subject\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = unquote(s).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        s = s.components(separatedBy: "\n").first ?? s
        if MeetingAIText.isPlaceholder(s) { return nil }
        return s.count > 90 ? String(s.prefix(90)) : s
    }

    private static func unquote(_ text: String) -> String {
        var t = text
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] where t.hasPrefix(open) && t.hasSuffix(close) && t.count > 2 {
            let inner = t.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { t = String(inner) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Makes an email end with the user's sign-off and first name.
    static func ensureSignOff(_ text: String, tone: ReplyToneProfile) -> String {
        let first = ReplyPromptBuilder.firstName(tone)
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces) else { return text }
        let lastLower = last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.! "))
        let endsWithSignOff = ReplyToneLearner.signOffs.contains(lastLower)
        let endsWithName = lastLower == first.lowercased() || lastLower == tone.userName.lowercased()
        if endsWithSignOff {
            lines.append(first)
        } else if !endsWithName {
            lines.append("")
            lines.append(tone.signOff ?? "Best,")
            lines.append(first)
        }
        return lines.joined(separator: "\n")
    }

    /// The message box already ends with the user's signature (Apple Mail:
    /// "Koushik\nCriska Security", or "Best,\nKoushik"): the draft keeps its
    /// sign-off line but not a second copy of the name (or of both).
    static func trimForSignature(_ text: String, signature: String, tone: ReplyToneProfile) -> String {
        let me = ReplyIdentity(fullName: tone.userName)
        let sigLines = signature.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let sigFirst = sigLines.first else { return text }
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), me.matches(last.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))) else { return text }
        lines.removeLast()
        let sigStartsWithSignOff = ReplyToneLearner.signOffs.contains(sigFirst.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!- ")))
        while let tail = lines.last, tail.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let endsWithSignOff = lines.last.map {
            ReplyToneLearner.signOffs.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!- ")))
        } ?? false
        if sigStartsWithSignOff {
            // "Best,\nKoushik" is already in the box.
            if endsWithSignOff { lines.removeLast() }
        } else if !endsWithSignOff {
            // The model signed with the name only: keep a sign-off line above
            // the box's own name signature.
            lines.append("")
            lines.append(tone.signOff ?? "Best,")
        }
        while let tail = lines.last, tail.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let result = lines.joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : result
    }

    /// Chat messages don't end with "Best,\nKoushik".
    static func stripChatSignOff(_ text: String, tone: ReplyToneProfile) -> String {
        let first = ReplyPromptBuilder.firstName(tone).lowercased()
        var lines = text.components(separatedBy: "\n")
        for _ in 0..<2 {
            guard let last = lines.last?.trimmingCharacters(in: .whitespaces) else { break }
            let lower = last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!- "))
            if lower.isEmpty || lower == first || lower == tone.userName.lowercased() || ReplyToneLearner.signOffs.contains(lower) {
                lines.removeLast()
            } else {
                break
            }
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    static func stripEmoji(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let p = scalar.properties
            let isEmoji = p.isEmojiPresentation || (p.isEmoji && scalar.value > 0x2100 && scalar.value != 0x2122)
                || scalar.value == 0xFE0F || scalar.value == 0x200D
            if !isEmoji { scalars.append(scalar) }
        }
        return String(scalars).replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }
}

// MARK: - Template (no model)

/// A deterministic draft when Apple Intelligence is off and Groq isn't
/// allowed: short, factual, never invents details.
enum ReplyTemplate {
    static let producedBy = "Basic template"

    static func draft(_ request: ReplyDraftRequest) -> ReplyDraft {
        let c = request.conversation
        let tone = request.tone
        let first = ReplyPromptBuilder.firstName(tone)
        let incoming = c.lastIncoming
        let them = incoming.map { ReplyConversationReader.cleanAuthor($0.author) }
            .flatMap { $0 == "Them" ? nil : $0.split(separator: " ").first.map(String.init) }
            ?? c.recipients.first.map(ReplySpaceContextBuilder.displayName(forAddress:))
        let asksQuestion = incoming?.text.contains("?") ?? false
        var core: String
        if !c.existingDraft.isEmpty {
            core = sentence(c.existingDraft)
        } else if asksQuestion {
            core = "Thanks for asking. Let me check and get back to you shortly."
        } else if incoming != nil {
            core = "Thanks, got it. I'll follow up soon."
        } else {
            core = "I wanted to reach out about this."
        }
        let body: String
        if c.kind.isEmail {
            let greeting = (tone.greeting ?? "Hi") + (them.map { " \($0)" } ?? "") + ","
            let signed = "\(greeting)\n\n\(core)\n\n\(tone.signOff ?? "Best,")\n\(first)"
            body = c.signature.map { ReplyDraftCleaner.trimForSignature(signed, signature: $0, tone: tone) } ?? signed
        } else {
            body = tone.startsLowercase ? core.prefix(1).lowercased() + core.dropFirst() : core
        }
        var subject: String?
        if request.wantsSubject {
            subject = c.subject.map { $0.lowercased().hasPrefix("re:") ? $0 : "Re: \($0)" }
                ?? String(c.existingDraft.split(separator: "\n").first?.prefix(60) ?? "Quick note")
        }
        return ReplyDraft(body: body, subject: subject, producedBy: producedBy)
    }

    /// Simple rewrites without a model.
    static func revise(_ text: String, revision: ReplyRevision, kind: ReplyAppKind) -> String {
        switch revision {
        case .shorter:
            let sentences = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if kind.isEmail, sentences.count > 3 {
                return ([sentences[0], "", sentences[1], ""] + sentences.suffix(2)).joined(separator: "\n")
            }
            return sentences.first.map(firstSentence) ?? text
        case .formal:
            return text.replacingOccurrences(of: #"^(Hey|Hiya|Yo)\b"#, with: "Hello", options: .regularExpression)
                .replacingOccurrences(of: "Cheers,", with: "Kind regards,")
                .replacingOccurrences(of: "Thanks,", with: "Thank you,")
                .replacingOccurrences(of: "got it", with: "noted")
        case .casual:
            return text.replacingOccurrences(of: #"^(Hello|Dear)\b"#, with: "Hey", options: .regularExpression)
                .replacingOccurrences(of: "Kind regards,", with: "Cheers,")
                .replacingOccurrences(of: "Best regards,", with: "Cheers,")
                .replacingOccurrences(of: "Thank you", with: "Thanks")
        case .longer, .regenerate:
            return text
        }
    }

    private static func firstSentence(_ text: String) -> String {
        guard let end = text.firstIndex(where: { ".!?".contains($0) }) else { return text }
        return String(text[...end])
    }

    private static func sentence(_ notes: String) -> String {
        var t = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first.isLowercase { t = first.uppercased() + t.dropFirst() }
        if let last = t.last, !".!?".contains(last) { t += "." }
        return t
    }
}
