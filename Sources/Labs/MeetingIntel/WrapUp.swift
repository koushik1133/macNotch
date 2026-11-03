import AppKit
import EventKit
import SwiftUI

// Meeting Intelligence, part C: the wrap-up after a call (DESIGN.md §6).
//
// - A peek band in the notch ("Design sync · 32 min · 3 tasks for you ·
//   2 decisions  [Review]") and a wrap-up panel with, down one thread line:
//   summary, moments, talk time, tasks -> Reminders, follow-up draft, file
//   into a Space.
// - Nothing leaves SparkV without a click: the follow-up is only opened as a
//   draft in the mail app (mailto) or copied; Reminders are created only from
//   ticked items after "Add N to Reminders", and permission is asked only
//   then, through `MeetingRemindersGate` (PermissionCenter); a Space is filed
//   only on "File". The on-device model polishes the draft; Groq is used only
//   when MeetingAssistant.allowGroqForMeetings is on.
//
// This file depends only on shared types (MeetingIntelModels.swift,
// MeetingModels, Spaces models, LiveActivity, SparkVTheme, MeetingAIBackend).
// The app adapters (MeetingAssistant, SpaceStore, SpaceConnectors, the
// keychain) live in wrapup-AppAdapters.swift, including the contract's
// `init(activities:assistant:spaces:reminders:store:)`.
//
// Additions beyond DESIGN.md (all in this file, shared types unchanged):
// - `MeetingWrapUpSource` / `MeetingWrapUpSpaces` protocols (test seams).
// - `MeetingWrapUpModel` also carries serviceName, attendees, generatedBy.
// - `MeetingFollowUpWriter.draft(record:attendees:userName:flags:)` overload
//   that folds in live decision / action flags not already in the notes.
// - `MeetingReminderWriter.add(...url:)` overload (sparkv:// link only when
//   the scheme is registered).
// - `MeetingRemindersUnavailableGate` until PermissionCenter has `.reminders`.
// - Own moments list (`MeetingWrapUpMomentRow`) so C does not depend on B's
//   `MeetingFlagTimeline`; swap it in once B lands if preferred.

// MARK: - Seams

/// Where the wrap-up reads meetings from (MeetingAssistant in the app).
@MainActor
protocol MeetingWrapUpSource: AnyObject {
    func record(id: UUID) -> MeetingRecord?
    /// True while that meeting is still recording or its minutes are being written.
    func isWritingNotes(for id: UUID) -> Bool
    /// MeetingAssistant.allowGroqForMeetings.
    var allowsGroq: Bool { get }
    func openNotes(meetingID: UUID)
}

/// The part of SpaceStore the wrap-up uses.
@MainActor
protocol MeetingWrapUpSpaces: AnyObject {
    var spaces: [Space] { get }
    var items: [SpaceItem] { get }
    func ingest(_ input: SpaceIngestInput) async -> SpaceItem?
    func move(itemID: UUID, to spaceID: UUID?)
    func search(_ query: String, in spaceID: UUID?) async -> [SpaceItem]
    /// SpaceConnectors.meetingInput in the app.
    func ingestInput(for record: MeetingRecord, attendees: [String]) -> SpaceIngestInput?
}

/// Used until PermissionCenter has `.reminders` (INTEGRATION.md steps 3–5): the
/// Reminders button is replaced by "Reminders isn't connected yet".
@MainActor
final class MeetingRemindersUnavailableGate: MeetingRemindersGate {
    init() {}
    func status() -> MeetingRemindersAccess { .unavailable }
    func request(from feature: String) async -> Bool { false }
}

// MARK: - Model

struct MeetingWrapUpModel: Equatable {
    var meetingID: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var notes: MeetingNotes?
    var flags: [MeetingFlag]
    var talk: MeetingTalkStats?
    var proposals: [MeetingReminderProposal]
    var draft: MeetingFollowUpDraft
    var suggestedSpaceID: UUID?
    var state: MeetingWrapUpState
    var serviceName: String? = nil
    var attendees: [MeetingAttendee] = []
    var generatedBy: String? = nil

    /// Decisions from the notes plus flagged ones not already there.
    var decisions: [String] { MeetingWrapUpBuilder.decisions(notes: notes, flags: flags) }
    var myTaskCount: Int { proposals.count }
    var momentCount: Int { flags.filter { $0.kind == .bookmark && !$0.isDismissed }.count }
    var remindedCount: Int { proposals.filter { $0.reminderID != nil }.count }
    var selectedCount: Int { proposals.filter { $0.isSelected && $0.reminderID == nil }.count }
}

/// One row of the Space picker ("Acme / Design").
struct MeetingWrapUpSpaceChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    var path: String
}

// MARK: - Pure building blocks

enum MeetingWrapUpBuilder {
    /// Marker stored in `reminderID` for items added in an earlier session
    /// (the sidecar keeps only which tasks were added).
    static let alreadyAdded = "added"

    static func decisions(notes: MeetingNotes?, flags: [MeetingFlag]) -> [String] {
        let fromNotes = (notes?.decisions ?? []).map(clean).filter { !$0.isEmpty }
        let flagged = flags.filter { $0.kind == .decision && !$0.isDismissed }.sorted { $0.at < $1.at }.map { clean($0.text) }
        var out = fromNotes
        for line in flagged where !line.isEmpty && !out.contains(where: { MeetingAIText.similarity($0, line) >= 0.6 }) {
            out.append(line)
        }
        return out
    }

    /// Action-item flags the notes don't already cover.
    static func extraActionFlags(notes: MeetingNotes?, flags: [MeetingFlag], mineOnly: Bool) -> [MeetingFlag] {
        let tasks = (notes?.myTasks ?? []) + (mineOnly ? [] : (notes?.othersTasks ?? []))
        var kept: [MeetingFlag] = []
        for flag in flags.sorted(by: { $0.at < $1.at })
        where flag.kind == .actionItem && !flag.isDismissed && (!mineOnly || flag.isMine) {
            let text = clean(flag.text)
            guard !text.isEmpty else { continue }
            if tasks.contains(where: { MeetingAIText.similarity($0.task, text) >= 0.6 }) { continue }
            if kept.contains(where: { MeetingAIText.similarity($0.text, text) >= 0.6 }) { continue }
            kept.append(flag)
        }
        return kept
    }

    /// My not-done tasks (+ my action flags not in the notes), all unticked.
    static func proposals(notes: MeetingNotes?, flags: [MeetingFlag], state: MeetingWrapUpState,
                          now: Date, calendar: Calendar) -> [MeetingReminderProposal] {
        let added = Set(state.remindedTaskIDs)
        func make(id: UUID, title: String, due: String?) -> MeetingReminderProposal {
            MeetingReminderProposal(
                id: id, actionItemID: id, title: title,
                dueDate: due.flatMap { MeetingDueDateParser.date(from: $0, relativeTo: now, calendar: calendar) },
                dueText: due, isSelected: false,
                reminderID: added.contains(id) ? alreadyAdded : nil
            )
        }
        var out = (notes?.myTasks ?? []).filter { !$0.isDone }.map { make(id: $0.id, title: clean($0.task), due: $0.due) }
        out += extraActionFlags(notes: notes, flags: flags, mineOnly: true).map { make(id: $0.id, title: clean($0.text), due: $0.due) }
        return out.filter { !$0.title.isEmpty }
    }

