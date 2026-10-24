import AppKit
import Combine
import SwiftUI

// Meeting Intelligence (B): live help while a session records.
// See DESIGN.md §5.
//
// - Flags action items and decisions from the live transcript: phrase rules
//   first (instant), then an optional on-device model pass every ~20 s that
//   cleans the wording and owner (never Groq here).
// - Records MeetingAssistant's own detected questions (liveAnswer) on the
//   timeline as `.question` flags; the answer card stays the assistant's.
// - Talk-time meter (1 Hz) and one gentle nudge on a long monologue.
// - Bookmark this moment.
// - Caption band (original language) when the plan asks for captions without
//   translation; translation draws its own band through
//   LiveTranslationController, so B never duplicates it.
//
// Privacy: nothing here records, sends or writes to another app. Every band
// B shows while capturing carries the red MeetingIntelLiveBadge dot, the REC
// wings (priority 65) are only ever covered by the ≤3 s flag toast (66), and
// the model pass runs on this Mac through MeetingAIBackend.onDevice.
//
// Additions beyond DESIGN.md's contract (all in this file, nothing changed in
// MeetingIntelModels.swift):
// - `LiveMeetingAssist.refiner`, `.clock`: test seams (model pass, time).
// - `LiveMeetingAssist.lastToast`, `.lastNudgeStats`: what was last shown.
// - `MeetingFlagDetector.affirmsPrevious(_:)`: "Agreed." / "Ship it." turns
//   the previous line into a decision.
// - `MeetingFlag.ownerLabel`, `MeetingIntelClock.text(_:)`: display helpers.

// MARK: - Caption line

struct MeetingCaptionLine: Identifiable, Equatable, Sendable {
    /// Segment id.
    let id: UUID
    var speaker: MeetingSpeaker
    var text: String
    var isFinal: Bool
    /// Seconds since recording started.
    var at: TimeInterval
}

// MARK: - Live assist

@MainActor
final class LiveMeetingAssist: ObservableObject, MeetingLiveAssisting {
    /// Set by the app (INTEGRATION.md step 6) so the notes window can show the
    /// live flags (step 10) without a new environment object.
    static weak var current: LiveMeetingAssist?

    @Published private(set) var session: MeetingIntelSession?
    /// Every flag of this session in the order found (dismissed ones kept
    /// with `isDismissed`, so they are never re-flagged).
    @Published private(set) var flags: [MeetingFlag] = []
    @Published private(set) var talk: MeetingTalkStats = .zero
    /// The newest ~6 transcript lines (volatile ones included).
    @Published private(set) var captionLines: [MeetingCaptionLine] = []
    /// The caption band is posted while this is on (and a session is live).
    @Published var captionsVisible = false {
        didSet { if captionsVisible != oldValue { refreshCaptionBand() } }
    }
    /// The flag shown in the last toast.
    @Published private(set) var lastToast: MeetingFlag?
    /// The stats the last nudge was shown with.
    @Published private(set) var lastNudgeStats: MeetingTalkStats?

    /// Model pass over rule flags. nil turns it off (tests). The default runs
    /// the on-device model only, and returns its input when unavailable.
    var refiner: (@Sendable ([MeetingFlag], [TranscriptSegment], String) async -> [MeetingFlag])? = { candidates, context, user in
        await MeetingFlagDetector.refine(candidates, context: context, userName: user)
    }
    /// Wall clock (rate limits). Segment times are recording-relative.
    var clock: () -> Date = { Date() }

    static let captionLineCount = 6
    static let toastInterval: TimeInterval = 20
    static let toastDuration: TimeInterval = 3
    static let nudgeInterval: TimeInterval = 300
    static let nudgeDuration: TimeInterval = 6
    static let refineInterval: TimeInterval = 20
    static let dedupeWindow: TimeInterval = 90
    static let persistDelay: TimeInterval = 2

    let prefs: MeetingIntelPreferences
    private let activities: ActivityCenter
    private weak var assistant: MeetingAssistant?
    private let store: MeetingIntelSidecarStore
    private let userName: String

    private var segments: [TranscriptSegment] = []
    private var processedFinal: Set<UUID> = []
    private var recordedAnswers: Set<UUID> = []
    private var lastToastAt: Date?
    private var lastNudgeAt: Date?
    private var lastTalkAt: Date?
    private var lastRefineAt: Date?
    private var pendingRefine: [UUID] = []
    private var talkTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var subscriptions: [AnyCancellable] = []

    init(activities: ActivityCenter,
         assistant: MeetingAssistant?,
         prefs: MeetingIntelPreferences? = nil,
         store: MeetingIntelSidecarStore = .shared,
         userName: String = MeetingAssistant.userName) {
        self.activities = activities
        self.assistant = assistant
        // Optional so the default is read on the main actor (Swift 5 warns
        // about a main-actor default argument otherwise).
        self.prefs = prefs ?? .shared
        self.store = store
        self.userName = userName
    }

    var userFirst: String { MeetingAIText.firstName(userName) }
    /// Flags the user hasn't dismissed, in time order.
    var visibleFlags: [MeetingFlag] { flags.filter { !$0.isDismissed }.sorted { $0.at < $1.at } }
    var showsTalkMeter: Bool { prefs.talkMeter }

    // MARK: MeetingLiveAssisting

