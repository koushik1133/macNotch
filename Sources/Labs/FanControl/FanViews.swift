import AppKit
import SwiftUI

// Fan Control views in the SparkV brand (SparkVTheme): the drawer page,
// the Agents hub tile, gear-menu items and the small shared pieces.
// Read-only: macOS controls the fans.
// Sampling runs only while one of these is on screen (attach/detach).

// MARK: - Shared pieces

/// The fan glyph.
struct FanGlyph: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "fan.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(SparkVTheme.text.opacity(0.85))
            .frame(width: size + 6, height: size + 6)
    }
}

/// Actual RPM within 0...max, with a tick at the fan's minimum.
struct FanRPMBar: View {
    let fan: FanInfo

    var body: some View {
        GeometryReader { geo in
            let maxRPM = max(fan.maximum ?? 1, 1)
            let fraction = min(max((fan.actual ?? 0) / maxRPM, 0), 1)
            let minFraction = min(max((fan.minimum ?? 0) / maxRPM, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(SparkVTheme.surface)
                Capsule()
                    .fill(SparkVTheme.text.opacity(0.75))
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
        .accessibilityValue("\(Int(fan.actual ?? 0)) RPM\(fan.maximum.map { " of \(Int($0))" } ?? "")")
    }
}

/// The one-line note under the fans: macOS controls them.
struct FanInfoLine: View {
    @ObservedObject var controller: FanController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: controller.hasFans ? "checkmark.shield.fill" : "thermometer.medium")
                .foregroundStyle(SparkVTheme.textTertiary)
            Text(controller.hasFans ? "Fans are controlled by macOS. SparkV only reads speeds and temperatures."
                                    : "Temperatures only: this Mac has no fans.")
                .foregroundStyle(SparkVTheme.textTertiary)
            Spacer(minLength: 4)
        }
        .font(SparkVTheme.caption(10))
        .lineLimit(1)
        .truncationMode(.tail)
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
            FanInfoLine(controller: controller)
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
            Spacer(minLength: 4)
            Button {
                FanControlWindowController.shared.show(controller: controller)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(FanSmallButtonStyle())
            .help("Open Fans & Temperatures")
            .accessibilityLabel("Open Fans and Temperatures")
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
                        .foregroundStyle(FanHeat.color(reading?.celsius))
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
            }
        }
    }
}

/// Temperature color: warning from 75 °C, red from 90 °C.
enum FanHeat {
    static func color(_ c: Double?) -> Color {
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
        HStack(spacing: 7) {
            FanGlyph()
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.name(for: fan.index))
                    .font(SparkVTheme.headline(11)).foregroundStyle(SparkVTheme.text)
                Text("\(FanFormat.rpm(fan.minimum))–\(FanFormat.rpm(fan.maximum))")
                    .font(SparkVTheme.caption(9).monospacedDigit()).foregroundStyle(SparkVTheme.textTertiary)
            }
            .frame(width: 58, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(FanFormat.rpm(fan.actual))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
                Text("rpm").font(SparkVTheme.caption(9)).foregroundStyle(SparkVTheme.textTertiary)
            }
            .frame(width: 70, alignment: .leading)
            FanRPMBar(fan: fan)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                .fill(SparkVTheme.surface)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Agents hub tile

/// Same footprint as the other hub tiles (48 pt): the fastest fan's speed.
struct FanHubTile: View {
    @ObservedObject var controller: FanController
    let onOpen: () -> Void
    @StateObject private var hover = ViewFlag()

    @MainActor init(controller: FanController? = nil, onOpen: @escaping () -> Void) {
        self.controller = controller ?? .shared
        self.onOpen = onOpen
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        let apple = SparkVTheme.usesTileTints
        Button(action: onOpen) {
            VStack(spacing: 5) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 16, weight: .semibold))
                    // Apple: cyan, like the hub's other tinted glyphs.
                    .foregroundStyle(apple ? Color.cyan : (hover.isOn ? SparkVTheme.red : SparkVTheme.text.opacity(0.88)))
                Text("Fans")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(LabsBHubTileBackground.label(isActive: false, isHovered: hover.isOn))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                if apple {
                    LabsBHubTileBackground(isActive: false, isHovered: hover.isOn, tint: .cyan)
                } else {
                    shape.fill(hover.isOn ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface)
                        .overlay(shape.strokeBorder(hover.isOn ? SparkVTheme.red.opacity(0.35) : SparkVTheme.stroke, lineWidth: 1))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help("Fans & Temperatures: speeds and temperatures (read-only)")
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
            Divider()
        } else if controller.snapshot.smcAvailable {
            Text("This Mac has no fans")
            Divider()
        }
        Button("Open Fans & Temperatures…") { FanControlWindowController.shared.show(controller: controller) }
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

/// The band (about 360 x 30): each fan's speed and the hottest sensor.
struct FanActivityBand: View {
    let state: FanActivityState

    var body: some View {
        HStack(spacing: 8) {
            FanGlyph(size: 12)
            Text("Fans").foregroundStyle(SparkVTheme.textSecondary)
            ForEach(Array(state.rpms.enumerated()), id: \.offset) { pair in
                Text("\(FanFormat.rpm(pair.element))")
                    .foregroundStyle(SparkVTheme.text)
            }
            Text("rpm").foregroundStyle(SparkVTheme.textTertiary)
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
