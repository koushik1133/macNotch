import AppKit
import SwiftUI

private enum DLLayout {
    static let headerHeight: CGFloat = 18
    static let headerSpacing: CGFloat = 4
    static let wellPadding: CGFloat = 4
    static let cardSpacing: CGFloat = 6
    static let cardWidth: CGFloat = 216
    static let cardCorner: CGFloat = 12
    static let wellCorner: CGFloat = cardCorner + wellPadding
}

/// Drawer tab (about 508×114 pt): a header with Undo, Rules and settings,
/// then a horizontally scrolling row of cards, newest first: copies and
/// sends in flight (Finder, LocalSend) ahead of the downloads.
struct DownloadsDrawerView: View {
    @ObservedObject var controller: DownloadsController
    @ObservedObject private var transfers = ShelfTransfersMonitor.shared
    /// Off until the drawer is on screen, so the cards fade in in turn.
    @StateObject private var appeared = ViewFlag()

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = max(proxy.size.height - DLLayout.headerHeight - DLLayout.headerSpacing, 0)
            VStack(spacing: DLLayout.headerSpacing) {
                DownloadsDrawerHeader(controller: controller)
                    .frame(height: DLLayout.headerHeight)
                content(cardHeight: max(rowHeight - DLLayout.wellPadding * 2, 40))
                    .frame(width: proxy.size.width, height: rowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: DLLayout.wellCorner, style: .continuous)
                            .fill(SparkVTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DLLayout.wellCorner, style: .continuous)
                            .strokeBorder(SparkVTheme.stroke, lineWidth: 1)
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .padding(.vertical, 2)
        .onAppear { appeared.isOn = true }
        .onDisappear { appeared.isOn = false }
    }

    @ViewBuilder
    private func content(cardHeight: CGFloat) -> some View {
        if !transfers.transfers.isEmpty, controller.status != .running || controller.items.isEmpty {
            // Copies and sends show even while the download watcher is off.
            cardRow(cardHeight: cardHeight, downloads: [])
        } else {
            statusContent(cardHeight: cardHeight)
        }
    }

    private func cardRow(cardHeight: CGFloat, downloads: [DownloadItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: DLLayout.cardSpacing) {
                ForEach(Array(transfers.transfers.enumerated()), id: \.element.id) { index, transfer in
                    ShelfTransferCard(monitor: transfers, transfer: transfer)
                        .frame(width: DLLayout.cardWidth, height: cardHeight)
                        .sparkVStaggeredEntrance(appeared.isOn, index: index)
                }
                ForEach(Array(downloads.enumerated()), id: \.element.id) { index, item in
                    DownloadCard(controller: controller, item: item)
                        .frame(width: DLLayout.cardWidth, height: cardHeight)
                        .sparkVStaggeredEntrance(appeared.isOn, index: index + transfers.transfers.count)
                }
            }
            .padding(DLLayout.wellPadding)
        }
    }

    @ViewBuilder
    private func statusContent(cardHeight: CGFloat) -> some View {
        switch controller.status {
        case .off:
            DownloadsNotice(symbol: "arrow.down.circle",
                            title: "Download watcher is off",
                            detail: "Shows progress for Safari, Chrome and Firefox downloads under the notch, then offers to sort each file. Nothing moves unless you choose.",
                            button: ("Turn On", { controller.setEnabled(true) }))
        case .starting:
            DownloadsNotice(symbol: "hourglass", title: "Opening Downloads…",
                            detail: "If macOS asks, allow SparkV to access the Downloads folder.", button: nil)
        case .denied:
            DownloadsNotice(symbol: "hand.raised.fill",
                            title: "macOS blocked access to Downloads",
                            detail: "Turn on Downloads Folder for SparkV in Privacy & Security › Files & Folders, then try again.",
                            button: ("Open Settings", { controller.openPrivacySettings() }),
                            secondary: ("Try Again", { controller.retry() }))
        case .failed(let reason):
            DownloadsNotice(symbol: "exclamationmark.triangle.fill", title: "Can't watch Downloads",
                            detail: reason, button: ("Try Again", { controller.retry() }))
        case .running:
            if controller.items.isEmpty {
                DownloadsNotice(symbol: "tray.and.arrow.down", title: "No downloads yet",
                                detail: "New files in Downloads show up here with progress, speed and a suggested folder.",
                                button: nil)
            } else {
                cardRow(cardHeight: cardHeight, downloads: controller.items)
            }
        }
    }
}

