import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Live level bars beside the closed notch, driven by the real sound.
///
/// One capture at most: when Ambient Light's engine is actually delivering
/// (`ambientFeatures` returns data; wired by the integrator), its analyser
/// output is read, at 30 fps or 15 fps in Low Power Mode / when hot;
/// otherwise, only while "Live Bars" is on, music plays and the bars are on
/// screen, this starts Ambient Light's own engine (process tap + FFT). That
/// own capture stops on pause, when the wings hide, in Low Power Mode, when
/// the Mac runs hot, on sleep and when the screens sleep. Without signal
/// (digital silence, nothing captured yet) the bars stand still and no
/// frame timeline runs. Starting a tap is what may show macOS's
/// System Audio Recording prompt, so it only happens after the user turned
/// the toggle on (that click asks).
@MainActor
final class MediaVisualizerController: ObservableObject {
    static let shared = MediaVisualizerController()

    enum Status: Equatable {
        case off
        /// Reading Ambient Light's capture.
        case sharingAmbientLight
        case capturing
        case waiting
        case needsPermission
        case paused(String)
    }

    /// Ambient Light's live features while its capture runs, nil otherwise.
    /// Set by the integrator: `{ AmbientLightController.shared.liveFeatures }`.
    var ambientFeatures: (@MainActor () -> AmbientAudioFeatures?)?

    @Published private(set) var status: Status = .off
    /// The capture delivers sound right now. False during digital silence:
    /// the bars then stand still instead of redrawing flat values.
    @Published private(set) var hasSignal = false

    private let settings = MediaPlusSettings.shared
    private var engine: AmbientAudioEngine?
    private weak var media: MediaEngine?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var visibleBars = 0
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var thermalHot = false
    private var screensAsleep = false
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var hasStartedOnce = UserDefaults.standard.bool(forKey: "MediaVisualizer.hasStartedCapture")
    /// Consecutive frames without signal (the timeline switches itself off).
    private var silentFrames = 0
    /// While live but silent: one look per second for sound coming back.
    private var signalTask: Task<Void, Never>?
    /// Ambient Light is on but its engine isn't delivering yet: wait this
    /// long before starting our own capture (avoids two taps at its start).
    private var ambientGraceTask: Task<Void, Never>?
    private var ambientGraceUntil: Date?

