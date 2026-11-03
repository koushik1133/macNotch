import AppKit
import SwiftUI

// Shared pieces for smart content (links, emails, phones, colours, paths,
// code): the swatch, the type badge and the action buttons used by the
// stack panel, the Clipboard tab cards and the C button's menu.

extension ClipboardColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    /// Dark text reads better on light swatches.
    var isLight: Bool { 0.299 * red + 0.587 * green + 0.114 * blue > 0.62 }
}

/// A round (or rounded-square) colour sample with a checkerboard behind
/// translucent colours.
struct ClipboardColorSwatch: View {
    let color: ClipboardColor
    var size: CGFloat = 14
    var corner: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner ?? size / 2, style: .continuous)
        ZStack {
            if color.alpha < 0.999 {
                Checkerboard(cell: max(2, size / 6)).clipShape(shape)
            }
            shape.fill(color.swiftUIColor)
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75))
        .accessibilityLabel("Colour \(color.hex)")
    }
}

private struct Checkerboard: View {
    let cell: CGFloat
    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / cell)), rows = Int(ceil(size.height / cell))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color(white: 0.78)))
                }
            }
        }
    }
}

/// "Link", "Phone", "Swift"… with its symbol (a swatch for colours).
struct ClipboardSmartBadge: View {
    let content: ClipboardSmartContent
    var size: CGFloat = 8.5

    var body: some View {
        HStack(spacing: 3) {
            if case .color(let color, _) = content {
                ClipboardColorSwatch(color: color, size: size + 1)
            } else {
                Image(systemName: content.symbol).font(.system(size: size - 0.5, weight: .bold))
            }
            Text(content.label).font(.system(size: size, weight: .semibold))
        }
        .foregroundStyle(Self.tint(for: content))
        .lineLimit(1)
        .fixedSize()
    }

    static func tint(for content: ClipboardSmartContent) -> Color {
        if SparkVTheme.isApple {
            // Apple: each detected type in its own system color, like data detectors.
            switch content {
            case .link: return SparkVTheme.link
            case .email: return Color.cyan
            case .phone: return Color.green
            case .filePath: return Color.orange
            case .code: return Color(red: 0.75, green: 0.55, blue: 1.0)
            case .color: return Color.white.opacity(0.75)
            }
        }
        switch content {
        // Links are the brand red; every other type stays neutral.
        case .link: return SparkVTheme.red
        case .email, .phone, .filePath, .code: return SparkVTheme.textSecondary
        case .color: return Color.white.opacity(0.75)
        }
    }
}

/// Capsule buttons for a smart item's actions ("Open", "Call via FaceTime",
/// "Copy as RGB"…).
struct ClipboardSmartActionRow: View {
    @EnvironmentObject private var clipboard: ClipboardController
    let item: ClipboardItem
    var limit = 3
    var height: CGFloat = 20
    /// Shown before the first action's title ("⌘O").
    var firstShortcut: String? = nil
    /// Runs after an action (the stack panel closes itself).
    var after: (() -> Void)? = nil

    var body: some View {
        let actions = Array(clipboard.smartActions(for: item).prefix(limit))
        if !actions.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    ClipboardSmartChip(action: action, height: height, shortcut: index == 0 ? firstShortcut : nil) {
                        clipboard.perform(action, for: item)
                        after?()
                    }
                }
            }
        }
    }
}

struct ClipboardSmartChip: View {
    let action: ClipboardSmartAction
    var height: CGFloat = 20
    var shortcut: String? = nil
    let run: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: action.symbol).font(.system(size: height * 0.42, weight: .semibold))
                Text(action.title).font(.system(size: height * 0.5, weight: .semibold))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: height * 0.42, weight: .medium))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, height * 0.42)
            .frame(height: height)
            .background(Capsule().fill(hover.isOn ? (SparkVTheme.isApple ? Color.white.opacity(0.22) : SparkVTheme.red) : SparkVTheme.surfaceHover))
            .overlay(Capsule().strokeBorder(hover.isOn ? Color.clear : SparkVTheme.stroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(action.title)
        .accessibilityLabel(action.title)
    }
}

extension ClipboardSmartAction {
    /// NSMenu entry that runs the action.
    @MainActor
    func menuItem(for item: ClipboardItem, clipboard: ClipboardController) -> NSMenuItem {
        TrayMenuItem(title, systemImage: symbol) { clipboard.perform(self, for: item) }
    }
}
