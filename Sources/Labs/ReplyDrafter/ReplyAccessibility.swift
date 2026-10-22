import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Live Accessibility access: reading the frontmost window into a
// `ReplyWindowSnapshot`, and the message box / Subject field of another app
// as a `ReplyWritableField`. AX calls are synchronous IPC to the target app,
// so reads run off the main thread with short messaging timeouts.

/// AXUIElement is a CFType that is safe to use from any thread.
final class ReplyAXElement: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

struct ReplyLiveSnapshot: Sendable {
    var snapshot: ReplyWindowSnapshot
    /// Parallel to `snapshot.nodes`.
    var elements: [ReplyAXElement]
    var pid: pid_t
}

enum ReplyAXReader {
    /// Apps where SparkV turned on `AXManualAccessibility` this session.
    nonisolated(unsafe) private static var enabledPIDs = Set<pid_t>()
    private static let lock = NSLock()

    /// Reads the app's focused window. Blocking: call off the main thread.
    nonisolated static func capture(pid: pid_t, bundleID: String, appName: String, maxNodes: Int = 4_000, timeBudget: TimeInterval = 2.5) -> ReplyLiveSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        if ReplyContextDetector.needsManualAccessibility(bundleID) { enableWebAccessibility(app, pid: pid) }

        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
            ?? (copy(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        let focused = element(app, kAXFocusedUIElementAttribute)
        let windowFrame = frame(of: window) ?? .zero
        let title = copy(window, kAXTitleAttribute) as? String ?? ""

        var nodes: [ReplyAXNode] = []
        var elements: [ReplyAXElement] = []
        var focusedIndex: Int?
        let deadline = Date().addingTimeInterval(timeBudget)
        var stack: [(AXUIElement, Int?, Int)] = [(window, nil, 0)]
        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
            kAXPlaceholderValueAttribute, kAXIdentifierAttribute, "AXDOMIdentifier", "AXDOMClassList",
            kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXURLAttribute, kAXFocusedAttribute,
        ] as [CFString]
        while let (current, parent, depth) = stack.popLast() {
            if nodes.count >= maxNodes || Date() > deadline { break }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(current, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [AnyObject], values.count == names.count else { continue }
            func string(_ i: Int) -> String {
                guard CFGetTypeID(values[i]) == CFStringGetTypeID() else { return "" }
                return values[i] as? String ?? ""
            }
            var node = ReplyAXNode(role: string(0))
            node.subrole = string(1)
            node.title = string(2)
            node.label = string(3)
            if node.subrole != kAXSecureTextFieldSubrole as String {
                let value = string(4)
                node.value = value.count > 8_000 ? String(value.prefix(8_000)) : value
            }
            node.placeholder = string(5)
            node.identifier = string(6).isEmpty ? string(7) : string(6)
            if CFGetTypeID(values[8]) == CFArrayGetTypeID() { node.domClasses = (values[8] as? [String]) ?? [] }
            node.frame = rect(position: values[9], size: values[10]) ?? .zero
            if CFGetTypeID(values[12]) == CFURLGetTypeID() { node.url = (values[12] as? URL)?.absoluteString ?? "" }
            node.isFocused = (values[13] as? Bool) ?? false
            node.depth = depth
            node.parent = parent
            if ["AXTextArea", "AXTextField", "AXComboBox"].contains(node.role), node.subrole != kAXSecureTextFieldSubrole as String {
                node.isEditable = isSettable(current, kAXValueAttribute) || isSettable(current, kAXSelectedTextAttribute) || node.isFocused
            }
            let index = nodes.count
            nodes.append(node)
            elements.append(ReplyAXElement(current))
            if let focused, CFEqual(focused, current) { focusedIndex = index }

            // Skip subtrees that are entirely outside the window (scrolled away).
            if node.frame.width > 0, node.frame.height > 0, !node.frame.intersects(windowFrame), depth > 0 { continue }
            if node.role == "AXTextArea" || node.role == "AXTextField" || node.role == "AXStaticText" { continue }
            guard CFGetTypeID(values[11]) == CFArrayGetTypeID(), let children = values[11] as? [AXUIElement] else { continue }
            for child in children.reversed() { stack.append((child, index, depth + 1)) }
        }
        // The focused element may live outside the walked part (budget).
        if focusedIndex == nil, let focused, var node = node(for: focused) {
            node.isFocused = true
            focusedIndex = nodes.count
            nodes.append(node)
            elements.append(ReplyAXElement(focused))
        }
        let snapshot = ReplyWindowSnapshot(bundleID: bundleID, appName: appName, windowTitle: title, windowFrame: windowFrame, nodes: nodes, focusedIndex: focusedIndex)
        return ReplyLiveSnapshot(snapshot: snapshot, elements: elements, pid: pid)
    }

    /// Electron and Chromium build the web AX tree only when asked
    /// (`AXManualAccessibility`, from Electron's accessibility docs). The
    /// first read after turning it on waits briefly for the tree.
    nonisolated private static func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
        lock.lock()
        let already = enabledPIDs.contains(pid)
        lock.unlock()
        guard !already else { return }
        let status = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        lock.lock()
        enabledPIDs.insert(pid)
        lock.unlock()
        if status == .success { Thread.sleep(forTimeInterval: 0.35) }
    }

