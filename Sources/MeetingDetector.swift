import AppKit
import CoreAudio
import Darwin
import SwiftUI

// Detects a live call (Zoom, Google Meet, Microsoft Teams, Slack huddles,
// Webex, FaceTime and other call apps) without joining it and without any
// new permission, the way Granola and Heizen do it: a known call app (or a
// browser on a meeting page) is using the microphone.
//
// Signals, cheapest first:
// - CoreAudio's per-process objects (macOS 14.2+): which processes have
//   input (microphone) or output running. Reading them captures nothing and
//   needs no permission. SparkV's own process is ignored.
// - The default input device's "running somewhere" flag, when per-process
//   information isn't available.
// - Browser tab URLs (meet.google.com/abc-defg-hij, app.zoom.us/wc/…,
//   teams.microsoft.com, *.webex.com/meet/…), read with AppleScript only
//   from browsers SparkV already may automate (PermissionCenter, never asks)
//   and only while that browser is using the microphone.
// - Today's calendar (MeetingsController): a call with a link that is on
//   now names the call and links the notes to the event.
//
// A call starts after the evidence holds for `startDelay` (two hot polls)
// and ends after it is gone for `endGrace`. While a call is on, the app's
// audio output or the meeting tab still being open keeps it alive, so muting
// (some apps release the microphone) does not end it.
//
// Everything above "LIVE" below is pure Foundation/CoreAudio-free logic plus
// the detector itself, exercised with fakes outside the app.

// MARK: - Catalog

/// A desktop app whose microphone use means a call.
struct MeetingCallApp: Sendable, Equatable {
    let id: String
    let name: String
    let provider: MeetingLink.Provider?
    /// The app's bundle IDs; helpers (`<id>.helper…`) match too.
    let bundleIDs: [String]
    /// System daemons that run the audio for this app (FaceTime's
    /// avconferenced). They count only while one of `bundleIDs` runs.
    var audioDaemons: [String] = []
    /// Also records voice messages or clips: counts as a call only while it
    /// plays audio too (the other side talking), not for a one-way recording.
    var needsTwoWayAudio = false
}

/// A browser whose microphone use may be a web meeting.
struct MeetingCallBrowser: Sendable, Equatable {
    enum Scripting: Sendable, Equatable { case safari, chromium }

    let name: String
    let bundleID: String
    /// nil: its tabs can't be read (Firefox); the calendar still helps.
    let scripting: Scripting?
    /// Out-of-process audio services that capture for this browser.
    var audioServices: [String] = []
}

enum MeetingCallCatalog {
    /// Chrome's installed Google Meet app (PWA). Its audio runs in Chrome's
    /// own helper processes.
    static let meetPWABundleID = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"

    static let apps: [MeetingCallApp] = [
        MeetingCallApp(id: "zoom", name: "Zoom", provider: .zoom, bundleIDs: ["us.zoom.xos"]),
        MeetingCallApp(id: "teams", name: "Microsoft Teams", provider: .teams, bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        MeetingCallApp(id: "webex", name: "Webex", provider: .webex, bundleIDs: ["Cisco-Systems.Spark", "com.webex.meetingmanager", "com.cisco.webexmeetingsapp"]),
        MeetingCallApp(id: "slack", name: "Slack huddle", provider: .slack, bundleIDs: ["com.tinyspeck.slackmacgap"], needsTwoWayAudio: true),
        MeetingCallApp(id: "facetime", name: "FaceTime", provider: .faceTime, bundleIDs: ["com.apple.FaceTime"], audioDaemons: ["avconferenced", "com.apple.avconferenced"]),
        MeetingCallApp(id: "around", name: "Around", provider: .around, bundleIDs: ["co.teamport.around"]),
        MeetingCallApp(id: "discord", name: "Discord", provider: nil, bundleIDs: ["com.hnc.Discord"], needsTwoWayAudio: true),
        MeetingCallApp(id: "whatsapp", name: "WhatsApp", provider: nil, bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"], needsTwoWayAudio: true),
        MeetingCallApp(id: "skype", name: "Skype", provider: nil, bundleIDs: ["com.skype.skype"]),
        MeetingCallApp(id: "tuple", name: "Tuple", provider: nil, bundleIDs: ["app.tuple.app"]),
        MeetingCallApp(id: "chime", name: "Amazon Chime", provider: nil, bundleIDs: ["com.amazon.Amazon-Chime"]),
        MeetingCallApp(id: "goto", name: "GoTo Meeting", provider: nil, bundleIDs: ["com.logmein.GoToMeeting", "com.logmein.goto"]),
        MeetingCallApp(id: "signal", name: "Signal", provider: nil, bundleIDs: ["org.whispersystems.signal-desktop"], needsTwoWayAudio: true),
        MeetingCallApp(id: "telegram", name: "Telegram", provider: nil, bundleIDs: ["ru.keepcoder.Telegram"], needsTwoWayAudio: true),
    ]

    static let browsers: [MeetingCallBrowser] = [
        MeetingCallBrowser(name: "Safari", bundleID: "com.apple.Safari", scripting: .safari, audioServices: ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]),
        MeetingCallBrowser(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview", scripting: .safari),
        MeetingCallBrowser(name: "Google Chrome", bundleID: "com.google.Chrome", scripting: .chromium),
        MeetingCallBrowser(name: "Chrome Canary", bundleID: "com.google.Chrome.canary", scripting: .chromium),
        MeetingCallBrowser(name: "Arc", bundleID: "company.thebrowser.Browser", scripting: .chromium),
        MeetingCallBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", scripting: .chromium),
        MeetingCallBrowser(name: "Brave", bundleID: "com.brave.Browser", scripting: .chromium),
        MeetingCallBrowser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", scripting: .chromium),
        MeetingCallBrowser(name: "Dia", bundleID: "company.thebrowser.dia", scripting: nil),
        MeetingCallBrowser(name: "Opera", bundleID: "com.operasoftware.Opera", scripting: nil),
        MeetingCallBrowser(name: "Firefox", bundleID: "org.mozilla.firefox", scripting: nil),
    ]

    /// `bundleID` is one of `candidates` or a helper of one ("<id>.helper").
    static func matches(_ bundleID: String?, _ candidates: [String]) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return candidates.contains { candidate in
            let c = candidate.lowercased()
            return id == c || id.hasPrefix(c + ".")
        }
    }

    static func isRunning(_ ids: [String], in running: Set<String>) -> Bool {
        running.contains { matches($0, ids) }
    }

    /// The call app a process with audio belongs to.
    static func app(for process: MeetingAudioProcess, running: Set<String>) -> MeetingCallApp? {
        for app in apps {
            if process.matches(app.bundleIDs) { return app }
            if !app.audioDaemons.isEmpty, process.matches(app.audioDaemons) || app.audioDaemons.contains(process.executable),
               isRunning(app.bundleIDs, in: running) {
                return app
            }
        }
        return nil
    }

    /// The browser a process with audio belongs to (its helpers, or WebKit's
    /// audio service while Safari runs). The Meet PWA counts as Chrome.
    static func browser(for process: MeetingAudioProcess, running: Set<String>) -> MeetingCallBrowser? {
        // Most specific first: "com.google.Chrome.canary" before "com.google.Chrome".
        let ordered = browsers.sorted { $0.bundleID.count > $1.bundleID.count }
        if let direct = ordered.first(where: { process.matches([$0.bundleID]) }) { return direct }
        for browser in browsers where !browser.audioServices.isEmpty {
            if process.matches(browser.audioServices) || browser.audioServices.contains(process.executable),
               running.contains(browser.bundleID) {
                return browser
            }
        }
        return nil
    }

    static func browser(bundleID: String) -> MeetingCallBrowser? {
        browsers.first { $0.bundleID == bundleID }
    }

    static func app(id: String) -> MeetingCallApp? {
        apps.first { $0.id == id }
    }
}

// MARK: - Signals

/// A process that has audio running, from CoreAudio's process objects.
struct MeetingAudioProcess: Sendable, Equatable {
    var pid: Int32
    /// CoreAudio's bundle ID for the process (a helper's own ID).
    var bundleID: String?
    /// The outermost .app the executable lives in ("com.google.Chrome" for
    /// "Google Chrome Helper"), when there is one.
    var ownerBundleID: String?
    /// Executable name ("avconferenced").
    var executable: String
    var isRunningInput: Bool
    var isRunningOutput: Bool

