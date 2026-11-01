import SwiftUI

/// The Agents tab: one tile per agent, so the header needs a single icon.
/// A tile opens the agent's own drawer page (or runs it right away); the
/// header icon comes back here.
///
/// A category bar on top (All, Write, Screen, Focus, Files, Media, System,
/// Developer, Planner) narrows the grid; the selection pill slides between
/// categories and the grid crossfades. Tiles can be hidden, reordered and
/// pinned to the drawer header (right-click a tile, or Customize Layout…);
/// controls hidden from the header show up here as tiles.
struct AgentsHubView: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var universalSearch: UniversalSearchController
    @EnvironmentObject private var quickCapture: QuickCaptureController
    @EnvironmentObject private var screenRegion: ScreenRegionController
    @EnvironmentObject private var clipboard: ClipboardController
    @ObservedObject private var layout = LayoutSettings.shared

    /// Eight columns across the 508 pt content width: tiles are ~58 pt wide;
    /// long labels shrink to fit. The drawer's height follows the row count
    /// (`AgentHubMetrics.contentHeight`).
    static let columns = AgentHubMetrics.columns

    /// Off until the grid is on screen, so the rows can fade in one after another.
    @StateObject private var appeared = ViewFlag()

    var body: some View {
        let visible = layout.visibleHubIDs
        let categories = HubCatalog.categories(in: visible)
        let selected = layout.effectiveHubCategory
        let shown = layout.shownHubIDs

        VStack(spacing: AgentHubMetrics.barSpacing) {
            HubCategoryBar(categories: categories, selection: selected, counts: counts(visible)) { category in
                // The drawer springs to the category's rows (the island's
                // own spring, NotchNookLayoutView); the grid crossfades.
                layout.hub.category = category
            }
            .frame(height: AgentHubMetrics.barHeight)

            ZStack(alignment: .top) {
                grid(shown, category: selected)
                    .id(selected)
                    .transition(.sparkVCrossfade)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Content swap: strong ease-out crossfade (Reduce Motion: plain fade).
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: selected)
        }
        .onAppear {
            appeared.isOn = true
            // Tiles that appeared since launch (Smart Moments, a package
            // tile) can change the row count: the drawer then resizes.
            layout.refreshSnapshot(announce: true)
        }
        .onDisappear { appeared.isOn = false }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func counts(_ visible: [String]) -> [HubCategory: Int] {
        var counts: [HubCategory: Int] = [.all: visible.count]
        for id in visible { counts[HubCatalog.category(of: id), default: 0] += 1 }
        return counts
    }

    @ViewBuilder
    private func grid(_ ids: [String], category: HubCategory) -> some View {
        if ids.isEmpty {
            HubEmptyState(category: category)
        } else if LayoutSnapshot.current.hubScrolls, category == .all {
            let overflow = (ids.count + AgentHubMetrics.columns - 1) / AgentHubMetrics.columns > AgentHubMetrics.maxRows
            ScrollView(.vertical) { tiles(ids) }
                .scrollIndicators(.automatic)
                // More tiles below the fold: the last row fades out, so it
                // reads as scrollable even with the overlay scroller hidden.
                .mask(
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, overflow ? .black.opacity(0.15) : .black],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                    }
                )
        } else {
            tiles(ids)
        }
    }

    private func tiles(_ ids: [String]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AgentHubMetrics.spacing), count: Self.columns),
            spacing: AgentHubMetrics.spacing
        ) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                HubTileCell(id: id, actions: actions)
                    // Rows arrive 40 ms apart; tiles stay clickable while they settle.
                    .sparkVStaggeredEntrance(appeared.isOn, index: index / Self.columns)
            }
        }
    }

    private var actions: HubActions {
        HubActions(state: state, search: universalSearch, capture: quickCapture, screenRegion: screenRegion, clipboard: clipboard)
    }
}

// MARK: - Metrics

enum AgentHubMetrics {
    /// Matches `FocusHubTile`'s height, so every row lines up.
    static let tileHeight: CGFloat = 48
    static let spacing: CGFloat = 6
    static let columns = 8
    /// The category bar above the grid.
    static let barHeight: CGFloat = 22
    static let barSpacing: CGFloat = 8
    /// Rows the drawer grows to; more scroll.
    static let maxRows = 5
    /// Rows the selected category needs (1 ... `maxRows`; "All" scrolls
    /// past that).
    static var rows: Int { LayoutSnapshot.current.hubRows }
    /// Height of the hub's content: the category bar and the rows of tiles
    /// (+4: tiles with two-line labels grow a few points past tileHeight).
    static var contentHeight: CGFloat {
        let rows = CGFloat(Self.rows)
        return barHeight + barSpacing + rows * tileHeight + (rows - 1) * spacing + 4
    }
}

// MARK: - Catalog

/// A hub tile's identity and look: what the grid, the category bar, the
/// pinned header buttons and the Customize Layout window share.
struct HubTileInfo: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// The tile's own color: its glyph in Apple (Control Center style); the
    /// SparkV Red look draws tiles monochrome and lights them red.
    let tint: Color
    let category: HubCategory
    var help: String? = nil
    /// Can sit in the drawer header as an icon button.
    var pinnable = true
}

