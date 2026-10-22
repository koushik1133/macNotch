import AppKit
import Combine
import SwiftUI

// Meeting Intelligence, part A: the start of a call.
//
// When a call is detected, one band offers Record notes / Captions /
// Translate (with "Always for <service>"), a remembered `.auto` rule starts
// after a visible countdown with Cancel, and a brief (agenda, what I owe
// these people, last time, Spaces) loads alongside. Once recording really
// runs, a `MeetingIntelSession` goes to part B (live) and, when it stops by
// any route, to part C (wrap-up). `MeetingIntelCenter` wires A, B and C.
//
// Privacy: recording never starts without a click or a visible countdown
// with Cancel; the consent line is in the band, in the countdown and in a
// toast at every start (manual starts too). Nothing here sends or writes
// to other apps; Calendars is read only when already granted.
//
// Notes for the other parts / changes asked of the shared types: none
// required. Additions in this part (own files only): `MeetingCallEventDiffer`,
// `MeetingStartCoordinator.onPlanChanged`, `changePlan(_:)`, `syncPhase()`,
// `MeetingIntelCenter.coordinator` (the contract's `start` property, renamed
// because Swift does not allow a `start` property next to `func start()`),
// and the views in start-Views.swift.

// MARK: - Call events from activeCall

/// Turns successive `MeetingCallDetector.activeCall` values into events:
/// nil -> call is `.started`, the same key with a new title or event is
/// `.updated`, call -> nil is `.ended`. A different key ends the old call
/// and starts the new one (`events(_:)` returns both).
struct MeetingCallEventDiffer {
    private(set) var last: DetectedCall?

    init(last: DetectedCall? = nil) { self.last = last }

    mutating func events(_ call: DetectedCall?) -> [MeetingCallEvent] {
        defer { last = call }
        switch (last, call) {
        case (nil, nil):
            return []
        case (nil, let new?):
            return [.started(new)]
        case (let old?, nil):
            return [.ended(old)]
        case (let old?, let new?):
            if old.key != new.key { return [.ended(old), .started(new)] }
            return old == new ? [] : [.updated(new)]
        }
    }

    /// The newest event for this value (a key change reports `.started`;
    /// use `events(_:)` to also see the `.ended`).
    mutating func next(_ call: DetectedCall?) -> MeetingCallEvent? {
        events(call).last
    }
}

// MARK: - Coordinator

@MainActor
final class MeetingStartCoordinator: ObservableObject {
    enum Stage: Equatable {
        case idle
        case prompting(DetectedCall)
        case countingDown(DetectedCall, MeetingStartPlan, secondsLeft: Int)
        case live(MeetingIntelSession)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var brief: MeetingBrief?
    /// The band's "Always for <service>" box (reset for each new offer).
    @Published var rememberChoice = false

    /// Fired after recording really started for a session.
    var onSessionStarted: ((MeetingIntelSession) -> Void)?
    /// Fired when that session's recording ended (any route).
    var onSessionEnded: ((MeetingIntelSession) -> Void)?
    /// Fired when `changePlan(_:)` changed a live session's plan.
    var onPlanChanged: ((MeetingIntelSession) -> Void)?

    /// Recording seam. Default: notes for a detected call go through
    /// `assistant.startDetectedCall()` (records the active call, opens the
    /// notepad, stops on its own when the call ends); otherwise
    /// `assistant.start(title:calendarEventID:)`, and this coordinator stops
    /// that recording when its call ends. INTEGRATION.md step 6 swaps in the
    /// detector-aware start once MeetingAssistant exposes it.
    var startRecording: (DetectedCall?, MeetingStartPlan) -> Void = { _, _ in }
    /// Whether MeetingAssistant should write minutes for a recording: false
    /// for Captions / Translate plans, true again when `changePlan(_:)` turns
    /// notes back on. Called for every session, however it started. The
    /// default does nothing (minutes are always written) until
    /// INTEGRATION.md steps 2 and 6 wire it to `MeetingAssistant.skipNotesFor`.
    var setWritesNotes: (UUID, Bool) -> Void = { _, _ in }

