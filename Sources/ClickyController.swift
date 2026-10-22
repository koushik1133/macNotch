import AppKit
import AVFoundation
import Combine
import CoreGraphics
import FoundationModels
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ClickyExchange: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: String
    let answer: String
    let date: Date
    /// Where Clicky pointed, on the `ClickyPrompt.grid` (0...1000) scale.
    let gridPoint: ClickyPoint?

    init(id: UUID = UUID(), question: String, answer: String, date: Date = Date(), gridPoint: ClickyPoint? = nil) {
        self.id = id
        self.question = question
        self.answer = answer
        self.date = date
        self.gridPoint = gridPoint
    }
}

// MARK: - Seams

/// The microphone side: `DictationController`'s command capture in the app
/// (see ClickySystem.swift), a fake in tests.
@MainActor
protocol ClickySpeechInput: AnyObject {
    var isCapturingCommand: Bool { get }
    var capturingChanges: AnyPublisher<Bool, Never> { get }
    var liveTextChanges: AnyPublisher<String, Never> { get }
    /// Microphone or Speech Recognition was refused: what to tell the user.
    /// Never prompts.
    var permissionProblem: String? { get }
    /// Both permissions are granted, so no system prompt interrupts the hold.
    var isReadyWithoutPrompt: Bool { get }
    /// A dictation (not a command capture) owns the microphone.
    var isDictating: Bool { get }
    /// Dictation is showing its own failure in the band.
    var isShowingFailure: Bool { get }
    /// Opens the Settings pane for the refused permission (via PermissionCenter).
    func openPermissionSettings()
    func startCommandCapture() -> Bool
    func finishCommandCapture() async -> String?
    func cancelCommandCapture()
}

/// The display under the mouse.
@MainActor
protocol ClickyScreenSource: AnyObject {
    var hasScreenAccess: Bool { get }
    /// Granted in Settings, but macOS applies it only after SparkV restarts.
    var needsRelaunch: Bool { get }
    /// Called with the new value when Screen Recording is granted or revoked.
    var onAccessChange: (@MainActor (Bool) -> Void)? { get set }
    /// Asks for Screen Recording (a prompt once, then Settings, rate-limited).
    func requestScreenAccess()
    func capture() async throws -> ClickyCapture
}

/// Answers one question (Groq vision with a key, Apple's on-device model
/// without one).
protocol ClickyAnswering: Sendable {
    func answer(_ query: ClickyQuery) async throws -> ClickyReply
}

enum ClickyBackendChoice: Equatable, Sendable {
    case groq(key: String, model: ClickyModel)
    case onDevice
}

@MainActor
protocol ClickyKeyStore: AnyObject {
    func hasKey() -> Bool
    /// May show the keychain's "allow access" alert after a rebuild, so it
    /// must not block the main thread.
    func load() async -> String?
    func save(_ key: String) -> Bool
    func delete()
}

@MainActor
protocol ClickyPointerPresenting: AnyObject {
    var isVisible: Bool { get }
    func show(from start: CGPoint, to target: CGPoint, label: String, screenFrame: CGRect)
    func dismiss(animated: Bool)
}

@MainActor
protocol ClickySpeaking: AnyObject {
    var onStart: (@MainActor () -> Void)? { get set }
    var onFinish: (@MainActor () -> Void)? { get set }
    /// UTF-16 offset in the spoken text of the word being spoken.
    var onProgress: (@MainActor (Int) -> Void)? { get set }
    func speak(_ text: String)
    func stop()
}

@MainActor
protocol ClickyHotkeySource: AnyObject {
    var onEvent: (@MainActor (ClickyHotkeyEvent) -> Void)? { get set }
    /// Accessibility granted, so the hold key is seen in other apps.
    var isTrusted: Bool { get }
    var onTrustChange: (@MainActor (Bool) -> Void)? { get set }
    func start()
    func stop()
    func reset()
}

enum ClickyHaptic: Equatable, Sendable {
    /// Listening started.
    case listen
    /// An answer arrived.
    case answer
}

/// One question as the backends see it.
struct ClickyQuery: Sendable {
    var question: String
    /// nil when the screen could not be captured (text-only answer).
    var capture: ClickyCapture?
    /// Mouse position in screenshot pixels (nil for typed questions).
    var cursor: CGPoint?
    var appName: String?
    var history: [ClickyExchange]
}

/// Timing knobs; tests shrink them.
struct ClickyTiming: Sendable {
    /// A failure stays in the band this long.
    var failureReset: Double = 4.5
    /// A hint (too-short hold, ready after a permission prompt) stays this long.
    var hintReset: Double = 2.5
    /// The answer stays this long after speech finishes.
    var afterSpeech: Double = 4
    /// Held for less than this (after the hold delay) with nothing heard: a slip.
    var shortHold: Double = 0.45
    /// Whole answer, every backend and retry included.
    var answerTimeout: Double = 40
    /// The screenshot (ScreenCaptureKit can stall, e.g. behind a system
    /// capture alert); past this Clicky answers without the screen.
    var captureTimeout: Double = 8
    /// No speech callback within this long: page the band by reading time.
    var speechStartGrace: Double = 1.5
    /// Seconds per word when paging without speech, and the minimum per page.
    var readingSecondsPerWord: Double = 0.32
    var minimumPageSeconds: Double = 2.2
    /// Added to each page's reading time (time to move the eyes there).
    var pageExtraSeconds: Double = 1
    /// Wait before retrying a start that dictation was still releasing.
    var busyRetry: Double = 0.25
}

// MARK: - Controller

