import AppKit
import Carbon.HIToolbox
import Combine
import os
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
        timer(seconds: TimeInterval(max(1, minutes) * 60))
    }

    /// A plain countdown of any length (at least a second).
    static func timer(seconds: TimeInterval) -> TimerState {
        let duration = max(1, seconds.rounded())
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

    /// Runs again for `seconds` (a snooze) without changing the length the
    /// timer goes back to afterwards: `baseDuration` stays the original.
    mutating func snooze(for seconds: TimeInterval, at now: Date) {
        duration = max(1, seconds.rounded())
        start(at: now)
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
        add(60)
    }

    /// Adds `seconds` to the phase, whatever its status.
    mutating func add(_ seconds: TimeInterval) {
        duration += seconds
        switch status {
        case .idle:
            break
        case .paused(let remaining):
            status = .paused(remaining: remaining + seconds)
        case .running(let startsAt, let endsAt):
            status = .running(startsAt: startsAt, endsAt: endsAt.addingTimeInterval(seconds))
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

/// Pomodoro lengths. They follow the Timer settings (`TimerPreferences`),
/// read straight from UserDefaults so pure code can use them anywhere.
enum Pomodoro {
    static var focusMinutes: Int { TimerPreferences.storedInt(TimerPreferences.Keys.focus, 25, 1...180) }
    static var shortBreakMinutes: Int { TimerPreferences.storedInt(TimerPreferences.Keys.shortBreak, 5, 1...60) }
    static var longBreakMinutes: Int { TimerPreferences.storedInt(TimerPreferences.Keys.longBreak, 15, 1...90) }
    static var sessionsPerCycle: Int { TimerPreferences.storedInt(TimerPreferences.Keys.sessions, 4, 2...8) }
    /// Whether the next phase starts on its own after `autoAdvancePause`.
    static var autoStartsNextPhase: Bool { TimerPreferences.storedBool(TimerPreferences.Keys.autoStart, true) }
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
        hms(Int(max(0, remaining).rounded(.up)))
    }

    /// Stopwatch reading: "00:07", "12:04", "1:02:03" (whole seconds, rounded down).
    static func elapsed(_ elapsed: TimeInterval) -> String {
        hms(Int(max(0, elapsed).rounded(.down)))
    }

    private static func hms(_ total: Int) -> String {
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

    /// Extra countdowns: the Clock app's orange in Apple, red in SparkV Red.
    static var countdownColor: Color { SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red) }
    /// Stopwatches: cyan in Apple, red in SparkV Red.
    static var stopwatchColor: Color { SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red) }

    /// A past date from which whole-second ticks line up with the moments
    /// the reading changes (`clock` rounds up, `elapsed` rounds down), so a
    /// `TimelineView` never shows a second late.
    static func tickAnchor(for entry: TimerEntry, now: Date) -> Date {
        let offset: TimeInterval
        switch entry.kind {
        case .stopwatch:
            guard let started = entry.stopwatch.startedAt else { return now }
            let fraction = entry.stopwatch.accumulated.truncatingRemainder(dividingBy: 1)
            offset = started.addingTimeInterval(-fraction).timeIntervalSince(now).truncatingRemainder(dividingBy: 1)
        case .pomodoro, .countdown:
            guard let end = entry.countdown.endsAt else { return now }
            offset = end.timeIntervalSince(now).truncatingRemainder(dividingBy: 1)
        }
        // A whole second before `now`, aligned to the change moments.
        let aligned = now.addingTimeInterval(offset)
        return aligned > now ? aligned.addingTimeInterval(-1) : aligned
    }
}

// MARK: - Several timers

/// One extra timer beside the main one: a named countdown or a stopwatch.
struct TimerItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case countdown
        case stopwatch
    }

    let id: UUID
    var name: String
    var kind: Kind
    /// Countdowns (mode `.timer`).
    var countdown: TimerState
    var stopwatch: StopwatchState
    /// Rings until stopped when it ends (countdowns).
    var rings: Bool

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return kind == .stopwatch ? "Stopwatch" : "Timer"
    }

    var isIdle: Bool { kind == .stopwatch ? stopwatch.isIdle : countdown.isIdle }
    var isRunning: Bool { kind == .stopwatch ? stopwatch.isRunning : countdown.isRunning }
}

