import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Spaces window: personas and the Space tree on the left, the items of
// the selection in the middle, and on the right either the selected item or
// the selected Space's agent (memory, rules, members, "Ask this Space").
// NotchIsland is an agent app, so the window brings a Dock icon while it's
// open and gives it back on close (the glance settings-window pattern).

// MARK: - Window controller

@MainActor
final class SpacesWindowController: NSObject, NSWindowDelegate {
    static let shared = SpacesWindowController()

    let model = SpacesWindowModel()
    private var window: NSWindow?

    /// Opens a meeting in Meeting Notes; set by the app (NotchWindowController)
    /// because the meeting assistant isn't a singleton.
    var openMeeting: ((UUID) -> Void)?

    /// Opens the window on a Space (nil = Inbox).
    func show(spaceID: UUID? = nil, tab: SpacesInspectorTab? = nil) {
        reveal()
        model.select(spaceID.map { SpacesSidebarSelection.space($0) } ?? .inbox)
        if let tab { model.inspectorTab = tab }
    }

    /// Opens the window with an item selected inside its Space.
    func show(itemID: UUID) {
        reveal()
        model.reveal(itemID: itemID)
    }

    /// Opens the window and asks for the new Space's name.
    func createSpace(parentID: UUID?) {
        reveal()
        model.newSpace(parentID: parentID)
    }

    func promptNewPersona() {
        reveal()
        model.newPersona()
    }

    func close() {
        window?.close()
    }

    private func reveal() {
        let window = window ?? makeWindow()
        self.window = window
        model.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = SpacesRootView(model: model, store: SpaceStore.shared)
        let hosting = NSHostingController(rootView: root.followsAppearance())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Spaces"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(SparkVTheme.background)
        LabsWindowGround.follow(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 940, height: 560)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("NotchIsland.Spaces")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Sidebar order

/// Sibling order of Spaces in the sidebar and the drawer. `Space` has no
/// order field yet, so the order is kept per persona in UserDefaults; Spaces
/// it doesn't know sort after, oldest first.
@MainActor
enum SpacesSidebarOrder {
    private static let key = "NotchIsland.Spaces.sidebarOrder"

    static func order(personaID: UUID) -> [UUID] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return (all[personaID.uuidString] ?? []).compactMap(UUID.init(uuidString:))
    }

    static func setOrder(_ ids: [UUID], personaID: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[personaID.uuidString] = ids.map(\.uuidString)
        UserDefaults.standard.set(all, forKey: key)
    }

    static func sorted(_ spaces: [Space], personaID: UUID) -> [Space] {
        var index: [UUID: Int] = [:]
        for (position, id) in order(personaID: personaID).enumerated() where index[id] == nil {
            index[id] = position
        }
        return spaces.sorted { lhs, rhs in
            let l = index[lhs.id] ?? Int.max, r = index[rhs.id] ?? Int.max
            if l != r { return l < r }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Puts `id` right before `targetID` (or at the end when nil).
    static func place(_ id: UUID, before targetID: UUID?, among spaces: [Space], personaID: UUID) {
        var ids = sorted(spaces, personaID: personaID).map(\.id)
        ids.removeAll { $0 == id }
        if let targetID, let index = ids.firstIndex(of: targetID) {
            ids.insert(id, at: index)
        } else {
            ids.append(id)
        }
        setOrder(ids, personaID: personaID)
    }
}

// MARK: - Model

enum SpacesSidebarSelection: Hashable {
    case inbox
    case space(UUID)

    var spaceID: UUID? {
        if case .space(let id) = self { return id }
        return nil
    }
}

enum SpacesInspectorTab: String, CaseIterable, Identifiable {
    case agent = "Agent"
    case members = "Members"
    case ask = "Ask"
    var id: String { rawValue }
}

struct SpacesSidebarRow: Identifiable {
    let space: Space
    let depth: Int
    let hasChildren: Bool
    var id: UUID { space.id }
}

/// Where a drag over a sidebar row would land.
struct SpacesDropHint: Equatable {
    enum Position: Equatable { case before, into }
    let target: SpacesSidebarSelection
    let position: Position
}

struct SpacesAskExchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: String?
    var citations: [UUID] = []
    var producedBy: String?
    var error: String?
}

/// Editable copy of a Space's look and agent rules; saved with "Save".
@MainActor
final class SpacesAgentDraft: ObservableObject {
    let spaceID: UUID
    @Published var name = ""
    @Published var icon = ""
    @Published var color = ""
    @Published var about = ""
    @Published var keywords: [String] = []
    @Published var people: [String] = []
    @Published var domains: [String] = []
    @Published var apps: [String] = []
    @Published var threshold = 0.8
    @Published var keywordInput = ""
    @Published var peopleInput = ""
    @Published var domainInput = ""

    init(space: Space) {
        spaceID = space.id
        load(space)
    }

    func load(_ space: Space) {
        name = space.name
        icon = space.icon
        color = space.color
        about = space.rules.about
        keywords = space.rules.keywords
        people = space.rules.people
        domains = space.rules.domains
        apps = space.rules.apps
        threshold = space.rules.autoFileThreshold
        keywordInput = ""
        peopleInput = ""
        domainInput = ""
    }

    var rules: SpaceAgentRules {
        SpaceAgentRules(
            keywords: keywords, people: people, domains: domains, apps: apps,
            about: about.trimmingCharacters(in: .whitespacesAndNewlines),
            autoFileThreshold: threshold
        )
    }

    func isDirty(comparedTo space: Space) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName != space.name || icon != space.icon || color != space.color
            || rules != space.rules
            || !keywordInput.isEmpty || !peopleInput.isEmpty || !domainInput.isEmpty
    }

    /// Moves half-typed tokens into their lists before saving.
    func commitInputs() {
        Self.addTokens(from: &keywordInput, to: &keywords)
        Self.addTokens(from: &peopleInput, to: &people)
        Self.addTokens(from: &domainInput, to: &domains, normalize: Self.normalizeDomain)
    }

    func applied(to space: Space) -> Space {
        commitInputs()
        var updated = space
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmedName.isEmpty ? space.name : trimmedName
        updated.icon = icon
        updated.color = color
        updated.rules = rules
        updated.updatedAt = Date()
        return updated
    }

    static func addTokens(from input: inout String, to list: inout [String], normalize: (String) -> String = { $0 }) {
        let parts = input
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        for part in parts where !list.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            list.append(part)
        }
        input = ""
    }

    /// "https://www.Helm.events/about" or "ana@helm.events" → "helm.events".
    static func normalizeDomain(_ raw: String) -> String {
        var value = raw.lowercased()
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

/// The "New Note" sheet.
@MainActor
final class SpacesManualEntry: ObservableObject, Identifiable {
    @Published var title = ""
    @Published var text = ""
    @Published var urlString = ""
    @Published var kind: SpaceItemKind = .note
    @Published var spaceID: UUID?

    init(spaceID: UUID?) {
        self.spaceID = spaceID
    }

    var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://" + trimmed)
    }

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || url != nil
    }
}

/// UI state of the Spaces window (no `@State` with the Command Line Tools).
@MainActor
final class SpacesWindowModel: ObservableObject {
    let store: SpaceStore

    @Published private(set) var selection: SpacesSidebarSelection = .inbox
    @Published var selectedItemID: UUID? {
        didSet { if selectedItemID != oldValue { tagInput = "" } }
    }
    @Published var tagInput = ""
    @Published private(set) var refreshingMemoryID: UUID?
    @Published private(set) var isRerouting = false
    @Published var inspectorTab: SpacesInspectorTab = .agent
    @Published var kindFilter: SpaceItemKind?
    @Published var sourceFilter: SpaceItemSource?
    @Published var includeSubfolders = true
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    /// Search every Space instead of only the selection.
    @Published var searchEverywhere = false {
        didSet { if searchEverywhere != oldValue { scheduleSearch() } }
    }
    @Published private(set) var searchResults: [SpaceItem]?
    @Published private(set) var isSearching = false
    @Published var expanded: Set<UUID> = []
    @Published var dropHint: SpacesDropHint?
    @Published var manualEntry: SpacesManualEntry?
    @Published private(set) var agentDraft: SpacesAgentDraft?
    @Published private(set) var toast: String?
    @Published private(set) var isReclustering = false

    // Members editor
    @Published var newMemberName = ""
    @Published var newMemberEmail = ""
    @Published var newMemberRole: SpaceRole = .editor

    // Ask
    @Published var askDraft = ""
    @Published private(set) var conversations: [String: [SpacesAskExchange]] = [:]
    @Published private(set) var isAsking = false

    weak var window: NSWindow?
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(store: SpaceStore? = nil) {
        self.store = store ?? SpaceStore.shared
    }

    // MARK: Selection

    var selectedSpace: Space? {
        selection.spaceID.flatMap { id in store.spaces.first { $0.id == id } }
    }

    var selectedItem: SpaceItem? {
        selectedItemID.flatMap { id in store.items.first { $0.id == id } }
    }

    func select(_ newSelection: SpacesSidebarSelection) {
        if newSelection != selection {
            selection = newSelection
            askDraft = ""
        }
        selectedItemID = nil
        if case .space(let id) = newSelection {
            expandAncestors(of: id)
            if let space = store.spaces.first(where: { $0.id == id }) {
                if agentDraft?.spaceID != id { agentDraft = SpacesAgentDraft(space: space) }
            }
        } else {
            agentDraft = nil
        }
        if !query.isEmpty { scheduleSearch() }
    }

    func edit(_ spaceID: UUID, tab: SpacesInspectorTab) {
        select(.space(spaceID))
        inspectorTab = tab
    }

