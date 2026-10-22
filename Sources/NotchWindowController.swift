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
    private var smartMoments: SmartMomentsWiring?

    private var eventMonitors: [Any] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var collapseTask: Task<Void, Never>?
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
        focus = FocusController(
            activities: activities,
            timer: timer,
            sources: .live(tray: tray, meetingAssistant: meetingAssistant, notifications: notifications)
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
                guard let self, self.state.isExpanded, dropped, !keepOpen, !self.isPointerInHotZone() else { return }
                self.forceCollapse()
            }
        }
        observers.append((NotificationCenter.default, dragEnd))
        FlowCanvasWindowController.shared.onSendToTray = { [tray] urls in urls.forEach(tray.addFile) }
        FlowCanvasWindowController.shared.onSendToSpace = { title, markdown, url in
            _ = SpaceStore.shared.addManual(title: title, text: markdown, url: url, spaceID: nil, kind: .note)
        }

        // Rebuilt when the look changes (gear menu › Appearance).
        let root = NotchNookLayoutView()
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
        let hostingView = NotchHostingView(rootView: root)
        // The window frame is owned by this controller, not by SwiftUI's ideal size.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: NotchMetrics.panelSize)
        panel.contentView = hostingView

        positionOverNotch()
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
        installMouseMonitors()
        observeSystemEvents()

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
        dictation.start()
        clicky.start()
        [hud.start, power.start, timer.start, meetings.start, notifications.start].forEach { $0() }
        // After the timer, so a running session re-attaches to its countdown.
        focus.start()
        startModes()
        meetingAssistant.start()
        meetingIntel.start()
        spacesIngest.start()
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
        FanController.shared.start()
        FanController.shared.connect(activities: activities, opensTab: .fans)
        // After the meeting assistant, downloads and clipboard started: it
        // chains onto their events.
        smartMoments?.start()
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
        window?.orderFrontRegardless()
    }

    func tearDown() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        collapseTask?.cancel()
        hoverDwellTask?.cancel()
        themePreviewTask?.cancel()
        faceUnlockWatch?.cancel()
        faceUnlockWatch = nil
        camera.stop()
        clicky.shutdown()
        [hud.stop, power.stop, timer.stop, meetings.stop, notifications.stop].forEach { $0() }
        liveTranslation.stop()
        meetingIntel.stop()
        meetingAssistant.shutdown()
        [uiAudit.stop, jobAgent.stop, screenRegion.stop, screenRecorder.shutdown, promptRefiner.stop, browserRecorder.stop, clipboard.stop, replyDrafter.stop, fileDrop.stop].forEach { $0() }
        universalSearch.stop()
        spacesIngest.stop()
        screenDistance.stop()
        quickCapture.stop()
        screenshotClipboard.stop()
        smartMoments?.stop()
        downloads.stop()
        focus.stop()
        // Every fan back to Auto before SparkV quits.
        FanController.shared.stop()
        CloudSyncController.shared.stop()
        dictation.shutdown()
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

    /// The built-in notched display when present, otherwise the primary screen.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func positionOverNotch() {
        guard let panel = window, let screen = Self.targetScreen() else { return }
        let screenFrame = screen.frame

        // On a notched display the safe-area inset is the notch height. In
        // clamshell mode or on an external display there is no notch, so the
        // island rests inside the menu bar instead of hanging below it.
        let restingHeight: CGFloat
        if screen.safeAreaInsets.top > 0 {
            restingHeight = screen.safeAreaInsets.top
        } else {
            let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
            restingHeight = menuBarHeight > 0 ? menuBarHeight : 24
        }
        let collapsed = CGSize(width: NotchMetrics.collapsedSize.width, height: restingHeight)
        state.collapsedSize = collapsed

        notchRect = NSRect(
            x: screenFrame.midX - collapsed.width / 2,
            y: screenFrame.maxY - collapsed.height,
            width: collapsed.width,
            height: collapsed.height
        )

        // Sized to the current tab so a shorter drawer never leaves a
        // transparent strip below it that swallows clicks. A notch theme adds
        // a glow margin on the left, right and bottom (0 for Plain); the top
        // stays at the screen edge, so the island does not move.
        let outset = max(
            NotchThemeLayout.outset(for: NotchThemeSettings.shared.theme),
            AmbientLightController.shared.notchOutset
        )
        appliedThemeOutset = outset
        let expanded = NotchMetrics.panelSize(for: state.tab)
        let panelFrame = NSRect(
            x: screenFrame.midX - expanded.width / 2 - outset,
            y: screenFrame.maxY - expanded.height - outset,
            width: expanded.width + 2 * outset,
            height: expanded.height + outset
        )
        panel.setFrame(panelFrame, display: true)
        if state.isExpanded { updateClickThrough() }
    }

    /// A taller tab grows the panel at once, so the drawer can spring into
    /// it; a shorter one shrinks the panel only after the drawer's height
    /// animation has played, so its bottom isn't cut off mid-spring.
    private func resizeForTab() {
        tabResizeTask?.cancel()
        tabResizeTask = nil
        let target = NotchMetrics.panelSize(for: state.tab).height + appliedThemeOutset
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

    // MARK: - System events

    private func observeSystemEvents() {
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { controller in
            controller.positionOverNotch()
        }

        // Close the drawer (and with it the camera and media polling) whenever
        // the Mac is left unattended.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observe(name, on: workspace) { $0.forceCollapse() }
        }
        // Undocumented but long-standing; fires for Lock Screen and Ctrl-Cmd-Q.
        observe(Notification.Name("com.apple.screenIsLocked"), on: DistributedNotificationCenter.default()) {
            $0.forceCollapse()
        }

        observe(NSMenu.didBeginTrackingNotification, on: .default) { $0.isMenuTracking = true }
        observe(NSMenu.didEndTrackingNotification, on: .default) { $0.isMenuTracking = false }
        observe(.notchThemePreviewRequested, on: .default) { $0.previewTheme() }
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        _ handler: @escaping @MainActor @Sendable (NotchWindowController) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    // MARK: - Hover tracking

    /// While collapsed the panel ignores mouse events, so an NSTrackingArea on
    /// it would never fire. Global + local monitors see every pointer move
    /// (global ones for events bound to other apps, local ones for our panel);
    /// mouse-move monitoring needs no Accessibility permission.
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointer() }
        }) {
            eventMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer() }
            return event
        }) {
            eventMonitors.append(local)
        }

        // Local monitors only see events delivered to our own panel.
        if let pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pressBeganInPanel = true }
            return event
        }) {
            eventMonitors.append(pressMonitor)
        }
    }

    private func isPointerInHotZone() -> Bool {
        let hotZone = state.isExpanded ? interactiveFrame : collapsedHotZone
        // NSRect.contains excludes maxY, and the pointer pins to the very top
        // pixel row when pushed against the edge, so grow the zone upwards.
        return hotZone.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    /// The closed island as drawn: the notch plus the compact wings beside
    /// the camera housing (always part of the island), plus the expanded
    /// band under it when the activity there leads somewhere (meeting,
    /// timer), so hovering it opens the drawer on that tab. A band that leads
    /// nowhere (volume, a notification) isn't, so reaching for content under
    /// it doesn't open the drawer.
    private var collapsedHotZone: NSRect {
        guard let layout = NotchActivityView.closedLayout(
            resting: state.collapsedSize, dictation: dictation, clicky: clicky, activities: activities, media: media
        ) else { return notchRect }
        let midX = notchRect.midX + layout.xOffset
        let bandLeadsSomewhere = layout.band != nil && dictation.phase == .idle && clicky.phase == .idle
            && activities.current?.opensTab != nil
        // The menu-bar row is island all the way across; the band below
        // only counts when it leads somewhere.
        let width = max(notchRect.width, layout.size.width)
        let height = bandLeadsSomewhere ? layout.size.height : notchRect.height
        return NSRect(x: midX - width / 2, y: notchRect.maxY - height, width: width, height: height)
    }

    /// The tab hovering the closed island opens: the expanded activity's,
    /// else the compact one's.
    private var hoverTab: NotchState.Tab? {
        guard dictation.phase == .idle, clicky.phase == .idle else { return nil }
        return activities.current?.opensTab ?? activities.compact?.opensTab
    }

    private func handlePointer() {
        // glance's onboarding/scan overlay sits above every window at the
        // notch; stay closed rather than drawing underneath it.
        if FaceUnlock.isUsingNotch {
            endThemeHover()
            if state.isExpanded { forceCollapse() }
            return
        }
        // Over the File Drop shelf during a file drag: let the drop land there.
        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }
        if isPointerInHotZone() {
            collapseTask?.cancel()
            collapseTask = nil
            if !state.isExpanded {
                let dwell = NotchThemeTiming.hoverDwell(for: NotchThemeSettings.shared.theme)
                if dwell == .zero {
                    openFromHover()
                } else if hoverDwellTask == nil {
                    themeHover.isHovered = true
                    hoverDwellTask = Task { [weak self] in
                        try? await Task.sleep(for: dwell)
                        guard !Task.isCancelled, let self else { return }
                        self.hoverDwellTask = nil
                        guard !self.state.isExpanded, self.isPointerInHotZone(), !FaceUnlock.isUsingNotch else {
                            self.themeHover.isHovered = false
                            return
                        }
                        self.openFromHover()
                    }
                }
            }
        } else {
            endThemeHover()
            if state.isExpanded, collapseTask == nil {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: NotchMetrics.collapseDelay)
                    // Stay open while a drag (e.g. a file leaving the tray) or a
                    // menu opened from the drawer is still in progress.
                    while !Task.isCancelled, self?.isInteractionInProgress == true {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    guard !Task.isCancelled, let self else { return }
                    self.collapseTask = nil
                    // A menu can close with the pointer back over the drawer
                    // without any mouse-moved event reaching the monitors.
                    guard !self.isPointerInHotZone() else { return }
                    self.setExpanded(false)
                }
            }
        }
        updateClickThrough()
        updateThemePointer()
    }

    /// What entering the hot zone did before themes: open on the activity's tab.
    private func openFromHover() {
        if let tab = hoverTab {
            state.select(tab)
        }
        setExpanded(true)
    }

    private func endThemeHover() {
        hoverDwellTask?.cancel()
        hoverDwellTask = nil
        if themeHover.isHovered, themePreviewTask == nil { themeHover.isHovered = false }
    }

    /// Pointer for Dewdrop and Magnetic Ripple, relative to the island's top
    /// center; nil when it is more than `maxOutset` away from the island.
    private func updateThemePointer() {
        guard NotchThemeSettings.shared.theme.usesPointer else {
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
        guard !state.isExpanded, NotchThemeSettings.shared.theme != .plain else { return }
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
    }

    private func forceCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        setExpanded(false)
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.isExpanded != expanded else { return }

        window?.ignoresMouseEvents = !expanded
        // Queued alerts wait while the drawer covers the island.
        activities.setDrawerOpen(expanded)
        withAnimation(NotchMetrics.hoverAnimation) {
            state.isExpanded = expanded
            if !expanded {
                state.didCollapse()
            }
        }
        if !expanded {
            themeHover.isHovered = false
            hoverDwellTask?.cancel()
            hoverDwellTask = nil
        } else {
            updateClickThrough()
        }

        media.setActive(expanded)
        if expanded {
            macros.refreshLibraryIfStale()
            watchFaceUnlock()
        } else {
            faceUnlockWatch?.cancel()
            faceUnlockWatch = nil
            // Never leave the camera running behind a closed drawer.
            camera.stop()
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
}
