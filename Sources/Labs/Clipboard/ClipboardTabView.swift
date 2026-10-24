import AppKit
import SwiftUI

/// Per-view UI state for the Clipboard tab (instead of @State, which needs
/// the macro plugin the Command Line Tools don't ship).
@MainActor
final class ClipboardTabUI: ObservableObject {
    @Published var query = ""
    @Published var filter: ClipboardFilter = .all
}

private enum ClipLayout {
    static let headerHeight: CGFloat = 18
    static let headerSpacing: CGFloat = 4
    static let wellPadding: CGFloat = 4
    static let cardSpacing: CGFloat = 6
    static let cardCorner: CGFloat = 12
    static let wellCorner: CGFloat = cardCorner + wellPadding
    /// Top-trailing corner that passes clicks to the hover pin/delete buttons.
    static let hoverButtons = CGSize(width: 44, height: 22)
    /// The same with a smart action button (Open, Call, Reveal…) in front.
    static let hoverButtonsWithAction = CGSize(width: 66, height: 22)
}

/// Drawer tab (~508×114 pt): search and filters on top, then a horizontally
/// scrolling row of cards. Click = copy, double-click = paste into the
/// frontmost app, drag = drag out, hover = pin/delete, right-click = menu.
struct ClipboardTabView: View {
    @EnvironmentObject private var clipboard: ClipboardController
    @StateObject private var ui = ClipboardTabUI()
    /// Off until the tab is on screen, so the cards fade in in turn.
    @StateObject private var appeared = ViewFlag()

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = max(proxy.size.height - ClipLayout.headerHeight - ClipLayout.headerSpacing, 0)
            let cardHeight = max(rowHeight - ClipLayout.wellPadding * 2, 40)
            VStack(spacing: ClipLayout.headerSpacing) {
                ClipboardTabHeader(ui: ui)
                    .frame(height: ClipLayout.headerHeight)
                ClipboardWell {
                    content(cardHeight: cardHeight)
                }
                .frame(height: rowHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .padding(.vertical, 2)
        .onAppear { appeared.isOn = true }
        .onDisappear { appeared.isOn = false }
    }

    @ViewBuilder
    private func content(cardHeight: CGFloat) -> some View {
        switch clipboard.status {
        case .off:
            ClipboardNotice(
                symbol: "doc.on.clipboard",
                title: "Clipboard history is off",
                detail: "Keeps your last 30 copies on this Mac only. Passwords and private copies are skipped.",
                button: ("Turn On", { clipboard.setEnabled(true) })
            )
        case .needsPermission, .denied:
            ClipboardNotice(
                symbol: "hand.raised.fill",
                title: clipboard.status == .denied ? "macOS blocks clipboard access" : "macOS asks before every read",
                detail: "Choose Allow for SparkV in Privacy & Security › Paste from Other Apps.",
                button: ("Open Settings", { clipboard.openPrivacySettings() })
            )
        case .running, .paused:
            let shown = clipboard.filtered(query: ui.query, filter: ui.filter)
            if shown.isEmpty {
                ClipboardNotice(
                    symbol: emptySymbol,
                    title: emptyTitle,
                    detail: emptyDetail,
                    button: clipboard.isPaused ? ("Resume", { clipboard.setPaused(false) }) : nil
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: ClipLayout.cardSpacing) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            ClipboardCard(item: item, height: cardHeight)
                                .sparkVStaggeredEntrance(appeared.isOn, index: index)
                        }
                    }
                    .padding(ClipLayout.wellPadding)
                }
            }
        }
    }

    private var emptySymbol: String {
        if !ui.query.isEmpty || ui.filter != .all { return "magnifyingglass" }
        return clipboard.isPaused ? "pause.circle" : "doc.on.clipboard"
    }

    private var emptyTitle: String {
        if !ui.query.isEmpty || ui.filter != .all { return "No matches" }
        return clipboard.isPaused ? "History is paused" : "Nothing copied yet"
    }

    private var emptyDetail: String {
        if !ui.query.isEmpty || ui.filter != .all { return "Try another search or filter." }
        return clipboard.isPaused
            ? "Copies made while paused are never recorded."
            : "Copy text, links, images or files and they show up here."
    }
}

// MARK: - Header

private struct ClipboardTabHeader: View {
    @EnvironmentObject private var clipboard: ClipboardController
    @ObservedObject var ui: ClipboardTabUI

