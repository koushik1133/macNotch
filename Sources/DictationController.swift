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

    /// macOS also acts on the 🌐 key (System Settings › Keyboard › "Press 🌐
    /// key to" is not "Do Nothing"): emoji picker, input source or macOS
    /// Dictation would fire along with SparkV's. Read-only; SparkV never
    /// changes the setting.
    static var fnKeyHasSystemAction: Bool {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return ((value as? NSNumber)?.intValue ?? 0) != 0
    }

    private static var loggedFnConflict = false

    static func noteFnConflictOnce(_ hotkey: Hotkey) {
        guard hotkey == .fn, !loggedFnConflict, fnKeyHasSystemAction else { return }
        loggedFnConflict = true
        AppLog.log("Dictation: macOS also acts on the 🌐 key (Keyboard › Press 🌐 key to); suggest Do Nothing")
    }

    static let fnConflictNote = "macOS also uses the 🌐 key. In System Settings › Keyboard, set “Press 🌐 key to” to “Do Nothing” so fn only dictates."

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

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

    /// Hold / double-tap / shortcut handling (DictationKeyMachine.swift).
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
    private var keys = DictationKeyMachine()
    /// Fires the machine's hold / double-tap deadline.
    private var keyDeadlineTask: Task<Void, Never>?
    /// Name of the app that had focus when the session began, for the history.
    private var targetAppName: String?
    /// Receives the formatted note text (nil when cancelled or failed).
    private var noteCompletion: (@MainActor (String?) -> Void)?
    /// `finishCommandCapture()` is stopping the recorder.
    private var isStoppingCommand = false

    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
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
            if phase == .listening { keys.startedHandsFreeElsewhere() }
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
            apply(keys.handle(.press(time)), at: time)
        case .released:
            apply(keys.handle(.release(time)), at: time)
        case .space:
            apply(keys.handle(.space(time)), at: time)
        case .chord:
            apply(keys.handle(.chord(time)), at: time)
        case .yieldedToControl:
            // fn+Control belongs to the Job Agent.
            if keys.isListening, phase == .listening, !isHandsFree {
                AppLog.log("Dictation: fn+Control belongs to the Job Agent, discarded")
                keys.reset()
                cancel()
            } else if !keys.isListening {
                keys.reset()
            }
        case .escape:
            AppLog.log("Dictation: Esc")
            cancel()

        case .pasteLast:
            pasteLastTranscript()

        case .copyLast:
            copyLastTranscript()
        }
    }

    /// Acts on the key machine's answer and re-arms its deadline.
    private func apply(_ action: DictationKeyMachine.Action, at time: TimeInterval) {
        // The assistant owns the microphone; its own UI ends the capture.
        if isCapturingCommand {
            keys.reset()
            return
        }
        switch action {
        case .none:
            break
        case .startHold:
            guard canStartFromKey else { keys.reset(); break }
            Self.noteFnConflictOnce(hotkey)
            beginSession(handsFree: false, trigger: "hold")
            if phase != .listening { keys.reset() }
        case .startHandsFree:
            guard canStartFromKey else { keys.reset(); break }
            beginSession(handsFree: true, trigger: "double tap")
            if phase != .listening { keys.reset() }
        case .lockHandsFree:
            guard phase == .listening else { break }
            isHandsFree = true
            SparkVHaptics.play(.snap)
            AppLog.log("Dictation: hands-free (hotkey+Space)")
        case .finish:
            guard phase == .listening else { break }
            AppLog.log("Dictation: stop (hotkey)")
            finish()
        case .cancel:
            guard phase == .listening else { break }
            AppLog.log("Dictation: hotkey used in a shortcut, discarded")
            cancel()
        }
        scheduleKeyDeadline()
    }

    /// Idle, or showing the last result: a new dictation may start.
    private var canStartFromKey: Bool {
        switch phase {
        case .idle, .done, .failed: true
        case .listening, .formatting: false
        }
    }

    private func scheduleKeyDeadline() {
        keyDeadlineTask?.cancel()
        keyDeadlineTask = nil
        guard let deadline = keys.deadline else { return }
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        keyDeadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 5_000_000)
            guard let self, !Task.isCancelled else { return }
            self.keyDeadlineTask = nil
            self.apply(self.keys.handle(.tick(ProcessInfo.processInfo.systemUptime)), at: ProcessInfo.processInfo.systemUptime)
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
        SparkVHaptics.play(.start)

        durationTask?.cancel()
        durationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumDuration * 1_000_000_000))
            guard let self, !Task.isCancelled, self.sessionID == id, self.phase == .listening else { return }
            AppLog.log("Dictation: maximum duration reached")
            self.finish(byUser: false)
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

    private func finish(byUser: Bool = true) {
        guard phase == .listening else { return }
        if byUser { SparkVHaptics.play(.stop) }
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
                // A brief accidental hold with nothing said: end quietly.
                if !recorder.heardVoice, !recorder.heardDigitalSilence, recorder.capturedSeconds < 1.2 {
                    AppLog.log("Dictation: short hold with no speech, discarded")
                    SparkVHaptics.play(.stop)
                    self.resetToIdle()
                    return
                }
                self.fail(recorder.heardDigitalSilence
                          ? "Mic is silent: allow SparkV in Privacy › Microphone"
                          : recorder.heardVoice ? "Couldn’t make out any words" : "No speech detected")
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
        SparkVHaptics.play(.success)
        endSession()
        phase = .done(text)
        scheduleReset(after: 1.5)
    }

    private func fail(_ message: String) {
        AppLog.log("Dictation: failed: \(message)")
        SparkVHaptics.play(.failure)
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
        // Whatever ended it (Esc, an error, the button), the key starts fresh.
        if keys.isListening { keys.reset() }
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
        var text = await backend.finish()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        let speech = SFSpeechRecognizer.authorizationStatus().rawValue
        let seconds = capture.capturedSeconds
        let voiced = capture.voicedSeconds
        AppLog.log(String(
            format: "Dictation: heard %d buffers (%.1f s, %.1f s voiced), peak %d dB, %@ (mic auth %d, speech auth %d)",
            capture.buffers, seconds, voiced, Int(capture.peakDecibels), backend.name, mic, speech
        ))
        // SpeechAnalyzer returned nothing for audio that had voice in it:
        // run the same audio through SFSpeechRecognizer before giving up.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           backend.name != LegacyBackend.name, voiced >= Self.minimumVoicedSeconds {
            text = await Self.recognizeAgain(capture.keptAudio, seconds: min(seconds, AudioCapture.maximumKeptSeconds))
        }
        capture.discardKeptAudio()
        return text
    }

    /// Less than this much loud audio is treated as "nothing was said".
    static let minimumVoicedSeconds: Double = 0.4

    /// Second pass over recorded audio with SFSpeechRecognizer (on device).
    static func recognizeAgain(_ audio: [AVAudioPCMBuffer], seconds: Double) async -> String {
        guard !audio.isEmpty else { return "" }
        do {
            // Fed at once, so recognition runs faster than real time; the
            // deadline grows with the recording.
            let legacy = try LegacyBackend(onText: { _ in }, finishTimeout: min(30, max(4, seconds * 0.5)))
            try await legacy.begin()
            let sink = legacy.sink
            for buffer in audio { sink(buffer) }
            let text = await legacy.finish()
            let words = text.split(whereSeparator: \.isWhitespace).count
            AppLog.log("Dictation: SpeechAnalyzer heard nothing; SFSpeechRecognizer second pass found \(words) word(s)")
            return text
        } catch {
            AppLog.log("Dictation: SFSpeechRecognizer second pass unavailable (\(error))")
            return ""
        }
    }

    /// Only zeros arrived: macOS gives an app silence (no error) when its
    /// Microphone access is off, or another app holds the input exclusively.
    var heardDigitalSilence: Bool { capture.buffers > 0 && capture.peakDecibels < -100 }

    /// Seconds of microphone audio captured.
    var capturedSeconds: Double { capture.capturedSeconds }

    /// Something louder than room tone reached the mic (speech, most likely).
    var heardVoice: Bool { capture.voicedSeconds >= Self.minimumVoicedSeconds }

    func cancel() async {
        await capture.stop()
        capture.discardKeptAudio()
        await backend.cancel()
    }
}

