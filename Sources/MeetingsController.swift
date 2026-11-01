import AppKit
import Carbon.HIToolbox
import Combine
import EventKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// One calendar event (a remaining meeting today, or any event in the
/// Planner's agenda), copied out of EventKit so it can cross from the fetch
/// queue to the main actor.
struct CalendarMeeting: Identifiable, Sendable, Equatable {
    /// Unique per occurrence (recurring events share an event identifier).
    let id: String
    /// EventKit's `eventIdentifier`.
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let calendarColor: CalendarRGBA
    let link: MeetingLink?
    var isAllDay = false
    /// `EKCalendar.calendarIdentifier`.
    var calendarID = ""
    var calendarTitle = ""
    var location: String? = nil
    /// The event's own URL when it isn't the call link.
    var eventURL: URL? = nil
    /// Marked "free" (holds, reminders): shown in the agenda, never a heads-up.
    var isFree = false

    func hasStarted(at now: Date) -> Bool { start <= now }
}

/// A calendar the user can show or hide (Settings, the Calendars menu).
struct CalendarInfo: Identifiable, Sendable, Equatable {
    /// `EKCalendar.calendarIdentifier`.
    let id: String
    let title: String
    let color: CalendarRGBA
    /// Account ("iCloud", "Google", "Exchange", "On My Mac").
    let sourceTitle: String
}

/// What one refresh of today returns.
struct CalendarSnapshot: Sendable, Equatable {
    /// Timed events that haven't ended (heads-up filter applied), soonest first.
    var meetings: [CalendarMeeting] = []
    /// Today's all-day events (display only: they never alert).
    var allDay: [CalendarMeeting] = []
    var calendars: [CalendarInfo] = []
}

/// Where a meeting stands relative to the clock.
enum MeetingTiming: Equatable, Sendable {
    /// Starts in this many minutes (rounded up, at least 2: the last minute
    /// before the start already counts as `now`).
    case upcoming(minutes: Int)
    /// From one minute before the start until five minutes after it: the
    /// moment to join.
    case now
    /// Started more than five minutes ago and hasn't ended.
    case inProgress
    case ended

    var isJoinMoment: Bool { self == .now }
    var hasStarted: Bool { self == .now || self == .inProgress }
}

/// Sendable stand-in for a calendar's NSColor.
struct CalendarRGBA: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let fallback = CalendarRGBA(red: 0.35, green: 0.6, blue: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor?) {
        guard let rgb = color?.usingColorSpace(.sRGB) else {
            self = .fallback
            return
        }
        self.init(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent),
            alpha: Double(rgb.alphaComponent)
        )
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// A video-call link found in an event.
struct MeetingLink: Sendable, Equatable {
    enum Provider: String, Sendable, CaseIterable {
        case zoom, googleMeet, teams, webex, slack, faceTime, around, whereby

        var displayName: String {
            switch self {
            case .zoom: "Zoom"
            case .googleMeet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .webex: "Webex"
            case .slack: "Slack huddle"
            case .faceTime: "FaceTime"
            case .around: "Around"
            case .whereby: "Whereby"
            }
        }

        /// Short name for tight spots ("Join on Teams").
        var shortName: String {
            switch self {
            case .googleMeet: "Meet"
            case .teams: "Teams"
            case .slack: "Slack"
            default: displayName
            }
        }

        /// Desktop apps that open this provider's links, newest first. Their
        /// icon is shown next to the Join button when one is installed.
        var appBundleIDs: [String] {
            switch self {
            case .zoom: ["us.zoom.xos"]
            case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
            case .webex: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
            case .slack: ["com.tinyspeck.slackmacgap"]
            case .faceTime: ["com.apple.FaceTime"]
            case .around: ["co.teamport.around"]
            // Chrome's installed Google Meet app (PWA).
            case .googleMeet: ["com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"]
            case .whereby: []
            }
        }

        /// Brand color for the glyph shown when no app icon is available.
        var brand: CalendarRGBA {
            switch self {
            case .zoom: CalendarRGBA(red: 0.043, green: 0.361, blue: 1)
            case .googleMeet: CalendarRGBA(red: 0, green: 0.537, blue: 0.482)
            case .teams: CalendarRGBA(red: 0.384, green: 0.392, blue: 0.655)
            case .webex: CalendarRGBA(red: 0.027, green: 0.643, blue: 0.82)
            case .slack: CalendarRGBA(red: 0.56, green: 0.22, blue: 0.58)
            case .faceTime: CalendarRGBA(red: 0.2, green: 0.78, blue: 0.35)
            case .around: CalendarRGBA(red: 0.96, green: 0.36, blue: 0.4)
            case .whereby: CalendarRGBA(red: 0.39, green: 0.29, blue: 1)
            }
        }

        var symbolName: String {
            switch self {
            case .slack: "headphones"
            case .faceTime: "video.fill"
            default: "video.fill"
            }
        }
    }

    let provider: Provider
    /// Web link (https) whenever one can be derived; otherwise the native one
    /// as found (e.g. `facetime://`).
    let url: URL
    /// App URL scheme form (zoommtg://, msteams:, slack://) when one exists.
    let nativeURL: URL?
}

// MARK: - Link detection