    /// Selects an item, switching to its Space when it isn't in the list.
    func reveal(itemID: UUID) {
        guard let item = store.items.first(where: { $0.id == itemID }) else { return }
        if !visibleItems().contains(where: { $0.id == itemID }) {
            query = ""
            kindFilter = nil
            sourceFilter = nil
            select(item.spaceID.map { SpacesSidebarSelection.space($0) } ?? .inbox)
        }
        selectedItemID = itemID
    }

    /// Keeps the selection valid when Spaces or the persona change.
    func storeDidChange() {
        if let id = selection.spaceID {
            if let space = store.spaces.first(where: { $0.id == id }) {
                if let draft = agentDraft, draft.spaceID == id, !draft.isDirty(comparedTo: space) {
                    draft.load(space)
                } else if agentDraft?.spaceID != id {
                    agentDraft = SpacesAgentDraft(space: space)
                }
            } else {
                select(.inbox)
            }
        }
        if let itemID = selectedItemID, !store.items.contains(where: { $0.id == itemID }) {
            selectedItemID = nil
        }
    }

    func personaDidChange() {
        conversations = [:]
        query = ""
        select(.inbox)
    }

    private func expandAncestors(of id: UUID) {
        var cursor = store.spaces.first { $0.id == id }?.parentID
        var guardCount = 0
        while let parent = cursor, guardCount < 32 {
            expanded.insert(parent)
            cursor = store.spaces.first { $0.id == parent }?.parentID
            guardCount += 1
        }
    }

    // MARK: Sidebar tree

