import Foundation

// Smart Moments, moment 3: "Meeting ended" (DESIGN.md).
//
// When a call ends the band offers:
//   - Notes wrap-up: a tap only. Stops a recording that is still going
//     (MeetingAssistant.stop() writes the minutes and opens them) and shows
//     MeetingIntel's wrap-up when it is built, else opens the notes window.
//   - Resume music: only when "Meeting started" paused it for this call and
//     the same player is still paused.
//   - Do Not Disturb off: only when "Meeting started" turned it on for this
//     call and no Focus session or mode holds it now.
//   - Show notification previews: only when "Meeting started" hid them for
//     this call and they are still hidden.
//
// The engine's ledger already limits the reversal chips to what the start
// moment changed. This file adds the exact record (which call, which player)
// by observing the start moment's hooks, so a call never puts back something
// a screen share, a presentation or the user changed in between. Undo on the
// band pauses, silences or hides again only what this band changed.
// Nothing here hides or quits apps, records, or asks for a permission.
//
// Install after `SmartMomentsWiring.start()` and after
// `MeetingStartedMoment.install` (hooks are wrapped, never replaced, for every
// other moment; installed earlier it still works from the engine's ledger).
// See INTEGRATION.md "Moment: MeetingEnded".

/// What "Meeting ended" needs from the app. `live(...)` builds it from the
/// real controllers; tests pass fakes.
@MainActor
struct MeetingEndedMomentDeps {
    /// The player that owns Now Playing (bundle id + title).
    struct NowPlaying: Equatable, Sendable {
        var bundleID: String?
        var title: String
    }

    // Notes (MeetingAssistant, MeetingIntel) --------------------------------
    /// MeetingAssistant is still recording this meeting (not tied to the call).
    var isRecordingMeeting: @MainActor (UUID) -> Bool
    /// MeetingAssistant is writing this meeting's minutes.
    var isWritingNotes: @MainActor (UUID) -> Bool
    /// The meeting exists (live or in the library).
    var hasMeeting: @MainActor (UUID) -> Bool
    /// MeetingAssistant.stop(): stops, writes the minutes and opens them.
    var stopRecording: @MainActor () -> Void
    /// MeetingAssistant.openNotesWindow(meetingID:).
    var openNotes: @MainActor (UUID) -> Void
    /// MeetingIntel wrap-up window (`MeetingWrapUpController.openWindow`), when built.
    var openWrapUp: (@MainActor (UUID) -> Void)?
    /// MeetingIntel wrap-up once the minutes exist (`present(meetingID:session:sidecar:)`).
    var presentWrapUp: (@MainActor (UUID) -> Void)?

    // Music (MediaEngine) ------------------------------------------------------
    var isMusicPlaying: @MainActor () -> Bool
    /// nil = no player owns Now Playing.
    var nowPlaying: @MainActor () -> NowPlaying?
    var togglePlayPause: @MainActor () -> Void

    // Do Not Disturb (FocusController's shortcuts, ModeEngine) -----------------
    /// The user's DND shortcuts exist.
    var dndAvailable: @MainActor () -> Bool
    /// Why DND belongs to someone else now (a Focus session, a mode), or nil.
    var dndHeldElsewhere: @MainActor () -> String?
    /// Runs the on (true) or off (false) shortcut.
    var setDoNotDisturb: @MainActor (Bool) async -> MomentActionResult

    // SparkV's notification previews (NotificationMonitor) ---------------------
    var previewsShown: @MainActor () -> Bool
    /// Why previews stay hidden (a Focus session restores them itself), or nil.
    var previewsHeldElsewhere: @MainActor () -> String?
    var setPreviewsShown: @MainActor (Bool) -> Void

    var now: @MainActor () -> Date = { Date() }
}

