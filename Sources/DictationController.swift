import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Speech

/// Wispr Flow-style dictation: hold the hotkey and talk, release to type the
/// cleaned-up text into the focused app.
///
/// - Hold the hotkey (fn / Globe by default) to talk; releasing it finishes.
/// - Double-tap the hotkey, or press hotkey+Space, for hands-free mode; press
///   the hotkey again (or the Dictate button) to finish.
/// - Esc cancels without typing anything.
/// - Ctrl+Cmd+V pastes the last dictation again, Ctrl+Cmd+C copies it.
///
/// Every dictation is recorded in `FlowStore` (raw and formatted text plus
/// the app it was typed into). Two other modes reuse the same capture path:
/// note dictation (`startNoteDictation`, formatted, handed back instead of
/// typed) and command capture (`startCommandCapture`, the raw transcript for
/// the Clicky assistant; `phase` stays `.idle` so the dictation band stays hidden).
///
/// Speech is transcribed on-device (SpeechAnalyzer/SpeechTranscriber on
/// macOS 26+, SFSpeechRecognizer with on-device recognition otherwise),
/// cleaned up by `DictationFormatter` and typed by `TextInserter`.
///
/// Permissions: Microphone and Speech Recognition are requested the first
/// time dictation starts. Accessibility is needed for the global hotkey and
/// for typing into other apps. For the fn key, set System Settings > Keyboard
/// > "Press 🌐 key to" = "Do Nothing" and pick a Dictation shortcut other
/// than fn, so macOS does not open the emoji picker or its own dictation.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case formatting
        case done(String)
        case failed(String)
    }

    enum Hotkey: String, CaseIterable {
        case fn
        case rightOption
        case off

        var title: String {
            switch self {
            case .fn: "fn (Globe)"
            case .rightOption: "Right Option"
            case .off: "Off"
            }
        }

        var monitorKey: PushToTalkMonitor.Key? {
            switch self {
            case .fn: .fn
            case .rightOption: .rightOption
            case .off: nil
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Live partial transcript while listening.
    @Published private(set) var liveText = ""
    /// Microphone level 0...1 for the waveform.
    @Published private(set) var level: Float = 0
    @Published private(set) var isHandsFree = false
    /// The current session dictates into a new Flow note instead of the focused app.
    @Published private(set) var isDictatingNote = false
    /// Listening for a spoken question (Clicky). `liveText` and `level` update,
    /// `phase` stays `.idle`.
    @Published private(set) var isCapturingCommand = false

    var isActive: Bool { phase == .listening || phase == .formatting }

    /// What stops a hands-free session, for the live band ("fn to stop").
    var hotkeyHint: String {
        switch hotkey {
        case .fn: "fn to stop"
        case .rightOption: "Right ⌥ to stop"
        case .off: "Dictate to stop"
        }
    }

    /// Ctrl+Cmd+V pastes and Ctrl+Cmd+C copies the last dictation.
    @Published var historyShortcutsEnabled: Bool {
        didSet {
            guard historyShortcutsEnabled != oldValue else { return }
            UserDefaults.standard.set(historyShortcutsEnabled, forKey: Keys.historyShortcuts)
            AppLog.log("Dictation: history shortcuts \(historyShortcutsEnabled ? "on" : "off")")
            if started { applyHotkey() }
        }
    }

    @Published var hotkey: Hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            UserDefaults.standard.set(hotkey.rawValue, forKey: Keys.hotkey)
            AppLog.log("Dictation: hotkey set to \(hotkey.rawValue)")
            if started { applyHotkey() }
        }
    }

    @Published var formattingEnabled: Bool {
        didSet {
            guard formattingEnabled != oldValue else { return }
            UserDefaults.standard.set(formattingEnabled, forKey: Keys.formatting)
        }
    }

    private enum Keys {
        static let hotkey = "dictation.hotkey"
        static let formatting = "dictation.formattingEnabled"
        static let historyShortcuts = "dictation.historyShortcutsEnabled"
    }

    /// A press shorter than this is a tap (half of a double-tap), not a hold.
    private static let tapThreshold: TimeInterval = 0.3
    /// Second press must follow a tap within this window to lock hands-free.
    private static let doubleTapWindow: TimeInterval = 0.4
    /// Another key within this time of pressing the hotkey means a shortcut.
    private static let chordWindow: TimeInterval = 1.0
    /// Safety stop for forgotten hands-free sessions.
    private static let maximumDuration: TimeInterval = 6 * 60
    /// Safety stop for a command capture nobody finished.
    private static let maximumCommandDuration: TimeInterval = 2 * 60

    private let monitor = PushToTalkMonitor()
    private let formatter = DictationFormatter.shared
    private var recorder: DictationRecorder?
    /// Bumped by every new session and every cancel; stale async work checks it.
    private var sessionID = 0
    private var started = false
    private var pressedAt: TimeInterval = 0
    /// Name of the app that had focus when the session began, for the history.
    private var targetAppName: String?
    /// Receives the formatted note text (nil when cancelled or failed).
    private var noteCompletion: (@MainActor (String?) -> Void)?
    /// `finishCommandCapture()` is stopping the recorder.
    private var isStoppingCommand = false

    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var pendingTapTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    /// Re-creates the key tap when Accessibility is granted (or re-granted).
    private var accessibilityWatch: AnyCancellable?
    private var commandTimeoutTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        hotkey = defaults.string(forKey: Keys.hotkey).flatMap(Hotkey.init(rawValue:)) ?? .fn
        formattingEnabled = defaults.object(forKey: Keys.formatting) as? Bool ?? true
        historyShortcutsEnabled = defaults.object(forKey: Keys.historyShortcuts) as? Bool ?? true
    }

    /// The monitor also serves the history shortcuts while the hotkey is off.
    private var needsMonitor: Bool { hotkey != .off || historyShortcutsEnabled }

    /// A microphone session (dictation, note or command) is running.
    private var isBusy: Bool { isActive || isCapturingCommand }

    // MARK: - Public API

    /// Installs push-to-talk monitoring. Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        monitor.onEvent = { [weak self] event, time in
            self?.handleKey(event, at: time)
        }
        applyHotkey()
    }

    /// Dictate button: starts hands-free dictation, or finishes and types it.
    func toggleHandsFree() {
        guard !isCapturingCommand else { return }
        switch phase {
        case .listening:
            AppLog.log("Dictation: stop (button)")
            finish()
        case .formatting:
            break
        case .idle, .done, .failed:
            beginSession(handsFree: true, trigger: "button")
        }
    }

    /// Discards the current dictation without typing anything.
    func cancel() {
        guard phase != .idle else { return }
        if isActive { AppLog.log("Dictation: cancelled") }
        sessionID += 1
        startTask?.cancel()
        finishTask?.cancel()
        startTask = nil
        finishTask = nil
        if let recorder {
            self.recorder = nil
            Task { await recorder.cancel() }
        }
        resetToIdle()
    }

    /// Teardown on quit.
    func shutdown() {
        cancel()
        cancelCommandCapture()
        accessibilityWatch = nil
        resetTask?.cancel()
        monitor.stop()
        monitor.onEvent = nil
        started = false
    }

    // MARK: - Last transcript (Ctrl+Cmd+V / Ctrl+Cmd+C)

    /// Types the most recent dictation into the focused app again.
    func pasteLastTranscript() {
        guard !isBusy else { return }
        guard let entry = FlowStore.shared.history.first else {
            flash(.failed("No dictation yet"))
            return
        }
        AppLog.log("Dictation: paste last transcript")
        Task { [weak self] in
            let outcome = await TextInserter.insert(entry.text)
            guard let self, case .failed(let message) = outcome else { return }
            self.flash(.failed(message))
        }
    }

    /// Puts the most recent dictation on the clipboard.
    func copyLastTranscript() {
        guard !isBusy else { return }
        guard let entry = FlowStore.shared.history.first else {
            flash(.failed("No dictation yet"))
            return
        }
        AppLog.log("Dictation: copy last transcript")
        FlowStore.shared.copy(entry)
        flash(.done("Copied last dictation"))
    }

    /// Shows a short status in the live band while nothing is recording.
    private func flash(_ status: Phase) {
        guard !isBusy else { return }
        var seconds = 1.5
        if case .failed(let message) = status {
            AppLog.log("Dictation: \(message)")
            seconds = 2.5
        }
        resetTask?.cancel()
        phase = status
        scheduleReset(after: seconds)
    }

    // MARK: - Note dictation

    /// Starts a hands-free dictation whose formatted text goes to `completion`
    /// instead of the focused app (the Flow panel's mic button). `completion`
    /// gets nil when the session is cancelled or fails. Returns false when
    /// something else is already recording.
    @discardableResult
    func startNoteDictation(completion: @escaping @MainActor (String?) -> Void) -> Bool {
        guard !isBusy else { return false }
        noteCompletion = completion
        isDictatingNote = true
        beginSession(handsFree: true, trigger: "note")
        return phase == .listening
    }

    /// Finishes a note dictation (same as pressing the hotkey again).
    func finishNoteDictation() {
        guard isDictatingNote, phase == .listening else { return }
        AppLog.log("Dictation: stop (note)")
        finish()
    }

    // MARK: - Command capture (Clicky)

    /// Listens for a spoken question without formatting or typing it. Returns
    /// false when a session is already running or a permission was refused
    /// (the refusal is shown as a failed phase). `phase` stays `.idle`.
    @discardableResult
    func startCommandCapture() -> Bool {
        guard !isBusy else {
            AppLog.log("Dictation: command capture refused (busy)")
            return false
        }
        if let message = DictationPermissions.deniedMessage() {
            fail(message)
            // A refused permission can't be asked again: open its Settings pane.
            Task { try? await DictationPermissions.ensure(from: "Clicky") }
            return false
        }
        resetTask?.cancel()
        resetTask = nil
        sessionID += 1
        let id = sessionID
        endSession()
        phase = .idle
        isStoppingCommand = false
        isCapturingCommand = true
        AppLog.log("Dictation: command capture started")

        commandTimeoutTask?.cancel()
        commandTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumCommandDuration * 1_000_000_000))
            guard let self, !Task.isCancelled, self.sessionID == id, self.isCapturingCommand,
                  !self.isStoppingCommand else { return }
            AppLog.log("Dictation: command capture timed out")
            self.cancelCommandCapture()
        }
        startRecorder(session: id)
        return true
    }

    /// Stops listening and returns the raw final transcript, or nil when it
    /// was empty, cancelled or failed to start.
    func finishCommandCapture() async -> String? {
        guard isCapturingCommand, !isStoppingCommand else { return nil }
        isStoppingCommand = true
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        level = 0
        let id = sessionID
        await startTask?.value
        guard sessionID == id else { return nil }
        guard let recorder else {
            endCommandCapture()
            return nil
        }
        self.recorder = nil
        let raw = await recorder.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionID == id else { return nil }
        endCommandCapture()
        AppLog.log("Dictation: command transcript \(raw.count) chars")
        return raw.isEmpty ? nil : raw
    }

    /// Discards a command capture.
    func cancelCommandCapture() {
        guard isCapturingCommand else { return }
        AppLog.log("Dictation: command capture cancelled")
        sessionID += 1
        startTask?.cancel()
        startTask = nil
        if let recorder {
            self.recorder = nil
            Task { await recorder.cancel() }
        }
        endCommandCapture()
    }

    private func endCommandCapture() {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        isCapturingCommand = false
        isStoppingCommand = false
        liveText = ""
        level = 0
    }

    // MARK: - Hotkey

    private func applyHotkey() {
        monitor.setKey(hotkey.monitorKey)
        monitor.setHistoryShortcutsEnabled(historyShortcutsEnabled)
        guard needsMonitor else {
            monitor.stop()
            accessibilityWatch = nil
            return
        }
        ensureMonitor()
    }

    private func ensureMonitor() {
        watchAccessibility()
        guard !monitor.isRunning else { return }
        if PermissionCenter.shared.isGranted(.accessibility), monitor.start() { return }
        // The hotkey cannot be seen without Accessibility. This runs at launch,
        // so it never prompts: onboarding or the Dictate button asks, and the
        // tap is created as soon as the grant arrives (watchAccessibility).
        AppLog.log("Dictation: waiting for Accessibility")
    }

    /// A tap created before the grant (or before the user switched
    /// Accessibility off and on again) never receives events: re-create it.
    private func watchAccessibility() {
        guard accessibilityWatch == nil else { return }
        accessibilityWatch = PermissionCenter.shared.onChange(of: .accessibility) { [weak self] status in
            guard let self, self.started, self.needsMonitor else { return }
            if status.isGranted {
                AppLog.log("Dictation: Accessibility granted")
                if !self.monitor.restart() { AppLog.log("Dictation: key monitor still unavailable") }
            } else if self.monitor.isRunning {
                AppLog.log("Dictation: Accessibility switched off")
                self.monitor.stop()
            }
        }
    }

    private func requestAccessibility() {
        Task { _ = await PermissionCenter.shared.request(.accessibility, from: "Dictation") }
    }

    private func handleKey(_ event: PushToTalkMonitor.Event, at time: TimeInterval) {
        switch event {
        case .pressed:
            AppLog.log("Dictation: hotkey down")
            // The assistant owns the microphone; its own UI ends the capture.
            guard !isCapturingCommand else { return }
            switch phase {
            case .listening:
                if pendingTapTask != nil {
                    pendingTapTask?.cancel()
                    pendingTapTask = nil
                    isHandsFree = true
                    AppLog.log("Dictation: hands-free (double tap)")
                } else if isHandsFree {
                    AppLog.log("Dictation: stop (hotkey)")
                    finish()
                }
            case .formatting:
                break
            case .idle, .done, .failed:
                pressedAt = time
                beginSession(handsFree: false, trigger: "hotkey")
            }

        case .released:
            AppLog.log("Dictation: hotkey up")
            guard phase == .listening, !isHandsFree, pendingTapTask == nil else { return }
            if time - pressedAt < Self.tapThreshold {
                // Maybe the first half of a double-tap: wait for the second press.
                let id = sessionID
                pendingTapTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.doubleTapWindow * 1_000_000_000))
                    guard let self, !Task.isCancelled, self.sessionID == id else { return }
                    self.pendingTapTask = nil
                    if self.phase == .listening, !self.isHandsFree {
                        AppLog.log("Dictation: tap too short, discarded")
                        self.cancel()
                    }
                }
            } else {
                finish()
            }

        case .space:
            guard phase == .listening, !isHandsFree else { return }
            pendingTapTask?.cancel()
            pendingTapTask = nil
            isHandsFree = true
            AppLog.log("Dictation: hands-free (hotkey+Space)")

        case .yieldedToControl:
            guard phase == .listening, !isHandsFree else { return }
            AppLog.log("Dictation: fn+Control belongs to the Job Agent, discarded")
            cancel()

        case .chord:
            guard phase == .listening, !isHandsFree, pendingTapTask == nil,
                  time - pressedAt < Self.chordWindow else { return }
            AppLog.log("Dictation: hotkey used in a shortcut, discarded")
            cancel()

        case .escape:
            AppLog.log("Dictation: Esc")
            cancel()

        case .pasteLast:
            pasteLastTranscript()

        case .copyLast:
            copyLastTranscript()
        }
    }

    // MARK: - Session

    private func beginSession(handsFree: Bool, trigger: String) {
        guard !isBusy else { return }
        // Typing into other apps needs Accessibility; a note does not.
        guard isDictatingNote || PermissionCenter.shared.isGranted(.accessibility) else {
            // Hotkey or Dictate button: a user action. Asks once per
            // signature, afterwards opens the Accessibility pane.
            requestAccessibility()
            fail("Allow Accessibility for SparkV")
            return
        }
        resetTask?.cancel()
        // A muted mic would record silence: say so (System Status mic mute).
        MicMuteController.shared.warnIfMuted(feature: "Dictation")
        sessionID += 1
        let id = sessionID
        phase = .listening
        liveText = ""
        level = 0
        isHandsFree = handsFree
        targetAppName = Self.frontmostAppName()
        monitor.setEscapeArmed(true)
        if formattingEnabled { formatter.prewarm() }
        AppLog.log("Dictation: listening (\(trigger)\(handsFree ? ", hands-free" : ""))")

        durationTask?.cancel()
        durationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumDuration * 1_000_000_000))
            guard let self, !Task.isCancelled, self.sessionID == id, self.phase == .listening else { return }
            AppLog.log("Dictation: maximum duration reached")
            self.finish()
        }

        startRecorder(session: id)
    }

    /// Recording, not yet stopping: dictation listening, or a command capture.
    private var isRecording: Bool {
        phase == .listening || (isCapturingCommand && !isStoppingCommand)
    }

    /// Asks for permissions, then starts the microphone and transcriber for
    /// session `id` (shared by dictation, notes and command capture).
    private func startRecorder(session id: Int) {
        startTask = Task { [weak self] in
            do {
                try await DictationPermissions.ensure()
                // Released (or cancelled) while a permission prompt was up.
                guard let self, self.sessionID == id, self.isRecording else { return }
                let recorder = try await DictationRecorder.start(
                    hints: FlowStore.shared.vocabulary.recognitionHints,
                    onText: { [weak self] text in
                        guard let self, self.sessionID == id,
                              self.phase == .listening || self.isCapturingCommand else { return }
                        self.liveText = text
                    },
                    onLevel: { [weak self] value in
                        Task { @MainActor [weak self] in self?.updateLevel(value, session: id) }
                    }
                )
                guard self.sessionID == id, self.isBusy else {
                    await recorder.cancel()
                    return
                }
                self.recorder = recorder
            } catch {
                guard let self, self.sessionID == id else { return }
                AppLog.log("Dictation: start failed: \(error)")
                if self.isCapturingCommand { self.endCommandCapture() }
                self.fail(DictationError.message(for: error))
            }
        }
    }

    private static func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app.localizedName
    }

    private func finish() {
        guard phase == .listening else { return }
        pendingTapTask?.cancel()
        pendingTapTask = nil
        durationTask?.cancel()
        durationTask = nil
        let id = sessionID
        let useModel = formattingEnabled
        let vocabulary = FlowStore.shared.vocabulary
        let isNote = isDictatingNote
        let appName = targetAppName
        phase = .formatting
        level = 0

        finishTask = Task { [weak self] in
            guard let self else { return }
            await self.startTask?.value
            guard self.sessionID == id else { return }
            guard let recorder = self.recorder else {
                // Never started (permission prompt, start error already shown).
                if self.phase == .formatting { self.resetToIdle() }
                return
            }
            self.recorder = nil
            let raw = await recorder.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.sessionID == id else { return }
            AppLog.log("Dictation: transcript \(raw.count) chars")
            guard !raw.isEmpty else {
                self.fail("No speech detected")
                return
            }

            let text = await self.formatter.format(raw, useModel: useModel, vocabulary: vocabulary)
            guard self.sessionID == id else { return }
            guard !text.isEmpty else {
                self.fail("No speech detected")
                return
            }

            if isNote {
                let completion = self.noteCompletion
                self.noteCompletion = nil
                completion?(text)
                AppLog.log("Dictation: note saved (\(text.count) chars)")
                self.complete("Saved to Notes")
                return
            }

            // Recorded before typing: a failed insert still leaves it on the clipboard.
            FlowStore.shared.record(raw: raw, text: text, appName: appName)
            let outcome = await TextInserter.insert(text)
            guard self.sessionID == id else { return }
            switch outcome {
            case .inserted:
                self.complete(text)
            case .failed(let message):
                self.fail(message)
            }
        }
    }

    private func updateLevel(_ value: Float, session: Int) {
        guard session == sessionID, isRecording else { return }
        // Fast attack, slower release, so the bars breathe instead of flicker.
        level = value > level ? value : level * 0.75 + value * 0.25
    }

    private func complete(_ text: String) {
        endSession()
        phase = .done(text)
        scheduleReset(after: 1.5)
    }

    private func fail(_ message: String) {
        AppLog.log("Dictation: failed: \(message)")
        sessionID += 1
        if let recorder {
            self.recorder = nil
            Task { await recorder.cancel() }
        }
        endSession()
        phase = .failed(message)
        scheduleReset(after: 3)
    }

    private func endSession() {
        pendingTapTask?.cancel()
        pendingTapTask = nil
        durationTask?.cancel()
        durationTask = nil
        isHandsFree = false
        level = 0
        liveText = ""
        targetAppName = nil
        monitor.setEscapeArmed(false)
        isDictatingNote = false
        if let completion = noteCompletion {
            noteCompletion = nil
            completion(nil)
        }
    }

    private func resetToIdle() {
        endSession()
        resetTask?.cancel()
        resetTask = nil
        phase = .idle
    }

    private func scheduleReset(after seconds: Double) {
        resetTask?.cancel()
        let shown = phase
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.phase == shown else { return }
            self.phase = .idle
        }
    }
}

