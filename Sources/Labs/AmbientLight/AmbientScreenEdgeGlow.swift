import AppKit
import CoreGraphics
import QuartzCore

// Screen edges: one borderless, click-through, non-activating panel per
// screen covering the whole screen frame, menu bar strip included, so the
// light runs along the true physical edge and around the notch. It sits at
// the island's level (`.statusBar`, above the menu bar; `.floating` while the
// island is lowered over a full-screen app) and is ordered just below the
// island, so the island's black body stays on top and the light seems to
// spill out from behind it. Kept out of screenshots and recordings
// (`sharingType = .none`), joins full-screen spaces too, and hidden while the
// screen is shared (and over full-screen windows only if the user asks).
// Drawn by `AmbientEdgeMetalRenderer`, or by `AmbientEdgeStrips` when Metal
// isn't available.

final class AmbientEdgePanel: NSPanel {
    /// Fallback when Metal (or the runtime shader) is unavailable.
    let strips: AmbientEdgeStrips?
    let metal: AmbientEdgeMetalRenderer?
    let displayID: CGDirectDisplayID

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        if let gpu = AmbientEdgeGPU.shared {
            metal = AmbientEdgeMetalRenderer(gpu: gpu)
            strips = nil
        } else {
            metal = nil
            strips = AmbientEdgeStrips()
        }
        self.displayID = displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // isFloatingPanel resets `level`, so it comes first.
        isFloatingPanel = true
        level = Self.targetLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.isOpaque = false
        if let metal { view.layer?.addSublayer(metal.layer) }
        if let strips { view.layer?.addSublayer(strips.root) }
        contentView = view
        fit(to: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The island's level: above the menu bar normally, lowered with it over
    /// full-screen apps.
    @MainActor static var targetLevel: NSWindow.Level { ExtrasIslandCover.islandLevel }

    func fit(to screen: NSScreen) {
        setFrame(screen.frame, display: false)
        let size = screen.frame.size
        let edgeWidth = CGFloat(AmbientLightSettings.shared.edgeWidth)
        if let metal {
            metal.layout(size: size, backingScale: screen.backingScaleFactor,
                         cornerRadius: Self.cornerRadius(of: displayID), notch: Self.notch(of: screen), edgeWidth: edgeWidth)
        }
        if let strips {
            strips.root.contentsScale = screen.backingScaleFactor
            // The top strip runs along the very top edge (over the menu bar).
            strips.layout(bounds: CGRect(origin: .zero, size: size), topInset: 0, thickness: edgeWidth)
        }
    }

    /// Follows the island on this screen; the camera housing otherwise.
    func setIsland(_ rect: CGRect?, radius: CGFloat) {
        guard let metal, let screen else { return }
        let f = screen.frame
        if let rect, rect.width > 20, f.insetBy(dx: -1, dy: -1).contains(CGPoint(x: rect.midX, y: rect.maxY - 1)) {
            let height = max(0, f.maxY - rect.minY)
            metal.setNotchTarget((rect.minX - f.minX, rect.maxX - f.minX, height), radius: radius)
        } else {
            metal.setNotchTarget(Self.notch(of: screen), radius: 9)
        }
    }

    /// The window server wasn't showing the panel last frame.
    private var wasOccluded = false

    func render(_ frame: AmbientVisualFrame, palette: AmbientLightPalette, mode: AmbientLightMode,
                intensity: Double, reduceMotion: Bool) {
        // Not on screen (display asleep, screen locked, just ordered in):
        // no frame. A drawable the window server never takes back would make
        // `nextDrawable()` wait up to 1 s on the main thread.
        guard occlusionState.contains(.visible) else {
            wasOccluded = true
            return
        }
        if wasOccluded {
            // Whatever was last presented may be stale: draw afresh.
            wasOccluded = false
            invalidateContent()
        }
        if let metal {
            metal.render(frame, palette: palette, mode: mode, intensity: intensity, reduceMotion: reduceMotion)
        } else {
            strips?.render(frame, palette: palette)
        }
    }

    func invalidateContent() {
        metal?.invalidate()
        strips?.invalidate()
    }

    /// Shows the panel and keeps it just under the island on this screen.
    func present() {
        let target = Self.targetLevel
        if level != target { level = target }
        orderFrontRegardless()
        for window in NSApp.windows where window is NotchPanel && window.isVisible && window.level == level
            && window.frame.intersects(frame) {
            order(.below, relativeTo: window.windowNumber)
            break
        }
    }

    /// Built-in MacBook displays have rounded corners (about 10–12 pt);
    /// external ones are square (a small radius keeps the light's corner soft).
    static func cornerRadius(of displayID: CGDirectDisplayID) -> CGFloat {
        CGDisplayIsBuiltin(displayID) != 0 ? 12 : 4
    }

    /// The camera housing in points from the screen's top-left: left x,
    /// right x, height. Nil on screens without a notch.
    static func notch(of screen: NSScreen) -> (x0: CGFloat, x1: CGFloat, height: CGFloat)? {
        let height = screen.safeAreaInsets.top
        guard height > 0, let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width else { return nil }
        let x0 = left, x1 = screen.frame.width - right
        guard x1 - x0 > 40, x1 - x0 < screen.frame.width / 2 else { return nil }
        return (x0, x1, height)
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
    /// Cached here (read on show and every suppression check), not per frame.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

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

    /// The island's live outline in screen coordinates (nil: use the camera
    /// housing). Each panel wraps it on its own screen.
    func setIsland(_ rect: CGRect?, radius: CGFloat) {
        for panel in panels.values where panel.isVisible {
            panel.setIsland(rect, radius: radius)
        }
    }

    /// Per display frame.
    func render(_ frame: AmbientVisualFrame, palette: AmbientLightPalette) {
        guard isShown else { return }
        let settings = AmbientLightSettings.shared
        let mode = settings.mode
        let intensity = settings.intensity
        for panel in panels.values where panel.isVisible {
            panel.render(frame, palette: palette, mode: mode, intensity: intensity, reduceMotion: reduceMotion)
        }
    }

    func relayout() {
        for (id, panel) in panels {
            if let screen = NSScreen.screens.first(where: { $0.ambientDisplayID == id }) { panel.fit(to: screen) }
        }
    }

    /// Re-sends colors on the next frame (palette changed).
    func invalidate() {
        for panel in panels.values { panel.invalidateContent() }
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
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        screenShared = AmbientDisplaySuppression.isScreenShared()
        // Over full-screen apps is the default: then the window list (the
        // costly part of this check) isn't read at all.
        suppressed = AmbientLightSettings.shared.overFullScreen ? [] : AmbientDisplaySuppression.displaysWithFullScreenWindows()
        let hideAll = screenShared || !externalReasons.isEmpty
        for (id, panel) in panels {
            let visible = !hideAll && !suppressed.contains(id)
            if visible, !panel.isVisible || panel.level != AmbientEdgePanel.targetLevel {
                panel.invalidateContent()
                panel.present()
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
