import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Off-main processing and storage: fingerprints, image conversion and
/// thumbnails, blob files and the JSON index. Directory layout:
///
///     <directory>/history.json
///     <directory>/blobs/<item id>.<ext>
///
/// The directory is created with mode 0700. With `persistsIndex == false`
/// blobs still go to disk while the app runs (images are too big for
/// memory) but the index is never written, and `removeAll()` wipes it.
actor ClipboardDiskStore {
    nonisolated let directory: URL
    nonisolated let blobDirectory: URL
    nonisolated let indexURL: URL
    private var persistsIndex: Bool

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Clipboard", isDirectory: true)
    }

    static let thumbnailPixelSize = 240

    init(directory: URL = ClipboardDiskStore.defaultDirectory, persistsIndex: Bool = true) {
        self.directory = directory
        self.blobDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        self.indexURL = directory.appendingPathComponent("history.json")
        self.persistsIndex = persistsIndex
    }

    func setPersistsIndex(_ value: Bool) {
        persistsIndex = value
        if !value { try? FileManager.default.removeItem(at: indexURL) }
    }

    // MARK: Index

    /// Saved items whose blobs (and files, for file items) still exist.
    /// Blobs no item refers to are deleted.
    func load() -> [ClipboardItem] {
        ensureDirectories()
        var items: [ClipboardItem] = []
        if persistsIndex, let data = try? Data(contentsOf: indexURL) {
            // Default (Double) dates: exact round trip, unlike ISO 8601 seconds.
            items = (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
        }
        items = items.filter { item in
            item.blobs.values.allSatisfy { FileManager.default.fileExists(atPath: blobURL($0).path) }
        }
        pruneOrphans(keeping: items)
        return items
    }

    func save(_ items: [ClipboardItem]) {
        guard persistsIndex else { return }
        ensureDirectories()
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    // MARK: Ingest

    /// Turns a capture into a history item: computes its fingerprint, stores
    /// rich text and image data as blobs (TIFF becomes PNG) and makes a
    /// thumbnail. Nil when there's nothing usable.
    func ingest(_ capture: ClipboardCapture, id: UUID = UUID()) -> ClipboardItem? {
        guard let kind = capture.kind else { return nil }
        ensureDirectories()
        var blobs: [String: String] = [:]
        var byteCount = 0
        var text: String?
        var title: String?
        var thumbnail: String?
        var width: Int?
        var height: Int?
        let fingerprint: String

        switch kind {
        case .text, .richText:
            text = capture.string ?? ""
            byteCount = text?.utf8.count ?? 0
            if let rtf = capture.rtf, let name = writeBlob(rtf, id: id, ext: "rtf") {
                blobs[UTType.rtf.identifier] = name
                byteCount += rtf.count
            }
            if let html = capture.html, let name = writeBlob(html, id: id, ext: "html") {
                blobs[UTType.html.identifier] = name
                byteCount += html.count
            }
            fingerprint = Self.fingerprint("t", Data((text ?? "").utf8))
        case .url:
            let trimmed = capture.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let link = ClipboardCapture.webLink(trimmed) != nil ? trimmed : (capture.urlString ?? trimmed)
            text = link
            title = capture.urlTitle
            byteCount = link.utf8.count
            fingerprint = Self.fingerprint("t", Data(link.utf8))
        case .image:
            guard let image = capture.image else { return nil }
            var data = image.data
            var type = image.type
            if type == UTType.tiff.identifier, let png = Self.convertToPNG(data) {
                data = png
                type = UTType.png.identifier
            }
            let ext = UTType(type)?.preferredFilenameExtension ?? "img"
            guard let name = writeBlob(data, id: id, ext: ext) else { return nil }
            blobs[type] = name
            byteCount = data.count
            if let info = Self.thumbnail(of: data, maxPixelSize: Self.thumbnailPixelSize) {
                width = info.width
                height = info.height
                if let thumb = writeBlob(info.png, id: id, ext: "thumb.png") {
                    thumbnail = thumb
                    byteCount += info.png.count
                }
            }
            // Fingerprint the decoded bytes' source, so the same screenshot
            // copied twice is one item.
            fingerprint = Self.fingerprint("i", image.data)
        case .file:
            let paths = capture.fileURLs.map(\.standardizedFileURL.path)
            byteCount = paths.joined().utf8.count
            fingerprint = Self.fingerprint("f", Data(paths.joined(separator: "\n").utf8))
        }

        return ClipboardItem(
            id: id, kind: kind, text: text, title: title,
            fileURLs: kind == .file ? capture.fileURLs : nil,
            blobs: blobs, thumbnailBlob: thumbnail, pixelWidth: width, pixelHeight: height,
            sourceBundleID: capture.sourceBundleID,
            copiedAt: capture.capturedAt, firstCopiedAt: capture.capturedAt, copyCount: 1,
            isPinned: false, fingerprint: fingerprint, byteCount: byteCount
        )
    }

    // MARK: Reading back

    /// The item with its blob data, ready to write to a pasteboard.
    func payload(for item: ClipboardItem) -> ClipboardPayload {
        var data: [String: Data] = [:]
        for (type, name) in item.blobs {
            if let blob = try? Data(contentsOf: blobURL(name)) { data[type] = blob }
        }
        return ClipboardPayload(item: item, data: data)
    }

    nonisolated func thumbnailData(for item: ClipboardItem) -> Data? {
        guard let name = item.thumbnailBlob else { return nil }
        return try? Data(contentsOf: blobURL(name))
    }

    /// File URL of the stored full image (for drag-out).
    nonisolated func imageFileURL(for item: ClipboardItem) -> URL? {
        guard item.kind == .image,
              let name = item.blobs.first(where: { $0.key != UTType.rtf.identifier && $0.key != UTType.html.identifier })?.value
        else { return nil }
        return blobURL(name)
    }

    // MARK: Deleting

    func discard(_ items: [ClipboardItem]) {
        for item in items {
            for name in item.blobs.values { try? FileManager.default.removeItem(at: blobURL(name)) }
            if let thumb = item.thumbnailBlob { try? FileManager.default.removeItem(at: blobURL(thumb)) }
        }
    }

    /// Deletes the index and every blob.
    func removeAll() {
        try? FileManager.default.removeItem(at: indexURL)
        try? FileManager.default.removeItem(at: blobDirectory)
        ensureDirectories()
    }

    private func pruneOrphans(keeping items: [ClipboardItem]) {
        let referenced = Set(items.flatMap { Array($0.blobs.values) + ($0.thumbnailBlob.map { [$0] } ?? []) })
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path)) ?? []
        for name in contents where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: blobURL(name))
        }
    }

    // MARK: Helpers

    nonisolated func blobURL(_ name: String) -> URL {
        // Names are generated here; never let one escape the folder.
        blobDirectory.appendingPathComponent((name as NSString).lastPathComponent)
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: blobDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobDirectory.path)
    }

    private func writeBlob(_ data: Data, id: UUID, ext: String) -> String? {
        let name = "\(id.uuidString).\(ext)"
        do {
            try data.write(to: blobURL(name), options: [.atomic])
            return name
        } catch {
            return nil
        }
    }

    static func fingerprint(_ prefix: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// On-device text recognition for image search (Vision, fast level).
    /// Runs off the ingest queue; skips huge images.
    nonisolated static func recognizeText(at url: URL, pixelWidth: Int, pixelHeight: Int) -> String? {
        guard pixelWidth * pixelHeight <= 25_000_000,
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(20_000))
    }

    static func convertToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return encodePNG(image)
    }

    /// Downsampled PNG preview plus the full image's pixel size.
    static func thumbnail(of data: Data, maxPixelSize: Int) -> (png: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = encodePNG(thumb)
        else { return nil }
        return (png, width, height)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
