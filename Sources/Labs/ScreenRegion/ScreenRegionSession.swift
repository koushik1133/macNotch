import AppKit
import SwiftUI

/// One captured selection and the conversation about it (the results panel's model).
@MainActor
final class ScreenRegionSession: ObservableObject, Identifiable {
    let id = UUID()
    let capture: ScreenRegionCaptureResult
    let thumbnail: NSImage
    let createdAt = Date()

    @Published var question = ""
    @Published private(set) var running: ScreenRegionAction?
    @Published private(set) var lastAction: ScreenRegionAction?
    @Published private(set) var status: String?
    @Published private(set) var text = ""
    @Published private(set) var producedBy: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var openURL: URL?
    /// Links, emails, phones, dates, addresses found by OCR + NSDataDetector.
    @Published private(set) var detected: [ScreenRegionDetected] = []
    /// True for a moment after Copy (for the "Copied" label).
    @Published private(set) var justCopied = false
    private var copiedReset: Task<Void, Never>?

    private let assistant: ScreenRegionAssistant
    private var work: Task<Void, Never>?

    init(capture: ScreenRegionCaptureResult, assistant: ScreenRegionAssistant) {
        self.capture = capture
        self.assistant = assistant
        let scale = max(1, capture.selection.display.scale)
        thumbnail = NSImage(cgImage: capture.image, size: NSSize(width: CGFloat(capture.image.width) / scale, height: CGFloat(capture.image.height) / scale))
    }

    var isRunning: Bool { running != nil }

    var subtitle: String {
        var parts: [String] = []
        if let app = capture.appName, !app.isEmpty { parts.append(app) }
        parts.append("\(capture.image.width)×\(capture.image.height) px")
        return parts.joined(separator: " · ")
    }

    /// OCR in the background right away, so chips and the first action are quick.
    func prepare() {
        Task { [weak self] in
            guard let self else { return }
            let analysis = await self.assistant.analysis(for: self.capture)
            self.detected = ScreenRegionDetectors.detect(in: analysis.copyText)
        }
    }

    func run(_ action: ScreenRegionAction) {
        if case .ask(let raw) = action, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // A typed question follows up on the answer on screen (as in a chat).
        var earlier: ScreenRegionExchange?
        if case .ask = action, let previous = lastAction, errorMessage == nil, !text.isEmpty {
            earlier = ScreenRegionExchange(request: previous.title, answer: text)
        }
        work?.cancel()
        running = action
        lastAction = action
        status = nil
        text = ""
        producedBy = nil
        errorMessage = nil
        openURL = nil
        let stream = assistant.stream(action, on: capture, earlier: earlier)
        work = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .status(let message):
                        self.status = message
                    case .partial(let snapshot):
                        self.status = nil
                        self.text = snapshot
                    case .done(let answer):
                        self.text = answer.text
                        self.producedBy = answer.producedBy
                        self.openURL = answer.openURL
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.running = nil
                self.status = nil
            } catch is CancellationError {
                // Cancelled by a newer run or `cancel()`, which own the state now.
                guard let self, !Task.isCancelled else { return }
                self.running = nil
                self.status = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.running = nil
                self.status = nil
                self.errorMessage = ScreenRegionAssistant.message(for: error)
            }
        }
    }

    /// Runs the free-form question in `question`.
    func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run(.ask(trimmed))
    }

    func cancel() {
        work?.cancel()
        work = nil
        running = nil
        status = nil
    }

    func copyAnswer() {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flashCopied()
    }

    func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([thumbnail])
        flashCopied()
    }

    /// Chip click: opens http(s)/mailto links, copies everything else.
    func use(_ item: ScreenRegionDetected) {
        if let url = item.url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        flashCopied()
    }

    private func flashCopied() {
        justCopied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.justCopied = false
        }
    }

    /// The web search page, on the user's click only.
    func openSearch() {
        guard let openURL, let scheme = openURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(openURL)
    }

    /// Item providers for `TrayStore.accept(_:)` (PNG data, so the tray copies it).
    func trayProviders() -> [NSItemProvider] {
        guard let data = try? Data(contentsOf: capture.fileURL) else { return [] }
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: "public.png")
        provider.suggestedName = "Screen selection.png"
        return [provider]
    }
}
