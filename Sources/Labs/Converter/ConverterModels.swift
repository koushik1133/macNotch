import Foundation
import ImageIO
import UniformTypeIdentifiers

// Value types shared by the converter engine (which runs off the main
// thread) and the drawer UI. Everything here is Sendable.

/// What a dropped file is, as far as conversions go.
enum ConverterInputKind: String, Sendable {
    case pdf
    case image
    /// Word (.docx/.doc), RTF/RTFD, ODT, WordML, HTML, web archive, plain text.
    case document
    case markdown
    /// CSV / TSV.
    case table
    case spreadsheet
    case presentation
    case unsupported

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .document: "doc.text"
        case .markdown: "text.badge.checkmark"
        case .table, .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .unsupported: "questionmark.square.dashed"
        }
    }
}

/// Raster formats ImageIO can write on this Mac. WebP is readable but has no
/// ImageIO encoder, so it never appears as a target.
enum ConverterImageFormat: String, CaseIterable, Sendable, Identifiable, Hashable {
    case jpg, png, heic, tiff, avif

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .avif: UTType("public.avif") ?? .jpeg
        }
    }

    var fileExtension: String { self == .jpg ? "jpg" : rawValue }
    var title: String { rawValue.uppercased() }
    var isLossy: Bool { self == .jpg || self == .heic || self == .avif }

    /// Formats with a working encoder, checked once against ImageIO.
    static let writable: [ConverterImageFormat] = {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { identifiers.contains($0.utType.identifier) }
    }()

    /// The format a file already is, if it is one of these.
    static func matching(_ url: URL) -> ConverterImageFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpg
        case "png": .png
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case "avif": .avif
        default: nil
        }
    }
}

/// Text an operation needs before it can run; the tab shows an inline field.
enum ConverterPrompt: Sendable {
    case password
    case newPassword
    case watermark
    case pageRanges
}

/// One conversion the user can pick.
enum ConverterOp: Hashable, Sendable, Identifiable {
    // From PDF
    case pdfToImages(ConverterImageFormat)
    case pdfToWord
    case pdfToText
    case pdfThumbnails
    case ocr
    // PDF tools
    case merge
    case split
    case extractPages
    case removePages
    case compress
    case rotate
    case pageNumbers
    case watermark
    case protect
    case unlock
    case repair
    // Images
    case imagesToPDF
    case convertImage(ConverterImageFormat)
    case resizeImage
    // Documents
    case documentToPDF
    case documentToWord
    case documentToText
    case tableToPDF
    case slidesToPDF

    var id: String {
        switch self {
        case .pdfToImages(let format): "pdfTo.\(format.rawValue)"
        case .convertImage(let format): "image.\(format.rawValue)"
        default: String(describing: self)
        }
    }

    /// Short label for the format button.
    var title: String {
        switch self {
        case .pdfToImages(let format): format.title
        case .pdfToWord, .documentToWord: "Word"
        case .pdfToText, .documentToText: "TXT"
        case .pdfThumbnails: "Thumbs"
        case .ocr: "OCR"
        case .merge: "Merge"
        case .split: "Split"
        case .extractPages: "Extract"
        case .removePages: "Remove"
        case .compress: "Compress"
        case .rotate: "Rotate"
        case .pageNumbers: "Numbers"
        case .watermark: "Watermark"
        case .protect: "Protect"
        case .unlock: "Unlock"
        case .repair: "Repair"
        case .imagesToPDF, .documentToPDF, .tableToPDF, .slidesToPDF: "PDF"
        case .convertImage(let format): format.title
        case .resizeImage: "Resize"
        }
    }

