import Foundation

// The Smart Moments engine (DESIGN.md "Engine rules"). Detectors report a
// `MomentTrigger` through `handle(_:)`; the engine applies the settings,
// quiet conditions, cooldowns and band priority, then shows an offer, runs it
// automatically, or ends a moment in effect and puts back what it changed.
//
// Everything the engine does to the system goes through `hooks` (set in
// wiring) or the MeetingIntel bridge. The engine itself never records,
// captures, sends, hides or quits anything.

/// One line of the engine's log (kept in memory, newest last, and mirrored
/// to AppLog without any copied text, file names or meeting titles).
struct SmartMomentsLogEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let at: Date
    let moment: MomentID?
    let message: String
}

/// Engine-side rules that complement the per-action flags in the models.
enum MomentEngineRules {
    /// In auto mode these stay chips: they open a window, a file or a link,
    /// which must follow a tap (an auto-opened download is a security risk,
    /// the wrap-up is "a chip" in DESIGN.md).
    /// The mirror (camera light) and System Settings also wait for a tap.
    static let chipOnlyInAuto: Set<MomentAction> = [
        .notesWrapUp, .openFile, .revealInFinder, .openLink, .annotateImage, .showAgendaBrief,
        .openMirror, .openBatterySettings,
    ]

    /// Moments that stay in effect until an end trigger (or "Meeting
    /// ended"): their `putBack` entries outlive the band. Other moments'
    /// put-backs only serve Undo while their band is up.
    static let lastingMoments: Set<MomentID> = [.meetingStarted, .screenSharing, .presentation]

    /// Never offered while the user is on a call (DESIGN.md).
    static let quietDuringCalls: Set<MomentID> = [.deepWork, .lateNight, .meetingSoon]

    /// Show the copied or captured content: dropped when sharing starts.
    static let contentMoments: Set<MomentID> = [.copiedSmart, .screenshotTaken, .downloadFinished]

    /// Moments whose meeting chips MeetingIntel may take over (rule 11).
    static let meetingMoments: Set<MomentID> = [.meetingSoon, .meetingStarted, .meetingEnded]

    /// Queue of offers waiting behind the band (rule 1).
    static let queueLimit = 3
    /// How long the "Done · Undo" band of an auto run stays (rule 3).
    static let autoDoneDuration: TimeInterval = 6
    /// A zero cooldown means "once per dedupe key"; keys are kept this long.
    static let onceMemory: TimeInterval = 36 * 3600
    /// Dismissals in a row before the band asks to turn the moment off.
    static let dismissStreakLimit = 3
    static let logLimit = 200
    static let feature = "Smart Moments"
}

@MainActor
final class SmartMomentsController: ObservableObject, SmartMomentsEngine {
    static weak var current: SmartMomentsController?

    let settings: SmartMomentsSettings
    var hooks: SmartMomentsHooks
    /// Strong: wiring hands over MeetingIntel's coordinator here.
    var meetingIntel: (any MeetingIntelBridge)?

    @Published private(set) var currentOffer: MomentOffer? {
        didSet { if oldValue != currentOffer { onOfferChanged?(currentOffer) } }
    }
    /// Offers waiting behind the band, highest priority first.
    @Published private(set) var queue: [MomentOffer] = []
    @Published private(set) var log: [SmartMomentsLogEntry] = []
    /// What the engine changed and will put back (rule 5).
    private(set) var ledger = MomentRestoreLedger()

    var onOfferChanged: ((MomentOffer?) -> Void)?
    var onDone: ((MomentID, String) -> Void)?

    /// Puts back an action that has no reversal pair: presentation mode
    /// (deactivate the mode), quiet notch, a sorted download (move back),
    /// captions started for a call. Run on Undo and when the moment ends.
    var putBack: [MomentAction: SmartMomentsHooks.Run] = [:]
    /// Asks for a blocked chip's permission (a tap only). Through
    /// PermissionCenter by default; tests replace it.
    var requestPermissionHandler: @MainActor (PermissionCenter.Permission, String) async -> Bool = { permission, feature in
        await PermissionCenter.shared.request(permission, from: feature).isGranted
    }
    var writesAppLog = true
    /// Off in tests, which call `tick()` with a fake clock.
    var schedulesTimers = true

    // State ----------------------------------------------------------------

