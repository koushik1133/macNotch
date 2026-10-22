# Wiring Screen Distance into SparkV

Everything below goes in files outside this folder, so it is left to the
lead. All of it typechecks against the current sources. The folder needs
no GlanceKit import, entitlement or new framework: AVFoundation, Vision,
IOKit and AppKit are already linked by the app.

## 1. build.sh

Next to the other Labs lines:

```zsh
cp Sources/Labs/ScreenDistance/*.swift "$WORK/src/"
```

(and add `ScreenDistance` to the `Sources/Labs/{...}` list in the typecheck script).

## 2. NotchState.swift: a drawer tab

```swift
enum Tab: Hashable {
    ...
    case clipboard
    case screenDistance

    static let agentTabs: Set<Tab> = [.agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance]
}
```

`ScreenDistanceDrawerView` is about 508×69 pt, so the default drawer height
(115) fits; no change to `NotchMetrics.expandedSize(for:)`.

## 3. NotchWindowController.swift

```swift
// with the other Labs controllers
private let screenDistance: ScreenDistanceController

// init(), next to the other `X(activities: activities)` lines
screenDistance = ScreenDistanceController(activities: activities)

// after super.init(window:), with the other hook assignments
screenDistance.opensTab = .screenDistance
screenDistance.isCameraBusy = { [weak camera] in
    (camera?.isRunning ?? false) || (camera?.isStarting ?? false) || FaceUnlock.isUsingNotch
}

// root view
.environmentObject(screenDistance)

// end of init (after observeSystemEvents()): starts only if the user turned it on
screenDistance.start()

// tearDown()
screenDistance.stop()
```

`start()` never opens the camera or asks for permission unless the feature
was switched on earlier; with it off it only registers lock/sleep observers.

## 4. Camera hand-off

Before SparkV's own camera starts, let a Screen Distance burst go at once.
In `NotchNookLayoutView.swift`, the mirror button (currently `camera.toggle()`
around line 774), with `@EnvironmentObject private var screenDistance: ScreenDistanceController`
added to that view:

```swift
if !camera.isRunning { screenDistance.yieldCamera() }
camera.toggle()
```

Optional, same idea, before `FaceUnlock.openSettings()` in the gear menu.
The `isCameraBusy` hook then keeps it paused while the mirror runs or glance
has the notch; on screen lock (when glance scans) it pauses on its own.

## 5. Drawer page and Agents hub tile

`NotchNookLayoutView.swift`, the tab switch:

```swift
case .screenDistance: ScreenDistanceDrawerView()
```

`AgentsHubView.swift`, the `agents` array:

```swift
Agent(tab: .screenDistance, title: "Distance", systemImage: "eye", tint: .mint),
```

## 6. Gear menu

In the gear `Menu` of `NotchNookLayoutView.swift` (the view that already has
`@EnvironmentObject` for the other controllers), e.g. after `Menu("Agents")`:

```swift
@EnvironmentObject private var screenDistance: ScreenDistanceController
...
Menu("Screen Distance") {
    ScreenDistanceMenuItems(controller: screenDistance)
}
```

It has the on/off toggle, Pause/Resume, Snooze 15 min / 1 hour (or Cancel
Snooze), Calibrate at 50 cm, Full-Screen Alert, Allow Skipping with Esc,
Pause Below 20% Battery, and Allow Camera Access when denied.

`ScreenDistanceSettingsSection(controller:)` (440 pt wide, native controls,
threshold slider, interval picker, calibration distance stepper) is there
for a settings window or popover if SparkV gets one; nothing requires it.

## 7. Info.plist

No new keys. Suggested wording for the existing `NSCameraUsageDescription`
so the prompt shown when Screen Distance is switched on explains it:

```
SparkV uses your FaceTime HD camera for the private mirror preview, to warn you when you sit too close to the screen (Screen Distance, if you turn it on) and, if you set it up, to recognize your face and unlock your Mac. Video is processed on-device and never leaves your Mac.
```

## 8. Behaviour to know

- Off by default; `screenDistance.isEnabled = true` (toggle, drawer switch or
  menu) is the only thing that requests camera access.
- The notice is a non-activating key `NSPanel` per screen at
  `NSWindow.Level.statusBar + 1`, above the notch panel (`.statusBar`) and
  below menus. It covers the notch too, so while it is up the gear menu is
  not reachable: the notice carries its own Snooze 15 min / 1 hour buttons
  (and Skip when allowed). It never activates SparkV, so focus goes back to
  the app you were in by itself.
- Live activity id `"screenDistance"`, kind `.notification`, priority 75: a
  persistent band while the notice is up, then a 2.5 s "That's better" band.
- UserDefaults keys: `screenDistance.*` (enabled, thresholdCM,
  intervalSeconds, allowSkipping, pauseOnLowBattery, fullScreenAlert,
  calibrationScale, snoozedUntil, stats).
- Center Stage on for SparkV pauses the feature ("turn off Center Stage for
  SparkV"); it is not changed programmatically.
- Harness: scratchpad `screen-distance/harness/` (`build.sh [5|6]` then
  `./sdharness`), 145 checks, no camera, no windows on screen.
