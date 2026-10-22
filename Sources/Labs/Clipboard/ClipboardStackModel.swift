import AppKit

// Keyboard model of the clipboard stack panel (⌘⇧V), kept free of views so
// the harness can drive it with synthetic keys. Behaviour follows Paste's
// stack and Maccy's popup: numbers 1–9 on the newest items, ↑/↓ and the
// scroll wheel move the selection, ↩ pastes, ⌘1…9 pastes that item,
// Space previews, ⌫ deletes, P pins, typing filters, Esc closes.

/// A key press, reduced to what the panel needs (built from an NSEvent, or
/// by hand in tests).
struct ClipboardStackKey: Equatable, Sendable {
    var keyCode: UInt16
    /// `charactersIgnoringModifiers`, lowercased.
    var characters: String
    /// The typed text (`characters`), for the search query.
    var text: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(keyCode: UInt16, characters: String = "", text: String? = nil,
         command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters.lowercased()
        self.text = text ?? characters
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(keyCode: event.keyCode,
                  characters: event.charactersIgnoringModifiers ?? "",
                  text: event.characters ?? "",
                  command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }

    // Virtual key codes (Carbon kVK_*).
    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16 = 53
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let home: UInt16 = 115
    static let end: UInt16 = 119
}

@MainActor
final class ClipboardStackModel: ObservableObject {
    enum Command: Equatable {
        case paste(ClipboardItem, plainText: Bool)
        case copy(ClipboardItem)
        case delete(ClipboardItem)
        case togglePin(ClipboardItem)
        case smartAction(ClipboardItem)
        case close
    }

    @Published var query = ""
    /// Typing goes to the query (after "/" or the first non-command letter),
    /// so "p" and Space type instead of pinning and previewing.
    @Published private(set) var isSearching = false
    @Published private(set) var selection = 0
    @Published var isPreviewing = false
    /// A pinned item waiting for a second ⌫.
    @Published private(set) var armedDeleteID: UUID?
    /// Hover only moves the selection after the pointer really moved, so a
    /// panel opening under the pointer keeps item 1 selected.
    var pointerMoved = false

    static let maxNumbered = 9
    /// Points of scrolling per selection step (trackpads); a wheel notch is one step.
    static let scrollStep: CGFloat = 14

    private let itemsProvider: () -> [ClipboardItem]
    private var scrollAccumulator: CGFloat = 0

    init(items: @escaping () -> [ClipboardItem]) {
        itemsProvider = items
    }

    /// The stack, newest first (1 = most recent), filtered by the query.
    var visibleItems: [ClipboardItem] {
        Self.filter(itemsProvider(), query: query)
    }

    var selectedItem: ClipboardItem? {
        let items = visibleItems
        return items.indices.contains(selection) ? items[selection] : items.first
    }