// MARK: - Errors and permissions

enum DictationError: Error {
    case microphoneDenied
    case speechDenied
    case noMicrophone
    case recognizerUnavailable

    static func message(for error: any Error) -> String {
        switch error as? DictationError {
        case .microphoneDenied: "Allow Microphone for SparkV"
        case .speechDenied: "Allow Speech Recognition for SparkV"
        case .noMicrophone: "No microphone found"
        case .recognizerUnavailable: "Speech recognition unavailable"
        case nil: "Dictation failed"
        }
    }
}

/// Microphone + Speech Recognition, requested on first use through
/// PermissionCenter (one system prompt at a time; a refused permission opens
/// its System Settings pane instead, since macOS won't ask twice).
@MainActor
enum DictationPermissions {
    /// Message for a permission the user already refused, without prompting.
    static func deniedMessage() -> String? {
        let center = PermissionCenter.shared
        switch center.status(.microphone) {
        case .denied, .restricted: return DictationError.message(for: DictationError.microphoneDenied)
        default: break
        }
        switch center.status(.speech) {
        case .denied, .restricted: return DictationError.message(for: DictationError.speechDenied)
        default: return nil
        }
    }

    /// Call from a user action (hotkey, button).
    static func ensure(from feature: String = "Dictation") async throws {
        let center = PermissionCenter.shared
        guard await center.ensure(.microphone, from: feature) else { throw DictationError.microphoneDenied }
        guard await center.ensure(.speech, from: feature) else { throw DictationError.speechDenied }
    }
}

