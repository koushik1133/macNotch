import AppKit
import Combine
import QuartzCore

/// Ambient Light's coordinator: listens to the media engine and the
/// settings, starts system-audio capture only while music plays and the
/// feature is on, and drives the notch glow and the screen edges from one
/// display link.
///
/// "Music plays" means either Now Playing says so, or the analyzer itself
/// hears sound: browsers (YouTube in Chrome, some Safari players) often
/// report no Now Playing state, or report "paused" between videos. When
/// capture is stopped, `AmbientOutputActivityMonitor` (a Core Audio property
/// listener, no IO) notices any app starting playback and starts a short
/// capture probe; capture then stays on while sound is heard and stops
/// `idleGrace` seconds after both signals go quiet.
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
    /// Last beat that tapped the trackpad (Music Haptics).
    private var lastFeltBeat: UInt64 = 0
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
    /// Any app playing through the default output (starts capture probes).
    private let outputActivity = AmbientOutputActivityMonitor()
    /// Capture was started by output activity; until this time it may run
    /// without Now Playing or heard sound (time to hear the music).
    private var probeUntil: Double = 0
    private var probeTask: Task<Void, Never>?
    /// The last probe heard nothing (an app holding a silent stream, a
    /// notification sound): no new probe for `probeCooldown` seconds.
    private var lastFruitlessProbe: Double = -1_000
    /// Last display frame that was live with music (picks the stop grace).
    private var lastLiveAt: Double = -1_000
    /// A "live" line was logged and no "idle" line yet.
    private var loggedLive = false
    private var loggedSilentTap = false
    /// Asleep or another user's session: no probes.
    private var suspended = false
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
        engine.onAudibleChange = { [weak self] _ in self?.evaluate(userInitiated: false) }
        outputActivity.onChange = { [weak self] running in self?.outputActivityChanged(running) }
        observeSystem()
        rebuildPalette()
        updateOutputMonitor()
        prewarmEdgesIfNeeded()
    }

    /// Compiles the screen-edge shader in the background as soon as the
    /// edges are in use, so the first light never compiles on the main thread.
    private func prewarmEdgesIfNeeded() {
        if settings.isActive, settings.scope == .notchAndEdges { AmbientEdgeGPU.prewarm() }
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

    /// Seconds a probe may run before it must have heard something.
    private static let probeWindow: Double = 6
    private static let probeCooldown: Double = 20
    /// Capture keeps running this long after music stops (Now Playing
    /// paused / nil and nothing heard). Gaps between YouTube videos or
    /// tracks, ads and short pauses used to stop and restart the tap every
    /// 1–3 minutes (1.5 s grace); an idle tap on silence costs ~1 % of a core.
    private static let idleGrace: Double = 12
    /// Grace when the light wasn't live recently (a probe that heard nothing).
    private static let shortGrace: Double = 2

    private var wantsCapture: Bool {
        settings.isActive && (isPlaying || engine.isHearingAudio || CACurrentMediaTime() < probeUntil)
    }

    /// Lit by music: capture runs and Now Playing reports playback or the
    /// analyzer hears sound from any app.
    private var isMusicLive: Bool {
        settings.isActive && engine.isRunning && (isPlaying || engine.isHearingAudio)
    }

    private func updateOutputMonitor() {
        if settings.isActive {
            if !outputActivity.isMonitoring { outputActivity.start() }
        } else if outputActivity.isMonitoring {
            outputActivity.stop()
            probeTask?.cancel()
            probeTask = nil
            probeUntil = 0
        }
    }

    /// Some app started playing through the output. Only acted on while
    /// capture is stopped (SparkV's own tap also runs the device).
    private func outputActivityChanged(_ running: Bool) {
        guard running, settings.isActive, !suspended, !isPlaying,
              !engine.isRunning, startTask == nil else { return }
        let now = CACurrentMediaTime()
        guard now - lastFruitlessProbe >= Self.probeCooldown else { return }
        beginProbe(now: now)
    }

    private func beginProbe(now: Double) {
        probeUntil = now + Self.probeWindow
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.probeWindow + 0.1))
            guard let self, !Task.isCancelled else { return }
            self.probeTask = nil
            if !self.engine.isHearingAudio, !self.isPlaying { self.lastFruitlessProbe = CACurrentMediaTime() }
            self.evaluate(userInitiated: false)
        }
        evaluate(userInitiated: false)
    }

    private func playingChanged(_ playing: Bool) {
        isPlaying = playing
        evaluate(userInitiated: false)
    }

    private func settingsChanged() {
        // objectWillChange fires before the new value is stored.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.wantsNotchOutset != self.settings.isActive { self.wantsNotchOutset = self.settings.isActive }
            let paletteKey = "\(self.settings.palette.rawValue)-\(self.settings.syncToAlbumColors)-\(self.settings.customColor)"
            if paletteKey != self.paletteKey { self.rebuildPalette() }
            if self.settings.edgeWidth != self.laidOutEdgeWidth {
                self.laidOutEdgeWidth = self.settings.edgeWidth
                self.edges.relayout()
            }
            self.updateFrameRate()
            self.updateOutputMonitor()
            self.prewarmEdgesIfNeeded()
            self.evaluate(userInitiated: false)
        }
    }

    private func evaluate(userInitiated: Bool) {
        if wantsCapture {
            stopTask?.cancel()
            stopTask = nil
            if !engine.isRunning, startTask == nil {
                startCapture(userInitiated: userInitiated)
            } else if engine.isRunning, isMusicLive {
                // Music came back during the stop grace (or is heard
                // without Now Playing): capture is already running.
                if case .running = status {} else { status = .running(source: engine.sourceName ?? backend.rawValue) }
            }
            startLink()
        } else {
            if !settings.isActive { status = .off }
            else if case .needsPermission = status {} else { status = .waitingForMusic }
            guard engine.isRunning || startTask != nil, stopTask == nil else { return }
            // Track gaps, ads and short pauses keep the tap (restarting costs
            // a tap + aggregate rebuild and drops the first beats).
            let recentlyLive = CACurrentMediaTime() - lastLiveAt < 30
            let grace = settings.isActive ? (recentlyLive ? Self.idleGrace : Self.shortGrace) : 0.05
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
                // A probe start isn't "running" until it hears music.
                self.status = self.isMusicLive ? .running(source: self.engine.sourceName ?? chosen.rawValue) : .waitingForMusic
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
                        self.status = self.isMusicLive ? .running(source: self.engine.sourceName ?? "Screen Capture Audio") : .waitingForMusic
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
        let wasHearing = engine.isHearingAudio
        AppLog.log("AmbientLight: output device changed; restarting capture")
        haltCapture()
        // Audio-only music (no Now Playing): the restarted tap needs a probe
        // window to hear it again.
        if wasHearing, !isPlaying {
            beginProbe(now: CACurrentMediaTime())
        } else {
            evaluate(userInitiated: false)
        }
    }

    /// Only zeros from the tap while music plays: macOS is withholding the
    /// audio (System Audio Recording off). Switch to ScreenCaptureKit when
    /// that's already allowed, otherwise say so in Settings.
    private func digitalSilenceChanged(_ silent: Bool) {
        guard silent, isPlaying, backend == .processTap, engine.isRunning else { return }
        let state = AmbientAudioPermission.preflight()
        guard state != .granted else { return } // genuinely silent
        if PermissionCenter.shared.isGranted(.screenRecording) {
            // Logged once: the backend stays .screenCapture from here on.
            AppLog.log("AmbientLight: tap delivers silence (System Audio Recording \(state.rawValue)); switching to screen capture audio")
            backend = .screenCapture
            haltCapture()
            evaluate(userInitiated: false)
        } else {
            if !loggedSilentTap {
                loggedSilentTap = true
                AppLog.log("AmbientLight: tap delivers silence (System Audio Recording \(state.rawValue)) and Screen Recording isn't granted; needs permission")
            }
            status = .needsPermission
        }
    }

    // MARK: Colors

    private var paletteKey = ""
    private var laidOutEdgeWidth: Double = -1

    private func rebuildPalette() {
        paletteKey = "\(settings.palette.rawValue)-\(settings.syncToAlbumColors)-\(settings.customColor)"
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
            // 60 is smooth for light; 120 on ProMotion doubled the GPU cost.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
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
        let musicLive = isMusicLive
        if musicLive {
            lastLiveAt = now
            if !loggedLive {
                loggedLive = true
                let why = isPlaying ? (engine.isHearingAudio ? "Now Playing + audio" : "Now Playing") : "audio heard, no Now Playing"
                AppLog.log("AmbientLight: live (\(why), \(engine.sourceName ?? backend.rawValue), \(settings.mode.rawValue), \(settings.scope.rawValue))")
            }
        }
        let live = musicLive || (previewing && settings.isEnabled)
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
        if live, settings.beatHaptics { feelBeat(features) }

        if choreographer.isDark, !live {
            logIdle()
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

    /// Music Haptics (optional): one tap per detected beat, firmer on bass
    /// hits. Reuses the analyzer's beat counter, so it costs nothing extra.
    private func feelBeat(_ features: AmbientAudioFeatures) {
        guard features.beatCount != lastFeltBeat else { return }
        let isNewBeat = lastFeltBeat != 0
        lastFeltBeat = features.beatCount
        guard isNewBeat, !features.isSilent, CACurrentMediaTime() - features.lastBeatTime < 0.25 else { return }
        SparkVHaptics.play(features.bass > 0.6 ? .boundary : .detent)
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

    private func logIdle() {
        guard loggedLive else { return }
        loggedLive = false
        AppLog.log("AmbientLight: idle (no music; capture \(engine.isRunning ? "stops after grace" : "stopped"))")
    }

    // MARK: System

    private func suspendForSystem() {
        suspended = true
        probeTask?.cancel()
        probeTask = nil
        probeUntil = 0
        logIdle()
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
            MainActor.assumeIsolated {
                self?.suspended = false
                self?.evaluate(userInitiated: false)
            }
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
            MainActor.assumeIsolated {
                self?.suspended = false
                self?.evaluate(userInitiated: false)
            }
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
