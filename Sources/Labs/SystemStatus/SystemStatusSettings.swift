import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings sections for the System Status package. Each takes no arguments
// (it reads the `.shared` controllers) and lays out at any width from about
// 380 pt; the Settings window decides the pane (see INTEGRATION.md).

// MARK: - Building blocks

/// A settings card: an icon tile, a title and a one-line summary, an
/// optional switch, then the section's rows (dimmed while switched off).
struct StatusSettingsBlock<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var isOn: Binding<Bool>? = nil
    /// False when the switch is a live action (Keep Awake, Mute), not the
    /// feature's on/off: the rows stay editable.
    var dimsWhenOff = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                StatusSettingsIcon(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SparkVTheme.headline(13))
                        .foregroundStyle(SparkVTheme.text)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let isOn {
                    StatusSwitch(isOn: isOn, label: title)
                }
            }
            VStack(alignment: .leading, spacing: 9, content: content)
                .disabled(dimsWhenOff && isOn?.wrappedValue == false)
                .opacity(dimsWhenOff && isOn?.wrappedValue == false ? 0.45 : 1)
                .animation(SparkVMotion.hover(), value: isOn?.wrappedValue)
        }
        .font(.system(size: 12))
        .tint(SparkVTheme.accent)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(SparkVTheme.surface))
        .overlay(shape.strokeBorder(SparkVTheme.stroke, lineWidth: SparkVTheme.isApple ? 0.5 : 1))
    }
}

/// System Settings-style icon: white glyph on the tint (Apple), red glyph
/// on a dark tile (SparkV Red).
struct StatusSettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SparkVTheme.isApple ? Color.white : SparkVTheme.red)
            .frame(width: 28, height: 28)
            .background(shape.fill(SparkVTheme.isApple ? tint : SparkVTheme.redSoft))
            .overlay(shape.strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.red.opacity(0.3), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A label on the left, a control on the right.
struct StatusSettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(SparkVTheme.text)
            Spacer(minLength: 8)
            control()
        }
    }
}

/// A drawn on/off switch (draws offscreen and in both looks).
struct StatusSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? SparkVTheme.accent : Color.white.opacity(0.2))
                Circle().fill(Color.white).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 19)
            .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A checkbox row (drawn, so it renders the same in both looks).
