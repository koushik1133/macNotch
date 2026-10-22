import AppKit
import SwiftUI

// Ambient Light UI: the settings window, the gear submenu items and the
// Agents hub tile. Only `@ObservedObject` / `@StateObject` (Command Line
// Tools build: no `@State`).

// MARK: - Settings view

struct AmbientLightSettingsView: View {
    @ObservedObject private var settings = AmbientLightSettings.shared
    @ObservedObject private var controller = AmbientLightController.shared
    @ObservedObject private var stats = AmbientLightController.shared.stats

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusRow
                section("Mode") { modeGrid }
                section("Brightness") {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").foregroundStyle(SparkVTheme.textSecondary)
                        Slider(value: $settings.intensity, in: 0.2...1)
                        Image(systemName: "sun.max.fill").foregroundStyle(SparkVTheme.textSecondary)
                    }
                }
                section("Where") {
                    Picker("", selection: $settings.scope) {
                        ForEach(AmbientLightScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if settings.scope == .notchAndEdges {
                        HStack(spacing: 10) {
                            Text("Edge Width").font(.system(size: 12)).foregroundStyle(SparkVTheme.textSecondary)
                            Slider(value: $settings.edgeWidth, in: 6...40)
                        }
                        Text("A thin strip of light along every screen edge, like a car's door lights. It hides itself over full-screen apps and while your screen is shared, and never shows up in screenshots or recordings.")
                            .font(.system(size: 11))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                section("Colors") {
                    Toggle("Match the Album Art", isOn: $settings.syncToAlbumColors)
                    HStack(spacing: 8) {
                        ForEach(AmbientBrandPalette.allCases) { brand in
                            paletteChip(brand)
                        }
                    }
                    Text(settings.syncToAlbumColors
                         ? "Colors come from the playing track's cover; the palette below is used when the cover has none."
                         : "The light uses the palette below.")
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textTertiary)
                    HStack(spacing: 6) {
                        Text("Now").font(.system(size: 11, weight: .medium)).foregroundStyle(SparkVTheme.textSecondary)
                        ForEach(Array(controller.palette.colors.enumerated()), id: \.offset) { _, c in
                            Circle().fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b)).frame(width: 14, height: 14)
                        }
                    }
                }
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 560)
        .background(LabsBWindowGround())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "light.beacon.max.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(SparkVTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ambient Light").font(.system(size: 20, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                Text("The notch glows and pulses with your music, like a car's mood lighting.")
                    .font(.system(size: 12))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { settings.isEnabled }, set: { controller.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(controller.status.text)
                .font(.system(size: 12))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if controller.status == .needsPermission {
                Button("Allow…") {
                    if AmbientAudioPermission.preflight() == .denied {
                        NSWorkspace.shared.open(AmbientAudioPermission.settingsURL)
                    } else {
                        controller.requestAccess()
                    }
                }
            }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            note("Reduce Motion is on, so the light stays steady instead of pulsing.")
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            note("Low Power Mode: the light updates at 30 frames per second.")
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .running: SparkVTheme.success
        case .needsPermission, .failed: SparkVTheme.warning
        default: SparkVTheme.textTertiary
        }
    }

    private var modeGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(AmbientLightMode.lit) { mode in
                AmbientModeCard(mode: mode, isSelected: settings.mode == mode) {
                    settings.mode = mode
                    if !settings.isEnabled { controller.setEnabled(true) }
                }
            }
        }
    }

    private func paletteChip(_ brand: AmbientBrandPalette) -> some View {
        let selected = settings.palette == brand
        return Button {
            settings.palette = brand
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(Array(brand.rgb.enumerated()), id: \.offset) { _, c in
                        RoundedRectangle(cornerRadius: 2).fill(Color(.sRGB, red: c.0, green: c.1, blue: c.2)).frame(width: 10, height: 16)
                    }
                }
                Text(brand.title).font(.system(size: 10, weight: .medium)).foregroundStyle(selected ? SparkVTheme.text : SparkVTheme.textSecondary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? SparkVTheme.accent.opacity(0.6) : SparkVTheme.stroke))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Preview") { controller.preview() }
                    .disabled(!settings.isEnabled)
                    .help("Plays the chosen mode for six seconds with a built-in beat")
                Spacer()
                Text(statsText).font(.system(size: 11).monospacedDigit()).foregroundStyle(SparkVTheme.textTertiary)
            }
            note("SparkV listens to what your Mac plays only while music is playing and Ambient Light is on. The sound is analyzed on this Mac and never recorded or stored. macOS asks once for System Audio Recording.")
        }
    }

    private var statsText: String {
        var parts: [String] = []
        if let bpm = stats.bpm { parts.append("\(Int(bpm)) BPM") }
        if stats.fps > 0 {
            parts.append(String(format: "%.0f fps", stats.fps))
            parts.append(String(format: "%.0f µs/frame", stats.frameMicros))
        }
        return parts.joined(separator: " · ")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(SparkVTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(SparkVTheme.textTertiary)
            content()
        }
    }
}

