import Foundation

// Smart Moments › Presentation (DESIGN.md moment 10).
//
// Keynote or PowerPoint starts playing, or an app goes fullscreen on an
// external display: the engine offers (or, for a slideshow, runs) these
// actions, and `presentationEnded` puts back exactly what they changed.
//
//   presentationMode  The ModeEngine mode picked in Settings
//                     (`tunables.presentationModeID`), else ModeEngine's
//                     built-in Presentation mode, but only while neither
//                     hides nor quits apps (the shipped preset hides every
//                     other app, so by default this falls back). Fallback:
//                     SparkV's quiet set, i.e. Do Not Disturb (the user's
//                     Focus shortcuts), SparkV notification previews off,
//                     and pause music, each through the engine's current
//                     hook (so other moments' wrappers apply, e.g. a share
//                     keeps previews hidden until it ends), else straight
//                     to FocusController / NotificationMonitor /
//                     MediaEngine. Put back: the mode is deactivated
//                     only if it is still the active one; each quiet-set
//                     step is reversed only if it is still in the state we
//                     left it and no one else (a Focus session, a mode, a
//                     call moment's ledger entry) owns it now.
//   talkTimer         TimerController countdown (`talkMinutes`), only
//                     when the timer is on and idle (never overwrites the
//                     user's timer). Put back: reset if it is still ours.
//   quietNotchActivities  ActivityCenter has no suppress/restore API, so
//                     it gets no hook and its chip stays hidden.
//
// Install after `SmartMomentsWiring.start()`, which sets the engine's other
// hooks (this replaces its presentationMode hook and put-back).
// Nothing here hides, quits or closes an app, records, or asks for a
// permission.

/// Result of a Do Not Disturb shortcut run (mirrors FocusDoNotDisturb.Outcome).
enum PresentationMomentDNDOutcome: Equatable, Sendable {
    case done
    case notSetUp
    case failed(String)
}

/// What the moment needs to know about a ModeEngine mode.
struct PresentationMomentModeInfo: Equatable, Sendable {
    let id: UUID
    let name: String
    let hidesOrQuitsApps: Bool
    let turnsOnDoNotDisturb: Bool
    let mutesPreviews: Bool
}

/// Everything the Presentation moment calls, as closures so tests can fake
/// them. `live(...)` builds it from the app's real controllers.
@MainActor
struct PresentationMomentDeps {
    // ModeEngine
    /// Settings › Smart Moments › Presentation mode pick (nil = built in).
    var chosenModeID: @MainActor () -> UUID?
    /// ModeEngine's own Presentation preset, used when nothing is picked.
    var builtInModeID: UUID?
    var modeInfo: @MainActor (UUID) -> PresentationMomentModeInfo?
    var activeModeID: @MainActor () -> UUID?
    var activateMode: @MainActor (UUID) async -> Void
    var deactivateMode: @MainActor () async -> Void
    var modeError: @MainActor () -> String?

    // Do Not Disturb (FocusController's shortcuts)
    /// False when the shortcuts are known to be missing.
    var dndUsable: @MainActor () -> Bool
    var dndTurnOn: @MainActor () async -> PresentationMomentDNDOutcome
    var dndTurnOff: @MainActor () async -> PresentationMomentDNDOutcome
    /// A Focus session turned DND on and will turn it off itself.
    var focusOwnsDND: @MainActor () -> Bool
    /// A Focus session is running (it restores previews itself).
    var focusSessionActive: @MainActor () -> Bool

    // SparkV notification previews (NotificationMonitor.isEnabled)
    var previewsShown: @MainActor () -> Bool
    var setPreviewsShown: @MainActor (Bool) -> Void

    // Music (MediaEngine)
    var isPlaying: @MainActor () -> Bool
    var hasPlayer: @MainActor () -> Bool
    var togglePlayPause: @MainActor () -> Void

    // Talk timer (TimerController)
    /// Timer on and idle, so starting one overwrites nothing.
    var timerIsFree: @MainActor () -> Bool
    /// Starts a countdown; returns its end (nil = didn't start).
    var startTimer: @MainActor (Int) -> Date?
    /// The end of the running countdown, if a plain timer runs.
    var runningTimerEndsAt: @MainActor () -> Date?
    var resetTimer: @MainActor () -> Void
    var talkMinutes: Int = 20
}

