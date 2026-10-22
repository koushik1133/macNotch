import AppKit
import CoreGraphics

/// Global hold-to-talk key watcher for dictation.
///
/// A session-level `CGEventTap` runs on its own thread (so a busy main thread
/// never adds latency to the user's typing) and reports, on the main thread:
/// hotkey down / up, hotkey+Space, Esc and "another key was used with the
/// hotkey" (a chord such as fn+Arrow or Option+E, which must not dictate).
///
/// It also watches the Flow history shortcuts, Ctrl+Cmd+V (paste the last
/// dictation) and Ctrl+Cmd+C (copy it).
///
/// Only Esc (while a dictation is active), the Space of hotkey+Space and the
/// two history shortcuts (while enabled) are swallowed; every other event
/// passes through untouched. The tap needs the
/// Accessibility permission; `start()` returns false without it (checked
/// through PermissionCenter, never prompting) and `restart()` re-creates the
/// tap after a grant.
///
/// About the fn / Globe key: the system acts on the key itself (emoji picker,
/// input source switch or "press fn twice" Dictation). The app cannot suppress
/// that without breaking fn+key combinations, so the user should set
/// System Settings > Keyboard > "Press 🌐 key to" = "Do Nothing", and set
/// Keyboard > Dictation > Shortcut to anything other than the fn key (or turn
/// macOS Dictation off). Right Option has no such conflict.
@MainActor
final class PushToTalkMonitor {
    enum Key: Sendable, Equatable {
        case fn
        case rightOption
    }

    enum Event: Sendable, Equatable {
        case pressed
        case released
        /// Space pressed while the hotkey is held (Wispr's hands-free chord).
        case space
        /// Esc pressed while dictation is active (the key was swallowed).
        case escape
        /// Another key or modifier was used together with the hotkey.
        case chord
        /// Ctrl+Cmd+V: paste the last dictation (the key was swallowed).
        case pasteLast
        /// Ctrl+Cmd+C: copy the last dictation (the key was swallowed).
        case copyLast
        /// Control joined a held fn: the chord belongs to the Job Agent.
        case yieldedToControl
    }

    /// Marks events SparkV posts itself (the synthetic Cmd+V) so the tap ignores them.
    nonisolated static let syntheticEventTag: Int64 = 0x4E49_4454

    /// Called on the main thread with the event and its time (system uptime, seconds).
    var onEvent: (@MainActor (Event, TimeInterval) -> Void)?

    private let core = TapCore()
    private var tapThread: Thread?
    private var tapPort: CFMachPort?

    var isRunning: Bool { tapPort != nil }

    /// nil turns the hotkey off (Esc handling stays available while running).
    func setKey(_ key: Key?) {
        core.setKey(key)
    }

    /// While enabled, Ctrl+Cmd+V / Ctrl+Cmd+C are swallowed and reported as
    /// `.pasteLast` / `.copyLast`.
    func setHistoryShortcutsEnabled(_ enabled: Bool) {
        core.setHistoryShortcutsEnabled(enabled)
    }

    /// While armed, Esc is swallowed and reported as `.escape`.
    func setEscapeArmed(_ armed: Bool) {
        core.setEscapeArmed(armed)
    }

