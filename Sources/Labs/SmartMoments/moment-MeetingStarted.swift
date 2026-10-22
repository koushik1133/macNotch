import AppKit
import Combine
import Foundation

// Smart Moments › "Meeting started" (DESIGN.md moment 2): the action and
// put-back handlers for `.meetingStarted(DetectedCall)`, on top of
// `SmartMomentsWiring`'s generic hooks.
//
// `MeetingStartedMoment.install(on:deps:)` wraps the engine's hooks: for a
// `.meetingStarted` trigger the handlers below run, for every other moment the
// hook that was there before runs unchanged (screen sharing, presentation and
// deep work share pauseMusic / DND / previews). Reversals (resumeMusic,
// doNotDisturbOff, showNotificationPreviews) and put-backs (captions, notes)
// are wrapped the same way: they restore what this moment changed and hand
// anything else to the previous handler.
//
// What each chip does (all through the controller that owns it):
// - Record notes: `MeetingAssistant.startDetectedCall()` for the call that is
//   on (titled after it, stops with it), else `start(title: call.title,
//   calendarEventID:)`. Consent: only ever from a tap (the engine checks too).
// - Live captions: MeetingIntel's caption band (`changePlan` / start with the
//   captions plan) when MeetingIntel is on, else Live Translation's caption
//   window showing the original words. Consent.
// - Translate captions: MeetingIntel's translated plan, else
//   `LiveTranslationController.isEnabled` + caption window (target language
//   from its own settings). Consent.
// - Pause music: `MediaEngine.send(.togglePlayPause)` only while it plays and
//   SparkV can control the player (never triggers an Automation prompt).
//   Put back only when the same track is still paused.
// - Do Not Disturb: the Focus feature's shortcut pair
//   (`FocusController.doNotDisturb.turnOn`), resolved like ModeEngine does
//   (`ModeDoNotDisturbNames.resolve`). Left alone while a Focus session or an
//   active Mode holds DND. Off runs the matching off shortcut.
// - Hide notification previews: `NotificationMonitor.isEnabled = false`.
// - Turn mirror off: `CameraController.stop()` (not turned back on later: the
//   camera light coming back after a call would be a surprise).
// - Suggested answers: while a recording runs during a detected call and this
//   moment is on, `MeetingAssistant.suggestAnswers` is on; it goes back to off
//   when that recording ends (unless the user changed it meanwhile).
//
// MeetingIntel hand-off (DESIGN.md rule 11): with a `MeetingStartedIntelLink`
// the moment installs a `MeetingIntelBridge`. When MeetingIntel shows its own
// start prompt for the call, Smart Moments shows no band: the quiet chips
// (pause music, DND, previews, mirror) are folded into that prompt and run
// when the user starts a session from it (in "Do automatically" the engine
// already ran them). "Not now" in MeetingIntel runs nothing.
//
// Never hides, quits or closes an app. Never asks for a permission itself:
// the engine checks `requiredPermissions` through PermissionCenter.

// MARK: - Ports (real controllers conform below; tests use fakes)

/// MeetingAssistant.
@MainActor
protocol MeetingStartedNotesPort: AnyObject {
    var isRecording: Bool { get }
    var meetingStartedRecordID: UUID? { get }
    var meetingStartedActiveCallKey: String? { get }
    var suggestAnswers: Bool { get set }
    func startDetectedCall()
    func start(title: String?, calendarEventID: String?)
    func stop()
    func meetingStartedOpenNotes()
    /// Emits true when recording starts, false when it stops.
    var meetingStartedRecordingChanges: AnyPublisher<Bool, Never> { get }
    var meetingStartedSuggestChanges: AnyPublisher<Bool, Never> { get }
}

/// LiveTranslationController.
@MainActor
protocol MeetingStartedCaptionsPort: AnyObject {
    var isEnabled: Bool { get set }
    var showsCaptionWindow: Bool { get set }
    var showsOriginal: Bool { get set }
}

/// MediaEngine.
@MainActor
protocol MeetingStartedMusicPort: AnyObject {
    var isPlaying: Bool { get }
    /// A player SparkV may send commands to (no Automation prompt).
    var meetingStartedCanControl: Bool { get }
    var trackKey: String? { get }
    func meetingStartedTogglePlayPause()
    var meetingStartedPlayingChanges: AnyPublisher<Bool, Never> { get }
}

