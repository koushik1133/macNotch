import AppKit
import SwiftUI

/// The File Drop tab's content: a compact strip sized for the drawer's
/// content area (508×69). It shows the dropped files (drag them, or any
/// result, out to any app) and the actions, or the step an action is on.
struct FileDropActionStrip: View {
    @ObservedObject var controller: FileDropController
    @StateObject private var targeted = ViewFlag()
    /// The pile is spread out into one draggable tile per file.
    @StateObject private var spread = ViewFlag()

    var body: some View {
        Group {
            if spread.isOn, canSpread {
                FileDropFilesRow(controller: controller, urls: controller.visibleFiles) { spread.isOn = false }
                    .transition(.opacity)
            } else {
                switch controller.mode {
                case .empty: emptyRow
                case .actions: actionsRow
                case .renaming(let index): FileDropRenameRow(controller: controller, index: index)
                case .pickingSpace: FileDropSpaceRow(controller: controller)
                case .working(let title): workingRow(title)
                case .done(let result): FileDropResultRow(controller: controller, result: result, onSpread: showFiles)
                }
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: spread.isOn)
        .onChange(of: controller.mode) { _, _ in spread.isOn = false }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted.isOn ? SparkVTheme.red : Color.clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .contentShape(Rectangle())
        .onDrop(of: FileDropController.acceptedTypes, isTargeted: $targeted.isOn) { providers in
            controller.accept(providers)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Only a pile of several files, in the actions or result row.
    private var canSpread: Bool {
        switch controller.mode {
        case .actions, .done: controller.visibleFiles.count > 1
        default: false
        }
    }

    private func showFiles() {
        spread.isOn = true
    }

    // MARK: Empty

    private var emptyRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .frame(width: 46, height: 46)
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SparkVTheme.isApple ? SparkVTheme.textSecondary : SparkVTheme.red)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Drop files here or on the notch")
                    .font(SparkVTheme.headline(12.5))
                    .tracking(-0.2)
                    .foregroundStyle(SparkVTheme.text)
                Text(controller.note?.text ?? "Rename with AI · Compress · Convert · Space · AirDrop · Tray")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(noteColor ?? SparkVTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FileDropPill(title: "Choose…", systemImage: "plus", prominent: false) { controller.chooseFiles() }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 9) {
            FileDropPile(controller: controller, urls: controller.items.map(\.url), side: 50, onSpread: showFiles)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(controller.note?.text ?? subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(noteColor ?? SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if controller.canUndo {
                        Button("Undo") { controller.undo() }
                            .buttonStyle(SparkVPressStyle())
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(SparkVTheme.red)
                            .help("Undo the last action")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(FileDropAction.allCases) { action in
                    FileDropActionButton(action: action, enabled: controller.isAvailable(action)) {
                        controller.perform(action)
                    }
                }
            }
            Button {
                controller.clear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(SparkVTheme.surfaceHover))
            }
            .buttonStyle(SparkVPressStyle())
            .help("Clear (files stay where they are)")
        }
    }

    private var title: String {
        let items = controller.items
        guard let first = items.first else { return "" }
        return items.count == 1 ? first.name : "\(items.count) files"
    }

    private var subtitle: String {
        let items = controller.items
        let total = FileDropOps.formatBytes(items.reduce(0) { $0 + $1.size })
        if items.count == 1, let first = items.first {
            let kind = first.kind == .folder ? "Folder" : first.fileExtension.isEmpty ? "File" : first.fileExtension.uppercased()
            return "\(kind) · \(total)"
        }
        let names = items.prefix(3).map(\.name).joined(separator: ", ")
        return "\(total) · \(names)"
    }

    private var noteColor: Color? {
        guard let note = controller.note else { return nil }
        return note.tone == .warning ? SparkVTheme.warning : SparkVTheme.success
    }

    // MARK: Working

    private func workingRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            FileDropPile(controller: controller, urls: controller.items.map(\.url), side: 50)
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            FileDropPill(title: "Stop", systemImage: "stop.fill", prominent: false) { controller.cancelWork() }
        }
    }
}

// MARK: - Rename

