import AppKit
import Combine
import Foundation

// Smart Moments app wiring: builds the engine, the live sources and the band
// presenter, and connects every action to the controller that owns it.
// NotchWindowController makes one `SmartMomentsWiring` and calls `start()`
// (INTEGRATION.md). Nothing here records, captures or sends anything on its
// own: recording and captions run only from a tap (the engine checks twice),
// and no hook hides or quits an app.

/// The app's controllers Smart Moments calls. All exist in NotchWindowController.
@MainActor
struct SmartMomentsAppControllers {
    let media: MediaEngine
    let camera: CameraController
    let screenDistance: ScreenDistanceController
    let activities: ActivityCenter
    let power: PowerMonitor
    let timer: TimerController
    let meetings: MeetingsController
    let notifications: NotificationMonitor
    let meetingAssistant: MeetingAssistant
    let liveTranslation: LiveTranslationController
    let screenRecorder: ScreenRecorderController
    let clipboard: ClipboardController
    let focus: FocusController
    let downloads: DownloadsController
    let screenshotClipboard: ScreenshotClipboardController
    let tray: TrayStore
    /// Opens the drawer on a tab (the mirror lives on `.nook`).
    let openTab: @MainActor (NotchState.Tab) -> Void
}

/// MeetingIntel extras for the moment installs (INTEGRATION.md §4). Set
/// `SmartMomentsWiring.meetingIntelExtras` before `start()`; nil (the
/// default) = MeetingIntel isn't built, and each moment uses its own fallback.
@MainActor
struct SmartMomentsMeetingIntelExtras {
    /// Meeting soon's Agenda brief lines (MeetingIntel `MeetingBriefBuilder`).
    var meetingBrief: (@MainActor (CalendarMeeting) async -> [String]?)?
    /// Meeting ended's wrap-up: open the finished minutes.
    var openWrapUp: (@MainActor (UUID) -> Void)?
    /// Meeting ended's wrap-up: wait for minutes still being written.
    var presentWrapUp: (@MainActor (UUID) -> Void)?

    init(
        meetingBrief: (@MainActor (CalendarMeeting) async -> [String]?)? = nil,
        openWrapUp: (@MainActor (UUID) -> Void)? = nil,
        presentWrapUp: (@MainActor (UUID) -> Void)? = nil
    ) {
        self.meetingBrief = meetingBrief
        self.openWrapUp = openWrapUp
        self.presentWrapUp = presentWrapUp
    }
}

@MainActor
final class SmartMomentsWiring {
    static weak var current: SmartMomentsWiring?

    let settings: SmartMomentsSettings
    let engine: SmartMomentsController
    let sources: SmartMomentsLiveSources
    let presenter: SmartMomentsPresenter
    private let app: SmartMomentsAppControllers

    private var bag: Set<AnyCancellable> = []
    private var reportedDownloads: Set<UUID> = []
    private var lastClipboardID: UUID?
    /// What a hook changed, so its put-back restores exactly that.
    private var brightnessBefore: Double?
    private var captionsBefore: (enabled: Bool, window: Bool, original: Bool)?
    private var activatedModeID: UUID?
    private var builtInPresentation: [MomentAction] = []
    private var started = false

    /// Set before `start()` when Sources/Labs/MeetingIntel is built.
    var meetingIntelExtras: SmartMomentsMeetingIntelExtras?

    /// Actions with no owner in this build: no hook, so the chip never shows
    /// and Settings says "Not available yet".
    static let unavailableActions: Set<MomentAction> = []