/// Clicky, a screen assistant in the notch: hold Control + Option and ask
/// about what's on screen; release to send. Clicky looks at the display under
/// the mouse only at that moment, answers out loud, and flies a pointer to
/// the element it is talking about.
///
/// The chain: hotkey (Accessibility) -> command capture (Microphone + Speech
/// Recognition, shared with dictation) -> screenshot of the display under the
/// mouse (Screen Recording, through PermissionCenter's cached content) ->
/// Groq vision with the user's key, or Vision OCR + Apple's on-device model
/// -> JSON reply (answer + optional point on the 0-1000 grid) -> global
/// screen point on the captured display -> pointer overlay, the band under
/// the notch (paged in step with speech) and AVSpeechSynthesizer -> history.
///
/// Without Screen Recording (or when capture fails) Clicky still answers,
/// from the question alone, and says it can't see the screen.
@MainActor
final class ClickyController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        /// The page of the answer the band shows now (two lines at most).
        case answering(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The question as heard so far (live while listening, final afterwards).
    @Published private(set) var liveQuestion = ""
    @Published private(set) var hasAPIKey: Bool
    /// Newest first, at most `maxExchanges`.
    @Published private(set) var exchanges: [ClickyExchange] = []
    /// Accessibility granted, so the ⌃⌥ hold key can be seen in other apps.
    @Published private(set) var hotkeyAvailable: Bool
    /// Screen Recording granted: answers can see the screen.
    @Published private(set) var canSeeScreen: Bool
    @Published private(set) var isSpeaking = false
    /// The whole answer being shown (the band shows one page of it).
    @Published private(set) var currentAnswer = ""
    @Published var model: ClickyModel {
        didSet { defaults.set(model.rawValue, forKey: Self.modelDefaultsKey) }
    }
    /// Read answers aloud. Off: the band pages through the answer instead.
    @Published var speaksAnswers: Bool {
        didSet {
            defaults.set(speaksAnswers, forKey: Self.speaksDefaultsKey)
            guard !speaksAnswers, speaksAnswers != oldValue else { return }
            // Also stops an utterance that was queued but has not started
            // yet (a voice still loading), which would otherwise speak anyway.
            speaker.stop()
            isSpeaking = false
            if case .answering = phase { startReadingPager() }
        }
    }

    /// No key: answers come from the on-device model, which reads screen text only.
    var isOnDevice: Bool { !hasAPIKey }

    static let maxExchanges = 8
    /// Longest answer kept and spoken.
    static let maxAnswerCharacters = 360
    /// One band page: two lines of the 400 pt band at 12 pt.
    static let pageCharacters = 84
    static let modelDefaultsKey = "clicky.model"
    static let speaksDefaultsKey = "clicky.speaksAnswers"

    private let speech: any ClickySpeechInput
    private let screen: any ClickyScreenSource
    private let keyStore: any ClickyKeyStore
    private let makeBackend: @MainActor (ClickyBackendChoice) -> any ClickyAnswering
    private let overlay: any ClickyPointerPresenting
    private let speaker: any ClickySpeaking
    private let hotkey: any ClickyHotkeySource
    private let defaults: UserDefaults
    private let mouseLocation: @MainActor () -> CGPoint
    private let frontmostAppName: @MainActor () -> String?
    private let haptic: @MainActor (ClickyHaptic) -> Void
    /// Opens the HTTPS connection to Groq while the user is still talking.
    private let prewarm: @MainActor () -> Void
    private let now: () -> Date
    let timing: ClickyTiming

    private var liveTextSubscription: AnyCancellable?
    private var captureSubscription: AnyCancellable?
    private var work: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var pagerTask: Task<Void, Never>?
    private var beginRetry: Task<Void, Never>?
    /// Bumped by every new question or cancel; stale results are dropped.
    private var session = 0
    private var cachedKey: String?
    private var started = false
    private var listeningSince = Date.distantPast
    /// The first hold may raise the Microphone / Speech prompts.
    private var mayPromptForSpeech = false
    /// Clicky itself is ending the capture (release or cancel).
    private var endingCapture = false
    private var pages: [String] = []
    private var pageStarts: [Int] = []
    private var pageIndex = 0

    init(
        speech: any ClickySpeechInput,
        screen: any ClickyScreenSource,
        keyStore: any ClickyKeyStore,
        makeBackend: @escaping @MainActor (ClickyBackendChoice) -> any ClickyAnswering,
        overlay: any ClickyPointerPresenting,
        speaker: any ClickySpeaking,
        hotkey: any ClickyHotkeySource,
        defaults: UserDefaults = .standard,
        mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        frontmostAppName: @escaping @MainActor () -> String? = ClickyController.otherFrontmostAppName,
        haptic: @escaping @MainActor (ClickyHaptic) -> Void = { _ in },
        prewarm: @escaping @MainActor () -> Void = {},
        now: @escaping () -> Date = Date.init,
        timing: ClickyTiming = ClickyTiming()
    ) {
        self.speech = speech
        self.screen = screen
        self.keyStore = keyStore
        self.makeBackend = makeBackend
        self.overlay = overlay
        self.speaker = speaker
        self.hotkey = hotkey
        self.defaults = defaults
        self.mouseLocation = mouseLocation
        self.frontmostAppName = frontmostAppName
        self.haptic = haptic
        self.prewarm = prewarm
        self.now = now
        self.timing = timing
        hasAPIKey = keyStore.hasKey()
        hotkeyAvailable = hotkey.isTrusted
        canSeeScreen = screen.hasScreenAccess
        model = ClickyModel.stored(defaults.string(forKey: Self.modelDefaultsKey))
        speaksAnswers = defaults.object(forKey: Self.speaksDefaultsKey) as? Bool ?? true
    }

    /// The frontmost app, unless it is SparkV itself (the notch panel).
    static func otherFrontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app.localizedName
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        speaker.onFinish = { [weak self] in self?.speechFinished() }
        speaker.onStart = { [weak self] in self?.speechStarted() }
        speaker.onProgress = { [weak self] offset in self?.speechReached(offset) }
        hotkey.onEvent = { [weak self] event in self?.handleHotkey(event) }
        // Monitors installed before the Accessibility grant may stay deaf;
        // the source re-creates them when trust arrives.
        hotkey.onTrustChange = { [weak self] trusted in
            guard let self, self.started else { return }
            self.hotkeyAvailable = trusted
            if trusted { AppLog.log("Clicky: Accessibility granted, hotkey active") }
        }
        screen.onAccessChange = { [weak self] granted in self?.canSeeScreen = granted }
        hotkey.start()
        hotkeyAvailable = hotkey.isTrusted
        canSeeScreen = screen.hasScreenAccess
        AppLog.log("Clicky: started (\(hasAPIKey ? "Groq \(model.rawValue)" : "on-device"), hotkey \(hotkeyAvailable ? "ready" : "needs Accessibility"), screen \(canSeeScreen ? "ok" : "off"))")
    }

    func shutdown() {
        started = false
        session += 1
        work?.cancel()
        resetTask?.cancel()
        pagerTask?.cancel()
        beginRetry?.cancel()
        dropCaptureSubscriptions()
        if phase == .listening || speech.isCapturingCommand {
            endingCapture = true
            speech.cancelCommandCapture()
        }
        hotkey.stop()
        overlay.dismiss(animated: false)
        speaker.stop()
        isSpeaking = false
        phase = .idle
    }

    // MARK: - Public actions

    /// Panel button: start listening, or send what was heard so far.
    func toggleListening() {
        if phase == .listening {
            finishListening()
        } else {
            beginListening()
        }
    }

    /// Typed question from the panel.
    func ask(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        beginRetry?.cancel()
        dropCaptureSubscriptions()
        if phase == .listening || speech.isCapturingCommand {
            endingCapture = true
            speech.cancelCommandCapture()
        }
        interruptOutput()
        session += 1
        let current = session
        resetTask?.cancel()
        liveQuestion = text
        phase = .thinking
        // The pointer is on the notch panel, not on what the question is
        // about, so its position is left out.
        work = Task { [weak self] in
            await self?.answer(text, session: current, includeCursor: false)
        }
    }

    /// nil or empty removes the key (Clicky falls back to on-device mode).
    func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            keyStore.delete()
            cachedKey = nil
            hasAPIKey = false
            AppLog.log("Clicky: API key removed")
            return
        }
        if keyStore.save(trimmed) {
            cachedKey = trimmed
            hasAPIKey = true
            AppLog.log("Clicky: API key saved")
        } else {
            fail("Couldn't save the key to Keychain")
        }
    }

    /// Stops speech and the pointer; an answer on screen goes back to idle.
    func stopSpeaking() {
        interruptOutput()
        if case .answering = phase { phase = .idle }
    }

    /// Esc: drop whatever Clicky is doing.
    func cancel() {
        let wasBusy = phase != .idle || isSpeaking || overlay.isVisible
        session += 1
        work?.cancel()
        work = nil
        resetTask?.cancel()
        beginRetry?.cancel()
        dropCaptureSubscriptions()
        if phase == .listening || speech.isCapturingCommand {
            endingCapture = true
            speech.cancelCommandCapture()
        }
        interruptOutput()
        hotkey.reset()
        phase = .idle
        if wasBusy { AppLog.log("Clicky: cancelled") }
    }

    // MARK: - Hotkey

    func handleHotkey(_ event: ClickyHotkeyEvent) {
        switch event {
        case .began:
            beginListening()
        case .ended:
            if beginRetry != nil {
                // Released before dictation let go of the microphone.
                beginRetry?.cancel()
                beginRetry = nil
                return
            }
            finishListening()
        case .interrupted:
            // ⌃⌥ was part of some other shortcut.
            beginRetry?.cancel()
            beginRetry = nil
            if phase == .listening { cancel() }
        case .escape:
            if phase != .idle || isSpeaking || overlay.isVisible || beginRetry != nil { cancel() }
        }
    }

    // MARK: - Listening

    private func beginListening(isRetry: Bool = false) {
        guard phase != .listening else { return }
        beginRetry?.cancel()
        beginRetry = nil
        work?.cancel()
        work = nil
        interruptOutput()
        session += 1
        resetTask?.cancel()

        if let problem = speech.permissionProblem {
            // macOS won't ask twice: open the pane. Typing still works.
            speech.openPermissionSettings()
            fail(problem)
            return
        }
        if speech.isDictating {
            guard !isRetry else {
                fail("Dictation is busy. Try again in a moment")
                return
            }
            // Dictation may be letting go of the microphone (its hotkey can
            // share Option); try once more shortly.
            let current = session
            beginRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.timing.busyRetry ?? 0.25) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.session == current else { return }
                self.beginRetry = nil
                self.beginListening(isRetry: true)
            }
            return
        }
        mayPromptForSpeech = !speech.isReadyWithoutPrompt
        endingCapture = false
        guard speech.startCommandCapture() else {
            if speech.isShowingFailure {
                // Dictation already shows why in the band.
                phase = .idle
            } else {
                fail("Can't listen right now. Try again")
            }
            return
        }
        liveQuestion = ""
        phase = .listening
        listeningSince = now()
        haptic(.listen)
        if hasAPIKey { prewarm() }
        let current = session
        liveTextSubscription = speech.liveTextChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                MainActor.assumeIsolated {
                    guard let self, self.session == current, self.phase == .listening else { return }
                    self.liveQuestion = text
                }
            }
        // Dictation can end the capture on its own: a permission prompt was
        // refused, the recognizer failed to start, or the 2-minute limit.
        captureSubscription = speech.capturingChanges
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] capturing in
                MainActor.assumeIsolated {
                    guard !capturing, let self, self.session == current else { return }
                    self.captureEndedOnItsOwn()
                }
            }
        AppLog.log("Clicky: listening")
    }

    private func captureEndedOnItsOwn() {
        guard phase == .listening, !endingCapture, !speech.isCapturingCommand else { return }
        dropCaptureSubscriptions()
        if speech.isShowingFailure {
            AppLog.log("Clicky: listening stopped by dictation (its band shows why)")
            phase = .idle
        } else {
            fail("Stopped listening. Hold ⌃⌥ to ask again")
        }
    }

    private func dropCaptureSubscriptions() {
        liveTextSubscription = nil
        captureSubscription = nil
    }

    private func finishListening() {
        guard phase == .listening else { return }
        let heldFor = now().timeIntervalSince(listeningSince)
        endingCapture = true
        captureSubscription = nil
        phase = .thinking
        let current = session
        let mayHavePrompted = mayPromptForSpeech
        work = Task { [weak self] in
            guard let self else { return }
            let heard = await self.speech.finishCommandCapture()
            guard current == self.session, !Task.isCancelled else { return }
            self.liveTextSubscription = nil
            let question = heard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !question.isEmpty else {
                self.nothingHeard(heldFor: heldFor, mayHavePrompted: mayHavePrompted)
                return
            }
            self.liveQuestion = question
            await self.answer(question, session: current, includeCursor: true)
        }
    }

    private func nothingHeard(heldFor: TimeInterval, mayHavePrompted: Bool) {
        if let problem = speech.permissionProblem {
            fail(problem)
        } else if mayHavePrompted, speech.isReadyWithoutPrompt {
            // The first hold went to the permission prompts.
            hint("Clicky can hear you now. Hold ⌃⌥ and ask")
        } else if speech.isShowingFailure {
            phase = .idle
        } else if heldFor < timing.shortHold {
            hint("Keep holding ⌃⌥ while you speak")
        } else {
            fail("Didn't catch that. Hold ⌃⌥ and speak")
        }
    }

    // MARK: - Answering

    /// Why the answer could not use the screen.
    enum ScreenNotice: Equatable {
        case noPermission
        case needsRestart
        case captureFailed

        var spoken: String {
            switch self {
            case .noPermission: "I can't see your screen until Screen Recording is on."
            case .needsRestart: "Restart SparkV so I can see your screen."
            case .captureFailed: "I couldn't capture your screen this time."
            }
        }
    }

    private func answer(_ question: String, session current: Int, includeCursor: Bool) async {
        AppLog.log("Clicky: asking (\(hasAPIKey ? model.rawValue : "on-device"), \(question.count) chars)")
        var capture: ClickyCapture?
        var notice: ScreenNotice?
        canSeeScreen = screen.hasScreenAccess
        if canSeeScreen {
            do {
                capture = try await ClickyDeadline.run(seconds: timing.captureTimeout) { @MainActor [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.screen.capture()
                }
            } catch is CancellationError {
                return
            } catch is ClickyDeadline.TimedOut {
                AppLog.log("Clicky: screen capture took over \(Int(timing.captureTimeout)) s; answering without the screen")
                notice = .captureFailed
            } catch let failure as ClickyCaptureFailure where failure == .permissionDenied {
                notice = screen.needsRelaunch ? .needsRestart : .noPermission
                canSeeScreen = false
                screen.requestScreenAccess()
            } catch {
                AppLog.log("Clicky: capture failed (\(error)); answering without the screen")
                notice = .captureFailed
            }
        } else {
            notice = screen.needsRelaunch ? .needsRestart : .noPermission
            // A question is a user action: ask (prompt once, then Settings).
            screen.requestScreenAccess()
        }
        guard current == session, !Task.isCancelled else { return }

        let choice: ClickyBackendChoice
        if hasAPIKey {
            var loaded = cachedKey
            if loaded == nil {
                loaded = await keyStore.load()
                guard current == session, !Task.isCancelled else { return }
            }
            guard let key = loaded else {
                fail("Couldn't read the Groq key. Paste it again")
                return
            }
            cachedKey = key
            choice = .groq(key: key, model: model)
        } else {
            choice = .onDevice
        }
        let query = ClickyQuery(
            question: question,
            capture: capture,
            cursor: includeCursor ? capture?.cursorPixel : nil,
            appName: frontmostAppName(),
            history: ClickyPrompt.context(from: exchanges, now: now())
        )
        let backend = makeBackend(choice)
        let started = Date()
        let reply: ClickyReply
        do {
            reply = try await ClickyDeadline.run(seconds: timing.answerTimeout) {
                try await backend.answer(query)
            }
        } catch is CancellationError {
            return
        } catch {
            guard current == session else { return }
            if case VisionClientError.invalidKey = error { cachedKey = nil }
            fail(Self.message(for: error))
            return
        }
        guard current == session, !Task.isCancelled else { return }
        AppLog.log("Clicky: answered in \(Int(Date().timeIntervalSince(started) * 1000)) ms, point=\(reply.point != nil), screen=\(capture != nil)")
        deliver(reply, question: question, capture: capture, notice: notice)
    }

    static func message(for error: any Error) -> String {
        if error is ClickyDeadline.TimedOut { return "That took too long. Try again" }
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return "Couldn't answer that. Try again"
    }

    private func deliver(_ reply: ClickyReply, question: String, capture: ClickyCapture?, notice: ScreenNotice?) {
        let answer = ClickyAnswerText.limited(reply.answer, maxCharacters: Self.maxAnswerCharacters)
        guard !answer.isEmpty else {
            fail("Couldn't answer that. Try again")
            return
        }
        // A point is only meaningful on the screenshot it was read from.
        let point = capture == nil ? nil : reply.point
        let gridPoint = point.flatMap { point -> ClickyPoint? in
            guard let size = capture?.imageSize, size.width > 0, size.height > 0 else { return nil }
            return ClickyPoint(
                x: point.x / size.width * ClickyPrompt.grid,
                y: point.y / size.height * ClickyPrompt.grid,
                label: point.label
            )
        }
        exchanges.insert(ClickyExchange(question: question, answer: answer, date: now(), gridPoint: gridPoint), at: 0)
        if exchanges.count > Self.maxExchanges {
            exchanges.removeLast(exchanges.count - Self.maxExchanges)
        }

        let spoken = notice.map { "\($0.spoken) \(answer)" } ?? answer
        currentAnswer = spoken
        let paged = ClickyAnswerText.pages(spoken, maxCharacters: Self.pageCharacters)
        pages = paged.map(\.text)
        pageStarts = paged.map(\.utf16Start)
        pageIndex = 0
        phase = .answering(pages.first ?? spoken)
        haptic(.answer)

        if let point, let capture {
            let target = ClickyGeometry.screenPoint(
                fromPixel: CGPoint(x: point.x, y: point.y),
                imageSize: capture.imageSize,
                screenFrame: capture.screenFrame
            )
            overlay.show(from: mouseLocation(), to: target, label: point.label, screenFrame: capture.screenFrame)
        }

        pagerTask?.cancel()
        if speaksAnswers {
            speaker.speak(spoken)
            // No voice, or speech never starts: page by reading time instead.
            let current = session
            pagerTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.timing.speechStartGrace ?? 1.5) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.session == current, !self.isSpeaking,
                      case .answering = self.phase else { return }
                self.startReadingPager()
            }
            // Safety net if speech never reports finishing.
            scheduleReset(after: Self.speechSafetyReset(for: spoken), onlyIfAnswering: true)
        } else {
            startReadingPager()
        }
    }

    /// Shows each page for its reading time, then resets.
    private func startReadingPager() {
        pagerTask?.cancel()
        resetTask?.cancel()
        let current = session
        let pages = self.pages.isEmpty ? [currentAnswer] : self.pages
        let first = pageIndex
        let timing = self.timing
        pagerTask = Task { [weak self] in
            var index = min(first, max(0, pages.count - 1))
            while index < pages.count {
                guard let self, self.session == current, case .answering = self.phase else { return }
                self.showPage(index)
                let words = pages[index].split(separator: " ").count
                let seconds = max(timing.minimumPageSeconds, Double(words) * timing.readingSecondsPerWord + timing.pageExtraSeconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { return }
                index += 1
            }
            guard let self, self.session == current else { return }
            self.scheduleReset(after: 0.5, onlyIfAnswering: true)
        }
    }

    private func showPage(_ index: Int) {
        guard index >= 0, index < pages.count, case .answering = phase else { return }
        pageIndex = index
        phase = .answering(pages[index])
    }

    private func speechReached(_ offset: Int) {
        guard case .answering = phase, !pages.isEmpty else { return }
        let index = ClickyAnswerText.pageIndex(forUTF16Offset: offset, pageStarts: pageStarts)
        if index != pageIndex { showPage(index) }
    }

    /// Speech began. When it began late (a voice that loads slowly, after
    /// `speechStartGrace`), the reading-time pager has already taken over:
    /// hand the band back to the speech so it neither pages twice nor resets
    /// while Clicky is still talking.
    private func speechStarted() {
        guard speaksAnswers else {
            speaker.stop()
            isSpeaking = false
            return
        }
        isSpeaking = true
        guard case .answering = phase else { return }
        pagerTask?.cancel()
        pagerTask = nil
        scheduleReset(after: Self.speechSafetyReset(for: currentAnswer), onlyIfAnswering: true)
    }

    /// Resets the band if speech never reports finishing.
    static func speechSafetyReset(for text: String) -> Double {
        max(8, Double(text.split(separator: " ").count) * 0.45 + 6)
    }

    private func speechFinished() {
        isSpeaking = false
        if case .answering = phase {
            pagerTask?.cancel()
            showPage(pages.count - 1)
            scheduleReset(after: timing.afterSpeech, onlyIfAnswering: true)
        }
    }

    private func interruptOutput() {
        pagerTask?.cancel()
        pagerTask = nil
        speaker.stop()
        isSpeaking = false
        overlay.dismiss(animated: true)
    }

    private func fail(_ message: String) {
        AppLog.log("Clicky: \(message)")
        dropCaptureSubscriptions()
        phase = .failed(message)
        scheduleReset(after: timing.failureReset, onlyIfAnswering: false)
    }

    /// A short, non-alarming note (shown like a failure, cleared sooner).
    private func hint(_ message: String) {
        AppLog.log("Clicky: \(message)")
        dropCaptureSubscriptions()
        phase = .failed(message)
        scheduleReset(after: timing.hintReset, onlyIfAnswering: false)
    }

    private func scheduleReset(after seconds: Double, onlyIfAnswering: Bool) {
        resetTask?.cancel()
        let current = session
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session == current else { return }
            switch self.phase {
            case .answering:
                self.pagerTask?.cancel()
                self.phase = .idle
            case .failed where !onlyIfAnswering:
                self.phase = .idle
            default:
                break
            }
        }
    }
}

