import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Cards on the canvas: source cards (note, link, image, PDF, file), AI step
// cards (with a compact output preview), the chat card, and frames. Plus the
// shared palette, status chip, Markdown and table renderers.

// MARK: - Palette (always the dark ground; system blue accent and per-kind
// tints in the Apple look, red accent and monochrome glyphs in SparkV Red)

struct FCPalette {
    /// Kept for the call sites; the canvas always uses the dark look.
    let scheme: ColorScheme
    var dark: Bool { true }
    private var apple: Bool { SparkVTheme.isApple }

    var canvas: Color { SparkVTheme.background }
    var dot: Color { Color.white.opacity(apple ? 0.09 : 0.10) }
    /// Apple: macOS dark elevated grays (#2C2C2E / #3A3A3C) on the #1C1C1E ground.
    var card: Color { apple ? Color(red: 0.173, green: 0.173, blue: 0.180) : Color(red: 0.086, green: 0.086, blue: 0.094) }
    var cardRaised: Color { apple ? Color(red: 0.227, green: 0.227, blue: 0.235) : Color(red: 0.125, green: 0.125, blue: 0.133) }
    var border: Color { SparkVTheme.stroke }
    var text: Color { SparkVTheme.text }
    var secondary: Color { SparkVTheme.textSecondary }
    var tertiary: Color { SparkVTheme.textTertiary }
    /// Primary / "go" accent: send and run buttons, ports, connect targets.
    var edge: Color { SparkVTheme.accent }
    /// Connection lines between cards (neutral; red only when selected or running).
    var wire: Color { Color.white.opacity(0.30) }
    var accent: Color { SparkVTheme.accent }
    var chrome: Color { apple ? Color(red: 0.141, green: 0.141, blue: 0.149) : Color(red: 0.102, green: 0.102, blue: 0.110) }
    var shadow: Color { Color.black.opacity(0.5) }
    var frameFill: Color { Color.white.opacity(0.025) }
    /// The user's chat bubble: Messages blue in Apple, a dark red in SparkV Red.
    var userBubble: Color { apple ? Color.accentColor : Color(red: 0.22, green: 0.06, blue: 0.07) }

    /// Card glyph color. Apple: one system tint per kind. SparkV Red:
    /// monochrome by brand (the glyph tells kinds apart).
    func tint(for kind: FCNodeKind) -> Color {
        guard apple else {
            switch kind {
            case .frame: return secondary
            default: return text.opacity(0.85)
            }
        }
        switch kind {
        case .note: return Color.yellow
        case .link: return Color.blue
        case .image: return Color.green
        case .pdf: return Color(red: 1.0, green: 0.45, blue: 0.40)
        case .file: return Color.gray
        case .chat: return Color.cyan
        case .summarize: return Color.purple
        case .extract: return Color.orange
        case .compare: return Color.teal
        case .report: return Color.indigo
        case .translate: return Color.green
        case .custom: return Color.pink
        case .frame: return secondary
        }
    }

    func status(_ phase: FCNodeStatus.Phase) -> Color {
        switch phase {
        case .ready: SparkVTheme.success
        case .loading: accent
        case .failed: SparkVTheme.destructive
        case .idle, .empty: secondary
        }
    }
}

// MARK: - Preference keys

