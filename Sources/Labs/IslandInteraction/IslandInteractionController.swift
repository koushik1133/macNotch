import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Something else is at the notch or the menu bar that SparkV should know
/// about: another notch app, a menu bar manager, or an app using fn.
struct IslandCoexistenceFinding: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Another notch / HUD app draws where the island is.
        case notchApp
        /// Ice, Bartender…: its bar can sit over the island.
        case menuBarManager
        /// Wispr Flow and SparkV's dictation both listen to fn.
        case fnDictation
    }

    /// Bundle ID, or "window:<owner name>" for an unknown app found by its window.
    var id: String
    var name: String
    var kind: Kind

    var message: String {
        switch kind {
        case .notchApp: "\(name) also draws at the notch"
        case .menuBarManager: "\(name) manages the menu bar"
        case .fnDictation: "\(name) also uses fn for dictation"
        }
    }
}

/// The parts of SparkV that can step aside for another notch app. The
/// window controller fills these in (it owns the HUD, media and
/// notification controllers).
@MainActor
struct IslandCoexistenceActions {
    var systemHUDReplaced: () -> Bool = { false }
    var setSystemHUDReplaced: (Bool) -> Void = { _ in }
    var nowPlayingWings: () -> Bool = { false }
    var setNowPlayingWings: (Bool) -> Void = { _ in }
    var notificationBanners: () -> Bool = { false }
    var setNotificationBanners: (Bool) -> Void = { _ in }
    var dictationUsesFn: () -> Bool = { false }
    var useRightOptionForDictation: () -> Void = {}
    var hideIsland: () -> Void = {}
}

/// Island Interaction's runtime: the open/close hotkey, Esc while the
/// pointer is on the drawer, menu bar item clearance for the wings, menu
/// bar managers, other notch apps and focus return. Everything is driven
/// by notifications and by the pointer reaching the island; nothing polls
/// while idle.
@MainActor
final class IslandInteractionController: ObservableObject {
    /// The running one (settings views and the hub tile use it).
    private(set) static weak var current: IslandInteractionController?

    let settings = IslandInteractionSettings.shared

    // MARK: Published state

    /// Other apps at the notch or the menu bar right now (settable for
    /// the render harness; the controller replaces it on every check).
    @Published var findings: [IslandCoexistenceFinding] = []
    /// A menu bar manager's bar is over the island: it fades out until the
    /// bar is gone.
    @Published private(set) var isSteppingAside = false
    /// The wings' room beside the housing (menu bar items).
    @Published private(set) var wingClearance = IslandWingClearance.unlimited
    /// The ⌃⌥O shortcut is registered (false: off, or another app owns it).
    @Published private(set) var toggleHotkeyRegistered = false
    /// Turning ⌃⌥O on failed: another app owns it.
    @Published private(set) var toggleHotkeyTaken = false
    /// Bumped when one of the step-aside switches changes, so views re-read.
    @Published private(set) var featureRevision = 0

    // MARK: Hooks the window controller sets

    var onToggleHotkey: (() -> Void)?
    var onEscape: (() -> Void)?
    var onStepAsideChanged: ((Bool) -> Void)?
    var onWingClearanceChanged: ((IslandWingClearance) -> Void)?
    /// Posts the "also at the notch" band (`ActivityCenter.post`).
    var postNotice: ((LiveActivity) -> Void)?
    /// Closes the drawer (the notch gap, the pinned bar, a swipe).
    var onCloseRequest: (() -> Void)?
    /// Pin from the gear menu or the hub tile.
    var onPinRequest: ((Bool) -> Void)?
    var isPinned: () -> Bool = { false }
    var actions = IslandCoexistenceActions()

    // MARK: Private

    private let toggleHotkey = ScreenRegionHotkey()
    private let escapeHotkey = ScreenRegionHotkey()
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var settingsObserver: AnyCancellable?
    private var managerPIDs: Set<Int32> = []
    private var coexistenceTask: Task<Void, Never>?
    private var stepAsideTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var lastSample: Date = .distantPast
    private var escapeRegistrationFailed = false
    private var started = false
    /// Where the island is, for the menu bar sample and the occupancy check.
    private var housing: CGRect = .zero
    private var menuBar: CGRect = .zero
    private var notchRect: CGRect = .zero
    /// The app that was in front when the drawer opened.
    private var previousApp: NSRunningApplication?

