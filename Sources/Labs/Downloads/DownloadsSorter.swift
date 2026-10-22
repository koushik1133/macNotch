import Foundation

/// Moves files for sorting and puts them back for Undo. Never overwrites:
/// a name that's taken gets " 2", " 3"… like Finder. Never deletes.
enum DownloadsSorter {
    enum SortError: LocalizedError, Equatable {
        case missing(String)
        case invalidDestination
        case alreadyThere
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): "\(name) isn't there any more"
            case .invalidDestination: "That folder can't be used"
            case .alreadyThere: "It's already in that folder"
            case .failed(let reason): reason
            }
        }
    }

    /// Moves `url` into `folder` (created when missing) and returns the new URL.
    static func move(_ url: URL, toFolder folder: URL, fileManager: FileManager = .default) throws -> URL {
        guard fileManager.fileExists(atPath: url.path) else { throw SortError.missing(url.lastPathComponent) }
        let source = URL(fileURLWithPath: DownloadsPath.real(url.path))
        let target = URL(fileURLWithPath: DownloadsPath.real(folder.path), isDirectory: true)
        guard target.path != "/" else { throw SortError.invalidDestination }
        if source.deletingLastPathComponent().path == target.path { throw SortError.alreadyThere }
        // A folder can't go inside itself.
        if target.path == source.path || target.path.hasPrefix(source.path + "/") { throw SortError.invalidDestination }
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            let destination = uniqueURL(in: target, name: source.lastPathComponent, fileManager: fileManager)
            try fileManager.moveItem(at: source, to: destination)
            return destination
        } catch let error as SortError {
            throw error
        } catch {
            throw SortError.failed(describe(error))
        }
    }

    /// Moves a sorted file back to where it was. Returns where it ended up
    /// (a " 2" name when something new took the original name meanwhile).
    static func undo(_ move: DownloadMove, fileManager: FileManager = .default) throws -> URL {
        guard fileManager.fileExists(atPath: move.to.path) else { throw SortError.missing(move.to.lastPathComponent) }
        let folder = move.from.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = fileManager.fileExists(atPath: move.from.path)
                ? uniqueURL(in: folder, name: move.from.lastPathComponent, fileManager: fileManager)
                : move.from
            try fileManager.moveItem(at: move.to, to: destination)
            return destination
        } catch {
            throw SortError.failed(describe(error))
        }
    }

    /// "Report.pdf" → "Report 2.pdf" → "Report 3.pdf" … (first free name).
    static func uniqueURL(in folder: URL, name: String, fileManager: FileManager = .default) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 2...9_999 {
            let next = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(next)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(base) \(UUID().uuidString.prefix(6))" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return "macOS didn't allow SparkV to use that folder"
        }
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(EPERM) || posix.code == Int(EACCES) {
            return "macOS didn't allow SparkV to use that folder"
        }
        return ns.localizedDescription
    }
}
