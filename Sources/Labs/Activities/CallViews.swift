import AppKit
import SwiftUI

// MARK: - Compact and minimal

/// The call app's icon (or a green phone) for the wings.
struct CallAppBadge: View {
    let icon: NSImage?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Circle().fill(SparkVTheme.success)
                    Image(systemName: "phone.fill")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Elapsed call time in green, counted by SwiftUI itself (no timer of
/// ours); a red slashed mic beside it while muted.
struct CallElapsedLabel: View {
    let startedAt: Date
    var isMuted = false
    var fontSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            if isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: fontSize - 2, weight: .bold))
                    .foregroundStyle(SparkVTheme.destructive)
                    .accessibilityLabel("Microphone muted")
            }
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.success)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Single icon for a call sharing the wings.
struct CallMinimalBadge: View {
    var isMuted = false

    var body: some View {
        ZStack {
            Circle().fill(isMuted ? SparkVTheme.destructive : SparkVTheme.success)
            Image(systemName: isMuted ? "mic.slash.fill" : "phone.fill")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.white)
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(isMuted ? "Call, microphone muted" : "Call")
    }
}

/// A green phone that rings: a soft ring grows and fades around it about
/// once a second (a still phone under Reduce Motion).
struct CallRingingBadge: View {
    @ObservedObject private var energy = SparkVEnergy.shared
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            if !SparkVMotion.reduceMotion {
                TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 30), paused: energy.pausesDecoration)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                    Circle()
                        .stroke(SparkVTheme.success, lineWidth: 1.5)
                        .scaleEffect(1 + 0.45 * phase)
                        .opacity(0.7 * (1 - phase))
                }
            }
            Circle().fill(SparkVTheme.success)
            Image(systemName: "phone.fill")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Ringing")
    }
}

// MARK: - Bands

/// The band for a call that's going on: app icon, title over the elapsed
/// time and microphone state, then Mute and Show.
struct OngoingCallBand: View {
    @ObservedObject var controller: CallsController
    @ObservedObject private var microphone: MicMuteController
    let call: CallsController.ActiveCall
    let icon: NSImage?

    init(controller: CallsController, call: CallsController.ActiveCall, icon: NSImage?) {
        self.controller = controller
        self.microphone = controller.microphone
        self.call = call
        self.icon = icon
    }

    var body: some View {
        let muted = microphone.isMuted
        HStack(spacing: 10) {
            CallAppBadge(icon: icon, size: 26)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.hasGenericTitle ? "\(call.service) call" : call.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    CallElapsedLabel(startedAt: call.startedAt, fontSize: 11)
                    Text("·").foregroundStyle(SparkVTheme.textTertiary)
                    Text(muted ? "Microphone muted" : (call.hasGenericTitle ? "Microphone on" : call.service))
                        .foregroundStyle(muted ? SparkVTheme.destructive : SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if microphone.canMute {
                    NotificationBandButton(
                        systemImage: muted ? "mic.slash.fill" : "mic.fill",
                        label: muted ? "Unmute Microphone" : "Mute Microphone",
                        tint: muted ? SparkVTheme.destructive : nil
                    ) { controller.toggleMute() }
                }
                if call.iconBundleID != nil {
                    NotificationBandButton(systemImage: "arrow.up.forward.app", label: "Show \(call.service)") {
                        controller.showCallApp()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(muted ? "\(call.service) call, microphone muted" : "\(call.service) call")
        .accessibilityAction(named: muted ? "Unmute" : "Mute") { controller.toggleMute() }
        .accessibilityAction(named: "Show \(call.service)") { controller.showCallApp() }
    }
}

/// A ringing call: who (or just the app), then Decline and Accept, the
/// way the iPhone's Dynamic Island shows it.
struct IncomingCallBand: View {
    @ObservedObject private var energy = SparkVEnergy.shared
    let caller: String?
    let appName: String?
    let detail: String?
    let icon: NSImage?
    var canAccept = true
    var canDecline = true
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(SparkVTheme.eyebrow(9))
                    .tracking(0.6)
                    .foregroundStyle(SparkVTheme.success)
                    .lineLimit(1)
                Text(caller ?? "Incoming call")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if canDecline {
                    NotificationBandButton(systemImage: "phone.down.fill", label: "Decline", tint: SparkVTheme.destructive, size: 32, action: onDecline)
                }
                if canAccept {
                    NotificationBandButton(systemImage: "phone.fill", label: "Accept", tint: SparkVTheme.success, size: 32, action: onAccept)
                }
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ActivityAnnouncementText.incomingCall(app: appName, caller: caller))
        .accessibilityAction(named: "Accept") { onAccept() }
        .accessibilityAction(named: "Decline") { onDecline() }
    }

    /// "FACETIME · AUDIO", "INCOMING CALL".
    private var eyebrow: String {
        var parts: [String] = []
        if let appName, !appName.isEmpty { parts.append(appName) } else { parts.append("Incoming call") }
        if let detail, !detail.isEmpty, detail.count <= 24 {
            // "FaceTime Audio" already names the app: say it once.
            if let appName, detail.lowercased().hasPrefix(appName.lowercased()) { parts = [detail] } else { parts.append(detail) }
        }
        return parts.joined(separator: " · ").uppercased()
    }

    private var avatar: some View {
        ZStack {
            if !SparkVMotion.reduceMotion {
                // One soft ring a second: it's ringing.
                TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 30), paused: energy.pausesDecoration)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Circle()
                        .stroke(SparkVTheme.success.opacity(0.8), lineWidth: 1.5)
                        .scaleEffect(1 + 0.32 * phase)
                        .opacity(1 - phase)
                }
            }
            Circle().fill(SparkVTheme.surfaceHover)
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}
