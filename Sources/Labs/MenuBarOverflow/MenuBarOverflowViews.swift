import AppKit
import SwiftUI

// MARK: - Drawer tab

/// The page's size: the drawer gives it `contentHeight` under the header
/// band (`NotchMetrics.menuBarExpandedHeight`).
enum MenuBarOverflowMetrics {
    static let tileHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 4
    static let gridPadding: CGFloat = 6
    static let headerHeight: CGFloat = 24
    static let spacing: CGFloat = 6
    static let verticalPadding: CGFloat = 2
    /// Header, spacing and a well of two rows of tiles (+2 pt of air).
    static var contentHeight: CGFloat {
        verticalPadding * 2 + headerHeight + spacing
            + (tileHeight * 2 + rowSpacing + gridPadding * 2) + 2
    }
}

/// The Menu Bar drawer tab (508 x `MenuBarOverflowMetrics.contentHeight`):
/// the icons the notch hides, two rows that scroll sideways. Click one to
/// open its menu; right-click for its app.
struct MenuBarOverflowDrawerView: View {
    @ObservedObject private var controller = MenuBarOverflowController.shared
    @StateObject private var appeared = ViewFlag()
    /// Opened with ⌃⌥B: tiles are there at once, no staggered entrance.
    @StateObject private var instant = ViewFlag()

    var body: some View {
        VStack(spacing: MenuBarOverflowMetrics.spacing) {
            header
                .frame(height: MenuBarOverflowMetrics.headerHeight)
            ExtrasWell { content }
        }
        .padding(.vertical, MenuBarOverflowMetrics.verticalPadding)
        .onAppear {
            instant.isOn = controller.takeKeyboardOpen()
            appeared.isOn = true
            controller.beginViewing()
        }
        .onDisappear {
            appeared.isOn = false
            instant.isOn = false
            controller.endViewing()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The dash and capitals are SparkV Red's; Apple shows plain text.
            StatusEyebrow(text: "Menu Bar")
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            // Without Accessibility there is nothing to list either way.
            if !controller.needsAccessibility {
                ExtrasSegmented(options: [(false, "Hidden"), (true, "All")], selection: $controller.showsAll, label: "Show", compact: true)
                    .frame(width: 120)
            }
            if controller.dividerEnabled {
                ExtrasIconButton(systemImage: controller.isDividerCollapsed ? "chevron.compact.right" : "chevron.compact.left",
                                 label: controller.isDividerCollapsed ? "Show icons left of the divider" : "Hide icons left of the divider") {
                    controller.setCollapsed(!controller.isDividerCollapsed)
                }
            }
            ExtrasIconButton(systemImage: "arrow.clockwise", label: "Refresh") { controller.refresh() }
        }
    }

    private var summary: String {
        if controller.needsAccessibility { return "Needs Accessibility" }
        if controller.lastScan == nil { return "Looking…" }
        let hidden = controller.hiddenItems.count
        if hidden == 0 { return "Nothing hidden by the notch" }
        return hidden == 1 ? "1 icon hidden by the notch" : "\(hidden) icons hidden by the notch"
    }

    @ViewBuilder
    private var content: some View {
        if controller.needsAccessibility {
            ExtrasNotice(symbol: "hand.raised.fill",
                         title: "Allow Accessibility to reach menu bar icons",
                         detail: "SparkV reads each app's menu bar extras and presses the one you click. It never moves or hides them.",
                         action: ("Allow…", { controller.requestAccessibility() }))
        } else if controller.shownItems.isEmpty {
            ExtrasNotice(symbol: "menubar.rectangle",
                         title: controller.lastScan == nil ? "Reading the menu bar…" : "Every icon fits",
                         detail: controller.items.isEmpty ? "No menu bar extras were found." : "The notch isn't hiding any menu bar icons right now. Switch to All to reach any of them from here.")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                let row = GridItem(.fixed(MenuBarOverflowMetrics.tileHeight), spacing: MenuBarOverflowMetrics.rowSpacing)
                LazyHGrid(rows: [row, row], spacing: MenuBarOverflowMetrics.rowSpacing) {
                    ForEach(Array(controller.shownItems.enumerated()), id: \.element.id) { index, item in
                        MenuBarExtraTile(item: item, icon: controller.icons[item.id] ?? controller.appIcon(item)) {
                            controller.press(item)
                        }
                        .contextMenu {
                            Button("Open Menu") { controller.press(item) }
                            Button("Bring \(item.appName) to Front") { controller.openApp(item) }
                        }
                        .modifier(MenuBarTileEntrance(shown: appeared.isOn, instant: instant.isOn, index: index / 2))
                    }
                }
                .padding(MenuBarOverflowMetrics.gridPadding)
            }
        }
    }
}

/// The tiles' staggered fade-in, skipped when the page opened from the
/// keyboard (keyboard-triggered UI appears at once).
private struct MenuBarTileEntrance: ViewModifier {
    let shown: Bool
    let instant: Bool
    let index: Int

    func body(content: Content) -> some View {
        if instant {
            content
        } else {
            content.sparkVStaggeredEntrance(shown, index: index)
        }
    }
}

