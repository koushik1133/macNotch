import AppKit
import ApplicationServices
import Combine
import CoreGraphics

// Global clipboard-stack shortcuts:
//
//  * ⌘ held, a digit 1–9, then V  -> paste history item N (1 = newest).
//  * ⌘⇧V                          -> open the stack panel.
//
// An active CGEventTap (needs Accessibility, like SystemKeyInterceptor and
// PushToTalkMonitor) on its own thread. When ⌘+digit is pressed it is held
// back for up to 400 ms. If V follows while ⌘ is still down, both are
// swallowed and item N is pasted. Anything else (another key, ⌘ released,
// another modifier, the timeout) replays the held ⌘+digit unchanged, so
// browser tab switching and every other ⌘1…⌘9 shortcut keep working, a
// little later at worst. ⌘+digit is only held while history has at least
// N items, so with history off nothing is ever delayed.

/// Pure key state machine for the chord, so it can be tested with
/// synthetic input. The tap wrapper turns its decisions into CGEvent work.
struct ClipboardChordMachine: Sendable {
    struct Config: Sendable, Equatable {
        /// ⌘+digit+V.
        var chordEnabled = true
        /// ⌘⇧V opens the stack panel.
        var panelShortcutEnabled = true
        /// History items available; ⌘+N is only held when N <= stackCount.
        var stackCount = 0
        /// Key code that types "v" in the current layout.
        var vKeyCode: Int64 = 9
        /// The stack panel is open and handles ⌘1…9 itself.
        var panelOpen = false
    }

    enum Input: Sendable, Equatable {
        case keyDown(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool)
        case keyUp(keyCode: Int64, flags: CGEventFlags)
        case flagsChanged(flags: CGEventFlags)
        /// The hold timer for `generation` fired.
        case timeout(generation: Int)
        /// The tap was disabled (timeout / user input) and re-enabled.
        case tapReset
    }

    /// What to do with the event being processed.
    enum Disposition: Sendable, Equatable {
        case pass
        case swallow
        /// Swallow it and keep it as the held ⌘+digit (key down).
        case hold
        /// Swallow it and keep it as the held digit's key up.
        case holdKeyUp
        /// Swallow it, then re-post it right after the held events, so the
        /// app sees the original order.
        case replayAfterHeld
    }

    enum Command: Sendable, Equatable {
        case paste(number: Int)
        case openPanel
    }

    struct Decision: Sendable, Equatable {
        var disposition: Disposition = .pass
        /// Re-post the held ⌘+digit (down, and up when it was seen) first.
        var replayHeld = false
        /// Start a hold timer for this generation.
        var startTimer: Int?
        var command: Command?
    }

    struct Held: Sendable, Equatable {
        var keyCode: Int64
        var number: Int
        var keyUpSeen = false
        var generation: Int
    }

    static let holdTimeout: TimeInterval = 0.4

    /// Top-row digit key codes (kVK_ANSI_1…9), position based like most
    /// global shortcuts.
    static let digitKeyCodes: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    var config = Config()
    private(set) var held: Held?
    /// Key codes whose key down was swallowed, so their key up is too.
    private(set) var swallowedKeyUps: Set<Int64> = []
    private var generation = 0

    private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    static func modifiers(_ flags: CGEventFlags) -> CGEventFlags { flags.intersection(modifierMask) }

    mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .timeout(let gen):
            guard let held, held.generation == gen else { return Decision() }
            self.held = nil
            return Decision(disposition: .pass, replayHeld: true)

        case .tapReset:
            swallowedKeyUps.removeAll()
            guard held != nil else { return Decision() }
            held = nil
            return Decision(disposition: .pass, replayHeld: true)

        case .flagsChanged(let flags):
            guard held != nil else { return Decision() }
            // ⌘ released or another modifier joined: the chord is over.
            if Self.modifiers(flags) != .maskCommand {
                held = nil
                return Decision(disposition: .replayAfterHeld, replayHeld: true)
            }
            return Decision()

