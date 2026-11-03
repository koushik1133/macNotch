import AppKit
import SwiftUI

private enum CPLayout {
    static let size = CGSize(width: 508, height: 114)
    static let headerHeight: CGFloat = 18
    static let bodyHeight: CGFloat = 70
    static let stripHeight: CGFloat = 18
    static let spacing: CGFloat = 4
    static let swatchWidth: CGFloat = 112
    static let corner: CGFloat = 10
}

/// The Color Picker drawer page (508×114, a tall tab): header with the
/// section switcher, Paste and Pick; the big swatch with its names beside
/// the section (formats, contrast, shades, palettes); the history strip.
struct ColorPickerDrawerView: View {
    @ObservedObject var controller: ColorPickerController
    @Namespace private var sectionPill

    static let size = CPLayout.size

    var body: some View {
        VStack(spacing: CPLayout.spacing) {
            header
                .frame(height: CPLayout.headerHeight)
            HStack(spacing: 8) {
                CPBigSwatch(controller: controller)
                    .frame(width: CPLayout.swatchWidth)
                ZStack {
                    sectionContent
                        .id(controller.section)
                        .transition(.sparkVCrossfade)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: controller.section)
            }
            .frame(height: CPLayout.bodyHeight)
            CPHistoryStrip(controller: controller)
                .frame(height: CPLayout.stripHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    /// One action button at a time on the right (Pick, Picking…, or Reset
    /// Picker when the loupe may be stuck), so the header never overflows;
    /// the section tabs keep their size and the buttons give way first.
    private var header: some View {
        HStack(spacing: 6) {
            Text(SparkVTheme.isApple ? "COLOR" : "SPARKV / COLOR")
                .font(SparkVTheme.eyebrow(9))
                .tracking(SparkVTheme.isApple ? 0.4 : 1.2)
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
            sectionSwitcher
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 4)
            CPIconButton(systemImage: "doc.on.clipboard", help: "Convert the color on the clipboard (hex, rgb, hsl, hsb, oklch, Swift)") {
                controller.convertClipboard()
            }
            if controller.mayBeStuck {
                Button {
                    controller.resetPicker()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Picker")
                    }
                }
                .buttonStyle(CPSmallButtonStyle(destructive: true))
                .help("The loupe hasn't answered for 20 s. Reset ends it; this resets the system color loupe for all apps.")
                .accessibilityLabel("Reset the color picker")
                .transition(.opacity)
            } else {
                Button {
                    controller.pickColor()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: controller.isPicking ? "eyedropper.full" : "eyedropper")
                        Text(controller.isPicking ? "Picking…" : "Pick")
                        if !controller.isPicking, !controller.shortcutLabel.isEmpty {
                            Text(controller.shortcutLabel)
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }
                }
                .buttonStyle(CPSmallButtonStyle(prominent: true))
                .help(controller.isPicking ? "The loupe is open: click a pixel, or press Esc to cancel." : "Pick a color from anywhere on screen. Esc cancels.")
                .accessibilityLabel(controller.isPicking ? "Picking a color" : "Pick a color from the screen")
                .transition(.opacity)
            }
            CPMenuButton(systemImage: "ellipsis.circle", help: "Color Picker settings") {
                ColorPickerSettingsItems(controller: controller)
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: controller.mayBeStuck)
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 1) {
            ForEach(ColorPickerController.Section.allCases) { section in
                CPSectionTab(title: section.title, isActive: controller.section == section, pill: sectionPill) {
                    // Clicks move the pill (ease-in-out); Reduce Motion: no slide.
                    withAnimation(SparkVMotion.reduceMotion ? nil : SparkVMotion.easeInOut(SparkVMotion.Duration.standard)) {
                        controller.section = section
                    }
                }
            }
        }
        .padding(1)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch controller.section {
        case .formats: CPFormatsSection(controller: controller)
        case .contrast: CPContrastSection(controller: controller)
        case .shades: CPShadesSection(controller: controller)
        case .palettes: CPPalettesSection(controller: controller)
        }
    }
}

