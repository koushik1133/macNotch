import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One thing on the shelf.
struct TrayItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        /// A file left where it is (documents, folders, …).
        case file
        /// An image copied into the tray's own storage (screenshots, photos).
        case image
        /// Dropped or pasted text, including links.
        case text
    }

    let id: UUID
    let kind: Kind
    var url: URL?
    var text: String?
    let addedAt: Date

    var displayName: String {
        switch kind {
        case .file, .image: url?.lastPathComponent ?? "Item"
        case .text: text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
    }
}

/// Shelf for the last few things dropped on the notch: screenshots, text,
/// links and files. Holds at most `capacity` items, newest first, and
/// survives relaunches.
@MainActor
final class TrayStore: ObservableObject {
    static let capacity = 5

    @Published private(set) var items: [TrayItem] = []
    /// Downsampled previews of image items, keyed by item id. Decoding a
    /// full-size screenshot on every redraw is far too slow for the drawer.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    private var thumbnailsLoading: Set<UUID> = []
    private static let thumbnailPixelSize = 160
    /// Cards picked with Cmd-click (Dropover's multi-select): dragging any
    /// of them drags them all. Not persisted.
    @Published private(set) var selection: Set<UUID> = []

    private static let defaultsKey = "TrayItems.v2"
    private let storage: URL
    private let defaults: UserDefaults
    private let trash: @Sendable (URL) -> Bool

    /// `storage`, `defaults` and `trash` are seams for tests; the app uses
    /// Application Support/SparkV/Tray, the standard defaults and the Trash.
    init(storage: URL? = nil, defaults: UserDefaults = .standard,
         trash: @escaping @Sendable (URL) -> Bool = { TrayStore.moveToTrash($0) }) {
        let url = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Tray", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.storage = url
        self.defaults = defaults
        self.trash = trash
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([TrayItem].self, from: data) {
            items = saved.filter { item in
                guard item.kind != .text else { return true }
                return item.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }
        }
        removeUnreferencedStorage()
        items.forEach(loadThumbnailIfNeeded)
    }

    /// Image copies left behind by a crash, or by items dropped from the saved
    /// list, would otherwise pile up in Application Support forever. They go
    /// to the Trash, not straight to deletion: if the saved list was ever
    /// lost, the screenshots are still recoverable.
    private func removeUnreferencedStorage() {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: storage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let referenced = Set(items.compactMap { item -> String? in
            guard item.kind == .image, let url = item.url else { return nil }
            return url.standardizedFileURL.path
        })
        var removed = 0
        for url in contents where !referenced.contains(url.standardizedFileURL.path) {
            if trash(url) { removed += 1 }
        }
        if removed > 0 {
            AppLog.log("Tray: moved \(removed) unreferenced file(s) from tray storage to the Trash")
        }
    }

