import AppKit
import SwiftUI

// Settings sections (no arguments; they use the shared settings objects).
// Each is a set of `Section`s for the Settings window's grouped `Form`; the
// Look & Layout window hosts the same sections in a grouped Form of its own.
//
// - `AppearanceSettingsSection`   → Settings › Appearance (replaces AppShellLookSettingsSection)
// - `TextContrastSettingsSection` → Settings › Accessibility (above AppShellAccessibilityStatusSection,
//                                   which keeps the live system switches)
// - `LayoutSettingsSection`       → Settings › Island
// - `LayoutFeaturesSettingsSection` → Settings › Island (below LayoutSettingsSection)

/// A grouped-form footer line.
struct LookFormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary)
    }
}

/// Hosts settings sections the way the Settings window does (a grouped
/// Form), for the Look & Layout window.
struct LookFormPage<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .tint(SparkVTheme.accent)
    }
}

// MARK: - Appearance

/// Look, accent color, drawer material (Liquid Glass), decorative glows and
/// the resting island's opacity.
struct AppearanceSettingsSection: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(AppearanceStyle.allCases) { style in
                    LookStyleCard(style: style, isSelected: appearance.style == style) {
                        appearance.style = style
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Look")
        } footer: {
            LookFormFooter("Apple is the native macOS look; SparkV Red is the brand look with one signal red. Applies everywhere at once.")
        }

        Section {
            HStack(spacing: 2) {
                LookAccentSwatch(
                    color: appearance.style == .apple ? Color.accentColor : SparkVTheme.brandRed,
                    title: appearance.style == .apple ? "Look Default (macOS accent)" : "Look Default (signal red)",
                    isSelected: appearance.accent == .lookDefault,
                    split: appearance.style == .apple ? SparkVTheme.brandRed : Color.accentColor
                ) { appearance.accent = .lookDefault }
                ForEach(AccentChoice.swatches) { choice in
                    LookAccentSwatch(color: choice.rgb?.color ?? .accentColor, title: choice.title,
                                     isSelected: appearance.accent == choice) {
                        appearance.accent = choice
                    }
                }
                LookCustomAccentSwatch()
                Spacer(minLength: 0)
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Button("Sample Button") {}
                        .buttonStyle(SparkVPrimaryButtonStyle())
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Toggle("", isOn: .constant(true))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .accessibilityLabel("On")
                }
            } label: {
                Text(accentSummary)
            }
        } header: {
            Text("Accent Color")
        } footer: {
            LookFormFooter("Buttons, switches, selection and links. Recording and delete stay red; text in the accent is lightened where it would read below 4.5:1.")
        }

        Section {
            Picker(selection: $appearance.drawerMaterial) {
                Text("Black").tag(DrawerMaterial.black)
                Text("Liquid Glass").tag(DrawerMaterial.liquidGlass)
            } label: {
                Text("Drawer")
                Text(drawerNote)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $appearance.decorativeGlows) {
                Text("Decorative Glows")
                Text("Album Glow behind Home, the notch hover themes and the SparkV Red window glow. Ambient Light keeps its own switch.")
            }
            Picker(selection: $appearance.restingOpacity) {
                Text("Solid").tag(RestingOpacity.solid)
                Text("85 %").tag(RestingOpacity.soft)
                Text("60 %").tag(RestingOpacity.faint)
            } label: {
                Text("Island at Rest")
                Text(restingNote)
            }
            .pickerStyle(.segmented)
            LabeledContent("Defaults") {
                Button("Reset Appearance") { appearance.resetToDefaults() }
            }
        } header: {
            Text("Island & Drawer")
        }
    }

    private var accentSummary: String {
        switch appearance.accent {
        case .lookDefault: appearance.style == .apple ? "Follows your macOS accent color." : "Signal red, the SparkV brand."
        case .custom: "Custom \(appearance.customAccent.hex)."
        default: appearance.accent.title + "."
        }
    }

    private var drawerNote: String {
        if appearance.display.reduceTransparency {
            return "Reduce Transparency is on, so the drawer stays black."
        }
        let glass = AppearanceSettings.supportsLiquidGlass ? "Liquid Glass" : "A frosted material (Liquid Glass needs macOS 26)"
        return "\(glass) behind the open drawer; the band beside the camera and the closed island stay black."
    }

    private var restingNote: String {
        LookIsland.isOnNotch
            ? "Only on displays without a camera notch; the island is on a notch now, so it stays solid."
            : "When nothing is showing, on displays without a camera notch. Never with Reduce Transparency."
    }
}

