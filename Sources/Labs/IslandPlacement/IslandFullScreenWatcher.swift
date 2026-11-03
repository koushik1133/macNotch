import AppKit
import ApplicationServices
import CoreGraphics

/// Which displays have a full-screen window, per display (each display
/// has its own Space with "Displays have separate Spaces").
///
/// Event-driven: Space changes, app switches, app launches and quits and
/// display changes trigger a check (again 0.8 s and 1.6 s later, after the
/// full-screen animation). A slow, tolerant 2 s check runs only while a
/// display is already full screen (to see it end), or while the front app
/// could go full screen in place without any notification: it has a
/// window filling nearly all of a display the island uses (a video's own
/// full-screen button), or it is a presenter or player (Keynote,
/// PowerPoint, Preview, QuickTime, IINA, VLC) whose slideshow needs no
/// Space change. Only while someone is using the Mac: with no input for a
/// few seconds it parks until the pointer moves again (`noteActivity()`).
/// The window list and Accessibility are read off the main thread.
///
/// No permission is needed: window bounds and owners only (no titles, no
/// pixels). On a notched display a native full-screen window sits below
/// the camera, exactly where a zoomed window sits when the Dock hides
/// itself; Accessibility (if the user already allowed it for SparkV)
/// tells the two apart, otherwise a visible Dock does, and with the Dock
/// hidden, whether that display's desktop picture is still on screen (a
/// full-screen Space has none).
@MainActor
final class IslandFullScreenWatcher {
    private(set) var fullScreenDisplays: Set<CGDirectDisplayID> = []
    /// Called on the main actor when the set changes.
    var onChange: ((Set<CGDirectDisplayID>) -> Void)?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pollTimer: Timer?
    private var followUps: [Task<Void, Never>] = []
    private var running = false
    /// The slow check stopped because nobody is using the Mac.
    private var parked = false
    /// AXFullScreen answers per window, until its bounds change.
    private var axCache: [Int: (bounds: CGRect, fullScreen: Bool?)] = [:]
    /// Windows whose AXFullScreen is being read in the background.
    private var axPending: Set<Int> = []
    /// Bumped per check: a slower, older window-list read is dropped.
    private var generation = 0
    /// The displays the island uses (its own and All Displays' mirrors);
    /// nil: every display. Only these keep the slow check alive.
    var watchedDisplays: () -> Set<CGDirectDisplayID>? = { nil }

    static let pollInterval: TimeInterval = 2
    static let pollTolerance: TimeInterval = 1
    /// No input for this long: the slow check parks until the pointer moves.
    static let idleParkAfter: TimeInterval = 6

    func start() {
        guard !running else { return }
        running = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
        ] {
            observe(workspace, name)
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        evaluate(followUp: false)
    }

    /// The pointer moved (NotchWindowController's monitors): a parked
    /// check resumes at once.
    func noteActivity() {
        guard parked, running else { return }
        parked = false
        check()
    }

    func stop() {
        running = false
        parked = false
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        followUps.forEach { $0.cancel() }
        followUps.removeAll()
        axCache.removeAll()
        axPending.removeAll()
    }

    /// Screens asleep or another user active: no checks at all.
    func pause() {
        pollTimer?.invalidate()
        pollTimer = nil
        followUps.forEach { $0.cancel() }
        followUps.removeAll()
    }