    /// Tray-owned copies (often the only copy of a screenshot) are never
    /// destroyed outright: they go to the Trash, where the user can restore them.
    @discardableResult
    nonisolated static func moveToTrash(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            AppLog.log("Tray: could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Adding

    /// Takes whatever a drag carries, in order of preference: an image
    /// (including screenshot thumbnails, which are dragged as image data or a
    /// file promise rather than a file), a file, a link, then plain text.
    func accept(_ providers: [NSItemProvider]) {
        AppLog.log("Tray: drop with \(providers.count) item(s): \(providers.map(\.registeredTypeIdentifiers))")
        for provider in providers {
            if let imageType = provider.registeredTypeIdentifiers.first(where: Self.isImageType),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || Self.isImageFile(provider) {
                loadImage(from: provider, type: imageType)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                loadFile(from: provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.addText(url.absoluteString) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in self.addText(text) }
                }
            } else {
                AppLog.log("Tray: nothing usable in \(provider.registeredTypeIdentifiers)")
            }
        }
    }

    /// Adds what's on the clipboard: an image (e.g. a screenshot taken with
    /// Ctrl-Shift-Cmd-4), files, or text.
    func pasteFromClipboard(_ pasteboard: NSPasteboard = .general) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            urls.forEach(addFile)
            return
        }
        // Only real bitmap types count as an image: NSImage(pasteboard:) also
        // accepts the PDF that many apps publish alongside copied text.
        if let type = pasteboard.availableType(from: [.png, .tiff]),
           let data = pasteboard.data(forType: type) {
            let png = type == .png ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            if let png {
                addImage(data: png, suggestedName: "Clipboard Image", fileExtension: "png")
                return
            }
        }
        if let text = pasteboard.string(forType: .string) {
            addText(text)
        }
    }

    /// Interactive screenshot (drag to select, Space for a window) straight
    /// into the tray. macOS asks for Screen Recording permission the first time.
    func captureScreenshot() {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkV Screenshot \(Int(Date().timeIntervalSince1970)).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-i", "-x", destination.path]
        capture.terminationHandler = { _ in
            Task { @MainActor in
                // Esc during selection exits without writing a file.
                guard FileManager.default.fileExists(atPath: destination.path) else { return }
                self.addFile(destination)
                try? FileManager.default.removeItem(at: destination)
            }
        }
        do {
            try capture.run()
        } catch {
            AppLog.log("Tray: could not start screencapture: \(error.localizedDescription)")
        }
    }

    /// Lets the user pick files when dragging isn't convenient.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Tray"
        // An agent app has to activate itself for the open panel to take focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self else { return }
                panel.urls.forEach(self.addFile)
            }
        }
    }

    func addFile(_ url: URL) {
        // Finder can hand over file *reference* URLs (file:///.file/id=…),
        // which have no usable name or icon until resolved to a path URL.
        let fileURL = (url as NSURL).filePathURL ?? url
        guard fileURL.isFileURL else { return }

        // Image files are copied in, so a screenshot still shows after macOS
        // tidies away the original or the user deletes it from the Desktop.
        if let type = UTType(filenameExtension: fileURL.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: fileURL) {
            addImage(data: data, suggestedName: fileURL.deletingPathExtension().lastPathComponent,
                     fileExtension: fileURL.pathExtension)
            return
        }
        guard !items.contains(where: { $0.url == fileURL }) else { return }
        insert(TrayItem(id: UUID(), kind: .file, url: fileURL, text: nil, addedAt: Date()))
    }

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !items.contains(where: { $0.kind == .text && $0.text == text }) else { return }
        insert(TrayItem(id: UUID(), kind: .text, url: nil, text: text, addedAt: Date()))
    }

    private func addImage(data: Data, suggestedName: String, fileExtension: String) {
        let name = Self.storageName(from: suggestedName, fileExtension: fileExtension)
        var destination = storage.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = storage.appendingPathComponent("\(name) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        do {
            try data.write(to: destination)
            let item = TrayItem(id: UUID(), kind: .image, url: destination, text: nil, addedAt: Date())
            insert(item)
            loadThumbnailIfNeeded(item)
        } catch {
            AppLog.log("Tray: could not save image: \(error.localizedDescription)")
        }
    }

    private func insert(_ item: TrayItem) {
        items.insert(item, at: 0)
        while items.count > Self.capacity {
            discardStorage(of: items.removeLast())
        }
        AppLog.log("Tray: added \(item.kind.rawValue) “\(item.displayName.prefix(40))”")
        save()
        SpaceIngestCenter.tray(item)
    }

    // MARK: Removing

    func remove(_ item: TrayItem) {
        items.removeAll { $0.id == item.id }
        discardStorage(of: item)
        save()
    }

    func clear() {
        items.forEach(discardStorage)
        items.removeAll()
        save()
    }

    /// Only copies the tray made itself are touched, and they go to the
    /// Trash; dropped files stay put.
    private func discardStorage(of item: TrayItem) {
        selection.remove(item.id)
        thumbnails[item.id] = nil
        thumbnailsLoading.remove(item.id)
        guard item.kind == .image, let url = item.url,
              url.standardizedFileURL.path.hasPrefix(storage.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        _ = trash(url)
    }

    // MARK: Using

    func copyToClipboard(_ item: TrayItem, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let url = item.url, let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image, url as NSURL])
            }
        case .file:
            if let url = item.url {
                pasteboard.writeObjects([url as NSURL])
            }
        }
    }

    func dragProvider(for item: TrayItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            NSItemProvider(object: (item.text ?? "") as NSString)
        case .image, .file:
            item.url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        }
    }

    // MARK: Thumbnails

    private func loadThumbnailIfNeeded(_ item: TrayItem) {
        guard item.kind == .image, let url = item.url,
              thumbnails[item.id] == nil, !thumbnailsLoading.contains(item.id)
        else { return }
        thumbnailsLoading.insert(item.id)
        let id = item.id
        let maxPixelSize = Self.thumbnailPixelSize
        DispatchQueue.global(qos: .userInitiated).async {
            let thumbnail = Self.makeThumbnail(of: url, maxPixelSize: maxPixelSize)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.thumbnailLoaded(thumbnail, for: id) }
            }
        }
    }

    private func thumbnailLoaded(_ thumbnail: CGImage?, for id: UUID) {
        // Removed while it was loading: don't resurrect the cache entry.
        guard thumbnailsLoading.remove(id) != nil else { return }
        guard let thumbnail else {
            AppLog.log("Tray: could not make a thumbnail for \(id)")
            return
        }
        thumbnails[id] = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }

    nonisolated private static func makeThumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Helpers

    /// A file name for a copied image: no doubled extension ("Shot.png.png")
    /// and no "/" or ":", which aren't allowed in a path component.
    private static func storageName(from suggestedName: String, fileExtension: String) -> String {
        var name = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = (name as NSString).pathExtension
        // Only strip a real extension: "Screenshot … at 10.30.45" ends in ".45".
        if !existing.isEmpty,
           existing.caseInsensitiveCompare(fileExtension) == .orderedSame
            || UTType(filenameExtension: existing).map({ !$0.isDynamic }) == true {
            name = (name as NSString).deletingPathExtension
        }
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the file.
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "Image" : name
    }

    private func loadImage(from provider: NSItemProvider, type: String) {
        let suggestedName = provider.suggestedName ?? "Screenshot"
        let fileExtension = UTType(type)?.preferredFilenameExtension ?? "png"
        // A file representation also resolves file promises (the floating
        // screenshot thumbnail); the file only exists during the callback.
        _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
            let data = url.flatMap { try? Data(contentsOf: $0) }
            Task { @MainActor in
                if let data {
                    self.addImage(data: data, suggestedName: suggestedName, fileExtension: fileExtension)
                } else {
                    AppLog.log("Tray: could not read image (\(error?.localizedDescription ?? "no data"))")
                }
            }
        }
    }

    private func loadFile(from provider: NSItemProvider) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                AppLog.log("Tray: could not read a file URL (\(error?.localizedDescription ?? "no data"))")
                return
            }
            Task { @MainActor in self.addFile(url) }
        }
    }

    private static func isImageType(_ identifier: String) -> Bool {
        UTType(identifier)?.conforms(to: .image) ?? false
    }

    /// A Finder drag of a .png carries both a file URL and an image type.
    private static func isImageFile(_ provider: NSItemProvider) -> Bool {
        guard let name = provider.suggestedName,
              let type = UTType(filenameExtension: (name as NSString).pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}


// MARK: - Dragging out

extension TrayItem {
    /// What a drag (or "copy all") puts on the pasteboard for this item: the
    /// file URL itself for files and images, exactly as a Finder drag does,
    /// so every receiver (Finder, Mail, Messages, Slack, browser upload
    /// fields, Notes, Figma, …) treats it as a real file and sandboxed apps
    /// get read access to it; plain text for text.
    ///
    /// A text item that is a single web link goes out the way Safari drags
    /// a link: `public.url` + a title + the plain string, so Finder makes a
    /// .webloc, a browser opens it and text fields get the address.
    var pasteboardWriter: (any NSPasteboardWriting)? {
        switch kind {
        case .text:
            guard let text, !text.isEmpty else { return nil }
            if let link = webLink { return Self.linkPasteboardItem(link) }
            return text as NSString
        case .image, .file:
            guard let url, url.isFileURL else { return nil }
            return url as NSURL
        }
    }

    /// A single http(s) link, if that's all the text is.
    var webLink: URL? {
        guard kind == .text, let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    static func linkPasteboardItem(_ link: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(link.absoluteString, forType: .URL)
        item.setString(link.absoluteString, forType: .string)
        var host = link.host ?? link.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        item.setString(host, forType: urlNameType)
        return item
    }
}

/// One thing to drag: what goes on the pasteboard and what follows the pointer.
struct TrayDragPayload {
    let writer: any NSPasteboardWriting
    let image: NSImage
}

extension TrayStore {
    /// Size of the drag image, matching the preview drawn in the tray.
    static let dragImageSize = CGSize(width: 52, height: 40)

    func dragPayload(for item: TrayItem) -> TrayDragPayload? {
        guard let writer = item.pasteboardWriter else { return nil }
        return TrayDragPayload(writer: writer, image: dragImage(for: item))
    }

    /// Payloads for several items, skipping any whose file has gone missing.
    func dragPayloads(for items: [TrayItem]) -> [TrayDragPayload] {
        items.compactMap { item in
            if item.kind != .text, let url = item.url, !FileManager.default.fileExists(atPath: url.path) {
                AppLog.log("Tray: skipping drag of missing file \(url.lastPathComponent)")
                return nil
            }
            return dragPayload(for: item)
        }
    }

    // MARK: Selection (Cmd-click)

    func isSelected(_ item: TrayItem) -> Bool { selection.contains(item.id) }

    func toggleSelection(_ item: TrayItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        if selection.remove(item.id) == nil { selection.insert(item.id) }
    }

    func clearSelection() {
        if !selection.isEmpty { selection.removeAll() }
    }

    /// What dragging `item` takes along: the whole selection when the item
    /// is part of a multi-selection (grabbed item first, so it leads the
    /// pile under the pointer, the rest in shelf order), else just the item.
    func itemsToDrag(startingWith item: TrayItem) -> [TrayItem] {
        guard selection.contains(item.id), selection.count > 1 else { return [item] }
        return [item] + items.filter { $0.id != item.id && selection.contains($0.id) }
    }

    /// Puts every item on the clipboard at once, the way they'd be dragged.
    func copyAllToClipboard(_ pasteboard: NSPasteboard = .general) {
        let writers = items.compactMap(\.pasteboardWriter)
        guard !writers.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
    }

    /// The preview a drag carries: the thumbnail for an image, the Finder
    /// icon for a file, a small card for text.
    func dragImage(for item: TrayItem) -> NSImage {
        let size = Self.dragImageSize
        let thumbnail = thumbnails[item.id]
        let icon: NSImage? = item.kind == .file ? item.url.map { NSWorkspace.shared.icon(forFile: $0.path) } : nil
        return TrayDragImage.render(size: size) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            switch item.kind {
            case .image:
                NSGraphicsContext.saveGraphicsState()
                card.addClip()
                if let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 {
                    // Aspect fill, like the preview in the tray.
                    let scale = max(rect.width / thumbnail.size.width, rect.height / thumbnail.size.height)
                    let drawn = CGSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
                    thumbnail.draw(
                        in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                   width: drawn.width, height: drawn.height),
                        from: .zero, operation: .sourceOver, fraction: 1
                    )
                } else {
                    NSColor(white: 0.25, alpha: 0.9).setFill()
                    card.fill()
                    TrayDragImage.drawSymbol("photo", in: rect)
                }
                NSGraphicsContext.restoreGraphicsState()
                NSColor(white: 1, alpha: 0.35).setStroke()
                card.lineWidth = 1
                card.stroke()
            case .file:
                if let icon {
                    let side = min(rect.width, rect.height) - 2
                    icon.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                              from: .zero, operation: .sourceOver, fraction: 1)
                } else {
                    NSColor(white: 0.25, alpha: 0.9).setFill()
                    card.fill()
                    TrayDragImage.drawSymbol("doc", in: rect)
                }
            case .text:
                NSColor(white: 0.18, alpha: 0.95).setFill()
                card.fill()
                NSColor(white: 1, alpha: 0.3).setStroke()
                card.lineWidth = 1
                card.stroke()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7),
                    .foregroundColor: NSColor(white: 1, alpha: 0.9),
                    .paragraphStyle: paragraph,
                ]
                (String((item.text ?? "").prefix(200)) as NSString).draw(
                    with: rect.insetBy(dx: 4, dy: 4),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: attributes
                )
            }
        }
    }
}

