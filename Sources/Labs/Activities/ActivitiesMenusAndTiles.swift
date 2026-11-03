import AppKit
import SwiftUI

// MARK: - Gear menu

/// Items for the gear menu's "Live Activities" submenu, after its feature
/// switches: which activity rests in the wings, ⌃⌥A, and the Timing,
/// Notifications, Calls and VoiceOver submenus.
struct LiveActivitiesMenuItems: View {
    var body: some View {
        if let center = LiveActivitiesController.current?.activities {
            ShowInWingsMenu(center: center)
        }
        Divider()
        Menu("Timing") { ActivityTimingMenuItems() }
        Menu("Notification Options") { NotificationsMenuItems() }
        Menu("Calls") { CallsMenuItems() }
        Toggle("Announce to VoiceOver", isOn: Binding(
            get: { ActivityAnnouncementSettings.shared.isEnabled },
            set: { ActivityAnnouncementSettings.shared.isEnabled = $0 }
        ))
    }
}

/// "Show in Wings": Automatic or one of the running activities, plus Next.
private struct ShowInWingsMenu: View {
    @ObservedObject var center: ActivityCenter
    @ObservedObject private var settings = LiveActivitiesSettings.shared

    var body: some View {
        Menu("Show in Wings") {
            Picker("Show in Wings", selection: Binding(
                get: { center.pinnedCompactID ?? "" },
                set: { center.pin(id: $0.isEmpty ? nil : $0) }
            )) {
                Text("Most Important").tag("")
                ForEach(center.running) { item in
                    Text(item.title).tag(item.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Next Activity" + (settings.cycleHotkeyEnabled ? "  \(LiveActivitiesController.cycleShortcut.displayString)" : "")) {
                LiveActivitiesController.current?.showNextFromKeyboard()
            }
            .disabled(center.running.count < 2)
        }
        .disabled(center.running.isEmpty)
    }
}

/// Timing submenu: durations as pickers, the toggles below.
struct ActivityTimingMenuItems: View {
    @ObservedObject private var timing = ActivityTimingSettings.shared

    var body: some View {
        Picker("Notifications Stay", selection: $timing.notificationSeconds) {
            ForEach(ActivityTimingSettings.notificationChoices, id: \.self) { Text(ActivityTimingSettings.label($0)).tag($0) }
        }
        Picker("Volume & Brightness Stay", selection: $timing.hudSeconds) {
            ForEach(ActivityTimingSettings.hudChoices, id: \.self) { Text(ActivityTimingSettings.label($0)).tag($0) }
        }
        Picker("New Activities Peek For", selection: $timing.peekSeconds) {
            ForEach(ActivityTimingSettings.peekChoices, id: \.self) { Text(ActivityTimingSettings.label($0)).tag($0) }
        }
        Picker("Song Title Shows For", selection: $timing.titlePeekSeconds) {
            ForEach(ActivityTimingSettings.titlePeekChoices, id: \.self) { Text(ActivityTimingSettings.label($0)).tag($0) }
        }
        .disabled(timing.alwaysShowTitle)
        Picker("Song Title Width", selection: $timing.titleWidth) {
            ForEach(ActivityTimingSettings.TitleWidth.allCases) { Text($0.label).tag($0) }
        }
        Divider()
        Toggle("Always Show Song Title", isOn: $timing.alwaysShowTitle)
        Toggle("Expand on Track Change", isOn: $timing.peekOnTrackChange)
        Toggle("Expand on Play & Pause", isOn: $timing.peekOnPlayPause)
        Toggle("Wait While Pointer Is on an Alert", isOn: $timing.pausesOnHover)
        Divider()
        Button("Reset Timing") { timing.resetToDefaults() }
            .disabled(timing.isDefault)
    }
}

/// Notification options: privacy, buttons, filter, muted apps.
struct NotificationsMenuItems: View {
    @ObservedObject private var prefs = NotificationPreferences.shared

    var body: some View {
        Toggle("Hide the Sender Too", isOn: $prefs.hidesSender)
            .disabled(!(NotificationMonitor.current?.hidesMessageBody ?? false))
        Toggle("Reply & Dismiss Buttons", isOn: $prefs.showsActions)
        Divider()
        Picker("Show From", selection: $prefs.filterMode) {
            ForEach(NotificationPreferences.FilterMode.allCases) { Text($0.label).tag($0) }
        }
        if let app = NotificationMonitor.current?.lastNotification?.appName {
            if prefs.isShown(app) {
                Button("Mute \(app)") { prefs.setShown(app, false) }
            } else {
                Button("Unmute \(app)") { prefs.setShown(app, true) }
            }
        }
        let apps = prefs.knownApps
        if !apps.isEmpty {
            Menu(prefs.filterMode == .onlyAllowed ? "Apps Shown" : "Muted Apps") {
                ForEach(apps, id: \.self) { app in
                    Toggle(app, isOn: Binding(
                        get: { prefs.filterMode == .onlyAllowed ? prefs.isShown(app) : !prefs.isShown(app) },
                        set: { prefs.setShown(app, prefs.filterMode == .onlyAllowed ? $0 : !$0) }
                    ))
                }
            }
        }
        Divider()
        Button("macOS Notification Settings…") { NotificationMonitor.openSystemNotificationSettings() }
    }
}

/// Calls submenu. The microphone item is the Mac's one mute
/// (`MicMuteController`, ⌃⌥M), live while SparkV runs.
struct CallsMenuItems: View {
    @ObservedObject private var prefs = CallPreferences.shared
    @ObservedObject private var microphone = MicMuteController.shared

    var body: some View {
        Toggle("Show Ongoing Calls", isOn: $prefs.showsOngoingCalls)
        if let calls = CallsController.current, !calls.detectsCalls {
            Button("Turn On Call Detection for the Timer") { calls.turnOnCallDetection() }
                .disabled(!prefs.showsOngoingCalls)
        }
        Toggle("Incoming FaceTime & iPhone Calls", isOn: $prefs.showsIncomingCalls)
        Toggle("Watch Call Apps' Ringing Windows", isOn: $prefs.watchesCallWindows)
            .disabled(!prefs.showsIncomingCalls)
        Toggle("Unmute When a Call Ends", isOn: $prefs.unmutesWhenCallEnds)
        Divider()
        Button(microphone.isMuted ? "Unmute Microphone" : "Mute Microphone") {
            if let calls = CallsController.current { calls.toggleMute() } else { microphone.setMuted(!microphone.isMuted) }
        }
        .disabled(!microphone.canMute)
    }
}

// MARK: - Agents hub tiles

/// Shared face for this package's hub tiles, matching `AgentTile`: Apple
/// draws the glyph in its tint on a dark tile (a tint wash while on);
/// SparkV Red is monochrome and lights red on hover or while on.
struct ActivityHubTileFace: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isOn = false
    var isDimmed = false
    let hovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        let apple = SparkVTheme.usesTileTints
        let lit = isOn || hovering
        let glyph: Color = apple
            ? (isDimmed ? SparkVTheme.textTertiary : tint)
            : (lit ? SparkVTheme.red : (isDimmed ? SparkVTheme.textTertiary : SparkVTheme.text.opacity(0.88)))
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(glyph)
                .frame(height: 20)
            Text(title)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(apple
                    ? Color.white.opacity(lit ? 1 : (isDimmed ? 0.55 : 0.82))
                    : (lit ? SparkVTheme.text : SparkVTheme.textSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(shape.fill(apple
            ? (isOn ? tint.opacity(0.24) : Color.white.opacity(hovering ? 0.14 : 0.08))
            : (isOn ? SparkVTheme.redSoft : (hovering ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface))))
        .overlay(shape.strokeBorder(apple
            ? (isOn ? tint.opacity(0.45) : Color.clear)
            : (lit ? SparkVTheme.red.opacity(isOn ? 0.55 : 0.35) : SparkVTheme.stroke), lineWidth: 1))
        .contentShape(shape)
        .animation(SparkVMotion.hover(), value: hovering)
    }
}

/// Live Activities (category: System). Click: the next running activity in
/// the wings. Right-click: pick one, timing.
struct LiveActivitiesHubTile: View {
    @StateObject private var hover = ViewFlag()

    var body: some View {
        if let center = LiveActivitiesController.current?.activities {
            LiveActivitiesHubTileBody(center: center, hover: hover)
        } else {
            ActivityHubTileFace(title: "Live", systemImage: "dot.radiowaves.left.and.right", tint: .orange, isDimmed: true, hovering: false)
        }
    }
}

private struct LiveActivitiesHubTileBody: View {
    @ObservedObject var center: ActivityCenter
    @ObservedObject var hover: ViewFlag

    var body: some View {
        let count = center.running.count
        Button {
            LiveActivitiesController.current?.showNextFromKeyboard()
        } label: {
            ActivityHubTileFace(
                title: count == 0 ? "Live" : "\(count) Live",
                systemImage: "dot.radiowaves.left.and.right",
                tint: .orange,
                isOn: center.pinnedCompactID != nil,
                // Full colour at rest: the tile always works (it shows
                // the next activity). Dimming means unavailable.
                isDimmed: false,
                hovering: hover.isOn
            )
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu {
            ShowInWingsMenu(center: center)
            Menu("Timing") { ActivityTimingMenuItems() }
        }
        .help(help(count))
        .accessibilityLabel("Live Activities")
        .accessibilityValue(count == 1 ? "1 running" : "\(count) running")
        .accessibilityHint(count > 1 ? "Shows the next one beside the notch" : "")
    }

    private func help(_ count: Int) -> String {
        switch count {
        case 0: "Live Activities: nothing running"
        case 1: "Live Activities: \(center.running[0].title). Click to peek."
        default: "Live Activities: \(count) running. Click for the next one (\(LiveActivitiesController.cycleShortcut.displayString)); right-click to pick."
        }
    }
}

/// Notifications (category: Focus). Click: previews on / off. Right-click:
/// privacy and apps.
struct NotificationsHubTile: View {
    @StateObject private var hover = ViewFlag()

    var body: some View {
        if let monitor = NotificationMonitor.current {
            NotificationsHubTileBody(monitor: monitor, hover: hover)
        } else {
            ActivityHubTileFace(title: "Alerts", systemImage: "bell.badge.fill", tint: .red, isDimmed: true, hovering: false)
        }
    }
}

private struct NotificationsHubTileBody: View {
    @ObservedObject var monitor: NotificationMonitor
    @ObservedObject var hover: ViewFlag

    var body: some View {
        let on = monitor.isEnabled
        Button {
            monitor.isEnabled.toggle()
        } label: {
            ActivityHubTileFace(
                title: on ? (monitor.hidesMessageBody ? "Private" : "Alerts") : "Alerts Off",
                systemImage: on ? "bell.badge.fill" : "bell.slash.fill",
                tint: .red,
                isDimmed: !on,
                hovering: hover.isOn
            )
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu {
            Toggle("Notifications Under the Notch", isOn: $monitor.isEnabled)
            Toggle("Hide Message Text", isOn: $monitor.hidesMessageBody)
            NotificationsMenuItems()
        }
        .help(on ? "Notifications appear under the notch. Click to stop; right-click for privacy and apps."
                 : "Notifications don't appear under the notch. Click to show them.")
        .accessibilityLabel("Notifications under the notch")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Calls (category: Media). On a call: the elapsed time, and a click
/// mutes or unmutes the microphone for the call. Otherwise: incoming calls
/// on / off (the plain microphone tile is System Status's Mic Mute).
struct CallsHubTile: View {
    @StateObject private var hover = ViewFlag()

    var body: some View {
        if let calls = CallsController.current {
            CallsHubTileBody(calls: calls, prefs: calls.prefs, microphone: calls.microphone, hover: hover)
        } else {
            ActivityHubTileFace(title: "Calls", systemImage: "phone.fill", tint: .green, isDimmed: true, hovering: false)
        }
    }
}

private struct CallsHubTileBody: View {
    @ObservedObject var calls: CallsController
    @ObservedObject var prefs: CallPreferences
    @ObservedObject var microphone: MicMuteController
    @ObservedObject var hover: ViewFlag

    var body: some View {
        if let call = calls.activeCall {
            TimelineView(.periodic(from: call.startedAt, by: 1)) { context in
                Button {
                    calls.toggleMute()
                } label: {
                    ActivityHubTileFace(
                        title: (microphone.isMuted ? "Muted " : "") + Self.elapsed(context.date.timeIntervalSince(call.startedAt)),
                        systemImage: microphone.isMuted ? "mic.slash.fill" : "phone.fill",
                        tint: microphone.isMuted ? SparkVTheme.destructive : .green,
                        isOn: true, isDimmed: false, hovering: hover.isOn
                    )
                }
                .buttonStyle(SparkVPressStyle())
                .disabled(!microphone.canMute)
                .onHover { hover.isOn = $0 }
                .contextMenu { CallsMenuItems() }
                .help("On a \(call.service) call. Click to \(microphone.isMuted ? "unmute" : "mute") the microphone.")
                .accessibilityLabel("\(call.service) call")
                .accessibilityValue(microphone.isMuted ? "Microphone muted" : "Microphone on")
            }
        } else {
            let on = prefs.showsIncomingCalls
            Button {
                prefs.showsIncomingCalls.toggle()
            } label: {
                ActivityHubTileFace(title: on ? "Calls" : "Calls Off", systemImage: on ? "phone.fill" : "phone.down.fill",
                                    tint: .green, isOn: false, isDimmed: !on, hovering: hover.isOn)
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { hover.isOn = $0 }
            .contextMenu { CallsMenuItems() }
            .help(on ? "Ringing calls show Accept and Decline under the notch. Click to stop; right-click for options."
                     : "Ringing calls don't show under the notch. Click to show them.")
            .accessibilityLabel("Incoming calls under the notch")
            .accessibilityValue(on ? "On" : "Off")
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
