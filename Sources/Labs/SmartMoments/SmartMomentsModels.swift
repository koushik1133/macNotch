import Foundation
import SwiftUI

// Smart Moments shared contracts. See DESIGN.md.
//
// A `MomentTrigger` (what happened) maps to a `MomentID` (which moment). The
// engine builds a `MomentOffer` from the moment's `MomentSettings` (the actions
// that are enabled) and the `SmartMomentsHooks` (the actions available here).
// It then shows the offer as a band, or runs it when the moment is set to
// `.automatic`. Consent actions are never run automatically.

// MARK: - Moment

enum MomentID: String, CaseIterable, Codable, Sendable, Identifiable {
    case meetingSoon
    case meetingStarted
    case meetingEnded
    case screenSharing
    case lowBatteryRecording
    case downloadFinished
    case deepWork
    case lateNight
    case presentation
    case copiedSmart
    case screenshotTaken
    case displayConnected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetingSoon: "Meeting in a few minutes"
        case .meetingStarted: "Meeting started"
        case .meetingEnded: "Meeting ended"
        case .screenSharing: "Screen sharing"
        case .lowBatteryRecording: "Low battery while recording"
        case .downloadFinished: "Download finished"
        case .deepWork: "Deep work"
        case .lateNight: "Late night"
        case .presentation: "Presenting"
        case .copiedSmart: "Copied a link or code"
        case .screenshotTaken: "Screenshot taken"
        case .displayConnected: "External display connected"
        }
    }

    /// One line for Settings: when the moment shows up.
    var triggerDescription: String {
        switch self {
        case .meetingSoon: "A calendar meeting with a link is about to start."
        case .meetingStarted: "A Meet, Zoom, Teams, FaceTime or Slack call starts."
        case .meetingEnded: "The call ends. Puts back what Meeting started changed."
        case .screenSharing: "Another app starts sharing or recording your screen."
        case .lowBatteryRecording: "The battery runs low while SparkV is recording."
        case .downloadFinished: "A file finishes downloading."
        case .deepWork: "You've worked in one app for a long stretch."
        case .lateNight: "You're still working late at night."
        case .presentation: "Keynote or PowerPoint starts playing, or an app goes fullscreen on a projector."
        case .copiedSmart: "You copy a link or a code snippet."
        case .screenshotTaken: "You take a screenshot."
        case .displayConnected: "An external display or projector connects."
        }
    }

    var symbol: String {
        switch self {
        case .meetingSoon: "calendar.badge.clock"
        case .meetingStarted: "video.fill"
        case .meetingEnded: "checkmark.circle"
        case .screenSharing: "rectangle.on.rectangle"
        case .lowBatteryRecording: "battery.25percent"
        case .downloadFinished: "arrow.down.circle"
        case .deepWork: "brain.head.profile"
        case .lateNight: "moon.stars"
        case .presentation: "play.rectangle.on.rectangle"
        case .copiedSmart: "doc.on.clipboard"
        case .screenshotTaken: "camera.viewfinder"
        case .displayConnected: "display"
        }
    }

    /// Read in `body` so it follows the look in effect.
    @MainActor var tint: Color {
        switch self {
        case .lowBatteryRecording: SparkVTheme.warning
        case .meetingEnded: SparkVTheme.success
        case .lateNight: SparkVTheme.choose(apple: Color.indigo, sparkv: SparkVTheme.textSecondary)
        default: SparkVTheme.accent
        }
    }

    /// Higher wins the band; lower waits in the queue (DESIGN.md rule 1).
    var priority: Int {
        switch self {
        case .lowBatteryRecording: 100
        case .meetingSoon: 90
        case .meetingStarted: 80
        case .screenSharing: 70
        case .meetingEnded: 60
        case .presentation: 50
        case .displayConnected: 40
        case .downloadFinished, .screenshotTaken: 30
        case .deepWork: 20
        case .lateNight, .copiedSmart: 10
        }
    }

    /// Same `dedupeKey` isn't offered again within this time.
    var defaultCooldown: TimeInterval {
        switch self {
        case .meetingSoon, .meetingStarted, .meetingEnded: 0 // keyed per meeting/call
        case .screenSharing, .presentation: 60
        case .lowBatteryRecording: 0 // fires at the threshold and once more at 5 %
        case .downloadFinished, .screenshotTaken, .copiedSmart: 0 // keyed per file/copy
        case .deepWork: 24 * 3600 // once per app per day
        case .lateNight: 20 * 3600 // once per night
        case .displayConnected: 30 * 60
        }
    }

    /// How long an unanswered offer stays (nil = until its end trigger).
    var expiresAfter: TimeInterval? {
        switch self {
        case .meetingSoon: 6 * 60
        case .meetingStarted: 3 * 60
        case .meetingEnded: 2 * 60
        case .screenSharing, .presentation: nil
        case .lowBatteryRecording: nil
        case .copiedSmart: 8
        case .screenshotTaken, .downloadFinished: 20
        case .displayConnected: 15
        case .deepWork, .lateNight: 60
        }
    }

    /// Shown while another app shares the screen (DESIGN.md rule 8).
    var allowedWhileScreenSharing: Bool {
        switch self {
        case .screenSharing, .lowBatteryRecording, .meetingEnded: true
        default: false
        }
    }

    /// The actions this moment offers, in band order.
    var actions: [MomentAction] {
        switch self {
        case .meetingSoon: [.joinMeeting, .openMirror, .checkDevices, .showAgendaBrief]
        case .meetingStarted: [.recordNotes, .liveCaptions, .translateCaptions, .pauseMusic, .doNotDisturbOn, .hideNotificationPreviews, .mirrorOff]
        case .meetingEnded: [.notesWrapUp, .resumeMusic, .doNotDisturbOff, .showNotificationPreviews]
        case .screenSharing: [.hideNotificationPreviews, .hideClipboardBand, .pauseMusic, .doNotDisturbOn]
        case .lowBatteryRecording: [.saveRecordingNow, .showBatteryTimeLeft, .openBatterySettings]
        case .downloadFinished: [.sortDownload, .openFile, .revealInFinder, .addToTray, .sendToSpace]
        case .deepWork: [.startFocusSession, .doNotDisturbOn, .pauseMusic]
        case .lateNight: [.nightMode, .lowerBrightness, .windDownTimer]
        case .presentation: [.presentationMode, .quietNotchActivities, .talkTimer]
        case .copiedSmart: [.openLink, .cleanLink, .copyAsMarkdownLink, .formatCode, .sendToSpace]
        case .screenshotTaken: [.copyImage, .annotateImage, .sendToSpace, .addToTray, .extractText]
        case .displayConnected: [.hideNotificationPreviews, .presentationMode, .moveIslandToDisplay]
        }
    }

    /// Actions on by default (the rest start off). DESIGN.md ☑ / ☐.
    var defaultEnabledActions: Set<MomentAction> {
        switch self {
        case .meetingStarted: Set(actions).subtracting([.translateCaptions])
        case .screenSharing: Set(actions).subtracting([.doNotDisturbOn])
        case .lowBatteryRecording: [.saveRecordingNow, .showBatteryTimeLeft]
        case .downloadFinished: [.sortDownload, .openFile, .revealInFinder]
        case .deepWork: [.startFocusSession, .doNotDisturbOn]
        case .lateNight: [.nightMode]
        case .presentation: [.presentationMode, .quietNotchActivities]
        case .copiedSmart: [.openLink, .cleanLink, .formatCode]
        case .screenshotTaken: [.copyImage, .annotateImage, .sendToSpace]
        case .displayConnected: [.hideNotificationPreviews]
        default: Set(actions)
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .lateNight, .copiedSmart, .displayConnected: false
        default: true
        }
    }

    var defaultMode: MomentMode {
        switch self {
        case .meetingEnded, .screenSharing, .presentation: .automatic
        default: .ask
        }
    }

    /// The moment that puts back what this one changed, if any.
    var endMoment: MomentID? {
        switch self {
        case .meetingStarted: .meetingEnded
        default: nil
        }
    }
}