struct FCNodeSizesKey: PreferenceKey {
    static let defaultValue: [UUID: CGSize] = [:]
    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Status chip

struct FCStatusChip: View {
    let status: FCNodeStatus
    let palette: FCPalette
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if status.phase == .loading {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            } else {
                Circle().fill(palette.status(status.phase)).frame(width: 6, height: 6)
            }
            if !compact {
                Text(status.phase == .idle && status.message != nil ? "Stale" : status.label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(palette.status(status.phase))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(palette.status(status.phase).opacity(0.12)))
        .help(status.message ?? status.label)
    }
}

// MARK: - Card

struct FCNodeView: View {
    let node: FCNode
    let editor: FCEditor
    let palette: FCPalette
    var isSelected = false
    var isGhost = false
    var isConnectTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(palette.border).frame(height: 1)
            content
                .padding(12)
        }
        .frame(width: node.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: isSelected || isConnectTarget ? 2 : 1, dash: isGhost ? [6, 4] : []))
        )
        .shadow(color: palette.shadow, radius: isSelected ? 14 : 8, y: isSelected ? 6 : 3)
        .overlay(alignment: .topLeading) { ports }
        .opacity(isGhost ? 0.55 : 1)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: FCNodeSizesKey.self, value: isGhost ? [:] : [node.id: geometry.size])
        })
    }

    private var borderColor: Color {
        if isConnectTarget { return palette.edge }
        if isSelected { return palette.accent }
        if node.status.phase == .failed { return palette.status(.failed).opacity(0.6) }
        return isGhost ? palette.accent.opacity(0.8) : palette.border
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.isApple || !isSelected ? palette.tint(for: node.kind) : palette.accent)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.isApple ? palette.tint(for: node.kind).opacity(0.18) : (isSelected ? SparkVTheme.accentSoft : SparkVTheme.surfaceHover)))
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            FCStatusChip(status: node.status, palette: palette)
        }
        .padding(.horizontal, 12)
        .frame(height: FCLayout.headerHeight)
    }

    private var subtitle: String {
        if node.kind.isSource {
            if let provider = node.source?.provider { return provider + (node.source?.detail.map { " · " + $0 } ?? "") }
            return node.source?.detail ?? node.kind.title
        }
        if let run = node.run, node.output != nil {
            return "\(node.kind.title) · \(String(format: "%.1f", run.duration)) s"
        }
        return node.kind.title
    }

    // MARK: Ports

    @ViewBuilder
    private var ports: some View {
        if !isGhost {
            ZStack(alignment: .topLeading) {
                if node.kind.hasInputPort {
                    portDot(filled: false)
                        .offset(x: -7, y: FCLayout.portY - 7)
                        .allowsHitTesting(false)
                }
                if node.kind.hasOutputPort {
                    portDot(filled: true)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                        .offset(x: node.width - 11, y: FCLayout.portY - 11)
                        .gesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .named(FCCanvasView.space))
                                .onChanged { value in
                                    if editor.pendingEdge == nil { editor.beginConnection(from: node.id, at: value.startLocation) }
                                    editor.updateConnection(to: value.location)
                                }
                                .onEnded { _ in editor.endConnection() }
                        )
                        .help("Drag to connect to an AI step")
                }
            }
        }
    }

    private func portDot(filled: Bool) -> some View {
        Circle()
            .fill(filled ? palette.edge : palette.card)
            .overlay(Circle().strokeBorder(palette.edge, lineWidth: 2))
            .frame(width: 14, height: 14)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .note: noteContent
        case .link: linkContent
        case .image: imageContent
        case .pdf, .file: documentContent
        case .chat: FCChatCard(node: node, editor: editor, palette: palette, isGhost: isGhost)
        case .frame: EmptyView()
        default: actionContent
        }
    }

    private var noteContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.editingNoteID == node.id && !isGhost {
                TextEditor(text: editor.noteBinding(node.id))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 140)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.cardRaised))
            } else if let text = node.source?.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.text)
                    .lineLimit(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Double-click to write")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiary)
            }
            sourceFooter
        }
    }

    @ViewBuilder
    private var linkContent: some View {
        if node.source?.url == nil {
            slotContent(prompt: node.status.message ?? "Paste a link")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let thumbnail = node.source?.thumbnailURL {
                    AsyncImage(url: thumbnail) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        palette.cardRaised
                    }
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.9)))
                }
                if let url = node.source?.url {
                    Text(url.absoluteString)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                preview(node.source?.text ?? "", lines: 4)
                caveat
                sourceFooter
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if node.source?.assetName == nil && node.status.phase != .loading {
            slotContent(prompt: node.status.message ?? "Drop a screenshot here")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let url = editor.assetURL(for: node), let image = FCThumbnails.shared.image(for: url, isPDF: false) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 130)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(palette.cardRaised).frame(height: 130)
                        .overlay(Image(systemName: "photo").foregroundStyle(palette.tertiary))
                }
                if let description = node.source?.imageDescription {
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                }
                preview(node.source?.text ?? "", lines: 3)
                caveat
                sourceFooter
            }
        }
    }

    @ViewBuilder
    private var documentContent: some View {
        if node.source?.assetName == nil && node.status.phase != .loading {
            slotContent(prompt: node.status.message ?? "Drop a file here")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    if node.kind == .pdf, let url = editor.assetURL(for: node), let image = FCThumbnails.shared.image(for: url, isPDF: true) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 54, height: 70)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.border))
                    } else {
                        Image(systemName: node.kind == .pdf ? "doc.richtext.fill" : "doc.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(palette.tint(for: node.kind))
                            .frame(width: 54, height: 70)
                            .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardRaised))
                    }
                    preview(node.source?.text ?? "", lines: 5)
                }
                caveat
                sourceFooter
            }
        }
    }

    private func preview(_ text: String, lines: Int) -> some View {
        Text(text.isEmpty ? (node.status.phase == .loading ? "Reading…" : "No text") : Self.plainPreview(text))
            .font(.system(size: 11))
            .foregroundStyle(text.isEmpty ? palette.tertiary : palette.secondary)
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// First lines without Markdown heading/bullet markers.
    static func plainPreview(_ text: String) -> String {
        String(text.prefix(700)).components(separatedBy: "\n").map { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @ViewBuilder
    private var caveat: some View {
        if let caveat = node.source?.caveat {
            Label(caveat, systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                .lineLimit(2)
        }
        if node.status.phase == .failed, let reason = node.status.message {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.status(.failed))
                .lineLimit(3)
        }
    }

    private var sourceFooter: some View {
        HStack(spacing: 6) {
            FCCardButton(title: "Copy text", symbol: "doc.on.doc", palette: palette) { editor.copyOutput(node.id) }
                .disabled((node.source?.text ?? "").isEmpty)
            if node.kind != .note {
                FCCardButton(title: "Open", symbol: "arrow.up.right.square", palette: palette) { editor.open(node.id) }
            }
            Spacer(minLength: 0)
            if node.status.phase == .failed {
                FCCardButton(title: "Retry", symbol: "arrow.clockwise", palette: palette) { editor.refetch(node.id) }
            }
        }
        .disabled(isGhost)
    }

    /// Empty slot: paste a link, or drop/choose a file.
    private func slotContent(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.kind == .link {
                HStack(spacing: 6) {
                    TextField("https://…", text: editor.linkDraftBinding(node.id))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                        .onSubmit { editor.setLink(node.id, editor.chatDrafts[node.id] ?? "") }
                    FCCardButton(title: "Add", symbol: "arrow.right", palette: palette, prominent: true) {
                        editor.setLink(node.id, editor.chatDrafts[node.id] ?? "")
                    }
                }
                Text(prompt).font(.system(size: 10.5)).foregroundStyle(palette.secondary)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: node.kind == .image ? "photo.badge.plus" : "doc.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.tertiary)
                    Text(prompt).font(.system(size: 11)).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
                    FCCardButton(title: "Choose…", symbol: "folder", palette: palette) { editor.chooseFile(for: node.id) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            }
            if node.status.phase == .failed, let reason = node.status.message {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.status(.failed))
                    .lineLimit(3)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FCDrop.fileURLs(from: providers) { url in editor.fill(node.id, with: url) }
            return true
        }
    }

    // MARK: Action content

    private var actionContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            configSummary
            if let output = node.output {
                FCOutputPreview(output: output, palette: palette)
            } else if node.status.phase != .loading {
                Text(isGhost ? node.kind.blurb : FCGraph.inputs(of: node.id, in: editor.document).isEmpty ? "Connect cards to this step" : "Run to see the result")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiary)
            }
            if node.status.phase == .failed, let reason = node.status.message {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.status(.failed))
                    .lineLimit(4)
            } else if node.status.phase == .idle, let message = node.status.message {
                Text(message).font(.system(size: 10.5)).foregroundStyle(palette.secondary)
            }
            HStack(spacing: 6) {
                if editor.runningIDs.contains(node.id) {
                    FCCardButton(title: "Stop", symbol: "stop.fill", palette: palette) { editor.stop() }
                } else {
                    FCCardButton(title: node.output == nil ? "Run" : "Run again", symbol: "play.fill", palette: palette, prominent: true) {
                        editor.run(node.id)
                    }
                }
                if node.output != nil {
                    FCCardButton(title: "Copy", symbol: "doc.on.doc", palette: palette) { editor.copyOutput(node.id) }
                }
                Spacer(minLength: 0)
                if let model = node.run?.model, node.output != nil {
                    Text(model)
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .disabled(isGhost)
        }
    }

    @ViewBuilder
    private var configSummary: some View {
        switch node.kind {
        case .extract:
            FCChips(items: node.config.fields.isEmpty ? ["no fields"] : node.config.fields, palette: palette)
        case .translate:
            Label("To \(node.config.language)", systemImage: "globe").font(.system(size: 11)).foregroundStyle(palette.secondary)
        case .custom, .summarize, .report, .compare:
            if !node.config.prompt.isEmpty {
                Text(node.config.prompt)
                    .font(.system(size: 11).italic())
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
            } else if node.kind == .custom {
                Text("Write the instruction in the inspector").font(.system(size: 11)).foregroundStyle(palette.status(.failed).opacity(0.8))
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Chat card

struct FCChatCard: View {
    let node: FCNode
    let editor: FCEditor
    let palette: FCPalette
    var isGhost = false

    var body: some View {
        let inputs = FCGraph.inputs(of: node.id, in: editor.document)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 10))
                Text(inputs.isEmpty ? "No cards connected" : "Reads \(inputs.count) card\(inputs.count == 1 ? "" : "s"): " + inputs.map(\.citationLabel).joined(separator: ", "))
                    .lineLimit(1)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(palette.secondary)

            if node.chat.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask anything about the connected cards.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                    ForEach(["What are the key differences?", "Which one is the cheapest?", "Summarize in 3 bullets"], id: \.self) { suggestion in
                        Button {
                            editor.chatDrafts[node.id] = suggestion
                            editor.sendChat(node.id)
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 11))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(palette.cardRaised))
                                .overlay(Capsule().strokeBorder(palette.border))
                        }
                        .buttonStyle(SparkVPressStyle())
                        .foregroundStyle(palette.text)
                        .disabled(inputs.isEmpty || isGhost)
                    }
                }
                .frame(minHeight: 120, alignment: .top)
            } else {
                let shown = node.chat.suffix(4)
                if node.chat.count > shown.count {
                    Text("\(node.chat.count - shown.count) earlier messages in the inspector")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.tertiary)
                }
                ForEach(Array(shown)) { message in
                    FCChatBubble(message: message, editor: editor, palette: palette, lineLimit: 10)
                }
            }
            if editor.runningIDs.contains(node.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(node.status.message ?? "Thinking").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            HStack(spacing: 6) {
                TextField("Ask about these cards…", text: editor.chatDraftBinding(node.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.cardRaised))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border))
                    .onSubmit { editor.sendChat(node.id) }
                Button {
                    editor.sendChat(node.id)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(palette.edge))
                }
                .buttonStyle(SparkVPressStyle())
                .disabled(editor.runningIDs.contains(node.id))
            }
            .disabled(isGhost)
        }
    }
}