/// Finds Zoom, Meet, Teams, Webex, Slack huddle, FaceTime, Around and Whereby
/// links in an event's URL, location and notes (checked in that order, the
/// order MeetingBar ranks them in). Pure Foundation, so it can be exercised
/// outside the app.
enum MeetingLinkDetector {
    static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        let sources = [url?.absoluteString, location, notes]
        for case let text? in sources where !text.isEmpty {
            if let link = detect(in: text) { return link }
        }
        return nil
    }

    /// The earliest meeting link in `text`, or nil.
    static func detect(in rawText: String) -> MeetingLink? {
        let decoded = rawText
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#61;", with: "=")
        let text = unwrapRedirects(in: decoded)
        let range = NSRange(text.startIndex..., in: text)
        var best: (location: Int, provider: MeetingLink.Provider, match: String)?
        for (provider, regex) in patterns {
            guard let result = regex.firstMatch(in: text, range: range),
                  let swiftRange = Range(result.range, in: text) else { continue }
            if best == nil || result.range.location < best!.location {
                best = (result.range.location, provider, String(text[swiftRange]))
            }
        }
        guard let best else { return nil }
        return makeLink(provider: best.provider, matched: trimTrailing(best.match))
    }

    // MARK: Patterns

    /// Characters a link may contain in free text.
    private static let urlChars = #"[^\s<>"'`]"#
    /// Not glued to a preceding host/path character, so "notzoom.us" or the
    /// middle of another URL doesn't match.
    private static let lead = #"(?<![\w.@/%-])"#

    /// Patterns follow MeetingBar's catalogue (leits/MeetingBar,
    /// MeetingProvider.swift), tightened so a bare marketing page
    /// (zoom.us/pricing, whereby.com) is not taken for a meeting.
    private static let patterns: [(MeetingLink.Provider, NSRegularExpression)] = {
        let u = urlChars
        let specs: [(MeetingLink.Provider, String)] = [
            (.zoom, lead + #"(?:https?://)?(?:[a-z0-9-]+\.)*(?:zoom\.us|zoom\.com|zoom\.com\.cn|zoom\.de|zoom-x\.de|zoomgov\.com)/(?:j|my|w|s|wc/join|webinar/register)/"# + u + "+"),
            (.zoom, lead + #"zoommtg://"# + u + "+"),
            (.googleMeet, lead + #"(?:https?://)?meet\.google\.com/(?:_meet/)?(?:[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z0-9-])|lookup/[a-z0-9_-]+)(?:\?"# + u + "*)?"),
            (.teams, lead + #"(?:https?://)?(?:gov\.)?teams\.microsoft\.(?:com|us)/(?:l/meetup-join|meet)/"# + u + "+"),
            (.teams, lead + #"(?:https?://)?teams\.live\.com/meet/"# + u + "+"),
            (.teams, lead + #"msteams:/{0,2}l/meetup-join/"# + u + "+"),
            (.webex, lead + #"(?:https?://)?(?!www\.|help\.)(?:[a-z0-9-]+\.)+webex\.com/(?:[^\s<>"'/]+/)?(?:j\.php\?|meet/|join/|wbxmjs/joinservice)"# + u + "*"),
            (.slack, lead + #"(?:https?://)?(?:[a-z0-9-]+\.)*slack\.com/huddle/"# + u + "+"),
            (.slack, lead + #"slack://join-huddle\?"# + u + "+"),
            (.faceTime, lead + #"(?:https?://)?facetime\.apple\.com/join"# + u + "*"),
            (.faceTime, lead + #"facetime(?:-audio)?://"# + u + "+"),
            (.around, lead + #"(?:https?://)?(?:meet\.)?around\.co/(?!$|\s)(?:r/)?[a-z0-9_-]"# + u + "*"),
            (.whereby, lead + #"(?:https?://)?(?:(?!www\.)[a-z0-9-]+\.)?whereby\.com/(?!information|pricing|blog|user|org|login|signup|download|support)[a-z0-9_-]+"# + u + "*"),
        ]
        return specs.compactMap { provider, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (provider, $0) }
        }
    }()

    /// Outlook Safe Links and Google redirect wrappers hide the real link in a
    /// percent-encoded query parameter; swap each for the link it carries.
    private static let redirectRegex = try? NSRegularExpression(
        pattern: #"https?://(?:[a-z0-9-]+\.)*(?:safelinks\.protection\.outlook\.com/?|google\.[a-z]{2,}(?:\.[a-z]{2,})?/url)\?[^\s<>"']+"#,
        options: [.caseInsensitive]
    )

    static func unwrapRedirects(in text: String) -> String {
        guard let regex = redirectRegex else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let components = URLComponents(string: String(result[range])),
                  let inner = components.queryItems?.first(where: { $0.name == "url" || $0.name == "q" })?.value,
                  inner.lowercased().hasPrefix("http") else { continue }
            result.replaceSubrange(range, with: inner)
        }
        return result
    }

    /// Drops sentence punctuation and unbalanced closing brackets that free
    /// text puts right after a link.
    static func trimTrailing(_ match: String) -> String {
        var s = Substring(match)
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = s.last {
            if ".,;:!?*".contains(last) {
                s = s.dropLast()
            } else if let opener = pairs[last], s.filter({ $0 == opener }).count < s.filter({ $0 == last }).count {
                s = s.dropLast()
            } else {
                break
            }
        }
        return String(s)
    }

    // MARK: Building links

    private static func makeURL(_ string: String) -> URL? {
        let lower = string.lowercased()
        let schemes = ["http://", "https://", "zoommtg:", "msteams:", "facetime", "slack:"]
        let hasScheme = schemes.contains { lower.hasPrefix($0) }
        let full = hasScheme ? string : "https://" + string
        if let url = URL(string: full) { return url }
        let allowed = CharacterSet.urlQueryAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: "#%"))
        return full.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    static func makeLink(provider: MeetingLink.Provider, matched: String) -> MeetingLink? {
        guard let found = makeURL(matched) else { return nil }
        let scheme = found.scheme?.lowercased()
        switch provider {
        case .zoom:
            if scheme == "zoommtg" {
                return MeetingLink(provider: .zoom, url: zoomWebURL(fromNative: found) ?? found, nativeURL: found)
            }
            return MeetingLink(provider: .zoom, url: found, nativeURL: zoomNativeURL(fromWeb: found))
        case .teams:
            if scheme == "msteams" {
                let path = found.absoluteString.dropFirst("msteams:".count).drop(while: { $0 == "/" })
                let web = URL(string: "https://teams.microsoft.com/" + path)
                return MeetingLink(provider: .teams, url: web ?? found, nativeURL: found)
            }
            return MeetingLink(provider: .teams, url: found, nativeURL: teamsNativeURL(fromWeb: found))
        case .slack:
            if scheme == "slack" {
                return MeetingLink(provider: .slack, url: slackWebURL(fromNative: found) ?? found, nativeURL: found)
            }
            return MeetingLink(provider: .slack, url: found, nativeURL: slackNativeURL(fromWeb: found))
        case .googleMeet, .webex, .faceTime, .around, .whereby:
            return MeetingLink(provider: provider, url: found, nativeURL: nil)
        }
    }

    /// https://us02web.zoom.us/j/850123?pwd=X → zoommtg://us02web.zoom.us/join?action=join&confno=850123&pwd=X.
    /// Only /j/ links carry a meeting number; personal rooms (/my/) and the
    /// rest open on the web, which hands off to the app itself.
    static func zoomNativeURL(fromWeb url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "j" else { return nil }
        let confno = String(parts[1])
        guard !confno.isEmpty, confno.allSatisfy(\.isNumber) else { return nil }
        var native = URLComponents()
        native.scheme = "zoommtg"
        native.host = host
        native.path = "/join"
        var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: confno)]
        if let pwd = components.queryItems?.first(where: { $0.name == "pwd" })?.value {
            items.append(URLQueryItem(name: "pwd", value: pwd))
        }
        native.queryItems = items
        return native.url
    }

    /// zoommtg://zoom.us/join?confno=123&pwd=X → https://zoom.us/j/123?pwd=X.
    static func zoomWebURL(fromNative url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let confno = components.queryItems?.first(where: { $0.name == "confno" })?.value,
              !confno.isEmpty else { return nil }
        var web = URLComponents()
        web.scheme = "https"
        web.host = components.host.flatMap { $0.isEmpty ? nil : $0 } ?? "zoom.us"
        web.path = "/j/" + confno
        if let pwd = components.queryItems?.first(where: { $0.name == "pwd" })?.value {
            web.queryItems = [URLQueryItem(name: "pwd", value: pwd)]
        }
        return web.url
    }

    /// https://teams.microsoft.com/l/meetup-join/… → msteams:/l/meetup-join/…
    /// (percent-encoding kept as is). The newer short links
    /// (teams.microsoft.com/meet/<id>?p=…) become
    /// msteams://teams.microsoft.com/meet/<id>?p=…, the form MeetingBar
    /// opens Teams with. teams.live.com (Teams free) stays on the web, which
    /// offers to open the app.
    static func teamsNativeURL(fromWeb url: URL) -> URL? {
        let string = url.absoluteString
        let lower = string.lowercased()
        let prefixes = ["https://teams.microsoft.com/l/meetup-join/", "http://teams.microsoft.com/l/meetup-join/"]
        if let prefix = prefixes.first(where: { lower.hasPrefix($0) }) {
            let rest = string.dropFirst(prefix.count)
            return URL(string: "msteams:/l/meetup-join/" + rest)
        }
        let meetPrefixes = ["https://teams.microsoft.com/meet/", "http://teams.microsoft.com/meet/"]
        if let prefix = meetPrefixes.first(where: { lower.hasPrefix($0) }), string.count > prefix.count {
            return URL(string: "msteams://teams.microsoft.com/meet/" + string.dropFirst(prefix.count))
        }
        return nil
    }

    /// https://app.slack.com/huddle/T0123/C0456 → slack://join-huddle?team=T0123&id=C0456
    /// (MeetingBar's SlackHuddleOpenStrategy).
    static func slackNativeURL(fromWeb url: URL) -> URL? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "huddle", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        var native = URLComponents()
        native.scheme = "slack"
        native.host = "join-huddle"
        native.queryItems = [URLQueryItem(name: "team", value: parts[1]), URLQueryItem(name: "id", value: parts[2])]
        return native.url
    }

    static func slackWebURL(fromNative url: URL) -> URL? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let team = items.first(where: { $0.name == "team" })?.value, !team.isEmpty,
              let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        return URL(string: "https://app.slack.com/huddle/\(team)/\(id)")
    }
}

// MARK: - Calendar access

/// Owns the EventKit store and does every fetch on its own serial queue, so
/// the main thread never waits on the calendar database. The store is created
/// only when first needed (after access is granted). PermissionCenter asks.
private final class CalendarSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.Meetings", qos: .userInitiated)
    private let lock = NSLock()
    private var storage: EKEventStore?

    private var store: EKEventStore {
        lock.lock()
        defer { lock.unlock() }
        if let storage { return storage }
        let created = EKEventStore()
        storage = created
        return created
    }

    /// Forgets cached state, e.g. after access was granted in System Settings.
    func reset() {
        queue.async { [self] in
            lock.lock()
            let existing = storage
            lock.unlock()
            existing?.reset()
        }
    }

    /// Events that haven't ended yet, from now to the end of today (or a bit
    /// past it, so a meeting just after midnight still gets its heads-up),
    /// today's all-day events, and the calendar list. Hidden calendars are
    /// left out everywhere.
    func today(now: Date, lookahead: TimeInterval, hidden: Set<String>) async -> CalendarSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: fetchToday(now: now, lookahead: lookahead, hidden: hidden))
            }
        }
    }

    /// Every event between the dates (all-day ones included; cancelled and
    /// declined ones left out), for the Planner's day, week and month views.
    func events(from start: Date, to end: Date, hidden: Set<String>) async -> [CalendarMeeting] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: fetchRange(from: start, to: end, hidden: hidden))
            }
        }
    }

    /// The calendars to search: nil for all, [] when every one is hidden.
    private func calendars(in store: EKEventStore, hidden: Set<String>) -> [EKCalendar]? {
        guard !hidden.isEmpty else { return nil }
        return store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
    }

    private func calendarList(_ store: EKEventStore) -> [CalendarInfo] {
        store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: CalendarRGBA($0.color), sourceTitle: $0.source?.title ?? "Other") }
            .sorted { $0.sourceTitle == $1.sourceTitle ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                                                       : $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending }
    }

    private func fetchToday(now: Date, lookahead: TimeInterval, hidden: Set<String>) -> CalendarSnapshot {
        let store = self.store
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        var snapshot = CalendarSnapshot(calendars: calendarList(store))
        let selected = calendars(in: store, hidden: hidden)
        if let selected, selected.isEmpty { return snapshot }
        let end = max(endOfDay, now.addingTimeInterval(lookahead))
        // Start a day back so a long meeting that is still running is included;
        // `finish > now` below drops the ones that are over.
        let from = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: from, end: end, calendars: selected)
        var meetings: [CalendarMeeting] = []
        var allDay: [CalendarMeeting] = []
        for event in store.events(matching: predicate) {
            guard let start = event.startDate, let finish = event.endDate else { continue }
            let me = event.attendees?.first(where: \.isCurrentUser)
            let isCanceled = event.status == .canceled
            let isDeclined = me?.participantStatus == .declined
            if event.isAllDay {
                // All-day events touching today, for display only.
                guard !isCanceled, !isDeclined, start < endOfDay, finish > startOfDay else { continue }
                allDay.append(Self.meeting(from: event, start: start, end: finish))
                continue
            }
            guard finish > now else { continue }
            let skip = MeetingFilter.shouldSkip(
                isAllDay: false,
                isCanceled: isCanceled,
                isDeclined: isDeclined,
                isFree: event.availability == .free
            )
            guard !skip else { continue }
            meetings.append(Self.meeting(from: event, start: start, end: finish))
        }
        snapshot.meetings = meetings.sorted(by: Self.order)
        snapshot.allDay = allDay.sorted(by: Self.order)
        return snapshot
    }

    private func fetchRange(from start: Date, to end: Date, hidden: Set<String>) -> [CalendarMeeting] {
        let store = self.store
        let selected = calendars(in: store, hidden: hidden)
        if let selected, selected.isEmpty { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate)
            .compactMap { event -> CalendarMeeting? in
                guard let s = event.startDate, let e = event.endDate else { return nil }
                let me = event.attendees?.first(where: \.isCurrentUser)
                guard event.status != .canceled, me?.participantStatus != .declined else { return nil }
                return Self.meeting(from: event, start: s, end: e)
            }
            .sorted(by: Self.order)
    }

    /// All-day first, then by start, then by title.
    private static func order(_ a: CalendarMeeting, _ b: CalendarMeeting) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        return a.start == b.start ? a.title < b.title : a.start < b.start
    }

    private static func meeting(from event: EKEvent, start: Date, end: Date) -> CalendarMeeting {
        let eventID = event.eventIdentifier ?? event.calendarItemIdentifier
        let rawTitle = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let link = MeetingLinkDetector.detect(url: event.url, location: event.location, notes: event.notes)
        let ownURL = event.url.flatMap { url in link?.url == url || link?.nativeURL == url ? nil : url }
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarMeeting(
            id: "\(eventID)@\(Int(start.timeIntervalSince1970))",
            eventID: eventID,
            title: rawTitle.isEmpty ? "Untitled event" : rawTitle,
            start: start,
            end: end,
            calendarColor: CalendarRGBA(event.calendar?.color),
            link: link,
            isAllDay: event.isAllDay,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            location: location?.isEmpty == false ? location : nil,
            eventURL: ownURL,
            isFree: event.availability == .free
        )
    }
}

