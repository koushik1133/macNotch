# System Status: wiring steps for the integrator

Battery status and actions, accessory batteries, privacy indicators, keep awake, quick toggles, connection alerts, a global mic mute and a Caps Lock indicator.

Code lives in two places:
- `Sources/PowerMonitor.swift` (edited in place) and `Sources/PowerActivityView.swift` (unchanged from the repo). `BatteryActivityMode` has six cases including `.critical`, which Activities' current `ActivityAnnouncementText.battery` already handles.
- `Sources/Labs/SystemStatus/` (new).

**Activities package, steps 6 and 7** (VoiceOver for the battery, the critical alert and AirPods) edit `PowerMonitor.swift`. Their three find-anchors are kept exactly in this version, so apply them as written, before or after these steps. Activities' Calls drive `MicMuteController` directly (the old `MicrophoneMute` is gone), so there is one mic mute.

Every step below is checked against the live repo (`/Users/koushikgoudshaganti/Developer/macNotch`, 1 Nov), and every find-anchor occurs exactly once there. Anchors were chosen so other pending packages (Activities, ColorPicker, DevStatus, FanControl, MediaPlus, Planner, SmartMoments) don't remove them: those packages only insert next to the same lines. The three edits that touch a line other packages also rewrite (2b, 2c, 6) are written as order-independent edits.

## What the package adds

