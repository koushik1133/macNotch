import AppKit
import Foundation
import FoundationModels
import NaturalLanguage
import Synchronization
import Translation

// Tray AI engine: runs an action on the selected tray items.
//
// 1. On-device extraction always (TrayAIOCR): Vision OCR with line boxes,
//    image labels, barcodes, dominant colors and size; file text (plain text,
//    RTF/Word, HTML, PDF via PDFKit, OCR for scanned PDFs); for link items the
//    page is fetched (only at run time) and reduced to readable text.
// 2. Reasoning: Groq only when `TrayAISettings.allowGroq` is on and Clicky's
//    key exists (vision model for image actions, text model otherwise);
//    otherwise the on-device Apple Intelligence model (FoundationModels) with
//    the extracted text as context, chunked for its 4096-token window; and
//    deterministic fallbacks when that model is unavailable.
// `TrayAIResult.producedBy` names the path that ran.

// MARK: - Sources

/// One selected item after on-device extraction.
struct TrayAISource: Sendable, Equatable {
    enum Kind: String, Sendable { case image, text, link, file }

    var id: UUID
    var kind: Kind
    var name: String
    /// Image file to send to a vision model (image items and image files).
    var imageURL: URL?
    var analysis: TrayAIImageAnalysis?
    var page: TrayAIWebPage?
    var file: TrayAIFileContent?
    /// Why a link couldn't be loaded, when it couldn't.
    var fetchError: String?
    /// Best text for the item: OCR text, the text itself, page text or file text.
    var text: String

    var kindDescription: String {
        switch kind {
        case .image: "image"
        case .text: "text"
        case .link: "web page"
        case .file: file.map { "file, \($0.typeDescription)" } ?? "file"
        }
    }

    var isImage: Bool { analysis != nil && imageURL != nil }
}

enum TrayAIEvent: Sendable {
    /// Progress for the panel ("Reading text…").
    case status(String)
    case result(TrayAIResult)
}

// MARK: - Engine

@MainActor
final class TrayAIEngine {
    static let shared = TrayAIEngine()

    /// Seam for tests: where the Groq key comes from. The default honors
    /// `TrayAISettings.allowGroq` and never touches the keychain when it's off.
    var groqKeyProvider: () -> String? = { TrayAISettings.groqKeyIfAllowed() }
    /// Seam for tests: skip the on-device model (deterministic fallbacks only).
    var useOnDeviceModel = true

    private var analysisCache: [String: TrayAIImageAnalysis] = [:]
    private var fileCache: [String: TrayAIFileContent] = [:]
    private var pageCache: [URL: TrayAIWebPage] = [:]

    init() {}

    /// Groq can be used right now (setting on and a key saved). Never prompts.
    var groqReady: Bool { TrayAISettings.allowGroq && ClickyKeychain.hasKey() }

    /// Why the on-device model can't run, or nil when it can.
    var onDeviceUnavailableReason: String? { TrayAIOnDevice.unavailableReason }

    func run(_ action: TrayAIAction, on items: [TrayItem]) async throws -> TrayAIResult {
        try await perform(action, on: items, report: { _ in })
    }

