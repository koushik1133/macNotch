import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A dropped file waiting to be converted.
struct ConverterInput: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let kind: ConverterInputKind
    /// "3 pages · 240 KB", "1600×1200 · 1.1 MB"; filled in off the main thread.
    var detail: String = ""

    var name: String { url.lastPathComponent }
}

/// A conversion in progress.
struct ConverterJob: Identifiable {
    let id = UUID()
    let op: ConverterOp
    let inputCount: Int
    var progress: Double = 0
}

/// A finished conversion: its files are in `directory` and can be dragged out.
struct ConverterResult: Identifiable {
    let id = UUID()
    let op: ConverterOp
    let files: [URL]
    let summary: String
    let directory: URL
    let createdAt = Date()

    var title: String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }
}

/// Drives the Converter tab: inputs → suggested targets → jobs → draggable
/// results. Conversions run in detached tasks (see `ConverterEngine`).
@MainActor
final class ConverterController: ObservableObject {
    @Published private(set) var inputs: [ConverterInput] = []
    /// Format buttons valid for the current inputs.
    @Published private(set) var targets: [ConverterOp] = []
    @Published var options = ConverterOptions()
    @Published private(set) var jobs: [ConverterJob] = []
    /// Newest first.
    @Published private(set) var results: [ConverterResult] = []
    /// One-line error shown over the results row for a few seconds.
    @Published private(set) var errorMessage: String?
    /// An op waiting for text (password, watermark, pages) in the inline field.
    @Published private(set) var pendingPrompt: ConverterOp?
    /// Preview of each result's first file.
    @Published private(set) var previews: [UUID: NSImage] = [:]
    /// Results whose files were just saved to Downloads (shows a checkmark).
    @Published private(set) var savedResults: Set<UUID> = []
    /// Dropped PDFs that need a password to open (Unlock asks for it only
    /// then; owner-restricted PDFs unlock without one, as on iLovePDF).
    @Published private(set) var lockedInputs: Set<URL> = []

    /// Wired by the app to `TrayStore.addFile` for each URL.
    var onAddToTray: (([URL]) -> Void)?
    /// Tab the finished-conversion live activity opens on hover (set this to
    /// the Converter tab once it exists in `NotchState.Tab`).
    var activityOpensTab: NotchState.Tab?

    static let maxResults = 12

    private let activities: ActivityCenter
    private var tasks: [UUID: Task<Result<ConverterRunOutcome, any Error>, Never>] = [:]
    /// Jobs the user cancelled: their card is gone at once, and whatever the
    /// conversion still hands back (Vision can't stop mid-page) is dropped.
    private var cancelledJobs: Set<UUID> = []
    private var targetsGeneration = 0
    private var errorClear: Task<Void, Never>?

    init(activities: ActivityCenter) {
        self.activities = activities
    }

    var isBusy: Bool { !jobs.isEmpty }

    // MARK: Inputs