    var body: some View {
        if clipboard.status == .running || clipboard.status == .paused {
            controls
        } else {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 9, weight: .semibold))
                Text("Clipboard")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(SparkVTheme.textSecondary)
            .padding(.leading, 6)
        }
    }

    private var controls: some View {
        HStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textTertiary)
                TextField("Search clipboard", text: $ui.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.text)
                if !ui.query.isEmpty {
                    Button { ui.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    .buttonStyle(SparkVPressStyle())
                }
            }
            .padding(.horizontal, 6)
            .frame(width: 150, height: ClipLayout.headerHeight)
            .background(Capsule().fill(SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            .tint(SparkVTheme.red)

            HStack(spacing: 1) {
                ForEach(ClipboardFilter.allCases) { filter in
                    ClipboardIconButton(systemImage: filter.symbol, isActive: ui.filter == filter, help: filter.help) {
                        ui.filter = filter
                    }
                }
            }

            Spacer(minLength: 4)

            Text("\(clipboard.items.filter { !$0.isPinned }.count)/\(ClipboardHistory.defaultUnpinnedLimit)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.textTertiary)
                .help("Recent items kept (pinned items don't count)")
            ClipboardIconButton(systemImage: "square.stack.3d.up", help: "Open the stack at the text cursor (⌘⇧V)") {
                clipboard.showStackPanel()
            }
            ClipboardIconButton(
                systemImage: clipboard.isPaused ? "play.fill" : "pause.fill",
                isActive: clipboard.isPaused,
                help: clipboard.isPaused ? "Resume history" : "Pause history"
            ) {
                clipboard.setPaused(!clipboard.isPaused)
            }
            ClipboardMenuButton()
        }
    }
}

