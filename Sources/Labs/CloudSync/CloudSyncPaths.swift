import Foundation

/// Folder names, file-name rules and where the mirror lives.
enum CloudSyncPaths {
    /// Folders SparkV manages itself; rendered content never lands in them.
    static let inbox = "Inbox"
    static let imported = "Imported"
    static let conflicts = "Conflicts"
    static let trash = ".trash"
    static let temp = ".sparkv-tmp"
    static let ownerFile = ".sparkv-owner.json"
    static let readme = "README.md"

    /// Top-level names rendered files may not use (lowercased).
    static let reservedTopLevel: Set<String> = Set([inbox, conflicts, trash, temp, ownerFile].map { $0.lowercased() })

    /// ~/Library/Mobile Documents/com~apple~CloudDocs, the "iCloud Drive"
    /// folder of the Files app. Present only when iCloud Drive is on.
    static var iCloudDriveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Local state: settings, manifests, received Inbox files, Mode log.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/CloudSync", isDirectory: true)
    }

    // MARK: Names

    /// Lookup key for a relative path: APFS and iCloud compare names
    /// case-insensitively and ignore Unicode normalization.
    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A single path component safe for APFS, iCloud Drive and the iPhone
    /// Files app: no "/", ":", control characters or leading dots, no
    /// trailing dots/spaces, at most `maxLength` characters, never empty.
    static func component(_ raw: String, fallback: String = "Untitled", maxLength: Int = 80) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        var out = ""
        var lastWasSpace = false
        for scalar in firstLine.precomposedStringWithCanonicalMapping.unicodeScalars {
            let bad = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || "/:\\<>\"|?*".unicodeScalars.contains(scalar)
                || (0xFE00...0xFE0F).contains(scalar.value) // variation selectors
            let isSpace = bad || CharacterSet.whitespaces.contains(scalar)
            if isSpace {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        // Markdown headings and list markers make poor file names.
        while let first = out.first, "#*-_>. ".contains(first) { out.removeFirst() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
        }
        while let last = out.last, last == " " || last == "." { out.removeLast() }
        // iCloud limits names to 255 UTF-8 bytes; leave room for " 12.md".
        while out.utf8.count > 200 { out.removeLast() }
        return out.isEmpty ? fallback : out
    }

    /// "2026-10-22", "2026-10", "1430": fixed formats, independent of locale.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func month(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return day(date, calendar: calendar) + String(format: " %02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// "Notes/Plan.md" -> "Notes/Plan 2.md" (number goes before the extension).
    static func numbered(_ path: String, _ n: Int) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? path : ns.deletingPathExtension
        return ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
    }

    /// A destination in `directory` named like `name` that does not exist yet.
    static func freeURL(in directory: URL, name: String, fileManager: FileManager = .default) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while exists(candidate, fileManager: fileManager) {
            candidate = directory.appendingPathComponent(numbered(name, n))
            n += 1
        }
        return candidate
    }

    /// True for a file or folder, including an evicted iCloud file that is
    /// only an old-style ".Name.icloud" placeholder.
    static func exists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return fileManager.fileExists(atPath: placeholder(for: url).path)
    }

    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// "Report.pdf" for ".Report.pdf.icloud", nil for anything else.
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    /// True when `child` is `root` or inside it (no "../" escapes).
    static func isInside(_ child: URL, _ root: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        return c == r || c.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

// MARK: - Destination folder

/// Where the mirror goes and whether it can be used right now.
enum CloudSyncLocation: Equatable, Sendable {
    case ready(URL)
    /// iCloud Drive is off on this Mac (no CloudDocs folder).
    case iCloudDriveOff
    /// The chosen folder (or the drive it was on) is gone.
    case folderMissing(String)

    /// The SparkV folder for `settings`. Never creates the iCloud Drive or
    /// custom parent folder: if it is missing, writing there is pointless.
    static func resolve(_ settings: CloudSyncSettings, fileManager: FileManager = .default,
                        iCloudRoot: URL = CloudSyncPaths.iCloudDriveRoot) -> CloudSyncLocation {
        if let custom = settings.customFolderPath, !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return .folderMissing(custom)
            }
            // Never mix with the user's own files: write into a SparkV
            // subfolder unless they picked a folder named SparkV.
            return .ready(url.lastPathComponent.lowercased() == "sparkv" ? url : url.appendingPathComponent("SparkV", isDirectory: true))
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: iCloudRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return .iCloudDriveOff
        }
        return .ready(iCloudRoot.appendingPathComponent("SparkV", isDirectory: true))
    }
}

