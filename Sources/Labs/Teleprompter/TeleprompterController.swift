import AppKit
import AVFoundation
import Carbon.HIToolbox
import Speech
import SwiftUI

/// The Teleprompter: your script scrolling in a dark panel just under the
/// camera, so your eyes stay near the lens. The panel never takes focus,
/// floats over full-screen apps and is excluded from screen sharing where
/// macOS honors that (`sharingType = .none`; some ScreenCaptureKit-based
/// tools ignore it, so share a window rather than the whole screen).
///
/// Energy: the scroll animates only while playing (TimelineView paused
/// otherwise), at 30 fps in Low Power Mode; it pauses when the displays
/// sleep, the Mac sleeps or the screen locks.
@MainActor
final class TeleprompterController: ObservableObject {
    static let shared = TeleprompterController()

    struct Script: Identifiable, Equatable {
        let id: String
        var title: String
        var text: String
        var modified: Date
        var url: URL
    }

    @Published var settings: TeleprompterSettings {
        didSet {
            let clamped = settings.clamped()
            // Assigning inside didSet doesn't re-run it.
            if clamped != settings { settings = clamped }
            saveSettings()
            if settings.speed != oldValue.speed { clock.setSpeed(settings.speed, at: Date()) }
            if settings.width != oldValue.width || settings.height != oldValue.height || settings.displayID != oldValue.displayID {
                panel.relayout(settings)
            }
            if settings.hotkeysEnabled != oldValue.hotkeysEnabled { installHotkeys() }
            if settings.voicePacing != oldValue.voicePacing { voicePacingChanged() }
        }
    }
    @Published private(set) var scripts: [Script] = []
    @Published var currentScriptID: String? {
        didSet { UserDefaults.standard.set(currentScriptID, forKey: "SparkV.teleprompter.current"); loadCurrentText() }
    }
    /// The text on the prompter (the current script, edited in place).
    @Published var text: String = "" {
        didSet { scheduleSave(); words = TeleprompterText.words(in: text); layoutCache = nil }
    }
    @Published private(set) var isShown = false
    @Published private(set) var isPlaying = false
    @Published private(set) var countdownRemaining: Int?
    /// Changes whenever the position jumps (restart, nudge, voice), so the
    /// paused view redraws.
    @Published private(set) var positionRevision = 0
    @Published private(set) var voiceStatus: String?
    @Published private(set) var reachedEnd = false

    /// Read by the integrator's hover handler: the island doesn't open on
    /// hover while the prompter plays (you're reading right under it).
    var blocksIslandHover: Bool { isShown && isPlaying }
    /// The scroll clock is running (playing, and not paced by voice): the
    /// view's TimelineView runs only then.
    var isClockRunning: Bool { isPlaying && clock.playingSince != nil }

    private(set) var clock: TeleprompterClock
    /// Total text height, measured by the view.
    var contentHeight: Double = 0
    private var countdownTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var hotkeys: [ScreenRegionHotkey] = []
    private var showHotkey: ScreenRegionHotkey?
    private let panel = TeleprompterPanelController()
    private lazy var pacer = TeleprompterVoicePacer()
    private var words: [TeleprompterText.Word] = []
    private var voiceCursor = 0
    private var layoutCache: TeleprompterLayout?
    private var isStarted = false