    func start(media: MediaEngine) {
        self.media = media
        cancellables.removeAll()
        media.$isPlaying.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.evaluate() } }
            .store(in: &cancellables)
        settings.$liveBars.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.evaluate() } }
            .store(in: &cancellables)
        AmbientLightSettings.shared.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.evaluate() } }
            .store(in: &cancellables)
        observeSystem()
        evaluate()
    }

    func stop() {
        cancellables.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        halt()
        status = .off
        setSignal(false)
    }

    /// From the toggle: turning it on is the click that may ask macOS.
    func setLiveBars(_ on: Bool) {
        settings.liveBars = on
        guard on else { evaluate(); return }
        switch AmbientAudioPermission.preflight() {
        case .granted:
            evaluate(userInitiated: true)
        case .denied:
            status = .needsPermission
        case .notDetermined:
            Task {
                let answer = await AmbientAudioPermission.request()
                self.status = answer == .denied ? .needsPermission : .waiting
                self.evaluate(userInitiated: true)
            }
        case .unknown:
            evaluate(userInitiated: true)
        }
    }

    func barsAppeared() {
        visibleBars += 1
        evaluate()
    }

    func barsDisappeared() {
        visibleBars = max(0, visibleBars - 1)
        evaluate()
    }

    /// Bar heights for this frame, or nil when there is no sound to show.
    /// Called from the bars' frame timeline; after a few silent frames it
    /// turns the timeline off (`hasSignal`) and checks once a second instead.
    func liveBars() -> [Double]? {
        guard settings.liveBars, !SparkVMotion.reduceMotion else { return nil }
        let shared = ambientFeatures?()
        if shared != nil, engine?.isRunning == true || startTask != nil {
            // Ambient Light started capturing: drop our own tap.
            DispatchQueue.main.async { [weak self] in self?.evaluate() }
        }
        let features = shared ?? (engine?.isRunning == true ? engine?.mailbox.load() : nil)
        guard let features, !features.isDigitalSilence else {
            silentFrames += 1
            if silentFrames >= 8, hasSignal {
                DispatchQueue.main.async { [weak self] in self?.setSignal(false) }
            }
            return nil
        }
        silentFrames = 0
        return MediaVisualizerMath.bars(bass: features.bass, mid: features.mid, treble: features.treble, level: features.level)
    }

    /// Current features from whichever capture runs (no side effects).
    private func currentFeatures() -> AmbientAudioFeatures? {
        ambientFeatures?() ?? (engine?.isRunning == true ? engine?.mailbox.load() : nil)
    }

    private func setSignal(_ value: Bool) {
        silentFrames = 0
        if hasSignal != value { hasSignal = value }
        updateSignalWatch()
    }

    /// Live, playing and on screen but silent: one check a second for
    /// sound (the 30 fps timeline is off meanwhile). Nothing otherwise.
    private func updateSignalWatch() {
        let wanted = isLive && !hasSignal && visibleBars > 0 && (media?.isPlaying ?? false)
        guard wanted else {
            signalTask?.cancel()
            signalTask = nil
            return
        }
        guard signalTask == nil else { return }
        signalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if let features = self.currentFeatures(), !features.isDigitalSilence {
                    self.signalTask = nil
                    self.setSignal(true)
                    return
                }
            }
        }
    }

    /// Frames per second for the bars' timeline: 15 in Low Power Mode or when
    /// hot (only reachable while sharing Ambient Light's capture; our own
    /// capture pauses then).
    var frameInterval: Double { lowPower || thermalHot ? 1.0 / 15 : 1.0 / 30 }

    var isLive: Bool {
        switch status {
        case .capturing, .sharingAmbientLight: true
        default: false
        }
    }

    // MARK: Decisions

    /// What Ambient Light's capture means for us right now.
    private enum AmbientShare {
        /// Its engine delivers data: read it, never start a tap.
        case delivering
        /// It is on but not delivering (starting, waiting for permission or
        /// failed). Without the integration closure we can't tell, so we
        /// stay out of its way.
        case unknownOrStarting
        case notCapturing
    }

    private var ambientShare: AmbientShare {
        if let ambientFeatures {
            if ambientFeatures() != nil { return .delivering }
            return AmbientLightSettings.shared.isActive && ambientGraceUntil.map({ Date() < $0 }) != false
                ? .unknownOrStarting : .notCapturing
        }
        return AmbientLightSettings.shared.isActive ? .unknownOrStarting : .notCapturing
    }

    private func evaluate(userInitiated: Bool = false) {
        defer { updateSignalWatch() }
        guard settings.liveBars else {
            halt()
            status = .off
            ambientGraceUntil = nil
            return
        }
        guard let media, media.isPlaying, visibleBars > 0 else {
            scheduleHalt()
            if case .needsPermission = status {} else { status = .waiting }
            return
        }
        if screensAsleep { scheduleHalt(); status = .paused("Display asleep"); return }
        // Ambient Light on: give its engine a moment before deciding it
        // isn't capturing (then ours may start).
        if AmbientLightSettings.shared.isActive, ambientFeatures != nil {
            if ambientGraceUntil == nil { ambientGraceUntil = Date().addingTimeInterval(3) }
        } else {
            ambientGraceUntil = nil
            ambientGraceTask?.cancel()
            ambientGraceTask = nil
        }
        switch ambientShare {
        case .delivering:
            // Ambient Light's capture runs anyway: never start a second tap.
            halt()
            if status != .sharingAmbientLight { status = .sharingAmbientLight; setSignal(true) }
            return
        case .unknownOrStarting:
            halt()
            status = ambientFeatures == nil ? .paused("Ambient Light is using the audio") : .waiting
            if let until = ambientGraceUntil, ambientGraceTask == nil {
                ambientGraceTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0.1, until.timeIntervalSinceNow + 0.1)))
                    guard let self, !Task.isCancelled else { return }
                    self.ambientGraceTask = nil
                    self.evaluate()
                }
            }
            return
        case .notCapturing:
            break
        }
        if lowPower { scheduleHalt(); status = .paused("Low Power Mode"); return }
        if thermalHot { scheduleHalt(); status = .paused("Mac is running hot"); return }
        stopTask?.cancel()
        stopTask = nil
        guard engine?.isRunning != true, startTask == nil else { return }
        let permission = AmbientAudioPermission.preflight()
        let mayStart = permission == .granted || (permission == .unknown && (userInitiated || hasStartedOnce))
        guard mayStart else {
            status = .needsPermission
            return
        }
        let engine = engine ?? AmbientAudioEngine()
        self.engine = engine
        startTask = Task { [weak self] in
            do {
                try await engine.start(.processTap)
                guard let self else { engine.stop(); return }
                self.startTask = nil
                self.hasStartedOnce = true
                UserDefaults.standard.set(true, forKey: "MediaVisualizer.hasStartedCapture")
                self.status = .capturing
                self.setSignal(true)
                // Conditions may have changed while starting.
                self.evaluate()
            } catch {
                guard let self else { return }
                self.startTask = nil
                if error is CancellationError { return }
                AppLog.log("Media: live bars couldn’t capture audio: \(error.localizedDescription)")
                self.status = PermissionCenter.isCaptureDenial(error) ? .needsPermission : .paused("Couldn’t capture audio")
            }
        }
    }

    /// Short grace so track skips and wing swaps don't restart capture.
    private func scheduleHalt() {
        guard engine?.isRunning == true || startTask != nil, stopTask == nil else { return }
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.stopTask = nil
            self.halt()
        }
    }

    private func halt() {
        stopTask?.cancel()
        stopTask = nil
        startTask?.cancel()
        startTask = nil
        engine?.stop()
        signalTask?.cancel()
        signalTask = nil
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.evaluate()
            }
        }))
        observers.append((center, center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let state = ProcessInfo.processInfo.thermalState
                self?.thermalHot = state == .serious || state == .critical
                self?.evaluate()
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.evaluate()
                }
            }))
        }
    }
}