/// Marks which Mac writes a SparkV folder. A second Mac signed in to the same
/// iCloud account would otherwise overwrite the first one's files (and each
/// would keep "preserving" the other's versions as conflicts), so it writes
/// to a subfolder named after itself instead.
struct CloudSyncOwner: Codable, Equatable, Sendable {
    var deviceID: UUID
    var deviceName: String
    var claimedAt: Date

    /// The owner file is in iCloud Drive but not downloaded yet (a fresh Mac,
    /// or an evicted file). Claiming now would take another Mac's folder, so
    /// the run waits and retries.
    struct NotDownloaded: LocalizedError {
        var folder: String
        var errorDescription: String? { "Waiting for iCloud Drive to download “\(folder)”. Sync will retry shortly." }
    }

    private enum Claim { case mine, other, free }

    /// The folder this Mac writes into, claiming `base` when nobody has.
    /// Otherwise `base/<Mac name>`, then `base/<Mac name> 2`… (two Macs can
    /// share a name), whichever is free or already this Mac's.
    static func destination(base: URL, deviceID: UUID, deviceName: String,
                            fileManager: FileManager = .default, now: Date = Date()) throws -> URL {
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        var name = CloudSyncPaths.component(deviceName, fallback: "Mac")
        // A Mac called "Notes" must not land inside the first Mac's Notes folder.
        let taken = Set(CloudSyncCategory.allCases.map { $0.folder.lowercased() })
            .union(CloudSyncPaths.reservedTopLevel).union([CloudSyncPaths.readme.lowercased(), ""])
        if taken.contains(name.lowercased()) { name += " (Mac)" }
        for n in 1...20 {
            let folder = n == 1 ? base
                : base.appendingPathComponent(n == 2 ? name : "\(name) \(n - 1)", isDirectory: true)
            switch try claim(folder, deviceID: deviceID, fileManager: fileManager) {
            case .mine:
                return folder
            case .other:
                continue
            case .free:
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let mine = CloudSyncOwner(deviceID: deviceID, deviceName: deviceName, claimedAt: now)
                try JSONEncoder.cloudSync.encode(mine)
                    .write(to: folder.appendingPathComponent(CloudSyncPaths.ownerFile), options: .atomic)
                return folder
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "Too many Macs share the SparkV folder"])
    }

    private static func claim(_ folder: URL, deviceID: UUID, fileManager: FileManager) throws -> Claim {
        let file = folder.appendingPathComponent(CloudSyncPaths.ownerFile)
        let placeholder = CloudSyncPaths.placeholder(for: file)
        if !fileManager.fileExists(atPath: file.path) {
            guard fileManager.fileExists(atPath: placeholder.path) else { return .free }
            try? fileManager.startDownloadingUbiquitousItem(at: file)
            throw NotDownloaded(folder: folder.lastPathComponent)
        }
        guard let data = try? Data(contentsOf: file) else {
            // Present but unreadable: a dataless file iCloud could not fetch.
            try? fileManager.startDownloadingUbiquitousItem(at: file)
            throw NotDownloaded(folder: folder.lastPathComponent)
        }
        // A damaged owner file counts as someone else's: never fight over it.
        guard let owner = try? JSONDecoder.cloudSync.decode(CloudSyncOwner.self, from: data) else { return .other }
        return owner.deviceID == deviceID ? .mine : .other
    }
}

extension JSONEncoder {
    static var cloudSync: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var cloudSync: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