extension PresentationMomentDeps {
    /// The real controllers (all exist in NotchWindowController).
    static func live(
        settings: SmartMomentsSettings,
        media: MediaEngine,
        focus: FocusController,
        notifications: NotificationMonitor,
        timer: TimerController,
        modes: ModeEngine? = nil,
        talkMinutes: Int = 20
    ) -> PresentationMomentDeps {
        let modes = modes ?? ModeEngine.shared
        return PresentationMomentDeps(
            chosenModeID: { [weak settings] in settings?.tunables.presentationModeID },
            builtInModeID: ModePresets.presentationID,
            modeInfo: { [weak modes] id in
                guard let mode = modes?.mode(id) else { return nil }
                return PresentationMoment.info(for: mode)
            },
            activeModeID: { [weak modes] in modes?.activeModeID },
            activateMode: { [weak modes] id in await modes?.activate(id) },
            deactivateMode: { [weak modes] in await modes?.deactivate() },
            modeError: { [weak modes] in modes?.lastError },
            dndUsable: { [weak focus] in
                guard let focus else { return false }
                if case .missing = focus.doNotDisturb.setup { return false }
                return true
            },
            dndTurnOn: { [weak focus] in
                guard let focus else { return .failed("Unavailable") }
                let s = focus.settings
                await focus.doNotDisturb.refresh(on: s.dndOnShortcut, off: s.dndOffShortcut)
                return PresentationMoment.outcome(await focus.doNotDisturb.turnOn(s.dndOnShortcut))
            },
            dndTurnOff: { [weak focus] in
                guard let focus else { return .failed("Unavailable") }
                return PresentationMoment.outcome(await focus.doNotDisturb.turnOff(focus.settings.dndOffShortcut))
            },
            focusOwnsDND: { [weak focus] in focus?.active?.didEnableDoNotDisturb == true },
            focusSessionActive: { [weak focus] in focus?.active != nil },
            previewsShown: { [weak notifications] in notifications?.isEnabled ?? false },
            setPreviewsShown: { [weak notifications] on in notifications?.isEnabled = on },
            isPlaying: { [weak media] in media?.isPlaying ?? false },
            hasPlayer: { [weak media] in
                guard let media else { return false }
                return media.source != .none
            },
            togglePlayPause: { [weak media] in media?.send(.togglePlayPause) },
            timerIsFree: { [weak timer] in
                guard let timer else { return false }
                return timer.isEnabled && timer.state.isIdle
            },
            startTimer: { [weak timer] minutes in
                guard let timer else { return nil }
                timer.startTimer(minutes: minutes)
                return timer.state.mode == .timer ? timer.state.endsAt : nil
            },
            runningTimerEndsAt: { [weak timer] in
                guard let timer, timer.state.mode == .timer else { return nil }
                return timer.state.endsAt
            },
            resetTimer: { [weak timer] in timer?.reset() },
            talkMinutes: talkMinutes
        )
    }
}

/// What this moment changed and has not put back yet.
@MainActor
final class PresentationMomentSession {
    enum Step: String, Sendable { case doNotDisturb, previews, music }

    /// The ModeEngine mode we activated.
    fileprivate(set) var modeID: UUID?
    /// Quiet-set steps we changed, in order.
    fileprivate(set) var steps: [Step] = []
    /// The talk timer we started (its end date identifies it).
    fileprivate(set) var timerEndsAt: Date?

    var isPresentationModeOn: Bool { modeID != nil || !steps.isEmpty }
}

