import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// State of the Tray AI panel: the items it works on, the action running or
/// finished, and the message field. No `@State` with the Command Line Tools.
@MainActor
final class TrayAIPanelModel: ObservableObject {
    enum Phase {
        case idle
        case running(TrayAIAction)
        case done(TrayAIAction, TrayAIResult)
        case failed(TrayAIAction, String)
    }

    static var languages: [String] { TrayAISettings.languages }

    @Published private(set) var items: [TrayItem] = []
    @Published var selectedIndex = 0
    @Published private(set) var phase: Phase = .idle
    @Published var message = ""
    @Published var showsSettings = false
    @Published private(set) var toast: String?
    /// Full-size (downsampled to screen size) previews of image items.
    @Published private(set) var previews: [UUID: NSImage] = [:]
    @Published var allowGroq = TrayAISettings.allowGroq {
        didSet {
            guard allowGroq != oldValue else { return }
            TrayAISettings.allowGroq = allowGroq
            AppLog.log("Tray AI: Groq \(allowGroq ? "allowed" : "not allowed")")
        }
    }
    @Published var translateTarget: String = TrayAISettings.translateTarget {
        didSet {
            guard translateTarget != oldValue else { return }
            TrayAISettings.translateTarget = translateTarget
        }
    }

    /// The most recent successful result and the action that made it (for Save).
    @Published private(set) var lastResult: (action: TrayAIAction, result: TrayAIResult)?

    var onClose: (() -> Void)?
    var onSaveToTray: ((String) -> Void)?

    private var runTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var loadGeneration = 0

    var selectedItem: TrayItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : items.first
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var suggestedActions: [TrayAIAction] {
        TrayAIAction.suggested(for: items).map { action in
            if case .translate = action { return .translate(translateTarget) }
            return action
        }
    }

    func load(_ newItems: [TrayItem]) {
        cancel()
        items = newItems
        selectedIndex = 0
        phase = .idle
        message = ""
        showsSettings = false
        lastResult = nil
        allowGroq = TrayAISettings.allowGroq
        translateTarget = TrayAISettings.translateTarget
        let keep = Set(newItems.map(\.id))
        previews = previews.filter { keep.contains($0.key) }
        loadPreviews()
    }

    // MARK: Running

