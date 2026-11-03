# Shelf, drops and transfers: integration

Package ids: shelf-power, shelf-drag-reliability, drag-filter,
shelf-near-pointer, cross-platform-share, transfer-progress.

Code lives in files this package owns (`Sources/TrayView.swift`,
`Sources/AirDropTarget.swift`, `Sources/Labs/FileDropActions/`,
`Sources/Labs/Downloads/`) and in the new lab `Sources/Labs/ShelfPlus/`.
Everything below goes into files the package does not own. Apply the steps
in order (1, 1b, 2 … 12); every **Find** block occurs exactly once (checked against the
repo's current `NotchWindowController.swift` and `NotchNookLayoutView.swift`
as well as the starting snapshot).

No new global hotkeys. The Tray's keys (Space, ← →, ⌘A, Delete, ⌘Z,
Return, ⌘C, Esc) work only after a click on a Tray card, through a local
key monitor that lives while the Tray is on screen.

## Settings sections (all in the **Shelf** pane, in this order)

| Section | What |
|---|---|
| `ShelfSettingsSection()` | Tray size (5–30), keep after restart, auto-remove, drag-out copy/move |
| `ShelfDragSettingsSection()` | Which drags open the notch (Files Only / Files, Links and Text / Never) |
| `FileDropSettingsSection()` | File Drop on/off, shelf under the notch, shake / hold key for a shelf at the pointer, AI rename style |
| `NearbyShareSettingsSection()` | LocalSend (off by default), the name other devices see, nearby senders first in Share menus |
| `FileTransfersSettingsSection()` | Finder copy progress (off by default), watched folders, external drives |
| `DownloadsSettingsSection()` | Download watcher switches (was only in the gear menu) |

## Agents hub tiles (category **Files**)

- `NearbyShareHubTile()` — opens Nearby Share (LocalSend) with the Tray's picked items (or all). Needs `TrayStore` in the environment (the hub has it).
- `FileTransfersHubTile()` — copy / send progress; click opens the Downloads tab, where transfers are listed with Pause / Cancel / Reveal. Needs `NotchState` in the environment.

Both match `AgentTile`'s 48 pt tile (`ShelfHubTileFace`, built on
`LabsBHubTileBackground`). Step 12 lists them in `HubCatalog.packageTiles`
(category `.files`), which the look-and-layout hub already reads.

Step 11 puts the six sections in the Shelf pane
(`Labs/AppShell/AppShellSettingsPanes.swift`), replacing its placeholder.

## Gear menu

`ShelfMenuItems()` inside `Menu("Shelf") { … }` (step 4). It covers every
Shelf setting, so nothing is out of reach before the Settings window ships:
Tray size, expiry, restart, drag-out, which drags open the notch, shake,
Nearby Share, the name other devices see, copy progress, its watched
folders (add / stop watching) and external drives.

## Controllers

All singletons, no new `environmentObject`: `ShelfSettings.shared`,
`TrayKeyboard.shared`, `TrayQuickLook.shared`, `LocalSendController.shared`,
`LocalSendPanelController.shared`, `ShelfTransfersMonitor.shared`
(`connect`/`start`/`stop`, steps 6–8). `FileDropController.current` and
`DownloadsController.current` are set by their own `init`.

---

### Step 1: compile the new lab

File: build.sh

Find:
```
cp Sources/Labs/FileDropActions/*.swift "$WORK/src/"
```

Replace with:
```
cp Sources/Labs/FileDropActions/*.swift "$WORK/src/"
cp Sources/Labs/ShelfPlus/*.swift "$WORK/src/"
```

### Step 1b (optional): move the Local Network link into PermissionCenter.swift

The extension `PermissionCenter.openLocalNetworkSettings(from:)` lives in
`Labs/ShelfPlus/PermissionCenterLocalNetwork.swift` so the lab compiles on
its own. To keep every permission in one file, cut that file's
`extension PermissionCenter { … }` block and paste it into
`Sources/PermissionCenter.swift` just above this line (it occurs once),
then delete `PermissionCenterLocalNetwork.swift`:

```
// MARK: - Signature
```

