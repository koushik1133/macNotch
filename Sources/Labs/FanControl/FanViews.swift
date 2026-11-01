import AppKit
import SwiftUI

// Fan Control views in the SparkV brand (SparkVTheme): the drawer page,
// the Agents hub tile, gear-menu items and the small shared pieces.
// Sampling runs only while one of these is on screen (attach/detach).

// MARK: - Shared pieces

/// The fan glyph: red while the fan is under manual control.
struct FanGlyph: View {
    let manual: Bool
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "fan.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(manual ? SparkVTheme.red : SparkVTheme.text.opacity(0.85))
            .frame(width: size + 6, height: size + 6)
    }
}

/// Small red "MANUAL" or neutral "AUTO" capsule.
struct FanModeBadge: View {
    let manual: Bool
    var waiting = false
    /// Manual through another app (Macs Fan Control, TG Pro...).
    var elsewhere = false

    var body: some View {
        Text(elsewhere ? "OTHER APP" : waiting ? "WAIT" : manual ? "MANUAL" : "AUTO")
            .font(SparkVTheme.eyebrow(8))
            .tracking(LabsBStyle.eyebrowTracking(0.8))
            .foregroundStyle(manual ? Color.white : (waiting || elsewhere) ? SparkVTheme.warning : SparkVTheme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(manual ? SparkVTheme.red : SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(manual ? Color.clear : SparkVTheme.stroke))
            .fixedSize()
    }
}

/// Actual RPM within 0...max, with a tick at the fan's minimum.
struct FanRPMBar: View {
    let fan: FanInfo
    let manual: Bool