// MARK: - Recorder

/// One recording: microphone capture feeding a transcription backend.
@MainActor
final class DictationRecorder {
    private let capture: AudioCapture
    private let backend: any TranscriptionBackend

    private init(capture: AudioCapture, backend: any TranscriptionBackend) {
        self.capture = capture
        self.backend = backend
    }

    /// `hints` are Dictionary words the recognizer should expect.
    static func start(
        hints: [String] = [],
        onText: @escaping @MainActor @Sendable (String) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws -> DictationRecorder {
        if #available(macOS 26.0, *), let analyzer = await AnalyzerBackend.make(hints: hints, onText: onText) {
            do {
                let recorder = try await start(backend: analyzer, onLevel: onLevel)
                AppLog.log("Dictation: SpeechAnalyzer started")
                return recorder
            } catch DictationError.noMicrophone {
                throw DictationError.noMicrophone
            } catch {
                AppLog.log("Dictation: SpeechAnalyzer failed (\(error)), using SFSpeechRecognizer")
            }
        }
        let legacy = try LegacyBackend(hints: hints, onText: onText)
        let recorder = try await start(backend: legacy, onLevel: onLevel)
        AppLog.log("Dictation: SFSpeechRecognizer started")
        return recorder
    }

    private static func start(
        backend: any TranscriptionBackend, onLevel: @escaping @Sendable (Float) -> Void
    ) async throws -> DictationRecorder {
        let capture = AudioCapture()
        do {
            // Capture first: audio is buffered while the recognizer warms up,
            // so the first words are not lost.
            try await capture.start(onBuffer: backend.sink, onLevel: onLevel)
            try await backend.begin()
        } catch {
            await capture.stop()
            await backend.cancel()
            throw error
        }
        return DictationRecorder(capture: capture, backend: backend)
    }