/// Ask first (default) or Do automatically.
enum MomentMode: String, Codable, Sendable, CaseIterable {
    case ask
    case automatic

    var title: String {
        switch self {
        case .ask: "Ask first"
        case .automatic: "Do automatically"
        }
    }
}

// MARK: - Trigger

/// What a detector reported. Built in wiring from each controller's events.
enum MomentTrigger: Sendable, Equatable {
    case meetingSoon(CalendarMeeting, minutesUntilStart: Int)
    case meetingStarted(DetectedCall)
    case meetingEnded(DetectedCall, recordedMeetingID: UUID?)
    case screenSharingStarted(appBundleID: String?, appName: String?)
    case screenSharingEnded
    case lowBatteryWhileRecording(level: Int, minutesLeft: Int?, recording: MomentRecordingKind)
    case downloadFinished(itemID: UUID, url: URL, suggestedFolder: String?)
    case deepWork(appBundleID: String, appName: String, minutes: Int)
    case lateNight(hour: Int)
    case presentationStarted(appBundleID: String?, appName: String, isSlideshow: Bool)
    case presentationEnded
    case copied(MomentCopiedKind, preview: String, itemID: UUID?)
    case screenshotTaken(url: URL)
    case displayConnected(displayID: UInt32, name: String)

    var moment: MomentID {
        switch self {
        case .meetingSoon: .meetingSoon
        case .meetingStarted: .meetingStarted
        case .meetingEnded: .meetingEnded
        case .screenSharingStarted, .screenSharingEnded: .screenSharing
        case .lowBatteryWhileRecording: .lowBatteryRecording
        case .downloadFinished: .downloadFinished
        case .deepWork: .deepWork
        case .lateNight: .lateNight
        case .presentationStarted, .presentationEnded: .presentation
        case .copied: .copiedSmart
        case .screenshotTaken: .screenshotTaken
        case .displayConnected: .displayConnected
        }
    }