    var body: some View {
        GeometryReader { geo in
            let maxRPM = max(fan.maximum ?? 1, 1)
            let fraction = min(max((fan.actual ?? 0) / maxRPM, 0), 1)
            let minFraction = min(max((fan.minimum ?? 0) / maxRPM, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(SparkVTheme.surface)
                Capsule()
                    .fill(manual ? SparkVTheme.red : SparkVTheme.text.opacity(0.75))
                    .frame(width: max(3, geo.size.width * fraction))
                Rectangle()
                    .fill(SparkVTheme.textTertiary)
                    .frame(width: 1, height: geo.size.height + 2)
                    .offset(x: geo.size.width * minFraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan speed")
        .accessibilityValue("\(Int(fan.actual ?? 0)) RPM\(fan.maximum.map { " of \(Int($0))" } ?? "")\(manual ? ", manual" : "")")
    }
}

/// Mode choices for one fan, used by the drawer chip and the hub tile.
struct FanModeMenuItems: View {
    @ObservedObject var controller: FanController
    let fan: FanInfo

    private var current: FanControlMode { controller.mode(for: fan.index) }

    private func item(_ title: String, _ mode: FanControlMode) -> some View {
        Button {
            controller.setMode(mode, for: fan.index)
        } label: {
            if current == mode { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    var body: some View {
        item("Auto (macOS)", .auto)
        if let limits = fan.validLimits {
            Menu("Constant Speed") {
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    let rpm = FanCurveMath.quantize(limits.lowerBound + fraction * (limits.upperBound - limits.lowerBound), step: 100, limits: limits)
                    item("\(Int(rpm)) rpm" + (fraction == 0 ? " (minimum)" : fraction == 1 ? " (maximum)" : ""), .constant(rpm: rpm))
                }
            }
            Menu("Follow Sensor") {
                item("CPU Hottest · 50 → 80 °C", .sensor(id: "agg.cpu.max", startC: 50, maxC: 80))
                item("CPU Hottest · 60 → 90 °C", .sensor(id: "agg.cpu.max", startC: 60, maxC: 90))
                item("GPU Hottest · 50 → 80 °C", .sensor(id: "agg.gpu.max", startC: 50, maxC: 80))
                item("SSD · 40 → 65 °C", .sensor(id: "agg.storage.max", startC: 40, maxC: 65))
            }
        } else {
            Text("Speed limits unknown: Auto only")
        }
        Divider()
        Button("Custom Speed or Curve…") { FanControlWindowController.shared.show(controller: controller) }
    }
}

extension FanControlMode {
    /// "Auto", "2400 rpm", "CPU Hottest 50→80°".
    func summary(sensors: [FanSensorReading]) -> String {
        switch self {
        case .auto: return "Auto"
        case .constant(let rpm): return "\(Int(rpm)) rpm"
        case .sensor(let id, let startC, let maxC):
            let name = sensors.first { $0.id == id }?.name ?? FanControlMode.sensorFallbackName(id)
            return "\(name) \(Int(startC))→\(Int(maxC))°"
        }
    }

    /// Fits the drawer chip: "Auto", "2800", "CPU 50–80°".
    var compactSummary: String {
        switch self {
        case .auto: return "Auto"
        case .constant(let rpm): return "\(Int(rpm))"
        case .sensor(let id, let startC, let maxC):
            let short: String
            if id.hasPrefix("agg."), let group = FanSensorGroup(rawValue: String(id.dropFirst(4).prefix { $0 != "." })) {
                short = group.title
            } else {
                short = String(id.split(separator: ".", maxSplits: 1).last?.prefix(6) ?? "Sensor")
            }
            return "\(short) \(Int(startC))–\(Int(maxC))°"
        }
    }

    static func sensorFallbackName(_ id: String) -> String {
        if id.hasPrefix("agg."), let group = FanSensorGroup(rawValue: String(id.dropFirst(4).prefix { $0 != "." })) {
            return id.hasSuffix(".avg") ? "\(group.title) Average" : "\(group.title) Hottest"
        }
        return String(id.split(separator: ".", maxSplits: 1).last ?? "Sensor")
    }
}

/// One line about the helper and the failsafe; shows a button when the
/// user has something to do.
struct FanHelperLine: View {
    @ObservedObject var controller: FanController

    var body: some View {
        HStack(spacing: 6) {
            if let failsafe = controller.failsafeText {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SparkVTheme.destructive)
                Text("Failsafe: \(failsafe). Fans are on Auto.").foregroundStyle(SparkVTheme.text)
            } else if let conflict = controller.conflictText {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SparkVTheme.warning)
                Text(conflict).foregroundStyle(SparkVTheme.textSecondary)
            } else if let notice = controller.notice {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(SparkVTheme.warning)
                Text(notice).foregroundStyle(SparkVTheme.textSecondary)
            } else {
                switch controller.helperState {
                case .connected:
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(SparkVTheme.success)
                    Text("Back to Auto above \(Int(FanHelperConstants.thermalLimit)) °C, on quit, sleep or no response")
                        .foregroundStyle(SparkVTheme.textTertiary)
                case .notInstalled where !controller.hasFans:
                    Image(systemName: "thermometer.medium").foregroundStyle(SparkVTheme.textTertiary)
                    Text("Temperatures only: nothing to control on this Mac.")
                        .foregroundStyle(SparkVTheme.textTertiary)
                case .notInstalled:
                    Image(systemName: "lock.fill").foregroundStyle(SparkVTheme.textTertiary)
                    Text("Reading only. Setting speeds needs the fan helper (one password).")
                        .foregroundStyle(SparkVTheme.textTertiary)
                default:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(SparkVTheme.warning)
                    Text(controller.helperState.title).foregroundStyle(SparkVTheme.textSecondary)
                }
            }
            Spacer(minLength: 4)
            if controller.helperState == .connected, FanHelperInstaller.updateAvailable {
                Button(controller.isInstallingHelper ? "Updating…" : "Update Helper…") {
                    controller.runHelperInstaller(install: true)
                }
                .buttonStyle(FanSmallButtonStyle(primary: true))
                .disabled(controller.isInstallingHelper)
                .help("This SparkV build carries a newer fan helper than the one installed")
            }
            if needsInstall {
                Button(controller.isInstallingHelper ? "Installing…" : installTitle) {
                    controller.runHelperInstaller(install: true)
                }
                .buttonStyle(FanSmallButtonStyle(primary: true))
                .disabled(controller.isInstallingHelper || !FanHelperInstaller.isBundled)
                .help(FanHelperInstaller.isBundled ? "Asks for your password once, then installs the fan helper"
                                                   : "This build has no fan helper (see Fan Control's INTEGRATION.md)")
            }
        }
        .font(SparkVTheme.caption(10))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var needsInstall: Bool {
        guard controller.hasFans else { return false }
        switch controller.helperState {
        case .notInstalled, .outdated, .unauthorized: return true
        default: return false
        }
    }

    private var installTitle: String {
        controller.helperState == .notInstalled ? "Install Helper…" : "Reinstall Helper…"
    }
}

/// A compact button for the 114 pt drawer.
struct FanSmallButtonStyle: ButtonStyle {
    var primary = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        let filled = primary || selected
        configuration.label
            .font(SparkVTheme.caption(10))
            .foregroundStyle(filled ? Color.white : SparkVTheme.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? (configuration.isPressed ? SparkVTheme.redDeep : SparkVTheme.red)
                                      : (configuration.isPressed ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(Capsule().strokeBorder(filled ? Color.clear : SparkVTheme.stroke))
            .contentShape(Capsule())
            .animation(SparkVMotion.hover(), value: selected)
            .modifier(FanPressFeedback(isPressed: configuration.isPressed))
    }
}

/// Emil press feedback for the fan buttons: 0.97 in 100 ms, release in
/// 160 ms (strong ease-out). Reduce Motion: color change only.
struct FanPressFeedback: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !SparkVMotion.reduceMotion ? SparkVMotion.pressedScale : 1)
            .animation(
                SparkVMotion.easeOut(isPressed ? SparkVMotion.Duration.press : SparkVMotion.Duration.release),
                value: isPressed
            )
    }
}


// MARK: - Drawer page (508 x 114)

struct FanTabView: View {
    @ObservedObject var controller: FanController

    @MainActor init(controller: FanController? = nil) {
        self.controller = controller ?? .shared
    }

    static let size = CGSize(width: 508, height: 114)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            HStack(alignment: .top, spacing: 10) {
                fansColumn.frame(width: 306)
                Rectangle().fill(SparkVTheme.stroke).frame(width: 1, height: 66)
                sensorGrid
            }
            .frame(height: 66, alignment: .top)
            FanHelperLine(controller: controller)
                .frame(height: 16)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .onAppear { controller.attachViewer() }
        .onDisappear { controller.detachViewer() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(SparkVTheme.isApple ? "FANS" : "SPARKV / FANS")
                .font(SparkVTheme.eyebrow(9))
                .tracking(SparkVTheme.isApple ? 0.4 : 1.2)
                .foregroundStyle(SparkVTheme.textTertiary)
            if controller.manualFanCount > 0 {
                Text("\(controller.manualFanCount) MANUAL")
                    .font(SparkVTheme.eyebrow(8))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(SparkVTheme.red))
            }
            Spacer(minLength: 4)
            if controller.hasFans {
                ForEach(FanPreset.builtins) { preset in
                    Button(preset.name) { controller.applyPreset(preset) }
                        .buttonStyle(FanSmallButtonStyle(selected: controller.activePresetID == preset.id))
                        .help(preset.subtitle)
                }
            }
            Button {
                FanControlWindowController.shared.show(controller: controller)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(FanSmallButtonStyle())
            .help("Open Fan Control")
            .accessibilityLabel("Open Fan Control")
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var fansColumn: some View {
        if !controller.snapshot.smcAvailable && controller.snapshot.fans.isEmpty {
            Text(controller.snapshot.sensors.isEmpty ? "Reading sensors…" : "No fan data")
                .font(SparkVTheme.body(11)).foregroundStyle(SparkVTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.snapshot.fans.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("This Mac has no fans").font(SparkVTheme.headline(12)).foregroundStyle(SparkVTheme.text)
                Text("It is cooled passively. Temperatures are on the right.")
                    .font(SparkVTheme.caption(10)).foregroundStyle(SparkVTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(controller.snapshot.fans) { fan in
                        FanDrawerRow(controller: controller, fan: fan)
                    }
                }
            }
        }
    }

    private var sensorGrid: some View {
        let ids = ["agg.cpu.max", "agg.gpu.max", "agg.storage.max", "agg.battery.max"]
        let titles = ["CPU", "GPU", "SSD", "Battery"]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(Array(ids.enumerated()), id: \.offset) { pair in
                let reading = controller.snapshot.sensor(pair.element)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titles[pair.offset])
                        .font(SparkVTheme.eyebrow(8)).tracking(LabsBStyle.eyebrowTracking(0.8))
                        .foregroundStyle(SparkVTheme.textTertiary)
                    Text(controller.temperatureText(reading?.celsius))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(heatColor(reading?.celsius))
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
            }
        }
    }

    private func heatColor(_ c: Double?) -> Color {
        guard let c else { return SparkVTheme.textTertiary }
        if c >= 90 { return SparkVTheme.destructive }
        if c >= 75 { return SparkVTheme.warning }
        return SparkVTheme.text
    }
}

private struct FanDrawerRow: View {
    @ObservedObject var controller: FanController
    let fan: FanInfo

    var body: some View {
        let manual = controller.isManual(fan.index)
        let wanted = controller.mode(for: fan.index)
        HStack(spacing: 7) {
            FanGlyph(manual: manual)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.name(for: fan.index))
                    .font(SparkVTheme.headline(11)).foregroundStyle(SparkVTheme.text)
                Text("\(FanFormat.rpm(fan.minimum))–\(FanFormat.rpm(fan.maximum))")
                    .font(SparkVTheme.caption(9).monospacedDigit()).foregroundStyle(SparkVTheme.textTertiary)
            }
            .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(FanFormat.rpm(fan.actual))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SparkVTheme.text)
                    Text("rpm").font(SparkVTheme.caption(9)).foregroundStyle(SparkVTheme.textTertiary)
                }
                FanRPMBar(fan: fan, manual: manual)
            }
            .frame(width: 70)
            Spacer(minLength: 2)
            Menu {
                FanModeMenuItems(controller: controller, fan: fan)
            } label: {
                // Manual: a red chip; waiting for the helper: amber; held by
                // another app: amber warning; Auto: neutral.
                let elsewhere = controller.isControlledElsewhere(fan.index)
                let waiting = (wanted.isManual && !manual) || elsewhere
                HStack(spacing: 4) {
                    if manual {
                        Image(systemName: "hand.raised.fill").font(.system(size: 8, weight: .bold))
                    } else if elsewhere {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8, weight: .bold))
                    } else if waiting {
                        Image(systemName: "hourglass").font(.system(size: 8, weight: .bold))
                    }
                    Text(elsewhere ? "Other app" : wanted.compactSummary)
                        .font(SparkVTheme.caption(10).monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(manual ? Color.white : waiting ? SparkVTheme.warning : SparkVTheme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(manual ? SparkVTheme.red : SparkVTheme.surface))
                .overlay(Capsule().strokeBorder(manual ? Color.clear : waiting ? SparkVTheme.warning.opacity(0.6) : SparkVTheme.stroke))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: 134, alignment: .trailing)
            .help(controller.isControlledElsewhere(fan.index)
                  ? "\(controller.otherFanApp ?? "Another app") controls this fan"
                  : wanted.summary(sensors: controller.snapshot.sensors))
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                .fill(manual ? SparkVTheme.redSoft : SparkVTheme.surface)
        )
    }
}

