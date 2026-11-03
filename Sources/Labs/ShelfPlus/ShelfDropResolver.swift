import AppKit
import UniformTypeIdentifiers

/// Decides what a dropped item is and fetches it, for every SparkV drop
/// target (Tray, File Drop shelf, AirDrop tile).
///
/// Apps hand over files in three ways: a file URL (Finder, the Desktop), a
/// file *promise* (Mail attachments, Photos, Affinity, WeChat, the
/// screenshot thumbnail, some browsers), or raw data/text. Promises carry
/// no file URL, so a drop target that only takes file URLs and images
/// rejects them. The resolver takes the promise's content type, asks for a
/// file representation (which makes the source app write the file) and
/// copies it out before the callback returns, because the system deletes
/// the provided file afterwards.
enum ShelfDropResolver {
    /// What one dropped item is, best first.
    enum Route: Equatable, Sendable {
        /// Image data or an image promise (copied in, shown as a thumbnail).
        case image(type: String)
        /// A real file on disk, kept by reference.
        case fileURL
        /// A promised or raw file of this content type (copied in).
        case promisedFile(type: String)
        /// A web link.
        case link
        case text
        case nothing
    }

    /// The route for a provider with these registered types. `suggestedName`
    /// tells a Finder drag of a .png (file URL + image type) from a web image.
    static func route(types: [String], suggestedName: String?) -> Route {
        let hasFileURL = types.contains { conforms($0, to: .fileURL) }
        if let imageType = types.first(where: { conforms($0, to: .image) }),
           !hasFileURL || nameLooksLikeImage(suggestedName) {
            return .image(type: imageType)
        }
        if hasFileURL { return .fileURL }
        let hasURL = types.contains { conforms($0, to: .url) }
        let hasText = types.contains { conforms($0, to: .text) || $0 == "NSStringPboardType" }
        // A link or a text selection often brings rich-text or archive
        // companions (RTFD, web archive): those are text, not files.
        if hasURL { return .link }
        if !hasText, let type = types.first(where: isFileContentType) {
            return .promisedFile(type: type)
        }
        if hasText { return .text }
        return .nothing
    }

    /// A content type a promised file can have: data or a folder, not a
    /// pasteboard bookkeeping type, a dynamic type or text.
    static func isFileContentType(_ identifier: String) -> Bool {
        guard !identifier.hasPrefix("dyn."), !identifier.hasPrefix("com.apple.pasteboard."),
              !identifier.hasPrefix("com.apple.NSFilePromise"), let type = UTType(identifier)
        else { return false }
        if type.conforms(to: .text) || type.conforms(to: .url) || type.conforms(to: .fileURL) { return false }
        return type.conforms(to: .data) || type.conforms(to: .directory) || type.conforms(to: .package)
    }

    static func conforms(_ identifier: String, to type: UTType) -> Bool {
        UTType(identifier)?.conforms(to: type) ?? false
    }

    static func nameLooksLikeImage(_ name: String?) -> Bool {
        guard let name, let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: Staging

    /// Per-drop folder in the temporary directory for promised files.
    nonisolated static func makeStagingFolder(_ label: String = "SparkV-Incoming") -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    /// A file name for a promised item: the provided file's own name, else
    /// the provider's suggested name with the type's extension.
    static func fileName(provided: URL?, suggestedName: String?, type: String) -> String {
        if let provided, !provided.lastPathComponent.isEmpty, !provided.lastPathComponent.hasPrefix(".") {
            return provided.lastPathComponent
        }
        var name = (suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Dropped File" }
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {
            name += "." + ext
        }
        return name
    }

    /// Fetches a promised (or raw data) file and copies it into a fresh
    /// staging folder. Nil when the source app couldn't provide it.
    @MainActor
    static func loadPromisedFile(_ provider: NSItemProvider, type: String) async -> URL? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, error in
                guard let url, let folder = makeStagingFolder() else {
                    AppLog.log("Drop: promised \(type) not provided (\(error?.localizedDescription ?? "no file"))")
                    continuation.resume(returning: nil)
                    return
                }
                let destination = folder.appendingPathComponent(fileName(provided: url, suggestedName: suggested, type: type))
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    AppLog.log("Drop: couldn't copy a promised file: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: File promise receivers (AppKit)

    /// Promises on a drag pasteboard (Mail, Photos, Affinity…) when the drag
    /// has no real file URLs. Read inside a drop's perform step only.
    @MainActor
    static func promiseReceivers(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        guard !(pasteboard.types ?? []).contains(.fileURL) else { return [] }
        return pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    /// True when every promised file is an image (those take the provider
    /// path, which already copies them into the Tray as pictures).
    @MainActor
    static func promisesAreImages(_ receivers: [NSFilePromiseReceiver]) -> Bool {
        let types = receivers.flatMap(\.fileTypes)
        return !types.isEmpty && types.allSatisfy { conforms($0, to: .image) }
    }

    /// Asks the source app to write its promised files into a staging folder;
    /// `each` runs on the main actor for every file as it arrives.
    @MainActor
    static func receive(_ receivers: [NSFilePromiseReceiver], each: @escaping @MainActor (URL) -> Void) {
        guard !receivers.isEmpty, let folder = makeStagingFolder() else { return }
        let queue = OperationQueue()
        queue.name = "SparkV.Drop.promises"
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { @Sendable url, error in
                if let error {
                    AppLog.log("Drop: a promised file failed: \(error.localizedDescription)")
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { each(url) }
                }
            }
        }
    }

    // MARK: Temporary locations

    /// Files in a temporary or cache folder vanish on their own (browser
    /// drag files, app exports): the Tray keeps a copy of those.
    static func isVolatile(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        if path.hasPrefix(temp + "/") || path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
            || path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") { return true }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().path
        if let caches, path.hasPrefix(caches + "/") { return true }
        return false
    }
}
