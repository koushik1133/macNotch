import AppKit
import SwiftUI

// Modes in the notch: the hub tile, the drawer strip, the gear submenu and the
// band shown while a mode is on. Everything reads and drives
// `ModeEngine.shared`; the editor lives in ModeEditorWindow.swift.

// MARK: - Colors and small helpers

enum ModeColors {
    /// The colors offered for a mode (the same family Apple uses for Focus).
    static let swatches = [
        "#5E5CE6", "#0A84FF", "#64D2FF", "#30D158", "#FFD60A", "#FF9F0A",
        "#FF453A", "#FF375F", "#BF5AF2", "#AC8E68", "#8E8E93",
    ]

    static func color(_ hex: String) -> Color { Color(nsColor: nsColor(hex)) }

    static func nsColor(_ hex: String) -> NSColor {
        ModeRGBColor(hex: hex)?.nsColor ?? NSColor(SparkVTheme.accent)
    }

    static func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#5E5CE6" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    static func binding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { color(hex.wrappedValue) }, set: { hex.wrappedValue = Self.hex($0) })
    }
}

/// A mode's round icon: its symbol on its color.
struct ModeBadge: View {
    let symbol: String
    let colorHex: String
    var size: CGFloat = 24
    /// Filled while the mode is on; a tinted outline look otherwise.
    var filled = true

    var body: some View {
        let tint = ModeColors.color(colorHex)
        ZStack {
            Circle().fill(filled ? tint : tint.opacity(0.22))
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
        }
        .frame(width: size, height: size)
    }
}

/// "42 min", "1 h 5 min" or "18 min left" for the active mode, from the
/// engine's `activeSince` and `endsAt`.
enum ModeStatusText {
    static func text(since start: Date?, endsAt: Date?, now: Date = Date()) -> String {
        if let endsAt {
            let left = max(0, Int((endsAt.timeIntervalSince(now) / 60).rounded(.up)))
            return left < 1 ? "Ending" : "\(duration(left)) left"
        }
        guard let start else { return "" }
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        return minutes < 1 ? "Just now" : duration(minutes)
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}

// MARK: - Hub tile

/// The Modes tile for the agents hub, 54 pt tall like the other tiles. Shows
/// the active mode in its color; a click lists the modes to switch to.
/// With `onOpen`, a click opens that page instead and the list moves to the
/// right-click menu.
struct ModesHubTile: View {
    @ObservedObject var engine: ModeEngine = .shared
    var onOpen: (() -> Void)?
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { face }
                    .buttonStyle(SparkVPressStyle())
                    .contextMenu { ModesMenuItems(engine: engine) }
            } else {
                Menu { ModesMenuItems(engine: engine) } label: { face }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
            }
        }
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(engine.activeMode.map { "\($0.name) is on. Click to switch or stop." }
              ?? "Modes: one click sets your wallpaper, music, apps and Do Not Disturb")
    }

    private var face: some View {
        let mode = engine.activeMode
        // Apple: the active mode's own color, indigo while none is on.
        let tint = mode.map { ModeColors.color($0.colorHex) } ?? Color.indigo
        return VStack(spacing: 5) {
            Image(systemName: mode?.symbol ?? "switch.2")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LabsBHubTileBackground.glyph(isActive: mode != nil, isHovered: hover.isOn, tint: tint))
            // Tiles are ~58 pt wide in the 8-column hub: "Concentration"
            // needs to shrink a little more than the other tiles' labels.
            Text(mode?.name ?? "Modes")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LabsBHubTileBackground.label(isActive: mode != nil, isHovered: hover.isOn))
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(LabsBHubTileBackground(isActive: mode != nil, isHovered: hover.isOn, tint: tint))
        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
    }
}

// MARK: - Menu items

/// Mode list for any menu (gear submenu, hub tile, context menus): one
/// checkable item per mode, then Stop and Edit Modes.
struct ModesMenuItems: View {
    @ObservedObject var engine: ModeEngine = .shared

