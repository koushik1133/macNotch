import Foundation
import UniformTypeIdentifiers

// Value types shared by the download watcher, the rules engine and the views.

/// Which browser family wrote a partial download (from its file naming).
enum DownloadBrowser: String, Codable, Sendable, CaseIterable {
    /// `name.ext.download` bundle with an Info.plist.
    case safari
    /// `name.ext.crdownload` (Chrome, Edge, Brave, Arc, Vivaldi) or `.opdownload` (Opera).
    case chromium
    /// `name.ext.part` next to a zero-byte `name.ext` placeholder.
    case firefox
    /// Any other file that grew in place (curl, other apps, AirDrop…).
    case other

    var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chromium: "Chromium browser"
        case .firefox: "Firefox"
        case .other: "Other app"
        }
    }
}

/// Broad file category used by rules and the UI (Hazel's "Kind").
enum DownloadCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case image, document, video, audio, archive, installer, code, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Images"
        case .document: "Documents"
        case .video: "Videos"
        case .audio: "Music"
        case .archive: "Archives"
        case .installer: "Installers"
        case .code: "Code"
        case .other: "Other"
        }
    }

    /// Singular, for rule sentences ("Kind is Image").
    var singular: String {
        switch self {
        case .image: "Image"
        case .document: "Document"
        case .video: "Video"
        case .audio: "Audio"
        case .archive: "Archive"
        case .installer: "Installer"
        case .code: "Code"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .document: "doc.text"
        case .video: "film"
        case .audio: "music.note"
        case .archive: "archivebox"
        case .installer: "shippingbox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }

    /// Category from the file name's extension through Uniform Type Identifiers,
    /// with a few explicit extensions UTType files under generic data.
    static func of(fileName: String) -> DownloadCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if ["dmg", "pkg", "mpkg", "app", "iso"].contains(ext) { return .installer }
        if ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"].contains(ext) { return .archive }
        if ["md", "markdown", "txt", "rtf", "pages", "numbers", "key", "epub", "csv", "ics", "vcf"].contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .diskImage) || (UTType("com.apple.installer-package-archive").map { type.conforms(to: $0) } ?? false) || type.conforms(to: .application) { return .installer }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .yaml) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }
}

enum DownloadPhase: String, Codable, Sendable {
    case downloading
    /// No new bytes for a while (Safari/Chrome pause, stalled network).
    case paused
    case finished
    case cancelled
}

/// Where a sort sends a file.
enum DownloadDestination: Codable, Hashable, Sendable {
    /// A folder, stored with `~` for the home folder ("~/Downloads/Images").
    case folder(String)
    /// SpaceIngestCenter files it into the right Space (or the Inbox).
    case space

    var displayName: String {
        switch self {
        case .space: return "Spaces"
        case .folder(let path):
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
    }

    /// Full path for display ("~/Downloads/Images").
    var displayPath: String {
        switch self {
        case .space: "Send to a Space (filed automatically)"
        case .folder(let path): path
        }
    }

    var symbol: String {
        switch self {
        case .space: "square.stack.3d.up"
        case .folder: "folder"
        }
    }

    /// The folder URL, with `~` expanded against `home`.
    func folderURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard case .folder(let path) = self else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true) }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// `~/…` form of a folder URL inside the home folder, for storing.
    static func folder(url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DownloadDestination {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return .folder("~") }
        if path.hasPrefix(homePath + "/") { return .folder("~" + path.dropFirst(homePath.count)) }
        return .folder(path)
    }
}

/// A move SparkV made, kept so Undo can put the file back.
struct DownloadMove: Codable, Equatable, Sendable {
    let from: URL
    let to: URL
    let destination: DownloadDestination
    let date: Date
    /// Rule that chose the folder, if any.
    let ruleName: String?
    /// True when an auto-sort rule moved it without a click.
    let automatic: Bool
}

