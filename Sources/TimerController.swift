import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: - Pure timer state

/// Everything the timer needs to survive a relaunch. Time is kept as dates,
/// never as counted ticks, so a running timer keeps counting while the app is
/// closed or the Mac sleeps.
struct TimerState: Codable, Equatable {
    enum Mode: String, Codable {
        case pomodoro
        case timer
    }

    enum Phase: String, Codable {
        case focus
        case shortBreak
        case longBreak
        /// A plain countdown.
        case timer
    }

    enum Status: Codable, Equatable {
        case idle
        /// Counts down from `startsAt` (which may be a few seconds in the
        /// future while Pomodoro pauses between phases) to `endsAt`.
        case running(startsAt: Date, endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    var mode: Mode
    var phase: Phase
    /// Focus sessions finished in the current Pomodoro cycle (0..<4).
    var completedFocus: Int
    /// Length of the current phase, including any minutes added.
    var duration: TimeInterval
    /// Length before minutes were added; reset returns to it.
    var baseDuration: TimeInterval
    var status: Status

    static func pomodoro() -> TimerState {
        let duration = Pomodoro.duration(of: .focus)
        return TimerState(mode: .pomodoro, phase: .focus, completedFocus: 0,
                          duration: duration, baseDuration: duration, status: .idle)
    }

    static func timer(minutes: Int) -> TimerState {
        let duration = TimeInterval(max(1, minutes) * 60)
        return TimerState(mode: .timer, phase: .timer, completedFocus: 0,
                          duration: duration, baseDuration: duration, status: .idle)
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    var isIdle: Bool { status == .idle }

    /// True while Pomodoro waits out the short pause before the next phase.
    func isPending(at now: Date) -> Bool {
        if case .running(let startsAt, _) = status { return now < startsAt }
        return false
    }

    func remaining(at now: Date) -> TimeInterval {
        switch status {
        case .idle:
            return duration
        case .paused(let remaining):
            return max(0, remaining)
        case .running(let startsAt, let endsAt):
            return max(0, endsAt.timeIntervalSince(max(now, startsAt)))
        }
    }

    /// 0 at the start of the phase, 1 when it is done.
    func progress(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    /// When the running phase ends, if it is running.
    var endsAt: Date? {
        if case .running(_, let endsAt) = status { return endsAt }
        return nil
    }

    mutating func start(at now: Date, after delay: TimeInterval = 0) {
        let startsAt = now.addingTimeInterval(delay)
        status = .running(startsAt: startsAt, endsAt: startsAt.addingTimeInterval(duration))
    }

    mutating func pause(at now: Date) {
        guard isRunning else { return }
        status = .paused(remaining: remaining(at: now))
    }

    mutating func resume(at now: Date) {
        guard case .paused(let remaining) = status else { return }
        status = .running(startsAt: now, endsAt: now.addingTimeInterval(remaining))
    }

    /// Adds a minute to the phase, whatever its status.
    mutating func addMinute() {
        duration += 60
        switch status {
        case .idle:
            break
        case .paused(let remaining):
            status = .paused(remaining: remaining + 60)
        case .running(let startsAt, let endsAt):
            status = .running(startsAt: startsAt, endsAt: endsAt.addingTimeInterval(60))
        }
    }

    /// Back to the start of the current phase; when already there, a
    /// Pomodoro cycle starts over at its first focus session.
    mutating func reset() {
        if isIdle, mode == .pomodoro {
            self = .pomodoro()
        } else {
            duration = baseDuration
            status = .idle
        }
    }

    /// Moves a Pomodoro to its next phase. `countFocus` is false when the
    /// user skips, so skipped focus sessions don't count toward the long break.
    mutating func advance(countFocus: Bool) {
        guard mode == .pomodoro else {
            duration = baseDuration
            status = .idle
            return
        }
        let next = Pomodoro.next(after: phase, completedFocus: completedFocus, countFocus: countFocus)
        phase = next.phase
        completedFocus = next.completedFocus
        duration = Pomodoro.duration(of: next.phase)
        baseDuration = duration
        status = .idle
    }

    /// Focus session the phase belongs to, e.g. 2 for "2/4": the one under
    /// way during focus, the one just finished during a break.
    var sessionNumber: Int {
        let number = phase == .focus ? completedFocus + 1 : completedFocus
        return min(Pomodoro.sessionsPerCycle, max(1, number))
    }
}

enum Pomodoro {
    static let focusMinutes = 25
    static let shortBreakMinutes = 5
    static let longBreakMinutes = 15
    static let sessionsPerCycle = 4
    /// Gap between a finished phase and the next one starting on its own.
    static let autoAdvancePause: TimeInterval = 5

    static func duration(of phase: TimerState.Phase) -> TimeInterval {
        switch phase {
        case .focus: TimeInterval(focusMinutes * 60)
        case .shortBreak: TimeInterval(shortBreakMinutes * 60)
        case .longBreak: TimeInterval(longBreakMinutes * 60)
        case .timer: TimeInterval(focusMinutes * 60)
        }
    }

    static func next(
        after phase: TimerState.Phase,
        completedFocus: Int,
        countFocus: Bool = true
    ) -> (phase: TimerState.Phase, completedFocus: Int) {
        switch phase {
        case .focus:
            let done = countFocus ? completedFocus + 1 : completedFocus
            return done >= sessionsPerCycle ? (.longBreak, done) : (.shortBreak, done)
        case .shortBreak:
            return (.focus, completedFocus)
        case .longBreak, .timer:
            return (.focus, 0)
        }
    }
}

enum TimerFormat {
    /// "18:42", "03:10", or "1:05:00" past an hour. Rounds up so a fresh
    /// 25-minute timer reads 25:00 and the last second reads 00:01.
    static func clock(_ remaining: TimeInterval) -> String {
        let total = Int(max(0, remaining).rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func shortName(of phase: TimerState.Phase) -> String {
        switch phase {
        case .focus: "Focus"
        case .shortBreak, .longBreak: "Break"
        case .timer: "Timer"
        }
    }

    static func longName(of phase: TimerState.Phase) -> String {
        switch phase {
        case .focus: "Focus"
        case .shortBreak: "Break"
        case .longBreak: "Long break"
        case .timer: "Timer"
        }
    }

    /// Celebration line when a phase ends, and the notification title.
    static func doneMessage(for finished: TimerState.Phase, next: TimerState.Phase) -> String {
        switch finished {
        case .focus: next == .longBreak ? "Focus done — take a long break" : "Focus done — take a break"
        case .shortBreak, .longBreak: "Break over — back to focus"
        case .timer: "Timer done"
        }
    }

    static func color(of phase: TimerState.Phase) -> Color {
        switch phase {
        // SparkV brand: red is the one accent; a break keeps the calm green.
        case .focus, .timer: SparkVTheme.red
        case .shortBreak, .longBreak: SparkVTheme.success
        }
    }
}

// MARK: - Controller

/// Pomodoro and plain countdown timers. Shows a persistent band under the
/// notch while a timer runs, celebrates when it ends, and keeps counting
/// across relaunches.
@MainActor
final class TimerController: ObservableObject {
    static let presets = [1, 5, 10, 15, 25]

    /// Turning the timer off resets it and clears the band.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                AppLog.log("Timer: enabled")
            } else {
                AppLog.log("Timer: disabled")
                state.status = .idle
                state.duration = state.baseDuration
                if state.mode == .pomodoro { state = .pomodoro() }
                activities.dismiss(id: Self.doneActivityID)
                stateDidChange()
            }
        }
    }

    @Published private(set) var state: TimerState
    /// Refreshed at least once a second while running, so views re-render.
    @Published private(set) var now = Date()

    private let activities: ActivityCenter
    private var ticker: Task<Void, Never>?
    private var isStarted = false
    private var completionSound: NSSound?
    /// Cached notification permission; nil until it has been read.
    private var notificationsAuthorized: Bool?
    /// Follows the notification switch in System Settings.
    private var notificationWatch: AnyCancellable?

    private enum Keys {
        static let enabled = "timer.enabled"
        static let state = "timer.state"
        static let askedForNotifications = "timer.askedForNotifications"
    }

    private static let activityID = "timer"
    private static let doneActivityID = "timer.done"
    private static let notificationID = "SparkV.timer"
    /// A phase that ended this long before launch (or wake) moves on quietly
    /// instead of chiming and auto-starting the next one.
    private static let staleCompletion: TimeInterval = 60
    /// UNUserNotificationCenter traps outside an app bundle (e.g. in tests).
    private static let canNotify = Bundle.main.bundleIdentifier != nil

    init(activities: ActivityCenter) {
        self.activities = activities
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.state),
           let saved = try? JSONDecoder().decode(TimerState.self, from: data) {
            state = saved
        } else {
            state = .pomodoro()
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        guard isEnabled else { return }

        // Reading settings never prompts.
        if Self.canNotify {
            Task { await refreshNotificationAuthorization() }
            notificationWatch = PermissionCenter.shared.onChange(of: .notifications) { [weak self] status in
                guard let self else { return }
                self.notificationsAuthorized = status.isGranted
                self.scheduleNotification()
            }
        }

        if let endsAt = state.endsAt, endsAt <= Date() {
            let overdue = Date().timeIntervalSince(endsAt)
            AppLog.log("Timer: \(state.phase.rawValue) ended \(Int(overdue))s before launch")
            // The system already delivered the scheduled notification.
            finishPhase(celebrate: overdue < Self.staleCompletion)
        } else {
            stateDidChange()
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        save()
        // A scheduled notification stays pending so it still fires while the
        // app is closed.
    }

    // MARK: Controls

    /// Starts a Pomodoro cycle at its first focus session.
    func startPomodoro() {
        guard isEnabled else { return }
        state = .pomodoro()
        begin()
    }

    /// Starts a plain countdown of `minutes`.
    func startTimer(minutes: Int) {
        guard isEnabled else { return }
        state = .timer(minutes: minutes)
        begin()
    }

    /// Start, pause or resume, depending on the current status.
    func toggle() {
        guard isEnabled else { return }
        switch state.status {
        case .idle:
            begin()
        case .running:
            state.pause(at: Date())
            AppLog.log("Timer: paused")
            stateDidChange()
        case .paused:
            state.resume(at: Date())
            AppLog.log("Timer: resumed")
            stateDidChange()
        }
    }

    func reset() {
        state.reset()
        AppLog.log("Timer: reset")
        stateDidChange()
    }

    /// Pomodoro only: jump to the next phase, keeping it running if this one was.
    func skip() {
        guard isEnabled, state.mode == .pomodoro else { return }
        let wasActive = !state.isIdle
        state.advance(countFocus: false)
        if wasActive { state.start(at: Date()) }
        AppLog.log("Timer: skipped to \(state.phase.rawValue)")
        stateDidChange()
    }

    func addMinute() {
        guard isEnabled else { return }
        state.addMinute()
        stateDidChange()
    }

    // MARK: Read-outs for views

    var remaining: TimeInterval { state.remaining(at: now) }
    var progress: Double { state.progress(at: now) }
    var isPending: Bool { state.isPending(at: now) }
    var remainingText: String { TimerFormat.clock(remaining) }
    var phaseTitle: String { TimerFormat.longName(of: state.phase) }
    var accent: Color { TimerFormat.color(of: state.phase) }
    /// "2/4" during Pomodoro.
    var sessionText: String? {
        state.mode == .pomodoro ? "\(state.sessionNumber)/\(Pomodoro.sessionsPerCycle)" : nil
    }

    // MARK: Internals

    private func begin() {
        state.start(at: Date())
        AppLog.log("Timer: started \(state.phase.rawValue) for \(Int(state.duration))s")
        requestNotificationsIfFirstStart()
        stateDidChange()
    }

    /// Persists, reschedules the notification, refreshes the band and the ticker.
    private func stateDidChange() {
        save()
        now = Date()
        scheduleNotification()
        updateActivity()
        restartTicker()
    }

    private func restartTicker() {
        ticker?.cancel()
        ticker = nil
        guard isEnabled, state.isRunning else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.tick() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// One second of the countdown. Returns how long to wait for the next
    /// visible change, or nil once the timer has stopped running.
    private func tick() -> TimeInterval? {
        guard isEnabled, case .running(let startsAt, let endsAt) = state.status else { return nil }
        let date = Date()
        now = date
        if date >= endsAt {
            let overdue = date.timeIntervalSince(endsAt)
            // A long overshoot means the Mac slept through the end.
            finishPhase(celebrate: overdue < Self.staleCompletion)
            return nil
        }
        updateActivity()
        if date < startsAt { return max(0.05, startsAt.timeIntervalSince(date) + 0.01) }
        // Wake just after the displayed (rounded-up) second changes.
        let remaining = endsAt.timeIntervalSince(date)
        let fraction = remaining - remaining.rounded(.down)
        return (fraction == 0 ? 1 : fraction) + 0.01
    }

    /// The running phase reached zero. With `celebrate`, chime, show the
    /// celebration and (Pomodoro) start the next phase after a short pause;
    /// false when the end passed long ago. The notification needs nothing
    /// here: it was scheduled ahead for the end date and fires on its own.
    private func finishPhase(celebrate: Bool) {
        let finished = state.phase
        state.advance(countFocus: true)
        let message = TimerFormat.doneMessage(for: finished, next: state.phase)
        AppLog.log("Timer: \(finished.rawValue) done\(celebrate ? "" : " (while away)")")

        if celebrate {
            if state.mode == .pomodoro {
                state.start(at: Date(), after: Pomodoro.autoAdvancePause)
            }
            playSound()
            postCelebration(message, phase: finished)
        }
        stateDidChange()
    }

    private func playSound() {
        let sound = NSSound(named: "Glass")
        completionSound = sound
        sound?.play()
    }

    // MARK: Band

    private func updateActivity() {
        guard isEnabled, !state.isIdle else {
            activities.dismiss(id: Self.activityID)
            return
        }
        let snapshot = TimerBandView.Model(
            title: TimerFormat.shortName(of: state.phase),
            time: TimerFormat.clock(state.remaining(at: now)),
            progress: state.progress(at: now),
            accent: TimerFormat.color(of: state.phase),
            isPaused: state.isPaused,
            isPending: state.isPending(at: now),
            session: sessionText
        )
        activities.post(LiveActivity(
            id: Self.activityID,
            kind: .timer,
            priority: 20,
            duration: nil,
            opensTab: .today
        ) {
            TimerBandView(model: snapshot)
        }
        // Rests beside the camera housing (ring + time) after its peek.
        .compact {
            CompactProgressRing(progress: snapshot.progress, tint: snapshot.accent)
        } trailing: {
            Text(snapshot.time)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        })
    }

    private func postCelebration(_ message: String, phase: TimerState.Phase) {
        let accent = TimerFormat.color(of: phase)
        activities.post(LiveActivity(
            id: Self.doneActivityID,
            kind: .timer,
            priority: 85,
            duration: 5,
            opensTab: .today
        ) {
            TimerDoneBandView(message: message, accent: accent)
        })
    }

    // MARK: Notifications

    /// The first start asks for permission (through PermissionCenter, so it
    /// never stacks on another prompt); launch never does. A refusal is not
    /// re-asked or sent to Settings from here: the timer works without it.
    private func requestNotificationsIfFirstStart() {
        let defaults = UserDefaults.standard
        guard Self.canNotify, !defaults.bool(forKey: Keys.askedForNotifications) else { return }
        Task {
            let center = PermissionCenter.shared
            var status = await center.freshStatus(.notifications)
            if status == .notDetermined {
                status = await center.request(.notifications, from: "Timer")
            }
            // Still undetermined means the prompt was deferred: ask next start.
            if status != .notDetermined { defaults.set(true, forKey: Keys.askedForNotifications) }
            AppLog.log("Timer: notification permission \(status.rawValue)")
            notificationsAuthorized = status.isGranted
            scheduleNotification()
        }
    }

    private func refreshNotificationAuthorization() async {
        let status = await PermissionCenter.shared.freshStatus(.notifications)
        notificationsAuthorized = status.isGranted
        scheduleNotification()
    }

    /// Keeps exactly one pending notification for the end of the running
    /// phase, scheduled ahead so it fires even if the app quits first.
    private func scheduleNotification() {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        guard isEnabled, notificationsAuthorized == true, let endsAt = state.endsAt else { return }
        let interval = endsAt.timeIntervalSinceNow
        guard interval >= 1 else { return }

        let finished = state.phase
        let next = Pomodoro.next(after: finished, completedFocus: state.completedFocus).phase
        let content = UNMutableNotificationContent()
        content.title = TimerFormat.doneMessage(for: finished, next: state.mode == .pomodoro ? next : .timer)
        content.body = Self.notificationBody(finished: finished, next: next, mode: state.mode,
                                             minutes: Int((state.duration / 60).rounded()))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                AppLog.log("Timer: couldn't schedule notification: \(error.localizedDescription)")
            }
        }
    }

    private static func notificationBody(
        finished: TimerState.Phase,
        next: TimerState.Phase,
        mode: TimerState.Mode,
        minutes: Int
    ) -> String {
        guard mode == .pomodoro else { return "Your \(minutes)-minute timer is up." }
        switch next {
        case .shortBreak: return "\(Pomodoro.shortBreakMinutes)-minute break starts now."
        case .longBreak: return "\(Pomodoro.longBreakMinutes)-minute break — you finished a full cycle."
        case .focus, .timer: return "\(Pomodoro.focusMinutes)-minute focus session starts now."
        }
    }

    // MARK: Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Keys.state)
    }
}
