import Foundation

/// Turns a meeting transcript into minutes of meeting (`MeetingNotes`):
/// summary, key points, decisions, the user's own tasks, everyone else's
/// tasks, open questions and next steps.
///
/// Map-reduce:
/// 1. The transcript becomes "[mm:ss] Speaker: words" lines (the microphone
///    is the user, system audio is "Others") cut into chunks that fit the
///    model: ~6,500 characters on-device (4,096-token context, shared with
///    the instructions, schema and reply), ~24,000 for Groq.
/// 2. Map: each chunk yields partial notes as structured JSON. A chunk that
///    still overflows the context is split in two and retried.
/// 3. Reduce: decisions, tasks and questions are merged and deduplicated
///    deterministically (so nothing is lost to a second model pass); the
///    model writes the overall summary, key points and next steps from the
///    chunk summaries (hierarchically when they do not fit).
/// 4. Validation: owners that never occur in the transcript become "Others",
///    due dates that were never spoken are dropped, and high-precision rules
///    add tasks the model missed for the user ("Koushik, can you…" + "sure").
/// Without any model (or when every request fails) a deterministic
/// extractor produces the notes.
struct MeetingSummarizer: Sendable {
    let config: MeetingAIConfig

    init(config: MeetingAIConfig) {
        self.config = config
    }

    static let onDeviceChunkChars = 6500
    static let groqChunkChars = 24000
    static let onDeviceLabel = "On-device"
    static let fallbackLabel = "On-device (basic)"

    /// Notes the user typed during the meeting are budgeted to this many
    /// characters per request (on-device / Groq).
    static let onDeviceUserNotesChars = 1000
    static let groqUserNotesChars = 4000

    func summarize(
        title: String, segments: [TranscriptSegment], userName: String, userNotes: String? = nil
    ) async throws -> MeetingNotes {
        let userFirst = MeetingAIText.firstName(userName)
        let turns = MeetingAIText.turns(segments)
        let typed = Self.cleanUserNotes(userNotes)
        guard !turns.isEmpty else {
            var notes = MeetingNotes(
                summary: "No speech was captured in this meeting.", keyPoints: [], decisions: [],
                myTasks: [], othersTasks: [], openQuestions: [], nextSteps: [], generatedBy: Self.fallbackLabel
            )
            Self.addUserNoteTasks(to: &notes, userNotes: typed, userFirst: userFirst)
            return notes
        }
        let started = Date()
        let transcriptText = turns.map(\.text).joined(separator: "\n")

        let useGroq = config.groqEnabled
        let useOnDevice = MeetingAIBackend.onDeviceAvailable
        guard useGroq || useOnDevice else {
            AppLog.log("Meetings AI: no model (\(MeetingAIBackend.onDeviceUnavailableReason ?? "?")), using rules")
            var notes = Self.deterministicNotes(turns: turns, userFirst: userFirst)
            Self.addUserNoteTasks(to: &notes, userNotes: typed, userFirst: userFirst)
            return notes
        }

        let maxChars = useGroq ? Self.groqChunkChars : Self.onDeviceChunkChars
        let notesForPrompt = String(typed.prefix(useGroq ? Self.groqUserNotesChars : Self.onDeviceUserNotesChars))
        var pending = MeetingAIText.chunks(turns, userFirst: userFirst, maxChars: maxChars)
        let total = pending.count
        var partials: [PartialNotes] = []
        var engines = Set<String>()
        var index = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            let chunk = pending.removeFirst()
            index += 1
            do {
                let (partial, engine) = try await mapChunk(
                    chunk, part: index, of: max(total, index + pending.count), title: title,
                    userFirst: userFirst, userNotes: notesForPrompt, useGroq: useGroq, useOnDevice: useOnDevice
                )
                partials.append(partial)
                engines.insert(engine)
            } catch MeetingAIError.contextTooLarge {
                let halves = MeetingAIText.split(chunk)
                if halves.count > 1 {
                    pending.insert(contentsOf: halves, at: 0)
                    index -= 1
                } else {
                    partials.append(Self.deterministicPartial(chunk: chunk, userFirst: userFirst))
                    engines.insert(Self.fallbackLabel)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Meetings AI: chunk \(index) failed (\(error.localizedDescription)), using rules for it")
                partials.append(Self.deterministicPartial(chunk: chunk, userFirst: userFirst))
                engines.insert(Self.fallbackLabel)
            }
        }

        var notes = Self.merge(partials, userFirst: userFirst, transcript: transcriptText)
        if partials.count > 1 {
            do {
                let (overview, engine) = try await reduce(
                    partials, title: title, userFirst: userFirst, useGroq: useGroq, useOnDevice: useOnDevice
                )
                if let summary = overview.summary { notes.summary = summary }
                if !overview.keyPoints.isEmpty { notes.keyPoints = overview.keyPoints }
                if !overview.nextSteps.isEmpty { notes.nextSteps = overview.nextSteps }
                engines.insert(engine)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Meetings AI: reduce failed (\(error.localizedDescription)), joining chunk summaries")
            }
        }
        Self.addMissedTasks(to: &notes, turns: turns, userFirst: userFirst)
        Self.addUserNoteTasks(to: &notes, userNotes: typed, userFirst: userFirst)
        if notes.nextSteps.isEmpty { notes.nextSteps = Self.nextSteps(from: notes) }
        notes.generatedBy = Self.label(for: engines)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        AppLog.log("Meetings AI: notes from \(turns.count) turns in \(partials.count) part(s) by \(notes.generatedBy) in \(elapsed) s")
        return notes
    }

