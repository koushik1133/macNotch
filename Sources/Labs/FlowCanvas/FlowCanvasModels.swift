import CoreGraphics
import Foundation

// Flow Canvas data model: a canvas is a graph of source cards (notes, images,
// links, PDFs, files) feeding AI action nodes along edges. Everything here is
// a plain Codable value so a canvas round-trips through JSON
// (~/Library/Application Support/SparkV/FlowCanvas/<id>.json).

// MARK: - Public input type (notch Tray / Converter → canvas)

/// Something the notch hands to Flow Canvas (`FlowCanvasWindowController.show(adding:)`).
enum FlowCanvasInput: Equatable, Sendable {
    case image(URL)
    case pdf(URL)
    case file(URL)
    case url(URL)
    case text(String)

    /// Picks the right case for a local file from its extension.
    static func forFile(_ url: URL) -> FlowCanvasInput {
        switch FCSourceKinds.kind(forFile: url) {
        case .image: return .image(url)
        case .pdf: return .pdf(url)
        default: return .file(url)
        }
    }
}

// MARK: - Node kinds

enum FCNodeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    // Sources
    case note, image, pdf, link, file
    // AI actions
    case chat, summarize, extract, compare, report, translate, custom
    // Decoration: a labelled area that groups cards.
    case frame

    var id: String { rawValue }

    static let sources: [FCNodeKind] = [.note, .link, .image, .pdf, .file]
    static let actions: [FCNodeKind] = [.chat, .summarize, .extract, .compare, .report, .translate, .custom]

    var isSource: Bool { Self.sources.contains(self) }
    var isAction: Bool { Self.actions.contains(self) }
    var hasInputPort: Bool { isAction }
    var hasOutputPort: Bool { self != .frame }

    var title: String {
        switch self {
        case .note: "Text note"
        case .image: "Image"
        case .pdf: "PDF"
        case .link: "Link"
        case .file: "File"
        case .chat: "Ask / Chat"
        case .summarize: "Summarize"
        case .extract: "Extract fields"
        case .compare: "Compare"
        case .report: "Write report"
        case .translate: "Translate"
        case .custom: "Custom prompt"
        case .frame: "Frame"
        }
    }

    var symbol: String {
        switch self {
        case .note: "note.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .link: "link"
        case .file: "doc"
        case .chat: "bubble.left.and.text.bubble.right"
        case .summarize: "text.append"
        case .extract: "tablecells"
        case .compare: "rectangle.split.3x1"
        case .report: "doc.text.magnifyingglass"
        case .translate: "character.bubble"
        case .custom: "wand.and.stars"
        case .frame: "rectangle.dashed"
        }
    }

    /// One line shown in menus and the planner.
    var blurb: String {
        switch self {
        case .note: "Type or paste text"
        case .image: "Screenshot or photo, read with Vision"
        case .pdf: "PDF text, OCR for scanned pages"
        case .link: "Web page title and readable text"
        case .file: "Word, RTF, Markdown, CSV, slides…"
        case .chat: "Ask questions about every connected card"
        case .summarize: "Key points of the inputs"
        case .extract: "Pull named fields into a table"
        case .compare: "Inputs side by side, plus a verdict"
        case .report: "Markdown report with a Sources section"
        case .translate: "Translate the inputs"
        case .custom: "Your own instruction"
        case .frame: "Group cards in a labelled area"
        }
    }

    var defaultWidth: Double {
        switch self {
        case .chat: 380
        case .frame: 560
        case .report, .compare, .extract: 300
        default: 260
        }
    }
}

// MARK: - Node parts

/// Loading / Ready / Failed chip on every card.
struct FCNodeStatus: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, empty, loading, ready, failed }

    var phase: Phase
    var message: String?

    static let idle = FCNodeStatus(phase: .idle)
    static let ready = FCNodeStatus(phase: .ready)
    static func empty(_ hint: String) -> FCNodeStatus { FCNodeStatus(phase: .empty, message: hint) }
    static func loading(_ message: String? = nil) -> FCNodeStatus { FCNodeStatus(phase: .loading, message: message) }
    static func failed(_ reason: String) -> FCNodeStatus { FCNodeStatus(phase: .failed, message: reason) }

    var label: String {
        switch phase {
        case .idle: "Not run"
        case .empty: "Empty"
        case .loading: message ?? "Loading"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }
}

/// A simple table (Extract / Compare outputs).
struct FCTable: Codable, Equatable, Sendable {
    var columns: [String]
    var rows: [[String]]

    var isEmpty: Bool { rows.isEmpty }