// MARK: - Calendar settings

/// Which calendars show, all-day events, the first weekday and where events
/// open. Saved under `meetings.*` in UserDefaults. Calendars are stored as
/// the hidden ones, so a calendar added later shows up on its own.
@MainActor
final class CalendarPreferences: ObservableObject {
    static let shared = CalendarPreferences()

    enum Keys {
        static let hidden = "meetings.hiddenCalendarIDs"
        static let allDay = "meetings.showsAllDay"
        static let weekStart = "meetings.weekStart"
        static let openIn = "meetings.openIn"
    }

    @Published var hiddenCalendarIDs: Set<String> {
        didSet { defaults.set(Array(hiddenCalendarIDs).sorted(), forKey: Keys.hidden) }
    }
    /// All-day events as chips in Today and the agenda (they never alert).
    @Published var showsAllDay: Bool { didSet { defaults.set(showsAllDay, forKey: Keys.allDay) } }
    /// 0 follows the system; 1 = Sunday … 7 = Saturday.
    @Published var weekStart: Int { didSet { defaults.set(weekStart, forKey: Keys.weekStart) } }
    @Published var openTarget: CalendarOpenTarget { didSet { defaults.set(openTarget.rawValue, forKey: Keys.openIn) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Keys.hidden) ?? [])
        showsAllDay = defaults.object(forKey: Keys.allDay) as? Bool ?? true
        let start = defaults.integer(forKey: Keys.weekStart)
        weekStart = (0...7).contains(start) ? start : 0
        openTarget = defaults.string(forKey: Keys.openIn).flatMap(CalendarOpenTarget.init(rawValue:)) ?? .calendarApp
    }

    func isShown(_ calendarID: String) -> Bool { !hiddenCalendarIDs.contains(calendarID) }

    func setShown(_ calendarID: String, _ shown: Bool) {
        if shown { hiddenCalendarIDs.remove(calendarID) } else { hiddenCalendarIDs.insert(calendarID) }
    }

    func binding(for calendarID: String) -> Binding<Bool> {
        Binding(get: { self.isShown(calendarID) }, set: { self.setShown(calendarID, $0) })
    }

    /// The user's calendar with the chosen first weekday.
    var calendar: Calendar { CalendarGrid.calendar(weekStart: weekStart) }

    static let weekStartChoices: [(value: Int, title: String)] = [
        (0, "System Setting"), (1, "Sunday"), (2, "Monday"), (7, "Saturday"),
    ]
}

