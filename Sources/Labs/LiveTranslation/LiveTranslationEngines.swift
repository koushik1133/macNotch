import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif
import Synchronization

// The three translators behind Live Translation, best first:
// 1. Apple Translation (on device, the same models as the Translate app).
//    macOS 26+: a standalone TranslationSession(installedSource:target:).
//    macOS 15: sessions only come from SwiftUI's .translationTask, so a tiny
//    invisible host view keeps one open and serves requests (bridge below).
// 2. The on-device Apple Intelligence model (FoundationModels) for short
//    captions when a language pair isn't installed.
// 3. Groq, only when the user turned on "Allow Live Translation to use my
//    Groq key" (off by default).

enum LiveTranslationEngineKind: String, Codable, Sendable {
    case apple
    case onDeviceModel
    case groq
    /// Already in the target language: shown as spoken.
    case skipped
    /// No translator could do it: shown as spoken, dimmed.
    case untranslated

    var label: String {
        switch self {
        case .apple: "Apple Translation"
        case .onDeviceModel: "Apple Intelligence"
        case .groq: "Groq"
        case .skipped: "Original"
        case .untranslated: "Not translated"
        }
    }
}

enum LiveTranslationError: Error, LocalizedError, Equatable {
    /// Supported, but the language files aren't on this Mac yet.
    case notInstalled(source: String, target: String)
    case unsupportedPair(source: String, target: String)
    case noTranslator
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .notInstalled(let s, let t):
            "\(LiveTranslationLanguages.displayName(s)) → \(LiveTranslationLanguages.displayName(t)) isn't downloaded"
        case .unsupportedPair(let s, let t):
            "\(LiveTranslationLanguages.displayName(s)) → \(LiveTranslationLanguages.displayName(t)) isn't supported"
        case .noTranslator: "No translator is available"
        case .emptyResult: "The translation came back empty"
        }
    }
}

// MARK: - Apple Translation

/// Availability of one language pair in Apple Translation.
enum LiveTranslationPairStatus: Equatable, Sendable {
    case installed
    case needsDownload
    case unsupported
}

/// Apple Translation, on device. All calls on the main actor; sessions are
/// cached per language pair and reused (a new pair costs ~1.8 s once, a warm
/// session ~0.3–0.8 s per caption on an M-series Mac).
@MainActor
final class LiveTranslationAppleEngine {
    /// Use the SwiftUI bridge even where standalone sessions exist (tests).
    var forceBridge = false
    private var statusCache: [String: LiveTranslationPairStatus] = [:]
    private var lowLatencyInstalled: [String: Bool] = [:]
    /// Standalone sessions (macOS 26+), as AnyObject so this type compiles on 15.
    private var sessions: [String: AnyObject] = [:]
    private(set) lazy var bridge = LiveTranslationSessionBridge()

    static func pairKey(_ source: Locale.Language, _ target: Locale.Language) -> String {
        LiveTranslationLanguages.id(source) + ">" + LiveTranslationLanguages.id(target)
    }

