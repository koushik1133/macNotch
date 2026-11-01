import SwiftUI

// Settings sections (no arguments; Settings window panes noted on each),
// the gear-menu items and the Agents hub tile for the volume and
// brightness HUD.

// Every section is a `Section { … }` for the Settings window's grouped Form
// (Labs/AppShell hosts them; see INTEGRATION.md for the panes).

/// A row title with an explanation under it, as Form rows show them.
private struct HUDRowLabel: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        Text(title)
        if let detail { Text(detail) }
    }
}

// MARK: - HUD (System pane)

/// Settings window › System: the HUD's switches, key steps, percentage,
/// interactivity and the keyboard backlight's status.
struct HUDSettingsSection: View {
    var body: some View {
        if let hud = HUDController.current {
            HUDSettingsContent(hud: hud)
        } else {
            Section {
                Text("The HUD starts with SparkV's island.")
                    .foregroundStyle(SparkVTheme.textSecondary)
            } header: {
                Text("Volume & Brightness")
            }
        }
    }
}

private struct HUDSettingsContent: View {
    @ObservedObject var hud: HUDController
    @ObservedObject private var settings = HUDPlusSettings.shared
    @ObservedObject private var permissions = PermissionCenter.shared

    var body: some View {
        let granted = permissions.isGranted(.accessibility)
        Section {
            Toggle(isOn: $hud.isEnabled) {
                HUDRowLabel(title: "Show the HUD", detail: "When the volume, output or brightness changes.")
            }
            Toggle(isOn: $hud.replacesSystemHUD) {
                HUDRowLabel(
                    title: "Hide the macOS pop-up",
                    detail: granted
                        ? "SparkV applies the keys itself. Keys it can't apply (DDC monitors with a display tool, outputs without a volume control, displays set to Off) still reach macOS."
                        : "Needs Accessibility, so SparkV can catch the volume and brightness keys."
                )
            }
            .disabled(!hud.isEnabled)
            if hud.isEnabled, hud.replacesSystemHUD, !granted {
                LabeledContent {
                    Button("Allow…") {
                        Task { _ = await PermissionCenter.shared.request(.accessibility, from: "Volume & Brightness HUD") }
                    }
                } label: {
                    HUDRowLabel(title: "Accessibility", detail: "Until it's allowed, macOS keeps showing its own pop-up.")
                }
            }
            Toggle(isOn: $settings.showsPercent) {
                HUDRowLabel(title: "Show percentage", detail: "The level as a number beside the bar or ring.")
            }
            Toggle(isOn: $settings.isInteractive) {
                HUDRowLabel(
                    title: "Drag, scroll or click the HUD",
                    detail: "Beside or under the notch: click the speaker to mute, drag or scroll the level. It stays while the pointer is on it. Hovering the camera still opens the drawer."
                )
            }
            Picker(selection: $settings.stepDivisions) {
                ForEach(HUDStepMath.divisionChoices, id: \.self) { Text("\($0) steps").tag($0) }
            } label: {
                HUDRowLabel(
                    title: "Key steps",
                    detail: "From 0 to 100% (macOS uses 16). Option-Shift gives quarter steps. Used while SparkV hides the macOS pop-up."
                )
            }
            .disabled(!hud.isEnabled || !hud.replacesSystemHUD)
            HUDKeyboardBacklightRow()
        } header: {
            Text("Volume & Brightness")
        }
    }
}

/// Read only: macOS has no public API for the keyboard backlight's level.
private struct HUDKeyboardBacklightRow: View {
    var body: some View {
        let present = HUDKeyboardBacklight.isPresent
        LabeledContent {
            if present {
                Button("Keyboard Settings…") { HUDKeyboardBacklight.openKeyboardSettings() }
            } else {
                Text("None")
            }
        } label: {
            HUDRowLabel(
                title: "Keyboard backlight",
                detail: present
                    ? "Not shown in SparkV's HUD: macOS has no public way to read or set its level, so its keys and Control Center keep their own pop-up."
                    : "This Mac has none. Backlight keys always go to macOS."
            )
        }
    }
}