    private static func label(for engines: Set<String>) -> String {
        let models = engines.filter { $0 != fallbackLabel }
        if models.isEmpty { return fallbackLabel }
        if let groq = models.first(where: { $0.hasPrefix("Groq") }) {
            return models.count > 1 ? "\(groq) + On-device" : groq
        }
        return onDeviceLabel
    }

    // MARK: - Map

    struct PartialNotes: Sendable, Equatable {
        var summary: String?
        var keyPoints: [String] = []
        var decisions: [String] = []
        var actionItems: [ActionItem] = []
        var openQuestions: [String] = []
        var nextSteps: [String] = []
        var start: TimeInterval = 0
        var end: TimeInterval = 0
    }

    static let chunkSchema = MeetingAISchema.object(name: "MeetingPartNotes", properties: [
        .init(name: "summary", description: "2-3 sentences on what was discussed in this part", schema: .string),
        .init(name: "keyPoints", description: "Important facts, numbers and updates, each one short sentence (max 5)",
              schema: .array(.string, maxItems: 5)),
        .init(name: "decisions", description: "What the group agreed or decided; empty if none",
              schema: .array(.string, maxItems: 5)),
        .init(name: "actionItems", description: "Concrete tasks someone committed to or was asked to do",
              schema: .array(.object(name: "ActionItem", properties: [
                  .init(name: "owner", description: "Who will do it (see the owner rules)", schema: .string),
                  .init(name: "task", description: "The task, starting with a verb", schema: .string),
                  .init(name: "due", description: "Deadline exactly as spoken, or empty", schema: .string),
              ]), maxItems: 8)),
        .init(name: "openQuestions", description: "Questions raised that were not answered or need follow-up",
              schema: .array(.string, maxItems: 3)),
        .init(name: "nextSteps", description: "What happens next (follow-up meeting, review, handoff); empty if none",
              schema: .array(.string, maxItems: 3)),
    ])

    static func mapInstructions(userFirst: String, hasUserNotes: Bool = false) -> String {
        let notesRule = hasUserNotes
            ? "\n- Lines between <my_notes> tags were typed by \(userFirst) during the meeting: they show what mattered most. " +
              "Cover those topics in the summary and keyPoints, and treat to-dos written there as \(userFirst)'s tasks."
            : ""
        return """
        You write accurate meeting minutes for \(userFirst). You receive one part of a meeting transcript between <transcript> tags. \
        Each line is "[time] Speaker: words". "\(userFirst)" is the user, speaking into the microphone. "Others" are the other \
        participants; their names are known only if someone says them. Speech recognition may contain small errors.
        Rules:
        - Use only facts stated in the transcript. Never invent names, owners, numbers or dates.
        - Lines under "Earlier context" were already covered: use them only to understand the rest.
        - actionItems: every task anyone committed to or was asked to do, for all participants, not only \(userFirst). \
        Skip things already done and hypothetical ideas. Owner rules: \
        "\(userFirst)" when \(userFirst) says "I'll", "I will", "I can" or "let me" about future work, or when someone asks \
        \(userFirst) by name or "you" to do something and \(userFirst) agrees; a person's name only when that name is spoken; \
        "Others" when a participant whose name is unknown commits; "Team" for "we" or "let's" tasks.
        - due: the deadline exactly as spoken ("Friday", "end of the week"), or "" when none was said.
        - Every item is one clear, specific sentence (keep the facts and numbers). Lists may be empty.\(notesRule)
        Reply with JSON only.
        """
    }

    func mapChunk(
        _ chunk: MeetingAIText.Chunk, part: Int, of total: Int, title: String,
        userFirst: String, userNotes: String = "", useGroq: Bool, useOnDevice: Bool
    ) async throws -> (PartialNotes, String) {
        let instructions = Self.mapInstructions(userFirst: userFirst, hasUserNotes: !userNotes.isEmpty)
        let range = "\(MeetingAIText.timestamp(chunk.start))–\(MeetingAIText.timestamp(chunk.end))"
        var prompt = "Meeting: \(Self.cleanTitle(title))\nPart \(part) of \(total) (\(range)).\n"
        if !userNotes.isEmpty {
            prompt += "<my_notes>\n\(userNotes)\n</my_notes>\n"
        }
        prompt += "<transcript>\n"
        if !chunk.context.isEmpty {
            prompt += "Earlier context:\n" + chunk.context.joined(separator: "\n") + "\n---\n"
        }
        prompt += chunk.text + "\n</transcript>"

        let reply: String
        let engine: String
        if useGroq {
            do {
                reply = try await groqJSON(
                    system: instructions + "\nJSON shape: " + Self.chunkSchema.outline + "\n" + Self.chunkSchema.fieldGuide,
                    user: prompt, maxTokens: 4096, timeout: 60
                )
                engine = "Groq \(config.groqModel)"
            } catch MeetingAIError.requestTooLarge {
                throw MeetingAIError.contextTooLarge
            } catch let error where useOnDevice && !(error is CancellationError) {
                AppLog.log("Meetings AI: Groq failed (\(error.localizedDescription)), trying on-device")
                guard chunk.characterCount <= Self.onDeviceChunkChars else { throw MeetingAIError.contextTooLarge }
                reply = try await Self.onDeviceJSON(instructions: instructions, prompt: prompt, schema: Self.chunkSchema, maxTokens: 700)
                engine = Self.onDeviceLabel
            }
        } else {
            reply = try await Self.onDeviceJSON(instructions: instructions, prompt: prompt, schema: Self.chunkSchema, maxTokens: 700)
            engine = Self.onDeviceLabel
        }
        guard let object = MeetingAIJSON.object(from: reply) else {
            AppLog.log("Meetings AI: unreadable notes JSON: \(reply.prefix(200))")
            throw MeetingAIError.badResponse
        }
        let sourceText = (chunk.context + chunk.lines + [userNotes]).joined(separator: "\n")
        var partial = Self.parsePartial(object, userFirst: userFirst, sourceText: sourceText)
        partial.start = chunk.start
        partial.end = chunk.end
        return (partial, engine)
    }

