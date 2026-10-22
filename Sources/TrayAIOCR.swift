import AppKit
import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import PDFKit
import UniformTypeIdentifiers
import Vision

// On-device extraction for Tray AI: Vision OCR, image labels, barcodes,
// dominant colors, file text (plain text, RTF, Word, HTML, PDF), readable
// web-page text, and a deterministic receipt parser. Nothing here talks to a
// model; web pages are fetched only when an action runs on a link item.

// MARK: - Image analysis types

struct TrayAITextLine: Sendable, Equatable {
    var text: String
    /// Pixels, origin top-left, y down.
    var rect: CGRect
    var confidence: Float
}

/// OCR lines that share a baseline, left to right (e.g. "Latte   4.50").
struct TrayAITextRow: Sendable, Equatable {
    var segments: [TrayAITextLine]
    var rect: CGRect
    var text: String { segments.map(\.text).joined(separator: "  ") }
    var height: CGFloat { segments.map(\.rect.height).max() ?? rect.height }
}

struct TrayAILabel: Sendable, Equatable {
    var identifier: String
    var confidence: Float
    var name: String { identifier.replacingOccurrences(of: "_", with: " ") }
}

struct TrayAIBarcode: Sendable, Equatable {
    var symbology: String
    var payload: String
}

struct TrayAIColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    /// Share of the image's pixels in this cluster (0...1).
    var fraction: Double

    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Relative luminance (WCAG).
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    func distance(to other: TrayAIColor) -> Double {
        let dr = red - other.red, dg = green - other.green, db = blue - other.blue
        return (dr * dr * 0.30 + dg * dg * 0.59 + db * db * 0.11).squareRoot()
    }

    /// WCAG contrast ratio against another color.
    func contrast(with other: TrayAIColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

struct TrayAIImageAnalysis: Sendable, Equatable {
    var pixelSize: CGSize
    /// In Vision's reading order.
    var lines: [TrayAITextLine]
    var rows: [TrayAITextRow]
    var labels: [TrayAILabel]
    var barcodes: [TrayAIBarcode]
    var colors: [TrayAIColor]
    /// Share of pixels close to the most common color (background/whitespace).
    var backgroundFraction: Double
    var meanLuminance: Double
    /// Median WCAG contrast between text and its surroundings, measured in
    /// the OCR line boxes (nil without text).
    var textContrast: Double?

    /// OCR text in reading order, one Vision line per line.
    var text: String { lines.map(\.text).joined(separator: "\n") }
    /// OCR text with same-baseline segments merged (tables, receipts).
    var rowText: String { rows.map(\.text).joined(separator: "\n") }

    /// True when many rows pair a label with a short value (receipts,
    /// tables, settings screens), where row order reads better than
    /// Vision's block order.
    var looksTabular: Bool {
        let paired = rows.filter { row in
            row.segments.count >= 2 && row.segments.dropFirst().allSatisfy { $0.text.count <= 24 }
        }.count
        return paired >= 2 && Double(paired) / Double(max(rows.count, 1)) >= 0.25
    }

    /// Best text for copying: rows (tab-separated) for tabular layouts,
    /// otherwise Vision's reading order.
    var copyText: String {
        looksTabular ? rows.map { $0.segments.map(\.text).joined(separator: "\t") }.joined(separator: "\n") : text
    }
    var hasText: Bool { !lines.isEmpty }

    var labelSummary: String {
        labels.prefix(5).map { "\($0.name) (\(Int(($0.confidence * 100).rounded()))%)" }.joined(separator: ", ")
    }

    var colorSummary: String {
        colors.prefix(6).map { "\($0.hex) \(Int(($0.fraction * 100).rounded()))%" }.joined(separator: ", ")
    }
}

/// CGImage across task boundaries (immutable once created).
struct TrayAIImageBox: @unchecked Sendable {
    let image: CGImage
}

// MARK: - OCR and image analysis

enum TrayAIOCR {
    /// Longest edge used for Vision (bigger screenshots are scaled down).
    static let analysisMaxPixel = 4096

    static func loadImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    static func loadImage(data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG for Groq: long edge ≤ `maxPixel`, quality 0.8.
    static func jpegData(at url: URL, maxPixel: Int = 1568) -> Data? {
        guard let image = loadImage(at: url, maxPixel: maxPixel) else { return nil }
        return jpegData(image)
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func analyze(imageAt url: URL) async -> TrayAIImageAnalysis? {
        await Task.detached(priority: .userInitiated) { () -> TrayAIImageAnalysis? in
            guard let image = loadImage(at: url, maxPixel: analysisMaxPixel) else {
                AppLog.log("Tray AI: couldn't decode image \(url.lastPathComponent)")
                return nil
            }
            return analyzeSync(image)
        }.value
    }

    static func analyze(_ box: TrayAIImageBox) async -> TrayAIImageAnalysis {
        await Task.detached(priority: .userInitiated) { analyzeSync(box.image) }.value
    }

    /// Text (accurate, language correction, automatic languages), labels,
    /// barcodes and colors in one pass. Blocking: call off the main thread.
    static func analyzeSync(_ image: CGImage) -> TrayAIImageAnalysis {
        let size = CGSize(width: image.width, height: image.height)
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        let classifyRequest = VNClassifyImageRequest()
        let barcodeRequest = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([textRequest, classifyRequest, barcodeRequest])
        } catch {
            AppLog.log("Tray AI: Vision failed \(error)")
        }

        let lines: [TrayAITextLine] = (textRequest.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TrayAITextLine(text: text, rect: pixelRect(observation.boundingBox, size: size), confidence: candidate.confidence)
        }
        let labels = (classifyRequest.results ?? [])
            .filter { $0.confidence >= 0.15 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(8)
            .map { TrayAILabel(identifier: $0.identifier, confidence: $0.confidence) }
        var seenPayloads = Set<String>()
        let barcodes = (barcodeRequest.results ?? []).compactMap { observation -> TrayAIBarcode? in
            guard let payload = observation.payloadStringValue, seenPayloads.insert(payload).inserted else { return nil }
            let symbology = observation.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
            return TrayAIBarcode(symbology: symbology, payload: payload)
        }
        let palette = dominantColors(image)
        let contrast = textContrast(image, lines: lines)
        return TrayAIImageAnalysis(
            pixelSize: size,
            lines: lines,
            rows: groupRows(lines),
            labels: Array(labels),
            barcodes: barcodes,
            colors: palette.colors,
            backgroundFraction: palette.background,
            meanLuminance: palette.meanLuminance,
            textContrast: contrast
        )
    }

    /// For up to 12 OCR lines: the WCAG contrast between the 5th and 95th
    /// luminance percentiles inside the line box (text vs. its background);
    /// the median over lines.
    static func textContrast(_ image: CGImage, lines: [TrayAITextLine]) -> Double? {
        guard !lines.isEmpty else { return nil }
        let scale = min(1, 1600 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var ratios: [Double] = []
        let step = max(1, lines.count / 12)
        for line in stride(from: 0, to: lines.count, by: step).map({ lines[$0] }) {
            // Bitmap rows run top to bottom here, matching the top-left rect.
            let rect = CGRect(x: line.rect.minX * scale, y: line.rect.minY * scale,
                              width: line.rect.width * scale, height: line.rect.height * scale).integral
            let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
            let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
            guard x1 - x0 >= 2, y1 - y0 >= 2 else { continue }
            var values: [Double] = []
            values.reserveCapacity((x1 - x0) * (y1 - y0))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    values.append(0.2126 * lin(Double(buffer[i]) / 255) + 0.7152 * lin(Double(buffer[i + 1]) / 255) + 0.0722 * lin(Double(buffer[i + 2]) / 255))
                }
            }
            values.sort()
            let low = values[values.count / 20], high = values[values.count - 1 - values.count / 20]
            ratios.append((high + 0.05) / (low + 0.05))
        }
        guard !ratios.isEmpty else { return nil }
        return ratios.sorted()[ratios.count / 2]
    }

    static func pixelRect(_ box: CGRect, size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }

    /// Merges lines whose vertical centers line up and that don't overlap
    /// horizontally into rows, top to bottom.
    static func groupRows(_ lines: [TrayAITextLine]) -> [TrayAITextRow] {
        var rows: [TrayAITextRow] = []
        for line in lines.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            let match = rows.indices.last { index in
                let row = rows[index]
                let tolerance = min(row.height, line.rect.height) * 0.55
                guard abs(row.rect.midY - line.rect.midY) <= tolerance else { return false }
                return !row.segments.contains { $0.rect.intersects(line.rect.insetBy(dx: 2, dy: 2)) }
            }
            if let match {
                rows[match].segments.append(line)
                rows[match].segments.sort { $0.rect.minX < $1.rect.minX }
                rows[match].rect = rows[match].rect.union(line.rect)
            } else {
                rows.append(TrayAITextRow(segments: [line], rect: line.rect))
            }
        }
        return rows.sorted { $0.rect.minY < $1.rect.minY }
    }

    // MARK: Colors

    struct Palette: Sendable {
        var colors: [TrayAIColor]
        var background: Double
        var meanLuminance: Double
    }

    /// k-means (k = 8, deterministic farthest-point seeding) over a 96 px
    /// downsample in sRGB. Clusters closer than a small distance are merged.
    static func dominantColors(_ image: CGImage, k: Int = 8) -> Palette {
        let maxSide = 96
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return Palette(colors: [], background: 0, meanLuminance: 0) }

        var pixels: [SIMD3<Double>] = []
        pixels.reserveCapacity(width * height)
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let alpha = Double(buffer[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            pixels.append(SIMD3(Double(buffer[i]) / 255 / alpha, Double(buffer[i + 1]) / 255 / alpha, Double(buffer[i + 2]) / 255 / alpha))
        }
        guard !pixels.isEmpty else { return Palette(colors: [], background: 0, meanLuminance: 0) }

        func dist(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let d = a - b
            return d.x * d.x * 0.30 + d.y * d.y * 0.59 + d.z * d.z * 0.11
        }

        // Farthest-point seeding from the mean: deterministic and spreads out.
        var centers: [SIMD3<Double>] = []
        let mean = pixels.reduce(SIMD3<Double>(repeating: 0), +) / Double(pixels.count)
        var nearest = pixels.map { dist($0, mean) }
        centers.append(pixels[nearest.indices.max { nearest[$0] < nearest[$1] } ?? 0])
        nearest = pixels.map { dist($0, centers[0]) }
        while centers.count < min(k, pixels.count) {
            guard let farthest = nearest.indices.max(by: { nearest[$0] < nearest[$1] }), nearest[farthest] > 1e-6 else { break }
            centers.append(pixels[farthest])
            for i in pixels.indices { nearest[i] = min(nearest[i], dist(pixels[i], pixels[farthest])) }
        }

        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<12 {
            var sums = [SIMD3<Double>](repeating: SIMD3(repeating: 0), count: centers.count)
            var counts = [Int](repeating: 0, count: centers.count)
            for (i, p) in pixels.enumerated() {
                var best = 0, bestD = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = dist(p, center)
                    if d < bestD { bestD = d; best = c }
                }
                assignment[i] = best
                sums[best] += p
                counts[best] += 1
            }
            var moved = 0.0
            for c in centers.indices where counts[c] > 0 {
                let next = sums[c] / Double(counts[c])
                moved = max(moved, dist(next, centers[c]))
                centers[c] = next
            }
            if moved < 1e-6 { break }
        }

        var counts = [Int](repeating: 0, count: centers.count)
        assignment.forEach { counts[$0] += 1 }
        var clusters: [(SIMD3<Double>, Int)] = centers.indices.compactMap { counts[$0] > 0 ? (centers[$0], counts[$0]) : nil }
        clusters.sort { $0.1 > $1.1 }
        // Merge near-duplicates (anti-aliasing produces many close shades).
        var merged: [(SIMD3<Double>, Int)] = []
        for cluster in clusters {
            if let index = merged.firstIndex(where: { dist($0.0, cluster.0) < 0.004 }) {
                let total = merged[index].1 + cluster.1
                merged[index].0 = (merged[index].0 * Double(merged[index].1) + cluster.0 * Double(cluster.1)) / Double(total)
                merged[index].1 = total
            } else {
                merged.append(cluster)
            }
        }
        merged.sort { $0.1 > $1.1 }
        let total = Double(pixels.count)
        let colors = merged
            .map { TrayAIColor(red: $0.0.x, green: $0.0.y, blue: $0.0.z, fraction: Double($0.1) / total) }
            .filter { $0.fraction >= 0.01 }

        var background = 0.0
        if let top = merged.first?.0 {
            background = Double(pixels.filter { dist($0, top) < 0.0025 }.count) / total
        }
        let lum = pixels.reduce(0.0) { $0 + 0.2126 * $1.x + 0.7152 * $1.y + 0.0722 * $1.z } / total
        return Palette(colors: colors, background: background, meanLuminance: lum)
    }

    // MARK: Language

    /// Dominant language of `text`, or nil when unsure.
    static func detectLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return confidence >= 0.3 ? language : nil
    }

    static func languageName(_ language: NLLanguage) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: language.rawValue) ?? language.rawValue
    }
}