    func run(_ action: TrayAIAction) {
        guard !items.isEmpty else { return }
        runTask?.cancel()
        showsSettings = false
        phase = .running(action)
        let targets = items
        AppLog.log("Tray AI: \(action.id) on \(targets.count) item(s)")
        runTask = Task { [weak self] in
            do {
                let result = try await TrayAIEngine.shared.run(action, on: targets)
                guard !Task.isCancelled else { return }
                self?.finished(action, result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.log("Tray AI: \(action.id) failed: \(error.localizedDescription)")
                self?.phase = .failed(action, error.localizedDescription)
            }
        }
    }

    private func finished(_ action: TrayAIAction, _ result: TrayAIResult) {
        phase = .done(action, result)
        lastResult = (action, result)
        AppLog.log("Tray AI: \(action.id) done (\(result.producedBy))")
        switch action {
        case .extractText:
            if !result.text.isEmpty {
                copyString(result.text)
                flash("Text copied")
            }
        case .webSearch:
            // The user asked to search: go straight to the results (the panel
            // keeps the query and an "Open search" button).
            if let url = result.openURL, !url.isFileURL {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    func sendMessage() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        run(.custom(text))
    }

    func retry() {
        switch phase {
        case .done(let action, _), .failed(let action, _), .running(let action):
            run(action)
        case .idle:
            break
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning { phase = .idle }
    }

    func backToActions() {
        cancel()
        phase = .idle
    }

    // MARK: Result actions

    /// What Save puts in the tray: the JSON for receipts, otherwise the text.
    var saveableText: String? {
        guard let last = lastResult else { return nil }
        let text = last.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = last.result.json?.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .receiptToJSON = last.action, let json, !json.isEmpty { return json }
        if !text.isEmpty { return text }
        if let json, !json.isEmpty { return json }
        return nil
    }

    func saveToTray() {
        guard let text = saveableText else { return }
        if let onSaveToTray {
            onSaveToTray(text)
            flash("Saved to Tray")
        } else {
            copyString(text)
            flash("Copied")
        }
    }

    func copyString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func copyResult(_ result: TrayAIResult) {
        copyString(result.text.isEmpty ? (result.json ?? "") : result.text)
        flash("Copied")
    }

    func copyJSON(_ json: String) {
        copyString(json)
        flash("JSON copied")
    }

    func flash(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
    }

    /// Hands the .ics to Calendar, which shows its own dialog to add it.
    func openEventFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            flash("Run Add to Calendar again")
            return
        }
        if let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open([url], withApplicationAt: calendar, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Item actions (left toolbar)

    func copySelectedItem() {
        guard let item = selectedItem else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            guard let url = item.url else { return }
            var objects: [any NSPasteboardWriting] = []
            if let image = NSImage(contentsOf: url) { objects.append(image) }
            objects.append(url as NSURL)
            pasteboard.writeObjects(objects)
        case .file:
            guard let url = item.url else { return }
            pasteboard.writeObjects([url as NSURL])
        }
        flash("Copied")
    }

    /// Images open in Preview; files in their default app; links in the
    /// browser; other text as a .txt in the default text editor.
    func openSelectedItem() {
        guard let item = selectedItem else { return }
        switch item.kind {
        case .image:
            guard let url = item.url else { return }
            if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        case .file:
            if let url = item.url { NSWorkspace.shared.open(url) }
        case .text:
            let text = item.text ?? ""
            if let link = AirDrop.webURL(in: text) {
                NSWorkspace.shared.open(link)
            } else if let file = AirDrop.temporaryTextFile(text) {
                NSWorkspace.shared.open(file)
            }
        }
    }

    var openTitle: String {
        guard let item = selectedItem else { return "Open" }
        switch item.kind {
        case .image: return "Open with Preview"
        case .file: return "Open"
        case .text: return AirDrop.webURL(in: item.text ?? "") == nil ? "Open as Text File" : "Open Link"
        }
    }

    /// What the Share picker offers for the selected item.
    var shareObjects: [Any] {
        guard let item = selectedItem else { return [] }
        switch item.kind {
        case .image, .file:
            return item.url.map { [$0 as NSURL] } ?? []
        case .text:
            let text = item.text ?? ""
            if let link = AirDrop.webURL(in: text) { return [link as NSURL] }
            return [text as NSString]
        }
    }

    // MARK: Previews

    private func loadPreviews() {
        loadGeneration += 1
        let generation = loadGeneration
        for item in items where item.kind == .image && previews[item.id] == nil {
            guard let url = item.url else { continue }
            let id = item.id
            DispatchQueue.global(qos: .userInitiated).async {
                let image = Self.makePreview(of: url, maxPixelSize: 1600)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.previewLoaded(image, for: id, generation: generation) }
                }
            }
        }
    }

    private func previewLoaded(_ image: CGImage?, for id: UUID, generation: Int) {
        guard generation == loadGeneration, items.contains(where: { $0.id == id }) else { return }
        guard let image else {
            AppLog.log("Tray AI: could not load a preview for \(id)")
            return
        }
        previews[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    nonisolated private static func makePreview(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Metrics

enum TrayAIPanelMetrics {
    static let previewWidth: CGFloat = 400
    static let actionsWidth: CGFloat = 340
    static let cardSpacing: CGFloat = 12
    static let height: CGFloat = 460
    static let cornerRadius: CGFloat = SparkVTheme.cornerLarge
    /// Room around the cards for their shadows.
    static let margin: CGFloat = 16
    static var panelSize: CGSize {
        CGSize(
            width: previewWidth + cardSpacing + actionsWidth + 2 * margin,
            height: height + 2 * margin
        )
    }
}

// MARK: - Root view

struct TrayAIPanelView: View {
    @ObservedObject var model: TrayAIPanelModel

    var body: some View {
        // Rebuilt when the look changes (gear menu › Appearance).
        AppearanceRoot {
            HStack(alignment: .top, spacing: TrayAIPanelMetrics.cardSpacing) {
                TrayAIPreviewCard(model: model)
                    .frame(width: TrayAIPanelMetrics.previewWidth, height: TrayAIPanelMetrics.height)
                TrayAIActionsCard(model: model)
                    .frame(width: TrayAIPanelMetrics.actionsWidth, height: TrayAIPanelMetrics.height)
            }
            .padding(TrayAIPanelMetrics.margin)
            .frame(width: TrayAIPanelMetrics.panelSize.width, height: TrayAIPanelMetrics.panelSize.height)
            .tint(SparkVTheme.accent)
        }
    }
}

/// Frosted card background shared by both halves.
struct TrayAICard<Content: View>: View {
    var material: NSVisualEffectView.Material = .hudWindow
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TrayAIPanelMetrics.cornerRadius, style: .continuous)
        content
            // Apple: the frosted HUD glass as it is. SparkV Red: near-black
            // over the glass, so the panel reads as the brand's black ground
            // with only a hint of blur.
            .background(shape.fill(SparkVTheme.choose(apple: Color.black.opacity(0.18), sparkv: SparkVTheme.background.opacity(0.84))))
            .background(TrayAIGlass(material: material, cornerRadius: TrayAIPanelMetrics.cornerRadius))
            .clipShape(shape)
            .overlay(shape.strokeBorder(SparkVTheme.choose(apple: Color.white.opacity(0.16), sparkv: SparkVTheme.stroke), lineWidth: 1))
            .overlay(shape.inset(by: 1).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }
}

// MARK: - Left: preview

struct TrayAIPreviewCard: View {
    @ObservedObject var model: TrayAIPanelModel

    var body: some View {
        TrayAICard(material: .hudWindow) {
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(TrayAIWindowDragArea())
                Divider().opacity(0.5)
                ZStack {
                    TrayAIWindowDragArea()
                    if let item = model.selectedItem {
                        TrayAIItemPreview(item: item, preview: model.previews[item.id])
                            .padding(14)
                            .id(item.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.items.count > 1 {
                    TrayAIFilmstrip(model: model)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TrayAICircleButton(systemImage: "xmark", help: "Close") { model.onClose?() }
            Text(model.selectedItem.map(TrayAIItemPreview.title(for:)) ?? "")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            TrayAIShareButton(objects: model.shareObjects)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.09)))
                .help("Share")
            TrayAICircleButton(systemImage: "arrow.up.forward.app", help: model.openTitle) { model.openSelectedItem() }
            TrayAICircleButton(systemImage: "doc.on.doc", help: "Copy") { model.copySelectedItem() }
        }
    }
}

struct TrayAIItemPreview: View {
    let item: TrayItem
    let preview: NSImage?

    static func title(for item: TrayItem) -> String {
        switch item.kind {
        case .image, .file:
            return item.url?.lastPathComponent ?? "Item"
        case .text:
            let text = item.text ?? ""
            if let link = AirDrop.webURL(in: text) { return link.host ?? "Link" }
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Text" : trimmed
        }
    }

    var body: some View {
        switch item.kind {
        case .image: imagePreview
        case .file: filePreview
        case .text: textPreview
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let preview {
            Image(nsImage: preview)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filePreview: some View {
        VStack(spacing: 10) {
            if let url = item.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 112, height: 112)
            }
            Text(item.url?.lastPathComponent ?? "File")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            if let detail = fileDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var fileDetail: String? {
        guard let url = item.url else { return nil }
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey])
        var parts: [String] = []
        if let type = values?.localizedTypeDescription { parts.append(type) }
        if values?.isDirectory != true, let size = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var textPreview: some View {
        let text = item.text ?? ""
        let link = AirDrop.webURL(in: text)
        return VStack(alignment: .leading, spacing: 8) {
            if let link {
                Label(link.host ?? "Link", systemImage: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct TrayAIFilmstrip: View {
    @ObservedObject var model: TrayAIPanelModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                Button {
                    model.selectedIndex = index
                } label: {
                    thumbnail(for: item)
                        .frame(width: 46, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    index == model.selectedIndex ? SparkVTheme.red : SparkVTheme.stroke,
                                    lineWidth: index == model.selectedIndex ? 2 : 1
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(TrayAIItemPreview.title(for: item))
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for item: TrayItem) -> some View {
        switch item.kind {
        case .image:
            if let image = model.previews[item.id] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.08)
            }
        case .file:
            ZStack {
                Color.primary.opacity(0.06)
                if let url = item.url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().aspectRatio(contentMode: .fit).padding(3)
                }
            }
        case .text:
            ZStack {
                Color.primary.opacity(0.08)
                Image(systemName: AirDrop.webURL(in: item.text ?? "") == nil ? "text.alignleft" : "link")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Right: actions

struct TrayAIActionsCard: View {
    @ObservedObject var model: TrayAIPanelModel

    var body: some View {
        TrayAICard(material: .hudWindow) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .background(TrayAIWindowDragArea())
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                TrayAIMessageField(model: model)
                    .padding(12)
            }
            .overlay(alignment: .bottom) { toast }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TrayAICircleButton(systemImage: "xmark", help: "Close") { model.onClose?() }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if !SparkVTheme.isApple {
                    Capsule().fill(SparkVTheme.eyebrowDash).frame(width: 10, height: 2)
                }
                Text(SparkVTheme.isApple ? "Tray AI" : "TRAY AI")
                    .tracking(SparkVTheme.isApple ? 0 : 1.2)
            }
            .font(SparkVTheme.isApple ? .system(size: 12.5, weight: .semibold) : SparkVTheme.eyebrow(10))
            .foregroundStyle(SparkVTheme.textSecondary)
            .allowsHitTesting(false)
            Spacer(minLength: 0)
            TrayAICircleButton(
                systemImage: model.showsSettings ? "gearshape.fill" : "gearshape",
                help: "Tray AI settings"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { model.showsSettings.toggle() }
            }
            Button {
                model.saveToTray()
            } label: {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.saveableText == nil ? SparkVTheme.textTertiary : Color.white)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(model.saveableText == nil ? SparkVTheme.surface : SparkVTheme.red))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.saveableText == nil)
            .opacity(model.saveableText == nil ? 0.5 : 1)
            .help("Save the latest result to the Tray")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.showsSettings {
            TrayAISettingsView(model: model)
                .padding(.horizontal, 14)
                .transition(.opacity)
        } else {
            switch model.phase {
            case .idle:
                TrayAIActionList(model: model)
            case .running(let action):
                TrayAIRunningView(model: model, action: action)
            case .done(let action, let result):
                TrayAIResultView(model: model, action: action, result: result)
            case .failed(let action, let message):
                TrayAIFailureView(model: model, action: action, message: message)
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(SparkVTheme.background.opacity(0.95)))
                .overlay(Capsule().strokeBorder(SparkVTheme.choose(apple: Color.white.opacity(0.12), sparkv: SparkVTheme.stroke)))
                .padding(.bottom, 62)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
        }
    }
}

struct TrayAIActionList: View {
    @ObservedObject var model: TrayAIPanelModel

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                ForEach(model.suggestedActions) { action in
                    if case .translate = action {
                        HStack(spacing: 6) {
                            TrayAIActionButton(action: action) { model.run(action) }
                            languageMenu
                        }
                    } else {
                        TrayAIActionButton(action: action) { model.run(action) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(TrayAIPanelModel.languages, id: \.self) { language in
                Button {
                    model.translateTarget = language
                } label: {
                    if language == model.translateTarget {
                        Label(language, systemImage: "checkmark")
                    } else {
                        Text(language)
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .help("Translation language")
    }
}

struct TrayAIActionButton: View {
    let action: TrayAIAction
    let perform: () -> Void
    @StateObject private var isHovered = ViewFlag()

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovered.isOn ? SparkVTheme.red : SparkVTheme.textSecondary)
                    .frame(width: 18)
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(isHovered.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .strokeBorder(SparkVTheme.isApple ? Color.white.opacity(isHovered.isOn ? 0.12 : 0.05) : (isHovered.isOn ? SparkVTheme.red.opacity(0.45) : SparkVTheme.stroke))
            )
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered.isOn = $0 }
    }
}

struct TrayAIRunningView: View {
    @ObservedObject var model: TrayAIPanelModel
    let action: TrayAIAction

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.regular)
            VStack(spacing: 3) {
                Text(action.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(model.allowGroq && action.mayUseGroq ? "Working…" : "Working on this Mac…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { model.backToActions() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(Capsule().fill(Color.primary.opacity(0.09)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }
}

struct TrayAIResultView: View {
    @ObservedObject var model: TrayAIPanelModel
    let action: TrayAIAction
    let result: TrayAIResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TrayAIBackButton { model.backToActions() }
                Spacer(minLength: 0)
                Label(action.title, systemImage: action.systemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !result.text.isEmpty {
                        Text(Self.styled(result.text))
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let json = result.json, !json.isEmpty {
                        jsonBlock(json)
                    }
                }
                .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 12)

            footer
                .padding(.horizontal, 12)
        }
    }

    /// The engine's light markdown for display: "## " lines as bold
    /// headings, "- " / "* " as bullets, inline **bold**, *italic* and
    /// `code`. Copy and Save still use the plain text.
    static func styled(_ text: String) -> AttributedString {
        var output = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            var line = raw
            var heading = false
            if let range = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
                heading = true
            } else if let range = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                let indent = String(line[range].prefix { $0 == " " || $0 == "\t" })
                line.replaceSubrange(range, with: indent + "•  ")
            }
            var part = (try? AttributedString(
                markdown: line,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(line)
            if heading {
                part.font = .system(size: 13.5, weight: .bold)
            }
            output += part
            if index < lines.count - 1 { output += AttributedString("\n") }
        }
        return output
    }

    private func jsonBlock(_ json: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("JSON")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                TrayAIPillButton(title: "Copy JSON", systemImage: "curlybraces") { model.copyJSON(json) }
            }
            Text(json)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 5) {
            // Who answered (on this Mac or Groq) stays readable.
            Text(result.producedBy)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            footerButtons
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if let url = result.openURL {
                if url.isFileURL, url.pathExtension.lowercased() == "ics" {
                    TrayAIPillButton(title: "Add to Calendar", systemImage: "calendar.badge.plus") { model.openEventFile(url) }
                } else {
                    TrayAIPillButton(title: "Open search", systemImage: "safari") { NSWorkspace.shared.open(url) }
                }
            }
            if !result.text.isEmpty {
                TrayAIPillButton(title: "Copy", systemImage: "doc.on.doc") { model.copyResult(result) }
            }
            TrayAIPillButton(title: "Retry", systemImage: "arrow.clockwise") { model.retry() }
        }
    }
}

struct TrayAIFailureView: View {
    @ObservedObject var model: TrayAIPanelModel
    let action: TrayAIAction
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrayAIBackButton { model.backToActions() }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(SparkVTheme.warning)
                Text("Couldn't \(action.title.lowercased())")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                ScrollView {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 120)
                HStack(spacing: 8) {
                    TrayAIPillButton(title: "Retry", systemImage: "arrow.clockwise") { model.retry() }
                    if !model.allowGroq {
                        TrayAIPillButton(title: "Settings", systemImage: "gearshape") {
                            withAnimation(.easeInOut(duration: 0.18)) { model.showsSettings = true }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

struct TrayAISettingsView: View {
    @ObservedObject var model: TrayAIPanelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tray AI")
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $model.allowGroq) {
                        Text("Allow Tray AI to use my Groq key")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text(
                        "Off: everything runs on this Mac with Apple Intelligence, Vision and Translation; only links you run an action on are loaded from the web. "
                            + "On: the selected items (images included) are sent to Groq with the key you saved for Clicky, for every action except Copy Text and Add to Calendar, which always stay on this Mac."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if model.allowGroq && !ClickyKeychain.hasKey() {
                        Label("No Groq key saved. Add one in Clicky's settings.", systemImage: "key")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SparkVTheme.warning)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                HStack {
                    Text("Translate to")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Picker("", selection: $model.translateTarget) {
                        ForEach(TrayAIPanelModel.languages, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                HStack {
                    Spacer()
                    TrayAIPillButton(title: "Done", systemImage: "checkmark") {
                        withAnimation(.easeInOut(duration: 0.18)) { model.showsSettings = false }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct TrayAIMessageField: View {
    @ObservedObject var model: TrayAIPanelModel

    var body: some View {
        let canSend = !model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.items.isEmpty
        HStack(spacing: 8) {
            TextField("Or enter message", text: $model.message)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { model.sendMessage() }
            Button {
                model.sendMessage()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? SparkVTheme.red : SparkVTheme.surface))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        )
    }
}

// MARK: - Small controls

struct TrayAICircleButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @StateObject private var isHovered = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(isHovered.isOn ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct TrayAIPillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TrayAIBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text("Actions")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AppKit bridges

/// Behind-window frosted glass, clipped to a rounded rectangle.
struct TrayAIGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 18

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.maskImage = Self.maskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }

    static func maskImage(cornerRadius radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Lets a borderless panel be dragged by this area.
struct TrayAIWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TrayAIDragView { TrayAIDragView() }
    func updateNSView(_ view: TrayAIDragView, context: Context) {}
}

final class TrayAIDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// A real NSButton so the system share picker can anchor to it.
struct TrayAIShareButton: NSViewRepresentable {
    let objects: [Any]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage()
        let button = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Share"
        button.setAccessibilityLabel("Share")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.objects = objects
        button.isEnabled = !objects.isEmpty
    }

    @MainActor
    final class Coordinator: NSObject {
        var objects: [Any] = []

        @objc func share(_ sender: NSButton) {
            guard !objects.isEmpty else { return }
            let picker = NSSharingServicePicker(items: objects)
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