    func sidebarRows() -> [SpacesSidebarRow] {
        let personaID = store.currentPersonaID
        var byParent: [UUID?: [Space]] = [:]
        let known = Set(store.spaces.map(\.id))
        for space in store.spaces {
            // A Space whose parent is gone shows at the top level.
            let parent = space.parentID.flatMap { known.contains($0) ? $0 : nil }
            byParent[parent, default: []].append(space)
        }
        var rows: [SpacesSidebarRow] = []
        func walk(_ parent: UUID?, depth: Int) {
            guard depth < 16 else { return }
            for space in SpacesSidebarOrder.sorted(byParent[parent] ?? [], personaID: personaID) {
                let children = byParent[space.id] ?? []
                rows.append(SpacesSidebarRow(space: space, depth: depth, hasChildren: !children.isEmpty))
                if expanded.contains(space.id) { walk(space.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        return rows
    }

    /// Every Space, depth-first, for "Move to" menus and pickers.
    func allSpacesFlattened() -> [(space: Space, depth: Int)] {
        let personaID = store.currentPersonaID
        var result: [(Space, Int)] = []
        func walk(_ parent: UUID?, depth: Int) {
            guard depth < 16 else { return }
            for space in SpacesSidebarOrder.sorted(store.spaces.filter { $0.parentID == parent }, personaID: personaID) {
                result.append((space, depth))
                walk(space.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return result.map { (space: $0.0, depth: $0.1) }
    }

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Items

    func visibleItems() -> [SpaceItem] {
        var list: [SpaceItem]
        if let results = searchResults {
            list = results
        } else {
            switch selection {
            case .inbox: list = store.items(in: nil, recursive: false)
            case .space(let id): list = store.items(in: id, recursive: includeSubfolders)
            }
        }
        if let kindFilter { list = list.filter { $0.kind == kindFilter } }
        if let sourceFilter { list = list.filter { $0.source == sourceFilter } }
        return list
    }

    var isFiltering: Bool { kindFilter != nil || sourceFilter != nil }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            searchResults = nil
            isSearching = false
            return
        }
        isSearching = true
        let everywhere = searchEverywhere
        let selection = self.selection
        let recursive = includeSubfolders
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            var found: [SpaceItem]
            if everywhere {
                found = await self.store.search(text, in: nil)
            } else {
                switch selection {
                case .inbox:
                    found = await self.store.search(text, in: nil).filter { $0.spaceID == nil }
                case .space(let id):
                    found = await self.store.search(text, in: id)
                    if !recursive { found = found.filter { $0.spaceID == id } }
                }
            }
            guard !Task.isCancelled else { return }
            self.searchResults = found
            self.isSearching = false
        }
    }

    func move(_ itemID: UUID, to spaceID: UUID?) {
        store.move(itemID: itemID, to: spaceID)
        flash("Moved to \(SpacesUI.path(of: spaceID, in: store.spaces))")
    }

    func confirmDelete(_ item: SpaceItem) {
        let id = item.id
        Task { [weak self] in
            guard let self else { return }
            let choice = await SpacesUI.confirm(
                title: "Delete “\(item.title.isEmpty ? "Untitled" : item.title)”?",
                message: "It's removed from Spaces on this Mac. The original file, page or meeting isn't touched.",
                buttons: ["Delete", "Cancel"],
                window: self.window
            )
            guard choice == 0 else { return }
            if self.selectedItemID == id { self.selectedItemID = nil }
            self.store.delete(itemID: id)
        }
    }

    func addTags(to item: SpaceItem) {
        var text = tagInput
        var tags = item.tags
        SpacesAgentDraft.addTokens(from: &text, to: &tags) {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }
        tagInput = text
        guard tags != item.tags else { return }
        var updated = item
        updated.tags = tags
        store.updateItem(updated)
    }

    func removeTag(_ tag: String, from item: SpaceItem) {
        var updated = item
        updated.tags.removeAll { $0 == tag }
        store.updateItem(updated)
    }

    func rename(_ item: SpaceItem) {
        Task { [weak self] in
            guard let self else { return }
            guard let title = await SpacesUI.prompt(
                title: "Rename Item", defaultValue: item.title, confirm: "Rename", window: self.window
            ), var current = self.store.item(item.id) else { return }
            current.title = title
            self.store.updateItem(current)
        }
    }

    func refreshMemory(of spaceID: UUID) {
        guard refreshingMemoryID == nil else { return }
        refreshingMemoryID = spaceID
        Task { [weak self] in
            await self?.store.refreshMemory(of: spaceID)
            self?.refreshingMemoryID = nil
        }
    }

    func rerouteInbox() {
        guard !isRerouting else { return }
        isRerouting = true
        Task { [weak self] in
            guard let self else { return }
            await self.store.rerouteInbox()
            self.isRerouting = false
            let count = self.store.suggestions.filter {
                if case .file = $0.action { return true }
                return false
            }.count
            self.flash(count == 0 ? "No Space matched the Inbox items" : "\(count) filing suggestion\(count == 1 ? "" : "s") to review")
        }
    }

    func openOriginal(_ item: SpaceItem) {
        open(item.url)
    }

    /// Web pages, files and mail open in their apps; meetings in Meeting Notes.
    func open(_ url: URL?) {
        guard let url else { return }
        if let meetingID = SpacesUI.meetingID(from: url) {
            if let openMeeting = SpacesWindowController.shared.openMeeting {
                openMeeting(meetingID)
            } else {
                flash("Open this meeting from Meeting Notes")
            }
            return
        }
        if !NSWorkspace.shared.open(url) { flash("Couldn't open \(url.isFileURL ? url.lastPathComponent : (url.host ?? "the link"))") }
    }

    // MARK: Spaces

    func newSpace(parentID: UUID?) {
        let parent = parentID.flatMap { id in store.spaces.first { $0.id == id } }
        Task { [weak self] in
            guard let self else { return }
            let name = await SpacesUI.prompt(
                title: parent == nil ? "New Space" : "New Folder in \(parent?.name ?? "")",
                message: parent == nil
                    ? "A Space gathers everything about one organization, client or project. Its agent files new items here."
                    : "Folders are Spaces inside a Space, with their own agent.",
                confirm: "Create",
                window: self.window
            )
            guard let name else { return }
            let color = parent?.color ?? SpacesPalette.spaceColors[self.store.spaces.count % SpacesPalette.spaceColors.count]
            let icon = parent == nil ? "building.2.fill" : "folder.fill"
            let space = self.store.createSpace(name: name, parentID: parentID, icon: icon, color: color, rules: SpacesUI.emptyRules)
            if let parentID { self.expanded.insert(parentID) }
            self.select(.space(space.id))
            self.inspectorTab = .agent
            self.flash("Created \(space.name). Teach its agent what belongs here.")
        }
    }

    func rename(_ space: Space) {
        Task { [weak self] in
            guard let self else { return }
            guard let name = await SpacesUI.prompt(
                title: "Rename Space", defaultValue: space.name, confirm: "Rename", window: self.window
            ) else { return }
            guard var current = self.store.spaces.first(where: { $0.id == space.id }) else { return }
            current.name = name
            current.updatedAt = Date()
            self.store.updateSpace(current)
            self.agentDraft?.name = self.agentDraft?.spaceID == space.id ? name : (self.agentDraft?.name ?? "")
        }
    }

    func confirmDelete(_ space: Space) {
        let folders = store.spaces.filter { SpacesUI.isDescendant($0.id, of: space.id, in: store.spaces) }.count - 1
        let count = store.items(in: space.id, recursive: true).count
        var message = "\(count) item\(count == 1 ? "" : "s")"
        if folders > 0 { message += " in this Space and its \(folders) folder\(folders == 1 ? "" : "s")" }
        let keepPlace = space.parentID.map { SpacesUI.path(of: $0, in: store.spaces) } ?? "the Inbox"
        message += ". Keep them in \(keepPlace), or delete them too?"
        let id = space.id
        Task { [weak self] in
            guard let self else { return }
            let choice = await SpacesUI.confirm(
                title: "Delete “\(space.name)”?",
                message: message,
                buttons: ["Delete, Keep Items", "Delete Everything", "Cancel"],
                destructiveIndex: 1,
                window: self.window
            )
            guard let choice, choice < 2 else { return }
            if self.selection.spaceID.map({ SpacesUI.isDescendant($0, of: id, in: self.store.spaces) }) == true {
                self.select(.inbox)
            }
            let keptIn = space.parentID.map { SpacesUI.path(of: $0, in: self.store.spaces) } ?? "the Inbox"
            self.store.deleteSpace(id, keepItems: choice == 0)
            self.flash(choice == 0 ? "Deleted \(space.name); items moved to \(keptIn)" : "Deleted \(space.name)")
        }
    }

    func saveDraft() {
        guard let draft = agentDraft, let space = store.spaces.first(where: { $0.id == draft.spaceID }) else { return }
        store.updateSpace(draft.applied(to: space))
        flash("Saved \(draft.name)'s agent")
    }

    func revertDraft() {
        guard let draft = agentDraft, let space = store.spaces.first(where: { $0.id == draft.spaceID }) else { return }
        draft.load(space)
    }

    /// Nests `spaceID` inside `parentID` (nil = top level), refusing cycles.
    func nest(_ spaceID: UUID, in parentID: UUID?) {
        guard var space = store.spaces.first(where: { $0.id == spaceID }) else { return }
        if let parentID, SpacesUI.isDescendant(parentID, of: spaceID, in: store.spaces) {
            flash("A Space can't go inside itself")
            return
        }
        guard space.parentID != parentID else { return }
        space.parentID = parentID
        space.updatedAt = Date()
        store.updateSpace(space)
        if let parentID { expanded.insert(parentID) }
        flash("Moved \(space.name) to \(SpacesUI.path(of: parentID, in: store.spaces).replacingOccurrences(of: "Inbox", with: "the top level"))")
    }

    /// Puts `spaceID` just above `targetID`, among the target's siblings.
    func reorder(_ spaceID: UUID, before targetID: UUID) {
        guard spaceID != targetID, let target = store.spaces.first(where: { $0.id == targetID }) else { return }
        if let parent = target.parentID, SpacesUI.isDescendant(parent, of: spaceID, in: store.spaces) {
            flash("A Space can't go inside itself")
            return
        }
        if var space = store.spaces.first(where: { $0.id == spaceID }), space.parentID != target.parentID {
            space.parentID = target.parentID
            space.updatedAt = Date()
            store.updateSpace(space)
        }
        SpacesSidebarOrder.place(spaceID, before: targetID, among: store.spaces, personaID: store.currentPersonaID)
        objectWillChange.send()
    }

    /// A drop on a sidebar row: files/links/text are ingested into the
    /// target, dragged items move there, dragged Spaces nest or reorder.
    func handleSidebarDrop(_ providers: [NSItemProvider], on target: SpacesSidebarSelection, position: SpacesDropHint.Position) -> Bool {
        let targetSpaceID = target.spaceID
        let name = SpacesUI.path(of: targetSpaceID, in: store.spaces)
        return SpacesDropIngestor.accept(
            providers,
            into: targetSpaceID,
            store: store,
            internalHandler: { [weak self] marker in
                guard let self else { return }
                switch marker {
                case .item(let itemID):
                    self.move(itemID, to: targetSpaceID)
                case .space(let spaceID):
                    if position == .before, let targetSpaceID {
                        self.reorder(spaceID, before: targetSpaceID)
                    } else if spaceID != targetSpaceID {
                        self.nest(spaceID, in: targetSpaceID)
                    }
                }
            },
            onFiled: { [weak self] _ in
                self?.flash(targetSpaceID == nil ? "Added to the Inbox" : "Filed to \(name)")
            }
        )
    }

    // MARK: Members

    func addMember(to spaceID: UUID) {
        let name = newMemberName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = newMemberEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !email.isEmpty else { return }
        let member = SpaceMember(
            id: UUID(),
            name: name.isEmpty ? (email.split(separator: "@").first.map(String.init) ?? email) : name,
            email: email.isEmpty ? nil : email,
            role: newMemberRole,
            externalID: nil
        )
        store.addMember(member, to: spaceID)
        newMemberName = ""
        newMemberEmail = ""
        newMemberRole = .editor
    }

    func setRole(_ role: SpaceRole, for memberID: UUID, in spaceID: UUID) {
        guard var space = store.spaces.first(where: { $0.id == spaceID }),
              let index = space.members.firstIndex(where: { $0.id == memberID }) else { return }
        space.members[index].role = role
        space.updatedAt = Date()
        store.updateSpace(space)
    }

    // MARK: Ask

    static func conversationKey(_ spaceID: UUID?) -> String { spaceID?.uuidString ?? "all" }

    func conversation(for spaceID: UUID?) -> [SpacesAskExchange] {
        conversations[Self.conversationKey(spaceID)] ?? []
    }

    func ask(in spaceID: UUID?) {
        let question = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        askDraft = ""
        let key = Self.conversationKey(spaceID)
        let exchange = SpacesAskExchange(question: question)
        conversations[key, default: []].append(exchange)
        isAsking = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.store.ask(question, in: spaceID)
                self.update(exchange.id, key: key) {
                    $0.answer = answer.text
                    $0.citations = answer.citedItemIDs
                    $0.producedBy = answer.producedBy
                }
            } catch {
                AppLog.log("Spaces: ask failed: \(error.localizedDescription)")
                self.update(exchange.id, key: key) { $0.error = error.localizedDescription }
            }
            self.isAsking = false
        }
    }

    func clearConversation(for spaceID: UUID?) {
        conversations[Self.conversationKey(spaceID)] = nil
    }

    private func update(_ id: UUID, key: String, _ change: (inout SpacesAskExchange) -> Void) {
        guard var list = conversations[key], let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        conversations[key] = list
    }

    // MARK: Personas

    func newPersona() {
        Task { [weak self] in
            guard let self else { return }
            guard let name = await SpacesUI.prompt(
                title: "New Persona",
                message: "Each persona has its own Spaces on this Mac — e.g. Work, Personal, a side project.",
                confirm: "Create",
                window: self.window
            ) else { return }
            let icon = SpacesPalette.personaIcons[self.store.personas.count % SpacesPalette.personaIcons.count]
            let persona = self.store.createPersona(name: name, icon: icon)
            self.store.currentPersonaID = persona.id
        }
    }

    func renamePersona(_ persona: Persona) {
        Task { [weak self] in
            guard let self else { return }
            guard let name = await SpacesUI.prompt(
                title: "Rename Persona", defaultValue: persona.name, confirm: "Rename", window: self.window
            ) else { return }
            self.store.renamePersona(persona.id, to: name)
        }
    }

    func confirmDelete(_ persona: Persona) {
        guard store.personas.count > 1 else { return }
        Task { [weak self] in
            guard let self else { return }
            let choice = await SpacesUI.confirm(
                title: "Delete persona “\(persona.name)”?",
                message: "All of its Spaces and items are removed from this Mac. Export any Space you want to keep first.",
                buttons: ["Delete Persona", "Cancel"],
                window: self.window
            )
            guard choice == 0 else { return }
            self.store.deletePersona(persona.id)
        }
    }

    // MARK: Toolbar actions

    func newNote() {
        manualEntry = SpacesManualEntry(spaceID: selection.spaceID)
    }

    func saveManualEntry(_ entry: SpacesManualEntry) {
        guard entry.canSave else { return }
        var title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) }
                ?? entry.url?.host ?? "Note"
        }
        let item = store.addManual(title: title, text: text, url: entry.url, spaceID: entry.spaceID, kind: entry.kind)
        manualEntry = nil
        if entry.spaceID == selection.spaceID { selectedItemID = item.id }
        flash("Added to \(SpacesUI.path(of: entry.spaceID, in: store.spaces))")
    }

    func recluster() {
        guard !isReclustering else { return }
        isReclustering = true
        Task { [weak self] in
            guard let self else { return }
            await self.store.recluster()
            self.isReclustering = false
            let clusters = self.store.suggestions.filter {
                if case .createSpace = $0.action { return true }
                return false
            }.count
            self.flash(clusters == 0 ? "No new clusters found" : "\(clusters) cluster\(clusters == 1 ? "" : "s") could become a Space")
        }
    }

    func export(_ spaceID: UUID) {
        guard let space = store.spaces.first(where: { $0.id == spaceID }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Space"
        panel.message = "Exports \(space.name), its folders, agent rules, members and items as a .sparkvspace package."
        panel.allowedContentTypes = [UTType(filenameExtension: "sparkvspace") ?? .data]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.fileName(space.name) + ".sparkvspace"
        Task { [weak self] in
            let response: NSApplication.ModalResponse
            if let window = self?.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, var url = panel.url, let self else { return }
            if url.pathExtension.lowercased() != "sparkvspace" { url.appendPathExtension("sparkvspace") }
            do {
                try self.store.exportSpace(spaceID, to: url)
                self.flash("Exported \(url.lastPathComponent)")
            } catch {
                AppLog.log("Spaces: export failed: \(error.localizedDescription)")
                self.flash("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func importSpace() {
        let panel = NSOpenPanel()
        panel.title = "Import Space"
        panel.message = "Choose a .sparkvspace package someone shared with you."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        // Until the lead declares the package type, a .sparkvspace export
        // looks like a folder to the open panel.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        Task { [weak self] in
            let response: NSApplication.ModalResponse
            if let window = self?.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url, let self else { return }
            guard url.pathExtension.lowercased() == "sparkvspace" else {
                self.flash("That isn't a .sparkvspace export")
                return
            }
            do {
                let space = try self.store.importSpace(from: url)
                self.select(.space(space.id))
                self.flash("Imported \(space.name)")
            } catch {
                AppLog.log("Spaces: import failed: \(error.localizedDescription)")
                self.flash("Import failed: \(error.localizedDescription)")
            }
        }
    }

    func addApp(_ bundleID: String) {
        guard let draft = agentDraft, !draft.apps.contains(bundleID) else { return }
        draft.apps.append(bundleID)
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = true
        Task { [weak self] in
            let response: NSApplication.ModalResponse
            if let window = self?.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let self else { return }
            for url in panel.urls {
                if let bundleID = Bundle(url: url)?.bundleIdentifier { self.addApp(bundleID) }
            }
        }
    }

    // MARK: Toast

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(message.count > 60 ? 5 : 3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private static func fileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Space" : cleaned
    }
}

// MARK: - Root

private struct SpacesRootView: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        HStack(spacing: 0) {
            SpacesSidebar(model: model, store: store)
                .frame(width: 236)
            Divider().overlay(SparkVTheme.stroke)
            SpacesItemColumn(model: model, store: store)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(SparkVTheme.stroke)
            SpacesInspector(model: model, store: store)
                .frame(width: 340)
        }
        .background(SpacesPalette.background)
        .tint(SparkVTheme.red)
        .preferredColorScheme(.dark)
        .sheet(item: $model.manualEntry) { entry in
            SpacesManualEntrySheet(entry: entry, model: model, store: store)
        }
        .onChange(of: store.spaces) { _, _ in model.storeDidChange() }
        .onChange(of: store.items.map(\.id)) { _, _ in model.storeDidChange() }
        .onChange(of: store.currentPersonaID) { _, _ in model.personaDidChange() }
    }
}