    /// Ends a moment that is in effect: dismisses its band and reverses its
    /// ledger entries instead of making an offer.
    var isEnd: Bool {
        switch self {
        case .screenSharingEnded, .presentationEnded: true
        default: false
        }
    }

    /// The same key is offered once per `MomentID.defaultCooldown`.
    var dedupeKey: String {
        switch self {
        case .meetingSoon(let m, _): "soon:\(m.id)"
        case .meetingStarted(let c): "call:\(c.key)"
        case .meetingEnded(let c, _): "ended:\(c.key)"
        case .screenSharingStarted(let id, _): "share:\(id ?? "?")"
        case .screenSharingEnded: "share:end"
        case .lowBatteryWhileRecording(let level, _, let kind): "battery:\(kind.rawValue):\(level <= 5 ? "critical" : "low")"
        case .downloadFinished(let id, _, _): "download:\(id.uuidString)"
        case .deepWork(let id, _, _): "deep:\(id)"
        case .lateNight: "night"
        case .presentationStarted(let id, _, _): "present:\(id ?? "fullscreen")"
        case .presentationEnded: "present:end"
        case .copied(_, _, let id): "copy:\(id?.uuidString ?? UUID().uuidString)"
        case .screenshotTaken(let url): "shot:\(url.path)"
        case .displayConnected(let id, _): "display:\(id)"
        }
    }

    /// Band headline, e.g. "Standup in 2 min".
    var headline: String {
        switch self {
        case .meetingSoon(let m, let mins): mins <= 0 ? "\(m.title) is starting" : "\(m.title) in \(mins) min"
        case .meetingStarted(let c): "On a \(c.serviceName) call"
        case .meetingEnded: "Call ended"
        case .screenSharingStarted: "Sharing your screen"
        case .screenSharingEnded: "Stopped sharing"
        case .lowBatteryWhileRecording(let level, _, _): "Battery \(level) %"
        case .downloadFinished(_, let url, _): url.lastPathComponent
        case .deepWork(_, let app, let mins): "\(mins) min in \(app)"
        case .lateNight: "It's late"
        case .presentationStarted: "Presenting"
        case .presentationEnded: "Presentation ended"
        case .copied(let kind, _, _): kind == .link ? "Link copied" : "Code copied"
        case .screenshotTaken: "Screenshot taken"
        case .displayConnected(_, let name): "Connected to \(name)"
        }
    }

    /// Band context line, e.g. "Google Meet" or "Sort into Invoices?".
    var detail: String? {
        switch self {
        case .meetingSoon(let m, _): m.link?.provider.displayName
        case .meetingStarted(let c): c.hasGenericTitle ? nil : c.title
        case .meetingEnded(let c, _): c.hasGenericTitle ? c.serviceName : c.title
        case .screenSharingStarted(_, let name): name
        case .lowBatteryWhileRecording(_, let mins, let kind):
            "\(kind.title) still going" + (mins.map { " · about \($0) min left" } ?? "")
        case .downloadFinished(_, _, let folder): folder.map { "Sort into \($0)?" }
        case .deepWork: "Protect this flow?"
        case .lateNight: "Switch to Night mode?"
        case .presentationStarted(_, let app, _): app
        case .copied(_, let preview, _): preview
        default: nil
        }
    }
}

