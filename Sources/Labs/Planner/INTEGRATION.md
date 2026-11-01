# Planner: calendar, reminders, timers, weather, launcher — wiring steps

Package files (already in place, copied back by the planner package):

| File | What it is |
| --- | --- |
| `Sources/Labs/Planner/PlannerLogic.swift` | Pure logic, Foundation only: `StopwatchState`, `TimerDurationParser`, `CalendarGrid` (day/week/month with a first-weekday override), `CalendarOpenTarget` + `CalendarLinks` (ical://, Google, Outlook), `ReminderQuickAddParser` + `ReminderDue`, Open-Meteo models and decoding (`WeatherPlace`, `WeatherForecast`, `OpenMeteo`, `WeatherCode`, `WeatherUnits`, `RainAlert`), `ShortcutListParser`. |
| `Sources/Labs/Planner/PlannerRouter.swift` | `PlannerSection` and `PlannerRouter.shared` (the page shown, `planner.section`). |
| `Sources/Labs/Planner/PlannerView.swift` | `PlannerPage` (rail + pages) and the Today, Reminders, Timers, Weather and Launcher pages. |
| `Sources/Labs/Planner/PlannerAgenda.swift` | `AgendaModel` and the Agenda page (month grid, day / week list). |
| `Sources/Labs/Planner/PlannerHubTiles.swift` | `AgendaHubTile`, `RemindersHubTile`, `TimersHubTile`, `WeatherHubTile`, `LauncherHubTile`. |
| `Sources/Labs/Planner/PlannerSettings.swift` | Settings sections and gear-menu items. |
| `Sources/Labs/Widgets/WeatherWidget.swift` | `WeatherController.shared` (Open-Meteo, off until a city is set) and the weather widget / glances / city editor. |
| `Sources/Labs/Widgets/RemindersWidget.swift` | `RemindersController.shared` (EventKit reminders) and the reminders widget / rows / quick add. |
| `Sources/TimerController.swift`, `TimerView.swift` | Extra named countdowns and stopwatches, ringing alarms with Stop / Snooze, settings, one live activity for all timers. |
| `Sources/MeetingsController.swift`, `MeetingsView.swift` | Calendar picker, all-day events, agenda fetch, open events in Calendar / Google / Outlook / the default calendar app. |
| `Sources/MacroController.swift`, `ShortcutRunner.swift` | App assignments, the 12-tile launcher, shortcut identifiers. |
| `Sources/TodayView.swift` | Tall drawer: the Planner. Short drawer: the classic meetings + timer. |
| `Sources/Labs/Widgets/WidgetsCatalog.swift`, `WidgetsTabView.swift` | `WidgetKind.weather` and `.reminders`, the Weather editor section, and `WidgetsHomeAccessory` (Home shows the day's weather in the volume knob's place once a city is set). |

Apply the steps in order. Every "Find" block occurs exactly once in its file in the repo today (checked against `/Users/koushikgoudshaganti/Developer/macNotch` with every Labs folder present). Steps 1 and 2 are required; the rest make the features reachable and start them. Steps marked **Skip if not found** are the only optional ones.

Order against other packages: every step here leaves its find's anchor line in place, so sibling steps that anchor on the same lines (Downloads on `Menu("Live Activities")`, FanControl / DevStatus / SystemStatus on `FanController.shared.start()` / `.stop()`, DevStatus on `tallTabs.contains(tab)`, Color Picker / System Status on the `tallTabs` line, Look & Layout on the `packageTiles` declaration) still match before or after. The one ordering rule: step 3c only after Look & Layout step 3e (or skip it).

### Step 1 — `build.sh`

Compile the new lab folder. Required: the core files above use Labs/Planner types.

Find:
```zsh
cp Sources/Labs/Widgets/*.swift "$WORK/src/"
```

Replace with:
```zsh
cp Sources/Labs/Widgets/*.swift "$WORK/src/"
cp Sources/Labs/Planner/*.swift "$WORK/src/"
```

### Step 2 — `Sources/NotchState.swift`

Today uses the tall drawer. The Planner needs 508×114 pt of content; without this Today keeps its classic short layout. This adds its own branch instead of editing the `tallTabs` line, so the Color Picker, System Status and DevStatus steps that rewrite that line (or the `tallTabs.contains` line) still find their text, in any order.

Find:
```swift
            trayExpandedHeight
        } else {
```

Replace with:
```swift
            trayExpandedHeight
        } else if tab == .today {
            // The Planner (Labs/Planner): rail and pages, 508×114 pt.
            trayExpandedHeight
        } else {
```

### Step 3a — `Sources/AgentsHubView.swift`

Today's tooltip, hub stand-in.

Find:
```swift
        HubTileInfo(id: "tab.today", title: "Today", systemImage: "calendar", tint: .red, category: .planner,
                    help: "Today: meetings and timer", pinnable: false),
```

Replace with:
```swift
        HubTileInfo(id: "tab.today", title: "Today", systemImage: "calendar", tint: .red, category: .planner,
                    help: "Today: meetings, agenda, reminders, timers, weather and launcher", pinnable: false),
```

### Step 3b — `Sources/Labs/LookLayout/LayoutModel.swift`

Today's tooltip in the header (Look & Layout's header catalog). Look & Layout's step 3e draws the header from this catalog.