    /// "moment|dedupeKey" -> when it was last handled (rule 7).
    private var handledAt: [String: Date] = [:]
    /// Offers folded into MeetingIntel's own prompt (no band of ours).
    private var detached: [UUID: MomentOffer] = [:]
    /// Actions an offer ran, for Undo (auto runs and "Do it").
    private var undoRecords: [UUID: UndoRecord] = [:]
    /// Ran actions with a `putBack` handler, until their moment ends.
    private var putBackEntries: [PutBackEntry] = []
    private var accepting: Set<UUID> = []
    private var pending: [MomentTrigger] = []
    private var isDraining = false
    private var expiryTask: Task<Void, Never>?

    private struct UndoRecord {
        let moment: MomentID
        let trigger: MomentTrigger
        let actions: [MomentAction]
    }

    private struct PutBackEntry {
        let moment: MomentID
        let offerID: UUID
        let trigger: MomentTrigger
        let action: MomentAction
    }

    /// `hooks` nil = none yet (wiring sets them before `handle` is called).
    init(settings: SmartMomentsSettings, hooks: SmartMomentsHooks? = nil) {
        self.settings = settings
        self.hooks = hooks ?? SmartMomentsHooks()
    }

    /// The band shows a meeting offer (wiring suppresses MeetingAssistant's
    /// own `promptedCall` band meanwhile, DESIGN.md rule 11).
    var isShowingMeetingOffer: Bool {
        guard let offer = currentOffer else { return false }
        return MomentEngineRules.meetingMoments.contains(offer.moment)
    }

    /// True when a detector for `moment` is worth running (master switch and
    /// the moment are on). Sources use it to skip polling.
    func wants(_ moment: MomentID) -> Bool {
        settings.isEnabled && settings.settings(for: moment).isEnabled
    }

    /// The reversals the ledger holds for a moment (Settings and tests).
    func ownedReversals(for moment: MomentID) -> [MomentAction] {
        ledger.entries.filter { $0.moment == moment }.map(\.reversal)
    }

    func canUndo(_ offerID: UUID) -> Bool {
        guard let record = undoRecords[offerID] else { return false }
        return record.actions.contains { action in
            if let reversal = action.reversal, ledger.owns(reversal) { return true }
            return putBackEntries.contains { $0.offerID == offerID && $0.action == action }
        }
    }

    // MARK: - Triggers

    func handle(_ trigger: MomentTrigger) {
        pending.append(trigger)
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    /// Handles queued triggers one by one, so a call that starts and ends
    /// quickly is processed in order even while actions await.
    private func drain() async {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            await process(next)
        }
        isDraining = false
    }