    /// Rows padded/trimmed to the column count.
    var normalizedRows: [[String]] {
        rows.map { row in
            var row = row
            if row.count < columns.count { row += Array(repeating: "", count: columns.count - row.count) }
            return Array(row.prefix(columns.count))
        }
    }

    var markdown: String {
        guard !columns.isEmpty else { return "" }
        func cell(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|")
            return flat.isEmpty ? " " : flat
        }
        var lines = ["| " + columns.map(cell).joined(separator: " | ") + " |",
                     "|" + columns.map { _ in " --- " }.joined(separator: "|") + "|"]
        for row in normalizedRows { lines.append("| " + row.map(cell).joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n")
    }

    var csv: String {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        return ([columns] + normalizedRows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// Tab-separated plain text.
    var plainText: String {
        ([columns] + normalizedRows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
}

/// The last result of a node (sources: their extracted text; actions: the answer).
struct FCOutput: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case text, markdown, table }

    var format: Format
    /// Text, Markdown, or (for tables) the narrative under the table.
    var text: String
    var table: FCTable?
    /// Source cards this output drew on (for citations and the Sources section).
    var citations: [UUID] = []

    /// Everything as Markdown (table first, then the text).
    var markdown: String {
        var parts: [String] = []
        if let table, !table.columns.isEmpty { parts.append(table.markdown) }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: "\n\n")
    }

    /// Plain text for the clipboard and .txt files.
    var plainText: String {
        var parts: [String] = []
        if let table, !table.columns.isEmpty { parts.append(table.plainText) }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: "\n\n")
    }
}

/// How the last run went.
struct FCRunInfo: Codable, Equatable, Sendable {
    var startedAt: Date
    var duration: Double
    var model: String
    var error: String?
}

/// Content of a source card.
struct FCSource: Codable, Equatable, Sendable {
    /// Web link, or where a dropped file came from (informational only).
    var url: URL?
    /// The canvas's own copy of an image/PDF/file, inside `<id>-assets/`.
    var assetName: String?
    /// Note body, or the text extracted from the image/page/PDF/file.
    var text: String = ""
    var title: String?
    /// "example.com", "12 pages", "PNG · 1440×900".
    var detail: String?
    /// Video thumbnail from the provider's oEmbed / og:image.
    var thumbnailURL: URL?
    /// "YouTube", "Loom" for video links.
    var provider: String?
    /// Caveat shown on the card ("Transcripts aren't fetched").
    var caveat: String?
    /// Vision labels, or the vision model's description when Groq is allowed.
    var imageDescription: String?
}

/// Settings of an action node.
struct FCActionConfig: Codable, Equatable, Sendable {
    /// Extract: field names ("price", "plans", "features").
    var fields: [String] = []
    /// Translate: target language (English name).
    var language: String = "English"
    /// Custom prompt / extra instruction for Summarize and Report.
    var prompt: String = ""
}

struct FCChatMessage: Codable, Equatable, Sendable, Identifiable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var citations: [UUID] = []
    var model: String?
    var date = Date()
}

struct FCNode: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kind: FCNodeKind
    var title: String
    var x: Double
    var y: Double
    var width: Double
    /// Frames only; cards size to their content.
    var height: Double?
    var source: FCSource?
    var config = FCActionConfig()
    var status = FCNodeStatus.idle
    var output: FCOutput?
    var run: FCRunInfo?
    var chat: [FCChatMessage] = []

    init(kind: FCNodeKind, title: String? = nil, at point: CGPoint, source: FCSource? = nil, config: FCActionConfig = FCActionConfig()) {
        self.kind = kind
        self.title = title ?? kind.title
        self.x = Double(point.x)
        self.y = Double(point.y)
        self.width = kind.defaultWidth
        self.height = kind == .frame ? 380 : nil
        self.source = kind.isSource ? (source ?? FCSource()) : source
        self.config = config
        if kind == .frame { status = .ready }
    }

    var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = Double(newValue.x); y = Double(newValue.y) }
    }

    /// Text this node hands to the next node.
    var outputText: String {
        if kind.isSource { return source?.text ?? "" }
        return output?.markdown ?? ""
    }

    /// Short label used in prompts and citations.
    var citationLabel: String {
        let base = source?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base, !base.isEmpty { return base }
        return title
    }
}

struct FCEdge: Codable, Equatable, Sendable, Identifiable, Hashable {
    var id = UUID()
    /// Output side.
    var from: UUID
    /// Input side.
    var to: UUID
}

struct FCViewport: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var zoom: Double = 1
}

/// One canvas file. `version` lets later builds migrate old files.
struct FCDocument: Codable, Equatable, Sendable, Identifiable {
    static let currentVersion = 1

