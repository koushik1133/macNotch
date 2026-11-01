# Look & Layout: wiring steps for the integrator

Package: look, layout and hub organisation (requirements `layout-custom`,
`appearance`, `liquid-glass`, `contrast-transparency`, `text-size`,
`onboarding`).

Files this package owns and already changed (copy them as they are):

- `Sources/AppearanceSettings.swift`: accent, text size, resting opacity,
  decorative glows, drawer material, contrast preference, the live
  Increase Contrast / Reduce Transparency state (lock-protected
  `LookOptions.current`, updated by notification, never polled), and
  `LookGlass` (the glass tint and its contrast model). The change
  notification names what changed (`AppearanceSettings.affectsGeometry`).
- `Sources/SparkVTheme.swift`: contrast-aware tokens (textTertiary at least
  4.5:1 everywhere, the glass drawer included), `accentText` lifted to
  4.5:1 whatever the accent, `primaryFill` / `onPrimary`, `textScale`.
- `Sources/AgentsHubView.swift`: categories, customization, pinned header
  buttons (`HubPinnedHeaderButton`), `HubCatalog` and `HubPackageTile` (the
  list other packages' tiles go in, see the table below), `AgentTile`.
- `Sources/Labs/Onboarding/*`: Try It and Finish steps (Launch at Login and
  the menu bar icon through AppShell's `AppShellLoginItem` /
  `StatusItemController`), `OnboardingSettingsSection`, window placed on the
  island's display below the drawer.
- `Sources/Labs/NotchThemes/*`: `effectiveTheme` / `effectiveBackground`,
  Form-native `NotchThemeSettingsSection`, no backdrop under the glass drawer.
- `Sources/Labs/LookLayout/*` (new; needs `Sources/Labs/AppShell` compiled,
  which AppDelegate already requires).

Every step below is a find-and-replace. Each **Find** block occurs exactly
once in the file named in its heading (checked against `requirements-pass`
as of this package, with AppShell and IslandPlacement already wired). Apply
them in order. The **Find** text must match byte for byte.

## Settings panes, hub, menus, hotkeys

| View (no arguments) | Settings pane |
|---|---|
| `OnboardingSettingsSection` (Welcome Tour…, Terms & Privacy…) | General |
| `LayoutSettingsSection` | Island |
| `LayoutFeaturesSettingsSection` (per-feature on/off) | Island |
| `AppearanceSettingsSection` (replaces `AppShellLookSettingsSection`) | Appearance |
| `NotchThemeSettingsSection` | Appearance (below `AppearanceSettingsSection`) |
| `TextContrastSettingsSection` | Accessibility (above `AppShellAccessibilityStatusSection`) |

Each is a set of `Section`s for AppShell's grouped Form (step 5 puts them
in). The Look & Layout window (`LookLayoutWindowController.shared.show(page:
.layout | .appearance | .textContrast)`) hosts the same sections in its own
grouped Form; only its Layout page (drag lists) uses cards.

### Agents hub tiles from other packages

The hub is organised into All, Write, Screen, Focus, Files, Media, System,
Developer, Planner. Other packages' INTEGRATION.md files add their tiles to
the old grid in `AgentsHubView.swift`; **skip those AgentsHubView steps**
(AppShell 12, ColorPicker's grid step, HUDPlus, IslandPlacement 7,
MediaPlus 10-13, Planner's grid steps, SystemStatus's grid step, DevStatus's
grid step) and add one entry per tile to `HubCatalog.packageTiles` instead.
Keep each package's other AgentsHubView-free steps (tabs, environment
objects). `opensTab` needs that package's `NotchState.Tab` case, so add the
entry after its NotchState step; `HubEnvTile` reads an environment object
the drawer already injects.

