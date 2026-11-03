import AppKit
import SwiftUI

// Meeting Intelligence: shared types for the three parts described in
// Sources/Labs/MeetingIntel/DESIGN.md.
//
// - (A) StartCoordinator.swift: a detected call -> one prompt band (Record
//   notes / Live captions / Translate captions), remembered per meeting kind,
//   and a pre-meeting brief.
// - (B) LiveAssist.swift: live flags (action items, decisions, questions,
//   bookmarks), talk-time meter and monologue nudge, caption band.
// - (C) WrapUp.swift: summary card, follow-up draft (Mail draft or copy,
//   never sent), Reminders on approval, file into a Space, talk-time stats.
//
// Everything here is pure data or tiny shared views. Nothing in this file
// records, sends, or writes to another app. Privacy rules every part keeps:
// on-device only (Groq only behind MeetingAssistant.allowGroqForMeetings),
// the red recording indicator stays visible while capturing, a consent
// reminder is shown when recording starts (also when it starts on its own),
// and nothing leaves SparkV without a click.

// MARK: - Activity ids and priorities

enum MeetingIntelActivity {
    /// (A) "Zoom call started" prompt band.
    static let startPrompt = "meetingIntel.start"
    /// (A) Pre-meeting brief peek.
    static let brief = "meetingIntel.brief"
    /// (B) Caption band (original or translated lines).
    static let captions = "meetingIntel.captions"
    /// (B) A flagged action item / decision / bookmark toast.
    static let flag = "meetingIntel.flag"
    /// (B) Monologue nudge.
    static let nudge = "meetingIntel.nudge"
    /// (C) Wrap-up card peek after the call.
    static let wrapUp = "meetingIntel.wrapUp"

    /// Above the calendar heads-up (60), below the recording indicator (65)
    /// so the red REC wings always stay visible.
    static let startPriority = 64
    static let briefPriority = 58
    /// Below the recording indicator: captions never hide it.
    static let captionsPriority = 62
    /// Short toasts, above captions.
    static let flagPriority = 66
    static let nudgePriority = 63
    static let wrapUpPriority = 61
}

// MARK: - Meeting kind (what "remember" is keyed by)

/// What a start choice is remembered for: the call service, narrowed to a
/// calendar series when the call matched a calendar event (e.g. the weekly
/// "Design sync" on Meet is remembered apart from other Meet calls).
struct MeetingKindKey: Hashable, Codable, Sendable, CustomStringConvertible {
    /// `MeetingLink.Provider.rawValue`, else the detected app name lowercased.
    var service: String
    /// Normalized calendar title when the call matched an event; nil otherwise.
    var series: String?

    var description: String { series.map { "\(service)/\($0)" } ?? service }
    /// Same service, any series.
    var serviceOnly: MeetingKindKey { MeetingKindKey(service: service, series: nil) }

    init(service: String, series: String?) {
        self.service = service
        self.series = series
    }

    /// The key for a detected call.
    init(call: DetectedCall) {
        service = call.provider?.rawValue ?? call.appName.lowercased()
        series = call.calendarEventID == nil || call.hasGenericTitle ? nil : Self.normalize(call.title)
    }

