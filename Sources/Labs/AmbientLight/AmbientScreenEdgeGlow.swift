import AppKit
import CoreGraphics
import QuartzCore

// Screen edges: one borderless, click-through, non-activating panel per
// screen, above normal windows and the Dock but below the menu bar and menus,
// drawing `AmbientEdgeStrips`. Kept out of screenshots and recordings
// (`sharingType = .none`), left out of full-screen spaces (no
// `.fullScreenAuxiliary`), and hidden on a screen that shows a full-screen
// window or while the screen is shared.

final class AmbientEdgePanel: NSPanel {
    let strips: AmbientEdgeStrips
    let displayID: CGDirectDisplayID

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        strips = AmbientEdgeStrips()
        self.displayID = displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // isFloatingPanel resets `level`, so it comes first.
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(strips.root)
        contentView = view
        fit(to: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func fit(to screen: NSScreen) {
        setFrame(screen.frame, display: false)
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        // With the menu bar hidden, visibleFrame reaches the top: keep a
        // notch-height margin on notched screens anyway.
        let topInset = max(menuBar, screen.safeAreaInsets.top)
        strips.root.contentsScale = screen.backingScaleFactor
        strips.layout(bounds: CGRect(origin: .zero, size: screen.frame.size), topInset: topInset,
                      thickness: CGFloat(AmbientLightSettings.shared.edgeWidth))
    }
}

/// Owns the edge panels and decides which screens may show them.
@MainActor
final class AmbientScreenEdgeGlow {
    private var panels: [CGDirectDisplayID: AmbientEdgePanel] = [:]
    private var suppressed: Set<CGDirectDisplayID> = []
    private var screenShared = false
    private(set) var isShown = false
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    /// Reasons other features set (a SparkV screen recording, a meeting
    /// that shares the screen). Any reason hides every edge.
    private var externalReasons: Set<String> = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSuppression() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    func setExternalSuppression(_ suppressed: Bool, reason: String) {
        if suppressed { externalReasons.insert(reason) } else { externalReasons.remove(reason) }
        refreshSuppression()
    }

    /// Shows the panels (on screens that allow it) or hides them all.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            ensurePanels()
            refreshSuppression()
            // Full-screen windows can appear without an app switch (a video
            // going full screen in place): re-check every 2 s while shown.
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSuppression() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            for panel in panels.values { panel.orderOut(nil) }
        }
    }

    /// Per display frame.
    func render(_ frame: AmbientVisualFrame, palette: AmbientLightPalette) {
        guard isShown else { return }
        for panel in panels.values where panel.isVisible {
            panel.strips.render(frame, palette: palette)
        }
    }

    func relayout() {
        for (id, panel) in panels {
            if let screen = NSScreen.screens.first(where: { $0.ambientDisplayID == id }) { panel.fit(to: screen) }
        }
    }

    /// Re-sends colors on the next frame (palette changed).
    func invalidate() {
        for panel in panels.values { panel.strips.invalidate() }
    }

    func tearDown() {
        setShown(false)
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }

    private func ensurePanels() {
        let screens = NSScreen.screens
        let ids = Set(screens.compactMap(\.ambientDisplayID))
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            panels[id] = nil
        }
        for screen in screens {
            guard let id = screen.ambientDisplayID else { continue }
            if let panel = panels[id] {
                panel.fit(to: screen)
            } else {
                panels[id] = AmbientEdgePanel(screen: screen, displayID: id)
            }
        }
    }

    private func screensChanged() {
        guard isShown else { return }
        ensurePanels()
        refreshSuppression()
    }

    func refreshSuppression() {
        guard isShown else { return }
        screenShared = AmbientDisplaySuppression.isScreenShared()
        suppressed = AmbientDisplaySuppression.displaysWithFullScreenWindows()
        let hideAll = screenShared || !externalReasons.isEmpty
        for (id, panel) in panels {
            let visible = !hideAll && !suppressed.contains(id)
            if visible, !panel.isVisible {
                panel.strips.invalidate()
                panel.orderFrontRegardless()
            } else if !visible, panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }
}

/// Cheap, permission-free checks (window bounds and owners, no titles).
enum AmbientDisplaySuppression {
    /// Displays covered edge to edge by another app's normal-level window
    /// (a full-screen video or game that isn't in its own space).
    static func displaysWithFullScreenWindows() -> Set<CGDirectDisplayID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var displays: [(CGDirectDisplayID, CGRect)] = []
        for screen in NSScreen.screens {
            if let id = screen.ambientDisplayID { displays.append((id, CGDisplayBounds(id))) }
        }
        let own = getpid()
        var covered: Set<CGDirectDisplayID> = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            for (id, frame) in displays where abs(bounds.minX - frame.minX) < 1.5 && abs(bounds.minY - frame.minY) < 1.5
                && abs(bounds.width - frame.width) < 1.5 && abs(bounds.height - frame.height) < 1.5 {
                covered.insert(id)
            }
        }
        return covered
    }

    /// macOS Screen Sharing / Remote Management is viewing this session.
    /// (Conferencing apps' sharing is reported through
    /// `AmbientLightController.setEdgeSuppression`, see INTEGRATION.md.)
    static func isScreenShared() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsShared"] as? Bool) ?? false
    }
}

extension NSScreen {
    var ambientDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
