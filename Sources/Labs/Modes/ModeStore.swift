import Foundation

// Persistence for Modes, in ~/Library/Application Support/SparkV/Modes/:
//   modes.json             the user's modes (versioned, see ModeLibraryFile)
//   active-snapshot.json   what to put back, written before a mode applies
//                          anything and kept until it's restored, so a crash
//                          or force quit is undone at the next launch.

/// What `modes.json` holds.
struct ModeLibraryFile: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = ModeLibraryFile.currentVersion
    var modes: [SparkMode]
    /// Bundle IDs the user agreed SparkV may quit (asked once per app).
    var approvedQuitApps: [String] = []
    /// Built-in mode IDs that were added once. A preset the user deleted
    /// stays deleted; presets added in a later SparkV version still appear.
    var seededBuiltIns: [UUID] = []

    init(modes: [SparkMode], approvedQuitApps: [String] = [], seededBuiltIns: [UUID] = []) {
        self.modes = modes
        self.approvedQuitApps = approvedQuitApps
        self.seededBuiltIns = seededBuiltIns
    }

    private enum CodingKeys: String, CodingKey { case version, modes, approvedQuitApps, seededBuiltIns }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // One damaged mode is skipped, not the whole library.
        modes = (try c.decodeIfPresent([ModeLenient<SparkMode>].self, forKey: .modes) ?? []).compactMap(\.value)
        approvedQuitApps = try c.decodeIfPresent([String].self, forKey: .approvedQuitApps) ?? []
        seededBuiltIns = try c.decodeIfPresent([UUID].self, forKey: .seededBuiltIns) ?? []
    }

    /// Fresh library with every preset.
    static var initial: ModeLibraryFile {
        ModeLibraryFile(modes: ModePresets.all, seededBuiltIns: ModePresets.all.map(\.id))
    }

    /// Adds presets this library has never had (new in this version).
    mutating func addNewBuiltIns() -> Bool {
        let seeded = Set(seededBuiltIns)
        let fresh = ModePresets.all.filter { !seeded.contains($0.id) }
        guard !fresh.isEmpty else { return false }
        let existing = Set(modes.map(\.id))
        modes += fresh.filter { !existing.contains($0.id) }
        seededBuiltIns += fresh.map(\.id)
        return true
    }
}

/// An app a mode quit, so restoring can open it again.
struct ModeQuitRecord: Codable, Hashable, Sendable {
    var bundleID: String
    var name: String
    var path: String?
}

/// Everything a running mode changed, with the values from before.
/// Values are captured the first time an action touches them, so a mode
/// with two volume steps still restores the original level.
struct ModeSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = ModeSnapshot.currentVersion
    var modeID: UUID
    var modeName: String
    var restoreOnExit: Bool
    var startedAt: Date
    var endsAt: Date?
    /// Still applying (a crash mid-activation is undone the same way).
    var isApplying = true
    /// ModeStepKind raw values in the order they were first applied;
    /// restoring walks this backwards.
    var applied: [String] = []

    var wallpapers: [String: ModeWallpaperState] = [:]
    var volume: Double?
    /// The output's mute state before the mode set a volume (nil: unknown).
    var volumeWasMuted: Bool?
    var darkMode: Bool?
    var brightness: Double?
    /// Bundle IDs this mode hid (apps that were already hidden aren't listed).
    var hiddenApps: [String] = []
    var quitApps: [ModeQuitRecord] = []
    /// Set when the mode turned Do Not Disturb on: the shortcut that turns it off.
    var doNotDisturbOffShortcut: String?
    var startedMusic = false
    var startedFocusSession = false
    /// SparkV previews' setting before the mode changed it.
    var previewsWereEnabled: Bool?

    init(mode: SparkMode, startedAt: Date) {
        modeID = mode.id
        modeName = mode.name
        restoreOnExit = mode.restoreOnExit
        self.startedAt = startedAt
        endsAt = mode.autoEndMinutes.map { startedAt.addingTimeInterval(TimeInterval($0) * 60) }
    }

    mutating func noteApplied(_ kind: ModeStepKind) {
        if !applied.contains(kind.rawValue) { applied.append(kind.rawValue) }
    }
}

@MainActor
final class ModeStore {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Modes", isDirectory: true)
    }

    let directory: URL
    private(set) var lastError: String?

    var libraryURL: URL { directory.appendingPathComponent("modes.json") }
    var snapshotURL: URL { directory.appendingPathComponent("active-snapshot.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    // MARK: Library

    /// The saved library, the presets on first run, or (when the file can't
    /// be read) the presets after moving the damaged file aside.
    func loadLibrary() -> ModeLibraryFile {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return .initial }
        do {
            let data = try Data(contentsOf: libraryURL)
            var file = try Self.decoder.decode(ModeLibraryFile.self, from: data)
            if file.version > ModeLibraryFile.currentVersion {
                // Saving drops what this version can't read, so keep the
                // newer file first (once per version).
                let backup = directory.appendingPathComponent("modes.v\(file.version)-backup.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: libraryURL, to: backup)
                }
                AppLog.log("Modes: modes.json is version \(file.version), newer than this SparkV; kept a copy and reading what it can")
            }
            file.version = ModeLibraryFile.currentVersion
            if file.addNewBuiltIns() { saveLibrary(file) }
            return file
        } catch {
            // An existing file that can't be read or decoded is never
            // overwritten: it's renamed first, and if that fails, saving
            // stays off for this run.
            if preserveDamaged(libraryURL) {
                lastError = "Your modes file couldn't be read, so the built-in modes were loaded. The old file was kept next to it."
            } else {
                libraryLocked = true
                lastError = "Your modes file couldn't be read, so the built-in modes were loaded. Changes won't be saved until SparkV can read it again."
            }
            AppLog.log("Modes: modes.json unreadable (\(error.localizedDescription)); \(libraryLocked ? "left in place, saving off" : "moved aside")")
            return .initial
        }
    }

    /// True when an unreadable modes.json couldn't be moved aside, so it
    /// isn't overwritten.
    private(set) var libraryLocked = false

    func saveLibrary(_ file: ModeLibraryFile) {
        guard !libraryLocked else { return }
        write(file, to: libraryURL)
    }

    // MARK: Snapshot

    func loadSnapshot() -> ModeSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        do {
            return try Self.decoder.decode(ModeSnapshot.self, from: data)
        } catch {
            preserveDamaged(snapshotURL)
            AppLog.log("Modes: restore snapshot unreadable (\(error.localizedDescription)); moved aside")
            return nil
        }
    }

    func saveSnapshot(_ snapshot: ModeSnapshot) {
        write(snapshot, to: snapshotURL)
    }

    /// Removes SparkV's own snapshot file once everything was put back.
    func clearSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    // MARK: Files

    private func write(_ value: some Encodable, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(value)
            try data.write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            AppLog.log("Modes: save failed for \(url.lastPathComponent) (\(error.localizedDescription))")
        }
    }

    /// Renames a damaged file (never deletes it) so the user's data
    /// survives. Returns false when the file is still in place.
    @discardableResult
    private func preserveDamaged(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return true }
        let stamp = Int(Date().timeIntervalSince1970)
        var target = url.deletingPathExtension().appendingPathExtension("damaged-\(stamp).json")
        if fileManager.fileExists(atPath: target.path) {
            target = url.deletingPathExtension().appendingPathExtension("damaged-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        }
        do {
            try fileManager.moveItem(at: url, to: target)
            return true
        } catch {
            AppLog.log("Modes: couldn't move \(url.lastPathComponent) aside (\(error.localizedDescription))")
            return false
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
