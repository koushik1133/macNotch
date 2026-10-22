import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ConverterLayout {
    static let chipRowHeight: CGFloat = 20
    static let targetRowHeight: CGFloat = 22
    static let rowSpacing: CGFloat = 5
    static let cardWidth: CGFloat = 168
    static let cardCorner: CGFloat = 12
    static let wellPadding: CGFloat = 4
    static let wellCorner: CGFloat = cardCorner + wellPadding
    /// Below this content height the dropped-file chips fold into a badge in
    /// the format row, so the results well keeps room for its cards.
    static let compactBelow: CGFloat = 96
    /// Card corner that passes clicks to its Save / Reveal / Tray buttons.
    static let cardButtons = CGSize(width: 74, height: 22)
}

/// Converter tab for the drawer (~508×114 pt): drop files, pick one of the
/// formats that fit them, drag the result anywhere. iLovePDF-style tools,
/// all on this Mac.
///
/// Rows: dropped files · format buttons (or an inline password/text field)
/// with the More… options menu · results to drag out (and running jobs).
struct ConverterTabView: View {
    @EnvironmentObject private var converter: ConverterController
    @StateObject private var dropTarget = ViewFlag()

    var body: some View {
        Group {
            if converter.inputs.isEmpty, converter.results.isEmpty, converter.jobs.isEmpty {
                ConverterDropZone(isTargeted: dropTarget.isOn)
            } else {
                GeometryReader { proxy in
                    let compact = proxy.size.height < ConverterLayout.compactBelow
                    VStack(spacing: ConverterLayout.rowSpacing) {
                        if !compact {
                            ConverterInputRow()
                                .frame(height: ConverterLayout.chipRowHeight)
                        }
                        ConverterTargetRow(showsInputsBadge: compact)
                            .frame(height: ConverterLayout.targetRowHeight)
                        ConverterResultsWell(isTargeted: dropTarget.isOn)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTarget.isOn) { providers in
            converter.accept(providers)
        }
    }
}

// MARK: - Empty state

private struct ConverterDropZone: View {
    @EnvironmentObject private var converter: ConverterController
    let isTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ConverterLayout.wellCorner, style: .continuous)
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 17))
                    .foregroundStyle(isTargeted ? SparkVTheme.red : SparkVTheme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drop files to convert")
                        .font(SparkVTheme.headline(12.5))
                        .tracking(-0.2)
                        .foregroundStyle(SparkVTheme.text)
                    Text("PDF · Word · PowerPoint · Excel/CSV · images · Markdown — converted on this Mac")
                        .font(.system(size: 9.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            HStack(spacing: 6) {
                ConverterPill(title: "Choose Files…", systemImage: "plus", prominent: true) { converter.chooseFiles() }
                    .help("Pick files to convert")
                ConverterPill(title: "Converted", systemImage: "folder") { converter.openOutputFolder() }
                    .help("Open the folder with past conversions")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isTargeted ? SparkVTheme.redSoft : SparkVTheme.surface))
        .overlay(
            shape.strokeBorder(
                isTargeted ? SparkVTheme.red.opacity(0.8) : Color.white.opacity(0.16),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

// MARK: - Inputs

private struct ConverterInputRow: View {
    @EnvironmentObject private var converter: ConverterController

    var body: some View {
        HStack(spacing: 5) {
            if converter.inputs.isEmpty {
                Text("Drop more files to convert")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(converter.inputs) { input in
                            ConverterInputChip(input: input)
                        }
                    }
                }
            }
            ConverterIconButton(systemImage: "plus", help: "Add files") { converter.chooseFiles() }
            if !converter.inputs.isEmpty {
                ConverterIconButton(systemImage: "xmark", help: "Clear dropped files") { converter.clearInputs() }
            }
        }
    }
}

private struct ConverterInputChip: View {
    @EnvironmentObject private var converter: ConverterController
    let input: ConverterInput
    @StateObject private var hover = ViewFlag()

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: input.url.path))
                .resizable()
                .frame(width: 13, height: 13)
            Text(input.name)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)
            if !input.detail.isEmpty {
                Text(input.detail)
                    .font(.system(size: 8.5).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
            }
            Button { converter.remove(input) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(hover.isOn ? (SparkVTheme.isApple ? SparkVTheme.text : SparkVTheme.red) : SparkVTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove \(input.name)")
        }
        .foregroundStyle(SparkVTheme.text)
        .padding(.horizontal, 7)
        .frame(height: ConverterLayout.chipRowHeight)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .onHover { hover.isOn = $0 }
        .help(input.url.path)
        .contextMenu {
            // Merge and Images → PDF follow this order.
            if converter.inputs.count > 1 {
                Button("Move Earlier") { converter.move(input, by: -1) }
                    .disabled(converter.inputs.first?.id == input.id)
                Button("Move Later") { converter.move(input, by: 1) }
                    .disabled(converter.inputs.last?.id == input.id)
                Divider()
            }
            Button("Remove") { converter.remove(input) }
        }
    }
}

// MARK: - Targets

/// Short drawers: the dropped files as one "2 files" menu in the format row.
private struct ConverterInputsBadge: View {
    @EnvironmentObject private var converter: ConverterController

