import AppKit
import Combine
import SwiftUI

/// Live translation band: while a meeting records, the latest speech from
/// other participants is translated into the user's language and shown under
/// the notch (and, optionally, in a floating caption window like macOS Live
/// Captions). The translated transcript is saved per meeting and can be added
/// to the meeting's notes.
///
/// Wiring: create once, `attach(to:)` the MeetingAssistant, `stop()` at quit.
/// See INTEGRATION.md.
@MainActor
final class LiveTranslationController: ObservableObject {
    enum Status: Equatable {
        /// The feature is turned off.
        case off
        /// On, waiting for a meeting to record.
        case waiting
        /// A meeting is recording; nothing translated yet.
        case listening
        case translating(LiveTranslationEngineKind)
        /// Apple Translation can do this pair after a one-time download.
        case needsDownload(source: String, target: String)
        case unavailable(String)
    }

    // MARK: Settings

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? enableNow() : disableNow()
        }
    }

    /// Target language id ("en", "es", "zh-Hans").
    @Published var targetLanguage: String {
        didSet {
            guard targetLanguage != oldValue else { return }
            defaults.set(targetLanguage, forKey: Keys.target)
            pipeline.target = LiveTranslationLanguages.language(targetLanguage)
            pendingDownload = nil
            checkExpectedPair()
            if isEnabled { prewarm() }
        }
    }

    /// Show the band under the notch while translating.
    @Published var showsInNotch: Bool {
        didSet {
            defaults.set(showsInNotch, forKey: Keys.showsInNotch)
            if !showsInNotch { dismissBand() }
        }
    }

    /// Also show a larger floating caption window during meetings.
    @Published var showsCaptionWindow: Bool {
        didSet {
            guard showsCaptionWindow != oldValue else { return }
            defaults.set(showsCaptionWindow, forKey: Keys.captionWindow)
            if showsCaptionWindow, isEnabled, sessionActive { captionWindow.show() }
            if !showsCaptionWindow { captionWindow.close() }
        }
    }

    /// Show the original words under each translation (caption window).
    @Published var showsOriginal: Bool {
        didSet { defaults.set(showsOriginal, forKey: Keys.showsOriginal) }
    }

    /// Translate the user's own microphone speech too (off: only others).
    @Published var translatesMySpeech: Bool {
        didSet {
            defaults.set(translatesMySpeech, forKey: Keys.mySpeech)
            pipeline.speakers = translatesMySpeech ? [.me, .others] : [.others]
        }
    }

    /// What other participants speak (a speech locale such as "es-ES"; empty
    /// = the Mac's language). MeetingTranscriber reads it at the start of a
    /// recording through `LiveTranslationSpokenLanguage` (INTEGRATION.md).
    @Published var othersSpeak: String {
        didSet {
            guard othersSpeak != oldValue else { return }
            defaults.set(othersSpeak, forKey: Keys.othersSpeak)
            pipeline.setTranscriberLanguage(othersSpokenLanguage, for: .others)
            pendingDownload = nil
            checkExpectedPair()
            if isEnabled, sessionActive { prewarm() }
        }
    }

    /// "Allow Live Translation to use my Groq key". Off by default.
    @Published var allowGroq: Bool {
        didSet {
            defaults.set(allowGroq, forKey: Keys.allowGroq)
            if !allowGroq { groqKey = nil; groqKeyLoaded = false }
        }
    }

    // MARK: State

    @Published private(set) var status: Status = .off
    /// The last few captions that needed translation, oldest first.
    @Published private(set) var captions: [LiveTranslatedLine] = []
    /// Captions translated in this meeting so far (finals and the live one).
    @Published private(set) var lineCount = 0
    @Published private(set) var meetingTitle: String?
    @Published private(set) var meetingStartedAt: Date?
    /// The meeting whose translation is shown (kept after it ends, until the next).
    @Published private(set) var meetingID: UUID?
    /// True while the meeting is recording.
    @Published private(set) var isRecording = false
    /// Targets for the picker, sorted by name.
    @Published private(set) var targets: [String] = LiveTranslationLanguages.fallbackTargets
    /// Seconds the last translation took.
    @Published private(set) var lastLatency: TimeInterval?
    /// Shown briefly after "Add to Meeting Notes".
    @Published private(set) var notesMessage: String?

    /// The caption the band shows: the newest one.
    var bandCaption: LiveTranslatedLine? { captions.last }

    static let bandActivityID = "meeting.translation"
    /// Above the recording band (65) it replaces while captions flow, below
    /// notifications (70) and suggested answers (80).
    static let bandPriority = 66
    static let bandHeight: CGFloat = 48
    /// The band gives the notch back to the recording indicator after this
    /// long without new speech.
    static let bandIdleSeconds: TimeInterval = 9

    // MARK: Private

    private enum Keys {
        static let enabled = "liveTranslation.enabled"
        static let target = "liveTranslation.target"
        static let showsInNotch = "liveTranslation.showsInNotch"
        static let captionWindow = "liveTranslation.captionWindow"
        static let showsOriginal = "liveTranslation.showsOriginal"
        static let mySpeech = "liveTranslation.mySpeech"
        static let allowGroq = "liveTranslation.allowGroq"
        static let othersSpeak = LiveTranslationSpokenLanguage.defaultsKey
    }

    private let defaults: UserDefaults
    private let activities: ActivityCenter
    private weak var assistant: MeetingAssistant?
    private var subscriptions: Set<AnyCancellable> = []
    let apple = LiveTranslationAppleEngine()
    private(set) lazy var pipeline: LiveTranslationPipeline = makePipeline()
    private lazy var captionWindow = LiveTranslationCaptionWindowController(controller: self)
    private lazy var downloadWindow = LiveTranslationDownloadWindowController(controller: self)
    private var sessionActive = false
    private var latestSegments: [TranscriptSegment] = []
    private var bandPosted = false
    private var bandIdleTask: Task<Void, Never>?
    private var endTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var groqKey: String?
    private var groqKeyLoaded = false
    private var pendingDownload: (source: String, target: String)?
    /// Meetings whose translation should go into the notes once they end.
    private var notesAfterEnd: Set<UUID> = []
    /// The exact block last inserted into each meeting's notes, so adding
    /// again replaces it instead of duplicating it.
    private var insertedBlocks: [UUID: String] = [:]
    /// Translator override for tests.
    var translatorOverride: LiveTranslationPipeline.Translator?
    /// Where transcripts are saved (tests use a temp folder).
    var transcriptDirectory = LiveTranslationTranscript.directory

    init(activities: ActivityCenter, defaults: UserDefaults = .standard) {
        self.activities = activities
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        targetLanguage = defaults.string(forKey: Keys.target) ?? LiveTranslationLanguages.defaultTarget
        showsInNotch = defaults.object(forKey: Keys.showsInNotch) as? Bool ?? true
        showsCaptionWindow = defaults.object(forKey: Keys.captionWindow) as? Bool ?? false
        showsOriginal = defaults.object(forKey: Keys.showsOriginal) as? Bool ?? true
        translatesMySpeech = defaults.object(forKey: Keys.mySpeech) as? Bool ?? false
        allowGroq = defaults.object(forKey: Keys.allowGroq) as? Bool ?? false
        othersSpeak = defaults.string(forKey: Keys.othersSpeak) ?? ""
        status = isEnabled ? .waiting : .off
    }

    /// The language other participants are transcribed in.
    var othersSpokenLanguage: Locale.Language? {
        othersSpeak.isEmpty ? nil : Locale.Language(identifier: othersSpeak)
    }

    /// The source language a meeting most likely needs translated.
    private var expectedSource: Locale.Language {
        othersSpokenLanguage ?? Locale.current.language
    }

    // MARK: Lifecycle

    /// Subscribes to the meeting assistant: `$phase` starts/ends a session,
    /// `$current` carries the live transcript (every segment insert/replace).
    func attach(to assistant: MeetingAssistant) {
        self.assistant = assistant
        subscriptions = []
        // @Published emits before the value is stored: read the new phase from
        // the emitted value and the record on the next turn.
        assistant.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                Task { @MainActor [weak self] in self?.phaseChanged(phase) }
            }
            .store(in: &subscriptions)
        assistant.$current
            .sink { [weak self] record in
                self?.recordChanged(record)
            }
            .store(in: &subscriptions)
        loadTargets()
        checkExpectedPair()
    }

    /// Call at quit: saves the transcript, stops translating, closes windows.
    func stop() {
        subscriptions = []
        if sessionActive { saveTranscript() }
        bandIdleTask?.cancel()
        endTask?.cancel()
        messageTask?.cancel()
        pipeline.reset()
        dismissBand()
        apple.bridge.tearDown()
        LiveTranslationModelEngine.releasePrewarmed()
        captionWindow.close()
        downloadWindow.close()
        sessionActive = false
        groqKey = nil
        groqKeyLoaded = false
    }

    // MARK: Meeting events

    /// Drives a session from the meeting phase. Public for tests.
    func phaseChanged(_ phase: MeetingAssistant.Phase) {
        switch phase {
        case .recording:
            isRecording = true
            if isEnabled, let record = assistant?.current { beginSession(record) }
        case .summarizing:
            // stop() marks the remaining volatile segments final and stores
            // them: keep observing so they get translated.
            isRecording = false
            pipeline.dropPartials()
            dismissBand()
        case .idle, .failed:
            isRecording = false
            if sessionActive {
                endSession()
            } else {
                // "Add to notes" was asked for, then the feature turned off
                // before the meeting ended: add the saved translation now.
                addDeferredNotes()
            }
        }
    }

    private func addDeferredNotes() {
        guard let assistant else { return }
        let ready = notesAfterEnd.filter { !assistant.isLive($0) }
        guard !ready.isEmpty else { return }
        notesAfterEnd.subtract(ready)
        Task { [weak self] in
            for id in ready { _ = await self?.addToMeetingNotes(meetingID: id) }
        }
    }

    /// Feeds a transcript snapshot. Public for tests.
    func recordChanged(_ record: MeetingRecord?) {
        guard let record, sessionActive, record.id == meetingID else { return }
        latestSegments = record.segments
        pipeline.observe(record.segments)
    }

    /// Starts translating `record`. Called on the recording phase, or when the
    /// feature is turned on mid-meeting (only speech from then on, plus the
    /// last phrase, is translated live; the rest is backfilled on save).
    func beginSession(_ record: MeetingRecord) {
        if sessionActive, meetingID == record.id {
            endTask?.cancel()
            return
        }
        endTask?.cancel()
        if sessionActive {
            // The previous meeting is still finishing (its last phrases were
            // being translated): keep what it has rather than dropping it.
            saveTranscript()
            pipeline.reset()
            sessionActive = false
            addDeferredNotes()
        }
        sessionActive = true
        meetingID = record.id
        meetingTitle = record.title
        meetingStartedAt = record.startedAt
        captions = []
        lineCount = 0
        insertedBlocks[record.id] = nil
        latestSegments = record.segments
        pipeline.reset()
        pipeline.speakers = translatesMySpeech ? [.me, .others] : [.others]
        pipeline.target = LiveTranslationLanguages.language(targetLanguage)
        pipeline.setTranscriberLanguage(othersSpokenLanguage, for: .others)
        pipeline.start(from: record.segments, keepLast: 2)
        status = pendingDownload.map { .needsDownload(source: $0.source, target: $0.target) } ?? .listening
        prewarm()
        if showsCaptionWindow { captionWindow.show() }
        AppLog.log("Live Translation: started (target \(targetLanguage))")
    }

    private func endSession() {
        guard sessionActive else { return }
        pipeline.dropPartials()
        dismissBand()
        endTask?.cancel()
        let id = meetingID
        endTask = Task { [weak self] in
            guard let self else { return }
            await pipeline.drain()
            guard !Task.isCancelled, meetingID == id else { return }
            sessionActive = false
            saveTranscript()
            if let id, notesAfterEnd.remove(id) != nil {
                _ = await addToMeetingNotes(meetingID: id)
            }
            groqKey = nil
            groqKeyLoaded = false
            LiveTranslationModelEngine.releasePrewarmed()
            status = isEnabled ? .waiting : .off
            AppLog.log("Live Translation: ended (\(lineCount) caption(s))")
        }
    }

    private func enableNow() {
        status = .waiting
        loadTargets()
        checkExpectedPair()
        if let assistant, assistant.phase == .recording, let record = assistant.current {
            isRecording = true
            beginSession(record)
        }
    }

    private func disableNow() {
        if sessionActive {
            saveTranscript()
            pipeline.reset()
            sessionActive = false
        }
        endTask?.cancel()
        apple.bridge.cancelAll()
        dismissBand()
        captionWindow.close()
        LiveTranslationModelEngine.releasePrewarmed()
        groqKey = nil
        groqKeyLoaded = false
        status = .off
    }

    // MARK: Translation routing

    private func makePipeline() -> LiveTranslationPipeline {
        let pipeline = LiveTranslationPipeline(
            target: LiveTranslationLanguages.language(targetLanguage),
            speakers: translatesMySpeech ? [.me, .others] : [.others],
            translator: { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.translate(request)
            }
        )
        pipeline.onUpdate = { [weak self] line in self?.captionUpdated(line) }
        pipeline.onError = { [weak self] error, request in self?.translationFailed(error, request) }
        return pipeline
    }

    /// Apple Translation first; the on-device model, then Groq (if allowed)
    /// when the pair isn't installed or fails.
    private func translate(_ request: LiveTranslationPipeline.Request) async throws -> (text: String, engine: LiveTranslationEngineKind) {
        let started = Date()
        if let translatorOverride {
            let result = try await translatorOverride(request)
            return finish(result.text, result.engine, started)
        }
        let source = LiveTranslationLanguages.id(request.source)
        let target = LiveTranslationLanguages.id(request.target)
        var lastError: Error = LiveTranslationError.noTranslator

        switch await apple.status(source: request.source, target: request.target) {
        case .installed:
            do {
                let text = try await apple.translate(request.text, source: request.source, target: request.target)
                return finish(text, .apple, started)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case LiveTranslationError.notInstalled = error { pendingDownload = (source, target) }
            }
        case .needsDownload:
            pendingDownload = (source, target)
            lastError = LiveTranslationError.notInstalled(source: source, target: target)
        case .unsupported:
            lastError = LiveTranslationError.unsupportedPair(source: source, target: target)
        }

        if LiveTranslationModelEngine.isAvailable {
            do {
                let text = try await LiveTranslationModelEngine.translate(request.text, source: source, target: target)
                return finish(text, .onDeviceModel, started)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if allowGroq, let key = await loadGroqKey() {
            do {
                let text = try await LiveTranslationGroqEngine.translate(request.text, source: source, target: target, key: key)
                return finish(text, .groq, started)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func finish(_ text: String, _ engine: LiveTranslationEngineKind, _ started: Date) -> (text: String, engine: LiveTranslationEngineKind) {
        lastLatency = Date().timeIntervalSince(started)
        // The language models are slower: re-translate a growing phrase less often.
        pipeline.partialInterval = engine == .apple ? 0.6 : 2.0
        if sessionActive {
            if engine == .apple || pendingDownload == nil {
                status = .translating(engine)
            } else if let pending = pendingDownload {
                status = .needsDownload(source: pending.source, target: pending.target)
            }
        }
        return (text, engine)
    }

    private func loadGroqKey() async -> String? {
        if groqKeyLoaded { return groqKey }
        let key = await Task.detached(priority: .userInitiated) { ClickyKeychain.load() }.value
        groqKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        groqKeyLoaded = true
        return groqKey
    }

    private func translationFailed(_ error: Error, _ request: LiveTranslationPipeline.Request) {
        // Never log the caption text.
        AppLog.log("Live Translation: \(LiveTranslationLanguages.id(request.source))→\(LiveTranslationLanguages.id(request.target)) failed: \(error.localizedDescription)")
        guard sessionActive else { return }
        if let pending = pendingDownload {
            status = .needsDownload(source: pending.source, target: pending.target)
        } else if !request.isPartial {
            status = .unavailable(error.localizedDescription)
        }
    }

    private func prewarm() {
        let source = expectedSource
        let target = LiveTranslationLanguages.language(targetLanguage)
        guard !LiveTranslationLanguages.isSame(source, target) else { return }
        Task { [weak self] in
            guard let self else { return }
            if await apple.status(source: source, target: target) == .installed {
                await apple.prewarm(source: source, target: target)
            } else {
                LiveTranslationModelEngine.prewarm(source: LiveTranslationLanguages.id(source), target: targetLanguage)
            }
        }
    }

    /// Checks the pair the meeting will most likely need (the transcriber's
    /// language into the target) so the menu can offer the download early.
    private func checkExpectedPair() {
        let source = expectedSource
        let target = LiveTranslationLanguages.language(targetLanguage)
        guard !LiveTranslationLanguages.isSame(source, target) else { return }
        Task { [weak self] in
            guard let self else { return }
            if await apple.status(source: source, target: target) == .needsDownload {
                pendingDownload = (LiveTranslationLanguages.id(source), targetLanguage)
                if isEnabled, case .waiting = status {
                    status = .needsDownload(source: LiveTranslationLanguages.id(source), target: targetLanguage)
                }
            }
        }
    }

    private func loadTargets() {
        Task { [weak self] in
            guard let self else { return }
            let languages = await apple.supportedLanguages()
            var ids = Set(LiveTranslationLanguages.fallbackTargets)
            for language in languages { ids.insert(LiveTranslationLanguages.normalizedTarget(language)) }
            ids.insert(targetLanguage)
            targets = ids.sorted {
                LiveTranslationLanguages.displayName($0).localizedCaseInsensitiveCompare(LiveTranslationLanguages.displayName($1)) == .orderedAscending
            }
        }
    }

    // MARK: Captions and band

    private func captionUpdated(_ line: LiveTranslatedLine) {
        lineCount = pipeline.lines.count
        // Speech already in the user's language isn't captioned.
        guard !line.isOriginal else {
            if let index = captions.firstIndex(where: { $0.id == line.id }) { captions.remove(at: index) }
            return
        }
        if let index = captions.firstIndex(where: { $0.id == line.id }) {
            captions[index] = line
        } else {
            captions.append(line)
            captions.sort { $0.start < $1.start }
            if captions.count > 6 { captions.removeFirst(captions.count - 6) }
        }
        guard sessionActive, isRecording else { return }
        postBand()
    }

    private func postBand() {
        guard showsInNotch, let started = meetingStartedAt else { return }
        // Keep the "Let participants know you're recording" reminder visible.
        guard Date().timeIntervalSince(started) >= 10 else { return }
        if !bandPosted {
            bandPosted = true
            activities.post(LiveActivity(
                id: Self.bandActivityID, kind: .meeting, priority: Self.bandPriority,
                duration: nil, height: Self.bandHeight
            ) { [weak self] in
                if let self {
                    LiveTranslationBand(controller: self, startedAt: started)
                }
            })
        }
        bandIdleTask?.cancel()
        bandIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.bandIdleSeconds))
            guard !Task.isCancelled else { return }
            self?.dismissBand()
        }
    }

    private func dismissBand() {
        bandIdleTask?.cancel()
        guard bandPosted else { return }
        bandPosted = false
        activities.dismiss(id: Self.bandActivityID)
    }

    // MARK: Transcript

    /// The translated transcript of the shown meeting.
    var transcript: LiveTranslationTranscript? {
        guard let meetingID else { return nil }
        return LiveTranslationTranscript(
            meetingID: meetingID, title: meetingTitle ?? "Meeting",
            startedAt: meetingStartedAt ?? Date(), targetLanguage: targetLanguage,
            lines: pipeline.lines.filter(\.isFinal)
        )
    }

    private func saveTranscript() {
        guard let transcript, !transcript.lines.isEmpty else { return }
        do {
            try transcript.write(to: transcriptDirectory)
        } catch {
            AppLog.log("Live Translation: saving the transcript failed: \(error.localizedDescription)")
        }
    }

    /// Adds the translated transcript to the meeting's notes (the notepad in
    /// the Meeting Notes window). While the meeting is still running it is
    /// added when it ends, so the minutes are written from the transcript
    /// rather than from a copy of it. Adding again replaces the earlier block.
    @discardableResult
    func addToMeetingNotes(meetingID requested: UUID? = nil) async -> Bool {
        guard let assistant, let id = requested ?? meetingID else {
            flash("No meeting to add to")
            return false
        }
        if assistant.isLive(id) {
            notesAfterEnd.insert(id)
            flash("Will be added to the notes when the meeting ends")
            return true
        }
        guard let record = assistant.record(id: id) else {
            flash("Meeting not found")
            return false
        }
        var transcript: LiveTranslationTranscript?
        if id == meetingID, sessionActive || !pipeline.lines.isEmpty {
            // Translate anything said before the feature was turned on.
            await pipeline.backfill(record.segments)
            transcript = self.transcript
        } else {
            transcript = LiveTranslationTranscript.load(meetingID: id, from: transcriptDirectory)
        }
        guard let transcript, !transcript.lines.isEmpty else {
            flash("Nothing was translated in this meeting")
            return false
        }
        try? transcript.write(to: transcriptDirectory)
        let block = transcript.notesBlock()
        let notes = Self.merge(block: block, previous: insertedBlocks[id], into: record.userNotes ?? "")
        assistant.setUserNotes(notes, meetingID: id)
        insertedBlocks[id] = block
        flash("Added to meeting notes")
        return true
    }

    /// Replaces the previously inserted block when it is still there
    /// unchanged; otherwise appends after the user's own notes.
    static func merge(block: String, previous: String?, into notes: String) -> String {
        if let previous, let range = notes.range(of: previous) {
            return notes.replacingCharacters(in: range, with: block)
        }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? block : trimmed + "\n\n" + block
    }

    /// Markdown of the translated transcript (copy / export).
    func transcriptMarkdown() -> String? {
        transcript?.markdown()
    }

    func copyTranscript() {
        guard let markdown = transcriptMarkdown() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        flash("Copied")
    }

    private func flash(_ message: String) {
        notesMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notesMessage = nil
        }
    }

    // MARK: Windows and downloads

    func openCaptionWindow() { captionWindow.show() }

    /// The pair Apple Translation needs downloaded, if any.
    var downloadPair: (source: String, target: String)? { pendingDownload }

    /// Opens the window that asks macOS to download the languages (the
    /// system shows its own consent sheet).
    func requestLanguageDownload() {
        let pair = pendingDownload ?? (LiveTranslationLanguages.id(expectedSource), targetLanguage)
        downloadWindow.show(source: pair.source, target: pair.target)
    }

    /// Called by the download window after macOS finished the download.
    func languagesDownloaded() {
        apple.refreshStatuses()
        pendingDownload = nil
        if sessionActive { status = .listening } else if isEnabled { status = .waiting }
        prewarm()
    }

    var statusText: String {
        switch status {
        case .off: return "Off"
        case .waiting: return "Starts with the next recorded meeting"
        case .listening: return "Listening…"
        case .translating(let engine): return "Translating with \(engine.label)"
        case .needsDownload(let source, let target):
            return "Download \(LiveTranslationLanguages.displayName(source)) → \(LiveTranslationLanguages.displayName(target)) for on-device translation"
        case .unavailable(let reason): return reason
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
