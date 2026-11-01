import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

// Source ingestion: turns what the user dropped or pasted into readable text.
// Images: Vision OCR + Vision labels (and the Groq vision model's description
// only when Flow Canvas may use Groq). PDFs: PDFKit text, OCR for scanned
// pages. Links: the page itself (URLSession, no cookies), reduced to readable
// text; video links also use the provider's own oEmbed endpoint for the title
// and thumbnail. Transcripts are never fetched. Other files: the Converter's
// readers (Word, RTF, HTML, Markdown, CSV, XLSX, PPTX) or plain text.

enum FCIngestError: LocalizedError {
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason): reason
        case .empty(let reason): reason
        }
    }
}

enum FCIngest {
    static let maxCharacters = 300_000

    // MARK: Images

    /// OCR text plus a short description from Vision's classifier.
    static func image(at url: URL) async throws -> FCSource {
        guard var analysis = await TrayAIOCR.analyze(imageAt: url) else {
            throw FCIngestError.unreadable("Couldn't open this image")
        }
        // Vision's text recognizer sometimes fails transiently (an e5rt
        // "precompiled compute operation" error while its model loads, seen
        // when several cards are read at once); TrayAIOCR only logs that and
        // returns no lines, which would show a wrong "No text found". Retry.
        // The failure can persist for the combined request, so the fallback is
        // a text-only request (accurate, then fast).
        var fallbackText: String?
        if analysis.lines.isEmpty {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(300))
            if let again = await TrayAIOCR.analyze(imageAt: url) { analysis = again }
        }
        if analysis.lines.isEmpty {
            try Task.checkCancellation()
            fallbackText = await Task.detached(priority: .userInitiated) { () -> String? in
                for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
                    if let text = recognizeText(at: url, level: level), !text.isEmpty { return text }
                }
                return nil
            }.value
        }
        var source = FCSource()
        source.title = url.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)?.preferredFilenameExtension?.uppercased() ?? url.pathExtension.uppercased()
        source.detail = "\(type) · \(Int(analysis.pixelSize.width))×\(Int(analysis.pixelSize.height))"
        let labels = analysis.labels.prefix(4).map(\.name)
        if !labels.isEmpty { source.imageDescription = "Looks like: " + labels.joined(separator: ", ") }
        let codes = analysis.barcodes.map { "\($0.symbology): \($0.payload)" }
        var text = (fallbackText ?? analysis.copyText).trimmingCharacters(in: .whitespacesAndNewlines)
        if !codes.isEmpty { text += (text.isEmpty ? "" : "\n\n") + "Codes:\n" + codes.joined(separator: "\n") }
        source.text = text
        if text.isEmpty {
            source.caveat = "No text found in this image"
        }
        return source
    }

    /// Text-only Vision OCR (the fallback when the combined analysis failed).
    nonisolated static func recognizeText(at url: URL, level: VNRequestTextRecognitionLevel) -> String? {
        guard let image = TrayAIOCR.loadImage(at: url, maxPixel: TrayAIOCR.analysisMaxPixel) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Adds the vision model's description (Groq, opt-in only).
    static func describeImage(at url: URL, groq: FCGroq) async throws -> String {
        let data: Data? = await Task.detached(priority: .userInitiated) {
            TrayAIOCR.jpegData(at: url, maxPixel: TrayAIGroq.maxImagePixel)
        }.value
        guard let data else { throw FCIngestError.unreadable("Couldn't encode the image") }
        let reply = try await groq.complete(
            system: FCPrompts.system,
            messages: [("user", "Describe this image for someone who can't see it: what it shows, any visible text, numbers, prices or UI elements. 3-6 short sentences.")],
            images: [data], json: false, maxTokens: 500
        )
        return reply.text
    }

    // MARK: PDFs

    static func pdf(at url: URL) async throws -> FCSource {
        try await Task.detached(priority: .userInitiated) { () throws -> FCSource in
            guard let document = PDFDocument(url: url) else { throw FCIngestError.unreadable("Couldn't open this PDF") }
            if document.isLocked { throw FCIngestError.unreadable("This PDF is password protected. Unlock it in the Converter first.") }
            var source = FCSource()
            let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            source.title = (title?.isEmpty == false ? title : nil) ?? url.deletingPathExtension().lastPathComponent
            var pages: [String] = []
            var scanned = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.count < 20 { scanned += 1 }
                pages.append(text)
            }
            var used = "PDFKit"
            // Mostly scanned: OCR up to 20 pages.
            if document.pageCount > 0, scanned * 2 >= document.pageCount {
                let ocr = TrayAIFiles.ocrPDF(document, pages: min(document.pageCount, 20))
                if ocr.count > pages.joined().count {
                    pages = [ocr]
                    used = "Vision OCR"
                }
            }
            let text = pages.map(FCText.unwrap).enumerated().filter { !$0.element.isEmpty }
                .map { document.pageCount > 1 ? "[Page \($0.offset + 1)]\n\($0.element)" : $0.element }
                .joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FCIngestError.empty("No text found, even with OCR")
            }
            source.text = String(text.prefix(maxCharacters))
            source.detail = "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")" + (used == "PDFKit" ? "" : " · OCR")
            if document.pageCount > 20 && used != "PDFKit" { source.caveat = "Only the first 20 scanned pages were read" }
            return source
        }.value
    }

    // MARK: Other files

    static func file(at url: URL) async throws -> FCSource {
        try await Task.detached(priority: .userInitiated) { () throws -> FCSource in
            var source = FCSource()
            source.title = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.uppercased()
            var text: String?
            switch ConverterEngine.kind(of: url) {
            case .document, .markdown:
                if ["txt", "text", "md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) {
                    text = try? ConverterDocuments.readText(url)
                } else {
                    text = (try? ConverterDocuments.load(url))?.text.string
                }
            case .table:
                text = try? ConverterDocuments.readText(url)
            case .spreadsheet:
                if let sheets = try? ConverterXLSX.sheets(of: url) {
                    text = sheets.map { sheet in
                        "## \(sheet.name)\n" + sheet.rows.prefix(2000).map { $0.joined(separator: "\t") }.joined(separator: "\n")
                    }.joined(separator: "\n\n")
                }
            case .presentation:
                if let slides = try? ConverterXLSX.slideTexts(of: url) {
                    text = slides.enumerated().map { "[Slide \($0.offset + 1)]\n" + $0.element.joined(separator: "\n") }.joined(separator: "\n\n")
                }
            case .pdf, .image, .unsupported:
                break
            }
            if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                text = TrayAIFiles.readSync(url).text
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FCIngestError.unreadable(ext.isEmpty ? "SparkV can't read this kind of file yet" : "SparkV can't read .\(ext.lowercased()) files yet")
            }
            source.text = String(text.prefix(maxCharacters))
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            source.detail = [ext.isEmpty ? nil : ext, size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                .compactMap { $0 }.joined(separator: " · ")
            return source
        }.value
    }

    // MARK: Links

    enum VideoProvider: String {
        case youtube = "YouTube", loom = "Loom", vimeo = "Vimeo"

        static func of(_ url: URL) -> VideoProvider? {
            let host = (url.host ?? "").lowercased()
            if host == "youtu.be" || host.hasSuffix("youtube.com") { return .youtube }
            if host.hasSuffix("loom.com") { return .loom }
            if host.hasSuffix("vimeo.com") { return .vimeo }
            return nil
        }

        /// The provider's own oEmbed endpoint (same company as the link).
        func oEmbedURL(for url: URL) -> URL? {
            var components: URLComponents?
            switch self {
            case .youtube: components = URLComponents(string: "https://www.youtube.com/oembed")
            case .loom: components = URLComponents(string: "https://www.loom.com/v1/oembed")
            case .vimeo: components = URLComponents(string: "https://vimeo.com/api/oembed.json")
            }
            components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
            return components?.url
        }
    }

    /// Normalizes what the user typed ("example.com/pricing" → https://…).
    static func normalizedURL(_ text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty, !string.contains(" ") else { return nil }
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        if scheme != "file", (url.host ?? "").isEmpty || !(url.host ?? "").contains(".") && url.host != "localhost" { return nil }
        return url
    }

    /// Only web pages (http/https with a host) and local files are read;
    /// other schemes (mailto:, data:, ftp:, app links…) are never requested.
    static func isReadable(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "file" { return true }
        return (scheme == "http" || scheme == "https") && !(url.host ?? "").isEmpty
    }

    static func link(_ url: URL) async throws -> FCSource {
        guard isReadable(url) else {
            throw FCIngestError.unreadable("Only web links (http or https) can be read; \(url.scheme ?? "this") links aren't opened")
        }
        var source = FCSource(url: url)
        source.detail = url.host ?? url.lastPathComponent

        if url.isFileURL {
            return try await localPage(url)
        }

        if let provider = VideoProvider.of(url) {
            source.provider = provider.rawValue
            source.caveat = "Video transcripts aren't fetched; only the title and description are used."
            if let embed = await oEmbed(provider, url) {
                source.title = embed.title
                source.thumbnailURL = embed.thumbnail
                if let author = embed.author { source.detail = "\(provider.rawValue) · \(author)" }
            }
            let page = try? await TrayAIWeb.fetch(url)
            if source.title == nil { source.title = page?.title }
            var parts: [String] = []
            if let title = source.title { parts.append("Video title: \(title)") }
            if let author = source.detail { parts.append("Channel: \(author)") }
            if let summary = page?.summary, !summary.isEmpty { parts.append("Description: \(summary)") }
            source.text = parts.joined(separator: "\n")
            guard source.title != nil else { throw FCIngestError.unreadable("Couldn't load this \(provider.rawValue) link") }
            return source
        }

        let page: TrayAIWebPage
        do {
            page = try await TrayAIWeb.fetch(url)
        } catch let error as TrayAIError {
            throw FCIngestError.unreadable(error.errorDescription ?? "Couldn't load the page")
        }
        source.title = page.title ?? url.host
        source.detail = page.siteName ?? url.host
        var text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < 80, let summary = page.summary, !summary.isEmpty {
            text = summary + (text.isEmpty ? "" : "\n\n" + text)
            source.caveat = "The page shows little text without signing in; only its preview was read."
        }
        guard !text.isEmpty else { throw FCIngestError.empty("The page returned no readable text (it may need a login)") }
        source.text = String(text.prefix(maxCharacters))
        return source
    }

    /// file:// pages (saved HTML, text, PDF) are read straight from disk.
    private static func localPage(_ url: URL) async throws -> FCSource {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            var source = try await pdf(at: url)
            source.url = url
            return source
        }
        return try await Task.detached(priority: .userInitiated) { () throws -> FCSource in
            guard let html = TrayAIFiles.readString(url) else { throw FCIngestError.unreadable("Couldn't read \(url.lastPathComponent)") }
            var source = FCSource(url: url)
            if ["html", "htm", "xhtml"].contains(ext) || html.range(of: "<html", options: .caseInsensitive) != nil {
                let readable = TrayAIHTML.readableText(html)
                source.title = readable.title ?? url.deletingPathExtension().lastPathComponent
                source.detail = readable.siteName ?? "Local page"
                source.text = String(readable.text.prefix(maxCharacters))
            } else {
                source.title = url.deletingPathExtension().lastPathComponent
                source.detail = "Local file"
                source.text = String(html.prefix(maxCharacters))
            }
            guard !source.text.isEmpty else { throw FCIngestError.empty("No readable text in this page") }
            return source
        }.value
    }

    struct Embed: Sendable {
        var title: String?
        var author: String?
        var thumbnail: URL?
    }

    static func oEmbed(_ provider: VideoProvider, _ url: URL) async -> Embed? {
        guard let endpoint = provider.oEmbedURL(for: url) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: endpoint),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parseOEmbed(object)
    }

    static func parseOEmbed(_ object: [String: Any]) -> Embed {
        let thumbnail = (object["thumbnail_url"] as? String).flatMap(URL.init(string:))
        return Embed(title: object["title"] as? String, author: object["author_name"] as? String,
                     thumbnail: thumbnail?.scheme == "https" ? thumbnail : nil)
    }

    // MARK: Pasteboard / drops

    /// What a drop or paste contains, in a form the editor can add.
    static func inputs(from pasteboard: NSPasteboard) -> [FlowCanvasInput] {
        var inputs: [FlowCanvasInput] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            for url in urls {
                if url.isFileURL { inputs.append(.forFile(url)) } else { inputs.append(.url(url)) }
            }
            return inputs
        }
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            let lines = string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let urls = lines.compactMap { line -> URL? in
                guard line.hasPrefix("http://") || line.hasPrefix("https://") else { return nil }
                return normalizedURL(line)
            }
            if !urls.isEmpty && urls.count == lines.count {
                return urls.map { FlowCanvasInput.url($0) }
            }
            return [.text(string)]
        }
        return inputs
    }
}

