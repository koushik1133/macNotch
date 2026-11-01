import AppKit
import SwiftUI

/// The Status drawer page (508 × 114, a tall tab): the battery with its
/// health, connected accessories and what uses the mic or camera, and the
/// quick toggles. Every value is re-read when the page appears.
struct SystemStatusTabView: View {
    @StateObject private var appeared = ViewFlag()
    @ObservedObject private var toggles = QuickTogglesController.shared

    var body: some View {
        HStack(alignment: .top, spacing: StatusPageMetrics.gap) {
            Group {
                if let power = PowerMonitor.current {
                    StatusBatteryCard(power: power)
                } else {
                    StatusCard { StatusEmptyNote(symbol: "battery.100percent", text: "Battery info appears once SparkV is running.") }
                }
            }
            .frame(width: StatusPageMetrics.batteryWidth)
            .sparkVStaggeredEntrance(appeared.isOn, index: 0)

            // A toggle's message (e.g. "make a Night Shift shortcut") takes
            // the middle card's place, so it never covers a control.
            Group {
                if let message = toggles.message {
                    QuickToggleMessageCard(message: message)
                        .transition(.sparkVCrossfade)
                } else {
                    StatusDevicesCard()
                        .transition(.sparkVCrossfade)
                }
            }
            .frame(maxWidth: .infinity)
            .sparkVStaggeredEntrance(appeared.isOn, index: 1)

            QuickTogglesGrid()
                .frame(width: StatusPageMetrics.togglesWidth)
                .sparkVStaggeredEntrance(appeared.isOn, index: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: toggles.message)
        .onAppear {
            appeared.isOn = true
            PowerMonitor.current?.refreshForDisplay()
            PeripheralBatteryMonitor.shared.refresh()
            toggles.refresh()
        }
        .onDisappear { appeared.isOn = false }
    }
}

enum StatusPageMetrics {
    static let gap: CGFloat = 8
    static let batteryWidth: CGFloat = 152
    /// Four 44 pt tiles and three 4 pt gaps.
    static let togglesWidth: CGFloat = 188
    static let tileSize = CGSize(width: 44, height: 53)
    static let tileSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 8
}

// MARK: - Cards

/// The page's raised card: a soft surface in Apple, a hairline in SparkV Red.
struct StatusCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(SparkVTheme.surface))
            .overlay(shape.strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
    }
}

/// "BATTERY" in SparkV Red's mono eyebrow, "Battery" in Apple.
struct StatusEyebrow: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if !SparkVTheme.isApple {
                Rectangle().fill(SparkVTheme.eyebrowDash).frame(width: 6, height: 1.5)
            }
            Text(SparkVTheme.isApple ? text : text.uppercased())
                .font(SparkVTheme.isApple ? .system(size: 10, weight: .semibold) : SparkVTheme.eyebrow(9.5))
                .tracking(SparkVTheme.isApple ? 0 : 1.0)
                .foregroundStyle(SparkVTheme.isApple ? SparkVTheme.textSecondary : SparkVTheme.textTertiary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(height: 13)
    }
}

struct StatusEmptyNote: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SparkVTheme.textTertiary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Battery card

struct StatusBatteryCard: View {
    @ObservedObject var power: PowerMonitor

