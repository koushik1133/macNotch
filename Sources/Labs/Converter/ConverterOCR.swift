import CoreGraphics
import Foundation
import Vision

/// On-device text recognition (Vision) for scanned PDF pages.
enum ConverterOCR {
    struct Line: Sendable {
        let text: String
        /// Normalized to the image, origin bottom-left (same as PDF space).
        let box: CGRect
    }

    static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox)
        }
    }

    /// Lines in reading order: top to bottom, then left to right; lines on
    /// the same row are joined with a space.
    static func joined(_ lines: [Line]) -> String {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[Line]] = []
        for line in sorted {
            if let last = rows.last?.last,
               abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        rows = rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
        return rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }
}