    nonisolated static func node(for element: AXUIElement) -> ReplyAXNode? {
        guard let role = copy(element, kAXRoleAttribute) as? String else { return nil }
        var node = ReplyAXNode(role: role)
        node.subrole = copy(element, kAXSubroleAttribute) as? String ?? ""
        node.label = copy(element, kAXDescriptionAttribute) as? String ?? ""
        node.title = copy(element, kAXTitleAttribute) as? String ?? ""
        node.placeholder = copy(element, kAXPlaceholderValueAttribute) as? String ?? ""
        if node.subrole != kAXSecureTextFieldSubrole as String { node.value = copy(element, kAXValueAttribute) as? String ?? "" }
        node.frame = frame(of: element) ?? .zero
        node.isEditable = ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) && node.subrole != kAXSecureTextFieldSubrole as String
        return node
    }

    // MARK: AX helpers

    nonisolated static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        rect(position: copy(element, kAXPositionAttribute), size: copy(element, kAXSizeAttribute))
    }

    nonisolated static func rect(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    nonisolated static func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetType(value as! AXValue) == .cfRange, AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    @discardableResult
    nonisolated static func setRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}

// MARK: - Writable field

/// The message box (or Subject) of another app.
///
/// Write order, like assistive apps and Grammarly: select the range through
/// `AXSelectedTextRange` and set `AXSelectedText` (native fields), verified
/// by reading the value back because browsers and Electron often report
/// success without changing anything; otherwise paste over the selection with
/// `TextInserter` (pasteboard saved and restored, marked transient).
@MainActor
final class ReplyAXField: ReplyWritableField {
    let box: ReplyAXElement
    let pid: pid_t
    let bundleID: String
    let role: String