// MARK: - Sidebar

private enum SpacesSidebarMetrics {
    static let rowHeight: CGFloat = 28
    static let indent: CGFloat = 14
}

private struct SpacesSidebar: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        let counts = SpacesUI.recursiveCounts(spaces: store.spaces, items: store.items)
        let rows = model.sidebarRows()
        VStack(alignment: .leading, spacing: 0) {
            SpacesPersonaPicker(model: model, store: store)
                .padding(.horizontal, 10)
                .padding(.top, 38)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SpacesSidebarInboxRow(model: model, store: store)
                        .padding(.bottom, 10)

                    HStack {
                        if !SparkVTheme.isApple {
                            Rectangle().fill(SparkVTheme.eyebrowDash).frame(width: 10, height: 1.5)
                        }
                        Text("SPACES")
                            .font(SparkVTheme.eyebrow())
                            .tracking(SparkVTheme.isApple ? 0.6 : 1.2)
                            .foregroundStyle(SpacesPalette.tertiaryText)
                        Spacer()
                        SpacesIconButton(systemImage: "plus", help: "New Space", size: 20) {
                            model.newSpace(parentID: nil)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                    .frame(height: 24)
                    // Dropping a Space on the header moves it to the top level.
                    .onDrop(of: SpacesDropIngestor.acceptedTypes, isTargeted: nil) { providers in
                        SpacesDropIngestor.accept(providers, into: nil, store: store, internalHandler: { marker in
                            if case .space(let id) = marker { model.nest(id, in: nil) }
                            if case .item(let id) = marker { model.move(id, to: nil) }
                        }, onFiled: { _ in model.flash("Added to the Inbox") })
                    }

                    if rows.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No Spaces yet")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SpacesPalette.secondaryText)
                            Text("Make one per organization, client or project. Its agent files meetings, notes, pages and files that belong there.")
                                .font(.system(size: 11))
                                .foregroundStyle(SpacesPalette.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("New Space") { model.newSpace(parentID: nil) }
                                .buttonStyle(SparkVPrimaryButtonStyle())
                                .padding(.top, 2)
                        }
                        .padding(8)
                    }

                    ForEach(rows) { row in
                        SpacesSidebarSpaceRow(
                            model: model,
                            store: store,
                            row: row,
                            count: counts[row.space.id] ?? 0
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Button {
                    model.importSpace()
                } label: {
                    Label("Import Space…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SpacesPalette.secondaryText)
                Spacer()
                Button {
                    model.newSpace(parentID: nil)
                } label: {
                    Label("New Space", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SparkVTheme.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background {
            // Apple: a translucent sidebar over the graphite window, as in Finder.
            if SparkVTheme.isApple {
                VisualEffectBackdrop(material: .sidebar).overlay(SpacesPalette.sidebar.opacity(0.55))
            } else {
                SpacesPalette.sidebar
            }
        }
    }
}

private struct SpacesPersonaPicker: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    private var persona: Persona? { store.personas.first { $0.id == store.currentPersonaID } }

    var body: some View {
        Menu {
            Section("Personas") {
                ForEach(store.personas) { persona in
                    Button {
                        store.currentPersonaID = persona.id
                    } label: {
                        if persona.id == store.currentPersonaID {
                            Label(persona.name, systemImage: "checkmark")
                        } else {
                            Text(persona.name)
                        }
                    }
                }
            }
            Divider()
            Button("New Persona…") { model.newPersona() }
            if let persona {
                Button("Rename “\(persona.name)”…") { model.renamePersona(persona) }
                Button("Delete “\(persona.name)”…") { model.confirmDelete(persona) }
                    .disabled(store.personas.count < 2)
            }
        } label: {
            HStack(spacing: 8) {
                SpacesPersonaAvatar(persona: persona, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(persona?.name ?? "Me")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SpacesPalette.primaryText)
                        .lineLimit(1)
                    Text("\(store.spaces.count) Space\(store.spaces.count == 1 ? "" : "s") · \(store.items.count) items")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SpacesPalette.tertiaryText)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
            .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch persona")
    }
}

private struct SpacesSidebarInboxRow: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let isSelected = model.selection == .inbox
        let isTargeted = model.dropHint?.target == .inbox && model.dropHint?.position == .into
        let unfiled = store.items.filter { $0.spaceID == nil }.count
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SpacesPalette.inbox)
                .frame(width: 18)
            Text("Inbox")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SpacesPalette.primaryText)
            Spacer()
            if !store.suggestions.isEmpty {
                SpacesBadge(count: store.suggestions.count)
                    .help("\(store.suggestions.count) suggestion\(store.suggestions.count == 1 ? "" : "s") to review")
            }
            if unfiled > 0 {
                Text("\(unfiled)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(SpacesPalette.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SpacesSidebarMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? SpacesPalette.selection : (hover.isOn ? SparkVTheme.surface : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SpacesPalette.accent, lineWidth: isTargeted ? 1.5 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(.inbox) }
        .onHover { hover.isOn = $0 }
        .onDrop(of: SpacesDropIngestor.acceptedTypes, delegate: SpacesSidebarDropDelegate(target: .inbox, model: model, allowsReorder: false))
    }
}

private struct SpacesSidebarSpaceRow: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    let row: SpacesSidebarRow
    let count: Int
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let space = row.space
        let isSelected = model.selection == .space(space.id)
        let hint = model.dropHint?.target == .space(space.id) ? model.dropHint?.position : nil
        let tint = SpacesUI.color(hex: space.color)
        HStack(spacing: 4) {
            Group {
                if row.hasChildren {
                    Button {
                        model.toggleExpanded(space.id)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(model.expanded.contains(space.id) ? 90 : 0))
                            .foregroundStyle(SpacesPalette.tertiaryText)
                            .frame(width: 14, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 20)
                }
            }
            SpacesIconTile(icon: space.icon, color: tint, size: 18)
            Text(space.name)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(SpacesPalette.primaryText)
                .lineLimit(1)
                .padding(.leading, 3)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(SpacesPalette.tertiaryText)
            }
            SpacesStatusDot(status: SpacesAgentStatus.of(space, store: store), size: 5)
        }
        .padding(.leading, 4 + CGFloat(row.depth) * SpacesSidebarMetrics.indent)
        .padding(.trailing, 8)
        .frame(height: SpacesSidebarMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? SpacesPalette.selection : (hover.isOn ? SparkVTheme.surface : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tint, lineWidth: hint == .into ? 1.5 : 0)
        )
        .overlay(alignment: .top) {
            if hint == .before {
                Capsule()
                    .fill(SpacesPalette.accent)
                    .frame(height: 2)
                    .padding(.leading, 4 + CGFloat(row.depth) * SpacesSidebarMetrics.indent)
                    .offset(y: -1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(.space(space.id)) }
        .onHover { hover.isOn = $0 }
        .onDrag { SpacesDropIngestor.dragProvider(spaceID: space.id) }
        .onDrop(
            of: SpacesDropIngestor.acceptedTypes,
            delegate: SpacesSidebarDropDelegate(target: .space(space.id), model: model, allowsReorder: true)
        )
        .contextMenu {
            Button("New Folder…") { model.newSpace(parentID: space.id) }
            Button("Rename…") { model.rename(space) }
            Divider()
            Button("Edit Agent") { model.edit(space.id, tab: .agent) }
            Button("Members") { model.edit(space.id, tab: .members) }
            Button("Ask This Space") { model.edit(space.id, tab: .ask) }
            Divider()
            if space.parentID != nil {
                Button("Move to Top Level") { model.nest(space.id, in: nil) }
            }
            Button("Export…") { model.export(space.id) }
            Divider()
            Button("Delete…", role: .destructive) { model.confirmDelete(space) }
        }
    }
}

/// Drops on sidebar rows: the top third of a Space row places a dragged
/// Space before it; anywhere else files into / nests inside it.
private struct SpacesSidebarDropDelegate: DropDelegate {
    let target: SpacesSidebarSelection
    let model: SpacesWindowModel
    let allowsReorder: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: SpacesDropIngestor.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if model.dropHint?.target == target { model.dropHint = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let position = self.position(info)
        model.dropHint = nil
        let providers = info.itemProviders(for: SpacesDropIngestor.acceptedTypes)
        return model.handleSidebarDrop(providers, on: target, position: position)
    }

    private func position(_ info: DropInfo) -> SpacesDropHint.Position {
        allowsReorder && info.location.y < SpacesSidebarMetrics.rowHeight * 0.3 ? .before : .into
    }

    private func update(_ info: DropInfo) {
        let hint = SpacesDropHint(target: target, position: position(info))
        if model.dropHint != hint { model.dropHint = hint }
    }
}

// MARK: - Item column

private struct SpacesItemColumn: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        let items = model.visibleItems()
        VStack(spacing: 0) {
            SpacesItemHeader(model: model, store: store, count: items.count)
                .padding(.horizontal, 18)
                .padding(.top, 30)
                .padding(.bottom, 10)
            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.selection == .inbox, model.searchResults == nil, !store.suggestions.isEmpty {
                        SpacesSuggestionsSection(model: model, store: store)
                            .padding(.bottom, 10)
                    }
                    if items.isEmpty {
                        SpacesItemsEmptyState(model: model, store: store)
                            .padding(.top, 60)
                    } else {
                        if model.selection == .inbox, model.searchResults == nil, !store.suggestions.isEmpty {
                            SpacesSectionHeader(title: "Unfiled")
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                        }
                        ForEach(items) { item in
                            SpacesItemRow(
                                model: model,
                                store: store,
                                item: item,
                                showsSpace: model.selection == .inbox ? model.searchResults != nil : (model.searchEverywhere || item.spaceID != model.selection.spaceID)
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(SparkVTheme.background))
                    .overlay(Capsule().strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.toast)
        .background(SpacesPalette.background)
        // Files dropped anywhere on the list go into the current selection.
        .onDrop(of: [.fileURL, .image, .url], isTargeted: nil) { providers in
            let target = model.selection.spaceID
            return SpacesDropIngestor.accept(providers, into: target, store: store, onFiled: { _ in
                model.flash("Added to \(SpacesUI.path(of: target, in: store.spaces))")
            })
        }
    }
}

private struct SpacesItemHeader: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let space = model.selectedSpace {
                    SpacesIconTile(icon: space.icon, color: SpacesUI.color(hex: space.color), size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(space.name)
                            .font(SparkVTheme.title(17))
                            .tracking(-0.4)
                            .foregroundStyle(SpacesPalette.primaryText)
                            .lineLimit(1)
                        Text(subtitle(for: space))
                            .font(.system(size: 11))
                            .foregroundStyle(SpacesPalette.tertiaryText)
                            .lineLimit(1)
                    }
                } else {
                    SpacesIconTile(icon: "tray.full.fill", color: SpacesPalette.inbox, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Inbox")
                            .font(SparkVTheme.title(17))
                            .tracking(-0.4)
                            .foregroundStyle(SpacesPalette.primaryText)
                        Text("Unfiled items and the agents' suggestions")
                            .font(.system(size: 11))
                            .foregroundStyle(SpacesPalette.tertiaryText)
                    }
                }
                Spacer(minLength: 8)
                toolbar
            }

            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                    TextField(searchPlaceholder, text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if model.isSearching {
                        ProgressView().controlSize(.mini)
                    }
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(SpacesPalette.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SparkVTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))

                Toggle(isOn: $model.searchEverywhere) {
                    Text("All Spaces").font(.system(size: 11))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Search every Space instead of only the selection")

                kindMenu
                sourceMenu
            }

            HStack(spacing: 6) {
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(SpacesPalette.tertiaryText)
                if model.isFiltering {
                    Button("Clear Filters") {
                        model.kindFilter = nil
                        model.sourceFilter = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SpacesPalette.accent)
                }
                Spacer()
                if model.selectedSpace != nil, !store.children(of: model.selection.spaceID).isEmpty {
                    Toggle("Include folders", isOn: $model.includeSubfolders)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 11))
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            SpacesIconButton(systemImage: "square.and.pencil", help: "New Note (title, text, link)", size: 28) {
                model.newNote()
            }
            Group {
                if model.isReclustering {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    SpacesIconButton(systemImage: "sparkles", help: "Recluster: look for groups of items that could become a Space", size: 28) {
                        model.recluster()
                    }
                }
            }
            SpacesIconButton(systemImage: "square.and.arrow.up", help: "Export this Space as a .sparkvspace package", size: 28) {
                if let id = model.selection.spaceID { model.export(id) }
            }
            .disabled(model.selection.spaceID == nil)
            .opacity(model.selection.spaceID == nil ? 0.4 : 1)
            SpacesIconButton(systemImage: "square.and.arrow.down", help: "Import a .sparkvspace package", size: 28) {
                model.importSpace()
            }
        }
    }

    private var kindMenu: some View {
        Menu {
            Button {
                model.kindFilter = nil
            } label: {
                if model.kindFilter == nil { Label("All Kinds", systemImage: "checkmark") } else { Text("All Kinds") }
            }
            Divider()
            ForEach(SpaceItemKind.allCases, id: \.self) { kind in
                Button {
                    model.kindFilter = kind
                } label: {
                    if model.kindFilter == kind {
                        Label(SpacesUI.label(for: kind), systemImage: "checkmark")
                    } else {
                        Label(SpacesUI.label(for: kind), systemImage: SpacesUI.symbol(for: kind))
                    }
                }
            }
        } label: {
            filterLabel(model.kindFilter.map { SpacesUI.label(for: $0) } ?? "Kind", active: model.kindFilter != nil)
        }
        .menuStyle(.button)
            .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                model.sourceFilter = nil
            } label: {
                if model.sourceFilter == nil { Label("All Sources", systemImage: "checkmark") } else { Text("All Sources") }
            }
            Divider()
            ForEach(SpacesUI.allSources, id: \.self) { source in
                Button {
                    model.sourceFilter = source
                } label: {
                    if model.sourceFilter == source {
                        Label(SpacesUI.label(for: source), systemImage: "checkmark")
                    } else {
                        Label(SpacesUI.label(for: source), systemImage: SpacesUI.symbol(for: source))
                    }
                }
            }
        } label: {
            filterLabel(model.sourceFilter.map { SpacesUI.label(for: $0) } ?? "Source", active: model.sourceFilter != nil)
        }
        .menuStyle(.button)
            .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func filterLabel(_ title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(active ? SpacesPalette.accent : SpacesPalette.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? SpacesPalette.accent.opacity(0.14) : SparkVTheme.surface)
        )
    }

    private var searchPlaceholder: String {
        if model.searchEverywhere { return "Search all Spaces" }
        return model.selectedSpace.map { "Search \($0.name)" } ?? "Search the Inbox"
    }

    private var countLabel: String {
        let noun = count == 1 ? "item" : "items"
        if model.searchResults != nil { return "\(count) \(noun) match “\(model.query)”" }
        return "\(count) \(noun)"
    }

    private func subtitle(for space: Space) -> String {
        var parts: [String] = []
        if space.parentID != nil { parts.append(SpacesUI.path(of: space.parentID, in: store.spaces)) }
        if !space.members.isEmpty { parts.append("\(space.members.count) member\(space.members.count == 1 ? "" : "s")") }
        parts.append(SpacesUI.hasRules(space.rules) ? "Agent auto-filing" : "Agent has no rules yet")
        return parts.joined(separator: " · ")
    }
}