/// A look preview card: a mini island over a desktop with three tiles.
private struct LookStyleCard: View {
    let style: AppearanceStyle
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                HStack(spacing: 6) {
                    Text(style == .apple ? "Apple" : "SparkV Red")
                        .font(SparkVTheme.font(12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                    if style == .apple {
                        Text("Default")
                            .font(SparkVTheme.font(9.5, weight: .medium))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(SparkVTheme.surfaceHover))
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(SparkVTheme.font(13, weight: .semibold))
                            .foregroundStyle(Color.white, SparkVTheme.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(8)
            .background(shape.fill(isSelected ? SparkVTheme.surfaceHover : (hover.isOn ? SparkVTheme.surface : Color.clear)))
            .overlay(shape.strokeBorder(isSelected ? SparkVTheme.accent : SparkVTheme.stroke, lineWidth: isSelected ? 2 : 1))
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(shape)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(style == .apple ? "Apple look" : "SparkV Red look")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var preview: some View {
        let apple = style == .apple
        let tints: [Color] = [.indigo, .orange, .cyan, .pink]
        let symbols = ["magnifyingglass", "tray.full.fill", "viewfinder", "doc.on.clipboard"]
        return ZStack(alignment: .top) {
            LinearGradient(colors: apple ? [Color(red: 0.20, green: 0.32, blue: 0.62), Color(red: 0.55, green: 0.30, blue: 0.62)]
                                         : [Color(white: 0.10), Color(red: 0.16, green: 0.03, blue: 0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Image(systemName: ["house.fill", "tray.full.fill", "calendar"][index])
                            .font(.system(size: 6.5, weight: .semibold))
                            .foregroundStyle(index == 0 ? (apple ? Color.white : SparkVTheme.brandRed) : Color.white.opacity(0.5))
                            .frame(width: 13, height: 10)
                            .background(Capsule().fill(index == 0 ? (apple ? Color.white.opacity(0.18) : SparkVTheme.brandRed.opacity(0.18)) : .clear))
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(apple ? Color.white.opacity(0.09) : Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(apple ? Color.clear : Color.white.opacity(0.10), lineWidth: 0.5))
                            .overlay(Image(systemName: symbols[index]).font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(apple ? tints[index] : (index == 1 ? SparkVTheme.brandRed : Color.white.opacity(0.85))))
                            .frame(height: 20)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 5)
            .padding(.bottom, 8)
            .frame(width: 120)
            .background(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 12, bottomTrailing: 12, topTrailing: 0),
                                               style: .continuous).fill(Color.black))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Text size & contrast

/// Text Size and SparkV's contrast boost. The live state of the system's
/// Increase Contrast and Reduce Transparency switches is in
/// AppShellAccessibilityStatusSection, right below it.
struct TextContrastSettingsSection: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Section {
            Picker("Text Size", selection: $appearance.textSize) {
                ForEach(TextSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            LookTextSizePreview(zoom: appearance.textSize.factor)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Text Size")
        } footer: {
            LookFormFooter(textSizeNote)
        }

        Section {
            Picker(selection: $appearance.contrast) {
                ForEach(ContrastPreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            } label: {
                Text("Higher Contrast")
                Text("Brighter secondary text and outlines, a visible active-tab outline, darker button fills.")
            }
            .pickerStyle(.segmented)
            LabeledContent("In Effect") {
                Text(effectSummary).foregroundStyle(SparkVTheme.textSecondary)
            }
        } header: {
            Text("Contrast")
        } footer: {
            LookFormFooter("Follow System uses System Settings › Accessibility › Display › Increase Contrast as it changes. Reduce Transparency turns Liquid Glass, Album Glow and window vibrancy solid.")
        }
    }

    private var effectSummary: String {
        let options = appearance.options
        var parts = [options.highContrast ? "Higher contrast" : "Standard contrast"]
        if options.reduceTransparency { parts.append("solid backgrounds") }
        return parts.joined(separator: ", ")
    }

    private var textSizeNote: String {
        let factor = appearance.textSize.factor
        let growth = factor == 1
            ? "Standard is the drawer as designed. Large and Larger grow its content and controls by 12 % and 25 %"
            : "The open drawer's content and controls are \(Int(((factor - 1) * 100).rounded())) % larger"
        return growth + "; the drawer gets wider and taller to fit, while the header beside the camera and the closed island keep their size. Its smallest captions grow with it; SparkV's windows draw nothing under 10 pt above Standard."
    }

    /// System Settings › Accessibility › Display (a local settings link).
    static func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A slice of the drawer at `zoom`, drawn through the same zoom the drawer
/// uses: what Text Size does, at a glance.
private struct LookTextSizePreview: View {
    let zoom: CGFloat

    var body: some View {
        let natural = CGSize(width: 300, height: 58)
        LookDrawerZoom(zoom: zoom) {
            HStack(spacing: 6) {
                ForEach(Array(sample.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 4) {
                        Image(systemName: item.0)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SparkVTheme.usesTileTints ? item.2 : SparkVTheme.text.opacity(0.88))
                        Text(item.1)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                }
            }
            .padding(7)
            .frame(width: natural.width, height: natural.height)
        }
        .frame(width: natural.width * zoom, height: natural.height * zoom, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12 * zoom, style: .continuous).fill(Color.black))
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: zoom)
        .accessibilityLabel("Preview of the drawer at this text size")
    }

    private var sample: [(String, String, Color)] {
        [("magnifyingglass", "Search", .indigo), ("tray.full.fill", "Tray", .blue),
         ("text.viewfinder", "Copy Text", .green), ("arrowshape.turn.up.left.fill", "Reply", .cyan),
         ("doc.on.clipboard", "Clipboard", .pink)]
    }
}

// MARK: - Layout

/// The drawer's layout: the tab it opens on, empty shortcut buttons, the
/// header at a glance and the way to the full editor.
struct LayoutSettingsSection: View {
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        Section {
            Picker(selection: $layout.openOn) {
                ForEach(DrawerOpenTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            } label: {
                Text("Open Drawer On")
                Text("A live activity's own page (a meeting, a timer) still opens first.")
            }
            Toggle(isOn: Binding(get: { !layout.hidesEmptyShortcuts }, set: { layout.hidesEmptyShortcuts = !$0 })) {
                Text("Show Empty Shortcut Buttons")
                Text("Off hides Home's shortcut buttons that have nothing assigned (right-click the column to add one).")
            }
        } header: {
            Text("Drawer")
        }

        Section {
            LookHeaderPreview(header: layout.effectiveHeader)
                .padding(.vertical, 2)
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Reset Layout") { layout.resetAll() }
                    Button("Customize Layout…") { LookLayoutWindowController.shared.show(page: .layout) }
                        .keyboardShortcut(.defaultAction)
                }
            } label: {
                Text(summary)
                Text("Drag to reorder header controls and hub tiles, hide them or pin tiles to the header.")
            }
        } header: {
            Text("Header & Agents Hub")
        } footer: {
            LookFormFooter("Six controls fit on each side of the camera. A hidden control keeps running and becomes a tile in the Agents hub.")
        }
    }

    private var summary: String {
        let hidden = layout.hubArrangedIDs.filter { layout.hub.hidden.contains($0) }.count
        let pins = layout.header.pins.count
        var parts = ["\(layout.visibleHubIDs.count) hub tiles"]
        if hidden > 0 { parts.append("\(hidden) hidden") }
        if pins > 0 { parts.append("\(pins) pinned") }
        return parts.joined(separator: ", ")
    }
}

/// One switch per feature that can be turned off as a whole: off stops its
/// controller (hotkeys, monitors, watchers) and removes it from the header
/// and the hub.
struct LayoutFeaturesSettingsSection: View {
    @ObservedObject private var features = FeatureSwitches.shared

    var body: some View {
        Section {
            ForEach(LayoutFeature.allCases) { feature in
                Toggle(isOn: Binding(get: { features.isOn(feature) }, set: { features.set(feature, on: $0) })) {
                    Label {
                        Text(feature.title)
                        Text(feature.detail)
                    } icon: {
                        Image(systemName: feature.systemImage)
                    }
                }
            }
        } header: {
            Text("Features")
        } footer: {
            LookFormFooter("Off saves energy: the feature stops completely until you turn it back on. To only tidy the header, hide its control instead.")
        }
    }
}

/// Every header control as a chip: click to hide or show it.
struct LookHeaderChips: View {
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([HeaderSide.left, .right], id: \.self) { side in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(side == .left ? "LEFT" : "RIGHT")
                        .font(SparkVTheme.Scaled.eyebrow(8.5))
                        .tracking(LabsBStyle.eyebrowTracking(1))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .frame(width: 38, alignment: .leading)
                    LookFlow(spacing: 6) {
                        ForEach(layout.header.order(side), id: \.self) { id in
                            if let item = HeaderCatalog.info(id) {
                                let shown = !layout.header.hidden.contains(id)
                                LookToggleChip(
                                    title: item.title, systemImage: item.systemImage, isOn: shown,
                                    isEnabled: item.canHide && (shown || layout.header.canShow(id)),
                                    help: !item.canHide ? "\(item.title) always shows: it leads to everything you hide."
                                        : (shown ? "Hide \(item.title) from the header" : (layout.header.canShow(id) ? "Show \(item.title) in the header" : "No room: hide a control or unpin a tile first"))
                                ) {
                                    layout.setHeaderItem(id, visible: !shown)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Pinned hub tiles with an unpin button each.
struct LookPinnedChips: View {
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("PINNED")
                .font(SparkVTheme.Scaled.eyebrow(8.5))
                .tracking(LabsBStyle.eyebrowTracking(1))
                .foregroundStyle(SparkVTheme.textTertiary)
                .frame(width: 38, alignment: .leading)
            LookFlow(spacing: 6) {
                ForEach(layout.header.pins, id: \.self) { id in
                    if let info = HubCatalog.info(id) {
                        LookToggleChip(title: info.title, systemImage: info.systemImage, tint: info.tint, isOn: true,
                                       trailingSymbol: "xmark", help: "Unpin \(info.title)") {
                            layout.unpin(id)
                        }
                    }
                }
            }
        }
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct LookFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
