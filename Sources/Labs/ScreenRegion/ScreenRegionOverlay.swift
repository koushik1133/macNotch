import AppKit

// Region-selection overlay, modeled on `screencapture -i`: a transparent
// panel on every display, crosshair, drag to select with the outside dimmed
// and a live size badge, Space toggles window-pick mode, Esc (or a right
// click) cancels, a click without a drag picks the window under the pointer.

/// What one overlay session is for: its hint text, accent and keys. The
/// default is "Ask about screen"; Copy Text and Screen Recording pass their own.
struct ScreenRegionOverlayOptions {
    /// Hint pill in region mode (nil: the Ask-about-screen text).
    var regionHint: String?
    /// Hint pill in window-pick mode.
    var windowHint: String?
    /// Window highlight and selection border color.
    /// System accent (blue) in the Apple look, the brand red in SparkV Red.
    var accent: NSColor = SparkVTheme.isApple ? .controlAccentColor : NSColor(srgbRed: 240 / 255, green: 24 / 255, blue: 34 / 255, alpha: 1)
    /// Return picks the whole display under the pointer (screen recording).
    /// The completion then gets `.region(rect: display.frame, display:)`.
    var returnSelectsDisplay = false
    /// Accessibility title of the overlay panels.
    var title = "Ask about screen"

    static let standard = ScreenRegionOverlayOptions()
}

/// Shared state of one selection session across every display's panel.
@MainActor
final class ScreenRegionOverlayState {
    enum Mode: Equatable { case region, window }

    var mode: Mode
    var displays: [ScreenRegionDisplay]
    /// Front-to-back, AppKit coordinates.
    var windows: [ScreenRegionWindowInfo]
    /// Pointer in AppKit global points.
    var mouse: CGPoint
    var dragStart: CGPoint?
    var dragCurrent: CGPoint?
    var dragDisplay: ScreenRegionDisplay?
    var options: ScreenRegionOverlayOptions

    init(mode: Mode, displays: [ScreenRegionDisplay], windows: [ScreenRegionWindowInfo], mouse: CGPoint,
         options: ScreenRegionOverlayOptions = .standard) {
        self.options = options
        self.mode = mode
        self.displays = displays
        self.windows = windows
        self.mouse = mouse
    }

    var isDragging: Bool { dragStart != nil }

    /// The rectangle being dragged, clamped to the display it started on.
    var selectionRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent, let display = dragDisplay,
              !ScreenRegionGeometry.isClick(from: start, to: current) else { return nil }
        return ScreenRegionGeometry.clampedRect(from: start, to: current, in: display.frame)
    }

    var hoveredWindow: ScreenRegionWindowInfo? {
        guard mode == .window, !isDragging else { return nil }
        return ScreenRegionGeometry.window(at: mouse, in: windows)
    }

    func windowSelection(_ window: ScreenRegionWindowInfo) -> ScreenRegionSelection? {
        guard let display = ScreenRegionGeometry.display(for: window.frame, in: displays) else { return nil }
        return .window(id: window.id, frame: window.frame, display: display, appName: window.appName, title: window.title)
    }
}