    /// ⌃⌥O unless remapped in Settings › Accessibility › Keyboard Shortcuts.
    static var toggleShortcut: ScreenRegionShortcut { DrawerShortcutStore.shared.toggleShortcut }
    static var toggleShortcutLabel: String { toggleShortcut.displayString }

    init() {}

    /// Harness seam: the settings views read `current`; nothing starts.
    func becomeCurrentForPreview() { Self.current = self }

    func start() {
        guard !started else { return }
        started = true
        Self.current = self
        toggleHotkey.onPress = { [weak self] in self?.onToggleHotkey?() }
        escapeHotkey.onPress = { [weak self] in self?.onEscape?() }
        applyToggleHotkey()
        settingsObserver = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.didLaunchApplicationNotification, on: workspace) { $0.appsChanged() }
        observe(NSWorkspace.didTerminateApplicationNotification, on: workspace) { $0.appsChanged() }
        // Status items move when the front app's menus change, or another
        // display is plugged in.
        observe(NSWorkspace.didActivateApplicationNotification, on: workspace) { $0.sampleMenuBar(force: false) }
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { $0.sampleMenuBar(force: true) }
        // Remapped, or a shortcut recorder wants the keys for a moment.
        observe(DrawerShortcutStore.didChangeNotification, on: .default) { $0.applyToggleHotkey() }
        refreshManagers()
        // The first look a few seconds after launch, once other login items are up.
        scheduleCoexistenceCheck(after: .seconds(4))
    }

    func stop() {
        guard started else { return }
        started = false
        toggleHotkey.unregister()
        escapeHotkey.unregister()
        toggleHotkeyRegistered = false
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        settingsObserver = nil
        [coexistenceTask, stepAsideTask, sampleTask].forEach { $0?.cancel() }
        coexistenceTask = nil
        stepAsideTask = nil
        sampleTask = nil
        if isSteppingAside { setSteppingAside(false) }
        IslandInteractionStore.setWingClearance(.unlimited)
        IslandWingRoom.shared.refresh()
        if Self.current === self { Self.current = nil }
    }

    // MARK: Settings

    private var lastSnapshot = IslandInteractionStore.current

    private func settingsChanged() {
        // objectWillChange fires before the value is stored.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = self.settings.snapshot
            let before = self.lastSnapshot
            self.lastSnapshot = now
            if now.toggleHotkeyEnabled != before.toggleHotkeyEnabled { self.applyToggleHotkey() }
            IslandWingRoom.shared.refresh()
            if now.avoidMenuBarItems != before.avoidMenuBarItems {
                self.onWingClearanceChanged?(IslandInteractionStore.wingClearance)
                if now.avoidMenuBarItems { self.sampleMenuBar(force: true) }
            }
            if now.stepAsideForMenuBarManagers != before.stepAsideForMenuBarManagers, !now.stepAsideForMenuBarManagers {
                self.stepAsideTask?.cancel()
                self.stepAsideTask = nil
                if self.isSteppingAside { self.setSteppingAside(false) }
            }
            if now.warnAboutOtherNotchApps != before.warnAboutOtherNotchApps { self.scheduleCoexistenceCheck(after: .zero) }
        }
    }

    private func applyToggleHotkey() {
        if settings.toggleHotkeyEnabled, !DrawerShortcutStore.shared.isRecording {
            if toggleHotkey.isRegistered, toggleHotkey.shortcut == Self.toggleShortcut { return }
            toggleHotkeyRegistered = toggleHotkey.register(Self.toggleShortcut)
            toggleHotkeyTaken = !toggleHotkeyRegistered
            if !toggleHotkeyRegistered { AppLog.log("Island: \(Self.toggleShortcutLabel) is taken by another app") }
        } else {
            toggleHotkey.unregister()
            toggleHotkeyRegistered = false
            toggleHotkeyTaken = false
        }
    }

    // MARK: Island geometry

    /// The window controller calls this on every layout.
    func noteIsland(housing: CGRect, notchRect: CGRect, screenFrame: CGRect, menuBarHeight: CGFloat) {
        let bar = CGRect(x: screenFrame.minX, y: screenFrame.maxY - max(menuBarHeight, notchRect.height, 24),
                         width: screenFrame.width, height: max(menuBarHeight, notchRect.height, 24))
        let moved = housing != self.housing || bar != menuBar
        self.housing = housing
        self.notchRect = notchRect
        menuBar = bar
        if moved { sampleMenuBar(force: true) }
    }

    // MARK: Esc

    /// Esc closes the drawer while the pointer is on it: a temporary
    /// shortcut, held only then (never while you type elsewhere with the
    /// pointer away from the drawer), and not while a screen selection
    /// owns Esc. The window controller passes `armed` false while
    /// dictation or Clicky own Esc (it re-checks when their phase changes)
    /// and while the drawer's panel is key: then the responder chain has
    /// Esc, so a field's own Esc (Flow, the media note, the Script editor's
    /// Cancel) runs first and `NotchPanel.cancelOperation` closes the
    /// drawer otherwise. A failed registration is not retried until the
    /// drawer opens again (`resetEscapeFailure`).
    func setEscapeArmed(_ armed: Bool) {
        let want = armed && settings.escapeCloses && !ScreenRegionOverlayController.isAnyActive
        if want, !escapeHotkey.isRegistered, !escapeRegistrationFailed {
            if !escapeHotkey.register(ScreenRegionShortcut(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)) {
                escapeRegistrationFailed = true
                AppLog.log("Island: Esc could not be held; not retried until the drawer opens again")
            }
        } else if !want, escapeHotkey.isRegistered {
            escapeHotkey.unregister()
        }
    }

    /// The drawer opened: one more try at holding Esc.
    func resetEscapeFailure() { escapeRegistrationFailed = false }

    // MARK: Focus

    /// Called when the drawer opens.
    func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    /// Called when the drawer closes: if a field in the drawer made SparkV
    /// the active app, the app you were in gets the keyboard back. A
    /// SparkV window you opened from the drawer (Settings, notes) keeps it.
    /// `force` (the drawer was opened by a shortcut and took the keyboard):
    /// hand it back even with Return Focus off.
    func restoreFrontApp(islandPanel: NSWindow?, force: Bool = false) {
        defer { previousApp = nil }
        guard (settings.returnsFocus || force), NSApp.isActive, let app = previousApp, !app.isTerminated else { return }
        if let key = NSApp.keyWindow, key !== islandPanel { return }
        let others = NSApp.windows.filter { $0.isVisible && $0 !== islandPanel && $0.canBecomeKey && !($0 is NSPanel) && $0.level == .normal }
        guard others.isEmpty else { return }
        app.activate()
    }

    // MARK: Menu bar items (wings)

    /// Wings came into view: status items may have moved since the last
    /// look (a manager revealed hidden ones). At most once a second.
    func wingsBecameVisible() {
        sampleMenuBar(force: false)
    }

    private func sampleMenuBar(force: Bool) {
        guard settings.avoidMenuBarItems, housing.width > 0 else { return }
        if !force, Date().timeIntervalSince(lastSample) < 1 { return }
        lastSample = Date()
        sampleTask?.cancel()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let housing = housing, bar = menuBar
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let readsMenus = PermissionCenter.shared.isGranted(.accessibility)
        sampleTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> IslandWingClearance in
                let windows = IslandWindowList.read(primaryHeight: primaryHeight)
                let items = windows
                    .filter { $0.pid != ownPID && $0.layer == IslandCoexistenceRules.statusLevel && $0.bounds.height <= bar.height + 2 }
                    .map(\.bounds)
                let menus = readsMenus && frontPID != nil ? IslandAppMenus.maxX(pid: frontPID!, primaryHeight: primaryHeight, menuBar: bar) : nil
                return IslandWingClearance.compute(housing: housing, menuBar: bar, items: items, appMenusMaxX: menus)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.applyClearance(result)
        }
    }

    private func applyClearance(_ clearance: IslandWingClearance) {
        IslandInteractionStore.setWingClearance(clearance)
        IslandWingRoom.shared.refresh()
        guard clearance != wingClearance else { return }
        wingClearance = clearance
        onWingClearanceChanged?(IslandInteractionStore.wingClearance)
    }

    // MARK: Menu bar managers

    var runningManagerNames: [String] {
        NSWorkspace.shared.runningApplications
            .filter { managerPIDs.contains($0.processIdentifier) }
            .compactMap { $0.localizedName }
    }

    private func refreshManagers() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { IslandKnownApps.isMenuBarManager(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
            .map(\.processIdentifier)
        managerPIDs = Set(pids)
        if managerPIDs.isEmpty, isSteppingAside {
            stepAsideTask?.cancel()
            stepAsideTask = nil
            setSteppingAside(false)
        }
    }

    /// The pointer reached the closed island while a menu bar manager
    /// runs: one look at the window list. If the manager's bar hangs over
    /// or under the island (not its stretched divider in the menu bar row,
    /// see `IslandCoexistenceRules.managerBarCovers`), the island fades out
    /// and is checked twice a second while the pointer stays, for at most
    /// 10 s. The pointer leaving, the bar going or the cap brings it back.
    /// Nothing runs without a manager, and nothing runs while idle.
    func pointerReachedIsland(zone: CGRect) {
        guard settings.stepAsideForMenuBarManagers, !managerPIDs.isEmpty, stepAsideTask == nil,
              menuBar.width > 0 else { return }
        let pids = managerPIDs
        let bar = menuBar
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        stepAsideTask = Task { [weak self] in
            var covering = await Self.managerBarCovers(zone: zone, menuBar: bar, pids: pids, primaryHeight: primaryHeight)
            guard !Task.isCancelled, let self else { return }
            guard covering else {
                self.stepAsideTask = nil
                return
            }
            self.setSteppingAside(true)
            AppLog.log("Island: stepping aside for the menu bar manager's bar")
            var checks = 0
            while covering, !Task.isCancelled, checks < IslandCoexistenceRules.stepAsideRecheckLimit {
                try? await Task.sleep(for: .milliseconds(IslandCoexistenceRules.stepAsideRecheckMilliseconds))
                guard !Task.isCancelled else { return }
                checks += 1
                covering = await Self.managerBarCovers(zone: zone, menuBar: bar, pids: pids, primaryHeight: primaryHeight)
            }
            guard !Task.isCancelled else { return }
            self.stepAsideTask = nil
            self.setSteppingAside(false)
        }
    }

    /// The pointer left the closed island: any step-aside check ends and
    /// the island shows again.
    func pointerLeftIsland() {
        guard stepAsideTask != nil || isSteppingAside else { return }
        stepAsideTask?.cancel()
        stepAsideTask = nil
        setSteppingAside(false)
    }

    private static func managerBarCovers(zone: CGRect, menuBar: CGRect, pids: Set<Int32>, primaryHeight: CGFloat) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            IslandCoexistenceRules.managerBarCovers(IslandWindowList.read(primaryHeight: primaryHeight), managerPIDs: pids,
                                                    zone: zone, menuBar: menuBar)
        }.value
    }

    private func setSteppingAside(_ value: Bool) {
        guard isSteppingAside != value else { return }
        isSteppingAside = value
        onStepAsideChanged?(value)
    }

    // MARK: Other notch apps

    private func appsChanged() {
        refreshManagers()
        // Launches come in bursts at login: one look 2 s after the last.
        scheduleCoexistenceCheck(after: .seconds(2))
    }

    private func scheduleCoexistenceCheck(after delay: Duration) {
        coexistenceTask?.cancel()
        coexistenceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.coexistenceTask = nil
            await self.checkCoexistence()
        }
    }

    /// Bundle IDs of the running apps, plus one window-list read for an
    /// unknown app parked over the notch.
    func checkCoexistence() async {
        var found: [IslandCoexistenceFinding] = []
        var seen: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            if let name = IslandKnownApps.notchAppName(bundleID: app.bundleIdentifier, name: app.localizedName), seen.insert(id).inserted {
                found.append(IslandCoexistenceFinding(id: id, name: name, kind: .notchApp))
            } else if IslandKnownApps.isMenuBarManager(bundleID: app.bundleIdentifier, name: app.localizedName), seen.insert(id).inserted {
                found.append(IslandCoexistenceFinding(id: id, name: app.localizedName ?? "A menu bar manager", kind: .menuBarManager))
            } else if let bundle = app.bundleIdentifier, let name = IslandKnownApps.fnDictationApps[bundle],
                      actions.dictationUsesFn(), seen.insert(id).inserted {
                found.append(IslandCoexistenceFinding(id: id, name: name, kind: .fnDictation))
            }
        }
        if notchRect.width > 0 {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let rect = notchRect
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let screenWidth = menuBar.width > 0 ? menuBar.width : CGFloat.greatestFiniteMagnitude
            let windows = await Task.detached(priority: .utility) { IslandWindowList.read(primaryHeight: primaryHeight) }.value
            // Geometry first; bundle IDs only for the few windows left.
            var candidates = IslandCoexistenceRules.notchOccupants(windows, notchRect: rect, ownPID: ownPID, screenWidth: screenWidth)
            for index in candidates.indices {
                candidates[index].bundleID = NSRunningApplication(processIdentifier: candidates[index].pid)?.bundleIdentifier
            }
            for window in IslandCoexistenceRules.notchOccupants(candidates, notchRect: rect, ownPID: ownPID, screenWidth: screenWidth) {
                let id = window.bundleID ?? "window:\(window.ownerName)"
                // A known manager's own bar is handled by stepping aside.
                guard !managerPIDs.contains(window.pid), seen.insert(id).inserted else { continue }
                found.append(IslandCoexistenceFinding(id: id, name: window.ownerName.isEmpty ? "Another app" : window.ownerName, kind: .notchApp))
            }
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let newOnes = found.filter { f in !findings.contains(f) }
        findings = found
        if !found.isEmpty { AppLog.log("Island: also running \(found.map(\.name).joined(separator: ", "))") }
        guard settings.warnAboutOtherNotchApps else { return }
        // One notice per app, never again once dismissed. Managers are
        // handled quietly (the island steps aside), so they get none.
        for finding in newOnes where finding.kind != .menuBarManager && !settings.dismissedConflicts.contains(finding.id) {
            postNotice?(IslandCoexistenceBand.activity(for: finding))
        }
    }

    func dismiss(_ finding: IslandCoexistenceFinding) {
        settings.dismissConflict(finding.id)
        featureRevision += 1
    }

    // MARK: Step-aside switches

    func setSystemHUDReplaced(_ on: Bool) { actions.setSystemHUDReplaced(on); featureRevision += 1 }
    func setNowPlayingWings(_ on: Bool) { actions.setNowPlayingWings(on); featureRevision += 1 }
    func setNotificationBanners(_ on: Bool) { actions.setNotificationBanners(on); featureRevision += 1 }
    func useRightOptionForDictation() { actions.useRightOptionForDictation(); featureRevision += 1 }

    // MARK: Helpers

    private func observe(_ name: Notification.Name, on center: NotificationCenter,
                         _ handler: @escaping @MainActor (IslandInteractionController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }
}