/// A tile another feature package adds to the hub. The integrator lists one
/// entry per `<Feature>HubTile` in `HubCatalog.packageTiles` (INTEGRATION.md
/// has a ready-made entry for each package):
///
///     HubPackageTile(info: HubTileInfo(id: "colorPicker", title: "Colors", systemImage: "eyedropper",
///                                      tint: .pink, category: .screen),
///                    opensTab: .colorPicker) { actions in
///         AnyView(ColorPickerHubTile(controller: actions.state.colorPicker, onOpen: { actions.openTab(.colorPicker) }))
///     }
///
/// - `opensTab`: the drawer page the tile opens, if any. A pinned header
///   button then opens it and lights while it shows, and the Agents header
///   tab stays dark meanwhile.
/// - `pinAction`: what the pinned header button does when the tile has no
///   page (a menu, a window, a toggle). With neither, the tile can't be pinned.
/// - `view`: the tile itself; `actions.openTab(_:)` opens a page with the
///   hub's own animation, `actions.state` is the drawer's `NotchState`.
struct HubPackageTile: Identifiable {
    let info: HubTileInfo
    let opensTab: NotchState.Tab?
    let pinAction: (@MainActor (HubActions) -> Void)?
    let view: @MainActor (HubActions) -> AnyView

    init(info: HubTileInfo, opensTab: NotchState.Tab? = nil, pinAction: (@MainActor (HubActions) -> Void)? = nil,
         view: @escaping @MainActor (HubActions) -> AnyView) {
        var info = info
        if pinAction == nil, opensTab == nil {
            info = HubTileInfo(id: info.id, title: info.title, systemImage: info.systemImage, tint: info.tint,
                               category: info.category, help: info.help, pinnable: false)
        }
        self.info = info
        self.opensTab = opensTab
        self.pinAction = pinAction
        self.view = view
    }

    var id: String { info.id }
}

/// Reads an environment object the drawer injects and builds a package
/// tile with it: `HubEnvTile { (picker: ColorPickerController) in ColorPickerHubTile(controller: picker) }`.
struct HubEnvTile<Object: ObservableObject & Sendable, Content: View>: View {
    @EnvironmentObject private var object: Object
    let content: (Object) -> Content

    init(@ViewBuilder content: @escaping (Object) -> Content) {
        self.content = content
    }

    var body: some View { content(object) }
}