    /// Applies one trigger. Internal so tests await it directly.
    func process(_ trigger: MomentTrigger) async {
        let now = hooks.now()
        let moment = trigger.moment

        // A moment in effect ends: put back what it changed, even when Smart
        // Moments was turned off meanwhile (nothing may stay hidden).
        if trigger.isEnd {
            await end(moment, trigger: trigger, now: now)
            return
        }

        switch trigger {
        case .meetingStarted:
            drop { $0.moment == .meetingSoon } // Join is moot now
        case .meetingEnded:
            drop { $0.moment == .meetingStarted } // unanswered, now stale
        case .screenSharingStarted:
            // Copied or captured content must not stay on a shared screen.
            drop { MomentEngineRules.contentMoments.contains($0.moment) }
        default:
            break
        }

        let momentSettings = settings.settings(for: moment)
        guard settings.isEnabled, momentSettings.isEnabled, !momentSettings.isSnoozed(at: now) else {
            note(moment, "skipped: \(settings.isEnabled ? (momentSettings.isEnabled ? "snoozed" : "moment off") : "Smart Moments off")")
            if moment == .meetingEnded { await silentlyPutBack(endingAt: .meetingEnded, now: now) }
            return
        }

        if let reason = quietReason(for: moment) {
            note(moment, "quiet: \(reason)")
            if moment == .meetingEnded { await silentlyPutBack(endingAt: .meetingEnded, now: now) }
            return
        }

        let bookKey = moment.rawValue + "|" + trigger.dedupeKey
        if isDuplicate(trigger, bookKey: bookKey, now: now) {
            note(moment, "duplicate, cooldown")
            return
        }
        handledAt[bookKey] = now
        pruneBook(now: now)

        // Calls end: things the start moment started (captions) stop on their
        // own; the reversal chips are offered below.
        if moment == .meetingEnded { await runPutBacks(where: { $0.moment.endMoment == .meetingEnded }, now: now, announce: false) }

        guard var offer = makeOffer(for: trigger, settings: momentSettings, now: now) else {
            note(moment, "nothing to offer")
            if moment == .meetingEnded { discardStartLedger(for: .meetingEnded) }
            return
        }

        if MomentEngineRules.meetingMoments.contains(moment), let bridge = meetingIntel, bridge.willPrompt(for: trigger) {
            if bridge.hostsContributedChips {
                await fold(offer, into: bridge, mode: momentSettings.mode, now: now)
                return
            }
            // MeetingIntel shows its own prompt for its actions but can't
            // host ours: our band keeps only the rest (no duplicate chips).
            offer.actions.removeAll { bridge.handledActions.contains($0) }
            offer.selected.formIntersection(offer.actions)
            offer.blocked = offer.blocked.filter { offer.actions.contains($0.key) }
            if offer.actions.isEmpty {
                note(moment, "MeetingIntel prompts; nothing else to offer")
                if moment == .meetingEnded { discardStartLedger(for: .meetingEnded) }
                return
            }
        }

        if effectiveMode(momentSettings.mode, for: trigger) == .automatic {
            offer = await autoRun(offer, now: now)
            let leftovers = offer.actions.filter { !offer.autoRan.contains($0) }
            if offer.autoRan.isEmpty && leftovers.isEmpty { return }
            if leftovers.isEmpty {
                offer = MomentOffer(
                    id: offer.id, trigger: offer.trigger, actions: offer.actions, selected: [],
                    blocked: offer.blocked, createdAt: offer.createdAt,
                    expiresAt: now.addingTimeInterval(MomentEngineRules.autoDoneDuration),
                    autoRan: offer.autoRan, suggestsTurningOff: false
                )
                if moment == .meetingEnded { discardStartLedger(for: .meetingEnded) }
            }
        }
        present(offer, now: now)
    }

    private func quietReason(for moment: MomentID) -> String? {
        if moment == .lowBatteryRecording { return nil } // ignores quiet conditions
        if hooks.isScreenSharing() && !moment.allowedWhileScreenSharing { return "screen sharing" }
        if hooks.isSparkVCapturing() && moment != .meetingEnded { return "SparkV capture window open" }
        if hooks.isOnCall() && MomentEngineRules.quietDuringCalls.contains(moment) { return "on a call" }
        return nil
    }

    private func isDuplicate(_ trigger: MomentTrigger, bookKey: String, now: Date) -> Bool {
        let key = trigger.dedupeKey
        let moment = trigger.moment
        // Already in the band, the queue or MeetingIntel's prompt.
        let showing = allOffers.contains { $0.moment == moment && $0.trigger.dedupeKey == key }
        if showing { return true }
        if moment == .lowBatteryRecording { return false } // ignores cooldowns
        guard let last = handledAt[bookKey] else { return false }
        let cooldown = moment.defaultCooldown
        let window = cooldown > 0 ? cooldown : MomentEngineRules.onceMemory
        return now.timeIntervalSince(last) < window
    }

    private func pruneBook(now: Date) {
        guard handledAt.count > 400 else { return }
        let horizon = max(MomentEngineRules.onceMemory, 24 * 3600)
        handledAt = handledAt.filter { now.timeIntervalSince($0.value) < horizon }
    }

    /// Generic fullscreen asks first even in auto mode (videos and games go
    /// fullscreen too); Keynote/PowerPoint play mode follows the setting.
    private func effectiveMode(_ mode: MomentMode, for trigger: MomentTrigger) -> MomentMode {
        if case .presentationStarted(_, _, let isSlideshow) = trigger, !isSlideshow { return .ask }
        return mode
    }

    // MARK: - Building an offer

