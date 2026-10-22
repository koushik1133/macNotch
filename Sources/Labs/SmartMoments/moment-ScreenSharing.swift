import Combine
import Foundation

// Smart Moments › Screen sharing (DESIGN.md moment 4).
//
// Another app starts sharing the screen: the engine runs (auto, the default)
// or offers these actions, and `screenSharingEnded` puts back exactly what
// they changed.
//
//   hideNotificationPreviews  NotificationMonitor.isEnabled = false (it also
//                     dismisses a preview on screen). Put back: true, only
//                     if we turned it off and it is still off.
//   hideClipboardBand ClipboardController.setShowsBannerForEveryCopy(false),
//                     and the "Copied" band on screen is dismissed
//                     (ActivityCenter.dismiss(id: ClipboardController.activityID)).
//                     History keeps recording. Put back: true, only if we
//                     turned it off and it is still off. Offered only while
//                     clipboard history is on (otherwise there is no band).
//   pauseMusic        MediaEngine.send(.togglePlayPause) when isPlaying.
//                     Put back: the same toggle, only if nothing plays now
//                     and the same player still owns Now Playing.
//   doNotDisturbOn    (off by default) left to the shared wiring hook.
//
// While a share is in effect, a put-back from another moment (Meeting ended's
// "Show previews" / "Resume music", Presentation's quiet set run through the
// hooks, an Undo) for a state the share protects is held and runs when the
// share ends, so nothing pops up on a shared screen. The user changing a
// state by hand (previews or the band turned on, music played) wins: we
// forget it and tell the engine (`userChanged`).
//
// The two settings are persisted by their controllers, so what we changed is
// noted in UserDefaults until put back; after a crash or force quit mid-share
// the next launch turns them back on. Music is never resumed at launch.
//
// Install after `SmartMomentsWiring.start()` (it wraps the shared hooks for
// these six actions; other moments' triggers still go to those hooks).
// Nothing here hides, quits or closes an app, records, or asks for a
// permission.

/// Everything the Screen sharing moment calls, as closures so tests can fake
/// them. `live(...)` builds it from the app's real controllers.
@MainActor
struct ScreenSharingMomentDeps {
    // SparkV notification previews (NotificationMonitor.isEnabled)
    var previewsShown: @MainActor () -> Bool
    var setPreviewsShown: @MainActor (Bool) -> Void
    var previewsChanges: AnyPublisher<Bool, Never>

    // Clipboard "Copied" band (ClipboardController)
    var clipboardHistoryOn: @MainActor () -> Bool
    var clipboardBandShown: @MainActor () -> Bool
    var setClipboardBandShown: @MainActor (Bool) -> Void
    var clipboardBandChanges: AnyPublisher<Bool, Never>
    /// Takes a "Copied" band off the screen now.
    var dismissClipboardBand: @MainActor () -> Void

    // Music (MediaEngine)
    var isPlaying: @MainActor () -> Bool
    var hasPlayer: @MainActor () -> Bool
    /// Bundle id of the app that owns Now Playing, when known.
    var playerID: @MainActor () -> String?
    var togglePlayPause: @MainActor () -> Void
    var playingChanges: AnyPublisher<Bool, Never>

    /// Another app shares the screen (SmartMomentsLiveSources.$isScreenSharing).
    var sharingChanges: AnyPublisher<Bool, Never>

    /// Where the "changed, not yet put back" note lives (crash safety).
    var defaults: UserDefaults = .standard
    /// After the share ends, how long the engine gets to put things back
    /// (with its "Put back" toast) before this file does it silently.
    var settleDelay: Duration = .seconds(3)
}

extension ScreenSharingMomentDeps {
    static func live(
        media: MediaEngine,
        notifications: NotificationMonitor,
        clipboard: ClipboardController,
        activities: ActivityCenter,
        sharing: AnyPublisher<Bool, Never>
    ) -> ScreenSharingMomentDeps {
        ScreenSharingMomentDeps(
            previewsShown: { [weak notifications] in notifications?.isEnabled ?? false },
            setPreviewsShown: { [weak notifications] on in notifications?.isEnabled = on },
            previewsChanges: notifications.$isEnabled.removeDuplicates().eraseToAnyPublisher(),
            clipboardHistoryOn: { [weak clipboard] in clipboard?.isEnabled ?? false },
            clipboardBandShown: { [weak clipboard] in clipboard?.showsBannerForEveryCopy ?? false },
            setClipboardBandShown: { [weak clipboard] on in clipboard?.setShowsBannerForEveryCopy(on) },
            clipboardBandChanges: clipboard.$showsBannerForEveryCopy.removeDuplicates().eraseToAnyPublisher(),
            dismissClipboardBand: { [weak activities] in activities?.dismiss(id: ClipboardController.activityID) },
            isPlaying: { [weak media] in media?.isPlaying ?? false },
            hasPlayer: { [weak media] in media.map { $0.source != .none } ?? false },
            playerID: { [weak media] in media?.sourceBundleID },
            togglePlayPause: { [weak media] in media?.send(.togglePlayPause) },
            playingChanges: media.$isPlaying.removeDuplicates().eraseToAnyPublisher(),
            sharingChanges: sharing
        )
    }
}