    /// "Design Sync (weekly)  #42" -> "design sync weekly".
    static func normalize(_ title: String) -> String? {
        let cleaned = title.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let words = String(cleaned).split(separator: " ").filter { !$0.allSatisfy(\.isNumber) }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - Start plan and remembered rule

/// What to run for a call. Captions and translation need the recorder
/// (they read MeetingAssistant's live transcript), so either implies capture;
/// `keepNotes` false means the minutes are not written for this call (the
/// transcript still stays on this Mac until the user deletes it).
struct MeetingStartPlan: Codable, Equatable, Sendable {
    var keepNotes: Bool
    var captions: Bool
    var translate: Bool
    /// BCP-47 target for translation; nil uses LiveTranslationController's.
    var targetLanguage: String?

    var needsRecording: Bool { keepNotes || captions || translate }

    static let notes = MeetingStartPlan(keepNotes: true, captions: false, translate: false, targetLanguage: nil)
    static let captionsOnly = MeetingStartPlan(keepNotes: false, captions: true, translate: false, targetLanguage: nil)
    static let translated = MeetingStartPlan(keepNotes: false, captions: true, translate: true, targetLanguage: nil)
}

/// What SparkV does next time a call of the same kind starts.
enum MeetingStartRule: Codable, Equatable, Sendable {
    /// Show the prompt band (default).
    case ask
    /// Start this plan after a short visible countdown the user can cancel,
    /// with the consent reminder shown.
    case auto(MeetingStartPlan)
    /// Never prompt for this kind.
    case never
}

/// UserDefaults-backed preferences shared by all three parts.
@MainActor
final class MeetingIntelPreferences: ObservableObject {
    static let shared = MeetingIntelPreferences()

    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "meetingIntel.enabled"
        static let rules = "meetingIntel.rules"
        static let showBrief = "meetingIntel.showBrief"
        static let flagging = "meetingIntel.flagging"
        static let talkMeter = "meetingIntel.talkMeter"
        static let monologueNudge = "meetingIntel.monologueNudge"
        static let monologueSeconds = "meetingIntel.monologueSeconds"
        static let autoCountdown = "meetingIntel.autoCountdown"
    }

    /// Master switch for the start prompt.
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    /// Show the pre-meeting brief with the prompt.
    @Published var showBrief: Bool { didSet { defaults.set(showBrief, forKey: Keys.showBrief) } }
    /// Flag action items and decisions live.
    @Published var flagging: Bool { didSet { defaults.set(flagging, forKey: Keys.flagging) } }
    /// Show the talk-time meter in the recording wings.
    @Published var talkMeter: Bool { didSet { defaults.set(talkMeter, forKey: Keys.talkMeter) } }
    /// Nudge after the user talks for `monologueSeconds` without a break.
    @Published var monologueNudge: Bool { didSet { defaults.set(monologueNudge, forKey: Keys.monologueNudge) } }
    @Published var monologueSeconds: TimeInterval {
        didSet { defaults.set(monologueSeconds, forKey: Keys.monologueSeconds) }
    }
    /// Seconds an `.auto` rule waits (Cancel visible) before it starts.
    @Published var autoCountdown: TimeInterval {
        didSet { defaults.set(autoCountdown, forKey: Keys.autoCountdown) }
    }
    @Published private(set) var rules: [MeetingKindKey: MeetingStartRule] = [:]

    static let monologueChoices: [TimeInterval] = [60, 90, 120, 180]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        showBrief = defaults.object(forKey: Keys.showBrief) as? Bool ?? true
        flagging = defaults.object(forKey: Keys.flagging) as? Bool ?? true
        talkMeter = defaults.object(forKey: Keys.talkMeter) as? Bool ?? true
        monologueNudge = defaults.object(forKey: Keys.monologueNudge) as? Bool ?? true
        monologueSeconds = defaults.object(forKey: Keys.monologueSeconds) as? Double ?? 120
        autoCountdown = defaults.object(forKey: Keys.autoCountdown) as? Double ?? 5
        if let data = defaults.data(forKey: Keys.rules),
           let stored = try? JSONDecoder().decode([StoredRule].self, from: data) {
            rules = Dictionary(stored.map { ($0.key, $0.rule) }, uniquingKeysWith: { _, new in new })
        }
    }

    /// The rule for `key`: its series first, then the service, else `.ask`.
    func rule(for key: MeetingKindKey) -> MeetingStartRule {
        rules[key] ?? rules[key.serviceOnly] ?? .ask
    }

    /// Remembers (or with `.ask`, forgets) the rule for `key`.
    func setRule(_ rule: MeetingStartRule, for key: MeetingKindKey) {
        if rule == .ask { rules[key] = nil } else { rules[key] = rule }
        persistRules()
    }