@MainActor
enum PresentationMoment {
    /// Registers the presentationMode and talkTimer hooks and put-backs.
    /// Returns the session state (tests read it).
    @discardableResult
    static func install(on engine: SmartMomentsController, deps: PresentationMomentDeps) -> PresentationMomentSession {
        let session = PresentationMomentSession()

        engine.hooks.actions[.presentationMode] = { [weak engine] context in
            guard let engine else { return .skipped("Gone") }
            return await turnOn(context, engine: engine, deps: deps, session: session)
        }
        engine.hooks.isAvailable[.presentationMode] = nil
        // A display has no end signal: in "Do automatically" it stays a chip.
        engine.hooks.autoEligible[.presentationMode] = { trigger in
            if case .displayConnected = trigger { return false }
            return true
        }
        engine.putBack[.presentationMode] = { [weak engine] context in
            guard let engine else { return .skipped("Gone") }
            return await turnOff(context, engine: engine, deps: deps, session: session)
        }

        engine.hooks.actions[.talkTimer] = { _ in
            guard session.timerEndsAt == nil else { return .skipped("Talk timer is on") }
            guard deps.timerIsFree() else { return .skipped("The timer is busy or off") }
            guard let endsAt = deps.startTimer(deps.talkMinutes) else { return .failed("Timer didn't start") }
            session.timerEndsAt = endsAt
            return .done("Talk timer · \(deps.talkMinutes) min")
        }
        engine.hooks.isAvailable[.talkTimer] = { trigger in
            guard case .presentationStarted = trigger else { return false }
            return session.timerEndsAt == nil && deps.timerIsFree()
        }
        engine.putBack[.talkTimer] = { _ in
            guard let ours = session.timerEndsAt else { return .skipped("Unchanged") }
            session.timerEndsAt = nil
            // Paused, finished or replaced by hand: it is the user's now.
            guard let running = deps.runningTimerEndsAt(), abs(running.timeIntervalSince(ours)) < 1 else {
                return .skipped("Timer changed by hand")
            }
            deps.resetTimer()
            return .done("Talk timer stopped")
        }
        return session
    }

    // MARK: - Presentation mode on

    private static func turnOn(
        _ context: MomentActionContext, engine: SmartMomentsController,
        deps: PresentationMomentDeps, session: PresentationMomentSession
    ) async -> MomentActionResult {
        // A display has no "presentation ended": only a tap turns it on there.
        if case .displayConnected = context.trigger, !context.userInitiated { return .skipped("Needs a tap") }
        guard !session.isPresentationModeOn else { return .skipped("Already on") }

        if let mode = usableMode(deps), deps.activeModeID() == nil {
            await deps.activateMode(mode.id)
            guard deps.activeModeID() == mode.id else {
                return .failed(deps.modeError() ?? "\(mode.name) didn't start")
            }
            session.modeID = mode.id
            return .done("\(mode.name) on")
        }
        return await quietSetOn(context, engine: engine, deps: deps, session: session)
    }

    /// The picked mode, else ModeEngine's Presentation preset, when it
    /// neither hides nor quits apps.
    private static func usableMode(_ deps: PresentationMomentDeps) -> PresentationMomentModeInfo? {
        for id in [deps.chosenModeID(), deps.builtInModeID].compactMap({ $0 }) {
            if let info = deps.modeInfo(id), !info.hidesOrQuitsApps { return info }
        }
        return nil
    }

    /// Each step goes through the engine's current hook when there is one
    /// (SmartMomentsWiring's, wrapped by other moments: a share holds a
    /// put-back until it ends, a call's record is handed over), else straight
    /// to the controller.
    private static func step(
        _ action: MomentAction, _ context: MomentActionContext, engine: SmartMomentsController,
        checkAvailability: Bool, direct: @MainActor () async -> MomentActionResult
    ) async -> MomentActionResult {
        guard let hook = engine.hooks.actions[action] else { return await direct() }
        if checkAvailability, !engine.hooks.supports(action, for: context.trigger) { return .skipped("Not available") }
        return await hook(context)
    }

    private static func dndResult(_ outcome: PresentationMomentDNDOutcome, done: String) -> MomentActionResult {
        switch outcome {
        case .done: .done(done)
        case .notSetUp: .failed("Set up Do Not Disturb in Focus settings")
        case .failed(let message): .failed(message)
        }
    }

