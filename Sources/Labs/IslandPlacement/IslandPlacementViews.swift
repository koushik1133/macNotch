import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings sections (no arguments; they read the shared settings and the
// running placement controller), the gear menu items, and the Agents hub
// tile. Panes: see INTEGRATION.md.

// MARK: - Shared pieces

/// One Settings section: a `Section` with the title (and subtitle) in its
/// header and the content as one row, so it sits in the Settings window's
/// grouped Form like every other package's section, without a card of its
/// own nested in the row. The standalone window hosts the same Form.
private struct IslandSettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            header
        }
    }

    private var header: some View {
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
            .padding(.bottom, 2)
    }
}

/// A drawn switch: the accent fill in both looks, the snappy knob spring
/// (renders offscreen, unlike the native one, and sized for the rows).
struct IslandSwitch: View {
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
        .accessibilityAddTraits(.isToggle)
    }
}

/// Title, optional detail line, switch on the right; the whole row toggles.
private struct IslandToggleRow: View {
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
            IslandSwitch(isOn: $isOn, label: title)
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

/// A compact segmented control in the house style (the active segment
/// slides with the strong ease-in-out; Reduce Motion: it just moves).
private struct IslandSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let label: String
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
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? (SparkVTheme.isApple ? Color.white : SparkVTheme.text) : SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 22)
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

/// Small grey note under a group (honest limits, privacy).
private struct IslandNote: View {
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
        // Secondary, not tertiary: these notes carry the honest limits.
        .foregroundStyle(SparkVTheme.textSecondary)
        .padding(.horizontal, 8)
    }
}

/// The running controller, observed when there is one (settings can open
/// before the island exists, e.g. in a test harness).
@MainActor
private final class IslandControllerBox: ObservableObject {
    @Published private(set) var controller: IslandPlacementController?
    private var token: Any?