    static func filter(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return items }
        return items.filter { item in
            let haystack = item.searchableText
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Fresh state each time the panel opens.
    func reset() {
        query = ""
        isSearching = false
        selection = 0
        isPreviewing = false
        armedDeleteID = nil
        pointerMoved = false
        scrollAccumulator = 0
    }

    func select(_ index: Int) {
        let count = visibleItems.count
        guard count > 0 else { selection = 0; return }
        selection = min(max(0, index), count - 1)
        armedDeleteID = nil
    }

    func select(id: UUID) {
        if let index = visibleItems.firstIndex(where: { $0.id == id }) { select(index) }
    }

    /// Keeps the selection valid after items change.
    func clampSelection() {
        let count = visibleItems.count
        if selection >= count { selection = max(0, count - 1) }
    }

    /// Scroll wheel / trackpad: moves the selection one row per step.
    func scroll(deltaY: CGFloat, precise: Bool) {
        guard deltaY != 0 else { return }
        if !precise {
            move(deltaY > 0 ? -1 : 1)
            return
        }
        scrollAccumulator += deltaY
        while abs(scrollAccumulator) >= Self.scrollStep {
            move(scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator -= scrollAccumulator > 0 ? Self.scrollStep : -Self.scrollStep
        }
    }

    func move(_ delta: Int) {
        select(selection + delta)
    }

    /// Handles a key; returns the command for the controller (nil when the
    /// key only changed panel state). `handled` is false for keys the panel
    /// doesn't use (they go on to the responder chain).
    func handle(_ key: ClipboardStackKey) -> (handled: Bool, command: Command?) {
        let items = visibleItems
        let selected = items.indices.contains(selection) ? items[selection] : items.first

        // ⌘ shortcuts first.
        if key.command, !key.control {
            if let digit = Int(key.characters), (1...Self.maxNumbered).contains(digit) {
                guard items.indices.contains(digit - 1) else { return (true, nil) }
                return (true, .paste(items[digit - 1], plainText: key.shift))
            }
            switch key.keyCode {
            case ClipboardStackKey.up: select(0); return (true, nil)
            case ClipboardStackKey.down: select(items.count - 1); return (true, nil)
            case ClipboardStackKey.returnKey, ClipboardStackKey.enterKey:
                return (true, selected.map { .copy($0) })
            case ClipboardStackKey.delete, ClipboardStackKey.forwardDelete:
                return (true, selected.map { .delete($0) })
            default: break
            }
            switch key.characters {
            case "p": return (true, selected.map { .togglePin($0) })
            case "o": return (true, selected.map { .smartAction($0) })
            case "f": isSearching = true; return (true, nil)
            case "c": return (true, selected.map { .copy($0) })
            // ⌘⇧V again closes (toggle); ⌘V pastes the selection.
            case "v": return (true, key.shift ? .close : selected.map { .paste($0, plainText: false) })
            case "w": return (true, .close)
            case "a":
                // Select-all is meaningless here; swallow it.
                return (true, nil)
            default: return (false, nil)
            }
        }
        if key.option, !key.command, !key.control, key.characters == "p" {
            return (true, selected.map { .togglePin($0) })
        }

        switch key.keyCode {
        case ClipboardStackKey.escape:
            if !query.isEmpty || isSearching {
                query = ""
                isSearching = false
                select(0)
                return (true, nil)
            }
            if isPreviewing { isPreviewing = false; return (true, nil) }
            return (true, .close)
        case ClipboardStackKey.returnKey, ClipboardStackKey.enterKey:
            return (true, selected.map { .paste($0, plainText: key.shift) })
        case ClipboardStackKey.up:
            move(-1); return (true, nil)
        case ClipboardStackKey.down, ClipboardStackKey.tab:
            move(key.keyCode == ClipboardStackKey.tab && key.shift ? -1 : 1); return (true, nil)
        case ClipboardStackKey.pageUp: move(-8); return (true, nil)
        case ClipboardStackKey.pageDown: move(8); return (true, nil)
        case ClipboardStackKey.home: select(0); return (true, nil)
        case ClipboardStackKey.end: select(items.count - 1); return (true, nil)
        case ClipboardStackKey.right:
            isPreviewing = true; return (true, nil)
        case ClipboardStackKey.left:
            isPreviewing = false; return (true, nil)
        case ClipboardStackKey.delete:
            if !query.isEmpty {
                query.removeLast()
                if query.isEmpty { isSearching = false }
                select(0)
                return (true, nil)
            }
            if isSearching { isSearching = false; return (true, nil) }
            return (true, deleteCommand(for: selected))
        case ClipboardStackKey.forwardDelete:
            return (true, deleteCommand(for: selected))
        case ClipboardStackKey.space where !isSearching && query.isEmpty:
            isPreviewing.toggle()
            return (true, nil)
        default:
            break
        }

        guard !key.control else { return (false, nil) }
        let typed = key.text.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard !typed.isEmpty else { return (false, nil) }
        if !isSearching, query.isEmpty {
            if key.characters == "p", !key.shift { return (true, selected.map { .togglePin($0) }) }
            if typed == "/" { isSearching = true; return (true, nil) }
        }
        isSearching = true
        query += typed
        select(0)
        return (true, nil)
    }

    /// Unpinned items go at once; a pinned one needs a second press.
    private func deleteCommand(for item: ClipboardItem?) -> Command? {
        guard let item else { return nil }
        if item.isPinned, armedDeleteID != item.id {
            armedDeleteID = item.id
            return nil
        }
        armedDeleteID = nil
        return .delete(item)
    }
}

// MARK: - Placement

enum ClipboardStackPlacement {
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// Where the panel goes for an anchor rect (the text caret, or a point
    /// at the pointer), in Cocoa screen coordinates: just below the anchor,
    /// left-aligned with it; above it when there's no room below; always
    /// inside `visible` (the screen's visible frame).
    static func frame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        var x = anchor.minX
        var y = anchor.minY - gap - size.height
        if y < visible.minY + margin {
            // Above the caret.
            let above = anchor.maxY + gap
            y = above + size.height <= visible.maxY - margin ? above : visible.minY + margin
        }
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)
        y = min(max(y, visible.minY + margin), visible.maxY - margin - size.height)
        if size.width > visible.width - 2 * margin { x = visible.minX + max(0, (visible.width - size.width) / 2) }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Converts an Accessibility rect (top-left origin of the primary
    /// screen, y down) to Cocoa coordinates (bottom-left, y up).
    static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Finds the text caret of the focused app through Accessibility (the
/// bounds of the selected range), as Maccy's "at text cursor" position does.
enum ClipboardCaretLocator {
    /// Caret rect in Accessibility coordinates, or nil (no AX access, no
    /// text field, or an app that reports nothing useful).
    nonisolated static func caretRectAX() -> CGRect? {
        // Off the main thread: PermissionCenter's nonisolated preflight,
        // which never prompts.
        guard PermissionCenter.isAccessibilityTrustedNow else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue {
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                           rangeValue, &bounds) == .success,
               let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.origin != .zero || rect.height > 0,
                   rect.height > 0, rect.height < 400 {
                    return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
                }
            }
        }
        // Fallback: the top-left of a small focused element (a single-line
        // field). Big text areas give no useful position.
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.height > 0, size.height <= 60 else { return nil }
        return CGRect(origin: origin, size: CGSize(width: min(size.width, 40), height: size.height))
    }
}