/// The share's own record of what it changed and what it holds.
@MainActor
final class ScreenSharingMomentSession {
    enum Part: String, CaseIterable, Sendable {
        case previews, clipboardBand, music

        var hideAction: MomentAction {
            switch self {
            case .previews: .hideNotificationPreviews
            case .clipboardBand: .hideClipboardBand
            case .music: .pauseMusic
            }
        }

        var restoreAction: MomentAction {
            switch self {
            case .previews: .showNotificationPreviews
            case .clipboardBand: .showClipboardBand
            case .music: .resumeMusic
            }
        }

        init?(hide action: MomentAction) {
            guard let part = Part.allCases.first(where: { $0.hideAction == action }) else { return nil }
            self = part
        }

        init?(restore action: MomentAction) {
            guard let part = Part.allCases.first(where: { $0.restoreAction == action }) else { return nil }
            self = part
        }
    }

    struct Hold {
        /// This share changed it (hid / paused): put it back when it ends.
        var changed = false
        /// Kept hidden or paused for this share (changed by us or already so).
        var protects = false
        /// Other moments' put-backs, held until the share ends (in order).
        var deferred: [(run: SmartMomentsHooks.Run, context: MomentActionContext)] = []
    }

    nonisolated static let defaultsKey = "SmartMoments.screenSharing.changed.v1"

    private(set) var holds: [Part: Hold] = [:]
    /// A share is in effect (from the live source or a share action).
    private(set) var isSharing = false
    /// Player we paused, so Resume never starts a different app.
    private(set) var pausedPlayerID: String?

    private let deps: ScreenSharingMomentDeps
    private weak var engine: SmartMomentsController?
    /// The shared hooks this file wraps (other moments' triggers go there).
    private var previous: [MomentAction: SmartMomentsHooks.Run] = [:]
    /// Set while we change a state ourselves (the change observers skip it).
    private var applying = false
    private var bag: Set<AnyCancellable> = []
    private var settleTask: Task<Void, Never>?

    init(engine: SmartMomentsController, deps: ScreenSharingMomentDeps) {
        self.engine = engine
        self.deps = deps
    }

    func hold(_ part: Part) -> Hold { holds[part] ?? Hold() }

    /// What is still changed and waiting to be put back.
    var changedParts: [Part] { Part.allCases.filter { hold($0).changed } }
    var hasSomethingToPutBack: Bool { Part.allCases.contains { hold($0).changed || !hold($0).deferred.isEmpty } }

    /// A share keeps this state hidden or paused right now.
    func isHolding(_ part: Part) -> Bool { isSharing && hold(part).protects }

    /// For a moment that puts a state back without going through the hooks
    /// (e.g. Presentation's quiet set): while the share holds `part`, keeps
    /// `putBack` and runs it when the share ends, and returns true. False:
    /// nothing is held, put it back now.
    @discardableResult
    func holdUntilShareEnds(_ part: Part, context: MomentActionContext, _ putBack: @escaping SmartMomentsHooks.Run) -> Bool {
        guard isHolding(part) else { return false }
        holds[part, default: Hold()].deferred.append((putBack, context))
        return true
    }

    // MARK: - Install

    private static var sessions: [ObjectIdentifier: ScreenSharingMomentSession] = [:]

    /// The installed session for `engine`, if any (Settings, other moments).
    static func session(for engine: SmartMomentsController) -> ScreenSharingMomentSession? {
        guard let session = sessions[ObjectIdentifier(engine)], session.engine === engine else { return nil }
        return session
    }