/// Borderless full-screen panel above everything, including the menu bar
/// and the notch drawer.
final class ScreenRegionOverlayPanel: NSPanel {
    init(frame: NSRect, title panelTitle: String = "Ask about screen") {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
        title = panelTitle
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws one display's part of the overlay and forwards input.
final class ScreenRegionOverlayView: NSView {
    let display: ScreenRegionDisplay
    let state: ScreenRegionOverlayState
    weak var controller: ScreenRegionOverlayController?
    private var tracking: NSTrackingArea?

    static let dimColor = NSColor.black.withAlphaComponent(0.32)
    static let accent = NSColor(srgbRed: 240 / 255, green: 24 / 255, blue: 34 / 255, alpha: 1)  // SparkV red

    init(display: ScreenRegionDisplay, state: ScreenRegionOverlayState) {
        self.display = display
        self.state = state
        super.init(frame: NSRect(origin: .zero, size: display.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    private var currentCursor: NSCursor {
        state.mode == .window && !state.isDragging ? .pointingHand : .crosshair
    }

    // MARK: Input

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        currentCursor.set()
        controller?.pointerMoved(to: globalPoint(event))
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.pointerMoved(to: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        controller?.pointerDown(at: globalPoint(event), on: display)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.pointerDragged(to: globalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.pointerUp(at: globalPoint(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.cancel()           // Esc
        case 49: controller?.toggleMode()       // Space
        case 36 where state.options.returnSelectsDisplay,   // Return
             76 where state.options.returnSelectsDisplay:   // Enter
            controller?.selectDisplayUnderPointer()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancel()
    }

    // MARK: Drawing

    /// Converts AppKit global points into this view.
    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let hole: CGRect?
        if let selection = state.selectionRect, state.dragDisplay?.id == display.id {
            hole = local(selection)
        } else if let window = state.hoveredWindow {
            hole = local(window.frame).intersection(bounds)
        } else {
            hole = nil
        }

        // Dim everything outside the hole (even-odd fill).
        let dim = NSBezierPath(rect: bounds)
        if let hole, !hole.isNull, !hole.isEmpty {
            dim.appendRect(hole)
            dim.windingRule = .evenOdd
        }
        Self.dimColor.setFill()
        dim.fill()

        if let selection = state.selectionRect, state.dragDisplay?.id == display.id {
            drawSelection(local(selection))
        } else if let window = state.hoveredWindow, let hole, !hole.isNull, !hole.isEmpty {
            drawWindowHighlight(hole, window: window)
        } else if !state.isDragging, state.mode == .region, display.frame.contains(state.mouse) {
            drawCrosshair(at: CGPoint(x: state.mouse.x - display.frame.minX, y: state.mouse.y - display.frame.minY))
        }
        if !state.isDragging, display.frame.contains(state.mouse) {
            drawHint()
        }
    }

    private func drawSelection(_ rect: CGRect) {
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()
        // Corner ticks.
        NSColor.white.setFill()
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            NSBezierPath(ovalIn: CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6)).fill()
        }
        drawBadge(ScreenRegionGeometry.badgeText(for: rect), near: rect)
    }

    private func drawWindowHighlight(_ rect: CGRect, window: ScreenRegionWindowInfo) {
        let accent = state.options.accent
        accent.withAlphaComponent(0.16).setFill()
        rect.fill()
        let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        accent.setStroke()
        border.stroke()
        let name = [window.appName, window.title].compactMap { $0 }.joined(separator: " — ")
        drawBadge(name.isEmpty ? ScreenRegionGeometry.badgeText(for: rect) : String(name.prefix(60)), near: rect)
    }

    private func drawCrosshair(at point: CGPoint) {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: point.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y.rounded() + 0.5))
        path.move(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.minY))
        path.line(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.maxY))
        path.stroke()
    }

    private func drawBadge(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let size = CGSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 6)
        let origin = ScreenRegionGeometry.badgeOrigin(badgeSize: size, selection: rect, bounds: bounds)
        let pill = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: pill, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        string.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3))
    }

    private func drawHint() {
        let text = state.mode == .region
            ? (state.options.regionHint ?? "Drag to select  ·  Click a window  ·  Space: pick window  ·  Esc: cancel")
            : (state.options.windowHint ?? "Click a window  ·  Space: drag a region  ·  Esc: cancel")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let size = CGSize(width: ceil(textSize.width) + 28, height: ceil(textSize.height) + 12)
        // Below the menu bar and the notch drawer.
        let pill = CGRect(x: (bounds.midX - size.width / 2).rounded(), y: bounds.maxY - 96 - size.height, width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        string.draw(at: CGPoint(x: pill.minX + 14, y: pill.minY + 6))
    }
}

/// Runs one selection session over every display.
@MainActor
final class ScreenRegionOverlayController {
    private var panels: [ScreenRegionOverlayPanel] = []
    private var views: [ScreenRegionOverlayView] = []
    private var state: ScreenRegionOverlayState?
    private var completion: ((ScreenRegionSelection?) -> Void)?
    private let escapeKey = ScreenRegionHotkey()
    private let spaceKey = ScreenRegionHotkey()
    private let returnKey = ScreenRegionHotkey()
    private var screenObserver: NSObjectProtocol?

    var isActive: Bool { state != nil }

    /// Sessions open in any controller (Ask about screen, Copy Text, Record).
    /// Only one may own the screen and its Esc/Space/Return keys at a time.
    private static var openSessions = 0
    static var isAnyActive: Bool { openSessions > 0 }