    /// Stops the microphone and returns the final transcript.
    func stop() async -> String {
        await capture.stop()
        return await backend.finish()
    }

    func cancel() async {
        await capture.stop()
        await backend.cancel()
    }
}

@MainActor
protocol TranscriptionBackend: AnyObject {
    /// Receives microphone buffers on the audio thread.
    var sink: @Sendable (AVAudioPCMBuffer) -> Void { get }
    func begin() async throws
    func finish() async -> String
    func cancel() async
}

private func joinTranscript(_ head: String, _ tail: String) -> String {
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    if head.last?.isWhitespace == true || tail.first?.isWhitespace == true { return head + tail }
    return head + " " + tail
}

// MARK: - Audio capture

/// AVAudioEngine microphone tap. Engine work runs on a private serial queue
/// (starting the input unit can take a moment), never on the main thread.
final class AudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.Dictation.Audio", qos: .userInitiated)
    private var engine: AVAudioEngine?

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.startOnQueue(onBuffer: onBuffer, onLevel: onLevel)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if let engine = self.engine {
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                    self.engine = nil
                }
                continuation.resume()
            }
        }
    }

    private func startOnQueue(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noMicrophone }

        let meter = LevelMeter(onLevel: onLevel)
        let handle: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            meter.process(buffer)
            onBuffer(buffer)
        }
        if #available(macOS 27.0, *) {
            try input.installAudioTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                handle(AVAudioPCMBuffer(copying: buffer))
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(handle))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    /// Built outside any actor: the block runs on the realtime audio thread.
    private static func makeTapBlock(_ handle: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in handle(buffer) }
    }
}

