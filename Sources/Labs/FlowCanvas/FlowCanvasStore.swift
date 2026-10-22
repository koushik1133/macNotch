import Foundation

// Persistence for Flow Canvas:
//   ~/Library/Application Support/SparkV/FlowCanvas/<id>.json      the canvas
//   ~/Library/Application Support/SparkV/FlowCanvas/<id>-assets/   copies of dropped images, PDFs, files
//   ~/Library/Application Support/SparkV/FlowCanvas/Templates/      user templates
//   ~/Library/Application Support/SparkV/FlowCanvas/Exports/        files made for drag-out / Tray
// Only files inside this folder are ever removed; the user's originals are
// copied, never moved or deleted.

// MARK: - Settings

enum FCSettings {
    /// Flow Canvas's own opt-in for Clicky's Groq key. Off by default; while
    /// off, the keychain is never read and nothing leaves the Mac except
    /// fetches of links the user put on the canvas.
    static let allowsGroqKey = "FlowCanvasAllowsGroq"
    static let textModel = "openai/gpt-oss-120b"
    static let visionModel = "qwen/qwen3.8-27b"

    /// Seam for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static var allowsGroq: Bool {
        get { defaults.bool(forKey: allowsGroqKey) }
        set { defaults.set(newValue, forKey: allowsGroqKey) }
    }
}

// MARK: - Codec

enum FCCodec {
    enum Failure: LocalizedError {
        case newerVersion(Int)
        var errorDescription: String? {
            switch self {
            case .newerVersion(let version):
                "This canvas was saved by a newer SparkV (format \(version)). Update SparkV to open it."
            }
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Seconds since 2001 as a JSON number: exact, so a save/load
        // round-trip compares equal. ISO 8601 strings are accepted on read.
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date: \(string)")
        }
        return decoder
    }

    private struct VersionProbe: Decodable { var version: Int? }

    static func encode(_ document: FCDocument) throws -> Data {
        try encoder().encode(document)
    }

    /// Decodes a canvas, refusing files from a newer format and migrating
    /// older ones (version 1 is the first format, nothing to migrate yet).
    static func decode(_ data: Data) throws -> FCDocument {
        let probe = try decoder().decode(VersionProbe.self, from: data)
        let version = probe.version ?? 1
        guard version <= FCDocument.currentVersion else { throw Failure.newerVersion(version) }
        var document = try decoder().decode(FCDocument.self, from: data)
        document.version = FCDocument.currentVersion
        // Nothing can be mid-run after a relaunch.
        for index in document.nodes.indices where document.nodes[index].status.phase == .loading {
            document.nodes[index].status = document.nodes[index].output == nil && document.nodes[index].kind.isAction
                ? .idle : .failed("Interrupted. Run it again.")
        }
        return document
    }
}

// MARK: - Library