    /// Shows the overlay. `completion` gets the selection, or nil when cancelled.
    /// Screen Recording must already be granted (window titles and the capture need it).
    func begin(
        mode: ScreenRegionOverlayState.Mode = .region,
        options: ScreenRegionOverlayOptions = .standard,
        completion: @escaping (ScreenRegionSelection?) -> Void
    ) {
        if isActive { finish(nil) }
        let displays = ScreenRegionCapture.displays()
        guard !displays.isEmpty else {
            completion(nil)
            return
        }
        let state = ScreenRegionOverlayState(
            mode: mode, displays: displays,
            windows: ScreenRegionCapture.onScreenWindows(),
            mouse: NSEvent.mouseLocation,
            options: options
        )
        self.state = state
        self.completion = completion
        Self.openSessions += 1

        for display in displays {
            let panel = ScreenRegionOverlayPanel(frame: display.frame, title: options.title)
            let view = ScreenRegionOverlayView(display: display, state: state)
            view.controller = self
            panel.contentView = view
            panel.setFrame(display.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        // Key focus on the panel under the pointer, so Esc/Space reach a view
        // even if the Carbon keys below can't be registered.
        let keyIndex = displays.firstIndex { $0.frame.contains(state.mouse) } ?? 0
        panels[keyIndex].makeKey()
        panels[keyIndex].makeFirstResponder(views[keyIndex])
        NSCursor.crosshair.set()

        // While the overlay is up, Esc and Space belong to it (as with the
        // system screenshot tool), whichever app is active.
        escapeKey.onPress = { [weak self] in self?.cancel() }
        spaceKey.onPress = { [weak self] in self?.toggleMode() }
        escapeKey.register(ScreenRegionShortcut(keyCode: 53, carbonModifiers: 0))
        spaceKey.register(ScreenRegionShortcut(keyCode: 49, carbonModifiers: 0))
        if options.returnSelectsDisplay {
            returnKey.onPress = { [weak self] in self?.selectDisplayUnderPointer() }
            returnKey.register(ScreenRegionShortcut(keyCode: 36, carbonModifiers: 0))
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        AppLog.log("Screen Region: overlay on \(displays.count) display(s), \(state.windows.count) window(s)")
    }

    func cancel() {
        guard isActive else { return }
        AppLog.log("Screen Region: selection cancelled")
        finish(nil)
    }

    func toggleMode() {
        guard let state, !state.isDragging else { return }
        state.mode = state.mode == .region ? .window : .region
        redraw(cursors: true)
    }

    /// Return in a session with `returnSelectsDisplay`: the whole display
    /// under the pointer, as a region equal to its frame.
    func selectDisplayUnderPointer() {
        guard let state, state.options.returnSelectsDisplay, !state.isDragging,
              let display = ScreenRegionGeometry.display(containing: NSEvent.mouseLocation, in: state.displays)
                ?? state.displays.first
        else { return }
        finish(.region(rect: display.frame, display: display))
    }

    // MARK: Pointer (AppKit global points)

    func pointerMoved(to point: CGPoint) {
        guard let state else { return }
        state.mouse = point
        redraw()
    }

    func pointerDown(at point: CGPoint, on display: ScreenRegionDisplay) {
        guard let state else { return }
        state.mouse = point
        state.dragStart = point
        state.dragCurrent = point
        state.dragDisplay = display
        redraw(cursors: true)
    }

    func pointerDragged(to point: CGPoint) {
        guard let state, state.isDragging else { return }
        state.mouse = point
        state.dragCurrent = point
        redraw()
    }

    func pointerUp(at point: CGPoint) {
        guard let state, let start = state.dragStart, let display = state.dragDisplay else { return }
        state.mouse = point
        state.dragCurrent = point
        let isClick = ScreenRegionGeometry.isClick(from: start, to: point)
        // A drag selects a region in either mode; a click picks a window.
        if !isClick {
            let rect = ScreenRegionGeometry.clampedRect(from: start, to: point, in: display.frame)
            if ScreenRegionGeometry.isCapturable(rect) {
                finish(.region(rect: rect, display: display))
                return
            }
        } else if let window = ScreenRegionGeometry.window(at: point, in: state.windows),
                  let selection = state.windowSelection(window) {
            finish(selection)
            return
        }
        // Too small, or a click on the desktop: keep selecting.
        state.dragStart = nil
        state.dragCurrent = nil
        state.dragDisplay = nil
        redraw(cursors: true)
    }

    // MARK: Private

    private func redraw(cursors: Bool = false) {
        for view in views {
            view.needsDisplay = true
            if cursors { view.window?.invalidateCursorRects(for: view) }
        }
    }

    private func finish(_ selection: ScreenRegionSelection?) {
        if state != nil { Self.openSessions = max(0, Self.openSessions - 1) }
        escapeKey.unregister()
        spaceKey.unregister()
        returnKey.unregister()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        state = nil
        NSCursor.arrow.set()
        let completion = completion
        self.completion = nil
        completion?(selection)
    }
}
