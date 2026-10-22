import Foundation

/// A saved moment in a track: "the drop at 2:41", "chapter 3 starts here".
struct MediaBookmark: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// `MediaEngine.trackKey(app:title:artist:)` of the track.
    var trackKey: String
    var title: String
    var artist: String
    var appBundleID: String
    /// Seconds into the track.
    var position: TimeInterval
    var note: String
    var createdAt: Date
}

/// Bookmarks for every track, persisted as JSON in
/// ~/Library/Application Support/SparkV/MediaBookmarks.json.
///
/// Shared (`MediaBookmarkStore.shared`) so the media views need no extra
/// environment wiring. Writes are atomic; a file that fails to decode is set
/// aside (renamed, never deleted) before the store starts a new one.
@MainActor
final class MediaBookmarkStore: ObservableObject {
    static let shared = MediaBookmarkStore()

    /// Two bookmarks closer than this on one track are the same bookmark.
    nonisolated static let mergeDistance: TimeInterval = 1.5
    /// Per-track cap, so a stuck key can't grow the file without bound.
    nonisolated static let maxPerTrack = 100

    @Published private(set) var bookmarks: [MediaBookmark] = []
    let fileURL: URL

    private struct FileFormat: Codable {
        var version: Int
        var bookmarks: [MediaBookmark]
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV", isDirectory: true)
            .appendingPathComponent("MediaBookmarks.json")
    }

    // MARK: Queries

    /// Bookmarks of one track, earliest first.
    func bookmarks(forTrack key: String?) -> [MediaBookmark] {
        guard let key else { return [] }
        return bookmarks.filter { $0.trackKey == key }.sorted { $0.position < $1.position }
    }

    /// The bookmark at `position` on the track, if one is within `tolerance`.
    func bookmark(near position: TimeInterval, track key: String?, tolerance: TimeInterval = mergeDistance) -> MediaBookmark? {
        bookmarks(forTrack: key)
            .filter { abs($0.position - position) <= tolerance }
            .min { abs($0.position - position) < abs($1.position - position) }
    }

    // MARK: Changes

    /// Saves a bookmark. One already within `mergeDistance` is updated
    /// instead (its note replaced when a new one is given), so a double click
    /// doesn't create twins.
    @discardableResult
    func add(
        trackKey: String,
        title: String,
        artist: String,
        appBundleID: String,
        position: TimeInterval,
        note: String = ""
    ) -> MediaBookmark? {
        guard position.isFinite, position >= 0 else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = bookmark(near: position, track: trackKey),
           let index = bookmarks.firstIndex(where: { $0.id == existing.id }) {
            if !trimmed.isEmpty { bookmarks[index].note = trimmed }
            save()
            return bookmarks[index]
        }
        guard bookmarks(forTrack: trackKey).count < Self.maxPerTrack else { return nil }

        let bookmark = MediaBookmark(
            id: UUID(),
            trackKey: trackKey,
            title: title,
            artist: artist,
            appBundleID: appBundleID,
            position: position,
            note: trimmed,
            createdAt: Date()
        )
        bookmarks.append(bookmark)
        save()
        return bookmark
    }

    func updateNote(_ id: UUID, to note: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func remove(_ id: UUID) {
        let before = bookmarks.count
        bookmarks.removeAll { $0.id == id }
        if bookmarks.count != before { save() }
    }

    func removeAll(forTrack key: String) {
        let before = bookmarks.count
        bookmarks.removeAll { $0.trackKey == key }
        if bookmarks.count != before { save() }
    }

    // MARK: Persistence

    private func load() {
        let files = FileManager.default
        guard files.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            bookmarks = try decoder.decode(FileFormat.self, from: data).bookmarks
        } catch {
            // Keep the unreadable file for the user; start a fresh one.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? files.moveItem(at: fileURL, to: aside)
            AppLog.log("Media: bookmarks file unreadable (\(error.localizedDescription)); kept it as \(aside.lastPathComponent)")
            bookmarks = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(FileFormat(version: 1, bookmarks: bookmarks))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.log("Media: could not save bookmarks: \(error.localizedDescription)")
        }
    }
}
