import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sends tray items, files and links with AirDrop (the system AirDrop sheet,
/// via `NSSharingService(named: .sendViaAirDrop)`). Text that isn't a link
/// goes as a temporary .txt file, which is what the receiving device can open.
@MainActor
enum AirDrop {
    /// Shares tray items: files and images as their files, links as web
    /// URLs (they open in Safari on the other device), other text as a .txt.
    static func share(_ items: [TrayItem]) {
        var objects: [Any] = []
        for item in items {
            switch item.kind {
            case .file, .image:
                if let url = item.url, FileManager.default.fileExists(atPath: url.path) {
                    objects.append(url as NSURL)
                }
            case .text:
                guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let link = webURL(in: text) {
                    objects.append(link as NSURL)
                } else if let file = temporaryTextFile(text) {
                    objects.append(file as NSURL)
                }
            }
        }
        perform(objects)
    }

    /// Shares file URLs and web URLs as they are.
    static func share(urls: [URL]) {
        perform(urls.map { $0 as NSURL })
    }

    /// True when AirDrop can take at least one of these items right now.
    static func canShare(_ items: [TrayItem]) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        let probe: [Any] = items.compactMap { item in
            switch item.kind {
            case .file, .image: return item.url.map { $0 as NSURL }
            case .text: return item.text.map { $0 as NSString }
            }
        }
        return !probe.isEmpty && service.canPerform(withItems: probe)
    }

    // MARK: Internals

    private static let delegate = AirDropServiceDelegate()

    private static func perform(_ objects: [Any]) {
        guard !objects.isEmpty else {
            AppLog.log("AirDrop: nothing to share")
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            AppLog.log("AirDrop: sharing service unavailable")
            NSSound.beep()
            return
        }
        guard service.canPerform(withItems: objects) else {
            AppLog.log("AirDrop: cannot share \(objects.count) item(s) (AirDrop off or unsupported items)")
            NSSound.beep()
            return
        }
        service.delegate = delegate
        // The AirDrop sheet is a window of this app: an agent app has to be
        // active or the sheet opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: objects)
        AppLog.log("AirDrop: sharing \(objects.count) item(s)")
    }

    /// The text itself when it is a single http(s) link.
    static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// Writes text to a uniquely named .txt in the temporary directory, named
    /// after its first words so the receiver sees something meaningful.
    static func temporaryTextFile(_ text: String) -> URL? {
        pruneTemporaryFolder("SparkV-AirDrop")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkV-AirDrop", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName(for: text)).appendingPathExtension("txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            AppLog.log("AirDrop: could not write text file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes per-share folders this app wrote to the temporary directory
    /// more than a day ago (by then any transfer is long finished).
    nonisolated static func pruneTemporaryFolder(_ name: String, olderThan age: TimeInterval = 86_400) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private static func fileName(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let cleaned = words.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Text" : String(cleaned.prefix(48))
    }

    /// Resolves one dropped provider to something AirDrop can send: a file
    /// URL (image data and promised files, such as Mail attachments, are
    /// written to a temporary file first), a web URL, or a temporary .txt
    /// for plain text. The File Drop shelf uses the same resolver.
    static func resolve(_ provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { @Sendable data, _ in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    continuation.resume(returning: url)
                }
            }
        }
        if let imageType = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) ?? false }) {
            let suggested = provider.suggestedName ?? "Image"
            let fileExtension = UTType(imageType)?.preferredFilenameExtension ?? "png"
            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                // The provided file is deleted when the handler returns, so
                // it's copied before resuming.
                _ = provider.loadFileRepresentation(forTypeIdentifier: imageType) { @Sendable url, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("SparkV-AirDrop", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    var name = (suggested as NSString).deletingPathExtension
                    if name.isEmpty { name = "Image" }
                    let destination = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        // A promise of a file that isn't an image (Mail, Affinity, WeChat…):
        // the source app writes it, a staging copy is shared.
        if case .promisedFile(let type) = ShelfDropResolver.route(types: provider.registeredTypeIdentifiers,
                                                                  suggestedName: provider.suggestedName) {
            return await ShelfDropResolver.loadPromisedFile(provider, type: type)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { @Sendable data, _ in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    continuation.resume(returning: url)
                }
            }
        }
        if provider.canLoadObject(ofClass: String.self) {
            let text: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                _ = provider.loadObject(ofClass: String.self) { @Sendable text, _ in
                    continuation.resume(returning: text)
                }
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return webURL(in: text) ?? temporaryTextFile(text)
        }
        return nil
    }

    /// `.data` lets promised files (no file URL) through.
    fileprivate static let acceptedTypes: [UTType] = [.fileURL, .image, .url, .plainText, .data]
}