enum MeetingStartedDNDOutcome: Equatable, Sendable {
    /// On; `off` is the shortcut that turns it off again.
    case done(off: String)
    case notSetUp
    case failed(String)
}

/// FocusController (its Do Not Disturb shortcuts) and ModeEngine.
@MainActor
protocol MeetingStartedFocusPort: AnyObject {
    var isSessionActive: Bool { get }
    /// Who already keeps Do Not Disturb on ("Focus", a mode name), if anyone.
    var dndHeldBy: String? { get }
    /// The on/off shortcuts exist (or weren't checked yet).
    var isDNDConfigured: Bool { get }
    func turnDNDOn() async -> MeetingStartedDNDOutcome
    func turnDNDOff(_ offShortcut: String) async -> MeetingStartedDNDOutcome
}

/// NotificationMonitor.
@MainActor
protocol MeetingStartedPreviewsPort: AnyObject {
    var isEnabled: Bool { get set }
    var meetingStartedEnabledChanges: AnyPublisher<Bool, Never> { get }
}

/// CameraController.
@MainActor
protocol MeetingStartedMirrorPort: AnyObject {
    var meetingStartedIsOn: Bool { get }
    func stop()
}

/// MeetingIntel's plan, without depending on that lab.
struct MeetingStartedPlan: Equatable, Sendable {
    var notes: Bool
    var captions: Bool
    var translate: Bool

    static let notesOnly = MeetingStartedPlan(notes: true, captions: false, translate: false)
    static let captionsOnly = MeetingStartedPlan(notes: false, captions: true, translate: false)
    static let translated = MeetingStartedPlan(notes: false, captions: true, translate: true)
}

enum MeetingStartedIntelStage: Equatable, Sendable {
    case idle
    /// The start prompt (or its auto countdown) is up for this call.
    case offering(callKey: String)
    case live(callKey: String?, plan: MeetingStartedPlan)
}

/// MeetingStartCoordinator as closures (INTEGRATION.md "Moment: MeetingStarted"),
/// so this file compiles without Sources/Labs/MeetingIntel.
@MainActor
final class MeetingStartedIntelLink {
    /// MeetingIntel will show its start prompt for this call.
    let willPrompt: @MainActor (DetectedCall) -> Bool
    /// MeetingIntel is turned on (its captions and plans can be used).
    let isOn: @MainActor () -> Bool
    /// Starts a session with this plan for the call (choose on the offered
    /// call, else start manually).
    let start: @MainActor (MeetingStartedPlan, DetectedCall) -> Void
    /// Changes the live session's plan (captions / translation on or off).
    let changePlan: @MainActor (MeetingStartedPlan) -> Void

    private(set) var stage: MeetingStartedIntelStage = .idle
    var onStage: ((MeetingStartedIntelStage) -> Void)?
    private var subscription: AnyCancellable?

    init(willPrompt: @escaping @MainActor (DetectedCall) -> Bool,
         isOn: @escaping @MainActor () -> Bool,
         stages: AnyPublisher<MeetingStartedIntelStage, Never>,
         start: @escaping @MainActor (MeetingStartedPlan, DetectedCall) -> Void,
         changePlan: @escaping @MainActor (MeetingStartedPlan) -> Void) {
        self.willPrompt = willPrompt
        self.isOn = isOn
        self.start = start
        self.changePlan = changePlan
        subscription = stages.removeDuplicates().sink { [weak self] stage in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stage = stage
                self.onStage?(stage)
            }
        }
    }

    var livePlan: MeetingStartedPlan? {
        if case .live(_, let plan) = stage { return plan }
        return nil
    }
}

struct MeetingStartedDeps {
    let notes: any MeetingStartedNotesPort
    let captions: (any MeetingStartedCaptionsPort)?
    let music: (any MeetingStartedMusicPort)?
    let focus: (any MeetingStartedFocusPort)?
    let previews: (any MeetingStartedPreviewsPort)?
    let mirror: (any MeetingStartedMirrorPort)?
    /// nil = MeetingIntel isn't built: Smart Moments' own band offers notes
    /// and captions (SmartMomentsWiring hides the assistant's "Notes?").
    let intel: MeetingStartedIntelLink?

