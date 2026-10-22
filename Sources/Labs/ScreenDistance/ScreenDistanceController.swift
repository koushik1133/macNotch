import AppKit
import AVFoundation
import SwiftUI

/// Screen Distance for the Mac: an opt-in, iOS-style "your screen is too
/// close" notice driven by short FaceTime camera bursts and Vision face
/// landmarks. Off by default; when on, it samples about a second every
/// `intervalSeconds`, warns after `triggerSeconds` closer than
/// `thresholdCM`, and keeps the camera on only while the notice shows.
@MainActor
final class ScreenDistanceController: ObservableObject {
    enum State: Equatable {
        case off, paused, measuring, tooClose, noFace, noPermission
    }

    enum PauseReason: Equatable {
        case user
        case snoozed(until: Date)
        case screenLocked
        case asleep
        /// The camera mirror or Face Unlock is using the camera.
        case cameraBusy
        /// Another app (a call, a recording) holds the camera.
        case cameraInUse
        case cameraUnavailable
        case lowBattery
        case calibrating
        /// Center Stage reframes the picture, so distance can't be measured.
        case centerStage

        var label: String {
            switch self {
            case .user: "Paused"
            case .snoozed(let until): "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
            case .screenLocked: "Paused while locked"
            case .asleep: "Paused while asleep"
            case .cameraBusy: "Paused: camera in use by SparkV"
            case .cameraInUse: "Paused: camera in use by another app"
            case .cameraUnavailable: "Camera unavailable"
            case .lowBattery: "Paused: battery below 20%"
            case .calibrating: "Calibrating…"
            case .centerStage: "Paused: turn off Center Stage for SparkV"
            }
        }
    }

    /// Non-nil while the notice (overlay and band) is up.
    enum AlertPhase: Equatable {
        case tooClose
        /// Back at a safe distance: Continue is enabled, and it fades soon.
        case safe
    }

    nonisolated static let activityID = "screenDistance"
    nonisolated static let triggerSeconds: TimeInterval = 8
    nonisolated static let clearMarginCM: Double = 5
    /// Faster bursts while "approaching", so the 8 s trigger is accurate.
    nonisolated static let approachIntervalSeconds: TimeInterval = 2
    nonisolated static let burstFrames = 5
    nonisolated static let streamFramesPerSecond: Double = 4

