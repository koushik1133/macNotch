import Foundation

// Sharing a Space (owned by spaces-core). Local today: a `.sparkvspace`
// package — a folder with manifest.json (the Space, its subfolders, members,
// items and agent memory) and Attachments/<itemID>/<file> copies — that can be
// AirDropped, mailed (zipped by Finder) or put on a shared drive. Importing
// re-creates everything with new ids under the current persona and keeps the
// members. `SpaceMember.externalID` stays reserved for a future sync backend.

struct SpacePackageManifest: Codable, Sendable {
    static let formatName = "sparkvspace"
    static let currentVersion = 1

    var format: String
    var version: Int
    var exportedAt: Date
    var exportedBy: String?
    var space: Space
    /// Every Space below `space`, any depth.
    var subfolders: [Space]
    /// The root Space's members (also inside `space`).
    var members: [SpaceMember]
    var items: [SpaceItem]
    /// Space id → the agent's running summary.
    var memories: [String: String]?
}

enum SpaceSharingError: Error, LocalizedError {
    case spaceNotFound
    case notAPackage
    case unsupportedVersion(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .spaceNotFound: return "That Space no longer exists."
        case .notAPackage: return "This isn't a SparkV Space (.sparkvspace)."
        case .unsupportedVersion(let v): return "This Space was exported by a newer version (format \(v))."
        case .unreadable(let message): return "Couldn't read the Space: \(message)"
        }
    }
}

extension SpaceStore {
    static let packageExtension = "sparkvspace"

