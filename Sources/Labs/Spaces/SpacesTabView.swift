import AppKit
import SwiftUI

/// UI state for the Spaces drawer tab (instead of @State, which needs the
/// macro plugin the Command Line Tools don't ship).
@MainActor
final class SpacesTabModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published private(set) var results: [SpaceItem] = []
    @Published private(set) var isSearching = false
    /// Which chip a drag is over: "inbox" or a Space id.
    @Published var dropTarget: String?
    /// Short confirmation after a drop ("Filed to Acme").
    @Published private(set) var toast: String?

    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    var isSearchActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func targetBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.dropTarget == key },
            set: { [weak self] isOn in
                guard let self else { return }
                if isOn { self.dropTarget = key } else if self.dropTarget == key { self.dropTarget = nil }
            }
        )
    }

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let found = await SpaceStore.shared.search(text, in: nil)
            guard !Task.isCancelled, let self else { return }
            self.results = Array(found.prefix(30))
            self.isSearching = false
        }
    }
}

private enum SpacesTabLayout {
    static let headerHeight: CGFloat = 20
    static let spacing: CGFloat = 5
    static let cardWidth: CGFloat = 112
    static let compactCardWidth: CGFloat = 138
    static let resultWidth: CGFloat = 168
    static let cardSpacing: CGFloat = 6
    static let corner: CGFloat = 12
    /// Rows shorter than this (the default 115 pt drawer) use one-line cards.
    static let compactBelow: CGFloat = 60
}

/// Drawer tab (~508×114 pt): persona switcher, quick search and "Open
/// Spaces" on top; below, a horizontally scrolling row with the Inbox and
/// every top-level Space. Click a card to open the Spaces window on it; drop
/// files, links or text on a card to file them there (the Inbox lets the
/// agents decide).
struct SpacesTabView: View {
    @ObservedObject private var store = SpaceStore.shared
    @StateObject private var ui = SpacesTabModel()

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = max(proxy.size.height - SpacesTabLayout.headerHeight - SpacesTabLayout.spacing, 0)
            VStack(spacing: SpacesTabLayout.spacing) {
                SpacesTabHeader(store: store, ui: ui)
                    .frame(height: SpacesTabLayout.headerHeight)
                ZStack(alignment: .bottom) {
                    if ui.isSearchActive {
                        resultsRow(height: rowHeight)
                    } else {
                        spacesRow(height: rowHeight)
                    }
                    if let toast = ui.toast {
                        Text(toast)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SparkVTheme.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .overlay(Capsule().strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }
                }
                .frame(height: rowHeight)
                .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: ui.toast)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .padding(.vertical, 2)
    }

    // MARK: Spaces row