// MARK: - Answer text

/// Fits answers to speech and to the two-line band.
enum ClickyAnswerText {
    struct Page: Equatable {
        var text: String
        /// UTF-16 offset of the page in the full text (speech progress unit).
        var utf16Start: Int
    }

    /// At most `maxCharacters`, cut after a sentence when one ends late
    /// enough, otherwise at a word with an ellipsis.
    static func limited(_ text: String, maxCharacters: Int) -> String {
        let clean = ClickyReplyParser.cleanAnswer(text)
        guard clean.count > maxCharacters else { return clean }
        let prefix = String(clean.prefix(maxCharacters))
        if let end = lastSentenceEnd(in: prefix), prefix.distance(from: prefix.startIndex, to: end) >= maxCharacters * 2 / 5 {
            return String(prefix[..<end]).trimmingCharacters(in: .whitespaces)
        }
        if let space = prefix.lastIndex(of: " ") {
            return String(prefix[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
        }
        return String(prefix.dropLast()) + "…"
    }

    /// Index just past the last ".", "!" or "?" that ends a sentence.
    private static func lastSentenceEnd(in text: String) -> String.Index? {
        var result: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next] == " " {
                result = next
            }
            index = next
        }
        return result
    }

    /// Splits into sentences, keeping their punctuation.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if ".!?".contains(c), i + 1 == chars.count || chars[i + 1] == " " {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// Band pages of at most `maxCharacters`, whole sentences where they fit,
    /// with their UTF-16 offsets in `text` for following speech.
    static func pages(_ text: String, maxCharacters: Int) -> [Page] {
        let clean = ClickyReplyParser.cleanAnswer(text)
        guard !clean.isEmpty else { return [Page(text: "", utf16Start: 0)] }
        var chunks: [String] = []
        for sentence in sentences(clean) {
            if sentence.count <= maxCharacters {
                chunks.append(sentence)
                continue
            }
            var line = ""
            for word in sentence.split(separator: " ") {
                var word = String(word)
                while word.count > maxCharacters {
                    if !line.isEmpty { chunks.append(line); line = "" }
                    chunks.append(String(word.prefix(maxCharacters)))
                    word = String(word.dropFirst(maxCharacters))
                }
                if line.isEmpty { line = word }
                else if line.count + 1 + word.count <= maxCharacters { line += " " + word }
                else { chunks.append(line); line = word }
            }
            if !line.isEmpty { chunks.append(line) }
        }
        // Pack short chunks (sentences) together.
        var packed: [String] = []
        for chunk in chunks {
            if let last = packed.last, last.count + 1 + chunk.count <= maxCharacters {
                packed[packed.count - 1] = last + " " + chunk
            } else {
                packed.append(chunk)
            }
        }
        // Offsets: pages are in order and separated by single spaces.
        var result: [Page] = []
        var searchFrom = clean.startIndex
        for page in packed {
            if let range = clean.range(of: page, range: searchFrom..<clean.endIndex) {
                result.append(Page(text: page, utf16Start: clean.utf16.distance(from: clean.utf16.startIndex, to: range.lowerBound)))
                searchFrom = range.upperBound
            } else {
                let start = result.last.map { $0.utf16Start + $0.text.utf16.count + 1 } ?? 0
                result.append(Page(text: page, utf16Start: start))
            }
        }
        return result
    }