/// Eager bitmap rendering for drag images (no lazily-run drawing handler, so
/// nothing non-Sendable escapes the main actor).
enum TrayDragImage {
    static func render(size: CGSize, scale: CGFloat = 2, draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    static func drawSymbol(_ name: String, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.7)]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    /// Several items fanned out a little, for the "drag all" handle and
    /// multi-item drags before AppKit regroups them.
    static func stackedFrames(count: Int, around center: CGPoint, size: CGSize) -> [NSRect] {
        let step: CGFloat = 4
        let spread = step * CGFloat(max(count - 1, 0))
        return (0..<count).map { index in
            NSRect(
                x: center.x - size.width / 2 - spread / 2 + step * CGFloat(index),
                y: center.y - size.height / 2 - spread / 2 + step * CGFloat(index),
                width: size.width, height: size.height
            )
        }
    }
}

// MARK: - Drag-out sessions

/// Every drag out of a SparkV shelf (Tray cards, File Drop piles, Converter
/// and Clipboard cards, anything built on `TrayDragSource`) checks in here,
/// so the drawer can stay open for the whole drag and the slide-back of a
/// cancelled one, and react once a drop landed somewhere.
///
/// `FileDropController.holdsDrawerOpen` (already part of the window
/// controller's `isInteractionInProgress`) includes `holdsDrawerOpen`.
@MainActor
enum TrayDragOut {
    /// Posted when a drag-out ends. userInfo: `dropped` (Bool),
    /// `count` (Int), `keepOpen` (Bool: Shift was held at the drop, the
    /// Dropover gesture for "keep the shelf open").
    static let didEndNotification = Notification.Name("SparkV.TrayDragOut.didEnd")