Find:
```swift
        HeaderItemInfo(id: "today", title: "Today", systemImage: "calendar", side: .left, canHide: true,
                       help: "Today: meetings and timer", hubStandIn: "tab.today"),
```

Replace with:
```swift
        HeaderItemInfo(id: "today", title: "Today", systemImage: "calendar", side: .left, canHide: true,
                       help: "Today: meetings, agenda, reminders, timers, weather and launcher", hubStandIn: "tab.today"),
```

### Step 3c — `Sources/NotchNookLayoutView.swift`

Today's tooltip in the classic header. Only for a build without Look & Layout's step 3e. Apply it **after** Look & Layout: 3e's find contains this line, so changing it first would break 3e.

**Skip if not found:** Look & Layout step 3e replaced the header HStack, so this line is gone; 3b covers it.

Find:
```swift
            IconTab(systemImage: "calendar", tab: .today, help: "Today: meetings and timer", pill: pill)
```

Replace with:
```swift
            IconTab(systemImage: "calendar", tab: .today, help: "Today: meetings, agenda, reminders, timers, weather and launcher", pill: pill)
```

### Step 4 — `Sources/NotchNookLayoutView.swift`

Gear menu: one "Planner" submenu. Open a page; Timers, Reminders, Weather and Launcher items. `timer` and `macros` are already environment objects of `SettingsMenu`. The Meetings submenu needs no change: `MeetingsMenuItems` now also has Calendars, Show All-Day Events and Open Events In. The anchor line is kept, so Downloads' "after Live Activities" submenu still goes in.

Find:
```swift
            Menu("Live Activities") {
```

Replace with:
```swift
            Menu("Planner") { PlannerMenuItems(timer: timer, macros: macros) }
            Menu("Live Activities") {
```

### Step 5 — `Sources/NotchNookLayoutView.swift`

Home buttons can open apps too. An "Apps" section in the button picker, used by the gear menu and both capsule menus.

Find:
```swift
        Divider()
        if slot.assignment != nil {
            Button("Remove from This Button") { macros.assign(nil, to: slot.id) }
        }
```

Replace with:
```swift
        Section("Apps") {
            Button("Choose an App…") {
                macros.chooseApp { assignment in
                    if let assignment { macros.assign(assignment, to: slot.id) }
                }
            }
            Menu("Running Apps") {
                ForEach(macros.runningApps, id: \.storageValue) { app in
                    pickerButton(app, systemImage: nil)
                }
            }
        }
        Divider()
        if slot.assignment != nil {
            Button("Remove from This Button") { macros.assign(nil, to: slot.id) }
        }
```

### Step 6 — `Sources/NotchNookLayoutView.swift`

A Home capsule bound to an app shows the app's icon. Cached, 32 px; no file-system call once drawn.

Find:
```swift
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.red))
            }
```

Replace with:
```swift
            } else if let assignment = slot.assignment, assignment.isApp, let icon = LauncherIcons.icon(for: assignment) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.red))
            }
```

### Step 7 — `Sources/NotchWindowController.swift`

Start reminders and weather. Both idle until used: reminders follow `.EKEventStoreChanged` and fetch only while a reminders view shows; weather does nothing until a city is set. The router opens the drawer on Today for menu items, Home's weather glance and notification clicks. The anchor line stays first, so FanControl/DevStatus/SystemStatus steps that anchor on it still match.

Find:
```swift
        FanController.shared.start()
```

Replace with:
```swift
        FanController.shared.start()
        RemindersController.shared.start()
        WeatherController.shared.start(activities: activities)
        PlannerRouter.shared.openDrawer = { [weak self] in
            guard let self else { return }
            self.state.select(.today)
            self.setExpanded(true)
        }
```

