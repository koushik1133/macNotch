import AppKit
import SwiftUI

/// Prompt Refiner: the user types or dictates a rough prompt, answers a few
/// clarifying questions (or skips them), and gets a structured prompt for the
/// chosen target, copied to the clipboard. The prompt is never executed; the
/// only thing that leaves the app is the clipboard copy the user asks for, and
/// (only with this feature's own opt-in) the Groq request.
///
/// Wiring (see the integration notes in the final report): create it with the
/// shared `ActivityCenter`, call `start()`, inject as an environment object for
/// `PromptRefinerDrawerView`, and optionally connect dictation through
/// `startDictation` / `stopDictation`.
@MainActor
final class PromptRefinerController: ObservableObject {
    enum Phase: Equatable {
        case compose
        case askingQuestions
        case answering
        case refining
        case done
        case failed(String)
    }

    /// Where dictated text goes.
    enum DictationField: Equatable {
        case draft
        case feedback
        case question(UUID)
    }

    // MARK: Published state

    @Published var draft = ""
    @Published var target: PromptTarget {
        didSet {
            guard target != oldValue else { return }
            PromptRefinerSettings.target = target
            prewarm()
        }
    }
    @Published var askQuestionsFirst: Bool {
        didSet { PromptRefinerSettings.askQuestionsFirst = askQuestionsFirst }
    }
    /// Use the Groq key (Clicky's) for this feature. Off by default.
    @Published var allowGroq: Bool {
        didSet {
            guard allowGroq != oldValue else { return }
            PromptRefinerSettings.allowGroq = allowGroq
            refreshEngineLabel()
            AppLog.log("Prompt Refiner: Groq \(allowGroq ? "allowed" : "not allowed")")
        }
    }
    @Published private(set) var phase: Phase = .compose
    @Published var questions: [ClarifyingQuestion] = []
    @Published private(set) var questionSource: PromptRefinerSource?
    @Published private(set) var questionLatency: TimeInterval = 0
    /// Editable result.
    @Published var refinedText = ""
    @Published private(set) var refinedTitle = ""
    @Published private(set) var lastRefinement: PromptRefinement?
    /// Optional "what to change" note for Refine again.
    @Published var feedback = ""
    @Published private(set) var history: [PromptRefinementRecord] = []
    @Published var showsHistory = false
    @Published var showsSettings = false
    /// History waiting for the user to confirm a delete (nothing is deleted
    /// without confirmation): one entry, or everything.
    @Published private(set) var pendingDeleteID: UUID?
    @Published private(set) var confirmsClearHistory = false
    @Published private(set) var isDictating = false
    @Published private(set) var toast: String?
    /// When the running model step started (for the elapsed-time label).
    @Published private(set) var workStartedAt: Date?

    /// Questions / prompt text as the on-device model writes them (read-only
    /// preview while a step runs).
    @Published private(set) var streamingQuestions: [ClarifyingQuestion] = []
    @Published private(set) var streamingText = ""

    /// The rough prompt the current questions/result belong to.
    @Published private(set) var sessionRough = ""

    // MARK: Hooks for the lead to wire

    /// Starts a dictation whose text is handed to the completion (nil when
    /// cancelled). Wire to `DictationController.startNoteDictation(completion:)`.
    var startDictation: ((@escaping @MainActor (String?) -> Void) -> Bool)?
    /// Ends the running dictation. Wire to `DictationController.finishNoteDictation()`.
    var stopDictation: (() -> Void)?

    var canDictate: Bool { startDictation != nil }

    /// True while dictation is filling `field` (so only that mic shows Stop).
    func isDictating(into field: DictationField) -> Bool { isDictating && dictationField == field }

    // MARK: Private

    private let activities: ActivityCenter
    private let store: PromptRefinerHistory
    private var panel: PromptRefinerPanelController?
    private var work: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var dictationField: DictationField = .draft
    private var isStarted = false
    /// Bumped per model step so late streaming updates are dropped.
    private var runID = 0
    private static let activityID = "promptRefiner"

    init(activities: ActivityCenter, historyDirectory: URL? = nil) {
        self.activities = activities
        store = PromptRefinerHistory(directory: historyDirectory)
        target = PromptRefinerSettings.target
        askQuestionsFirst = PromptRefinerSettings.askQuestionsFirst
        allowGroq = PromptRefinerSettings.allowGroq
        history = store.records
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        history = store.records
        refreshEngineLabel()
        AppLog.log("Prompt Refiner: started (\(history.count) saved refinement(s))")
    }

    /// Call when the drawer tab appears: loads the on-device model so the
    /// first questions come back faster.
    func prepare() {
        refreshEngineLabel()
        prewarm()
    }

    func stop() {
        cancelWork()
        if isDictating { stopDictation?() }
        isDictating = false
        panel?.close()
        activities.dismiss(id: Self.activityID)
        isStarted = false
    }

