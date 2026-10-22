import Foundation

// Core clipboard-history model. No AppKit view code and no app-only types,
// so the test harness in Vendor/clipboard/Tests compiles it on its own.
// Approach follows Maccy (MIT, github.com/p0deje/Maccy) and nspasteboard.org;
// see DESIGN.md.

/// One entry in the clipboard history.
struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case text
        /// Text that came with RTF and/or HTML.
        case richText
        /// A single web link.
        case url
        case image
        /// One or more file URLs.
        case file
    }

    let id: UUID
    var kind: Kind
    /// Plain text (text, rich text, the link of a URL). Nil for images and files.
    var text: String?
    /// `public.url-name` that came with a link, if any.
    var title: String?
    /// Text read out of an image on this Mac (Vision), so screenshots are
    /// searchable, as in Raycast. Nil for other kinds.
    var recognizedText: String? = nil
    /// Files (kind == .file).
    var fileURLs: [URL]?
    /// Stored representations: pasteboard type raw value -> blob file name.
    var blobs: [String: String]
    /// Small PNG preview of an image (blob file name).
    var thumbnailBlob: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Bundle id of the app it was copied in, when known.
    var sourceBundleID: String?
    /// Most recent copy.
    var copiedAt: Date
    var firstCopiedAt: Date
    var copyCount: Int
    var isPinned: Bool
    /// SHA-256 of the content; equal fingerprints are the same item.
    var fingerprint: String
    /// Rough size of everything stored for this item.
    var byteCount: Int

    /// First line of the text, link host, file name or image size.
    var displayTitle: String {
        switch kind {
        case .text, .richText:
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "Text" : String(line.prefix(120))
        case .url:
            if let title, !title.isEmpty { return title }
            return linkHost ?? (text ?? "Link")
        case .image:
            if let pixelWidth, let pixelHeight { return "Image \(pixelWidth)×\(pixelHeight)" }
            return "Image"
        case .file:
            let urls = fileURLs ?? []
            guard let first = urls.first else { return "File" }
            return urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) +\(urls.count - 1)"
        }
    }

    /// Host without "www." for links.
    var linkHost: String? {
        guard kind == .url, let text, let host = URL(string: text)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Lowercased text the search field matches against.
    var searchableText: String {
        var parts: [String] = [displayTitle]
        if let text { parts.append(String(text.prefix(20_000))) }
        if let title { parts.append(title) }
        if let recognizedText { parts.append(String(recognizedText.prefix(20_000))) }
        if let fileURLs { parts.append(contentsOf: fileURLs.map(\.path)) }
        if let sourceBundleID { parts.append(sourceBundleID) }
        return parts.joined(separator: "\n").lowercased()
    }

    /// Plain text to type or paste, if the item has any.
    var plainText: String? {
        switch kind {
        case .text, .richText, .url: text
        case .file: fileURLs?.map(\.path).joined(separator: "\n")
        case .image: nil
        }
    }
}

/// Raw snapshot of what was read from a pasteboard (Sendable, so it can be
/// processed off the main thread).
struct ClipboardCapture: Sendable, Equatable {
    struct Image: Sendable, Equatable {
        /// Pasteboard type raw value (public.png, public.tiff, …).
        var type: String
        var data: Data
    }

    var changeCount: Int
    /// Union of the types of every pasteboard item.
    var types: [String]
    var string: String?
    var rtf: Data?
    var html: Data?
    /// `public.url` (non-file links only).
    var urlString: String?
    var urlTitle: String?
    var image: Image?
    var fileURLs: [URL]
    var sourceBundleID: String?
    var capturedAt: Date

    /// Which kind of history item this becomes, or nil when nothing usable
    /// was read. Order: files, images (when there's no real text), a single
    /// link, rich text, text.
    var kind: ClipboardItem.Kind? {
        if !fileURLs.isEmpty { return .file }
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if image != nil, trimmed.isEmpty || ClipboardCapture.webLink(trimmed) != nil {
            return .image
        }
        if trimmed.isEmpty, let urlString, ClipboardCapture.webLink(urlString) != nil { return .url }
        if trimmed.isEmpty { return nil }
        if ClipboardCapture.webLink(trimmed) != nil { return .url }
        if rtf != nil || html != nil { return .richText }
        return .text
    }

