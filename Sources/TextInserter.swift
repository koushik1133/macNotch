import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Types dictated text into whatever text field has focus in the frontmost app.
///
/// 1. Accessibility: replace the focused element's `kAXSelectedTextAttribute`.
///    Used only for native text roles in apps known to honor it, and verified
///    through the character count, because many apps (browsers, Electron)
///    report success without inserting anything.
/// 2. Otherwise the pasteboard: save every item, put the text on it (marked
///    transient so clipboard managers skip it), post Cmd+V, then restore the
///    saved items unless something else wrote to the pasteboard meanwhile.
///
/// Both need the Accessibility permission. Without it, or while Secure Input
/// is on, the text is left on the clipboard and an error is returned.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        case inserted
        case failed(String)
    }

    /// Restoring the clipboard is chained so back-to-back insertions never
    /// snapshot each other's temporary contents.
    private static var pendingRestore: Task<Void, Never>?

    /// Apps whose text views claim AX writes succeed but ignore or garble them.
    private static let pasteOnlyBundlePrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.", "com.brave.Browser", "company.thebrowser.",
        "com.operasoftware.", "com.vivaldi.", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode",
        "com.todesktop.", "com.hnc.Discord", "notion.id", "com.figma.Desktop", "com.electron.",
        "com.github.GitHubClient", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "com.jetbrains.", "com.microsoft.Word", "com.microsoft.Outlook", "com.microsoft.teams",
        "com.spotify.client", "md.obsidian", "com.openai.chat", "com.anthropic.claudefordesktop", "com.linear",
    ]

    static func insert(_ text: String) async -> Outcome {
        guard !text.isEmpty else { return .inserted }

        guard PermissionCenter.shared.isGranted(.accessibility) else {
            copyToClipboard(text)
            AppLog.log("Dictation: Accessibility missing; text left on the clipboard")
            return .failed("Allow Accessibility for SparkV")
        }
        if IsSecureEventInputEnabled() {
            copyToClipboard(text)
            AppLog.log("Dictation: Secure Input is on; text left on the clipboard")
            return .failed("Secure input is on – text copied")
        }

        // Pasting while the hotkey (Option) or another modifier is still held
        // would turn Cmd+V into a different shortcut.
        await waitForModifierRelease()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let denyList = pasteOnlyBundlePrefixes
        let attempt = await Task.detached(priority: .userInitiated) {
            Self.insertViaAccessibility(text, ownPID: ownPID, pasteOnlyPrefixes: denyList)
        }.value

        switch attempt.result {
        case .inserted:
            AppLog.log("Dictation: inserted \(attempt.text.count) chars via Accessibility into \(attempt.appID)")
            return .inserted
        case .ownApp:
            copyToClipboard(text)
            AppLog.log("Dictation: focus is in SparkV itself; text left on the clipboard")
            return .failed("Click a text field first – text copied")
        case .notInserted:
            await pasteViaPasteboard(attempt.text)
            AppLog.log("Dictation: inserted \(attempt.text.count) chars via Cmd+V into \(attempt.appID)")
            return .inserted
        }
    }

    // MARK: - Accessibility

    private enum AXResult: Sendable {
        case inserted
        case notInserted
        case ownApp
    }

    private struct AXAttempt: Sendable {
        var result: AXResult
        /// The text actually used, possibly with a leading space added.
        var text: String
        var appID: String
    }

    /// Runs off the main thread: AX calls are synchronous IPC to the target app.
    nonisolated private static func insertViaAccessibility(
        _ original: String, ownPID: pid_t, pasteOnlyPrefixes: [String]
    ) -> AXAttempt {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.4)

        guard let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) else {
            return AXAttempt(result: .notInserted, text: original, appID: frontmostID())
        }
        AXUIElementSetMessagingTimeout(focused, 0.4)

        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        if pid == ownPID {
            return AXAttempt(result: .ownApp, text: original, appID: "SparkV")
        }
        let appID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? frontmostID()

        // Smart spacing: dictating right after a word adds a separating space.
        var text = original
        let selection = copyRange(focused, kAXSelectedTextRangeAttribute)
        if let selection, selection.location > 0,
           let previous = copyString(focused, forRange: CFRange(location: selection.location - 1, length: 1))?.last,
           needsLeadingSpace(after: previous, before: text) {
            text = " " + text
        }

        let role = copyString(focused, kAXRoleAttribute) ?? ""
        let subrole = copyString(focused, kAXSubroleAttribute) ?? ""
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        let pasteOnly = pasteOnlyPrefixes.contains { appID.hasPrefix($0) }
        guard textRoles.contains(role), subrole != kAXSecureTextFieldSubrole, !pasteOnly else {
            return AXAttempt(result: .notInserted, text: text, appID: appID)
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return AXAttempt(result: .notInserted, text: text, appID: appID)
        }

        let before = copyInt(focused, kAXNumberOfCharactersAttribute)
        let status = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString)
        guard status == .success else {
            return AXAttempt(result: .notInserted, text: text, appID: appID)
        }
        let after = copyInt(focused, kAXNumberOfCharactersAttribute)
        if let before, let after {
            let expected = before - (selection?.length ?? 0) + text.utf16.count
            if after == before, expected != before {
                // Claimed success, changed nothing: fall back to pasting.
                return AXAttempt(result: .notInserted, text: text, appID: appID)
            }
            if after != expected {
                AppLog.log("Dictation: AX insert length mismatch (expected \(expected), got \(after)); keeping it")
            }
        }
        return AXAttempt(result: .inserted, text: text, appID: appID)
    }

    nonisolated private static func needsLeadingSpace(after previous: Character, before text: String) -> Bool {
        guard let first = text.first else { return false }
        if previous.isWhitespace || "([{\"'“‘/-@#\n\t".contains(previous) { return false }
        return first.isLetter || first.isNumber || "\"“(".contains(first)
    }

    nonisolated private static func frontmostID() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    }

    nonisolated private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    nonisolated private static func copyInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        (copyValue(element, attribute) as? NSNumber)?.intValue
    }

    nonisolated private static func copyRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    nonisolated private static func copyString(_ element: AXUIElement, forRange range: CFRange) -> String? {
        var cfRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        )
        guard status == .success else { return nil }
        return value as? String
    }

    // MARK: - Pasteboard + Cmd+V

    private static func pasteViaPasteboard(_ text: String) async {
        await pendingRestore?.value

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org markers: clipboard managers ignore this entry.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        try? await Task.sleep(nanoseconds: 40_000_000)
        postCommandV()

        // Apps read the pasteboard asynchronously after Cmd+V; restore later.
        pendingRestore = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard pasteboard.changeCount == ourChangeCount else {
                AppLog.log("Dictation: pasteboard changed meanwhile; not restoring")
                return
            }
            restore(saved, to: pasteboard)
        }
    }

    /// Puts `text` on the general pasteboard as an ordinary copy (Flow
    /// history, Ctrl+Cmd+C), unlike the transient entry used for pasting.
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        copyToClipboard(text)
    }

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.compactMap { entries in
            guard !entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private static func waitForModifierRelease() async {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let commandKey = CGKeyCode(kVK_Command)
        let events = [
            CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false),
        ]
        for (index, event) in events.enumerated() {
            guard let event else { continue }
            event.flags = index == 3 ? [] : .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: PushToTalkMonitor.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Key code that types `character` in the current keyboard layout, so
    /// Cmd+V also works on Dvorak, AZERTY and similar layouts.
    private static func keyCode(for character: Character) -> CGKeyCode? {
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
