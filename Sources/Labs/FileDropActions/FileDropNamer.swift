import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import Vision

/// Descriptive file names from a file's content, the way AI renamers
/// (Hazel-style rules + an LLM pass) do it: read the content (Vision OCR and
/// scene labels for images, the text layer or OCR for PDFs, the text of
/// documents), ask the on-device model for a short name, then normalise it.
/// Without Apple Intelligence a heuristic picks the title line and any date.
/// Nothing leaves the Mac.
enum FileDropNamer {
    /// What the namer saw in a file.
    struct Context: Sendable, Equatable {
        var originalName: String
        var typeDescription: String
        var text: String
        var labels: [String]
        var created: Date?
        var isImage: Bool
    }

    struct Suggestion: Sendable, Equatable {
        var name: String
        /// Shown under the field: "On-device AI", "From the title", …
        var source: String
    }

    static let maxContentCharacters = 2_400

    // MARK: Reading

    static func context(for url: URL) async -> Context {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .creationDateKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        var context = Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            typeDescription: type.localizedDescription ?? url.pathExtension.uppercased(),
            text: "", labels: [], created: values?.creationDate, isImage: type.conforms(to: .image)
        )
        // Vision and PDF OCR can stall when the Neural Engine is busy; a
        // name is never worth more than `readTimeout`, so fall back to what
        // we have (the heuristic still uses the date and current name).
        if context.isImage {
            if let read = try? await MeetingAITimeout.run(seconds: readTimeout, operation: {
                await FileDropImageReads.shared.read(url)
            }) {
                context.text = read.text
                context.labels = read.labels
            } else {
                AppLog.log("FileDrop: image reading timed out")
            }
        } else if let content = try? await MeetingAITimeout.run(seconds: readTimeout, operation: { await TrayAIFiles.read(url) }) {
            context.text = content.text ?? ""
        } else {
            AppLog.log("FileDrop: file reading timed out")
        }
        context.text = String(tidy(context.text).prefix(maxContentCharacters))
        return context
    }

    static let readTimeout: Double = 45

    /// Loads the Vision text and scene models in the background (at
    /// launch), so the first Rename doesn't pay their cold start.
    static func prewarmVision() {
        Task.detached(priority: .utility) {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 12, y: 12, width: 6, height: 24))
            context.fill(CGRect(x: 30, y: 12, width: 6, height: 24))
            guard let cgImage = context.makeImage() else { return }
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .fast
            let classify = VNClassifyImageRequest()
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([text])
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([classify])
        }
    }

    /// Text (Vision OCR, reading order) and scene labels for an image, on a
    /// copy at most 2048 px wide. Text and labels run as separate requests
    /// so one failing doesn't lose the other.
    nonisolated static func readImageSync(_ url: URL) -> (text: String, labels: [String]) {
        guard let image = TrayAIOCR.loadImage(at: url, maxPixel: 2048) else { return ("", []) }
        func recognize(_ level: VNRequestTextRecognitionLevel) -> (lines: [ConverterOCR.Line], failed: Bool) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = level == .accurate
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                return ([], true)
            }
            let lines = (request.results ?? []).compactMap { observation -> ConverterOCR.Line? in
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                return ConverterOCR.Line(text: text, box: observation.boundingBox)
            }
            return (lines, false)
        }
        // The fast recognizer (CPU, ~0.1 s) reads titles and headings well,
        // which is all a name needs; the accurate one runs on the Neural
        // Engine and can stall for a minute on a busy or cold one. Only
        // when fast finds next to nothing (small or stylised text) is the
        // accurate one tried.
        let classify = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([classify])
        let ranked = (classify.results ?? []).filter { $0.confidence >= 0.3 }.sorted { $0.confidence > $1.confidence }
        let labels = ranked.prefix(5).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        var result = recognize(.fast)
        // Photos of skies and people skip the slow pass; documents,
        // screenshots, signs and receipts get it.
        let looksTextual = ranked.contains { label in textualLabels.contains { label.identifier.contains($0) } }
        if looksTextual, result.lines.map(\.text).joined().filter(\.isLetter).count < 12 {
            let accurate = recognize(.accurate)
            if !accurate.failed, !accurate.lines.isEmpty { result = accurate }
        }
        return (ConverterOCR.joined(result.lines), Array(labels))
    }

    static let textualLabels = ["document", "screenshot", "text", "paper", "printed", "receipt", "menu", "poster",
                                "sign", "handwriting", "book", "whiteboard", "diagram", "chart", "letter", "card"]

    /// Runs of spaces collapsed, blank lines dropped; line breaks kept so
    /// the heuristic can find the title line.
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Suggesting

    static let instructions = """
    You name files on a Mac. Read what the file contains and reply with one short, descriptive file name \
    of 2 to 7 words. Put the most specific facts first: who or what it is about, the kind of document, an \
    identifying number, then a date. Write dates found in the content as YYYY-MM-DD. Use only facts that \
    appear in the content or the image labels; never invent names, numbers or dates. No file extension, \
    no quotes, no emoji, no slashes, no colons.
    """

    static let schema = MeetingAISchema.object(name: "FileName", properties: [
        .init(name: "name", description: "The new file name, 2 to 7 words, without an extension", schema: .string),
    ])

    static func prompt(for context: Context, avoiding: String? = nil) -> String {
        var lines = ["Current name: \(context.originalName)", "File type: \(context.typeDescription)"]
        if !context.labels.isEmpty { lines.append("Image labels: \(context.labels.joined(separator: ", "))") }
        if context.text.isEmpty {
            lines.append("Content: (no readable text)")
        } else {
            lines.append("Content:\n\"\"\"\n\(context.text)\n\"\"\"")
        }
        if let avoiding, !avoiding.isEmpty {
            lines.append("The user didn't like \"\(avoiding)\". Suggest a clearly different name, for example with other facts first.")
        }
        lines.append("Reply with the file name.")
        return lines.joined(separator: "\n")
    }

    /// A name for `url`, or nil when there's nothing better than the
    /// current one.
    static func suggest(for url: URL, style: FileDropSettings.NameStyle, useModel: Bool = true, avoiding: String? = nil) async -> Suggestion? {
        let context = await context(for: url)
        if useModel, MeetingAIBackend.onDeviceAvailable,
           !(context.text.isEmpty && context.labels.isEmpty) {
            do {
                let raw = try await MeetingAIBackend.onDevice(
                    instructions: instructions, prompt: prompt(for: context, avoiding: avoiding), schema: schema,
                    maxTokens: 60, timeout: 25, permissive: true
                )
                let name = MeetingAIJSON.object(from: raw).flatMap { MeetingAIJSON.string($0["name"]) } ?? raw
                let styled = normalize(name, style: style)
                if isUseful(styled, original: context.originalName),
                   styled.lowercased() != avoiding?.lowercased() {
                    return Suggestion(name: styled, source: "On-device AI")
                }
            } catch {
                // Never log the content; the kind of failure is enough.
                AppLog.log("FileDrop: on-device naming failed (\(String(describing: type(of: error))))")
            }
        }
        return heuristic(context, style: style)
    }

    // MARK: Heuristic

    /// The first line that reads like a title, plus a date from the content
    /// (or, for photos without text, the scene labels and the day it was taken).
    static func heuristic(_ context: Context, style: FileDropSettings.NameStyle) -> Suggestion? {
        let date = firstDate(in: context.text)
        if let title = titleLine(in: context.text) {
            var name = title
            if let date, !name.contains(date) { name += " \(date)" }
            let styled = normalize(name, style: style)
            if isUseful(styled, original: context.originalName) { return Suggestion(name: styled, source: "From the text") }
        }
        if context.isImage, !context.labels.isEmpty {
            var words = context.labels.prefix(2).map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
            if let created = context.created { words.append(dayString(created)) }
            let styled = normalize(words.joined(separator: " "), style: style)
            if isUseful(styled, original: context.originalName) { return Suggestion(name: styled, source: "From the picture") }
        }
        return nil
    }

    static func titleLine(in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline).prefix(12) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = line.filter(\.isLetter).count
            guard letters >= 4, Double(letters) / Double(max(line.count, 1)) > 0.5 else { continue }
            let words = line.split(whereSeparator: \.isWhitespace).prefix(7).joined(separator: " ")
            return words
        }
        // One long paragraph (OCR without line breaks): its first words.
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6)
        let joined = words.joined(separator: " ")
        return joined.filter(\.isLetter).count >= 4 ? joined : nil
    }

    /// The first date in the text as YYYY-MM-DD (NSDataDetector, so
    /// "March 12, 2024", "12/03/2024" and "2024-03-12" all count).
    static func firstDate(in text: String) -> String? {
        if let explicit = numericDate(in: text) { return explicit }
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range).prefix(5) {
            guard let date = match.date, let span = Range(match.range, in: text) else { continue }
            // A real calendar date: a month name or a numeric d/m/y shape,
            // not a bare time ("10:30") or a weekday ("Monday at 3").
            guard isCalendarDate(String(text[span])) else { continue }
            return dayString(date)
        }
        return nil
    }

    /// A detector match that is a real calendar date: a month name with a
    /// number, or a numeric d/m/y shape (not "10:30" or "Monday at 3").
    static func isCalendarDate(_ literal: String) -> Bool {
        let numeric = literal.range(of: #"\d{1,4}[/.\-]\d{1,2}([/.\-]\d{1,4})?"#, options: .regularExpression) != nil
        let lower = literal.lowercased()
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let named = months.contains { lower.contains($0) } && literal.contains(where: \.isNumber)
        return numeric || named
    }

    /// Rewrites full dates in a name as YYYY-MM-DD ("Invoice March 12, 2024"
    /// → "Invoice 2024-03-12"), as the instructions ask; the on-device model
    /// doesn't always follow them. Only dates that state a year are touched,
    /// so the detector never invents one.
    static func isoDates(in text: String) -> String {
        var result = text
        if let explicit = text.range(of: #"\b\d{1,2}/\d{1,2}/(19|20)\d{2}\b"#, options: .regularExpression),
           let iso = numericDate(in: String(text[explicit])) {
            result.replaceSubrange(explicit, with: iso)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return result }
        let matches = detector.matches(in: result, options: [], range: NSRange(result.startIndex..<result.endIndex, in: result))
        for match in matches.reversed() {
            guard let date = match.date, let span = Range(match.range, in: result) else { continue }
            let literal = String(result[span])
            guard literal.range(of: #"^(19|20)\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) == nil,
                  literal.range(of: #"(19|20)\d{2}"#, options: .regularExpression) != nil,
                  isCalendarDate(literal)
            else { continue }
            result.replaceSubrange(span, with: dayString(date))
        }
        return result
    }

    /// ISO dates ("2024-03-12") and slashed ones ("03/12/2024"), which
    /// NSDataDetector misses. Slashed day/month order: whichever part is
    /// over 12, else the user's locale order.
    static func numericDate(in text: String) -> String? {
        if let range = text.range(of: #"\b(19|20)\d{2}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\b"#, options: .regularExpression) {
            return String(text[range])
        }
        guard let range = text.range(of: #"\b\d{1,2}/\d{1,2}/(19|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let pattern = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: .current) ?? "M/d/y"
        let dayFirstLocale = (pattern.firstIndex(of: "d") ?? pattern.endIndex) < (pattern.firstIndex(of: "M") ?? pattern.endIndex)
        let (day, month): (Int, Int)
        if parts[0] > 12 { (day, month) = (parts[0], parts[1]) }
        else if parts[1] > 12 { (day, month) = (parts[1], parts[0]) }
        else if dayFirstLocale { (day, month) = (parts[0], parts[1]) }
        else { (day, month) = (parts[1], parts[0]) }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", parts[2], month, day)
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Normalising

    /// A model's or a heuristic's raw name → a safe file name in the user's
    /// style, at most 7 words / 80 characters, ISO dates kept intact.
    static func normalize(_ raw: String, style: FileDropSettings.NameStyle) -> String {
        var text = MeetingAIJSON.stripReasoning(raw)
        text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = isoDates(in: text)
        // A model sometimes answers "Name: …" or adds an extension.
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 12 {
            text = String(text[text.index(after: colon)...])
        }
        if let dot = text.lastIndex(of: "."), text.distance(from: dot, to: text.endIndex) <= 6,
           text[text.index(after: dot)...].allSatisfy({ $0.isLetter || $0.isNumber }),
           !text[text.index(after: dot)...].isEmpty {
            text = String(text[..<dot])
        }
        // Underscores / dashes between words become spaces; keep dashes inside dates.
        let separatorsAsSpaces = text.replacingOccurrences(of: "_", with: " ")
        let cleaned = separatorsAsSpaces.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "&" || scalar == "#" || scalar == "." || scalar == "," { return Character(scalar) }
            return " "
        }
        var words = String(cleaned).split(separator: " ").map { word -> String in
            var w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "-.,#"))
            if w.hasPrefix("#") { w.removeFirst() }
            return w
        }.filter { !$0.isEmpty }
        // Split "Acme-Invoice" style words, but not dates or numbers like 2024-03-12.
        words = words.flatMap { word -> [String] in
            guard word.contains("-"), !isDateLike(word), word.contains(where: \.isLetter) else { return [word] }
            return word.split(separator: "-").map(String.init)
        }
        // A word said twice ("Outdoor Sky Blue Sky") reads as a glitch.
        var seen = Set<String>()
        // So is a date given twice (the title's date plus the one found).
        words = words.filter { word in
            guard word.contains(where: \.isLetter) || (word.count == 10 && isDateLike(word)) else { return true }
            return seen.insert(word.lowercased()).inserted
        }
        words = Array(words.prefix(7))
        var result: String
        switch style {
        case .words:
            result = words.enumerated().map { $0.offset == 0 ? capitalizeFirst($0.element) : capitalizeIfLower($0.element) }
                .joined(separator: " ")
        case .kebab:
            result = words.map { $0.lowercased() }.joined(separator: "-")
        case .snake:
            result = words.enumerated().map { $0.offset == 0 ? capitalizeFirst($0.element) : capitalizeIfLower($0.element) }
                .joined(separator: "_")
        }
        if result.count > 80 {
            result = String(result.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        }
        return result
    }

    static func isDateLike(_ word: String) -> Bool {
        word.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// "invoice" → "Invoice"; "iPhone", "ACME", "2024-03-12" stay as they are.
    static func capitalizeIfLower(_ word: String) -> String {
        guard let first = word.first, first.isLowercase, word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return word }
        let small: Set<String> = ["and", "or", "of", "the", "for", "to", "in", "on", "a", "an", "at", "by", "with", "vs"]
        return small.contains(word) ? word : word.prefix(1).uppercased() + word.dropFirst()
    }

    static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first, first.isLowercase, word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    static func isUseful(_ name: String, original: String) -> Bool {
        let letters = name.filter(\.isLetter).count
        guard letters >= 3 else { return false }
        return name.lowercased() != original.lowercased()
    }
}

/// One Vision read per file at a time: a second request for the same file
/// (the heuristic after a model timeout, ✨ again) joins the one in flight
/// instead of queueing more work on a busy Neural Engine.
actor FileDropImageReads {
    static let shared = FileDropImageReads()
    private var inFlight: [String: Task<(text: String, labels: [String]), Never>] = [:]

    func read(_ url: URL) async -> (text: String, labels: [String]) {
        let key = url.standardizedFileURL.path
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { FileDropNamer.readImageSync(url) }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}