    /// Whether `source → target` can be translated now, needs a download, or never.
    func status(source: Locale.Language, target: Locale.Language) async -> LiveTranslationPairStatus {
        let key = Self.pairKey(source, target)
        if let cached = statusCache[key] { return cached }
        #if canImport(Translation)
        let result: LiveTranslationPairStatus
        switch await Self.availability(source: source, target: target, lowLatency: false) {
        case .installed: result = .installed
        case .supported: result = .needsDownload
        case .unsupported: result = .unsupported
        @unknown default: result = .unsupported
        }
        statusCache[key] = result
        if #available(macOS 26.4, *), result == .installed {
            let low = await Self.availability(source: source, target: target, lowLatency: true)
            lowLatencyInstalled[key] = low == .installed
        }
        return result
        #else
        return .unsupported
        #endif
    }

    /// Forget cached availability (after the user downloaded languages).
    func refreshStatuses() {
        statusCache = [:]
        lowLatencyInstalled = [:]
        sessions = [:]
    }

    func supportedLanguages() async -> [Locale.Language] {
        #if canImport(Translation)
        return await Self.systemSupportedLanguages()
        #else
        return []
        #endif
    }

    #if canImport(Translation)
    // LanguageAvailability isn't Sendable: create and use it off the main actor.
    nonisolated private static func availability(
        source: Locale.Language, target: Locale.Language, lowLatency: Bool
    ) async -> LanguageAvailability.Status {
        if lowLatency, #available(macOS 26.4, *) {
            return await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
        }
        return await LanguageAvailability().status(from: source, to: target)
    }

    nonisolated private static func systemSupportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }
    #endif

    /// Loads the models for a pair ahead of the first caption.
    func prewarm(source: Locale.Language, target: Locale.Language) async {
        guard await status(source: source, target: target) == .installed else { return }
        _ = try? await translate("Hello.", source: source, target: target)
    }

    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        let key = Self.pairKey(source, target)
        switch await status(source: source, target: target) {
        case .installed: break
        case .needsDownload:
            throw LiveTranslationError.notInstalled(source: LiveTranslationLanguages.id(source), target: LiveTranslationLanguages.id(target))
        case .unsupported:
            throw LiveTranslationError.unsupportedPair(source: LiveTranslationLanguages.id(source), target: LiveTranslationLanguages.id(target))
        }
        #if canImport(Translation)
        if #available(macOS 26.0, *), !forceBridge {
            // TranslationSession isn't Sendable; this engine is the only user
            // of the cached session and the caption pipeline is sequential.
            nonisolated(unsafe) let session = standaloneSession(key: key, source: source, target: target)
            do {
                let response = try await session.translate(text)
                return response.targetText
            } catch {
                sessions[key] = nil
                throw Self.map(error, source: source, target: target, statusCache: &statusCache, key: key)
            }
        }
        do {
            return try await bridge.translate(text, source: source, target: target)
        } catch {
            throw Self.map(error, source: source, target: target, statusCache: &statusCache, key: key)
        }
        #else
        throw LiveTranslationError.noTranslator
        #endif
    }

    #if canImport(Translation)
    @available(macOS 26.0, *)
    private func standaloneSession(key: String, source: Locale.Language, target: Locale.Language) -> TranslationSession {
        if let existing = sessions[key] as? TranslationSession { return existing }
        let session: TranslationSession
        if #available(macOS 26.4, *), lowLatencyInstalled[key] == true {
            // The low-latency models, when the system has them for this pair.
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        sessions[key] = session
        return session
    }

    private static func map(
        _ error: Error, source: Locale.Language, target: Locale.Language,
        statusCache: inout [String: LiveTranslationPairStatus], key: String
    ) -> Error {
        if error is CancellationError || error is LiveTranslationError { return error }
        let s = LiveTranslationLanguages.id(source), t = LiveTranslationLanguages.id(target)
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            statusCache[key] = .needsDownload
            return LiveTranslationError.notInstalled(source: s, target: t)
        }
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            statusCache[key] = .unsupported
            return LiveTranslationError.unsupportedPair(source: s, target: t)
        }
        if TranslationError.nothingToTranslate ~= error { return LiveTranslationError.emptyResult }
        return error
    }
    #endif
}

// MARK: - macOS 15 bridge

/// On macOS 15 a TranslationSession can only be obtained inside SwiftUI's
/// `.translationTask`. This bridge publishes the wanted configuration; the
/// host view (`LiveTranslationSessionHost`, kept alive in a 1×1 invisible
/// panel) receives the session and serves queued requests in its closure
/// until the configuration changes. This is the pattern Apple's sample uses
/// for batch work, kept open for the whole meeting.
@MainActor
final class LiveTranslationSessionBridge: ObservableObject {
    #if canImport(Translation)
    @Published private(set) var configuration: TranslationSession.Configuration?
    #endif

    private struct Job {
        let id = UUID()
        let text: String
        let key: String
        let continuation: CheckedContinuation<String, Error>
    }

    /// A job nobody picked up in this long fails (SwiftUI never delivered a
    /// session), so the caption pipeline falls back instead of waiting forever.
    var queueTimeout: Duration = .seconds(8)

