import AppKit
import Combine
import SwiftUI

// MARK: - Inputs from the rest of the app

/// What the controller reads from the other features, as closures so the
/// harness can feed fixtures. `live(...)` wires the real stores.
struct FocusSources {
    /// Everything SparkV currently holds that could have been made during a
    /// session (the controller keeps only what's new since the start).
    var artifacts: @MainActor () -> [FocusArtifact]
    /// SparkV's notification previews (NotificationMonitor.isEnabled); nil
    /// getter result = no monitor.
    var previewsEnabled: @MainActor () -> Bool?
    var setPreviewsEnabled: @MainActor (Bool) -> Void

    static let none = FocusSources(artifacts: { [] }, previewsEnabled: { nil }, setPreviewsEnabled: { _ in })

    @MainActor
    static func live(
        tray: TrayStore,
        meetingAssistant: MeetingAssistant,
        notifications: NotificationMonitor,
        flow: FlowStore? = nil,
        spaces: SpaceStore? = nil
    ) -> FocusSources {
        let flow = flow ?? .shared
        let spaces = spaces ?? .shared
        return FocusSources(
            artifacts: { [weak tray, weak meetingAssistant, weak flow, weak spaces] in
                var out: [FocusArtifact] = []
                for e in flow?.history ?? [] {
                    out.append(FocusArtifact(id: "flow:\(e.id)", kind: .dictation, title: e.text, date: e.date))
                }
                for n in flow?.notes ?? [] {
                    out.append(FocusArtifact(id: "note:\(n.id)", kind: .note, title: n.text, date: n.date))
                }
                for t in tray?.items ?? [] {
                    out.append(FocusArtifact(id: "tray:\(t.id)", kind: .tray, title: t.displayName, date: t.addedAt))
                }
                for m in meetingAssistant?.library ?? [] {
                    out.append(FocusArtifact(id: "meeting:\(m.id)", kind: .meeting,
                                             title: m.title, date: m.endedAt ?? m.startedAt))
                }
                for s in spaces?.items ?? [] {
                    out.append(FocusArtifact(id: "space:\(s.id)", kind: .spaceItem, title: s.title, date: s.createdAt))
                }
                return out
            },
            previewsEnabled: { [weak notifications] in notifications?.isEnabled },
            setPreviewsEnabled: { [weak notifications] in notifications?.isEnabled = $0 }
        )
    }
}

// MARK: - Controller

/// Focus mode: one tap mutes notifications (Do Not Disturb through the
/// user's Shortcuts plus SparkV's own previews), runs Pomodoro-style
/// focus/break rounds on `TimerController`, shows a "Focusing" band with the
/// time left, watches for distractions, and ends with a recap of the apps,
/// documents and SparkV items of the session.
@MainActor
final class FocusController: ObservableObject {
    static let activityID = "focus"
    static let doneActivityID = "focus.done"
    static let summaryActivityID = "focus.summary"
    /// Just above the running timer's band (20), below HUDs and notifications.
    static let activityPriority = 21

