import Foundation

// Incremental caption translation, as live caption translators do it
// (Google Meet / Translate's "re-translation"): finalised phrases are
// translated once, in order, and kept; the phrase still being spoken is
// re-translated as it grows, at most every `partialInterval`, with its last
// words masked so the caption doesn't flicker. Results are cached, so the
// final version of a phrase whose last partial already had the same text
// costs nothing.

/// One translated caption: a transcript segment and its translation.
struct LiveTranslatedLine: Identifiable, Codable, Equatable, Sendable {
    /// The transcript segment's id.
    let id: UUID
    let speaker: MeetingSpeaker
    /// Seconds since the recording started.
    var start: TimeInterval
    var end: TimeInterval
    var sourceText: String
    /// Detected language of `sourceText` ("es").
    var sourceLanguage: String
    var targetLanguage: String
    /// Full translation of `sourceText` (empty when translation failed).
    var translatedText: String
    /// What captions show: the translation, masked while the phrase is volatile.
    var displayText: String
    var isFinal: Bool
    var engine: LiveTranslationEngineKind

    /// Already in the target language, shown as spoken.
    var isOriginal: Bool { engine == .skipped }
    /// No translator could translate it: captions show the original, dimmed.
    var failed: Bool { engine == .untranslated || (translatedText.isEmpty && !isOriginal) }
}

@MainActor
final class LiveTranslationPipeline {
    struct Request: Sendable {
        let text: String
        let source: Locale.Language
        let target: Locale.Language
        let isPartial: Bool
    }

    typealias Translator = @MainActor (Request) async throws -> (text: String, engine: LiveTranslationEngineKind)

    var target: Locale.Language {
        didSet {
            guard LiveTranslationLanguages.id(oldValue) != LiveTranslationLanguages.id(target) else { return }
            cache = [:]
            cacheOrder = []
            lastPartialAt = [:]
            // Re-translate the latest captions so the band switches language now.
            let recent = lines.suffix(2).compactMap { line -> TranscriptSegment? in
                guard line.isFinal else { return nil }
                return TranscriptSegment(id: line.id, speaker: line.speaker, text: line.sourceText,
                                         start: line.start, end: line.end, isFinal: true)
            }
            for segment in recent where !finalQueue.contains(where: { $0.id == segment.id }) {
                finalQueue.append(segment)
            }
            kick()
        }
    }

    /// Whose speech is translated (by default only other participants).
    var speakers: Set<MeetingSpeaker>
    /// Minimum time between re-translations of a speaker's volatile phrase.
    var partialInterval: TimeInterval = 0.6
    /// Words hidden from the end of a volatile translation (mask-k).
    var maskWords = 2
    /// Called after each caption changes (on the main actor).
    var onUpdate: ((LiveTranslatedLine) -> Void)?
    /// Called when a translation fails (the line keeps its original text).
    var onError: ((Error, Request) -> Void)?

    private(set) var lines: [LiveTranslatedLine] = []
    private var lineIndex: [UUID: Int] = [:]
    private var seen: [UUID: (text: String, isFinal: Bool)] = [:]
    private var scannedCount = 0
    /// Volatile segments being followed, with their last known index.
    private var openSegments: [UUID: Int] = [:]
    private var finalQueue: [TranscriptSegment] = []
    private var partials: [MeetingSpeaker: TranscriptSegment] = [:]
    private var lastPartialAt: [MeetingSpeaker: Date] = [:]
    private var worker: Task<Void, Never>?
    private var workerToken = UUID()
    private var processingFinal = false
    private var detector: LiveTranslationLanguageDetector
    private var cache: [String: (text: String, engine: LiveTranslationEngineKind)] = [:]
    private var cacheOrder: [String] = []
    private let translator: Translator

    init(target: Locale.Language,
         speakers: Set<MeetingSpeaker> = [.others],
         detector: LiveTranslationLanguageDetector = LiveTranslationLanguageDetector(),
         translator: @escaping Translator) {
        self.target = target
        self.speakers = speakers
        self.detector = detector
        self.translator = translator
    }

    var isIdle: Bool { worker == nil && finalQueue.isEmpty && partials.isEmpty }

    /// The language a stream is transcribed in, when not the Mac's own
    /// (used for text too short to detect).
    func setTranscriberLanguage(_ language: Locale.Language?, for speaker: MeetingSpeaker) {
        detector.speakerLanguages[speaker] = language
    }

    // MARK: Input