private struct FileDropRenameRow: View {
    @ObservedObject var controller: FileDropController
    let index: Int

    var body: some View {
        let items = controller.items
        if items.indices.contains(index) {
            let item = items[index]
            let draft = controller.renameDrafts[item.id]
            HStack(spacing: 9) {
                FileDropPile(controller: controller, urls: [item.url], side: 46)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(items.count > 1 ? "Rename \(index + 1) of \(items.count)" : "Rename")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                        Text("· \(item.name)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        status(draft)
                    }
                    HStack(spacing: 4) {
                        TextField("New name", text: $controller.renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(SparkVTheme.text)
                            .onSubmit { controller.confirmRename() }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .tint(SparkVTheme.red)
                            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
                            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.isApple ? SparkVTheme.accent.opacity(0.8) : SparkVTheme.red.opacity(0.7)))
                        if item.kind != .folder, !item.fileExtension.isEmpty {
                            Text(".\(item.fileExtension)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(SparkVTheme.textTertiary)
                        }
                        Button { controller.resuggest() } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SparkVTheme.red)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(SparkVTheme.surface))
                        }
                        .buttonStyle(SparkVPressStyle())
                        .disabled(draft?.isSuggesting == true)
                        .help("Suggest another name")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 4) {
                    FileDropPill(title: "Rename", systemImage: "checkmark", prominent: true) { controller.confirmRename() }
                    HStack(spacing: 4) {
                        if items.count > 1 {
                            FileDropPill(title: "Skip", systemImage: nil, prominent: false, compact: true) { controller.skipRename() }
                        }
                        FileDropPill(title: "Cancel", systemImage: nil, prominent: false, compact: true) { controller.cancelRename() }
                    }
                }
                .frame(width: 104)
            }
        }
    }

    @ViewBuilder
    private func status(_ draft: FileDropRenameDraft?) -> some View {
        if let note = controller.note {
            Text(note.text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(note.tone == .warning ? SparkVTheme.warning : SparkVTheme.textTertiary)
                .lineLimit(1)
        } else if draft?.isSuggesting == true {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Reading…")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        } else if let source = draft?.source {
            HStack(spacing: 3) {
                Image(systemName: draft?.suggestion == nil ? "minus.circle" : "sparkles")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(source)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(SparkVTheme.textTertiary)
        }
    }
}

// MARK: - Space picker

private struct FileDropSpaceRow: View {
    @ObservedObject var controller: FileDropController

    var body: some View {
        HStack(spacing: 8) {
            Button { controller.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 22, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
            }
            .buttonStyle(SparkVPressStyle())
            .help("Back")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FileDropSpaceChip(name: "Auto", icon: "sparkles", color: SparkVTheme.accent,
                                      help: "Let the Spaces agents file each one (Inbox when unsure)") {
                        controller.send(toSpace: nil)
                    }
                    ForEach(controller.spaces) { space in
                        FileDropSpaceChip(name: space.name, icon: space.icon, color: SpaceIngestCenter.color(hex: space.color),
                                          help: "Send to \(space.name)") {
                            controller.send(toSpace: space.id)
                        }
                    }
                    if controller.spaces.isEmpty {
                        Text("No Spaces yet: Auto files into the Inbox")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .padding(.leading, 4)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct FileDropSpaceChip: View {
    let name: String
    let icon: String
    let color: Color
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(color.opacity(0.9)).frame(width: 24, height: 24)
                    if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                        Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(SparkVTheme.text)
                    } else {
                        Text(icon.isEmpty ? String(name.prefix(1)) : icon).font(.system(size: 12, weight: .bold)).foregroundStyle(SparkVTheme.text)
                    }
                }
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 76, height: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover.isOn ? (SparkVTheme.isApple ? SparkVTheme.surfaceHover : SparkVTheme.redSoft) : SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover.isOn ? FileDropStyle.hoverStroke : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
    }
}

// MARK: - Result

private struct FileDropResultRow: View {
    @ObservedObject var controller: FileDropController
    let result: FileDropResult
    var onSpread: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 9) {
            if result.outputs.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SparkVTheme.surface).frame(width: 50, height: 50)
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 18)).foregroundStyle(SparkVTheme.success)
                }
            } else {
                FileDropPile(controller: controller, urls: result.outputs, side: 50, onSpread: onSpread)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.success)
                    Text(result.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(controller.note?.text ?? (result.outputs.isEmpty ? result.detail : dragHint))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(controller.note?.tone == .warning ? SparkVTheme.warning : SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if result.undo != nil, controller.canUndo {
                    FileDropPill(title: "Undo", systemImage: "arrow.uturn.backward", prominent: false) { controller.undo() }
                }
                if result.offersZip {
                    FileDropPill(title: "Zip", systemImage: "doc.zipper", prominent: false) { controller.zipInstead() }
                        .help("Make one .zip of the originals instead")
                }
                if !result.outputs.isEmpty {
                    FileDropPill(title: nil, systemImage: "folder", prominent: false) { controller.reveal(result.outputs) }
                        .help("Show in Finder")
                }
                FileDropPill(title: "Done", systemImage: nil, prominent: true) { controller.back() }
            }
        }
    }

    private var dragHint: String {
        guard result.detail.isEmpty else { return result.detail }
        return result.outputs.count == 1 ? "Drag it anywhere" : "Drag them anywhere · click the pile for each file"
    }
}