/// A timer as the views draw it: the main one (Pomodoro or countdown) or an
/// extra item, copied into a value so bands can draw it between posts.
struct TimerEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case pomodoro
        case countdown
        case stopwatch
    }

    /// "primary" or the item's UUID.
    let id: String
    /// nil for the main timer.
    let itemID: UUID?
    let kind: Kind
    /// Phase or the user's name ("Focus", "Break", "Tea", "Stopwatch").
    let title: String
    let countdown: TimerState
    let stopwatch: StopwatchState
    /// "2/4" during Pomodoro.
    let session: String?
    let accent: Color

    static let primaryID = "primary"

    var isPrimary: Bool { itemID == nil }
    var isRunning: Bool { kind == .stopwatch ? stopwatch.isRunning : countdown.isRunning }
    var isPaused: Bool { kind == .stopwatch ? stopwatch.isPaused : countdown.isPaused }
    var isIdle: Bool { kind == .stopwatch ? stopwatch.isIdle : countdown.isIdle }

    func isPending(at now: Date) -> Bool { kind != .stopwatch && countdown.isPending(at: now) }

    func timeText(at now: Date) -> String {
        kind == .stopwatch ? TimerFormat.elapsed(stopwatch.elapsed(at: now)) : TimerFormat.clock(countdown.remaining(at: now))
    }

    /// Countdowns fill up to their end; a stopwatch sweeps once a minute.
    func progress(at now: Date) -> Double {
        if kind == .stopwatch {
            let elapsed = stopwatch.elapsed(at: now)
            return stopwatch.isIdle ? 0 : elapsed.truncatingRemainder(dividingBy: 60) / 60
        }
        return countdown.progress(at: now)
    }

    var symbol: String {
        switch kind {
        case .stopwatch: "stopwatch"
        case .countdown: "timer"
        case .pomodoro:
            switch countdown.phase {
            case .focus: "brain.head.profile"
            case .shortBreak, .longBreak: "cup.and.saucer.fill"
            case .timer: "timer"
            }
        }
    }

    /// Soonest change first: running countdowns by end, then stopwatches,
    /// then paused ones.
    var sortKey: (Int, Double) {
        if kind != .stopwatch, let end = countdown.endsAt { return (0, end.timeIntervalSinceReferenceDate) }
        if stopwatch.isRunning { return (1, 0) }
        return (2, 0)
    }

    /// "Tea, 3 minutes 12 seconds left" for VoiceOver.
    func spoken(at now: Date) -> String {
        if kind == .stopwatch {
            return "\(title), \(TimerDurationParser.spoken(stopwatch.elapsed(at: now)))\(stopwatch.isRunning ? "" : ", paused")"
        }
        let left = TimerDurationParser.spoken(countdown.remaining(at: now).rounded(.up))
        if countdown.isIdle { return "\(title), \(left), not started" }
        return "\(title), \(left) left\(countdown.isPaused ? ", paused" : "")"
    }
}

/// Countdowns that ended and keep ringing until stopped. Two that end
/// together ring once ("Tea and Eggs"); Stop silences both, Snooze snoozes both.
struct TimerRinging: Equatable {
    /// The first timer that rang; nil: the main timer.
    let itemID: UUID?
    let title: String
    let since: Date
    /// Timers that ended while this one was ringing (nil: the main timer).
    var others: [UUID?] = []
    /// Their names, after `title`.
    var otherTitles: [String] = []

    /// Every ringing timer, the first one first.
    var itemIDs: [UUID?] { [itemID] + others }

    func includes(_ id: UUID?) -> Bool { itemIDs.contains(id) }

    /// "Tea", "Tea and Eggs", "Tea, Eggs and Pasta".
    var displayTitle: String {
        let names = [title] + otherTitles
        guard names.count > 1, let last = names.last else { return title }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "Tea is done", "Tea and Eggs are done".
    var doneSentence: String { "\(displayTitle) \(others.isEmpty ? "is" : "are") done" }

    /// Adds a timer that ended while this one rings.
    func adding(_ id: UUID?, title name: String) -> TimerRinging {
        guard !includes(id) else { return self }
        var copy = self
        copy.others.append(id)
        copy.otherTitles.append(name)
        return copy
    }
}

// MARK: - Settings

/// Timer settings, saved under `timer.*` in UserDefaults.
@MainActor
final class TimerPreferences: ObservableObject {
    static let shared = TimerPreferences()

    enum Keys {
        static let focus = "timer.pomodoro.focusMinutes"
        static let shortBreak = "timer.pomodoro.shortBreakMinutes"
        static let longBreak = "timer.pomodoro.longBreakMinutes"
        static let sessions = "timer.pomodoro.sessions"
        static let autoStart = "timer.pomodoro.autoStart"
        static let rings = "timer.alert.ringsUntilStopped"
        static let ringLimit = "timer.alert.ringLimitSeconds"
        static let sound = "timer.alert.sound"
        static let snooze = "timer.alert.snoozeMinutes"
        static let wings = "timer.showsBesideNotch"
        static let hotkey = "timer.hotkeyEnabled"
    }

    static let sounds = ["Glass", "Ping", "Hero", "Submarine", "Funk", "Tink", "Purr", "Blow", "Bottle", "Frog", "Morse", "Pop", "Sosumi", "Basso"]
    static let ringLimits = [15, 30, 60, 120, 300]