    init(notes: any MeetingStartedNotesPort, captions: (any MeetingStartedCaptionsPort)?,
         music: (any MeetingStartedMusicPort)?, focus: (any MeetingStartedFocusPort)?,
         previews: (any MeetingStartedPreviewsPort)?, mirror: (any MeetingStartedMirrorPort)?,
         intel: MeetingStartedIntelLink?) {
        self.notes = notes
        self.captions = captions
        self.music = music
        self.focus = focus
        self.previews = previews
        self.mirror = mirror
        self.intel = intel
    }
}

// MARK: - The moment

@MainActor
final class MeetingStartedMoment {
    static weak var current: MeetingStartedMoment?

    private weak var engine: SmartMomentsController?
    private let deps: MeetingStartedDeps
    /// MeetingIntel's start coordinator, once connected.
    private(set) var intel: MeetingStartedIntelLink?
    private var bag: Set<AnyCancellable> = []

    // What this moment changed, so the put-back restores exactly that ------
    /// The track it paused ("" = the player reported none).
    private(set) var pausedTrack: String?
    /// The off shortcut of the Do Not Disturb it turned on.
    private(set) var dndOffShortcut: String?
    private(set) var hidPreviews = false
    private enum CaptionsBefore {
        case translation(enabled: Bool, window: Bool, original: Bool)
        case intel(MeetingStartedPlan)
    }
    private var captionsBefore: CaptionsBefore?
    /// A recording it started without the detector's auto-stop.
    private(set) var ownedRecordingID: UUID?
    /// `suggestAnswers` was off before this moment turned it on.
    private(set) var turnedOnSuggestedAnswers = false
    private var settingSuggest = false

    // MeetingIntel hand-off ------------------------------------------------
    private struct Folded {
        let callKey: String
        let actions: [MomentAction]
        let run: @MainActor (MomentAction) -> Void
        var sawOffer: Bool
    }
    private var folded: Folded?

    static let handledByIntel: Set<MomentAction> = [.recordNotes, .liveCaptions, .translateCaptions]

    init(engine: SmartMomentsController, deps: MeetingStartedDeps) {
        self.engine = engine
        self.deps = deps
    }

    /// Wires the moment into the engine. Call after `SmartMomentsWiring.start()`
    /// (its generic hooks are wrapped, not replaced) and after
    /// `connectMeetingIntel` if that is used (this bridge supersedes it).
    @discardableResult
    static func install(on engine: SmartMomentsController, deps: MeetingStartedDeps) -> MeetingStartedMoment {
        let moment = MeetingStartedMoment(engine: engine, deps: deps)
        moment.installHooks()
        moment.observe()
        if let link = deps.intel { moment.connect(link) }
        current = moment
        return moment
    }

    /// Hands the call-start prompt to MeetingIntel (INTEGRATION.md "Moment:
    /// MeetingStarted"). Replaces `SmartMomentsWiring.connectMeetingIntel`'s
    /// bridge, which it wraps for the other meeting moments.
    func connect(_ link: MeetingStartedIntelLink) {
        guard let engine, intel !== link else { return }
        intel = link
        link.onStage = { [weak self] stage in self?.intelStageChanged(stage) }
        engine.meetingIntel = MeetingStartedIntelBridge(moment: self, link: link, previous: engine.meetingIntel)
    }

    // MARK: Hooks

    private static func isMine(_ trigger: MomentTrigger) -> Bool {
        if case .meetingStarted = trigger { return true }
        return false
    }

