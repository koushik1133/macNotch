import AppKit
import Combine
import Foundation
import SwiftUI

// Editor state for one open canvas: the document, selection, viewport,
// tools, the undo/redo command stack, ingestion and run orchestration, the
// AI plan preview and autosave. Views observe this; nothing here draws.

enum FCLayout {
    /// Ports sit at the vertical centre of the card header.
    static let portY: CGFloat = 24
    static let headerHeight: CGFloat = 48
    static let estimatedHeight: CGFloat = 170
    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 2.5
    static let gridSpacing: CGFloat = 24
}

/// Nodes and edges at one point in time (what undo restores).
struct FCSnapshot: Equatable {
    var nodes: [FCNode]
    var edges: [FCEdge]
}

struct FCCommand {
    var name: String
    var before: FCSnapshot
    var after: FCSnapshot
}

struct FCPendingEdge: Equatable {
    var from: UUID
    /// Pointer, in canvas (screen) coordinates.
    var point: CGPoint
    var target: UUID?
}

struct FCGhostPlan {
    var plan: FCPlan
    var nodes: [FCNode]
    var edges: [FCEdge]
}

@MainActor
final class FCEditor: ObservableObject {
    enum Tool: String, CaseIterable { case select, hand, connect, frame }

    let library: FCLibrary
    let ai: FCAI
    let runner: FCRunner

    @Published private(set) var document: FCDocument
    @Published var selection: Set<UUID> = []
    @Published var selectedEdge: UUID?
    @Published var zoom: CGFloat = 1
    @Published var offset: CGSize = .zero
    @Published var tool: Tool = .select
    @Published var marquee: CGRect?
    @Published var pendingEdge: FCPendingEdge?
    @Published var fullscreenNodeID: UUID?
    @Published var inspectorVisible = true
    @Published var sidebarVisible = true
    @Published var editingNoteID: UUID?
    @Published var flashMessage: String?
    @Published var goal = ""
    @Published var isPlanning = false
    @Published var ghost: FCGhostPlan?
    @Published private(set) var runningIDs: Set<UUID> = []
    @Published private(set) var isRunningAll = false
    @Published var spaceHeld = false
    @Published var renamingCanvasID: UUID?
    @Published var renameDraft = ""
    @Published var chatDrafts: [UUID: String] = [:]
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var showTemplates = false

    /// Set by the canvas view.
    var canvasSize: CGSize = CGSize(width: 900, height: 600)
    var canvasFrameInWindow: CGRect = .zero
    private(set) var measuredSizes: [UUID: CGSize] = [:]

    weak var window: NSWindow?
    var onSendToTray: (([URL]) -> Void)?
    var onSendToSpace: ((_ title: String, _ markdown: String, _ url: URL?) -> Void)?

    private var undoStack: [FCCommand] = []
    private var redoStack: [FCCommand] = []
    private var interactionBefore: FCSnapshot?
    private var moveOrigins: [UUID: CGPoint] = [:]
    private var marqueeStart: CGPoint?
    private var marqueeBase: Set<UUID> = []
    private var panStart: CGSize?
    private var resizeOrigin: CGSize?
    private var saveTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var ingestTasks: [UUID: Task<Void, Never>] = [:]
    /// Every run in flight (Run, Run all, chat), so Stop and a canvas
    /// switch cancel all of them, not only the latest.
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    /// Cards removed by a command or an undo, with their latest content, so
    /// undo/redo brings them back as they were (and results that arrive
    /// while they're gone aren't lost).
    private var removedNodes: [UUID: FCNode] = [:]
    /// The canvas a plan request was made for (a switch drops the reply).
    private var planningDocumentID: UUID?
    nonisolated(unsafe) private var terminationObserver: (any NSObjectProtocol)?
    /// Tests: save synchronously instead of after a short pause.
    var autosaveDelay: Duration = .milliseconds(700)