    /// The page holding `offset`.
    static func pageIndex(forUTF16Offset offset: Int, pageStarts: [Int]) -> Int {
        var index = 0
        for (i, start) in pageStarts.enumerated() where start <= offset { index = i }
        return index
    }
}

// MARK: - Deadline

/// Runs `operation` with a time limit. On timeout (or cancellation of the
/// caller) the operation's task is cancelled and the caller resumes at once,
/// even when the operation ignores cancellation (Vision, the on-device model).
enum ClickyDeadline {
    struct TimedOut: Error, Equatable {}

    static func run<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                race.attach(continuation)
                race.add(Task {
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                })
                race.add(Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    if !Task.isCancelled { race.finish(.failure(TimedOut())) }
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var pending: Result<T, any Error>?
        private var done = false
        private var tasks: [Task<Void, Never>] = []

        func attach(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func add(_ task: Task<Void, Never>) {
            lock.lock()
            if done {
                lock.unlock()
                task.cancel()
                return
            }
            tasks.append(task)
            lock.unlock()
        }

        func finish(_ result: Result<T, any Error>) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { pending = result }
            let tasks = self.tasks
            self.tasks = []
            lock.unlock()
            continuation?.resume(with: result)
            for task in tasks { task.cancel() }
        }
    }
}

// MARK: - Speech output