    private func installHooks() {
        guard let engine else { return }
        var h = engine.hooks
        let hadHook = Set(h.actions.keys)

        func wrap(_ action: MomentAction, _ mine: @escaping SmartMomentsHooks.Run) {
            let previous = h.actions[action]
            h.actions[action] = { context in
                if Self.isMine(context.trigger) { return await mine(context) }
                return await previous?(context) ?? .skipped("Not available")
            }
        }
        func available(_ action: MomentAction, _ mine: @escaping @MainActor (MomentTrigger) -> Bool) {
            let hadPrevious = hadHook.contains(action)
            let previous = h.isAvailable[action]
            h.isAvailable[action] = { trigger in
                if Self.isMine(trigger) { return mine(trigger) }
                guard hadPrevious else { return false }
                return previous?(trigger) ?? true
            }
        }
        /// A reversal: ours if this moment changed that state, else the previous one.
        func reversal(_ action: MomentAction, owns: @escaping @MainActor () -> Bool, _ mine: @escaping SmartMomentsHooks.Run) {
            let previous = h.actions[action]
            h.actions[action] = { context in
                if owns() { return await mine(context) }
                return await previous?(context) ?? .skipped("Not available")
            }
        }

        wrap(.recordNotes) { context in await self.recordNotes(context) }
        available(.recordNotes) { _ in !self.deps.notes.isRecording }
        wrap(.liveCaptions) { context in await self.captions(translated: false, context) }
        available(.liveCaptions) { _ in self.canStartCaptions(translated: false) }
        wrap(.translateCaptions) { context in await self.captions(translated: true, context) }
        available(.translateCaptions) { _ in self.canStartCaptions(translated: true) }

        if deps.music != nil {
            wrap(.pauseMusic) { _ in self.pauseMusic() }
            available(.pauseMusic) { _ in
                guard let music = self.deps.music else { return false }
                return music.isPlaying && music.meetingStartedCanControl
            }
            reversal(.resumeMusic, owns: { self.pausedTrack != nil }) { _ in self.resumeMusic() }
        }
        if deps.focus != nil {
            wrap(.doNotDisturbOn) { _ in await self.dndOn() }
            available(.doNotDisturbOn) { _ in self.deps.focus?.isDNDConfigured ?? false }
            reversal(.doNotDisturbOff, owns: { self.dndOffShortcut != nil }) { _ in await self.dndOff() }
        }
        if deps.previews != nil {
            wrap(.hideNotificationPreviews) { _ in self.hidePreviews() }
            available(.hideNotificationPreviews) { _ in self.deps.previews?.isEnabled ?? false }
            reversal(.showNotificationPreviews, owns: { self.hidPreviews }) { _ in self.showPreviews() }
        }
        if deps.mirror != nil {
            wrap(.mirrorOff) { _ in
                guard let mirror = self.deps.mirror, mirror.meetingStartedIsOn else { return .skipped("Mirror is off") }
                mirror.stop()
                return .done("Mirror off")
            }
            available(.mirrorOff) { _ in self.deps.mirror?.meetingStartedIsOn ?? false }
        }
        engine.hooks = h

        // Put-backs (meeting ended, Undo, quit). Keyed by action, so the
        // previous handler (SmartMomentsWiring's) keeps working for the rest.
        for action in [MomentAction.liveCaptions, .translateCaptions] {
            let previous = engine.putBack[action]
            engine.putBack[action] = { context in
                guard self.captionsBefore != nil else { return await previous?(context) ?? .skipped("Unchanged") }
                let result = self.restoreCaptions()
                // A recording started only for these captions ends with them.
                if self.ownedRecordingID != nil { _ = self.stopOwnedRecording() }
                return result
            }
        }
        let previousNotes = engine.putBack[.recordNotes]
        engine.putBack[.recordNotes] = { context in
            if self.ownedRecordingID != nil { return self.stopOwnedRecording() }
            return await previousNotes?(context) ?? .skipped("Stops with the call")
        }
    }

    // MARK: Observers (user changed it by hand; suggested answers)

