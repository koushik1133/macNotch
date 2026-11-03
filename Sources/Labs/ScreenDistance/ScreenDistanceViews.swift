import SwiftUI

// Views for Screen Distance: the band under the notch, the drawer tab, the
// gear-menu items and the settings section. The full-screen notice is in
// ScreenDistanceOverlay.swift. Controls are custom-drawn (plain buttons, a
// drawn switch) so they match the notch's dark UI and render offscreen.

enum ScreenDistanceStyle {
    /// The eye: mint in Apple (its hub tile color), SparkV red in SparkV Red.
    static var accent: Color { SparkVTheme.choose(apple: Color.mint, sparkv: SparkVTheme.red) }
    /// "Too close" is the one alarm here: system red in Apple, the brand
    /// red in SparkV Red.
    static var warning: Color { SparkVTheme.destructive }
    static var caution: Color { SparkVTheme.warning }
    static var good: Color { SparkVTheme.success }

    static func color(distance: Double?, threshold: Double) -> Color {
        guard let distance else { return SparkVTheme.textTertiary }
        if distance < threshold { return warning }
        if distance <= threshold + ScreenDistanceController.clearMarginCM { return caution }
        return good
    }

    static func centimeters(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) cm" } ?? "– cm"
    }

    static func inches(_ value: Double) -> String {
        "\(Int(ScreenDistanceMath.inches(value).rounded())) in"
    }
}

// MARK: - Gauge

/// A horizontal scale from 20 to 80 cm: red up to the threshold, amber in
/// the hysteresis band, green beyond, and a dot at the current distance.
struct ScreenDistanceGauge: View {
    let distance: Double?
    let threshold: Double
    var height: CGFloat = 6
    var showsLabels = false

    static let range: ClosedRange<Double> = 20...80

