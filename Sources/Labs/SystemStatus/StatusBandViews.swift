import AppKit
import SwiftUI

// Bands and compact pieces posted by the System Status controllers. Same
// layout as the battery band: a 34 pt icon column, one line of text, a small
// trailing item, 16 pt side padding, on the island's black.

// MARK: - Palette

enum PrivacyPalette {
    /// macOS's own meaning in both looks: green camera, orange microphone,
    /// purple screen capture.
    static func color(_ sensor: PrivacySensor) -> Color {
        switch sensor {
        case .camera: Color(red: 0.20, green: 0.84, blue: 0.35)
        case .microphone: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .screen: Color(red: 0.69, green: 0.45, blue: 1.0)
        }
    }
}

enum KeepAwakePalette {
    /// Warm coffee amber in Apple; monochrome in SparkV Red, where red
    /// stays for live and recording state.
    static var tint: Color {
        SparkVTheme.choose(apple: Color(red: 1.0, green: 0.72, blue: 0.36), sparkv: SparkVTheme.text)
    }
}

// MARK: - Generic band

/// Icon, a title, a quieter detail.
struct StatusBand: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 16)
            Text("\(Text(title).foregroundStyle(SparkVTheme.text))\(Text(detail.map { " · \($0)" } ?? "").foregroundStyle(SparkVTheme.textSecondary))")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail, trailing].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Peripheral

struct PeripheralActivityView: View {
    enum Mode: Equatable { case connected, low }

    let device: PeripheralBattery
    let mode: Mode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(mode == .low ? tint : SparkVTheme.text)
                .frame(width: 34, height: 16)
            Text("\(Text(device.bandName).foregroundStyle(mode == .low ? tint : SparkVTheme.text))\(Text(mode == .low ? " · Low battery" : (device.isCharging ? " · Charging" : "")).foregroundStyle(SparkVTheme.textSecondary))")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing.fixedSize()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name)\(mode == .low ? ", low battery" : " connected")\(device.percent.map { ", \($0) percent" } ?? "")")
    }

    private var tint: Color { BatteryTint.color(level: device.percent ?? 100) }

    @ViewBuilder
    private var trailing: some View {
        if let percent = device.percent {
            HStack(spacing: 6) {
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(mode == .low ? tint : SparkVTheme.text)
                BatteryGlyph(level: percent, isCharging: device.isCharging, tint: tint)
            }
        } else {
            Text(SparkVTheme.isApple ? "Connected" : "CONNECTED")
                .font(SparkVTheme.isApple ? .system(size: 10, weight: .semibold) : SparkVTheme.eyebrow(9.5))
                .tracking(SparkVTheme.isApple ? 0 : 0.6)
                .foregroundStyle(SparkVTheme.choose(apple: SparkVTheme.textSecondary, sparkv: SparkVTheme.textTertiary))
        }
    }
}

/// A slim level bar for lists: track, fill in the battery color, number.
struct StatusLevelBar: View {
    let percent: Int?
    var isCharging = false
    var width: CGFloat = 22

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(SparkVTheme.surfaceHover)
                if let percent {
                    Capsule()
                        .fill(BatteryTint.color(level: percent))
                        .frame(width: max(3, width * CGFloat(percent) / 100))
                }
            }
            .frame(width: width, height: 5)
            if let percent, percent <= 20, !isCharging, SparkVTheme.differentiateWithoutColor {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(BatteryTint.color(level: percent))
                    .accessibilityHidden(true)
            }
            Group {
                if let percent {
                    Text(isCharging ? "\(percent)%⚡︎" : "\(percent)%")
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(SparkVTheme.text)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 26, alignment: .trailing)
        }
    }
}

/// "64%" in the battery color (green, orange, red), with a bolt while it
/// charges: for narrow lists.
struct StatusPercentLabel: View {
    let percent: Int?
    var isCharging = false