    init(pid: Int32, bundleID: String?, ownerBundleID: String? = nil, executable: String = "",
         isRunningInput: Bool, isRunningOutput: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.ownerBundleID = ownerBundleID
        self.executable = executable
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }

    func matches(_ ids: [String]) -> Bool {
        MeetingCallCatalog.matches(bundleID, ids) || MeetingCallCatalog.matches(ownerBundleID, ids)
    }
}

struct MeetingRunningApps: Sendable, Equatable {
    var bundleIDs: Set<String>
    var frontmost: String?

    init(bundleIDs: Set<String> = [], frontmost: String? = nil) {
        self.bundleIDs = bundleIDs
        self.frontmost = frontmost
    }
}

/// An open browser tab on a meeting page.
struct MeetingBrowserTab: Sendable, Equatable {
    let browserBundleID: String
    let url: URL
    let title: String
    let provider: MeetingLink.Provider
    /// True for an actual meeting page (a Meet code, Zoom's web client), false
    /// for an app shell that may or may not be in a call (teams.microsoft.com).
    let isSpecific: Bool

    /// Host and path, lowercased: the same meeting in two refreshes.
    var key: String { MeetingTabClassifier.key(for: url) }
}

struct MeetingCallSignals: Sendable {
    /// nil when per-process audio information isn't available.
    var processes: [MeetingAudioProcess]?
    /// The default input device runs somewhere (used without `processes`).
    var defaultInputRunning: Bool = false
    /// SparkV itself captures the microphone (recording, dictation).
    var ownMicActive: Bool = false
    var ownPID: Int32
    var ownBundleID: String?
    var apps: MeetingRunningApps = MeetingRunningApps()
    var tabs: [MeetingBrowserTab] = []
    var calendar: [CalendarMeeting] = []
    var now: Date
}

// MARK: - Detected call

struct DetectedCall: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A call app (`MeetingCallApp.id`).
        case app(id: String)
        /// A browser, on a meeting tab (`tabKey`) or during a calendar meeting.
        case browser(bundleID: String, tabKey: String?)
    }

    /// Stable while the same call goes on.
    let key: String
    /// "Zoom", "Google Meet", "Google Chrome" (a browser during a calendar
    /// meeting whose service is unknown).
    let appName: String
    let provider: MeetingLink.Provider?
    let source: Source
    /// The calendar event's title, else the meeting tab's, else "Zoom call".
    var title: String
    /// Set when the call matches one of today's calendar events.
    var calendarEventID: String?
    /// True when `title` is the generic "<App> call".
    var hasGenericTitle: Bool

    var id: String { key }

    /// "Google Meet", "Zoom", "Slack huddle": what the prompt calls it.
    var serviceName: String { provider?.displayName ?? appName }

    /// The bundle ID whose icon represents the call.
    var iconBundleID: String? {
        switch source {
        case .app(let id): MeetingCallCatalog.app(id: id)?.bundleIDs.first
        case .browser(let bundleID, _): bundleID
        }
    }
}

enum MeetingCallEvent: Equatable, Sendable {
    case started(DetectedCall)
    /// Same call, better title (the calendar event or tab title showed up).
    case updated(DetectedCall)
    case ended(DetectedCall)
}

// MARK: - Tabs

