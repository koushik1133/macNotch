import SwiftUI

/// Agents hub tile, same 48 pt footprint and faces as `AgentTile`: a click
/// picks at once (the drawer collapses first), the small swatch in the
/// corner shows the last pick and opens the Color Picker page, right-click
/// has the menu. While a pick is open the tile is lit; after 20 s without an
/// answer it turns into Reset.
struct ColorPickerHubTile: View {
    @ObservedObject var controller: ColorPickerController
    /// Opens the drawer page (the integrator passes `state.select(.colorPicker)`).
    let onOpen: () -> Void

    @StateObject private var hover = ViewFlag()

    static let tint = Color.purple

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        Button {
            if controller.mayBeStuck { controller.resetPicker() } else { controller.pickColor() }
        } label: {
            if SparkVTheme.usesTileTints {
                appleFace(shape)
            } else {
                sparkvFace(shape)
            }
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .overlay(alignment: .topTrailing) { cornerSwatch }
        .help(helpText)
        .accessibilityLabel(controller.mayBeStuck ? "Reset the color picker" : "Pick a color from the screen")
        .contextMenu {
            ColorPickerMenuItems(controller: controller, onOpen: onOpen)
        }
    }

    private var title: String {
        if controller.mayBeStuck { return "Reset" }
        return controller.isPicking ? "Picking…" : "Pick Color"
    }

    private var symbol: String { controller.isPicking ? "eyedropper.full" : "eyedropper.halffull" }

    private var helpText: String {
        if controller.mayBeStuck { return "The system loupe stopped answering. Click to reset it." }
        let key = controller.shortcutLabel.isEmpty ? "" : " (\(controller.shortcutLabel))"
        return "Pick a color anywhere on screen\(key), copied as \(controller.defaultFormat.title). Esc cancels. The arrow in the corner opens the Color Picker."
    }

    /// Opens the Color Picker page (the drop at the glyph's tip shows the last pick).
    private var cornerSwatch: some View {
        Button(action: onOpen) {
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(hover.isOn ? SparkVTheme.textSecondary : SparkVTheme.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .padding(1)
        .help(controller.current.map { "Open the Color Picker (last color \($0.hexString))" } ?? "Open the Color Picker")
        .accessibilityLabel(controller.current.map { "Open the Color Picker. Last color \($0.spokenDescription)" } ?? "Open the Color Picker")
    }

    /// The eyedropper with a drop of the last picked color at its tip.
    private func glyph(tint: Color) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .overlay(alignment: .bottomLeading) {
                if let color = controller.current {
                    CPSwatchDot(color: color, size: 7)
                        .offset(x: -4, y: 3)
                        .accessibilityHidden(true)
                }
            }
    }

    private func appleFace(_ shape: RoundedRectangle) -> some View {
        let lit = controller.isPicking
        return VStack(spacing: 5) {
            glyph(tint: Self.tint)
                .font(.system(size: 16, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(lit || hover.isOn ? 1 : 0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(shape.fill(lit ? Self.tint.opacity(0.24) : Color.white.opacity(hover.isOn ? 0.14 : 0.08)))
        .overlay(shape.strokeBorder(lit ? Self.tint.opacity(0.45) : Color.clear, lineWidth: 1))
        .contentShape(shape)
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }

    private func sparkvFace(_ shape: RoundedRectangle) -> some View {
        let highlighted = controller.isPicking
        let lit = highlighted || hover.isOn
        return VStack(spacing: 5) {
            glyph(tint: lit ? SparkVTheme.red : SparkVTheme.text.opacity(0.88))
                .font(.system(size: 16, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(lit ? SparkVTheme.text : SparkVTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(shape.fill(highlighted ? SparkVTheme.redSoft : (hover.isOn ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface)))
        .overlay(shape.strokeBorder(lit ? SparkVTheme.red.opacity(highlighted ? 0.55 : 0.35) : SparkVTheme.stroke, lineWidth: 1))
        .contentShape(shape)
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }
}

/// Gear menu (`Menu("Color Picker") { … }`) and the hub tile's right-click.
struct ColorPickerMenuItems: View {
    @ObservedObject var controller: ColorPickerController
    var onOpen: (() -> Void)? = nil

    var body: some View {
        Button(controller.shortcutLabel.isEmpty ? "Pick Color" : "Pick Color  \(controller.shortcutLabel)") {
            controller.pickColor()
        }
        if controller.isPicking {
            // Also ends the system loupe other apps may have open.
            Button("Reset Color Picker") { controller.resetPicker() }
        }
        Button("Open Color Picker") {
            if let onOpen { onOpen() } else { controller.onOpenDrawer?() }
        }
        Button("Convert Clipboard Color") { controller.convertClipboard() }
        if let color = controller.current {
            Menu("Copy Last Color As") {
                ForEach(CPFormat.allCases) { format in
                    Button("\(format.title)  \(controller.displayText(color, format))") { controller.copy(color, as: format) }
                }
            }
        }
        Divider()
        ColorPickerSettingsItems(controller: controller)
    }
}

/// Settings shared by the gear menu and the drawer's ⋯ menu.
struct ColorPickerSettingsItems: View {
    @ObservedObject var controller: ColorPickerController

    var body: some View {
        Picker("Copy As", selection: $controller.defaultFormat) {
            ForEach(CPFormat.allCases) { format in
                Text(format.menuTitle).tag(format)
            }
        }
        Toggle("Lowercase Hex", isOn: $controller.options.lowercaseHex)
        Toggle("Include # in Hex", isOn: $controller.options.hexHash)
        Toggle("Comma CSS Syntax (rgb(59, 130, 246))", isOn: $controller.options.legacyCSS)
        Toggle("Precise HSL and HSB (Decimals When Needed)", isOn: $controller.options.preciseHSL)
        Toggle("Remember the App Each Color Came From", isOn: $controller.remembersApp)
        Menu("Shortcut") {
            Toggle("Pick with a Shortcut", isOn: Binding(get: { controller.hotkeyEnabled }, set: { controller.setHotkeyEnabled($0) }))
            Divider()
            ForEach(ColorPickerController.shortcutChoices, id: \.displayString) { choice in
                Toggle(choice.displayString + (choice == ColorPickerController.defaultShortcut ? " (Default)" : ""), isOn: Binding(
                    get: { controller.shortcut == choice },
                    set: { if $0 { controller.setShortcut(choice) } }
                ))
                .disabled(!controller.hotkeyEnabled)
            }
            if let problem = controller.hotkeyProblem {
                Divider()
                Text(problem)
            }
        }
        // Turned on by itself after a stuck pick was reset: the loupe then
        // starts with SparkV active (the front app shows its inactive colors).
        Toggle("Start Picker in Compatibility Mode", isOn: $controller.compatibilityStart)
        Divider()
        Button("Clear Recent Colors") { controller.clearHistory() }
            .disabled(controller.history.isEmpty)
    }
}
