import AppKit
import Combine
import CoreAudio
import CoreGraphics
import SwiftUI

/// Volume and brightness HUD. Shows SparkV's own HUD whenever the output
/// volume, mute state, output device or a display's brightness changes. With
/// `replacesSystemHUD` (and Accessibility), SystemKeyInterceptor swallows the
/// keys it can apply so macOS's own pop-up doesn't show as well.
///
/// - Volume: CoreAudio property listeners on the default output device
///   (volume scalar on the main element, or channels 1/2, plus mute), run on a
///   private queue because the first HAL call can take 100+ ms.
/// - Brightness: DisplayServices (private, loaded with dlopen, as before) for
///   the level and change notifications of every display it can drive (the
///   built-in panel and Apple's own displays), plus the brightness keys seen
///   through an NSEvent monitor, after which that display is sampled for a
///   second. Monitors DisplayServices can't drive (DDC) are left to
///   BetterDisplay, Lunar or macOS; SparkV then shows nothing rather than a
///   wrong level.
/// - Styles (`HUDPlusSettings`): beside the notch (bar or ring), the band
///   under it, a floating pill or an edge bar, per display. Displays without
///   the island use the pill or edge bar in an overlay panel.
/// - Interactive: on the closed island the HUD takes clicks, drags and
///   scrolls (`HUDInteractionController`).
///
/// Nothing polls while idle: listeners and notifications only, plus a
/// one-second sample burst after a brightness key.
@MainActor
final class HUDController: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            guard isStarted else { return }
            if isEnabled { startMonitoring() } else { stopMonitoring() }
        }
    }

    /// Swallow the brightness/volume keys and apply them ourselves so only
    /// SparkV's HUD shows, not macOS's pop-up as well.
    @Published var replacesSystemHUD: Bool {
        didSet {
            guard replacesSystemHUD != oldValue else { return }
            UserDefaults.standard.set(replacesSystemHUD, forKey: Self.replaceKey)
            guard isMonitoring else { return }
            if replacesSystemHUD { interceptor.start() } else { interceptor.stop() }
        }
    }

    /// The running controller, for Settings sections and menu items that take
    /// no arguments.
    static weak var current: HUDController?

    static let volumeActivityID = "volume"
    static let brightnessActivityID = "brightness"
    private static let enabledKey = "HUDEnabled"
    private static let replaceKey = "HUDReplacesSystem"
    /// Settings › Activities › Timing (1–4 s, 1.6 s by default).
    private static var hudDuration: TimeInterval {
        min(NotchMetrics.alertMaxDuration, ActivityTimingSettings.shared.hudSeconds)
    }
    private static let deviceDuration: TimeInterval = 2

    let settings = HUDPlusSettings.shared
    /// Clicks, drags and scrolls on the HUD beside the notch.
    let interaction = HUDInteractionController()
    /// The island's display. `NotchWindowController` points this at its own
    /// choice; the default matches it (notched screen, else the first).
    var islandScreen: () -> NSScreen? = { HUDDisplayDirectory.defaultIslandScreen() }
    /// Whether the island is on screen. `NotchWindowController` feeds Island
    /// Placement's decision; while it is hidden, wing styles use the band it
    /// passes through (or nothing, and macOS's own pop-up shows).
    var islandAvailability: () -> HUDIslandAvailability = { .shown }
    /// Displays showing an All Displays mirror of the island right now. A HUD
    /// for one of them draws on that mirror only.
    var islandMirrorDisplayIDs: () -> Set<CGDirectDisplayID> = { [] }

    private let activities: ActivityCenter
    private let overlay = HUDOverlayPresenter()
    private let displays = HUDDisplayDirectory.shared
    private let displayApps = HUDDisplayAppWatcher.shared
    private let brightness = HUDDisplayBrightness.shared
    private var isStarted = false
    private var isMonitoring = false

    // Volume
    private var audio: AudioOutputMonitor?
    private var lastAudio: AudioOutputMonitor.State?
    private var deviceCaptionUntil = Date.distantPast
    private var lastVolumePost = Date.distantPast
    private var volumeKeyTask: Task<Void, Never>?

    // Brightness, per display
    private var lastBrightness: [CGDirectDisplayID: Float] = [:]
    private var brightnessSamples: [CGDirectDisplayID: [(time: Date, value: Float)]] = [:]
    private var brightnessKeyUntil = Date.distantPast
    private var lastBrightnessPost = Date.distantPast
    /// The display of the brightness HUD showing (or last shown).
    private var brightnessDisplay: CGDirectDisplayID?
    private var pollTask: Task<Void, Never>?
    private var forcedBrightnessTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    // Keys
    private let interceptor = SystemKeyInterceptor()
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    /// Re-installs the global key monitor after an Accessibility grant.
    private var trustWatch: AnyCancellable?
    /// Ends the HUD's interaction when it leaves the island.
    private var islandWatch: AnyCancellable?
    private var announceTask: Task<Void, Never>?
    private var lastAnnouncement: String?
    /// VoiceOver hears SparkV's HUD only while SparkV took the key (macOS then
    /// stays quiet) or the pointer set the level; otherwise macOS speaks.
    private var announceUntil = Date.distantPast

    /// What each HUD id last showed, exactly as presented, so holding it on
    /// screen or moving its level never changes its form (an output switch
    /// stays in the band).
    private struct Presentation {
        var content: HUDContent
        var kind: LiveActivity.Kind
        var duration: TimeInterval
        var style: HUDStyle
        var screen: HUDScreenInfo?
        var allowsCompact: Bool
    }
    private var presented: [String: Presentation] = [:]
    /// Keeps the HUD up while the pointer rests on it (exists only then).
    private var holdTask: Task<Void, Never>?
    /// Interactive level: the latest value, written at most ~30 times a
    /// second and posted at most ~10 times a second (last value wins).
    private var pendingLevel: Double?
    private var writeTask: Task<Void, Never>?
    private var lastLevelWrite = Date.distantPast
    private var repostTask: Task<Void, Never>?
    private var lastRepost = Date.distantPast
    private static let writeInterval: TimeInterval = 1.0 / 30
    private static let repostInterval: TimeInterval = 0.1
    /// CoreAudio writes from the interactive HUD (a Bluetooth output can
    /// take a while to answer), off the main thread.
    private static let audioWriteQueue = DispatchQueue(label: "SparkV.HUD.audioWrite", qos: .userInitiated)

    /// The controller DisplayServices' C callback forwards to.
    fileprivate static weak var brightnessTarget: HUDController?

    init(activities: ActivityCenter) {
        self.activities = activities
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        replacesSystemHUD = UserDefaults.standard.object(forKey: Self.replaceKey) as? Bool ?? true
        Self.current = self
        interceptor.onHandled = { [weak self] key in
            guard let self, self.isMonitoring else { return }
            self.announceUntil = Date().addingTimeInterval(1)
            switch key {
            case SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown:
                break // onHandledBrightness says which display
            default:
                self.volumeKeyPressed()
            }
        }
        interceptor.onHandledBrightness = { [weak self] display in
            guard let self, self.isMonitoring else { return }
            self.announceUntil = Date().addingTimeInterval(1)
            self.brightnessKeyPressed(handled: display)
        }
        interceptor.showsFeedback = { [weak self] display in
            guard let self else { return true }
            let screen = display.flatMap(self.displays.screen(for:)) ?? (display == nil ? self.volumeScreen() : nil)
            return self.resolvedStyle(on: screen) != .hidden
        }
        connectInteraction()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if isEnabled { startMonitoring() }
    }

    func stop() {
        stopMonitoring()
        isStarted = false
    }

    /// Hands the island panel to the interactive HUD (see `HUDInteractionController`).
    func attachIsland(window: NSWindow, isDrawerOpen: @escaping () -> Bool) {
        interaction.attach(window: window, isDrawerOpen: isDrawerOpen)
    }

    /// For `NotchWindowController.handlePointer` while the drawer is closed:
    /// true while the pointer is on the HUD (skip opening from hover).
    func handleIslandPointer(notchRect: NSRect, layout: IslandClosedLayout?) -> Bool {
        interaction.handlePointer(NSEvent.mouseLocation, zones: interactionZones(notchRect: notchRect, layout: layout))
    }

    /// Where the HUD's icon and level are on the closed island, or nil when
    /// it isn't there (or isn't interactive).
    func interactionZones(notchRect: NSRect, layout: IslandClosedLayout?) -> HUDInteractionZones? {
        guard isMonitoring, settings.isInteractive, let layout, let placement = islandPlacement(),
              let id = islandHUDID(), let shown = presented[id],
              // Drawn on a mirror only: nothing to point at on this island.
              shown.content.mirrorTarget == nil
        else { return nil }
        return HUDInteractionZones.island(
            notchRect: notchRect, layout: layout, placement: placement,
            ring: shown.style == .ring && placement == .wings,
            showsPercent: settings.showsPercent,
            hasCaption: placement == .band && shown.content.captionText != nil
        )
    }

    /// Shows the HUD in `style` (default: the current choice) with the
    /// current volume, from Settings and the gear menu.
    func preview(style: HUDStyle? = nil) {
        let device = HUDVolumeControl.defaultOutput()
        let level = device.flatMap(HUDVolumeControl.volume) ?? lastAudio?.volume ?? 0.5
        let muted = device.map(HUDVolumeControl.isMuted) ?? false
        let content = HUDContent(style: .volume(muted: muted, deviceName: nil), level: Double(level))
        let screen = volumeScreen()
        let resolved = style ?? resolvedStyle(on: screen)
        announceUntil = .distantPast
        present(content, id: Self.volumeActivityID, kind: .volume, duration: Self.hudDuration * 1.5, style: resolved, screen: screen)
    }

    // MARK: - Lifecycle

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        displays.start()
        displayApps.start()

        let monitor = AudioOutputMonitor { [weak self] change in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleAudio(change) }
            }
        }
        audio = monitor
        monitor.start()

        Self.brightnessTarget = self
        registerBrightness()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { HUDController.brightnessTarget?.screensChanged() }
        }

        startKeyMonitors()
        trustWatch = PermissionCenter.shared.whenGranted(.accessibility) { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.startKeyMonitors()
        }
        if replacesSystemHUD { interceptor.start() }
        islandWatch = activities.$current.combineLatest(activities.$compact)
            .sink { [weak self] current, compact in
                let ids = [HUDController.volumeActivityID, HUDController.brightnessActivityID]
                guard !ids.contains(current?.id ?? ""), !ids.contains(compact?.id ?? "") else { return }
                // @Published fires before the store; end on the next turn.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.islandPlacement() == nil else { return }
                        self.interaction.end()
                    }
                }
            }
        AppLog.log("HUD: monitoring started (brightness on \(brightness.registered.count) display(s)\(displayApps.runningName.map { ", \($0) running" } ?? ""))")
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        audio?.stop()
        audio = nil
        lastAudio = nil
        volumeKeyTask?.cancel()
        volumeKeyTask = nil

        brightness.unregisterAll()
        if Self.brightnessTarget === self { Self.brightnessTarget = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pollTask?.cancel()
        pollTask = nil
        forcedBrightnessTask?.cancel()
        forcedBrightnessTask = nil
        announceTask?.cancel()
        announceTask = nil
        lastBrightness = [:]
        brightnessSamples = [:]

        interceptor.stop()
        trustWatch = nil
        islandWatch = nil
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil

        interaction.end()
        stopHolding()
        writeTask?.cancel()
        writeTask = nil
        repostTask?.cancel()
        repostTask = nil
        pendingLevel = nil
        presented = [:]
        overlay.hide(animated: false)
        activities.dismiss(id: Self.volumeActivityID)
        activities.dismiss(id: Self.brightnessActivityID)
        displays.stop()
        displayApps.stop()
        AppLog.log("HUD: monitoring stopped")
    }

    // MARK: - Presenting

    /// The style for a screen (nil: the island's), with its per-display choice.
    private func resolvedStyle(on screen: HUDScreenInfo?) -> HUDStyle {
        let island = islandScreen().flatMap(HUDDisplayDirectory.displayID(of:))
        guard let screen = screen ?? island.flatMap(displays.screen(for:)) else {
            return settings.resolvedStyle(forDisplayUUID: nil, isIslandScreen: true)
        }
        return settings.resolvedStyle(forDisplayUUID: screen.uuid, isIslandScreen: isIslandDisplay(screen.facts.id, main: island))
    }

    /// The main island's display, or one of its All Displays mirrors.
    private func isIslandDisplay(_ display: CGDirectDisplayID, main: CGDirectDisplayID?) -> Bool {
        main == nil || display == main || islandMirrorDisplayIDs().contains(display)
    }

    /// Shows a HUD: on the island for its styles, else in the overlay panel
    /// on `screen` (nil: the island's display).
    private func present(_ content: HUDContent, id: String, kind: LiveActivity.Kind, duration: TimeInterval, style requested: HUDStyle, screen: HUDScreenInfo?, allowsCompact requestedCompact: Bool = true) {
        var content = content
        var style = requested
        var allowsCompact = requestedCompact
        if style.usesIsland {
            let main = islandScreen().flatMap(HUDDisplayDirectory.displayID(of:))
            if let target = screen?.facts.id, target != main, islandMirrorDisplayIDs().contains(target) {
                // All Displays: only the island on the display being changed draws it.
                content.mirrorTarget = target
            } else {
                content.mirrorTarget = nil
                let availability = islandAvailability()
                if let adjusted = HUDStyleResolver.whileIslandHidden(style, availability: availability) {
                    if adjusted != style { allowsCompact = false }
                    style = adjusted
                } else {
                    // Hidden with no band: macOS's pop-up shows, unless SparkV
                    // swallowed the key; then the pill, so there's feedback.
                    style = interceptor.isActive ? .pill : .hidden
                }
            }
        }
        presented[id] = Presentation(content: content, kind: kind, duration: duration, style: style, screen: screen, allowsCompact: allowsCompact)
        if let shown = presented[id] { show(shown, id: id) }
        if Date() < announceUntil { announce(content) }
    }

    /// Draws a presentation as is (also when holding it or moving its level).
    private func show(_ shown: Presentation, id: String) {
        let content = shown.content
        let style = shown.style
        let duration = shown.duration
        let screen = shown.screen
        switch style {
        case .hidden:
            presented[id] = nil
            activities.dismiss(id: id)
        case .inline, .ring, .band:
            if overlay.isShowing { overlay.hide(animated: false) }
            activities.post(islandActivity(content, id: id, kind: shown.kind, duration: duration, style: style, allowsCompact: shown.allowsCompact))
        case .pill, .edgeBar:
            activities.dismiss(id: id)
            let target = screen.flatMap(displays.nsScreen(for:)) ?? islandScreen() ?? NSScreen.main
            guard let target else { return }
            overlay.show(content, style: style, on: target, edge: settings.edge, showsPercent: settings.showsPercent, duration: duration)
        }
    }

    /// The island form of a HUD in `style` (internal for the render harness).
    func islandActivity(_ content: HUDContent, id: String, kind: LiveActivity.Kind, duration: TimeInterval, style: HUDStyle, allowsCompact: Bool) -> LiveActivity {
        let showsPercent = settings.showsPercent
        let band = LiveActivity(id: id, kind: kind, priority: 90, duration: duration) {
            HUDActivityView(content: content, showsPercent: showsPercent)
        }
        // An output switch has a name to read: always the band.
        guard allowsCompact else { return band }
        // Inline OSD beside the camera housing (boring.notch style): the
        // level never covers what is under the menu bar. The band style keeps
        // the same wings for when dictation or Clicky holds the band.
        let compact = band.compact {
            HUDWingIcon(content: content)
        } trailing: {
            if style == .ring {
                HUDWingRing(content: content, showsPercent: showsPercent)
            } else {
                HUDWingLevel(content: content, showsPercent: showsPercent)
            }
        }
        return style == .band ? compact.presentation(.expanded) : compact
    }

    /// The id of the HUD on the island right now (band first), if any.
    private func islandHUDID() -> String? {
        switch islandPlacement() {
        case .band: activities.current?.id
        case .wings: activities.compact?.id
        case nil: nil
        }
    }

    /// Where the HUD is on the island right now.
    private func islandPlacement() -> HUDPlacement? {
        let ids = [Self.volumeActivityID, Self.brightnessActivityID]
        if let id = activities.current?.id, ids.contains(id) { return .band }
        if let id = activities.compact?.id, ids.contains(id) { return .wings }
        return nil
    }

    /// VoiceOver loses macOS's spoken level when SparkV replaces the pop-up:
    /// announce the settled level instead.
    private func announce(_ content: HUDContent) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        // A HUD held on screen re-posts the same level: say it once.
        let text = content.accessibilityText
        guard text != lastAnnouncement else { return }
        lastAnnouncement = text
        announceTask?.cancel()
        announceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    // MARK: - Interaction

    private func connectInteraction() {
        interaction.placement = { [weak self] in self?.islandPlacement() }
        interaction.target = { [weak self] in self?.interactionTarget() }
        interaction.setLevel = { [weak self] level in self?.setInteractiveLevel(level) }
        interaction.commit = { [weak self] in self?.commitInteractiveLevel() }
        interaction.toggleMute = { [weak self] in self?.toggleMute() }
        interaction.hold = { [weak self] in self?.holdHUD() }
        interaction.onActiveChange = { [weak self] active in
            if active { self?.startHolding() } else { self?.stopHolding() }
        }
    }

    /// What the HUD on the island controls.
    private func interactionTarget() -> HUDInteractionController.Target? {
        switch islandHUDID() {
        case Self.volumeActivityID:
            guard let state = lastAudio, let volume = state.volume else { return nil }
            return .volume(level: Double(volume), muted: state.isMuted)
        case Self.brightnessActivityID:
            guard let display = brightnessDisplay, let value = lastBrightness[display] ?? brightness.read(display) else { return nil }
            return .brightness(display: display, level: Double(value))
        default:
            return nil
        }
    }

    /// A drag or scroll set the level. The bar follows at once (through
    /// `HUDPointerState.liveLevel` while dragging); the hardware write is
    /// coalesced to ~30 Hz and the island re-posted at most ~10 times a second.
    private func setInteractiveLevel(_ level: Double) {
        let value = min(1, max(0, level))
        announceUntil = Date().addingTimeInterval(1)
        guard let target = interactionTarget() else { return }
        if interaction.pointer.isDragging { interaction.pointer.setLiveLevel(value, brightness: target.isBrightness) }
        pendingLevel = value
        // Optimistic, so the next scroll step and the hardware echo agree.
        switch target {
        case .volume:
            if var state = lastAudio {
                state.volume = Float(value)
                if state.isMuted, value > 0 { state.isMuted = false }
                lastAudio = state
            }
        case .brightness(let display, _):
            lastBrightness[display] = Float(value)
        }
        let wait = Self.writeInterval - Date().timeIntervalSince(lastLevelWrite)
        if wait <= 0 {
            writePendingLevel()
        } else if writeTask == nil {
            writeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.writeTask = nil
                self.writePendingLevel()
            }
        }
    }

    /// The button went up: write and draw the final value now.
    private func commitInteractiveLevel() {
        writeTask?.cancel()
        writeTask = nil
        writePendingLevel()
        if let id = islandHUDID() { repost(id, now: true) }
    }

    private func writePendingLevel() {
        guard let value = pendingLevel else { return }
        pendingLevel = nil
        lastLevelWrite = Date()
        switch interactionTarget() {
        case .volume:
            let unmute = value > 0
            Self.audioWriteQueue.async {
                guard let device = HUDVolumeControl.defaultOutput(), HUDVolumeControl.canSetVolume(device) else { return }
                HUDVolumeControl.setVolume(device, Float(value))
                if unmute, HUDVolumeControl.isMuted(device) { HUDVolumeControl.setMuted(device, false) }
            }
            updatePresented(Self.volumeActivityID, level: value, muted: lastAudio?.isMuted ?? false)
        case .brightness(let display, _):
            brightness.write(Float(value), to: display)
            HUDBrightnessFeed.shared.report(Float(value), display: display)
            updatePresented(Self.brightnessActivityID, level: value, muted: nil)
        case nil:
            break
        }
    }

    /// Moves a shown HUD's level without re-deciding its form.
    private func updatePresented(_ id: String, level: Double?, muted: Bool?) {
        guard var shown = presented[id] else { return }
        shown.content = shown.content.with(level: level, muted: muted)
        presented[id] = shown
        repost(id, now: false)
    }

    /// Re-posts a presentation, at most every `repostInterval` unless `now`.
    private func repost(_ id: String, now: Bool) {
        let wait = Self.repostInterval - Date().timeIntervalSince(lastRepost)
        if now || wait <= 0 {
            repostTask?.cancel()
            repostTask = nil
            lastRepost = Date()
            if let shown = presented[id] { show(shown, id: id) }
        } else if repostTask == nil {
            repostTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.repostTask = nil
                self.lastRepost = Date()
                if let shown = self.presented[id] { self.show(shown, id: id) }
            }
        }
    }

    private func toggleMute() {
        announceUntil = Date().addingTimeInterval(1)
        Self.audioWriteQueue.async {
            guard let device = HUDVolumeControl.defaultOutput() else { return }
            HUDVolumeControl.setMuted(device, !HUDVolumeControl.isMuted(device))
            // The mute listener posts the HUD.
        }
    }

    /// Restarts the time of the HUD on the island, exactly as it shows.
    private func holdHUD() {
        guard let id = islandHUDID() else { return }
        repost(id, now: true)
    }

    /// While the pointer is on the HUD it stays up: one task re-arms it just
    /// before it would expire (only while the pointer is there, at most 30 s
    /// without a move, like a hovered band).
    private func startHolding() {
        guard holdTask == nil else { return }
        let period = max(0.5, Self.hudDuration - 0.4)
        holdTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < 30 {
                try? await Task.sleep(for: .seconds(period))
                guard !Task.isCancelled, let self, self.interaction.isActive else { return }
                self.holdHUD()
            }
        }
    }

    private func stopHolding() {
        holdTask?.cancel()
        holdTask = nil
    }

    // MARK: - Volume

    private func handleAudio(_ change: AudioOutputMonitor.Change) {
        guard isMonitoring else { return }
        switch change {
        case .initial(let state):
            // Startup read: remember, never show.
            lastAudio = state
        case .deviceChanged(let state):
            let previous = lastAudio
            lastAudio = state
            guard previous != nil, previous?.deviceID != state.deviceID else { return }
            deviceCaptionUntil = Date().addingTimeInterval(Self.deviceDuration)
            postDevice(state)
        case .volumeChanged(let state, let forced):
            let previous = lastAudio
            lastAudio = state
            guard previous != nil else { return }
            if !forced, previous?.volume == state.volume, previous?.isMuted == state.isMuted { return }
            postVolume(state)
        }
    }

    /// The screen the volume HUD shows on: the one with the pointer, or the island's.
    private func volumeScreen() -> HUDScreenInfo? {
        settings.showsOnPointerDisplay ? displays.screenUnderPointer() : nil
    }

    private func postVolume(_ state: AudioOutputMonitor.State) {
        lastVolumePost = Date()
        // Under the pointer: keep its form (a device band stays a band) and
        // move only the level and mute state.
        if interaction.isActive, islandHUDID() == Self.volumeActivityID, presented[Self.volumeActivityID] != nil {
            updatePresented(Self.volumeActivityID, level: state.volume.map(Double.init), muted: state.isMuted)
            return
        }
        let caption = Date() < deviceCaptionUntil ? state.name : nil
        let content = HUDContent(
            style: .volume(muted: state.isMuted, deviceName: caption),
            level: state.volume.map(Double.init)
        )
        let screen = volumeScreen()
        present(content, id: Self.volumeActivityID, kind: .volume, duration: Self.hudDuration, style: resolvedStyle(on: screen), screen: screen)
    }

    private func postDevice(_ state: AudioOutputMonitor.State) {
        lastVolumePost = Date()
        let content = HUDContent(
            style: .outputDevice(name: state.name, transport: state.transport, muted: state.isMuted),
            level: state.volume.map(Double.init)
        )
        let screen = volumeScreen()
        let style = resolvedStyle(on: screen)
        // On the island an output switch always uses the band (a name to read).
        present(content, id: Self.volumeActivityID, kind: .volume, duration: Self.deviceDuration,
                style: style.usesIsland ? .band : style, screen: screen, allowsCompact: false)
    }

    /// A volume key was pressed. Normally CoreAudio reports the new level
    /// right away; at 0 % or 100 % nothing changes, so show the level anyway.
    private func volumeKeyPressed() {
        let pressedAt = Date()
        volumeKeyTask?.cancel()
        volumeKeyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.isMonitoring else { return }
            if self.lastVolumePost < pressedAt { self.audio?.refresh(forced: true) }
        }
    }

    // MARK: - Brightness

    /// Subscribes to every display DisplayServices can drive and reads their
    /// levels (startup reads are never shown).
    private func registerBrightness() {
        displays.refresh()
        let controllable = displays.controllableDisplays
        brightness.registerForChanges(controllable, callback: brightnessChangeCallback)
        var levels: [CGDirectDisplayID: Float] = [:]
        for display in controllable {
            if let value = brightness.read(display) {
                levels[display] = value
                HUDBrightnessFeed.shared.report(value, display: display)
            }
        }
        lastBrightness = levels
        brightnessSamples = brightnessSamples.filter { controllable.contains($0.key) }
    }

    /// DisplayServices change notification (user, keys, Control Center or
    /// auto-brightness) for `display`, or for an unknown one.
    fileprivate func brightnessNotified(display: CGDirectDisplayID?) {
        guard isMonitoring else { return }
        if let display, brightness.registered.contains(display) {
            sampleBrightness(display, forced: false)
        } else {
            brightness.registered.forEach { sampleBrightness($0, forced: false) }
        }
    }

    private func screensChanged() {
        guard isMonitoring else { return }
        // Display IDs change on reconnect: subscribe afresh.
        registerBrightness()
    }

    /// A brightness key. `handled` is the display SparkV just set; nil when
    /// only listening (macOS or a display tool handled the key).
    private func brightnessKeyPressed(handled: CGDirectDisplayID?) {
        let target: CGDirectDisplayID?
        if let handled {
            target = handled
        } else if case .apply(let display) = interceptor.brightnessRoute() {
            target = display
        } else {
            // The key went to a display tool, or to macOS for a monitor
            // SparkV can't read: no level to show.
            target = nil
        }
        brightnessKeyUntil = Date().addingTimeInterval(1.2)
        guard let target else { return }
        let pressedAt = Date()
        forcedBrightnessTask?.cancel()
        if handled != nil {
            // Show the level right away (it may already be at a limit).
            sampleBrightness(target, forced: true)
        } else {
            // Listening only: macOS may have changed another display; if no
            // change arrives, show this one's level (at a limit).
            forcedBrightnessTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.isMonitoring, self.lastBrightnessPost < pressedAt else { return }
                self.sampleBrightness(target, forced: true)
            }
        }
        // Follow the system's smooth ramp for a second.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.isMonitoring else { return }
                self.sampleBrightness(target, forced: false)
            }
        }
    }

    private func sampleBrightness(_ display: CGDirectDisplayID, forced: Bool) {
        guard let value = brightness.read(display) else { return }
        let now = Date()
        let previous = lastBrightness[display]
        lastBrightness[display] = value
        HUDBrightnessFeed.shared.report(value, display: display)

        var samples = brightnessSamples[display] ?? []
        samples.append((now, value))
        samples.removeAll { now.timeIntervalSince($0.time) > 1 }
        brightnessSamples[display] = samples

        // First read of a display is never shown.
        guard let previous else { return }
        let changed = abs(value - previous) > 0.001
        guard forced || changed else { return }

        if !forced, now >= brightnessKeyUntil, !interaction.isActive {
            // No brightness key just now: show it only for a quick, deliberate
            // change (Control Center slider), not auto-brightness drifting.
            guard Self.isDeliberateChange(samples: samples, now: now) else { return }
        }
        // A display tool handling this display shows its own OSD.
        if let facts = displays.facts(for: display),
           !HUDBrightnessRouter.showsHUD(for: facts, displayAppRunning: displayApps.isRunning,
                                         stepAside: settings.stepAsideForDisplayApps,
                                         appsHandleBuiltIn: settings.displayAppsHandleBuiltIn) {
            return
        }
        postBrightness(value, display: display)
    }

    /// True when the level moved by at least 4 % within the last half second.
    /// Auto-brightness ramps far slower than that.
    static func isDeliberateChange(samples: [(time: Date, value: Float)], now: Date) -> Bool {
        guard let current = samples.last?.value else { return false }
        return samples.contains { now.timeIntervalSince($0.time) <= 0.5 && abs($0.value - current) >= 0.04 }
    }

    /// The display's name when more than one screen is connected and it isn't
    /// the built-in panel ("Studio Display").
    private func brightnessCaption(for display: CGDirectDisplayID?) -> String? {
        guard let display, displays.screens.count > 1, let screen = displays.screen(for: display), !screen.facts.isBuiltin else { return nil }
        return screen.name
    }

    private func postBrightness(_ value: Float, display: CGDirectDisplayID) {
        lastBrightnessPost = Date()
        if interaction.isActive, islandHUDID() == Self.brightnessActivityID, display == brightnessDisplay,
           presented[Self.brightnessActivityID] != nil {
            updatePresented(Self.brightnessActivityID, level: Double(value), muted: nil)
            return
        }
        brightnessDisplay = display
        let content = HUDContent(style: .brightness, level: Double(value), caption: brightnessCaption(for: display))
        // On the display being changed.
        let screen = displays.screen(for: display)
        present(content, id: Self.brightnessActivityID, kind: .brightness, duration: Self.hudDuration, style: resolvedStyle(on: screen), screen: screen)
    }

    // MARK: - Keys

    /// Listens (never swallows) for the media keys: brightness up/down and
    /// volume up/down/mute. The system OSD still appears as usual.
    /// Re-callable: replaces existing monitors (a global monitor added before
    /// an Accessibility grant may stay deaf).
    private func startKeyMonitors() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        let mask: NSEvent.EventTypeMask = [.systemDefined]
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let key = SystemKeyEvent(event) else { return }
            MainActor.assumeIsolated { self?.handleKey(key) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let key = SystemKeyEvent(event) {
                MainActor.assumeIsolated { self?.handleKey(key) }
            }
            return event
        }
    }

    private func handleKey(_ key: SystemKeyEvent) {
        guard isMonitoring, key.isKeyDown else { return }
        switch key.keyCode {
        case SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown:
            brightnessKeyPressed(handled: nil)
        case SystemKeyEvent.soundUp, SystemKeyEvent.soundDown, SystemKeyEvent.mute:
            volumeKeyPressed()
        default:
            break
        }
    }
}