### Step 2: Local Network prompt text and LAN-only ATS exception

LocalSend's search (only after the user clicks Turn On in the Nearby panel)
is what makes macOS 15 ask for Local Network access; without this key the
prompt has no explanation. `NSAllowsLocalNetworking` lets SparkV reach a
LocalSend device whose owner turned encryption off (plain http on the LAN);
it changes nothing for internet hosts. If another package already added an
`NSAppTransportSecurity` dictionary, add only the `NSAllowsLocalNetworking`
key to it.

File: Info.plist

Find:
```
	<key>NSHighResolutionCapable</key>
```

Replace with:
```
	<key>NSLocalNetworkUsageDescription</key>
	<string>SparkV looks for devices running LocalSend on your network while the Nearby Share panel is open, so you can send Tray files to Android, Windows and Linux. It sends only the files you pick, and only after that device accepts.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>NSHighResolutionCapable</key>
```

### Step 3: the drawer's drop target (drag filter + file promises)

Links, tabs and text no longer flip the drawer to the Tray; promised files
(Mail attachments, Photos, Affinity, WeChat) land as real files.

File: Sources/NotchNookLayoutView.swift

Find:
```
                // Screenshot thumbnails arrive as image data or a file promise,
                // not a file URL, so images, links and text are accepted too.
                .onDrop(of: [.fileURL, .image, .url, .text], isTargeted: $state.isDropTargeted) { providers in
                    if state.tab == .converter {
                        return converter.accept(providers)
                    }
                    // Between the Space cards: file it in the Spaces Inbox.
                    if state.tab == .spaces {
                        return SpacesDropIngestor.accept(providers, into: nil, store: SpaceStore.shared)
                    }
                    // The strip has its own drop target; this covers the header band.
                    if state.tab == .fileDrop {
                        return fileDrop.accept(providers)
                    }
                    tray.accept(providers)
                    return true
                }
```

Replace with:
```
                // Files, images and file promises (Mail, Photos, the screenshot
                // thumbnail) land here on any tab; links and text only on the
                // Tray or Spaces the user opened (Labs/ShelfPlus/ShelfDragFilter).
                .onDrop(of: ShelfDrawerDrop.types,
                        delegate: ShelfDrawerDrop(state: state, tray: tray, converter: converter, fileDrop: fileDrop))
```

### Step 4: gear menu

File: Sources/NotchNookLayoutView.swift

Find:
```
            FileDropSettingsMenu(controller: fileDrop)
```

Replace with:
```
            FileDropSettingsMenu(controller: fileDrop)
            Menu("Shelf") { ShelfMenuItems() }
```

### Step 5: open the closed notch only for file drags

File: Sources/NotchWindowController.swift

Find:
```
        if isPointerInHotZone() {
            collapseTask?.cancel()
            collapseTask = nil
```

Replace with:
```
        if isPointerInHotZone() {
            collapseTask?.cancel()
            collapseTask = nil
            // A drag reaching the closed notch opens it only when it carries
            // files (Settings › Shelf), never for a browser tab, a link or a
            // window being moved.
            if !state.isExpanded, !ShelfDragFilter.allowsHoverOpen(pressBeganInPanel: pressBeganInPanel) {
                endThemeHover()
                updateClickThrough()
                return
            }
```

### Step 6: the same check after the hover dwell

File: Sources/NotchWindowController.swift

Find:
```
guard !self.state.isExpanded, self.isPointerInHotZone(), !FaceUnlock.isUsingNotch
```

Replace with:
```
guard !self.state.isExpanded, self.isPointerInHotZone(), !FaceUnlock.isUsingNotch,
                                  ShelfDragFilter.allowsHoverOpen(pressBeganInPanel: self.pressBeganInPanel)
```

### Step 7: keep the drawer open for Quick Look and during a file drag

A file drag over the open drawer used to risk the drawer closing (and
`ignoresMouseEvents` flipping) mid-drag; Quick Look of a Tray item keeps it
open until the preview closes.

File: Sources/NotchWindowController.swift

Find:
```
        return pressBeganInPanel || isMenuTracking || camera.isAwaitingPermission || fileDrop.holdsDrawerOpen
```

