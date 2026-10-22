import Foundation

// Conversions the notch uses to hand items to Flow Canvas. Nothing here is
// wired up; see INTEGRATION.md for the one-line hooks.

extension FlowCanvasInput {
    /// A Tray item as a canvas input: images, files (PDFs detected), links, text.
    init?(trayItem item: TrayItem) {
        switch item.kind {
        case .image:
            guard let url = item.url else { return nil }
            self = .image(url)
        case .file:
            guard let url = item.url else { return nil }
            self = .forFile(url)
        case .text:
            if let link = item.trayAILinkURL {
                self = .url(link)
            } else if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self = .text(text)
            } else {
                return nil
            }
        }
    }

    static func from(trayItems items: [TrayItem]) -> [FlowCanvasInput] {
        items.compactMap(FlowCanvasInput.init(trayItem:))
    }

    /// Converter outputs (or any files) as canvas inputs.
    static func from(files urls: [URL]) -> [FlowCanvasInput] {
        urls.filter(\.isFileURL).map(FlowCanvasInput.forFile)
    }
}
