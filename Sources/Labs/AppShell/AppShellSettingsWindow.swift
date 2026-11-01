import AppKit
import SwiftUI

/// The eleven Settings panes, in toolbar order. Every package files its
/// `<X>SettingsSection` views under one of these in `AppShellSettingsPanes.swift`.
enum SparkVSettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, island, media, system, activities, planner, shelf, extras, appearance, accessibility, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .island: "Island"
        case .media: "Media"
        case .system: "System"
        case .activities: "Activities"
        case .planner: "Planner"
        case .shelf: "Shelf"
        case .extras: "Extras"
        case .appearance: "Appearance"
        case .accessibility: "Accessibility"
        case .advanced: "Advanced"
        }
    }

    /// Toolbar glyph (SF Symbols, all available on macOS 15).
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .island: "rectangle.topthird.inset.filled"
        case .media: "play.circle"
        case .system: "gauge.with.dots.needle.33percent"
        case .activities: "app.badge"
        case .planner: "calendar"
        case .shelf: "tray.full"
        case .extras: "puzzlepiece.extension"
        case .appearance: "paintpalette"
        case .accessibility: "accessibility"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// "media", "Media", "now-playing" style names from links and Shortcuts.
    init?(slug: String?) {
        guard let slug = AutomationText.slug(slug) else { return nil }
        if let pane = SparkVSettingsPane(rawValue: slug) { self = pane; return }
        let aliases: [String: SparkVSettingsPane] = [
            "updates": .general, "about": .general, "login": .general, "menu-bar": .general,
            "notch": .island, "music": .media, "now-playing": .media, "hud": .system, "battery": .system,
            "live-activities": .activities, "calendar": .planner, "timer": .planner, "focus": .planner,
            "tray": .shelf, "files": .shelf, "look": .appearance, "theme": .appearance,
            "diagnostics": .advanced, "automation": .advanced, "reset": .advanced, "uninstall": .advanced,
        ]
        guard let pane = aliases[slug] else { return nil }
        self = pane
    }
}

/// The Settings window: native preference-style toolbar panes (the window
/// title is the pane's name), opened in front on the current Space even
/// though SparkV has no Dock icon, never floating, back on the last pane
/// next time. Reachable from the gear menu, ⌘, while SparkV is active, the
/// menu bar icon, the Agents hub, `sparkv://settings` and by opening
/// SparkV again from Finder, Spotlight or Launchpad.
@MainActor
final class SparkVSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SparkVSettingsWindowController()

    static let lastPaneKey = "AppShell.settings.lastPane"
    static let frameName = "SparkV.Settings"
    /// Wide enough for the eleven toolbar items at their measured label
    /// widths (longer translations widen the window instead of pushing
    /// panes into the toolbar's » menu); panes scroll inside.
    static var contentSize: NSSize {
        NSSize(width: SettingsToolbarWidth.width(for: SparkVSettingsPane.allCases.map(\.title)), height: 600)
    }

    /// Optional: wraps every pane in the drawer's environment objects, for
    /// sections that read `@EnvironmentObject`. Set before the first `show`.
    var environment: ((AnyView) -> AnyView)?

    private var window: NSWindow?
    private var tabs: SparkVSettingsTabController?
    private var appearanceObserver: NSObjectProtocol?

    var isVisible: Bool { window?.isVisible ?? false }

    /// The pane the window opens on: the last one used, General at first.
    var lastPane: SparkVSettingsPane {
        get { UserDefaults.standard.string(forKey: Self.lastPaneKey).flatMap(SparkVSettingsPane.init(rawValue:)) ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.lastPaneKey) }
    }

    /// Opens Settings on `pane` (or the last pane) in front of every app.
    func show(pane: SparkVSettingsPane? = nil) {
        let window = prepareWindow()
        if let pane { select(pane) }
        // A Dock-less app's window can open behind the front app, and on
        // another Space: become a regular app while it is open, take
        // activation explicitly and order it front regardless.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { place(window) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppLog.log("Settings: opened on \(currentPane.title)")
    }

    /// The window, built on first use (not shown).
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let made = makeWindow()
        window = made
        return made
    }

    func select(_ pane: SparkVSettingsPane) {
        guard let tabs, let index = SparkVSettingsPane.allCases.firstIndex(of: pane) else { return }
        if tabs.selectedTabViewItemIndex != index { tabs.selectedTabViewItemIndex = index }
        lastPane = pane
    }

    var currentPane: SparkVSettingsPane {
        guard let tabs, tabs.selectedTabViewItemIndex >= 0,
              tabs.selectedTabViewItemIndex < SparkVSettingsPane.allCases.count else { return lastPane }
        return SparkVSettingsPane.allCases[tabs.selectedTabViewItemIndex]
    }

    func close() { window?.performClose(nil) }

    // MARK: Building

    private func makeWindow() -> NSWindow {
        let tabs = SparkVSettingsTabController()
        tabs.tabStyle = .toolbar
        // Crossfade between panes (AppKit's own short fade; Reduce Motion
        // keeps fades). No sliding.
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for pane in SparkVSettingsPane.allCases {
            let root = AnyView(SparkVSettingsPaneRoot(pane: pane).followsAppearance())
            let hosting = NSHostingController(rootView: environment?(root) ?? root)
            hosting.sizingOptions = []
            hosting.preferredContentSize = Self.contentSize
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.toolTip = "\(pane.title) settings"
            tabs.addTabViewItem(item)
        }
        tabs.onSelect = { [weak self] pane in self?.lastPane = pane }
        let initial = lastPane
        tabs.selectedTabViewItemIndex = SparkVSettingsPane.allCases.firstIndex(of: initial) ?? 0
        self.tabs = tabs

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.title = initial.title
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(SparkVTheme.windowBackground)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed
        window.setContentSize(Self.contentSize)
        window.delegate = self
        window.setAccessibilityTitle("SparkV Settings")
        if !window.setFrameUsingName(Self.frameName) { center(window) }
        window.setFrameAutosaveName(Self.frameName)
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated { window?.backgroundColor = NSColor(SparkVTheme.windowBackground) }
        }
        return window
    }

    /// A saved frame that is no longer on any screen (a monitor went away)
    /// is centered on the main screen instead.
    private func place(_ window: NSWindow) {
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame.insetBy(dx: 40, dy: 40)) }
        if !visible { center(window) }
    }

    /// Centered a little above the middle of the screen with the key window
    /// (`NSScreen.main`), not necessarily the notched built-in display.
    private func center(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { window.center(); return }
        let area = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.08)
        window.setFrameOrigin(NSPoint(x: max(area.minX, origin.x), y: min(max(area.minY, origin.y), area.maxY - size.height)))
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        lastPane = currentPane
        // Back to a Dock-less agent once no other SparkV window is open.
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// The window width that fits every toolbar label: each preference item is
/// its label plus padding, never narrower than its icon cell.
@MainActor
enum SettingsToolbarWidth {
    static let minimum: CGFloat = 780

