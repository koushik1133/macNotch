import CoreGraphics
import Foundation

// Pure detector logic for Smart Moments: no system calls, so every moment's
// trigger rule is tested with fake inputs. `SmartMomentsLiveSources` feeds
// them real readings (windows, displays, idle time, battery, audio route).

// MARK: - Meeting soon

enum MomentMeetingSoonScanner {
    /// Meetings with a link that start within `leadMinutes` (or started less
    /// than a minute ago), soonest first, with the minutes left (0 = now).
    static func due(_ meetings: [CalendarMeeting], now: Date, leadMinutes: Int) -> [(meeting: CalendarMeeting, minutes: Int)] {
        let lead = TimeInterval(max(1, leadMinutes) * 60)
        return meetings
            .filter { meeting in
                guard meeting.link != nil, meeting.end > now else { return false }
                let until = meeting.start.timeIntervalSince(now)
                return until <= lead && until > -60
            }
            .sorted { $0.start < $1.start }
            .map { meeting in
                let until = meeting.start.timeIntervalSince(now)
                return (meeting, until <= 30 ? 0 : Int((until / 60).rounded(.up)))
            }
    }
}

// MARK: - Deep work (front app dwell)

struct MomentDwellTracker: Sendable, Equatable {
    /// Away this long breaks the stretch.
    var idleBreak: TimeInterval = 5 * 60
    private(set) var bundleID: String?
    private(set) var appName: String?
    private(set) var since: Date?
    private(set) var firedThisStretch = false

    init(idleBreak: TimeInterval = 5 * 60) { self.idleBreak = idleBreak }

    mutating func frontmostChanged(bundleID: String?, appName: String?, at now: Date) {
        guard bundleID != self.bundleID else { return }
        self.bundleID = bundleID
        self.appName = appName
        since = bundleID == nil ? nil : now
        firedThisStretch = false
    }

    /// Called about once a minute. `blocked` = a Focus session runs or a
    /// call is on (the moment would only nag then).
    mutating func sample(
        now: Date, idleSeconds: TimeInterval, thresholdMinutes: Int,
        excluded: Set<String>, ownBundleID: String?, blocked: Bool
    ) -> MomentTrigger? {
        if idleSeconds >= idleBreak {
            since = bundleID == nil ? nil : now
            firedThisStretch = false
            return nil
        }
        guard !blocked, !firedThisStretch, let bundleID, let since,
              !excluded.contains(bundleID), bundleID != ownBundleID else { return nil }
        let minutes = Int(now.timeIntervalSince(since) / 60)
        guard minutes >= max(1, thresholdMinutes) else { return nil }
        firedThisStretch = true
        return .deepWork(appBundleID: bundleID, appName: appName ?? bundleID, minutes: minutes)
    }
}

// MARK: - Late night

struct MomentLateNightTracker: Sendable, Equatable {
    /// Active this long inside the window before the moment fires.
    var activeFor: TimeInterval = 10 * 60
    /// The night ends at this hour.
    var morningHour = 5
    private(set) var activeSince: Date?

    init(activeFor: TimeInterval = 10 * 60) { self.activeFor = activeFor }

    static func isLate(hour: Int, startHour: Int, morningHour: Int = 5) -> Bool {
        if startHour >= morningHour { return hour >= startHour || hour < morningHour }
        return hour >= startHour && hour < morningHour // a start past midnight (0...4)
    }

    mutating func sample(now: Date, idleSeconds: TimeInterval, startHour: Int, calendar: Calendar = .current) -> MomentTrigger? {
        let hour = calendar.component(.hour, from: now)
        guard Self.isLate(hour: hour, startHour: startHour, morningHour: morningHour), idleSeconds < 120 else {
            activeSince = nil
            return nil
        }
        guard let since = activeSince else {
            activeSince = now
            return nil
        }
        guard now.timeIntervalSince(since) >= activeFor else { return nil }
        return .lateNight(hour: hour) // the engine's cooldown keeps it to once a night
    }
}

// MARK: - Low battery while recording

struct MomentLowBatteryWatch: Sendable, Equatable {
    static let criticalPercent = 5
    private(set) var firedLow = false
    private(set) var firedCritical = false

    init() {}

    mutating func sample(
        level: Int, onBattery: Bool, minutesLeft: Int?, recording: MomentRecordingKind?, thresholdPercent: Int
    ) -> MomentTrigger? {
        guard onBattery, let recording else {
            firedLow = false
            firedCritical = false
            return nil
        }
        if level <= Self.criticalPercent, !firedCritical {
            firedCritical = true
            firedLow = true
            return .lowBatteryWhileRecording(level: level, minutesLeft: minutesLeft, recording: recording)
        }
        if level <= thresholdPercent, !firedLow {
            firedLow = true
            return .lowBatteryWhileRecording(level: level, minutesLeft: minutesLeft, recording: recording)
        }
        return nil
    }
}

// MARK: - On/off debouncing (screen sharing, presentation)

struct MomentEdgeDebouncer: Sendable, Equatable {
    let onAfter: Int
    let offAfter: Int
    private(set) var isOn = false
    private var streak = 0

    init(onAfter: Int = 2, offAfter: Int = 2) {
        self.onAfter = max(1, onAfter)
        self.offAfter = max(1, offAfter)
    }

    /// Returns the new state when it flips.
    mutating func feed(_ observed: Bool) -> Bool? {
        guard observed != isOn else {
            streak = 0
            return nil
        }
        streak += 1
        guard streak >= (observed ? onAfter : offAfter) else { return nil }
        isOn = observed
        streak = 0
        return isOn
    }

    mutating func reset() {
        isOn = false
        streak = 0
    }
}

// MARK: - Windows and displays