enum MeetingTabClassifier {
    private static let meetCode = try? NSRegularExpression(pattern: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#)
    private static let teamsHosts: Set<String> = [
        "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft", "gov.teams.microsoft.us", "teams.microsoft.us",
    ]
    private static let wherebyReserved: Set<String> = [
        "information", "pricing", "blog", "user", "org", "login", "signup", "download", "support", "",
    ]

    /// Substrings the tab script filters on, so only meeting URLs ever leave
    /// the browser.
    static let scriptFilters = [
        "meet.google.com/", "zoom.us/wc", "zoom.com/wc", "zoomgov.com/wc", "teams.microsoft.", "teams.live.com",
        "teams.cloud.microsoft", "webex.com/", "app.slack.com/huddle", "whereby.com/", "facetime.apple.com/join",
        "around.co/",
    ]

    static func isMeetCode(_ s: String) -> Bool {
        guard let meetCode else { return false }
        return meetCode.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The service and whether the page is a meeting itself (not just the
    /// app shell). nil for anything that isn't a meeting page.
    static func classify(_ url: URL) -> (provider: MeetingLink.Provider, isSpecific: Bool)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let parts = url.path.lowercased().split(separator: "/").map(String.init)
        let query = (url.query ?? "").lowercased()
        let fragment = (url.fragment ?? "").lowercased()

        if host == "meet.google.com" {
            guard let first = parts.first else { return nil }
            if isMeetCode(first) { return (.googleMeet, true) }
            if first == "lookup", parts.count >= 2 { return (.googleMeet, true) }
            return nil
        }
        if hostIs(host, anyOf: ["zoom.us", "zoom.com", "zoomgov.com", "zoom.com.cn", "zoom.de"]) {
            // The web client: app.zoom.us/wc/123/join, zoom.us/wc/join/123.
            if parts.first == "wc", parts.count >= 2 { return (.zoom, true) }
            return nil
        }
        if teamsHosts.contains(host) {
            let specific = parts.contains("meetup-join") || parts.first == "meet"
                || query.contains("meetingjoin") || fragment.contains("pre-join") || fragment.contains("meetup-join")
                || parts.contains("light-meetings")
            return (.teams, specific)
        }
        if host.hasSuffix(".webex.com"), !host.hasPrefix("www."), !host.hasPrefix("help.") {
            let path = url.path.lowercased()
            if path.contains("/meet/") || path.contains("/wbxmjs/") || path.contains("/webappng/") || path.contains("j.php")
                || path.hasPrefix("/meet") {
                return (.webex, true)
            }
            return nil
        }
        if host == "app.slack.com", parts.contains("huddle") { return (.slack, true) }
        if host == "whereby.com" || (host.hasSuffix(".whereby.com") && !host.hasPrefix("www.")) {
            guard let first = parts.first, !wherebyReserved.contains(first) else { return nil }
            return (.whereby, true)
        }
        if host == "facetime.apple.com", parts.first == "join" { return (.faceTime, true) }
        if host == "around.co" || host == "meet.around.co" {
            guard let first = parts.first, !first.isEmpty else { return nil }
            return (.around, true)
        }
        return nil
    }

    static func tab(url: URL, title: String, browserBundleID: String) -> MeetingBrowserTab? {
        guard let kind = classify(url) else { return nil }
        return MeetingBrowserTab(browserBundleID: browserBundleID, url: url, title: title,
                                 provider: kind.provider, isSpecific: kind.isSpecific)
    }

    static func key(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        var path = url.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    private static func hostIs(_ host: String, anyOf domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// AppleScript that lists the meeting tabs of one browser as
    /// "URL<TAB>title" lines. Only URLs containing a `scriptFilters` entry
    /// are returned; Chromium incognito windows are skipped.
    static func tabScript(bundleID: String, scripting: MeetingCallBrowser.Scripting) -> String {
        let condition = scriptFilters.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        switch scripting {
        case .safari:
            return """
            set sep to character id 9
            set out to ""
            with timeout of 4 seconds
                tell application id "\(bundleID)"
                    repeat with w in windows
                        try
                            repeat with t in tabs of w
                                try
                                    set u to (URL of t) as text
                                    if \(condition) then
                                        set out to out & u & sep & ((name of t) as text) & linefeed
                                    end if
                                end try
                            end repeat
                        end try
                    end repeat
                end tell
            end timeout
            return out
            """
        case .chromium:
            return """
            set sep to character id 9
            set out to ""
            with timeout of 4 seconds
                tell application id "\(bundleID)"
                    repeat with w in windows
                        set skipWindow to false
                        try
                            if ((mode of w) as text) is "incognito" then set skipWindow to true
                        end try
                        if not skipWindow then
                            repeat with t in tabs of w
                                try
                                    set u to (URL of t) as text
                                    if \(condition) then
                                        set out to out & u & sep & ((title of t) as text) & linefeed
                                    end if
                                end try
                            end repeat
                        end if
                    end repeat
                end tell
            end timeout
            return out
            """
        }
    }

    /// Parses `tabScript` output; anything that isn't a meeting page is dropped.
    static func parseTabs(_ output: String, browserBundleID: String) -> [MeetingBrowserTab] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawURL = fields.first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
                  !rawURL.isEmpty, rawURL != "missing value", let url = URL(string: rawURL) else { return nil }
            var title = fields.count > 1 ? String(fields[1]).trimmingCharacters(in: .whitespaces) : ""
            if title == "missing value" { title = "" }
            return tab(url: url, title: title, browserBundleID: browserBundleID)
        }
    }

    /// A tab title worth naming the notes after, or nil for a generic one
    /// ("Meet - abc-defg-hij", "Zoom Meeting", "Microsoft Teams").
    static func meaningfulTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unread badges: "(2) Meet - Standup".
        if let range = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { title.removeSubrange(range) }
        let prefixes = ["Meet - ", "Meet – ", "Meet — ", "Google Meet - ", "Google Meet – ", "Zoom - ", "Webex - "]
        for prefix in prefixes where title.hasPrefix(prefix) { title.removeFirst(prefix.count) }
        let suffixes = [" | Microsoft Teams", " - Microsoft Teams", " | Webex", " - Webex", " - Zoom", " | Zoom", " | Slack",
                        " - Slack", " - Google Meet", " | Whereby", " - Whereby"]
        for suffix in suffixes where title.hasSuffix(suffix) { title.removeLast(suffix.count) }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = [
            "", "meet", "google meet", "zoom", "zoom meeting", "zoom webinar", "microsoft teams", "teams", "webex",
            "webex meetings", "slack", "huddle", "whereby", "facetime", "meeting", "meeting in progress", "calls",
            "chat", "activity", "calendar", "new tab", "untitled",
        ]
        if generic.contains(title.lowercased()) || isMeetCode(title.lowercased()) { return nil }
        return title.count > 80 ? String(title.prefix(79)) + "…" : title
    }
}

// MARK: - Evaluation (pure)

enum MeetingCallEvaluator {
    /// A call joined up to this long before the event starts is that event
    /// (Granola uses the same 15-minute window).
    static let calendarEarlyJoin: TimeInterval = 15 * 60

    static func isOwn(_ process: MeetingAudioProcess, _ signals: MeetingCallSignals) -> Bool {
        if process.pid == signals.ownPID { return true }
        guard let own = signals.ownBundleID?.lowercased(), !own.isEmpty else { return false }
        return process.bundleID?.lowercased() == own || process.ownerBundleID?.lowercased() == own
    }

