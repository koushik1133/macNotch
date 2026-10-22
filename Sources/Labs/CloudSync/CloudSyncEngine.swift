import CryptoKit
import Foundation

/// Mirrors a list of files into a folder, incrementally and without ever
/// deleting anything the user could want back:
///
/// - A file is written only when its content hash changed; unchanged files
///   are recognized by size and modification date, so a run with no changes
///   reads nothing from iCloud Drive (and never downloads evicted files).
/// - A file someone edited (on the iPhone, in Finder, on another Mac) is
///   moved to `Conflicts/` before SparkV writes its own version.
/// - A file whose source is gone moves to `.trash/<day>/`; an edited one to
///   `Conflicts/`. Nothing is removed outright.
/// - A renamed source (meeting renamed, note's first line changed, Space
///   renamed) moves its file instead of trashing and rewriting it.
/// - Files whose category is off or whose data could not be loaded this run
///   are left alone ("scopes"), and a run that would remove most of a
///   category at once is held back until the user confirms it.
///
/// Runs synchronously; call it off the main thread. All writes and moves go
/// through `NSFileCoordinator`, so iCloud's own syncing sees them properly.
struct CloudSyncEngine: Sendable {
    let root: URL
    var now = Date()
    var calendar = Calendar.current
    /// Above this many removals in one run (and over half of what is in
    /// scope), removals wait for `allowMassRemoval`.
    var massRemovalThreshold = 20

    /// Applies `files`. `scopes` are the sourceKey prefixes this run is
    /// authoritative for; manifest entries outside them are not touched.
    func mirror(_ files: [CloudSyncFile], scopes: [String], manifest: inout CloudSyncManifest,
                allowMassRemoval: Bool = false) -> CloudSyncReport {
        var report = CloudSyncReport()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            record(error, "Can't create \(root.lastPathComponent)", into: &report)
            report.finishedAt = Date()
            return report
        }

        // 1. Desired files, de-duplicated by case-insensitive path.
        var desired: [(key: String, file: CloudSyncFile)] = []
        var taken = Set<String>()
        for var file in files {
            guard Self.isValid(file.path) else {
                report.skipped.append("Skipped unsafe path \(file.path)")
                continue
            }
            var key = CloudSyncPaths.key(file.path)
            if taken.contains(key) {
                let original = file.path
                var n = 2
                repeat {
                    file.path = CloudSyncPaths.numbered(original, n)
                    key = CloudSyncPaths.key(file.path)
                    n += 1
                } while taken.contains(key)
            }
            taken.insert(key)
            desired.append((key, file))
        }
        let desiredKeys = taken
        var bySource: [String: String] = [:]
        for (key, entry) in manifest.entries { bySource[entry.sourceKey] = key }

