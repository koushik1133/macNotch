import Foundation
import SQLite3

// SQLite persistence for Spaces (owned by spaces-core), via the system
// sqlite3 library. One connection, used only on a private serial queue:
// writes are enqueued in order (fire-and-forget), reads either block briefly
// (`sync`, used at launch and for persona switches) or suspend (`read`).
//
// Tables: meta, personas, spaces, items (+ items_fts, an FTS5 index over
// title/text/entities/tags), embeddings (Float32 blobs), suggestions,
// dismissed (suggestions the user turned down) and space_memory (each Space
// agent's running summary).

final class SpaceDatabase: @unchecked Sendable {
    enum Value: Sendable {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)

        var string: String? { if case .text(let s) = self { return s }; return nil }
        var double: Double? {
            switch self {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }
        var int: Int? {
            switch self {
            case .int(let i): return Int(i)
            case .double(let d): return Int(d)
            default: return nil
            }
        }
        var data: Data? { if case .blob(let d) = self { return d }; return nil }
        var uuid: UUID? { string.flatMap(UUID.init(uuidString:)) }
    }

    struct DBError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The single connection. Only touched on `queue`.
    final class Connection: @unchecked Sendable {
        fileprivate let db: OpaquePointer

        fileprivate init(db: OpaquePointer) { self.db = db }

        private static var transient: sqlite3_destructor_type {
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        }

        private var lastError: String { String(cString: sqlite3_errmsg(db)) }

        func exec(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
                let text = message.map { String(cString: $0) } ?? lastError
                sqlite3_free(message)
                throw DBError(message: text)
            }
        }