// MARK: - Media key decoding

/// An NX_SUBTYPE_AUX_CONTROL_BUTTONS system-defined event (media keys).
struct SystemKeyEvent: Equatable, Sendable {
    static let soundUp = 0       // NX_KEYTYPE_SOUND_UP
    static let soundDown = 1     // NX_KEYTYPE_SOUND_DOWN
    static let brightnessUp = 2  // NX_KEYTYPE_BRIGHTNESS_UP
    static let brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    static let mute = 7          // NX_KEYTYPE_MUTE
    /// Keyboard backlight keys (Intel MacBooks, some keyboards). SparkV never
    /// handles them: there's no public API for the backlight level.
    static let illuminationUp = 21     // NX_KEYTYPE_ILLUMINATION_UP
    static let illuminationDown = 22   // NX_KEYTYPE_ILLUMINATION_DOWN
    static let illuminationToggle = 23 // NX_KEYTYPE_ILLUMINATION_TOGGLE

    let keyCode: Int
    let isKeyDown: Bool
    let isRepeat: Bool

    /// Decodes `data1`: key code in the high 16 bits, state (0xA down,
    /// 0xB up) in bits 8–15, repeat flag in bit 0.
    init?(subtype: Int16, data1: Int) {
        guard subtype == 8 else { return nil }
        keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        isKeyDown = state == 0xA
        isRepeat = flags & 0x1 != 0
    }

