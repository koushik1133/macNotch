import Foundation

// Pure logic for the Planner (calendar, reminders, timers, weather,
// shortcuts). Foundation only, so the test harness compiles it on its own.

// MARK: - Stopwatch

/// A stopwatch kept as dates, like `TimerState`: it keeps counting while the
/// app is closed or the Mac sleeps, and needs no tick while nobody looks.
struct StopwatchState: Codable, Equatable, Sendable {
    /// Running since this date; nil while paused or idle.
    var startedAt: Date?
    /// Time counted before `startedAt`.
    var accumulated: TimeInterval = 0
    /// Elapsed time at each lap, oldest first (at most `maxLaps`).
    var laps: [TimeInterval] = []

    static let maxLaps = 99

    init(startedAt: Date? = nil, accumulated: TimeInterval = 0, laps: [TimeInterval] = []) {
        self.startedAt = startedAt
        self.accumulated = accumulated
        self.laps = laps
    }

    var isRunning: Bool { startedAt != nil }
    var isPaused: Bool { startedAt == nil && accumulated > 0 }
    var isIdle: Bool { startedAt == nil && accumulated == 0 }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + max(0, startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    /// Time since the last lap (or the start).
    func currentLap(at now: Date) -> TimeInterval {
        max(0, elapsed(at: now) - (laps.last ?? 0))
    }

    mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func pause(at now: Date) {
        guard let startedAt else { return }
        accumulated += max(0, now.timeIntervalSince(startedAt))
        self.startedAt = nil
    }

    mutating func toggle(at now: Date) {
        if isRunning { pause(at: now) } else { start(at: now) }
    }

    mutating func lap(at now: Date) {
        guard isRunning else { return }
        laps.append(elapsed(at: now))
        if laps.count > Self.maxLaps { laps.removeFirst(laps.count - Self.maxLaps) }
    }

    mutating func reset() {
        self = StopwatchState()
    }
}

// MARK: - Durations typed by the user

/// Reads the durations people type into a timer field: "5" (minutes), "90s",
/// "1:30" (1 min 30 s), "1:02:03", "1h", "1.5h", "1h30", "1h 30m 15s",
/// "45 min". Between 1 second and 24 hours; nil otherwise.
enum TimerDurationParser {
    static let maximum: TimeInterval = 24 * 3600

    static func seconds(from raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let total: TimeInterval?
        if text.contains(":") {
            total = clockSeconds(text)
        } else {
            total = unitSeconds(text)
        }
        guard let total, total >= 1, total <= maximum else { return nil }
        return total.rounded()
    }