    /// The text if it is exactly one http(s) link.
    static func webLink(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4096, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}

/// What to record and what to skip. Checked against the pasteboard's type
/// list before any content is read, so a password is never even loaded.
struct ClipboardPolicy: Sendable, Equatable {
    // nspasteboard.org markers.
    static let concealedType = "org.nspasteboard.ConcealedType"
    static let transientType = "org.nspasteboard.TransientType"
    static let autoGeneratedType = "org.nspasteboard.AutoGeneratedType"
    static let sourceType = "org.nspasteboard.source"
    /// Universal Clipboard (Handoff from another device).
    static let remoteClipboardType = "com.apple.is-remote-clipboard"
    /// Marks pasteboard contents SparkV's clipboard history wrote itself.
    static let ownMarkerType = "com.notchisland.clipboard"

    /// Always skipped, whatever the settings say (as in Maccy).
    static let alwaysIgnoredTypes: Set<String> = [concealedType, transientType, autoGeneratedType]

    /// Skipped by default (Maccy's default list): password-manager and
    /// transient markers from specific apps.
    static let defaultIgnoredTypes: Set<String> = [
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
        "net.antelle.keeweb",
    ]

    /// Password managers and similar apps; copies made while one of them is
    /// the source are never recorded. Best effort: the concealed marker
    /// above is the main defence.
    static let defaultExcludedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "com.keepassium.KeePassium",
        "in.sinew.Enpass-Desktop",
        "com.markmcguill.strongbox.mac",
        "com.keepersecurity.passwordmanager",
        "com.nordsec.nordpass",
        "me.proton.pass.electron",
    ]

    enum SkipReason: String, Sendable, Equatable {
        case concealed
        case transient
        case autoGenerated
        /// A password-manager or other ignored type.
        case ignoredType
        case excludedApp
        case remoteClipboard
        /// Our own copy-back.
        case ownWrite
        case empty
        case tooLarge
    }

    enum Decision: Sendable, Equatable {
        case record
        case skip(SkipReason)
    }

    var ignoredTypes: Set<String> = ClipboardPolicy.defaultIgnoredTypes
    var excludedBundleIDs: Set<String> = ClipboardPolicy.defaultExcludedBundleIDs
    var ignoresRemoteClipboard = false

    // Size limits (Alfred-style maximum clip size).
    var maxTextBytes = 2_000_000
    var maxRichBytes = 4_000_000
    var maxImageBytes = 40_000_000
    var maxFiles = 200

    /// Decision from the type list and source app alone.
    func preflight(types: [String], sourceBundleID: String?) -> Decision {
        let set = Set(types)
        if set.contains(Self.concealedType) { return .skip(.concealed) }
        if set.contains(Self.transientType) { return .skip(.transient) }
        if set.contains(Self.autoGeneratedType) { return .skip(.autoGenerated) }
        if !set.isDisjoint(with: ignoredTypes) { return .skip(.ignoredType) }
        if set.contains(Self.ownMarkerType) { return .skip(.ownWrite) }
        if ignoresRemoteClipboard, set.contains(Self.remoteClipboardType) { return .skip(.remoteClipboard) }
        if let sourceBundleID, excludedBundleIDs.contains(sourceBundleID) { return .skip(.excludedApp) }
        if set.isEmpty { return .skip(.empty) }
        return .record
    }

    /// Applies the size limits to a capture: drops oversized rich text, and
    /// skips oversized text and images.
    func enforceLimits(_ capture: inout ClipboardCapture) -> Decision {
        if let rtf = capture.rtf, rtf.count > maxRichBytes { capture.rtf = nil }
        if let html = capture.html, html.count > maxRichBytes { capture.html = nil }
        if capture.fileURLs.count > maxFiles { capture.fileURLs = Array(capture.fileURLs.prefix(maxFiles)) }
        guard let kind = capture.kind else { return .skip(.empty) }
        switch kind {
        case .text, .richText, .url:
            if (capture.string?.utf8.count ?? 0) > maxTextBytes { return .skip(.tooLarge) }
        case .image:
            if (capture.image?.data.count ?? 0) > maxImageBytes { return .skip(.tooLarge) }
        case .file:
            break
        }
        return .record
    }
}