private struct CPSectionTab: View {
    let title: String
    let isActive: Bool
    let pill: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? SparkVTheme.activeGlyph : (hover.isOn ? SparkVTheme.text : SparkVTheme.inactiveGlyph))
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background {
                    if isActive {
                        Capsule()
                            .fill(SparkVTheme.activeTabFill)
                            .overlay(Capsule().strokeBorder(SparkVTheme.activeTabStroke, lineWidth: 0.5))
                            .matchedGeometryEffect(id: "colorPickerSection", in: pill)
                    }
                }
                .contentShape(Capsule())
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Big swatch

private struct CPBigSwatch: View {
    @ObservedObject var controller: ColorPickerController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CPLayout.corner, style: .continuous)
        if let color = controller.current {
            Button {
                controller.copy(color, as: controller.defaultFormat, feedbackKey: "swatch")
            } label: {
                ZStack(alignment: .bottomLeading) {
                    shape.fill(Color(cp: color))
                    shape.strokeBorder(Color.white.opacity(hover.isOn ? 0.34 : 0.16), lineWidth: 1)
                    labels(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .contentShape(shape)
                .animation(SparkVMotion.hover(), value: hover.isOn)
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { hover.isOn = $0 }
            .help("Copy as \(controller.defaultFormat.title): \(controller.text(color, controller.defaultFormat))")
            .accessibilityLabel("Current color \(color.spokenDescription). Copy as \(controller.defaultFormat.title)")
            .contextMenu { CPColorContextItems(controller: controller, color: color, entry: nil) }
        } else {
            Button {
                controller.pickColor()
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SparkVTheme.choose(apple: Color.purple, sparkv: SparkVTheme.red))
                    Text("Pick a color")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(SparkVTheme.surface))
                .overlay(shape.strokeBorder(SparkVTheme.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(shape)
            }
            .buttonStyle(SparkVPressStyle())
            .accessibilityLabel("Pick a color from the screen")
        }
    }

    private func labels(_ color: CPColor) -> some View {
        let ink = color.legibleText
        let named = CPNamedColors.nearest(color)
        let tailwind = CPTailwind.nearest(color)
        let copied = controller.isCopied("swatch")
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(CPColorFamily.name(color))
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if !color.isInSRGBGamut {
                    Text("P3")
                        .font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 3)
                        .frame(height: 12)
                        .background(Capsule().fill(ink.opacity(0.18)))
                        .help("Outside sRGB: hex and rgb() are clipped; P3 and Swift formats keep it")
                }
            }
            .opacity(0.85)
            Spacer(minLength: 0)
            Text((tailwind.isExact ? "" : "≈ ") + tailwind.name)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .opacity(0.8)
                .help("Nearest Tailwind v3 class (ΔE \(String(format: "%.1f", tailwind.distance * 100)))")
            Text((named.isExact ? "" : "≈ ") + named.name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .opacity(0.8)
                .help("Nearest CSS color name")
            HStack(spacing: 3) {
                Text(copied ? "Copied" : controller.text(color, .hex))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .transition(.opacity)
                } else if hover.isOn {
                    // Says what a click does.
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.8)
                        .transition(.opacity)
                }
            }
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: copied)
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .foregroundStyle(ink)
    }
}

// MARK: - Formats

/// HEX/RGB and HSL/HSB share rows; OKLCH sits beside Tailwind; the CSS P3
/// and Swift initializers get full-width rows, so every value shows in
/// full at one font size. (Internal so the offscreen renders can show every
/// row in a taller frame.)
struct CPFormatsSection: View {
    @ObservedObject var controller: ColorPickerController

    static let wide: [CPFormat] = [.displayP3, .swiftUI, .uiKit, .appKit]

