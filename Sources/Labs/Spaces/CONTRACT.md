# Spaces contract

Types: `SpaceModels.swift` (owned by the lead — don't change; ask for fields in your final answer).

## SpaceStore (owned by spaces-core)

```swift
@MainActor final class SpaceStore: ObservableObject {
    static let shared: SpaceStore
    @Published private(set) var personas: [Persona]
    @Published var currentPersonaID: UUID            // persisted; a default "Me" persona is created on first run
    @Published private(set) var spaces: [Space]      // current persona only
    @Published private(set) var items: [SpaceItem]   // current persona only, newest first
    @Published private(set) var suggestions: [SpaceSuggestion]
    @Published private(set) var isIndexing: Bool

    // Personas
    func createPersona(name: String, icon: String) -> Persona
    func renamePersona(_ id: UUID, to name: String)
    func deletePersona(_ id: UUID)

    // Spaces (clusters / folders)
    func createSpace(name: String, parentID: UUID?, icon: String, color: String, rules: SpaceAgentRules) -> Space
    func updateSpace(_ space: Space)
    func deleteSpace(_ id: UUID, keepItems: Bool)
    func children(of parentID: UUID?) -> [Space]
    func addMember(_ member: SpaceMember, to spaceID: UUID)
    func removeMember(_ memberID: UUID, from spaceID: UUID)

    // Items
    func ingest(_ input: SpaceIngestInput) async -> SpaceItem?   // de-dupes by sourceKey, routes via agents, may create a suggestion
    func addManual(title: String, text: String, url: URL?, spaceID: UUID?, kind: SpaceItemKind) -> SpaceItem
    func move(itemID: UUID, to spaceID: UUID?)
    func delete(itemID: UUID)
    func items(in spaceID: UUID?, recursive: Bool) -> [SpaceItem]   // nil = Inbox
    func accept(_ suggestion: SpaceSuggestion)
    func dismiss(_ suggestion: SpaceSuggestion)

    // Intelligence
    func search(_ query: String, in spaceID: UUID?) async -> [SpaceItem]          // keyword + semantic
    func ask(_ question: String, in spaceID: UUID?) async throws -> SpaceAnswer    // on-device RAG; answer cites item ids
    func recluster() async                                                       // refresh "create Space" suggestions

    // Sharing (local today)
    func exportSpace(_ id: UUID, to url: URL) throws        // .sparkvspace package (manifest.json + Attachments/)
    func importSpace(from url: URL) throws -> Space
}

struct SpaceAnswer: Sendable { var text: String; var citedItemIDs: [UUID]; var producedBy: String }
```

## UI (owned by spaces-ui)

- `struct SpacesTabView: View` — drawer content area (~508×114 pt): persona switcher, space chips, Inbox count, quick search, "Open Spaces" button.
- `@MainActor final class SpacesWindowController { static let shared; func show(spaceID: UUID? = nil) }` — the full Mac window.

## Ingest (owned by spaces-ingest)

- `@MainActor final class SpaceIngestCenter: ObservableObject { init(store: SpaceStore, activities: ActivityCenter); func start(); func stop(); @Published var enabledSources: Set<SpaceItemSource> }`
- Static helpers the lead calls from existing features:
  `SpaceIngestCenter.meeting(_ record: MeetingRecord)`, `.flow(_ entry: FlowEntry)`, `.tray(_ item: TrayItem)`, `.saveCurrentWebPage()`, `.saveSelectedMail()`, `.file(_ url: URL)`.