struct FCChatBubble: View {
    let message: FCChatMessage
    let editor: FCEditor
    let palette: FCPalette
    var lineLimit: Int?

    var body: some View {
        let isUser = message.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Group {
                if isUser {
                    Text(message.text)
                } else {
                    FCMarkdownText(text: message.text, palette: palette, compact: true)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.text)
            .lineLimit(lineLimit)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isUser ? palette.userBubble : palette.cardRaised))
            if !message.citations.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "quote.opening").font(.system(size: 8))
                    ForEach(message.citations, id: \.self) { id in
                        if let node = editor.document.node(id) {
                            Button {
                                editor.select(id, extend: false)
                            } label: {
                                Text(node.citationLabel)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(palette.edge.opacity(0.14)))
                            }
                            .buttonStyle(SparkVPressStyle())
                            .help("Used \(node.citationLabel)")
                        }
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(palette.edge)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

// MARK: - Frame

struct FCFrameView: View {
    let node: FCNode
    let editor: FCEditor
    let palette: FCPalette
    var isSelected = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.frameFill)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? palette.accent : palette.border, style: StrokeStyle(lineWidth: isSelected ? 2 : 1.2, dash: [8, 6]))
            if isSelected {
                TextField("Frame", text: editor.titleBinding(node.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 220)
                    .padding(14)
            } else {
                Text(node.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .padding(14)
            }
        }
        .frame(width: node.width, height: node.height ?? 380)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(palette.card))
                    .overlay(Circle().strokeBorder(palette.accent))
                    .offset(x: 6, y: 6)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(FCCanvasView.space))
                            .onChanged { value in
                                if !editor.isResizing { editor.beginResize(node.id) }
                                editor.resize(node.id, by: value.translation)
                            }
                            .onEnded { _ in editor.endResize() }
                    )
            }
        }
    }
}