    fileprivate func install() {
        guard let engine else { return }
        recoverAfterCrash()
        var h = engine.hooks
        for part in Part.allCases {
            let hide = part.hideAction
            let restore = part.restoreAction
            if let existing = h.actions[hide] { previous[hide] = existing }
            if let existing = h.actions[restore] { previous[restore] = existing }

            h.actions[hide] = { [weak self] context in
                guard let self else { return .skipped("Unavailable") }
                if context.trigger.moment == .screenSharing { return self.hide(part) }
                return await self.forward(hide, context)
            }
            h.actions[restore] = { [weak self] context in
                guard let self else { return .skipped("Unavailable") }
                if context.trigger.moment == .screenSharing { return self.putBack(part, context: context) }
                return await self.othersPutBack(part, context: context)
            }
        }
        // The band only exists while clipboard history is on.
        let earlierBandCheck = h.isAvailable[.hideClipboardBand]
        h.isAvailable[.hideClipboardBand] = { [deps] trigger in
            if trigger.moment == .screenSharing { return deps.clipboardHistoryOn() }
            return earlierBandCheck?(trigger) ?? true
        }
        engine.hooks = h
        observe()
    }

    // MARK: - The share's actions

    private func hide(_ part: Part) -> MomentActionResult {
        isSharing = true
        settleTask?.cancel()
        var hold = hold(part)
        defer { holds[part] = hold; saveNote() }
        switch part {
        case .previews:
            hold.protects = true
            guard deps.previewsShown() else { return .skipped("Already hidden") }
            apply { deps.setPreviewsShown(false) }
            hold.changed = true
            return .done("Previews hidden")
        case .clipboardBand:
            deps.dismissClipboardBand()
            guard deps.clipboardHistoryOn() else { return .skipped("Clipboard history is off") }
            hold.protects = true
            guard deps.clipboardBandShown() else { return .skipped("Already hidden") }
            apply { deps.setClipboardBandShown(false) }
            hold.changed = true
            return .done("Clipboard band hidden")
        case .music:
            hold.protects = true
            guard deps.isPlaying() else { return .skipped("Nothing playing") }
            pausedPlayerID = deps.playerID()
            apply { deps.togglePlayPause() }
            hold.changed = true
            return .done("Paused music")
        }
    }

    /// The engine puts back what the share changed: on `screenSharingEnded`,
    /// on quit (also `screenSharingEnded`) or on Undo (`screenSharingStarted`).
    private func putBack(_ part: Part, context: MomentActionContext) -> MomentActionResult {
        var hold = hold(part)
        let wasChanged = hold.changed
        let deferred = hold.deferred
        hold = Hold() // Undo or end: this share no longer holds it
        holds[part] = hold
        if case .screenSharingEnded = context.trigger { isSharing = false }
        defer { saveNote() }

        var result: MomentActionResult = .skipped("Unchanged")
        if wasChanged { result = restore(part) }
        runHeld(deferred)
        if case .screenSharingEnded = context.trigger { finishShare(includingChanged: false) }
        return result
    }

    /// Puts one state back if it is still the way we left it.
    private func restore(_ part: Part) -> MomentActionResult {
        switch part {
        case .previews:
            guard !deps.previewsShown() else { return .skipped("Already shown") }
            apply { deps.setPreviewsShown(true) }
            return .done("Previews back")
        case .clipboardBand:
            guard !deps.clipboardBandShown() else { return .skipped("Already shown") }
            apply { deps.setClipboardBandShown(true) }
            return .done("Clipboard band back")
        case .music:
            let paused = pausedPlayerID
            pausedPlayerID = nil
            guard !deps.isPlaying() else { return .skipped("Already playing") }
            guard deps.hasPlayer() else { return .skipped("Nothing to resume") }
            if let paused, let now = deps.playerID(), paused != now { return .skipped("Another player now") }
            apply { deps.togglePlayPause() }
            return .done("Resumed music")
        }
    }

    // MARK: - Other moments

    private func forward(_ action: MomentAction, _ context: MomentActionContext) async -> MomentActionResult {
        guard let run = previous[action] else { return .skipped("Not available") }
        return await run(context)
    }

    /// Another moment puts back previews, the band or music. While the share
    /// protects that state it waits for the share to end.
    private func othersPutBack(_ part: Part, context: MomentActionContext) async -> MomentActionResult {
        let restore = part.restoreAction
        guard isSharing, hold(part).protects, let run = previous[restore] else {
            return await forward(restore, context)
        }
        holds[part, default: Hold()].deferred.append((run, context))
        return .skipped(part == .music ? "Music stays paused while sharing" : "Kept hidden while sharing")
    }