    func resume() {
        guard running else { return }
        evaluate(followUp: true)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(followUp: true) }
        }
        observers.append((center, token))
    }

    /// Checks now and, after an event, twice more while the full-screen
    /// animation settles.
    func evaluate(followUp: Bool) {
        guard running else { return }
        check()
        guard followUp else { return }
        followUps.forEach { $0.cancel() }
        followUps = [0.8, 1.6].map { delay in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.check()
            }
        }
    }

    /// Reads the window list off the main thread, then decides here.
    private func check() {
        generation += 1
        let ticket = generation
        Task { [weak self] in
            let windows = await Task.detached(priority: .utility) { Self.sampleWindows() }.value
            guard let self, self.running, ticket == self.generation else { return }
            self.decide(windows)
        }
    }

    private func decide(_ windows: [IslandWindowSample]) {
        let displays = IslandDisplays.bounds()
        let own = ProcessInfo.processInfo.processIdentifier
        let axAllowed = PermissionCenter.shared.isGranted(.accessibility)
        let dockHides = cachedDockAutoHides()
        let wallpapers = IslandFullScreenDetector.wallpaperDisplays(windows: windows, displays: displays)
        let found = IslandFullScreenDetector.fullScreenDisplays(windows: windows, displays: displays, ownPID: own) { [weak self] candidate in
            let ax = axAllowed ? self?.axFullScreen(candidate.window) : nil
            return IslandFullScreenDetector.confirmBelowNotch(ax: ax, dockHides: dockHides,
                                                              wallpaperDisplays: wallpapers, displayID: candidate.displayID)
        }
        if found != fullScreenDisplays {
            fullScreenDisplays = found
            AppLog.log("Island: full screen on \(found.isEmpty ? "no display" : found.map(String.init).sorted().joined(separator: ", "))")
            onChange?(found)
        }
        // Keep a slow check only while full screen is on or likely on a
        // display the island uses.
        let front = NSWorkspace.shared.frontmostApplication
        let watched = watchedDisplays()
        let islandDisplays = watched.map { set in displays.filter { set.contains($0.id) } } ?? displays
        let likely = !found.isEmpty
            || IslandFullScreenDetector.isPresenter(bundleID: front?.bundleIdentifier)
            || IslandFullScreenDetector.hasLargeWindow(pid: front?.processIdentifier, windows: windows, displays: islandDisplays)
        // Going full screen or leaving it takes a click or a key: idle, park.
        // kCGAnyInputEventType.
        let idle = CGEventType(rawValue: ~0).map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) } ?? 0
        parked = likely && idle > Self.idleParkAfter
        setPolling(likely && !parked)
        // Forget windows that are gone.
        let live = Set(windows.map(\.number))
        axCache = axCache.filter { live.contains($0.key) }
    }

    private func setPolling(_ on: Bool) {
        if on, pollTimer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = Self.pollTolerance
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !on, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    // MARK: Reading the system

    /// Desktop elements included: the desktop-picture windows tell a
    /// full-screen Space apart (candidates skip them by layer and owner).
    nonisolated static func sampleWindows() -> [IslandWindowSample] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return IslandWindowSample(
                number: info[kCGWindowNumber as String] as? Int ?? 0,
                pid: info[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                bounds: bounds
            )
        }
    }

    /// One Dock defaults suite, read at most every 30 s (not a new suite
    /// per check on the main thread).
    private static let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
    private var dockHidesCache: (value: Bool, at: Date)?

    private func cachedDockAutoHides() -> Bool {
        if let cache = dockHidesCache, Date().timeIntervalSince(cache.at) < 30 { return cache.value }
        let value = Self.dockDefaults?.bool(forKey: "autohide") ?? false
        dockHidesCache = (value, Date())
        return value
    }

    /// The Dock's own "Automatically hide and show the Dock" (read only).
    static func dockAutoHides() -> Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// AXFullScreen of the app's window with these bounds; nil until it
    /// has been read. Only asked for below-the-notch candidates, read in the
    /// background (a hung app can't stall the island), cached until the
    /// window's bounds change; the answer triggers a fresh check.
    private func axFullScreen(_ window: IslandWindowSample) -> Bool? {
        if let cached = axCache[window.number], cached.bounds == window.bounds { return cached.fullScreen }
        guard !axPending.contains(window.number) else { return nil }
        axPending.insert(window.number)
        let number = window.number, pid = window.pid, bounds = window.bounds
        Task { [weak self] in
            let answer = await Task.detached(priority: .utility) { Self.readAXFullScreen(pid: pid, bounds: bounds) }.value
            guard let self else { return }
            self.axPending.remove(number)
            guard self.running else { return }
            self.axCache[number] = (bounds, answer)
            self.check()
        }
        return nil
    }

    /// Every element read gets the short timeout: it applies only to the
    /// element it is set on, not to the windows an app returns.
    nonisolated private static func readAXFullScreen(pid: pid_t, bounds: CGRect) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.2)
            guard let frame = frame(of: window),
                  abs(frame.minX - bounds.minX) < 2, abs(frame.minY - bounds.minY) < 2,
                  abs(frame.width - bounds.width) < 2, abs(frame.height - bounds.height) < 2 else { continue }
            var flag: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &flag) == .success else { return nil }
            return (flag as? Bool) ?? (flag as? NSNumber)?.boolValue
        }
        return nil
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