/// The canvases on disk. Main-actor because the sidebar observes it.
@MainActor
final class FCLibrary: ObservableObject {
    static let shared = FCLibrary(root: FCLibrary.defaultRoot)

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/FlowCanvas", isDirectory: true)
    }

    let root: URL
    /// Tests: remove instead of moving to the Trash.
    var usesTrash = true
    @Published private(set) var canvases: [FCCanvasSummary] = []
    @Published private(set) var userTemplates: [FCTemplate] = []

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    // MARK: Paths

    func fileURL(for id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }
    func assetsDirectory(for id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString)-assets", isDirectory: true) }
    func assetURL(_ name: String, in id: UUID) -> URL { assetsDirectory(for: id).appendingPathComponent(name) }
    var templatesDirectory: URL { root.appendingPathComponent("Templates", isDirectory: true) }
    var exportsDirectory: URL { root.appendingPathComponent("Exports", isDirectory: true) }

    // MARK: Listing

    func refresh() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var summaries: [FCCanvasSummary] = []
        for name in names where name.hasSuffix(".json") {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let document = try? FCCodec.decode(data) else { continue }
            summaries.append(FCCanvasSummary(id: document.id, name: document.name, updatedAt: document.updatedAt,
                                             nodeCount: document.nodes.filter { $0.kind != .frame }.count))
        }
        canvases = summaries.sorted { $0.updatedAt > $1.updatedAt }
        userTemplates = loadTemplates()
    }

    // MARK: Canvases

    func load(_ id: UUID) throws -> FCDocument {
        try FCCodec.decode(Data(contentsOf: fileURL(for: id)))
    }

    /// Writes atomically; `touch` bumps `updatedAt`.
    @discardableResult
    func save(_ document: FCDocument, touch: Bool = true) throws -> FCDocument {
        var document = document
        if touch { document.updatedAt = Date() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FCCodec.encode(document).write(to: fileURL(for: document.id), options: .atomic)
        upsertSummary(document)
        return document
    }

    func create(name: String = "Untitled canvas") -> FCDocument {
        let document = FCDocument(name: uniqueName(name))
        _ = try? save(document)
        return document
    }

    func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var document = try load(id)
        document.name = trimmed
        try save(document)
    }

    /// A copy with a new id, its own copy of the assets, and the same cards.
    func duplicate(_ id: UUID) throws -> FCDocument {
        var document = try load(id)
        let oldAssets = assetsDirectory(for: id)
        document.id = UUID()
        document.name = uniqueName(document.name + " copy")
        document.createdAt = Date()
        if FileManager.default.fileExists(atPath: oldAssets.path) {
            try FileManager.default.copyItem(at: oldAssets, to: assetsDirectory(for: document.id))
        }
        return try save(document)
    }

    /// Removes the canvas file and its asset copies (the app's own files,
    /// moved to the Trash so a mistake can be undone in Finder).
    func delete(_ id: UUID) throws {
        for url in [fileURL(for: id), assetsDirectory(for: id)] where FileManager.default.fileExists(atPath: url.path) {
            guard url.path.hasPrefix(root.path) else { continue }
            if usesTrash, (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { continue }
            try FileManager.default.removeItem(at: url)
        }
        canvases.removeAll { $0.id == id }
    }

    // MARK: Assets

    /// Copies a dropped file into the canvas's assets folder (never moves it).
    nonisolated static func copyAsset(_ source: URL, into directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var name = ext.isEmpty ? base : "\(base).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        return name
    }

    /// Saves pasted image data as a PNG asset.
    nonisolated static func writeAsset(_ data: Data, name: String, into directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var file = name
        var counter = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            file = "\(base) \(counter).\(ext)"
            counter += 1
        }
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        return file
    }

    // MARK: Templates

    func saveTemplate(_ template: FCTemplate) throws {
        try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        var template = template
        template.isBuiltIn = false
        try FCCodec.encoder().encode(template).write(to: templatesDirectory.appendingPathComponent("\(template.id).json"), options: .atomic)
        userTemplates = loadTemplates()
    }

    func deleteTemplate(_ id: String) {
        let url = templatesDirectory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            if !usesTrash || (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
        userTemplates = loadTemplates()
    }

    private func loadTemplates() -> [FCTemplate] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: templatesDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: templatesDirectory.appendingPathComponent(name)) else { return nil }
            return try? FCCodec.decoder().decode(FCTemplate.self, from: data)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Helpers

    private func upsertSummary(_ document: FCDocument) {
        let summary = FCCanvasSummary(id: document.id, name: document.name, updatedAt: document.updatedAt,
                                      nodeCount: document.nodes.filter { $0.kind != .frame }.count)
        if let index = canvases.firstIndex(where: { $0.id == document.id }) {
            if canvases[index] != summary { canvases[index] = summary }
        } else {
            canvases.insert(summary, at: 0)
        }
        canvases.sort { $0.updatedAt > $1.updatedAt }
    }

    func uniqueName(_ name: String) -> String {
        let taken = Set(canvases.map(\.name))
        guard taken.contains(name) else { return name }
        var counter = 2
        while taken.contains("\(name) \(counter)") { counter += 1 }
        return "\(name) \(counter)"
    }
}