enum MomentRecordingKind: String, Sendable, Codable {
    case meetingNotes, screenRecording

    var title: String {
        switch self {
        case .meetingNotes: "Meeting recording"
        case .screenRecording: "Screen recording"
        }
    }
}

enum MomentCopiedKind: String, Sendable, Codable {
    case link, code
}

// MARK: - Action

enum MomentAction: String, CaseIterable, Codable, Sendable, Identifiable {
    // Before a meeting
    case joinMeeting, openMirror, checkDevices, showAgendaBrief
    // During a meeting
    case recordNotes, liveCaptions, translateCaptions, mirrorOff
    // After a meeting
    case notesWrapUp
    // System state (reversible pairs)
    case pauseMusic, resumeMusic
    case doNotDisturbOn, doNotDisturbOff
    case hideNotificationPreviews, showNotificationPreviews
    case hideClipboardBand, showClipboardBand
    // Devices and power
    case saveRecordingNow, showBatteryTimeLeft, openBatterySettings
    // Files
    case sortDownload, openFile, revealInFinder, addToTray, sendToSpace
    // Focus and modes
    case startFocusSession, nightMode, lowerBrightness, windDownTimer
    case presentationMode, quietNotchActivities, talkTimer, moveIslandToDisplay
    // Clipboard
    case openLink, cleanLink, copyAsMarkdownLink, formatCode
    // Screenshots
    case copyImage, annotateImage, extractText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .joinMeeting: "Join"
        case .openMirror: "Check yourself"
        case .checkDevices: "Mic, camera & sound"
        case .showAgendaBrief: "Agenda brief"
        case .recordNotes: "Record notes"
        case .liveCaptions: "Live captions"
        case .translateCaptions: "Translate captions"
        case .mirrorOff: "Turn mirror off"
        case .notesWrapUp: "Notes wrap-up"
        case .pauseMusic: "Pause music"
        case .resumeMusic: "Resume music"
        case .doNotDisturbOn: "Do Not Disturb"
        case .doNotDisturbOff: "Do Not Disturb off"
        case .hideNotificationPreviews: "Hide notification previews"
        case .showNotificationPreviews: "Show notification previews"
        case .hideClipboardBand: "Hide clipboard band"
        case .showClipboardBand: "Show clipboard band"
        case .saveRecordingNow: "Save recording now"
        case .showBatteryTimeLeft: "Time left"
        case .openBatterySettings: "Battery settings"
        case .sortDownload: "Sort"
        case .openFile: "Open"
        case .revealInFinder: "Show in Finder"
        case .addToTray: "Add to Tray"
        case .sendToSpace: "Send to Space"
        case .startFocusSession: "Start Focus"
        case .nightMode: "Night mode"
        case .lowerBrightness: "Lower brightness"
        case .windDownTimer: "15-min wind-down"
        case .presentationMode: "Presentation mode"
        case .quietNotchActivities: "Quiet the notch"
        case .talkTimer: "Talk timer"
        case .moveIslandToDisplay: "Move island here"
        case .openLink: "Open link"
        case .cleanLink: "Clean link"
        case .copyAsMarkdownLink: "Copy as Markdown"
        case .formatCode: "Format code"
        case .copyImage: "Copy"
        case .annotateImage: "Annotate"
        case .extractText: "Copy text"
        }
    }

    var symbol: String {
        switch self {
        case .joinMeeting: "video.fill"
        case .openMirror: "person.crop.square"
        case .checkDevices: "mic.and.signal.meter"
        case .showAgendaBrief: "list.bullet.rectangle"
        case .recordNotes: "record.circle"
        case .liveCaptions: "captions.bubble"
        case .translateCaptions: "translate"
        case .mirrorOff: "video.slash"
        case .notesWrapUp: "doc.text"
        case .pauseMusic: "pause.fill"
        case .resumeMusic: "play.fill"
        case .doNotDisturbOn: "moon.fill"
        case .doNotDisturbOff: "moon"
        case .hideNotificationPreviews: "bell.slash"
        case .showNotificationPreviews: "bell"
        case .hideClipboardBand: "eye.slash"
        case .showClipboardBand: "eye"
        case .saveRecordingNow: "square.and.arrow.down"
        case .showBatteryTimeLeft: "clock"
        case .openBatterySettings: "gearshape"
        case .sortDownload: "folder.badge.plus"
        case .openFile: "arrow.up.forward.app"
        case .revealInFinder: "magnifyingglass"
        case .addToTray: "tray.and.arrow.down"
        case .sendToSpace: "square.stack.3d.up"
        case .startFocusSession: "scope"
        case .nightMode: "moon.stars.fill"
        case .lowerBrightness: "sun.min"
        case .windDownTimer: "timer"
        case .presentationMode: "play.rectangle"
        case .quietNotchActivities: "speaker.slash"
        case .talkTimer: "stopwatch"
        case .moveIslandToDisplay: "rectangle.portrait.and.arrow.right"
        case .openLink: "safari"
        case .cleanLink: "wand.and.stars"
        case .copyAsMarkdownLink: "link"
        case .formatCode: "chevron.left.forwardslash.chevron.right"
        case .copyImage: "doc.on.doc"
        case .annotateImage: "pencil.tip.crop.circle"
        case .extractText: "text.viewfinder"
        }
    }

    /// Records audio, shows captions of others' speech, or starts capture.
    /// Never run automatically; the band says "Let participants know".
    var needsConsent: Bool {
        switch self {
        case .recordNotes, .liveCaptions, .translateCaptions: true
        default: false
        }
    }

    /// Never run automatically even outside consent (opens a call, moves a
    /// file to a Space, or stops a recording).
    var alwaysAsks: Bool {
        if needsConsent { return true }
        switch self {
        case .joinMeeting, .saveRecordingNow, .sendToSpace, .moveIslandToDisplay: return true
        default: return false
        }
    }

    /// Can run on its own in "Do automatically". False for consent and
    /// always-ask actions and for chips that open a window, a file, a link
    /// or the camera (`MomentEngineRules.chipOnlyInAuto`): those stay chips.
    /// `SmartMomentsHooks.autoEligible` can narrow it per trigger.
    var isAutoEligible: Bool {
        !alwaysAsks && !MomentEngineRules.chipOnlyInAuto.contains(self)
    }

    /// The action that puts this one back. The engine records it in the
    /// `MomentRestoreLedger` when the action changes state.
    var reversal: MomentAction? {
        switch self {
        case .pauseMusic: .resumeMusic
        case .doNotDisturbOn: .doNotDisturbOff
        case .hideNotificationPreviews: .showNotificationPreviews
        case .hideClipboardBand: .showClipboardBand
        case .presentationMode, .nightMode: nil // ModeEngine restores on deactivate
        default: nil
        }
    }

    /// Checked through PermissionCenter before running (DESIGN.md rule 6).
    var requiredPermissions: [PermissionCenter.Permission] {
        switch self {
        case .openMirror: [.camera]
        case .recordNotes: [.microphone]
        case .liveCaptions, .translateCaptions: [.microphone, .speech]
        case .showAgendaBrief: [.calendars]
        case .sortDownload: [.downloadsFolder]
        default: []
        }
    }
}