struct DownloadsDrawerHeader: View {
    @ObservedObject var controller: DownloadsController
    @ObservedObject private var transfers = ShelfTransfersMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DownloadsPalette.accent)
            Text("Downloads")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(SparkVTheme.text)
            Text(statusText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(controller.notice == nil ? DownloadsPalette.secondary : SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if controller.canUndo {
                DownloadsHeaderButton(title: "Undo", symbol: "arrow.uturn.backward", help: "Put the last sorted file back") {
                    controller.undoLast()
                }
            }
            DownloadsHeaderButton(title: "Rules", symbol: "slider.horizontal.3", help: "Edit sorting rules") {
                controller.openRulesEditor()
            }
            Menu {
                Toggle("Watch Downloads Folder", isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
                Toggle("Show Progress Under the Notch", isOn: $controller.showsActivity)
                Toggle("Suggest Folders with Apple Intelligence", isOn: $controller.suggestsWithAI)
                Divider()
                Button("Edit Rules…") { controller.openRulesEditor() }
                Button("Open Downloads Folder") { NSWorkspace.shared.open(controller.folder) }
                Divider()
                Button("Clear Finished") {
                    controller.clearFinished()
                    transfers.clearFinished()
                }
                .disabled(!controller.items.contains { !$0.isActive } && !transfers.transfers.contains { !$0.isActive })
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Download watcher settings")
            .accessibilityLabel("Download watcher settings")
        }
    }

    private var statusText: String {
        if let notice = controller.notice { return notice }
        let copying = transfers.activeTransfers.count
        if copying > 0, controller.activeItems.isEmpty {
            return copying == 1 ? "1 transfer in progress" : "\(copying) transfers in progress"
        }
        switch controller.status {
        case .running:
            let active = controller.activeItems.count
            if active > 0 { return active == 1 ? "1 in progress" : "\(active) in progress" }
            return controller.items.isEmpty ? "Watching" : "\(controller.items.count) recent"
        case .off: return "Off"
        case .starting: return "Starting"
        case .denied: return "No access"
        case .failed: return "Stopped"
        }
    }
}

struct DownloadsHeaderButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .help(help)
    }
}

