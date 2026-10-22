import Foundation

// Shared contract for Spaces (knowledge clusters). Owned by the lead; the
// core, UI and ingest agents code against these types and the SpaceStore API
// described in Sources/Labs/Spaces/CONTRACT.md.

/// A local profile on this Mac. Each persona has its own Spaces.
struct Persona: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// SF Symbol name or emoji shown in pickers.
    var icon: String
    var createdAt: Date
}

enum SpaceRole: String, Codable, CaseIterable, Sendable {
    case owner, editor, viewer
}

/// Someone with access to a Space. Local today (export/import to share);
/// `externalID` is reserved for a future sync backend.
struct SpaceMember: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var email: String?
    var role: SpaceRole
    var externalID: String?
}

/// What the Space's agent watches for when auto-filing new items.
struct SpaceAgentRules: Codable, Equatable, Sendable {
    var keywords: [String]
    var people: [String]
    /// Web domains and email domains, e.g. "helm.events".
    var domains: [String]
    /// App bundle identifiers whose screenshots/clipboard belong here.
    var apps: [String]
    /// Free-text description the agent uses for semantic matching.
    var about: String
    /// Auto-file without asking when confidence ≥ this (0…1).
    var autoFileThreshold: Double
}

/// A cluster: one organization, client or project. Folders are nested Spaces.
struct Space: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var personaID: UUID
    var parentID: UUID?
    var name: String
    var icon: String
    /// Hex color, e.g. "#4F8EF7".
    var color: String
    var rules: SpaceAgentRules
    var members: [SpaceMember]
    var createdAt: Date
    var updatedAt: Date
}

enum SpaceItemKind: String, Codable, CaseIterable, Sendable {
    case meeting, note, dictation, screenshot, file, webPage, email, clipboard, job, contact, link, manual
}

enum SpaceItemSource: String, Codable, Sendable {
    case meetings, flow, tray, screenshots, files, web, mail, clipboard, jobs, manual
}

/// One piece of knowledge filed into a Space (or waiting in the Inbox when
/// `spaceID` is nil).
struct SpaceItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var spaceID: UUID?
    var personaID: UUID
    var kind: SpaceItemKind
    var source: SpaceItemSource
    var title: String
    /// Plain-text body used for search, embeddings and Q&A.
    var text: String
    /// Original location: file URL, web URL, meeting id URL, message URL…
    var url: URL?
    /// Copy kept inside the store (e.g. screenshot), relative to the store root.
    var attachmentPath: String?
    /// People, organizations, emails, domains, dates found in the text.
    var entities: [String]
    var tags: [String]
    var createdAt: Date
    /// Where the item came from in a stable, de-duplicatable form
    /// (e.g. "meeting:<uuid>", "web:<url>", "file:<path>").
    var sourceKey: String
    /// How sure the agent was when it filed this (nil = filed by hand).
    var filingConfidence: Double?
}

/// What an ingest connector hands to the store; the agents decide the Space.
struct SpaceIngestInput: Sendable {
    var kind: SpaceItemKind
    var source: SpaceItemSource
    var title: String
    var text: String
    var url: URL?
    /// A file to copy into the store as the item's attachment.
    var attachment: URL?
    var sourceKey: String
    var createdAt: Date
    /// Hints that help routing: app bundle id, sender email, participants…
    var hints: [String: String]
}

/// A suggestion the agents surface: file this item there, or create a cluster.
struct SpaceSuggestion: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case file(itemID: UUID, spaceID: UUID, confidence: Double, reason: String)
        case createSpace(name: String, itemIDs: [UUID], reason: String)
    }
    let id: UUID
    let action: Action
}