// MARK: - Settings (persisted)

/// One moment's settings. Missing action keys fall back to the defaults, so
/// new actions appear with their default state after an update.
struct MomentSettings: Codable, Sendable, Equatable {
    var isEnabled: Bool
    var mode: MomentMode
    /// Explicit per-action choices; absent = `MomentID.defaultEnabledActions`.
    var actionOverrides: [MomentAction: Bool]
    /// The moment stays silent until then (Snooze = end of today).
    var snoozedUntil: Date?
    /// Dismissals in a row; at 3 the band asks to turn the moment off.
    var dismissStreak: Int

    init(isEnabled: Bool, mode: MomentMode, actionOverrides: [MomentAction: Bool] = [:], snoozedUntil: Date? = nil, dismissStreak: Int = 0) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.actionOverrides = actionOverrides
        self.snoozedUntil = snoozedUntil
        self.dismissStreak = dismissStreak
    }

    static func defaults(for moment: MomentID) -> MomentSettings {
        MomentSettings(isEnabled: moment.defaultEnabled, mode: moment.defaultMode)
    }

    func isActionEnabled(_ action: MomentAction, in moment: MomentID) -> Bool {
        actionOverrides[action] ?? moment.defaultEnabledActions.contains(action)
    }

    func enabledActions(for moment: MomentID) -> [MomentAction] {
        moment.actions.filter { isActionEnabled($0, in: moment) }
    }

    func isSnoozed(at now: Date) -> Bool {
        if let until = snoozedUntil { return until > now }
        return false
    }

    // Codable with string keys (a dictionary keyed by an enum encodes as an array).
    private enum CodingKeys: String, CodingKey { case isEnabled, mode, actions, snoozedUntil, dismissStreak }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        mode = (try? c.decode(MomentMode.self, forKey: .mode)) ?? .ask
        let raw = (try? c.decode([String: Bool].self, forKey: .actions)) ?? [:]
        var overrides: [MomentAction: Bool] = [:]
        for (key, value) in raw {
            if let action = MomentAction(rawValue: key) { overrides[action] = value }
        }
        actionOverrides = overrides
        snoozedUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        dismissStreak = (try? c.decode(Int.self, forKey: .dismissStreak)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(mode, forKey: .mode)
        try c.encode(Dictionary(uniqueKeysWithValues: actionOverrides.map { ($0.key.rawValue, $0.value) }), forKey: .actions)
        try c.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try c.encode(dismissStreak, forKey: .dismissStreak)
    }
}

