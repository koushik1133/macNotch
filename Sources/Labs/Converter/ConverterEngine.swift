import Foundation
import PDFKit
import UniformTypeIdentifiers

/// iLovePDF-style conversions that run entirely on this Mac (PDFKit, ImageIO,
/// CoreGraphics, TextKit, Vision, `/usr/bin/textutil`, `/usr/bin/unzip`).
///
/// Everything is synchronous and nonisolated: call `run` from
/// `Task.detached`. Ops check `Task.isCancelled` between pages and throw
/// `CancellationError` when the task is cancelled.
enum ConverterEngine {
    // MARK: Detection

    static func kind(of url: URL) -> ConverterInputKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "txt", "text", "xml", "wordml":
            return .document
        case "md", "markdown", "mdown": return .markdown
        case "csv", "tsv": return .table
        case "xlsx": return .spreadsheet
        case "pptx": return .presentation
        default: break
        }
        if let type = UTType(filenameExtension: ext) ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) { return .table }
            if type.conforms(to: .rtf) || type.conforms(to: .html) || type.conforms(to: .plainText) { return .document }
        }
        return .unsupported
    }

    /// True for a PDF that needs a password to open.
    static func isLockedPDF(_ url: URL) -> Bool {
        guard kind(of: url) == .pdf, let document = PDFDocument(url: url) else { return false }
        return document.isLocked
    }

    /// True for any encrypted PDF, including ones that open without a
    /// password but carry an owner password (permissions).
    static func isEncryptedPDF(_ url: URL) -> Bool {
        guard kind(of: url) == .pdf, let document = PDFDocument(url: url) else { return false }
        return document.isEncrypted
    }

    /// Format buttons for a set of inputs, most useful first.
    static func targets(for urls: [URL]) -> [ConverterOp] {
        let kinds = urls.map(kind(of:))
        guard !kinds.isEmpty, !kinds.contains(.unsupported) else { return [] }
        let unique = Set(kinds)

        if unique.count > 1 {
            // A mix: anything PDF-able can be merged into one PDF.
            let mergeable: Set<ConverterInputKind> = [.pdf, .image, .document, .markdown, .table, .spreadsheet, .presentation]
            return unique.isSubset(of: mergeable) ? [.merge] : []
        }

        let images = ConverterImageFormat.writable
        switch kinds[0] {
        case .pdf:
            // A PDF that needs a password can only be unlocked until it is.
            if urls.contains(where: isLockedPDF) { return [.unlock] }
            var ops: [ConverterOp] = urls.count > 1 ? [.merge] : []
            if urls.contains(where: isEncryptedPDF) { ops.append(.unlock) }
            ops += [.pdfToWord, .pdfToImages(.jpg), .pdfToImages(.png), .pdfToText, .compress]
            if urls.count == 1 { ops += [.split, .extractPages, .removePages] }
            ops += [.rotate, .pageNumbers, .watermark, .protect, .ocr, .pdfThumbnails, .repair]
            return ops
        case .image:
            let sources = Set(urls.compactMap(ConverterImageFormat.matching))
            var ops: [ConverterOp] = [.imagesToPDF]
            // HEIC → JPG first: the common case for iPhone photos.
            let preferred: [ConverterImageFormat] = [.jpg, .png, .heic, .avif, .tiff]
            for format in preferred where images.contains(format) {
                if sources.count == 1, sources.contains(format) { continue }
                ops.append(.convertImage(format))
            }
            ops.append(.resizeImage)
            return ops
        case .document:
            let isDocx = urls.allSatisfy { $0.pathExtension.lowercased() == "docx" }
            let isText = urls.allSatisfy { ["txt", "text"].contains($0.pathExtension.lowercased()) }
            var ops: [ConverterOp] = [.documentToPDF]
            if urls.count > 1 { ops.insert(.merge, at: 0) }
            if !isDocx { ops.append(.documentToWord) }
            if !isText { ops.append(.documentToText) }
            return ops
        case .markdown:
            return (urls.count > 1 ? [.merge] : []) + [.documentToPDF, .documentToWord]
        case .table, .spreadsheet:
            return (urls.count > 1 ? [.merge] : []) + [.tableToPDF]
        case .presentation:
            return (urls.count > 1 ? [.merge] : []) + [.slidesToPDF]
        case .unsupported:
            return []
        }
    }

    // MARK: Output location

    /// ~/Library/Application Support/SparkV/Converted
    static var outputRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Converted", isDirectory: true)
    }

    /// Staging folder for dropped image data that has no file of its own.
    static var inputStaging: URL { outputRoot.appendingPathComponent("Inputs", isDirectory: true) }

    /// A fresh `Converted/<yyyy-MM-dd HH.mm.ss>-<op>/` folder.
    static func makeJobDirectory(for op: ConverterOp) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(formatter.string(from: Date()))-\(op.id)"
        var url = outputRoot.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputRoot.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `<dir>/<name>.<ext>`, adding " 2", " 3"… if taken.
    static func uniqueURL(in directory: URL, name: String, ext: String) -> URL {
        let clean = sanitize(name)
        var url = directory.appendingPathComponent(clean).appendingPathExtension(ext)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(clean) \(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return url
    }

    static func baseName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Converted" : String(trimmed.prefix(120))
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Running

    /// Runs one op. Combining ops (Merge, Images → PDF) take all inputs at
    /// once; every other op runs once per input and the outputs are pooled.
    static func run(
        _ op: ConverterOp,
        inputs: [URL],
        options: ConverterOptions,
        in directory: URL,
        progress: @escaping ConverterProgress
    ) throws -> ConverterOutput {
        guard !inputs.isEmpty else { throw ConverterError.needsInput("Nothing to convert") }
        AppLog.log("Converter: \(op.id) on \(inputs.count) file(s)")
        if op.combinesInputs {
            let output = try combineToPDF(inputs, options: options, in: directory, progress: progress)
            progress(1)
            return output
        }

        var pooled = ConverterOutput(files: [], summary: "", bytesBefore: nil, bytesAfter: nil)
        var summaries: [String] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let share = 1 / Double(inputs.count)
            let sub: ConverterProgress = { fraction in
                progress((Double(index) + min(max(fraction, 0), 1)) * share)
            }
            let output = try runSingle(op, input: input, options: options, in: directory, progress: sub)
            pooled.files += output.files
            summaries.append(output.summary)
            if let before = output.bytesBefore { pooled.bytesBefore = (pooled.bytesBefore ?? 0) + before }
            if let after = output.bytesAfter { pooled.bytesAfter = (pooled.bytesAfter ?? 0) + after }
        }
        if inputs.count == 1 {
            pooled.summary = summaries.first ?? ""
        } else if let before = pooled.bytesBefore, let after = pooled.bytesAfter {
            pooled.summary = "\(inputs.count) files: \(formatBytes(before)) → \(formatBytes(after))"
        } else {
            pooled.summary = "\(inputs.count) files → \(pooled.files.count) \(op.title)"
        }
        progress(1)
        return pooled
    }

    private static func runSingle(
        _ op: ConverterOp,
        input: URL,
        options: ConverterOptions,
        in directory: URL,
        progress: @escaping ConverterProgress
    ) throws -> ConverterOutput {
        switch op {
        case .pdfToImages(let format):
            return try ConverterPDF.toImages(input, format: format, options: options, thumbnails: false, in: directory, progress: progress)
        case .pdfThumbnails:
            return try ConverterPDF.toImages(input, format: .png, options: options, thumbnails: true, in: directory, progress: progress)
        case .pdfToWord:
            return try ConverterPDF.toWord(input, options: options, in: directory, progress: progress)
        case .pdfToText:
            return try ConverterPDF.toText(input, options: options, in: directory, progress: progress)
        case .ocr:
            return try ConverterPDF.makeSearchable(input, options: options, in: directory, progress: progress)
        case .split:
            return try ConverterPDF.split(input, options: options, in: directory, progress: progress)
        case .extractPages:
            return try ConverterPDF.extract(input, options: options, keep: true, in: directory, progress: progress)
        case .removePages:
            return try ConverterPDF.extract(input, options: options, keep: false, in: directory, progress: progress)
        case .compress:
            return try ConverterPDF.compress(input, options: options, in: directory, progress: progress)
        case .rotate:
            return try ConverterPDF.rotate(input, options: options, in: directory, progress: progress)
        case .pageNumbers:
            return try ConverterPDF.pageNumbers(input, options: options, in: directory, progress: progress)
        case .watermark:
            return try ConverterPDF.watermark(input, options: options, in: directory, progress: progress)
        case .protect:
            return try ConverterPDF.protect(input, options: options, in: directory, progress: progress)
        case .unlock:
            return try ConverterPDF.unlock(input, options: options, in: directory, progress: progress)
        case .repair:
            return try ConverterPDF.repair(input, in: directory, progress: progress)
        case .convertImage(let format):
            return try ConverterImages.convert(input, to: format, maxPixelSize: nil, options: options, in: directory)
        case .resizeImage:
            let format = ConverterImageFormat.matching(input).flatMap { ConverterImageFormat.writable.contains($0) ? $0 : nil } ?? .png
            return try ConverterImages.convert(input, to: format, maxPixelSize: options.maxPixelSize, options: options, in: directory)
        case .documentToPDF:
            return try ConverterDocuments.toPDF(input, in: directory, progress: progress)
        case .documentToWord:
            return try ConverterDocuments.toWord(input, in: directory)
        case .documentToText:
            return try ConverterDocuments.toText(input, in: directory)
        case .tableToPDF:
            return try ConverterDocuments.tableToPDF(input, in: directory, progress: progress)
        case .slidesToPDF:
            return try ConverterDocuments.slidesToPDF(input, in: directory, progress: progress)
        case .merge, .imagesToPDF:
            return try combineToPDF([input], options: options, in: directory, progress: progress)
        }
    }

    /// Merge / Images → PDF: PDFs keep their pages, images become pages,
    /// documents and sheets are rendered first. Order = drop order.
    static func combineToPDF(
        _ inputs: [URL],
        options: ConverterOptions,
        in directory: URL,
        progress: @escaping ConverterProgress
    ) throws -> ConverterOutput {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkV-Converter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let merged = PDFDocument()
        let allImages = inputs.allSatisfy { kind(of: $0) == .image }
        var index = 0
        // Consecutive images go into one image PDF so page size rules apply.
        var pendingImages: [URL] = []

        func appendPDF(_ url: URL) throws {
            let document = try ConverterPDF.open(url, password: options.password)
            for pageIndex in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        func flushImages() throws {
            guard !pendingImages.isEmpty else { return }
            let temp = scratch.appendingPathComponent("images-\(index).pdf")
            try ConverterImages.writePDF(from: pendingImages, pageSize: options.pageSize, to: temp) { _ in }
            pendingImages.removeAll()
            try appendPDF(temp)
        }

        for (offset, input) in inputs.enumerated() {
            try Task.checkCancellation()
            index = offset
            let kind = kind(of: input)
            if kind == .image {
                pendingImages.append(input)
            } else {
                try flushImages()
                switch kind {
                case .pdf:
                    try appendPDF(input)
                case .document, .markdown:
                    let temp = scratch.appendingPathComponent("doc-\(offset).pdf")
                    try ConverterDocuments.renderPDF(of: input, to: temp) { _ in }
                    try appendPDF(temp)
                case .table, .spreadsheet:
                    let temp = scratch.appendingPathComponent("table-\(offset).pdf")
                    try ConverterDocuments.renderTablePDF(of: input, to: temp) { _ in }
                    try appendPDF(temp)
                case .presentation:
                    let temp = scratch.appendingPathComponent("slides-\(offset).pdf")
                    try ConverterDocuments.renderSlidesPDF(of: input, to: temp) { _ in }
                    try appendPDF(temp)
                case .image, .unsupported:
                    throw ConverterError.unsupported("Can't add \(input.lastPathComponent) to a PDF")
                }
            }
            progress(Double(offset + 1) / Double(inputs.count) * 0.9)
        }
        try flushImages()
        guard merged.pageCount > 0 else { throw ConverterError.unreadable("the dropped files (no pages)") }

        let name = inputs.count == 1 ? baseName(inputs[0]) : (allImages ? "Images" : "Merged")
        let out = uniqueURL(in: directory, name: name, ext: "pdf")
        guard merged.write(to: out) else { throw ConverterError.writeFailed(out.lastPathComponent) }
        let pages = merged.pageCount
        let summary = allImages
            ? "\(inputs.count) image\(inputs.count == 1 ? "" : "s") → PDF"
            : "\(inputs.count) file\(inputs.count == 1 ? "" : "s") → \(pages)-page PDF"
        return ConverterOutput(files: [out], summary: summary, bytesBefore: nil, bytesAfter: fileSize(out))
    }

    /// Runs a command-line tool and returns stdout (used for textutil/unzip).
    static func runTool(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting so a full pipe can't deadlock the tool.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ConverterError.toolFailed("\((path as NSString).lastPathComponent) failed\(message.isEmpty ? "" : ": \(message)")")
        }
        return data
    }
}
