# Live activities, notifications and calls: integration

Package requirement ids: `notifications`, `multi-activities`, `activity-timing`,
`voiceover-announcements`, `calls`.

Owned and already changed (no action): `Sources/LiveActivity.swift`,
`Sources/NotificationMonitor.swift`, `Sources/NotificationActivityView.swift`,
`Sources/DictationActivityView.swift`, `Sources/Labs/Activities/` (new).

Everything below is for files this package does not own. Apply in order.
Every Find block was checked against the live repo
(`/Users/koushikgoudshaganti/Developer/macNotch`, branch `requirements-pass`)
on 1 Nov 2026 (after the IslandPlacement fix pass landed): each occurs
exactly once there. Each step names its file on a
`File:` line.

**Depends on** (their own INTEGRATION steps, already partly in the repo):
- **SystemStatus**: `MicMuteController` (Labs/SystemStatus) is the one
  microphone mute; the call band's Mute, the Calls tile, menu and settings use
  it. Its `cp Sources/Labs/SystemStatus/*.swift` build line and
  `SystemStatusCenter.shared.start(...)` wiring must be in. Without it running,
  Mute is hidden (`canMute` stays false); nothing else breaks.
- **IslandPlacement**: steps 3e and 3f extend its visibility decision (already
  in `NotchWindowController.swift`).
- **AppShell** (step 11) and **LookLayout** (step 12, `HubCatalog.packageTiles`).

Steps 1–4 and 11–12 are required (build, behaviour, reachable settings);
5–10 are the VoiceOver sentences and the HUD timing, each independent.

Ordering with **HUDPlus** step 3 (its `hud.handleIslandPointer` line also goes
after the File Drop line): either order works. This package only ever
restores `ignoresMouseEvents` when it was the one that turned it off
(`bandTakesClicks`), and the HUD's band is never "interactive" here, so the
two never fight over the same band. If HUDPlus is applied first, its line
sits between the File Drop line and this package's; use its new text as the
step 3a anchor's end.

---

## 1. Compile the lab (required)

File: build.sh

Find:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```
Replace with:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/Activities/*.swift "$WORK/src/"
```

## 2. Create, start and stop the controller (required)

### 2a. Properties

File: Sources/NotchWindowController.swift

Find:
```
    private var smartMoments: SmartMomentsWiring?
```
Replace with:
```
    private var smartMoments: SmartMomentsWiring?
    /// Live activities: music beside other activities, calls, ⌃⌥A (Labs/Activities).
    private let liveActivities: LiveActivitiesController
    /// Re-checks the band under a still pointer when the band changes.
    private var bandPointerObserver: AnyCancellable?
    /// A ringing call: collapses the drawer and passes through a hidden island.
    private var callRingingObserver: AnyCancellable?
    /// When a band with buttons may take clicks (see `ActivityBandClickGate`).
    private var bandClickGate = ActivityBandClickGate()
    /// This code made the collapsed panel take clicks (and so may undo it).
    private var bandTakesClicks = false
    private var bandClickRecheck: Task<Void, Never>?
```

### 2b. Create it (before `super.init`)

File: Sources/NotchWindowController.swift

Find:
```
        super.init(window: panel)
```
Replace with:
```
        liveActivities = LiveActivitiesController(
            activities: activities, media: media, notifications: notifications, meetingAssistant: meetingAssistant
        )
        super.init(window: panel)
```

### 2c. Start it

File: Sources/NotchWindowController.swift

Find:
```
        meetingAssistant.start()
        meetingIntel.start()
```
Replace with:
```
        meetingAssistant.start()
        meetingIntel.start()
        // Music as a peer activity, call timer / incoming calls / mute, ⌃⌥A.
        liveActivities.start()
```

### 2d. Stop it (also undoes a mute pressed for a call)

File: Sources/NotchWindowController.swift

Find:
```
        meetingIntel.stop()
        meetingAssistant.shutdown()
```
Replace with:
```
        meetingIntel.stop()
        liveActivities.stop()
        meetingAssistant.shutdown()
```

## 3. The band under the pointer, and ringing calls (required)