// MARK: - Style (Appearance pane)

/// Settings window › Appearance: how the HUD looks on the island's display
/// and on the others, with a live preview.
struct HUDStyleSettingsSection: View {
    @ObservedObject private var settings = HUDPlusSettings.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(HUDStyle.islandChoices) { style in
                        HUDStyleCard(style: style, isSelected: settings.style == style, edge: settings.edge) {
                            settings.style = style
                            HUDController.current?.preview(style: style)
                        }
                    }
                }
                HUDStylePreview(style: settings.style, showsPercent: settings.showsPercent)
                Text(settings.style.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            .padding(.vertical, 4)
            Picker(selection: $settings.otherDisplaysStyle) {
                ForEach(HUDStyle.otherDisplayChoices) { Text($0.title).tag($0) }
            } label: {
                HUDRowLabel(title: "On other displays", detail: "Displays without the island.")
            }
            Picker(selection: $settings.edge) {
                ForEach(HUDEdge.allCases) { Text($0.title).tag($0) }
            } label: {
                HUDRowLabel(title: "Edge bar side", detail: "Kept clear of the Dock.")
            }
            LabeledContent {
                Button("Preview") { HUDController.current?.preview() }
            } label: {
                HUDRowLabel(title: "Try it", detail: "Shows the HUD with the current volume.")
            }
        } header: {
            Text("Volume & Brightness HUD")
        }
    }
}

/// A selectable thumbnail with the style's name.
private struct HUDStyleCard: View {
    let style: HUDStyle
    let isSelected: Bool
    let edge: HUDEdge
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HUDStyleThumbnail(style: style, isSelected: isSelected, edge: edge)
                    .frame(maxWidth: .infinity)
                Text(style.shortTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? SparkVTheme.text : SparkVTheme.textSecondary)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .sparkVHoverFill(hover.isOn && !isSelected, cornerRadius: 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(style.title)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The selected style at real size on a dark stage, drawn with the HUD's
/// own views.
struct HUDStylePreview: View {
    let style: HUDStyle
    var showsPercent = true
    var content = HUDContent(style: .volume(muted: false, deviceName: nil), level: 0.62)

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
            // Menu bar.
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 24)
            stage
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: style)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(style.title)")
    }

    @ViewBuilder
    private var stage: some View {
        switch style {
        case .inline, .ring:
            HStack(spacing: 0) {
                HUDWingIcon(content: content)
                    .padding(.trailing, 8)
                    .frame(width: 60, alignment: .trailing)
                Color.clear.frame(width: 110)
                Group {
                    if style == .ring {
                        HUDWingRing(content: content, showsPercent: showsPercent)
                    } else {
                        HUDWingLevel(content: content, showsPercent: showsPercent)
                    }
                }
                .padding(.leading, 8)
                .frame(width: 104, alignment: .leading)
            }
            .frame(height: 30)
            .background(islandShape.fill(Color.black))
            .transition(.sparkVCrossfade)
        case .band:
            VStack(spacing: 0) {
                Color.clear.frame(height: 26)
                HUDActivityView(content: content, showsPercent: showsPercent)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            }
            .frame(width: 330)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16).fill(Color.black))
            .transition(.sparkVCrossfade)
        case .pill:
            VStack(spacing: 0) {
                restingNotch
                HUDPillView(content: content, showsPercent: showsPercent)
                    .padding(.top, 14)
            }
            .transition(.sparkVCrossfade)
        case .edgeBar:
            ZStack(alignment: .top) {
                restingNotch
                HStack {
                    Spacer()
                    // The real bar at 45 %: it is 200 pt tall on screen.
                    HUDEdgeBarView(content: content, showsPercent: showsPercent)
                        .scaleEffect(0.45)
                        .frame(width: 22, height: 92)
                        .padding(.trailing, 16)
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 14)
            }
            .transition(.sparkVCrossfade)
        case .hidden:
            restingNotch
        }
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
    }

    private var restingNotch: some View {
        islandShape.fill(Color.black).frame(width: 120, height: 24)
    }
}

// MARK: - Displays (System pane)

