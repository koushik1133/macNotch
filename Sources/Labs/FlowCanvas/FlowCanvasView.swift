import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The infinite canvas: dotted grid, connections, cards, ghost cards of a
// suggested plan, the marquee, the selection pill and the empty state.
// World → screen is `world * zoom + offset`; cards are laid out in world
// coordinates inside one container that is scaled and offset as a whole.
// Scroll-wheel pan, pinch zoom and keys come from the window's event monitor
// (FlowCanvasWindowController); drags and clicks are SwiftUI gestures.

struct FCCanvasView: View {
    static let space = "FlowCanvas.canvas"

    @ObservedObject var editor: FCEditor
    @ObservedObject private var thumbnails = FCThumbnails.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = FCPalette(scheme: scheme)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                FCGridBackground(zoom: editor.zoom, offset: editor.offset, palette: palette)
                backgroundGestures
                FCEdgesLayer(editor: editor, palette: palette)
                cards(palette)
                if let ghost = editor.ghost { ghostCards(ghost, palette: palette) }
                if let marquee = editor.marquee {
                    Rectangle()
                        .fill(palette.accent.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(palette.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: editor.tool == .frame ? [6, 4] : [])))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false)
                }
                if editor.fullscreenNodeID == nil, editor.ghost == nil, let rect = editor.selectionScreenRect, editor.marquee == nil, !editor.isMoving {
                    FCSelectionPill(editor: editor, palette: palette)
                        .fixedSize()
                        .position(x: rect.midX.fcClamped(160, max(160, geometry.size.width - 160)),
                                  y: max(84, rect.minY - 26))
                }
                if editor.document.nodes.isEmpty && editor.ghost == nil {
                    FCEmptyState(editor: editor, palette: palette)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
            .clipped()
            .contentShape(Rectangle())
            .onDrop(of: FCDrop.types, isTargeted: nil) { providers, location in
                drop(providers, at: location)
                return true
            }
            .onPreferenceChange(FCNodeSizesKey.self) { sizes in
                MainActor.assumeIsolated { editor.setMeasured(sizes) }
            }
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { update(proxy) }
                    .onChange(of: proxy.size) { _, _ in update(proxy) }
                    .onChange(of: proxy.frame(in: .global)) { _, _ in update(proxy) }
            })
        }
        .background(palette.canvas)
    }

    private func update(_ proxy: GeometryProxy) {
        editor.canvasSize = proxy.size
        editor.canvasFrameInWindow = proxy.frame(in: .global)
    }

    // MARK: Background

    private var backgroundGestures: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        editor.backgroundDragChanged(start: value.startLocation, location: value.location, translation: value.translation)
                    }
                    .onEnded { _ in editor.backgroundDragEnded() }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .named(Self.space)).onEnded { value in
                    editor.backgroundDoubleTapped(at: value.location)
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1, coordinateSpace: .named(Self.space)).onEnded { value in
                    editor.backgroundTapped(at: value.location)
                }
            )
    }

    // MARK: Cards

    private func cards(_ palette: FCPalette) -> some View {
        let frames = editor.document.nodes.filter { $0.kind == .frame }
        let cards = editor.document.nodes.filter { $0.kind != .frame }
        return ZStack(alignment: .topLeading) {
            ForEach(frames) { node in
                FCFrameView(node: node, editor: editor, palette: palette, isSelected: editor.selection.contains(node.id))
                    .fixedSize()
                    .modifier(FCCardInteraction(node: node, editor: editor))
                    .offset(x: node.x, y: node.y)
            }
            ForEach(cards) { node in
                FCNodeView(node: node, editor: editor, palette: palette,
                           isSelected: editor.selection.contains(node.id),
                           isConnectTarget: editor.pendingEdge?.target == node.id)
                    .fixedSize()
                    .modifier(FCCardInteraction(node: node, editor: editor))
                    .offset(x: node.x, y: node.y)
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
        .scaleEffect(editor.zoom, anchor: .topLeading)
        .offset(x: editor.offset.width, y: editor.offset.height)
    }

    private func ghostCards(_ ghost: FCGhostPlan, palette: FCPalette) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ghost.nodes) { node in
                FCNodeView(node: node, editor: editor, palette: palette, isGhost: true)
                    .fixedSize()
                    .offset(x: node.x, y: node.y)
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
        .scaleEffect(editor.zoom, anchor: .topLeading)
        .offset(x: editor.offset.width, y: editor.offset.height)
        .allowsHitTesting(false)
    }

    // MARK: Drop

    private func drop(_ providers: [NSItemProvider], at location: CGPoint) {
        let world = editor.toWorld(location)
        FCDrop.inputs(from: providers) { index, input, data in
            let point = CGPoint(x: world.x + CGFloat(index) * 24, y: world.y + CGFloat(index) * 190)
            // Dropped on a slot card: fill it instead of adding a new card.
            if let input, case .url(let url) = input, let slot = editor.node(at: point), slot.kind == .link, slot.source?.url == nil {
                editor.setLink(slot.id, url.absoluteString)
                return
            }
            if let input {
                editor.add([input], at: point)
            } else if let data {
                editor.addImageData(data, at: point)
            }
        }
    }
}

