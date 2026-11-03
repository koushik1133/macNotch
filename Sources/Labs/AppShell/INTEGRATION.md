# App shell: wiring steps for the integrator

Settings window, menu bar icon, reopen, About and Quit, updates, crash and hang reports, reset and uninstall, privacy manifest, Homebrew and the `sparkv://` URL scheme.

New files live in `Sources/Labs/AppShell/` and `Packaging/`. `Sources/AppDelegate.swift` is already changed in this package (main menu, log rotation, `AppShellController.shared.start()/stop()`, `applicationShouldHandleReopen`, `application(_:open:)`). `Sources/NotchIslandApp.swift` needs no change. Everything below edits files this package doesn't own. Apply the steps in order. Every **Find** occurs exactly once in the repo as of 2026-11-01 (after IslandPlacement rewrote `NotchWindowController` and LookLayout added `HubCatalog`); replace it with **Replace with**.

The module builds and runs without steps 6 to 12: the Settings window, menus, updates, diagnostics, reset and the URL scheme all work, and anything that needs the island (open the drawer, post a band, start the timer) falls back to Settings or reports "not available".

## Where other packages' settings go

Everything goes in **one file**: `Sources/Labs/AppShell/AppShellSettingsPanes.swift`. It holds one `switch` with a case per pane. Put each package's `<X>SettingsSection()` on its own line, directly above that pane's marker comment:

```
// ▸ General: add sections above this line
// ▸ Island: add sections above this line
// ▸ Media: add sections above this line
// ▸ System: add sections above this line
// ▸ Activities: add sections above this line
// ▸ Planner: add sections above this line
// ▸ Shelf: add sections above this line
// ▸ Extras: add sections above this line
// ▸ Appearance: add sections above this line
// ▸ Accessibility: add sections above this line
// ▸ Advanced: add sections above this line
```