// MARK: - Agents hub tile

/// Same footprint as the other hub tiles (48 pt). Lit red while any fan is
/// manual, showing the fastest fan's speed. Right-click: presets.
struct FanHubTile: View {
    @ObservedObject var controller: FanController
    let onOpen: () -> Void
    @StateObject private var hover = ViewFlag()

    @MainActor init(controller: FanController? = nil, onOpen: @escaping () -> Void) {
        self.controller = controller ?? .shared
        self.onOpen = onOpen
    }

    var body: some View {
        let manual = controller.manualFanCount > 0
        let lit = manual || hover.isOn
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        let fastest = controller.snapshot.fans.compactMap(\.actual).max()
        let apple = SparkVTheme.usesTileTints
        Button(action: onOpen) {
            VStack(spacing: 5) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 16, weight: .semibold))
                    // Apple: cyan, like the hub's other tinted glyphs.
                    .foregroundStyle(apple ? Color.cyan : (lit ? SparkVTheme.red : SparkVTheme.text.opacity(0.88)))
                Text(manual ? "\(FanFormat.compactRPM(fastest)) rpm" : "Fans")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(LabsBHubTileBackground.label(isActive: manual, isHovered: hover.isOn))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                if apple {
                    LabsBHubTileBackground(isActive: manual, isHovered: hover.isOn, tint: .cyan)
                } else {
                    shape.fill(manual ? SparkVTheme.redSoft : (hover.isOn ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface))
                        .overlay(shape.strokeBorder(lit ? SparkVTheme.red.opacity(manual ? 0.55 : 0.35) : SparkVTheme.stroke, lineWidth: 1))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(manual ? "Fans: \(controller.manualFanCount) under manual control" : "Fan Control: speeds, temperatures, presets")
        .contextMenu { FanMenuItems(controller: controller) }
    }
}