    private var jobs: [Job] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var servingKey: String?
    private var hostPanel: NSPanel?

    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        #if canImport(Translation)
        let key = LiveTranslationAppleEngine.pairKey(source, target)
        ensureHost()
        if configuration?.source != source || configuration?.target != target {
            // The old session is cancelled; its queued jobs would never run.
            let stale = jobs.filter { $0.key != key }
            jobs.removeAll { $0.key != key }
            stale.forEach { $0.continuation.resume(throwing: CancellationError()) }
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let job = Job(text: text, key: key, continuation: continuation)
            jobs.append(job)
            wakeWaiters()
            // Whoever removes the job from the queue resumes it: serve() once
            // it starts, this timer if it never does.
            let timeout = queueTimeout
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                self.jobs.remove(at: index).continuation.resume(throwing: MeetingAIError.timedOut)
            }
        }
        #else
        throw LiveTranslationError.noTranslator
        #endif
    }

    #if canImport(Translation)
    /// Called from the host view's `.translationTask` closure: serves jobs for
    /// this session's pair until SwiftUI cancels the task (new configuration).
    func serve(_ session: TranslationSession) async {
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }
        let key = LiveTranslationAppleEngine.pairKey(source, target)
        servingKey = key
        defer { if servingKey == key { servingKey = nil } }
        while !Task.isCancelled {
            if let index = jobs.firstIndex(where: { $0.key == key }) {
                let job = jobs.remove(at: index)
                nonisolated(unsafe) let unsafeSession = session
                do {
                    let response = try await unsafeSession.translate(job.text)
                    job.continuation.resume(returning: response.targetText)
                } catch {
                    job.continuation.resume(throwing: error)
                }
                continue
            }
            // Sleep until a job arrives or SwiftUI cancels this session.
            let token = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled || jobs.contains(where: { $0.key == key }) {
                        continuation.resume()
                    } else {
                        waiters[token] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.waiters.removeValue(forKey: token)?.resume()
                }
            }
        }
    }
    #endif

    /// Fails everything queued (meeting ended, feature turned off).
    func cancelAll() {
        let pending = jobs
        jobs = []
        pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
        wakeWaiters()
    }

    private func wakeWaiters() {
        let all = waiters
        waiters = [:]
        all.values.forEach { $0.resume() }
    }

    func tearDown() {
        cancelAll()
        hostPanel?.orderOut(nil)
        hostPanel = nil
    }

    /// A 1×1 transparent, click-through panel hosting the session view. SwiftUI
    /// only runs `.translationTask` for a view that is in an ordered-in window.
    private func ensureHost() {
        guard hostPanel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: LiveTranslationSessionHost(bridge: self))
        panel.orderFrontRegardless()
        hostPanel = panel
    }
}

/// The invisible view that owns the macOS 15 translation session.
struct LiveTranslationSessionHost: View {
    @ObservedObject var bridge: LiveTranslationSessionBridge

    var body: some View {
        #if canImport(Translation)
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.serve(session)
            }
        #else
        Color.clear.frame(width: 1, height: 1)
        #endif
    }
}

// MARK: - On-device language model

/// Short-caption translation with the on-device Apple Intelligence model,
/// used when Apple Translation can't do the pair yet. One fresh session per
/// caption (sessions keep history), with the next one prewarmed.
enum LiveTranslationModelEngine {
    static var isAvailable: Bool { MeetingAIBackend.onDeviceAvailable }

    /// Longest text sent in one request; longer captions are split by sentence.
    static let maxChars = 360

    static func instructions(source: String, target: String) -> String {
        let s = LiveTranslationLanguages.displayName(source, locale: Locale(identifier: "en"))
        let t = LiveTranslationLanguages.displayName(target, locale: Locale(identifier: "en"))
        return """
        You translate live meeting captions from \(s) into \(t). \
        Reply with only the \(t) translation of the user's text: no quotes, no notes, no explanations. \
        Keep names, numbers and technical terms. If the text is a fragment, translate the fragment.
        """
    }

    #if canImport(FoundationModels)
    private final class Prepared: @unchecked Sendable {
        let key: String
        let session: AnyObject
        init(key: String, session: AnyObject) { self.key = key; self.session = session }
    }

    private static let prepared = Mutex<Prepared?>(nil)
    #endif