        // 2. Write what changed.
        for (key, file) in desired {
            let dest = url(for: file.path)
            var entry = manifest.entries[key]

            // A source whose file name changed: move the old file over.
            if entry?.sourceKey != file.sourceKey, let oldKey = bySource[file.sourceKey], oldKey != key,
               !desiredKeys.contains(oldKey), let old = manifest.entries[oldKey] {
                let oldURL = url(for: old.path)
                if fm.fileExists(atPath: oldURL.path), !CloudSyncPaths.exists(dest), isUnchanged(old, at: oldURL) {
                    do {
                        try move(oldURL, to: dest)
                        manifest.entries[oldKey] = nil
                        bySource[file.sourceKey] = key
                        var moved = old
                        moved.path = file.path
                        if let stat = Self.stat(dest) { moved.size = stat.size; moved.modified = stat.modified }
                        manifest.entries[key] = moved
                        entry = moved
                        report.renamed += 1
                        removeEmptyParents(of: oldURL)
                    } catch {
                        record(error, "Can't rename \(old.path)", into: &report)
                        if report.permissionDenied { break }
                    }
                }
            }

            // What the file should contain.
            let hash: String
            var signature: String?
            switch file.payload {
            case .data(let data):
                hash = Self.sha256(data)
            case .copy(let source):
                guard let stat = Self.stat(source) else {
                    report.skipped.append("\(source.lastPathComponent) is no longer on this Mac")
                    continue
                }
                let sig = "\(stat.size):\(stat.modified)"
                signature = sig
                if let entry, entry.sourceSignature == sig {
                    hash = entry.hash
                } else if let h = Self.sha256(fileAt: source) {
                    hash = h
                } else {
                    report.skipped.append("Can't read \(source.lastPathComponent)")
                    continue
                }
            }

            do {
                if fm.fileExists(atPath: dest.path) {
                    let untouched = entry.map { isUnchanged($0, at: dest) } ?? false
                    if let current = entry, untouched, current.hash == hash {
                        if current.sourceSignature != signature || current.sourceKey != file.sourceKey {
                            var updated = current
                            updated.sourceSignature = signature
                            updated.sourceKey = file.sourceKey
                            manifest.entries[key] = updated
                        }
                        report.unchanged += 1
                        continue
                    }
                    let destHash = untouched ? entry?.hash : Self.sha256(fileAt: dest)
                    if destHash == hash {
                        // Already right (e.g. written before a crash): adopt it.
                        manifest.entries[key] = makeEntry(file, hash: hash, signature: signature, at: dest)
                        report.unchanged += 1
                        continue
                    }
                    if entry == nil || destHash != entry?.hash {
                        // Edited outside SparkV, or a file SparkV never wrote.
                        try preserve(dest, relativePath: file.path)
                        report.preserved += 1
                    } else if entry?.sourceKey != file.sourceKey {
                        // SparkV's file for a source that is gone (a deleted
                        // note whose name a new one took): trash, don't overwrite.
                        try moveToTrash(dest, relativePath: file.path)
                        report.trashed += 1
                    }
                } else if fm.fileExists(atPath: CloudSyncPaths.placeholder(for: dest).path) {
                    // Old-style evicted iCloud file: ask for it and retry later.
                    if entry?.hash == hash { report.unchanged += 1; continue }
                    try? fm.startDownloadingUbiquitousItem(at: dest)
                    report.skipped.append("Waiting for iCloud to download \(file.path)")
                    continue
                }
                try write(file.payload, to: dest)
                manifest.entries[key] = makeEntry(file, hash: hash, signature: signature, at: dest)
                bySource[file.sourceKey] = key
                report.written += 1
            } catch {
                record(error, "Can't write \(file.path)", into: &report)
                if report.permissionDenied || Self.isOutOfSpace(error) { break }
            }
        }

        // 3. Files whose source is gone.
        if !report.permissionDenied {
            let inScope = manifest.entries.filter { _, e in scopes.contains { e.sourceKey.hasPrefix($0) } }
            let stale = inScope.filter { !desiredKeys.contains($0.key) }
            // Judged per scope (category): 30 meetings vanishing at once must
            // be held even when 200 Spaces files are fine.
            var held = Set<String>()
            if !allowMassRemoval {
                for scope in scopes {
                    let scoped = inScope.filter { $0.value.sourceKey.hasPrefix(scope) }
                    let scopedStale = scoped.keys.filter { !desiredKeys.contains($0) }
                    if scopedStale.count > massRemovalThreshold, scopedStale.count * 2 > scoped.count {
                        held.formUnion(scopedStale)
                    }
                }
            }
            report.heldRemovals = held.count
            for (key, entry) in stale.sorted(by: { $0.key < $1.key }) where !held.contains(key) {
                let target = url(for: entry.path)
                do {
                    if fm.fileExists(atPath: target.path) {
                        if isUnchanged(entry, at: target) || Self.sha256(fileAt: target) == entry.hash {
                            try moveToTrash(target, relativePath: entry.path)
                            report.trashed += 1
                        } else {
                            try preserve(target, relativePath: entry.path)
                            report.preserved += 1
                        }
                        removeEmptyParents(of: target)
                    }
                    manifest.entries[key] = nil
                } catch {
                    record(error, "Can't move \(entry.path) to the SparkV trash", into: &report)
                    if report.permissionDenied { break }
                }
            }
        }