/// RMS level of each buffer mapped to 0...1, reported at most ~30 times a second.
private final class LevelMeter: @unchecked Sendable {
    private let onLevel: @Sendable (Float) -> Void
    private var lastReport: TimeInterval = 0

    init(onLevel: @escaping @Sendable (Float) -> Void) {
        self.onLevel = onLevel
    }

    /// Audio thread only.
    func process(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 1.0 / 30 else { return }
        lastReport = now
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        if let channels = buffer.floatChannelData {
            let samples = channels[0]
            for index in 0..<frames { sum += samples[index] * samples[index] }
        } else if let channels = buffer.int16ChannelData {
            let samples = channels[0]
            for index in 0..<frames {
                let value = Float(samples[index]) / Float(Int16.max)
                sum += value * value
            }
        } else {
            return
        }
        let rms = (sum / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        // -55 dB (room tone) ... -10 dB (loud speech).
        onLevel(min(1, max(0, (decibels + 55) / 45)))
    }
}

// MARK: - SpeechAnalyzer backend (macOS 26+)

@available(macOS 26.0, *)
@MainActor
final class AnalyzerBackend: TranscriptionBackend {
    let sink: @Sendable (AVAudioPCMBuffer) -> Void
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onText: @MainActor @Sendable (String) -> Void
    private let hints: [String]
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    private static var isInstallingAssets = false