    var body: some View {
        HStack(spacing: 2) {
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(SparkVTheme.success)
            }
            if let percent, percent <= 20, !isCharging, SparkVTheme.differentiateWithoutColor {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(BatteryTint.color(level: percent))
            }
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent.map { $0 > 20 ? SparkVTheme.text : BatteryTint.color(level: $0) } ?? SparkVTheme.textTertiary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Privacy

/// The dots macOS uses (green camera, orange mic, purple screen), in a row.
struct PrivacyDots: View {
    let sensors: [PrivacySensor]
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: size * 0.55) {
            ForEach(sensors, id: \.self) { sensor in
                if SparkVTheme.differentiateWithoutColor {
                    // Differentiate Without Color: each sensor's own glyph,
                    // so the camera and the microphone don't differ only in hue.
                    Image(systemName: sensor.symbol)
                        .font(.system(size: size * 1.25, weight: .bold))
                        .foregroundStyle(PrivacyPalette.color(sensor))
                        .frame(minWidth: size, minHeight: size)
                } else {
                    Circle()
                        .fill(PrivacyPalette.color(sensor))
                        .frame(width: size, height: size)
                        .shadow(color: PrivacyPalette.color(sensor).opacity(0.55), radius: size * 0.45)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sensors.isEmpty ? "Microphone and camera off" : sensors.map(\.title).joined(separator: ", ") + " in use")
    }
}

/// The app's icon (or a person glyph when it can't be named).
struct PrivacyAppBadge: View {
    let app: PrivacyApp?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let app, let icon = PrivacyAppNamer.icon(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // A web page (WebKit helper) gets a globe, not an empty app.
                Image(systemName: app?.bundleID == nil && app?.name == PrivacyAppNamer.webPageName ? "globe" : "app.fill")
                    .font(.system(size: size * 0.7, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(app?.name ?? "An app")
    }
}

struct PrivacyActivityView: View {
    let snapshot: PrivacySnapshot

    var body: some View {
        HStack(spacing: 10) {
            PrivacyDots(sensors: snapshot.sensors, size: 8)
                .frame(width: 34, height: 16)
            Text(snapshot.headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(snapshot.sensors, id: \.self) { sensor in
                    Image(systemName: sensor.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PrivacyPalette.color(sensor))
                }
                PrivacyAppBadge(app: snapshot.leadApp, size: 16)
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.headline + " in use")
    }
}

// MARK: - Keep awake

struct KeepAwakeActivityView: View {
    let session: KeepAwakeSession

    var body: some View {
        // The schedule only re-renders; the time is read fresh (its dates
        // sit on minute boundaries).
        TimelineView(.everyMinute) { _ in
            StatusBand(
                symbol: "cup.and.saucer.fill",
                tint: KeepAwakePalette.tint,
                title: "Keep Awake",
                detail: detail,
                trailing: session.until.map { StatusFormat.remaining(until: $0, now: Date()) } ?? "On"
            )
        }
    }

    private var detail: String {
        switch session.reason {
        case .manual: session.mode == .display ? "Display stays on" : "Display may sleep"
        case .app(let name): "While \(name) runs"
        }
    }
}

/// Minutes left beside the notch ("58m", "1:30", "∞").
struct KeepAwakeCompactTime: View {
    let until: Date?

    var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(StatusFormat.compactRemaining(until: until, now: Date()))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(KeepAwakePalette.tint)
                .fixedSize()
        }
        .accessibilityLabel(until.map { "\(StatusFormat.remaining(until: $0, now: Date())) left" } ?? "Until turned off")
    }
}

// MARK: - Mic mute

struct MicMuteBand: View {
    let isMuted: Bool
    let deviceName: String?
    let message: String?

    var body: some View {
        StatusBand(
            symbol: isMuted ? "mic.slash.fill" : "mic.fill",
            tint: isMuted ? SparkVTheme.recording : SparkVTheme.text,
            title: message ?? (isMuted ? "Microphone muted" : "Microphone on"),
            detail: message == nil ? deviceName : nil,
            trailing: MicMuteController.shortcut.displayString
        )
    }
}

// MARK: - Caps Lock

struct CapsLockBand: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOn ? "capslock.fill" : "capslock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(width: 34, height: 16)
            Text(isOn ? "Caps Lock On" : "Caps Lock Off")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(isOn ? "ABC" : "abc")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isOn ? SparkVTheme.islandBackground : SparkVTheme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(isOn ? SparkVTheme.text : SparkVTheme.surfaceHover))
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOn ? "Caps Lock on" : "Caps Lock off")
    }
}
