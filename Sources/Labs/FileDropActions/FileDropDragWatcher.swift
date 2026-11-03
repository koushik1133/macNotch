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
///
/// During a file drag it also watches for a *shake* (three quick left-right
/// reversals) or a held modifier key, Dropover style: either one summons
/// the drop shelf right at the pointer, so files don't have to travel to
/// the notch. That math runs only while a file drag is live.
@MainActor
final class FileDropDragWatcher {
    enum Event: Equatable {
        case began
        case moved(NSPoint)
        /// Shaken, or the shelf key held: show the shelf at this point.
        case summoned(NSPoint)
        case ended
    }

    var onEvent: ((Event) -> Void)?
    private(set) var isDraggingFiles = false
    /// Settings seams (the app reads ShelfSettings).
    var shakeEnabled: () -> Bool = { ShelfSettings.shared.shakeForShelf }
    var summonKey: () -> NSEvent.ModifierFlags? = { ShelfSettings.shared.holdKey.flag }
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private let pasteboard: NSPasteboard
    private var monitors: [Any] = []
    /// Lives only while a file drag is live, so a key pressed with the
    /// pointer still summons the shelf too.
    private var flagsMonitor: Any?
    private var changeCountAtMouseDown: Int
    /// The drag pasteboard is read at most once per change: a drag that
    /// isn't a file drag (a link, a tab, text) isn't re-read on every one
    /// of its 60-120 mouse-dragged events a second.
    private var checkedChangeCount: Int?
    private var checkedVerdict = false
    private var endWatch: Task<Void, Never>?
    private var shake = FileDropShakeDetector()
    /// One summon per drag.
    private var summoned = false
    /// The modifier was already down when the drag began (not a request).
    private var keyHeldAtStart = false

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
        unwatchFlags()
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
            guard newDragCarriesFiles() else { return }
            // Only once per session, even if the types are re-read.
            changeCountAtMouseDown = pasteboard.changeCount
            isDraggingFiles = true
            shake.reset()
            summoned = false
            keyHeldAtStart = summonKey().map { modifierFlags().contains($0) } ?? false
            onEvent?(.began)
            watchForEnd()
            watchFlags()
        }
        onEvent?(.moved(point))
        guard !summoned else { return }
        if checkSummonKey(at: point) { return }
        if shakeEnabled(), shake.add(x: point.x, at: clock()) {
            summoned = true
            onEvent?(.summoned(point))
        }
    }

    /// The summon key went down during the drag (not held from before).
    @discardableResult
    func checkSummonKey(at point: NSPoint) -> Bool {
        guard isDraggingFiles, !summoned, let key = summonKey() else { return false }
        let held = modifierFlags().contains(key)
        if held, !keyHeldAtStart {
            summoned = true
            onEvent?(.summoned(point))
            return true
        }
        if !held { keyHeldAtStart = false }
        return false
    }

    /// Modifier changes while the pointer is still.
    func flagsChanged() {
        checkSummonKey(at: NSEvent.mouseLocation)
    }

    private func watchFlags() {
        guard flagsMonitor == nil, summonKey() != nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.flagsChanged() }
        })
    }

    private func unwatchFlags() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }

    func mouseUp() {
        guard isDraggingFiles else { return }
        isDraggingFiles = false
        endWatch?.cancel()
        endWatch = nil
        unwatchFlags()
        shake.reset()
        onEvent?(.ended)
    }

    /// A file drag from another app is under way right now, checked
    /// directly (the window controller's monitor may see a mouse-dragged
    /// event before this watcher does): the drag pasteboard changed since
    /// the last mouse-down and declares files. A stale pasteboard from an
    /// earlier drag never counts.
    func isFileDragLive(buttons: Int = NSEvent.pressedMouseButtons) -> Bool {
        if isDraggingFiles { return true }
        guard buttons & 1 != 0 else { return false }
        return newDragCarriesFiles()
    }

    /// The drag pasteboard changed since the last mouse-down and declares
    /// files; the verdict is cached per change count.
    private func newDragCarriesFiles() -> Bool {
        let count = pasteboard.changeCount
        guard count != changeCountAtMouseDown else { return false }
        if count == checkedChangeCount { return checkedVerdict }
        let verdict = Self.carriesFiles(on: pasteboard)
        checkedChangeCount = count
        checkedVerdict = verdict
        return verdict
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
    ///
    /// Browser link and tab drags are the trap: Safari and Chrome add a
    /// promised `.webloc` (content type `com.apple.web-internet-location`)
    /// and often a favicon or preview image next to `public.url`. So when
    /// the drag carries a URL and no file URL, image types don't count, and
    /// a promise only counts when its declared content type is a real file
    /// (`promisedContentTypes`, read from the pasteboard's promise metadata,
    /// never the file). An unknown promise beside a URL doesn't count.
    nonisolated static func carriesFiles(_ types: [NSPasteboard.PasteboardType],
                                         promisedContentTypes: [String] = []) -> Bool {
        let raw = Set(types.map(\.rawValue))
        if raw.contains(NSPasteboard.PasteboardType.fileURL.rawValue) || raw.contains("NSFilenamesPboardType") { return true }
        let carriesURL = !raw.isDisjoint(with: urlTypes)
        let promised = raw.contains("com.apple.pasteboard.promised-file-url") || raw.contains("com.apple.NSFilePromiseItemMetaData")
            || raw.contains(promisedContentTypeKey)
        if promised {
            let real = promisedContentTypes.filter { !isWebLocation($0) }
            if !promisedContentTypes.isEmpty { return !real.isEmpty }
            if !carriesURL { return true }
        }
        if carriesURL { return false }
        return raw.contains { UTType($0)?.conforms(to: .image) == true }
    }

    /// Same check against a live pasteboard: its types plus each item's
    /// declared promise content type (metadata only).
    static func carriesFiles(on pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard !types.isEmpty else { return false }
        var promisedTypes: [String] = []
        if types.contains(where: { $0.rawValue == promisedContentTypeKey }) {
            let key = NSPasteboard.PasteboardType(promisedContentTypeKey)
            promisedTypes = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: key) }
        }
        return carriesFiles(types, promisedContentTypes: promisedTypes)
    }

    nonisolated static let promisedContentTypeKey = "com.apple.pasteboard.promised-file-content-type"
    nonisolated static let urlTypes: Set<String> = [
        "public.url", "public.url-name", "WebURLsWithTitlesPboardType", "Apple URL pasteboard type",
        "org.chromium.chromium-renderer-initiated-drag", "com.apple.webarchive",
    ]
    nonisolated static func isWebLocation(_ type: String) -> Bool {
        if type == "com.apple.web-internet-location" || type == "public.url" || type == "com.apple.internet-location" { return true }
        guard let t = UTType(type) else { return false }
        return t.conforms(to: .url) || t.conforms(to: .internetShortcut)
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

    /// The shelf next to the pointer (shake or held key): centred on it,
    /// `gap` above (below when there's no room), inside the visible frame
    /// of the screen the pointer is on, so it never covers what's under it.
    static func pointerZoneFrame(point: NSPoint, visible: NSRect, size: CGSize = FileDropLayout.zoneSize,
                                 gap: CGFloat = FileDropLayout.pointerGap) -> NSRect {
        let margin: CGFloat = 8
        var x = point.x - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)
        var y = point.y + gap
        if y + size.height > visible.maxY - margin {
            y = point.y - gap - size.height
        }
        y = min(max(y, visible.minY + margin), visible.maxY - margin - size.height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The screen the point is on (any display), else the notched one.
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? targetScreen()
    }

    /// The notched built-in display, else the main screen (as the notch
    /// window does).
    static func targetScreen() -> NSScreen? {
        // The island's display; nil while the island is hidden or ignores
        // hover (full screen, an excluded app), so no shelf appears there.
        IslandScreen.shelfScreen
    }

    static func notchHeight(of screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? menuBar : 24
    }
}

