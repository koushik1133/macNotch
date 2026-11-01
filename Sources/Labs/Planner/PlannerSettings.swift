import AppKit
import SwiftUI

// Settings sections (Settings › Planner) and gear-menu items for the
// Planner's features. Every section takes no arguments: it reads the
// shared controllers (`.shared`, or `.current` for the ones the window
// controller creates).

// MARK: - Layout

/// Title, one line of explanation, then the controls (about 440 pt wide).
struct PlannerSettingsBlock<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SparkVTheme.headline(13))
                    .tracking(-0.2)
                    .foregroundStyle(SparkVTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .font(.system(size: 12))
                .tint(SparkVTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Connected" / "Connect …" / "Open Settings" for a permission.
private struct PlannerAccessRow: View {
    let granted: Bool
    let denied: Bool
    let connectTitle: String
    let busy: Bool
    let connect: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : (denied ? "exclamationmark.triangle.fill" : "circle.dashed"))
                .foregroundStyle(granted ? SparkVTheme.success : (denied ? SparkVTheme.warning : SparkVTheme.textTertiary))
            Text(granted ? "Access allowed" : (denied ? "Access is off in Privacy & Security" : "Not connected yet"))
                .foregroundStyle(SparkVTheme.textSecondary)
            Spacer()
            if denied {
                Button("Open Settings…", action: openSettings).buttonStyle(SparkVSecondaryButtonStyle())
            } else if !granted {
                Button(busy ? "Connecting…" : connectTitle, action: connect)
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .disabled(busy)
            }
        }
    }
}

/// "Focus            25 min [±]": the value and stepper on the right, like the pickers.
private struct PlannerStepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(SparkVTheme.text)
            Spacer(minLength: 8)
            Text("\(value) \(unit)")
                .monospacedDigit()
                .foregroundStyle(SparkVTheme.text)
            Stepper("", value: $value, in: range)
                .labelsHidden()
                .accessibilityLabel(label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }
}

/// A labelled row: label on the left, control on the right.
private struct PlannerSettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(SparkVTheme.text)
            Spacer(minLength: 8)
            control
        }
    }
}

/// Calendars shown, grouped by account, with each calendar's color.
private struct CalendarChecklist: View {
    @ObservedObject var controller: MeetingsController
    @ObservedObject var preferences: CalendarPreferences