    func begin(_ session: MeetingIntelSession) {
        stopTimersAndSubscriptions()
        self.session = session
        flags = []
        talk = .zero
        captionLines = []
        segments = []
        processedFinal = []
        recordedAnswers = []
        lastToastAt = nil
        lastNudgeAt = nil
        lastTalkAt = nil
        lastRefineAt = nil
        pendingRefine = []
        lastToast = nil
        lastNudgeStats = nil

        let id = session.id, service = session.serviceName, kind = session.kind, plan = session.plan
        let store = store
        Task { await store.update(id) { $0.serviceName = service; $0.kind = kind; $0.plan = plan } }

        if let assistant {
            subscriptions.append(assistant.$current.sink { [weak self] record in
                MainActor.assumeIsolated { self?.receive(record) }
            })
            subscriptions.append(assistant.$liveAnswer.sink { [weak self] answer in
                MainActor.assumeIsolated { self?.receive(answer) }
            })
        }
        let wantsCaptions = session.plan.captions && !session.plan.translate
        if captionsVisible == wantsCaptions { refreshCaptionBand() } else { captionsVisible = wantsCaptions }
        AppLog.log("MeetingIntel: live assist on for \(session.serviceName) (captions \(wantsCaptions ? "on" : "off"))")
    }

    func update(plan: MeetingStartPlan) {
        guard session != nil else { return }
        session?.plan = plan
        captionsVisible = plan.captions && !plan.translate
        if let id = session?.id {
            let store = store
            Task { await store.update(id) { $0.plan = plan } }
        }
    }

