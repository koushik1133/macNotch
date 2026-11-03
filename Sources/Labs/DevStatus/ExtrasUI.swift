import AppKit
import SwiftUI

// Shared building blocks for the Developer & Extras labs (DevStatus,
// Teleprompter, MenuBarOverflow and the camera mirror): settings cards, rows,
// a drawn switch, a segmented control, hub-tile faces, status pills and a
// copyable code block. Both looks resolve through SparkVTheme; motion goes
// through SparkVMotion.

// MARK: - Settings

/// A settings card: icon, title, subtitle, then its rows.
struct ExtrasSettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.isApple ? SparkVTheme.textSecondary : SparkVTheme.red)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SparkVTheme.headline(13))
                        .tracking(-0.2)
                        .foregroundStyle(SparkVTheme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .fill(SparkVTheme.surface.opacity(SparkVTheme.isApple ? 0.6 : 0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .strokeBorder(SparkVTheme.stroke, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A drawn switch (renders offscreen, sized for the rows): the accent fill in
/// both looks, the snappy knob spring.
struct ExtrasSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? SparkVTheme.accent : Color.white.opacity(0.18))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Title, optional detail, switch on the right; the whole row toggles.
struct ExtrasToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var indent: CGFloat = 0
    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isEnabled ? SparkVTheme.text : SparkVTheme.textTertiary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isEnabled ? SparkVTheme.textSecondary : SparkVTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            ExtrasSwitch(isOn: $isOn, label: title)
                .opacity(isEnabled ? 1 : 0.45)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .padding(.leading, indent)
        .sparkVHoverFill(hover.isOn && isEnabled, cornerRadius: 8)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.toggle() } }
        .onHover { hover.isOn = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { if isEnabled { isOn.toggle() } }
    }
}

/// A label on the left and any control on the right (pickers, steppers).
struct ExtrasControlRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
    }
}

/// Small grey note under a group (honest limits, privacy).
struct ExtrasNote: View {
    let text: String
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(SparkVTheme.textTertiary)
        .padding(.horizontal, 8)
    }
}

struct ExtrasDivider: View {
    var body: some View {
        Rectangle()
            .fill(SparkVTheme.stroke)
            .frame(height: 1)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

/// A compact segmented control in the house style: the active segment slides
/// with the strong ease-in-out (Reduce Motion: it just moves).
struct ExtrasSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let label: String
    var compact = false
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    withAnimation(SparkVMotion.reduceMotion ? nil : SparkVMotion.easeInOut(SparkVMotion.Duration.standard)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: compact ? 10.5 : 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? (SparkVTheme.isApple ? Color.white : SparkVTheme.text) : SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, compact ? 8 : 10)
                        .frame(maxWidth: .infinity, minHeight: compact ? 20 : 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(SparkVTheme.isApple ? Color.white.opacity(0.18) : SparkVTheme.redSoft)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.red.opacity(0.45), lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "segment", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SparkVPressStyle())
                .accessibilityLabel("\(label): \(option.title)")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(SparkVTheme.isApple ? 0.06 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
    }
}

/// A monospaced snippet with a Copy button (setup lines the user pastes into
/// their own tool's config; SparkV never edits those files).
struct ExtrasCodeBlock: View {
    let title: String
    let code: String
    var maxHeight: CGFloat = 150
    @StateObject private var copied = ViewFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied.isOn = true
                    Task { @MainActor [copied] in
                        try? await Task.sleep(for: .seconds(1.6))
                        copied.isOn = false
                    }
                } label: {
                    Label(copied.isOn ? "Copied" : "Copy", systemImage: copied.isOn ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .contentTransition(.opacity)
                }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .accessibilityLabel("Copy \(title)")
            }
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(code)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SparkVTheme.text.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Drawer pieces

/// Small status capsule ("Working", "Needs you", ":3000").
struct ExtrasPill: View {
    let text: String
    var tint: Color = SparkVTheme.textSecondary
    var filled = false
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(filled ? tint : tint.opacity(0.16)))
        .fixedSize()
    }
}

/// A round 22 pt icon button for drawer rows: hover fill, press scale.
struct ExtrasIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color? = nil
    var size: CGFloat = 22
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint ?? (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary))
                .frame(width: size, height: size)
                .background(Circle().fill(SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0)))
                .contentShape(Circle())
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A small capsule action in a drawer row or band ("Allow", "Deny", "Open").
struct ExtrasCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = false
    var tint: Color? = nil
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let fill: Color = prominent ? (tint ?? SparkVTheme.accent) : Color.white.opacity(hover.isOn ? 0.2 : 0.12)
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9.5, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.white : (tint ?? SparkVTheme.text))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(fill))
            .overlay(Capsule().fill(Color.white.opacity(prominent && hover.isOn ? 0.1 : 0)))
            .contentShape(Capsule())
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .fixedSize()
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(title)
    }
}

/// An empty or off state in a drawer well: symbol, two lines, an action.
struct ExtrasNotice: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(SparkVPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The drawer well every Extras tab draws its content in.
struct ExtrasWell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                    .fill(SparkVTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                    .strokeBorder(SparkVTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
    }
}

// MARK: - Hub tile face

/// The Agents hub tile look (48 pt, Control Center style in Apple; monochrome
/// lit red in SparkV Red), shared by every Extras tile.
struct ExtrasHubTileFace: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isActive = false
    /// A small count badge in the corner (running agents, hidden icons).
    var badge: String? = nil
    var badgeTint: Color? = nil
    var help: String? = nil
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LabsBHubTileBackground.glyph(isActive: isActive, isHovered: hover.isOn, tint: tint))
                Text(title)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(LabsBHubTileBackground.label(isActive: isActive, isHovered: hover.isOn))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
            .background(LabsBHubTileBackground(isActive: isActive, isHovered: hover.isOn, tint: tint))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(badgeTint ?? SparkVTheme.accent))
                        .padding(4)
                        .transition(.opacity.combined(with: .scale(scale: SparkVMotion.enterScale)))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: badge)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityHint(help ?? "")
    }
}

// MARK: - Small helpers

/// The display directly under the camera: the first with a notch, else the
/// main display.
@MainActor
enum ExtrasScreens {
    static var notched: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static var notchedOrMain: NSScreen? {
        notched ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// A screen by its CGDirectDisplayID (stored as a number), if attached.
    static func screen(displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Hosting view for SparkV's floating, non-activating panels: the first
/// click acts (the panel never becomes key, so typing stays where it is).
final class ExtrasPanelHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The end of an Extras hub tile's right-click menu: the hub's own Pin /
/// Hide / Move / Customize items, when the tile sits in the hub.
struct ExtrasHubMenuTail: View {
    let hubID: String?

    var body: some View {
        if let hubID {
            Divider()
            HubTileMenuItems(id: hubID)
        }
    }
}
