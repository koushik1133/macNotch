# File Drop actions: integration (for the lead)

Everything below is wiring in files this feature does not own. All code is
exact; paste it where indicated. No Info.plist keys, entitlements, TCC
permissions or hotkeys are needed (global mouse monitors need no
Accessibility permission; the app is already unsandboxed for `/usr/bin/ditto`).

## 1. build.sh

After the `cp Sources/Labs/BrowserRecorder/*.swift "$WORK/src/"` line:

```zsh
cp Sources/Labs/FileDropActions/*.swift "$WORK/src/"
```

(The typecheck script needs `FileDropActions` in its `Sources/Labs/{…}` list too.)

## 2. NotchState.swift

Add the tab (and let it light the Agents header icon):

```swift
        case screenDistance
        /// File drop actions: rename, compress, convert, Space, AirDrop.
        case fileDrop

        static let agentTabs: Set<Tab> = [.agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance, .fileDrop]
```

(If other features have added tabs to `agentTabs` since, keep them and
append `.fileDrop`; `case screenDistance` above is the existing last case,
shown only to place the new one.)

In `isDropTargeted`'s `didSet`, don't flip a drag over the File Drop tab to the Tray:

```swift
            guard isDropTargeted, tab != .tray, tab != .converter, tab != .spaces, tab != .jobs, tab != .fileDrop else { return }
```

The default drawer height (115) is right: the strip is 508×69, the drawer's
content area. Do **not** add `.fileDrop` to `trayExpandedHeight`.

## 3. NotchWindowController.swift

Property, next to the other agents:

```swift
    private let fileDrop: FileDropController
```

In `init()`, before `super.init(window: panel)`:

```swift
        fileDrop = FileDropController(activities: activities)
```

After `super.init(window: panel)` (next to the converter wiring):

```swift
        fileDrop.activityOpensTab = .fileDrop
        fileDrop.converter = converter
        fileDrop.onAddToTray = { [tray] urls in urls.forEach(tray.addFile) }
        fileDrop.isDrawerExpanded = { [weak self] in self?.state.isExpanded ?? false }
        fileDrop.onOpenStrip = { [weak self] in
            self?.state.select(.fileDrop)
            self?.setExpanded(true)
        }
        fileDrop.onOpenConverter = { [weak self] in
            self?.state.select(.converter)
            self?.setExpanded(true)
        }
```

Add to the environment objects of `root`:

```swift
            .environmentObject(fileDrop)
```

Start / stop (append to the existing lists):

```swift
        [uiAudit.start, jobAgent.start, screenRegion.start, promptRefiner.start, browserRecorder.start, clipboard.start, fileDrop.start].forEach { $0() }
```

```swift
        [uiAudit.stop, jobAgent.stop, screenRegion.stop, promptRefiner.stop, browserRecorder.stop, clipboard.stop, fileDrop.stop].forEach { $0() }
```

### Accepting drops on the collapsed notch

The closed notch window ignores mouse events (so it never blocks the menu
bar), which also means it can't be a drag destination. File Drop therefore
owns its own small panel, the **drop shelf** (`FileDropZonePanel`, level
`.statusBar + 1`): `FileDropDragWatcher` notices a file drag from another app
(drag-pasteboard `changeCount` + types, global monitors only) and, when the
pointer comes within 320×230 pt of the notch, shows the shelf 6 pt under the
notch (below a live-activity band if one is showing). The shelf has four
buckets: **Actions** (keep the files, open the strip), **Compress**, **To
Space** (Auto) and **AirDrop**, which run on drop. Dragging on into the
notch itself still opens the drawer and the Tray, exactly as today; the
shelf hides as soon as the drawer is open.

One line keeps the drawer from opening over the shelf when a live activity
band (which is part of the hover zone) sits behind it. At the top of
`handlePointer()`, after the `FaceUnlock.isUsingNotch` block:

```swift
        // Over the File Drop shelf during a file drag: let the drop land there.
        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }
```

After a drop on **Actions**, `onOpenStrip` opens the drawer on the File Drop
tab. With no band the shelf's buckets lie inside the 115 pt drawer, but with a
live-activity band showing the shelf sits 30 pt lower, below the drawer, and
the collapse timer would close the drawer again under the pointer. One more
line holds it open while the pointer stays where the shelf was (at most 8 s).
In `isInteractionInProgress`, replace the `return` line with:

