import AppKit
import Combine
import QuartzCore

/// Ambient Light's coordinator: listens to the media engine and the
/// settings, starts system-audio capture only while music plays and the
/// feature is on, and drives the notch glow and the screen edges from one
/// display link.
///
/// Permission rules: the System Audio Recording prompt only ever appears
/// from `setEnabled(true)` / `requestAccess()` (the user's own click). An
/// automatic start (music begins) never prompts: without the grant it shows
/// "needs permission" in Settings instead. The ScreenCaptureKit fallback is
/// used only when Screen Recording is already granted (PermissionCenter).
@MainActor
final class AmbientLightController: NSObject, ObservableObject {
    static let shared = AmbientLightController()

    let settings = AmbientLightSettings.shared
    /// Slow-changing numbers for the settings view only (tempo, frame cost),
    /// kept apart so nothing else re-renders when they tick.
    let stats = AmbientLightStats()

    @Published private(set) var status: AmbientLightStatus = .off
    @Published private(set) var palette: AmbientLightPalette = .brand(.sparkV)
    /// True while the notch panel needs a glow margin (feature on).
    @Published private(set) var wantsNotchOutset = false

    /// Margin the notch panel needs on its left, right and bottom.
    var notchOutset: CGFloat { wantsNotchOutset ? NotchThemeMetrics.maxOutset : 0 }

    private let engine = AmbientAudioEngine()
    /// Live analyser output while capture runs (the Media visualizer's
    /// level bars read it instead of starting a second tap).
    var liveFeatures: AmbientAudioFeatures? { engine.isRunning ? engine.mailbox.load() : nil }
    private var choreographer = AmbientLightChoreographer()
    private var discoPalette: AmbientLightPalette = .disco(base: .brand(.sparkV))
    private let edges = AmbientScreenEdgeGlow()
    private let notchViews = NSHashTable<AmbientNotchGlowView>.weakObjects()
    private var link: CADisplayLink?
    private var cancellables: Set<AnyCancellable> = []
    private var mediaCancellables: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var isPlaying = false
    private var artwork: NSImage?
    private var backend: AmbientAudioEngine.Backend = .processTap
    private var startTask: Task<Void, Never>?
    /// Bumped whenever a start is superseded or halted, so a stale start
    /// task can neither clear a newer `startTask` nor stop a newer capture.
    private var startToken = 0
    private var stopTask: Task<Void, Never>?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var thermalHot = false

    // Frame-cost bookkeeping (published once a second).
    private var costSum: Double = 0
    private var costFrames = 0
    private var costSince: Double = 0

    override init() {
        super.init()
        wantsNotchOutset = settings.isActive
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        engine.onDigitalSilenceChange = { [weak self] silent in self?.digitalSilenceChanged(silent) }
        engine.onRouteChange = { [weak self] in self?.restartCapture() }
        observeSystem()
        rebuildPalette()
    }

    // MARK: Wiring