Alerts wait while the pointer is on the band (Settings › Activities › Timing).
A band with buttons (notification Reply / Dismiss, call Accept / Decline /
Mute) takes clicks instead of opening the drawer, but only after the pointer
came onto it, or moved over it once it had been up 0.6 s: a band that pops up
under a click meant for a browser tab never catches it. Accept and Decline
also ignore clicks in the band's first 0.5 s. The collapsed panel still
ignores the mouse everywhere else, so the menu bar keeps working.

A ringing call passes through a hidden island (full screen, an excluded app,
a quiet Smart Moment) like a HUD does, keeps its buttons there, and an open
drawer collapses for it unless a drag or a menu is in progress.

### 3a. Call it from `handlePointer`

File: Sources/NotchWindowController.swift

Find:
```
        if !state.isExpanded, !visibility.isOnScreen || visibility.ignoresHover {
            endThemeHover()
```
Replace with:
```
        if !state.isExpanded, !visibility.isOnScreen || visibility.ignoresHover {
            // A ringing call passes through a hidden island (full screen):
            // its Accept and Decline still take clicks. Any other band lets go.
            if handleActivityBandPointer() { return }
            endThemeHover()
```

### 3b. The band after the File Drop shelf

File: Sources/NotchWindowController.swift

Find:
```
        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }
```
Replace with:
```
        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }
        // The band under the notch: its alert waits while the pointer is on
        // it, and a band with buttons takes clicks instead of opening the drawer.
        if handleActivityBandPointer() { return }
```

### 3c. The methods

File: Sources/NotchWindowController.swift

Find:
```
    /// What entering the hot zone did before themes: open on the activity's tab.
```
Replace with:
```
    /// Holds the band's clock while the pointer is on it; over a band with
    /// buttons, lets the panel take clicks there once `bandClickGate`
    /// allows. True when the pointer is on such a band (the caller stops:
    /// hovering it never opens the drawer). `moved`: a real mouse move.
    /// While the island is hidden, only a ringing call's band counts.
    @discardableResult
    private func handleActivityBandPointer(moved: Bool = true) -> Bool {
        let now = Date()
        bandClickRecheck?.cancel()
        bandClickRecheck = nil
        guard !state.isExpanded else {
            // setExpanded owns ignoresMouseEvents while the drawer is open.
            bandTakesClicks = false
            bandClickGate.update(bandID: nil, onBand: false, moved: moved, now: now)
            activities.setHovered(false)
            return false
        }
        let voiceIdle = dictation.phase == .idle && clicky.phase == .idle
        let allowed = visibility.isOnScreen && (!visibility.ignoresHover || liveActivities.calls.incoming != nil)
        let layout = NotchActivityView.closedLayout(
            resting: state.collapsedSize, dictation: dictation, clicky: clicky, activities: activities, media: media
        )
        let decision = allowed ? ActivityBandPointer.decide(
            mouse: NSEvent.mouseLocation,
            bandRect: layout.flatMap { ActivityBandPointer.bandRect(layout: $0, notchRect: notchRect) },
            isExpanded: false,
            bandOwnedByActivity: voiceIdle && activities.current != nil,
            isInteractive: activities.current?.isInteractive == true
        ) : .none
        activities.setHovered(decision != .none)
        let interactiveID = allowed && voiceIdle && activities.current?.isInteractive == true ? activities.current?.id : nil
        bandClickGate.update(bandID: interactiveID, onBand: decision == .interact, moved: moved, now: now)
        let takesClicks = decision == .interact && bandClickGate.allowsClicks(onBand: true, now: now)
        setActivityBandTakesClicks(takesClicks)
        if decision == .interact, !takesClicks, bandClickGate.movedOver {
            // Moved onto a band that just appeared: look once more when it has settled.
            bandClickRecheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ActivityBandClickGate.settle))
                guard !Task.isCancelled else { return }
                self?.handleActivityBandPointer(moved: false)
            }
        }
        guard decision == .interact else { return false }
        endThemeHover()
        return true
    }

    /// Turns clicks on the collapsed panel on or off for the band; only
    /// ever undoes what it did itself (the HUD may take the pointer too).
    private func setActivityBandTakesClicks(_ on: Bool) {
        guard on != bandTakesClicks else { return }
        bandTakesClicks = on
        guard !state.isExpanded else { return }
        window?.ignoresMouseEvents = !on
    }

    /// What entering the hot zone did before themes: open on the activity's tab.
```

