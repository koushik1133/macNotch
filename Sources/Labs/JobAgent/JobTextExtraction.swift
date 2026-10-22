import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// On-device text sources for the Job Agent: Vision OCR of screenshots and
// resume files (PDF, DOCX, TXT/RTF). Self-contained (no app dependencies) so
// the test harness can compile it on its own.

/// CGImage across task boundaries (immutable once created).
struct JobImageBox: @unchecked Sendable {
    let image: CGImage
}

struct JobOCRLine: Sendable, Equatable {
    var text: String
    /// Pixels, origin top-left.
    var rect: CGRect
    var confidence: Float
}

struct JobOCRResult: Sendable, Equatable {
    var lines: [JobOCRLine]
    var pixelSize: CGSize
    /// Set when Vision failed (the result is then empty).
    var error: String?
    /// Lines in reading order, one per line.
    var text: String { lines.map(\.text).joined(separator: "\n") }
    var isEmpty: Bool { lines.isEmpty }
}

enum JobOCR {
    /// Vision text recognition (accurate, language correction). Blocking:
    /// call from a background task.
    static func recognizeSync(_ image: CGImage) -> JobOCRResult {
        let size = CGSize(width: image.width, height: image.height)
        var lastError: String?
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Latin-script UI text: automatic detection sometimes reads "Acme" as Cyrillic.
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = recognitionLanguages
        // Small UI text in a downscaled window capture.
        request.minimumTextHeight = 0.006
        // Vision can fail transiently while the Neural Engine is busy: retry once.
        var performed = false
        for attempt in 0..<2 where !performed {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                performed = true
            } catch {
                lastError = String(describing: error)
            }
        }
        guard performed else { return JobOCRResult(lines: [], pixelSize: size, error: lastError) }
        var lines: [JobOCRLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = fixCommonErrors(candidate.string.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                              width: box.width * size.width, height: box.height * size.height)
            return JobOCRLine(text: text, rect: rect, confidence: candidate.confidence)
        }
        lines = readingOrder(lines)
        return JobOCRResult(lines: lines, pixelSize: size)
    }

    /// English plus the user's preferred languages that Vision supports.
    static let recognitionLanguages: [String] = {
        var languages = ["en-US"]
        for identifier in Locale.preferredLanguages.prefix(3) where !identifier.hasPrefix("en") {
            languages.append(identifier)
        }
        return languages
    }()

    /// Vision occasionally returns Cyrillic look-alikes for gray Latin text
    /// ("Аст Robotics"). Mapped back unless the user reads a Cyrillic/Greek language.
    static func latinizeHomoglyphs(_ text: String) -> String {
        guard !recognitionLanguages.contains(where: { ["ru", "uk", "bg", "sr", "be", "kk", "el", "mk"].contains(String($0.prefix(2))) }),
              text.unicodeScalars.contains(where: { (0x0370...0x04FF).contains($0.value) }) else { return text }
        let map: [Character: Character] = [
            "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M", "О": "O", "Р": "P", "Т": "T", "Х": "X",
            "У": "Y", "І": "I", "Ј": "J", "Ѕ": "S", "а": "a", "с": "c", "е": "e", "о": "o", "р": "p", "х": "x", "у": "y",
            "і": "i", "ј": "j", "ѕ": "s", "т": "m", "п": "n", "к": "k", "в": "b", "н": "h", "м": "m", "г": "r", "Α": "A",
            "Β": "B", "Ε": "E", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Χ": "X",
            "ο": "o", "ν": "v", "α": "a",
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    /// Frequent Vision confusions in tech postings (capital I read as l).
    static func fixCommonErrors(_ text: String) -> String {
        var t = latinizeHomoglyphs(text)
        let fixes: [(String, String)] = [
            ("SwiftUl\\b", "SwiftUI"), ("\\bUlKit\\b", "UIKit"), ("\\bUl\\b", "UI"), ("\\bUl/UX\\b", "UI/UX"),
            ("\\bIOS\\b", "iOS"), ("\\blOS\\b", "iOS"), ("\\bMacOS\\b", "macOS"), ("\\bAPls\\b", "APIs"), ("\\bAPl\\b", "API"),
            ("\\bCl/CD\\b", "CI/CD"), ("\\bGraphQl\\b", "GraphQL"),
        ]
        for (pattern, replacement) in fixes {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return t
    }

    static func recognize(_ box: JobImageBox) async -> JobOCRResult {
        await Task.detached(priority: .userInitiated) { recognizeSync(box.image) }.value
    }

    /// Top-to-bottom, then left-to-right for lines sharing a baseline; a
    /// clearly separate right column (sidebars) is read after the main column.
    static func readingOrder(_ lines: [JobOCRLine]) -> [JobOCRLine] {
        guard lines.count > 1 else { return lines }
        let width = (lines.map(\.rect.maxX).max() ?? 0)
        // Column split: many lines starting right of 62 % while the main body starts left of 40 %.
        let rightStarters = lines.filter { $0.rect.minX > width * 0.62 }
        let leftStarters = lines.filter { $0.rect.minX < width * 0.4 }
        let split = rightStarters.count >= 6 && leftStarters.count >= 6
        func ordered(_ group: [JobOCRLine]) -> [JobOCRLine] {
            group.sorted { a, b in
                let tolerance = min(a.rect.height, b.rect.height) * 0.5
                if abs(a.rect.midY - b.rect.midY) <= tolerance { return a.rect.minX < b.rect.minX }
                return a.rect.midY < b.rect.midY
            }
        }
        if split {
            let right = lines.filter { $0.rect.minX > width * 0.62 }
            let left = lines.filter { $0.rect.minX <= width * 0.62 }
            return ordered(left) + ordered(right)
        }
        return ordered(lines)
    }

    static func loadImage(at url: URL, maxPixel: Int = 4096) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Creation date of an image file (when a screenshot was taken), if known.
    static func captureDate(of url: URL) -> Date? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: raw) { return date }
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}

// MARK: - Resume files

enum JobResumeFileError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name). Use a PDF, DOCX or TXT resume."
        case .empty: "No text found in the resume. If it's a scanned image, export it as a text PDF."
        case .tooLarge: "The resume file is larger than 15 MB."
        }
    }
}