/// Settings window › System: which display the keys and HUD go to, BetterDisplay
/// / Lunar / MonitorControl, and a style per connected display.
struct HUDDisplaysSettingsSection: View {
    @ObservedObject private var settings = HUDPlusSettings.shared
    @ObservedObject private var directory = HUDDisplayDirectory.shared
    @ObservedObject private var displayApps = HUDDisplayAppWatcher.shared

    var body: some View {
        Section {
            Toggle(isOn: $settings.brightnessFollowsPointer) {
                HUDRowLabel(
                    title: "Brightness keys follow the pointer",
                    detail: "Keys change the display under the pointer. A monitor SparkV can't set (DDC) goes to a display tool when one runs, else the built-in display."
                )
            }
            Toggle(isOn: $settings.showsOnPointerDisplay) {
                HUDRowLabel(title: "Show volume on the pointer's display", detail: "Otherwise on the island's display.")
            }
            Toggle(isOn: $settings.stepAsideForDisplayApps) {
                HUDRowLabel(
                    title: "Step aside for display tools",
                    detail: displayApps.runningName.map { "\($0) is running: it handles external displays' keys and shows its own HUD." }
                        ?? "When BetterDisplay, Lunar or MonitorControl runs, external displays' keys go to it."
                )
            }
            Toggle(isOn: $settings.displayAppsHandleBuiltIn) {
                HUDRowLabel(title: "Built-in display too", detail: "Let those tools handle the built-in display's keys as well.")
            }
            .disabled(!settings.stepAsideForDisplayApps)
            ForEach(directory.screens, id: \.facts.id) { screen in
                HUDDisplayRow(screen: screen)
            }
            if directory.screens.isEmpty {
                Text("No displays found.")
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
        } header: {
            Text("Displays")
        } footer: {
            Text("A display set to Off gets macOS's own pop-up.")
        }
        // Follows screen changes only while it shows.
        .onAppear { directory.start() }
        .onDisappear { directory.stop() }
    }
}

/// One connected display: who drives its brightness and its HUD style.
private struct HUDDisplayRow: View {
    let screen: HUDScreenInfo
    @ObservedObject private var settings = HUDPlusSettings.shared
    @ObservedObject private var displayApps = HUDDisplayAppWatcher.shared

    var body: some View {
        let islandScreen = HUDController.current?.islandScreen() ?? HUDDisplayDirectory.defaultIslandScreen()
        let isIsland = islandScreen.flatMap(HUDDisplayDirectory.displayID(of:)) == screen.facts.id
        if let uuid = screen.uuid {
            Picker(selection: Binding(
                get: { settings.override(forDisplayUUID: uuid) },
                set: { settings.setOverride($0, forDisplayUUID: uuid) }
            )) {
                Text("Default (\(defaultStyle(isIsland: isIsland).shortTitle))").tag(HUDStyle?.none)
                Divider()
                ForEach(isIsland ? HUDStyle.islandChoices + [.hidden] : HUDStyle.otherDisplayChoices) { style in
                    Text(style.title).tag(HUDStyle?.some(style))
                }
            } label: {
                label(isIsland: isIsland)
            }
        } else {
            LabeledContent { EmptyView() } label: { label(isIsland: isIsland) }
        }
    }

    @ViewBuilder
    private func label(isIsland: Bool) -> some View {
        Label {
            Text(isIsland ? "\(screen.name) · Island" : screen.name)
            Text(brightnessStatus)
        } icon: {
            Image(systemName: screen.facts.isBuiltin ? "laptopcomputer" : "display")
                .foregroundStyle(SparkVTheme.textSecondary)
        }
    }

    private func defaultStyle(isIsland: Bool) -> HUDStyle {
        HUDStyleResolver.resolve(islandStyle: settings.style, otherStyle: settings.otherDisplaysStyle, override: nil, isIslandScreen: isIsland)
    }