| Requirement | What it does | How (all public API, event driven) |
| --- | --- | --- |
| battery-status | The plug-in band shows the charger's wattage ("Charging · 67 W · 1h 5m to full"). "Charging On Hold · Optimized / At charge limit" replaces "Not charging" only when macOS says it holds the charge (the optimized flag, or a non-zero ChargerData NotChargingReason); the band is re-posted if the state settles during its 3 s. Condition is shown only when macOS reports one: "Service Recommended" for a failure flag or under 80 % maximum capacity; Apple silicon reports no health key, so no made-up "Normal". Low-battery warnings fire at the levels the user picks (default 20 % and 10 %, chips in settings, a submenu in the gear menu). A persistent critical alert (default 5 %, configurable or off; Activities step 6 makes VoiceOver announce it as important) peeks in the band at every 1 % drop and otherwise sits in the wings as a red battery and "4%", until the charger goes in. The Status page battery card shows level, state, wattage, time, Maximum Capacity (84 % on this Mac, the same as System Settings), cycle count and condition. | IOPS notifications (existing). `IOPSCopyExternalPowerAdapterDetails` gives the watts. AppleSmartBattery registry keys are read one at a time, on plug and unplug, when the page opens, and at most every 10 min. Low Power Mode comes from `NSProcessInfoPowerStateDidChange`. |
| battery-actions | Low Power Mode on/off: a Quick Toggle tile with a lock badge, plus "Turn On… / Turn Off…" in Battery settings. It runs `/usr/bin/pmset -a lowpowermode 1\|0` through macOS's own administrator dialog. The arguments are fixed, nothing is interpolated, and the dialog appears only after a click. "Charge to Full Now" has no public API. The page and settings say so and deep-link to Battery settings. The battery menu in the menu bar has the real button. | osascript `do shell script … with administrator privileges` (same pattern as FanHelperInstaller). The fan helper was not extended: whitelisting pmset in a root daemon widens its attack surface for one switch. |
| peripheral-battery | Magic Mouse, Keyboard and Trackpad, other HID accessories that report a battery, and game controllers. A band appears when one connects. A low warning (default 15 %) fires once per discharge, and the device re-arms when it charges or gains 10 points. The devices are listed on the Status page and in settings. | IOKit `AppleDeviceManagementHIDEventService` (`BatteryPercent`, `Product`, `BatteryStatusFlags`, `DeviceAddress`), with first-match and terminated notifications on the main run loop. A 15 min re-read runs (with tolerance) only while a device is connected, and once after wake. Controllers use the GameController connect notifications and `GCDeviceBattery`. No Bluetooth permission is needed. |
| privacy-indicators | Orange, green and purple dots sit beside the notch, with the app's icon. A band ("Microphone · zoom.us", "Camera · likely FaceTime") peeks whenever something new starts. The panel floats over full-screen apps. "Only a short band" is an option. | CoreAudio `DeviceIsRunningSomewhere` on every input device, the HAL process list, and a per-process `IsRunningInput` listener. All of these name the app exactly, and helper processes count as their app. CoreMediaIO `DeviceIsRunningSomewhere` listens on every camera, including hot-plugged ones. The camera's app is inferred and labelled "likely". Screen sharing comes from SmartMoments' detector when connected (best effort). SparkV's own process never shows: its own capture sessions are excluded through AVFoundation's in-process notifications plus a hook. |
| keep-awake | One tap for the default time (1 h). The gear submenu offers 15 m, 30 m, 1 h, 2 h, 4 h or until off, plus +30 min. The user picks display-on or system-only. Keep Awake turns off on battery under N % (default 20 %). It can also switch on while chosen apps run. A cup and the minutes left sit in the wings. | `IOPMAssertionCreateWithName` with `PreventUserIdleDisplaySleep` or `PreventUserIdleSystemSleep`, plus a kernel timeout for timed sessions. Battery is watched through IOPS notifications only while a session runs. NSWorkspace launch and quit notifications drive the app condition. Keep Awake is never restored at launch. |
| quick-toggles | The Status page has a 4 × 2 grid: Keep Awake, Mute Mic, Dark Mode, Hide Desktop Icons, Night Shift, AirPods, Low Power and Screen Saver. Each state is re-read when the grid appears. Settings choose which tiles show. | Dark Mode goes through `LiveModeSystem.setDarkMode` (Modes' Automation consent). Desktop icons are covered per screen by a non-activating wallpaper panel one level above them; it takes desktop clicks, so hidden files can't be selected or moved, and it is updated in place (the wallpaper is decoded once) on Space switches. Finder is not restarted. Night Shift runs a named user Shortcut, because there is no public API. AirPods use IOBluetooth's async `openConnection(_:)` and then become the default output. |
| connectivity-alerts | Alerts for no internet and back online, VPN connected or disconnected, Personal Hotspot joined, "<drive> ejected · Safe to remove", and "<drive> removed · Eject drives before unplugging". | NWPathMonitor, with no pinging. On each path change, getifaddrs scans for tunnels with a routable address (macOS's own utun0-3 carry only fe80:: addresses). A hotspot is detected as Wi-Fi + expensive. Drives: NSWorkspace mount and unmount notifications, plus DiskArbitration's unmount/eject approval callbacks (they run only for a requested eject, never for a pulled drive; they approve at once) and its disappeared callback. The verdict doesn't depend on notification order; BSD names are cleared on mount. Disk images are skipped. Going offline must last 4 s before it alerts; a pending alert is dropped at sleep and alerts stay quiet for 10 s after wake; all alerts stay quiet while the screen is shared. |
| mic-mute | ⌃⌥M (or a tile, the menu, or settings) mutes the default input for every app. A red "Muted" stays beside the notch, also over full-screen apps. The mute follows AirPods taking over the input and follows unmutes made elsewhere. The mic is put back at quit, and at the next launch after a crash. `warnIfMuted(feature:)` makes dictation, Clicky and meeting notes show "Mic muted · Dictation can't hear you", with ⌃⌥M on the right (steps 7-9). The call band's Mute button, the Calls tile and its menu (Activities) use this same controller, so there is one owner, one saved record and one restore path. | `kAudioDevicePropertyMute` (input scope) on the device. Where that is missing, the device's input volume is set to 0 and the old volume is saved. The hotkey uses the Carbon hotkey wrapper (`ScreenRegionHotkey`), so no Accessibility permission is needed. Only the controls in use are listened to (cached per device), and a record whose device vanished is kept by UID and applied when it returns. |
| small-utilities | The Caps Lock indicator: a short band ("Caps Lock On" with an ABC pill) and an optional ⇪ in the wings while it stays on. It is off by default, because macOS 14+ shows Caps Lock at the cursor. The color picker is built by another package. | Global and local `.flagsChanged` monitors, re-created when Accessibility is granted (PermissionCenter). Without Accessibility, it catches up whenever an app activates. There is no timer. |

## Settings sections and their panes

All take no arguments.

| View | Pane |
| --- | --- |
| `BatterySettingsSection` | System |
| `PeripheralBatterySettingsSection` | System |
| `KeepAwakeSettingsSection` | System |
| `MicMuteSettingsSection` | Media |
| `PrivacyIndicatorSettingsSection` | Activities |
| `ConnectivitySettingsSection` | Activities |
| `CapsLockSettingsSection` | Accessibility |
| `QuickTogglesSettingsSection` | Island |

## Agents hub tiles

Added as `HubCatalog.packageTiles` entries (step 4).

| View | Category | Click | Right-click | Pinned to the header |
| --- | --- | --- | --- | --- |
| `SystemStatusHubTile()` | System | Opens the Status page; the battery % is a neutral badge. | `SystemStatusMenuItems` | Opens the Status page |
| `KeepAwakeHubTile()` | System | Keep Awake on (default time) or off; shows the time left. | `KeepAwakeMenuItems` | Toggles Keep Awake |
| `MicMuteHubTile()` | Media | Mute or unmute. | `MicMuteMenuItems` | Toggles the mute |

## Gear menu items

| View | Where |
| --- | --- |
| `SystemStatusMenuItems()` | Inside "Live Activities": battery warnings submenu, accessories, mic and camera, connection alerts, Caps Lock, "Status Page…". |
| `KeepAwakeMenuItems()` | `Menu("Keep Awake")` |
| `MicMuteMenuItems()` | `Menu("Microphone")` |
| `QuickTogglesMenuItems()` | `Menu("Quick Toggles")` |

## Hotkeys

- ⌃⌥M: mute or unmute the microphone. Off by default (a Carbon hotkey holds the combination in every app, and ⌃⌥ is also VoiceOver's modifier pair); it can be turned on in settings and in the menu. Registration goes through `ScreenRegionHotkey`. If `RegisterEventHotKey` fails, settings say "SparkV couldn't register ⌃⌥M". Carbon doesn't report another app using the same keys, so that case isn't detected.
- Checked against Sources and every lab: ⌃⌥A/B/C/E/F/H/I/J/K/P/R/S/T, ⌃⌥⇧R/T, ⌃⌥⇧Space, ⌃⌥1-5, ⌥Space (and ⌃⌥Space / ⌥⇧Space / ⌘⇧Space), ⌘⇧V, ⌘1-9V, ⌃⌘V/C are taken. ⌃⌥M is free. Keep Awake has no hotkey.

## Controllers

Every feature is a `@MainActor` `ObservableObject` singleton with `start()` / `stop()`:

- `PeripheralBatteryMonitor.shared`
- `PrivacyIndicatorMonitor.shared`
- `KeepAwakeController.shared`
- `MicMuteController.shared` (Activities' `CallsController` takes it as its `microphone`)
- `ConnectivityMonitor.shared`
- `CapsLockMonitor.shared`
- `QuickTogglesController.shared`

`SystemStatusCenter.shared` connects them to the `ActivityCenter`, holds the hooks, and starts and stops them all. The views read `.shared` directly, so no `.environmentObject` is needed. `PowerMonitor` stays as it was (created in NotchWindowController) and sets `PowerMonitor.current`. Its battery reading (one IOPS notification source) now stays live while the "Battery & AirPods" HUD is off, so the hub badge and the Status page never go stale; only the bands and Bluetooth are gated by that switch.

UserDefaults keys, each with its feature prefix:
- `power.lowThresholds`, `power.criticalLevel`, `power.showsWattage`
- `peripherals.*`
- `privacy.*`
- `keepAwake.*`
- `micMute.*` (including `micMute.record`, the crash-recovery record)
- `connectivity.*`
- `capsLock.*`
- `quickToggles.*`

Nothing in this package sends data off the Mac.

---

## 1. build.sh

File: `build.sh`

Find:

```zsh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```

Insert after:

```zsh
cp Sources/Labs/SystemStatus/*.swift "$WORK/src/"
```

IOKit, CoreAudio, CoreMediaIO, AVFoundation, Network, DiskArbitration, GameController and IOBluetooth are all autolinked from the imports. No new entitlement is needed. (Activities depends on this package: its Calls use `MicMuteController`, so both build lines must be in.)

## 2. Sources/NotchState.swift

### 2a. The tab

File: `Sources/NotchState.swift`

Find:

```swift
        /// Fan Control: fan speeds, temperatures, presets (Agents hub tile).
        case fans
```

Insert after:

```swift
        /// Status: battery and health, accessories, privacy dots, quick
        /// toggles (Agents hub tile; Labs/SystemStatus).
        case status
```

### 2b. An Agents page (order-independent)

Other packages rewrite the `.focus, … .fans,` line, so this adds its own line before the set's closing bracket.

File: `Sources/NotchState.swift`

Find:

```swift
        ]
    }

    @Published var isExpanded = false
```

Replace with:

```swift
            .status,
        ]
    }

    @Published var isExpanded = false
```

### 2c. The tall drawer (508 × 114 content), order-independent

ColorPicker and Planner rewrite the whole `tallTabs` line. Don't replace it: **add `, .status` before the closing `]` of the `static let tallTabs` set, keeping whatever is already in it.** On today's repo the line becomes:

```swift
    static let tallTabs: Set<NotchState.Tab> = [.tray, .converter, .clipboard, .search, .downloads, .widgets, .replyDrafter, .fans, .status]
```

## 3. Sources/NotchNookLayoutView.swift

### 3a. The page

File: `Sources/NotchNookLayoutView.swift`

Find:

```swift
        case .fans: FanTabView()
```

Insert after:

```swift
        case .status: SystemStatusTabView()
```

### 3b. Live Activities menu

File: `Sources/NotchNookLayoutView.swift`

Find:

```swift
                    Button("Enable AirPods Battery…") { power.requestBluetoothAccess() }
                }
```

Insert after:

```swift
                SystemStatusMenuItems()
```

### 3c. Keep Awake, Microphone and Quick Toggles menus

File: `Sources/NotchNookLayoutView.swift`

Find:

```swift
            Menu("Downloads") {
```

Insert before:

```swift
            Menu("Keep Awake") { KeepAwakeMenuItems() }
            Menu("Microphone") { MicMuteMenuItems() }
            Menu("Quick Toggles") { QuickTogglesMenuItems() }
```

## 4. Sources/AgentsHubView.swift (HubCatalog)

### 4a. The three tiles

Insert after the commented example, so other packages' entries can go after the same line in any order.

File: `Sources/AgentsHubView.swift`

Find:

```swift
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```

Insert after:

```swift
            // System Status (Labs/SystemStatus).
            HubPackageTile(info: HubTileInfo(id: "status", title: "Status", systemImage: "battery.75percent",
                                             tint: Color(red: 0.30, green: 0.85, blue: 0.45), category: .system,
                                             help: "Status: battery and health, accessories, what uses the mic or camera, and quick toggles"),
                           pinAction: { SystemStatusCenter.shared.openPage() }) { AnyView(SystemStatusHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "keepAwake", title: "Keep Awake", systemImage: "cup.and.saucer.fill",
                                             tint: KeepAwakePalette.tint, category: .system,
                                             help: "Keep the Mac awake. Right-click for durations."),
                           pinAction: { KeepAwakeController.shared.toggle() }) { AnyView(KeepAwakeHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "micMute", title: "Mute Mic", systemImage: "mic.fill",
                                             tint: .orange, category: .media,
                                             help: "Mute the microphone for every app (⌃⌥M)"),
                           pinAction: { MicMuteController.shared.toggle() }) { AnyView(MicMuteHubTile()) },
```

### 4b. The tab the Status tile opens

File: `Sources/AgentsHubView.swift`

Find:

```swift
        case "fans": .fans
```

Insert after:

```swift
        case "status": .status
```

## 5. Sources/NotchWindowController.swift

### 5a. Connect and hooks

File: `Sources/NotchWindowController.swift`

Find:

```swift
        FanController.shared.connect(activities: activities, opensTab: .fans)
```

Insert after:

```swift
        // Battery details, accessories, privacy dots, keep awake, mic mute,
        // connection alerts, Caps Lock and quick toggles (Labs/SystemStatus).
        let systemStatus = SystemStatusCenter.shared
        systemStatus.connect(activities: activities)
        systemStatus.statusTab = .status
        systemStatus.openStatusPage = { [weak self] in
            self?.state.select(.status)
            self?.setExpanded(true)
        }
        // SparkV's own camera use never lights the camera dot.
        systemStatus.isOwnCameraActive = { [weak camera] in
            (camera?.isRunning ?? false) || (camera?.isStarting ?? false) || FaceUnlock.isUsingNotch
        }
```

### 5b. Screen sharing from SmartMoments, then start

File: `Sources/NotchWindowController.swift`

Find:

```swift
        smartMoments?.start()
```

Insert after:

```swift
        if let sources = smartMoments?.sources {
            // Connection alerts stay quiet while sharing; the privacy dots show it.
            systemStatus.isScreenSharing = { [weak sources] in sources?.isScreenSharing ?? false }
            PrivacyIndicatorMonitor.shared.connectScreenSharing(sources.$isScreenSharing.eraseToAnyPublisher())
        }
        systemStatus.start()
```

### 5c. Stop at quit

`tearDown()` runs from `applicationWillTerminate`. It releases Keep Awake, unmutes a mic SparkV muted, and removes every listener.

File: `Sources/NotchWindowController.swift`

Find:

```swift
        FanController.shared.stop()
```

Insert after:

```swift
        SystemStatusCenter.shared.stop()
```

## 6. Info.plist: one Bluetooth purpose string (order-independent; supersedes MediaPlus step 15)

MediaPlus also rewrites this string. Whatever `NSBluetoothAlwaysUsageDescription`'s `<string>` says when you get here, **replace that one `<string>…</string>` line** with this merged wording (it covers the battery HUD, the Quick Toggles AirPods tile and MediaPlus' Sound Output list). Skip MediaPlus step 15 if you apply this one.

```xml
	<string>SparkV shows your AirPods and headphones' battery when they connect, lists paired headphones in Sound Output so you can connect and switch to them, and connects them when you tap AirPods in the quick toggles.</string>
```

## 7. Sources/DictationController.swift: dictation warns when the mic is muted

File: `Sources/DictationController.swift`

Find:

```swift
        sessionID += 1
        let id = sessionID
        phase = .listening
```

Insert before:

```swift
        // A muted mic would record silence: say so (System Status mic mute).
        MicMuteController.shared.warnIfMuted(feature: "Dictation")
```

## 8. Sources/ClickyController.swift: Clicky warns when the mic is muted

File: `Sources/ClickyController.swift`

Find:

```swift
        liveQuestion = ""
        phase = .listening
        listeningSince = now()
```

Insert after:

```swift
        MicMuteController.shared.warnIfMuted(feature: "Clicky")
```

## 9. Sources/MeetingAssistant.swift: meeting notes warn when the mic is muted

File: `Sources/MeetingAssistant.swift`

Find:

```swift
        // Recording now (from anywhere): the "Take notes?" offer is answered.
```

Insert before:

```swift
        // Your side of the call would be silent (System Status mic mute).
        MicMuteController.shared.warnIfMuted(feature: "Meeting notes")
```

---

## Known limits

- **Camera attribution**: macOS has no public way to say which app holds the camera. The band says "likely <app>": the app on the mic, else the front app. WebKit's shared helpers (web pages in Safari or any app's web view) are named Safari only while Safari is in front, else "A web page".
- **Screen sharing**: the indicator relies on SmartMoments' window-title detector, which runs only while SmartMoments watches for sharing.
- **Charge to Full Now**: no public API. There is a deep link to Battery settings instead.
- **Charge hold**: shown only when macOS reports it (optimized flag or NotChargingReason). Which reason codes mean "limit" isn't documented, so a non-zero reason at 50 % or more reads "At charge limit", lower down "Not Charging".
- **Battery condition**: Apple silicon reports no health string, so a healthy battery shows its maximum capacity and cycles without a "Normal" label; under 80 % shows "Service Recommended".
- **Low Power Mode**: asks for an administrator password on every change. Making it password-free would mean adding pmset to the root fan helper, which was deliberately not done.
- **Night Shift**: needs a user Shortcut with "Set Night Shift → Toggle" (named in settings, default "Toggle Night Shift"). Its on/off state can't be read, so the tile has no lit state.
- **Hide Desktop Icons**: the cover shows the wallpaper's still image, so dynamic and aerial wallpapers don't animate under it. It takes desktop clicks (so hidden files can't be selected or dragged); icons already selected before hiding stay selected in Finder.
- **Accessory batteries**: the registry keys are undocumented. `BatteryStatusFlags == 3` is read as charging. Most third-party mice report nothing.
- **Personal Hotspot**: detected heuristically (Wi-Fi + expensive). The network name would need Location permission and is not read.
- **Drives**: a volume unmounted with plain `umount` (no DiskArbitration request) and then pulled within a second reads as "removed".
- **Caps Lock**: needs Accessibility to see changes in other apps live. When Caps Lock is set to switch input sources, macOS never reports it.
- **Keep Awake**: can't stop lid-close sleep on battery, which would need root `pmset disablesleep`.
- **Mic mute badges**: during a call the call band shows its own mute state next to the "Muted" badge. Both read the same `MicMuteController`, so they never disagree.