    @Published var focusMinutes: Int { didSet { save(focusMinutes, Keys.focus) } }
    @Published var shortBreakMinutes: Int { didSet { save(shortBreakMinutes, Keys.shortBreak) } }
    @Published var longBreakMinutes: Int { didSet { save(longBreakMinutes, Keys.longBreak) } }
    @Published var sessionsPerCycle: Int { didSet { save(sessionsPerCycle, Keys.sessions) } }
    @Published var autoStartsNextPhase: Bool { didSet { save(autoStartsNextPhase, Keys.autoStart) } }
    /// Countdowns (not Pomodoro phases) ring until stopped, up to `ringLimitSeconds`.
    @Published var ringsUntilStopped: Bool { didSet { save(ringsUntilStopped, Keys.rings) } }
    @Published var ringLimitSeconds: Int { didSet { save(ringLimitSeconds, Keys.ringLimit) } }
    @Published var soundName: String { didSet { save(soundName, Keys.sound) } }
    @Published var snoozeMinutes: Int { didSet { save(snoozeMinutes, Keys.snooze) } }
    /// Running timers rest beside the camera housing while the island is closed.
    @Published var showsBesideNotch: Bool { didSet { save(showsBesideNotch, Keys.wings) } }
    /// ⌃⌥⇧P starts, pauses or silences the main timer from anywhere.
    @Published var hotkeyEnabled: Bool { didSet { save(hotkeyEnabled, Keys.hotkey) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focusMinutes = Self.storedInt(Keys.focus, 25, 1...180, defaults)
        shortBreakMinutes = Self.storedInt(Keys.shortBreak, 5, 1...60, defaults)
        longBreakMinutes = Self.storedInt(Keys.longBreak, 15, 1...90, defaults)
        sessionsPerCycle = Self.storedInt(Keys.sessions, 4, 2...8, defaults)
        autoStartsNextPhase = Self.storedBool(Keys.autoStart, true, defaults)
        ringsUntilStopped = Self.storedBool(Keys.rings, true, defaults)
        ringLimitSeconds = Self.storedInt(Keys.ringLimit, 60, 5...600, defaults)
        soundName = defaults.string(forKey: Keys.sound).flatMap { Self.sounds.contains($0) ? $0 : nil } ?? "Glass"
        snoozeMinutes = Self.storedInt(Keys.snooze, 5, 1...60, defaults)
        showsBesideNotch = Self.storedBool(Keys.wings, true, defaults)
        hotkeyEnabled = Self.storedBool(Keys.hotkey, false, defaults)
    }

    func resetPomodoro() {
        focusMinutes = 25
        shortBreakMinutes = 5
        longBreakMinutes = 15
        sessionsPerCycle = 4
        autoStartsNextPhase = true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    nonisolated static func storedInt(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>, _ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: key) as? Int ?? fallback
        return min(range.upperBound, max(range.lowerBound, value))
    }

    nonisolated static func storedBool(_ key: String, _ fallback: Bool, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}

// MARK: - Notification actions (Snooze / Stop)

/// UNUserNotificationCenter delegate for the timer's notifications: their
/// Snooze and Stop buttons, and banners while SparkV runs. Anything else is
/// handed to the delegate that was installed before (if any), so another
/// feature can keep its own; a feature that installs one later should call
/// `forward(to:)` with it instead of replacing this one. With no other
/// delegate, other notifications behave as they did before this one was
/// installed: not presented while SparkV is the active app.
///
/// Sendable: its only mutable state, `other`, sits behind a lock.
final class TimerNotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = TimerNotificationRouter()
    static let categoryID = "SparkV.timer.alert"
    static let snoozeActionID = "SparkV.timer.snooze"
    static let stopActionID = "SparkV.timer.stop"
    static let timerKey = "timerID"

    private final class WeakDelegate: @unchecked Sendable {
        weak var value: UNUserNotificationCenterDelegate?
    }

    /// Written on the main actor, read in the delegate callbacks (the
    /// system's queue): always through the lock.
    private let otherLock = OSAllocatedUnfairLock(uncheckedState: WeakDelegate())

    private var other: UNUserNotificationCenterDelegate? {
        otherLock.withLockUnchecked { $0.value }
    }

    private func setOther(_ delegate: UNUserNotificationCenterDelegate?) {
        otherLock.withLockUnchecked { $0.value = delegate }
    }

    @MainActor
    func install(snoozeMinutes: Int) {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== self {
            if let existing = center.delegate { setOther(existing) }
            center.delegate = self
        }
        let snoozeTitle = "Snooze \(snoozeMinutes) min"
        center.getNotificationCategories { existing in
            let snooze = UNNotificationAction(identifier: Self.snoozeActionID, title: snoozeTitle, options: [])
            let stop = UNNotificationAction(identifier: Self.stopActionID, title: "Stop", options: [.destructive])
            let category = UNNotificationCategory(identifier: Self.categoryID, actions: [stop, snooze], intentIdentifiers: [], options: [])
            var categories = existing.filter { $0.identifier != Self.categoryID }
            categories.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
    }

    /// Another feature's delegate gets every notification that isn't the timer's.
    @MainActor
    func forward(to delegate: UNUserNotificationCenterDelegate?) {
        setOther(delegate)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier.hasPrefix(TimerController.notificationIDPrefix) {
            // SparkV already chimes (or rings) and shows its band.
            completionHandler([.banner, .list])
            return
        }
        if let other, other.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            other.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            return
        }
        // What macOS does with no delegate: nothing while SparkV is active.
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let request = response.notification.request
        guard request.identifier.hasPrefix(TimerController.notificationIDPrefix) else {
            if let other, other.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                other.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            } else {
                completionHandler()
            }
            return
        }
        let action = response.actionIdentifier
        let timerID = request.content.userInfo[Self.timerKey] as? String
        Task { @MainActor in
            TimerController.current?.handleNotificationAction(action, timerID: timerID)
        }
        completionHandler()
    }
}

// MARK: - Controller

/// Pomodoro and countdown timers, plus extra named countdowns and
/// stopwatches. Running timers rest beside the notch as one live activity,
/// a finished countdown can ring until stopped (Stop / Snooze in the drawer
/// and on its notification), and everything keeps counting across relaunches.
///
/// Energy: no per-second work in the controller. Bands and drawer views
/// read the dates through `TimelineView`, which only ticks while drawn; the
/// controller wakes once, at the soonest end.
@MainActor
final class TimerController: ObservableObject {
    static let presets = [1, 5, 10, 15, 25]
    /// More lengths in the preset menu.
    static let morePresets = [2, 3, 20, 30, 45, 60, 90]
    /// Extra timers beside the main one.
    static let maxExtras = 6
    /// Most recently created controller, for menus, settings and
    /// notification actions that have no environment. Weak.
    static weak var current: TimerController?
    nonisolated static let notificationIDPrefix = "SparkV.timer"
    /// ⌃⌥⇧P. ⌃⌥P is the Color Picker's default; nothing else in SparkV
    /// uses ⌃⌥⇧P.
    static let hotkeyShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))

    /// Turning the timer off resets it and clears the band.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                AppLog.log("Timer: enabled")
                if isStarted { setUpNotifications() }
            } else {
                AppLog.log("Timer: disabled")
                stopRinging(reason: "timer off")
                state.status = .idle
                state.duration = state.baseDuration
                if state.mode == .pomodoro { state = .pomodoro() }
                for index in extras.indices {
                    extras[index].countdown.reset()
                    extras[index].stopwatch.reset()
                }
                saveExtras()
                activities.dismiss(id: Self.doneActivityID)
                stateDidChange()
                // stateDidChange only clears the main timer's notification.
                scheduleExtraNotifications()
            }
            updateHotkey()
        }
    }

    /// The main timer (Pomodoro or countdown). Focus and Smart Moments drive it.
    @Published private(set) var state: TimerState
    /// The main timer's name and whether it rings ("" uses the phase name).
    @Published private(set) var primaryName = ""
    @Published private(set) var extras: [TimerItem] = []
    /// A countdown that ended and is still ringing.
    @Published private(set) var ringing: TimerRinging?
    /// Which timer the Today slot shows: nil for the main one.
    @Published var focusedID: UUID?
    /// When the state last changed (views tick on their own through `TimelineView`).
    @Published private(set) var now = Date()
    /// False when macOS refused ⌃⌥⇧P (another app owns it).
    @Published private(set) var isHotkeyRegistered = false

    private let activities: ActivityCenter
    private let defaults: UserDefaults
    private let preferences: TimerPreferences
    private var ticker: Task<Void, Never>?
    private var isStarted = false
    private var completionSound: NSSound?
    private var ringSound: NSSound?
    /// Whether the main countdown rings when it ends (user-started ones).
    private var primaryRings = false
    /// Cached notification permission; nil until it has been read.
    private var notificationsAuthorized: Bool?
    /// Follows the notification switch in System Settings.
    private var notificationWatch: AnyCancellable?
    private var preferencesWatch: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private let hotkey = ScreenRegionHotkey()
    /// Tests: no sound.
    var isSilent = false

    private enum Keys {
        static let enabled = "timer.enabled"
        static let state = "timer.state"
        static let primaryMeta = "timer.primary.meta"
        static let extras = "timer.items.v2"
        static let askedForNotifications = "timer.askedForNotifications"
    }

    private struct PrimaryMeta: Codable {
        var name: String
        var rings: Bool
    }

    private static let activityID = "timer"
    private static let doneActivityID = "timer.done"
    private static let ringingActivityID = "timer.ringing"
    private static let notificationID = "SparkV.timer"
    /// A phase that ended this long before launch (or wake) moves on quietly
    /// instead of chiming and auto-starting the next one.
    private static let staleCompletion: TimeInterval = 60
    /// UNUserNotificationCenter traps outside an app bundle (e.g. in tests).
    private static let canNotify = Bundle.main.bundleIdentifier != nil

    init(activities: ActivityCenter, defaults: UserDefaults = .standard, preferences: TimerPreferences? = nil) {
        self.activities = activities
        self.defaults = defaults
        self.preferences = preferences ?? .shared
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.state),
           let saved = try? JSONDecoder().decode(TimerState.self, from: data) {
            state = saved
        } else {
            state = .pomodoro()
        }
        if let data = defaults.data(forKey: Keys.primaryMeta),
           let meta = try? JSONDecoder().decode(PrimaryMeta.self, from: data) {
            primaryName = meta.name
            primaryRings = meta.rings
        }
        if let data = defaults.data(forKey: Keys.extras),
           let saved = try? JSONDecoder().decode([TimerItem].self, from: data) {
            extras = Array(saved.prefix(Self.maxExtras))
        }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        Self.current = self
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        preferencesWatch = preferences.objectWillChange.sink { [weak self] _ in
            // After the change lands.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.preferencesChanged() } }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        updateHotkey()
        guard isEnabled else { return }
        setUpNotifications()

        let date = Date()
        if let endsAt = state.endsAt, endsAt <= date {
            let overdue = date.timeIntervalSince(endsAt)
            AppLog.log("Timer: \(state.phase.rawValue) ended \(Int(overdue))s before launch")
            // The system already delivered the scheduled notification.
            finishPhase(celebrate: overdue < Self.staleCompletion)
        }
        finishEndedExtras(at: date)
        stateDidChange()
    }

    /// Snooze / Stop actions and the permission watch. Reading settings never prompts.
    private func setUpNotifications() {
        guard Self.canNotify, notificationWatch == nil else { return }
        TimerNotificationRouter.shared.install(snoozeMinutes: preferences.snoozeMinutes)
        Task { await refreshNotificationAuthorization() }
        notificationWatch = PermissionCenter.shared.onChange(of: .notifications) { [weak self] status in
            guard let self else { return }
            self.notificationsAuthorized = status.isGranted
            self.scheduleAllNotifications()
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        ringSound?.stop()
        ringSound = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        preferencesWatch = nil
        notificationWatch = nil
        isStarted = false
        updateHotkey()
        save()
        saveExtras()
        // Scheduled notifications stay pending so they still fire while the
        // app is closed.
    }

    // MARK: Main timer controls

    /// Starts a Pomodoro cycle at its first focus session.
    func startPomodoro() {
        guard isEnabled else { return }
        stopRingingIfMain()
        state = .pomodoro()
        setPrimaryMeta(name: "", rings: false)
        focusedID = nil
        begin()
    }

    /// Starts a plain countdown of `minutes` on the main timer. Focus and
    /// Smart Moments call this: these countdowns chime once, never ring.
    func startTimer(minutes: Int) {
        guard isEnabled else { return }
        // A ringing main timer is done with: a later Snooze must not
        // replace this countdown.
        stopRingingIfMain()
        state = .timer(minutes: minutes)
        setPrimaryMeta(name: "", rings: false)
        begin()
    }

    /// A countdown the user started from the timer (presets, the field):
    /// rings until stopped when Timer settings say so.
    func startCountdown(seconds: TimeInterval, name: String = "") {
        guard isEnabled, seconds >= 1 else { return }
        stopRingingIfMain()
        state = .timer(seconds: seconds)
        setPrimaryMeta(name: name, rings: true)
        focusedID = nil
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

    // MARK: Extra timers

    var canAddTimer: Bool { extras.count < Self.maxExtras }

    /// Adds a named countdown (running unless `start` is false). Nil when full.
    @discardableResult
    func addCountdown(seconds: TimeInterval, name: String = "", start: Bool = true) -> UUID? {
        guard isEnabled, canAddTimer, seconds >= 1 else { return nil }
        var item = TimerItem(id: UUID(), name: Self.cleanName(name), kind: .countdown,
                             countdown: .timer(seconds: seconds), stopwatch: StopwatchState(), rings: true)
        if start { item.countdown.start(at: Date()) }
        extras.append(item)
        focusedID = item.id
        AppLog.log("Timer: added a \(Int(seconds))s countdown (\(extras.count) extra)")
        if start { requestNotificationsIfFirstStart() }
        extrasDidChange()
        return item.id
    }

    @discardableResult
    func addStopwatch(name: String = "", start: Bool = true) -> UUID? {
        guard isEnabled, canAddTimer else { return nil }
        var item = TimerItem(id: UUID(), name: Self.cleanName(name), kind: .stopwatch,
                             countdown: .timer(seconds: 60), stopwatch: StopwatchState(), rings: false)
        if start { item.stopwatch.start(at: Date()) }
        extras.append(item)
        focusedID = item.id
        AppLog.log("Timer: added a stopwatch (\(extras.count) extra)")
        extrasDidChange()
        return item.id
    }

    func item(_ id: UUID) -> TimerItem? { extras.first { $0.id == id } }

    /// Start, pause or resume an extra timer (nil: the main one).
    func toggle(_ id: UUID?) {
        guard let id else { return toggle() }
        guard isEnabled else { return }
        mutate(id) { item, now in
            switch item.kind {
            case .stopwatch:
                item.stopwatch.toggle(at: now)
            case .countdown:
                switch item.countdown.status {
                case .idle: item.countdown.start(at: now)
                case .running: item.countdown.pause(at: now)
                case .paused: item.countdown.resume(at: now)
                }
            }
        }
        if item(id)?.isRunning == true { requestNotificationsIfFirstStart() }
    }

    func reset(_ id: UUID?) {
        guard let id else { return reset() }
        if ringing?.includes(id) == true { stopRinging(reason: "reset") }
        mutate(id) { item, _ in
            item.countdown.reset()
            item.stopwatch.reset()
        }
    }

    func add(seconds: TimeInterval, to id: UUID?) {
        guard isEnabled else { return }
        guard let id else {
            state.add(seconds)
            stateDidChange()
            return
        }
        mutate(id) { item, _ in item.countdown.add(seconds) }
    }

    func lap(_ id: UUID) {
        mutate(id) { item, now in item.stopwatch.lap(at: now) }
    }

    func rename(_ id: UUID?, to name: String) {
        let clean = Self.cleanName(name)
        guard let id else {
            setPrimaryMeta(name: clean, rings: primaryRings)
            stateDidChange()
            return
        }
        mutate(id) { item, _ in item.name = clean }
    }

    func remove(_ id: UUID) {
        if ringing?.includes(id) == true { stopRinging(reason: "removed") }
        extras.removeAll { $0.id == id }
        if focusedID == id { focusedID = nil }
        removeNotification(for: id)
        extrasDidChange()
    }

    private func mutate(_ id: UUID, _ change: (inout TimerItem, Date) -> Void) {
        guard let index = extras.firstIndex(where: { $0.id == id }) else { return }
        change(&extras[index], Date())
        extrasDidChange()
    }

    private static func cleanName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    // MARK: Ringing

    /// Silences a ringing timer (Stop in the drawer, the notification, ⌃⌥⇧P).
    func stopRinging() {
        stopRinging(reason: "stopped")
    }

    /// Stops the ringing timers and runs each again for the snooze length.
    /// Their own length is kept: Reset afterwards goes back to it.
    func snooze() {
        guard let ringing else { return }
        let seconds = TimeInterval(preferences.snoozeMinutes * 60)
        stopRinging(reason: "snoozed")
        let date = Date()
        var extrasChanged = false
        for id in ringing.itemIDs {
            if let id {
                guard let index = extras.firstIndex(where: { $0.id == id }) else { continue }
                extras[index].countdown.snooze(for: seconds, at: date)
                extrasChanged = true
            } else if state.mode == .timer, state.isIdle {
                setPrimaryMeta(name: primaryName, rings: true)
                state.snooze(for: seconds, at: date)
                AppLog.log("Timer: started timer for \(Int(state.duration))s")
                requestNotificationsIfFirstStart()
                stateDidChange()
            }
        }
        if extrasChanged { extrasDidChange() }
        AppLog.log("Timer: snoozed \(preferences.snoozeMinutes) min")
    }

    func handleNotificationAction(_ action: String, timerID: String?) {
        switch action {
        case TimerNotificationRouter.snoozeActionID:
            if ringing == nil { snoozeEnded(timerID: timerID) } else { snooze() }
        case TimerNotificationRouter.stopActionID:
            stopRinging()
        default:
            // The banner itself: stop the sound and show the timers.
            stopRinging()
            PlannerRouter.shared.show(.timers)
        }
    }

    /// Snooze from a notification after the ringing timed out (or while
    /// SparkV wasn't running when it ended).
    /// Only the main timer's own notification snoozes the main timer, and
    /// only while it is idle: anything else (a deleted timer, the main one
    /// already running something new) snoozes as a new countdown.
    private func snoozeEnded(timerID: String?) {
        guard isEnabled else { return }
        let seconds = TimeInterval(preferences.snoozeMinutes * 60)
        let date = Date()
        if let timerID, let id = UUID(uuidString: timerID), let index = extras.firstIndex(where: { $0.id == id }) {
            if extras[index].kind == .countdown, extras[index].countdown.isIdle {
                extras[index].countdown.snooze(for: seconds, at: date)
                extrasDidChange()
            } else {
                addCountdown(seconds: seconds, name: extras[index].displayName)
            }
        } else if timerID == TimerEntry.primaryID, state.mode == .timer, state.isIdle {
            setPrimaryMeta(name: primaryName, rings: true)
            state.snooze(for: seconds, at: date)
            focusedID = nil
            stateDidChange()
        } else {
            addCountdown(seconds: seconds, name: "Snooze")
        }
    }

    private func startRinging(itemID: UUID?, title: String) {
        guard isEnabled else { return }
        if let current = ringing {
            // Another timer ended while one rings: one alarm for both.
            let ring = current.adding(itemID, title: title)
            ringing = ring
            AppLog.log("Timer: ringing \(ring.itemIDs.count) timers")
            postRinging(ring)
            return
        }
        ringSound?.stop()
        if !isSilent {
            let sound = NSSound(named: NSSound.Name(preferences.soundName)) ?? NSSound(named: "Glass")
            sound?.loops = true
            sound?.play()
            ringSound = sound
        }
        let ring = TimerRinging(itemID: itemID, title: title, since: Date())
        ringing = ring
        // Hovering the band opens Today: make sure Stop and Snooze are there.
        if PlannerRouter.shared.section != .timers { PlannerRouter.shared.section = .today }
        AppLog.log("Timer: ringing")
        postRinging(ring)
    }

    private func stopRinging(reason: String) {
        guard ringing != nil else { return }
        ringSound?.stop()
        ringSound = nil
        ringing = nil
        activities.dismiss(id: Self.ringingActivityID)
        if Self.canNotify {
            // The banner of the ended timer has done its job.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: allNotificationIDs)
        }
        AppLog.log("Timer: ringing \(reason)")
        restartTicker()
    }

    private func stopRingingIfMain() {
        if let ringing, ringing.includes(nil) { stopRinging(reason: "restarted") }
    }

    // MARK: Hotkey

    /// ⌃⌥⇧P: silence a ringing timer, else start or pause the main one.
    private func hotkeyPressed() {
        guard isEnabled else { return }
        if ringing != nil {
            stopRinging()
            return
        }
        toggle()
        // Keyboard-triggered: show the band at once, without waiting.
        if state.isRunning || state.isPaused { activities.peek(id: Self.activityID) }
    }

    private func updateHotkey() {
        let wanted = isStarted && isEnabled && preferences.hotkeyEnabled
        if wanted {
            if hotkey.shortcut != Self.hotkeyShortcut {
                isHotkeyRegistered = hotkey.register(Self.hotkeyShortcut)
                AppLog.log("Timer: shortcut \(Self.hotkeyShortcut.displayString) \(isHotkeyRegistered ? "registered" : "unavailable")")
            }
        } else if hotkey.isRegistered {
            hotkey.unregister()
            isHotkeyRegistered = false
        }
    }

    private func preferencesChanged() {
        updateHotkey()
        updateActivity()
        if Self.canNotify, isStarted { TimerNotificationRouter.shared.install(snoozeMinutes: preferences.snoozeMinutes) }
    }

    // MARK: Read-outs for views

    var remaining: TimeInterval { state.remaining(at: Date()) }
    var progress: Double { state.progress(at: Date()) }
    var isPending: Bool { state.isPending(at: Date()) }
    var remainingText: String { TimerFormat.clock(remaining) }
    var phaseTitle: String { TimerFormat.longName(of: state.phase) }
    var accent: Color { TimerFormat.color(of: state.phase) }
    /// "2/4" during Pomodoro.
    var sessionText: String? {
        state.mode == .pomodoro ? "\(state.sessionNumber)/\(Pomodoro.sessionsPerCycle)" : nil
    }

    /// The main timer as an entry.
    var primaryEntry: TimerEntry {
        let name = primaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimerEntry(
            id: TimerEntry.primaryID,
            itemID: nil,
            kind: state.mode == .pomodoro ? .pomodoro : .countdown,
            title: state.mode == .timer && !name.isEmpty ? name : TimerFormat.longName(of: state.phase),
            countdown: state,
            stopwatch: StopwatchState(),
            session: sessionText,
            accent: TimerFormat.color(of: state.phase)
        )
    }

    func entry(for item: TimerItem) -> TimerEntry {
        TimerEntry(
            id: item.id.uuidString,
            itemID: item.id,
            kind: item.kind == .stopwatch ? .stopwatch : .countdown,
            title: item.displayName,
            countdown: item.countdown,
            stopwatch: item.stopwatch,
            session: nil,
            accent: item.kind == .stopwatch ? TimerFormat.stopwatchColor : TimerFormat.countdownColor
        )
    }

    /// The main timer first, then the extra ones.
    var entries: [TimerEntry] { [primaryEntry] + extras.map(entry(for:)) }

    /// Timers running or paused, soonest change first.
    var activeEntries: [TimerEntry] {
        entries.filter { !$0.isIdle }.sorted { a, b in
            a.sortKey.0 != b.sortKey.0 ? a.sortKey.0 < b.sortKey.0 : a.sortKey.1 < b.sortKey.1
        }
    }

    /// What the Today slot shows.
    var focusedEntry: TimerEntry {
        if let focusedID, let item = item(focusedID) { return entry(for: item) }
        return primaryEntry
    }

    // MARK: Internals

    private func begin() {
        state.start(at: Date())
        AppLog.log("Timer: started \(state.phase.rawValue) for \(Int(state.duration))s")
        requestNotificationsIfFirstStart()
        stateDidChange()
    }

    private func setPrimaryMeta(name: String, rings: Bool) {
        primaryName = Self.cleanName(name)
        primaryRings = rings
        if let data = try? JSONEncoder().encode(PrimaryMeta(name: primaryName, rings: rings)) {
            defaults.set(data, forKey: Keys.primaryMeta)
        }
    }

    /// Persists, reschedules the notification, refreshes the band and the ticker.
    private func stateDidChange() {
        save()
        now = Date()
        scheduleNotification()
        updateActivity()
        restartTicker()
    }

    private func extrasDidChange() {
        saveExtras()
        now = Date()
        scheduleExtraNotifications()
        updateActivity()
        restartTicker()
    }

    /// Wakes once, at the soonest moment something must happen: a countdown
    /// ends or a ringing timer times out. Capped, so a clock change or a
    /// missed wake is caught within five minutes.
    private func restartTicker() {
        ticker?.cancel()
        ticker = nil
        guard isEnabled, let deadline = nextDeadline() else { return }
        let delay = min(300, max(0.05, deadline.timeIntervalSinceNow + 0.02))
        ticker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func nextDeadline() -> Date? {
        var deadlines: [Date] = []
        if let end = state.endsAt { deadlines.append(end) }
        for item in extras where item.kind == .countdown {
            if let end = item.countdown.endsAt { deadlines.append(end) }
        }
        if let ringing { deadlines.append(ringing.since.addingTimeInterval(TimeInterval(preferences.ringLimitSeconds))) }
        return deadlines.min()
    }

    /// Finishes whatever ended and times out the ringing.
    private func tick() {
        guard isEnabled else { return }
        let date = Date()
        now = date
        if let endsAt = state.endsAt, date >= endsAt {
            let overdue = date.timeIntervalSince(endsAt)
            // A long overshoot means the Mac slept through the end.
            finishPhase(celebrate: overdue < Self.staleCompletion)
        }
        finishEndedExtras(at: date)
        if let ringing, date.timeIntervalSince(ringing.since) >= TimeInterval(preferences.ringLimitSeconds) {
            stopRinging(reason: "timed out")
        }
        restartTicker()
    }

    /// The running phase reached zero. With `celebrate`, chime, show the
    /// celebration and (Pomodoro) start the next phase after a short pause;
    /// false when the end passed long ago. The notification needs nothing
    /// here: it was scheduled ahead for the end date and fires on its own.
    private func finishPhase(celebrate: Bool) {
        let finished = state.phase
        let wasPomodoro = state.mode == .pomodoro
        let title = primaryEntry.title
        let isNamed = !wasPomodoro && !primaryName.isEmpty
        state.advance(countFocus: true)
        let message = isNamed ? "\(title) is done" : TimerFormat.doneMessage(for: finished, next: state.phase)
        AppLog.log("Timer: \(finished.rawValue) done\(celebrate ? "" : " (while away)")")

        if celebrate {
            if wasPomodoro, Pomodoro.autoStartsNextPhase {
                state.start(at: Date(), after: Pomodoro.autoAdvancePause)
            }
            if !wasPomodoro, primaryRings, preferences.ringsUntilStopped {
                startRinging(itemID: nil, title: title)
            } else {
                playSound()
                postCelebration(message, accent: TimerFormat.color(of: finished))
            }
        }
        stateDidChange()
    }

    private func finishEndedExtras(at date: Date) {
        var changed = false
        for index in extras.indices where extras[index].kind == .countdown {
            guard let end = extras[index].countdown.endsAt, date >= end else { continue }
            let item = extras[index]
            extras[index].countdown.advance(countFocus: true)
            changed = true
            let overdue = date.timeIntervalSince(end)
            AppLog.log("Timer: extra countdown done\(overdue < Self.staleCompletion ? "" : " (while away)")")
            guard overdue < Self.staleCompletion else { continue }
            if item.rings, preferences.ringsUntilStopped {
                startRinging(itemID: item.id, title: item.displayName)
            } else {
                playSound()
                postCelebration("\(item.displayName) is done", accent: TimerFormat.countdownColor)
            }
        }
        if changed { extrasDidChange() }
    }

    private func playSound() {
        guard !isSilent else { return }
        let sound = NSSound(named: NSSound.Name(preferences.soundName)) ?? NSSound(named: "Glass")
        completionSound = sound
        sound?.play()
    }

    // MARK: Bands

    /// One live activity for every running timer: the soonest one rests
    /// beside the camera housing (ring + time, "+2" when more run); the band
    /// lists them all when it peeks.
    private func updateActivity() {
        let active = isEnabled && preferences.showsBesideNotch ? activeEntries : []
        guard let lead = active.first else {
            activities.dismiss(id: Self.activityID)
            return
        }
        let others = Array(active.dropFirst())
        // Order-free: pausing or reordering doesn't re-peek, a timer starting or ending does.
        let signature = active.map(\.id).sorted().joined(separator: ",")
        let count = others.count
        activities.post(LiveActivity(
            id: Self.activityID,
            kind: .timer,
            priority: 20,
            duration: nil,
            opensTab: .today,
            tint: lead.accent,
            // A timer starting or ending re-introduces the band for 4 s.
            peekKey: signature
        ) {
            TimerBandView(entries: active)
        }
        .compact {
            TimerCompactLeading(entry: lead)
        } trailing: {
            TimerCompactTrailing(entry: lead, extraCount: count)
        }
        .minimal {
            TimerCompactLeading(entry: lead)
        })
    }

    private func postCelebration(_ message: String, accent: Color) {
        activities.post(LiveActivity(
            id: Self.doneActivityID,
            kind: .timer,
            priority: 85,
            duration: 5,
            opensTab: .today
        ) {
            TimerDoneBandView(message: message, accent: accent)
        }
        .announcing(ActivityAnnouncementText.timerFinished(message), as: .timer, important: true))
    }

    private func postRinging(_ ring: TimerRinging) {
        let id = Self.ringingActivityID
        activities.post(LiveActivity(
            id: id,
            kind: .timer,
            priority: 85,
            duration: nil,
            opensTab: .today,
            symbol: "bell.and.waves.left.and.right.fill",
            peekKey: "ring.\(ring.since.timeIntervalSinceReferenceDate)"
        ) {
            TimerRingingBandView(sentence: ring.doneSentence)
        }
        .compact {
            TimerRingingGlyph(size: 13)
        } trailing: {
            Text("Done")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TimerFormat.countdownColor)
                .fixedSize()
        })
        // Long enough to notice; then the wings keep ringing quietly.
        activities.peek(id: id, for: 8)
    }

    // MARK: Notifications

    /// The first start asks for permission (through PermissionCenter, so it
    /// never stacks on another prompt); launch never does. A refusal is not
    /// re-asked or sent to Settings from here: the timer works without it.
    private func requestNotificationsIfFirstStart() {
        guard Self.canNotify, !defaults.bool(forKey: Keys.askedForNotifications) else { return }
        let defaults = self.defaults
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
            scheduleAllNotifications()
        }
    }

    private func refreshNotificationAuthorization() async {
        let status = await PermissionCenter.shared.freshStatus(.notifications)
        notificationsAuthorized = status.isGranted
        scheduleAllNotifications()
    }

    private func scheduleAllNotifications() {
        scheduleNotification()
        scheduleExtraNotifications()
    }

    private var allNotificationIDs: [String] {
        [Self.notificationID] + extras.map { Self.notificationID(for: $0.id) }
    }

    private static func notificationID(for id: UUID) -> String {
        "\(notificationID).\(id.uuidString)"
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
        let name = primaryName
        if state.mode == .timer, !name.isEmpty {
            content.title = "\(name) is done"
        } else {
            content.title = TimerFormat.doneMessage(for: finished, next: state.mode == .pomodoro ? next : .timer)
        }
        content.body = Self.notificationBody(finished: finished, next: next, mode: state.mode,
                                             seconds: state.duration)
        content.sound = .default
        if state.mode == .timer {
            content.categoryIdentifier = TimerNotificationRouter.categoryID
            content.userInfo = [TimerNotificationRouter.timerKey: TimerEntry.primaryID]
        }
        add(content, id: Self.notificationID, after: interval)
    }

    /// One pending notification per running extra countdown.
    private func scheduleExtraNotifications() {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: extras.map { Self.notificationID(for: $0.id) })
        guard isEnabled, notificationsAuthorized == true else { return }
        for item in extras where item.kind == .countdown {
            guard let end = item.countdown.endsAt else { continue }
            let interval = end.timeIntervalSinceNow
            guard interval >= 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(item.displayName) is done"
            content.body = "Your \(TimerDurationParser.spoken(item.countdown.duration)) timer is up."
            content.sound = .default
            content.categoryIdentifier = TimerNotificationRouter.categoryID
            content.userInfo = [TimerNotificationRouter.timerKey: item.id.uuidString]
            add(content, id: Self.notificationID(for: item.id), after: interval)
        }
    }

    private func removeNotification(for id: UUID) {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID(for: id)])
    }

    private func add(_ content: UNMutableNotificationContent, id: String, after interval: TimeInterval) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.log("Timer: couldn't schedule notification: \(error.localizedDescription)")
            }
        }
    }

    private static func notificationBody(
        finished: TimerState.Phase,
        next: TimerState.Phase,
        mode: TimerState.Mode,
        seconds: TimeInterval
    ) -> String {
        guard mode == .pomodoro else { return "Your \(TimerDurationParser.spoken(seconds)) timer is up." }
        switch next {
        case .shortBreak: return "\(Pomodoro.shortBreakMinutes)-minute break starts now."
        case .longBreak: return "\(Pomodoro.longBreakMinutes)-minute break — you finished a full cycle."
        case .focus, .timer: return "\(Pomodoro.focusMinutes)-minute focus session starts now."
        }
    }

    // MARK: Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Keys.state)
    }

    private func saveExtras() {
        guard let data = try? JSONEncoder().encode(extras) else { return }
        defaults.set(data, forKey: Keys.extras)
    }
}