    private func spacesRow(height: CGFloat) -> some View {
        let counts = SpacesUI.recursiveCounts(spaces: store.spaces, items: store.items)
        let roots = SpacesSidebarOrder.sorted(store.children(of: nil), personaID: store.currentPersonaID)
        let inboxCount = store.items.filter { $0.spaceID == nil }.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SpacesTabLayout.cardSpacing) {
                SpacesTabCard(
                    title: "Inbox",
                    subtitle: inboxCount == 1 ? "1 unfiled" : "\(inboxCount) unfiled",
                    icon: "tray.full.fill",
                    color: SpacesPalette.inbox,
                    status: nil,
                    badge: store.suggestions.count,
                    isTargeted: ui.dropTarget == "inbox",
                    height: height
                ) {
                    SpacesWindowController.shared.show(spaceID: nil)
                }
                .onDrop(of: SpacesDropIngestor.acceptedTypes, isTargeted: ui.targetBinding("inbox")) { providers in
                    drop(providers, into: nil)
                }

                ForEach(roots) { space in
                    let folders = store.children(of: space.id).count
                    let count = counts[space.id] ?? 0
                    SpacesTabCard(
                        title: space.name,
                        subtitle: subtitle(count: count, folders: folders),
                        icon: space.icon,
                        color: SpacesUI.color(hex: space.color),
                        status: SpacesAgentStatus.of(space, store: store),
                        badge: 0,
                        isTargeted: ui.dropTarget == space.id.uuidString,
                        height: height
                    ) {
                        SpacesWindowController.shared.show(spaceID: space.id)
                    }
                    .onDrop(of: SpacesDropIngestor.acceptedTypes, isTargeted: ui.targetBinding(space.id.uuidString)) { providers in
                        drop(providers, into: space.id)
                    }
                    .contextMenu {
                        Button("Open") { SpacesWindowController.shared.show(spaceID: space.id) }
                        Button("Edit Agent…") { SpacesWindowController.shared.show(spaceID: space.id, tab: .agent) }
                        Button("Ask This Space…") { SpacesWindowController.shared.show(spaceID: space.id, tab: .ask) }
                    }
                }

                SpacesTabNewCard(height: height) {
                    SpacesWindowController.shared.createSpace(parentID: nil)
                }
            }
            .padding(.horizontal, 2)
            .frame(height: height)
        }
    }

    private func subtitle(count: Int, folders: Int) -> String {
        let items = count == 1 ? "1 item" : "\(count) items"
        guard folders > 0 else { return items }
        return items + " · \(folders) folder" + (folders == 1 ? "" : "s")
    }

    private func drop(_ providers: [NSItemProvider], into spaceID: UUID?) -> Bool {
        let name = spaceID.flatMap { id in store.spaces.first { $0.id == id }?.name }
        let ui = self.ui
        return SpacesDropIngestor.accept(providers, into: spaceID, store: store, onFiled: { _ in
            ui.flash(name.map { "Filed to \($0)" } ?? "Added to Inbox")
        })
    }

    // MARK: Search results

    @ViewBuilder
    private func resultsRow(height: CGFloat) -> some View {
        if ui.results.isEmpty {
            HStack(spacing: 6) {
                if ui.isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                } else {
                    Image(systemName: "magnifyingglass")
                    Text("No matches in your Spaces")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(SpacesPalette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous).fill(SpacesPalette.card))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpacesTabLayout.cardSpacing) {
                    ForEach(ui.results) { item in
                        SpacesTabResultCard(
                            item: item,
                            spacePath: SpacesUI.path(of: item.spaceID, in: store.spaces),
                            height: height
                        ) {
                            SpacesWindowController.shared.show(itemID: item.id)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .frame(height: height)
            }
        }
    }
}

// MARK: - Header

private struct SpacesTabHeader: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var ui: SpacesTabModel

    private var persona: Persona? { store.personas.first { $0.id == store.currentPersonaID } }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(store.personas) { persona in
                    Button {
                        store.currentPersonaID = persona.id
                    } label: {
                        if persona.id == store.currentPersonaID {
                            Label(persona.name, systemImage: "checkmark")
                        } else {
                            Text(persona.name)
                        }
                    }
                }
                Divider()
                Button("New Persona…") { SpacesWindowController.shared.promptNewPersona() }
            } label: {
                HStack(spacing: 4) {
                    SpacesPersonaAvatar(persona: persona, size: 15)
                    Text(persona?.name ?? "Me")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SpacesPalette.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                }
                .padding(.leading, 2)
                .padding(.trailing, 6)
                .frame(height: 20)
                .background(Capsule().fill(SparkVTheme.surface))
                .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch persona")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textTertiary)
                TextField("Search Spaces", text: $ui.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.text)
                if !ui.query.isEmpty {
                    Button { ui.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    .buttonStyle(SparkVPressStyle())
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .frame(width: 170, height: 20)
            .background(Capsule().fill(SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            .tint(SparkVTheme.red)

            Spacer(minLength: 4)

            if store.isIndexing {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Filing…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(SpacesPalette.secondaryText)
                }
                .help("The Space agents are filing new items")
            }

            Button {
                SpacesWindowController.shared.show(spaceID: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 8.5, weight: .semibold))
                    Text("Open Spaces").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(SparkVTheme.red))
                .contentShape(Capsule())
            }
            .buttonStyle(SparkVPressStyle())
            .help("Open the Spaces window")
        }
    }
}

// MARK: - Cards

