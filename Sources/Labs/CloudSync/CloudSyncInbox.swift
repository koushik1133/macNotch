import AppKit
import Foundation
import UniformTypeIdentifiers

/// The two-way part: files saved into iCloud Drive › SparkV › Inbox (for
/// example from the iPhone share sheet with "Save to Files") come into
/// SparkV. Text and Markdown become Spaces Inbox notes, links become Spaces
/// links, images and other files go on the Tray (and into Spaces).
///
/// An imported file is never deleted: it moves to Inbox/Imported/<day>/.
/// SparkV keeps its own copy in Application Support (so Tray and Spaces
/// references stay valid even when iCloud evicts the file).
enum CloudSyncInbox {
    enum Kind: String, Sendable, Equatable {
        case text, link, image, file
    }

    struct Arrival: Sendable, Equatable {
        var name: String
        var kind: Kind
        /// SparkV's own copy (nil for text and links, which are read inline).
        var localCopy: URL?
        /// Where the original went in iCloud Drive.
        var archivedAt: URL?
        var title: String
        var text: String?
        var link: URL?
        var hash: String
        /// Already imported once (same content): archived, not imported again.
        var isDuplicate: Bool
    }

    struct Result: Sendable {
        var arrivals: [Arrival] = []
        var skipped: [String] = []
        var errors: [String] = []
        /// Files still arriving; scan again shortly.
        var pending = 0
    }

    static let maxFileBytes: Int64 = 200 * 1024 * 1024
    static let maxTextBytes: Int64 = 2 * 1024 * 1024
    /// A file must keep the same size and date this long before import.
    static let settleTime: TimeInterval = 2
    static let importedHistoryLimit = 5000

    static func inboxURL(in root: URL) -> URL {
        root.appendingPathComponent(CloudSyncPaths.inbox, isDirectory: true)
    }