    /// Guided generation first; if the schema itself is the problem, plain
    /// JSON text with the outline in the prompt.
    /// On-device decoding runs at roughly 15-50 tokens/s and requests are
    /// served one at a time, so the budget is generous: this runs after the
    /// meeting, not live.
    static func onDeviceJSON(
        instructions: String, prompt: String, schema: MeetingAISchema, maxTokens: Int, budget: Double = 90
    ) async throws -> String {
        do {
            return try await MeetingAIBackend.onDevice(
                instructions: instructions, prompt: prompt, schema: schema,
                maxTokens: maxTokens, timeout: budget, permissive: true
            )
        } catch let error as MeetingAIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.log("Meetings AI: guided generation failed (\(error)), retrying as text")
            return try await MeetingAIBackend.onDevice(
                instructions: instructions + "\nJSON shape: " + schema.outline,
                prompt: prompt, schema: nil, maxTokens: maxTokens, timeout: budget, permissive: true
            )
        }
    }

    /// Groq JSON request with a short wait on rate limits.
    func groqJSON(system: String, user: String, maxTokens: Int, timeout: Double) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await MeetingAIBackend.groq(
                    config: config, system: system, user: user, json: true,
                    maxTokens: maxTokens, reasoningEffort: "medium", timeout: timeout
                )
            } catch MeetingAIError.rateLimited(let retryAfter) where attempt < 2 {
                attempt += 1
                let wait = min(20, max(2, retryAfter ?? Double(4 * attempt)))
                AppLog.log("Meetings AI: Groq rate limited, retrying in \(Int(wait)) s")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    static func parsePartial(_ object: [String: Any], userFirst: String, sourceText: String) -> PartialNotes {
        var partial = PartialNotes()
        partial.summary = MeetingAIJSON.string(object["summary"])
        partial.keyPoints = MeetingAIJSON.strings(object["keyPoints"] ?? object["key_points"], limit: 8)
        partial.decisions = MeetingAIJSON.strings(object["decisions"], limit: 8)
        partial.openQuestions = MeetingAIJSON.strings(object["openQuestions"] ?? object["open_questions"], limit: 6)
        partial.nextSteps = MeetingAIJSON.strings(object["nextSteps"] ?? object["next_steps"], limit: 6)
        let rawItems = MeetingAIJSON.objects(
            object["actionItems"] ?? object["action_items"] ?? object["tasks"]
        )
        for raw in rawItems {
            guard let task = MeetingAIJSON.string(raw["task"] ?? raw["text"] ?? raw["item"]) else { continue }
            let (owner, isMine) = resolveOwner(MeetingAIJSON.string(raw["owner"]), userFirst: userFirst, sourceText: sourceText)
            let due = verifiedDue(MeetingAIJSON.string(raw["due"] ?? raw["deadline"]), sourceText: sourceText)
            partial.actionItems.append(ActionItem(
                id: UUID(), owner: owner, task: cleanTask(task), due: due, isMine: isMine, isDone: false
            ))
        }
        return partial
    }

    // MARK: - Validation

    /// Normalizes an owner, keeping only names that occur in the transcript.
    static func resolveOwner(_ raw: String?, userFirst: String, sourceText: String) -> (String, Bool) {
        guard let raw else { return (MeetingAIText.othersLabel, false) }
        let owner = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let lowered = owner.lowercased()
        let first = userFirst.lowercased()
        let mine = Set(["me", "i", "myself", "user", "the user", "you", first, "\(first) (me)"])
        if mine.contains(lowered) { return (userFirst, true) }
        if ["team", "we", "us", "everyone", "all", "the team", "everybody", "group", "both"].contains(lowered) {
            return ("Team", false)
        }
        if ["others", "other", "participant", "a participant", "someone", "unknown", "speaker", "they", "them",
            "he", "she", "guest", "other participant", "other participants", "unassigned"].contains(lowered) {
            return (MeetingAIText.othersLabel, false)
        }
        // "Koushik and Priya", "Koushik / Ravi".
        let names = owner.components(separatedBy: CharacterSet(charactersIn: ",/&+")).flatMap {
            $0.components(separatedBy: " and ")
        }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let includesUser = names.contains { $0.lowercased() == first || $0.lowercased() == "me" }
        let known = names.filter { name in
            name.lowercased() == first || name.lowercased() == "me" || MeetingAIText.containsWord(sourceText, name)
        }
        guard !known.isEmpty else { return (MeetingAIText.othersLabel, false) }
        if known.count == 1, includesUser { return (userFirst, true) }
        let display = known.map { $0.lowercased() == "me" ? userFirst : $0 }.joined(separator: ", ")
        return (display, includesUser)
    }

    /// Keeps a due date only when its words were actually spoken.
    static func verifiedDue(_ raw: String?, sourceText: String) -> String? {
        guard let raw else { return nil }
        let generic: Set<String> = ["by", "the", "end", "of", "on", "before", "until", "next", "this", "due", "at", "in"]
        let words = MeetingAIText.words(raw).filter { !generic.contains($0) }
        guard !words.isEmpty else { return nil }
        let spoken = MeetingAIText.words(sourceText)
        let spokenSet = Set(spoken)
        let found = words.filter { spokenSet.contains($0) || spokenSet.contains($0 + "s") }.count
        return Double(found) / Double(words.count) >= 0.5 ? raw : nil
    }

    static func cleanTask(_ task: String) -> String {
        var text = MeetingAIText.cleanItem(task)
        text = text.replacingOccurrences(of: #"^(To|Will|I'll|I will|We'll|We will)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func cleanTitle(_ title: String) -> String {
        let trimmed = MeetingAIText.collapse(title)
        return trimmed.isEmpty ? "Untitled meeting" : String(trimmed.prefix(120))
    }

    // MARK: - Merge

    static func merge(_ partials: [PartialNotes], userFirst: String, transcript: String) -> MeetingNotes {
        let summaries = partials.compactMap(\.summary)
        let summary = summaries.count <= 1
            ? (summaries.first ?? "")
            : summaries.prefix(3).joined(separator: " ")
        var mine: [ActionItem] = []
        var others: [ActionItem] = []
        for item in partials.flatMap(\.actionItems) {
            if item.isMine { insert(item, into: &mine) } else { insert(item, into: &others) }
        }
        // A task the user owns shouldn't also appear under someone else.
        others.removeAll { other in mine.contains { MeetingAIText.similarity($0.task, other.task) >= 0.75 } }
        // Models sometimes file assignments under decisions as well.
        let decisions = MeetingAIText.dedupe(partials.flatMap(\.decisions)).filter { decision in
            !(mine + others).contains { MeetingAIText.similarity($0.task, decision) >= 0.6 }
        }
        return MeetingNotes(
            summary: summary.isEmpty ? "The meeting was recorded, but no summary could be written." : summary,
            keyPoints: Array(MeetingAIText.dedupe(partials.flatMap(\.keyPoints)).prefix(8)),
            decisions: Array(decisions.prefix(10)),
            myTasks: mine,
            othersTasks: others,
            openQuestions: Array(MeetingAIText.dedupe(partials.flatMap(\.openQuestions)).prefix(6)),
            nextSteps: Array(MeetingAIText.dedupe(partials.flatMap(\.nextSteps)).prefix(6)),
            generatedBy: onDeviceLabel
        )
    }

    /// Adds `item` unless a similar task with the same owner exists; the more
    /// specific one (with a due date, longer) wins.
    static func insert(_ item: ActionItem, into list: inout [ActionItem]) {
        if let index = list.firstIndex(where: { sameTask($0, item) }) {
            var existing = list[index]
            if existing.due == nil { existing.due = item.due }
            if item.task.count > existing.task.count { existing.task = item.task }
            // A named owner is more useful than "Others".
            if existing.owner == MeetingAIText.othersLabel, item.owner != MeetingAIText.othersLabel {
                existing.owner = item.owner
                existing.isMine = item.isMine
            }
            list[index] = existing
        } else {
            list.append(item)
        }
    }

    /// Same owner (or one side unnamed) and the same work: similar wording,
    /// or the same verb and at least two shared objects ("Update the privacy
    /// policy…" twice).
    static func sameTask(_ a: ActionItem, _ b: ActionItem) -> Bool {
        let others = MeetingAIText.othersLabel
        let ownersMatch = a.owner.lowercased() == b.owner.lowercased() || a.owner == others || b.owner == others
        guard ownersMatch else { return false }
        if MeetingAIText.similarity(a.task, b.task) >= 0.5 { return true }
        let verbA = MeetingAIText.words(a.task).first, verbB = MeetingAIText.words(b.task).first
        guard verbA != nil, verbA == verbB else { return false }
        let objectsA = MeetingAIText.contentWords(a.task).subtracting([verbA.map(MeetingAIText.stem) ?? ""])
        let objectsB = MeetingAIText.contentWords(b.task).subtracting([verbB.map(MeetingAIText.stem) ?? ""])
        return objectsA.intersection(objectsB).count >= 2
    }

    // MARK: - Reduce

    struct Overview: Sendable, Equatable {
        var summary: String?
        var keyPoints: [String]
        var nextSteps: [String]
    }

    static let overviewSchema = MeetingAISchema.object(name: "MeetingOverview", properties: [
        .init(name: "summary", description: "3-5 sentences: purpose, main discussion and outcome of the whole meeting",
              schema: .string),
        .init(name: "keyPoints", description: "The 4-7 most important points of the whole meeting, deduplicated, each under 15 words",
              schema: .array(.string, maxItems: 7)),
        .init(name: "nextSteps", description: "Up to 4 concrete next steps, deduplicated; empty if none",
              schema: .array(.string, maxItems: 4)),
    ])

    static let reduceInstructions = """
    You combine the notes of consecutive parts of one meeting into final minutes. Use only information in the notes; \
    do not add facts, names or dates. Write plainly and concisely. Reply with JSON only.
    """

    func reduce(
        _ partials: [PartialNotes], title: String, userFirst: String, useGroq: Bool, useOnDevice: Bool
    ) async throws -> (Overview, String) {
        let blocks = partials.enumerated().map { index, partial in
            Self.noteBlock(partial, index: index + 1)
        }
        let limit = useGroq ? Self.groqChunkChars : 5200
        // Hierarchical: condense groups of blocks until everything fits once.
        var current = blocks
        var engine = useGroq ? "Groq \(config.groqModel)" : Self.onDeviceLabel
        var rounds = 0
        while current.joined(separator: "\n\n").count > limit, current.count > 1, rounds < 3 {
            rounds += 1
            var grouped: [String] = []
            var group: [String] = []
            for block in current {
                if !group.isEmpty, (group + [block]).joined(separator: "\n\n").count > limit {
                    grouped.append(group.joined(separator: "\n\n"))
                    group = []
                }
                group.append(block)
            }
            if !group.isEmpty { grouped.append(group.joined(separator: "\n\n")) }
            var condensed: [String] = []
            for (index, text) in grouped.enumerated() {
                let (overview, used) = try await overviewRequest(notes: text, title: title, useGroq: useGroq, useOnDevice: useOnDevice)
                engine = used
                condensed.append(Self.noteBlock(PartialNotes(summary: overview.summary, keyPoints: overview.keyPoints,
                                                             nextSteps: overview.nextSteps), index: index + 1))
            }
            current = condensed
        }
        let text = String(current.joined(separator: "\n\n").prefix(limit))
        let (overview, used) = try await overviewRequest(notes: text, title: title, useGroq: useGroq, useOnDevice: useOnDevice)
        engine = used
        return (overview, engine)
    }

    private func overviewRequest(notes: String, title: String, useGroq: Bool, useOnDevice: Bool) async throws -> (Overview, String) {
        let prompt = "Meeting: \(Self.cleanTitle(title))\n<notes>\n\(notes)\n</notes>"
        var reply: String?
        var engine = Self.onDeviceLabel
        if useGroq {
            do {
                reply = try await groqJSON(
                    system: Self.reduceInstructions + "\nJSON shape: " + Self.overviewSchema.outline + "\n" + Self.overviewSchema.fieldGuide,
                    user: prompt, maxTokens: 3000, timeout: 60
                )
                engine = "Groq \(config.groqModel)"
            } catch let error where useOnDevice && !(error is CancellationError) {
                AppLog.log("Meetings AI: Groq reduce failed (\(error.localizedDescription)), trying on-device")
            }
        }
        if reply == nil {
            guard useOnDevice else { throw MeetingAIError.badResponse }
            reply = try await Self.onDeviceJSON(
                instructions: Self.reduceInstructions, prompt: String(prompt.prefix(5600)),
                schema: Self.overviewSchema, maxTokens: 500, budget: 60
            )
        }
        guard let reply, let object = MeetingAIJSON.object(from: reply) else { throw MeetingAIError.badResponse }
        let overview = Overview(
            summary: MeetingAIJSON.string(object["summary"]),
            keyPoints: MeetingAIJSON.strings(object["keyPoints"] ?? object["key_points"], limit: 8),
            nextSteps: MeetingAIJSON.strings(object["nextSteps"] ?? object["next_steps"], limit: 5)
        )
        return (overview, engine)
    }

    static func noteBlock(_ partial: PartialNotes, index: Int) -> String {
        var lines = ["Part \(index):"]
        if let summary = partial.summary { lines.append("Summary: \(summary)") }
        if !partial.keyPoints.isEmpty { lines.append("Points: " + partial.keyPoints.joined(separator: " | ")) }
        if !partial.decisions.isEmpty { lines.append("Decisions: " + partial.decisions.joined(separator: " | ")) }
        if !partial.actionItems.isEmpty {
            lines.append("Tasks: " + partial.actionItems.map { item in
                "\(item.owner): \(item.task)" + (item.due.map { " (\($0))" } ?? "")
            }.joined(separator: " | "))
        }
        if !partial.nextSteps.isEmpty { lines.append("Next: " + partial.nextSteps.joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }

    static func nextSteps(from notes: MeetingNotes) -> [String] {
        (notes.myTasks + notes.othersTasks).prefix(5).map { item in
            "\(item.owner): \(item.task)" + (item.due.map { " (\($0))" } ?? "")
        }
    }

    // MARK: - High-precision rules for the user's tasks

    /// Adds the user's tasks that clear rules find but the model missed.
    static func addMissedTasks(to notes: inout MeetingNotes, turns: [MeetingAIText.Turn], userFirst: String) {
        let found = RuleExtractor(userFirst: userFirst).tasks(in: turns).filter { $0.item.isMine && $0.confidence >= 0.8 }
        let all = notes.myTasks + notes.othersTasks
        for candidate in found {
            if let index = notes.myTasks.firstIndex(where: { MeetingAIText.similarity($0.task, candidate.item.task) >= 0.45 }) {
                // The model kept the task but dropped its spoken deadline.
                if notes.myTasks[index].due == nil { notes.myTasks[index].due = candidate.item.due }
                continue
            }
            guard !all.contains(where: { MeetingAIText.similarity($0.task, candidate.item.task) >= 0.45 }) else { continue }
            insert(candidate.item, into: &notes.myTasks)
        }
        // Someone named committing ("Ravi will schedule a follow-up…").
        let named = RuleExtractor(userFirst: userFirst).tasks(in: turns).filter { candidate in
            !candidate.item.isMine && candidate.confidence >= 0.7
                && ![MeetingAIText.othersLabel, "Team"].contains(candidate.item.owner)
        }
        for candidate in named {
            // The model kept the task but lost the spoken name.
            if let index = notes.othersTasks.firstIndex(where: {
                $0.owner == MeetingAIText.othersLabel && MeetingAIText.similarity($0.task, candidate.item.task) >= 0.6
            }) {
                notes.othersTasks[index].owner = candidate.item.owner
                if notes.othersTasks[index].due == nil { notes.othersTasks[index].due = candidate.item.due }
                continue
            }
            let existing = notes.myTasks + notes.othersTasks
            guard !existing.contains(where: { MeetingAIText.similarity($0.task, candidate.item.task) >= 0.45 }) else { continue }
            insert(candidate.item, into: &notes.othersTasks)
        }
    }

    /// Typed notes: trimmed, blank lines dropped, at most 60 lines.
    static func cleanUserNotes(_ text: String?) -> String {
        guard let text else { return "" }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(60)
            .joined(separator: "\n")
    }

    /// To-dos the user wrote in their own notes ("todo: send the deck",
    /// "[ ] book the room", "- action: call Ravi") become their tasks.
    static func addUserNoteTasks(to notes: inout MeetingNotes, userNotes: String, userFirst: String) {
        let pattern = #"^(?:[-*•]\s*)?(?:\[\s?\]\s*|(?:todo|to-do|to do|action|action item|ai|follow[- ]up)\s*[:\-]\s*)(.+)$"#
        for line in userNotes.components(separatedBy: .newlines) {
            guard let match = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            var text = String(line[match])
            text = text.replacingOccurrences(of: pattern, with: "$1", options: [.regularExpression, .caseInsensitive])
            let task = cleanTask(text)
            guard MeetingAIText.words(task).count >= 2 else { continue }
            let all = notes.myTasks + notes.othersTasks
            guard !all.contains(where: { MeetingAIText.similarity($0.task, task) >= 0.6 }) else { continue }
            let due = RuleExtractor(userFirst: userFirst).due(in: task)
            insert(ActionItem(id: UUID(), owner: userFirst, task: task, due: due, isMine: true, isDone: false),
                   into: &notes.myTasks)
        }
    }

    // MARK: - Deterministic fallback

    static func deterministicNotes(turns: [MeetingAIText.Turn], userFirst: String) -> MeetingNotes {
        let extractor = RuleExtractor(userFirst: userFirst)
        let tasks = extractor.tasks(in: turns)
        var mine: [ActionItem] = []
        var others: [ActionItem] = []
        for task in tasks { task.item.isMine ? insert(task.item, into: &mine) : insert(task.item, into: &others) }
        var notes = MeetingNotes(
            summary: extractor.summary(turns: turns),
            keyPoints: extractor.keyPoints(turns: turns),
            decisions: extractor.decisions(turns: turns),
            myTasks: mine,
            othersTasks: others,
            openQuestions: extractor.openQuestions(turns: turns),
            nextSteps: [],
            generatedBy: fallbackLabel
        )
        notes.nextSteps = nextSteps(from: notes)
        return notes
    }

    static func deterministicPartial(chunk: MeetingAIText.Chunk, userFirst: String) -> PartialNotes {
        let turns = chunk.lines.compactMap { RuleExtractor.parseLine($0, userFirst: userFirst) }
        let notes = deterministicNotes(turns: turns, userFirst: userFirst)
        return PartialNotes(
            summary: notes.summary, keyPoints: notes.keyPoints, decisions: notes.decisions,
            actionItems: notes.myTasks + notes.othersTasks, openQuestions: notes.openQuestions,
            nextSteps: [], start: chunk.start, end: chunk.end
        )
    }
}

/// Rule-based extraction used when no model is available and to catch the
/// user's tasks a model missed.
struct RuleExtractor: Sendable {
    let userFirst: String

    struct Candidate: Sendable {
        var item: ActionItem
        var confidence: Double
    }

    static let actionVerbs: Set<String> = [
        "send", "share", "follow", "check", "review", "update", "fix", "write", "prepare", "schedule", "set", "create",
        "look", "draft", "email", "call", "reach", "finish", "deploy", "test", "merge", "push", "ping", "talk", "sync",
        "book", "file", "add", "build", "investigate", "handle", "take", "put", "circle", "document", "upload",
        "compile", "organize", "coordinate", "confirm", "submit", "complete", "deliver", "present", "ship", "migrate",
        "refactor", "implement", "design", "research", "find", "get", "move", "clean", "own", "lead", "run",
        "loop", "notify", "invite", "order", "pay", "sign", "approve", "close", "open", "start", "fill",
    ]

    static let notTasks = [
        "share my screen", "share the screen", "share screen", "stop sharing", "be quick", "keep it short",
        "go first", "let you", "pass it", "hand it over", "hand over", "repeat", "mute", "unmute", "hear you",
        "see you", "talk to you", "be right back", "drop off", "jump off", "stop here", "wrap up",
    ]

    static let dueRegex = #"\b(?:(?:by|before|on|until|due|for|this|next)\s+)?(?:today|tonight|tomorrow|eod|eow|end of (?:the )?(?:day|week|month|quarter|sprint)|next (?:week|month|sprint|quarter|meeting|call)|this (?:week|month|sprint|afternoon|evening)|(?:mon|tues|wednes|thurs|fri|satur|sun)day|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?::\d{2})? ?(?:am|pm)|(?:over |this |next )?(?:the )?weekend|in (?:a|one|two|three|\d+) (?:days?|weeks?|hours?))\b"#

    static func parseLine(_ line: String, userFirst: String) -> MeetingAIText.Turn? {
        // "[mm:ss] Speaker: text"
        guard let close = line.firstIndex(of: "]"),
              let colon = line[close...].firstIndex(of: ":") else { return nil }
        let speaker = line[line.index(after: close)..<colon].trimmingCharacters(in: .whitespaces)
        let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return MeetingAIText.Turn(speaker: speaker == userFirst ? .me : .others, start: 0, end: 0, text: text)
    }

    func due(in text: String) -> String? {
        guard let range = text.range(of: Self.dueRegex, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }

    /// Task text from the verb on: "I'll send the deck by Friday" -> "Send the deck by Friday".
    func taskText(_ text: String) -> String {
        var task = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        task = task.replacingOccurrences(of: #"^(?:sure|yes|yeah|okay|ok|absolutely|definitely|alright|right)[,.!]?\s+"#,
                                         with: "", options: [.regularExpression, .caseInsensitive])
        task = task.replacingOccurrences(
            of: #"^.*?\b(?:i'll|i will|i'm going to|i am going to|i can|i need to|i have to|we'll|we will|we need to|we should|let's|can you|could you|would you|will you|please)\s+"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        task = task.replacingOccurrences(of: #"^(?:also|just|quickly|go ahead and|then)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return MeetingSummarizer.cleanTask(task)
    }

    private func firstWord(_ text: String) -> String {
        MeetingAIText.words(text).first ?? ""
    }

    private func isTaskLike(_ task: String) -> Bool {
        let lowered = task.lowercased()
        guard Self.actionVerbs.contains(firstWord(task)), MeetingAIText.words(task).count >= 3 else { return false }
        return !Self.notTasks.contains { lowered.contains($0) }
    }

    func tasks(in turns: [MeetingAIText.Turn]) -> [Candidate] {
        var result: [Candidate] = []
        let name = NSRegularExpression.escapedPattern(for: userFirst)
        for (index, turn) in turns.enumerated() {
            for sentence in MeetingAIText.sentences(turn.text) {
                let lowered = sentence.lowercased()
                let sentenceDue = due(in: sentence)
                if turn.speaker == .me {
                    // "I'll send the deck by Friday."
                    guard lowered.range(of: #"\b(i'll|i will|i'm going to|i am going to|i can take|i'll take)\b"#, options: .regularExpression) != nil else {
                        if lowered.range(of: #"\b(we need to|we should|let's)\b"#, options: .regularExpression) != nil {
                            let task = taskText(sentence)
                            if isTaskLike(task) {
                                result.append(Candidate(item: item("Team", task, due(in: task), mine: false), confidence: 0.5))
                            }
                        }
                        continue
                    }
                    let task = taskText(sentence)
                    guard isTaskLike(task) else { continue }
                    let spokenDue = due(in: task)
                    let confidence = spokenDue != nil || MeetingAIText.words(task).count >= 5 ? 0.85 : 0.6
                    result.append(Candidate(item: item(userFirst, task, spokenDue, mine: true), confidence: confidence))
                } else {
                    // "Ravi, can you review the fix?": someone else's task.
                    if let match = sentence.range(of: #"^(?:(?:okay|so|and|great|thanks)[,]?\s+)?([A-Z][a-z]+),?\s+(?:can|could|would|will) you\s+"#, options: .regularExpression),
                       let owner = sentence[match].components(separatedBy: CharacterSet(charactersIn: ", ")).first(where: { $0.first?.isUppercase == true && !["Okay", "So", "And", "Great", "Thanks"].contains($0) }),
                       owner.lowercased() != userFirst.lowercased() {
                        let task = MeetingSummarizer.cleanTask(String(sentence[match.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "?. ")))
                        if isTaskLike(task) {
                            result.append(Candidate(item: item(owner, task, due(in: task), mine: false), confidence: 0.75))
                        }
                        continue
                    }
                    let spokenDue = sentenceDue
                    // "Koushik, can you send the deck?" (+ an OK from the user)
                    if sentence.range(of: "\\b\(name)\\b[,]?\\s+(can|could|would|will) you\\b", options: [.regularExpression, .caseInsensitive]) != nil
                        || sentence.range(of: "\\b(can|could|would|will) you\\b[^,]*,\\s*\(name)\\W*$", options: [.regularExpression, .caseInsensitive]) != nil
                        || sentence.range(of: "\\b\(name)\\b,?\\s+(please|will|should|needs to|is going to)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                        var task = taskText(sentence.replacingOccurrences(of: "\\b\(name)\\b,?\\s*", with: "", options: [.regularExpression, .caseInsensitive]))
                        task = task.replacingOccurrences(of: #"^(?:please|will|should|needs to|is going to)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
                        task = MeetingSummarizer.cleanTask(task)
                        guard isTaskLike(task) else { continue }
                        let accepted = userAgrees(after: index, in: turns)
                        let due = spokenDue ?? (accepted.flatMap { due(in: $0) })
                        result.append(Candidate(item: item(userFirst, task, due, mine: true), confidence: accepted != nil ? 0.95 : 0.8))
                        continue
                    }
                    // "Can you send the deck?" + "Sure, I'll do it today."
                    if lowered.range(of: #"\b(can|could|would|will) you\b"#, options: .regularExpression) != nil,
                       let reply = userAgrees(after: index, in: turns) {
                        let task = taskText(sentence)
                        guard isTaskLike(task) else { continue }
                        result.append(Candidate(item: item(userFirst, task, spokenDue ?? due(in: reply), mine: true), confidence: 0.85))
                        continue
                    }
                    // "Priya will update the doc." / "I'll send the invite."
                    if let match = sentence.range(of: #"\b([A-Z][a-z]+)\s+(?:will|is going to|needs to|should|can)\s+"#, options: .regularExpression) {
                        let owner = String(sentence[match]).components(separatedBy: " ").first ?? ""
                        let excluded: Set<String> = ["We", "It", "This", "That", "They", "He", "She", "Everyone", "Someone",
                                                     "There", "What", "Who", "Which", "And", "But", "So", "Then", "You", "I"]
                        if !excluded.contains(owner), owner.lowercased() != userFirst.lowercased() {
                            let task = MeetingSummarizer.cleanTask(String(sentence[match.upperBound...]))
                            if isTaskLike(task) {
                                result.append(Candidate(item: item(owner, task, spokenDue, mine: false), confidence: 0.7))
                                continue
                            }
                        }
                    }
                    if lowered.range(of: #"\b(i'll|i will|i'm going to|i am going to)\b"#, options: .regularExpression) != nil {
                        let task = taskText(sentence)
                        if isTaskLike(task) {
                            result.append(Candidate(item: item(MeetingAIText.othersLabel, task, spokenDue, mine: false), confidence: 0.6))
                        }
                    } else if lowered.range(of: #"\b(we need to|we should|let's)\b"#, options: .regularExpression) != nil {
                        let task = taskText(sentence)
                        if isTaskLike(task) {
                            result.append(Candidate(item: item("Team", task, spokenDue, mine: false), confidence: 0.5))
                        }
                    }
                }
            }
        }
        return result
    }

    /// The user's reply right after `index` when it accepts a request.
    private func userAgrees(after index: Int, in turns: [MeetingAIText.Turn]) -> String? {
        guard index + 1 < turns.count else { return nil }
        let next = turns[index + 1]
        guard next.speaker == .me else { return nil }
        let lowered = next.text.lowercased()
        let accepts = lowered.range(
            of: #"^\W*(sure|yes|yeah|yep|ok|okay|absolutely|definitely|of course|will do|no problem|got it|sounds good|i can|i'll|i will|on it)\b"#,
            options: .regularExpression
        ) != nil
        return accepts ? next.text : nil
    }

    private func item(_ owner: String, _ task: String, _ due: String?, mine: Bool) -> ActionItem {
        ActionItem(id: UUID(), owner: owner, task: task, due: due, isMine: mine, isDone: false)
    }

    // MARK: Extractive summary

    private struct Scored {
        var sentence: String
        var order: Int
        var score: Double
    }

    private func scoredSentences(_ turns: [MeetingAIText.Turn]) -> [Scored] {
        var sentences: [(String, Int)] = []
        for turn in turns {
            for sentence in MeetingAIText.sentences(turn.text) where !sentence.hasSuffix("?") {
                let count = MeetingAIText.words(sentence).count
                if count >= 6, count <= 45 { sentences.append((sentence, sentences.count)) }
            }
        }
        var frequency: [String: Int] = [:]
        for (sentence, _) in sentences {
            for word in MeetingAIText.contentWords(sentence) where word.count > 2 { frequency[word, default: 0] += 1 }
        }
        let fillers = ["um", "uh", "you know", "i mean", "kind of", "sort of", "like,"]
        return sentences.map { sentence, order in
            let words = MeetingAIText.contentWords(sentence).filter { $0.count > 2 }
            var score = words.reduce(0.0) { $0 + log(1 + Double(frequency[$1] ?? 0)) } / sqrt(Double(max(words.count, 1)))
            let lowered = sentence.lowercased()
            if fillers.contains(where: { lowered.contains($0) }) { score *= 0.8 }
            if lowered.range(of: #"\b(decid|agree|plan|goal|launch|deadline|priority|issue|problem|update|release)"#, options: .regularExpression) != nil {
                score *= 1.25
            }
            return Scored(sentence: MeetingAIText.cleanItem(sentence), order: order, score: score)
        }
    }

    func summary(turns: [MeetingAIText.Turn]) -> String {
        let scored = scoredSentences(turns)
        // The agenda, when someone states it near the start.
        let agenda = scored.prefix(8).first {
            $0.sentence.range(of: #"\b(today|agenda|go over|discuss|talk about|sync|catch up on)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        var top = Array(scored.sorted { $0.score > $1.score }.filter { $0.order != agenda?.order }.prefix(agenda == nil ? 3 : 2))
        if let agenda { top.append(agenda) }
        top.sort { $0.order < $1.order }
        guard !top.isEmpty else {
            let words = turns.map(\.text).joined(separator: " ")
            return words.isEmpty ? "No speech was captured in this meeting." : MeetingAIText.cleanItem(String(words.prefix(300)))
        }
        return top.map(\.sentence).joined(separator: " ")
    }

    func keyPoints(turns: [MeetingAIText.Turn]) -> [String] {
        let ranked = scoredSentences(turns).sorted { $0.score > $1.score }
        let summarySet = Set(ranked.prefix(3).map(\.sentence))
        let points = ranked.dropFirst(3).prefix(10).sorted { $0.order < $1.order }.map(\.sentence)
            .filter { !summarySet.contains($0) }
        return Array(MeetingAIText.dedupe(points).prefix(6))
    }

    func decisions(turns: [MeetingAIText.Turn]) -> [String] {
        let pattern = #"\b(we decided|we've decided|decided to|let's go with|we'll go with|we're going with|we agreed|agreed to|the decision is|final decision|we will go ahead|go ahead with|we're going to go)\b"#
        let found = turns.flatMap { MeetingAIText.sentences($0.text) }
            .filter { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
            .map(MeetingAIText.cleanItem)
        return Array(MeetingAIText.dedupe(found).prefix(6))
    }

    func openQuestions(turns: [MeetingAIText.Turn]) -> [String] {
        let smallTalk = ["how are you", "can you hear", "can you see", "are you there", "is that clear", "make sense",
                         "you know?", "right?", "okay?", "how's it going", "what's up", "everyone hear", "everyone see",
                         "is everyone here", "everyone okay with", "anything else", "any other questions"]
        let deferral = #"\b(not sure|don't know|do not know|check|get back|follow up|find out|let's not decide|later)\b"#
        var asked: [String] = []
        for (index, turn) in turns.enumerated() {
            // Answered right away by the user ("Koushik, what's the status?" + a real answer).
            let reply = index + 1 < turns.count && turns[index + 1].speaker == .me && turn.speaker == .others
                ? turns[index + 1].text : nil
            let answered = reply.map { MeetingAIText.words($0).count >= 8
                && $0.range(of: deferral, options: [.regularExpression, .caseInsensitive]) == nil } ?? false
            let sentences = MeetingAIText.sentences(turn.text)
            for (position, sentence) in sentences.enumerated() {
                if answered, position == sentences.count - 1 { continue }
                asked.append(sentence)
            }
        }
        let found = asked
            .filter { $0.hasSuffix("?") && MeetingAIText.words($0).count >= 5 }
            .filter { $0.range(of: #"^(?:\w+,\s*)?(?:can|could|would|will) you\b"#, options: [.regularExpression, .caseInsensitive]) == nil }
            .filter { sentence in !smallTalk.contains { sentence.lowercased().contains($0) } }
            .map(MeetingAIText.cleanItem)
        return Array(MeetingAIText.dedupe(found).suffix(5))
    }
}