    /// Installs the event tap. Returns false when the tap cannot be created,
    /// which in practice means Accessibility has not been granted.
    @discardableResult
    func start() -> Bool {
        guard tapPort == nil else { return true }
        // Creating a key tap without the grant can make macOS show its own
        // Accessibility alert; only PermissionCenter may ask.
        guard PermissionCenter.shared.isGranted(.accessibility) else {
            AppLog.log("Dictation: key monitor unavailable (Accessibility not granted)")
            return false
        }

        core.setDeliver { [weak self] event, time in
            // Hop to the main thread in event order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onEvent?(event, time)
                }
            }
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passRetained(core).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.makeCallback(),
            userInfo: refcon
        ) else {
            Unmanaged<TapCore>.fromOpaque(refcon).release()
            AppLog.log("Dictation: key monitor unavailable (Accessibility not granted)")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Unmanaged<TapCore>.fromOpaque(refcon).release()
            AppLog.log("Dictation: key monitor run loop source failed")
            return false
        }
        core.setPort(port)
        tapPort = port

        let box = TapThreadBox(port: port, source: source, refcon: refcon, core: core)
        let thread = Thread {
            Self.runTapLoop(box)
        }
        thread.name = "SparkV.PushToTalk"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        AppLog.log("Dictation: key monitor started")
        return true
    }

    /// Drops the current tap and creates a new one. A tap created before
    /// Accessibility was (re-)granted stays deaf, so call this after a grant.
    @discardableResult
    func restart() -> Bool {
        stop()
        return start()
    }

    func stop() {
        guard let port = tapPort else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        core.stopRunLoop()
        tapPort = nil
        tapThread = nil
        core.setPort(nil)
        AppLog.log("Dictation: key monitor stopped")
    }

    // MARK: - Tap thread

    nonisolated private static func runTapLoop(_ box: TapThreadBox) {
        guard let runLoop = CFRunLoopGetCurrent() else {
            Unmanaged<TapCore>.fromOpaque(box.refcon).release()
            return
        }
        CFRunLoopAddSource(runLoop, box.source, .commonModes)
        if box.core.attachRunLoop(runLoop) {
            CGEvent.tapEnable(tap: box.port, enable: true)
            CFRunLoopRun()
        }
        CFRunLoopRemoveSource(runLoop, box.source, .commonModes)
        Unmanaged<TapCore>.fromOpaque(box.refcon).release()
    }

    /// Built outside any actor so the C callback carries no isolation assumptions.
    nonisolated private static func makeCallback() -> CGEventTapCallBack {
        return { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let core = Unmanaged<TapCore>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = core.handle(type: type, event: event)
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
    }
}

/// Everything the tap thread needs, handed over once.
private final class TapThreadBox: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    let refcon: UnsafeMutableRawPointer
    let core: TapCore

    init(port: CFMachPort, source: CFRunLoopSource, refcon: UnsafeMutableRawPointer, core: TapCore) {
        self.port = port
        self.source = source
        self.refcon = refcon
        self.core = core
    }
}

/// Key state machine that runs on the tap thread. All mutable state sits
/// behind one lock because configuration changes arrive from the main thread.
private final class TapCore: @unchecked Sendable {
    private let lock = NSLock()
    private var key: PushToTalkMonitor.Key? = .fn
    private var escapeArmed = false
    private var historyShortcuts = true
    /// The hotkey is physically down.
    private var hotkeyDown = false
    /// `.pressed` was reported for the current press, so `.released` is owed.
    private var pressReported = false
    /// Key codes whose keyDown was swallowed, so their keyUp is swallowed too.
    private var swallowedKeyUps: Set<Int64> = []
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false

    private var deliver: (@Sendable (PushToTalkMonitor.Event, TimeInterval) -> Void)?

    func setDeliver(_ handler: (@Sendable (PushToTalkMonitor.Event, TimeInterval) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        deliver = handler
    }

    // Virtual key codes (Carbon kVK_*).
    private static let fnKeyCodes: Set<Int64> = [63, 179] // kVK_Function, Globe on newer keyboards
    private static let rightOptionKeyCode: Int64 = 61     // kVK_RightOption
    private static let escapeKeyCode: Int64 = 53
    private static let spaceKeyCode: Int64 = 49
    // Position-based (ANSI V / C), like most global shortcuts.
    private static let vKeyCode: Int64 = 9
    private static let cKeyCode: Int64 = 8
    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK).
    private static let deviceLeftAlt: UInt64 = 0x0000_0020
    private static let deviceRightAlt: UInt64 = 0x0000_0040

    func setKey(_ newKey: PushToTalkMonitor.Key?) {
        lock.lock(); defer { lock.unlock() }
        key = newKey
        hotkeyDown = false
        pressReported = false
    }

    func setEscapeArmed(_ armed: Bool) {
        lock.lock(); defer { lock.unlock() }
        escapeArmed = armed
    }