/// Click to select, double-click to edit/expand, drag to move (or to
/// connect with the Connect tool).
struct FCCardInteraction: ViewModifier {
    let node: FCNode
    let editor: FCEditor

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if node.kind == .note {
                    editor.select(node.id, extend: false)
                    editor.editingNoteID = node.id
                } else if node.kind != .frame {
                    editor.select(node.id, extend: false)
                    editor.toggleFullscreen()
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                let extend = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                if editor.editingNoteID != node.id { editor.editingNoteID = nil }
                editor.select(node.id, extend: extend)
            })
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(FCCanvasView.space))
                    .onChanged { value in
                        guard editor.editingNoteID != node.id else { return }
                        if editor.tool == .connect && node.kind.hasOutputPort {
                            if editor.pendingEdge == nil { editor.beginConnection(from: node.id, at: value.startLocation) }
                            editor.updateConnection(to: value.location)
                            return
                        }
                        if !editor.isMoving {
                            editor.beginMove(node.id, extend: NSEvent.modifierFlags.contains(.shift))
                        }
                        editor.move(by: value.translation)
                    }
                    .onEnded { _ in
                        if editor.pendingEdge != nil { editor.endConnection() } else if editor.isMoving { editor.endMove() }
                    }
            )
    }
}

// MARK: - Selection pill

struct FCSelectionPill: View {
    @ObservedObject var editor: FCEditor
    let palette: FCPalette

    var body: some View {
        HStack(spacing: 2) {
            if editor.selectedNodes.contains(where: { $0.kind.isAction }) {
                pillButton("Run", key: "↩", symbol: "play.fill") { editor.runSelected() }
                divider
            }
            pillButton("Fullscreen", key: "F", symbol: "arrow.up.left.and.arrow.down.right") { editor.toggleFullscreen() }
            pillButton("Zoom", key: "Z", symbol: "plus.magnifyingglass") { editor.zoomToSelection() }
            divider
            pillButton("Delete", key: "D", symbol: "trash", destructive: true) { editor.deleteSelection() }
        }
        .padding(4)
        .background(Capsule().fill(palette.chrome))
        .overlay(Capsule().strokeBorder(palette.border))
        .shadow(color: palette.shadow, radius: 10, y: 3)
    }

    private var divider: some View {
        Rectangle().fill(palette.border).frame(width: 1, height: 16).padding(.horizontal, 2)
    }

    private func pillButton(_ title: String, key: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
                Text(key)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(palette.cardRaised))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.border))
                    .foregroundStyle(palette.secondary)
            }
            .foregroundStyle(destructive ? palette.status(.failed) : palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

struct FCEmptyState: View {
    @ObservedObject var editor: FCEditor
    let palette: FCPalette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.edge)
            Text("Turn anything into a workflow")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.text)
            Text("Drop screenshots, links, PDFs or text here, then tell SparkV what to do with them.")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                FCCardButton(title: "Paste", symbol: "doc.on.clipboard", palette: palette) { editor.paste() }
                FCCardButton(title: "Add files…", symbol: "folder", palette: palette) { editor.chooseFilesToAdd() }
                FCCardButton(title: "Text note", symbol: "note.text", palette: palette) { editor.addNote(edit: true) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or start from a template").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                ForEach(FCTemplates.builtIn) { template in
                    Button {
                        editor.newCanvas(from: template)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: template.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(template.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(palette.text)
                                Text(template.summary).font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 420)
            .padding(.top, 6)
        }
        .padding(28)
    }
}