    // MARK: Published state

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            settings.isEnabled = isEnabled
            persist()
            // The switch is a user action: the only place it may ask.
            isEnabled ? turnedOn(userInitiated: true) : turnedOff()
        }
    }
    @Published private(set) var distanceCM: Double?
    @Published private(set) var state: State = .off
    @Published private(set) var pauseReason: PauseReason?
    @Published private(set) var todayStats: ScreenDistanceDayStats
    @Published private(set) var alertPhase: AlertPhase?
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationMessage: String?
    @Published private(set) var calibrationScale: Double
    @Published private(set) var snoozedUntil: Date?
    @Published private(set) var isUserPaused = false

    @Published var thresholdCM: Double {
        didSet {
            thresholdCM = ScreenDistanceSettings.clampThreshold(thresholdCM)
            settings.thresholdCM = thresholdCM
            tracker.config.thresholdCM = thresholdCM
            persist()
        }
    }
    @Published var intervalSeconds: TimeInterval {
        didSet {
            let clamped = intervalSeconds.isFinite ? min(60, max(3, intervalSeconds)) : 5
            if intervalSeconds != clamped { intervalSeconds = clamped }
            settings.intervalSeconds = clamped
            persist()
        }
    }
    @Published var allowSkipping: Bool {
        didSet { settings.allowSkipping = allowSkipping; persist() }
    }
    @Published var pauseOnLowBattery: Bool {
        didSet { settings.pauseOnLowBattery = pauseOnLowBattery; persist() }
    }
    @Published var showsFullScreenAlert: Bool {
        didSet {
            settings.showsFullScreenAlert = showsFullScreenAlert
            persist()
            // Switched while a notice is up: show or remove the overlay now.
            guard alertPhase != nil else { return }
            if showsFullScreenAlert { presentOverlay() } else { overlay?.hide(animated: true) }
        }
    }
    /// Distance the user says they sat at while calibrating (ruler, or 50 cm).
    @Published var calibrationReferenceCM: Double = 50

    // MARK: Hooks for the host

    /// True while the camera mirror or Face Unlock has the camera.
    var isCameraBusy: (() -> Bool)?
    /// Hovering the band opens this drawer tab.
    var opensTab: NotchState.Tab?
    var isLowBattery: () -> Bool = { ScreenDistancePower.isOnLowBattery(percent: 20) }
    var authorizationStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) }
    /// Through PermissionCenter: one camera prompt at a time, at most once
    /// per session, never during launch; denied opens System Settings.
    var requestAccess: (@escaping @Sendable (Bool) -> Void) -> Void = { completion in
        Task { @MainActor in
            let status = await PermissionCenter.shared.request(.camera, from: "Screen Distance")
            completion(status.isGranted)
        }
    }

    // MARK: Internals

    private let activities: ActivityCenter
    private let defaults: UserDefaults
    private let camera: any ScreenDistanceSampling
    private var overlay: (any ScreenDistanceOverlayPresenting)?
    private let makeOverlay: @MainActor () -> any ScreenDistanceOverlayPresenting
    private let now: () -> Date
    private let calendar: Calendar
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var settings: ScreenDistanceSettings
    private var tracker: ScreenDistanceTracker
    private var smoother = ScreenDistanceSmoother(capacity: 3, maxAge: 4)
    private var statsLog: ScreenDistanceStatsLog
    private var loopTask: Task<Void, Never>?
    private var hasStarted = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isScreenLocked = false
    /// Fast user switching: this session is in the background.
    private var isSessionInactive = false
    private var isDisplayAsleep = false
    private var isSystemAsleep = false
    private var isAsleep: Bool { isDisplayAsleep || isSystemAsleep }
    private var lastStreamFrameAt = Date.distantPast
    private var calibrationMessageToken = 0
    private var isStreaming = false
    private var lastStreamAttempt = Date.distantPast
    private var burstInFlight = false
    private var lastReading: ScreenDistanceReading?

    init(
        activities: ActivityCenter,
        defaults: UserDefaults = .standard,
        camera: (any ScreenDistanceSampling)? = nil,
        overlay: (@MainActor () -> any ScreenDistanceOverlayPresenting)? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) {
        self.activities = activities
        self.defaults = defaults
        self.camera = camera ?? ScreenDistanceCamera()
        self.makeOverlay = overlay ?? { ScreenDistanceOverlayController() }
        self.now = now
        self.calendar = calendar
        self.sleep = sleep ?? { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }

        let loaded = ScreenDistanceSettings.load(from: defaults)
        settings = loaded
        statsLog = ScreenDistanceSettings.loadStats(from: defaults)
        tracker = ScreenDistanceTracker(config: .init(
            thresholdCM: loaded.thresholdCM,
            triggerSeconds: Self.triggerSeconds,
            clearMarginCM: Self.clearMarginCM
        ))
        isEnabled = loaded.isEnabled
        thresholdCM = loaded.thresholdCM
        intervalSeconds = min(60, max(3, loaded.intervalSeconds))
        allowSkipping = loaded.allowSkipping
        pauseOnLowBattery = loaded.pauseOnLowBattery
        showsFullScreenAlert = loaded.showsFullScreenAlert
        calibrationScale = loaded.calibrationScale
        snoozedUntil = loaded.snoozedUntil
        todayStats = statsLog.stats(for: now(), calendar: calendar)
    }

    // MARK: Lifecycle

    /// Call once at launch. Measures only if the user turned the feature on.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observeSystem()
        // Launch: never prompts. Without camera access the state shows
        // "Needs camera access" with a button that asks.
        if isEnabled { turnedOn(userInitiated: false) } else { updateState() }
    }

    /// Call at quit. Turns the camera off and removes the notice.
    func stop() {
        hasStarted = false
        stopLoop()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        updateState()
    }

    // MARK: User actions

    func pause() { isUserPaused = true; endAlert(reason: nil); updateState() }
    func resume() { isUserPaused = false; startLoopIfNeeded(); updateState() }
    func togglePause() { isUserPaused ? resume() : pause() }

    func snooze(minutes: Int) {
        let until = now().addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
        snoozedUntil = until
        settings.snoozedUntil = until
        persist()
        endAlert(reason: nil)
        updateState()
    }

    func cancelSnooze() {
        snoozedUntil = nil
        settings.snoozedUntil = nil
        persist()
        updateState()
    }

    /// The Continue button: works only once you are at a safe distance.
    func continueTapped() {
        if let event = tracker.acknowledge(skip: false, allowSkipping: allowSkipping) { handle([event]) }
    }

    /// Esc / Skip: ends the notice while still close only if allowed.
    @discardableResult
    func skipTapped() -> Bool {
        guard let event = tracker.acknowledge(skip: true, allowSkipping: allowSkipping, at: now()) else { return false }
        handle([event])
        return true
    }

    /// Call before SparkV's own camera users (mirror, Face Unlock) start, so
    /// a burst in progress lets go of the camera at once.
    func yieldCamera() {
        camera.stopAll()
        isStreaming = false
    }

    /// One-step calibration: sit at your usual distance (measure it, or
    /// accept 50 cm), and SparkV scales its estimate to match.
    func calibrate() {
        guard !isCalibrating else { return }
        guard alertPhase == nil else { showCalibrationMessage("Move back first, then calibrate."); return }
        // Never take the camera from the mirror or Face Unlock, or while locked.
        if isCameraBusy?() == true { showCalibrationMessage("Close the camera mirror first, then calibrate."); return }
        if isScreenLocked || isSessionInactive || isAsleep { return }
        switch authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            requestAccess { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.calibrate() } else { self.showCalibrationMessage("Camera access was denied."); self.updateState() }
                }
            }
            return
        default:
            showCalibrationMessage("Allow camera access in System Settings first.")
            updateState()
            return
        }
        let reference = min(120, max(25, calibrationReferenceCM))
        isCalibrating = true
        calibrationMessage = "Hold still at your usual distance…"
        updateState()
        Task {
            while burstInFlight { await sleep(0.1) }
            let result = await burst(frames: 12, timeout: 5)
            isCalibrating = false
            defer { updateState() }
            if case .success(let frames) = result, frames.contains(where: \.isReframed) {
                showCalibrationMessage("Turn off Center Stage for SparkV, then calibrate.")
                return
            }
            guard case .success(let frames) = result,
                  case .distance(let measured) = ScreenDistanceMath.burstReading(frames, calibrationScale: 1, minimumCount: 4),
                  let scale = ScreenDistanceMath.calibrationScale(measuredCentimeters: measured, actualCentimeters: reference)
            else {
                showCalibrationMessage("Couldn’t see your face clearly. Face the screen and try again.")
                return
            }
            calibrationScale = scale
            settings.calibrationScale = scale
            persist()
            smoother.reset()
            let reads = measured * scale
            showCalibrationMessage("Calibrated: measured \(Int(measured.rounded())) cm, now reads \(Int(reads.rounded())) cm.")
        }
    }

    /// Shows a calibration result for a few seconds (drawer and settings).
    private func showCalibrationMessage(_ text: String) {
        calibrationMessage = text
        calibrationMessageToken &+= 1
        let token = calibrationMessageToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.calibrationMessageToken == token, !self.isCalibrating else { return }
            self.calibrationMessage = nil
        }
    }

    func resetCalibration() {
        calibrationScale = 1
        settings.calibrationScale = 1
        persist()
        smoother.reset()
        showCalibrationMessage("Using the default 6.3 cm eye spacing.")
    }

    /// "Allow Camera Access…": shows the macOS prompt when it was never
    /// answered, otherwise opens Privacy & Security › Camera.
    func openCameraPrivacySettings() {
        if authorizationStatus() == .notDetermined {
            requestAccess { [weak self] _ in
                Task { @MainActor in self?.startLoopIfNeeded(); self?.updateState() }
            }
        } else {
            PermissionCenter.shared.openSettings(.camera, from: "Screen Distance")
        }
    }

    // MARK: Enable / disable

    private func turnedOn(userInitiated: Bool) {
        guard hasStarted else { updateState(); return }
        if userInitiated, authorizationStatus() == .notDetermined {
            // Only asked here, when the user switches the feature on.
            requestAccess { [weak self] _ in
                Task { @MainActor in self?.startLoopIfNeeded(); self?.updateState() }
            }
        }
        startLoopIfNeeded()
        updateState()
    }

    private func turnedOff() {
        stopLoop()
        distanceCM = nil
        lastReading = nil
        updateState()
    }

    private func startLoopIfNeeded() {
        guard hasStarted, isEnabled, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        endAlert(reason: nil)
        camera.stopAll()
        isStreaming = false
        smoother.reset()
    }

    // MARK: The loop

    /// One iteration: check pauses, then either tick the notice (camera
    /// streaming) or take one burst, then sleep until the next.
    private func step() async {
        let current = now()
        todayStats = statsLog.stats(for: current, calendar: calendar)
        if let until = snoozedUntil, current >= until { cancelSnooze() }

        if let reason = currentPauseReason() {
            if pauseReason != reason {
                pauseReason = reason
                endAlert(reason: nil)
                if reason != .calibrating { camera.stopAll(); isStreaming = false }
                smoother.reset()
                tracker.reset()
            }
            updateState()
            await sleep(reason == .calibrating ? 0.5 : min(intervalSeconds, 5))
            return
        }
        pauseReason = nil

        guard authorizationStatus() == .authorized else {
            endAlert(reason: nil)
            updateState()
            await sleep(intervalSeconds)
            return
        }

        if tracker.isAlerting {
            // Watchdog: a stream that stopped delivering (camera taken,
            // session interrupted) is restarted instead of trusted.
            if isStreaming, current.timeIntervalSince(max(lastStreamAttempt, lastStreamFrameAt)) > 4 {
                camera.stopAll()
                isStreaming = false
            }
            ensureStreaming()
            handle(tracker.tick(at: current))
            updateState()
            await sleep(0.5)
            return
        }

        let result = await burst(frames: Self.burstFrames, timeout: 2.5)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let frames) where frames.contains(where: \.isReframed):
            pauseReason = .centerStage
            distanceCM = nil
            updateState()
            await sleep(max(intervalSeconds, 30))
            return
        case .success(let frames):
            ingest(ScreenDistanceMath.burstReading(frames, calibrationScale: calibrationScale), at: now())
        case .failure(.inUse):
            pauseReason = .cameraInUse
        case .failure(.busy):
            break
        case .failure:
            pauseReason = .cameraUnavailable
        }
        updateState()
        if tracker.isAlerting { return }
        await sleep(tracker.isApproaching ? Self.approachIntervalSeconds : intervalSeconds)
    }

    private func currentPauseReason() -> PauseReason? {
        if isCalibrating { return .calibrating }
        if isUserPaused { return .user }
        if let until = snoozedUntil { return .snoozed(until: until) }
        if isScreenLocked || isSessionInactive { return .screenLocked }
        if isAsleep { return .asleep }
        if isCameraBusy?() == true { return .cameraBusy }
        if pauseOnLowBattery, isLowBattery() { return .lowBattery }
        return nil
    }

    private func burst(frames: Int, timeout: TimeInterval) async -> Result<[ScreenDistanceFrame], ScreenDistanceCameraError> {
        burstInFlight = true
        defer { burstInFlight = false }
        let camera = self.camera
        return await withCheckedContinuation { continuation in
            camera.captureBurst(frames: frames, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    private func ensureStreaming() {
        guard !isStreaming, now().timeIntervalSince(lastStreamAttempt) > 2 else { return }
        isStreaming = true
        lastStreamAttempt = now()
        camera.startStream(
            framesPerSecond: Self.streamFramesPerSecond,
            onFrame: { [weak self] frame in
                Task { @MainActor in self?.streamed(frame) }
            },
            onFailure: { [weak self] _ in
                Task { @MainActor in self?.isStreaming = false }
            }
        )
    }

    private func streamed(_ frame: ScreenDistanceFrame) {
        guard isStreaming, tracker.isAlerting else { return }
        lastStreamFrameAt = now()
        ingest(ScreenDistanceMath.reading(for: frame, calibrationScale: calibrationScale), at: now())
    }

    // MARK: Readings → decisions

    private func ingest(_ reading: ScreenDistanceReading, at date: Date) {
        lastReading = reading
        var input = reading
        if let value = reading.centimeters {
            let smoothed = smoother.add(value, at: date)
            distanceCM = smoothed
            input = .distance(smoothed)
            statsLog.recordReading(isClose: smoothed < thresholdCM, at: date, calendar: calendar, maxGap: max(15, intervalSeconds * 2.5))
        } else {
            distanceCM = nil
            statsLog.recordReading(isClose: false, at: date, calendar: calendar, maxGap: 0)
        }
        handle(tracker.ingest(input, at: date))
        todayStats = statsLog.stats(for: date, calendar: calendar)
        updateState()
    }

    private func handle(_ events: [ScreenDistanceTracker.Event]) {
        for event in events {
            switch event {
            case .alertBegan:
                statsLog.recordWarning(at: now(), calendar: calendar)
                saveStats()
                alertPhase = .tooClose
                postBand()
                if showsFullScreenAlert { presentOverlay() }
                ensureStreaming()
            case .safeToContinue:
                alertPhase = .safe
            case .closeAgain:
                alertPhase = .tooClose
            case .alertEnded(let reason):
                endAlert(reason: reason)
            }
        }
        todayStats = statsLog.stats(for: now(), calendar: calendar)
        updateState()
    }

    /// Takes the notice down and turns the camera back to bursts.
    private func endAlert(reason: ScreenDistanceTracker.EndReason?) {
        let wasShowing = alertPhase != nil
        alertPhase = nil
        if tracker.isAlerting { tracker.reset() }
        overlay?.hide(animated: reason == .movedBack || reason == .continued)
        activities.dismiss(id: Self.activityID)
        if isStreaming {
            camera.stopAll()
            isStreaming = false
        }
        saveStats()
        guard wasShowing, reason == .movedBack || reason == .continued, let distance = distanceCM else { return }
        let text = "\(Int(distance.rounded())) cm"
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 75, duration: 2.5) {
            ScreenDistanceThanksBandView(distanceText: text)
        })
    }

    private func presentOverlay() {
        if overlay == nil { overlay = makeOverlay() }
        overlay?.show(controller: self)
    }

    private func postBand() {
        activities.post(LiveActivity(
            id: Self.activityID, kind: .notification, priority: 75, duration: nil, opensTab: opensTab,
            urgent: true
        ) { [weak self] in
            if let self { ScreenDistanceBandView(controller: self) }
        })
    }

    private func updateState() {
        let newState: State
        if !isEnabled {
            newState = .off
        } else if !hasStarted || pauseReason != nil || isUserPaused || snoozedUntil != nil {
            newState = .paused
        } else if authorizationStatus() != .authorized {
            newState = .noPermission
        } else if alertPhase == .tooClose || (distanceCM.map { $0 < thresholdCM } ?? false) {
            newState = .tooClose
        } else if let lastReading, lastReading.centimeters == nil {
            newState = .noFace
        } else {
            newState = .measuring
        }
        if state != newState { state = newState }
    }

    // MARK: System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (ScreenDistanceController) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                    self.updateState()
                }
            }
            observers.append((center, token))
        }
        watch(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isScreenLocked = true; $0.systemPaused() }
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isScreenLocked = false }
        watch(workspace, NSWorkspace.screensDidSleepNotification) { $0.isDisplayAsleep = true; $0.systemPaused() }
        watch(workspace, NSWorkspace.screensDidWakeNotification) { $0.isDisplayAsleep = false }
        watch(workspace, NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true; $0.systemPaused() }
        watch(workspace, NSWorkspace.didWakeNotification) { $0.isSystemAsleep = false }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isSessionInactive = true; $0.systemPaused() }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isSessionInactive = false }
    }

    /// Lock, sleep or user switch: camera off and notice down right away,
    /// without waiting for the loop's next step.
    private func systemPaused() {
        endAlert(reason: nil)
        tracker.reset()
        smoother.reset()
        yieldCamera()
    }

    // MARK: Persistence

    private func persist() { settings.save(to: defaults) }
    private func saveStats() { ScreenDistanceSettings.saveStats(statsLog, to: defaults) }

    // MARK: Test hooks

    /// Feeds one reading as if the camera produced it (harness only).
    func _ingestForTesting(_ reading: ScreenDistanceReading, at date: Date) {
        if tracker.isAlerting { isStreaming = true }
        ingest(reading, at: date)
    }

    func _tickForTesting(at date: Date) { handle(tracker.tick(at: date)) }

    /// Stops the background loop but keeps the controller "started" (harness only).
    func _stopLoopForTesting() { loopTask?.cancel(); loopTask = nil }

    func _simulateScreenLock(_ locked: Bool) { isScreenLocked = locked; if locked { systemPaused() } }
    func _simulateSleep(_ asleep: Bool) { isSystemAsleep = asleep; if asleep { systemPaused() } }
}