    func forgetAllRules() {
        rules = [:]
        persistRules()
    }

    private struct StoredRule: Codable {
        var key: MeetingKindKey
        var rule: MeetingStartRule
    }

    private func persistRules() {
        let stored = rules.map { StoredRule(key: $0.key, rule: $0.value) }
            .sorted { $0.key.description < $1.key.description }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Keys.rules) }
    }
}

// MARK: - Pre-meeting brief (A)

struct MeetingAttendee: Hashable, Codable, Sendable {
    var name: String
    /// Lowercased; nil when the calendar has none.
    var email: String?
    var isMe: Bool

    /// "Priya" from "Priya Raman" or "priya.raman@x.com".
    var firstName: String {
        if let first = name.split(separator: " ").first, !first.contains("@") { return String(first) }
        let local = (email ?? name).split(separator: "@").first.map(String.init) ?? name
        return local.split(whereSeparator: { $0 == "." || $0 == "_" }).first.map { $0.capitalized } ?? local
    }
}

/// A past meeting with overlapping attendees (MeetingAssistant library).
struct MeetingBriefPastMeeting: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var date: Date
    /// First sentence or two of `MeetingNotes.summary`.
    var summary: String
    /// Not-done tasks left from that meeting (mine first).
    var openTasks: [ActionItem]
    /// Attendees shared with the upcoming meeting (first names).
    var sharedPeople: [String]
}

/// A Space item that matches the meeting (SpaceStore.search).
struct MeetingBriefSpaceHit: Identifiable, Equatable, Sendable {
    let id: UUID
    var spaceName: String?
    var title: String
    var snippet: String
}

struct MeetingBrief: Equatable, Sendable {
    var title: String
    var start: Date?
    var end: Date?
    var calendarEventID: String?
    /// Lines from the event notes that read like an agenda (bullets,
    /// numbered lines), at most 6. Empty when the calendar isn't allowed.
    var agenda: [String]
    var attendees: [MeetingAttendee]
    /// Newest first, at most 3.
    var pastMeetings: [MeetingBriefPastMeeting]
    /// My open tasks across those meetings (deduplicated), at most 5.
    var openTasks: [ActionItem]
    /// At most 3.
    var spaceHits: [MeetingBriefSpaceHit]
    /// Which sources were readable ("Calendar", "Meetings", "Spaces").
    var sources: [String]

    var isEmpty: Bool { agenda.isEmpty && pastMeetings.isEmpty && openTasks.isEmpty && spaceHits.isEmpty }

    static func empty(title: String) -> MeetingBrief {
        MeetingBrief(title: title, start: nil, end: nil, calendarEventID: nil, agenda: [], attendees: [],
                     pastMeetings: [], openTasks: [], spaceHits: [], sources: [])
    }
}

// MARK: - The live session handed A -> B -> C

/// One call SparkV is helping with. Created by (A) when the user picks a
/// plan (or an `.auto` rule fires), handed to (B) while live and to (C) at
/// the end.
struct MeetingIntelSession: Identifiable, Equatable, Sendable {
    /// Same as the MeetingRecord id once recording started.
    var id: UUID
    var callKey: String?
    var kind: MeetingKindKey?
    var serviceName: String
    var title: String
    var calendarEventID: String?
    var plan: MeetingStartPlan
    var brief: MeetingBrief?
    var startedAt: Date
}

// MARK: - Live flags (B)

enum MeetingFlagKind: String, Codable, CaseIterable, Sendable {
    case actionItem, decision, question, bookmark

    var symbol: String {
        switch self {
        case .actionItem: "checkmark.circle"
        case .decision: "seal"
        case .question: "questionmark.bubble"
        case .bookmark: "bookmark.fill"
        }
    }