    // MARK: Derived

    var isWorking: Bool { phase == .askingQuestions || phase == .refining }

    var answeredCount: Int { questions.filter(\.isAnswered).count }

    var canRefine: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Which engine the next step will use, for the footnote. Refreshed on
    /// start, panel open and opt-in changes (not per render: it asks the
    /// keychain whether a key exists).
    @Published private(set) var engineLabel = PromptRefinerSource.template.label

    private func refreshEngineLabel() {
        engineLabel = makeEngine(readKey: false).preferredSource.label
    }

    var isPanelOpen: Bool { panel?.isOpen ?? false }

    // MARK: Entry points

    /// Starts a refinement of `text` (or the draft): opens the panel and asks
    /// the clarifying questions, or refines right away when questions are off.
    func refine(_ text: String? = nil) {
        if let text { draft = text }
        let rough = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rough.isEmpty else {
            openPanel()
            return
        }
        sessionRough = rough
        questions = []
        questionSource = nil
        refinedText = ""
        refinedTitle = ""
        lastRefinement = nil
        feedback = ""
        showsHistory = false
        cancelPendingDelete()
        openPanel()
        if askQuestionsFirst {
            askQuestions()
        } else {
            runRefinement(previous: nil, feedback: nil)
        }
    }

    func openPanel() {
        let panel = panel ?? PromptRefinerPanelController(controller: self)
        self.panel = panel
        panel.open()
        refreshEngineLabel()
        prewarm()
    }

    func closePanel() {
        cancelWork()
        if isDictating { finishDictation() }
        panel?.close()
    }

    /// Opens the panel on the history list.
    func showHistory() {
        openPanel()
        showsHistory = true
    }