struct StatusCheck: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String? = nil

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? SparkVTheme.accent : Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : Color.white.opacity(0.28), lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(SparkVTheme.text)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A pill that toggles one value in a set ("20%").
struct StatusChipToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isOn ? Color.white : SparkVTheme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(isOn ? SparkVTheme.accent : Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
                .contentShape(Capsule())
                .animation(SparkVMotion.hover(), value: isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Small print under a section.
struct StatusSettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(SparkVTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A value read live from the system ("84% · 317 cycles").
struct StatusSettingsReadout: View {
    let symbol: String
    let text: String
    var tint: Color = SparkVTheme.textSecondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pickers here are compact menus in both looks.
private extension View {
    func statusMenuPicker() -> some View {
        labelsHidden().pickerStyle(.menu).fixedSize()
    }
}

// MARK: - Battery (System)

struct BatterySettingsSection: View {
    var body: some View {
        if let power = PowerMonitor.current {
            BatterySettingsContent(power: power)
        } else {
            StatusSettingsBlock(symbol: "battery.100percent.bolt", tint: .green, title: "Battery",
                                subtitle: "Battery settings appear once SparkV's island is running.") { EmptyView() }
        }
    }
}

private struct BatterySettingsContent: View {
    @ObservedObject var power: PowerMonitor
    @ObservedObject private var toggles = QuickTogglesController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            batteryBlock
            healthBlock
        }
        .onAppear { power.refreshForDisplay() }
    }

    private var batteryBlock: some View {
        StatusSettingsBlock(
            symbol: "battery.100percent.bolt", tint: .green, title: "Battery",
            subtitle: "A band when the charger goes in or out (with its wattage), warnings as the battery runs down, and a red alert that stays beside the notch until you plug in.",
            isOn: $power.isEnabled
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Warn at").font(.system(size: 12)).foregroundStyle(SparkVTheme.text)
                HStack(spacing: 5) {
                    ForEach(BatteryThresholds.lowChoices, id: \.self) { value in
                        StatusChipToggle(title: "\(value)%", isOn: power.lowThresholds.contains(value)) {
                            power.setLowThreshold(value, enabled: !power.lowThresholds.contains(value))
                        }
                    }
                }
            }
            StatusSettingsRow(title: "Critical alert") {
                Picker("Critical alert", selection: Binding(get: { power.criticalLevel }, set: { power.setCriticalLevel($0) })) {
                    ForEach(BatteryThresholds.criticalChoices, id: \.self) { value in
                        Text(value == 0 ? "Off" : "At \(value)%").tag(value)
                    }
                }
                .statusMenuPicker()
            }
            StatusCheck(title: "Show the charger's wattage", isOn: $power.showsWattage)
            if power.bluetoothAccess == .notDetermined {
                StatusSettingsRow(title: "AirPods battery when they connect") {
                    Button("Allow Bluetooth…") { power.requestBluetoothAccess() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
        }
    }

    private var healthBlock: some View {
        StatusSettingsBlock(
            symbol: "heart.text.square.fill", tint: .pink, title: "Battery Health & Charging",
            subtitle: "Read from macOS when the charger changes and when you open this page; nothing polls."
        ) {
            if let health = power.details?.health {
                StatusSettingsReadout(
                    symbol: health.condition == .serviceRecommended ? "exclamationmark.triangle.fill" : "heart.fill",
                    text: healthText(health),
                    tint: health.condition == .serviceRecommended ? SparkVTheme.warning : .pink
                )
            } else {
                StatusSettingsReadout(symbol: "powerplug.fill", text: power.battery == nil ? "This Mac has no battery." : "Health isn't available on this Mac.")
            }
            if let adapter = power.details?.adapter {
                StatusSettingsReadout(symbol: "bolt.fill", text: [adapter.watts.map { "\($0) W charger connected" } ?? "Charger connected", adapter.isWireless ? "wireless" : nil].compactMap { $0 }.joined(separator: " · "), tint: SparkVTheme.success)
            }
            StatusSettingsRow(title: "Low Power Mode: \(power.isLowPowerMode ? "On" : "Off")") {
                Button(power.isLowPowerMode ? "Turn Off…" : "Turn On…") { toggles.setLowPowerMode(!power.isLowPowerMode) }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .disabled(toggles.busy.contains(.lowPower))
                    .help("Runs “pmset -a lowpowermode” through macOS's administrator dialog.")
            }
            StatusSettingsRow(title: "Charge to Full Now, charge limit") {
                Button("Battery Settings…") { power.openBatterySettings() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
            }
            StatusSettingsNote(text: "Turning Low Power Mode on or off asks for an administrator password each time. macOS doesn't let apps override Optimized Charging or the charge limit; “Charge to Full Now” is in the battery menu in the menu bar and in Battery settings.")
        }
    }

    private func healthText(_ health: BatteryHealthReading) -> String {
        var parts: [String] = []
        if let capacity = health.maximumCapacityPercent { parts.append("Maximum capacity \(capacity)%") }
        if let cycles = health.cycleCount {
            parts.append(health.designCycleCount.map { "\(cycles) of \($0) cycles" } ?? "\(cycles) cycles")
        }
        switch health.condition {
        case .normal: parts.append("Normal")
        case .serviceRecommended: parts.append("Service recommended")
        case .unknown: break
        }
        if let temperature = health.temperature { parts.append(String(format: "%.0f °C", temperature)) }
        return parts.isEmpty ? "No health details from macOS." : parts.joined(separator: " · ")
    }
}

// MARK: - Accessories (System)

struct PeripheralBatterySettingsSection: View {
    @ObservedObject private var monitor = PeripheralBatteryMonitor.shared

    var body: some View {
        StatusSettingsBlock(
            symbol: "magicmouse.fill", tint: .blue, title: "Accessory Batteries",
            subtitle: "Magic Mouse, Keyboard, Trackpad and game controllers: a band when one connects and a warning when it runs low.",
            isOn: $monitor.isEnabled
        ) {
            StatusSettingsRow(title: "Warn when an accessory is at") {
                Picker("Warn at", selection: $monitor.lowThreshold) {
                    ForEach(PeripheralBatteryMonitor.thresholdChoices, id: \.self) { value in
                        Text(value == 0 ? "Never" : "\(value)%").tag(value)
                    }
                }
                .statusMenuPicker()
            }
            StatusCheck(title: "Show a band when one connects", isOn: $monitor.showsConnectBand)
            StatusCheck(title: "Include game controllers", isOn: $monitor.includesGameControllers)
            if monitor.devices.isEmpty {
                StatusSettingsReadout(symbol: "dot.radiowaves.left.and.right", text: "No accessory is reporting a battery right now.")
            } else {
                ForEach(monitor.devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.kind.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .frame(width: 18)
                        Text(device.name).font(.system(size: 12)).foregroundStyle(SparkVTheme.text)
                        Spacer()
                        StatusLevelBar(percent: device.percent, isCharging: device.isCharging, width: 26)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(device.name), \(device.percent.map { "\($0) percent" } ?? "battery unknown")")
                }
            }
            StatusSettingsNote(text: "Read from the battery level the accessory reports to macOS: no Bluetooth permission, and the radio isn't woken. Levels refresh when a device connects and every 15 minutes while one is connected. Most third-party mice report nothing.")
        }
        .onAppear { monitor.refresh() }
    }
}

// MARK: - Keep Awake (System)

struct KeepAwakeSettingsSection: View {
    @ObservedObject private var controller = KeepAwakeController.shared

    var body: some View {
        StatusSettingsBlock(
            symbol: "cup.and.saucer.fill", tint: .brown, title: "Keep Awake",
            subtitle: controller.session.map(Self.status) ?? "Stops your Mac from going to sleep on its own, for a while or while chosen apps run.",
            isOn: Binding(get: { controller.isActive }, set: { $0 ? controller.turnOn(minutes: controller.defaultMinutes) : controller.turnOff() }),
            dimsWhenOff: false
        ) {
            StatusSettingsRow(title: "One tap keeps awake") {
                Picker("Duration", selection: $controller.defaultMinutes) {
                    ForEach(KeepAwakeDurations.choices, id: \.self) { minutes in
                        Text(minutes == nil ? "Until turned off" : "For \(KeepAwakeDurations.title(minutes).lowercased())").tag(minutes)
                    }
                }
                .statusMenuPicker()
            }
            StatusSettingsRow(title: "While on") {
                Picker("While on", selection: $controller.mode) {
                    Text("Keep the display on").tag(KeepAwakeMode.display)
                    Text("Let the display sleep").tag(KeepAwakeMode.system)
                }
                .statusMenuPicker()
            }
            StatusSettingsRow(title: "Turn off on battery at") {
                Picker("Battery cutoff", selection: $controller.batteryCutoff) {
                    ForEach(KeepAwakePolicy.cutoffChoices, id: \.self) { value in
                        Text(value == 0 ? "Never" : "\(value)%").tag(value)
                    }
                }
                .statusMenuPicker()
            }
            StatusCheck(title: "Show a cup and the time left beside the notch", isOn: $controller.showsInNotch)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Keep awake while these apps run").font(.system(size: 12)).foregroundStyle(SparkVTheme.text)
                    Spacer()
                    Button("Add App…") { Self.chooseApp() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
                if controller.watchedApps.isEmpty {
                    StatusSettingsReadout(symbol: "app.dashed", text: "None. Add a video editor, a game or a download manager.")
                } else {
                    ForEach(controller.watchedApps, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                            }
                            Text(KeepAwakeController.appName(bundleID)).font(.system(size: 12)).foregroundStyle(SparkVTheme.text)
                            Spacer()
                            Button { controller.removeWatchedApp(bundleID) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(SparkVTheme.textTertiary)
                            }
                            .buttonStyle(SparkVPressStyle())
                            .accessibilityLabel("Remove \(KeepAwakeController.appName(bundleID))")
                        }
                    }
                }
            }
            StatusSettingsNote(text: "Uses a standard power assertion (it shows as “SparkV Keep Awake” in pmset -g assertions) and ends when SparkV quits. Closing the lid still sleeps a MacBook on battery: stopping that needs administrator rights, which SparkV doesn't use.")
        }
    }

    private static func status(_ session: KeepAwakeSession) -> String {
        switch session.reason {
        case .app(let name): return "On while \(name) runs."
        case .manual: return session.until.map { "On for \(StatusFormat.remaining(until: $0, now: Date())) more." } ?? "On until you turn it off."
        }
    }

    @MainActor
    private static func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(KeepAwakeController.shared.addWatchedApp(at:))
    }
}

// MARK: - Microphone (Media)

struct MicMuteSettingsSection: View {
    @ObservedObject private var controller = MicMuteController.shared

    var body: some View {
        StatusSettingsBlock(
            symbol: controller.isMuted ? "mic.slash.fill" : "mic.fill", tint: .red, title: "Mute Microphone",
            subtitle: controller.deviceName.map { "Mutes \($0) for every app. \(MicMuteController.shortcut.displayString) works from anywhere." }
                ?? "No microphone is connected.",
            isOn: Binding(get: { controller.isMuted }, set: { controller.setMuted($0) }),
            dimsWhenOff: false
        ) {
            StatusCheck(title: "Shortcut \(MicMuteController.shortcut.displayString)", isOn: $controller.hotkeyEnabled)
            if controller.hotkeyFailed {
                StatusSettingsReadout(symbol: "exclamationmark.triangle.fill", text: "SparkV couldn't register \(MicMuteController.shortcut.displayString). Turn the shortcut off and on to retry.", tint: SparkVTheme.warning)
            }
            StatusCheck(title: "Show “Muted” beside the notch", isOn: $controller.showsInNotch, detail: "Also over full-screen apps.")
            if !controller.canMute, controller.deviceName != nil {
                StatusSettingsReadout(symbol: "exclamationmark.triangle.fill", text: "This microphone has no mute or input volume SparkV can set.", tint: SparkVTheme.warning)
            }
            StatusSettingsNote(text: "Mutes the input device itself, so every app hears silence; Zoom or Teams may say the mic is muted by the system. SparkV puts the mic back when it quits, and at its next launch if it ever crashes.")
        }
    }
}

// MARK: - Privacy indicators (Activities)

struct PrivacyIndicatorSettingsSection: View {
    @ObservedObject private var monitor = PrivacyIndicatorMonitor.shared

    var body: some View {
        StatusSettingsBlock(
            symbol: "hand.raised.fill", tint: .orange, title: "Microphone & Camera In Use",
            subtitle: "Orange and green dots beside the notch, naming the app, even over full-screen apps where the menu bar is hidden.",
            isOn: $monitor.isEnabled
        ) {
            StatusCheck(title: "Microphone", isOn: $monitor.watchesMicrophone, detail: "Names the app exactly.")
            StatusCheck(title: "Camera", isOn: $monitor.watchesCamera, detail: "macOS doesn't tell apps who holds the camera, so it shows the likely app.")
            StatusCheck(title: "Screen sharing", isOn: $monitor.watchesScreen, detail: "Best effort, from Smart Moments' sharing detector when it is on.")
            StatusSettingsRow(title: "Show as") {
                Picker("Show as", selection: $monitor.display) {
                    ForEach(PrivacyDisplay.allCases) { display in Text(display.title).tag(display) }
                }
                .statusMenuPicker()
            }
            HStack(spacing: 6) {
                if monitor.snapshot.isIdle {
                    Circle().fill(SparkVTheme.textTertiary).frame(width: 6, height: 6)
                    Text("Nothing in use right now").font(.system(size: 11.5)).foregroundStyle(SparkVTheme.textSecondary)
                } else {
                    PrivacyDots(sensors: monitor.snapshot.sensors, size: 7)
                    Text(monitor.snapshot.headline).font(.system(size: 11.5, weight: .medium)).foregroundStyle(SparkVTheme.text)
                }
            }
            StatusSettingsNote(text: "Listens to CoreAudio and CoreMediaIO; no timer, no permission. SparkV's own dictation, meeting notes and camera mirror never show here.")
        }
    }
}

// MARK: - Connection alerts (Activities)

struct ConnectivitySettingsSection: View {
    @ObservedObject private var monitor = ConnectivityMonitor.shared

    var body: some View {
        StatusSettingsBlock(
            symbol: "wifi", tint: .blue, title: "Connection Alerts",
            subtitle: "A short band when the internet drops or comes back, a VPN connects, you join a Personal Hotspot or eject a drive.",
            isOn: $monitor.isEnabled
        ) {
            StatusCheck(title: "No internet / back online", isOn: $monitor.alertsOffline, detail: "Waits a few seconds, and stays quiet just after waking.")
            StatusCheck(title: "VPN connected or disconnected", isOn: $monitor.alertsVPN)
            StatusCheck(title: "Personal Hotspot", isOn: $monitor.alertsHotspot, detail: "Recognized because hotspots mark Wi-Fi as metered.")
            StatusCheck(title: "Drive ejected · safe to remove", isOn: $monitor.alertsDrives)
            if let observation = monitor.observation {
                StatusSettingsReadout(
                    symbol: observation.isOnline ? observation.interface.symbol : "wifi.slash",
                    text: [observation.isOnline ? "Online" : "Offline", observation.isOnline ? observation.interface.title : nil,
                           observation.tunnels.isEmpty ? nil : "VPN", observation.isHotspot ? "Hotspot" : nil].compactMap { $0 }.joined(separator: " · "),
                    tint: observation.isOnline ? SparkVTheme.success : SparkVTheme.warning
                )
            }
            StatusSettingsNote(text: "Nothing is sent off your Mac: no pings and no captive-portal checks. Alerts stay quiet while your screen is shared.")
        }
    }
}

// MARK: - Caps Lock (Accessibility)

struct CapsLockSettingsSection: View {
    @ObservedObject private var monitor = CapsLockMonitor.shared

    var body: some View {
        StatusSettingsBlock(
            symbol: "capslock.fill", tint: .gray, title: "Caps Lock Indicator",
            subtitle: "A short “Caps Lock On” band under the notch when you press it.",
            isOn: $monitor.isEnabled
        ) {
            StatusCheck(title: "Keep ⇪ beside the notch while it's on", isOn: $monitor.showsWhileOn)
            if monitor.needsAccessibility {
                StatusSettingsRow(title: "Seeing it in every app needs Accessibility") {
                    Button("Allow…") { monitor.requestAccessibility() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            StatusSettingsNote(text: "macOS also shows Caps Lock at the text cursor. When Caps Lock switches input sources, macOS doesn't report it and nothing shows.")
        }
    }
}

// MARK: - Quick toggles (Island)

struct QuickTogglesSettingsSection: View {
    @ObservedObject private var toggles = QuickTogglesController.shared
    /// Re-renders when Bluetooth is granted elsewhere (e.g. the Battery
    /// section's button), so the row below never goes stale.
    @ObservedObject private var permissions = PermissionCenter.shared

    var body: some View {
        StatusSettingsBlock(symbol: "switch.2", tint: .indigo, title: "Quick Toggles",
                            subtitle: "The one-tap grid on the Status page. Pick up to eight.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(QuickToggleKind.defaultOrder) { kind in
                    StatusCheck(title: kind.longTitle, isOn: Binding(
                        get: { toggles.visibleKinds.contains(kind) },
                        set: { toggles.setVisible(kind, $0) }
                    ))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                StatusSettingsRow(title: "Night Shift shortcut") {
                    TextField("Shortcut name", text: $toggles.nightShiftShortcut)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                    Button("Open Shortcuts") { toggles.performMessageAction(.openShortcuts) }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
                StatusSettingsNote(text: "macOS has no Night Shift switch for apps. Make a shortcut with this name containing “Set Night Shift” → Toggle, and the tile runs it.")
            }
            if permissions.isGranted(.bluetooth) {
                StatusSettingsRow(title: "AirPods toggle connects") {
                    Picker("Headphones", selection: Binding(get: { toggles.favoriteDevice?.address ?? "" }, set: { toggles.favoriteAudioAddress = $0.isEmpty ? nil : $0 })) {
                        if toggles.audioDevices.isEmpty { Text("No headphones paired").tag("") }
                        ForEach(toggles.audioDevices) { device in Text(device.name).tag(device.address) }
                    }
                    .statusMenuPicker()
                }
            } else {
                StatusSettingsRow(title: "AirPods toggle needs Bluetooth access") {
                    Button("Allow Bluetooth…") { toggles.requestBluetoothAccess() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            StatusCheck(title: "Hide desktop icons now", isOn: Binding(get: { toggles.hidesDesktopIcons }, set: { toggles.setHidesDesktopIcons($0) }),
                        detail: "Covers the icons with your wallpaper and takes desktop clicks, so hidden files can’t be selected or moved. Finder isn’t restarted.")
        }
        .onAppear { toggles.refresh() }
        .onChange(of: permissions.isGranted(.bluetooth)) { _, granted in
            if granted { toggles.refreshAudioDevices() }
        }
    }
}