    private init(
        analyzer: SpeechAnalyzer, format: AVAudioFormat, hints: [String],
        onText: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.analyzer = analyzer
        self.format = format
        self.hints = hints
        self.onText = onText
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
        let converter = AnalyzerSink(format: format, continuation: continuation)
        sink = { buffer in converter.append(buffer) }
    }

    /// nil when SpeechTranscriber cannot run right now (unsupported locale,
    /// model not installed yet); missing models are downloaded in the
    /// background for next time.
    static func make(
        hints: [String], onText: @escaping @MainActor @Sendable (String) -> Void
    ) async -> AnalyzerBackend? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            return nil
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            AppLog.log("Dictation: speech model for \(locale.identifier) is \(status)")
            if status == .supported || status == .downloading { installAssets(for: locale) }
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return nil
        }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let backend = AnalyzerBackend(analyzer: analyzer, format: format, hints: hints, onText: onText)
        backend.consume(transcriber.results)
        return backend
    }

    private func consume<Results: AsyncSequence & Sendable>(_ results: Results)
    where Results.Element == SpeechTranscriber.Result {
        resultsTask = Task { [weak self] in
            do {
                for try await result in results {
                    self?.apply(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                AppLog.log("Dictation: transcriber error \(error)")
            }
        }
    }

    private func apply(text: String, isFinal: Bool) {
        if isFinal {
            finalized = joinTranscript(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        onText(joinTranscript(finalized, volatile))
    }

    func begin() async throws {
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            do {
                try await analyzer.setContext(context)
            } catch {
                AppLog.log("Dictation: Dictionary hints not applied (\(error))")
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
    }

    func finish() async -> String {
        continuation.finish()
        let analyzer = self.analyzer
        let finalized = await AsyncTimeout.run(seconds: 3) {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            } catch {
                return false
            }
        }
        if finalized != true { await analyzer.cancelAndFinishNow() }
        if let resultsTask {
            _ = await AsyncTimeout.run(seconds: 1) {
                await resultsTask.value
                return true
            }
            resultsTask.cancel()
        }
        return joinTranscript(self.finalized, volatile)
    }

    func cancel() async {
        continuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private static func installAssets(for locale: Locale) {
        guard !isInstallingAssets else { return }
        isInstallingAssets = true
        AppLog.log("Dictation: downloading speech model for \(locale.identifier)")
        Task.detached(priority: .utility) {
            do {
                _ = try? await AssetInventory.reserve(locale: locale)
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
                AppLog.log("Dictation: speech model installed")
            } catch {
                AppLog.log("Dictation: speech model download failed: \(error)")
            }
            await MainActor.run { AnalyzerBackend.isInstallingAssets = false }
        }
    }
}

/// Converts microphone buffers to the analyzer's format (16 kHz Int16 mono
/// here) and feeds the input stream. Audio thread only.
@available(macOS 26.0, *)
private final class AnalyzerSink: @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            sourceFormat = buffer.format
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }
}

// MARK: - SFSpeechRecognizer backend (fallback)

@MainActor
final class LegacyBackend: TranscriptionBackend {
    let sink: @Sendable (AVAudioPCMBuffer) -> Void
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let state = LegacyState()
    private let onText: @MainActor @Sendable (String) -> Void
    private var task: SFSpeechRecognitionTask?

    init(hints: [String] = [], onText: @escaping @MainActor @Sendable (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = hints
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            AppLog.log("Dictation: on-device recognition unavailable for \(recognizer.locale.identifier)")
        }
        // Results arrive on a background queue, not the main thread.
        recognizer.queue = OperationQueue()
        self.recognizer = recognizer
        self.request = request
        self.onText = onText
        let box = RequestBox(request)
        sink = { buffer in box.request.append(buffer) }
    }

    func begin() async throws {
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(state: state, onText: onText))
    }

    func finish() async -> String {
        request.endAudio()
        let state = self.state
        let done = await AsyncTimeout.run(seconds: 2.5) {
            await state.waitUntilDone()
            return true
        }
        if done != true { task?.cancel() }
        task = nil
        return state.text
    }

    func cancel() async {
        task?.cancel()
        task = nil
        request.endAudio()
    }

    nonisolated private static func makeHandler(
        state: LegacyState, onText: @escaping @MainActor @Sendable (String) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                state.update(text)
                Task { @MainActor in onText(text) }
                if result.isFinal { state.markDone() }
            }
            if let error {
                AppLog.log("Dictation: SFSpeechRecognizer ended: \(error.localizedDescription)")
                state.markDone()
            }
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
}

/// Latest transcript plus a "final result arrived" signal, shared with the
/// recognizer's background queue.
private final class LegacyState: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = ""
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func update(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        latest = text
    }

    func markDone() {
        lock.lock()
        done = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func waitUntilDone() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