    /// Takes a drop: file URLs (Finder, Mail attachments…) or image data
    /// (screenshot thumbnails, images dragged from a browser), which is
    /// staged as a file first. Returns false when nothing usable was offered.
    @discardableResult
    func accept(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in self.add([url]) }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) ?? false }) {
                accepted = true
                let name = provider.suggestedName ?? "Image"
                let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                // The file representation only exists during the callback.
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    guard let url, let staged = Self.stage(url, name: name, ext: ext) else { return }
                    Task { @MainActor in self.add([staged]) }
                }
            }
        }
        if !accepted { AppLog.log("Converter: drop had nothing usable") }
        return accepted
    }

    nonisolated private static func stage(_ url: URL, name: String, ext: String) -> URL? {
        let directory = ConverterEngine.inputStaging
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let target = ConverterEngine.uniqueURL(in: directory, name: base.isEmpty ? "Image" : base, ext: ext)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            AppLog.log("Converter: could not stage dropped image (\(error.localizedDescription))")
            return nil
        }
    }

    func add(_ urls: [URL]) {
        var changed = false
        for raw in urls {
            // Finder can hand over file reference URLs (file:///.file/id=…).
            let url = (raw as NSURL).filePathURL ?? raw
            guard url.isFileURL, !inputs.contains(where: { $0.url == url }) else { continue }
            let kind = ConverterEngine.kind(of: url)
            guard kind != .unsupported else {
                showError("Can't convert .\(url.pathExtension.isEmpty ? "folder" : url.pathExtension) files")
                continue
            }
            inputs.append(ConverterInput(url: url, kind: kind))
            changed = true
        }
        if changed {
            pendingPrompt = nil
            refreshTargets()
        }
    }

    func remove(_ input: ConverterInput) {
        inputs.removeAll { $0.id == input.id }
        pendingPrompt = nil
        refreshTargets()
    }

    func clearInputs() {
        inputs.removeAll()
        pendingPrompt = nil
        refreshTargets()
    }

    /// Moves a dropped file earlier (-1) or later (+1); Merge follows this order.
    func move(_ input: ConverterInput, by offset: Int) {
        guard let index = inputs.firstIndex(where: { $0.id == input.id }) else { return }
        let target = index + offset
        guard inputs.indices.contains(target) else { return }
        inputs.swapAt(index, target)
        pendingPrompt = nil
        refreshTargets()
    }

    /// iLovePDF's "Continue": the result's files become the new inputs, so
    /// tools chain (Word → PDF → Compress → Protect).
    func continueWith(_ result: ConverterResult) {
        let files = result.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            showError("The converted files are gone")
            return
        }
        inputs.removeAll()
        pendingPrompt = nil
        add(files)
        refreshTargets()
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to convert"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.add(panel.urls)
            }
        }
    }

    /// Targets and chip details are computed off the main thread (opening a
    /// big PDF to count pages can take a moment).
    private func refreshTargets() {
        targetsGeneration &+= 1
        let generation = targetsGeneration
        let urls = inputs.map(\.url)
        guard !urls.isEmpty else {
            targets = []
            lockedInputs = []
            return
        }
        Task {
            let (targets, details) = await Task.detached(priority: .userInitiated) {
                (ConverterEngine.targets(for: urls), urls.map(Self.describe))
            }.value
            guard generation == self.targetsGeneration else { return }
            self.targets = targets
            self.lockedInputs = Set(zip(urls, details).filter { $0.1.locked }.map(\.0))
            for (url, detail) in zip(urls, details) {
                if let index = self.inputs.firstIndex(where: { $0.url == url }) { self.inputs[index].detail = detail.text }
            }
        }
    }

    nonisolated private static func describe(_ url: URL) -> (text: String, locked: Bool) {
        let size = ConverterEngine.formatBytes(ConverterEngine.fileSize(url))
        switch ConverterEngine.kind(of: url) {
        case .pdf:
            guard let document = PDFDocument(url: url) else { return (size, false) }
            if document.isLocked { return ("Locked · \(size)", true) }
            return ("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s") · \(size)", false)
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return (size, false) }
            return ("\(width)×\(height) · \(size)", false)
        default:
            return (size, false)
        }
    }

    // MARK: Running

    /// The inline text an op needs before it runs, if any.
    func prompt(for op: ConverterOp) -> ConverterPrompt? {
        if op == .split { return options.splitMode == .eachPage ? nil : .pageRanges }
        // Only a PDF that won't open needs its password; owner-restricted
        // ones (printing/copying locked) are unlocked without one.
        if op == .unlock, !inputs.contains(where: { lockedInputs.contains($0.url) }) { return nil }
        return op.prompt
    }

    /// Format button tapped: asks for text first when the op needs it.
    func start(_ op: ConverterOp) {
        if prompt(for: op) != nil {
            if prompt(for: op) == .password || prompt(for: op) == .newPassword { options.password = "" }
            pendingPrompt = op
        } else {
            pendingPrompt = nil
            run(op)
        }
    }

    func confirmPrompt() {
        guard let op = pendingPrompt else { return }
        switch prompt(for: op) {
        case .password, .newPassword:
            guard !options.password.isEmpty else { return }
        case .watermark:
            guard !options.watermarkText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        case .pageRanges:
            guard !options.pageRanges.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        case nil:
            break
        }
        pendingPrompt = nil
        run(op)
    }

    func cancelPrompt() {
        pendingPrompt = nil
        options.password = ""
    }

    func run(_ op: ConverterOp) {
        let urls = inputs.map(\.url)
        guard !urls.isEmpty else { return }
        var runOptions = options
        // Page ranges only apply to the ops that asked for them.
        if prompt(for: op) != .pageRanges { runOptions.pageRanges = "" }
        // Passwords are used once and never kept around.
        if op == .protect || op == .unlock { options.password = "" }

        let job = ConverterJob(op: op, inputCount: urls.count)
        jobs.append(job)
        let jobID = job.id
        let task = Task.detached(priority: .userInitiated) { () -> Result<ConverterRunOutcome, any Error> in
            do {
                let directory = try ConverterEngine.makeJobDirectory(for: op)
                do {
                    let output = try ConverterEngine.run(op, inputs: urls, options: runOptions, in: directory) { fraction in
                        Task { @MainActor in self.setProgress(fraction, for: jobID) }
                    }
                    // Cancelled during the last page: discard the output too.
                    try Task.checkCancellation()
                    return .success(ConverterRunOutcome(output: output, directory: directory))
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            } catch {
                return .failure(error)
            }
        }
        tasks[jobID] = task
        Task {
            let result = await task.value
            self.finish(jobID, op: op, result: result)
        }
    }

    func cancel(_ job: ConverterJob) {
        guard let task = tasks[job.id] else { return }
        task.cancel()
        cancelledJobs.insert(job.id)
        jobs.removeAll { $0.id == job.id }
    }

    private func setProgress(_ fraction: Double, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = max(jobs[index].progress, min(max(fraction, 0), 1))
    }

    private func finish(_ id: UUID, op: ConverterOp, result: Result<ConverterRunOutcome, any Error>) {
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
        if cancelledJobs.remove(id) != nil {
            if case .success(let outcome) = result { try? FileManager.default.removeItem(at: outcome.directory) }
            AppLog.log("Converter: \(op.id) cancelled")
            return
        }
        switch result {
        case .success(let outcome):
            let converted = ConverterResult(op: op, files: outcome.output.files, summary: outcome.output.summary,
                                            directory: outcome.directory)
            results.insert(converted, at: 0)
            if results.count > Self.maxResults {
                let dropped = results.suffix(from: Self.maxResults)
                dropped.forEach { previews[$0.id] = nil }
                results.removeLast(results.count - Self.maxResults)
            }
            AppLog.log("Converter: \(op.id) done — \(converted.summary)")
            postActivity(for: converted)
            loadPreview(for: converted)
        case .failure(let error) where error is CancellationError:
            AppLog.log("Converter: \(op.id) cancelled")
        case .failure(let error):
            AppLog.log("Converter: \(op.id) failed — \(error.localizedDescription)")
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        errorClear?.cancel()
        errorClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.errorMessage = nil
        }
    }

    func dismissError() {
        errorClear?.cancel()
        errorMessage = nil
    }

    private func postActivity(for result: ConverterResult) {
        let summary = result.summary
        let detail = "\(result.op.title) ready"
        activities.post(LiveActivity(
            id: "converter.done",
            kind: .notification,
            priority: 65,
            duration: 4,
            opensTab: activityOpensTab
        ) {
            ConverterActivityView(summary: summary, detail: detail)
        })
    }

    // MARK: Results

    func removeResult(_ result: ConverterResult) {
        results.removeAll { $0.id == result.id }
        previews[result.id] = nil
    }

    func clearResults() {
        results.removeAll()
        previews.removeAll()
    }

    func open(_ result: ConverterResult) {
        if result.files.count == 1 {
            NSWorkspace.shared.open(result.files[0])
        } else {
            reveal(result)
        }
    }

    func reveal(_ result: ConverterResult) {
        NSWorkspace.shared.activateFileViewerSelecting(result.files)
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: ConverterEngine.outputRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ConverterEngine.outputRoot)
    }

    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    /// Copies the result's files into ~/Downloads (never overwriting).
    /// A user action: the first write may show the Files & Folders prompt.
    @discardableResult
    func saveToDownloads(_ result: ConverterResult) -> [URL] {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var saved: [URL] = []
        for file in result.files {
            let target = ConverterEngine.uniqueURL(in: downloads, name: ConverterEngine.baseName(file), ext: file.pathExtension)
            do {
                try FileManager.default.copyItem(at: file, to: target)
                saved.append(target)
            } catch where Self.isPermissionError(error) {
                // macOS ignores a second request once denied: open the
                // Files & Folders pane instead of failing silently.
                showError("Allow Downloads Folder for SparkV in Privacy & Security › Files & Folders")
                PermissionCenter.shared.openSettings(.downloadsFolder, from: "Converter")
                break
            } catch {
                showError("Couldn't save \(file.lastPathComponent) to Downloads")
            }
        }
        if !saved.isEmpty {
            AppLog.log("Converter: saved \(saved.count) file(s) to Downloads")
            savedResults.insert(result.id)
            let id = result.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.savedResults.remove(id)
            }
        }
        return saved
    }

    func addToTray(_ result: ConverterResult) {
        guard let onAddToTray else {
            showError("The Tray isn't connected")
            return
        }
        onAddToTray(result.files)
    }

    func copyToClipboard(_ result: ConverterResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(result.files.map { $0 as NSURL })
    }

    /// What dragging a result card carries: the files themselves, exactly
    /// as a Finder drag does, so every app accepts them.
    func dragPayloads(for result: ConverterResult) -> [TrayDragPayload] {
        let existing = result.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count < result.files.count { showError("Some converted files are gone") }
        let image = dragImage(for: result)
        return existing.map { TrayDragPayload(writer: $0 as NSURL, image: image) }
    }

    private func dragImage(for result: ConverterResult) -> NSImage {
        let preview = previews[result.id] ?? result.files.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return TrayDragImage.render(size: TrayStore.dragImageSize) { rect in
            guard let preview, preview.size.width > 0, preview.size.height > 0 else {
                TrayDragImage.drawSymbol("doc", in: rect)
                return
            }
            let scale = min(rect.width / preview.size.width, rect.height / preview.size.height)
            let size = CGSize(width: preview.size.width * scale, height: preview.size.height * scale)
            preview.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                    width: size.width, height: size.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private func loadPreview(for result: ConverterResult) {
        guard let file = result.files.first else { return }
        let id = result.id
        Task {
            let image = await Task.detached(priority: .utility) { Self.previewImage(of: file) }.value
            if let image {
                self.previews[id] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            } else {
                self.previews[id] = NSWorkspace.shared.icon(forFile: file.path)
            }
        }
    }

    nonisolated private static func previewImage(of url: URL) -> CGImage? {
        switch ConverterEngine.kind(of: url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .pdf:
            guard let document = PDFDocument(url: url), !document.isLocked, let page = document.page(at: 0) else { return nil }
            let size = ConverterPDF.displaySize(of: page)
            return ConverterPDF.renderPage(page, scale: 160 / max(size.width, size.height, 1))
        default:
            return nil
        }
    }
}

/// What a detached conversion hands back to the controller.
struct ConverterRunOutcome: Sendable {
    let output: ConverterOutput
    let directory: URL
}

/// Band under the notch when a conversion finishes.
struct ConverterActivityView: View {
    let summary: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.success)
            Text(summary)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