```swift
    static let packageTiles: [HubPackageTile] = [
        // AppShell (System)
        HubPackageTile(info: HubTileInfo(id: "settings", title: "Settings", systemImage: "gearshape.fill", tint: Color(white: 0.72),
                                         category: .system, help: "SparkV Settings"),
                       pinAction: { _ in SparkVSettingsWindowController.shared.show() }) { _ in AnyView(SettingsHubTile()) },
        // ColorPicker (Screen)
        HubPackageTile(info: HubTileInfo(id: "colorPicker", title: "Colors", systemImage: "eyedropper", tint: .pink, category: .screen,
                                         help: "Color Picker"), opensTab: .colorPicker) { actions in
            AnyView(HubEnvTile { (picker: ColorPickerController) in
                ColorPickerHubTile(controller: picker, onOpen: { actions.openTab(.colorPicker) })
            })
        },
        // HUDPlus (System; its tile opens a menu)
        HubPackageTile(info: HubTileInfo(id: "hud", title: "HUD", systemImage: "speaker.wave.2.fill", tint: .gray, category: .system)) { _ in
            AnyView(HUDHubTile())
        },
        // IslandPlacement (System; a menu)
        HubPackageTile(info: HubTileInfo(id: "islandPlacement", title: "Island", systemImage: "rectangle.topthird.inset.filled", tint: .blue,
                                         category: .system)) { _ in AnyView(IslandPlacementHubTile()) },
        // MediaPlus (Media)
        HubPackageTile(info: HubTileInfo(id: "soundOutput", title: "Output", systemImage: "hifispeaker.fill", tint: .blue, category: .media)) { _ in
            AnyView(SoundOutputHubTile())
        },
        HubPackageTile(info: HubTileInfo(id: "appVolume", title: "App Volumes", systemImage: "slider.horizontal.3", tint: .orange, category: .media)) { _ in
            AnyView(AppVolumeHubTile())
        },
        HubPackageTile(info: HubTileInfo(id: "lyrics", title: "Lyrics", systemImage: "quote.bubble.fill", tint: .pink, category: .media),
                       pinAction: { _ in LyricsWindow.shared.show() }) { _ in AnyView(LyricsHubTile()) },
        // Planner (Planner; Launcher in System). Their tiles open Today's Planner pages.
        HubPackageTile(info: HubTileInfo(id: "agenda", title: "Agenda", systemImage: "calendar", tint: .red, category: .planner),
                       opensTab: .today) { _ in AnyView(AgendaHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "reminders", title: "Reminders", systemImage: "checklist", tint: .orange, category: .planner),
                       opensTab: .today) { _ in AnyView(RemindersHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "timers", title: "Timers", systemImage: "timer", tint: .orange, category: .planner),
                       opensTab: .today) { _ in AnyView(TimersHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "weather", title: "Weather", systemImage: "cloud.sun.fill", tint: .cyan, category: .planner),
                       opensTab: .today) { _ in AnyView(WeatherHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "launcher", title: "Launcher", systemImage: "square.grid.3x3.fill", tint: .indigo,
                                         category: .system)) { _ in AnyView(LauncherHubTile()) },
        // SystemStatus (System; Mic Mute in Media)
        HubPackageTile(info: HubTileInfo(id: "status", title: "Status", systemImage: "gauge.with.dots.needle.67percent", tint: .green,
                                         category: .system), opensTab: .status) { actions in
            AnyView(SystemStatusHubTile(onOpen: { actions.openTab(.status) }))
        },
        HubPackageTile(info: HubTileInfo(id: "keepAwake", title: "Keep Awake", systemImage: "cup.and.saucer.fill", tint: .brown,
                                         category: .system)) { _ in AnyView(KeepAwakeHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "micMute", title: "Mic", systemImage: "mic.slash.fill", tint: .red, category: .media)) { _ in
            AnyView(MicMuteHubTile())
        },
        // ShelfPlus (Files)
        HubPackageTile(info: HubTileInfo(id: "nearbyShare", title: "Nearby", systemImage: "wave.3.right.circle.fill", tint: .blue,
                                         category: .files)) { _ in AnyView(NearbyShareHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "fileTransfers", title: "Transfers", systemImage: "doc.on.doc.fill", tint: .blue,
                                         category: .files), opensTab: .downloads) { _ in AnyView(FileTransfersHubTile()) },
        // DevStatus (Developer; Teleprompter and Mirror in Media, Menu Bar in System)
        HubPackageTile(info: HubTileInfo(id: "codingAgents", title: "Agents", systemImage: "sparkles.rectangle.stack", tint: .purple,
                                         category: .developer), opensTab: .devStatus) { actions in
            AnyView(CodingAgentsHubTile(onOpen: { DevStatusNavigator.shared.section = .agents; actions.openTab(.devStatus) }))
        },
        HubPackageTile(info: HubTileInfo(id: "devStatus", title: "Servers", systemImage: "server.rack", tint: .green,
                                         category: .developer), opensTab: .devStatus) { actions in
            AnyView(DevStatusHubTile(onOpen: { actions.openTab(.devStatus) }))
        },
        HubPackageTile(info: HubTileInfo(id: "scripts", title: "Scripts", systemImage: "terminal.fill", tint: .gray,
                                         category: .developer), opensTab: .devStatus) { actions in
            AnyView(ScriptWidgetHubTile(onOpen: { DevStatusNavigator.shared.section = .scripts; actions.openTab(.devStatus) }))
        },
        HubPackageTile(info: HubTileInfo(id: "teleprompter", title: "Prompter", systemImage: "scroll", tint: .orange, category: .media)) { _ in
            AnyView(TeleprompterHubTile())
        },
        HubPackageTile(info: HubTileInfo(id: "cameraMirror", title: "Mirror", systemImage: "person.crop.square", tint: .teal, category: .media)) { _ in
            AnyView(CameraMirrorHubTile())
        },
        HubPackageTile(info: HubTileInfo(id: "menuBar", title: "Menu Bar", systemImage: "menubar.dock.rectangle", tint: .gray,
                                         category: .system), opensTab: .menuBar) { actions in
            AnyView(MenuBarOverflowHubTile(onOpen: { actions.openTab(.menuBar) }))
        },
    ]
```