    /// "m:ss" or "h:mm:ss".
    private static func clockSeconds(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 2 {
            guard numbers[1] < 60 else { return nil }
            return TimeInterval(numbers[0] * 60 + numbers[1])
        }
        guard numbers[1] < 60, numbers[2] < 60 else { return nil }
        return TimeInterval(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
    }

    private enum Unit { case hours, minutes, seconds }

    private static func unit(_ word: String) -> Unit? {
        switch word {
        case "h", "hr", "hrs", "hour", "hours", "std": .hours
        case "m", "min", "mins", "minute", "minutes", "'": .minutes
        case "s", "sec", "secs", "second", "seconds", "\"": .seconds
        default: nil
        }
    }

    /// Number-unit pairs; a bare number is minutes, or the next smaller unit
    /// after a unit ("1h30" = 1 h 30 min, "2m30" = 2 min 30 s).
    private static func unitSeconds(_ text: String) -> TimeInterval? {
        var index = text.startIndex
        var total: TimeInterval = 0
        var lastUnit: Unit?
        var sawNumber = false
        /// "1.5h" or "1,5h": a mark between digits.
        func isDecimalMark(at i: String.Index, after number: String) -> Bool {
            guard text[i] == "." || text[i] == ",", !number.isEmpty, !number.contains(".") else { return false }
            let next = text.index(after: i)
            return next < text.endIndex && text[next].isNumber
        }
        func skipSpaces() {
            while index < text.endIndex, text[index] == " " || text[index] == "," { index = text.index(after: index) }
        }
        skipSpaces()
        while index < text.endIndex {
            var number = ""
            while index < text.endIndex, text[index].isNumber || isDecimalMark(at: index, after: number) {
                number.append(text[index].isNumber ? text[index] : ".")
                index = text.index(after: index)
            }
            guard let value = Double(number) else { return nil }
            sawNumber = true
            skipSpaces()
            var word = ""
            while index < text.endIndex, text[index].isLetter || text[index] == "'" || text[index] == "\"" {
                word.append(text[index])
                index = text.index(after: index)
            }
            let resolved: Unit
            if word.isEmpty {
                switch lastUnit {
                case nil: resolved = .minutes
                case .hours: resolved = .minutes
                case .minutes: resolved = .seconds
                case .seconds: return nil
                }
            } else {
                guard let u = unit(word) else { return nil }
                resolved = u
            }
            switch resolved {
            case .hours: total += value * 3600
            case .minutes: total += value * 60
            case .seconds: total += value
            }
            lastUnit = resolved
            skipSpaces()
        }
        return sawNumber ? total : nil
    }

    /// "25 min", "1 h 30 min", "45 s": for labels and VoiceOver.
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 || parts.isEmpty { parts.append("\(s) s") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Calendar grid

/// Day, week and month ranges with a configurable first weekday.
enum CalendarGrid {
    /// `weekStart`: 1 = Sunday … 7 = Saturday; anything else follows the system.
    static func calendar(weekStart: Int, base: Calendar = .current) -> Calendar {
        var calendar = base
        if (1...7).contains(weekStart) { calendar.firstWeekday = weekStart }
        return calendar
    }

    static func monthStart(of date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? calendar.startOfDay(for: date)
    }

    /// First day of the week containing `date`.
    static func weekStart(of date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -lead, to: day) ?? day
    }

    /// Six full weeks (42 days, local midnights) covering the month of
    /// `date`, starting on the calendar's first weekday.
    static func monthGrid(for date: Date, calendar: Calendar) -> [Date] {
        let start = weekStart(of: monthStart(of: date, calendar: calendar), calendar: calendar)
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// The seven days of the week containing `date`.
    static func week(containing date: Date, calendar: Calendar) -> [Date] {
        let start = weekStart(of: date, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func dayInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    static func weekInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = weekStart(of: date, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        return DateInterval(start: start, end: end)
    }

    /// The month grid's whole range (for one fetch that covers it).
    static func gridInterval(for date: Date, calendar: Calendar) -> DateInterval {
        let days = monthGrid(for: date, calendar: calendar)
        guard let first = days.first, let last = days.last else { return dayInterval(date, calendar: calendar) }
        return DateInterval(start: first, end: dayInterval(last, calendar: calendar).end)
    }

    /// One- or two-letter weekday labels in grid order ("M T W T F S S").
    static func weekdayInitials(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let offset = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + offset) % 7] }
    }

    /// Moves `date` by whole months, keeping the day when it exists.
    static func addingMonths(_ months: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: months, to: date) ?? date
    }

    /// Whether an event (or all-day span) touches the local day.
    static func overlaps(start: Date, end: Date, day: Date, calendar: Calendar) -> Bool {
        let interval = dayInterval(day, calendar: calendar)
        // A zero-length event at midnight belongs to that day.
        if start == end { return interval.contains(start) && start < interval.end }
        return start < interval.end && end > interval.start
    }
}

// MARK: - Opening events

/// Where "Open" sends a calendar event.
enum CalendarOpenTarget: String, CaseIterable, Identifiable, Sendable {
    /// The macOS Calendar app (the event itself when it can be found).
    case calendarApp
    /// Google Calendar on the web, at the event's day.
    case googleWeb
    /// Outlook on the web, at the event's day.
    case outlookWeb
    /// Whichever app opens calendar files on this Mac (Fantastical, BusyCal,
    /// Outlook…). It opens the app; only Calendar can be sent to the event.
    case defaultApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendarApp: "Calendar"
        case .googleWeb: "Google Calendar (web)"
        case .outlookWeb: "Outlook (web)"
        case .defaultApp: "Default calendar app"
        }
    }
}