/// Every hub tile in its default order, with its category.
@MainActor
enum HubCatalog {
    /// Tiles from other feature packages (integrator: add entries here, see
    /// INTEGRATION.md for each package's). Built once.
    static let packageTiles: [HubPackageTile] = [
        // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { _ in AnyView(…HubTile()) },
        // App shell (System): opens Settings; a dot marks an available update.
        HubPackageTile(info: HubTileInfo(id: "settings", title: "Settings", systemImage: "gearshape.fill",
                                         tint: Color(white: 0.72), category: .system,
                                         help: "Settings (⌘, while SparkV is in front)"),
                       pinAction: { _ in SparkVSettings.show() }) { _ in AnyView(SettingsHubTile()) },
        // Island placement (System): click for display, style, hiding.
        HubPackageTile(info: HubTileInfo(id: "islandPlacement", title: "Island", systemImage: "rectangle.topthird.inset.filled",
                                         tint: Color(red: 0.36, green: 0.78, blue: 0.98), category: .system,
                                         help: "Island: display, style and when it hides"),
                       pinAction: { _ in IslandSettingsOpener.open() }) { _ in AnyView(IslandPlacementHubTile()) },
        // Volume & brightness HUD (System).
        HubPackageTile(info: HubTileInfo(id: "hud", title: "HUD", systemImage: "speaker.wave.2.fill",
                                         tint: Color(red: 1.0, green: 0.72, blue: 0.22), category: .system,
                                         help: "Volume & brightness HUD: styles, key steps, displays and a preview"),
                       pinAction: { _ in HUDController.current?.preview() }) { _ in AnyView(HUDHubTile()) },
        // Live activities (System; Alerts in Focus; Calls in Media).
        HubPackageTile(info: HubTileInfo(id: "liveActivities", title: "Live", systemImage: "dot.radiowaves.left.and.right",
                                         tint: .orange, category: .system,
                                         help: "Live Activities: the next running one beside the notch (⌃⌥A)"),
                       pinAction: { _ in LiveActivitiesController.current?.showNextFromKeyboard() }) { _ in AnyView(LiveActivitiesHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "notificationsUnderNotch", title: "Alerts", systemImage: "bell.badge.fill",
                                         tint: .red, category: .focus,
                                         help: "Notifications under the notch on or off")) { _ in AnyView(NotificationsHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "calls", title: "Calls", systemImage: "phone.fill",
                                         tint: .green, category: .media,
                                         help: "Calls: mute during a call, incoming calls on or off")) { _ in AnyView(CallsHubTile()) },
        // System Status (System; Mute Mic in Media).
        HubPackageTile(info: HubTileInfo(id: "status", title: "Status", systemImage: "battery.75percent",
                                         tint: Color(red: 0.30, green: 0.85, blue: 0.45), category: .system,
                                         help: "Status: battery and health, accessories, what uses the mic or camera, and quick toggles"),
                       opensTab: .status, pinAction: { _ in SystemStatusCenter.shared.openPage() }) { _ in AnyView(SystemStatusHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "keepAwake", title: "Keep Awake", systemImage: "cup.and.saucer.fill",
                                         tint: KeepAwakePalette.tint, category: .system,
                                         help: "Keep the Mac awake. Right-click for durations."),
                       pinAction: { _ in KeepAwakeController.shared.toggle() }) { _ in AnyView(KeepAwakeHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "micMute", title: "Mute Mic", systemImage: "mic.fill",
                                         tint: .orange, category: .media,
                                         help: "Mute the microphone for every app (⌃⌥M)"),
                       pinAction: { _ in MicMuteController.shared.toggle() }) { _ in AnyView(MicMuteHubTile()) },
        // Media package (Media).
        HubPackageTile(info: HubTileInfo(id: "soundOutput", title: "Output", systemImage: "hifispeaker.fill", tint: .blue,
                                         category: .media, help: "Sound output")) { _ in AnyView(SoundOutputHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "appVolumes", title: "App Volumes", systemImage: "slider.vertical.3", tint: .teal,
                                         category: .media, help: "Per-app volume"),
                       pinAction: { _ in AppVolumeWindow.shared.show() }) { _ in AnyView(AppVolumeHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "lyrics", title: "Lyrics", systemImage: "quote.bubble.fill", tint: .pink,
                                         category: .media, help: "Synced lyrics"),
                       pinAction: { _ in LyricsWindow.shared.show() }) { _ in AnyView(LyricsHubTile()) },
        // Planner package (Planner; Launcher in System).
        HubPackageTile(info: HubTileInfo(id: "agenda", title: "Agenda", systemImage: "calendar.day.timeline.left", tint: .red, category: .planner,
                                         help: "Agenda: day, week and month"),
                       pinAction: { _ in PlannerRouter.shared.show(.agenda) }) { _ in AnyView(AgendaHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "reminders", title: "Reminders", systemImage: "checklist", tint: .orange, category: .planner,
                                         help: "Reminders due today"),
                       pinAction: { _ in PlannerRouter.shared.show(.reminders) }) { _ in AnyView(RemindersHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "timers", title: "Timers", systemImage: "timer", tint: .orange, category: .planner,
                                         help: "Timers, stopwatches and Pomodoro"),
                       pinAction: { _ in PlannerRouter.shared.show(.timers) }) { _ in AnyView(TimersHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "weather", title: "Weather", systemImage: "cloud.sun.fill", tint: .cyan, category: .planner,
                                         help: "Weather (off until you choose a city)"),
                       pinAction: { _ in PlannerRouter.shared.show(.weather) }) { _ in AnyView(WeatherHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "launcher", title: "Launcher", systemImage: "square.grid.3x3.fill", tint: .indigo, category: .system,
                                         help: "Launcher: pinned apps and shortcuts"),
                       pinAction: { _ in PlannerRouter.shared.show(.launcher) }) { _ in AnyView(LauncherHubTile()) },
        // Shelf (Files).
        HubPackageTile(info: HubTileInfo(id: "nearbyShare", title: "Nearby", systemImage: "wave.3.right.circle.fill", tint: .teal,
                                         category: .files, help: "Nearby Share: send Tray items to Android, Windows or Linux (LocalSend)"),
                       pinAction: { _ in LocalSendPanelController.shared.open() }) { _ in AnyView(NearbyShareHubTile()) },
        HubPackageTile(info: HubTileInfo(id: "fileTransfers", title: "Transfers", systemImage: "doc.on.doc.fill", tint: .blue,
                                         category: .files, help: "Copy and send progress, with Pause and Cancel"),
                       opensTab: .downloads) { _ in AnyView(FileTransfersHubTile()) },
        // Color Picker (Screen): click picks, the chevron opens the page.
        HubPackageTile(info: HubTileInfo(id: "colorPicker", title: "Colors", systemImage: "eyedropper", tint: .pink, category: .screen,
                                         help: "Color Picker (⌃⌥P)"), opensTab: .colorPicker) { actions in
            AnyView(HubEnvTile { (picker: ColorPickerController) in
                ColorPickerHubTile(controller: picker, onOpen: { actions.openTab(.colorPicker) })
            })
        },
        // Developer & Extras (Developer; Prompter and Mirror in Media, Menu Bar in System).
        HubPackageTile(info: HubTileInfo(id: "codingAgents", title: "Coding", systemImage: "sparkles.rectangle.stack",
                                         tint: Color(red: 0.85, green: 0.47, blue: 0.34), category: .developer,
                                         help: "Coding Agents: Claude Code, Codex and Cursor sessions"),
                       pinAction: { _ in DevStatusNavigator.shared.open(.agents) }) { _ in
            AnyView(CodingAgentsHubTile(hubID: "codingAgents"))
        },
        HubPackageTile(info: HubTileInfo(id: "devStatus", title: "Dev", systemImage: "server.rack", tint: .teal,
                                         category: .developer, help: "Dev Status: local servers, GitHub Actions"),
                       pinAction: { _ in
                           let nav = DevStatusNavigator.shared
                           nav.open(nav.section == .agents ? .servers : nav.section)
                       }) { _ in
            AnyView(DevStatusHubTile(hubID: "devStatus"))
        },
        HubPackageTile(info: HubTileInfo(id: "scripts", title: "Scripts", systemImage: "terminal.fill", tint: Color(white: 0.78),
                                         category: .developer, help: "Scripts: your shell commands' output, xbar-style"),
                       pinAction: { _ in DevStatusNavigator.shared.open(.scripts) }) { _ in
            AnyView(ScriptWidgetHubTile(hubID: "scripts"))
        },
        HubPackageTile(info: HubTileInfo(id: "teleprompter", title: "Prompter", systemImage: "scroll", tint: .indigo,
                                         category: .media, help: "Teleprompter under the camera"),
                       pinAction: { _ in TeleprompterController.shared.toggleShown() }) { _ in
            AnyView(TeleprompterHubTile(hubID: "teleprompter"))
        },
        HubPackageTile(info: HubTileInfo(id: "mirror", title: "Mirror", systemImage: "person.crop.square", tint: .green,
                                         category: .media, help: "A large mirror under the notch"),
                       pinAction: { _ in CameraController.current?.togglePopOut() }) { _ in
            AnyView(CameraMirrorHubTile(hubID: "mirror"))
        },
        HubPackageTile(info: HubTileInfo(id: "menuBar", title: "Menu Bar", systemImage: "menubar.dock.rectangle", tint: Color(white: 0.8),
                                         category: .system, help: "Menu bar icons hidden by the notch"),
                       pinAction: { _ in MenuBarOverflowController.shared.onOpenDrawer?() }) { _ in
            AnyView(MenuBarOverflowHubTile(hubID: "menuBar"))
        },
        // Island Interaction: keep the drawer open (a pin button in the header when pinned there).
        HubPackageTile(info: HubTileInfo(id: "islandKeepOpen", title: "Keep Open", systemImage: "pin.fill",
                                         tint: Color(red: 0.98, green: 0.72, blue: 0.27), category: .system,
                                         help: "Keep the drawer open while you work"),
                       pinAction: { _ in IslandInteractionActions.setPinned(!IslandInteractionActions.isPinned) }) { _ in
            AnyView(IslandInteractionHubTile())
        },
    ]

