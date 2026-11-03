import SwiftUI

// Bands posted by PowerMonitor: the battery when the charger goes in or out
// or runs low, and a Bluetooth headset's battery when it connects. Same
// layout as the dictation band: icon left, text middle, small trailing item.

enum BatteryTint {
    /// Red at 10% and below, yellow to 20%, green above.
    static func color(level: Int) -> Color {
        if level <= 10 { return SparkVTheme.destructive }
        if level <= 20 { return SparkVTheme.warning }
        return SparkVTheme.success
    }
}

struct BatteryActivityView: View {
    let reading: BatteryReading
    let mode: BatteryActivityMode
    /// The charger's wattage, shown while plugging in.
    var watts: Int? = nil
    /// Why it isn't charging on power (`.notCharging` only).
    var hold: BatteryHoldReason? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: leadingSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(leadingColor)
                .frame(width: 34, height: 16)

            Text("\(Text(title).foregroundStyle(titleColor))\(Text(detailText).foregroundStyle(SparkVTheme.textSecondary))")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text("\(reading.level)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isWarning ? tint : SparkVTheme.text)
                BatteryGlyph(level: reading.level, isCharging: mode == .charging, tint: tint)
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)\(detailText), battery \(reading.level) percent")
    }

    private var isWarning: Bool { mode == .low || mode == .critical }

    private var tint: Color {
        mode == .critical ? SparkVTheme.destructive : BatteryTint.color(level: reading.level)
    }

    private var leadingSymbol: String {
        switch mode {
        case .charging, .charged: "bolt.fill"
        case .notCharging: hold == .optimized || hold == .chargeLimit ? "pause.circle.fill" : "powerplug.fill"
        case .onBattery: "bolt.slash.fill"
        case .low, .critical: "exclamationmark.triangle.fill"
        }
    }

    private var leadingColor: Color {
        switch mode {
        case .charging, .charged: SparkVTheme.success
        case .notCharging: SparkVTheme.warning
        case .onBattery: SparkVTheme.textSecondary
        case .low, .critical: tint
        }
    }

    private var title: String {
        switch mode {
        case .charging: "Charging"
        case .charged: "Charged"
        case .notCharging: hold == .optimized || hold == .chargeLimit ? "Charging On Hold" : "Not Charging"
        case .onBattery: "On Battery"
        case .low: "Low Battery"
        case .critical: "Battery Critically Low"
        }
    }

    private var titleColor: Color {
        isWarning ? tint : SparkVTheme.text
    }

    /// " · 67 W · 1h 5m to full", or "" when there is nothing to add.
    private var detailText: String {
        details.map { " · \($0)" }.joined()
    }

    private var details: [String] {
        switch mode {
        case .charging:
            [watts.map { "\($0) W" }, reading.minutesToFull.map { "\(PowerFormat.duration(minutes: $0)) to full" }].compactMap { $0 }
        case .charged:
            [watts.map { "\($0) W" }].compactMap { $0 }
        case .notCharging:
            switch hold {
            case .optimized: ["Optimized"]
            case .chargeLimit: ["At charge limit"]
            case .other, nil: [watts.map { "\($0) W" }].compactMap { $0 }
            }
        case .onBattery, .low:
            [reading.minutesToEmpty.map { "\(PowerFormat.duration(minutes: $0)) left" }].compactMap { $0 }
        case .critical:
            ["Plug in now"]
        }
    }
}

struct AirPodsActivityView: View {
    let device: BluetoothAudioDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .frame(width: 34, height: 16)

            Text(device.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        let items = device.batteries.items
        guard !items.isEmpty else { return "\(device.name), connected" }
        let parts = items.map { item in
            (item.label.isEmpty ? "" : item.label + " ") + "\(item.percent) percent" + (item.percent <= 10 ? ", low" : "")
        }
        return device.name + ", " + parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var trailing: some View {
        let items = device.batteries.items
        if items.isEmpty {
            Text(SparkVTheme.isApple ? "Connected" : "CONNECTED")
                .font(SparkVTheme.isApple ? .system(size: 10, weight: .semibold) : SparkVTheme.eyebrow(9.5))
                .tracking(SparkVTheme.isApple ? 0 : 0.6)
                .foregroundStyle(SparkVTheme.choose(apple: SparkVTheme.textSecondary, sparkv: SparkVTheme.textTertiary))
        } else {
            HStack(spacing: 10) {
                ForEach(items, id: \.label) { item in
                    BudBattery(label: item.label, percent: item.percent)
                }
            }
        }
    }
}

/// "L ▬ 80%": label, a small fill bar, and the percentage.
private struct BudBattery: View {
    let label: String
    let percent: Int

    var body: some View {
        HStack(spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(SparkVTheme.surfaceHover)
                Capsule()
                    .fill(BatteryTint.color(level: percent))
                    .frame(width: max(3, 16 * CGFloat(percent) / 100))
            }
            .frame(width: 16, height: 5)
            Text("\(percent)%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
            // Low is said with a shape, not only the red bar.
            if percent <= 10 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(SparkVTheme.destructive)
            }
        }
    }
}

/// A small battery outline filled to `level`, with a bolt while charging.
struct BatteryGlyph: View {
    let level: Int
    let isCharging: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, 19 * CGFloat(min(100, max(0, level))) / 100))
                    .padding(2)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.6), radius: 0.5)
                        .frame(maxWidth: .infinity)
                } else if level <= 20, SparkVTheme.differentiateWithoutColor {
                    // Low said with a mark, not only the red fill.
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.6), radius: 0.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 23, height: 11)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
    }
}
