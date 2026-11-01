import AppKit
import SwiftUI

// Settings › Activities and Settings › Accessibility. Every view here is a
// `Section { … } header: { … }` (or a few of them) for the app shell's
// grouped Form: rows are plain toggles, pickers and labeled content, like
// System Settings. No arguments; they read `.shared` / `.current`.

// MARK: - Building blocks

/// A row's title with one line of explanation under it (the Form's own
/// two-line label style).
struct ActivitySettingsLabel: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A short status line: a glyph in its tone and the text.
struct ActivitySettingsNotice: View {
    enum Tone { case neutral, good, warning }

    let text: String
    var symbol: String = "info.circle"
    var tone: Tone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .neutral: SparkVTheme.textTertiary
        case .good: SparkVTheme.success
        case .warning: SparkVTheme.warning
        }
    }
}

/// Seconds picker (menu style) for a list of choices.
struct ActivitySecondsPicker: View {
    let title: String
    var detail: String? = nil
    let choices: [TimeInterval]
    @Binding var value: TimeInterval

    var body: some View {
        Picker(selection: $value) {
            ForEach(choices, id: \.self) { Text(ActivityTimingSettings.label($0)).tag($0) }
        } label: {
            ActivitySettingsLabel(title: title, detail: detail)
        }
        .pickerStyle(.menu)
    }
}

/// Glyph of a running activity in its own tint.
struct ActivitySymbolBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(SparkVTheme.isApple ? 0.2 : 0.16))
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Live Activities (pane: Activities)

/// What runs in the island right now, which one rests in the wings, how
/// many show at once, music beside the others, and the ⌃⌥A shortcut.
struct LiveActivitiesSettingsSection: View {
    @ObservedObject private var settings = LiveActivitiesSettings.shared
    private let center: ActivityCenter?
    private let controller: LiveActivitiesController?

    init() {
        controller = LiveActivitiesController.current
        center = controller?.activities
    }

    /// For renders.
    init(center: ActivityCenter?) {
        self.center = center
        controller = LiveActivitiesController.current
    }

    var body: some View {
        Section {
            if let center { RunningActivitiesRows(center: center) }
            Picker(selection: $settings.maxVisible) {
                Text("2").tag(2)
                Text("3").tag(3)
            } label: {
                ActivitySettingsLabel(title: "Show at once", detail: "The wings beside the camera fit one activity and one or two small icons.")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $settings.keepsNowPlayingAlongside) {
                ActivitySettingsLabel(title: "Keep music beside other activities",
                                      detail: "Album art stays as a small icon next to a timer or a call.")
            }
            Toggle(isOn: $settings.cycleHotkeyEnabled) {
                ActivitySettingsLabel(title: "\(LiveActivitiesController.cycleShortcut.displayString) shows the next activity",
                                      detail: "Works from any app. With one activity, it peeks.")
            }
            if let controller { LiveActivitiesHotkeyStatus(controller: controller) }
        } header: {
            Text("Live Activities")
        } footer: {
            Text("The most important activity rests beside the notch; the next ones ride along as small icons.")
        }
    }
}

private struct LiveActivitiesHotkeyStatus: View {
    @ObservedObject var controller: LiveActivitiesController