    private(set) static var activeSessions = 0
    private(set) static var activeSince: Date?
    private(set) static var lastEnd: (date: Date, dropped: Bool, keepOpen: Bool)?

    /// A session that never reported its end (can't happen with AppKit,
    /// but never hold the drawer forever) stops counting after this long.
    static let staleAfter: TimeInterval = 90
    /// After a cancelled drag the image slides back to the card; keep the
    /// drawer up that long. After a Shift-drop keep it up a little longer,
    /// so the user can grab the next file.
    static let cancelGrace: TimeInterval = 1.2
    static let keepOpenGrace: TimeInterval = 6

    static var isActive: Bool {
        guard activeSessions > 0, let since = activeSince else { return false }
        return Date().timeIntervalSince(since) < staleAfter
    }

    static var holdsDrawerOpen: Bool {
        if isActive { return true }
        guard let end = lastEnd else { return false }
        let age = Date().timeIntervalSince(end.date)
        if end.keepOpen { return age < keepOpenGrace }
        return !end.dropped && age < cancelGrace
    }

    static func began(itemCount: Int) {
        if !isActive { activeSessions = 0 }
        activeSessions += 1
        activeSince = Date()
        lastEnd = nil
    }

    static func ended(operation: NSDragOperation, itemCount: Int, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        activeSessions = max(activeSessions - 1, 0)
        if activeSessions == 0 { activeSince = nil }
        let dropped = !operation.isEmpty
        let keepOpen = modifiers.contains(.shift)
        lastEnd = (Date(), dropped, keepOpen)
        NotificationCenter.default.post(name: didEndNotification, object: nil, userInfo: [
            "dropped": dropped, "count": itemCount, "keepOpen": keepOpen,
        ])
    }

    /// For tests.
    static func reset() {
        activeSessions = 0
        activeSince = nil
        lastEnd = nil
    }

    /// True when a pasteboard writer carries a real file (so the drag must
    /// be a copy, never a move).
    nonisolated static func carriesFile(_ writer: any NSPasteboardWriting) -> Bool {
        if let url = writer as? NSURL { return url.isFileURL }
        if let item = writer as? NSPasteboardItem { return item.types.contains(.fileURL) }
        return false
    }

    /// The dragging items for a set of payloads, fanned around `center`
    /// (view coordinates). Split out so tests can check the construction.
    static func draggingItems(for payloads: [TrayDragPayload], around center: CGPoint, imageSize: CGSize) -> [NSDraggingItem] {
        let frames = TrayDragImage.stackedFrames(count: payloads.count, around: center, size: imageSize)
        return zip(payloads, frames).map { payload, frame in
            let item = NSDraggingItem(pasteboardWriter: payload.writer)
            item.setDraggingFrame(frame, contents: payload.image)
            return item
        }
    }
}

// MARK: - AppKit drag source

/// Transparent AppKit view laid over a tray item (or the "drag all" handle)
/// that owns the mouse: it starts a real `NSDraggingSession`, so drags out
/// of the non-activating notch panel work in every app, and it tells clicks,
/// double-clicks and right-clicks apart itself instead of letting SwiftUI tap
/// gestures race the drag.
final class TrayDragSourceView: NSView, NSDraggingSource {
    enum Anchor {
        /// The drag image starts over the preview at the top of the view.
        case top
        /// The drag image starts centred on the pointer.
        case pointer
    }

    var payloads: () -> [TrayDragPayload] = { [] }
    var anchor: Anchor = .top
    var imageSize: CGSize = TrayStore.dragImageSize
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Cmd- or Shift-click (multi-select). Nil: treated as a plain click.
    var onCommandClick: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?
    var onDragEnded: ((NSDragOperation) -> Void)?
    /// Pointer entered (true) or left (false) the view. Tracked here rather
    /// than with SwiftUI's `onHover`, since this view sits on top and owns
    /// the mouse.
    var onHoverChange: ((Bool) -> Void)?
    /// A top-trailing corner that lets clicks through to the SwiftUI content
    /// drawn above this view (the card's hover ✨ button). `.zero` = none.
    var passThroughTopTrailing: CGSize = .zero
    /// The same for the top-leading corner (the card's hover remove button).
    var passThroughTopLeading: CGSize = .zero
    /// Feedback when a press turns into a drag but nothing behind the view
    /// still exists. A seam for tests.
    var onNothingToDrag: () -> Void = { NSSound.beep() }

    private var mouseDownEvent: NSEvent?
    private var hoverArea: NSTrackingArea?
    private var isDragging = false
    private var pendingClick: Task<Void, Never>?
    /// Text never moves anything, so destinations that only take the
    /// generic operation may have it too.
    private var draggingTextOnly = false
    private var draggingCount = 0

    /// Pointer travel before a press turns into a drag.
    static let dragThreshold: CGFloat = 3

