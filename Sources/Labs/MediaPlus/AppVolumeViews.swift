import AppKit
import SwiftUI

// MARK: - Mixer

/// One row per app making sound: icon, name, a 0–200 % slider with a detent
/// at 100 %, the level, and a reset. Apps with a saved level stay listed
/// (dimmed) while they're quiet.
struct AppVolumeMixerView: View {
    @ObservedObject private var controller = AppVolumeController.shared
    /// Rows for offscreen renders.
    var previewRows: [AppVolumeController.AppRow]? = nil

    var body: some View {
        let rows = previewRows ?? controller.rows
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .foregroundStyle(SparkVTheme.textTertiary)
                    Text("Apps appear here while they play sound.")
                        .font(.system(size: 12))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(rows) { row in
                    AppVolumeRowView(row: row, isPreview: previewRows != nil)
                }
            }
        }
        // Window-aware (App Volumes and Settings windows are kept when
        // closed): listeners stop once the mixer is off screen.
        .mpReportsOnScreen { [isPreview = previewRows != nil] visible in
            if !isPreview { AppVolumeController.shared.setMixerVisible(visible) }
        }
    }
}

private struct AppVolumeRowView: View {
    let row: AppVolumeController.AppRow
    let isPreview: Bool
    @StateObject private var hover = ViewFlag()

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
                .opacity(row.isPlaying ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(row.isPlaying ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(row.problem == nil ? SparkVTheme.textTertiary : SparkVTheme.warning)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(detail)
            }
            .frame(width: 118, alignment: .leading)
            Slider(value: Binding(
                get: { row.gain },
                set: { if !isPreview { AppVolumeController.shared.setGain($0, for: row.id) } }
            ), in: AppGainMath.range)
            .controlSize(.small)
            .tint(row.gain > 1 ? SparkVTheme.warning : SparkVTheme.accent)
            .accessibilityLabel("\(row.name) volume")
            .accessibilityValue(AppGainMath.percentText(row.gain))
            Text(AppGainMath.percentText(row.gain))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppGainMath.isUnity(row.gain) ? SparkVTheme.textSecondary : SparkVTheme.text)
                .frame(width: 38, alignment: .trailing)
            Button {
                if row.problem != nil {
                    AppVolumeController.shared.retry(row.id)
                } else {
                    AppVolumeController.shared.setGain(1, for: row.id)
                }
            } label: {
                Image(systemName: row.problem != nil ? "arrow.clockwise" : "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hover.isOn ? LabsBStyle.hoverGlyph : SparkVTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(hover.isOn ? LabsBStyle.hoverFill : Color.clear))
                    .contentShape(Circle())
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { hover.isOn = $0 }
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .opacity(AppGainMath.isUnity(row.gain) && row.problem == nil ? 0 : 1)
            .disabled(AppGainMath.isUnity(row.gain) && row.problem == nil)
            .help(row.problem != nil ? "Try again" : "Back to 100%")
            .accessibilityLabel(row.problem != nil ? "Try again" : "Reset \(row.name) to 100 percent")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                .fill(row.isRouted ? LabsBStyle.activeCardFill(SparkVTheme.accent) : SparkVTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                .strokeBorder(row.isRouted ? LabsBStyle.activeCardStroke(SparkVTheme.accent) : Color.clear, lineWidth: 1)
        )
    }

    private var detail: String {
        if let problem = row.problem { return problem }
        if !row.isPlaying { return "Not playing" }
        if row.isRouted { return row.gain > 1 ? "Boosted" : "Adjusted" }
        return "Playing"
    }

    @ViewBuilder
    private var icon: some View {
        if let image = MPAppIcon.icon(bundleID: row.id.contains("|") ? nil : row.id, path: row.appPath) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 16))
                .foregroundStyle(SparkVTheme.textSecondary)
        }
    }
}

// MARK: - Window, settings, tile

/// "App Volumes" settings: the switch, status, the mixer and the fine print.
struct AppVolumeSettingsSection: View {
    @ObservedObject private var controller = AppVolumeController.shared

    var body: some View {
        MPSettingsSection(
            title: "App Volumes",
            summary: "Turn one app down (a loud call) or up to 200 % (a quiet video) without touching the others.",
            systemImage: "slider.horizontal.3",
            accessory: { MPHeaderSwitch(label: "App Volumes", isOn: $controller.isEnabled) }
        ) {
            if controller.isEnabled {
                statusLine
                AppVolumeMixerView()
                HStack {
                    MPNote(text: "Adjusted apps play through SparkV, which adds about 10–20 ms of delay; keep calls at 100 % if lip sync matters. Levels are remembered per app.")
                    Spacer(minLength: 8)
                    if controller.hasLevels {
                        Button("Reset All") { controller.resetAll() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                }
            } else {
                MPNote(text: "Off. Uses macOS audio taps (System Audio Recording permission). Sound is processed on this Mac and never recorded or sent anywhere.")
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch controller.status {
        case .needsPermission:
            HStack {
                MPStatusLine(text: "Allow System Audio Recording for SparkV to change app volumes.", color: SparkVTheme.warning)
                Spacer()
                Button("Open Settings…") { controller.openPermissionSettings() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
            }
        case .failed(let message):
            MPStatusLine(text: message, color: SparkVTheme.warning)
        case .ready, .off:
            EmptyView()
        }
    }
}

/// The App Volumes window (hub tile, gear menu).
@MainActor
enum AppVolumeWindow {
    static let shared = MPWindowController(
        title: "App Volumes — SparkV", autosave: "SparkV.AppVolumes",
        size: NSSize(width: 480, height: 380), minSize: NSSize(width: 440, height: 260)
    ) {
        AnyView(
            ScrollView {
                AppVolumeSettingsSection()
                    .padding(.horizontal, 18)
                    .padding(.top, 34)
                    .padding(.bottom, 18)
            }
            .background(LabsBWindowGround())
            .followsAppearance()
        )
    }
}

/// Agents hub tile (Media): opens App Volumes; lit while a level is applied.
struct AppVolumeHubTile: View {
    @ObservedObject private var controller = AppVolumeController.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let active = controller.isEnabled && controller.rows.contains(where: \.isRouted)
        Button {
            AppVolumeWindow.shared.show()
        } label: {
            MPHubTileFace(title: "App Volumes", systemImage: "slider.horizontal.3", tint: .teal,
                          isActive: active, isHovered: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu {
            Toggle("App Volumes", isOn: $controller.isEnabled)
            if controller.hasLevels {
                Button("Reset All to 100%") { controller.resetAll() }
            }
        }
        .help("Per-app volume: turn one app up or down")
    }
}