    private static func quietSetOn(
        _ context: MomentActionContext, engine: SmartMomentsController,
        deps: PresentationMomentDeps, session: PresentationMomentSession
    ) async -> MomentActionResult {
        let active = deps.activeModeID().flatMap(deps.modeInfo)
        var steps: [PresentationMomentSession.Step] = []
        var problems: [String] = []

        // DND already on through someone who will turn it off (a Focus
        // session, a mode, a call moment): leave it to them.
        if deps.dndUsable(), !deps.focusOwnsDND(), !(active?.turnsOnDoNotDisturb ?? false),
           !engine.ledger.owns(.doNotDisturbOff) {
            let result = await step(.doNotDisturbOn, context, engine: engine, checkAvailability: true) {
                dndResult(await deps.dndTurnOn(), done: "Do Not Disturb on")
            }
            switch result {
            case .done: steps.append(.doNotDisturb)
            case .failed(let message): problems.append(message)
            default: break
            }
        }
        if deps.previewsShown() {
            let result = await step(.hideNotificationPreviews, context, engine: engine, checkAvailability: true) {
                deps.setPreviewsShown(false)
                return .done("Previews hidden")
            }
            if result.changedState { steps.append(.previews) }
        }
        if deps.isPlaying() {
            let result = await step(.pauseMusic, context, engine: engine, checkAvailability: true) {
                deps.togglePlayPause()
                return .done("Paused music")
            }
            if result.changedState { steps.append(.music) }
        }
        session.steps = steps
        if steps.isEmpty {
            return problems.isEmpty ? .skipped("Already quiet") : .failed(problems.joined(separator: " · "))
        }
        return .done("Presentation mode on")
    }

    // MARK: - Presentation mode off (end, Undo, quit)

    private static func turnOff(
        _ context: MomentActionContext, engine: SmartMomentsController,
        deps: PresentationMomentDeps, session: PresentationMomentSession
    ) async -> MomentActionResult {
        if let id = session.modeID {
            session.modeID = nil
            // The user switched modes meanwhile: theirs stays.
            guard deps.activeModeID() == id else { return .skipped("Mode changed by hand") }
            await deps.deactivateMode()
            let name = deps.modeInfo(id)?.name ?? "Presentation mode"
            return deps.activeModeID() == id ? .failed(deps.modeError() ?? "\(name) is still on") : .done("\(name) off")
        }

        let steps = session.steps
        session.steps = []
        guard !steps.isEmpty else { return .skipped("Unchanged") }
        let active = deps.activeModeID().flatMap(deps.modeInfo)
        var undone = false
        var failed: String?
        var note = "Changed by hand"
        func absorb(_ result: MomentActionResult) {
            switch result {
            case .done: undone = true
            case .failed(let message): failed = message
            case .skipped(let why): note = why
            case .needsPermission: break
            }
        }
        for item in steps.reversed() {
            switch item {
            case .music:
                // Playing again (by hand), or a call moment resumes it later.
                guard !deps.isPlaying(), deps.hasPlayer(), !engine.ledger.owns(.resumeMusic) else { continue }
                absorb(await step(.resumeMusic, context, engine: engine, checkAvailability: false) {
                    deps.togglePlayPause()
                    return .done("Resumed music")
                })
            case .previews:
                guard !deps.previewsShown(), !deps.focusSessionActive(), !(active?.mutesPreviews ?? false),
                      !engine.ledger.owns(.showNotificationPreviews) else { continue }
                absorb(await step(.showNotificationPreviews, context, engine: engine, checkAvailability: false) {
                    deps.setPreviewsShown(true)
                    return .done("Previews back")
                })
            case .doNotDisturb:
                guard !deps.focusOwnsDND(), !(active?.turnsOnDoNotDisturb ?? false),
                      !engine.ledger.owns(.doNotDisturbOff) else { continue }
                absorb(await step(.doNotDisturbOff, context, engine: engine, checkAvailability: false) {
                    dndResult(await deps.dndTurnOff(), done: "Do Not Disturb off")
                })
            }
        }
        if undone { return .done("Presentation mode off") }
        if let failed { return .failed(failed) }
        return .skipped(note)
    }

    // MARK: - Helpers

    nonisolated static func info(for mode: SparkMode) -> PresentationMomentModeInfo {
        var hides = false
        var dnd = false
        var mutes = false
        for action in mode.actions {
            switch action {
            case .hideApps, .quitApps: hides = true
            case .doNotDisturb(let on): dnd = dnd || on
            case .muteNotificationsPreviews(let mute): mutes = mutes || mute
            default: break
            }
        }
        return PresentationMomentModeInfo(
            id: mode.id, name: mode.name, hidesOrQuitsApps: hides, turnsOnDoNotDisturb: dnd, mutesPreviews: mutes
        )
    }

    static func outcome(_ outcome: FocusDoNotDisturb.Outcome) -> PresentationMomentDNDOutcome {
        switch outcome {
        case .done: .done
        case .notSetUp: .notSetUp
        case .failed(let message): .failed(message)
        }
    }
}