    private func observe() {
        deps.notes.meetingStartedRecordingChanges
            .removeDuplicates()
            .sink { [weak self] recording in
                MainActor.assumeIsolated { self?.recordingChanged(recording) }
            }
            .store(in: &bag)
        deps.notes.meetingStartedSuggestChanges
            .removeDuplicates()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self, !self.settingSuggest, !on else { return }
                    // Turned off by hand: theirs; nothing to put back.
                    self.turnedOnSuggestedAnswers = false
                }
            }
            .store(in: &bag)
        deps.music?.meetingStartedPlayingChanges
            .removeDuplicates()
            .sink { [weak self] playing in
                MainActor.assumeIsolated {
                    guard let self, playing, self.pausedTrack != nil else { return }
                    self.pausedTrack = nil
                    self.forgetIfOwned(.resumeMusic)
                }
            }
            .store(in: &bag)
        deps.previews?.meetingStartedEnabledChanges
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard let self, enabled, self.hidPreviews else { return }
                    self.hidPreviews = false
                    self.forgetIfOwned(.showNotificationPreviews)
                }
            }
            .store(in: &bag)
    }

    private func forgetIfOwned(_ reversal: MomentAction) {
        guard let engine, engine.ownedReversals(for: .meetingStarted).contains(reversal) else { return }
        engine.userChanged(reversal)
    }

    /// Suggested answers are on while a recording runs during a detected
    /// call with this moment on; off again when it ends, if we turned it on.
    private func recordingChanged(_ recording: Bool) {
        if recording {
            guard let engine, engine.wants(.meetingStarted), deps.notes.meetingStartedActiveCallKey != nil else { return }
            ensureSuggestedAnswers()
        } else {
            if turnedOnSuggestedAnswers {
                turnedOnSuggestedAnswers = false
                if deps.notes.suggestAnswers { setSuggest(false) }
            }
            ownedRecordingID = nil
        }
    }

    private func ensureSuggestedAnswers() {
        guard !deps.notes.suggestAnswers else { return }
        setSuggest(true)
        turnedOnSuggestedAnswers = true
    }

    private func setSuggest(_ on: Bool) {
        settingSuggest = true
        deps.notes.suggestAnswers = on
        settingSuggest = false
    }

    // MARK: Record notes and captions (consent: a tap only)

    func recordNotes(_ context: MomentActionContext) async -> MomentActionResult {
        guard context.userInitiated else { return .skipped("Needs a tap") }
        guard case .meetingStarted(let call) = context.trigger else { return .skipped("No call") }
        guard !deps.notes.isRecording else { return .skipped("Already recording") }
        return startRecording(for: call, openNotes: true) ? .done("Recording notes") : .failed("Recording didn't start")
    }

    /// Starts the meeting recording for `call`, with suggested answers on.
    private func startRecording(for call: DetectedCall, openNotes: Bool) -> Bool {
        let notes = deps.notes
        ensureSuggestedAnswers() // before start: the answer model prewarms then
        if openNotes, notes.meetingStartedActiveCallKey == call.key {
            // Titled after the call, opens the notepad, stops with the call.
            notes.startDetectedCall()
        } else {
            notes.start(title: call.title, calendarEventID: call.calendarEventID)
            if notes.isRecording {
                ownedRecordingID = notes.meetingStartedRecordID
                if openNotes { notes.meetingStartedOpenNotes() }
            }
        }
        if !notes.isRecording, turnedOnSuggestedAnswers {
            turnedOnSuggestedAnswers = false
            setSuggest(false)
        }
        return notes.isRecording
    }

    private func stopOwnedRecording() -> MomentActionResult {
        let id = ownedRecordingID
        ownedRecordingID = nil
        guard let id, deps.notes.isRecording, deps.notes.meetingStartedRecordID == id else { return .skipped("Already stopped") }
        deps.notes.stop()
        return .done("Recording saved")
    }

    private func intelIsOn() -> Bool { intel?.isOn() ?? false }

    private func canStartCaptions(translated: Bool) -> Bool {
        if intelIsOn(), let link = intel {
            guard let plan = link.livePlan else { return true }
            return translated ? !plan.translate : !plan.captions
        }
        guard let captions = deps.captions else { return false }
        return !captions.isEnabled
    }

    func captions(translated: Bool, _ context: MomentActionContext) async -> MomentActionResult {
        guard context.userInitiated else { return .skipped("Needs a tap") }
        guard case .meetingStarted(let call) = context.trigger else { return .skipped("No call") }
        let done: MomentActionResult = .done(translated ? "Translating captions" : "Captions on")

        // MeetingIntel: its caption band (original words) or its translated
        // plan; it puts translation back when the session ends.
        if intelIsOn(), let link = intel {
            if let plan = link.livePlan {
                var next = plan
                next.captions = true
                if translated { next.translate = true }
                guard next != plan else { return .skipped("Captions are on") }
                ensureSuggestedAnswers()
                if captionsBefore == nil { captionsBefore = .intel(plan) }
                link.changePlan(next)
                return done
            }
            guard !deps.notes.isRecording else {
                // A recording MeetingIntel doesn't track: use Live Translation.
                return liveTranslationCaptions(translated: translated, call: call, done: done)
            }
            // Suggested answers follow from `recordingChanged` once it records.
            link.start(translated ? .translated : .captionsOnly, call)
            return deps.notes.isRecording ? done : .skipped("Starting in MeetingIntel")
        }
        return liveTranslationCaptions(translated: translated, call: call, done: done)
    }

    private func liveTranslationCaptions(translated: Bool, call: DetectedCall, done: MomentActionResult) -> MomentActionResult {
        guard let captions = deps.captions else { return .failed("Captions unavailable") }
        guard !captions.isEnabled else { return .skipped("Captions are on") }
        // Captions follow the meeting transcript: the tap is the consent, and
        // MeetingAssistant's recording band and dot stay up.
        if !deps.notes.isRecording {
            guard startRecording(for: call, openNotes: false) else { return .failed("Recording didn't start") }
        }
        if captionsBefore == nil {
            captionsBefore = .translation(enabled: captions.isEnabled, window: captions.showsCaptionWindow, original: captions.showsOriginal)
        }
        if !translated { captions.showsOriginal = true }
        captions.showsCaptionWindow = true
        captions.isEnabled = true
        return done
    }

    private func restoreCaptions() -> MomentActionResult {
        guard let before = captionsBefore else { return .skipped("Unchanged") }
        captionsBefore = nil
        switch before {
        case .translation(let enabled, let window, let original):
            guard let captions = deps.captions else { return .skipped("Gone") }
            captions.isEnabled = enabled
            captions.showsCaptionWindow = window
            captions.showsOriginal = original
            return .done("Captions off")
        case .intel(let plan):
            // The session ended: MeetingIntel already stopped its captions.
            guard let link = intel, let live = link.livePlan else { return .skipped("Session ended") }
            var back = live
            back.captions = plan.captions
            back.translate = plan.translate
            guard back != live else { return .skipped("Unchanged") }
            link.changePlan(back)
            return .done("Captions off")
        }
    }

    // MARK: Music

    private func pauseMusic() -> MomentActionResult {
        guard let music = deps.music, music.isPlaying else { return .skipped("Nothing playing") }
        guard music.meetingStartedCanControl else { return .skipped("Can't control this player") }
        let track = music.trackKey ?? ""
        music.meetingStartedTogglePlayPause()
        pausedTrack = track
        return .done("Paused music")
    }

    private func resumeMusic() -> MomentActionResult {
        let track = pausedTrack
        pausedTrack = nil
        guard let music = deps.music, let track else { return .skipped("Unchanged") }
        guard !music.isPlaying else { return .skipped("Already playing") }
        guard music.meetingStartedCanControl, track.isEmpty || music.trackKey == track else {
            return .skipped("Something else is up next")
        }
        music.meetingStartedTogglePlayPause()
        return .done("Resumed music")
    }

    // MARK: Do Not Disturb

    private func dndOn() async -> MomentActionResult {
        guard let focus = deps.focus else { return .skipped("Unavailable") }
        if let holder = focus.dndHeldBy { return .skipped("\(holder) keeps Do Not Disturb on") }
        switch await focus.turnDNDOn() {
        case .done(let off):
            dndOffShortcut = off
            return .done("Do Not Disturb on")
        case .notSetUp:
            return .failed("Set up Do Not Disturb in Focus settings")
        case .failed(let message):
            return .failed(message)
        }
    }

    private func dndOff() async -> MomentActionResult {
        let off = dndOffShortcut
        dndOffShortcut = nil
        guard let focus = deps.focus, let off else { return .skipped("Unchanged") }
        // A Focus session or a Mode that started meanwhile keeps it on.
        if let holder = focus.dndHeldBy { return .skipped("\(holder) keeps it on") }
        switch await focus.turnDNDOff(off) {
        case .done: return .done("Do Not Disturb off")
        case .notSetUp: return .failed("Set up Do Not Disturb in Focus settings")
        case .failed(let message): return .failed(message)
        }
    }

    // MARK: Notification previews

    private func hidePreviews() -> MomentActionResult {
        guard let previews = deps.previews, previews.isEnabled else { return .skipped("Already hidden") }
        previews.isEnabled = false
        hidPreviews = true
        return .done("Previews hidden")
    }

    private func showPreviews() -> MomentActionResult {
        guard hidPreviews, let previews = deps.previews else { return .skipped("Unchanged") }
        hidPreviews = false
        guard !previews.isEnabled else { return .skipped("Already shown") }
        // A Focus session started meanwhile restores them itself when it ends.
        if deps.focus?.isSessionActive == true { return .skipped("Focus keeps them hidden") }
        previews.isEnabled = true
        return .done("Previews back")
    }

    // MARK: MeetingIntel hand-off

    func fold(_ actions: [MomentAction], callKey: String, run: @escaping @MainActor (MomentAction) -> Void) {
        folded = Folded(callKey: callKey, actions: actions, run: run, sawOffer: false)
        if let stage = intel?.stage { intelStageChanged(stage) }
    }

    private func intelStageChanged(_ stage: MeetingStartedIntelStage) {
        switch stage {
        case .live(let key, _):
            if deps.notes.meetingStartedActiveCallKey != nil, engine?.wants(.meetingStarted) == true {
                ensureSuggestedAnswers()
            }
            // The user started a session from MeetingIntel's prompt: that tap
            // answers the bundle, so the folded quiet chips run now.
            guard let pending = folded, key == nil || key == pending.callKey else { return }
            folded = nil
            for action in pending.actions { pending.run(action) }
        case .offering(let key):
            if folded?.callKey == key { folded?.sawOffer = true }
        case .idle:
            // Not now / Never / the call ended in MeetingIntel: nothing runs.
            if folded?.sawOffer == true { folded = nil }
        }
    }

    /// For tests and Settings: chips waiting for MeetingIntel's prompt.
    var foldedActions: [MomentAction] { folded?.actions ?? [] }
}

