import Foundation

// Focus mode: value types shared by the controller, the store and the views.
// Everything here is pure (no AppKit, no singletons) so the headless harness
// can drive it with fixed dates.

// MARK: - Settings

/// What one tap starts. Stored in UserDefaults as JSON.
struct FocusSettings: Codable, Equatable, Sendable {
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    /// A long break replaces the short one after this many focus rounds.
    var longBreakEvery: Int = 4
    /// Focus rounds in one session; 0 runs until the user ends it.
    var rounds: Int = 1

    /// User-created shortcuts that turn Do Not Disturb on and off.
    var dndOnShortcut: String = FocusSettings.defaultOnShortcut
    var dndOffShortcut: String = FocusSettings.defaultOffShortcut
    /// Run those shortcuts when a session starts and ends.
    var usesDoNotDisturb: Bool = true

    /// Read focused-window titles (needs Accessibility, never prompted here).
    var tracksWindowTitles: Bool = true
    /// Write the end-of-session recap with the on-device model.
    var summarizesWithModel: Bool = true

    /// Apps and sites that get the gentle overlay while focusing.
    var blockedApps: [FocusBlockedApp] = []
    var blockedSites: [String] = []
    var blocksDistractions: Bool = true
    var snoozeMinutes: Int = 5

    /// The glowing border around the screens (see FocusEdgeGlow.swift).
    var edgeGlow: FocusEdgeGlowMode = .transitions
    /// The quick shake and pulse of the border and the notch band.
    var edgeGlowKick: Bool = true
    /// A haptic tap with the kick (felt on Force Touch trackpads).
    var edgeGlowHaptics: Bool = true
    /// Confetti when a session is completed.
    var edgeGlowConfetti: Bool = true

    static let defaultOnShortcut = "SparkV Focus On"
    static let defaultOffShortcut = "SparkV Focus Off"

    /// Quick presets for the drawer and the settings window.
    static let presets: [(focus: Int, rest: Int)] = [(25, 5), (50, 10), (90, 15)]

    /// Clamped copy, so a hand-edited default can't produce a zero-length phase.
    var sanitized: FocusSettings {
        var s = self
        s.focusMinutes = min(240, max(1, s.focusMinutes))
        s.shortBreakMinutes = min(60, max(1, s.shortBreakMinutes))
        s.longBreakMinutes = min(90, max(1, s.longBreakMinutes))
        s.longBreakEvery = min(12, max(2, s.longBreakEvery))
        s.rounds = min(12, max(0, s.rounds))
        s.snoozeMinutes = min(60, max(1, s.snoozeMinutes))
        s.blockedSites = FocusBlockRules.normalizedSites(s.blockedSites)
        var seen = Set<String>()
        s.blockedApps = s.blockedApps.filter { seen.insert($0.bundleID).inserted }
        return s
    }

    // Decoding tolerates missing keys so older saved settings keep working.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FocusSettings()
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? d.focusMinutes
        shortBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .shortBreakMinutes) ?? d.shortBreakMinutes
        longBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? d.longBreakMinutes
        longBreakEvery = try c.decodeIfPresent(Int.self, forKey: .longBreakEvery) ?? d.longBreakEvery
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? d.rounds
        dndOnShortcut = try c.decodeIfPresent(String.self, forKey: .dndOnShortcut) ?? d.dndOnShortcut
        dndOffShortcut = try c.decodeIfPresent(String.self, forKey: .dndOffShortcut) ?? d.dndOffShortcut
        usesDoNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .usesDoNotDisturb) ?? d.usesDoNotDisturb
        tracksWindowTitles = try c.decodeIfPresent(Bool.self, forKey: .tracksWindowTitles) ?? d.tracksWindowTitles
        summarizesWithModel = try c.decodeIfPresent(Bool.self, forKey: .summarizesWithModel) ?? d.summarizesWithModel
        blockedApps = try c.decodeIfPresent([FocusBlockedApp].self, forKey: .blockedApps) ?? d.blockedApps
        blockedSites = try c.decodeIfPresent([String].self, forKey: .blockedSites) ?? d.blockedSites
        blocksDistractions = try c.decodeIfPresent(Bool.self, forKey: .blocksDistractions) ?? d.blocksDistractions
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? d.snoozeMinutes
        // An unknown raw value (a newer build's option) falls back to the default.
        edgeGlow = (try? c.decodeIfPresent(FocusEdgeGlowMode.self, forKey: .edgeGlow)) ?? d.edgeGlow
        edgeGlowKick = try c.decodeIfPresent(Bool.self, forKey: .edgeGlowKick) ?? d.edgeGlowKick
        edgeGlowHaptics = try c.decodeIfPresent(Bool.self, forKey: .edgeGlowHaptics) ?? d.edgeGlowHaptics
        edgeGlowConfetti = try c.decodeIfPresent(Bool.self, forKey: .edgeGlowConfetti) ?? d.edgeGlowConfetti
    }
}