    /// Test seams.
    var clock: () -> Date = { Date() }
    var countdownStep: TimeInterval = 1

    let assistant: MeetingAssistant
    let translation: LiveTranslationController?
    let prefs: MeetingIntelPreferences

    private let activities: ActivityCenter
    private let calendar: () -> [CalendarMeeting]
    private let spaces: SpaceStore?
    private let permissions: PermissionCenter

    private var subscriptions: Set<AnyCancellable> = []
    private var differ = MeetingCallEventDiffer()
    /// Calls answered here (Not now, Never, already recorded): no offer
    /// again until the call ends.
    private var declined: Set<String> = []
    /// What the next recording is for (set right before it starts).
    private var pending: (call: DetectedCall?, plan: MeetingStartPlan)?
    private var pendingExpiry: Task<Void, Never>?
    /// A recording this coordinator started without the detector's
    /// auto-stop: stop it when this call ends.
    private var stopsWithCallKey: String?
    /// Translation as it was before a session turned it on.
    private var translationBefore: (enabled: Bool, target: String)?
    private var countdownTask: Task<Void, Never>?
    private var briefTask: Task<Void, Never>?
    /// What the current brief was built for ("<title>|<eventID>").
    private var briefKey: String?

    init(activities: ActivityCenter,
         assistant: MeetingAssistant,
         translation: LiveTranslationController?,
         calendar: @escaping () -> [CalendarMeeting],
         spaces: SpaceStore?,
         prefs: MeetingIntelPreferences? = nil,
         permissions: PermissionCenter? = nil) {
        // Optional defaults (not `= .shared`): main-actor defaults warn in Swift 5.
        self.activities = activities
        self.assistant = assistant
        self.translation = translation
        self.calendar = calendar
        self.spaces = spaces
        self.prefs = prefs ?? .shared
        self.permissions = permissions ?? .shared
        startRecording = { [weak assistant] call, plan in
            guard let assistant else { return }
            if plan.keepNotes, call != nil {
                assistant.startDetectedCall()
            } else {
                assistant.start(title: call?.title, calendarEventID: call?.calendarEventID)
            }
        }
    }

    // MARK: Derived state

    /// The call the band is offering for (prompt or countdown).
    var offeredCall: DetectedCall? {
        switch stage {
        case .prompting(let call): call
        case .countingDown(let call, _, _): call
        case .idle, .live: nil
        }
    }

    var session: MeetingIntelSession? {
        if case .live(let session) = stage { return session }
        return nil
    }

    // MARK: Lifecycle

