import CoreGraphics
import Foundation

// Templates: ready-made graphs with empty source slots. Built-ins live in
// code; "Save as template" writes the current canvas's structure (no outputs,
// no copied files) to FlowCanvas/Templates/<id>.json.

struct FCTemplate: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var symbol: String
    var isBuiltIn: Bool
    var nodes: [FCNode]
    var edges: [FCEdge]
}

enum FCTemplates {
    static let competitorPricingID = "builtin.competitor-pricing"
    static let summarizePDFID = "builtin.summarize-pdf"
    static let screenshotsToNotesID = "builtin.screenshots-notes"
    static let researchBriefID = "builtin.research-brief"

    static var builtIn: [FCTemplate] {
        [competitorPricing(), summarizePDF(), screenshotsToNotes(), researchBrief()]
    }

    static func template(id: String, user: [FCTemplate]) -> FCTemplate? {
        (builtIn + user).first { $0.id == id }
    }

    // MARK: Built-ins

    static func competitorPricing() -> FCTemplate {
        var nodes: [FCNode] = []
        var edges: [FCEdge] = []
        let extract = FCNode(kind: .extract, title: "Pricing, plans, features", at: CGPoint(x: 420, y: 420),
                             config: FCActionConfig(fields: ["price", "plans", "features"]))
        for index in 0..<5 {
            var slot = FCNode(kind: .link, title: "Competitor \(index + 1)", at: CGPoint(x: 60, y: 40 + Double(index) * 240))
            slot.status = .empty("Paste a competitor's pricing page link")
            nodes.append(slot)
            edges.append(FCEdge(from: slot.id, to: extract.id))
        }
        let compare = FCNode(kind: .compare, title: "Compare competitors", at: CGPoint(x: 800, y: 420),
                             config: FCActionConfig(prompt: "Compare pricing, plans and features. Who is cheapest, who offers the most?"))
        let report = FCNode(kind: .report, title: "Competitor report", at: CGPoint(x: 1180, y: 420),
                            config: FCActionConfig(prompt: "A competitor pricing comparison for a product team."))
        nodes += [extract, compare, report]
        edges += [FCEdge(from: extract.id, to: compare.id), FCEdge(from: compare.id, to: report.id)]
        return FCTemplate(id: competitorPricingID, name: "Competitor pricing comparison",
                          summary: "5 links → extract price, plans, features → compare → report with source links",
                          symbol: "chart.bar.doc.horizontal", isBuiltIn: true, nodes: nodes, edges: edges)
    }

    static func summarizePDF() -> FCTemplate {
        var pdf = FCNode(kind: .pdf, title: "PDF", at: CGPoint(x: 60, y: 160))
        pdf.status = .empty("Drop a PDF here")
        let summary = FCNode(kind: .summarize, title: "Summary", at: CGPoint(x: 420, y: 60))
        let chat = FCNode(kind: .chat, title: "Ask the PDF", at: CGPoint(x: 420, y: 320))
        return FCTemplate(id: summarizePDFID, name: "Summarize a PDF",
                          summary: "Drop a PDF → key points, plus a chat that answers from it with citations",
                          symbol: "doc.richtext", isBuiltIn: true, nodes: [pdf, summary, chat],
                          edges: [FCEdge(from: pdf.id, to: summary.id), FCEdge(from: pdf.id, to: chat.id)])
    }

    static func screenshotsToNotes() -> FCTemplate {
        var nodes: [FCNode] = []
        var edges: [FCEdge] = []
        let notes = FCNode(kind: .custom, title: "Organized notes", at: CGPoint(x: 420, y: 320),
                           config: FCActionConfig(prompt: "Turn the text from these screenshots into organized notes in Markdown: a title, short sections with \"## \" headings, and \"- \" bullets. Keep every number, name and date. Don't invent anything."))
        for index in 0..<3 {
            var slot = FCNode(kind: .image, title: "Screenshot \(index + 1)", at: CGPoint(x: 60, y: 40 + Double(index) * 310))
            slot.status = .empty("Drop a screenshot here")
            nodes.append(slot)
            edges.append(FCEdge(from: slot.id, to: notes.id))
        }
        nodes.append(notes)
        return FCTemplate(id: screenshotsToNotesID, name: "Screenshots to notes",
                          summary: "3 screenshots → Vision OCR → organized Markdown notes",
                          symbol: "camera.viewfinder", isBuiltIn: true, nodes: nodes, edges: edges)
    }