@MainActor
protocol TranscriptionBackend: AnyObject {
    /// "SpeechAnalyzer" or "SFSpeechRecognizer", for the log.
    var name: String { get }
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

// MARK: - Self-test

/// Launch-argument diagnostic for the microphone + speech pipeline.
@MainActor
enum DictationSelfTest {
    static func run() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            AppLog.log("Mic self-test: starting (5 s)")
            do {
                let recorder = try await DictationRecorder.start(onText: { _ in }, onLevel: { _ in })
                try? await Task.sleep(for: .seconds(5))
                let text = await recorder.stop().trimmingCharacters(in: .whitespacesAndNewlines)
                let words = text.split(separator: " ").count
                AppLog.log("Mic self-test: \(words) word(s) recognized\(recorder.heardDigitalSilence ? ", input was digital silence" : "")")
            } catch {
                AppLog.log("Mic self-test: failed to start: \(error)")
            }
            await recognizeFile()
        }
    }

    /// `--speech-file <path>`: the same recognizer fed from a file, no mic,
    /// so a silent result can be pinned on the input or on recognition.
    private static func recognizeFile() async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--speech-file"), index + 1 < args.count else { return }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[index + 1]))
            var backend: (any TranscriptionBackend)?
            if #available(macOS 26.0, *) { backend = await AnalyzerBackend.make(hints: [], onText: { _ in }) }
            let recognizer = try backend ?? LegacyBackend(onText: { _ in })
            try await recognizer.begin()
            let sink = recognizer.sink
            let downmix = MonoDownmix(sampleRate: file.processingFormat.sampleRate)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800) else { break }
                try file.read(into: buffer, frameCount: 4800)
                guard buffer.frameLength > 0 else { break }
                sink(downmix.process(buffer))
            }
            let words = await recognizer.finish().split(separator: " ").count
            AppLog.log("Speech self-test: \(words) word(s) from the file (\(backend == nil ? "SFSpeechRecognizer" : "SpeechAnalyzer"))")
        } catch {
            AppLog.log("Speech self-test: failed: \(error)")
        }
    }
}