    /// `settings` nil = the saved Smart Moments settings.
    init(app: SmartMomentsAppControllers, settings: SmartMomentsSettings? = nil) {
        let settings = settings ?? SmartMomentsSettings()
        self.app = app
        self.settings = settings
        engine = SmartMomentsController(settings: settings)
        sources = SmartMomentsLiveSources(engine: engine)
        presenter = SmartMomentsPresenter(engine: engine, activities: app.activities)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Self.current = self
        SmartMomentsController.current = engine
        installEnvironment()
        installHooks()
        installMoments()
        installSourceInputs()
        installReports()
        installSettingsWindow()

        presenter.start()
        presenter.extraOnOfferChanged = { [weak self] offer in self?.offerChanged(offer) }

        // Sources run only while Smart Moments is on. Call events still reach
        // the engine when it is off, so a call's Do Not Disturb is put back.
        settings.$snapshot
            .map(\.isEnabled)
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.sources.start() } else { self.sources.stop() }
            }
            .store(in: &bag)
    }

    /// NotchWindowController.tearDown().
    func stop() {
        sources.stop()
        bag = []
        started = false
    }

    /// True while something Smart Moments changed is in effect.
    var hasWorkToFinishBeforeQuit: Bool { engine.hasSomethingToPutBack }

    /// NotchWindowController.finishWorkBeforeQuit: puts back Do Not Disturb,
    /// previews, the clipboard band and presentation mode before SparkV quits.
    func prepareForQuit() async {
        sources.stop()
        await engine.prepareForQuit()
    }

    /// MeetingIntel's coordinator, once that lab is built (INTEGRATION.md §4).
    func connectMeetingIntel(_ bridge: any MeetingIntelBridge) {
        engine.meetingIntel = bridge
    }

    // MARK: - Moments (moment-*.swift)

    /// Each moment's handlers and put-backs, on top of `installHooks()`. The
    /// order matters: Meeting started before Meeting ended (which wraps its
    /// reversals), and Screen sharing last of the hook wrappers, so a share's
    /// hold also covers the meeting and presentation put-backs.
    private func installMoments() {
        let app = app
        let intel = meetingIntelExtras
        MeetingSoonMoment.install(on: engine, deps: .live(
            meetings: app.meetings, camera: app.camera, screenDistance: app.screenDistance,
            activities: app.activities, openTab: app.openTab, meetingIntelBrief: intel?.meetingBrief
        ))
        MeetingStartedMoment.install(on: engine, deps: MeetingStartedDeps(
            assistant: app.meetingAssistant, translation: app.liveTranslation, media: app.media,
            focus: app.focus, notifications: app.notifications, camera: app.camera
        ))
        MeetingEndedMoment.install(on: engine, deps: .live(
            assistant: app.meetingAssistant, media: app.media, focus: app.focus, notifications: app.notifications,
            openWrapUp: intel?.openWrapUp, presentWrapUp: intel?.presentWrapUp
        ))
        PresentationMoment.install(on: engine, deps: .live(
            settings: settings, media: app.media, focus: app.focus,
            notifications: app.notifications, timer: app.timer
        ))
        ScreenSharingMoment.install(on: engine, deps: .live(
            media: app.media, notifications: app.notifications, clipboard: app.clipboard,
            activities: app.activities, sharing: sources.$isScreenSharing.eraseToAnyPublisher()
        ))
        DownloadFinishedMoment.install(on: engine, deps: .live(downloads: app.downloads))
        ScreenshotTakenMoment.install(on: engine, deps: .live(
            clipboard: app.clipboard, screenshotClipboard: app.screenshotClipboard
        ))
    }

    // MARK: - Environment the engine reads

    private func installEnvironment() {
        engine.hooks.isScreenSharing = { [weak sources] in sources?.isScreenSharing ?? false }
        engine.hooks.isOnCall = { [weak assistant = app.meetingAssistant] in assistant?.callDetector.activeCall != nil }
        engine.hooks.isSparkVCapturing = { [weak recorder = app.screenRecorder] in
            guard let recorder else { return false }
            return recorder.phase != .idle
        }
    }

    private func installSourceInputs() {
        let app = app
        sources.meetings = { [weak meetings = app.meetings] in meetings?.meetings ?? [] }
        sources.isOnCall = { [weak assistant = app.meetingAssistant] in assistant?.callDetector.activeCall != nil }
        sources.isFocusSessionActive = { [weak focus = app.focus] in focus?.active != nil }
        sources.recordingKind = { [weak assistant = app.meetingAssistant, weak recorder = app.screenRecorder] in
            if assistant?.isRecording == true { return .meetingNotes }
            if recorder?.phase.isRecording == true { return .screenRecording }
            return nil
        }
        sources.battery = { [weak power = app.power] in
            guard let reading = power?.battery else { return nil }
            return MomentBatterySample(level: reading.level, onBattery: !reading.isOnAC, minutesLeft: reading.minutesToEmpty)
        }
    }

    // MARK: - Reports from controllers

    private func installReports() {
        let app = app

        // Calls: chained after MeetingAssistant's own handler. The recorded
        // meeting's id is read before MeetingAssistant handles `.ended`.
        let previous = app.meetingAssistant.callDetector.onEvent
        app.meetingAssistant.callDetector.onEvent = { [weak self, weak assistant = app.meetingAssistant] event in
            let recordedID = assistant?.isRecording == true ? assistant?.current?.id : nil
            previous?(event)
            self?.sources.reportCallEvent(event, recordedMeetingID: recordedID)
        }

        // Downloads: each finished item once, unless DownloadsController's
        // own band shows it or a rule already moved it.
        reportedDownloads = Set(app.downloads.items.filter { $0.phase == .finished }.map(\.id))
        app.downloads.$items
            .sink { [weak self] items in
                guard let self else { return }
                for item in items where item.phase == .finished && !self.reportedDownloads.contains(item.id) {
                    self.reportedDownloads.insert(item.id)
                    guard !self.app.downloads.showsActivity, item.move == nil else { continue }
                    let folder = self.app.downloads.suggestions[item.id]?.destination.displayName
                    self.sources.reportDownloadFinished(itemID: item.id, url: item.url, suggestedFolder: folder)
                }
            }
            .store(in: &bag)

        // Clipboard: the newest item when it is a link or code. The band shows
        // the host or a line count, never the copied text.
        lastClipboardID = app.clipboard.items.first?.id
        app.clipboard.$items
            .sink { [weak self] items in
                guard let self, let item = items.first, item.id != self.lastClipboardID else { return }
                self.lastClipboardID = item.id
                switch ClipboardContentDetector.detect(item) {
                case .link(let url)?:
                    self.sources.reportCopied(.link, preview: url.host ?? "Link", itemID: item.id)
                case .code?:
                    let lines = (item.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
                    self.sources.reportCopied(.code, preview: "\(lines) lines", itemID: item.id)
                default:
                    break
                }
            }
            .store(in: &bag)
    }

    /// The band changed. While our meeting band offers Record notes, the
    /// assistant's own "Notes?" prompt steps aside (one offer per call).
    private func offerChanged(_ offer: MomentOffer?) {
        guard let offer, offer.moment == .meetingStarted, offer.actions.contains(.recordNotes),
              engine.meetingIntel == nil, app.meetingAssistant.promptedCall != nil else { return }
        app.meetingAssistant.dismissDetectedCall()
    }

    // MARK: - Settings window

    private func installSettingsWindow() {
        let window = SmartMomentsSettingsWindowController.shared
        window.modeChoices = {
            ModeEngine.shared.modes
                .filter { !SmartMomentsWiring.hidesOrQuitsApps($0) }
                .map { SmartMomentsModeChoice(id: $0.id, name: $0.name, symbol: $0.symbol) }
        }
        window.isActionAvailable = { [weak engine] action in
            guard let engine else { return true }
            return engine.hooks.actions[action] != nil || (engine.meetingIntel?.handledActions.contains(action) ?? false)
        }
    }

    /// Smart Moments never turns on a mode that hides or quits apps.
    nonisolated static func hidesOrQuitsApps(_ mode: SparkMode) -> Bool {
        mode.actions.contains { action in
            switch action {
            case .hideApps, .quitApps: true
            default: false
            }
        }
    }

    // MARK: - Action hooks

    private func installHooks() {
        let app = app
        var h = engine.hooks

        // Before a meeting ---------------------------------------------------

        h.actions[.joinMeeting] = { [weak meetings = app.meetings] context in
            guard case .meetingSoon(let meeting, _) = context.trigger, meeting.link != nil, let meetings else {
                return .skipped("No call link")
            }
            meetings.join(meeting)
            return .done("Joining")
        }
        h.isAvailable[.joinMeeting] = { trigger in
            if case .meetingSoon(let meeting, _) = trigger { return meeting.link != nil }
            return false
        }

        h.actions[.openMirror] = { [weak camera = app.camera, weak distance = app.screenDistance, openTab = app.openTab] context in
            guard let camera else { return .skipped("No camera") }
            if context.userInitiated { openTab(.nook) }
            guard !camera.isRunning, !camera.isStarting else { return .skipped("Mirror is on") }
            distance?.yieldCamera()
            camera.start()
            return .done("Mirror on")
        }
        h.isAvailable[.openMirror] = { [weak camera = app.camera] _ in !(camera?.isRunning ?? true) }

        h.actions[.checkDevices] = { _ in
            let center = PermissionCenter.shared
            let mic = center.isGranted(.microphone) ? "Mic ready" : "Mic needs access"
            let cam = center.isGranted(.camera) ? "camera ready" : "camera needs access"
            let output = SmartMomentsSystemReaders.defaultOutput()?.name
            return .done([mic, cam, output.map { "sound to \($0)" }].compactMap { $0 }.joined(separator: " · "))
        }

        // During a meeting (consent: the engine runs these only from a tap) --

        h.actions[.recordNotes] = { [weak assistant = app.meetingAssistant] context in
            guard let assistant else { return .failed("Meeting notes unavailable") }
            guard !assistant.isRecording else { return .skipped("Already recording") }
            if case .meetingStarted = context.trigger, assistant.callDetector.activeCall != nil {
                assistant.startDetectedCall()
            } else {
                assistant.start(title: nil, calendarEventID: nil)
                if assistant.isRecording { assistant.openNotesWindow() }
            }
            return assistant.isRecording ? .done("Recording notes") : .failed("Recording didn't start")
        }
        h.isAvailable[.recordNotes] = { [weak assistant = app.meetingAssistant] _ in !(assistant?.isRecording ?? true) }

        // Captions come from the meeting transcript, shown by Live Translation
        // (original words for captions, translated for Translate). They need
        // the recording, so a tap here starts it when it isn't running.
        h.actions[.liveCaptions] = { [weak self] context in
            await self?.startCaptions(translated: false, context: context) ?? .failed("Unavailable")
        }
        h.actions[.translateCaptions] = { [weak self] context in
            await self?.startCaptions(translated: true, context: context) ?? .failed("Unavailable")
        }
        h.isAvailable[.liveCaptions] = { [weak translation = app.liveTranslation] _ in !(translation?.isEnabled ?? true) }
        h.isAvailable[.translateCaptions] = { [weak translation = app.liveTranslation] _ in !(translation?.isEnabled ?? true) }
        let stopCaptions: SmartMomentsHooks.Run = { [weak self] _ in self?.restoreCaptions() ?? .skipped("Gone") }
        engine.putBack[.liveCaptions] = stopCaptions
        engine.putBack[.translateCaptions] = stopCaptions

        h.actions[.mirrorOff] = { [weak camera = app.camera] _ in
            guard let camera, camera.isRunning || camera.isStarting else { return .skipped("Mirror is off") }
            camera.stop()
            return .done("Mirror off")
        }
        h.isAvailable[.mirrorOff] = { [weak camera = app.camera] _ in camera?.isRunning ?? false }

        // After a meeting ----------------------------------------------------

        h.actions[.notesWrapUp] = { [weak assistant = app.meetingAssistant] context in
            guard case .meetingEnded(_, let id?) = context.trigger, let assistant else { return .skipped("No notes") }
            assistant.openNotesWindow(meetingID: id)
            return .done("Notes open")
        }
        h.isAvailable[.notesWrapUp] = { trigger in
            if case .meetingEnded(_, let id) = trigger { return id != nil }
            return false
        }

        // Music ----------------------------------------------------------------

        h.actions[.pauseMusic] = { [weak media = app.media] _ in
            guard let media, media.isPlaying else { return .skipped("Nothing playing") }
            media.send(.togglePlayPause)
            return .done("Paused music")
        }
        h.actions[.resumeMusic] = { [weak media = app.media] _ in
            guard let media, !media.isPlaying, media.source != .none else { return .skipped("Nothing to resume") }
            media.send(.togglePlayPause)
            return .done("Resumed music")
        }
        h.isAvailable[.resumeMusic] = { [weak media = app.media] _ in
            guard let media else { return false }
            return !media.isPlaying && media.source != .none
        }

        // Do Not Disturb (the user's Focus shortcuts) ------------------------

        h.actions[.doNotDisturbOn] = { [weak focus = app.focus] _ in
            guard let focus else { return .skipped("Unavailable") }
            // A focus session already silenced things: leave it to the session.
            if focus.active?.didEnableDoNotDisturb == true { return .skipped("Already on for Focus") }
            let s = focus.settings
            await focus.doNotDisturb.refresh(on: s.dndOnShortcut, off: s.dndOffShortcut)
            switch await focus.doNotDisturb.turnOn(s.dndOnShortcut) {
            case .done: return .done("Do Not Disturb on")
            case .notSetUp: return .failed("Set up Do Not Disturb in Focus settings")
            case .failed(let message): return .failed(message)
            }
        }
        h.actions[.doNotDisturbOff] = { [weak focus = app.focus] _ in
            guard let focus else { return .skipped("Unavailable") }
            if focus.active?.didEnableDoNotDisturb == true { return .skipped("Focus keeps it on") }
            switch await focus.doNotDisturb.turnOff(focus.settings.dndOffShortcut) {
            case .done: return .done("Do Not Disturb off")
            case .notSetUp: return .failed("Set up Do Not Disturb in Focus settings")
            case .failed(let message): return .failed(message)
            }
        }
        let dndReady: @MainActor (MomentTrigger) -> Bool = { [weak focus = app.focus] _ in
            guard let focus else { return false }
            if case .missing = focus.doNotDisturb.setup { return false }
            return true
        }
        h.isAvailable[.doNotDisturbOn] = dndReady
        h.isAvailable[.doNotDisturbOff] = dndReady

        // SparkV's own notification previews --------------------------------

        h.actions[.hideNotificationPreviews] = { [weak notifications = app.notifications] _ in
            guard let notifications, notifications.isEnabled else { return .skipped("Already hidden") }
            notifications.isEnabled = false
            return .done("Previews hidden")
        }
        h.actions[.showNotificationPreviews] = { [weak notifications = app.notifications, weak focus = app.focus] _ in
            guard let notifications, !notifications.isEnabled else { return .skipped("Already shown") }
            // A running focus session restores previews itself when it ends.
            if focus?.active != nil { return .skipped("Focus keeps them hidden") }
            notifications.isEnabled = true
            return .done("Previews back")
        }

        // Clipboard band (history keeps recording) ---------------------------

        h.actions[.hideClipboardBand] = { [weak clipboard = app.clipboard] _ in
            guard let clipboard, clipboard.showsBannerForEveryCopy else { return .skipped("Already hidden") }
            clipboard.setShowsBannerForEveryCopy(false)
            return .done("Clipboard band hidden")
        }
        h.actions[.showClipboardBand] = { [weak clipboard = app.clipboard] _ in
            guard let clipboard, !clipboard.showsBannerForEveryCopy else { return .skipped("Already shown") }
            clipboard.setShowsBannerForEveryCopy(true)
            return .done("Clipboard band back")
        }

        // Power ----------------------------------------------------------------

        h.actions[.saveRecordingNow] = { [weak assistant = app.meetingAssistant, weak recorder = app.screenRecorder] context in
            guard case .lowBatteryWhileRecording(_, _, let kind) = context.trigger else { return .skipped("Nothing recording") }
            switch kind {
            case .meetingNotes:
                guard let assistant, assistant.isRecording else { return .skipped("Not recording") }
                assistant.stop()
            case .screenRecording:
                guard let recorder, recorder.phase.isRecording else { return .skipped("Not recording") }
                recorder.stop()
            }
            return .done("Saving the recording")
        }
        h.actions[.showBatteryTimeLeft] = { [weak power = app.power] _ in
            guard let reading = power?.battery else { return .skipped("No battery reading") }
            if let minutes = reading.minutesToEmpty { return .done("About \(minutes) min left at \(reading.level) %") }
            return .done("Battery \(reading.level) %")
        }
        h.actions[.openBatterySettings] = { context in
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return .failed("No link") }
            NSWorkspace.shared.open(url)
            return .done("Battery settings")
        }

        // Downloads ------------------------------------------------------------

        h.actions[.sortDownload] = { [weak downloads = app.downloads] context in
            guard case .downloadFinished(let id, _, _) = context.trigger, let downloads,
                  let suggestion = downloads.suggestions[id] else { return .skipped("No suggestion") }
            // On its own only by the user's own rule; an AI pick waits for a tap.
            if !context.userInitiated, case .ai = suggestion.origin { return .skipped("Needs a tap") }
            downloads.sortWithSuggestion(id)
            guard downloads.item(id)?.move != nil else { return .failed("Couldn't move it") }
            return .done("Moved to \(suggestion.destination.displayName)")
        }
        h.isAvailable[.sortDownload] = { [weak downloads = app.downloads] trigger in
            guard case .downloadFinished(let id, _, _) = trigger, let downloads else { return false }
            return downloads.suggestions[id] != nil
        }
        engine.putBack[.sortDownload] = { [weak downloads = app.downloads] context in
            guard case .downloadFinished(let id, _, _) = context.trigger, let downloads, downloads.item(id)?.move != nil else {
                return .skipped("Not moved")
            }
            downloads.undo(id)
            return downloads.item(id)?.move == nil ? .done("Put back") : .failed("Couldn't move it back")
        }
        h.actions[.openFile] = { [weak downloads = app.downloads] context in
            guard context.userInitiated, case .downloadFinished(let id, _, _) = context.trigger, let downloads else { return .skipped("Needs a tap") }
            downloads.open(id)
            return .done("Opened")
        }
        h.actions[.revealInFinder] = { [weak downloads = app.downloads] context in
            guard context.userInitiated, case .downloadFinished(let id, _, _) = context.trigger, let downloads else { return .skipped("Needs a tap") }
            downloads.reveal(id)
            return .done("Shown in Finder")
        }

        // Tray and Spaces (downloads and screenshots) ------------------------

        h.actions[.addToTray] = { [weak downloads = app.downloads, weak tray = app.tray] context in
            switch context.trigger {
            case .downloadFinished(let id, _, _):
                guard let downloads else { return .skipped("Unavailable") }
                downloads.addToTray(id)
                return .done("Added to the Tray")
            case .screenshotTaken(let url):
                guard let tray else { return .skipped("Unavailable") }
                tray.addFile(url)
                return .done("Added to the Tray")
            default:
                return .skipped("Nothing to add")
            }
        }
        h.isAvailable[.addToTray] = { trigger in
            switch trigger {
            case .downloadFinished, .screenshotTaken: true
            default: false
            }
        }
        h.actions[.sendToSpace] = { [weak downloads = app.downloads, weak clipboard = app.clipboard] context in
            guard context.userInitiated else { return .skipped("Needs a tap") }
            switch context.trigger {
            case .downloadFinished(let id, _, _):
                downloads?.sendToSpace(id)
                return .done("Sent to Spaces")
            case .screenshotTaken(let url):
                SpaceIngestCenter.file(url, userInitiated: true)
                return .done("Sent to Spaces")
            case .copied(let kind, _, let itemID?):
                guard let item = clipboard?.items.first(where: { $0.id == itemID }), let text = item.text else {
                    return .skipped("Copy is gone")
                }
                let link: URL? = kind == .link ? URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                _ = SpaceStore.shared.addManual(
                    title: link?.host ?? "Code snippet", text: text, url: link, spaceID: nil,
                    kind: kind == .link ? .link : .clipboard
                )
                return .done("Sent to Spaces")
            default:
                return .skipped("Nothing to send")
            }
        }

        // Focus and wind-down -------------------------------------------------

        h.actions[.startFocusSession] = { [weak focus = app.focus] _ in
            guard let focus, focus.active == nil else { return .skipped("Focus is on") }
            focus.startSession()
            return focus.active != nil ? .done("Focus started") : .failed("Focus didn't start")
        }
        h.isAvailable[.startFocusSession] = { [weak focus = app.focus] _ in focus?.active == nil }

        h.actions[.nightMode] = { [weak self] _ in
            guard let self else { return .skipped("Gone") }
            return await self.activateMode(self.settings.tunables.nightModeID ?? ModePresets.nightID)
        }
        engine.putBack[.nightMode] = { [weak self] _ in await self?.deactivateOurMode() ?? .skipped("Gone") }

        h.actions[.lowerBrightness] = { [weak self] _ in
            let system = LiveModeSystem.shared
            guard let self, let level = system.brightness() else { return .skipped("Built-in display only") }
            let target = max(0.15, level * 0.6)
            guard target < level - 0.02 else { return .skipped("Already low") }
            do {
                try system.setBrightness(target)
                self.brightnessBefore = level
                return .done("Brightness lowered")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        h.isAvailable[.lowerBrightness] = { _ in LiveModeSystem.shared.brightness() != nil }
        engine.putBack[.lowerBrightness] = { [weak self] _ in
            guard let self, let level = self.brightnessBefore else { return .skipped("Unchanged") }
            self.brightnessBefore = nil
            do {
                try LiveModeSystem.shared.setBrightness(level)
                return .done("Brightness back")
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        h.actions[.windDownTimer] = { [weak timer = app.timer] _ in
            guard let timer, timer.isEnabled else { return .skipped("Timer is off") }
            timer.startTimer(minutes: 15)
            return .done("Wind-down started")
        }
        h.isAvailable[.windDownTimer] = { [weak timer = app.timer] _ in timer?.isEnabled ?? false }

        // Presenting ------------------------------------------------------------

        h.actions[.presentationMode] = { [weak self] context in
            guard let self else { return .skipped("Gone") }
            // A display has no "presentation ended": only a tap turns it on there.
            if case .displayConnected = context.trigger, !context.userInitiated { return .skipped("Needs a tap") }
            if let id = self.settings.tunables.presentationModeID { return await self.activateMode(id) }
            return await self.builtInPresentationOn(context)
        }
        engine.putBack[.presentationMode] = { [weak self] context in
            guard let self else { return .skipped("Gone") }
            if self.activatedModeID != nil { return await self.deactivateOurMode() }
            return await self.builtInPresentationOff(context)
        }

        // Clipboard -----------------------------------------------------------

        h.actions[.openLink] = { [weak self] context in
            guard context.userInitiated, let url = self?.copiedLink(context.trigger) else { return .skipped("Needs a tap") }
            NSWorkspace.shared.open(url)
            return .done("Opened")
        }
        h.actions[.cleanLink] = { [weak self] context in
            guard let self, let url = self.copiedLink(context.trigger) else { return .skipped("No link") }
            guard let clean = MomentTextTools.cleanLink(url) else { return .skipped("Already clean") }
            self.writeToPasteboard(clean.absoluteString)
            return .done("Link cleaned")
        }
        h.actions[.copyAsMarkdownLink] = { [weak self] context in
            guard let self, let url = self.copiedLink(context.trigger) else { return .skipped("No link") }
            self.writeToPasteboard(MomentTextTools.markdownLink(title: nil, url: MomentTextTools.cleanLink(url) ?? url))
            return .done("Copied as Markdown")
        }
        h.actions[.formatCode] = { [weak self] context in
            guard let self, case .copied(.code, _, _) = context.trigger, let text = self.copiedText(context.trigger) else {
                return .skipped("No code")
            }
            let formatted = MomentTextTools.formatCode(text)
            guard formatted != text else { return .skipped("Already tidy") }
            self.writeToPasteboard(formatted)
            return .done("Code formatted")
        }
        let isLink: @MainActor (MomentTrigger) -> Bool = { trigger in
            if case .copied(.link, _, _) = trigger { return true }
            return false
        }
        h.isAvailable[.openLink] = isLink
        h.isAvailable[.cleanLink] = { [weak self] trigger in
            guard isLink(trigger), let url = self?.copiedLink(trigger) else { return false }
            return MomentTextTools.cleanLink(url) != nil
        }
        h.isAvailable[.copyAsMarkdownLink] = isLink
        h.isAvailable[.formatCode] = { trigger in
            if case .copied(.code, _, _) = trigger { return true }
            return false
        }

        // Screenshots ------------------------------------------------------------

        h.actions[.copyImage] = { [weak clipboard = app.clipboard] context in
            guard case .screenshotTaken(let url) = context.trigger, let image = NSImage(contentsOf: url) else {
                return .skipped("Screenshot is gone")
            }
            clipboard?.ignoreNextCopy()
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects([image])
            return .done("Copied")
        }
        // Screenshot to Clipboard already copies every screenshot.
        h.isAvailable[.copyImage] = { [weak shots = app.screenshotClipboard] _ in !(shots?.isEnabled ?? false) }
        h.actions[.annotateImage] = { context in
            guard context.userInitiated, case .screenshotTaken(let url) = context.trigger else { return .skipped("Needs a tap") }
            guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                NSWorkspace.shared.open(url)
                return .done("Opened")
            }
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
            return .done("Opened in Preview")
        }
        h.actions[.extractText] = { [weak self] context in
            guard let self, case .screenshotTaken(let url) = context.trigger else { return .skipped("No screenshot") }
            // On-device Vision; nothing leaves the Mac.
            guard let analysis = await TrayAIOCR.analyze(imageAt: url) else { return .failed("Couldn't read it") }
            let text = analysis.lines.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else { return .skipped("No text in it") }
            self.writeToPasteboard(text)
            return .done("Text copied")
        }

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

    private func startCaptions(translated: Bool, context: MomentActionContext) async -> MomentActionResult {
        let translation = app.liveTranslation
        let assistant = app.meetingAssistant
        guard !translation.isEnabled else { return .skipped("Captions are on") }
        if !assistant.isRecording {
            // The tap is the consent: the recording band and its dot stay up.
            if case .meetingStarted = context.trigger, assistant.callDetector.activeCall != nil {
                assistant.startDetectedCall()
            } else {
                assistant.start(title: nil, calendarEventID: nil)
            }
            guard assistant.isRecording else { return .failed("Recording didn't start") }
        }
        captionsBefore = (translation.isEnabled, translation.showsCaptionWindow, translation.showsOriginal)
        if !translated { translation.showsOriginal = true }
        translation.showsCaptionWindow = true
        translation.isEnabled = true
        return .done(translated ? "Translating captions" : "Captions on")
    }

    private func restoreCaptions() -> MomentActionResult {
        guard let before = captionsBefore else { return .skipped("Unchanged") }
        captionsBefore = nil
        let translation = app.liveTranslation
        translation.isEnabled = before.enabled
        translation.showsCaptionWindow = before.window
        translation.showsOriginal = before.original
        return .done("Captions off")
    }

    // MARK: - Modes

    private func activateMode(_ id: UUID) async -> MomentActionResult {
        let modes = ModeEngine.shared
        guard let mode = modes.mode(id) else { return .failed("That mode no longer exists") }
        guard !Self.hidesOrQuitsApps(mode) else { return .skipped("\(mode.name) hides or quits apps") }
        guard modes.activeModeID == nil else { return .skipped("Another mode is on") }
        await modes.activate(id)
        guard modes.activeModeID == id else { return .failed(modes.lastError ?? "\(mode.name) didn't start") }
        activatedModeID = id
        return .done("\(mode.name) on")
    }

    private func deactivateOurMode() async -> MomentActionResult {
        guard let id = activatedModeID else { return .skipped("Unchanged") }
        activatedModeID = nil
        let modes = ModeEngine.shared
        // The user switched modes meanwhile: theirs stays.
        guard modes.activeModeID == id else { return .skipped("Changed by hand") }
        await modes.deactivate()
        return .done("Mode off")
    }

    /// The default presentation mode: Do Not Disturb, hidden previews and
    /// paused music. Never hides apps or changes the wallpaper.
    private func builtInPresentationOn(_ context: MomentActionContext) async -> MomentActionResult {
        var changed: [MomentAction] = []
        for action in [MomentAction.doNotDisturbOn, .hideNotificationPreviews, .pauseMusic] {
            guard let hook = engine.hooks.actions[action], engine.hooks.supports(action, for: context.trigger) else { continue }
            if case .done = await hook(context) { changed.append(action) }
        }
        builtInPresentation = changed
        return changed.isEmpty ? .skipped("Already quiet") : .done("Presentation mode on")
    }

    private func builtInPresentationOff(_ context: MomentActionContext) async -> MomentActionResult {
        let changed = builtInPresentation
        builtInPresentation = []
        var undone = false
        for action in changed.reversed() {
            guard let reversal = action.reversal, let hook = engine.hooks.actions[reversal] else { continue }
            if case .done = await hook(context) { undone = true }
        }
        return undone ? .done("Presentation mode off") : .skipped("Unchanged")
    }

    // MARK: - Clipboard helpers

    private func copiedText(_ trigger: MomentTrigger) -> String? {
        guard case .copied(_, _, let itemID?) = trigger else { return nil }
        return app.clipboard.items.first { $0.id == itemID }?.text
    }

    private func copiedLink(_ trigger: MomentTrigger) -> URL? {
        guard case .copied(.link, _, _) = trigger, let text = copiedText(trigger) else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Our own copy isn't recorded as a new clipboard item (no echo band).
    private func writeToPasteboard(_ text: String) {
        app.clipboard.ignoreNextCopy()
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

// MARK: - MeetingIntel link

/// Adapts MeetingIntel's start coordinator to `MeetingIntelBridge` without
/// this lab depending on it: wiring passes closures (INTEGRATION.md §4).
/// MeetingIntel shows its own call prompt (record, captions, translate);
/// Smart Moments then shows only the rest in its band.
@MainActor
final class SmartMomentsMeetingIntelLink: MeetingIntelBridge {
    /// True when MeetingIntel will prompt for this call.
    let wantsOffer: @MainActor (DetectedCall) -> Bool
    /// Runs record / captions / translate through MeetingIntel (a tap).
    let start: @MainActor (MomentAction) async -> MomentActionResult

    init(wantsOffer: @escaping @MainActor (DetectedCall) -> Bool,
         start: @escaping @MainActor (MomentAction) async -> MomentActionResult) {
        self.wantsOffer = wantsOffer
        self.start = start
    }

    let handledActions: Set<MomentAction> = [.recordNotes, .liveCaptions, .translateCaptions]
    var hostsContributedChips: Bool { false }

    func willPrompt(for trigger: MomentTrigger) -> Bool {
        if case .meetingStarted(let call) = trigger { return wantsOffer(call) }
        return false
    }

    func perform(_ action: MomentAction, context: MomentActionContext) async -> MomentActionResult {
        guard context.userInitiated else { return .skipped("Needs a tap") }
        return await start(action)
    }

    func contribute(_ actions: [MomentAction], for trigger: MomentTrigger, run: @escaping @MainActor (MomentAction) -> Void) {}
}