    @Published var settings: FocusSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            applySettingsToGuards()
        }
    }
    @Published private(set) var active: FocusActiveSession?
    @Published private(set) var now = Date()
    /// The last finished session, for the summary card.
    @Published private(set) var lastSummary: FocusSessionRecord?
    @Published private(set) var isSummarizing = false
    /// Shown in the drawer/summary when Do Not Disturb couldn't be set.
    @Published private(set) var doNotDisturbNotice: String?

    let store: FocusStore
    let doNotDisturb: FocusDoNotDisturb

    /// Where hovering the band leads (the lead may point it at a Focus tab).
    var bandOpensTab: NotchState.Tab? = .today
    /// Opens the summary card when a session ends (off in tests).
    var presentsSummaryWindow = true
    /// Shows the distraction overlay (off in tests).
    var presentsOverlay = true
    /// Shows the glowing screen border (off in tests).
    var presentsEdgeGlow = true
    /// Called after a session is saved (and again when its model summary lands).
    var onSessionEnded: ((FocusSessionRecord) -> Void)?

    private let activities: ActivityCenter
    private weak var timer: TimerController?
    private let sources: FocusSources
    private let defaults: UserDefaults
    private let tracker = FocusActivityTracker()
    private let distractionGuard = FocusDistractionGuard()
    private let overlay = FocusOverlayController()
    private lazy var edgeGlow = FocusEdgeGlowController()
    /// When the band last got its kick (start of a session).
    private var bandKickAt: Date?

    private var ticker: Task<Void, Never>?
    private var timerObserver: AnyCancellable?
    private var baseline: Set<String> = []
    private var isStarted = false
    private var tickCount = 0
    /// The TimerController countdown currently mirrors this phase.
    private var mirroring = false
    private var mirroredDuration: TimeInterval = 0
    private var completionSound: NSSound?

    private enum Keys {
        static let settings = "focus.settings"
    }

    /// A finished phase this long ago (sleep, relaunch) advances quietly.
    static let staleBoundary: TimeInterval = 60
    /// Our tick waits this long past a phase end so TimerController chimes first.
    static let endGrace: TimeInterval = 0.5

    init(
        activities: ActivityCenter,
        timer: TimerController?,
        sources: FocusSources = .none,
        store: FocusStore? = nil,
        doNotDisturb: FocusDoNotDisturb? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.activities = activities
        self.timer = timer
        self.sources = sources
        self.store = store ?? FocusStore()
        self.doNotDisturb = doNotDisturb ?? FocusDoNotDisturb()
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.settings),
           let saved = try? JSONDecoder().decode(FocusSettings.self, from: data) {
            settings = saved.sanitized
        } else {
            settings = FocusSettings()
        }
        lastSummary = self.store.sessions.first
        tracker.onFrontmostChange = { [weak self] app in self?.frontmostChanged(app) }
        distractionGuard.onHit = { [weak self] hit in self?.distractionHit(hit) }
        applySettingsToGuards()
    }

    // MARK: Lifecycle

    /// Picks a session running before the relaunch back up (or wraps it up
    /// when it ended while SparkV was closed).
    func start() {
        guard !isStarted else { return }
        isStarted = true
        timerObserver = timer?.$state.sink { [weak self] _ in
            // @Published fires before the new value is stored.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.timerChanged() } }
        }
        guard let saved = store.loadActive() else { return }
        AppLog.log("Focus: restoring a session from before relaunch")
        active = saved
        baseline = Set(sources.artifacts().map(\.id))
        mirroring = timerMatchesPhase()
        if mirroring { mirroredDuration = saved.schedule.phaseDuration }
        tracker.tracksWindowTitles = settings.tracksWindowTitles
        tracker.begin(with: saved.usage)
        if saved.schedule.phase == .focus && !saved.schedule.isPaused {
            if settings.blocksDistractions { distractionGuard.activate() }
        } else {
            tracker.suspend()
        }
        tick()
        restartTicker()
        refreshEdgeGlow()
    }

    /// App teardown: the session stays saved and resumes on the next launch.
    func stop() {
        isStarted = false
        persistActive()
        ticker?.cancel()
        ticker = nil
        timerObserver = nil
        overlay.hide()
        distractionGuard.deactivate()
        if presentsEdgeGlow { edgeGlow.hideNow() }
        // The snapshot is saved above; drop the workspace observer and title poll.
        _ = tracker.finish()
    }

    // MARK: Controls

    var isActive: Bool { active != nil }
    var isPaused: Bool { active?.schedule.isPaused == true }
    var phase: FocusSchedule.Phase? { active?.schedule.phase }

    /// Starts a session, or ends the running one.
    func toggle() {
        if isActive { end() } else { startSession() }
    }

    func startSession(using override: FocusSettings? = nil) {
        guard active == nil else { return }
        if let override { settings = override.sanitized }
        let s = settings.sanitized
        let date = Date()
        var session = FocusActiveSession(
            id: UUID(), startedAt: date,
            schedule: FocusSchedule(plan: .init(settings: s), start: date),
            plannedFocusMinutes: s.focusMinutes * max(1, s.rounds),
            didEnableDoNotDisturb: false, previewsWereEnabled: nil,
            usage: FocusUsageSnapshot(), artifacts: [], interruptions: []
        )
        baseline = Set(sources.artifacts().map(\.id))
        if let enabled = sources.previewsEnabled() {
            session.previewsWereEnabled = enabled
            if enabled { sources.setPreviewsEnabled(false) }
        }
        active = session
        doNotDisturbNotice = nil
        lastSummary = nil
        AppLog.log("Focus: started \(s.focusMinutes)/\(s.shortBreakMinutes) min, rounds \(s.rounds)")

        tracker.tracksWindowTitles = s.tracksWindowTitles
        tracker.begin()
        if s.blocksDistractions { distractionGuard.resetSnoozes(); distractionGuard.activate() }
        mirrorPhase()
        bandKickAt = date
        tick()
        restartTicker()
        persistActive()
        playEdgeGlow(.focus)
        if s.usesDoNotDisturb { enableDoNotDisturb(sessionID: session.id) }
    }

    /// Ends the session now and shows the summary.
    func end() {
        guard let active else { return }
        let reason: FocusSessionRecord.EndReason = active.schedule.isLastRound
            && active.schedule.phase == .focus && active.schedule.remaining(at: Date()) < 1 ? .completed : .stopped
        finish(reason: reason, at: Date(), effects: true)
    }

    func pause() {
        guard var a = active, !a.schedule.isPaused else { return }
        a.schedule.pause(at: Date())
        active = a
        if mirroring, timer?.state.isRunning == true { timer?.toggle() }
        tracker.suspend()
        distractionGuard.deactivate()
        overlay.hide()
        afterChange()
        refreshEdgeGlow()
    }

    func resume() {
        guard var a = active, a.schedule.isPaused else { return }
        a.schedule.resume(at: Date())
        active = a
        if mirroring, timer?.state.isPaused == true { timer?.toggle() }
        if a.schedule.phase == .focus {
            tracker.resume()
            if settings.blocksDistractions { distractionGuard.activate() }
        }
        afterChange()
        refreshEdgeGlow()
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// Ends the current phase now (a break early, or the focus round).
    func skipPhase() {
        guard active != nil else { return }
        // No chime or "round done" band, but the border still marks the switch.
        phaseEnded(at: Date(), celebrate: false, effects: true)
    }

    func addFiveMinutes() {
        guard var a = active else { return }
        a.schedule.extend(by: 300)
        active = a
        if mirroring {
            for _ in 0..<5 { timer?.addMinute() }
            mirroredDuration += 300
        }
        afterChange()
    }

    /// From the summary card: a plain break countdown on the timer.
    func startBreak() {
        timer?.startTimer(minutes: settings.sanitized.shortBreakMinutes)
    }

    func dismissSummary() {
        activities.dismiss(id: Self.summaryActivityID)
        FocusSummaryWindowController.shared.close()
    }

    func stats() -> FocusStats { store.stats(now: now) }

    // MARK: Read-outs

    var remaining: TimeInterval { active?.schedule.remaining(at: now) ?? 0 }
    var progress: Double { active?.schedule.progress(at: now) ?? 0 }
    var remainingText: String { FocusText.clock(remaining) }
    var focusedSoFar: TimeInterval { active?.schedule.focusedTime(at: now) ?? 0 }

    /// "1/2" when the session has more than one round, "#3" open-ended.
    var roundText: String? {
        guard let a = active else { return nil }
        if a.schedule.plan.rounds == 1 { return nil }
        if a.schedule.plan.rounds == 0 { return "#\(a.schedule.round)" }
        return "\(a.schedule.round)/\(a.schedule.plan.rounds)"
    }

    var phaseTitle: String {
        switch active?.schedule.phase {
        case .focus?: "Focusing"
        case .shortBreak?: "Break"
        case .longBreak?: "Long break"
        case nil: "Focus"
        }
    }

    // MARK: Ticking

    private func restartTicker() {
        ticker?.cancel()
        ticker = nil
        guard active != nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active != nil else { return }
                let delay = self.tick()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Advances finished phases, refreshes the band, samples artifacts.
    /// Returns how long to wait for the next visible change.
    @discardableResult
    private func tick() -> TimeInterval {
        let date = Date()
        now = date
        // Catch up on every phase that ended (sleep, relaunch).
        var guardCount = 0
        while let a = active, let endsAt = a.schedule.endsAt, date >= endsAt.addingTimeInterval(Self.endGrace), guardCount < 100 {
            guardCount += 1
            let fresh = date.timeIntervalSince(endsAt) < Self.staleBoundary
            phaseEnded(at: endsAt, celebrate: fresh, effects: fresh)
        }
        guard let a = active else { return 1 }
        tickCount &+= 1
        if tickCount % 5 == 0 { sampleArtifacts() }
        if tickCount % 15 == 0 { persistActive() }
        updateBand()
        if a.schedule.isPaused { return 1 }
        let left = a.schedule.remaining(at: date)
        if left <= 0 { return Self.endGrace + 0.05 }
        let fraction = left - left.rounded(.down)
        return min(1, (fraction == 0 ? 1 : fraction) + 0.01)
    }

    private func phaseEnded(at boundary: Date, celebrate: Bool, effects: Bool? = nil) {
        let effects = effects ?? celebrate
        guard var a = active else { return }
        let finished = a.schedule.phase
        // TimerController chimes for the phases it was counting.
        let timerChimed = mirroring && timer?.isEnabled == true
        let more = a.schedule.advance(at: boundary)
        active = a
        guard more else {
            finish(reason: .completed, at: boundary, effects: effects)
            return
        }
        let next = a.schedule.phase
        AppLog.log("Focus: \(finished.rawValue) done, \(next.rawValue) next")
        if next == .focus {
            tracker.resume()
            if settings.blocksDistractions { distractionGuard.activate() }
        } else {
            tracker.suspend()
            distractionGuard.deactivate()
            overlay.hide()
        }
        mirrorPhase()
        if celebrate {
            if !timerChimed { playChime() }
            postCelebration(finished: finished, next: next, schedule: a.schedule)
        }
        afterChange()
        if effects {
            playEdgeGlow(next == .focus ? .focus : .relax)
        } else {
            refreshEdgeGlow()
        }
    }

    private func afterChange() {
        now = Date()
        updateBand()
        persistActive()
        restartTicker()
    }

    // MARK: Ending

    private func finish(reason: FocusSessionRecord.EndReason, at endDate: Date, effects: Bool = false) {
        guard var a = active else { return }
        sampleArtifacts()
        a = active ?? a
        let usage = tracker.finish()
        distractionGuard.deactivate()
        overlay.hide()
        ticker?.cancel()
        ticker = nil

        // Undo the muting.
        if a.didEnableDoNotDisturb { disableDoNotDisturb() }
        if a.previewsWereEnabled == true { sources.setPreviewsEnabled(true) }
        if mirroring, reason != .completed, timer?.state.isIdle == false { timer?.reset() }
        mirroring = false

        let focused = a.schedule.focusedTime(at: endDate)
        let completedRounds = a.schedule.phase == .focus
            ? (reason == .completed ? a.schedule.round : a.schedule.round - 1)
            : a.schedule.round
        var record = FocusSessionRecord(
            id: a.id, startedAt: a.startedAt, endedAt: max(a.startedAt, endDate),
            focusedSeconds: focused,
            plannedFocusMinutes: a.plannedFocusMinutes,
            roundsCompleted: max(0, completedRounds),
            endReason: reason,
            apps: usage.topApps(),
            documents: usage.topDocuments(),
            artifacts: a.artifacts.sorted { $0.date < $1.date },
            interruptions: a.interruptions,
            mutedSystemNotifications: a.didEnableDoNotDisturb,
            summary: "", summaryBy: FocusSummarizer.templateName
        )
        record.summary = FocusSummarizer.template(for: record)

        active = nil
        store.saveActive(nil)
        store.add(record)
        lastSummary = record
        activities.dismiss(id: Self.activityID)
        postSummaryBand(record, kick: effects)
        if effects {
            playEdgeGlow(.celebrate, confetti: reason == .completed)
        } else {
            refreshEdgeGlow()
        }
        AppLog.log("Focus: ended (\(reason.rawValue)) after \(Int(focused / 60)) min")
        onSessionEnded?(record)
        if presentsSummaryWindow { FocusSummaryWindowController.shared.show(controller: self) }

        guard settings.summarizesWithModel else { return }
        isSummarizing = true
        Task { [weak self] in
            let text = await FocusSummarizer.modelSummary(for: record)
            guard let self else { return }
            self.isSummarizing = false
            guard let text else { return }
            var updated = record
            updated.summary = text
            updated.summaryBy = FocusSummarizer.modelName
            self.store.update(updated)
            if self.lastSummary?.id == updated.id { self.lastSummary = updated }
            self.onSessionEnded?(updated)
        }
    }

    // MARK: Muting

    private func enableDoNotDisturb(sessionID: UUID) {
        let s = settings
        Task { [weak self] in
            guard let self else { return }
            await self.doNotDisturb.refresh(on: s.dndOnShortcut, off: s.dndOffShortcut)
            let outcome = await self.doNotDisturb.turnOn(s.dndOnShortcut)
            switch outcome {
            case .done:
                if self.active?.id == sessionID {
                    self.active?.didEnableDoNotDisturb = true
                    self.persistActive()
                    self.updateBand()
                } else {
                    // The session ended while the shortcut was running.
                    _ = await self.doNotDisturb.turnOff(s.dndOffShortcut)
                }
            case .notSetUp:
                self.doNotDisturbNotice = "Set up Do Not Disturb in Focus Settings to silence other apps."
            case .failed(let message):
                self.doNotDisturbNotice = "Do Not Disturb shortcut failed: \(FocusText.clip(message, 80))"
            }
        }
    }

    private func disableDoNotDisturb() {
        let off = settings.dndOffShortcut
        Task { [weak self] in
            guard let self else { return }
            if case .failed(let message) = await self.doNotDisturb.turnOff(off) {
                self.doNotDisturbNotice = "Couldn’t turn Do Not Disturb off: \(FocusText.clip(message, 80))"
            }
        }
    }

    // MARK: Timer mirroring

    /// Starts the TimerController countdown for the current phase, so the
    /// Today tab, the end chime and the scheduled notification all follow it.
    private func mirrorPhase() {
        guard let a = active, let timer, timer.isEnabled else {
            mirroring = false
            return
        }
        // A countdown the user started themselves keeps running; Focus then
        // keeps time (and chimes) on its own.
        if !mirroring, !timer.state.isIdle {
            AppLog.log("Focus: timer busy, counting on its own")
            return
        }
        let duration = a.schedule.remaining(at: Date())
        let minutes = Int((duration / 60).rounded())
        // TimerController counts whole minutes; skip odd lengths (tests).
        guard minutes >= 1, abs(Double(minutes * 60) - duration) < 2 else {
            mirroring = false
            return
        }
        timer.startTimer(minutes: minutes)
        mirroring = true
        mirroredDuration = TimeInterval(minutes * 60)
    }

    private func timerMatchesPhase() -> Bool {
        guard let timer, timer.isEnabled, let a = active, timer.state.mode == .timer else { return false }
        guard let end = timer.state.endsAt, let mine = a.schedule.endsAt else { return timer.state.isPaused && a.schedule.isPaused }
        return abs(end.timeIntervalSince(mine)) < 3
    }

    /// The user paused, resumed or reset the timer from the Today tab.
    private func timerChanged() {
        guard mirroring, let timer, let a = active else { return }
        let state = timer.state
        guard state.mode == .timer, abs(state.duration - mirroredDuration) < 1 else {
            // Something else took over the timer: keep focusing without it.
            mirroring = false
            return
        }
        switch state.status {
        case .paused:
            if !a.schedule.isPaused { pause() }
        case .running:
            if a.schedule.isPaused { resume() }
        case .idle:
            // Finishing on time is ours to handle in `tick`; an early reset
            // just detaches the timer.
            if a.schedule.remaining(at: Date()) > 2 { mirroring = false }
        }
    }

    // MARK: Artifacts

    private func sampleArtifacts() {
        guard var a = active else { return }
        let known = Set(a.artifacts.map(\.id))
        let start = a.startedAt.addingTimeInterval(-2)
        let fresh = sources.artifacts().filter { item in
            !baseline.contains(item.id) && !known.contains(item.id)
                && (item.kind == .spaceItem || item.date >= start)
        }
        guard !fresh.isEmpty else { return }
        a.artifacts.append(contentsOf: fresh)
        active = a
    }

    // MARK: Distractions

    private func frontmostChanged(_ app: NSRunningApplication) {
        distractionGuard.frontmostChanged(app)
        if overlay.isVisible, let key = overlay.currentKey {
            let stillThere = key == "app:" + (app.bundleIdentifier ?? "")
                || (key.hasPrefix("site:") && SpaceConnectors.Browser.all.contains { $0.bundleID == app.bundleIdentifier })
            if !stillThere { overlay.hide() }
        }
    }

    private func distractionHit(_ hit: FocusDistractionGuard.Hit) {
        guard var a = active, a.schedule.phase == .focus, !a.schedule.isPaused else { return }
        if overlay.isVisible && overlay.currentKey == hit.key { return }
        // A site that comes back a few seconds after "Back to Work" is the same distraction.
        let isRepeat = a.interruptions.last.map { $0.target == hit.title && Date().timeIntervalSince($0.date) < 60 } ?? false
        if !isRepeat {
            a.interruptions.append(FocusInterruption(target: hit.title, date: Date(), snoozed: false))
            active = a
        }
        AppLog.log("Focus: distraction overlay shown")
        guard presentsOverlay else { return }
        let model = FocusOverlayModel(key: hit.key, target: hit.title, isSite: hit.isSite,
                                      timeLeft: FocusText.duration(remaining), snoozeMinutes: settings.snoozeMinutes)
        overlay.show(model: model, actions: .init(
            backToWork: { [weak self] in self?.backToWork(from: hit) },
            snooze: { [weak self] in self?.snooze(hit) },
            endFocus: { [weak self] in
                self?.overlay.hide()
                self?.end()
            }
        ))
    }

    private func backToWork(from hit: FocusDistractionGuard.Hit) {
        overlay.hide()
        if let work = distractionGuard.lastWorkApp, !work.isTerminated, work.bundleIdentifier != hit.bundleID {
            work.activate()
        } else {
            // Nowhere to go back to: hide (never quit) the distracting app or browser.
            NSRunningApplication.runningApplications(withBundleIdentifier: hit.bundleID).first?.hide()
        }
    }

    private func snooze(_ hit: FocusDistractionGuard.Hit) {
        distractionGuard.snooze(hit.key)
        if var a = active, let i = a.interruptions.lastIndex(where: { $0.target == hit.title }) {
            a.interruptions[i].snoozed = true
            active = a
        }
        overlay.hide()
    }

    // MARK: Band

    private func updateBand() {
        guard let a = active else {
            activities.dismiss(id: Self.activityID)
            return
        }
        let model = FocusBandView.Model(
            title: phaseTitle,
            time: FocusText.clock(a.schedule.remaining(at: now)),
            progress: a.schedule.progress(at: now),
            isBreak: a.schedule.phase.isBreak,
            isPaused: a.schedule.isPaused,
            round: roundText,
            doNotDisturb: a.didEnableDoNotDisturb,
            kickedAt: kickDate(bandKickAt)
        )
        activities.post(LiveActivity(
            id: Self.activityID, kind: .timer, priority: Self.activityPriority,
            duration: nil, opensTab: bandOpensTab,
            peekKey: model.isBreak ? "break" : "focus"
        ) {
            FocusBandView(model: model)
        }
        .compact {
            CompactProgressRing(progress: model.progress, tint: model.isBreak ? FocusPalette.rest : FocusPalette.accent)
        } trailing: {
            Text(model.time)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(model.isPaused ? Color.white.opacity(0.55) : Color.white)
        })
    }

    private func postCelebration(finished: FocusSchedule.Phase, next: FocusSchedule.Phase, schedule: FocusSchedule) {
        let message: String
        switch next {
        case .shortBreak, .longBreak:
            message = "Round done — \(FocusText.duration(schedule.phaseDuration)) \(next == .longBreak ? "long break" : "break")"
        case .focus:
            message = "Break over — back to focus"
        }
        let accent = next == .focus ? FocusPalette.accent : FocusPalette.rest
        let kick = kickDate(Date())
        activities.post(LiveActivity(id: Self.doneActivityID, kind: .timer, priority: 86, duration: 5, opensTab: bandOpensTab) {
            FocusDoneBandView(message: message, accent: accent, kickedAt: kick)
        }
        .announcing(message, as: .timer, important: true))
    }

    private func postSummaryBand(_ record: FocusSessionRecord, kick: Bool) {
        let kickedAt = kick ? kickDate(Date()) : nil
        activities.post(LiveActivity(
            id: Self.summaryActivityID, kind: .timer, priority: 86, duration: 8,
            height: NotchMetrics.activityAnswerBandHeight, opensTab: bandOpensTab
        ) {
            FocusSummaryBandView(record: record, kickedAt: kickedAt)
        })
    }

    // MARK: Screen effects

    /// The mood the border holds between bursts: only with "Always, subtly",
    /// while a phase runs (not paused).
    private var restingGlowMood: FocusGlowMood? {
        guard settings.edgeGlow == .alwaysSubtle, let a = active, !a.schedule.isPaused else { return nil }
        return a.schedule.phase.isBreak ? .relax : .focus
    }

    private func glowOptions(confetti: Bool) -> FocusGlowOptions {
        FocusGlowOptions(
            shake: settings.edgeGlowKick,
            haptics: settings.edgeGlowHaptics,
            confetti: confetti && settings.edgeGlowConfetti,
            reduceMotion: FocusEdgeGlowController.systemReduceMotion
        )
    }

    private func playEdgeGlow(_ mood: FocusGlowMood, confetti: Bool = false) {
        guard presentsEdgeGlow else { return }
        guard settings.edgeGlow != .off else {
            edgeGlow.rest(nil, reduceMotion: true)
            return
        }
        edgeGlow.burst(mood, rest: restingGlowMood, options: glowOptions(confetti: confetti))
    }

    /// Brings the resting border in line with the settings and the phase.
    private func refreshEdgeGlow() {
        guard presentsEdgeGlow else { return }
        edgeGlow.rest(restingGlowMood, reduceMotion: FocusEdgeGlowController.systemReduceMotion)
    }

    /// Plays one burst so the user can see it (Focus Settings).
    func previewEdgeGlow(_ mood: FocusGlowMood) {
        guard presentsEdgeGlow else { return }
        edgeGlow.burst(mood, rest: restingGlowMood, options: glowOptions(confetti: mood == .celebrate))
    }

    /// The band kick happens once, right after `date`; later band refreshes
    /// (every second) pass nil so it never repeats.
    private func kickDate(_ date: Date?) -> Date? {
        guard let date, settings.edgeGlowKick, !FocusEdgeGlowController.systemReduceMotion,
              Date().timeIntervalSince(date) < FocusGlowTiming.kick + 0.3 else { return nil }
        return date
    }

    var _restingGlowMood: FocusGlowMood? { restingGlowMood }
    var _edgeGlowController: FocusEdgeGlowController { edgeGlow }

    private func playChime() {
        let sound = NSSound(named: "Glass")
        completionSound = sound
        sound?.play()
    }

    // MARK: Persistence

    private func persistActive() {
        guard var a = active else {
            store.saveActive(nil)
            return
        }
        a.usage = tracker.checkpoint()
        store.saveActive(a)
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Keys.settings)
    }

    private func applySettingsToGuards() {
        let s = settings.sanitized
        distractionGuard.apps = s.blockedApps
        distractionGuard.sites = s.blockedSites
        distractionGuard.snoozeMinutes = s.snoozeMinutes
        tracker.tracksWindowTitles = s.tracksWindowTitles
        if isStarted || active != nil { refreshEdgeGlow() }
        guard let a = active else { return }
        if !s.blocksDistractions {
            distractionGuard.deactivate()
            overlay.hide()
        } else if !distractionGuard.isActive, a.schedule.phase == .focus, !a.schedule.isPaused {
            distractionGuard.activate()
        }
    }

    // MARK: Test seams

    /// Ends the running phase as if its time ran out at `date` (harness only).
    func _simulatePhaseEnd(at date: Date) { phaseEnded(at: date, celebrate: true) }
    /// Feeds a distraction as the guard would (harness only).
    func _simulateDistraction(title: String, bundleID: String, isSite: Bool) {
        distractionHit(.init(key: (isSite ? "site:" : "app:") + title, title: title, bundleID: bundleID, isSite: isSite))
    }
    func _sampleNow() { sampleArtifacts() }
    var _isMirroringTimer: Bool { mirroring }
    var _isGuardActive: Bool { distractionGuard.isActive }
}
