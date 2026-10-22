import AppKit
import SwiftUI

/// Coordinates a recorded meeting end to end: capture (`MeetingRecorder`),
/// live suggested answers when someone asks the user a question
/// (`QuestionAnswerer`), minutes of meeting when it ends (`MeetingSummarizer`),
/// the notch band while it runs, and the library of past meetings saved as one
/// JSON file each in ~/Library/Application Support/NotchIsland/Meetings.
@MainActor
final class MeetingAssistant: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case summarizing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The meeting being recorded (or summarized), with its live transcript.
    @Published private(set) var current: MeetingRecord?
    /// Every saved meeting, newest first. The one being recorded is included
    /// (refreshed on each autosave); `current` has its live transcript.
    @Published private(set) var library: [MeetingRecord] = []
    /// The latest suggested answer to a question someone asked the user.
    @Published private(set) var liveAnswer: SuggestedAnswer?
    /// Meetings whose notes are being regenerated from the library.
    @Published private(set) var regenerating: Set<UUID> = []

    /// The Groq key belongs to Clicky; meetings use it only when allowed.
    @Published var allowGroqForMeetings: Bool {
        didSet { UserDefaults.standard.set(allowGroqForMeetings, forKey: Keys.allowGroq) }
    }

    /// Pop up a suggested answer when someone asks the user a question.
    @Published var suggestAnswers: Bool {
        didSet {
            UserDefaults.standard.set(suggestAnswers, forKey: Keys.suggestAnswers)
            if !suggestAnswers { activities.dismiss(id: ActivityID.answer) }
        }
    }

    /// Notice calls (Zoom, Meet, Teams, Slack, Webex, FaceTime…) and offer
    /// to take notes. On by default; needs no permission.
    @Published var detectCalls: Bool {
        didSet {
            guard detectCalls != oldValue else { return }
            UserDefaults.standard.set(detectCalls, forKey: Keys.detectCalls)
            AppLog.log("Meetings: call detection \(detectCalls ? "on" : "off")")
            updateCallDetection()
        }
    }

    /// Start recording on its own when a call starts (off by default). The
    /// recording band still reminds the user to tell participants.
    @Published var autoStartDetectedCalls: Bool {
        didSet { UserDefaults.standard.set(autoStartDetectedCalls, forKey: Keys.autoStartCalls) }
    }

    /// The detected call SparkV is offering to take notes for (shown in the
    /// band and as the Today tab's first row), if any.
    @Published private(set) var promptedCall: DetectedCall?
    /// Return true to take over the offer for this call (MeetingIntel shows
    /// its own prompt). Renames, calendar marks and auto-stop still run here.
    var callOfferOverride: ((DetectedCall) -> Bool)?
    /// Recordings whose minutes shouldn't be written (captions-only calls).
    var skipNotesFor: Set<UUID> = []

    /// Exposed so the notch band and settings can show live levels.
    let recorder = MeetingRecorder()
    let callDetector: MeetingCallDetector

    private let activities: ActivityCenter
    private let store = MeetingLibraryStore()
    private var autosaveTask: Task<Void, Never>?
    private var failureResetTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var notesSaveTask: Task<Void, Never>?
    /// The saved meeting whose typed notes are waiting for `notesSaveTask`.
    private var pendingNotesSave: UUID?
    /// Newest question that arrived while another was being answered.
    private var pendingQuestion: (text: String, askedAt: TimeInterval)?
    /// Normalized questions already answered in this meeting.
    private var answeredQuestions: Set<String> = []
    /// Index of each segment id in `current.segments`.
    private var segmentIndex: [UUID: Int] = [:]
    private var didLoadLibrary = false
    private var isStarted = false
    /// The recording that started from a detected call: it stops and writes
    /// its notes on its own when that call ends.
    private var detectorRecording: (recordID: UUID, callKey: String)?
    /// Calls the user said no to (or already recorded): no prompt again
    /// until the call ends.
    private var declinedCallKeys: Set<String> = []
    private lazy var notesWindow = MeetingNotesWindowController(assistant: self)

    private enum Keys {
        static let allowGroq = "meeting.allowGroq"
        static let suggestAnswers = "meeting.suggestAnswers"
        static let detectCalls = "meeting.detectCalls"
        static let autoStartCalls = "meeting.autoStartDetectedCalls"
    }

    enum ActivityID {
        static let recording = "meeting.recording"
        static let answer = "meeting.answer"
        static let notes = "meeting.notes"
        static let callPrompt = "meeting.callPrompt"
    }

    static let groqModel = "openai/gpt-oss-120b"
    /// Above the calendar heads-up (60) so the recording indicator is never
    /// hidden by it; notifications (70) and HUDs still show briefly on top.
    static let recordingPriority = 65
    /// The "Take notes?" prompt: above the calendar heads-up (60), below
    /// the recording band (65).
    static let callPromptPriority = 62

    init(activities: ActivityCenter, callProbe: (any MeetingSignalProbe)? = nil) {
        self.activities = activities
        let defaults = UserDefaults.standard
        allowGroqForMeetings = defaults.object(forKey: Keys.allowGroq) as? Bool ?? false
        suggestAnswers = defaults.object(forKey: Keys.suggestAnswers) as? Bool ?? true
        detectCalls = defaults.object(forKey: Keys.detectCalls) as? Bool ?? true
        autoStartDetectedCalls = defaults.object(forKey: Keys.autoStartCalls) as? Bool ?? false
        callDetector = MeetingCallDetector(probe: callProbe ?? LiveMeetingSignalProbe())
        callDetector.calendar = { MeetingsController.current?.meetings ?? [] }
        callDetector.isOwnMicActive = { [weak self] in self?.recorder.isRecording ?? false }
        callDetector.onEvent = { [weak self] event in self?.handleCallEvent(event) }
    }

    /// The user's first name ("Koushik"), used to find their tasks and the
    /// questions aimed at them.
    nonisolated static var userName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let first = full.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? NSUserName() : first
    }

    var isRecording: Bool { phase == .recording }

    // MARK: - App lifecycle

    /// Loads the library. Call once at launch.
    func start() {
        guard !didLoadLibrary else { return }
        didLoadLibrary = true
        isStarted = true
        updateCallDetection()
        Task { [weak self] in
            guard let self else { return }
            let loaded = await store.loadAll()
            // Keep anything that changed while loading (a meeting started in
            // the meantime).
            var byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            for record in library { byID[record.id] = record }
            library = byID.values.sorted { $0.startedAt > $1.startedAt }
            AppLog.log("Meetings: loaded \(loaded.count) saved meeting(s)")
        }
    }

    /// Saves the meeting being recorded and stops capture. Call at quit.
    func shutdown() {
        isStarted = false
        callDetector.stop()
        activities.dismiss(id: ActivityID.callPrompt)
        autosaveTask?.cancel()
        notesSaveTask?.cancel()
        if let id = pendingNotesSave, let record = library.first(where: { $0.id == id }) {
            store.saveNow(record)
        }
        answerTask?.cancel()
        failureResetTask?.cancel()
        if var record = current {
            if record.endedAt == nil { record.endedAt = Date() }
            store.saveNow(record)
        }
        if recorder.isRecording {
            let recorder = recorder
            Task { await recorder.stop() }
        }
        activities.dismiss(id: ActivityID.recording)
        activities.dismiss(id: ActivityID.answer)
    }

    // MARK: - Recording

    /// Starts recording a meeting. `title` defaults to the date and time.
    func start(title: String?, calendarEventID: String?) {
        switch phase {
        case .recording, .summarizing: return
        case .idle, .failed: break
        }
        failureResetTask?.cancel()
        // Recording now (from anywhere): the "Take notes?" offer is answered.
        if let call = callDetector.activeCall { declinedCallKeys.insert(call.key) }
        clearCallPrompt()
        detectorRecording = nil

        let now = Date()
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let record = MeetingRecord(
            id: UUID(),
            title: trimmed.isEmpty ? Self.defaultTitle(for: now) : trimmed,
            startedAt: now,
            endedAt: nil,
            calendarEventID: calendarEventID,
            segments: [],
            notes: nil,
            answers: []
        )
        current = record
        segmentIndex = [:]
        answeredQuestions = []
        pendingQuestion = nil
        liveAnswer = nil
        phase = .recording
        postRecordingActivity()

        recorder.onSegment = { [weak self] segment in
            self?.ingest(segment)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start()
                guard current?.id == record.id, phase == .recording else {
                    await recorder.stop()
                    return
                }
                AppLog.log("Meetings: recording \"\(record.title)\"")
                // Load the answer model now so the first suggested answer
                // doesn't pay the on-device model's cold start.
                if suggestAnswers {
                    QuestionAnswerer.prewarm(userName: Self.userName)
                }
                upsertLibrary(record)
                store.save(record)
                startAutosave()
            } catch {
                // Stop was pressed while capture was still starting: stop()
                // owns the session now and finishes it.
                if error is CancellationError, current?.id != record.id || phase != .recording { return }
                AppLog.log("Meetings: could not start recording: \(error.localizedDescription)")
                recorder.onSegment = nil
                current = nil
                activities.dismiss(id: ActivityID.recording)
                fail(recorder.lastError ?? error.localizedDescription)
            }
        }
    }

    /// Stops recording, writes the minutes and opens them.
    func stop() {
        guard phase == .recording, let started = current else { return }
        phase = .summarizing
        autosaveTask?.cancel()
        autosaveTask = nil
        // The meeting is over: a pending or shown suggested answer would only
        // hide the "Writing notes" and "Notes ready" bands.
        activities.dismiss(id: ActivityID.answer)
        postSummarizingActivity()

        Task { [weak self] in
            guard let self else { return }
            await recorder.stop()
            recorder.onSegment = nil
            answerTask?.cancel()
            answerTask = nil
            pendingQuestion = nil

            guard var record = current, record.id == started.id else { return }
            record.endedAt = Date()
            record.segments = record.segments
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { segment in
                    var segment = segment
                    segment.isFinal = true
                    return segment
                }
            current = record
            upsertLibrary(record)
            await store.saveAndWait(record)
            if skipNotesFor.remove(record.id) != nil {
                finishSession()
                return
            }

            guard !record.segments.isEmpty else {
                AppLog.log("Meetings: no speech captured in \"\(record.title)\"")
                finishSession()
                activities.post(LiveActivity(
                    id: ActivityID.notes, kind: .meeting, priority: 75, duration: 5
                ) {
                    MeetingStatusBand(symbol: "waveform.slash", tint: SparkVTheme.warning,
                                      title: "No speech captured", subtitle: record.title)
                })
                return
            }

            do {
                let notes = try await makeNotes(for: record)
                record.notes = notes
                // Keep anything typed or renamed while the notes were written.
                if let live = current, live.id == record.id {
                    record.userNotes = live.userNotes
                    record.title = live.title
                }
                current = record
                upsertLibrary(record)
                await store.saveAndWait(record)
                SpaceIngestCenter.meeting(record)
                AppLog.log("Meetings: notes ready for \"\(record.title)\" (\(notes.generatedBy))")
                finishSession()
                let mine = notes.myTasks.count
                activities.post(LiveActivity(
                    id: ActivityID.notes, kind: .meeting, priority: 75, duration: 6
                ) {
                    MeetingStatusBand(
                        symbol: "checkmark.circle.fill", tint: .green,
                        title: "Notes ready",
                        subtitle: mine == 0 ? record.title : "\(record.title) · \(mine) task\(mine == 1 ? "" : "s") for you"
                    )
                })
                openNotesWindow(meetingID: record.id)
            } catch {
                AppLog.log("Meetings: summarizing failed: \(error.localizedDescription)")
                if let live = current, live.id == record.id {
                    upsertLibrary(live)
                    store.save(live)
                }
                finishSession()
                fail("Couldn't write notes: \(error.localizedDescription)")
                // The transcript is saved; notes can be regenerated later.
                openNotesWindow(meetingID: record.id)
            }
        }
    }

    // MARK: - Detected calls

    /// The prompt's Start: records the call that is on, titled after its
    /// calendar event (or tab, or app), and opens the notepad. The recording
    /// stops and writes notes on its own when the call ends.
    func startDetectedCall() {
        guard let call = promptedCall ?? callDetector.activeCall else { return }
        startRecording(for: call)
        if phase == .recording { openNotesWindow() }
    }

    /// The prompt's ×: no offer again for this call.
    func dismissDetectedCall() {
        guard let call = promptedCall else { return }
        declinedCallKeys.insert(call.key)
        clearCallPrompt()
    }

    private func updateCallDetection() {
        if isStarted, detectCalls {
            callDetector.start()
        } else {
            callDetector.stop()
            clearCallPrompt()
            declinedCallKeys = []
        }
    }

    func startRecording(for call: DetectedCall) {
        switch phase {
        case .recording, .summarizing: return
        case .idle, .failed: break
        }
        start(title: call.title, calendarEventID: call.calendarEventID)
        guard phase == .recording, let id = current?.id else { return }
        detectorRecording = (id, call.key)
        AppLog.log("Meetings: recording a detected \(call.serviceName) call")
    }

    /// Internal so tests can feed events without a probe.
    func handleCallEvent(_ event: MeetingCallEvent) {
        switch event {
        case .started(let call):
            // No "AppLog" of the title: the log is a plain file.
            AppLog.log("Meetings: \(call.serviceName) call detected")
            if let eventID = call.calendarEventID { MeetingsController.current?.markJoined(eventID: eventID) }
            guard phase == .idle || isFailed, !declinedCallKeys.contains(call.key) else { return }
            // Auto-start never brings up a permission prompt mid-call (the
            // recorder asks only from a user action): until the microphone,
            // speech and Screen Recording were answered, it offers instead.
            if !autoStartDetectedCalls, callOfferOverride?(call) == true { return }
            if autoStartDetectedCalls, Self.canRecordWithoutPrompt {
                startRecording(for: call)
            } else {
                postCallPrompt(call, isNew: true)
            }

        case .updated(let call):
            if let eventID = call.calendarEventID { MeetingsController.current?.markJoined(eventID: eventID) }
            if promptedCall?.key == call.key { postCallPrompt(call, isNew: false) }
            // A recording named "Zoom call" takes the calendar event's name
            // once it shows up, unless the user renamed it.
            if let recording = detectorRecording, recording.callKey == call.key, !call.hasGenericTitle,
               var live = current, live.id == recording.recordID,
               live.title == MeetingCallEvaluator.genericTitle(call.serviceName) {
                live.title = call.title
                if live.calendarEventID == nil { live.calendarEventID = call.calendarEventID }
                current = live
                upsertLibrary(live)
            }

        case .ended(let call):
            AppLog.log("Meetings: \(call.serviceName) call ended")
            declinedCallKeys.remove(call.key)
            if promptedCall?.key == call.key { clearCallPrompt() }
            guard phase == .recording else { return }
            if let recording = detectorRecording, recording.callKey == call.key, current?.id == recording.recordID {
                stop()
            } else {
                activities.post(LiveActivity(
                    id: ActivityID.notes, kind: .meeting, priority: 75, duration: 5
                ) {
                    MeetingStatusBand(symbol: "phone.down.fill", tint: SparkVTheme.warning,
                                      title: "\(call.serviceName) ended", subtitle: "Still recording · stop when you're done")
                })
            }
        }
    }

    /// Recording would start without any system prompt.
    static var canRecordWithoutPrompt: Bool {
        let center = PermissionCenter.shared
        return center.isGranted(.microphone) && center.isGranted(.speech)
            && center.status(.screenRecording) != .notDetermined
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func postCallPrompt(_ call: DetectedCall, isNew: Bool) {
        promptedCall = call
        let icon = MeetingCallIcon.icon(for: call)
        let provider = call.provider
        activities.post(LiveActivity(
            id: ActivityID.callPrompt,
            kind: .meeting,
            priority: Self.callPromptPriority,
            duration: nil,
            opensTab: .today,
            symbol: "waveform",
            tint: SparkVTheme.red,
            compactText: "Notes?",
            peekKey: call.key
        ) {
            MeetingCallPromptBand(call: call, icon: icon)
        }
        .compact {
            MeetingProviderBadge(provider: provider, appIcon: icon, calendarColor: SparkVTheme.red, size: 16)
        } trailing: {
            Text("Notes?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .fixedSize()
        }
        .minimal {
            MeetingProviderBadge(provider: provider, appIcon: icon, calendarColor: SparkVTheme.red, size: 14)
        })
        // A new call announces itself a little longer than the 4 s peek,
        // then rests in the wings ("Notes?") until it ends or is answered.
        if isNew { activities.peek(id: ActivityID.callPrompt, for: 8) }
    }

    private func clearCallPrompt() {
        guard promptedCall != nil else { return }
        promptedCall = nil
        activities.dismiss(id: ActivityID.callPrompt)
    }

    // MARK: - Library actions

    func openNotesWindow(meetingID: UUID? = nil) {
        notesWindow.show(meetingID: meetingID ?? current?.id ?? library.first?.id)
    }

    /// The freshest copy of a meeting: the live one while recording.
    func record(id: UUID) -> MeetingRecord? {
        if let current, current.id == id { return current }
        return library.first { $0.id == id }
    }

    func isLive(_ id: UUID) -> Bool {
        current?.id == id && phase != .idle
    }

    func rename(meetingID: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(meetingID) { $0.title = title }
    }

    /// The user's own notes for a meeting, typed in the notes window. Saved
    /// a moment after typing stops (the live meeting also autosaves).
    func setUserNotes(_ text: String, meetingID: UUID) {
        if var live = current, live.id == meetingID {
            live.userNotes = text
            current = live
            return
        }
        guard let index = library.firstIndex(where: { $0.id == meetingID }) else { return }
        library[index].userNotes = text
        if let pending = pendingNotesSave, pending != meetingID,
           let other = library.first(where: { $0.id == pending }) {
            store.save(other)
        }
        pendingNotesSave = meetingID
        notesSaveTask?.cancel()
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pendingNotesSave = nil
            if let record = self.library.first(where: { $0.id == meetingID }) { self.store.save(record) }
        }
    }

    func setTask(_ taskID: UUID, done: Bool, meetingID: UUID) {
        update(meetingID) { record in
            guard var notes = record.notes else { return }
            if let index = notes.myTasks.firstIndex(where: { $0.id == taskID }) {
                notes.myTasks[index].isDone = done
            } else if let index = notes.othersTasks.firstIndex(where: { $0.id == taskID }) {
                notes.othersTasks[index].isDone = done
            }
            record.notes = notes
        }
    }

    func delete(meetingID: UUID) {
        guard !isLive(meetingID) else { return }
        library.removeAll { $0.id == meetingID }
        if current?.id == meetingID { current = nil }
        store.delete(id: meetingID)
        Task { await MeetingIntelSidecarStore.shared.remove(meetingID) }
    }

    /// Writes fresh notes for a saved meeting.
    func regenerateNotes(meetingID: UUID) {
        guard !isLive(meetingID), !regenerating.contains(meetingID),
              let record = record(id: meetingID), !record.segments.isEmpty else { return }
        regenerating.insert(meetingID)
        Task { [weak self] in
            guard let self else { return }
            defer { regenerating.remove(meetingID) }
            do {
                var notes = try await makeNotes(for: record)
                // Keep checkmarks for tasks that survived.
                if let old = self.record(id: meetingID)?.notes {
                    let done = Set((old.myTasks + old.othersTasks).filter(\.isDone).map { $0.task.lowercased() })
                    for i in notes.myTasks.indices where done.contains(notes.myTasks[i].task.lowercased()) {
                        notes.myTasks[i].isDone = true
                    }
                    for i in notes.othersTasks.indices where done.contains(notes.othersTasks[i].task.lowercased()) {
                        notes.othersTasks[i].isDone = true
                    }
                }
                let finished = notes
                update(meetingID) { $0.notes = finished }
                if let updated = self.record(id: meetingID) { SpaceIngestCenter.meeting(updated) }
                AppLog.log("Meetings: regenerated notes for \"\(record.title)\"")
            } catch {
                AppLog.log("Meetings: regenerating notes failed: \(error.localizedDescription)")
                notesWindow.flash("Couldn't regenerate notes: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Segments and live answers

    private func ingest(_ segment: TranscriptSegment) {
        // Final segments are still flushed while stop() waits on the recorder.
        guard phase == .recording || phase == .summarizing, var record = current else { return }
        if let index = segmentIndex[segment.id], index < record.segments.count,
           record.segments[index].id == segment.id {
            record.segments[index] = segment
        } else {
            segmentIndex[segment.id] = record.segments.count
            record.segments.append(segment)
        }
        current = record

        guard phase == .recording, segment.isFinal, segment.speaker == .others, suggestAnswers else { return }
        let recent = Array(record.segments.suffix(12))
        guard let question = QuestionAnswerer.detectQuestion(
            in: segment, recent: recent, userName: Self.userName
        ) else { return }
        let key = Self.normalize(question)
        guard !key.isEmpty, !answeredQuestions.contains(key) else { return }
        answeredQuestions.insert(key)

        if answerTask != nil {
            pendingQuestion = (question, segment.end)
        } else {
            answer(question, askedAt: segment.end)
        }
    }

    private func answer(_ question: String, askedAt: TimeInterval) {
        guard let meetingID = current?.id else { return }
        let id = UUID()
        activities.post(answerActivity(question: question, answer: nil))

        answerTask = Task { [weak self] in
            guard let self else { return }
            let config = await aiConfig()
            let context = Array((current?.segments ?? []).suffix(60))
            do {
                let text = try await QuestionAnswerer(config: config)
                    .answer(question: question, context: context, userName: Self.userName)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard current?.id == meetingID, !text.isEmpty else { throw CancellationError() }
                let suggestion = SuggestedAnswer(id: id, question: question, answer: text, askedAt: askedAt)
                current?.answers.append(suggestion)
                liveAnswer = suggestion
                if suggestAnswers, phase == .recording {
                    activities.post(answerActivity(question: question, answer: text))
                }
                AppLog.log("Meetings: suggested an answer")
            } catch {
                if !(error is CancellationError) {
                    AppLog.log("Meetings: answering failed: \(error.localizedDescription)")
                }
                activities.dismiss(id: ActivityID.answer)
            }
            answerTask = nil
            if phase == .recording, let next = pendingQuestion {
                pendingQuestion = nil
                answer(next.text, askedAt: next.askedAt)
            }
        }
    }

    private func answerActivity(question: String, answer: String?) -> LiveActivity {
        LiveActivity(
            id: ActivityID.answer, kind: .notification, priority: 80,
            duration: answer == nil ? 20 : 12, height: 48
        ) {
            MeetingAnswerBand(question: question, answer: answer)
        }
    }

    // MARK: - Notes

    private func makeNotes(for record: MeetingRecord) async throws -> MeetingNotes {
        let config = await aiConfig()
        return try await MeetingSummarizer(config: config)
            .summarize(title: record.title, segments: record.segments, userName: Self.userName,
                       userNotes: record.userNotes)
    }

    /// Reads the Groq key off the main thread (the keychain may ask once
    /// after a rebuild), and only when meetings may use it.
    private func aiConfig() async -> MeetingAIConfig {
        guard allowGroqForMeetings else {
            return MeetingAIConfig(useGroq: false, groqKey: nil, groqModel: Self.groqModel)
        }
        let key = await Task.detached(priority: .userInitiated) { ClickyKeychain.load() }.value
        return MeetingAIConfig(useGroq: key != nil, groqKey: key, groqModel: Self.groqModel)
    }

    // MARK: - Helpers

    private func finishSession() {
        detectorRecording = nil
        activities.dismiss(id: ActivityID.recording)
        current = nil
        segmentIndex = [:]
        phase = .idle
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        failureResetTask?.cancel()
        failureResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, case .failed = phase else { return }
            phase = .idle
        }
        activities.post(LiveActivity(
            id: ActivityID.notes, kind: .meeting, priority: 75, duration: 6
        ) {
            MeetingStatusBand(symbol: "exclamationmark.triangle.fill", tint: SparkVTheme.warning,
                              title: "Meeting notes", subtitle: message)
        })
    }

    private func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, phase == .recording, let record = current else { return }
                upsertLibrary(record)
                store.save(record)
            }
        }
    }

    private func update(_ meetingID: UUID, _ change: (inout MeetingRecord) -> Void) {
        if var live = current, live.id == meetingID {
            change(&live)
            current = live
        }
        guard let index = library.firstIndex(where: { $0.id == meetingID }) else {
            if let live = current, live.id == meetingID { upsertLibrary(live); store.save(live) }
            return
        }
        var record = library[index]
        change(&record)
        library[index] = record
        store.save(record)
    }

    private func upsertLibrary(_ record: MeetingRecord) {
        if let index = library.firstIndex(where: { $0.id == record.id }) {
            library[index] = record
        } else {
            library.insert(record, at: 0)
            library.sort { $0.startedAt > $1.startedAt }
        }
    }

    private func postRecordingActivity() {
        guard let started = current?.startedAt else { return }
        let recorder = recorder
        activities.post(LiveActivity(
            id: ActivityID.recording, kind: .meeting, priority: Self.recordingPriority, duration: nil
        ) {
            MeetingRecordingBand(recorder: recorder, startedAt: started)
        })
    }

    private func postSummarizingActivity() {
        let title = current?.title ?? "Meeting"
        activities.post(LiveActivity(
            id: ActivityID.recording, kind: .meeting, priority: Self.recordingPriority, duration: nil
        ) {
            MeetingSummarizingBand(title: title)
        })
    }

    static func defaultTitle(for date: Date) -> String {
        "Meeting · " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private static func normalize(_ question: String) -> String {
        question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Storage

/// One JSON file per meeting. Writes are serialized on this actor so an
/// autosave never races the final save.
actor MeetingLibraryStore {
    nonisolated let directory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("SparkV/Meetings", isDirectory: true)
    }

    nonisolated func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func loadAll() -> [MeetingRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [MeetingRecord] = []
        for file in files where file.pathExtension == "json" {
            do {
                var record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: file))
                // A meeting left open by a crash or force quit.
                if record.endedAt == nil {
                    let last = record.segments.map(\.end).max() ?? 0
                    record.endedAt = record.startedAt.addingTimeInterval(last)
                }
                records.append(record)
            } catch {
                AppLog.log("Meetings: skipped unreadable \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    func write(_ record: MeetingRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(record).write(to: fileURL(for: record.id), options: .atomic)
        } catch {
            AppLog.log("Meetings: save failed: \(error.localizedDescription)")
        }
    }

    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    nonisolated func save(_ record: MeetingRecord) {
        Task { await write(record) }
    }

    nonisolated func saveAndWait(_ record: MeetingRecord) async {
        await write(record)
    }

    nonisolated func delete(id: UUID) {
        Task { await remove(id: id) }
    }

    /// Synchronous save for app termination.
    nonisolated func saveNow(_ record: MeetingRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(record).write(to: fileURL(for: record.id), options: .atomic)
        } catch {
            AppLog.log("Meetings: save at quit failed: \(error.localizedDescription)")
        }
    }

    private static func encode(_ record: MeetingRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }
}

// MARK: - Formatting

enum MeetingFormat {
    /// "4:07" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "45 min", "1 h 5 min", "< 1 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    static func duration(of record: MeetingRecord, now: Date = Date()) -> TimeInterval {
        (record.endedAt ?? now).timeIntervalSince(record.startedAt)
    }

    // MARK: Markdown

    static func markdown(for record: MeetingRecord) -> String {
        var out: [String] = []
        out.append("# \(record.title)")
        let date = record.startedAt.formatted(date: .complete, time: .shortened)
        out.append("_\(date) · \(duration(duration(of: record)))_")
        out.append("")

        if let notes = record.notes {
            if !notes.myTasks.isEmpty {
                out.append("## \(MeetingAssistant.userName)'s tasks")
                out += notes.myTasks.map(taskLine)
                out.append("")
            }
            if !notes.summary.isEmpty {
                out.append("## Minutes of meeting")
                out.append(notes.summary)
                out.append("")
            }
            section("Key points", notes.keyPoints, into: &out)
            section("Decisions", notes.decisions, into: &out)
            if !notes.othersTasks.isEmpty {
                out.append("## Others' tasks")
                for (owner, tasks) in groupedByOwner(notes.othersTasks) {
                    out.append("### \(owner)")
                    out += tasks.map(taskLine)
                }
                out.append("")
            }
            section("Open questions", notes.openQuestions, into: &out)
            section("Next steps", notes.nextSteps, into: &out)
            out.append("_Notes by \(notes.generatedBy)_")
            out.append("")
        }

        if let mine = record.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !mine.isEmpty {
            out.append("## My notes")
            out.append(mine)
            out.append("")
        }

        if !record.answers.isEmpty {
            out.append("## Suggested answers")
            for answer in record.answers {
                out.append("- **Q (\(clock(answer.askedAt))):** \(answer.question)")
                out.append("  **A:** \(answer.answer)")
            }
            out.append("")
        }

        if !record.segments.isEmpty {
            out.append("## Transcript")
            for segment in record.segments {
                let who = segment.speaker == .me ? MeetingAssistant.userName : "Others"
                out.append("**[\(clock(segment.start))] \(who):** \(segment.text)")
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    static func groupedByOwner(_ tasks: [ActionItem]) -> [(String, [ActionItem])] {
        let groups = Dictionary(grouping: tasks) { task -> String in
            let owner = task.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            return owner.isEmpty ? "Unassigned" : owner
        }
        return groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, groups[$0] ?? []) }
    }

    private static func taskLine(_ task: ActionItem) -> String {
        var line = "- [\(task.isDone ? "x" : " ")] \(task.task)"
        if let due = task.due, !due.isEmpty { line += " _(due \(due))_" }
        return line
    }

    private static func section(_ title: String, _ items: [String], into out: inout [String]) {
        guard !items.isEmpty else { return }
        out.append("## \(title)")
        out += items.map { "- \($0)" }
        out.append("")
    }

    // MARK: Apple Notes HTML

    static func notesHTML(for record: MeetingRecord) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func list(_ items: [String]) -> String {
            "<ul>" + items.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        }
        func tasks(_ items: [ActionItem]) -> String {
            list(items.map { task in
                (task.isDone ? "☑ " : "☐ ") + task.task + (task.due.map { $0.isEmpty ? "" : " (due \($0))" } ?? "")
            })
        }
        var html = "<h1>\(esc(record.title))</h1>"
        html += "<p><i>\(esc(record.startedAt.formatted(date: .complete, time: .shortened))) · \(esc(duration(duration(of: record))))</i></p>"
        if let notes = record.notes {
            if !notes.myTasks.isEmpty {
                html += "<h2>\(esc(MeetingAssistant.userName))'s tasks</h2>" + tasks(notes.myTasks)
            }
            if !notes.summary.isEmpty { html += "<h2>Minutes of meeting</h2><p>\(esc(notes.summary))</p>" }
            if !notes.keyPoints.isEmpty { html += "<h2>Key points</h2>" + list(notes.keyPoints) }
            if !notes.decisions.isEmpty { html += "<h2>Decisions</h2>" + list(notes.decisions) }
            if !notes.othersTasks.isEmpty {
                html += "<h2>Others' tasks</h2>"
                for (owner, items) in groupedByOwner(notes.othersTasks) {
                    html += "<h3>\(esc(owner))</h3>" + tasks(items)
                }
            }
            if !notes.openQuestions.isEmpty { html += "<h2>Open questions</h2>" + list(notes.openQuestions) }
            if !notes.nextSteps.isEmpty { html += "<h2>Next steps</h2>" + list(notes.nextSteps) }
        }
        if let mine = record.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !mine.isEmpty {
            html += "<h2>My notes</h2>" + mine.components(separatedBy: .newlines).map { "<p>\(esc($0))</p>" }.joined()
        }
        if record.notes == nil, !record.segments.isEmpty {
            html += "<h2>Transcript</h2>"
            html += record.segments.map { segment in
                let who = segment.speaker == .me ? MeetingAssistant.userName : "Others"
                return "<p><b>[\(clock(segment.start))] \(esc(who)):</b> \(esc(segment.text))</p>"
            }.joined()
        }
        return html
    }
}