    static func model(record: MeetingRecord, session: MeetingIntelSession?, sidecar: MeetingIntelSidecar?,
                      userName: String, now: Date, calendar: Calendar,
                      monologueThreshold: TimeInterval) -> MeetingWrapUpModel {
        let flags = sidecar?.visibleFlags ?? []
        let state = sidecar?.wrapUp ?? MeetingWrapUpState()
        let attendees = session?.brief?.attendees ?? []
        let talk = sidecar?.talk ?? {
            let stats = MeetingTalkTime.compute(record.segments, monologueThreshold: monologueThreshold)
            return stats.total > 0 ? stats : nil
        }()
        return MeetingWrapUpModel(
            meetingID: record.id,
            title: record.title,
            date: record.startedAt,
            duration: max(0, (record.endedAt ?? now).timeIntervalSince(record.startedAt)),
            notes: record.notes,
            flags: flags,
            talk: talk,
            proposals: proposals(notes: record.notes, flags: flags, state: state, now: now, calendar: calendar),
            draft: MeetingFollowUpWriter.draft(record: record, attendees: attendees, userName: userName, flags: flags),
            suggestedSpaceID: state.filedSpaceID,
            state: state,
            serviceName: session?.serviceName ?? sidecar?.serviceName,
            attendees: attendees,
            generatedBy: record.notes?.generatedBy
        )
    }

    /// Nothing to wrap up: no notes, no speech, no flags.
    static func isWorthShowing(_ model: MeetingWrapUpModel) -> Bool {
        model.notes != nil || !model.flags.isEmpty || (model.talk?.total ?? 0) > 20
    }

    /// "Acme / Design" paths for the current persona's Spaces, sorted.
    static func spaceChoices(_ spaces: [Space]) -> [MeetingWrapUpSpaceChoice] {
        let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ space: Space) -> String {
            var names = [space.name]
            var parent = space.parentID
            var guardCount = 0
            while let id = parent, let next = byID[id], guardCount < 8 {
                names.insert(next.name, at: 0)
                parent = next.parentID
                guardCount += 1
            }
            return names.joined(separator: " / ")
        }
        return spaces.map { MeetingWrapUpSpaceChoice(id: $0.id, path: path($0)) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -•*").union(.whitespacesAndNewlines))
    }
}

/// The follow-up email, written by a template (no model), DESIGN.md §6.
enum MeetingFollowUpWriter {
    static func draft(record: MeetingRecord, attendees: [MeetingAttendee], userName: String) -> MeetingFollowUpDraft {
        draft(record: record, attendees: attendees, userName: userName, flags: [])
    }

    static func draft(record: MeetingRecord, attendees: [MeetingAttendee], userName: String,
                      flags: [MeetingFlag]) -> MeetingFollowUpDraft {
        let me = firstName(userName)
        let others = attendees.filter { !$0.isMe }
        var seen = Set<String>()
        let to = others.compactMap { $0.email?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") && seen.insert($0).inserted }

        let title = MeetingWrapUpBuilder.clean(record.title)
        let subject = "Recap: \(title.isEmpty ? "our meeting" : title) (\(shortDate(record.startedAt)))"

        var names: [String] = []
        for name in others.map(\.firstName) where !name.isEmpty && !names.contains(name) { names.append(name) }
        let greeting: String
        switch names.count {
        case 1: greeting = "Hi \(names[0]),"
        case 2: greeting = "Hi \(names[0]) and \(names[1]),"
        case 3: greeting = "Hi \(names[0]), \(names[1]) and \(names[2]),"
        default: greeting = "Hi all,"
        }

        let notes = record.notes
        let decisions = MeetingWrapUpBuilder.decisions(notes: notes, flags: flags)
        var steps: [String] = []
        for task in (notes?.myTasks ?? []) + (notes?.othersTasks ?? []) {
            let text = MeetingWrapUpBuilder.clean(task.task)
            guard !text.isEmpty else { continue }
            let owner = task.isMine ? me : MeetingWrapUpBuilder.clean(task.owner)
            steps.append(stepLine(owner: owner, task: text, due: task.due))
        }
        for flag in MeetingWrapUpBuilder.extraActionFlags(notes: notes, flags: flags, mineOnly: false) {
            let owner = flag.isMine ? me : (flag.owner.map(MeetingWrapUpBuilder.clean) ?? "")
            steps.append(stepLine(owner: owner, task: MeetingWrapUpBuilder.clean(flag.text), due: flag.due))
        }
        if steps.isEmpty {
            steps = (notes?.nextSteps ?? []).map(MeetingWrapUpBuilder.clean).filter { !$0.isEmpty }.map { "- \($0)" }
        }
        let questions = (notes?.openQuestions ?? []).map(MeetingWrapUpBuilder.clean).filter { !$0.isEmpty }

        var lines = [greeting, ""]
        let hasRecap = !decisions.isEmpty || !steps.isEmpty || !questions.isEmpty
        lines.append(hasRecap ? "Thanks for the time today. Quick recap:" : "Thanks for the time today.")
        if !decisions.isEmpty {
            lines += ["", "Decisions"] + decisions.map { "- \($0)" }
        }
        if !steps.isEmpty {
            lines += ["", "Next steps"] + steps
        }
        if !questions.isEmpty {
            lines += ["", "Open questions"] + questions.map { "- \($0)" }
        }
        lines += ["", "Best,", me]
        return MeetingFollowUpDraft(to: to, subject: subject, body: lines.joined(separator: "\n"))
    }

    private static func stepLine(owner: String, task: String, due: String?) -> String {
        let due = due.map(MeetingWrapUpBuilder.clean).flatMap { $0.isEmpty ? nil : $0 }
        let head = owner.isEmpty ? "- \(task)" : "- \(owner): \(task)"
        return due.map { "\(head) (\($0))" } ?? head
    }

    static func firstName(_ userName: String) -> String {
        let first = userName.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)
        return first ?? userName
    }

    /// "Thu 22 Oct" (fixed English format: the template is English).
    static func shortDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }
}