    /// Calls the signals show right now, best first. Starting a call needs
    /// the microphone; `isSustained` decides whether a known call goes on.
    static func observe(_ signals: MeetingCallSignals) -> [DetectedCall] {
        let running = signals.apps.bundleIDs
        var found: [(call: DetectedCall, rank: Int)] = []

        if let processes = signals.processes {
            let inputs = processes.filter { $0.isRunningInput && !isOwn($0, signals) }
            var seenKeys: Set<String> = []
            func add(_ call: DetectedCall, rank: Int) {
                guard seenKeys.insert(call.key).inserted else { return }
                found.append((call, rank))
            }
            for process in inputs {
                if let app = MeetingCallCatalog.app(for: process, running: running) {
                    if app.needsTwoWayAudio {
                        let plays = processes.contains {
                            $0.isRunningOutput && !isOwn($0, signals) && MeetingCallCatalog.app(for: $0, running: running) == app
                        }
                        guard plays else { continue }
                    }
                    add(appCall(app, signals: signals), rank: 0)
                } else if let browser = MeetingCallCatalog.browser(for: process, running: running) {
                    if let call = browserCall(browser, signals: signals) { add(call.call, rank: call.rank) }
                }
            }
        } else if signals.defaultInputRunning, !signals.ownMicActive {
            // No per-process view: anything else using the mic, plus a
            // meeting tab, a calendar meeting on now, or a call app in front.
            let tabs = sortedTabs(signals.tabs)
            if let tab = tabs.first {
                found.append((tabCall(tab, signals: signals), tab.isSpecific ? 1 : 3))
            } else if let event = calendarCallEvent(signals) {
                found.append((calendarCall(event, browserBundleID: nil, signals: signals), 2))
            } else if let front = signals.apps.frontmost,
                      let app = MeetingCallCatalog.apps.first(where: { MeetingCallCatalog.matches(front, $0.bundleIDs) }) {
                found.append((appCall(app, signals: signals), 0))
            }
        }

        // A call that matches a calendar event outranks one that doesn't.
        return found
            .sorted { lhs, rhs in
                let l = lhs.call.calendarEventID == nil ? 1 : 0, r = rhs.call.calendarEventID == nil ? 1 : 0
                return l != r ? l < r : lhs.rank < rhs.rank
            }
            .map(\.call)
    }

    /// Whether `call`, already on, is still going: its app still has audio
    /// in or out (others talking, even while the user is muted), or its
    /// meeting tab is still open.
    static func isSustained(_ call: DetectedCall, _ signals: MeetingCallSignals) -> Bool {
        switch call.source {
        case .app(let id):
            guard let app = MeetingCallCatalog.app(id: id) else { return false }
            if let processes = signals.processes {
                return processes.contains { process in
                    !isOwn(process, signals) && (process.isRunningInput || process.isRunningOutput)
                        && MeetingCallCatalog.app(for: process, running: signals.apps.bundleIDs) == app
                }
            }
            return signals.defaultInputRunning && !signals.ownMicActive
                && MeetingCallCatalog.isRunning(app.bundleIDs, in: signals.apps.bundleIDs)
        case .browser(let bundleID, let tabKey):
            let browser = MeetingCallCatalog.browser(bundleID: bundleID)
            let tabOpen = tabKey.map { key in signals.tabs.contains { $0.key == key } } ?? false
            if let processes = signals.processes {
                guard let browser else { return false }
                // Meet keeps its page (same URL, "You left the meeting") after
                // the call, and Teams' web app stays open all day: an open tab
                // keeps the call on only while the browser still plays or
                // captures audio (WebRTC keeps its output running in a call).
                return processes.contains { process in
                    !isOwn(process, signals) && (process.isRunningInput || (tabOpen && process.isRunningOutput))
                        && MeetingCallCatalog.browser(for: process, running: signals.apps.bundleIDs) == browser
                }
            }
            return tabOpen || (signals.defaultInputRunning && !signals.ownMicActive)
        }
    }

    /// Whether `call`, already on, still has the microphone: the strong form
    /// of `isSustained`. Without it (audio output or an open tab only) a call
    /// stays on for at most `MeetingCallDebouncer.quietHoldLimit`, so an app
    /// that keeps an output stream open all day (Teams) can't keep a call,
    /// and a recording started from it, going forever.
    ///
    /// Without per-process information while SparkV itself records, the mic
    /// flag can't tell who uses it: the call app still running, the meeting
    /// tab still open or the calendar meeting still on counts, so recording
    /// a detected call never ends that call by itself.
    static func isHeard(_ call: DetectedCall, _ signals: MeetingCallSignals) -> Bool {
        let running = signals.apps.bundleIDs
        if let processes = signals.processes {
            return processes.contains { process in
                guard process.isRunningInput, !isOwn(process, signals) else { return false }
                switch call.source {
                case .app(let id):
                    return MeetingCallCatalog.app(for: process, running: running)?.id == id
                case .browser(let bundleID, _):
                    return MeetingCallCatalog.browser(for: process, running: running)?.bundleID == bundleID
                }
            }
        }
        if signals.ownMicActive {
            switch call.source {
            case .app(let id):
                guard let app = MeetingCallCatalog.app(id: id) else { return false }
                return MeetingCallCatalog.isRunning(app.bundleIDs, in: running)
            case .browser(_, let tabKey):
                if let tabKey { return signals.tabs.contains { $0.key == tabKey } }
                guard let eventID = call.calendarEventID else { return false }
                return signals.calendar.contains { $0.eventID == eventID && signals.now < $0.end }
            }
        }
        guard signals.defaultInputRunning else { return false }
        if case .app(let id) = call.source, let app = MeetingCallCatalog.app(id: id) {
            return MeetingCallCatalog.isRunning(app.bundleIDs, in: running)
        }
        return true
    }

    // MARK: Building calls

    private static func appCall(_ app: MeetingCallApp, signals: MeetingCallSignals) -> DetectedCall {
        let event = matchingEvent(provider: app.provider, tabURL: nil, in: signals.calendar, now: signals.now)
        return DetectedCall(
            key: "app:\(app.id)",
            appName: app.name,
            provider: app.provider,
            source: .app(id: app.id),
            title: event?.title ?? genericTitle(app.provider?.displayName ?? app.name),
            calendarEventID: event?.eventID,
            hasGenericTitle: event == nil
        )
    }

    private static func browserCall(_ browser: MeetingCallBrowser, signals: MeetingCallSignals) -> (call: DetectedCall, rank: Int)? {
        let tabs = sortedTabs(signals.tabs.filter { $0.browserBundleID == browser.bundleID })
        if let tab = tabs.first, tab.isSpecific { return (tabCall(tab, signals: signals), 1) }
        // Chrome's Google Meet app is open and Chrome has the microphone.
        if browser.bundleID == "com.google.Chrome", signals.apps.bundleIDs.contains(MeetingCallCatalog.meetPWABundleID) {
            let event = matchingEvent(provider: .googleMeet, tabURL: nil, in: signals.calendar, now: signals.now)
            return (DetectedCall(
                key: "app:meet-pwa",
                appName: "Google Meet",
                provider: .googleMeet,
                source: .browser(bundleID: browser.bundleID, tabKey: nil),
                title: event?.title ?? genericTitle("Google Meet"),
                calendarEventID: event?.eventID,
                hasGenericTitle: event == nil
            ), 1)
        }
        if let event = calendarCallEvent(signals) {
            return (calendarCall(event, browserBundleID: browser.bundleID, signals: signals), 2)
        }
        // Only an app shell (teams.microsoft.com) is open: still the best guess.
        if let tab = tabs.first { return (tabCall(tab, signals: signals), 3) }
        // A browser using the microphone for anything else is not a call.
        return nil
    }

