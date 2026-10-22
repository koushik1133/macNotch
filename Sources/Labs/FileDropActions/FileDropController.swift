import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// File drop actions: drop files on the shelf that appears under the notch
/// while a file drag nears it (or on the File Drop tab of the drawer), then
/// Rename / Compress / Convert / Send to a Space / AirDrop / Tray / Reveal.
///
/// Flow modelled on Dropover (instant-action buckets that run on drop, a
/// shelf whose results drag out anywhere), Yoink (a shelf that appears only
/// while dragging, files kept by reference, never moved) and NotchNook (the
/// drop zone grows out of the notch). See DESIGN.md.
@MainActor
final class FileDropController: ObservableObject {
    // MARK: Wiring (set by NotchWindowController; see INTEGRATION.md)

    /// Tab the result band opens when hovered (the lead's `.fileDrop`).
    var activityOpensTab: NotchState.Tab?
    /// Open the drawer on the File Drop tab.
    var onOpenStrip: (() -> Void)?
    /// Open the drawer on the converter tab (after `converter.add`).
    var onOpenConverter: (() -> Void)?
    /// Keep files in the Tray (`tray.addFile`).
    var onAddToTray: (([URL]) -> Void)?
    weak var converter: ConverterController?
    /// True while the drawer is open: the shelf stays hidden then.
    var isDrawerExpanded: () -> Bool = { false }
    /// The Spaces store, resolved lazily so creating the controller never
    /// loads the database (tests swap in their own).
    var spaceStore: () -> SpaceStore = { SpaceStore.shared }

    // MARK: State