    /// Loads the model and processes the instructions for `source → target`.
    static func prewarm(source: String, target: String) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return }
        let text = instructions(source: source, target: target)
        let session = LanguageModelSession(model: model, instructions: text)
        session.prewarm()
        let box = Prepared(key: text, session: session)
        prepared.withLock { $0 = box }
        #endif
    }

    /// Drops the prewarmed session (meeting over, feature off, quit).
    static func releasePrewarmed() {
        #if canImport(FoundationModels)
        prepared.withLock { $0 = nil }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static var model: SystemLanguageModel {
        // Translating the user's meeting is a content transformation.
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    @available(macOS 26.0, *)
    private static func takeSession(instructions text: String) -> LanguageModelSession {
        let box: Prepared? = prepared.withLock { slot in
            guard let current = slot, current.key == text else { return nil }
            slot = nil
            return current
        }
        if let session = box?.session as? LanguageModelSession { return session }
        return LanguageModelSession(model: model, instructions: text)
    }
    #endif

    static func translate(_ text: String, source: String, target: String, timeout: Double = 8) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw MeetingAIError.unavailable("needs macOS 26") }
        if let reason = MeetingAIBackend.onDeviceUnavailableReason { throw MeetingAIError.unavailable(reason) }
        let pieces = LiveTranslationText.pieces(text, maxChars: maxChars)
        var out: [String] = []
        for piece in pieces {
            out.append(try await translatePiece(piece, source: source, target: target, timeout: timeout))
        }
        let joined = out.joined(separator: " ")
        // Ready for the next caption.
        prewarm(source: source, target: target)
        return joined
        #else
        throw MeetingAIError.unavailable("needs macOS 26")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func translatePiece(_ piece: String, source: String, target: String, timeout: Double) async throws -> String {
        let text = instructions(source: source, target: target)
        let maxTokens = min(600, max(48, piece.count))
        let raw = try await MeetingAITimeout.run(seconds: timeout) {
            let session = takeSession(instructions: text)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
            do {
                return try await session.respond(to: piece, options: options).content
            } catch {
                throw MeetingAIBackend.classifyOnDeviceError(error)
            }
        }
        let cleaned = LiveTranslationText.cleanModelOutput(raw)
        guard !cleaned.isEmpty else { throw LiveTranslationError.emptyResult }
        return cleaned
    }
    #endif
}

// MARK: - Groq

enum LiveTranslationGroqEngine {
    /// Fast production model on Groq; translation needs little reasoning.
    static let model = "openai/gpt-oss-20b"

    static func translate(_ text: String, source: String, target: String, key: String, timeout: Double = 5) async throws -> String {
        let config = MeetingAIConfig(useGroq: true, groqKey: key, groqModel: model)
        let raw = try await MeetingAIBackend.groq(
            config: config,
            system: LiveTranslationModelEngine.instructions(source: source, target: target),
            user: text,
            json: false,
            maxTokens: min(1200, max(96, text.count * 2)),
            reasoningEffort: "low",
            timeout: timeout
        )
        let cleaned = LiveTranslationText.cleanModelOutput(raw)
        guard !cleaned.isEmpty else { throw LiveTranslationError.emptyResult }
        return cleaned
    }
}

// MARK: - Text helpers

enum LiveTranslationText {
    /// Splits long text at sentence ends into pieces of at most `maxChars`.
    static func pieces(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed.isEmpty ? [] : [trimmed] }
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let sub, !sub.trimmingCharacters(in: .whitespaces).isEmpty {
                sentences.append(sub.trimmingCharacters(in: .whitespaces))
            }
        }
        var out: [String] = []
        var current = ""
        for sentence in sentences {
            var sentence = sentence
            // One sentence longer than the limit: cut at word boundaries.
            while sentence.count > maxChars {
                let head = String(sentence.prefix(maxChars))
                let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
                if !current.isEmpty { out.append(current); current = "" }
                out.append(cut)
                sentence = String(sentence.dropFirst(cut.count)).trimmingCharacters(in: .whitespaces)
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= maxChars {
                current += " " + sentence
            } else {
                out.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Removes what language models add around a translation: surrounding
    /// quotes, a "Translation:" label, trailing notes in parentheses.
    static func cleanModelOutput(_ raw: String) -> String {
        var text = MeetingAIJSON.stripReasoning(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstBlank = text.range(of: "\n\n") {
            // A blank line usually starts a note about the translation.
            let rest = text[firstBlank.upperBound...].lowercased()
            if rest.hasPrefix("note") || rest.hasPrefix("(") || rest.hasPrefix("*") {
                text = String(text[..<firstBlank.lowerBound])
            }
        }
        let labels = ["translation:", "translated text:", "here is the translation:", "here's the translation:"]
        for label in labels where text.lowercased().hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("「", "」"), ("'", "'")]
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
