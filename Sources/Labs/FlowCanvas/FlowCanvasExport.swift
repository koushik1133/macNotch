import AppKit
import Foundation
import UniformTypeIdentifiers

// Export of node outputs: Markdown / CSV / text files (for drag-out, the
// Tray hook and save panels), PDF (the Markdown rendered with the
// Converter's TextKit paginator), the clipboard, and Notes through the
// system share service (no Apple Events).

enum FCExportFormat: String, CaseIterable, Sendable, Identifiable {
    case markdown = "md", csv, text = "txt", pdf

    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .csv: "CSV"
        case .text: "Text"
        case .pdf: "PDF"
        }
    }
    var utType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .csv: .commaSeparatedText
        case .text: .plainText
        case .pdf: .pdf
        }
    }
}

enum FCExport {
    /// Formats that make sense for a node's output.
    static func formats(for output: FCOutput?) -> [FCExportFormat] {
        guard let output else { return [] }
        return output.table != nil ? [.markdown, .csv, .text, .pdf] : [.markdown, .text, .pdf]
    }

    /// The output as one Markdown document, titled with the node name.
    static func markdown(for node: FCNode) -> String {
        if node.kind.isSource {
            let source = node.source ?? FCSource()
            var parts = ["# \(node.citationLabel)"]
            if let url = source.url { parts.append("<\(url.absoluteString)>") }
            if !source.text.isEmpty { parts.append(source.text) }
            return parts.joined(separator: "\n\n")
        }
        guard let output = node.output else { return "" }
        let body = output.markdown
        return body.hasPrefix("# ") ? body : "# \(node.title)\n\n" + body
    }

    static func content(for node: FCNode, format: FCExportFormat) -> String {
        switch format {
        case .markdown, .pdf: return markdown(for: node)
        case .csv: return node.output?.table?.csv ?? ""
        case .text: return node.kind.isSource ? (node.source?.text ?? "") : (node.output?.plainText ?? "")
        }
    }

    static func fileName(for node: FCNode) -> String {
        let base = node.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Flow Canvas output" : String(base.prefix(80))
    }

    /// Writes the output into `directory` (unique name) and returns the file.
    @discardableResult
    static func write(_ node: FCNode, format: FCExportFormat, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = ConverterEngine.uniqueURL(in: directory, name: fileName(for: node), ext: format.rawValue)
        try write(node, format: format, toFile: url)
        return url
    }

    static func write(_ node: FCNode, format: FCExportFormat, toFile url: URL) throws {
        if format == .pdf {
            try writePDF(markdown: markdown(for: node), to: url)
        } else {
            try Data(content(for: node, format: format).utf8).write(to: url, options: .atomic)
        }
    }

    /// Markdown → paginated PDF (Converter's renderer: headings, bullets, code).
    static func writePDF(markdown: String, to url: URL) throws {
        let attributed = ConverterMarkdown.render(markdown)
        try ConverterDocuments.renderAttributed(
            attributed, pageSize: ConverterPageSize.regionalDefault,
            margins: NSEdgeInsets(top: 64, left: 64, bottom: 64, right: 64), to: url, progress: { _ in }
        )
    }

    // MARK: Clipboard / Notes

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Hands the text to Notes' share extension. False when it isn't available.
    @MainActor
    static func addToNotes(_ text: String) -> Bool {
        let name = NSSharingService.Name("com.apple.Notes.SharingExtension")
        guard let service = NSSharingService(named: name), service.canPerform(withItems: [text]) else { return false }
        service.perform(withItems: [text])
        return true
    }

    /// Save panel for one output.
    @MainActor
    static func save(_ node: FCNode, format: FCExportFormat, in window: NSWindow?) async -> Result<URL, Error>? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: node) + "." + format.rawValue
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        do {
            try write(node, format: format, toFile: url)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    /// Drag image for an exported file chip.
    @MainActor
    static func dragImage(for format: FCExportFormat) -> NSImage {
        TrayDragImage.render(size: TrayStore.dragImageSize) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
            card.stroke()
            let label = "." + format.rawValue
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