/// The ordered history: newest first, dedupe by fingerprint, at most
/// `unpinnedLimit` unpinned items plus `pinnedLimit` pinned ones. Pure
/// value logic; storage of blobs is ClipboardDiskStore's job.
struct ClipboardHistory: Sendable, Equatable {
    static let defaultUnpinnedLimit = 30
    static let defaultPinnedLimit = 20

    private(set) var items: [ClipboardItem]
    var unpinnedLimit: Int
    var pinnedLimit: Int

    init(items: [ClipboardItem] = [],
         unpinnedLimit: Int = ClipboardHistory.defaultUnpinnedLimit,
         pinnedLimit: Int = ClipboardHistory.defaultPinnedLimit) {
        self.unpinnedLimit = unpinnedLimit
        self.pinnedLimit = pinnedLimit
        self.items = items.sorted { $0.copiedAt > $1.copiedAt }
        _ = trim()
    }

    /// The most recent copy (what should be on the clipboard now).
    var latest: ClipboardItem? { items.first }
    var pinned: [ClipboardItem] { items.filter(\.isPinned) }
    var unpinned: [ClipboardItem] { items.filter { !$0.isPinned } }

    func item(id: UUID) -> ClipboardItem? { items.first { $0.id == id } }

    /// Adds `item` at the top. A duplicate (same fingerprint) is replaced:
    /// the new copy wins, keeping the old pin, first-copy date and count.
    /// Returns the items that left the history (duplicates, evictions), whose
    /// blobs should be deleted.
    @discardableResult
    mutating func insert(_ item: ClipboardItem) -> [ClipboardItem] {
        var item = item
        var removed: [ClipboardItem] = []
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint && $0.id != item.id }) {
            let old = items.remove(at: index)
            item.isPinned = item.isPinned || old.isPinned
            item.firstCopiedAt = min(old.firstCopiedAt, item.firstCopiedAt)
            item.copyCount = old.copyCount + item.copyCount
            removed.append(old)
        }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        removed += trim()
        return removed
    }

    /// Moves an existing item to the top (copied again from the history).
    mutating func bump(id: UUID, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.copiedAt = max(date, item.copiedAt)
        item.copyCount += 1
        items.insert(item, at: 0)
    }

    /// Stores text read out of an image; false when the item is gone.
    @discardableResult
    mutating func setRecognizedText(id: UUID, _ text: String?) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].recognizedText = text
        return true
    }

    @discardableResult
    mutating func remove(id: UUID) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Pins or unpins. Pinning fails (returns false) once `pinnedLimit` pinned
    /// items exist. Unpinning may evict the oldest unpinned item (returned).
    mutating func setPinned(id: UUID, _ pinned: Bool) -> (ok: Bool, removed: [ClipboardItem]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return (false, []) }
        if items[index].isPinned == pinned { return (true, []) }
        if pinned, self.pinned.count >= pinnedLimit { return (false, []) }
        items[index].isPinned = pinned
        return (true, trim())
    }

    /// Removes everything (or everything unpinned); returns what was removed.
    mutating func clear(keepingPinned: Bool) -> [ClipboardItem] {
        let removed = keepingPinned ? unpinned : items
        items = keepingPinned ? pinned : []
        return removed
    }

    /// Search plus kind filter, pinned first, then newest first.
    func filtered(query: String, kinds: Set<ClipboardItem.Kind>? = nil, pinnedOnly: Bool = false) -> [ClipboardItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terms = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = items.filter { item in
            if pinnedOnly, !item.isPinned { return false }
            if let kinds, !kinds.contains(item.kind) { return false }
            guard !terms.isEmpty else { return true }
            let haystack = item.searchableText
            return terms.allSatisfy { haystack.contains($0) }
        }
        return matches.filter(\.isPinned) + matches.filter { !$0.isPinned }
    }

    private mutating func trim() -> [ClipboardItem] {
        var removed: [ClipboardItem] = []
        var unpinnedSeen = 0
        var pinnedSeen = 0
        items = items.filter { item in
            if item.isPinned {
                pinnedSeen += 1
                if pinnedSeen > pinnedLimit { removed.append(item); return false }
            } else {
                unpinnedSeen += 1
                if unpinnedSeen > unpinnedLimit { removed.append(item); return false }
            }
            return true
        }
        return removed
    }
}