        case .keyUp(let keyCode, _):
            if let held, held.keyCode == keyCode, !held.keyUpSeen {
                self.held?.keyUpSeen = true
                return Decision(disposition: .holdKeyUp)
            }
            if swallowedKeyUps.remove(keyCode) != nil { return Decision(disposition: .swallow) }
            return Decision()

        case .keyDown(let keyCode, let flags, let isRepeat):
            let mods = Self.modifiers(flags)
            // Auto-repeat of a key whose press was swallowed (the V of the
            // chord or of ⌘⇧V, still held down): the app never saw the press,
            // so it must not see the repeats either. Otherwise holding V a
            // moment too long pastes item N again and again, or closes the
            // stack panel that ⌘⇧V just opened.
            if isRepeat, held?.keyCode != keyCode, swallowedKeyUps.contains(keyCode) {
                return Decision(disposition: .swallow)
            }
            if let held {
                if keyCode == held.keyCode, isRepeat { return Decision(disposition: .swallow) }
                // A V repeat here belongs to a press the app already got
                // (V went down before the digit), so it is not a chord.
                if keyCode == config.vKeyCode, mods == .maskCommand, !isRepeat {
                    // The chord: paste item N.
                    swallowedKeyUps.insert(keyCode)
                    if !held.keyUpSeen { swallowedKeyUps.insert(held.keyCode) }
                    self.held = nil
                    return Decision(disposition: .swallow, command: .paste(number: held.number))
                }
                // Anything else: replay the held ⌘+digit, then judge this
                // key on its own (it may start a new hold).
                self.held = nil
                var fresh = evaluateFresh(keyCode: keyCode, mods: mods, isRepeat: isRepeat)
                fresh.replayHeld = true
                if fresh.disposition == .pass { fresh.disposition = .replayAfterHeld }
                return fresh
            }
            return evaluateFresh(keyCode: keyCode, mods: mods, isRepeat: isRepeat)
        }
    }

    private mutating func evaluateFresh(keyCode: Int64, mods: CGEventFlags, isRepeat: Bool) -> Decision {
        // Only a fresh press: repeats of a swallowed ⌘⇧V were dropped above,
        // and repeats of a V the app already saw go down (⇧V held, then ⌘
        // added) must not lose their key up.
        if config.panelShortcutEnabled, !config.panelOpen, config.stackCount > 0, !isRepeat,
           keyCode == config.vKeyCode, mods == [.maskCommand, .maskShift] {
            swallowedKeyUps.insert(keyCode)
            return Decision(disposition: .swallow, command: .openPanel)
        }
        if config.chordEnabled, !config.panelOpen, !isRepeat, mods == .maskCommand,
           let number = Self.digitKeyCodes[keyCode], number <= config.stackCount {
            generation &+= 1
            held = Held(keyCode: keyCode, number: number, generation: generation)
            return Decision(disposition: .hold, startTimer: generation)
        }
        return Decision()
    }
}

/// Installs the tap and reports chord commands on the main thread.
@MainActor
final class ClipboardHotkeys {
    var onCommand: (@MainActor (ClipboardChordMachine.Command) -> Void)?
    /// Called when the tap comes or goes (e.g. right after an Accessibility
    /// grant), so the "Allow Accessibility" hint can refresh.
    var onRunningChange: (@MainActor (Bool) -> Void)?

    private let core = ClipboardHotkeyCore()
    private var tapPort: CFMachPort?
    /// Accessibility changes, from PermissionCenter (distributed
    /// notification + app activation; no polling of our own).
    private var accessibilityWatch: AnyCancellable?
    private var layoutObserver: NSObjectProtocol?
    private var wanted = false

    var isRunning: Bool { tapPort != nil }