    static func width(for labels: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let items = labels.reduce(CGFloat(0)) { sum, label in
            sum + max((label as NSString).size(withAttributes: [.font: font]).width + 26, 52)
        }
        let needed = (items + 48).rounded(.up)
        let screen = (NSScreen.main?.visibleFrame.width ?? 1440) - 80
        return min(max(minimum, needed), max(minimum, screen))
    }
}

/// Reports pane changes (toolbar click, ⌘-number in the toolbar) so the
/// window reopens on the last pane.
final class SparkVSettingsTabController: NSTabViewController {
    var onSelect: ((SparkVSettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SparkVSettingsPane(rawValue: id) {
            onSelect?(pane)
        }
    }
}

// MARK: - Pane chrome

/// One pane: a native grouped form (System Settings style) on the look's
/// window ground. Sections come from `SparkVSettingsPanes.sections(for:)`.
struct SparkVSettingsPaneRoot: View {
    let pane: SparkVSettingsPane

    var body: some View {
        Form {
            SparkVSettingsPanes.sections(for: pane)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SparkVSettingsGround())
        .tint(SparkVTheme.accent)
        .environment(\.colorScheme, .dark)
    }
}

/// The card lane: hosts a self-contained card section (LookLayout's
/// LookCard, HUDPlus, Planner, anything that draws its own rounded card)
/// inside the pane's grouped Form without a second background, the Form's
/// row insets or separators. Use it in AppShellSettingsPanes.swift:
///
///     SettingsCardRow { AppearanceSettingsSection() }
///
/// A section that is a plain `Section { … } header: { … }` goes in as is.
struct SettingsCardRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// The grouped Form's row inset on macOS. listRowInsets isn't honored
    /// there, so the card grows by the inset and covers the section's own
    /// ground exactly (checked in offscreen renders, both looks).
    static var formRowInset: CGFloat { 10 }

    var body: some View {
        Section {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(-Self.formRowInset)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}

/// The window ground: dark vibrancy in Apple, the flat brand ground with
/// its soft red glow in SparkV Red.
struct SparkVSettingsGround: View {
    var body: some View {
        if SparkVTheme.isApple {
            AppearanceWindowBackground()
        } else {
            ZStack {
                SparkVTheme.background
                SparkVTheme.glow.opacity(0.7).allowsHitTesting(false)
            }
        }
    }
}

/// Shown in a pane until a package adds its sections there (see
/// INTEGRATION.md: delete this line when the first real section lands).
struct SettingsPanePlaceholderSection: View {
    let pane: SparkVSettingsPane

    private var note: String {
        switch pane {
        case .media: "Now Playing, artwork glow and media options are in the drawer’s gear menu for now."
        case .system: "Volume and brightness HUD and battery options are in the drawer’s gear menu › Live Activities for now."
        case .activities: "Live Activity switches are in the drawer’s gear menu › Live Activities for now."
        case .planner: "Calendar, timer and Focus options are in the drawer’s gear menu for now."
        case .shelf: "Tray, Downloads and File Drop options are in the drawer’s gear menu for now."
        default: "More options are in the drawer’s gear menu for now."
        }
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(pane.title) settings are moving here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Opening Settings from anywhere

/// One call for every entry point.
@MainActor
enum SparkVSettings {
    static func show(_ pane: SparkVSettingsPane? = nil) {
        SparkVSettingsWindowController.shared.show(pane: pane)
    }
}
