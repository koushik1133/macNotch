import SwiftUI

/// What a volume or brightness band shows. Pure data, so the symbol and
/// percentage choices can be checked without a view.
struct HUDContent: Equatable {
    enum Style: Equatable {
        /// Volume level, optionally captioned with the output device name.
        case volume(muted: Bool, deviceName: String?)
        /// The output device just changed (AirPods connected, etc).
        case outputDevice(name: String, transport: HUDOutputTransport, muted: Bool)
        /// Built-in display brightness.
        case brightness
    }

    var style: Style
    /// 0...1; nil when the device exposes no volume control (HDMI, AirPlay).
    var level: Double?

    var clampedLevel: Double { min(1, max(0, level ?? 0)) }

    var percentText: String {
        if case .volume(muted: true, _) = style { return "Muted" }
        guard level != nil else { return "" }
        return "\(Int((clampedLevel * 100).rounded()))%"
    }

    var symbol: String {
        switch style {
        case .volume(let muted, _):
            Self.speakerSymbol(level: clampedLevel, muted: muted)
        case .outputDevice(let name, let transport, _):
            transport.symbol(deviceName: name)
        case .brightness:
            clampedLevel < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    static func speakerSymbol(level: Double, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Coarse kind of audio output, used to pick the device icon.
enum HUDOutputTransport: Equatable, Sendable {
    case builtIn, bluetooth, usb, display, airPlay, other

    func symbol(deviceName: String) -> String {
        let name = deviceName.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") || name.contains("headphone") || name.contains("headset") { return "headphones" }
        switch self {
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return "headphones"
        case .usb: return "hifispeaker.fill"
        case .display: return "tv"
        case .airPlay: return "airplayaudio"
        case .other: return "hifispeaker.fill"
        }
    }
}

/// Band for the volume / brightness HUD: icon on the left, a rounded level bar
/// in the middle (with the device name for an output switch), percentage on
/// the right.
struct HUDActivityView: View {
    let content: HUDContent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: content.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 16)

            middle
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(content.percentText)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(isMuted ? SparkVTheme.textTertiary : SparkVTheme.text)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var middle: some View {
        switch content.style {
        case .outputDevice(let name, _, _):
            HStack(spacing: 10) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if content.level != nil {
                    HUDLevelBar(level: content.clampedLevel, fill: barColor)
                        .frame(width: 56, height: 5)
                }
            }
        case .volume(_, let deviceName?):
            HStack(spacing: 8) {
                Text(deviceName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HUDLevelBar(level: content.clampedLevel, fill: barColor)
                    .frame(height: 6)
            }
        case .volume, .brightness:
            HUDLevelBar(level: content.clampedLevel, fill: barColor)
                .frame(height: 6)
        }
    }

    private var isMuted: Bool {
        switch content.style {
        case .volume(let muted, _), .outputDevice(_, _, let muted): muted
        case .brightness: false
        }
    }

    private var iconColor: Color {
        switch content.style {
        case .brightness: SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.text)
        case .outputDevice: SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.text)
        case .volume: isMuted ? SparkVTheme.textTertiary : SparkVTheme.text
        }
    }

    private var barColor: Color {
        if isMuted { return SparkVTheme.textTertiary }
        if SparkVTheme.isApple {
            if case .brightness = content.style { return Color(red: 1, green: 0.85, blue: 0.35) }
            return Color.white
        }
        return SparkVTheme.red
    }
}

/// Rounded track with a filled portion, like the system OSD.
struct HUDLevelBar: View {
    let level: Double
    var fill: Color = SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let filled = level <= 0 ? 0 : max(proxy.size.height, width * level)
            ZStack(alignment: .leading) {
                Capsule().fill(SparkVTheme.surfaceHover)
                Capsule()
                    .fill(fill)
                    .frame(width: min(width, filled))
            }
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }
}