    static let toggleShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
    static let playShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
    static let fasterShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_UpArrow), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
    static let slowerShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_DownArrow), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
    /// displayString has no glyphs for arrow keys.
    static let fasterLabel = "⌃⌥⇧↑"
    static let slowerLabel = "⌃⌥⇧↓"

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Teleprompter", isDirectory: true)
    }

    init() {
        let loaded: TeleprompterSettings
        if let data = UserDefaults.standard.data(forKey: "SparkV.teleprompter.settings"),
           let saved = try? JSONDecoder().decode(TeleprompterSettings.self, from: data) {
            loaded = saved.clamped()
        } else {
            loaded = TeleprompterSettings()
        }
        settings = loaded
        clock = TeleprompterClock(speed: loaded.speed)
        currentScriptID = UserDefaults.standard.string(forKey: "SparkV.teleprompter.current")
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        reloadScripts()
        installHotkeys()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.panel.relayout(self.settings)
            }
        })
    }

    func stop() {
        hide()
        saveNow()
        isStarted = false
        hotkeys.forEach { $0.unregister() }
        hotkeys.removeAll()
        showHotkey?.unregister()
        showHotkey = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: Showing

    func toggleShown() { isShown ? hide() : show() }

    /// From the keyboard it appears at once (no fade).
    func show(animated: Bool = true) {
        if text.isEmpty, scripts.isEmpty { text = Self.sample }
        isShown = true
        // Asked for from inside the open drawer: close it, so the prompter
        // is what you see (closing it shows the panel through the cover).
        let covered = ExtrasIslandCover.userWillShowPanel()
        if !covered {
            panel.show(controller: self, settings: settings, animated: animated && !SparkVMotion.reduceMotion)
        }
        installHotkeys()
    }

    /// The island's drawer opened over (or closed off) the prompter: step
    /// aside and pause while it's open, come back when it closes.
    func islandCoverChanged(_ covered: Bool) {
        guard isShown else { return }
        if covered {
            pause()
            panel.hide(animated: !SparkVMotion.reduceMotion)
        } else {
            panel.show(controller: self, settings: settings, animated: !SparkVMotion.reduceMotion)
        }
    }

    func panelLevelChanged(_ level: NSWindow.Level) { panel.setLevel(level) }

    func hide(animated: Bool = true) {
        guard isShown else { return }
        pause()
        isShown = false
        panel.hide(animated: animated)
        installHotkeys()
    }

    // MARK: Playback

    func togglePlay() { isPlaying || countdownRemaining != nil ? pause() : play() }

    func play() {
        guard isShown else { show(); return play() }
        // Played from the keyboard with the drawer open: close it, the
        // drawer would cover the text.
        ExtrasIslandCover.userWillShowPanel()
        if reachedEnd { restart() }
        countdownTask?.cancel()
        let seconds = settings.countdown
        // A countdown only from the top, so resuming mid-script is instant.
        if seconds > 0, clock.offset(at: Date()) < 1 {
            countdownRemaining = seconds
            countdownTask = Task { [weak self] in
                for remaining in stride(from: seconds, to: 0, by: -1) {
                    self?.countdownRemaining = remaining
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                self?.countdownRemaining = nil
                self?.beginScrolling()
            }
        } else {
            beginScrolling()
        }
    }

    private func beginScrolling() {
        isPlaying = true
        reachedEnd = false
        if settings.voicePacing {
            startVoice()
        } else {
            clock.play(at: Date())
        }
    }

    func pause() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        guard isPlaying else { return }
        clock.pause(at: Date())
        isPlaying = false
        pacer.stop()
        positionRevision += 1
    }

    func restart() {
        let wasPlaying = isPlaying
        pause()
        clock.jump(to: 0, at: Date())
        voiceCursor = 0
        reachedEnd = false
        positionRevision += 1
        if wasPlaying { play() }
    }

    func faster() { settings.speed = TeleprompterSettings.stepped(settings.speed, faster: true) }
    func slower() { settings.speed = TeleprompterSettings.stepped(settings.speed, faster: false) }
    func biggerText() { settings.fontSize = min(settings.fontSize + 2, TeleprompterSettings.fontRange.upperBound) }
    func smallerText() { settings.fontSize = max(settings.fontSize - 2, TeleprompterSettings.fontRange.lowerBound) }

    /// Scroll-wheel / trackpad nudges (positive moves the text up).
    func nudge(by delta: Double) {
        let now = Date()
        let target = min(max(0, clock.offset(at: now) + delta), max(contentHeight, 0))
        clock.jump(to: target, at: now)
        if reachedEnd, target < contentHeight - 1 { reachedEnd = false }
        positionRevision += 1
    }

    func offset(at date: Date) -> Double {
        let value = clock.offset(at: date)
        return min(value, max(contentHeight, 0))
    }

    /// Called by the view when the text has scrolled past its end.
    func noteEnd() {
        guard isPlaying, contentHeight > 0, clock.offset(at: Date()) >= contentHeight else { return }
        pause()
        reachedEnd = true
    }

    // MARK: Voice pacing (on-device)

    private func voicePacingChanged() {
        if isPlaying {
            pause()
            play()
        }
    }

    private func startVoice() {
        voiceStatus = "Listening…"
        // Start from where the text is now.
        voiceCursor = wordIndex(atOffset: clock.offset(at: Date()))
        Task { [weak self] in
            guard let self else { return }
            let center = PermissionCenter.shared
            guard await center.ensure(.microphone, from: "Teleprompter voice pacing"),
                  await center.ensure(.speech, from: "Teleprompter voice pacing") else {
                self.voiceStatus = "Needs microphone and speech access"
                self.settings.voicePacing = false
                return
            }
            guard self.isPlaying else { return }
            let started = self.pacer.start({ [weak self] heard in
                self?.heard(heard)
            }, onGiveUp: { [weak self] in
                self?.voicePacingFailed()
            })
            if !started {
                self.voiceStatus = "On-device speech isn't available for this language"
                self.clock.play(at: Date())
            }
        }
    }

    /// Recognition kept failing: say so and keep scrolling at the set speed.
    private func voicePacingFailed() {
        voiceStatus = "Voice pacing stopped: speech unavailable"
        guard isPlaying else { return }
        clock.play(at: Date())
        positionRevision += 1
    }

    private func heard(_ recognized: [String]) {
        guard isPlaying, settings.voicePacing else { return }
        let scriptWords = words.map(\.text)
        guard let next = TeleprompterVoiceMatcher.advance(script: scriptWords, cursor: voiceCursor, heard: recognized) else { return }
        guard next > voiceCursor else { return }
        voiceCursor = next
        voiceStatus = nil
        let target = lineOffset(forWord: max(0, next - 1))
        let now = Date()
        // Ease toward the spoken line rather than jumping.
        let current = clock.offset(at: now)
        if target > current { clock.jump(to: current + (target - current) * 0.6, at: now) }
        positionRevision += 1
    }

    private func layout() -> TeleprompterLayout {
        if let layoutCache, layoutCache.matches(text: text, settings: settings) { return layoutCache }
        let layout = TeleprompterLayout(text: text, settings: settings)
        layoutCache = layout
        return layout
    }

    private func lineOffset(forWord index: Int) -> Double {
        guard words.indices.contains(index) else { return clock.offset(at: Date()) }
        return layout().y(forCharacterOffset: words[index].offset)
    }

    private func wordIndex(atOffset offset: Double) -> Int {
        let layout = layout()
        return words.firstIndex { layout.y(forCharacterOffset: $0.offset) >= offset } ?? 0
    }

    // MARK: Scripts on disk (Application Support/SparkV/Teleprompter)

    func reloadScripts() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        scripts = urls.filter { $0.pathExtension == "txt" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return Script(id: url.deletingPathExtension().lastPathComponent, title: TeleprompterText.title(for: text), text: text, modified: modified, url: url)
        }.sorted { $0.modified > $1.modified }
        if currentScriptID == nil || !scripts.contains(where: { $0.id == currentScriptID }) {
            currentScriptID = scripts.first?.id
        } else {
            loadCurrentText()
        }
    }

    private func loadCurrentText() {
        guard let id = currentScriptID, let script = scripts.first(where: { $0.id == id }) else { return }
        if text != script.text { text = script.text }
        clock.jump(to: 0, at: Date())
        voiceCursor = 0
        reachedEnd = false
        positionRevision += 1
    }

    @discardableResult
    func newScript(text: String = "") -> String {
        let id = UUID().uuidString
        let url = Self.folder.appendingPathComponent(id + ".txt")
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
        reloadScripts()
        currentScriptID = id
        return id
    }

    /// Imports .txt / .md files (dropped or picked); Markdown is cleaned up.
    func importFiles(_ urls: [URL]) {
        var last: String?
        for url in urls where ["txt", "md", "markdown", "text"].contains(url.pathExtension.lowercased()) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = url.pathExtension.lowercased() == "txt" || url.pathExtension.lowercased() == "text" ? raw : TeleprompterText.fromMarkdown(raw)
            last = newScript(text: text)
        }
        if let last { currentScriptID = last }
    }

    func deleteScript(_ id: String) {
        guard let script = scripts.first(where: { $0.id == id }) else { return }
        try? FileManager.default.trashItem(at: script.url, resultingItemURL: nil)
        if currentScriptID == id { currentScriptID = nil; text = "" }
        reloadScripts()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let id = currentScriptID, let index = scripts.firstIndex(where: { $0.id == id }) else {
            if !text.isEmpty, text != Self.sample, currentScriptID == nil { newScript(text: text) }
            return
        }
        guard scripts[index].text != text else { return }
        try? Data(text.utf8).write(to: scripts[index].url, options: .atomic)
        scripts[index].text = text
        scripts[index].title = TeleprompterText.title(for: text)
        scripts[index].modified = Date()
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "SparkV.teleprompter.settings")
        }
    }

    // MARK: Hotkeys (Carbon, no Accessibility)

    private func installHotkeys() {
        hotkeys.forEach { $0.unregister() }
        hotkeys.removeAll()
        guard isStarted, settings.hotkeysEnabled else {
            showHotkey?.unregister()
            showHotkey = nil
            return
        }
        if showHotkey == nil {
            let hotkey = ScreenRegionHotkey()
            // Keyboard-triggered: appears instantly.
            hotkey.onPress = { [weak self] in
                guard let self else { return }
                self.isShown ? self.hide(animated: false) : self.show(animated: false)
            }
            if !hotkey.register(Self.toggleShortcut) { AppLog.log("Teleprompter: \(Self.toggleShortcut.displayString) is taken by another app") }
            showHotkey = hotkey
        }
        // Playback keys only while the prompter shows.
        guard isShown else { return }
        let bindings: [(ScreenRegionShortcut, () -> Void)] = [
            (Self.playShortcut, { [weak self] in self?.togglePlay() }),
            (Self.fasterShortcut, { [weak self] in self?.faster() }),
            (Self.slowerShortcut, { [weak self] in self?.slower() }),
        ]
        for (shortcut, action) in bindings {
            let hotkey = ScreenRegionHotkey()
            hotkey.onPress = action
            if hotkey.register(shortcut) { hotkeys.append(hotkey) }
        }
    }

    static let sample = """
    Welcome to the SparkV teleprompter.

    Your script scrolls right under the camera, so your eyes stay close to the lens.

    Press Control-Option-Shift-Space to play or pause, and Control-Option-Shift-Up or Down to change the speed.

    Scroll on the text to move it by hand. Turn on Voice Pacing and it follows you as you read.
    """
}

