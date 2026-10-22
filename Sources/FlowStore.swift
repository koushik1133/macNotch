import AppKit
import Foundation

/// One finished dictation: what was heard, what was typed, and where.
struct FlowEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    /// Transcript as recognized, before cleanup.
    let raw: String
    /// Formatted text that was typed (or copied).
    let text: String
    /// Frontmost app when the dictation began, nil when unknown.
    let appName: String?

    init(id: UUID = UUID(), date: Date = Date(), raw: String, text: String, appName: String?) {
        self.id = id
        self.date = date
        self.raw = raw
        self.text = text
        self.appName = appName
    }
}

/// A Scratchpad note, typed or dictated in the Flow panel.
struct FlowNote: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    /// Last change.
    var date: Date

    init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }
}

/// A Dictionary word: a name or term spelled the way the user wants it.
/// `heardAs` lists what the recognizer tends to write instead ("spark v").
struct FlowWord: Identifiable, Codable, Equatable {
    let id: UUID
    var term: String
    var heardAs: [String]
    var date: Date

    init(id: UUID = UUID(), term: String, heardAs: [String] = [], date: Date = Date()) {
        self.id = id
        self.term = term
        self.heardAs = heardAs
        self.date = date
    }
}

/// A Snippet: saying `trigger` types `expansion` instead.
struct FlowSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var trigger: String
    var expansion: String
    var date: Date

    init(id: UUID = UUID(), trigger: String, expansion: String, date: Date = Date()) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.date = date
    }
}

/// Dictionary and snippets as the formatter needs them (empty entries dropped).
struct FlowVocabulary: Sendable {
    var words: [(term: String, heardAs: [String])] = []
    var snippets: [(trigger: String, expansion: String)] = []

    static let empty = FlowVocabulary()

    /// Terms the recognizer should expect (contextual strings).
    var recognitionHints: [String] { Array(words.map(\.term).prefix(100)) }
}

/// Dictation history, notes, dictionary and snippets behind the Flow panel,
/// Wispr Flow-style.
///
/// Stored as JSON in ~/Library/Application Support/SparkV/Flow/
/// (`history.json`, `notes.json`, `dictionary.json`, `snippets.json`).
/// History keeps the newest `historyLimit` dictations, newest first; the
/// rest are unlimited, newest first. Writes are coalesced and done off the
/// main thread, and flushed when the app quits.
@MainActor
final class FlowStore: ObservableObject {
    static let shared = FlowStore()
    static let historyLimit = 200

