# HUDPlus: volume and brightness HUD (integration)

Package: `hud-external-displays`, `hud-steps-backlight`, `hud-interactive`, `hud-styles`.

Owned files, already updated in place (no integration step needed):
`Sources/HUDController.swift`, `Sources/HUDActivityView.swift`,
`Sources/SystemKeyInterceptor.swift`, and the new lab `Sources/Labs/HUDPlus/`:

| File | What |
| --- | --- |
| `HUDPlusModel.swift` | Pure logic: `HUDStyle`, `HUDEdge`, `HUDStyleResolver`, `HUDStepMath` (custom steps, Option+Shift, scroll/drag math), `HUDBrightnessRouter` (which display a brightness key is for, and whether SparkV may touch it), `HUDDisplayApps` (BetterDisplay / Lunar / MonitorControl ids), `HUDIslandGeometry` + `HUDInteractionZones` (hit testing that matches the wings and band), `HUDOverlayLayout` (pill / edge bar placement). |
| `HUDPlusSettings.swift` | `HUDPlusSettings.shared`, UserDefaults under `HUD.*` (style, otherDisplaysStyle, styleByDisplay keyed by display UUID, edge, stepDivisions, showsPercent, interactive, brightnessFollowsPointer, showsOnPointerDisplay, stepAsideForDisplayApps, displayAppsHandleBuiltIn). |
| `HUDPlusSystem.swift` | `HUDDisplayBrightness` (the one DisplayServices wrapper, per display), `HUDDisplayDirectory` (cached screens, UUIDs, pointer screen; refreshed on screen-parameter changes), `HUDDisplayAppWatcher` (NSWorkspace launch/quit notifications), `HUDVolumeControl` (the CoreAudio helper the key tap and the interactive HUD share), `HUDKeyboardBacklight` (read-only presence, public IOKit). |
| `HUDPlusInteraction.swift` | `HUDPointerState`, `HUDInteractionController`: the closed island's HUD takes clicks / drags / scrolls while the pointer is on it. |
| `HUDPlusOverlay.swift` | `HUDOverlayPanel` + `HUDOverlayPresenter`: pill and edge-bar styles, and the HUD on displays without the island. Click-through. |
| `HUDPlusViews.swift` | `HUDWingIcon`, `HUDWingLevel`, `HUDWingRing`, `HUDPercentText`, `HUDPillView`, `HUDEdgeBarView`, `HUDStyleThumbnail`. |
| `HUDPlusBrightnessSlider.swift` | `HUDBrightnessFeed`, `HUDBrightnessSlider` (drawer row, or `compact`), `HUDBrightnessWidget` (Widgets › Brightness, 1x1). |
| `HUDPlusSettingsViews.swift` | Settings sections (`Section { … }` rows for AppShell's grouped Form), `HUDMenuItems`, `HUDHubTile`. |

Public surface the integrator may use:

- `HUDController.current` (the running controller), `hud.attachIsland(window:isDrawerOpen:)`,
  `hud.handleIslandPointer(notchRect:layout:) -> Bool`, `hud.interaction.end()`, `hud.preview(style:)`.
- Closures the island feeds: `hud.islandScreen` (its display), `hud.islandAvailability`
  (`HUDIslandAvailability`: shown / hidden but passing a band through / hidden) and
  `hud.islandMirrorDisplayIDs` (All Displays mirrors on screen).
- `\.hudIslandDisplayID` environment value: set on each All Displays mirror's root so a HUD aimed at
  one display draws only on that display's island.
- `HUDController(activities:)`, `start()`, `stop()`, `isEnabled`, `replacesSystemHUD` are unchanged.
  The controller already exists in `NotchWindowController`; nothing new to create.

## Settings window panes (steps 9–11)

| View (no arguments, a `Section`) | Pane |
| --- | --- |
| `HUDSettingsSection()` | **System** (show HUD, hide macOS pop-up + Accessibility, percentage, interactive, key steps, keyboard backlight status) |
| `HUDDisplaysSettingsSection()` | **System** (brightness keys follow pointer, volume on pointer's display, step aside for display tools, built-in too, a style per connected display) |
| `HUDStyleSettingsSection()` | **Appearance** (style cards with live preview, other displays, edge side, Preview button) |

## Agents hub tile (step 8)

`HUDHubTile()` — category **System**, registered in `HubCatalog.packageTiles`. Click: `HUDMenuItems`
(styles, steps, toggles, Preview). Lit while SparkV replaces the macOS pop-up. Pinned to the header it
previews the HUD.

## Gear menu (step 7)

`HUDMenuItems()` — usable inside any `Menu { }`; step 7 puts it under Live Activities › Volume & Brightness.

## Widgets (steps 12–18)

`HUDBrightnessWidget()` (1x1) in the Widgets catalog, not on by default (Add widget › Brightness).
`HUDBrightnessSlider()` is also there for a drawer row.

## Hotkeys

None added. (Grepped: ⌃⌥J ⌃⌥R ⌃⌥S ⌃⌥T ⌃⌥⇧R ⌥Space ⌘⇧V ⌘1-9V ⌃⌥1-5 ⌃⌥H are untouched.)

## Other packages' steps

- Activities step 5 (`private static let hudDuration: TimeInterval = 1.6` in HUDController.swift) still
  finds its line verbatim; with it applied, Settings › Activities › Timing sets every HUD form's time,
  the overlay pill and edge bar included.
- Activities step 3a: see the note on step 3 (order inside `handlePointer`).
- Steps 2, 8, 9 and 11 keep their Find text, so the AppShell, IslandPlacement, SystemStatus and other
  packages that anchor on the same lines still apply.

## Steps (apply in order; each Find occurs exactly once)

### Step 1 — compile the lab
File: build.sh

Until this step is applied the repo does not build: `HUDController.swift` and `SystemKeyInterceptor.swift` use types from `Labs/HUDPlus`.

Find:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```
Replace with:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/HUDPlus/*.swift "$WORK/src/"
```

### Step 2 — hand the island to the HUD
File: Sources/NotchWindowController.swift

The Activities package's step 3c uses the same Find and keeps it, so both apply in either order.

Find:
```
        installMouseMonitors()
        observeSystemEvents()
```
Replace with:
```
        installMouseMonitors()
        observeSystemEvents()
        // The HUD beside the notch takes the pointer while it shows (drag,
        // scroll, click to mute), draws on the island's display (or on the
        // All Displays mirror of the display being changed), and uses the
        // band Island Placement passes through while the island is hidden.
        hud.attachIsland(window: panel, isDrawerOpen: { [weak self] in self?.state.isExpanded ?? true })
        hud.islandScreen = { IslandScreen.current }
        hud.islandAvailability = { [weak self] in
            guard let self, self.visibility.isHidden else { return .shown }
            let passes = !self.visibility.reasons.contains(where: \.isHard)
                && (self.placement.settings.showsHUDWhileHidden || (self.hud.isEnabled && self.hud.replacesSystemHUD))
            return passes ? .passesBand : .hidden
        }
        hud.islandMirrorDisplayIDs = { [weak self] in
            Set(self?.mirrors.filter { $0.value.panel.isVisible }.map(\.key) ?? [])
        }
```

### Step 3 — let the HUD take the pointer before hover-open
File: Sources/NotchWindowController.swift

Keep this block directly after the File Drop line and **before** the Activities package's `if handleActivityBandPointer() { return }` (its step 3a, whose Find must be adapted to `fileDrop.zoneContains(mouse)` in today's repo): that call sets `ignoresMouseEvents = true` for every non-interactive band on each pointer move, which would undo the HUD's click handling.

Find:
```
        // Over the File Drop shelf during a file drag: let the drop land there.
        if !state.isExpanded, fileDrop.zoneContains(mouse) { return }
```
Replace with:
```
        // Over the File Drop shelf during a file drag: let the drop land there.
        if !state.isExpanded, fileDrop.zoneContains(mouse) { return }
        // On the HUD beside (or under) the notch: it takes the pointer for
        // drag, scroll and click-to-mute instead of opening the drawer, and
        // makes the panel click-through again as soon as the pointer leaves
        // or the HUD goes. Hovering the camera housing still opens the drawer.
        if !state.isExpanded, hud.handleIslandPointer(notchRect: notchRect, layout: hudIslandLayout) {
            endThemeHover()
            return
        }
```

### Step 4 — the layout the HUD hit-tests against
File: Sources/NotchWindowController.swift

Find:
```
    /// The tab hovering the closed island opens: the expanded activity's,
```
Replace with:
```
    /// The closed island's layout for the HUD's hit testing; nil while
    /// dictation or Clicky own the island.
    private var hudIslandLayout: IslandClosedLayout? {
        guard dictation.phase == .idle, clicky.phase == .idle else { return nil }
        return NotchActivityView.closedLayout(
            resting: state.collapsedSize, dictation: dictation, clicky: clicky, activities: activities, media: media
        )
    }

    /// The tab hovering the closed island opens: the expanded activity's,
```

### Step 5 — the drawer opening ends the HUD's interaction
File: Sources/NotchWindowController.swift

Find:
```
        window?.ignoresMouseEvents = !expanded
        // Queued alerts wait while the drawer covers the island.
```
Replace with:
```
        // A hotkey can open the drawer with the pointer on the HUD: the
        // drawer's top row is the drawer's again.
        if expanded { hud.interaction.end() }
        window?.ignoresMouseEvents = !expanded
        // Queued alerts wait while the drawer covers the island.
```

### Step 6 — All Displays mirrors draw only the HUD aimed at them
File: Sources/NotchWindowController.swift

Find:
```
        let host = NotchHostingView(rootView: islandRoot(state: mirrorState))
```
Replace with:
```
        // The HUD for another display's change stays off this mirror.
        let host = NotchHostingView(rootView: islandRoot(state: mirrorState).environment(\.hudIslandDisplayID, id))
```

### Step 7 — gear menu: the HUD's submenu
File: Sources/NotchNookLayoutView.swift

Find:
```
                Toggle("Volume & Brightness", isOn: $hud.isEnabled)
                Toggle("Hide macOS Volume/Brightness Pop-up", isOn: $hud.replacesSystemHUD)
                    .disabled(!hud.isEnabled)
```
Replace with:
```
                // Show / hide macOS pop-up, style, steps, displays, preview.
                Menu("Volume & Brightness") { HUDMenuItems() }
```

### Step 8 — Agents hub tile (System)
File: Sources/AgentsHubView.swift

The template comment stays, so other packages' entries still find it.

Find:
```
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```
Replace with:
```
            HubPackageTile(info: HubTileInfo(id: "hud", title: "HUD", systemImage: "speaker.wave.2.fill",
                                             tint: Color(red: 1.0, green: 0.72, blue: 0.22), category: .system,
                                             help: "Volume & brightness HUD: styles, key steps, displays and a preview"),
                           pinAction: { HUDController.current?.preview() }) { AnyView(HUDHubTile()) }
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```

### Step 9 — Settings › System
File: Sources/Labs/AppShell/AppShellSettingsPanes.swift

Find:
```
            // ▸ System: add sections above this line
```
Replace with:
```
            HUDSettingsSection()
            HUDDisplaysSettingsSection()
            // ▸ System: add sections above this line
```

### Step 10 (optional) — Settings › System: drop the placeholder
File: Sources/Labs/AppShell/AppShellSettingsPanes.swift

Skip this step when the Find text is no longer there (another package already did it).

Its note says the HUD's options live in the gear menu; they now have real sections. Replace with nothing.

Find:
```
            SettingsPanePlaceholderSection(pane: .system)

```
Replace with:
```

```

### Step 11 — Settings › Appearance
File: Sources/Labs/AppShell/AppShellSettingsPanes.swift

Find:
```
            // ▸ Appearance: add sections above this line
```
Replace with:
```
            HUDStyleSettingsSection()
            // ▸ Appearance: add sections above this line
```

### Step 12 — Widgets: a Brightness widget (waits in "Add widget")
File: Sources/Labs/Widgets/WidgetsCatalog.swift

Find:
```
    /// Apple Reminders due today, with check-off.
    case reminders
```
Replace with:
```
    /// Apple Reminders due today, with check-off.
    case reminders
    /// The island's display brightness with a slider (Labs/HUDPlus).
    case brightness
```

### Step 13 — Widgets: title
File: Sources/Labs/Widgets/WidgetsCatalog.swift

Find:
```
        case .reminders: "Reminders"
```
Replace with:
```
        case .reminders: "Reminders"
        case .brightness: "Brightness"
```

### Step 14 — Widgets: symbol
File: Sources/Labs/Widgets/WidgetsCatalog.swift

Find:
```
        case .reminders: "checklist"
```
Replace with:
```
        case .reminders: "checklist"
        case .brightness: "sun.max.fill"
```

### Step 15 — Widgets: tint
File: Sources/Labs/Widgets/WidgetsCatalog.swift

Find:
```
        case .reminders: Color.orange
```
Replace with:
```
        case .reminders: Color.orange
        case .brightness: Color.yellow
```

### Step 16 — Widgets: sizes
File: Sources/Labs/Widgets/WidgetsCatalog.swift

Find:
```
        case .reminders: [.large, .wide, .small]
```
Replace with:
```
        case .reminders: [.large, .wide, .small]
        case .brightness: [.small]
```

### Step 17 — Widgets: shrink priority
File: Sources/Labs/Widgets/WidgetsCatalog.swift

Find:
```
        case .reminders: 4
```
Replace with:
```
        case .reminders: 4
        case .brightness: 6
```

### Step 18 — Widgets: the view
File: Sources/Labs/Widgets/WidgetsTabView.swift

Find:
```
            case .reminders: RemindersWidget(controller: models.reminders, size: size, fixedDate: models.fixedDate)
```
Replace with:
```
            case .reminders: RemindersWidget(controller: models.reminders, size: size, fixedDate: models.fixedDate)
            case .brightness: HUDBrightnessWidget()
```

## Behaviour notes for QA

- Brightness keys (with "Hide macOS pop-up" on and Accessibility granted) go to the display under the pointer.
  SparkV applies them only to displays DisplayServices can set (built-in, Apple Studio Display, Pro Display XDR,
  LG UltraFine). For any other monitor the key is passed through untouched, so BetterDisplay, Lunar,
  MonitorControl or macOS handle it. While one of those tools runs, keys for external displays always pass
  through (Settings › System › Displays › Step Aside, on by default) and SparkV shows no HUD for them, so the
  tool's own OSD is the only one. With no tool running, a key over a monitor SparkV can't set changes the
  built-in panel (as before SparkV followed the pointer). Clamshell mode: such keys go to macOS.
- A display whose style is Off: its keys go to macOS, so macOS's pop-up gives the feedback.
- Island hidden by Island Placement (full screen, excluded app, ⌃⌥H, clamshell): beside-the-notch styles
  show in the band the island passes through (always while SparkV hides the macOS pop-up); with nothing
  passed through, SparkV shows nothing and macOS's pop-up shows.
- All Displays: a HUD aimed at a mirrored display draws on that display's island only; the other
  islands keep its width for that moment (the wings are shared) but draw nothing in it.
- The HUD shows on the display being changed (brightness) or the display with the pointer (volume). Displays
  without the island use the pill (or edge bar / off) in a click-through overlay panel.
- Keyboard backlight (partial by design): macOS has no public API for its level (only the private
  CoreBrightness), so SparkV does not draw or change it; backlight keys (NX 21/22/23) always pass
  through. Settings shows whether the Mac has one (IOResources) with a Keyboard Settings… button.
- Interactive HUD: only while the HUD is on the closed island and the pointer is on its icon or level
  (or its band). Click the speaker: mute / unmute. Click or drag the bar: set the level (the ring drags
  relatively). Scroll (trackpad smooth, wheel one step per notch, momentum ignored). The HUD keeps its
  form (an output-device band stays a band) and stays up while the pointer rests on it (up to 30 s).
  Drags draw at pointer speed; the hardware is written at most ~30 times a second (CoreAudio off the
  main thread) and the island re-posted at most ~10 times a second, plus once on release. Leaving
  restores click-through at once; the HUD then expires 1.6 s later. Opening the drawer ends it.
- VoiceOver hears SparkV's HUD only when SparkV took the key or the pointer set the level; otherwise
  macOS speaks its own.
- Energy: no timers while idle. The overlay's hide timer runs only while it shows; the 1 s brightness sample
  burst runs only after a key; the event monitor and the hold task for the interactive HUD exist only while the pointer is on it.