    var symbol: String {
        switch self {
        case .pdfToImages, .convertImage: "photo"
        case .pdfToWord, .documentToWord: "doc.text"
        case .pdfToText, .documentToText: "text.alignleft"
        case .pdfThumbnails: "square.grid.2x2"
        case .ocr: "text.viewfinder"
        case .merge: "square.stack.3d.down.right"
        case .split: "scissors"
        case .extractPages: "doc.on.doc"
        case .removePages: "minus.square"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .rotate: "rotate.right"
        case .pageNumbers: "number"
        case .watermark: "drop"
        case .protect: "lock"
        case .unlock: "lock.open"
        case .repair: "wrench.adjustable"
        case .imagesToPDF, .documentToPDF, .tableToPDF, .slidesToPDF: "doc.richtext"
        case .resizeImage: "arrow.up.left.and.down.right.magnifyingglass"
        }
    }

    /// Tooltip.
    var help: String {
        switch self {
        case .pdfToImages(let format): "Export every page as \(format.title)"
        case .pdfToWord: "Convert to an editable Word document (.docx)"
        case .pdfToText: "Extract the text (scanned pages are read with OCR)"
        case .pdfThumbnails: "Small PNG previews of every page"
        case .ocr: "Make scanned pages searchable and selectable"
        case .merge: "Combine everything into one PDF, in drop order"
        case .split: "One PDF per page, or per page range"
        case .extractPages: "Keep only the chosen pages (in the order you type them)"
        case .removePages: "Delete the chosen pages"
        case .compress: "Shrink images inside the PDF; text stays sharp"
        case .rotate: "Rotate pages"
        case .pageNumbers: "Stamp page numbers"
        case .watermark: "Stamp text across every page"
        case .protect: "Require a password to open"
        case .unlock: "Remove the password (you need to know it)"
        case .repair: "Rewrite the PDF to fix structural damage"
        case .imagesToPDF: "Put the images into one PDF"
        case .convertImage(let format): "Convert to \(format.title)"
        case .resizeImage: "Scale down to the longest side set in More…"
        case .documentToPDF: "Render the document as a PDF"
        case .documentToWord: "Save as a Word document (.docx)"
        case .documentToText: "Save as plain text"
        case .tableToPDF: "Render the sheet as a PDF table"
        case .slidesToPDF: "One page per slide (text only)"
        }
    }

    /// Text the op needs first, or nil.
    var prompt: ConverterPrompt? {
        switch self {
        case .protect: .newPassword
        case .unlock: .password
        case .watermark: .watermark
        case .extractPages, .removePages: .pageRanges
        default: nil
        }
    }

    /// Ops that turn several inputs into one output; everything else runs
    /// once per input.
    var combinesInputs: Bool { self == .merge || self == .imagesToPDF }
}

enum ConverterCompression: String, CaseIterable, Sendable, Identifiable {
    case low, recommended, extreme
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "Less (best quality)"
        case .recommended: "Recommended"
        case .extreme: "Extreme (smallest)"
        }
    }
    /// Target image resolution and JPEG quality for the Quartz filter.
    var imageDPI: Int { self == .low ? 220 : self == .recommended ? 150 : 96 }
    var quality: Double { self == .low ? 0.8 : self == .recommended ? 0.6 : 0.4 }
}

enum ConverterPageSize: String, CaseIterable, Sendable, Identifiable {
    case fit, a4, letter
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit to image" : self == .a4 ? "A4" : "US Letter" }
    /// Portrait size in points (nil = fit).
    var size: CGSize? {
        switch self {
        case .fit: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
    /// Page for documents: A4, or Letter in the US.
    static var regionalDefault: CGSize {
        Locale.current.region?.identifier == "US" ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }
}

enum ConverterSplitMode: String, CaseIterable, Sendable, Identifiable {
    case eachPage, ranges
    /// iLovePDF's "fixed ranges": a new file every N pages.
    case fixed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .eachPage: "Every page"
        case .ranges: "By page ranges"
        case .fixed: "Every N pages"
        }
    }
}

enum ConverterNumberPosition: String, CaseIterable, Sendable, Identifiable {
    case bottomCenter, bottomRight, topRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right"
        case .topRight: "Top right"
        }
    }
}