    init?(_ event: NSEvent) {
        guard event.type == .systemDefined else { return nil }
        self.init(subtype: event.subtype.rawValue, data1: event.data1)
    }
}

// MARK: - Brightness change notifications

/// C callback for DisplayServices; the thread it runs on isn't documented, so
/// hop to the main queue and re-read there. The observer is the display ID
/// (see `HUDDisplayBrightness.registerForChanges`).
private let brightnessChangeCallback: CFNotificationCallback = { _, observer, _, _, _ in
    let display = HUDDisplayBrightness.display(fromObserver: observer)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HUDController.brightnessTarget?.brightnessNotified(display: display) }
    }
}

// MARK: - Volume (CoreAudio)

/// Watches the default output device's volume, mute and identity. All
/// CoreAudio work happens on a private serial queue.
final class AudioOutputMonitor: @unchecked Sendable {
    struct State: Equatable, Sendable {
        var deviceID: AudioObjectID
        var name: String
        var transport: HUDOutputTransport
        /// 0...1; nil when the device has no volume control.
        var volume: Float?
        var isMuted: Bool
    }

    enum Change: Sendable {
        case initial(State)
        case deviceChanged(State)
        case volumeChanged(State, forced: Bool)
    }

    private let queue = DispatchQueue(label: "SparkV.HUD.audio", qos: .userInitiated)
    private let onChange: @Sendable (Change) -> Void