    /// Feed the meeting's whole live transcript (MeetingRecord.segments) each
    /// time it changes. Only the tail is scanned, plus every phrase still
    /// volatile: MeetingAssistant appends new segments and replaces volatile
    /// ones in place, and while one speaker's phrase is still growing the
    /// other speaker can append any number of segments after it.
    func observe(_ segments: [TranscriptSegment]) {
        let from = max(0, min(scannedCount, segments.count) - 6)
        scannedCount = segments.count
        var checked = Set<Int>()
        for (id, hint) in openSegments {
            let index: Int?
            if hint < segments.count, segments[hint].id == id {
                index = hint
            } else {
                // Indices shift only when the transcript is rewritten (stop()
                // drops empty phrases): find it again, rarely.
                index = segments.firstIndex { $0.id == id }
            }
            guard let index else { openSegments[id] = nil; continue }
            openSegments[id] = index
            if index < from {
                checked.insert(index)
                consider(segments[index], at: index)
            }
        }
        if from < segments.count {
            for index in from..<segments.count where !checked.contains(index) {
                consider(segments[index], at: index)
            }
        }
        kick()
    }

    /// Starts from a transcript already in progress: everything but the last
    /// `keepLast` segments is treated as seen (backfill() translates it later).
    /// Phrases still being spoken there are followed, so their finals show.
    func start(from segments: [TranscriptSegment], keepLast: Int = 2) {
        let skip = max(0, segments.count - keepLast)
        for (index, segment) in segments.prefix(skip).enumerated() {
            seen[segment.id] = (segment.text.trimmingCharacters(in: .whitespacesAndNewlines), segment.isFinal)
            if !segment.isFinal, speakers.contains(segment.speaker) { openSegments[segment.id] = index }
        }
        scannedCount = skip
        observe(segments)
    }

    /// Queues every final segment that has no translation in the current
    /// target language yet (e.g. speech from before the feature was turned
    /// on), then waits for all finals to finish.
    func backfill(_ segments: [TranscriptSegment]) async {
        let targetID = LiveTranslationLanguages.id(target)
        for segment in segments where segment.isFinal && speakers.contains(segment.speaker) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let index = lineIndex[segment.id], lines[index].isFinal, lines[index].sourceText == text,
               lines[index].targetLanguage == targetID, !lines[index].failed { continue }
            if finalQueue.contains(where: { $0.id == segment.id }) { continue }
            seen[segment.id] = (text, true)
            finalQueue.append(segment)
        }
        finalQueue.sort { $0.start < $1.start }
        kick()
        await drain()
    }

    /// Waits until every queued final phrase is translated (or the caller is
    /// cancelled: a cancelled sleep returns at once, so don't spin on it).
    func drain() async {
        while (!finalQueue.isEmpty || processingFinal), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Drops volatile work (the meeting stopped); finals still finish.
    func dropPartials() {
        partials = [:]
    }

    func reset() {
        worker?.cancel()
        worker = nil
        workerToken = UUID()
        lines = []
        lineIndex = [:]
        seen = [:]
        openSegments = [:]
        scannedCount = 0
        finalQueue = []
        partials = [:]
        lastPartialAt = [:]
        processingFinal = false
        detector.reset()
    }

    private func consider(_ segment: TranscriptSegment, at index: Int) {
        guard speakers.contains(segment.speaker) else { return }
        if segment.isFinal {
            openSegments[segment.id] = nil
        } else {
            openSegments[segment.id] = index
        }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let previous = seen[segment.id], previous.text == text, previous.isFinal == segment.isFinal { return }
        // A final line never goes back to volatile.
        if let previous = seen[segment.id], previous.isFinal, !segment.isFinal { return }
        seen[segment.id] = (text, segment.isFinal)
        if segment.isFinal {
            if partials[segment.speaker]?.id == segment.id { partials[segment.speaker] = nil }
            finalQueue.removeAll { $0.id == segment.id }
            finalQueue.append(segment)
        } else {
            partials[segment.speaker] = segment
        }
    }

    // MARK: Worker

    private func kick() {
        guard worker == nil, !(finalQueue.isEmpty && partials.isEmpty) else { return }
        let token = UUID()
        workerToken = token
        worker = Task { [weak self] in
            await self?.run(token: token)
        }
    }

    private func run(token: UUID) async {
        defer {
            // reset() may have started a newer worker meanwhile.
            if workerToken == token { worker = nil }
        }
        while !Task.isCancelled {
            if !finalQueue.isEmpty {
                let segment = finalQueue.removeFirst()
                processingFinal = true
                await process(segment, partial: false)
                processingFinal = false
                continue
            }
            guard !partials.isEmpty else { break }
            let now = Date()
            let due = partials.values
                .filter { now >= (lastPartialAt[$0.speaker] ?? .distantPast).addingTimeInterval(partialInterval) }
                .min { $0.start < $1.start }
            if let segment = due {
                partials[segment.speaker] = nil
                lastPartialAt[segment.speaker] = now
                await process(segment, partial: true)
                continue
            }
            // Short naps so a final arriving meanwhile isn't held back.
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Work queued while the last item finished.
        if !Task.isCancelled, workerToken == token, !(finalQueue.isEmpty && partials.isEmpty) {
            Task { [weak self] in self?.kick() }
        }
    }

    private func process(_ segment: TranscriptSegment, partial: Bool) async {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if partial, let index = lineIndex[segment.id], lines[index].isFinal { return }
        let targetLanguage = target
        let targetID = LiveTranslationLanguages.id(targetLanguage)
        let detection = detector.detect(text, speaker: segment.speaker)
        let sourceID = LiveTranslationLanguages.id(detection.language)

        var line = LiveTranslatedLine(
            id: segment.id, speaker: segment.speaker, start: segment.start, end: segment.end,
            sourceText: text, sourceLanguage: sourceID, targetLanguage: targetID,
            translatedText: "", displayText: text, isFinal: !partial, engine: .skipped
        )

        if LiveTranslationLanguages.isSame(detection.language, targetLanguage) {
            line.translatedText = text
            line.displayText = text
            line.engine = .skipped
        } else {
            let key = "\(sourceID)>\(targetID)|\(text)"
            let result: (text: String, engine: LiveTranslationEngineKind)?
            if let cached = cache[key] {
                result = cached
            } else {
                let request = Request(text: text, source: detection.language, target: targetLanguage, isPartial: partial)
                do {
                    let translated = try await translator(request)
                    let clean = translated.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = clean.isEmpty ? nil : (clean, translated.engine)
                    if let result { remember(key, result) }
                } catch {
                    if !(error is CancellationError) { onError?(error, request) }
                    result = nil
                }
            }
            // Superseded while translating: a newer final, or another target.
            if Task.isCancelled || LiveTranslationLanguages.id(target) != targetID { return }
            if partial, let index = lineIndex[segment.id], lines[index].isFinal { return }
            if let result {
                line.translatedText = result.text
                line.engine = result.engine
                line.displayText = partial
                    ? LiveTranslationLanguages.masked(result.text, target: targetLanguage, words: maskWords)
                    : result.text
            } else if partial, let index = lineIndex[segment.id], !lines[index].failed {
                // Keep the previous partial translation rather than flashing the original.
                return
            } else {
                line.engine = .untranslated
                line.translatedText = ""
                line.displayText = text
            }
        }
        store(line)
    }

    private func store(_ line: LiveTranslatedLine) {
        if let index = lineIndex[line.id] {
            lines[index] = line
        } else {
            lineIndex[line.id] = lines.count
            lines.append(line)
        }
        onUpdate?(line)
    }

    private func remember(_ key: String, _ value: (text: String, engine: LiveTranslationEngineKind)) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        if cacheOrder.count > 300 {
            let drop = cacheOrder.prefix(100)
            drop.forEach { cache[$0] = nil }
            cacheOrder.removeFirst(100)
        }
    }
}