/// Every knob the "More…" menu and inline prompts expose.
struct ConverterOptions: Sendable, Equatable {
    /// PDF → image resolution.
    var dpi: Int = 150
    /// JPEG / HEIC / AVIF quality, 0…1.
    var imageQuality: Double = 0.85
    var compression: ConverterCompression = .recommended
    /// Images → PDF page size.
    var pageSize: ConverterPageSize = .fit
    var splitMode: ConverterSplitMode = .eachPage
    /// "1-3, 5, 8-" (1-based, open end allowed). Empty = all pages. For
    /// Split in `.fixed` mode it holds the pages per file ("2").
    var pageRanges: String = ""
    /// Degrees clockwise: 90, 180 or 270.
    var rotation: Int = 90
    /// Unlock: the current password; Protect: the new one.
    var password: String = ""
    var watermarkText: String = "CONFIDENTIAL"
    var watermarkOpacity: Double = 0.18
    var numberPosition: ConverterNumberPosition = .bottomCenter
    /// "1 / 12" instead of "1".
    var numberWithTotal: Bool = false
    /// Resize: longest side in pixels.
    var maxPixelSize: Int = 1600
    /// Read pages without a text layer with Vision (PDF → Word/TXT).
    var ocrScannedPages: Bool = true
}

/// What a finished conversion produced.
struct ConverterOutput: Sendable {
    var files: [URL]
    /// One line for the result card and the live activity, e.g. "3 pages → JPG".
    var summary: String
    var bytesBefore: Int64?
    var bytesAfter: Int64?
}

/// Progress callback; called from the conversion thread, 0…1.
typealias ConverterProgress = @Sendable (Double) -> Void

enum ConverterError: LocalizedError, Sendable {
    case unreadable(String)
    case locked(String)
    case wrongPassword
    case needsInput(String)
    case badRange(String)
    case unsupported(String)
    case writeFailed(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't open \(name)"
        case .locked(let name): "\(name) is password-protected: use Unlock first"
        case .wrongPassword: "Wrong password"
        case .needsInput(let what): what
        case .badRange(let text): "Pages \"\(text)\" don't match this PDF"
        case .unsupported(let what): what
        case .writeFailed(let name): "Couldn't write \(name)"
        case .toolFailed(let what): what
        }
    }
}

/// Parses "1-3, 5, 8-" against a page count into 0-based page groups.
/// Ranges may run backwards ("5-3") and repeat pages, which is how Extract
/// reorders. An empty string means every page, as one group.
enum ConverterPageRanges {
    static func parse(_ text: String, pageCount: Int) throws -> [[Int]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageCount > 0 else { throw ConverterError.unreadable("the PDF (no pages)") }
        guard !trimmed.isEmpty else { return [Array(0..<pageCount)] }
        var groups: [[Int]] = []
        for part in trimmed.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) where !part.isEmpty {
            let pieces = part.split(separator: "-", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            func page(_ string: String, default fallback: Int) throws -> Int {
                if string.isEmpty { return fallback }
                guard let value = Int(string), value >= 1, value <= pageCount else {
                    throw ConverterError.badRange(trimmed)
                }
                return value
            }
            switch pieces.count {
            case 1:
                groups.append([try page(pieces[0], default: -1) - 1])
            case 2:
                let start = try page(pieces[0], default: 1)
                let end = try page(pieces[1], default: pageCount)
                let range = start <= end ? Array(start...end) : Array((end...start).reversed())
                groups.append(range.map { $0 - 1 })
            default:
                throw ConverterError.badRange(trimmed)
            }
        }
        guard !groups.isEmpty else { throw ConverterError.badRange(trimmed) }
        return groups
    }

    /// "p1-3" / "p5" for file names.
    static func label(_ group: [Int]) -> String {
        guard let first = group.first, let last = group.last else { return "" }
        return group.count == 1 ? "p\(first + 1)" : "p\(first + 1)-\(last + 1)"
    }
}
