import AppKit
import SwiftUI

// MARK: - App info, About, Quit

/// Version, links and the About panel.
@MainActor
enum SparkVAppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// "1.0 (1)"
    static var versionText: String { "\(shortVersion) (\(build))" }

    static var version: SparkVVersion { SparkVVersion(shortVersion) ?? SparkVVersion("1.0")! }

    static let repositoryURL = URL(string: "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repository)")!
    static let newIssueURL = URL(string: "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repository)/issues/new")!

    /// Installed with `brew install --cask sparkv` (the Caskroom keeps a record).
    static var isHomebrewInstall: Bool {
        ["/opt/homebrew/Caskroom/sparkv", "/usr/local/Caskroom/sparkv"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static let brewUpgradeCommand = "brew upgrade --cask sparkv"

    /// The bundle has no icon yet: the drawn mark becomes the Dock and
    /// ⌘-Tab icon for the times a SparkV window makes it a regular app.
    static func installDockIconIfNeeded() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["CFBundleIconFile"] == nil, info["CFBundleIconName"] == nil,
              let mark = SparkVAppMark.image(size: 512) else { return }
        NSApp.applicationIconImage = mark
    }

    /// The standard About panel with the version, build and the licenses of
    /// the open-source parts. An agent app must activate first or the panel
    /// opens behind the front app.
    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "SparkV",
            .applicationVersion: shortVersion,
            .version: "Build \(build)",
            .credits: credits(),
        ]
        // Until the bundle ships an icon, the drawn mark stands in.
        let info = Bundle.main.infoDictionary ?? [:]
        if info["CFBundleIconFile"] == nil, info["CFBundleIconName"] == nil, let mark = SparkVAppMark.image(size: 128) {
            options[.applicationIcon] = mark
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        // Find the panel just opened and bring it to this Space.
        for window in NSApp.windows where window.className.contains("About") {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
        }
        AppLog.log("About: shown (\(versionText))")
    }

    /// Credits under the version: what SparkV is built with and where the
    /// licenses are. Colors follow the panel's light or dark appearance.
    static func credits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let text = NSMutableAttributedString(string: "Dynamic Island for the MacBook notch. Everything runs on this Mac.\n\n", attributes: body)
        let lines = [
            "Face Unlock: glance (MIT) and the ArcFace model (non-commercial use only).",
            "Now Playing: mediaremote-adapter (BSD 3-Clause).",
            "Licenses: SparkV.app › Contents › Resources.",
        ]
        text.append(NSAttributedString(string: lines.joined(separator: "\n") + "\n\n", attributes: body))
        var link = body
        link[.link] = repositoryURL
        link[.foregroundColor] = NSColor.linkColor
        text.append(NSAttributedString(string: "github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repository)", attributes: link))
        return text
    }

    /// Quits through `applicationShouldTerminate`, so a recording or mode
    /// still finishes first.
    static func quit() {
        AppLog.log("Quit: from the app shell")
        NSApp.terminate(nil)
    }
}

// MARK: - SwiftUI menu items (gear menu, right-click)

/// Settings…, Check for Updates…, About, Quit: for the gear menu, at the
/// bottom in place of the bare "Quit SparkV" button.
struct AppShellMenuItems: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        Button("Settings…") { SparkVSettings.show() }
        Button(updates.menuTitle) { updates.checkNow(userInitiated: true) }
            .disabled(updates.isChecking)
        Menu("Troubleshooting") { AppShellTroubleshootingMenuItems() }
        Divider()
        Button("About SparkV") { SparkVAppInfo.showAbout() }
        Button("Quit SparkV") { SparkVAppInfo.quit() }
    }
}

/// Diagnostics, automation guide, reset and uninstall.
struct AppShellTroubleshootingMenuItems: View {
    var body: some View {
        Button("Crash & Hang Reports…") { DiagnosticsWindowController.shared.show() }
        Button("Export Diagnostics…") { DiagnosticsController.shared.exportWithPanel() }
        Button("Automation Guide…") { AutomationGuideWindowController.shared.show() }
        Divider()
        Button("Reset SparkV…") { ResetController.shared.confirm(.reset) }
        Button("Uninstall SparkV…") { ResetController.shared.confirm(.uninstall) }
    }
}