// MARK: - Gear menu

/// Items for `Menu("Fans") { FanMenuItems() }` in the gear menu.
struct FanMenuItems: View {
    @ObservedObject var controller: FanController

    @MainActor init(controller: FanController? = nil) {
        self.controller = controller ?? .shared
    }

    var body: some View {
        if controller.hasFans {
            Text(controller.snapshot.fans.map { "\(FanFormat.rpm($0.actual))" }.joined(separator: " · ") + " rpm"
                 + (controller.snapshot.hottestCPU.map { " · CPU \(controller.temperatureText($0.celsius))" } ?? ""))
            if controller.manualFanCount > 0 {
                Text("\(controller.manualFanCount) fan(s) under manual control")
            }
            Divider()
            ForEach(controller.presets) { preset in
                Button {
                    controller.applyPreset(preset)
                } label: {
                    if controller.activePresetID == preset.id { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
            Button("All Fans to Auto") { controller.resetAllToAuto() }
                .disabled(!controller.wantsManual && controller.manualFanCount == 0)
            Divider()
        } else if controller.snapshot.smcAvailable {
            Text("This Mac has no fans")
            Divider()
        }
        Button("Open Fan Control…") { FanControlWindowController.shared.show(controller: controller) }
        if controller.helperState == .notInstalled || controller.helperState == .unauthorized {
            Button(controller.helperState == .notInstalled ? "Install Fan Helper…" : "Reinstall Fan Helper…") {
                controller.runHelperInstaller(install: true)
            }
            .disabled(!FanHelperInstaller.isBundled || controller.isInstallingHelper)
        }
    }
}

// MARK: - Live activity views (posted by FanActivity.swift)

struct FanActivityTrailing: View {
    let state: FanActivityState
    let fastest: Double?

    var body: some View {
        HStack(spacing: 4) {
            Text(FanFormat.compactRPM(fastest))
                .foregroundStyle(SparkVTheme.text)
            if let hottest = state.hottest {
                Text(FanFormat.temperature(hottest, fahrenheit: state.fahrenheit))
                    .foregroundStyle(hottest >= 90 ? SparkVTheme.destructive : SparkVTheme.textSecondary)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

/// The band (about 360 x 30): what is manual, each fan's speed, the hottest sensor.
struct FanActivityBand: View {
    let state: FanActivityState

    var body: some View {
        HStack(spacing: 8) {
            FanGlyph(manual: state.manualFans > 0 || state.failsafe != nil, size: 12)
            if let failsafe = state.failsafe {
                Text("Failsafe: \(failsafe). Fans on Auto")
                    .foregroundStyle(SparkVTheme.text)
            } else {
                Text(state.manualFans > 0 ? "\(state.manualFans) fan\(state.manualFans == 1 ? "" : "s") manual" : "Fans auto")
                    .foregroundStyle(state.manualFans > 0 ? SparkVTheme.red : SparkVTheme.textSecondary)
                ForEach(Array(state.rpms.enumerated()), id: \.offset) { pair in
                    Text("\(FanFormat.rpm(pair.element))")
                        .foregroundStyle(SparkVTheme.text)
                }
                Text("rpm").foregroundStyle(SparkVTheme.textTertiary)
            }
            Spacer(minLength: 4)
            if let hottest = state.hottest {
                Text("\(state.hottestName ?? "CPU") \(FanFormat.temperature(hottest, fahrenheit: state.fahrenheit))")
                    .foregroundStyle(hottest >= 90 ? SparkVTheme.destructive : SparkVTheme.textSecondary)
            }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
