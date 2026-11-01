import GlanceKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Root view: one continuous black shape that grows out of the hardware notch.
struct NotchNookLayoutView: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var tray: TrayStore
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var clicky: ClickyController
    @EnvironmentObject private var activities: ActivityCenter
    @EnvironmentObject private var converter: ConverterController
    @EnvironmentObject private var jobAgent: JobAgentController
    @EnvironmentObject private var screenRegion: ScreenRegionController
    @EnvironmentObject private var media: MediaEngine
    @EnvironmentObject private var universalSearch: UniversalSearchController
    @EnvironmentObject private var fileDrop: FileDropController
    @EnvironmentObject private var downloads: DownloadsController
    @EnvironmentObject private var colorPicker: ColorPickerController
    /// Notch theme and island background (Labs/NotchThemes).
    @ObservedObject private var themeSettings = NotchThemeSettings.shared
    /// The Agents hub's rows (its category) set the drawer's height.
    @ObservedObject private var layout = LayoutSettings.shared
    /// Drawer width and motion (Labs/IslandInteraction): re-lays out when they change.
    @ObservedObject private var interactionSettings = IslandInteractionSettings.shared

    /// Geometry of the closed island (compact wings, expanded band), or nil
    /// when it rests at the notch or the drawer is open.
    private var closedLayout: IslandClosedLayout? {
        guard !state.isExpanded else { return nil }
        return NotchActivityView.closedLayout(
            resting: state.collapsedSize, dictation: dictation, clicky: clicky, activities: activities, media: media
        )
    }

    var body: some View {
        let closed = closedLayout
        let surface = state.surface
        let isPill = surface.shape == .pill
        let size: CGSize = if state.isExpanded {
            NotchMetrics.expandedSize(for: state.tab)
        } else if let closed {
            closed.size
        } else if state.isHoverPrimed {
            // Open by Click or Press and Hold: ready under the pointer.
            CGSize(width: state.collapsedSize.width + IslandSizing.primedGrowth.width,
                   height: state.collapsedSize.height + IslandSizing.primedGrowth.height)
        } else {
            state.collapsedSize
        }
        // glance-style silhouette: shoulders flare into the menu bar, and both
        // radii grow as the island opens. The flare sits outside the body.
        // A pill has no flare: a capsule at rest, rounded corners open.
        let radii: (top: CGFloat, bottom: CGFloat) = if isPill {
            if state.isExpanded {
                (0, NotchMetrics.pillOpenRadius)
            } else if closed?.band != nil {
                (0, NotchMetrics.pillBandRadius)
            } else {
                (0, size.height / 2)
            }
        } else if state.isExpanded {
            (NotchMetrics.openFlareRadius, NotchMetrics.openBottomRadius)
        } else if closed?.band != nil {
            (NotchMetrics.activityFlareRadius, NotchMetrics.activityBottomRadius)
        } else {
            (NotchMetrics.closedFlareRadius, NotchMetrics.closedBottomRadius)
        }
        let shape = IslandSilhouette(shape: surface.shape, topRadius: radii.top, bottomRadius: radii.bottom)
        let wingsSource = state.isExpanded ? nil : NotchActivityView.wingsSource(activities: activities, media: media)
        // Minimal (or an auto-hidden menu bar): nothing at rest until the
        // pointer reaches the top edge or an activity appears.
        let restingHidden = surface.restsHidden && !state.isExpanded && closed == nil && !state.isRestingRevealed
        // A floating pill rests `gap` below the top edge (the panel reaches
        // the edge). Open, or with a band, the body grows up into the gap,
        // so no strip of menu bar shows above the black.
        let gap = isPill ? surface.topInset : 0
        let fill: CGFloat = gap > 0 && (state.isExpanded || closed?.band != nil) ? gap : 0

        ZStack(alignment: .top) {
            // Black, or Liquid Glass while open (Appearance › Drawer); always
            // black when closed and with Reduce Transparency.
            LookDrawerBackground(shape: shape, isExpanded: state.isExpanded, headerHeight: state.collapsedSize.height,
                                 hasNotch: state.surface.hasNotch)

            Group {

            // Album-art glow (boring.notch style), under all content; the
            // clip shape below keeps it inside the island.
            // Only with the Album Glow background; Black keeps the island pure black.
            if themeSettings.effectiveBackground == .albumGlow, state.isExpanded, state.tab == .nook {
                MediaGlowBackground(center: UnitPoint(
                    x: (16 + radii.top + MediaColumnV2.artworkSide / 2) / (size.width + 2 * radii.top),
                    y: (state.collapsedSize.height + MediaColumnV2.artworkSide / 2) / size.height
                ))
                .transition(.opacity)
            } else if themeSettings.effectiveBackground == .albumGlow, !state.isExpanded, wingsSource == .nowPlaying {
                MediaGlowBackground(style: .pill, center: UnitPoint(
                    x: (radii.top + 22) / (size.width + 2 * radii.top),
                    y: 0.5
                ), intensity: 0.8)
                .transition(.opacity)
            }

            if state.isExpanded {
                VStack(spacing: 0) {
                    HeaderRow()
                        // Right-click: version, Settings, updates, About, Quit.
                        .contextMenu { AppShellContextMenuItems() }
                        // VoiceOver: the tab strip first, then the tab's content.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Drawer tabs")
                        .accessibilitySortPriority(2)
                        // Header shares the band beside the camera cutout, so
                        // nothing important is drawn under the physical notch.
                        .frame(height: isPill ? max(state.collapsedSize.height, NotchMetrics.pillHeaderMinHeight) : state.collapsedSize.height)
                        // A click on the notch (the camera gap) closes the drawer.
                        .overlay { IslandNotchGapTarget(headerWidth: size.width - 32) }

                    // Crossfade between tabs (opacity and a light 2 pt blur
                    // that hides the double exposure) while the drawer's
                    // height springs to the new tab.
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
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(DrawerShortcutStore.title(of: state.tab))
                    .accessibilitySortPriority(1)
                }
                .padding(.horizontal, 16 + radii.top)
                .padding(.bottom, NotchMetrics.drawerBottomPadding)
                // Keep Drawer Open: a short bar at the bottom edge.
                .overlay(alignment: .bottom) { IslandPinnedIndicator().padding(.bottom, 1) }
                // The whole drawer accepts files, including the header band the
                // drag enters through; a drag over Nook switches to the Tray.
                .contentShape(Rectangle())
                // Files, images and file promises (Mail, Photos, the screenshot
                // thumbnail) land here on any tab; links and text only on the
                // Tray or Spaces the user opened (Labs/ShelfPlus/ShelfDragFilter).
                .onDrop(of: ShelfDrawerDrop.types,
                        delegate: ShelfDrawerDrop(state: state, tray: tray, converter: converter, fileDrop: fileDrop))
                // Grows out of the notch: from 96 % at the top edge with a
                // fade (fade only under Reduce Motion). On close the content
                // fades out quickly, so it is gone before the body shrinks
                // over it, and a fast re-hover retargets the spring.
                .transition(.asymmetric(
                    insertion: .sparkVEnter,
                    removal: .opacity.animation(SparkVMotion.easeOut(SparkVMotion.Duration.press))
                ))
            } else if let closed {
                // Compact wings beside the camera housing, inside the menu
                // bar, plus the band under the notch only when expanded.
                ClosedIslandContent(layout: closed, restingHeight: state.collapsedSize.height, source: wingsSource)
                    .padding(.horizontal, radii.top)
                    // Opening without hover: VoiceOver's actions (also the
                    // menu bar icon's Open Drawer and the keyboard shortcut).
                    .accessibilityAction(named: "Open SparkV drawer") { AppShellController.shared.openDrawerOrSettings() }
                    .transition(.opacity)
            }
            // Track progress along the bottom of the closed pill (Settings ›
            // Island › Closed Island Music; draws nothing while off).
            if !state.isExpanded, wingsSource == .nowPlaying, closed?.band == nil {
                MediaClosedProgressLine(bottomRadius: radii.bottom)
                    .padding(.horizontal, radii.top)
            }
            }
            .padding(.top, fill)
        }
        .frame(width: size.width + 2 * radii.top, height: size.height + fill)
        .clipShape(shape)
        // Appearance › Island at Rest: only while resting with nothing to
        // show, only without a camera notch, never with Reduce Transparency.
        .opacity(LookResting.opacity(isResting: !state.isExpanded && closed == nil, hasNotch: state.surface.hasNotch))
        // Hover theme, behind and around the black body. Plain draws nothing.
        .background(alignment: .top) {
            NotchThemeBackdrop(
                isExpanded: state.isExpanded,
                bodySize: CGSize(width: size.width, height: size.height + fill),
                topRadius: radii.top,
                bottomRadius: radii.bottom
            )
        }
        // Ambient Light: music-synced glow around the island (nothing while off).
        .background(alignment: .top) {
            if !LookDrawerMaterial.hidesBackdrops(isExpanded: state.isExpanded) {
                AmbientNotchGlowBackdrop(bodySize: CGSize(width: size.width, height: size.height + fill), topRadius: radii.top, bottomRadius: radii.bottom)
            }
        }
        // Uneven wings shift the body so the housing stays over the camera.
        .offset(x: closed?.xOffset ?? 0)
        .padding(.top, gap - fill)
        .animation(NotchMetrics.hoverAnimation, value: closed)
        .animation(NotchMetrics.hoverAnimation, value: state.tab)
        .animation(NotchMetrics.hoverAnimation, value: layout.hub.category)
        // Enters and leaves with a short strong ease-out (a fade only, so
        // Reduce Motion needs nothing else).
        .opacity(restingHidden ? 0 : 1)
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: restingHidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            if restingHidden, surface.showsHairline {
                IslandRestingHairline(hasNotch: surface.hasNotch, width: state.collapsedSize.width)
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: NotchActivityView.isBandHeld(dictation: dictation, clicky: clicky), initial: true) { _, held in
            activities.setBandHeld(held)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch state.tab {
        case .nook: FeaturesGrid()
        case .tray: TrayView()
        case .flow: FlowView()
        case .clicky: ClickyView()
        case .today: TodayView()
        case .converter: ConverterTabView()
        case .spaces: SpacesTabView()
        case .agents: AgentsHubView()
        case .uiAudit: UIAuditTabView()
        case .jobs: JobAgentDrawerView(controller: jobAgent)
        case .screen: ScreenRegionDrawerView(controller: screenRegion)
        case .promptRefiner: PromptRefinerDrawerView()
        case .browser: BrowserRecorderTab()
        case .clipboard: ClipboardTabView()
        case .screenDistance: ScreenDistanceDrawerView()
        case .focus: FocusTabView()
        case .search: UniversalSearchDrawerView(controller: universalSearch)
        case .replyDrafter: ReplyDrafterDrawerView()
        case .fileDrop: FileDropActionStrip(controller: fileDrop)
        case .downloads: DownloadsDrawerView(controller: downloads)
        case .widgets: WidgetsTabView()
        case .fans: FanTabView()
        case .colorPicker: ColorPickerDrawerView(controller: colorPicker)
        case .devStatus: DevStatusDrawerView()
        case .menuBar: MenuBarOverflowDrawerView()
        case .status: SystemStatusTabView()
        }
    }
}