Replace with:
```
        return pressBeganInPanel || isMenuTracking || camera.isAwaitingPermission || fileDrop.holdsDrawerOpen
            || TrayQuickLook.shared.isVisible || fileDrop.isDraggingFiles
```

### Step 8: wiring (drop highlight reset, transfer bands)

File: Sources/NotchWindowController.swift

Find:
```
        fileDrop.onOpenConverter = { [weak self] in
```

Replace with:
```
        // A file drag that ended anywhere clears the drawer's drop highlight,
        // so the dashed well never sticks.
        fileDrop.onDragEnded = { [weak self] in self?.state.isDropTargeted = false }
        // Finder copy and LocalSend progress bands open the Downloads tab,
        // where the transfers are listed with Pause / Cancel / Reveal.
        ShelfTransfersMonitor.shared.connect(activities: activities, opensTab: .downloads)
        fileDrop.onOpenConverter = { [weak self] in
```

### Step 9: start

`start()` only follows the setting: nothing subscribes until the user turns
copy progress on.

File: Sources/NotchWindowController.swift

Find:
```
        downloads.start()
```

Replace with:
```
        downloads.start()
        ShelfTransfersMonitor.shared.start()
```

### Step 10: stop

File: Sources/NotchWindowController.swift

Find:
```
        downloads.stop()
```

Replace with:
```
        downloads.stop()
        ShelfTransfersMonitor.shared.stop()
        // Ends a LocalSend search and any send in progress.
        LocalSendController.shared.cancel()
        LocalSendController.shared.panelClosed()
```

### Step 11: Settings › Shelf

File: Sources/Labs/AppShell/AppShellSettingsPanes.swift

Find:
```
            SettingsPanePlaceholderSection(pane: .shelf)
```

Replace with:
```
            ShelfSettingsSection()
            ShelfDragSettingsSection()
            FileDropSettingsSection()
            NearbyShareSettingsSection()
            FileTransfersSettingsSection()
            DownloadsSettingsSection()
```

### Step 12: Agents hub tiles (Files)

The hub's environment already carries `TrayStore` and `NotchState`
(NotchWindowController injects both at the root). Keep the commented
example line for the next package.

File: Sources/AgentsHubView.swift

Find:
```
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```

Replace with:
```
            HubPackageTile(info: HubTileInfo(id: "nearbyShare", title: "Nearby", systemImage: "wave.3.right.circle.fill", tint: .teal,
                                             category: .files, help: "Nearby Share: send Tray items to Android, Windows or Linux (LocalSend)"),
                           pinAction: { LocalSendPanelController.shared.open() }) { AnyView(NearbyShareHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "fileTransfers", title: "Transfers", systemImage: "doc.on.doc.fill", tint: .blue,
                                             category: .files, help: "Copy and send progress, with Pause and Cancel")) { AnyView(FileTransfersHubTile()) },
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```

---

## Notes for the integrator

- **Permissions.** Local Network has no public status or request API; the
  prompt comes from the first multicast send, which runs only from the
  Nearby panel's "Turn On and Search" button or its Search Again button.
  The Settings link goes through `PermissionCenter.openLocalNetworkSettings(from:)`,
  in `Labs/ShelfPlus/PermissionCenterLocalNetwork.swift` (Step 1b moves it into `PermissionCenter.swift`). `.localNetwork` was not added to `PermissionCenter.Permission`, because
  `SmartMomentsViews.swift` switches over that enum exhaustively.
- **Hover gating needs `fileDrop.start()`** (already unconditional), whose
  watcher compares the drag pasteboard's change count with mouse-down.
- `TrayStore.capacity` (static) stays as the default (5); the live limit is
  `tray.capacity` (Settings).
- `TrayDragPayload` gained `canMove` (default `false`), `TrayDragSource`
  gained `takesKeyboardFocus`, `quickLookID`, `onModifiedClick` and
  `onPress` (all defaulted): other shelves (Converter, File Drop, Flow
  Canvas, Clipboard) are unchanged.
- `FileDropLayout.zoneSize` grew to 444 pt for the new Tray bucket.
