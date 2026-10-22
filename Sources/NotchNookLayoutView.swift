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
    /// Notch theme and island background (Labs/NotchThemes).
    @ObservedObject private var themeSettings = NotchThemeSettings.shared

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
        let size: CGSize = if state.isExpanded {
            NotchMetrics.expandedSize(for: state.tab)
        } else {
            closed?.size ?? state.collapsedSize
        }
        // glance-style silhouette: shoulders flare into the menu bar, and both
        // radii grow as the island opens. The flare sits outside the body.
        let radii: (top: CGFloat, bottom: CGFloat) = if state.isExpanded {
            (NotchMetrics.openFlareRadius, NotchMetrics.openBottomRadius)
        } else if closed?.band != nil {
            (NotchMetrics.activityFlareRadius, NotchMetrics.activityBottomRadius)
        } else {
            (NotchMetrics.closedFlareRadius, NotchMetrics.closedBottomRadius)
        }
        let shape = IslandShape(topRadius: radii.top, bottomRadius: radii.bottom)
        let wingsSource = state.isExpanded ? nil : NotchActivityView.wingsSource(activities: activities, media: media)

        ZStack(alignment: .top) {
            shape.fill(SparkVTheme.islandBackground)

            // Album-art glow (boring.notch style), under all content; the
            // clip shape below keeps it inside the island.
            // Only with the Album Glow background; Black keeps the island pure black.
            if themeSettings.background == .albumGlow, state.isExpanded, state.tab == .nook {
                MediaGlowBackground(center: UnitPoint(
                    x: (16 + radii.top + MediaColumnV2.artworkSide / 2) / (size.width + 2 * radii.top),
                    y: (state.collapsedSize.height + MediaColumnV2.artworkSide / 2) / size.height
                ))
                .transition(.opacity)
            } else if themeSettings.background == .albumGlow, !state.isExpanded, wingsSource == .nowPlaying {
                MediaGlowBackground(style: .pill, center: UnitPoint(
                    x: (radii.top + 22) / (size.width + 2 * radii.top),
                    y: 0.5
                ), intensity: 0.8)
                .transition(.opacity)
            }

            if state.isExpanded {
                VStack(spacing: 0) {
                    HeaderRow()
                        // Header shares the band beside the camera cutout, so
                        // nothing important is drawn under the physical notch.
                        .frame(height: state.collapsedSize.height)

                    // Crossfade between tabs (opacity, a slight scale and
                    // blur) while the drawer's height springs to the new tab.
                    ZStack {
                        tabContent
                            .id(state.tab)
                            .transition(.tabCrossfade)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(NotchMetrics.tabAnimation, value: state.tab)
                }
                .padding(.horizontal, 16 + radii.top)
                .padding(.bottom, NotchMetrics.drawerBottomPadding)
                // The whole drawer accepts files, including the header band the
                // drag enters through; a drag over Nook switches to the Tray.
                .contentShape(Rectangle())
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
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else if let closed {
                // Compact wings beside the camera housing, inside the menu
                // bar, plus the band under the notch only when expanded.
                ClosedIslandContent(layout: closed, restingHeight: state.collapsedSize.height, source: wingsSource)
                    .padding(.horizontal, radii.top)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + 2 * radii.top, height: size.height)
        .clipShape(shape)
        // Hover theme, behind and around the black body. Plain draws nothing.
        .background(alignment: .top) {
            NotchThemeBackdrop(
                isExpanded: state.isExpanded,
                bodySize: size,
                topRadius: radii.top,
                bottomRadius: radii.bottom
            )
        }
        // Ambient Light: music-synced glow around the island (nothing while off).
        .background(alignment: .top) {
            AmbientNotchGlowBackdrop(bodySize: size, topRadius: radii.top, bottomRadius: radii.bottom)
        }
        // Uneven wings shift the body so the housing stays over the camera.
        .offset(x: closed?.xOffset ?? 0)
        .animation(NotchMetrics.hoverAnimation, value: closed)
        .animation(NotchMetrics.hoverAnimation, value: state.tab)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        }
    }
}

