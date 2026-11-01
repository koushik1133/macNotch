# Developer & Extras: integration

This package adds three lab folders and upgrades the camera mirror:

| Path | What |
|---|---|
| `Sources/Labs/DevStatus/` | **Coding Agents** (Claude Code, Codex, Cursor sessions; optional 127.0.0.1 hook with Allow / Deny), **Dev Status** (local dev-server ports, GitHub Actions, long-command finished), **Scripts & Tickers** (xbar-style shell-command widgets; tickers are presets), the Dev drawer tab, and `ExtrasUI.swift` (shared settings rows, hub-tile face, pills; used by all three folders and the mirror) |
| `Sources/Labs/Teleprompter/` | **Teleprompter**: a non-activating panel under the notch, `sharingType = .none`, speed / size / mirror / countdown, on-device voice pacing, a script editor window |
| `Sources/Labs/MenuBarOverflow/` | **Menu Bar Overflow**: menu bar extras hidden behind the notch, listed in a drawer tab and pressed through Accessibility; optional divider (Hidden Bar technique) |
| `Sources/CameraMirrorView.swift` | **Mirror**: camera picker (built-in, external, Continuity), mirrored / natural, Center Stage, Video Effects, a large pop-out mirror under the notch, optional pop-out when a call app turns the camera on |

No other file was edited. Every change below goes into an existing file. Apply the steps **in order**; each **Find** block is copied from the current source and occurs exactly once at that point (checked by a script). Steps marked *optional* can be skipped.

**Validated against the live tree** (1 Nov, after the Look & Layout hub rewrite): every Find block was counted in a fresh copy of `Sources/` (each occurs once), all steps were applied, and the copy typechecked in Swift 5 and Swift 6 with every lab folder in `Sources/Labs` compiled (`validate/tcsnap.sh <copy> 5|6`). No error comes from this package; the tree's own pre-existing errors are listed in the package report.

**Shared lines this package does not touch:** `NotchMetrics.tallTabs` (System Status, Color Picker and Planner each replace that line; Dev and Menu Bar get their own heights in steps 6 and 7 instead). Hub tiles go after the commented example in `HubCatalog.packageTiles`, which stays, like the Media package's.

**Nothing new needs `.environmentObject`:** every view reads its controller through `.shared` (or `CameraController.current`, set by the existing `CameraController()` in `NotchWindowController`).

## Steps

### Step 1: Compile the three new lab folders

**File:** `build.sh`

Teleprompter, MenuBarOverflow and Sources/CameraMirrorView.swift use the shared UI in DevStatus/ExtrasUI.swift, so all three go in together.

**Find (occurs once):**

````sh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
````

**Replace with:**

