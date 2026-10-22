import Foundation

// Shared value types for "Sync to iPhone (iCloud Drive)". Everything here is
// plain Foundation so the mirror engine and its tests build without the app.

/// What SparkV mirrors into iCloud Drive. The raw value is the sourceKey
/// prefix ("meetings:<id>"), so files from a category can be frozen when the
/// category is off or its data is unavailable.
enum CloudSyncCategory: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case meetings
    case flowNotes
    case dictations
    case spaces
    case tray
    case clipboard
    case focus
    case modes
    case habits

    var id: String { rawValue }

    static func < (a: Self, b: Self) -> Bool {
        (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
    }

    var title: String {
        switch self {
        case .meetings: "Meeting notes"
        case .flowNotes: "Flow notes"
        case .dictations: "Dictation history"
        case .spaces: "Spaces"
        case .tray: "Tray"
        case .clipboard: "Pinned clipboard"
        case .focus: "Focus sessions"
        case .modes: "Modes"
        case .habits: "Habits"
        }
    }

    var detail: String {
        switch self {
        case .meetings: "One Markdown file per meeting: tasks, minutes, decisions"
        case .flowNotes: "Scratchpad notes as Markdown"
        case .dictations: "One Markdown file per day"
        case .spaces: "Every item as Markdown, one folder per Space"
        case .tray: "Copies of the images and files on the shelf"
        case .clipboard: "Pinned text only. Passwords and private copies are never written"
        case .focus: "Monthly summaries of your Focus sessions"
        case .modes: "When each Mode ran and for how long"
        case .habits: "Your habits and streaks for the last 14 days"
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: "person.2.wave.2.fill"
        case .flowNotes: "note.text"
        case .dictations: "waveform"
        case .spaces: "square.stack.3d.up.fill"
        case .tray: "tray.full.fill"
        case .clipboard: "doc.on.clipboard"
        case .focus: "timer"
        case .modes: "circle.hexagongrid.fill"
        case .habits: "checkmark.circle.fill"
        }
    }

    /// Top-level folder in the SparkV folder ("" = the root, for Habits.md).
    var folder: String {
        switch self {
        case .meetings: "Meetings"
        case .flowNotes: "Notes"
        case .dictations: "Dictation"
        case .spaces: "Spaces"
        case .tray: "Tray"
        case .clipboard: "Clipboard"
        case .focus: "Focus"
        case .modes: "Modes"
        case .habits: ""
        }
    }

    /// Clipboard is off by default: pinned text can still be sensitive.
    static let defaults: Set<CloudSyncCategory> = Set(allCases).subtracting([.clipboard])
}

/// User choices, saved as JSON in Application Support/SparkV/CloudSync.
struct CloudSyncSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var isPaused = false
    var categories: Set<CloudSyncCategory> = CloudSyncCategory.defaults
    /// Meeting files include the full transcript.
    var includesTranscripts = true
    /// Spaces items carry a copy of their attachment (screenshot, file).
    var includesSpaceAttachments = true
    /// Import what is dropped into SparkV/Inbox (from the iPhone share sheet).
    var importsInbox = true
    /// A folder chosen instead of iCloud Drive (nil = iCloud Drive/SparkV).
    var customFolderPath: String?
    /// Identifies this Mac in the folder's owner file.
    var deviceID = UUID()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CloudSyncSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? d.isPaused
        // Unknown category names (from a newer build) are dropped, not fatal.
        if let raw = try c.decodeIfPresent([String].self, forKey: .categories) {
            categories = Set(raw.compactMap(CloudSyncCategory.init(rawValue:)))
        }
        includesTranscripts = try c.decodeIfPresent(Bool.self, forKey: .includesTranscripts) ?? d.includesTranscripts
        includesSpaceAttachments = try c.decodeIfPresent(Bool.self, forKey: .includesSpaceAttachments) ?? d.includesSpaceAttachments
        importsInbox = try c.decodeIfPresent(Bool.self, forKey: .importsInbox) ?? d.importsInbox
        customFolderPath = try c.decodeIfPresent(String.self, forKey: .customFolderPath)
        deviceID = try c.decodeIfPresent(UUID.self, forKey: .deviceID) ?? d.deviceID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(isPaused, forKey: .isPaused)
        try c.encode(categories.sorted().map(\.rawValue), forKey: .categories)
        try c.encode(includesTranscripts, forKey: .includesTranscripts)
        try c.encode(includesSpaceAttachments, forKey: .includesSpaceAttachments)
        try c.encode(importsInbox, forKey: .importsInbox)
        try c.encodeIfPresent(customFolderPath, forKey: .customFolderPath)
        try c.encode(deviceID, forKey: .deviceID)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, isPaused, categories, includesTranscripts, includesSpaceAttachments
        case importsInbox, customFolderPath, deviceID
    }
}

/// One file the mirror should contain.
struct CloudSyncFile: Sendable, Equatable {
    enum Payload: Sendable, Equatable {
        /// Rendered content (Markdown).
        case data(Data)
        /// A file copied as is (images, Tray files, Space attachments).
        case copy(URL)
    }

    /// Relative to the SparkV folder, "/"-separated, already sanitized.
    var path: String
    /// Stable identity across renames: "<category>:<id>[:part]".
    var sourceKey: String
    var payload: Payload

    static func markdown(_ path: String, key: String, _ text: String) -> CloudSyncFile {
        CloudSyncFile(path: path, sourceKey: key, payload: .data(Data(text.utf8)))
    }
}

/// What the mirror wrote last time, per file. Stored on this Mac (not in
/// iCloud Drive), one manifest per destination folder.
struct CloudSyncManifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var path: String
        var sourceKey: String
        /// SHA-256 of the content written.
        var hash: String
        /// Size and modification date of the destination right after the
        /// write: if they still match, the file was not touched since.
        var size: Int64
        var modified: Double
        /// For copies, "size:mtime" of the source, so an unchanged source is
        /// not re-hashed on every run.
        var sourceSignature: String?
    }

    /// Inbox files seen but not yet stable (still uploading).
    struct Sighting: Codable, Equatable, Sendable {
        var size: Int64
        var modified: Double
        var firstSeen: Date
    }

    var version = 1
    /// Keyed by `CloudSyncPaths.key(path)` (case- and normalization-insensitive).
    var entries: [String: Entry] = [:]
    /// Content hashes already imported from the Inbox, with the import date.
    var imported: [String: Date] = [:]
    var sightings: [String: Sighting] = [:]
}

/// What one run did.
struct CloudSyncReport: Sendable, Equatable {
    var written = 0
    var unchanged = 0
    var renamed = 0
    var trashed = 0
    /// Files edited outside SparkV, kept in SparkV/Conflicts before rewriting.
    var preserved = 0
    var imported = 0
    /// Removals held back because they looked like a data-loading failure.
    var heldRemovals = 0
    var skipped: [String] = []
    var errors: [String] = []
    /// A write failed with a permission error (macOS privacy).
    var permissionDenied = false
    var finishedAt = Date()

    var changedCount: Int { written + renamed + trashed + preserved + imported }
}

/// What the status view shows.
enum CloudSyncStatus: Equatable, Sendable {
    case off
    case idle
    case syncing
    case paused(String?)
    /// The user has to do something (iCloud Drive off, folder gone, privacy).
    case attention(String)
    case failed(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .idle: "Up to date"
        case .syncing: "Syncing…"
        case .paused(let reason): reason ?? "Paused"
        case .attention(let message): message
        case .failed(let message): message
        }
    }
}