/// Requests from the island's own views (the notch gap, the pinned bar,
/// the gear menu), routed to the running window controller.
@MainActor
enum IslandInteractionActions {
    static func close() { IslandInteractionController.current?.onCloseRequest?() }

    static var isPinned: Bool { IslandInteractionController.current?.isPinned() ?? false }

    static func setPinned(_ pinned: Bool) {
        IslandInteractionController.current?.onPinRequest?(pinned)
    }
}

// MARK: - Window list

/// One read of the on-screen window list. Bounds, owner and layer need no
/// permission (window names would need Screen Recording and aren't read).
enum IslandWindowList {
    static func read(primaryHeight: CGFloat) -> [IslandForeignWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var windows: [IslandForeignWindow] = []
        windows.reserveCapacity(list.count)
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { continue }
            windows.append(IslandForeignWindow(
                pid: pid, layer: layer,
                bounds: IslandScreenCoordinates.appKitRect(fromCG: cg, primaryScreenHeight: primaryHeight),
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                bundleID: nil
            ))
        }
        return windows
    }
}

/// The front app's menus (Accessibility, only when already allowed; never
/// prompts). Each element gets a 0.2 s timeout; runs off the main thread.
enum IslandAppMenus {
    static func maxX(pid: pid_t, primaryHeight: CGFloat, menuBar: CGRect) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let barValue = barRef, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return nil }
        let bar = barValue as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, 0.2)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        var edge: CGFloat?
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.2)
            guard let frame = frame(of: child) else { continue }
            let appKit = IslandScreenCoordinates.appKitRect(fromCG: frame, primaryScreenHeight: primaryHeight)
            guard appKit.intersects(menuBar) else { continue }
            edge = max(edge ?? appKit.maxX, appKit.maxX)
        }
        return edge
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

// MARK: - Event samples

/// The parts of a scroll event the swipe tracker needs, copied out of the
/// `NSEvent` before it crosses to the main actor.
struct IslandScrollSample: Sendable {
    let phase: IslandScrollPhase
    let deltaY: CGFloat
    let inverted: Bool
    /// A trackpad (precise deltas) gesture phase, not momentum or a wheel.
    let isPreciseGesture: Bool

    init(_ event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        deltaY = event.scrollingDeltaY
        inverted = event.isDirectionInvertedFromDevice
        if !event.momentumPhase.isEmpty || !precise {
            phase = .other
        } else if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.changed) {
            phase = .changed
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            phase = .ended
        } else {
            phase = .other
        }
        isPreciseGesture = phase != .other
    }
}

extension Duration {
    /// Whole milliseconds (for the hover-intent arithmetic).
    var islandMilliseconds: Int {
        let c = components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