    init() {
        controller = IslandPlacementController.current
        token = controller?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

private func displayIcon(_ display: IslandDisplayInfo) -> String {
    display.isBuiltIn ? "laptopcomputer" : "display"
}

private func displayDetail(_ display: IslandDisplayInfo) -> String {
    var parts: [String] = []
    parts.append(display.isBuiltIn ? "Built-in" : "External display")
    if display.hasNotch { parts.append("notch") }
    if display.isMain { parts.append("main display") }
    return parts.joined(separator: " · ").capitalizedFirst
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - Display (Island pane)

/// Which display shows the island: Automatic, Built-in Only, Main, a
/// specific display (remembered across replugs), Follow the Pointer or All
/// Displays; plus how snugly it wraps the notch.
struct IslandDisplaySettingsSection: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared
    @StateObject private var box = IslandControllerBox()

    private var displays: [IslandDisplayInfo] {
        box.controller?.displays ?? IslandDisplays.current()
    }

    var body: some View {
        IslandSettingsCard(title: "Display", subtitle: box.controller?.statusLine ?? "Where the island lives.", systemImage: "display.2") {
            VStack(spacing: 2) {
                modeRow(.automatic)
                modeRow(.builtIn)
                modeRow(.main)
                ForEach(displays) { display in
                    displayRow(display)
                }
                if let missing = missingSavedDisplay {
                    missingRow(missing)
                }
                modeRow(.followPointer)
                modeRow(.allDisplays)
            }
            if displays.contains(where: \.hasNotch) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Notch Fit")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SparkVTheme.text)
                        Spacer()
                        IslandSegmented(
                            options: IslandNotchFit.allCases.map { ($0, $0.title) },
                            selection: $settings.notchFit,
                            label: "Notch fit"
                        )
                        .frame(width: 210)
                    }
                    IslandNote(text: fitNote)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
    }

    private var fitNote: String {
        let housing = Int(NotchMetrics.cameraHousingWidth.rounded())
        return settings.notchFit == .snug
            ? "At rest the island is exactly the \(housing) pt camera housing, so it looks like the hardware notch."
            : "Measured from this Mac’s screen: a \(housing) pt camera housing plus a slim shoulder each side."
    }

    private var missingSavedDisplay: String? {
        guard settings.displayMode == .specific, let uuid = settings.displayUUID,
              !displays.contains(where: { $0.uuid == uuid }) else { return nil }
        return settings.displayName ?? "Saved display"
    }

    private func modeRow(_ mode: IslandDisplayMode) -> some View {
        IslandChoiceRow(
            systemImage: icon(for: mode),
            title: mode.title,
            detail: mode.summary,
            isSelected: settings.displayMode == mode,
            isDisabled: mode == .builtIn && !displays.contains(where: \.isBuiltIn) && settings.displayMode != .builtIn
        ) {
            settings.choose(mode)
        }
    }

    private func displayRow(_ display: IslandDisplayInfo) -> some View {
        IslandChoiceRow(
            systemImage: displayIcon(display),
            title: display.name,
            detail: displayDetail(display) + (box.controller?.islandDisplayID == display.id ? " · island is here" : ""),
            isSelected: settings.displayMode == .specific && settings.displayUUID == display.uuid
        ) {
            settings.choose(display: display)
        }
    }

    private func missingRow(_ name: String) -> some View {
        IslandChoiceRow(
            systemImage: "display.trianglebadge.exclamationmark",
            title: "\(name) (not connected)",
            detail: "Waiting on another display. The island goes back when it reconnects.",
            isSelected: true
        ) {}
    }

    private func icon(for mode: IslandDisplayMode) -> String {
        switch mode {
        case .automatic: "wand.and.stars"
        case .builtIn: "laptopcomputer"
        case .main: "menubar.rectangle"
        case .specific: "display"
        case .followPointer: "cursorarrow.motionlines"
        case .allDisplays: "rectangle.on.rectangle"
        }
    }
}

/// A radio-style row: icon, title, detail, checkmark when chosen.
private struct IslandChoiceRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let isSelected: Bool
    var isDisabled = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? SparkVTheme.accent : SparkVTheme.textSecondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? SparkVTheme.accent : SparkVTheme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? SparkVTheme.accentSoft.opacity(SparkVTheme.isApple ? 0.55 : 0.8) : SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0))
            )
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Style (Appearance pane)

/// Selected display in the style section (no @State).
@MainActor
private final class IslandStyleSelection: ObservableObject {
    @Published var uuid: String?
}