// MARK: - Audio capture

/// AVAudioEngine microphone tap. Engine work runs on a private serial queue
/// (starting the input unit can take a moment), never on the main thread.
/// Restarts itself when the input device or its format changes
/// (AVAudioEngineConfigurationChange): AirPods switching to their headset
/// profile when the mic opens stops the engine, which used to end the
/// recording a second or two in, before the user had said anything.
final class AudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.Dictation.Audio", qos: .userInitiated)
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var isRunning = false
    private var restartAttempts = 0

    // Stats and the kept audio: written on the audio thread, read on main (lock).
    private var bufferCount = 0
    private var peak: Float = 0
    private var seconds: Double = 0
    private var voiced: Double = 0
    private var kept: [AVAudioPCMBuffer] = []
    private var keptSeconds: Double = 0
    /// Audio kept for a second recognition pass (SpeechAnalyzer heard nothing).
    static let maximumKeptSeconds: Double = 120

    var buffers: Int { lock.lock(); defer { lock.unlock() }; return bufferCount }
    var peakDecibels: Float { lock.lock(); defer { lock.unlock() }; return 20 * log10(max(peak, 0.000_000_1)) }
    /// Seconds of audio captured.
    var capturedSeconds: Double { lock.lock(); defer { lock.unlock() }; return seconds }
    /// Seconds of audio louder than room tone (roughly: speech).
    var voicedSeconds: Double { lock.lock(); defer { lock.unlock() }; return voiced }
    /// Mono buffers captured so far (first `maximumKeptSeconds`).
    var keptAudio: [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return kept }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    guard self.engine == nil else {
                        continuation.resume()
                        return
                    }
                    self.onBuffer = onBuffer
                    self.onLevel = onLevel
                    try self.startEngine()
                    self.isRunning = true
                    continuation.resume()
                } catch {
                    self.teardown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isRunning = false
                self.teardown()
                self.onBuffer = nil
                self.onLevel = nil
                continuation.resume()
            }
        }
    }

    /// Drops the kept audio (after the transcript is settled).
    func discardKeptAudio() {
        lock.lock(); defer { lock.unlock() }
        kept.removeAll()
    }

    /// Queue only.
    private func startEngine() throws {
        guard let onBuffer, let onLevel else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noMicrophone }

        let meter = LevelMeter(onLevel: onLevel)
        let downmix = MonoDownmix(sampleRate: format.sampleRate)
        let handle: @Sendable (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            // The built-in MacBook mic is a 3-channel array; AVAudioConverter
            // turns that into pure silence, so hand on one channel instead.
            let mono = downmix.process(buffer)
            self?.record(mono)
            meter.process(mono)
            onBuffer(mono)
        }
        // ~43 ms at 48 kHz: half the wake-ups of 1024 frames, still smooth live text.
        if #available(macOS 27.0, *) {
            try input.installAudioTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                handle(AVAudioPCMBuffer(copying: buffer))
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTapBlock(handle))
        }
        AppLog.log("Dictation: microphone \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restart() }
        }
    }

    /// Queue only. The input device or its format changed mid-recording.
    private func restart() {
        guard isRunning else { return }
        AppLog.log("Dictation: audio configuration changed, restarting microphone")
        teardown()
        do {
            try startEngine()
            restartAttempts = 0
        } catch {
            restartAttempts += 1
            AppLog.log("Dictation: microphone restart failed (\(error)), attempt \(restartAttempts)")
            guard restartAttempts < 5 else { return }
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restart() }
        }
    }

    /// Queue only.
    private func teardown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
    }

    /// Audio thread: stats, plus a copy of the audio for a second pass.
    private func record(_ mono: AVAudioPCMBuffer) {
        let frames = Int(mono.frameLength)
        let rate = mono.format.sampleRate
        guard frames > 0, rate > 0 else { return }
        var bufferPeak: Float = 0
        var sum: Float = 0
        if let samples = mono.floatChannelData?[0] {
            for index in 0..<frames {
                let value = samples[index]
                bufferPeak = max(bufferPeak, abs(value))
                sum += value * value
            }
        }
        let duration = Double(frames) / rate
        // -50 dB RMS: above a quiet room, below any speech close to the mic.
        let isVoiced = (sum / Float(frames)).squareRoot() > 0.003
        lock.lock(); defer { lock.unlock() }
        bufferCount += 1
        peak = max(peak, bufferPeak)
        seconds += duration
        if isVoiced { voiced += duration }
        // A copy: before macOS 27 the tap's own buffer is reused after it returns.
        if keptSeconds < Self.maximumKeptSeconds, let copy = Self.copy(mono) {
            kept.append(copy)
            keptSeconds += duration
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        for channel in 0..<channels {
            destination[channel].update(from: source[channel], count: samples)
        }
        return copy
    }

    /// Built outside any actor: the block runs on the realtime audio thread.
    private static func makeTapBlock(_ handle: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in handle(buffer) }
    }
}