    private static func tabCall(_ tab: MeetingBrowserTab, signals: MeetingCallSignals) -> DetectedCall {
        let event = matchingEvent(provider: tab.provider, tabURL: tab.url, in: signals.calendar, now: signals.now)
        let tabTitle = tab.isSpecific ? MeetingTabClassifier.meaningfulTitle(tab.title) : nil
        let title = event?.title ?? tabTitle ?? genericTitle(tab.provider.displayName)
        return DetectedCall(
            key: "tab:\(tab.key)",
            appName: tab.provider.displayName,
            provider: tab.provider,
            source: .browser(bundleID: tab.browserBundleID, tabKey: tab.key),
            title: title,
            calendarEventID: event?.eventID,
            hasGenericTitle: event == nil && tabTitle == nil
        )
    }

    private static func calendarCall(_ event: CalendarMeeting, browserBundleID: String?, signals: MeetingCallSignals) -> DetectedCall {
        let provider = event.link?.provider
        let browserName = browserBundleID.flatMap { MeetingCallCatalog.browser(bundleID: $0)?.name }
        return DetectedCall(
            key: "cal:\(event.id)",
            appName: provider?.displayName ?? browserName ?? "Call",
            provider: provider,
            source: .browser(bundleID: browserBundleID ?? "", tabKey: nil),
            title: event.title,
            calendarEventID: event.eventID,
            hasGenericTitle: false
        )
    }

