import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// Menu Bar Overflow: the menu bar extras the notch hides, listed in a
/// drawer page, each one pressable from there. Uses Accessibility (each
/// app's AXExtrasMenuBar, SystemUIServer and Control Center included) to
/// find items and AXPress to open them; nothing is moved or rearranged.
///
/// Refreshes only when the page opens and, while it is open, when an app
/// launches or quits; never on a timer. Real icons are opt-in (Screen
/// Recording); otherwise each item shows its app's icon or a system symbol.
/// An optional divider (the Hidden Bar technique) hides the icons you
/// ⌘-drag to its left.
@MainActor
final class MenuBarOverflowController: ObservableObject {
    static let shared = MenuBarOverflowController()

    @Published private(set) var items: [MenuBarExtraItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var needsAccessibility = false
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published var showsAll: Bool { didSet { defaults.set(showsAll, forKey: Self.key("showAll")) } }
    @Published var showsRealIcons: Bool { didSet { defaults.set(showsRealIcons, forKey: Self.key("realIcons")); if showsRealIcons { captureIcons() } else { icons = [:] } } }
    @Published var dividerEnabled: Bool { didSet { defaults.set(dividerEnabled, forKey: Self.key("divider")); applyDivider() } }
    @Published private(set) var isDividerCollapsed = false
    @Published var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: Self.key("hotkey")); installHotkey() } }
    @Published private(set) var hotkeyUnavailable = false

    /// Set by the integrator: collapse the drawer before a menu opens, so
    /// it isn't covered.
    var onWillPress: (() -> Void)?
    /// Set by the integrator: select the Menu Bar tab and open the drawer.
    var onOpenDrawer: (() -> Void)?
    /// When ⌃⌥B last opened the page (the integrator opens the drawer
    /// without animation then, and the tiles skip their entrance).
    private var keyboardOpenAt: Date?

    /// The page is opening from the keyboard right now.
    var isOpeningFromKeyboard: Bool {
        keyboardOpenAt.map { Date().timeIntervalSince($0) < 1 } ?? false
    }

    /// Read once by the page as it appears.
    func takeKeyboardOpen() -> Bool {
        defer { keyboardOpenAt = nil }
        return isOpeningFromKeyboard
    }

    static let shortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(controlKey | optionKey))

    private let defaults: UserDefaults
    private var viewers = 0
    private var observers: [NSObjectProtocol] = []
    private var hotkey: ScreenRegionHotkey?
    private var separatorItem: NSStatusItem?
    private var chevronItem: NSStatusItem?
    private var isStarted = false

    private static func key(_ name: String) -> String { "SparkV.menuBar." + name }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsAll = defaults.bool(forKey: Self.key("showAll"))
        showsRealIcons = defaults.bool(forKey: Self.key("realIcons"))
        dividerEnabled = defaults.bool(forKey: Self.key("divider"))
        hotkeyEnabled = defaults.bool(forKey: Self.key("hotkey")) // opt-in: a Carbon hotkey holds ⌃⌥B in every app
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installHotkey()
        applyDivider()
    }

    func stop() {
        isStarted = false
        hotkey?.unregister()
        hotkey = nil
        removeDivider()
        endObserving()
        viewers = 0
    }

    // MARK: Viewing (drawer page)

    func beginViewing() {
        viewers += 1
        if viewers == 1 {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh(after: 0.6) }
                })
            }
        }
        refresh()
    }

    func endViewing() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { endObserving() }
    }

    private func endObserving() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Scanning

    private var refreshTask: Task<Void, Never>?

    func refresh(after delay: TimeInterval = 0) {
        guard PermissionCenter.shared.isGranted(.accessibility) else {
            needsAccessibility = true
            return
        }
        needsAccessibility = false
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await self.scan()
        }
    }

    func requestAccessibility() {
        Task {
            _ = await PermissionCenter.shared.request(.accessibility, from: "Menu Bar Overflow")
            refresh()
        }
    }

    private func scan() async {
        isScanning = true
        let own = ProcessInfo.processInfo.processIdentifier
        let apps: [MenuBarScan.App] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != own, app.activationPolicy != .prohibited || MenuBarNaming.systemBundleIDs.contains(app.bundleIdentifier ?? "") else { return nil }
            return MenuBarScan.App(pid: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "App", bundleID: app.bundleIdentifier)
        }
        let displays = Self.displays()
        let found = await Task.detached(priority: .userInitiated) {
            MenuBarScan.scan(apps: apps, displays: displays)
        }.value
        items = MenuBarNaming.sorted(found, hiddenFirst: true)
        lastScan = Date()
        isScanning = false
        if showsRealIcons { captureIcons() }
    }

    /// Every display's menu bar strip and notch span, in AX coordinates.
    static func displays() -> [MenuBarGeometry.Display] {
        guard let primary = NSScreen.screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return NSScreen.screens.map { screen in
            let barHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            let bar = CGRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight, width: screen.frame.width, height: barHeight)
            var notch: ClosedRange<CGFloat>?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
                // The left area starts at the display's left edge: in global
                // coordinates that is frame.minX, in screen-local ones 0.
                let isGlobal = abs(left.minX - screen.frame.minX) < 1
                let shift = isGlobal ? 0 : screen.frame.minX
                notch = (left.maxX + shift)...(right.minX + shift)
            }
            return MenuBarGeometry.Display(menuBar: MenuBarGeometry.axRect(fromAppKit: bar, primaryHeight: primaryHeight), notch: notch)
        }
    }

    var hiddenItems: [MenuBarExtraItem] { items.filter(\.isHidden) }
    var shownItems: [MenuBarExtraItem] { showsAll ? items : hiddenItems }

    // MARK: Pressing

    /// Opens the item's menu: the drawer gets out of the way first.
    func press(_ item: MenuBarExtraItem) {
        guard PermissionCenter.shared.isGranted(.accessibility) else {
            needsAccessibility = true
            return
        }
        onWillPress?()
        Task {
            // Let the drawer close so the menu isn't drawn under it.
            try? await Task.sleep(for: .milliseconds(220))
            let pressed = await Task.detached(priority: .userInitiated) { MenuBarScan.press(item) }.value
            if !pressed {
                AppLog.log("Menu Bar Overflow: couldn't open an item of \(item.appName)")
                // The app may have moved it: refresh and let the user retry.
                refresh()
            }
        }
    }

    func openApp(_ item: MenuBarExtraItem) {
        NSRunningApplication(processIdentifier: item.pid)?.activate()
    }

    func appIcon(_ item: MenuBarExtraItem) -> NSImage? {
        NSRunningApplication(processIdentifier: item.pid)?.icon
    }

    // MARK: Real icons (opt-in, Screen Recording)

    private func captureIcons() {
        guard showsRealIcons, PermissionCenter.shared.isGranted(.screenRecording) else { return }
        guard #available(macOS 15.2, *) else { return }
        let targets = items.filter { $0.frame.width >= 4 && $0.frame.width < 200 }
        Task {
            var captured: [String: NSImage] = [:]
            for item in targets {
                guard let image = try? await SCScreenshotManager.captureImage(in: item.frame) else { continue }
                captured[item.id] = NSImage(cgImage: image, size: item.frame.size)
            }
            PermissionCenter.shared.noteScreenCaptureUse(from: "Menu Bar Overflow icons")
            icons = captured
        }
    }

    func requestScreenRecording() {
        Task {
            _ = await PermissionCenter.shared.request(.screenRecording, from: "Menu Bar Overflow icons")
            captureIcons()
        }
    }

    // MARK: Divider (Hidden Bar technique, opt-in)

    private static let collapsedLength: CGFloat = 10_000
    private static let separatorLength: CGFloat = 10

    private func applyDivider() {
        guard isStarted else { return }
        dividerEnabled ? installDivider() : removeDivider()
    }

    private func installDivider() {
        guard chevronItem == nil else { return }
        // The chevron first: newer items appear to its left, so the
        // separator sits just left of it.
        let chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron.autosaveName = "SparkV.MenuBarDivider.Toggle"
        chevron.button?.image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "Hide menu bar icons")
        chevron.button?.target = self
        chevron.button?.action = #selector(chevronClicked)
        chevron.button?.setAccessibilityLabel("SparkV: hide or show menu bar icons")
        let separator = NSStatusBar.system.statusItem(withLength: Self.separatorLength)
        separator.autosaveName = "SparkV.MenuBarDivider.Separator"
        separator.button?.image = NSImage(systemSymbolName: "poweron", accessibilityDescription: "Divider")
        separator.button?.imageScaling = .scaleProportionallyDown
        separator.button?.appearsDisabled = true
        separator.button?.setAccessibilityLabel("SparkV divider: icons to the left of it hide")
        chevronItem = chevron
        separatorItem = separator
        setCollapsed(false)
    }

    private func removeDivider() {
        if let chevronItem { NSStatusBar.system.removeStatusItem(chevronItem) }
        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        chevronItem = nil
        separatorItem = nil
        isDividerCollapsed = false
    }

    @objc private func chevronClicked() {
        setCollapsed(!isDividerCollapsed)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard let separatorItem, let chevronItem else { return }
        isDividerCollapsed = collapsed
        separatorItem.length = collapsed ? Self.collapsedLength : Self.separatorLength
        chevronItem.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.compact.right" : "chevron.compact.left",
                                            accessibilityDescription: collapsed ? "Show menu bar icons" : "Hide menu bar icons")
    }

    // MARK: Hotkey (⌃⌥B)

    private func installHotkey() {
        hotkey?.unregister()
        hotkey = nil
        hotkeyUnavailable = false
        guard isStarted, hotkeyEnabled else { return }
        let hotkey = ScreenRegionHotkey()
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            // Keyboard-triggered: the page appears at once (no fade-in).
            self.keyboardOpenAt = Date()
            self.onOpenDrawer?()
        }
        if hotkey.register(Self.shortcut) {
            self.hotkey = hotkey
        } else {
            hotkeyUnavailable = true
            AppLog.log("Menu Bar Overflow: \(Self.shortcut.displayString) is taken by another app")
        }
    }
}

