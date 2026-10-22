import AppKit
import ApplicationServices

/// What the Accessibility API reported about the front app's focus.
struct QuickCaptureFocus: Sendable, Equatable {
    var selectedText: String?
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    /// The focused element is a password field: nothing was read.
    var isSecure = false
}

/// Reads the selected text of the frontmost app through Accessibility, the
/// way PopClip-style tools and the selected-text crates do it:
/// `AXSelectedText` on the system-wide focused element, then
/// `AXSelectedTextRange` + `AXStringForRange`, then the frontmost app's own
/// focused element. Chromium/Electron apps build their accessibility tree
/// only for assistive apps, so they get `AXManualAccessibility` (Electron's
/// documented switch) once and a short retry. It never synthesises ⌘C and
/// never touches the pasteboard; password fields and SparkV itself are skipped.
enum QuickCaptureSelectionReader {
    /// Apps that need `AXManualAccessibility` before they expose selections.
    static let manualAccessibilityPrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.", "com.vivaldi.",
        "com.operasoftware.", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.todesktop.", "com.hnc.Discord",
        "notion.id", "com.figma.Desktop", "com.electron.", "md.obsidian", "com.linear", "com.github.GitHubClient",
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.microsoft.teams2", "net.whatsapp.WhatsApp",
    ]

    /// Seam for tests: the whole read, replaced by a fake.
    nonisolated(unsafe) static var reader: @Sendable () async -> QuickCaptureFocus = { await readLive() }

    static func read() async -> QuickCaptureFocus { await reader() }

    /// Whether SparkV may read other apps' text. Never prompts.
    static var isTrusted: Bool { PermissionCenter.isAccessibilityTrustedNow }

    static func needsManualAccessibility(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return manualAccessibilityPrefixes.contains { bundleID.hasPrefix($0) }
    }

    // MARK: - Live

    static func readLive() async -> QuickCaptureFocus {
        let front = await MainActor.run { () -> (pid_t, String?, String?) in
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.processIdentifier ?? 0, app?.bundleIdentifier, app?.localizedName)
        }
        var focus = QuickCaptureFocus(appBundleID: front.1, appName: front.2)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard PermissionCenter.isAccessibilityTrustedNow, front.0 != 0, front.0 != ownPID else { return focus }

        let pid = front.0
        let manual = needsManualAccessibility(front.1)
        let result = await Task.detached(priority: .userInitiated) { () -> QuickCaptureFocus in
            var attempt = Self.readOnce(pid: pid, ownPID: ownPID, enableManual: manual)
            if attempt.selectedText == nil, !attempt.isSecure, manual {
                // The tree builds asynchronously after AXManualAccessibility.
                for _ in 0..<3 where attempt.selectedText == nil {
                    usleep(120_000)
                    attempt = Self.readOnce(pid: pid, ownPID: ownPID, enableManual: false)
                }
            }
            return attempt
        }.value
        focus.selectedText = result.selectedText
        focus.windowTitle = result.windowTitle
        focus.isSecure = result.isSecure
        return focus
    }

    /// One pass over the AX tree. Runs off the main thread (synchronous IPC).
    nonisolated static func readOnce(pid: pid_t, ownPID: pid_t, enableManual: Bool) -> QuickCaptureFocus {
        var focus = QuickCaptureFocus()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        if enableManual {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if let window = element(app, kAXFocusedWindowAttribute) {
            focus.windowTitle = string(window, kAXTitleAttribute)
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.35)
        var candidates: [AXUIElement] = []
        if let focused = element(systemWide, kAXFocusedUIElementAttribute) {
            var focusedPID: pid_t = 0
            AXUIElementGetPid(focused, &focusedPID)
            if focusedPID == ownPID { return focus }
            if focusedPID == pid { candidates.append(focused) }
        }
        if let focused = element(app, kAXFocusedUIElementAttribute) { candidates.append(focused) }

        for candidate in candidates {
            AXUIElementSetMessagingTimeout(candidate, 0.35)
            if string(candidate, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
                focus.isSecure = true
                return focus
            }
            if let text = selectedText(of: candidate) {
                focus.selectedText = text
                return focus
            }
        }
        return focus
    }

    nonisolated static func selectedText(of element: AXUIElement) -> String? {
        if let text = string(element, kAXSelectedTextAttribute), !text.isEmpty { return text }
        guard let range = range(element, kAXSelectedTextRangeAttribute), range.length > 0 else { return nil }
        var cfRange = range
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, value, &result
        ) == .success, let text = result as? String, !text.isEmpty else { return nil }
        return text
    }

    nonisolated private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    nonisolated private static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}