// MARK: - Pieces

/// Up to three thumbnails fanned like a pile, with a count badge. Drags
/// every file out (copy, like a Finder drag, Dropover's "drag the stack");
/// click spreads a pile of several into one tile per file (`onSpread`),
/// double-click opens the first, right-click has Copy / Show in Finder.
struct FileDropPile: View {
    @ObservedObject var controller: FileDropController
    let urls: [URL]
    let side: CGFloat
    var onSpread: (() -> Void)? = nil
    @StateObject private var hover = ViewFlag()

    var body: some View {
        ZStack {
            ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { offset, url in
                Image(nsImage: controller.thumbnail(for: url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side - 8, height: side - 8)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .rotationEffect(.degrees(urls.count > 1 ? Double(offset) * 7 - 4 : 0))
                    .offset(x: CGFloat(offset) * 3, y: CGFloat(offset) * -1)
            }
        }
        .frame(width: side, height: side)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover.isOn ? FileDropStyle.hoverStroke : SparkVTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if urls.count > 1 {
                Text("\(urls.count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(SparkVTheme.red))
                    .offset(x: 4, y: -4)
            }
        }
        .overlay(
            TrayDragSource(
                anchor: .pointer,
                toolTip: urls.count == 1 ? "\(urls[0].lastPathComponent)\nDrag into any app · double-click to open"
                    : "Drag all \(urls.count) files into any app" + (onSpread == nil ? "" : " · click to see each file"),
                payloads: { controller.dragPayloads(for: urls) },
                onClick: urls.count > 1 ? onSpread : nil,
                onDoubleClick: { if let first = urls.first { controller.open(first) } },
                menu: { FileDropPile.menu(controller: controller, urls: urls, onSpread: urls.count > 1 ? onSpread : nil) },
                onHoverChange: { hover.isOn = $0 }
            )
        )
    }
}

extension FileDropPile {
    static func menu(controller: FileDropController, urls: [URL], onSpread: (() -> Void)?) -> NSMenu? {
        guard !urls.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let many = urls.count > 1
        menu.addItem(TrayMenuItem(many ? "Copy \(urls.count) Files" : "Copy", systemImage: "doc.on.doc") {
            controller.copyFiles(urls)
        })
        if urls.count == 1 {
            menu.addItem(TrayMenuItem("Open", systemImage: "arrow.up.forward.app") { controller.open(urls[0]) })
        }
        menu.addItem(TrayMenuItem("Show in Finder", systemImage: "folder") { controller.reveal(urls) })
        if let onSpread {
            menu.addItem(.separator())
            menu.addItem(TrayMenuItem("Show Each File", systemImage: "square.grid.3x1.below.line.grid.1x2") { onSpread() })
        }
        return menu
    }
}

/// A pile spread out: "All" (drags every file) then one tile per file, each
/// dragged on its own, like Dropover's expanded shelf. Fits the 69 pt strip.
struct FileDropFilesRow: View {
    @ObservedObject var controller: FileDropController
    let urls: [URL]
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 3) {
                FileDropPile(controller: controller, urls: urls, side: 46)
                Text("All \(urls.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Rectangle().fill(SparkVTheme.surfaceHover).frame(width: 1, height: 48)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(urls, id: \.self) { url in
                        FileDropFileTile(controller: controller, url: url)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
            FileDropPill(title: "Back", systemImage: "chevron.left", prominent: false, action: onBack)
                .help("Back to the actions")
        }
        .padding(.horizontal, 2)
    }
}