    func setHistoryShortcutsEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        historyShortcuts = enabled
    }

    func setPort(_ newPort: CFMachPort?) {
        lock.lock(); defer { lock.unlock() }
        port = newPort
        if newPort != nil { stopped = false }
    }

    /// Returns false when `stop()` already ran, so the thread exits at once.
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

    /// Returns true when the event should be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Events were missed while the tap was off: resync with the real
            // modifier state, so a hotkey released meanwhile still ends the hold.
            let current = CGEventSource.flagsState(.combinedSessionState)
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            var emitted: [PushToTalkMonitor.Event] = []
            let stillDown = key.map { Self.isHotkeyFlagSet(current, $0, lenient: true) } ?? false
            if hotkeyDown, !stillDown {
                hotkeyDown = false
                if pressReported {
                    pressReported = false
                    emitted.append(.released)
                }
            }
            swallowedKeyUps.removeAll()
            let port = self.port
            let deliver = self.deliver
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            if let deliver { emitted.forEach { deliver($0, now) } }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == PushToTalkMonitor.syntheticEventTag {
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let (emitted, swallow) = transition(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        let deliver = self.deliver
        lock.unlock()

        if let deliver {
            for item in emitted { deliver(item, now) }
        }
        return swallow
    }

    /// Caller holds the lock.
    private func transition(
        type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool
    ) -> ([PushToTalkMonitor.Event], Bool) {
        switch type {
        case .flagsChanged:
            guard let key else { return ([], false) }
            if Self.isHotkey(keyCode, key) {
                let down = Self.isHotkeyFlagSet(flags, key)
                guard down != hotkeyDown else { return ([], false) }
                hotkeyDown = down
                if down {
                    // Ignore the hotkey while other modifiers are held (a shortcut).
                    if Self.otherModifiersHeld(flags, key) { return ([], false) }
                    pressReported = true
                    return ([.pressed], false)
                }
                if pressReported {
                    pressReported = false
                    return ([.released], false)
                }
                return ([], false)
            }
            if key == .fn, hotkeyDown, pressReported, flags.contains(.maskControl) {
                // No .released owed: the press belongs to the Job Agent.
                pressReported = false
                return ([.yieldedToControl], false)
            }
            if hotkeyDown, pressReported, Self.otherModifiersHeld(flags, key) {
                return ([.chord], false)
            }
            return ([], false)

        case .keyDown:
            if historyShortcuts, let shortcut = Self.historyShortcut(keyCode, flags) {
                swallowedKeyUps.insert(keyCode)
                return (isRepeat ? [] : [shortcut], true)
            }
            if keyCode == Self.escapeKeyCode, escapeArmed {
                swallowedKeyUps.insert(keyCode)
                return ([.escape], true)
            }
            if hotkeyDown, pressReported {
                if keyCode == Self.spaceKeyCode {
                    swallowedKeyUps.insert(keyCode)
                    return (isRepeat ? [] : [.space], true)
                }
                if !isRepeat { return ([.chord], false) }
            }
            return ([], false)

        case .keyUp:
            return ([], swallowedKeyUps.remove(keyCode) != nil)

        default:
            return ([], false)
        }
    }

    /// Exactly Ctrl+Cmd (no Shift / Option) plus V or C.
    private static func historyShortcut(_ keyCode: Int64, _ flags: CGEventFlags) -> PushToTalkMonitor.Event? {
        guard flags.contains(.maskControl), flags.contains(.maskCommand),
              flags.intersection([.maskShift, .maskAlternate]).isEmpty else { return nil }
        switch keyCode {
        case vKeyCode: return .pasteLast
        case cKeyCode: return .copyLast
        default: return nil
        }
    }

    private static func isHotkey(_ keyCode: Int64, _ key: PushToTalkMonitor.Key) -> Bool {
        switch key {
        case .fn: fnKeyCodes.contains(keyCode)
        case .rightOption: keyCode == rightOptionKeyCode
        }
    }

    /// `lenient` skips the device bit for Right Option (the combined session
    /// state may not carry device-dependent bits).
    private static func isHotkeyFlagSet(_ flags: CGEventFlags, _ key: PushToTalkMonitor.Key, lenient: Bool = false) -> Bool {
        switch key {
        case .fn: flags.contains(.maskSecondaryFn)
        case .rightOption: flags.contains(.maskAlternate) && (lenient || (flags.rawValue & deviceRightAlt) != 0)
        }
    }

    private static func otherModifiersHeld(_ flags: CGEventFlags, _ key: PushToTalkMonitor.Key) -> Bool {
        if !flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty { return true }
        switch key {
        case .fn: return flags.contains(.maskAlternate)
        case .rightOption: return (flags.rawValue & deviceLeftAlt) != 0
        }
    }
}