Check each `pinAction` against the package's current API when you paste it
(`SparkVSettingsWindowController.shared.show()`, `LyricsWindow.shared.show()`);
drop the `pinAction:` argument to make a tile not pinnable. A new tile
appears next to the tile before it in the default order, even for users who
already rearranged the hub; the hub's height follows its rows (up to 5,
then "All" scrolls).

**Planner step 3** edits the Today `IconTab`'s help text, which step 3e
below replaces: instead, change `help:` of `"today"` in `HeaderCatalog.items`
(`Sources/Labs/LookLayout/LayoutModel.swift`) and of `"tab.today"` in
`HubCatalog.standIns` (`Sources/AgentsHubView.swift`) to Planner's text.

**Header controls from other packages:** add a `HeaderItemInfo` to
`HeaderCatalog.items` (with its side and an optional hub stand-in tile), add
its view as a `case` in `headerItem(_:)` (step 3e), and, because each side
already holds six controls, put its id in `HeaderCatalog.hiddenByDefault`
so it starts hidden, on fresh installs too; a side that still goes over
budget hides its last controls, which then get their hub stand-ins.

**Gear menu:** `AppearanceMenuItems` and `LayoutMenuItems` (step 3g; Layout
has Header Controls, Features and Customize Layout…), `OnboardingMenuItems`
(already in the gear menu: Welcome Tour…, Permissions & Setup…, Terms &
Privacy…).

**Hotkeys:** none added. (Checked: ⌃⌥J ⌃⌥R ⌃⌥S ⌃⌥T ⌃⌥⇧R ⌃⌥1–5 ⌥Space ⌘⇧V
⌘1–9V ⌃⌘V ⌃⌘C fn⌃ are untouched; ⌃⌥C stays free for the color picker.)

**Menu bar icon:** this package adds none; AppShell's `StatusItemController`
is the only one and the tour's Finish step turns it on or off.

## 1. build.sh: compile the new folder

### File: `build.sh`

Find:
```zsh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```
Replace with:
```zsh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/LookLayout/*.swift "$WORK/src/"
```

## 2. NotchState.swift: drawer size follows Text Size and the hub's rows

