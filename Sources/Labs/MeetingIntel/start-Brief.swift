import EventKit
import Foundation

// Meeting Intelligence, part A: the pre-meeting brief.
//
// Everything here is local and read-only:
// - Calendar: the event's notes (agenda lines) and attendees, read from
//   EventKit only when Calendars access is already granted. MeetingIntel
//   never asks for Calendars access.
// - Meetings library: past meetings with the same people or the same
//   series, and the tasks still open from them.
// - Spaces: the best matching items (SpaceStore.search, on this Mac).
//
// Additions to the shared types (this file only): `MeetingStartBriefLine`,
// `MeetingBrief.bandLines(max:)`, `MeetingBrief.peopleChip(now:)`.

enum MeetingBriefBuilder {
    // MARK: Build

    /// Gathers the brief. `event` is today's matching calendar entry (start/end);
    /// agenda and attendees come from EventKit only when `calendarGranted`.
    @MainActor
    static func build(title: String, calendarEventID: String?, event: CalendarMeeting?,
                      library: [MeetingRecord], spaces: SpaceStore?,
                      calendarGranted: Bool, now: Date) async -> MeetingBrief {
        var brief = MeetingBrief.empty(title: title)
        brief.calendarEventID = calendarEventID ?? event?.eventID
        brief.start = event?.start
        brief.end = event?.end

        if calendarGranted, let eventID = brief.calendarEventID {
            if let notes = MeetingBriefCalendarReader.notes(eventID: eventID) {
                brief.agenda = agendaLines(from: notes)
            }
            brief.attendees = attendees(eventID: eventID)
            brief.sources.append("Calendar")
        }

        // The library scan reads transcripts: keep it off the main actor.
        let attendees = brief.attendees
        let finished = library.filter { $0.endedAt != nil }
        let past = await Task.detached(priority: .userInitiated) {
            related(finished, attendees: attendees, title: title, limit: 3)
        }.value
        brief.pastMeetings = past
        brief.openTasks = openTasks(from: past, limit: 5)
        if !library.isEmpty { brief.sources.append("Meetings") }

        if let spaces {
            let query = spaceQuery(title: title, attendees: attendees)
            if !query.isEmpty {
                let pastIDs = Set(past.map { "meeting:\($0.id.uuidString)" })
                let hits = await spaces.search(query, in: nil)
                brief.spaceHits = hits
                    .filter { !pastIDs.contains($0.sourceKey) }
                    .prefix(3)
                    .map { item in
                        MeetingBriefSpaceHit(
                            id: item.id,
                            spaceName: item.spaceID.flatMap { spaces.space($0)?.name },
                            title: item.title,
                            snippet: snippet(item.text, limit: 120)
                        )
                    }
                brief.sources.append("Spaces")
            }
        }
        return brief
    }

    // MARK: Calendar

