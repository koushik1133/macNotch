import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One thing on the shelf.
struct TrayItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        /// A file: left where it is, or a copy the tray keeps itself when it
        /// came from a temporary folder or a file promise (Mail, Photos…).
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

/// Something the Tray can take back (⌘Z, or the header's Undo chip).
struct TrayUndo: Equatable {
    struct Removed: Equatable {
        let item: TrayItem
        let index: Int
        /// Where a tray-made copy went in the Trash, so Undo can bring it back.
        let trashedURL: URL?
    }

    enum Action: Equatable {
        case removed([Removed])
        case renamed(id: UUID, from: URL, to: URL)
    }

    let action: Action
    let title: String
    /// Set when lowering the Tray size dropped items: Undo also puts the
    /// size back, so the items fit again.
    var restoresCapacity: Int? = nil

    /// The empty Tray's button: "Put Back 5", "Put Back", "Undo Rename".
    var putBackTitle: String {
        switch action {
        case .removed(let list): list.count == 1 ? "Put Back" : "Put Back \(list.count)"
        case .renamed: "Undo Rename"
        }
    }
}

/// A Quick Look entry: the item and the file the preview shows.
struct TrayPreviewEntry: Equatable {
    let id: UUID
    let url: URL
}

/// Shelf for the things dropped on the notch: screenshots, text, links and
/// files. Holds up to `capacity` items (5 by default, up to 30), newest
/// first; survives relaunches unless the user turned that off, and can let
/// items expire. Tray-made copies go to the Trash, never straight to deletion.
@MainActor
final class TrayStore: ObservableObject {
    /// The default size of the shelf; the user picks 5–30 in Settings.
    static let capacity = ShelfSettings.defaultCapacity

    @Published private(set) var items: [TrayItem] = []
    /// Downsampled previews of image items, keyed by item id. Decoding a
    /// full-size screenshot on every redraw is far too slow for the drawer.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    private var thumbnailsLoading: Set<UUID> = []
    private static let thumbnailPixelSize = 160
    /// Cards picked with ⌘-click (toggle) or ⇧-click (range), or ⌘A: dragging
    /// any of them drags them all. Not persisted.
    @Published private(set) var selection: Set<UUID> = []
    /// The card the keyboard acts on (last clicked or arrowed to).
    @Published private(set) var focusedID: UUID?
    /// ⇧-click / ⇧-arrow range anchor.
    private var anchorID: UUID?
    /// What ⌘Z (and the header's Undo) puts back.
    @Published private(set) var undo: TrayUndo?
    /// The item being renamed in the header.
    @Published var renamingID: UUID?
    /// False for one change made from the keyboard: that shows at once.
    @Published private(set) var animatesChanges = true

    let settings: ShelfSettings
    /// How many items the shelf keeps.
    var capacity: Int { settings.capacity }

    private static let defaultsKey = "TrayItems.v2"
    private let storage: URL
    private let defaults: UserDefaults
    private let trashItem: @Sendable (URL) -> (moved: Bool, location: URL?)
    private var settingsObservers: Set<AnyCancellable> = []
    private var undoExpiry: Task<Void, Never>?
    /// Temporary .txt files for previewing text items, by item id.
    private var textPreviews: [UUID: URL] = [:]
    /// The size the Tray was last trimmed to (Undo after lowering it).
    private var appliedCapacity = ShelfSettings.defaultCapacity
    /// Storage files a background copy is still writing (names taken).
    private var pendingCopies: Set<URL> = []
    /// Files above this size from temporary folders are copied in off the
    /// main thread, so a big browser export doesn't freeze the drawer.
    nonisolated static let syncCopyLimit = 4 * 1024 * 1024

    /// `storage`, `defaults`, `trash`, `settings` and `trashLocation` are
    /// seams for tests; the app uses Application Support/SparkV/Tray, the
    /// standard defaults, the Trash and the shared settings.
    /// `trashLocation` returns where a file went (Undo can bring it back).
    init(storage: URL? = nil, defaults: UserDefaults = .standard,
         trash: (@Sendable (URL) -> Bool)? = nil, settings: ShelfSettings? = nil,
         trashLocation: (@Sendable (URL) -> URL?)? = nil) {
        let url = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Tray", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.storage = url
        self.defaults = defaults
        self.settings = settings ?? .shared
        if let trashLocation {
            trashItem = { url in
                let location = trashLocation(url)
                return (location != nil, location)
            }
        } else if let trash {
            trashItem = { (trash($0), nil) }
        } else {
            trashItem = { TrayStore.moveToTrashKeepingLocation($0) }
        }
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([TrayItem].self, from: data) {
            items = saved.filter { item in
                guard item.kind != .text else { return true }
                return item.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }
        }
        // "Keep items after restart" off: start empty. Done here, not at
        // quit, so it holds after a crash too; the copies go to the Trash below.
        if !self.settings.keepAcrossRestarts, !items.isEmpty {
            AppLog.log("Tray: starting empty (items aren't kept across restarts)")
            items = []
        }
        removeUnreferencedStorage()
        pruneExpired(save: false)
        trimToCapacity()
        appliedCapacity = capacity
        save()
        items.forEach(loadThumbnailIfNeeded)
        observeSettings()
    }