    var body: some View {
        if let color = controller.current {
            // Three rows show; the fourth peeks under the fade, so it reads
            // as a list that scrolls.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: CPFormatRow.spacing) {
                    HStack(spacing: 4) {
                        CPFormatRow(controller: controller, color: color, format: .hex)
                        CPFormatRow(controller: controller, color: color, format: .rgb)
                    }
                    HStack(spacing: 4) {
                        CPFormatRow(controller: controller, color: color, format: .hsl)
                        CPFormatRow(controller: controller, color: color, format: .hsb)
                    }
                    HStack(spacing: 4) {
                        CPFormatRow(controller: controller, color: color, format: .oklch)
                        CPFormatRow(controller: controller, color: color, format: .tailwind)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    ForEach(Self.wide) { format in
                        CPFormatRow(controller: controller, color: color, format: format)
                    }
                }
                .padding(.bottom, 6)
            }
            .mask(
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                }
            )
        } else {
            CPSectionHint(
                symbol: "eyedropper.halffull",
                title: "Pick anywhere, it's copied",
                detail: "\(controller.shortcutLabel.isEmpty ? "Click Pick" : "Press \(controller.shortcutLabel)") over any app or web page. Esc cancels. No Screen Recording permission needed."
            )
        }
    }
}

private struct CPFormatRow: View {
    static let height: CGFloat = 18
    static let spacing: CGFloat = 3

    @ObservedObject var controller: ColorPickerController
    let color: CPColor
    let format: CPFormat
    @StateObject private var hover = ViewFlag()

    /// Values that name themselves (`oklch(`, `color(display-p3`, `Color(`,
    /// `UIColor(`, `NSColor(`): the name is drawn in the label's color, so
    /// no separate label takes room from the value.
    private var namesItself: Bool { [.oklch, .displayP3, .swiftUI, .uiKit, .appKit].contains(format) }

    var body: some View {
        let value = controller.text(color, format)
        let shown = controller.displayText(color, format)
        let copied = controller.isCopied(format.rawValue)
        let isDefault = controller.defaultFormat == format
        let labelColor = isDefault ? SparkVTheme.accent : SparkVTheme.textSecondary
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button {
            controller.copy(color, as: format)
        } label: {
            HStack(spacing: 5) {
                Group {
                    if namesItself {
                        selfNamedValue(shown, labelColor: labelColor)
                    } else {
                        HStack(spacing: 5) {
                            Text(format.title)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(labelColor)
                                .fixedSize()
                                .frame(minWidth: 21, alignment: .leading)
                            Text(shown)
                                .font(.system(size: 10.5, weight: .medium, design: format == .hex || format == .rgb ? .monospaced : .default))
                                .foregroundStyle(SparkVTheme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(copied ? SparkVTheme.success : (hover.isOn ? SparkVTheme.text : SparkVTheme.textTertiary))
                    .frame(width: 12)
                    .contentTransition(.opacity)
            }
            .padding(.leading, 6)
            .padding(.trailing, 5)
            .frame(height: Self.height)
            .background(shape.fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            .contentShape(shape)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: copied)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(helpText(value, shown: shown))
        .accessibilityLabel("Copy \(format.title): \(value)")
        .contextMenu {
            Button("Copy \(format.title)") { controller.copy(color, as: format) }
            Button("Use \(format.title) When Picking") { controller.defaultFormat = format }
                .disabled(isDefault)
        }
    }

    /// "Color" in the label's color, "(red: 0.231, …)" in the text color.
    private func selfNamedValue(_ value: String, labelColor: Color) -> some View {
        let end = format == .displayP3 ? value.firstIndex(of: " ") : value.firstIndex(of: "(")
        let split = end ?? value.endIndex
        let name = Text(String(value[..<split])).foregroundStyle(labelColor)
        let rest = Text(String(value[split...])).foregroundStyle(SparkVTheme.text)
        return Text("\(name)\(rest)")
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func helpText(_ value: String, shown: String) -> String {
        switch format {
        case .hsl where !controller.options.preciseHSL, .hsb where !controller.options.preciseHSL:
            return "\(value). Whole numbers, so reading it back can be up to 3 steps off per channel; Precise HSL and HSB in the ⋯ menu keeps the exact color."
        case .tailwind where shown != value:
            return "Nearest Tailwind v3 class: copies \(value)."
        default:
            return value
        }
    }
}

private struct CPSectionHint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SparkVTheme.choose(apple: Color.purple, sparkv: SparkVTheme.red))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: CPLayout.corner, style: .continuous).fill(SparkVTheme.surface))
    }
}

// MARK: - Contrast

private struct CPContrastSection: View {
    @ObservedObject var controller: ColorPickerController

