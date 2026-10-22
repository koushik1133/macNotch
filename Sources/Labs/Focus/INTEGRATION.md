# Focus: wiring steps for the lead

All Focus code lives in `Sources/Labs/Focus/`. Nothing outside the folder was edited.

Every step below was applied to a snapshot of the current app and typechecked clean in Swift 5 and Swift 6. The validator's script is `scratchpad/features2/focus/val/integ.py`, and step 6 (the optional tab) was included.

## 1. build.sh

Add this next to the other `Labs` copies:

```zsh
cp Sources/Labs/Focus/*.swift "$WORK/src/"
```

## 2. NotchWindowController.swift

```swift
// stored properties, after `private let clipboard: ClipboardController`
private let focus: FocusController

// in init(), directly before `super.init(window: panel)`
focus = FocusController(
    activities: activities,
    timer: timer,
    sources: .live(tray: tray, meetingAssistant: meetingAssistant, notifications: notifications)
)

// root view, after `.environmentObject(clipboard)`
    .environmentObject(focus)

// directly after `[hud.start, power.start, timer.start, meetings.start, notifications.start].forEach { $0() }`
// (the timer must start first, so a running session re-attaches to its countdown)
focus.start()

// in tearDown(), directly before `dictation.shutdown()`
focus.stop()
```

`focus.stop()` saves a running session, and the next launch resumes it. It does not turn Do Not Disturb off, because the session keeps running. A session that ran out while SparkV was closed is wrapped up at the next launch: DND goes off, previews come back, and the summary shows.

## 3. Header button (NotchNookLayoutView.swift › HeaderRow)

```swift
// HeaderRow: tighten the spacing from 5 to 2
HStack(spacing: 2) {
    ...
    Spacer(minLength: 0)
    FocusHeaderButton()
    RecordMeetingButton()
    ...
}
```

The spacing change matters. These widths were measured offscreen on this Mac:

- The camera housing is 185 pt wide (`NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`).
- That leaves 145.5 pt on each side of the 476 pt header.

| Right group | Spacing 5 | Spacing 2 |
|---|---|---|
| Today, idle | 131 pt | 119 pt |
| Today, recording "● 59:59" | 160 pt (already 14.5 pt under the camera) | 148 pt |
| With Focus, idle | 160 pt (does not fit) | 145 pt (fits) |

`FocusHeaderButton` is always 24 × 22 pt, the same as an IconTab:

- Idle, it shows a moon. One click starts a session.
- Running, it shows a progress ring around the moon (a cup on a break, a pause glyph while paused). Clicking it opens a menu that starts with "Focusing · 18:42 left", then Pause, Add 5 Minutes, Finish This Round or Skip Break, End Focus and Show Summary, and Focus Settings.

Even at spacing 2, the recording pill still overlaps the camera by a few points while it runs. That is a header issue that exists today, not one Focus adds.

## 4. Agents hub tile (AgentsHubView.swift)

Add the tile directly before `ClipboardButton()`:

```swift
// with the Focus tab from step 6 (recommended):
FocusHubTile(onOpen: { withAnimation(.easeOut(duration: 0.15)) { state.select(.focus) } })
// without step 6:
FocusHubTile()
```

- Idle, one click starts focus.
- Running, it shows the time left. A click opens the Focus page; without step 6, it opens the same menu as the header button. A stray click never ends a session.

## 5. Gear menu (NotchNookLayoutView.swift › SettingsMenu)