/// Speaks answers with the best installed system voice for the user's
/// language. Stoppable at any time; reports progress for the band pager.
@MainActor
final class ClickySpeaker: NSObject, AVSpeechSynthesizerDelegate, ClickySpeaking {
    var onStart: (@MainActor () -> Void)?
    var onFinish: (@MainActor () -> Void)?
    var onProgress: (@MainActor (Int) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var current: ObjectIdentifier?
    private var cachedVoice: (language: String, voice: AVSpeechSynthesisVoice?)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice()
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.04)
        current = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Enumerating voices takes tens of milliseconds: once per language.
    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        if let cachedVoice, cachedVoice.language == language { return cachedVoice.voice }
        let voice = Self.bestVoice(language: language)
        cachedVoice = (language, voice)
        return voice
    }

    private static func bestVoice(language: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
            switch quality {
            case .premium: 3
            case .enhanced: 2
            default: 1
            }
        }
        let region = Locale.current.region?.identifier
        let best = candidates.max { a, b in
            let ra = rank(a.quality) * 2 + (region.map { a.language.hasSuffix($0) } == true ? 1 : 0)
            let rb = rank(b.quality) * 2 + (region.map { b.language.hasSuffix($0) } == true ? 1 : 0)
            return ra < rb
        }
        return best ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.current == id else { return }
            self.onStart?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        let offset = characterRange.location
        Task { @MainActor in
            guard self.current == id else { return }
            self.onProgress?(offset)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.current == id else { return }
            self.current = nil
            self.onFinish?()
        }
    }
}