/// One `CGWindowListCopyWindowInfo` entry. `name` is nil unless SparkV has
/// Screen Recording access (the call itself never prompts).
struct MomentWindowInfo: Sendable, Equatable {
    var ownerPID: Int32
    var ownerName: String?
    var bundleID: String?
    var name: String?
    var layer: Int
    /// Global display coordinates, top-left origin (as CGDisplayBounds).
    var bounds: CGRect
    var isOnscreen: Bool = true
}

struct MomentDisplayInfo: Sendable, Equatable {
    var id: UInt32
    var name: String
    /// CGDisplayBounds.
    var frame: CGRect
    var isBuiltin: Bool
}

enum MomentScreenShareHeuristics {
    /// Window titles the sharing UI of call apps and browsers uses, in
    /// lowercase. Chrome/Edge/Arc: "meet.google.com is sharing your screen.";
    /// Zoom: "zoom share toolbar", "zoom share statusBar window"; Teams:
    /// "Sharing control bar"; Webex: "You're sharing".
    static let titleMarkers = [
        "is sharing your screen", "is sharing a window", "is sharing this tab", "is sharing your entire screen",
        "share toolbar", "share statusbar", "sharing control bar", "screen sharing toolbar",
        "you're sharing", "you are sharing", "you’re sharing",
    ]

    /// The window that shows another app is sharing the screen, if any.
    static func sharer(in windows: [MomentWindowInfo], ownPID: Int32) -> MomentWindowInfo? {
        windows.first { window in
            guard window.ownerPID != ownPID, window.isOnscreen, let name = window.name?.lowercased(), !name.isEmpty else { return false }
            return titleMarkers.contains { name.contains($0) }
        }
    }
}

enum MomentPresentationHeuristics {
    static let slideshowApps: [String: String] = [
        "com.apple.iWork.Keynote": "Keynote",
        "com.microsoft.Powerpoint": "PowerPoint",
    ]
    /// Fullscreen apps that are not a talk.
    static let notPresentations: Set<String> = [
        "com.apple.TV", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
        "com.apple.Photos", "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2",
    ]

    struct Detection: Sendable, Equatable {
        var bundleID: String?
        var appName: String
        var isSlideshow: Bool
    }

    static func covers(_ window: CGRect, _ display: CGRect, tolerance: CGFloat = 2) -> Bool {
        window.minX <= display.minX + tolerance && window.minY <= display.minY + tolerance
            && window.maxX >= display.maxX - tolerance && window.maxY >= display.maxY - tolerance
    }

    /// Keynote/PowerPoint playing (a raised fullscreen window or a "Slide
    /// Show" window), or another front app fullscreen on an external display.
    static func detect(
        frontBundleID: String?, frontName: String?, frontPID: Int32?,
        windows: [MomentWindowInfo], displays: [MomentDisplayInfo], ownPID: Int32
    ) -> Detection? {
        guard let frontPID, frontPID != ownPID else { return nil }
        let mine = windows.filter { $0.ownerPID == frontPID && $0.isOnscreen }
        if let bundleID = frontBundleID, let app = slideshowApps[bundleID] {
            let playing = mine.contains { window in
                if let name = window.name?.lowercased(), name.contains("slide show") || name.contains("slideshow") { return true }
                let full = displays.contains { covers(window.bounds, $0.frame) }
                let onExternal = displays.contains { !$0.isBuiltin && covers(window.bounds, $0.frame) }
                return full && (window.layer > 0 || onExternal)
            }
            return playing ? Detection(bundleID: bundleID, appName: app, isSlideshow: true) : nil
        }
        if let bundleID = frontBundleID, notPresentations.contains(bundleID) { return nil }
        let externalFull = mine.contains { window in
            displays.contains { !$0.isBuiltin && covers(window.bounds, $0.frame) }
        }
        guard externalFull else { return nil }
        return Detection(bundleID: frontBundleID, appName: frontName ?? "Fullscreen app", isSlideshow: false)
    }
}

/// Newly connected external displays (the first reading is the baseline).
struct MomentDisplayDiff: Sendable, Equatable {
    private(set) var known: Set<UInt32>?

    init() {}

    mutating func update(_ displays: [MomentDisplayInfo]) -> [MomentDisplayInfo] {
        let ids = Set(displays.map(\.id))
        defer { known = ids }
        guard let known else { return [] }
        return displays.filter { !$0.isBuiltin && !known.contains($0.id) }
    }
}

// MARK: - Audio output (Meeting soon's device check)

struct MomentAudioOutput: Sendable, Equatable {
    var uid: String
    var name: String
    var isBluetooth: Bool
}

// MARK: - Text tools for the clipboard actions

enum MomentTextTools {
    /// Query parameters that only track the click.
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
        "_hsenc", "_hsmi", "mkt_tok", "ref_src", "ref_url", "s_cid", "si", "spm", "vero_id", "oly_enc_id", "oly_anon_id",
    ]

    /// The link without utm_* and click-tracking parameters; nil when there
    /// was nothing to remove.
    static func cleanLink(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count != items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url
    }

    /// `[title](url)`, with brackets in the title escaped.
    static func markdownLink(title: String?, url: URL) -> String {
        let raw = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? (url.host ?? url.absoluteString)
        let escaped = raw.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url.absoluteString))"
    }

    /// Trims blank edges and trailing spaces, turns tabs into 4 spaces, and
    /// removes the indentation every line shares.
    static func formatCode(_ code: String) -> String {
        var lines = code.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
            .map { line -> String in
                var line = line
                while line.last == " " { line.removeLast() }
                return line
            }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let indent = lines.filter { !$0.isEmpty }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(indent)) }.joined(separator: "\n")
    }
}