    /// Call once with the notch's media engine (see INTEGRATION.md).
    func attach(media: MediaEngine) {
        mediaCancellables.removeAll()
        media.$isPlaying.removeDuplicates()
            .sink { [weak self] playing in
                DispatchQueue.main.async { self?.playingChanged(playing) }
            }
            .store(in: &mediaCancellables)
        media.$artwork
            .sink { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, image !== self.artwork else { return }
                    self.artwork = image
                    self.rebuildPalette()
                }
            }
            .store(in: &mediaCancellables)
    }

    /// The user turned the feature on or off (Settings, gear menu, hub
    /// tile). Turning it on is the one moment SparkV may ask macOS for System
    /// Audio Recording.
    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if enabled {
            if settings.mode == .off { settings.mode = .ambient }
            requestAccess()
        }
    }

    /// From a user click: asks for System Audio Recording if macOS hasn't
    /// asked yet (or opens its Settings pane when denied), then starts when
    /// music is playing.
    func requestAccess() {
        let state = AmbientAudioPermission.preflight()
        if state == .denied {
            if PermissionCenter.shared.isGranted(.screenRecording) {
                backend = .screenCapture
                evaluate(userInitiated: true)
            } else {
                status = .needsPermission
                NSWorkspace.shared.open(AmbientAudioPermission.settingsURL)
            }
            return
        }
        backend = .processTap
        if isPlaying {
            evaluate(userInitiated: true)
        } else if state != .granted {
            Task { await self.askWithoutMusic(state) }
        }
    }

    /// Hides the screen edges while `suppressed` (e.g. SparkV's own screen
    /// recording, or a meeting app sharing the screen).
    func setEdgeSuppression(_ suppressed: Bool, reason: String) {
        edges.setExternalSuppression(suppressed, reason: reason)
    }

    func register(_ view: AmbientNotchGlowView) {
        notchViews.add(view)
        view.glow.invalidate()
        if link != nil { view.glow.render(choreographer.frame, palette: currentPalette(for: choreographer.frame)) }
    }

    func unregister(_ view: AmbientNotchGlowView) {
        notchViews.remove(view)
    }

    /// Previews the chosen mode for a few seconds without music (Settings).
    func preview() {
        previewUntil = CACurrentMediaTime() + 6
        startLink()
    }

    private var previewUntil: Double = 0
    private var previewBeat: UInt64 = 0

    // MARK: State

    private var wantsCapture: Bool { settings.isActive && isPlaying }

    private func playingChanged(_ playing: Bool) {
        isPlaying = playing
        evaluate(userInitiated: false)
    }

    private func settingsChanged() {
        // objectWillChange fires before the new value is stored.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.wantsNotchOutset != self.settings.isActive { self.wantsNotchOutset = self.settings.isActive }
            let paletteKey = "\(self.settings.palette.rawValue)-\(self.settings.syncToAlbumColors)"
            if paletteKey != self.paletteKey { self.rebuildPalette() }
            if self.settings.edgeWidth != self.laidOutEdgeWidth {
                self.laidOutEdgeWidth = self.settings.edgeWidth
                self.edges.relayout()
            }
            self.updateFrameRate()
            self.evaluate(userInitiated: false)
        }
    }

    private func evaluate(userInitiated: Bool) {
        if wantsCapture {
            stopTask?.cancel()
            stopTask = nil
            if !engine.isRunning, startTask == nil {
                startCapture(userInitiated: userInitiated)
            }
            startLink()
        } else {
            if !settings.isActive { status = .off }
            else if case .needsPermission = status {} else { status = .waitingForMusic }
            guard engine.isRunning || startTask != nil, stopTask == nil else { return }
            // A short grace period: skipping tracks shouldn't restart capture.
            let grace = settings.isActive ? 1.5 : 0.05
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                guard let self, !Task.isCancelled, !self.wantsCapture else { return }
                self.stopTask = nil
                self.haltCapture()
            }
        }
    }

    /// Stops capture and abandons any start in flight (never leaves a tap
    /// running behind a cancelled start).
    private func haltCapture() {
        startToken += 1
        startTask?.cancel()
        startTask = nil
        stopTask?.cancel()
        stopTask = nil
        engine.stop()
    }

    private func startCapture(userInitiated: Bool) {
        startToken += 1
        let token = startToken
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.startToken == token { self.startTask = nil } }
            guard let chosen = await self.chooseBackend(userInitiated: userInitiated) else { return }
            // Superseded or halted while the permission prompt was open.
            guard self.startToken == token, !Task.isCancelled else { return }
            do {
                try await self.engine.start(chosen)
                guard self.startToken == token else { return } // a newer start owns the engine
                if Task.isCancelled || !self.wantsCapture {
                    self.engine.stop()
                    return
                }
                if chosen == .processTap { self.settings.hasStartedCaptureOnce = true }
                self.backend = chosen
                self.status = .running(source: self.engine.sourceName ?? chosen.rawValue)
                self.startLink()
            } catch {
                if error is CancellationError || self.startToken != token || Task.isCancelled { return }
                AppLog.log("AmbientLight: \(chosen.rawValue) failed: \(error.localizedDescription)")
                if chosen == .processTap, PermissionCenter.shared.isGranted(.screenRecording) {
                    self.backend = .screenCapture
                    do {
                        try await self.engine.start(.screenCapture)
                        guard self.startToken == token else { return }
                        if Task.isCancelled || !self.wantsCapture {
                            self.engine.stop()
                            return
                        }
                        self.status = .running(source: self.engine.sourceName ?? "Screen Capture Audio")
                        self.startLink()
                        return
                    } catch {
                        if error is CancellationError || self.startToken != token { return }
                        AppLog.log("AmbientLight: screen capture fallback failed: \(error.localizedDescription)")
                    }
                }
                self.status = PermissionCenter.isCaptureDenial(error) ? .needsPermission : .failed(error.localizedDescription)
            }
        }
    }

    /// nil when capture must not start now (no grant and no user action).
    private func chooseBackend(userInitiated: Bool) async -> AmbientAudioEngine.Backend? {
        if backend == .screenCapture, PermissionCenter.shared.isGranted(.screenRecording) { return .screenCapture }
        switch AmbientAudioPermission.preflight() {
        case .granted:
            return .processTap
        case .denied:
            if PermissionCenter.shared.isGranted(.screenRecording) { return .screenCapture }
            status = .needsPermission
            return nil
        case .notDetermined:
            guard userInitiated else { status = .needsPermission; return nil }
            status = .requestingPermission
            let answer = await AmbientAudioPermission.request()
            if answer == .denied {
                if PermissionCenter.shared.isGranted(.screenRecording) { return .screenCapture }
                status = .needsPermission
                return nil
            }
            return .processTap
        case .unknown:
            // No way to read the grant: the first tap start is the prompt,
            // allowed from the user's click or once it has been shown.
            guard userInitiated || settings.hasStartedCaptureOnce else { status = .needsPermission; return nil }
            if userInitiated { status = .requestingPermission }
            return .processTap
        }
    }

    /// Turned on while nothing plays: ask now, so the prompt belongs to the
    /// click and later automatic starts are silent.
    private func askWithoutMusic(_ state: AmbientAudioPermission.State) async {
        status = .requestingPermission
        switch state {
        case .notDetermined:
            let answer = await AmbientAudioPermission.request()
            status = answer == .denied ? .needsPermission : .waitingForMusic
        case .unknown where !settings.hasStartedCaptureOnce:
            // Start and stop the tap once: that shows the system prompt.
            do {
                try await engine.start(.processTap)
                settings.hasStartedCaptureOnce = true
                try? await Task.sleep(for: .milliseconds(400))
                if !wantsCapture, startTask == nil { engine.stop() }
                if engine.isRunning, wantsCapture {
                    status = .running(source: engine.sourceName ?? "System Audio")
                    startLink()
                } else {
                    status = .waitingForMusic
                }
            } catch is CancellationError {
                status = settings.isActive ? .waitingForMusic : .off
            } catch {
                status = .failed(error.localizedDescription)
            }
        default:
            status = .waitingForMusic
        }
    }

    private func restartCapture() {
        guard engine.isRunning else { return }
        haltCapture()
        evaluate(userInitiated: false)
    }

    /// Only zeros from the tap while music plays: macOS is withholding the
    /// audio (System Audio Recording off). Switch to ScreenCaptureKit when
    /// that's already allowed, otherwise say so in Settings.
    private func digitalSilenceChanged(_ silent: Bool) {
        guard silent, isPlaying, backend == .processTap, engine.isRunning else { return }
        let state = AmbientAudioPermission.preflight()
        guard state != .granted else { return } // genuinely silent
        if PermissionCenter.shared.isGranted(.screenRecording) {
            AppLog.log("AmbientLight: tap delivers silence; switching to screen capture audio")
            backend = .screenCapture
            haltCapture()
            evaluate(userInitiated: false)
        } else {
            status = .needsPermission
        }
    }

    // MARK: Colors

    private var paletteKey = ""
    private var laidOutEdgeWidth: Double = -1

    private func rebuildPalette() {
        paletteKey = "\(settings.palette.rawValue)-\(settings.syncToAlbumColors)"
        var next = AmbientLightPalette.brand(settings.palette)
        if settings.syncToAlbumColors, let artwork, let fromArt = AmbientLightPalette.fromArtwork(artwork) {
            next = fromArt
        }
        palette = next
        discoPalette = .disco(base: next)
        for view in notchViews.allObjects { view.glow.invalidate() }
        edges.invalidate()
    }

    private func currentPalette(for frame: AmbientVisualFrame) -> AmbientLightPalette {
        frame.usesDiscoPalette ? discoPalette : palette
    }

    // MARK: Display link

    private func startLink() {
        if let link {
            link.isPaused = false
            return
        }
        let notchScreen = notchViews.allObjects.lazy.compactMap { $0.window?.screen }.first
        guard let screen = notchScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        updateFrameRate()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        edges.setShown(false)
    }

    private func updateFrameRate() {
        guard let link else { return }
        let slow = lowPower || thermalHot
        if slow {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        } else if reduceMotion {
            // A steady glow only needs frames for its fade in / out.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        } else if settings.mode == .ambient {
            // A slow breath needs no more than 60.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        } else {
            // ProMotion screens get 120 for Pulse / Disco / Wave.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let started = CACurrentMediaTime()
        let now = link.timestamp
        var features = engine.mailbox.load()
        let previewing = now < previewUntil
        if previewing, !engine.isRunning {
            features = Self.previewFeatures(now: now, beat: &previewBeat)
        }
        let live = (settings.isActive && isPlaying && engine.isRunning) || (previewing && settings.isEnabled)
        let frame = choreographer.step(.init(
            features: features,
            mode: settings.mode,
            intensity: settings.intensity,
            isLive: live,
            reduceMotion: reduceMotion,
            now: now
        ))
        let palette = currentPalette(for: frame)
        for view in notchViews.allObjects { view.glow.render(frame, palette: palette) }
        edges.setShown(settings.scope == .notchAndEdges && frame.presence > 0.001)
        edges.render(frame, palette: palette)

        if choreographer.isDark, !live {
            stopLink()
            return
        }
        // Cost of this frame's work on the main thread.
        costSum += CACurrentMediaTime() - started
        costFrames += 1
        if now - costSince >= 1 {
            stats.update(frameMicros: costSum / Double(max(1, costFrames)) * 1e6,
                         fps: Double(costFrames) / max(0.001, now - costSince),
                         bpm: features.tempoConfidence > 0.3 ? Double(features.bpm) : nil)
            costSum = 0
            costFrames = 0
            costSince = now
        }
    }

    /// A synthetic 120 BPM groove for the Settings preview.
    private static func previewFeatures(now: Double, beat: inout UInt64) -> AmbientAudioFeatures {
        let period = 0.5
        let phase = now.truncatingRemainder(dividingBy: period) / period
        let index = UInt64(now / period)
        if index != beat { beat = index }
        var f = AmbientAudioFeatures()
        f.bass = Float(exp(-phase * 6))
        f.mid = 0.5 + 0.2 * Float(sin(now * 3))
        f.treble = Float(exp(-((phase * 2).truncatingRemainder(dividingBy: 1)) * 9)) * 0.6
        f.level = 0.7
        f.beatCount = beat
        f.lastBeatTime = Double(index) * period
        f.bpm = 120
        f.tempoConfidence = 0.9
        f.isSilent = false
        f.time = now
        return f
    }

    // MARK: System

    private func suspendForSystem() {
        haltCapture()
        stopLink()
        if case .running = status { status = settings.isActive ? .waitingForMusic : .off }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.updateFrameRate()
            }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.updateFrameRate()
            }
        }))
        observers.append((center, center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let state = ProcessInfo.processInfo.thermalState
                self?.thermalHot = state == .serious || state == .critical
                self?.updateFrameRate()
            }
        }))
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendForSystem() }
        }))
        // Fast user switching / login window: this session's audio isn't
        // ours to light up; stop like for sleep, re-evaluate on return.
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendForSystem() }
        }))
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(userInitiated: false) }
        }))
        // A display link belongs to one screen: rebuild it when screens
        // change (the screen it ran on may be gone).
        observers.append((center, center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let old = self.link else { return }
                old.invalidate()
                self.link = nil
                self.startLink()
            }
        }))
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(userInitiated: false) }
        }))
    }
}

/// Numbers shown in the settings view, published at most once a second.
@MainActor
final class AmbientLightStats: ObservableObject {
    @Published private(set) var frameMicros: Double = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var bpm: Double?

    func update(frameMicros: Double, fps: Double, bpm: Double?) {
        let roundedBPM = bpm.map { $0.rounded() }
        if abs(self.frameMicros - frameMicros) > 2 { self.frameMicros = frameMicros.rounded() }
        if abs(self.fps - fps) > 1.5 { self.fps = fps.rounded() }
        if roundedBPM != self.bpm { self.bpm = roundedBPM }
    }
}
