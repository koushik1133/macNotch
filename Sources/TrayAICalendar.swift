import Foundation

// Tray AI "Add to Calendar": finds a date (and time, place) in the selected
// items with NSDataDetector, entirely on this Mac, and writes a one-event
// .ics file. Opening that file shows Calendar's own "add event" dialog, so
// nothing is written to a calendar without the user confirming it there,
// and SparkV never needs calendar access.

struct TrayAICalendarEvent: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    /// The text the date was found in.
    var notes: String?
    var timeZone: TimeZone?
}

enum TrayAICalendar {
    // MARK: Detection

    private static func detector(_ types: NSTextCheckingResult.CheckingType) -> NSDataDetector? {
        try? NSDataDetector(types: types.rawValue)
    }

    /// Cheap check used when choosing which actions to offer.
    static func containsDate(_ text: String) -> Bool {
        let sample = String(text.prefix(4000))
        guard !sample.isEmpty, let detector = detector(.date) else { return false }
        return detector.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil
    }

    /// True when the matched text names a time of day, not just a date.
    static func mentionsTime(_ text: String) -> Bool {
        text.range(
            of: #"(?i)(\b\d{1,2}[:.]\d{2}\b|\b\d{1,2}\s?(am|pm|a\.m\.|p\.m\.)|\bnoon\b|\bmidnight\b|\bo'?clock\b|\b\d{1,2}\s?h\d{0,2}\b)"#,
            options: .regularExpression
        ) != nil
    }