// MARK: - Bars

/// The four bars right of the notch. Live (30 fps, album-tinted if chosen)
/// while the visualizer has sound; otherwise the decorative 4 Hz bounce
/// (`CompactLevelBars`). Reduce Motion: still bars.
struct MediaLiveLevelBars: View {
    let isAnimating: Bool
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var settings = MediaPlusSettings.shared
    @ObservedObject private var visualizer = MediaVisualizerController.shared
    /// Fixed heights for offscreen renders.
    var previewLevels: [Double]? = nil

    var body: some View {
        Group {
            if let previewLevels {
                bars(previewLevels)
            } else if settings.liveBars, visualizer.isLive, isAnimating, !SparkVMotion.reduceMotion {
                if visualizer.hasSignal {
                    TimelineView(.animation(minimumInterval: visualizer.frameInterval, paused: !media.isPlaying)) { _ in
                        bars(visualizer.liveBars() ?? Self.restingLevels)
                    }
                } else {
                    // Silence: still bars, no frame timeline.
                    bars(Self.restingLevels)
                }
            } else if settings.tintsBars {
                // Decorative bounce, in the album color.
                CompactLevelBars(isAnimating: isAnimating)
                    .colorMultiply(barColor)
            } else {
                CompactLevelBars(isAnimating: isAnimating)
            }
        }
        .mpReportsOnScreen { [isPreview = previewLevels != nil] visible in
            guard !isPreview else { return }
            if visible { MediaVisualizerController.shared.barsAppeared() } else { MediaVisualizerController.shared.barsDisappeared() }
        }
        .accessibilityHidden(true)
    }

    static let restingLevels: [Double] = [0.25, 0.25, 0.25, 0.25]

    private var barColor: Color {
        guard settings.tintsBars, let tint = media.artworkTint else { return Color.white }
        return Color(nsColor: tint)
    }

    private func bars(_ levels: [Double]) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(barColor.opacity(0.9))
                    .frame(width: 2.5)
                    .scaleEffect(y: index < levels.count ? levels[index] : 0.25, anchor: .center)
            }
        }
    }
}

// MARK: - Progress under the closed island

/// A 1.5 pt line along the bottom of the closed island showing how far the
/// track is. Place it in the island's ZStack; it fills the frame and draws at
/// the bottom, inset by the bottom corner radius. Hidden while the length is
/// unknown (live streams) or the setting is off. Steps about 1 pt at a time
/// (one redraw every length / width seconds, at least 1 s apart), with no
/// animation in between; static while paused.
struct MediaClosedProgressLine: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var settings = MediaPlusSettings.shared
    var bottomRadius: CGFloat = 10
    var previewDate: Date? = nil

    var body: some View {
        if settings.showsTrackProgress, media.source != .none, media.timing.isKnown {
            let timing = media.timing
            GeometryReader { geometry in
                let inset = bottomRadius + 4
                let width = max(0, geometry.size.width - inset * 2)
                if previewDate != nil || timing.rate == 0 {
                    line(fraction: timing.progress(at: previewDate ?? Date()), width: width, in: geometry.size)
                } else {
                    TimelineView(.periodic(from: .now, by: MediaVisualizerMath.progressTick(duration: timing.duration, rate: timing.rate, width: width))) { context in
                        line(fraction: timing.progress(at: context.date), width: width, in: geometry.size)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    private func line(fraction: Double, width: CGFloat, in size: CGSize) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.14))
            Capsule().fill(tint)
                .frame(width: max(1.5, width * fraction))
        }
        .frame(width: width, height: 1.5)
        .position(x: size.width / 2, y: size.height - 2)
    }

    private var tint: Color {
        if settings.tintsBars, let tint = media.artworkTint { return Color(nsColor: tint) }
        return SparkVTheme.progressTint
    }
}