/// Accessibility reads and presses, off the main thread (AX calls can wait
/// on a busy app; each one has a 0.25 s messaging timeout).
enum MenuBarScan {
    struct App: Sendable {
        let pid: Int32
        let name: String
        let bundleID: String?
    }

    static func scan(apps: [App], displays: [MenuBarGeometry.Display]) -> [MenuBarExtraItem] {
        var items: [MenuBarExtraItem] = []
        for app in apps {
            for (index, raw) in extras(of: app.pid).enumerated() {
                let label = MenuBarNaming.label(raw, appName: app.name)
                items.append(MenuBarExtraItem(
                    pid: app.pid, index: index, appName: app.name, bundleID: app.bundleID, label: label,
                    frame: raw.frame, isHidden: MenuBarGeometry.isHidden(raw.frame, displays: displays)
                ))
            }
        }
        return items
    }

    static func press(_ item: MenuBarExtraItem) -> Bool {
        let elements = extraElements(of: item.pid)
        guard !elements.isEmpty else { return false }
        let raws = elements.map(read)
        // Same position and label first; else the nearest frame.
        let index: Int? = raws.indices.contains(item.index) && MenuBarNaming.label(raws[item.index], appName: item.appName) == item.label
            ? item.index
            : MenuBarGeometry.bestMatch(for: item.frame, among: raws.map(\.frame))
        guard let index else { return false }
        let element = elements[index]
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
        return AXUIElementPerformAction(element, "AXShowMenu" as CFString) == .success
    }

    private static func extras(of pid: Int32) -> [MenuBarExtraRaw] {
        extraElements(of: pid).map(read)
    }

    private static func extraElements(of pid: Int32) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar = element(app, "AXExtrasMenuBar") else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func read(_ element: AXUIElement) -> MenuBarExtraRaw {
        var origin = CGPoint.zero
        var size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let value,
           CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        value = nil
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value,
           CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return MenuBarExtraRaw(
            title: string(element, kAXTitleAttribute),
            description: string(element, kAXDescriptionAttribute),
            help: string(element, kAXHelpAttribute),
            identifier: string(element, kAXIdentifierAttribute),
            frame: CGRect(origin: origin, size: size)
        )
    }
}