        private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DBError(message: "prepare: \(lastError) — \(sql.prefix(80))")
            }
            for (offset, value) in args.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .null: rc = sqlite3_bind_null(stmt, index)
                case .int(let i): rc = sqlite3_bind_int64(stmt, index, i)
                case .double(let d): rc = sqlite3_bind_double(stmt, index, d)
                case .text(let s): rc = sqlite3_bind_text(stmt, index, s, -1, Self.transient)
                case .blob(let data):
                    rc = data.withUnsafeBytes { raw in
                        sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), Self.transient)
                    }
                }
                if rc != SQLITE_OK {
                    sqlite3_finalize(stmt)
                    throw DBError(message: "bind: \(lastError)")
                }
            }
            return stmt
        }

        @discardableResult
        func run(_ sql: String, _ args: [Value] = []) throws -> Int {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
            guard rc == SQLITE_DONE else { throw DBError(message: "step: \(lastError) — \(sql.prefix(80))") }
            return Int(sqlite3_changes(db))
        }

        func query(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            var rows: [[Value]] = []
            let columns = sqlite3_column_count(stmt)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DBError(message: "step: \(lastError)") }
                var row: [Value] = []
                row.reserveCapacity(Int(columns))
                for c in 0..<columns {
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                    case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                    case SQLITE_TEXT:
                        row.append(.text(sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(stmt, c))
                        if let bytes = sqlite3_column_blob(stmt, c), count > 0 {
                            row.append(.blob(Data(bytes: bytes, count: count)))
                        } else {
                            row.append(.blob(Data()))
                        }
                    default: row.append(.null)
                    }
                }
                rows.append(row)
            }
            return rows
        }

        func transaction<T>(_ body: () throws -> T) throws -> T {
            try exec("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try exec("COMMIT")
                return result
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    let url: URL
    private let queue = DispatchQueue(label: "SparkV.SpaceDatabase", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let connection: Connection

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            throw DBError(message: message)
        }
        sqlite3_busy_timeout(handle, 3000)
        connection = Connection(db: handle)
        queue.setSpecific(key: queueKey, value: 1)
        try connection.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF;")
        try Self.migrate(connection)
    }

    deinit {
        let db = connection.db
        queue.sync { _ = sqlite3_close_v2(db) }
    }

    /// Runs `work` on the database queue and waits for it.
    func sync<T>(_ work: (Connection) throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work(connection) }
        return try queue.sync { try work(connection) }
    }

    /// Enqueues a write; runs after every write enqueued before it.
    func enqueue(_ label: String, _ work: @escaping @Sendable (Connection) throws -> Void) {
        let connection = connection
        queue.async {
            do { try work(connection) } catch { AppLog.log("Spaces DB: \(label) failed — \(error.localizedDescription)") }
        }
    }

    /// Runs `work` after all pending writes, without blocking the caller.
    func read<T: Sendable>(_ work: @escaping @Sendable (Connection) throws -> T) async throws -> T {
        let connection = connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async { continuation.resume(with: Result { try work(connection) }) }
        }
    }

    /// Waits until every enqueued write has run.
    func flush() { queue.sync {} }

    // MARK: - Schema

    static let schemaVersion = 1

    private static func migrate(_ c: Connection) throws {
        let version = try c.query("PRAGMA user_version").first?.first?.int ?? 0
        guard version < schemaVersion else { return }
        try c.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS personas(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, icon TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS spaces(
            id TEXT PRIMARY KEY, persona_id TEXT NOT NULL, parent_id TEXT, name TEXT NOT NULL,
            json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS spaces_persona ON spaces(persona_id);
        CREATE TABLE IF NOT EXISTS items(
            id TEXT PRIMARY KEY, persona_id TEXT NOT NULL, space_id TEXT, kind TEXT NOT NULL,
            source TEXT NOT NULL, source_key TEXT NOT NULL, created_at REAL NOT NULL,
            json TEXT NOT NULL, typed_entities TEXT);
        CREATE INDEX IF NOT EXISTS items_persona ON items(persona_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS items_source ON items(persona_id, source_key);
        CREATE INDEX IF NOT EXISTS items_space ON items(space_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            item_id UNINDEXED, persona_id UNINDEXED, title, text, entities, tags,
            tokenize = 'porter unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS embeddings(
            item_id TEXT PRIMARY KEY, model TEXT NOT NULL, dim INTEGER NOT NULL, vector BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS suggestions(
            id TEXT PRIMARY KEY, persona_id TEXT NOT NULL, kind TEXT NOT NULL, json TEXT NOT NULL,
            created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS suggestions_persona ON suggestions(persona_id);
        CREATE TABLE IF NOT EXISTS dismissed(
            persona_id TEXT NOT NULL, key TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(persona_id, key));
        CREATE TABLE IF NOT EXISTS space_memory(
            space_id TEXT PRIMARY KEY, summary TEXT NOT NULL, item_count INTEGER NOT NULL,
            produced_by TEXT NOT NULL, updated_at REAL NOT NULL);
        PRAGMA user_version = \(schemaVersion);
        """)
    }

    // MARK: - Coding

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data, dimension: Int) -> [Float] {
        guard dimension > 0, data.count == dimension * MemoryLayout<Float>.size else { return [] }
        // Copy rather than bind: a Data slice's bytes needn't be Float-aligned.
        var out = [Float](repeating: 0, count: dimension)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    /// FTS5 MATCH expression: each term as a quoted prefix, OR-ed so BM25
    /// ranks items matching more terms first. nil when nothing searchable.
    static func ftsQuery(_ text: String) -> String? {
        var tokens: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let token = String(raw)
            guard token.count >= 2 || token.allSatisfy(\.isNumber) else { continue }
            if SpaceIntelligence.stopwords.contains(token), text.split(separator: " ").count > 1 { continue }
            if !tokens.contains(token) { tokens.append(token) }
            if tokens.count >= 12 { break }
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}

// MARK: - Records

/// A suggestion as stored (SpaceSuggestion itself isn't Codable).
struct SpaceStoredSuggestion: Codable, Sendable {
    var id: UUID
    var kind: String
    var itemID: UUID?
    var spaceID: UUID?
    var confidence: Double?
    var reason: String
    var name: String?
    var itemIDs: [UUID]?

    init(_ suggestion: SpaceSuggestion) {
        id = suggestion.id
        switch suggestion.action {
        case .file(let itemID, let spaceID, let confidence, let reason):
            kind = "file"
            self.itemID = itemID
            self.spaceID = spaceID
            self.confidence = confidence
            self.reason = reason
        case .createSpace(let name, let itemIDs, let reason):
            kind = "createSpace"
            self.name = name
            self.itemIDs = itemIDs
            self.reason = reason
        }
    }

    var suggestion: SpaceSuggestion? {
        switch kind {
        case "file":
            guard let itemID, let spaceID else { return nil }
            return SpaceSuggestion(id: id, action: .file(itemID: itemID, spaceID: spaceID, confidence: confidence ?? 0, reason: reason))
        case "createSpace":
            guard let name, let itemIDs else { return nil }
            return SpaceSuggestion(id: id, action: .createSpace(name: name, itemIDs: itemIDs, reason: reason))
        default:
            return nil
        }
    }
}

/// A Space agent's running summary.
struct SpaceMemoryRecord: Codable, Sendable, Equatable {
    var spaceID: UUID
    var summary: String
    /// Items in the Space (incl. subfolders) when the summary was made.
    var itemCount: Int
    var producedBy: String
    var updatedAt: Date
}

/// Everything loaded for one persona.
struct SpacePersonaSnapshot: Sendable {
    var spaces: [Space] = []
    var items: [SpaceItem] = []
    var typedEntities: [UUID: [SpaceIntelligence.Entity]] = [:]
    var vectors: [UUID: [Float]] = [:]
    var suggestions: [SpaceSuggestion] = []
    var dismissed: Set<String> = []
    var memories: [UUID: SpaceMemoryRecord] = [:]
}

// MARK: - Operations

extension SpaceDatabase.Connection {
    typealias Value = SpaceDatabase.Value

    // Meta

    func meta(_ key: String) throws -> String? {
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.first?.string
    }

    func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)])
    }

    // Personas

    func personas() throws -> [Persona] {
        try query("SELECT id, name, icon, created_at FROM personas ORDER BY created_at").compactMap { row in
            guard let id = row[0].uuid else { return nil }
            return Persona(id: id, name: row[1].string ?? "", icon: row[2].string ?? "",
                           createdAt: Date(timeIntervalSince1970: row[3].double ?? 0))
        }
    }

    func upsertPersona(_ p: Persona) throws {
        try run("""
            INSERT INTO personas(id, name, icon, created_at) VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, icon = excluded.icon
            """, [.text(p.id.uuidString), .text(p.name), .text(p.icon), .double(p.createdAt.timeIntervalSince1970)])
    }

    /// Deletes a persona and everything it owns; returns the deleted item ids.
    @discardableResult
    func deletePersona(_ id: UUID) throws -> [UUID] {
        try transaction {
            let pid = Value.text(id.uuidString)
            let itemIDs = try query("SELECT id FROM items WHERE persona_id = ?", [pid]).compactMap { $0[0].uuid }
            let spaceIDs = try query("SELECT id FROM spaces WHERE persona_id = ?", [pid]).compactMap { $0[0].uuid }
            try run("DELETE FROM embeddings WHERE item_id IN (SELECT id FROM items WHERE persona_id = ?)", [pid])
            try run("DELETE FROM items_fts WHERE persona_id = ?", [pid])
            try run("DELETE FROM items WHERE persona_id = ?", [pid])
            for spaceID in spaceIDs { try run("DELETE FROM space_memory WHERE space_id = ?", [.text(spaceID.uuidString)]) }
            try run("DELETE FROM spaces WHERE persona_id = ?", [pid])
            try run("DELETE FROM suggestions WHERE persona_id = ?", [pid])
            try run("DELETE FROM dismissed WHERE persona_id = ?", [pid])
            try run("DELETE FROM personas WHERE id = ?", [pid])
            return itemIDs
        }
    }

    // Spaces

    func upsertSpace(_ s: Space) throws {
        try run("""
            INSERT INTO spaces(id, persona_id, parent_id, name, json, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET persona_id = excluded.persona_id, parent_id = excluded.parent_id,
                name = excluded.name, json = excluded.json, updated_at = excluded.updated_at
            """, [
                .text(s.id.uuidString), .text(s.personaID.uuidString), s.parentID.map { .text($0.uuidString) } ?? .null,
                .text(s.name), .text(try SpaceDatabase.encode(s)), .double(s.createdAt.timeIntervalSince1970),
                .double(s.updatedAt.timeIntervalSince1970),
            ])
    }

    func deleteSpaces(_ ids: [UUID]) throws {
        try transaction {
            for id in ids {
                try run("DELETE FROM spaces WHERE id = ?", [.text(id.uuidString)])
                try run("DELETE FROM space_memory WHERE space_id = ?", [.text(id.uuidString)])
            }
        }
    }

    // Items

    func upsertItem(_ item: SpaceItem, typed: [SpaceIntelligence.Entity]) throws {
        try transaction { try upsertItemNoTransaction(item, typed: typed) }
    }

    func upsertItems(_ items: [(SpaceItem, [SpaceIntelligence.Entity])]) throws {
        try transaction { for (item, typed) in items { try upsertItemNoTransaction(item, typed: typed) } }
    }

    private func upsertItemNoTransaction(_ item: SpaceItem, typed: [SpaceIntelligence.Entity]) throws {
        let id = Value.text(item.id.uuidString)
        try run("""
            INSERT INTO items(id, persona_id, space_id, kind, source, source_key, created_at, json, typed_entities)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET persona_id = excluded.persona_id, space_id = excluded.space_id,
                kind = excluded.kind, source = excluded.source, source_key = excluded.source_key,
                created_at = excluded.created_at, json = excluded.json, typed_entities = excluded.typed_entities
            """, [
                id, .text(item.personaID.uuidString), item.spaceID.map { .text($0.uuidString) } ?? .null,
                .text(item.kind.rawValue), .text(item.source.rawValue), .text(item.sourceKey),
                .double(item.createdAt.timeIntervalSince1970), .text(try SpaceDatabase.encode(item)),
                .text(try SpaceDatabase.encode(typed)),
            ])
        try run("DELETE FROM items_fts WHERE item_id = ?", [id])
        let body = item.text.count > 100_000 ? String(item.text.prefix(100_000)) : item.text
        try run("INSERT INTO items_fts(item_id, persona_id, title, text, entities, tags) VALUES(?, ?, ?, ?, ?, ?)", [
            id, .text(item.personaID.uuidString), .text(item.title), .text(body),
            .text(item.entities.joined(separator: " · ")), .text(item.tags.joined(separator: " ")),
        ])
    }

    /// Updates only the filing columns (cheap; no FTS rewrite needed).
    func updateFiling(_ item: SpaceItem) throws {
        try run("UPDATE items SET space_id = ?, json = ? WHERE id = ?", [
            item.spaceID.map { .text($0.uuidString) } ?? .null, .text(try SpaceDatabase.encode(item)),
            .text(item.id.uuidString),
        ])
    }

    func deleteItems(_ ids: [UUID]) throws {
        try transaction {
            for id in ids {
                let v = Value.text(id.uuidString)
                try run("DELETE FROM items WHERE id = ?", [v])
                try run("DELETE FROM items_fts WHERE item_id = ?", [v])
                try run("DELETE FROM embeddings WHERE item_id = ?", [v])
            }
        }
    }

    func setEmbedding(_ id: UUID, model: String, vector: [Float]) throws {
        try run("""
            INSERT INTO embeddings(item_id, model, dim, vector) VALUES(?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET model = excluded.model, dim = excluded.dim, vector = excluded.vector
            """, [.text(id.uuidString), .text(model), .int(Int64(vector.count)), .blob(SpaceDatabase.blob(vector))])
    }

    /// Ranked (item id, bm25) for the persona; lower bm25 = better.
    func searchFTS(_ match: String, personaID: UUID, limit: Int) throws -> [(UUID, Double)] {
        try query("""
            SELECT item_id, bm25(items_fts, 0.0, 0.0, 6.0, 1.0, 3.0, 3.0) AS rank FROM items_fts
            WHERE items_fts MATCH ? AND persona_id = ? ORDER BY rank LIMIT ?
            """, [.text(match), .text(personaID.uuidString), .int(Int64(limit))]).compactMap { row in
            guard let id = row[0].uuid else { return nil }
            return (id, row[1].double ?? 0)
        }
    }

    // Suggestions

    func replaceSuggestions(_ suggestions: [SpaceSuggestion], personaID: UUID) throws {
        try transaction {
            try run("DELETE FROM suggestions WHERE persona_id = ?", [.text(personaID.uuidString)])
            let now = Date().timeIntervalSince1970
            for (offset, suggestion) in suggestions.enumerated() {
                let stored = SpaceStoredSuggestion(suggestion)
                try run("INSERT INTO suggestions(id, persona_id, kind, json, created_at) VALUES(?, ?, ?, ?, ?)", [
                    .text(stored.id.uuidString), .text(personaID.uuidString), .text(stored.kind),
                    .text(try SpaceDatabase.encode(stored)), .double(now + Double(offset) * 0.001),
                ])
            }
        }
    }

    func addDismissed(_ key: String, personaID: UUID) throws {
        try run("INSERT OR IGNORE INTO dismissed(persona_id, key, created_at) VALUES(?, ?, ?)",
                [.text(personaID.uuidString), .text(key), .double(Date().timeIntervalSince1970)])
    }

    // Memory

    func upsertMemory(_ m: SpaceMemoryRecord) throws {
        try run("""
            INSERT INTO space_memory(space_id, summary, item_count, produced_by, updated_at) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(space_id) DO UPDATE SET summary = excluded.summary, item_count = excluded.item_count,
                produced_by = excluded.produced_by, updated_at = excluded.updated_at
            """, [.text(m.spaceID.uuidString), .text(m.summary), .int(Int64(m.itemCount)), .text(m.producedBy),
                  .double(m.updatedAt.timeIntervalSince1970)])
    }

    // Loading

    func loadPersona(_ personaID: UUID, embeddingModel: String) throws -> SpacePersonaSnapshot {
        var snap = SpacePersonaSnapshot()
        let pid = Value.text(personaID.uuidString)
        snap.spaces = try query("SELECT json FROM spaces WHERE persona_id = ? ORDER BY created_at", [pid])
            .compactMap { SpaceDatabase.decode(Space.self, $0[0].string) }
        for row in try query("SELECT json, typed_entities FROM items WHERE persona_id = ? ORDER BY created_at DESC", [pid]) {
            guard let item = SpaceDatabase.decode(SpaceItem.self, row[0].string) else { continue }
            snap.items.append(item)
            snap.typedEntities[item.id] = SpaceDatabase.decode([SpaceIntelligence.Entity].self, row[1].string) ?? []
        }
        for row in try query("""
            SELECT e.item_id, e.dim, e.vector FROM embeddings e JOIN items i ON i.id = e.item_id
            WHERE i.persona_id = ? AND e.model = ?
            """, [pid, .text(embeddingModel)]) {
            guard let id = row[0].uuid, let data = row[2].data else { continue }
            let v = SpaceDatabase.vector(data, dimension: row[1].int ?? 0)
            if !v.isEmpty { snap.vectors[id] = v }
        }
        snap.suggestions = try query("SELECT json FROM suggestions WHERE persona_id = ? ORDER BY created_at", [pid])
            .compactMap { SpaceDatabase.decode(SpaceStoredSuggestion.self, $0[0].string)?.suggestion }
        snap.dismissed = Set(try query("SELECT key FROM dismissed WHERE persona_id = ?", [pid]).compactMap { $0[0].string })
        let spaceIDs = Set(snap.spaces.map(\.id))
        for row in try query("SELECT space_id, summary, item_count, produced_by, updated_at FROM space_memory") {
            guard let id = row[0].uuid, spaceIDs.contains(id) else { continue }
            snap.memories[id] = SpaceMemoryRecord(
                spaceID: id, summary: row[1].string ?? "", itemCount: row[2].int ?? 0,
                producedBy: row[3].string ?? "", updatedAt: Date(timeIntervalSince1970: row[4].double ?? 0)
            )
        }
        return snap
    }
}
