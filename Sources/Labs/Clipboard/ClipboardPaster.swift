import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Pastes whatever is on the general pasteboard into the frontmost app by
/// posting ⌘V, the way Maccy does: the item is written first with every
/// stored representation, so rich text, images and files paste as
/// themselves (TextInserter only types plain text, and adds dictation's
/// smart spacing). Needs the Accessibility permission to post the keystroke;
/// never prompts for it.
@MainActor
enum ClipboardPaster {
    enum Outcome: Equatable {
        case pasted
        /// Not pasted; the item stays on the clipboard. The message says why.
        case notPasted(String)
    }

    /// `target`: the app to paste into when SparkV's own panel had focus
    /// (the stack panel records the app it opened over). `keepCommand`: the
    /// ⌘+N+V chord, where the user may still hold ⌘; only ⇧/⌥/⌃ must be up,
    /// and ⌘ is not pressed and released again under their finger.
    static func pasteIntoFrontmostApp(target preferred: NSRunningApplication? = nil,
                                      keepCommand: Bool = false) async -> Outcome {
        guard PermissionCenter.shared.isGranted(.accessibility) else { return .notPasted("Allow Accessibility for SparkV to paste · ⌘V") }
        if IsSecureEventInputEnabled() { return .notPasted("Secure input is on · press ⌘V") }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidate = preferred.flatMap { $0.isTerminated ? nil : $0 } ?? NSWorkspace.shared.frontmostApplication
        guard let target = candidate, target.processIdentifier != ownPID
        else { return .notPasted("Click a text field first · ⌘V") }

        // The notch panel takes key focus after a click in its search field;
        // hand it back, or ⌘V would land in SparkV.
        if preferred != nil || NSApp.keyWindow != nil {
            NSApp.keyWindow?.makeFirstResponder(nil)
            target.activate()
            try? await Task.sleep(for: .milliseconds(150))
        }
        await waitForModifierRelease(keepCommand ? [.maskAlternate, .maskControl, .maskShift]
                                                 : [.maskCommand, .maskAlternate, .maskControl, .maskShift])
        // Give the target a moment to see the new pasteboard contents.
        try? await Task.sleep(for: .milliseconds(30))
        let commandDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        postCommandV(pressCommand: !(keepCommand && commandDown))
        return .pasted
    }

    /// ⌥ (the menu's "paste" alternate) or ⇧ still held would turn ⌘V into
    /// another shortcut, such as Finder's "Move Item Here".
    private static func waitForModifierRelease(_ modifiers: CGEventFlags) async {
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// `pressCommand` false: only V down/up with the ⌘ flag (the user is
    /// physically holding ⌘ after the ⌘+N+V chord).
    private static func postCommandV(pressCommand: Bool = true) {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let commandKey = CGKeyCode(kVK_Command)
        var events = [
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
        ]
        if pressCommand {
            events.insert(CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true), at: 0)
            events.append(CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false))
        }
        for (index, event) in events.enumerated() {
            guard let event else { continue }
            event.flags = pressCommand && index == events.count - 1 ? [] : .maskCommand
            // Tagged so SparkV's own hotkey monitor ignores it.
            event.setIntegerValueField(.eventSourceUserData, value: PushToTalkMonitor.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Key that types `character` in the current layout (Dvorak, AZERTY…),
    /// so ⌘V is the real "Paste" shortcut there too.
    static func keyCode(for character: Character) -> CGKeyCode? {
        let sources: [TISInputSource?] = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        for case let source? in sources {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            let found: CGKeyCode? = data.withUnsafeBytes { raw in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                for code in 0..<UInt16(128) {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                    )
                    if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1) == String(character) {
                        return CGKeyCode(code)
                    }
                }
                return nil
            }
            if let found { return found }
        }
        return nil
    }
}