The open drawer's content zooms with Text Size (1, 1.12, 1.25), so the
drawer body grows by the same factor (header band excluded). The Agents hub's
height now includes its category bar and follows the number of visible tiles.

### File: `Sources/NotchState.swift`

Find:
```swift
        let rows = CGFloat(AgentHubMetrics.rows)
        // +4: tiles with two-line labels grow a few points past tileHeight.
        return collapsedSize.height + rows * AgentHubMetrics.tileHeight + (rows - 1) * AgentHubMetrics.spacing + drawerBottomPadding + 4
```
Replace with:
```swift
        // Category bar, rows of tiles (+4 for two-line labels), see AgentHubMetrics.
        return collapsedSize.height + AgentHubMetrics.contentHeight + drawerBottomPadding
```

### File: `Sources/NotchState.swift`

Find:
```swift
        return CGSize(width: expandedSize.width, height: height)
```
Replace with:
```swift
        // Text Size: the content area grows with the zoom (Look & Layout).
        return LookDrawerMetrics.zoomed(CGSize(width: expandedSize.width, height: height),
                                        header: collapsedSize.height, bottomInset: drawerBottomPadding)
```

## 3. NotchNookLayoutView.swift

### 3a. Drawer material (black or Liquid Glass)

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
            shape.fill(SparkVTheme.islandBackground)
```
Replace with:
```swift
            // Black, or Liquid Glass while open (Appearance › Drawer); always
            // black when closed and with Reduce Transparency.
            LookDrawerBackground(shape: shape, isExpanded: state.isExpanded, headerHeight: state.collapsedSize.height,
                                 hasNotch: state.surface.hasNotch)
