import AppKit
import Foundation

/// Turns macOS Do Not Disturb on and off through two user-created Shortcuts,
/// the way Session ("session_start"/"session_end") and Tuple ("dnd-on"/
/// "dnd-off") do it. Since macOS 12 there's no public API to set a Focus,
/// and the old preference-file and keyboard-shortcut hacks break between
/// releases, while the Shortcuts "Set Focus" action is Apple's own supported
/// path and runs headless through /usr/bin/shortcuts (`ShortcutRunner`).
/// SparkV's own notification previews are muted separately by the controller.
@MainActor
final class FocusDoNotDisturb: ObservableObject {
    enum Setup: Equatable {
        case unknown
        case checking
        /// Both shortcuts exist in the library.
        case ready
        /// Missing shortcut names.
        case missing([String])
        case failed(String)
    }

    enum Outcome: Equatable {
        case done
        case notSetUp
        case failed(String)
    }

    @Published private(set) var setup: Setup = .unknown
    /// Names in the user's Shortcuts library (for the pickers in settings).
    @Published private(set) var library: [String] = []
    @Published private(set) var lastError: String?

    /// Common names other apps' guides use, offered when ours don't exist.
    nonisolated static let knownPairs: [(on: String, off: String)] = [
        (FocusSettings.defaultOnShortcut, FocusSettings.defaultOffShortcut),
        ("dnd-on", "dnd-off"),
        ("DND On", "DND Off"),
        ("Focus On", "Focus Off"),
        ("Do Not Disturb On", "Do Not Disturb Off"),
        ("session_start", "session_end"),
    ]

    private let runner: ShortcutRunner
    private var lastCheck: Date?

    init(runner: ShortcutRunner = ShortcutRunner(timeout: 20)) {
        self.runner = runner
    }

    /// Reads the library (cached for a minute unless `force`).
    func refresh(on: String, off: String, force: Bool = false) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 60, setup != .unknown {
            setup = Self.evaluate(library: library, on: on, off: off)
            return
        }
        setup = .checking
        do {
            library = try await runner.listShortcuts()
            lastCheck = Date()
            setup = Self.evaluate(library: library, on: on, off: off)
        } catch {
            setup = .failed(error.localizedDescription)
        }
    }

    nonisolated static func evaluate(library: [String], on: String, off: String) -> Setup {
        let names = Set(library)
        let missing = [on, off].filter { !$0.isEmpty && !names.contains($0) }
        if on.isEmpty || off.isEmpty { return .missing([on, off].filter { !$0.isEmpty }) }
        return missing.isEmpty ? .ready : .missing(missing)
    }

    /// A pair from `knownPairs` that's already in the library, if any.
    nonisolated static func detectPair(in library: [String]) -> (on: String, off: String)? {
        let names = Set(library)
        return knownPairs.first { names.contains($0.on) && names.contains($0.off) }
    }

    func turnOn(_ name: String) async -> Outcome { await run(name) }
    func turnOff(_ name: String) async -> Outcome { await run(name) }

    private func run(_ name: String) async -> Outcome {
        guard !name.isEmpty else { return .notSetUp }
        if case .missing(let names) = setup, names.contains(name) { return .notSetUp }
        do {
            _ = try await runner.run(name)
            lastError = nil
            return .done
        } catch {
            let message = error.localizedDescription
            lastError = message
            AppLog.log("Focus: Do Not Disturb shortcut failed (\(Self.shortReason(message)))")
            // A renamed or deleted shortcut: re-check the library next time.
            lastCheck = nil
            return .failed(message)
        }
    }

    /// Never logs anything the shortcut printed beyond its first line.
    private nonisolated static func shortReason(_ message: String) -> String {
        FocusText.clip(message, 60)
    }

    // MARK: Setup help

    /// Opens the Shortcuts app on a new, empty shortcut.
    static func openShortcutsToCreate() {
        if let url = URL(string: "shortcuts://create-shortcut"), NSWorkspace.shared.open(url) { return }
        openShortcutsApp()
    }

    static func openShortcutsApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Steps shown in the setup guide.
    static func guideSteps(on: String, off: String) -> [String] {
        [
            "Open Shortcuts and click + to make a new shortcut.",
            "Name it “\(on)”. Add the action Set Focus, choose Do Not Disturb, set it to Turn On, and pick Until Turned Off.",
            "Make a second shortcut named “\(off)” with Set Focus › Do Not Disturb › Turn Off.",
            "Run each one once from Shortcuts so macOS can ask for any permission, then click Check Again here.",
        ]
    }
}