### 3d. Re-check when the band changes under a still pointer; ringing calls

File: Sources/NotchWindowController.swift

Find:
```
        installMouseMonitors()
        observeSystemEvents()
```
Replace with:
```
        installMouseMonitors()
        observeSystemEvents()
        // A band that appears, changes or goes away under a still pointer is
        // re-checked without waiting for a move. This never turns clicks on
        // by itself: a new band needs the pointer to move onto it.
        bandPointerObserver = activities.$current
            .map { $0.map { "\($0.id)|\($0.isInteractive)" } }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleActivityBandPointer(moved: false) } }
            }
        // A ringing call shows over full screen (`callRinging`) and the
        // drawer makes way for it, unless a drag or a menu is in progress.
        callRingingObserver = liveActivities.calls.$incoming
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ringing in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if ringing, self.state.isExpanded, !self.isInteractionInProgress { self.forceCollapse() }
                        self.applyVisibility()
                    }
                }
            }
```

### 3e. Tell Island Placement a call is ringing

File: Sources/NotchWindowController.swift

Find:
```
            voiceShowing: dictation.phase != .idle || clicky.phase != .idle,
            showsVoiceWhileHidden: s.showsVoiceWhileHidden
        )
```
Replace with:
```
            voiceShowing: dictation.phase != .idle || clicky.phase != .idle,
            showsVoiceWhileHidden: s.showsVoiceWhileHidden,
            callRinging: liveActivities.calls.incoming != nil
        )
```

### 3f. A ringing call passes through a soft hide

File: Sources/Labs/IslandPlacement/IslandPlacementCore.swift

Find:
```
    var showsVoiceWhileHidden = true
```
Replace with:
```
    var showsVoiceWhileHidden = true
    /// A call is ringing (Labs/Activities): its band shows through a soft
    /// hide such as full screen, like a HUD, so it can be answered.
    var callRinging = false
```

File: Sources/Labs/IslandPlacement/IslandPlacementCore.swift

Find:
```
            decision.isPassThrough = hud || voice
```
Replace with:
```
            decision.isPassThrough = hud || voice || i.callRinging
```

## 4. Gear menu (required for the menu items)

File: Sources/NotchNookLayoutView.swift

Find:
```
                Toggle("Hide Message Text", isOn: $notifications.hidesMessageBody)
                    .disabled(!notifications.isEnabled)
            }
```
Replace with:
```
                Toggle("Hide Message Text", isOn: $notifications.hidesMessageBody)
                    .disabled(!notifications.isEnabled)
                Divider()
                // Show in Wings, Next Activity ⌃⌥A, Timing, Notification
                // Options, Calls, Announce to VoiceOver (Labs/Activities).
                LiveActivitiesMenuItems()
            }
```

## 5. User-chosen HUD time (Settings › Activities › Timing)

(If HUDPlus has made it non-private by then, drop `private` from both lines.)

File: Sources/HUDController.swift

Find:
```
    private static let hudDuration: TimeInterval = 1.6
```
Replace with:
```
    /// Settings › Activities › Timing (1–4 s, 1.6 s by default).
    private static var hudDuration: TimeInterval {
        min(NotchMetrics.alertMaxDuration, ActivityTimingSettings.shared.hudSeconds)
    }
```

## 6. Announce charging and battery to VoiceOver

File: Sources/PowerMonitor.swift

Find:
```
            BatteryActivityView(reading: reading, mode: mode, watts: watts, hold: hold)
        })
```
Replace with:
```
            BatteryActivityView(reading: reading, mode: mode, watts: watts, hold: hold)
        }
        .announcing(ActivityAnnouncementText.battery(reading, mode: mode), as: .charging,
                    important: ActivityAnnouncementText.isImportant(mode)))
```

File: Sources/PowerMonitor.swift

Find:
```
            BatteryActivityView(reading: reading, mode: .critical)
        }
        .compact {
```
Replace with:
```
            BatteryActivityView(reading: reading, mode: .critical)
        }
        .announcing(ActivityAnnouncementText.battery(reading, mode: .critical), as: .charging, important: true)
        .compact {
```

