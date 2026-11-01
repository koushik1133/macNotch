import AppKit
import SwiftUI

// Agents hub tiles and gear-menu items for the System Status package.

// MARK: - Tile face

/// The Agents hub tile look (AgentsHubView's AgentTile): Apple draws the
/// glyph in the feature's tint on a dark Control Center tile and washes it
/// while on; SparkV Red is monochrome and lights red on hover or while on.
struct StatusHubTileFace: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isHighlighted = false
    var badge: String? = nil
    let isHovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        let apple = SparkVTheme.usesTileTints
        let lit = isHighlighted || isHovered
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(apple ? tint : (lit ? SparkVTheme.red : SparkVTheme.text.opacity(0.88)))
                .frame(height: 20)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 7.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 3)
                            .frame(height: 11)
                            // Red is for live / recording state: SparkV Red
                            // keeps the badge neutral.
                            .background(Capsule().fill(apple ? tint.opacity(0.9) : Color(white: 0.32)))
                            .offset(x: 12, y: -5)
                            .fixedSize()
                    }
                }
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(apple
                                 ? Color.white.opacity(lit ? 1 : 0.82)
                                 : (lit ? SparkVTheme.text : SparkVTheme.textSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(shape.fill(fill(apple: apple)))
        .overlay(shape.strokeBorder(stroke(apple: apple, lit: lit), lineWidth: 1))
        .contentShape(shape)
        .animation(SparkVMotion.hover(), value: isHovered)
    }

    private func fill(apple: Bool) -> Color {
        if apple { return isHighlighted ? tint.opacity(0.24) : Color.white.opacity(isHovered ? 0.14 : 0.08) }
        return isHighlighted ? SparkVTheme.redSoft : (isHovered ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface)
    }

    private func stroke(apple: Bool, lit: Bool) -> Color {
        if apple { return isHighlighted ? tint.opacity(0.45) : Color.clear }
        return lit ? SparkVTheme.red.opacity(isHighlighted ? 0.55 : 0.35) : SparkVTheme.stroke
    }
}

// MARK: - Status (System)

/// Opens the Status page (battery, devices, privacy, quick toggles). Shows
/// the battery level as its badge.
struct SystemStatusHubTile: View {
    var onOpen: (() -> Void)? = nil

    var body: some View {
        if let power = PowerMonitor.current {
            StatusHubTileObserved(power: power, onOpen: onOpen)
        } else {
            StatusHubTileButton(level: nil, onOpen: onOpen)
        }
    }
}

private struct StatusHubTileObserved: View {
    @ObservedObject var power: PowerMonitor
    let onOpen: (() -> Void)?

    var body: some View {
        StatusHubTileButton(level: power.battery?.level, onOpen: onOpen)
    }
}

