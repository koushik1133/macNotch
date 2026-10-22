import AppKit
import UniformTypeIdentifiers

/// Notices a file drag from another app (Finder, a browser, the screenshot
/// thumbnail) and reports where the pointer is, so the shelf can appear as
/// the drag nears the notch.
///
/// Same technique as the notch shelves (NotchNook, NotchDrop, Dropover's
/// "drop to notch"): the drag pasteboard's `changeCount` is remembered on
/// mouse-down and compared on mouse-dragged; a change means a new drag
/// session started, and its declared types say whether it carries files.
/// Global monitors see every pointer event bound to other apps without
/// Accessibility permission. Drags that start inside SparkV (a file leaving
/// the Tray or the strip) only reach local monitors, so they never open the
/// shelf. The pasteboard's contents are never read here, only its types.
@MainActor
final class FileDropDragWatcher {
    enum Event: Equatable {
        case began
        case moved(NSPoint)
        case ended
    }

    var onEvent: ((Event) -> Void)?
    private(set) var isDraggingFiles = false

    private let pasteboard: NSPasteboard
    private var monitors: [Any] = []
    private var changeCountAtMouseDown: Int
    private var endWatch: Task<Void, Never>?

    init(pasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        self.pasteboard = pasteboard
        changeCountAtMouseDown = pasteboard.changeCount
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(down) }
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged(at: NSEvent.mouseLocation) }
        }) { monitors.append(dragged) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }) { monitors.append(up) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endWatch?.cancel()
        endWatch = nil
        if isDraggingFiles {
            isDraggingFiles = false
            onEvent?(.ended)
        }
    }

    // MARK: Event handling (internal so tests can drive it with a named pasteboard)

    func mouseDown() {
        changeCountAtMouseDown = pasteboard.changeCount
    }

    func mouseDragged(at point: NSPoint) {
        if !isDraggingFiles {
            guard pasteboard.changeCount != changeCountAtMouseDown, Self.carriesFiles(pasteboard.types ?? []) else { return }
            // Only once per session, even if the types are re-read.
            changeCountAtMouseDown = pasteboard.changeCount
            isDraggingFiles = true
            onEvent?(.began)
            watchForEnd()
        }
        onEvent?(.moved(point))
    }

    func mouseUp() {
        guard isDraggingFiles else { return }
        isDraggingFiles = false
        endWatch?.cancel()
        endWatch = nil
        onEvent?(.ended)
    }

    /// A drag session can end without a mouse-up reaching the global
    /// monitor (dropped on an app that swallows it, Esc). Poll the button
    /// state while a file drag is live.
    private func watchForEnd() {
        endWatch?.cancel()
        endWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.mouseUp()
                    return
                }
            }
        }
    }

    /// File URLs, promised files (Mail attachments, Photos) and image data
    /// (the screenshot thumbnail) count; plain text and links don't.
    static func carriesFiles(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let raw = Set(types.map(\.rawValue))
        if raw.contains(NSPasteboard.PasteboardType.fileURL.rawValue) || raw.contains("NSFilenamesPboardType") { return true }
        if raw.contains("com.apple.pasteboard.promised-file-url") || raw.contains("com.apple.NSFilePromiseItemMetaData")
            || raw.contains("com.apple.pasteboard.promised-file-content-type") { return true }
        return raw.contains { UTType($0)?.conforms(to: .image) == true }
    }

    // MARK: Geometry

    /// True when `point` is close enough to the notch at the top centre of
    /// `screen` for the shelf to show. `margin` grows the area (used to keep
    /// a visible shelf open while the pointer wobbles at its edge).
    static func isNearNotch(_ point: NSPoint, screen: NSRect, margin: CGFloat = 0) -> Bool {
        let size = FileDropLayout.proximity
        let area = NSRect(x: screen.midX - size.width / 2 - margin, y: screen.maxY - size.height - margin,
                          width: size.width + 2 * margin, height: size.height + margin + 2)
        return area.contains(point)
    }

    /// The shelf's frame: centred under the notch (and under a live
    /// activity band when one is showing), `FileDropLayout.zoneGap` below it.
    static func zoneFrame(screen: NSRect, notchHeight: CGFloat, bandHeight: CGFloat = 0) -> NSRect {
        let size = FileDropLayout.zoneSize
        return NSRect(x: (screen.midX - size.width / 2).rounded(),
                      y: (screen.maxY - notchHeight - bandHeight - FileDropLayout.zoneGap - size.height).rounded(),
                      width: size.width, height: size.height)
    }

    /// The notched built-in display, else the main screen (as the notch
    /// window does).
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    static func notchHeight(of screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? menuBar : 24
    }
}