    override var isFlipped: Bool { true }
    // The panel never becomes key in an active app: take the very first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        let local = convert(point, from: superview)
        // Flipped: minY is the top edge.
        if passThroughTopTrailing.width > 0, passThroughTopTrailing.height > 0,
           NSRect(x: bounds.maxX - passThroughTopTrailing.width, y: bounds.minY,
                  width: passThroughTopTrailing.width, height: passThroughTopTrailing.height).contains(local) {
            return nil
        }
        if passThroughTopLeading.width > 0, passThroughTopLeading.height > 0,
           NSRect(x: bounds.minX, y: bounds.minY,
                  width: passThroughTopLeading.width, height: passThroughTopLeading.height).contains(local) {
            return nil
        }
        return hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // The notch panel never becomes key, so track in every app state.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Removed (e.g. the card was deleted) while hovered: no exit event follows.
        if window == nil { onHoverChange?(false) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        mouseDownEvent = event
        isDragging = false
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !isDragging else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return }
        pendingClick?.cancel()
        pendingClick = nil
        beginDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !isDragging,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        if event.clickCount == 1, let onCommandClick,
           !event.modifierFlags.intersection([.command, .shift]).isEmpty {
            pendingClick?.cancel()
            pendingClick = nil
            onCommandClick()
            return
        }
        switch event.clickCount {
        case 1:
            guard let onClick else { return }
            guard onDoubleClick != nil else {
                onClick()
                return
            }
            // Wait out the double-click interval so opening an item doesn't
            // also overwrite the clipboard.
            pendingClick?.cancel()
            let delay = min(NSEvent.doubleClickInterval, 0.6)
            pendingClick = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.pendingClick = nil
                self.onClick?()
            }
        case 2:
            pendingClick?.cancel()
            pendingClick = nil
            (onDoubleClick ?? onClick)?()
        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?()
    }

    private func showMenu(for event: NSEvent) {
        pendingClick?.cancel()
        pendingClick = nil
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func beginDrag(with event: NSEvent) {
        let payloads = payloads()
        guard !payloads.isEmpty else {
            // Every file behind it has gone missing (moved or deleted). End
            // this press here: otherwise every further mouse-dragged event
            // of the same press would try again and beep again.
            mouseDownEvent = nil
            onNothingToDrag()
            AppLog.log("Tray: nothing to drag (files missing)")
            return
        }
        isDragging = true
        draggingTextOnly = !payloads.contains { TrayDragOut.carriesFile($0.writer) }
        draggingCount = payloads.count

        let center: CGPoint
        switch anchor {
        case .top:
            center = CGPoint(x: bounds.midX, y: min(bounds.minY + imageSize.height / 2, bounds.midY))
        case .pointer:
            center = convert(event.locationInWindow, from: nil)
        }
        let items = TrayDragOut.draggingItems(for: payloads, around: center, imageSize: imageSize)
        TrayDragOut.began(itemCount: items.count)
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .pile : .none
        session.draggingLeaderIndex = 0
        AppLog.log("Tray: drag started with \(items.count) item(s)")
    }

    // MARK: NSDraggingSource

    /// Outside the app: copy only for files, so Finder never *moves* a
    /// tray-owned screenshot out of Application Support (it treats `.generic`
    /// and `.move` as a move on the same volume). Inside the app: nothing, so
    /// dropping back on the drawer doesn't add a duplicate.
    nonisolated static func operationMask(for context: NSDraggingContext, textOnly: Bool) -> NSDragOperation {
        switch context {
        case .outsideApplication: textOnly ? [.copy, .generic] : .copy
        case .withinApplication: []
        @unknown default: .copy
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operationMask(for: context, textOnly: draggingTextOnly)
    }

    /// Cmd/Option would otherwise filter the mask down to an operation we
    /// don't offer and make the drop fail.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownEvent = nil
        AppLog.log("Tray: drag ended (\(operation.isEmpty ? "cancelled" : "dropped"))")
        TrayDragOut.ended(operation: operation, itemCount: draggingCount)
        draggingCount = 0
        onDragEnded?(operation)
    }
}

/// SwiftUI wrapper for `TrayDragSourceView`; lay it over the view it drags.
struct TrayDragSource: NSViewRepresentable {
    var anchor: TrayDragSourceView.Anchor = .top
    var toolTip: String?
    var payloads: () -> [TrayDragPayload]
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var menu: (() -> NSMenu?)?
    var onHoverChange: ((Bool) -> Void)?
    var passThroughTopTrailing: CGSize = .zero
    var passThroughTopLeading: CGSize = .zero
    var onCommandClick: (() -> Void)? = nil
    var onDragEnded: ((NSDragOperation) -> Void)? = nil

    func makeNSView(context: Context) -> TrayDragSourceView {
        let view = TrayDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ view: TrayDragSourceView, context: Context) {
        configure(view)
    }

    private func configure(_ view: TrayDragSourceView) {
        view.anchor = anchor
        view.payloads = payloads
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onCommandClick = onCommandClick
        view.onDragEnded = onDragEnded
        view.makeMenu = menu
        view.onHoverChange = onHoverChange
        view.passThroughTopTrailing = passThroughTopTrailing
        view.passThroughTopLeading = passThroughTopLeading
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}

/// Menu item that runs a closure (NSMenuItem's target is weak, so the item
/// is its own target).
final class TrayMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

// MARK: - Views

/// Shelf geometry: a dark rounded well of square cards, with the AirDrop
/// tile beside it.
private enum TrayLayout {
    static let cardCorner: CGFloat = SparkVTheme.cornerMedium
    static let wellPadding: CGFloat = 5
    static let wellCorner: CGFloat = cardCorner + wellPadding
    static let cardSpacing: CGFloat = 8
    static let headerHeight: CGFloat = 16
    static let headerSpacing: CGFloat = 4
    static let airDropWidth: CGFloat = 110
    static let columnSpacing: CGFloat = 10
    static let minCard: CGFloat = 44
    static let maxCard: CGFloat = 96
    /// Size of the corner that passes clicks through to the hover ✨ button.
    static let aiButtonCorner = CGSize(width: 30, height: 30)
    /// Selected cards: the system accent in Apple, red in SparkV Red.
    static var selectionTint: Color { SparkVTheme.accent }
}

/// Opens the AI panel on tray items. "Save to Tray" results land in this
/// tray unless something else already wired the controller.
@MainActor
private func openTrayAI(_ items: [TrayItem], tray: TrayStore, action: TrayAIAction? = nil) {
    guard !items.isEmpty else { return }
    let controller = TrayAIPanelController.shared
    if controller.onSaveToTray == nil {
        controller.onSaveToTray = { [weak tray] text in tray?.addText(text) }
    }
    controller.open(items: items, initialAction: action)
}

struct TrayView: View {
    @EnvironmentObject private var tray: TrayStore
    // Drops are handled by the whole drawer in NotchNookLayoutView.
    @EnvironmentObject private var state: NotchState
    /// Off until the shelf is on screen, so the cards can fade in in turn.
    @StateObject private var appeared = ViewFlag()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let rowHeight = max(size.height - TrayLayout.headerHeight - TrayLayout.headerSpacing, 0)
            let side = min(max(rowHeight - TrayLayout.wellPadding * 2, TrayLayout.minCard), TrayLayout.maxCard)
            let wellHeight = side + TrayLayout.wellPadding * 2
            let airDrop = CGSize(width: TrayLayout.airDropWidth, height: wellHeight)