    /// The first event-like date in `text`. `headline` (the most prominent
    /// text of an image, say) is the preferred title when the date's own
    /// line doesn't name the event.
    static func event(in text: String, headline: String? = nil, fallbackTitle: String = "Event", now: Date = Date()) -> TrayAICalendarEvent? {
        let text = String(text.prefix(20_000))
        guard let detector = detector(.date) else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { $0.date != nil }
        guard !matches.isEmpty else { return nil }
        // Prefer a date that also says when in the day, then one that hasn't
        // passed; otherwise the first one.
        let match = matches.first { mentionsTime(ns.substring(with: $0.range)) && ($0.date ?? now) >= now.addingTimeInterval(-86_400) }
            ?? matches.first { ($0.date ?? now) >= now.addingTimeInterval(-86_400) }
            ?? matches[0]
        guard let start = match.date else { return nil }
        let matched = ns.substring(with: match.range)
        let timed = mentionsTime(matched)

        let lineRange = ns.lineRange(for: match.range)
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Self.title(line: line, matched: matched, headline: headline, text: text, fallback: fallbackTitle)

        var event = TrayAICalendarEvent(
            title: title, start: start, end: start, isAllDay: !timed, location: location(in: text),
            notes: line.isEmpty ? nil : String(line.prefix(500)), timeZone: match.timeZone
        )
        if timed {
            let duration = match.duration > 60 ? match.duration : 3600
            event.end = start.addingTimeInterval(duration)
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = match.timeZone ?? .current
            let day = calendar.startOfDay(for: start)
            event.start = day
            event.end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return event
    }

    private static func title(line: String, matched: String, headline: String?, text: String, fallback: String) -> String {
        // The detector's match can swallow event words ("lunch tomorrow at
        // 1pm"): only its date and time words are dropped from the title.
        let kept = matched.split(whereSeparator: \.isWhitespace).filter { !isDateWord(String($0)) }.joined(separator: " ")
        func usable(_ candidate: String) -> String? {
            var value = candidate.replacingOccurrences(of: matched, with: " \(kept) ")
            value = TrayAIRegex.replace(#"(?i)\b(on|at|from|until|till|to|by|starts?|begins?|when|date|time)\s*[:\-–]?\s*$"#, in: value, with: "")
            value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—|·•()[]"))
            guard value.filter(\.isLetter).count >= 3 else { return nil }
            return String(value.prefix(120))
        }
        if let headline, let value = usable(headline) { return value }
        if let value = usable(line) { return value }
        // The first line with words that isn't the date line.
        for candidate in text.components(separatedBy: .newlines).prefix(8) where candidate.trimmingCharacters(in: .whitespaces) != line {
            if let value = usable(candidate) { return value }
        }
        return fallback
    }

    /// Words that only say when: numbers, weekdays, months, relative days,
    /// times of day and the little words between them.
    static func isDateWord(_ word: String) -> Bool {
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:()[]–-—/"))
        if bare.isEmpty || bare.contains(where: \.isNumber) { return true }
        return bare.range(
            of: #"^(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(day)?s?$|^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*$|^(today|tonight|tomorrow|yesterday|next|this|last|coming|at|on|from|to|until|till|by|the|of|in|am|pm|a\.m|p\.m|noon|midnight|morning|afternoon|evening|night|week|weekend|month|year|o'?clock|and|between|est|edt|pst|pdt|cst|cdt|utc|gmt|bst|cet|ist)$"#,
            options: .regularExpression
        ) != nil
    }

    static func location(in text: String) -> String? {
        guard let detector = detector(.address) else { return nil }
        let ns = text as NSString
        guard let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let value = ns.substring(with: match.range).split(whereSeparator: \.isNewline).joined(separator: ", ")
        return value.isEmpty ? nil : value
    }

    // MARK: iCalendar

    /// RFC 5545 text for one event (CRLF line ends, folded at 75 octets).
    static func ics(_ event: TrayAICalendarEvent, now: Date = Date(), uid: String = UUID().uuidString) -> String {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = event.timeZone ?? .current
        day.dateFormat = "yyyyMMdd"

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//SparkV//Tray AI//EN",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:\(uid)@sparkv.local",
            "DTSTAMP:\(utc.string(from: now))",
        ]
        if event.isAllDay {
            lines.append("DTSTART;VALUE=DATE:\(day.string(from: event.start))")
            lines.append("DTEND;VALUE=DATE:\(day.string(from: event.end))")
        } else {
            lines.append("DTSTART:\(utc.string(from: event.start))")
            lines.append("DTEND:\(utc.string(from: event.end))")
        }
        lines.append("SUMMARY:\(escape(event.title))")
        if let location = event.location { lines.append("LOCATION:\(escape(location))") }
        if let notes = event.notes { lines.append("DESCRIPTION:\(escape(notes))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Lines longer than 75 octets continue on lines starting with a space,
    /// never splitting a character.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var parts: [String] = []
        var current = ""
        var octets = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = parts.isEmpty ? 75 : 74
            if octets + size > limit {
                parts.append(current)
                current = ""
                octets = 0
            }
            current.append(character)
            octets += size
        }
        parts.append(current)
        return parts.joined(separator: "\r\n ")
    }

    /// Writes the event to a uniquely named temporary .ics.
    static func writeFile(_ event: TrayAICalendarEvent) throws -> URL {
        AirDrop.pruneTemporaryFolder("SparkV-Calendar")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkV-Calendar", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = event.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        let url = directory.appendingPathComponent(name.isEmpty ? "Event" : String(name.prefix(60))).appendingPathExtension("ics")
        try ics(event).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// "Tue, 4 Nov 2025, 15:00 – 16:00" style summary for the panel.
    static func describe(_ event: TrayAICalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = event.timeZone ?? .current
        var lines = ["## \(event.title)"]
        if event.isAllDay {
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            lines.append("- When: \(formatter.string(from: event.start)) (all day)")
        } else {
            formatter.dateStyle = .full
            formatter.timeStyle = .short
            let endFormatter = DateFormatter()
            endFormatter.timeZone = formatter.timeZone
            endFormatter.dateStyle = Calendar.current.isDate(event.start, inSameDayAs: event.end) ? .none : .medium
            endFormatter.timeStyle = .short
            lines.append("- When: \(formatter.string(from: event.start)) – \(endFormatter.string(from: event.end))")
        }
        if let location = event.location { lines.append("- Where: \(location)") }
        if let notes = event.notes, notes != event.title { lines.append("- Found in: “\(String(notes.prefix(160)))”") }
        lines.append("")
        lines.append("Click Add to Calendar to review it in Calendar before it's saved.")
        return lines.joined(separator: "\n")
    }
}