/// Notch, Pill or Minimal per display, the pill's height and top margin,
/// Minimal's hairline, and what happens when the menu bar hides.
struct IslandStyleSettingsSection: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared
    @StateObject private var box = IslandControllerBox()
    @StateObject private var selection = IslandStyleSelection()

    private var displays: [IslandDisplayInfo] {
        box.controller?.displays ?? IslandDisplays.current()
    }

    private var selected: IslandDisplayInfo? {
        let list = displays
        if let uuid = selection.uuid, let match = list.first(where: { $0.uuid == uuid }) { return match }
        if let id = box.controller?.islandDisplayID, let match = list.first(where: { $0.id == id }) { return match }
        return list.first
    }

    var body: some View {
        IslandSettingsCard(title: "Island Style", subtitle: "Each display remembers its own style.", systemImage: "paintpalette") {
            if displays.count > 1 {
                HStack(spacing: 8) {
                    Text("Display")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SparkVTheme.text)
                    IslandSegmented(
                        options: displays.map { ($0.uuid, $0.name) },
                        selection: Binding(get: { selected?.uuid ?? "" }, set: { selection.uuid = $0 }),
                        label: "Display"
                    )
                }
                .padding(.horizontal, 8)
            }
            if let display = selected {
                let current = settings.preset(for: display)
                HStack(spacing: 8) {
                    ForEach(IslandStylePreset.allCases) { preset in
                        IslandStyleCard(preset: preset, hasNotch: display.hasNotch, isSelected: current == preset) {
                            withAnimation(SparkVMotion.respecting(SparkVMotion.snappy)) {
                                settings.setPreset(preset, for: display)
                            }
                        }
                    }
                }
                // A notched display in Notch style has no further options.
                if !(display.hasNotch && current == .notch) {
                    options(for: display, preset: current)
                }
            } else {
                IslandNote(text: "No display found.")
            }
        }
    }

    @ViewBuilder
    private func options(for display: IslandDisplayInfo, preset: IslandStylePreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !display.hasNotch, preset != .notch {
                IslandSliderRow(title: preset == .minimal ? "Height" : "Pill Height", value: $settings.pillHeight,
                                range: Double(IslandGeometry.pillHeightRange.lowerBound)...Double(IslandGeometry.pillHeightRange.upperBound))
                IslandSliderRow(title: "Top Margin", value: $settings.pillTopMargin,
                                range: Double(IslandGeometry.pillTopMarginRange.lowerBound)...Double(IslandGeometry.pillTopMarginRange.upperBound))
                IslandNote(text: "0 pt touches the top edge. About 30 pt floats it below the menu bar, like the Dynamic Island; pushing the pointer to the top edge still opens it, and open it reaches the edge.")
            }
            if display.hasNotch, preset == .pill {
                IslandNote(text: "On a display with a notch the pill always wraps the camera, so it hugs the top edge.")
            }
            if preset == .minimal {
                IslandToggleRow(title: "Show a Hairline", detail: "A faint line at the top marks where the island appears. Not needed on a display with a notch.",
                                isOn: $settings.minimalHairline)
                    .disabled(display.hasNotch)
            }
            if !display.hasNotch {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When the Menu Bar Hides")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SparkVTheme.text)
                        Text("With “Automatically hide the menu bar”, push the pointer to the top to bring both back.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    IslandSegmented(
                        options: IslandMenuBarAutoHideBehavior.allCases.map { ($0, $0 == .hideWithMenuBar ? "Hide Too" : "Keep") },
                        selection: $settings.menuBarAutoHide,
                        label: "When the menu bar hides"
                    )
                    .frame(width: 130)
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

private struct IslandSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .frame(width: 92, alignment: .leading)
            // Whole points, without the tick marks a stepped slider draws.
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                .tint(SparkVTheme.accent)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value)) points")
            Text("\(Int(value)) pt")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 8)
    }
}

/// A selectable card with a drawn preview of the style on a menu bar.
private struct IslandStyleCard: View {
    let preset: IslandStylePreset
    let hasNotch: Bool
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 7) {
                IslandStylePreview(preset: preset, hasNotch: hasNotch)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(spacing: 1) {
                    Text(preset.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                    Text(preset.summary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(shape.fill(isSelected ? SparkVTheme.accentSoft.opacity(SparkVTheme.isApple ? 0.7 : 1) : Color.white.opacity(hover.isOn ? 0.09 : 0.04)))
            .overlay(shape.strokeBorder(isSelected ? SparkVTheme.accent : SparkVTheme.stroke, lineWidth: isSelected ? 1.5 : 1))
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(shape)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .accessibilityLabel("\(preset.title) style")
        .accessibilityHint(preset.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A tiny menu bar over a wallpaper with the style drawn in it.
struct IslandStylePreview: View {
    let preset: IslandStylePreset
    let hasNotch: Bool

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.26, green: 0.33, blue: 0.52), Color(red: 0.55, green: 0.36, blue: 0.48)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Menu bar.
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 9)
                    .frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(Color.white.opacity(0.55)).frame(width: 7, height: 2)
                    }
                    Spacer()
                    Capsule().fill(Color.white.opacity(0.55)).frame(width: 9, height: 2)
                }
                .padding(.horizontal, 5)
                .frame(height: 9)
                island(width: w)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func island(width w: CGFloat) -> some View {
        switch preset {
        case .notch:
            IslandShape(topRadius: 3, bottomRadius: 5)
                .fill(Color.black)
                .frame(width: w * 0.36 + 6, height: 11)
        case .pill:
            Capsule()
                .fill(Color.black)
                .frame(width: w * 0.34, height: hasNotch ? 11 : 8)
                .padding(.top, hasNotch ? 0 : 0.5)
        case .minimal:
            if hasNotch {
                // Only the hardware notch shows.
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3, style: .continuous)
                    .fill(Color.black)
                    .frame(width: w * 0.28, height: 9)
            } else {
                Capsule()
                    .fill(Color.black.opacity(0.6))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                    .frame(width: w * 0.14, height: 2)
                    .padding(.top, 1)
            }
        }
    }
}

