import AppKit
import SwiftUI

// Right-side inspector and the Fullscreen (F) overlay. Both show one card's
// settings, inputs, last output (text / table / Markdown), run time, model
// and error, plus Copy, Pin as note, drag-out files and exports.

struct FCInspector: View {
    @ObservedObject var editor: FCEditor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = FCPalette(scheme: scheme)
        VStack(spacing: 0) {
            HStack {
                Text("Inspector").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondary)
                Spacer()
                Button {
                    editor.inspectorVisible = false
                } label: {
                    Image(systemName: "sidebar.right").foregroundStyle(palette.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide inspector")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            Divider()
            if let node = editor.primarySelection {
                ScrollView {
                    FCNodeDetail(node: node, editor: editor, palette: palette, wide: false)
                        .padding(14)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "sidebar.squares.right").font(.system(size: 22)).foregroundStyle(palette.tertiary)
                    Text(editor.selection.count > 1 ? "\(editor.selection.count) cards selected" : "Select a card to see its result")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                    if let edge = editor.selectedEdge, let item = editor.document.edges.first(where: { $0.id == edge }),
                       let from = editor.document.node(item.from), let to = editor.document.node(item.to) {
                        Text("Connection: \(from.title) → \(to.title)").font(.system(size: 11)).foregroundStyle(palette.secondary)
                        FCCardButton(title: "Delete connection", symbol: "trash", palette: palette) { editor.deleteSelection() }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        }
        .frame(width: 340)
        .background(palette.card)
    }
}

/// Fullscreen view of one card over the canvas.
struct FCFullscreenView: View {
    @ObservedObject var editor: FCEditor
    let nodeID: UUID
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = FCPalette(scheme: scheme)
        ZStack {
            Color.black.opacity(scheme == .dark ? 0.55 : 0.28)
                .contentShape(Rectangle())
                .onTapGesture { editor.fullscreenNodeID = nil }
            if let node = editor.document.node(nodeID) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: node.kind.symbol).foregroundStyle(palette.tint(for: node.kind))
                        Text(node.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.text).lineLimit(1)
                        FCStatusChip(status: node.status, palette: palette)
                        Spacer()
                        Text("Esc or F to close").font(.system(size: 10.5)).foregroundStyle(palette.tertiary)
                        Button {
                            editor.fullscreenNodeID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(palette.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 50)
                    Divider()
                    ScrollView {
                        FCNodeDetail(node: node, editor: editor, palette: palette, wide: true)
                            .padding(22)
                    }
                }
                .frame(maxWidth: 940, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.card))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                .padding(.horizontal, 40)
                .padding(.vertical, 30)
            }
        }
    }
}