    var body: some View {
        VStack(spacing: 3) {
            if showsLabels {
                // The threshold, written above its spot on the scale.
                GeometryReader { geo in
                    Text("\(Int(threshold)) cm")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize()
                        .position(x: position(of: threshold, width: geo.size.width), y: geo.size.height / 2)
                }
                .frame(height: 12)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let clear = threshold + ScreenDistanceController.clearMarginCM
                ZStack(alignment: .leading) {
                    Capsule().fill(SparkVTheme.stroke)
                    HStack(spacing: 0) {
                        Rectangle().fill(ScreenDistanceStyle.warning.opacity(0.75))
                            .frame(width: position(of: threshold, width: width))
                        Rectangle().fill(ScreenDistanceStyle.caution.opacity(0.75))
                            .frame(width: max(0, position(of: clear, width: width) - position(of: threshold, width: width)))
                        Rectangle().fill(ScreenDistanceStyle.good.opacity(0.75))
                    }
                    .clipShape(Capsule())
                    if let distance {
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                            .frame(width: height + 6, height: height + 6)
                            .offset(x: position(of: distance, width: width) - (height + 6) / 2)
                    }
                }
                .frame(height: height)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: height + 6)
            if showsLabels {
                HStack {
                    Text("Too close").foregroundStyle(ScreenDistanceStyle.warning)
                    Spacer()
                    Text("Comfortable").foregroundStyle(ScreenDistanceStyle.good)
                }
                .font(.system(size: 10, weight: .medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance \(ScreenDistanceStyle.centimeters(distance)), minimum \(Int(threshold)) centimetres")
    }

    private func position(of value: Double, width: CGFloat) -> CGFloat {
        let span = Self.range.upperBound - Self.range.lowerBound
        let clamped = min(Self.range.upperBound, max(Self.range.lowerBound, value))
        return CGFloat((clamped - Self.range.lowerBound) / span) * width
    }
}

// MARK: - Band under the notch

/// "Too close: 32 cm, move back" (about 400×30, dark). Updates live while
/// the camera streams during the notice.
struct ScreenDistanceBandView: View {
    @ObservedObject var controller: ScreenDistanceController

    var body: some View {
        let safe = controller.alertPhase == .safe
        HStack(spacing: 10) {
            Image(systemName: safe ? "checkmark.circle.fill" : "eye.trianglebadge.exclamationmark.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(safe ? ScreenDistanceStyle.good : ScreenDistanceStyle.warning)
                .frame(width: 22, height: 16)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScreenDistanceGauge(distance: controller.distanceCM, threshold: controller.thresholdCM, height: 4)
                .frame(width: 92)
        }
        .padding(.horizontal, 16)
    }

    private var title: String {
        let distance = ScreenDistanceStyle.centimeters(controller.distanceCM)
        if controller.alertPhase == .safe { return "Good distance: \(distance)" }
        if controller.distanceCM == nil { return "Too close, move back" }
        return "Too close: \(distance), move back"
    }
}

/// Shown for a moment after the notice clears.
struct ScreenDistanceThanksBandView: View {
    let distanceText: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ScreenDistanceStyle.good)
                .frame(width: 22, height: 16)
            Text("\(Text("That’s better").foregroundStyle(SparkVTheme.text))\(Text(" · \(distanceText)").foregroundStyle(SparkVTheme.textTertiary))")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Drawer tab

/// Screen Distance's drawer page (about 508×69 pt, dark): on/off, the live
/// distance with a gauge, today's totals and Calibrate. Needs
/// `ScreenDistanceController` as an environment object.
struct ScreenDistanceDrawerView: View {
    @EnvironmentObject private var controller: ScreenDistanceController

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "eye")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(controller.isEnabled ? ScreenDistanceStyle.accent : SparkVTheme.textSecondary)
                Text("Screen Distance")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(SparkVTheme.text)
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if controller.isEnabled {
                    ScreenDistanceChipButton(
                        title: controller.isUserPaused ? "Resume" : "Pause",
                        systemImage: controller.isUserPaused ? "play.fill" : "pause.fill"
                    ) { controller.togglePause() }
                }
                ScreenDistanceChipButton(title: controller.isCalibrating ? "Calibrating…" : "Calibrate", systemImage: "ruler") {
                    controller.calibrate()
                }
                .disabled(controller.isCalibrating || !controller.isEnabled)
                .opacity(controller.isEnabled ? 1 : 0.45)
                ScreenDistanceSwitch(isOn: $controller.isEnabled)
                    .help(controller.isEnabled ? "Turn Screen Distance off" : "Turn Screen Distance on")
            }

            HStack(spacing: 10) {
                Text(controller.isEnabled ? ScreenDistanceStyle.centimeters(controller.distanceCM) : "Off")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .tracking(-0.4)
                    .foregroundStyle(controller.isEnabled
                        ? ScreenDistanceStyle.color(distance: controller.distanceCM, threshold: controller.thresholdCM)
                        : SparkVTheme.textTertiary)
                    .frame(width: 62, alignment: .leading)
                ScreenDistanceGauge(
                    distance: controller.isEnabled ? controller.distanceCM : nil,
                    threshold: controller.thresholdCM, height: 5
                )
                .frame(width: 150)
                .opacity(controller.isEnabled ? 1 : 0.4)
                Text("Today: \(controller.todayStats.summary)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusText: String {
        // While calibrating, and for a few seconds after (the result).
        if let message = controller.calibrationMessage { return message }
        switch controller.state {
        case .off: return "Warns when you sit closer than \(Int(controller.thresholdCM)) cm"
        case .paused: return controller.pauseReason?.label ?? "Paused"
        case .measuring: return "Checking every \(Int(controller.intervalSeconds)) s · on this Mac only"
        case .tooClose: return "Too close, move back"
        case .noFace: return "No face in view"
        case .noPermission: return "Needs camera access"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .tooClose, .noPermission: ScreenDistanceStyle.warning
        default: SparkVTheme.textTertiary
        }
    }
}

// MARK: - Gear menu

/// Items for a `Menu("Screen Distance") { ... }` in the gear menu.
struct ScreenDistanceMenuItems: View {
    @ObservedObject var controller: ScreenDistanceController

    var body: some View {
        Toggle("Screen Distance", isOn: $controller.isEnabled)
        if controller.isEnabled {
            Button(controller.isUserPaused ? "Resume" : "Pause") { controller.togglePause() }
            if controller.snoozedUntil != nil {
                Button("Cancel Snooze") { controller.cancelSnooze() }
            } else {
                Button("Snooze for 15 Minutes") { controller.snooze(minutes: 15) }
                Button("Snooze for 1 Hour") { controller.snooze(minutes: 60) }
            }
            Button("Calibrate at \(Int(controller.calibrationReferenceCM)) cm") { controller.calibrate() }
            Divider()
            Toggle("Full-Screen Alert", isOn: $controller.showsFullScreenAlert)
            Toggle("Allow Skipping with Esc", isOn: $controller.allowSkipping)
            Toggle("Pause Below 20% Battery", isOn: $controller.pauseOnLowBattery)
            if controller.state == .noPermission {
                Button("Allow Camera Access…") { controller.openCameraPrivacySettings() }
            }
        }
    }
}

// MARK: - Settings section

/// A settings block (about 420 pt wide) for a settings window or popover.
struct ScreenDistanceSettingsSection: View {
    @ObservedObject var controller: ScreenDistanceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Distance").font(SparkVTheme.headline(13)).tracking(-0.2).foregroundStyle(SparkVTheme.text)
                    Text("Warns when your face is closer than \(Int(controller.thresholdCM)) cm (\(ScreenDistanceStyle.inches(controller.thresholdCM))) for \(Int(ScreenDistanceController.triggerSeconds)) seconds.")
                        .font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary)
                }
                Spacer()
                ScreenDistanceSwitch(isOn: $controller.isEnabled)
            }

            Group {
                HStack {
                    Text("Warn closer than").font(.system(size: 12))
                    Slider(value: $controller.thresholdCM, in: ScreenDistanceSettings.thresholdRange, step: 5)
                        .accessibilityLabel("Warn closer than")
                    Text("\(Int(controller.thresholdCM)) cm").font(.system(size: 12).monospacedDigit()).frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("Check every").font(.system(size: 12))
                    Picker("", selection: $controller.intervalSeconds) {
                        ForEach(ScreenDistanceSettings.intervalChoices, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .accessibilityLabel("Check every")
                    Spacer()
                }
                Toggle("Full-screen alert (otherwise only the band under the notch)", isOn: $controller.showsFullScreenAlert)
                Toggle("Allow skipping with Esc", isOn: $controller.allowSkipping)
                Toggle("Pause on battery below 20%", isOn: $controller.pauseOnLowBattery)
                HStack(spacing: 8) {
                    Text("I sit").font(.system(size: 12))
                    Stepper(value: $controller.calibrationReferenceCM, in: 25...120, step: 5) {
                        Text("\(Int(controller.calibrationReferenceCM)) cm from the screen").font(.system(size: 12).monospacedDigit())
                    }
                    Button(controller.isCalibrating ? "Calibrating…" : "Calibrate") { controller.calibrate() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .disabled(controller.isCalibrating)
                    if controller.calibrationScale != 1 {
                        Button("Reset") { controller.resetCalibration() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                }
                if let message = controller.calibrationMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary)
                }
                if controller.state == .noPermission {
                    Button("Allow Camera Access in System Settings…") { controller.openCameraPrivacySettings() }
                        .buttonStyle(SparkVPrimaryButtonStyle())
                }
            }
            .disabled(!controller.isEnabled)
            .font(.system(size: 12))
            .tint(SparkVTheme.accent)

            Text("Uses the FaceTime camera for about a second at a time; the green camera light shows when it does. Frames are analysed on this Mac and never saved or sent anywhere.")
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
    }
}

// MARK: - Small controls

struct ScreenDistanceChipButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
    }
}

/// A drawn on/off switch (the native one doesn't render offscreen and is
/// too large for the drawer).
struct ScreenDistanceSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                // Apple: the system switch's accent fill; SparkV Red: red.
                Capsule().fill(isOn ? SparkVTheme.accent : Color.white.opacity(0.2))
                Circle().fill(Color.white).padding(2)
            }
            .frame(width: 30, height: 18)
            // Knob slide: the interruptible snappy spring for toggles.
            .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screen Distance")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