    private func makeOffer(for trigger: MomentTrigger, settings momentSettings: MomentSettings, now: Date) -> MomentOffer? {
        let moment = trigger.moment
        let bridgeActions = meetingIntel?.handledActions ?? []
        var actions = momentSettings.enabledActions(for: moment).filter { action in
            (MomentEngineRules.meetingMoments.contains(moment) && bridgeActions.contains(action))
                || hooks.supports(action, for: trigger)
        }
        if moment == .meetingEnded {
            // Reversal chips only for what the start moment actually changed.
            let owned = Set(ledger.entries.filter { $0.moment.endMoment == .meetingEnded }.map(\.reversal))
            actions = actions.filter { !isReversalAction($0) || owned.contains($0) }
        }
        guard !actions.isEmpty else { return nil }

        var blocked: [MomentAction: PermissionCenter.Permission] = [:]
        for action in actions {
            if let missing = action.requiredPermissions.first(where: { !hooks.permissionGranted($0) }) {
                blocked[action] = missing
            }
        }
        return MomentOffer(
            id: UUID(),
            trigger: trigger,
            actions: actions,
            selected: Set(actions).subtracting(blocked.keys),
            blocked: blocked,
            createdAt: now,
            expiresAt: moment.expiresAfter.map { now.addingTimeInterval($0) },
            autoRan: [],
            suggestsTurningOff: momentSettings.dismissStreak >= MomentEngineRules.dismissStreakLimit
        )
    }

    /// resumeMusic, doNotDisturbOff, showNotificationPreviews, showClipboardBand.
    private func isReversalAction(_ action: MomentAction) -> Bool {
        MomentAction.allCases.contains { $0.reversal == action }
    }

    private func autoEligible(_ action: MomentAction, in offer: MomentOffer) -> Bool {
        action.isAutoEligible
            && (hooks.autoEligible[action]?(offer.trigger) ?? true)
            && offer.blocked[action] == nil
            && offer.selected.contains(action)
    }

    // MARK: - Auto mode

    private func autoRun(_ offer: MomentOffer, now: Date) async -> MomentOffer {
        var offer = offer
        let auto = offer.actions.filter { autoEligible($0, in: offer) }
        guard !auto.isEmpty else { return offer }
        let results = await perform(auto, offer: offer, userInitiated: false)
        let ran = results.filter { $0.result.changedState }.map(\.action)
        let attempted = Set(auto)
        // Skipped (nothing to do) and failed actions leave the band too: auto
        // mode never turns them into questions.
        let needsPermission = Set(results.compactMap { item -> MomentAction? in
            if case .needsPermission = item.result { return item.action }
            return nil
        })
        offer.actions = offer.actions.filter { !attempted.contains($0) || ran.contains($0) || needsPermission.contains($0) }
        offer.selected.subtract(attempted)
        offer.autoRan = ran
        absorbPermissionResults(results, into: &offer)
        if !ran.isEmpty {
            undoRecords[offer.id] = UndoRecord(moment: offer.moment, trigger: offer.trigger, actions: ran)
            note(offer.moment, "auto ran: " + ran.map(\.rawValue).joined(separator: ", "))
        }
        return offer
    }

    // MARK: - MeetingIntel (rule 11)

    private func fold(_ offer: MomentOffer, into bridge: any MeetingIntelBridge, mode: MomentMode, now: Date) async {
        var mine = offer
        mine.actions = offer.actions.filter { !bridge.handledActions.contains($0) }
        mine.selected = offer.selected.intersection(mine.actions)
        if mode == .automatic {
            mine = await autoRun(mine, now: now)
            if !mine.autoRan.isEmpty {
                onDone?(mine.moment, doneText(mine.autoRan.map { ($0, MomentActionResult.done(nil)) }))
            }
        }
        let leftovers = mine.actions.filter { !mine.autoRan.contains($0) }
        note(offer.moment, "folded into MeetingIntel (\(leftovers.count) chips)")
        guard !leftovers.isEmpty else {
            if offer.moment == .meetingEnded { discardStartLedger(for: .meetingEnded) }
            return
        }
        mine.actions = leftovers
        mine.selected = mine.selected.intersection(leftovers)
        mine.autoRan = []
        detached[mine.id] = mine
        let offerID = mine.id
        bridge.contribute(leftovers, for: offer.trigger) { [weak self] action in
            Task { _ = await self?.run(action, offerID: offerID) }
        }
        scheduleExpiry()
    }

    // MARK: - The band and its queue (rule 1)

    private var allOffers: [MomentOffer] {
        (currentOffer.map { [$0] } ?? []) + queue + Array(detached.values)
    }

    private func isDoneToast(_ offer: MomentOffer) -> Bool {
        !offer.autoRan.isEmpty && offer.actions.allSatisfy { offer.autoRan.contains($0) }
    }