    @Published private(set) var items: [FileDropItem] = []
    @Published private(set) var mode: FileDropMode = .empty
    @Published private(set) var note: FileDropNote?
    /// Thumbnails by file path.
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    /// The rename field's text.
    @Published var renameText = ""
    @Published private(set) var renameDrafts: [UUID: FileDropRenameDraft] = [:]
    /// The last action that can be undone (survives going back to the actions row).
    @Published private(set) var lastUndo: FileDropUndo?
    @Published private(set) var isZoneVisible = false
    /// Spaces offered by the picker (current persona).
    @Published private(set) var spaces: [Space] = []

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: FileDropSettings.enabledKey)
            if !isEnabled { hideZone() }
        }
    }
    /// Show the drop shelf under the notch while dragging files.
    @Published var showsShelf: Bool {
        didSet {
            defaults.set(showsShelf, forKey: FileDropSettings.zoneKey)
            if !showsShelf { hideZone() }
        }
    }
    @Published var nameStyle: FileDropSettings.NameStyle {
        didSet { defaults.set(nameStyle.rawValue, forKey: FileDropSettings.nameStyleKey) }
    }

    private let activities: ActivityCenter
    private let defaults: UserDefaults
    private let watcher: FileDropDragWatcher
    private var zonePanel: FileDropZonePanel?
    private var zoneHide: Task<Void, Never>?
    private var noteClear: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var resuggestTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var renames: [FileDropRename] = []
    /// The text the rename field had when SparkV last filled it, so a
    /// late suggestion never overwrites what the user typed.
    private var autoFilledText = ""
    /// A drop on an instant bucket (Compress, To Space, AirDrop) that came
    /// in while another action was running: it runs when that one ends.
    private var pendingInstant: (urls: [URL], instant: FileDropInstant)?
    /// When a drop on the shelf's Actions bucket opened the drawer, and
    /// where the shelf was (see `holdsDrawerOpen`).
    private var shelfDropAt: Date?
    private var lastZoneFrame: NSRect?
    static let activityID = "fileDrop.done"

    init(activities: ActivityCenter, defaults: UserDefaults = .standard, dragPasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        self.activities = activities
        self.defaults = defaults
        watcher = FileDropDragWatcher(pasteboard: dragPasteboard)
        isEnabled = defaults.object(forKey: FileDropSettings.enabledKey) as? Bool ?? true
        showsShelf = defaults.object(forKey: FileDropSettings.zoneKey) as? Bool ?? true
        nameStyle = FileDropSettings.NameStyle(rawValue: defaults.string(forKey: FileDropSettings.nameStyleKey) ?? "") ?? .words
        watcher.onEvent = { [weak self] event in self?.handleDrag(event) }
    }

    func start() {
        watcher.start()
        AirDrop.pruneTemporaryFolder("SparkV-AirDrop")
        if isEnabled { FileDropNamer.prewarmVision() }
    }

    func stop() {
        watcher.stop()
        hideZone(immediately: true)
        suggestTask?.cancel()
        resuggestTask?.cancel()
        workTask?.cancel()
    }

    // MARK: Shelf under the notch

    /// True when the point is over the visible shelf (the lead skips the
    /// hover-to-expand there so the drawer doesn't open over it).
    func zoneContains(_ point: NSPoint) -> Bool {
        guard isZoneVisible, let frame = zonePanel?.frame else { return false }
        return frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// True for a few seconds after a drop on the shelf's Actions bucket
    /// opened the drawer, while the pointer is still where the shelf was.
    /// The shelf can sit below the open drawer (under a live-activity band),
    /// so without this the drawer would close again under the pointer. The
    /// lead adds it to `isInteractionInProgress`.
    ///
    /// It is also true for the whole of any drag *out* of a SparkV shelf
    /// (`TrayDragOut`: Tray cards, these piles, Converter and Clipboard
    /// cards), plus the slide-back of a cancelled one, so the drawer never
    /// closes under a drag that started in it.
    var holdsDrawerOpen: Bool {
        if TrayDragOut.holdsDrawerOpen { return true }
        guard let at = shelfDropAt, Date().timeIntervalSince(at) < 8, let frame = lastZoneFrame else { return false }
        return frame.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
    }

    /// Called by the shelf's buckets when a drop lands on them.
    func noteShelfDrop(_ instant: FileDropInstant) {
        shelfDropAt = instant == .actions ? Date() : nil
    }

    func handleDrag(_ event: FileDropDragWatcher.Event) {
        switch event {
        case .began:
            break
        case .moved(let point):
            guard isEnabled, showsShelf, !isDrawerExpanded(), let screen = FileDropDragWatcher.targetScreen() else {
                if isZoneVisible { hideZone() }
                return
            }
            let near = FileDropDragWatcher.isNearNotch(point, screen: screen.frame, margin: isZoneVisible ? 40 : 0)
            if near { showZone(on: screen) } else if isZoneVisible { hideZone() }
        case .ended:
            // Let a drop on the shelf land before it goes away.
            hideZone(after: .milliseconds(350))
        }
    }

    private func showZone(on screen: NSScreen) {
        zoneHide?.cancel()
        zoneHide = nil
        guard !isZoneVisible else { return }
        let band = activities.current?.height ?? 0
        let frame = FileDropDragWatcher.zoneFrame(screen: screen.frame, notchHeight: FileDropDragWatcher.notchHeight(of: screen),
                                                  bandHeight: band)
        let panel = zonePanel ?? FileDropZonePanel(controller: self)
        zonePanel = panel
        lastZoneFrame = frame
        isZoneVisible = true
        panel.present(at: frame)
    }

    func hideZone(after delay: Duration? = nil, immediately: Bool = false) {
        zoneHide?.cancel()
        guard isZoneVisible || zonePanel?.isVisible == true else { return }
        guard let delay, !immediately else {
            isZoneVisible = false
            zonePanel?.dismiss(animated: !immediately)
            return
        }
        zoneHide = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.isZoneVisible = false
            self.zonePanel?.dismiss(animated: true)
        }
    }

    // MARK: Taking files

    static let acceptedTypes: [UTType] = [.fileURL, .image]

    /// Accepts one drop (shelf bucket or drawer tab) and runs `instant`.
    @discardableResult
    func accept(_ providers: [NSItemProvider], then instant: FileDropInstant = .actions) -> Bool {
        guard isEnabled, !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await AirDrop.resolve(provider), url.isFileURL { urls.append(url) }
            }
            guard !urls.isEmpty else {
                self.show(FileDropNote(text: "That drop had no files", tone: .warning))
                return
            }
            self.add(urls, then: instant)
        }
        return true
    }

    /// Adds files (Finder reference URLs resolved) and runs `instant`.
    func add(_ rawURLs: [URL], then instant: FileDropInstant = .actions) {
        let urls = rawURLs.map { ($0 as NSURL).filePathURL ?? $0 }.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SparkV-AirDrop").resolvingSymlinksInPath().path
        let fresh: [FileDropItem] = urls.map { FileDropItem(url: $0, isStaged: $0.resolvingSymlinksInPath().path.hasPrefix(stagingRoot)) }
        let known = Set(items.map(\.url.path))
        let newOnes = fresh.filter { !known.contains($0.url.path) }
        switch mode {
        case .working where instant != .actions:
            // An instant bucket while something runs: do it right after,
            // on just these files (never silently dropped).
            pendingInstant = (urls, instant)
            show(FileDropNote(text: "\(instant.title) is next, after the current action", tone: .info))
            return
        case .working:
            // Don't pull the files out from under a running action.
            items += newOnes
            loadThumbnails(for: items.map(\.url))
            show(FileDropNote(text: "Added; finishing the current action first", tone: .info))
            return
        case .renaming where instant == .actions:
            // Renaming carries on through the new files too.
            items += newOnes
            loadThumbnails(for: items.map(\.url))
            queueSuggestions(for: newOnes)
            return
        case .renaming:
            // An instant bucket ends the rename (names already applied
            // stay applied) and acts on the new drop.
            suggestTask?.cancel(); resuggestTask?.cancel()
            renames = []
        default:
            break
        }
        // A drop on an instant bucket acts on just what was dropped.
        if instant != .actions, mode != .empty {
            mode = .empty
        }
        switch mode {
        case .actions, .pickingSpace:
            items += newOnes
        default:
            workTask?.cancel()
            suggestTask?.cancel(); resuggestTask?.cancel()
            items = fresh
            lastUndo = nil
            // Thumbnails are per drop; don't let them pile up.
            let keep = Set(fresh.map(\.url.path))
            thumbnails = thumbnails.filter { keep.contains($0.key) }
        }
        note = nil
        mode = .actions
        loadThumbnails(for: items.map(\.url))
        switch instant {
        case .actions: onOpenStrip?()
        case .compress: compress()
        case .space: send(toSpace: nil)
        case .airDrop: airDrop()
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func remove(_ item: FileDropItem) {
        items.removeAll { $0.id == item.id }
        if items.isEmpty { clear() }
    }

    /// Back to the empty strip. Files on disk are untouched.
    func clear() {
        workTask?.cancel()
        suggestTask?.cancel(); resuggestTask?.cancel()
        items = []
        renameDrafts = [:]
        renames = []
        lastUndo = nil
        pendingInstant = nil
        thumbnails = [:]
        note = nil
        mode = .empty
    }

    /// A running action ended: run an instant drop that waited for it.
    private func workEnded() {
        guard let pending = pendingInstant else { return }
        pendingInstant = nil
        add(pending.urls, then: pending.instant)
    }

    /// Stops a running compress / Spaces filing (files already written stay
    /// and remain undoable through Finder).
    func cancelWork() {
        // Each task stops after the file in hand and shows what it finished.
        workTask?.cancel()
    }

    /// From a result or picker back to the action row.
    func back() {
        suggestTask?.cancel(); resuggestTask?.cancel()
        mode = items.isEmpty ? .empty : .actions
    }

    // MARK: Actions

    func isAvailable(_ action: FileDropAction) -> Bool {
        guard !items.isEmpty else { return false }
        switch action {
        case .convert:
            return converter != nil && !ConverterEngine.targets(for: items.map(\.url)).isEmpty
        case .tray:
            return onAddToTray != nil
        case .airDrop:
            return NSSharingService(named: .sendViaAirDrop) != nil
        case .rename, .compress, .space, .reveal:
            return true
        }
    }

    func perform(_ action: FileDropAction) {
        guard isAvailable(action) else {
            NSSound.beep()
            return
        }
        switch action {
        case .rename: beginRename()
        case .compress: compress()
        case .convert: convert()
        case .space: showSpacePicker()
        case .airDrop: airDrop()
        case .tray: addToTray()
        case .reveal: reveal(items.map(\.url))
        }
    }

    // MARK: Rename

    func beginRename() {
        guard !items.isEmpty else { return }
        renames = []
        renameDrafts = [:]
        suggestTask?.cancel()
        suggestTask = nil
        // Suggestions for every file, one at a time (the on-device model
        // serves one request at a time anyway), first file first.
        queueSuggestions(for: items)
        showRenameEditor(at: 0)
    }

    /// Prepares names for `targets` after any already queued.
    private func queueSuggestions(for targets: [FileDropItem]) {
        let previous = suggestTask
        let style = nameStyle
        let work = targets.map { ($0.id, $0.url) }
        for (id, _) in work { renameDrafts[id] = FileDropRenameDraft(suggestion: nil, source: nil, isSuggesting: true) }
        suggestTask = Task { [weak self] in
            await previous?.value
            for (id, url) in work {
                guard !Task.isCancelled else { return }
                let suggestion = await FileDropNamer.suggest(for: url, style: style)
                guard !Task.isCancelled, let self else { return }
                self.receive(suggestion, for: id)
            }
        }
    }

    /// Asks again for the file being renamed, for a name unlike the
    /// current one (the model is greedy, so it's told what to avoid).
    func resuggest() {
        guard case .renaming(let index) = mode, items.indices.contains(index) else { return }
        let item = items[index]
        let avoid = renameText
        renameDrafts[item.id] = FileDropRenameDraft(suggestion: nil, source: nil, isSuggesting: true)
        // The user asked: the new suggestion may replace the field.
        autoFilledText = renameText
        resuggestTask?.cancel()
        let style = nameStyle
        resuggestTask = Task { [weak self] in
            let suggestion = await FileDropNamer.suggest(for: item.url, style: style, avoiding: avoid)
            guard !Task.isCancelled, let self else { return }
            self.receive(suggestion, for: item.id)
        }
    }

    private func receive(_ suggestion: FileDropNamer.Suggestion?, for id: UUID) {
        renameDrafts[id] = FileDropRenameDraft(suggestion: suggestion?.name, source: suggestion?.source ?? "No better name found",
                                               isSuggesting: false)
        guard case .renaming(let index) = mode, items.indices.contains(index), items[index].id == id,
              let name = suggestion?.name, renameText == autoFilledText else { return }
        renameText = name
        autoFilledText = name
    }

    private func showRenameEditor(at index: Int) {
        guard items.indices.contains(index) else { return finishRenaming() }
        let item = items[index]
        // A folder's whole name is editable ("Assets.v2" has no extension).
        let text = renameDrafts[item.id]?.suggestion ?? (item.kind == .folder ? item.name : item.baseName)
        renameText = text
        autoFilledText = text
        mode = .renaming(index: index)
    }

    var renameIndex: Int? {
        if case .renaming(let index) = mode { return index }
        return nil
    }

    /// Renames the current file to the field's text and moves on.
    func confirmRename() {
        guard let index = renameIndex, items.indices.contains(index) else { return }
        let item = items[index]
        let name = FileDropOps.cleanTypedName(renameText, extension: item.kind == .folder ? nil : item.fileExtension)
        guard !name.isEmpty else {
            show(FileDropNote(text: "Type a name first", tone: .warning))
            return
        }
        if name != (item.kind == .folder ? item.name : item.baseName) {
            do {
                let newURL = try FileDropOps.rename(item.url, toBaseName: name)
                if newURL != item.url {
                    renames.append(FileDropRename(itemID: item.id, from: item.url, to: newURL))
                    moveThumbnail(from: item.url, to: newURL)
                    items[index].url = newURL
                    items[index].kind = FileDropKind(newURL)
                }
            } catch {
                show(FileDropNote(text: "Couldn't rename: \(error.localizedDescription)", tone: .warning))
                return
            }
        }
        showRenameEditor(at: index + 1)
    }

    func skipRename() {
        guard let index = renameIndex else { return }
        showRenameEditor(at: index + 1)
    }

    /// Stops renaming; files already renamed stay renamed (and undoable).
    func cancelRename() {
        suggestTask?.cancel(); resuggestTask?.cancel()
        if renames.isEmpty { mode = .actions } else { finishRenaming() }
    }

    private func finishRenaming() {
        suggestTask?.cancel(); resuggestTask?.cancel()
        guard !renames.isEmpty else {
            mode = .actions
            show(FileDropNote(text: "Names unchanged", tone: .info))
            return
        }
        let done = renames
        renames = []
        let headline = done.count == 1 ? "Renamed to \(done[0].to.lastPathComponent)" : "Renamed \(done.count) files"
        let detail = done.count == 1 ? "was \(done[0].from.lastPathComponent)" : done.map(\.to.lastPathComponent).joined(separator: ", ")
        finish(FileDropResult(action: .rename, headline: headline, detail: detail, outputs: done.map(\.to), undo: .renamed(done)))
    }

    // MARK: Compress

    /// Images and PDFs get smaller copies next to the originals; anything
    /// else (or `zipAll`) becomes one .zip. Originals are never changed.
    func compress(zipAll: Bool = false) {
        guard !items.isEmpty else { return }
        let snapshot = items
        let mediaOnly = !zipAll && snapshot.allSatisfy { $0.kind == .image || $0.kind == .pdf }
        mode = .working(mediaOnly ? "Compressing \(snapshot.count == 1 ? snapshot[0].name : "\(snapshot.count) files")…" : "Zipping…")
        workTask?.cancel()
        workTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) { () -> Result<FileDropResult, Error> in
                Result { try Self.runCompress(snapshot, mediaOnly: mediaOnly) }
            }
            // Cancelling stops after the current file; what's written is
            // still shown (and undoable), never left behind unlisted.
            let outcome = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            switch outcome {
            case .success(let result):
                // "Already as small as it gets" has no outputs; the result
                // row offers a .zip instead. Either way the band says what
                // happened when the drawer is closed (an instant drop).
                self.finish(result)
                self.postBand(icon: result.outputs.isEmpty ? "checkmark.seal.fill" : "arrow.down.right.and.arrow.up.left",
                              color: SparkVTheme.success, headline: result.headline,
                              detail: result.outputs.isEmpty ? "No smaller copy made" : result.detail)
            case .failure(let error):
                self.mode = .actions
                self.show(FileDropNote(text: "Couldn't compress: \(error.localizedDescription)", tone: .warning))
            }
            self.workEnded()
        }
    }

    nonisolated static func runCompress(_ items: [FileDropItem], mediaOnly: Bool) throws -> FileDropResult {
        let before = items.reduce(Int64(0)) { $0 + $1.size }
        guard mediaOnly else {
            let directory = try FileDropOps.outputDirectory(for: items[0], label: "Archive")
            let archive = try FileDropOps.zip(items, in: directory)
            let after = FileDropOps.fileSize(archive)
            let percent = before > 0 && after < before ? Int(((1 - Double(after) / Double(before)) * 100).rounded()) : 0
            let saved = percent >= 1 ? " (−\(percent)%)" : ""
            return FileDropResult(action: .compress, headline: "\(archive.lastPathComponent) · \(FileDropOps.formatBytes(after))\(saved)",
                                  detail: "\(items.count) item\(items.count == 1 ? "" : "s") zipped, originals kept",
                                  outputs: [archive], undo: .created([archive]))
        }
        var outputs: [URL] = []
        var beforeShrunk: Int64 = 0
        var afterShrunk: Int64 = 0
        var unchanged = 0
        var failures: [Error] = []
        for item in items {
            if Task.isCancelled { break }
            // One unreadable file (a damaged image, a locked PDF) must not
            // throw away, unlisted, the copies already written for the others.
            do {
                let directory = try FileDropOps.outputDirectory(for: item, label: "Compressed")
                let result = item.kind == .pdf
                    ? try FileDropOps.compressPDF(item, in: directory)
                    : try FileDropOps.compressImage(item, in: directory)
                if let output = result.output {
                    outputs.append(output)
                    beforeShrunk += result.before
                    afterShrunk += result.after
                } else {
                    unchanged += 1
                }
            } catch {
                failures.append(error)
            }
        }
        if outputs.isEmpty, unchanged == 0, let first = failures.first { throw first }
        guard !outputs.isEmpty else {
            let failedNote = failures.isEmpty ? "" : " · \(failures.count) couldn't be read"
            return FileDropResult(action: .compress, headline: items.count == 1 ? "Already as small as it gets" : "These are already as small as they get",
                                  detail: "No smaller copy was made · a .zip is still possible" + failedNote, outputs: [], undo: nil, offersZip: true)
        }
        let percent = beforeShrunk > 0 ? Int(((1 - Double(afterShrunk) / Double(beforeShrunk)) * 100).rounded()) : 0
        let headline = "Saved \(FileDropOps.formatBytes(beforeShrunk - afterShrunk)) (−\(percent)%)"
        var detail = outputs.count == 1
            ? "\(FileDropOps.formatBytes(beforeShrunk)) → \(FileDropOps.formatBytes(afterShrunk)) · \(outputs[0].lastPathComponent)"
            : "\(outputs.count) smaller copies · \(FileDropOps.formatBytes(beforeShrunk)) → \(FileDropOps.formatBytes(afterShrunk))"
        if unchanged > 0 { detail += " · \(unchanged) already small" }
        if !failures.isEmpty { detail += " · \(failures.count) couldn't be read" }
        return FileDropResult(action: .compress, headline: headline, detail: detail, outputs: outputs, undo: .created(outputs), offersZip: true)
    }

    /// From a media compress result: one .zip of the originals instead.
    /// The smaller copies go to the Trash first (they're SparkV's own).
    func zipInstead() {
        if case .created(let urls) = lastUndo { _ = FileDropOps.trash(urls) }
        lastUndo = nil
        compress(zipAll: true)
    }

    // MARK: Convert, Space, AirDrop, Tray, Reveal

    func convert() {
        guard let converter else {
            show(FileDropNote(text: "The converter isn't available", tone: .warning))
            return
        }
        converter.add(items.map(\.url))
        onOpenConverter?()
    }

    func showSpacePicker() {
        let store = spaceStore()
        spaces = store.spaces.sorted { lhs, rhs in
            // Parents before their children, then by name.
            (lhs.parentID == nil ? 0 : 1, lhs.name.lowercased()) < (rhs.parentID == nil ? 0 : 1, rhs.name.lowercased())
        }
        mode = .pickingSpace
    }

    /// nil = Auto: the Spaces agents route each file (Inbox when unsure).
    func send(toSpace spaceID: UUID?) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        let store = spaceStore()
        let spaceName = spaceID.flatMap { id in store.spaces.first { $0.id == id }?.name }
        mode = .working(spaceName.map { "Filing to \($0)…" } ?? "Filing to Spaces…")
        workTask?.cancel()
        workTask = Task { [weak self] in
            var filed: [String: Int] = [:]
            var inbox = 0
            var failed = 0
            var already = 0
            var folders = 0
            for url in urls {
                if Task.isCancelled { break }
                // Spaces hold files; a folder has to be zipped first.
                if FileDropKind(url) == .folder {
                    folders += 1
                    continue
                }
                guard var input = await SpaceConnectors.fileInput(url, source: .files) else {
                    failed += 1
                    continue
                }
                input.hints["origin"] = "fileDrop"
                if let spaceID {
                    input.hints["spaceID"] = spaceID.uuidString
                    guard let item = await store.ingest(input) else {
                        failed += 1
                        continue
                    }
                    if item.spaceID != spaceID { store.move(itemID: item.id, to: spaceID) }
                    filed[spaceName ?? "Space", default: 0] += 1
                } else if let center = SpaceIngestCenter.current {
                    // The ingest center announces where each file went.
                    switch await center.submit(input, userInitiated: true) {
                    case .filed(_, _, let name): filed[name, default: 0] += 1
                    case .inbox: inbox += 1
                    case .skipped: already += 1
                    case .failed: failed += 1
                    }
                } else if let item = await store.ingest(input) {
                    if let id = item.spaceID, let name = store.spaces.first(where: { $0.id == id })?.name {
                        filed[name, default: 0] += 1
                    } else {
                        inbox += 1
                    }
                } else {
                    failed += 1
                }
            }
            guard let self else { return }
            defer { self.workEnded() }
            let total = filed.values.reduce(0, +) + inbox
            guard total > 0 else {
                self.mode = .actions
                let text: String
                if folders > 0, failed == 0, already == 0 {
                    // Short enough for the strip's subtitle (Compress zips a folder).
                    text = "Zip folders for Spaces"
                } else if failed > 0 || folders > 0, already == 0 {
                    text = "Couldn't read \(failed + folders == 1 ? "that file" : "those files") for Spaces"
                } else {
                    text = "Already in Spaces"
                }
                self.show(FileDropNote(text: text, tone: already > 0 && failed == 0 && folders == 0 ? .info : .warning))
                return
            }
            let places = filed.sorted { $0.value > $1.value }.map(\.key) + (inbox > 0 ? ["Inbox"] : [])
            let headline = "Sent \(total == 1 ? urls.count == 1 ? urls[0].lastPathComponent : "1 file" : "\(total) files") to \(places.prefix(2).joined(separator: " & "))"
            var skipped: [String] = []
            if failed > 0 { skipped.append("\(failed) couldn't be read") }
            if folders > 0 { skipped.append("\(folders) folder\(folders == 1 ? "" : "s") skipped") }
            let detail = skipped.isEmpty
                ? "The original\(total == 1 ? " stays" : "s stay") where \(total == 1 ? "it is" : "they are")"
                : skipped.joined(separator: " · ")
            self.finish(FileDropResult(action: .space, headline: headline, detail: detail, outputs: urls, undo: nil))
            if let spaceID, let space = store.spaces.first(where: { $0.id == spaceID }) {
                self.postBand(icon: space.icon.isEmpty ? "square.stack.3d.up.fill" : space.icon,
                              color: SpaceIngestCenter.color(hex: space.color), headline: "Filed to \(space.name)",
                              detail: total == 1 ? "file" : "\(total) files")
            } else if spaceID == nil, SpaceIngestCenter.current == nil {
                // Without the ingest center nobody else announces Auto filing.
                self.postBand(icon: "square.stack.3d.up.fill", color: SparkVTheme.isApple ? Color(red: 0.55, green: 0.45, blue: 1.0) : SparkVTheme.red,
                              headline: headline, detail: "Spaces")
            }
        }
    }

    func airDrop() {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        AirDrop.share(urls: urls)
    }

    func addToTray() {
        let urls = items.map(\.url)
        guard let onAddToTray, !urls.isEmpty else { return }
        onAddToTray(urls)
        show(FileDropNote(text: urls.count == 1 ? "Added to the Tray" : "Added \(urls.count) files to the Tray", tone: .info))
    }

    func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return show(FileDropNote(text: "Those files are gone", tone: .warning)) }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Undo

    var canUndo: Bool { lastUndo != nil }

    func undo() {
        guard let undo = lastUndo else { return }
        lastUndo = nil
        switch undo {
        case .renamed(let list):
            var problems: [String] = []
            for rename in list.reversed() {
                do {
                    try FileDropOps.undoRename(rename)
                    if let index = items.firstIndex(where: { $0.id == rename.itemID }) {
                        moveThumbnail(from: rename.to, to: rename.from)
                        items[index].url = rename.from
                    }
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            mode = items.isEmpty ? .empty : .actions
            show(problems.isEmpty
                 ? FileDropNote(text: list.count == 1 ? "Name restored" : "\(list.count) names restored", tone: .info)
                 : FileDropNote(text: problems[0], tone: .warning))
        case .created(let urls):
            let failed = FileDropOps.trash(urls)
            mode = items.isEmpty ? .empty : .actions
            show(failed.isEmpty
                 ? FileDropNote(text: urls.count == 1 ? "Moved the copy to the Trash" : "Moved \(urls.count) copies to the Trash", tone: .info)
                 : FileDropNote(text: "Couldn't move \(failed[0].lastPathComponent) to the Trash", tone: .warning))
        }
        activities.dismiss(id: Self.activityID)
    }

    // MARK: Dragging out

    /// Files as a Finder drag carries them (real file URLs: Finder, Mail,
    /// Slack, browser upload fields and sandboxed apps all take those, and
    /// the drag pasteboard hands sandboxed receivers read access), with
    /// their thumbnails. Files that have gone missing are skipped; a
    /// Finder file-reference URL is resolved to its path first.
    func dragPayloads(for urls: [URL]) -> [TrayDragPayload] {
        var seen = Set<String>()
        return urls.compactMap { url -> TrayDragPayload? in
            let file = (url as NSURL).filePathURL ?? url
            guard file.isFileURL, FileManager.default.fileExists(atPath: file.path),
                  seen.insert(file.standardizedFileURL.path).inserted else { return nil }
            return TrayDragPayload(writer: file as NSURL, image: dragImage(for: file))
        }
    }

    /// The files of the current pile (results when an action finished,
    /// else the dropped originals), for the strip's file list.
    var visibleFiles: [URL] {
        if case .done(let result) = mode, !result.outputs.isEmpty { return result.outputs }
        return items.map(\.url)
    }

    /// Copies files to a pasteboard the way a drag carries them.
    func copyFiles(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        let writers = dragPayloads(for: urls).map(\.writer)
        guard !writers.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
    }

    private func dragImage(for url: URL) -> NSImage {
        let preview = thumbnails[url.path] ?? NSWorkspace.shared.icon(forFile: url.path)
        return TrayDragImage.render(size: TrayStore.dragImageSize) { rect in
            guard preview.size.width > 0, preview.size.height > 0 else { return TrayDragImage.drawSymbol("doc", in: rect) }
            let scale = min(rect.width / preview.size.width, rect.height / preview.size.height)
            let size = CGSize(width: preview.size.width * scale, height: preview.size.height * scale)
            preview.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    // MARK: Thumbnails (Quick Look, like Finder and the shelf apps)

    func thumbnail(for url: URL) -> NSImage {
        thumbnails[url.path] ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    func loadThumbnails(for urls: [URL]) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for url in urls where thumbnails[url.path] == nil {
            let path = url.path
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: scale,
                                                       representationTypes: [.icon, .thumbnail])
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let cgImage = representation?.cgImage else { return }
                let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
                let image = NSImage(cgImage: cgImage, size: size)
                Task { @MainActor in self?.thumbnails[path] = image }
            }
        }
    }

    private func moveThumbnail(from old: URL, to new: URL) {
        if let image = thumbnails[old.path] { thumbnails[new.path] = image }
    }

    // MARK: Helpers

    private func finish(_ result: FileDropResult) {
        lastUndo = result.undo
        loadThumbnails(for: result.outputs)
        mode = .done(result)
    }

    func show(_ note: FileDropNote) {
        self.note = note
        // With the drawer closed (a drop on the shelf), the strip's note is
        // invisible: say it in the band under the notch instead.
        postBand(icon: note.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill",
                 color: note.tone == .warning ? SparkVTheme.warning : SparkVTheme.success,
                 headline: note.text, detail: "")
        noteClear?.cancel()
        noteClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    private func postBand(icon: String, color: Color, headline: String, detail: String) {
        guard !isDrawerExpanded() else { return }
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 64, duration: 4, opensTab: activityOpensTab) {
            FileDropActivityView(icon: icon, color: color, headline: headline, detail: detail)
        })
    }
}