/// Minimal style at rest: a faint 3 pt line where the island will appear,
/// readable on light and dark menu bars. On a notched display it sits just
/// under the camera housing.
private struct IslandRestingHairline: View {
    let hasNotch: Bool
    let width: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.black.opacity(0.55))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.34), lineWidth: 0.5))
            .frame(width: max(44, width * 0.32), height: 3)
            .padding(.top, hasNotch ? 2 : 1.5)
            .accessibilityHidden(true)
    }
}

// MARK: - Header

private struct HeaderRow: View {
    @EnvironmentObject private var assistant: MeetingAssistant
    @EnvironmentObject private var state: NotchState
    /// The active tab's pill is one shape that slides between icons.
    @Namespace private var pill
    /// Which controls show, in what order, and pinned hub tiles.
    @ObservedObject private var headerLayout = LayoutSettings.shared

    var body: some View {
        // Each side of the camera housing has 161.5 pt (508 pt header, 185 pt
        // housing on the 16-inch MacBook Pro). Measured at spacing 2: left
        // group 154 pt with Widgets; right group 145 pt with Focus, 148 pt while the record
        // button shows "● 59:59". Focus steps aside while recording, since
        // both together (174 pt) would slide under the camera.
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
        // The pill slides with a strong ease-in-out (on-screen movement),
        // overriding the island spring the drawer uses for its height.
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

/// Header icon that selects a drawer tab; the active one sits on a soft pill.
private struct IconTab: View {
    @EnvironmentObject private var state: NotchState
    let systemImage: String
    let tab: NotchState.Tab
    let help: String
    /// Tabs that also light this icon (the Agents hub's pages).
    var activeFor: Set<NotchState.Tab> = []
    /// Shared with the other header tabs so the active pill slides between them.
    let pill: Namespace.ID

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let isActive = state.tab == tab || activeFor.contains(state.tab)
        Button {
            // HeaderRow animates the pill; the drawer animates its own height.
            state.select(tab)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? SparkVTheme.activeGlyph : (hover.isOn ? SparkVTheme.text : SparkVTheme.inactiveGlyph))
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .frame(width: 24, height: 22)
                .sparkVHoverFill(hover.isOn && !isActive, cornerRadius: 11)
                .background {
                    if isActive {
                        Capsule()
                            .fill(SparkVTheme.activeTabFill)
                            .overlay(Capsule().strokeBorder(SparkVTheme.activeTabStroke, lineWidth: 0.5))
                            .matchedGeometryEffect(id: "activeTabPill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        // "Home" (the tooltip's part before the colon); the rest is the hint.
        .accessibilityLabel(help.split(separator: ":", maxSplits: 1).first.map(String.init) ?? help)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityValue(isActive ? "Showing" : "")
    }
}

/// One-click meeting recording from the header: a red record glyph that
/// turns into a blinking dot with the elapsed time while recording.
private struct RecordMeetingButton: View {
    @EnvironmentObject private var assistant: MeetingAssistant
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let isRecording = assistant.phase == .recording
        Button {
            if isRecording {
                assistant.stop()
            } else {
                assistant.start(title: nil, calendarEventID: nil)
                // Like Granola: the notepad opens with the recording.
                assistant.openNotesWindow()
            }
        } label: {
            Group {
                if isRecording, let started = assistant.current?.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        HStack(spacing: 3) {
                            // A record glyph with Differentiate Without Color;
                            // steady with Reduce Motion.
                            SparkVStatusDot(kind: .recording, color: SparkVTheme.recording, size: 7, label: "")
                                .opacity(SparkVMotion.reduceMotion || Int(context.date.timeIntervalSince(started)) % 2 == 0 ? 1 : 0.35)
                            Text(Self.elapsed(from: started, to: context.date))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(SparkVTheme.text)
                        }
                    }
                } else if assistant.phase == .summarizing {
                    ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
                } else {
                    Image(systemName: "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.recording)
                }
            }
            .padding(.horizontal, isRecording ? 6 : 0)
            .frame(minWidth: 24, minHeight: 22)
            .background(Capsule().fill(SparkVTheme.choose(apple: Color.red.opacity(isRecording ? 0.22 : 0),
                                                          sparkv: SparkVTheme.redSoft.opacity(isRecording ? 1.4 : 0))))
            .sparkVHoverFill(hover.isOn && !isRecording, cornerRadius: 11)
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(isRecording ? "Stop recording and write meeting notes" : "Record this meeting (transcript, tasks and minutes)")
        .accessibilityLabel(isRecording ? "Stop recording" : (assistant.phase == .summarizing ? "Writing meeting notes" : "Record meeting"))
        .accessibilityValue(isRecording ? "Recording" : "")
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        // Past an hour, "1h05" keeps the pill clear of the camera housing.
        if seconds >= 3600 {
            return String(format: "%dh%02d", seconds / 3600, seconds % 3600 / 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SettingsMenu: View {
    @EnvironmentObject private var macros: MacroController
    @EnvironmentObject private var media: MediaEngine
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var hud: HUDController
    @EnvironmentObject private var power: PowerMonitor
    @EnvironmentObject private var timer: TimerController
    @EnvironmentObject private var meetings: MeetingsController
    @EnvironmentObject private var notifications: NotificationMonitor
    @EnvironmentObject private var meetingAssistant: MeetingAssistant
    @EnvironmentObject private var spacesIngest: SpaceIngestCenter
    @EnvironmentObject private var uiAudit: UIAuditController
    @EnvironmentObject private var jobAgent: JobAgentController
    @EnvironmentObject private var screenRegion: ScreenRegionController
    @EnvironmentObject private var promptRefiner: PromptRefinerController
    @EnvironmentObject private var browserRecorder: BrowserRecorderController
    @EnvironmentObject private var screenDistance: ScreenDistanceController
    @EnvironmentObject private var focus: FocusController
    @EnvironmentObject private var universalSearch: UniversalSearchController
    @EnvironmentObject private var quickCapture: QuickCaptureController
    @EnvironmentObject private var screenshotClipboard: ScreenshotClipboardController
    @EnvironmentObject private var replyDrafter: ReplyDrafterController
    @EnvironmentObject private var fileDrop: FileDropController
    @EnvironmentObject private var liveTranslation: LiveTranslationController
    @EnvironmentObject private var meetingLive: LiveMeetingAssist
    @EnvironmentObject private var downloads: DownloadsController
    @EnvironmentObject private var tray: TrayStore
    @EnvironmentObject private var clipboard: ClipboardController
    @EnvironmentObject private var screenRecorder: ScreenRecorderController
    @EnvironmentObject private var colorPicker: ColorPickerController
    @ObservedObject private var flowCanvasSettings = FCSettingsModel.shared
    @StateObject private var loginItem = LaunchAtLogin()
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Menu {
            Menu("Home Buttons") {
                ForEach(macros.slots) { slot in
                    Menu("Button \(slot.id + 1): \(slot.assignment?.title ?? "None")") {
                        ShortcutPickerItems(slot: slot)
                    }
                }
            }
            Divider()
            Menu("Meetings") {
                Button(meetingAssistant.phase == .recording ? "Stop Recording" : "Record Meeting") {
                    if meetingAssistant.phase == .recording {
                        meetingAssistant.stop()
                    } else {
                        meetingAssistant.start(title: nil, calendarEventID: nil)
                    }
                }
                Button("Meeting Notes…") { meetingAssistant.openNotesWindow() }
                Divider()
                MeetingsMenuItems(controller: meetings)
                Divider()
                Toggle("Suggest Answers to Questions", isOn: $meetingAssistant.suggestAnswers)
                Toggle("Allow Meeting Notes to Use My Groq Key", isOn: $meetingAssistant.allowGroqForMeetings)
                Divider()
                LiveTranslationMenu(controller: liveTranslation)
                Divider()
                Button("Live Captions for This Meeting") {
                    MeetingIntelCenter.current?.coordinator.startManually(title: nil, calendarEventID: nil, plan: .captionsOnly)
                }
                .disabled(meetingAssistant.phase != .idle)
                MeetingStartMenuItems(prefs: MeetingIntelPreferences.shared)
                Divider()
                MeetingLiveAssistMenuItems(assist: meetingLive)
            }
            Menu("Planner") { PlannerMenuItems(timer: timer, macros: macros) }
            Menu("Live Activities") {
                Toggle("Now Playing Beside the Notch", isOn: $media.showsInClosedNotch)
                // Show / hide macOS pop-up, style, steps, displays, preview.
                Menu("Volume & Brightness") { HUDMenuItems() }
                Toggle("Battery & AirPods", isOn: $power.isEnabled)
                if power.bluetoothAccess == .notDetermined {
                    Button("Enable AirPods Battery…") { power.requestBluetoothAccess() }
                }
                SystemStatusMenuItems()
                Toggle("Timer", isOn: $timer.isEnabled)
                Toggle("Meetings", isOn: $meetings.isEnabled)
                Toggle("Notifications", isOn: $notifications.isEnabled)
                Toggle("Hide Message Text", isOn: $notifications.hidesMessageBody)
                    .disabled(!notifications.isEnabled)
                Divider()
                // Show in Wings, Next Activity ⌃⌥A, Timing, Notification
                // Options, Calls, Announce to VoiceOver (Labs/Activities).
                LiveActivitiesMenuItems()
            }
            Menu("Media") { MediaPlusMenuItems() }
            Divider()
            // The island: where it shows, how it opens, how it looks.
            Menu("Island & Look") {
                Menu("Island") { IslandPlacementMenuItems() }
                Menu("Island Behavior") { IslandInteractionMenuItems() }
                Menu("Appearance") { AppearanceMenuItems() }
                Menu("Layout") { LayoutMenuItems() }
                Menu("Notch Theme") { NotchThemeMenuItems() }
                Menu("Ambient Light") { AmbientLightMenuItems() }
            }
            Menu("System") {
                Menu("Keep Awake") { KeepAwakeMenuItems() }
                Menu("Microphone") { MicMuteMenuItems() }
                Menu("Quick Toggles") { QuickTogglesMenuItems() }
                Menu("Menu Bar Icons") { MenuBarOverflowMenuItems() }
                Menu("Screen Distance") {
                    ScreenDistanceMenuItems(controller: screenDistance)
                }
                Menu("Fans") { FanMenuItems() }
            }
            Menu("Tools") {
                Menu("Dictation") {
                    Picker("Hold to Talk", selection: $dictation.hotkey) {
                        ForEach(DictationController.Hotkey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    Toggle("AI Formatting", isOn: $dictation.formattingEnabled)
                    Toggle("Paste / Copy Last Dictation  ⌃⌘V ⌃⌘C", isOn: $dictation.historyShortcutsEnabled)
                }
                Menu("Focus") {
                    Button(focus.isActive ? "End Focus" : "Start Focus (\(focus.settings.focusMinutes) min)") { focus.toggle() }
                    if focus.isActive {
                        Button(focus.isPaused ? "Resume" : "Pause") { focus.togglePause() }
                    }
                    Button("Focus Settings…") { FocusSettingsWindowController.shared.show(controller: focus) }
                    Divider()
                    Toggle("Turn On Do Not Disturb", isOn: $focus.settings.usesDoNotDisturb)
                    Toggle("Remind Me About Distractions", isOn: $focus.settings.blocksDistractions)
                    Toggle("Write Recap On Device", isOn: $focus.settings.summarizesWithModel)
                    Divider()
                    Picker("Screen Glow", selection: $focus.settings.edgeGlow) {
                        ForEach(FocusEdgeGlowMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Shake on Start and Breaks", isOn: $focus.settings.edgeGlowKick)
                        .disabled(focus.settings.edgeGlow == .off)
                    Toggle("Confetti When a Session Ends", isOn: $focus.settings.edgeGlowConfetti)
                        .disabled(focus.settings.edgeGlow == .off)
                    Button("Preview Screen Glow") { focus.previewEdgeGlow(.focus) }
                }
                Menu("Modes") { ModesMenuItems() }
                if let smartMoments = SmartMomentsWiring.current {
                    SmartMomentsMenu(settings: smartMoments.settings)
                }
                UniversalSearchSettingsMenu(controller: universalSearch)
                Menu("Clipboard") {
                    Button("Open Clipboard Stack  ⌘⇧V") { clipboard.showStackPanel() }
                    Toggle("⌘ + Number + V Pastes From History", isOn: Binding(
                        get: { clipboard.stackChordEnabled }, set: { clipboard.setStackChordEnabled($0) }))
                    Toggle("⌘⇧V Opens the Clipboard Stack", isOn: Binding(
                        get: { clipboard.stackPanelShortcutEnabled }, set: { clipboard.setStackPanelShortcutEnabled($0) }))
                    if clipboard.stackShortcutsNeedAccessibility {
                        Divider()
                        Button("Allow Accessibility for ⌘+Number+V…") { clipboard.openAccessibilitySettings() }
                    }
                }
                Menu("Screen Tools") {
                    ScreenTextGrabMenuItems(controller: screenRegion.textGrab)
                    Divider()
                    ScreenRecorderMenuItems(recorder: screenRecorder)
                }
                Menu("Color Picker") { ColorPickerMenuItems(controller: colorPicker) }
                Menu("Quick Capture") {
                    QuickCaptureMenuItems(capture: quickCapture, screenshots: screenshotClipboard)
                }
                Menu("Spaces") {
                    Button("Open Spaces…") { SpacesWindowController.shared.show() }
                    Button("Save Current Web Page") { SpaceIngestCenter.saveCurrentWebPage() }
                    Button("Save Selected Mail") { SpaceIngestCenter.saveSelectedMail() }
                    Button("Quick Capture  \(quickCapture.settings.shortcut.displayString)") { quickCapture.captureNow() }
                    if spacesIngest.screenshotWatchNeedsConsent {
                        Button("File New Screenshots Automatically") { spacesIngest.allowScreenshotWatching() }
                    }
                }
                Button("Sync to iPhone…") { CloudSyncWindowController.shared.show() }
                Menu("Teleprompter") { TeleprompterMenuItems() }
                Menu("Mirror") { CameraMirrorMenuItems() }
                Menu("Agents") {
                    Button("UI Audit…") { uiAudit.showWindow() }
                    Button("Job Agent…") { jobAgent.showWindow() }
                    Button("Capture Job Page  fn⌃") { jobAgent.captureNow() }
                    Button("Ask About Screen…  \(screenRegion.shortcut.displayString)") { screenRegion.beginSelection() }
                    Button("Pick a Window to Ask About…") { screenRegion.beginSelection(mode: .window) }
                    Button("Prompt Refiner…") { promptRefiner.openPanel() }
                    Button("Browser Flows…") { browserRecorder.openWindow() }
                    Divider()
                    Button("Draft Reply…  \(replyDrafter.shortcutLabel)") { replyDrafter.draftReply() }
                    ReplyDrafterMenuToggles(settings: replyDrafter.settings)
                    Divider()
                    Button("Flow Canvas…") { FlowCanvasWindowController.shared.show() }
                    Button("Send Tray to Flow Canvas") {
                        FlowCanvasWindowController.shared.show(adding: FlowCanvasInput.from(trayItems: tray.items))
                    }
                    .disabled(tray.items.isEmpty)
                    Toggle("Allow Flow Canvas to Use My Groq Key", isOn: $flowCanvasSettings.allowsGroq)
                }
            }
            Menu("Files") {
                Menu("Shelf") { ShelfMenuItems() }
                FileDropSettingsMenu(controller: fileDrop)
                Menu("Downloads") {
                    Toggle("Watch Downloads Folder", isOn: Binding(get: { downloads.isEnabled }, set: { downloads.setEnabled($0) }))
                    Toggle("Show Download Progress Under the Notch", isOn: $downloads.showsActivity)
                        .disabled(!downloads.isEnabled)
                    Toggle("Suggest Folders with Apple Intelligence", isOn: $downloads.suggestsWithAI)
                    Divider()
                    Button("Sorting Rules…") { downloads.openRulesEditor() }
                }
            }
            Menu("Developer") {
                    CodingAgentsMenuItems()
                    Divider()
                    DevStatusMenuItems()
                Divider()
                Menu("Scripts") { ScriptWidgetMenuItems() }
            }
            Divider()
            OnboardingMenuItems()
            Button(FaceUnlock.isSetUp ? "Face Unlock Settings…" : "Set Up Face Unlock…") {
                FaceUnlock.openSettings()
            }
            Divider()
            if loginItem.status == .requiresApproval {
                Button("Launch at Login (Needs Approval…)") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItem.status == .enabled },
                    set: { loginItem.setEnabled($0) }
                ))
            }
            if let error = loginItem.lastError {
                Text("Couldn’t change Launch at Login: \(error)")
            }
            Divider()
            LocalizationMenuItems()
            // Quits cleanly (the same work as Quit) and opens SparkV again:
            // the fix for a lost or misplaced island.
            Button("Restart SparkV") { PermissionCenter.shared.relaunch(from: "Menu") }
            AppShellMenuItems()
        } label: {
            // Same 12 pt semibold glyph, 24x22 hit area and hover fill as
            // the tab icons beside it.
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.inactiveGlyph)
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .frame(width: 24, height: 22)
                .sparkVHoverFill(hover.isOn, cornerRadius: 11)
                .contentShape(Capsule())
        }
        // .borderlessButton ignores the label's font and color.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover.isOn = $0 }
        .help("Settings and more")
        .accessibilityLabel("Settings and more")
        .onAppear { loginItem.reload() }
    }
}

/// Reply Drafter's toggles; a wrapper so SwiftUI observes `ReplyDrafterSettings`.
private struct ReplyDrafterMenuToggles: View {
    @ObservedObject var settings: ReplyDrafterSettings
    var body: some View {
        Menu("Reply Drafter") {
            Toggle("Write Reply into the Message Box", isOn: $settings.autoInsert)
            Toggle("Fill an Empty Email Subject", isOn: $settings.fillSubject)
            Toggle("Use Spaces as Context", isOn: $settings.useSpaces)
            Toggle("Read the Window When Text Is Hidden", isOn: $settings.readScreen)
            Toggle("Shortcut \(settings.shortcut.displayString)", isOn: $settings.hotkeyEnabled)
            Toggle("Allow Reply Drafter to Use My Groq Key", isOn: $settings.allowGroq)
            Button("Tone & Name…") { ReplyDrafterSettingsWindow.shared.show(settings: settings) }
        }
    }
}

@MainActor
private final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    /// Shown in the gear menu when the last change was refused.
    @Published private(set) var lastError: String?

    func reload() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            NSLog("SparkV: launch-at-login change failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        reload()
        // macOS can accept the registration but hold it until the user
        // approves it in Login Items.
        if enabled, status == .requiresApproval {
            lastError = nil
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// MARK: - Feature grid

private struct FeaturesGrid: View {
    var body: some View {
        HStack(spacing: 0) {
            HomeMediaSlot()
                .frame(width: 180, height: 69, alignment: .leading)
            Spacer(minLength: 8)
            // 56 pt rotary volume knob beside the transport controls.
            WidgetsHomeAccessory()
            Spacer(minLength: 8)
            ColumnDivider()
            Spacer(minLength: 8)
            MacroColumn()
                .frame(width: 130)
            Spacer(minLength: 8)
            ColumnDivider()
            Spacer(minLength: 8)
            MirrorColumn()
                .frame(width: 60)
        }
    }
}

private struct ColumnDivider: View {
    var body: some View {
        Rectangle()
            .fill(SparkVTheme.choose(apple: Color.white.opacity(0.15), sparkv: SparkVTheme.stroke))
            .frame(width: 1, height: 52)
    }
}

// MARK: Column A – media (MediaColumnV2, Labs/Media)

// MARK: Column B – shortcut macros

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

/// Menu items that bind a capsule to a built-in action or a shortcut from
/// the user's library.
private struct ShortcutPickerItems: View {
    @EnvironmentObject private var macros: MacroController
    let slot: MacroController.Slot

    var body: some View {
        Section("SparkV") {
            ForEach(MacroController.BuiltInAction.allCases) { action in
                pickerButton(.builtIn(action), systemImage: action.systemImage)
            }
        }
        Section("Shortcuts") {
            if macros.library.isEmpty {
                Text("No shortcuts found")
            } else {
                ForEach(macros.library, id: \.self) { name in
                    pickerButton(.shortcut(name), systemImage: nil)
                }
            }
        }
        Section("Apps") {
            Button("Choose an App…") {
                macros.chooseApp { assignment in
                    if let assignment { macros.assign(assignment, to: slot.id) }
                }
            }
            Menu("Running Apps") {
                ForEach(macros.runningApps, id: \.storageValue) { app in
                    pickerButton(app, systemImage: nil)
                }
            }
        }
        Divider()
        if slot.assignment != nil {
            Button("Remove from This Button") { macros.assign(nil, to: slot.id) }
        }
        Button("Open Shortcuts…") { macros.openShortcutsApp() }
    }

    @ViewBuilder
    private func pickerButton(_ assignment: MacroController.Assignment, systemImage: String?) -> some View {
        Button {
            macros.assign(assignment, to: slot.id)
        } label: {
            if assignment == slot.assignment {
                Label(assignment.title, systemImage: "checkmark")
            } else if let systemImage {
                Label(assignment.title, systemImage: systemImage)
            } else {
                Text(assignment.title)
            }
        }
    }
}

private struct MacroCapsule: View {
    @EnvironmentObject private var macros: MacroController
    @EnvironmentObject private var dictation: DictationController
    let slot: MacroController.Slot
    let status: MacroController.Status

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Group {
            switch status {
            case .unassigned, .missing:
                // Nothing runnable yet: a click opens the picker.
                Menu {
                    ShortcutPickerItems(slot: slot)
                } label: {
                    capsule
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
            default:
                Button {
                    macros.run(slot)
                } label: {
                    capsule
                }
                .buttonStyle(SparkVPressStyle())
                .disabled(status == .running)
                .contextMenu {
                    ShortcutPickerItems(slot: slot)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(helpText)
    }

    /// The Dictate capsule turns into a live "Stop" button while recording.
    private var isLiveDictation: Bool {
        slot.assignment == .builtIn(.dictate) && dictation.isActive
    }

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
                    // "Capture to Tray" fits the 130 pt capsule this way
                    // instead of truncating.
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 130, height: 27)
        .background(Capsule().fill(isLiveDictation
                                   ? SparkVTheme.choose(apple: Color.red.opacity(0.35), sparkv: SparkVTheme.red)
                                   : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
        .overlay(Capsule().strokeBorder(isLiveDictation || SparkVTheme.isApple ? Color.clear : (hover.isOn ? SparkVTheme.red.opacity(0.45) : SparkVTheme.stroke), lineWidth: 1))
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .idle:
            if case .builtIn(let action) = slot.assignment {
                Image(systemName: isLiveDictation ? "stop.fill" : action.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isLiveDictation ? Color.white : SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red))
            } else if let assignment = slot.assignment, assignment.isApp, let icon = LauncherIcons.icon(for: assignment) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.red))
            }
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(SparkVTheme.progressTint)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.success)
        case .failed, .missing:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(status == .missing ? SparkVTheme.warning : SparkVTheme.destructive)
        case .unassigned:
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    /// A failure replaces the title so it is readable without a tooltip. A
    /// missing shortcut keeps its name (orange) so the user sees which one.
    private var label: String {
        if isLiveDictation { return "Stop Dictation" }
        return switch status {
        case .failed: "Failed"
        case .unassigned: "Add Action"
        default: slot.assignment?.title ?? "Add Action"
        }
    }

    private var labelColor: Color {
        switch status {
        case .failed: SparkVTheme.destructive
        case .missing: SparkVTheme.warning
        case .unassigned: SparkVTheme.textSecondary
        default: SparkVTheme.text
        }
    }

    private var helpText: String {
        let name = slot.assignment?.title ?? ""
        return switch status {
        case .failed(let message): "\(name): \(message)"
        case .missing: "“\(name)” is no longer in your Shortcuts library. Click to choose another."
        case .unassigned: "Choose an action or shortcut for this button"
        default: "\(name) · Right-click to change"
        }
    }
}

// MARK: Column C – mirror

private struct MirrorColumn: View {
    @EnvironmentObject private var camera: CameraController
    @ObservedObject private var mirrorSettings = CameraMirrorSettings.shared
    @EnvironmentObject private var screenDistance: ScreenDistanceController

    var body: some View {
        VStack(spacing: 5) {
            Button {
                // Let a Screen Distance burst release the camera first.
                if !camera.isRunning { screenDistance.yieldCamera() }
                camera.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(camera.isRunning ? Color.clear : SparkVTheme.surface)
                    Circle()
                        .strokeBorder(camera.isRunning ? SparkVTheme.choose(apple: Color.green.opacity(0.9), sparkv: SparkVTheme.red)
                                                       : SparkVTheme.choose(apple: Color.clear, sparkv: SparkVTheme.stroke),
                                      lineWidth: camera.isRunning ? 1.5 : 1)
                        .zIndex(1)

                    if camera.isRunning {
                        CameraMirrorView(session: camera.session, mirrored: mirrorSettings.isMirrored)
                            .clipShape(Circle())
                            .transition(.opacity)
                    } else if camera.isStarting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(SparkVTheme.progressTint)
                    } else {
                        Image(systemName: camera.isDenied ? "video.slash.fill" : "video.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(camera.isDenied ? SparkVTheme.textTertiary : SparkVTheme.text)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(SparkVPressStyle())
            .help(camera.errorMessage ?? "Toggle camera mirror")
            .contextMenu { CameraMirrorMenuItems() }

            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(captionColor)
                .lineLimit(1)
        }
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.standard), value: camera.isRunning)
        // Leaving the Nook tab (or closing the drawer) removes the preview,
        // so the camera must not keep capturing behind it.
        // The circle shows the camera whenever it runs: closing the large
        // mirror while it is on screen keeps the camera on here.
        .onAppear { camera.drawerPreviewAppeared() }
        .onDisappear { camera.releaseDrawerPreview() }
    }

    private var caption: String {
        if camera.isRunning || camera.errorMessage == nil { return "Mirror" }
        return camera.isDenied ? "No Access" : "Error"
    }

    private var captionColor: Color {
        if camera.isRunning { return SparkVTheme.choose(apple: SparkVTheme.success, sparkv: SparkVTheme.red) }
        return camera.errorMessage == nil ? SparkVTheme.textSecondary : SparkVTheme.warning
    }
}