// MARK: - Apple Notes

enum MeetingNotesExporter {
    enum Failure: LocalizedError {
        case notAuthorized
        case script(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "SparkV isn't allowed to control Notes. Turn it on in System Settings › Privacy & Security › Automation."
            case .script(let message):
                message
            }
        }
    }

    static let notesBundleID = "com.apple.Notes"

    /// Creates a note in Apple Notes. Runs osascript off the main thread so
    /// launching Notes (or the one-time Automation prompt) never blocks the UI.
    static func saveToAppleNotes(title: String, html: String) async throws {
        try await checkAutomation()
        let result: (status: Int32, error: String) = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "on run argv",
                "-e", "tell application \"Notes\" to make new note with properties {name:(item 1 of argv), body:(item 2 of argv)}",
                "-e", "end run",
                title, html,
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value

        guard result.status != 0 else { return }
        if result.error.contains("-1743") || result.error.localizedCaseInsensitiveContains("not authorized") {
            throw Failure.notAuthorized
        }
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure.script(message.isEmpty ? "Notes didn't accept the note." : message)
    }

    /// While Notes runs macOS can answer without asking: a refusal fails
    /// fast, and a first-time ask goes through PermissionCenter's queue
    /// instead of popping up from the osascript child. When Notes isn't
    /// running, osascript launches it and macOS asks then (first time only).
    @MainActor
    private static func checkAutomation() async throws {
        let center = PermissionCenter.shared
        let notes = PermissionCenter.Permission.automation(bundleID: notesBundleID)
        switch await center.freshStatus(notes) {
        case .denied, .restricted:
            throw Failure.notAuthorized
        case .notDetermined:
            let status = await center.request(notes, from: "Meeting notes")
            if status == .denied || status == .restricted { throw Failure.notAuthorized }
        default:
            break
        }
    }
}
