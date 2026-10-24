import SwiftUI

/// Compact search for the Agents hub drawer: the same box, mic and Ask,
/// with as many results as fit (two in the default 508×75 pt drawer of a
/// 16-inch MacBook Pro, four in a 160 pt tall drawer). ↩ opens, ↑↓ move,
/// the expand button (or ⌥Space) opens the full panel with the same query.
struct UniversalSearchDrawerView: View {
    @ObservedObject var controller: UniversalSearchController

    static let searchRowHeight: CGFloat = 26
    static let spacing: CGFloat = 5
    static let rowHeight: CGFloat = 19

    /// Result rows that fit under the search row in `height` points.
    static func rowCount(for height: CGFloat) -> Int {
        let free = height - searchRowHeight - spacing
        return max(1, min(6, Int((free + 0.5) / rowHeight)))
    }

    var body: some View {
        GeometryReader { geo in
            content(rows: Self.rowCount(for: geo.size.height))
        }
        .environment(\.colorScheme, .dark)
        .onAppear { controller.setDrawerVisible(true) }
        .onDisappear { controller.setDrawerVisible(false) }
    }

    private func content(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: controller.mode == .ask ? "sparkles" : "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UniversalSearchPalette.secondary)
                    UniversalSearchField(controller: controller, fontSize: 12.5, placeholder: "Search Spaces, meetings, Flow, clipboard, Tray",
                                         inDrawer: true)
                        .frame(height: 18)
                    if !controller.query.isEmpty {
                        Button {
                            controller.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(UniversalSearchPalette.tertiary)
                        }
                        .buttonStyle(SparkVPressStyle())
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: Self.searchRowHeight)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                .tint(SparkVTheme.red)

                UniversalSearchMicButton(controller: controller, size: 26)
                UniversalSearchDrawerButton(symbol: "sparkles", help: "Ask about your results (Tab)") {
                    controller.askInPanel()
                }
                UniversalSearchDrawerButton(symbol: "arrow.up.left.and.arrow.down.right",
                                            help: "Open the search panel (\(controller.shortcut.displayString))") {
                    controller.openPanel(query: controller.query)
                }
            }

            if controller.flat.isEmpty || controller.mode == .ask {
                hint
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleRows(rows)) { r in
                        UniversalSearchRow(result: r, isSelected: controller.selectedID == r.id, compact: true)
                            .frame(height: Self.rowHeight)
                            .onTapGesture(count: 2) { controller.activate(r) }
                            .onTapGesture { controller.select(r.id) }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let toast = controller.toast {
                        Text(toast)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SparkVTheme.text)
                            .padding(.horizontal, 8)
                            .frame(height: Self.rowHeight - 2)
                            .background(Capsule().fill(SparkVTheme.red))
                            .padding(.top, 1)
                            .transition(.opacity)
                    }
                }
                .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: controller.toast)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// `count` rows around the selection.
    private func visibleRows(_ count: Int) -> [UniversalSearchResult] {
        let list = controller.flat
        let i = list.firstIndex { $0.id == controller.selectedID } ?? 0
        let start = max(0, min(i - 1, list.count - count))
        return Array(list[start..<min(list.count, start + count)])
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let toast = controller.toast {
                Text(toast)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
            } else if controller.isDictating {
                Text("Listening… tap the mic to finish")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
            } else if controller.mode == .ask {
                Text("Answering in the search panel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
            } else if controller.query.isEmpty {
                Text("One box for everything you’ve saved, said and copied.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
            } else {
                Text("No matches · ↩ asks instead")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            HStack(spacing: 5) {
                UniversalSearchKeyCap(text: controller.shortcut.displayString)
                Text("anywhere · ⇥ Ask · in:meetings, date:week")
                    .font(.system(size: 10))
                    .foregroundStyle(UniversalSearchPalette.tertiary)
            }
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }
}

private struct UniversalSearchDrawerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover.isOn ? (SparkVTheme.isApple ? SparkVTheme.text : SparkVTheme.red) : UniversalSearchPalette.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover.isOn ? (SparkVTheme.isApple ? SparkVTheme.surfaceHover : SparkVTheme.redSoft) : SparkVTheme.surface))
                .overlay(Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Search" submenu for the gear menu.
struct UniversalSearchSettingsMenu: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        Menu("Search") {
            Button("Open Search…  \(controller.shortcut.displayString)") { controller.openPanel() }
            Toggle("Global Shortcut", isOn: $controller.hotkeyEnabled)
            if controller.hotkeyEnabled, !controller.hotkeyRegistered {
                Text("\(controller.shortcut.displayString) is used by another app")
            }
            Picker("Shortcut", selection: Binding(
                get: { controller.shortcut.displayString },
                set: { name in
                    if let s = UniversalSearchController.shortcutPresets.first(where: { $0.displayString == name }) {
                        controller.setShortcut(s)
                    }
                }
            )) {
                ForEach(UniversalSearchController.shortcutPresets, id: \.displayString) { s in
                    Text(s.displayString).tag(s.displayString)
                }
                if !UniversalSearchController.shortcutPresets.contains(controller.shortcut) {
                    Text(controller.shortcut.displayString).tag(controller.shortcut.displayString)
                }
            }
            Button("Record Shortcut…") { controller.beginShortcutRecording() }
            Divider()
            ForEach(UniversalSearchSource.allCases) { source in
                Toggle("Search \(source.title)", isOn: Binding(
                    get: { controller.enabledSources.contains(source) },
                    set: { controller.setSourceEnabled(source, $0) }
                ))
            }
            Divider()
            Toggle("Allow Ask to Use My Groq Key", isOn: $controller.allowGroq)
            Button("Clear Search History") { controller.clearHistory() }
        }
    }
}