## 7. Announce AirPods to VoiceOver

File: Sources/PowerMonitor.swift

Find:
```
            AirPodsActivityView(device: device)
        })
```
Replace with:
```
            AirPodsActivityView(device: device)
        }
        .announcing(ActivityAnnouncementText.airPods(device), as: .charging))
```

## 8. Announce a finished timer

File: Sources/TimerController.swift

Find:
```
            TimerDoneBandView(message: message, accent: accent)
        })
```
Replace with:
```
            TimerDoneBandView(message: message, accent: accent)
        }
        .announcing(ActivityAnnouncementText.timerFinished(message), as: .timer, important: true))
```

## 9. Announce "meeting in 5 minutes" and "now"

(Spoken when the heads-up first appears and again when it turns to "Now":
the activity's `peekKey` changes from "soon" to "now".)

File: Sources/MeetingsController.swift

Find:
```
        activities.post(activity)
        // "Now" announces itself for a little longer than the 4 s peek, then
```
Replace with:
```
        let minutesLeft = isNow ? 0 : max(1, Int((meeting.start.timeIntervalSinceNow / 60).rounded(.up)))
        activities.post(activity.announcing(ActivityAnnouncementText.meeting(title: title, minutes: minutesLeft), as: .meeting))
        // "Now" announces itself for a little longer than the 4 s peek, then
```

## 10. Announce the end of a focus block or break

File: Sources/Labs/Focus/FocusController.swift

Find:
```
            FocusDoneBandView(message: message, accent: accent, kickedAt: kick)
        })
```
Replace with:
```
            FocusDoneBandView(message: message, accent: accent, kickedAt: kick)
        }
        .announcing(message, as: .timer, important: true))
```

## 11. Settings sections (required: some controls live only here)

The sections are native `Section { … } header: { … }` rows for the panes'
grouped Form.

File: Sources/Labs/AppShell/AppShellSettingsPanes.swift

Find:
```
            SettingsPanePlaceholderSection(pane: .activities)
            // ▸ Activities: add sections above this line
```
Replace with:
```
            LiveActivitiesSettingsSection()
            NotificationsSettingsSection()
            CallsSettingsSection()
            ActivityTimingSettingsSection()
            // ▸ Activities: add sections above this line
```

File: Sources/Labs/AppShell/AppShellSettingsPanes.swift

Find:
```
            // ▸ Accessibility: add sections above this line
```
Replace with:
```
            VoiceOverAnnouncementsSettingsSection()
            // ▸ Accessibility: add sections above this line
```

## 12. Agents hub tiles (required for the tiles)

File: Sources/AgentsHubView.swift

Find:
```
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```
Replace with:
```
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
            HubPackageTile(info: HubTileInfo(id: "liveActivities", title: "Live", systemImage: "rectangle.topthird.inset.filled",
                                             tint: .orange, category: .system,
                                             help: "Live Activities: the next running one beside the notch (⌃⌥A)"),
                           pinAction: { LiveActivitiesController.current?.showNextFromKeyboard() }) { AnyView(LiveActivitiesHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "notificationsUnderNotch", title: "Alerts", systemImage: "bell.badge.fill",
                                             tint: .red, category: .focus,
                                             help: "Notifications under the notch on or off")) { AnyView(NotificationsHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "calls", title: "Calls", systemImage: "phone.fill",
                                             tint: .green, category: .media,
                                             help: "Calls: mute during a call, incoming calls on or off")) { AnyView(CallsHubTile()) },
```

---

## Settings sections (no arguments; they use `.shared` / `.current`)

| View | Pane |
|---|---|
| `LiveActivitiesSettingsSection()` | Activities |
| `NotificationsSettingsSection()` (two sections: Notifications, Apps) | Activities |
| `CallsSettingsSection()` | Activities |
| `ActivityTimingSettingsSection()` (two sections: Timing, Music in the Island) | Activities |
| `VoiceOverAnnouncementsSettingsSection()` | Accessibility |

## Agents hub tiles (no required arguments)

| View | Category | Click | Right-click |
|---|---|---|---|
| `LiveActivitiesHubTile()` | System | next running activity in the wings (instant), or a peek when only one runs | Show in Wings, Timing |
| `NotificationsHubTile()` | Focus | notifications under the notch on / off | privacy, muted apps |
| `CallsHubTile()` | Media | during a call: mute / unmute (shows the call time); otherwise incoming calls on / off | Calls options |

They match `AgentTile` (Apple: tinted glyph on a dark tile, tint wash while on;
SparkV Red: monochrome, red when hovered or on) and use `AgentHubMetrics.tileHeight`.
The plain microphone tile stays System Status's Mic Mute tile.

## Gear menu

`LiveActivitiesMenuItems()` (step 4) contains: Show in Wings (picker: Most
Important + every running activity), Next Activity ⌃⌥A, Timing ›
(`ActivityTimingMenuItems`), Notification Options › (`NotificationsMenuItems`:
hide sender, buttons, Show From, Mute <last app>, Muted Apps ›, macOS
Notification Settings…), Calls › (`CallsMenuItems`, with Turn On Call
Detection when Meetings › Detect Calls is off), Announce to VoiceOver.
Each submenu view also works on its own inside any `Menu { }`.

## Hotkeys

- **⌃⌥A**: show the next running activity in the wings (with one running, it
  peeks). Registered by `LiveActivitiesController` through `ScreenRegionHotkey`
  (Carbon, no permission). **Let go while VoiceOver runs** (⌃⌥ is the VO
  modifier, VO-A is "read from the cursor"; followed by KVO on
  `NSWorkspace.isVoiceOverEnabled`, no polling) and taken again when it stops.
  Settings › Activities › Live Activities can turn it off and says when it is
  paused or taken by another app. Checked against SparkV's ⌃⌥ J R S T C F H M
  P K E I N Space 1–5, ⌃⌥⇧R, ⌥Space, ⌘⇧V, ⌘1–9V, ⌃⌘V / ⌃⌘C.

## Controllers

- `LiveActivitiesController` (start / stop, step 2): owns
  `NowPlayingActivityBridge` and `CallsController`, the ⌃⌥A hotkey.
  `LiveActivitiesController.current`, `CallsController.current` and
  `NotificationMonitor.current` are weak statics for settings views, menus
  and tiles; nothing needs `.environmentObject`.
- `CallsController.incoming` (published) is what steps 3a–3e read.

## Behaviour changes to know about

- The band goes to the highest-priority *persistent activity that wants
  it* (peeking, urgent, expanded), not only to the top one: e.g. a lower
  meeting peek shows while REC rests in the wings. Alerts still win by
  priority as before.
- Music playing is a live activity (`kind: .media`, priority 5) when "Keep
  music beside other activities" is on (default). With it off, Expand on
  Track Change / Play still work through a short band of their own.
- Up to three activities show at once (compact + a minimal icon on each
  side); Settings can limit it to two. Custom compact trailing views are
  clipped to the wing's room; the song title hides beside another icon
  unless Always Show is on.
- Incoming calls: only FaceTime / Phone alerts (`AXNotificationCenterAlert`
  from those apps) with Accept and Decline, and call apps' *new* windows with
  Accept and Decline *and* call wording. AirDrop, Screen Sharing, calendar
  invitations and friend requests are never calls.
- With notification previews off (also Smart Moments pausing them),
  Notification Center is still watched for calls when incoming calls are on,
  but banners are not read at all (alerts only), nothing polls unless a call
  rings, and the caller's name is hidden.
- Dismiss presses only a "Close"/"Dismiss" control; never "Clear" or "Mark as
  Read". Without one, it just removes the band.
- Mute uses `MicMuteController` (one mute for the whole app, ⌃⌥M, survives
  crashes and input switches). A mute pressed during a call is undone when
  the call ends (Settings › Calls › Unmute when the call ends).
- The call timer needs Meetings › Detect Calls; Settings and the Calls menu
  offer to turn it on. It counts from when the call's evidence started (the
  detector's 4 s start delay is added back).

## Validation

Applied with `req/tests-activities/apply_integration.py` to a fresh copy of the
work copy (`req/wired-activities`) and typechecked with every lab in Swift 5
and 6 (`req/tests-activities/tc.sh`, which neutralises the AppShell/LookLayout
`LookCard` clash in a scratch copy; that clash is not this package's).
