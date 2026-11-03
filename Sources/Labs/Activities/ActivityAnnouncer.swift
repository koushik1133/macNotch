import AppKit

/// Speaks important live changes to VoiceOver (charging started, a timer
/// finished, a meeting in 5 minutes, an incoming call) without spamming:
///
/// - only while VoiceOver runs, and only for categories the user keeps on;
/// - only when an activity first appears or its `peekKey` changes, never
///   for volume or brightness (macOS speaks those itself);
/// - the same sentence for the same activity at most once every 30 s;
/// - at least 3 s between announcements: anything arriving sooner waits,
///   newer posts of the same activity replace older waiting ones, and a
///   waiting one older than 10 s is dropped. Calls skip the wait.
///
/// Posts `NSAccessibility.Notification.announcementRequested` on the app
/// element (a public API, no permission needed).
@MainActor
final class ActivityAnnouncer {
    static let shared = ActivityAnnouncer()

    static let minimumGap: TimeInterval = 3
    static let repeatWindow: TimeInterval = 30
    static let maxWait: TimeInterval = 10
    static let maxPending = 3

    /// Test seams.
    var isVoiceOverRunning: @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    var speak: @MainActor (String, Bool) -> Void = { text, important in
        let priority: NSAccessibilityPriorityLevel = important ? .high : .medium
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: priority.rawValue]
        )
    }
    var allows: @MainActor (ActivityAnnouncement.Category) -> Bool = { category in
        let settings = ActivityAnnouncementSettings.shared
        return settings.isEnabled && settings.isOn(category)
    }
    var isEnabledOverall: @MainActor () -> Bool = { ActivityAnnouncementSettings.shared.isEnabled }

    private struct Pending {
        var id: String
        var text: String
        var isImportant: Bool
        var queuedAt: Date
    }

    private let clock: () -> Date
    private var lastSpoken: [String: (text: String, at: Date)] = [:]
    private var lastAnyAt: Date = .distantPast
    private var pending: [Pending] = []
    private var flushTask: Task<Void, Never>?
    /// Every sentence spoken, newest last (diagnostics and tests; never logged).
    private(set) var spokenCount = 0

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Called by `ActivityCenter.post` for every post.
    func consider(_ activity: LiveActivity, isNew: Bool, peekKeyChanged: Bool) {
        guard let announcement = activity.announcement, !activity.kind.isLiveFeedback,
              isNew || peekKeyChanged
        else { return }
        announce(announcement.text, id: activity.id, category: announcement.category, important: announcement.isImportant)
    }

    /// Speaks `text` for `id` if VoiceOver runs and `category` is on.
    /// `ignoresCategory` (Settings' Test Announcement): only the master
    /// switch counts, not the category's own.
    func announce(_ text: String, id: String, category: ActivityAnnouncement.Category, important: Bool = false, ignoresCategory: Bool = false) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = ignoresCategory ? isEnabledOverall() : allows(category)
        guard !sentence.isEmpty, allowed, isVoiceOverRunning() else { return }
        let now = clock()
        if let last = lastSpoken[id], last.text == sentence, now.timeIntervalSince(last.at) < Self.repeatWindow { return }
        let urgent = category == .call
        if urgent || now.timeIntervalSince(lastAnyAt) >= Self.minimumGap, pending.isEmpty || urgent {
            say(sentence, id: id, important: important || urgent, now: now)
            return
        }
        // Coalesce: one waiting sentence per activity, the newest.
        pending.removeAll { $0.id == id }
        pending.append(Pending(id: id, text: sentence, isImportant: important, queuedAt: now))
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        scheduleFlush(now: now)
    }

    /// Drops anything waiting (e.g. announcements were turned off).
    func cancelPending() {
        pending.removeAll()
        flushTask?.cancel()
        flushTask = nil
    }

    /// Speaks the next waiting sentence if its turn came (also the timer's
    /// target; tests call it with a moved clock).
    func flush() {
        flushTask = nil
        let now = clock()
        pending.removeAll { now.timeIntervalSince($0.queuedAt) > Self.maxWait }
        guard !pending.isEmpty else { return }
        guard now.timeIntervalSince(lastAnyAt) >= Self.minimumGap - 0.01 else {
            scheduleFlush(now: now)
            return
        }
        let next = pending.removeFirst()
        guard isVoiceOverRunning() else { pending.removeAll(); return }
        say(next.text, id: next.id, important: next.isImportant, now: now)
        if !pending.isEmpty { scheduleFlush(now: now) }
    }

    var pendingCount: Int { pending.count }

    private func say(_ text: String, id: String, important: Bool, now: Date) {
        lastSpoken[id] = (text, now)
        lastAnyAt = now
        spokenCount += 1
        // Old entries can't block anything any more.
        if lastSpoken.count > 64 {
            lastSpoken = lastSpoken.filter { now.timeIntervalSince($0.value.at) < Self.repeatWindow }
        }
        speak(text, important)
    }

    private func scheduleFlush(now: Date) {
        guard flushTask == nil else { return }
        let delay = max(0.05, Self.minimumGap - now.timeIntervalSince(lastAnyAt))
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

/// Ready-made sentences for the features that post activities, so the
/// wording stays consistent (and testable).
enum ActivityAnnouncementText {
    static func charging(level: Int, minutesToFull: Int?) -> String {
        if let minutes = minutesToFull, minutes > 0 {
            return "Charging, \(level) percent, \(durationText(minutes: minutes)) until full"
        }
        return "Charging, \(level) percent"
    }

    static func charged(level: Int) -> String { level >= 100 ? "Fully charged" : "Not charging, \(level) percent" }
    static func onBattery(level: Int) -> String { "On battery, \(level) percent" }
    static func lowBattery(level: Int) -> String { "Low battery, \(level) percent" }
    static func criticalBattery(level: Int) -> String { "Battery critically low, \(level) percent. Plug in soon" }

    static func airPods(name: String, percent: Int?) -> String {
        percent.map { "\(name) connected, \($0) percent" } ?? "\(name) connected"
    }

    /// For `PowerMonitor.postBattery`.
    static func battery(_ reading: BatteryReading, mode: BatteryActivityMode) -> String {
        switch mode {
        case .charging: charging(level: reading.level, minutesToFull: reading.minutesToFull)
        case .charged: charged(level: 100)
        case .notCharging: charged(level: reading.level)
        case .onBattery: onBattery(level: reading.level)
        case .low: lowBattery(level: reading.level)
        case .critical: criticalBattery(level: reading.level)
        }
    }

    /// Battery sentences that must not wait behind others.
    static func isImportant(_ mode: BatteryActivityMode) -> Bool {
        mode == .low || mode == .critical
    }

    /// For `PowerMonitor.postAirPods`: the lower earbud, else the headset.
    static func airPods(_ device: BluetoothAudioDevice) -> String {
        let buds = [device.batteries.left, device.batteries.right].compactMap { $0 }
        return airPods(name: device.name, percent: buds.min() ?? device.batteries.single)
    }

    static func timerFinished(_ message: String) -> String {
        message.isEmpty ? "Timer finished" : message
    }

    /// "Meeting in 5 minutes: Design review" (title only when allowed).
    static func meeting(title: String?, minutes: Int?) -> String {
        let when: String = switch minutes {
        case nil, 0?: "Meeting starting now"
        case 1?: "Meeting in 1 minute"
        case let m?: "Meeting in \(m) minutes"
        }
        guard let title, !title.isEmpty else { return when }
        return "\(when): \(title)"
    }

    /// Respects the notification privacy setting: app only, app and sender,
    /// or (if the user asked VoiceOver to read it) the message too.
    static func notification(app: String?, sender: String?, body: String?) -> String {
        let source = app.map { "Notification from \($0)" } ?? "New notification"
        guard let sender, !sender.isEmpty, sender != app else { return source }
        guard let body, !body.isEmpty else { return "\(source): \(sender)" }
        return "\(source): \(sender). \(body)"
    }

    static func incomingCall(app: String?, caller: String?) -> String {
        let service = app.map { " on \($0)" } ?? ""
        guard let caller, !caller.isEmpty else { return "Incoming call\(service)" }
        return "Incoming call from \(caller)\(service)"
    }

    static func nowPlaying(title: String, artist: String) -> String {
        artist.isEmpty ? "Now playing \(title)" : "Now playing \(title) by \(artist)"
    }

    static func durationText(minutes: Int) -> String {
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        let rest = minutes % 60
        let h = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? h : "\(h) \(rest) minutes"
    }
}