    /// Subscribes to `assistant.callDetector.$activeCall` and `assistant.$phase`.
    /// Both are handled on the next main-actor turn: `@Published` emits
    /// before the value is stored, and MeetingAssistant reacts to the same
    /// call (its own `onEvent`) right after `activeCall` changes, so by then
    /// its prompt exists and can be taken over.
    func attach() {
        subscriptions = []
        differ = MeetingCallEventDiffer(last: nil)
        assistant.callDetector.$activeCall
            .removeDuplicates()
            .sink { [weak self] call in
                Task { @MainActor [weak self] in self?.activeCallChanged(call) }
            }
            .store(in: &subscriptions)
        assistant.$phase
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncPhase() }
            }
            .store(in: &subscriptions)
    }

    func detach() {
        subscriptions = []
        countdownTask?.cancel()
        countdownTask = nil
        briefTask?.cancel()
        briefTask = nil
        pendingExpiry?.cancel()
        activities.dismiss(id: MeetingIntelActivity.startPrompt)
        activities.dismiss(id: Self.consentActivityID)
        if case .live = stage {} else { stage = .idle }
    }

    /// Feeds one `activeCall` value through the differ. Internal for tests.
    func activeCallChanged(_ call: DetectedCall?) {
        for event in differ.events(call) { handle(event) }
    }

    // MARK: Call events

    func handle(_ event: MeetingCallEvent) {
        switch event {
        case .started(let call): callStarted(call)
        case .updated(let call): callUpdated(call)
        case .ended(let call): callEnded(call)
        }
    }

    /// For `MeetingAssistant.callOfferOverride` (INTEGRATION.md steps 2 and 6): true
    /// when MeetingIntel shows the offer for this call itself (rule `.ask`
    /// or `.auto`) or deliberately suppresses it (rule `.never`, or the
    /// user already said Not now). False when MeetingIntel is off, so the
    /// assistant's own simple prompt shows as before.
    func wantsOffer(for call: DetectedCall) -> Bool {
        prefs.isEnabled && assistant.detectCalls
    }

    private func callStarted(_ call: DetectedCall) {
        guard prefs.isEnabled, assistant.detectCalls else { return }
        if declined.contains(call.key) {
            suppressAssistantOffer(call)
            return
        }
        if case .live(var session) = stage {
            // Recording started by hand just before the call was noticed:
            // tie the session to it (it still won't stop on its own).
            if session.callKey == nil {
                session.callKey = call.key
                session.kind = MeetingKindKey(call: call)
                session.serviceName = call.serviceName
                if session.calendarEventID == nil { session.calendarEventID = call.calendarEventID }
                stage = .live(session)
            }
            declined.insert(call.key)
            return
        }
        // The assistant records detected calls on its own: no prompt, the
        // session is built from the phase change; the brief still loads.
        if assistant.autoStartDetectedCalls {
            loadBrief(title: call.title, eventID: call.calendarEventID)
            return
        }
        guard Self.isIdle(assistant.phase) else { return }

        let kind = MeetingKindKey(call: call)
        rememberChoice = false
        switch prefs.rule(for: kind) {
        case .never:
            suppressAssistantOffer(call)
            declined.insert(call.key)
        case .ask:
            suppressAssistantOffer(call)
            stage = .prompting(call)
            loadBrief(title: call.title, eventID: call.calendarEventID)
            postPrompt(call, isNew: true)
        case .auto(let plan):
            suppressAssistantOffer(call)
            loadBrief(title: call.title, eventID: call.calendarEventID)
            beginCountdown(call, plan)
        }
    }

    private func callUpdated(_ call: DetectedCall) {
        if let pending, pending.call?.key == call.key { self.pending = (call, pending.plan) }
        switch stage {
        case .prompting(let old) where old.key == call.key:
            stage = .prompting(call)
            if old.title != call.title || old.calendarEventID != call.calendarEventID {
                loadBrief(title: call.title, eventID: call.calendarEventID)
            }
            postPrompt(call, isNew: false)
        case .countingDown(let old, let plan, let left) where old.key == call.key:
            stage = .countingDown(call, plan, secondsLeft: left)
            if old.title != call.title || old.calendarEventID != call.calendarEventID {
                loadBrief(title: call.title, eventID: call.calendarEventID)
            }
            postCountdown(call, plan, secondsLeft: left)
        case .live(var session) where session.callKey == call.key:
            // MeetingAssistant renames a "Zoom call" recording once the
            // calendar event shows up: follow it.
            var changed = false
            if let title = assistant.current?.title, assistant.current?.id == session.id, title != session.title {
                session.title = title
                changed = true
            }
            if session.calendarEventID == nil, let eventID = call.calendarEventID {
                session.calendarEventID = eventID
                changed = true
                loadBrief(title: session.title, eventID: eventID)
            }
            if changed { stage = .live(session) }
        default:
            break
        }
    }

    private func callEnded(_ call: DetectedCall) {
        declined.remove(call.key)
        if offeredCall?.key == call.key {
            clearOffer()
            stage = .idle
            brief = nil
            briefKey = nil
        }
        if stopsWithCallKey == call.key {
            stopsWithCallKey = nil
            // Turning call detection off clears `activeCall` without the call
            // really ending (MeetingCallDetector.stop()): that must never
            // stop a recording, the same rule MeetingAssistant keeps.
            if assistant.phase == .recording, assistant.callDetector.isRunning {
                // MeetingAssistant just said "<App> ended · Still recording":
                // this recording ends with its call, so that band is wrong.
                activities.dismiss(id: MeetingAssistant.ActivityID.notes)
                assistant.stop()
            }
        }
    }

    /// Hides MeetingAssistant's own "Take notes?" prompt for this call (until
    /// the `callOfferOverride` hook in INTEGRATION.md step 2 is applied, after
    /// which there is none to hide).
    private func suppressAssistantOffer(_ call: DetectedCall) {
        if assistant.promptedCall?.key == call.key { assistant.dismissDetectedCall() }
    }

    // MARK: Choices

    /// Starts `plan` for the offered call (or, without one, a plain
    /// recording). `remember` makes it the `.auto` rule for this kind.
    func choose(_ plan: MeetingStartPlan, remember: Bool) {
        guard plan.needsRecording else {
            notNow()
            return
        }
        let call = offeredCall
        countdownTask?.cancel()
        countdownTask = nil
        if remember, let call { prefs.setRule(.auto(plan), for: MeetingKindKey(call: call)) }
        launch(call: call, plan: plan) { [startRecording] in startRecording(call, plan) }
    }

    /// Not for this call (offered again next time).
    func notNow() {
        if let call = offeredCall { declined.insert(call.key) }
        countdownTask?.cancel()
        countdownTask = nil
        clearOffer()
        if case .live = stage {} else { stage = .idle }
    }

    /// Never offer for this service again (`.never` for `kind.serviceOnly`).
    func never() {
        if let call = offeredCall {
            prefs.setRule(.never, for: MeetingKindKey(call: call).serviceOnly)
        }
        notNow()
    }

    /// Stops an `.auto` countdown; the regular choices come back so the
    /// user can still pick something (or ✕).
    func cancelCountdown() {
        guard case .countingDown(let call, _, _) = stage else { return }
        countdownTask?.cancel()
        countdownTask = nil
        stage = .prompting(call)
        postPrompt(call, isNew: true)
    }

    /// Menu / Today tab: start without a detected call (or for the call
    /// that is on, when there is one, so it is tied to it).
    func startManually(title: String?, calendarEventID: String?, plan: MeetingStartPlan) {
        guard plan.needsRecording else { return }
        countdownTask?.cancel()
        countdownTask = nil
        let call = offeredCall ?? assistant.callDetector.activeCall
        let event = calendarEventID.flatMap { id in calendar().first { $0.eventID == id } }
        let resolvedTitle = title ?? event?.title
        if briefKey != Self.briefKey(title: resolvedTitle ?? "", eventID: calendarEventID) {
            loadBrief(title: resolvedTitle ?? "", eventID: calendarEventID)
        }
        launch(call: call, plan: plan) { [assistant] in
            assistant.start(title: resolvedTitle, calendarEventID: calendarEventID ?? call?.calendarEventID)
            if plan.keepNotes, assistant.phase == .recording { assistant.openNotesWindow() }
        }
    }

    /// Captions or translation turned on/off mid-call. Keeps the recording.
    func changePlan(_ plan: MeetingStartPlan) {
        guard var session, session.plan != plan else { return }
        if plan.translate { applyTranslation(plan) }
        if session.plan.translate, !plan.translate { restoreTranslation() }
        if session.plan.keepNotes != plan.keepNotes { setWritesNotes(session.id, plan.keepNotes) }
        session.plan = plan
        stage = .live(session)
        onPlanChanged?(session)
    }

    private func launch(call: DetectedCall?, plan: MeetingStartPlan, start: () -> Void) {
        guard Self.isIdle(assistant.phase) else { return }
        if let call { declined.insert(call.key) }
        activities.dismiss(id: MeetingIntelActivity.startPrompt)
        applyTranslation(plan)
        pending = (call, plan)
        // With the default seam, notes for a call use the detector's
        // auto-stop; captions/translation recordings are stopped here.
        stopsWithCallKey = plan.keepNotes ? nil : call?.key
        stage = .idle
        start()
        if assistant.phase == .recording {
            syncPhase()
        } else {
            // The seam may start a moment later; give up after 10 s.
            pendingExpiry?.cancel()
            pendingExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, self.session == nil, self.pending != nil else { return }
                self.pending = nil
                self.stopsWithCallKey = nil
                self.restoreTranslation()
            }
        }
    }

    // MARK: Countdown

    private func beginCountdown(_ call: DetectedCall, _ plan: MeetingStartPlan) {
        let total = max(1, Int(prefs.autoCountdown.rounded()))
        stage = .countingDown(call, plan, secondsLeft: total)
        postCountdown(call, plan, secondsLeft: total)
        countdownTask?.cancel()
        let step = countdownStep
        countdownTask = Task { @MainActor [weak self] in
            var left = total
            while left > 0 {
                try? await Task.sleep(for: .seconds(step))
                guard let self, !Task.isCancelled,
                      case .countingDown(let current, let currentPlan, _) = self.stage, current.key == call.key else { return }
                left -= 1
                if left > 0 {
                    self.stage = .countingDown(current, currentPlan, secondsLeft: left)
                    self.postCountdown(current, currentPlan, secondsLeft: left)
                } else {
                    self.countdownTask = nil
                    self.choose(currentPlan, remember: false)
                }
            }
        }
    }

    // MARK: Phase -> session

    /// Builds the session when recording runs and ends it when recording
    /// stops, whatever started or stopped it. Internal for tests.
    func syncPhase() {
        switch assistant.phase {
        case .recording:
            beginSessionIfNeeded()
        case .summarizing:
            endSessionIfNeeded()
        case .idle, .failed:
            endSessionIfNeeded()
            if translationBefore != nil, pending == nil { restoreTranslation() }
        }
    }

    private func beginSessionIfNeeded() {
        guard session == nil, assistant.phase == .recording, let record = assistant.current else { return }
        let call = pending?.call ?? assistant.callDetector.activeCall
        let plan = pending?.plan ?? .notes
        pending = nil
        pendingExpiry?.cancel()
        if let call { declined.insert(call.key) }
        countdownTask?.cancel()
        countdownTask = nil
        clearOffer()

        let eventID = record.calendarEventID ?? call?.calendarEventID
        // The brief loaded for the offer stays; a start without one gets one.
        if briefKey == nil { loadBrief(title: record.title, eventID: eventID) }
        let session = MeetingIntelSession(
            id: record.id,
            callKey: call?.key,
            kind: call.map { MeetingKindKey(call: $0) },
            serviceName: call?.serviceName ?? "Meeting",
            title: record.title,
            calendarEventID: eventID,
            plan: plan,
            brief: brief,
            startedAt: record.startedAt
        )
        stage = .live(session)
        if !plan.keepNotes { setWritesNotes(session.id, false) }
        postConsentToast(plan)
        AppLog.log("MeetingIntel: session started (\(Self.planName(plan)))")
        onSessionStarted?(session)
    }

    private func endSessionIfNeeded() {
        guard let session else { return }
        stage = .idle
        stopsWithCallKey = nil
        briefTask?.cancel()
        briefTask = nil
        brief = nil
        briefKey = nil
        activities.dismiss(id: Self.consentActivityID)
        AppLog.log("MeetingIntel: session ended")
        onSessionEnded?(session)
    }

    // MARK: Translation

    private func applyTranslation(_ plan: MeetingStartPlan) {
        guard plan.translate, let translation else { return }
        if translationBefore == nil { translationBefore = (translation.isEnabled, translation.targetLanguage) }
        if let target = plan.targetLanguage, !target.isEmpty { translation.targetLanguage = target }
        translation.isEnabled = true
    }

    /// Puts translation back the way it was before this session turned it
    /// on (only if it is still on: the user may have changed it).
    private func restoreTranslation() {
        guard let before = translationBefore, let translation else {
            translationBefore = nil
            return
        }
        translationBefore = nil
        guard translation.isEnabled else { return }
        if !before.enabled { translation.isEnabled = false }
        if translation.targetLanguage != before.target { translation.targetLanguage = before.target }
    }

    // MARK: Brief

    private static func briefKey(title: String, eventID: String?) -> String {
        "\(title)|\(eventID ?? "")"
    }

    private func loadBrief(title: String, eventID: String?) {
        guard prefs.showBrief else {
            brief = nil
            briefKey = nil
            return
        }
        let key = Self.briefKey(title: title, eventID: eventID)
        briefKey = key
        briefTask?.cancel()
        let event = eventID.flatMap { id in calendar().first { $0.eventID == id } }
        let granted = permissions.status(.calendars) == .granted
        let library = assistant.library
        let spaces = spaces
        let now = clock()
        briefTask = Task { @MainActor [weak self] in
            let built = await MeetingBriefBuilder.build(
                title: title, calendarEventID: eventID, event: event, library: library,
                spaces: spaces, calendarGranted: granted, now: now
            )
            guard let self, !Task.isCancelled, self.briefKey == key else { return }
            self.setBrief(built)
        }
    }

    /// Applies a finished brief (also a test seam).
    func setBrief(_ built: MeetingBrief) {
        brief = built
        switch stage {
        case .prompting(let call):
            postPrompt(call, isNew: false)
        case .live(var session):
            session.brief = built
            stage = .live(session)
        case .idle, .countingDown:
            break
        }
    }

    // MARK: Activities

    static let consentActivityID = "meetingIntel.consent"
    /// Below the REC wings (65); transient.
    static let consentPriority = 63
    /// How long a new prompt stays open before it rests in the wings.
    static let promptPeek: TimeInterval = 10

    private func postPrompt(_ call: DetectedCall, isNew: Bool) {
        let icon = MeetingCallIcon.icon(for: call)
        let provider = call.provider
        let height = MeetingStartPromptBand.height(for: brief)
        activities.post(LiveActivity(
            id: MeetingIntelActivity.startPrompt,
            kind: .meeting,
            priority: MeetingIntelActivity.startPriority,
            duration: nil,
            height: height,
            opensTab: .today,
            symbol: "waveform",
            tint: SparkVTheme.recording,
            compactText: "Notes?",
            peekKey: call.key
        ) { [self] in
            MeetingStartPromptBand(coordinator: self, call: call, icon: icon)
        }
        .compact {
            MeetingProviderBadge(provider: provider, appIcon: icon, calendarColor: SparkVTheme.recording, size: 16)
        } trailing: {
            MeetingStartCompactTrailing()
        }
        .minimal {
            MeetingProviderBadge(provider: provider, appIcon: icon, calendarColor: SparkVTheme.recording, size: 14)
        })
        // A new call announces itself for a while, then rests in the
        // wings until it ends or is answered (the Today tab has it too).
        if isNew { activities.peek(id: MeetingIntelActivity.startPrompt, for: Self.promptPeek) }
    }

    private func postCountdown(_ call: DetectedCall, _ plan: MeetingStartPlan, secondsLeft: Int) {
        let total = max(1, Int(prefs.autoCountdown.rounded()))
        let icon = MeetingCallIcon.icon(for: call)
        activities.post(LiveActivity(
            id: MeetingIntelActivity.startPrompt,
            kind: .meeting,
            priority: MeetingIntelActivity.startPriority,
            duration: nil,
            height: MeetingCountdownBand.height,
            opensTab: .today,
            presentation: .expanded,
            symbol: "record.circle",
            tint: SparkVTheme.recording,
            compactText: "\(secondsLeft)"
        ) { [weak self] in
            MeetingCountdownBand(call: call, icon: icon, plan: plan, secondsLeft: secondsLeft, total: total,
                                 onCancel: { self?.cancelCountdown() })
        })
    }

    private func postConsentToast(_ plan: MeetingStartPlan) {
        activities.post(LiveActivity(
            id: Self.consentActivityID,
            kind: .meeting,
            priority: Self.consentPriority,
            duration: 3,
            symbol: "record.circle",
            tint: SparkVTheme.recording
        ) {
            MeetingConsentToast(plan: plan)
        })
    }

    private func clearOffer() {
        activities.dismiss(id: MeetingIntelActivity.startPrompt)
    }

    // MARK: Helpers

    static func isIdle(_ phase: MeetingAssistant.Phase) -> Bool {
        switch phase {
        case .idle, .failed: true
        case .recording, .summarizing: false
        }
    }

    static func planName(_ plan: MeetingStartPlan) -> String {
        if plan.translate { return "translated captions" }
        if plan.captions && plan.keepNotes { return "notes + captions" }
        if plan.captions { return "captions" }
        return "notes"
    }
}