    /// Same as `run`, with progress messages before the result.
    func stream(_ action: TrayAIAction, on items: [TrayItem]) -> AsyncThrowingStream<TrayAIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let result = try await self.perform(action, on: items) { continuation.yield(.status($0)) }
                    continuation.yield(.result(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Clears cached OCR, file text and pages (e.g. when the tray changes).
    func clearCache() {
        analysisCache.removeAll()
        fileCache.removeAll()
        pageCache.removeAll()
    }

    // MARK: Dispatch

    private func perform(_ action: TrayAIAction, on items: [TrayItem], report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        guard !items.isEmpty else { throw TrayAIError.noItems }
        let started = Date()
        report(items.contains(where: \.trayAIIsImage) ? "Reading text in images…" : "Reading items…")
        let sources = try await prepare(items, fetchLinks: true, report: report)
        try Task.checkCancellation()

        // Only read the key when the user allowed Groq for Tray AI, and only
        // for actions that can use it.
        let key = action.mayUseGroq ? groqKeyProvider() : nil
        let groq = key.map { TrayAIGroq(key: $0) }

        let result: TrayAIResult
        switch action {
        case .extractText:
            result = try extractText(sources)
        case .addToCalendar:
            result = try calendarEvent(sources)
        case .receiptToJSON:
            result = try await receipt(sources, groq: groq, report: report)
        case .compareDesigns:
            result = try await compareDesigns(sources, groq: groq, report: report)
        case .checkSpelling:
            result = try await checkSpelling(sources, groq: groq, report: report)
        case .improveWriting:
            result = try await improveWriting(sources, groq: groq, report: report)
        case .translate(let language):
            result = try await translate(sources, to: TrayAISettings.resolvedLanguage(language), groq: groq, report: report)
        case .webSearch:
            result = try await webSearch(sources, groq: groq, report: report)
        case .summarize:
            result = try await summarize(sources, groq: groq, report: report)
        case .whatIsThis, .explain, .listItems, .custom:
            result = try await answer(action, sources, groq: groq, report: report)
        }
        AppLog.log("Tray AI: \(action.id.prefix(40)) on \(items.count) item(s) by \(result.producedBy) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return result
    }

    // MARK: Extraction

    /// On-device extraction for each item (cached per file and modification date).
    func prepare(_ items: [TrayItem], fetchLinks: Bool, report: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> [TrayAISource] {
        var sources: [TrayAISource] = []
        for item in items {
            try Task.checkCancellation()
            var source = TrayAISource(id: item.id, kind: .text, name: item.displayName, text: "")
            if item.trayAIIsImage, let url = item.url {
                source.kind = item.kind == .image ? .image : .file
                source.imageURL = url
                source.analysis = await analysis(for: url)
                // Row order keeps labels next to their values (receipts, tables).
                source.text = source.analysis.map { $0.looksTabular ? $0.rowText : $0.text } ?? ""
                if source.analysis == nil { source.imageURL = nil }
            } else if let link = item.trayAILinkURL {
                source.kind = .link
                source.name = link.host ?? link.absoluteString
                if fetchLinks {
                    report("Loading \(link.host ?? "page")…")
                    do {
                        let page = try await page(for: link)
                        source.page = page
                        source.name = page.title ?? source.name
                        source.text = page.text
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        source.fetchError = error.localizedDescription
                        source.text = ""
                    }
                }
            } else if item.kind == .text {
                source.kind = .text
                source.name = "Text"
                source.text = item.text ?? ""
            } else if let url = item.url {
                source.kind = .file
                let file = await fileContent(for: url)
                source.file = file
                source.text = file.text ?? ""
            }
            sources.append(source)
        }
        return sources
    }

    private func cacheKey(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.standardizedFileURL.path)|\(date?.timeIntervalSince1970 ?? 0)"
    }

    private func analysis(for url: URL) async -> TrayAIImageAnalysis? {
        let key = cacheKey(url)
        if let cached = analysisCache[key] { return cached }
        let result = await TrayAIOCR.analyze(imageAt: url)
        if let result {
            if analysisCache.count > 20 { analysisCache.removeAll() }
            analysisCache[key] = result
        }
        return result
    }

    private func fileContent(for url: URL) async -> TrayAIFileContent {
        let key = cacheKey(url)
        if let cached = fileCache[key] { return cached }
        let content = await TrayAIFiles.read(url)
        if fileCache.count > 20 { fileCache.removeAll() }
        fileCache[key] = content
        return content
    }

    private func page(for url: URL) async throws -> TrayAIWebPage {
        if let cached = pageCache[url] { return cached }
        let page = try await TrayAIWeb.fetch(url)
        if pageCache.count > 10 { pageCache.removeAll() }
        pageCache[url] = page
        return page
    }

    /// Throws when no item has any usable text.
    private func requireText(_ sources: [TrayAISource]) throws {
        guard sources.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            if let failure = sources.compactMap(\.fetchError).first { throw TrayAIError.fetchFailed(failure) }
            throw TrayAIError.nothingToRead
        }
    }

    private var onDeviceReady: Bool { useOnDeviceModel && TrayAIOnDevice.unavailableReason == nil }

    private func onDeviceLabel() -> String { "On-device (Apple Intelligence)" }

    // MARK: Extract text (always on-device)

    private func extractText(_ sources: [TrayAISource]) throws -> TrayAIResult {
        let parts: [(String, String)] = sources.compactMap { source in
            var text = (source.analysis?.copyText ?? source.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if let analysis = source.analysis, !analysis.barcodes.isEmpty {
                let codes = analysis.barcodes.map { "\($0.symbology): \($0.payload)" }.joined(separator: "\n")
                text = text.isEmpty ? codes : text + "\n\n" + codes
            }
            return text.isEmpty ? nil : (source.name, text)
        }
        guard !parts.isEmpty else {
            if let failure = sources.compactMap(\.fetchError).first { throw TrayAIError.fetchFailed(failure) }
            throw TrayAIError.nothingToRead
        }
        let text = parts.count == 1 ? parts[0].1 : parts.map { "— \($0.0) —\n\($0.1)" }.joined(separator: "\n\n")
        let usedOCR = sources.contains { $0.analysis != nil }
        return TrayAIResult(text: text, json: nil, producedBy: usedOCR ? "On-device (Vision OCR)" : "On-device", openURL: nil)
    }

    // MARK: Add to Calendar (always on-device)

    /// The first date in the items as a one-event .ics. Opening it is left
    /// to the user (Calendar then asks before saving anything).
    private func calendarEvent(_ sources: [TrayAISource]) throws -> TrayAIResult {
        for source in sources {
            let text = source.analysis?.rowText ?? source.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // The biggest text in a screenshot usually names the event.
            let headline = source.analysis?.rows
                .filter { !TrayAICalendar.containsDate($0.text) && $0.text.filter(\.isLetter).count >= 3 }
                .max { $0.height < $1.height }?.text
            let fallback = source.page?.title ?? (source.kind == .text ? "Event" : source.name)
            guard let event = TrayAICalendar.event(in: text, headline: headline, fallbackTitle: fallback) else { continue }
            let file: URL
            do {
                file = try TrayAICalendar.writeFile(event)
            } catch {
                throw TrayAIError.groq("Couldn't write the event file: \(error.localizedDescription)")
            }
            return TrayAIResult(text: TrayAICalendar.describe(event), json: nil, producedBy: "On-device (data detectors)", openURL: file)
        }
        if let failure = sources.compactMap(\.fetchError).first { throw TrayAIError.fetchFailed(failure) }
        throw TrayAIError.noDate
    }

    // MARK: Generic answers

    private func answer(_ action: TrayAIAction, _ sources: [TrayAISource], groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        let hasImages = sources.contains(where: \.isImage)
        if !hasImages { try requireText(sources) }
        let task = TrayAIPrompts.task(for: action, onDevice: false)

        if let groq {
            report("Asking Groq…")
            do {
                let (text, model) = try await groq.ask(
                    task: task, sources: sources, useVision: hasImages,
                    json: false, maxTokens: action == .listItems ? 1200 : 1500
                )
                return TrayAIResult(text: text, json: nil, producedBy: "Groq \(model)", openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: Groq failed (\(error.localizedDescription)), using on-device")
            }
        }

        let note = hasImages && action.needsVisualUnderstanding ? "\n\n" + TrayAIPrompts.onDeviceImageNote : ""
        if onDeviceReady {
            report("Thinking on-device…")
            let budget = TrayAIOnDevice.characterBudget(for: sources.map(\.text).joined(), base: 6000)
            let prompt = TrayAIPrompts.context(sources, budget: budget)
                + "\n\nTask: " + TrayAIPrompts.task(for: action, onDevice: true)
            do {
                let text = try await TrayAIOnDevice.respondRetrying(
                    instructions: TrayAIPrompts.onDeviceSystem, prompt: prompt,
                    maxTokens: action == .listItems ? 700 : 500, timeout: 30,
                    permissive: !isCustom(action),
                    rebuild: { smaller in
                        TrayAIPrompts.context(sources, budget: smaller) + "\n\nTask: " + TrayAIPrompts.task(for: action, onDevice: true)
                    },
                    budget: budget
                )
                return TrayAIResult(text: TrayAIText.clean(text) + note, json: nil, producedBy: onDeviceLabel(), openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: on-device model failed (\(error.localizedDescription))")
                if action == .explain || isCustom(action) { throw error }
            }
        }

        // Deterministic fallbacks.
        switch action {
        case .whatIsThis:
            return TrayAIResult(text: describeWithoutModel(sources) + note, json: nil, producedBy: "On-device (Vision)", openURL: nil)
        case .listItems:
            let list = listWithoutModel(sources)
            guard !list.isEmpty else { throw TrayAIError.nothingToRead }
            return TrayAIResult(text: list + note, json: nil, producedBy: "On-device (rules)", openURL: nil)
        default:
            throw TrayAIError.onDeviceUnavailable(TrayAIOnDevice.unavailableReason ?? "turned off")
        }
    }

    /// Progress callback usable from nonisolated code.
    private static func relay(_ report: @escaping @MainActor @Sendable (String) -> Void) -> @Sendable (String) -> Void {
        { message in Task { @MainActor in report(message) } }
    }

    private func isCustom(_ action: TrayAIAction) -> Bool {
        if case .custom = action { return true }
        return false
    }

    private func describeWithoutModel(_ sources: [TrayAISource]) -> String {
        sources.map { source -> String in
            var lines: [String] = []
            switch source.kind {
            case _ where source.analysis != nil:
                if let analysis = source.analysis {
                    let size = "\(Int(analysis.pixelSize.width))×\(Int(analysis.pixelSize.height))"
                    let labels = analysis.labels.prefix(3).map(\.name)
                    lines.append(labels.isEmpty ? "An image (\(size) px)." : "An image (\(size) px) that looks like: \(labels.joined(separator: ", ")).")
                    if analysis.hasText {
                        let sample = analysis.rows.sorted { $0.height > $1.height }.prefix(3).map(\.text)
                        lines.append("Most prominent text: \(sample.map { "“\($0)”" }.joined(separator: ", ")). \(analysis.lines.count) lines of text in total.")
                    }
                    for code in analysis.barcodes { lines.append("\(code.symbology) code: \(code.payload)") }
                }
            case .link:
                if let page = source.page {
                    lines.append("A web page: \(page.title ?? page.url.absoluteString)\(page.siteName.map { " (\($0))" } ?? "").")
                    if let summary = page.summary { lines.append(summary) }
                } else {
                    lines.append("A link to \(source.name)\(source.fetchError.map { " (couldn't load: \($0))" } ?? "").")
                }
            case .text:
                let words = source.text.split(whereSeparator: \.isWhitespace).count
                let language = TrayAIOCR.detectLanguage(source.text).map(TrayAIOCR.languageName) ?? "unknown language"
                lines.append("A text snippet of \(words) words in \(language).")
            default:
                if let file = source.file { lines.append(file.metadata) }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func listWithoutModel(_ sources: [TrayAISource]) -> String {
        var bullets: [String] = []
        for source in sources {
            if let analysis = source.analysis {
                bullets += analysis.labels.prefix(4).map { "- \($0.name.capitalized)" }
                bullets += analysis.rows.map(\.text).filter { $0.count >= 2 }.prefix(25).map { "- \($0)" }
            } else {
                let lines = source.text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*·")) }
                    .filter { !$0.isEmpty }
                bullets += (lines.count >= 2 ? lines : TrayAIText.sentences(source.text)).prefix(30).map { "- \($0)" }
            }
        }
        var seen = Set<String>()
        return bullets.filter { seen.insert($0.lowercased()).inserted }.joined(separator: "\n")
    }

    // MARK: Summarize

    private func summarize(_ sources: [TrayAISource], groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        try requireText(sources)
        let task = TrayAIPrompts.task(for: .summarize, onDevice: false)
        let hasImages = sources.contains(where: \.isImage)
        if let groq {
            report("Summarizing with Groq…")
            do {
                let (text, model) = try await groq.ask(task: task, sources: sources, useVision: hasImages, json: false, maxTokens: 1200)
                return TrayAIResult(text: text, json: nil, producedBy: "Groq \(model)", openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: Groq summarize failed (\(error.localizedDescription)), using on-device")
            }
        }

        let all = TrayAIPrompts.context(sources, budget: 60_000, includeImageFacts: false)
        if onDeviceReady {
            report("Summarizing on-device…")
            do {
                let text = try await TrayAIOnDevice.summarize(all, task: TrayAIPrompts.task(for: .summarize, onDevice: true), report: Self.relay(report))
                return TrayAIResult(text: TrayAIText.clean(text), json: nil, producedBy: onDeviceLabel(), openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: on-device summarize failed (\(error.localizedDescription)), using extractive summary")
            }
        }
        let body = sources.map(\.text).joined(separator: "\n\n")
        let summary = TrayAIText.extractiveSummary(body, sentences: 5)
        guard !summary.isEmpty else { throw TrayAIError.nothingToRead }
        let header = sources.compactMap { $0.page?.title }.first.map { "## \($0)\n" } ?? ""
        return TrayAIResult(text: header + summary, json: nil, producedBy: "On-device (extractive)", openURL: nil)
    }

    // MARK: Writing

    private func combinedText(_ sources: [TrayAISource]) -> String {
        sources.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    private func improveWriting(_ sources: [TrayAISource], groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        try requireText(sources)
        let input = combinedText(sources)
        let task = TrayAIPrompts.task(for: .improveWriting, onDevice: false)
        if let groq {
            report("Improving with Groq…")
            do {
                let (text, model) = try await groq.transform(task: task, text: input, maxTokens: min(8000, input.count / 2 + 600))
                return TrayAIResult(text: TrayAIText.stripWrapper(text), json: nil, producedBy: "Groq \(model)", openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: Groq improve failed (\(error.localizedDescription)), using on-device")
            }
        }
        if onDeviceReady {
            report("Improving on-device…")
            do {
                let text = try await TrayAIOnDevice.transformChunks(input, task: TrayAIPrompts.task(for: .improveWriting, onDevice: true), report: Self.relay(report))
                if TrayAIText.wordSimilarity(input, text) >= 0.25 {
                    return TrayAIResult(text: text, json: nil, producedBy: onDeviceLabel(), openURL: nil)
                }
                AppLog.log("Tray AI: on-device rewrite drifted from the input, using spelling fixes")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: on-device improve failed (\(error.localizedDescription))")
            }
        }
        let fixed = TrayAISpelling.correct(input)
        let changes = TrayAIText.wordChanges(from: input, to: fixed)
        let note = "Apple Intelligence isn't available, so only spelling and spacing were fixed."
        let text = (changes.isEmpty ? input : fixed) + "\n\n" + note
        return TrayAIResult(text: text, json: nil, producedBy: "On-device (spell checker)", openURL: nil)
    }

    private func checkSpelling(_ sources: [TrayAISource], groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        try requireText(sources)
        let input = combinedText(sources)
        var corrected: String?
        var producedBy = ""
        if let groq {
            report("Checking with Groq…")
            do {
                let (text, model) = try await groq.transform(
                    task: TrayAIPrompts.task(for: .checkSpelling, onDevice: false), text: input,
                    maxTokens: min(8000, input.count / 2 + 600)
                )
                let candidate = TrayAIText.stripWrapper(text)
                if TrayAIText.wordSimilarity(input, candidate) >= 0.6 {
                    corrected = candidate
                    producedBy = "Groq \(model)"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: Groq spelling failed (\(error.localizedDescription)), using on-device")
            }
        }
        if corrected == nil, onDeviceReady {
            report("Checking on-device…")
            do {
                let text = try await TrayAIOnDevice.transformChunks(input, task: TrayAIPrompts.task(for: .checkSpelling, onDevice: true), report: Self.relay(report))
                if TrayAIText.wordSimilarity(input, text) >= 0.6 {
                    corrected = text
                    producedBy = onDeviceLabel()
                } else {
                    AppLog.log("Tray AI: on-device spelling output rejected (rewrote too much)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: on-device spelling failed (\(error.localizedDescription))")
            }
        }
        if corrected == nil {
            corrected = TrayAISpelling.correct(input)
            producedBy = "On-device (spell checker)"
        }
        let output = corrected ?? input
        let changes = TrayAIText.wordChanges(from: input, to: output)
        var text = output
        if changes.isEmpty {
            text += "\n\n## Changes\nNo mistakes found."
        } else {
            let shown = changes.prefix(30).map { change -> String in
                change.from.isEmpty ? "- added “\(change.to)”"
                    : change.to.isEmpty ? "- removed “\(change.from)”"
                    : "- “\(change.from)” → “\(change.to)”"
            }
            text += "\n\n## Changes\n" + shown.joined(separator: "\n")
            if changes.count > 30 { text += "\n- …and \(changes.count - 30) more" }
        }
        let json = TrayAIText.jsonString([
            "corrected": output,
            "changes": changes.map { ["from": $0.from, "to": $0.to] },
        ])
        return TrayAIResult(text: text, json: json, producedBy: producedBy, openURL: nil)
    }

    // MARK: Translate

    private func translate(_ sources: [TrayAISource], to target: String, groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        try requireText(sources)
        let input = combinedText(sources)
        let detected = TrayAIOCR.detectLanguage(input)
        let sourceName = detected.map(TrayAIOCR.languageName)
        let targetCode = TrayAITranslator.languageCode(for: target)
        if let detected, let targetCode, TrayAITranslator.sameLanguage(detected.rawValue, targetCode) {
            return TrayAIResult(text: input + "\n\n(The text is already in \(target).)", json: nil, producedBy: "On-device", openURL: nil)
        }
        let header = sourceName.map { "Translated from \($0) to \(target)" } ?? "Translated to \(target)"

        if let groq {
            report("Translating with Groq…")
            do {
                let (text, model) = try await groq.transform(
                    task: TrayAIPrompts.task(for: .translate(target), onDevice: false), text: input,
                    maxTokens: min(8000, input.count + 600)
                )
                return TrayAIResult(text: TrayAIText.stripWrapper(text), json: nil, producedBy: "Groq \(model) · \(header)", openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: Groq translate failed (\(error.localizedDescription)), using on-device")
            }
        }

        var reasons: [String] = []
        if let detected, let targetCode {
            report("Translating on-device…")
            do {
                let text = try await TrayAITranslator.translate(input, from: detected.rawValue, to: targetCode)
                return TrayAIResult(text: text, json: nil, producedBy: "On-device (Translation) · \(header)", openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reasons.append(error.localizedDescription)
            }
        } else if detected == nil {
            reasons.append("couldn't detect the source language")
        }
        if onDeviceReady {
            report("Translating with Apple Intelligence…")
            do {
                let text = try await TrayAIOnDevice.transformChunks(input, task: TrayAIPrompts.task(for: .translate(target), onDevice: true), report: Self.relay(report))
                return TrayAIResult(text: text, json: nil, producedBy: "\(onDeviceLabel()) · \(header)", openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reasons.append(error.localizedDescription)
            }
        } else {
            reasons.append("Apple Intelligence isn't available")
        }
        throw TrayAIError.translationUnavailable(reasons.joined(separator: "; ") + ". Allow Groq in Tray AI settings to translate any language")
    }

    // MARK: Web search

    private func webSearch(_ sources: [TrayAISource], groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        let hasImages = sources.contains(where: \.isImage)
        var query: String?
        var producedBy = "On-device (rules)"
        if let groq {
            report("Writing a search query…")
            do {
                let (text, model) = try await groq.ask(
                    task: TrayAIPrompts.task(for: .webSearch, onDevice: false), sources: sources,
                    useVision: hasImages, json: false, maxTokens: 200
                )
                query = TrayAIText.cleanQuery(text)
                producedBy = "Groq \(model)"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: Groq query failed (\(error.localizedDescription))")
            }
        }
        if query == nil, onDeviceReady, sources.contains(where: { !$0.text.isEmpty }) {
            do {
                let prompt = TrayAIPrompts.context(sources, budget: 2500) + "\n\nTask: " + TrayAIPrompts.task(for: .webSearch, onDevice: true)
                let text = try await TrayAIOnDevice.respond(
                    instructions: TrayAIPrompts.onDeviceSystem, prompt: prompt, maxTokens: 60, timeout: 15, permissive: true
                )
                query = TrayAIText.cleanQuery(text)
                if query != nil { producedBy = onDeviceLabel() }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: on-device query failed (\(error.localizedDescription))")
            }
        }
        if query == nil {
            query = TrayAIText.ruleBasedQuery(sources)
            producedBy = "On-device (rules)"
        }
        guard let query, !query.isEmpty else { throw TrayAIError.nothingToRead }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return TrayAIResult(text: "Search: \(query)", json: nil, producedBy: producedBy, openURL: components?.url)
    }

    // MARK: Receipts

    private func receipt(_ sources: [TrayAISource], groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        if groq == nil { try requireText(sources) }
        let candidates = sources.filter { !$0.text.isEmpty || $0.isImage }
        guard !candidates.isEmpty else { throw TrayAIError.nothingToRead }
        var receipts: [TrayAIReceipt] = []
        var producers = Set<String>()

        for (index, source) in candidates.enumerated() {
            report(candidates.count > 1 ? "Reading receipt \(index + 1) of \(candidates.count)…" : "Reading the receipt…")
            let rules = source.analysis.map { TrayAIReceiptParser.parse(rows: $0.rows) } ?? TrayAIReceiptParser.parse(text: source.text)
            let ocrText = source.analysis?.rowText ?? source.text
            var chosen = rules
            var producer = "On-device (rules)"

            if let groq {
                do {
                    let hint = ocrText.isEmpty ? "" : "\n\nOCR text of the receipt (may contain errors; the image wins):\n" + TrayAIPrompts.truncate(ocrText, to: 6000)
                    let (reply, model) = try await groq.ask(
                        task: TrayAIPrompts.receiptTask + hint, sources: [source], useVision: source.isImage,
                        json: true, maxTokens: 2500, includeContext: !source.isImage
                    )
                    if let object = ClickyReplyParser.jsonObject(in: TrayAIText.stripReasoning(reply)) {
                        var parsed = TrayAIReceipt.from(object: object)
                        parsed.validate()
                        if !parsed.isEmpty {
                            chosen = parsed
                            producer = "Groq \(model)"
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    AppLog.log("Tray AI: Groq receipt failed (\(error.localizedDescription)), using on-device")
                }
            }
            // The rules result is used as is when everything adds up.
            let rulesConsistent = !rules.items.isEmpty && rules.total != nil && rules.warnings.isEmpty
            if producer == "On-device (rules)", !rulesConsistent, onDeviceReady, !ocrText.isEmpty {
                do {
                    let json = try await TrayAIOnDevice.receiptJSON(ocrText: TrayAIPrompts.truncate(ocrText, to: 4500))
                    if let object = ClickyReplyParser.jsonObject(in: json) {
                        var model = TrayAIReceipt.from(object: object)
                        model.validate()
                        let grounded = TrayAIReceiptGrounding.ungroundedCount(model, ocrText: ocrText) <= 1
                        if grounded, model.consistencyScore > rules.consistencyScore {
                            chosen = model
                            producer = onDeviceLabel()
                        } else if chosen.merchant == nil, let merchant = model.merchant {
                            chosen.merchant = merchant
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    AppLog.log("Tray AI: on-device receipt failed (\(error.localizedDescription))")
                }
            }
            // A model may leave out what the rules read plainly (header lines).
            if chosen != rules {
                chosen.merchant = chosen.merchant ?? rules.merchant
                chosen.date = chosen.date ?? rules.date
                chosen.currency = chosen.currency ?? rules.currency
                chosen.paymentMethod = chosen.paymentMethod ?? rules.paymentMethod
            }
            if source.isImage, !TrayAIReceiptParser.looksLikeReceipt(ocrText), producer.hasPrefix("On-device") {
                chosen.warnings.insert("This doesn't look much like a receipt", at: 0)
            }
            receipts.append(chosen)
            producers.insert(producer)
        }

        let json = receipts.count == 1 ? receipts[0].json
            : "[\n" + receipts.map { $0.json.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") }.joined(separator: ",\n") + "\n]"
        let text = receipts.map(TrayAIText.describe).joined(separator: "\n\n")
        return TrayAIResult(text: text, json: json, producedBy: producers.sorted().joined(separator: " + "), openURL: nil)
    }

    // MARK: Design comparison

    private func compareDesigns(_ sources: [TrayAISource], groq: TrayAIGroq?, report: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrayAIResult {
        let designs = sources.filter(\.isImage)
        guard designs.count >= 2 else { throw TrayAIError.needsImages(2) }
        report("Measuring colors, type and spacing…")
        let facts = TrayAIDesign.facts(designs)
        let measured = "## Measured\n" + facts

        if let groq {
            report("Comparing with Groq…")
            do {
                let (text, model) = try await groq.ask(
                    task: TrayAIPrompts.compareTaskGroq + "\n\nMeasured facts:\n" + facts,
                    sources: Array(designs.prefix(TrayAIGroq.maxImages)), useVision: true, json: false,
                    maxTokens: 2500, includeContext: false
                )
                let extra = designs.count > TrayAIGroq.maxImages ? "\n\n(Only the first \(TrayAIGroq.maxImages) images were sent to the model.)" : ""
                return TrayAIResult(text: text + "\n\n" + measured + extra, json: nil, producedBy: "Groq \(model)", openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: Groq compare failed (\(error.localizedDescription)), using on-device")
            }
        }

        let note = "\n\n" + TrayAIPrompts.onDeviceImageNote
        if onDeviceReady {
            report("Comparing on-device…")
            do {
                let ocr = designs.enumerated().map { index, source in
                    "Design \(index + 1) text: " + TrayAIPrompts.truncate(source.text.replacingOccurrences(of: "\n", with: " · "), to: 500)
                }.joined(separator: "\n")
                let prompt = "Measured facts:\n" + TrayAIPrompts.truncate(facts, to: 5000) + "\n\n" + ocr
                    + "\n\nTask: " + TrayAIPrompts.compareTaskOnDevice
                let text = try await TrayAIOnDevice.respond(
                    instructions: TrayAIPrompts.onDeviceSystem, prompt: prompt, maxTokens: 600, timeout: 35, permissive: true
                )
                return TrayAIResult(text: measured + "\n\n## Analysis\n" + TrayAIText.clean(text) + note, json: nil, producedBy: onDeviceLabel(), openURL: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.log("Tray AI: on-device compare failed (\(error.localizedDescription))")
            }
        }
        let analysis = TrayAIDesign.ruleBasedComparison(designs)
        return TrayAIResult(text: measured + "\n\n" + analysis + note, json: nil, producedBy: "On-device (measurements)", openURL: nil)
    }
}

// MARK: - Groq

/// Groq Chat Completions for Tray AI. Only constructed with a key the user
/// allowed Tray AI to use; the key is sent only to api.groq.com.
struct TrayAIGroq: Sendable {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    static let maxImages = 3
    static let maxImagePixel = 1568

    let key: String

    /// Question about items: images (when `useVision`) go as base64 JPEG data
    /// URLs to the vision model, everything else as text context.
    func ask(task: String, sources: [TrayAISource], useVision: Bool, json: Bool, maxTokens: Int,
             includeContext: Bool = true) async throws -> (String, String) {
        let imageURLs = useVision ? sources.compactMap(\.imageURL).prefix(Self.maxImages) : []
        let images: [Data] = await Task.detached(priority: .userInitiated) {
            imageURLs.compactMap { TrayAIOCR.jpegData(at: $0, maxPixel: Self.maxImagePixel) }
        }.value
        let model = images.isEmpty ? TrayAISettings.textModel : TrayAISettings.visionModel
        var user = ""
        if includeContext {
            user = TrayAIPrompts.context(sources, budget: images.isEmpty ? 60_000 : 20_000) + "\n\n"
        }
        user += "Action: " + task
        let body = try Self.body(model: model, system: TrayAIPrompts.groqSystem, user: user, images: images, json: json, maxTokens: maxTokens)
        let text = try await send(body)
        return (json ? text : TrayAIText.clean(text), model)
    }

    /// Text in, transformed text out (improve, spelling, translate).
    func transform(task: String, text: String, maxTokens: Int) async throws -> (String, String) {
        let model = TrayAISettings.textModel
        let user = "Action: \(task)\n\n<text>\n\(TrayAIPrompts.truncate(text, to: 60_000))\n</text>"
        let body = try Self.body(model: model, system: TrayAIPrompts.groqSystem, user: user, images: [], json: false, maxTokens: maxTokens)
        return (try await send(body), model)
    }

    static func body(model: String, system: String, user: String, images: [Data], json: Bool, maxTokens: Int) throws -> Data {
        let content: Any
        if images.isEmpty {
            content = user
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": user]]
            for image in images {
                parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]])
            }
            content = parts
        }
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_completion_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        if model.hasPrefix("openai/gpt-oss") {
            body["reasoning_effort"] = "low"
            body["include_reasoning"] = false
        } else if model.hasPrefix("qwen/") {
            body["include_reasoning"] = false
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func send(_ body: Data) async throws -> String {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.httpBody = body
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw TrayAIError.timedOut
        } catch {
            throw TrayAIError.network(error.localizedDescription)
        }
        return try Self.parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parse(data: Data, status: Int) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            AppLog.log("Tray AI: Groq HTTP \(status) \(message.prefix(160))")
            switch status {
            case 401, 403: throw TrayAIError.invalidKey
            case 429: throw TrayAIError.rateLimited
            default: throw TrayAIError.groq(message.isEmpty ? "Groq error \(status)" : "Groq error \(status): \(message.prefix(100))")
            }
        }
        guard let json, let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw TrayAIError.badResponse }
        if let usage = json["usage"] as? [String: Any] {
            AppLog.log("Tray AI: \(json["model"] as? String ?? "?") in=\(usage["prompt_tokens"] ?? "?") out=\(usage["completion_tokens"] ?? "?") finish=\(choice["finish_reason"] as? String ?? "?")")
        }
        let text = TrayAIText.stripReasoning(message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TrayAIError.badResponse }
        return text
    }
}

// MARK: - On-device model

enum TrayAIOnDevice {
    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "needs macOS 26" }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "this Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off"
        case .unavailable(.modelNotReady): return "the model is still downloading"
        case .unavailable: return "unavailable"
        }
    }

    /// Characters of input that fit the 4096-token window next to the
    /// instructions and the answer; CJK and similar scripts use ~1 token per
    /// character, Latin text ~1 per 3-4.
    static func characterBudget(for text: String, base: Int) -> Int {
        let sample = text.unicodeScalars.prefix(4000)
        guard !sample.isEmpty else { return base }
        let dense = sample.filter { $0.value >= 0x0900 }.count
        return Double(dense) / Double(sample.count) > 0.3 ? base * 2 / 5 : base
    }

    static func respond(instructions: String, prompt: String, maxTokens: Int, timeout: Double, permissive: Bool) async throws -> String {
        guard #available(macOS 26.0, *) else { throw TrayAIError.onDeviceUnavailable("needs macOS 26") }
        if let reason = unavailableReason { throw TrayAIError.onDeviceUnavailable(reason) }
        return try await TrayAITimeout.run(seconds: timeout) {
            let model = SystemLanguageModel(useCase: .general, guardrails: permissive ? .permissiveContentTransformations : .default)
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(
                    to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
                )
                return response.content
            } catch {
                throw classify(error)
            }
        }
    }

    /// `respond`, retrying once with half the context when it didn't fit.
    static func respondRetrying(instructions: String, prompt: String, maxTokens: Int, timeout: Double, permissive: Bool,
                                rebuild: @Sendable (Int) -> String, budget: Int) async throws -> String {
        do {
            return try await respond(instructions: instructions, prompt: prompt, maxTokens: maxTokens, timeout: timeout, permissive: permissive)
        } catch TrayAIError.contextTooLarge {
            return try await respond(instructions: instructions, prompt: rebuild(budget / 2), maxTokens: maxTokens, timeout: timeout, permissive: permissive)
        }
    }

    /// Single pass when the text fits, otherwise map (bullets per chunk, at
    /// most 6 chunks) then reduce.
    static func summarize(_ text: String, task: String, report: @escaping @Sendable (String) -> Void) async throws -> String {
        let budget = characterBudget(for: text, base: 6500)
        if text.count <= budget {
            return try await respondRetrying(
                instructions: TrayAIPrompts.onDeviceSystem, prompt: text + "\n\nTask: " + task,
                maxTokens: 600, timeout: 35, permissive: true,
                rebuild: { TrayAIPrompts.truncate(text, to: $0) + "\n\nTask: " + task }, budget: budget
            )
        }
        var parts = TrayAIPrompts.chunks(text, size: budget)
        let skipped = max(0, parts.count - 6)
        parts = Array(parts.prefix(6))
        var notes: [String] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            report("Summarizing part \(index + 1) of \(parts.count)…")
            let note = try await respondRetrying(
                instructions: TrayAIPrompts.onDeviceSystem,
                prompt: part + "\n\nTask: List the key points of this part as 3-6 short \"- \" bullets. Keep numbers and names.",
                maxTokens: 350, timeout: 30, permissive: true,
                rebuild: { TrayAIPrompts.truncate(part, to: $0) + "\n\nTask: List the key points as short \"- \" bullets." },
                budget: budget
            )
            notes.append(note)
        }
        report("Combining…")
        let combined = TrayAIPrompts.truncate(notes.joined(separator: "\n"), to: budget)
        var summary = try await respond(
            instructions: TrayAIPrompts.onDeviceSystem,
            prompt: "Key points from consecutive parts of one document:\n" + combined + "\n\nTask: " + task,
            maxTokens: 600, timeout: 35, permissive: true
        )
        if skipped > 0 { summary += "\n\n(The last \(skipped) part(s) were too long to include.)" }
        return summary
    }

    /// Output about as long as the input (rewrite, correct, translate):
    /// paragraph-aligned chunks, processed in order.
    static func transformChunks(_ text: String, task: String, report: @escaping @Sendable (String) -> Void) async throws -> String {
        let size = characterBudget(for: text, base: 2400)
        let parts = TrayAIPrompts.chunks(text, size: size)
        var output: [String] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            if parts.count > 1 { report("Part \(index + 1) of \(parts.count)…") }
            let result = try await respond(
                instructions: TrayAIPrompts.onDeviceTransformSystem,
                prompt: "Task: \(task)\n\n<text>\n\(part)\n</text>",
                maxTokens: min(2400, part.count / 2 + 250), timeout: 40, permissive: true
            )
            output.append(TrayAIText.stripWrapper(result))
        }
        return output.joined(separator: "\n")
    }

    /// Guided JSON for a receipt from its OCR text.
    static func receiptJSON(ocrText: String) async throws -> String {
        guard #available(macOS 26.0, *) else { throw TrayAIError.onDeviceUnavailable("needs macOS 26") }
        if let reason = unavailableReason { throw TrayAIError.onDeviceUnavailable(reason) }
        return try await TrayAITimeout.run(seconds: 40) {
            let schema = try receiptSchema()
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(
                model: model,
                instructions: "You turn receipt text (from OCR, one printed line per line) into structured data. Copy amounts exactly as printed. Never invent items or numbers; leave unknown fields out."
            )
            do {
                let response = try await session.respond(
                    to: "Receipt text:\n\(ocrText)", schema: schema, includeSchemaInPrompt: true,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1200)
                )
                return response.content.jsonString
            } catch {
                throw classify(error)
            }
        }
    }

    @available(macOS 26.0, *)
    static func receiptSchema() throws -> GenerationSchema {
        func string() -> DynamicGenerationSchema { DynamicGenerationSchema(type: String.self) }
        func number() -> DynamicGenerationSchema { DynamicGenerationSchema(type: Double.self) }
        let item = DynamicGenerationSchema(name: "ReceiptItem", properties: [
            .init(name: "name", description: "Item name as printed", schema: string()),
            .init(name: "qty", description: "Quantity (1 if not printed)", schema: number()),
            .init(name: "unitPrice", description: "Price per unit", schema: number(), isOptional: true),
            .init(name: "total", description: "Line total as printed", schema: number()),
        ])
        let root = DynamicGenerationSchema(name: "Receipt", properties: [
            .init(name: "merchant", description: "Store or restaurant name", schema: string(), isOptional: true),
            .init(name: "date", description: "Purchase date as YYYY-MM-DD when possible", schema: string(), isOptional: true),
            .init(name: "currency", description: "ISO 4217 code such as USD", schema: string(), isOptional: true),
            .init(name: "items", description: "Purchased lines, not totals", schema: DynamicGenerationSchema(arrayOf: item, maximumElements: 60)),
            .init(name: "subtotal", description: "Subtotal", schema: number(), isOptional: true),
            .init(name: "tax", description: "Total tax", schema: number(), isOptional: true),
            .init(name: "tip", description: "Tip or gratuity", schema: number(), isOptional: true),
            .init(name: "total", description: "Grand total", schema: number(), isOptional: true),
            .init(name: "paymentMethod", description: "e.g. Visa ••••1234 or Cash", schema: string(), isOptional: true),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Maps FoundationModels errors (GenerationError on macOS 26,
    /// LanguageModelError on 27) by name, without depending on either type.
    static func classify(_ error: Error) -> Error {
        if error is CancellationError || error is TrayAIError { return error }
        let text = String(describing: error)
        if text.contains("contextSizeExceeded") || text.contains("exceededContextWindowSize") { return TrayAIError.contextTooLarge }
        if text.contains("guardrailViolation") || text.contains("refusal") { return TrayAIError.refused }
        if text.contains("assetsUnavailable") { return TrayAIError.onDeviceUnavailable("model assets unavailable") }
        if text.contains("unsupportedLanguageOrLocale") { return TrayAIError.onDeviceUnavailable("this language isn't supported on-device") }
        return error
    }
}

// MARK: - Translation framework

enum TrayAITranslator {
    static let codes: [String: String] = [
        "english": "en", "spanish": "es", "french": "fr", "german": "de", "italian": "it", "portuguese": "pt",
        "dutch": "nl", "chinese": "zh-Hans", "chinese (simplified)": "zh-Hans", "chinese (traditional)": "zh-Hant",
        "japanese": "ja", "korean": "ko", "hindi": "hi", "arabic": "ar", "russian": "ru", "turkish": "tr",
        "polish": "pl", "ukrainian": "uk", "vietnamese": "vi", "thai": "th", "indonesian": "id",
        "telugu": "te", "tamil": "ta",
    ]

    /// "Spanish" → "es"; also accepts codes ("es") and other English language names.
    static func languageCode(for name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code = codes[key] { return code }
        let english = Locale(identifier: "en")
        if Locale.LanguageCode.isoLanguageCodes.contains(where: { $0.identifier == key }) { return key }
        return Locale.LanguageCode.isoLanguageCodes.first {
            english.localizedString(forLanguageCode: $0.identifier)?.lowercased() == key
        }?.identifier
    }

    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        let base = { (code: String) in code.split(separator: "-").first.map(String.init)?.lowercased() ?? code }
        // zh-Hans vs zh-Hant differ in script; treat as different.
        if a.hasPrefix("zh") || b.hasPrefix("zh") { return a.lowercased() == b.lowercased() }
        return base(a) == base(b)
    }

    /// Apple's on-device Translation (macOS 26+), installed languages only.
    static func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard #available(macOS 26.0, *) else { throw TrayAIError.translationUnavailable("needs macOS 26") }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: from, to: to)
        switch status {
        case .installed: break
        case .supported:
            throw TrayAIError.translationUnavailable("download the languages in System Settings › General › Language & Region › Translation Languages")
        default:
            throw TrayAIError.translationUnavailable("this language pair isn't supported by Apple Translation")
        }
        let session = TranslationSession(installedSource: from, target: to)
        var output: [String] = []
        for part in TrayAIPrompts.chunks(text, size: 3000) {
            try Task.checkCancellation()
            output.append(try await session.translate(part).targetText)
        }
        return output.joined(separator: "\n")
    }
}

// MARK: - Spell checker fallback

@MainActor
enum TrayAISpelling {
    /// NSSpellChecker corrections (spelling and grammar), applied back to front.
    static func correct(_ text: String) -> String {
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        let language = TrayAIOCR.detectLanguage(text)?.rawValue
        let ns = text as NSString
        var orthography: NSOrthography?
        var wordCount = 0
        let results = checker.check(
            text, range: NSRange(location: 0, length: ns.length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue,
            options: language.map { [NSSpellChecker.OptionKey.orthography: NSOrthography.defaultOrthography(forLanguage: $0)] },
            inSpellDocumentWithTag: tag, orthography: &orthography, wordCount: &wordCount
        )
        var replacements: [(NSRange, String)] = []
        for result in results {
            switch result.resultType {
            case .spelling:
                let word = ns.substring(with: result.range)
                if let fix = checker.correction(forWordRange: result.range, in: text, language: language ?? "en", inSpellDocumentWithTag: tag)
                    ?? checker.guesses(forWordRange: result.range, in: text, language: language, inSpellDocumentWithTag: tag)?.first,
                   fix != word {
                    replacements.append((result.range, fix))
                }
            case .grammar:
                for detail in result.grammarDetails ?? [] {
                    guard let value = detail["NSGrammarRange"] as? NSValue,
                          let corrections = detail["NSGrammarCorrections"] as? [String], let fix = corrections.first else { continue }
                    let local = value.rangeValue
                    let range = NSRange(location: result.range.location + local.location, length: local.length)
                    replacements.append((range, fix))
                }
            default:
                break
            }
        }
        let mutable = NSMutableString(string: text)
        var lastStart = Int.max
        for (range, fix) in replacements.sorted(by: { $0.0.location > $1.0.location }) where NSMaxRange(range) <= lastStart {
            mutable.replaceCharacters(in: range, with: fix)
            lastStart = range.location
        }
        var output = mutable as String
        output = TrayAIRegex.replace(#"[ \t]{2,}"#, in: output, with: " ")
        output = TrayAIRegex.replace(#" +([,.;:!?])"#, in: output, with: "$1")
        return output
    }
}

// MARK: - Text utilities

enum TrayAIText {
    struct Change: Sendable, Equatable {
        var from: String
        var to: String
    }

    static func stripReasoning(_ text: String) -> String {
        var text = text
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        return text
    }

    /// Trims, strips code fences and reasoning.
    static func clean(_ text: String) -> String {
        var lines = stripReasoning(text).components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For transforms: also drops <text> tags, wrapping quotes and preambles.
    static func stripWrapper(_ text: String) -> String {
        var output = clean(text)
        output = TrayAIRegex.replace(#"</?text>"#, in: output, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = output.components(separatedBy: "\n").first,
           first.range(of: #"^(here('| i)s|sure|certainly|corrected text|improved text|translation)\b.*:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            output = String(output.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”")] where output.hasPrefix(open) && output.hasSuffix(close) && output.count > 2 {
            let inner = output.dropFirst().dropLast()
            if !inner.contains(open) { output = String(inner) }
        }
        return output
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Share of input words kept (by LCS) in the output, 0...1.
    static func wordSimilarity(_ a: String, _ b: String) -> Double {
        let x = words(a.lowercased()).map(normalizeWord), y = words(b.lowercased()).map(normalizeWord)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        let common = lcsPairs(Array(x.prefix(3000)), Array(y.prefix(3000))).count
        return Double(common) / Double(max(min(x.count, 3000), min(y.count, 3000)))
    }

    private static func normalizeWord(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
    }

    /// Indices of matching words (longest common subsequence).
    static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var table = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] &+ 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    /// Word-level differences ("teh" → "the"), grouped into runs.
    static func wordChanges(from original: String, to corrected: String) -> [Change] {
        let a = Array(words(original).prefix(4000)), b = Array(words(corrected).prefix(4000))
        let pairs = lcsPairs(a, b) + [(a.count, b.count)]
        var changes: [Change] = []
        var i = 0, j = 0
        for (pi, pj) in pairs {
            if pi > i || pj > j {
                let from = a[i..<pi].joined(separator: " "), to = b[j..<pj].joined(separator: " ")
                if from != to { changes.append(Change(from: from, to: to)) }
            }
            i = pi + 1
            j = pj + 1
        }
        return changes
    }

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "have", "this", "that", "with", "from", "they", "will", "would", "there", "their", "what", "about",
        "which", "when", "your", "were", "been", "also", "into", "than", "then", "them", "these", "some", "more",
        "its", "his", "she", "him", "who", "how", "may", "just", "over", "such", "only", "very", "most", "other",
    ]

    /// Frequency-scored sentences in their original order, as bullets.
    static func extractiveSummary(_ text: String, sentences count: Int) -> String {
        let all = sentences(text).filter { $0.count >= 20 && $0.count <= 600 }
        guard !all.isEmpty else {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
            return lines.prefix(count).map { "- \($0)" }.joined(separator: "\n")
        }
        var frequency: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            if word.count >= 3, !stopwords.contains(word) { frequency[word, default: 0] += 1 }
            return true
        }
        let scored = all.enumerated().map { index, sentence -> (Int, Double) in
            let words = sentence.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let score = words.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) } / max(1, Double(words.count).squareRoot())
            // Slight preference for the opening sentences.
            return (index, score * (index == 0 ? 1.3 : 1))
        }
        let keep = min(all.count, count, max(2, (all.count + 1) / 2))
        let chosen = scored.sorted { $0.1 > $1.1 }.prefix(keep).map(\.0).sorted()
        return chosen.map { "- \(all[$0])" }.joined(separator: "\n")
    }

    static func cleanQuery(_ text: String) -> String? {
        var query = clean(text).components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        query = query.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”`-•*"))
        query = TrayAIRegex.replace(#"(?i)^(search( query)?|query)\s*:\s*"#, in: query, with: "")
        let words = words(query)
        guard !words.isEmpty, words.count <= 16 else { return nil }
        return words.joined(separator: " ")
    }

    /// Query without a model: error lines first, then the most prominent
    /// text in images, page titles, or the first words of text.
    static func ruleBasedQuery(_ sources: [TrayAISource]) -> String? {
        var candidates: [String] = []
        for source in sources {
            if let analysis = source.analysis {
                let errorLine = analysis.lines.map(\.text).first {
                    $0.range(of: #"(?i)\b(error|failed|exception|denied|not found|couldn.t|unable)\b"#, options: .regularExpression) != nil
                }
                if let errorLine { candidates.append(errorLine) }
                let ranked = analysis.rows.filter { $0.text.filter(\.isLetter).count >= 3 }.sorted { $0.height > $1.height }
                // The headline, plus the next line only when the headline is very short.
                let take = (ranked.first.map { Self.words($0.text).count } ?? 0) < 3 ? 2 : 1
                let prominent = ranked.prefix(take).map(\.text)
                candidates += prominent
                if prominent.isEmpty { candidates += analysis.labels.prefix(2).map(\.name) }
            } else if let page = source.page {
                candidates.append(page.title ?? page.url.host ?? "")
            } else if source.kind == .link {
                candidates.append(source.name)
            } else if !source.text.isEmpty {
                candidates.append(sentences(source.text).first ?? source.text)
            } else if let file = source.file {
                candidates.append(file.name)
            }
        }
        let words = words(candidates.joined(separator: " ")).prefix(10)
        let query = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return query.isEmpty ? nil : query
    }

    /// Short human-readable receipt summary for the panel.
    static func describe(_ receipt: TrayAIReceipt) -> String {
        func money(_ value: Double?) -> String {
            guard let value else { return "—" }
            return (receipt.currency.map { $0 + " " } ?? "") + TrayAIReceipt.format(value)
        }
        var lines: [String] = []
        let head = [receipt.merchant ?? "Receipt", receipt.date].compactMap { $0 }.joined(separator: " · ")
        lines.append("## \(head)")
        for item in receipt.items {
            let qty = item.qty.map { $0 == 1 ? "" : "\(TrayAIReceipt.format($0, decimals: 3)) × " } ?? ""
            lines.append("- \(qty)\(item.name): \(money(item.total))")
        }
        if let subtotal = receipt.subtotal { lines.append("Subtotal: \(money(subtotal))") }
        if let tax = receipt.tax { lines.append("Tax: \(money(tax))") }
        if let tip = receipt.tip { lines.append("Tip: \(money(tip))") }
        lines.append("Total: \(money(receipt.total))")
        if let payment = receipt.paymentMethod { lines.append("Paid with \(payment)") }
        if receipt.warnings.isEmpty {
            lines.append("✓ The numbers add up.")
        } else {
            lines.append("Warnings:")
            lines += receipt.warnings.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    static func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Receipt grounding

enum TrayAIReceiptGrounding {
    /// Numbers in a model's receipt that don't appear in the OCR text
    /// (computed products like qty × unit price are allowed).
    static func ungroundedCount(_ receipt: TrayAIReceipt, ocrText: String) -> Int {
        let printed = Set(TrayAIRegex.matches(TrayAIReceiptParser.amountPattern, in: ocrText)
            .compactMap(TrayAIReceiptParser.parseAmount).map { cents(abs($0)) })
        var values: [Double] = [receipt.subtotal, receipt.tax, receipt.tip, receipt.total].compactMap { $0 }
        for item in receipt.items {
            if let total = item.total { values.append(total) }
            if let unit = item.unitPrice, unit != item.total { values.append(unit) }
        }
        return values.filter { !printed.contains(cents(abs($0))) }.count
    }

    private static func cents(_ value: Double) -> Int { Int((value * 100).rounded()) }
}

// MARK: - Design measurements

enum TrayAIDesign {
    struct TypeLevel: Sendable {
        var height: Double
        var count: Int
    }

    /// Text line-box heights grouped into levels (within 12%), largest first.
    static func typeLevels(_ analysis: TrayAIImageAnalysis) -> [TypeLevel] {
        let heights = analysis.lines.map { Double($0.rect.height) }.sorted(by: >)
        var levels: [TypeLevel] = []
        for height in heights {
            if let last = levels.indices.last, height >= levels[last].height * 0.88 {
                levels[last].count += 1
            } else {
                levels.append(TypeLevel(height: height, count: 1))
            }
        }
        return levels
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    struct Metrics: Sendable {
        var name: String
        var analysis: TrayAIImageAnalysis
        var levels: [TypeLevel]
        var bodyHeight: Double?
        var rowGap: Double?
        var leftMargin: Double?
        var textCoverage: Double
        var bestTextContrast: Double?
    }

    static func metrics(_ source: TrayAISource) -> Metrics? {
        guard let analysis = source.analysis else { return nil }
        let levels = typeLevels(analysis)
        let body = levels.max { $0.count < $1.count }?.height
        let rows = analysis.rows.sorted { $0.rect.minY < $1.rect.minY }
        var gaps: [Double] = []
        for (a, b) in zip(rows, rows.dropFirst()) {
            let gap = Double(b.rect.minY - a.rect.maxY)
            if gap > 0 { gaps.append(gap) }
        }
        let width = Double(analysis.pixelSize.width), height = Double(analysis.pixelSize.height)
        let left = analysis.lines.map { Double($0.rect.minX) }.min().map { $0 / max(width, 1) }
        let textArea = analysis.lines.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        let contrast = analysis.textContrast
        return Metrics(name: source.name, analysis: analysis, levels: levels, bodyHeight: body, rowGap: median(gaps),
                       leftMargin: left, textCoverage: textArea / max(width * height, 1), bestTextContrast: contrast)
    }

    static func facts(_ sources: [TrayAISource]) -> String {
        let all = sources.compactMap(metrics)
        var blocks: [String] = []
        for (index, m) in all.enumerated() {
            let a = m.analysis
            let w = Int(a.pixelSize.width), h = Int(a.pixelSize.height)
            let orientation = w > h ? "landscape" : (w < h ? "portrait" : "square")
            var lines = ["Design \(index + 1) — \(m.name)"]
            lines.append("- Size: \(w)×\(h) px (\(orientation), aspect \(String(format: "%.2f", Double(w) / Double(max(h, 1)))))")
            lines.append("- Palette: \(a.colorSummary)")
            if let bg = a.colors.first {
                lines.append("- Background: \(bg.hex) (\(bg.luminance > 0.5 ? "light" : "dark") theme), ~\(Int((a.backgroundFraction * 100).rounded()))% of the canvas is plain background")
            }
            if let contrast = m.bestTextContrast {
                lines.append("- Text contrast (median over text lines): \(String(format: "%.1f", contrast)):1\(contrast < 4.5 ? " (below WCAG AA 4.5:1)" : "")")
            }
            if a.hasText {
                let levels = m.levels.prefix(4).map { "\(Int($0.height.rounded())) px ×\($0.count)" }.joined(separator: ", ")
                lines.append("- Text: \(a.lines.count) lines, \(a.text.split(whereSeparator: \.isWhitespace).count) words; line heights \(levels) (\(m.levels.count) size level\(m.levels.count == 1 ? "" : "s"))")
                if let largest = m.levels.first?.height, let body = m.bodyHeight, body > 0 {
                    lines.append("- Type scale: largest/body ≈ \(String(format: "%.1f", largest / body))×")
                }
                if let gap = m.rowGap, let body = m.bodyHeight, body > 0 {
                    lines.append("- Spacing: median gap between text rows \(Int(gap.rounded())) px (\(String(format: "%.1f", gap / body))× body line height)")
                }
                if let left = m.leftMargin { lines.append("- Left margin to first text: \(Int((left * 100).rounded()))% of width") }
                lines.append("- Text covers ~\(Int((m.textCoverage * 100).rounded()))% of the canvas")
                let headline = a.rows.sorted { $0.height > $1.height }.first?.text
                if let headline { lines.append("- Most prominent text: “\(String(headline.prefix(80)))”") }
            } else {
                lines.append("- No text found")
            }
            if !a.labels.isEmpty { lines.append("- Labels: \(a.labels.prefix(3).map(\.name).joined(separator: ", "))") }
            blocks.append(lines.joined(separator: "\n"))
        }
        if all.count >= 2 {
            let first = all[0].analysis.colors, second = all[1].analysis.colors
            let shared = first.filter { a in second.contains { $0.distance(to: a) < 0.06 } }
            blocks.append("Shared colors (Design 1 & 2): \(shared.isEmpty ? "none" : shared.map(\.hex).joined(separator: ", "))")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Rule-based differences and recommendations when no model is available.
    static func ruleBasedComparison(_ sources: [TrayAISource]) -> String {
        let all = sources.compactMap(metrics)
        guard all.count >= 2 else { return "" }
        var differences: [String] = []
        var recommendations: [String] = []
        let names = all.indices.map { "Design \($0 + 1)" }

        let themes = all.map { ($0.analysis.colors.first?.luminance ?? 1) > 0.5 ? "light" : "dark" }
        if Set(themes).count > 1 {
            differences.append("Theme: " + zip(names, themes).map { "\($0) is \($1)" }.joined(separator: ", ") + ".")
        }
        let paletteSizes = all.map { $0.analysis.colors.filter { $0.fraction >= 0.03 }.count }
        if let maxSize = paletteSizes.max(), let minSize = paletteSizes.min(), maxSize - minSize >= 2 {
            differences.append("Palette breadth: " + zip(names, paletteSizes).map { "\($0) uses \($1) main colors" }.joined(separator: ", ") + ".")
        }
        let whitespace = all.map { $0.analysis.backgroundFraction }
        if let a = whitespace.max(), let b = whitespace.min(), a - b > 0.15, let airy = whitespace.firstIndex(of: a) {
            differences.append("\(names[airy]) is noticeably airier (\(Int((a * 100).rounded()))% plain background vs \(Int((b * 100).rounded()))%).")
        }
        let levels = all.map(\.levels.count)
        if Set(levels).count > 1 {
            differences.append("Type hierarchy: " + zip(names, levels).map { "\($0) has \($1) text size level\($1 == 1 ? "" : "s")" }.joined(separator: ", ") + ".")
        }
        let words = all.map { $0.analysis.text.split(whereSeparator: \.isWhitespace).count }
        if let a = words.max(), let b = words.min(), a > max(10, b * 2), let dense = words.firstIndex(of: a) {
            differences.append("\(names[dense]) is much more text-heavy (\(a) words vs \(b)).")
        }
        if differences.isEmpty { differences.append("The designs are close in theme, palette breadth, whitespace and type levels.") }

        for (index, m) in all.enumerated() {
            if let contrast = m.bestTextContrast, contrast < 4.5 {
                recommendations.append("\(names[index]): text contrast is about \(String(format: "%.1f", contrast)):1; aim for ≥ 4.5:1 for body text.")
            }
            if m.levels.count > 5 {
                recommendations.append("\(names[index]): \(m.levels.count) text sizes; consolidate to 3-4 levels for a clearer hierarchy.")
            }
            if m.levels.count == 1, m.analysis.lines.count > 3 {
                recommendations.append("\(names[index]): all text is one size; add a larger heading level to guide the eye.")
            }
            if let gap = m.rowGap, let body = m.bodyHeight, body > 0, gap / body < 0.3 {
                recommendations.append("\(names[index]): text rows are tight (\(String(format: "%.1f", gap / body))× line height); add vertical spacing.")
            }
        }
        if recommendations.isEmpty { recommendations.append("Keep a shared palette and type scale across the designs for consistency.") }
        return "## Key differences\n" + differences.map { "- \($0)" }.joined(separator: "\n")
            + "\n\n## Recommendations\n" + recommendations.map { "- \($0)" }.joined(separator: "\n")
    }
}

// MARK: - Time limits

enum TrayAITimeout {
    /// Runs `operation`, throwing `TrayAIError.timedOut` after `seconds`
    /// without waiting for the operation to notice its cancellation.
    static func run<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = TrayAITimeoutGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                let work = Task {
                    do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    gate.finish(.failure(TrayAIError.timedOut))
                }
                gate.attach(work: work, timer: timer)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

final class TrayAITimeoutGate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var pending: Result<T, Error>?
        var done = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = state.withLock { state in
            if let pending = state.pending {
                state.pending = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            if state.done { return true }
            state.tasks = [work, timer]
            return false
        }
        if cancelNow {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, tasks): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = state.withLock { state in
            guard !state.done else { return (nil, []) }
            state.done = true
            let tasks = state.tasks
            state.tasks = []
            if let continuation = state.continuation {
                state.continuation = nil
                return (continuation, tasks)
            }
            state.pending = result
            return (nil, tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
