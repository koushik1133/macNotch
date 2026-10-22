import Foundation

// The decision logic, free of timers and cameras: feed it readings with
// their timestamps (and `tick` it), and it says when to warn and when the
// warning may end. Mirrors iOS Screen Distance: a warning only after being
// too close for a while, a Continue that unlocks only once you are back at a
// safe distance, and a notice that clears itself when you move back.

struct ScreenDistanceTracker: Sendable {
    struct Config: Equatable, Sendable {
        /// Closer than this counts as too close.
        var thresholdCM: Double = 40
        /// How long you must stay too close before the warning.
        var triggerSeconds: TimeInterval = 8
        /// Hysteresis: the warning clears only beyond threshold + margin.
        var clearMarginCM: Double = 5
        /// "Approaching" is forgotten when no close reading arrived for this long.
        var staleSeconds: TimeInterval = 12
        /// Once at a safe distance, the notice fades out after this long.
        var autoDismissSeconds: TimeInterval = 1.5
        /// With no face during a warning (you left), it ends after this long.
        var faceLostDismissSeconds: TimeInterval = 20
        /// After Esc/Skip, no new warning for this long unless you first move
        /// back to a safe distance (otherwise it would return 8 s later).
        var skipCooldownSeconds: TimeInterval = 300

        var clearDistanceCM: Double { thresholdCM + clearMarginCM }
    }

    enum Phase: Equatable, Sendable {
        case safe
        case approaching(since: Date, lastClose: Date)
        case alerting(since: Date, lastFace: Date)
        /// Back at a safe distance; Continue is enabled and the notice fades soon.
        case cleared(at: Date, alertSince: Date)
    }

    enum EndReason: Equatable, Sendable {
        case movedBack, continued, skipped, faceLost
    }

    enum Event: Equatable, Sendable {
        case alertBegan
        case safeToContinue
        case closeAgain
        case alertEnded(EndReason)
    }

    var config: Config
    private(set) var phase: Phase = .safe
    /// Set by a skip: closeness is ignored until then, or until a safe reading.
    private(set) var suppressedUntil: Date?

    init(config: Config = Config()) {
        self.config = config
    }

    var isAlerting: Bool {
        switch phase {
        case .alerting, .cleared: true
        case .safe, .approaching: false
        }
    }

    var canContinue: Bool {
        if case .cleared = phase { return true }
        return false
    }

    var isApproaching: Bool {
        if case .approaching = phase { return true }
        return false
    }

    mutating func reset() { phase = .safe }

    @discardableResult
    mutating func ingest(_ reading: ScreenDistanceReading, at now: Date) -> [Event] {
        var events = tick(at: now)
        let distance = reading.centimeters

        switch phase {
        case .safe:
            if let until = suppressedUntil {
                if now >= until || (distance.map { $0 > config.clearDistanceCM } ?? false) {
                    suppressedUntil = nil
                } else {
                    break
                }
            }
            guard let d = distance, d < config.thresholdCM else { break }
            phase = .approaching(since: now, lastClose: now)
            if config.triggerSeconds <= 0 {
                phase = .alerting(since: now, lastFace: now)
                events.append(.alertBegan)
            }

        case .approaching(let since, let lastClose):
            if let d = distance {
                if d < config.thresholdCM {
                    if now.timeIntervalSince(since) >= config.triggerSeconds {
                        phase = .alerting(since: now, lastFace: now)
                        events.append(.alertBegan)
                    } else {
                        phase = .approaching(since: since, lastClose: now)
                    }
                } else {
                    phase = .safe
                }
            } else if now.timeIntervalSince(lastClose) > config.staleSeconds {
                phase = .safe
            }

        case .alerting(let since, _):
            guard let d = distance else { break }
            if d > config.clearDistanceCM {
                phase = .cleared(at: now, alertSince: since)
                events.append(.safeToContinue)
            } else {
                phase = .alerting(since: since, lastFace: now)
            }

        case .cleared(_, let alertSince):
            // Between threshold and threshold + margin the notice stays
            // cleared; only coming closer than the threshold re-arms it.
            if let d = distance, d < config.thresholdCM {
                phase = .alerting(since: alertSince, lastFace: now)
                events.append(.closeAgain)
            }
        }
        return events
    }