    /// Browsers, Electron and other apps whose fields claim AX writes worked
    /// without applying them (same list idea as TextInserter).
    static let pasteOnlyPrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.", "com.brave.Browser", "company.thebrowser.",
        "com.operasoftware.", "com.vivaldi.", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams",
        "com.microsoft.Outlook", "desktop.WhatsApp", "com.electron.", "com.todesktop.", "org.chromium.",
    ]

    /// Tests turn this off: no app activation, no pasteboard, no key events.
    static var allowsSideEffects = true

    init(element: ReplyAXElement, pid: pid_t, bundleID: String, role: String) {
        box = element
        self.pid = pid
        self.bundleID = bundleID
        self.role = role
    }

    var frame: CGRect? { ReplyAXReader.frame(of: box.element) }

    private var axWritable: Bool { !Self.pasteOnlyPrefixes.contains { bundleID.hasPrefix($0) } }

    func read() async -> ReplyFieldState? {
        let box = box
        return await Task.detached(priority: .userInitiated) { () -> ReplyFieldState? in
            AXUIElementSetMessagingTimeout(box.element, 0.5)
            guard let value = ReplyAXReader.copy(box.element, kAXValueAttribute) as? String else { return nil }
            let selection = ReplyAXReader.range(box.element, kAXSelectedTextRangeAttribute)
            let placeholder = ReplyAXReader.copy(box.element, kAXPlaceholderValueAttribute) as? String ?? ""
            return ReplyFieldState(value: value, selection: selection, placeholder: placeholder)
        }.value
    }

    func replace(_ range: NSRange, with text: String) async -> Bool {
        await bringToFront()
        let box = box
        let before = await read()
        let axWritable = axWritable
        // 1. Accessibility write, verified.
        if axWritable, let before, range.location != NSNotFound {
            let baseline = before.value == before.placeholder ? "" : before.value
            let expected = ReplyInsertionPlanner.applying(text, to: baseline, in: range)
            let wrote = await Task.detached(priority: .userInitiated) { () -> Bool in
                _ = AXUIElementSetAttributeValue(box.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                guard ReplyAXReader.setRange(box.element, range) else { return false }
                return AXUIElementSetAttributeValue(box.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
            }.value
            if wrote, let after = await read() {
                if ReplyTextLocator.normalizedEqual(after.value, expected) { return true }
                if !ReplyTextLocator.normalizedEqual(after.value, before.value) {
                    // The write landed but the editor reformatted it (rich
                    // text, smart quotes): accept it when the text is there,
                    // never paste a second copy on top.
                    if text.isEmpty || ReplyTextLocator.locate(text, in: after.value, near: range.location) != nil { return true }
                    // Changed in some other way. Only a plain one-line field
                    // can be put back by value; resetting a rich editor's
                    // AXValue would flatten the quoted thread and signature.
                    guard role == "AXTextField" else {
                        AppLog.log("Reply Drafter: the field changed unexpectedly; not writing again")
                        return false
                    }
                    let original = before.value
                    await Task.detached(priority: .userInitiated) {
                        _ = AXUIElementSetAttributeValue(box.element, kAXValueAttribute as CFString, original as CFString)
                    }.value
                }
            }
            // A plain text field can take the whole value.
            if role == "AXTextField" {
                let status = await Task.detached(priority: .userInitiated) { () -> AXError in
                    guard ReplyAXReader.isSettable(box.element, kAXValueAttribute) else { return .attributeUnsupported }
                    return AXUIElementSetAttributeValue(box.element, kAXValueAttribute as CFString, expected as CFString)
                }.value
                if status == .success, let after = await read(), ReplyTextLocator.normalizedEqual(after.value, expected) { return true }
            }
        }
        guard Self.allowsSideEffects else { return false }
        // 2. Select the range, then paste over it (or delete for empty text).
        if range.location != NSNotFound {
            let length = before.map { ($0.value as NSString).length } ?? 0
            let selected = await Task.detached(priority: .userInitiated) { () -> Bool in
                _ = AXUIElementSetAttributeValue(box.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return ReplyAXReader.setRange(box.element, range)
                    && (ReplyAXReader.range(box.element, kAXSelectedTextRangeAttribute).map { $0 == range } ?? true)
            }.value
            if !selected {
                if range.location == 0, range.length >= length, length > 0 {
                    ReplyKeys.post(keyCode: CGKeyCode(kVK_ANSI_A), command: true)
                } else if range.location == 0, range.length == 0 {
                    ReplyKeys.post(keyCode: CGKeyCode(kVK_UpArrow), command: true)
                } else {
                    AppLog.log("Reply Drafter: couldn't select the text to replace")
                    return false
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        } else {
            await focus()
        }
        if text.isEmpty {
            if range.length > 0 { ReplyKeys.post(keyCode: CGKeyCode(kVK_Delete), command: false) }
        } else {
            guard await TextInserter.insert(text) == .inserted else { return false }
        }
        try? await Task.sleep(nanoseconds: 260_000_000)
        if let before, range.location != NSNotFound, let after = await read() {
            let expected = ReplyInsertionPlanner.applying(text, to: before.value == before.placeholder ? "" : before.value, in: range)
            if !ReplyTextLocator.normalizedEqual(after.value, expected) {
                // Rich editors reformat pasted text; accept when the text is there.
                return text.isEmpty || ReplyTextLocator.locate(text, in: after.value, near: range.location) != nil
            }
        }
        return true
    }

    func focus() async {
        let box = box
        await Task.detached(priority: .userInitiated) {
            _ = AXUIElementSetAttributeValue(box.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }.value
    }

    func nativeUndo() async -> Bool {
        guard Self.allowsSideEffects else { return false }
        await bringToFront()
        ReplyKeys.post(keyCode: CGKeyCode(kVK_ANSI_Z), command: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        return true
    }

    func nativeRedo() async -> Bool {
        guard Self.allowsSideEffects else { return false }
        await bringToFront()
        ReplyKeys.post(keyCode: CGKeyCode(kVK_ANSI_Z), command: true, shift: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        return true
    }

    /// The app must be frontmost for pasting and ⌘Z.
    private func bringToFront() async {
        guard Self.allowsSideEffects else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
        app.activate()
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
        }
    }
}

/// Synthetic key presses, tagged like TextInserter's so SparkV's own
/// monitors ignore them. Only ⌘A / ⌘↑ / ⌘Z / ⇧⌘Z / Delete; never Return.
enum ReplyKeys {
    /// The only keys this feature may post. Return / Enter (which send in
    /// chat apps) are not on it, so they are refused rather than posted.
    static let allowedKeys: Set<CGKeyCode> = [
        CGKeyCode(kVK_ANSI_A), CGKeyCode(kVK_ANSI_Z), CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_Delete),
    ]

    static func post(keyCode: CGKeyCode, command: Bool, shift: Bool = false) {
        guard allowedKeys.contains(keyCode) else {
            AppLog.log("Reply Drafter: refused to post key \(keyCode)")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: PushToTalkMonitor.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