/// One file of a spread pile: its thumbnail and name; drag it out on its own.
private struct FileDropFileTile: View {
    @ObservedObject var controller: FileDropController
    let url: URL
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        VStack(spacing: 3) {
            Image(nsImage: controller.thumbnail(for: url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                .opacity(exists ? 1 : 0.35)
            Text(url.lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(exists ? SparkVTheme.text : SparkVTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 58)
        }
        .frame(width: 62, height: 60)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover.isOn ? FileDropStyle.hoverStroke : SparkVTheme.stroke, lineWidth: 1))
        .overlay(
            TrayDragSource(
                anchor: .pointer,
                toolTip: exists ? "\(url.lastPathComponent)\nDrag into any app · double-click to open" : "\(url.lastPathComponent) is no longer there",
                payloads: { controller.dragPayloads(for: [url]) },
                onClick: nil,
                onDoubleClick: { controller.open(url) },
                menu: { FileDropPile.menu(controller: controller, urls: [url], onSpread: nil) },
                onHoverChange: { hover.isOn = $0 }
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
    }
}

private struct FileDropActionButton: View {
    let action: FileDropAction
    let enabled: Bool
    let perform: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? (hover.isOn && !SparkVTheme.isApple ? SparkVTheme.red : SparkVTheme.text) : SparkVTheme.textTertiary.opacity(0.75))
                    .frame(height: 16)
                Text(action.title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? SparkVTheme.text : SparkVTheme.textTertiary.opacity(0.75))
            .frame(width: 40, height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover.isOn && enabled ? (SparkVTheme.isApple ? SparkVTheme.surfaceHover : SparkVTheme.redSoft) : SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover.isOn && enabled ? FileDropStyle.hoverStroke : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(!enabled)
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(action.help)
        .accessibilityLabel(action.title)
    }
}

struct FileDropPill: View {
    let title: String?
    let systemImage: String?
    let prominent: Bool
    var compact = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: compact ? 9 : 10, weight: .bold))
                }
                if let title {
                    Text(title).font(.system(size: compact ? 10 : 11, weight: .semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(prominent ? Color.white : SparkVTheme.text)
            .padding(.horizontal, title == nil ? 7 : (compact ? 8 : 10))
            .frame(height: compact ? 20 : 26)
            .frame(maxWidth: prominent && compact == false && title == "Rename" ? .infinity : nil)
            .background(
                Capsule().fill(prominent ? (hover.isOn ? SparkVTheme.redDeep : SparkVTheme.red) : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }
}

// MARK: - Settings

/// "File Drop" submenu for the gear menu.
struct FileDropSettingsMenu: View {
    @ObservedObject var controller: FileDropController

    var body: some View {
        Menu("File Drop") {
            Toggle("File Drop Actions", isOn: $controller.isEnabled)
            Toggle("Show Drop Shelf Under the Notch While Dragging", isOn: $controller.showsShelf)
                .disabled(!controller.isEnabled)
            Picker("AI Rename Style", selection: $controller.nameStyle) {
                ForEach(FileDropSettings.NameStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Divider()
            Button("Choose Files…") { controller.chooseFiles() }
        }
    }
}

/// Look-dependent strip details.
enum FileDropStyle {
    /// A hovered tile's outline: a soft white lift in Apple, a red hairline in SparkV Red.
    static var hoverStroke: Color { SparkVTheme.isApple ? Color.white.opacity(0.20) : SparkVTheme.red.opacity(0.6) }
}