/// Spoken due phrases -> a date (pure). 9:00 unless the phrase says
/// otherwise (EOD/today/end of week 17:00, "afternoon" 14:00, "3pm").
enum MeetingDueDateParser {
    static func date(from spoken: String, relativeTo now: Date, calendar: Calendar) -> Date? {
        let text = " " + normalize(spoken) + " "
        guard text.trimmingCharacters(in: .whitespaces).isEmpty == false else { return nil }

        let endOfDay = has(text, ["eod", "end of day", "end of the day", "close of business", "cob", "tonight"])
        var hour = 9, minute = 0
        if has(text, ["afternoon"]) { hour = 14 }
        if has(text, ["noon", "lunch", "midday"]) { hour = 12 }
        if has(text, ["evening"]) { hour = 18 }
        if endOfDay { hour = 17 }
        let explicit = explicitTime(text)
        if let explicit { (hour, minute) = explicit }

        let today = calendar.startOfDay(for: now)
        func at(_ day: Date, defaultHour: Int? = nil) -> Date? {
            let h = explicit?.0 ?? (endOfDay ? 17 : (defaultHour ?? hour))
            return calendar.date(bySettingHour: h, minute: explicit?.1 ?? minute, second: 0, of: day)
        }
        func plus(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }

        if has(text, ["day after tomorrow"]) { return plus(2).flatMap { at($0) } }
        if has(text, ["tomorrow", "tmrw", "tmr"]) { return plus(1).flatMap { at($0) } }
        if let days = relativeDays(text) { return plus(days).flatMap { at($0) } }
        if let day = monthDay(text, now: now, calendar: calendar) { return at(day) }
        if let day = weekday(text, today: today, calendar: calendar) { return at(day) }

        if has(text, ["end of next week"]) {
            return endOfWeek(from: plus(7) ?? today, calendar: calendar).flatMap { at($0, defaultHour: 17) }
        }
        if has(text, ["end of week", "end of the week", "eow", "this week", "by the weekend"]) {
            return endOfWeek(from: today, calendar: calendar).flatMap { at($0, defaultHour: 17) }
        }
        if has(text, ["next week"]) {
            return nextWeekStart(from: today, calendar: calendar).flatMap { at($0) }
        }
        if has(text, ["end of month", "end of the month", "eom"]) {
            guard let interval = calendar.dateInterval(of: .month, for: today),
                  let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
            return at(calendar.startOfDay(for: last), defaultHour: 17)
        }
        if has(text, ["next month"]) {
            guard let interval = calendar.dateInterval(of: .month, for: today) else { return nil }
            return at(interval.end)
        }
        if has(text, ["today", "asap", "right away"]) || endOfDay {
            return at(today, defaultHour: 17)
        }
        return nil
    }

    // MARK: Pieces

    private static let weekdayWords: [(Int, [String])] = [
        (1, ["sunday", "sun"]), (2, ["monday", "mon"]), (3, ["tuesday", "tues", "tue"]),
        (4, ["wednesday", "weds", "wed"]), (5, ["thursday", "thurs", "thur", "thu"]),
        (6, ["friday", "fri"]), (7, ["saturday", "sat"]),
    ]

    private static let months: [(Int, [String])] = [
        (1, ["january", "jan"]), (2, ["february", "feb"]), (3, ["march", "mar"]), (4, ["april", "apr"]),
        (5, ["may"]), (6, ["june", "jun"]), (7, ["july", "jul"]), (8, ["august", "aug"]),
        (9, ["september", "sept", "sep"]), (10, ["october", "oct"]), (11, ["november", "nov"]),
        (12, ["december", "dec"]),
    ]

    private static let numberWords = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                      "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple of": 2]

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "/" || scalar == ":" ? Character(scalar) : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    private static func has(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains(" \($0) ") }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func explicitTime(_ text: String) -> (Int, Int)? {
        if let m = firstMatch(#" (\d{1,2})(?::(\d{2}))? ?(am|pm) "#, in: text), let h = Int(m[1]), (1...12).contains(h) {
            let minute = Int(m[2]) ?? 0
            let hour = m[3] == "pm" ? (h % 12) + 12 : h % 12
            return (hour, min(59, minute))
        }
        if let m = firstMatch(#" ([01]?\d|2[0-3]):([0-5]\d) "#, in: text), let h = Int(m[1]), let mm = Int(m[2]) {
            return (h, mm)
        }
        return nil
    }

    private static func relativeDays(_ text: String) -> Int? {
        let words = numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        guard let m = firstMatch(#" in (\d{1,2}|"# + words + #") (day|days|week|weeks) "#, in: text) else { return nil }
        let n = Int(m[1]) ?? numberWords[m[1]] ?? 1
        return m[2].hasPrefix("week") ? n * 7 : n
    }

    private static func monthIndex(_ word: String) -> Int? {
        months.first { $0.1.contains(word) }?.0
    }

    private static func monthDay(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let names = months.flatMap(\.1).sorted { $0.count > $1.count }.joined(separator: "|")
        var month: Int?
        var day: Int?
        if let m = firstMatch(" (" + names + #") (\d{1,2})(?:st|nd|rd|th)? "#, in: text) {
            month = monthIndex(m[1]); day = Int(m[2])
        } else if let m = firstMatch(#" (\d{1,2})(?:st|nd|rd|th)? (?:of )?("# + names + ") ", in: text) {
            month = monthIndex(m[2]); day = Int(m[1])
        } else if let m = firstMatch(#" (\d{1,2})/(\d{1,2}) "#, in: text) {
            // US month/day ("10/30").
            month = Int(m[1]); day = Int(m[2])
        }
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year = calendar.component(.year, from: now)
        for candidate in [year, year + 1] {
            var parts = DateComponents()
            parts.year = candidate; parts.month = month; parts.day = day
            guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == day else { return nil }
            if date >= calendar.startOfDay(for: now) { return date }
        }
        return nil
    }

    private static func weekday(_ text: String, today: Date, calendar: Calendar) -> Date? {
        for (weekday, words) in weekdayWords {
            guard let word = words.first(where: { text.contains(" \($0) ") }) else { continue }
            let current = calendar.component(.weekday, from: today)
            var delta = (weekday - current + 7) % 7
            let saysThis = text.contains(" this \(word) ")
            if delta == 0 && !saysThis { delta = 7 }
            guard var date = calendar.date(byAdding: .day, value: delta, to: today) else { return nil }
            if text.contains(" next \(word) "),
               calendar.isDate(date, equalTo: today, toGranularity: .weekOfYear) {
                date = calendar.date(byAdding: .day, value: 7, to: date) ?? date
            }
            return date
        }
        return nil
    }

    /// Friday of the week `day` is in (or `day` itself on a weekend).
    private static func endOfWeek(from day: Date, calendar: Calendar) -> Date? {
        let current = calendar.component(.weekday, from: day)
        if current == 7 || current == 1 { return day }
        return calendar.date(byAdding: .day, value: 6 - current, to: day)
    }

    /// The Monday after `day`.
    private static func nextWeekStart(from day: Date, calendar: Calendar) -> Date? {
        let current = calendar.component(.weekday, from: day)
        let delta = (2 - current + 7) % 7
        return calendar.date(byAdding: .day, value: delta == 0 ? 7 : delta, to: day)
    }
}

/// Creates EKReminders. The caller already has access (asked through the gate).
enum MeetingReminderWriter {
    enum Failure: Error, LocalizedError {
        case noList
        var errorDescription: String? { "There's no default Reminders list" }
    }