    /// Starts now when Accessibility is granted, otherwise as soon as
    /// PermissionCenter sees the grant. Never prompts.
    func start() {
        wanted = true
        if layoutObserver == nil {
            layoutObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLayout() }
            }
        }
        if accessibilityWatch == nil {
            // includeRechecks: also retried on app activation while granted,
            // in case tapCreate failed although Accessibility is on.
            accessibilityWatch = PermissionCenter.shared.onChange(of: .accessibility, includeRechecks: true) { [weak self] status in
                self?.accessibilityChanged(granted: status.isGranted)
            }
        }
        guard tapPort == nil else { return }
        refreshLayout()
        if install() { onRunningChange?(true) }
    }

    func stop() {
        wanted = false
        accessibilityWatch = nil
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
        layoutObserver = nil
        guard tapPort != nil else { return }
        removeTap()
        AppLog.log("Clipboard: stack shortcuts stopped")
        onRunningChange?(false)
    }

    /// A tap created before the grant (or before a revoke and re-grant)
    /// receives nothing: drop it when trust goes away, re-create it when
    /// trust comes back.
    private func accessibilityChanged(granted: Bool) {
        guard wanted else { return }
        if granted {
            guard tapPort == nil else { return }
            refreshLayout()
            if install() { onRunningChange?(true) }
        } else if tapPort != nil {
            removeTap()
            AppLog.log("Clipboard: Accessibility turned off; stack shortcuts paused")
            onRunningChange?(false)
        }
    }

    private func removeTap() {
        guard let port = tapPort else { return }
        core.flushHeld()
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        core.stopRunLoop()
        tapPort = nil
        core.setPort(nil)
    }

    func update(_ change: (inout ClipboardChordMachine.Config) -> Void) {
        core.updateConfig(change)
    }

    /// What the tap currently intercepts (for diagnostics and tests).
    var config: ClipboardChordMachine.Config { core.config }

    private func refreshLayout() {
        let code = ClipboardPaster.keyCode(for: "v").map(Int64.init) ?? 9
        core.updateConfig { $0.vKeyCode = code }
    }

    private func install() -> Bool {
        guard PermissionCenter.shared.isGranted(.accessibility) else { return false }
        core.setDeliver { [weak self] command in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onCommand?(command) }
            }
        }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passRetained(core).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.makeCallback(), userInfo: refcon
        ) else {
            Unmanaged<ClipboardHotkeyCore>.fromOpaque(refcon).release()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Unmanaged<ClipboardHotkeyCore>.fromOpaque(refcon).release()
            return false
        }
        core.setPort(port)
        tapPort = port
        let box = ClipboardTapBox(port: port, source: source, refcon: refcon, core: core)
        let thread = Thread { Self.runLoop(box) }
        thread.name = "SparkV.ClipboardStack"
        thread.qualityOfService = .userInteractive
        thread.start()
        AppLog.log("Clipboard: stack shortcuts on (⌘+1…9+V, ⌘⇧V)")
        return true
    }

    nonisolated private static func runLoop(_ box: ClipboardTapBox) {
        guard let loop = CFRunLoopGetCurrent() else {
            Unmanaged<ClipboardHotkeyCore>.fromOpaque(box.refcon).release()
            return
        }
        CFRunLoopAddSource(loop, box.source, .commonModes)
        if box.core.attachRunLoop(loop) {
            CGEvent.tapEnable(tap: box.port, enable: true)
            CFRunLoopRun()
        }
        CFRunLoopRemoveSource(loop, box.source, .commonModes)
        Unmanaged<ClipboardHotkeyCore>.fromOpaque(box.refcon).release()
    }

    nonisolated private static func makeCallback() -> CGEventTapCallBack {
        return { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let core = Unmanaged<ClipboardHotkeyCore>.fromOpaque(refcon).takeUnretainedValue()
            return core.handle(proxy: proxy, type: type, event: event)
        }
    }
}

private final class ClipboardTapBox: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    let refcon: UnsafeMutableRawPointer
    let core: ClipboardHotkeyCore

    init(port: CFMachPort, source: CFRunLoopSource, refcon: UnsafeMutableRawPointer, core: ClipboardHotkeyCore) {
        self.port = port
        self.source = source
        self.refcon = refcon
        self.core = core
    }
}