// MARK: - Small pieces

struct FCCardButton: View {
    let title: String
    let symbol: String
    let palette: FCPalette
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(prominent ? Color.white : palette.text)
                .background(Capsule().fill(prominent ? palette.edge : palette.cardRaised))
                .overlay(Capsule().strokeBorder(prominent ? Color.clear : palette.border))
        }
        .buttonStyle(SparkVPressStyle())
    }
}

struct FCChips: View {
    let items: [String]
    let palette: FCPalette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(palette.accent.opacity(0.12)))
                    .foregroundStyle(palette.accent)
            }
            if items.count > 4 {
                Text("+\(items.count - 4)").font(.system(size: 10.5)).foregroundStyle(palette.secondary)
            }
        }
    }
}

/// Compact output on a card: a few table rows and/or the first lines of text.
struct FCOutputPreview: View {
    let output: FCOutput
    let palette: FCPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let table = output.table, !table.columns.isEmpty {
                FCTableView(table: table, palette: palette, maxRows: 5, maxColumns: 4, compact: true)
            }
            if !output.text.isEmpty {
                FCMarkdownText(text: String(output.text.prefix(900)), palette: palette, compact: true)
                    .lineLimit(output.table == nil ? 10 : 4)
            }
        }
    }
}

// MARK: - Table