    /// Specific meeting pages first, then app shells; stable otherwise.
    static func sortedTabs(_ tabs: [MeetingBrowserTab]) -> [MeetingBrowserTab] {
        tabs.enumerated()
            .sorted { lhs, rhs in
                lhs.element.isSpecific != rhs.element.isSpecific ? lhs.element.isSpecific : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// "Zoom call", "Google Meet call", "Slack huddle".
    static func genericTitle(_ service: String) -> String {
        service.lowercased().hasSuffix("huddle") ? service : "\(service) call"
    }

    // MARK: Calendar

    /// A calendar meeting with a call link that is on now (or starts within
    /// ten minutes): what a browser using the microphone is most likely in.
    static func calendarCallEvent(_ signals: MeetingCallSignals) -> CalendarMeeting? {
        signals.calendar
            .filter { $0.link != nil && signals.now >= $0.start.addingTimeInterval(-10 * 60) && signals.now < $0.end }
            .min { abs($0.start.timeIntervalSince(signals.now)) < abs($1.start.timeIntervalSince(signals.now)) }
    }

    /// The calendar event a call belongs to: on now or starting within 15
    /// minutes; the same meeting link beats the same service, which beats an
    /// event with no link. An event with another service's link never matches.
    static func matchingEvent(provider: MeetingLink.Provider?, tabURL: URL?, in meetings: [CalendarMeeting], now: Date) -> CalendarMeeting? {
        let tabKey = tabURL.map(MeetingTabClassifier.key(for:))
        let ranked: [(CalendarMeeting, Int)] = meetings.compactMap { meeting in
            guard now >= meeting.start.addingTimeInterval(-calendarEarlyJoin), now < meeting.end else { return nil }
            if let tabKey, let link = meeting.link, MeetingTabClassifier.key(for: link.url) == tabKey { return (meeting, 0) }
            guard let provider else { return (meeting, meeting.link == nil ? 3 : 2) }
            if meeting.link?.provider == provider { return (meeting, 1) }
            if meeting.link == nil { return (meeting, 2) }
            return nil
        }
        return ranked.min { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 < rhs.1
                : abs(lhs.0.start.timeIntervalSince(now)) < abs(rhs.0.start.timeIntervalSince(now))
        }?.0
    }
}

// MARK: - Debounce (pure)

/// Turns per-poll observations into call started / updated / ended events.
struct MeetingCallDebouncer: Sendable {
    /// Evidence must hold this long before a call counts as started.
    var startDelay: TimeInterval = 4
    /// A call ends after its evidence is gone this long (a short glitch,
    /// switching microphones or rejoining doesn't end it).
    var endGrace: TimeInterval = 30
    /// A call kept on only by audio output or an open tab (nobody uses the
    /// microphone) ends after this long: muted calls keep the microphone in
    /// Zoom, Meet, Teams, Slack and FaceTime, so this is a call that is over
    /// while the app or page stays open.
    var quietHoldLimit: TimeInterval = 5 * 60

    private(set) var active: DetectedCall?
    private var candidate: (key: String, since: Date)?
    private var missingSince: Date?
    /// Last time the active call had the microphone.
    private var heardAt: Date?

    init(startDelay: TimeInterval = 4, endGrace: TimeInterval = 30, quietHoldLimit: TimeInterval = 5 * 60) {
        self.startDelay = startDelay
        self.endGrace = endGrace
        self.quietHoldLimit = quietHoldLimit
    }

    /// True while something is pending or on (poll faster).
    var isBusy: Bool { active != nil || candidate != nil }

    /// `sustained`: the call goes on (`isSustained`); `heard`: it still has
    /// the microphone (`isHeard`), which keeps it on without a time limit.
    mutating func update(observed: [DetectedCall], sustained: Bool, heard: Bool = false, now: Date) -> MeetingCallEvent? {
        guard let current = active else {
            guard let top = observed.first else {
                candidate = nil
                return nil
            }
            if let candidate, candidate.key == top.key {
                guard now.timeIntervalSince(candidate.since) >= startDelay else { return nil }
                self.candidate = nil
                active = top
                missingSince = nil
                heardAt = now
                return .started(top)
            }
            candidate = (top.key, now)
            if startDelay <= 0 {
                candidate = nil
                active = top
                missingSince = nil
                heardAt = now
                return .started(top)
            }
            return nil
        }

        if let same = observed.first(where: { $0.key == current.key }) {
            missingSince = nil
            heardAt = now
            // Only a better title is news: a generic one never replaces a real one.
            if same.title != current.title, !same.hasGenericTitle || current.hasGenericTitle {
                active = same
                return .updated(same)
            }
            if same.calendarEventID != nil, current.calendarEventID == nil {
                active = same
                return .updated(same)
            }
            return nil
        }
        if heard {
            missingSince = nil
            heardAt = now
            return nil
        }
        if sustained, now.timeIntervalSince(heardAt ?? now) < quietHoldLimit {
            missingSince = nil
            return nil
        }
        let since = missingSince ?? now
        missingSince = since
        guard now.timeIntervalSince(since) >= endGrace else { return nil }
        active = nil
        missingSince = nil
        heardAt = nil
        candidate = nil
        return .ended(current)
    }

    /// Forgets everything (detection turned off).
    mutating func reset() {
        active = nil
        candidate = nil
        missingSince = nil
        heardAt = nil
    }
}

// MARK: - Probe

/// Where the detector reads its signals. The live one reads CoreAudio,
/// NSWorkspace and (permitted) browsers; tests pass fakes.
protocol MeetingSignalProbe: AnyObject, Sendable {
    /// nil when per-process audio information isn't available.
    func audioProcesses() async -> [MeetingAudioProcess]?
    func isDefaultInputRunning() async -> Bool
    func runningApps() async -> MeetingRunningApps
    /// Meeting tabs of these browsers. Reads only browsers SparkV may
    /// already automate; never asks for permission.
    func meetingTabs(in browserBundleIDs: [String]) async -> [MeetingBrowserTab]
    /// Calls `changed` when the audio setup changes (a process starts or
    /// stops the microphone), so detection doesn't wait for the next poll.
    @MainActor func startObserving(_ changed: @escaping @MainActor @Sendable () -> Void)
    @MainActor func stopObserving()
}

// MARK: - Detector

/// Polls the signals (every 2 s while a call is pending or on or anything
/// else uses the microphone, every 8 s otherwise, plus right away when
/// CoreAudio reports a change) and reports calls starting and ending.
@MainActor
final class MeetingCallDetector: ObservableObject {
    @Published private(set) var activeCall: DetectedCall?
    @Published private(set) var isRunning = false

    var onEvent: ((MeetingCallEvent) -> Void)?
    /// Today's meetings (MeetingsController), to name and link calls.
    var calendar: () -> [CalendarMeeting] = { [] }
    /// SparkV itself is using the microphone (matters only without
    /// per-process information, where the mic flag can't tell apps apart).
    var isOwnMicActive: () -> Bool = { false }

    nonisolated static let hotInterval: TimeInterval = 2
    nonisolated static let idleInterval: TimeInterval = 8
    nonisolated static let tabRefreshInterval: TimeInterval = 6

    let probe: any MeetingSignalProbe
    private let clock: () -> Date
    private let ownPID: Int32
    private let ownBundleID: String?
    private var debouncer: MeetingCallDebouncer
    private var loop: Task<Void, Never>?
    private var isTicking = false
    private var lastTickWasHot = false
    /// When the next scheduled evaluation runs (wall clock).
    private var nextTickAt = Date.distantFuture
    private var tabs: [MeetingBrowserTab] = []
    private var tabsReadAt = Date.distantPast
    private var tabsReadFor: Set<String> = []

    init(
        probe: any MeetingSignalProbe,
        clock: @escaping () -> Date = { Date() },
        debouncer: MeetingCallDebouncer = MeetingCallDebouncer(),
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.probe = probe
        self.clock = clock
        self.debouncer = debouncer
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        probe.startObserving { [weak self] in self?.kick() }
        schedule(after: 1)
    }

    /// Stops polling and forgets the current call without an `.ended`
    /// event (turning detection off must not stop a recording).
    func stop() {
        guard isRunning else { return }
        isRunning = false
        loop?.cancel()
        loop = nil
        nextTickAt = .distantFuture
        probe.stopObserving()
        debouncer.reset()
        activeCall = nil
        tabs = []
        tabsReadFor = []
        tabsReadAt = .distantPast
    }

    /// Re-evaluates soon (CoreAudio reported a change). A burst of changes
    /// never pushes the evaluation back: one already due soon stays.
    func kick() {
        guard isRunning, !isTicking, nextTickAt.timeIntervalSinceNow > 0.3 else { return }
        schedule(after: 0.3)
    }

    private func schedule(after delay: TimeInterval) {
        loop?.cancel()
        nextTickAt = Date().addingTimeInterval(delay)
        loop = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.isRunning else { return }
            await self.tick()
            guard !Task.isCancelled, self.isRunning else { return }
            self.schedule(after: self.lastTickWasHot ? Self.hotInterval : Self.idleInterval)
        }
    }

    /// One evaluation. Internal so tests drive it with a fake clock.
    @discardableResult
    func tick() async -> MeetingCallEvent? {
        guard !isTicking else { return nil }
        isTicking = true
        defer { isTicking = false }

        let processes = await probe.audioProcesses()
        let inputRunning = processes == nil ? await probe.isDefaultInputRunning() : false
        let apps = await probe.runningApps()
        let ownMic = isOwnMicActive()

        var signals = MeetingCallSignals(
            processes: processes,
            defaultInputRunning: inputRunning,
            ownMicActive: ownMic,
            ownPID: ownPID,
            ownBundleID: ownBundleID,
            apps: apps,
            tabs: [],
            calendar: calendar(),
            now: clock()
        )

        let wanted = tabBrowsers(signals)
        if wanted.isEmpty {
            tabs = []
            tabsReadFor = []
        } else if wanted != tabsReadFor || signals.now.timeIntervalSince(tabsReadAt) >= Self.tabRefreshInterval {
            tabs = await probe.meetingTabs(in: wanted.sorted())
            tabsReadAt = clock()
            tabsReadFor = wanted
        }
        signals.tabs = tabs
        signals.now = clock()

        let observed = MeetingCallEvaluator.observe(signals)
        let sustained = debouncer.active.map { MeetingCallEvaluator.isSustained($0, signals) } ?? false
        let heard = debouncer.active.map { MeetingCallEvaluator.isHeard($0, signals) } ?? false
        let event = debouncer.update(observed: observed, sustained: sustained, heard: heard, now: signals.now)

        let othersOnMic = processes.map { list in
            list.contains { $0.isRunningInput && !MeetingCallEvaluator.isOwn($0, signals) }
        } ?? (inputRunning && !ownMic)
        lastTickWasHot = debouncer.isBusy || othersOnMic

        if activeCall != debouncer.active { activeCall = debouncer.active }
        if let event { onEvent?(event) }
        return event
    }

    /// Browsers worth reading tabs from: those using the microphone (or all
    /// running ones when processes can't be told apart), and the browser of
    /// the call that is on.
    private func tabBrowsers(_ signals: MeetingCallSignals) -> Set<String> {
        let running = signals.apps.bundleIDs
        var wanted: Set<String> = []
        if let processes = signals.processes {
            for process in processes where process.isRunningInput && !MeetingCallEvaluator.isOwn(process, signals) {
                if let browser = MeetingCallCatalog.browser(for: process, running: running), browser.scripting != nil {
                    wanted.insert(browser.bundleID)
                }
            }
        } else if signals.defaultInputRunning, !signals.ownMicActive {
            for browser in MeetingCallCatalog.browsers where browser.scripting != nil && running.contains(browser.bundleID) {
                wanted.insert(browser.bundleID)
            }
        }
        if case .browser(let bundleID, let tabKey)? = debouncer.active?.source, tabKey != nil,
           MeetingCallCatalog.browser(bundleID: bundleID)?.scripting != nil, running.contains(bundleID) {
            wanted.insert(bundleID)
        }
        return wanted
    }
}

// MARK: - LIVE (CoreAudio, NSWorkspace, AppleScript, UI)

/// Reads the real signals. CoreAudio and AppleScript run off the main thread.
final class LiveMeetingSignalProbe: MeetingSignalProbe, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.MeetingDetector", qos: .utility)
    /// pid → (executable path, owner bundle ID). Touched on `queue` only.
    private var owners: [Int32: (path: String, owner: String?)] = [:]
    private let lock = NSLock()
    /// Browser → (when checked, may automate). Behind `lock`.
    private var automation: [String: (at: Date, granted: Bool)] = [:]