// MARK: - Visibility (Island pane)

/// Full screen, clamshell, displays without a notch, Mission Control,
/// what still shows while hidden, and the ⌃⌥H shortcut.
struct IslandVisibilitySettingsSection: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared
    @StateObject private var box = IslandControllerBox()

    private var hasNotchedDisplay: Bool {
        (box.controller?.displays ?? IslandDisplays.current()).contains(where: \.hasNotch)
    }

    var body: some View {
        IslandSettingsCard(title: "Getting Out of the Way", subtitle: subtitle, systemImage: "eye.slash") {
            VStack(alignment: .leading, spacing: 2) {
                IslandToggleRow(title: "Hide in Full Screen",
                                detail: "Videos, games, slideshows and full-screen apps, only on the display that is full screen.",
                                isOn: $settings.hideInFullScreen)
                IslandToggleRow(title: "Reveal at the Top Edge",
                                detail: "Hold the pointer against the top over the notch for half a second.",
                                isOn: $settings.revealAtTopEdge, indent: 14)
                    .disabled(!settings.hideInFullScreen)
                if settings.hideInFullScreen, hasNotchedDisplay, !PermissionCenter.shared.isGranted(.accessibility) {
                    HStack(spacing: 8) {
                        IslandNote(text: "On the built-in display, a full-screen app and a zoomed window look alike. With Accessibility, SparkV can tell them apart.",
                                   systemImage: "hand.raised")
                        Spacer(minLength: 0)
                        Button("Allow…") {
                            Task { _ = await PermissionCenter.shared.request(.accessibility, from: "Island: full-screen detection") }
                        }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .accessibilityLabel("Allow Accessibility for full-screen detection")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 2)
                }

                IslandDivider()
                IslandToggleRow(title: "Show on Displays Without a Notch",
                                detail: "Off: the island only appears on a display with a camera notch.",
                                isOn: $settings.showOnDisplaysWithoutNotch)
                IslandToggleRow(title: "Hide in Clamshell Mode",
                                detail: "While the MacBook’s lid is closed and you use an external display.",
                                isOn: $settings.hideInClamshell)
                IslandToggleRow(title: "Hide in Mission Control",
                                detail: "macOS hides the island in Mission Control and Exposé, so there’s no second notch.",
                                isOn: $settings.hidesInMissionControl)

                IslandDivider()
                // Whatever hid it: full screen, an excluded app, the lid,
                // a Smart Moment or Hide for 1 Hour.
                IslandToggleRow(title: "While Hidden, Still Show Volume & Brightness",
                                detail: settings.showsHUDWhileHidden ? nil : "While SparkV replaces the macOS pop-up, it still shows, or you’d see none.",
                                isOn: $settings.showsHUDWhileHidden)
                IslandToggleRow(title: "While Hidden, Still Show Dictation & Clicky",
                                isOn: $settings.showsVoiceWhileHidden)

                IslandDivider()
                IslandToggleRow(title: "Hide and Show with \(IslandPlacementController.hotkeyLabel)",
                                detail: hotkeyDetail,
                                isOn: $settings.hotkeyEnabled)
                hideButtons
            }
        }
    }

    private var subtitle: String {
        box.controller?.statusLine ?? "The island steps aside when it would be in the way."
    }

    private var hotkeyDetail: String {
        let key = IslandPlacementController.hotkeyLabel
        if box.controller?.hotkeyUnavailable == true { return "Another app already uses \(key)." }
        var text = "Hides the island; pressed while it’s hidden, it brings it back open."
        // VO-H is VoiceOver's help menu: with VoiceOver on, both answer.
        if NSWorkspace.shared.isVoiceOverEnabled { text += " With VoiceOver on, \(key) is also VoiceOver’s Help." }
        return text
    }

    /// How a hidden island comes back early (it has no gear menu then).
    private var comeBackNote: String {
        let key = IslandPlacementController.hotkeyLabel
        if settings.hotkeyEnabled, box.controller?.hotkeyUnavailable != true {
            return "Press \(key) to bring it back sooner."
        }
        return "To bring it back sooner, open SparkV again (or its menu bar icon) and choose Settings › Island › Show the Island."
    }

    @ViewBuilder
    private var hideButtons: some View {
        if let controller = box.controller {
            HStack(spacing: 8) {
                if controller.isManuallyHidden {
                    Button("Show the Island") { controller.unhide() }
                        .buttonStyle(SparkVPrimaryButtonStyle())
                    if let until = controller.hiddenUntil {
                        Text("Hidden until \(until.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                } else {
                    Button("Hide for 1 Hour") { controller.hide(for: 3600) }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .accessibilityHint(comeBackNote)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            if !controller.isManuallyHidden {
                IslandNote(text: comeBackNote)
            }
        }
    }
}

private struct IslandDivider: View {
    var body: some View {
        Rectangle()
            .fill(SparkVTheme.stroke)
            .frame(height: 1)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

// MARK: - Excluded apps (Island pane)

/// Apps in front of which the island doesn't open on hover (or hides).
struct IslandExcludedAppsSettingsSection: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared
    @StateObject private var box = IslandControllerBox()

    var body: some View {
        IslandSettingsCard(title: "Excluded Apps",
                           subtitle: "While one of these is in front, the island stays out of the way. Volume and media keys keep working.",
                           systemImage: "app.badge.checkmark") {
            HStack {
                Text("In These Apps")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                Spacer()
                IslandSegmented(
                    options: IslandExclusionBehavior.allCases.map { ($0, $0.title) },
                    selection: $settings.exclusionBehavior,
                    label: "In excluded apps"
                )
                .frame(width: 270)
            }
            .padding(.horizontal, 8)

            if settings.excludedBundleIDs.isEmpty {
                IslandNote(text: "No apps yet. Add a video player, a design app or a game.", systemImage: "square.dashed")
                    .padding(.vertical, 4)
            } else {
                IslandAppChips(ids: settings.excludedBundleIDs) { id in
                    withAnimation(SparkVMotion.respecting(SparkVMotion.snappy)) { settings.setExcluded(id, false) }
                }
                .padding(.horizontal, 8)
            }

            HStack(spacing: 8) {
                Button("Add App…") { addApp() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                if let front = box.controller?.frontApp, !settings.isExcluded(front.bundleID) {
                    Button("Add \(front.name)") {
                        withAnimation(SparkVMotion.respecting(SparkVMotion.snappy)) { settings.setExcluded(front.bundleID, true) }
                    }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Exclude Apps from the Island"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { settings.setExcluded(id, true) }
        }
    }
}

/// App chips with icon, name and a remove button.
private struct IslandAppChips: View {
    let ids: [String]
    let remove: (String) -> Void

    var body: some View {
        IslandFlowLayout(spacing: 6) {
            ForEach(ids, id: \.self) { id in
                IslandAppChip(id: id) { remove(id) }
                    .transition(.sparkVEnter)
            }
        }
    }
}

private struct IslandAppChip: View {
    let id: String
    let remove: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if let icon = IslandAppInfo.icon(id) {
                    Image(nsImage: icon).resizable()
                } else {
                    // Not installed on this Mac.
                    Image(systemName: "app.dashed")
                        .font(.system(size: 13))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(IslandAppInfo.name(id))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(hover.isOn ? SparkVTheme.textSecondary : SparkVTheme.textTertiary)
            }
            .buttonStyle(SparkVPressStyle())
            .help("Remove \(IslandAppInfo.name(id))")
            .accessibilityLabel("Remove \(IslandAppInfo.name(id))")
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(hover.isOn ? 0.12 : 0.07)))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .onHover { hover.isOn = $0 }
    }
}

@MainActor
enum IslandAppInfo {
    static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func name(_ id: String) -> String {
        if let url = url(id) {
            let bundle = Bundle(url: url)
            return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        // Not installed: "com.apple.Keynote" reads as "Keynote".
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    static func icon(_ id: String) -> NSImage? {
        url(id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// Wraps chips onto as many rows as they need.
private struct IslandFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Black menu bar (Appearance pane)

/// "Black Menu Bar": the notch disappears into a black band.
struct IslandBlackMenuBarSettingsSection: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared
    @ObservedObject private var blackBar = IslandBlackMenuBar.shared

    var body: some View {
        IslandSettingsCard(title: "Black Menu Bar", subtitle: "Hides the notch: the menu bar turns black so the camera cutout blends in.",
                           systemImage: "menubar.rectangle") {
            HStack(spacing: 12) {
                IslandBlackBarPreview(isOn: settings.blackMenuBar)
                    .frame(width: 132, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    IslandToggleRow(title: "Black Menu Bar", detail: settings.blackMenuBar ? blackBar.status.text : "Off", isOn: $settings.blackMenuBar)
                    IslandNote(text: "Changes your wallpaper: SparkV saves a copy with a black band and puts the original back when you turn this off or quit. Live (Aerial) wallpapers are left alone. A rotating or shuffled wallpaper becomes one still picture while this is on.")
                }
            }
        }
    }
}

private struct IslandBlackBarPreview: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.42), Color(red: 0.42, green: 0.22, blue: 0.48)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle()
                .fill(isOn ? Color.black : Color.white.opacity(0.22))
                .frame(height: 12)
                .animation(SparkVMotion.easeOut(SparkVMotion.Duration.standard), value: isOn)
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Capsule().fill(Color.white.opacity(0.8)).frame(width: 9, height: 2.5) }
                Spacer()
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 12, height: 2.5)
            }
            .padding(.horizontal, 7)
            .frame(height: 12)
            UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4, style: .continuous)
                .fill(Color.black)
                .frame(width: 34, height: 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Capture privacy (Advanced pane)

struct IslandCapturePrivacySettingsSection: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared

    var body: some View {
        IslandSettingsCard(title: "Screenshots & Screen Sharing", subtitle: "SparkV stays visible to you.", systemImage: "rectangle.dashed.badge.record") {
            IslandToggleRow(title: "Hide SparkV from Screenshots & Screen Sharing",
                            detail: "The island and SparkV’s floating panels. Settings and notes windows still show.",
                            isOn: $settings.hideFromCapture)
            IslandNote(text: "Best effort: some recording and video-call apps may still capture it. Off by default, so your screenshots and bug reports show the island.",
                       systemImage: "exclamationmark.triangle")
        }
    }
}

// MARK: - Recovery (Advanced pane)

struct IslandRecoverySettingsSection: View {
    var body: some View {
        IslandSettingsCard(title: "If the Island Goes Missing",
                           subtitle: "After sleep, unlock, a user switch or a display change, SparkV puts the island back at the top center by itself.",
                           systemImage: "arrow.clockwise.circle") {
            HStack(spacing: 8) {
                Button("Restart SparkV") { PermissionCenter.shared.relaunch(from: "Island settings") }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .accessibilityHint("Quits SparkV cleanly and opens it again")
                Text("Quits cleanly and opens SparkV again.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - Gear menu

/// Items for a `Menu("Island") { IslandPlacementMenuItems() }`.
struct IslandPlacementMenuItems: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared
    @StateObject private var box = IslandControllerBox()

    var body: some View {
        let displays = box.controller?.displays ?? IslandDisplays.current()
        Picker("Show On", selection: displayChoice) {
            Text(IslandDisplayMode.automatic.title).tag("mode:automatic")
            Text(IslandDisplayMode.builtIn.title).tag("mode:builtIn")
            Text(IslandDisplayMode.main.title).tag("mode:main")
            Divider()
            ForEach(displays) { display in
                Text(display.name).tag("display:" + display.uuid)
            }
            if settings.displayMode == .specific, let uuid = settings.displayUUID, !displays.contains(where: { $0.uuid == uuid }) {
                Text("\(settings.displayName ?? "Saved Display") (Not Connected)").tag("display:" + uuid)
            }
            Divider()
            Text(IslandDisplayMode.followPointer.title).tag("mode:followPointer")
            Text(IslandDisplayMode.allDisplays.title).tag("mode:allDisplays")
        }
        if let display = box.controller?.info(for: box.controller?.islandDisplayID) {
            Picker("Style", selection: Binding(get: { settings.preset(for: display) }, set: { settings.setPreset($0, for: display) })) {
                ForEach(IslandStylePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
        }
        Divider()
        Toggle("Hide in Full Screen", isOn: $settings.hideInFullScreen)
        Toggle("Show on Displays Without a Notch", isOn: $settings.showOnDisplaysWithoutNotch)
        Toggle("Hide in Clamshell Mode", isOn: $settings.hideInClamshell)
        Toggle("Hide in Mission Control", isOn: $settings.hidesInMissionControl)
        Divider()
        if let front = box.controller?.frontApp {
            Toggle("Disable SparkV in \(front.name)", isOn: Binding(
                get: { settings.isExcluded(front.bundleID) },
                set: { box.controller?.setFrontAppExcluded($0) }
            ))
        }
        Button("Excluded Apps…") { IslandSettingsOpener.open() }
        Divider()
        Toggle("Hide from Screenshots & Screen Sharing", isOn: $settings.hideFromCapture)
        Text("Best effort: some recording apps may still capture it")
        Toggle("Black Menu Bar (Hides the Notch)", isOn: $settings.blackMenuBar)
        Divider()
        if let controller = box.controller {
            if controller.isManuallyHidden {
                Button("Show the Island") { controller.unhide() }
            } else {
                Button("Hide the Island for 1 Hour") { controller.hide(for: 3600) }
            }
        }
        Toggle("Hide/Show Shortcut  \(IslandPlacementController.hotkeyLabel)", isOn: $settings.hotkeyEnabled)
        Button("Island Settings…") { IslandSettingsOpener.open() }
    }

    private var displayChoice: Binding<String> {
        Binding(
            get: {
                if settings.displayMode == .specific, let uuid = settings.displayUUID { return "display:" + uuid }
                return "mode:" + settings.displayMode.rawValue
            },
            set: { tag in
                if tag.hasPrefix("display:") {
                    let uuid = String(tag.dropFirst("display:".count))
                    let displays = box.controller?.displays ?? IslandDisplays.current()
                    if let display = displays.first(where: { $0.uuid == uuid }) { settings.choose(display: display) }
                } else if let mode = IslandDisplayMode(rawValue: String(tag.dropFirst("mode:".count))) {
                    settings.choose(mode)
                }
            }
        )
    }
}

// MARK: - Agents hub tile (System)

/// Shows where the island is and its style; click for the Island menu
/// (display, style, hide, exclude the front app).
struct IslandPlacementHubTile: View {
    @ObservedObject private var settings = IslandPlacementSettings.shared
    @StateObject private var box = IslandControllerBox()
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Menu { IslandPlacementMenuItems() } label: { face }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { hover.isOn = $0 }
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .help(help)
            .accessibilityLabel("Island placement")
            .accessibilityValue(help)
    }

    private var preset: IslandStylePreset {
        guard let display = box.controller?.info(for: box.controller?.islandDisplayID) else { return .notch }
        return settings.preset(for: display)
    }

    private var isActive: Bool {
        settings.displayMode != .automatic || box.controller?.isManuallyHidden == true
    }

    private var title: String {
        if box.controller?.isManuallyHidden == true { return "Hidden" }
        switch settings.displayMode {
        case .followPointer: return "Follows"
        case .allDisplays: return "All Screens"
        default: return "Island"
        }
    }

    private var help: String {
        guard let controller = box.controller else { return "Island: display, style and when it hides" }
        return "\(controller.statusLine). Style: \(preset.title). Click for display, style and hiding."
    }

    private var face: some View {
        let tint = Color(red: 0.36, green: 0.78, blue: 0.98)
        let glyph = LabsBHubTileBackground.glyph(isActive: isActive, isHovered: hover.isOn, tint: tint)
        return VStack(spacing: 5) {
            Group {
                if box.controller?.isManuallyHidden == true {
                    Image(systemName: "eye.slash").font(.system(size: 16, weight: .semibold))
                } else {
                    IslandGlyph(preset: preset)
                }
            }
            .foregroundStyle(glyph)
            .frame(height: 19)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LabsBHubTileBackground.label(isActive: isActive, isHovered: hover.isOn))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(LabsBHubTileBackground(isActive: isActive, isHovered: hover.isOn, tint: tint))
        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
    }
}

/// A tiny screen with the island drawn in it (the hub tile's glyph), in
/// the foreground style.
struct IslandGlyph: View {
    let preset: IslandStylePreset

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(lineWidth: 1.8)
                .frame(width: 24, height: 17)
            switch preset {
            case .notch:
                IslandShape(topRadius: 1.5, bottomRadius: 2.5)
                    .frame(width: 13, height: 6)
            case .pill:
                Capsule()
                    .frame(width: 9, height: 3.5)
                    .padding(.top, 3.5)
            case .minimal:
                Capsule()
                    .frame(width: 7, height: 1.5)
                    .padding(.top, 3.5)
                    .opacity(0.8)
            }
        }
        .frame(width: 24, height: 17)
        .accessibilityHidden(true)
    }
}

// MARK: - Window (until the Settings window hosts these sections)

/// Where "Island Settings…" and "Excluded Apps…" go. INTEGRATION.md points
/// this one line at the app shell's Settings window (Island pane).
@MainActor
enum IslandSettingsOpener {
    static func open() {
        SparkVSettings.show(.island)
    }
}

/// A standalone window with every Island section, opened from the gear
/// menu. When the app shell's Settings window exists, point "Island
/// Settings…" there instead (INTEGRATION.md).
@MainActor
final class IslandPlacementWindowController: NSObject, NSWindowDelegate {
    static let shared = IslandPlacementWindowController()
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: IslandPlacementSettingsRoot().followsAppearance())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Island"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 720))
        window.center()
        window.setFrameAutosaveName("SparkV.IslandPlacement")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Every Island section in one grouped Form, as the Settings window hosts them.
struct IslandPlacementSettingsRoot: View {
    var body: some View {
        Form {
            IslandDisplaySettingsSection()
            IslandStyleSettingsSection()
            IslandVisibilitySettingsSection()
            IslandExcludedAppsSettingsSection()
            IslandBlackMenuBarSettingsSection()
            IslandCapturePrivacySettingsSection()
            IslandRecoverySettingsSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 460, minHeight: 420)
        .background { AppearanceWindowBackground().ignoresSafeArea() }
    }
}