    static func researchBrief() -> FCTemplate {
        var nodes: [FCNode] = []
        var edges: [FCEdge] = []
        let summary = FCNode(kind: .summarize, title: "Key points", at: CGPoint(x: 420, y: 40))
        let facts = FCNode(kind: .extract, title: "Facts", at: CGPoint(x: 420, y: 380),
                           config: FCActionConfig(fields: ["main claim", "key numbers", "date"]))
        let report = FCNode(kind: .report, title: "Research brief", at: CGPoint(x: 800, y: 220),
                            config: FCActionConfig(prompt: "A one-page research brief: what the sources say, where they agree or disagree, open questions."))
        for index in 0..<3 {
            var slot = FCNode(kind: .link, title: "Link \(index + 1)", at: CGPoint(x: 60, y: 40 + Double(index) * 240))
            slot.status = .empty("Paste an article or page link")
            nodes.append(slot)
            edges.append(FCEdge(from: slot.id, to: summary.id))
            edges.append(FCEdge(from: slot.id, to: facts.id))
        }
        nodes += [summary, facts, report]
        edges += [FCEdge(from: summary.id, to: report.id), FCEdge(from: facts.id, to: report.id)]
        return FCTemplate(id: researchBriefID, name: "Research brief from links",
                          summary: "3 links → key points + facts table → one-page brief with sources",
                          symbol: "books.vertical", isBuiltIn: true, nodes: nodes, edges: edges)
    }

    // MARK: Instantiate / capture

    /// Fresh ids for every node and edge, so a template can be used twice.
    static func instantiate(_ template: FCTemplate, name: String? = nil) -> FCDocument {
        var document = FCDocument(name: name ?? template.name)
        document.templateID = template.id
        let (nodes, edges) = remap(template.nodes, template.edges)
        document.nodes = nodes
        document.edges = edges
        return document
    }

    static func remap(_ nodes: [FCNode], _ edges: [FCEdge], offset: CGPoint = .zero) -> ([FCNode], [FCEdge]) {
        var mapping: [UUID: UUID] = [:]
        let newNodes: [FCNode] = nodes.map { node in
            var copy = node
            copy.id = UUID()
            copy.x += Double(offset.x)
            copy.y += Double(offset.y)
            mapping[node.id] = copy.id
            return copy
        }
        let newEdges: [FCEdge] = edges.compactMap { edge in
            guard let from = mapping[edge.from], let to = mapping[edge.to] else { return nil }
            return FCEdge(from: from, to: to)
        }
        return (newNodes, newEdges)
    }

    /// The canvas's structure as a template: links and notes keep their
    /// content, copied files become empty slots, outputs and chats are dropped.
    static func capture(_ document: FCDocument, name: String) -> FCTemplate {
        let nodes: [FCNode] = document.nodes.map { node in
            var copy = node
            copy.output = nil
            copy.run = nil
            copy.chat = []
            switch node.kind {
            case .note:
                copy.status = .ready
            case .link:
                if let url = node.source?.url {
                    copy.source = FCSource(url: url)
                    copy.status = .idle
                } else {
                    copy.source = FCSource()
                    copy.status = .empty("Paste a link")
                }
            case .image, .pdf, .file:
                copy.source = FCSource()
                copy.status = .empty("Drop a \(node.kind == .image ? "screenshot" : node.kind == .pdf ? "PDF" : "file") here")
            case .frame:
                copy.status = .ready
            default:
                copy.status = .idle
            }
            return copy
        }
        let actions = nodes.filter { $0.kind.isAction }.map(\.kind.title)
        return FCTemplate(id: "user." + UUID().uuidString, name: name,
                          summary: actions.isEmpty ? "\(nodes.count) cards" : actions.joined(separator: " → "),
                          symbol: "square.grid.3x1.below.line.grid.1x2", isBuiltIn: false, nodes: nodes, edges: document.edges)
    }
}