    static func packageTile(_ id: String) -> HubPackageTile? { packageTiles.first { $0.id == id } }

    /// Built-in tiles in grid order. Row 1: everyday actions. Row 2:
    /// clipboard, screen and files. Row 3: tools, watchers and setup.
    static let builtIn: [HubTileInfo] = [
        HubTileInfo(id: "search", title: "Search", systemImage: "magnifyingglass", tint: .indigo, category: .files,
                    help: "Search everything (⌥Space)"),
        // The header has its own Focus and Widgets controls, so these two
        // tiles aren't pinned there.
        HubTileInfo(id: "focus", title: "Focus", systemImage: "moon.fill", tint: .indigo, category: .focus,
                    help: "Focus: mute notifications and start a Pomodoro", pinnable: false),
        HubTileInfo(id: "modes", title: "Modes", systemImage: "switch.2", tint: .indigo, category: .focus,
                    help: "Modes: one click sets your wallpaper, music, apps and Do Not Disturb", pinnable: false),
        HubTileInfo(id: "ambientLight", title: "Ambient", systemImage: "light.beacon.max", tint: Color(red: 0.62, green: 0.35, blue: 1.0),
                    category: .media, help: "Ambient Light: the notch glows with your music"),
        HubTileInfo(id: "capture", title: "Capture", systemImage: "square.and.arrow.down.on.square.fill", tint: .orange, category: .files,
                    help: "Quick Capture: save what you're looking at to Spaces"),
        HubTileInfo(id: "copyText", title: "Copy Text", systemImage: "text.viewfinder", tint: .green, category: .screen,
                    help: "Copy text from anywhere on screen"),
        HubTileInfo(id: "reply", title: "Reply", systemImage: "arrowshape.turn.up.left.fill", tint: .cyan, category: .write,
                    help: "Reply Drafter (⌃⌥R)"),
        HubTileInfo(id: "askScreen", title: "Ask Screen", systemImage: "viewfinder", tint: .cyan, category: .screen,
                    help: "Ask about part of the screen (⌃⌥S)"),
        HubTileInfo(id: "prompt", title: "Prompt", systemImage: "wand.and.stars", tint: .purple, category: .write,
                    help: "Prompt Refiner"),
        HubTileInfo(id: "clipboardTab", title: "Clipboard", systemImage: "doc.on.clipboard", tint: .pink, category: .write,
                    help: "Clipboard history"),
        HubTileInfo(id: "pasteStack", title: "Paste Stack", systemImage: "square.stack.3d.down.right.fill", tint: .pink, category: .write,
                    help: "Clipboard stack (⌘⇧V). Hold ⌘, tap a number, tap V to paste that copy."),
        HubTileInfo(id: "record", title: "Record", systemImage: "record.circle", tint: .red, category: .screen,
                    help: "Record the screen to the Desktop (⌃⌥⇧R)"),
        HubTileInfo(id: "widgets", title: "Widgets", systemImage: "rectangle.3.group.fill", tint: .orange, category: .system,
                    help: "World clocks, volume knob, habits, CPU/RAM and network speed", pinnable: false),
        HubTileInfo(id: "fileDrop", title: "File Drop", systemImage: "arrow.down.doc.fill", tint: .yellow, category: .files,
                    help: "File Drop: rename, compress, convert, AirDrop"),
        HubTileInfo(id: "downloads", title: "Downloads", systemImage: "arrow.down.circle", tint: .blue, category: .files,
                    help: "Downloads: progress, recent files and sorting"),
        HubTileInfo(id: "translate", title: "Translate", systemImage: "captions.bubble.fill", tint: .green, category: .media,
                    help: "Translate meeting captions live"),
        HubTileInfo(id: "uiAudit", title: "UI Audit", systemImage: "checkmark.rectangle.stack", tint: .green, category: .developer,
                    help: "UI Audit"),
        HubTileInfo(id: "jobs", title: "Jobs", systemImage: "briefcase.fill", tint: .orange, category: .planner,
                    help: "Job Agent"),
        HubTileInfo(id: "browser", title: "Browser", systemImage: "play.rectangle.on.rectangle", tint: .blue, category: .developer,
                    help: "Browser Flows"),
        HubTileInfo(id: "distance", title: "Distance", systemImage: "eye", tint: .mint, category: .focus,
                    help: "Screen Distance"),
        HubTileInfo(id: "canvas", title: "Canvas", systemImage: "point.3.connected.trianglepath.dotted", tint: .teal, category: .developer,
                    help: "Flow Canvas"),
        HubTileInfo(id: "setup", title: "Setup", systemImage: "checkmark.shield.fill", tint: Color(white: 0.72), category: .system,
                    help: "Permissions & Setup: see and allow what SparkV needs"),
        HubTileInfo(id: "iphone", title: "iPhone", systemImage: "iphone.and.arrow.forward", tint: .blue, category: .files,
                    help: "Sync to iPhone: keeps iCloud Drive › SparkV up to date for the Files app"),
        HubTileInfo(id: "smartMoments", title: "Moments", systemImage: "sparkles", tint: .yellow, category: .system,
                    help: "Smart Moments"),
        HubTileInfo(id: "fans", title: "Fans", systemImage: "fan.fill", tint: .cyan, category: .system,
                    help: "Fan Control: speeds, temperatures and presets"),
    ]