struct FCTableView: View {
    let table: FCTable
    let palette: FCPalette
    var maxRows: Int?
    var maxColumns: Int?
    var compact = false

    var body: some View {
        let columns = Array(table.columns.prefix(maxColumns ?? table.columns.count))
        let rows = Array(table.normalizedRows.prefix(maxRows ?? table.rows.count))
        let font = Font.system(size: compact ? 10 : 11.5)
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column)
                        .font(font.weight(.semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(compact ? 1 : 2)
                        .padding(.horizontal, compact ? 5 : 8)
                        .padding(.vertical, compact ? 4 : 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.cardRaised)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.prefix(columns.count).enumerated()), id: \.offset) { column, cell in
                        Text(cell)
                            .font(column == 0 ? font.weight(.medium) : font)
                            .foregroundStyle(cell == "—" ? palette.tertiary : palette.text)
                            .lineLimit(compact ? 2 : nil)
                            .textSelection(.enabled)
                            .padding(.horizontal, compact ? 5 : 8)
                            .padding(.vertical, compact ? 3 : 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index % 2 == 1 ? palette.cardRaised.opacity(0.5) : Color.clear)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        if let maxRows, table.rows.count > maxRows {
            Text("+\(table.rows.count - maxRows) more rows").font(.system(size: 10)).foregroundStyle(palette.tertiary)
        }
    }
}