extension MeetingEndedMomentDeps {
    /// The real controllers. `openWrapUp` / `presentWrapUp` come from
    /// MeetingIntel when it is built (nil = MeetingAssistant's notes window).
    static func live(
        assistant: MeetingAssistant,
        media: MediaEngine,
        focus: FocusController,
        notifications: NotificationMonitor,
        modes: ModeEngine? = nil,
        openWrapUp: (@MainActor (UUID) -> Void)? = nil,
        presentWrapUp: (@MainActor (UUID) -> Void)? = nil
    ) -> MeetingEndedMomentDeps {
        let modes = modes ?? ModeEngine.shared
        return MeetingEndedMomentDeps(
            isRecordingMeeting: { [weak assistant] id in
                guard let assistant else { return false }
                return assistant.isRecording && assistant.current?.id == id
            },
            isWritingNotes: { [weak assistant] id in
                guard let assistant else { return false }
                return assistant.phase == .summarizing && assistant.current?.id == id
            },
            hasMeeting: { [weak assistant] id in assistant?.record(id: id) != nil },
            stopRecording: { [weak assistant] in assistant?.stop() },
            openNotes: { [weak assistant] id in assistant?.openNotesWindow(meetingID: id) },
            openWrapUp: openWrapUp,
            presentWrapUp: presentWrapUp,
            isMusicPlaying: { [weak media] in media?.isPlaying ?? false },
            nowPlaying: { [weak media] in
                guard let media, media.source != .none else { return nil }
                return NowPlaying(bundleID: media.sourceBundleID, title: media.title)
            },
            togglePlayPause: { [weak media] in media?.send(.togglePlayPause) },
            dndAvailable: { [weak focus] in
                guard let focus else { return false }
                if case .missing = focus.doNotDisturb.setup { return false }
                return true
            },
            dndHeldElsewhere: { [weak focus, weak modes] in
                if focus?.active?.didEnableDoNotDisturb == true { return "Focus keeps it on" }
                if let modes, let id = modes.activeModeID, let mode = modes.mode(id),
                   mode.actions.contains(.doNotDisturb(true)) {
                    return "\(mode.name) keeps it on"
                }
                return nil
            },
            setDoNotDisturb: { [weak focus] on in
                guard let focus else { return .skipped("Unavailable") }
                let s = focus.settings
                if on { await focus.doNotDisturb.refresh(on: s.dndOnShortcut, off: s.dndOffShortcut) }
                let outcome = on
                    ? await focus.doNotDisturb.turnOn(s.dndOnShortcut)
                    : await focus.doNotDisturb.turnOff(s.dndOffShortcut)
                switch outcome {
                case .done: return .done(on ? "Do Not Disturb on" : "Do Not Disturb off")
                case .notSetUp: return .failed("Set up Do Not Disturb in Focus settings")
                case .failed(let message): return .failed(message)
                }
            },
            previewsShown: { [weak notifications] in notifications?.isEnabled ?? true },
            previewsHeldElsewhere: { [weak focus] in focus?.active != nil ? "Focus keeps them hidden" : nil },
            setPreviewsShown: { [weak notifications] shown in notifications?.isEnabled = shown }
        )
    }
}

/// What "Meeting started" changed, per call, and what each "Meeting ended"
/// band changed (for its Undo). Owned by the closures `install` registers.
@MainActor
final class MeetingEndedMomentState {
    struct Owned: Equatable {
        /// nil: another moment (a share, a presentation) changed it since.
        let callKey: String?
        let at: Date
        /// The player that was paused (music only).
        var player: MeetingEndedMomentDeps.NowPlaying?
    }

    struct BandChanges: Equatable {
        var resumed: MeetingEndedMomentDeps.NowPlaying?
        var didResume = false
        var dndOff = false
        var previewsShown = false
    }

    /// A record older than this is stale (a call can't run that long).
    static let maxAge: TimeInterval = 12 * 3600

    fileprivate(set) var pausedMusic: Owned?
    fileprivate(set) var dndOn: Owned?
    fileprivate(set) var previewsHidden: Owned?
    fileprivate(set) var bands: [UUID: BandChanges] = [:]

    fileprivate func valid(_ owned: Owned?, key: String?, now: Date) -> Owned? {
        guard let owned, owned.callKey != nil, now.timeIntervalSince(owned.at) < Self.maxAge else { return nil }
        if let key, owned.callKey != key { return nil }
        return owned
    }

    fileprivate func change(_ offerID: UUID, _ edit: (inout BandChanges) -> Void) {
        var changes = bands[offerID] ?? BandChanges()
        edit(&changes)
        bands[offerID] = changes
        if bands.count > 20, let oldest = bands.keys.first { bands[oldest] = nil }
    }
}