````sh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/DevStatus/*.swift "$WORK/src/"
cp Sources/Labs/Teleprompter/*.swift "$WORK/src/"
cp Sources/Labs/MenuBarOverflow/*.swift "$WORK/src/"
````

### Step 2: Camera usage text names every camera; allow Continuity Camera

**File:** `Info.plist`

Without NSCameraUseContinuityCameraDeviceType macOS hides iPhones from the mirror's camera list.

**Find (occurs once):**

````xml
	<key>NSCameraUsageDescription</key>
	<string>SparkV uses your FaceTime HD camera for the private mirror preview, to warn you when you sit too close to the screen (Screen Distance, if you turn it on) and, if you set it up, to recognize your face and unlock your Mac. Video is processed on-device and never leaves your Mac.</string>
````

**Replace with:**

````xml
	<key>NSCameraUseContinuityCameraDeviceType</key>
	<true/>
	<key>NSCameraUsageDescription</key>
	<string>SparkV uses the camera you choose (the built-in FaceTime HD camera, an external webcam or a Continuity Camera iPhone) for the private mirror preview, to warn you when you sit too close to the screen (Screen Distance, if you turn it on) and, if you set it up, to recognize your face and unlock your Mac. Video is processed on-device and never leaves your Mac.</string>
````

### Step 3: Automation text mentions jumping to a terminal tab

**File:** `Info.plist`

**Find (occurs once):**

````xml
	<key>NSAppleEventsUsageDescription</key>
	<string>SparkV reads the current track from Music and Spotify and sends play, pause and skip commands to them. When you choose Save to Spaces, it reads the open page from Safari, Chrome, Arc, Edge or Brave, or the selected message in Mail. The Job Agent reads the address and title of the job page you capture with fn + Control. During Focus, it reads the address of the front browser tab to spot sites you chose to block. During a Mode, SparkV opens your chosen music in its own Safari window (or plays a playlist in Music) and closes only that window when the mode ends, and switches between light and dark appearance through System Events.</string>
````

**Replace with:**

````xml
	<key>NSAppleEventsUsageDescription</key>
	<string>When you click Go to on a coding agent, SparkV selects its tab in Terminal or iTerm2. SparkV reads the current track from Music and Spotify and sends play, pause and skip commands to them. When you choose Save to Spaces, it reads the open page from Safari, Chrome, Arc, Edge or Brave, or the selected message in Mail. The Job Agent reads the address and title of the job page you capture with fn + Control. During Focus, it reads the address of the front browser tab to spot sites you chose to block. During a Mode, SparkV opens your chosen music in its own Safari window (or plays a playlist in Music) and closes only that window when the mode ends, and switches between light and dark appearance through System Events.</string>
````

### Step 4: Two drawer tabs: Dev and Menu Bar

**File:** `Sources/NotchState.swift`

**Find (occurs once):**

````swift
        /// Fan Control: fan speeds, temperatures, presets (Agents hub tile).
        case fans
````

**Replace with:**

````swift
        /// Fan Control: fan speeds, temperatures, presets (Agents hub tile).
        case fans
        /// Developer: coding agents, local servers, GitHub Actions, scripts
        /// (Agents hub tiles; approval bands open it).
        case devStatus
        /// Menu bar icons hidden by the notch (Agents hub tile, ⌃⌥B).
        case menuBar
````

### Step 5: Both open from the Agents hub

**File:** `Sources/NotchState.swift`

**Find (occurs once):**

````swift
            .focus, .search, .replyDrafter, .fileDrop, .downloads, .fans,
````

**Replace with:**

````swift
            .focus, .search, .replyDrafter, .fileDrop, .downloads, .fans, .devStatus, .menuBar,
````

### Step 6: Dev and Menu Bar get their own drawer heights

**File:** `Sources/NotchState.swift`

`tallTabs` is left alone: the System Status, Color Picker and Planner packages each replace that whole line, so this package never touches it.

**Find (occurs once):**

````swift
    static let drawerBottomPadding: CGFloat = 8
````

**Replace with:**

````swift
    static let drawerBottomPadding: CGFloat = 8
    /// The Dev tab: an approval card plus three session rows.
    static let devStatusExpandedHeight: CGFloat = 200
    /// The Menu Bar tab: its header and two rows of icon tiles.
    static var menuBarExpandedHeight: CGFloat {
        collapsedSize.height + MenuBarOverflowMetrics.contentHeight + drawerBottomPadding
    }
````

### Step 7: …and their heights in expandedSize(for:)

**File:** `Sources/NotchState.swift`

The Menu Bar page needs 136 pt under the header (two 42 pt rows of tiles), more than the 114 pt of the tall drawer, so it gets its own height (182 pt) instead of joining `tallTabs`.

**Find (occurs once):**

````swift
        let height: CGFloat = if tab == .agents {
            agentsExpandedHeight
        } else if tallTabs.contains(tab) {
````

**Replace with:**

````swift
        let height: CGFloat = if tab == .agents {
            agentsExpandedHeight
        } else if tab == .devStatus {
            devStatusExpandedHeight
        } else if tab == .menuBar {
            menuBarExpandedHeight
        } else if tallTabs.contains(tab) {
````

### Step 8: Draw the two tabs

**File:** `Sources/NotchNookLayoutView.swift`

**Find (occurs once):**

````swift
        case .fans: FanTabView()
````

**Replace with:**

````swift
        case .fans: FanTabView()
        case .devStatus: DevStatusDrawerView()
        case .menuBar: MenuBarOverflowDrawerView()
````

### Step 9: Mirror circle follows the Mirror Image setting

**File:** `Sources/NotchNookLayoutView.swift`

**Find (occurs once):**

````swift
private struct MirrorColumn: View {
    @EnvironmentObject private var camera: CameraController
````

**Replace with:**

````swift
private struct MirrorColumn: View {
    @EnvironmentObject private var camera: CameraController
    @ObservedObject private var mirrorSettings = CameraMirrorSettings.shared
````

### Step 10: …pass it to the preview

**File:** `Sources/NotchNookLayoutView.swift`

**Find (occurs once):**

````swift
                        CameraMirrorView(session: camera.session)
````

**Replace with:**

````swift
                        CameraMirrorView(session: camera.session, mirrored: mirrorSettings.isMirrored)
````

### Step 11: Right-click the circle: camera, mirror, large mirror

**File:** `Sources/NotchNookLayoutView.swift`

**Find (occurs once):**

````swift
            .help(camera.errorMessage ?? "Toggle camera mirror")
````

**Replace with:**

````swift
            .help(camera.errorMessage ?? "Toggle camera mirror")
            .contextMenu { CameraMirrorMenuItems() }
````

### Step 12: Leaving Home keeps a popped-out mirror running

**File:** `Sources/NotchNookLayoutView.swift`

**Find (occurs once):**

````swift
        .onDisappear { camera.stop() }
````

**Replace with:**

````swift
        // The circle shows the camera whenever it runs: closing the large
        // mirror while it is on screen keeps the camera on here.
        .onAppear { camera.drawerPreviewAppeared() }
        .onDisappear { camera.releaseDrawerPreview() }
````

### Step 13: Gear menu entries

**File:** `Sources/NotchNookLayoutView.swift`

**Find (occurs once):**

````swift
            Menu("Fans") { FanMenuItems() }
````

**Replace with:**

````swift
            Menu("Fans") { FanMenuItems() }
            Menu("Developer") {
                CodingAgentsMenuItems()
                Divider()
                DevStatusMenuItems()
            }
            Menu("Scripts") { ScriptWidgetMenuItems() }
            Menu("Teleprompter") { TeleprompterMenuItems() }
            Menu("Mirror") { CameraMirrorMenuItems() }
            Menu("Menu Bar Icons") { MenuBarOverflowMenuItems() }
````

### Step 14: Hub tiles for the six features

**File:** `Sources/AgentsHubView.swift`

Categories: Agents, Dev and Scripts → **Developer**; Prompter and Mirror → **Media**; Menu Bar → **System**. The anchor is the commented example inside `HubCatalog.packageTiles` and is kept, so other packages' entries (Media, HUD, …) can be inserted after it in any order. Each tile's right-click menu ends with the hub's own Pin / Hide / Move items (`hubID`).

**Find (occurs once):**

````swift
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
````

**Replace with:**

````swift
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
            // Developer & Extras (Labs/DevStatus, Teleprompter, MenuBarOverflow, CameraMirrorView.swift).
            HubPackageTile(info: HubTileInfo(id: "codingAgents", title: "Agents", systemImage: "sparkles.rectangle.stack",
                                             tint: Color(red: 0.85, green: 0.47, blue: 0.34), category: .developer,
                                             help: "Coding Agents: Claude Code, Codex and Cursor sessions"),
                           pinAction: { DevStatusNavigator.shared.open(.agents) }) {
                AnyView(CodingAgentsHubTile(hubID: "codingAgents"))
            },
            HubPackageTile(info: HubTileInfo(id: "devStatus", title: "Dev", systemImage: "server.rack", tint: .teal,
                                             category: .developer, help: "Dev Status: local servers, GitHub Actions"),
                           pinAction: {
                               let nav = DevStatusNavigator.shared
                               nav.open(nav.section == .agents ? .servers : nav.section)
                           }) {
                AnyView(DevStatusHubTile(hubID: "devStatus"))
            },
            HubPackageTile(info: HubTileInfo(id: "scripts", title: "Scripts", systemImage: "terminal.fill", tint: Color(white: 0.78),
                                             category: .developer, help: "Scripts: your shell commands' output, xbar-style"),
                           pinAction: { DevStatusNavigator.shared.open(.scripts) }) {
                AnyView(ScriptWidgetHubTile(hubID: "scripts"))
            },
            HubPackageTile(info: HubTileInfo(id: "teleprompter", title: "Prompter", systemImage: "scroll", tint: .indigo,
                                             category: .media, help: "Teleprompter under the camera"),
                           pinAction: { TeleprompterController.shared.toggleShown() }) {
                AnyView(TeleprompterHubTile(hubID: "teleprompter"))
            },
            HubPackageTile(info: HubTileInfo(id: "mirror", title: "Mirror", systemImage: "person.crop.square", tint: .green,
                                             category: .media, help: "A large mirror under the notch"),
                           pinAction: { CameraController.current?.togglePopOut() }) {
                AnyView(CameraMirrorHubTile(hubID: "mirror"))
            },
            HubPackageTile(info: HubTileInfo(id: "menuBar", title: "Menu Bar", systemImage: "menubar.dock.rectangle", tint: Color(white: 0.8),
                                             category: .system, help: "Menu bar icons hidden by the notch"),
                           pinAction: { MenuBarOverflowController.shared.onOpenDrawer?() }) {
                AnyView(MenuBarOverflowHubTile(hubID: "menuBar"))
            },
````

### Step 15: …the Dev and Menu Bar tiles name their tabs (pinned header buttons show as selected)

**File:** `Sources/AgentsHubView.swift`

**Find (occurs once):**

````swift
    static func tab(for id: String) -> NotchState.Tab? {
        switch id {
````

**Replace with:**

````swift
    static func tab(for id: String) -> NotchState.Tab? {
        switch id {
        case "devStatus": .devStatus
        case "menuBar": .menuBar
````

### Step 16: Create, connect and start the controllers

**File:** `Sources/NotchWindowController.swift`

**Find (occurs once):**

````swift
        FanController.shared.connect(activities: activities, opensTab: .fans)
````

**Replace with:**

````swift
        FanController.shared.connect(activities: activities, opensTab: .fans)
        // Developer & Extras (Labs/DevStatus, Teleprompter, MenuBarOverflow).
        // Everything that reads files, listens or polls is off until the
        // user turns it on; start() only restores what was on.
        let openDev: () -> Void = { [weak self] in
            // A hub tile or menu: the hub's own short ease-out tab switch.
            withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) {
                self?.state.select(.devStatus)
            }
            self?.setExpanded(true)
        }
        DevStatusNavigator.shared.onOpenDrawer = openDev
        CodingAgentsController.shared.connect(activities: activities, opensTab: .devStatus)
        CodingAgentsController.shared.onOpenDrawer = openDev
        CodingAgentsController.shared.start()
        DevCIController.shared.connect(activities: activities, opensTab: .devStatus)
        DevCIController.shared.start()
        ScriptWidgetsController.shared.connect(activities: activities, opensTab: .devStatus)
        ScriptWidgetsController.shared.start()
        // ⌃⌥⇧T (and, while it shows, ⌃⌥⇧Space / ⌃⌥⇧↑ / ⌃⌥⇧↓).
        TeleprompterController.shared.start()
        // ⌃⌥B opens the Menu Bar page at once (keyboard: no animation); the
        // hub tile and menus switch with the hub's ease-out.
        MenuBarOverflowController.shared.onOpenDrawer = { [weak self] in
            let instant = MenuBarOverflowController.shared.isOpeningFromKeyboard
            withAnimation(instant ? nil : SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) {
                self?.state.select(.menuBar)
            }
            self?.setExpanded(true, animated: !instant)
        }
        MenuBarOverflowController.shared.onWillPress = { [weak self] in self?.forceCollapse() }
        MenuBarOverflowController.shared.start()
        // The teleprompter and the large mirror close the drawer when you
        // ask for them from inside it (see step 19 for the rest).
        ExtrasIslandCover.collapseIsland = { [weak self] in self?.forceCollapse() }
````

### Step 17: Stop them at quit

**File:** `Sources/NotchWindowController.swift`

**Find (occurs once):**

````swift
        // Every fan back to Auto before SparkV quits.
        FanController.shared.stop()
````

**Replace with:**

````swift
        // Every fan back to Auto before SparkV quits.
        FanController.shared.stop()
        CodingAgentsController.shared.stop()
        DevCIController.shared.stop()
        DevServersController.shared.stop()
        ScriptWidgetsController.shared.stop()
        TeleprompterController.shared.stop()
        MenuBarOverflowController.shared.stop()
````

### Step 18: Closing the drawer keeps the large mirror (it has its own ×)

**File:** `Sources/NotchWindowController.swift`

**Find (occurs once):**

````swift
            // Never leave the camera running behind a closed drawer.
            camera.stop()
````

**Replace with:**

````swift
            // Never leave the camera running behind a closed drawer (the
            // large mirror, while open, keeps it until its × closes it).
            camera.releaseDrawerPreview()
````

### Step 19: Teleprompter and large mirror stay under the island and step aside while the drawer is open

**File:** `Sources/NotchWindowController.swift`

`updateLevel()` runs on every open and close (from `setExpanded`) and whenever full screen lowers the island to `.floating`. Without this step both panels still sit one level below `.statusBar`, so the island draws over them, but they don't fade out while the drawer is open.

**Find (occurs once):**

````swift
        if panel.level != level { panel.level = level }
````

**Replace with:**

````swift
        if panel.level != level { panel.level = level }
        // The teleprompter and the large mirror sit one level below the
        // island (in full screen too) and fade out while the drawer is open.
        ExtrasIslandCover.islandChanged(expanded: state.isExpanded, level: level)
````

### Step 20: No hover-open while you read the teleprompter under the notch

**File:** `Sources/NotchWindowController.swift`

**Find (occurs once):**

````swift
        if !state.isExpanded, fileDrop.zoneContains(mouse) { return }
````

**Replace with:**

````swift
        if !state.isExpanded, fileDrop.zoneContains(mouse) { return }
        // The teleprompter plays right under the notch: reading it must not
        // open the island. Pause it (or hide it) to use the island again.
        if !state.isExpanded, TeleprompterController.shared.blocksIslandHover {
            endThemeHover()
            return
        }
````

### Step 21 (optional): Smart Moments' "Check yourself" opens the large mirror

**File:** `Sources/Labs/SmartMoments/SmartMomentsWiring.swift`

Skip this to keep the 44 pt drawer circle for that chip.

**Find (occurs once):**

````swift
            distance?.yieldCamera()
            camera.start()
            return .done("Mirror on")
````

**Replace with:**

````swift
            distance?.yieldCamera()
            // The large mirror under the notch: bigger than the drawer circle
            // and it stays while you get ready.
            camera.popOut()
            return .done("Mirror on")
````

### Step 22 (optional): a Script widget kind for the Widgets grid

**File:** `Sources/Labs/Widgets/WidgetsCatalog.swift`

Optional (Widgets grid). The planner package adds Weather and Reminders to the same switches: apply these after it, each arm next to `.network`. Keep `.script` out of the planner's `defaultEnabled` list so a fresh install doesn't show an empty Script widget.

**Find (occurs once):**

````swift
    case network
````

**Replace with:**

````swift
    case network
    /// The first reviewed script's output (Labs/DevStatus).
    case script
````

### Step 23 (optional): …title

**File:** `Sources/Labs/Widgets/WidgetsCatalog.swift`

**Find (occurs once):**

````swift
        case .network: "Network"
````

**Replace with:**

````swift
        case .network: "Network"
        case .script: "Script"
````

### Step 24 (optional): …symbol

**File:** `Sources/Labs/Widgets/WidgetsCatalog.swift`

**Find (occurs once):**

````swift
        case .network: "arrow.up.arrow.down"
````

**Replace with:**

````swift
        case .network: "arrow.up.arrow.down"
        case .script: "terminal.fill"
````

### Step 25 (optional): …tint

**File:** `Sources/Labs/Widgets/WidgetsCatalog.swift`

**Find (occurs once):**

````swift
        case .network: Color.teal
````

**Replace with:**

````swift
        case .network: Color.teal
        case .script: Color.gray
````

### Step 26 (optional): …sizes

**File:** `Sources/Labs/Widgets/WidgetsCatalog.swift`

**Find (occurs once):**

````swift
        case .network: [.wide, .small]
````

**Replace with:**

````swift
        case .network: [.wide, .small]
        case .script: [.wide, .small]
````

### Step 27 (optional): …shrinks first

**File:** `Sources/Labs/Widgets/WidgetsCatalog.swift`

**Find (occurs once):**

````swift
        case .network: 0
````

**Replace with:**

````swift
        case .network: 0
        case .script: 0
````

### Step 28 (optional): …its cell

**File:** `Sources/Labs/Widgets/WidgetsTabView.swift`

**Find (occurs once):**

````swift
            case .network: NetworkSpeedWidget(sampler: models.network, size: size, samples: models.samples)
````

**Replace with:**

````swift
            case .network: NetworkSpeedWidget(sampler: models.network, size: size, samples: models.samples)
            case .script: ScriptWidgetCell(compact: size == .small)
````

## Settings sections (no arguments; `.shared` inside)

| View | Pane |
|---|---|
| `CodingAgentsSettingsSection()` (watching, per-tool switches, tokens, wings, sounds; hook endpoint with Claude / Codex / Cursor setup lines to copy; long commands with the `~/.zshrc` lines) | **Extras** |
| `DevStatusSettingsSection()` (local servers; GitHub Actions on/off, repos, keychain token, failure band) | **Extras** |
| `ScriptWidgetSettingsSection()` (scripts, presets incl. tickers) | **Extras** |
| `TeleprompterSettingsSection()` | **Extras** |
| `MenuBarOverflowSettingsSection()` | **System** |
| `CameraMirrorSettingsSection()` | **Media** |

The Dev tab's gear button and the CI empty state call `ExtrasSettingsOpener.open()`. By default that opens `sparkv://settings/extras` (the App Shell's link). Once the App Shell package is wired you may route it directly, in `NotchWindowController.init` next to step 16 (not typechecked here, the App Shell isn't in this copy):

```swift
ExtrasSettingsOpener.handler = { SparkVSettingsWindowController.shared.show(pane: SparkVSettingsPane(slug: $0) ?? .extras) }
```

## Agents hub tiles (48 pt, the hub's own look via `LabsBHubTileBackground`; step 14 registers them in `HubCatalog.packageTiles`)

| Hub id | Tile | Category | Click | Right-click |
|---|---|---|---|---|
| `codingAgents` | `CodingAgentsHubTile(hubID:)` (badge: sessions waiting for you; lit while one works) | **Developer** | Dev tab, Agents page | `CodingAgentsMenuItems` + hub items |
| `devStatus` | `DevStatusHubTile(hubID:)` (turns red "CI Failed") | **Developer** | Dev tab (Servers, or CI after a failure) | `DevStatusMenuItems` + hub items |
| `scripts` | `ScriptWidgetHubTile(hubID:)` (shows the pinned script's first line) | **Developer** | Dev tab, Scripts page | `ScriptWidgetMenuItems` + hub items |
| `teleprompter` | `TeleprompterHubTile(hubID:)` | **Media** | show / hide the prompter (closes the drawer) | `TeleprompterMenuItems` + hub items |
| `mirror` | `CameraMirrorHubTile(hubID:)` | **Media** | open / close the large mirror (closes the drawer) | `CameraMirrorMenuItems` + hub items |
| `menuBar` | `MenuBarOverflowHubTile(hubID:)` (badge: icons hidden by the notch) | **System** | Menu Bar tab | `MenuBarOverflowMenuItems` + hub items |

Every argument is optional (`onOpen`, `hubID`); without `onOpen` a tile opens the drawer through `DevStatusNavigator.shared.onOpenDrawer` / `MenuBarOverflowController.shared.onOpenDrawer` (set in step 16). With `hubID` its right-click menu ends with the hub's `HubTileMenuItems` (Pin / Hide / Move / Customize).

## Floating panels and the island

The teleprompter and the large mirror hang under the notch, where the drawer opens. They sit one window level below the island (`ExtrasIslandCover.panelLevel`, following the island down to `.floating` in full screen), fade out while the drawer is open (the prompter also pauses) and come back when it closes (step 19). Asking for either from inside the drawer (hub tile, menu, ⌃⌥⇧T, ⌃⌥⇧Space) closes the drawer first (`ExtrasIslandCover.collapseIsland`, step 16). The automatic pop-out on a call never closes the drawer: it waits until the drawer closes.

## Gear menu items (`Menu("…") { … }`)

`CodingAgentsMenuItems`, `DevStatusMenuItems`, `ScriptWidgetMenuItems`, `TeleprompterMenuItems`, `CameraMirrorMenuItems`, `MenuBarOverflowMenuItems` (step 13 adds them all).

## Hotkeys (Carbon `ScreenRegionHotkey`, no Accessibility; none clash)

| Keys | What | When registered |
|---|---|---|
| ⌃⌥⇧T | Show / hide the teleprompter (instantly) | Always, unless turned off in Settings |
| ⌃⌥⇧Space | Teleprompter play / pause | Only while the prompter shows |
| ⌃⌥⇧↑ / ⌃⌥⇧↓ | Teleprompter faster / slower | Only while the prompter shows |
| ⌃⌥B | Open the island on the Menu Bar page (instantly) | Always, unless turned off in Settings |

Checked against ⌃⌥ J R S T C H F P K E I A M N 1–5 Space, ⌃⌥⇧R, ⌥Space, ⌥⇧S, ⌘⇧V, ⌃⌘C, ⌃⌘V. A taken combination is logged and shown in Settings, never forced.

## Controllers (one per feature, `start()` / `stop()`)

`CodingAgentsController.shared` (+ `connect(activities:opensTab:)`), `DevCIController.shared` (+ `connect`), `DevServersController.shared` (samples only while its page is on screen; `stop()` at quit), `ScriptWidgetsController.shared` (+ `connect`), `TeleprompterController.shared`, `MenuBarOverflowController.shared`. The mirror keeps the existing `CameraController` (new: `drawerPreviewAppeared()`, `releaseDrawerPreview()`, `popOut()`, `closePopOut()`, `selectCamera(_:)`, `cameras`, `isPoppedOut`, `static weak var current`).

Live bands and wings go through `ActivityCenter` with `kind: .notification` plus their own symbol and tint, so `LiveActivity.swift` needs no change: `agents.approval` (urgent, 82, opens Dev), `agents.summary` (wings, 18), `agents.finished` (64/70), `agents.command` (62), `devStatus.ci` (66), `scripts.wing` (wings, 14). Bands don't take clicks, so the approval band says "Hover to answer": hovering opens the Dev tab on the Allow / Deny card.

## UserDefaults (feature prefixes)

`SparkV.agents.*`, `SparkV.devStatus.*` (`section`, `ci.enabled`, `ci.repos`, `ci.notify`), `SparkV.devServers.showAll`, `SparkV.scripts.configs`, `SparkV.teleprompter.*`, `SparkV.menuBar.*`, `Mirror.*` (`cameraID`, `mirrored`, `autoPopOut`, `autoPopOutSeconds`, `popOutSize`). The GitHub token lives in the keychain (`SparkV.devStatus.github`), never in UserDefaults or the log.

## Privacy and network

- Off until turned on: Coding Agents (reads `~/.claude`, `~/.codex`, `~/.cursor` read-only), the hook endpoint, GitHub Actions (the only feature here that calls a server: api.github.com over HTTPS), scripts (run only after "Save & Run"; a preset that uses the internet says so), real menu bar icons (Screen Recording), pop-out on call.
- SparkV never edits `~/.claude/settings.json`, `~/.codex/config.toml` or `~/.cursor/hooks.json`; Settings shows the lines and a Copy button. It writes only its own `~/Library/Application Support/SparkV/agent-hook` (0755), `agent-hook.header` (token, 0600) and `agent-hook.port`.
- The hook endpoint binds 127.0.0.1 only (`requiredLocalEndpoint` + `acceptLocalOnly`, loopback re-checked per connection), needs the per-install token, refuses requests with `Origin` / `Sec-Fetch-*` headers and foreign `Host` values (DNS rebinding), caps bodies at 512 KB and holds a connection at most the chosen 15–55 s. Allow is only ever an explicit click; a timeout answers "ask", so the tool shows its own prompt.
- Prompts, code, tool input and command text are never logged. Folder names and commands are hidden from bands while Smart Moments sees the screen being shared.

## Energy

Nothing polls while idle: session folders through one FSEvents stream (2 s latency) plus process-exit sources; a one-shot timer only while a session still has to age from Working / Done; the hook listener is idle until a request; dev-server ports are sampled every 4 s only while the Servers page is visible; GitHub every 60 s while a run is in progress, else 5 min, with ETags, paused in sleep and Low Power Mode; scripts only while visible (or pinned to the wings, at their ≥ 60 s interval, paused when asleep, locked or in Low Power Mode, and resumed when Low Power Mode turns off); a script that times out is stopped with every process it started (pipelines, `&&` chains), so nothing keeps running orphaned; the teleprompter's TimelineView runs only while the text scrolls on the clock (not while paused or voice-paced; 30 fps in Low Power Mode, paused on display sleep, sleep and lock); voice pacing restarts recognition after a short delay and gives up after three failures within 6 s instead of toggling the microphone; the closed island's agent wing is static (one bounce when an agent starts waiting, nothing repeating); GitHub polling stops when the last repo is removed; menu bar items are read when the page opens and on app launch / quit while it is open; the mirror's auto pop-out uses KVO on `isInUseByAnotherApplication`, only while that option is on. No event monitors or CGEvents are created.

## Tests and renders

- `scratchpad/req/tests-extras/run-tests.sh` compiles the pure logic plus `ScriptRunner`, `LocalProcesses` and `AgentHookServer` and runs 91 assertions in Swift 5 and Swift 6: xbar parsing, the crypto preset's jq program run through `/usr/bin/jq`, wing text, hook HTTP checks (Origin, Host, token, sizes), the 0600 token file, teleprompter clock / voice matcher / restart backoff, menu bar geometry, and live script timeouts that must leave no orphaned children (pipelines, `&&` chains, a script that ignores SIGINT/SIGTERM).
- `scratchpad/req/render-extras/build-render.sh <copy> scratchpad/req/shots-extras` renders the drawer pages at their real sizes, hub tiles, wings, bands, the teleprompter, the large mirror and the six settings sections in both looks (42 PNGs).
- `scratchpad/req/tools-extras/apply.py <copy> INTEGRATION.md [required]` applies these steps and counts each Find block.