/// Moment tunables shown under their moment in Settings.
struct MomentTunables: Codable, Sendable, Equatable {
    var meetingLeadMinutes: Int = 2 // 1...10
    var deepWorkMinutes: Int = 45 // 20...120
    var lateNightHour: Int = 23 // 20...3 (wraps past midnight)
    var lowBatteryPercent: Int = 15 // 5...30
    /// ModeEngine mode for Night mode; nil = the built-in wind-down preset.
    var nightModeID: UUID?
    /// ModeEngine mode for Presentation mode; nil = DND + hide previews + pause music.
    var presentationModeID: UUID?
    /// Bundle IDs that never count as deep work.
    var deepWorkExcludedBundleIDs: [String] = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.apple.mail", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
    ]

    static let `default` = MomentTunables()
}

/// Everything Smart Moments persists, under one UserDefaults key.
struct SmartMomentsSettingsSnapshot: Codable, Sendable, Equatable {
    var isEnabled: Bool = true
    var moments: [String: MomentSettings] = [:]
    var tunables: MomentTunables = .default

    func settings(for moment: MomentID) -> MomentSettings {
        moments[moment.rawValue] ?? .defaults(for: moment)
    }
}

/// Observable settings for the engine and the Settings pane. Writes
/// through to UserDefaults on every change.
@MainActor
final class SmartMomentsSettings: ObservableObject {
    nonisolated static let defaultsKey = "SmartMoments.settings.v1"