```swift
// with the other environment objects, after `browserRecorder`
@EnvironmentObject private var focus: FocusController

// directly before `Menu("Agents") {`
Menu("Focus") {
    Button(focus.isActive ? "End Focus" : "Start Focus (\(focus.settings.focusMinutes) min)") { focus.toggle() }
    if focus.isActive {
        Button(focus.isPaused ? "Resume" : "Pause") { focus.togglePause() }
    }
    Button("Focus Settings…") { FocusSettingsWindowController.shared.show(controller: focus) }
    Divider()
    Toggle("Turn On Do Not Disturb", isOn: $focus.settings.usesDoNotDisturb)
    Toggle("Remind Me About Distractions", isOn: $focus.settings.blocksDistractions)
    Toggle("Write Recap On Device", isOn: $focus.settings.summarizesWithModel)
}
```

## 6. Focus drawer page (recommended)

`FocusTabView` fits the standard 476×69 pt content area.

```swift
// NotchState.Tab: add after `case clipboard`
case focus
// and add `.focus` to the existing `agentTabs` set (keep the entries already there), e.g.
static let agentTabs: Set<Tab> = [.focus, .agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance]

// NotchNookLayoutView tab switch, after `case .clipboard: ClipboardTabView()`
case .focus: FocusTabView()

// NotchWindowController.init, directly after `super.init(window: panel)`
focus.bandOpensTab = .focus
```

Without this step, hovering the band opens `.today`, where the mirrored timer shows.

## 7. Info.plist

Append one sentence to `NSAppleEventsUsageDescription`:

```
 During Focus, it reads the address of the front browser tab to spot sites you chose to block.
```

Site checks use the existing Apple Events entitlement, so no new entitlement is needed. No other keys are needed either:

- Shortcuts run through `/usr/bin/shortcuts`, the same way the action capsules do.
- Window titles use the Accessibility permission SparkV already has. Focus never prompts for it.

## 8. Do Not Disturb setup (user action, once)

In Focus Settings › Do Not Disturb, the user creates two shortcuts:

- `SparkV Focus On`: **Set Focus** › Do Not Disturb › Turn On › Until Turned Off.
- `SparkV Focus Off`: **Set Focus** › Do Not Disturb › Turn Off.

The settings window helps with this:

- It lists the user's shortcuts.
- It picks up common pairs automatically (`dnd-on`/`dnd-off`, `session_start`/`session_end`, …).
- It can open the Shortcuts app.
- It has Test On and Test Off buttons.

Until the shortcuts exist, a session still mutes SparkV's own previews and shows a notice.

## 9. Screen effects (no wiring needed)

`FocusEdgeGlow.swift` is picked up by the existing `cp Sources/Labs/Focus/*.swift` line, and `FocusController` drives it itself. No other file changes.

- When focus starts, a break starts, or the session ends, a glowing border lights up every screen. Focus is blue and violet, the break is green and amber, and the end uses every colour, with confetti if the session was completed.
- The border window is borderless, non-activating and click-through (`ignoresMouseEvents`). Its level is `.statusBar`, and it is ordered directly below SparkV's `NotchPanel`, so the island stays crisp and the light seems to come from behind it. It asks to be excluded from screen capture (`sharingType = .none`; ScreenCaptureKit recorders do not always honour this, so SparkV's own recorder should exclude SparkV's windows through its content filter), shows on every Space and over full-screen apps, and gets one window per screen.
- About 0.6 s "kick": the border shakes and squeezes, and the notch band (`FocusBandView`, `FocusDoneBandView`, `FocusSummaryBandView`) wobbles with it. On a Force Touch trackpad, there is an optional haptic tap.
- Settings live in Focus Settings › Screen Effects:
  - Border: Off, At start, breaks and end (the default), or Always, subtly. The subtle option keeps a faint breathing border up for the whole phase and hides it while paused.
  - Shake, Haptics and Confetti toggles.
  - Preview buttons.
- Reduce Motion: the border only fades in and out. There is no shake, spin, breathing or confetti, and the band does not wobble.
- All of it is Core Animation, so SparkV's main thread is idle while the border shows. The "always" motion runs at about 15 fps (`preferredFrameRateRange`). The soft masks are blurred once, at ¼ and ⅛ resolution.
- New API:
  - `FocusController.previewEdgeGlow(_:)`.
  - `presentsEdgeGlow`, which turns the effect off in tests.
  - `FocusEdgeGlowController.ordersWindows`, a harness seam.

## Public API (FocusController, @MainActor ObservableObject)

- **Lifecycle:** `start()` and `stop()`.
- **Controls:** `startSession(using:)`, `end()`, `toggle()`, `pause()`, `resume()`, `togglePause()`, `skipPhase()`, `addFiveMinutes()`, `startBreak()` and `dismissSummary()`.
- **Published state:**
  - `settings` (FocusSettings, persisted)
  - `active` (FocusActiveSession?)
  - `now`
  - `lastSummary`
  - `isSummarizing`
  - `doNotDisturbNotice`
- **Read-outs:** `isActive`, `isPaused`, `phase`, `remaining`, `remainingText`, `progress`, `roundText`, `phaseTitle`, `focusedSoFar` and `stats()`.
- **Hooks:** `bandOpensTab`, `onSessionEnded`, `presentsSummaryWindow`, `presentsOverlay` and `presentsEdgeGlow`.
- **Views:** `FocusHeaderButton`, `FocusHubTile(onOpen:)`, `FocusControlsMenuItems(focus:)`, `FocusTabView`, `FocusBandView` and `FocusSummaryCard`.
- **Windows:**
  - `FocusSettingsWindowController.shared.show(controller:)`.
  - `FocusSummaryWindowController.shared.show(controller:)`. It opens on its own when a session ends, centred on the notched display under the summary band.

Validator notes (focus-fx): the soft masks (halo, wash) are blurred once per screen size and cached in `FocusGlowStrand` with one shared `CIContext`; the sharp core line is a `CAShapeLayer` mask. Earlier every burst rebuilt a 30 MB full-resolution mask and a new `CIContext` on the main thread (90 to 230 ms per burst). The band kick (`FocusKick`) runs on a finite `FocusKickSchedule`, so the TimelineView stops after about 0.7 s instead of redrawing at display rate while the 5 to 8 s done and summary bands are up.
