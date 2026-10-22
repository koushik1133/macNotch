import Darwin
import Foundation

// How browsers lay out in-progress downloads on macOS, and the metadata they
// leave on finished files. Pure functions over the file system, safe to call
// from any thread.
//
// - Safari: a `name.ext.download` package holding `Info.plist`
//   (DownloadEntryURL, DownloadEntryProgressTotalToLoad,
//   DownloadEntryProgressBytesSoFar…) and the data file `name.ext`. On
//   completion the data file is moved out next to the package and the
//   package is removed, so the data file keeps its inode.
// - Chromium (Chrome, Edge, Brave, Arc, Vivaldi): `name.ext.crdownload`
//   (older builds: `Unconfirmed 123456.crdownload`), renamed in place when
//   done. Opera uses `.opdownload`.
// - Firefox: `name.ext.part` plus a zero-byte placeholder `name.ext`; the
//   `.part` file is renamed over the placeholder when done.
// - All of them publish an NSProgress with NSProgressFileURLKey (what Finder
//   and the Dock draw), which `DownloadsProgressSubscriber` listens to.
// - Finished files carry `com.apple.metadata:kMDItemWhereFroms` (binary
//   plist array: [file URL, referring page]) and `com.apple.quarantine`
//   ("flags;hex time;agent name;UUID").

/// Device + inode: survives the rename/move that finishes a download.
struct DownloadFileID: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// lstat result for one path.
struct DownloadFileStat: Sendable, Equatable {
    let id: DownloadFileID
    let size: Int64
    let isDirectory: Bool
    let isRegularFile: Bool
    let modified: Date

    static func of(_ path: String) -> DownloadFileStat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return DownloadFileStat(
            id: DownloadFileID(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino)),
            size: Int64(info.st_size),
            isDirectory: type == S_IFDIR,
            isRegularFile: type == S_IFREG,
            modified: modified
        )
    }
}

/// An in-progress download found on disk.
struct DownloadPartialInfo: Sendable, Equatable {
    /// The `.crdownload` / `.part` file or the Safari `.download` package.
    let partialURL: URL
    /// The file whose size grows (the partial itself, or the data file inside
    /// Safari's package; nil until Safari creates it).
    let dataURL: URL?
    /// Name the file will have when done.
    let finalName: String
    let browser: DownloadBrowser
    /// Total and received bytes and the source from Safari's Info.plist.
    var plistTotal: Int64?
    var plistReceived: Int64?
    var plistSourceURL: String?
}

enum DownloadPartials {
    static let safariExtension = "download"
    static let chromiumExtensions: Set<String> = ["crdownload", "opdownload"]
    static let firefoxExtension = "part"
    /// Other common partial suffixes (old Edge, Transmit/FileZilla style).
    static let genericExtensions: Set<String> = ["partial", "filepart"]