private struct SpacesItemRow: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    let item: SpaceItem
    let showsSpace: Bool
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let isSelected = model.selectedItemID == item.id
        HStack(alignment: .top, spacing: 10) {
            SpacesKindIcon(kind: item.kind, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SpacesPalette.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    SpacesConfidenceBadge(confidence: item.filingConfidence)
                    Text(SpacesUI.relativeDate(item.createdAt))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(SpacesPalette.tertiaryText)
                }
                HStack(spacing: 5) {
                    Image(systemName: SpacesUI.symbol(for: item.source)).font(.system(size: 9.5))
                    Text(SpacesUI.label(for: item.source))
                    if showsSpace {
                        Text("·")
                        Text(SpacesUI.path(of: item.spaceID, in: store.spaces)).lineLimit(1)
                    }
                    if let host = SpacesUI.displayHost(of: item.url) {
                        Text("·")
                        Text(host).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(SpacesPalette.secondaryText)
                if !item.entities.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(item.entities.prefix(4).enumerated()), id: \.offset) { _, entity in
                            SpacesChip(text: entity)
                        }
                        if item.entities.count > 4 {
                            Text("+\(item.entities.count - 4)")
                                .font(.system(size: 10))
                                .foregroundStyle(SpacesPalette.tertiaryText)
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? SpacesPalette.accent.opacity(0.16) : (hover.isOn ? Color.white.opacity(0.035) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SpacesPalette.accent.opacity(isSelected ? 0.45 : 0), lineWidth: 0.75)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedItemID = item.id }
        .onHover { hover.isOn = $0 }
        .onDrag { SpacesDropIngestor.dragProvider(itemID: item.id) }
        .contextMenu {
            if item.url != nil {
                Button("Open Original") { model.openOriginal(item) }
            }
            SpacesMoveMenu(model: model, item: item)
            Button("Rename…") { model.rename(item) }
            Button("Copy Text") { SpacesUI.copy(item.text.isEmpty ? item.title : item.text) }
            Divider()
            Button("Delete…", role: .destructive) { model.confirmDelete(item) }
        }
    }
}

private struct SpacesMoveMenu: View {
    @ObservedObject var model: SpacesWindowModel
    let item: SpaceItem
    var title = "Move to"