    private func present(_ offer: MomentOffer, now: Date) {
        guard let current = currentOffer else {
            currentOffer = offer
            note(offer.moment, "offered")
            scheduleExpiry()
            return
        }
        if offer.moment.priority >= current.moment.priority {
            if !isDoneToast(current) { enqueue(current) }
            currentOffer = offer
            note(offer.moment, "offered, replaced \(current.moment.rawValue)")
        } else {
            enqueue(offer)
            note(offer.moment, "queued behind \(current.moment.rawValue)")
        }
        scheduleExpiry()
    }

    private func enqueue(_ offer: MomentOffer) {
        queue.removeAll { $0.id == offer.id }
        queue.append(offer)
        queue.sort { a, b in
            a.moment.priority != b.moment.priority ? a.moment.priority > b.moment.priority : a.createdAt > b.createdAt
        }
        while queue.count > MomentEngineRules.queueLimit {
            let dropped = queue.removeLast()
            note(dropped.moment, "dropped from the queue")
        }
    }

    /// Shows the next offer still worth showing.
    private func advance(now: Date) {
        queue.removeAll { offer in
            guard let expiry = offer.expiresAt, expiry <= now else { return false }
            note(offer.moment, "expired in the queue")
            return true
        }
        currentOffer = queue.isEmpty ? nil : queue.removeFirst()
        scheduleExpiry()
    }

    private func find(_ id: UUID) -> MomentOffer? {
        if currentOffer?.id == id { return currentOffer }
        return queue.first { $0.id == id } ?? detached[id]
    }

    private func replace(_ offer: MomentOffer) {
        if currentOffer?.id == offer.id {
            currentOffer = offer
        } else if let index = queue.firstIndex(where: { $0.id == offer.id }) {
            queue[index] = offer
        } else if detached[offer.id] != nil {
            detached[offer.id] = offer
        }
    }

    private func remove(_ id: UUID, now: Date) {
        // Undo lives on the band: once it is gone, so is its record. Put-backs
        // of moments that don't stay in effect go with it (a sorted download
        // must never move back later on its own).
        undoRecords[id] = nil
        putBackEntries.removeAll { $0.offerID == id && !MomentEngineRules.lastingMoments.contains($0.moment) }
        detached[id] = nil
        queue.removeAll { $0.id == id }
        if currentOffer?.id == id { advance(now: now) } else { scheduleExpiry() }
    }

    private func drop(where shouldDrop: (MomentOffer) -> Bool) {
        let now = hooks.now()
        for offer in allOffers where shouldDrop(offer) {
            note(offer.moment, "withdrawn")
            remove(offer.id, now: now)
        }
    }

    // MARK: - Expiry

    /// Expires offers past their time. The timer calls it; tests call it.
    func tick() {
        let now = hooks.now()
        for (id, offer) in detached {
            if let expiry = offer.expiresAt, expiry <= now {
                detached[id] = nil
                closedWithoutAnswer(offer)
            }
        }
        queue.removeAll { offer in
            guard let expiry = offer.expiresAt, expiry <= now else { return false }
            closedWithoutAnswer(offer)
            return true
        }
        if let current = currentOffer, let expiry = current.expiresAt, expiry <= now {
            closedWithoutAnswer(current)
            advance(now: now)
        } else {
            scheduleExpiry()
        }
    }

