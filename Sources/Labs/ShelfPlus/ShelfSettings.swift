import AppKit
import Combine
import SwiftUI

/// Preferences for the Tray shelf, drags into the notch, Nearby sharing and
/// copy progress. Stored in UserDefaults under the "shelf." prefix; every
/// view and controller reads the one shared instance (tests make their own
/// with a scratch suite).
@MainActor
final class ShelfSettings: ObservableObject {
    static let shared = ShelfSettings()

    enum Keys {
        static let capacity = "shelf.capacity"
        static let keepAcrossRestarts = "shelf.keepAcrossRestarts"
        static let expiry = "shelf.expiry"
        static let dragOut = "shelf.dragOut"
        static let openOnDrag = "shelf.openOnDrag"
        static let shakeForShelf = "shelf.shakeForShelf"
        static let holdKey = "shelf.holdKeyForShelf"
        static let promoteNearby = "shelf.promoteNearbyShare"
        static let localSendEnabled = "shelf.localSend.enabled"
        static let localSendAlias = "shelf.localSend.alias"
        static let transfersEnabled = "shelf.transfers.enabled"
        static let transferFolders = "shelf.transfers.folders"
        static let transferVolumes = "shelf.transfers.volumes"
    }

    /// How long an item stays on the shelf.
    enum Expiry: String, CaseIterable, Identifiable, Sendable {
        case never, hour, day, week

        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: "Never"
            case .hour: "After 1 Hour"
            case .day: "After 1 Day"
            case .week: "After 1 Week"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .never: nil
            case .hour: 3600
            case .day: 86_400
            case .week: 7 * 86_400
            }
        }
    }

    /// What a drag out of the Tray does with a file the Tray only points to.
    /// Tray-made copies (screenshots, received files) are always copied, so
    /// they never vanish from the shelf.
    enum DragOut: String, CaseIterable, Identifiable, Sendable {
        /// Always a copy; hold ⌘ while dropping to move instead.
        case copy
        /// Like a Finder drag: moves on the same disk, ⌥ copies.
        case finder

        var id: String { rawValue }
        var title: String {
            switch self {
            case .copy: "Copy (⌘ to Move)"
            case .finder: "Like Finder (⌥ to Copy)"
            }
        }
    }

    /// Which drags may open the closed notch when they reach it.
    enum OpenOnDrag: String, CaseIterable, Identifiable, Sendable {
        /// Files, images and promised files only; never tabs, links or text.
        case files
        case anything
        case never

        var id: String { rawValue }
        var title: String {
            switch self {
            case .files: "Files Only"
            case .anything: "Files, Links and Text"
            case .never: "Never"
            }
        }
    }

    /// A modifier that, held during a file drag, opens a drop shelf at the pointer.
    enum HoldKey: String, CaseIterable, Identifiable, Sendable {
        case none, shift, control, function

        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .shift: "Shift ⇧"
            case .control: "Control ⌃"
            case .function: "fn"
            }
        }
        var flag: NSEvent.ModifierFlags? {
            switch self {
            case .none: nil
            case .shift: .shift
            case .control: .control
            case .function: .function
            }
        }
    }

    static let capacityRange = 5...30
    static let defaultCapacity = 5
    static let defaultAlias = "SparkV Mac"

    @Published var capacity: Int {
        didSet {
            // Assigning inside didSet doesn't re-run the observer.
            let clamped = min(max(capacity, Self.capacityRange.lowerBound), Self.capacityRange.upperBound)
            if clamped != capacity { capacity = clamped }
            defaults.set(capacity, forKey: Keys.capacity)
        }
    }
    @Published var keepAcrossRestarts: Bool { didSet { defaults.set(keepAcrossRestarts, forKey: Keys.keepAcrossRestarts) } }
    @Published var expiry: Expiry { didSet { defaults.set(expiry.rawValue, forKey: Keys.expiry) } }
    @Published var dragOut: DragOut { didSet { defaults.set(dragOut.rawValue, forKey: Keys.dragOut) } }
    @Published var openOnDrag: OpenOnDrag { didSet { defaults.set(openOnDrag.rawValue, forKey: Keys.openOnDrag) } }
    @Published var shakeForShelf: Bool { didSet { defaults.set(shakeForShelf, forKey: Keys.shakeForShelf) } }
    @Published var holdKey: HoldKey { didSet { defaults.set(holdKey.rawValue, forKey: Keys.holdKey) } }
    /// NearDrop / LocalSend / Quick Share first in the Share menu.
    @Published var promoteNearby: Bool { didSet { defaults.set(promoteNearby, forKey: Keys.promoteNearby) } }
    /// LocalSend sending: off until the user turns it on (it talks to other
    /// devices on the network).
    @Published var localSendEnabled: Bool { didSet { defaults.set(localSendEnabled, forKey: Keys.localSendEnabled) } }
    /// The name other devices see. Not the computer's name unless the user types it.
    @Published var localSendAlias: String {
        didSet {
            let trimmed = String(localSendAlias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            defaults.set(trimmed.isEmpty ? Self.defaultAlias : trimmed, forKey: Keys.localSendAlias)
        }
    }
    /// Finder copy / move progress under the notch.
    @Published var transfersEnabled: Bool { didSet { defaults.set(transfersEnabled, forKey: Keys.transfersEnabled) } }
    /// Watched destination folders, `~/…` form.
    @Published var transferFolders: [String] { didSet { defaults.set(transferFolders, forKey: Keys.transferFolders) } }
    /// Also the top level of every external drive.
    @Published var transferVolumes: Bool { didSet { defaults.set(transferVolumes, forKey: Keys.transferVolumes) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedCapacity = defaults.object(forKey: Keys.capacity) as? Int ?? Self.defaultCapacity
        capacity = min(max(storedCapacity, Self.capacityRange.lowerBound), Self.capacityRange.upperBound)
        keepAcrossRestarts = defaults.object(forKey: Keys.keepAcrossRestarts) as? Bool ?? true
        expiry = Expiry(rawValue: defaults.string(forKey: Keys.expiry) ?? "") ?? .never
        dragOut = DragOut(rawValue: defaults.string(forKey: Keys.dragOut) ?? "") ?? .copy
        openOnDrag = OpenOnDrag(rawValue: defaults.string(forKey: Keys.openOnDrag) ?? "") ?? .files
        shakeForShelf = defaults.object(forKey: Keys.shakeForShelf) as? Bool ?? true
        holdKey = HoldKey(rawValue: defaults.string(forKey: Keys.holdKey) ?? "") ?? .none
        promoteNearby = defaults.object(forKey: Keys.promoteNearby) as? Bool ?? true
        localSendEnabled = defaults.bool(forKey: Keys.localSendEnabled)
        localSendAlias = defaults.string(forKey: Keys.localSendAlias) ?? Self.defaultAlias
        transfersEnabled = defaults.bool(forKey: Keys.transfersEnabled)
        transferFolders = defaults.stringArray(forKey: Keys.transferFolders) ?? ["~/Desktop", "~/Documents"]
        transferVolumes = defaults.object(forKey: Keys.transferVolumes) as? Bool ?? true
    }

    /// The alias as sent (never empty).
    var effectiveAlias: String {
        let trimmed = localSendAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultAlias : String(trimmed.prefix(40))
    }

    /// Watched folders as URLs (`~` expanded).
    func transferFolderURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        transferFolders.compactMap { ShelfPaths.expand($0, home: home) }
    }
}

/// `~/…` <-> URL for stored folder paths.
enum ShelfPaths {
    static func expand(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true) }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    static func abbreviate(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
