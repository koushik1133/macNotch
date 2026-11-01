import AppKit
import SwiftUI

/// The app shell: Settings window, menu bar icon, main menu, reopen,
/// updates, crash and hang reports, reset/uninstall and the sparkv:// URL
/// scheme. AppDelegate starts and stops it; NotchWindowController connects
/// the drawer and the island (see INTEGRATION.md) so the shell can open the
/// drawer and post live activities. Without that connection everything
/// still works and falls back to the Settings window.
@MainActor
final class AppShellController: ObservableObject {
    static let shared = AppShellController()

    /// What opening SparkV again (Finder, Spotlight, Launchpad, the Dock
    /// icon while a window is open) does.
    enum ReopenAction: String, CaseIterable, Identifiable {
        case settings, drawer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .settings: "Show Settings"
            case .drawer: "Open the Drawer"
            }
        }
    }

    static let reopenKey = "AppShell.reopen.action"

    @Published var reopenAction: ReopenAction {
        didSet { UserDefaults.standard.set(reopenAction.rawValue, forKey: Self.reopenKey) }
    }

    // MARK: Hooks (set by NotchWindowController, see INTEGRATION.md)

    /// Opens the drawer on a tab (nil: the current one) and keeps it open
    /// until the pointer has been over it once. `reveal` (the user clicked
    /// the menu bar icon or opened SparkV again) brings a hidden island back
    /// for the moment, like ⌃⌥H; links never reveal it. Returns false when
    /// nothing could be shown (the island is hidden, no display for it).
    var openDrawer: ((_ tab: NotchState.Tab?, _ reveal: Bool) -> Bool)?
    var closeDrawer: (() -> Void)?
    var toggleDrawer: (() -> Void)?
    /// The island's ActivityCenter.
    var postActivity: ((LiveActivity) -> Void)?
    var dismissActivity: ((String) -> Void)?
    /// Finishes a recording or mode and stops every feature (Reset and
    /// Uninstall call it before deleting anything).
    var prepareForReset: (() async -> Void)?

    private(set) var isStarted = false
    private var wakeObserver: NSObjectProtocol?

    private init() {
        reopenAction = UserDefaults.standard.string(forKey: Self.reopenKey).flatMap(ReopenAction.init(rawValue:)) ?? .settings
    }

    /// From `applicationDidFinishLaunching`, after the notch controller.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        // The main menu is installed in applicationWillFinishLaunching.
        if NSApp.mainMenu == nil { AppShellMenus.installMainMenu() }
        StatusItemController.shared.start()
        DiagnosticsController.shared.start()
        UpdateController.shared.start()
        // SparkV runs for weeks between launches: also rotate the log on
        // wake (an event, nothing polls) and before every export.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.global(qos: .utility).async { AppShellLogMaintenance.rotateIfNeeded() }
        }
        // Last: links that arrived during launch run now.
        AutomationRouter.shared.start()
        AppLog.log("App shell: started (SparkV \(SparkVAppInfo.versionText))")
    }

    /// From `applicationWillTerminate`. Removes the status item, the
    /// MetricKit subscriber and the update schedule.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        AutomationRouter.shared.stop()
        UpdateController.shared.stop()
        DiagnosticsController.shared.stop()
        StatusItemController.shared.stop()
    }

    /// `applicationShouldHandleReopen`: the island's panel always counts as
    /// a visible window, so the flag says nothing; always do the action.
    func handleReopen() {
        AppLog.log("App shell: reopened (\(reopenAction.rawValue))")
        switch reopenAction {
        case .settings: SparkVSettings.show()
        case .drawer: openDrawerOrSettings()
        }
    }

    /// Opens the drawer on Home (bringing a hidden island back for the
    /// moment), or Settings when the island isn't connected or can't show.
    func openDrawerOrSettings() {
        if let openDrawer, openDrawer(.nook, true) { return }
        AppLog.log("App shell: the island can't show right now, opening Settings")
        SparkVSettings.show()
    }

    /// `application(_:open:)`. Files dropped on the Dock icon or opened with
    /// `open -a SparkV <file>` are not links: they are ignored quietly
    /// instead of filling Recent links with failures.
    func handle(urls: [URL]) {
        let links = urls.filter { !$0.isFileURL }
        if links.count < urls.count { AppLog.log("App shell: ignored \(urls.count - links.count) file(s) opened with SparkV") }
        guard !links.isEmpty else { return }
        AutomationRouter.shared.handle(links)
    }

    /// Posts on the island; false when the island isn't connected.
    @discardableResult
    func post(_ activity: LiveActivity) -> Bool {
        guard let postActivity else { return false }
        postActivity(activity)
        return true
    }
}

/// Size-based rotation of ~/Library/Logs/SparkV.log: at launch, on wake
/// and before a diagnostics export.
enum AppShellLogMaintenance {
    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/SparkV.log")
    }

    static func rotateIfNeeded() {
        let files = FileManager.default
        let log = logURL
        guard let size = (try? files.attributesOfItem(atPath: log.path))?[.size] as? NSNumber else { return }
        for step in LogRotation.plan(log: log, size: size.intValue) {
            guard files.fileExists(atPath: step.from.path) else { continue }
            if let to = step.to {
                try? files.removeItem(at: to)
                try? files.moveItem(at: step.from, to: to)
            } else {
                try? files.removeItem(at: step.from)
            }
        }
    }
}