// MARK: - MeetingIntel bridge

/// MeetingIntel owns the call-start prompt; this bridge keeps Smart Moments
/// from showing a second band for the same call.
@MainActor
final class MeetingStartedIntelBridge: MeetingIntelBridge {
    private let moment: MeetingStartedMoment
    private let link: MeetingStartedIntelLink
    private let previous: (any MeetingIntelBridge)?

    init(moment: MeetingStartedMoment, link: MeetingStartedIntelLink, previous: (any MeetingIntelBridge)?) {
        self.moment = moment
        self.link = link
        self.previous = previous
    }

    var handledActions: Set<MomentAction> {
        MeetingStartedMoment.handledByIntel.union(previous?.handledActions ?? [])
    }

    var hostsContributedChips: Bool { true }

    func willPrompt(for trigger: MomentTrigger) -> Bool {
        if case .meetingStarted(let call) = trigger { return link.willPrompt(call) }
        return previous?.willPrompt(for: trigger) ?? false
    }

    func perform(_ action: MomentAction, context: MomentActionContext) async -> MomentActionResult {
        guard case .meetingStarted = context.trigger else {
            return await previous?.perform(action, context: context) ?? .skipped("Not available")
        }
        switch action {
        case .recordNotes: return await moment.recordNotes(context)
        case .liveCaptions: return await moment.captions(translated: false, context)
        case .translateCaptions: return await moment.captions(translated: true, context)
        default: return await previous?.perform(action, context: context) ?? .skipped("Not available")
        }
    }