    @Published private(set) var snapshot: SmartMomentsSettingsSnapshot

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(SmartMomentsSettingsSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = SmartMomentsSettingsSnapshot()
        }
    }

    var isEnabled: Bool {
        get { snapshot.isEnabled }
        set { mutate { $0.isEnabled = newValue } }
    }

    var tunables: MomentTunables {
        get { snapshot.tunables }
        set { mutate { $0.tunables = newValue } }
    }

    func settings(for moment: MomentID) -> MomentSettings { snapshot.settings(for: moment) }

    func update(_ moment: MomentID, _ change: (inout MomentSettings) -> Void) {
        mutate { snap in
            var s = snap.settings(for: moment)
            change(&s)
            snap.moments[moment.rawValue] = s
        }
    }

    func setEnabled(_ on: Bool, for moment: MomentID) { update(moment) { $0.isEnabled = on; $0.dismissStreak = 0 } }
    func setMode(_ mode: MomentMode, for moment: MomentID) { update(moment) { $0.mode = mode } }
    func setAction(_ action: MomentAction, enabled: Bool, for moment: MomentID) { update(moment) { $0.actionOverrides[action] = enabled } }
    func snooze(_ moment: MomentID, until date: Date) { update(moment) { $0.snoozedUntil = date } }

    /// Settings › "Reset Smart Moments".
    func resetToDefaults() { mutate { $0 = SmartMomentsSettingsSnapshot() } }

    /// SwiftUI binding helpers for the Settings pane.
    func binding(enabled moment: MomentID) -> Binding<Bool> {
        Binding(get: { self.settings(for: moment).isEnabled }, set: { self.setEnabled($0, for: moment) })
    }

    func binding(mode moment: MomentID) -> Binding<MomentMode> {
        Binding(get: { self.settings(for: moment).mode }, set: { self.setMode($0, for: moment) })
    }

    func binding(action: MomentAction, in moment: MomentID) -> Binding<Bool> {
        Binding(
            get: { self.settings(for: moment).isActionEnabled(action, in: moment) },
            set: { self.setAction(action, enabled: $0, for: moment) }
        )
    }

    private func mutate(_ change: (inout SmartMomentsSettingsSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        snapshot = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Offer and results

/// What the band shows (or what auto mode ran).
struct MomentOffer: Identifiable, Sendable, Equatable {
    let id: UUID
    let trigger: MomentTrigger
    var moment: MomentID { trigger.moment }
    /// Enabled and available actions, in band order.
    var actions: [MomentAction]
    /// Chips selected for "Do it" (starts as `actions`).
    var selected: Set<MomentAction>
    /// Actions that can't run yet because a permission is missing.
    var blocked: [MomentAction: PermissionCenter.Permission]
    let createdAt: Date
    let expiresAt: Date?
    /// Set when auto mode already ran these (the band shows "Done · Undo").
    var autoRan: [MomentAction]
    /// The band adds "Turn off this moment?" (dismissStreak ≥ 3).
    var suggestsTurningOff: Bool

    var headline: String { trigger.headline }
    var detail: String? { trigger.detail }
    /// Consent actions left for the user to tap in auto mode.
    var pendingConsent: [MomentAction] { actions.filter { $0.needsConsent && !autoRan.contains($0) } }
    var showsConsentNote: Bool { actions.contains { $0.needsConsent } }
}

enum MomentActionResult: Sendable, Equatable {
    /// Done; the optional text goes in the "Done" toast.
    case done(String?)
    /// Not applicable now (nothing playing, DND already on): not reversed later.
    case skipped(String)
    case needsPermission(PermissionCenter.Permission)
    case failed(String)

    var changedState: Bool {
        if case .done = self { return true }
        return false
    }
}

/// What a moment changed, so its end trigger reverses only that.
struct MomentRestoreLedger: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let moment: MomentID
        let dedupeKey: String
        let reversal: MomentAction
        let at: Date
    }

    private(set) var entries: [Entry] = []

    mutating func record(_ action: MomentAction, moment: MomentID, key: String, at date: Date) {
        guard let reversal = action.reversal else { return }
        entries.removeAll { $0.reversal == reversal } // one owner per state
        entries.append(Entry(moment: moment, dedupeKey: key, reversal: reversal, at: date))
    }

    /// Removes and returns the reversals owned by `moment`, newest first.
    mutating func takeReversals(for moment: MomentID) -> [MomentAction] {
        let mine = entries.filter { $0.moment == moment }
        entries.removeAll { $0.moment == moment }
        return mine.reversed().map(\.reversal)
    }

    /// The user changed that state by hand: drop it, don't reverse it later.
    mutating func forget(_ reversal: MomentAction) { entries.removeAll { $0.reversal == reversal } }

    func owns(_ reversal: MomentAction) -> Bool { entries.contains { $0.reversal == reversal } }
}

// MARK: - Hooks (set in wiring)

/// Context an action runs with.
struct MomentActionContext: Sendable {
    let trigger: MomentTrigger
    let offerID: UUID
    /// False when auto mode is running it (no windows stolen into focus).
    let userInitiated: Bool
}

/// One closure per building block, set in AppDelegate wiring. A nil hook
/// means the action is unavailable here and its chip is hidden. Each hook
/// returns what happened. Hooks must not hide or quit apps.
@MainActor
struct SmartMomentsHooks {
    typealias Run = @MainActor (MomentActionContext) async -> MomentActionResult

    /// Per-action implementations (keyed by action).
    var actions: [MomentAction: Run] = [:]
    /// Extra availability check (e.g. `notesWrapUp` only if notes exist,
    /// `resumeMusic` only if a source is paused). nil = available.
    var isAvailable: [MomentAction: @MainActor (MomentTrigger) -> Bool] = [:]
    /// Per-trigger auto check, on top of `MomentAction.isAutoEligible`.
    /// False keeps the action as a chip in "Do automatically" instead of
    /// running it (e.g. a download an AI picked a folder for waits for a
    /// tap). nil = `isAutoEligible` decides.
    var autoEligible: [MomentAction: @MainActor (MomentTrigger) -> Bool] = [:]

