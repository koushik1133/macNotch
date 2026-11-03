import SwiftUI

/// Left part of the Today tab (about 280×70 pt, taller in the Planner):
/// today's all-day events as chips, then as many of today's remaining
/// meetings as fit, with a Join button when the event has a call link, or a
/// prompt to connect the calendar. Click a title to open the event.
struct MeetingsView: View {
    @EnvironmentObject private var meetings: MeetingsController
    @ObservedObject private var preferences = CalendarPreferences.shared

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
                    GeometryReader { geo in
                        list(height: geo.size.height)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
        }
        .onAppear { meetings.recheckAuthorization() }
    }

    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 3
    static let chipRowHeight: CGFloat = 16

    @ViewBuilder
    private func list(height: CGFloat) -> some View {
        let allDay = preferences.showsAllDay ? meetings.allDayEvents : []
        let chipSpace = allDay.isEmpty ? 0 : Self.chipRowHeight + Self.rowSpacing
        let fit = max(1, Int((height - chipSpace + Self.rowSpacing) / (Self.rowHeight + Self.rowSpacing)))
        let rows = meetings.upcoming(limit: fit)
        let more = meetings.remainingToday - rows.count
        if rows.isEmpty, allDay.isEmpty {
            MeetingsMessage(systemImage: "checkmark.circle", text: "No more meetings today")
        } else {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                if !allDay.isEmpty {
                    AllDayStrip(events: allDay, moreMeetings: rows.isEmpty ? 0 : more)
                }
                if rows.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("No more meetings today")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(height: Self.rowHeight)
                }
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

/// "ALL DAY  ● Holiday  ● Mum's birthday": today's all-day events as
/// chips (click one to open it). They never get a heads-up.
struct AllDayStrip: View {
    @EnvironmentObject private var meetings: MeetingsController
    let events: [CalendarMeeting]
    /// Meetings that didn't fit below ("+2 more").
    var moreMeetings = 0

    var body: some View {
        HStack(spacing: 4) {
            Text("ALL DAY")
                .font(SparkVTheme.eyebrow(8.5))
                .tracking(0.6)
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
            ForEach(events.prefix(3)) { event in
                AllDayChip(event: event) { meetings.open(event) }
            }
            if events.count > 3 {
                Text("+\(events.count - 3)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if moreMeetings > 0 {
                Button { PlannerRouter.shared.section = .agenda } label: {
                    Text("+\(moreMeetings) more")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(SparkVPressStyle())
                .help("\(moreMeetings) more meetings today: show the agenda")
                .accessibilityLabel("\(moreMeetings) more meetings today. Show the agenda")
            }
        }
        .frame(height: MeetingsView.chipRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All-day events")
    }
}

struct AllDayChip: View {
    let event: CalendarMeeting
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(event.calendarColor.color).frame(width: 5, height: 5)
                Text(event.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.text.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .frame(height: MeetingsView.chipRowHeight)
            .background(Capsule().fill(event.calendarColor.color.opacity(hover.isOn ? 0.32 : 0.2)))
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help("\(event.title) · all day\(event.calendarTitle.isEmpty ? "" : " · \(event.calendarTitle)") · click to open")
        .accessibilityLabel("\(event.title), all day")
        .accessibilityHint("Opens the event")
    }
}

/// Time (or "in 4 min" / "Now"), calendar dot, title, Join and Notes,
/// about 20 pt tall.
struct UpcomingMeetingRow: View {
    @EnvironmentObject private var assistant: MeetingAssistant
    @EnvironmentObject private var meetings: MeetingsController
    @StateObject private var titleHover = ViewFlag()
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

            Button { meetings.open(meeting) } label: {
                Text(meeting.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(titleHover.isOn ? SparkVTheme.text : SparkVTheme.text.opacity(0.92))
                    .underline(titleHover.isOn, color: SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { titleHover.isOn = $0 }
            .help("Open \(meeting.title) in \(MeetingsController.title(for: CalendarPreferences.shared.openTarget))")
            .accessibilityLabel("\(meeting.title), \(timeLabel)")
            .accessibilityHint("Opens the event")

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
        .contextMenu { CalendarEventMenuItems(meeting: meeting) }
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

// MARK: - Menus

/// Right-click on an event: open it in each calendar, join, copy the link.
struct CalendarEventMenuItems: View {
    @EnvironmentObject private var meetings: MeetingsController
    let meeting: CalendarMeeting

    var body: some View {
        ForEach(MeetingsController.openTargets) { target in
            Button("Open in \(MeetingsController.title(for: target))") { meetings.open(meeting, in: target) }
        }
        if let url = meeting.eventURL {
            Button("Open Event Link") { NSWorkspace.shared.open(url) }
        }
        if let link = meeting.link {
            Divider()
            Button("Join on \(link.provider.displayName)") { meetings.join(meeting) }
            Button("Copy Meeting Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
    }
}

/// Show or hide each calendar, grouped by account (Toggles show as
/// checkmarks in a menu).
struct CalendarPickerItems: View {
    @ObservedObject var controller: MeetingsController
    @ObservedObject private var preferences = CalendarPreferences.shared

    var body: some View {
        if controller.access != .granted {
            Text("Connect your calendar first")
        } else if controller.calendars.isEmpty {
            Text("No calendars")
        } else {
            let groups = Dictionary(grouping: controller.calendars, by: \.sourceTitle)
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            ForEach(groups, id: \.key) { group in
                Section(group.key) {
                    ForEach(group.value) { calendar in
                        Toggle(calendar.title, isOn: preferences.binding(for: calendar.id))
                    }
                }
            }
            Divider()
            Button("Show All Calendars") { preferences.hiddenCalendarIDs = [] }
                .disabled(preferences.hiddenCalendarIDs.isEmpty)
        }
    }
}

/// Items for the settings menu's "Meetings" submenu: Join Next Meeting
/// (⌃⌥J), the heads-up lead time, the shortcut toggle, and which calendars
/// show, all-day events and where events open.
struct MeetingsMenuItems: View {
    @ObservedObject var controller: MeetingsController
    @ObservedObject private var preferences = CalendarPreferences.shared

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
        Divider()
        Menu("Calendars") { CalendarPickerItems(controller: controller) }
            .disabled(!controller.isEnabled)
        Toggle("Show All-Day Events", isOn: $preferences.showsAllDay)
            .disabled(!controller.isEnabled)
        Picker("Open Events In", selection: $preferences.openTarget) {
            ForEach(MeetingsController.openTargets) { target in
                Text(MeetingsController.title(for: target)).tag(target)
            }
        }
        .disabled(!controller.isEnabled)
    }

    private var joinTitle: String {
        let title = controller.joinNextMenuTitle
        guard controller.joinShortcutEnabled, controller.isShortcutRegistered else { return title }
        return "\(title)  \(MeetingsController.joinShortcut.displayString)"
    }
}