    var body: some View {
        let groups = Dictionary(grouping: controller.calendars, by: \.sourceTitle)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.key) { group in
                Text(group.key.uppercased())
                    .font(SparkVTheme.eyebrow(9))
                    .tracking(0.6)
                    .foregroundStyle(SparkVTheme.textTertiary)
                ForEach(group.value) { calendar in
                    Toggle(isOn: preferences.binding(for: calendar.id)) {
                        HStack(spacing: 6) {
                            Circle().fill(calendar.color.color).frame(width: 8, height: 8)
                            Text(calendar.title).foregroundStyle(SparkVTheme.text)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
    }
}

// MARK: - Calendar

/// Settings › Planner: meetings in the notch, heads-up, the calendars that
/// show, all-day events, first weekday and where events open.
struct CalendarSettingsSection: View {
    var body: some View {
        if let controller = MeetingsController.current {
            CalendarSettingsForm(controller: controller, preferences: .shared)
        } else {
            PlannerSettingsBlock(title: "Calendar", detail: "Calendar settings appear once SparkV has started.") { EmptyView() }
        }
    }
}

private struct CalendarSettingsForm: View {
    @ObservedObject var controller: MeetingsController
    @ObservedObject var preferences: CalendarPreferences

    var body: some View {
        PlannerSettingsBlock(
            title: "Calendar",
            detail: "Today’s meetings with Join buttons, a heads-up under the notch before each one, and the Planner’s agenda. SparkV reads the calendars on this Mac (accounts added in Calendar, such as iCloud, Google or Exchange); nothing is uploaded."
        ) {
            PlannerAccessRow(granted: controller.access == .granted, denied: controller.access == .denied,
                             connectTitle: "Connect Calendar", busy: controller.isRequestingAccess,
                             connect: { controller.requestAccess() }, openSettings: { controller.openPrivacySettings() })
            Toggle("Meetings in the notch", isOn: $controller.isEnabled)
            Group {
                PlannerSettingsRow(label: "Heads-up before meetings") {
                    Picker("", selection: $controller.leadMinutes) {
                        ForEach(MeetingsController.leadChoices, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Heads-up before meetings")
                }
                Toggle("Join the next meeting with \(MeetingsController.joinShortcut.displayString)", isOn: $controller.joinShortcutEnabled)
                Toggle("Show all-day events (they never alert)", isOn: $preferences.showsAllDay)
                PlannerSettingsRow(label: "Week starts on") {
                    Picker("", selection: $preferences.weekStart) {
                        ForEach(CalendarPreferences.weekStartChoices, id: \.value) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PlannerSettingsRow(label: "Open events in") {
                    Picker("", selection: $preferences.openTarget) {
                        ForEach(MeetingsController.openTargets) { target in
                            Text(MeetingsController.title(for: target)).tag(target)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if controller.access == .granted, !controller.calendars.isEmpty {
                    HStack {
                        Text("Calendars to show").foregroundStyle(SparkVTheme.text)
                        Spacer()
                        Button("Show All") { preferences.hiddenCalendarIDs = [] }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                            .disabled(preferences.hiddenCalendarIDs.isEmpty)
                    }
                    CalendarChecklist(controller: controller, preferences: preferences)
                }
            }
            .disabled(!controller.isEnabled)
            Text("Hidden calendars are left out everywhere: the list, the heads-up and ⌃⌥J. Calendar opens the event itself when it can find it (recurring events open their series).")
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Reminders

/// Settings › Planner: which lists show, undated reminders, quick add.
struct RemindersSettingsSection: View {
    @ObservedObject private var controller = RemindersController.shared

    var body: some View {
        PlannerSettingsBlock(
            title: "Reminders",
            detail: "Reminders due today and overdue, in Today › Reminders and the Reminders widget. Tick them off or add new ones from the notch; they stay in Apple Reminders and sync as usual."
        ) {
            PlannerAccessRow(granted: controller.access == .granted, denied: controller.access == .denied,
                             connectTitle: "Connect Reminders", busy: controller.isRequestingAccess,
                             connect: { controller.requestAccess() }, openSettings: { controller.openPrivacySettings() })
            Group {
                Toggle("Show reminders without a date", isOn: $controller.showsUndated)
                Toggle("New reminders are due today when no date is typed", isOn: $controller.quickAddDueToday)
                PlannerSettingsRow(label: "Add new reminders to") {
                    Picker("", selection: Binding(get: { controller.defaultListID ?? "" },
                                                  set: { controller.defaultListID = $0.isEmpty ? nil : $0 })) {
                        Text("Default list").tag("")
                        ForEach(controller.lists.filter(\.allowsAdding)) { list in
                            Text(list.title).tag(list.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Add new reminders to")
                }
                if !controller.lists.isEmpty {
                    Text("Lists to show").foregroundStyle(SparkVTheme.text)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(controller.lists) { list in
                            Toggle(isOn: controller.binding(for: list.id)) {
                                HStack(spacing: 6) {
                                    Circle().fill(list.color.color).frame(width: 8, height: 8)
                                    Text(list.title).foregroundStyle(SparkVTheme.text)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
                }
            }
            .disabled(controller.access != .granted)
            Text("Type dates in plain words: “Pay rent Friday”, “Call Mom tomorrow at 5pm”. A time adds an alert, as in Reminders.")
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
        .remindersVisible(controller)
    }
}

// MARK: - Timers

/// Settings › Planner: Pomodoro lengths, alarms, the band and ⌃⌥⇧P.
struct TimerSettingsSection: View {
    @ObservedObject private var preferences = TimerPreferences.shared

    var body: some View {
        PlannerSettingsBlock(
            title: "Timers",
            detail: "Countdowns, stopwatches and Pomodoro in Today and Today › Timers. Running timers rest beside the notch; a countdown can keep ringing until you stop or snooze it."
        ) {
            if let controller = TimerController.current {
                TimerEnabledToggle(controller: controller)
            }
            Group {
                Text("Pomodoro").font(SparkVTheme.headline(12)).foregroundStyle(SparkVTheme.text)
                PlannerStepperRow(label: "Focus", value: $preferences.focusMinutes, range: 1...180, unit: "min")
                PlannerStepperRow(label: "Short break", value: $preferences.shortBreakMinutes, range: 1...60, unit: "min")
                PlannerStepperRow(label: "Long break", value: $preferences.longBreakMinutes, range: 1...90, unit: "min")
                PlannerStepperRow(label: "Long break after", value: $preferences.sessionsPerCycle, range: 2...8, unit: "sessions")
                HStack {
                    Toggle("Start the next phase on its own", isOn: $preferences.autoStartsNextPhase)
                    Spacer()
                    Button("Reset to 25 / 5 / 15") { preferences.resetPomodoro() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            Group {
                Text("When a countdown ends").font(SparkVTheme.headline(12)).foregroundStyle(SparkVTheme.text)
                Toggle("Ring until I stop or snooze it", isOn: $preferences.ringsUntilStopped)
                PlannerSettingsRow(label: "Ring for at most") {
                    Picker("", selection: $preferences.ringLimitSeconds) {
                        ForEach(TimerPreferences.ringLimits, id: \.self) { seconds in
                            Text(seconds < 60 ? "\(seconds) seconds" : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("When a countdown ends")
                }
                .disabled(!preferences.ringsUntilStopped)
                PlannerSettingsRow(label: "Sound") {
                    Picker("", selection: $preferences.soundName) {
                        ForEach(TimerPreferences.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Sound")
                    Button("Play") { NSSound(named: NSSound.Name(preferences.soundName))?.play() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .accessibilityLabel("Play the \(preferences.soundName) sound")
                }
                PlannerStepperRow(label: "Snooze for", value: $preferences.snoozeMinutes, range: 1...60, unit: "min")
            }
            Toggle("Show running timers beside the notch", isOn: $preferences.showsBesideNotch)
            if let controller = TimerController.current {
                TimerHotkeyRow(controller: controller, preferences: preferences)
            } else {
                Toggle("Start, pause or silence the main timer with \(TimerController.hotkeyShortcut.displayString)", isOn: $preferences.hotkeyEnabled)
            }
            Text("Countdowns started from Focus or Smart Moments chime once instead of ringing. macOS doesn’t let other apps see the Clock app’s timers, so those stay in Clock.")
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The timer shortcut and, once registration has run, whether it worked.
private struct TimerHotkeyRow: View {
    @ObservedObject var controller: TimerController
    @ObservedObject var preferences: TimerPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Start, pause or silence the main timer with \(TimerController.hotkeyShortcut.displayString)", isOn: $preferences.hotkeyEnabled)
            if preferences.hotkeyEnabled, controller.isEnabled, !controller.isHotkeyRegistered {
                Label("This shortcut is already taken", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.warning)
                    .padding(.leading, 20)
                    .help("Another app (or another SparkV feature) already uses \(TimerController.hotkeyShortcut.displayString).")
            }
        }
    }
}

private struct TimerEnabledToggle: View {
    @ObservedObject var controller: TimerController

    var body: some View {
        Toggle("Timers", isOn: $controller.isEnabled)
    }
}

// MARK: - Weather

/// Settings › Planner: the city, units and rain alerts. Says what leaves the Mac.
struct WeatherSettingsSection: View {
    @ObservedObject private var controller = WeatherController.shared

    var body: some View {
        PlannerSettingsBlock(
            title: "Weather",
            detail: "Off until you choose a city. Then SparkV asks Open-Meteo (free, no account) for that city’s forecast, sending only its coordinates rounded to about 1 km: every 30 minutes while weather is on screen, hourly with rain alerts on. No location access is used. Typing in the search sends the text to Open-Meteo’s city search."
        ) {
            WeatherCityEditor(controller: controller, showsUnits: false, showsDisclosure: false)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
            PlannerSettingsRow(label: "Units") {
                Picker("", selection: $controller.units) {
                    ForEach(WeatherUnits.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Units")
            }
            HStack {
                Toggle("Rain alerts under the notch", isOn: $controller.rainAlerts)
                Spacer()
                Picker("", selection: $controller.rainThreshold) {
                    ForEach(WeatherController.thresholdChoices, id: \.self) { Text("\($0)% chance").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!controller.rainAlerts)
                .accessibilityLabel("Rain alert threshold")
            }
            .disabled(!controller.isConfigured)
            Toggle("Show today’s weather on Home, in place of the volume knob", isOn: $controller.showsOnHome)
                .disabled(!controller.isConfigured)
            HStack {
                Text(controller.isConfigured ? controller.updatedText : "Weather is off")
                    .foregroundStyle(SparkVTheme.textTertiary)
                Spacer()
                if controller.isConfigured {
                    Button("Refresh") { controller.refresh() }.buttonStyle(SparkVSecondaryButtonStyle())
                    Button("Turn Off") { controller.setPlace(nil) }.buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            Text("\(OpenMeteo.attribution) (CC BY 4.0). Open-Meteo’s free service is for non-commercial use.")
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
    }
}

// MARK: - Launcher

/// Settings › Planner: the launcher grid's items, and the two Home buttons.
struct LauncherSettingsSection: View {
    var body: some View {
        if let macros = MacroController.current {
            LauncherSettingsForm(macros: macros)
        } else {
            PlannerSettingsBlock(title: "Launcher", detail: "Launcher settings appear once SparkV has started.") { EmptyView() }
        }
    }
}

private struct LauncherSettingsForm: View {
    @ObservedObject var macros: MacroController

    var body: some View {
        PlannerSettingsBlock(
            title: "Launcher",
            detail: "Up to \(MacroController.maxLauncherItems) apps, shortcuts and SparkV actions in Today › Launcher. Shortcuts run with Apple’s shortcuts tool and stay pinned when you rename them."
        ) {
            VStack(spacing: 0) {
                if macros.launcher.isEmpty {
                    Text("Nothing pinned yet")
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ForEach(Array(macros.launcher.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        LauncherSettingsIcon(assignment: item.assignment)
                        Text(item.assignment?.title ?? "Missing").foregroundStyle(SparkVTheme.text)
                        Text(kind(item.assignment)).foregroundStyle(SparkVTheme.textTertiary)
                        Spacer()
                        Button { macros.moveLauncherItem(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(index == 0).help("Move earlier")
                        Button { macros.moveLauncherItem(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(index == macros.launcher.count - 1).help("Move later")
                        Button { macros.removeFromLauncher(item.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    if index < macros.launcher.count - 1 {
                        Rectangle().fill(SparkVTheme.stroke).frame(height: 1).padding(.leading, 38)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
            HStack {
                Menu("Add…") { LauncherAddItems(macros: macros) }
                    .fixedSize()
                    .disabled(!macros.canAddToLauncher)
                Spacer()
                Button("Open Shortcuts") { macros.openShortcutsApp() }.buttonStyle(SparkVSecondaryButtonStyle())
            }
            Text("Home buttons").font(SparkVTheme.headline(12)).foregroundStyle(SparkVTheme.text)
            ForEach(macros.slots) { slot in
                PlannerSettingsRow(label: "Button \(slot.id + 1)") {
                    Menu(slot.assignment?.title ?? "None") {
                        MacroAssignmentPickerItems(macros: macros, slotID: slot.id)
                    }
                    .fixedSize()
                }
            }
        }
        .onAppear { macros.refreshLibraryIfStale() }
    }

    private func kind(_ assignment: MacroController.Assignment?) -> String {
        switch assignment {
        case .app?: "App"
        case .shortcut?: "Shortcut"
        case .builtIn?: "SparkV"
        case nil: ""
        }
    }
}

private struct LauncherSettingsIcon: View {
    let assignment: MacroController.Assignment?

    var body: some View {
        Group {
            if let assignment, let image = LauncherIcons.icon(for: assignment) {
                Image(nsImage: image).resizable()
            } else if case .builtIn(let action)? = assignment {
                Image(systemName: action.systemImage).foregroundStyle(SparkVTheme.accent)
            } else {
                Image(systemName: "square.2.layers.3d.fill").foregroundStyle(SparkVTheme.choose(apple: Color.pink, sparkv: SparkVTheme.red))
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Everything a Home button (or any slot) can run: SparkV actions,
/// shortcuts and apps. A drop-in for the gear menu's button pickers.
struct MacroAssignmentPickerItems: View {
    @ObservedObject var macros: MacroController
    let slotID: Int

    var body: some View {
        let current = macros.slots.first { $0.id == slotID }?.assignment
        Section("SparkV") {
            ForEach(MacroController.BuiltInAction.allCases) { action in
                pick(.builtIn(action), current: current)
            }
        }
        Section("Shortcuts") {
            if macros.library.isEmpty {
                Text("No shortcuts found")
            } else {
                ForEach(macros.library, id: \.self) { name in
                    pick(.shortcut(name), current: current)
                }
            }
        }
        Section("Apps") {
            Button("Choose an App…") {
                macros.chooseApp { assignment in
                    if let assignment { macros.assign(assignment, to: slotID) }
                }
            }
            Menu("Running Apps") {
                ForEach(macros.runningApps, id: \.storageValue) { app in
                    pick(app, current: current)
                }
            }
        }
        Divider()
        if current != nil {
            Button("Remove from This Button") { macros.assign(nil, to: slotID) }
        }
        Button("Open Shortcuts…") { macros.openShortcutsApp() }
    }

    private func pick(_ assignment: MacroController.Assignment, current: MacroController.Assignment?) -> some View {
        Button {
            macros.assign(assignment, to: slotID)
        } label: {
            if assignment == current {
                Label(assignment.title, systemImage: "checkmark")
            } else {
                Text(assignment.title)
            }
        }
    }
}

// MARK: - Gear menu

/// Items for `Menu("Reminders") { RemindersMenuItems() }`.
struct RemindersMenuItems: View {
    @ObservedObject private var controller = RemindersController.shared

    var body: some View {
        if controller.access == .granted {
            Button("Show Reminders (\(controller.dueCount) Due)") { PlannerRouter.shared.show(.reminders) }
            RemindersListItems(controller: controller)
            Divider()
            Button("Open Reminders") { controller.openRemindersApp() }
        } else if controller.access == .denied {
            Button("Allow Reminders Access…") { controller.openPrivacySettings() }
        } else {
            Button("Connect Reminders…") { controller.requestAccess() }
        }
    }
}

/// Items for `Menu("Weather") { WeatherMenuItems() }`.
struct WeatherMenuItems: View {
    @ObservedObject private var controller = WeatherController.shared

    var body: some View {
        if let summary = controller.summary {
            Text(summary)
            Button("Show Weather") { PlannerRouter.shared.show(.weather) }
            Button("Refresh") { controller.refresh() }
            Divider()
            Picker("Units", selection: $controller.units) {
                ForEach(WeatherUnits.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Rain Alerts", isOn: $controller.rainAlerts)
            Toggle("Show on Home", isOn: $controller.showsOnHome)
            Button("Change City…") { PlannerRouter.shared.show(.weather) }
            Button("Turn Weather Off") { controller.setPlace(nil) }
        } else if controller.isConfigured {
            Button("Show Weather") { PlannerRouter.shared.show(.weather) }
            Button("Turn Weather Off") { controller.setPlace(nil) }
        } else {
            Button("Choose a City…") { PlannerRouter.shared.show(.weather) }
            Text("Weather is off: nothing is sent until you choose a city")
        }
    }
}

/// Items for `Menu("Launcher") { LauncherMenuItems(macros: macros) }`: run
/// any pinned item.
struct LauncherMenuItems: View {
    @ObservedObject var macros: MacroController

    var body: some View {
        ForEach(macros.launcher) { item in
            if let assignment = item.assignment {
                Button(assignment.title) { macros.runLauncher(item) }
                    .disabled(macros.launcherStatus(for: item) == .missing)
            }
        }
        if !macros.launcher.isEmpty { Divider() }
        Menu("Add") { LauncherAddItems(macros: macros) }
            .disabled(!macros.canAddToLauncher)
        Button("Edit Launcher…") { PlannerRouter.shared.show(.launcher) }
    }
}

/// One "Planner" submenu for the gear menu: open a page, plus each
/// feature's own items.
struct PlannerMenuItems: View {
    @ObservedObject var timer: TimerController
    @ObservedObject var macros: MacroController

    var body: some View {
        ForEach(PlannerSection.allCases) { section in
            Button("Open \(section.title)") { PlannerRouter.shared.show(section) }
        }
        Divider()
        Menu("Timers") { TimerMenuItems(controller: timer) }
        Menu("Reminders") { RemindersMenuItems() }
        Menu("Weather") { WeatherMenuItems() }
        Menu("Launcher") { LauncherMenuItems(macros: macros) }
    }
}
