# Island Placement and Visibility — integration

Package requirements: fullscreen-hide, fullscreen-menubar, display-choice,
display-change-recovery, external-off, nonnotch-pill, notch-match,
capture-exclusion, lifecycle-recovery, mission-control, menubar-autohide,
exclude-apps, island-style-presets, hide-notch-blackbar.

## What is already in the owned files

These files were edited directly (this package owns them). Other packages'
patches that anchor on the lines listed below need re-anchoring:

| File | Change |
|---|---|
| `Sources/NotchWindowController.swift` | Owns an `IslandPlacementController` (`placement`), created with the panel and started by `connectPlacement()` right after the first `positionOverNotch()`. `static func targetScreen()` stays (it now returns `IslandScreen.current`); `positionOverNotch()` is rewritten around `IslandGeometry` (real notch width from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, camera-centred, pixel-rounded, pill margin; the panel always reaches the top edge, a pill's margin is inside it). `handlePointer()` keeps its original File Drop line and `} else { endThemeHover(); if state.isExpanded, collapseTask == nil {` lines verbatim. The `.environmentObject(...)` chain moved unchanged into `private func islandRoot(state:) -> some View` (same 12-space indentation; `.environmentObject(downloads)` is now its last line, followed by `    }`), so an extra `.environmentObject(x)` added after `.environmentObject(downloads)` still applies, to the island and to the All Displays mirrors. `observe(_:on:object:_:)` gained an optional `object:`. `setExpanded(_:animated:)` gained `animated` (default `true`); an open requested while the island is hidden (a hotkey, a link, Smart Moments, the app shell) shows the island for as long as the drawer is open, and is refused only without a display or for another user. `showWindow` does nothing while the island is hidden. `tearDown()` starts with `placement.stop()` (restores the wallpaper, unregisters ⌃⌥H, clears every hide/quiet reason). New: HUD-only fallback on the main display when the island has no display but SparkV replaces the volume/brightness pop-up; a pool of All Displays mirrors; coalesced `scheduleRelayout`, `recoverPanel`, `selfCheck`, visibility (`applyVisibility`), top-edge reveal, Follow the Pointer, All Displays mirrors. |
| `Sources/NotchPanel.swift` | `setHidesInMissionControl(_:)` (`.transient` vs `.stationary`, keeping `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.ignoresCycle`). |
| `Sources/NotchState.swift` | `NotchMetrics.cameraHousingWidth` is now `nonisolated(unsafe) static var` (set from the measured notch on every layout, main thread only); new `pillOpenRadius`, `pillBandRadius`, `pillHeaderMinHeight`; `NotchState.surface` (`IslandSurface`, with `topInset` for a floating pill), `NotchState.isRestingRevealed`; new `struct IslandSurface`. |
| `Sources/IslandShape.swift` | New `IslandSilhouette` shape (notch silhouette or continuous capsule, both radii animatable). `IslandShape` itself is unchanged. |
| `Sources/NotchNookLayoutView.swift` | Body: `let shape = IslandShape(...)` → `IslandSilhouette(...)`, pill radii, Minimal resting opacity + hairline overlay (at the top edge), pill header min height; a floating pill rests `topInset` below the edge and its open drawer or band fills that gap. Gear menu: `Menu("Island") { IslandPlacementMenuItems() }` right after `AppearanceMenu()`, and `Button("Restart SparkV") { PermissionCenter.shared.relaunch(from: "Menu") }` right before `Button("Quit SparkV")`. |

## Steps for the integrator (apply in order)

Each step: the **Find** text occurs exactly once in the current file; replace
it with the **Replace** text. Steps 8–11 need the app-shell package (already
in the repo); skip them only if it is not compiled.

### 1. `build.sh` — compile the lab

Find:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```
Replace:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/IslandPlacement/*.swift "$WORK/src/"
```

### 2. `Sources/Labs/SmartMoments/SmartMomentsWiring.swift` — both island actions now have an owner

Find:
```
    static let unavailableActions: Set<MomentAction> = [
        .quietNotchActivities, .moveIslandToDisplay,
    ]
```
Replace:
```
    static let unavailableActions: Set<MomentAction> = []
```

### 3. `Sources/Labs/SmartMoments/SmartMomentsWiring.swift` — "Quiet the notch" and "Move island here"

Find:
```
        engine.hooks = h
    }

    // MARK: - Captions
```
Replace:
```
        // Island Placement (Labs/IslandPlacement) ----------------------------

        // Presenting: the island and its live activities step aside until
        // the presentation ends (volume/brightness and dictation bands still
        // pass through, per the Island settings).
        h.actions[.quietNotchActivities] = { _ in
            let reason = IslandPlacementController.smartMomentsQuietReason
            guard let placement = IslandPlacementController.current else { return .skipped("Island unavailable") }
            guard !placement.quietReasons.contains(reason) else { return .skipped("Already quiet") }
            placement.setQuiet(true, reason: reason)
            return .done("Notch quiet")
        }
        engine.putBack[.quietNotchActivities] = { _ in
            let reason = IslandPlacementController.smartMomentsQuietReason
            guard let placement = IslandPlacementController.current, placement.quietReasons.contains(reason) else {
                return .skipped("Unchanged")
            }
            placement.setQuiet(false, reason: reason)
            return .done("Notch back")
        }
        // A display connected: one tap pins the island to it (saved by UUID).
        h.actions[.moveIslandToDisplay] = { context in
            guard case .displayConnected(let id, let name) = context.trigger else { return .skipped("No display") }
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard let placement = IslandPlacementController.current else { return .failed("Island unavailable") }
            return placement.moveIsland(toDisplayID: id) ? .done("Island on \(name)") : .failed("\(name) isn’t connected")
        }
        h.isAvailable[.moveIslandToDisplay] = { trigger in
            guard case .displayConnected(let id, _) = trigger, let placement = IslandPlacementController.current else { return false }
            return placement.islandDisplayID != id
        }

        engine.hooks = h
    }

    // MARK: - Captions
```

### 4. `Sources/Labs/QuickCapture/QuickCaptureToast.swift` — the toast lands on the island's display

Find:
```
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
```
Replace:
```
        guard let screen = IslandScreen.current else { return }
```

### 5. `Sources/Labs/Focus/FocusWindows.swift` — the Focus recap card too

Find:
```
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
```
Replace:
```
        let screen = IslandScreen.current ?? NSScreen.main ?? NSScreen.screens.first
```

### 6. `Sources/Labs/FileDropActions/FileDropDragWatcher.swift` — the File Drop shelf follows the island, and stays away while it is hidden

Find:
```
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }
```
Replace:
```
    static func targetScreen() -> NSScreen? {
        // The island's display; nil while the island is hidden or ignores
        // hover (full screen, an excluded app), so no shelf appears there.
        IslandScreen.shelfScreen
    }
```

### 7. `Sources/AgentsHubView.swift` — hub tile (category: System)

The look-and-layout package rebuilt the hub around `HubCatalog.packageTiles`.
This keeps the "integrator: add entries here" comment line, so other
packages that anchor on it still match.

Find:
```
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```
Replace:
```
            // Island placement (Labs/IslandPlacement): click for display, style, hiding.
            HubPackageTile(info: HubTileInfo(id: "islandPlacement", title: "Island", systemImage: "rectangle.topthird.inset.filled",
                                             tint: Color(red: 0.36, green: 0.78, blue: 0.98), category: .system,
                                             help: "Island: display, style and when it hides"),
                           pinAction: { IslandSettingsOpener.open() }) { AnyView(IslandPlacementHubTile()) },
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```

### 8. `Sources/Labs/AppShell/AppShellSettingsPanes.swift` — the sections in the Settings window

Each section is a `Section { … } header:` and sits in the pane's grouped
Form like the shell's own sections. Each marker line is kept, so other
packages can still insert above it.

Find:
```
            // ▸ Island: add sections above this line
```
Replace:
```
            IslandDisplaySettingsSection()
            IslandVisibilitySettingsSection()
            IslandExcludedAppsSettingsSection()
            // ▸ Island: add sections above this line
```

### 9. `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Find:
```
            // ▸ Appearance: add sections above this line
```
Replace:
```
            IslandStyleSettingsSection()
            IslandBlackMenuBarSettingsSection()
            // ▸ Appearance: add sections above this line
```

### 10. `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Find:
```
            // ▸ Advanced: add sections above this line
```
Replace:
```
            IslandCapturePrivacySettingsSection()
            IslandRecoverySettingsSection()
            // ▸ Advanced: add sections above this line
```

### 11. `Sources/Labs/IslandPlacement/IslandPlacementViews.swift` — "Island Settings…" and "Excluded Apps…" open the Island pane

Find:
```
        IslandPlacementWindowController.shared.show()
```
Replace:
```
        SparkVSettings.show(.island)
```

## Notes for other packages' patches

- **`targetScreen()`** is back as `static func targetScreen() -> NSScreen?`
  in `NotchWindowController` (it returns `IslandScreen.current`, the
  island's display), so AppShell step 8 (`Self.targetScreen()`) and HUDPlus
  step 2 (`hud.islandScreen = { NotchWindowController.targetScreen() }`)
  compile unchanged. New code should call `IslandScreen.current`.
- **`handlePointer()`** keeps the original lines word for word:
  `if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }`
  (Activities 3a, ColorPicker 5g, HUDPlus 3), and
  `        } else {` / `            endThemeHover()` / `            if state.isExpanded, collapseTask == nil {`
  are contiguous again (AppShell step 9). Island Placement's own
  pointer-left work now runs after that block.
- **DevStatus/Teleprompter step 23** anchors on
  `if !state.isExpanded, fileDrop.zoneContains(mouse) { return }`. That form
  no longer exists; use
  `        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }`
  as its Find and its first Replace line instead (same behaviour: `mouse` was
  `NSEvent.mouseLocation`).
- **Smart Moments** steps 2 and 3 above are unchanged.
- **AppShell Reset / Uninstall**: AppShell's `prepareForReset` (its
  INTEGRATION) calls `tearDown()`, which starts with `placement.stop()`, so
  Black Menu Bar puts the current Space's wallpaper back before any file is
  moved to the Trash. No extra step.

## Settings sections (no arguments) and their panes

| View | Pane |
|---|---|
| `IslandDisplaySettingsSection()` — which display (Automatic, Built-in Only, Main, each connected display by name, a disconnected saved one, Follow the Pointer, All Displays), Notch Fit (Standard / Exact Notch) | **Island** |
| `IslandVisibilitySettingsSection()` — Hide in Full Screen (+ Reveal at the Top Edge, Still Show Volume & Brightness, Still Show Dictation & Clicky, Accessibility hint), Show on Displays Without a Notch, Hide in Clamshell Mode, Hide in Mission Control, ⌃⌥H toggle, Hide for 1 Hour / Show | **Island** |
| `IslandExcludedAppsSettingsSection()` — behaviour (Don’t Open on Hover / Hide the Island), app chips, Add App…, Add <front app> | **Island** |
| `IslandStyleSettingsSection()` — Notch / Pill / Minimal per display with previews, Pill Height, Top Margin, Minimal hairline, When the Menu Bar Hides | **Appearance** |
| `IslandBlackMenuBarSettingsSection()` — Black Menu Bar (hides the notch) | **Appearance** |
| `IslandCapturePrivacySettingsSection()` — Hide SparkV from Screenshots & Screen Sharing (best-effort note) | **Advanced** |
| `IslandRecoverySettingsSection()` — Restart SparkV | **Advanced** |

Every section is a `Section { … } header:` for a grouped Form (no card of
its own). `IslandPlacementSettingsRoot()` stacks all seven in such a Form;
until step 11 is applied, `IslandSettingsOpener.open()` (the gear menu's
"Island Settings…" and "Excluded Apps…", the hub tile when pinned) shows it
in a small window. After step 11 they open Settings › Island.

## Gear menu

`IslandPlacementMenuItems` (usable in any `Menu { }`) is already in the
gear menu as `Menu("Island") { IslandPlacementMenuItems() }`. It has: Show On
(picker), Style (for the island's display), Hide in Full Screen, Show on
Displays Without a Notch, Hide in Clamshell Mode, Hide in Mission Control,
Disable SparkV in <front app>, Excluded Apps…, Hide from Screenshots &
Screen Sharing (with its best-effort line), Black Menu Bar, Hide the Island
for 1 Hour / Show the Island, Hide/Show Shortcut ⌃⌥H, Island Settings….
"Restart SparkV" sits above "Quit SparkV".

## Hub tile

`IslandPlacementHubTile()` — category **System** (step 7). Same face as the
other Labs tiles (`LabsBHubTileBackground`); a click opens the Island menu.
Pinned to the header, it opens the Island settings.

## Hotkeys

⌃⌥H — hide / show the island (opt-in, off by default; Settings › Island or
the gear menu). Hidden by you: shows it and opens it. Hidden for full screen,
an excluded app or a Smart Moment: shows it for now and opens it; the next
press puts it away again. Checked against ⌃⌥J ⌃⌥R ⌃⌥S ⌃⌥T ⌃⌥C ⌃⌥F ⌃⌥⇧R
⌃⌥1–5 ⌥Space ⌘⇧V ⌘1–9V: no SparkV clash. If another app owns it, Settings
says so. With VoiceOver on it is also VO-H (VoiceOver's Help); the setting's
detail line says so while VoiceOver runs.

## Controller

`IslandPlacementController` (`@MainActor ObservableObject`, `start()`/`stop()`)
is created and started inside `NotchWindowController`; nothing to add.
`IslandPlacementController.current` is the running one (Smart Moments and the
settings views use it). No `.environmentObject` is needed: the views read
`IslandPlacementSettings.shared` and `IslandPlacementController.current`.

## Settings keys

All in `UserDefaults.standard` under `IslandPlacement.`: `displayMode`,
`displayUUID`, `displayName`, `stylePresets`, `notchFit`, `pillHeight`,
`pillTopMargin`, `minimalHairline`, `showOnDisplaysWithoutNotch`,
`hideInClamshell`, `hideInFullScreen`, `revealAtTopEdge`,
`showsHUDWhileHidden`, `showsVoiceWhileHidden`, `excludedBundleIDs`,
`exclusionBehavior`, `hidesInMissionControl`, `menuBarAutoHide`,
`hideFromCapture`, `blackMenuBar`, `hotkeyEnabled`, `blackBar.originals`,
`builtInHasNotch`.
Nothing leaves the Mac.

## Permissions

None required. If the user already allowed Accessibility, full-screen
detection on a notched display asks each candidate window's `AXFullScreen`
(through `PermissionCenter.shared.isGranted(.accessibility)`; it never
prompts). The Island pane shows an "Allow…" button
(`PermissionCenter.shared.request(.accessibility, from:)`) only while Hide in
Full Screen is on, a notched display is connected and access is missing.

## Energy

No polling while idle. Workspace, screen, session, occlusion and Space
notifications drive everything. The only timer is the full-screen watcher's
2 s check (tolerance 1 s). It runs only while a display is full screen, the
front app has a window filling 97 % or more of a display the island uses,
or the front app is a presenter or player (Keynote, PowerPoint, Preview,
QuickTime, IINA, VLC); it parks after 6 s without input and while the
screens sleep or another user is active. The window list and Accessibility
reads run off the main thread. Event monitors are the existing three;
recovery re-installs them only if they are missing.