    private var brightnessStatus: String {
        let facts = screen.facts
        let handledByApp = displayApps.isRunning
            && (facts.isBuiltin ? settings.stepAsideForDisplayApps && settings.displayAppsHandleBuiltIn : settings.stepAsideForDisplayApps)
        if handledByApp, let name = displayApps.runningName { return "Brightness: \(name)" }
        if facts.canSetBrightness { return "Brightness: SparkV" }
        if displayApps.isRunning { return "Brightness: \(displayApps.runningName ?? "a display tool")" }
        return "Brightness: not settable (DDC has no public API)"
    }
}

// MARK: - Gear menu

/// The HUD's items for any menu: `Menu("Volume & Brightness") { HUDMenuItems() }`.
struct HUDMenuItems: View {
    @ObservedObject private var settings = HUDPlusSettings.shared

    var body: some View {
        if let hud = HUDController.current {
            HUDMenuControllerItems(hud: hud)
            Divider()
        }
        Picker("Style", selection: $settings.style) {
            ForEach(HUDStyle.islandChoices) { style in
                Label(style.title, systemImage: style.systemImage).tag(style)
            }
        }
        Picker("On Other Displays", selection: $settings.otherDisplaysStyle) {
            ForEach(HUDStyle.otherDisplayChoices) { Text($0.title).tag($0) }
        }
        Picker("Key Steps", selection: $settings.stepDivisions) {
            ForEach(HUDStepMath.divisionChoices, id: \.self) { Text("\($0) Steps").tag($0) }
        }
        Toggle("Show Percentage", isOn: $settings.showsPercent)
        Toggle("Drag, Scroll or Click the HUD", isOn: $settings.isInteractive)
        Divider()
        Toggle("Brightness Keys Follow the Pointer", isOn: $settings.brightnessFollowsPointer)
        Toggle("Step Aside for BetterDisplay & Lunar", isOn: $settings.stepAsideForDisplayApps)
        Divider()
        Button("Preview HUD") { HUDController.current?.preview() }
    }
}

private struct HUDMenuControllerItems: View {
    @ObservedObject var hud: HUDController

    var body: some View {
        Toggle("Volume & Brightness HUD", isOn: $hud.isEnabled)
        Toggle("Hide macOS Volume/Brightness Pop-up", isOn: $hud.replacesSystemHUD)
            .disabled(!hud.isEnabled)
    }
}

// MARK: - Agents hub tile (System)

/// Shows the HUD's style; a click lists the styles, steps and a preview,
/// like the Modes tile. Lit while SparkV replaces the macOS pop-up.
struct HUDHubTile: View {
    static let tint = Color(red: 1.0, green: 0.72, blue: 0.22)

    @ObservedObject private var settings = HUDPlusSettings.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        if let hud = HUDController.current {
            HUDHubTileLit(hud: hud, settings: settings, hover: hover)
        } else {
            HUDHubTileFace(lit: false, settings: settings, hover: hover)
        }
    }
}

/// Follows the controller's switches for the tile's lit state.
private struct HUDHubTileLit: View {
    @ObservedObject var hud: HUDController
    @ObservedObject var settings: HUDPlusSettings
    @ObservedObject var hover: ViewFlag

    var body: some View {
        HUDHubTileFace(lit: hud.isEnabled && hud.replacesSystemHUD, settings: settings, hover: hover)
    }
}

private struct HUDHubTileFace: View {
    let lit: Bool
    @ObservedObject var settings: HUDPlusSettings
    @ObservedObject var hover: ViewFlag

    var body: some View {
        Menu {
            HUDMenuItems()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LabsBHubTileBackground.glyph(isActive: lit, isHovered: hover.isOn, tint: HUDHubTile.tint))
                    .frame(height: 20)
                Text("HUD \(settings.style.shortTitle)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LabsBHubTileBackground.label(isActive: lit, isHovered: hover.isOn))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
            .background(LabsBHubTileBackground(isActive: lit, isHovered: hover.isOn, tint: HUDHubTile.tint))
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(lit
              ? "Volume & brightness HUD (\(settings.style.title)), replacing the macOS pop-up. Click for styles and a preview."
              : "Volume & brightness HUD: \(settings.style.title). Click for styles and a preview.")
        .accessibilityLabel("Volume and brightness HUD, \(settings.style.title)")
    }
}