// MARK: - Screenshot

/// One screenshot of the display under the mouse, ready to send.
struct ClickyCapture: @unchecked Sendable {
    let image: CGImage
    let jpeg: Data
    /// Pixel size of `image` (≤ 1568 px on the long edge).
    let imageSize: CGSize
    /// Frame of the captured display in global screen points.
    let screenFrame: CGRect
    /// Mouse position in `image` pixels.
    let cursorPixel: CGPoint
}

enum ClickyCaptureFailure: Error, Equatable {
    case permissionDenied
    case noDisplay
    case encodingFailed
}

/// Image helpers shared by the capture and the tests.
enum ClickyImage {
    /// Groq takes base64 images up to 4 MB; stay well under.
    static let maxJPEGBytes = 3_000_000

    static func downscale(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// JPEG under `maxJPEGBytes`, lowering quality for busy screens.
    static func sendableJPEG(_ image: CGImage) -> Data? {
        for quality in [0.8, 0.6, 0.45] {
            guard let data = jpegData(image, quality: quality) else { return nil }
            if data.count <= maxJPEGBytes { return data }
        }
        return nil
    }
}

// MARK: - Backends

/// Groq vision with the user's key. Fast OCR adds text positions as grounding
/// hints and snaps a point onto the text it names.
struct ClickyGroqBackend: ClickyAnswering {
    let client: VisionClient
    /// OCR longer than this is skipped (the screenshot alone still works).
    var ocrBudget: Double = 1.2

    func answer(_ query: ClickyQuery) async throws -> ClickyReply {
        guard let capture = query.capture else {
            return try await client.ask(ClickyVisionInput(
                question: query.question, jpeg: nil, imageSize: .zero, cursor: nil,
                appName: query.appName, history: query.history
            ))
        }
        let box = ClickyOnDevice.ClickyImageBox(image: capture.image)
        let size = capture.imageSize
        let lines = (try? await ClickyDeadline.run(seconds: ocrBudget) {
            await ClickyOnDevice.recognizeText(in: box, imageSize: size, fast: true)
        }) ?? []
        let hints = ClickyGrounding.hints(from: lines, question: query.question, cursor: query.cursor, imageSize: size)
        var reply = try await client.ask(ClickyVisionInput(
            question: query.question, jpeg: capture.jpeg, imageSize: size, cursor: query.cursor,
            appName: query.appName, history: query.history, screenText: hints
        ))
        reply.point = reply.point.map { ClickyGrounding.refine($0, lines: lines, imageSize: size) }
        return reply
    }
}

/// Apple's on-device model over OCR text (or the question alone).
struct ClickyOnDeviceBackend: ClickyAnswering {
    func answer(_ query: ClickyQuery) async throws -> ClickyReply {
        try await ClickyOnDevice.answer(
            question: query.question, image: query.capture?.image, imageSize: query.capture?.imageSize ?? .zero,
            cursor: query.cursor, appName: query.appName, history: query.history
        )
    }
}

/// OCR lines as prompt hints and as anchors for model points.
enum ClickyGrounding {
    static let hintBudget = 1200

    static func hints(from lines: [ClickyOnDevice.TextLine], question: String, cursor: CGPoint?, imageSize: CGSize) -> [ClickyTextHint] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        return ClickyOnDevice.select(lines, question: question, cursor: cursor, budget: hintBudget)
            .filter { $0.text.count >= 2 }
            .map {
                ClickyTextHint(
                    text: $0.text,
                    x: Int(($0.center.x / imageSize.width * ClickyPrompt.grid).rounded()),
                    y: Int(($0.center.y / imageSize.height * ClickyPrompt.grid).rounded())
                )
            }
    }

    /// Moves a vision-model point onto the OCR line its label names, when
    /// that line is close (models are often a few percent off on text).
    /// Icons and unlabeled targets stay where the model put them.
    static func refine(_ point: ClickyPoint, lines: [ClickyOnDevice.TextLine], imageSize: CGSize) -> ClickyPoint {
        let label = normalized(point.label)
        guard label.count >= 3 else { return point }
        let here = CGPoint(x: point.x, y: point.y)
        let reach = 0.12 * max(imageSize.width, imageSize.height)
        let matches = lines.filter {
            let text = normalized($0.text)
            return text == label || (text.count >= 3 && (label.contains(text) || text.contains(label)) && text.count <= label.count * 3)
        }
        guard let best = matches.min(by: { distance($0.center, here) < distance($1.center, here) }),
              distance(best.center, here) <= reach else { return point }
        return ClickyPoint(x: best.center.x, y: best.center.y, label: point.label)
    }

    /// Lowercased, without generic element words ("Export button" -> "export").
    static func normalized(_ text: String) -> String {
        let generic: Set<String> = ["button", "menu", "tab", "field", "icon", "link", "the", "option", "item"]
        return text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !generic.contains($0) }
            .joined(separator: " ")
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - On-device

/// Without an API key: Vision OCR of the screenshot plus Apple's on-device
/// model, which reasons over the recognized text and its positions only.
/// With no screenshot it answers from the question alone.
enum ClickyOnDevice {
    struct TextLine: Sendable, Equatable {
        let text: String
        /// Pixel rect in the screenshot (origin top-left).
        let rect: CGRect
        var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }

