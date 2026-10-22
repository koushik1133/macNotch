import AppKit
import Foundation

/// The two action capsules in the drawer. Each slot runs either a built-in
/// SparkV action or a shortcut from the user's library, chosen from a
/// menu and saved in UserDefaults.
@MainActor
final class MacroController: ObservableObject {
    enum BuiltInAction: String, CaseIterable, Identifiable {
        case dictate
        case captureToTray
        case recordMeeting

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictate: "Dictate"
            case .captureToTray: "Capture to Tray"
            case .recordMeeting: "Record Meeting"
            }
        }

        var systemImage: String {
            switch self {
            case .dictate: "mic.fill"
            case .captureToTray: "camera.viewfinder"
            case .recordMeeting: "record.circle"
            }
        }
    }

    enum Assignment: Equatable {
        case builtIn(BuiltInAction)
        /// Exact name of the shortcut in the Shortcuts app.
        case shortcut(String)

        var title: String {
            switch self {
            case .builtIn(let action): action.title
            case .shortcut(let name): name
            }
        }

        fileprivate var storageValue: String {
            switch self {
            case .builtIn(let action): "builtin:\(action.rawValue)"
            case .shortcut(let name): "shortcut:\(name)"
            }
        }

        fileprivate init?(storageValue value: String) {
            if value.isEmpty { return nil }
            if value.hasPrefix("builtin:") {
                guard let action = BuiltInAction(rawValue: String(value.dropFirst("builtin:".count))) else { return nil }
                self = .builtIn(action)
            } else if value.hasPrefix("shortcut:") {
                self = .shortcut(String(value.dropFirst("shortcut:".count)))
            } else {
                // Saved by an earlier version, which only stored shortcut names.
                self = .shortcut(value)
            }
        }

        /// Whether `value` was written by this format (prefixed) rather than
        /// the original one, which stored bare shortcut names or "".
        fileprivate static func isCurrentFormat(_ value: String) -> Bool {
            value.hasPrefix("builtin:") || value.hasPrefix("shortcut:")
        }
    }

    struct Slot: Identifiable, Equatable {
        let id: Int
        /// nil until the user picks something.
        var assignment: Assignment?
    }

    enum Status: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
        /// Nothing chosen for this slot yet.
        case unassigned
        /// The chosen shortcut is no longer in the user's library.
        case missing
    }

    @Published private(set) var slots: [Slot]
    /// Every shortcut in the user's library, in library order.
    @Published private(set) var library: [String] = []
    @Published private var statuses: [Int: Status] = [:]

    /// Runs built-in actions; set by the window controller, which owns the
    /// tray and the dictation engine.
    var performBuiltIn: ((BuiltInAction) -> Void)?

    /// nil until the first `shortcuts list` succeeds; until then every chosen
    /// shortcut is assumed present.
    private var availableNames: Set<String>?
    private var lastLibraryCheck: ContinuousClock.Instant?
    private var isCheckingLibrary = false
    private var resetTasks: [Int: Task<Void, Never>] = [:]
    private let runner = ShortcutRunner()

    private static let defaultsKey = "MacroSlots"
    /// Set once the slots are saved in the prefixed format, so an all-empty
    /// array saved by this version isn't mistaken for the original format.
    private static let formatKey = "MacroSlots.format"
    private static let currentFormat = 2
    private static let slotCount = 2
    /// Out of the box: the two built-ins, which work without any setup.
    private static let defaultAssignments: [Assignment] = [.builtIn(.dictate), .builtIn(.captureToTray)]

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: Self.defaultsKey)
        let isLegacy = saved.map { values in
            defaults.integer(forKey: Self.formatKey) < Self.currentFormat
                && !values.contains(where: Assignment.isCurrentFormat)
        } ?? false

        slots = (0..<Self.slotCount).map { index in
            guard let saved else {
                return Slot(id: index, assignment: Self.defaultAssignments[index])
            }
            let value = index < saved.count ? saved[index] : ""
            if isLegacy {
                // The original format: "" meant "never chosen", which now
                // gets the built-in default instead of an empty capsule.
                return Slot(id: index, assignment: value.isEmpty ? Self.defaultAssignments[index] : .shortcut(value))
            }
            return Slot(id: index, assignment: Assignment(storageValue: value))
        }

        if isLegacy {
            AppLog.log("Shortcuts: migrated capsule slots \(saved ?? []) to \(slots.map { $0.assignment?.storageValue ?? "" })")
            saveSlots()
        } else if saved != nil, defaults.integer(forKey: Self.formatKey) < Self.currentFormat {
            defaults.set(Self.currentFormat, forKey: Self.formatKey)
        }
        refreshLibrary()
    }

    private func saveSlots() {
        UserDefaults.standard.set(slots.map { $0.assignment?.storageValue ?? "" }, forKey: Self.defaultsKey)
        UserDefaults.standard.set(Self.currentFormat, forKey: Self.formatKey)
    }

    func status(for slot: Slot) -> Status {
        if let status = statuses[slot.id], status != .idle {
            return status
        }
        switch slot.assignment {
        case nil:
            return .unassigned
        case .builtIn:
            return .idle
        case .shortcut(let name):
            if let availableNames, !availableNames.contains(Self.normalized(name)) {
                return .missing
            }
            return .idle
        }
    }

    func assign(_ assignment: Assignment?, to slotID: Int) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].assignment = assignment
        resetTasks[slotID]?.cancel()
        statuses[slotID] = nil
        saveSlots()
    }

    func run(_ slot: Slot) {
        switch slot.assignment {
        case nil:
            return
        case .builtIn(let action):
            performBuiltIn?(action)
        case .shortcut(let name):
            runShortcut(name, in: slot)
        }
    }

    private func runShortcut(_ name: String, in slot: Slot) {
        guard status(for: slot) != .running else { return }

        resetTasks[slot.id]?.cancel()
        statuses[slot.id] = .running

        Task {
            let outcome: Status
            do {
                _ = try await runner.run(name)
                outcome = .succeeded
            } catch {
                outcome = .failed(error.localizedDescription)
                AppLog.log("Shortcuts: “\(name)” failed: \(error.localizedDescription)")
                // It may have been renamed or deleted since the last check.
                refreshLibrary()
            }
            statuses[slot.id] = outcome

            // Success flashes briefly; failures stay long enough to read.
            let hold: Duration = outcome == .succeeded ? .seconds(2.5) : .seconds(6)
            resetTasks[slot.id] = Task {
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                statuses[slot.id] = .idle
            }
        }
    }

    func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        // Pick up anything the user creates there on the next expand.
        lastLibraryCheck = nil
    }

    /// Re-reads the Shortcuts library at most every 30 seconds.
    func refreshLibraryIfStale() {
        if let lastLibraryCheck, ContinuousClock.now - lastLibraryCheck < .seconds(30) {
            return
        }
        refreshLibrary()
    }

    func refreshLibrary() {
        guard !isCheckingLibrary else { return }
        isCheckingLibrary = true
        Task {
            defer { isCheckingLibrary = false }
            do {
                let names = try await runner.listShortcuts()
                library = names
                availableNames = Set(names.map(Self.normalized))
                lastLibraryCheck = .now
            } catch {
                AppLog.log("Shortcuts: could not list shortcuts: \(error.localizedDescription)")
            }
        }
    }

    /// Shortcuts and the CLI may disagree on Unicode composition ("Laís").
    private static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }
}