private struct SpacesTabCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let status: SpacesAgentStatus?
    let badge: Int
    let isTargeted: Bool
    let height: CGFloat
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    /// The default drawer leaves ~40 pt for the row: icon beside the text.
    private var isCompact: Bool { height < SpacesTabLayout.compactBelow }

    var body: some View {
        Button(action: action) {
            Group {
                if isCompact {
                    HStack(spacing: 7) {
                        SpacesIconTile(icon: icon, color: color, size: min(24, max(16, height - 16)))
                        labels
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, badge > 0 ? 22 : 12)
                    .frame(width: SpacesTabLayout.compactCardWidth, height: height, alignment: .leading)
                    .overlay(alignment: .topTrailing) { indicator.padding(5) }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            SpacesIconTile(icon: icon, color: color, size: 26)
                            Spacer(minLength: 2)
                            indicator
                        }
                        Spacer(minLength: 4)
                        labels
                    }
                    .padding(8)
                    .frame(width: SpacesTabLayout.cardWidth, height: height, alignment: .topLeading)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous)
                    .fill(isTargeted ? targetColor.opacity(SparkVTheme.isApple ? 0.18 : 0.16) : (hover.isOn ? SpacesPalette.cardHover : SpacesPalette.card))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous)
                    .strokeBorder(isTargeted ? targetColor.opacity(0.9) : (hover.isOn ? SpacesPalette.hoverStroke : SpacesPalette.stroke),
                                  lineWidth: isTargeted ? 1.5 : 1)
            )
            .scaleEffect(isTargeted && !SparkVMotion.reduceMotion ? 1.03 : 1)
            // A drag can leave mid-grow: a spring retargets with its velocity.
            .animation(SparkVMotion.snappy, value: isTargeted)
            .contentShape(RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help("Open \(title) · drop files, links or text to file them here")
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: isCompact ? 1 : 0) {
            Text(title)
                .font(.system(size: isCompact ? 11 : 11.5, weight: .semibold))
                .foregroundStyle(SpacesPalette.primaryText)
                .lineLimit(1)
            Text(isTargeted ? "Drop to file here" : subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(isTargeted ? targetColor : SpacesPalette.secondaryText)
                .lineLimit(1)
        }
    }

    /// Drop highlight: the Space's own color in Apple (as before), red in SparkV Red.
    private var targetColor: Color { SparkVTheme.isApple ? color : SparkVTheme.red }

    @ViewBuilder
    private var indicator: some View {
        if badge > 0 {
            SpacesBadge(count: badge)
                .help("\(badge) suggestion\(badge == 1 ? "" : "s") from the agents")
        } else if let status {
            SpacesStatusDot(status: status, size: isCompact ? 5 : 6)
                .padding(.top, isCompact ? 0 : 3)
        }
    }
}

private struct SpacesTabNewCard: View {
    let height: CGFloat
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Group {
                if height < SpacesTabLayout.compactBelow {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("New Space").font(.system(size: 10, weight: .medium))
                    }
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("New Space")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
            }
            .foregroundStyle(hover.isOn ? (SparkVTheme.isApple ? SpacesPalette.primaryText : SparkVTheme.red) : SpacesPalette.secondaryText)
            .frame(width: height < SpacesTabLayout.compactBelow ? 92 : 78, height: height)
            .background(
                RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(hover.isOn ? (SparkVTheme.isApple ? Color.white.opacity(0.32) : SparkVTheme.red.opacity(0.7)) : Color.white.opacity(0.16))
            )
            .contentShape(RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help("Create a Space for an organization, client or project")
    }
}

private struct SpacesTabResultCard: View {
    let item: SpaceItem
    let spacePath: String
    let height: CGFloat
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            if height < SpacesTabLayout.compactBelow {
                HStack(spacing: 7) {
                    SpacesKindIcon(kind: item.kind, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SpacesPalette.primaryText)
                            .lineLimit(1)
                        Text(spacePath + " · " + SpacesUI.relativeDate(item.createdAt))
                            .font(.system(size: 9.5))
                            .foregroundStyle(SpacesPalette.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(width: SpacesTabLayout.resultWidth, height: height, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous)
                        .fill(hover.isOn ? SpacesPalette.cardHover : SpacesPalette.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous)
                        .strokeBorder(hover.isOn ? SpacesPalette.hoverStroke : SpacesPalette.stroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous))
            } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    SpacesKindIcon(kind: item.kind, size: 18)
                    Text(SpacesUI.label(for: item.kind))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(SpacesPalette.secondaryText)
                    Spacer(minLength: 0)
                    Text(SpacesUI.relativeDate(item.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(SpacesPalette.tertiaryText)
                }
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SpacesPalette.primaryText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Image(systemName: item.spaceID == nil ? "tray" : "square.stack.3d.up")
                        .font(.system(size: 8))
                    Text(spacePath).lineLimit(1)
                }
                .font(.system(size: 9.5))
                .foregroundStyle(SpacesPalette.secondaryText)
            }
            .padding(8)
            .frame(width: SpacesTabLayout.resultWidth, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous)
                    .fill(hover.isOn ? SpacesPalette.cardHover : SpacesPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous)
                    .strokeBorder(hover.isOn ? SpacesPalette.hoverStroke : SpacesPalette.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: SpacesTabLayout.corner, style: .continuous))
            }
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }
}
