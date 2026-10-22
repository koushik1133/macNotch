import AppKit
import ApplicationServices

/// Watches for Clicky's hold-to-talk chord: Control + Option together, with no
/// other modifier and no other key.
///
/// Uses NSEvent global + local monitors (`.flagsChanged`, `.keyDown`). They
/// observe only, never swallow, so ⌃⌥ shortcuts in other apps keep working;
/// pressing any key while the chord is held reports `.interrupted` so a
/// shortcut such as ⌃⌥← never starts or finishes a question.
///
/// Global key monitors need Accessibility. Without it they receive nothing;
/// `ClickySystemHotkey` (ClickySystem.swift) follows the grant through
/// PermissionCenter and re-creates the monitors when it arrives.
///
/// The chord logic is driven through `feedFlags` / `feedKeyDown`, so tests
/// exercise it without real input events.
enum ClickyHotkeyEvent: Equatable, Sendable {
    /// The chord has been held long enough to count as intentional.
    case began
    /// The chord was released after `.began`.
    case ended
    /// Another key or modifier joined the chord after `.began`.
    case interrupted
    case escape
}

@MainActor
final class ClickyHotkeyMonitor {
    typealias Event = ClickyHotkeyEvent

    /// The chord must be held this long before `.began`; quick ⌃⌥ taps and
    /// shortcuts never start listening.
    var holdDelay: TimeInterval = 0.18

    var onEvent: (@MainActor (Event) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var chordDown = false
    private var began = false
    private var pending: Task<Void, Never>?

    private static let escapeKeyCode: UInt16 = 53
    nonisolated private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func start() {
        guard !isRunning else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let info = Self.info(event)
            MainActor.assumeIsolated { self?.handle(info) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let info = Self.info(event)
            MainActor.assumeIsolated { self?.handle(info) }
            return event
        }
        AppLog.log("Clicky: hotkey monitor started")
    }

    /// Re-installs the monitors; a global monitor added before the
    /// Accessibility grant may stay deaf until it is re-created.
    func restart() {
        stop()
        start()
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    /// Forgets a held chord, e.g. after the controller cancelled the question.
    func reset() {
        pending?.cancel()
        pending = nil
        chordDown = false
        began = false
    }

    // MARK: - Events

    private struct Info: Sendable {
        let isFlags: Bool
        let isRepeat: Bool
        let keyCode: UInt16
        let flags: UInt
    }

    nonisolated private static func info(_ event: NSEvent) -> Info {
        let isFlags = event.type == .flagsChanged
        return Info(
            isFlags: isFlags,
            isRepeat: isFlags ? false : event.isARepeat,
            keyCode: event.keyCode,
            flags: event.modifierFlags.rawValue
        )
    }

    /// Test entry points: the same handling as real events.
    func feedFlags(_ flags: NSEvent.ModifierFlags) {
        handleFlags(flags)
    }

    func feedKeyDown(keyCode: UInt16, isRepeat: Bool = false) {
        handleKeyDown(keyCode: keyCode, isRepeat: isRepeat)
    }

    private func handle(_ info: Info) {
        if info.isFlags {
            handleFlags(NSEvent.ModifierFlags(rawValue: info.flags))
        } else {
            handleKeyDown(keyCode: info.keyCode, isRepeat: info.isRepeat)
        }
    }

    /// Pure chord test, exposed for tests.
    nonisolated static func isChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(relevantModifiers) == [.control, .option]
    }

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let isChord = Self.isChord(flags)
        if isChord, !chordDown {
            chordDown = true
            pending?.cancel()
            let delay = holdDelay
            pending = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.chordDown, !self.began else { return }
                self.began = true
                self.onEvent?(.began)
            }
        } else if !isChord, chordDown {
            chordDown = false
            pending?.cancel()
            pending = nil
            guard began else { return }
            began = false
            // Releasing Control or Option ends the question; adding Command,
            // Shift or fn turns it into some other shortcut.
            let stillHeld = flags.intersection(Self.relevantModifiers)
            let addedOther = !stillHeld.intersection([.command, .shift, .function]).isEmpty
            onEvent?(addedOther ? .interrupted : .ended)
        }
    }

    private func handleKeyDown(keyCode: UInt16, isRepeat: Bool) {
        if keyCode == Self.escapeKeyCode, !isRepeat {
            reset()
            onEvent?(.escape)
            return
        }
        guard chordDown else { return }
        // A key typed with ⌃⌥ held is a shortcut, not a question.
        pending?.cancel()
        pending = nil
        chordDown = false
        if began {
            began = false
            onEvent?(.interrupted)
        }
    }
}