enum JobResumeFile {
    static let maxBytes = 15 * 1024 * 1024
    static let maxCharacters = 60_000

    /// Extracts resume text on-device. Blocking: call from a background task.
    static func extractText(from url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxBytes else { throw JobResumeFileError.tooLarge }
        let ext = url.pathExtension.lowercased()
        var text: String?
        switch ext {
        case "pdf":
            text = pdfText(url)
        case "docx", "docm", "dotx":
            text = docxText(url) ?? attributedText(url)
        case "doc", "rtf", "rtfd", "odt", "html", "htm":
            text = attributedText(url)
        case "txt", "text", "md", "markdown", "":
            text = plainText(url)
        default:
            let type = UTType(filenameExtension: ext)
            if type?.conforms(to: .pdf) == true { text = pdfText(url) }
            else if type?.conforms(to: .text) == true { text = plainText(url) }
            else { text = attributedText(url) }
        }
        guard let text else { throw JobResumeFileError.unreadable(url.lastPathComponent) }
        let cleaned = normalize(text)
        guard cleaned.count >= 40 else { throw JobResumeFileError.empty }
        return String(cleaned.prefix(maxCharacters))
    }

    static func normalize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        result = result.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2022}", with: "• ")
            .replacingOccurrences(of: "\u{F0B7}", with: "• ")
            .replacingOccurrences(of: "\u{25CF}", with: "• ")
            // Bullets glued into one line by PDF text extraction start their own line.
            .replacingOccurrences(of: "[ \t]+•[ \t]+(?=[A-Z])", with: "\n• ", options: .regularExpression)
        let lines = result.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        // Collapse runs of blank lines.
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1)
    }

    static func attributedText(_ url: URL) -> String? {
        (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }

    /// PDFKit text; scanned PDFs (no text layer) are OCR'd page by page (first 4 pages).
    static func pdfText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        // `document.string` joins the lines of a text block with spaces, which
        // hides section headers ("Summary iOS engineer…"): read line by line.
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let selection = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
            let lines = selection.selectionsByLine().compactMap { $0.string?.trimmingCharacters(in: .whitespaces) }
            pages.append(lines.joined(separator: "\n"))
        }
        var text = pages.joined(separator: "\n\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 { text = document.string ?? "" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
            var parts: [String] = []
            for index in 0..<min(4, document.pageCount) {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = 2200 / max(bounds.width, bounds.height, 1)
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                parts.append(JobOCR.recognizeSync(cg).text)
            }
            text = parts.joined(separator: "\n\n")
        }
        return text
    }

    /// DOCX = ZIP; text lives in word/document.xml (ECMA-376 WordprocessingML).
    static func docxText(_ url: URL) -> String? {
        guard let xml = unzipEntry(url, entry: "word/document.xml") else { return nil }
        return DocxTextParser.text(fromDocumentXML: xml)
    }

    /// `/usr/bin/unzip -p archive entry` (ships with macOS). Nil on failure.
    static func unzipEntry(_ archive: URL, entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}

/// Collects `w:t` runs; `w:p` and `w:br` end lines, `w:tab` becomes a tab.
final class DocxTextParser: NSObject, XMLParserDelegate {
    private var output = ""
    private var inText = false
    private var paragraphIsListItem = false

    static func text(fromDocumentXML data: Data) -> String? {
        let delegate = DocxTextParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.output.isEmpty else { return nil }
        return delegate.output
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:t": inText = true
        case "w:tab": output += "\t"
        case "w:br", "w:cr": output += "\n"
        case "w:p": paragraphIsListItem = false
        case "w:numPr":
            // Numbered/bulleted paragraph: mark as a bullet once.
            if !paragraphIsListItem {
                paragraphIsListItem = true
                output += "• "
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:t": inText = false
        case "w:p": output += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { output += string }
    }
}