    // Main actor only.
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var onChange: (@MainActor @Sendable () -> Void)?

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Audio processes

    func audioProcesses() async -> [MeetingAudioProcess]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: readProcesses()) }
        }
    }

    func isDefaultInputRunning() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let device = Self.defaultInputDevice() else { return continuation.resume(returning: false) }
                continuation.resume(returning: Self.uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0)
            }
        }
    }

    private func readProcesses() -> [MeetingAudioProcess]? {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &objects) == noErr else { return nil }

        var result: [MeetingAudioProcess] = []
        var alive: Set<Int32> = []
        for object in objects {
            let input = Self.uint32(object, kAudioProcessPropertyIsRunningInput) != 0
            let output = Self.uint32(object, kAudioProcessPropertyIsRunningOutput) != 0
            guard input || output else { continue }
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 else { continue }
            alive.insert(pid)
            let owner = owner(of: pid)
            result.append(MeetingAudioProcess(
                pid: pid,
                bundleID: Self.string(object, kAudioProcessPropertyBundleID),
                ownerBundleID: owner.owner,
                executable: (owner.path as NSString).lastPathComponent,
                isRunningInput: input,
                isRunningOutput: output
            ))
        }
        if owners.count > 64 { owners = owners.filter { alive.contains($0.key) } }
        return result
    }

    /// Executable path and the bundle ID of the outermost .app it lives in.
    private func owner(of pid: pid_t) -> (path: String, owner: String?) {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        if let cached = owners[pid], cached.path == path { return cached }
        var ownerID: String?
        if let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            ownerID = Bundle(path: appPath)?.bundleIdentifier
        }
        let entry = (path: path, owner: ownerID)
        owners[pid] = entry
        return entry
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    private static func defaultInputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    // MARK: Apps

    func runningApps() async -> MeetingRunningApps {
        await MainActor.run {
            let workspace = NSWorkspace.shared
            return MeetingRunningApps(
                bundleIDs: Set(workspace.runningApplications.compactMap(\.bundleIdentifier)),
                frontmost: workspace.frontmostApplication?.bundleIdentifier
            )
        }
    }

    // MARK: Tabs

    func meetingTabs(in browserBundleIDs: [String]) async -> [MeetingBrowserTab] {
        var tabs: [MeetingBrowserTab] = []
        for bundleID in browserBundleIDs {
            guard let browser = MeetingCallCatalog.browser(bundleID: bundleID), let scripting = browser.scripting,
                  await mayAutomate(bundleID) else { continue }
            let script = MeetingTabClassifier.tabScript(bundleID: bundleID, scripting: scripting)
            switch await SpaceAppleEvents.shared.run(script, timeout: 5) {
            case .success(let output):
                tabs += MeetingTabClassifier.parseTabs(output, browserBundleID: bundleID)
            case .failure(.notPermitted):
                setAutomation(bundleID, granted: false)
            case .failure:
                break
            }
        }
        return tabs
    }

    /// Already allowed to automate `bundleID` (checked at most every 30 s
    /// through PermissionCenter, which never prompts for a read).
    private func mayAutomate(_ bundleID: String) async -> Bool {
        let cached = lock.withLock { automation[bundleID] }
        if let cached, Date().timeIntervalSince(cached.at) < 30 { return cached.granted }
        let status = await PermissionCenter.shared.freshStatus(.automation(bundleID: bundleID))
        setAutomation(bundleID, granted: status.isGranted)
        return status.isGranted
    }

    private func setAutomation(_ bundleID: String, granted: Bool) {
        lock.withLock { automation[bundleID] = (Date(), granted) }
    }

    /// Forgets cached Automation answers (after the user granted access).
    func forgetAutomation() {
        lock.withLock { automation.removeAll() }
    }

    // MARK: Change notifications

    @MainActor
    func startObserving(_ changed: @escaping @MainActor @Sendable () -> Void) {
        stopObserving()
        onChange = changed
        addListener(Self.system, kAudioHardwarePropertyProcessObjectList)
        addListener(Self.system, kAudioHardwarePropertyDefaultInputDevice)
        if let device = Self.defaultInputDevice() {
            addListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
    }

    @MainActor
    func stopObserving() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        listeners.removeAll()
        onChange = nil
    }

    @MainActor
    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let isDeviceSwitch = selector == kAudioHardwarePropertyDefaultInputDevice
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let onChange = self.onChange else { return }
                if isDeviceSwitch { self.startObserving(onChange) }
                onChange()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        listeners.append((object, address, block))
    }
}

extension MeetingCallDetector {
    /// Supported browsers that are running now: the ones "Detect Calls in
    /// Browser Tabs" asks about.
    static var runningScriptableBrowsers: [MeetingCallBrowser] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return MeetingCallCatalog.browsers.filter { $0.scripting != nil && running.contains($0.bundleID) }
    }

    /// From a user action only: lets SparkV read meeting tabs of the running
    /// browsers (one Automation prompt per browser, through PermissionCenter).
    func requestBrowserAccess() {
        let browsers = Self.runningScriptableBrowsers
        guard !browsers.isEmpty else { return }
        Task { [weak self] in
            for browser in browsers {
                let status = await PermissionCenter.shared.request(.automation(bundleID: browser.bundleID), from: "Meeting detection")
                AppLog.log("Meetings: browser tab access for \(browser.name) \(status.rawValue)")
            }
            (self?.probe as? LiveMeetingSignalProbe)?.forgetAutomation()
            self?.kick()
        }
    }
}