```

### 3b. Album Glow pauses with Decorative Glows off, Reduce Transparency or higher contrast

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
            if themeSettings.background == .albumGlow, state.isExpanded, state.tab == .nook {
```
Replace with:
```swift
            if themeSettings.effectiveBackground == .albumGlow, state.isExpanded, state.tab == .nook {
```

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
            } else if themeSettings.background == .albumGlow, !state.isExpanded, wingsSource == .nowPlaying {
```
Replace with:
```swift
            } else if themeSettings.effectiveBackground == .albumGlow, !state.isExpanded, wingsSource == .nowPlaying {
```

### 3c. Text Size: the drawer's content zooms

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
                    ZStack {
                        tabContent
                            .id(state.tab)
                            .transition(.sparkVCrossfade)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(NotchMetrics.tabAnimation, value: state.tab)
```
Replace with:
```swift
                    // Text Size: laid out at Standard and zoomed to fill the
                    // (larger) drawer, so every tab grows evenly.
                    LookDrawerZoom {
                        ZStack {
                            tabContent
                                .id(state.tab)
                                .transition(.sparkVCrossfade)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(NotchMetrics.tabAnimation, value: state.tab)
                    }
```

### 3d. Resting opacity (displays without a notch only)

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
        .clipShape(shape)
```
Replace with:
```swift
        .clipShape(shape)
        // Appearance › Island at Rest: only while resting with nothing to
        // show, only without a camera notch, never with Reduce Transparency.
        .opacity(LookResting.opacity(isResting: !state.isExpanded && closed == nil, hasNotch: state.surface.hasNotch))
```

### 3d1. No theme or Ambient Light glow behind the Liquid Glass drawer

They sit behind the body and would show through the glass (and make it
re-blur every frame). `NotchThemeBackdrop` already steps aside by itself.

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
            AmbientNotchGlowBackdrop(bodySize: size, topRadius: radii.top, bottomRadius: radii.bottom)
```
Replace with:
```swift
            if !LookDrawerMaterial.hidesBackdrops(isExpanded: state.isExpanded) {
                AmbientNotchGlowBackdrop(bodySize: size, topRadius: radii.top, bottomRadius: radii.bottom)
            }
```

### 3d2. The drawer springs to the hub category's height

Switching the Agents hub's category (All, Write, …) changes the hub's rows;
the drawer follows with the island's own spring while the grid crossfades.

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
    @ObservedObject private var themeSettings = NotchThemeSettings.shared
```
Replace with:
```swift
    @ObservedObject private var themeSettings = NotchThemeSettings.shared
    /// The Agents hub's rows (its category) set the drawer's height.
    @ObservedObject private var layout = LayoutSettings.shared
```

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
        .animation(NotchMetrics.hoverAnimation, value: state.tab)
```
Replace with:
```swift
        .animation(NotchMetrics.hoverAnimation, value: state.tab)
        .animation(NotchMetrics.hoverAnimation, value: layout.hub.category)
```

### 3e. Header: controls, order and pins from Customize Layout

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
    /// The active tab's pill is one shape that slides between icons.
    @Namespace private var pill
```
Replace with:
```swift
    /// The active tab's pill is one shape that slides between icons.
    @Namespace private var pill
    /// Which controls show, in what order, and pinned hub tiles.
    @ObservedObject private var headerLayout = LayoutSettings.shared
```

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
        HStack(spacing: 2) {
            // Places on the left, actions on the right; the camera cutout sits
            // in the gap between them. Icons only, each with a tooltip.
            IconTab(systemImage: "house.fill", tab: .nook, help: "Home: media, shortcuts and mirror", pill: pill)
            IconTab(systemImage: "rectangle.3.group.fill", tab: .widgets, help: "Widgets: world clocks, volume, habits, system and network", pill: pill)
            IconTab(systemImage: "tray.full.fill", tab: .tray, help: "Tray: screenshots, text and files", pill: pill)
            IconTab(systemImage: "calendar", tab: .today, help: "Today: meetings and timer", pill: pill)
            IconTab(systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard", tab: .converter, help: "Convert: drop a file, pick a format", pill: pill)
            IconTab(systemImage: "square.stack.3d.up.fill", tab: .spaces, help: "Spaces: knowledge folders per organization", pill: pill)
            Spacer(minLength: 0)
            if assistant.phase != .recording {
                FocusHeaderButton()
            }
            RecordMeetingButton()
            IconTab(systemImage: "square.grid.2x2.fill", tab: .agents, help: "Agents: search, focus, capture, reply, screen, prompts, clipboard, files, downloads and more",
                    activeFor: NotchState.Tab.agentTabs, pill: pill)
            // Original SF Symbols, not the Wispr Flow or Clicky logos.
            IconTab(systemImage: "waveform", tab: .flow, help: "Flow: dictation history and notes", pill: pill)
            IconTab(systemImage: "cursorarrow.rays", tab: .clicky, help: "Clicky: ask about your screen", pill: pill)
            SettingsMenu()
        }
```
Replace with:
```swift
        // Customize Layout decides which controls show and in what order,
        // and adds pinned hub tiles where a slot is free (six per side, the
        // gear included on the right). While recording, Focus steps aside
        // for the timer pill (and a pin if the side is full).
        // Switched-off features (Customize Layout › Features) are left out.
        let placement = headerLayout.effectiveHeader.placement(recording: assistant.phase == .recording)
        HStack(spacing: 2) {
            // Places on the left, actions on the right; the camera cutout sits
            // in the gap between them. Icons only, each with a tooltip.
            ForEach(placement.left, id: \.self) { id in headerItem(id) }
            Spacer(minLength: 0)
            ForEach(placement.right, id: \.self) { id in headerItem(id) }
            SettingsMenu()
        }
```

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
        .animation(NotchMetrics.tabPillAnimation, value: state.tab)
    }
}
```
Replace with:
```swift
        .animation(NotchMetrics.tabPillAnimation, value: state.tab)
    }

    /// One header control by its Customize Layout id; anything else is a
    /// hub tile pinned to the header.
    @ViewBuilder
    private func headerItem(_ id: String) -> some View {
        switch id {
        case "focus":
            FocusHeaderButton()
        case "record":
            RecordMeetingButton()
        case "agents":
            // A page a pinned tile opens lights that pin, not Agents.
            IconTab(systemImage: "square.grid.2x2.fill", tab: .agents, help: HeaderCatalog.info(id)?.help ?? "Agents",
                    activeFor: HubCatalog.agentsActiveTabs(pins: headerLayout.header.pins), pill: pill)
        default:
            // Original SF Symbols, not the Wispr Flow or Clicky logos.
            if let tab = HeaderTabs.tab(for: id), let item = HeaderCatalog.info(id) {
                IconTab(systemImage: item.systemImage, tab: tab, help: item.help, pill: pill)
            } else {
                HubPinnedHeaderButton(id: id)
            }
        }
    }
}
```

### 3f. Home: empty shortcut buttons (no "Add Action" placeholder)

The column follows Show Empty Shortcut Buttons live, and right-click on it
always offers Add Shortcut (also when every empty button is hidden).

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
private struct MacroColumn: View {
    @EnvironmentObject private var macros: MacroController

    var body: some View {
        VStack(spacing: 7) {
            ForEach(macros.slots) { slot in
                MacroCapsule(slot: slot, status: macros.status(for: slot))
            }
        }
    }
}
```
Replace with:
```swift
private struct MacroColumn: View {
    @EnvironmentObject private var macros: MacroController
    /// Customize Layout › Show Empty Shortcut Buttons (on by default).
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        let shown = macros.slots.filter { !layout.hidesEmptyShortcuts || macros.status(for: $0) != .unassigned }
        VStack(spacing: 7) {
            ForEach(shown) { slot in
                MacroCapsule(slot: slot, status: macros.status(for: slot))
            }
            if shown.isEmpty {
                // Every button is empty and hidden: keep a quiet area to right-click.
                Color.clear.frame(height: 28)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let empty = macros.slots.first(where: { macros.status(for: $0) == .unassigned }) {
                Menu("Add Shortcut") { ShortcutPickerItems(slot: empty) }
            }
            Toggle("Show Empty Shortcut Buttons", isOn: Binding(
                get: { !layout.hidesEmptyShortcuts }, set: { layout.hidesEmptyShortcuts = !$0 }
            ))
        }
    }
}
```

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
    private var capsule: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