struct MenuBarExtraTile: View {
    let item: MenuBarExtraItem
    let icon: NSImage?
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                glyph
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    Text(item.isHidden ? "Under the notch" : item.appName)
                        .font(.system(size: 9))
                        .foregroundStyle(item.isHidden ? SparkVTheme.warning.opacity(0.9) : SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: 150, height: MenuBarOverflowMetrics.tileHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hover.isOn ? SparkVTheme.surfaceHover : Color.white.opacity(SparkVTheme.isApple ? 0.05 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hover.isOn && !SparkVTheme.isApple ? SparkVTheme.red.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help("Open \(item.displayName)")
        .accessibilityLabel("\(item.displayName), \(item.appName)\(item.isHidden ? ", hidden by the notch" : "")")
        .accessibilityHint("Opens its menu")
    }

    @ViewBuilder
    private var glyph: some View {
        if item.isSystem, let symbol = MenuBarNaming.symbol(for: item.label, isSystem: true) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.text.opacity(0.9))
        } else if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: MenuBarNaming.symbol(for: item.label, isSystem: false) ?? "app.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
        }
    }
}

// MARK: - Hub tile, menu, settings

/// System category. The badge counts icons the notch hides (last check).
struct MenuBarOverflowHubTile: View {
    @ObservedObject private var controller = MenuBarOverflowController.shared
    /// Inside the hub: switch tabs with the hub's own animation.
    var onOpen: (() -> Void)? = nil
    /// Its id in the Agents hub: adds the hub's Pin / Hide / Move items.
    var hubID: String? = nil

    var body: some View {
        let hidden = controller.hiddenItems.count
        ExtrasHubTileFace(
            title: "Menu Bar",
            systemImage: "menubar.dock.rectangle",
            tint: Color(white: 0.8),
            isActive: false,
            badge: hidden > 0 ? "\(hidden)" : nil,
            badgeTint: SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red),
            help: "Menu bar icons hidden by the notch (\(MenuBarOverflowController.shortcut.displayString))"
        ) {
            if let onOpen { onOpen() } else { controller.onOpenDrawer?() }
        }
        .contextMenu {
            MenuBarOverflowMenuItems()
            ExtrasHubMenuTail(hubID: hubID)
        }
    }
}

/// `Menu("Menu Bar Icons") { MenuBarOverflowMenuItems() }`: the hidden
/// icons (from the last check), each one opens its menu.
struct MenuBarOverflowMenuItems: View {
    @ObservedObject private var controller = MenuBarOverflowController.shared

    var body: some View {
        if controller.needsAccessibility {
            Button("Allow Accessibility…") { controller.requestAccessibility() }
        } else if controller.hiddenItems.isEmpty {
            Text(controller.lastScan == nil ? "Open the Menu Bar page to check" : "Nothing hidden by the notch")
        } else {
            ForEach(controller.hiddenItems) { item in
                Button(item.displayName == item.appName ? item.appName : "\(item.displayName) (\(item.appName))") { controller.press(item) }
            }
        }
        Divider()
        Button("Show Menu Bar Page  \(MenuBarOverflowController.shortcut.displayString)") { controller.onOpenDrawer?() }
        Toggle("Divider in the Menu Bar", isOn: $controller.dividerEnabled)
        if controller.dividerEnabled {
            Button(controller.isDividerCollapsed ? "Show Icons Left of the Divider" : "Hide Icons Left of the Divider") {
                controller.setCollapsed(!controller.isDividerCollapsed)
            }
        }
    }
}

/// System pane.
struct MenuBarOverflowSettingsSection: View {
    @ObservedObject private var controller = MenuBarOverflowController.shared

    var body: some View {
        ExtrasSettingsCard(title: "Menu Bar Icons Behind the Notch",
                           subtitle: "When there are more menu bar icons than fit beside the notch, macOS hides some. SparkV lists them in the drawer and opens them for you.",
                           systemImage: "menubar.dock.rectangle") {
            VStack(alignment: .leading, spacing: 2) {
                if !PermissionCenter.shared.isGranted(.accessibility) {
                    HStack(spacing: 8) {
                        ExtrasNote(text: "Needs Accessibility to read and press menu bar icons.", systemImage: "hand.raised")
                        Spacer()
                        Button("Allow…") { controller.requestAccessibility() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                    .padding(.trailing, 8)
                }
                ExtrasToggleRow(title: "Open with \(MenuBarOverflowController.shortcut.displayString)",
                                detail: controller.hotkeyUnavailable ? "Another app already uses \(MenuBarOverflowController.shortcut.displayString)." : "Opens the island on the Menu Bar page.",
                                isOn: $controller.hotkeyEnabled)
                ExtrasToggleRow(title: "Show Real Icons",
                                detail: "Captures each icon from the screen, so it needs Screen Recording. Off: app icons and system symbols.",
                                isOn: Binding(get: { controller.showsRealIcons }, set: { on in
                                    controller.showsRealIcons = on
                                    if on, !PermissionCenter.shared.isGranted(.screenRecording) { controller.requestScreenRecording() }
                                }))
                ExtrasDivider()
                ExtrasToggleRow(title: "Divider in the Menu Bar",
                                detail: "Adds a divider and a chevron. ⌘-drag icons to the left of the divider; the chevron hides or shows them. Turn off to remove both.",
                                isOn: $controller.dividerEnabled)
                ExtrasNote(text: "SparkV doesn't reorder icons (that needs synthetic ⌘-drags). On macOS 26 and later, System Settings › Menu Bar can also hide icons for good.",
                           systemImage: "info.circle")
            }
        }
    }
}