            HStack(alignment: .bottom, spacing: TrayLayout.columnSpacing) {
                if tray.items.isEmpty {
                    TrayWell(isTargeted: state.isDropTargeted) {
                        TrayEmptyState()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: TrayLayout.headerSpacing) {
                        TrayHeader()
                            .frame(height: TrayLayout.headerHeight)
                        TrayWell(isTargeted: state.isDropTargeted) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: TrayLayout.cardSpacing) {
                                    ForEach(Array(tray.items.enumerated()), id: \.element.id) { index, item in
                                        TrayCardView(item: item, side: side)
                                            .sparkVStaggeredEntrance(appeared.isOn, index: index)
                                            .transition(.opacity.combined(with: .scale(scale: SparkVMotion.enterScale)))
                                    }
                                }
                                .padding(TrayLayout.wellPadding)
                                // New and removed cards slide the row instead of jumping.
                                .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: tray.items.map(\.id))
                            }
                        }
                        .frame(height: wellHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

                TrayAirDropColumn(size: airDrop)
            }
            .frame(width: size.width, height: size.height, alignment: .bottom)
        }
        .padding(.vertical, 2)
        .onAppear { appeared.isOn = true }
        .onDisappear { appeared.isOn = false }
    }
}

/// The dark rounded inner well; dashed and lighter while a drag is over the drawer.
private struct TrayWell<Content: View>: View {
    let isTargeted: Bool
    let content: Content

    init(isTargeted: Bool, @ViewBuilder content: () -> Content) {
        self.isTargeted = isTargeted
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TrayLayout.wellCorner, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipShape(shape)
            .background(shape.fill(isTargeted ? SparkVTheme.choose(apple: Color.white.opacity(0.12), sparkv: SparkVTheme.redSoft) : SparkVTheme.choose(apple: Color.white.opacity(0.055), sparkv: SparkVTheme.surface)))
            .overlay(
                shape.strokeBorder(
                    isTargeted ? SparkVTheme.choose(apple: Color.white.opacity(0.55), sparkv: SparkVTheme.red.opacity(0.8)) : SparkVTheme.choose(apple: Color.white.opacity(0.07), sparkv: SparkVTheme.stroke),
                    style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [5, 4] : [])
                )
            )
            .animation(SparkVMotion.hover(), value: isTargeted)
    }
}

private struct TrayEmptyState: View {
    @EnvironmentObject private var tray: TrayStore

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 15))
                Text("Drop screenshots, text or files")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(SparkVTheme.textSecondary)
            HStack(spacing: 6) {
                TrayActionButton(title: "Paste", systemImage: "doc.on.clipboard") { tray.pasteFromClipboard() }
                    .help("Add what's on the clipboard")
                TrayActionButton(title: "Capture", systemImage: "camera.viewfinder") { tray.captureScreenshot() }
                    .help("Capture part of the screen")
                TrayActionButton(title: "Add…", systemImage: "plus") { tray.chooseFiles() }
                    .help("Choose files to add")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Count, quick actions and the "All" drag handle above the well.
private struct TrayHeader: View {
    @EnvironmentObject private var tray: TrayStore

    var body: some View {
        let images = tray.items.filter { $0.kind == .image }
        HStack(spacing: 5) {
            if tray.selection.isEmpty {
                Text("\(tray.items.count)/\(TrayStore.capacity)")
                    .font(SparkVTheme.eyebrow(9.5))
                    .tracking(0.6)
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .padding(.leading, 6)
                    .help("Cmd-click cards to pick several, then drag any of them")
            } else {
                TrayActionButton(title: "\(tray.selection.count) selected", systemImage: "xmark", height: TrayLayout.headerHeight,
                                 tint: TrayLayout.selectionTint) {
                    tray.clearSelection()
                }
                .help("Drag any picked card to drag all \(tray.selection.count) · click to deselect")
            }
            Spacer(minLength: 6)
            if images.count >= 2 {
                TrayActionButton(title: "Compare with AI", systemImage: "sparkles", height: TrayLayout.headerHeight) {
                    openTrayAI(images, tray: tray, action: .compareDesigns)
                }
                .help("Compare the \(images.count) images with AI")
            }
            TrayActionButton(title: nil, systemImage: "doc.on.clipboard", height: TrayLayout.headerHeight) {
                tray.pasteFromClipboard()
            }
            .help("Add what's on the clipboard")
            TrayActionButton(title: nil, systemImage: "camera.viewfinder", height: TrayLayout.headerHeight) {
                tray.captureScreenshot()
            }
            .help("Capture part of the screen")
            TrayClearButton()
            if tray.items.count > 1 {
                TrayDragAllHandle()
            }
        }
    }
}

/// Clearing asks first: the first click turns the button into a red
/// "Clear 3?" capsule for a few seconds, a second click clears.
private struct TrayClearButton: View {
    @EnvironmentObject private var tray: TrayStore
    @StateObject private var armed = ViewFlag()
    @StateObject private var disarm = TrayTaskBox()

    var body: some View {
        Group {
            if armed.isOn {
                TrayActionButton(title: "Clear \(tray.items.count)?", systemImage: "trash", height: TrayLayout.headerHeight,
                                 tint: SparkVTheme.destructive) {
                    disarm.task?.cancel()
                    armed.isOn = false
                    tray.clear()
                }
                .help("Click again to remove every item (tray copies go to the Trash)")
            } else {
                TrayActionButton(title: nil, systemImage: "xmark", height: TrayLayout.headerHeight) {
                    armed.isOn = true
                    disarm.task?.cancel()
                    let flag = armed
                    disarm.task = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        flag.isOn = false
                    }
                }
                .help("Clear tray")
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.hover)), value: armed.isOn)
        .onDisappear {
            disarm.task?.cancel()
            armed.isOn = false
        }
    }
}