    /// Look & Layout's own tiles, before the "C" capsule.
    static let lookTiles: [HubTileInfo] = [
        HubTileInfo(id: "look", title: "Look", systemImage: "paintpalette.fill", tint: .pink, category: .system,
                    help: "Appearance: look, accent color, text size, Liquid Glass. Right-click for quick changes."),
        HubTileInfo(id: "customize", title: "Customize", systemImage: "slider.horizontal.3", tint: Color(white: 0.72), category: .system,
                    help: "Customize Layout: header controls, pinned tiles, hub order and the tab the drawer opens on"),
    ]

    /// The "C" capsule: one click pastes what's on the clipboard. Always last.
    static let capsule = HubTileInfo(id: "clipboardCapsule", title: "Clipboard Capsule", systemImage: "c.circle.fill", tint: .pink,
                                     category: .write, help: "Paste the current clipboard item", pinnable: false)

    /// Tiles that stand in for header controls the user hid.
    static let standIns: [HubTileInfo] = [
        HubTileInfo(id: "tab.home", title: "Home", systemImage: "house.fill", tint: .blue, category: .media,
                    help: "Home: media, shortcuts and mirror", pinnable: false),
        HubTileInfo(id: "tab.tray", title: "Tray", systemImage: "tray.full.fill", tint: .blue, category: .files,
                    help: "Tray: screenshots, text and files", pinnable: false),
        HubTileInfo(id: "tab.today", title: "Today", systemImage: "calendar", tint: .red, category: .planner,
                    help: "Today: meetings, agenda, reminders, timers, weather and launcher", pinnable: false),
        HubTileInfo(id: "tab.converter", title: "Convert", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard", tint: .orange,
                    category: .files, help: "Convert: drop a file, pick a format", pinnable: false),
        HubTileInfo(id: "tab.spaces", title: "Spaces", systemImage: "square.stack.3d.up.fill", tint: .purple, category: .files,
                    help: "Spaces: knowledge folders per organization", pinnable: false),
        HubTileInfo(id: "tab.meeting", title: "Meeting", systemImage: "person.2.wave.2", tint: .red, category: .planner,
                    help: "Record this meeting (transcript, tasks and minutes)", pinnable: false),
        HubTileInfo(id: "tab.flow", title: "Flow", systemImage: "waveform", tint: .pink, category: .write,
                    help: "Flow: dictation history and notes", pinnable: false),
        HubTileInfo(id: "tab.clicky", title: "Clicky", systemImage: "cursorarrow.rays", tint: .cyan, category: .screen,
                    help: "Clicky: ask about your screen", pinnable: false),
    ]

    /// Default order for a header layout: built-ins, stand-ins for hidden
    /// header controls, package tiles, Look & Layout, the capsule.
    static func defaultOrder(header: HeaderLayout) -> [String] {
        let shownStandIns = Set(header.hubStandIns)
        // Smart Moments has a tile only when it is built and running.
        let builtIns = builtIn.filter { $0.id != "smartMoments" || SmartMomentsWiring.current != nil }
        return builtIns.map(\.id)
            + standIns.map(\.id).filter { shownStandIns.contains($0) }
            + packageTiles.map(\.id)
            + lookTiles.map(\.id)
            + [capsule.id]
    }

    /// Every tile that can ever appear (for the Customize window and pins).
    static var allInfos: [HubTileInfo] {
        builtIn + standIns + packageTiles.map(\.info) + lookTiles + [capsule]
    }

    static func info(_ id: String) -> HubTileInfo? {
        if let tile = builtIn.first(where: { $0.id == id }) { return tile }
        if let tile = lookTiles.first(where: { $0.id == id }) { return tile }
        if let tile = standIns.first(where: { $0.id == id }) { return tile }
        if id == capsule.id { return capsule }
        return packageTile(id)?.info
    }

    /// A tile standing in for a hidden header control ("tab.tray").
    static func isStandIn(_ id: String) -> Bool { standIns.contains { $0.id == id } }

    /// The tabs that light the header's Agents icon: every Agents page,
    /// except those a pinned tile opens (that tile lights instead).
    static func agentsActiveTabs(pins: [String]) -> Set<NotchState.Tab> {
        NotchState.Tab.agentTabs.subtracting(pins.compactMap(tab(for:)))
    }

    static func category(of id: String) -> HubCategory {
        info(id)?.category ?? .system
    }

    /// Ids that can be pinned to the header.
    static var pinnableIDs: Set<String> {
        Set(allInfos.filter(\.pinnable).map(\.id))
    }

    /// "All" plus every category with at least one of `ids`, in bar order.
    static func categories(in ids: [String]) -> [HubCategory] {
        let present = Set(ids.map(category(of:)))
        return HubCategory.allCases.filter { $0 == .all || present.contains($0) }
    }

    /// The drawer tab a tile opens, if it opens one.
    static func tab(for id: String) -> NotchState.Tab? {
        switch id {
        case "devStatus": .devStatus
        case "menuBar": .menuBar
        case "reply": .replyDrafter
        case "askScreen": .screen
        case "prompt": .promptRefiner
        case "clipboardTab": .clipboard
        case "widgets": .widgets
        case "fileDrop": .fileDrop
        case "downloads": .downloads
        case "uiAudit": .uiAudit
        case "jobs": .jobs
        case "browser": .browser
        case "distance": .screenDistance
        case "fans": .fans
        case "status": .status
        case "tab.home": .nook
        case "tab.tray": .tray
        case "tab.today": .today
        case "tab.converter": .converter
        case "tab.spaces": .spaces
        case "tab.flow": .flow
        case "tab.clicky": .clicky
        default: packageTile(id)?.opensTab
        }
    }
}