    var body: some View {
        ForEach(engine.modes) { mode in
            Toggle(isOn: Binding(
                get: { engine.activeModeID == mode.id },
                set: { _ in Task { await engine.toggle(mode.id) } }
            )) {
                Label(mode.name, systemImage: mode.symbol)
            }
        }
        if engine.modes.isEmpty {
            Text("No Modes Yet")
        }
        Divider()
        if let active = engine.activeMode {
            Button("Stop \(active.name)") { Task { await engine.deactivate() } }
        }
        Button("Edit Modes…") { ModeEditorWindowController.shared.show(selecting: engine.activeModeID) }
    }
}

// MARK: - Drawer strip

/// A strip of mode chips for the drawer (508 x 69 pt). Click a chip to turn
/// that mode on (or off again); the active one is filled in its color, with
/// a Stop button on the right.
struct ModesDrawerView: View {
    @ObservedObject var engine: ModeEngine = .shared

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(engine.modes) { mode in
                        ModeChip(mode: mode, isActive: engine.activeModeID == mode.id) {
                            Task { await engine.toggle(mode.id) }
                        }
                    }
                    if engine.modes.isEmpty {
                        Text("No modes yet. Click Edit to make one.")
                            .font(.system(size: 11))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .padding(.leading, 6)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)
            trailing
        }
        .frame(width: 508, height: 69)
    }

    @ViewBuilder private var trailing: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let active = engine.activeMode {
                Button {
                    Task { await engine.deactivate() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(SparkVTheme.destructive))
                }
                .buttonStyle(SparkVPressStyle())
                .help(active.restoreOnExit ? "Stop \(active.name) and put your setup back" : "Stop \(active.name)")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(ModeStatusText.text(since: engine.activeSince, endsAt: engine.endsAt, now: context.date))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            } else {
                ModeStripIconButton(systemImage: "slider.horizontal.3", help: "Edit Modes") {
                    ModeEditorWindowController.shared.show()
                }
            }
        }
        .frame(width: 66, alignment: .trailing)
    }
}

/// One mode in the drawer strip, 66 x 58 pt (six fit beside Stop).
struct ModeChip: View {
    let mode: SparkMode
    let isActive: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ModeBadge(symbol: mode.symbol, colorHex: mode.colorHex, size: 26, filled: isActive)
                Text(mode.name)
                    .font(.system(size: 10, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive || hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 4)
            .frame(width: 66, height: 58)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                    .fill(isActive ? LabsBStyle.activeCardFill(ModeColors.color(mode.colorHex)) : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                    .strokeBorder(isActive ? SparkVTheme.choose(apple: ModeColors.color(mode.colorHex).opacity(0.45), sparkv: SparkVTheme.red.opacity(0.8)) : LabsBStyle.chipStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(isActive ? "Turn \(mode.name) off" : "Turn \(mode.name) on")
        .contextMenu {
            Button(isActive ? "Turn Off" : "Turn On", action: action)
            Button("Edit \(mode.name)…") { ModeEditorWindowController.shared.show(selecting: mode.id) }
        }
    }
}

private struct ModeStripIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
                .overlay(Circle().strokeBorder(LabsBStyle.chipStroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
    }
}

// MARK: - Live activity band

/// The band under the notch while a mode is on: "Concentration on · 42 min".
/// Lays out in about 360 x 30 pt on the dark band.
struct ModeActivityView: View {
    @ObservedObject var engine: ModeEngine = .shared

    var body: some View {
        if let mode = engine.activeMode {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 8) {
                    ModeBadge(symbol: mode.symbol, colorHex: mode.colorHex, size: 18)
                    (Text(mode.name).fontWeight(.semibold).foregroundColor(SparkVTheme.text)
                     + Text(" on").foregroundColor(SparkVTheme.textSecondary))
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !engine.failures.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(SparkVTheme.warning)
                            .help(engine.failures.map(\.text).joined(separator: "\n"))
                    }
                    Text(engine.isBusy ? "Setting up…" : ModeStatusText.text(since: engine.activeSince, endsAt: engine.endsAt, now: context.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