// MARK: - Saved transcript

/// The translated transcript of one meeting, saved next to (not inside) the
/// meeting library: ~/Library/Application Support/SparkV/LiveTranslation/<id>.json.
struct LiveTranslationTranscript: Codable, Equatable, Sendable {
    let meetingID: UUID
    var title: String
    var startedAt: Date
    var targetLanguage: String
    var lines: [LiveTranslatedLine]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/LiveTranslation", isDirectory: true)
    }

    static func url(for meetingID: UUID, in directory: URL = LiveTranslationTranscript.directory) -> URL {
        directory.appendingPathComponent("\(meetingID.uuidString).json")
    }

    func write(to directory: URL = LiveTranslationTranscript.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(for: meetingID, in: directory), options: .atomic)
    }

    static func load(meetingID: UUID, from directory: URL = LiveTranslationTranscript.directory) -> LiveTranslationTranscript? {
        guard let data = try? Data(contentsOf: url(for: meetingID, in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveTranslationTranscript.self, from: data)
    }

    /// Heading that starts the block added to the meeting's notes.
    static func notesHeading(target: String) -> String {
        "Live translation (\(LiveTranslationLanguages.displayName(target)))"
    }

    /// Plain-text block for the meeting notepad: one line per final caption,
    /// "[mm:ss] Speaker: translation".
    func notesBlock(userName: String = MeetingAssistant.userName) -> String {
        var out = [Self.notesHeading(target: targetLanguage)]
        for line in lines where line.isFinal {
            let who = line.speaker == .me ? userName : "Others"
            let text = line.failed ? "\(line.sourceText) (not translated)" : line.displayText
            let tag = line.isOriginal ? "" : " [\(LiveTranslationLanguages.shortTag(line.sourceLanguage))]"
            out.append("[\(MeetingFormat.clock(line.start))] \(who)\(tag): \(text)")
        }
        return out.joined(separator: "\n")
    }

    func markdown(userName: String = MeetingAssistant.userName) -> String {
        var out = ["# \(title)", "", "## \(Self.notesHeading(target: targetLanguage))", ""]
        for line in lines where line.isFinal {
            let who = line.speaker == .me ? userName : "Others"
            out.append("- **[\(MeetingFormat.clock(line.start))] \(who):** \(line.failed ? line.sourceText : line.displayText)")
            if !line.isOriginal, !line.failed {
                out.append("  - _\(LiveTranslationLanguages.displayName(line.sourceLanguage)):_ \(line.sourceText)")
            }
        }
        return out.joined(separator: "\n")
    }
}