/// Which events never get a heads-up or a Join (the MeetingBar defaults):
/// all-day, cancelled, declined, and "free" time (reminders, holds).
enum MeetingFilter {
    static func shouldSkip(isAllDay: Bool, isCanceled: Bool, isDeclined: Bool, isFree: Bool) -> Bool {
        isAllDay || isCanceled || isDeclined || isFree
    }
}

// MARK: - Controller

/// Today's remaining meetings for the Today tab, plus a live activity under
/// the notch from the heads-up time (1, 5, 10 or 15 minutes) before a meeting
/// until 5 minutes after it starts, and a global Join Next Meeting action
/// (⌃⌥J by default).
@MainActor
final class MeetingsController: ObservableObject {
    enum Access: Equatable {
        /// Not asked yet (or only write access): show "Connect Calendar".
        case notDetermined
        case granted
        /// Denied or restricted: point to System Settings.
        case denied
    }

    /// Most recently created controller, for menu items and App Intents that
    /// have no environment. Weak, so it never keeps one alive.
    static weak var current: MeetingsController?

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            AppLog.log("Meetings: \(isEnabled ? "enabled" : "disabled")")
            guard isStarted else { return }
            if isEnabled { beginMonitoringIfAuthorized() } else { endMonitoring(clear: true) }
            updateHotkey()
            updateAccessWatch()
        }
    }

    /// Minutes before a meeting the heads-up appears: one of `leadChoices`.
    @Published var leadMinutes: Int {
        didSet {
            // Through @Published, assigning here re-runs this observer with
            // the clamped value, which then persists it.
            let clamped = Self.clampLead(leadMinutes)
            guard clamped == leadMinutes else {
                leadMinutes = clamped
                return
            }
            guard leadMinutes != oldValue else { return }
            defaults.set(leadMinutes, forKey: Self.leadKey)
            AppLog.log("Meetings: heads-up \(leadMinutes) min before")
            updateActivity(now: Date())
            restartTicking()
        }
    }

    /// Whether ⌃⌥J joins the next meeting from anywhere.
    @Published var joinShortcutEnabled: Bool {
        didSet {
            guard joinShortcutEnabled != oldValue else { return }
            defaults.set(joinShortcutEnabled, forKey: Self.shortcutKey)
            updateHotkey()
        }
    }

    @Published private(set) var access: Access {
        didSet {
            guard access != oldValue else { return }
            updateAccessWatch()
            // What the agenda may show changed.
            calendarRevision &+= 1
        }
    }
    /// Today's remaining events (not all-day, not declined, not cancelled,
    /// not free, not in a hidden calendar), soonest first.
    @Published private(set) var meetings: [CalendarMeeting] = []
    /// Today's all-day events from the shown calendars (display only).
    @Published private(set) var allDayEvents: [CalendarMeeting] = []
    /// Every event calendar, for the Calendars menu and Settings.
    @Published private(set) var calendars: [CalendarInfo] = []
    /// Bumped when the calendar database or the calendar settings change,
    /// so the Planner's agenda knows to fetch again.
    @Published private(set) var calendarRevision = 0
    /// Updated every refresh so "Now" labels stay current.
    @Published private(set) var now = Date()
    @Published private(set) var isRequestingAccess = false
    /// When EventKit was last read (the minute tick reuses that result).
    private var lastFetchAt: Date?
    /// False when macOS refused the shortcut (another app owns it).
    @Published private(set) var isShortcutRegistered = false

    nonisolated static let leadChoices = [1, 5, 10, 15]
    nonisolated static let defaultLeadMinutes = 10
    /// The heads-up and the "Now" state last this long after the start.
    nonisolated static let trailTime: TimeInterval = 5 * 60
    /// "Now" starts this long before the start.
    nonisolated static let nowLeadTime: TimeInterval = 60
    static let activityPriority = 60
    /// Join confirmations and "no meeting" notices sit above the band.
    static let noticePriority = 75
    static let joinShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey))

    private static let enabledKey = "meetings.enabled"
    private static let leadKey = "meetings.leadMinutes"
    private static let shortcutKey = "meetings.joinShortcut"
    private static let noticeID = "meeting.notice"
    /// How often access is re-read while it isn't granted yet.

    private let activities: ActivityCenter
    private let defaults: UserDefaults
    private let source = CalendarSource()
    private let hotkey = ScreenRegionHotkey()
    private var isStarted = false
    private var isMonitoring = false
    private var observers: [NSObjectProtocol] = []
    private var tickTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Follows calendar access through PermissionCenter (no polling here).
    private var accessWatch: AnyCancellable?
    /// Follows the calendar settings (hidden calendars, all-day).
    private var preferencesWatch: AnyCancellable?
    private let preferences: CalendarPreferences
    /// Occurrences (`CalendarMeeting.id`) the user already joined: their
    /// "Now" band stops holding the space under the notch and rests in the
    /// wings beside the camera instead.
    private var joinedIDs: Set<String> = []
    private var refreshGeneration = 0
    private var requestWasRefused = false
    /// The live activity currently posted and the text it shows, so it is
    /// re-posted only when the minute count changes.
    private var postedActivity: (id: String, signature: String)?
    /// The calendar settings the fetches depend on, as last seen: only a
    /// change to these refetches (not the first weekday or "open in").
    private var fetchSettings: (hidden: Set<String>, allDay: Bool) = ([], true)

    init(activities: ActivityCenter, defaults: UserDefaults = .standard, preferences: CalendarPreferences? = nil) {
        self.activities = activities
        self.defaults = defaults
        self.preferences = preferences ?? .shared
        isEnabled = (defaults.object(forKey: Self.enabledKey) as? Bool) ?? true
        leadMinutes = Self.clampLead((defaults.object(forKey: Self.leadKey) as? Int) ?? Self.defaultLeadMinutes)
        joinShortcutEnabled = (defaults.object(forKey: Self.shortcutKey) as? Bool) ?? true
        access = Self.currentAccess(refused: false)
        hotkey.onPress = { [weak self] in self?.joinNextMeeting() }
        Self.current = self
        fetchSettings = (self.preferences.hiddenCalendarIDs, self.preferences.showsAllDay)
        preferencesWatch = self.preferences.objectWillChange.sink { [weak self] _ in
            // After the change lands.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let settings = (hidden: self.preferences.hiddenCalendarIDs, allDay: self.preferences.showsAllDay)
                    guard settings != self.fetchSettings else { return }
                    self.fetchSettings = settings
                    self.calendarRevision &+= 1
                    self.scheduleRefresh()
                }
            }
        }
    }

    var leadTime: TimeInterval { TimeInterval(leadMinutes) * 60 }

    // MARK: Lifecycle

    /// Reads the calendar only if access was already granted; never prompts.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        if isEnabled { beginMonitoringIfAuthorized() }
        updateHotkey()
        updateAccessWatch()
    }

    func stop() {
        isStarted = false
        endMonitoring(clear: true)
        updateHotkey()
        updateAccessWatch()
    }

    // MARK: Actions

    /// Asks for full calendar access (the "Connect Calendar" button). The
    /// system prompt shows only while macOS hasn't asked yet; once refused,
    /// PermissionCenter opens the Calendars pane in System Settings instead.
    func requestAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        AppLog.log("Meetings: requesting calendar access")
        Task { [weak self] in
            let status = await PermissionCenter.shared.request(.calendars, from: "Meetings")
            guard let self else { return }
            let granted = status.isGranted
            self.isRequestingAccess = false
            // Still undetermined means the prompt was deferred, not refused.
            self.requestWasRefused = !granted && status != .notDetermined
            self.access = Self.currentAccess(refused: self.requestWasRefused)
            AppLog.log("Meetings: calendar access \(status.rawValue)")
            if self.access == .granted, self.isStarted, self.isEnabled {
                // The grant came through another event store.
                self.source.reset()
                self.beginMonitoringIfAuthorized()
            }
        }
    }

    /// Picks up access granted or revoked in System Settings; cheap enough
    /// to call whenever the Today tab appears.
    func recheckAuthorization() {
        let updated = Self.currentAccess(refused: requestWasRefused)
        guard updated != access else {
            if access == .granted, isMonitoring { scheduleRefresh() }
            return
        }
        AppLog.log("Meetings: calendar access changed to \(updated)")
        access = updated
        guard isStarted, isEnabled else { return }
        if updated == .granted {
            source.reset()
            beginMonitoringIfAuthorized()
        } else {
            endMonitoring(clear: true)
        }
    }

    func openPrivacySettings() {
        PermissionCenter.shared.openSettings(.calendars, from: "Meetings")
    }

    /// Opens the meeting in its app when installed (Zoom, Teams, Slack, the
    /// Google Meet app), otherwise the web link in the default browser.
    func join(_ meeting: CalendarMeeting) {
        guard let link = meeting.link else { return }
        let plan = Self.openPlan(for: link, canOpen: Self.canOpen, appURL: Self.appURL(bundleID:))
        // No title or link in the log: it is a plain file in ~/Library/Logs.
        switch plan {
        case .url(let target):
            AppLog.log("Meetings: joining a \(link.provider.displayName) call via \(target.scheme ?? "?")")
            if !NSWorkspace.shared.open(target), target != link.url {
                NSWorkspace.shared.open(link.url)
            }
        case .app(let target, let app):
            AppLog.log("Meetings: joining a \(link.provider.displayName) call in its app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            let web = link.url
            NSWorkspace.shared.open([target], withApplicationAt: app, configuration: configuration) { running, error in
                guard running == nil || error != nil else { return }
                Task { @MainActor in
                    AppLog.log("Meetings: the meeting app didn't open, using the browser")
                    NSWorkspace.shared.open(web)
                }
            }
        }
        markJoined(meeting)
    }

    /// How Join opens a link.
    enum OpenPlan: Equatable, Sendable {
        /// Open this URL with whatever handles it (zoommtg:, msteams:, https).
        case url(URL)
        /// Open the web link in this app (Chrome's Google Meet app).
        case app(URL, appURL: URL)
    }

    /// Native scheme when an app handles it; Google Meet in its installed
    /// app; else the web link.
    nonisolated static func openPlan(for link: MeetingLink, canOpen: (URL) -> Bool, appURL: (String) -> URL?) -> OpenPlan {
        if link.provider == .googleMeet, link.url.scheme?.lowercased() == "https",
           let app = link.provider.appBundleIDs.lazy.compactMap(appURL).first {
            return .app(link.url, appURL: app)
        }
        return .url(openTarget(for: link, canOpen: canOpen))
    }

    nonisolated private static func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Stops the "Now" band for `meeting` from holding the space under the
    /// notch (it rests in the wings). Internal so tests can call it without
    /// opening anything.
    func markJoined(_ meeting: CalendarMeeting) {
        guard joinedIDs.insert(meeting.id).inserted else { return }
        updateActivity(now: Date())
    }

    /// A call for this event was detected (the user is in it): its "Now"
    /// band rests in the wings like after Join.
    func markJoined(eventID: String) {
        let now = Date()
        guard let meeting = meetings.first(where: { $0.eventID == eventID && $0.end > now && Self.isInHeadsUp($0, now: now, lead: leadTime) })
            ?? meetings.first(where: { $0.eventID == eventID && $0.start <= now && $0.end > now }) else { return }
        markJoined(meeting)
    }

    /// The meeting ⌃⌥J and "Join Next Meeting" open, if any.
    var nextJoinableMeeting: CalendarMeeting? {
        Self.meetingToJoin(in: meetings, now: Date())
    }

    /// Joins the meeting that is starting or running now, else the next one
    /// with a call link today. Shows a short notice under the notch either way.
    func joinNextMeeting() {
        guard isEnabled else { return }
        if access != .granted {
            postNotice(systemImage: "calendar.badge.exclamationmark", text: "Connect your calendar to join meetings", tint: SparkVTheme.warning)
            return
        }
        guard let meeting = nextJoinableMeeting, let link = meeting.link else {
            postNotice(systemImage: "video.slash", text: "No meeting with a call link today", tint: SparkVTheme.textSecondary)
            return
        }
        join(meeting)
        postNotice(
            systemImage: "arrow.up.right.video.fill",
            text: "Joining \(meeting.title) on \(link.provider.shortName)",
            tint: SparkVTheme.red
        )
    }

    /// Title for the menu item, e.g. "Join Standup (Zoom)".
    var joinNextMenuTitle: String {
        guard let meeting = nextJoinableMeeting, let link = meeting.link else { return "Join Next Meeting" }
        let title = meeting.title.count > 32 ? String(meeting.title.prefix(31)) + "…" : meeting.title
        return "Join \(title) (\(link.provider.shortName))"
    }

    /// The next three rows for the Today tab.
    var upcoming: [CalendarMeeting] { upcoming(limit: 3) }

    /// Today's meetings that haven't ended, at most `limit`.
    func upcoming(limit: Int) -> [CalendarMeeting] {
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        return Array(meetings.filter { $0.end > now && $0.start < endOfDay }.prefix(max(0, limit)))
    }

    /// Today's remaining meetings (all of them), for counts.
    var remainingToday: Int { upcoming(limit: .max).count }

    func timing(for meeting: CalendarMeeting) -> MeetingTiming {
        Self.timing(for: meeting, now: now)
    }

    /// True while `meeting` is in its heads-up window (shown in the band).
    func isInHeadsUp(_ meeting: CalendarMeeting) -> Bool {
        Self.isInHeadsUp(meeting, now: now, lead: leadTime)
    }

    // MARK: Hotkey

    private func updateHotkey() {
        let wanted = isStarted && isEnabled && joinShortcutEnabled
        if wanted {
            if hotkey.shortcut != Self.joinShortcut {
                isShortcutRegistered = hotkey.register(Self.joinShortcut)
                AppLog.log("Meetings: Join shortcut \(Self.joinShortcut.displayString) \(isShortcutRegistered ? "registered" : "unavailable")")
            }
        } else if hotkey.isRegistered {
            hotkey.unregister()
            isShortcutRegistered = false
        }
    }

    // MARK: Access watch

    /// Calendar access is often granted outside this controller (the
    /// onboarding Permissions step, or System Settings), and can be revoked
    /// there. PermissionCenter re-reads it when SparkV or System Settings
    /// activates, so the heads-up starts on its own instead of waiting for
    /// the Today tab to be opened.
    private func updateAccessWatch() {
        let wanted = isStarted && isEnabled
        guard wanted else {
            accessWatch = nil
            return
        }
        guard accessWatch == nil else { return }
        accessWatch = PermissionCenter.shared.onChange(of: .calendars) { [weak self] _ in
            guard let self else { return }
            // Not while the system prompt from "Connect Calendar" is up.
            if !self.isRequestingAccess { self.recheckAuthorization() }
        }
    }

    // MARK: Monitoring

    private func beginMonitoringIfAuthorized() {
        access = Self.currentAccess(refused: requestWasRefused)
        guard access == .granted, isEnabled else { return }
        guard !isMonitoring else {
            scheduleRefresh()
            return
        }
        isMonitoring = true
        AppLog.log("Meetings: monitoring calendar")

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.calendarRevision &+= 1
                self?.scheduleRefresh()
            }
        })
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        observers.append(wake)

        restartTicking()
        scheduleRefresh()
    }

    /// Refreshes just after every minute boundary, and also right at each
    /// heads-up, "Now" and end moment, so the band lines up with the clock
    /// even for meetings that don't start on a whole minute.
    private func restartTicking() {
        tickTask?.cancel()
        tickTask = nil
        guard isMonitoring else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextTickDelay() else { return }
                try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// The minute tick only moves the band's countdown on, from the cached
    /// meetings: EventKit is fetched again on EKEventStoreChanged, a day
    /// change, wake and calendar-settings changes, plus a safety refetch
    /// when the last one is over 15 minutes old. Displays asleep: nothing
    /// to show, the next tick after they wake catches up.
    private func tick() {
        guard isMonitoring, !SparkVEnergy.shared.screensAsleep else { return }
        if let lastFetchAt, Date().timeIntervalSince(lastFetchAt) < 15 * 60 {
            apply(meetings, now: Date())
        } else {
            scheduleRefresh()
        }
    }

    private func nextTickDelay() -> TimeInterval {
        let date = Date()
        let interval = date.timeIntervalSinceReferenceDate
        let untilNextMinute = 60 - interval.truncatingRemainder(dividingBy: 60) + 0.5
        let transition = Self.nextTransition(in: meetings, after: date, lead: leadTime)
            .map { $0.timeIntervalSince(date) + 0.25 } ?? .infinity
        return max(0.5, min(untilNextMinute, transition))
    }

    private func endMonitoring(clear: Bool) {
        if isMonitoring { AppLog.log("Meetings: stopped monitoring") }
        isMonitoring = false
        lastFetchAt = nil
        tickTask?.cancel()
        tickTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if clear {
            meetings = []
            allDayEvents = []
        }
        dismissActivity()
    }

    private func scheduleRefresh() {
        guard isMonitoring else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let source = self.source
        let lookahead = TimeInterval(Self.leadChoices.max() ?? 15) * 60 + 60
        let hidden = preferences.hiddenCalendarIDs
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let snapshot = await source.today(now: Date(), lookahead: lookahead, hidden: hidden)
            guard let self, !Task.isCancelled, generation == self.refreshGeneration, self.isMonitoring else { return }
            self.lastFetchAt = Date()
            if snapshot.allDay != self.allDayEvents { self.allDayEvents = snapshot.allDay }
            if snapshot.calendars != self.calendars { self.calendars = snapshot.calendars }
            self.apply(snapshot.meetings, now: Date())
        }
    }

    /// Internal (not private) so tests can feed synthetic meetings.
    func apply(_ fetched: [CalendarMeeting], now: Date) {
        self.now = now
        if fetched != meetings { meetings = fetched }
        if !joinedIDs.isEmpty { joinedIDs.formIntersection(fetched.map(\.id)) }
        updateActivity(now: now)
    }

    /// Tests and renders: all-day events and the calendar list.
    func applyExtras(allDay: [CalendarMeeting], calendars: [CalendarInfo]) {
        allDayEvents = allDay
        self.calendars = calendars
    }

    // MARK: Agenda and opening events

    /// Events between the dates from the shown calendars (all-day included),
    /// for the Planner's day, week and month views. Empty without access.
    func agenda(from start: Date, to end: Date) async -> [CalendarMeeting] {
        guard access == .granted, isEnabled else { return [] }
        return await source.events(from: start, to: end, hidden: preferences.hiddenCalendarIDs)
    }

    /// Opens the event where Settings say (Calendar by default). Calendar
    /// gets the event itself through its ical:// link when it can find it;
    /// the web calendars open at the event's day.
    func open(_ meeting: CalendarMeeting, in target: CalendarOpenTarget? = nil) {
        let choice = target ?? preferences.openTarget
        // No title in the log: it is a plain file in ~/Library/Logs.
        AppLog.log("Meetings: opening an event in \(choice.rawValue)")
        switch choice {
        case .calendarApp:
            if let url = CalendarLinks.calendarApp(eventIdentifier: meeting.eventID), NSWorkspace.shared.open(url) { return }
            Self.openCalendarApp()
        case .googleWeb:
            NSWorkspace.shared.open(CalendarLinks.googleDay(meeting.start, calendar: .current))
        case .outlookWeb:
            NSWorkspace.shared.open(CalendarLinks.outlookDay(meeting.start, calendar: .current))
        case .defaultApp:
            if Self.defaultCalendarAppIsCalendar {
                if let url = CalendarLinks.calendarApp(eventIdentifier: meeting.eventID), NSWorkspace.shared.open(url) { return }
            }
            Self.openDefaultCalendarApp()
        }
    }

    /// Opens the calendar at a day (the web calendars), or Calendar itself.
    func openDay(_ date: Date) {
        switch preferences.openTarget {
        case .calendarApp: Self.openCalendarApp()
        case .googleWeb: NSWorkspace.shared.open(CalendarLinks.googleDay(date, calendar: .current))
        case .outlookWeb: NSWorkspace.shared.open(CalendarLinks.outlookDay(date, calendar: .current))
        case .defaultApp: Self.openDefaultCalendarApp()
        }
    }

    static func openCalendarApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The app macOS opens calendar files (.ics) with, else the one for
    /// webcal:// links. Read when asked (a menu or a click), never polled.
    static var defaultCalendarAppURL: URL? {
        if let ics = UTType("com.apple.ical.ics"), let url = NSWorkspace.shared.urlForApplication(toOpen: ics) { return url }
        if let probe = URL(string: "webcal://localhost/calendar.ics") { return NSWorkspace.shared.urlForApplication(toOpen: probe) }
        return nil
    }

    /// "Fantastical", for the "Open Events In" choices. Menus ask on every
    /// update, so the answer is kept for half a minute.
    static var defaultCalendarAppName: String? {
        if let cached = defaultAppNameCache, Date().timeIntervalSince(cached.date) < 30 { return cached.name }
        var name: String?
        if let url = defaultCalendarAppURL {
            var display = FileManager.default.displayName(atPath: url.path)
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            name = display
        }
        defaultAppNameCache = (Date(), name)
        return name
    }

    private static var defaultAppNameCache: (date: Date, name: String?)?

    /// "Default calendar app (Fantastical)".
    static func title(for target: CalendarOpenTarget) -> String {
        guard target == .defaultApp, let name = defaultCalendarAppName else { return target.title }
        return "\(target.title) (\(name))"
    }

    /// Choices worth offering: the default-app one only when it isn't Calendar.
    static var openTargets: [CalendarOpenTarget] {
        let name = defaultCalendarAppName
        let chosen = CalendarPreferences.shared.openTarget
        return CalendarOpenTarget.allCases.filter { $0 != .defaultApp || $0 == chosen || (name != nil && name != "Calendar") }
    }

    private static var defaultCalendarAppIsCalendar: Bool {
        guard let url = defaultCalendarAppURL else { return true }
        return Bundle(url: url)?.bundleIdentifier == "com.apple.iCal"
    }

    /// Opens the default calendar app; Calendar when there is none.
    static func openDefaultCalendarApp() {
        guard let app = defaultCalendarAppURL else { return openCalendarApp() }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Live activity

    private func updateActivity(now: Date) {
        guard isEnabled, let meeting = Self.activityMeeting(in: meetings, now: now, lead: leadTime) else {
            dismissActivity()
            return
        }
        let id = "meeting.\(meeting.eventID)"
        let timing = Self.timing(for: meeting, now: now)
        let status = Self.statusText(for: timing)
        let joined = joinedIDs.contains(meeting.id)
        let signature = "\(meeting.title)|\(status)|\(meeting.link?.url.absoluteString ?? "-")|\(joined)"
        if let posted = postedActivity, posted.id == id, posted.signature == signature { return }
        if let posted = postedActivity, posted.id != id { activities.dismiss(id: posted.id) }
        let wasAnnouncedNow = postedActivity.map { $0.id == id && $0.signature.contains("|Now|") } ?? false
        postedActivity = (id, signature)

        let title = meeting.title
        let calendarColor = meeting.calendarColor.color
        let provider = meeting.link?.provider
        let icon = meeting.link.flatMap(MeetingAppIcon.icon(for:))
        let startText = Self.timeFormatter.string(from: meeting.start)
        let isNow = timing.isJoinMoment
        let compactStatus = isNow ? "Now" : status.replacingOccurrences(of: "in ", with: "")
        // Dynamic Island style: the band peeks when the heads-up starts and
        // again at "Now" (10 s), then the countdown or a green "Now" rests in
        // the wings beside the camera.
        let activity = LiveActivity(
            id: id,
            kind: .meeting,
            priority: Self.activityPriority,
            duration: nil,
            opensTab: .today,
            symbol: provider == nil ? "calendar" : "video.fill",
            tint: isNow ? SparkVTheme.red : nil,
            compactText: compactStatus,
            peekKey: isNow ? "now" : "soon"
        ) {
            MeetingPeekBand(
                title: title,
                status: status,
                isNow: isNow,
                calendarColor: calendarColor,
                provider: provider,
                appIcon: icon,
                startText: startText
            )
        }
        .compact {
            MeetingProviderBadge(provider: provider, appIcon: icon, calendarColor: calendarColor, size: 16)
        } trailing: {
            Text(compactStatus)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isNow ? SparkVTheme.red : SparkVTheme.text)
                .lineLimit(1)
                .fixedSize()
        }
        .minimal {
            MeetingProviderBadge(provider: provider, appIcon: icon, calendarColor: calendarColor, size: 14)
        }
        let minutesLeft = isNow ? 0 : max(1, Int((meeting.start.timeIntervalSinceNow / 60).rounded(.up)))
        activities.post(activity.announcing(ActivityAnnouncementText.meeting(title: title, minutes: minutesLeft), as: .meeting))
        // "Now" announces itself for a little longer than the 4 s peek, then
        // rests in the wings as a green "Now" (hover opens Today with Join),
        // so an unjoined meeting never keeps the band over the page.
        if isNow, !joined, !wasAnnouncedNow { activities.peek(id: id, for: 10) }
    }

    private func dismissActivity() {
        guard let posted = postedActivity else { return }
        activities.dismiss(id: posted.id)
        postedActivity = nil
    }

    private func postNotice(systemImage: String, text: String, tint: Color) {
        activities.post(LiveActivity(
            id: Self.noticeID,
            kind: .meeting,
            priority: Self.noticePriority,
            duration: 2.5
        ) {
            MeetingNoticeBand(systemImage: systemImage, text: text, tint: tint)
        })
    }

    // MARK: Timing (pure)

    nonisolated static func clampLead(_ minutes: Int) -> Int {
        leadChoices.contains(minutes) ? minutes : (leadChoices.min { abs($0 - minutes) < abs($1 - minutes) } ?? defaultLeadMinutes)
    }

    nonisolated static func timing(for meeting: CalendarMeeting, now: Date) -> MeetingTiming {
        guard now < meeting.end else { return .ended }
        let remaining = meeting.start.timeIntervalSince(now)
        if remaining > nowLeadTime {
            return .upcoming(minutes: max(2, Int((remaining / 60).rounded(.up))))
        }
        if remaining > -trailTime { return .now }
        return .inProgress
    }

    nonisolated static func isInHeadsUp(_ meeting: CalendarMeeting, now: Date, lead: TimeInterval) -> Bool {
        now >= meeting.start.addingTimeInterval(-lead)
            && now < meeting.start.addingTimeInterval(trailTime)
            && now < meeting.end
    }

    /// The meeting whose heads-up window contains `now`; when two overlap,
    /// the one whose start is closest (an upcoming one wins a tie).
    nonisolated static func activityMeeting(in meetings: [CalendarMeeting], now: Date, lead: TimeInterval) -> CalendarMeeting? {
        meetings
            .filter { isInHeadsUp($0, now: now, lead: lead) }
            .min { lhs, rhs in
                let l = abs(lhs.start.timeIntervalSince(now)), r = abs(rhs.start.timeIntervalSince(now))
                return l == r ? lhs.start > rhs.start : l < r
            }
    }

    /// What "Join Next Meeting" opens, among meetings with a call link:
    /// one in its "Now" window (closest start), else one starting within 15
    /// minutes, else one still running (latest start), else the next today.
    nonisolated static func meetingToJoin(in meetings: [CalendarMeeting], now: Date) -> CalendarMeeting? {
        let joinable = meetings.filter { $0.link != nil && $0.end > now }
        let nowWindow = joinable.filter { timing(for: $0, now: now) == .now }
        if let pick = nowWindow.min(by: { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }) {
            return pick
        }
        let upcoming = joinable.filter { $0.start > now }.sorted { $0.start < $1.start }
        if let soon = upcoming.first, soon.start.timeIntervalSince(now) <= 15 * 60 { return soon }
        if let running = joinable.filter({ $0.start <= now }).max(by: { $0.start < $1.start }) { return running }
        return upcoming.first
    }

    /// The next moment the band or a row label changes.
    nonisolated static func nextTransition(in meetings: [CalendarMeeting], after now: Date, lead: TimeInterval) -> Date? {
        meetings
            .flatMap { [
                $0.start.addingTimeInterval(-lead),
                $0.start.addingTimeInterval(-nowLeadTime),
                $0.start,
                $0.start.addingTimeInterval(trailTime),
                $0.end,
            ] }
            .filter { $0 > now }
            .min()
    }

    /// "in 4 min" before the start, "Now" from a minute before until it ends.
    nonisolated static func statusText(for timing: MeetingTiming) -> String {
        switch timing {
        case .upcoming(let minutes):
            minutes >= 60 ? "in \(minutes / 60) h \(minutes % 60) min" : "in \(minutes) min"
        case .now, .inProgress: "Now"
        case .ended: "Ended"
        }
    }

    nonisolated static func statusText(for meeting: CalendarMeeting, now: Date) -> String {
        statusText(for: timing(for: meeting, now: now))
    }

    /// The URL to open: the app's own scheme when an app handles it,
    /// otherwise the web link.
    nonisolated static func openTarget(for link: MeetingLink, canOpen: (URL) -> Bool) -> URL {
        if let native = link.nativeURL, canOpen(native) { return native }
        return link.url
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()

    /// Read through PermissionCenter; never prompts.
    private static func currentAccess(refused: Bool) -> Access {
        let center = PermissionCenter.shared
        if center.isGranted(.calendars) { return .granted }
        switch center.status(.calendars) {
        // A cached .granted here is a grant revoked a moment ago.
        case .denied, .restricted, .granted: return .denied
        default: return refused ? .denied : .notDetermined
        }
    }

    nonisolated private static func canOpen(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }
}