/// When the screen border glows.
enum FocusEdgeGlowMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    /// A burst when focus starts, a break starts and the session ends.
    case transitions
    /// The bursts, and a faint border that stays for the whole phase.
    case alwaysSubtle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .transitions: "At start, breaks and end"
        case .alwaysSubtle: "Always, subtly"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: "Off"
        case .transitions: "On changes"
        case .alwaysSubtle: "Always"
        }
    }
}

struct FocusBlockedApp: Codable, Equatable, Hashable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

// MARK: - Schedule

/// The focus/break sequence of one session, kept as dates (like TimerState)
/// so it keeps counting across sleep and relaunch.
struct FocusSchedule: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case focus, shortBreak, longBreak

        var isBreak: Bool { self != .focus }
    }

    var phase: Phase
    /// 1-based focus round the phase belongs to (during a break: the round just done).
    var round: Int
    var phaseStartedAt: Date
    var phaseDuration: TimeInterval
    /// Set while paused: time left in the phase.
    var pausedRemaining: TimeInterval?
    /// Focus time banked from finished (or partly run) focus phases.
    var bankedFocus: TimeInterval
    let plan: Plan

    struct Plan: Codable, Equatable, Sendable {
        var focus: TimeInterval
        var shortBreak: TimeInterval
        var longBreak: TimeInterval
        var longBreakEvery: Int
        /// 0 = open ended.
        var rounds: Int

        init(settings: FocusSettings) {
            let s = settings.sanitized
            focus = TimeInterval(s.focusMinutes * 60)
            shortBreak = TimeInterval(s.shortBreakMinutes * 60)
            longBreak = TimeInterval(s.longBreakMinutes * 60)
            longBreakEvery = s.longBreakEvery
            rounds = s.rounds
        }

        init(focus: TimeInterval, shortBreak: TimeInterval, longBreak: TimeInterval, longBreakEvery: Int, rounds: Int) {
            self.focus = focus
            self.shortBreak = shortBreak
            self.longBreak = longBreak
            self.longBreakEvery = longBreakEvery
            self.rounds = rounds
        }
    }

    init(plan: Plan, start: Date) {
        self.plan = plan
        phase = .focus
        round = 1
        phaseStartedAt = start
        phaseDuration = plan.focus
        pausedRemaining = nil
        bankedFocus = 0
    }

    var isPaused: Bool { pausedRemaining != nil }

    /// Nil while paused.
    var endsAt: Date? {
        isPaused ? nil : phaseStartedAt.addingTimeInterval(phaseDuration)
    }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        return max(0, phaseStartedAt.addingTimeInterval(phaseDuration).timeIntervalSince(now))
    }

    func elapsedInPhase(at now: Date) -> TimeInterval {
        max(0, phaseDuration - remaining(at: now))
    }

    func progress(at now: Date) -> Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, elapsedInPhase(at: now) / phaseDuration))
    }

    /// Focus time so far, counting the running focus phase.
    func focusedTime(at now: Date) -> TimeInterval {
        bankedFocus + (phase == .focus ? elapsedInPhase(at: now) : 0)
    }

    /// True when the session has a last round and this is it.
    var isLastRound: Bool { plan.rounds > 0 && round >= plan.rounds }

    mutating func pause(at now: Date) {
        guard !isPaused else { return }
        pausedRemaining = remaining(at: now)
    }

    mutating func resume(at now: Date) {
        guard let left = pausedRemaining else { return }
        pausedRemaining = nil
        phaseStartedAt = now.addingTimeInterval(left - phaseDuration)
    }

    mutating func extend(by seconds: TimeInterval) {
        phaseDuration += seconds
        if let left = pausedRemaining { pausedRemaining = left + seconds }
    }

    /// What follows the current phase, or nil when the session is complete.
    /// The last focus round ends the session: there is no trailing break.
    func nextPhase() -> (phase: Phase, round: Int)? {
        switch phase {
        case .focus:
            if isLastRound { return nil }
            return (round % plan.longBreakEvery == 0 ? .longBreak : .shortBreak, round)
        case .shortBreak, .longBreak:
            return (.focus, round + 1)
        }
    }

    /// Ends the current phase at `boundary` (its scheduled end, or now when
    /// skipping) and starts the next one there. Returns false, leaving the
    /// schedule on its last phase, when the session is complete.
    @discardableResult
    mutating func advance(at boundary: Date) -> Bool {
        if phase == .focus { bankedFocus += min(phaseDuration, elapsedInPhase(at: boundary)) }
        guard let next = nextPhase() else {
            // Freeze the finished phase so focusedTime doesn't double count.
            pausedRemaining = nil
            phaseDuration = 0
            phaseStartedAt = boundary
            return false
        }
        phase = next.phase
        round = next.round
        phaseStartedAt = boundary
        pausedRemaining = nil
        phaseDuration = switch next.phase {
        case .focus: plan.focus
        case .shortBreak: plan.shortBreak
        case .longBreak: plan.longBreak
        }
        return true
    }

    /// Planned end of the whole session when every phase runs as scheduled,
    /// nil for open-ended sessions.
    func plannedEnd() -> Date? {
        guard plan.rounds > 0, let endsAt else { return nil }
        var copy = self
        var end = endsAt
        while copy.advance(at: end), let next = copy.endsAt { end = next }
        return end
    }
}

// MARK: - Activity during a session