### Step 8 — `Sources/NotchWindowController.swift`

Stop them.

Find:
```swift
        FanController.shared.stop()
```

Replace with:
```swift
        FanController.shared.stop()
        RemindersController.shared.stop()
        WeatherController.shared.stop()
```

### Step 9 — `Sources/AgentsHubView.swift`

Hub tiles. Five entries in `HubCatalog.packageTiles`, Look & Layout's extension point (category **Planner**: Agenda, Reminders, Timers, Weather; **System**: Launcher). The find is the declaration only, so other packages adding their own entries before or after this step don't clash; the replacement keeps it.

Find:
```swift
    static var packageTiles: [HubPackageTile] {
        [
```

Replace with:
```swift
    static var packageTiles: [HubPackageTile] {
        [
            // Planner package (Labs/Planner): Agenda, Reminders, Timers, Weather; Launcher in System.
            HubPackageTile(info: HubTileInfo(id: "agenda", title: "Agenda", systemImage: "calendar", tint: .red, category: .planner,
                                             help: "Agenda: day, week and month"),
                           pinAction: { PlannerRouter.shared.show(.agenda) }) { AnyView(AgendaHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "reminders", title: "Reminders", systemImage: "checklist", tint: .orange, category: .planner,
                                             help: "Reminders due today"),
                           pinAction: { PlannerRouter.shared.show(.reminders) }) { AnyView(RemindersHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "timers", title: "Timers", systemImage: "timer", tint: .orange, category: .planner,
                                             help: "Timers, stopwatches and Pomodoro"),
                           pinAction: { PlannerRouter.shared.show(.timers) }) { AnyView(TimersHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "weather", title: "Weather", systemImage: "cloud.sun.fill", tint: .cyan, category: .planner,
                                             help: "Weather (off until you choose a city)"),
                           pinAction: { PlannerRouter.shared.show(.weather) }) { AnyView(WeatherHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "launcher", title: "Launcher", systemImage: "square.grid.3x3.fill", tint: .indigo, category: .system,
                                             help: "Launcher: pinned apps and shortcuts"),
                           pinAction: { PlannerRouter.shared.show(.launcher) }) { AnyView(LauncherHubTile()) },
```

### Step 10 — `Info.plist`

The reminders prompt now covers the Planner too.

Find:
```xml
	<string>SparkV adds the meeting tasks you tick to Reminders. Nothing is added unless you click Add.</string>
```

Replace with:
```xml
	<string>SparkV shows your reminders due today in the notch, lets you tick them off and add new ones, and adds the meeting tasks you choose. Nothing is changed unless you click.</string>
```

### Step 11a — `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Settings › Planner: the five sections. Each is a plain view (no card of its own), so each goes in its own Form `Section`. The find is only the pane's marker, so another package's Planner sections can go above or below in any order.

Find:
```swift
            // ▸ Planner: add sections above this line
```

Replace with:
```swift
            Section { CalendarSettingsSection() }
            Section { RemindersSettingsSection() }
            Section { TimerSettingsSection() }
            Section { WeatherSettingsSection() }
            Section { LauncherSettingsSection() }
            // ▸ Planner: add sections above this line
```

### Step 11b — `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Drop the Planner placeholder. The pane now has real sections (AppShell's rule).

**Skip if not found:** another package already removed it.

Find:
```swift
            SettingsPanePlaceholderSection(pane: .planner)
```

Replace with (an empty line):
```swift
```

## Settings sections (app-shell Settings window)

All take no arguments.

| View | Pane |
| --- | --- |
| `CalendarSettingsSection()` | Planner |
| `RemindersSettingsSection()` | Planner |
| `TimerSettingsSection()` | Planner |
| `WeatherSettingsSection()` | Planner |
| `LauncherSettingsSection()` | Planner |

Step 11a puts them in. They fill the width they are given (about 440 pt is the narrowest they are designed for), native controls (pickers, steppers, checkboxes) on `SparkVTheme` colors, written for the dark settings window. `CalendarSettingsSection` and `LauncherSettingsSection` read `MeetingsController.current` / `MacroController.current` (set when the window controller creates them); `TimerSettingsSection` reads `TimerPreferences.shared` and `TimerController.current`.

## Hub tiles

| View | Category |
| --- | --- |
| `AgendaHubTile()` | Planner |
| `RemindersHubTile()` | Planner |
| `TimersHubTile()` | Planner |
| `WeatherHubTile()` | Planner |
| `LauncherHubTile()` | System |

