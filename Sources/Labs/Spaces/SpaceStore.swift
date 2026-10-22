import AppKit
import Foundation

// Spaces store (owned by spaces-core): personas, Spaces (nested = folders),
// items, the routing agents' suggestions, search, on-device Q&A and each
// Space agent's running memory. API per Sources/Labs/Spaces/CONTRACT.md.
//
// In-memory state for the current persona is the source of truth for the UI
// (@Published, main actor); every change is persisted to SQLite
// (SpaceDatabase) on its private serial queue. Entity extraction, embeddings,
// routing and clustering run off the main actor (SpaceIntelligence).
//
// Storage: ~/Library/Application Support/SparkV/Spaces/spaces.sqlite,
// attachments under Spaces/Attachments/<itemID>/.

struct SpaceAnswer: Sendable {
    var text: String
    var citedItemIDs: [UUID]
    var producedBy: String
}

@MainActor
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore()

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Spaces", isDirectory: true)
    }

    static let onDeviceModelName = "Apple Intelligence (on-device)"
    static let extractiveName = "Extractive (on-device)"

    @Published private(set) var personas: [Persona] = []
    /// Persisted; switching reloads Spaces, items and suggestions.
    @Published var currentPersonaID: UUID {
        didSet {
            guard currentPersonaID != oldValue else { return }
            guard personas.contains(where: { $0.id == currentPersonaID }) else {
                currentPersonaID = oldValue
                return
            }
            let id = currentPersonaID
            database?.enqueue("save persona choice") { try $0.setMeta("currentPersonaID", id.uuidString) }
            loadCurrentPersona()
        }
    }
    /// Current persona only.
    @Published private(set) var spaces: [Space] = []
    /// Current persona only, newest first.
    @Published private(set) var items: [SpaceItem] = []
    @Published private(set) var suggestions: [SpaceSuggestion] = []
    @Published private(set) var isIndexing = false

    /// Folder holding spaces.sqlite and Attachments/.
    let rootDirectory: URL
    let database: SpaceDatabase?

    /// Below this a routing match is not even suggested.
    var suggestionFloor = 0.3
    /// Matches with only semantic resemblance (no rule or shared entity) are
    /// suggested from this confidence up.
    var semanticOnlySuggestionFloor = 0.45
    /// A Space's memory is rewritten after this many new items.
    var memoryRefreshEvery = 5
    /// Delay before a background memory refresh (coalesces bursts).
    var memoryRefreshDelay: Double = 3
    /// Quiet time after the last question before postponed refreshes run.
    var memoryIdleDelay: Double = 20
    /// Default rules threshold for Spaces made from suggestions.
    var defaultAutoFileThreshold = 0.7

    private var typedEntities: [UUID: [SpaceIntelligence.Entity]] = [:]
    private var vectors: [UUID: [Float]] = [:]
    private var embeddingModel = ""
    private var memories: [UUID: SpaceMemoryRecord] = [:]
    private var dismissedKeys: Set<String> = []
    private var aboutVectors: [UUID: (text: String, vector: [Float])] = [:]
    private var profileCache: [SpaceIntelligence.SpaceProfile]?
    private var inFlightKeys: Set<String> = []
    private var memoryTasks: [UUID: Task<Void, Never>] = [:]
    private var rerouteTask: Task<Void, Never>?
    private var reindexTask: Task<Void, Never>?
    /// Questions in flight; background memory refreshes yield the model to them.
    private var activeAsks = 0
    private var postponedMemory: Set<UUID> = []
    private var pendingWork = 0 {
        didSet { if isIndexing != (pendingWork > 0) { isIndexing = pendingWork > 0 } }
    }

    init(directory: URL = SpaceStore.defaultDirectory) {
        rootDirectory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: SpaceDatabase?
        do {
            db = try SpaceDatabase(url: directory.appendingPathComponent("spaces.sqlite"))
        } catch {
            AppLog.log("Spaces: database unavailable (\(error.localizedDescription)); running in memory")
        }
        database = db

        var loaded = (try? db?.sync { try $0.personas() }) ?? []
        if loaded.isEmpty {
            let me = Persona(id: UUID(), name: "Me", icon: "person.crop.circle.fill", createdAt: Date())
            loaded = [me]
            db?.enqueue("create default persona") { try $0.upsertPersona(me) }
        }
        let stored = (try? db?.sync { try $0.meta("currentPersonaID") }).flatMap { $0 }.flatMap(UUID.init(uuidString:))
        let current = loaded.first { $0.id == stored } ?? loaded[0]
        personas = loaded
        currentPersonaID = current.id
        let currentID = current.id
        db?.enqueue("save persona choice") { try $0.setMeta("currentPersonaID", currentID.uuidString) }
        loadCurrentPersona()
    }

    // MARK: - Loading

    private func loadCurrentPersona() {
        for task in memoryTasks.values { task.cancel() }
        memoryTasks = [:]
        rerouteTask?.cancel()
        profileCache = nil
        aboutVectors = [:]
        if embeddingModel.isEmpty { embeddingModel = SpaceIntelligence.embeddingModelID }
        let personaID = currentPersonaID
        let model = embeddingModel
        let snap: SpacePersonaSnapshot
        if let database {
            do {
                snap = try database.sync { try $0.loadPersona(personaID, embeddingModel: model) }
            } catch {
                AppLog.log("Spaces: loading persona failed — \(error.localizedDescription)")
                snap = SpacePersonaSnapshot()
            }
        } else {
            snap = SpacePersonaSnapshot()
        }
        spaces = snap.spaces
        items = snap.items
        typedEntities = snap.typedEntities
        vectors = snap.vectors
        suggestions = snap.suggestions
        dismissedKeys = snap.dismissed
        memories = snap.memories
        scheduleReindexMissing()
    }

    /// Items without a vector in the current embedding model get one in the background.
    private func scheduleReindexMissing() {
        let missing = items.filter { vectors[$0.id] == nil }
        guard !missing.isEmpty else { return }
        reindexTask?.cancel()
        let personaID = currentPersonaID
        reindexTask = Task { [weak self] in
            await self?.reanalyze(missing, personaID: personaID, refreshEntities: false)
        }
    }

    private func reanalyze(_ batch: [SpaceItem], personaID: UUID, refreshEntities: Bool) async {
        pendingWork += 1
        defer { pendingWork -= 1 }
        for item in batch {
            if Task.isCancelled || personaID != currentPersonaID { return }
            let analysis = await Self.analyze(title: item.title, text: item.text, hints: Self.hints(for: item))
            guard personaID == currentPersonaID, let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            vectors[item.id] = analysis.vector
            if refreshEntities || typedEntities[item.id] == nil {
                typedEntities[item.id] = analysis.entities
                items[index].entities = Self.entityStrings(analysis.entities)
                persist(items[index])
            }
            persistVector(item.id, analysis)
        }
        profileCache = nil
    }

    // MARK: - Personas

    @discardableResult
    func createPersona(name: String, icon: String) -> Persona {
        let persona = Persona(id: UUID(), name: Self.clean(name, fallback: "Persona"), icon: icon, createdAt: Date())
        personas.append(persona)
        database?.enqueue("create persona") { try $0.upsertPersona(persona) }
        return persona
    }

    func renamePersona(_ id: UUID, to name: String) {
        guard let index = personas.firstIndex(where: { $0.id == id }) else { return }
        personas[index].name = Self.clean(name, fallback: personas[index].name)
        let persona = personas[index]
        database?.enqueue("rename persona") { try $0.upsertPersona(persona) }
    }

    /// Deletes a persona with its Spaces and items. The last persona can't be deleted.
    func deletePersona(_ id: UUID) {
        guard personas.count > 1, let index = personas.firstIndex(where: { $0.id == id }) else { return }
        personas.remove(at: index)
        let root = rootDirectory
        database?.enqueue("delete persona") { connection in
            let itemIDs = try connection.deletePersona(id)
            for itemID in itemIDs { SpaceStore.removeAttachments(itemID: itemID, root: root) }
        }
        if currentPersonaID == id { currentPersonaID = personas[0].id }
    }

    var currentPersona: Persona? { personas.first { $0.id == currentPersonaID } }

    // MARK: - Spaces

    @discardableResult
    func createSpace(name: String, parentID: UUID?, icon: String, color: String, rules: SpaceAgentRules) -> Space {
        let now = Date()
        let parent = parentID.flatMap { id in spaces.first { $0.id == id }?.id }
        let space = Space(
            id: UUID(), personaID: currentPersonaID, parentID: parent, name: Self.clean(name, fallback: "Untitled"),
            icon: icon.isEmpty ? "folder.fill" : icon, color: color.isEmpty ? Self.color(for: name) : color,
            rules: Self.sanitized(rules), members: [], createdAt: now, updatedAt: now
        )
        spaces.append(space)
        persist(space)
        spacesChanged(rerouteInbox: Self.hasRules(space.rules))
        return space
    }

    func updateSpace(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        let old = spaces[index]
        var updated = space
        updated.personaID = old.personaID
        updated.rules = Self.sanitized(space.rules)
        // A Space can't become its own ancestor.
        if let parentID = updated.parentID, parentID == updated.id || descendantIDs(of: updated.id).contains(parentID)
            || !spaces.contains(where: { $0.id == parentID }) {
            updated.parentID = old.parentID
        }
        updated.updatedAt = Date()
        spaces[index] = updated
        persist(updated)
        spacesChanged(rerouteInbox: old.rules != updated.rules || old.name != updated.name)
    }

    /// Deletes a Space and its subfolders. With `keepItems` their items move
    /// to the deleted Space's parent (the Inbox for a top-level Space).
    func deleteSpace(_ id: UUID, keepItems: Bool) {
        guard let space = spaces.first(where: { $0.id == id }) else { return }
        let doomed = descendantIDs(of: id).union([id])
        let affected = items.filter { $0.spaceID.map(doomed.contains) ?? false }
        if keepItems {
            for item in affected {
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[index].spaceID = space.parentID
                items[index].filingConfidence = nil
                persistFiling(items[index])
            }
        } else {
            removeItems(Set(affected.map(\.id)))
        }
        spaces.removeAll { doomed.contains($0.id) }
        for spaceID in doomed {
            memories[spaceID] = nil
            aboutVectors[spaceID] = nil
            memoryTasks[spaceID]?.cancel()
            memoryTasks[spaceID] = nil
        }
        database?.enqueue("delete spaces") { try $0.deleteSpaces(Array(doomed)) }
        mutateSuggestions { list in
            list.removeAll { s in
                if case .file(_, let spaceID, _, _) = s.action { return doomed.contains(spaceID) }
                return false
            }
        }
        spacesChanged(rerouteInbox: keepItems && space.parentID == nil)
        if let parentID = space.parentID { scheduleMemoryRefresh(parentID) }
    }

    /// Direct children, by name; nil = top level.
    func children(of parentID: UUID?) -> [Space] {
        spaces.filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addMember(_ member: SpaceMember, to spaceID: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        if let existing = spaces[index].members.firstIndex(where: { $0.id == member.id }) {
            spaces[index].members[existing] = member
        } else {
            spaces[index].members.append(member)
        }
        spaces[index].updatedAt = Date()
        persist(spaces[index])
    }

    func removeMember(_ memberID: UUID, from spaceID: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].members.removeAll { $0.id == memberID }
        spaces[index].updatedAt = Date()
        persist(spaces[index])
    }

    func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    /// Root → … → the Space itself (for breadcrumbs).
    func path(of spaceID: UUID) -> [Space] {
        var out: [Space] = []
        var current = spaces.first { $0.id == spaceID }
        var guardCount = 0
        while let s = current, guardCount < 64 {
            out.insert(s, at: 0)
            current = s.parentID.flatMap { pid in spaces.first { $0.id == pid } }
            guardCount += 1
        }
        return out
    }

    /// All subfolders below `spaceID` (not including it).
    func descendantIDs(of spaceID: UUID) -> Set<UUID> {
        var out: Set<UUID> = []
        var frontier = [spaceID]
        while let next = frontier.popLast() {
            for child in spaces where child.parentID == next && !out.contains(child.id) {
                out.insert(child.id)
                frontier.append(child.id)
            }
        }
        return out
    }

    private func spacesChanged(rerouteInbox: Bool) {
        profileCache = nil
        if rerouteInbox { scheduleInboxReroute() }
    }

    // MARK: - Items

    /// Files new knowledge: de-dupes by `sourceKey` (an update of an existing
    /// item keeps its Space), copies the attachment, extracts entities, embeds,
    /// and lets the Space agents route it — auto-filed at or above the Space's
    /// threshold, otherwise left in the Inbox with a `.file` suggestion.
    func ingest(_ input: SpaceIngestInput) async -> SpaceItem? {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !text.isEmpty || input.attachment != nil else { return nil }
        let key = input.sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaID = currentPersonaID
        var hints = input.hints
        if let url = input.url, hints["url"] == nil { hints["url"] = url.absoluteString }

        if !key.isEmpty {
            if inFlightKeys.contains(key) { return nil }
            if let existing = items.first(where: { $0.sourceKey == key }) {
                guard existing.title != title || existing.text != text else { return existing }
                inFlightKeys.insert(key)
                pendingWork += 1
                defer { inFlightKeys.remove(key); pendingWork -= 1 }
                let analysis = await Self.analyze(title: title, text: text, hints: hints)
                guard personaID == currentPersonaID, let index = items.firstIndex(where: { $0.id == existing.id }) else {
                    return nil
                }
                items[index].title = title.isEmpty ? existing.title : title
                items[index].text = text
                if let url = input.url { items[index].url = url }
                items[index].entities = Self.entityStrings(analysis.entities)
                typedEntities[existing.id] = analysis.entities
                vectors[existing.id] = analysis.vector
                persist(items[index])
                persistVector(existing.id, analysis)
                profileCache = nil
                return items[index]
            }
            inFlightKeys.insert(key)
        }
        pendingWork += 1
        defer {
            if !key.isEmpty { inFlightKeys.remove(key) }
            pendingWork -= 1
        }

        let id = UUID()
        let displayTitle = title.isEmpty ? (input.attachment?.lastPathComponent ?? String(text.prefix(60))) : title
        let analysis = await Self.analyze(title: displayTitle, text: text, hints: hints)
        var attachmentPath: String?
        if let attachment = input.attachment {
            let root = rootDirectory
            attachmentPath = await Task.detached(priority: .utility) {
                SpaceStore.copyAttachment(attachment, itemID: id, root: root)
            }.value
        }

        var item = SpaceItem(
            id: id, spaceID: nil, personaID: personaID, kind: input.kind, source: input.source, title: displayTitle,
            text: text, url: input.url, attachmentPath: attachmentPath, entities: Self.entityStrings(analysis.entities),
            tags: [], createdAt: input.createdAt, sourceKey: key.isEmpty ? "item:\(id.uuidString)" : key,
            filingConfidence: nil
        )

        guard personaID == currentPersonaID else {
            // The persona changed while analyzing: file it to the Inbox of the
            // persona it was meant for.
            let typed = analysis.entities
            let model = analysis.model, vector = analysis.vector
            let pending = item
            database?.enqueue("ingest (other persona)") { c in
                try c.upsertItem(pending, typed: typed)
                if !vector.isEmpty { try c.setEmbedding(pending.id, model: model, vector: vector) }
            }
            return pending
        }

        let decision = await route(
            SpaceIntelligence.RoutingItem(
                title: displayTitle, text: text, hints: hints, entities: analysis.entities,
                vector: analysis.vector, model: analysis.model
            )
        )
        guard personaID == currentPersonaID else { return nil }
        if let decision, decision.autoFile, spaces.contains(where: { $0.id == decision.spaceID }) {
            item.spaceID = decision.spaceID
            item.filingConfidence = decision.confidence
        }
        insertSorted(item)
        typedEntities[id] = analysis.entities
        vectors[id] = analysis.vector
        persist(item)
        persistVector(id, analysis)
        profileCache = nil

        if let spaceID = item.spaceID {
            AppLog.log("Spaces: filed “\(displayTitle.prefix(60))” → \(space(spaceID)?.name ?? "?") (\(decision.map { String(format: "%.2f", $0.confidence) } ?? "-"))")
            scheduleMemoryRefresh(spaceID)
        } else if let decision, worthSuggesting(decision) {
            addFileSuggestion(itemID: id, decision: decision)
        }
        return item
    }

    /// Adds an item by hand (filed where asked, or the Inbox when nil).
    @discardableResult
    func addManual(title: String, text: String, url: URL?, spaceID: UUID?, kind: SpaceItemKind) -> SpaceItem {
        let id = UUID()
        let target = spaceID.flatMap { sid in spaces.first { $0.id == sid }?.id }
        let cleanTitle = Self.clean(title, fallback: String(text.prefix(60)).isEmpty ? "Untitled" : String(text.prefix(60)))
        let item = SpaceItem(
            id: id, spaceID: target, personaID: currentPersonaID, kind: kind, source: .manual, title: cleanTitle,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), url: url, attachmentPath: nil, entities: [],
            tags: [], createdAt: Date(), sourceKey: url.map { "manual:\($0.absoluteString)" } ?? "manual:\(id.uuidString)",
            filingConfidence: nil
        )
        insertSorted(item)
        typedEntities[id] = []
        persist(item)
        let personaID = currentPersonaID
        pendingWork += 1
        Task { [weak self] in
            let analysis = await SpaceStore.analyze(title: item.title, text: item.text, hints: SpaceStore.hints(for: item))
            guard let self else { return }
            self.pendingWork -= 1
            guard personaID == self.currentPersonaID, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[index].entities = SpaceStore.entityStrings(analysis.entities)
            self.typedEntities[id] = analysis.entities
            self.vectors[id] = analysis.vector
            self.persist(self.items[index])
            self.persistVector(id, analysis)
            self.profileCache = nil
            if let target { self.scheduleMemoryRefresh(target) } else { await self.suggestFiling(for: id) }
        }
        return item
    }

    /// Files an item by hand (nil = back to the Inbox). The agents learn from it.
    func move(itemID: UUID, to spaceID: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let target = spaceID.flatMap { sid in spaces.first { $0.id == sid }?.id }
        let old = items[index].spaceID
        guard old != target || items[index].filingConfidence != nil else { return }
        items[index].spaceID = target
        items[index].filingConfidence = nil
        persistFiling(items[index])
        removeSuggestions(forItems: [itemID])
        profileCache = nil
        if let target { scheduleMemoryRefresh(target) }
        if let old { scheduleMemoryRefresh(old) }
    }

    func delete(itemID: UUID) {
        let spaceID = items.first { $0.id == itemID }?.spaceID
        removeItems([itemID])
        if let spaceID { scheduleMemoryRefresh(spaceID) }
    }

    /// Edits an item (title, text, tags, url); re-indexes it.
    func updateItem(_ item: SpaceItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let old = items[index]
        var updated = item
        updated.personaID = old.personaID
        updated.attachmentPath = old.attachmentPath
        if let sid = updated.spaceID, !spaces.contains(where: { $0.id == sid }) { updated.spaceID = old.spaceID }
        items[index] = updated
        persist(updated)
        profileCache = nil
        if old.title != updated.title || old.text != updated.text {
            let personaID = currentPersonaID
            Task { [weak self] in await self?.reanalyze([updated], personaID: personaID, refreshEntities: true) }
        }
    }

    /// Inbox when nil (ignores `recursive`); newest first.
    func items(in spaceID: UUID?, recursive: Bool) -> [SpaceItem] {
        guard let spaceID else { return items.filter { $0.spaceID == nil } }
        let scope = recursive ? descendantIDs(of: spaceID).union([spaceID]) : [spaceID]
        return items.filter { $0.spaceID.map(scope.contains) ?? false }
    }

    func item(_ id: UUID) -> SpaceItem? { items.first { $0.id == id } }

    var inboxCount: Int { items.reduce(0) { $0 + ($1.spaceID == nil ? 1 : 0) } }

    /// Where an item's stored attachment is on disk.
    func attachmentURL(for item: SpaceItem) -> URL? {
        guard let path = item.attachmentPath, !path.isEmpty else { return nil }
        let url = rootDirectory.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(rootDirectory.standardizedFileURL.path + "/") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Typed entities (kind + value) found in an item.
    func entities(of itemID: UUID) -> [SpaceIntelligence.Entity] { typedEntities[itemID] ?? [] }

    private func insertSorted(_ item: SpaceItem) {
        let index = items.firstIndex { $0.createdAt < item.createdAt } ?? items.endIndex
        items.insert(item, at: index)
    }

    private func removeItems(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            typedEntities[id] = nil
            vectors[id] = nil
        }
        let root = rootDirectory
        let list = Array(ids)
        database?.enqueue("delete items") { connection in
            try connection.deleteItems(list)
            for id in list { SpaceStore.removeAttachments(itemID: id, root: root) }
        }
        if database == nil {
            Task.detached(priority: .utility) { for id in list { SpaceStore.removeAttachments(itemID: id, root: root) } }
        }
        removeSuggestions(forItems: ids)
        profileCache = nil
    }

    // MARK: - Suggestions

    func accept(_ suggestion: SpaceSuggestion) {
        removeSuggestion(suggestion.id)
        switch suggestion.action {
        case .file(let itemID, let spaceID, let confidence, _):
            guard let index = items.firstIndex(where: { $0.id == itemID }), spaces.contains(where: { $0.id == spaceID })
            else { return }
            items[index].spaceID = spaceID
            items[index].filingConfidence = confidence
            persistFiling(items[index])
            removeSuggestions(forItems: [itemID])
            profileCache = nil
            scheduleMemoryRefresh(spaceID)
        case .createSpace(let name, let itemIDs, _):
            let members = itemIDs.filter { id in items.contains { $0.id == id } }
            let rules = derivedRules(name: name, itemIDs: members)
            let space = createSpace(name: name, parentID: nil, icon: "folder.fill", color: Self.color(for: name), rules: rules)
            for id in members {
                guard let index = items.firstIndex(where: { $0.id == id }), items[index].spaceID == nil else { continue }
                items[index].spaceID = space.id
                items[index].filingConfidence = nil
                persistFiling(items[index])
            }
            removeSuggestions(forItems: Set(members))
            profileCache = nil
            scheduleMemoryRefresh(space.id)
        }
    }

    func dismiss(_ suggestion: SpaceSuggestion) {
        removeSuggestion(suggestion.id)
        let key = Self.dismissKey(suggestion.action)
        dismissedKeys.insert(key)
        let personaID = currentPersonaID
        database?.enqueue("dismiss suggestion") { try $0.addDismissed(key, personaID: personaID) }
    }

    private static func dismissKey(_ action: SpaceSuggestion.Action) -> String {
        switch action {
        case .file(let itemID, let spaceID, _, _): return "file:\(itemID.uuidString):\(spaceID.uuidString)"
        case .createSpace(let name, _, _): return "create:\(name.lowercased())"
        }
    }

    private func worthSuggesting(_ d: SpaceIntelligence.RouteDecision) -> Bool {
        d.confidence >= (d.concrete ? suggestionFloor : max(suggestionFloor, semanticOnlySuggestionFloor))
    }

    private func addFileSuggestion(itemID: UUID, decision: SpaceIntelligence.RouteDecision) {
        let action = SpaceSuggestion.Action.file(
            itemID: itemID, spaceID: decision.spaceID, confidence: decision.confidence,
            reason: decision.reason.isEmpty ? "looks related" : decision.reason
        )
        guard !dismissedKeys.contains(Self.dismissKey(action)) else { return }
        mutateSuggestions { list in
            list.removeAll { s in
                if case .file(let id, _, _, _) = s.action { return id == itemID }
                return false
            }
            list.append(SpaceSuggestion(id: UUID(), action: action))
        }
    }

    private func removeSuggestion(_ id: UUID) {
        mutateSuggestions { $0.removeAll { $0.id == id } }
    }

    /// Drops `.file` suggestions for these items and removes them from cluster proposals.
    private func removeSuggestions(forItems ids: Set<UUID>) {
        guard suggestions.contains(where: { s in
            switch s.action {
            case .file(let itemID, _, _, _): return ids.contains(itemID)
            case .createSpace(_, let itemIDs, _): return itemIDs.contains(where: ids.contains)
            }
        }) else { return }
        mutateSuggestions { list in
            list = list.compactMap { s in
                switch s.action {
                case .file(let itemID, _, _, _):
                    return ids.contains(itemID) ? nil : s
                case .createSpace(let name, let itemIDs, let reason):
                    let remaining = itemIDs.filter { !ids.contains($0) }
                    if remaining.count == itemIDs.count { return s }
                    return remaining.count >= 2
                        ? SpaceSuggestion(id: s.id, action: .createSpace(name: name, itemIDs: remaining, reason: reason))
                        : nil
                }
            }
        }
    }

    private func mutateSuggestions(_ body: (inout [SpaceSuggestion]) -> Void) {
        var list = suggestions
        body(&list)
        guard list != suggestions else { return }
        suggestions = list
        let snapshot = list
        let personaID = currentPersonaID
        database?.enqueue("save suggestions") { try $0.replaceSuggestions(snapshot, personaID: personaID) }
    }

    /// Rules for a Space created from a cluster: its shared domains, people and organizations.
    private func derivedRules(name: String, itemIDs: [UUID]) -> SpaceAgentRules {
        var coverage: [String: (SpaceIntelligence.Entity, Int)] = [:]
        for id in itemIDs {
            var seen: Set<String> = []
            for e in typedEntities[id] ?? [] where e.isDiscriminative && seen.insert(e.key).inserted {
                coverage[e.key, default: (e, 0)].1 += 1
            }
        }
        let minimum = max(2, Int((Double(itemIDs.count) * 0.4).rounded(.up)))
        let ranked = coverage.values.filter { $0.1 >= minimum }.sorted { $0.1 > $1.1 }
        let domains = ranked.filter { $0.0.kind == .domain }.prefix(3).map { $0.0.value }
        let people = ranked.filter { $0.0.kind == .person }.prefix(3).map { $0.0.value }
        var keywords = ranked.filter { $0.0.kind == .organization }.prefix(3).map { $0.0.value }
        if !keywords.contains(where: { $0.lowercased() == name.lowercased() }) { keywords.insert(name, at: 0) }
        let titles = itemIDs.compactMap { id in items.first { $0.id == id }?.title }.prefix(5)
        let about = "\(name). " + titles.joined(separator: "; ")
        return SpaceAgentRules(
            keywords: keywords, people: people, domains: domains, apps: [], about: String(about.prefix(400)),
            autoFileThreshold: defaultAutoFileThreshold
        )
    }

    // MARK: - Routing

    private func route(_ item: SpaceIntelligence.RoutingItem) async -> SpaceIntelligence.RouteDecision? {
        guard !spaces.isEmpty else { return nil }
        let (profiles, counts) = await routingProfiles()
        guard !profiles.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            SpaceIntelligence.route(item, profiles: profiles, entitySpaceCounts: counts)
        }.value
    }

    private func routingProfiles() async -> ([SpaceIntelligence.SpaceProfile], [String: Int]) {
        if profileCache == nil { await refreshAboutVectors() }
        let profiles: [SpaceIntelligence.SpaceProfile]
        if let cached = profileCache {
            profiles = cached
        } else {
            profiles = buildProfiles()
            profileCache = profiles
        }
        var counts: [String: Int] = [:]
        for p in profiles { for key in p.entityCounts.keys { counts[key, default: 0] += 1 } }
        return (profiles, counts)
    }

    private func buildProfiles() -> [SpaceIntelligence.SpaceProfile] {
        var byID: [UUID: Space] = [:]
        for s in spaces { byID[s.id] = s }
        var direct: [UUID: [SpaceItem]] = [:]
        for item in items { if let sid = item.spaceID { direct[sid, default: []].append(item) } }
        return spaces.map { space in
            var ancestors: [UUID] = []
            var parent = space.parentID
            while let pid = parent, ancestors.count < 64, let p = byID[pid] {
                ancestors.append(pid)
                parent = p.parentID
            }
            let members = direct[space.id] ?? []
            var counts: [String: Int] = [:]
            var labels: [String: String] = [:]
            for item in members {
                var seen: Set<String> = []
                for e in typedEntities[item.id] ?? [] where e.isDiscriminative && seen.insert(e.key).inserted {
                    counts[e.key, default: 0] += 1
                    if labels[e.key] == nil { labels[e.key] = e.value }
                }
            }
            let memberVectors = members.prefix(200).compactMap { vectors[$0.id] }
            return SpaceIntelligence.SpaceProfile(
                space: space, ancestorIDs: ancestors, aboutVector: aboutVectors[space.id]?.vector,
                centroid: SpaceIntelligence.mean(memberVectors), itemCount: members.count,
                entityCounts: counts, entityLabels: labels
            )
        }
    }

    /// Embeds each Space's description (name + about + keywords) when it changed.
    private func refreshAboutVectors() async {
        let wanted: [(UUID, String)] = spaces.compactMap { space in
            let text = Self.aboutText(space)
            guard !text.isEmpty else { return nil }
            if aboutVectors[space.id]?.text == text { return nil }
            return (space.id, text)
        }
        guard !wanted.isEmpty else { return }
        let results = await Task.detached(priority: .utility) {
            wanted.map { ($0.0, $0.1, SpaceIntelligence.embed($0.1).vector) }
        }.value
        for (id, text, vector) in results where !vector.isEmpty { aboutVectors[id] = (text, vector) }
    }

    private static func aboutText(_ space: Space) -> String {
        let rules = space.rules
        var parts = [space.name]
        if !rules.about.isEmpty { parts.append(rules.about) }
        if !rules.keywords.isEmpty { parts.append(rules.keywords.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }

    /// After Spaces or rules change: suggest filing for Inbox items that now match.
    private func scheduleInboxReroute() {
        rerouteTask?.cancel()
        rerouteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.rerouteInbox()
        }
    }

    /// Re-scores Inbox items against the current Spaces and refreshes their `.file` suggestions.
    func rerouteInbox() async {
        let inbox = items.filter { $0.spaceID == nil }.prefix(300)
        guard !inbox.isEmpty, !spaces.isEmpty else { return }
        pendingWork += 1
        defer { pendingWork -= 1 }
        let (profiles, counts) = await routingProfiles()
        let model = embeddingModel
        let inputs = inbox.map { item in
            (item.id, SpaceIntelligence.RoutingItem(
                title: item.title, text: item.text, hints: Self.hints(for: item), entities: typedEntities[item.id] ?? [],
                vector: vectors[item.id] ?? [], model: model
            ))
        }
        let decisions = await Task.detached(priority: .utility) {
            inputs.map { ($0.0, SpaceIntelligence.route($0.1, profiles: profiles, entitySpaceCounts: counts)) }
        }.value
        guard !Task.isCancelled else { return }
        for (itemID, decision) in decisions {
            guard let decision, worthSuggesting(decision),
                  items.contains(where: { $0.id == itemID && $0.spaceID == nil }) else { continue }
            let already = suggestions.contains { s in
                if case .file(let id, let sid, _, _) = s.action { return id == itemID && sid == decision.spaceID }
                return false
            }
            if !already { addFileSuggestion(itemID: itemID, decision: decision) }
        }
    }

    private func suggestFiling(for itemID: UUID) async {
        guard let item = items.first(where: { $0.id == itemID }), item.spaceID == nil else { return }
        let decision = await route(SpaceIntelligence.RoutingItem(
            title: item.title, text: item.text, hints: Self.hints(for: item), entities: typedEntities[itemID] ?? [],
            vector: vectors[itemID] ?? [], model: embeddingModel
        ))
        if let decision, worthSuggesting(decision), self.item(itemID)?.spaceID == nil {
            addFileSuggestion(itemID: itemID, decision: decision)
        }
    }

    // MARK: - Clustering

    /// Clusters the Inbox and refreshes the "create Space" suggestions.
    func recluster() async {
        pendingWork += 1
        defer { pendingWork -= 1 }
        let personaID = currentPersonaID
        let model = embeddingModel
        let candidates = items.filter { $0.spaceID == nil }.prefix(300).map { item in
            SpaceIntelligence.ClusterCandidate(
                id: item.id, title: item.title, entities: typedEntities[item.id] ?? [],
                vector: vectors[item.id] ?? [], model: model
            )
        }
        let names = Set(spaces.map(\.name))
        let reserved = Set(spaces.flatMap { $0.rules.people + $0.rules.keywords + $0.rules.domains })
        let proposals = await Task.detached(priority: .utility) {
            SpaceIntelligence.cluster(Array(candidates), existingNames: names, reservedTerms: reserved)
        }.value
        guard personaID == currentPersonaID else { return }

        // A cluster that mostly routes to one existing Space isn't a new
        // organization: suggest filing its items there instead.
        var newSpaceProposals: [SpaceIntelligence.ClusterProposal] = []
        if spaces.isEmpty {
            newSpaceProposals = proposals
        } else {
            let (profiles, counts) = await routingProfiles()
            let lookup = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let routable: [(SpaceIntelligence.ClusterProposal, [(UUID, SpaceIntelligence.RoutingItem)])] = proposals.map { p in
                (p, p.itemIDs.compactMap { id in
                    guard let c = lookup[id], let item = self.item(id) else { return nil }
                    return (id, SpaceIntelligence.RoutingItem(
                        title: c.title, text: item.text, hints: Self.hints(for: item), entities: c.entities,
                        vector: c.vector, model: c.model
                    ))
                })
            }
            let routed = await Task.detached(priority: .utility) {
                routable.map { proposal, members in
                    (proposal, members.map { ($0.0, SpaceIntelligence.route($0.1, profiles: profiles, entitySpaceCounts: counts)) })
                }
            }.value
            for (proposal, decisions) in routed {
                var votes: [UUID: Int] = [:]
                for (_, d) in decisions { if let d, d.confidence >= 0.25 { votes[d.spaceID, default: 0] += 1 } }
                if let (spaceID, n) = votes.max(by: { $0.value < $1.value }), Double(n) >= Double(proposal.itemIDs.count) * 0.5 {
                    let name = space(spaceID)?.name ?? "this Space"
                    for (itemID, d) in decisions {
                        guard var d, d.spaceID == spaceID, d.confidence >= 0.25 else { continue }
                        let similar = proposal.itemIDs.count - 1
                        d.reason = (d.reason.isEmpty ? "" : d.reason + "; ") + "like \(similar) similar Inbox item\(similar == 1 ? "" : "s") for \(name)"
                        let exists = suggestions.contains { s in
                            if case .file(let id, _, _, _) = s.action { return id == itemID }
                            return false
                        }
                        if !exists && self.item(itemID)?.spaceID == nil { addFileSuggestion(itemID: itemID, decision: d) }
                    }
                } else {
                    newSpaceProposals.append(proposal)
                }
            }
        }
        let fresh = newSpaceProposals.compactMap { p -> SpaceSuggestion? in
            let action = SpaceSuggestion.Action.createSpace(name: p.name, itemIDs: p.itemIDs, reason: p.reason)
            return dismissedKeys.contains(Self.dismissKey(action)) ? nil : SpaceSuggestion(id: UUID(), action: action)
        }
        mutateSuggestions { list in
            // Keep ids stable for proposals that didn't change.
            let previous = list.filter { if case .createSpace = $0.action { return true }; return false }
            list.removeAll { if case .createSpace = $0.action { return true }; return false }
            for suggestion in fresh {
                if let same = previous.first(where: { $0.action == suggestion.action }) {
                    list.append(same)
                } else {
                    list.append(suggestion)
                }
            }
        }
        AppLog.log("Spaces: recluster → \(fresh.count) proposal(s) from \(candidates.count) Inbox item(s)")
    }

    // MARK: - Search

    /// Keyword (FTS5 BM25) + semantic (cosine) search. `spaceID` nil = everywhere
    /// (all Spaces and the Inbox); otherwise that Space and its subfolders.
    func search(_ query: String, in spaceID: UUID?) async -> [SpaceItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return await rankedSearch(q, in: spaceID, limit: 50).map(\.item)
    }

    private struct Hit {
        var item: SpaceItem
        var score: Double
    }

    private func rankedSearch(_ q: String, in spaceID: UUID?, limit: Int) async -> [Hit] {
        let scope: Set<UUID>? = spaceID.map { descendantIDs(of: $0).union([$0]) }
        let personaID = currentPersonaID
        var bm: [UUID: Double] = [:]
        if let database, let match = SpaceDatabase.ftsQuery(q) {
            let rows = (try? await database.read { try $0.searchFTS(match, personaID: personaID, limit: 300) }) ?? []
            for (id, rank) in rows { bm[id] = -rank }
        } else {
            let queryTerms = Set(SpaceIntelligence.terms(of: q))
            for item in items {
                let s = SpaceIntelligence.sentenceScore(item.title + " " + item.text.prefix(4000), terms: queryTerms)
                if s > 0 { bm[item.id] = s }
            }
        }
        let queryVector = await Task.detached(priority: .userInitiated) { SpaceIntelligence.embed(q).vector }.value
        let model = embeddingModel
        let maxBM = bm.values.max() ?? 0
        let queryTermCount = max(1, SpaceIntelligence.terms(of: q).count)
        let lowerQ = q.lowercased()
        var hits: [Hit] = []
        for item in items {
            if let scope, !(item.spaceID.map(scope.contains) ?? false) { continue }
            let keyword = maxBM > 0 ? (bm[item.id] ?? 0) / maxBM : 0
            var semantic = 0.0
            if let v = vectors[item.id], !queryVector.isEmpty {
                semantic = SpaceIntelligence.semanticScore(SpaceIntelligence.cosine(queryVector, v), model: model)
            }
            var score: Double
            if keyword > 0 {
                score = 0.6 * keyword + 0.4 * semantic
                if item.title.lowercased().contains(lowerQ) { score += 0.15 }
            } else {
                // Semantic-only matches need to be clearly related.
                guard semantic >= (queryTermCount <= 2 ? 0.75 : 0.6) else { continue }
                score = 0.4 * semantic
            }
            if score >= 0.12 { hits.append(Hit(item: item, score: score)) }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.createdAt > $1.item.createdAt }
        return Array(hits.prefix(limit))
    }

    // MARK: - Q&A

    /// Answers from the items in scope (nil = everywhere) with [n] citations,
    /// using the on-device model; a deterministic extractive answer otherwise.
    func ask(_ question: String, in spaceID: UUID?) async throws -> SpaceAnswer {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SpaceAnswer(text: "Ask a question about this Space.", citedItemIDs: [], producedBy: Self.extractiveName) }
        pendingWork += 1
        activeAsks += 1
        // The on-device model runs one request at a time: stop background
        // memory refreshes so the question doesn't wait behind them.
        for (id, task) in memoryTasks {
            task.cancel()
            postponedMemory.insert(id)
        }
        memoryTasks = [:]
        defer {
            pendingWork -= 1
            activeAsks -= 1
            if activeAsks == 0 {
                let postponed = postponedMemory
                postponedMemory = []
                for id in postponed { scheduleMemoryRefresh(id, force: true, delay: memoryIdleDelay) }
            }
        }

        var retrieved = await rankedSearch(q, in: spaceID, limit: 8).map(\.item)
        if retrieved.count < 3 {
            let pool = spaceID.map { items(in: $0, recursive: true) } ?? items
            for item in pool where !retrieved.contains(where: { $0.id == item.id }) && retrieved.count < 4 {
                retrieved.append(item)
            }
        }
        try Task.checkCancellation()
        guard !retrieved.isEmpty else {
            return SpaceAnswer(text: "There's nothing here yet to answer from.", citedItemIDs: [], producedBy: Self.extractiveName)
        }
        let background = spaceID.flatMap { memory(of: $0) }

        if MeetingAIBackend.onDeviceAvailable {
            for budget in [7_500, 4_000] {
                let sources = Self.sources(for: retrieved, question: q, budget: budget)
                let prompt = Self.askPrompt(question: q, sources: sources, background: background)
                do {
                    let reply = try await MeetingAIBackend.onDevice(
                        instructions: Self.askInstructions, prompt: prompt, schema: nil,
                        maxTokens: 400, timeout: 30, permissive: true
                    )
                    let cleaned = Self.cleanAnswer(reply)
                    guard !cleaned.isEmpty else { break }
                    // Inline [n] markers are renumbered to match the citation list.
                    var (text, cited) = SpaceIntelligence.renumberCitations(cleaned, sources: sources)
                    if cited.isEmpty, let first = sources.first { cited = [first.itemID] }
                    return SpaceAnswer(text: text, citedItemIDs: cited, producedBy: Self.onDeviceModelName)
                } catch is CancellationError {
                    throw CancellationError()
                } catch MeetingAIError.contextTooLarge {
                    continue
                } catch {
                    AppLog.log("Spaces: on-device answer failed (\(error.localizedDescription)); using extractive answer")
                    break
                }
            }
        }
        let sources = Self.sources(for: retrieved, question: q, budget: 20_000)
        let extractive = await Task.detached(priority: .userInitiated) {
            SpaceIntelligence.extractiveAnswer(question: q, sources: sources)
        }.value
        let renumbered = SpaceIntelligence.renumberCitations(extractive.text, sources: sources)
        return SpaceAnswer(
            text: renumbered.text, citedItemIDs: renumbered.cited.isEmpty ? extractive.cited : renumbered.cited,
            producedBy: Self.extractiveName
        )
    }

    private static let askInstructions = """
    You answer questions using only the numbered sources from the user's own notes, meetings, emails and files. \
    Cite every fact with its source number in square brackets, like [1] or [2][3]. \
    If the sources don't contain the answer, say you couldn't find it. Be concise: at most five sentences. \
    Never invent names, dates or numbers.
    """

    private static func sources(for items: [SpaceItem], question: String, budget: Int) -> [SpaceIntelligence.Source] {
        let queryTerms = Set(SpaceIntelligence.terms(of: question))
        let perItem = max(400, budget / max(1, items.count))
        var used = 0
        var out: [SpaceIntelligence.Source] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        for item in items {
            guard used < budget else { break }
            let allowance = min(perItem + max(0, (budget - used) - perItem * (items.count - out.count)) / 2, budget - used)
            let excerpt = SpaceIntelligence.passage(of: item.text, terms: queryTerms, budget: max(200, allowance))
            used += excerpt.count + item.title.count + 40
            let header = "\(item.title) (\(item.kind.rawValue), \(formatter.string(from: item.createdAt)))"
            out.append(SpaceIntelligence.Source(number: out.count + 1, itemID: item.id, title: header, text: excerpt))
        }
        return out
    }

    private static func askPrompt(question: String, sources: [SpaceIntelligence.Source], background: String?) -> String {
        var parts: [String] = []
        if let background, !background.isEmpty {
            parts.append("Background about this Space (don't cite):\n" + String(background.prefix(600)))
        }
        parts.append("Sources:")
        for s in sources { parts.append("[\(s.number)] \(s.title)\n\(s.text)") }
        parts.append("Question: \(question)\nAnswer with citations:")
        return parts.joined(separator: "\n\n")
    }

    private static func cleanAnswer(_ reply: String) -> String {
        var text = MeetingAIJSON.stripReasoning(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Answer with citations:", "Answer:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Space memory

    /// The Space agent's running summary (regenerated in the background after
    /// every `memoryRefreshEvery` new items).
    func memory(of spaceID: UUID) -> String? {
        memories[spaceID]?.summary
    }

    func memoryRecord(of spaceID: UUID) -> SpaceMemoryRecord? { memories[spaceID] }

    /// Debounced background refresh when enough new items arrived (also bubbles up to parents).
    private func scheduleMemoryRefresh(_ spaceID: UUID, force: Bool = false, delay: Double? = nil) {
        var current: UUID? = spaceID
        var depth = 0
        while let id = current, depth < 16 {
            let count = items(in: id, recursive: true).count
            let last = memories[id]?.itemCount
            let due = (force && depth == 0) || (last.map { abs(count - $0) >= memoryRefreshEvery } ?? (count >= 3))
            if due && activeAsks > 0 {
                postponedMemory.insert(id)
            } else if due && memoryTasks[id] == nil {
                let delay = max(delay ?? 0, memoryRefreshDelay)
                memoryTasks[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.refreshMemory(of: id, background: true)
                    if !Task.isCancelled { self?.memoryTasks[id] = nil }
                }
            }
            current = spaces.first { $0.id == id }?.parentID
            depth += 1
        }
    }

    /// Regenerates a Space's memory now (on-device model, extractive fallback).
    func refreshMemory(of spaceID: UUID) async {
        await refreshMemory(of: spaceID, background: false)
    }

    private func refreshMemory(of spaceID: UUID, background: Bool) async {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        let scoped = items(in: spaceID, recursive: true)
        guard !scoped.isEmpty else { return }
        pendingWork += 1
        defer { pendingWork -= 1 }
        let previous = memories[spaceID]?.summary
        let recent = Array(scoped.prefix(12))
        var summary: String?
        var producedBy = Self.extractiveName
        if MeetingAIBackend.onDeviceAvailable && !(background && activeAsks > 0) {
            var lines: [String] = []
            var used = 0
            for item in recent {
                let excerpt = String(item.text.prefix(500)).replacingOccurrences(of: "\n", with: " ")
                let line = "- \(item.title): \(excerpt)"
                guard used + line.count < 6_000 else { break }
                lines.append(line)
                used += line.count
            }
            let prompt = """
            Space: \(space.name)\(space.rules.about.isEmpty ? "" : " — \(space.rules.about)")
            Items: \(scoped.count)
            Previous memory:
            \(previous ?? "(none)")

            Newest items:
            \(lines.joined(separator: "\n"))

            Write the updated memory.
            """
            do {
                let reply = try await MeetingAIBackend.onDevice(
                    instructions: Self.memoryInstructions, prompt: prompt, schema: nil,
                    maxTokens: 320, timeout: 30, permissive: true
                )
                let cleaned = MeetingAIJSON.stripReasoning(reply).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    summary = cleaned
                    producedBy = Self.onDeviceModelName
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                AppLog.log("Spaces: memory for \(space.name) via model failed (\(error.localizedDescription))")
            }
        }
        if summary == nil {
            let entities = scoped.prefix(200).flatMap { typedEntities[$0.id] ?? [] }
            summary = SpaceIntelligence.extractiveMemory(
                spaceName: space.name, itemCount: scoped.count, entities: entities, recentTitles: recent.map(\.title)
            )
        }
        guard let summary, spaces.contains(where: { $0.id == spaceID }) else { return }
        let record = SpaceMemoryRecord(
            spaceID: spaceID, summary: summary, itemCount: scoped.count, producedBy: producedBy, updatedAt: Date()
        )
        memories[spaceID] = record
        objectWillChange.send()
        database?.enqueue("save memory") { try $0.upsertMemory(record) }
    }

    private static let memoryInstructions = """
    You keep a short running memory for one folder of the user's knowledge (a client, organization or project). \
    Using the previous memory and the newest items, write 3 to 6 short bullet points: who is involved, what it is \
    about, decisions, open tasks and upcoming dates. Keep facts from the previous memory that still matter. \
    Only use facts from the text. No preamble.
    """

    // MARK: - Re-indexing

    /// Re-extracts entities and re-embeds every item of the current persona.
    func reindexAll() async {
        reindexTask?.cancel()
        await reanalyze(items, personaID: currentPersonaID, refreshEntities: true)
    }

    /// Waits for queued database writes (tests, before export, on quit).
    func flush() { database?.flush() }

    // MARK: - Persistence helpers

    private func persist(_ space: Space) {
        database?.enqueue("save space") { try $0.upsertSpace(space) }
    }

    private func persist(_ item: SpaceItem) {
        let typed = typedEntities[item.id] ?? []
        database?.enqueue("save item") { try $0.upsertItem(item, typed: typed) }
    }

    private func persistFiling(_ item: SpaceItem) {
        database?.enqueue("file item") { try $0.updateFiling(item) }
    }

    private func persistVector(_ id: UUID, _ analysis: SpaceIntelligence.Analysis) {
        guard !analysis.vector.isEmpty else { return }
        let model = analysis.model, vector = analysis.vector
        if embeddingModel.isEmpty { embeddingModel = model }
        database?.enqueue("save embedding") { try $0.setEmbedding(id, model: model, vector: vector) }
    }

    // MARK: - Import support (used by SpaceSharing.swift)

    /// Adds imported Spaces and items to the current persona.
    func commitImport(spaces newSpaces: [Space], items newItems: [SpaceItem], memories newMemories: [SpaceMemoryRecord]) {
        spaces.append(contentsOf: newSpaces)
        for item in newItems {
            insertSorted(item)
            typedEntities[item.id] = []
        }
        for record in newMemories { memories[record.spaceID] = record }
        let pairs = newItems.map { ($0, [SpaceIntelligence.Entity]()) }
        database?.enqueue("import") { c in
            for s in newSpaces { try c.upsertSpace(s) }
            try c.upsertItems(pairs)
            for m in newMemories { try c.upsertMemory(m) }
        }
        profileCache = nil
        let personaID = currentPersonaID
        Task { [weak self] in
            await self?.reanalyze(newItems, personaID: personaID, refreshEntities: true)
        }
    }

    func memoryRecords(for spaceIDs: Set<UUID>) -> [SpaceMemoryRecord] {
        memories.values.filter { spaceIDs.contains($0.spaceID) }
    }

    // MARK: - Static helpers

    nonisolated static func analyze(title: String, text: String, hints: [String: String]) async -> SpaceIntelligence.Analysis {
        await Task.detached(priority: .utility) {
            SpaceIntelligence.analyze(title: title, text: text, hints: hints)
        }.value
    }

    /// Routing/extraction hints recoverable from a stored item.
    nonisolated static func hints(for item: SpaceItem) -> [String: String] {
        guard let url = item.url, !url.isFileURL else { return [:] }
        return ["url": url.absoluteString]
    }

    nonisolated static func entityStrings(_ entities: [SpaceIntelligence.Entity]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for e in entities where e.kind != .url && seen.insert(e.key).inserted { out.append(e.value) }
        return out
    }

    /// Copies a file into Attachments/<itemID>/; returns the path relative to `root`.
    nonisolated static func copyAttachment(_ source: URL, itemID: UUID, root: URL) -> String? {
        let fm = FileManager.default
        guard source.isFileURL, fm.fileExists(atPath: source.path) else { return nil }
        let folder = root.appendingPathComponent("Attachments/\(itemID.uuidString)", isDirectory: true)
        var name = source.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        if name.isEmpty || name == "." || name == ".." { name = "attachment" }
        let destination = folder.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            return "Attachments/\(itemID.uuidString)/\(name)"
        } catch {
            AppLog.log("Spaces: couldn't copy attachment \(source.lastPathComponent) — \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func removeAttachments(itemID: UUID, root: URL) {
        let folder = root.appendingPathComponent("Attachments/\(itemID.uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try? FileManager.default.removeItem(at: folder) }
    }

    static func hasRules(_ rules: SpaceAgentRules) -> Bool {
        !rules.keywords.isEmpty || !rules.people.isEmpty || !rules.domains.isEmpty || !rules.apps.isEmpty
            || !rules.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sanitized(_ rules: SpaceAgentRules) -> SpaceAgentRules {
        func list(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        var r = rules
        r.keywords = list(r.keywords)
        r.people = list(r.people)
        r.domains = list(r.domains.map(SpaceIntelligence.normalizeDomain))
        r.apps = list(r.apps)
        r.about = r.about.trimmingCharacters(in: .whitespacesAndNewlines)
        r.autoFileThreshold = r.autoFileThreshold.isFinite ? min(1, max(0, r.autoFileThreshold)) : 0.7
        return r
    }

    private static func clean(_ text: String, fallback: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : String(t.prefix(200))
    }

    static let palette = ["#4F8EF7", "#34C759", "#FF9F0A", "#FF375F", "#BF5AF2", "#64D2FF", "#FFD60A", "#AC8E68"]

    /// A stable color for a name.
    static func color(for name: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in name.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