    func bookmarkNow(note: String?) {
        guard let session else { return }
        let at = segments.map(\.end).max() ?? max(0, clock().timeIntervalSince(session.startedAt))
        let latest = segments.last(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        let context = latest.flatMap { MeetingAIText.sentences($0.text).last }.map { MeetingFlagDetector.clip($0, to: 100) }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let flag = MeetingFlag(
            id: UUID(), kind: .bookmark,
            text: context ?? "Moment at \(MeetingIntelClock.text(at))",
            owner: nil, due: nil, isMine: false, at: at,
            segmentID: latest?.id, speaker: latest?.speaker, origin: .user,
            note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote
        )
        flags.append(flag)
        showToast(flag, force: true)
        schedulePersist()
    }

    func end() async -> MeetingIntelSidecar? {
        guard let session else { return nil }
        // Recording just stopped: the last lines are often still volatile
        // (MeetingAssistant finalizes them only after the recorder stops), and
        // goodbyes are where "I'll send the deck" gets said. Read them as
        // final once, without a toast.
        if prefs.flagging {
            let closing = segments.map { segment -> TranscriptSegment in
                var segment = segment
                segment.isFinal = true
                return segment
            }
            detectFlags(in: closing, at: clock(), announce: false)
        }
        stopTimersAndSubscriptions()
        talk = MeetingTalkTime.compute(segments, monologueThreshold: prefs.monologueSeconds)
        activities.dismiss(id: MeetingIntelActivity.flag)
        activities.dismiss(id: MeetingIntelActivity.nudge)
        let flags = flags, talk = talk, plan = session.plan, kind = session.kind, service = session.serviceName
        self.session = nil
        captionsVisible = false
        activities.dismiss(id: MeetingIntelActivity.captions)
        let sidecar = await store.update(session.id) {
            $0.flags = flags
            $0.talk = talk
            $0.plan = plan
            $0.kind = kind
            $0.serviceName = service
        }
        AppLog.log("MeetingIntel: live assist ended: \(flags.filter { !$0.isDismissed }.count) flags")
        return sidecar
    }

    // MARK: Editing flags

    func dismiss(flagID: UUID) {
        guard let index = flags.firstIndex(where: { $0.id == flagID }) else { return }
        flags[index].isDismissed = true
        if lastToast?.id == flagID { activities.dismiss(id: MeetingIntelActivity.flag) }
        schedulePersist()
    }

    /// Flag a transcript line by hand (or restore one that was dismissed).
    func flag(segmentID: UUID, as kind: MeetingFlagKind) {
        guard session != nil, let segment = segments.first(where: { $0.id == segmentID }) else { return }
        if let index = flags.firstIndex(where: { $0.segmentID == segmentID && $0.kind == kind }) {
            flags[index].isDismissed = false
            flags[index].origin = .user
        } else {
            let text = MeetingFlagDetector.clip(MeetingAIText.cleanItem(segment.text), to: 140)
            let mine = kind == .actionItem && segment.speaker == .me
            flags.append(MeetingFlag(
                id: UUID(), kind: kind, text: text,
                owner: mine ? userFirst : nil,
                due: kind == .actionItem ? MeetingFlagDetector.dueText(in: segment.text) : nil,
                isMine: mine, at: segment.start, segmentID: segment.id,
                speaker: segment.speaker, origin: .user
            ))
        }
        schedulePersist()
    }

    func setNote(_ note: String, flagID: UUID) {
        guard let index = flags.firstIndex(where: { $0.id == flagID }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        flags[index].note = trimmed.isEmpty ? nil : trimmed
        schedulePersist()
    }

    // MARK: Transcript

    /// Test seam (and the live path): a transcript snapshot at `now`.
    func ingest(_ segments: [TranscriptSegment], at now: Date) {
        guard session != nil else { return }
        let latest = MeetingAIText.latestSegments(segments)
        self.segments = latest

        let lines = latest.suffix(Self.captionLineCount).map {
            MeetingCaptionLine(id: $0.id, speaker: $0.speaker, text: MeetingAIText.collapse($0.text),
                               isFinal: $0.isFinal, at: $0.start)
        }
        if lines != captionLines { captionLines = Array(lines) }

        if prefs.flagging { detectFlags(in: latest, at: now) }
        updateTalk(at: now)
    }

    private func receive(_ record: MeetingRecord?) {
        guard let record, let session, record.id == session.id else { return }
        ingest(record.segments, at: clock())
    }

    private func receive(_ answer: SuggestedAnswer?) {
        guard let answer, session != nil, !recordedAnswers.contains(answer.id) else { return }
        recordedAnswers.insert(answer.id)
        let flag = MeetingFlag(
            id: UUID(), kind: .question,
            text: MeetingFlagDetector.clip(MeetingAIText.cleanItem(answer.question), to: 140),
            owner: userFirst, due: nil, isMine: true, at: answer.askedAt,
            segmentID: nil, speaker: .others, origin: .assistant
        )
        guard !isDuplicate(flag) else { return }
        flags.append(flag)
        schedulePersist()
    }

    private func detectFlags(in latest: [TranscriptSegment], at now: Date, announce: Bool = true) {
        var found: [MeetingFlag] = []
        for (index, segment) in latest.enumerated() where segment.isFinal && !processedFinal.contains(segment.id) {
            processedFinal.insert(segment.id)
            var candidates = MeetingFlagDetector.flags(in: segment, userName: userName)
            if candidates.isEmpty, MeetingFlagDetector.affirmsPrevious(segment.text),
               let previous = latest[..<index].last(where: { $0.isFinal && $0.speaker != segment.speaker }),
               let sentence = MeetingAIText.sentences(previous.text).last,
               MeetingAIText.words(sentence).count >= 4 {
                candidates = [MeetingFlag(
                    id: UUID(), kind: .decision,
                    text: MeetingFlagDetector.clip(MeetingFlagDetector.statement(sentence), to: 140),
                    owner: nil, due: MeetingFlagDetector.dueText(in: sentence), isMine: false,
                    at: segment.start, segmentID: segment.id, speaker: segment.speaker, origin: .rule
                )]
            }
            for candidate in candidates where !isDuplicate(candidate) && !isDuplicate(candidate, in: found) {
                found.append(candidate)
            }
        }
        guard !found.isEmpty else { return }
        flags.append(contentsOf: found)
        // Mine first: that's the toast worth seeing.
        if announce, let pick = found.last(where: \.isMine) ?? found.last { showToast(pick, force: false, now: now) }
        pendingRefine.append(contentsOf: found.map(\.id))
        scheduleRefine(now: now)
        schedulePersist()
    }

    private func isDuplicate(_ flag: MeetingFlag, in list: [MeetingFlag]? = nil) -> Bool {
        let key = MeetingFlagDetector.normalizedKey(flag.text)
        return (list ?? flags).contains { other in
            other.kind == flag.kind
                && abs(other.at - flag.at) <= Self.dedupeWindow
                && (MeetingFlagDetector.normalizedKey(other.text) == key
                    || MeetingAIText.similarity(other.text, flag.text) >= 0.75)
        }
    }

    // MARK: Talk time and nudge

    private func updateTalk(at now: Date) {
        if let last = lastTalkAt, now.timeIntervalSince(last) < 1 {
            guard talkTask == nil else { return }
            let wait = 1 - now.timeIntervalSince(last)
            talkTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.talkTask = nil
                self.computeTalk(at: self.clock())
            }
            return
        }
        computeTalk(at: now)
    }

    private func computeTalk(at now: Date) {
        lastTalkAt = now
        let stats = MeetingTalkTime.compute(segments, monologueThreshold: prefs.monologueSeconds)
        if stats != talk { talk = stats }
        checkNudge(at: now)
    }

    private func checkNudge(at now: Date) {
        guard prefs.monologueNudge, session != nil,
              talk.currentMonologue >= prefs.monologueSeconds,
              // Never while someone else is talking: the newest line must be mine.
              segments.max(by: { $0.end < $1.end })?.speaker == .me else { return }
        if let last = lastNudgeAt, now.timeIntervalSince(last) < Self.nudgeInterval { return }
        lastNudgeAt = now
        lastNudgeStats = talk
        let stats = talk
        activities.post(LiveActivity(
            id: MeetingIntelActivity.nudge, kind: .meeting, priority: MeetingIntelActivity.nudgePriority,
            duration: Self.nudgeDuration, height: 48, presentation: .expanded,
            symbol: "person.wave.2", tint: SparkVTheme.accent
        ) {
            MeetingNudgeBand(stats: stats)
        })
    }

    // MARK: Bands

    private func showToast(_ flag: MeetingFlag, force: Bool, now: Date? = nil) {
        let now = now ?? clock()
        if !force, let last = lastToastAt, now.timeIntervalSince(last) < Self.toastInterval { return }
        lastToastAt = now
        lastToast = flag
        activities.post(LiveActivity(
            id: MeetingIntelActivity.flag, kind: .meeting, priority: MeetingIntelActivity.flagPriority,
            duration: Self.toastDuration, height: 30, presentation: .expanded,
            symbol: flag.kind.symbol, tint: flag.kind.tint
        ) { [weak self] in
            MeetingFlagToast(flag: flag) { self?.dismiss(flagID: flag.id) }
        })
    }

    private func refreshCaptionBand() {
        guard captionsVisible, session != nil else {
            activities.dismiss(id: MeetingIntelActivity.captions)
            return
        }
        activities.post(LiveActivity(
            id: MeetingIntelActivity.captions, kind: .meeting, priority: MeetingIntelActivity.captionsPriority,
            duration: nil, height: 48, presentation: .expanded,
            symbol: "captions.bubble", tint: SparkVTheme.recording
        ) {
            MeetingCaptionBand(assist: self)
        })
    }

    // MARK: Model pass and persistence

    private func scheduleRefine(now: Date) {
        guard refiner != nil, refineTask == nil, !pendingRefine.isEmpty else { return }
        let since = lastRefineAt.map { now.timeIntervalSince($0) } ?? Self.refineInterval
        let wait = max(0, Self.refineInterval - since)
        refineTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            await self.runRefine()
        }
    }