// MARK: - Markdown

/// Block Markdown: headings, bullets, numbered lists, code blocks, tables
/// and inline styling/links (AttributedString).
struct FCMarkdownText: View {
    let text: String
    let palette: FCPalette
    var compact = false

    enum Block: Hashable {
        case heading(Int, String)
        case bullet(String, Int)
        case numbered(String, String)
        case paragraph(String)
        case code(String)
        case table(String)
    }

    var body: some View {
        let blocks = Self.blocks(text)
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        let base: CGFloat = compact ? 11.5 : 13
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(.system(size: base + CGFloat(max(0, 4 - level)) * (compact ? 1 : 2.5), weight: .bold))
                .foregroundStyle(palette.text)
                .padding(.top, compact ? 2 : 6)
        case .bullet(let content, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(palette.secondary)
                inline(content).foregroundStyle(palette.text)
            }
            .font(.system(size: base))
            .padding(.leading, CGFloat(depth) * 12)
        case .numbered(let number, let content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(palette.secondary).monospacedDigit()
                inline(content).foregroundStyle(palette.text)
            }
            .font(.system(size: base))
        case .paragraph(let content):
            inline(content).font(.system(size: base)).foregroundStyle(palette.text)
        case .code(let content):
            Text(content)
                .font(.system(size: base - 1, design: .monospaced))
                .foregroundStyle(palette.text)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardRaised))
        case .table(let source):
            if let table = FCText.table(fromMarkdown: source) {
                FCTableView(table: table, palette: palette, maxRows: compact ? 4 : nil, maxColumns: compact ? 4 : nil, compact: compact)
            }
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))); table = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { flushParagraph(); flushTable(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.hasPrefix("|") { flushParagraph(); table.append(line); continue }
            flushTable()
            if line.isEmpty { flushParagraph(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[hashes] == " " {
                flushParagraph()
                blocks.append(.heading(line.distance(from: line.startIndex, to: hashes), String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                let depth = (raw.prefix { $0 == " " }.count) / 2
                blocks.append(.bullet(String(line.dropFirst(2)), min(depth, 3)))
            } else if let match = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(.numbered(String(line[match]).trimmingCharacters(in: .whitespaces), String(line[match.upperBound...])))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }
}

// MARK: - Drops

enum FCDrop {
    static let types: [UTType] = [.fileURL, .url, .image, .utf8PlainText, .plainText]

    /// File URLs from providers, delivered on the main actor one by one.
    static func fileURLs(from providers: [NSItemProvider], handler: @escaping @MainActor (URL) -> Void) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in handler(url) }
            }
        }
    }

    /// Everything a canvas drop can carry, as inputs (index = drop order).
    static func inputs(from providers: [NSItemProvider], handler: @escaping @MainActor (Int, FlowCanvasInput?, Data?) -> Void) {
        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in handler(index, .forFile(url), nil) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in handler(index, url.isFileURL ? .forFile(url) : .url(url), nil) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in handler(index, nil, data) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    let input: FlowCanvasInput = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) && !trimmed.contains(" ")
                        ? (FCIngest.normalizedURL(trimmed).map { .url($0) } ?? .text(string)) : .text(string)
                    Task { @MainActor in handler(index, input, nil) }
                }
            }
        }
    }
}