private struct StatusHubTileButton: View {
    let level: Int?
    let onOpen: (() -> Void)?
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            if let onOpen { onOpen() } else { SystemStatusCenter.shared.openPage() }
        } label: {
            StatusHubTileFace(
                title: "Status",
                systemImage: Self.symbol(level),
                tint: Color(red: 0.30, green: 0.85, blue: 0.45),
                badge: level.map { "\($0)" },
                isHovered: hover.isOn
            )
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu { SystemStatusMenuItems() }
        .help("Status: battery and health, accessories, what uses the mic or camera, and quick toggles")
        .accessibilityLabel("Status")
        .accessibilityValue(level.map { "Battery \($0) percent" } ?? "")
    }

    static func symbol(_ level: Int?) -> String {
        guard let level else { return "gauge.with.dots.needle.33percent" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Keep Awake (System)

/// Click: on for the default time, or off. Right-click: durations and options.
struct KeepAwakeHubTile: View {
    @ObservedObject private var controller = KeepAwakeController.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let on = controller.isActive
        Button { controller.toggle() } label: {
            TimelineView(.everyMinute) { _ in
                StatusHubTileFace(
                    title: on ? (controller.session?.until.map { "\(StatusFormat.remaining(until: $0, now: Date())) left" } ?? "Awake") : "Keep Awake",
                    systemImage: on ? "cup.and.saucer.fill" : "cup.and.saucer",
                    tint: KeepAwakePalette.tint,
                    isHighlighted: on,
                    isHovered: hover.isOn
                )
            }
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu { KeepAwakeMenuItems() }
        .help(on ? "Keep Awake is on. Click to turn off, right-click for more time."
                 : "Keep your Mac awake for \(KeepAwakeDurations.title(controller.defaultMinutes).lowercased()). Right-click for other durations.")
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(on ? "On" : "Off")
    }
}

// MARK: - Mute Mic (Media)

/// Click: mute or unmute the microphone everywhere (⌃⌥M).
struct MicMuteHubTile: View {
    @ObservedObject private var controller = MicMuteController.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let muted = controller.isMuted
        Button { controller.toggle() } label: {
            StatusHubTileFace(
                title: muted ? "Muted" : "Mute Mic",
                systemImage: muted ? "mic.slash.fill" : "mic.fill",
                tint: muted ? .red : .orange,
                isHighlighted: muted,
                isHovered: hover.isOn
            )
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu { MicMuteMenuItems() }
        .help(muted ? "The microphone is muted. Click to unmute (\(MicMuteController.shortcut.displayString))."
                    : "Mute the microphone in every app (\(MicMuteController.shortcut.displayString)).")
        .accessibilityLabel("Mute microphone")
        .accessibilityValue(muted ? "Muted" : "On")
    }
}

// MARK: - Gear menu

/// For the gear menu's "Live Activities" submenu: battery warnings,
/// accessories, privacy dots, connection alerts and Caps Lock.
struct SystemStatusMenuItems: View {
    @ObservedObject private var peripherals = PeripheralBatteryMonitor.shared
    @ObservedObject private var privacy = PrivacyIndicatorMonitor.shared
    @ObservedObject private var connectivity = ConnectivityMonitor.shared
    @ObservedObject private var capsLock = CapsLockMonitor.shared

    var body: some View {
        if let power = PowerMonitor.current {
            BatteryMenuItems(power: power)
        }
        Toggle("Accessory Batteries", isOn: $peripherals.isEnabled)
        Toggle("Microphone & Camera In Use", isOn: $privacy.isEnabled)
        Toggle("Connection Alerts", isOn: $connectivity.isEnabled)
        Toggle("Caps Lock", isOn: $capsLock.isEnabled)
        if SystemStatusCenter.shared.openStatusPage != nil {
            Button("Status Page…") { SystemStatusCenter.shared.openPage() }
        }
    }
}

/// Battery thresholds and the critical alert.
struct BatteryMenuItems: View {
    @ObservedObject var power: PowerMonitor

    var body: some View {
        Menu("Battery Warnings: \(BatteryThresholds.summary(power.lowThresholds))") {
            ForEach(BatteryThresholds.lowChoices, id: \.self) { value in
                Toggle("\(value)%", isOn: Binding(
                    get: { power.lowThresholds.contains(value) },
                    set: { power.setLowThreshold(value, enabled: $0) }
                ))
            }
            Divider()
            Picker("Critical Alert", selection: Binding(get: { power.criticalLevel }, set: { power.setCriticalLevel($0) })) {
                ForEach(BatteryThresholds.criticalChoices, id: \.self) { value in
                    Text(value == 0 ? "Off" : "At \(value)%").tag(value)
                }
            }
            Toggle("Show Charger Wattage", isOn: $power.showsWattage)
            Divider()
            Button("Battery Settings…") { power.openBatterySettings() }
        }
    }
}

/// Keep Awake: on for a duration, off, display or system, battery cutoff.
struct KeepAwakeMenuItems: View {
    @ObservedObject private var controller = KeepAwakeController.shared

    var body: some View {
        if controller.isActive {
            Button("Turn Off Keep Awake") { controller.turnOff() }
            if controller.session?.until != nil {
                Button("Add 30 Minutes") { controller.extend(minutes: 30) }
            }
            Divider()
        }
        ForEach(KeepAwakeDurations.choices, id: \.self) { minutes in
            Button(minutes == nil ? "Keep Awake Until Turned Off" : "Keep Awake for \(KeepAwakeDurations.title(minutes))") {
                controller.turnOn(minutes: minutes)
            }
        }
        Divider()
        Picker("While On", selection: $controller.mode) {
            ForEach(KeepAwakeMode.allCases) { mode in Text(mode.title).tag(mode) }
        }
        Picker("Turn Off on Battery Below", selection: $controller.batteryCutoff) {
            ForEach(KeepAwakePolicy.cutoffChoices, id: \.self) { value in
                Text(value == 0 ? "Never" : "\(value)%").tag(value)
            }
        }
        Toggle("Show Cup Beside the Notch", isOn: $controller.showsInNotch)
    }
}

/// Microphone: mute, the ⌃⌥M shortcut, the badge.
struct MicMuteMenuItems: View {
    @ObservedObject private var controller = MicMuteController.shared

    var body: some View {
        Button(controller.isMuted ? "Unmute Microphone" : "Mute Microphone") { controller.toggle() }
            .disabled(!controller.canMute && !controller.isMuted)
        Toggle("Shortcut \(MicMuteController.shortcut.displayString)", isOn: $controller.hotkeyEnabled)
        Toggle("Show “Muted” Beside the Notch", isOn: $controller.showsInNotch)
        if let name = controller.deviceName {
            Text("Input: \(name)")
        }
    }
}

/// Quick toggles that make sense from a menu.
struct QuickTogglesMenuItems: View {
    @ObservedObject private var toggles = QuickTogglesController.shared

    var body: some View {
        Toggle("Hide Desktop Icons", isOn: Binding(get: { toggles.hidesDesktopIcons }, set: { toggles.setHidesDesktopIcons($0) }))
        Button("Toggle Dark Mode") { toggles.perform(.darkMode) }
        Button("Toggle Night Shift") { toggles.perform(.nightShift) }
        Button(toggles.isLowPowerMode ? "Turn Off Low Power Mode…" : "Turn On Low Power Mode…") { toggles.perform(.lowPower) }
        Button("Start Screen Saver") { toggles.perform(.screenSaver) }
    }
}
