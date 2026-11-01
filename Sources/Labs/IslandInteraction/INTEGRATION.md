# Island Interaction — integration

Package requirements: anim-calm, hover-smooth, hover-timing, open-trigger,
dismiss-controls, haptics, size-custom, menubar-items,
menubar-manager-compat, notch-app-conflicts.

## What is already in the owned files

This package owns these files and edited them directly. Every other
package's Find text on them still matches, except the two listed under
"Notes for other packages' patches".

| File | Change |
|---|---|
| `Sources/NotchWindowController.swift` | Owns an `IslandInteractionController` (`interaction`), connected by `connectInteraction()` just before `installMouseMonitors()` and stopped in `tearDown()`. **Hover intent:** `handlePointer()` plans each hover open with `IslandHoverIntent` in `planHoverOpen(_:wasRevealed:)`. Automatic waits about 110 ms (longer with a notch theme). Pushing against the top edge over the notch opens at once. Over a live-activity wing it waits 320 ms and not while the pointer slides sideways. Full screen and Minimal keep their floors. At the end of the wait the pointer must have settled (below 1500 pt/s), so a fast pass never opens it. **Closing:** `closeDelay()` is the Close After setting (at least 80 ms), and a drawer that just opened stays at least 0.35 s. Keep Drawer Open (`state.isPinned`) starts no close timer, and a Space switch or a drag-out doesn't close it either. **New monitors** (all in `eventMonitors`): global and local `.scrollWheel` for two-finger swipes, global `.leftMouseDown` for click outside, and local `.leftMouseDown`/`.leftMouseUp` for Click and Press and Hold. While Click or Press and Hold is chosen and the pointer is on the closed island, the panel takes the button (`updateClosedClickCapture`). Elsewhere it stays click-through. **Esc:** a temporary Carbon Esc is held only while the pointer is on the open drawer and the panel is not key (`updateEscape`, re-checked on key changes and when dictation or Clicky change); while the panel is key the responder chain has Esc, so the drawer's own Esc handlers (Flow, the media note, the Script editor's Cancel) run first and `NotchPanel.escapeNotification` closes it otherwise. A failed registration is not retried until the drawer opens again. **Explicit closes stick:** after Esc, a click on the notch, a swipe up or ⌃⌥O, hover can't reopen the drawer until the pointer has left the island (`IslandCloseLatch`). **Click capture** re-asserts `ignoresMouseEvents = false` on every pass while the closed island should take the button, so another feature turning the panel click-through can't leave Click or Press and Hold dead. **Other:** ⌃⌥O (opt-in) opens or closes; focus goes back to the previous app on close; menu bar managers make the island step aside; wing room changes; Closed Width widens `IslandGeometry` (live island and mirrors). `collapsedHotZone` is now cached and invalidated by the activities, media, dictation, Clicky and state publishers and by every layout. The `} else { endThemeHover(); if !state.isExpanded { … } if state.isExpanded, collapseTask == nil {` order now matches AppShell step 9. The `if !state.isExpanded, !visibility.isOnScreen || visibility.ignoresHover {` line and the ShelfPlus dwell guard line are unchanged. |
| `Sources/NotchPanel.swift` | `cancelOperation(_:)` and Esc in `keyDown` post `NotchPanel.escapeNotification`. |
| `Sources/NotchState.swift` | `NotchMetrics.expandedSize` is now a computed `static var`. Its width comes from Drawer Width (540, 600 or 660) and its height stays 115. `hoverAnimation` follows Island Motion (style, speed) and still respects Reduce Motion. `tabShrinkDelay` is computed from the spring's settle time. New `NotchState.isPinned`, `isHoverPrimed` and `wingClearanceRevision`. |
| `Sources/IslandShape.swift` | `IslandClosedLayout.make` caps each wing at the measured room before the nearest menu bar item (`IslandInteractionStore.wingClearance`). The cap is never narrower than the resting shoulder. |
| `Sources/NotchNookLayoutView.swift` | `@ObservedObject interactionSettings`. The resting island grows 10 × 2 pt while the pointer is on it in Click, Press and Hold or Swipe Down. A click on the header's camera gap closes the drawer (`IslandNotchGapTarget`, an overlay after the header's `.frame(height:)`). Keep Open shows as a bar at the bottom (`IslandPinnedIndicator`). The gear menu gets `Menu("Island Behavior") { IslandInteractionMenuItems() }` right after `Menu("Island") { IslandPlacementMenuItems() }`. |

