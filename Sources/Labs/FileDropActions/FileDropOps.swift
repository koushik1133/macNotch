import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File operations behind the strip's actions. Everything here is
/// synchronous and nonisolated: the controller runs it in `Task.detached`.
/// Nothing here ever deletes a user's file: compress and zip write new files
/// next to the originals, rename moves within the same folder, and Undo of a
/// created file moves it to the Trash.
enum FileDropOps {
    // MARK: Locations

    /// Tests point this at a scratch folder; nil = Application Support.
    nonisolated(unsafe) static var rootOverride: URL?

    /// ~/Library/Application Support/SparkV/FileDrop
    static var outputRoot: URL {
        if let rootOverride { return rootOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/FileDrop", isDirectory: true)
    }

    /// Where an output for `item` goes: next to the original (what Finder's
    /// Compress does) when that folder is writable and is a real place,
    /// otherwise a fresh `FileDrop/<date> <label>/` folder.
    static func outputDirectory(for item: FileDropItem, label: String) throws -> URL {
        let parent = item.url.deletingLastPathComponent()
        if !item.isStaged, !isTemporary(parent), FileManager.default.isWritableFile(atPath: parent.path) {
            return parent
        }
        return try makeJobDirectory(label)
    }

    static func makeJobDirectory(_ label: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(formatter.string(from: Date())) \(label)"
        var url = outputRoot.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputRoot.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return path.hasPrefix(temp) || path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
    }

    /// `<dir>/<name>.<ext>` (no dot when `ext` is empty), adding " 2", " 3"…
    /// when taken. `ignoring` is a file that may keep its own name (a
    /// rename that only changes case).
    static func uniqueURL(in directory: URL, name: String, ext: String, ignoring: URL? = nil) -> URL {
        func make(_ base: String) -> URL {
            let url = directory.appendingPathComponent(base)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var url = make(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path),
              url.path.lowercased() != ignoring?.path.lowercased() {
            url = make("\(name) \(suffix)")
            suffix += 1
        }
        return url
    }

    static func fileSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isPackageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0) }
        // Folders and packages: add up their files (bounded, so a huge tree
        // can't stall the strip).
        var total: Int64 = 0
        var visited = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [])
        while let file = enumerator?.nextObject() as? URL, visited < 20_000 {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            visited += 1
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Rename

    /// Renames in place, keeping the extension. Returns the new URL (the
    /// same URL when the name didn't change).
    static func rename(_ url: URL, toBaseName rawName: String) throws -> URL {
        let name = cleanTypedName(rawName)
        guard !name.isEmpty else { throw FileDropError.emptyName }
        let directory = url.deletingLastPathComponent()
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
        let ext = isFolder ? "" : url.pathExtension
        let target = uniqueURL(in: directory, name: name, ext: ext, ignoring: url)
        if target.path == url.path { return url }
        let fm = FileManager.default
        if target.path.lowercased() == url.path.lowercased() {
            // Case-only change on a case-insensitive volume: go through a
            // temporary name, since the "target" already exists.
            let hop = directory.appendingPathComponent(".sparkv-rename-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: hop)
            do { try fm.moveItem(at: hop, to: target) } catch {
                try? fm.moveItem(at: hop, to: url)
                throw error
            }
        } else {
            try fm.moveItem(at: url, to: target)
        }
        return target
    }

    /// Puts a renamed file back. Refuses to overwrite anything that took the
    /// old name in the meantime.
    static func undoRename(_ rename: FileDropRename) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rename.to.path) else { throw FileDropError.missing(rename.to.lastPathComponent) }
        if rename.from.path.lowercased() == rename.to.path.lowercased() {
            _ = try self.rename(rename.to, toBaseName: rename.from.deletingPathExtension().lastPathComponent)
            return
        }
        guard !fm.fileExists(atPath: rename.from.path) else { throw FileDropError.nameTaken(rename.from.lastPathComponent) }
        try fm.moveItem(at: rename.to, to: rename.from)
    }

    /// What the user typed, made safe for a file name (no slashes or colons,
    /// no leading dot, no trailing extension they typed out of habit).
    static func cleanTypedName(_ raw: String, extension ext: String? = nil) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if let ext, !ext.isEmpty, name.lowercased().hasSuffix("." + ext.lowercased()) {
            name = String(name.dropLast(ext.count + 1))
        }
        return String(name.prefix(180)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Compress

    struct Compressed: Sendable {
        let output: URL?
        let before: Int64
        let after: Int64
    }

    /// Re-encodes an image the way image optimizers do: same format for
    /// JPEG/HEIC (quality 0.72), opaque PNG/TIFF/BMP/WebP → JPEG, PNG with
    /// real transparency stays PNG; anything over 3072 px on its longest side
    /// is scaled down. Metadata (GPS included) is dropped. Returns a nil
    /// output when the copy isn't smaller.
    static func compressImage(_ item: FileDropItem, in directory: URL) throws -> Compressed {
        let before = fileSize(item.url)
        let ext = item.url.pathExtension.lowercased()
        // Animated GIFs/PNGs and vector images would lose their animation or
        // become pixels: leave them as they are (a .zip is still offered).
        if ["svg", "svgz", "pdf", "eps", "ai"].contains(ext) { return Compressed(output: nil, before: before, after: before) }
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil), CGImageSourceGetCount(source) > 1,
           ["gif", "png", "apng", "webp"].contains(ext) {
            return Compressed(output: nil, before: before, after: before)
        }
        let loaded = try ConverterImages.loadUpright(item.url, maxPixelSize: 3072)
        let image = loaded.image
        let transparent = hasVisibleTransparency(image)
        let format: ConverterImageFormat
        switch ext {
        case "jpg", "jpeg": format = .jpg
        case "heic", "heif": format = ConverterImageFormat.writable.contains(.heic) ? .heic : .jpg
        default: format = transparent ? .png : .jpg
        }
        let quality = format == .heic ? 0.6 : 0.72
        let out = uniqueURL(in: directory, name: "\(item.baseName)-compressed", ext: format.fileExtension)
        try ConverterImages.write(image, to: out, format: format, quality: quality)
        let after = fileSize(out)
        guard after > 0, after < before else {
            try? FileManager.default.removeItem(at: out) // our own scratch copy
            return Compressed(output: nil, before: before, after: before)
        }
        return Compressed(output: out, before: before, after: after)
    }

    /// True when the image has an alpha channel and actually uses it
    /// (sampled on a small copy), so opaque screenshots can go to JPEG.
    static func hasVisibleTransparency(_ image: CGImage) -> Bool {
        guard ConverterImages.hasAlpha(image) else { return false }
        let side = 128
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return true }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for index in stride(from: 3, to: side * side * 4, by: 4) where pixels[index] < 250 {
            return true
        }
        return false
    }

    /// PDFs through the converter's Compress (Quartz filter or PDFKit, the
    /// smaller wins). Nil output when it couldn't be made smaller.
    static func compressPDF(_ item: FileDropItem, in directory: URL) throws -> Compressed {
        let before = fileSize(item.url)
        let output = try ConverterEngine.run(.compress, inputs: [item.url], options: ConverterOptions(), in: directory, progress: { _ in })
        guard let file = output.files.first,
              file.standardizedFileURL.path != item.url.standardizedFileURL.path
        else { return Compressed(output: nil, before: before, after: before) }
        let after = fileSize(file)
        guard after < before else {
            // The converter keeps an identical copy when nothing shrank; it's ours.
            try? FileManager.default.removeItem(at: file)
            return Compressed(output: nil, before: before, after: before)
        }
        return Compressed(output: file, before: before, after: after)
    }

    /// A .zip the way Finder's Compress makes one (`ditto -c -k
    /// --keepParent`, Finder's naming), minus the Mac-only metadata: one item
    /// → "<name>.zip" next to it, several → "Archive.zip" with the items at
    /// its root.
    static func zip(_ items: [FileDropItem], in directory: URL) throws -> URL {
        guard let first = items.first else { throw FileDropError.nothingToDo }
        let fm = FileManager.default
        if items.count == 1 {
            // Finder keeps the whole name: "Report.pdf" → "Report.pdf.zip".
            let out = uniqueURL(in: directory, name: first.name, ext: "zip")
            try runTool("/usr/bin/ditto", ["-c", "-k"] + zipFlags + ["--keepParent", first.url.path, out.path])
            return out
        }
        // ditto archives one source, so the items are cloned (APFS: instant,
        // no extra space) into a scratch folder that is archived as a whole.
        let scratch = fm.temporaryDirectory.appendingPathComponent("SparkV-FileDrop-\(UUID().uuidString)", isDirectory: true)
        let staging = scratch.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        for item in items {
            let target = uniqueURL(in: staging, name: item.baseName.isEmpty ? item.name : item.baseName, ext: item.kind == .folder ? "" : item.fileExtension)
            try fm.copyItem(at: item.url, to: target)
        }
        let out = uniqueURL(in: directory, name: "Archive", ext: "zip")
        try runTool("/usr/bin/ditto", ["-c", "-k"] + zipFlags + [staging.path, out.path])
        return out
    }

    /// Clean, cross-platform archives (what Keka/BetterZip call "exclude Mac
    /// resource forks"): no __MACOSX folder, no quarantine or extended
    /// attributes, so the zip opens tidily on Windows and Linux too.
    static let zipFlags = ["--norsrc", "--noextattr", "--noqtn", "--noacl"]

    /// Lists a zip's entries (used by the tests and to sanity-check output).
    static func zipEntries(_ url: URL) -> [String] {
        guard let data = try? runTool("/usr/bin/zipinfo", ["-1", url.path]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @discardableResult
    static func runTool(_ path: String, _ arguments: [String]) throws -> Data {
        do {
            return try ConverterEngine.runTool(path, arguments)
        } catch let error as ConverterError {
            throw FileDropError.tool(error.localizedDescription)
        }
    }

    /// Undo for created files: to the Trash (recoverable), never deleted.
    static func trash(_ urls: [URL]) -> [URL] {
        var failed: [URL] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                if let trashOverride {
                    try trashOverride(url)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            } catch { failed.append(url) }
        }
        return failed
    }

    /// Tests move "trashed" files into a scratch folder instead of the
    /// user's Trash.
    nonisolated(unsafe) static var trashOverride: ((URL) throws -> Void)?
}

enum FileDropError: LocalizedError, Sendable, Equatable {
    case emptyName
    case missing(String)
    case nameTaken(String)
    case nothingToDo
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Type a name first"
        case .missing(let name): "\(name) is gone"
        case .nameTaken(let name): "Something else is called \(name) now"
        case .nothingToDo: "Nothing to do"
        case .tool(let message): message
        }
    }
}
