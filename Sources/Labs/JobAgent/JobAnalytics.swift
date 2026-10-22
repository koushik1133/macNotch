import Foundation

/// Tracker analytics: applications per week, response rate, average fit,
/// top missing skills across applied jobs, status funnel.
struct JobAnalytics: Sendable, Equatable {
    struct Week: Sendable, Equatable, Identifiable {
        var start: Date
        var count: Int
        var id: Date { start }
    }

    struct FunnelStage: Sendable, Equatable, Identifiable {
        var name: String
        var count: Int
        var id: String { name }
    }

    var totalTracked = 0
    var totalApplied = 0
    var responded = 0
    var interviews = 0
    var offers = 0
    var rejections = 0
    var ghosted = 0
    /// Applied, past the expected response date, no answer yet.
    var overdue = 0
    /// Not applied yet, application deadline within the next 7 days.
    var closingSoon = 0
    var responseRate: Double = 0
    var averageFitApplied: Double?
    var averageFitAll: Double?
    var weeks: [Week] = []
    var topMissingSkills: [(skill: String, count: Int)] = []
    var funnel: [FunnelStage] = []
    var statusCounts: [JobStatus: Int] = [:]

    static func == (lhs: JobAnalytics, rhs: JobAnalytics) -> Bool {
        lhs.totalTracked == rhs.totalTracked && lhs.totalApplied == rhs.totalApplied && lhs.responded == rhs.responded
            && lhs.weeks == rhs.weeks && lhs.funnel == rhs.funnel && lhs.averageFitApplied == rhs.averageFitApplied
            && lhs.topMissingSkills.map(\.skill) == rhs.topMissingSkills.map(\.skill)
    }

    static func compute(_ jobs: [JobApplication], now: Date = Date(), weeksBack: Int = 12) -> JobAnalytics {
        var a = JobAnalytics()
        a.totalTracked = jobs.count
        let applied = jobs.filter(\.everApplied)
        a.totalApplied = applied.count
        a.responded = applied.filter(\.gotResponse).count
        a.interviews = jobs.filter { $0.maxFunnelRank >= 2 }.count
        a.offers = jobs.filter { $0.maxFunnelRank >= 3 }.count
        a.rejections = jobs.filter { $0.status == .rejected }.count
        a.ghosted = jobs.filter { $0.status == .ghosted }.count
        a.overdue = jobs.filter { $0.status == .applied && ($0.expectedResponseAt ?? .distantFuture) < now }.count
        a.closingSoon = jobs.filter { ($0.daysUntilDeadline(now: now) ?? .max) <= 7 }.count
        a.responseRate = applied.isEmpty ? 0 : Double(a.responded) / Double(applied.count)
        let appliedFits = applied.compactMap { $0.fit?.overall }
        a.averageFitApplied = appliedFits.isEmpty ? nil : Double(appliedFits.reduce(0, +)) / Double(appliedFits.count)
        let allFits = jobs.compactMap { $0.fit?.overall }
        a.averageFitAll = allFits.isEmpty ? nil : Double(allFits.reduce(0, +)) / Double(allFits.count)

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        var weeks: [Week] = (0..<weeksBack).reversed().compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek).map { Week(start: $0, count: 0) }
        }
        for job in applied {
            guard let date = job.appliedAt ?? job.history.first(where: { $0.status == .applied })?.date,
                  let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start,
                  let index = weeks.firstIndex(where: { $0.start == start }) else { continue }
            weeks[index].count += 1
        }
        a.weeks = weeks

        var missing: [String: Int] = [:]
        for job in applied { for skill in job.fit?.missingSkills ?? [] { missing[skill, default: 0] += 1 } }
        a.topMissingSkills = missing.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8).map { (skill: $0.key, count: $0.value) }

        a.funnel = [
            FunnelStage(name: "Tracked", count: jobs.count),
            FunnelStage(name: "Applied", count: applied.count),
            FunnelStage(name: "Responded", count: a.responded),
            FunnelStage(name: "Interview", count: a.interviews),
            FunnelStage(name: "Offer", count: a.offers),
        ]
        for status in JobStatus.allCases { a.statusCounts[status] = jobs.filter { $0.status == status }.count }
        return a
    }
}