// MARK: - Actions

/// What a tile (or its pinned header button) does, for the tiles that just
/// run something or open a page.
@MainActor
struct HubActions {
    let state: NotchState
    let search: UniversalSearchController
    let capture: QuickCaptureController
    let screenRegion: ScreenRegionController
    let clipboard: ClipboardController

    /// Opening an agent's page: a short strong ease-out (Reduce Motion: fade).
    func openTab(_ tab: NotchState.Tab) {
        withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) { state.select(tab) }
    }

    /// Runs `id`'s simple action; false when the tile has its own behavior.
    @discardableResult
    func perform(_ id: String) -> Bool {
        if let tab = HubCatalog.tab(for: id) {
            openTab(tab)
            return true
        }
        switch id {
        case "search": search.openPanel()
        case "capture": capture.captureNow()
        case "copyText": screenRegion.textGrab.begin()
        case "pasteStack": clipboard.showStackPanel()
        case "canvas": FlowCanvasWindowController.shared.show()
        case "setup": OnboardingController.shared.show(step: .permissions)
        case "iphone": CloudSyncWindowController.shared.show()
        case "look": LookLayoutWindowController.shared.show(page: .appearance)
        case "customize": LookLayoutWindowController.shared.show(page: .layout)
        case "smartMoments":
            guard let wiring = SmartMomentsWiring.current else { return false }
            SmartMomentsSettingsWindowController.shared.show(settings: wiring.settings)
        default:
            if let action = HubCatalog.packageTile(id)?.pinAction {
                action(self)
            } else {
                return false
            }
        }
        return true
    }

    /// Help text with the live shortcut where one exists.
    func help(for info: HubTileInfo) -> String {
        switch info.id {
        case "copyText": "Copy text from anywhere on screen (\(screenRegion.textGrab.settings.shortcut.displayString))"
        default: info.help ?? info.title
        }
    }
}

// MARK: - One cell