    static func add(_ proposals: [MeetingReminderProposal], meetingTitle: String, date: Date,
                    store: EKEventStore) throws -> [UUID: String] {
        try add(proposals, meetingTitle: meetingTitle, date: date, url: nil, store: store)
    }

    static func add(_ proposals: [MeetingReminderProposal], meetingTitle: String, date: Date, url: URL?,
                    store: EKEventStore) throws -> [UUID: String] {
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList }
        var created: [(UUID, EKReminder)] = []
        for proposal in proposals {
            let reminder = EKReminder(eventStore: store)
            reminder.title = proposal.title
            reminder.calendar = list
            reminder.notes = notesLine(meetingTitle: meetingTitle, date: date)
            reminder.url = url
            if let due = proposal.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due
                )
            }
            try store.save(reminder, commit: false)
            created.append((proposal.id, reminder))
        }
        try store.commit()
        return Dictionary(created.map { ($0.0, $0.1.calendarItemIdentifier) }, uniquingKeysWith: { a, _ in a })
    }

    /// "From Design sync · Thu 22 Oct".
    static func notesLine(meetingTitle: String, date: Date) -> String {
        "From \(meetingTitle) · \(MeetingFollowUpWriter.shortDate(date))"
    }

    /// sparkv://meeting/<id> only when SparkV registers the scheme.
    static func meetingURL(_ id: UUID, bundle: Bundle = .main) -> URL? {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() }
        guard schemes.contains("sparkv") else { return nil }
        return URL(string: "sparkv://meeting/\(id.uuidString)")
    }
}

/// Polish: the model may only reword, never add or drop facts.
enum MeetingWrapUpPolish {
    static let instructions = """
    You tidy up a meeting follow-up email the user wrote. Keep every name, decision, task, owner and date exactly \
    as given. Do not add facts, promises, dates or people. Keep the "- " bullet lists. Plain text, no markdown \
    headings, no subject line. Warm and brief. Reply with the email body only.
    """

    static let maxBodyCharacters = 6000

    static func prompt(_ draft: MeetingFollowUpDraft) -> String {
        "Subject (for context, do not repeat it): \(draft.subject)\n\nEmail body:\n\(draft.body)"
    }