enum MeetingEndedMoment {
    /// Registers "Meeting ended"'s action handlers and Undo put-backs on the
    /// engine. Call once, after `SmartMomentsWiring.start()`.
    @MainActor
    @discardableResult
    static func install(on engine: SmartMomentsController, deps: MeetingEndedMomentDeps) -> MeetingEndedMomentState {
        let state = MeetingEndedMomentState()
        let startOwns: @MainActor (MomentAction) -> Bool = { [weak engine] reversal in
            engine?.ownedReversals(for: .meetingStarted).contains(reversal) ?? false
        }
        var h = engine.hooks

        // Earlier hooks, kept for every other moment.
        let pauseBefore = h.actions[.pauseMusic]
        let resumeBefore = h.actions[.resumeMusic]
        let resumeAvailableBefore = h.isAvailable[.resumeMusic]
        let dndOnBefore = h.actions[.doNotDisturbOn]
        let dndOffBefore = h.actions[.doNotDisturbOff]
        let dndOffAvailableBefore = h.isAvailable[.doNotDisturbOff]
        let hideBefore = h.actions[.hideNotificationPreviews]
        let showBefore = h.actions[.showNotificationPreviews]
        let showAvailableBefore = h.isAvailable[.showNotificationPreviews]
        let wrapUpBefore = h.actions[.notesWrapUp]

        // Observe what "Meeting started" changes ------------------------------
        // The record has one owner, like the engine's ledger: a later pause by
        // a screen share or a presentation takes it over.

        h.actions[.pauseMusic] = { context in
            let player = deps.nowPlaying()
            let result: MomentActionResult
            if let pauseBefore {
                result = await pauseBefore(context)
            } else if deps.isMusicPlaying() {
                deps.togglePlayPause()
                result = .done("Paused music")
            } else {
                result = .skipped("Nothing playing")
            }
            if result.changedState {
                if case .meetingStarted(let call) = context.trigger {
                    state.pausedMusic = .init(callKey: call.key, at: deps.now(), player: player)
                } else {
                    state.pausedMusic = .init(callKey: nil, at: deps.now())
                }
            }
            return result
        }

        h.actions[.doNotDisturbOn] = { context in
            let result: MomentActionResult
            if let dndOnBefore {
                result = await dndOnBefore(context)
            } else if let reason = deps.dndHeldElsewhere() {
                result = .skipped(reason)
            } else {
                result = await deps.setDoNotDisturb(true)
            }
            if result.changedState {
                if case .meetingStarted(let call) = context.trigger {
                    state.dndOn = .init(callKey: call.key, at: deps.now())
                } else {
                    state.dndOn = .init(callKey: nil, at: deps.now())
                }
            }
            return result
        }

        h.actions[.hideNotificationPreviews] = { context in
            let result: MomentActionResult
            if let hideBefore {
                result = await hideBefore(context)
            } else if deps.previewsShown() {
                deps.setPreviewsShown(false)
                result = .done("Previews hidden")
            } else {
                result = .skipped("Already hidden")
            }
            if result.changedState {
                if case .meetingStarted(let call) = context.trigger {
                    state.previewsHidden = .init(callKey: call.key, at: deps.now())
                } else {
                    state.previewsHidden = .init(callKey: nil, at: deps.now())
                }
            }
            return result
        }

        // Put back what this call changed ----------------------------------------
        // Our record says which call changed what (or that another moment
        // changed it since). With no record at all (a moment installed after
        // this one handled the start), the engine's ledger decides and the
        // earlier handler does the work as before. Where an earlier handler
        // exists (SmartMomentsWiring's, moment-MeetingStarted.swift's owning
        // reversal) it does the work after our checks, so its own record clears.

        enum Claim { case recorded, ledgerOnly, none }

        /// key nil: the engine puts back silently (Meeting ended is off,
        /// snoozed or quiet, Reset, or quitting) with a stand-in trigger.
        func claim(_ owned: MeetingEndedMomentState.Owned?, _ reversal: MomentAction, key: String?) -> Claim {
            if owned != nil { return state.valid(owned, key: key, now: deps.now()) != nil ? .recorded : .none }
            guard key != nil else { return .none }
            return startOwns(reversal) ? .ledgerOnly : .none
        }

        func resume(key: String?, context: MomentActionContext) async -> MomentActionResult {
            let paused = state.pausedMusic
            switch claim(paused, .resumeMusic, key: key) {
            case .none:
                return .skipped("SparkV didn't pause it")
            case .recorded:
                state.pausedMusic = nil
                guard !deps.isMusicPlaying() else { return .skipped("Already playing") }
                guard let player = deps.nowPlaying() else { return .skipped("Nothing to resume") }
                if let was = paused?.player, was.bundleID != nil, was.bundleID != player.bundleID {
                    return .skipped("Something else is in Now Playing")
                }
            case .ledgerOnly:
                break
            }
            let player = deps.nowPlaying()
            let result: MomentActionResult
            if let resumeBefore {
                result = await resumeBefore(context)
            } else if !deps.isMusicPlaying(), player != nil {
                deps.togglePlayPause()
                result = .done("Resumed music")
            } else {
                result = .skipped("Nothing to resume")
            }
            if result.changedState { state.change(context.offerID) { $0.didResume = true; $0.resumed = player } }
            return result
        }

        h.actions[.resumeMusic] = { context in
            switch context.trigger {
            case .meetingEnded(let call, _):
                return await resume(key: call.key, context: context)
            case .screenSharingStarted, .screenSharingEnded, .presentationStarted, .presentationEnded:
                // The call's silent put-back uses a stand-in trigger; a share or
                // a presentation that paused music took the record over.
                if state.valid(state.pausedMusic, key: nil, now: deps.now()) != nil {
                    return await resume(key: nil, context: context)
                }
                return await resumeBefore?(context) ?? .skipped("Not available")
            default:
                // Another moment's own Resume (not a call's): theirs.
                let player = deps.nowPlaying()
                let result = await resumeBefore?(context) ?? .skipped("Not available")
                if result.changedState {
                    state.pausedMusic = nil
                    state.change(context.offerID) { $0.didResume = true; $0.resumed = player }
                }
                return result
            }
        }
        h.isAvailable[.resumeMusic] = { trigger in
            guard case .meetingEnded(let call, _) = trigger else { return resumeAvailableBefore?(trigger) ?? true }
            switch claim(state.pausedMusic, .resumeMusic, key: call.key) {
            case .none: return false
            case .recorded: return !deps.isMusicPlaying() && deps.nowPlaying() != nil
            case .ledgerOnly: return resumeAvailableBefore?(trigger) ?? (!deps.isMusicPlaying() && deps.nowPlaying() != nil)
            }
        }

        func dndOff(key: String?, context: MomentActionContext) async -> MomentActionResult {
            switch claim(state.dndOn, .doNotDisturbOff, key: key) {
            case .none:
                return .skipped("SparkV didn't turn it on")
            case .recorded:
                state.dndOn = nil
                if let reason = deps.dndHeldElsewhere() { return .skipped(reason) }
            case .ledgerOnly:
                break
            }
            let result: MomentActionResult
            if let dndOffBefore {
                result = await dndOffBefore(context)
            } else if let reason = deps.dndHeldElsewhere() {
                result = .skipped(reason)
            } else {
                result = await deps.setDoNotDisturb(false)
            }
            if result.changedState { state.change(context.offerID) { $0.dndOff = true } }
            return result
        }

        h.actions[.doNotDisturbOff] = { context in
            switch context.trigger {
            case .meetingEnded(let call, _):
                return await dndOff(key: call.key, context: context)
            case .screenSharingEnded, .presentationEnded, .screenSharingStarted, .presentationStarted:
                if state.valid(state.dndOn, key: nil, now: deps.now()) != nil {
                    return await dndOff(key: nil, context: context)
                }
                return await dndOffBefore?(context) ?? .skipped("Not available")
            default:
                return await dndOffBefore?(context) ?? .skipped("Not available")
            }
        }
        h.isAvailable[.doNotDisturbOff] = { trigger in
            guard case .meetingEnded(let call, _) = trigger else { return dndOffAvailableBefore?(trigger) ?? true }
            switch claim(state.dndOn, .doNotDisturbOff, key: call.key) {
            case .none: return false
            case .recorded: return deps.dndAvailable() && deps.dndHeldElsewhere() == nil
            case .ledgerOnly: return dndOffAvailableBefore?(trigger) ?? deps.dndAvailable()
            }
        }

        func show(key: String?, context: MomentActionContext) async -> MomentActionResult {
            switch claim(state.previewsHidden, .showNotificationPreviews, key: key) {
            case .none:
                return .skipped("SparkV didn't hide them")
            case .recorded:
                state.previewsHidden = nil
                guard !deps.previewsShown() else { return .skipped("Already shown") }
                if let reason = deps.previewsHeldElsewhere() { return .skipped(reason) }
            case .ledgerOnly:
                break
            }
            let result: MomentActionResult
            if let showBefore {
                result = await showBefore(context)
            } else if !deps.previewsShown(), deps.previewsHeldElsewhere() == nil {
                deps.setPreviewsShown(true)
                result = .done("Previews back")
            } else {
                result = .skipped("Already shown")
            }
            if result.changedState { state.change(context.offerID) { $0.previewsShown = true } }
            return result
        }

        h.actions[.showNotificationPreviews] = { context in
            switch context.trigger {
            case .meetingEnded(let call, _):
                return await show(key: call.key, context: context)
            case .screenSharingEnded, .presentationEnded, .screenSharingStarted, .presentationStarted:
                if state.valid(state.previewsHidden, key: nil, now: deps.now()) != nil {
                    return await show(key: nil, context: context)
                }
                return await showBefore?(context) ?? .skipped("Not available")
            default:
                return await showBefore?(context) ?? .skipped("Not available")
            }
        }
        h.isAvailable[.showNotificationPreviews] = { trigger in
            guard case .meetingEnded(let call, _) = trigger else { return showAvailableBefore?(trigger) ?? true }
            switch claim(state.previewsHidden, .showNotificationPreviews, key: call.key) {
            case .none: return false
            case .recorded: return !deps.previewsShown() && deps.previewsHeldElsewhere() == nil
            case .ledgerOnly: return showAvailableBefore?(trigger) ?? !deps.previewsShown()
            }
        }

        // Notes wrap-up (a tap only) -------------------------------------------------

        h.actions[.notesWrapUp] = { context in
            guard case .meetingEnded(_, let recorded) = context.trigger else {
                return await wrapUpBefore?(context) ?? .skipped("No notes")
            }
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard let id = recorded, deps.hasMeeting(id) || deps.isRecordingMeeting(id) else {
                return .skipped("No notes")
            }
            if deps.isRecordingMeeting(id) {
                // Recorded by hand, so it didn't stop with the call: stop and
                // write the minutes (MeetingAssistant opens them when ready).
                deps.stopRecording()
                deps.presentWrapUp?(id)
                return .done("Writing notes")
            }
            if deps.isWritingNotes(id) {
                // MeetingAssistant opens the notes when they are written;
                // MeetingIntel's wrap-up waits for them too.
                deps.presentWrapUp?(id)
                return .done("Notes on the way")
            }
            if let openWrapUp = deps.openWrapUp {
                openWrapUp(id)
                return .done("Wrap-up open")
            }
            deps.openNotes(id)
            return .done("Notes open")
        }
        h.isAvailable[.notesWrapUp] = { trigger in
            guard case .meetingEnded(_, let id?) = trigger else { return false }
            return deps.hasMeeting(id) || deps.isRecordingMeeting(id)
        }

        engine.hooks = h

        // Undo on the band: puts back only what that band changed -----------------
        // The engine runs put-backs on Undo (a tap) and, for moments in effect,
        // when they end; "Meeting ended" isn't in effect, so only Undo counts.

        let resumePutBackBefore = engine.putBack[.resumeMusic]
        engine.putBack[.resumeMusic] = { context in
            guard context.userInitiated else { return await resumePutBackBefore?(context) ?? .skipped("Needs a tap") }
            guard let changes = state.bands[context.offerID], changes.didResume else {
                return await resumePutBackBefore?(context) ?? .skipped("Unchanged")
            }
            state.change(context.offerID) { $0.didResume = false }
            guard deps.isMusicPlaying() else { return .skipped("Already paused") }
            if let resumed = changes.resumed, let player = deps.nowPlaying(), resumed.bundleID != player.bundleID {
                return .skipped("Something else is playing")
            }
            deps.togglePlayPause()
            return .done("Paused music")
        }

        let dndPutBackBefore = engine.putBack[.doNotDisturbOff]
        engine.putBack[.doNotDisturbOff] = { context in
            guard context.userInitiated, case .meetingEnded = context.trigger else {
                return await dndPutBackBefore?(context) ?? .skipped("Needs a tap")
            }
            guard state.bands[context.offerID]?.dndOff == true else { return .skipped("Unchanged") }
            state.change(context.offerID) { $0.dndOff = false }
            // Back on and staying on: Undo means "keep it on", so no owner.
            return await deps.setDoNotDisturb(true)
        }

        let showPutBackBefore = engine.putBack[.showNotificationPreviews]
        engine.putBack[.showNotificationPreviews] = { context in
            guard context.userInitiated, case .meetingEnded = context.trigger else {
                return await showPutBackBefore?(context) ?? .skipped("Needs a tap")
            }
            guard state.bands[context.offerID]?.previewsShown == true else { return .skipped("Unchanged") }
            state.change(context.offerID) { $0.previewsShown = false }
            guard deps.previewsShown() else { return .skipped("Already hidden") }
            deps.setPreviewsShown(false)
            return .done("Previews hidden")
        }

        return state
    }
}
