import AppKit

/// Entry point. SparkV is an agent app (LSUIElement = true in Info.plist),
/// so there is no Dock icon, no App Switcher entry and no main menu.
@main
enum NotchIslandApp {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        AppMigration.runIfNeeded()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