    /// Runs the model pass on pending rule flags now (also used by tests).
    func runRefine() async {
        defer {
            refineTask = nil
            lastRefineAt = clock()
            if !pendingRefine.isEmpty, session != nil { scheduleRefine(now: clock()) }
        }
        let ids = Set(pendingRefine)
        pendingRefine = []
        let candidates = flags.filter { ids.contains($0.id) && !$0.isDismissed && $0.origin == .rule }
        guard let refiner, !candidates.isEmpty else { return }
        let context = Array(segments.filter(\.isFinal).suffix(12))
        let refined = await refiner(candidates, context, userName)
        guard !Task.isCancelled, session != nil else { return }
        for item in refined {
            // Only rule flags the user hasn't touched since.
            guard let index = flags.firstIndex(where: { $0.id == item.id }), flags[index].origin == .rule else { continue }
            flags[index].text = item.text
            flags[index].owner = item.owner
            flags[index].due = item.due
            flags[index].isMine = item.isMine
            flags[index].origin = item.origin
            flags[index].isDismissed = item.isDismissed
        }
        schedulePersist()
    }

    private func schedulePersist() {
        guard let id = session?.id else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.persistDelay))
            guard !Task.isCancelled, let self else { return }
            await self.persistNow(id)
        }
    }

    private func persistNow(_ id: UUID) async {
        let flags = flags, talk = talk
        await store.update(id) {
            $0.flags = flags
            $0.talk = talk
        }
    }

    private func stopTimersAndSubscriptions() {
        subscriptions.removeAll()
        talkTask?.cancel(); talkTask = nil
        refineTask?.cancel(); refineTask = nil
        persistTask?.cancel(); persistTask = nil
    }
}

// MARK: - Flag detection (pure)

enum MeetingFlagDetector {
    /// Action items and decisions said in one final segment.
    static func flags(in segment: TranscriptSegment, userName: String) -> [MeetingFlag] {
        let me = MeetingAIText.firstName(userName)
        var result: [MeetingFlag] = []
        for sentence in MeetingAIText.sentences(segment.text) {
            guard let match = classify(sentence, speaker: segment.speaker, userFirst: me) else { continue }
            result.append(MeetingFlag(
                id: UUID(), kind: match.kind, text: match.text, owner: match.owner, due: match.due,
                isMine: match.isMine, at: segment.start, segmentID: segment.id,
                speaker: segment.speaker, origin: .rule
            ))
        }
        return result
    }

