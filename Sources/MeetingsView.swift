import SwiftUI

/// Left part of the Today tab (about 280×70 pt): up to three of today's
/// remaining meetings with a Join button when the event has a call link,
/// or a prompt to connect the calendar.
struct MeetingsView: View {
    @EnvironmentObject private var meetings: MeetingsController

    var body: some View {
        Group {
            if !meetings.isEnabled {
                MeetingsMessage(systemImage: "calendar", text: "Meetings are turned off")
            } else {
                switch meetings.access {
                case .notDetermined:
                    MeetingsMessage(systemImage: "calendar.badge.plus", text: "See today's meetings here") {
                        MeetingsPillButton(
                            title: meetings.isRequestingAccess ? "Connecting…" : "Connect Calendar",
                            tint: SparkVTheme.red
                        ) { meetings.requestAccess() }
                            .disabled(meetings.isRequestingAccess)
                    }
                case .denied:
                    MeetingsMessage(systemImage: "calendar.badge.exclamationmark", text: "Calendar access is off") {
                        MeetingsPillButton(title: "Open Settings", tint: nil) { meetings.openPrivacySettings() }
                    }
                case .granted:
                    list
                }
            }
        }
        .onAppear { meetings.recheckAuthorization() }
    }

    @ViewBuilder
    private var list: some View {
        let rows = meetings.upcoming
        if rows.isEmpty {
            MeetingsMessage(systemImage: "checkmark.circle", text: "No more meetings today")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows) { meeting in
                    UpcomingMeetingRow(
                        meeting: meeting,
                        timing: meetings.timing(for: meeting),
                        isInHeadsUp: meetings.isInHeadsUp(meeting)
                    ) { meetings.join(meeting) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Time (or "in 4 min" / "Now"), calendar dot, title, Join and Notes,
/// about 20 pt tall.
struct UpcomingMeetingRow: View {
    @EnvironmentObject private var assistant: MeetingAssistant
    let meeting: CalendarMeeting
    let timing: MeetingTiming
    /// Within the heads-up window: show the countdown instead of the time.
    let isInHeadsUp: Bool
    let join: () -> Void

    var body: some View {
        let isLive = timing.hasStarted
        HStack(spacing: 6) {
            Text(timeLabel)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(timeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 48, alignment: .leading)

            Circle()
                .fill(meeting.calendarColor.color)
                .frame(width: 6, height: 6)

            Text(meeting.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let link = meeting.link {
                MeetingsPillButton(
                    title: "Join",
                    systemImage: "video.fill",
                    icon: MeetingAppIcon.icon(for: link),
                    tint: timing.isJoinMoment || isLive ? SparkVTheme.choose(apple: Color.green, sparkv: SparkVTheme.red) : nil,
                    action: join
                )
                .help("Join on \(link.provider.displayName)")
            }
            // Record this meeting, titled after the calendar event, and open
            // the notepad; while recording it just opens the notes.
            if assistant.phase == .recording {
                MeetingsPillButton(title: "Notes", systemImage: "note.text", tint: nil) {
                    assistant.openNotesWindow()
                }
                .help("Open the live notes and transcript")
            } else {
                MeetingsPillButton(title: "Notes", systemImage: "record.circle", tint: nil, iconTint: SparkVTheme.recording) {
                    assistant.start(title: meeting.title, calendarEventID: meeting.eventID)
                    assistant.openNotesWindow()
                }
                .help("Record and take notes for \(meeting.title)")
            }
        }
        .frame(height: 20)
    }

    private var timeLabel: String {
        switch timing {
        case .now, .inProgress: "Now"
        case .upcoming where isInHeadsUp: MeetingsController.statusText(for: timing)
        default: MeetingsController.timeFormatter.string(from: meeting.start)
        }
    }

    private var timeColor: Color {
        switch timing {
        case .now, .inProgress: SparkVTheme.choose(apple: SparkVTheme.success, sparkv: SparkVTheme.red)
        case .upcoming where isInHeadsUp: SparkVTheme.text
        default: SparkVTheme.textTertiary
        }
    }
}

/// Icon, one line of text and an optional button, vertically centered.
private struct MeetingsMessage<Accessory: View>: View {
    let systemImage: String
    let text: String
    let accessory: Accessory

    init(systemImage: String, text: String, @ViewBuilder accessory: () -> Accessory) {
        self.systemImage = systemImage
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SparkVTheme.textTertiary)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            accessory
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

extension MeetingsMessage where Accessory == EmptyView {
    init(systemImage: String, text: String) {
        self.init(systemImage: systemImage, text: text) { EmptyView() }
    }
}

/// Small capsule button used for Join / Notes / Connect Calendar. `icon`
/// (the meeting app's icon) replaces the SF Symbol when given.
private struct MeetingsPillButton: View {
    let title: String
    var systemImage: String?
    var icon: NSImage?
    /// Filled red for the primary action; nil draws the frosted secondary pill.
    let tint: Color?
    /// Glyph color on a frosted pill (e.g. the red record dot).
    var iconTint: Color? = nil
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 12, height: 12)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(iconTint ?? (tint == nil ? SparkVTheme.text : Color.white))
                }
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tint == nil ? SparkVTheme.text : Color.white)
            .padding(.leading, icon == nil ? 8 : 4)
            .padding(.trailing, 8)
            .frame(height: 18)
            .background(Capsule().fill(tint.map { hover.isOn ? (SparkVTheme.isApple ? $0.opacity(0.8) : SparkVTheme.redDeep) : $0 } ?? (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(tint == nil && !SparkVTheme.isApple ? SparkVTheme.stroke : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .fixedSize()
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }
}

// MARK: - Menu

/// Items for the settings menu's "Meetings" submenu: Join Next Meeting
/// (⌃⌥J), the heads-up lead time and the shortcut toggle.
struct MeetingsMenuItems: View {
    @ObservedObject var controller: MeetingsController

    var body: some View {
        Button(joinTitle) { controller.joinNextMeeting() }
            .disabled(!controller.isEnabled || controller.nextJoinableMeeting == nil)
        Picker("Heads-Up Before Meetings", selection: $controller.leadMinutes) {
            ForEach(MeetingsController.leadChoices, id: \.self) { minutes in
                Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
            }
        }
        .disabled(!controller.isEnabled)
        Toggle("Join Shortcut  \(MeetingsController.joinShortcut.displayString)", isOn: $controller.joinShortcutEnabled)
            .disabled(!controller.isEnabled)
    }

    private var joinTitle: String {
        let title = controller.joinNextMenuTitle
        guard controller.joinShortcutEnabled, controller.isShortcutRegistered else { return title }
        return "\(title)  \(MeetingsController.joinShortcut.displayString)"
    }
}