    var label: String {
        switch self {
        case .actionItem: "Action"
        case .decision: "Decision"
        case .question: "Question"
        case .bookmark: "Moment"
        }
    }

    /// Status color only; accents come from SparkVTheme.
    var tint: Color {
        switch self {
        case .actionItem: SparkVTheme.success
        case .decision: SparkVTheme.accent
        case .question: SparkVTheme.warning
        case .bookmark: SparkVTheme.text
        }
    }
}

enum MeetingFlagOrigin: String, Codable, Sendable {
    /// Phrase rules on final segments (instant, on-device).
    case rule
    /// The on-device model confirmed or rewrote it.
    case model
    /// The user pressed Bookmark or flagged a line by hand.
    case user
    /// MeetingAssistant's existing question detection (liveAnswer).
    case assistant
}

struct MeetingFlag: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: MeetingFlagKind
    /// The cleaned statement ("Send the pricing deck by Friday").
    var text: String
    /// "Koushik", "Priya", "Team"; nil when unknown.
    var owner: String?
    var due: String?
    var isMine: Bool
    /// Seconds since recording started.
    var at: TimeInterval
    /// Transcript segment the flag came from, if any.
    var segmentID: UUID?
    var speaker: MeetingSpeaker?
    var origin: MeetingFlagOrigin
    /// The user dismissed it ("not an action item").
    var isDismissed: Bool = false
    /// User-typed note on a bookmark.
    var note: String?
}

// MARK: - Talk time (B live, C after)

struct MeetingTalkStats: Codable, Equatable, Sendable {
    var meSeconds: TimeInterval
    var othersSeconds: TimeInterval
    /// Longest stretch the user talked without others speaking.
    var longestMonologue: TimeInterval
    /// The user's current unbroken stretch (0 when others spoke last).
    var currentMonologue: TimeInterval
    /// Stretches over the monologue threshold.
    var monologueCount: Int
    /// Number of times the speaker changed.
    var turns: Int

    static let zero = MeetingTalkStats(meSeconds: 0, othersSeconds: 0, longestMonologue: 0,
                                       currentMonologue: 0, monologueCount: 0, turns: 0)

    var total: TimeInterval { meSeconds + othersSeconds }
    /// 0...1, nil before anyone spoke.
    var myShare: Double? { total > 0 ? meSeconds / total : nil }
}

enum MeetingTalkTime {
    /// A pause shorter than this between two of my segments keeps the same
    /// stretch going.
    static let joinGap: TimeInterval = 2.5
    /// Others' speech shorter than this ("mm-hm") doesn't break my stretch.
    static let backchannel: TimeInterval = 1.5

    /// Talk-time from a transcript (volatile segments count too, so the
    /// live meter moves). Overlapping speech counts for both sides.
    static func compute(_ segments: [TranscriptSegment], monologueThreshold: TimeInterval) -> MeetingTalkStats {
        var stats = MeetingTalkStats.zero
        let ordered = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var streakStart: TimeInterval?
        var streakEnd: TimeInterval = 0
        var lastSpeaker: MeetingSpeaker?

        func closeStreak() {
            guard let s = streakStart else { return }
            let length = streakEnd - s
            stats.longestMonologue = max(stats.longestMonologue, length)
            if length >= monologueThreshold { stats.monologueCount += 1 }
            streakStart = nil
        }

        for seg in ordered {
            let length = seg.end - seg.start
            switch seg.speaker {
            case .me:
                stats.meSeconds += length
                if streakStart != nil, seg.start - streakEnd <= joinGap {
                    streakEnd = max(streakEnd, seg.end)
                } else {
                    closeStreak()
                    streakStart = seg.start
                    streakEnd = seg.end
                }
            case .others:
                stats.othersSeconds += length
                if length >= backchannel { closeStreak() }
            }
            if let last = lastSpeaker, last != seg.speaker, length >= backchannel { stats.turns += 1 }
            if length >= backchannel || lastSpeaker == nil { lastSpeaker = seg.speaker }
        }
        if let s = streakStart {
            stats.currentMonologue = streakEnd - s
            stats.longestMonologue = max(stats.longestMonologue, stats.currentMonologue)
            if stats.currentMonologue >= monologueThreshold { stats.monologueCount += 1 }
        }
        return stats
    }
}