// MARK: - App icons

/// The installed app's icon for a meeting link (Zoom, Teams, Slack, FaceTime,
/// Webex), looked up once per provider.
@MainActor
enum MeetingAppIcon {
    private static var cache: [MeetingLink.Provider: NSImage?] = [:]

    static func icon(for link: MeetingLink) -> NSImage? {
        if let cached = cache[link.provider] { return cached }
        let workspace = NSWorkspace.shared
        var found: NSImage?
        for bundleID in link.provider.appBundleIDs {
            if let app = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                found = workspace.icon(forFile: app.path)
                break
            }
        }
        cache[link.provider] = found
        return found
    }
}

// MARK: - Band

/// The provider's app icon (or a brand-colored glyph), drawn 18 pt.
struct MeetingProviderBadge: View {
    let provider: MeetingLink.Provider?
    let appIcon: NSImage?
    let calendarColor: Color
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let provider {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(provider.brand.color)
                    .overlay(
                        Image(systemName: provider.symbolName)
                            .font(.system(size: size * 0.5, weight: .bold))
                            .foregroundStyle(Color.white)
                    )
                    .padding(size * 0.06)
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(calendarColor)
            }
        }
        .frame(width: size, height: size)
    }
}

/// "Standup · in 4 min   [Join]": the provider's icon, the title, a
/// countdown (green "Now" from a minute before until five minutes after the
/// start) and a Join button. Hovering the band opens the Today tab, whose
/// row for this meeting has the same Join button.
struct MeetingPeekBand: View {
    let title: String
    let status: String
    let isNow: Bool
    let calendarColor: Color
    let provider: MeetingLink.Provider?
    let appIcon: NSImage?
    let startText: String

    var body: some View {
        HStack(spacing: 8) {
            MeetingProviderBadge(provider: provider, appIcon: appIcon, calendarColor: calendarColor)

            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                HStack(spacing: 4) {
                    if isNow {
                        Circle().fill(SparkVTheme.red).frame(width: 6, height: 6)
                    }
                    Text(status)
                        .foregroundStyle(isNow ? SparkVTheme.red : SparkVTheme.textSecondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)

            if provider != nil {
                MeetingJoinPill(isNow: isNow)
            } else {
                Text(startText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The band's Join capsule: green at the join moment, blue before.
struct MeetingJoinPill: View {
    let isNow: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "video.fill").font(.system(size: 8, weight: .bold))
            Text("Join").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(isNow ? Color.white : SparkVTheme.text)
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background(Capsule().fill(isNow ? SparkVTheme.red : SparkVTheme.surfaceHover))
        .overlay(Capsule().strokeBorder(isNow ? Color.clear : SparkVTheme.stroke))
        .fixedSize()
    }
}

/// One-line notice ("Joining Standup on Zoom", "No meeting with a call link").
struct MeetingNoticeBand: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