// MARK: - Layout measurement (for voice pacing)

/// Where a character sits vertically in the prompter's text, measured with
/// TextKit at the prompter's font, width and line spacing.
@MainActor
struct TeleprompterLayout {
    private let key: String
    private let storage: NSTextStorage
    private let manager: NSLayoutManager
    private let container: NSTextContainer

    init(text: String, settings: TeleprompterSettings) {
        key = Self.key(text: text, settings: settings)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = settings.lineSpacing
        style.alignment = settings.centered ? .center : .left
        storage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: settings.fontSize, weight: .semibold),
            .paragraphStyle: style,
        ])
        manager = NSLayoutManager()
        container = NSTextContainer(size: NSSize(width: TeleprompterLayout.textWidth(settings), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
    }

    static func textWidth(_ settings: TeleprompterSettings) -> Double { settings.width - 40 }

    private static func key(text: String, settings: TeleprompterSettings) -> String {
        "\(text.hashValue)|\(settings.fontSize)|\(settings.width)|\(settings.lineSpacing)|\(settings.centered)"
    }

    func matches(text: String, settings: TeleprompterSettings) -> Bool {
        key == Self.key(text: text, settings: settings)
    }

    func y(forCharacterOffset offset: Int) -> Double {
        let length = storage.length
        guard length > 0 else { return 0 }
        let glyph = manager.glyphIndexForCharacter(at: min(max(0, offset), length - 1))
        return Double(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
    }
}

// MARK: - Voice pacer

/// On-device speech recognition only (`requiresOnDeviceRecognition`): audio
/// never leaves the Mac. Hands the recognized words to the controller.
@MainActor
final class TeleprompterVoicePacer {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var onWords: (([String]) -> Void)?
    private var onGiveUp: (() -> Void)?
    /// Bumped by every begin and teardown: a cancelled task's late callback
    /// (it always reports an error) is ignored instead of restarting again.
    private var generation = 0
    private var restartTask: Task<Void, Never>?
    private var backoff = TeleprompterRestartBackoff()

    /// False when on-device recognition isn't available for the language.
    /// `onGiveUp` runs when recognition keeps failing (it stops itself).
    func start(_ onWords: @escaping ([String]) -> Void, onGiveUp: @escaping () -> Void) -> Bool {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return false }
        self.recognizer = recognizer
        self.onWords = onWords
        self.onGiveUp = onGiveUp
        backoff = TeleprompterRestartBackoff()
        return begin()
    }

    private func begin() -> Bool {
        guard let recognizer else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            AppLog.log("Teleprompter: microphone didn't start")
            return false
        }
        self.engine = engine
        self.request = request
        generation += 1
        let current = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result.map { $0.bestTranscription.segments.suffix(6).map { TeleprompterText.normalize($0.substring) } }
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if let words, !words.isEmpty {
                    self.backoff.noteHeard()
                    self.onWords?(words)
                }
                // Recognition tasks end on long pauses: start a fresh one.
                if isFinal || failed {
                    self.restart(afterFailure: failed && words == nil)
                }
            }
        }
        return true
    }

    /// A fresh task after a short pause. Recognition that fails again and
    /// again (model not downloaded, Dictation off, the mic taken) gives up
    /// instead of spinning the microphone on and off.
    private func restart(afterFailure failed: Bool) {
        guard onWords != nil else { return }
        teardown()
        guard let delay = backoff.next(failed: failed, at: Date()) else {
            giveUp()
            return
        }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.onWords != nil else { return }
            if !self.begin() { self.giveUp() }
        }
    }

    private func giveUp() {
        let callback = onGiveUp
        AppLog.log("Teleprompter: on-device speech kept failing; voice pacing stopped")
        stop()
        callback?()
    }

    func stop() {
        onWords = nil
        onGiveUp = nil
        restartTask?.cancel()
        restartTask = nil
        teardown()
    }

    private func teardown() {
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }
}