Step 9 adds them. They use `NotchState`, `MeetingsController`, `TimerController` and `MacroController` from the drawer's environment (already injected) and open the Today tab on their Planner page. Right-click gives each feature's menu items.

## Gear menu items

`PlannerMenuItems(timer:macros:)` (step 4) contains `TimerMenuItems(controller:)`, `RemindersMenuItems()`, `WeatherMenuItems()` and `LauncherMenuItems(macros:)`, each usable on its own inside `Menu { }`. `MeetingsMenuItems` (already in the gear menu) gained Calendars, Show All-Day Events and Open Events In. `MacroAssignmentPickerItems(macros:slotID:)` is a drop-in for the Home button pickers (step 5 adds the same Apps section in place).

## Optional

- **Weather on Home** needs no step: `WidgetsHomeAccessory` (Labs/Widgets, already in `FeaturesGrid`) shows `WeatherHomeGlance` (56×56: symbol and now, high / low, rain chance; click opens Today › Weather) in the volume knob's place once a city is set, unless Settings › Planner › Weather › "Show today's weather on Home" (`weather.showsOnHome`, on by default) is off. With weather off, Home is unchanged. The Planner's Today header shows the same day overview.
- **Notification delegate**: `TimerNotificationRouter.shared` becomes the `UNUserNotificationCenter` delegate when the timer starts (Snooze / Stop actions). It forwards every other notification to the delegate that was installed before it. A feature that installs its own delegate later should call `TimerNotificationRouter.shared.forward(to: itsDelegate)` instead of replacing it. With no other delegate, other features' notifications are presented as macOS does without a delegate (not while SparkV is the active app), so nothing changes for them.

## Hotkeys

One, off by default: **⌃⌥⇧P** starts, pauses or silences the main timer (Settings › Planner › Timers, or the gear menu's Planner › Timers). It uses `ScreenRegionHotkey`; when macOS refuses it, Settings says "This shortcut is already taken".

Checked against every shortcut in the repo: ⌃⌥J (join meeting), ⌃⌥R (Reply Drafter), ⌃⌥S (Ask Screen), ⌃⌥T (Copy Text), ⌃⌥C (Quick Capture), ⌃⌥F / ⌥Space / ⌃⌥Space / ⌥⇧Space / ⌘⇧Space (Search), ⌃⌥H (Island Placement), ⌃⌥M (mic mute), ⌃⌥B (menu bar), ⌃⌥A (activities), ⌃⌥1…5, ⌃⌥⇧R (record), ⌃⌥⇧T / ⌃⌥⇧Space (Teleprompter), ⌘⇧V and ⌘1…9 V (clipboard), and **Color Picker's ⌃⌥P (on by default) and its choices ⌃⌥K / ⌃⌥E / ⌃⌥I / ⌃⌥⌘C**. ⌃⌥⇧P is used by none of them. (Earlier versions of this package used ⌃⌥P, which clashed with the Color Picker.)

## Data and energy

- UserDefaults keys: `timer.*` (`timer.items.v2`, `timer.primary.meta`, `timer.pomodoro.*`, `timer.alert.*`, `timer.showsBesideNotch`, `timer.hotkeyEnabled`), `meetings.hiddenCalendarIDs`, `meetings.showsAllDay`, `meetings.weekStart`, `meetings.openIn`, `reminders.*`, `weather.*`, `MacroLauncher.items`, `planner.section`, and `SparkV.widgets.enabled` (Weather and Reminders widgets wait in "Add widget"), `weather.showsOnHome`. `MacroSlots.format` goes to 3 (adds `app:` values; older builds read them as missing shortcuts); only arrays saved before format 2 are migrated, so a user who emptied both Home buttons keeps them empty.
- Timers: no per-second work in the controller; one wake at the soonest end. Bands and views tick through `TimelineView` only while drawn.
- Calendar and reminders: `.EKEventStoreChanged`, day change and wake notifications; no polling. Only a change to hidden calendars or all-day events refetches (not the first weekday or "open in"). The agenda refetches on appear when the calendar revision moved while it was off screen.
- Launcher and Home buttons: the running-apps list is read once and kept until `NSWorkspace` reports an app launching or quitting; app locations are cached for 30 s, icons for good.
- Weather: nothing until a city is set; then at most every 30 min while weather is on screen, hourly in the background only with rain alerts on, never while asleep, backing off after failures.