    /// True for names that are partial downloads, whatever the browser.
    static func isPartialName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == safariExtension || ext == firefoxExtension
            || chromiumExtensions.contains(ext) || genericExtensions.contains(ext)
    }

    /// Hidden files, Finder metadata and Office lock files are never downloads.
    static func isIgnoredName(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("~$") || name == "Icon\r" || name.hasSuffix(".localized")
    }

    /// Name without the partial suffix ("a.pdf.crdownload" → "a.pdf").
    static func finalName(forPartial name: String) -> String {
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? name : stripped
    }

    /// Describes `url` when it's a partial download, else nil. `stat` is the
    /// entry's lstat (passed in to avoid a second system call).
    static func inspect(_ url: URL, stat: DownloadFileStat) -> DownloadPartialInfo? {
        let name = url.lastPathComponent
        guard !isIgnoredName(name), isPartialName(name) else { return nil }
        let ext = url.pathExtension.lowercased()
        let finalName = finalName(forPartial: name)

        if ext == safariExtension {
            // Safari's package; a plain file named *.download is generic.
            guard stat.isDirectory else {
                return DownloadPartialInfo(partialURL: url, dataURL: url, finalName: finalName, browser: .other)
            }
            var info = DownloadPartialInfo(partialURL: url, dataURL: safariDataFile(in: url, finalName: finalName),
                                           finalName: finalName, browser: .safari)
            if let plist = safariInfo(bundle: url) {
                info.plistTotal = plist.total
                info.plistReceived = plist.received
                info.plistSourceURL = plist.sourceURL
            }
            return info
        }
        guard stat.isRegularFile else { return nil }
        let browser: DownloadBrowser = chromiumExtensions.contains(ext) ? .chromium : (ext == firefoxExtension ? .firefox : .other)
        return DownloadPartialInfo(partialURL: url, dataURL: url, finalName: finalName, browser: browser)
    }

    /// Safari's data file: the entry named like the final file, else the
    /// largest regular file that isn't Info.plist.
    static func safariDataFile(in bundle: URL, finalName: String) -> URL? {
        let named = bundle.appendingPathComponent(finalName)
        if let s = DownloadFileStat.of(named.path), s.isRegularFile { return named }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: bundle.path) else { return nil }
        var best: (url: URL, size: Int64)?
        for entry in names where entry != "Info.plist" && !entry.hasPrefix(".") {
            let url = bundle.appendingPathComponent(entry)
            guard let s = DownloadFileStat.of(url.path), s.isRegularFile else { continue }
            if best == nil || s.size > best!.size { best = (url, s.size) }
        }
        return best?.url
    }

    struct SafariPlist: Equatable, Sendable {
        var total: Int64?
        var received: Int64?
        var sourceURL: String?
    }

    /// Reads the keys Safari writes into a `.download` package's Info.plist.
    static func safariInfo(bundle: URL) -> SafariPlist? {
        let url = bundle.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func int64(_ key: String) -> Int64? {
            if let n = plist[key] as? NSNumber { return n.int64Value > 0 ? n.int64Value : nil }
            if let s = plist[key] as? String, let n = Int64(s) { return n > 0 ? n : nil }
            return nil
        }
        return SafariPlist(
            total: int64("DownloadEntryProgressTotalToLoad"),
            received: int64("DownloadEntryProgressBytesSoFar"),
            sourceURL: plist["DownloadEntryURL"] as? String
        )
    }

    /// Firefox's zero-byte placeholder next to `name.part`.
    static func isFirefoxPlaceholder(_ url: URL, stat: DownloadFileStat) -> Bool {
        guard stat.size == 0 else { return false }
        return FileManager.default.fileExists(atPath: url.path + ".part")
    }
}

/// Download provenance from extended attributes.
enum DownloadMetadata {
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"
    static let quarantineAttribute = "com.apple.quarantine"

    static func attribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length > 0, length < 1_000_000 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { buffer in
                getxattr(path, name, buffer.baseAddress, length, 0, XATTR_NOFOLLOW)
            }
            return read == length ? data : nil
        }
    }

    /// kMDItemWhereFroms: [download URL, referring page], either may be missing.
    static func whereFroms(_ url: URL) -> [String] {
        guard let data = attribute(whereFromsAttribute, of: url) else { return [] }
        if let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            return list.filter { !$0.isEmpty }
        }
        if let single = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String {
            return [single]
        }
        return []
    }

    /// Agent name from com.apple.quarantine ("0083;6512ab34;Safari;UUID").
    static func quarantineAgent(_ url: URL) -> String? {
        guard let data = attribute(quarantineAttribute, of: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let agent = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty ? nil : agent
    }

    /// Writes kMDItemWhereFroms the way browsers do (tests and fixtures).
    @discardableResult
    static func setWhereFroms(_ values: [String], on url: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return false }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return data.withUnsafeBytes { setxattr(path, whereFromsAttribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) } == 0
        }
    }
}
