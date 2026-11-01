import AppKit
import Carbon.HIToolbox
import Combine
import GlanceKit
import SwiftUI

/// Owns the notch panel, positions it over the hardware notch and drives the
/// hover → expand / leave → collapse cycle.
///
/// The panel is laid out once at the expanded 540×115 size, pinned to the top
/// edge of the screen. The visible black shape inside it springs between the
/// 220×38 resting size and the full drawer. Animating the SwiftUI shape rather
/// than calling `setFrame` every frame keeps the spring at a steady 60/120 FPS;
/// while collapsed the panel ignores mouse events, so the transparent area
/// around the notch never blocks the menu bar.
@MainActor
final class NotchWindowController: NSWindowController {
    private let state = NotchState()
    private let media = MediaEngine()
    private let macros = MacroController()
    private let camera = CameraController()
    private let tray = TrayStore()
    private let dictation = DictationController()
    private let flow = FlowStore.shared
    private let clicky: ClickyController
    // Live activities: HUDs, battery/AirPods, timer, meetings, notifications.
    private let activities = ActivityCenter()
    private let hud: HUDController
    private let power: PowerMonitor
    private let timer: TimerController
    private let meetings: MeetingsController
    private let notifications: NotificationMonitor
    private let meetingAssistant: MeetingAssistant
    private let converter: ConverterController
    private let spacesIngest: SpaceIngestCenter
    // Agents (opened from the Agents hub).
    private let uiAudit: UIAuditController
    private let jobAgent: JobAgentController
    private let screenRegion: ScreenRegionController
    private let screenRecorder: ScreenRecorderController
    private let promptRefiner: PromptRefinerController
    private let browserRecorder: BrowserRecorderController
    private let clipboard: ClipboardController
    private let screenDistance: ScreenDistanceController
    private let focus: FocusController
    private let universalSearch: UniversalSearchController
    private let quickCapture: QuickCaptureController
    private let screenshotClipboard: ScreenshotClipboardController
    private let replyDrafter: ReplyDrafterController
    private let fileDrop: FileDropController
    private let liveTranslation: LiveTranslationController
    private let meetingIntel: MeetingIntelCenter
    private let meetingLive: LiveMeetingAssist
    private let meetingWrapUp: MeetingWrapUpController
    private let downloads: DownloadsController
    private let colorPicker: ColorPickerController
    private var smartMoments: SmartMomentsWiring?
    /// Live activities: music beside other activities, calls, ⌃⌥A (Labs/Activities).
    private let liveActivities: LiveActivitiesController
    /// Re-checks the band under a still pointer when the band changes.
    private var bandPointerObserver: AnyCancellable?
    /// A ringing call: collapses the drawer and passes through a hidden island.
    private var callRingingObserver: AnyCancellable?
    /// When a band with buttons may take clicks (see `ActivityBandClickGate`).
    private var bandClickGate = ActivityBandClickGate()
    /// This code made the collapsed panel take clicks (and so may undo it).
    private var bandTakesClicks = false
    private var bandClickRecheck: Task<Void, Never>?

    private var eventMonitors: [Any] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var collapseTask: Task<Void, Never>?
    /// Opened from the menu bar icon, a sparkv:// link or a reopen: the
    /// drawer stays open until the pointer has been over it once (or 10 s).
    private var shellPinnedOpen = false
    /// Opened by a keyboard shortcut: the drawer holds the keyboard (tab
    /// navigation, Esc always closes) and hands it back when it closes.
    private var keyboardSession = false
    /// Opened from the keyboard: hover doesn't close it until the pointer
    /// has been on the drawer once (Esc, the hotkey, a click outside do).
    private var keyboardPinned = false
    private var keyboardPinEntered = false
    private var shellPinEntered = false
    private var shellPinTask: Task<Void, Never>?
    /// Runs only while the drawer is open: closes it as soon as glance's
    /// overlay takes the notch (e.g. Set Up Face Unlock… from the gear menu),
    /// which no pointer event announces.
    private var faceUnlockWatch: Task<Void, Never>?
    /// True while any NSMenu (gear menu, tray context menu) is open.
    private var isMenuTracking = false
    /// The current left-button press started inside the drawer (e.g. dragging
    /// a file out of the tray), as opposed to anywhere else on screen.
    private var pressBeganInPanel = false
    /// Screen-space rect of the resting notch, used as the hover hot zone.
    private var notchRect: NSRect = .zero
    private var tabObserver: AnyCancellable?
    /// Control+Option+1...5 toggle the first five Modes.
    private var modeHotkeys: [ScreenRegionHotkey] = []
    /// Pending shrink of the panel to a shorter tab (see `resizeForTab`).
    private var tabResizeTask: Task<Void, Never>?
    /// Hover look and pointer for the notch theme layer.
    private let themeHover = NotchThemeHoverState.shared
    /// Pointer on the closed island, waiting out the theme's hover dwell.
    private var hoverDwellTask: Task<Void, Never>?
    /// "Preview on my notch" from the theme picker.
    private var themePreviewTask: Task<Void, Never>?
    private var themeObserver: AnyCancellable?
    /// Ambient Light needs the same glow margin as a notch theme.
    private var ambientObserver: AnyCancellable?
    /// Hides Ambient Light's screen edges while SparkV records the screen.
    private var ambientRecordingObserver: AnyCancellable?
    /// Glow margin the panel was laid out with (0 for Plain).
    private var appliedThemeOutset: CGFloat = 0

    // Island placement and visibility (Labs/IslandPlacement).
    private let placement = IslandPlacementController()
    /// Whether the island shows, and why not.
    private var visibility = IslandVisibilityDecision.shown
    /// The panel is (or is fading) on screen.
    private var isPanelShown = true
    /// Where the island sits on its display (nil: no display for it).
    private var geometry: IslandGeometry?
    /// The frame the last layout set, for the recovery check.
    private var expectedPanelFrame: NSRect = .zero
    /// Frame of the island's display (Follow the Pointer's quick check).
    private var islandScreenFrame: NSRect = .zero
    /// Coalesces bursts of screen-change notifications.
    private var relayoutTask: Task<Void, Never>?
    /// The notch inset lagged once after a lid opening; retried.
    private var insetRetryDone = false
    /// Settles after wake, unlock or a user switch, then re-places the island.
    private var recoveryTask: Task<Void, Never>?
    /// Follow the Pointer: the display the pointer moved to, waiting a second.
    private var pointerFollowTask: Task<Void, Never>?
    private var pendingPointerDisplay: CGDirectDisplayID?
    /// Hidden for full screen: pointer held against the top edge.
    private var revealTask: Task<Void, Never>?
    private var revealEndTask: Task<Void, Never>?
    /// The top edge or ⌃⌥H brought a hidden island back for now.
    private var isRevealed = false
    /// The drawer was opened by the keyboard or another feature while the
    /// island was hidden: it shows until the drawer closes.
    private var drawerRevealed = false
    /// No display for the island, but SparkV swallows the volume and
    /// brightness keys: the island is laid out on the main display for the
    /// HUD band only.
    private var hudFallbackDisplayID: CGDirectDisplayID?
    /// Mirrors no display needs right now, kept for the next one (All
    /// Displays swaps roles instead of building a new hierarchy).
    private var spareMirrors: [IslandMirror] = []
    private var hudObserver: AnyCancellable?
    /// The next visibility change came from the keyboard: no fade.
    private var nextVisibilityInstant = false
    /// All Displays: click-through copies of the closed island.
    private var mirrors: [CGDirectDisplayID: IslandMirror] = [:]
    private var placementBands: AnyCancellable?

    // Island interaction: how it opens, closes and moves (Labs/IslandInteraction).
    private let interaction = IslandInteractionController()
    /// Pointer speed, for hover intent (fed by the mouse monitors).
    private var pointerTracker = IslandPointerTracker()
    private var swipeTracker = IslandSwipeTracker()
    private var pressTracker = IslandPressTracker()
    /// Press and Hold: fires when the hold time is up.
    private var pressTask: Task<Void, Never>?
    /// The hover dwell was started over this part of the island.
    private var hoverDwellZone: IslandHoverZone?
    /// When the drawer last opened (system uptime), for the minimum open time.
    private var openedAt: Double?
    /// Open by Click or Press and Hold: the closed island takes the button
    /// while the pointer is on it.
    private var clickCaptureActive = false
    /// `collapsedHotZone`, kept until an activity, the media, dictation,
    /// Clicky, the layout or the menu bar room changes.
    private var hotZoneCache: NSRect?
    private var hotZoneObservers: [AnyCancellable] = []
    private var interactionObserver: AnyCancellable?
    private var lastInteraction = IslandInteractionStore.current
    /// The closed island had wings at the last look (menu bar sampling).
    private var wingsVisible = false
    private var wingsCheckScheduled = false
    /// The pointer was on the closed island at the last move.
    private var pointerWasOnIsland = false
    /// Closed on request (Esc, the notch, a swipe up, ⌃⌥O) with the pointer
    /// on the island: hover can't reopen it until the pointer leaves.
    private var closeLatch = IslandCloseLatch()

    /// Held this long against the top edge, a hidden island comes back.
    private static let topEdgeRevealDwell: Duration = .milliseconds(500)
    /// Follow the Pointer waits this long on a new display before moving.
    private static let followPointerDelay: Duration = .seconds(1)
    /// Hover dwell while the display is full screen (even for Plain).
    private static let fullScreenHoverDwell: Duration = .milliseconds(400)
    /// A resting island woken from the top-edge strip shows first, then opens.
    private static let restingRevealDwell: Duration = .milliseconds(250)
    /// Rows at the top edge that belong to macOS's full-screen menu bar.
    private static let fullScreenMenuBarRows: CGFloat = 2
    /// This Mac's built-in display has a notch (seen in an earlier layout),
    /// so a zero inset after the lid opens is lag worth one retry.
    private static var builtInHasNotch: Bool {
        get { UserDefaults.standard.bool(forKey: IslandPlacementSettings.Key.prefix + "builtInHasNotch") }
        set {
            guard newValue != builtInHasNotch else { return }
            UserDefaults.standard.set(newValue, forKey: IslandPlacementSettings.Key.prefix + "builtInHasNotch")
        }
    }