// MARK: - Thumbnails

/// Small previews for cards, decoded once off the main thread.
@MainActor
final class FCThumbnails: ObservableObject {
    static let shared = FCThumbnails()
    private var cache: [String: NSImage] = [:]
    private var pending: Set<String> = []
    @Published private(set) var revision = 0
    /// 640 px previews are ~1.6 MB each: keep at most this many.
    static let capacity = 48

    init() {
        SparkVEnergy.shared.onMemoryPressure { [weak self] in self?.cache.removeAll() }
    }

    func image(for url: URL, isPDF: Bool) -> NSImage? {
        let key = url.path
        if let image = cache[key] { return image }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        Task.detached(priority: .utility) {
            let cgImage: CGImage? = isPDF ? Self.pdfThumbnail(url) : TrayAIOCR.loadImage(at: url, maxPixel: 640)
            await MainActor.run {
                self.pending.remove(key)
                if let cgImage {
                    if self.cache.count >= Self.capacity { self.cache.removeAll() }
                    self.cache[key] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.revision &+= 1
                }
            }
        }
        return nil
    }

    nonisolated static func pdfThumbnail(_ url: URL) -> CGImage? {
        // Keep the document alive while drawing: a PDFPage only holds it weakly
        // ("Drawing a PDFPage when its PDFDocument is nil is unsupported").
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        defer { withExtendedLifetime(document) {} }
        let bounds = page.bounds(for: .mediaBox)
        let scale = 640 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