## Steps for the integrator (apply in order)

Each step's **Find** text occurs exactly once in the current file. Replace
it with the **Replace** text. Steps 15–18 need the app-shell package (already
in the repo); skip them only if it isn't compiled.

### 1. `build.sh` — compile the lab

Find:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```
Replace:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/IslandInteraction/*.swift "$WORK/src/"
```

### 2. `Sources/Labs/NotchThemes/NotchThemeViews.swift` — theme layers spring with Island Motion

Find:
```
    static let islandSpring: Animation = .spring(response: 0.35, dampingFraction: 0.8)
```
Replace:
```
    static var islandSpring: Animation { NotchMetrics.hoverAnimation }
```

### 3. `Sources/Labs/AmbientLight/AmbientNotchGlow.swift` — the outline's spring follows Island Motion

Find:
```
    static let springResponse = 0.35
```
Replace:
```
    /// nil with Island Motion › Instant: the outline jumps.
    static var springResponse: Double? { IslandInteractionStore.current.motion.coreAnimationResponse }
```

### 4. `Sources/Labs/AmbientLight/AmbientGlowLayers.swift` — and its bounce

Find:
```
                let spring = CASpringAnimation(perceptualDuration: response, bounce: 0.15)
```
Replace:
```
                let spring = CASpringAnimation(perceptualDuration: response, bounce: IslandInteractionStore.current.motion.coreAnimationBounce)
```

### 5. `Sources/DictationActivityView.swift` — Compact Now Playing: no artwork

Find:
```
struct NowPlayingCompactLeading: View {
    @EnvironmentObject private var media: MediaEngine

    var body: some View {
        artwork
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel("Now playing: \(media.title)")
    }
```
Replace:
```
struct NowPlayingCompactLeading: View {
    @EnvironmentObject private var media: MediaEngine
    /// Compact Now Playing, or too little menu bar room (Labs/IslandInteraction).
    @ObservedObject private var wingRoom = IslandWingRoom.shared

    var body: some View {
        if !wingRoom.compactNowPlaying {
            artwork
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityLabel("Now playing: \(media.title)")
        }
    }
```

### 6. `Sources/DictationActivityView.swift` — Compact Now Playing: only the level bars

Find:
```
    @StateObject private var peek = TrackTitlePeek()
    /// A minimal icon shares the wing: the title gets less room.
```
Replace:
```
    @StateObject private var peek = TrackTitlePeek()
    @ObservedObject private var wingRoom = IslandWingRoom.shared
    /// A minimal icon shares the wing: the title gets less room.
```
Find:
```
        let showsTitle = TrackTitlePolicy.showsTitle(
            peeking: peek.showsTitle, always: timing.alwaysShowTitle, besideMinimal: besideMinimal, width: width
        )
```
Replace:
```
        // Compact Now Playing (Labs/IslandInteraction): only the level bars.
        let showsTitle = !wingRoom.compactNowPlaying && TrackTitlePolicy.showsTitle(
            peeking: peek.showsTitle, always: timing.alwaysShowTitle, besideMinimal: besideMinimal, width: width
        )
```

### 7. `Sources/DictationActivityView.swift` — wings that stop short of a menu bar item

The island caps each wing at the room before the nearest menu bar item.
A compact text is then truncated to fit, and any other content that is still
too wide fades out at the wing's edge instead of being cut.