    init(library: FCLibrary? = nil, ai: FCAI? = nil, document: FCDocument? = nil) {
        let library = library ?? .shared
        let ai = ai ?? .shared
        self.library = library
        self.ai = ai
        self.runner = FCRunner(ai: ai)
        if let document {
            self.document = document
        } else if let recent = library.canvases.first, let loaded = try? library.load(recent.id) {
            self.document = loaded
        } else {
            self.document = library.create()
        }
        applyViewport()
        // A pending debounced save would be lost if SparkV quits first.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveIfPending() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// True while a change is waiting for the debounced autosave.
    var hasPendingSave: Bool { saveTask != nil }

    func saveIfPending() {
        if saveTask != nil { saveNow() }
    }

    // MARK: - Geometry

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + offset.width, y: point.y * zoom + offset.height)
    }

    func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / zoom, y: (point.y - offset.height) / zoom)
    }

    func size(of node: FCNode) -> CGSize {
        if node.kind == .frame { return CGSize(width: node.width, height: node.height ?? 380) }
        return measuredSizes[node.id] ?? CGSize(width: node.width, height: FCLayout.estimatedHeight)
    }

    func rect(of node: FCNode) -> CGRect {
        CGRect(origin: node.position, size: size(of: node))
    }

    func outputPort(_ node: FCNode) -> CGPoint { CGPoint(x: node.x + node.width, y: node.y + Double(FCLayout.portY)) }
    func inputPort(_ node: FCNode) -> CGPoint { CGPoint(x: node.x, y: node.y + Double(FCLayout.portY)) }

    func setMeasured(_ sizes: [UUID: CGSize]) {
        for (id, size) in sizes { measuredSizes[id] = size }
    }

    /// Topmost card under a world point (cards above frames).
    func node(at world: CGPoint) -> FCNode? {
        if let card = document.nodes.reversed().first(where: { $0.kind != .frame && rect(of: $0).insetBy(dx: -6, dy: -6).contains(world) }) {
            return card
        }
        return document.nodes.reversed().first { $0.kind == .frame && rect(of: $0).contains(world) }
    }

    var selectedNodes: [FCNode] { document.nodes.filter { selection.contains($0.id) } }
    var primarySelection: FCNode? { selection.count == 1 ? selectedNodes.first : nil }

    /// Selection bounds in canvas (screen) coordinates.
    var selectionScreenRect: CGRect? {
        let rects = selectedNodes.map(rect(of:))
        guard let first = rects.first else { return nil }
        let world = rects.dropFirst().reduce(first) { $0.union($1) }
        let origin = toScreen(world.origin)
        return CGRect(x: origin.x, y: origin.y, width: world.width * zoom, height: world.height * zoom)
    }

    // MARK: - Viewport

    private func applyViewport() {
        zoom = CGFloat(document.viewport.zoom).fcClamped(FCLayout.minZoom, FCLayout.maxZoom)
        offset = CGSize(width: document.viewport.x, height: document.viewport.y)
    }

    func pan(by delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        scheduleSave()
    }

    func zoom(by factor: CGFloat, around screenPoint: CGPoint? = nil) {
        let anchor = screenPoint ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let world = toWorld(anchor)
        zoom = (zoom * factor).fcClamped(FCLayout.minZoom, FCLayout.maxZoom)
        offset = CGSize(width: anchor.x - world.x * zoom, height: anchor.y - world.y * zoom)
        scheduleSave()
    }

    func setZoom(_ value: CGFloat) {
        zoom(by: value / zoom)
    }

    /// Cmd-0: every card in view.
    func fitAll() {
        let rects = document.nodes.map(rect(of:))
        guard let first = rects.first else {
            zoom = 1
            offset = .zero
            return
        }
        fit(rects.dropFirst().reduce(first) { $0.union($1) }, maxZoom: 1.1)
    }

    /// Z: the selection fills the view.
    func zoomToSelection() {
        let rects = selectedNodes.map(rect(of:))
        guard let first = rects.first else { fitAll(); return }
        fit(rects.dropFirst().reduce(first) { $0.union($1) }, maxZoom: 1.6)
    }

    private func fit(_ world: CGRect, maxZoom: CGFloat) {
        let padding: CGFloat = 80
        let available = CGSize(width: max(200, canvasSize.width - padding * 2), height: max(200, canvasSize.height - padding * 2 - 60))
        let scale = min(available.width / max(world.width, 1), available.height / max(world.height, 1)).fcClamped(FCLayout.minZoom, maxZoom)
        // The camera moves on screen: strong ease-in-out. Reduce Motion jumps.
        withAnimation(SparkVMotion.reduceMotion ? nil : SparkVMotion.easeInOut(0.25)) {
            zoom = scale
            offset = CGSize(width: canvasSize.width / 2 - world.midX * scale, height: canvasSize.height / 2 - world.midY * scale + 10)
        }
        scheduleSave()
    }

    /// Where new cards go when there's no drop point: left of the view centre.
    var insertionPoint: CGPoint {
        let center = toWorld(CGPoint(x: canvasSize.width * 0.4, y: canvasSize.height * 0.4))
        return CGPoint(x: center.x.rounded(), y: center.y.rounded())
    }

    // MARK: - Commands (undo / redo)

    private var snapshot: FCSnapshot { FCSnapshot(nodes: document.nodes, edges: document.edges) }

    /// An undoable change to the graph.
    func perform(_ name: String, _ change: (inout FCDocument) -> Void) {
        let before = snapshot
        change(&document)
        let after = snapshot
        guard before != after else { return }
        rememberRemoved(before.nodes)
        push(FCCommand(name: name, before: before, after: after))
        scheduleSave()
    }

    /// Keeps the latest content of cards that just left the canvas.
    private func rememberRemoved(_ previous: [FCNode]) {
        let ids = Set(document.nodes.map(\.id))
        for node in previous where !ids.contains(node.id) { removedNodes[node.id] = node }
        for id in ids { removedNodes.removeValue(forKey: id) }
    }

    private func push(_ command: FCCommand) {
        undoStack.append(command)
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    /// A runtime change (status, output, chat, extracted text): not undoable.
    func update(_ id: UUID, _ change: (inout FCNode) -> Void) {
        guard let index = document.index(of: id) else {
            // Removed (deleted or undone) while reading or running: keep the
            // result with the card so undo/redo brings it back complete.
            if var removed = removedNodes[id] {
                change(&removed)
                removedNodes[id] = removed
            }
            return
        }
        var node = document.nodes[index]
        change(&node)
        guard node != document.nodes[index] else { return }
        document.nodes[index] = node
        scheduleSave()
    }

    func undo() {
        guard let command = undoStack.popLast() else { return }
        restore(command.before)
        redoStack.append(command)
        canUndo = !undoStack.isEmpty
        canRedo = true
        flash("Undid \(command.name.lowercased())")
    }

    func redo() {
        guard let command = redoStack.popLast() else { return }
        restore(command.after)
        undoStack.append(command)
        canUndo = true
        canRedo = !redoStack.isEmpty
        flash("Redid \(command.name.lowercased())")
    }

    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    /// Which cards exist, their position/size and the connections come from
    /// the snapshot. Everything edited outside the command stack (note text,
    /// titles, settings, read text, outputs, chats) keeps its latest value,
    /// so undoing an unrelated move never reverts a rename or a note, and
    /// redoing an "Add" brings the card back with what was typed into it.
    private func restore(_ snapshot: FCSnapshot) {
        let previous = document.nodes
        let current = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        document.nodes = snapshot.nodes.map { node in
            guard let live = current[node.id] ?? removedNodes[node.id] else { return node }
            var merged = live
            merged.x = node.x
            merged.y = node.y
            merged.width = node.width
            merged.height = node.height
            return merged
        }
        rememberRemoved(previous)
        let ids = Set(document.nodes.map(\.id))
        document.edges = snapshot.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        if let fullscreen = fullscreenNodeID, !ids.contains(fullscreen) { fullscreenNodeID = nil }
        if let editing = editingNoteID, !ids.contains(editing) { editingNoteID = nil }
        selection = selection.intersection(ids)
        if let edge = selectedEdge, !document.edges.contains(where: { $0.id == edge }) { selectedEdge = nil }
        scheduleSave()
    }

    // MARK: - Interactive moves

    func beginMove(_ id: UUID, extend: Bool) {
        if !selection.contains(id) {
            selection = extend ? selection.union([id]) : [id]
        }
        selectedEdge = nil
        interactionBefore = snapshot
        var moving = Set(selection)
        // Moving a frame carries the cards inside it.
        for frame in selectedNodes where frame.kind == .frame {
            let area = rect(of: frame)
            for node in document.nodes where node.kind != .frame {
                let r = rect(of: node)
                if area.contains(CGPoint(x: r.midX, y: r.midY)) { moving.insert(node.id) }
            }
        }
        moveOrigins = Dictionary(uniqueKeysWithValues: document.nodes.filter { moving.contains($0.id) }.map { ($0.id, $0.position) })
    }

    var isMoving: Bool { !moveOrigins.isEmpty }
    var isResizing: Bool { resizeOrigin != nil }

    func move(by translation: CGSize) {
        guard !moveOrigins.isEmpty else { return }
        let dx = translation.width / zoom, dy = translation.height / zoom
        for index in document.nodes.indices {
            guard let origin = moveOrigins[document.nodes[index].id] else { continue }
            document.nodes[index].x = Double((origin.x + dx).rounded())
            document.nodes[index].y = Double((origin.y + dy).rounded())
        }
    }

    func endMove() {
        moveOrigins = [:]
        finishInteraction(named: selection.count > 1 ? "Move cards" : "Move card")
    }

    func beginResize(_ id: UUID) {
        guard let node = document.node(id) else { return }
        interactionBefore = snapshot
        resizeOrigin = CGSize(width: node.width, height: node.height ?? 380)
    }

    func resize(_ id: UUID, by translation: CGSize) {
        guard let origin = resizeOrigin, let index = document.index(of: id) else { return }
        document.nodes[index].width = Double(max(220, origin.width + translation.width / zoom).rounded())
        document.nodes[index].height = Double(max(140, origin.height + translation.height / zoom).rounded())
    }

    func endResize() {
        resizeOrigin = nil
        finishInteraction(named: "Resize frame")
    }

    private func finishInteraction(named name: String) {
        guard let before = interactionBefore else { return }
        interactionBefore = nil
        let after = snapshot
        if before != after {
            push(FCCommand(name: name, before: before, after: after))
            scheduleSave()
        }
    }

    // MARK: - Background gestures (pan / marquee)

    var pansOnDrag: Bool { tool == .hand || spaceHeld || NSEvent.modifierFlags.contains(.option) }

    func backgroundDragChanged(start: CGPoint, location: CGPoint, translation: CGSize) {
        if tool == .frame {
            if marqueeStart == nil { marqueeStart = start }
            marquee = CGRect.fc(from: start, to: location)
            return
        }
        if panStart != nil || (marqueeStart == nil && pansOnDrag) {
            if panStart == nil { panStart = offset }
            offset = CGSize(width: panStart!.width + translation.width, height: panStart!.height + translation.height)
            return
        }
        if marqueeStart == nil {
            marqueeStart = start
            marqueeBase = NSEvent.modifierFlags.contains(.shift) ? selection : []
            selectedEdge = nil
        }
        let screenRect = CGRect.fc(from: start, to: location)
        marquee = screenRect
        let worldRect = CGRect.fc(from: toWorld(screenRect.origin), to: toWorld(CGPoint(x: screenRect.maxX, y: screenRect.maxY)))
        let hits = document.nodes.filter { node in
            let r = rect(of: node)
            return node.kind == .frame ? worldRect.contains(r) : worldRect.intersects(r)
        }.map(\.id)
        selection = marqueeBase.union(hits)
    }

    func backgroundDragEnded() {
        if tool == .frame, let rect = marquee {
            let world = CGRect.fc(from: toWorld(rect.origin), to: toWorld(CGPoint(x: rect.maxX, y: rect.maxY)))
            if world.width > 60 && world.height > 40 {
                var frame = FCNode(kind: .frame, title: "Frame", at: world.origin)
                frame.width = Double(world.width.rounded())
                frame.height = Double(world.height.rounded())
                perform("Add frame") { $0.nodes.insert(frame, at: 0) }
                selection = [frame.id]
            }
            tool = .select
        }
        if panStart != nil { scheduleSave() }
        panStart = nil
        marqueeStart = nil
        marquee = nil
    }

    /// Click on empty canvas: select the edge under it, or clear.
    func backgroundTapped(at screen: CGPoint) {
        editingNoteID = nil
        if let edge = edge(near: screen) {
            selectedEdge = edge.id
            selection = []
        } else {
            selectedEdge = nil
            if !NSEvent.modifierFlags.contains(.shift) { selection = [] }
        }
        window?.makeFirstResponder(nil)
    }

    func backgroundDoubleTapped(at screen: CGPoint) {
        addNote(at: toWorld(screen), edit: true)
    }

    // MARK: - Edges

    func edgePath(_ edge: FCEdge) -> Path? {
        guard let from = document.node(edge.from), let to = document.node(edge.to) else { return nil }
        return Self.curve(from: toScreen(outputPort(from)), to: toScreen(inputPort(to)))
    }

    static func curve(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let dx = max(50, abs(end.x - start.x) * 0.5)
        path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
        return path
    }

    /// Edge within 7 pt of a screen point (sampled along the curve).
    func edge(near point: CGPoint) -> FCEdge? {
        var best: (FCEdge, CGFloat)?
        for edge in document.edges {
            guard let from = document.node(edge.from), let to = document.node(edge.to) else { continue }
            let a = toScreen(outputPort(from)), d = toScreen(inputPort(to))
            let dx = max(50, abs(d.x - a.x) * 0.5)
            let b = CGPoint(x: a.x + dx, y: a.y), c = CGPoint(x: d.x - dx, y: d.y)
            for step in 0...40 {
                let t = CGFloat(step) / 40, u = 1 - t
                let x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x
                let y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
                let distance = hypot(x - point.x, y - point.y)
                if distance < 7, distance < (best?.1 ?? .infinity) { best = (edge, distance) }
            }
        }
        return best?.0
    }

    func beginConnection(from id: UUID, at screen: CGPoint) {
        pendingEdge = FCPendingEdge(from: id, point: screen, target: nil)
    }

    func updateConnection(to screen: CGPoint) {
        guard var pending = pendingEdge else { return }
        pending.point = screen
        let target = node(at: toWorld(screen))
        pending.target = target.flatMap { $0.kind.hasInputPort && $0.id != pending.from ? $0.id : nil }
        pendingEdge = pending
    }

    func endConnection() {
        guard let pending = pendingEdge else { return }
        pendingEdge = nil
        if let target = node(at: toWorld(pending.point)), target.id != pending.from {
            connect(pending.from, to: target.id)
        }
    }

    @discardableResult
    func connect(_ from: UUID, to: UUID) -> Bool {
        guard let source = document.node(from), let target = document.node(to) else { return false }
        guard source.kind.hasOutputPort else { return false }
        guard target.kind.hasInputPort else {
            flash("Only AI steps take inputs. Connect \(source.title) to an action card.")
            return false
        }
        if document.edges.contains(where: { $0.from == from && $0.to == to }) { return false }
        if FCGraph.wouldCreateCycle(from: from, to: to, edges: document.edges) {
            flash("That connection would make a loop, so it wasn't added.")
            return false
        }
        perform("Connect") { $0.edges.append(FCEdge(from: from, to: to)) }
        markStale(downstreamOf: from, including: to)
        return true
    }

    // MARK: - Selection / deletion

    func select(_ id: UUID, extend: Bool) {
        selectedEdge = nil
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func selectAll() {
        selection = Set(document.nodes.map(\.id))
        selectedEdge = nil
    }

    func deleteSelection() {
        if let edge = selectedEdge {
            let target = document.edges.first { $0.id == edge }?.to
            perform("Delete connection") { $0.edges.removeAll { $0.id == edge } }
            selectedEdge = nil
            if let target { markStale(downstreamOf: target, including: target) }
            return
        }
        guard !selection.isEmpty else { return }
        let ids = selection
        // Reading continues: the result is kept with the removed card, so
        // Undo brings it back ready instead of stuck on "Loading".
        perform(ids.count > 1 ? "Delete cards" : "Delete card") { document in
            document.nodes.removeAll { ids.contains($0.id) }
            document.edges.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        }
        selection = []
        if let fullscreen = fullscreenNodeID, ids.contains(fullscreen) { fullscreenNodeID = nil }
    }

    func duplicateSelection() {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }
        let ids = Set(nodes.map(\.id))
        let edges = document.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        let (copies, copiedEdges) = FCTemplates.remap(nodes, edges, offset: CGPoint(x: 40, y: 40))
        perform("Duplicate") { document in
            document.nodes += copies
            document.edges += copiedEdges
        }
        selection = Set(copies.map(\.id))
    }

    func toggleFullscreen() {
        if fullscreenNodeID != nil { fullscreenNodeID = nil; return }
        guard let node = primarySelection ?? selectedNodes.first else {
            flash("Select a card first")
            return
        }
        fullscreenNodeID = node.id
    }

    // MARK: - Adding cards

    func addNote(at point: CGPoint? = nil, text: String = "", edit: Bool = false) {
        var source = FCSource()
        source.text = text
        var node = FCNode(kind: .note, title: Self.noteTitle(text), at: point ?? insertionPoint, source: source)
        node.status = .ready
        perform("Add note") { $0.nodes.append(node) }
        selection = [node.id]
        if edit { editingNoteID = node.id }
    }

    func addAction(_ kind: FCNodeKind, at point: CGPoint? = nil) {
        let selectedSources = selectedNodes.filter { $0.kind.hasOutputPort && $0.kind != .frame }
        var origin = point ?? insertionPoint
        if point == nil, !selectedSources.isEmpty {
            let right = selectedSources.map { $0.x + $0.width }.max() ?? Double(origin.x)
            let mid = selectedSources.map(\.y).reduce(0, +) / Double(selectedSources.count)
            origin = CGPoint(x: right + 120, y: mid)
        }
        var config = FCActionConfig()
        if kind == .extract { config.fields = ["price", "plans", "features"] }
        if kind == .translate { config.language = TrayAISettings.defaultTranslateTarget }
        let node = FCNode(kind: kind, at: origin, config: config)
        perform("Add \(kind.title)") { document in
            document.nodes.append(node)
            for source in selectedSources where source.id != node.id {
                document.edges.append(FCEdge(from: source.id, to: node.id))
            }
        }
        selection = [node.id]
    }

    func addFrame() {
        tool = .frame
        flash("Drag on the canvas to draw a frame")
    }

    /// Empty source slot (link to paste, or file to drop).
    func addSlot(_ kind: FCNodeKind, at point: CGPoint? = nil) {
        var node = FCNode(kind: kind, at: point ?? insertionPoint)
        node.status = .empty(kind == .link ? "Paste a link" : "Drop a file here or click Choose…")
        perform("Add \(kind.title.lowercased())") { $0.nodes.append(node) }
        selection = [node.id]
    }

    /// Adds dropped / pasted / handed-in items as cards and starts reading them.
    @discardableResult
    func add(_ inputs: [FlowCanvasInput], at point: CGPoint? = nil) -> [UUID] {
        guard !inputs.isEmpty else { return [] }
        let origin = point ?? insertionPoint
        var nodes: [FCNode] = []
        var y = origin.y
        for (index, input) in inputs.enumerated() {
            let at = CGPoint(x: origin.x + CGFloat(index % 2) * 24, y: y)
            y += Self.estimatedHeight(of: input) + 30
            switch input {
            case .text(let text):
                var source = FCSource()
                source.text = text
                var node = FCNode(kind: .note, title: Self.noteTitle(text), at: at, source: source)
                node.status = .ready
                nodes.append(node)
            case .url(let url):
                var node = FCNode(kind: .link, title: url.host ?? "Link", at: at, source: FCSource(url: url))
                node.status = .loading("Fetching")
                nodes.append(node)
            case .image(let url), .pdf(let url), .file(let url):
                let kind: FCNodeKind = {
                    if case .image = input { return .image }
                    if case .pdf = input { return .pdf }
                    return FCSourceKinds.kind(forFile: url) == .link ? .file : FCSourceKinds.kind(forFile: url)
                }()
                var node = FCNode(kind: kind, title: url.deletingPathExtension().lastPathComponent, at: at, source: FCSource(url: url))
                node.status = .loading("Copying")
                nodes.append(node)
            }
        }
        perform(nodes.count > 1 ? "Add \(nodes.count) cards" : "Add card") { $0.nodes += nodes }
        selection = Set(nodes.map(\.id))
        for (node, input) in zip(nodes, inputs) { ingest(node.id, input) }
        return nodes.map(\.id)
    }

    /// Pasted image data (no file): saved as a PNG asset, then read.
    func addImageData(_ data: Data, at point: CGPoint? = nil) {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            flash("Couldn't read the pasted image")
            return
        }
        do {
            let name = try FCLibrary.writeAsset(png, name: "Pasted image.png", into: library.assetsDirectory(for: document.id))
            var source = FCSource()
            source.assetName = name
            var node = FCNode(kind: .image, title: "Pasted image", at: point ?? insertionPoint, source: source)
            node.status = .loading("Reading")
            perform("Paste image") { $0.nodes.append(node) }
            selection = [node.id]
            let url = library.assetURL(name, in: document.id)
            ingestTasks[node.id] = Task { [weak self] in await self?.extract(node.id, kind: .image, file: url) }
        } catch {
            flash("Couldn't save the pasted image: \(error.localizedDescription)")
        }
    }

    func paste(at point: CGPoint? = nil) {
        let pasteboard = NSPasteboard.general
        let inputs = FCIngest.inputs(from: pasteboard)
        if !inputs.isEmpty {
            add(inputs, at: point)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            addImageData(data, at: point)
        } else {
            flash("Nothing to paste")
        }
    }

    /// Rough card heights, so cards added together don't overlap.
    static func estimatedHeight(of input: FlowCanvasInput) -> CGFloat {
        switch input {
        case .text: 150
        case .url: 230
        case .image: 300
        case .pdf, .file: 210
        }
    }

    static func noteTitle(_ text: String) -> String {
        let first = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*- "))
        return trimmed.isEmpty ? "Text note" : String(trimmed.prefix(40))
    }

    // MARK: - Ingestion

    func assetURL(for node: FCNode) -> URL? {
        node.source?.assetName.map { library.assetURL($0, in: document.id) }
    }

    private func ingest(_ id: UUID, _ input: FlowCanvasInput) {
        ingestTasks[id]?.cancel()
        switch input {
        case .text:
            return
        case .url(let url):
            ingestTasks[id] = Task { [weak self] in await self?.fetchLink(id, url) }
        case .image(let url), .pdf(let url), .file(let url):
            let directory = library.assetsDirectory(for: document.id)
            ingestTasks[id] = Task { [weak self] in
                let copied: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                    Result { try FCLibrary.copyAsset(url, into: directory) }
                }.value
                guard let self, !Task.isCancelled else { return }
                switch copied {
                case .success(let name):
                    self.update(id) { $0.source?.assetName = name }
                    let kind = self.document.node(id)?.kind ?? .file
                    await self.extract(id, kind: kind, file: directory.appendingPathComponent(name))
                case .failure(let error):
                    self.update(id) { $0.status = .failed("Couldn't copy the file: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func extract(_ id: UUID, kind: FCNodeKind, file: URL) async {
        update(id) { $0.status = .loading(kind == .image ? "Reading text" : "Reading") }
        do {
            var content: FCSource
            switch kind {
            case .image: content = try await FCIngest.image(at: file)
            case .pdf: content = try await FCIngest.pdf(at: file)
            default: content = try await FCIngest.file(at: file)
            }
            if kind == .image, let groq = ai.groqIfAllowed() {
                update(id) { $0.status = .loading("Describing") }
                if let description = try? await FCIngest.describeImage(at: file, groq: groq) {
                    content.imageDescription = description
                }
            }
            guard !Task.isCancelled else { return }
            applySource(id, content)
        } catch is CancellationError {
            return
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    private func fetchLink(_ id: UUID, _ url: URL) async {
        update(id) { $0.status = .loading("Fetching") }
        do {
            let content = try await FCIngest.link(url)
            guard !Task.isCancelled else { return }
            applySource(id, content)
        } catch is CancellationError {
            return
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    private func applySource(_ id: UUID, _ content: FCSource) {
        update(id) { node in
            let keep = node.source
            var merged = content
            merged.assetName = keep?.assetName ?? content.assetName
            merged.url = content.url ?? keep?.url
            node.source = merged
            let defaults = [node.kind.title, "Link", node.source?.url?.host ?? "", node.source?.url?.deletingPathExtension().lastPathComponent ?? ""]
            if let title = content.title, !title.isEmpty, defaults.contains(node.title) || node.title.hasPrefix("Competitor ") || node.title.hasPrefix("Link ") || node.title.hasPrefix("Screenshot ") {
                node.title = String(title.prefix(60))
            }
            node.status = .ready
        }
        markStale(downstreamOf: id, including: nil)
    }

    /// URL slot: the user pasted or typed a link.
    func setLink(_ id: UUID, _ text: String) {
        guard let url = FCIngest.normalizedURL(text) else {
            flash("That doesn't look like a link")
            return
        }
        update(id) { $0.source = FCSource(url: url) }
        ingest(id, .url(url))
    }

    /// File slot: a file was dropped on the card or chosen.
    func fill(_ id: UUID, with file: URL) {
        guard let node = document.node(id) else { return }
        let kind = FCSourceKinds.kind(forFile: file)
        if node.kind != kind, kind != .link {
            update(id) { $0.kind = kind }
        }
        update(id) {
            $0.source = FCSource(url: file)
            $0.status = .loading("Copying")
        }
        ingest(id, kind == .image ? .image(file) : kind == .pdf ? .pdf(file) : .file(file))
    }

    func chooseFile(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let kind = document.node(id)?.kind
        if kind == .image { panel.allowedContentTypes = [.image] }
        if kind == .pdf { panel.allowedContentTypes = [.pdf] }
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.fill(id, with: url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls.map(FlowCanvasInput.forFile))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    func refetch(_ id: UUID) {
        guard let node = document.node(id), let source = node.source else { return }
        if node.kind == .link, let url = source.url {
            ingest(id, .url(url))
        } else if let url = assetURL(for: node), FileManager.default.fileExists(atPath: url.path) {
            ingestTasks[id] = Task { [weak self] in await self?.extract(id, kind: node.kind, file: url) }
        } else if let original = source.url, original.isFileURL, FileManager.default.fileExists(atPath: original.path) {
            // The copy never finished (e.g. SparkV quit mid-copy): copy again.
            fill(id, with: original)
        } else {
            update(id) { $0.status = .failed("The file is gone. Drop it on the card again.") }
        }
    }

    func setNoteText(_ id: UUID, _ text: String) {
        update(id) { node in
            let oldDefault = Self.noteTitle(node.source?.text ?? "")
            node.source?.text = text
            if node.title == oldDefault || node.title == FCNodeKind.note.title { node.title = Self.noteTitle(text) }
        }
        markStale(downstreamOf: id, including: nil)
    }

    /// Downstream actions keep their output but show "Inputs changed".
    private func markStale(downstreamOf id: UUID, including extra: UUID?) {
        var targets = Set<UUID>()
        var stack = document.edges.filter { $0.from == id }.map(\.to)
        if let extra { stack.append(extra) }
        while let next = stack.popLast() {
            guard targets.insert(next).inserted else { continue }
            stack += document.edges.filter { $0.from == next }.map(\.to)
        }
        for target in targets {
            update(target) { node in
                guard node.kind.isAction, node.output != nil, node.status.phase == .ready else { return }
                node.status = FCNodeStatus(phase: .idle, message: "Inputs changed. Run again.")
            }
        }
    }

    /// Waits for every source card still loading.
    func waitForSources(_ ids: Set<UUID>? = nil) async {
        for (id, task) in ingestTasks where ids?.contains(id) ?? true {
            await task.value
        }
    }

    // MARK: - Running

    var isBusy: Bool { !runningIDs.isEmpty || isRunningAll }

    func run(_ id: UUID) {
        guard runningIDs.isEmpty || !runningIDs.contains(id) else { return }
        startRun { await $0.runChain(to: id) }
    }

    func runSelected() {
        let actions = selectedNodes.filter { $0.kind.isAction }
        guard !actions.isEmpty else {
            flash("Select an AI step to run, or use Run all")
            return
        }
        startRun { editor in
            for action in actions { await editor.runChain(to: action.id) }
        }
    }

    func runAll() {
        guard !isRunningAll else { return }
        startRun { await $0.runEverything() }
    }

    func stop() {
        cancelRuns()
    }

    private func startRun(_ body: @escaping @MainActor (FCEditor) async -> Void) {
        let token = UUID()
        runTasks[token] = Task { [weak self] in
            if let self { await body(self) }
            self?.runTasks.removeValue(forKey: token)
        }
    }

    private func cancelRuns() {
        for task in runTasks.values { task.cancel() }
        runTasks = [:]
    }

    /// Runs `id`, after any upstream step that has no output yet (or whose
    /// inputs changed).
    func runChain(to id: UUID) async {
        let scope = FCGraph.upstream(of: id, edges: document.edges).union([id])
        let order: [UUID]
        do {
            order = try FCGraph.topologicalOrder(document, restrictTo: scope)
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
            flash(error.localizedDescription)
            return
        }
        await waitForSources(scope)
        for nodeID in order {
            if Task.isCancelled { return }
            guard let node = document.node(nodeID), node.kind.isAction else { continue }
            let stale = node.output == nil || node.status.phase != .ready
            if nodeID == id || stale {
                if nodeID == id, node.kind == .chat, !node.chat.isEmpty { continue }
                await execute(nodeID)
            }
        }
    }

    /// Run all: every action in dependency order. A loop stops it before
    /// anything runs.
    func runEverything() async {
        let order: [UUID]
        do {
            order = try FCGraph.topologicalOrder(document)
        } catch {
            flash(error.localizedDescription)
            lastRunError = error.localizedDescription
            return
        }
        lastRunError = nil
        isRunningAll = true
        defer { isRunningAll = false }
        let actions = order.filter { document.node($0)?.kind.isAction == true }
        guard !actions.isEmpty else {
            flash("Add an AI step (Summarize, Extract, Compare, Report…) to run")
            return
        }
        await waitForSources()
        lastRunOrder = actions
        for id in actions {
            if Task.isCancelled { return }
            await execute(id)
        }
        let failed = actions.filter { document.node($0)?.status.phase == .failed }.count
        flash(failed == 0 ? "Ran \(actions.count) step\(actions.count == 1 ? "" : "s")" : "\(failed) of \(actions.count) steps failed")
    }

    /// For tests and the inspector: the last Run all's order, or its error.
    private(set) var lastRunOrder: [UUID] = []
    private(set) var lastRunError: String?

    /// Runs one action now with whatever its inputs hold.
    func execute(_ id: UUID) async {
        guard let node = document.node(id), node.kind.isAction else { return }
        let inputNodes = FCGraph.inputs(of: id, in: document)
        if let blocked = inputNodes.first(where: { $0.status.phase == .failed && ($0.kind.isSource || $0.output == nil) }),
           inputNodes.allSatisfy({ $0.status.phase == .failed || $0.outputText.isEmpty }) {
            update(id) { $0.status = .failed("Input \"\(blocked.title)\" failed: \(blocked.status.message ?? "no text")") }
            return
        }
        let inputs = FCRunner.inputs(for: id, in: document, assetURL: assetURL(for:))
        runningIDs.insert(id)
        defer { runningIDs.remove(id) }
        update(id) { $0.status = .loading("Running") }
        let started = Date()
        let progress: FCProgress = { [weak self] message in
            Task { @MainActor in
                self?.update(id) { node in
                    if node.status.phase == .loading { node.status = .loading(message) }
                }
            }
        }
        do {
            let result = try await runner.run(node, inputs: inputs, progress: progress)
            update(id) { node in
                node.output = result.output
                node.run = FCRunInfo(startedAt: started, duration: Date().timeIntervalSince(started), model: result.model)
                node.status = .ready
            }
        } catch is CancellationError {
            update(id) { $0.status = FCNodeStatus(phase: .idle, message: "Stopped") }
        } catch {
            let reason = error.localizedDescription
            update(id) { node in
                node.status = .failed(reason)
                node.run = FCRunInfo(startedAt: started, duration: Date().timeIntervalSince(started), model: self.ai.backend().label, error: reason)
            }
        }
    }

    // MARK: - Chat

    func sendChat(_ id: UUID) {
        let text = (chatDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !runningIDs.contains(id) else { return }
        chatDrafts[id] = ""
        startRun { await $0.ask(id, text) }
    }

    func ask(_ id: UUID, _ question: String) async {
        // Upstream steps without output run first.
        let upstream = FCGraph.upstream(of: id, edges: document.edges)
        if let order = try? FCGraph.topologicalOrder(document, restrictTo: upstream) {
            await waitForSources(upstream)
            for nodeID in order where document.node(nodeID)?.kind.isAction == true && document.node(nodeID)?.output == nil {
                await execute(nodeID)
            }
        }
        guard let node = document.node(id) else { return }
        let inputs = FCRunner.inputs(for: id, in: document, assetURL: assetURL(for:))
        update(id) { $0.chat.append(FCChatMessage(role: .user, text: question)) }
        runningIDs.insert(id)
        defer { runningIDs.remove(id) }
        update(id) { $0.status = .loading("Thinking") }
        let started = Date()
        do {
            let answer = try await runner.chat(node, question: question, inputs: inputs)
            update(id) { node in
                node.chat.append(answer)
                node.output = FCOutput(format: .markdown, text: answer.text, citations: answer.citations)
                node.run = FCRunInfo(startedAt: started, duration: Date().timeIntervalSince(started), model: answer.model ?? "")
                node.status = .ready
            }
        } catch is CancellationError {
            update(id) { $0.status = FCNodeStatus(phase: .idle, message: "Stopped") }
        } catch {
            let reason = error.localizedDescription
            update(id) { node in
                node.chat.append(FCChatMessage(role: .assistant, text: "Couldn't answer: \(reason)"))
                node.status = .failed(reason)
            }
        }
    }

    func clearChat(_ id: UUID) {
        update(id) { node in
            node.chat = []
            node.output = nil
            node.status = .idle
        }
    }

    // MARK: - AI plan

    var planSources: [FCNode] {
        let selected = selectedNodes.filter { $0.kind.isSource }
        return selected.isEmpty ? document.nodes.filter { $0.kind.isSource }.sorted { ($0.y, $0.x) < ($1.y, $1.x) } : selected.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    func proposePlan() {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isPlanning else { return }
        isPlanning = true
        ghost = nil
        let sources = planSources
        let documentID = document.id
        planningDocumentID = documentID
        Task { [weak self] in
            guard let self else { return }
            let plan = await FCPlanner.plan(goal: goal, sources: sources, ai: self.ai)
            self.isPlanning = false
            // The user opened another canvas meanwhile: the plan was for the old one.
            guard self.document.id == documentID, self.planningDocumentID == documentID else { return }
            self.planningDocumentID = nil
            self.showPlan(plan, sources: sources)
        }
    }

    func showPlan(_ plan: FCPlan, sources: [FCNode]) {
        let (nodes, edges) = FCPlanner.materialize(plan, sources: sources, near: insertionPoint)
        ghost = FCGhostPlan(plan: plan, nodes: nodes, edges: edges)
        if sources.isEmpty { flash("Add some cards, then connect them to these steps") }
        // Bring the suggestion into view if it landed off screen.
        let rects = (sources + nodes).map(rect(of:))
        if let first = rects.first {
            let world = rects.dropFirst().reduce(first) { $0.union($1) }
            let visible = CGRect.fc(from: toWorld(.zero), to: toWorld(CGPoint(x: canvasSize.width, y: canvasSize.height)))
            if !visible.contains(world) { fit(world, maxZoom: zoom) }
        }
    }

    func acceptPlan() {
        guard let ghost else { return }
        // A source deleted while the suggestion was showing leaves no dangling edge.
        let known = Set(document.nodes.map(\.id)).union(ghost.nodes.map(\.id))
        let edges = ghost.edges.filter { known.contains($0.from) && known.contains($0.to) }
        perform("Add suggested steps") { document in
            document.nodes += ghost.nodes
            document.edges += edges
        }
        selection = Set(ghost.nodes.map(\.id))
        self.ghost = nil
        goal = ""
        flash("Added \(ghost.nodes.count) step\(ghost.nodes.count == 1 ? "" : "s"). Press Run all when your cards are ready.")
    }

    func discardPlan() {
        ghost = nil
    }

    // MARK: - Outputs

    func pinOutput(_ id: UUID) {
        guard let node = document.node(id), let output = node.output else { return }
        var source = FCSource()
        source.text = output.markdown
        var note = FCNode(kind: .note, title: "Pinned: \(node.title)", at: CGPoint(x: node.x, y: node.y + Double(size(of: node).height) + 40), source: source)
        note.status = .ready
        perform("Pin output") { $0.nodes.append(note) }
        selection = [note.id]
    }

    var exportsDirectory: URL {
        library.exportsDirectory.appendingPathComponent(document.id.uuidString, isDirectory: true)
    }

    /// A fresh file for drag-out / the Tray.
    func exportFile(_ id: UUID, format: FCExportFormat) -> URL? {
        guard let node = document.node(id) else { return nil }
        do {
            return try FCExport.write(node, format: format, to: exportsDirectory)
        } catch {
            flash("Couldn't write the file: \(error.localizedDescription)")
            return nil
        }
    }

    func copyOutput(_ id: UUID) {
        guard let node = document.node(id) else { return }
        let text = node.kind.isSource ? (node.source?.text ?? "") : (node.output?.markdown ?? "")
        guard !text.isEmpty else { flash("Nothing to copy yet"); return }
        FCExport.copy(text)
        flash("Copied")
    }

    func addToNotes(_ id: UUID) {
        guard let node = document.node(id) else { return }
        let text = FCExport.markdown(for: node)
        guard !text.isEmpty else { flash("Nothing to add yet"); return }
        if !FCExport.addToNotes(text) {
            FCExport.copy(text)
            flash("Notes sharing isn't available here; copied instead")
        }
    }

    func sendToTray(_ id: UUID) {
        guard let onSendToTray else {
            flash("The Tray isn't connected in this build")
            return
        }
        guard let url = exportFile(id, format: .markdown) else { return }
        onSendToTray([url])
        flash("Sent to the Tray")
    }

    func sendToSpace(_ id: UUID) {
        guard let node = document.node(id), let onSendToSpace else { return }
        onSendToSpace(node.title, FCExport.markdown(for: node), node.source?.url)
        flash("Added to Spaces")
    }

    func save(_ id: UUID, as format: FCExportFormat) {
        guard let node = document.node(id) else { return }
        Task { [weak self] in
            guard let result = await FCExport.save(node, format: format, in: self?.window) else { return }
            switch result {
            case .success(let url): self?.flash("Exported \(url.lastPathComponent)")
            case .failure(let error): self?.flash("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func open(_ id: UUID) {
        guard let node = document.node(id) else { return }
        if let asset = assetURL(for: node), FileManager.default.fileExists(atPath: asset.path) {
            NSWorkspace.shared.open(asset)
        } else if let url = node.source?.url, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            flash("Nothing to open")
        }
    }

    // MARK: - Canvases

    func openCanvas(_ id: UUID) {
        guard id != document.id else { return }
        do {
            let loaded = try library.load(id)
            switchTo(loaded)
        } catch {
            flash(error.localizedDescription)
        }
    }

    func newCanvas(from template: FCTemplate? = nil) {
        let fresh: FCDocument
        if let template {
            var instance = FCTemplates.instantiate(template, name: library.uniqueName(template.name))
            instance.name = library.uniqueName(template.name)
            fresh = (try? library.save(instance)) ?? instance
        } else {
            fresh = library.create()
        }
        switchTo(fresh)
        if template != nil {
            DispatchQueue.main.async { [weak self] in self?.fitAll() }
        }
    }

    /// `saveCurrent: false` when the current canvas was just deleted.
    private func switchTo(_ next: FCDocument, saveCurrent: Bool = true) {
        if saveCurrent {
            saveNow()
        } else {
            saveTask?.cancel()
            saveTask = nil
        }
        for task in ingestTasks.values { task.cancel() }
        ingestTasks = [:]
        cancelRuns()
        document = next
        selection = []
        selectedEdge = nil
        ghost = nil
        planningDocumentID = nil
        pendingEdge = nil
        marquee = nil
        editingNoteID = nil
        removedNodes = [:]
        moveOrigins = [:]
        interactionBefore = nil
        resizeOrigin = nil
        fullscreenNodeID = nil
        undoStack = []
        redoStack = []
        canUndo = false
        canRedo = false
        measuredSizes = [:]
        applyViewport()
        // Links from a template slot that already have a URL get fetched.
        for node in document.nodes where node.kind == .link && node.status.phase == .idle {
            if let url = node.source?.url { ingest(node.id, .url(url)) }
        }
    }

    func renameCanvas(_ id: UUID, to name: String) {
        renamingCanvasID = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if id == document.id {
            document.name = trimmed
            saveNow()
        } else {
            try? library.rename(id, to: trimmed)
        }
    }

    func duplicateCanvas(_ id: UUID) {
        if id == document.id { saveNow() }
        do {
            let copy = try library.duplicate(id)
            switchTo(copy)
            flash("Duplicated as \(copy.name)")
        } catch {
            flash("Couldn't duplicate: \(error.localizedDescription)")
        }
    }

    /// Asks first; removes only the canvas file and its copied assets.
    func confirmDeleteCanvas(_ id: UUID) {
        let name = library.canvases.first { $0.id == id }?.name ?? document.name
        let alert = NSAlert()
        alert.messageText = "Delete \"\(name)\"?"
        alert.informativeText = "The canvas and SparkV's copies of its files move to the Trash. Your original files aren't touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteCanvas(id)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
    }

    func deleteCanvas(_ id: UUID) {
        let isCurrent = id == document.id
        if isCurrent {
            // Stop everything that could write the deleted canvas back to disk.
            saveTask?.cancel()
            saveTask = nil
            for task in ingestTasks.values { task.cancel() }
            ingestTasks = [:]
            cancelRuns()
        }
        do {
            try library.delete(id)
        } catch {
            flash("Couldn't delete: \(error.localizedDescription)")
            return
        }
        if isCurrent {
            let next = library.canvases.first.flatMap { try? library.load($0.id) } ?? library.create()
            switchTo(next, saveCurrent: false)
        }
    }

    func saveAsTemplate(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try library.saveTemplate(FCTemplates.capture(document, name: trimmed))
            flash("Saved template \"\(trimmed)\"")
        } catch {
            flash("Couldn't save the template: \(error.localizedDescription)")
        }
    }

    /// Asks for a template name, then saves.
    func promptSaveAsTemplate() {
        let alert = NSAlert()
        alert.messageText = "Save as template"
        alert.informativeText = "Cards, settings and connections are saved. Copied files become empty slots; outputs aren't kept."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = document.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.saveAsTemplate(named: field.stringValue)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
    }

    // MARK: - Autosave

    func scheduleSave() {
        saveTask?.cancel()
        let delay = autosaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        var copy = document
        copy.viewport = FCViewport(x: Double(offset.width), y: Double(offset.height), zoom: Double(zoom))
        do {
            let saved = try library.save(copy)
            document.updatedAt = saved.updatedAt
            document.viewport = saved.viewport
        } catch {
            AppLog.log("Flow Canvas: autosave failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Flash

    func flash(_ message: String) {
        flashMessage = message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.flashMessage = nil
        }
    }

    // MARK: - Bindings for views

    func titleBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { [weak self] in self?.document.node(id)?.title ?? "" },
                set: { [weak self] value in self?.update(id) { $0.title = value } })
    }

    func noteBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { [weak self] in self?.document.node(id)?.source?.text ?? "" },
                set: { [weak self] value in self?.setNoteText(id, value) })
    }

    func promptBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { [weak self] in self?.document.node(id)?.config.prompt ?? "" },
                set: { [weak self] value in self?.updateConfig(id) { $0.prompt = value } })
    }

    func languageBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { [weak self] in self?.document.node(id)?.config.language ?? "English" },
                set: { [weak self] value in self?.updateConfig(id) { $0.language = value } })
    }

    func fieldsBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { [weak self] in self?.document.node(id)?.config.fields.joined(separator: ", ") ?? "" },
                set: { [weak self] value in
                    self?.updateConfig(id) { $0.fields = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                })
    }

    func chatDraftBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { [weak self] in self?.chatDrafts[id] ?? "" },
                set: { [weak self] value in self?.chatDrafts[id] = value })
    }

    func linkDraftBinding(_ id: UUID) -> Binding<String> {
        chatDraftBinding(id)
    }

    private func updateConfig(_ id: UUID, _ change: (inout FCActionConfig) -> Void) {
        update(id) { node in
            change(&node.config)
            if node.output != nil, node.status.phase == .ready {
                node.status = FCNodeStatus(phase: .idle, message: "Settings changed. Run again.")
            }
        }
    }
}

// MARK: - Small helpers

extension Comparable {
    func fcClamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}

extension CGRect {
    static func fc(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
