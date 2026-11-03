import AppKit
import SwiftUI

// Building blocks for the Look & Layout settings sections and window, in
// both looks. Text uses the scaled theme fonts, so it follows Text Size.

/// A settings card: title, one-line explanation, content.
struct LookPanelCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let content: Content

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(SparkVTheme.font(12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.choose(apple: SparkVTheme.textSecondary, sparkv: SparkVTheme.accentText))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SparkVTheme.Scaled.headline(13))
                        .foregroundStyle(SparkVTheme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(SparkVTheme.font(11))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(SparkVTheme.surface))
        .overlay(shape.strokeBorder(SparkVTheme.choose(apple: SparkVTheme.highContrast ? SparkVTheme.stroke : Color.white.opacity(0.05),
                                                       sparkv: SparkVTheme.stroke)))
        .accessibilityElement(children: .contain)
    }
}

/// A labeled row: label (and an optional note) on the left, control on the right.
struct LookRow<Control: View>: View {
    let label: String
    var note: String? = nil
    let control: Control

    init(_ label: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(SparkVTheme.font(12, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                if let note {
                    Text(note)
                        .font(SparkVTheme.font(10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .accessibilityElement(children: .combine)
    }
}

/// A caption under a group of controls.
struct LookNote: View {
    let text: String
    var systemImage: String? = nil

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(SparkVTheme.font(10.5))
        .foregroundStyle(SparkVTheme.textTertiary)
    }
}

/// A thin divider in the theme's stroke color.
struct LookDivider: View {
    var body: some View {
        Rectangle().fill(SparkVTheme.stroke).frame(height: 1).accessibilityHidden(true)
    }
}

/// On/Off pill for a live system switch (Increase Contrast, ...).
struct LookStatusPill: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            SparkVStatusDot(kind: isOn ? .good : .idle, color: isOn ? SparkVTheme.success : SparkVTheme.textTertiary, size: 6, label: "")
            Text(isOn ? "On" : "Off")
                .font(SparkVTheme.font(10.5, weight: .semibold))
                .foregroundStyle(isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(isOn ? SparkVTheme.success.opacity(0.16) : SparkVTheme.surface))
        .accessibilityLabel(isOn ? "On" : "Off")
    }
}

/// A chip that toggles something on and off (header controls, hidden tiles).
struct LookToggleChip: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    let isOn: Bool
    var isEnabled = true
    /// Trailing glyph; nil shows a checkmark while on.
    var trailingSymbol: String? = nil
    var help: String? = nil
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(SparkVTheme.font(10.5, weight: .semibold))
                    .foregroundStyle(glyphColor)
                Text(title)
                    .font(SparkVTheme.font(11, weight: isOn ? .semibold : .medium))
                    .foregroundStyle(isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .lineLimit(1)
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(SparkVTheme.font(8.5, weight: .bold))
                        .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                        .accessibilityHidden(true)
                } else if isOn {
                    Image(systemName: "checkmark")
                        .font(SparkVTheme.font(8.5, weight: .bold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: SparkVTheme.scaledSize(24))
            .background(Capsule().fill(isOn ? LabsBStyle.selectedFill : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(isOn ? LabsBStyle.selectedStroke : LabsBStyle.chipStroke, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(!isEnabled)
        .onHover { hover.isOn = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var glyphColor: Color {
        if let tint, SparkVTheme.usesTileTints { return isOn ? tint : tint.opacity(0.6) }
        return isOn ? SparkVTheme.choose(apple: SparkVTheme.text, sparkv: SparkVTheme.accentText) : SparkVTheme.textTertiary
    }
}

// MARK: - Header preview

/// The drawer header as it will draw, in miniature: controls left of the
/// camera housing, the housing, controls and pins to the right, the gear.
/// Each side shows its six slots, so a full side is plain to see.
struct LookHeaderPreview: View {
    let header: HeaderLayout
    var recording = false

    var body: some View {
        let placement = header.placement(recording: recording)
        let pins = Set(header.pins)
        HStack(spacing: 0) {
            side(placement.left, pins: pins, capacity: HeaderCatalog.capacity(.left), trailingGear: false)
            // The camera housing (185 of 508 pt).
            Capsule()
                .fill(Color(white: 0.11))
                .overlay(
                    Circle().fill(Color(white: 0.2)).frame(width: 5, height: 5)
                        .overlay(Circle().fill(Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.6)).frame(width: 2, height: 2))
                )
                .frame(width: 92, height: 16)
                .padding(.horizontal, 10)
                .accessibilityLabel("Camera housing")
            side(placement.right, pins: pins, capacity: HeaderCatalog.capacity(.right), trailingGear: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 4, bottomLeading: 16, bottomTrailing: 16, topTrailing: 4), style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 4, bottomLeading: 16, bottomTrailing: 16, topTrailing: 4), style: .continuous)
                .strokeBorder(SparkVTheme.stroke)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(placement))
    }

    private func side(_ ids: [String], pins: Set<String>, capacity: Int, trailingGear: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(ids, id: \.self) { id in
                glyph(for: id, pinned: pins.contains(id))
            }
            ForEach(0..<max(0, capacity - ids.count), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 20, height: 18)
            }
            if trailingGear {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 20, height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: trailingGear ? .trailing : .leading)
    }

    @ViewBuilder
    private func glyph(for id: String, pinned: Bool) -> some View {
        if let item = HeaderCatalog.info(id) {
            Image(systemName: item.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(id == "record" ? Color.red : Color.white.opacity(0.75))
                .frame(width: 20, height: 18)
        } else if let tile = HubCatalog.info(id) {
            Image(systemName: tile.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.usesTileTints ? tile.tint : SparkVTheme.accentText)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "pin.fill").font(.system(size: 5.5, weight: .bold)).foregroundStyle(Color.white.opacity(0.8))
                        .rotationEffect(.degrees(35)).offset(x: 1, y: -1)
                }
        }
    }

    private func accessibilitySummary(_ placement: (left: [String], right: [String])) -> String {
        func names(_ ids: [String]) -> String {
            ids.map { HeaderCatalog.info($0)?.title ?? HubCatalog.info($0)?.title ?? $0 }.joined(separator: ", ")
        }
        return "Header preview. Left: \(names(placement.left)). Right: \(names(placement.right)), Settings."
    }
}

/// Six dots per side: filled for used slots.
struct LookSlotMeter: View {
    let used: Int
    let capacity: Int
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(SparkVTheme.font(10.5, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
            HStack(spacing: 3) {
                ForEach(0..<capacity, id: \.self) { index in
                    Capsule()
                        .fill(index < used ? SparkVTheme.choose(apple: Color.white.opacity(0.8), sparkv: SparkVTheme.accentText) : SparkVTheme.surfaceHover)
                        .frame(width: 10, height: 4)
                }
            }
            Text("\(used)/\(capacity)")
                .font(SparkVTheme.font(10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(used >= capacity ? SparkVTheme.text : SparkVTheme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(used) of \(capacity) slots used")
    }
}

/// A round accent swatch with a selection ring.
struct LookAccentSwatch: View {
    let color: Color
    let title: String
    let isSelected: Bool
    var split: Color? = nil
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            ZStack {
                if let split {
                    Circle().fill(AngularGradient(colors: [color, color, split, split, color], center: .center, angle: .degrees(-45)))
                } else {
                    Circle().fill(color)
                }
                Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                if isSelected {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                }
            }
            .frame(width: 20, height: 20)
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? SparkVTheme.text : (hover.isOn ? SparkVTheme.stroke : Color.clear), lineWidth: 1.5))
            .scaleEffect(hover.isOn && !isSelected ? 1.06 : 1)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The custom accent: a hue wheel until a custom color is picked, then that
/// color. A click opens the macOS color panel; picking a color makes it the
/// accent.
struct LookCustomAccentSwatch: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let selected = appearance.accent == .custom
        Button {
            LookColorPanel.shared.open()
        } label: {
            ZStack {
                if selected {
                    Circle().fill(appearance.customAccent.color)
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                }
                Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: 20, height: 20)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? SparkVTheme.text : (hover.isOn ? SparkVTheme.stroke : Color.clear), lineWidth: 1.5))
            .scaleEffect(hover.isOn && !selected ? 1.06 : 1)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(selected ? "Custom accent \(appearance.customAccent.hex). Click to change." : "Pick a custom accent color")
        .accessibilityLabel("Custom accent color")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Bridges the shared NSColorPanel to the custom accent, for one session at
/// a time. The panel is shared with every other color control in the app
/// (the Modes editor's color wells), so SparkV's accent only listens while
/// its own session is open: the session ends when the panel closes or when
/// another window (not the panel, not the one the swatch is in) becomes key,
/// and the target and action are cleared then. Changes commit once the
/// pointer lets go (`isContinuous = false`), as one change.
@MainActor
final class LookColorPanel: NSObject {
    static let shared = LookColorPanel()

    /// True while the panel edits the custom accent.
    private(set) var isSessionOpen = false
    private weak var hostWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func open() {
        let panel = NSColorPanel.shared
        endSession()
        panel.showsAlpha = false
        panel.isContinuous = false
        // Set the color before taking the target: setting it sends the action.
        panel.color = NSColor(AppearanceSettings.shared.customAccent.color)
        hostWindow = NSApp.keyWindow
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        isSessionOpen = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { LookColorPanel.shared.endSession() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { LookColorPanel.shared.keyWindowChanged(to: window) }
        })
        panel.orderFront(nil)
    }

    /// Stops listening; the panel goes back to whoever uses it next.
    func endSession() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard isSessionOpen else { return }
        isSessionOpen = false
        hostWindow = nil
        // Color wells don't use the panel's target, so clearing it never
        // takes the panel from them.
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    private func keyWindowChanged(to window: NSWindow?) {
        guard isSessionOpen, let window else { return }
        if window === NSColorPanel.shared || window === hostWindow { return }
        endSession()
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard isSessionOpen, let rgb = LookRGB.resolved(sender.color) else { return }
        AppearanceSettings.shared.setCustomAccent(rgb)
    }
}
