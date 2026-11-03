import SwiftUI

/// What a volume or brightness HUD shows. Pure data, so the symbol and
/// percentage choices can be checked without a view.
struct HUDContent: Equatable {
    enum Style: Equatable {
        /// Volume level, optionally captioned with the output device name.
        case volume(muted: Bool, deviceName: String?)
        /// The output device just changed (AirPods connected, etc).
        case outputDevice(name: String, transport: HUDOutputTransport, muted: Bool)
        /// Display brightness (the built-in panel, or `caption` names the display).
        case brightness
    }

    var style: Style
    /// 0...1; nil when the device exposes no volume control (HDMI, AirPlay).
    var level: Double?
    /// A display's name for brightness on another screen ("Studio Display").
    var caption: String? = nil
    /// All Displays: the mirrored island this HUD is for (the display being
    /// changed). nil: the main island. Other islands keep its space but
    /// don't draw it (see `HUDIslandDisplayKey`).
    var mirrorTarget: CGDirectDisplayID? = nil

    var clampedLevel: Double { min(1, max(0, level ?? 0)) }

    var percentText: String {
        if case .volume(muted: true, _) = style { return "Muted" }
        guard level != nil else { return "" }
        return "\(Int((clampedLevel * 100).rounded()))%"
    }

    /// Spoken by VoiceOver and the accessibility value of the level.
    var accessibilityText: String {
        let what: String
        switch style {
        case .volume: what = "Volume"
        case .outputDevice(let name, _, _): what = "Output \(name), volume"
        case .brightness: what = caption.map { "\($0) brightness" } ?? "Brightness"
        }
        if isMuted { return "\(what) muted" }
        guard level != nil else { return what }
        return "\(what) \(Int((clampedLevel * 100).rounded())) percent"
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

    var isMuted: Bool {
        switch style {
        case .volume(let muted, _), .outputDevice(_, _, let muted): muted
        case .brightness: false
        }
    }

    var isBrightness: Bool {
        if case .brightness = style { return true }
        return false
    }

    /// The level the bar draws: empty while muted, like macOS.
    var barLevel: Double { isMuted ? 0 : clampedLevel }

    /// The device name or display name shown with the level, if any.
    var captionText: String? {
        switch style {
        case .volume(_, let deviceName): deviceName
        case .outputDevice(let name, _, _): name
        case .brightness: caption
        }
    }

    /// The same HUD at another level (and mute state, for volume).
    func with(level newLevel: Double?, muted: Bool? = nil) -> HUDContent {
        var copy = self
        copy.level = newLevel
        if let muted {
            switch style {
            case .volume(_, let name): copy.style = .volume(muted: muted, deviceName: name)
            case .outputDevice(let name, let transport, _): copy.style = .outputDevice(name: name, transport: transport, muted: muted)
            case .brightness: break
            }
        }
        return copy
    }

    /// While the pointer drags this HUD's level: the level under the
    /// pointer, ahead of the throttled re-posts (a drag past 0 unmutes).
    @MainActor
    func live(_ pointer: HUDPointerState) -> HUDContent {
        guard let level = pointer.liveLevel, pointer.liveIsBrightness == isBrightness else { return self }
        return with(level: level, muted: isMuted && level <= 0)
    }

    /// Whether the island in `island` (nil: the main one) draws this HUD.
    func isDrawn(onIsland island: CGDirectDisplayID?) -> Bool {
        mirrorTarget == island
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

/// Which island a view is drawn in: nil for the main island, the display ID
/// for an All Displays mirror (`NotchWindowController.makeMirror` sets it).
/// A HUD aimed at one display draws only on that display's island.
struct HUDIslandDisplayKey: EnvironmentKey {
    static let defaultValue: CGDirectDisplayID? = nil
}

extension EnvironmentValues {
    var hudIslandDisplayID: CGDirectDisplayID? {
        get { self[HUDIslandDisplayKey.self] }
        set { self[HUDIslandDisplayKey.self] = newValue }
    }
}

/// Colors for every HUD form, in both looks.
enum HUDPalette {
    /// The icon: yellow sun and cyan device in Apple, monochrome in SparkV Red.
    static func icon(_ content: HUDContent) -> Color {
        switch content.style {
        case .brightness: SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.text)
        case .outputDevice: SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.text)
        case .volume: content.isMuted ? SparkVTheme.textTertiary : SparkVTheme.text
        }
    }

    /// The filled part of the bar: white (warm for brightness) in Apple,
    /// signal red in SparkV Red; grey while muted.
    static func fill(_ content: HUDContent) -> Color {
        if content.isMuted { return SparkVTheme.textTertiary }
        if SparkVTheme.isApple {
            return content.isBrightness ? Color(red: 1, green: 0.85, blue: 0.35) : Color.white
        }
        return SparkVTheme.red
    }

    /// The percentage text.
    static func percent(_ content: HUDContent) -> Color {
        content.isMuted ? SparkVTheme.textTertiary : SparkVTheme.text
    }
}

/// Band for the volume / brightness HUD: icon on the left, a rounded level bar
/// in the middle (with the device name for an output switch), percentage on
/// the right. The column widths match `HUDIslandGeometry`, which the
/// interactive HUD hit-tests against.
struct HUDActivityView: View {
    private let posted: HUDContent
    /// The band under the notch also takes clicks, drags and scrolls when the
    /// HUD is interactive; the bar grows a little while the pointer is on it.
    var showsPercent = true
    @ObservedObject private var pointer = HUDPointerState.shared
    @Environment(\.hudIslandDisplayID) private var islandDisplay