    /// The model's reply as a body, or nil when it lost details.
    static func clean(_ raw: String, original: String) -> String? {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty
                || first.lowercased().hasPrefix("subject:") { lines.removeFirst() }
        if let first = lines.first, first.lowercased().hasPrefix("body:") {
            lines[0] = String(first.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Double(text.count) >= Double(original.count) * 0.4 else { return nil }
        // Every bullet of the original must survive (task, owner, decision).
        let outLines = text.components(separatedBy: "\n")
        let bullets = original.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        for bullet in bullets where !outLines.contains(where: { MeetingAIText.similarity($0, bullet) >= 0.5 }) {
            return nil
        }
        return text
    }
}

// MARK: - Controller

@MainActor
final class MeetingWrapUpController: ObservableObject, MeetingWrappingUp {
    /// Set by the app (INTEGRATION.md step 6) so the notes window can open a wrap-up.
    static weak var current: MeetingWrapUpController?

    @Published private(set) var model: MeetingWrapUpModel?
    /// "reminders", "polish", "file".
    @Published private(set) var busy: Set<String> = []
    /// Last result line ("Added 2 to Reminders.").
    @Published private(set) var message: String?
    @Published private(set) var remindersAccess: MeetingRemindersAccess = .notDetermined
    @Published private(set) var spaceChoices: [MeetingWrapUpSpaceChoice] = []
    /// The Space the picker shows (suggested first).
    @Published var chosenSpaceID: UUID?
    /// True while the minutes are still being written.
    @Published private(set) var isWaitingForNotes = false

    private let activities: ActivityCenter
    private let source: any MeetingWrapUpSource
    private let spaces: (any MeetingWrapUpSpaces)?
    private let reminders: any MeetingRemindersGate
    private let store: MeetingIntelSidecarStore
    private let userName: String

    // Seams (tests replace these; defaults touch the system only on a click).
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// nil -> EventKit (`MeetingReminderWriter`).
    var writeReminders: (([MeetingReminderProposal], String, Date, URL?) throws -> [UUID: String])?
    /// nil -> on-device model (Groq only if allowed).
    var polisher: ((MeetingFollowUpDraft) async throws -> String)?
    /// Groq key reader, used only when `source.allowsGroq` (the app reads the keychain).
    var groqKey: @Sendable () async -> String? = { nil }
    var now: () -> Date = { Date() }
    var calendar = Calendar.current
    var notesWaitLimit: TimeInterval = 180
    var monologueThreshold: TimeInterval = 120
    var showsWindowOnReview = true

    private var waitTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var session: MeetingIntelSession?
    private var eventStore: EKEventStore?
    /// The last Polish went to Groq (only possible with allowGroqForMeetings on).
    private var lastPolishUsedGroq = false
    private lazy var window = MeetingWrapUpWindowController(controller: self)

    init(activities: ActivityCenter,
         source: any MeetingWrapUpSource,
         spaces: (any MeetingWrapUpSpaces)?,
         reminders: any MeetingRemindersGate,
         store: MeetingIntelSidecarStore = .shared,
         userName: String) {
        self.activities = activities
        self.source = source
        self.spaces = spaces
        self.reminders = reminders
        self.store = store
        self.userName = userName
    }

    // MARK: MeetingWrappingUp

    func present(meetingID: UUID, session: MeetingIntelSession?, sidecar: MeetingIntelSidecar?) {
        waitTask?.cancel()
        self.session = session
        let keepNotes = session?.plan.keepNotes ?? true
        guard keepNotes, !notesReady(meetingID) else {
            isWaitingForNotes = false
            Task { await show(meetingID: meetingID, sidecar: sidecar, peek: true) }
            return
        }
        isWaitingForNotes = true
        let limit = notesWaitLimit
        waitTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < limit {
                guard let self else { return }
                if self.notesReady(meetingID) { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.isWaitingForNotes = false
            await self.show(meetingID: meetingID, sidecar: sidecar, peek: true)
        }
    }

    func openWindow(meetingID: UUID) {
        activities.dismiss(id: MeetingIntelActivity.wrapUp)
        if model?.meetingID == meetingID {
            refreshEnvironment()
            if showsWindowOnReview { window.show() }
            return
        }
        Task {
            await show(meetingID: meetingID, sidecar: nil, peek: false)
            if model?.meetingID == meetingID, showsWindowOnReview { window.show() }
        }
    }

    // MARK: Tasks -> Reminders

    func toggleProposal(_ id: UUID) {
        guard var m = model, let i = m.proposals.firstIndex(where: { $0.id == id }),
              m.proposals[i].reminderID == nil else { return }
        m.proposals[i].isSelected.toggle()
        model = m
    }

    func setDue(_ date: Date?, proposal id: UUID) {
        guard var m = model, let i = m.proposals.firstIndex(where: { $0.id == id }) else { return }
        m.proposals[i].dueDate = date
        model = m
    }

    /// Asks for Reminders access here (only on click), then adds the ticked items.
    @discardableResult
    func addSelectedToReminders() async -> Int {
        guard let m = model, !busy.contains("reminders") else { return 0 }
        let chosen = m.proposals.filter { $0.isSelected && $0.reminderID == nil }
        guard !chosen.isEmpty else {
            say("Tick the tasks you want in Reminders first.")
            return 0
        }
        busy.insert("reminders")
        defer { busy.remove("reminders") }
        switch reminders.status() {
        case .unavailable:
            remindersAccess = .unavailable
            say("Reminders isn't connected yet.")
            return 0
        case .denied:
            remindersAccess = .denied
            say("Reminders access is off. Turn it on in System Settings › Privacy & Security › Reminders.")
            return 0
        case .granted, .notDetermined:
            break
        }
        guard await reminders.request(from: "Meeting wrap-up") else {
            remindersAccess = reminders.status()
            say("Reminders wasn't allowed, so nothing was added.")
            return 0
        }
        remindersAccess = .granted
        let ids: [UUID: String]
        do {
            let url = MeetingReminderWriter.meetingURL(m.meetingID)
            if let writeReminders {
                ids = try writeReminders(chosen, m.title, m.date, url)
            } else {
                let store = eventStore ?? EKEventStore()
                eventStore = store
                ids = try MeetingReminderWriter.add(chosen, meetingTitle: m.title, date: m.date, url: url, store: store)
            }
        } catch {
            AppLog.log("MeetingIntel: reminders failed: \(error.localizedDescription)")
            say("Couldn't add to Reminders: \(error.localizedDescription)")
            return 0
        }
        guard var latest = model, latest.meetingID == m.meetingID else { return ids.count }
        for i in latest.proposals.indices {
            guard let reminderID = ids[latest.proposals[i].id] else { continue }
            latest.proposals[i].reminderID = reminderID
            latest.proposals[i].isSelected = false
            if let task = latest.proposals[i].actionItemID, !latest.state.remindedTaskIDs.contains(task) {
                latest.state.remindedTaskIDs.append(task)
            }
        }
        model = latest
        persistState()
        AppLog.log("MeetingIntel: added \(ids.count) reminder(s) for a meeting")
        say("Added \(ids.count) to Reminders.")
        return ids.count
    }

    // MARK: Follow-up

    func updateDraft(_ draft: MeetingFollowUpDraft) {
        guard var m = model else { return }
        m.draft = draft
        model = m
    }

    func polishDraft() async {
        guard let m = model, !busy.contains("polish") else { return }
        let draft = m.draft
        guard draft.body.count <= MeetingWrapUpPolish.maxBodyCharacters else {
            say("The draft is too long to polish on this Mac.")
            return
        }
        busy.insert("polish")
        defer { busy.remove("polish") }
        lastPolishUsedGroq = false
        do {
            let raw = try await (polisher ?? defaultPolish)(draft)
            guard let body = MeetingWrapUpPolish.clean(raw, original: draft.body) else {
                say("The rewrite dropped some details, so your draft was kept.")
                return
            }
            // Don't overwrite edits made while the model was working.
            guard var latest = model, latest.meetingID == m.meetingID, latest.draft == draft else {
                say("You edited the draft meanwhile, so it was kept.")
                return
            }
            latest.draft.body = body
            model = latest
            // Say where it really ran: a custom polisher or the on-device model
            // is "this Mac"; only the Groq fallback (meeting toggle on) is not.
            say(lastPolishUsedGroq ? "Polished with Groq (your meeting setting). Check it before sending."
                                   : "Polished on this Mac. Check it before sending.")
        } catch {
            say("Couldn't polish: \(error.localizedDescription)")
        }
    }

    /// Opens the draft in the mail app; never sends. False -> copied instead.
    @discardableResult
    func openDraftInMail() -> Bool {
        guard var m = model else { return false }
        guard let url = m.draft.mailtoURL else {
            copyText(m.draft.plainText)
            m.state.draftCopiedAt = now()
            model = m
            persistState()
            say("Too long for a mail link, so it was copied. Paste it into a new email.")
            return false
        }
        guard openURL(url) else {
            copyText(m.draft.plainText)
            m.state.draftCopiedAt = now()
            model = m
            persistState()
            say("No mail app opened, so the draft was copied.")
            return false
        }
        m.state.draftOpenedAt = now()
        model = m
        persistState()
        say("Opened as a draft in Mail. Nothing was sent.")
        return true
    }

    func copyDraft() {
        guard var m = model else { return }
        copyText(m.draft.plainText)
        m.state.draftCopiedAt = now()
        model = m
        persistState()
        say("Copied the follow-up.")
    }

    // MARK: Spaces

    @discardableResult
    func file(into spaceID: UUID) async -> Bool {
        guard let m = model, let spaces, !busy.contains("file") else { return false }
        guard let space = spaces.spaces.first(where: { $0.id == spaceID }) else {
            say("That Space isn't there anymore.")
            return false
        }
        busy.insert("file")
        defer { busy.remove("file") }
        let key = "meeting:\(m.meetingID.uuidString)"
        var item = spaces.items.first { $0.sourceKey == key }
        if item == nil {
            let names = m.attendees.filter { !$0.isMe }.map(\.name)
            guard let record = source.record(id: m.meetingID),
                  let input = spaces.ingestInput(for: record, attendees: names) else {
                say("Nothing to file yet: the meeting has no notes or transcript.")
                return false
            }
            item = await spaces.ingest(input)
        }
        guard let item else {
            say("Couldn't add the meeting to Spaces.")
            return false
        }
        spaces.move(itemID: item.id, to: spaceID)
        guard var latest = model, latest.meetingID == m.meetingID else { return true }
        latest.state.filedSpaceID = spaceID
        latest.state.filedItemID = item.id
        latest.suggestedSpaceID = spaceID
        model = latest
        chosenSpaceID = spaceID
        persistState()
        say("Filed in \(space.name).")
        return true
    }

    func openFullNotes() {
        guard let m = model else { return }
        source.openNotes(meetingID: m.meetingID)
    }

    func dismiss() {
        waitTask?.cancel()
        isWaitingForNotes = false
        activities.dismiss(id: MeetingIntelActivity.wrapUp)
        window.close()
        guard var m = model else { return }
        m.state.dismissedAt = now()
        model = m
        persistState()
    }

    // MARK: Internals

    private func notesReady(_ id: UUID) -> Bool {
        if source.record(id: id)?.notes != nil { return true }
        return !source.isWritingNotes(for: id)
    }

    private func show(meetingID: UUID, sidecar: MeetingIntelSidecar?, peek: Bool) async {
        guard let record = source.record(id: meetingID) else { return }
        let loaded: MeetingIntelSidecar
        if let sidecar { loaded = sidecar } else { loaded = await store.load(meetingID) }
        let built = MeetingWrapUpBuilder.model(
            record: record, session: session?.id == meetingID ? session : nil, sidecar: loaded,
            userName: userName, now: now(), calendar: calendar, monologueThreshold: monologueThreshold
        )
        model = built
        message = nil
        refreshEnvironment()
        chosenSpaceID = built.suggestedSpaceID
        if peek, MeetingWrapUpBuilder.isWorthShowing(built) { postPeek(built) }
        await suggestSpace(for: record)
    }

    private func refreshEnvironment() {
        remindersAccess = reminders.status()
        spaceChoices = MeetingWrapUpBuilder.spaceChoices(spaces?.spaces ?? [])
    }

    private func suggestSpace(for record: MeetingRecord) async {
        guard let spaces, var m = model, m.meetingID == record.id, m.state.filedSpaceID == nil else { return }
        let key = "meeting:\(record.id.uuidString)"
        var suggestion = spaces.items.first { $0.sourceKey == key }?.spaceID
        if suggestion == nil {
            let people = m.attendees.filter { !$0.isMe }.map(\.name).joined(separator: " ")
            let query = [record.title, people].filter { !$0.isEmpty }.joined(separator: " ")
            let hits = await spaces.search(query, in: nil)
            suggestion = hits.first { $0.spaceID != nil && $0.sourceKey != key }?.spaceID
        }
        guard let suggestion, spaces.spaces.contains(where: { $0.id == suggestion }) else { return }
        guard let latest = model, latest.meetingID == m.meetingID else { return }
        m = latest
        m.suggestedSpaceID = suggestion
        model = m
        if chosenSpaceID == nil { chosenSpaceID = suggestion }
    }

    private func postPeek(_ model: MeetingWrapUpModel) {
        let id = model.meetingID
        activities.post(
            LiveActivity(
                id: MeetingIntelActivity.wrapUp, kind: .meeting,
                priority: MeetingIntelActivity.wrapUpPriority, duration: 12, height: 48,
                presentation: .expanded, symbol: "text.badge.checkmark",
                compactText: model.myTaskCount > 0 ? "\(model.myTaskCount)" : nil
            ) { [weak self] in
                MeetingWrapUpPeek(model: model) { self?.openWindow(meetingID: id) }
            }
        )
    }

    private func defaultPolish(_ draft: MeetingFollowUpDraft) async throws -> String {
        let prompt = MeetingWrapUpPolish.prompt(draft)
        let allowGroq = source.allowsGroq
        if MeetingAIBackend.onDeviceAvailable {
            do {
                return try await MeetingAIBackend.onDevice(
                    instructions: MeetingWrapUpPolish.instructions, prompt: prompt, schema: nil,
                    maxTokens: 700, timeout: 30, permissive: true
                )
            } catch {
                if !allowGroq { throw error }
            }
        }
        guard allowGroq, let key = await groqKey(), !key.isEmpty else {
            throw MeetingAIError.unavailable("Apple Intelligence is off on this Mac")
        }
        let config = MeetingAIConfig(useGroq: true, groqKey: key)
        lastPolishUsedGroq = true
        return try await MeetingAIBackend.groq(
            config: config, system: MeetingWrapUpPolish.instructions, user: prompt, json: false,
            maxTokens: 900, reasoningEffort: "low", timeout: 30
        )
    }

    private func persistState() {
        guard let m = model else { return }
        let state = m.state
        let id = m.meetingID
        let store = store
        Task { await store.update(id) { $0.wrapUp = state } }
    }

    private func say(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

// MARK: - Formatting

enum MeetingWrapUpFormat {
    /// "4:07" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "32 min", "1 h 5 min", "< 1 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "You 41% · longest stretch 2:10 · 14 turns".
    static func talkLine(_ stats: MeetingTalkStats) -> String {
        let share = Int(((stats.myShare ?? 0) * 100).rounded())
        var parts = ["You \(share)%"]
        if stats.longestMonologue >= 5 { parts.append("longest stretch \(clock(stats.longestMonologue))") }
        parts.append("\(stats.turns) turn\(stats.turns == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    static func due(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        return formatter.string(from: date)
    }

    static func meta(_ model: MeetingWrapUpModel) -> String {
        var parts = [MeetingFollowUpWriter.shortDate(model.date),
                     model.date.formatted(date: .omitted, time: .shortened),
                     duration(model.duration)]
        if let service = model.serviceName, !service.isEmpty { parts.append(service) }
        return parts.joined(separator: " · ")
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

// MARK: - Peek band (notch, 360 × 48)

/// `Wrap-up  Design sync · 32 min` over `✓ 3 tasks for you  ◇ 2 decisions`,
/// a two-node thread on the left and Review on the right.
struct MeetingWrapUpPeek: View {
    let model: MeetingWrapUpModel
    let onReview: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 11) {
            thread
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MeetingIntelEyebrow(text: "Wrap-up")
                        .fixedSize()
                    Text(model.title)
                        .font(SparkVTheme.headline(12))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text(MeetingWrapUpFormat.duration(model.duration))
                        .font(SparkVTheme.caption(10.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .fixedSize()
                }
                ViewThatFits(in: .horizontal) {
                    counts(long: true)
                    counts(long: false)
                }
            }
            Spacer(minLength: 6)
            Button("Review") { onReview() }
                .buttonStyle(SparkVPrimaryButtonStyle())
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func counts(long: Bool) -> some View {
        HStack(spacing: long ? 10 : 8) {
            if model.myTaskCount > 0 {
                count(.actionItem, MeetingWrapUpFormat.plural(model.myTaskCount, "task") + (long ? " for you" : ""))
            }
            if !model.decisions.isEmpty {
                count(.decision, MeetingWrapUpFormat.plural(model.decisions.count, "decision"))
            }
            if model.momentCount > 0 {
                count(.bookmark, long ? MeetingWrapUpFormat.plural(model.momentCount, "moment") : "\(model.momentCount)")
            }
            if model.myTaskCount == 0 && model.decisions.isEmpty && model.momentCount == 0 {
                Text(model.notes == nil ? "Transcript saved on this Mac" : "Notes ready")
                    .font(SparkVTheme.caption(10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var thread: some View {
        VStack(spacing: 0) {
            Circle().fill(SparkVTheme.accent).frame(width: 6, height: 6)
            Rectangle().fill(SparkVTheme.stroke).frame(width: 1.5, height: 14)
            Circle().strokeBorder(SparkVTheme.textTertiary, lineWidth: 1.5).frame(width: 6, height: 6)
        }
        .frame(width: 6, height: 26)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func count(_ kind: MeetingFlagKind, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(text)
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.textSecondary)
        }
        .fixedSize()
    }
}

// MARK: - Wrap-up panel

/// One section on the thread: a ringed glyph node, an eyebrow, content.
struct MeetingWrapUpThreadSection<Content: View>: View {
    let symbol: String
    let title: String
    var tint: Color = SparkVTheme.textSecondary
    var isLast = false
    let content: Content

    init(symbol: String, title: String, tint: Color = SparkVTheme.textSecondary, isLast: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.title = title
        self.tint = tint
        self.isLast = isLast
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle()
                        .fill(SparkVTheme.stroke)
                        .frame(width: 1.5)
                        .padding(.top, 20)
                        .frame(maxHeight: .infinity)
                }
                Circle()
                    .fill(SparkVTheme.background)
                    .overlay(Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 1.5))
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tint)
                    )
                    .frame(width: 20, height: 20)
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 9) {
                MeetingIntelEyebrow(text: title)
                    .frame(height: 20)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, isLast ? 4 : 22)
        }
    }
}

struct MeetingWrapUpMomentRow: View {
    let flag: MeetingFlag
    var onSelect: () -> Void = {}

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(MeetingWrapUpFormat.clock(flag.at))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .frame(width: 40, alignment: .trailing)
                Image(systemName: flag.kind.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(flag.kind.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(flag.text.isEmpty ? flag.kind.label : flag.text)
                        .font(SparkVTheme.body(12))
                        .foregroundStyle(SparkVTheme.text)
                        .multilineTextAlignment(.leading)
                    if let note = flag.note, !note.isEmpty {
                        Text(note)
                            .font(SparkVTheme.caption(10.5))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the notes")
    }
}

struct MeetingWrapUpView: View {
    @ObservedObject var controller: MeetingWrapUpController

    var body: some View {
        VStack(spacing: 0) {
            if let model = controller.model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(model)
                            .padding(.bottom, 22)
                        sections(model)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 30)
                    .padding(.bottom, 18)
                }
                footer
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.isWaitingForNotes ? "Writing the notes on this Mac…" : "No meeting selected")
                        .font(SparkVTheme.body(12))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SparkVTheme.background)
    }

    // MARK: Header

    private func header(_ model: MeetingWrapUpModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                MeetingIntelEyebrow(text: "Wrap-up")
                Text(model.title)
                    .font(SparkVTheme.title(22))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(2)
                Text(MeetingWrapUpFormat.meta(model))
                    .font(SparkVTheme.caption(11))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Done") { controller.dismiss() }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(_ model: MeetingWrapUpModel) -> some View {
        MeetingWrapUpThreadSection(symbol: "text.alignleft", title: "Summary", tint: SparkVTheme.accent) {
            summary(model)
        }
        if !model.flags.isEmpty {
            MeetingWrapUpThreadSection(symbol: MeetingFlagKind.bookmark.symbol, title: "Moments") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.flags.prefix(12)) { flag in
                        MeetingWrapUpMomentRow(flag: flag) { controller.openFullNotes() }
                    }
                }
            }
        }
        if let talk = model.talk {
            MeetingWrapUpThreadSection(symbol: "waveform", title: "Talk time") {
                VStack(alignment: .leading, spacing: 7) {
                    MeetingTalkShareBar(stats: talk, height: 5)
                        .frame(maxWidth: 320)
                    Text(MeetingWrapUpFormat.talkLine(talk))
                        .font(SparkVTheme.caption(11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            }
        }
        MeetingWrapUpThreadSection(symbol: MeetingFlagKind.actionItem.symbol, title: "Your tasks → Reminders",
                                   tint: SparkVTheme.success) {
            tasks(model)
        }
        MeetingWrapUpThreadSection(symbol: "envelope", title: "Follow-up draft") {
            followUp(model)
        }
        MeetingWrapUpThreadSection(symbol: "square.stack.3d.up", title: "File into a Space", isLast: true) {
            fileRow(model)
        }
    }

    private func summary(_ model: MeetingWrapUpModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notes = model.notes, !notes.summary.isEmpty {
                Text(notes.summary)
                    .font(SparkVTheme.body(12.5))
                    .foregroundStyle(SparkVTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(controller.isWaitingForNotes ? "Writing the notes on this Mac…"
                     : "No minutes for this call. The transcript is saved on this Mac.")
                    .font(SparkVTheme.body(12))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            if !model.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.decisions.prefix(6).enumerated()), id: \.offset) { _, line in
                        bullet(line, symbol: MeetingFlagKind.decision.symbol, tint: MeetingFlagKind.decision.tint)
                    }
                }
            }
            if let points = model.notes?.keyPoints, !points.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(points.prefix(4).enumerated()), id: \.offset) { _, line in
                        bullet(line, symbol: "circle.fill", tint: SparkVTheme.textTertiary, small: true)
                    }
                }
            }
            Button {
                controller.openFullNotes()
            } label: {
                HStack(spacing: 4) {
                    Text("Open full notes")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(SparkVTheme.caption(11))
                .foregroundStyle(SparkVTheme.link)
            }
            .buttonStyle(SparkVPressStyle())
        }
    }