    func contribute(_ actions: [MomentAction], for trigger: MomentTrigger, run: @escaping @MainActor (MomentAction) -> Void) {
        guard case .meetingStarted(let call) = trigger else {
            previous?.contribute(actions, for: trigger, run: run)
            return
        }
        moment.fold(actions, callKey: call.key, run: run)
    }
}

// MARK: - Real controllers

#if !SMARTMOMENTS_FAKES
extension MeetingAssistant: MeetingStartedNotesPort {
    var meetingStartedRecordID: UUID? { current?.id }
    var meetingStartedActiveCallKey: String? { callDetector.activeCall?.key }
    func meetingStartedOpenNotes() { openNotesWindow() }
    var meetingStartedRecordingChanges: AnyPublisher<Bool, Never> {
        $phase.map { $0 == .recording }.eraseToAnyPublisher()
    }
    var meetingStartedSuggestChanges: AnyPublisher<Bool, Never> { $suggestAnswers.eraseToAnyPublisher() }
}

extension LiveTranslationController: MeetingStartedCaptionsPort {}

extension MediaEngine: MeetingStartedMusicPort {
    var meetingStartedCanControl: Bool {
        switch source {
        case .app, .player: true
        case .none, .needsPermission, .denied: false
        }
    }
    func meetingStartedTogglePlayPause() { send(.togglePlayPause) }
    var meetingStartedPlayingChanges: AnyPublisher<Bool, Never> { $isPlaying.eraseToAnyPublisher() }
}

