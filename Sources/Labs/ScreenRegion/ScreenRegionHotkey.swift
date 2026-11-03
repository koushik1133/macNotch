import AppKit
import Carbon.HIToolbox

/// A key + modifiers combination, stored with Carbon values.
struct ScreenRegionShortcut: Codable, Equatable, Sendable {
    /// Virtual key code (kVK_*).
    var keyCode: UInt32
    /// Carbon modifier mask (controlKey | optionKey | cmdKey | shiftKey).
    var carbonModifiers: UInt32

    /// ⌃⌥S.
    static let defaultShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = Self.carbon(from: modifiers)
    }

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask = 0
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.command) { mask |= cmdKey }
        return UInt32(mask)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let mask = Int(carbonModifiers)
        if mask & controlKey != 0 { flags.insert(.control) }
        if mask & optionKey != 0 { flags.insert(.option) }
        if mask & shiftKey != 0 { flags.insert(.shift) }
        if mask & cmdKey != 0 { flags.insert(.command) }
        return flags
    }

    /// A global shortcut needs at least one of ⌃⌥⌘ (Shift alone would eat typing).
    var isValidGlobal: Bool {
        !modifierFlags.intersection([.control, .option, .command]).isEmpty
    }

    /// "⌃⌥S", in the order macOS menus use.
    var displayString: String {
        let flags = modifierFlags
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Escape: "Esc", kVK_Return: "↩", kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".",
            // Recordable in Settings › Accessibility › Keyboard Shortcuts.
            kVK_ANSI_Comma: ",", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Grave: "`", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
            kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return letters[Int(code)] ?? "Key \(code)"
    }
}

/// Global hotkeys via Carbon `RegisterEventHotKey`, the approach of
/// sindresorhus/KeyboardShortcuts (MIT): no Accessibility permission, no
/// prompt, and the keystroke is consumed so it doesn't also reach the front
/// app. Events arrive on the main thread.
@MainActor
final class ScreenRegionHotkey {
    var onPress: (() -> Void)?
    private(set) var shortcut: ScreenRegionShortcut?
    private var ref: EventHotKeyRef?
    private let identifier: UInt32

    init() {
        identifier = ScreenRegionHotkeyCenter.nextIdentifier()
    }

    var isRegistered: Bool { ref != nil }

    /// Registers (replacing any previous shortcut). False when macOS refused,
    /// e.g. another app already owns the combination.
    @discardableResult
    func register(_ shortcut: ScreenRegionShortcut) -> Bool {
        unregister()
        guard ScreenRegionHotkeyCenter.installHandlerIfNeeded() else { return false }
        var newRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: ScreenRegionHotkeyCenter.signature, id: identifier)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            AppLog.log("Screen Region: hotkey \(shortcut.displayString) not registered (status \(status))")
            return false
        }
        ref = newRef
        self.shortcut = shortcut
        ScreenRegionHotkeyCenter.handlers[identifier] = { [weak self] in self?.onPress?() }
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        shortcut = nil
        ScreenRegionHotkeyCenter.handlers[identifier] = nil
    }
}

/// One Carbon event handler shared by every `ScreenRegionHotkey`.
@MainActor
enum ScreenRegionHotkeyCenter {
    /// 'NIsr'.
    static let signature: OSType = 0x4E49_7372
    static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var counter: UInt32 = 0

    static func nextIdentifier() -> UInt32 {
        counter &+= 1
        return counter
    }

    static func installHandlerIfNeeded() -> Bool {
        guard !installed else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard read == noErr, hotKeyID.signature == ScreenRegionHotkeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let handler = ScreenRegionHotkeyCenter.handlers[id] else { return false }
                handler()
                return true
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, nil, nil)
        installed = status == noErr
        if !installed { AppLog.log("Screen Region: InstallEventHandler failed (\(status))") }
        return installed
    }
}
