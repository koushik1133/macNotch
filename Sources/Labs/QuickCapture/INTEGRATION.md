# Quick Capture: integration steps for the lead

Everything lives in `Sources/Labs/QuickCapture/` (file names are unique, so the flat
`$WORK/src` copy in build.sh is safe). No new Info.plist keys, entitlements or
permissions: it reuses Accessibility (already used by TextInserter), Screen Recording
(already used by Screen Region) and Apple Events to browsers (already declared by
`NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events`).

## 1. build.sh

Add after the `ScreenDistance` line:

```sh
cp Sources/Labs/QuickCapture/*.swift "$WORK/src/"
```

## 2. NotchWindowController.swift

Properties (next to `clipboard` / `screenDistance`):

```swift
    private let quickCapture: QuickCaptureController
    private let screenshotClipboard: ScreenshotClipboardController
```

In `init`, after `screenDistance = ScreenDistanceController(activities: activities)`:

```swift
        quickCapture = QuickCaptureController(store: SpaceStore.shared, activities: activities)
        screenshotClipboard = ScreenshotClipboardController(activities: activities)
```

On the root view, after `.environmentObject(screenDistance)`:

```swift
            .environmentObject(quickCapture)
            .environmentObject(screenshotClipboard)
```

In `init`, after `screenDistance.start()` (registers ⌃⌥C; the screenshot watcher only
runs if the user turned it on; nothing prompts at launch):

```swift
        quickCapture.start()
        screenshotClipboard.start()
```

In `tearDown()`, after `screenDistance.stop()`:

```swift
        quickCapture.stop()
        screenshotClipboard.stop()
```

## 3. Gear menu (NotchNookLayoutView.swift, `SettingsMenu`)

Environment objects (next to the others):

```swift
    @EnvironmentObject private var quickCapture: QuickCaptureController
    @EnvironmentObject private var screenshotClipboard: ScreenshotClipboardController
```

A submenu right after `Menu("Spaces") { … }`:

```swift
            Menu("Quick Capture") {
                QuickCaptureMenuItems(capture: quickCapture, screenshots: screenshotClipboard)
            }
```

That submenu has: "Capture to Spaces Now ⌃⌥C", the hotkey toggle, the
"Copy New Screenshots to Clipboard" toggle (default off), a consent button when the
screenshot folder is privacy-protected and the go-ahead is missing, and
"Quick Capture Settings…" which opens `QuickCaptureSettingsWindow` (shortcut recorder,
capture sources, "When no Space fits" fallback, screenshot-to-clipboard options).

Optionally, in the `Spaces` submenu too:

```swift
                Button("Quick Capture  \(quickCapture.settings.shortcut.displayString)") { quickCapture.captureNow() }
```

## 4. Nothing else

- No drawer tab or header icon is needed: the band (`LiveActivity` id `quickcapture`,
  priority 46) says "Saved to <Space>", and a small non-activating strip under it
  (level statusBar − 1, so the open drawer covers it) holds Change Space ▾ / Open / Undo
  for 6 s (hover keeps it up).
- Hotkey: Carbon `RegisterEventHotKey` through the existing `ScreenRegionHotkey`
  (signature 'NIsr', own id), default ⌃⌥C, stored in `QuickCapture.shortcut`.
- UserDefaults keys: `QuickCapture.*` and `QuickCapture.screenshotClipboard.*`.