    var body: some View {
        Menu {
            ForEach(converter.inputs) { input in
                Button("Remove \(input.name)") { converter.remove(input) }
            }
            Divider()
            Button("Add Files…") { converter.chooseFiles() }
            Button("Clear All") { converter.clearInputs() }
                .disabled(converter.inputs.isEmpty)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: converter.inputs.count == 1 ? converter.inputs[0].kind.symbol : "doc.on.doc")
                    .font(.system(size: 8.5, weight: .bold))
                Text(converter.inputs.count == 1 ? converter.inputs[0].name : "\(converter.inputs.count) files")
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 90)
            }
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, 7)
            .frame(height: ConverterLayout.targetRowHeight)
            .background(Capsule().fill(SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(converter.inputs.map(\.name).joined(separator: "\n"))
    }
}

private struct ConverterTargetRow: View {
    @EnvironmentObject private var converter: ConverterController
    var showsInputsBadge = false

    var body: some View {
        HStack(spacing: 5) {
            if showsInputsBadge, !converter.inputs.isEmpty, converter.pendingPrompt == nil {
                ConverterInputsBadge()
            }
            if let op = converter.pendingPrompt {
                ConverterPromptStrip(op: op)
            } else if converter.inputs.isEmpty {
                if showsInputsBadge {
                    Text("Drop more files to convert")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
                if showsInputsBadge {
                    ConverterIconButton(systemImage: "plus", help: "Add files") { converter.chooseFiles() }
                }
            } else if converter.targets.isEmpty {
                Text("No conversions for this mix of files")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SparkVTheme.isApple ? SparkVTheme.textTertiary : SparkVTheme.red)
                    .padding(.leading, 3)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(converter.targets) { op in
                            ConverterTargetButton(op: op)
                        }
                    }
                }
            }
            ConverterOptionsMenu()
        }
    }
}