    enum Unavailable: Equatable, Sendable {
        case needsNewerMacOS
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady
        case unknown
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable(Unavailable)
        case refused
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable(.needsNewerMacOS): "On-device answers need macOS 26. Add a Groq key"
            case .unavailable(.deviceNotEligible): "This Mac can't run Apple's model. Add a Groq key"
            case .unavailable(.appleIntelligenceOff): "Turn on Apple Intelligence, or add a Groq key"
            case .unavailable(.modelNotReady): "Apple's model is still downloading. Try later"
            case .unavailable(.unknown): "Couldn't answer on-device. Add a Groq key"
            case .refused: "Apple's model declined to answer that"
            case .timedOut: "Apple's model took too long. Try again"
            }
        }
    }

    enum ModelErrorKind: Equatable {
        case contextTooLong
        case refused
        case busy
        case unavailable
        case other
    }

    /// FoundationModels renamed its errors in macOS 27 (GenerationError ->
    /// LanguageModelError); matching the case names covers both.
    static func classify(_ error: any Error) -> ModelErrorKind {
        let text = String(describing: error)
        if text.contains("exceededContextWindowSize") || text.contains("contextSizeExceeded") { return .contextTooLong }
        if text.contains("guardrailViolation") || text.contains("refusal") { return .refused }
        if text.contains("rateLimited") || text.contains("concurrentRequests") { return .busy }
        if text.contains("assetsUnavailable") { return .unavailable }
        return .other
    }

    /// Prompt budget for OCR lines; the on-device model has a 4096-token context.
    static let lineCharacterBudget = 2600
    static let modelTimeout: Double = 20

    static func answer(
        question: String, image: CGImage?, imageSize: CGSize, cursor: CGPoint?, appName: String?,
        history: [ClickyExchange] = []
    ) async throws -> ClickyReply {
        let hasScreen = image != nil && imageSize.width > 0 && imageSize.height > 0
        let lines: [TextLine]
        if let image, hasScreen {
            lines = await readScreen(ClickyImageBox(image: image), imageSize: imageSize)
        } else {
            lines = []
        }
        var unavailable = Unavailable.needsNewerMacOS

        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .general, guardrails: .default)
            switch model.availability {
            case .available:
                var selected = select(lines, question: question, cursor: cursor)
                for _ in 0..<2 {
                    let prompt = prompt(
                        question: question, lines: selected, imageSize: imageSize, cursor: cursor,
                        appName: appName, previous: history.last, hasScreen: hasScreen
                    )
                    do {
                        let text = try await ClickyDeadline.run(seconds: modelTimeout) {
                            let session = LanguageModelSession(model: model, instructions: instructions)
                            let response = try await session.respond(
                                to: prompt,
                                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300)
                            )
                            return response.content
                        }
                        if var reply = ClickyReplyParser.parse(text, imageSize: imageSize) {
                            reply.point = selected.isEmpty ? nil : reply.point.map { snap($0, to: selected) }
                            return reply
                        }
                        AppLog.log("Clicky: on-device reply unparseable")
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch is ClickyDeadline.TimedOut {
                        throw Failure.timedOut
                    } catch {
                        let kind = classify(error)
                        AppLog.log("Clicky: on-device model error (\(kind)) \(error)")
                        if kind == .refused { throw Failure.refused }
                        if kind == .contextTooLong, selected.count > 4 {
                            selected = Array(selected.prefix(selected.count / 2))
                            continue
                        }
                        if kind == .unavailable { unavailable = .modelNotReady }
                        else { unavailable = .unknown }
                        break
                    }
                }
                if unavailable == .needsNewerMacOS { unavailable = .unknown }
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: unavailable = .deviceNotEligible
                case .appleIntelligenceNotEnabled: unavailable = .appleIntelligenceOff
                case .modelNotReady: unavailable = .modelNotReady
                @unknown default: unavailable = .unknown
                }
            }
        }
        if let reply = keywordReply(question: question, lines: lines) {
            return reply
        }
        throw Failure.unavailable(unavailable)
    }

    struct ClickyImageBox: @unchecked Sendable {
        let image: CGImage
    }

    /// Remembers that the accurate recognizer is broken on this Mac (its
    /// neural model fails to compile, e.g. on a full disk, after ~40 s with a
    /// bare "nilError"), so later questions go straight to the fast one.
    final class OCRHealth: @unchecked Sendable {
        private let lock = NSLock()
        private var accurateFailedAt: Date?
        /// Try the accurate recognizer again after this long.
        static let retryAfter: TimeInterval = 60 * 60

        var accurateUsable: Bool {
            lock.withLock {
                guard let at = accurateFailedAt else { return true }
                return Date().timeIntervalSince(at) > Self.retryAfter
            }
        }

        func accurateFailed() { lock.withLock { accurateFailedAt = Date() } }
        func accurateWorked() { lock.withLock { accurateFailedAt = nil } }
    }

    static let ocrHealth = OCRHealth()
    /// Accurate OCR normally takes well under a second on a screenshot.
    static let accurateOCRTimeout: Double = 4
    static let fastOCRTimeout: Double = 2

    /// OCR for the answer itself. The fast pass runs first (a fraction of a
    /// second) so there is always something to go on; the accurate pass
    /// replaces it when it finishes in time. An accurate pass that stalls is
    /// not tried again for a while: while it hangs, Vision queues other text
    /// requests behind it.
    static func readScreen(_ box: ClickyImageBox, imageSize: CGSize) async -> [TextLine] {
        let fastLines = (try? await ClickyDeadline.run(seconds: fastOCRTimeout, {
            await recognizeText(in: box, imageSize: imageSize, fast: true)
        })) ?? []
        guard ocrHealth.accurateUsable else { return fastLines }
        do {
            let accurate = try await ClickyDeadline.run(seconds: accurateOCRTimeout, {
                await recognizeText(in: box, imageSize: imageSize)
            })
            return accurate.isEmpty ? fastLines : accurate
        } catch {
            AppLog.log("Clicky: accurate OCR took over \(Int(accurateOCRTimeout)) s; fast OCR from now on")
            ocrHealth.accurateFailed()
            return fastLines
        }
    }

    /// `fast` trades accuracy for speed (a grounding hint, not the answer).
    /// When the accurate recognizer fails, the fast one is tried at once.
    static func recognizeText(in box: ClickyImageBox, imageSize: CGSize, fast: Bool = false) async -> [TextLine] {
        let health = ocrHealth
        return await Task.detached(priority: .userInitiated) {
            func run(_ level: VNRequestTextRecognitionLevel) -> [VNRecognizedTextObservation]? {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = level
                request.usesLanguageCorrection = level == .accurate
                do {
                    try VNImageRequestHandler(cgImage: box.image, options: [:]).perform([request])
                    if level == .accurate { health.accurateWorked() }
                    return request.results ?? []
                } catch {
                    AppLog.log("Clicky: OCR (\(level == .fast ? "fast" : "accurate")) failed \(error)")
                    if level == .accurate { health.accurateFailed() }
                    return nil
                }
            }
            let useFast = fast || !health.accurateUsable
            guard let observations = run(useFast ? .fast : .accurate) ?? (useFast ? nil : run(.fast)) else { return [] }
            return observations.compactMap { observation -> TextLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TextLine(text: text, rect: pixelRect(fromNormalized: observation.boundingBox, imageSize: imageSize))
            }
        }.value
    }

    /// Vision's normalized rect (origin bottom-left) to screenshot pixels (origin top-left).
    static func pixelRect(fromNormalized box: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: box.minX * imageSize.width,
            y: (1 - box.maxY) * imageSize.height,
            width: box.width * imageSize.width,
            height: box.height * imageSize.height
        )
    }

    /// Lines that mention the question's words first, then those nearest the
    /// pointer, within the prompt budget; returned in reading order.
    static func select(_ lines: [TextLine], question: String, cursor: CGPoint?, budget: Int = lineCharacterBudget) -> [TextLine] {
        let words = keywords(question)
        let ranked = lines.enumerated().sorted { a, b in
            let ma = matchScore(a.element.text, words), mb = matchScore(b.element.text, words)
            if ma != mb { return ma > mb }
            if let cursor {
                return distance(a.element.center, cursor) < distance(b.element.center, cursor)
            }
            return a.offset < b.offset
        }
        var remaining = budget
        var kept: [(Int, TextLine)] = []
        for (index, line) in ranked {
            let cost = min(line.text.count, 80) + 16
            guard remaining - cost >= 0 else { continue }
            remaining -= cost
            kept.append((index, line))
        }
        return kept.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static let instructions = """
    You are Clicky, a helpful Mac screen assistant whose answers are spoken aloud. You cannot see the screen. \
    Instead you may get the text that was found on it, one line per item, each with the pixel coordinates of its \
    center in a screenshot (origin top-left, y grows downward). Use the text and its positions to answer the \
    user's question about what is on screen. When there is no screen text, answer from general knowledge of macOS \
    and its apps, and never claim to see the screen.
    Reply with only a JSON object: {"answer": "<1-3 short spoken sentences>", "point": {"x": <number>, "y": <number>, "label": "<element name>"} or null}.
    Copy x and y from the item the user should look at or click, and use its text as the label; use null when no single item fits \
    or there is no screen text. Never say coordinates or numbers from the positions; say where it is in words \
    (top right, below the title). No markdown. If the text does not answer the question, say so briefly.
    """

    static func prompt(
        question: String, lines: [TextLine], imageSize: CGSize, cursor: CGPoint?, appName: String?,
        previous: ClickyExchange? = nil, hasScreen: Bool = true
    ) -> String {
        var parts: [String] = []
        if hasScreen {
            parts.append("Screenshot size: \(Int(imageSize.width))x\(Int(imageSize.height)) pixels.")
        } else {
            parts.append("No screen text is available this time (the screen could not be captured).")
        }
        if let previous {
            // The small context window fits one earlier turn, for follow-ups.
            parts.append("Previous question: \(previous.question.prefix(200))")
            parts.append("Your previous answer: \(previous.answer.prefix(300))")
        }
        if let appName, !appName.isEmpty { parts.append("Frontmost app: \(appName).") }
        if hasScreen {
            if let cursor { parts.append("Mouse pointer at (\(Int(cursor.x)), \(Int(cursor.y))).") }
            if lines.isEmpty {
                parts.append("No text was found on screen.")
            } else {
                parts.append("Text on screen:")
                for line in lines {
                    let text = line.text.count > 80 ? String(line.text.prefix(79)) + "…" : line.text
                    parts.append("- \"\(text)\" at (\(Int(line.center.x)), \(Int(line.center.y)))")
                }
            }
        }
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n")
    }

    /// Small models paraphrase coordinates; move the point onto the line it names.
    static func snap(_ point: ClickyPoint, to lines: [TextLine]) -> ClickyPoint {
        let label = point.label.lowercased()
        if label.count >= 2, let named = lines.first(where: {
            let text = $0.text.lowercased()
            return text == label || (text.contains(label) && label.count >= 3) || (label.contains(text) && text.count >= 3)
        }) {
            return ClickyPoint(x: named.center.x, y: named.center.y, label: point.label)
        }
        let here = CGPoint(x: point.x, y: point.y)
        if let nearest = lines.min(by: { distance($0.center, here) < distance($1.center, here) }),
           distance(nearest.center, here) < 60 {
            return ClickyPoint(x: nearest.center.x, y: nearest.center.y, label: point.label)
        }
        return point
    }

    /// Last resort without a language model: point at the line that best
    /// matches the question's words.
    static func keywordReply(question: String, lines: [TextLine]) -> ClickyReply? {
        let words = keywords(question)
        guard !words.isEmpty,
              let best = lines.max(by: { matchScore($0.text, words) < matchScore($1.text, words) }),
              matchScore(best.text, words) > 0
        else { return nil }
        let label = best.text.count > 32 ? String(best.text.prefix(31)) + "…" : best.text
        return ClickyReply(
            answer: "I can only read the text on screen right now. I think it's \(label), here.",
            point: ClickyPoint(x: best.center.x, y: best.center.y, label: label)
        )
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "how", "what", "where", "which", "who", "why", "when", "can", "could", "would",
        "should", "this", "that", "there", "here", "with", "into", "onto", "from", "about", "does", "did",
        "are", "was", "were", "you", "your", "find", "click", "button", "show", "tell", "please", "want",
        "need", "make", "get", "use", "screen", "page", "app", "open", "see", "its", "it's", "is", "do", "i",
    ]

    static func keywords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    static func matchScore(_ text: String, _ words: [String]) -> Int {
        guard !words.isEmpty else { return 0 }
        let lower = text.lowercased()
        return words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