    /// Skips (or stops waiting for) the questions and refines right away.
    func skipQuestions() {
        guard !sessionRough.isEmpty || canRefine else { return }
        if sessionRough.isEmpty { sessionRough = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
        for index in questions.indices {
            questions[index].selected = []
            questions[index].freeText = ""
        }
        runRefinement(previous: nil, feedback: nil)
    }

    func submitAnswers() {
        guard phase == .answering else { return }
        runRefinement(previous: nil, feedback: nil)
    }

    func toggle(option: String, questionID: UUID) {
        guard let index = questions.firstIndex(where: { $0.id == questionID }) else { return }
        if let existing = questions[index].selected.firstIndex(of: option) {
            questions[index].selected.remove(at: existing)
        } else {
            questions[index].selected.append(option)
        }
    }

    /// Runs the refinement again on the current result, with the optional
    /// feedback note ("shorter", "add tests").
    func refineAgain() {
        guard !refinedText.isEmpty else { return }
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        runRefinement(previous: refinedText, feedback: note.isEmpty ? nil : note)
    }

    /// Back to the editor with the same rough prompt.
    func startOver() {
        cancelWork()
        phase = .compose
        questions = []
        refinedText = ""
        feedback = ""
        showsHistory = false
    }

    func cancelWork() {
        work?.cancel()
        work = nil
        runID &+= 1
        streamingQuestions = []
        streamingText = ""
        workStartedAt = nil
        activities.dismiss(id: Self.activityID)
        if phase == .askingQuestions || phase == .refining {
            phase = refinedText.isEmpty ? (questions.isEmpty ? .compose : .answering) : .done
        }
    }

    /// Puts the controller into a step without running a model (UI snapshot
    /// tests and previews). `refined` nil shows the questions.
    func loadSnapshot(rough: String, target: PromptTarget, questions: [ClarifyingQuestion], refined: String?,
                      source: PromptRefinerSource = .onDevice) {
        cancelWork()
        draft = rough
        sessionRough = rough
        self.target = target
        self.questions = questions
        questionSource = source
        questionLatency = 7.5
        if let refined {
            refinedText = refined
            refinedTitle = PromptRefinerTemplates.title(from: rough)
            lastRefinement = PromptRefinement(title: refinedTitle, text: refined, source: source, latency: 11.3, note: nil)
            phase = .done
        } else {
            refinedText = ""
            phase = .answering
        }
    }

    // MARK: Clipboard

    func copyRefined() {
        let text = refinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        copy(text)
        flash("Copied to clipboard")
        postCopiedActivity(title: refinedTitle)
    }

    func copy(_ record: PromptRefinementRecord) {
        copy(record.refined)
        flash("Copied to clipboard")
        postCopiedActivity(title: record.title)
    }

    /// Copies the newest history entry (the drawer's "Copy last").
    func copyLast() {
        guard let last = history.first else { return }
        copy(last)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLog.log("Prompt Refiner: copied \(text.count) chars")
    }

    // MARK: History

    func restore(_ record: PromptRefinementRecord) {
        cancelWork()
        draft = record.rough
        sessionRough = record.rough
        target = record.target
        questions = record.answers.map {
            ClarifyingQuestion(label: "", question: $0.question, options: [], selected: [], freeText: $0.answer)
        }
        refinedText = record.refined
        refinedTitle = record.title
        lastRefinement = PromptRefinement(title: record.title, text: record.refined, source: record.source,
                                          latency: Double(record.latencyMs) / 1000, note: nil)
        feedback = ""
        phase = .done
        showsHistory = false
    }

    /// First tap on a row's trash: asks for confirmation in the row.
    func requestDelete(id: UUID) {
        confirmsClearHistory = false
        pendingDeleteID = id
    }

    /// First tap on Clear all: asks for confirmation in the footer.
    func requestClearHistory() {
        pendingDeleteID = nil
        confirmsClearHistory = true
    }

    func cancelPendingDelete() {
        pendingDeleteID = nil
        confirmsClearHistory = false
    }

    /// Deletes one entry; only after `requestDelete(id:)` for the same entry.
    func deleteHistory(id: UUID) {
        guard pendingDeleteID == id else {
            requestDelete(id: id)
            return
        }
        pendingDeleteID = nil
        store.remove(id: id)
        history = store.records
        AppLog.log("Prompt Refiner: deleted 1 saved refinement")
    }

    /// Deletes everything; only after `requestClearHistory()`.
    func clearHistory() {
        guard confirmsClearHistory else {
            requestClearHistory()
            return
        }
        confirmsClearHistory = false
        let count = history.count
        store.clear()
        history = store.records
        AppLog.log("Prompt Refiner: cleared \(count) saved refinement(s)")
    }

    /// One-tap "Refine" choices on a result (shorter, more formal…), applied
    /// as feedback for Refine again.
    static let quickRefinements = ["Shorter", "More detailed", "More formal", "More casual", "Add an example"]

    func quickRefine(_ choice: String) {
        guard !refinedText.isEmpty, !isWorking else { return }
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction: String
        switch choice {
        case "Shorter": instruction = "Make the prompt shorter and tighter; keep every answer the user gave"
        case "More detailed": instruction = "Make the prompt more detailed and specific"
        case "More formal": instruction = "Use a more formal, professional tone"
        case "More casual": instruction = "Use a more casual, conversational tone"
        case "Add an example": instruction = "Add one short example of the desired result to the prompt"
        default: instruction = choice
        }
        runRefinement(previous: refinedText, feedback: note.isEmpty ? instruction : note + "; " + instruction)
    }

    // MARK: Dictation

    /// Inserts dictated (or otherwise captured) text into the field the mic
    /// was started for; the draft by default. Safe to call from any feature.
    func insertDictatedText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        func appended(_ base: String) -> String {
            let trimmed = base.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? cleaned : trimmed + (trimmed.hasSuffix("\n") ? "" : " ") + cleaned
        }
        switch dictationField {
        case .draft:
            draft = appended(draft)
        case .feedback:
            feedback = appended(feedback)
        case .question(let id):
            if let index = questions.firstIndex(where: { $0.id == id }) {
                questions[index].freeText = appended(questions[index].freeText)
            } else {
                draft = appended(draft)
            }
        }
    }

    func toggleDictation(into field: DictationField = .draft) {
        if isDictating {
            finishDictation()
            return
        }
        guard let startDictation else {
            flash("Dictation isn't connected")
            return
        }
        dictationField = field
        let started = startDictation { [weak self] text in
            guard let self else { return }
            self.isDictating = false
            if let text { self.insertDictatedText(text) }
        }
        isDictating = started
        if !started { flash("Dictation is busy") }
    }

    private func finishDictation() {
        stopDictation?()
    }

    // MARK: Running

    private func makeEngine(readKey: Bool) -> PromptRefinerEngine {
        var engine = PromptRefinerEngine()
        // The key is Clicky's: read it only when this feature's opt-in is on.
        // `hasKey()` reads attributes only and never prompts.
        if allowGroq, ClickyKeychain.hasKey() {
            engine.groqKey = readKey ? ClickyKeychain.load() : "pending"
        }
        return engine
    }

    private func prewarm() {
        guard PromptRefinerLLM.onDeviceAvailable, !(allowGroq && ClickyKeychain.hasKey()) else { return }
        let instructions = PromptRefinerPrompts.questionInstructions(target: target)
        Task.detached(priority: .utility) { PromptRefinerLLM.prewarm(instructions: instructions) }
    }