enum CalendarLinks {
    /// ical://ekevent/<eventIdentifier>?method=show&options=more, the form
    /// MeetingBar and Itsycal open Calendar.app with. Undocumented, so
    /// callers fall back to opening Calendar when it fails.
    static func calendarApp(eventIdentifier: String) -> URL? {
        let id = eventIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") { return url }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "ical://ekevent/\(encoded)?method=show&options=more")
    }

    private static func ymd(_ date: Date, calendar: Calendar) -> (Int, Int, Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    /// https://calendar.google.com/calendar/r/day/2026/10/27
    static func googleDay(_ date: Date, calendar: Calendar) -> URL {
        let (y, m, d) = ymd(date, calendar: calendar)
        return URL(string: "https://calendar.google.com/calendar/r/day/\(y)/\(m)/\(d)")!
    }

    /// https://outlook.office.com/calendar/view/day/2026/10/27
    static func outlookDay(_ date: Date, calendar: Calendar) -> URL {
        let (y, m, d) = ymd(date, calendar: calendar)
        return URL(string: "https://outlook.office.com/calendar/view/day/\(y)/\(m)/\(d)")!
    }
}

// MARK: - Reminders

/// "Call Mom tomorrow at 5pm" → title "Call Mom", due tomorrow 17:00.
struct ReminderDraft: Equatable, Sendable {
    var title: String
    /// Local due date (midnight when `hasTime` is false).
    var due: Date?
    var hasTime: Bool
}

enum ReminderQuickAddParser {
    /// Finds a date in the text with NSDataDetector (relative to now), takes
    /// it out of the title, and trims a dangling "at", "on", "by" or "due".
    /// Without a date, `defaultDue` (today, date only) applies when given.
    static func parse(_ raw: String, defaultDue: Date? = nil, calendar: Calendar = .current) -> ReminderDraft? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fallback = ReminderDraft(title: text, due: defaultDue.map { calendar.startOfDay(for: $0) }, hasTime: false)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date,
              let range = Range(match.range, in: text) else { return fallback }
        let phrase = String(text[range])
        var title = text
        title.removeSubrange(range)
        title = cleanTitle(title)
        guard !title.isEmpty else { return fallback }
        let timed = mentionsTime(phrase)
        return ReminderDraft(title: title, due: timed ? date : calendar.startOfDay(for: date), hasTime: timed)
    }