/// Spots a shake in a drag: `reversalsNeeded` changes of horizontal
/// direction within `window` seconds, each leg at least `minLeg` points.
/// A normal drag (even a wobbly one) doesn't reverse that fast that far.
struct FileDropShakeDetector: Equatable {
    var minLeg: CGFloat = 30
    var window: TimeInterval = 0.7
    var reversalsNeeded = 3

    private var started = false
    private var direction = 0
    private var legStart: CGFloat = 0
    private var extreme: CGFloat = 0
    private var reversals: [TimeInterval] = []

    mutating func reset() {
        started = false
        direction = 0
        reversals.removeAll()
    }

    /// Feeds one pointer position; true when it completes a shake.
    mutating func add(x: CGFloat, at time: TimeInterval) -> Bool {
        guard started else {
            started = true
            legStart = x
            extreme = x
            return false
        }
        if direction == 0 {
            if abs(x - legStart) >= minLeg {
                direction = x > legStart ? 1 : -1
                extreme = x
            }
            return false
        }
        // Still going the same way: the leg grows.
        if (direction > 0 && x >= extreme) || (direction < 0 && x <= extreme) {
            extreme = x
            return false
        }
        // Back by a full leg: a reversal.
        guard abs(extreme - x) >= minLeg else { return false }
        reversals.append(time)
        reversals.removeAll { time - $0 > window }
        legStart = extreme
        extreme = x
        direction = -direction
        if reversals.count >= reversalsNeeded {
            reset()
            return true
        }
        return false
    }
}