private struct AmbientModeCard: View {
    let mode: AmbientLightMode
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? SparkVTheme.accent : SparkVTheme.text.opacity(0.85))
                    Text(mode.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(SparkVTheme.accent)
                    }
                }
                Text(mode.blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(shape.fill(isSelected ? SparkVTheme.accentSoft : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(shape.strokeBorder(isSelected ? SparkVTheme.accent.opacity(0.55) : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}

// MARK: - Window

@MainActor
final class AmbientLightSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = AmbientLightSettingsWindowController()
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // SparkV is an agent app: become a regular app while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: AmbientLightSettingsView().followsAppearance())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ambient Light — SparkV"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 560)
        window.setContentSize(NSSize(width: 520, height: 720))
        window.center()
        window.setFrameAutosaveName("SparkV.AmbientLight")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Gear menu

/// Items for the gear menu's "Ambient Light" submenu:
/// `Menu("Ambient Light") { AmbientLightMenuItems() }`.
struct AmbientLightMenuItems: View {
    @ObservedObject private var settings = AmbientLightSettings.shared

    var body: some View {
        Toggle("Ambient Light", isOn: Binding(get: { settings.isEnabled },
                                              set: { AmbientLightController.shared.setEnabled($0) }))
        Section("Mode") {
            ForEach(AmbientLightMode.lit) { mode in
                Toggle(mode.title, isOn: Binding(
                    get: { settings.mode == mode },
                    set: { isOn in
                        guard isOn else { return }
                        settings.mode = mode
                        if !settings.isEnabled { AmbientLightController.shared.setEnabled(true) }
                    }
                ))
            }
        }
        Divider()
        Toggle("Light the Screen Edges", isOn: Binding(
            get: { settings.scope == .notchAndEdges },
            set: { settings.scope = $0 ? .notchAndEdges : .notchOnly }
        ))
        Toggle("Match the Album Art", isOn: $settings.syncToAlbumColors)
        Divider()
        Button("Ambient Light Settings…") { AmbientLightSettingsWindowController.shared.show() }
    }
}

// MARK: - Agents hub tile

/// Click: on / off. Right-click: modes and settings.
struct AmbientLightHubTile: View {
    @ObservedObject private var settings = AmbientLightSettings.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let on = settings.isEnabled
        let tint = Color(red: 0.62, green: 0.35, blue: 1.0)
        Button {
            AmbientLightController.shared.setEnabled(!on)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: on ? settings.mode.systemImage : "light.beacon.max")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LabsBHubTileBackground.glyph(isActive: on, isHovered: hover.isOn, tint: tint))
                Text(on ? settings.mode.title : "Ambient")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LabsBHubTileBackground.label(isActive: on, isHovered: hover.isOn))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
            .background(LabsBHubTileBackground(isActive: on, isHovered: hover.isOn, tint: tint))
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .contextMenu { AmbientLightMenuItems() }
        .help(on ? "Ambient Light (\(settings.mode.title)) is on. Click to turn off, right-click for modes."
                 : "Ambient Light: the notch glows with your music. Click to turn on.")
    }
}
