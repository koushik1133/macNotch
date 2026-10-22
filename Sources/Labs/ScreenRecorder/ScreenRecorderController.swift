import AppKit
import AVFoundation
import SwiftUI

/// One-click screen recording, the CleanShot X / macOS screenshot-toolbar way:
/// ⌃⌥⇧R (or the Screen tab's Record tile) shows the selection overlay: drag
/// an area, click a window, or press Return for the whole screen. A red band
/// under the notch and a menu-bar stop button show the elapsed time; the
/// movie lands on the Desktop as "SparkV Recording <date>.mov" with a
/// thumbnail you can drag into any app, Reveal, Open or Add to Tray.
@MainActor
final class ScreenRecorderController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case selecting
        case starting
        case recording(since: Date)
        case stopping

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var target: ScreenRecorderTarget?
    @Published private(set) var lastRecording: ScreenRecording? {
        didSet { if lastRecording != oldValue { loadThumbnail() } }
    }
    /// A frame of `lastRecording`, for the tile and the result card.
    @Published private(set) var lastThumbnail: NSImage?
    @Published private(set) var lastError: String?
    @Published private(set) var hasScreenRecording = false
    @Published private(set) var hotkeyRegistered = false
    let settings: ScreenRecorderSettings

    /// Hovering the recording band opens this drawer tab (where Stop is).
    var opensTab: NotchState.Tab? = .screen
    /// Wire to the tray to offer "Add to Tray".
    var onAddToTray: ((URL) -> Void)?
    /// Before the overlay appears (wire to `clicky.cancel()`: ⌃⌥ is its chord).
    var onWillBegin: (() -> Void)?
    /// Test seams.
    var makeEngine: () -> ScreenRecorderEngine = { ScreenCaptureRecorderEngine() }
    var preflight: @MainActor () -> Bool = { PermissionCenter.shared.isGranted(.screenRecording) }
    /// Microphone status through PermissionCenter (never prompts).
    var microphoneGranted: @MainActor () -> Bool = { PermissionCenter.shared.isGranted(.microphone) }
    var destinations: () -> [URL] = { [ScreenRecorderFiles.desktop, ScreenRecorderFiles.fallback] }
    var showsChrome = true
    var now: () -> Date = { Date() }

    private let activities: ActivityCenter
    private let hotkey = ScreenRegionHotkey()
    private let overlay = ScreenRegionOverlayController()
    private let frameWindow = ScreenRecorderFrameWindow()
    private let statusItem = ScreenRecorderStatusItem()
    private let resultPanel = ScreenRecorderResultPanel()
    private var engine: ScreenRecorderEngine?
    private var tempURL: URL?
    private var startTask: Task<Void, Never>?
    /// `stop()` arrived while starting (e.g. Quit): stop as soon as it runs.
    private var stopWhenStarted = false

    static let activityID = "screenRecorder"

    init(activities: ActivityCenter, settings: ScreenRecorderSettings? = nil) {
        self.activities = activities
        self.settings = settings ?? ScreenRecorderSettings()
        hotkey.onPress = { [weak self] in self?.toggle() }
        statusItem.onStop = { [weak self] in self?.stop() }
    }

    var canAddToTray: Bool { onAddToTray != nil }
    var shortcut: ScreenRegionShortcut { settings.shortcut }

    // MARK: Lifecycle

    func start() {
        refreshPermission()
    }

    /// App shutdown: finishes a running recording (the file is kept) and
    /// removes the hotkey.
    func shutdown() {
        uninstallHotkey()
        overlay.cancel()
        stop()
        resultPanel.close()
    }

    @discardableResult
    func installHotkey() -> Bool {
        hotkeyRegistered = hotkey.register(settings.shortcut)
        if hotkeyRegistered { AppLog.log("Screen Recorder: hotkey \(settings.shortcut.displayString)") }
        return hotkeyRegistered
    }

    func uninstallHotkey() {
        hotkey.unregister()
        hotkeyRegistered = false
    }

    @discardableResult
    func setShortcut(_ newValue: ScreenRegionShortcut) -> Bool {
        guard newValue.isValidGlobal else { return false }
        let wasRegistered = hotkeyRegistered
        settings.save(shortcut: newValue)
        return wasRegistered ? installHotkey() : true
    }

    // MARK: Permission (preflight only; the request runs on a click)

    func refreshPermission() {
        hasScreenRecording = preflight()
    }

    /// Only from a click. PermissionCenter shows the system request once per
    /// code signature; after that, System Settings (and a restart offer).
    func requestScreenRecording() {
        ScreenRegionCapture.requestPermission(from: "Screen Recorder") { [weak self] _ in self?.refreshPermission() }
    }

    /// The microphone toggle. Asks for access on this click when needed
    /// (through PermissionCenter: one prompt, queued; denied opens Settings).
    func setRecordsMicrophone(_ on: Bool) {
        guard on else {
            settings.recordsMicrophone = false
            return
        }
        if microphoneGranted() {
            settings.recordsMicrophone = true
            return
        }
        let wasDenied = PermissionCenter.shared.status(.microphone) != .notDetermined
        Task { [weak self] in
            let status = await PermissionCenter.shared.request(.microphone, from: "Screen Recorder")
            guard let self else { return }
            self.settings.recordsMicrophone = status.isGranted
            guard !status.isGranted else { return }
            if wasDenied {
                self.notify("mic.slash", "Turn on SparkV in Privacy & Security › Microphone", duration: 4)
            } else {
                self.notify("mic.slash", "Microphone access is off for SparkV", duration: 3)
            }
        }
    }

    // MARK: Entry points

    /// Hotkey: start selecting, cancel selecting, or stop.
    func toggle() {
        switch phase {
        case .idle: beginSelection()
        case .selecting: overlay.cancel()
        case .recording: stop()
        case .starting, .stopping: break
        }
    }

    /// Overlay: drag an area, click a window, Return = the whole screen.
    func beginSelection(mode: ScreenRegionOverlayState.Mode = .region) {
        // One overlay owns the screen (and Esc/Space/Return) at a time.
        guard phase == .idle, !ScreenRegionOverlayController.isAnyActive, ensurePermission() else { return }
        onWillBegin?()
        resultPanel.close()
        phase = .selecting
        let front = NSWorkspace.shared.frontmostApplication
        let previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        var options = ScreenRegionOverlayOptions()
        options.regionHint = "Drag to record an area  ·  Click a window  ·  Return: full screen  ·  Esc: cancel"
        options.windowHint = "Click a window to record it  ·  Space: drag an area  ·  Return: full screen  ·  Esc: cancel"
        options.accent = .systemRed
        options.returnSelectsDisplay = true
        options.title = "Record screen"
        overlay.begin(mode: mode, options: options) { [weak self] selection in
            guard let self else { return }
            if let previousApp, !previousApp.isTerminated { previousApp.activate() }
            guard let selection else {
                self.phase = .idle
                return
            }
            self.phase = .idle
            self.record(ScreenRecorderTarget(selection: selection))
        }
    }

    /// One click: the display under the pointer.
    func recordFullScreen() {
        guard phase == .idle, ensurePermission() else { return }
        let displays = ScreenRegionCapture.displays()
        guard let display = ScreenRegionGeometry.display(containing: NSEvent.mouseLocation, in: displays) ?? displays.first else {
            fail(ScreenRecorderError.noDisplay.localizedDescription)
            return
        }
        onWillBegin?()
        record(.display(display))
    }

    /// Starts recording `target` (also the test entry point).
    func record(_ target: ScreenRecorderTarget) {
        guard phase == .idle else { return }
        lastError = nil
        stopWhenStarted = false
        phase = .starting
        self.target = target
        resultPanel.close()
        let options = effectiveOptions()
        startTask = Task { [weak self] in
            // Let the overlay leave the screen first.
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            await self.startEngine(target: target, options: options)
        }
    }

    private func effectiveOptions() -> ScreenRecorderOptions {
        var options = settings.options
        if options.recordsMicrophone, !microphoneGranted() {
            options.recordsMicrophone = false
            notify("mic.slash", "Recording without the microphone (no access)", duration: 3)
        }
        return options
    }

    private func startEngine(target: ScreenRecorderTarget, options: ScreenRecorderOptions) async {
        let scale = ScreenRegionCapture.screen(for: target.display)?.backingScaleFactor ?? target.display.scale
        let plan = ScreenRecorderPlan.make(target: target, scale: scale, options: options)
        let engine = makeEngine()
        engine.onUnexpectedStop = { [weak self] error in self?.unexpectedStop(error) }
        self.engine = engine
        do {
            let url = try ScreenRecorderFiles.newTempURL(fileExtension: options.format.fileExtension)
            tempURL = url
            try await engine.start(target: target, plan: plan, url: url)
            let since = now()
            phase = .recording(since: since)
            showRecordingChrome(target: target, since: since)
            AppLog.log("Screen Recorder: started \(target.label)")
            if stopWhenStarted {
                stopWhenStarted = false
                stop()
            }
        } catch {
            self.engine = nil
            discardTemp()
            phase = .idle
            self.target = nil
            fail(error.localizedDescription)
        }
    }

    /// Stops and saves. While selecting it cancels; while starting, the
    /// recording stops (and is saved) as soon as it has begun.
    func stop() {
        switch phase {
        case .selecting:
            overlay.cancel()
            return
        case .starting:
            stopWhenStarted = true
            return
        case .idle, .stopping, .recording:
            break
        }
        guard case .recording(let since) = phase, let engine else { return }
        phase = .stopping
        hideRecordingChrome()
        notify("record.circle", "Saving recording…", duration: 10, busy: true)
        let duration = now().timeIntervalSince(since)
        Task { [weak self] in
            var stopError: Error?
            do { try await engine.stop() } catch { stopError = error }
            guard let self else { return }
            await self.finish(duration: duration, stopError: stopError)
        }
    }

    private func unexpectedStop(_ error: Error?) {
        guard phase.isRecording else { return }
        AppLog.log("Screen Recorder: stopped unexpectedly")
        stop()
    }

    private func finish(duration: TimeInterval, stopError: Error?) async {
        engine = nil
        let label = target?.label ?? "Recording"
        target = nil
        guard let temp = tempURL else {
            phase = .idle
            return
        }
        tempURL = nil
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            phase = .idle
            discard(temp)
            fail(stopError?.localizedDescription ?? "The recording was empty")
            return
        }
        let base = ScreenRecorderFiles.baseName(for: now())
        let folders = destinations()
        let moved = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result { try ScreenRecorderFiles.move(temp, named: base, to: folders) }
        }.value
        phase = .idle
        switch moved {
        case .success(let url):
            let recording = ScreenRecording(url: url, duration: duration, byteCount: size, date: now(), targetLabel: label)
            lastRecording = recording
            AppLog.log("Screen Recorder: saved \(recording.summary) to \(url.deletingLastPathComponent().lastPathComponent)")
            let place = url.deletingLastPathComponent().standardizedFileURL == ScreenRecorderFiles.desktop.standardizedFileURL
                ? "Desktop" : url.deletingLastPathComponent().lastPathComponent
            notify("checkmark.circle.fill", "Saved to \(place) · \(recording.summary)", duration: 4, opensTab: opensTab)
            if showsChrome { resultPanel.show(recording, controller: self) }
        case .failure(let error):
            // Keep the temp file: never lose a recording.
            let recording = ScreenRecording(url: temp, duration: duration, byteCount: size, date: now(), targetLabel: label)
            lastRecording = recording
            fail("Couldn't save to the Desktop: \(error.localizedDescription)")
            if showsChrome { resultPanel.show(recording, controller: self) }
        }
    }

    private func loadThumbnail() {
        lastThumbnail = nil
        guard let url = lastRecording?.url else { return }
        Task { [weak self] in
            let image = await ScreenRecorderThumbnails.make(for: url)
            guard let self, self.lastRecording?.url == url else { return }
            self.lastThumbnail = image
        }
    }

    // MARK: Actions on a finished recording

    func reveal(_ recording: ScreenRecording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    func open(_ recording: ScreenRecording) {
        NSWorkspace.shared.open(recording.url)
    }

    func addToTray(_ recording: ScreenRecording) {
        guard let onAddToTray else { return }
        onAddToTray(recording.url)
        notify("tray.and.arrow.down", "Added to Tray", duration: 2)
    }

    func closeResult() {
        resultPanel.close()
    }

    // MARK: Chrome: band, menu-bar stop button, region frame

    private func showRecordingChrome(target: ScreenRecorderTarget, since: Date) {
        let shortcut = settings.shortcut.displayString
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 80, duration: nil, opensTab: opensTab) {
            ScreenRecorderBandView(since: since, label: target.label, shortcut: shortcut)
        })
        guard showsChrome else { return }
        statusItem.show(since: since)
        if case .region(let rect, _) = target { frameWindow.show(around: rect) }
    }

    private func hideRecordingChrome() {
        activities.dismiss(id: Self.activityID)
        statusItem.hide()
        frameWindow.hide()
    }

    // MARK: Helpers

    private func ensurePermission() -> Bool {
        refreshPermission()
        guard hasScreenRecording else {
            if ScreenRegionCapture.needsRelaunch {
                fail("Restart SparkV so Screen Recording takes effect")
            } else {
                fail("Allow Screen Recording to record the screen (Screen tab → Allow)")
            }
            return false
        }
        return true
    }

    private func discardTemp() {
        if let tempURL { discard(tempURL) }
        tempURL = nil
    }

    /// Only ever deletes our own temp files.
    private func discard(_ url: URL) {
        guard url.path.hasPrefix(ScreenRecorderFiles.tempFolder.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func fail(_ message: String) {
        lastError = message
        AppLog.log("Screen Recorder: \(message)")
        notify("exclamationmark.triangle", message, duration: 4)
    }

    private func notify(_ systemImage: String, _ text: String, duration: TimeInterval, busy: Bool = false, opensTab: NotchState.Tab? = nil) {
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 66, duration: duration, opensTab: opensTab) {
            ScreenRegionBandView(systemImage: systemImage, text: text, busy: busy)
        })
    }
}