// MARK: - Wrap-up (C)

/// A follow-up email SparkV drafts. It is only ever opened as a draft in
/// the user's mail app (mailto) or copied; SparkV never sends it.
struct MeetingFollowUpDraft: Equatable, Sendable {
    var to: [String]
    var subject: String
    var body: String

    /// mailto: links longer than this are unreliable: copy instead.
    static let mailtoLimit = 7000

    /// nil when there is nothing to open or the body is too long for mailto.
    var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "subject", value: subject),
                                 URLQueryItem(name: "body", value: body)]
        guard let url = components.url, url.absoluteString.count <= Self.mailtoLimit else { return nil }
        return url
    }

    /// Plain text for the clipboard ("Subject: ..." first).
    var plainText: String { "Subject: \(subject)\n\n\(body)" }
}

/// One action item offered as a Reminder; added only on approval.
struct MeetingReminderProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    var actionItemID: UUID?
    var title: String
    /// Parsed from the spoken due ("Friday" -> next Friday 9:00), if any.
    var dueDate: Date?
    var dueText: String?
    var isSelected: Bool
    /// Set after the Reminder was created (EKReminder.calendarItemIdentifier).
    var reminderID: String?
}

/// What (C) has done for a meeting, so the card never offers twice.
struct MeetingWrapUpState: Codable, Equatable, Sendable {
    var draftOpenedAt: Date?
    var draftCopiedAt: Date?
    /// ActionItem ids already added to Reminders.
    var remindedTaskIDs: [UUID] = []
    var filedSpaceID: UUID?
    var filedItemID: UUID?
    var dismissedAt: Date?
}

// MARK: - Sidecar (flags, stats, wrap-up state per meeting)

/// MeetingIntel's own record next to a MeetingRecord (MeetingRecord itself
/// is owned by MeetingAssistant and isn't changed). One JSON file per
/// meeting in ~/Library/Application Support/SparkV/MeetingIntel/.
struct MeetingIntelSidecar: Codable, Equatable, Sendable {
    let meetingID: UUID
    var serviceName: String?
    var kind: MeetingKindKey?
    var plan: MeetingStartPlan?
    var flags: [MeetingFlag]
    var talk: MeetingTalkStats?
    var wrapUp: MeetingWrapUpState
    var updatedAt: Date

    init(meetingID: UUID) {
        self.meetingID = meetingID
        serviceName = nil
        kind = nil
        plan = nil
        flags = []
        talk = nil
        wrapUp = MeetingWrapUpState()
        updatedAt = Date()
    }

    var visibleFlags: [MeetingFlag] { flags.filter { !$0.isDismissed }.sorted { $0.at < $1.at } }
}

actor MeetingIntelSidecarStore {
    static let shared = MeetingIntelSidecarStore()

    nonisolated let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/MeetingIntel", isDirectory: true)
    }

    nonisolated func fileURL(for meetingID: UUID) -> URL {
        directory.appendingPathComponent("\(meetingID.uuidString).json")
    }

    func load(_ meetingID: UUID) -> MeetingIntelSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL(for: meetingID)),
              let sidecar = try? decoder.decode(MeetingIntelSidecar.self, from: data) else {
            return MeetingIntelSidecar(meetingID: meetingID)
        }
        return sidecar
    }

    func save(_ sidecar: MeetingIntelSidecar) {
        var copy = sidecar
        copy.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(copy).write(to: fileURL(for: sidecar.meetingID), options: .atomic)
        } catch {
            AppLog.log("MeetingIntel: sidecar save failed: \(error.localizedDescription)")
        }
    }

    /// Loads, applies `change`, saves, and returns the result.
    @discardableResult
    func update(_ meetingID: UUID, _ change: @Sendable (inout MeetingIntelSidecar) -> Void) -> MeetingIntelSidecar {
        var sidecar = load(meetingID)
        change(&sidecar)
        save(sidecar)
        return sidecar
    }

    /// Call when the meeting itself is deleted.
    func remove(_ meetingID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: meetingID))
    }
}