    /// Writes the Space (with subfolders, members, items, memory and copies of
    /// attachments) as a `.sparkvspace` package at `url`, replacing what's there.
    func exportSpace(_ id: UUID, to url: URL) throws {
        guard let root = space(id) else { throw SpaceSharingError.spaceNotFound }
        let subtree = descendantIDs(of: id)
        let subfolders = spaces.filter { subtree.contains($0.id) }
        let scope = subtree.union([id])
        let exported = items.filter { $0.spaceID.map(scope.contains) ?? false }
        let memoryMap = Dictionary(
            memoryRecords(for: scope).map { ($0.spaceID.uuidString, $0.summary) }, uniquingKeysWith: { a, _ in a }
        )
        let manifest = SpacePackageManifest(
            format: SpacePackageManifest.formatName, version: SpacePackageManifest.currentVersion, exportedAt: Date(),
            exportedBy: currentPersona?.name, space: root, subfolders: subfolders, members: root.members,
            items: exported, memories: memoryMap.isEmpty ? nil : memoryMap
        )

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Build next to the destination, then swap in, so a failed export
        // never leaves a half-written package behind.
        let staging = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            for item in exported {
                guard let path = item.attachmentPath, let source = attachmentURL(for: item) else { continue }
                let destination = staging.appendingPathComponent(path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: url)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        AppLog.log("Spaces: exported \(root.name) (\(subfolders.count) folder(s), \(exported.count) item(s)) → \(url.lastPathComponent)")
    }

    /// Re-creates a `.sparkvspace` package under the current persona with new
    /// ids (members kept), as a new top-level Space. Returns the new root.
    @discardableResult
    func importSpace(from url: URL) throws -> Space {
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw SpaceSharingError.notAPackage }
        let manifest: SpacePackageManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(SpacePackageManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw SpaceSharingError.unreadable(error.localizedDescription)
        }
        guard manifest.format == SpacePackageManifest.formatName else { throw SpaceSharingError.notAPackage }
        guard manifest.version <= SpacePackageManifest.currentVersion else {
            throw SpaceSharingError.unsupportedVersion(manifest.version)
        }

        let personaID = currentPersonaID
        let now = Date()
        var idMap: [UUID: UUID] = [manifest.space.id: UUID()]
        for folder in manifest.subfolders where idMap[folder.id] == nil { idMap[folder.id] = UUID() }

        // Root keeps its members; name gets a suffix if it clashes at top level.
        let topNames = Set(children(of: nil).map { $0.name.lowercased() })
        var rootName = manifest.space.name
        if topNames.contains(rootName.lowercased()) {
            var n = 2
            while topNames.contains("\(manifest.space.name) \(n)".lowercased()) { n += 1 }
            rootName = "\(manifest.space.name) \(n)"
        }

        func remap(_ s: Space, isRoot: Bool) -> Space? {
            guard let newID = idMap[s.id] else { return nil }
            var parent: UUID?
            if !isRoot {
                guard let oldParent = s.parentID, let mapped = idMap[oldParent] else { return nil }
                parent = mapped
            }
            let members = isRoot && !manifest.members.isEmpty ? manifest.members : s.members
            return Space(
                id: newID, personaID: personaID, parentID: parent, name: isRoot ? rootName : s.name,
                icon: s.icon, color: s.color, rules: s.rules, members: members, createdAt: s.createdAt, updatedAt: now
            )
        }
        var newSpaces: [Space] = []
        if let root = remap(manifest.space, isRoot: true) { newSpaces.append(root) }
        // Folders whose parent chain is broken are attached to the root.
        for folder in manifest.subfolders {
            if let mapped = remap(folder, isRoot: false) {
                newSpaces.append(mapped)
            } else if let newID = idMap[folder.id], let rootID = newSpaces.first?.id {
                newSpaces.append(Space(
                    id: newID, personaID: personaID, parentID: rootID, name: folder.name, icon: folder.icon,
                    color: folder.color, rules: folder.rules, members: folder.members, createdAt: folder.createdAt,
                    updatedAt: now
                ))
            }
        }
        guard let newRoot = newSpaces.first else { throw SpaceSharingError.unreadable("missing Space") }

        let packageRoot = url.standardizedFileURL.path
        let existingKeys = Set(items.map(\.sourceKey))
        var newItems: [SpaceItem] = []
        for old in manifest.items {
            let newID = UUID()
            var attachmentPath: String?
            if let path = old.attachmentPath, !path.isEmpty {
                // Only files inside the package (no "../" escapes).
                let source = url.appendingPathComponent(path).standardizedFileURL
                if source.path.hasPrefix(packageRoot + "/"), fm.fileExists(atPath: source.path) {
                    attachmentPath = SpaceStore.copyAttachment(source, itemID: newID, root: rootDirectory)
                }
            }
            let spaceID = old.spaceID.flatMap { idMap[$0] } ?? newRoot.id
            let key = existingKeys.contains(old.sourceKey) ? "import:\(newID.uuidString):\(old.sourceKey)" : old.sourceKey
            newItems.append(SpaceItem(
                id: newID, spaceID: spaceID, personaID: personaID, kind: old.kind, source: old.source,
                title: old.title, text: old.text, url: old.url, attachmentPath: attachmentPath,
                entities: old.entities, tags: old.tags, createdAt: old.createdAt, sourceKey: key,
                filingConfidence: nil
            ))
        }

        var newMemories: [SpaceMemoryRecord] = []
        for (oldID, summary) in manifest.memories ?? [:] {
            guard let old = UUID(uuidString: oldID), let newID = idMap[old] else { continue }
            let count = newItems.filter { item in
                guard let sid = item.spaceID else { return false }
                return sid == newID || newSpaces.contains { $0.id == sid && isDescendant($0.id, of: newID, in: newSpaces) }
            }.count
            newMemories.append(SpaceMemoryRecord(
                spaceID: newID, summary: summary, itemCount: count, producedBy: "Imported", updatedAt: now
            ))
        }

        commitImport(spaces: newSpaces, items: newItems, memories: newMemories)
        AppLog.log("Spaces: imported \(newRoot.name) (\(newSpaces.count - 1) folder(s), \(newItems.count) item(s))")
        return newRoot
    }

    private func isDescendant(_ id: UUID, of ancestor: UUID, in list: [Space]) -> Bool {
        var current = list.first { $0.id == id }?.parentID
        var depth = 0
        while let pid = current, depth < 64 {
            if pid == ancestor { return true }
            current = list.first { $0.id == pid }?.parentID
            depth += 1
        }
        return false
    }
}