```
Replace with:
```swift
    private var capsule: some View {
        HStack(spacing: 6) {
            if status == .unassigned {
                // No placeholder text: a quiet centered plus (click to choose).
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .accessibilityLabel("Choose a shortcut for this button")
                Spacer(minLength: 0)
            } else {
                statusIcon
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
```

### 3g. Gear menu: Appearance and Layout submenus

### File: `Sources/NotchNookLayoutView.swift`

Find:
```swift
            AppearanceMenu()
```
Replace with:
```swift
            Menu("Appearance") { AppearanceMenuItems() }
            Menu("Layout") { LayoutMenuItems() }
```

## 4. NotchWindowController.swift

### 4a. Open Drawer On

### File: `Sources/NotchWindowController.swift`

Find:
```swift
    private func openFromHover() {
        if let tab = hoverTab {
            state.select(tab)
        }
```
Replace with:
```swift
    private func openFromHover() {
        if let tab = hoverTab {
            state.select(tab)
        } else if let tab = LayoutSettings.shared.openTab {
            // Customize Layout › Open Drawer On (Last Used keeps the tab).
            state.select(tab)
        }
```

### 4b. Tell onboarding's Try It step the drawer opened

### File: `Sources/NotchWindowController.swift`

Find:
```swift
        media.setActive(expanded)
        if expanded {
```
Replace with:
```swift
        media.setActive(expanded)
        if expanded {
            NotificationCenter.default.post(name: .sparkVIslandDidExpand, object: nil)
```

### 4c. Resize when Text Size, glows or the hub's tiles change

### File: `Sources/NotchWindowController.swift`

Find:
```swift
        observe(.notchThemePreviewRequested, on: .default) { $0.previewTheme() }
```
Replace with:
```swift
        observe(.notchThemePreviewRequested, on: .default) { $0.previewTheme() }
        // Text Size changes the drawer's size, Decorative Glows and Reduce
        // Transparency the theme margin (an accent or look change resizes
        // nothing), hiding hub tiles the Agents hub's height. resizeForTab
        // grows at once and shrinks after the drawer's spring.
        let lookToken = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let resizes = AppearanceSettings.affectsGeometry(note)
            MainActor.assumeIsolated { if resizes { self?.resizeForTab() } }
        }
        observers.append((NotificationCenter.default, lookToken))
        observe(LayoutSettings.didChangeNotification, on: .default) { $0.resizeForTab() }
```

### 4d. No pointer tracking or preview for a theme that is paused

### File: `Sources/NotchWindowController.swift`

Find:
```swift
        guard NotchThemeSettings.shared.theme.usesPointer else {
```
Replace with:
```swift
        guard NotchThemeSettings.shared.effectiveTheme.usesPointer else {
```

### File: `Sources/NotchWindowController.swift`

Find:
```swift
        guard !state.isExpanded, NotchThemeSettings.shared.theme != .plain else { return }
```
Replace with:
```swift
        guard !state.isExpanded, NotchThemeSettings.shared.effectiveTheme != .plain else { return }
```

### 4e. Where the island is (Island at Rest, onboarding)

Island Placement can put the island on another display than the notched
one; `LookIsland` keeps the display the window last used, for the Try It
step's wording and the onboarding window's position.

### File: `Sources/NotchWindowController.swift`

Find:
```swift
        if state.surface != surface { state.surface = surface }
```
Replace with:
```swift
        if state.surface != surface { state.surface = surface }
        LookIsland.note(screen: screen, hasNotch: geo.hasNotch)
```

### File: `Sources/NotchWindowController.swift`

Find:
```swift
            islandScreenFrame = .zero
            placement.noteIslandDisplay(nil)
```
Replace with:
```swift
            islandScreenFrame = .zero
            LookIsland.note(screen: nil, hasNotch: false)
            placement.noteIslandDisplay(nil)
```

### 4f. Features that can be switched off (Customize Layout › Features)

Each controller starts only while its feature is on, and stops (hotkey,
key monitor, watchers) the moment it is switched off. All are on by default,
so nothing changes for a user who never touches the switches.

### File: `Sources/NotchWindowController.swift`

Find:
```swift
        dictation.start()
        clicky.start()
        [hud.start, power.start, timer.start, meetings.start, notifications.start].forEach { $0() }
```
Replace with:
```swift
        // Customize Layout › Features: each starts only while switched on.
        let features = FeatureSwitches.shared
        features.connect(.flow, start: { [weak dictation] in dictation?.start() }, stop: { [weak dictation] in dictation?.shutdown() })
        features.connect(.clicky, start: { [weak clicky] in clicky?.start() }, stop: { [weak clicky] in clicky?.shutdown() })
        [hud.start, power.start, timer.start, notifications.start].forEach { $0() }
        features.connect(.today, start: { [weak meetings] in meetings?.start() }, stop: { [weak meetings] in meetings?.stop() })
```

### File: `Sources/NotchWindowController.swift`

Find:
```swift
        spacesIngest.start()
```
Replace with:
```swift
        FeatureSwitches.shared.connect(.spaces, start: { [weak spacesIngest] in spacesIngest?.start() },
                                       stop: { [weak spacesIngest] in spacesIngest?.stop() })
```

## 5. Settings window panes (AppShell)

The sections are `Section`s for AppShell's grouped Form. Appearance's look
picker replaces `AppShellLookSettingsSection` (keep one look picker).
Accessibility keeps `AppShellAccessibilityStatusSection` for the live
system switches (Text & Contrast no longer repeats them). General keeps
AppShell's Startup (Launch at Login) and Menu Bar sections, the only ones:
the tour's Finish step uses the same `AppShellLoginItem` and
`StatusItemController`, and this package adds no status item of its own.

### File: `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Find:
```swift
            // ▸ General: add sections above this line
```
Replace with:
```swift
            OnboardingSettingsSection()
            // ▸ General: add sections above this line
```

### File: `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Find:
```swift
            // ▸ Island: add sections above this line
```
Replace with:
```swift
            LayoutSettingsSection()
            LayoutFeaturesSettingsSection()
            // ▸ Island: add sections above this line
```

### File: `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Find:
```swift
            AppShellLookSettingsSection()
```
Replace with:
```swift
            AppearanceSettingsSection()
            NotchThemeSettingsSection()
```

### File: `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Find:
```swift
            AppShellAccessibilityStatusSection()
            // ▸ Accessibility: add sections above this line
```
Replace with:
```swift
            TextContrastSettingsSection()
            AppShellAccessibilityStatusSection()
            // ▸ Accessibility: add sections above this line
```

## What it stores (UserDefaults)

| Key | Meaning |
|---|---|
| `AppearanceStyle` | look (unchanged) |
| `SparkV.appearance.accent`, `.customAccent` | accent choice, custom color as `#RRGGBB` |
| `SparkV.appearance.textSize` | standard / large / larger |
| `SparkV.appearance.restingOpacity` | solid / soft / faint |
| `SparkV.appearance.decorativeGlows` | Bool, default true |
| `SparkV.appearance.drawerMaterial` | black / liquidGlass |
| `SparkV.appearance.contrast` | system / higher |
| `SparkV.layout.headerLeft`, `.headerRight`, `.headerHidden`, `.headerPins` | header order, hidden controls, pinned hub tile ids |
| `SparkV.layout.hubOrder`, `.hubHidden`, `.hubCategory` | hub tile order, hidden tiles, selected category |
| `SparkV.layout.openOn` | tab the drawer opens on (lastUsed default) |
| `SparkV.layout.hidesEmptyShortcuts` | hide unassigned Home shortcut buttons |
| `SparkV.layout.featuresOff` | features switched off (Customize Layout › Features); none by default |
| `SparkV.onboarding.triedIsland`, `.finishSeenAt` | Try It done, tour finished |

The menu bar icon and Launch at Login are AppShell's (`AppShell.statusItem.visible`, `SMAppService.mainApp`).

## Behavior notes

- Nothing polls. Increase Contrast / Reduce Transparency arrive by
  `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, the macOS
  accent by `NSColor.systemColorsDidChangeNotification`; both update the
  lock-protected `LookOptions.current` and rebuild the roots once.
- Liquid Glass (`glassEffect`, macOS 26+; `.ultraThinMaterial` + black on
  macOS 15) is drawn only while the drawer is open and is removed when it
  closes; it never animates on its own and sits under no TimelineView. With
  Reduce Transparency the drawer stays black.
- Text Size zooms the drawer's content with `scaleEffect` (text is drawn at
  the zoomed size and stays sharp; clicks, hover and drops follow). The base
  theme fonts (`title`, `headline`, …) keep their size because they also draw
  the closed island's bands; windows use `SparkVTheme.font(...)` /
  `SparkVTheme.Scaled.*` to grow with it.
- The hub's height follows the selected category's rows (All: every
  visible tile; Write: one row, ...). The panel grows at once and shrinks
  after the drawer's spring (`resizeForTab`, via `LayoutSettings.didChangeNotification`).
- Hiding a header control never removes the feature: it appears as a tile in
  the hub (Home, Tray, Today, Convert, Spaces, Meeting, Flow, Clicky). Agents
  can't be hidden. Pins need a free slot (hide a control first): six controls
  fit each side of the camera housing.
- The Try It step only listens for `.sparkVIslandDidExpand`; it never asks for
  a permission. Its "rest here" pulse plays three 300 ms pulses (again when
  the hint appears) and stops; the permission-status timer runs only on the
  Permissions step.
- The custom accent's color panel listens only during its own session (it
  ends when the panel closes or another window takes focus) and commits once
  per pick, so the Modes editor's color wells never change the accent.
- Features switched off stop their controllers (`FeatureSwitches.connect`
  hooks: `dictation.start/shutdown`, `clicky.start/shutdown`,
  `meetings.start/stop`, `spacesIngest.start/stop`); Convert has no
  background work and is only removed.