/// Right-click on the open island: version, Settings, About, Quit.
struct AppShellContextMenuItems: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        Text("SparkV \(SparkVAppInfo.versionText)")
        Divider()
        Button("Settings…") { SparkVSettings.show() }
        Button(updates.menuTitle) { updates.checkNow(userInitiated: true) }
            .disabled(updates.isChecking)
        Divider()
        Button("About SparkV") { SparkVAppInfo.showAbout() }
        Button("Quit SparkV") { SparkVAppInfo.quit() }
    }
}

// MARK: - AppKit menus (main menu, status item, closed-island right-click)

/// Target for every AppKit menu item the shell builds.
@MainActor
final class AppShellMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = AppShellMenuTarget()

    @objc func openSettings(_ sender: Any?) { SparkVSettings.show() }
    @objc func checkForUpdates(_ sender: Any?) { UpdateController.shared.checkNow(userInitiated: true) }
    @objc func showAbout(_ sender: Any?) { SparkVAppInfo.showAbout() }
    @objc func quit(_ sender: Any?) { SparkVAppInfo.quit() }
    @objc func openDrawer(_ sender: Any?) { AppShellController.shared.openDrawerOrSettings() }
    @objc func showDiagnostics(_ sender: Any?) { DiagnosticsWindowController.shared.show() }
    @objc func exportDiagnostics(_ sender: Any?) { DiagnosticsController.shared.exportWithPanel() }
    @objc func showAutomationGuide(_ sender: Any?) { AutomationGuideWindowController.shared.show() }
    @objc func openRepository(_ sender: Any?) { NSWorkspace.shared.open(SparkVAppInfo.repositoryURL) }
    @objc func reset(_ sender: Any?) { ResetController.shared.confirm(.reset) }
    @objc func uninstall(_ sender: Any?) { ResetController.shared.confirm(.uninstall) }
    @objc func hideStatusItem(_ sender: Any?) { StatusItemController.shared.setVisible(false) }

    /// Key equivalents only while SparkV itself is the active app: ⌘, and
    /// ⌘Q never fire because the drawer's panel happened to be key while
    /// another app was in front.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return !UpdateController.shared.isChecking }
        if !menuItem.keyEquivalent.isEmpty, menuItem.target === self { return NSApp.isActive }
        return true
    }
}