    // Queue-confined.
    private var running = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceAddresses: [AudioObjectPropertyAddress] = []
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    init(onChange: @escaping @Sendable (Change) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.defaultDeviceChanged()
            }
            defaultDeviceBlock = block
            var address = Self.defaultOutputAddress
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status != noErr { AppLog.log("HUD: default output listener failed (\(status))") }
            attach(to: Self.defaultOutputDevice())
            if let state = readState() { onChange(.initial(state)) }
        }
    }

    /// Synchronous so listeners are gone before the app quits.
    func stop() {
        queue.sync { [self] in
            guard running else { return }
            running = false
            detach()
            if let block = defaultDeviceBlock {
                var address = Self.defaultOutputAddress
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
            defaultDeviceBlock = nil
        }
    }

    /// Re-reads the level and reports it even if nothing changed.
    func refresh(forced: Bool) {
        queue.async { [self] in
            guard running, let state = readState() else { return }
            onChange(.volumeChanged(state, forced: forced))
        }
    }

    // MARK: Queue-confined

    private func defaultDeviceChanged() {
        guard running else { return }
        let newDevice = Self.defaultOutputDevice()
        guard newDevice != device else { return }
        attach(to: newDevice)
        if let state = readState() { onChange(.deviceChanged(state)) }
    }

    private func deviceChanged() {
        guard running, let state = readState() else { return }
        onChange(.volumeChanged(state, forced: false))
    }

    private func attach(to newDevice: AudioObjectID) {
        detach()
        device = newDevice
        guard newDevice != kAudioObjectUnknown else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceChanged()
        }
        deviceBlock = block
        let candidates: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyVolumeScalar, 2),
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyMute, 1),
            (kAudioDevicePropertyMute, 2),
        ]
        for (selector, element) in candidates {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(newDevice, &address) else { continue }
            if AudioObjectAddPropertyListenerBlock(newDevice, &address, queue, block) == noErr {
                deviceAddresses.append(address)
            }
        }
    }

    private func detach() {
        if let block = deviceBlock, device != kAudioObjectUnknown {
            for var address in deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            }
        }
        deviceAddresses = []
        deviceBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func readState() -> State? {
        guard device != kAudioObjectUnknown else { return nil }
        return State(
            deviceID: device,
            name: Self.name(of: device) ?? "Output",
            transport: Self.transport(of: device),
            volume: Self.volume(of: device),
            isMuted: Self.isMuted(device)
        )
    }

    // MARK: Property reads

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func volume(of device: AudioObjectID) -> Float? {
        if let main = scalar(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return min(1, max(0, main))
        }
        let channels = [1, 2].compactMap { scalar(device, kAudioDevicePropertyVolumeScalar, AudioObjectPropertyElement($0)) }
        guard !channels.isEmpty else { return nil }
        return min(1, max(0, channels.reduce(0, +) / Float(channels.count)))
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value != 0 }
        }
        return false
    }

    private static func scalar(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
        return value
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        let string = name.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func transport(of device: AudioObjectID) -> HUDOutputTransport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        default: return .other
        }
    }
}