    /// Creates the Inbox (and its Imported folder) so it shows on the iPhone.
    static func prepare(root: URL) throws {
        try FileManager.default.createDirectory(
            at: inboxURL(in: root).appendingPathComponent(CloudSyncPaths.imported, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// Finds settled files, copies them into `receivedDirectory`, archives
    /// the originals and updates `manifest` (sightings and imported hashes).
    static func collect(root: URL, receivedDirectory: URL, manifest: inout CloudSyncManifest,
                        now: Date = Date(), calendar: Calendar = .current) -> Result {
        var result = Result()
        let fm = FileManager.default
        let inbox = inboxURL(in: root)
        do { try prepare(root: root) } catch {
            result.errors.append("Can't create the Inbox folder: \(error.localizedDescription)")
            return result
        }
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else {
            result.errors.append("Can't read the Inbox folder")
            return result
        }

        var present = Set<String>()
        for name in names.sorted() {
            if let real = CloudSyncPaths.realName(ofPlaceholder: name) {
                // Evicted / not yet downloaded: ask iCloud for it.
                try? fm.startDownloadingUbiquitousItem(at: inbox.appendingPathComponent(real))
                result.pending += 1
                present.insert(real)
                continue
            }
            if name.hasPrefix(".") || name.lowercased() == CloudSyncPaths.imported.lowercased() { continue }
            let url = inbox.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // Bundles like .rtfd or .pages are not imported, nor are folders.
                result.skipped.append("Inbox: “\(name)” is a folder; drop the files themselves")
                continue
            }
            present.insert(name)
            guard let stat = CloudSyncEngine.stat(url) else { continue }
            if stat.size > maxFileBytes {
                result.skipped.append("Inbox: “\(name)” is larger than 200 MB")
                continue
            }

            // Wait until the file stops changing (an upload still in progress).
            let previous = manifest.sightings[name]
            let settled = previous.map {
                $0.size == stat.size && abs($0.modified - stat.modified) < 0.001
                    && now.timeIntervalSince($0.firstSeen) >= settleTime
            } ?? false
            let modifiedAt = Date(timeIntervalSinceReferenceDate: stat.modified)
            guard settled, stat.size > 0, now.timeIntervalSince(modifiedAt) >= settleTime else {
                if previous == nil || previous?.size != stat.size || abs((previous?.modified ?? 0) - stat.modified) >= 0.001 {
                    manifest.sightings[name] = .init(size: stat.size, modified: stat.modified, firstSeen: now)
                }
                if stat.size > 0 { result.pending += 1 }
                continue
            }

            guard let hash = CloudSyncEngine.sha256(fileAt: url) else {
                result.skipped.append("Inbox: can't read “\(name)” yet")
                result.pending += 1
                continue
            }
            let kind = kind(of: url)
            var arrival = Arrival(name: name, kind: kind, localCopy: nil, archivedAt: nil,
                                  title: (name as NSString).deletingPathExtension, text: nil, link: nil,
                                  hash: hash, isDuplicate: manifest.imported[hash] != nil)
            if !arrival.isDuplicate {
                // Text that can't be read as a note (over 2 MB, binary) and a
                // link file without a web address still arrive, as a file on
                // the Tray. Leaving them in the Inbox would re-hash them on
                // every scan and never import them.
                if kind == .text {
                    if stat.size <= maxTextBytes, let text = readText(url) {
                        arrival.text = text
                        arrival.title = title(of: text) ?? arrival.title
                    } else {
                        arrival.kind = .file
                    }
                } else if kind == .link {
                    if let link = readLink(url) { arrival.link = link } else { arrival.kind = .file }
                }
                switch arrival.kind {
                case .text, .link:
                    break
                case .image, .file:
                    do {
                        let folder = receivedDirectory.appendingPathComponent(String(hash.prefix(16)), isDirectory: true)
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                        let copy = folder.appendingPathComponent(name)
                        if !fm.fileExists(atPath: copy.path) { try fm.copyItem(at: url, to: copy) }
                        arrival.localCopy = copy
                    } catch {
                        result.errors.append("Inbox: can't copy “\(name)”: \(error.localizedDescription)")
                        continue
                    }
                }
            }

            // Archive the original (never delete it).
            do {
                let folder = inbox.appendingPathComponent(CloudSyncPaths.imported, isDirectory: true)
                    .appendingPathComponent(CloudSyncPaths.day(now, calendar: calendar), isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = CloudSyncPaths.freeURL(in: folder, name: name)
                try CloudSyncEngine(root: root, now: now, calendar: calendar).move(url, to: target)
                arrival.archivedAt = target
            } catch {
                // Not archived means it would be imported again next scan:
                // drop the arrival so nothing is imported twice.
                if let copy = arrival.localCopy { try? fm.removeItem(at: copy.deletingLastPathComponent()) }
                result.errors.append("Inbox: can't move “\(name)” to Imported: \(error.localizedDescription)")
                continue
            }
            manifest.sightings[name] = nil
            manifest.imported[hash] = now
            result.arrivals.append(arrival)
        }

        // Forget files that left the Inbox, and very old import history.
        manifest.sightings = manifest.sightings.filter { present.contains($0.key) }
        if manifest.imported.count > importedHistoryLimit {
            let keep = manifest.imported.sorted { $0.value > $1.value }.prefix(importedHistoryLimit)
            manifest.imported = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return result
    }

    // MARK: - Reading

    static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "txt", "text", "rtf"].contains(ext) { return .text }
        if ["webloc", "url"].contains(ext) { return .link }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .plainText) { return .text }
        }
        return .file
    }

    /// UTF-8 (with or without BOM), UTF-16, or Latin-1; RTF as plain text.
    static func readText(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "rtf" {
            let attributed = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                     documentAttributes: nil)
            return attributed?.string.trimmingCharacters(in: .whitespacesAndNewlines).cloudSyncNonEmpty
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: .isoLatin1)
        }
        guard var clean = text else { return nil }
        if clean.hasPrefix("\u{FEFF}") { clean.removeFirst() }
        if clean.contains("\u{0}") { return nil } // binary renamed to .txt
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).cloudSyncNonEmpty
    }

    /// The first Markdown heading or non-empty line, shortened.
    static func title(of text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            var t = line.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(80)) }
        }
        return nil
    }

    /// Safari/Finder .webloc (plist) or Windows .url ("URL=…").
    static func readLink(_ url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let string = plist["URL"] as? String {
            return webURL(string)
        }
        if let text = String(data: data, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("URL=") {
                return webURL(String(line.dropFirst(4)))
            }
        }
        return nil
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }
}

private extension String {
    var cloudSyncNonEmpty: String? { isEmpty ? nil : self }
}
