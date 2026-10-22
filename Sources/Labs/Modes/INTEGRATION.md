# SparkV Modes: integration

Modes are one-tap setups such as Concentration, Study, Relax, Meeting, Presentation and Night. Each one changes the wallpaper, starts music in a background Safari window, turns Do Not Disturb on, hides or quits apps, sets volume, brightness and appearance, and starts a Pomodoro. Ending the mode puts everything back. The approach copies proven products:

- **Apple Focus filters.** Settings apply while the mode is on and revert on their own when it ends.
- **Session and Tuple.** Do Not Disturb runs through two user-made Shortcuts ("Set Focus" is Apple's only supported path since macOS 12).
- **Keyboard Maestro macro groups and Bartender presets.** Each mode is an ordered list of steps the user can edit.
- **System Settings › Focus.** The editor copies its layout: a sidebar of modes, and for each one what happens when it turns on and when it ends.

This one file covers the engine, the UI and the music/wallpaper parts. (It replaces INTEGRATION-UI.md and INTEGRATION-MUSIC.md.) Every Swift snippet below was typechecked against the current NotchWindowController, FocusController, NotificationMonitor, ActivityCenter, ScreenRegionHotkey and AppDelegate types, in Swift 6 and Swift 5.

## Files

| File | What it holds |
|---|---|
| `ModeModels.swift` | `SparkMode`, `ModeAction` (+ `title`, `symbol`, `detail`, `kind: ModeStepKind`), `ModeWallpaperChoice`, `ModeMusicChoice`, `ModeActionFailure`, `ModeAppNames` |
| `ModeSystem.swift` | `protocol ModeSystem` (every side effect), `LiveModeSystem.shared`, `ModeFocusHooks`, `ModeDoNotDisturbNames`, CoreAudio / DisplayServices / osascript helpers |
| `ModeStore.swift` | `ModeStore` (JSON in `~/Library/Application Support/SparkV/Modes/`), `ModeLibraryFile` (versioned), `ModeSnapshot` |
| `ModeEngine.swift` | `ModeEngine.shared`: activate, deactivate, toggle, auto-end, crash recovery, editing |
| `ModePresets.swift` | The six built-in modes, with fixed UUIDs |
| `ModeWallpapers.swift` | `ModeWallpaperFactory`: solid and gradient PNGs at native resolution, presets, file validation |
| `ModeMusic.swift` | `ModeMusicPlayer` (background Safari window, Music playlist or AVPlayer stream), `ModeMusicLibrary` |
| `ModeViews.swift` | `ModesHubTile`, `ModesDrawerView`, `ModesMenuItems`, `ModeActivityView`, `ModeBadge`, `ModeColors`, `ModeStatusText` |
| `ModeEditorWindow.swift` | `ModeEditorWindowController.shared` and the editor |

`ModeStepKind` is the engine's enum of action kinds.

## 1. build.sh

Add this next to the other Labs lines:

```sh
cp Sources/Labs/Modes/*.swift "$WORK/src/"
```

Only the `.swift` files are copied; the `.md` files stay out of the build.

## 2. NotchWindowController

Add the following at the end of `init`, after `focus.start()` (so a restored focus session exists before the engine checks whether to end it). `focus`, `notifications` and `activities` are the controller's existing properties.

```swift
let modes = ModeEngine.shared

// Lets modes use SparkV's Focus feature and notification previews.
LiveModeSystem.shared.focusHooks = ModeFocusHooks(
    startSession: { [weak focus] focusMinutes, breakMinutes in
        guard let focus, !focus.isActive else { return false }
        let saved = focus.settings
        var s = saved
        if let focusMinutes { s.focusMinutes = focusMinutes }
        if let breakMinutes { s.shortBreakMinutes = breakMinutes }
        focus.startSession(using: s)
        // The session captured its plan, so the user's own settings come back.
        if focusMinutes != nil || breakMinutes != nil { focus.settings = saved }
        return true
    },
    endSession: { [weak focus] in focus?.end() },
    isSessionActive: { [weak focus] in focus?.isActive ?? false },
    previewsEnabled: { [weak notifications] in notifications?.isEnabled },
    setPreviewsEnabled: { [weak notifications] in notifications?.isEnabled = $0 },
    doNotDisturbShortcuts: { [weak focus] in
        (focus?.settings.dndOnShortcut ?? ModeDoNotDisturbNames.on,
         focus?.settings.dndOffShortcut ?? ModeDoNotDisturbNames.off)
    }
)

// The live activity while a mode is on. The engine calls this when a mode
// starts, about once a minute while it runs (the text changes), and with nil
// when it ends. Reposting the same id updates it in place, so the compact
// wings show the mode's symbol and "42 min" / "18 min left"; the peekKey
// makes the band ("Concentration on · 42 min") show briefly when a mode starts
// or a different mode takes over.
modes.onActivityText = { [weak activities] text in
    guard let activities else { return }
    let engine = ModeEngine.shared
    guard text != nil, let mode = engine.activeMode else { activities.dismiss(id: "mode"); return }
    activities.post(LiveActivity(
        id: "mode", kind: .timer, priority: 20, duration: nil,
        symbol: mode.symbol, tint: ModeColors.color(mode.colorHex),
        compactText: ModeStatusText.text(since: engine.activeSince, endsAt: engine.endsAt),
        peekKey: mode.id.uuidString
    ) {
        ModeActivityView()
    })
}

// At launch: undoes a mode that was still on when SparkV crashed or was force
// quit (including closing the music window it had opened in Safari).
Task { await modes.start() }
```

Optional, for music left behind without a mode snapshot (e.g. the editor's Test button was playing when SparkV crashed): `Task { await ModeMusicPlayer().cleanUpOrphans() }` after `modes.start()`.

Notes:

- `.timer` is used because `LiveActivity.Kind` has no `.mode` case. Adding `case mode` (symbol `switch.2`, tint `.indigo`) is fine too.
- Concentration and Study start a SparkV Focus session (Pomodoro), whose band has priority 21. While it runs, the Focus timer shows instead of the mode band; the mode band comes back when the Pomodoro ends. That is intended: the timer is the more useful one.
- `ModeActivityView` is laid out for the standard 30 pt band (about 360 pt wide). It redraws itself every 30 s and shows "Setting up…" while the engine applies the mode, and an orange warning icon (with the failed steps as its tooltip) if a step failed.

## 3. AppDelegate: restore on quit

`AppDelegate` has no `applicationShouldTerminate` yet. `applicationWillTerminate` cannot wait for async work, so add this (the SIGTERM handler already calls `NSApp.terminate`, so `kill` and logout go through it too):

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard ModeEngine.shared.activeModeID != nil else { return .terminateNow }
    Task { @MainActor in
        // Puts the wallpaper, volume, apps and Do Not Disturb back. If this takes
        // longer than 5 s, SparkV quits anyway and the next launch restores it.
        let restore = Task { await ModeEngine.shared.prepareForQuit() }
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { await restore.value }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            await group.next()
            group.cancelAll()
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
}
```

## 4. UI in the notch

| View | Where it goes | Size |
|---|---|---|
| `ModesHubTile(onOpen:)` | Agents hub grid | 54 pt tall like `FocusHubTile`; the label fits a 51 pt (9-column) tile |
| `ModesMenuItems()` | Inside `Menu("Modes") { … }` in the gear menu | Menu items |
| `ModesDrawerView()` | Optional drawer page | Exactly 508 x 69 pt |
| `ModeActivityView()` | Body of the live activity (section 2) | 360 x 30 pt band |
| `ModeEditorWindowController.shared.show()` / `.show(selecting: id)` | The editor window | 820 x 640, min 720 x 520, resizable |

Every view reads `ModeEngine.shared` by default and also takes `engine:`, so a harness can pass an engine built on a fake `ModeSystem`.

### 4a. Agents hub (AgentsHubView.swift)

The grid is full: 8 columns x 2 rows fill the 508 x 114 pt content area, and `cells` already has 16 entries. A 17th cell would start a third row that doesn't fit. Pick one:

- **Recommended:** set `static let columns = 9` (tiles become about 51 pt wide; 18 slots for 17 cells), then add the Modes cell next to Focus:

  ```swift
  // In `enum Cell`: case modes   (and `case .modes: "modes"` in `id`)
  // In `cells`, right after `.focus`:
  .modes,
  // In the ForEach switch:
  case .modes:
      ModesHubTile()  // one click lists the modes; pick one to switch, or Stop / Edit Modes…
  ```

  Check the other tiles' labels at 51 pt after the change ("Translate On" and "Downloads" are the longest; `AgentTile` shrinks text to 80 %).
- Or give a cell's spot to Modes (e.g. drop the "Canvas" agent tile, which is also in the gear menu under Agents).

With a Modes drawer page (4c), use `ModesHubTile(onOpen: { withAnimation(.easeOut(duration: 0.15)) { state.select(.modes) } })`. The mode list then moves to the tile's right-click menu.

### 4b. Gear menu (NotchNookLayoutView.swift)

Put this right after `Menu("Focus") { … }`:

```swift
Menu("Modes") { ModesMenuItems() }
```

It has one checkable item per mode (checked = on; picking another mode switches), then "Stop <Mode>" while one is on, then "Edit Modes…".

### 4c. Optional drawer page

`ModesDrawerView()` is exactly 508 x 69 pt, the standard drawer content area (115 pt drawer), so it needs no change to `NotchMetrics.expandedSize(for:)`. It needs:

1. `case modes` in `NotchState.Tab`, and `.modes` in `Tab.agentTabs` (it is opened from the hub).
2. `case .modes: ModesDrawerView()` in `NotchNookLayoutView.tabContent`.
3. The hub tile with `onOpen` (4a).

It shows six 66 x 58 pt chips; a click turns that mode on or off, and right-click offers Turn On/Off and "Edit <Mode>…". A seventh mode and beyond scroll sideways (the next chip shows cut off at the edge). On the right: a Stop button in the mode's colour with the elapsed or remaining time while a mode is on, otherwise an Edit button.

### 4d. The editor

`ModeEditorWindowController.shared.show()` opens it; the gear menu, the hub tile menu and the drawer all call it. While it is open the app switches to `.regular` (Dock icon, key window) and back to `.accessory` when it closes, like `FocusSettingsWindowController`.

- Sidebar: the modes, with "On" next to the active one. Bottom bar: + (new), − (delete, asks first), duplicate, and a ⋯ menu with Move Up/Down, "Reset <Mode> to Original" for built-in modes, and "Restore All Built-in Modes".
- Detail: big icon (click for Icon & Color), editable name, Turn On / Turn Off.
- "When <Mode> turns on": the ordered actions. Each row opens its own editor and has move up/down and remove. "Add Action" is a grouped menu; one-per-mode kinds (wallpaper, music, volume, …) are greyed out once added.
- "When it ends": "Put my setup back" (`restoreOnExit`) and "End automatically" with a 15-minute stepper (`autoEndMinutes`).
- Per-action editors: a live mini-desktop wallpaper preview with the five presets plus Color, Gradient and Image… (stacked under the preview at the minimum window width); a music card with Choose… (library by category, or Custom URL), "Keep Safari in the background" and Test/Stop; sliders for volume and brightness; On/Off for Do Not Disturb, previews and appearance; Pomodoro steppers; app chips with icons and an Add menu (apps open now, or choose from /Applications; Hide also offers "All Other Apps"); Quit Apps lists apps already approved to quit without asking, each with "Ask Again"; a list of links; a shortcut name with a Choose menu from `shortcuts list`.
- Every change saves at once through `engine.update(_:)` (the engine writes `modes.json`) and applies the next time the mode turns on.
- The Test button uses the editor's own `ModeMusicPlayer()`, so it never touches the active mode's Safari window, and closing the editor stops it.
- Engine errors and the active mode's failed steps show at the bottom in orange, with Dismiss.

## 5. Hotkeys (optional)

Control+Option+1 through 5 toggle the first five modes in sidebar order, using the same `ScreenRegionHotkey` (Carbon `RegisterEventHotKey`) the other Labs use. It needs no permission. NotchWindowController needs `import Carbon.HIToolbox` and a `private var modeHotkeys: [ScreenRegionHotkey] = []` property to keep them alive:

```swift
for (index, keyCode) in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].enumerated() {
    let hotkey = ScreenRegionHotkey()
    hotkey.onPress = {
        let engine = ModeEngine.shared
        guard engine.modes.indices.contains(index) else { return }
        Task { await engine.toggle(engine.modes[index].id) }
    }
    if !hotkey.register(ScreenRegionShortcut(keyCode: UInt32(keyCode), carbonModifiers: UInt32(controlKey | optionKey))) {
        AppLog.log("Modes: Control+Option+\(index + 1) is taken by another app")
    }
    modeHotkeys.append(hotkey)
}
```

Control+Option+S, T, C, R, F and Space are already taken in SparkV, and the Clipboard's digit shortcuts use Command, so Control+Option+digits are free. If they are added, show them in `ModesMenuItems` titles or the hub tile's help text.

## 6. Info.plist

Append this sentence to `NSAppleEventsUsageDescription` (the `com.apple.security.automation.apple-events` entitlement is already there):

> During a Mode, SparkV opens your chosen music in its own Safari window (or plays a playlist in Music) and closes only that window when the mode ends, and switches between light and dark appearance through System Events.

The first time a mode uses each app, macOS asks for Automation consent: Safari (music), Music (only for `music-playlist:` choices) and System Events (dark mode). If the user says no, that step fails with a message naming System Settings › Privacy & Security › Automation › SparkV, and the rest of the mode still runs.

## Engine behavior

- **Order.** Actions run top to bottom in the order shown in the editor. Restoring walks the applied steps backwards. For example, Concentration stops the Pomodoro, then the music, then puts back volume, wallpaper and hidden apps, and turns Do Not Disturb off last.
- **Snapshot first.** `active-snapshot.json` is written before anything changes, and again after every step. Each value is captured the first time a step touches it:
  - wallpaper and its scaling, clipping and fill color, for each screen
  - output volume, appearance and brightness
  - the apps the mode hid (apps that were already hidden are left alone)
  - the apps the mode quit, so they can be reopened in the background
  - whether the mode turned Do Not Disturb on, and with which off shortcut
  - whether it started music or a focus session
  - the SparkV previews setting

  A crash mid-activation or mid-restore is undone at the next `start()`. The engine then sets `lastError` to "Concentration was still on when SparkV quit, so your previous setup was restored."
- **Switching.** Activating a mode while another is on fully restores the first mode, then applies the second.
- **restoreOnExit.** Music, the focus session, Do Not Disturb and muted previews always end with the mode. With `restoreOnExit == false`, the wallpaper, volume, appearance, brightness and hidden or quit apps stay as the mode left them.
- **Failures.** Every step is caught on its own. `failures` lists each one, `lastError` gives a one-line summary such as "Concentration is on, but 2 steps didn't work: …", and the remaining steps still run. Restore failures are collected the same way, and the mode still ends.
- **Do Not Disturb.** The engine runs the shortcuts named in the user's Focus settings (default "SparkV Focus On" / "SparkV Focus Off", the same ones `FocusMuter.swift` uses). It checks them against `shortcuts list`, and falls back to common pairs (dnd-on/dnd-off, session_start/session_end, …). If they are missing, the step fails with a message naming both shortcuts and pointing to Focus settings. A "Do Not Disturb off" step with no shortcuts set up is skipped quietly, so Relax doesn't show an error.
- **Quitting apps.** The first time a mode quits an app, the user is asked with an NSAlert: "Quit Slack when Concentration starts?". Approval is remembered per bundle ID in `modes.json` (`quitApprovals`, `forgetQuitApproval(_:)`, shown in the editor with "Ask Again"). Apps get a normal `terminate()` and are never force quit. SparkV, Finder and loginwindow are never quit.
- **Hide everything.** `.hideApps([ModeAction.allOtherApps])` hides every regular app except the frontmost one and SparkV (used by Presentation).
- **Focus session.** `.pomodoro` and `.focusSession` leave a session the user started alone, and only end sessions the mode started.
- **Auto-end.** `autoEndMinutes` sets `endsAt`. A 30 s ticker checks the deadline (so it catches up after sleep) and refreshes `onActivityText` ("Meeting on · 18 min left", or "Concentration on · 42 min" with no deadline).
- **Serialized.** `activate`, `deactivate`, `toggle` and auto-end run one at a time. `isBusy` is true while a mode is being applied or restored (the editor's Turn On button shows "Working…").
- **Persistence.** `modes.json` is `{version: 1, modes, approvedQuitApps, seededBuiltIns}`. Decoding is lenient: a damaged mode or an unknown action type is skipped. An unreadable file is renamed to `modes.damaged-<time>.json` and never deleted, and the presets load in its place. A built-in mode the user deletes stays deleted. `resetBuiltIns()` and `resetBuiltIn(_:)` put presets back. Presets added in later versions appear once.
- **Values.** `volume(_:)` and `brightness(_:)` take values from 0 to 1, so 0.35 means 35 %.

## Built-in modes

| Mode | Steps |
|---|---|
| Concentration | Do Not Disturb on, hide Slack/Messages/Mail, black wallpaper, volume 35 %, Lofi Girl in background Safari, Pomodoro 50/10 |
| Study | Do Not Disturb on, deep navy wallpaper, volume 30 %, classical study mix (Mozart), Pomodoro 25/5 |
| Relax | Do Not Disturb off, warm sunset gradient, volume 25 %, rainstorm sounds |
| Meeting | Do Not Disturb on, mute SparkV previews, hide Music, open Calendar, auto-end after 60 min |
| Presentation | Do Not Disturb on, mute previews, hide everything except the front app, minimal grey wallpaper |
| Night | Dark appearance, brightness 40 % |

The preset music links (rFZHOHl-L8A, 3AkZazth0a0, yIQd2Ya0Ziw) are entries of `ModeMusicLibrary`, so the editor shows them as library cards and the player has their alternates if a stream ends.

## Wallpapers (ModeWallpapers.swift)

- `ModeWallpaperFactory.imageURL(for: choice, screen: pixelSize) throws -> URL`
  - `.solid` and `.gradient` are drawn at the exact pixel size (gradients top to bottom, with an 8x8 ordered dither so dark ramps don't band) and cached as `~/Library/Application Support/SparkV/Modes/Wallpapers/sparkv-wallpaper-<sha256>.png`. A different colour or size gives a new file, so `setDesktopImageURL` always sees a new URL.
  - `.builtIn(id)` presets: `black`, `navy`, `forest`, `sunset`, `grey`. Lookup ignores case and punctuation, so `pureBlack`, `deepNavy`, `warmSunset` and `Minimal Gray` also work. Navy is a solid `#0B1A33`, forest a gradient `#16302B` → `#08140F`, sunset a gradient `#FF7E5F` → `#FEB47B`.
  - `.file(path)` must be an absolute (or `~`) path to a readable regular file that ImageIO can decode. It is returned unchanged and never copied. Errors are `ModeWallpaperError`, each with a sentence the user can read.
  - Thread-safe. A first 5K render takes about 0.5 to 1 s (PNG encoding); cache hits return at once.
- `ModeWallpaperFactory.desktopOptions(for:)`: fill the screen with clipping, plus `.fillColor` for colours.
- For the editor: `presets` (id, name, symbol), `title(for:)`, `swatchColors(for:)` and `previewImage(for:size:)`. The editor's tiles use `presets` and `preset(id:)?.rendering`, so previews match the rendered PNGs.
- Optional housekeeping: `ModeWallpaperRenderer(directory: ModeWallpaperFactory.defaultDirectory).pruneCache(keepingNewest: 40, protecting: currentDesktopURLs)` removes only `sparkv-wallpaper-*.png` files in that folder.

## Music (ModeMusic.swift)

- `ModeMusicPlayer` (`@MainActor`, `ObservableObject`): `start(_:) async throws`, `stop() async`, `test(_:)`, `cleanUpOrphans()`, and published `isPlaying`, `current` and `statusText`.
- Each player instance owns its own music, so the mode's player and the editor's Test player never close each other's windows. Sessions are saved in UserDefaults under `SparkV.Modes.MusicSessions` with SparkV's pid; music left by an earlier SparkV process is closed by the next `start`/`stop` or `cleanUpOrphans()` (the engine's crash recovery calls it when it restores a mode that played music).
- Sources, chosen by `ModeMusicSource.parse(url)`:
  - YouTube or any web page: opens in a new Safari window. If Safari isn't running it is launched with `activates = false`. SparkV records the window ids before and after `make new document`, so it knows which window it made, and gives focus back to the app that had it. About 6 s later it starts the video with JavaScript (only if Safari allows JavaScript from Apple Events; otherwise this fails harmlessly), then minimizes the window unless the user brought it forward.
  - Stop closes a window that holds only SparkV's tab; if the user added tabs, only the tabs showing SparkV's video. If Safari was restarted (different pid, so window ids were reused) it sends nothing. Safari is never quit or launched by stop.
  - `music-playlist:Name`: plays that playlist in Music (launched hidden). Stop pauses only if Music is still playing that playlist, then puts Music's volume back.
  - Direct audio (`.mp3 .aac .m4a .wav .aiff .caf .flac .m3u8`, http(s) or a local file): plays in-process with AVPlayer.
- Each YouTube link is checked with oEmbed at start. An ended live stream (200 with no title) counts as gone, and the library entry's main URL and alternates are tried. Offline, the link plays anyway.
- Autoplay: Safari's default per-site setting can block autoplay with sound. When the JavaScript check finds the video paused, `statusText` becomes `ModeMusicPlayer.autoplayHint` (shown under the editor's Test button). The fix is Safari › Settings for youtube.com › Auto-Play › Allow All Auto-Play.
- Errors are `ModeMusicError`; `.automationDenied(app:)` (OSA -1743/-1744) says where to allow it, `.unavailable` means the video and all alternates are gone.
- Library: `ModeMusicLibrary.entries` (curated Lofi Girl radios, Chillhop, deep focus, classical, jazz, rain and brown noise, with category, symbol and alternates), `all`, `lofiStudy`, `classicalStudy`, `rainSounds`, `deepFocus`, and `customChoice(url:title:)` for a pasted link. Every URL returned oEmbed 200 with a title on 2026-10-21.

## Known limits

- `setDesktopImageURL` changes the current Space only. Other Spaces keep their wallpaper, and restore puts back what was captured for the current Space.
- An Aerial or "Dynamic" system wallpaper comes back as its still image path.
- With "Auto" appearance, restoring sets the light or dark appearance that was showing. Turning "Auto" back on isn't scriptable.
- Brightness works on the built-in display only.
- Do Not Disturb has no readable state, so the engine only turns it off on exit if the mode turned it on.
- Whether YouTube autoplays in a background Safari window depends on Safari's per-site Auto-Play setting.

## What the user does once

1. Create the two Shortcuts the Focus feature already uses, if they don't exist: "SparkV Focus On" (Set Focus › Do Not Disturb › Turn On) and "SparkV Focus Off" (Turn Off).
2. Allow SparkV to control Safari and System Events when macOS asks (System Settings › Privacy & Security › Automation).
3. If study music doesn't start, set Safari › Settings for youtube.com › Auto-Play to "Allow All Auto-Play". Optionally turn on Safari's Develop › "Allow JavaScript from Apple Events" so SparkV can start the video and detect a paused one.

## Tests

None of these touch the real wallpaper, volume, Do Not Disturb, appearance, Safari or apps. All live in `/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/modes/`.

- `engine/run-tests.sh` (`SV=5` for Swift 5): drives `ModeEngine` with `RecordingModeSystem`: apply order and exact reverse restore, switching, crash recovery (also mid-apply), auto-end, per-action failures, missing and alternate Do Not Disturb shortcuts, the quit confirmation, restoreOnExit off, hide-all-others, first captured value wins, versioned and damaged-file persistence, editing, serialized calls, activity text.
- `wallpaper-music/harness` (`build.sh`, then `./wmtest`, `--network` for the oEmbed check): wallpaper rendering, sizes, colours, cache, pruning and path validation; every music side effect through a recording fake; all generated AppleScripts compiled with `osacompile` against copies of Safari's and Music's sdef.
- `validate-ui/run.sh [6|5]`: the editor model and views against a real `ModeEngine` on a fake system (add/remove/reorder actions, one-per-mode kinds, new/duplicate/delete/move/reset modes, edits saved to `modes.json`, toggling from chips), exact sizes (drawer 508 x 69, chips 66 x 58, hub tile 54 pt, band 360 x 30), no horizontal overflow at the editor's 720 pt minimum for every action editor, and offscreen renders in `validate-ui/out/`. `validate-ui/tc.sh 6|5` (with `PROBE=1`) typechecks the whole app plus this folder and the snippets in this file.

## Validator notes (engine, system, music, presets)

Changes made while validating, all inside Sources/Labs/Modes:

- `ModeSystem` has three new requirements with protocol-extension defaults (so existing fakes still compile): `renderWallpaperImage(for:size:) async` (the live one renders off the main thread), `outputMuted()` and `setOutputMuted(_:)`. A mode that sets a volume unmutes the output; ending the mode mutes it again if it was muted before (`ModeSnapshot.volumeWasMuted`).
- `LiveModeSystem` tracks the last frontmost app other than SparkV, so "Hide all but the front app" started from SparkV's own window keeps the user's app instead of hiding everything. Create `LiveModeSystem.shared` (it is, via `ModeEngine.shared`) at launch so the tracking starts early.
- `activate`/`toggle` run `start()` first if it hasn't run, so a crash snapshot is restored before a new mode could overwrite it. Still call `start()` at launch after the focus hooks are set.
- `ModeStore`: a `modes.json` that exists but can't be read is renamed aside (unique name), or, if renaming fails, left untouched with saving off for that run (`libraryLocked`). A file from a newer SparkV is copied to `modes.v<N>-backup.json` before this version saves over it.
- Presets use the current library streams (Lofi Girl `rFZHOHl-L8A`, HALIDONMUSIC Mozart, Calm rainstorm) so the player's alternates apply. `ModeMusicPlayer` maps ended-stream links (`formerURLs`) to the current stream before any network check.
- Stopping music: a single-tab SparkV window is closed only while it still shows SparkV's video or the same site; if the user navigated it elsewhere it is left open.
- Empty Do Not Disturb shortcut names fall back to "SparkV Focus On"/"SparkV Focus Off".