/// A tile in the grid: the right face for its id, plus the pin badge and
/// the Hide / Move / Pin menu.
private struct HubTileCell: View {
    let id: String
    let actions: HubActions
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        if let info = HubCatalog.info(id) {
            face(info)
                // Higher contrast: every tile gets the same visible outline
                // (SparkV Red tiles already have one).
                .overlay {
                    if SparkVTheme.highContrast, SparkVTheme.usesTileTints, id != HubCatalog.capsule.id {
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                            .strokeBorder(SparkVTheme.stroke, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if layout.header.pins.contains(id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .rotationEffect(.degrees(35))
                            .padding(5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                // Tiles with their own right-click menu (Translate, Ambient,
                // Modes, Moments, the capsule) keep it; the rest get this one.
                .contextMenu { HubTileMenuItems(id: id) }
                .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func face(_ info: HubTileInfo) -> some View {
        switch id {
        case "focus":
            FocusHubTile(onOpen: { actions.openTab(.focus) })
        case "modes":
            // One click lists the modes; pick one to switch, or Stop / Edit Modes…
            ModesHubTile()
        case "ambientLight":
            // Click: on/off. Right-click: modes, edges, settings.
            AmbientLightHubTile()
        case "record":
            RecordHubTile()
        case "translate":
            TranslateHubTile()
        case "smartMoments":
            if let smartMoments = SmartMomentsWiring.current {
                SmartMomentsHubTile(settings: smartMoments.settings)
            }
        case "fans":
            FanHubTile(onOpen: { actions.openTab(.fans) })
        case "tab.meeting":
            MeetingHubTile()
        case "look":
            AgentTile(title: info.title, systemImage: info.systemImage, tint: info.tint, help: info.help) {
                actions.perform(id)
            }
            .contextMenu { AppearanceMenuItems() }
        case "clipboardCapsule":
            // The "C" capsule: one click pastes what's on the clipboard.
            ClipboardButton(maxWidth: 58, height: 24)
                .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        default:
            if let package = HubCatalog.packageTile(id) {
                package.view(actions)
            } else {
                AgentTile(title: info.title, systemImage: info.systemImage, tint: info.tint, help: actions.help(for: info)) {
                    actions.perform(id)
                }
            }
        }
    }
}

/// Right-click menu of a hub tile: pin, hide, move, customize.
struct HubTileMenuItems: View {
    let id: String
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        let info = HubCatalog.info(id)
        if info?.pinnable == true {
            if layout.header.pins.contains(id) {
                Button("Unpin from Header") { layout.unpin(id) }
            } else if layout.header.canPinMore {
                Button("Pin to Header") { layout.pin(id) }
            } else {
                Button(layout.header.pins.count >= HeaderCatalog.maxPins
                       ? "Pin to Header (Up to \(HeaderCatalog.maxPins))"
                       : "Pin to Header (Header Is Full)") {}
                    .disabled(true)
            }
        }
        if layout.canHideTile(id) {
            Button("Hide Tile") { layout.hideTile(id) }
        } else {
            // A stand-in is the way to a hidden header control.
            Button("Show in Header Instead") {
                if let item = HeaderCatalog.items.first(where: { $0.hubStandIn == id }) {
                    layout.setHeaderItem(item.id, visible: true)
                }
            }
            .disabled(!(HeaderCatalog.items.first(where: { $0.hubStandIn == id }).map { layout.header.canShow($0.id) } ?? false))
        }
        Divider()
        Button("Move Earlier") { layout.moveTile(id, by: -1) }
            .disabled(!layout.canMoveTile(id, by: -1))
        Button("Move Later") { layout.moveTile(id, by: 1) }
            .disabled(!layout.canMoveTile(id, by: 1))
        Divider()
        Button("Customize Layout…") { LookLayoutWindowController.shared.show(page: .layout) }
    }
}

// MARK: - Category bar

/// All · Write · Screen · … with a pill that slides to the selection
/// (strong ease-in-out, 220 ms; Reduce Motion: it just moves), and the
/// Customize button at the end.
private struct HubCategoryBar: View {
    let categories: [HubCategory]
    let selection: HubCategory
    let counts: [HubCategory: Int]
    let select: (HubCategory) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 1) {
            ForEach(categories) { category in
                HubCategoryChip(
                    category: category,
                    isSelected: category == selection,
                    count: counts[category] ?? 0,
                    pill: pill
                ) {
                    guard category != selection else { return }
                    select(category)
                }
            }
            Spacer(minLength: 4)
            HubCustomizeButton()
        }
        .animation(NotchMetrics.tabPillAnimation, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Categories")
    }
}

private struct HubCategoryChip: View {
    let category: HubCategory
    let isSelected: Bool
    let count: Int
    let pill: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Text(category.title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? SparkVTheme.activeGlyph : (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7.5)
                .frame(height: 20)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(SparkVTheme.activeTabFill)
                            .overlay(Capsule().strokeBorder(SparkVTheme.activeTabStroke, lineWidth: SparkVTheme.highContrast ? 1 : 0.5))
                            .matchedGeometryEffect(id: "hubCategoryPill", in: pill)
                    } else if hover.isOn {
                        Capsule().fill(SparkVTheme.hoverFill)
                    }
                }
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help("\(category.title): \(category.detail)")
        .accessibilityLabel("\(category.title), \(count) tiles")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The slider glyph at the end of the bar: opens Customize Layout.
private struct HubCustomizeButton: View {
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            LookLayoutWindowController.shared.show(page: .layout)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(width: 24, height: 20)
                .sparkVHoverFill(hover.isOn, cornerRadius: 10)
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help("Customize Layout: hide, reorder and pin tiles")
        .accessibilityLabel("Customize Layout")
    }
}

/// A category with nothing in it (every tile hidden).
private struct HubEmptyState: View {
    let category: HubCategory
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(SparkVTheme.textTertiary)
            Text(category == .all ? "Every tile is hidden" : "No \(category.title) tiles are showing")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
            Button("Show Hidden Tiles…") { LookLayoutWindowController.shared.show(page: .layout) }
                .buttonStyle(SparkVSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pinned header buttons

/// A hub tile pinned to the drawer header: its glyph at header size, beside
/// the tabs (24 x 22 pt, like `IconTab`). At rest it is grey like the other
/// header icons; hovered or lit it takes the tile's color in Apple and red
/// in SparkV Red. It lights while its page is open or its feature is on
/// (recording, Live Translation, Ambient Light, a focus session); the
/// Agents icon stays dark meanwhile (`HubCatalog.agentsActiveTabs`).
struct HubPinnedHeaderButton: View {
    let id: String
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var universalSearch: UniversalSearchController
    @EnvironmentObject private var quickCapture: QuickCaptureController
    @EnvironmentObject private var screenRegion: ScreenRegionController
    @EnvironmentObject private var clipboard: ClipboardController
    @EnvironmentObject private var recorder: ScreenRecorderController
    @EnvironmentObject private var liveTranslation: LiveTranslationController
    @EnvironmentObject private var focus: FocusController
    @ObservedObject private var ambient = AmbientLightSettings.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        if let info = HubCatalog.info(id) {
            let lit = isLit
            Button {
                perform()
            } label: {
                Image(systemName: glyph(info))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphColor(info, lit: lit))
                    .frame(width: 24, height: 22)
                    .background {
                        if lit {
                            Capsule()
                                .fill(SparkVTheme.choose(apple: info.tint.opacity(0.24), sparkv: SparkVTheme.accentSoft))
                                .overlay(Capsule().strokeBorder(SparkVTheme.activeTabStroke, lineWidth: 0.5))
                        }
                    }
                    .sparkVHoverFill(hover.isOn && !lit, cornerRadius: 11)
                    .animation(SparkVMotion.hover(), value: hover.isOn)
                    .contentShape(Capsule())
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { hover.isOn = $0 }
            .help("\(actions.help(for: info)) · Pinned")
            .accessibilityLabel(info.title)
            .accessibilityHint("Pinned from the Agents hub")
            .accessibilityAddTraits(lit ? .isSelected : [])
            .contextMenu {
                Button("Unpin from Header") { LayoutSettings.shared.unpin(id) }
                Button("Customize Layout…") { LookLayoutWindowController.shared.show(page: .layout) }
            }
        }
    }

    private var actions: HubActions {
        HubActions(state: state, search: universalSearch, capture: quickCapture, screenRegion: screenRegion, clipboard: clipboard)
    }

    private var isLit: Bool {
        if let tab = HubCatalog.tab(for: id) { return state.tab == tab }
        switch id {
        case "record": return recorder.phase.isRecording
        case "translate": return liveTranslation.isEnabled
        case "ambientLight": return ambient.isEnabled
        case "focus": return focus.isActive || state.tab == .focus
        default: return false
        }
    }

    private func glyph(_ info: HubTileInfo) -> String {
        switch id {
        case "record" where recorder.phase.isRecording: "stop.circle.fill"
        case "focus" where focus.isActive: "moon.stars.fill"
        default: info.systemImage
        }
    }

    private func glyphColor(_ info: HubTileInfo, lit: Bool) -> Color {
        guard lit || hover.isOn else { return SparkVTheme.inactiveGlyph }
        return SparkVTheme.usesTileTints ? info.tint : SparkVTheme.accentText
    }

    private func perform() {
        switch id {
        case "record":
            recorder.toggle()
        case "translate":
            liveTranslation.isEnabled.toggle()
        case "ambientLight":
            AmbientLightController.shared.setEnabled(!ambient.isEnabled)
        case "focus":
            if focus.isActive { actions.openTab(.focus) } else { focus.startSession() }
        default:
            actions.perform(id)
        }
    }
}

// MARK: - Tiles with their own behavior

/// One-click screen recording: opens the red selection overlay (drag an
/// area, click a window, Return for the whole display); while recording it
/// turns into a red Stop tile with the elapsed time.
private struct RecordHubTile: View {
    @EnvironmentObject private var recorder: ScreenRecorderController

    var body: some View {
        if case .recording(let since) = recorder.phase {
            TimelineView(.periodic(from: since, by: 1)) { context in
                AgentTile(title: "Stop " + ScreenRecording.durationText(context.date.timeIntervalSince(since)),
                          systemImage: "stop.circle.fill", tint: .red, isHighlighted: true,
                          help: "Stop recording (\(recorder.shortcut.displayString))") {
                    recorder.stop()
                }
            }
        } else {
            AgentTile(title: "Record", systemImage: "record.circle", tint: .red,
                      help: "Record the screen to the Desktop (\(recorder.shortcut.displayString))") {
                recorder.toggle()
            }
            .disabled(recorder.phase == .starting || recorder.phase == .stopping)
        }
    }
}

/// Stand-in for the header's meeting button while it is hidden there: one
/// click records the meeting and opens the notepad; a second click stops.
private struct MeetingHubTile: View {
    @EnvironmentObject private var assistant: MeetingAssistant

    var body: some View {
        let recording = assistant.phase == .recording
        AgentTile(title: recording ? "Stop Notes" : "Meeting", systemImage: recording ? "stop.circle.fill" : "person.2.wave.2",
                  tint: .red, isHighlighted: recording,
                  help: recording ? "Stop recording and write meeting notes" : "Record this meeting (transcript, tasks and minutes)") {
            if recording {
                assistant.stop()
            } else {
                assistant.start(title: nil, calendarEventID: nil)
                assistant.openNotesWindow()
            }
        }
        .disabled(assistant.phase == .summarizing)
    }
}

/// Live Translation has no page of its own (it runs only while a meeting is
/// recorded), so its tile switches it on or off; right-click for the
/// caption window and the language.
private struct TranslateHubTile: View {
    @EnvironmentObject private var liveTranslation: LiveTranslationController

    var body: some View {
        let on = liveTranslation.isEnabled
        AgentTile(title: on ? "Translate On" : "Translate", systemImage: "captions.bubble.fill", tint: .green,
                  isHighlighted: on, help: on
                    ? "Live Translation is on: meeting captions in \(LiveTranslationLanguages.displayName(liveTranslation.targetLanguage)). Click to turn off."
                    : "Translate meeting captions live. Click to turn on.") {
            liveTranslation.isEnabled.toggle()
        }
        .contextMenu {
            Toggle("Translate Meetings Live", isOn: $liveTranslation.isEnabled)
            Picker("Translate To", selection: $liveTranslation.targetLanguage) {
                ForEach(liveTranslation.targets, id: \.self) { id in
                    Text(LiveTranslationLanguages.displayName(id)).tag(id)
                }
            }
            Button("Open Caption Window") { liveTranslation.openCaptionWindow() }
            Divider()
            HubTileMenuItems(id: "translate")
        }
    }
}

/// The hub's tile face, also for other packages' `<Feature>HubTile`s:
/// `AgentTile(title:systemImage:tint:isHighlighted:help:action:)`.
struct AgentTile: View {
    let title: String
    let systemImage: String
    /// The agent's own color. Apple draws the glyph in it (and washes the
    /// tile with it while the agent is on); SparkV Red draws every tile
    /// monochrome and lights it red on hover or while the agent is on.
    let tint: Color
    /// Lit while the agent is on (e.g. Live Translation, a recording).
    var isHighlighted = false
    var help: String? = nil
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        Button(action: action) {
            if SparkVTheme.usesTileTints {
                appleFace(shape)
            } else {
                sparkvFace(shape)
            }
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help((help ?? title).sparkVLocalized)
        .accessibilityLabel(title.sparkVLocalized)
        .accessibilityHint(help ?? "")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// Apple: a dark Control Center tile, the glyph in the agent's color, a
    /// white label; hover lifts the tile, an active agent gets a tint wash.
    private func appleFace(_ shape: RoundedRectangle) -> some View {
        let contrast = SparkVTheme.highContrast
        return VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                // One glyph box, so tall symbols don't push the label down.
                .frame(height: 20)
            Text(title.sparkVLocalized)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(isHighlighted || hover.isOn || contrast ? 1 : 0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(
            shape.fill(isHighlighted ? tint.opacity(0.24) : Color.white.opacity(hover.isOn ? 0.14 : 0.08))
        )
        .overlay(
            // Higher contrast adds its outline from the hub cell, for every tile alike.
            shape.strokeBorder(isHighlighted ? tint.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(shape)
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }

    /// SparkV Red: monochrome tiles lit red (sparkv.si).
    private func sparkvFace(_ shape: RoundedRectangle) -> some View {
        let lit = isHighlighted || hover.isOn
        return VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(lit ? SparkVTheme.accentText : SparkVTheme.text.opacity(0.88))
            Text(title.sparkVLocalized)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(lit ? SparkVTheme.text : SparkVTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(
            shape.fill(isHighlighted ? SparkVTheme.redSoft : (hover.isOn ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface))
        )
        .overlay(
            shape.strokeBorder(lit ? SparkVTheme.red.opacity(isHighlighted ? 0.55 : 0.35) : SparkVTheme.stroke, lineWidth: 1)
        )
        .contentShape(shape)
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }
}