    init() {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: NotchMetrics.panelSize))
        clicky = ClickyController(dictation: dictation)
        hud = HUDController(activities: activities)
        power = PowerMonitor(activities: activities)
        timer = TimerController(activities: activities)
        meetings = MeetingsController(activities: activities)
        notifications = NotificationMonitor(activities: activities)
        meetingAssistant = MeetingAssistant(activities: activities)
        liveTranslation = LiveTranslationController(activities: activities)
        let intelStart = MeetingStartCoordinator(
            activities: activities,
            assistant: meetingAssistant,
            translation: liveTranslation,
            calendar: { MeetingsController.current?.meetings ?? [] },
            spaces: SpaceStore.shared
        )
        meetingLive = LiveMeetingAssist(activities: activities, assistant: meetingAssistant)
        meetingWrapUp = MeetingWrapUpController(
            activities: activities,
            assistant: meetingAssistant,
            spaces: SpaceStore.shared,
            reminders: PermissionCenterRemindersGate()
        )
        meetingIntel = MeetingIntelCenter(start: intelStart, live: meetingLive, wrapUp: meetingWrapUp)
        converter = ConverterController(activities: activities)
        spacesIngest = SpaceIngestCenter(store: SpaceStore.shared, activities: activities)
        uiAudit = UIAuditController(activities: activities)
        jobAgent = JobAgentController(activities: activities)
        screenRegion = ScreenRegionController(activities: activities)
        screenRecorder = ScreenRecorderController(activities: activities)
        promptRefiner = PromptRefinerController(activities: activities)
        browserRecorder = BrowserRecorderController(activities: activities)
        clipboard = ClipboardController(activities: activities)
        screenDistance = ScreenDistanceController(activities: activities)
        universalSearch = UniversalSearchController.live(
            flow: flow,
            meetings: meetingAssistant,
            clipboard: clipboard,
            tray: tray,
            spaces: SpaceStore.shared,
            dictation: dictation
        )
        quickCapture = QuickCaptureController(store: SpaceStore.shared, activities: activities)
        screenshotClipboard = ScreenshotClipboardController(activities: activities)
        replyDrafter = ReplyDrafterController(activities: activities)
        fileDrop = FileDropController(activities: activities)
        downloads = DownloadsController(activities: activities)
        colorPicker = ColorPickerController()
        focus = FocusController(
            activities: activities,
            timer: timer,
            sources: .live(tray: tray, meetingAssistant: meetingAssistant, notifications: notifications)
        )
        liveActivities = LiveActivitiesController(
            activities: activities, media: media, notifications: notifications, meetingAssistant: meetingAssistant
        )
        super.init(window: panel)
        smartMoments = SmartMomentsWiring(app: SmartMomentsAppControllers(
            media: media, camera: camera, screenDistance: screenDistance, activities: activities,
            power: power, timer: timer, meetings: meetings, notifications: notifications,
            meetingAssistant: meetingAssistant, liveTranslation: liveTranslation,
            screenRecorder: screenRecorder, clipboard: clipboard, focus: focus, downloads: downloads,
            screenshotClipboard: screenshotClipboard, tray: tray,
            openTab: { [weak self] tab in
                self?.state.select(tab)
                self?.setExpanded(true)
            }
        ))
        // MeetingIntel is built: Meeting soon's Agenda brief and Meeting
        // ended's wrap-up use it. Before `start()`, which installs the moments.
        smartMoments?.meetingIntelExtras = SmartMomentsMeetingIntelExtras(
            meetingBrief: { [weak meetingAssistant] meeting in
                guard MeetingIntelPreferences.shared.showBrief, let assistant = meetingAssistant else { return nil }
                let brief = await MeetingBriefBuilder.build(
                    title: meeting.title, calendarEventID: meeting.eventID, event: meeting,
                    library: assistant.library, spaces: SpaceStore.shared,
                    calendarGranted: PermissionCenter.shared.isGranted(.calendars), now: Date()
                )
                let lines = brief.bandLines(max: MeetingSoonMoment.briefLineLimit).map(\.text)
                return lines.isEmpty ? nil : lines
            },
            openWrapUp: { MeetingWrapUpController.current?.openWindow(meetingID: $0) },
            presentWrapUp: { MeetingWrapUpController.current?.present(meetingID: $0, session: nil, sidecar: nil) }
        )
        focus.bandOpensTab = .focus
        uiAudit.activityTab = .uiAudit
        browserRecorder.opensTab = .browser
        screenDistance.opensTab = .screenDistance
        screenDistance.isCameraBusy = { [weak camera] in
            (camera?.isRunning ?? false) || (camera?.isStarting ?? false) || FaceUnlock.isUsingNotch
        }
        SpacesWindowController.shared.openMeeting = { [weak meetingAssistant] id in meetingAssistant?.openNotesWindow(meetingID: id) }
        screenRegion.onWillBeginSelection = { [weak clicky] in clicky?.cancel() }
        screenRegion.onSaveToTray = { [weak tray] providers in tray?.accept(providers) }
        screenRecorder.onWillBegin = { [weak clicky] in clicky?.cancel() }
        screenRecorder.onAddToTray = { [weak tray] url in tray?.addFile(url) }
        screenRegion.drawerAccessory = { [screenRecorder] in AnyView(ScreenRecorderDrawerTile(recorder: screenRecorder)) }
        promptRefiner.startDictation = { [weak dictation] done in dictation?.startNoteDictation(completion: done) ?? false }
        promptRefiner.stopDictation = { [weak dictation] in dictation?.finishNoteDictation() }
        converter.activityOpensTab = .converter
        converter.onAddToTray = { [tray] urls in urls.forEach(tray.addFile) }
        fileDrop.activityOpensTab = .fileDrop
        fileDrop.converter = converter
        fileDrop.onAddToTray = { [tray] urls in urls.forEach(tray.addFile) }
        fileDrop.isDrawerExpanded = { [weak self] in self?.state.isExpanded ?? false }
        fileDrop.onOpenStrip = { [weak self] in
            self?.state.select(.fileDrop)
            self?.setExpanded(true)
        }
        // A file drag that ended anywhere clears the drawer's drop highlight,
        // so the dashed well never sticks.
        fileDrop.onDragEnded = { [weak self] in self?.state.isDropTargeted = false }
        // Finder copy and LocalSend progress bands open the Downloads tab,
        // where the transfers are listed with Pause / Cancel / Reveal.
        ShelfTransfersMonitor.shared.connect(activities: activities, opensTab: .downloads)
        fileDrop.onOpenConverter = { [weak self] in
            self?.state.select(.converter)
            self?.setExpanded(true)
        }
        downloads.opensTab = .downloads
        downloads.onAddToTray = { [tray] url in tray.addFile(url) }
        downloads.onOpenTab = { [weak self] in
            self?.state.select(.downloads)
            self?.setExpanded(true)
        }
        // Color Picker: the band opens its page on hover; the drawer gets out
        // of the way before the loupe shows, so it can't tint the pixels.
        colorPicker.connect(activities: activities, opensTab: .colorPicker)
        colorPicker.onWillPick = { [weak self] in self?.forceCollapse() }
        colorPicker.onOpenDrawer = { [weak self] in
            self?.state.select(.colorPicker)
            self?.setExpanded(true)
        }
        universalSearch.openFlowHandler = { [weak self] target in
            // FlowView reads its section from this default when it is created.
            if case .flowNote = target { UserDefaults.standard.set("notes", forKey: "flow.section") }
            else { UserDefaults.standard.set("history", forKey: "flow.section") }
            self?.state.select(.flow)
            self?.setExpanded(true)
        }
        liveTranslation.attach(to: meetingAssistant)
        MeetingIntelCenter.current = meetingIntel
        LiveMeetingAssist.current = meetingLive
        MeetingWrapUpController.current = meetingWrapUp
        meetingIntel.coordinator.startRecording = { [weak meetingAssistant] call, plan in
            guard let assistant = meetingAssistant else { return }
            if let call { assistant.startRecording(for: call) } else { assistant.start(title: nil, calendarEventID: nil) }
            if plan.keepNotes, assistant.phase == .recording { assistant.openNotesWindow() }
        }
        meetingIntel.coordinator.setWritesNotes = { [weak meetingAssistant] id, writes in
            if writes { meetingAssistant?.skipNotesFor.remove(id) } else { meetingAssistant?.skipNotesFor.insert(id) }
        }
        meetingAssistant.callOfferOverride = { [weak meetingIntel] call in
            meetingIntel?.coordinator.wantsOffer(for: call) ?? false
        }
        // A file dragged out of a shelf and dropped in another app closes the
        // drawer right away (Shift-drop keeps it open, Dropover-style).
        let dragEnd = NotificationCenter.default.addObserver(forName: TrayDragOut.didEndNotification, object: nil, queue: .main) { [weak self] note in
            let dropped = note.userInfo?["dropped"] as? Bool == true
            let keepOpen = note.userInfo?["keepOpen"] as? Bool == true
            MainActor.assumeIsolated {
                guard let self, self.state.isExpanded, dropped, !keepOpen, !self.state.isPinned, !self.isPointerInHotZone() else { return }
                self.forceCollapse()
            }
        }
        observers.append((NotificationCenter.default, dragEnd))
        FlowCanvasWindowController.shared.onSendToTray = { [tray] urls in urls.forEach(tray.addFile) }
        FlowCanvasWindowController.shared.onSendToSpace = { title, markdown, url in
            _ = SpaceStore.shared.addManual(title: title, text: markdown, url: url, spaceID: nil, kind: .note)
        }

        // Every controller injected (see `islandRoot`; the All Displays
        // mirrors use the same root).
        let root = islandRoot(state: state)
        let hostingView = NotchHostingView(rootView: root)
        // The window frame is owned by this controller, not by SwiftUI's ideal size.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: NotchMetrics.panelSize)
        panel.contentView = hostingView
        panel.setAccessibilityLabel("SparkV island")

        positionOverNotch()
        // Display choice, styles, full screen, excluded apps, capture
        // privacy, Black Menu Bar and ⌃⌥H.
        connectPlacement()
        // @Published fires before the new value is stored, so re-layout on
        // the next turn of the run loop.
        tabObserver = state.$tab.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeForTab() }
        }
        // A theme other than Plain needs a glow margin around the panel.
        themeObserver = NotchThemeSettings.shared.$theme.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.themeHover.isHovered = false
                self.themeHover.setPointer(nil)
                self.positionOverNotch()
            }
        }
        AmbientLightController.shared.attach(media: media)
        // Media package (Labs/MediaPlus): outputs, app volumes, lyrics, live bars.
        MediaVisualizerController.shared.ambientFeatures = { AmbientLightController.shared.liveFeatures }
        MediaPlus.start(media: media, activities: activities)
        ambientObserver = AmbientLightController.shared.$wantsNotchOutset
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.positionOverNotch() }
            }
        ambientRecordingObserver = screenRecorder.$phase
            .map(\.isRecording)
            .removeDuplicates()
            .sink { recording in
                AmbientLightController.shared.setEdgeSuppression(recording, reason: "screenRecording")
            }
        // Open by, delays, gestures, motion, size, menu bar, other notch apps.
        connectInteraction()
        installMouseMonitors()
        observeSystemEvents()
        // A band that appears, changes or goes away under a still pointer is
        // re-checked without waiting for a move. This never turns clicks on
        // by itself: a new band needs the pointer to move onto it.
        bandPointerObserver = activities.$current
            .map { $0.map { "\($0.id)|\($0.isInteractive)" } }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.handleActivityBandPointer(moved: false) } }
            }
        // A ringing call shows over full screen (`callRinging`) and the
        // drawer makes way for it, unless a drag or a menu is in progress.
        callRingingObserver = liveActivities.calls.$incoming
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ringing in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if ringing, self.state.isExpanded, !self.isInteractionInProgress { self.forceCollapse() }
                        self.applyVisibility()
                    }
                }
            }
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
        connectAppShell()

        macros.performBuiltIn = { [weak self] action in
            guard let self else { return }
            switch action {
            case .dictate:
                self.dictation.toggleHandsFree()
            case .recordMeeting:
                if self.meetingAssistant.phase == .recording {
                    self.meetingAssistant.stop()
                } else {
                    self.meetingAssistant.start(title: nil, calendarEventID: nil)
                }
            case .captureToTray:
                // Get the drawer out of the way of the selection.
                self.forceCollapse()
                self.state.select(.tray)
                self.tray.captureScreenshot()
            }
        }
        // Customize Layout › Features: each starts only while switched on.
        let features = FeatureSwitches.shared
        features.connect(.flow, start: { [weak dictation] in dictation?.start() }, stop: { [weak dictation] in dictation?.shutdown() })
        features.connect(.clicky, start: { [weak clicky] in clicky?.start() }, stop: { [weak clicky] in clicky?.shutdown() })
        [hud.start, power.start, timer.start, notifications.start].forEach { $0() }
        features.connect(.today, start: { [weak meetings] in meetings?.start() }, stop: { [weak meetings] in meetings?.stop() })
        // After the timer, so a running session re-attaches to its countdown.
        focus.start()
        startModes()
        meetingAssistant.start()
        meetingIntel.start()
        // Music as a peer activity, call timer / incoming calls / mute, ⌃⌥A.
        liveActivities.start()
        FeatureSwitches.shared.connect(.spaces, start: { [weak spacesIngest] in spacesIngest?.start() },
                                       stop: { [weak spacesIngest] in spacesIngest?.stop() })
        let cloudSync = CloudSyncController.shared
        cloudSync.connect(meetings: meetingAssistant, tray: tray, clipboard: clipboard, focus: focus)
        cloudSync.onImport = { [weak self] message in
            self?.activities.post(CloudSyncController.importActivity(message))
        }
        // Does nothing unless the user turned sync on; then the first sync runs 8 s after launch.
        cloudSync.start()
        clipboard.onOpenTab = { [weak self] in
            self?.state.select(.clipboard)
            self?.setExpanded(true)
        }
        [uiAudit.start, jobAgent.start, screenRegion.start, screenRecorder.start, promptRefiner.start, browserRecorder.start, clipboard.start, replyDrafter.start, fileDrop.start].forEach { $0() }
        // ⌥Space (search); ⌃⌥R (reply) above; ⌃⌥S (screen) next; ⌃⌥C (capture) below.
        universalSearch.start()
        screenRegion.installHotkey()
        // ⌃⌥⇧R: record the screen (a second press stops).
        _ = screenRecorder.installHotkey()
        // Opens the camera only if the user turned Screen Distance on.
        screenDistance.start()
        quickCapture.start()
        // Both watch only if the user turned them on.
        screenshotClipboard.start()
        downloads.start()
        // ⌃⌥P: pick a color. Registers the hotkey only; nothing else runs.
        colorPicker.start()
        ShelfTransfersMonitor.shared.start()
        FanController.shared.start()
        RemindersController.shared.start()
        WeatherController.shared.start(activities: activities)
        PlannerRouter.shared.openDrawer = { [weak self] in
            guard let self else { return }
            self.state.select(.today)
            self.setExpanded(true)
        }
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
        // The Dev tab's gear and the CI empty state open Settings › Extras directly.
        ExtrasSettingsOpener.handler = { SparkVSettings.show(SparkVSettingsPane(rawValue: $0) ?? .extras) }
        // The teleprompter and the large mirror close the drawer when you
        // ask for them from inside it (see step 19 for the rest).
        ExtrasIslandCover.collapseIsland = { [weak self] in self?.forceCollapse() }
        // Battery details, accessories, privacy dots, keep awake, mic mute,
        // connection alerts, Caps Lock and quick toggles (Labs/SystemStatus).
        let systemStatus = SystemStatusCenter.shared
        systemStatus.connect(activities: activities)
        systemStatus.statusTab = .status
        systemStatus.openStatusPage = { [weak self] in
            self?.state.select(.status)
            self?.setExpanded(true)
        }
        // SparkV's own camera use never lights the camera dot.
        systemStatus.isOwnCameraActive = { [weak camera] in
            (camera?.isRunning ?? false) || (camera?.isStarting ?? false) || FaceUnlock.isUsingNotch
        }
        // After the meeting assistant, downloads and clipboard started: it
        // chains onto their events.
        smartMoments?.start()
        if let sources = smartMoments?.sources {
            // Connection alerts stay quiet while sharing; the privacy dots show it.
            systemStatus.isScreenSharing = { [weak sources] in sources?.isScreenSharing ?? false }
            PrivacyIndicatorMonitor.shared.connectScreenSharing(sources.$isScreenSharing.eraseToAnyPublisher())
        }
        systemStatus.start()
        // MeetingIntel's start prompt is the only band for a call; Smart
        // Moments folds its quiet chips into it.
        let momentIntel = meetingIntel.coordinator
        MeetingStartedMoment.current?.connect(MeetingStartedIntelLink(
            willPrompt: { [weak momentIntel] call in
                guard let c = momentIntel, c.prefs.isEnabled, c.assistant.detectCalls, !c.assistant.autoStartDetectedCalls,
                      MeetingStartCoordinator.isIdle(c.assistant.phase) else { return false }
                return c.prefs.rule(for: MeetingKindKey(call: call)) != .never
            },
            isOn: { [weak momentIntel] in momentIntel?.prefs.isEnabled ?? false },
            stages: momentIntel.$stage.map { stage -> MeetingStartedIntelStage in
                switch stage {
                case .idle: .idle
                case .prompting(let call), .countingDown(let call, _, _): .offering(callKey: call.key)
                case .live(let s): .live(callKey: s.callKey, plan: MeetingStartedPlan(
                    notes: s.plan.keepNotes, captions: s.plan.captions, translate: s.plan.translate))
                }
            }.eraseToAnyPublisher(),
            start: { [weak momentIntel] plan, call in
                guard let c = momentIntel else { return }
                let p = MeetingStartPlan(keepNotes: plan.notes, captions: plan.captions, translate: plan.translate, targetLanguage: nil)
                if c.offeredCall?.key == call.key { c.choose(p, remember: false) }
                else { c.startManually(title: call.title, calendarEventID: call.calendarEventID, plan: p) }
            },
            changePlan: { [weak momentIntel] plan in
                guard let c = momentIntel, let s = c.session else { return }
                c.changePlan(MeetingStartPlan(keepNotes: s.plan.keepNotes, captions: plan.captions,
                                              translate: plan.translate, targetLanguage: s.plan.targetLanguage))
            }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        // Hidden (full screen, clamshell, an excluded app…) stays hidden.
        guard visibility.isOnScreen else { return }
        window?.orderFrontRegardless()
        isPanelShown = true
    }

    func tearDown() {
        // Wallpaper back, hotkey and watchers off, mirrors closed.
        placement.stop()
        placementBands = nil
        interaction.stop()
        DrawerShortcutStore.shared.stop()
        interactionObserver = nil
        hotZoneObservers.removeAll()
        pressTask?.cancel()
        pressTask = nil
        [relayoutTask, recoveryTask, pointerFollowTask, revealTask, revealEndTask].forEach { $0?.cancel() }
        for mirror in mirrors.values { mirror.panel.close() }
        mirrors.removeAll()
        spareMirrors.forEach { $0.panel.close() }
        spareMirrors.removeAll()
        hudObserver = nil
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        collapseTask?.cancel()
        hoverDwellTask?.cancel()
        themePreviewTask?.cancel()
        faceUnlockWatch?.cancel()
        faceUnlockWatch = nil
        shellPinTask?.cancel()
        shellPinTask = nil
        camera.stop()
        clicky.shutdown()
        [hud.stop, power.stop, timer.stop, meetings.stop, notifications.stop].forEach { $0() }
        liveTranslation.stop()
        meetingIntel.stop()
        liveActivities.stop()
        meetingAssistant.shutdown()
        [uiAudit.stop, jobAgent.stop, screenRegion.stop, screenRecorder.shutdown, promptRefiner.stop, browserRecorder.stop, clipboard.stop, replyDrafter.stop, fileDrop.stop].forEach { $0() }
        universalSearch.stop()
        spacesIngest.stop()
        screenDistance.stop()
        quickCapture.stop()
        screenshotClipboard.stop()
        smartMoments?.stop()
        downloads.stop()
        colorPicker.stop()
        ShelfTransfersMonitor.shared.stop()
        // Ends a LocalSend search and any send in progress.
        LocalSendController.shared.cancel()
        LocalSendController.shared.panelClosed()
        focus.stop()
        // Every fan back to Auto before SparkV quits.
        FanController.shared.stop()
        CodingAgentsController.shared.stop()
        DevCIController.shared.stop()
        DevServersController.shared.stop()
        ScriptWidgetsController.shared.stop()
        TeleprompterController.shared.stop()
        MenuBarOverflowController.shared.stop()
        RemindersController.shared.stop()
        WeatherController.shared.stop()
        SystemStatusCenter.shared.stop()
        CloudSyncController.shared.stop()
        dictation.shutdown()
        // Removes every App Volume tap and aggregate (synchronous).
        MediaPlus.stop()
        // Also ends the Now Playing adapter's perl process.
        media.stop()
    }

    /// True while a screen recording is running or being written.
    var hasWorkToFinishBeforeQuit: Bool {
        (screenRecorder.phase != .idle && screenRecorder.phase != .selecting)
            || ModeEngine.shared.activeModeID != nil
            || (smartMoments?.hasWorkToFinishBeforeQuit ?? false)
    }

    /// Stops a running recording and waits until the movie is saved.
    func finishWorkBeforeQuit(timeout: Duration) async {
        screenRecorder.stop()   // recording: stop and save; starting: stop as soon as it begins; selecting: cancel
        // Do Not Disturb, previews and presentation mode go back before quitting.
        await smartMoments?.prepareForQuit()
        let deadline = ContinuousClock.now + timeout
        // Puts the wallpaper, volume, apps and Do Not Disturb back; if it runs
        // past the deadline the next launch restores the rest.
        if ModeEngine.shared.activeModeID != nil {
            let restore = Task { await ModeEngine.shared.prepareForQuit() }
            while ModeEngine.shared.activeModeID != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            _ = restore
        }
        while hasWorkToFinishBeforeQuit, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Modes

    private func startModes() {
        let modes = ModeEngine.shared
        // Lets modes use SparkV's Focus feature and notification previews.
        LiveModeSystem.shared.focusHooks = ModeFocusHooks(
            startSession: { [weak focus] focusMinutes, breakMinutes in
                guard let focus, !focus.isActive else { return false }
                let saved = focus.settings
                var s = saved
                if let focusMinutes { s.focusMinutes = focusMinutes }
                if let breakMinutes { s.shortBreakMinutes = breakMinutes }
                focus.startSession(using: s)
                // The session captured its plan, so the user's own settings come back.
                if focusMinutes != nil || breakMinutes != nil { focus.settings = saved }
                return true
            },
            endSession: { [weak focus] in focus?.end() },
            isSessionActive: { [weak focus] in focus?.isActive ?? false },
            previewsEnabled: { [weak notifications] in notifications?.isEnabled },
            setPreviewsEnabled: { [weak notifications] in notifications?.isEnabled = $0 },
            doNotDisturbShortcuts: { [weak focus] in
                (focus?.settings.dndOnShortcut ?? ModeDoNotDisturbNames.on,
                 focus?.settings.dndOffShortcut ?? ModeDoNotDisturbNames.off)
            }
        )
        modes.onActivityText = { [weak activities] text in
            guard let activities else { return }
            let engine = ModeEngine.shared
            guard text != nil, let mode = engine.activeMode else { activities.dismiss(id: "mode"); return }
            activities.post(LiveActivity(
                id: "mode", kind: .timer, priority: 20, duration: nil,
                symbol: mode.symbol, tint: ModeColors.color(mode.colorHex),
                compactText: ModeStatusText.text(since: engine.activeSince, endsAt: engine.endsAt),
                peekKey: mode.id.uuidString
            ) {
                ModeActivityView()
            })
        }
        // Undoes a mode that was still on when SparkV crashed or was force quit.
        Task { await modes.start() }

        for (index, keyCode) in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].enumerated() {
            let hotkey = ScreenRegionHotkey()
            hotkey.onPress = {
                let engine = ModeEngine.shared
                guard engine.modes.indices.contains(index) else { return }
                Task { await engine.toggle(engine.modes[index].id) }
            }
            if !hotkey.register(ScreenRegionShortcut(keyCode: UInt32(keyCode), carbonModifiers: UInt32(controlKey | optionKey))) {
                AppLog.log("Modes: Control+Option+\(index + 1) is taken by another app")
            }
            modeHotkeys.append(hotkey)
        }
    }

    // MARK: - Positioning

    /// The display the island is on (nil while it has none). Kept for the
    /// other packages' patches that call it; new code uses `IslandScreen.current`.
    static func targetScreen() -> NSScreen? {
        IslandScreen.current
    }

    /// Lays the island out on the display the placement settings pick
    /// (built-in, main, a saved one, the pointer's, all), at the real notch
    /// width from the screen's auxiliary top areas, or as a pill or a
    /// resting-hidden Minimal island; then decides whether it shows.
    private func positionOverNotch() {
        guard let panel = window else { return }
        let resolution = placement.resolve()
        var target: (display: IslandDisplayInfo, screen: NSScreen)?
        if let display = resolution.island, let screen = IslandDisplays.screen(for: display.id) {
            target = (display, screen)
            hudFallbackDisplayID = nil
        } else if hud.isEnabled, hud.replacesSystemHUD, placement.sessionActive,
                  let screen = NSScreen.main ?? NSScreen.screens.first,
                  let display = IslandDisplays.info(for: screen) {
            // Built-in Only with the lid closed: SparkV still swallows the
            // volume and brightness keys, so their band shows on the main
            // display (nothing else does, and no hover there).
            target = (display, screen)
            hudFallbackDisplayID = display.id
        } else {
            hudFallbackDisplayID = nil
        }
        guard let (display, screen) = target else {
            // Built-in Only with the lid closed, or no display at all.
            geometry = nil
            notchRect = .zero
            islandScreenFrame = .zero
            LookIsland.note(screen: nil, hasNotch: false)
            placement.noteIslandDisplay(nil)
            layoutMirrors([])
            applyVisibility()
            return
        }
        if let previous = placement.islandDisplayID, previous != display.id, state.isExpanded {
            // Never carry an open drawer to another display.
            forceCollapse()
        }
        // The HUD-only fallback isn't the island's display for anything else.
        placement.noteIslandDisplay(hudFallbackDisplayID == nil ? display.id : nil)
        if CGDisplayIsBuiltin(display.id) != 0, screen.safeAreaInsets.top > 0 { Self.builtInHasNotch = true }
        islandScreenFrame = screen.frame
        // Closed Width (Settings › Appearance › Island Size) adds shoulders.
        let geo = IslandGeometry.make(IslandDisplays.metrics(of: screen), placement.settings.geometryOptions(for: display))
            .widened(by: IslandInteractionStore.current.closedWidth.extra)
        geometry = geo
        let surface = IslandSurface(
            shape: geo.surface == .pill ? .pill : .notch,
            hasNotch: geo.hasNotch,
            housingWidth: geo.housingWidth,
            restsHidden: geo.restsHidden,
            showsHairline: geo.showsHairline,
            topInset: geo.topInset
        )
        if state.surface != surface { state.surface = surface }
        LookIsland.note(screen: screen, hasNotch: geo.hasNotch)
        if state.collapsedSize != geo.collapsedSize { state.collapsedSize = geo.collapsedSize }
        if !geo.restsHidden, state.isRestingRevealed { state.isRestingRevealed = false }
        notchRect = geo.notchRect
        hotZoneCache = nil
        // Where menu bar items and other notch apps are looked for.
        let housing = NSRect(x: geo.centerX - geo.housingWidth / 2, y: geo.notchRect.minY,
                             width: geo.housingWidth, height: geo.collapsedSize.height)
        interaction.noteIsland(housing: housing, notchRect: geo.notchRect, screenFrame: screen.frame, menuBarHeight: geo.menuBarHeight)

        // Sized to the current tab so a shorter drawer never leaves a
        // transparent strip below it that swallows clicks. A notch theme adds
        // a glow margin on the left, right and bottom (0 for Plain); the top
        // stays at the screen edge (or the pill's margin), so the island does
        // not move.
        let outset = max(
            NotchThemeLayout.outset(for: NotchThemeSettings.shared.theme),
            AmbientLightController.shared.notchOutset
        )
        appliedThemeOutset = outset
        let frame = geo.panelFrame(expanded: NotchMetrics.panelSize(for: state.tab), outset: outset)
        expectedPanelFrame = frame
        panel.setFrame(frame, display: true)
        (panel as? NotchPanel)?.setHidesInMissionControl(placement.settings.hidesInMissionControl)
        if state.isExpanded { updateClickThrough() }

        // Compact content must clear the widest camera housing in use.
        let mirrorHousing = layoutMirrors(hudFallbackDisplayID == nil ? resolution.mirrors : [])
        NotchMetrics.cameraHousingWidth = max(geo.housingWidth, mirrorHousing)
        applyVisibility()
    }

    /// A taller tab grows the panel at once, so the drawer can spring into
    /// it; a shorter one shrinks the panel only after the drawer's height
    /// animation has played, so its bottom isn't cut off mid-spring.
    private func resizeForTab() {
        tabResizeTask?.cancel()
        tabResizeTask = nil
        let target = NotchMetrics.panelSize(for: state.tab).height + appliedThemeOutset + (geometry?.topInset ?? 0)
        guard let current = window?.frame.height, target < current - 0.5, state.isExpanded else {
            positionOverNotch()
            return
        }
        tabResizeTask = Task { [weak self] in
            try? await Task.sleep(for: NotchMetrics.tabShrinkDelay)
            guard !Task.isCancelled else { return }
            self?.positionOverNotch()
        }
    }

    /// Display changes come in bursts (lid, plug, resolution, wake): one
    /// relayout 300 ms after the last, snapped to exact top-center.
    private func scheduleRelayout(reason: String, delay: Duration = .milliseconds(300)) {
        relayoutTask?.cancel()
        relayoutTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.relayoutTask = nil
            self.relayoutNow(reason: reason)
        }
    }

    private func relayoutNow(reason: String) {
        tabResizeTask?.cancel()
        tabResizeTask = nil
        let before = placement.islandDisplayID
        let changed = placement.refreshDisplays()
        let after = placement.resolve().island?.id
        if changed || after != before {
            // The drawer doesn't follow a display change half open.
            if state.isExpanded, !isInteractionInProgress { forceCollapse() }
            AppLog.log("Island: displays changed (\(reason)), island on \(placement.info(for: after)?.name ?? "no display")")
        }
        themeHover.isHovered = false
        themeHover.setPointer(nil)
        positionOverNotch()
        if visibility.isOnScreen, let panel = window, !panel.isVisible || panel.alphaValue < 0.99 {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            isPanelShown = true
        }
        // The lid just opened: the notch inset can lag behind the screen
        // (only on a Mac whose built-in display has a notch).
        let builtIn = NSScreen.screens.first { IslandDisplays.displayID(of: $0).map { CGDisplayIsBuiltin($0) != 0 } ?? false }
        if let builtIn, builtIn.safeAreaInsets.top == 0, Self.builtInHasNotch, !insetRetryDone {
            insetRetryDone = true
            scheduleRelayout(reason: "notch inset settling", delay: .seconds(1))
        } else {
            insetRetryDone = false
        }
    }

    // MARK: - Visibility

    /// Full screen, excluded apps, clamshell, displays without a notch,
    /// a manual hide or a quiet Smart Moment hide the island; a volume or
    /// dictation band can still pass through.
    private func visibilityInputs(displayID: CGDirectDisplayID?, hasNotch: Bool, isMain: Bool) -> IslandVisibilityInputs {
        let s = placement.settings
        var inputs = IslandVisibilityInputs(
            sessionActive: placement.sessionActive,
            hasDisplay: displayID != nil,
            displayHasNotch: hasNotch,
            showOnDisplaysWithoutNotch: s.showOnDisplaysWithoutNotch,
            builtInDisplayActive: placement.builtInActive,
            hideInClamshell: s.hideInClamshell,
            isFullScreen: placement.isFullScreen(displayID),
            hideInFullScreen: s.hideInFullScreen,
            frontAppExcluded: placement.isFrontAppExcluded,
            exclusionBehavior: s.exclusionBehavior,
            manuallyHidden: placement.isManuallyHidden,
            quiet: !placement.quietReasons.isEmpty,
            revealed: isMain && isRevealed,
            isInteracting: isMain && state.isExpanded && isInteractionInProgress,
            hudShowing: activities.current?.kind.isLiveFeedback == true,
            showsHUDWhileHidden: s.showsHUDWhileHidden,
            systemHUDReplaced: hud.isEnabled && hud.replacesSystemHUD,
            voiceShowing: dictation.phase != .idle || clicky.phase != .idle,
            showsVoiceWhileHidden: s.showsVoiceWhileHidden,
            callRinging: liveActivities.calls.incoming != nil
        )
        inputs.drawerRevealed = isMain && drawerRevealed
        inputs.hasHUDFallbackDisplay = isMain && hudFallbackDisplayID != nil && geometry != nil
        return inputs
    }

    private func applyVisibility() {
        let animated = !nextVisibilityInstant
        nextVisibilityInstant = false
        // A manual hide always wins over a reveal still in progress.
        if placement.isManuallyHidden, isRevealed {
            isRevealed = false
            revealEndTask?.cancel()
            revealEndTask = nil
        }
        let inputs = visibilityInputs(displayID: geometry == nil ? nil : placement.islandDisplayID,
                                      hasNotch: geometry?.hasNotch ?? true, isMain: true)
        let decision = IslandVisibility.decide(inputs)
        visibility = decision
        placement.record(decision)
        if decision.isHidden, state.isExpanded { forceCollapse() }
        if decision.ignoresHover, !state.isExpanded {
            endThemeHover()
            setRestingRevealed(false)
        }
        if !decision.isHidden { cancelTopEdgeReveal() }
        setPanelShown(decision.isOnScreen, animated: animated)
        updateLevel()
        updateMirrorVisibility()
    }

    /// Fades the island in or out (keyboard-triggered changes are instant).
    private func setPanelShown(_ shown: Bool, animated: Bool) {
        guard let panel = window else { return }
        guard shown != isPanelShown || (shown && !panel.isVisible) else { return }
        isPanelShown = shown
        // A fade only (no movement), so Reduce Motion keeps it.
        let fade = animated
        if shown {
            if !panel.isVisible {
                panel.alphaValue = fade ? 0 : 1
                panel.orderFrontRegardless()
            }
            if fade { LiveBandMotion.fadeIn(panel) } else { panel.alphaValue = 1 }
        } else if fade {
            LiveBandMotion.fadeOut(panel)
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    /// Full screen with the island showing: one level below the menu bar
    /// macOS slides down, so the island never covers it; open, it is back
    /// above everything.
    private func updateLevel() {
        guard let panel = window else { return }
        // A top-edge reveal on a notched display stays above the menu bar it
        // slides in with (the notch has no menu bar under it); on a display
        // without a notch it would cover the middle of that menu bar.
        let revealAbove = isRevealed && (geometry?.hasNotch ?? false)
        let lowered = placement.isFullScreen(placement.islandDisplayID) && !state.isExpanded && !visibility.isHidden && !revealAbove
        let level: NSWindow.Level = lowered ? .floating : .statusBar
        if panel.level != level { panel.level = level }
        // The teleprompter and the large mirror sit one level below the
        // island (in full screen too) and fade out while the drawer is open.
        ExtrasIslandCover.islandChanged(expanded: state.isExpanded, level: level)
    }

    /// ⌃⌥H (opt-in): hides the island, or brings back one that is hidden
    /// and opens it. Keyboard-triggered, so nothing animates in.
    private func handleHideHotkey() {
        nextVisibilityInstant = true
        switch IslandHotkeyAction.decide(isRevealed: isRevealed || drawerRevealed,
                                         isManuallyHidden: placement.isManuallyHidden, decision: visibility) {
        case .endReveal:
            // Shown for now over a full-screen (or excluded-app) hide: the
            // second press puts it away again.
            isRevealed = false
            revealEndTask?.cancel()
            revealEndTask = nil
            forceCollapse()
            applyVisibility()
        case .unhideAndOpen:
            placement.unhide()
            applyVisibility()
            // Still hidden for another reason (full screen): show it for now.
            if visibility.isHidden, !visibility.reasons.contains(where: \.isHard) { revealAndOpen() }
            else { openAfterHotkey() }
        case .revealAndOpen:
            revealAndOpen()
        case .none:
            nextVisibilityInstant = false
            AppLog.log("Island: \(IslandPlacementController.hotkeyLabel) can't show it (\(visibility.reasons.map(\.rawValue).joined(separator: ", ")))")
        case .hide:
            forceCollapse()
            placement.hide()
            applyVisibility()
        }
    }

    private func revealAndOpen() {
        nextVisibilityInstant = true
        isRevealed = true
        applyVisibility()
        openAfterHotkey()
    }

    /// Opens at once (keyboard-triggered), when the island is there to open.
    private func openAfterHotkey() {
        guard visibility.isOnScreen, !visibility.isHidden, !visibility.ignoresHover else { return }
        setExpanded(true, animated: false)
        takeKeyboard()
    }

    // MARK: - Top-edge reveal (hidden in full screen)

    /// Hidden for full screen: the pointer held against the top edge over
    /// the notch for half a second brings the island back until it leaves.
    private func trackTopEdgeReveal(_ mouse: NSPoint) {
        guard placement.settings.revealAtTopEdge, let geometry,
              !visibility.reasons.isEmpty, visibility.reasons.allSatisfy({ $0 == .fullScreen }) else {
            cancelTopEdgeReveal()
            return
        }
        let strip = geometry.revealStrip.insetBy(dx: 0, dy: -2)
        guard strip.contains(mouse) else {
            cancelTopEdgeReveal()
            return
        }
        guard revealTask == nil else { return }
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.topEdgeRevealDwell)
            guard !Task.isCancelled, let self else { return }
            self.revealTask = nil
            guard let geometry = self.geometry,
                  geometry.revealStrip.insetBy(dx: 0, dy: -2).contains(NSEvent.mouseLocation) else { return }
            self.isRevealed = true
            self.applyVisibility()
        }
    }

    private func cancelTopEdgeReveal() {
        revealTask?.cancel()
        revealTask = nil
    }

    /// A reveal ends once the pointer has left the closed island for a moment.
    private func scheduleRevealEnd() {
        guard isRevealed, !state.isExpanded, revealEndTask == nil else { return }
        revealEndTask = Task { [weak self] in
            try? await Task.sleep(for: NotchMetrics.collapseDelay)
            guard !Task.isCancelled, let self else { return }
            self.revealEndTask = nil
            guard self.isRevealed, !self.state.isExpanded, !self.isPointerInHotZone() else { return }
            self.isRevealed = false
            self.applyVisibility()
        }
    }

    private func setRestingRevealed(_ revealed: Bool) {
        let value = revealed && state.surface.restsHidden
        if state.isRestingRevealed != value { state.isRestingRevealed = value }
    }

    // MARK: - Follow the pointer, mirrors

    /// Follow the Pointer: the closed island moves to the display the
    /// pointer has rested on for a second. All Displays: reaching a mirror
    /// makes it the live island at once.
    private func followPointer(to mouse: NSPoint) {
        // Still on the island's display: nothing to look up.
        if islandScreenFrame.insetBy(dx: 0, dy: -1).contains(mouse), pendingPointerDisplay == nil { return }
        guard let screen = IslandDisplays.screen(containing: mouse), let id = IslandDisplays.displayID(of: screen) else { return }
        guard id != placement.islandDisplayID else {
            pointerFollowTask?.cancel()
            pointerFollowTask = nil
            pendingPointerDisplay = nil
            return
        }
        if placement.settings.displayMode == .allDisplays {
            if let mirror = mirrors[id], mirror.notchRect.insetBy(dx: -2, dy: -2).contains(mouse) {
                moveIsland(to: id)
            }
            return
        }
        guard pendingPointerDisplay != id else { return }
        pendingPointerDisplay = id
        pointerFollowTask?.cancel()
        pointerFollowTask = Task { [weak self] in
            try? await Task.sleep(for: Self.followPointerDelay)
            guard !Task.isCancelled, let self else { return }
            self.pointerFollowTask = nil
            guard !self.state.isExpanded,
                  let now = IslandDisplays.screen(containing: NSEvent.mouseLocation),
                  IslandDisplays.displayID(of: now) == id else {
                self.pendingPointerDisplay = nil
                return
            }
            self.moveIsland(to: id)
        }
    }

    private func moveIsland(to id: CGDirectDisplayID) {
        pendingPointerDisplay = nil
        placement.pointerDisplayID = id
        endThemeHover()
        setRestingRevealed(false)
        positionOverNotch()
    }

    /// One click-through copy of the closed island per other display (All
    /// Displays). Returns the widest camera housing among them.
    @discardableResult
    private func layoutMirrors(_ displays: [IslandDisplayInfo]) -> CGFloat {
        let wanted = Set(displays.map(\.id))
        for (id, mirror) in mirrors where !wanted.contains(id) {
            // Kept for the next display that needs one: moving the live
            // island between displays swaps roles, no new view hierarchy.
            mirror.panel.orderOut(nil)
            mirror.panel.alphaValue = 1
            mirror.hasShown = false
            mirrors[id] = nil
            spareMirrors.append(mirror)
        }
        // More spares than any layout can use go.
        while spareMirrors.count > 2 {
            let extra = spareMirrors.removeLast()
            placement.capture.unregister(extra.panel)
            extra.panel.close()
        }
        placement.mirrorDisplayIDs = wanted
        var housing: CGFloat = 0
        for display in displays {
            guard let screen = IslandDisplays.screen(for: display.id) else { continue }
            let mirror = mirrors[display.id] ?? (spareMirrors.popLast() ?? makeMirror())
            mirrors[display.id] = mirror
            if mirror.displayBox.displayID != display.id { mirror.displayBox.displayID = display.id }
            let geo = IslandGeometry.make(IslandDisplays.metrics(of: screen), placement.settings.geometryOptions(for: display))
                .widened(by: IslandInteractionStore.current.closedWidth.extra)
            let surface = IslandSurface(shape: geo.surface == .pill ? .pill : .notch, hasNotch: geo.hasNotch,
                                        housingWidth: geo.housingWidth, restsHidden: geo.restsHidden, showsHairline: geo.showsHairline,
                                        topInset: geo.topInset)
            if mirror.state.surface != surface { mirror.state.surface = surface }
            if mirror.state.collapsedSize != geo.collapsedSize { mirror.state.collapsedSize = geo.collapsedSize }
            // Up to the top edge, like the live island's hot zone.
            mirror.notchRect = geo.reachingTopEdge(geo.restsHidden && !geo.hasNotch ? geo.revealStrip : geo.notchRect)
            mirror.hasNotch = geo.hasNotch
            mirror.panel.setFrame(geo.panelFrame(expanded: NotchMetrics.panelSize, outset: appliedThemeOutset), display: true)
            mirror.panel.setHidesInMissionControl(placement.settings.hidesInMissionControl)
            housing = max(housing, geo.housingWidth)
        }
        return housing
    }

    private func makeMirror() -> IslandMirror {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: NotchMetrics.panelSize))
        let mirrorState = NotchState()
        // The HUD for another display's change stays off this mirror. Mirrors
        // are pooled and move between displays, so the display is observed.
        let displayBox = MirrorDisplayBox()
        let host = NotchHostingView(rootView: MirrorHUDScope(box: displayBox, content: islandRoot(state: mirrorState)))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: NotchMetrics.panelSize)
        panel.contentView = host
        panel.setAccessibilityLabel("SparkV island (mirror)")
        placement.capture.register(panel)
        return IslandMirror(panel: panel, state: mirrorState, displayBox: displayBox)
    }

    private func updateMirrorVisibility() {
        for (id, mirror) in mirrors {
            let decision = IslandVisibility.decide(visibilityInputs(displayID: id, hasNotch: mirror.hasNotch, isMain: false))
            let shown = decision.isOnScreen
            if shown, !mirror.panel.isVisible || mirror.panel.alphaValue < 0.99 {
                // A new mirror takes over from the live island that just
                // left this display: no fade, so nothing blinks.
                let fade = mirror.hasShown
                if !mirror.panel.isVisible { mirror.panel.alphaValue = fade ? 0 : 1 }
                mirror.panel.orderFrontRegardless()
                if fade { LiveBandMotion.fadeIn(mirror.panel) }
                mirror.hasShown = true
            } else if !shown, mirror.panel.isVisible {
                LiveBandMotion.fadeOut(mirror.panel)
            }
            let level: NSWindow.Level = placement.isFullScreen(id) && !decision.isHidden ? .floating : .statusBar
            if mirror.panel.level != level { mirror.panel.level = level }
        }
    }

    // MARK: - Recovery

    /// After wake, unlock or a user switch, once displays have settled:
    /// back to exact top-center, ordered in, monitors in place.
    private func scheduleRecovery(reason: String, delay: Duration = .seconds(1)) {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            self.recoverPanel(reason: reason, attempt: 0)
        }
    }

    private func recoverPanel(reason: String, attempt: Int) {
        guard placement.sessionActive else { return }
        // glance's overlay owns the notch at the lock screen: try again shortly.
        if FaceUnlock.isUsingNotch {
            guard attempt < 5 else { return }
            recoveryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.recoverPanel(reason: reason, attempt: attempt + 1)
            }
            return
        }
        placement.resumeWatching()
        placement.refreshDisplays()
        positionOverNotch()
        var fixes: [String] = []
        if let panel = window, visibility.isOnScreen {
            if !panel.isVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                isPanelShown = true
                fixes.append("ordered in")
            }
            if panel.screen == nil || !panel.frame.equalTo(expectedPanelFrame) {
                panel.setFrame(expectedPanelFrame, display: true)
                fixes.append("frame")
            }
        }
        if eventMonitors.isEmpty {
            installMouseMonitors()
            fixes.append("pointer monitors")
        }
        placement.recheckFullScreen()
        AppLog.log("Island: checked after \(reason)\(fixes.isEmpty ? "" : ", fixed " + fixes.joined(separator: ", "))")
    }

    /// Cheap self-check (occlusion changes, Space switches): the island
    /// should be on screen but its window is gone.
    private func selfCheck() {
        guard placement.sessionActive, visibility.isOnScreen, isPanelShown, let panel = window, !panel.isVisible,
              recoveryTask == nil else { return }
        scheduleRecovery(reason: "the island window went missing")
    }

    // MARK: - App shell (Settings window, menu bar icon, sparkv:// links)

    /// Lets the app shell open the drawer, post live activities, run the
    /// timer and Focus from sparkv:// links, and stop everything before a
    /// reset. Called once from init.
    private func connectAppShell() {
        let shell = AppShellController.shared
        shell.openDrawer = { [weak self] tab, reveal in self?.presentFromShell(tab: tab, reveal: reveal) ?? false }
        shell.closeDrawer = { [weak self] in self?.forceCollapse() }
        shell.toggleDrawer = { [weak self] in
            guard let self else { return }
            // Links only: never brings a hidden island back.
            if self.state.isExpanded { self.forceCollapse() } else { self.presentFromShell(tab: nil, reveal: false) }
        }
        shell.postActivity = { [weak self] activity in self?.activities.post(activity) }
        shell.dismissActivity = { [weak self] id in self?.activities.dismiss(id: id) }
        shell.prepareForReset = { [weak self] in
            guard let self else { return }
            await self.finishWorkBeforeQuit(timeout: .seconds(5))
            self.tearDown()
        }

        AutomationRouter.shared.actions = AutomationActions(
            startTimer: { [weak self] minutes in self?.timer.startTimer(minutes: minutes) },
            startPomodoro: { [weak self] in self?.timer.startPomodoro() },
            pauseTimer: { [weak self] in self?.timer.toggle() },
            resetTimer: { [weak self] in self?.timer.reset() },
            startFocus: { [weak self] minutes in
                guard let self, !self.focus.isActive else { return }
                var settings = self.focus.settings
                if let minutes { settings.focusMinutes = minutes }
                self.focus.startSession(using: settings)
            },
            endFocus: { [weak self] in self?.focus.end() },
            openMeeting: { [weak self] id in self?.meetingAssistant.openNotesWindow(meetingID: id) },
            // Color Picker (Labs/ColorPicker): sparkv://color-picker picks at once.
            pickColor: { [weak self] in self?.colorPicker.pickColor() }
        )
        // Harmless, visible switches other tools may flip
        // (sparkv://feature/<name>?on=1). Never camera, microphone or recording.
        let router = AutomationRouter.shared
        let media = media, hud = hud, power = power, timer = timer
        let meetings = meetings, notifications = notifications, downloads = downloads
        router.register(AutomationFeature(name: "now-playing", title: "Now Playing beside the notch",
                                          get: { media.showsInClosedNotch }, set: { media.showsInClosedNotch = $0 }))
        router.register(AutomationFeature(name: "hud", title: "Volume & Brightness HUD",
                                          get: { hud.isEnabled }, set: { hud.isEnabled = $0 }))
        router.register(AutomationFeature(name: "battery", title: "Battery & AirPods",
                                          get: { power.isEnabled }, set: { power.isEnabled = $0 }))
        router.register(AutomationFeature(name: "timer-activity", title: "Timer live activity",
                                          get: { timer.isEnabled }, set: { timer.isEnabled = $0 }))
        router.register(AutomationFeature(name: "meetings", title: "Meeting live activities",
                                          get: { meetings.isEnabled }, set: { meetings.isEnabled = $0 }))
        // Mirrors other apps' banners onto the island: a link may only turn it off.
        router.register(AutomationFeature(name: "notifications", title: "Notifications", allowsTurningOn: false,
                                          get: { notifications.isEnabled }, set: { notifications.isEnabled = $0 }))
        router.register(AutomationFeature(name: "downloads", title: "Downloads watcher",
                                          get: { downloads.isEnabled }, set: { downloads.setEnabled($0) }))

        // Settings sections that read @EnvironmentObject get the drawer's objects.
        SparkVSettingsWindowController.shared.environment = { [weak self] view in
            guard let self else { return view }
            return AnyView(view
                .environmentObject(self.state)
                .environmentObject(self.media)
                .environmentObject(self.macros)
                .environmentObject(self.camera)
                .environmentObject(self.tray)
                .environmentObject(self.dictation)
                .environmentObject(self.flow)
                .environmentObject(self.clicky)
                .environmentObject(self.activities)
                .environmentObject(self.hud)
                .environmentObject(self.power)
                .environmentObject(self.timer)
                .environmentObject(self.meetings)
                .environmentObject(self.notifications)
                .environmentObject(self.meetingAssistant)
                .environmentObject(self.liveTranslation)
                .environmentObject(self.meetingLive)
                .environmentObject(self.converter)
                .environmentObject(self.spacesIngest)
                .environmentObject(self.uiAudit)
                .environmentObject(self.jobAgent)
                .environmentObject(self.screenRegion)
                .environmentObject(self.screenRecorder)
                .environmentObject(self.promptRefiner)
                .environmentObject(self.browserRecorder)
                .environmentObject(self.clipboard)
                .environmentObject(self.screenDistance)
                .environmentObject(self.focus)
                .environmentObject(self.universalSearch)
                .environmentObject(self.quickCapture)
                .environmentObject(self.screenshotClipboard)
                .environmentObject(self.replyDrafter)
                .environmentObject(self.fileDrop)
                .environmentObject(self.downloads)
                .environmentObject(self.colorPicker))
        }
    }

    /// Opens the drawer for the shell. The pointer is usually far from the
    /// notch then, so the drawer waits for it (10 s at most) instead of
    /// closing after the usual grace period. A hidden island (full screen,
    /// an excluded app, screen sharing, ⌃⌥H, Built-in Only with the lid
    /// closed) comes back for the moment only when `reveal` is set (the
    /// user clicked the menu bar icon or opened SparkV again), the way ⌃⌥H
    /// does; links never reveal it. False: nothing could be shown, and the
    /// shell falls back to Settings or reports "The island is hidden".
    @discardableResult
    private func presentFromShell(tab: NotchState.Tab?, reveal: Bool) -> Bool {
        guard !FaceUnlock.isUsingNotch else { return false }
        if visibility.isHidden {
            guard reveal else { return false }
            isRevealed = true
            applyVisibility()
            // Nothing to bring back (no display for it, another user).
            guard !visibility.isHidden else {
                isRevealed = false
                return false
            }
        }
        if let tab { state.select(tab) }
        collapseTask?.cancel()
        collapseTask = nil
        setExpanded(true)
        shellPinnedOpen = true
        shellPinEntered = false
        shellPinTask?.cancel()
        shellPinTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.shellPinnedOpen, !self.shellPinEntered else { return }
            self.shellPinnedOpen = false
            if !self.isPointerInHotZone(), !self.isInteractionInProgress { self.setExpanded(false) }
        }
        return true
    }

    /// Right-click on the closed island: the shell menu at the pointer. Only
    /// over the camera housing of a notched screen, where no menu bar item
    /// sits underneath (a global monitor can't swallow the click).
    private func showShellMenuIfOverIsland() {
        guard !state.isExpanded, !FaceUnlock.isUsingNotch,
              geometry?.hasNotch == true, visibility.isOnScreen, !visibility.ignoresHover,
              notchRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
        AppShellIslandMenu.popUp(at: NSEvent.mouseLocation)
    }

    // MARK: - System events

    private func observeSystemEvents() {
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { controller in
            controller.scheduleRelayout(reason: "screen parameters")
        }

        // Close the drawer (and with it the camera and media polling) whenever
        // the Mac is left unattended.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observe(name, on: workspace) {
                $0.forceCollapse()
                $0.placement.pauseWatching()
            }
        }
        // Fast user switching: nothing shows for the other user.
        observe(NSWorkspace.sessionDidResignActiveNotification, on: workspace) { $0.placement.setSessionActive(false) }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, on: workspace) { $0.placement.setSessionActive(true) }
        // Back from sleep, a user switch or the lock screen: re-place and re-show.
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observe(name, on: workspace) { $0.scheduleRecovery(reason: name.rawValue) }
        }
        // Undocumented but long-standing; fires for Lock Screen and Ctrl-Cmd-Q.
        observe(Notification.Name("com.apple.screenIsLocked"), on: DistributedNotificationCenter.default()) {
            $0.forceCollapse()
        }
        observe(Notification.Name("com.apple.screenIsUnlocked"), on: DistributedNotificationCenter.default()) {
            $0.scheduleRecovery(reason: "unlock")
        }
        // An open drawer shouldn't ride the Space animation.
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: workspace) { controller in
            if controller.state.isExpanded, !controller.isInteractionInProgress, !controller.state.isPinned { controller.forceCollapse() }
            // A Space can hide the menu bar (full screen, auto-hide) on a
            // display without a notch: the resting island follows it.
            controller.positionOverNotch()
            controller.selfCheck()
        }
        if let panel = window {
            observe(NSWindow.didChangeOcclusionStateNotification, on: .default, object: panel) { $0.selfCheck() }
        }

        observe(NSMenu.didBeginTrackingNotification, on: .default) { $0.isMenuTracking = true }
        observe(NSMenu.didEndTrackingNotification, on: .default) { $0.isMenuTracking = false }
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
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        object: AnyObject? = nil,
        _ handler: @escaping @MainActor @Sendable (NotchWindowController) -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    /// The pieces Island Placement needs from the rest of the island: what
    /// is on the band (HUD, voice) while it is hidden, and its callbacks.
    private func connectPlacement() {
        placement.onLayoutNeeded = { [weak self] in self?.positionOverNotch() }
        placement.onVisibilityNeeded = { [weak self] in self?.applyVisibility() }
        placement.onHotkey = { [weak self] in self?.handleHideHotkey() }
        // A band can pass through a hidden island: re-decide when one comes or goes.
        let bandChanges: [AnyPublisher<Void, Never>] = [
            activities.$current.map { $0?.kind.isLiveFeedback == true }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            dictation.$phase.map { $0 == .idle }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            clicky.$phase.map { $0 == .idle }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        placementBands = Publishers.MergeMany(bandChanges)
            .dropFirst(bandChanges.count)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.visibility.isHidden else { return }
                self.applyVisibility()
            }
        // The HUD-only fallback (no display for the island) follows the
        // HUD's own switches.
        hudObserver = Publishers.CombineLatest(hud.$isEnabled, hud.$replacesSystemHUD)
            .map { $0 && $1 }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.positionOverNotch() }
        if let window { placement.capture.register(window) }
        placement.start()
    }

    // MARK: - Hover tracking

    /// While collapsed the panel ignores mouse events, so an NSTrackingArea on
    /// it would never fire. Global + local monitors see every pointer move
    /// (global ones for events bound to other apps, local ones for our panel);
    /// mouse-move monitoring needs no Accessibility permission.
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let time = event.timestamp
            MainActor.assumeIsolated {
                self?.notePointer(time: time)
                self?.handlePointer()
            }
        }) {
            eventMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let time = event.timestamp
            MainActor.assumeIsolated {
                self?.notePointer(time: time)
                self?.handlePointer()
            }
            return event
        }) {
            eventMonitors.append(local)
        }

        // Two-finger swipes on the island (trackpad only). The global
        // monitor sees every scroll on the Mac, so it returns at once
        // unless a gesture starts on the closed island.
        if let globalScroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let scroll = IslandScrollSample(event)
            guard scroll.isPreciseGesture else { return }
            MainActor.assumeIsolated { _ = self?.handleScroll(scroll) }
        }) {
            eventMonitors.append(globalScroll)
        }
        if let localScroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let scroll = IslandScrollSample(event)
            guard scroll.isPreciseGesture else { return event }
            // A swipe that began on the drawer's top row is the island's.
            let consumed = MainActor.assumeIsolated { self?.handleScroll(scroll) ?? false }
            return consumed ? nil : event
        }) {
            eventMonitors.append(localScroll)
        }

        // A click anywhere else (another app, the desktop) closes the open
        // drawer. Global monitors never see clicks on SparkV's own windows.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClickOutside() }
        }) {
            eventMonitors.append(outside)
        }

        // Right-click on the closed island: version, Settings, About, Quit.
        if let rightClick = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.showShellMenuIfOverIsland() }
        }) {
            eventMonitors.append(rightClick)
        }

        // Local monitors only see events delivered to our own panel.
        if let pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pressBeganInPanel = true }
            return event
        }) {
            eventMonitors.append(pressMonitor)
        }

        // Open by Click or Press and Hold: the closed island takes the
        // button while the pointer is on it (see `updateClosedClickCapture`).
        if let islandPress = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            let down = event.type == .leftMouseDown
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handleClosedIslandPress(down: down, time: time) }
            return event
        }) {
            eventMonitors.append(islandPress)
        }
    }

    private func isPointerInHotZone() -> Bool {
        var hotZone = state.isExpanded ? interactiveFrame : collapsedHotZone
        // A floating pill or revealed Minimal island: up to the top edge.
        if let geometry { hotZone = geometry.reachingTopEdge(hotZone) }
        // NSRect.contains excludes maxY, and the pointer pins to the very top
        // pixel row when pushed against the edge, so grow the zone upwards.
        return hotZone.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    /// The closed island as drawn: the notch plus the compact wings beside
    /// the camera housing (always part of the island), plus the expanded
    /// band under it when the activity there leads somewhere (meeting,
    /// timer), so hovering it opens the drawer on that tab. A band that leads
    /// nowhere (volume, a notification) isn't, so reaching for content under
    /// it doesn't open the drawer. A resting island that draws nothing on a
    /// display without a notch wakes from a thin strip at the top edge.
    private var collapsedHotZone: NSRect {
        // Read on every pointer move: kept until something it depends on
        // changes (see `connectInteraction`).
        if let hotZoneCache { return hotZoneCache }
        let zone = computeCollapsedHotZone()
        hotZoneCache = zone
        return zone
    }

    private func computeCollapsedHotZone() -> NSRect {
        guard let layout = NotchActivityView.closedLayout(
            resting: state.collapsedSize, dictation: dictation, clicky: clicky, activities: activities, media: media
        ) else {
            if let geometry, state.surface.restsHidden, !state.surface.hasNotch, !state.isRestingRevealed {
                return geometry.revealStrip
            }
            return notchRect
        }
        let midX = notchRect.midX + layout.xOffset
        let bandLeadsSomewhere = layout.band != nil && dictation.phase == .idle && clicky.phase == .idle
            && activities.current?.opensTab != nil
        // The menu-bar row is island all the way across; the band below
        // only counts when it leads somewhere.
        let width = max(notchRect.width, layout.size.width)
        let height = bandLeadsSomewhere ? layout.size.height : notchRect.height
        return NSRect(x: midX - width / 2, y: notchRect.maxY - height, width: width, height: height)
    }

    /// The closed island's layout for the HUD's hit testing; nil while
    /// dictation or Clicky own the island.
    private var hudIslandLayout: IslandClosedLayout? {
        guard dictation.phase == .idle, clicky.phase == .idle else { return nil }
        return NotchActivityView.closedLayout(
            resting: state.collapsedSize, dictation: dictation, clicky: clicky, activities: activities, media: media
        )
    }

    /// The tab hovering the closed island opens: the expanded activity's,
    /// else the compact one's.
    private var hoverTab: NotchState.Tab? {
        guard dictation.phase == .idle, clicky.phase == .idle else { return nil }
        return activities.current?.opensTab ?? activities.compact?.opensTab
    }

    /// Full screen with the island showing: the top two rows reveal macOS's
    /// menu bar, so they never open the island.
    private func isOnFullScreenMenuBarRow(_ mouse: NSPoint) -> Bool {
        guard let geometry, placement.isFullScreen(placement.islandDisplayID) else { return false }
        return mouse.y >= geometry.screenTop - Self.fullScreenMenuBarRows
    }

    private func handlePointer() {
        // glance's onboarding/scan overlay sits above every window at the
        // notch; stay closed rather than drawing underneath it.
        if FaceUnlock.isUsingNotch {
            endThemeHover()
            if state.isExpanded { forceCollapse() }
            return
        }
        let mouse = NSEvent.mouseLocation
        placement.fullScreen.noteActivity()
        if placement.settings.displayMode.followsPointer, !state.isExpanded { followPointer(to: mouse) }
        // Hidden, shown only for a band, or an excluded app is in front: no
        // hover and no drops. Hidden for full screen, the top edge can
        // still bring it back.
        if !state.isExpanded, !visibility.isOnScreen || visibility.ignoresHover {
            // A ringing call passes through a hidden island (full screen):
            // its Accept and Decline still take clicks. Any other band lets go.
            if handleActivityBandPointer() { return }
            endThemeHover()
            setRestingRevealed(false)
            updateClosedClickCapture(onIsland: false)
            trackTopEdgeReveal(mouse)
            return
        }
        // A menu bar manager's bar is over the island: it stepped aside
        // (faded, click-through) until the bar is gone.
        if !state.isExpanded, interaction.isSteppingAside {
            endThemeHover()
            setRestingRevealed(false)
            updateClosedClickCapture(onIsland: false)
            // Leaving the island ends the step-aside (and its re-checks).
            let onIsland = isPointerInHotZone()
            if !onIsland { interaction.pointerLeftIsland() }
            pointerWasOnIsland = onIsland
            return
        }
        // After an explicit close, hover waits until the pointer has left.
        let hoverSuppressed = !state.isExpanded && closeLatch.suppressesHover(pointerOnIsland: isPointerInHotZone())
        // The color loupe is up: don't open the drawer over the pixels being
        // picked (or let a pointer theme move under them).
        if colorPicker.isPicking {
            endThemeHover()
            themeHover.setPointer(nil)
            return
        }
        // Over the File Drop shelf during a file drag: let the drop land there.
        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }
        // On the HUD beside (or under) the notch: it takes the pointer for
        // drag, scroll and click-to-mute instead of opening the drawer, and
        // makes the panel click-through again as soon as the pointer leaves
        // or the HUD goes. Hovering the camera housing still opens the drawer.
        if !state.isExpanded, hud.handleIslandPointer(notchRect: notchRect, layout: hudIslandLayout) {
            endThemeHover()
            return
        }
        // The band under the notch: its alert waits while the pointer is on
        // it, and a band with buttons takes clicks instead of opening the drawer.
        if handleActivityBandPointer() { return }
        // The teleprompter plays right under the notch: reading it must not
        // open the island. Pause it (or hide it) to use the island again.
        if !state.isExpanded, TeleprompterController.shared.blocksIslandHover {
            endThemeHover()
            return
        }
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
            if shellPinnedOpen { shellPinEntered = true }
            if keyboardPinned { keyboardPinEntered = true }
            revealEndTask?.cancel()
            revealEndTask = nil
            if !state.isExpanded {
                let wasRevealed = state.isRestingRevealed
                setRestingRevealed(true)
                noteReachedIsland()
                if isOnFullScreenMenuBarRow(mouse) || hoverSuppressed {
                    endThemeHover()
                } else if !IslandInteractionStore.current.openTrigger.opensOnHover {
                    // Click, Press and Hold or Swipe Down: hovering only
                    // shows that the island is ready.
                    setHoverPrimed(true)
                } else {
                    planHoverOpen(mouse, wasRevealed: wasRevealed)
                }
            }
        } else {
            endThemeHover()
            if !state.isExpanded {
                setRestingRevealed(false)
                scheduleRevealEnd()
            }
            // Opened from the menu bar icon or a link: wait for the pointer.
            // Opened from the keyboard: the same wait, with no time limit.
            let waitingForPointer = (shellPinnedOpen && !shellPinEntered)
                || (keyboardPinned && !keyboardPinEntered)
            if !(shellPinnedOpen && !shellPinEntered) { shellPinnedOpen = false }
            if state.isExpanded, collapseTask == nil, !waitingForPointer {
                // Kept open (Keep Drawer Open): no close timer at all.
                if !state.isPinned {
                    let delay = closeDelay()
                    collapseTask = Task { [weak self] in
                        try? await Task.sleep(for: delay)
                        // Stay open while a drag (e.g. a file leaving the tray) or a
                        // menu opened from the drawer is still in progress.
                        while !Task.isCancelled, self?.isInteractionInProgress == true {
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        guard !Task.isCancelled, let self else { return }
                        self.collapseTask = nil
                        // A menu can close with the pointer back over the drawer
                        // without any mouse-moved event reaching the monitors.
                        guard !self.isPointerInHotZone(), !self.state.isPinned else { return }
                        self.setExpanded(false)
                        self.scheduleRevealEnd()
                    }
                }
            }
        }
        let onClosedIsland = !state.isExpanded && isPointerInHotZone()
        if !onClosedIsland { setHoverPrimed(false) }
        if pointerWasOnIsland, !onClosedIsland { interaction.pointerLeftIsland() }
        pointerWasOnIsland = onClosedIsland
        updateClosedClickCapture(onIsland: onClosedIsland)
        updateEscape()
        updateClickThrough()
        updateThemePointer()
    }

    /// Hover intent: open now, or after a short wait once the pointer has
    /// settled (Settings › Island › Open after). Pushed against the top
    /// edge over the notch, Automatic opens at once; over a live-activity
    /// wing it waits longer and not while the pointer slides sideways
    /// toward a menu bar item.
    private func planHoverOpen(_ mouse: NSPoint, wasRevealed: Bool) {
        let zone = hoverZone(at: mouse)
        // A wait that began over a wing starts again (shorter) once the
        // pointer reaches the notch itself.
        if hoverDwellTask != nil, hoverDwellZone == .wing, zone == .housing {
            hoverDwellTask?.cancel()
            hoverDwellTask = nil
        }
        guard hoverDwellTask == nil else { return }
        var floor = 0
        // Full screen: a deliberate pause, so passing by on the way to the
        // menu bar doesn't open it.
        if placement.isFullScreen(placement.islandDisplayID) { floor = max(floor, Self.fullScreenHoverDwell.islandMilliseconds) }
        // Woken from the top-edge strip: show first, then open.
        if state.surface.restsHidden, !state.surface.hasNotch, !wasRevealed { floor = max(floor, Self.restingRevealDwell.islandMilliseconds) }
        let plan = IslandHoverIntent.plan(IslandHoverIntent.Inputs(
            zone: zone,
            atTopEdge: geometry.map { mouse.y >= $0.screenTop - 1 } ?? false,
            delay: IslandInteractionStore.current.openDelay,
            themeDwellMilliseconds: NotchThemeTiming.hoverDwell(for: NotchThemeSettings.shared.theme).islandMilliseconds,
            floorMilliseconds: floor
        ))
        switch plan {
        case .openNow:
            openFromHover()
        case .wait(let milliseconds):
            themeHover.isHovered = true
            hoverDwellZone = zone
            hoverDwellTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(milliseconds))
                // Then up to 1.5 s more for the pointer to settle.
                for _ in 0..<25 {
                    guard !Task.isCancelled, let self else { return }
                    guard !self.state.isExpanded, self.isPointerInHotZone(), !FaceUnlock.isUsingNotch,
                                  ShelfDragFilter.allowsHoverOpen(pressBeganInPanel: self.pressBeganInPanel),
                          !self.isOnFullScreenMenuBarRow(NSEvent.mouseLocation),
                          self.visibility.isOnScreen, !self.visibility.ignoresHover else {
                        self.hoverDwellTask = nil
                        self.themeHover.isHovered = false
                        return
                    }
                    if self.pointerHasSettled() {
                        self.hoverDwellTask = nil
                        self.openFromHover()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(60))
                }
                self?.hoverDwellTask = nil
            }
        }
    }

    /// Over the notch (or the resting pill), a wing beside it, or the band under it.
    private func hoverZone(at mouse: NSPoint) -> IslandHoverZone {
        let rest = geometry.map { $0.reachingTopEdge(notchRect) } ?? notchRect
        if rest.insetBy(dx: -2, dy: -2).contains(mouse) { return .housing }
        if mouse.y < notchRect.minY - 1 { return .band }
        return .wing
    }

    private func pointerHasSettled() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return IslandHoverIntent.settled(zone: hoverDwellZone ?? .housing,
                                         speed: pointerTracker.speed(at: now),
                                         horizontalSpeed: pointerTracker.horizontalSpeed(at: now))
    }

    /// Close After (at least 80 ms), and never before the drawer has been
    /// open 0.35 s.
    private func closeDelay() -> Duration {
        .milliseconds(IslandCloseTiming.delayMilliseconds(
            setting: IslandInteractionStore.current.closeDelay, openedAt: openedAt,
            now: ProcessInfo.processInfo.systemUptime))
    }

    /// Holds the band's clock while the pointer is on it; over a band with
    /// buttons, lets the panel take clicks there once `bandClickGate`
    /// allows. True when the pointer is on such a band (the caller stops:
    /// hovering it never opens the drawer). `moved`: a real mouse move.
    /// While the island is hidden, only a ringing call's band counts.
    @discardableResult
    private func handleActivityBandPointer(moved: Bool = true) -> Bool {
        let now = Date()
        bandClickRecheck?.cancel()
        bandClickRecheck = nil
        guard !state.isExpanded else {
            // setExpanded owns ignoresMouseEvents while the drawer is open.
            bandTakesClicks = false
            bandClickGate.update(bandID: nil, onBand: false, moved: moved, now: now)
            activities.setHovered(false)
            return false
        }
        let voiceIdle = dictation.phase == .idle && clicky.phase == .idle
        let allowed = visibility.isOnScreen && (!visibility.ignoresHover || liveActivities.calls.incoming != nil)
        let layout = NotchActivityView.closedLayout(
            resting: state.collapsedSize, dictation: dictation, clicky: clicky, activities: activities, media: media
        )
        let decision = allowed ? ActivityBandPointer.decide(
            mouse: NSEvent.mouseLocation,
            bandRect: layout.flatMap { ActivityBandPointer.bandRect(layout: $0, notchRect: notchRect) },
            isExpanded: false,
            bandOwnedByActivity: voiceIdle && activities.current != nil,
            isInteractive: activities.current?.isInteractive == true
        ) : .none
        activities.setHovered(decision != .none)
        let interactiveID = allowed && voiceIdle && activities.current?.isInteractive == true ? activities.current?.id : nil
        bandClickGate.update(bandID: interactiveID, onBand: decision == .interact, moved: moved, now: now)
        let takesClicks = decision == .interact && bandClickGate.allowsClicks(onBand: true, now: now)
        setActivityBandTakesClicks(takesClicks)
        if decision == .interact, !takesClicks, bandClickGate.movedOver {
            // Moved onto a band that just appeared: look once more when it has settled.
            bandClickRecheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ActivityBandClickGate.settle))
                guard !Task.isCancelled else { return }
                self?.handleActivityBandPointer(moved: false)
            }
        }
        guard decision == .interact else { return false }
        endThemeHover()
        return true
    }

    /// Turns clicks on the collapsed panel on or off for the band; only
    /// ever undoes what it did itself (the HUD may take the pointer too).
    private func setActivityBandTakesClicks(_ on: Bool) {
        guard on != bandTakesClicks else { return }
        bandTakesClicks = on
        guard !state.isExpanded else { return }
        window?.ignoresMouseEvents = !on
    }

    /// What entering the hot zone did before themes: open on the activity's tab.
    private func openFromHover() {
        if let tab = hoverTab {
            state.select(tab)
        } else if let tab = LayoutSettings.shared.openTab {
            // Customize Layout › Open Drawer On (Last Used keeps the tab).
            state.select(tab)
        }
        setExpanded(true)
    }

    private func endThemeHover() {
        hoverDwellTask?.cancel()
        hoverDwellTask = nil
        setHoverPrimed(false)
        if themeHover.isHovered, themePreviewTask == nil { themeHover.isHovered = false }
    }

    /// Pointer for Dewdrop and Magnetic Ripple, relative to the island's top
    /// center; nil when it is more than `maxOutset` away from the island.
    private func updateThemePointer() {
        guard NotchThemeSettings.shared.effectiveTheme.usesPointer else {
            themeHover.setPointer(nil)
            return
        }
        let zone = state.isExpanded ? interactiveFrame : collapsedHotZone
        let mouse = NSEvent.mouseLocation
        let reach = NotchThemeMetrics.maxOutset
        guard zone.insetBy(dx: -reach, dy: -reach).contains(mouse) else {
            themeHover.setPointer(nil)
            return
        }
        themeHover.setPointer(CGPoint(x: mouse.x - zone.midX, y: zone.maxY - mouse.y))
    }

    /// "Preview on my notch": the hovered look for a moment, without opening.
    private func previewTheme() {
        guard !state.isExpanded, NotchThemeSettings.shared.effectiveTheme != .plain else { return }
        themePreviewTask?.cancel()
        themeHover.isHovered = true
        themePreviewTask = Task { [weak self] in
            try? await Task.sleep(for: NotchThemeTiming.previewDuration)
            guard !Task.isCancelled, let self else { return }
            self.themePreviewTask = nil
            if self.hoverDwellTask == nil, !self.state.isExpanded { self.themeHover.isHovered = false }
        }
    }

    /// The panel minus the theme's glow margin: exactly the panel frame
    /// before themes existed. Hot zones and clicks use this.
    private var interactiveFrame: NSRect {
        guard let frame = window?.frame else { return .zero }
        let o = appliedThemeOutset
        return NSRect(x: frame.minX + o, y: frame.minY + o, width: frame.width - 2 * o, height: frame.height - o)
    }

    /// While the drawer is open, clicks in the glow margin fall through to
    /// whatever is below, as they did before the panel grew. With no margin
    /// (Plain, or a switch to Plain while the drawer is open) the open panel
    /// always takes clicks, exactly as before themes.
    private func updateClickThrough() {
        guard state.isExpanded else { return }
        let inside = appliedThemeOutset == 0
            || interactiveFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if window?.ignoresMouseEvents == inside { window?.ignoresMouseEvents = !inside }
    }

    private var isInteractionInProgress: Bool {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            pressBeganInPanel = false
        }
        return pressBeganInPanel || isMenuTracking || camera.isAwaitingPermission || fileDrop.holdsDrawerOpen
            || TrayQuickLook.shared.isVisible || fileDrop.isDraggingFiles
    }

    private func forceCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        setExpanded(false)
    }

    /// `animated: false` for keyboard-triggered opens (they appear at once).
    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard state.isExpanded != expanded else { return }
        var animated = animated
        // Opened by a hotkey, a link or another feature while hidden (full
        // screen, an excluded app, Hide for 1 Hour…): show it for as long as
        // the drawer is open, at once. Nothing can open it without a display
        // or for another user.
        var revealsForDrawer = false
        if expanded, visibility.isHidden || !visibility.isOnScreen {
            if visibility.reasons.contains(where: \.isHard) || geometry == nil || hudFallbackDisplayID != nil {
                AppLog.log("Island: not opening, \(visibility.reasons.map(\.rawValue).joined(separator: ", "))")
                return
            }
            drawerRevealed = true
            revealsForDrawer = true
            nextVisibilityInstant = true
            animated = false
        }

        // A hotkey can open the drawer with the pointer on the HUD: the
        // drawer's top row is the drawer's again.
        if expanded { hud.interaction.end() }
        window?.ignoresMouseEvents = !expanded
        // Queued alerts wait while the drawer covers the island.
        activities.setDrawerOpen(expanded)
        var transaction = Transaction(animation: NotchMetrics.hoverAnimation)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            state.isExpanded = expanded
            if !expanded {
                state.didCollapse()
            }
        }
        if !expanded {
            shellPinnedOpen = false
            keyboardPinned = false
            keyboardPinEntered = false
            shellPinTask?.cancel()
            shellPinTask = nil
            themeHover.isHovered = false
            hoverDwellTask?.cancel()
            hoverDwellTask = nil
        } else {
            updateClickThrough()
        }
        updateLevel()
        noteExpandedForInteraction(expanded)

        media.setActive(expanded)
        if expanded {
            NotificationCenter.default.post(name: .sparkVIslandDidExpand, object: nil)
            macros.refreshLibraryIfStale()
            watchFaceUnlock()
        } else {
            faceUnlockWatch?.cancel()
            faceUnlockWatch = nil
            // Never leave the camera running behind a closed drawer (the
            // large mirror, while open, keeps it until its × closes it).
            camera.releaseDrawerPreview()
        }
        if revealsForDrawer {
            applyVisibility()
        } else if !expanded, drawerRevealed {
            // The drawer that brought it back closed: hidden again.
            drawerRevealed = false
            applyVisibility()
        }
    }

    /// glance exposes no notification for its overlay, so poll the cheap
    /// `FaceUnlock.isUsingNotch` flag twice a second while the drawer is open.
    private func watchFaceUnlock() {
        faceUnlockWatch?.cancel()
        faceUnlockWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: NotchMetrics.faceUnlockPollInterval)
                guard !Task.isCancelled, let self, self.state.isExpanded else { return }
                if FaceUnlock.isUsingNotch {
                    AppLog.log("Notch: collapsing for Face Unlock overlay")
                    self.forceCollapse()
                    return
                }
            }
        }
    }

    // MARK: - Island interaction (Labs/IslandInteraction)

    /// Open by, delays, gestures, Esc, click outside, Keep Open, motion,
    /// size, menu bar room, menu bar managers and other notch apps.
    private func connectInteraction() {
        interaction.onToggleHotkey = { [weak self] in self?.toggleFromKeyboard() }
        // Settings › Accessibility › Keyboard Shortcuts: one per tab.
        let shortcuts = DrawerShortcutStore.shared
        shortcuts.onTabShortcut = { [weak self] tab in self?.toggleFromKeyboard(tab: tab) }
        shortcuts.start()
        interaction.onEscape = { [weak self] in self?.closeFromEscape() }
        interaction.onCloseRequest = { [weak self] in self?.closeOnRequest() }
        interaction.onPinRequest = { [weak self] pinned in self?.setPinned(pinned) }
        interaction.isPinned = { [weak self] in self?.state.isPinned ?? false }
        interaction.onStepAsideChanged = { [weak self] stepping in self?.stepAside(stepping) }
        interaction.onWingClearanceChanged = { [weak self] _ in self?.wingRoomChanged() }
        interaction.postNotice = { [weak self] activity in self?.activities.post(activity) }
        let hud = hud, media = media, notifications = notifications, dictation = dictation
        interaction.actions = IslandCoexistenceActions(
            systemHUDReplaced: { hud.isEnabled && hud.replacesSystemHUD },
            setSystemHUDReplaced: { on in
                if on { hud.isEnabled = true }
                hud.replacesSystemHUD = on
            },
            nowPlayingWings: { media.showsInClosedNotch },
            setNowPlayingWings: { media.showsInClosedNotch = $0 },
            notificationBanners: { notifications.isEnabled },
            setNotificationBanners: { notifications.isEnabled = $0 },
            dictationUsesFn: { dictation.hotkey == .fn },
            useRightOptionForDictation: { dictation.hotkey = .rightOption },
            hideIsland: { [weak self] in
                guard let self else { return }
                self.forceCollapse()
                self.placement.hide()
                self.applyVisibility()
            }
        )
        // Esc while a field in the drawer has the keyboard.
        if let window {
            observe(NotchPanel.escapeNotification, on: .default, object: window) { $0.closeFromEscape() }
            // ← → / Tab / ⌘1–⌘9 with no field focused (NotchPanel.keyDown).
            let navigate = NotificationCenter.default.addObserver(
                forName: NotchPanel.navigateNotification, object: window, queue: .main
            ) { [weak self] note in
                let move = note.userInfo?["move"] as? Int
                let index = note.userInfo?["index"] as? Int
                MainActor.assumeIsolated { self?.navigateTabs(move: move, index: index) }
            }
            observers.append((center: NotificationCenter.default, token: navigate))
            // Key or not decides who handles Esc (see `updateEscape`).
            observe(NSWindow.didBecomeKeyNotification, on: .default, object: window) { $0.updateEscape() }
            observe(NSWindow.didResignKeyNotification, on: .default, object: window) { $0.updateEscape() }
        }
        // The closed island's hot zone and wings change with these.
        let sources: [ObservableObjectPublisher] = [
            activities.objectWillChange, media.objectWillChange, dictation.objectWillChange,
            clicky.objectWillChange, state.objectWillChange,
        ]
        hotZoneObservers = sources.map { publisher in
            publisher.sink { [weak self] _ in
                guard let self else { return }
                self.hotZoneCache = nil
                self.scheduleWingsCheck()
            }
        }
        interactionObserver = IslandInteractionSettings.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value is stored.
            DispatchQueue.main.async { self?.interactionSettingsChanged() }
        }
        interaction.start()
    }

    private func interactionSettingsChanged() {
        let now = IslandInteractionStore.current
        let before = lastInteraction
        lastInteraction = now
        if now.drawerSize != before.drawerSize || now.closedWidth != before.closedWidth {
            positionOverNotch()
        }
        if now.openTrigger != before.openTrigger {
            endThemeHover()
            updateClosedClickCapture(onIsland: false)
        }
        if now.motionStyle != before.motionStyle || now.motionSpeed != before.motionSpeed {
            AppLog.log("Island: motion \(now.motionStyle.rawValue), speed \(now.motionSpeed.rawValue)")
        }
    }

    /// Mouse monitors: pointer speed for hover intent; a drag cancels Press and Hold.
    private func notePointer(time: TimeInterval) {
        let p = NSEvent.mouseLocation
        pointerTracker.note(x: p.x, y: p.y, time: time)
        if pressTracker.isPressing, !pressTracker.moved(x: p.x, y: p.y) {
            pressTask?.cancel()
            pressTask = nil
        }
    }

    /// The pointer just reached the closed island: with a menu bar manager
    /// running, one look at whether its bar is over the island.
    private func noteReachedIsland() {
        guard !pointerWasOnIsland else { return }
        interaction.pointerReachedIsland(zone: collapsedHotZone)
    }

    /// Click, Press and Hold, Swipe Down: the resting island grows a little
    /// (and a notch theme shows its hover look) while the pointer is on it.
    private func setHoverPrimed(_ primed: Bool) {
        let value = primed && !state.isExpanded
        if state.isHoverPrimed != value {
            withAnimation(SparkVMotion.respecting(SparkVMotion.snappy)) { state.isHoverPrimed = value }
        }
        if value, NotchThemeSettings.shared.theme != .plain, !themeHover.isHovered { themeHover.isHovered = true }
    }

    /// The closed island takes the button only while the pointer is on it,
    /// and only for Click or Press and Hold; everywhere else (and with
    /// Hover) it stays click-through, so the menu bar works as before.
    private func updateClosedClickCapture(onIsland: Bool) {
        let want = onIsland && !state.isExpanded && IslandInteractionStore.current.openTrigger.takesClicks
            && visibility.isOnScreen && !visibility.ignoresHover && !interaction.isSteppingAside && !FaceUnlock.isUsingNotch
        guard want != clickCaptureActive else {
            // Another feature (the HUD, an activity band) may have made the
            // panel click-through meanwhile: while capture is wanted, the
            // closed island takes the button again on every pass.
            if want, !state.isExpanded, window?.ignoresMouseEvents == true { window?.ignoresMouseEvents = false }
            return
        }
        clickCaptureActive = want
        if !state.isExpanded { window?.ignoresMouseEvents = !want }
        if !want {
            pressTask?.cancel()
            pressTask = nil
            pressTracker.up()
        }
    }

    /// Esc is held only while the pointer is on the open drawer, not while
    /// dictation or Clicky own it (re-checked when they change), and not
    /// while the drawer's panel is key: then the responder chain has Esc,
    /// so the drawer's own Esc handlers (Flow, the media note field, the
    /// Script editor's Cancel) run first and `NotchPanel.cancelOperation`
    /// closes the drawer otherwise.
    private func updateEscape() {
        // Another SparkV window that is key (the Tray's key panel, Quick Look,
        // a sheet) already gets Esc through its own responder chain, so the
        // global Esc must stay unarmed or it would close the whole drawer.
        let otherKey = NSApp.keyWindow.map { $0 !== window } ?? false
        let armed = state.isExpanded && window?.isKeyWindow != true && !otherKey
            && !TrayKeyboard.shared.hasFocus && !TrayQuickLook.shared.isVisible
            && dictation.phase == .idle && clicky.phase == .idle && isPointerInHotZone()
        interaction.setEscapeArmed(armed)
    }

    private func handleClosedIslandPress(down: Bool, time: TimeInterval) {
        guard !state.isExpanded, clickCaptureActive else {
            if !down { pressTracker.up() }
            return
        }
        let trigger = IslandInteractionStore.current.openTrigger
        guard down else {
            pressTracker.up()
            pressTask?.cancel()
            pressTask = nil
            return
        }
        if trigger.opensOnClick {
            openFromGesture()
        } else if trigger.opensOnPress {
            let p = NSEvent.mouseLocation
            pressTracker.down(x: p.x, y: p.y, time: time)
            pressTask?.cancel()
            pressTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(IslandPressTracker.holdSeconds * 1000)))
                guard !Task.isCancelled, let self else { return }
                self.pressTask = nil
                guard self.pressTracker.isPressing, NSEvent.pressedMouseButtons & 1 == 1,
                      !self.state.isExpanded, self.isPointerInHotZone() else { return }
                self.pressTracker.up()
                self.openFromGesture()
            }
        }
    }

    /// Opened by a click, a hold or a swipe: one gentle tap on a Force
    /// Touch trackpad (never for hover).
    private func openFromGesture() {
        guard !state.isExpanded, !FaceUnlock.isUsingNotch else { return }
        endThemeHover()
        SparkVHaptics.perform(.alignment)
        openFromHover()
    }

    /// Two-finger swipes: down on the closed island opens it, up on the
    /// open drawer's top row closes it. True when the island used the
    /// event (only then is it kept from the drawer's content).
    private func handleScroll(_ scroll: IslandScrollSample) -> Bool {
        if scroll.phase == .changed, !swipeTracker.isTracking { return false }
        let settings = IslandInteractionStore.current
        var inZone = false
        if scroll.phase == .began {
            if state.isExpanded {
                inZone = settings.swipeGestures && headerBand.contains(NSEvent.mouseLocation)
            } else {
                inZone = (settings.swipeGestures || settings.openTrigger == .swipeDown)
                    && visibility.isOnScreen && !visibility.ignoresHover && !interaction.isSteppingAside
                    && !FaceUnlock.isUsingNotch && isPointerInHotZone()
            }
        }
        let wasExpanded = state.isExpanded
        switch swipeTracker.feed(phase: scroll.phase, deltaY: scroll.deltaY, inverted: scroll.inverted, inZone: inZone) {
        case .down where !wasExpanded:
            openFromGesture()
        case .up where wasExpanded:
            SparkVHaptics.perform(.alignment)
            closeOnRequest()
        default:
            break
        }
        return wasExpanded && swipeTracker.isTracking
    }

    /// The open drawer's top row (the header band beside the camera).
    private var headerBand: NSRect {
        let frame = interactiveFrame
        let height = state.collapsedSize.height + (geometry?.topInset ?? 0) + 4
        return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    private func handleClickOutside() {
        // A press in another app can't have begun in the drawer.
        pressBeganInPanel = false
        guard state.isExpanded, IslandInteractionStore.current.clickOutsideCloses, !state.isPinned,
              !isInteractionInProgress else { return }
        guard !interactiveFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
        forceCollapse()
    }

    /// ⌃⌥O (opt-in, remappable) or a tab shortcut: opens at once
    /// (keyboard-triggered, no animation in) and takes the keyboard, or
    /// closes. A tab shortcut while the drawer shows another tab switches.
    private func toggleFromKeyboard(tab: NotchState.Tab? = nil) {
        guard !FaceUnlock.isUsingNotch else { return }
        if state.isExpanded {
            if let tab, !isShowing(tab) {
                selectInstantly(tab)
                takeKeyboard()
                return
            }
            closeOnRequest()
        } else {
            endThemeHover()
            if let tab { selectInstantly(tab) }
            setExpanded(true, animated: false)
            takeKeyboard()
        }
    }

    private func isShowing(_ tab: NotchState.Tab) -> Bool {
        state.tab == tab || (tab == .agents && NotchState.Tab.agentTabs.contains(state.tab))
    }

    /// Keyboard-triggered tab change: no slide.
    private func selectInstantly(_ tab: NotchState.Tab) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { state.select(tab) }
    }

    /// The drawer was opened from the keyboard: its panel becomes key (it
    /// is non-activating, so the app you were in stays in front) so the
    /// arrow keys, Tab and Esc reach it, and VoiceOver hears where it is.
    private func takeKeyboard() {
        guard state.isExpanded, let window else { return }
        keyboardSession = true
        if !keyboardPinned {
            keyboardPinned = true
            keyboardPinEntered = isPointerInHotZone()
        }
        collapseTask?.cancel()
        collapseTask = nil
        SparkVAssistive.shared.refresh()
        window.makeKey()
        updateEscape()
        SparkVAssistive.announce("SparkV drawer, \(DrawerShortcutStore.title(of: state.tab))")
    }

    /// ← → / Tab / ⌘1–⌘9 in an open drawer: the next, previous or n-th
    /// header tab, instantly.
    private func navigateTabs(move: Int?, index: Int?) {
        guard state.isExpanded else { return }
        let tabs = DrawerShortcutStore.headerTabs()
        guard !tabs.isEmpty else { return }
        let target: NotchState.Tab
        if let index {
            guard index < tabs.count else { return }
            target = tabs[index]
        } else if let move {
            let current = tabs.firstIndex(of: state.tab)
                ?? (NotchState.Tab.agentTabs.contains(state.tab) ? tabs.firstIndex(of: .agents) : nil)
                ?? 0
            target = tabs[(current + move % tabs.count + tabs.count) % tabs.count]
        } else {
            return
        }
        guard target != state.tab else { return }
        selectInstantly(target)
        SparkVAssistive.announce(DrawerShortcutStore.title(of: target))
    }

    /// Closing a drawer that took the keyboard: if SparkV never became the
    /// active app, key status moves to the Tray's invisible key panel and
    /// only that panel is ordered out, so the front app types again. The
    /// notch panel itself is never re-ordered (no occlusion change, no
    /// flicker, lyrics and bars keep running).
    private func releaseKeyboard() {
        guard let window, window.isKeyWindow, window.isVisible, !NSApp.isActive else { return }
        let keys = TrayKeyboard.shared.makeKeyPanel()
        keys.setFrameOrigin(NSPoint(x: window.frame.midX, y: window.frame.maxY - TrayKeyPanel.size.height))
        keys.orderFrontRegardless()
        keys.makeKey()
        keys.makeFirstResponder(nil)
        keys.orderOut(nil)
    }

    private func closeFromEscape() {
        guard state.isExpanded, IslandInteractionStore.current.escapeCloses || keyboardSession else { return }
        closeOnRequest()
    }

    /// Esc, a click on the notch, a swipe up, ⌃⌥O: closes even a pinned drawer.
    private func closeOnRequest() {
        guard state.isExpanded else { return }
        closeLatch.closedOnRequest()
        state.isPinned = false
        forceCollapse()
    }

    /// Keep Drawer Open (gear menu, the Keep Open tile, its bar).
    private func setPinned(_ pinned: Bool) {
        guard pinned != state.isPinned else { return }
        if pinned, !state.isExpanded {
            setExpanded(true, animated: false)
            guard state.isExpanded else { return }
        }
        state.isPinned = pinned && state.isExpanded
        collapseTask?.cancel()
        collapseTask = nil
        SparkVHaptics.perform(.alignment)
        AppLog.log("Island: drawer \(pinned ? "kept open" : "free to close")")
        // Let go with the pointer elsewhere: the usual close timer starts.
        if !pinned { handlePointer() }
    }

    /// A menu bar manager's bar is over the closed island: fade it out
    /// (it stays in place, click-through) until the bar is gone.
    private func stepAside(_ stepping: Bool) {
        guard let panel = window else { return }
        if stepping {
            endThemeHover()
            setRestingRevealed(false)
            updateClosedClickCapture(onIsland: false)
            guard !state.isExpanded else { return }
        }
        guard visibility.isOnScreen, isPanelShown else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SparkVMotion.Duration.hover
            panel.animator().alphaValue = stepping ? 0 : 1
        }
    }

    /// The room beside the housing changed: the wings lay out again.
    private func wingRoomChanged() {
        hotZoneCache = nil
        state.wingClearanceRevision &+= 1
        for mirror in mirrors.values { mirror.state.wingClearanceRevision &+= 1 }
    }

    /// Wings just appeared: menu bar items may have moved since the last look.
    private func scheduleWingsCheck() {
        guard !wingsCheckScheduled else { return }
        wingsCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wingsCheckScheduled = false
            let visible = !self.state.isExpanded && NotchActivityView.wingsSource(activities: self.activities, media: self.media) != nil
            if visible, !self.wingsVisible { self.interaction.wingsBecameVisible() }
            self.wingsVisible = visible
            // Dictation or Clicky may have started or stopped owning Esc.
            if self.state.isExpanded { self.updateEscape() }
        }
    }

    /// Open and close bookkeeping: minimum open time, click capture, the
    /// hover cue, Esc, Keep Open and the app that had the keyboard.
    private func noteExpandedForInteraction(_ expanded: Bool) {
        pressTask?.cancel()
        pressTask = nil
        pressTracker.up()
        swipeTracker.reset()
        clickCaptureActive = false
        if expanded {
            openedAt = ProcessInfo.processInfo.systemUptime
            closeLatch.reset()
            interaction.resetEscapeFailure()
            if state.isHoverPrimed { state.isHoverPrimed = false }
            // Opened by the keyboard while stepping aside: it shows.
            if interaction.isSteppingAside, let panel = window, panel.alphaValue < 1 { panel.alphaValue = 1 }
            interaction.rememberFrontApp()
        } else {
            openedAt = nil
            if state.isPinned { state.isPinned = false }
            interaction.setEscapeArmed(false)
            let tookKeyboard = keyboardSession
            keyboardSession = false
            interaction.restoreFrontApp(islandPanel: window, force: tookKeyboard)
            if tookKeyboard { releaseKeyboard() }
        }
    }

    // MARK: - Island root view

    /// The island's SwiftUI root with every controller injected (the live
    /// island and the All Displays mirrors share it).
    private func islandRoot(state: NotchState) -> some View {
        // Rebuilt when the look changes (gear menu › Appearance).
        NotchNookLayoutView()
            .followsAppearance()
            .environmentObject(state)
            .environmentObject(media)
            .environmentObject(macros)
            .environmentObject(camera)
            .environmentObject(tray)
            .environmentObject(dictation)
            .environmentObject(flow)
            .environmentObject(clicky)
            .environmentObject(activities)
            .environmentObject(hud)
            .environmentObject(power)
            .environmentObject(timer)
            .environmentObject(meetings)
            .environmentObject(notifications)
            .environmentObject(meetingAssistant)
            .environmentObject(liveTranslation)
            .environmentObject(meetingLive)
            .environmentObject(converter)
            .environmentObject(spacesIngest)
            .environmentObject(uiAudit)
            .environmentObject(jobAgent)
            .environmentObject(screenRegion)
            .environmentObject(screenRecorder)
            .environmentObject(promptRefiner)
            .environmentObject(browserRecorder)
            .environmentObject(clipboard)
            .environmentObject(screenDistance)
            .environmentObject(focus)
            .environmentObject(universalSearch)
            .environmentObject(quickCapture)
            .environmentObject(screenshotClipboard)
            .environmentObject(replyDrafter)
            .environmentObject(fileDrop)
            .environmentObject(downloads)
            .environmentObject(colorPicker)
    }
}

/// A click-through copy of the closed island on another display (All
/// Displays). It never opens: reaching it moves the live island there.
@MainActor
private final class IslandMirror {
    let panel: NotchPanel
    let state: NotchState
    /// The display this mirror draws for right now (HUDPlus mirror filter).
    let displayBox: MirrorDisplayBox
    var notchRect: NSRect = .zero
    var hasNotch = true
    /// Shown at least once (later appearances fade in).
    var hasShown = false

    init(panel: NotchPanel, state: NotchState, displayBox: MirrorDisplayBox) {
        self.panel = panel
        self.state = state
        self.displayBox = displayBox
    }
}

/// The display a pooled All Displays mirror currently draws for, so the HUD
/// aimed at another display stays off it (`\.hudIslandDisplayID`).
@MainActor
private final class MirrorDisplayBox: ObservableObject {
    @Published var displayID: CGDirectDisplayID?
}

private struct MirrorHUDScope<Content: View>: View {
    @ObservedObject var box: MirrorDisplayBox
    let content: Content

    var body: some View { content.environment(\.hudIslandDisplayID, box.displayID) }
}