Find:
```
private struct IslandWingsRow: View {
    @EnvironmentObject private var activities: ActivityCenter
    @EnvironmentObject private var media: MediaEngine
```
Replace:
```
private struct IslandWingsRow: View {
    @EnvironmentObject private var activities: ActivityCenter
    @EnvironmentObject private var media: MediaEngine
    /// Menu bar room for the wings (Labs/IslandInteraction).
    @ObservedObject private var wingRoom = IslandWingRoom.shared
```
Find:
```
                .padding(.trailing, NotchMetrics.wingInnerPadding)
                .frame(width: layout.leadingWing, height: height, alignment: .trailing)
```
Replace:
```
                .padding(.trailing, NotchMetrics.wingInnerPadding)
                .frame(width: layout.leadingWing, height: height, alignment: .trailing)
                .islandWingFit(content: activities.measuredWings.leading, wing: layout.leadingWing, edge: .leading)
```
Find:
```
                .padding(.leading, NotchMetrics.wingInnerPadding)
                .frame(width: layout.trailingWing, height: height, alignment: .leading)
```
Replace:
```
                .padding(.leading, NotchMetrics.wingInnerPadding)
                .frame(width: layout.trailingWing, height: height, alignment: .leading)
                .islandWingFit(content: activities.measuredWings.trailing, wing: layout.trailingWing, edge: .trailing)
```
Find:
```
                        maxTextWidth: activities.secondary == nil
                            ? CompactTrailingView.textWidth
                            : CompactTrailingView.textWidthBesideMinimal
```
Replace:
```
                        maxTextWidth: min(activities.secondary == nil
                            ? CompactTrailingView.textWidth
                            : CompactTrailingView.textWidthBesideMinimal,
                            wingRoom.trailingTextRoom(besideMinimal: activities.secondary != nil))
```

### 8. `Sources/MeetingDetector.swift` — call prompt haptics through the one switch

Find:
```
    static func hover() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func press() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
```
Replace:
```
    /// Hovering never taps the trackpad (Trackpad Haptics: only presses,
    /// swipes, drops and detents do).
    static func hover() {}
    static func press() { SparkVHaptics.perform(.levelChange) }
```

### 9. `Sources/ClickySystem.swift` — Clicky's tick

Find:
```
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
```
Replace:
```
        SparkVHaptics.perform(pattern)
```

### 10. `Sources/Labs/FileDropActions/FileDropZonePanel.swift` — a drag over the shelf

Find:
```
            if on { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
```
Replace:
```
            if on { SparkVHaptics.perform(.alignment) }
```

### 11. `Sources/Labs/FileDropActions/FileDropController.swift` — the shelf summoned at the pointer

Find:
```
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
```
Replace:
```
        SparkVHaptics.perform(.generic)
```

### 12. `Sources/Labs/Focus/FocusEdgeGlow.swift` — the start kick (still also gated by its own toggle)

Find:
```
    private static func hapticKick() {
        let performer = NSHapticFeedbackManager.defaultPerformer
        performer.perform(.levelChange, performanceTime: .now)
        Task { @MainActor in
            for delay in [0.12, 0.14] {
                try? await Task.sleep(for: .seconds(delay))
                performer.perform(.generic, performanceTime: .now)
            }
        }
    }
```
Replace:
```
    private static func hapticKick() {
        // Gentle (the default): one light tap instead of three.
        SparkVHaptics.performSequence([.levelChange, .generic, .generic], gaps: [0.12, 0.14])
    }
```

### 13. `Sources/Labs/Widgets/VolumeKnobWidget.swift` — the knob's detents

Find:
```
        NSHapticFeedbackManager.defaultPerformer.perform(strong ? .levelChange : .alignment, performanceTime: .now)
```
Replace:
```
        SparkVHaptics.perform(strong ? .levelChange : .alignment)
```

### 14. `Sources/AgentsHubView.swift` — the Keep Open tile (category System)

Keep the comment line: other packages anchor on it too.

Find:
```
        // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { _ in AnyView(…HubTile()) },
```
Replace:
```
        // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { _ in AnyView(…HubTile()) },
        // Island Interaction: keep the drawer open (a pin button in the header when pinned there).
        HubPackageTile(info: HubTileInfo(id: "islandKeepOpen", title: "Keep Open", systemImage: "pin.fill",
                                         tint: Color(red: 0.98, green: 0.72, blue: 0.27), category: .system,
                                         help: "Keep the drawer open while you work"),
                       pinAction: { _ in IslandInteractionActions.setPinned(!IslandInteractionActions.isPinned) }) { _ in
            AnyView(IslandInteractionHubTile())
        },
```

### 15. `Sources/Labs/AppShell/AppShellSettingsPanes.swift` — Island pane