- When a pane gets its first real section, delete that pane's `SettingsPanePlaceholderSection(pane: …)` line (Media, System, Activities, Planner, Shelf).
- Each pane is a grouped `Form`. Two kinds of section go in:
  - **Form sections** (`Section { … } header: { … }`, most packages): put the line in as is, e.g. `MediaControlsSettingsSection()`.
  - **Self-contained cards** (a view that draws its own rounded card: LookLayout's `LookCard` sections, HUDPlus, Planner): wrap them in the card lane, `SettingsCardRow { AppearanceSettingsSection() }`. It drops the Form's row background, insets and separators, so there is no card inside a card. The card should fill the width it is given (the pane's content is about 740 pt wide).
- A case with more than 10 lines: wrap some of them in `Group { … }`.
- The fallback link sections, `AppShellIslandLinksSettingsSection` (Notch Theme, Ambient Light) and `AppShellExtrasLinksSettingsSection` (Spaces, Modes, Sync to iPhone, Fan Control, Face Unlock), open the existing feature windows. Delete a row once that feature has its own section. If the look-layout package ships a look picker in Appearance, drop `AppShellLookSettingsSection()`.
- A section that reads `@EnvironmentObject` gets the drawer's objects through the `environment` closure in step 8. Sections that use `.shared` singletons need nothing.

Open Settings from anywhere with `SparkVSettings.show()` or `SparkVSettings.show(.media)`.

## This package's sections

| Section | Pane |
|---|---|
| `AppShellAboutSettingsSection` (mark, version, update state, About, Quit) | General |
| `AppShellStartupSettingsSection` (open at login, SMAppService approval) | General |
| `AppShellMenuBarSettingsSection` (menu bar icon, what reopening does) | General |
| `AppShellUpdatesSettingsSection` | General |
| `AppShellIslandLinksSettingsSection` (fallback links) | Island |
| `AppShellPermissionsSettingsSection` | System |
| `AppShellExtrasLinksSettingsSection` (fallback links) | Extras |
| `AppShellLookSettingsSection` | Appearance |
| `AppShellAccessibilityStatusSection` | Accessibility |
| `AppShellAutomationSettingsSection` | Advanced |
| `AppShellDiagnosticsSettingsSection` | Advanced |
| `AppShellResetSettingsSection` (with the uninstall guide) | Advanced |

Other surfaces:

- **Gear menu:** `AppShellMenuItems` (Settings…, Check for Updates…, Troubleshooting ›, About SparkV, Quit SparkV), plus `AppShellTroubleshootingMenuItems` on its own.
- **Right-click on the open island:** `AppShellContextMenuItems`.
- **Agents hub tile:** `SettingsHubTile`, category **System**.
- **Hotkeys:** none global. The main menu (installed in `applicationWillFinishLaunching`) has ⌘, Settings and ⌘Q Quit, enabled only while SparkV is the active app (`NSApp.isActive`), so they never take ⌘, or ⌘Q from another app. It also has ⌘W Close and ⌘M Minimize, which act only on closable SparkV windows and never on the island, and the standard Edit keys (⌘Z ⌘X ⌘C ⌘V ⌘A), which reach SparkV's own text fields. There are no Hide items, because hiding SparkV would hide the island. None of these clash with ⌃⌥J ⌃⌥R ⌃⌥S ⌃⌥T ⌃⌥⇧R ⌃⌥C ⌥Space ⌘⇧V ⌘1–9V.

## 1. build.sh: compile the folder

File: `build.sh`

Find:
```zsh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```

Replace with:
```zsh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/AppShell/*.swift "$WORK/src/"
```

The module imports MetricKit, ServiceManagement, Security and UniformTypeIdentifiers. All of them autolink, so no flags are needed.

## 2. build.sh: debug symbols for crash reports

`-g` doesn't slow `-O` code. With `-g`, swiftc writes `SparkV.dSYM` next to the binary, inside `Contents/MacOS`, where it would break codesign. That already happens today for `./build.sh debug`. Step 3 moves it to `build/symbols/<version>-<build>/`, so `.ips` reports can be symbolicated with `atos -o build/symbols/1.0-1/SparkV.dSYM/Contents/Resources/DWARF/SparkV -arch arm64 -l <load address> <addresses>`.

File: `build.sh`

Find:
```zsh
OPT_FLAGS=(-O)
```

Replace with:
```zsh
OPT_FLAGS=(-O -g)
```

## 3. build.sh: move the symbols out, add the privacy manifest

File: `build.sh`

Find:
```zsh
cp Info.plist "$STAGED/Contents/Info.plist"
```

Replace with:
```zsh
# Debug symbols stay outside the app, one folder per version and build.
SYMBOLS="build/symbols/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
mkdir -p "$SYMBOLS"
if [[ -d "$STAGED/Contents/MacOS/SparkV.dSYM" ]]; then
  rm -rf "$SYMBOLS/SparkV.dSYM"
  mv "$STAGED/Contents/MacOS/SparkV.dSYM" "$SYMBOLS/SparkV.dSYM"
  dwarfdump --uuid "$SYMBOLS/SparkV.dSYM" | sed 's/^/symbols: /'
fi

cp Info.plist "$STAGED/Contents/Info.plist"
# Privacy manifest: no tracking, no data collected, required-reason APIs.
cp Packaging/PrivacyInfo.xcprivacy "$STAGED/Contents/Resources/PrivacyInfo.xcprivacy"
```

## 4. build.sh: the fan helper's symbols

File: `build.sh`

Find:
```zsh
cp Helpers/FanHelper/com.sparkv.fanhelper.plist
```

Replace with:
```zsh
if [[ -d "$STAGED/Contents/Library/LaunchServices/com.sparkv.fanhelper.dSYM" ]]; then
  rm -rf "$SYMBOLS/com.sparkv.fanhelper.dSYM"
  mv "$STAGED/Contents/Library/LaunchServices/com.sparkv.fanhelper.dSYM" "$SYMBOLS/"
fi
cp Helpers/FanHelper/com.sparkv.fanhelper.plist
```

`build/` is already git-ignored as build output. Keep `build/symbols` for every released build: `Packaging/release.sh` prints its UUID.

## 5. Info.plist: register sparkv:// (and the old notchisland:// meeting links)

File: `Info.plist`

Find:
```xml
	<key>UTExportedTypeDeclarations</key>
```

Replace with:
```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.sparkv.app</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>sparkv</string>
				<string>notchisland</string>
			</array>
		</dict>
	</array>
	<key>UTExportedTypeDeclarations</key>
```

This also makes the existing `sparkv://meeting/<id>` links in Reminders (MeetingWrapUp) and Spaces open Meeting Notes. `notchisland://` is accepted only for `meeting/<uuid>` links. Check the result with `plutil -lint Info.plist`.

## 6. NotchWindowController: state for "opened from the shell"

File: `Sources/NotchWindowController.swift`

Find:
```swift
    private var collapseTask: Task<Void, Never>?
```

Replace with:
```swift
    private var collapseTask: Task<Void, Never>?
    /// Opened from the menu bar icon, a sparkv:// link or a reopen: the
    /// drawer stays open until the pointer has been over it once (or 10 s).
    private var shellPinnedOpen = false
    private var shellPinEntered = false
    private var shellPinTask: Task<Void, Never>?
```

## 7. NotchWindowController: connect the shell in init

File: `Sources/NotchWindowController.swift`

Find:
```swift
        installMouseMonitors()
        observeSystemEvents()
```

Replace with:
```swift
        installMouseMonitors()
        observeSystemEvents()
        connectAppShell()
```

## 8. NotchWindowController: the shell's hooks

File: `Sources/NotchWindowController.swift`

Find:
```swift
    // MARK: - System events
```

Replace with:
```swift
    // MARK: - App shell (Settings window, menu bar icon, sparkv:// links)

    /// Lets the app shell open the drawer, post live activities, run the
    /// timer and Focus from sparkv:// links, and stop everything before a
    /// reset. Called once from init.
    private func connectAppShell() {
        let shell = AppShellController.shared
        shell.openDrawer = { [weak self] tab, reveal in self?.presentFromShell(tab: tab, reveal: reveal) ?? false }
        shell.closeDrawer = { [weak self] in self?.forceCollapse() }
        shell.toggleDrawer = { [weak self] in
            guard let self else { return }
            // Links only: never brings a hidden island back.
            if self.state.isExpanded { self.forceCollapse() } else { self.presentFromShell(tab: nil, reveal: false) }
        }
        shell.postActivity = { [weak self] activity in self?.activities.post(activity) }
        shell.dismissActivity = { [weak self] id in self?.activities.dismiss(id: id) }
        shell.prepareForReset = { [weak self] in
            guard let self else { return }
            await self.finishWorkBeforeQuit(timeout: .seconds(5))
            self.tearDown()
        }

        AutomationRouter.shared.actions = AutomationActions(
            startTimer: { [weak self] minutes in self?.timer.startTimer(minutes: minutes) },
            startPomodoro: { [weak self] in self?.timer.startPomodoro() },
            pauseTimer: { [weak self] in self?.timer.toggle() },
            resetTimer: { [weak self] in self?.timer.reset() },
            startFocus: { [weak self] minutes in
                guard let self, !self.focus.isActive else { return }
                var settings = self.focus.settings
                if let minutes { settings.focusMinutes = minutes }
                self.focus.startSession(using: settings)
            },
            endFocus: { [weak self] in self?.focus.end() },
            openMeeting: { [weak self] id in self?.meetingAssistant.openNotesWindow(meetingID: id) },
            // The color picker package sets this when it lands.
            pickColor: nil
        )
        // Harmless, visible switches other tools may flip
        // (sparkv://feature/<name>?on=1). Never camera, microphone or recording.
        let router = AutomationRouter.shared
        let media = media, hud = hud, power = power, timer = timer
        let meetings = meetings, notifications = notifications, downloads = downloads
        router.register(AutomationFeature(name: "now-playing", title: "Now Playing beside the notch",
                                          get: { media.showsInClosedNotch }, set: { media.showsInClosedNotch = $0 }))
        router.register(AutomationFeature(name: "hud", title: "Volume & Brightness HUD",
                                          get: { hud.isEnabled }, set: { hud.isEnabled = $0 }))
        router.register(AutomationFeature(name: "battery", title: "Battery & AirPods",
                                          get: { power.isEnabled }, set: { power.isEnabled = $0 }))
        router.register(AutomationFeature(name: "timer-activity", title: "Timer live activity",
                                          get: { timer.isEnabled }, set: { timer.isEnabled = $0 }))
        router.register(AutomationFeature(name: "meetings", title: "Meeting live activities",
                                          get: { meetings.isEnabled }, set: { meetings.isEnabled = $0 }))
        // Mirrors other apps' banners onto the island: a link may only turn it off.
        router.register(AutomationFeature(name: "notifications", title: "Notifications", allowsTurningOn: false,
                                          get: { notifications.isEnabled }, set: { notifications.isEnabled = $0 }))
        router.register(AutomationFeature(name: "downloads", title: "Downloads watcher",
                                          get: { downloads.isEnabled }, set: { downloads.setEnabled($0) }))

        // Settings sections that read @EnvironmentObject get the drawer's objects.
        SparkVSettingsWindowController.shared.environment = { [weak self] view in
            guard let self else { return view }
            return AnyView(view
                .environmentObject(self.state)
                .environmentObject(self.media)
                .environmentObject(self.macros)
                .environmentObject(self.camera)
                .environmentObject(self.tray)
                .environmentObject(self.dictation)
                .environmentObject(self.flow)
                .environmentObject(self.clicky)
                .environmentObject(self.activities)
                .environmentObject(self.hud)
                .environmentObject(self.power)
                .environmentObject(self.timer)
                .environmentObject(self.meetings)
                .environmentObject(self.notifications)
                .environmentObject(self.meetingAssistant)
                .environmentObject(self.liveTranslation)
                .environmentObject(self.meetingLive)
                .environmentObject(self.converter)
                .environmentObject(self.spacesIngest)
                .environmentObject(self.uiAudit)
                .environmentObject(self.jobAgent)
                .environmentObject(self.screenRegion)
                .environmentObject(self.screenRecorder)
                .environmentObject(self.promptRefiner)
                .environmentObject(self.browserRecorder)
                .environmentObject(self.clipboard)
                .environmentObject(self.screenDistance)
                .environmentObject(self.focus)
                .environmentObject(self.universalSearch)
                .environmentObject(self.quickCapture)
                .environmentObject(self.screenshotClipboard)
                .environmentObject(self.replyDrafter)
                .environmentObject(self.fileDrop)
                .environmentObject(self.downloads))
        }
    }

    /// Opens the drawer for the shell. The pointer is usually far from the
    /// notch then, so the drawer waits for it (10 s at most) instead of
    /// closing after the usual grace period. A hidden island (full screen,
    /// an excluded app, screen sharing, ⌃⌥H, Built-in Only with the lid
    /// closed) comes back for the moment only when `reveal` is set (the
    /// user clicked the menu bar icon or opened SparkV again), the way ⌃⌥H
    /// does; links never reveal it. False: nothing could be shown, and the
    /// shell falls back to Settings or reports "The island is hidden".
    @discardableResult
    private func presentFromShell(tab: NotchState.Tab?, reveal: Bool) -> Bool {
        guard !FaceUnlock.isUsingNotch else { return false }
        if visibility.isHidden {
            guard reveal else { return false }
            isRevealed = true
            applyVisibility()
            // Nothing to bring back (no display for it, another user).
            guard !visibility.isHidden else {
                isRevealed = false
                return false
            }
        }
        if let tab { state.select(tab) }
        collapseTask?.cancel()
        collapseTask = nil
        setExpanded(true)
        shellPinnedOpen = true
        shellPinEntered = false
        shellPinTask?.cancel()
        shellPinTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.shellPinnedOpen, !self.shellPinEntered else { return }
            self.shellPinnedOpen = false
            if !self.isPointerInHotZone(), !self.isInteractionInProgress { self.setExpanded(false) }
        }
        return true
    }

    /// Right-click on the closed island: the shell menu at the pointer. Only
    /// over the camera housing of a notched screen, where no menu bar item
    /// sits underneath (a global monitor can't swallow the click).
    private func showShellMenuIfOverIsland() {
        guard !state.isExpanded, !FaceUnlock.isUsingNotch,
              geometry?.hasNotch == true, visibility.isOnScreen, !visibility.ignoresHover,
              notchRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
        AppShellIslandMenu.popUp(at: NSEvent.mouseLocation)
    }

    // MARK: - System events
```

## 9. NotchWindowController: keep a shell-opened drawer open until visited

File: `Sources/NotchWindowController.swift`

Find:
```swift
        if isPointerInHotZone() {
            collapseTask?.cancel()
            collapseTask = nil
```

Replace with:
```swift
        if isPointerInHotZone() {
            collapseTask?.cancel()
            collapseTask = nil
            if shellPinnedOpen { shellPinEntered = true }
```

File: `Sources/NotchWindowController.swift`

Find:
```swift
        } else {
            endThemeHover()
            if !state.isExpanded {
                setRestingRevealed(false)
                scheduleRevealEnd()
            }
            if state.isExpanded, collapseTask == nil {
```

Replace with:
```swift
        } else {
            endThemeHover()
            if !state.isExpanded {
                setRestingRevealed(false)
                scheduleRevealEnd()
            }
            // Opened from the menu bar icon or a link: wait for the pointer.
            let waitingForPointer = shellPinnedOpen && !shellPinEntered
            if !waitingForPointer { shellPinnedOpen = false }
            if state.isExpanded, collapseTask == nil, !waitingForPointer {
```

File: `Sources/NotchWindowController.swift`

Find:
```swift
        if !expanded {
            themeHover.isHovered = false
```

Replace with:
```swift
        if !expanded {
            shellPinnedOpen = false
            shellPinTask?.cancel()
            shellPinTask = nil
            themeHover.isHovered = false
```

## 10. NotchWindowController: right-click on the closed island, cleanup

File: `Sources/NotchWindowController.swift`

Find:
```swift
        // Local monitors only see events delivered to our own panel.
```

Replace with:
```swift
        // Right-click on the closed island: version, Settings, About, Quit.
        if let rightClick = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.showShellMenuIfOverIsland() }
        }) {
            eventMonitors.append(rightClick)
        }

        // Local monitors only see events delivered to our own panel.
```

File: `Sources/NotchWindowController.swift`

Find:
```swift
        faceUnlockWatch?.cancel()
        faceUnlockWatch = nil
        camera.stop()
```

Replace with:
```swift
        faceUnlockWatch?.cancel()
        faceUnlockWatch = nil
        shellPinTask?.cancel()
        shellPinTask = nil
        camera.stop()
```

The right-click monitor goes into `eventMonitors`, so `tearDown()` already removes it.

## 11. NotchNookLayoutView: gear menu and right-click on the open island

File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
            Button("Quit SparkV") { NSApp.terminate(nil) }
```

Replace with:
```swift
            AppShellMenuItems()
```

This puts Settings…, Check for Updates… (or "Update Available: SparkV x…"), Troubleshooting › (Crash & Hang Reports…, Export Diagnostics…, Automation Guide…, Reset SparkV…, Uninstall SparkV…), About SparkV and Quit SparkV at the bottom of the gear menu. Quit still goes through `applicationShouldTerminate`.

File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
                    HeaderRow()
```

Replace with:
```swift
                    HeaderRow()
                        // Right-click: version, Settings, updates, About, Quit.
                        .contextMenu { AppShellContextMenuItems() }
```

The drawer's `isMenuTracking` (NSMenu.didBeginTracking) already keeps it open while the menu shows.

## 12. AgentsHubView: the Settings tile (category System)

File: `Sources/AgentsHubView.swift`

Find:
```swift
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```

Replace with:
```swift
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
            // App shell: opens Settings; a dot marks an available update.
            HubPackageTile(info: HubTileInfo(id: "settings", title: "Settings", systemImage: "gearshape.fill",
                                             tint: Color(white: 0.72), category: .system,
                                             help: "Settings (⌘, while SparkV is in front)"),
                           pinAction: { SparkVSettings.show() }) { AnyView(SettingsHubTile()) },
```

`SettingsHubTile` is the hub's own `AgentTile` with the update dot as an overlay and no menu of its own, so the hub cell's Pin / Hide / Move items (`HubTileMenuItems`) apply. Other packages add their entries next to it; keep the comment line as the anchor.

## Optional (not applied by the validation)

- **Onboarding privacy text:** add one line, for example "Update checks (GitHub) and sparkv:// automation are off until you turn them on in Settings."
- **Homebrew tap:** create `github.com/koushik1133/homebrew-sparkv`, copy `Packaging/homebrew/sparkv.rb` to `Casks/sparkv.rb`, then release with `Packaging/release.sh <version>`. It runs PlistBuddy, `build.sh`, `notarize.sh`, `gh release create`, and updates the cask's version and sha256. Users install with `brew install --cask koushik1133/sparkv/sparkv`. Ship only notarized builds.
- **Color picker:** the color picker package sets `AutomationRouter.shared.actions.pickColor = { … }` to make `sparkv://color-picker` work.
- **Other features:** any package can expose a harmless switch with `AutomationRouter.shared.register(AutomationFeature(name:title:get:set:))`.

## UserDefaults keys (prefix `AppShell.`)

| Key | Default | Meaning |
|---|---|---|
| `AppShell.settings.lastPane` | general | pane the Settings window reopens on |
| `AppShell.statusItem.visible` | false | menu bar icon |
| `AppShell.reopen.action` | settings | what opening SparkV again does (`settings` / `drawer`) |
| `AppShell.updates.automatic` | false | daily update check (contacts api.github.com) |
| `AppShell.updates.betas` | false | include pre-releases |
| `AppShell.updates.lastCheck` / `skippedVersion` / `notifiedVersion` | | check bookkeeping |
| `AppShell.diagnostics.metricKit` | true | save MetricKit diagnostics locally |
| `AppShell.automation.enabled` | false | allow sparkv:// links that change state |

Window frames: `SparkV.Settings`, `SparkV.SoftwareUpdate`, `SparkV.Diagnostics`, `SparkV.AutomationGuide`. Files: `~/Library/Application Support/SparkV/Diagnostics/metrickit-*.json`.

## Energy

Nothing polls. Automatic update checks use `NSBackgroundActivityScheduler` (once a day, system-timed) only while the switch is on; a failed automatic check schedules one system-timed retry about 90 minutes later. The log rotates at launch, on `NSWorkspace.didWakeNotification` and before an export. Rate-limited links are delivered by one short-lived task per key, cancelled in `stop()`. MetricKit delivers payloads by itself. Diagnostic folders are read only when the report list opens. The login-item status refreshes on app activation, and accessibility statuses on `accessibilityDisplayOptionsDidChangeNotification`. The status item exists only while it is turned on. The right-click monitor shares the controller's monitor list and is removed in `tearDown()`.