/// The body of the inspector and the fullscreen view.
struct FCNodeDetail: View {
    let node: FCNode
    @ObservedObject var editor: FCEditor
    let palette: FCPalette
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !wide {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: node.kind.symbol).foregroundStyle(palette.tint(for: node.kind))
                        TextField("Title", text: editor.titleBinding(node.id))
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.text)
                    }
                    HStack(spacing: 6) {
                        Text(node.kind.title).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        FCStatusChip(status: node.status, palette: palette)
                    }
                }
            }
            if node.kind.isSource { sourceSection } else if node.kind.isAction { actionSection }
            if node.kind == .frame {
                Text("Frames group cards. Moving a frame moves the cards inside it.").font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Source

    @ViewBuilder
    private var sourceSection: some View {
        let source = node.source ?? FCSource()
        if let url = source.url, !url.isFileURL {
            section("Link") {
                Link(url.absoluteString, destination: url).font(.system(size: 11.5)).lineLimit(2)
            }
        }
        if let detail = source.detail { info("Details", detail) }
        if let caveat = source.caveat { info("Note", caveat) }
        if let description = source.imageDescription { info("Image", description) }
        if node.status.phase == .failed, let reason = node.status.message {
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(palette.status(.failed))
        }
        if node.kind == .image, let url = editor.assetURL(for: node), let image = FCThumbnails.shared.image(for: url, isPDF: false) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxHeight: wide ? 420 : 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        if node.kind == .note {
            section("Text") {
                TextEditor(text: editor.noteBinding(node.id))
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: wide ? 360 : 200)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.cardRaised))
            }
        } else {
            section(node.kind == .link ? "Readable text" : "Extracted text") {
                Text(source.text.isEmpty ? "No text yet." : String(source.text.prefix(wide ? 40_000 : 8_000)))
                    .font(.system(size: 12))
                    .foregroundStyle(source.text.isEmpty ? palette.tertiary : palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if source.text.count > (wide ? 40_000 : 8_000) {
                    Text("Showing the start of \(source.text.count) characters. Copy text for all of it.")
                        .font(.system(size: 10.5)).foregroundStyle(palette.tertiary)
                }
            }
        }
        HStack(spacing: 6) {
            FCCardButton(title: "Copy text", symbol: "doc.on.doc", palette: palette) { editor.copyOutput(node.id) }
            if node.kind != .note {
                FCCardButton(title: "Open", symbol: "arrow.up.right.square", palette: palette) { editor.open(node.id) }
                FCCardButton(title: "Read again", symbol: "arrow.clockwise", palette: palette) { editor.refetch(node.id) }
            }
        }
        exportRow
    }

    // MARK: Action

    @ViewBuilder
    private var actionSection: some View {
        settings
        inputsList
        runInfo
        if node.kind == .chat {
            section("Conversation") {
                if node.chat.isEmpty {
                    Text("No messages yet. Ask from the card on the canvas or below.").font(.system(size: 12)).foregroundStyle(palette.tertiary)
                }
                ForEach(node.chat) { message in
                    FCChatBubble(message: message, editor: editor, palette: palette)
                }
                HStack(spacing: 6) {
                    TextField("Ask about the connected cards…", text: editor.chatDraftBinding(node.id))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { editor.sendChat(node.id) }
                    FCCardButton(title: "Send", symbol: "arrow.up", palette: palette, prominent: true) { editor.sendChat(node.id) }
                }
                if !node.chat.isEmpty {
                    FCCardButton(title: "Clear conversation", symbol: "trash", palette: palette) { editor.clearChat(node.id) }
                }
            }
        } else if let output = node.output {
            section("Output") {
                if let table = output.table, !table.columns.isEmpty {
                    ScrollView(.horizontal) {
                        FCTableView(table: table, palette: palette)
                            .frame(minWidth: wide ? 860 : max(300, CGFloat(table.columns.count) * 120))
                    }
                }
                if !output.text.isEmpty {
                    FCMarkdownText(text: output.text, palette: palette)
                        .textSelection(.enabled)
                }
            }
        }
        if node.output != nil { exportRow }
    }

    @ViewBuilder
    private var settings: some View {
        switch node.kind {
        case .extract:
            section("Fields to extract") {
                TextField("price, plans, features", text: editor.fieldsBinding(node.id))
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated. One row per connected card.").font(.system(size: 10.5)).foregroundStyle(palette.tertiary)
            }
        case .translate:
            section("Translate to") {
                Picker("", selection: editor.languageBinding(node.id)) {
                    ForEach(TrayAISettings.languages, id: \.self) { Text($0).tag($0) }
                    if !TrayAISettings.languages.contains(node.config.language) { Text(node.config.language).tag(node.config.language) }
                }
                .labelsHidden()
            }
        case .custom, .summarize, .report, .compare:
            section(node.kind == .custom ? "Instruction" : node.kind == .report ? "Audience / goal (optional)" : "Focus (optional)") {
                TextEditor(text: editor.promptBinding(node.id))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.cardRaised))
            }
        default:
            EmptyView()
        }
        HStack(spacing: 6) {
            if editor.runningIDs.contains(node.id) {
                ProgressView().controlSize(.small)
                Text(node.status.message ?? "Running").font(.system(size: 11)).foregroundStyle(palette.secondary)
                FCCardButton(title: "Stop", symbol: "stop.fill", palette: palette) { editor.stop() }
            } else if node.kind != .chat {
                FCCardButton(title: node.output == nil ? "Run" : "Run again", symbol: "play.fill", palette: palette, prominent: true) { editor.run(node.id) }
            }
        }
    }

    private var inputsList: some View {
        let inputs = FCGraph.inputs(of: node.id, in: editor.document)
        return section("Inputs (\(inputs.count))") {
            if inputs.isEmpty {
                Text("Drag from a card's green dot to this step to connect it.").font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
            }
            ForEach(Array(inputs.enumerated()), id: \.element.id) { index, input in
                Button {
                    editor.select(input.id, extend: false)
                } label: {
                    HStack(spacing: 6) {
                        Text("S\(index + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(palette.edge)
                        Image(systemName: input.kind.symbol).font(.system(size: 10)).foregroundStyle(palette.tint(for: input.kind))
                        Text(input.citationLabel).font(.system(size: 11.5)).foregroundStyle(palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        FCStatusChip(status: input.status, palette: palette, compact: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var runInfo: some View {
        if let run = node.run {
            section("Last run") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("When").foregroundStyle(palette.secondary)
                        Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    GridRow {
                        Text("Time").foregroundStyle(palette.secondary)
                        Text(String(format: "%.2f s", run.duration))
                    }
                    GridRow {
                        Text("Model").foregroundStyle(palette.secondary)
                        Text(run.model.isEmpty ? "—" : run.model)
                    }
                    if let error = run.error {
                        GridRow {
                            Text("Error").foregroundStyle(palette.secondary)
                            Text(error).foregroundStyle(palette.status(.failed))
                        }
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(palette.text)
            }
        } else if node.status.phase == .failed, let reason = node.status.message {
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(palette.status(.failed))
        }
    }

    // MARK: Export

    private var exportRow: some View {
        let formats = node.kind.isSource ? [FCExportFormat.markdown, .text] : FCExport.formats(for: node.output).filter { $0 != .pdf }
        return section("Use the result") {
            HStack(spacing: 6) {
                FCCardButton(title: "Copy", symbol: "doc.on.doc", palette: palette) { editor.copyOutput(node.id) }
                if node.kind.isAction {
                    FCCardButton(title: "Pin as note", symbol: "pin", palette: palette) { editor.pinOutput(node.id) }
                }
                Menu {
                    Button("Markdown (.md)…") { editor.save(node.id, as: .markdown) }
                    Button("PDF…") { editor.save(node.id, as: .pdf) }
                    if node.output?.table != nil { Button("CSV…") { editor.save(node.id, as: .csv) } }
                    Button("Text (.txt)…") { editor.save(node.id, as: .text) }
                    Divider()
                    Button("Add to Notes") { editor.addToNotes(node.id) }
                    Button("Send to Tray") { editor.sendToTray(node.id) }
                    if editor.onSendToSpace != nil { Button("Add to Spaces") { editor.sendToSpace(node.id) } }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 10.5, weight: .semibold))
                }
                .menuStyle(.button)
                .fixedSize()
            }
            HStack(spacing: 6) {
                Text("Drag out:").font(.system(size: 10.5)).foregroundStyle(palette.tertiary)
                ForEach(formats) { format in
                    FCDragChip(format: format, palette: palette) { editor.exportFile(node.id, format: format) }
                }
            }
        }
    }

    // MARK: Layout helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabsEyebrow(title, color: palette.tertiary)
            content()
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        section(title) {
            Text(value).font(.system(size: 12)).foregroundStyle(palette.text).textSelection(.enabled)
        }
    }
}

/// ".md" chip that drags a freshly written file out (Finder, Mail, Slack…).
struct FCDragChip: View {
    let format: FCExportFormat
    let palette: FCPalette
    let makeFile: () -> URL?

    var body: some View {
        Text("." + format.rawValue)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(palette.cardRaised))
            .overlay(Capsule().strokeBorder(palette.border))
            .overlay(
                TrayDragSource(anchor: .pointer, toolTip: "Drag the \(format.title) file out", payloads: {
                    guard let url = makeFile() else { return [] }
                    return [TrayDragPayload(writer: url as NSURL, image: FCExport.dragImage(for: format))]
                })
            )
    }
}