    /// Whether the detected phrase names a time of day, not only a day
    /// (NSDataDetector reads "tomorrow" as tomorrow at noon).
    static func mentionsTime(_ phrase: String) -> Bool {
        let lower = phrase.lowercased()
        if lower.contains("noon") || lower.contains("midnight") || lower.contains("tonight") { return true }
        let patterns = [#"\d{1,2}[:.]\d{2}"#, #"\d{1,2}\s*(am|pm|a\.m\.|p\.m\.|h\b|uhr)"#, #"\bat\s+\d{1,2}\b"#]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    private static func cleanTitle(_ text: String) -> String {
        var title = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;-–—")))
        let dangling = [" at", " on", " by", " due", " for", " from", " until"]
        var changed = true
        while changed {
            changed = false
            for word in dangling where title.lowercased().hasSuffix(word) {
                title = String(title.dropLast(word.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return title
    }
}

enum ReminderDue {
    /// Shown in the Planner: due by the end of today (overdue included), plus
    /// undated ones when asked.
    static func isShown(due: Date?, showsUndated: Bool, now: Date, calendar: Calendar) -> Bool {
        guard let due else { return showsUndated }
        return due < CalendarGrid.dayInterval(now, calendar: calendar).end
    }

    /// Date-only reminders are overdue from the next day; timed ones from their time.
    static func isOverdue(due: Date?, hasTime: Bool, now: Date, calendar: Calendar) -> Bool {
        guard let due else { return false }
        if hasTime { return due < now }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    /// Sort key: overdue first (oldest first), then today's timed ones by
    /// time, then today's date-only ones, then undated; ties by priority
    /// (1 high … 9 low, 0 none) and title.
    static func sortKey(due: Date?, hasTime: Bool, priority: Int, title: String, now: Date, calendar: Calendar) -> (Int, Double, Int, String) {
        let rank: Int
        let time: Double
        if let due {
            if isOverdue(due: due, hasTime: hasTime, now: now, calendar: calendar) {
                rank = 0
            } else {
                rank = hasTime ? 1 : 2
            }
            time = due.timeIntervalSinceReferenceDate
        } else {
            rank = 3
            time = 0
        }
        let p = priority == 0 ? 10 : priority
        return (rank, time, p, title.lowercased())
    }

    static func precedes(_ a: (Int, Double, Int, String), _ b: (Int, Double, Int, String)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if a.2 != b.2 { return a.2 < b.2 }
        return a.3 < b.3
    }

    /// "9:30", "Today", "Yesterday", "Mon", "12 Oct" (or "" when undated).
    static func label(due: Date?, hasTime: Bool, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        guard let due else { return "" }
        let day = calendar.startOfDay(for: due)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if days == 0 {
            if hasTime {
                formatter.setLocalizedDateFormatFromTemplate("jmm")
                return formatter.string(from: due)
            }
            return "Today"
        }
        if days == -1 { return "Yesterday" }
        if days == 1 { return "Tomorrow" }
        if days > -7, days < 0 {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: due)
        }
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: due)
    }
}

// MARK: - Weather

/// A city picked for the forecast (from Open-Meteo's geocoding).
struct WeatherPlace: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var admin1: String?
    var country: String?
    var countryCode: String?
    var latitude: Double
    var longitude: Double
    var timeZone: String?

    var id: String { "\(name)|\(admin1 ?? "")|\(countryCode ?? "")|\(Self.rounded(latitude))|\(Self.rounded(longitude))" }

    /// "London, England, United Kingdom" without repeats.
    var detail: String {
        var parts: [String] = []
        for part in [admin1, country] {
            if let part, !part.isEmpty, part != name, !parts.contains(part) { parts.append(part) }
        }
        return parts.joined(separator: ", ")
    }

    /// Two decimals (about 1 km): enough for a forecast, and all that leaves the Mac.
    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

struct WeatherForecast: Codable, Equatable, Sendable {
    struct Current: Codable, Equatable, Sendable {
        var time: Date
        var temperature: Double
        var apparent: Double
        var code: Int
        var isDay: Bool
        var windSpeed: Double
        var precipitation: Double
        var humidity: Int?
    }

    struct Hour: Codable, Equatable, Sendable {
        var time: Date
        var temperature: Double
        var precipitationProbability: Int
        var code: Int
        var isDay: Bool
    }

    struct Day: Codable, Equatable, Sendable {
        /// Local midnight of the city's day.
        var date: Date
        var code: Int
        var high: Double
        var low: Double
        var precipitationProbability: Int
        var sunrise: Date?
        var sunset: Date?
    }

    var current: Current
    var hourly: [Hour]
    var daily: [Day]
    var timeZoneIdentifier: String
    var fetchedAt: Date

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// The hour slot in progress, then the next ones.
    func upcomingHours(from now: Date, count: Int) -> [Hour] {
        Array(hourly.filter { $0.time.addingTimeInterval(3600) > now }.prefix(count))
    }

    /// The city's today (the first day whose span contains `now`).
    func day(containing now: Date) -> Day? {
        daily.first { $0.date <= now && $0.date.addingTimeInterval(86_400) > now } ?? daily.first
    }

    func isStale(at now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) >= maxAge || fetchedAt > now.addingTimeInterval(60)
    }
}

enum WeatherUnits: String, CaseIterable, Identifiable, Sendable {
    /// °F where the locale measures in US units, °C elsewhere.
    case automatic
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .celsius: "Celsius (°C)"
        case .fahrenheit: "Fahrenheit (°F)"
        }
    }

    func usesFahrenheit(locale: Locale = .current) -> Bool {
        switch self {
        case .celsius: false
        case .fahrenheit: true
        case .automatic: locale.measurementSystem == .us
        }
    }

    /// "18°" from Celsius.
    func degrees(_ celsius: Double, locale: Locale = .current) -> String {
        let value = usesFahrenheit(locale: locale) ? celsius * 9 / 5 + 32 : celsius
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    /// "14 km/h" or "9 mph" from km/h.
    func wind(_ kmh: Double, locale: Locale = .current) -> String {
        usesFahrenheit(locale: locale) ? "\(Int((kmh / 1.609_344).rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }
}

/// WMO weather interpretation codes (the ones Open-Meteo returns).
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: isDay ? "sun.max.fill" : "moon.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 80, 81: isDay && code >= 80 ? "cloud.sun.rain.fill" : "cloud.rain.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 66, 67: "cloud.sleet.fill"
        case 71, 73, 75, 85, 86: "cloud.snow.fill"
        case 77: "snowflake"
        case 95: "cloud.bolt.rain.fill"
        case 96, 99: "cloud.hail.fill"
        default: "cloud.fill"
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71: "Light snow"
        case 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80: "Light showers"
        case 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "Unknown"
        }
    }