    var body: some View {
        Menu(title) {
            Button {
                model.move(item.id, to: nil)
            } label: {
                Label("Inbox", systemImage: item.spaceID == nil ? "checkmark" : "tray")
            }
            .disabled(item.spaceID == nil)
            Divider()
            ForEach(model.allSpacesFlattened(), id: \.space.id) { entry in
                Button {
                    model.move(item.id, to: entry.space.id)
                } label: {
                    let name = String(repeating: "    ", count: entry.depth) + entry.space.name
                    if item.spaceID == entry.space.id {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
                .disabled(item.spaceID == entry.space.id)
            }
        }
    }
}

private struct SpacesItemsEmptyState: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(SpacesPalette.tertiaryText)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SpacesPalette.secondaryText)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(SpacesPalette.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if model.searchResults == nil, !model.isFiltering {
                Button("New Note") { model.newNote() }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var symbol: String {
        if model.searchResults != nil || model.isFiltering { return "magnifyingglass" }
        return model.selection == .inbox ? "tray" : "square.stack.3d.up"
    }

    private var title: String {
        if model.searchResults != nil { return "No matches" }
        if model.isFiltering { return "Nothing matches these filters" }
        return model.selection == .inbox ? "Inbox zero" : "Nothing here yet"
    }

    private var detail: String {
        if model.searchResults != nil { return "Try other words, or search all Spaces." }
        if model.isFiltering { return "Clear the kind or source filter to see everything." }
        if model.selection == .inbox {
            return "Everything the agents captured has been filed. Items they aren't sure about wait here."
        }
        return "Drop files, links or text here, add a note, or give the agent keywords, people and domains so it files new items here."
    }
}

// MARK: - Suggestions

private struct SpacesSuggestionsSection: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpacesSectionHeader(title: "Suggestions")
                .padding(.horizontal, 8)
            ForEach(store.suggestions) { suggestion in
                SpacesSuggestionCard(model: model, store: store, suggestion: suggestion)
            }
        }
    }
}

private struct SpacesSuggestionCard: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    let suggestion: SpaceSuggestion
    var compact = false

    var body: some View {
        switch suggestion.action {
        case .file(let itemID, let spaceID, let confidence, let reason):
            let item = store.items.first { $0.id == itemID }
            let space = store.spaces.first { $0.id == spaceID }
            card(
                icon: space?.icon ?? "folder.fill",
                tint: space.map { SpacesUI.color(hex: $0.color) } ?? SpacesPalette.accent,
                title: compact
                    ? "File to \(space?.name ?? "a Space")"
                    : "File “\(item?.title ?? "an item")” to \(space?.name ?? "a Space")",
                detail: reason,
                confidence: confidence,
                acceptTitle: "File",
                onTitleTap: compact ? nil : { model.selectedItemID = itemID }
            )
        case .createSpace(let name, let itemIDs, let reason):
            let titles = itemIDs.compactMap { id in store.items.first { $0.id == id }?.title }
            card(
                icon: "sparkles",
                tint: SpacesPalette.warning,
                title: "Create Space “\(name)” from \(itemIDs.count) item\(itemIDs.count == 1 ? "" : "s")",
                detail: titles.isEmpty ? reason : reason + (reason.isEmpty ? "" : " · ") + titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? "…" : ""),
                confidence: nil,
                acceptTitle: "Create Space",
                onTitleTap: nil
            )
        }
    }

    private func card(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        confidence: Double?,
        acceptTitle: String,
        onTitleTap: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SpacesIconTile(icon: icon, color: tint, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SpacesPalette.primaryText)
                        .lineLimit(2)
                        .onTapGesture { onTitleTap?() }
                    SpacesConfidenceBadge(confidence: confidence)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SpacesPalette.secondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Button(acceptTitle) {
                        store.accept(suggestion)
                        model.flash(acceptTitle == "File" ? "Filed" : "Space created")
                    }
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .controlSize(.small)
                    Button("Dismiss") { store.dismiss(suggestion) }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .controlSize(.small)
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 0.75))
    }
}

// MARK: - Inspector

private struct SpacesInspector: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        Group {
            if let item = model.selectedItem {
                SpacesItemDetail(model: model, store: store, item: item)
            } else if let space = model.selectedSpace, let draft = model.agentDraft, draft.spaceID == space.id {
                SpacesAgentPanel(model: model, store: store, draft: draft, space: space)
            } else {
                SpacesInboxPanel(model: model, store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SpacesPalette.inspector)
    }
}

// MARK: Item detail