Each marker line is kept, so other packages can still insert above it.

Find:
```
            // ▸ Island: add sections above this line
```
Replace:
```
            IslandOpeningSettingsSection()
            IslandMenuBarSettingsSection()
            // ▸ Island: add sections above this line
```

### 16. `Sources/Labs/AppShell/AppShellSettingsPanes.swift` — Appearance pane

Find:
```
            // ▸ Appearance: add sections above this line
```
Replace:
```
            IslandMotionSettingsSection()
            IslandSizeSettingsSection()
            // ▸ Appearance: add sections above this line
```

### 17. `Sources/Labs/AppShell/AppShellSettingsPanes.swift` — Accessibility pane

Find:
```
            // ▸ Accessibility: add sections above this line
```
Replace:
```
            IslandHapticsSettingsSection()
            // ▸ Accessibility: add sections above this line
```

### 18. `Sources/Labs/AppShell/AppShellSettingsPanes.swift` — Advanced pane

Find:
```
            // ▸ Advanced: add sections above this line
```
Replace:
```
            IslandCoexistenceSettingsSection()
            // ▸ Advanced: add sections above this line
```

## Settings sections (no arguments) and their panes

| View | Pane |
|---|---|
| `IslandOpeningSettingsSection()` — Open the drawer by (Hover / Click / Hover or Click / Press and Hold / Swipe Down), Open after (Automatic, Instantly, 0.1–1 s), Close after (Right Away … 2 s), Two-finger swipes, Click outside closes, Esc closes, Give the keyboard back, ⌃⌥O | **Island** |
| `IslandMenuBarSettingsSection()` — Keep live activities clear of menu bar items, Compact Now Playing, Step aside for menu bar managers (and which are running) | **Island** |
| `IslandMotionSettingsSection()` — Island motion (Calm / Snappy / No Bounce / Instant), Speed (Standard / Quick / Fastest; every spring at or under 0.35 s), live preview | **Appearance** |
| `IslandSizeSettingsSection()` — Open drawer width (540 / 600 / 660 pt), Closed island width (+0 / +16 / +32 pt), preview to scale | **Appearance** |
| `IslandHapticsSettingsSection()` — Trackpad haptics (Off / Gentle / Standard), Feel It | **Accessibility** |
| `IslandCoexistenceSettingsSection()` — other notch, HUD, menu bar and fn-dictation apps found, and what SparkV can turn off for each | **Advanced** |

Each is a native `Section { } header: { } footer: { }` for the pane's grouped
Form, in the app shell's own style. `IslandInteractionSettingsRoot()` stacks
all six in one Form.

## Gear menu

`IslandInteractionMenuItems` is already in the gear menu as
`Menu("Island Behavior") { IslandInteractionMenuItems() }`. It has: Keep
Drawer Open, Open By, Open After, Close After, Two-Finger Swipes, Click
Outside Closes, Esc Closes, ⌃⌥O Opens and Closes, Motion, Speed, Drawer
Width, Closed Width, Keep Clear of Menu Bar Items, Compact Now Playing,
Trackpad Haptics, and Island Behavior Settings… (`SparkVSettings.show(.island)`).

## Hub tile

`IslandInteractionHubTile()` — category **System** (step 14). It uses the
same face as the other Labs tiles (`LabsBHubTileBackground`). A click keeps
the drawer open or lets it close. Pinned to the header, it is a pin button
there.

## Hotkeys

- **⌃⌥O**: opens or closes the drawer. Opt-in, off by default (Settings ›
  Island or the gear menu). It opens at once with no animation, because it is
  keyboard-triggered. Checked against ⌃⌥J ⌃⌥R ⌃⌥S ⌃⌥T ⌃⌥H ⌃⌥C ⌃⌥F ⌃⌥A
  ⌃⌥B ⌃⌥E ⌃⌥I ⌃⌥K ⌃⌥M ⌃⌥N ⌃⌥P ⌃⌥⇧R ⌃⌥1–5 ⌃⌥Space ⌥Space ⌘⇧V ⌘1–9V
  in the repo and every package's working copy: no clash. If another app owns
  it, Settings says so. With VoiceOver on, the detail line notes that ⌃⌥ keys
  are VoiceOver's too.