    init(content: HUDContent, showsPercent: Bool = true) {
        self.posted = content
        self.showsPercent = showsPercent
    }

    /// The posted HUD, or the level under the pointer while it is dragged.
    private var content: HUDContent { posted.live(pointer) }

    var body: some View {
        let drawn = posted.isDrawn(onIsland: islandDisplay)
        row
            .opacity(drawn ? 1 : 0)
            .accessibilityHidden(!drawn)
    }

    private var row: some View {
        HStack(spacing: HUDIslandGeometry.bandGap) {
            Image(systemName: content.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HUDPalette.icon(content))
                .frame(width: HUDIslandGeometry.bandIcon, height: 16)
                .background(
                    Circle()
                        .fill(SparkVTheme.hoverFill)
                        .frame(width: 24, height: 24)
                        .opacity(pointer.isHovering(.icon, in: .band) ? 1 : 0)
                )
                .animation(SparkVMotion.hover(), value: pointer.isHovering(.icon, in: .band))

            middle
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(showsPercent ? content.percentText : "")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(HUDPalette.percent(content))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: HUDIslandGeometry.bandPercent, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityText)
    }

    private var barHeight: CGFloat {
        pointer.isHovering(.level, in: .band) || pointer.isDragging ? 8 : 6
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
                    HUDLevelBar(level: content.barLevel, fill: HUDPalette.fill(content))
                        .frame(width: 56, height: 5)
                }
            }
        default:
            if let caption = content.captionText {
                HStack(spacing: 8) {
                    Text(caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    bar
                }
            } else {
                bar
            }
        }
    }

    private var bar: some View {
        HUDLevelBar(level: content.barLevel, fill: HUDPalette.fill(content), animates: !pointer.isDragging)
            .frame(height: barHeight)
            .animation(SparkVMotion.hover(), value: barHeight)
    }
}

/// Rounded track with a filled portion, like the system OSD.
struct HUDLevelBar: View {
    let level: Double
    var fill: Color = SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red)
    /// Key presses ease the fill (100 ms); a drag tracks the pointer 1:1.
    var animates = true

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
            // Key-press feedback: a 100 ms ease-out keeps it snappy (the band
            // itself is rebuilt per post, so repeated presses don't queue).
            .animation(animates ? SparkVMotion.easeOut(SparkVMotion.Duration.press) : nil, value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int((min(max(level, 0), 1) * 100).rounded())) percent")
    }
}