/// Holds a cancellable task for a view (no `@State` with the CLT toolchain).
@MainActor
private final class TrayTaskBox: ObservableObject {
    var task: Task<Void, Never>?
}

private struct TrayActionButton: View {
    let title: String?
    let systemImage: String
    var height: CGFloat = 20
    var tint: Color? = nil
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: height < 18 ? 8 : 9, weight: .bold))
                if let title {
                    Text(title)
                        .font(.system(size: height < 18 ? 9 : 10, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(tint == nil ? SparkVTheme.text : Color.white)
            .padding(.horizontal, title == nil ? 0 : (height < 18 ? 7 : 8))
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(tint.map { hover.isOn ? (SparkVTheme.isApple ? $0.opacity(0.8) : SparkVTheme.redDeep) : $0 }
                                       ?? (hover.isOn ? SparkVTheme.choose(apple: Color.white.opacity(0.18), sparkv: SparkVTheme.surfaceHover)
                                                      : SparkVTheme.choose(apple: Color.white.opacity(0.1), sparkv: SparkVTheme.surface))))
            .overlay(Capsule().strokeBorder(tint == nil && !SparkVTheme.isApple ? SparkVTheme.stroke : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }
}

/// Grab handle that drags every tray item at once; a click copies them all.
private struct TrayDragAllHandle: View {
    @EnvironmentObject private var tray: TrayStore
    @StateObject private var copied = ViewFlag()

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: copied.isOn ? "checkmark" : "square.stack.3d.up.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(copied.isOn ? SparkVTheme.success : SparkVTheme.text)
            Text("All")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
        }
        .padding(.horizontal, 7)
        .frame(height: TrayLayout.headerHeight)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .overlay(
            TrayDragSource(
                anchor: .pointer,
                toolTip: "Drag all \(tray.items.count) items anywhere · click to copy them all",
                payloads: { tray.dragPayloads(for: tray.items) },
                onClick: { copyAll() }
            )
        )
    }

    private func copyAll() {
        tray.copyAllToClipboard()
        copied.isOn = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            copied.isOn = false
        }
    }
}

/// Measured layout size, so a fixed-size view can be scaled to fit a slot.
private final class TraySizeBox: ObservableObject {
    @Published var size: CGSize

    init(_ size: CGSize) {
        self.size = size
    }
}

/// The tall AirDrop tile to the right of the well: drop files on it to
/// AirDrop them (handled by `AirDropTile`), click it to AirDrop the whole tray.
private struct TrayAirDropColumn: View {
    @EnvironmentObject private var tray: TrayStore
    let size: CGSize

    /// `AirDropTile` draws itself at a fixed size; it's scaled up to the slot.
    @StateObject private var natural = TraySizeBox(CGSize(width: 76, height: 64))

    var body: some View {
        let measured = natural.size
        let scale = measured.width > 1 && measured.height > 1
            ? min(size.width / measured.width, size.height / measured.height, 1.6)
            : 1
        let count = tray.items.count
        Button {
            AirDrop.share(tray.items)
        } label: {
            AirDropTile()
                .fixedSize()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { natural.size = proxy.size }
                            .onChange(of: proxy.size) { _, newSize in natural.size = newSize }
                    }
                )
                .scaleEffect(scale)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .help(count == 0
              ? "Drop files, images or links here to send them with AirDrop"
              : "Click to AirDrop \(count == 1 ? "the item" : "all \(count) items") · drop files here to AirDrop them")
    }
}

/// One square shelf card. AppKit owns the mouse over it: drag = drag out,
/// click = copy, double-click = open, right/control-click = menu; hovering
/// shows a ✨ button that asks AI about the item.
private struct TrayCardView: View {
    @EnvironmentObject private var tray: TrayStore
    let item: TrayItem
    let side: CGFloat