// MARK: - Root

/// Owns part A and talks to B and C through their protocols.
@MainActor
final class MeetingIntelCenter: ObservableObject {
    static weak var current: MeetingIntelCenter?

    /// Part A. (The contract called this `start`; Swift does not allow a
    /// `start` property next to `func start()`.)
    let coordinator: MeetingStartCoordinator
    private let live: any MeetingLiveAssisting
    private let wrapUp: any MeetingWrappingUp
    private let store: MeetingIntelSidecarStore
    private var isStarted = false
    private var endTasks: [UUID: Task<Void, Never>] = [:]

    init(start: MeetingStartCoordinator, live: any MeetingLiveAssisting, wrapUp: any MeetingWrappingUp,
         store: MeetingIntelSidecarStore = .shared) {
        coordinator = start
        self.live = live
        self.wrapUp = wrapUp
        self.store = store
    }

    /// Wires A -> B -> C and starts listening. Call once at launch, after
    /// `MeetingAssistant.start()`.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        coordinator.onSessionStarted = { [weak self] session in
            self?.live.begin(session)
        }
        coordinator.onPlanChanged = { [weak self] session in
            self?.live.update(plan: session.plan)
        }
        coordinator.onSessionEnded = { [weak self] session in
            self?.finish(session)
        }
        coordinator.attach()
    }

    /// At quit.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        coordinator.detach()
    }

    /// Forwards to part A (tests, menu).
    func handle(_ event: MeetingCallEvent) {
        coordinator.handle(event)
    }

    /// Bookmark this moment (recording band button, menu, hotkey).
    func bookmarkNow() {
        guard coordinator.session != nil else { return }
        live.bookmarkNow(note: nil)
    }

    private func finish(_ session: MeetingIntelSession) {
        endTasks[session.id]?.cancel()
        let store = store
        endTasks[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let gathered = await self.live.end()
            // Make sure the sidecar knows how the meeting was started (B
            // normally saved its flags already; fill them in if it didn't).
            let kind = session.kind
            let plan = session.plan
            let service = session.serviceName
            let sidecar = await store.update(session.id) { saved in
                if let gathered, gathered.meetingID == saved.meetingID, saved.flags.isEmpty {
                    saved.flags = gathered.flags
                }
                if let gathered, gathered.meetingID == saved.meetingID, saved.talk == nil {
                    saved.talk = gathered.talk
                }
                if saved.kind == nil { saved.kind = kind }
                if saved.plan == nil { saved.plan = plan }
                if saved.serviceName == nil { saved.serviceName = service }
            }
            self.wrapUp.present(meetingID: session.id, session: session, sidecar: sidecar)
            self.endTasks[session.id] = nil
        }
    }
}