    @Published private(set) var history: [FlowEntry] = []
    @Published private(set) var notes: [FlowNote] = []
    @Published private(set) var words: [FlowWord] = []
    @Published private(set) var snippets: [FlowSnippet] = []

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Flow", isDirectory: true)
    }

    private enum File: CaseIterable {
        case history
        case notes
        case words
        case snippets

        var name: String {
            switch self {
            case .history: "history.json"
            case .notes: "notes.json"
            case .words: "dictionary.json"
            case .snippets: "snippets.json"
            }
        }
    }

    private let directory: URL
    private var saveTasks: [File: Task<Void, Never>] = [:]
    private var terminationObserver: NSObjectProtocol?
    /// Serial, so an older snapshot never lands after a newer one.
    private static let ioQueue = DispatchQueue(label: "SparkV.FlowStore", qos: .utility)
    private static let saveDelay: UInt64 = 400_000_000

    init(directory: URL = FlowStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = Array((load([FlowEntry].self, from: .history) ?? []).prefix(Self.historyLimit))
        notes = load([FlowNote].self, from: .notes) ?? []
        words = load([FlowWord].self, from: .words) ?? []
        snippets = load([FlowSnippet].self, from: .snippets) ?? []
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    // MARK: - History

    /// Adds a finished dictation at the top of the history.
    func record(raw: String, text: String, appName: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let entry = FlowEntry(raw: raw.trimmingCharacters(in: .whitespacesAndNewlines), text: text, appName: appName)
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        scheduleSave(.history)
        SpaceIngestCenter.flow(entry)
    }

    /// Copies the formatted text.
    func copy(_ e: FlowEntry) {
        TextInserter.copy(e.text)
    }

    /// Copies the transcript as recognized, before cleanup.
    func copyRaw(_ e: FlowEntry) {
        TextInserter.copy(e.raw.isEmpty ? e.text : e.raw)
    }

    /// Types the formatted text into the focused app again.
    func paste(_ e: FlowEntry) {
        Task {
            if case .failed(let message) = await TextInserter.insert(e.text) {
                AppLog.log("Flow: paste failed: \(message)")
            }
        }
    }

    func deleteEntry(_ e: FlowEntry) {
        history.removeAll { $0.id == e.id }
        scheduleSave(.history)
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        AppLog.log("Flow: history cleared")
        scheduleSave(.history)
    }

    // MARK: - Notes

    /// Adds a note at the top and returns it (an empty text starts a blank note).
    @discardableResult
    func addNote(_ text: String) -> FlowNote {
        let note = FlowNote(text: text)
        notes.insert(note, at: 0)
        scheduleSave(.notes)
        // A dictated note arrives finished; a blank one is filed once typed into.
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scheduleSpacesFiling(note) }
        return note
    }

    /// Replaces the stored note with the same id (keeps its position).
    func updateNote(_ n: FlowNote) {
        guard let index = notes.firstIndex(where: { $0.id == n.id }), notes[index] != n else { return }
        notes[index] = n
        scheduleSave(.notes)
        scheduleSpacesFiling(n)
    }

    /// Files a note in Spaces once typing pauses, not on every keystroke.
    private var spacesFilingTasks: [UUID: Task<Void, Never>] = [:]

    private func scheduleSpacesFiling(_ note: FlowNote) {
        spacesFilingTasks[note.id]?.cancel()
        spacesFilingTasks[note.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self,
                  let latest = self.notes.first(where: { $0.id == note.id }) else { return }
            self.spacesFilingTasks[note.id] = nil
            SpaceIngestCenter.flow(latest)
        }
    }

    func deleteNote(_ n: FlowNote) {
        spacesFilingTasks[n.id]?.cancel()
        spacesFilingTasks[n.id] = nil
        notes.removeAll { $0.id == n.id }
        scheduleSave(.notes)
    }

    // MARK: - Dictionary and snippets

    /// What the formatter applies to every dictation and note.
    var vocabulary: FlowVocabulary {
        var result = FlowVocabulary()
        result.words = words.compactMap { word in
            let term = word.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let heard = word.heardAs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return (term, heard)
        }
        result.snippets = snippets.compactMap { snippet in
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !snippet.expansion.isEmpty else { return nil }
            return (trigger, snippet.expansion)
        }
        return result
    }

    @discardableResult
    func addWord(_ term: String = "", heardAs: [String] = []) -> FlowWord {
        let word = FlowWord(term: term, heardAs: heardAs)
        words.insert(word, at: 0)
        scheduleSave(.words)
        return word
    }

    func updateWord(_ w: FlowWord) {
        guard let index = words.firstIndex(where: { $0.id == w.id }), words[index] != w else { return }
        words[index] = w
        scheduleSave(.words)
    }

    func deleteWord(_ w: FlowWord) {
        words.removeAll { $0.id == w.id }
        scheduleSave(.words)
    }

    @discardableResult
    func addSnippet(trigger: String = "", expansion: String = "") -> FlowSnippet {
        let snippet = FlowSnippet(trigger: trigger, expansion: expansion)
        snippets.insert(snippet, at: 0)
        scheduleSave(.snippets)
        return snippet
    }

    func updateSnippet(_ s: FlowSnippet) {
        guard let index = snippets.firstIndex(where: { $0.id == s.id }), snippets[index] != s else { return }
        snippets[index] = s
        scheduleSave(.snippets)
    }

    func deleteSnippet(_ s: FlowSnippet) {
        snippets.removeAll { $0.id == s.id }
        scheduleSave(.snippets)
    }

    // MARK: - Persistence

    /// Writes pending changes now (called at quit).
    func flush() {
        let pending = saveTasks.keys
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
        for file in pending {
            guard let (data, url) = snapshot(file) else { continue }
            Self.ioQueue.sync { Self.write(data, to: url) }
        }
    }

    private func scheduleSave(_ file: File) {
        saveTasks[file]?.cancel()
        saveTasks[file] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard let self, !Task.isCancelled else { return }
            self.saveTasks[file] = nil
            guard let (data, url) = self.snapshot(file) else { return }
            Self.ioQueue.async { Self.write(data, to: url) }
        }
    }

    private func snapshot(_ file: File) -> (Data, URL)? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data?
        switch file {
        case .history: data = try? encoder.encode(history)
        case .notes: data = try? encoder.encode(notes)
        case .words: data = try? encoder.encode(words)
        case .snippets: data = try? encoder.encode(snippets)
        }
        guard let data else {
            AppLog.log("Flow: could not encode \(file.name)")
            return nil
        }
        return (data, directory.appendingPathComponent(file.name))
    }

    nonisolated private static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            AppLog.log("Flow: save failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from file: File) -> T? {
        let url = directory.appendingPathComponent(file.name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            // Keep the unreadable file for inspection instead of overwriting it.
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            AppLog.log("Flow: \(file.name) unreadable (\(error)); moved aside")
            return nil
        }
    }
}