    @StateObject private var copied = ViewFlag()
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TrayLayout.cardCorner, style: .continuous)
        let hovered = hover.isOn
        let selected = tray.isSelected(item)
        ZStack(alignment: .bottom) {
            artwork
                .frame(width: side, height: side)
                .clipped()
            TrayCardLabel(text: label, maxWidth: side - 12)
                .padding(.bottom, 6)
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(selected ? TrayLayout.selectionTint : (hovered ? SparkVTheme.choose(apple: Color.white.opacity(0.3), sparkv: SparkVTheme.red.opacity(0.55)) : SparkVTheme.choose(apple: Color.white.opacity(0.08), sparkv: SparkVTheme.stroke)),
                               lineWidth: selected ? 2.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if selected, !hovered {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, TrayLayout.selectionTint)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .overlay {
            if copied.isOn {
                shape
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(SparkVTheme.success)
                    )
                    .transition(.opacity)
            }
        }
        .contentShape(shape)
        .overlay(
            TrayDragSource(
                anchor: .pointer,
                toolTip: item.kind == .text ? String((item.text ?? "").prefix(500)) : (item.url?.path ?? ""),
                payloads: { tray.dragPayloads(for: tray.itemsToDrag(startingWith: item)) },
                onClick: {
                    tray.clearSelection()
                    copy()
                },
                onDoubleClick: item.kind == .text ? nil : { open() },
                menu: { makeMenu() },
                onHoverChange: { hover.isOn = $0 },
                passThroughTopTrailing: hovered ? TrayLayout.aiButtonCorner : .zero,
                passThroughTopLeading: hovered ? TrayLayout.aiButtonCorner : .zero,
                onCommandClick: { tray.toggleSelection(item) }
            )
        )
        .overlay(alignment: .topLeading) {
            if hovered {
                TrayRemoveButton { tray.remove(item) }
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: SparkVMotion.enterScale, anchor: .topLeading)))
            }
        }
        // Drawn above the drag source, whose top-trailing corner lets the
        // click through while it's shown.
        .overlay(alignment: .topTrailing) {
            if hovered {
                TrayAIButton { askAI() }
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: SparkVMotion.enterScale, anchor: .topTrailing)))
            }
        }
        .animation(SparkVMotion.hover(), value: hovered)
        .animation(SparkVMotion.hover(), value: selected)
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.hover), value: copied.isOn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Artwork

    @ViewBuilder
    private var artwork: some View {
        switch item.kind {
        case .image:
            if let image = tray.thumbnails[item.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder("photo")
            }
        case .file:
            ZStack {
                SparkVTheme.surface
                if let url = item.url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.66, height: side * 0.66)
                        // Leave room for the name below.
                        .offset(y: -side * 0.09)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: side * 0.3))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .offset(y: -side * 0.09)
                }
            }
        case .text:
            ZStack(alignment: .topLeading) {
                SparkVTheme.surfaceHover
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: link == nil ? "doc.text.fill" : "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(link == nil ? SparkVTheme.textTertiary : SparkVTheme.red)
                    Text(String((item.text ?? "").prefix(300)))
                        .font(.system(size: 8))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(max(Int((side - 56) / 10), 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 9)
                .padding(.top, 9)
            }
        }
    }

    private func placeholder(_ symbol: String) -> some View {
        ZStack {
            SparkVTheme.surface
            Image(systemName: symbol)
                .font(.system(size: side * 0.26))
                .foregroundStyle(SparkVTheme.textTertiary)
                .offset(y: -side * 0.08)
        }
    }

    /// A single http(s) link, if that's all the text is.
    private var link: URL? { item.webLink }

    private var label: String {
        switch item.kind {
        case .file, .image:
            return item.displayName
        case .text:
            if let host = link?.host {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            let firstLine = item.displayName.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "Text" : firstLine
        }
    }

    // MARK: Actions

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tray = tray
        let item = item
        menu.addItem(TrayMenuItem("Copy", systemImage: "doc.on.doc") { copy() })
        if item.kind != .text {
            menu.addItem(TrayMenuItem("Open", systemImage: "arrow.up.forward.app") { open() })
            menu.addItem(TrayMenuItem("Show in Finder", systemImage: "folder") {
                if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(TrayMenuItem("Ask AI…", systemImage: "sparkles") { openTrayAI([item], tray: tray) })
        menu.addItem(TrayMenuItem("AirDrop", systemImage: "dot.radiowaves.left.and.right") { AirDrop.share([item]) })
        menu.addItem(.separator())
        menu.addItem(TrayMenuItem("Remove from Tray", systemImage: "trash") { tray.remove(item) })
        return menu
    }

    private func askAI() {
        openTrayAI([item], tray: tray)
    }

    private func copy() {
        tray.copyToClipboard(item)
        copied.isOn = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            copied.isOn = false
        }
    }

    private func open() {
        if let url = item.url { NSWorkspace.shared.open(url) }
    }
}

/// Dark translucent capsule with the item's (middle-truncated) name.
private struct TrayCardLabel: View {
    let text: String
    let maxWidth: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(SparkVTheme.text)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(SparkVTheme.choose(apple: Color.black.opacity(0.58), sparkv: SparkVTheme.background.opacity(0.72)))
                    .overlay(Capsule().strokeBorder(SparkVTheme.choose(apple: Color.white.opacity(0.08), sparkv: SparkVTheme.stroke), lineWidth: 0.5))
            )
            .frame(maxWidth: max(maxWidth, 0))
    }
}

/// The small ✕ shown on a hovered card: takes the item off the shelf (a
/// dropped file stays where it is; a tray-made copy goes to the Trash).
private struct TrayRemoveButton: View {
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SparkVTheme.text)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover.isOn
                                          ? SparkVTheme.choose(apple: Color.black.opacity(0.82), sparkv: SparkVTheme.red)
                                          : SparkVTheme.choose(apple: Color.black.opacity(0.62), sparkv: SparkVTheme.background.opacity(0.72))))
                .overlay(Circle().strokeBorder(hover.isOn && !SparkVTheme.isApple ? Color.clear : SparkVTheme.choose(apple: Color.white.opacity(0.22), sparkv: SparkVTheme.stroke), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help("Remove from Tray")
    }
}

/// The small ✨ button shown on a hovered card.
private struct TrayAIButton: View {
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hover.isOn || SparkVTheme.isApple ? Color.white : SparkVTheme.red)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover.isOn
                                          ? SparkVTheme.choose(apple: Color.black.opacity(0.82), sparkv: SparkVTheme.red)
                                          : SparkVTheme.choose(apple: Color.black.opacity(0.62), sparkv: SparkVTheme.background.opacity(0.72))))
                .overlay(Circle().strokeBorder(SparkVTheme.isApple ? Color.white.opacity(0.22) : (hover.isOn ? Color.clear : SparkVTheme.red.opacity(0.45)), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help("Ask AI about this")
    }
}