/// One download, in flight or finished.
struct DownloadItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// Final file name (without .crdownload/.part/.download).
    var name: String
    /// Where the file is now: the partial while downloading, the finished
    /// file afterwards, the sorted location after a move.
    var url: URL
    var phase: DownloadPhase
    var browser: DownloadBrowser
    var bytesReceived: Int64
    /// Nil when the browser doesn't tell (Chrome without NSProgress, curl).
    var totalBytes: Int64?
    /// Smoothed transfer rate (bytes per second).
    var bytesPerSecond: Double
    var startedAt: Date
    var finishedAt: Date?
    /// First entry of kMDItemWhereFroms (the file's URL) or the URL from the
    /// browser's progress / Safari's Info.plist.
    var sourceURL: String?
    /// Second entry of kMDItemWhereFroms (the page it came from).
    var referrerURL: String?
    /// App that downloaded it, from the quarantine attribute ("Safari").
    var agentName: String?
    var move: DownloadMove?
    var sentToSpace = false
    var addedToTray = false
    /// Already in Downloads when the watcher started (no live progress, never auto-sorted).
    var isSeeded = false

    init(id: UUID = UUID(), name: String, url: URL, phase: DownloadPhase, browser: DownloadBrowser,
         bytesReceived: Int64 = 0, totalBytes: Int64? = nil, bytesPerSecond: Double = 0,
         startedAt: Date = Date(), finishedAt: Date? = nil, sourceURL: String? = nil,
         referrerURL: String? = nil, agentName: String? = nil, isSeeded: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.phase = phase
        self.browser = browser
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sourceURL = sourceURL
        self.referrerURL = referrerURL
        self.agentName = agentName
        self.isSeeded = isSeeded
    }

    var isActive: Bool { phase == .downloading || phase == .paused }
    var category: DownloadCategory { .of(fileName: name) }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    /// 0…1 when the total is known.
    var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(total)))
    }

    /// Seconds left at the current rate, when the total is known.
    var etaSeconds: Double? {
        guard let total = totalBytes, total > 0, bytesPerSecond > 1 else { return nil }
        let remaining = Double(max(0, total - bytesReceived))
        return remaining / bytesPerSecond
    }

    /// Host of the source (or the referring page), without "www.".
    var sourceDomain: String? {
        for candidate in [sourceURL, referrerURL] {
            guard let text = candidate, let host = URL(string: text)?.host?.lowercased(), !host.isEmpty else { continue }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return nil
    }
}

/// What the drawer proposes for a finished file.
struct DownloadSuggestion: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case rule(String)
        case ai
    }

    let destination: DownloadDestination
    let origin: Origin
    /// Short reason for the tooltip ("Rule: Images", "Apple Intelligence").
    var reason: String {
        switch origin {
        case .rule(let name): "Rule: \(name)"
        case .ai: "Suggested by Apple Intelligence on this Mac"
        }
    }

    /// True when the on-device model chose it (no rule matched).
    var isAI: Bool { origin == .ai }
}

// MARK: - Formatting

enum DownloadFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// "8 s left", "3 min left", "1 h 5 min left".
    static func eta(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(max(1, s)) s left" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) min left" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m == 0 ? "\(h) h left" : "\(h) h \(m) min left"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }

    /// One-line status for an in-flight item: "42% · 3.1 MB/s · 12 s left".
    static func progressLine(_ item: DownloadItem) -> String {
        if item.phase == .paused {
            var parts = ["Paused"]
            if let fraction = item.fraction { parts.append(percent(fraction)) }
            parts.append(bytes(item.bytesReceived))
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if let fraction = item.fraction {
            parts.append(percent(fraction))
        } else {
            parts.append(bytes(item.bytesReceived))
        }
        if item.bytesPerSecond >= 1 { parts.append(speed(item.bytesPerSecond)) }
        if let seconds = item.etaSeconds { parts.append(eta(seconds)) }
        return parts.joined(separator: " · ")
    }

    /// "2.4 MB · github.com".
    static func detailLine(_ item: DownloadItem) -> String {
        var parts = [bytes(item.totalBytes ?? item.bytesReceived)]
        if let domain = item.sourceDomain { parts.append(domain) } else if let agent = item.agentName { parts.append(agent) }
        return parts.joined(separator: " · ")
    }
}