// MARK: - Icons

/// The icon for a detected call: the call app's, else the meeting app the
/// link opens in, else the browser's.
@MainActor
enum MeetingCallIcon {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for call: DetectedCall) -> NSImage? {
        var candidates: [String] = []
        if case .app(let id) = call.source { candidates += MeetingCallCatalog.app(id: id)?.bundleIDs ?? [] }
        if call.key == "app:meet-pwa" { candidates.append(MeetingCallCatalog.meetPWABundleID) }
        candidates += call.provider?.appBundleIDs ?? []
        if let browser = call.iconBundleID { candidates.append(browser) }
        for bundleID in candidates {
            if let cached = cache[bundleID] {
                if let cached { return cached }
                continue
            }
            let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            if cache.count >= 64 { cache.removeAll() }
            cache[bundleID] = found
            if let found { return found }
        }
        return nil
    }
}

// MARK: - Haptics

/// A light tick on the trackpad (Force Touch trackpads only; nothing
/// elsewhere), for hover and press on the call prompt.
@MainActor
enum MeetingHaptics {
    /// Hovering never taps the trackpad (Trackpad Haptics: only presses,
    /// swipes, drops and detents do).
    static func hover() {}
    static func press() { SparkVHaptics.perform(.levelChange) }
}

// MARK: - Views

/// The band when a call starts: "Google Meet started · Take notes?" with a
/// Start pill. Hovering it opens the Today tab, whose first row has the
/// working Start button (`DetectedCallBanner`).
struct MeetingCallPromptBand: View {
    let call: DetectedCall
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            MeetingProviderBadge(provider: call.provider, appIcon: icon, calendarColor: SparkVTheme.red)
            HStack(spacing: 5) {
                Text("\(call.serviceName) started")
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !call.hasGenericTitle {
                    Text("· \(call.title)")
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("· Take notes?")
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Text("Start").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Capsule().fill(SparkVTheme.red))
            .fixedSize()
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The compact form beside the camera: the call app's icon and "Notes?".
struct MeetingCallPromptCompact: View {
    let call: DetectedCall
    let icon: NSImage?
    var size: CGFloat = 16

    var body: some View {
        MeetingProviderBadge(provider: call.provider, appIcon: icon, calendarColor: SparkVTheme.red, size: size)
    }
}

/// First row of the Today tab while a call is on and not recorded:
/// "● Google Meet · Weekly sync   [Take Notes] [×]". Renders nothing
/// otherwise, so it can sit above the meeting list unconditionally.
struct DetectedCallBanner: View {
    @EnvironmentObject private var assistant: MeetingAssistant

    var body: some View {
        Group {
            if let call = assistant.promptedCall {
                DetectedCallRow(call: call, start: { assistant.startDetectedCall() }, dismiss: { assistant.dismissDetectedCall() })
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: assistant.promptedCall?.key)
    }
}

private struct DetectedCallRow: View {
    let call: DetectedCall
    let start: () -> Void
    let dismiss: () -> Void

    @StateObject private var pulse = ViewFlag()

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(SparkVTheme.success.opacity(0.35)).frame(width: 10, height: 10)
                    .scaleEffect(pulse.isOn ? 1.25 : 0.7)
                    .opacity(pulse.isOn ? 0 : 1)
                Circle().fill(SparkVTheme.success).frame(width: 6, height: 6)
            }
            .frame(width: 12)
            .onAppear {
                // Constant ripple; still under Reduce Motion or on a hot Mac.
                guard !SparkVMotion.reduceMotion, !SparkVEnergy.shared.pausesDecoration else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse.isOn = true }
            }

            MeetingProviderBadge(provider: call.provider, appIcon: MeetingCallIcon.icon(for: call), calendarColor: SparkVTheme.red, size: 14)

            Text(call.hasGenericTitle ? "\(call.title) on" : call.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            MeetingCallPill(title: "Take Notes", systemImage: "record.circle", isPrimary: true, action: start)
                .help("Record this call and write notes. Let participants know you're recording.")
            MeetingCallPill(title: nil, systemImage: "xmark", isPrimary: false, action: dismiss)
                .help("Not this call")
        }
        .frame(height: 20)
    }
}

/// Capsule button with a hover lift, a trackpad tick on hover and press,
/// and a quick press squeeze.
struct MeetingCallPill: View {
    let title: String?
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            MeetingHaptics.press()
            action()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
                if let title { Text(title).font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundStyle(isPrimary ? Color.white : SparkVTheme.textSecondary)
            .padding(.horizontal, title == nil ? 5 : 8)
            .frame(height: 18)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(isPrimary ? Color.clear : SparkVTheme.stroke))
            .contentShape(Capsule())
            .scaleEffect(hover.isOn ? 1.04 : 1)
        }
        .buttonStyle(MeetingCallPressStyle())
        .fixedSize()
        .onHover { inside in
            if inside, !hover.isOn { MeetingHaptics.hover() }
            withAnimation(.easeOut(duration: 0.14)) { hover.isOn = inside }
        }
    }

    private var fill: Color {
        if isPrimary { return hover.isOn ? SparkVTheme.redDeep : SparkVTheme.red }
        return hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface
    }
}

private struct MeetingCallPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Items for the settings menu's "Meetings" submenu: take notes for the
/// call that is on, call detection and auto-start toggles, browser access.
struct MeetingCallMenuItems: View {
    @ObservedObject var assistant: MeetingAssistant

    var body: some View {
        if let call = assistant.promptedCall {
            Button("Take Notes for \(call.title)") {
                assistant.startDetectedCall()
            }
        }
        Toggle("Detect Calls (Zoom, Meet, Teams, Slack, Webex, FaceTime)", isOn: $assistant.detectCalls)
        Toggle("Start Notes Automatically When a Call Starts", isOn: $assistant.autoStartDetectedCalls)
            .disabled(!assistant.detectCalls)
        Button("Detect Calls in Browser Tabs…") { assistant.callDetector.requestBrowserAccess() }
            .disabled(!assistant.detectCalls || MeetingCallDetector.runningScriptableBrowsers.isEmpty)
        Text("Let participants know when you record a call")
    }
}