    var body: some View {
        StatusCard {
            HStack(spacing: 4) {
                StatusEyebrow(text: "Battery", trailing: power.isLowPowerMode ? "Low Power" : nil)
                if let reading = power.battery, let hold = power.details?.holdReason(for: reading), hold != .other {
                    Button { power.openBatterySettings() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .frame(width: 16, height: 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help("macOS is holding the charge (\(hold.title)). Apps can't override it; “Charge to Full Now” is in the battery menu and in Battery settings.")
                    .accessibilityLabel("Battery Settings")
                }
            }
            if let reading = power.battery {
                filled(reading)
            } else {
                StatusEmptyNote(symbol: "powerplug.fill", text: "No battery: this Mac runs on its power adapter.")
                    .padding(.top, 6)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func filled(_ reading: BatteryReading) -> some View {
        let tint = BatteryTint.color(level: reading.level)
        let mode: BatteryActivityMode = reading.isOnAC ? BatteryActivityMode(chargingReading: reading) : .onBattery
        let hold = power.details?.holdReason(for: reading)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(reading.level)%")
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .tracking(-0.6)
                .foregroundStyle(reading.level <= 20 && !reading.isOnAC ? tint : SparkVTheme.text)
            StatusBigBatteryGlyph(level: reading.level, isCharging: mode == .charging, tint: tint)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Spacer(minLength: 0)
        }
        .padding(.top, 1)

        let lines = stateLines(reading, mode: mode, hold: hold)
        Text(lines.state)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(mode == .notCharging ? SparkVTheme.warning : SparkVTheme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.top, -1)
        if let time = lines.time {
            Text(time)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 1)
        }

        Spacer(minLength: 2)

        healthLine
    }

    /// "Charging · 67 W" and "1h 5m to full" (two lines in the narrow card).
    private func stateLines(_ reading: BatteryReading, mode: BatteryActivityMode, hold: BatteryHoldReason?) -> (state: String, time: String?) {
        let watts = power.details?.adapter?.watts.map { "\($0) W" }
        switch mode {
        case .charging:
            return ((["Charging", watts].compactMap { $0 }).joined(separator: " · "),
                    reading.minutesToFull.map { "\(PowerFormat.duration(minutes: $0)) to full" })
        case .charged:
            return ((["Charged", watts].compactMap { $0 }).joined(separator: " · "), nil)
        case .notCharging:
            switch hold {
            case .optimized?: return ("On hold · Optimized", nil)
            case .chargeLimit?: return ("On hold · Charge limit", nil)
            default: return ("Not charging", watts.map { "On a \($0) charger" })
            }
        default:
            return ("On battery", reading.minutesToEmpty.map { "\(PowerFormat.duration(minutes: $0)) left" })
        }
    }

    @ViewBuilder
    private var healthLine: some View {
        let health = power.details?.health
        let capacity = health?.maximumCapacityPercent
        let cycles = health?.cycleCount
        if capacity != nil || cycles != nil {
            HStack(spacing: 4) {
                Image(systemName: health?.condition == .serviceRecommended ? "exclamationmark.triangle.fill" : "heart.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(health?.condition == .serviceRecommended ? SparkVTheme.warning : SparkVTheme.textTertiary)
                Text([capacity.map { "Health \($0)%" }, cycles.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .help(health?.condition == .serviceRecommended
                  ? "macOS recommends service for this battery."
                  : "Maximum capacity compared with when it was new, and charge cycles so far.")
        }
    }
}

/// A larger battery outline than the band's, for the card.
struct StatusBigBatteryGlyph: View {
    let level: Int
    let isCharging: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: max(3, 27 * CGFloat(min(100, max(0, level))) / 100))
                    .padding(2.5)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.6), radius: 0.6)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 32, height: 15)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.42))
                .frame(width: 2, height: 5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Devices card

struct StatusDevicesCard: View {
    @ObservedObject private var peripherals = PeripheralBatteryMonitor.shared
    @ObservedObject private var privacy = PrivacyIndicatorMonitor.shared

    var body: some View {
        StatusCard {
            StatusEyebrow(text: "Devices")
            let rows = rows
            if rows.isEmpty {
                Text(peripherals.isEnabled ? "No accessories with a battery" : "Accessory batteries are off")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .padding(.top, 5)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows.prefix(3), id: \.id) { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.symbol)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SparkVTheme.textSecondary)
                                .frame(width: 16)
                            Text(row.shortName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(SparkVTheme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            StatusPercentLabel(percent: row.percent, isCharging: row.isCharging)
                        }
                        .help(row.name)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.name), \(row.percent.map { "\($0) percent" } ?? "battery unknown")\(row.isCharging ? ", charging" : "")")
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 2)
            privacyLine
        }
    }

    private struct Row: Identifiable {
        var id: String
        var name: String
        var shortName: String
        var symbol: String
        var percent: Int?
        var isCharging: Bool
    }

    private var rows: [Row] {
        var result: [Row] = []
        if let audio = PowerMonitor.current?.connectedAudio {
            result.append(Row(id: "audio." + audio.address, name: audio.name,
                              shortName: PeripheralBattery.shortName(audio.name, kind: .headset), symbol: audio.symbolName,
                              percent: audio.batteries.lowest, isCharging: false))
        }
        result += peripherals.devices.map {
            Row(id: $0.id, name: $0.name, shortName: $0.shortName, symbol: $0.kind.symbol, percent: $0.percent, isCharging: $0.isCharging)
        }
        return result
    }

    @ViewBuilder
    private var privacyLine: some View {
        let snapshot = privacy.snapshot
        HStack(spacing: 5) {
            if snapshot.isIdle {
                Circle().fill(SparkVTheme.textTertiary.opacity(0.6)).frame(width: 5, height: 5)
                Text(privacy.isEnabled ? "Mic and camera off" : "Privacy dots off")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
            } else {
                PrivacyDots(sensors: snapshot.sensors, size: 6)
                Text(Self.shortPrivacy(snapshot))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.isIdle ? "Microphone and camera off" : snapshot.headline + " in use")
        .help(snapshot.isIdle ? "Nothing uses your microphone or camera."
              : snapshot.headline + (snapshot.camera ? ". The camera's app is inferred: macOS doesn't tell apps which app holds the camera." : ""))
    }

    /// "FaceTime", "Safari +1", "Microphone" for the narrow card.
    private static func shortPrivacy(_ snapshot: PrivacySnapshot) -> String {
        if let mic = snapshot.microphone.first {
            return snapshot.microphone.count > 1 ? "\(mic.name) +\(snapshot.microphone.count - 1)" : mic.name
        }
        if snapshot.camera, let guess = snapshot.cameraLikelyApp { return "\(guess.name)?" }
        if snapshot.screen, let app = snapshot.screenApp { return app }
        return snapshot.sensors.first?.title ?? ""
    }
}

// MARK: - Quick toggles grid

/// Up to eight one-tap toggles, four across.
struct QuickTogglesGrid: View {
    @ObservedObject private var toggles = QuickTogglesController.shared
    @ObservedObject private var keepAwake = KeepAwakeController.shared
    @ObservedObject private var micMute = MicMuteController.shared

    var body: some View {
        let kinds = Array(toggles.visibleKinds.prefix(8))
        let columns = Array(repeating: GridItem(.fixed(StatusPageMetrics.tileSize.width), spacing: StatusPageMetrics.tileSpacing), count: 4)
        // Once a minute, so Keep Awake's time left stays current while open.
        TimelineView(.everyMinute) { _ in
            LazyVGrid(columns: columns, alignment: .leading, spacing: StatusPageMetrics.rowSpacing) {
                ForEach(kinds) { kind in
                    QuickToggleTile(
                        kind: kind,
                        isOn: toggles.isOn(kind),
                        detail: toggles.detail(kind),
                        isBusy: toggles.busy.contains(kind)
                    ) {
                        toggles.perform(kind)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Control Center style: a glyph in a circle (filled with the accent while
/// on in Apple; lit red in SparkV Red) and a one-line title.
struct QuickToggleTile: View {
    let kind: QuickToggleKind
    let isOn: Bool?
    let detail: String?
    let isBusy: Bool
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let on = isOn == true
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    Circle().fill(circleFill(on))
                    if isBusy {
                        ProgressView().controlSize(.mini).tint(on ? Color.white : SparkVTheme.progressTint)
                    } else {
                        Image(systemName: kind.symbol(isOn: on))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(glyph(on))
                    }
                    if kind == .lowPower {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .offset(x: 11, y: 10)
                    }
                }
                .frame(width: 24, height: 24)
                // Two short lines at most ("Screen / Saver"), top-aligned so
                // every circle sits on the same line.
                Text(title(on))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(on || hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .lineSpacing(-1.5)
                    .frame(height: 23, alignment: .top)
            }
            .padding(.top, 2)
            .padding(.horizontal, 1)
            .frame(width: StatusPageMetrics.tileSize.width, height: StatusPageMetrics.tileSize.height)
            .background(shape.fill(tileFill(on)))
            .overlay(shape.strokeBorder(tileStroke(on), lineWidth: 1))
            .contentShape(shape)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: on)
        }
        .buttonStyle(SparkVPressStyle())
        .focusEffectDisabled()
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(kind.longTitle)
        .accessibilityValue(isOn.map { $0 ? "On" : "Off" } ?? (detail ?? ""))
        .accessibilityAddTraits(isOn == nil ? [] : .isToggle)
    }

    private func title(_ on: Bool) -> String {
        if kind == .keepAwake, on, let detail { return detail == "On" ? "Awake" : "\(detail) left" }
        if kind == .micMute, on { return "Muted" }
        return kind.title
    }

    private var help: String {
        switch kind {
        case .keepAwake: "Keep Awake: stops the Mac and display from sleeping. Right-click the hub tile or use the gear menu for durations."
        case .micMute: "Mute the microphone everywhere (\(MicMuteController.shortcut.displayString))."
        case .darkMode: "Switch between light and dark appearance (asks once to control System Events)."
        case .desktopIcons: "Hide the icons on your desktop (covers them with your wallpaper; Finder isn't restarted)."
        case .nightShift: "Runs your “\(QuickTogglesController.shared.nightShiftShortcut)” shortcut (Set Night Shift: Toggle). macOS has no Night Shift API for apps."
        case .airPods: "Connect or disconnect your headphones and play sound on them."
        case .lowPower: "Turn Low Power Mode on or off. macOS asks for an administrator password."
        case .screenSaver: "Start the screen saver."
        }
    }

    private func circleFill(_ on: Bool) -> Color {
        if SparkVTheme.isApple { return on ? SparkVTheme.accent : Color.white.opacity(hover.isOn ? 0.2 : 0.14) }
        return on ? SparkVTheme.red.opacity(0.22) : Color.white.opacity(hover.isOn ? 0.12 : 0.07)
    }

    private func glyph(_ on: Bool) -> Color {
        if SparkVTheme.isApple { return Color.white.opacity(on ? 1 : 0.88) }
        return on ? SparkVTheme.red : SparkVTheme.text.opacity(0.88)
    }

    private func tileFill(_ on: Bool) -> Color {
        if SparkVTheme.isApple { return Color.white.opacity(hover.isOn ? 0.12 : 0.06) }
        return on ? SparkVTheme.redSoft : (hover.isOn ? SparkVTheme.red.opacity(0.08) : SparkVTheme.surface)
    }

    private func tileStroke(_ on: Bool) -> Color {
        if SparkVTheme.isApple { return Color.clear }
        return on ? SparkVTheme.red.opacity(0.5) : (hover.isOn ? SparkVTheme.red.opacity(0.3) : SparkVTheme.stroke)
    }
}

/// "Make a shortcut named …  [Open Shortcuts]" in the middle card's place
/// (never over a control), with a close button. Fades by itself after 8 s.
struct QuickToggleMessageCard: View {
    let message: QuickToggleMessage

    var body: some View {
        StatusCard {
            HStack(spacing: 4) {
                StatusEyebrow(text: "Quick Toggles")
                Button { QuickTogglesController.shared.dismissMessage() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .frame(width: 16, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SparkVPressStyle())
                .help("Close")
                .accessibilityLabel("Close message")
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.warning)
                    .padding(.top, 1)
                Text(message.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(4)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 5)
            Spacer(minLength: 2)
            if let title = message.actionTitle, let action = message.action {
                Button(title) { QuickTogglesController.shared.performMessageAction(action) }
                    .buttonStyle(StatusChipButtonStyle(prominent: true))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A small capsule button for cards and chips.
struct StatusChipButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StatusChipBody(configuration: configuration, prominent: prominent)
    }
}

private struct StatusChipBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @StateObject private var hover = ViewFlag()

    var body: some View {
        configuration.label
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : SparkVTheme.text)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(prominent || SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !SparkVMotion.reduceMotion ? SparkVMotion.pressedScale : 1)
            .animation(SparkVMotion.easeOut(configuration.isPressed ? SparkVMotion.Duration.press : SparkVMotion.Duration.release), value: configuration.isPressed)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .onHover { hover.isOn = $0 }
    }

    private var fill: Color {
        if prominent { return SparkVTheme.accent.opacity(configuration.isPressed ? 0.78 : 1) }
        return Color.white.opacity(configuration.isPressed ? 0.22 : (hover.isOn ? 0.18 : 0.12))
    }
}
