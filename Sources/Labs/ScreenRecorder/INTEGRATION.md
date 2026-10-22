# Screen tools: Copy Text and Screen Recorder, wiring steps for the lead

Two features. **Copy Text needs no wiring.** It lives in `Sources/Labs/ScreenRegion/` (already compiled), and `ScreenRegionController` owns it. The **Screen Recorder** lives in `Sources/Labs/ScreenRecorder/` and needs the steps below.

## What the user gets

| | Copy Text | Screen Recorder |
|---|---|---|
| Hotkey | ⌃⌥T (Carbon, no permission) | ⌃⌥⇧R (⌃⌥R is Reply Drafter's). The first press opens the overlay; a press while recording stops it. |
| Selection | ScreenRegion overlay (green). Drag a region, click a window, Space toggles window mode, Esc cancels. | The same overlay (red). Drag an area, click a window, or press **Return** for the whole display. |
| Result | Vision OCR (accurate, language correction, automatic language) puts the text on the clipboard. Band shows "Copied 12 words ...". A QR code or barcode payload is copied instead when found. | Live red band "● 0:42 Full screen … ■ Stop ⌃⌥⇧R", a red ■ 0:42 stop button in the menu bar (one click stops) and a dashed frame around a recorded area. |
| Output | Clipboard. Options: keep line breaks (default on), read QR codes and barcodes (on), add to the clipboard instead of replacing (off). | `~/Desktop/SparkV Recording 2026-10-21 at 14.03.22.mov` (or .mp4). If the Desktop can't be written, it goes to `~/Movies/SparkV Recordings/`. A card in the bottom-right corner shows a draggable thumbnail with Reveal, Open and Tray buttons, and closes after 12 s unless hovered. |
| Options | Tile chevron and menu | Microphone (asks for access on that click), system audio (on), show cursor (on), highlight clicks (on, uses `showMouseClicks`), .mov/.mp4, 60/30 fps |

The Screen tab (`.screen`) now shows three tiles: **Ask about screen**, **Copy text**, and **Record screen** (the recorder's tile, injected through `screenRegion.drawerAccessory`). A status line sits underneath. The Record tile turns into a red **Stop** tile with the elapsed time while a recording runs, and it shows the last recording's thumbnail, which can be dragged into any app. The collapsed notch ignores clicks, so the recording band has `opensTab = .screen`: hovering it opens the drawer on that Stop tile.

Permissions: Screen Recording is **preflighted only** (`CGPreflightScreenCaptureAccess`). It is requested only from the Allow… button on the Screen tab, never from a hotkey. The microphone is requested only when the user turns on "Record Microphone". SparkV's own windows (the notch, the band, the frame and the overlay) are excluded from every recording.

## 1. build.sh

Next to the other `Labs` lines:

```zsh
cp Sources/Labs/ScreenRecorder/*.swift "$WORK/src/"
```

No new frameworks or flags (ScreenCaptureKit, AVFoundation and Vision are already linked implicitly). `ScreenRecorder` depends on `ScreenRegion`, which is already compiled.

## 2. NotchWindowController.swift

Property, next to `private let screenRegion: ScreenRegionController`:

```swift
    private let screenRecorder: ScreenRecorderController
```

In `init()`, right after `screenRegion = ScreenRegionController(activities: activities)`:

```swift
        screenRecorder = ScreenRecorderController(activities: activities)
```

After `super.init(window: panel)`, next to `screenRegion.onWillBeginSelection = …`:

```swift
        screenRecorder.onWillBegin = { [weak clicky] in clicky?.cancel() }
        screenRecorder.onAddToTray = { [weak tray] url in tray?.addFile(url) }
        screenRegion.drawerAccessory = { [screenRecorder] in AnyView(ScreenRecorderDrawerTile(recorder: screenRecorder)) }
```

(If `tray.addFile(_:)` has a different name, use whatever the Downloads wiring calls, for example `tray.accept([NSItemProvider(contentsOf: url)!])`.)

Environment, next to `.environmentObject(screenRegion)`:

```swift
            .environmentObject(screenRecorder)
```

Start: add `screenRecorder.start` to the start list, and install its hotkey next to `screenRegion.installHotkey()`:

```swift
        screenRecorder.installHotkey()
```

(`screenRegion.installHotkey()` already registers Copy Text's ⌃⌥T.)

Stop: add `screenRecorder.shutdown` to the stop list (`[uiAudit.stop, …, screenRecorder.shutdown]`).

## 3. NotchNookLayoutView.swift: the "…" menu

In the menu view that already has `@EnvironmentObject private var screenRegion: ScreenRegionController` (around line 341), add:

```swift
    @EnvironmentObject private var screenRecorder: ScreenRecorderController
```

and a submenu, for example right after `Menu("Agents") { … }`:

```swift
            Menu("Screen Tools") {
                ScreenTextGrabMenuItems(controller: screenRegion.textGrab)
                Divider()
                ScreenRecorderMenuItems(recorder: screenRecorder)
            }
```

## 4. Optional

* **NotchState.swift**: the tiles fit the regular 508×69 drawer. Adding `.screen` to the tall tabs in `NotchMetrics.expandedSize(for:)` gives them more air (rendered and checked at 508×114 too).
* **AgentsHubView**: rename the `.screen` tile to "Screen tools" (Ask, Copy text, Record).
* **Info.plist** usage strings should mention recording, because macOS shows them in the prompts:
  * `NSMicrophoneUsageDescription`: "… record a meeting, or narrate a screen recording …"
  * `NSDesktopFolderUsageDescription`: "SparkV saves your screen recordings to the Desktop and moves a download there when you sort it there."
  * The microphone entitlement `com.apple.security.device.audio-input` is already present.

## Notes

* Ad-hoc rebuilds lose the Screen Recording grant. After rebuilding, the Screen tab shows "Screen Recording is off" until the user re-allows it.
* **The first OCR after a new build can take about a minute**, while Vision loads its text model for the new binary. It was measured here at about 60 s on the first run of a fresh binary and 0.1 to 0.3 s after that. `ScreenRegionController.start()` runs a tiny background OCR 20 s after launch so the first ⌃⌥T is fast. If the accurate model throws (seen once: "e5rt … precompiled compute operation"), recognition retries with `.fast`.
* Quitting SparkV while a recording runs: `shutdown()` starts the stop, but the app may exit before the movie is finalized. A clean finish would need `applicationShouldTerminate` to return `.terminateLater` until `screenRecorder.phase == .idle`; that is not wired.
* Nothing is deleted except SparkV's own temp files in `$TMPDIR/SparkV-Recordings/`, which are moved, not copied. If a move fails, the temp file is kept and shown.