    var body: some View {
        let key = LiveActivitiesController.cycleShortcut.displayString
        if controller.hotkeyPausedForVoiceOver {
            ActivitySettingsNotice(text: "\(key) is VoiceOver’s while it runs (VO-A reads from the cursor), so SparkV leaves it alone. Use the gear menu’s Show in Wings.",
                                   symbol: "speaker.wave.2.bubble.left.fill")
        } else if controller.hotkeyUnavailable {
            ActivitySettingsNotice(text: "Another app uses \(key), so it doesn’t reach SparkV. Use the gear menu’s Show in Wings instead.",
                                   symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
    }
}

/// The running activities, the one in the wings marked, Show to pin.
private struct RunningActivitiesRows: View {
    @ObservedObject var center: ActivityCenter

    var body: some View {
        if center.running.isEmpty {
            ActivitySettingsNotice(text: "Nothing running. Timers, calls, meetings, downloads and music show up here.", symbol: "moon.zzz")
        } else {
            ForEach(center.running) { item in
                row(item)
            }
        }
    }

    private func row(_ item: LiveActivitySummary) -> some View {
        let inWings = center.compact?.id == item.id
        let inBand = center.current?.id == item.id
        let pinned = center.pinnedCompactID == item.id
        return HStack(spacing: 10) {
            ActivitySymbolBadge(symbol: item.symbol, tint: item.kind.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                Text(status(inWings: inWings, inBand: inBand, pinned: pinned))
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Spacer(minLength: 8)
            if inWings || inBand {
                if pinned {
                    Button("Automatic") { center.pin(id: nil) }
                        .help("Back to the most important one first")
                } else {
                    Text(inBand ? "Showing" : "In the wings")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            } else {
                Button("Show") { center.pin(id: item.id) }
                    .help("Rest \(item.title) beside the notch until it ends")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func status(inWings: Bool, inBand: Bool, pinned: Bool) -> String {
        if pinned { return "Picked by you" }
        if inBand { return "In the band under the notch" }
        if inWings { return "Most important right now" }
        return "Small icon beside the wings"
    }
}

// MARK: - Timing (pane: Activities)

/// Peek, notification and HUD durations, the track title, hover pause.
struct ActivityTimingSettingsSection: View {
    @ObservedObject private var timing = ActivityTimingSettings.shared
    @ObservedObject private var live = LiveActivitiesSettings.shared

    var body: some View {
        Section {
            ActivitySecondsPicker(title: "Notifications stay", detail: "Longer helps when you read slowly or use VoiceOver.",
                                  choices: ActivityTimingSettings.notificationChoices, value: $timing.notificationSeconds)
            ActivitySecondsPicker(title: "Volume and brightness stay", choices: ActivityTimingSettings.hudChoices, value: $timing.hudSeconds)
            ActivitySecondsPicker(title: "New activities peek for", detail: "A timer, call or meeting shows in full, then tucks beside the notch.",
                                  choices: ActivityTimingSettings.peekChoices, value: $timing.peekSeconds)
            Toggle(isOn: $timing.pausesOnHover) {
                ActivitySettingsLabel(
                    title: "Wait while the pointer is on it",
                    detail: "An alert under the pointer stays (up to \(Int(ActivityTimingSettings.hoverHoldCap)) s), so you can read it or click its buttons."
                )
            }
        } header: {
            HStack {
                Text("Timing")
                Spacer()
                if !timing.isDefault {
                    Button("Reset") { timing.resetToDefaults() }
                        .controlSize(.small)
                }
            }
        }
        Section {
            Toggle(isOn: $timing.alwaysShowTitle) {
                ActivitySettingsLabel(title: "Always show the song title", detail: "Otherwise only for a while after the track changes.")
            }
            ActivitySecondsPicker(title: "Song title shows for", choices: ActivityTimingSettings.titlePeekChoices, value: $timing.titlePeekSeconds)
                .disabled(timing.alwaysShowTitle)
            Picker(selection: $timing.titleWidth) {
                ForEach(ActivityTimingSettings.TitleWidth.allCases) { Text($0.label).tag($0) }
            } label: {
                ActivitySettingsLabel(title: "Title width", detail: "Wide covers more of the menu bar.")
            }
            .pickerStyle(.menu)
            Toggle(isOn: $timing.peekOnTrackChange) {
                ActivitySettingsLabel(title: "Expand on track change", detail: "Shows the artwork and title under the notch.")
            }
            Toggle("Expand on play and pause", isOn: $timing.peekOnPlayPause)
        } header: {
            Text("Music in the Island")
        } footer: {
            if !live.keepsNowPlayingAlongside {
                Text("Music isn’t kept beside other activities, so it only expands while nothing else runs.")
            }
        }
    }
}

// MARK: - Notifications (pane: Activities)

/// Mirrored notifications: on/off, privacy, buttons, which apps.
struct NotificationsSettingsSection: View {
    @ObservedObject private var prefs = NotificationPreferences.shared
    @ObservedObject private var permissions = PermissionCenter.shared
    private let monitor: NotificationMonitor?

    init() { monitor = NotificationMonitor.current }
    init(monitor: NotificationMonitor?) { self.monitor = monitor }

    var body: some View {
        if let monitor {
            NotificationsSettingsBody(monitor: monitor, prefs: prefs, accessibilityGranted: permissions.isGranted(.accessibility))
        } else {
            Section("Notifications") {
                ActivitySettingsNotice(text: "Starts with SparkV.")
            }
        }
    }
}

private struct NotificationsSettingsBody: View {
    @ObservedObject var monitor: NotificationMonitor
    @ObservedObject var prefs: NotificationPreferences
    let accessibilityGranted: Bool

    var body: some View {
        Section {
            Toggle(isOn: $monitor.isEnabled) {
                ActivitySettingsLabel(title: "Show notifications under the notch",
                                      detail: "Banners from Messages, Slack, Mail and other apps, with Reply and Dismiss.")
            }
            if !accessibilityGranted {
                LabeledContent {
                    Button("Allow…") {
                        Task { await PermissionCenter.shared.request(.accessibility, from: "Notifications") }
                    }
                } label: {
                    ActivitySettingsNotice(text: "Needs Accessibility to read banners.", symbol: "hand.raised.fill", tone: .warning)
                }
            }
            Group {
                Toggle(isOn: $monitor.hidesMessageBody) {
                    ActivitySettingsLabel(title: "Hide message text", detail: "Shows who it’s from, not what it says.")
                }
                Toggle(isOn: $prefs.hidesSender) {
                    ActivitySettingsLabel(title: "Hide the sender too", detail: "Only the app’s name and icon.")
                }
                .disabled(!monitor.hidesMessageBody)
                Toggle(isOn: $prefs.showsActions) {
                    ActivitySettingsLabel(title: "Reply, Open and Dismiss buttons",
                                          detail: "They press the banner’s own buttons; Reply opens its reply field.")
                }
            }
            .disabled(!monitor.isEnabled)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Message text is never stored or logged; app names are kept to build the list below. Only banners macOS shows can appear here: Focus and Do Not Disturb hide them too.")
        }

        Section {
            Picker("Show notifications from", selection: $prefs.filterMode) {
                ForEach(NotificationPreferences.FilterMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            let apps = prefs.knownApps
            if apps.isEmpty {
                ActivitySettingsNotice(text: "Apps appear here after their first banner. You can also add one.")
            } else {
                ForEach(apps, id: \.self) { app in
                    Toggle(isOn: prefs.shownBinding(app)) {
                        HStack(spacing: 8) {
                            NotificationSettingsAppIcon(app: app)
                            Text(app)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Add App…") { pickApp() }
                if !prefs.seenApps.isEmpty {
                    Button("Forget Recent Apps") { prefs.forgetSeenApps() }
                }
                Spacer()
                Button("Preview") {
                    monitor.mirror(NotificationContent(appName: "Messages", title: "Priya", subtitle: nil, body: "Can we move the demo to Thursday?"))
                }
            }
        } header: {
            Text("Apps")
        }
        .disabled(!monitor.isEnabled)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(prefs.add(appAt:))
    }
}

private struct NotificationSettingsAppIcon: View {
    let app: String

    var body: some View {
        Group {
            // Cached per app name in NotificationAppLocator.
            if let icon = NotificationAppLocator.icon(forAppNamed: app) {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed").foregroundStyle(SparkVTheme.textTertiary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Calls (pane: Activities)

/// Ongoing call timer, incoming calls, microphone mute.
struct CallsSettingsSection: View {
    @ObservedObject private var prefs = CallPreferences.shared
    @ObservedObject private var microphone = MicMuteController.shared
    private let calls: CallsController?

    init() { calls = CallsController.current }
    /// For renders.
    init(calls: CallsController?) { self.calls = calls }

    var body: some View {
        Section {
            Toggle(isOn: $prefs.showsOngoingCalls) {
                ActivitySettingsLabel(title: "Show ongoing calls",
                                      detail: "A green timer beside the notch on Zoom, Teams, Meet, FaceTime, WhatsApp and Slack calls, with Mute.")
            }
            if let calls { CallDetectionNotice(calls: calls, isOn: prefs.showsOngoingCalls) }
            Toggle(isOn: $prefs.showsIncomingCalls) {
                ActivitySettingsLabel(title: "Incoming FaceTime and iPhone calls",
                                      detail: "Accept and Decline press the call’s own buttons, also over full-screen apps. SparkV never answers by itself.")
            }
            Toggle(isOn: $prefs.watchesCallWindows) {
                ActivitySettingsLabel(title: "Also watch call apps’ ringing windows",
                                      detail: "Zoom, Teams, WhatsApp, Webex and others: only the new windows they open, when they show their buttons to Accessibility.")
            }
            .disabled(!prefs.showsIncomingCalls)
            Toggle(isOn: $prefs.unmutesWhenCallEnds) {
                ActivitySettingsLabel(title: "Unmute when the call ends",
                                      detail: "Only a mute you pressed during that call, so dictation never finds the mic silent.")
            }
            LabeledContent {
                Button(microphone.isMuted ? "Unmute" : "Mute") {
                    if let calls { calls.toggleMute() } else { microphone.setMuted(!microphone.isMuted) }
                }
                .disabled(!microphone.canMute)
            } label: {
                ActivitySettingsLabel(title: "Microphone", detail: microphoneDetail)
            }
        } header: {
            Text("Calls")
        } footer: {
            Text("Mute silences the Mac’s microphone for every app (\(MicMuteController.shortcut.displayString) does too). With notification previews off, the caller’s name is hidden. Call detection and buttons work on this Mac only.")
        }
    }

    private var microphoneDetail: String {
        guard microphone.canMute else { return "This input device can’t be muted from here." }
        let name = microphone.deviceName ?? "Default input"
        return microphone.isMuted ? "\(name): muted" : "\(name): on"
    }
}

/// The call timer needs Meetings › Detect Calls; says so when it is off.
private struct CallDetectionNotice: View {
    @ObservedObject var calls: CallsController
    let isOn: Bool

    var body: some View {
        if !calls.detectsCalls {
            LabeledContent {
                Button("Turn On") { calls.turnOnCallDetection() }
                    .disabled(!isOn)
            } label: {
                ActivitySettingsNotice(text: "The call timer needs Meetings › Detect Calls, which is off.",
                                       symbol: "exclamationmark.triangle.fill", tone: .warning)
            }
        }
    }
}

// MARK: - VoiceOver announcements (pane: Accessibility)

/// What SparkV says to VoiceOver on its own, by category.
struct VoiceOverAnnouncementsSettingsSection: View {
    @ObservedObject private var settings = ActivityAnnouncementSettings.shared
    @StateObject private var voiceOver = ViewFlag()

    var body: some View {
        Section {
            Toggle(isOn: $settings.isEnabled) {
                ActivitySettingsLabel(title: "Announce live activities",
                                      detail: "Charging, timers, meetings, notifications and calls, at most one every few seconds.")
            }
            Group {
                ForEach(ActivityAnnouncement.Category.allCases) { category in
                    Toggle(isOn: settings.binding(category)) {
                        ActivitySettingsLabel(title: category.label, detail: detail(category))
                    }
                }
                Toggle(isOn: $settings.readsNotificationText) {
                    ActivitySettingsLabel(title: "Read notification text",
                                          detail: "Otherwise only the app and sender. Never when Hide Message Text is on.")
                }
                .disabled(!settings.isOn(.notification))
            }
            .disabled(!settings.isEnabled)
            LabeledContent {
                Button("Test Announcement") {
                    ActivityAnnouncer.shared.announce("SparkV announcements are on", id: "settings.test", category: .general,
                                                      important: true, ignoresCategory: true)
                }
                .disabled(!settings.isEnabled || !voiceOver.isOn)
            } label: {
                ActivitySettingsNotice(
                    text: voiceOver.isOn ? "VoiceOver is on." : "VoiceOver is off: nothing is spoken until you turn it on (⌘F5).",
                    symbol: voiceOver.isOn ? "checkmark.circle.fill" : "info.circle",
                    tone: voiceOver.isOn ? .good : .neutral
                )
            }
        } header: {
            Text("VoiceOver Announcements")
        } footer: {
            Text("Volume and brightness are never announced: macOS speaks those itself.")
        }
        .onAppear { voiceOver.isOn = NSWorkspace.shared.isVoiceOverEnabled }
    }

    private func detail(_ category: ActivityAnnouncement.Category) -> String? {
        switch category {
        case .media: "Off by default: songs change often."
        case .call: "Spoken right away, without waiting for others."
        default: nil
        }
    }
}