        try? fm.removeItem(at: root.appendingPathComponent(CloudSyncPaths.temp))
        report.finishedAt = Date()
        return report
    }

    // MARK: - Paths

    func url(for relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Relative, no "." / ".." components, nothing in SparkV's own folders.
    static func isValid(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !path.hasPrefix("/") else { return false }
        for part in parts where part.isEmpty || part == "." || part == ".." || part.hasPrefix(".") {
            return false
        }
        return !CloudSyncPaths.reservedTopLevel.contains(parts[0].lowercased())
    }

    // MARK: - File operations

    /// True when `url` is inside the root once symlinks are resolved: a
    /// folder in the mirror that is a symlink (or alias target) leading
    /// elsewhere never receives writes or moves.
    func staysInside(_ url: URL) -> Bool {
        let fm = FileManager.default
        var dir = url.deletingLastPathComponent()
        // The nearest folder that exists decides (the rest gets created inside it).
        while !fm.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return false }
            dir = parent
        }
        return CloudSyncPaths.isInside(dir, root)
    }

    private func requireInside(_ urls: URL...) throws {
        for url in urls where !staysInside(url) {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "“\(url.deletingLastPathComponent().lastPathComponent)” leads outside the SparkV folder (a link); not written",
            ])
        }
    }

    private func write(_ payload: CloudSyncFile.Payload, to dest: URL) throws {
        let fm = FileManager.default
        try requireInside(dest)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch payload {
        case .data(let data):
            try coordinate(writing: dest) { url in try data.write(to: url, options: .atomic) }
        case .copy(let source):
            // Copy next to the destination first, then swap it in, so a
            // half-copied image never shows up on the iPhone.
            let tempDir = root.appendingPathComponent(CloudSyncPaths.temp, isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let temp = tempDir.appendingPathComponent(UUID().uuidString + "-" + dest.lastPathComponent)
            try requireInside(temp)
            try fm.copyItem(at: source, to: temp)
            do {
                try coordinate(writing: dest) { url in
                    if fm.fileExists(atPath: url.path) {
                        _ = try fm.replaceItemAt(url, withItemAt: temp)
                    } else {
                        try fm.moveItem(at: temp, to: url)
                    }
                }
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
    }

    /// Moves a file edited outside SparkV to Conflicts/, keeping its folder
    /// and adding when it was set aside: "Conflicts/Notes/Plan (edited 2026-10-22 143005).md".
    private func preserve(_ file: URL, relativePath: String) throws {
        let ns = relativePath as NSString
        let dir = ns.deletingLastPathComponent
        let ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        let name = "\(stem) (edited \(CloudSyncPaths.stamp(now, calendar: calendar)))" + (ext.isEmpty ? "" : ".\(ext)")
        var folder = root.appendingPathComponent(CloudSyncPaths.conflicts, isDirectory: true)
        if !dir.isEmpty { folder = dir.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try move(file, to: CloudSyncPaths.freeURL(in: folder, name: name))
    }

    private func moveToTrash(_ file: URL, relativePath: String) throws {
        let dir = (relativePath as NSString).deletingLastPathComponent
        var folder = root.appendingPathComponent(CloudSyncPaths.trash, isDirectory: true)
            .appendingPathComponent(CloudSyncPaths.day(now, calendar: calendar), isDirectory: true)
        if !dir.isEmpty { folder = dir.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try move(file, to: CloudSyncPaths.freeURL(in: folder, name: file.lastPathComponent))
    }

    func move(_ source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try requireInside(source, dest)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: dest, options: .forReplacing, error: &coordError) { from, to in
            do {
                try fm.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordError ?? moveError { throw error }
    }

    private func coordinate(writing url: URL, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do { try body(target) } catch { bodyError = error }
        }
        if let error = coordError ?? bodyError { throw error }
    }

    /// Removes folders the mirror emptied (up to, not including, the root).
    /// Only empty folders go; a folder holding anything but Finder's
    /// .DS_Store stays.
    func removeEmptyParents(of file: URL) {
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while dir.path.hasPrefix(rootPath + "/"), dir.path != rootPath {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            for name in contents { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            guard (try? fm.removeItem(at: dir)) != nil else { return }
            dir = dir.deletingLastPathComponent()
        }
    }

    // MARK: - Change detection

    private func isUnchanged(_ entry: CloudSyncManifest.Entry, at url: URL) -> Bool {
        guard let stat = Self.stat(url) else { return false }
        return stat.size == entry.size && abs(stat.modified - entry.modified) < 0.001
    }

    private func makeEntry(_ file: CloudSyncFile, hash: String, signature: String?, at url: URL) -> CloudSyncManifest.Entry {
        let stat = Self.stat(url)
        return CloudSyncManifest.Entry(path: file.path, sourceKey: file.sourceKey, hash: hash,
                                       size: stat?.size ?? -1, modified: stat?.modified ?? 0, sourceSignature: signature)
    }

    static func stat(_ url: URL) -> (size: Int64, modified: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return (size, modified)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file in 1 MB chunks (images and videos can be large).
    static func sha256(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // nil (or empty) at end of file; a thrown error is a real read failure.
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Errors

    private func record(_ error: Error, _ context: String, into report: inout CloudSyncReport) {
        if Self.isPermissionDenied(error) { report.permissionDenied = true }
        report.errors.append("\(context): \(error.localizedDescription)")
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}