/// Runs on the tap thread; all state behind one lock.
private final class ClipboardHotkeyCore: @unchecked Sendable {
    private let lock = NSLock()
    private var machine = ClipboardChordMachine()
    private var heldDown: CGEvent?
    private var heldUp: CGEvent?
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var deliver: (@Sendable (ClipboardChordMachine.Command) -> Void)?
    private let timerQueue = DispatchQueue(label: "SparkV.ClipboardStack.timer", qos: .userInteractive)

    func setDeliver(_ handler: (@Sendable (ClipboardChordMachine.Command) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        deliver = handler
    }

    func updateConfig(_ change: (inout ClipboardChordMachine.Config) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&machine.config)
    }

    var config: ClipboardChordMachine.Config {
        lock.lock(); defer { lock.unlock() }
        return machine.config
    }

    func setPort(_ newPort: CFMachPort?) {
        lock.lock(); defer { lock.unlock() }
        port = newPort
        if newPort != nil { stopped = false }
    }

    func attachRunLoop(_ loop: CFRunLoop) -> Bool {
        lock.lock(); defer { lock.unlock() }
        runLoop = loop
        return !stopped
    }

    func stopRunLoop() {
        lock.lock()
        stopped = true
        let loop = runLoop
        runLoop = nil
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }

    /// Replays a held ⌘+digit when the tap goes away.
    func flushHeld() {
        lock.lock()
        let decision = machine.handle(.tapReset)
        let events = decision.replayHeld ? takeHeld() : []
        lock.unlock()
        events.forEach { $0.post(tap: .cgSessionEventTap) }
    }

    /// Caller holds the lock.
    private func takeHeld() -> [CGEvent] {
        let events = [heldDown, heldUp].compactMap { $0 }
        heldDown = nil
        heldUp = nil
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: PushToTalkMonitor.syntheticEventTag)
        }
        return events
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let decision = machine.handle(.tapReset)
            let events = decision.replayHeld ? takeHeld() : []
            let port = self.port
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            events.forEach { $0.post(tap: .cgSessionEventTap) }
            return Unmanaged.passUnretained(event)
        }
        // SparkV's own keystrokes (pastes, replays) pass untouched.
        if event.getIntegerValueField(.eventSourceUserData) == PushToTalkMonitor.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        let input: ClipboardChordMachine.Input
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .keyDown:
            input = .keyDown(keyCode: keyCode, flags: event.flags,
                             isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            input = .keyUp(keyCode: keyCode, flags: event.flags)
        case .flagsChanged:
            input = .flagsChanged(flags: event.flags)
        default:
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let decision = machine.handle(input)
        var replay = decision.replayHeld ? takeHeld() : []
        switch decision.disposition {
        case .hold:
            heldDown = event.copy()
            heldUp = nil
        case .holdKeyUp:
            heldUp = event.copy()
        case .replayAfterHeld:
            if let copy = event.copy() {
                copy.setIntegerValueField(.eventSourceUserData, value: PushToTalkMonitor.syntheticEventTag)
                replay.append(copy)
            }
        case .pass, .swallow:
            break
        }
        // The chord consumed the held ⌘+digit: drop the copies for good.
        if case .paste? = decision.command {
            heldDown = nil
            heldUp = nil
        }
        let deliver = self.deliver
        lock.unlock()

        // In order, right after this tap: the held ⌘+digit, then this event.
        for held in replay { held.tapPostEvent(proxy) }
        if let generation = decision.startTimer { scheduleTimeout(generation) }
        if let command = decision.command { deliver?(command) }

        switch decision.disposition {
        case .pass: return Unmanaged.passUnretained(event)
        case .swallow, .hold, .holdKeyUp, .replayAfterHeld: return nil
        }
    }

    private func scheduleTimeout(_ generation: Int) {
        timerQueue.asyncAfter(deadline: .now() + ClipboardChordMachine.holdTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let decision = self.machine.handle(.timeout(generation: generation))
            let events = decision.replayHeld ? self.takeHeld() : []
            self.lock.unlock()
            // No tap proxy here: post at the session tap; our tap skips them
            // (tagged) and every other tap and app sees the ⌘+digit.
            events.forEach { $0.post(tap: .cgSessionEventTap) }
        }
    }
}
