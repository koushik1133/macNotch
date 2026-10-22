import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import Quartz

/// PDF tools: render, split, merge helpers, compress, rotate, stamp,
/// protect/unlock, OCR. All synchronous; run off the main thread.
enum ConverterPDF {
    // MARK: Opening

    static func open(_ url: URL, password: String) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ConverterError.unreadable(url.lastPathComponent)
        }
        if document.isLocked {
            guard !password.isEmpty else { throw ConverterError.locked(url.lastPathComponent) }
            guard document.unlock(withPassword: password) else { throw ConverterError.wrongPassword }
        }
        guard document.pageCount > 0 else { throw ConverterError.unreadable("\(url.lastPathComponent) (no pages)") }
        return document
    }

    // MARK: Page geometry and rendering

    /// The page as a viewer shows it: crop box, with /Rotate applied.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box
    }

    /// Draws `page` into a context whose origin is the bottom-left corner of
    /// a `displaySize(of:)` rectangle. PDFKit's `draw(with:to:)` maps the
    /// rotated crop box onto that rectangle itself.
    static func drawPage(_ page: PDFPage, in context: CGContext) {
        page.draw(with: .cropBox, to: context)
    }

    /// Renders a page on white, at `scale` pixels per point.
    static func renderPage(_ page: PDFPage, scale requested: CGFloat) -> CGImage? {
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        // Keep bitmaps sane (≈ 10k px on the long side).
        let scale = min(requested, 10_000 / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        drawPage(page, in: context)
        return context.makeImage()
    }

    /// Writes a new PDF whose pages are the source pages redrawn (vector
    /// content stays vector), with `overlay` drawn on top of each page.
    static func redraw(
        _ document: PDFDocument,
        to url: URL,
        progress: ConverterProgress,
        overlay: (CGContext, CGRect, Int, PDFPage) throws -> Void
    ) throws {
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextCreator: "SparkV"]
        guard let context = CGContext(url as CFURL, mediaBox: &defaultBox, info as CFDictionary) else {
            throw ConverterError.writeFailed(url.lastPathComponent)
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            var box = CGRect(origin: .zero, size: displaySize(of: page))
            context.beginPage(mediaBox: &box)
            context.saveGState()
            drawPage(page, in: context)
            context.restoreGState()
            context.saveGState()
            try overlay(context, box, index, page)
            context.restoreGState()
            context.endPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        context.closePDF()
        closed = true
    }

    static func makeLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func lineWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func pageLabel(_ count: Int) -> String {
        "\(count) page\(count == 1 ? "" : "s")"
    }

    // MARK: PDF → images

    static func toImages(
        _ input: URL,
        format: ConverterImageFormat,
        options: ConverterOptions,
        thumbnails: Bool,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        let base = ConverterEngine.baseName(input)
        let count = document.pageCount
        let digits = max(2, String(count).count)
        var files: [URL] = []
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let size = displaySize(of: page)
                let scale: CGFloat = thumbnails
                    ? 320 / max(size.width, size.height, 1)
                    : CGFloat(options.dpi) / 72
                guard let image = renderPage(page, scale: scale) else {
                    throw ConverterError.writeFailed("page \(index + 1)")
                }
                let number = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + String(index + 1)
                let name = thumbnails ? "\(base)-thumb-p\(number)" : (count == 1 ? base : "\(base)-p\(number)")
                let url = ConverterEngine.uniqueURL(in: directory, name: name, ext: format.fileExtension)
                try ConverterImages.write(image, to: url, format: format, quality: options.imageQuality,
                                          dpi: thumbnails ? 72 : Double(options.dpi))
                files.append(url)
            }
            progress(Double(index + 1) / Double(count))
        }
        let summary = thumbnails ? "\(pageLabel(count)) → thumbnails" : "\(pageLabel(count)) → \(format.title)"
        return ConverterOutput(files: files, summary: summary)
    }

    // MARK: PDF → text / Word

    /// Text of one page; scanned pages (no text layer) go through Vision.
    private static func text(of page: PDFPage, ocr: Bool) throws -> (String, Bool) {
        let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existing.isEmpty || !ocr { return (page.string ?? "", false) }
        guard let image = renderPage(page, scale: 200 / 72) else { return ("", false) }
        let lines = try ConverterOCR.recognize(image)
        return (ConverterOCR.joined(lines), true)
    }

    static func toText(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        var pages: [String] = []
        var ocrPages = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let (text, usedOCR) = try text(of: page, ocr: options.ocrScannedPages)
            if usedOCR { ocrPages += 1 }
            pages.append(text)
            progress(Double(index + 1) / Double(document.pageCount))
        }
        let out = ConverterEngine.uniqueURL(in: directory, name: ConverterEngine.baseName(input), ext: "txt")
        do {
            try pages.joined(separator: "\n\n\u{0C}\n").write(to: out, atomically: true, encoding: .utf8)
        } catch {
            throw ConverterError.writeFailed(out.lastPathComponent)
        }
        let suffix = ocrPages > 0 ? " (\(ocrPages) via OCR)" : ""
        return ConverterOutput(files: [out], summary: "\(pageLabel(document.pageCount)) → TXT\(suffix)")
    }

    static func toWord(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 12)
        var ocrPages = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            if index > 0 {
                // Form feed: the .docx writer turns it into a page break.
                result.append(NSAttributedString(string: "\n\u{0C}", attributes: [.font: bodyFont]))
            }
            let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !existing.isEmpty, let styled = page.attributedString {
                result.append(styled)
            } else if options.ocrScannedPages {
                let (text, _) = try text(of: page, ocr: true)
                ocrPages += 1
                result.append(NSAttributedString(string: text, attributes: [.font: bodyFont]))
            }
            progress(Double(index + 1) / Double(document.pageCount) * 0.9)
        }
        let out = ConverterEngine.uniqueURL(in: directory, name: ConverterEngine.baseName(input), ext: "docx")
        try ConverterDocuments.writeDocx(result, to: out)
        let suffix = ocrPages > 0 ? " (\(ocrPages) via OCR)" : ""
        return ConverterOutput(files: [out], summary: "\(pageLabel(document.pageCount)) → Word\(suffix)")
    }

    // MARK: OCR (searchable PDF)

    /// Keeps every page as it is and lays Vision's text invisibly over pages
    /// that have no text layer, so the PDF becomes searchable/selectable.
    static func makeSearchable(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-ocr", ext: "pdf")
        var recognized = 0
        try redraw(document, to: out, progress: progress) { context, rect, _, page in
            let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard existing.isEmpty, let image = renderPage(page, scale: 220 / 72) else { return }
            let lines = try ConverterOCR.recognize(image)
            guard !lines.isEmpty else { return }
            recognized += 1
            context.setTextDrawingMode(.invisible)
            context.textMatrix = .identity
            let black = CGColor(gray: 0, alpha: 1)
            for line in lines {
                let box = CGRect(x: line.box.minX * rect.width, y: line.box.minY * rect.height,
                                 width: line.box.width * rect.width, height: line.box.height * rect.height)
                guard box.width > 1, box.height > 1 else { continue }
                let font = CTFontCreateWithName("Helvetica" as CFString, max(1, box.height * 0.85), nil)
                let ctLine = makeLine(line.text, font: font, color: black)
                let width = lineWidth(ctLine)
                guard width > 0 else { continue }
                context.saveGState()
                context.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
                context.scaleBy(x: box.width / width, y: 1)
                context.textPosition = .zero
                CTLineDraw(ctLine, context)
                context.restoreGState()
            }
        }
        let summary = recognized == 0
            ? "Already searchable (\(pageLabel(document.pageCount)))"
            : "OCR: \(recognized) of \(pageLabel(document.pageCount)) made searchable"
        return ConverterOutput(files: [out], summary: summary)
    }

    // MARK: Split / extract / remove

    private static func write(_ pages: [Int], of document: PDFDocument, to url: URL) throws {
        let output = PDFDocument()
        for index in pages {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            output.insert(page, at: output.pageCount)
        }
        guard output.pageCount > 0, output.write(to: url) else {
            throw ConverterError.writeFailed(url.lastPathComponent)
        }
    }

    static func split(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        let base = ConverterEngine.baseName(input)
        let groups: [[Int]]
        switch options.splitMode {
        case .eachPage:
            groups = (0..<document.pageCount).map { [$0] }
        case .ranges:
            guard !options.pageRanges.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConverterError.needsInput("Type page ranges, e.g. 1-3, 4-6")
            }
            groups = try ConverterPageRanges.parse(options.pageRanges, pageCount: document.pageCount)
        case .fixed:
            guard let size = Int(options.pageRanges.trimmingCharacters(in: .whitespaces)), size >= 1 else {
                throw ConverterError.needsInput("Type how many pages go in each file, e.g. 2")
            }
            let count = document.pageCount
            groups = stride(from: 0, to: count, by: size).map { Array($0..<min($0 + size, count)) }
        }
        var files: [URL] = []
        for (offset, group) in groups.enumerated() {
            try Task.checkCancellation()
            let url = ConverterEngine.uniqueURL(in: directory, name: "\(base)-\(ConverterPageRanges.label(group))", ext: "pdf")
            try write(group, of: document, to: url)
            files.append(url)
            progress(Double(offset + 1) / Double(groups.count))
        }
        return ConverterOutput(files: files, summary: "Split into \(files.count) PDF\(files.count == 1 ? "" : "s")")
    }

    static func extract(
        _ input: URL,
        options: ConverterOptions,
        keep: Bool,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        guard !options.pageRanges.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConverterError.needsInput("Type the pages, e.g. 1-3, 5")
        }
        let document = try open(input, password: options.password)
        let chosen = try ConverterPageRanges.parse(options.pageRanges, pageCount: document.pageCount).flatMap { $0 }
        let pages: [Int]
        if keep {
            pages = chosen
        } else {
            let removed = Set(chosen)
            pages = (0..<document.pageCount).filter { !removed.contains($0) }
            guard !pages.isEmpty else { throw ConverterError.needsInput("That would remove every page") }
        }
        let suffix = keep ? "extract" : "trimmed"
        let url = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-\(suffix)", ext: "pdf")
        try write(pages, of: document, to: url)
        progress(1)
        let summary = keep
            ? "Kept \(pageLabel(pages.count))"
            : "Removed \(pageLabel(document.pageCount - pages.count)), \(pages.count) left"
        return ConverterOutput(files: [url], summary: summary)
    }

    // MARK: Compress

    /// A Quartz filter like /System/Library/Filters/Reduce File Size.qfilter
    /// with our resolution and JPEG quality.
    private static func compressionFilter(_ level: ConverterCompression) -> QuartzFilter? {
        let properties: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "SparkV Compress",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": level.quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": level.imageDPI,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": level == .extreme ? 1600 : 3000,
                            "ImageSizeMin": 0,
                        ],
                    ],
                ],
            ],
        ]
        return QuartzFilter(properties: properties)
    }

    static func compress(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let before = ConverterEngine.fileSize(input)
        let document = try open(input, password: options.password)
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-compressed", ext: "pdf")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkV-compress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var candidates: [URL] = []
        if let filter = compressionFilter(options.compression) {
            let url = scratch.appendingPathComponent("quartz.pdf")
            if document.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) {
                candidates.append(url)
            }
        }
        progress(0.5)
        try Task.checkCancellation()
        let pdfKitURL = scratch.appendingPathComponent("pdfkit.pdf")
        if document.write(to: pdfKitURL, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) {
            candidates.append(pdfKitURL)
        }
        progress(0.9)

        let best = candidates
            .filter { PDFDocument(url: $0)?.pageCount == document.pageCount }
            .min { ConverterEngine.fileSize($0) < ConverterEngine.fileSize($1) }
        let fm = FileManager.default
        do {
            if let best, ConverterEngine.fileSize(best) < before {
                try fm.moveItem(at: best, to: out)
            } else {
                try fm.copyItem(at: input, to: out)
            }
        } catch {
            throw ConverterError.writeFailed(out.lastPathComponent)
        }
        let after = ConverterEngine.fileSize(out)
        let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
        let summary = after < before
            ? "\(ConverterEngine.formatBytes(before)) → \(ConverterEngine.formatBytes(after)) (−\(saved)%)"
            : "Already optimized (\(ConverterEngine.formatBytes(before)))"
        return ConverterOutput(files: [out], summary: summary, bytesBefore: before, bytesAfter: after)
    }

    // MARK: Rotate / stamp

    static func rotate(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        let pages = Set(try ConverterPageRanges.parse(options.pageRanges, pageCount: document.pageCount).flatMap { $0 })
        let degrees = [90, 180, 270].contains(options.rotation) ? options.rotation : 90
        for index in pages.sorted() {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + degrees) % 360
        }
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-rotated", ext: "pdf")
        guard document.write(to: out) else { throw ConverterError.writeFailed(out.lastPathComponent) }
        progress(1)
        return ConverterOutput(files: [out], summary: "Rotated \(pageLabel(pages.count)) \(degrees)°")
    }

    static func pageNumbers(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        let total = document.pageCount
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-numbered", ext: "pdf")
        let color = CGColor(gray: 0.25, alpha: 1)
        try redraw(document, to: out, progress: progress) { context, rect, index, _ in
            let label = options.numberWithTotal ? "\(index + 1) / \(total)" : "\(index + 1)"
            let size = max(8, min(14, min(rect.width, rect.height) / 50))
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = makeLine(label, font: font, color: color)
            let width = lineWidth(line)
            let margin = max(18, size * 2.2)
            let point: CGPoint
            switch options.numberPosition {
            case .bottomCenter: point = CGPoint(x: rect.midX - width / 2, y: margin)
            case .bottomRight: point = CGPoint(x: rect.maxX - margin - width, y: margin)
            case .topRight: point = CGPoint(x: rect.maxX - margin - width, y: rect.maxY - margin - size)
            }
            context.textMatrix = .identity
            context.textPosition = point
            CTLineDraw(line, context)
        }
        return ConverterOutput(files: [out], summary: "Numbered \(pageLabel(total))")
    }

    static func watermark(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let text = options.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConverterError.needsInput("Type the watermark text") }
        let document = try open(input, password: options.password)
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-watermarked", ext: "pdf")
        let opacity = min(max(options.watermarkOpacity, 0.05), 1)
        let color = CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: opacity)
        try redraw(document, to: out, progress: progress) { context, rect, _, _ in
            let angle = atan2(rect.height, rect.width)
            let diagonal = hypot(rect.width, rect.height)
            let probeFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil)
            let probe = lineWidth(makeLine(text, font: probeFont, color: color))
            let size = max(10, min(220, 100 * diagonal * 0.62 / max(probe, 1)))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let line = makeLine(text, font: font, color: color)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: angle)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: -bounds.width / 2 - bounds.minX, y: -bounds.height / 2 - bounds.minY)
            CTLineDraw(line, context)
        }
        return ConverterOutput(files: [out], summary: "Watermarked \(pageLabel(document.pageCount))")
    }

    // MARK: Security

    static func protect(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        guard !options.password.isEmpty else { throw ConverterError.needsInput("Type a password") }
        // An already-protected file must be unlocked first (the password
        // field holds the *new* password here).
        let document = try open(input, password: "")
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-protected", ext: "pdf")
        let written = document.write(to: out, withOptions: [
            .userPasswordOption: options.password,
            .ownerPasswordOption: options.password,
        ])
        guard written, PDFDocument(url: out)?.isLocked == true else {
            try? FileManager.default.removeItem(at: out)
            throw ConverterError.writeFailed(out.lastPathComponent)
        }
        progress(1)
        return ConverterOutput(files: [out], summary: "Password-protected (\(pageLabel(document.pageCount)))")
    }

    static func unlock(
        _ input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: ConverterProgress
    ) throws -> ConverterOutput {
        let document = try open(input, password: options.password)
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-unlocked", ext: "pdf")
        if !document.write(to: out) || PDFDocument(url: out)?.isEncrypted != false {
            // PDFKit kept the encryption: redraw the pages into a plain PDF.
            try? FileManager.default.removeItem(at: out)
            try redraw(document, to: out, progress: progress) { _, _, _, _ in }
        }
        guard let check = PDFDocument(url: out), !check.isEncrypted else {
            throw ConverterError.writeFailed(out.lastPathComponent)
        }
        progress(1)
        return ConverterOutput(files: [out], summary: "Unlocked (\(pageLabel(document.pageCount)))")
    }

    static func repair(_ input: URL, in directory: URL, progress: ConverterProgress) throws -> ConverterOutput {
        guard let document = PDFDocument(url: input) ?? (try? Data(contentsOf: input)).flatMap(PDFDocument.init(data:)) else {
            throw ConverterError.unreadable("\(input.lastPathComponent): too damaged to recover")
        }
        let out = ConverterEngine.uniqueURL(in: directory, name: "\(ConverterEngine.baseName(input))-repaired", ext: "pdf")
        guard document.write(to: out) else { throw ConverterError.writeFailed(out.lastPathComponent) }
        progress(1)
        return ConverterOutput(files: [out], summary: "Rewrote \(pageLabel(document.pageCount))")
    }
}