// MARK: - Panel

/// Borderless, non-activating, above full-screen apps, out of screen
/// sharing (best effort), centered under the notch.
@MainActor
final class TeleprompterPanelController {
    private var panel: NSPanel?

    func show(controller: TeleprompterController, settings: TeleprompterSettings, animated: Bool) {
        if panel == nil {
            let panel = TeleprompterPanel(contentRect: NSRect(x: 0, y: 0, width: settings.width, height: settings.height),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // isFloatingPanel resets the level, so it comes first. One level
            // below the island, so the open drawer and bands draw on top.
            panel.isFloatingPanel = true
            panel.level = ExtrasIslandCover.panelLevel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            // Not in screenshots or screen sharing (where macOS honors it).
            panel.sharingType = .none
            panel.setAccessibilityLabel("SparkV teleprompter")
            let host = TeleprompterHostingView(rootView: AnyView(TeleprompterView(controller: controller).followsAppearance()))
            host.onScroll = { [weak controller] delta in controller?.nudge(by: delta) }
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
        }
        guard let panel else { return }
        relayout(settings)
        if animated {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SparkVMotion.Duration.standard
                context.timingFunction = .sparkVEaseOut
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        guard animated, !SparkVMotion.reduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = SparkVMotion.Duration.small
            context.timingFunction = .sparkVEaseOut
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                guard panel.alphaValue < 0.01 else { return }
                panel.orderOut(nil)
            }
        })
    }

    func setLevel(_ level: NSWindow.Level) {
        guard let panel, panel.level != level else { return }
        panel.level = level
    }

    /// Directly under the notch on its display (or under the menu bar).
    func relayout(_ settings: TeleprompterSettings) {
        guard let panel else { return }
        let screen = settings.displayID.flatMap(ExtrasScreens.screen(displayID:)) ?? ExtrasScreens.notchedOrMain
        guard let screen else { return }
        let size = NSSize(width: settings.width, height: settings.height)
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 4
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}

final class TeleprompterPanel: NSPanel {
    // Buttons work without SparkV becoming active; never key, so typing
    // always stays in the app you're in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Turns scroll-wheel and trackpad scrolling into prompter nudges.
final class TeleprompterHostingView: NSHostingView<AnyView> {
    var onScroll: ((Double) -> Void)?

    // The panel never becomes key, so the first click must act.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        onScroll?(-Double(delta))
    }
}