```swift
        return pressBeganInPanel || isMenuTracking || camera.isAwaitingPermission || fileDrop.holdsDrawerOpen
```

## 4. NotchNookLayoutView.swift

Environment object in `NotchNookLayoutView`:

```swift
    @EnvironmentObject private var fileDrop: FileDropController
```

Tab content (in the `switch state.tab`):

```swift
                        case .fileDrop: FileDropActionStrip(controller: fileDrop)
```

In the drawer's root `.onDrop` handler, before `tray.accept(providers)` (the
strip has its own drop target; this covers the header band):

```swift
                    if state.tab == .fileDrop {
                        return fileDrop.accept(providers)
                    }
```

Settings: in `SettingsMenu` add

```swift
    @EnvironmentObject private var fileDrop: FileDropController
```

and after the `Menu("Spaces") { … }` block:

```swift
            FileDropSettingsMenu(controller: fileDrop)
```

(File Drop Actions on/off, Show Drop Shelf Under the Notch While Dragging,
AI Rename Style, Choose Files…; all persisted in UserDefaults under
`fileDrop.*`, default on / on / words.)

## 5. AgentsHubView.swift (a way in without dragging)

Add to `agents`:

```swift
        Agent(tab: .fileDrop, title: "File Drop", systemImage: "arrow.down.doc.fill", tint: .yellow),
```

## 6. Optional: Actions tile in the open Tray

Skip this unless the Tray layout is reworked. `FileDropTile` is an
AirDrop-sized drop tile for drags that already opened the drawer on the
Tray, but it is itself a `Button`. `TrayAirDropColumn` draws `AirDropTile()`
inside its own `Button { AirDrop.share(tray.items) } label: { … }`, so putting
the tile in that label nests one button in another, which breaks the clicks.
The column's width is also a fixed slot (`TrayAirDropColumn(size: airDrop)`).
If you want it, give the column a second slot next to the existing `Button`,
not inside its label:

```swift
        HStack(spacing: 6) {
            FileDropTile(controller: fileDrop)   // @EnvironmentObject private var fileDrop: FileDropController
            Button { AirDrop.share(tray.items) } label: { /* unchanged */ }
        }
```

and widen `airDrop` by 76 pt where TrayView computes it. Without this step,
the shelf, the Agents hub tile and the File Drop tab still cover every way in.

## What it reuses

`ActivityCenter`/`LiveActivity` (result band, id `fileDrop.done`, opens
`.fileDrop`), `ConverterController.add` (Convert), `ConverterEngine.run(.compress)`
and `ConverterImages` (PDF/image compress), `ConverterEngine.runTool`
(`/usr/bin/ditto`), `AirDrop.resolve` / `AirDrop.share(urls:)`,
`SpaceConnectors.fileInput` + `SpaceStore.ingest/move` + `SpaceIngestCenter.submit`
(Send to Space / Auto), `TrayAIFiles.read`, `ConverterOCR`, `TrayAIOCR.loadImage`,
`MeetingAIBackend.onDevice` (on-device naming), `TrayDragSource` /
`TrayDragImage` (drag out), `ViewFlag`.

## 7. Drag-out (round 3): nothing required, one optional line

Every drag out of a SparkV shelf (Tray cards and the "All" handle, the File
Drop piles and the new per-file tiles, Converter, Clipboard and FlowCanvas
cards: everything built on `TrayDragSource`) now checks in with
`TrayDragOut` (TrayView.swift). `FileDropController.holdsDrawerOpen`, which
is already part of `isInteractionInProgress`, is true for the whole drag,
for 1.2 s of slide-back after a cancelled one, and for 6 s after a drop made
with Shift held (Dropover's "keep the shelf open" gesture). **No wiring is
needed for this.**

Optional, closes the drawer right after a successful drop instead of on the
next mouse move. In `NotchWindowController.init`, after the other
`observe(...)`/NotificationCenter observers (or anywhere after
`super.init(window: panel)`):

```swift
        NotificationCenter.default.addObserver(forName: TrayDragOut.didEndNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.state.isExpanded,
                      note.userInfo?["dropped"] as? Bool == true,
                      note.userInfo?["keepOpen"] as? Bool != true,
                      !self.isPointerInHotZone() else { return }
                self.forceCollapse()
            }
        }
```

(The token can be ignored: the controller lives as long as the app.)