extension NotificationMonitor: MeetingStartedPreviewsPort {
    var meetingStartedEnabledChanges: AnyPublisher<Bool, Never> { $isEnabled.eraseToAnyPublisher() }
}

extension CameraController: MeetingStartedMirrorPort {
    var meetingStartedIsOn: Bool { isRunning || isStarting }
}

/// Do Not Disturb through the user's Focus shortcuts (the same pair the
/// Focus feature and ModeEngine use).
@MainActor
final class MeetingStartedFocusAdapter: MeetingStartedFocusPort {
    private let focus: FocusController
    private let modes: ModeEngine

    init(focus: FocusController, modes: ModeEngine) {
        self.focus = focus
        self.modes = modes
    }

    var isSessionActive: Bool { focus.active != nil }

    var dndHeldBy: String? {
        if focus.active?.didEnableDoNotDisturb == true { return "Focus" }
        if let mode = modes.activeMode, mode.actions.contains(where: { action in
            if case .doNotDisturb(true) = action { return true }
            return false
        }) {
            return mode.name
        }
        return nil
    }

    var isDNDConfigured: Bool {
        let dnd = focus.doNotDisturb
        guard case .missing = dnd.setup else { return true }
        return ModeDoNotDisturbNames.resolve(preferred: preferred, library: dnd.library) != nil
    }

    private var preferred: (on: String, off: String) {
        (focus.settings.dndOnShortcut, focus.settings.dndOffShortcut)
    }

    func turnDNDOn() async -> MeetingStartedDNDOutcome {
        let pair = preferred
        await focus.doNotDisturb.refresh(on: pair.on, off: pair.off)
        guard let names = ModeDoNotDisturbNames.resolve(preferred: pair, library: focus.doNotDisturb.library) else {
            return .notSetUp
        }
        switch await focus.doNotDisturb.turnOn(names.on) {
        case .done: return .done(off: names.off)
        case .notSetUp: return .notSetUp
        case .failed(let message): return .failed(message)
        }
    }

    func turnDNDOff(_ offShortcut: String) async -> MeetingStartedDNDOutcome {
        switch await focus.doNotDisturb.turnOff(offShortcut) {
        case .done: return .done(off: offShortcut)
        case .notSetUp: return .notSetUp
        case .failed(let message): return .failed(message)
        }
    }
}

@MainActor
extension MeetingStartedDeps {
    /// The app's controllers (NotchWindowController's properties).
    init(assistant: MeetingAssistant, translation: LiveTranslationController?, media: MediaEngine,
         focus: FocusController?, modes: ModeEngine? = nil, notifications: NotificationMonitor,
         camera: CameraController, intel: MeetingStartedIntelLink? = nil) {
        let modeEngine = modes ?? ModeEngine.shared
        self.init(
            notes: assistant, captions: translation, music: media,
            focus: focus.map { MeetingStartedFocusAdapter(focus: $0, modes: modeEngine) },
            previews: notifications, mirror: camera, intel: intel
        )
    }
}
#endif