// MARK: - Files

struct TrayAIFileContent: Sendable, Equatable {
    var name: String
    var typeDescription: String
    /// Readable text when the file has any (truncated to `TrayAIFiles.maxCharacters`).
    var text: String?
    var metadata: String
    var pageCount: Int?
    var isImage: Bool
}

enum TrayAIFiles {
    static let maxCharacters = 200_000
    static let maxBytes = 8 * 1024 * 1024

    static func read(_ url: URL) async -> TrayAIFileContent {
        await Task.detached(priority: .userInitiated) { readSync(url) }.value
    }

    static func readSync(_ url: URL) -> TrayAIFileContent {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let size = values?.fileSize ?? 0
        var meta = ["Name: \(url.lastPathComponent)", "Kind: \(type.localizedDescription ?? type.identifier)"]
        if size > 0 { meta.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))") }
        if let date = values?.contentModificationDate {
            meta.append("Modified: \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        var content = TrayAIFileContent(
            name: url.lastPathComponent, typeDescription: type.localizedDescription ?? type.identifier,
            text: nil, metadata: "", pageCount: nil, isImage: type.conforms(to: .image)
        )

        if values?.isDirectory == true {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
            meta.append("Contains \(names.count) item(s)")
            content.text = names.prefix(80).map { "• \($0)" }.joined(separator: "\n")
        } else if type.conforms(to: .pdf) {
            if let document = PDFDocument(url: url) {
                content.pageCount = document.pageCount
                meta.append("Pages: \(document.pageCount)")
                var text = document.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    text = ocrPDF(document, pages: 3)
                }
                content.text = text
            }
        } else if type.conforms(to: .html) {
            if let html = readString(url) { content.text = TrayAIHTML.readableText(html).text }
        } else if type.conforms(to: .rtf) || type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD)
                    || type.identifier == "org.openxmlformats.wordprocessingml.document"
                    || type.identifier == "com.microsoft.word.doc"
                    || type.identifier == "org.oasis-open.opendocument.text" {
            content.text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) {
            content.text = readString(url)
        } else if !content.isImage, size > 0, size <= maxBytes, let data = try? Data(contentsOf: url),
                  !data.prefix(4096).contains(0), let text = String(data: data, encoding: .utf8) {
            content.text = text
        }
        if let text = content.text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            content.text = trimmed.isEmpty ? nil : String(trimmed.prefix(maxCharacters))
        }
        content.metadata = meta.joined(separator: "\n")
        return content
    }

    static func readString(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let slice = data.prefix(maxBytes)
        if let text = String(data: slice, encoding: .utf8) { return text }
        if let text = String(data: slice, encoding: .utf16) { return text }
        return String(data: slice, encoding: .isoLatin1)
    }

    /// Scanned PDFs: render the first pages and OCR them.
    static func ocrPDF(_ document: PDFDocument, pages: Int) -> String {
        var parts: [String] = []
        for index in 0..<min(pages, document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2000 / max(bounds.width, bounds.height, 1)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let analysis = TrayAIOCR.analyzeSync(image)
            if analysis.hasText { parts.append(analysis.looksTabular ? analysis.rowText : analysis.text) }
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Web pages

struct TrayAIWebPage: Sendable, Equatable {
    var url: URL
    var title: String?
    var siteName: String?
    var summary: String?
    var text: String
}

enum TrayAIWeb {
    static let maxBytes = 5 * 1024 * 1024

    /// Downloads a page (no cookies, 15 s) and reduces it to readable text.
    /// Only called when the user runs an action on a link item.
    static func fetch(_ url: URL) async throws -> TrayAIWebPage {
        var candidates = [url]
        if url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if let secure = components.url { candidates.insert(secure, at: 0) }
        }
        var lastError: Error = TrayAIError.fetchFailed("no response")
        for candidate in candidates {
            do {
                return try await fetchOnce(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetchOnce(_ url: URL) async throws -> TrayAIWebPage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "user-agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,application/pdf;q=0.8,*/*;q=0.5", forHTTPHeaderField: "accept")
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "accept-language")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw TrayAIError.fetchFailed("the site only offers insecure http")
        } catch {
            throw TrayAIError.fetchFailed(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        guard (200..<400).contains(status) else { throw TrayAIError.fetchFailed("HTTP \(status)") }
        let body = data.prefix(maxBytes)
        let finalURL = response.url ?? url
        let mime = (response.mimeType ?? "").lowercased()

        if mime == "application/pdf", let document = PDFDocument(data: Data(body)) {
            return TrayAIWebPage(url: finalURL, title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                                 siteName: finalURL.host, summary: nil, text: document.string ?? "")
        }
        if mime.hasPrefix("image/"), let image = TrayAIOCR.loadImage(data: Data(body), maxPixel: TrayAIOCR.analysisMaxPixel) {
            let analysis = TrayAIOCR.analyzeSync(image)
            return TrayAIWebPage(url: finalURL, title: finalURL.lastPathComponent, siteName: finalURL.host, summary: nil, text: analysis.text)
        }
        let string = decode(Data(body), encodingName: response.textEncodingName)
        if mime.hasPrefix("text/plain") || mime == "text/markdown" {
            return TrayAIWebPage(url: finalURL, title: finalURL.lastPathComponent, siteName: finalURL.host, summary: nil, text: string)
        }
        let readable = TrayAIHTML.readableText(string)
        return TrayAIWebPage(url: finalURL, title: readable.title, siteName: readable.siteName ?? finalURL.host,
                             summary: readable.description, text: readable.text)
    }

    static func decode(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName ?? sniffCharset(data) {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func sniffCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        return TrayAIRegex.firstGroup(#"<meta[^>]+charset=["']?([A-Za-z0-9_\-]+)"#, in: head)
    }
}

// MARK: - HTML to readable text

enum TrayAIHTML {
    struct Readable: Sendable, Equatable {
        var title: String?
        var siteName: String?
        var description: String?
        var text: String
    }

    /// Main-content heuristics: prefer the longest <article>, then <main>,
    /// then <body>; drop scripts, navigation, headers/footers, forms and
    /// asides; split into blocks and drop link-heavy or boilerplate blocks.
    static func readableText(_ html: String) -> Readable {
        var html = TrayAIRegex.replace(#"<!--[\s\S]*?-->"#, in: html, with: " ")
        let metas = metaTags(html)
        let rawTitle = TrayAIRegex.firstGroup(#"<title[^>]*>([\s\S]*?)</title>"#, in: html)
        let title = (metas["og:title"] ?? metas["twitter:title"] ?? rawTitle.map(decodeEntities))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description = metas["og:description"] ?? metas["description"]
        let siteName = metas["og:site_name"]

        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head", "canvas", "select", "button"] {
            html = TrayAIRegex.replace("<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", in: html, with: " ")
        }

        var container = html
        let articles = TrayAIRegex.matches(#"<article\b[\s\S]*?</article\s*>"#, in: html)
        if let best = articles.max(by: { strippedLength($0) < strippedLength($1) }), strippedLength(best) >= 400 {
            container = best
        } else if let main = TrayAIRegex.matches(#"<main\b[\s\S]*?</main\s*>"#, in: html).first, strippedLength(main) >= 300 {
            container = main
        } else if let body = TrayAIRegex.firstGroup(#"<body[^>]*>([\s\S]*)</body"#, in: html) {
            container = TrayAIRegex.replace(#"<header\b[\s\S]*?</header\s*>"#, in: body, with: " ")
        }
        for tag in ["nav", "footer", "aside", "form", "figure"] {
            container = TrayAIRegex.replace("<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", in: container, with: " ")
        }

        // Mark link text (\u{2}…\u{3}) to measure link density per block.
        container = TrayAIRegex.replace(#"<a\b[^>]*>"#, in: container, with: "\u{2}")
        container = TrayAIRegex.replace(#"</a\s*>"#, in: container, with: "\u{3}")
        container = TrayAIRegex.replace(#"<h[1-6]\b[^>]*>"#, in: container, with: "\n\u{1}")
        container = TrayAIRegex.replace(#"<li\b[^>]*>"#, in: container, with: "\n• ")
        container = TrayAIRegex.replace(#"<(td|th)\b[^>]*>"#, in: container, with: " ")
        container = TrayAIRegex.replace(#"</?(p|div|section|ul|ol|h[1-6]|tr|br|blockquote|pre|table|dd|dt|dl|hr|header|address|figcaption|li)\b[^>]*>"#, in: container, with: "\n")
        container = TrayAIRegex.replace(#"<[^>]+>"#, in: container, with: " ")
        container = decodeEntities(container)

        let boilerplate = #"(?i)(cookie|subscribe|newsletter|sign (in|up)|log ?in|all rights reserved|privacy policy|terms of (use|service)|share (this|on)|advertisement|skip to (main )?content|accept all|©)"#
        var kept: [String] = []
        for raw in container.components(separatedBy: "\n") {
            let isHeading = raw.contains("\u{1}")
            let linkChars = linkCharacterCount(raw)
            var line = raw.replacingOccurrences(of: "\u{1}", with: "")
                .replacingOccurrences(of: "\u{2}", with: "").replacingOccurrences(of: "\u{3}", with: "")
            line = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !line.isEmpty, line != "•" else { continue }
            let length = line.count
            let density = Double(linkChars) / Double(max(length, 1))
            if density > 0.5 && length < 300 { continue }
            if length < 120, TrayAIRegex.matches(boilerplate, in: line).count > 0 { continue }
            let isBullet = line.hasPrefix("• ")
            if !isHeading && !isBullet && length < 25 && !line.contains(where: { ".!?:".contains($0) }) { continue }
            if isHeading {
                kept.append("\n## " + line)
            } else {
                kept.append(line)
            }
        }
        // Headings with nothing after them are usually menus.
        var text: [String] = []
        for (index, line) in kept.enumerated() {
            if line.hasPrefix("\n## ") && (index + 1 >= kept.count || kept[index + 1].hasPrefix("\n## ")) { continue }
            if text.last != line { text.append(line) }
        }
        let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Readable(title: title.flatMap { $0.isEmpty ? nil : $0 }, siteName: siteName,
                        description: description, text: joined)
    }

    private static func strippedLength(_ html: String) -> Int {
        TrayAIRegex.replace(#"<[^>]+>"#, in: html, with: "").filter { !$0.isWhitespace }.count
    }

    private static func linkCharacterCount(_ line: String) -> Int {
        var count = 0, inLink = false
        for character in line {
            if character == "\u{2}" { inLink = true } else if character == "\u{3}" { inLink = false }
            else if inLink && !character.isWhitespace { count += 1 }
        }
        // Normalize to the whitespace-collapsed length used by the caller.
        return count
    }

    /// name/property → content for every <meta> tag.
    static func metaTags(_ html: String) -> [String: String] {
        var result: [String: String] = [:]
        for tag in TrayAIRegex.matches(#"<meta\b[^>]*>"#, in: html) {
            var attributes: [String: String] = [:]
            for match in TrayAIRegex.groups(#"([a-zA-Z:_\-]+)\s*=\s*("([^"]*)"|'([^']*)')"#, in: tag) {
                let name = match[0].lowercased()
                attributes[name] = match.count > 2 ? (match[2].isEmpty ? match[3] : match[2]) : ""
            }
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"], !content.isEmpty else { continue }
            if result[key] == nil { result[key] = decodeEntities(content) }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—",
            "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”",
            "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•", "euro": "€", "pound": "£",
            "yen": "¥", "cent": "¢", "deg": "°", "times": "×", "laquo": "«", "raquo": "»", "shy": "",
        ]
        guard let regex = try? NSRegularExpression(pattern: "&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);") else { return text }
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                replacement = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[body.lowercased()]
            }
            output += replacement ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}

// MARK: - Regex helpers

enum TrayAIRegex {
    static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = regex(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = regex(pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Capture groups (1...n) of every match; missing groups are "".
    static func groups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = regex(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<max(match.numberOfRanges, 1)).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

// MARK: - Receipts

struct TrayAIReceipt: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var name: String
        var qty: Double?
        var unitPrice: Double?
        var total: Double?
    }

    var merchant: String?
    var date: String?
    var currency: String?
    var items: [Item] = []
    var subtotal: Double?
    var tax: Double?
    var tip: Double?
    var total: Double?
    var paymentMethod: String?
    var warnings: [String] = []

    var isEmpty: Bool { items.isEmpty && total == nil && subtotal == nil }

    /// How trustworthy the numbers look (higher is better).
    var consistencyScore: Int {
        var score = items.count + (total != nil ? 3 : 0) + (subtotal != nil ? 1 : 0) + (merchant != nil ? 1 : 0)
        score -= warnings.count * 2
        return score
    }

    /// Sum checks; replaces `warnings` with what doesn't add up.
    mutating func validate() {
        var notes: [String] = []
        let tolerance = 0.015
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(tolerance, abs(b) * 0.001) }
        func money(_ v: Double) -> String { TrayAIReceipt.format(v) }

        for (index, item) in items.enumerated() {
            if let qty = item.qty, let unit = item.unitPrice, let total = item.total, !near(qty * unit, total) {
                notes.append("Item \(index + 1) (\(item.name)): \(TrayAIReceipt.format(qty, decimals: 3)) × \(money(unit)) = \(money(qty * unit)), but the line total is \(money(total))")
            }
            if item.total == nil, let qty = item.qty, let unit = item.unitPrice {
                items[index].total = (qty * unit * 100).rounded() / 100
            }
        }
        let itemTotals = items.compactMap(\.total)
        let itemsSum = (itemTotals.reduce(0, +) * 100).rounded() / 100
        if itemTotals.count < items.count { notes.append("\(items.count - itemTotals.count) item(s) have no price") }
        if let subtotal, !itemTotals.isEmpty, !near(itemsSum, subtotal) {
            notes.append("Items add up to \(money(itemsSum)) but the subtotal is \(money(subtotal)) (difference \(money(subtotal - itemsSum)))")
        }
        let base = subtotal ?? (itemTotals.isEmpty ? nil : itemsSum)
        if let total {
            if let base {
                let expected = base + (tax ?? 0) + (tip ?? 0)
                if !near(expected, total) {
                    let parts = ["subtotal \(money(base))"] + (tax.map { ["tax \(money($0))"] } ?? []) + (tip.map { ["tip \(money($0))"] } ?? [])
                    notes.append("\(parts.joined(separator: " + ")) = \(money(expected)), but the total is \(money(total)) (difference \(money(total - expected)))")
                }
            }
        } else {
            notes.append("No total found")
        }
        if items.isEmpty { notes.append("No line items found") }
        warnings = notes
    }

    static func format(_ value: Double, decimals: Int = 2) -> String {
        let rounded = (value * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        if decimals == 3, rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.\(decimals)f", rounded)
    }

    /// Ordered, pretty JSON (keys in the documented order, nulls explicit).
    var json: String {
        func string(_ value: String?) -> String {
            guard let value else { return "null" }
            let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
        /// Money: always two decimals (valid JSON numbers, e.g. 9.00).
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "null" }
            return TrayAIReceipt.format(value, decimals: 2)
        }
        func quantity(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "null" }
            return TrayAIReceipt.format(value, decimals: 3)
        }
        var lines = ["{"]
        lines.append("  \"merchant\": \(string(merchant)),")
        lines.append("  \"date\": \(string(date)),")
        lines.append("  \"currency\": \(string(currency)),")
        if items.isEmpty {
            lines.append("  \"items\": [],")
        } else {
            lines.append("  \"items\": [")
            for (index, item) in items.enumerated() {
                let comma = index == items.count - 1 ? "" : ","
                lines.append("    {\"name\": \(string(item.name)), \"qty\": \(quantity(item.qty)), \"unitPrice\": \(number(item.unitPrice)), \"total\": \(number(item.total))}\(comma)")
            }
            lines.append("  ],")
        }
        lines.append("  \"subtotal\": \(number(subtotal)),")
        lines.append("  \"tax\": \(number(tax)),")
        lines.append("  \"tip\": \(number(tip)),")
        lines.append("  \"total\": \(number(total)),")
        lines.append("  \"paymentMethod\": \(string(paymentMethod)),")
        if warnings.isEmpty {
            lines.append("  \"warnings\": []")
        } else {
            lines.append("  \"warnings\": [")
            lines.append(warnings.map { "    \(string($0))" }.joined(separator: ",\n"))
            lines.append("  ]")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Reads a model's JSON reply into a receipt (tolerant of strings for
    /// numbers, alternative key names and missing fields).
    static func from(object: [String: Any]) -> TrayAIReceipt {
        func str(_ value: Any?) -> String? {
            switch value {
            case let s as String:
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty || t.lowercased() == "null" ? nil : t
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        func num(_ value: Any?) -> Double? {
            switch value {
            case let n as NSNumber:
                return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
            case let s as String: return TrayAIReceiptParser.parseAmount(s)
            default: return nil
            }
        }
        var receipt = TrayAIReceipt()
        receipt.merchant = str(object["merchant"] ?? object["store"])
        receipt.date = str(object["date"])
        receipt.currency = str(object["currency"])?.uppercased()
        receipt.subtotal = num(object["subtotal"])
        receipt.tax = num(object["tax"])
        receipt.tip = num(object["tip"])
        receipt.total = num(object["total"])
        receipt.paymentMethod = str(object["paymentMethod"] ?? object["payment_method"] ?? object["payment"])
        receipt.items = ((object["items"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let name = str(entry["name"] ?? entry["description"]) else { return nil }
            return Item(name: name, qty: num(entry["qty"] ?? entry["quantity"]),
                        unitPrice: num(entry["unitPrice"] ?? entry["unit_price"] ?? entry["price"]),
                        total: num(entry["total"] ?? entry["amount"]))
        }
        return receipt
    }
}

/// Deterministic receipt reading from OCR rows: prices at line ends,
/// quantity patterns ("2 x 3.50", "2 @ 3.50", "3 Bagel"), keyword lines for
/// subtotal/tax/tip/total/payment, a date, a currency and the merchant name
/// (tallest text near the top).
enum TrayAIReceiptParser {
    static let amountPattern = #"[-−]?\(?(?:[$€£₹¥]|USD|EUR|GBP|INR|CAD|AUD|JPY)?\s?(?:\d{1,3}(?:[,.]\d{3})+[.,]\d{2}|\d+[.,]\d{2})(?!\d)\)?|[-−]?\(?(?:[$€£₹¥])\s?\d+(?![.,\d])\)?"#

    static func parse(rows: [TrayAITextRow]) -> TrayAIReceipt {
        parse(lines: rows.map { ($0.text, $0.height) })
    }

    static func parse(text: String) -> TrayAIReceipt {
        parse(lines: text.components(separatedBy: .newlines).map { ($0, 0) })
    }

    static func parse(lines input: [(String, CGFloat)]) -> TrayAIReceipt {
        var receipt = TrayAIReceipt()
        let lines = joinSplitPrices(input.map { ($0.0.trimmingCharacters(in: .whitespaces), $0.1) }.filter { !$0.0.isEmpty })
        let allText = lines.map(\.0).joined(separator: "\n")
        receipt.currency = currency(in: allText)
        receipt.date = date(in: allText)
        receipt.paymentMethod = payment(in: allText)
        receipt.merchant = merchant(lines)

        var reachedTotals = false
        for (line, _) in lines {
            let lower = line.lowercased()
            let amounts = TrayAIRegex.matches(amountPattern, in: line)
            guard let last = amounts.last, let value = parseAmount(last) else { continue }
            let label = labelPart(line, removing: last)
            let labelLower = label.lowercased()

            if matches(labelLower, #"\bsub[\s\-]?total\b"#) {
                receipt.subtotal = value; reachedTotals = true
            } else if matches(labelLower, #"\b(tax|vat|gst|hst|pst|sales tax|cgst|sgst)\b"#) {
                receipt.tax = (receipt.tax ?? 0) + value; reachedTotals = true
            } else if matches(labelLower, #"\b(tip|gratuity|service charge)\b"#) {
                receipt.tip = (receipt.tip ?? 0) + value; reachedTotals = true
            } else if matches(labelLower, #"\b(grand total|total due|amount due|balance due|total amount|total|amount)\b"#) {
                // The largest "total" wins (some receipts repeat it).
                if receipt.total == nil || value >= (receipt.total ?? 0) { receipt.total = value }
                reachedTotals = true
            } else if matches(labelLower, #"\b(change|cash tendered|tendered|cash|visa|mastercard|amex|debit|credit|card|paid|payment|balance|points|savings|you saved|discount total)\b"#) {
                continue
            } else if matches(lower, #"\b(tel|phone|fax|order #|order no|invoice|receipt #|table|guests|server|cashier|store #)\b"#) && label.count < 4 {
                continue
            } else if !reachedTotals {
                if var item = item(label: label, amounts: amounts, value: value) {
                    if matches(labelLower, #"\b(discount|coupon|promo)\b"#), (item.total ?? 0) > 0 { item.total = -(item.total ?? 0) }
                    receipt.items.append(item)
                }
            }
        }
        receipt.validate()
        return receipt
    }

    /// OCR often reads a wide receipt line as two rows ("Croissant" then
    /// "3.75"): a label-only line followed by a price-only line is one line.
    static func joinSplitPrices(_ lines: [(String, CGFloat)]) -> [(String, CGFloat)] {
        var result: [(String, CGFloat)] = []
        var index = 0
        while index < lines.count {
            let (line, height) = lines[index]
            if index + 1 < lines.count,
               line.contains(where: \.isLetter), TrayAIRegex.matches(amountPattern, in: line).isEmpty,
               isPriceOnly(lines[index + 1].0) {
                result.append((line + "  " + lines[index + 1].0, max(height, lines[index + 1].1)))
                index += 2
            } else {
                result.append((line, height))
                index += 1
            }
        }
        return result
    }

    private static func isPriceOnly(_ line: String) -> Bool {
        let amounts = TrayAIRegex.matches(amountPattern, in: line)
        guard amounts.count == 1, let amount = amounts.first else { return false }
        let rest = line.replacingOccurrences(of: amount, with: "")
        return !rest.contains(where: { $0.isLetter || $0.isNumber })
    }

    private static func item(label: String, amounts: [String], value: Double) -> TrayAIReceipt.Item? {
        var name = label
        var qty: Double?
        var unit: Double?
        // "2 x 3.50" / "2 @ 3.50" inside the line.
        if let groups = TrayAIRegex.groups(#"(\d+(?:[.,]\d+)?)\s*(?:x|×|@)\s*(?:[$€£₹¥])?\s?(\d+[.,]\d{2})"#, in: label).first {
            qty = Double(groups[0].replacingOccurrences(of: ",", with: "."))
            unit = parseAmount(groups[1])
            name = TrayAIRegex.replace(#"(\d+(?:[.,]\d+)?)\s*(?:x|×|@)\s*(?:[$€£₹¥])?\s?(\d+[.,]\d{2})"#, in: name, with: "")
        } else if let groups = TrayAIRegex.groups(#"^(\d{1,3})\s*(?:x|×)?\s+(\D.*)$"#, in: label).first {
            // Leading quantity: "2 Latte".
            qty = Double(groups[0])
            name = groups[1]
            if let qty, qty > 0 { unit = (value / qty * 100).rounded() / 100 }
            // "2 x Latte @ 4.50": the unit price follows "@".
            if let at = TrayAIRegex.groups(#"(?:@|each|ea\.?)\s*(?:[$€£₹¥])?\s?(\d+[.,]\d{2})"#, in: name).first {
                unit = parseAmount(at[0]) ?? unit
                name = TrayAIRegex.replace(#"(?:@|each|ea\.?)\s*(?:[$€£₹¥])?\s?(\d+[.,]\d{2})"#, in: name, with: "")
            }
        } else if amounts.count >= 2, let first = parseAmount(amounts[amounts.count - 2]) {
            unit = first
            if first > 0 { qty = ((value / first) * 1000).rounded() / 1000 }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .:-*#\t"))
        name = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard name.count >= 2, name.contains(where: \.isLetter) else { return nil }
        return TrayAIReceipt.Item(name: name, qty: qty ?? 1, unitPrice: unit ?? value, total: value)
    }

    private static func labelPart(_ line: String, removing amount: String) -> String {
        var label = line
        if let range = label.range(of: amount, options: .backwards) { label.removeSubrange(range) }
        // Drop trailing currency codes / tax flags like "T", "A", "F".
        label = TrayAIRegex.replace(#"\s+(?:[A-Z]{1}|USD|EUR|GBP|INR)\s*$"#, in: label, with: "")
        return label.trimmingCharacters(in: CharacterSet(charactersIn: " :\t$€£₹¥"))
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        TrayAIRegex.regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "1,234.56", "1.234,56", "$12.00", "(3.00)" → Double.
    static func parseAmount(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        let negative = s.hasPrefix("-") || s.hasPrefix("−") || (s.hasPrefix("(") && s.hasSuffix(")"))
        s = s.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard !s.isEmpty else { return nil }
        if let lastSeparator = s.lastIndex(where: { $0 == "." || $0 == "," }) {
            let decimals = s.distance(from: lastSeparator, to: s.endIndex) - 1
            if decimals == 2 || decimals == 1 {
                let whole = s[..<lastSeparator].filter(\.isNumber)
                let fraction = s[s.index(after: lastSeparator)...]
                s = "\(whole).\(fraction)"
            } else {
                s = s.filter(\.isNumber)
            }
        }
        guard let value = Double(s) else { return nil }
        return negative ? -value : value
    }

    static func currency(in text: String) -> String? {
        let codes = ["USD", "EUR", "GBP", "INR", "CAD", "AUD", "JPY", "CHF", "SGD", "AED"]
        if let code = codes.first(where: { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) { return code }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        if text.contains("₹") || text.range(of: #"\bRs\.?\s?\d"#, options: .regularExpression) != nil { return "INR" }
        if text.contains("¥") { return "JPY" }
        if text.contains("$") { return "USD" }
        return nil
    }

    static func date(in text: String) -> String? {
        let patterns = [
            #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#,
            #"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})\b"#,
            #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4}\b"#,
            #"\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{4}\b"#,
        ]
        for pattern in patterns {
            if let match = TrayAIRegex.matches(pattern, in: text).first { return normalizeDate(match) }
        }
        return nil
    }

    /// ISO 8601 when unambiguous, otherwise the text as printed.
    private static func normalizeDate(_ raw: String) -> String {
        if let g = TrayAIRegex.groups(#"^(\d{4})-(\d{1,2})-(\d{1,2})$"#, in: raw).first,
           let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) {
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        if let g = TrayAIRegex.groups(#"^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})$"#, in: raw).first,
           let a = Int(g[0]), let b = Int(g[1]), var y = Int(g[2]) {
            if y < 100 { y += 2000 }
            if a > 12, b <= 12 { return String(format: "%04d-%02d-%02d", y, b, a) }
            if b > 12, a <= 12 { return String(format: "%04d-%02d-%02d", y, a, b) }
            // Ambiguous day/month: follow the user's locale (US: month first).
            let monthFirst = (Locale.current.region?.identifier ?? "US") == "US"
            return String(format: "%04d-%02d-%02d", y, monthFirst ? a : b, monthFirst ? b : a)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["MMM d, yyyy", "MMMM d, yyyy", "MMM d yyyy", "d MMM yyyy", "d MMMM yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "Sept", with: "Sep")) {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }
        return raw
    }

    static func payment(in text: String) -> String? {
        let lower = text.lowercased()
        let brands: [(String, String)] = [
            ("apple pay", "Apple Pay"), ("google pay", "Google Pay"), ("visa", "Visa"), ("mastercard", "Mastercard"),
            ("master card", "Mastercard"), ("amex", "American Express"), ("american express", "American Express"),
            ("discover", "Discover"), ("upi", "UPI"), ("paypal", "PayPal"), ("debit", "Debit card"),
            ("credit", "Credit card"), ("cash", "Cash"),
        ]
        guard let brand = brands.first(where: { lower.range(of: "\\b\($0.0)\\b", options: .regularExpression) != nil }) else { return nil }
        if let last4 = TrayAIRegex.firstGroup(#"(?:\*{2,}|x{2,}|ending(?: in)?|#)\s*(\d{4})\b"#, in: lower) {
            return "\(brand.1) ••••\(last4)"
        }
        return brand.1
    }

    private static func merchant(_ lines: [(String, CGFloat)]) -> String? {
        let top = Array(lines.prefix(6))
        let candidates = top.filter { line, _ in
            let letters = line.filter(\.isLetter).count
            guard letters >= 3, Double(letters) / Double(max(line.count, 1)) > 0.5 else { return false }
            let lower = line.lowercased()
            if matches(lower, #"\b(receipt|invoice|tel|phone|www\.|http|street|st\.|ave|road|rd\.|suite|order|date|welcome)\b"#) { return false }
            return TrayAIRegex.matches(amountPattern, in: line).isEmpty
        }
        if let tallest = candidates.max(by: { $0.1 < $1.1 }), tallest.1 > 0 { return tallest.0 }
        return candidates.first?.0
    }

    /// Heuristic: the OCR text looks like a receipt.
    static func looksLikeReceipt(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["total", "subtotal", "tax", "receipt", "change", "visa", "cash", "qty", "amount due", "tip"]
        let hits = keywords.filter { lower.contains($0) }.count
        let amounts = TrayAIRegex.matches(amountPattern, in: text).count
        return hits >= 2 && amounts >= 3
    }
}