    private func askQuestions() {
        work?.cancel()
        let rough = sessionRough
        let target = target
        let engine = makeEngine(readKey: true)
        phase = .askingQuestions
        workStartedAt = Date()
        runID &+= 1
        let id = runID
        streamingQuestions = []
        postWorkingActivity("Thinking of questions…")
        // Strong capture is fine: the engine drops the callback when the step ends.
        let onPartial: @Sendable ([ClarifyingQuestion]) -> Void = { [self] partial in
            Task { @MainActor in
                guard self.runID == id, self.phase == .askingQuestions else { return }
                self.streamingQuestions = partial
            }
        }
        AppLog.log("Prompt Refiner: questions for \(rough.count) chars, target \(target.rawValue), via \(engine.preferredSource.rawValue)")
        work = Task { [weak self] in
            do {
                let set = try await engine.questions(for: rough, target: target, onPartial: onPartial)
                guard !Task.isCancelled, let self, self.runID == id else { return }
                self.streamingQuestions = []
                self.questions = set.questions
                self.questionSource = set.source
                self.questionLatency = set.latency
                self.phase = .answering
                self.workStartedAt = nil
                self.activities.dismiss(id: Self.activityID)
                AppLog.log(String(format: "Prompt Refiner: %d question(s) via %@ in %.1fs%@",
                                  set.questions.count, set.source.rawValue, set.latency, set.note.map { " (\($0))" } ?? ""))
                // Warm the refinement instructions while the user answers.
                let instructions = PromptRefinerPrompts.refineInstructions(target: target)
                if set.source == .onDevice {
                    Task.detached(priority: .utility) { PromptRefinerLLM.prewarm(instructions: instructions) }
                }
            } catch {
                // Only cancellation reaches here.
            }
        }
    }

    private func runRefinement(previous: String?, feedback note: String?) {
        work?.cancel()
        let rough = sessionRough.isEmpty ? draft.trimmingCharacters(in: .whitespacesAndNewlines) : sessionRough
        guard !rough.isEmpty else { return }
        sessionRough = rough
        let target = target
        let answered = questions
        let engine = makeEngine(readKey: true)
        phase = .refining
        workStartedAt = Date()
        runID &+= 1
        let id = runID
        streamingText = ""
        postWorkingActivity(previous == nil ? "Refining your prompt…" : "Refining again…")
        let onPartial: @Sendable (String) -> Void = { [self] partial in
            Task { @MainActor in
                guard self.runID == id, self.phase == .refining else { return }
                self.streamingText = partial
            }
        }
        AppLog.log("Prompt Refiner: refine (\(answered.filter(\.isAnswered).count) answer(s), again: \(previous != nil)) via \(engine.preferredSource.rawValue)")
        work = Task { [weak self] in
            do {
                let result = try await engine.refine(
                    rough: rough, target: target, questions: answered, previous: previous, feedback: note,
                    onPartial: onPartial
                )
                guard !Task.isCancelled, let self, self.runID == id else { return }
                self.streamingText = ""
                self.finish(result, rough: rough, target: target, questions: answered)
            } catch {
                // Only cancellation reaches here.
            }
        }
    }

    private func finish(_ result: PromptRefinement, rough: String, target: PromptTarget, questions: [ClarifyingQuestion]) {
        refinedText = result.text
        refinedTitle = result.title
        lastRefinement = result
        feedback = ""
        phase = .done
        workStartedAt = nil
        activities.dismiss(id: Self.activityID)
        AppLog.log(String(format: "Prompt Refiner: refined via %@ in %.1fs (%d chars)%@",
                          result.source.rawValue, result.latency, result.text.count, result.note.map { " (\($0))" } ?? ""))
        let record = PromptRefinementRecord(
            title: result.title,
            rough: rough,
            target: target,
            answers: questions.compactMap { q in q.answer.map { .init(question: q.question, answer: $0) } },
            refined: result.text,
            source: result.source,
            latencyMs: Int((result.latency * 1000).rounded())
        )
        store.add(record)
        history = store.records
    }

    // MARK: Feedback

    func flash(_ text: String) {
        toastTask?.cancel()
        // Enter and exit both use the strong ease-out (never ease-in).
        withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) { toast = text }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) { self?.toast = nil }

        }
    }

    private func postWorkingActivity(_ text: String) {
        // The panel shows progress itself; the band is for when it's hidden.
        guard !(panel?.isOpen ?? false) else { return }
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: nil) {
            PromptRefinerActivityView(systemImage: "wand.and.stars", text: text, isWorking: true)
        })
    }

    private func postCopiedActivity(title: String) {
        let text = title.isEmpty ? "Prompt copied" : "Copied: \(title)"
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: 2.5) {
            PromptRefinerActivityView(systemImage: "doc.on.clipboard.fill", text: text, isWorking: false)
        })
    }
}

/// Band under the notch while Prompt Refiner works in the background or just
/// copied a prompt (~360×30 pt, dark).
struct PromptRefinerActivityView: View {
    let systemImage: String
    let text: String
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LabsTint.feature)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