    /// Attendees of an event (organizer included), read only when Calendars
    /// access is granted (callers check). Empty when EventKit has none.
    @MainActor
    static func attendees(eventID: String) -> [MeetingAttendee] {
        guard let event = MeetingBriefCalendarReader.event(eventID) else { return [] }
        var people: [EKParticipant] = event.attendees ?? []
        if let organizer = event.organizer { people.insert(organizer, at: 0) }
        var seen: Set<String> = []
        var result: [MeetingAttendee] = []
        for person in people {
            let email = emailAddress(from: person.url)
            let name = (person.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? email ?? "Guest"
            let key = email ?? name.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(MeetingAttendee(name: name, email: email, isMe: person.isCurrentUser))
        }
        return result
    }

    /// "mailto:Priya.Raman@x.com" -> "priya.raman@x.com".
    static func emailAddress(from url: URL) -> String? {
        let raw = url.absoluteString
        guard raw.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(raw.dropFirst("mailto:".count)).removingPercentEncoding ?? String(raw.dropFirst(7))
        return address.contains("@") ? address.lowercased() : nil
    }

    // MARK: Agenda (pure)

    /// Agenda-looking lines from calendar notes: bullets, numbered lines and
    /// "Agenda:" blocks, with Zoom / Meet / Teams / Webex join boilerplate
    /// and dial-in text removed. At most 6, each at most 90 characters.
    static func agendaLines(from notes: String) -> [String] {
        let text = plainText(fromHTML: notes)
        var lines: [String] = []
        var seen: Set<String> = []
        var inSeparatorBlock = false
        var inAgendaBlock = false

        func add(_ raw: String) {
            let cleaned = clean(raw)
            guard !cleaned.isEmpty, !isBoilerplate(cleaned) else { return }
            let key = cleaned.lowercased()
            guard seen.insert(key).inserted else { return }
            lines.append(cleaned)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isSeparator(line) {
                inSeparatorBlock.toggle()
                inAgendaBlock = false
                continue
            }
            if inSeparatorBlock { continue }
            if line.isEmpty {
                inAgendaBlock = false
                continue
            }
            if isBoilerplate(line) {
                inAgendaBlock = false
                continue
            }
            if let rest = agendaHeaderRest(line) {
                inAgendaBlock = true
                if !rest.isEmpty {
                    for part in rest.split(whereSeparator: { $0 == "," || $0 == ";" }) { add(String(part)) }
                }
                continue
            }
            if bulletBody(line) != nil || inAgendaBlock {
                // A new "Heading:" line inside a block ends it.
                if bulletBody(line) == nil, line.hasSuffix(":") {
                    inAgendaBlock = false
                    continue
                }
                add(line)
            }
            if lines.count >= 6 { break }
        }
        return Array(lines.prefix(6))
    }

    /// HTML from Google / Outlook invites to plain lines.
    static func plainText(fromHTML raw: String) -> String {
        guard raw.contains("<") && raw.contains(">") else { return decodeEntities(raw) }
        var s = raw
        let replacements: [(String, String)] = [
            ("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("</p>", "\n"), ("</div>", "\n"),
            ("<li>", "\n• "), ("</li>", "\n"), ("</ul>", "\n"), ("</ol>", "\n"), ("</h1>", "\n"),
            ("</h2>", "\n"), ("</h3>", "\n"), ("</tr>", "\n"),
        ]
        for (from, to) in replacements { s = s.replacingOccurrences(of: from, with: to, options: .caseInsensitive) }
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return decodeEntities(out)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static let bulletPrefixes = ["- ", "* ", "• ", "◦ ", "– ", "— ", "▪ ", "· ", "□ ", "☐ ", "▸ ", "> "]

    /// The text of a bulleted or numbered line ("1. Pricing" -> "Pricing").
    static func bulletBody(_ line: String) -> String? {
        for prefix in bulletPrefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        // "1. ", "12) ", "a) ", "b. "
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber, digits < 3 {
            digits += 1
            index = line.index(after: index)
        }
        if digits == 0, index < line.endIndex, line[index].isLetter, line[index].isLowercase {
            let next = line.index(after: index)
            if next < line.endIndex, line[next] == ")" { index = next; digits = 1 } else { return nil }
            index = line.index(after: index)
        } else if digits > 0, index < line.endIndex, line[index] == "." || line[index] == ")" {
            index = line.index(after: index)
        } else {
            return nil
        }
        guard index < line.endIndex, line[index] == " " else { return nil }
        let body = line[index...].trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private static let agendaHeaders = [
        "agenda", "topics", "talking points", "discussion points", "to discuss", "goals", "objectives", "items",
    ]

    /// "Agenda: pricing v2, launch" -> "pricing v2, launch"; "Agenda" -> "".
    static func agendaHeaderRest(_ line: String) -> String? {
        let lower = line.lowercased()
        for header in agendaHeaders where lower.hasPrefix(header) {
            let rest = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return "" }
            for mark in [":", " -", "–", "—"] where rest.hasPrefix(mark) {
                return rest.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// "____", "-::~:~::~:~:~::-", "────────" (invite blocks start and end with one).
    static func isSeparator(_ line: String) -> Bool {
        guard line.count >= 8 else { return false }
        let allowed: Set<Character> = ["_", "-", "─", "━", "=", "~", ":", "*", "•", ".", " ", "—", "–"]
        return line.allSatisfy { allowed.contains($0) }
    }

    private static let boilerplateMarkers = [
        // Zoom
        "join zoom meeting", "zoom.us/", "zoom.com/", "zoomgov.com", "meeting id:", "meeting id ", "passcode", "password:",
        "one tap mobile", "dial by your location", "find your local number", "join by sip", "join by h.323",
        "join instructions", "zoom meeting", "join the zoom", "zoom.us",
        // Google Meet
        "meet.google.com", "join with google meet", "join by phone", "more phone numbers", "learn more about meet",
        "pin:", "join google meet", "google meet joining info", "video call link",
        // Teams
        "microsoft teams meeting", "microsoft teams need help", "join the meeting now", "join on your computer",
        "teams.microsoft.com", "teams.live.com", "meeting options", "click here to join", "dial in by phone",
        "phone conference id", "for organizers:", "reset dial-in pin", "video conferencing device", "tenant key",
        "video id", "need help?", "join microsoft teams",
        // Webex and general
        "webex.com", "join meeting", "access code", "attendee id", "do not edit this section",
        "invitation from google calendar", "you are receiving this", "forwarding this invitation",
        "view all guest info", "reply for", "learn more", "unsubscribe", "privacy and security",
    ]

    static func isBoilerplate(_ line: String) -> Bool {
        let lower = line.lowercased()
        if boilerplateMarkers.contains(where: { lower.contains($0) }) { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") { return true }
        // Dial-in rows: "+1 646 558 8656 US (New York)", ",,84123456#".
        let digits = line.filter(\.isNumber).count
        let letters = line.filter(\.isLetter).count
        if digits >= 8, letters <= 14 { return true }
        return false
    }

    private static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let body = bulletBody(s) { s = body }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—•·:;"))
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if s.count > 90 { s = String(s.prefix(89)).trimmingCharacters(in: .whitespaces) + "…" }
        return s
    }

    // MARK: Related meetings (pure)

    /// Past meetings worth recalling: ones that share people with this one
    /// (names found in their title, notes, typed notes or transcript), or
    /// that belong to the same series (same normalized title). Strong
    /// matches (a shared person or the same series) come first, newest
    /// first within each group.
    static func related(_ library: [MeetingRecord], attendees: [MeetingAttendee],
                        title: String, limit: Int) -> [MeetingBriefPastMeeting] {
        let people = attendees.filter { !$0.isMe }
        let titleKey = isGenericTitle(title) ? nil : MeetingKindKey.normalize(title)
        let titleWords = Set((titleKey ?? "").split(separator: " ").map(String.init)).subtracting(stopWords)

        var strong: [MeetingBriefPastMeeting] = []
        var weak: [MeetingBriefPastMeeting] = []
        for record in library {
            var isStrong = false
            var isWeak = false
            let recordKey = isGenericTitle(record.title) ? nil : MeetingKindKey.normalize(record.title)
            if let titleKey, let recordKey {
                if titleKey == recordKey {
                    isStrong = true
                } else if !titleWords.isEmpty {
                    let words = Set(recordKey.split(separator: " ").map(String.init)).subtracting(stopWords)
                    let overlap = Double(titleWords.intersection(words).count)
                    let union = Double(titleWords.union(words).count)
                    if union > 0, overlap / union >= 0.5 { isWeak = true }
                }
            }
            var shared: [String] = []
            if !people.isEmpty {
                let words = wordSet(searchableText(record))
                for person in people where mentions(person, in: words) {
                    if !shared.contains(person.firstName) { shared.append(person.firstName) }
                }
                if !shared.isEmpty { isStrong = true }
            }
            guard isStrong || isWeak else { continue }
            let notes = record.notes
            let mine = (notes?.myTasks ?? []).filter { !$0.isDone }
            let others = (notes?.othersTasks ?? []).filter { !$0.isDone }
            let past = MeetingBriefPastMeeting(
                id: record.id,
                title: record.title,
                date: record.startedAt,
                summary: firstSentences(notes?.summary ?? "", count: 2, limit: 160),
                openTasks: Array((mine + others).prefix(4)),
                sharedPeople: shared
            )
            if isStrong { strong.append(past) } else { weak.append(past) }
        }
        let newest: (MeetingBriefPastMeeting, MeetingBriefPastMeeting) -> Bool = { $0.date > $1.date }
        return Array((strong.sorted(by: newest) + weak.sorted(by: newest)).prefix(max(0, limit)))
    }

    /// My not-done tasks across the past meetings, newest meeting first,
    /// without repeats.
    static func openTasks(from past: [MeetingBriefPastMeeting], limit: Int) -> [ActionItem] {
        var seen: Set<String> = []
        var result: [ActionItem] = []
        for meeting in past {
            for task in meeting.openTasks where task.isMine && !task.isDone {
                let key = MeetingKindKey.normalize(task.task) ?? task.task.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(task)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// Titles that say nothing about the meeting ("Zoom call",
    /// "Meeting · Oct 22, 3:41 PM", "Google Meet").
    static func isGenericTitle(_ title: String) -> Bool {
        guard let key = MeetingKindKey.normalize(title) else { return true }
        return key.split(separator: " ").allSatisfy { genericWords.contains(String($0)) }
    }

    private static let genericWords: Set<String> = [
        "zoom", "google", "meet", "microsoft", "teams", "webex", "slack", "huddle", "facetime", "around",
        "whereby", "call", "meeting", "video", "chat", "untitled", "new", "event", "am", "pm",
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "with", "for", "to", "on", "in", "x", "vs", "meeting", "call",
        "sync", "weekly", "daily", "monthly", "chat",
    ]

    private static func searchableText(_ record: MeetingRecord) -> String {
        var parts = [record.title, record.userNotes ?? ""]
        if let notes = record.notes {
            parts.append(notes.summary)
            parts += notes.keyPoints
            parts += notes.decisions
            parts += (notes.myTasks + notes.othersTasks).flatMap { [$0.owner, $0.task] }
        }
        var transcriptBudget = 40_000
        for segment in record.segments where transcriptBudget > 0 {
            parts.append(segment.text)
            transcriptBudget -= segment.text.count
        }
        return parts.joined(separator: " ")
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }

    private static func mentions(_ person: MeetingAttendee, in words: Set<String>) -> Bool {
        let first = person.firstName.lowercased()
        if first.count >= 3, words.contains(first) { return true }
        if let email = person.email, words.contains(email) { return true }
        let parts = person.name.lowercased().split(separator: " ").map(String.init)
        if parts.count >= 2, let last = parts.last, last.count >= 3, words.contains(last), words.contains(parts[0]) {
            return true
        }
        return false
    }

    // MARK: Text helpers

    static func firstSentences(_ text: String, count: Int, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sub, _, _, stop in
            if let sub { sentences.append(sub.trimmingCharacters(in: .whitespaces)) }
            if sentences.count >= count { stop = true }
        }
        return snippet(sentences.joined(separator: " "), limit: limit)
    }

    static func snippet(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit - 1)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// Words to look for in Spaces: the meeting title (unless generic) and
    /// up to three attendee names.
    static func spaceQuery(title: String, attendees: [MeetingAttendee]) -> String {
        var terms: [String] = []
        if !isGenericTitle(title) { terms.append(title) }
        terms += attendees.filter { !$0.isMe }.prefix(3).map(\.name).filter { !$0.contains("@") }
        return terms.joined(separator: " ")
    }
}

/// EventKit reads for the brief. Callers check Calendars access first; this
/// never requests it.
@MainActor
enum MeetingBriefCalendarReader {
    private static var store: EKEventStore?

    static func event(_ eventID: String) -> EKEvent? {
        let store = store ?? EKEventStore()
        Self.store = store
        return store.event(withIdentifier: eventID)
    }

    static func notes(eventID: String) -> String? {
        guard let event = event(eventID) else { return nil }
        let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? nil : notes
    }
}

// MARK: - Band lines

/// One line of the brief inside the start band.
struct MeetingStartBriefLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case agenda, owe, lastTime, space }
    var kind: Kind
    var text: String

    var symbol: String {
        switch kind {
        case .agenda: "list.bullet"
        case .owe: "circle.dashed"
        case .lastTime: "clock.arrow.circlepath"
        case .space: "square.stack"
        }
    }
}

extension MeetingBrief {
    /// The few lines the start band shows, most useful first: the agenda,
    /// what I still owe these people, what happened last time, a Space hit.
    func bandLines(max count: Int = 2) -> [MeetingStartBriefLine] {
        var lines: [MeetingStartBriefLine] = []
        if !agenda.isEmpty {
            lines.append(MeetingStartBriefLine(kind: .agenda, text: "Agenda: " + agenda.prefix(3).joined(separator: ", ")))
        }
        if let task = openTasks.first {
            var text = "You owe: " + task.task
            if let due = task.due, !due.isEmpty { text += " · \(due)" }
            if openTasks.count > 1 { text += "  +\(openTasks.count - 1)" }
            lines.append(MeetingStartBriefLine(kind: .owe, text: text))
        }
        if let last = pastMeetings.first, !last.summary.isEmpty {
            lines.append(MeetingStartBriefLine(kind: .lastTime, text: "Last time: " + last.summary))
        }
        if let hit = spaceHits.first {
            let place = hit.spaceName.map { " · \($0)" } ?? ""
            lines.append(MeetingStartBriefLine(kind: .space, text: "In Spaces: \(hit.title)\(place)"))
        }
        return Array(lines.prefix(Swift.max(0, count)))
    }

    /// "2 people you met Tue", "1 person you met 14 Oct", "4 invited".
    func peopleChip(now: Date, calendar: Calendar = .current) -> String? {
        if let last = pastMeetings.first(where: { !$0.sharedPeople.isEmpty }) {
            let n = last.sharedPeople.count
            return "\(n) \(n == 1 ? "person" : "people") you met \(Self.shortWhen(last.date, now: now, calendar: calendar))"
        }
        let invited = attendees.filter { !$0.isMe }.count
        return invited > 0 ? "\(invited) invited" : nil
    }

    /// "today", "yesterday", "Tue" within the week, else "14 Oct".
    static func shortWhen(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        let startNow = calendar.startOfDay(for: now)
        let startThen = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startThen, to: startNow).day ?? 99
        if days == 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = (0..<7).contains(days) ? "EEE" : "d MMM"
        return formatter.string(from: date)
    }
}
