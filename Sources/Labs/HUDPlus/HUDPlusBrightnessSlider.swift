import SwiftUI

/// Latest brightness per display as the HUD sees it, for sliders that should
/// follow key presses and Control Center without polling. Separate from
/// `HUDController` so a change re-renders only the views that show it.
@MainActor
final class HUDBrightnessFeed: ObservableObject {
    static let shared = HUDBrightnessFeed()

    @Published private(set) var levels: [CGDirectDisplayID: Float] = [:]

    func report(_ value: Float, display: CGDirectDisplayID) {
        guard levels[display].map({ abs($0 - value) > 0.002 }) ?? true else { return }
        levels[display] = value
    }
}

/// A brightness slider for the drawer or a widget: the island's display (or
/// the built-in panel), drag or click the track. Disabled with a short
/// reason when SparkV can't set that display. `compact` drops the sun at
/// each end and the percentage (the Brightness widget shows its own).
struct HUDBrightnessSlider: View {
    var compact = false
    @ObservedObject private var feed = HUDBrightnessFeed.shared
    @ObservedObject private var directory = HUDDisplayDirectory.shared
    @StateObject private var dragging = ViewFlag()
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let display = targetDisplay
        let level = display.flatMap { feed.levels[$0] ?? HUDDisplayBrightness.shared.read($0) }
        let content = HUDContent(style: .brightness, level: level.map(Double.init) ?? 0)
        HStack(spacing: 10) {
            if !compact {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            GeometryReader { proxy in
                HUDLevelBar(level: content.clampedLevel, fill: HUDPalette.fill(content), animates: !dragging.isOn)
                    .frame(height: hover.isOn || dragging.isOn ? 8 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragging.isOn = true
                                set(Double(value.location.x / max(1, proxy.size.width)), display: display)
                            }
                            .onEnded { _ in dragging.isOn = false }
                    )
            }
            .frame(height: 20)
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .onHover { hover.isOn = $0 }
            if !compact {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.text))
                Text(level == nil ? "–" : content.percentText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .opacity(level == nil ? 0.45 : 1)
        .disabled(level == nil)
        .help(level == nil ? "SparkV can't set this display's brightness (DDC monitors need BetterDisplay or Lunar)." : "Brightness")
        // Follows screen changes only while it shows.
        .onAppear { directory.start() }
        .onDisappear { directory.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brightness")
        .accessibilityValue(level == nil ? "Unavailable" : "\(HUDStepMath.percent(content.clampedLevel)) percent")
        .accessibilityAdjustableAction { direction in
            let step = Double(HUDStepMath.step(divisions: HUDPlusSettings.shared.stepDivisions, fine: false))
            switch direction {
            case .increment: set(content.clampedLevel + step, display: display)
            case .decrement: set(content.clampedLevel - step, display: display)
            @unknown default: break
            }
        }
    }

    private var targetDisplay: CGDirectDisplayID? { Self.targetDisplay(in: directory) }

    /// The island's display when SparkV can set it, else the built-in panel.
    static func targetDisplay(in directory: HUDDisplayDirectory) -> CGDirectDisplayID? {
        let island = (HUDController.current?.islandScreen() ?? HUDDisplayDirectory.defaultIslandScreen())
            .flatMap(HUDDisplayDirectory.displayID(of:))
        if let island, directory.facts(for: island)?.canSetBrightness == true { return island }
        return directory.builtIn().flatMap { $0.facts.canSetBrightness ? $0.facts.id : nil }
    }

    private func set(_ level: Double, display: CGDirectDisplayID?) {
        guard let display else { return }
        let value = Float(min(1, max(0, level)))
        HUDDisplayBrightness.shared.write(value, to: display)
        feed.report(value, display: display)
    }
}

/// Widgets › Brightness (1x1): the level of the island's display (or the
/// built-in panel) with a slider, following key presses and Control Center
/// through `HUDBrightnessFeed`. Unavailable on DDC monitors.
struct HUDBrightnessWidget: View {
    @ObservedObject private var feed = HUDBrightnessFeed.shared
    @ObservedObject private var directory = HUDDisplayDirectory.shared

    var body: some View {
        let display = HUDBrightnessSlider.targetDisplay(in: directory)
        let level = display.flatMap { feed.levels[$0] ?? HUDDisplayBrightness.shared.read($0) }
        WidgetCard(padding: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: (level ?? 1) < 0.5 ? "sun.min.fill" : "sun.max.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.textSecondary))
                    Text(level.map { "\(HUDStepMath.percent(Double($0)))%" } ?? "–")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .tracking(-0.2)
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HUDBrightnessSlider(compact: true)
                    .frame(height: 14)
                Text(level == nil ? "NOT AVAILABLE" : "BRIGHTNESS")
                    .font(WidgetStyle.label(7))
                    .tracking(WidgetStyle.labelTracking)
                    .foregroundStyle(WidgetStyle.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .help(level == nil ? "SparkV can't set this display's brightness (DDC monitors need BetterDisplay or Lunar)." : "Brightness")
    }
}