- **Esc**: closes the drawer, but only while the pointer is on the open
  drawer (a temporary Carbon Esc, held only while the drawer's panel is not
  key) or the panel has the keyboard (the responder chain, so a field's own
  Esc runs first). It is never held globally, and not during a screen
  selection, dictation or Clicky.

## Controller

`IslandInteractionController` (`@MainActor ObservableObject`,
`start()`/`stop()`) is created and started inside `NotchWindowController`;
nothing to add. `IslandInteractionController.current` is the running one.
The views read `IslandInteractionSettings.shared`, `IslandWingRoom.shared`
and `.current`; none needs an `.environmentObject` except the hub tile,
which reads the drawer's `NotchState` (it is already in the drawer's
environment).

## Settings keys

`UserDefaults.standard`, prefix `IslandInteraction.`: `openTrigger`,
`openDelayMs`, `closeDelayMs`, `swipeGestures`, `clickOutsideCloses`,
`escapeCloses`, `returnsFocus`, `toggleHotkeyEnabled`, `motionStyle`,
`motionSpeed`, `drawerSize`, `closedWidth`, `compactNowPlaying`,
`avoidMenuBarItems`, `stepAsideForMenuBarManagers`,
`warnAboutOtherNotchApps`, `dismissedConflicts`. Haptics:
`SparkVHaptics.level` (shared by every feature).
Nothing leaves the Mac.

## Permissions

None required. Menu bar status items are read from
`CGWindowListCopyWindowInfo` (bounds, owner and layer only, which need no
Screen Recording). The front app's menus are avoided too, but only if
Accessibility is already allowed (`PermissionCenter.shared.isGranted`, which
never prompts). That read uses a 0.2 s timeout per element and runs off the
main thread.

## Energy

Nothing polls while idle.
- **Pointer:** the existing global mouse-moved monitor now also keeps a
  speed estimate (no allocation), and the hot zone is cached instead of
  being rebuilt on every move.
- **Scrolling:** the global scroll monitor returns at once unless a trackpad
  gesture starts on the closed island.
- **Window list:** read on screen changes, app activation, wings appearing
  or a layout change, at most once a second.
- **Menu bar managers:** only while one runs, one read when the pointer
  reaches the island. Only a bar that hangs below the menu bar row counts
  (never the stretched divider Ice, Hidden Bar and Dozer park in the row).
  If such a bar is over or under the island, it is checked twice a second
  while the pointer stays, at most 10 s; the pointer leaving, the bar going
  or the cap ends it and the island shows again.
- **Other notch apps:** checked 4 s after launch and 2 s after the last app
  launches or quits. Windows wider than half the screen or reaching more
  than 400 pt below the menu bar (dimmers, capture and presentation
  overlays) are skipped, and bundle IDs are looked up only for the windows
  left after the geometry test.
- **Hotkeys and timers:** Esc is registered only while the pointer is on the
  open drawer. Press and Hold uses one 0.4 s task per press.

## Notes for other packages' patches

These two Find blocks can't both match today's file, whatever this package
does. The Activities and ColorPicker packages anchor on the same line with
`NSEvent.mouseLocation`, so it stays as it is:

- **HUDPlus step 3** finds
  `// Over the File Drop shelf during a file drag: let the drop land there.` +
  `if !state.isExpanded, fileDrop.zoneContains(mouse) { return }`. Use
  `        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }`
  as its second Find line and as the matching Replace line. The behaviour is
  the same, because `mouse` is `NSEvent.mouseLocation`. Keep its HUD block
  before Activities' `handleActivityBandPointer()` call, as HUDPlus asks.
- **DevStatus/Teleprompter step 23** needs the same change (see Island
  Placement's notes).

**New haptics:** route any new performer through `SparkVHaptics.perform(_:)`
so the one Trackpad Haptics setting covers it. Never fire one on plain
hover.

**Interactive bands:** the "also at the notch" band
(`IslandCoexistenceBand`) is `isInteractive`. Its Review and dismiss buttons
take clicks once Activities' `handleActivityBandPointer()` is wired. Before
that the band still says what was found and expires after 8 s.