    /// Rain, drizzle, snow, showers or storms.
    static func isWet(_ code: Int) -> Bool {
        (51...99).contains(code)
    }
}

/// Builds Open-Meteo requests and reads its JSON (`timeformat=unixtime`).
enum OpenMeteo {
    static let attribution = "Weather data by Open-Meteo.com"

    static func forecastURL(for place: WeatherPlace) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", WeatherPlace.rounded(place.latitude))),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", WeatherPlace.rounded(place.longitude))),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,is_day,precipitation,weather_code,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "4"),
        ]
        return components.url!
    }

    static func geocodingURL(query: String, language: String = Locale.current.language.languageCode?.identifier ?? "en") -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: String(trimmed.prefix(80))),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components.url
    }

    enum DecodeError: Error, LocalizedError {
        case missing(String)
        case api(String)

        var errorDescription: String? {
            switch self {
            case .missing(let field): "The forecast came back without \(field)."
            case .api(let reason): reason
            }
        }
    }

    private struct RawForecast: Decodable {
        struct RawCurrent: Decodable {
            let time: Double?
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let relative_humidity_2m: Double?
            let is_day: Double?
            let precipitation: Double?
            let weather_code: Double?
            let wind_speed_10m: Double?
        }

        struct RawHourly: Decodable {
            let time: [Double?]?
            let temperature_2m: [Double?]?
            let precipitation_probability: [Double?]?
            let weather_code: [Double?]?
            let is_day: [Double?]?
        }

        struct RawDaily: Decodable {
            let time: [Double?]?
            let weather_code: [Double?]?
            let temperature_2m_max: [Double?]?
            let temperature_2m_min: [Double?]?
            let precipitation_probability_max: [Double?]?
            let sunrise: [Double?]?
            let sunset: [Double?]?
        }

        let timezone: String?
        let utc_offset_seconds: Double?
        let current: RawCurrent?
        let hourly: RawHourly?
        let daily: RawDaily?
        let error: Bool?
        let reason: String?
    }

    static func decodeForecast(_ data: Data, fetchedAt: Date) throws -> WeatherForecast {
        let raw = try JSONDecoder().decode(RawForecast.self, from: data)
        if raw.error == true { throw DecodeError.api(raw.reason ?? "Open-Meteo refused the request.") }
        guard let c = raw.current, let time = c.time, let temperature = c.temperature_2m, let code = c.weather_code else {
            throw DecodeError.missing("current conditions")
        }
        let current = WeatherForecast.Current(
            time: Date(timeIntervalSince1970: time),
            temperature: temperature,
            apparent: c.apparent_temperature ?? temperature,
            code: Int(code),
            isDay: (c.is_day ?? 1) >= 0.5,
            windSpeed: c.wind_speed_10m ?? 0,
            precipitation: c.precipitation ?? 0,
            humidity: c.relative_humidity_2m.map { Int($0.rounded()) }
        )
        var hours: [WeatherForecast.Hour] = []
        if let h = raw.hourly, let times = h.time {
            for (i, t) in times.enumerated() {
                guard let t, let temp = h.temperature_2m?[safe: i] ?? nil else { continue }
                hours.append(WeatherForecast.Hour(
                    time: Date(timeIntervalSince1970: t),
                    temperature: temp,
                    precipitationProbability: Int(((h.precipitation_probability?[safe: i] ?? nil) ?? 0).rounded()),
                    code: Int((h.weather_code?[safe: i] ?? nil) ?? 3),
                    isDay: ((h.is_day?[safe: i] ?? nil) ?? 1) >= 0.5
                ))
            }
        }
        var days: [WeatherForecast.Day] = []
        if let d = raw.daily, let times = d.time {
            for (i, t) in times.enumerated() {
                guard let t, let high = d.temperature_2m_max?[safe: i] ?? nil, let low = d.temperature_2m_min?[safe: i] ?? nil else { continue }
                days.append(WeatherForecast.Day(
                    date: Date(timeIntervalSince1970: t),
                    code: Int((d.weather_code?[safe: i] ?? nil) ?? 3),
                    high: high,
                    low: low,
                    precipitationProbability: Int(((d.precipitation_probability_max?[safe: i] ?? nil) ?? 0).rounded()),
                    sunrise: (d.sunrise?[safe: i] ?? nil).map { Date(timeIntervalSince1970: $0) },
                    sunset: (d.sunset?[safe: i] ?? nil).map { Date(timeIntervalSince1970: $0) }
                ))
            }
        }
        return WeatherForecast(current: current, hourly: hours, daily: days,
                               timeZoneIdentifier: raw.timezone ?? TimeZone.current.identifier, fetchedAt: fetchedAt)
    }

    private struct RawPlaces: Decodable {
        struct RawPlace: Decodable {
            let name: String?
            let latitude: Double?
            let longitude: Double?
            let country: String?
            let country_code: String?
            let admin1: String?
            let timezone: String?
        }
        let results: [RawPlace]?
    }

    /// Geocoding results; an answer without "results" means no match.
    static func decodePlaces(_ data: Data) throws -> [WeatherPlace] {
        let raw = try JSONDecoder().decode(RawPlaces.self, from: data)
        var seen = Set<String>()
        return (raw.results ?? []).compactMap { r -> WeatherPlace? in
            guard let name = r.name, let lat = r.latitude, let lon = r.longitude else { return nil }
            let place = WeatherPlace(name: name, admin1: r.admin1, country: r.country, countryCode: r.country_code,
                                     latitude: lat, longitude: lon, timeZone: r.timezone)
            return seen.insert(place.id).inserted ? place : nil
        }
    }
}