private struct ConverterTargetButton: View {
    @EnvironmentObject private var converter: ConverterController
    let op: ConverterOp
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button { converter.start(op) } label: {
            HStack(spacing: 4) {
                Image(systemName: op.symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hover.isOn || SparkVTheme.isApple ? Color.white : SparkVTheme.red)
                Text(op.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                if converter.prompt(for: op) != nil {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, 8)
            .frame(height: ConverterLayout.targetRowHeight)
            // Apple: the previous version's tinted capsules (accent, deeper on hover).
            .background(Capsule().fill(SparkVTheme.isApple
                ? SparkVTheme.accent.opacity(hover.isOn ? 0.55 : 0.30)
                : (hover.isOn ? SparkVTheme.red : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(hover.isOn || SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(op.help)
    }
}

/// Inline field for the text an op needs (password, watermark, pages).
private struct ConverterPromptStrip: View {
    @EnvironmentObject private var converter: ConverterController
    let op: ConverterOp

    private var pagesPlaceholder: String {
        guard op == .split else { return "Pages, e.g. 1-3, 5, 8-" }
        return converter.options.splitMode == .fixed ? "Pages per file, e.g. 2" : "Ranges, e.g. 1-3, 4-6"
    }

    var body: some View {
        let prompt = converter.prompt(for: op)
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                Image(systemName: op.symbol)
                    .font(.system(size: 8.5, weight: .bold))
                Text(op.title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(SparkVTheme.text)
            .padding(.leading, 4)

            Group {
                switch prompt {
                case .password:
                    SecureField("Current password", text: $converter.options.password)
                case .newPassword:
                    SecureField("New password", text: $converter.options.password)
                case .watermark:
                    TextField("Watermark text", text: $converter.options.watermarkText)
                case .pageRanges:
                    TextField(pagesPlaceholder, text: $converter.options.pageRanges)
                case nil:
                    EmptyView()
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(SparkVTheme.text)
            .tint(SparkVTheme.red)
            .padding(.horizontal, 8)
            .frame(height: ConverterLayout.targetRowHeight)
            .background(Capsule().fill(SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(SparkVTheme.isApple ? SparkVTheme.stroke : SparkVTheme.red.opacity(0.7), lineWidth: 1))
            .onSubmit { converter.confirmPrompt() }

            ConverterPill(title: "Go", systemImage: "return", height: ConverterLayout.targetRowHeight, prominent: true) {
                converter.confirmPrompt()
            }
            .help("Run \(op.title)")
            ConverterIconButton(systemImage: "xmark", help: "Cancel") { converter.cancelPrompt() }
        }
    }
}

/// "More…": every option, grouped by what it affects.
private struct ConverterOptionsMenu: View {
    @EnvironmentObject private var converter: ConverterController

    var body: some View {
        Menu {
            // Every tool for the dropped files, even ones scrolled out of the row.
            if !converter.targets.isEmpty, converter.pendingPrompt == nil {
                Section("Convert To") {
                    ForEach(converter.targets) { op in
                        Button("\(op.title)\(converter.prompt(for: op) == nil ? "" : "…") — \(op.help)") { converter.start(op) }
                    }
                }
            }
            Section("PDF → Images") {
                Picker("Resolution", selection: $converter.options.dpi) {
                    Text("72 dpi (screen)").tag(72)
                    Text("150 dpi").tag(150)
                    Text("300 dpi (print)").tag(300)
                }
            }
            Section("Images") {
                Picker("Quality", selection: $converter.options.imageQuality) {
                    Text("Small (60%)").tag(0.6)
                    Text("Balanced (85%)").tag(0.85)
                    Text("Best (95%)").tag(0.95)
                }
                Picker("Resize To", selection: $converter.options.maxPixelSize) {
                    ForEach([800, 1200, 1600, 2400, 3200], id: \.self) { size in
                        Text("\(size) px long side").tag(size)
                    }
                }
                Picker("Page Size (Images → PDF)", selection: $converter.options.pageSize) {
                    ForEach(ConverterPageSize.allCases) { size in Text(size.title).tag(size) }
                }
            }
            Section("PDF Tools") {
                Picker("Compression", selection: $converter.options.compression) {
                    ForEach(ConverterCompression.allCases) { level in Text(level.title).tag(level) }
                }
                Picker("Split", selection: $converter.options.splitMode) {
                    ForEach(ConverterSplitMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Picker("Rotate", selection: $converter.options.rotation) {
                    Text("90° right").tag(90)
                    Text("180°").tag(180)
                    Text("90° left").tag(270)
                }
                Picker("Page Numbers", selection: $converter.options.numberPosition) {
                    ForEach(ConverterNumberPosition.allCases) { position in Text(position.title).tag(position) }
                }
                Toggle("Show Total (1 / 12)", isOn: $converter.options.numberWithTotal)
                Picker("Watermark Opacity", selection: $converter.options.watermarkOpacity) {
                    Text("Faint (10%)").tag(0.1)
                    Text("Light (18%)").tag(0.18)
                    Text("Medium (30%)").tag(0.3)
                    Text("Strong (50%)").tag(0.5)
                }
                Toggle("Read Scanned Pages with OCR", isOn: $converter.options.ocrScannedPages)
            }
            Divider()
            Button("Open Converted Folder") { converter.openOutputFolder() }
            Button("Clear Results") { converter.clearResults() }
                .disabled(converter.results.isEmpty)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: ConverterLayout.targetRowHeight, height: ConverterLayout.targetRowHeight)
                .background(Circle().fill(SparkVTheme.surface))
                .overlay(Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Every tool for these files, plus options: resolution, quality, compression, page size…")
    }
}

// MARK: - Results

private struct ConverterResultsWell: View {
    @EnvironmentObject private var converter: ConverterController
    let isTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ConverterLayout.wellCorner, style: .continuous)
        GeometryReader { proxy in
            let cardHeight = max(proxy.size.height - ConverterLayout.wellPadding * 2, 30)
            ZStack {
                if converter.jobs.isEmpty, converter.results.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.point.up.left")
                            .font(.system(size: 11))
                        Text("Pick a format above — results land here, ready to drag anywhere")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(converter.jobs) { job in
                                ConverterJobCard(job: job, height: cardHeight)
                            }
                            ForEach(converter.results) { result in
                                ConverterResultCard(result: result, height: cardHeight)
                            }
                        }
                        .padding(ConverterLayout.wellPadding)
                    }
                }
                if let message = converter.errorMessage {
                    ConverterErrorBanner(message: message)
                }
            }
        }
        .clipShape(shape)
        .background(shape.fill(isTargeted ? SparkVTheme.redSoft : SparkVTheme.surface))
        .overlay(
            shape.strokeBorder(
                isTargeted ? SparkVTheme.red.opacity(0.8) : SparkVTheme.stroke,
                style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [5, 4] : [])
            )
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

private struct ConverterJobCard: View {
    @EnvironmentObject private var converter: ConverterController
    let job: ConverterJob
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(SparkVTheme.isApple ? Color.white : SparkVTheme.red)
            VStack(alignment: .leading, spacing: height >= 44 ? 4 : 2) {
                Text("\(job.op.title)…")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(SparkVTheme.red)
                if height >= 44 {
                    Text(job.inputCount == 1 ? "\(Int(job.progress * 100))%" : "\(job.inputCount) files · \(Int(job.progress * 100))%")
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            Button { converter.cancel(job) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 9)
        .frame(width: ConverterLayout.cardWidth, height: height)
        .background(RoundedRectangle(cornerRadius: ConverterLayout.cardCorner, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: ConverterLayout.cardCorner, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
    }
}

/// A finished conversion. AppKit owns the mouse over it (the Tray's drag
/// source): drag = drag the files out, double-click = open, right-click =
/// menu. The top-right buttons save to Downloads, reveal, or add to the Tray.
private struct ConverterResultCard: View {
    @EnvironmentObject private var converter: ConverterController
    let result: ConverterResult
    let height: CGFloat
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ConverterLayout.cardCorner, style: .continuous)
        HStack(spacing: 7) {
            preview
                .frame(width: max(height - 14, 24), height: max(height - 14, 24))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(result.op.title)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(SparkVTheme.red))
                    Spacer(minLength: ConverterLayout.cardButtons.width - 6)
                }
                Text(result.summary)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(height >= 44 ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                // Short drawers drop the file name; the tooltip still has it.
                if height >= 44 {
                    Text(result.title)
                        .font(.system(size: 8.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: ConverterLayout.cardWidth, height: height)
        .background(shape.fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
        .overlay(shape.strokeBorder(hover.isOn ? (SparkVTheme.isApple ? Color.white.opacity(0.18) : SparkVTheme.red.opacity(0.55)) : SparkVTheme.stroke, lineWidth: 1))
        .overlay(
            TrayDragSource(
                anchor: .pointer,
                toolTip: "\(result.title)\nDrag \(result.files.count == 1 ? "the file" : "all \(result.files.count) files") into any app · double-click to open",
                payloads: { converter.dragPayloads(for: result) },
                onClick: nil,
                onDoubleClick: { converter.open(result) },
                menu: { makeMenu() },
                onHoverChange: { hover.isOn = $0 },
                passThroughTopTrailing: ConverterLayout.cardButtons
            )
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 1) {
                ConverterCardButton(
                    systemImage: converter.savedResults.contains(result.id) ? "checkmark" : "arrow.down.to.line",
                    help: "Save to Downloads"
                ) { converter.saveToDownloads(result) }
                ConverterCardButton(systemImage: "magnifyingglass", help: "Reveal in Finder") { converter.reveal(result) }
                ConverterCardButton(systemImage: "tray.and.arrow.down", help: "Add to Tray") { converter.addToTray(result) }
                ConverterCardButton(systemImage: "arrow.triangle.2.circlepath", help: "Convert again: use as the new input") {
                    converter.continueWith(result)
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 5)
            .opacity(hover.isOn ? 1 : 0.55)
        }
        .clipShape(shape)
    }

    @ViewBuilder
    private var preview: some View {
        let corner = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let image = converter.previews[result.id] {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(corner.fill(SparkVTheme.surface))
                    .clipShape(corner)
                if result.files.count > 1 {
                    Text("\(result.files.count)")
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.white))
                        .offset(x: 3, y: 3)
                }
            }
        } else {
            corner.fill(SparkVTheme.surface)
                .overlay(Image(systemName: result.op.symbol).font(.system(size: 13)).foregroundStyle(SparkVTheme.textSecondary))
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(TrayMenuItem(result.files.count == 1 ? "Open" : "Show Files", systemImage: "arrow.up.forward.app") {
            converter.open(result)
        })
        menu.addItem(TrayMenuItem("Save to Downloads", systemImage: "arrow.down.to.line") { converter.saveToDownloads(result) })
        menu.addItem(TrayMenuItem("Reveal in Finder", systemImage: "magnifyingglass") { converter.reveal(result) })
        menu.addItem(TrayMenuItem("Add to Tray", systemImage: "tray.and.arrow.down") { converter.addToTray(result) })
        menu.addItem(TrayMenuItem("Copy", systemImage: "doc.on.doc") { converter.copyToClipboard(result) })
        menu.addItem(TrayMenuItem("Convert Again", systemImage: "arrow.triangle.2.circlepath") { converter.continueWith(result) })
        menu.addItem(.separator())
        menu.addItem(TrayMenuItem("Remove from List", systemImage: "xmark") { converter.removeResult(result) })
        return menu
    }
}

private struct ConverterErrorBanner: View {
    @EnvironmentObject private var converter: ConverterController
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SparkVTheme.warning)
            Text(message)
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button { converter.dismissError() } label: {
                Image(systemName: "xmark").foregroundStyle(SparkVTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.background))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity)
    }
}

// MARK: - Small controls

private struct ConverterPill: View {
    let title: String
    let systemImage: String
    var height: CGFloat = 20
    var prominent = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.white : SparkVTheme.text)
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(Capsule().fill(prominent
                ? (hover.isOn ? SparkVTheme.redDeep : SparkVTheme.red)
                : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}

private struct ConverterIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(width: ConverterLayout.chipRowHeight, height: ConverterLayout.chipRowHeight)
                .background(Circle().fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
                .overlay(Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help)
    }
}

private struct ConverterCardButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Capsule().fill(hover.isOn ? (SparkVTheme.isApple ? SparkVTheme.accent : SparkVTheme.red) : Color.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help)
    }
}