/// One download: icon, name and source on top; progress or the sort pill in
/// the middle; Open, Reveal, Tray, Space and More at the bottom.
struct DownloadCard: View {
    @ObservedObject var controller: DownloadsController
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(nsImage: DownloadsIcons.icon(for: item))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                    .opacity(item.isActive ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(DownloadFormat.detailLine(item))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(DownloadsPalette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .help(item.url.path)
            middle
            Spacer(minLength: 0)
            actions
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: DLLayout.cardCorner, style: .continuous)
                .fill(SparkVTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DLLayout.cardCorner, style: .continuous)
                .strokeBorder(item.isActive ? SparkVTheme.red.opacity(0.45) : SparkVTheme.stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DLLayout.cardCorner, style: .continuous))
        .onTapGesture(count: 2) { if !item.isActive { controller.open(item.id) } }
        .contextMenu { contextItems }
    }

    @ViewBuilder
    private var middle: some View {
        if item.isActive {
            VStack(alignment: .leading, spacing: 3) {
                DownloadsBar(fraction: item.fraction, tint: item.phase == .paused ? SparkVTheme.warning : DownloadsPalette.accent)
                Text(DownloadFormat.progressLine(item))
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(DownloadsPalette.secondary)
                    .lineLimit(1)
            }
        } else if let move = item.move {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DownloadsPalette.accent)
                Text("In \(move.destination.displayName)\(move.automatic ? " (auto)" : "")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Button("Undo") { controller.undo(item.id) }
                    .buttonStyle(SparkVPressStyle())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DownloadsPalette.accent)
                    .help("Move it back to \(move.from.deletingLastPathComponent().lastPathComponent)")
            }
            .frame(height: 18)
        } else {
            sortRow
        }
    }

    private var sortRow: some View {
        let suggestion = controller.suggestions[item.id]
        let thinking = controller.thinking.contains(item.id)
        return HStack(spacing: 4) {
            Button {
                if suggestion != nil { controller.sortWithSuggestion(item.id) } else { controller.chooseFolder(for: item.id) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: suggestion?.isAI == true ? "sparkles" : (suggestion == nil ? "folder" : "arrow.right"))
                        .font(.system(size: 8.5, weight: .bold))
                    Text(suggestion.map { "Sort to \($0.destination.displayName)" } ?? "Sort…")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(suggestion == nil ? SparkVTheme.text : Color.white)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(suggestion == nil ? SparkVTheme.surfaceHover : SparkVTheme.red))
                .overlay(Capsule().strokeBorder(suggestion == nil ? SparkVTheme.stroke : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(SparkVPressStyle())
            .help(suggestion.map { "\($0.destination.displayPath) — \($0.reason)" } ?? "Choose a folder")
            Menu {
                sortMenuItems
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Other folders")
            .accessibilityLabel("Other folders")
            if thinking {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                    .help("Apple Intelligence is picking a folder")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private var sortMenuItems: some View {
        if let pick = controller.aiPicks[item.id], pick != controller.suggestions[item.id]?.destination {
            Button("✦ \(pick.displayName) (Apple Intelligence)") { controller.sort(id: item.id, to: pick) }
            Divider()
        }
        ForEach(controller.folderChoices(excluding: item.url)) { choice in
            Button(choice.name) { controller.sort(id: item.id, to: choice.destination) }
        }
        Divider()
        Button("Send to a Space") { controller.sort(id: item.id, to: .space) }
        Button("Choose Folder…") { controller.chooseFolder(for: item.id) }
        if let suggestion = controller.suggestions[item.id] {
            Divider()
            Button("Always Sort Like This…") { controller.makeRule(from: item.id, destination: suggestion.destination) }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if item.isActive, let controls = controller.controls[item.id] {
                // The browser's own Pause / Cancel, through its published progress.
                if controls.canPause {
                    DownloadsIconButton(symbol: controls.isPaused ? "play.fill" : "pause.fill",
                                        help: controls.isPaused ? "Resume" : "Pause", enabled: true) { controller.togglePause(item.id) }
                }
                DownloadsIconButton(symbol: "xmark", help: "Cancel Download", enabled: controls.canCancel) { controller.cancelDownload(item.id) }
                DownloadsIconButton(symbol: "magnifyingglass", help: "Show in Finder", enabled: true) { controller.reveal(item.id) }
                Spacer(minLength: 0)
            } else {
                finishedActions
            }
        }
    }

    private var finishedActions: some View {
        HStack(spacing: 2) {
            DownloadsIconButton(symbol: "arrow.up.forward.app", help: "Open", enabled: !item.isActive) { controller.open(item.id) }
            DownloadsIconButton(symbol: "magnifyingglass", help: "Show in Finder", enabled: true) { controller.reveal(item.id) }
            DownloadsIconButton(symbol: item.addedToTray ? "tray.full.fill" : "tray.and.arrow.down", help: "Add to Tray",
                                enabled: !item.isActive) { controller.addToTray(item.id) }
            DownloadsIconButton(symbol: item.sentToSpace ? "square.stack.3d.up.fill" : "square.stack.3d.up", help: "Send to Space",
                                enabled: !item.isActive) { controller.sendToSpace(item.id) }
            Spacer(minLength: 0)
            Menu {
                contextItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
    }

    @ViewBuilder
    private var contextItems: some View {
        if !item.isActive {
            Button("Open") { controller.open(item.id) }
        }
        Button("Show in Finder") { controller.reveal(item.id) }
        if item.isActive, let controls = controller.controls[item.id] {
            if controls.canPause {
                Button(controls.isPaused ? "Resume Download" : "Pause Download") { controller.togglePause(item.id) }
            }
            if controls.canCancel {
                Button("Cancel Download") { controller.cancelDownload(item.id) }
            }
        }
        if !item.isActive {
            Button("Add to Tray") { controller.addToTray(item.id) }
            Button("Send to Space") { controller.sendToSpace(item.id) }
            Button("AirDrop…") { controller.airDrop(item.id) }
            Button("Share…") {
                let url = item.url
                ShelfShare.presentAtPointer([url as NSURL], localSendFiles: { [url] })
            }
            Button("Send to Android / Windows…") { LocalSendPanelController.shared.open(files: [item.url]) }
            Divider()
            if item.move != nil {
                Button("Undo Sort") { controller.undo(item.id) }
            } else {
                Button("Move to Folder…") { controller.chooseFolder(for: item.id) }
            }
            if let source = item.sourceURL, let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                Button("Copy Source Link") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(source, forType: .string)
                }
            }
            Divider()
            Button("Remove from List") { controller.forget(item.id) }
        }
    }
}

struct DownloadsIconButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(enabled ? (hover.isOn ? (SparkVTheme.isApple ? SparkVTheme.text : SparkVTheme.red) : SparkVTheme.textSecondary) : Color.white.opacity(0.25))
                .frame(width: 24, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover.isOn && enabled ? SparkVTheme.surfaceHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(!enabled)
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct DownloadsNotice: View {
    let symbol: String
    let title: String
    let detail: String
    let button: (String, () -> Void)?
    var secondary: (String, () -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DownloadsPalette.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 5) {
                if let button {
                    Button(button.0, action: button.1)
                        .buttonStyle(SparkVPressStyle())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(Capsule().fill(SparkVTheme.red))
                }
                if let secondary {
                    Button(secondary.0, action: secondary.1)
                        .buttonStyle(SparkVPressStyle())
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