enum RainAlert {
    /// The first hour slot overlapping the next `window` whose chance of
    /// precipitation reaches `threshold` %, unless it is already wet now.
    static func upcoming(in forecast: WeatherForecast, now: Date, threshold: Int, window: TimeInterval = 3600) -> WeatherForecast.Hour? {
        guard !WeatherCode.isWet(forecast.current.code), forecast.current.precipitation < 0.1 else { return nil }
        return forecast.hourly.first { hour in
            hour.time.addingTimeInterval(3600) > now
                && hour.time < now.addingTimeInterval(window)
                && hour.precipitationProbability >= threshold
        }
    }
}

// MARK: - Shortcuts

struct ShortcutInfo: Equatable, Hashable, Sendable, Identifiable {
    let name: String
    /// Stable across renames; nil when the CLI gave none.
    let identifier: String?
    var id: String { identifier ?? name }
}

enum ShortcutListParser {
    private static let identified = try? NSRegularExpression(pattern: #"^(.*\S)\s+\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)\s*$"#)

    /// Lines of `shortcuts list --show-identifiers`: "Name (UUID)". A line
    /// without an identifier keeps just its name.
    static func parse(_ output: String) -> [ShortcutInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            if let match = identified?.firstMatch(in: text, range: range),
               let nameRange = Range(match.range(at: 1), in: text),
               let idRange = Range(match.range(at: 2), in: text) {
                return ShortcutInfo(name: String(text[nameRange]), identifier: String(text[idRange]).uppercased())
            }
            return ShortcutInfo(name: text, identifier: nil)
        }
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