/// Time spent in one app while focusing.
struct FocusAppUsage: Codable, Equatable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    var seconds: TimeInterval
    var id: String { bundleID }
}

/// A window or document the user worked in (title only, from Accessibility).
struct FocusDocumentUsage: Codable, Equatable, Sendable, Identifiable {
    var title: String
    var appName: String
    var seconds: TimeInterval
    var id: String { appName + "\u{1F}" + title }
}

/// Something SparkV recorded during the session.
struct FocusArtifact: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case dictation, note, tray, meeting, spaceItem

        var label: String {
            switch self {
            case .dictation: "Flow dictation"
            case .note: "Flow note"
            case .tray: "Tray item"
            case .meeting: "Meeting note"
            case .spaceItem: "Space item"
            }
        }

        func countLabel(_ count: Int) -> String {
            let base: String = switch self {
            case .dictation: "dictation"
            case .note: "note"
            case .tray: "Tray item"
            case .meeting: "meeting"
            case .spaceItem: "Space item"
            }
            return "\(count) \(base)\(count == 1 ? "" : "s")"
        }

        var systemImage: String {
            switch self {
            case .dictation: "waveform"
            case .note: "note.text"
            case .tray: "tray.full.fill"
            case .meeting: "person.2.wave.2.fill"
            case .spaceItem: "square.stack.3d.up.fill"
            }
        }
    }

    var id: String
    var kind: Kind
    /// Short, single-line title (the summary never needs the full text).
    var title: String
    var date: Date

    init(id: String, kind: Kind, title: String, date: Date) {
        self.id = id
        self.kind = kind
        self.title = FocusText.clip(title, 80)
        self.date = date
    }
}

/// A distraction the overlay caught.
struct FocusInterruption: Codable, Equatable, Sendable {
    var target: String
    var date: Date
    /// The user chose "5 more minutes".
    var snoozed: Bool
}

// MARK: - Saved session

struct FocusSessionRecord: Codable, Equatable, Sendable, Identifiable {
    enum EndReason: String, Codable, Sendable {
        case completed, stopped, expired
    }

    let id: UUID
    var startedAt: Date
    var endedAt: Date
    var focusedSeconds: TimeInterval
    var plannedFocusMinutes: Int
    var roundsCompleted: Int
    var endReason: EndReason
    var apps: [FocusAppUsage]
    var documents: [FocusDocumentUsage]
    var artifacts: [FocusArtifact]
    var interruptions: [FocusInterruption]
    var mutedSystemNotifications: Bool
    var summary: String
    var summaryBy: String

    var focusedMinutes: Int { Int((focusedSeconds / 60).rounded()) }

    func count(of kind: FocusArtifact.Kind) -> Int { artifacts.filter { $0.kind == kind }.count }
}

/// Today / this week numbers for the drawer, the summary footer and settings.
struct FocusStats: Equatable, Sendable {
    var todaySeconds: TimeInterval = 0
    var todaySessions = 0
    var weekSeconds: TimeInterval = 0
    var weekSessions = 0
    /// Last seven days, oldest first; each entry is that day's focused seconds.
    var days: [(date: Date, seconds: TimeInterval)] = []
    /// Consecutive days, ending today (or yesterday), with any focus.
    var streakDays = 0

    static func == (lhs: FocusStats, rhs: FocusStats) -> Bool {
        lhs.todaySeconds == rhs.todaySeconds && lhs.todaySessions == rhs.todaySessions
            && lhs.weekSeconds == rhs.weekSeconds && lhs.weekSessions == rhs.weekSessions
            && lhs.streakDays == rhs.streakDays
            && lhs.days.map(\.seconds) == rhs.days.map(\.seconds)
    }

    static func compute(_ sessions: [FocusSessionRecord], now: Date, calendar: Calendar = .current) -> FocusStats {
        var stats = FocusStats()
        let today = calendar.startOfDay(for: now)
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: today) else { return stats }
        var perDay: [Date: TimeInterval] = [:]
        for s in sessions {
            let day = calendar.startOfDay(for: s.startedAt)
            perDay[day, default: 0] += s.focusedSeconds
            if day == today {
                stats.todaySeconds += s.focusedSeconds
                stats.todaySessions += 1
            }
            if day >= weekStart && day <= today {
                stats.weekSeconds += s.focusedSeconds
                stats.weekSessions += 1
            }
        }
        stats.days = (0..<7).compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return (d, perDay[d] ?? 0)
        }
        // Streak: today counts if focused; otherwise start from yesterday.
        var cursor = (perDay[today] ?? 0) > 0 ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while (perDay[cursor] ?? 0) >= 60 {
            stats.streakDays += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return stats
    }
}

// MARK: - Formatting

enum FocusText {
    /// "25 min", "1 h 05 min", "<1 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds > 0 && minutes == 0 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "25m", "1h05", for tight spots (tiles, chips).
    static func compact(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    /// "18:42", rounding up so a fresh 25 minutes reads 25:00.
    static func clock(_ remaining: TimeInterval) -> String {
        let total = Int(max(0, remaining).rounded(.up))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// One line, at most `limit` characters.
    static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}