    private func bullet(_ text: String, symbol: String, tint: Color, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: small ? 4.5 : 9.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 11)
            Text(text)
                .font(SparkVTheme.body(12))
                .foregroundStyle(SparkVTheme.text.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Tasks

    @ViewBuilder
    private func tasks(_ model: MeetingWrapUpModel) -> some View {
        if model.proposals.isEmpty {
            Text("No tasks for you in this meeting.")
                .font(SparkVTheme.body(12))
                .foregroundStyle(SparkVTheme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    ForEach(Array(model.proposals.enumerated()), id: \.element.id) { index, proposal in
                        if index > 0 { Rectangle().fill(SparkVTheme.stroke).frame(height: 1) }
                        taskRow(proposal)
                    }
                }
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
                remindersAction(model)
            }
        }
    }

    private func taskRow(_ proposal: MeetingReminderProposal) -> some View {
        let added = proposal.reminderID != nil
        return HStack(spacing: 10) {
            Button {
                controller.toggleProposal(proposal.id)
            } label: {
                Image(systemName: added ? "checkmark.circle.fill" : (proposal.isSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(added ? SparkVTheme.success : (proposal.isSelected ? SparkVTheme.accent : SparkVTheme.textTertiary))
                    // Checkbox: the glyph swaps in place with a snappy spring.
                    .contentTransition(.symbolEffect(.replace))
                    .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: proposal.isSelected)
                    .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: added)
            }

            .buttonStyle(SparkVPressStyle())
            .disabled(added)
            .accessibilityLabel(proposal.isSelected ? "Selected" : "Not selected")
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.title)
                    .font(SparkVTheme.body(12))
                    .foregroundStyle(added ? SparkVTheme.textSecondary : SparkVTheme.text)
                    .lineLimit(2)
                if let spoken = proposal.dueText, !spoken.isEmpty {
                    Text("said “\(spoken)”")
                        .font(SparkVTheme.caption(10))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            Spacer(minLength: 6)
            if added {
                Text("In Reminders")
                    .font(SparkVTheme.caption(10.5))
                    .foregroundStyle(SparkVTheme.success)
            } else if let due = proposal.dueDate {
                HStack(spacing: 4) {
                    DatePicker("Due", selection: Binding(
                        get: { proposal.dueDate ?? due },
                        set: { controller.setDue($0, proposal: proposal.id) }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .controlSize(.small)
                    .fixedSize()
                    Button {
                        controller.setDue(nil, proposal: proposal.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help("No due date")
                    .accessibilityLabel("No due date")
                }
            } else {
                Button("Add date") {
                    let base = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                    controller.setDue(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: base), proposal: proposal.id)
                }
                .buttonStyle(SparkVPressStyle())
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func remindersAction(_ model: MeetingWrapUpModel) -> some View {
        switch controller.remindersAccess {
        case .unavailable:
            note("checklist", "Reminders isn't connected yet.")
        case .denied:
            note("lock", "Reminders access is off. Turn it on in System Settings › Privacy & Security › Reminders.")
        case .granted, .notDetermined:
            HStack(spacing: 10) {
                let n = model.selectedCount
                Button(n == 0 ? "Add to Reminders" : "Add \(n) to Reminders") {
                    Task { await controller.addSelectedToReminders() }
                }
                .buttonStyle(SparkVPrimaryButtonStyle())
                .disabled(n == 0 || controller.busy.contains("reminders"))
                .opacity(n == 0 ? 0.5 : 1)
                if controller.busy.contains("reminders") { ProgressView().controlSize(.small) }
                Text(model.remindedCount > 0 ? "\(model.remindedCount) already in Reminders"
                     : "Only the ticked tasks are added.")
                    .font(SparkVTheme.caption(10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    // MARK: Follow-up

    private func followUp(_ model: MeetingWrapUpModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("To") {
                TextField(model.attendees.isEmpty ? "Add recipients" : "No emails on the invite", text: Binding(
                    get: { controller.model?.draft.to.joined(separator: ", ") ?? "" },
                    set: { value in
                        guard var draft = controller.model?.draft else { return }
                        draft.to = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        controller.updateDraft(draft)
                    }
                ))
            }
            field("Subject") {
                TextField("Subject", text: Binding(
                    get: { controller.model?.draft.subject ?? "" },
                    set: { value in
                        guard var draft = controller.model?.draft else { return }
                        draft.subject = value
                        controller.updateDraft(draft)
                    }
                ))
            }
            TextEditor(text: Binding(
                get: { controller.model?.draft.body ?? "" },
                set: { value in
                    guard var draft = controller.model?.draft else { return }
                    draft.body = value
                    controller.updateDraft(draft)
                }
            ))
            .font(SparkVTheme.body(12))
            .foregroundStyle(SparkVTheme.text)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 190)
            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
            HStack(spacing: 8) {
                Button("Open draft in Mail") { controller.openDraftInMail() }
                    .buttonStyle(SparkVPrimaryButtonStyle())
                Button("Copy") { controller.copyDraft() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Button {
                    Task { await controller.polishDraft() }
                } label: {
                    HStack(spacing: 5) {
                        if controller.busy.contains("polish") {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "wand.and.stars").font(.system(size: 10.5, weight: .medium))
                        }
                        Text("Polish")
                    }
                }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .disabled(controller.busy.contains("polish"))
                Spacer(minLength: 6)
                Text(sentLine(model.state))
                    .font(SparkVTheme.caption(10))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func sentLine(_ state: MeetingWrapUpState) -> String {
        if state.draftOpenedAt != nil { return "Draft opened · not sent" }
        if state.draftCopiedAt != nil { return "Copied · not sent" }
        return "SparkV never sends it"
    }

    private func field<F: View>(_ label: String, @ViewBuilder _ content: () -> F) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .frame(width: 48, alignment: .leading)
            content()
                .textFieldStyle(.plain)
                .font(SparkVTheme.body(12))
                .foregroundStyle(SparkVTheme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
    }

    // MARK: Spaces

    @ViewBuilder
    private func fileRow(_ model: MeetingWrapUpModel) -> some View {
        if controller.spaceChoices.isEmpty {
            note("square.stack.3d.up", "No Spaces yet. The meeting is in the Spaces Inbox.")
        } else {
            let filed = model.state.filedSpaceID
            HStack(spacing: 10) {
                Picker("Space", selection: $controller.chosenSpaceID) {
                    Text("Choose a Space").tag(UUID?.none)
                    ForEach(controller.spaceChoices) { choice in
                        Text(choice.path + (choice.id == model.suggestedSpaceID && filed == nil ? "  (suggested)" : ""))
                            .tag(UUID?.some(choice.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Button(filed != nil && filed == controller.chosenSpaceID ? "Filed" : "File") {
                    guard let id = controller.chosenSpaceID else { return }
                    Task { await controller.file(into: id) }
                }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .disabled(controller.chosenSpaceID == nil || controller.busy.contains("file")
                          || (filed != nil && filed == controller.chosenSpaceID))
                if controller.busy.contains("file") { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(SparkVTheme.caption(11))
        .foregroundStyle(SparkVTheme.textSecondary)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SparkVTheme.textTertiary)
            Text("Nothing leaves this Mac until you click.")
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
            Spacer(minLength: 8)
            if let message = controller.message {
                Text(message)
                    .font(SparkVTheme.caption(11))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 11)
        .background(SparkVTheme.surface.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(SparkVTheme.stroke).frame(height: 1) }
    }
}

// MARK: - Window

/// The wrap-up panel. NotchIsland is an agent app: the panel activates
/// SparkV so the draft fields take typing, without a Dock icon.
@MainActor
final class MeetingWrapUpWindowController: NSObject, NSWindowDelegate {
    private weak var controller: MeetingWrapUpController?
    private var panel: NSPanel?
    private var appearanceObserver: NSObjectProtocol?

    init(controller: MeetingWrapUpController) {
        self.controller = controller
        super.init()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.backgroundColor = NSColor(SparkVTheme.background)
            }
        }
    }

    func show() {
        guard let panel = panel ?? makePanel() else { return }
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel? {
        guard let controller else { return nil }
        let root = MeetingWrapUpView(controller: controller).followsAppearance()
        let hosting = NSHostingController(rootView: AnyView(root))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.title = "Meeting Wrap-up"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(SparkVTheme.background)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentMinSize = NSSize(width: 520, height: 520)
        panel.setContentSize(NSSize(width: 600, height: 760))
        panel.center()
        panel.setFrameAutosaveName("SparkV.MeetingWrapUp")
        panel.delegate = self
        return panel
    }
}

@MainActor
final class PermissionCenterRemindersGate: MeetingRemindersGate {
    private let center: PermissionCenter
    init(center: PermissionCenter? = nil) { self.center = center ?? .shared }

    func status() -> MeetingRemindersAccess {
        switch center.status(.reminders) {
        case .granted: .granted
        case .notDetermined, .unknown: .notDetermined
        case .denied, .restricted, .limited: .denied
        case .appNotRunning, .appNotInstalled: .unavailable
        }
    }

    func request(from feature: String) async -> Bool {
        await center.ensure(.reminders, from: feature)
    }
}