    // Environment the engine reads (all nil-safe defaults).
    var isScreenSharing: @MainActor () -> Bool = { false }
    var isOnCall: @MainActor () -> Bool = { false }
    var isSparkVCapturing: @MainActor () -> Bool = { false }
    var now: @MainActor () -> Date = { Date() }
    var permissionGranted: @MainActor (PermissionCenter.Permission) -> Bool = { PermissionCenter.shared.isGranted($0) }

    func supports(_ action: MomentAction, for trigger: MomentTrigger) -> Bool {
        guard actions[action] != nil else { return false }
        return isAvailable[action]?(trigger) ?? true
    }
}

/// MeetingIntel's coordinator conforms to this (see INTEGRATION.md). Smart
/// Moments owns the trigger engine and settings; MeetingIntel owns the
/// call-start prompt with notes, captions and brief.
@MainActor
protocol MeetingIntelBridge: AnyObject {
    /// MeetingIntel will show its own prompt for this call. Smart Moments
    /// then shows no second band and hands it the extra chips instead.
    func willPrompt(for trigger: MomentTrigger) -> Bool
    /// MeetingIntel handles these actions itself (e.g. recordNotes,
    /// liveCaptions, translateCaptions, showAgendaBrief, notesWrapUp).
    var handledActions: Set<MomentAction> { get }
    /// Runs one of `handledActions`.
    func perform(_ action: MomentAction, context: MomentActionContext) async -> MomentActionResult
    /// The remaining Smart Moments chips (pause music, DND, previews, mirror
    /// off) to show inside MeetingIntel's prompt. Running one calls `run`.
    func contribute(_ actions: [MomentAction], for trigger: MomentTrigger, run: @escaping @MainActor (MomentAction) -> Void)
    /// False when MeetingIntel's prompt can't show extra chips: Smart
    /// Moments then shows its own band with only the actions MeetingIntel
    /// doesn't handle. Default true.
    var hostsContributedChips: Bool { get }
}

extension MeetingIntelBridge {
    var hostsContributedChips: Bool { true }
}

// MARK: - Engine

/// The Smart Moments engine. `SmartMomentsController` conforms to it; the
/// band, the Settings pane and wiring talk to it through this protocol.
@MainActor
protocol SmartMomentsEngine: AnyObject {
    var settings: SmartMomentsSettings { get }
    var hooks: SmartMomentsHooks { get set }
    var meetingIntel: (any MeetingIntelBridge)? { get set }

    /// The offer in the band, if any.
    var currentOffer: MomentOffer? { get }
    /// Called after `currentOffer` changes (wiring updates ActivityCenter).
    var onOfferChanged: ((MomentOffer?) -> Void)? { get set }
    /// Called with a short "Done: …" text after actions ran (toast band).
    var onDone: ((MomentID, String) -> Void)? { get set }

    /// Detectors report here. The engine applies settings, cooldowns, quiet
    /// conditions and priority, then offers, runs automatically or ends.
    func handle(_ trigger: MomentTrigger)

    /// "Do it": runs the selected actions of the offer.
    func accept(_ offerID: UUID, actions: Set<MomentAction>?) async
    /// Runs a single chip (⌥-click / long-press, or a MeetingIntel chip).
    func run(_ action: MomentAction, offerID: UUID) async -> MomentActionResult
    func toggleSelection(_ action: MomentAction, offerID: UUID)
    /// "Not now".
    func dismiss(_ offerID: UUID)
    /// "Snooze for today".
    func snooze(_ offerID: UUID)
    /// Undo of an auto-run toast: runs the reversals it recorded.
    func undo(_ offerID: UUID) async
    /// Asks PermissionCenter for a blocked chip's permission.
    func requestPermission(for action: MomentAction, offerID: UUID)

    /// The user changed a state by hand (e.g. turned DND off themselves),
    /// so the ledger must not reverse it later.
    func userChanged(_ reversal: MomentAction)
    /// Undo would put something back for this offer (the band shows Undo).
    func canUndo(_ offerID: UUID) -> Bool
}

/// Fire-and-forget conveniences for wiring call sites.
extension SmartMomentsEngine {
    func canUndo(_ offerID: UUID) -> Bool { false }
    func acceptAll(_ offerID: UUID) { Task { await accept(offerID, actions: nil) } }
}