    /// Time-based transitions; call every second or so while a warning shows.
    @discardableResult
    mutating func tick(at now: Date) -> [Event] {
        switch phase {
        case .cleared(let at, _) where now.timeIntervalSince(at) >= config.autoDismissSeconds:
            phase = .safe
            return [.alertEnded(.movedBack)]
        case .alerting(_, let lastFace) where now.timeIntervalSince(lastFace) >= config.faceLostDismissSeconds:
            phase = .safe
            return [.alertEnded(.faceLost)]
        case .approaching(_, let lastClose) where now.timeIntervalSince(lastClose) > config.staleSeconds:
            phase = .safe
            return []
        default:
            return []
        }
    }

    /// Continue (allowed once safe) or Esc/skip (only when skipping is allowed).
    /// With `now`, a skip also starts the skip cooldown.
    mutating func acknowledge(skip: Bool, allowSkipping: Bool, at now: Date? = nil) -> Event? {
        if canContinue {
            phase = .safe
            return .alertEnded(.continued)
        }
        if skip, allowSkipping, isAlerting {
            phase = .safe
            if let now, config.skipCooldownSeconds > 0 {
                suppressedUntil = now.addingTimeInterval(config.skipCooldownSeconds)
            }
            return .alertEnded(.skipped)
        }
        return nil
    }
}

// MARK: - Daily stats

struct ScreenDistanceDayStats: Codable, Equatable, Sendable {
    /// "yyyy-MM-dd" in the user's calendar and time zone.
    var day: String
    var tooCloseSeconds: Double = 0
    var warnings: Int = 0

    var tooCloseMinutes: Int { Int((tooCloseSeconds / 60).rounded(.down)) }

    /// "12 min too close · 3 warnings"
    var summary: String {
        let time: String
        if tooCloseSeconds < 60 {
            time = tooCloseSeconds < 1 ? "0 min" : "<1 min"
        } else {
            time = "\(tooCloseMinutes) min"
        }
        return "\(time) too close · \(warnings) warning\(warnings == 1 ? "" : "s")"
    }
}

/// Per-day totals (the last two weeks), plus the time of the last close
/// reading so time between two close readings can be counted.
struct ScreenDistanceStatsLog: Codable, Equatable, Sendable {
    var days: [String: ScreenDistanceDayStats] = [:]
    var lastCloseAt: Date?
    static let keptDays = 14

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func stats(for date: Date, calendar: Calendar) -> ScreenDistanceDayStats {
        let key = Self.dayKey(for: date, calendar: calendar)
        return days[key] ?? ScreenDistanceDayStats(day: key)
    }

    mutating func recordWarning(at date: Date, calendar: Calendar) {
        let key = Self.dayKey(for: date, calendar: calendar)
        days[key, default: ScreenDistanceDayStats(day: key)].warnings += 1
        prune(now: date, calendar: calendar)
    }

    /// Call with every distance reading. Time between two consecutive close
    /// readings (at most `maxGap` apart, so a pause isn't counted) is added,
    /// split across midnight when it spans it.
    mutating func recordReading(isClose: Bool, at date: Date, calendar: Calendar, maxGap: TimeInterval) {
        defer { lastCloseAt = isClose ? date : nil }
        guard isClose, let previous = lastCloseAt else { return }
        let gap = date.timeIntervalSince(previous)
        guard gap > 0, gap <= maxGap else { return }
        addTooClose(from: previous, to: date, calendar: calendar)
    }

    mutating func addTooClose(from start: Date, to end: Date, calendar: Calendar) {
        var cursor = start
        while cursor < end {
            let nextMidnight = calendar.nextDate(
                after: cursor, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime
            ) ?? end
            let segmentEnd = min(end, nextMidnight)
            let key = Self.dayKey(for: cursor, calendar: calendar)
            days[key, default: ScreenDistanceDayStats(day: key)].tooCloseSeconds += segmentEnd.timeIntervalSince(cursor)
            cursor = segmentEnd
        }
        prune(now: end, calendar: calendar)
    }

    private mutating func prune(now: Date, calendar: Calendar) {
        guard days.count > Self.keptDays,
              let cutoff = calendar.date(byAdding: .day, value: -(Self.keptDays - 1), to: now)
        else { return }
        let cutoffKey = Self.dayKey(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }
    }
}