private struct ClipboardIconButton: View {
    let systemImage: String
    var isActive = false
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: isActive ? .bold : .semibold))
                .foregroundStyle(isActive ? SparkVTheme.activeGlyph : (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary))
                .frame(width: 20, height: ClipLayout.headerHeight)
                .background(Capsule().fill(isActive ? SparkVTheme.activeTabFill : (hover.isOn ? SparkVTheme.hoverFill : Color.clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "…" button opening the same menu as the C button (clear, settings, …).
private struct ClipboardMenuButton: View {
    @EnvironmentObject private var clipboard: ClipboardController

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(SparkVTheme.textSecondary)
            .frame(width: 20, height: ClipLayout.headerHeight)
            .background(Capsule().fill(SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            .overlay(ClipboardMenuOnClick(makeMenu: { ClipboardMenu.make(for: clipboard) }))
            .accessibilityLabel("Clipboard options")
    }
}

/// Opens a menu on a plain click.
private struct ClipboardMenuOnClick: NSViewRepresentable {
    var makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> ClipboardPressView {
        let view = ClipboardPressView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ClipboardPressView, context: Context) { configure(view) }

    private func configure(_ view: ClipboardPressView) {
        view.makeMenu = makeMenu
        view.onClick = { [weak view] _ in
            guard let view else { return }
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
        view.toolTip = "Clear, pause, settings"
    }
}

// MARK: - Well and notices

private struct ClipboardWell<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClipLayout.wellCorner, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipShape(shape)
            .background(shape.fill(SparkVTheme.surface))
            .overlay(shape.strokeBorder(SparkVTheme.stroke, lineWidth: 1))
    }
}

private struct ClipboardNotice: View {
    let symbol: String
    let title: String
    let detail: String
    var button: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(SparkVTheme.textTertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button {
                Button(action: button.1) {
                    Text(button.0)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(SparkVTheme.red))
                        .contentShape(Capsule())
                }
                .buttonStyle(SparkVPressStyle())
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card

/// One history card. AppKit (TrayDragSource) owns the mouse: click = copy,
/// double-click = paste, drag = drag out, right/control-click = menu.
/// Hovering shows pin and delete buttons in the top-trailing corner.
private struct ClipboardCard: View {
    @EnvironmentObject private var clipboard: ClipboardController
    let item: ClipboardItem
    let height: CGFloat

    @StateObject private var hover = ViewFlag()
    @StateObject private var deleteArmed = ViewFlag()

    /// Disarms the delete button after a moment, like a confirmation that times out.
    private func armDelete() {
        let flag = deleteArmed
        flag.isOn = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            flag.isOn = false
        }
    }

    private var width: CGFloat {
        switch item.kind {
        case .image: height * 1.35
        case .file: height
        case .text, .richText, .url: height * 1.4
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClipLayout.cardCorner, style: .continuous)
        let hovered = hover.isOn
        let flashed = clipboard.flashedItemID == item.id
        let smartAction = clipboard.smartActions(for: item).first
        ZStack(alignment: .topLeading) {
            artwork
                .frame(width: width, height: height)
                .clipped()
            HStack(spacing: 3) {
                // ⌘ + this number + V pastes the card from anywhere.
                if let number = stackNumber {
                    Text("\(number)")
                        .font(.system(size: 7.5, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(SparkVTheme.text)
                        .frame(width: 12, height: 12)
                        .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Color.black.opacity(0.55)))
                        .help("⌘\(number) then V pastes this from anywhere")
                }
                // Text and link cards show the pin in their footer instead.
                if item.isPinned, item.kind == .image || item.kind == .file || isColor {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(SparkVTheme.isApple ? Color.yellow : SparkVTheme.red)
                        .rotationEffect(.degrees(30))
                        .padding(2)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
            }
            .padding(4)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(hovered ? (SparkVTheme.isApple ? Color.white.opacity(0.30) : SparkVTheme.red.opacity(0.6)) : SparkVTheme.stroke, lineWidth: 1))
        .overlay {
            if flashed {
                shape.fill(Color.black.opacity(0.55))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(SparkVTheme.success))
            }
        }
        .contentShape(shape)
        .overlay(
            TrayDragSource(
                anchor: .pointer,
                toolTip: toolTip,
                payloads: { clipboard.dragPayloads(for: item) },
                onClick: { clipboard.copy(item) },
                onDoubleClick: { clipboard.paste(item) },
                menu: { makeMenu() },
                onHoverChange: { hover.isOn = $0 },
                passThroughTopTrailing: hovered || deleteArmed.isOn
                    ? (smartAction == nil ? ClipLayout.hoverButtons : ClipLayout.hoverButtonsWithAction) : .zero
            )
        )
        .overlay(alignment: .topTrailing) {
            if hovered || deleteArmed.isOn {
                HStack(spacing: 3) {
                    if let smartAction {
                        ClipboardCardButton(systemImage: smartAction.symbol, help: smartAction.title) {
                            clipboard.perform(smartAction, for: item)
                        }
                    }
                    ClipboardCardButton(systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill",
                                        help: item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
                    // Two clicks: the first arms it (turns red), the second deletes.
                    ClipboardCardButton(systemImage: deleteArmed.isOn ? "trash.fill" : "xmark",
                                        help: deleteArmed.isOn ? "Click again to delete" : "Delete",
                                        destructive: deleteArmed.isOn) {
                        if deleteArmed.isOn {
                            deleteArmed.isOn = false
                            clipboard.delete(item)
                        } else {
                            armDelete()
                        }
                    }
                }
                .padding(4)
                .transition(.opacity)
            }
        }
        .animation(SparkVMotion.hover(), value: hovered)
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.hover), value: flashed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.rawValue): \(item.displayTitle)")
        .accessibilityAddTraits(.isButton)
    }

    /// Position in the stack (1 = newest) when it's one of the first nine.
    private var stackNumber: Int? {
        guard let index = clipboard.items.firstIndex(where: { $0.id == item.id }), index < 9 else { return nil }
        return index + 1
    }

    private var smart: ClipboardSmartContent? { clipboard.smartContent(for: item) }

    private var isColor: Bool {
        if case .color? = smart { return true }
        return false
    }

    private var toolTip: String {
        switch item.kind {
        case .text, .richText, .url: return String((item.text ?? "").prefix(500))
        case .image: return item.displayTitle
        case .file: return (item.fileURLs ?? []).map(\.path).joined(separator: "\n")
        }
    }

    // MARK: Artwork

    @ViewBuilder
    private var artwork: some View {
        switch item.kind {
        case .image:
            ZStack(alignment: .bottomLeading) {
                SparkVTheme.surface
                if let image = clipboard.thumbnails[item.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer(dark: true).padding(5)
            }
        case .file:
            ZStack(alignment: .bottom) {
                SparkVTheme.surface
                if let url = item.fileURLs?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: height * 0.5, height: height * 0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -height * 0.1)
                }
                Text(item.displayTitle)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
        case .url:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SparkVTheme.red)
                    Text(item.linkHost ?? "Link")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                }
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 9))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(2)
                }
                Text(item.text ?? "")
                    .font(.system(size: 8))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(item.title == nil ? 3 : 1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                footer(dark: false)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 7)
            .padding(.top, stackNumber == nil ? 7 : 17)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(SparkVTheme.surface)
        case .text, .richText:
            if case .color(let color, _)? = smart {
                // A colour: the swatch is the card.
                ZStack(alignment: .bottomLeading) {
                    color.swiftUIColor
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? color.hex)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color.isLight ? Color.black.opacity(0.85) : Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        footer(dark: true)
                    }
                    .padding(6)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String((item.text ?? "").prefix(400)))
                        .font(smart?.isMonospaced == true
                              ? .system(size: 8.5, design: .monospaced)
                              : .system(size: 9))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(max(Int((height - 26) / 11), 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    footer(dark: false)
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 7)
                .padding(.top, stackNumber == nil ? 7 : 17)
                .frame(width: width, height: height, alignment: .topLeading)
                .background(SparkVTheme.surface)
            }
        }
    }

    /// Source app icon, rich-text badge and age.
    private func footer(dark: Bool) -> some View {
        HStack(spacing: 3) {
            if item.isPinned, !dark {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(SparkVTheme.isApple ? Color.yellow : SparkVTheme.red)
                    .rotationEffect(.degrees(30))
            }
            if let icon = clipboard.appIcon(for: item.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 10, height: 10)
            }
            if let smart, item.kind != .url {
                Image(systemName: smart.symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(ClipboardSmartBadge.tint(for: smart))
                    .help(smart.label)
            }
            if item.kind == .richText {
                Text("Aa")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .help("Formatted text")
            }
            Text(Self.age(of: item.copiedAt))
                .font(.system(size: 7.5, weight: .medium).monospacedDigit())
                .foregroundStyle(SparkVTheme.textTertiary)
        }
        .padding(.horizontal, dark ? 4 : 0)
        .padding(.vertical, dark ? 2 : 0)
        .background {
            if dark { Capsule().fill(Color.black.opacity(0.55)) }
        }
    }

    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let clipboard = clipboard
        let item = item
        menu.addItem(TrayMenuItem("Copy", systemImage: "doc.on.doc") { clipboard.copy(item) })
        menu.addItem(TrayMenuItem("Paste", systemImage: "arrow.down.doc") { clipboard.paste(item) })
        if item.kind == .richText {
            menu.addItem(TrayMenuItem("Copy as Plain Text", systemImage: "textformat") {
                clipboard.copy(item, plainText: true)
            })
            menu.addItem(TrayMenuItem("Paste as Plain Text", systemImage: "text.badge.checkmark") {
                clipboard.paste(item, plainText: true)
            })
        }
        switch item.kind {
        case .url:
            menu.addItem(TrayMenuItem("Open Link", systemImage: "safari") { clipboard.open(item) })
        case .file:
            menu.addItem(TrayMenuItem("Open", systemImage: "arrow.up.forward.app") { clipboard.open(item) })
            menu.addItem(TrayMenuItem("Show in Finder", systemImage: "folder") { clipboard.revealInFinder(item) })
        case .image:
            menu.addItem(TrayMenuItem("Open in Preview", systemImage: "photo") { clipboard.open(item) })
        case .text, .richText:
            break
        }
        // Smart actions: Open, Compose, Call via FaceTime, Copy as RGB, Reveal.
        let smartActions = clipboard.smartActions(for: item).filter { action in
            // Links already have "Open Link" above.
            !(item.kind == .url && action.title == "Open")
        }
        if !smartActions.isEmpty {
            menu.addItem(.separator())
            smartActions.forEach { menu.addItem($0.menuItem(for: item, clipboard: clipboard)) }
        }
        menu.addItem(.separator())
        menu.addItem(TrayMenuItem(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") {
            clipboard.togglePin(item)
        })
        if let bundleID = item.sourceBundleID, bundleID != Bundle.main.bundleIdentifier {
            let name = clipboard.appName(for: bundleID) ?? bundleID
            menu.addItem(TrayMenuItem("Never Record From \(name)", systemImage: "eye.slash") {
                clipboard.exclude(bundleID: bundleID)
            })
        }
        menu.addItem(.separator())
        menu.addItem(TrayMenuItem("Delete", systemImage: "trash") { clipboard.delete(item) })
        return menu
    }
}

private struct ClipboardCardButton: View {
    let systemImage: String
    let help: String
    var destructive = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(SparkVTheme.text)
                .frame(width: 18, height: 18)
                .background(Circle().fill(destructive ? SparkVTheme.destructive : Color.black.opacity(hover.isOn ? 0.85 : 0.62)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
        .accessibilityLabel(help)
    }
}