private struct SpacesItemDetail: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    let item: SpaceItem

    private var itemSuggestions: [SpaceSuggestion] {
        store.suggestions.filter {
            if case .file(let itemID, _, _, _) = $0.action { return itemID == item.id }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SpacesKindIcon(kind: item.kind, size: 22)
                Text(SpacesUI.label(for: item.kind).uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(SpacesPalette.secondaryText)
                Spacer()
                if item.url != nil {
                    SpacesIconButton(systemImage: "arrow.up.right.square", help: "Open the original") {
                        model.openOriginal(item)
                    }
                }
                SpacesIconButton(systemImage: "pencil", help: "Rename") {
                    model.rename(item)
                }
                SpacesIconButton(systemImage: "xmark", help: model.selectedSpace == nil ? "Close" : "Back to the Space's agent") {
                    model.selectedItemID = nil
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SpacesPalette.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    meta

                    ForEach(itemSuggestions) { suggestion in
                        SpacesSuggestionCard(model: model, store: store, suggestion: suggestion, compact: true)
                    }

                    SpacesAttachmentPreview(item: item)

                    if let url = item.url {
                        originalLink(url)
                    }

                    if !item.entities.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SpacesSectionHeader(title: "Entities")
                            SpacesFlowLayout(spacing: 4, lineSpacing: 4) {
                                ForEach(Array(item.entities.enumerated()), id: \.offset) { _, entity in
                                    SpacesChip(text: entity, symbol: Self.entitySymbol(entity))
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SpacesSectionHeader(title: "Tags")
                        VStack(alignment: .leading, spacing: 6) {
                            if !item.tags.isEmpty {
                                SpacesFlowLayout(spacing: 4, lineSpacing: 4) {
                                    ForEach(item.tags, id: \.self) { tag in
                                        SpacesChip(text: "#" + tag, tint: SpacesPalette.accent) {
                                            model.removeTag(tag, from: item)
                                        }
                                    }
                                }
                            }
                            TextField("Add a tag…", text: $model.tagInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .onSubmit { model.addTags(to: item) }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))
                    }

                    if !item.text.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SpacesSectionHeader(
                                title: "Text",
                                trailing: AnyView(
                                    Button("Copy") { SpacesUI.copy(item.text) }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(SpacesPalette.accent)
                                )
                            )
                            SpacesCard {
                                Text(item.text.count > 20_000 ? String(item.text.prefix(20_000)) + "…" : item.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(SpacesPalette.primaryText.opacity(0.85))
                                    .lineSpacing(2)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Delete Item…", role: .destructive) { model.confirmDelete(item) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SparkVTheme.destructive)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: SpacesUI.symbol(for: item.source))
                Text(SpacesUI.label(for: item.source))
                Text("·")
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(SpacesPalette.secondaryText)

            HStack(spacing: 6) {
                Menu {
                    SpacesMoveMenuItems(model: model, item: item)
                } label: {
                    HStack(spacing: 5) {
                        if let space = store.spaces.first(where: { $0.id == item.spaceID }) {
                            SpacesIconTile(icon: space.icon, color: SpacesUI.color(hex: space.color), size: 16)
                        } else {
                            Image(systemName: "tray").font(.system(size: 10))
                        }
                        Text(SpacesUI.path(of: item.spaceID, in: store.spaces))
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(SpacesPalette.primaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SparkVTheme.surface))
                }
                .menuStyle(.button)
            .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Move to another Space")

                if let confidence = item.filingConfidence {
                    Text("Filed by agent · \(Int((confidence * 100).rounded()))% sure")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                } else if item.spaceID != nil {
                    Text("Filed by hand")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                }
            }
        }
    }

    private func originalLink(_ url: URL) -> some View {
        let isMeeting = SpacesUI.meetingID(from: url) != nil
        return SpacesCard(padding: 10) {
            HStack(spacing: 8) {
                Image(systemName: isMeeting ? "person.2.wave.2" : (url.isFileURL ? "doc" : "link"))
                    .font(.system(size: 12))
                    .foregroundStyle(SpacesPalette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isMeeting ? "Meeting notes" : (url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SpacesPalette.primaryText)
                        .lineLimit(1)
                    Text(isMeeting ? "Minutes, transcript and answers in SparkV" : (url.isFileURL ? url.deletingLastPathComponent().path : url.absoluteString))
                        .font(.system(size: 10.5))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if url.isFileURL {
                    SpacesIconButton(systemImage: "folder", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                SpacesIconButton(systemImage: "arrow.up.right", help: isMeeting ? "Open in Meeting Notes" : "Open") {
                    model.open(url)
                }
            }
        }
    }

    static func entitySymbol(_ entity: String) -> String? {
        if entity.contains("@") { return "envelope" }
        if entity.contains("."), !entity.contains(" ") { return "globe" }
        return nil
    }
}

/// The "Move to" entries without the enclosing Menu (for custom labels).
private struct SpacesMoveMenuItems: View {
    @ObservedObject var model: SpacesWindowModel
    let item: SpaceItem

    var body: some View {
        Button("Inbox") { model.move(item.id, to: nil) }
            .disabled(item.spaceID == nil)
        Divider()
        ForEach(model.allSpacesFlattened(), id: \.space.id) { entry in
            Button(String(repeating: "    ", count: entry.depth) + entry.space.name) {
                model.move(item.id, to: entry.space.id)
            }
            .disabled(item.spaceID == entry.space.id)
        }
    }
}

@MainActor
private final class SpacesPreviewLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    private var loadedURL: URL?

    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        loadedURL = url
        image = nil
        guard let url else { return }
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> Data? in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 40 * 1024 * 1024 else { return nil }
                return try? Data(contentsOf: url)
            }.value
            guard let self, self.loadedURL == url else { return }
            self.image = data.flatMap { NSImage(data: $0) }
        }
    }
}

private struct SpacesAttachmentPreview: View {
    let item: SpaceItem
    @StateObject private var loader = SpacesPreviewLoader()

    private var attachmentURL: URL? { SpaceStore.shared.attachmentURL(for: item) }

    private var isImage: Bool {
        guard let url = attachmentURL else { return false }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    var body: some View {
        Group {
            if let url = attachmentURL {
                if isImage {
                    Group {
                        if let image = loader.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(SpacesPalette.card)
                                .frame(height: 120)
                                .overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .help("Double-click to open")
                } else {
                    SpacesCard(padding: 10) {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data))
                                .resizable()
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(SpacesPalette.primaryText)
                                    .lineLimit(1)
                                Text("Saved copy")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(SpacesPalette.tertiaryText)
                            }
                            Spacer(minLength: 4)
                            SpacesIconButton(systemImage: "eye", help: "Open the saved copy") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .task(id: isImage ? attachmentURL : nil) {
            loader.load(isImage ? attachmentURL : nil)
        }
    }
}

// MARK: Agent panel

private struct SpacesAgentPanel: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    @ObservedObject var draft: SpacesAgentDraft
    let space: Space

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 12)

            Picker("", selection: $model.inspectorTab) {
                ForEach(SpacesInspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            switch model.inspectorTab {
            case .agent:
                SpacesAgentRulesView(model: model, store: store, draft: draft, space: space)
            case .members:
                SpacesMembersView(model: model, store: store, space: space)
            case .ask:
                SpacesAskView(model: model, store: store, spaceID: space.id, placeholder: "Ask \(space.name)…")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Icon") {
                    ForEach(SpacesPalette.spaceIcons, id: \.self) { icon in
                        Button {
                            draft.icon = icon
                        } label: {
                            Label(icon, systemImage: icon)
                        }
                    }
                }
            } label: {
                SpacesIconTile(icon: draft.icon, color: SpacesUI.color(hex: draft.color), size: 38)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change icon")

            VStack(alignment: .leading, spacing: 5) {
                TextField("Space name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SpacesPalette.primaryText)
                HStack(spacing: 5) {
                    ForEach(SpacesPalette.spaceColors, id: \.self) { hex in
                        Circle()
                            .fill(SpacesUI.color(hex: hex))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle().strokeBorder(Color.white, lineWidth: draft.color.lowercased() == hex.lowercased() ? 1.5 : 0)
                            )
                            .onTapGesture { draft.color = hex }
                    }
                }
            }
        }
    }
}

private struct SpacesMemorySummary {
    let total: Int
    let autoFiled: Int
    let lastAdded: Date?
    let topEntities: [String]
    let kinds: [(kind: SpaceItemKind, count: Int)]
    let recentTitles: [String]

    init(items: [SpaceItem]) {
        total = items.count
        autoFiled = items.filter { $0.filingConfidence != nil }.count
        lastAdded = items.map(\.createdAt).max()
        var entityCounts: [String: Int] = [:]
        for item in items { for entity in Set(item.entities) { entityCounts[entity, default: 0] += 1 } }
        topEntities = entityCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(10).map(\.key)
        var kindCounts: [SpaceItemKind: Int] = [:]
        for item in items { kindCounts[item.kind, default: 0] += 1 }
        kinds = kindCounts.sorted { $0.value > $1.value }.map { (kind: $0.key, count: $0.value) }
        recentTitles = items.sorted { $0.createdAt > $1.createdAt }.prefix(3).map(\.title)
    }
}

private struct SpacesAgentRulesView: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    @ObservedObject var draft: SpacesAgentDraft
    let space: Space

    var body: some View {
        let isDirty = draft.isDirty(comparedTo: space)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    memory
                    aboutSection
                    SpacesTokenEditor(
                        title: "Keywords",
                        symbol: "text.magnifyingglass",
                        placeholder: "Project names, products, codes…",
                        tokens: $draft.keywords,
                        input: $draft.keywordInput
                    )
                    SpacesTokenEditor(
                        title: "People",
                        symbol: "person",
                        placeholder: "Names or emails",
                        tokens: $draft.people,
                        input: $draft.peopleInput
                    )
                    SpacesTokenEditor(
                        title: "Domains",
                        symbol: "globe",
                        placeholder: "acme.com, client.io",
                        tokens: $draft.domains,
                        input: $draft.domainInput,
                        normalize: SpacesAgentDraft.normalizeDomain
                    )
                    appsSection
                    thresholdSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            if isDirty {
                Divider().opacity(0.5)
                HStack {
                    Text("Unsaved changes")
                        .font(.system(size: 11))
                        .foregroundStyle(SpacesPalette.secondaryText)
                    Spacer()
                    Button("Revert") { model.revertDraft() }
                        .controlSize(.small)
                    Button("Save") { model.saveDraft() }
                        .buttonStyle(SparkVPrimaryButtonStyle())
                        .controlSize(.small)
                        .keyboardShortcut("s", modifiers: .command)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SpacesPalette.sidebar)
            }
        }
    }

    private var memory: some View {
        let summary = SpacesMemorySummary(items: store.items(in: space.id, recursive: true))
        let record = store.memoryRecord(of: space.id)
        let isRefreshing = model.refreshingMemoryID == space.id
        return VStack(alignment: .leading, spacing: 6) {
            SpacesSectionHeader(
                title: "Memory",
                trailing: summary.total == 0 ? nil : AnyView(
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button("Refresh") { model.refreshMemory(of: space.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SpacesPalette.accent)
                                .help("Rewrite the agent's summary of this Space on this Mac")
                        }
                    }
                )
            )
            SpacesCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let record, !record.summary.isEmpty {
                        Text(record.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(SpacesPalette.primaryText.opacity(0.88))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(record.producedBy) · \(SpacesUI.relativeDate(record.updatedAt)) · \(record.itemCount) items")
                            .font(.system(size: 9.5))
                            .foregroundStyle(SpacesPalette.tertiaryText)
                    }
                    if summary.total == 0 {
                        Text("Nothing filed yet. The agent learns what belongs here from the rules below and from what you file by hand.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SpacesPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        if record == nil || record?.summary.isEmpty == true {
                            Text(memorySentence(summary))
                                .font(.system(size: 12))
                                .foregroundStyle(SpacesPalette.primaryText.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !summary.kinds.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(summary.kinds.prefix(5), id: \.kind) { entry in
                                    HStack(spacing: 3) {
                                        Image(systemName: SpacesUI.symbol(for: entry.kind))
                                            .foregroundStyle(SpacesUI.tint(for: entry.kind))
                                        Text("\(entry.count)")
                                    }
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(SpacesPalette.secondaryText)
                                    .help(SpacesUI.label(for: entry.kind))
                                }
                            }
                        }
                        if !summary.topEntities.isEmpty {
                            SpacesFlowLayout(spacing: 4, lineSpacing: 4) {
                                ForEach(summary.topEntities, id: \.self) { entity in
                                    SpacesChip(text: entity, symbol: SpacesItemDetail.entitySymbol(entity))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func memorySentence(_ summary: SpacesMemorySummary) -> String {
        var text = "Knows \(summary.total) item\(summary.total == 1 ? "" : "s")"
        if summary.autoFiled > 0 { text += ", \(summary.autoFiled) filed automatically" }
        text += "."
        if let last = summary.lastAdded { text += " Last added \(SpacesUI.relativeDate(last).lowercased())." }
        if !summary.recentTitles.isEmpty {
            text += " Recent: " + summary.recentTitles.map { "“\($0)”" }.joined(separator: ", ") + "."
        }
        return text
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpacesSectionHeader(title: "About")
            ZStack(alignment: .topLeading) {
                if draft.about.isEmpty {
                    Text("Describe this Space in a sentence or two — who it's for, what it covers. The agent matches new items against it.")
                        .font(.system(size: 12))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.about)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(SpacesPalette.primaryText)
            }
            .frame(height: 72)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpacesSectionHeader(
                title: "Apps",
                trailing: AnyView(
                    Menu {
                        Section("Running Apps") {
                            ForEach(runningApps, id: \.bundleID) { app in
                                Button(app.name) { model.addApp(app.bundleID) }
                                    .disabled(draft.apps.contains(app.bundleID))
                            }
                        }
                        Divider()
                        Button("Choose from Applications…") { model.chooseApp() }
                    } label: {
                        Label("Add App", systemImage: "plus")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .menuStyle(.button)
            .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(SpacesPalette.accent)
                )
            )
            if draft.apps.isEmpty {
                Text("Screenshots and copies from these apps are filed here.")
                    .font(.system(size: 11))
                    .foregroundStyle(SpacesPalette.tertiaryText)
            } else {
                VStack(spacing: 2) {
                    ForEach(draft.apps, id: \.self) { bundleID in
                        let info = SpacesUI.appInfo(for: bundleID)
                        HStack(spacing: 8) {
                            if let icon = info.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed").frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(info.name).font(.system(size: 12))
                                    .foregroundStyle(SpacesPalette.primaryText)
                                Text(bundleID).font(.system(size: 9.5))
                                    .foregroundStyle(SpacesPalette.tertiaryText)
                            }
                            Spacer()
                            SpacesIconButton(systemImage: "minus.circle", help: "Remove", size: 20) {
                                draft.apps.removeAll { $0 == bundleID }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(SparkVTheme.surface))
                    }
                }
            }
        }
    }

    private var runningApps: [(name: String, bundleID: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return (name: app.localizedName ?? id, bundleID: id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpacesSectionHeader(title: "Auto-file")
            HStack(spacing: 10) {
                Slider(value: $draft.threshold, in: 0.5...1.0, step: 0.05)
                    .controlSize(.small)
                Text("\(Int((draft.threshold * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SpacesPalette.primaryText)
                    .frame(width: 38, alignment: .trailing)
            }
            Text(draft.threshold >= 0.999
                 ? "Never files on its own; every match becomes a suggestion in the Inbox."
                 : "Files on its own when at least \(Int((draft.threshold * 100).rounded()))% sure. Less certain matches wait in the Inbox as suggestions.")
                .font(.system(size: 11))
                .foregroundStyle(SpacesPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SpacesTokenEditor: View {
    let title: String
    let symbol: String
    let placeholder: String
    @Binding var tokens: [String]
    @Binding var input: String
    var normalize: (String) -> String = { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpacesSectionHeader(title: title)
            VStack(alignment: .leading, spacing: 6) {
                if !tokens.isEmpty {
                    SpacesFlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(tokens, id: \.self) { token in
                            SpacesChip(text: token, symbol: symbol, tint: Color.white.opacity(0.8)) {
                                tokens.removeAll { $0 == token }
                            }
                        }
                    }
                }
                TextField(placeholder, text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { commit() }
                    .onChange(of: input) { _, newValue in
                        if newValue.contains(",") || newValue.contains("\n") { commit() }
                    }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))
        }
    }

    private func commit() {
        var text = input
        var list = tokens
        SpacesAgentDraft.addTokens(from: &text, to: &list, normalize: normalize)
        tokens = list
        input = text
    }
}

// MARK: Members

private struct SpacesMembersView: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    let space: Space

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SpacesSectionHeader(title: "\(space.members.count) Member\(space.members.count == 1 ? "" : "s")")
                    if space.members.isEmpty {
                        Text("Only you, for now. Add the people who work on this with you; they come along when you export the Space.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SpacesPalette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(space.members) { member in
                        memberRow(member)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SpacesSectionHeader(title: "Add Member")
                    SpacesCard(padding: 10) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $model.newMemberName)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                            TextField("Email (optional)", text: $model.newMemberEmail)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .onSubmit { model.addMember(to: space.id) }
                            HStack {
                                Picker("Role", selection: $model.newMemberRole) {
                                    ForEach(SpaceRole.allCases, id: \.self) { role in
                                        Text(Self.label(role)).tag(role)
                                    }
                                }
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .fixedSize()
                                Spacer()
                                Button("Add") { model.addMember(to: space.id) }
                                    .buttonStyle(SparkVPrimaryButtonStyle())
                                    .controlSize(.small)
                                    .disabled(model.newMemberName.trimmingCharacters(in: .whitespaces).isEmpty
                                              && model.newMemberEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SpacesSectionHeader(title: "Sharing")
                    Text("Spaces stay on this Mac. To share one, export it and send the .sparkvspace file; the other person imports it into their own persona. Live sync is coming later.")
                        .font(.system(size: 11))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.export(space.id)
                    } label: {
                        Label("Export \(space.name)…", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func memberRow(_ member: SpaceMember) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(SpacesUI.color(hex: space.color).opacity(0.25))
                Text(Self.initials(member.name))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SpacesUI.color(hex: space.color))
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(member.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SpacesPalette.primaryText)
                    .lineLimit(1)
                if let email = member.email {
                    Text(email)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(SpaceRole.allCases, id: \.self) { role in
                    Button {
                        model.setRole(role, for: member.id, in: space.id)
                    } label: {
                        if member.role == role { Label(Self.label(role), systemImage: "checkmark") } else { Text(Self.label(role)) }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(Self.label(member.role))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SpacesPalette.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(Capsule().fill(SparkVTheme.surface))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            SpacesIconButton(systemImage: "xmark", help: "Remove \(member.name)", size: 20) {
                store.removeMember(member.id, from: space.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
    }

    static func label(_ role: SpaceRole) -> String {
        switch role {
        case .owner: return "Owner"
        case .editor: return "Editor"
        case .viewer: return "Viewer"
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map { String($0) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

// MARK: Ask

private struct SpacesAskView: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore
    let spaceID: UUID?
    let placeholder: String

    var body: some View {
        let exchanges = model.conversation(for: spaceID)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if exchanges.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 20))
                                    .foregroundStyle(SpacesPalette.tertiaryText)
                                Text("Ask about anything filed here — decisions, dates, who said what. Answers are written on this Mac and cite the items they come from.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(SpacesPalette.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                // Starter questions, like a notebook guide.
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(starters, id: \.self) { question in
                                        Button {
                                            model.askDraft = question
                                            model.ask(in: spaceID)
                                        } label: {
                                            Label(question, systemImage: "sparkle")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(SpacesPalette.accent)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Capsule().fill(SpacesPalette.accent.opacity(0.1)))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(model.isAsking)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .padding(.top, 8)
                        }
                        ForEach(exchanges) { exchange in
                            exchangeView(exchange).id(exchange.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: exchanges.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: exchanges.last?.answer) { _, _ in
                    if let id = exchanges.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }

            Divider().opacity(0.5)
            HStack(spacing: 6) {
                TextField(placeholder, text: $model.askDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...4)
                    .onSubmit { model.ask(in: spaceID) }
                if model.isAsking {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.ask(in: spaceID)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(model.askDraft.trimmingCharacters(in: .whitespaces).isEmpty ? SpacesPalette.tertiaryText : SpacesPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.askDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SparkVTheme.surface))
            .padding(12)
            if !exchanges.isEmpty {
                Button("Clear conversation") { model.clearConversation(for: spaceID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SpacesPalette.tertiaryText)
                    .padding(.bottom, 8)
            }
        }
    }

    private var starters: [String] {
        spaceID == nil
            ? ["What happened this week?", "What tasks are still open?", "Which deadlines are coming up?"]
            : ["Summarize this Space", "What was decided?", "What are the open tasks and dates?"]
    }

    private func exchangeView(_ exchange: SpacesAskExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 30)
                Text(exchange.question)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SparkVTheme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SpacesPalette.accent.opacity(0.35)))
                    .textSelection(.enabled)
            }
            if let error = exchange.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SpacesPalette.warning)
            } else if let answer = exchange.answer {
                VStack(alignment: .leading, spacing: 8) {
                    Text(answer)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SpacesPalette.primaryText)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !exchange.citations.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(exchange.citations.enumerated()), id: \.offset) { index, itemID in
                                citation(index: index + 1, itemID: itemID)
                            }
                        }
                    }
                    if let producedBy = exchange.producedBy, !producedBy.isEmpty {
                        Text(producedBy)
                            .font(.system(size: 9.5))
                            .foregroundStyle(SpacesPalette.tertiaryText)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the Space…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SpacesPalette.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func citation(index: Int, itemID: UUID) -> some View {
        if let item = store.items.first(where: { $0.id == itemID }) {
            Button {
                model.reveal(itemID: itemID)
            } label: {
                HStack(spacing: 6) {
                    Text("\(index)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(SpacesPalette.accent)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(SpacesPalette.accent.opacity(0.18)))
                    Image(systemName: SpacesUI.symbol(for: item.kind))
                        .font(.system(size: 10))
                        .foregroundStyle(SpacesUI.tint(for: item.kind))
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SpacesPalette.primaryText.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SparkVTheme.surface))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this item")
        }
    }
}

// MARK: Inbox panel

private struct SpacesInboxPanel: View {
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        let unfiled = store.items.filter { $0.spaceID == nil }.count
        let fileSuggestions = store.suggestions.filter { if case .file = $0.action { return true }; return false }.count
        let clusters = store.suggestions.count - fileSuggestions
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SpacesIconTile(icon: "sparkles", color: SpacesPalette.accent, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Space agents")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SpacesPalette.primaryText)
                        Text(store.isIndexing ? "Filing new items…" : "\(store.spaces.count) agent\(store.spaces.count == 1 ? "" : "s") watching")
                            .font(.system(size: 11))
                            .foregroundStyle(SpacesPalette.tertiaryText)
                    }
                }
                HStack(spacing: 8) {
                    stat("\(unfiled)", "unfiled")
                    stat("\(fileSuggestions)", "to review")
                    stat("\(clusters)", "new clusters")
                }
                Text("Each Space's agent files meetings, notes, pages, mail and screenshots that match its rules. What they aren't sure about waits here.")
                    .font(.system(size: 11))
                    .foregroundStyle(SpacesPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button {
                        model.rerouteInbox()
                    } label: {
                        Label(model.isRerouting ? "Matching…" : "Match Inbox to Spaces", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(model.isRerouting || unfiled == 0 || store.spaces.isEmpty)
                    .help("Score every unfiled item against your Spaces' agents again")
                    Button {
                        model.recluster()
                    } label: {
                        Label(model.isReclustering ? "Looking…" : "Find Clusters", systemImage: "sparkles")
                    }
                    .disabled(model.isReclustering)
                    .help("Look for groups of unfiled items that could become a new Space")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 12)

            Divider().opacity(0.5)
            HStack {
                SpacesSectionHeader(title: "Ask all Spaces")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            SpacesAskView(model: model, store: store, spaceID: nil, placeholder: "Ask across all your Spaces…")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(SpacesPalette.primaryText)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(SpacesPalette.tertiaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SpacesPalette.card))
    }
}

// MARK: - New Note sheet

private struct SpacesManualEntrySheet: View {
    @ObservedObject var entry: SpacesManualEntry
    @ObservedObject var model: SpacesWindowModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Note")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                field("Title") {
                    TextField("What is this?", text: $entry.title)
                        .textFieldStyle(.roundedBorder)
                }
                field("Text") {
                    TextEditor(text: $entry.text)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 150)
                        .background(RoundedRectangle(cornerRadius: 6).fill(SparkVTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))
                }
                field("Link") {
                    TextField("https://…", text: $entry.urlString)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 16) {
                    field("Kind") {
                        Picker("", selection: $entry.kind) {
                            ForEach(SpaceItemKind.allCases, id: \.self) { kind in
                                Label(SpacesUI.label(for: kind), systemImage: SpacesUI.symbol(for: kind)).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                    field("Space") {
                        Picker("", selection: $entry.spaceID) {
                            Text("Inbox (let agents file it)").tag(UUID?.none)
                            Divider()
                            ForEach(model.allSpacesFlattened(), id: \.space.id) { entry in
                                Text(String(repeating: "    ", count: entry.depth) + entry.space.name)
                                    .tag(Optional(entry.space.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 210)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.manualEntry = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { model.saveManualEntry(entry) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .disabled(!entry.canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .preferredColorScheme(.dark)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SpacesPalette.secondaryText)
            content()
        }
    }
}