// MARK: - Tab transition

/// Fades a tab's content with a slight scale and blur, so switching tabs
/// reads as one surface changing rather than a hard swap.
private struct TabCrossfadeModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .scaleEffect(1 - 0.03 * progress, anchor: .top)
            .blur(radius: 5 * progress)
    }
}

extension AnyTransition {
    /// Drawer tab crossfade (see `TabCrossfadeModifier`).
    static var tabCrossfade: AnyTransition {
        .modifier(active: TabCrossfadeModifier(progress: 1), identity: TabCrossfadeModifier(progress: 0))
    }
}

// MARK: - Header

private struct HeaderRow: View {
    @EnvironmentObject private var assistant: MeetingAssistant

    var body: some View {
        // Each side of the camera housing has 161.5 pt (508 pt header, 185 pt
        // housing on the 16-inch MacBook Pro). Measured at spacing 2: left
        // group 154 pt with Widgets; right group 145 pt with Focus, 148 pt while the record
        // button shows "● 59:59". Focus steps aside while recording, since
        // both together (174 pt) would slide under the camera.
        HStack(spacing: 2) {
            // Places on the left, actions on the right; the camera cutout sits
            // in the gap between them. Icons only, each with a tooltip.
            IconTab(systemImage: "house.fill", tab: .nook, help: "Home: media, shortcuts and mirror")
            IconTab(systemImage: "rectangle.3.group.fill", tab: .widgets, help: "Widgets: world clocks, volume, habits, system and network")
            IconTab(systemImage: "tray.full.fill", tab: .tray, help: "Tray: screenshots, text and files")
            IconTab(systemImage: "calendar", tab: .today, help: "Today: meetings and timer")
            IconTab(systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard", tab: .converter, help: "Convert: drop a file, pick a format")
            IconTab(systemImage: "square.stack.3d.up.fill", tab: .spaces, help: "Spaces: knowledge folders per organization")
            Spacer(minLength: 0)
            if assistant.phase != .recording {
                FocusHeaderButton()
            }
            RecordMeetingButton()
            IconTab(systemImage: "square.grid.2x2.fill", tab: .agents, help: "Agents: search, focus, capture, reply, screen, prompts, clipboard, files, downloads and more",
                    activeFor: NotchState.Tab.agentTabs)
            // Original SF Symbols, not the Wispr Flow or Clicky logos.
            IconTab(systemImage: "waveform", tab: .flow, help: "Flow: dictation history and notes")
            IconTab(systemImage: "cursorarrow.rays", tab: .clicky, help: "Clicky: ask about your screen")
            SettingsMenu()
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

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let isActive = state.tab == tab || activeFor.contains(state.tab)
        Button {
            withAnimation(.easeOut(duration: 0.15)) { state.select(tab) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? SparkVTheme.activeGlyph : (hover.isOn ? SparkVTheme.text : SparkVTheme.inactiveGlyph))
                .frame(width: 24, height: 22)
                .background(
                    Capsule().fill(isActive ? SparkVTheme.activeTabFill : (hover.isOn ? SparkVTheme.hoverFill : Color.clear))
                )
                .overlay(
                    Capsule().strokeBorder(isActive ? SparkVTheme.activeTabStroke : Color.clear, lineWidth: 0.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help)
    }
}

/// One-click meeting recording from the header: a red record glyph that
/// turns into a blinking dot with the elapsed time while recording.
private struct RecordMeetingButton: View {
    @EnvironmentObject private var assistant: MeetingAssistant

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
                            Circle()
                                .fill(SparkVTheme.recording)
                                .frame(width: 7, height: 7)
                                .opacity(Int(context.date.timeIntervalSince(started)) % 2 == 0 ? 1 : 0.35)
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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Stop recording and write meeting notes" : "Record this meeting (transcript, tasks and minutes)")
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
    @ObservedObject private var flowCanvasSettings = FCSettingsModel.shared
    @StateObject private var loginItem = LaunchAtLogin()

    var body: some View {
        Menu {
            ForEach(macros.slots) { slot in
                Menu("Button \(slot.id + 1): \(slot.assignment?.title ?? "None")") {
                    ShortcutPickerItems(slot: slot)
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
            Menu("Live Activities") {
                Toggle("Now Playing Beside the Notch", isOn: $media.showsInClosedNotch)
                Toggle("Volume & Brightness", isOn: $hud.isEnabled)
                Toggle("Hide macOS Volume/Brightness Pop-up", isOn: $hud.replacesSystemHUD)
                    .disabled(!hud.isEnabled)
                Toggle("Battery & AirPods", isOn: $power.isEnabled)
                if power.bluetoothAccess == .notDetermined {
                    Button("Enable AirPods Battery…") { power.requestBluetoothAccess() }
                }
                Toggle("Timer", isOn: $timer.isEnabled)
                Toggle("Meetings", isOn: $meetings.isEnabled)
                Toggle("Notifications", isOn: $notifications.isEnabled)
                Toggle("Hide Message Text", isOn: $notifications.hidesMessageBody)
                    .disabled(!notifications.isEnabled)
            }
            Menu("Downloads") {
                Toggle("Watch Downloads Folder", isOn: Binding(get: { downloads.isEnabled }, set: { downloads.setEnabled($0) }))
                Toggle("Show Download Progress Under the Notch", isOn: $downloads.showsActivity)
                    .disabled(!downloads.isEnabled)
                Toggle("Suggest Folders with Apple Intelligence", isOn: $downloads.suggestsWithAI)
                Divider()
                Button("Sorting Rules…") { downloads.openRulesEditor() }
            }
            Menu("Dictation") {
                Picker("Hold to Talk", selection: $dictation.hotkey) {
                    ForEach(DictationController.Hotkey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                Toggle("AI Formatting", isOn: $dictation.formattingEnabled)
                Toggle("Paste / Copy Last Dictation  ⌃⌘V ⌃⌘C", isOn: $dictation.historyShortcutsEnabled)
            }
            Menu("Modes") { ModesMenuItems() }
            if let smartMoments = SmartMomentsWiring.current {
                SmartMomentsMenu(settings: smartMoments.settings)
            }
            Menu("Notch Theme") { NotchThemeMenuItems() }
            Menu("Ambient Light") { AmbientLightMenuItems() }
            AppearanceMenu()
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
            Menu("Fans") { FanMenuItems() }
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
            Menu("Screen Distance") {
                ScreenDistanceMenuItems(controller: screenDistance)
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
            Menu("Quick Capture") {
                QuickCaptureMenuItems(capture: quickCapture, screenshots: screenshotClipboard)
            }
            UniversalSearchSettingsMenu(controller: universalSearch)
            FileDropSettingsMenu(controller: fileDrop)
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
            Button("Quit SparkV") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12))
                .foregroundStyle(SparkVTheme.inactiveGlyph)
        }
        // .borderlessButton ignores the label's font and color.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
            MediaColumnV2()
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

    var body: some View {
        VStack(spacing: 7) {
            ForEach(macros.slots) { slot in
                MacroCapsule(slot: slot, status: macros.status(for: slot))
            }
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
            statusIcon
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 130, height: 27)
        .background(Capsule().fill(isLiveDictation
                                   ? SparkVTheme.choose(apple: Color.red.opacity(0.35), sparkv: SparkVTheme.red)
                                   : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
        .overlay(Capsule().strokeBorder(isLiveDictation || SparkVTheme.isApple ? Color.clear : (hover.isOn ? SparkVTheme.red.opacity(0.45) : SparkVTheme.stroke), lineWidth: 1))
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
                        CameraMirrorView(session: camera.session)
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
            .buttonStyle(.plain)
            .help(camera.errorMessage ?? "Toggle camera mirror")

            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(captionColor)
                .lineLimit(1)
        }
        .animation(.easeOut(duration: 0.2), value: camera.isRunning)
        // Leaving the Nook tab (or closing the drawer) removes the preview,
        // so the camera must not keep capturing behind it.
        .onDisappear { camera.stop() }
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
