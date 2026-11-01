import AppKit
import SwiftUI

// The Look & Layout window: Layout (drag to reorder header controls, pins
// and hub tiles), Appearance and Text & Contrast. Opened from the hub's
// Look / Customize tiles, the category bar's slider button, a tile's
// right-click menu and the gear menu. Drag reordering lives here, in a
// normal window, not in the non-activating notch panel, where a drag would
// fight the drawer's file drop and its collapse timer.

@MainActor
final class LookLayoutWindowModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case layout, appearance, textContrast
        var id: String { rawValue }
        var title: String {
            switch self {
            case .layout: "Layout"
            case .appearance: "Appearance"
            case .textContrast: "Text & Contrast"
            }
        }
    }

    @Published var page: Page = .layout
}

@MainActor
final class LookLayoutWindowController: NSObject, NSWindowDelegate {
    static let shared = LookLayoutWindowController()
    typealias Page = LookLayoutWindowModel.Page

    private var window: NSWindow?
    private let model = LookLayoutWindowModel()

    func show(page: Page = .layout) {
        model.page = page
        let window = window ?? makeWindow()
        self.window = window
        // SparkV is an agent app: become a regular app while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: LookLayoutRootView(model: model).followsAppearance())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Look & Layout — SparkV"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.setContentSize(NSSize(width: 900, height: 780))
        window.center()
        window.setFrameAutosaveName("SparkV.LookLayout")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

struct LookLayoutRootView: View {
    @ObservedObject var model: LookLayoutWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    LabsBEyebrow(SparkVTheme.isApple ? "Settings" : "SparkV / Settings")
                    Text("Look & Layout")
                        .font(SparkVTheme.Scaled.title(24))
                        .tracking(-0.4)
                        .foregroundStyle(SparkVTheme.text)
                }
                Spacer()
                Picker("Page", selection: $model.page) {
                    ForEach(LookLayoutWindowModel.Page.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 16)

            ZStack {
                switch model.page {
                case .layout:
                    LayoutEditorView().transition(.sparkVCrossfade)
                case .appearance:
                    // The same sections as Settings › Appearance.
                    LookFormPage {
                        AppearanceSettingsSection()
                        NotchThemeSettingsSection()
                    }
                    .padding(.horizontal, 12)
                    .transition(.sparkVCrossfade)
                case .textContrast:
                    // The same sections as Settings › Accessibility.
                    LookFormPage {
                        TextContrastSettingsSection()
                        AppShellAccessibilityStatusSection()
                    }
                    .padding(.horizontal, 12)
                    .transition(.sparkVCrossfade)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: model.page)
        }
        .background(LabsBWindowGround(glow: 0.6).ignoresSafeArea())
        .foregroundStyle(SparkVTheme.text)
        .tint(SparkVTheme.accent)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Layout editor

/// Two columns: the header (left of the camera, right of it, pins, the tab
/// the drawer opens on) and the Agents hub (every tile: drag to reorder,
/// check to show, pin to put it in the header).
struct LayoutEditorView: View {
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LookPanelCard("Header", subtitle: "Drag to reorder. Six controls fit beside the camera on each side.",
                             systemImage: "menubar.rectangle") {
                        VStack(alignment: .leading, spacing: 12) {
                            LookHeaderPreview(header: layout.effectiveHeader)
                            headerList(.left, title: "Left of the camera")
                            headerList(.right, title: "Right of the camera")
                            pinList
                        }
                    }
                    LookPanelCard("Drawer", systemImage: "rectangle.topthird.inset.filled") {
                        VStack(alignment: .leading, spacing: 10) {
                            LookRow("Open Drawer On") {
                                Picker("Open Drawer On", selection: $layout.openOn) {
                                    ForEach(DrawerOpenTab.allCases) { Text($0.title).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 140)
                            }
                            LookRow("Show Empty Shortcut Buttons") {
                                Toggle("Show Empty Shortcut Buttons", isOn: Binding(
                                    get: { !layout.hidesEmptyShortcuts }, set: { layout.hidesEmptyShortcuts = !$0 }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            }
                            HStack {
                                Spacer()
                                Button("Reset Header") { layout.resetHeader() }
                                    .buttonStyle(SparkVSecondaryButtonStyle())
                            }
                        }
                    }
                    LookPanelCard("Features", subtitle: "Off stops the feature completely (its hotkey and watchers too) and removes it from the header and the hub.",
                                  systemImage: "power") {
                        LookFeatureRows()
                    }
                }
                .padding(.bottom, 24)
            }
            .frame(width: 400)

            LookPanelCard("Agents Hub", subtitle: "Drag to reorder. Uncheck to hide. The pin puts a tile in the header.",
                     systemImage: "square.grid.2x2") {
                VStack(alignment: .leading, spacing: 10) {
                    hubList
                    HStack {
                        Text("\(layout.visibleHubIDs.count) of \(layout.hubArrangedIDs.count) tiles showing")
                            .font(SparkVTheme.font(10.5))
                            .foregroundStyle(SparkVTheme.textTertiary)
                        Spacer()
                        Button("Reset Hub") { layout.resetHub() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
    }

    // MARK: Header lists

    private func headerList(_ side: HeaderSide, title: String) -> some View {
        let ids = layout.header.order(side)
        let placement = layout.effectiveHeader.placement()
        let used = side == .left ? placement.left.count : placement.right.count + 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(SparkVTheme.Scaled.eyebrow(8.5))
                    .tracking(LabsBStyle.eyebrowTracking(1))
                    .foregroundStyle(SparkVTheme.textTertiary)
                Spacer()
                LookSlotMeter(used: used, capacity: HeaderCatalog.slotsPerSide, label: "Slots")
            }
            List {
                ForEach(ids, id: \.self) { id in
                    if let item = HeaderCatalog.info(id) {
                        HeaderEditorRow(item: item)
                    }
                }
                .onMove { layout.header.move(side, fromOffsets: $0, toOffset: $1) }
                if side == .right {
                    LookEditorRow(systemImage: "gearshape.fill", title: "Settings", tint: nil, movable: false) {
                        Text("Always last")
                            .font(SparkVTheme.font(10.5))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    .moveDisabled(true)
                }
            }
            .modifier(LookEditorListStyle(rows: ids.count + (side == .right ? 1 : 0)))
        }
    }

    private var pinList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PINNED TILES")
                    .font(SparkVTheme.Scaled.eyebrow(8.5))
                    .tracking(LabsBStyle.eyebrowTracking(1))
                    .foregroundStyle(SparkVTheme.textTertiary)
                Spacer()
                Text("\(layout.header.pins.count) of \(HeaderCatalog.maxPins)")
                    .font(SparkVTheme.font(10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            if layout.header.pins.isEmpty {
                LookNote(layout.header.freeSlots > 0
                         ? "No tiles pinned. Use the pin beside a tile on the right."
                         : "No room to pin: hide a header control first (each side holds six).",
                         systemImage: "pin")
            } else {
                List {
                    ForEach(layout.header.pins, id: \.self) { id in
                        if let info = HubCatalog.info(id) {
                            LookEditorRow(systemImage: info.systemImage, title: info.title, tint: info.tint, movable: true) {
                                Button {
                                    layout.unpin(id)
                                } label: {
                                    Image(systemName: "pin.slash")
                                        .font(SparkVTheme.font(11, weight: .semibold))
                                }
                                .buttonStyle(.borderless)
                                .help("Unpin \(info.title)")
                                .accessibilityLabel("Unpin \(info.title)")
                            }
                        }
                    }
                    .onMove { layout.header.movePins(fromOffsets: $0, toOffset: $1) }
                }
                .modifier(LookEditorListStyle(rows: layout.header.pins.count))
            }
        }
    }

    // MARK: Hub list

    private var hubList: some View {
        let ids = layout.hubArrangedIDs
        return List {
            ForEach(ids, id: \.self) { id in
                if let info = HubCatalog.info(id) {
                    HubEditorRow(info: info)
                }
            }
            .onMove { layout.moveTiles(fromOffsets: $0, toOffset: $1) }
        }
        .modifier(LookEditorListStyle(rows: nil))
    }
}

/// A header control in the editor: drag handle, glyph, title, show switch.
private struct HeaderEditorRow: View {
    let item: HeaderItemInfo
    @ObservedObject private var layout = LayoutSettings.shared

    @ObservedObject private var features = FeatureSwitches.shared

    var body: some View {
        let shown = !layout.header.hidden.contains(item.id)
        let featureOff = LayoutFeature.owning(headerID: item.id).map { !features.isOn($0) } ?? false
        LookEditorRow(systemImage: item.systemImage, title: item.title, tint: nil, movable: true, dimmed: !shown || featureOff) {
            if featureOff {
                Text("Feature off")
                    .font(SparkVTheme.font(10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            } else if item.canHide {
                Toggle("Show \(item.title)", isOn: Binding(
                    get: { shown },
                    set: { layout.setHeaderItem(item.id, visible: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!shown && !layout.header.canShow(item.id))
                .help(!shown && !layout.header.canShow(item.id) ? "No room: hide a control or unpin a tile first" : "")
            } else {
                Text("Always shown")
                    .font(SparkVTheme.font(10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }
}

/// A hub tile in the editor: drag handle, colored glyph, title, category,
/// pin, show checkbox.
private struct HubEditorRow: View {
    let info: HubTileInfo
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        let shown = !layout.hub.hidden.contains(info.id)
        let pinned = layout.header.pins.contains(info.id)
        LookEditorRow(systemImage: info.systemImage, title: info.title, tint: info.tint, movable: true, dimmed: !shown) {
            HStack(spacing: 10) {
                Text(info.category.title)
                    .font(SparkVTheme.font(9.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(SparkVTheme.surfaceHover))
                if info.pinnable {
                    Button {
                        if pinned { layout.unpin(info.id) } else { layout.pin(info.id) }
                    } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(SparkVTheme.font(11, weight: .semibold))
                            .foregroundStyle(pinned ? SparkVTheme.accentText : SparkVTheme.textSecondary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!pinned && !layout.header.canPinMore)
                    .help(pinned ? "Unpin from the header" : (layout.header.canPinMore ? "Pin to the header" : "The header is full"))
                    .accessibilityLabel(pinned ? "Unpin \(info.title)" : "Pin \(info.title) to the header")
                } else {
                    Color.clear.frame(width: 18, height: 1)
                }
                Toggle("Show \(info.title)", isOn: Binding(
                    get: { shown },
                    set: { $0 ? layout.showTile(info.id) : layout.hideTile(info.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                // A stand-in is the way to a hidden header control.
                .disabled(shown && !layout.canHideTile(info.id))
                .help(layout.canHideTile(info.id) ? "" : "Stands in for a hidden header control: show the control again to remove it")
            }
        }
    }
}

/// One editor row.
private struct LookEditorRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    let tint: Color?
    let movable: Bool
    var dimmed = false
    let trailing: Trailing

    init(systemImage: String, title: String, tint: Color?, movable: Bool, dimmed: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
        self.movable = movable
        self.dimmed = dimmed
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(SparkVTheme.font(10, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
                .opacity(movable ? 1 : 0)
                .accessibilityHidden(true)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(iconFill)
                .frame(width: SparkVTheme.scaledSize(22), height: SparkVTheme.scaledSize(22))
                .overlay(
                    Image(systemName: systemImage)
                        .font(SparkVTheme.font(10.5, weight: .semibold))
                        .foregroundStyle(iconGlyph)
                )
                .accessibilityHidden(true)
            Text(title)
                .font(SparkVTheme.font(12, weight: .medium))
                .foregroundStyle(dimmed ? SparkVTheme.textSecondary : SparkVTheme.text)
            Spacer(minLength: 6)
            trailing
        }
        .frame(height: LookEditorMetrics.rowHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(SparkVTheme.stroke)
        .accessibilityElement(children: .contain)
    }

    private var iconFill: AnyShapeStyle {
        if let tint, SparkVTheme.usesTileTints { return AnyShapeStyle(tint.gradient) }
        return AnyShapeStyle(SparkVTheme.surfaceHover)
    }

    private var iconGlyph: Color {
        if tint != nil, SparkVTheme.usesTileTints { return .white }
        return SparkVTheme.text
    }
}

enum LookEditorMetrics {
    /// One editor row (grows with Text Size).
    static var rowHeight: CGFloat { SparkVTheme.scaledSize(34) }
}

/// Plain dark list: no background of its own, a fixed height for short lists.
private struct LookEditorListStyle: ViewModifier {
    /// Rows to size for; nil lets the list fill the space.
    let rows: Int?

    func body(content: Content) -> some View {
        let rowHeight = LookEditorMetrics.rowHeight
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, rowHeight)
            // Rows, their separators and the list's own top and bottom inset.
            .frame(height: rows.map { CGFloat($0) * (rowHeight + 1) + 6 })
            .frame(maxHeight: rows == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
            .scrollDisabled(rows != nil)
    }
}

/// The feature switches as editor rows.
private struct LookFeatureRows: View {
    @ObservedObject private var features = FeatureSwitches.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(LayoutFeature.allCases) { feature in
                LookRow(feature.title, note: feature.detail) {
                    Toggle(feature.title, isOn: Binding(get: { features.isOn(feature) }, set: { features.set(feature, on: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
        }
    }
}

// MARK: - Gear menu

/// Layout items for a menu: `Menu("Layout") { LayoutMenuItems() }` in the
/// gear menu.
struct LayoutMenuItems: View {
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        Picker("Open Drawer On", selection: $layout.openOn) {
            ForEach(DrawerOpenTab.allCases) { Text($0.title).tag($0) }
        }
        Menu("Header Controls") {
            ForEach(HeaderCatalog.items.filter { $0.canHide && !layout.effectiveHeader.featureOff.contains($0.id) }, id: \.id) { item in
                let shown = !layout.header.hidden.contains(item.id)
                Toggle(item.title, isOn: Binding(
                    get: { shown },
                    set: { layout.setHeaderItem(item.id, visible: $0) }
                ))
                .disabled(!shown && !layout.header.canShow(item.id))
            }
            if !layout.header.pins.isEmpty {
                Divider()
                ForEach(layout.header.pins, id: \.self) { id in
                    Button("Unpin \(HubCatalog.info(id)?.title ?? id)") { layout.unpin(id) }
                }
            }
        }
        Menu("Features") {
            ForEach(LayoutFeature.allCases) { feature in
                Toggle(feature.title, isOn: Binding(
                    get: { FeatureSwitches.shared.isOn(feature) },
                    set: { FeatureSwitches.shared.set(feature, on: $0) }
                ))
            }
        }
        Toggle("Show Empty Shortcut Buttons", isOn: Binding(
            get: { !layout.hidesEmptyShortcuts }, set: { layout.hidesEmptyShortcuts = !$0 }
        ))
        Divider()
        Button("Customize Layout…") { LookLayoutWindowController.shared.show(page: .layout) }
        Button("Reset Layout") { layout.resetAll() }
    }
}