    private func closedWithoutAnswer(_ offer: MomentOffer) {
        note(offer.moment, "expired")
        // An unanswered "Call ended" leaves things as they are; the ledger
        // forgets them so a later call can't put them back by surprise.
        discardStartLedger(for: offer.moment)
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard schedulesTimers else { return }
        let next = allOffers.compactMap(\.expiresAt).min()
        guard let next else { return }
        let delay = max(0.05, next.timeIntervalSince(hooks.now()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    // MARK: - User answers

    func accept(_ offerID: UUID, actions chosen: Set<MomentAction>?) async {
        guard let offer = find(offerID), !accepting.contains(offerID) else { return }
        accepting.insert(offerID)
        defer { accepting.remove(offerID) }
        let wanted = chosen ?? offer.selected
        let toRun = offer.actions.filter { wanted.contains($0) && offer.blocked[$0] == nil && !offer.autoRan.contains($0) }
        let results = await perform(toRun, offer: offer, userInitiated: true)
        let ran = results.filter { $0.result.changedState }.map(\.action)
        if !ran.isEmpty {
            let earlier = undoRecords[offerID]?.actions ?? []
            undoRecords[offerID] = UndoRecord(moment: offer.moment, trigger: offer.trigger, actions: earlier + ran)
        }
        settings.update(offer.moment) { $0.dismissStreak = 0 }
        note(offer.moment, "accepted: " + toRun.map(\.rawValue).joined(separator: ", "))
        discardStartLedger(for: offer.moment)
        remove(offerID, now: hooks.now())
        if !results.isEmpty { onDone?(offer.moment, doneText(results)) }
    }

    func run(_ action: MomentAction, offerID: UUID) async -> MomentActionResult {
        guard var offer = find(offerID), offer.actions.contains(action), !offer.autoRan.contains(action) else {
            return .skipped("This moment has passed")
        }
        if let permission = offer.blocked[action] { return .needsPermission(permission) }
        let results = await perform([action], offer: offer, userInitiated: true)
        let result = results.first?.result ?? .skipped("Not available")
        // The offer may have changed while the action ran.
        offer = find(offerID) ?? offer
        if result.changedState {
            let earlier = undoRecords[offerID]?.actions ?? []
            undoRecords[offerID] = UndoRecord(moment: offer.moment, trigger: offer.trigger, actions: earlier + [action])
        }
        if case .needsPermission(let permission) = result {
            offer.blocked[action] = permission
            offer.selected.remove(action)
            replace(offer)
            return result
        }
        offer.actions.removeAll { $0 == action }
        offer.selected.remove(action)
        settings.update(offer.moment) { $0.dismissStreak = 0 }
        note(offer.moment, "ran \(action.rawValue)")
        if offer.actions.allSatisfy({ offer.autoRan.contains($0) }) {
            discardStartLedger(for: offer.moment)
            if offer.autoRan.isEmpty || detached[offerID] != nil {
                remove(offerID, now: hooks.now())
            } else {
                replace(offer)
            }
        } else {
            replace(offer)
        }
        onDone?(offer.moment, doneText(results))
        return result
    }

    func toggleSelection(_ action: MomentAction, offerID: UUID) {
        guard var offer = find(offerID), offer.actions.contains(action), offer.blocked[action] == nil else { return }
        if offer.selected.contains(action) { offer.selected.remove(action) } else { offer.selected.insert(action) }
        replace(offer)
    }

    func dismiss(_ offerID: UUID) {
        guard let offer = find(offerID) else { return }
        if offer.autoRan.isEmpty {
            settings.update(offer.moment) { $0.dismissStreak += 1 }
        }
        note(offer.moment, "dismissed")
        discardStartLedger(for: offer.moment)
        remove(offerID, now: hooks.now())
    }

    func snooze(_ offerID: UUID) {
        guard let offer = find(offerID) else { return }
        let now = hooks.now()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(12 * 3600)
        settings.snooze(offer.moment, until: tomorrow)
        settings.update(offer.moment) { $0.dismissStreak = 0 }
        note(offer.moment, "snoozed until tomorrow")
        discardStartLedger(for: offer.moment)
        remove(offerID, now: now)
    }

    func undo(_ offerID: UUID) async {
        let offer = find(offerID)
        guard let record = undoRecords.removeValue(forKey: offerID) else {
            if offer != nil { remove(offerID, now: hooks.now()) }
            return
        }
        var undone: [(action: MomentAction, result: MomentActionResult)] = []
        for action in record.actions.reversed() {
            if let reversal = action.reversal, ledger.owns(reversal) {
                ledger.forget(reversal)
                let result = await execute(reversal, trigger: record.trigger, offerID: offerID, userInitiated: true)
                undone.append((action, result))
            } else if let index = putBackEntries.firstIndex(where: { $0.offerID == offerID && $0.action == action }),
                      let handler = putBack[action] {
                putBackEntries.remove(at: index)
                let context = MomentActionContext(trigger: record.trigger, offerID: offerID, userInitiated: true)
                undone.append((action, await handler(context)))
            }
        }
        note(record.moment, "undo: " + undone.map(\.action.rawValue).joined(separator: ", "))
        if offer != nil { remove(offerID, now: hooks.now()) }
        if !undone.isEmpty {
            let names = undone.filter { $0.result.changedState }.map(\.action.title)
            if !names.isEmpty { onDone?(record.moment, "Undone: " + names.joined(separator: ", ")) }
        }
    }

    func requestPermission(for action: MomentAction, offerID: UUID) {
        guard let offer = find(offerID), let permission = offer.blocked[action] else { return }
        note(offer.moment, "asks for \(permission) for \(action.rawValue)")
        Task {
            let granted = await requestPermissionHandler(permission, MomentEngineRules.feature)
            guard granted, var latest = find(offerID) else { return }
            // Another permission may still be missing.
            if let next = action.requiredPermissions.first(where: { !hooks.permissionGranted($0) && $0 != permission }) {
                latest.blocked[action] = next
            } else {
                latest.blocked[action] = nil
                latest.selected.insert(action)
            }
            replace(latest)
        }
    }

    func userChanged(_ reversal: MomentAction) {
        guard ledger.owns(reversal) else { return }
        ledger.forget(reversal)
        note(nil, "user changed \(reversal.rawValue) by hand; not put back")
    }

    /// Forgets everything (Settings › Reset, or Smart Moments turned off).
    /// Puts back what the engine changed first.
    func reset() async {
        let now = hooks.now()
        for moment in MomentID.allCases { await end(moment, now: now, announce: false) }
        currentOffer = nil
        queue = []
        detached = [:]
        undoRecords = [:]
        handledAt = [:]
        scheduleExpiry()
    }

    /// Something the engine changed is still in effect (Do Not Disturb for a
    /// call, hidden previews while sharing, presentation mode).
    var hasSomethingToPutBack: Bool {
        !ledger.entries.isEmpty || putBackEntries.contains { MomentEngineRules.lastingMoments.contains($0.moment) }
    }

    /// Quitting: puts back what the moments in effect changed, quietly, so
    /// nothing stays hidden or silenced after SparkV is gone. Unlike
    /// `reset()` it keeps cooldowns and settings, and never touches files.
    func prepareForQuit() async {
        let now = hooks.now()
        for moment in MomentID.allCases where MomentEngineRules.lastingMoments.contains(moment) {
            await end(moment, now: now, announce: false)
        }
        // Reversals owned by any other moment (none today) go back too.
        for moment in MomentID.allCases where !ledger.entries.filter({ $0.moment == moment }).isEmpty {
            await end(moment, now: now, announce: false)
        }
    }

    // MARK: - Ending a moment (rule 5)

    private func end(_ moment: MomentID, trigger: MomentTrigger? = nil, now: Date, announce: Bool = true) async {
        drop { $0.moment == moment }
        // A share or a talk that starts again soon is protected again: the
        // cooldown only keeps a flapping detector from re-asking.
        let prefix = moment.rawValue + "|"
        handledAt = handledAt.filter { !$0.key.hasPrefix(prefix) }
        let reversals = ledger.takeReversals(for: moment)
        var results: [(action: MomentAction, result: MomentActionResult)] = []
        for reversal in reversals {
            results.append((reversal, await execute(reversal, trigger: trigger, offerID: nil, userInitiated: false)))
        }
        await runPutBacks(where: { $0.moment == moment }, now: now, announce: false, collect: &results)
        guard !results.isEmpty else { return }
        note(moment, "put back: " + results.map(\.action.rawValue).joined(separator: ", "))
        let done = results.filter { $0.result.changedState }.map(\.action.title)
        if announce, !done.isEmpty { onDone?(moment, "Put back: " + done.joined(separator: ", ")) }
    }

    /// "Meeting ended" is off, snoozed or quiet: put back what "Meeting
    /// started" changed without a band (leaving DND on after a call is worse).
    private func silentlyPutBack(endingAt endMoment: MomentID, now: Date) async {
        for start in MomentID.allCases where start.endMoment == endMoment {
            await end(start, now: now, announce: true)
        }
    }

    private func runPutBacks(where matches: (PutBackEntry) -> Bool, now: Date, announce: Bool) async {
        var ignored: [(action: MomentAction, result: MomentActionResult)] = []
        await runPutBacks(where: matches, now: now, announce: announce, collect: &ignored)
    }

    private func runPutBacks(
        where matches: (PutBackEntry) -> Bool, now: Date, announce: Bool,
        collect results: inout [(action: MomentAction, result: MomentActionResult)]
    ) async {
        let due = putBackEntries.filter(matches)
        guard !due.isEmpty else { return }
        putBackEntries.removeAll(where: matches)
        for entry in due.reversed() {
            guard let handler = putBack[entry.action] else { continue }
            let context = MomentActionContext(trigger: entry.trigger, offerID: entry.offerID, userInitiated: false)
            results.append((entry.action, await handler(context)))
        }
    }

    /// The start moment's ledger entries once its end moment was answered.
    private func discardStartLedger(for endMoment: MomentID) {
        for start in MomentID.allCases where start.endMoment == endMoment {
            let dropped = ledger.takeReversals(for: start)
            if !dropped.isEmpty { note(start, "left as is: " + dropped.map(\.rawValue).joined(separator: ", ")) }
        }
    }

    // MARK: - Running actions

    private func perform(
        _ actions: [MomentAction], offer: MomentOffer, userInitiated: Bool
    ) async -> [(action: MomentAction, result: MomentActionResult)] {
        var results: [(action: MomentAction, result: MomentActionResult)] = []
        for action in actions {
            // Rule 3, belt and braces: consent actions only ever follow a tap.
            if !userInitiated && (action.needsConsent || action.alwaysAsks) {
                results.append((action, .skipped("Needs a tap")))
                continue
            }
            let result = await execute(action, trigger: offer.trigger, offerID: offer.id, userInitiated: userInitiated)
            if result.changedState {
                if ledger.owns(action) { ledger.forget(action) } // a reversal ran: nothing left to put back
                ledger.record(action, moment: offer.moment, key: offer.trigger.dedupeKey, at: hooks.now())
                if putBack[action] != nil {
                    putBackEntries.append(PutBackEntry(moment: offer.moment, offerID: offer.id, trigger: offer.trigger, action: action))
                }
            }
            results.append((action, result))
        }
        return results
    }

    /// One action through MeetingIntel or its hook, after a permission check
    /// (never a prompt: requests only follow a tap, `requestPermission`).
    private func execute(_ action: MomentAction, trigger: MomentTrigger?, offerID: UUID?, userInitiated: Bool) async -> MomentActionResult {
        if let missing = action.requiredPermissions.first(where: { !hooks.permissionGranted($0) }) {
            return .needsPermission(missing)
        }
        let context = MomentActionContext(
            trigger: trigger ?? .screenSharingEnded, offerID: offerID ?? UUID(), userInitiated: userInitiated
        )
        let result: MomentActionResult
        if let trigger, MomentEngineRules.meetingMoments.contains(trigger.moment),
           let bridge = meetingIntel, bridge.handledActions.contains(action) {
            result = await bridge.perform(action, context: context)
        } else if let hook = hooks.actions[action] {
            result = await hook(context)
        } else {
            result = .skipped("Not available")
        }
        if case .failed(let why) = result { note(trigger?.moment, "\(action.rawValue) failed: \(why)") }
        return result
    }

    private func absorbPermissionResults(_ results: [(action: MomentAction, result: MomentActionResult)], into offer: inout MomentOffer) {
        for (action, result) in results {
            if case .needsPermission(let permission) = result {
                offer.blocked[action] = permission
                offer.selected.remove(action)
            }
        }
    }

    /// "Done: Paused music, Do Not Disturb · Couldn't: Join".
    func doneText(_ results: [(action: MomentAction, result: MomentActionResult)]) -> String {
        var done: [String] = []
        var failed: [String] = []
        var needs: [String] = []
        for (action, result) in results {
            switch result {
            case .done(let text): done.append(text ?? action.title)
            case .skipped: break
            case .needsPermission(let permission): needs.append("\(action.title) needs \(permission) access")
            case .failed: failed.append(action.title)
            }
        }
        var parts: [String] = []
        if !done.isEmpty { parts.append("Done: " + done.joined(separator: ", ")) }
        if !failed.isEmpty { parts.append("Couldn't: " + failed.joined(separator: ", ")) }
        parts.append(contentsOf: needs)
        return parts.isEmpty ? "Nothing to change" : parts.joined(separator: " · ")
    }

    // MARK: - Log

    private func note(_ moment: MomentID?, _ message: String) {
        let entry = SmartMomentsLogEntry(id: UUID(), at: hooks.now(), moment: moment, message: message)
        log.append(entry)
        if log.count > MomentEngineRules.logLimit { log.removeFirst(log.count - MomentEngineRules.logLimit) }
        if writesAppLog { AppLog.log("SmartMoments: \(moment?.rawValue ?? "-") \(message)") }
    }
}