    var body: some View {
        let pair = controller.contrast
        let ratio = controller.contrastRatio
        let apca = CPContrast.apca(text: pair.foreground, background: pair.background)
        HStack(spacing: 8) {
            preview(pair)
                .frame(width: 58)
            VStack(spacing: 4) {
                CPContrastSlot(controller: controller, title: "Text", color: pair.foreground, slot: .foreground)
                CPContrastSlot(controller: controller, title: "Background", color: pair.background, slot: .background)
            }
            .frame(width: 118)
            .overlay(alignment: .trailing) {
                CPIconButton(systemImage: "arrow.up.arrow.down", help: "Swap text and background", size: 18) {
                    controller.swapContrast()
                }
                .offset(x: 14)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(CPContrast.ratioText(ratio))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(SparkVTheme.text)
                    Text("APCA Lc \(Int(apca.rounded()))")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .help("APCA lightness contrast, a WCAG 3 draft (not yet a standard)")
                    Spacer(minLength: 0)
                    if let suggestion = controller.contrastSuggestion {
                        Button {
                            controller.applySuggestion()
                        } label: {
                            HStack(spacing: 3) {
                                CPSwatchDot(color: suggestion, size: 9)
                                Text("Fix")
                            }
                        }
                        .buttonStyle(CPSmallButtonStyle())
                        .help("Use \(suggestion.hexString) for the text: same hue, \(CPContrast.ratioText(CPContrast.ratio(suggestion, pair.background))) (passes AA)")
                        .accessibilityLabel("Suggest a passing text color, \(suggestion.hexString)")
                    }
                }
                let levels = CPContrast.Level.allCases
                HStack(spacing: 3) {
                    ForEach(levels.prefix(3)) { level in
                        CPLevelBadge(title: level.title, passes: CPContrast.passes(level, ratio: ratio), help: level.detail)
                    }
                }
                HStack(spacing: 3) {
                    ForEach(levels.suffix(2)) { level in
                        CPLevelBadge(title: level.title, passes: CPContrast.passes(level, ratio: ratio), help: level.detail)
                    }
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func preview(_ pair: CPContrastPair) -> some View {
        let shape = RoundedRectangle(cornerRadius: CPLayout.corner, style: .continuous)
        return VStack(spacing: 0) {
            Text("Aa")
                .font(.system(size: 20, weight: .bold))
            Text("Sample text")
                .font(.system(size: 8.5, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(Color(cp: pair.foreground))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color(cp: pair.background)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(pair.foreground.spokenDescription) on \(pair.background.spokenDescription)")
    }
}

private struct CPContrastSlot: View {
    @ObservedObject var controller: ColorPickerController
    let title: String
    let color: CPColor
    let slot: ColorPickerController.Slot
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let canUse = controller.current != nil
        HStack(spacing: 5) {
            Button {
                guard let current = controller.current else { return }
                if slot == .foreground { controller.contrast.foreground = current } else { controller.contrast.background = current }
            } label: {
                CPSwatchTile(color: color, corner: 5, hovered: hover.isOn && canUse)
                    .frame(width: 22, height: 22)
                    .animation(SparkVMotion.hover(), value: hover.isOn)
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { hover.isOn = $0 }
            .disabled(!canUse)
            .help("Use the current color as the \(title.lowercased())")
            .accessibilityLabel("\(title): \(color.spokenDescription). Use the current color")
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                Text(color.hexString)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SparkVTheme.text)
            }
            Spacer(minLength: 0)
            CPIconButton(systemImage: "eyedropper", help: "Pick the \(title.lowercased()) from the screen", size: 18) {
                controller.pickColor(into: slot)
            }
        }
        .frame(height: 33)
    }
}

// MARK: - Shades

private struct CPShadesSection: View {
    @ObservedObject var controller: ColorPickerController

    var body: some View {
        if let color = controller.current {
            let ramp = CPShades.tintsAndShades(color)
            let scale = CPShades.scale(color)
            let nearest = CPShades.nearestStep(color)
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(Array(ramp.enumerated()), id: \.offset) { index, swatch in
                        CPShadeSwatch(controller: controller, color: swatch, label: nil, isBase: index == ramp.count / 2,
                                      key: "ramp-\(index)")
                    }
                }
                HStack(spacing: 3) {
                    ForEach(scale, id: \.step) { item in
                        CPShadeSwatch(controller: controller, color: item.color, label: "\(item.step)", isBase: item.step == nearest,
                                      key: "scale-\(item.step)")
                    }
                }
            }
        } else {
            CPSectionHint(symbol: "square.stack.3d.down.forward", title: "Tints, shades and a 50–950 scale",
                          detail: "Pick a color to see lighter and darker steps made in OKLCH (same hue, kept inside sRGB).")
        }
    }
}

private struct CPShadeSwatch: View {
    @ObservedObject var controller: ColorPickerController
    let color: CPColor
    let label: String?
    let isBase: Bool
    let key: String
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let copied = controller.isCopied(key)
        Button {
            if NSEvent.modifierFlags.contains(.shift) {
                controller.addToPalette(color)
            } else {
                controller.copy(color, as: controller.defaultFormat, feedbackKey: key)
            }
        } label: {
            CPSwatchTile(color: color, corner: 5, selected: isBase)
                .overlay {
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(color.legibleText)
                            .transition(.opacity)
                    } else if let label {
                        Text(label)
                            .font(.system(size: 8, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color.legibleText.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .scaleEffect(hover.isOn && !SparkVMotion.reduceMotion ? 1.06 : 1)
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: copied)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .frame(maxWidth: .infinity)
        .frame(height: 31)
        .help("\(label.map { "\($0): " } ?? "")\(controller.text(color, controller.defaultFormat)). Click to copy, ⇧-click to add to the palette.")
        .accessibilityLabel("\(label.map { "Step \($0), " } ?? "")\(color.spokenDescription). Copy")
        .contextMenu { CPColorContextItems(controller: controller, color: color, entry: nil) }
    }
}

// MARK: - Palettes

/// Inline modes of the palettes toolbar (no sheets on the notch panel).
@MainActor
private final class CPPaletteEditState: ObservableObject {
    enum Mode: Equatable { case none, renaming(UUID), confirmingDelete(UUID) }
    @Published var mode: Mode = .none
    @Published var draftName = ""
}

private struct CPPalettesSection: View {
    @ObservedObject var controller: ColorPickerController
    @StateObject private var edit = CPPaletteEditState()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolbar
                .frame(height: 20)
            if let palette = controller.selectedPalette {
                colors(of: palette)
                    .frame(height: 46)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Group colors into named palettes, then copy them as CSS variables, Tailwind, JSON or Swift. ⇧-click a recent color to add it.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(controller.current == nil ? "New Palette" : "New Palette with This Color") {
                        controller.createPalette(with: controller.current.map { [$0] } ?? [])
                    }
                    .buttonStyle(CPSmallButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        switch edit.mode {
        case .renaming(let id):
            HStack(spacing: 5) {
                TextField("Palette name", text: $edit.draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
                    .onSubmit { commitRename(id) }
                    .accessibilityLabel("Palette name")
                Button("Cancel") { edit.mode = .none }
                    .buttonStyle(CPSmallButtonStyle())
                Button("Rename") { commitRename(id) }
                    .buttonStyle(CPSmallButtonStyle(prominent: true))
                    .disabled(edit.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .confirmingDelete(let id):
            let palette = controller.palettes.first { $0.id == id }
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SparkVTheme.destructive)
                Text("Delete “\(palette?.name ?? "palette")” and its \(palette?.colors.count ?? 0) colors?")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Cancel") { edit.mode = .none }
                    .buttonStyle(CPSmallButtonStyle())
                Button("Delete") {
                    controller.deletePalette(id)
                    edit.mode = .none
                }
                .buttonStyle(CPSmallButtonStyle(destructive: true))
            }
        case .none:
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(controller.palettes) { palette in
                            CPPaletteChip(name: palette.name, count: palette.colors.count,
                                          isSelected: palette.id == controller.selectedPalette?.id) {
                                controller.selectedPaletteID = palette.id
                            }
                        }
                    }
                }
                CPIconButton(systemImage: "plus", help: "New palette", size: 18) {
                    controller.createPalette(with: controller.current.map { [$0] } ?? [])
                }
                if let palette = controller.selectedPalette {
                    CPMenuButton(systemImage: "ellipsis", help: "Rename, reorder, export or delete “\(palette.name)”", size: 18) {
                        Button("Rename…") {
                            edit.draftName = palette.name
                            edit.mode = .renaming(palette.id)
                        }
                        Button("Move Left") { controller.movePalette(palette.id, by: -1) }
                            .disabled(controller.palettes.first?.id == palette.id)
                        Button("Move Right") { controller.movePalette(palette.id, by: 1) }
                            .disabled(controller.palettes.last?.id == palette.id)
                        Menu("Copy As") {
                            ForEach(CPPaletteExport.allCases) { kind in
                                Button(kind.title) { controller.export(palette, as: kind) }
                            }
                        }
                        .disabled(palette.colors.isEmpty)
                        Divider()
                        Button("Delete Palette…", role: .destructive) { edit.mode = .confirmingDelete(palette.id) }
                    }
                }
            }
        }
    }

    private func colors(of palette: CPPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                CPPaletteAddTile(controller: controller, palette: palette)
                ForEach(Array(palette.colors.enumerated()), id: \.offset) { index, color in
                    CPPaletteSwatch(controller: controller, palette: palette, index: index, color: color)
                }
                if palette.colors.isEmpty {
                    Text("Empty. Add the current color, or ⇧-click a recent one.")
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .padding(.leading, 4)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func commitRename(_ id: UUID) {
        controller.renamePalette(id, to: edit.draftName)
        edit.mode = .none
    }
}

private struct CPPaletteChip: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .opacity(0.6)
            }
            .foregroundStyle(isSelected ? SparkVTheme.activeGlyph : (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(isSelected ? SparkVTheme.activeTabFill : (hover.isOn ? SparkVTheme.hoverFill : Color.white.opacity(0.05))))
            .overlay(Capsule().strokeBorder(isSelected ? SparkVTheme.activeTabStroke : Color.clear, lineWidth: 0.5))
            .contentShape(Capsule())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .accessibilityLabel("Palette \(name), \(count) colors")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The dashed "Add" tile at the start of a palette.
private struct CPPaletteAddTile: View {
    @ObservedObject var controller: ColorPickerController
    let palette: CPPalette
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let lit = hover.isOn && controller.current != nil
        Button {
            if let current = controller.current { controller.addToPalette(current, paletteID: palette.id) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(lit ? SparkVTheme.text : SparkVTheme.textSecondary)
            .frame(width: 34, height: 44)
            .background(shape.fill(lit ? SparkVTheme.hoverFill : Color.clear))
            .overlay(shape.strokeBorder(lit ? SparkVTheme.textTertiary : SparkVTheme.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(shape)
            .animation(SparkVMotion.hover(), value: lit)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .disabled(controller.current == nil)
        .help("Add the current color to “\(palette.name)”")
        .accessibilityLabel("Add the current color to \(palette.name)")
    }
}

private struct CPPaletteSwatch: View {
    @ObservedObject var controller: ColorPickerController
    let palette: CPPalette
    let index: Int
    let color: CPColor
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let key = "palette-\(palette.id)-\(index)"
        let copied = controller.isCopied(key)
        Button {
            controller.show(color)
            controller.copy(color, as: controller.defaultFormat, feedbackKey: key)
        } label: {
            VStack(spacing: 2) {
                CPSwatchTile(color: color, corner: 6, hovered: hover.isOn)
                    .frame(width: 34, height: 30)
                    .overlay {
                        if copied {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(color.legibleText)
                        }
                    }
                Text(color.hexString.dropFirst())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 36)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: copied)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help("\(controller.text(color, controller.defaultFormat)). Click to copy.")
        .accessibilityLabel("\(color.spokenDescription). Copy")
        .contextMenu {
            CPColorContextItems(controller: controller, color: color, entry: nil)
            Divider()
            Button("Move Left") { controller.moveColor(at: index, by: -1, inPalette: palette.id) }
                .disabled(index == 0)
            Button("Move Right") { controller.moveColor(at: index, by: 1, inPalette: palette.id) }
                .disabled(index == palette.colors.count - 1)
            Button("Remove from Palette", role: .destructive) { controller.removeColor(at: index, fromPalette: palette.id) }
        }
    }
}

// MARK: - History strip

private struct CPHistoryStrip: View {
    @ObservedObject var controller: ColorPickerController

    var body: some View {
        HStack(spacing: 6) {
            Text("RECENT")
                .font(SparkVTheme.eyebrow(8.5))
                .tracking(SparkVTheme.isApple ? 0.4 : 1.2)
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
            if controller.history.isEmpty {
                Text("Your last \(ColorPickerController.historyLimit) picks show here. Click one to copy it again.")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(controller.history) { entry in
                            CPHistoryDot(controller: controller, entry: entry)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
            if controller.canUndo {
                Button("Undo") { controller.undo() }
                    .buttonStyle(CPSmallButtonStyle())
                    .help("Bring back what was just removed")
            }
            if !controller.history.isEmpty {
                CPIconButton(systemImage: "trash", help: "Clear recent colors", size: 18) {
                    controller.clearHistory()
                }
            }
        }
    }
}

private struct CPHistoryDot: View {
    @ObservedObject var controller: ColorPickerController
    let entry: CPHistoryEntry
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let key = "history-\(entry.id)"
        let copied = controller.isCopied(key)
        let isCurrent = controller.current.map { CPCollections.sameColor($0, entry.color) } ?? false
        Button {
            if NSEvent.modifierFlags.contains(.shift) {
                controller.addToPalette(entry.color)
            } else {
                controller.recopy(entry)
            }
        } label: {
            ZStack {
                CPSwatchDot(color: entry.color, size: 15)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(entry.color.legibleText)
                        .transition(.opacity)
                }
            }
            .padding(1.5)
            .overlay(Circle().strokeBorder(isCurrent ? SparkVTheme.accent : Color.clear, lineWidth: 1.2))
            .scaleEffect(hover.isOn && !SparkVMotion.reduceMotion ? 1.1 : 1)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: copied)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(helpText)
        .accessibilityLabel("\(entry.color.spokenDescription). Copy again")
        .contextMenu {
            CPColorContextItems(controller: controller, color: entry.color, entry: entry)
        }
    }

    private var helpText: String {
        var text = controller.text(entry.color, controller.defaultFormat)
        if let app = entry.appName { text += " · \(app)" }
        text += " · " + entry.date.formatted(date: .abbreviated, time: .shortened)
        return text + ". Click to copy, ⇧-click to add to the palette."
    }
}

// MARK: - Shared context menu

/// Copy As, Show, palette and contrast actions for any swatch.
struct CPColorContextItems: View {
    @ObservedObject var controller: ColorPickerController
    let color: CPColor
    let entry: CPHistoryEntry?

    var body: some View {
        Button("Show in Color Picker") { controller.show(color) }
        Menu("Copy As") {
            ForEach(CPFormat.allCases) { format in
                Button("\(format.title)  \(controller.displayText(color, format))") { controller.copy(color, as: format) }
            }
        }
        Divider()
        Button(controller.selectedPalette.map { "Add to “\($0.name)”" } ?? "Add to New Palette") {
            controller.addToPalette(color)
        }
        Button("Use as Text Color") { controller.contrast.foreground = color }
        Button("Use as Background") { controller.contrast.background = color }
        if let entry {
            Divider()
            Button("Remove from Recent", role: .destructive) { controller.delete(entry) }
        }
    }
}