/// Mono Float32 for every input layout, mixed by hand (MeetingMonoMixer):
/// AVAudioConverter turns the 3-channel MacBook mic into pure silence.
/// Stereo is averaged; arrays of three or more use the first channel with
/// signal, so an interface whose mic is on input 2 isn't heard as silence
/// (taking channel 0 alone did that). Mono Float32 passes through.
/// Audio thread only.
final class MonoDownmix: @unchecked Sendable {
    private let mixer = MeetingMonoMixer()

    init(sampleRate: Double) {}

    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = buffer.format
        if format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 { return buffer }
        return mixer.mix(buffer) ?? buffer
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
    let name = "SpeechAnalyzer"
    let sink: @Sendable (AVAudioPCMBuffer) -> Void
    private let fed: AnalyzerSink
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
        fed = converter
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
        reserveOnce(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            AppLog.log("Dictation: no audio format for the speech model")
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
        // Long dictations (or a model still loading) need longer than 3 s to
        // finalize; cancelling early dropped the words still in flight.
        let deadline = 3 + min(7, fed.fedSeconds / 20)
        let finalized = await AsyncTimeout.run(seconds: deadline) {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            } catch {
                return false
            }
        }
        if finalized != true {
            AppLog.log(String(format: "Dictation: SpeechAnalyzer did not finalize within %.0f s", deadline))
            await analyzer.cancelAndFinishNow()
        }
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

    private static var reservedThisLaunch: Set<String> = []

    /// An installed model another app put there can be removed when that app
    /// lets go of it; reserving the locale keeps it for SparkV too.
    private static func reserveOnce(_ locale: Locale) {
        guard reservedThisLaunch.insert(locale.identifier).inserted else { return }
        Task.detached(priority: .utility) {
            let reserved = await AssetInventory.reservedLocales
            guard !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
            } catch {
                AppLog.log("Dictation: could not reserve \(locale.identifier) (\(error))")
            }
        }
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
    private let lock = NSLock()
    private var fedFrames: Double = 0

    /// Seconds of audio handed to the analyzer so far.
    var fedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return format.sampleRate > 0 ? fedFrames / format.sampleRate : 0
    }

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
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
        lock.lock()
        fedFrames += Double(output.frameLength)
        lock.unlock()
        continuation.yield(AnalyzerInput(buffer: output))
    }
}

// MARK: - SFSpeechRecognizer backend (fallback)

@MainActor
final class LegacyBackend: TranscriptionBackend {
    static let name = "SFSpeechRecognizer"
    var name: String { Self.name }
    let sink: @Sendable (AVAudioPCMBuffer) -> Void
    private let finishTimeout: Double
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let state = LegacyState()
    private let onText: @MainActor @Sendable (String) -> Void
    private var task: SFSpeechRecognitionTask?

    init(
        hints: [String] = [], onText: @escaping @MainActor @Sendable (String) -> Void, finishTimeout: Double = 2.5
    ) throws {
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
        self.finishTimeout = finishTimeout
        let box = RequestBox(request)
        sink = { buffer in box.request.append(buffer) }
    }

    func begin() async throws {
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(state: state, onText: onText))
    }

    func finish() async -> String {
        request.endAudio()
        let state = self.state
        let done = await AsyncTimeout.run(seconds: finishTimeout) {
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