@MainActor
enum AppShellMenus {
    /// An item handled by `AppShellMenuTarget`.
    static func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                     symbol: String? = nil) -> NSMenuItem {
        let item = responder(title, action, key: key, modifiers: modifiers)
        item.target = AppShellMenuTarget.shared
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// A standard item sent along the responder chain (Copy, Close, Hide…).
    static func responder(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    /// The menu bar SparkV shows while one of its windows is open (it is a
    /// regular app then): standard app, Edit and Window menus, so ⌘, ⌘W
    /// and copy/paste in text fields work. Nothing here is a global hotkey.
    static func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu(title: "SparkV")
        app.addItem(item("About SparkV", #selector(AppShellMenuTarget.showAbout(_:))))
        app.addItem(item("Check for Updates…", #selector(AppShellMenuTarget.checkForUpdates(_:))))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppShellMenuTarget.openSettings(_:)), key: ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        // No Hide items: hiding SparkV would hide the island too, and the
        // drawer's panel can be key while another app is in front.
        app.addItem(.separator())
        app.addItem(item("Quit SparkV", #selector(AppShellMenuTarget.quit(_:)), key: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(responder("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(responder("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(responder("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(responder("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(responder("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(responder("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift]))
        edit.addItem(responder("Delete", #selector(NSText.delete(_:))))
        edit.addItem(responder("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(responder("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(responder("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(responder("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(responder("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("Automation Guide", #selector(AppShellMenuTarget.showAutomationGuide(_:))))
        help.addItem(item("Crash & Hang Reports", #selector(AppShellMenuTarget.showDiagnostics(_:))))
        help.addItem(item("SparkV on GitHub", #selector(AppShellMenuTarget.openRepository(_:))))
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    /// The menu of the menu bar icon and of a right-click on the closed island.
    static func shellMenu(includeHide: Bool) -> NSMenu {
        let menu = NSMenu(title: "SparkV")
        menu.autoenablesItems = true
        let header = NSMenuItem(title: "SparkV \(SparkVAppInfo.versionText)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let release = UpdateController.shared.availableRelease {
            let update = item("Update Available: SparkV \(release.displayVersion)…", #selector(AppShellMenuTarget.checkForUpdates(_:)),
                              symbol: "arrow.down.circle")
            menu.addItem(update)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Drawer", #selector(AppShellMenuTarget.openDrawer(_:)), symbol: "rectangle.topthird.inset.filled"))
        menu.addItem(item("Settings…", #selector(AppShellMenuTarget.openSettings(_:)), symbol: "gearshape"))
        if UpdateController.shared.availableRelease == nil {
            menu.addItem(item("Check for Updates…", #selector(AppShellMenuTarget.checkForUpdates(_:)), symbol: "arrow.triangle.2.circlepath"))
        }
        menu.addItem(.separator())
        let trouble = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        let troubleMenu = NSMenu(title: "Troubleshooting")
        troubleMenu.addItem(item("Crash & Hang Reports…", #selector(AppShellMenuTarget.showDiagnostics(_:))))
        troubleMenu.addItem(item("Export Diagnostics…", #selector(AppShellMenuTarget.exportDiagnostics(_:))))
        troubleMenu.addItem(item("Automation Guide…", #selector(AppShellMenuTarget.showAutomationGuide(_:))))
        troubleMenu.addItem(.separator())
        troubleMenu.addItem(item("Reset SparkV…", #selector(AppShellMenuTarget.reset(_:))))
        troubleMenu.addItem(item("Uninstall SparkV…", #selector(AppShellMenuTarget.uninstall(_:))))
        trouble.submenu = troubleMenu
        trouble.image = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: nil)
        menu.addItem(trouble)
        if includeHide {
            menu.addItem(item("Hide Menu Bar Icon", #selector(AppShellMenuTarget.hideStatusItem(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item("About SparkV", #selector(AppShellMenuTarget.showAbout(_:))))
        menu.addItem(item("Quit SparkV", #selector(AppShellMenuTarget.quit(_:))))
        return menu
    }
}

/// Right-click on the closed island (the notch itself): the same shell
/// menu at the pointer. Used only on a notched screen, where nothing of the
/// menu bar sits under the camera housing.
@MainActor
enum AppShellIslandMenu {
    static func popUp(at screenPoint: NSPoint = NSEvent.mouseLocation) {
        let menu = AppShellMenus.shellMenu(includeHide: false)
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }
}

// MARK: - Agents hub tile

/// "Settings" tile for the Agents hub (category: System). The hub's own
/// AgentTile face; a dot marks an available update. Right-click: the hub's
/// Pin / Hide / Move items (HubTileMenuItems, from the hub cell).
struct SettingsHubTile: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        let update = updates.availableRelease
        // The hub's own tile face (both looks, high contrast), so it never
        // drifts from the other tiles. No menu of its own: the hub cell's
        // Pin / Hide / Move menu applies.
        AgentTile(
            title: "Settings",
            systemImage: "gearshape.fill",
            tint: Color(white: 0.72),
            help: update.map { "Settings · SparkV \($0.displayVersion) is available" } ?? "Settings (⌘, while SparkV is in front)"
        ) {
            SparkVSettings.show()
        }
        .overlay(alignment: .topTrailing) {
            if update != nil {
                Circle()
                    .fill(SparkVTheme.accent)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(update.map { "Update available: \($0.displayVersion)" } ?? "")
    }
}