/// Logs AirDrop outcomes.
@MainActor
private final class AirDropServiceDelegate: NSObject, NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        AppLog.log("AirDrop: shared \(items.count) item(s)")
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        AppLog.log("AirDrop: failed: \(error.localizedDescription)")
    }
}

/// Rounded "AirDrop" tile: drop files, images, links or text on it to send
/// them with AirDrop.
struct AirDropTile: View {
    private let onDropComplete: (() -> Void)?
    @StateObject private var isTargeted = ViewFlag()
    @StateObject private var isHovered = ViewFlag()
    @StateObject private var isWorking = ViewFlag()

    init(onDropComplete: (() -> Void)? = nil) {
        self.onDropComplete = onDropComplete
    }

    var body: some View {
        let active = isTargeted.isOn
        VStack(spacing: 5) {
            ZStack {
                if SparkVTheme.isApple {
                    // The AirDrop blue disc, as in Finder and Control Center.
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 0.24, green: 0.62, blue: 1.0), Color(red: 0.05, green: 0.42, blue: 0.95)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 30, height: 30)
                        .shadow(color: Color.blue.opacity(active ? 0.55 : 0), radius: 8)
                } else {
                    Circle()
                        .fill(active || isHovered.isOn ? SparkVTheme.red : SparkVTheme.surfaceHover)
                        .overlay(Circle().strokeBorder(active || isHovered.isOn ? Color.clear : SparkVTheme.stroke))
                        .frame(width: 30, height: 30)
                        .shadow(color: SparkVTheme.red.opacity(active ? 0.55 : 0), radius: 8)
                }
                if isWorking.isOn {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.text))
                }
            }
            Text("AirDrop")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(active || isHovered.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
        }
        .frame(minWidth: 64, minHeight: 64)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .fill(active ? SparkVTheme.choose(apple: Color.white.opacity(0.18), sparkv: SparkVTheme.redSoft)
                      : (isHovered.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .strokeBorder(
                    active ? SparkVTheme.choose(apple: Color.blue.opacity(0.85), sparkv: SparkVTheme.red.opacity(0.85))
                           : SparkVTheme.choose(apple: Color.white.opacity(0.06), sparkv: SparkVTheme.stroke),
                    style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active ? [4, 3] : [])
                )
        )
        .scaleEffect(active && !SparkVMotion.reduceMotion ? 1.05 : 1)
        .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: active)
        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        .onHover { isHovered.isOn = $0 }
        .onDrop(of: AirDrop.acceptedTypes, isTargeted: $isTargeted.isOn) { providers in
            handleDrop(providers)
        }
        .help("Drop files, images or links to send them with AirDrop")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AirDrop")
        .accessibilityHint("Drop items here to send them with AirDrop")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        isWorking.isOn = true
        let completion = onDropComplete
        let working = isWorking
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await AirDrop.resolve(provider) { urls.append(url) }
            }
            working.isOn = false
            if urls.isEmpty {
                AppLog.log("AirDrop: drop had nothing shareable")
                NSSound.beep()
            } else {
                AirDrop.share(urls: urls)
            }
            completion?()
        }
        return true
    }
}