    var version = FCDocument.currentVersion
    var id = UUID()
    var name: String
    var createdAt = Date()
    var updatedAt = Date()
    var nodes: [FCNode] = []
    var edges: [FCEdge] = []
    var viewport = FCViewport()
    /// Set when the canvas was made from a template.
    var templateID: String?

    init(name: String) {
        self.name = name
    }

    func node(_ id: UUID) -> FCNode? { nodes.first { $0.id == id } }
    func index(of id: UUID) -> Int? { nodes.firstIndex { $0.id == id } }
}

/// A list row in the sidebar (read without decoding outputs into the UI).
struct FCCanvasSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var updatedAt: Date
    var nodeCount: Int
}

// MARK: - Graph

enum FCGraphError: LocalizedError, Equatable {
    case cycle([String])
    case selfLoop

    var errorDescription: String? {
        switch self {
        case .cycle(let names):
            "These cards form a loop, so there's no order to run them in: \(names.joined(separator: " → ")). Remove one of the connections."
        case .selfLoop:
            "A card can't feed itself."
        }
    }
}

enum FCGraph {
    /// Inputs of `id`, top to bottom (the order sources appear in prompts).
    static func inputs(of id: UUID, in document: FCDocument) -> [FCNode] {
        let ids = document.edges.filter { $0.to == id }.map(\.from)
        return ids.compactMap(document.node).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    static func outputs(of id: UUID, in document: FCDocument) -> [FCNode] {
        document.edges.filter { $0.from == id }.map(\.to).compactMap(document.node)
    }

    /// Every node upstream of `id` (not including it).
    static func upstream(of id: UUID, edges: [FCEdge]) -> Set<UUID> {
        var seen = Set<UUID>()
        var stack = edges.filter { $0.to == id }.map(\.from)
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            stack += edges.filter { $0.to == next }.map(\.from)
        }
        return seen
    }

    /// Source cards that ultimately feed `id`, in canvas order.
    static func rootSources(of id: UUID, in document: FCDocument) -> [FCNode] {
        let ids = upstream(of: id, edges: document.edges)
        return document.nodes.filter { ids.contains($0.id) && $0.kind.isSource }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// True when adding `from → to` would close a loop.
    static func wouldCreateCycle(from: UUID, to: UUID, edges: [FCEdge]) -> Bool {
        from == to || upstream(of: from, edges: edges).contains(to)
    }

    /// Kahn's algorithm over the nodes that take part in the graph (frames
    /// are ignored). Ties run left to right, then top to bottom.
    static func topologicalOrder(_ document: FCDocument, restrictTo subset: Set<UUID>? = nil) throws -> [UUID] {
        let nodes = document.nodes.filter { $0.kind != .frame && (subset?.contains($0.id) ?? true) }
        let ids = Set(nodes.map(\.id))
        let edges = document.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        if edges.contains(where: { $0.from == $0.to }) { throw FCGraphError.selfLoop }
        var indegree: [UUID: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        for edge in edges { indegree[edge.to, default: 0] += 1 }
        let order: (FCNode, FCNode) -> Bool = { ($0.x, $0.y) < ($1.x, $1.y) }
        var ready = nodes.filter { indegree[$0.id] == 0 }.sorted(by: order)
        var result: [UUID] = []
        while !ready.isEmpty {
            let node = ready.removeFirst()
            result.append(node.id)
            for edge in edges where edge.from == node.id {
                indegree[edge.to, default: 0] -= 1
                if indegree[edge.to] == 0, let next = document.node(edge.to) {
                    ready.append(next)
                    ready.sort(by: order)
                }
            }
        }
        if result.count < nodes.count {
            let stuck = Set(nodes.map(\.id)).subtracting(result)
            throw FCGraphError.cycle(cycleNames(stuck, edges: edges, document: document))
        }
        return result
    }

    /// Names along one loop among `stuck` nodes, for the error message.
    private static func cycleNames(_ stuck: Set<UUID>, edges: [FCEdge], document: FCDocument) -> [String] {
        guard let start = stuck.sorted(by: { $0.uuidString < $1.uuidString }).first else { return [] }
        var path: [UUID] = [start]
        var current = start
        for _ in 0..<(stuck.count + 1) {
            guard let next = edges.first(where: { $0.from == current && stuck.contains($0.to) })?.to else { break }
            if let loopStart = path.firstIndex(of: next) {
                let loop = Array(path[loopStart...]) + [next]
                return loop.compactMap { document.node($0)?.title }
            }
            path.append(next)
            current = next
        }
        return stuck.compactMap { document.node($0)?.title }
    }
}

// MARK: - Source kinds

enum FCSourceKinds {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "avif"]

    static func kind(forFile url: URL) -> FCNodeKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if ["webloc"].contains(ext) { return .link }
        return .file
    }
}