    /// "by Friday" -> "Friday", "end of day" -> "EOD", "next week".
    static func dueText(in text: String) -> String? {
        let lower = normalizeQuotes(text).lowercased()
        guard let match = firstMatch(dueRegex, in: lower), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: lower) else { return nil }
        var phrase = String(lower[range]).trimmingCharacters(in: .whitespaces)
        switch phrase {
        case "eod", "cob", "end of day", "end of the day": return "EOD"
        case "eow", "end of week", "end of the week": return "end of week"
        default: break
        }
        phrase = phrase.replacingOccurrences(of: ".", with: "")
        let capitalized = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                           "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return phrase.split(separator: " ").map { word in
            capitalized.contains(where: { word.hasPrefix($0) }) ? word.capitalized : String(word)
        }.joined(separator: " ")
    }

    /// Order-free content words, for de-duplication.
    static func normalizedKey(_ text: String) -> String {
        let words = normalizeQuotes(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !keyStopWords.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
        return Set(words).sorted().joined(separator: " ")
    }

    /// A short reply that settles what was just proposed ("Agreed.", "Ship
    /// it.", "OK, let's do that.").
    static func affirmsPrevious(_ text: String) -> Bool {
        let lower = normalizeQuotes(MeetingAIText.collapse(text)).lowercased()
        return lower.range(of: #"^(?:(?:ok(?:ay)?|yeah|yes|yep|great|perfect|cool|sounds good|that works|alright)[ ,.!]*)*(?:agreed|ship it|let's do (?:that|it|this)|let's go with (?:that|it|this)|go with that|deal|approved|that's the plan|done deal|works for me|we're agreed)[ .!]*$"#,
                           options: .regularExpression) != nil
    }

    /// Asks the on-device model to confirm and clean rule candidates. Returns
    /// the input unchanged when the model isn't available or fails. Never
    /// leaves the Mac (no Groq here).
    static func refine(_ candidates: [MeetingFlag], context: [TranscriptSegment],
                       userName: String) async -> [MeetingFlag] {
        let reviewable = candidates.filter { $0.kind == .actionItem || $0.kind == .decision }
        guard !reviewable.isEmpty, MeetingAIBackend.onDeviceAvailable else { return candidates }
        let me = MeetingAIText.firstName(userName)
        let transcript = context.suffix(12).map {
            "\(MeetingAIText.speakerLabel($0.speaker, userFirst: me)): \(clip(MeetingAIText.collapse($0.text), to: 260))"
        }.joined(separator: "\n")
        let list = reviewable.enumerated().map { index, flag in
            let kind = flag.kind == .decision ? "decision" : "action"
            let owner = flag.owner.map { " (owner: \($0))" } ?? ""
            return "\(index + 1). [\(kind)] \(flag.text)\(owner)"
        }.joined(separator: "\n")
        let item = MeetingAISchema.object(name: "FlagReview", properties: [
            .init(name: "number", description: "The item number from the list", schema: .string),
            .init(name: "keep", description: "yes if it is a real commitment or decision, else no", schema: .string),
            .init(name: "text", description: "Short imperative wording, under 12 words, keep names and dates", schema: .string),
            .init(name: "owner", description: "First name of who will do it, \(me) for the user, Team, or empty", schema: .string),
            .init(name: "due", description: "Due date or timeframe as spoken, or empty", schema: .string),
        ])
        let schema = MeetingAISchema.object(name: "FlagReviews", properties: [
            .init(name: "items", description: "One entry per numbered item", schema: .array(item, maxItems: reviewable.count)),
        ])
        let instructions = """
        You check notes taken live in \(me)'s meeting. For each numbered item decide whether it is a real \
        action item (someone committed to do something) or a real decision, and rewrite it short and clear. \
        Use only the transcript. Never invent names, dates or facts.
        """
        let prompt = "Transcript (latest lines):\n\(transcript)\n\nItems:\n\(list)\n\nAnswer as JSON: \(schema.outline)"
        do {
            let raw = try await MeetingAIBackend.onDevice(
                instructions: instructions, prompt: prompt, schema: schema,
                maxTokens: 400, timeout: 8, permissive: true
            )
            guard let object = MeetingAIJSON.object(from: raw) else { return candidates }
            var updated: [UUID: MeetingFlag] = [:]
            for entry in MeetingAIJSON.objects(object["items"]) {
                guard let number = MeetingAIJSON.string(entry["number"]).flatMap({ Int($0.filter(\.isNumber)) }),
                      reviewable.indices.contains(number - 1) else { continue }
                var flag = reviewable[number - 1]
                if MeetingAIJSON.string(entry["keep"])?.lowercased().hasPrefix("n") == true {
                    flag.isDismissed = true
                } else if let text = MeetingAIJSON.string(entry["text"]), text.count >= 3 {
                    flag.text = clip(text, to: 140)
                }
                if let owner = MeetingAIJSON.string(entry["owner"]) {
                    let mine = ["me", "i", "you", me.lowercased()].contains(owner.lowercased())
                    flag.owner = mine ? me : owner
                    flag.isMine = mine
                }
                if let due = MeetingAIJSON.string(entry["due"]) { flag.due = due }
                flag.origin = .model
                updated[flag.id] = flag
            }
            return candidates.map { updated[$0.id] ?? $0 }
        } catch {
            AppLog.log("MeetingIntel: flag review on device skipped (\(error.localizedDescription))")
            return candidates
        }
    }

    // MARK: Rules

    struct Match: Equatable {
        var kind: MeetingFlagKind
        var text: String
        var owner: String?
        var due: String?
        var isMine: Bool
    }

    /// One sentence -> an action item, a decision, or nothing.
    static func classify(_ raw: String, speaker: MeetingSpeaker, userFirst: String) -> Match? {
        var sentence = normalizeQuotes(MeetingAIText.collapse(raw))
        let isQuestion = sentence.hasSuffix("?")
        sentence = stripFillers(sentence)
        // "Koushik, can you …" -> addressee.
        var addressee: String?
        if let match = firstMatch(vocativeRegex, in: sentence), let range = Range(match.range(at: 1), in: sentence) {
            let name = String(sentence[range])
            if !stopNames.contains(name) {
                addressee = name
                sentence = String(sentence[sentence.index(range.upperBound, offsetBy: 1)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let lower = sentence.lowercased()
        guard MeetingAIText.words(lower).count >= 2 else { return nil }
        let due = dueText(in: sentence)
        let me = userFirst.lowercased()

        // Decisions.
        if let rest = remainder(after: decisionRegex, in: sentence) {
            guard !isQuestion, lower.range(of: decisionNegation, options: .regularExpression) == nil else { return nil }
            let body = MeetingAIText.words(rest).count >= 2 ? rest : sentence
            let goWith = lower.range(of: #"\b(?:let's|we'll|we're|we are|we will) go(?:ing)? with\b"#, options: .regularExpression) != nil
            let text = goWith && body == rest ? "Go with " + statement(body, capitalize: false) : statement(body)
            guard MeetingAIText.words(text).count >= 2 else { return nil }
            return Match(kind: .decision, text: clip(text, to: 140), owner: nil, due: due, isMine: false)
        }

        // First person: "I'll send the deck by Friday."
        if let rest = remainder(after: firstPersonRegex, in: sentence) {
            guard !isQuestion, isTask(rest, due: due) else { return nil }
            let mine = speaker == .me
            return Match(kind: .actionItem, text: statement(rest), owner: mine ? userFirst : nil, due: due, isMine: mine)
        }

        // Someone by name: "Priya will send the deck."
        if let match = firstMatch(namedRegex, in: sentence),
           let nameRange = Range(match.range(at: 1), in: sentence),
           let whole = Range(match.range, in: sentence) {
            let name = String(sentence[nameRange])
            let rest = String(sentence[whole.upperBound...])
            if !stopNames.contains(name), !isQuestion, isTask(rest, due: due) {
                let mine = name.lowercased() == me
                return Match(kind: .actionItem, text: statement(rest), owner: mine ? userFirst : name, due: due, isMine: mine)
            }
        }

        // The team: "We'll ship the beta on Monday."
        if let rest = remainder(after: teamRegex, in: sentence) {
            guard !isQuestion, isTask(rest, due: due) else { return nil }
            return Match(kind: .actionItem, text: statement(rest), owner: "Team", due: due, isMine: false)
        }
        if due != nil, let rest = remainder(after: #"\bwe should\b"#, in: sentence), !isQuestion, isTask(rest, due: due) {
            return Match(kind: .actionItem, text: statement(rest), owner: "Team", due: due, isMine: false)
        }

        // Requests: "Can you send me the deck?"
        if let rest = remainder(after: requestRegex, in: sentence) {
            guard isTask(rest, due: due),
                  rest.lowercased().range(of: requestNonTask, options: .regularExpression) == nil else { return nil }
            let owner: String?
            if let addressee {
                owner = addressee.lowercased() == me ? userFirst : addressee
            } else {
                // Someone on the call asking: usually asks the listener.
                owner = speaker == .others ? userFirst : nil
            }
            let mine = owner?.lowercased() == me
            return Match(kind: .actionItem, text: statement(rest), owner: owner, due: due, isMine: mine)
        }

        // "Action item: Priya to update the forecast."
        if let rest = remainder(after: #"\baction items?\b(?:\s+(?:is|for|here))?[:,]?"#, in: sentence),
           MeetingAIText.words(rest).count >= 2 {
            var owner: String?
            var text = rest
            if let match = firstMatch(ownerLeadRegex, in: rest), let nameRange = Range(match.range(at: 1), in: rest),
               let whole = Range(match.range, in: rest), !stopNames.contains(String(rest[nameRange])) {
                owner = String(rest[nameRange])
                text = String(rest[whole.upperBound...])
            } else if rest.lowercased().hasPrefix("for me") || rest.lowercased().hasPrefix("me") {
                owner = speaker == .me ? userFirst : nil
            }
            let mine = owner?.lowercased() == me
            return Match(kind: .actionItem, text: statement(text), owner: owner, due: due, isMine: mine)
        }

        // Follow-ups: "Follow up with legal on the contract."
        if !isQuestion, lower.range(of: #"\b(follow[- ]up|circle back|get back to)\b"#, options: .regularExpression) != nil,
           lower.range(of: #"\b(not|never|don't|didn't|won't)\b"#, options: .regularExpression) == nil {
            let mine = speaker == .me
            return Match(kind: .actionItem, text: statement(sentence), owner: mine ? userFirst : nil, due: due, isMine: mine)
        }

        // "The contract needs to be signed by Friday."
        if due != nil, !isQuestion, let rest = remainder(after: #"\b(?:needs? to|has to|have to|must)\b"#, in: sentence),
           isTask(rest, due: due) {
            return Match(kind: .actionItem, text: statement(sentence), owner: nil, due: due, isMine: false)
        }
        return nil
    }

    /// Cleaned, capitalized wording without trailing punctuation.
    /// Long sentences keep their first clause ("…, the data backs that up").
    static func statement(_ text: String, capitalize: Bool = true) -> String {
        var text = MeetingAIText.collapse(text)
        text = text.replacingOccurrences(
            of: #"^(?:(?:to|that|just|also|definitely|quickly|go ahead and|then|probably|basically|actually|i think|i feel like|i'd say|i believe|maybe|honestly)\s+)+"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        if MeetingAIText.words(text).count > 14, let comma = text.range(of: ", "),
           MeetingAIText.words(String(text[..<comma.lowerBound])).count >= 4 {
            text = String(text[..<comma.lowerBound])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!?-—"))
        if capitalize, let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        return clip(text, to: 140)
    }

    static func clip(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    // MARK: Helpers

    private static func isTask(_ rest: String, due: String?) -> Bool {
        let lower = rest.lowercased().trimmingCharacters(in: .whitespaces)
        let words = MeetingAIText.words(lower)
        guard words.count >= 2 || (words.count == 1 && due != nil) else { return false }
        // "I will not be there", "I'll never …", "we can't".
        if lower.range(of: #"^(?:\S+\s+){0,2}(?:not|never|no longer)\b"#, options: .regularExpression) != nil { return false }
        return lower.range(of: nonTaskLead, options: .regularExpression) == nil
    }

    private static func remainder(after pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func stripFillers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^(?:(?:so|okay|ok|um+|uh+|yeah|yes|alright|all right|right|and|well|cool|great|perfect|sure|honestly|anyway)\b[,.]?\s+)+"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
    }

    static func normalizeQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static let decisionRegex =
        #"\b(?:we(?:'ve| have)? (?:decided|agreed)(?: (?:to|that|on))?|(?:the )?decision is(?: to| that)?|let's go with|we're going with|we are going with|we'll go with|(?:it's |it is )?agreed(?: that|,)?|final answer(?: is)?|ship it|we settled on|settled on|the plan is(?: to)?|going forward,? we)\b[:,]?"#
    private static let decisionNegation =
        #"\b(?:not (?:yet )?(?:decided|agreed)|haven't (?:decided|agreed)|have not (?:decided|agreed)|didn't (?:decide|agree)|undecided|no decision|don't agree|disagree|if we (?:decide|agree)|before we decide|unless)\b"#
    private static let firstPersonRegex =
        #"\b(?:i'll|i will|i'm going to|i am going to|i'm gonna|let me|i need to|i have to|i've got to|i can take|i'll take care of|i'll own)\b"#
    private static let teamRegex =
        #"\b(?:we'll|we will|we need to|we have to|we're going to|we are going to|we must)\b"#
    private static let requestRegex =
        #"\b(?:can you|could you|would you|can you please|could you please|please)\b"#
    /// Things people say on calls that aren't tasks.
    private static let nonTaskLead =
        #"^(?:be (?:honest|brief|quick|right back|back|there|late|on|out|off|fine|happy)|say|admit|pass|keep it short|start (?:with|by)|see\b|think\b|talk\b|share my screen|stop sharing|mute|unmute|just say|tell you what|try that again|repeat|check\s*$|know\b|get there|figure it out\s*$|move on|jump in|hand (?:it )?over|(?:walk|run|go) (?:you |everyone |us )?through|show you|pull (?:it |that )?up|explain|recap|summari[sz]e|give (?:you |everyone )?(?:a |some )?(?:quick )?(?:update|context|overview|background|demo)|kick (?:us |it |things )?off)"#
    private static let requestNonTask =
        #"^(?:hear|see (?:my|the|your|it|this|me)|repeat|say that|go back|unmute|mute|scroll|share your screen|give me a (?:sec|second|minute)|let me know if you can hear)"#

    private static let vocativeRegex =
        try! NSRegularExpression(pattern: #"^([A-Z][a-z]{1,15}),\s"#)
    private static let namedRegex =
        try! NSRegularExpression(pattern: #"\b([A-Z][a-z]{1,15})(?:'ll| will| is going to| can take| is taking| to own| owns| needs to| is on)\b"#)
    private static let ownerLeadRegex =
        try! NSRegularExpression(pattern: #"^(?:for\s+)?([A-Z][a-z]{1,15})(?::|,|\s+to\b|\s+will\b|\s+-)\s*"#)
    private static let dueRegex = try! NSRegularExpression(pattern:
        #"\b(?:by|before|until|on|for|due)?\s*(end of (?:the )?(?:day|week|month|sprint|quarter)|eod|eow|cob|tomorrow(?: morning| afternoon| evening)?|tonight|today|this (?:afternoon|evening|week|month)|next (?:week|month|sprint|call|meeting|sync|monday|tuesday|wednesday|thursday|friday)|(?:this )?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2}(?:st|nd|rd|th)?|the \d{1,2}(?:st|nd|rd|th))\b"#)

    private static let stopNames: Set<String> = [
        "I", "We", "It", "That", "This", "There", "Someone", "Somebody", "Everyone", "Everybody", "Nobody", "They",
        "He", "She", "You", "Who", "What", "Which", "Then", "So", "And", "But", "Also", "Maybe", "Today", "Tomorrow",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Okay", "Yeah", "Yes", "Well",
        "Sure", "Right", "Great", "Cool", "Perfect", "Hey", "Hi", "Thanks", "Sorry", "Please", "Now", "Next", "Engineering",
        "Design", "Marketing", "Sales", "Legal", "Finance", "Product", "Everything", "Nothing", "If", "When", "Once",
    ]
    private static let keyStopWords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "for", "on", "by", "with", "it", "that", "this", "i", "we", "you", "will",
        "ll", "be", "is", "are", "me", "my", "our", "your", "please", "can", "could", "just", "then", "so", "go", "ahead",
    ]
}

// MARK: - Display helpers

enum MeetingIntelClock {
    /// "12:41" / "1:02:09" from seconds since recording started.
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// "45 s", "1.5 min", "2 min" (rounded down to the half minute).
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "\(Int(seconds)) s" }
        let halves = (seconds / 30).rounded(.down) / 2
        return halves == halves.rounded(.down) ? "\(Int(halves)) min" : String(format: "%.1f min", halves)
    }

    static func percent(_ share: Double?) -> String {
        share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

extension MeetingFlag {
    /// "You", "Priya", "Team", or nil.
    var ownerLabel: String? { isMine ? "You" : owner }
}

// MARK: - Views

/// Two caption lines under the notch, newest at the bottom. Each line starts
/// with a speaker tick (you in the accent, others grey); text still being
/// recognized is dimmer. Trailing: live dot, talk share, bookmark, close.
struct MeetingCaptionBand: View {
    @ObservedObject var assist: LiveMeetingAssist

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                let lines = Array(assist.captionLines.suffix(2))
                if lines.isEmpty {
                    captionRow(MeetingCaptionLine(id: UUID(), speaker: .others, text: "Listening…", isFinal: false, at: 0),
                               isNewest: true)
                } else {
                    ForEach(lines) { line in
                        captionRow(line, isNewest: line.id == lines.last?.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 10) {
                    MeetingIntelLiveBadge(compact: true)
                    Button {
                        assist.bookmarkNow(note: nil)
                    } label: {
                        Image(systemName: "bookmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help("Bookmark this moment")
                    Button {
                        assist.captionsVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help("Hide captions (recording continues)")
                }
                if assist.showsTalkMeter {
                    HStack(spacing: 6) {
                        MeetingTalkShareBar(stats: assist.talk, height: 3)
                            .frame(width: 38)
                        Text("You \(MeetingIntelClock.percent(assist.talk.myShare))")
                            .font(SparkVTheme.caption(10).monospacedDigit())
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live captions")
    }

    private func captionRow(_ line: MeetingCaptionLine, isNewest: Bool) -> some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(line.speaker == .me ? SparkVTheme.accent : SparkVTheme.textSecondary)
                .frame(width: 2, height: 12)
            Text(line.text)
                .font(SparkVTheme.body(isNewest ? 12.5 : 11.5))
                .foregroundStyle(!line.isFinal ? SparkVTheme.textTertiary
                                 : isNewest ? SparkVTheme.text : SparkVTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .accessibilityLabel("\(line.speaker == .me ? "You" : "Others"): \(line.text)")
    }
}

/// One-line toast (≤3 s) when something is flagged.
struct MeetingFlagToast: View {
    let flag: MeetingFlag
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().strokeBorder(flag.kind.tint.opacity(0.7), lineWidth: 1.2)
                Image(systemName: flag.kind.symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(flag.kind.tint)
            }
            .frame(width: 17, height: 17)

            Group {
                if flag.kind == .bookmark {
                    Text("Moment saved").foregroundStyle(SparkVTheme.text)
                        + Text("  \(MeetingIntelClock.text(flag.at))").foregroundStyle(SparkVTheme.textSecondary)
                } else {
                    Text(flag.kind.label).foregroundStyle(flag.kind.tint)
                        + Text(flag.ownerLabel.map { "  \($0): " } ?? "  ").foregroundStyle(SparkVTheme.textSecondary)
                        + Text(flag.text).foregroundStyle(SparkVTheme.text)
                }
            }
            .font(SparkVTheme.body(12).weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            MeetingIntelLiveBadge(compact: true)
            Button("Undo", action: onUndo)
                .buttonStyle(SparkVPressStyle())
                .font(SparkVTheme.caption(11))
                .foregroundStyle(SparkVTheme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }
}

/// The once-in-a-while nudge after a long stretch of the user talking.
struct MeetingNudgeBand: View {
    let stats: MeetingTalkStats

    var body: some View {
        HStack(spacing: 11) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(SparkVTheme.accent)
                    .frame(width: 1.5)
                    .padding(.vertical, 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("You've had the floor for \(MeetingIntelClock.duration(stats.currentMonologue))")
                    .font(SparkVTheme.headline(12.5))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Text("Maybe check in with the room")
                    .font(SparkVTheme.body(11.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                MeetingIntelLiveBadge(compact: true)
                HStack(spacing: 6) {
                    MeetingTalkShareBar(stats: stats, height: 3).frame(width: 38)
                    Text("You \(MeetingIntelClock.percent(stats.myShare))")
                        .font(SparkVTheme.caption(10).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }
}

/// Flags down a thread line, one node per flag (timestamp, kind, owner, due,
/// note). Reused by the wrap-up window (C).
struct MeetingFlagTimeline: View {
    let flags: [MeetingFlag]
    var onSelect: (MeetingFlag) -> Void = { _ in }

    private var items: [MeetingFlag] { flags.filter { !$0.isDismissed }.sorted { $0.at < $1.at } }

    var body: some View {
        let items = items
        if items.isEmpty {
            Text("Nothing flagged in this meeting.")
                .font(SparkVTheme.body(12))
                .foregroundStyle(SparkVTheme.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, flag in
                    Button {
                        onSelect(flag)
                    } label: {
                        row(flag, isFirst: index == 0, isLast: index == items.count - 1)
                    }
                    // Large row: a lighter press than a button.
                    .buttonStyle(SparkVPressStyle(scale: 0.99))
                }
            }
        }
    }

    private func row(_ flag: MeetingFlag, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : SparkVTheme.stroke)
                    .frame(width: 1.5, height: 3)
                ZStack {
                    Circle().fill(SparkVTheme.islandBackground)
                    Circle().strokeBorder(flag.kind.tint.opacity(0.75), lineWidth: 1.2)
                    Image(systemName: flag.kind.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(flag.kind.tint)
                }
                .frame(width: 18, height: 18)
                Rectangle()
                    .fill(isLast ? Color.clear : SparkVTheme.stroke)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(MeetingIntelClock.text(flag.at))
                        .font(SparkVTheme.caption(10).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                    Text(flag.kind.label.uppercased())
                        .font(SparkVTheme.eyebrow(9))
                        .tracking(1)
                        .foregroundStyle(flag.kind.tint)
                    if let owner = flag.ownerLabel {
                        Text(owner)
                            .font(SparkVTheme.caption(10.5))
                            .foregroundStyle(flag.isMine ? SparkVTheme.text : SparkVTheme.textSecondary)
                    }
                    if let due = flag.due {
                        Text("· \(due)")
                            .font(SparkVTheme.caption(10.5))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                }
                Text(flag.text)
                    .font(SparkVTheme.body(12.5))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = flag.note {
                    Text(note)
                        .font(SparkVTheme.body(11.5).italic())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.top, 3)
            .padding(.bottom, isLast ? 0 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The live meeting's flags in the notes window (INTEGRATION.md step 10).
/// Renders nothing unless `meetingID` is the session being recorded and
/// something was flagged.
struct MeetingLiveFlagsSection: View {
    @ObservedObject var assist: LiveMeetingAssist
    let meetingID: UUID

    var body: some View {
        if assist.session?.id == meetingID, !assist.visibleFlags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MeetingIntelEyebrow(text: "Flagged live")
                    MeetingIntelLiveBadge(text: "On this Mac")
                }
                MeetingFlagTimeline(flags: assist.flags)
            }
        }
    }
}

/// Gear-menu items for live help (Meetings submenu; see INTEGRATION.md step 7).
struct MeetingLiveAssistMenuItems: View {
    @ObservedObject var assist: LiveMeetingAssist
    @ObservedObject var prefs: MeetingIntelPreferences

    init(assist: LiveMeetingAssist) {
        self.assist = assist
        prefs = assist.prefs
    }

    var body: some View {
        Button("Bookmark This Moment") { assist.bookmarkNow(note: nil) }
            .disabled(assist.session == nil)
        if let plan = assist.session?.plan, !plan.translate {
            Toggle("Show Live Captions", isOn: $assist.captionsVisible)
        }
        Toggle("Flag Action Items & Decisions", isOn: $prefs.flagging)
        Toggle("Talk-Time Meter", isOn: $prefs.talkMeter)
        Toggle("Nudge After Long Monologues", isOn: $prefs.monologueNudge)
        Picker("Nudge After", selection: $prefs.monologueSeconds) {
            ForEach(MeetingIntelPreferences.monologueChoices, id: \.self) { seconds in
                Text(MeetingIntelClock.duration(seconds)).tag(seconds)
            }
        }
        .disabled(!prefs.monologueNudge)
    }
}