// MARK: - Seams between the parts

/// (B) as (A)'s root sees it. Implemented by `LiveMeetingAssist`.
@MainActor
protocol MeetingLiveAssisting: AnyObject {
    /// Starts flagging, the meter and (per plan) the caption band.
    func begin(_ session: MeetingIntelSession)
    /// Plan changed mid-call (captions on/off, translate on/off).
    func update(plan: MeetingStartPlan)
    /// Bookmark this moment (button, hotkey, menu).
    func bookmarkNow(note: String?)
    /// Stops everything and returns what was gathered (also saved to the sidecar).
    func end() async -> MeetingIntelSidecar?
}

/// (C) as (A)'s root sees it. Implemented by `MeetingWrapUpController`.
@MainActor
protocol MeetingWrappingUp: AnyObject {
    /// Shows the wrap-up card once the minutes for `meetingID` exist (or
    /// right away with what there is when `keepNotes` was off).
    func present(meetingID: UUID, session: MeetingIntelSession?, sidecar: MeetingIntelSidecar?)
    /// Opens the full wrap-up window for any saved meeting (library).
    func openWindow(meetingID: UUID)
}

enum MeetingRemindersAccess: Equatable, Sendable {
    case granted, denied, notDetermined, unavailable
}

/// Reminders permission as (C) sees it. The app wires this to
/// PermissionCenter (see INTEGRATION.md); (C) never calls EventKit's
/// request API itself.
@MainActor
protocol MeetingRemindersGate: AnyObject {
    func status() -> MeetingRemindersAccess
    /// Asks through PermissionCenter's queue; true when granted.
    func request(from feature: String) async -> Bool
}

// MARK: - Shared small views

/// The privacy line every MeetingIntel surface shows while capturing: a red
/// dot (SparkVTheme.recording, red in both looks) and "On this Mac".
struct MeetingIntelLiveBadge: View {
    var text: String = "Recording · on this Mac"
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            SparkVStatusDot(kind: .recording, color: SparkVTheme.recording, size: compact ? 6 : 7, label: "")
            if !compact {
                Text(text)
                    .font(SparkVTheme.caption(10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// The consent line shown whenever recording starts (by click or rule).
enum MeetingIntelConsent {
    static let reminder = "Let everyone know you're taking notes."
    static let detail = "Audio stays on this Mac and is transcribed on device."
}

/// Eyebrow label in both looks ("— BRIEF" in SparkV Red).
struct MeetingIntelEyebrow: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(SparkVTheme.eyebrowDash)
                .frame(width: 8, height: 1.5)
            Text(text.uppercased())
                .font(SparkVTheme.eyebrow())
                .tracking(1.2)
                .foregroundStyle(SparkVTheme.textTertiary)
        }
    }
}

/// Two-segment bar: my share vs everyone else, used live (B) and after (C).
struct MeetingTalkShareBar: View {
    let stats: MeetingTalkStats
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let share = stats.myShare ?? 0
            HStack(spacing: 1.5) {
                Capsule().fill(SparkVTheme.accent)
                    .frame(width: max(0, (geo.size.width - 1.5) * share))
                Capsule().fill(SparkVTheme.textTertiary)
            }
        }
        .frame(height: height)
        .opacity(stats.myShare == nil ? 0.35 : 1)
        .accessibilityLabel("You spoke \(Int(((stats.myShare ?? 0) * 100).rounded())) percent of the time")
    }
}
