import AppKit
import SwiftUI

extension Color {
    /// sRGB when the color fits, Display P3 otherwise (wide-gamut picks
    /// render as picked on a P3 screen).
    init(cp color: CPColor) {
        if color.isInSRGBGamut {
            let c = color.clamped
            self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        } else {
            let p = color.displayP3
            self.init(.displayP3, red: CPMath.clamp01(p.r), green: CPMath.clamp01(p.g), blue: CPMath.clamp01(p.b), opacity: color.alpha)
        }
    }
}

extension CPColor {
    /// Black or white, whichever reads better on this color.
    var legibleText: Color {
        CPContrast.ratio(.white, self) >= CPContrast.ratio(.black, self) ? .white : Color(white: 0.08)
    }

    /// "Blue, #3B82F6" for VoiceOver.
    var spokenDescription: String {
        "\(CPColorFamily.name(self)), \(hexString.dropFirst().map { String($0) }.joined(separator: " "))"
    }
}

/// A round swatch with a hairline so dark colors stay visible on black.
struct CPSwatchDot: View {
    let color: CPColor
    var size: CGFloat = 14

    var body: some View {
        Circle()
            .fill(Color(cp: color))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .frame(width: size, height: size)
    }
}

/// A rounded swatch, the shape used in rows and palettes.
struct CPSwatchTile: View {
    let color: CPColor
    var corner: CGFloat = 6
    var selected = false
    /// Hover: a brighter rim (the accent ring stays for selection).
    var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape
            .fill(Color(cp: color))
            .overlay(shape.strokeBorder(Color.white.opacity(hovered ? 0.42 : 0.14), lineWidth: 1))
            .overlay(
                shape.inset(by: -2).strokeBorder(selected ? SparkVTheme.accent : Color.clear, lineWidth: 1.5)
            )
    }
}

/// Small icon button (16 pt glyph area) with hover fill and press feedback.
struct CPIconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 20
    var tint: Color? = nil
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint ?? (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary))
                .frame(width: size, height: size)
                .sparkVHoverFill(hover.isOn, cornerRadius: 6)
                .contentShape(Rectangle())
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An icon that opens a menu, with the same hover fill as `CPIconButton`
/// (a menu opens on mouse-down, so it needs no press scale).
struct CPMenuButton<Items: View>: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 20
    @ViewBuilder let items: () -> Items

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: (size * 0.6).rounded(), weight: .medium))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: size, height: size)
        .sparkVHoverFill(hover.isOn, cornerRadius: 6)
        .contentShape(Rectangle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Compact text button for the drawer header and inline confirmations.
struct CPSmallButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        CPSmallButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }
}

private struct CPSmallButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let destructive: Bool
    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.isApple ? 6 : 5, style: .continuous)
        let fill: Color = if destructive {
            SparkVTheme.destructive.opacity(configuration.isPressed ? 0.7 : 1)
        } else if prominent {
            SparkVTheme.accent.opacity(configuration.isPressed ? 0.78 : 1)
        } else {
            Color.white.opacity(configuration.isPressed ? 0.2 : (hover.isOn ? 0.15 : 0.09))
        }
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(prominent || destructive ? Color.white : SparkVTheme.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(shape.fill(fill))
            .overlay(shape.fill(Color.white.opacity((prominent || destructive) && hover.isOn && !configuration.isPressed ? 0.08 : 0)))
            .overlay(shape.strokeBorder(SparkVTheme.isApple || prominent || destructive ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .modifier(LiveBandPressEffect(isPressed: configuration.isPressed))
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .onHover { hover.isOn = $0 }
    }
}

/// Pass / fail chip: never color alone, always ✓ / ✕ text.
struct CPLevelBadge: View {
    let title: String
    let passes: Bool
    var help: String = ""

    var body: some View {
        HStack(spacing: 2) {
            Text(passes ? "✓" : "✕")
                .font(.system(size: 9, weight: .heavy))
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(passes ? SparkVTheme.success : SparkVTheme.textSecondary)
        .padding(.horizontal, 5)
        .frame(height: 15)
        .background(
            Capsule().fill(passes ? SparkVTheme.success.opacity(0.16) : Color.white.opacity(0.07))
        )
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(passes ? "passes" : "fails")")
    }
}