    // MARK: - Share ended, hand changes

    private func observe() {
        deps.sharingChanges
            .removeDuplicates()
            .sink { [weak self] sharing in
                guard let self else { return }
                if sharing {
                    self.isSharing = true
                    self.settleTask?.cancel()
                } else if self.isSharing {
                    self.shareStopped()
                }
            }
            .store(in: &bag)

        deps.previewsChanges
            .sink { [weak self] shown in if shown { self?.changedByHand(.previews) } }
            .store(in: &bag)
        deps.clipboardBandChanges
            .sink { [weak self] shown in if shown { self?.changedByHand(.clipboardBand) } }
            .store(in: &bag)
        deps.playingChanges
            .sink { [weak self] playing in if playing { self?.changedByHand(.music) } }
            .store(in: &bag)
    }

    /// The live source says the share stopped. The engine's own
    /// `screenSharingEnded` puts back what we changed (with its toast); held
    /// put-backs of other moments run now, and anything still changed after
    /// `settleDelay` is put back here, so nothing stays hidden.
    private func shareStopped() {
        isSharing = false
        finishShare(includingChanged: false)
        settleTask?.cancel()
        let delay = deps.settleDelay
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isSharing else { return }
            self.finishShare(includingChanged: true)
        }
    }

    private func finishShare(includingChanged: Bool) {
        for part in Part.allCases {
            var hold = hold(part)
            if includingChanged, hold.changed {
                hold.changed = false
                holds[part] = hold
                _ = restore(part)
            }
            guard !hold.changed else { continue }
            runHeld(hold.deferred)
            holds[part] = Hold()
        }
        saveNote()
    }

    /// The user (or another app) turned it back on or played music: theirs
    /// wins, and nothing is put back later.
    private func changedByHand(_ part: Part) {
        guard !applying else { return }
        let hold = hold(part)
        guard hold.changed || hold.protects || !hold.deferred.isEmpty else { return }
        holds[part] = Hold()
        if part == .music { pausedPlayerID = nil }
        engine?.userChanged(part.restoreAction)
        saveNote()
    }

    /// Held put-backs of other moments, in the order they came.
    private func runHeld(_ held: [(run: SmartMomentsHooks.Run, context: MomentActionContext)]) {
        guard !held.isEmpty else { return }
        Task {
            for item in held { _ = await item.run(item.context) }
        }
    }

    private func apply(_ change: () -> Void) {
        applying = true
        change()
        applying = false
    }

    // MARK: - Crash safety

    private func saveNote() {
        // Music is left out: it is never resumed at launch.
        let parts = changedParts.filter { $0 != .music }.map(\.rawValue)
        if parts.isEmpty {
            deps.defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            deps.defaults.set(parts, forKey: Self.defaultsKey)
        }
    }

    /// SparkV ended mid-share last time: turn back on what we had turned off.
    private func recoverAfterCrash() {
        let parts = (deps.defaults.stringArray(forKey: Self.defaultsKey) ?? []).compactMap(Part.init(rawValue:))
        guard !parts.isEmpty else { return }
        deps.defaults.removeObject(forKey: Self.defaultsKey)
        for part in parts {
            switch part {
            case .previews where !deps.previewsShown(): apply { deps.setPreviewsShown(true) }
            case .clipboardBand where !deps.clipboardBandShown(): apply { deps.setClipboardBandShown(true) }
            default: break
            }
        }
        AppLog.log("SmartMoments: screenSharing restored after an unfinished share: " + parts.map(\.rawValue).joined(separator: ", "))
    }

    fileprivate static func register(_ session: ScreenSharingMomentSession, for engine: SmartMomentsController) {
        sessions = sessions.filter { $0.value.engine != nil }
        sessions[ObjectIdentifier(engine)] = session
    }
}

enum ScreenSharingMoment {
    /// Registers the Screen sharing hooks and put-backs. Call once, after
    /// `SmartMomentsWiring.start()`; a second call returns the first session.
    @MainActor
    @discardableResult
    static func install(on engine: SmartMomentsController, deps: ScreenSharingMomentDeps) -> ScreenSharingMomentSession {
        if let existing = ScreenSharingMomentSession.session(for: engine) { return existing }
        let session = ScreenSharingMomentSession(engine: engine, deps: deps)
        ScreenSharingMomentSession.register(session, for: engine)
        session.install()
        return session
    }
}