    private func observeSettings() {
        // @Published sends before the new value is stored: act on the next turn.
        settings.$capacity.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.capacityChanged() } }
        }.store(in: &settingsObservers)
        settings.$expiry.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pruneExpired() } }
        }.store(in: &settingsObservers)
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
            guard isOwned(item), let url = item.url else { return nil }
            return Self.canonicalPath(url)
        })
        var removed = 0
        for url in contents where !referenced.contains(Self.canonicalPath(url)) {
            if trashItem(url).moved { removed += 1 }
        }
        if removed > 0 {
            AppLog.log("Tray: moved \(removed) unreferenced file(s) from tray storage to the Trash")
        }
    }

    /// Tray-owned copies (often the only copy of a screenshot) are never
    /// destroyed outright: they go to the Trash, where the user can restore them.
    @discardableResult
    nonisolated static func moveToTrash(_ url: URL) -> Bool {
        moveToTrashKeepingLocation(url).moved
    }

    /// The same, also returning where the file landed in the Trash (for Undo).
    nonisolated static func moveToTrashKeepingLocation(_ url: URL) -> (moved: Bool, location: URL?) {
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return (true, resulting as URL?)
        } catch {
            AppLog.log("Tray: could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
            return (false, nil)
        }
    }

    nonisolated private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// True for files the tray made itself (screenshots, images, promised
    /// and temporary files it copied in): those live in its storage folder
    /// and go to the Trash when removed.
    func isOwned(_ item: TrayItem) -> Bool {
        guard item.kind != .text, let url = item.url else { return false }
        return isInStorage(url)
    }

    private func isInStorage(_ url: URL) -> Bool {
        Self.canonicalPath(url).hasPrefix(Self.canonicalPath(storage) + "/")
    }

    // MARK: Adding

    /// Takes whatever a drag carries, in order of preference: an image
    /// (including screenshot thumbnails, which are dragged as image data or a
    /// file promise rather than a file), a file, a link, a promised file
    /// (Mail attachments, Affinity and WeChat exports), then plain text.
    func accept(_ providers: [NSItemProvider]) {
        AppLog.log("Tray: drop with \(providers.count) item(s): \(providers.map(\.registeredTypeIdentifiers))")
        for provider in providers {
            switch ShelfDropResolver.route(types: provider.registeredTypeIdentifiers, suggestedName: provider.suggestedName) {
            case .image(let type):
                loadImage(from: provider, type: type)
            case .fileURL:
                loadFile(from: provider)
            case .link:
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.addText(url.absoluteString) }
                }
            case .promisedFile(let type):
                loadPromisedFile(from: provider, type: type)
            case .text:
                guard provider.canLoadObject(ofClass: String.self) else { continue }
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in self.addText(text) }
                }
            case .nothing:
                AppLog.log("Tray: nothing usable in \(provider.registeredTypeIdentifiers)")
            }
        }
    }

    /// File promises read straight from the drag (AppKit's receiver: the
    /// source app writes each file, the tray keeps it).
    func acceptPromises(_ receivers: [NSFilePromiseReceiver]) {
        AppLog.log("Tray: drop with \(receivers.count) promised file(s): \(receivers.flatMap(\.fileTypes))")
        ShelfDropResolver.receive(receivers) { [weak self] url in self?.addReceivedFile(url) }
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
           !isInStorage(fileURL), let data = try? Data(contentsOf: fileURL) {
            addImage(data: data, suggestedName: fileURL.deletingPathExtension().lastPathComponent,
                     fileExtension: fileURL.pathExtension)
            return
        }
        guard !items.contains(where: { $0.url == fileURL }) else { return }
        // A file in a temporary or cache folder (a browser's drag file, an
        // app's export) would vanish from the shelf: keep a copy instead.
        if ShelfDropResolver.isVolatile(fileURL), !isInStorage(fileURL) {
            // The same temp file dropped twice: the copy is already here.
            guard !hasOwnedCopy(of: fileURL) else { return }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= Self.syncCopyLimit {
                if let copy = copyIntoStorage(fileURL) {
                    insert(TrayItem(id: UUID(), kind: .file, url: copy, text: nil, addedAt: Date()))
                }
            } else {
                copyIntoStorageInBackground(fileURL)
            }
            return
        }
        insert(TrayItem(id: UUID(), kind: .file, url: fileURL, text: nil, addedAt: Date()))
    }

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !items.contains(where: { $0.kind == .text && $0.text == text }) else { return }
        insert(TrayItem(id: UUID(), kind: .text, url: nil, text: text, addedAt: Date()))
    }

    /// A file a promise wrote into a staging folder: moved into the tray's
    /// storage (it's the tray's own copy from now on).
    func addReceivedFile(_ staged: URL) {
        let fileManager = FileManager.default
        let ext = staged.pathExtension
        let name = Self.storageName(from: staged.lastPathComponent, fileExtension: ext)
        let destination = uniqueStorageURL(name: name, fileExtension: ext)
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            do {
                try fileManager.copyItem(at: staged, to: destination)
            } catch {
                AppLog.log("Tray: could not keep a received file: \(error.localizedDescription)")
                return
            }
        }
        // The per-drop staging folder is empty once its files moved in.
        let folder = staged.deletingLastPathComponent()
        if folder.path.contains("/SparkV-Incoming/"),
           (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
        }
        let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
        let item = TrayItem(id: UUID(), kind: isImage ? .image : .file, url: destination, text: nil, addedAt: Date())
        insert(item)
        loadThumbnailIfNeeded(item)
    }

    /// An owned copy with the same name and size as `source` (a temp file
    /// dropped again).
    private func hasOwnedCopy(of source: URL) -> Bool {
        let base = Self.storageName(from: source.deletingPathExtension().lastPathComponent, fileExtension: source.pathExtension)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if pendingCopies.contains(where: { $0.deletingPathExtension().lastPathComponent.hasPrefix(base) }) { return true }
        return items.contains { item in
            guard isOwned(item), let url = item.url, url.pathExtension == source.pathExtension,
                  url.deletingPathExtension().lastPathComponent.hasPrefix(base) else { return false }
            return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2) == size
        }
    }

    /// Copies a large temporary file in on a background task, then adds it.
    private func copyIntoStorageInBackground(_ source: URL) {
        let ext = source.pathExtension
        let destination = uniqueStorageURL(name: Self.storageName(from: source.deletingPathExtension().lastPathComponent,
                                                                  fileExtension: ext), fileExtension: ext)
        pendingCopies.insert(destination)
        AppLog.log("Tray: copying \(source.lastPathComponent) in")
        Task.detached(priority: .userInitiated) { [weak self] in
            let ok: Bool
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                ok = true
            } catch {
                ok = false
                AppLog.log("Tray: could not copy \(source.lastPathComponent) in: \(error.localizedDescription)")
            }
            await self?.finishBackgroundCopy(destination, ok: ok)
        }
    }

    private func finishBackgroundCopy(_ destination: URL, ok: Bool) {
        pendingCopies.remove(destination)
        if ok { insert(TrayItem(id: UUID(), kind: .file, url: destination, text: nil, addedAt: Date())) }
    }

    /// Waits for background copies (tests).
    var isCopying: Bool { !pendingCopies.isEmpty }

    private func copyIntoStorage(_ source: URL) -> URL? {
        let ext = source.pathExtension
        let destination = uniqueStorageURL(name: Self.storageName(from: source.deletingPathExtension().lastPathComponent,
                                                                  fileExtension: ext), fileExtension: ext)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            AppLog.log("Tray: could not copy \(source.lastPathComponent) in: \(error.localizedDescription)")
            return nil
        }
    }

    private func uniqueStorageURL(name: String, fileExtension: String) -> URL {
        func make(_ base: String) -> URL {
            let url = storage.appendingPathComponent(base)
            return fileExtension.isEmpty ? url : url.appendingPathExtension(fileExtension)
        }
        var destination = make(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) || pendingCopies.contains(destination) {
            destination = make("\(name) \(counter)")
            counter += 1
        }
        return destination
    }

    private func addImage(data: Data, suggestedName: String, fileExtension: String) {
        let name = Self.storageName(from: suggestedName, fileExtension: fileExtension)
        let destination = uniqueStorageURL(name: name, fileExtension: fileExtension)
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
        pruneExpired(save: false)
        trimToCapacity()
        AppLog.log("Tray: added \(item.kind.rawValue) (\(item.displayName.count) chars)")
        save()
        SpaceIngestCenter.tray(item)
    }

    // MARK: Limits

    /// Drops the oldest items beyond `capacity` (tray copies to the Trash).
    @discardableResult
    private func trimToCapacity(saving: Bool = false) -> [TrayUndo.Removed] {
        var removed: [TrayUndo.Removed] = []
        while items.count > capacity {
            let index = items.count - 1
            let item = items.removeLast()
            removed.append(TrayUndo.Removed(item: item, index: index, trashedURL: discardStorage(of: item)))
        }
        if !removed.isEmpty, saving { save() }
        return removed
    }

    /// The Tray size changed in Settings or the gear menu. Lowering it drops
    /// the oldest items at once, with Undo (which also puts the size back),
    /// never silently.
    func capacityChanged() {
        let previous = appliedCapacity
        appliedCapacity = capacity
        let removed = trimToCapacity(saving: true)
        guard !removed.isEmpty else { return }
        if let renamingID, removed.contains(where: { $0.item.id == renamingID }) { self.renamingID = nil }
        if let focusedID, removed.contains(where: { $0.item.id == focusedID }) { self.focusedID = nil }
        AppLog.log("Tray: size lowered to \(capacity), \(removed.count) item(s) removed (Undo puts them back)")
        registerUndo(TrayUndo(action: .removed(removed.reversed()),
                              title: removed.count == 1 ? "Removed" : "Removed \(removed.count)",
                              restoresCapacity: previous))
    }

    /// Removes items older than the expiry setting. Runs on launch, when an
    /// item is added and when the drawer shows the Tray: no timer.
    func pruneExpired(now: Date = Date(), save shouldSave: Bool = true) {
        guard let interval = settings.expiry.interval else { return }
        let cutoff = now.addingTimeInterval(-interval)
        let expired = items.filter { $0.addedAt < cutoff }
        guard !expired.isEmpty else { return }
        let ids = Set(expired.map(\.id))
        expired.forEach { _ = discardStorage(of: $0) }
        items.removeAll { ids.contains($0.id) }
        AppLog.log("Tray: \(expired.count) item(s) expired")
        if shouldSave { save() }
    }

    // MARK: Removing

    func remove(_ item: TrayItem) {
        remove(ids: [item.id])
    }

    /// Removes items; ⌘Z or the header's Undo puts them back (tray copies
    /// come back out of the Trash).
    func remove(ids: [UUID]) {
        let targets = Set(ids)
        var removed: [TrayUndo.Removed] = []
        for (index, item) in items.enumerated() where targets.contains(item.id) {
            removed.append(TrayUndo.Removed(item: item, index: index, trashedURL: discardStorage(of: item)))
        }
        guard !removed.isEmpty else { return }
        let nextFocus = focusedID.flatMap { id -> UUID? in
            guard targets.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return id }
            let rest = items.enumerated().filter { !targets.contains($0.element.id) }
            return (rest.first { $0.offset > index } ?? rest.last)?.element.id
        }
        items.removeAll { targets.contains($0.id) }
        focusedID = nextFocus
        if let renamingID, targets.contains(renamingID) { self.renamingID = nil }
        save()
        registerUndo(TrayUndo(action: .removed(removed), title: removed.count == 1 ? "Removed" : "Removed \(removed.count)"))
    }

    func clear() {
        remove(ids: items.map(\.id))
    }

    /// Only copies the tray made itself are touched, and they go to the
    /// Trash; dropped files stay put. Returns where the copy went.
    private func discardStorage(of item: TrayItem) -> URL? {
        selection.remove(item.id)
        thumbnails[item.id] = nil
        thumbnailsLoading.remove(item.id)
        if let preview = textPreviews.removeValue(forKey: item.id) { try? FileManager.default.removeItem(at: preview) }
        guard isOwned(item), let url = item.url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return trashItem(url).location
    }

    // MARK: Undo

    private func registerUndo(_ undo: TrayUndo) {
        self.undo = undo
        undoExpiry?.cancel()
        // The chip and ⌘Z stay for a few seconds, like the Finder's.
        undoExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    func undoLast() {
        guard let undo else { return }
        self.undo = nil
        undoExpiry?.cancel()
        switch undo.action {
        case .removed(let list):
            if let size = undo.restoresCapacity, size > capacity {
                settings.capacity = size
                appliedCapacity = size
            }
            var restored = 0
            for entry in list.sorted(by: { $0.index < $1.index }) {
                let item = entry.item
                guard !items.contains(where: { $0.id == item.id }) else { continue }
                if let trashed = entry.trashedURL, let original = item.url, !FileManager.default.fileExists(atPath: original.path) {
                    do {
                        try FileManager.default.moveItem(at: trashed, to: original)
                    } catch {
                        AppLog.log("Tray: could not bring \(original.lastPathComponent) back from the Trash")
                        continue
                    }
                }
                if item.kind != .text, let url = item.url, !FileManager.default.fileExists(atPath: url.path) { continue }
                items.insert(item, at: min(entry.index, items.count))
                loadThumbnailIfNeeded(item)
                restored += 1
            }
            trimToCapacity()
            save()
            AppLog.log("Tray: put back \(restored) item(s)")
        case .renamed(let id, let from, let to):
            do {
                try FileDropOps.undoRename(FileDropRename(itemID: id, from: from, to: to))
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].url = from }
                save()
            } catch {
                AppLog.log("Tray: could not undo the rename: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Rename

    /// Renames a file or image on disk (a tray copy in the tray's folder, a
    /// dropped file where it is). Returns an error message, or nil.
    @discardableResult
    func rename(_ item: TrayItem, to rawName: String) -> String? {
        guard item.kind != .text, let url = item.url, let index = items.firstIndex(where: { $0.id == item.id }) else {
            return "Only files can be renamed"
        }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
        let name = FileDropOps.cleanTypedName(rawName, extension: isFolder ? nil : url.pathExtension)
        guard !name.isEmpty else { return "Type a name first" }
        let current = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        guard name != current else {
            renamingID = nil
            return nil
        }
        do {
            let newURL = try FileDropOps.rename(url, toBaseName: name)
            items[index].url = newURL
            renamingID = nil
            save()
            registerUndo(TrayUndo(action: .renamed(id: item.id, from: url, to: newURL), title: "Renamed"))
            AppLog.log("Tray: renamed an item")
            return nil
        } catch {
            return error.localizedDescription
        }
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

    /// Several items at once, the way they'd be dragged.
    func copyToClipboard(_ list: [TrayItem], pasteboard: NSPasteboard = .general) {
        guard list.count > 1 else {
            if let item = list.first { copyToClipboard(item, pasteboard: pasteboard) }
            return
        }
        let writers = list.compactMap(\.pasteboardWriter)
        guard !writers.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
    }

    func dragProvider(for item: TrayItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            NSItemProvider(object: (item.text ?? "") as NSString)
        case .image, .file:
            item.url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        }
    }

    /// Files for Quick Look, in shelf order. Text items preview as a
    /// temporary .txt (removed with the item).
    func quickLookEntries(for list: [TrayItem]) -> [TrayPreviewEntry] {
        list.compactMap { item -> TrayPreviewEntry? in
            switch item.kind {
            case .file, .image:
                guard let url = item.url, FileManager.default.fileExists(atPath: url.path) else { return nil }
                return TrayPreviewEntry(id: item.id, url: url)
            case .text:
                if let existing = textPreviews[item.id], FileManager.default.fileExists(atPath: existing.path) {
                    return TrayPreviewEntry(id: item.id, url: existing)
                }
                guard let text = item.text, let file = AirDrop.temporaryTextFile(text) else { return nil }
                textPreviews[item.id] = file
                return TrayPreviewEntry(id: item.id, url: file)
            }
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
    static func storageName(from suggestedName: String, fileExtension: String) -> String {
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

    /// A promised (or raw data) file: the source app writes it, the tray
    /// keeps the copy.
    private func loadPromisedFile(from provider: NSItemProvider, type: String) {
        Task { @MainActor in
            guard let staged = await ShelfDropResolver.loadPromisedFile(provider, type: type) else {
                AppLog.log("Tray: a promised \(type) file never arrived")
                return
            }
            self.addReceivedFile(staged)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Drags out that moved files

    /// After a drag out: a dropped file the destination *moved* (Finder,
    /// same disk, or ⌘ held) isn't where the tray points any more, so its
    /// card goes (nothing is trashed: the file is safe where it went).
    /// Dropped on the Dock's Trash (`.delete`): the file is in the Trash
    /// now, so the card goes too, Tray copies included.
    func dragEnded(ids: [UUID], operation: NSDragOperation) {
        let trashed = operation.contains(.delete)
        guard trashed || operation.contains(.move) || operation.contains(.generic) else { return }
        let targets = Set(ids)
        let gone = items.filter { item in
            guard targets.contains(item.id), item.kind != .text, trashed || !isOwned(item), let url = item.url else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        guard !gone.isEmpty else { return }
        let goneIDs = Set(gone.map(\.id))
        items.removeAll { goneIDs.contains($0.id) }
        selection.subtract(goneIDs)
        if let focusedID, goneIDs.contains(focusedID) { self.focusedID = nil }
        save()
        gone.forEach { thumbnails[$0.id] = nil }
        AppLog.log(trashed ? "Tray: \(gone.count) file(s) dragged to the Trash" : "Tray: \(gone.count) file(s) moved out of the tray")
    }

    /// Marks the next change as keyboard-made (no animation).
    func keyboardChange() {
        animatesChanges = false
        DispatchQueue.main.async { MainActor.assumeIsolated { self.animatesChanges = true } }
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
    /// A file the Tray only points to (not a tray-made copy): a drag may
    /// move it (Shelf settings: Copy with ⌘ to move, or like Finder).
    var canMove = false
}

extension TrayStore {
    /// Size of the drag image, matching the preview drawn in the tray.
    static let dragImageSize = CGSize(width: 52, height: 40)

    func dragPayload(for item: TrayItem) -> TrayDragPayload? {
        guard let writer = item.pasteboardWriter else { return nil }
        // Tray-made copies always copy out, or the card would lose its file.
        return TrayDragPayload(writer: writer, image: dragImage(for: item), canMove: item.kind == .file && !isOwned(item))
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

    // MARK: Selection (⌘-click, ⇧-click, ⌘A) and keyboard focus

    func isSelected(_ item: TrayItem) -> Bool { selection.contains(item.id) }

    func isFocused(_ item: TrayItem) -> Bool { focusedID == item.id }

    func toggleSelection(_ item: TrayItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        if selection.remove(item.id) == nil { selection.insert(item.id) }
        focusedID = item.id
        anchorID = item.id
    }

    func clearSelection() {
        if !selection.isEmpty { selection.removeAll() }
    }

    func selectAll() {
        selection = Set(items.map(\.id))
        if focusedID == nil { focusedID = items.first?.id }
    }

    /// A plain click: the card gets the keyboard focus, the multi-selection goes.
    func focus(_ item: TrayItem) {
        clearSelection()
        focusedID = item.id
        anchorID = item.id
    }

    /// Quick Look paged to another item.
    func focus(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        focusedID = id
    }

    /// ⌘-click toggles one card; ⇧-click selects the run from the last
    /// clicked card (Finder's list view).
    func click(_ item: TrayItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = anchorID ?? focusedID,
           let from = items.firstIndex(where: { $0.id == anchor }), let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = min(from, to)...max(from, to)
            let run = Set(items[range].map(\.id))
            selection = modifiers.contains(.command) ? selection.union(run) : run
            focusedID = item.id
        } else {
            toggleSelection(item)
        }
    }

    /// ← / →: moves the focus; with ⇧ it extends the selection from the anchor.
    func moveFocus(forward: Bool, extending: Bool) {
        guard !items.isEmpty else { return }
        let current = focusedID.flatMap { id in items.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = min(max(current + (forward ? 1 : -1), 0), items.count - 1)
        } else {
            next = forward ? 0 : items.count - 1
        }
        let target = items[next].id
        if extending {
            let anchor = anchorID ?? focusedID ?? target
            anchorID = anchor
            if let from = items.firstIndex(where: { $0.id == anchor }) {
                selection = Set(items[min(from, next)...max(from, next)].map(\.id))
            }
        } else {
            clearSelection()
            anchorID = target
        }
        focusedID = target
    }

    /// What the keyboard acts on: the selection (in shelf order), else the
    /// focused card.
    var keyboardTargets: [TrayItem] {
        if !selection.isEmpty { return items.filter { selection.contains($0.id) } }
        guard let focusedID, let item = items.first(where: { $0.id == focusedID }) else { return [] }
        return [item]
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
        let icon: NSImage? = item.kind == .file ? item.url.map { TrayFileIcons.icon(for: $0) } : nil
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
    /// Like `onCommandClick`, with the modifiers (⇧ range vs ⌘ toggle);
    /// used instead of it when set.
    var onModifiedClick: ((NSEvent.ModifierFlags) -> Void)?
    /// Any press, before click or drag is known (the Tray takes the keyboard here).
    var onPress: (() -> Void)?
    /// A click makes the non-activating panel key, so keys reach the view's
    /// owner (the Tray's Space / Delete / arrows). Off for other shelves.
    var takesKeyboardFocus = false
    /// The Tray item this view stands for: Quick Look zooms from it.
    var quickLookID: UUID? {
        didSet { if let quickLookID, quickLookID != oldValue { TrayQuickLook.shared.register(self, for: quickLookID) } }
    }
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
    /// Every dragged file is one the Tray only points to (a move is allowed).
    private var draggingCanMove = false
    private var draggingCount = 0

    /// Pointer travel before a press turns into a drag.
    static let dragThreshold: CGFloat = 3

    override var isFlipped: Bool { true }
    // The panel never becomes key in an active app: take the very first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The notch panel becomes key only for views that ask (`becomesKeyOnlyIfNeeded`).
    override var needsPanelToBecomeKey: Bool { takesKeyboardFocus }

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
        onPress?()
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
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if event.clickCount == 1, !modifiers.isEmpty, onModifiedClick != nil || onCommandClick != nil {
            pendingClick?.cancel()
            pendingClick = nil
            if let onModifiedClick { onModifiedClick(modifiers) } else { onCommandClick?() }
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
        draggingCanMove = payloads.allSatisfy(\.canMove)
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
    /// and `.move` as a move on the same volume). Files the Tray only points
    /// to may move: with ⌘ held in the default mode, or the way Finder does
    /// it (same disk moves, ⌥ copies) in "Like Finder" mode. Inside the app:
    /// nothing, so dropping back on the drawer doesn't add a duplicate.
    nonisolated static func operationMask(for context: NSDraggingContext, textOnly: Bool, canMove: Bool = false,
                                          mode: ShelfSettings.DragOut = .copy, commandHeld: Bool = false) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            if textOnly { return [.copy, .generic] }
            guard canMove else { return .copy }
            switch mode {
            case .finder: return [.copy, .move, .generic]
            case .copy: return commandHeld ? [.move, .generic] : .copy
            }
        case .withinApplication: return []
        @unknown default: return .copy
        }
    }

    /// The mode in effect (AppKit asks on the main thread).
    private var dragOutMode: ShelfSettings.DragOut { ShelfSettings.shared.dragOut }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operationMask(for: context, textOnly: draggingTextOnly, canMove: draggingCanMove, mode: dragOutMode,
                           commandHeld: NSEvent.modifierFlags.contains(.command))
    }

    /// Cmd/Option would otherwise filter the mask down to an operation we
    /// don't offer and make the drop fail. "Like Finder" lets them through:
    /// that mask offers every operation they pick.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        !(draggingCanMove && dragOutMode == .finder)
    }

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
    var onModifiedClick: ((NSEvent.ModifierFlags) -> Void)? = nil
    var onPress: (() -> Void)? = nil
    var takesKeyboardFocus = false
    var quickLookID: UUID? = nil

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
        view.onModifiedClick = onModifiedClick
        view.onPress = onPress
        view.takesKeyboardFocus = takesKeyboardFocus
        view.quickLookID = quickLookID
        view.makeMenu = menu
        view.onHoverChange = onHoverChange
        view.passThroughTopTrailing = passThroughTopTrailing
        view.passThroughTopLeading = passThroughTopLeading
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}

/// Menu item that runs a closure (NSMenuItem's target is weak, so the item
/// is its own target). `key` shows a shortcut that works while the Tray
/// has the keyboard (the item itself doesn't bind it).
final class TrayMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, systemImage: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [],
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
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
    /// The keyboard focus ring (lighter than a selection).
    static var focusTint: Color { SparkVTheme.isApple ? Color.white.opacity(0.75) : SparkVTheme.red.opacity(0.75) }
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

/// Share menu / Nearby panel on tray items.
@MainActor
private func shareTrayItems(_ items: [TrayItem]) {
    ShelfShare.presentAtPointer(ShelfShare.objects(for: items), localSendFiles: { ShelfShare.fileURLs(for: items) })
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
                            ScrollViewReader { reader in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: TrayLayout.cardSpacing) {
                                        ForEach(Array(tray.items.enumerated()), id: \.element.id) { index, item in
                                            TrayCardView(item: item, side: side)
                                                .id(item.id)
                                                .sparkVStaggeredEntrance(appeared.isOn, index: index)
                                                .transition(.opacity.combined(with: .scale(scale: SparkVMotion.enterScale)))
                                        }
                                    }
                                    .padding(TrayLayout.wellPadding)
                                    // New and removed cards slide the row instead of
                                    // jumping; keyboard changes show at once.
                                    .animation(tray.animatesChanges ? SparkVMotion.respecting(SparkVMotion.easeOut()) : nil,
                                               value: tray.items.map(\.id))
                                }
                                // Arrow keys keep the focused card in view (instantly).
                                .onChange(of: tray.focusedID) { _, id in
                                    guard let id else { return }
                                    reader.scrollTo(id)
                                }
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
        // The Tray's keyboard target and Quick Look controller.
        .background(TrayKeyResponder().frame(width: 1, height: 1).opacity(0).accessibilityHidden(true))
        .onAppear {
            appeared.isOn = true
            tray.pruneExpired()
            TrayKeyboard.shared.attach(tray: tray, state: state)
        }
        .onDisappear {
            appeared.isOn = false
            TrayKeyboard.shared.detach(drawerOpen: state.isExpanded)
        }
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
                if let undo = tray.undo {
                    TrayActionButton(title: undo.putBackTitle, systemImage: "arrow.uturn.backward",
                                     tint: TrayLayout.selectionTint) { tray.undoLast() }
                        .help("Put back what was just removed (⌘Z)")
                        .transition(.opacity)
                }
            }
            .animation(tray.animatesChanges ? SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)) : nil, value: tray.undo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Count, quick actions and the "All" drag handle above the well; the
/// rename field while a card is being renamed.
private struct TrayHeader: View {
    @EnvironmentObject private var tray: TrayStore
    @ObservedObject private var keyboard = TrayKeyboard.shared

    var body: some View {
        Group {
            if let id = tray.renamingID, let item = tray.items.first(where: { $0.id == id }) {
                TrayRenameBar(item: item)
                    .transition(.opacity)
            } else {
                actions
                    .transition(.opacity)
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: tray.renamingID)
    }

    private var actions: some View {
        let images = tray.items.filter { $0.kind == .image }
        return HStack(spacing: 5) {
            if let undo = tray.undo {
                TrayActionButton(title: "\(undo.title) · Undo", systemImage: "arrow.uturn.backward", height: TrayLayout.headerHeight,
                                 tint: TrayLayout.selectionTint) {
                    tray.undoLast()
                }
                .help("Put it back (⌘Z)")
                .transition(.opacity)
            } else if tray.selection.isEmpty {
                Text("\(tray.items.count)/\(tray.capacity)")
                    .font(SparkVTheme.eyebrow(9.5))
                    .tracking(0.6)
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .padding(.leading, 6)
                    .help("⌘-click or ⇧-click cards to pick several, then drag any of them · click a card, then Space for Quick Look")
                if keyboard.hasFocus {
                    HStack(spacing: 3) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("Space to preview")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
                    .accessibilityLabel("Keyboard: Space previews, arrows move, Delete removes")
                }
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
            TrayActionButton(title: nil, systemImage: "square.and.arrow.up", height: TrayLayout.headerHeight) {
                shareTrayItems(tray.selection.isEmpty ? tray.items : tray.keyboardTargets)
            }
            .help(tray.selection.isEmpty ? "Share all: AirDrop, Messages, NearDrop, LocalSend…" : "Share the \(tray.selection.count) picked items")
            .accessibilityLabel("Share")
            TrayClearButton()
            if tray.items.count > 1 {
                TrayDragAllHandle()
            }
        }
        .animation(tray.animatesChanges ? SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)) : nil, value: tray.undo)
        .animation(SparkVMotion.hover(), value: keyboard.hasFocus)
    }
}

/// Holds the rename field's text and error (no `@State` with the CLT toolchain).
@MainActor
private final class TrayRenameDraft: ObservableObject {
    @Published var text = ""
    @Published var error: String?
    var loadedFor: UUID?
}

/// "Rename  [name].png  ✓ ✕" in place of the header; Return renames, Esc cancels.
private struct TrayRenameBar: View {
    @EnvironmentObject private var tray: TrayStore
    let item: TrayItem
    @StateObject private var draft = TrayRenameDraft()

    var body: some View {
        let ext = isFolder ? "" : (item.url?.pathExtension ?? "")
        HStack(spacing: 5) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .padding(.leading, 5)
            HStack(spacing: 1) {
                TrayRenameField(text: Binding(get: { draft.text }, set: { draft.text = $0; draft.error = nil }),
                                onCommit: commit, onCancel: cancel)
                if !ext.isEmpty {
                    Text(".\(ext)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: TrayLayout.headerHeight)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(draft.error == nil ? TrayLayout.selectionTint.opacity(0.8) : SparkVTheme.warning, lineWidth: 1))
            if let error = draft.error {
                Text(error)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.warning)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            TrayActionButton(title: "Rename", systemImage: "checkmark", height: TrayLayout.headerHeight,
                             tint: TrayLayout.selectionTint, action: commit)
                .help("Rename (Return)")
            TrayActionButton(title: nil, systemImage: "xmark", height: TrayLayout.headerHeight, action: cancel)
                .help("Cancel (Esc)")
        }
        .onAppear(perform: load)
        .onChange(of: item.id) { _, _ in load() }
    }

    private var isFolder: Bool {
        guard let url = item.url else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
    }

    private func load() {
        guard draft.loadedFor != item.id, let url = item.url else { return }
        draft.loadedFor = item.id
        draft.text = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        draft.error = nil
    }

    private func commit() {
        if let error = tray.rename(item, to: draft.text) {
            draft.error = error
            return
        }
        TrayKeyboard.shared.returnFocusAfterEditing()
    }

    private func cancel() {
        tray.renamingID = nil
        TrayKeyboard.shared.returnFocusAfterEditing()
    }
}

/// A plain AppKit text field (takes the keyboard by itself when it appears,
/// which makes the non-activating notch panel key): Return commits, Esc cancels.
private struct TrayRenameField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TrayRenameTextField {
        let field = TrayRenameTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 10.5, weight: .medium)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityLabel("New name")
        return field
    }

    func updateNSView(_ field: TrayRenameTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TrayRenameField
        init(_ parent: TrayRenameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Focuses itself, with the whole name selected, as soon as it's on screen.
final class TrayRenameTextField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window === window else { return }
                if !window.isKeyWindow, window.canBecomeKey { window.makeKey() }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
}

/// Clearing asks first: the first click turns the button into a red
/// "Clear 3?" capsule for a few seconds, a second click clears (and the
/// header then offers Undo).
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
                .help("Click again to remove every item (tray copies go to the Trash; Undo puts them back)")
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
                .accessibilityLabel("Clear tray")
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
                onClick: { copyAll() },
                onDragEnded: { [tray] operation in tray.dragEnded(ids: tray.items.map(\.id), operation: operation) }
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drag all items")
        .accessibilityAction(named: "Copy All") { copyAll() }
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
            AirDrop.share(tray.selection.isEmpty ? tray.items : tray.keyboardTargets)
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
              : (tray.selection.isEmpty
                 ? "Click to AirDrop \(count == 1 ? "the item" : "all \(count) items") · drop files here to AirDrop them"
                 : "Click to AirDrop the \(tray.selection.count) picked items"))
    }
}

/// One square shelf card. AppKit owns the mouse over it: drag = drag out,
/// click = copy (and keyboard focus), ⌘/⇧-click = pick, double-click = open,
/// right/control-click = menu; hovering shows ✕ and a ✨ button that asks AI.
private struct TrayCardView: View {
    @EnvironmentObject private var tray: TrayStore
    @ObservedObject private var keyboard = TrayKeyboard.shared
    let item: TrayItem
    let side: CGFloat

    @StateObject private var copied = ViewFlag()
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TrayLayout.cardCorner, style: .continuous)
        let hovered = hover.isOn
        let selected = tray.isSelected(item)
        // The card whose name is being edited in the header.
        let renaming = tray.renamingID == item.id
        let focused = keyboard.hasFocus && tray.isFocused(item) && !selected
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
            shape.strokeBorder(selected || renaming ? TrayLayout.selectionTint
                               : (focused ? TrayLayout.focusTint
                                  : (hovered ? SparkVTheme.choose(apple: Color.white.opacity(0.3), sparkv: SparkVTheme.red.opacity(0.55))
                                     : SparkVTheme.choose(apple: Color.white.opacity(0.08), sparkv: SparkVTheme.stroke))),
                               lineWidth: selected || renaming ? 2.5 : (focused ? 2 : 1))
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
                    tray.focus(item)
                    copy()
                },
                onDoubleClick: item.kind == .text ? nil : { open() },
                menu: { makeMenu() },
                onHoverChange: { hover.isOn = $0 },
                passThroughTopTrailing: hovered ? TrayLayout.aiButtonCorner : .zero,
                passThroughTopLeading: hovered ? TrayLayout.aiButtonCorner : .zero,
                onCommandClick: { tray.toggleSelection(item) },
                onDragEnded: { [tray, item] operation in
                    tray.dragEnded(ids: tray.itemsToDrag(startingWith: item).map(\.id), operation: operation)
                },
                onModifiedClick: { modifiers in tray.click(item, modifiers: modifiers) },
                onPress: { TrayKeyboard.shared.focusFromClick() },
                takesKeyboardFocus: true,
                quickLookID: item.id
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
        .animation(tray.animatesChanges ? SparkVMotion.hover() : nil, value: selected)
        // Focus moves with the keys: no animation.
        .animation(nil, value: focused)
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.hover), value: copied.isOn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { copy() }
        .accessibilityActions { accessibilityActionButtons }
    }

    /// VoiceOver actions: the right-click menu and the hover-only ✕ and ✨.
    @ViewBuilder
    private var accessibilityActionButtons: some View {
        Button("Quick Look") { TrayKeyboard.showQuickLook(tray, startingAt: item) }
        Button(item.kind == .text ? "Copy" : "Open") { item.kind == .text ? copy() : open() }
        Button(tray.isSelected(item) ? "Deselect" : "Select") { tray.toggleSelection(item) }
        Button("Share") { shareTrayItems([item]) }
        Button("Remove from Tray") { tray.remove(item) }
        Button("Ask AI") { askAI() }
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
                    Image(nsImage: TrayFileIcons.icon(for: url))
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

    private var accessibilityTitle: String {
        switch item.kind {
        case .image: "Image, \(label)"
        case .file: "File, \(label)"
        case .text: link == nil ? "Text, \(label)" : "Link, \(label)"
        }
    }

    // MARK: Actions

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tray = tray
        let item = item
        // A right-click on a picked card acts on every picked card.
        let group = tray.isSelected(item) && tray.selection.count > 1 ? tray.keyboardTargets : [item]
        let several = group.count > 1
        menu.addItem(TrayMenuItem(several ? "Copy \(group.count) Items" : "Copy", systemImage: "doc.on.doc", key: "c", modifiers: .command) {
            if several { tray.copyToClipboard(group) } else { copy() }
        })
        menu.addItem(TrayMenuItem("Quick Look", systemImage: "eye", key: " ") {
            TrayKeyboard.showQuickLook(tray, startingAt: several ? nil : item)
        })
        if item.kind != .text {
            menu.addItem(TrayMenuItem("Open", systemImage: "arrow.up.forward.app") { open() })
            menu.addItem(TrayMenuItem("Show in Finder", systemImage: "folder") {
                let urls = group.compactMap(\.url)
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            })
            if !several {
                menu.addItem(TrayMenuItem("Rename…", systemImage: "character.cursor.ibeam") {
                    tray.renamingID = item.id
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ShelfShare.menuItem(for: ShelfShare.objects(for: group), localSendFiles: { ShelfShare.fileURLs(for: group) }))
        menu.addItem(TrayMenuItem("AirDrop", systemImage: "dot.radiowaves.left.and.right") { AirDrop.share(group) })
        menu.addItem(TrayMenuItem("Send to Android / Windows…", systemImage: "wave.3.right") {
            LocalSendPanelController.shared.open(files: ShelfShare.fileURLs(for: group))
        })
        menu.addItem(TrayMenuItem("Ask AI…", systemImage: "sparkles") { openTrayAI(group, tray: tray) })
        menu.addItem(.separator())
        if !several, !tray.isSelected(item) {
            menu.addItem(TrayMenuItem("Select", systemImage: "checkmark.circle") { tray.toggleSelection(item) })
        }
        menu.addItem(TrayMenuItem("Select All", systemImage: "checkmark.circle.badge.questionmark", key: "a", modifiers: .command) {
            tray.selectAll()
        })
        menu.addItem(.separator())
        menu.addItem(TrayMenuItem(several ? "Remove \(group.count) from Tray" : "Remove from Tray", systemImage: "trash",
                                  key: "\u{8}") {
            tray.remove(ids: group.map(\.id))
        })
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
/// dropped file stays where it is; a tray-made copy goes to the Trash; the
/// header offers Undo).
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
        .accessibilityLabel("Remove from Tray")
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
        .accessibilityLabel("Ask AI")
    }
}

/// File icons for Tray cards, looked up once per path (a LaunchServices and
/// file-system call) instead of on every redraw of the card body.
@MainActor
enum TrayFileIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
