import AppKit
import SwiftUI

// Settings sections (no arguments), gear menu items, the Agents hub tile,
// and the small pieces the island draws (the notch gap that closes the
// drawer, the Keep Open bar, the "also at the notch" band). Panes: see
// INTEGRATION.md.

// MARK: - Motion

extension IslandMotionTuning {
    /// The island's spring for this tuning (Reduce Motion is applied by
    /// `NotchMetrics.hoverAnimation`).
    var animation: Animation {
        isInstant ? .linear(duration: 0) : .spring(response: response, dampingFraction: dampingFraction)
    }
}

// MARK: - Shared pieces

private struct IslandFooterText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(SparkVTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A status line with a colored symbol (honest limits, what was found).
private struct IslandStatusLine: View {
    enum Tone { case good, warning, neutral }
    let text: String
    var symbol: String = "info.circle"
    var tone: Tone = .neutral

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .good: SparkVTheme.success
        case .warning: SparkVTheme.warning
        case .neutral: SparkVTheme.textSecondary
        }
    }
}

/// The running controller, observed when there is one (settings can open
/// before the island exists, e.g. in a test harness).
@MainActor
private final class IslandInteractionBox: ObservableObject {
    @Published private(set) var controller: IslandInteractionController?
    private var token: Any?

    init() {
        controller = IslandInteractionController.current
        token = controller?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

// MARK: - Opening and closing (Island pane)

/// How the drawer opens and closes: trigger, delays, gestures, Esc, click
/// outside, focus and the ⌃⌥O shortcut.
struct IslandOpeningSettingsSection: View {
    @ObservedObject private var settings = IslandInteractionSettings.shared
    @StateObject private var box = IslandInteractionBox()

    var body: some View {
        Section {
            Picker(selection: $settings.openTrigger) {
                ForEach(IslandOpenTrigger.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Open the drawer by")
                Text(settings.openTrigger.detail)
            }
            Picker(selection: $settings.openDelay) {
                ForEach(IslandOpenDelay.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Open after")
                Text(settings.openTrigger.opensOnHover
                     ? "Automatic waits about 0.1 s, so passing by doesn’t open it (longer with a notch theme). Over a live activity beside the notch it waits a little more."
                     : "Hover isn’t used to open with \(settings.openTrigger.title).")
            }
            .disabled(!settings.openTrigger.opensOnHover)
            Picker(selection: $settings.closeDelay) {
                ForEach(IslandCloseDelay.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Close after the pointer leaves")
                Text("A drawer that just opened stays at least 0.35 s, so a brush past can’t snap it shut.")
            }
            Toggle(isOn: $settings.swipeGestures) {
                Text("Two-finger swipes")
                Text("On a trackpad: swipe down over the notch to open, up on the drawer’s top row to close.")
            }
            Toggle(isOn: $settings.clickOutsideCloses) {
                Text("Click outside closes the drawer")
                Text("Unless you pinned it open.")
            }
            Toggle(isOn: $settings.escapeCloses) {
                Text("Esc closes the drawer")
                Text("While the pointer is on the drawer, or while a field in it has the keyboard.")
            }
            Toggle(isOn: $settings.returnsFocus) {
                Text("Give the keyboard back when it closes")
                Text("If typing in the drawer brought SparkV to the front, the app you were in comes back.")
            }
            Toggle(isOn: $settings.toggleHotkeyEnabled) {
                Text("\(IslandInteractionController.toggleShortcutLabel) opens and closes the drawer")
                Text(hotkeyDetail)
            }
            if settings.toggleHotkeyEnabled, box.controller?.toggleHotkeyTaken == true {
                IslandStatusLine(text: "Another app already uses \(IslandInteractionController.toggleShortcutLabel).",
                                 symbol: "exclamationmark.triangle.fill", tone: .warning)
            }
        } header: {
            Text("Opening & Closing")
        } footer: {
            IslandFooterText(text: "To keep the drawer open while you work, choose Keep Drawer Open in the gear menu or the Keep Open tile in Agents. Esc, a click on the notch or choosing it again lets it close.")
        }
    }

    private var hotkeyDetail: String {
        var text = "Off until you turn it on. Opens on the Home tab or where you left it; press again to close."
        if NSWorkspace.shared.isVoiceOverEnabled {
            text += " With VoiceOver on, ⌃⌥ keys are VoiceOver’s too: pick other keys."
        }
        text += " Change the keys, or add one per tab, in Settings › Accessibility › Keyboard Shortcuts."
        return text
    }
}

// MARK: - Menu bar (Island pane)

/// Wings that keep clear of menu bar items, and stepping aside for menu
/// bar managers.
struct IslandMenuBarSettingsSection: View {
    @ObservedObject private var settings = IslandInteractionSettings.shared
    @StateObject private var box = IslandInteractionBox()

    var body: some View {
        Section {
            Toggle(isOn: $settings.avoidMenuBarItems) {
                Text("Keep live activities clear of menu bar items")
                Text("The wings beside the notch stop short of the nearest item and wait a moment before opening, so reaching for a menu bar item never opens the drawer.")
            }
            if settings.avoidMenuBarItems {
                IslandStatusLine(text: clearanceText, symbol: menusReadable ? "checkmark.circle.fill" : "info.circle",
                                 tone: menusReadable ? .good : .neutral)
            }
            Toggle(isOn: $settings.compactNowPlaying) {
                Text("Compact Now Playing beside the notch")
                Text("Only the level bars, no artwork or title, so music covers the least of the menu bar. Also used when the room is tight.")
            }
            Toggle(isOn: $settings.stepAsideForMenuBarManagers) {
                Text("Step aside for menu bar managers")
                Text("When Ice, Bartender, Hidden Bar or a similar app shows its bar over the island, the island fades out until the bar goes.")
            }
            if let names = box.controller?.runningManagerNames, !names.isEmpty {
                IslandStatusLine(text: "Running now: \(names.joined(separator: ", ")).", symbol: "menubar.rectangle")
            }
        } header: {
            Text("Menu Bar")
        } footer: {
            IslandFooterText(text: "Item positions are read from the window list when the island’s display, the front app or the wings change: never in a loop, and nothing leaves the Mac.")
        }
    }

    private var menusReadable: Bool { PermissionCenter.shared.isGranted(.accessibility) }

    private var clearanceText: String {
        menusReadable
            ? "Status items and the front app’s menus are both avoided."
            : "Status items are avoided. App menus are avoided too once SparkV has Accessibility access (it never asks for it here)."
    }
}

// MARK: - Motion (Appearance pane)

/// The open/close spring: style and speed, with a live preview.
struct IslandMotionSettingsSection: View {
    @ObservedObject private var settings = IslandInteractionSettings.shared

    var body: some View {
        Section {
            Picker(selection: $settings.motionStyle) {
                ForEach(IslandMotionStyle.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Island motion")
                Text(settings.motionStyle.detail)
            }
            Picker(selection: $settings.motionSpeed) {
                ForEach(IslandMotionSpeed.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Speed")
                Text(speedDetail)
            }
            .disabled(settings.motionStyle == .instant)
            IslandMotionPreview(tuning: settings.snapshot.motion)
        } header: {
            Text("Island Motion")
        } footer: {
            IslandFooterText(text: "Reduce Motion in System Settings › Accessibility › Display always wins: the island then fades instead of springing.")
        }
    }

    private var speedDetail: String {
        let tuning = settings.snapshot.motion
        guard !tuning.isInstant else { return "Instant has no speed." }
        return "Settles in about \(tuning.settleMilliseconds) ms."
    }
}

/// A small island on a menu bar strip that opens and closes with the
/// chosen spring. Press Preview to play it.
struct IslandMotionPreview: View {
    let tuning: IslandMotionTuning
    @StateObject private var open: ViewFlag

    /// `startsOpen`: shows the open state first (renders).
    init(tuning: IslandMotionTuning, startsOpen: Bool = false) {
        self.tuning = tuning
        let flag = ViewFlag()
        flag.isOn = startsOpen
        _open = StateObject(wrappedValue: flag)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 9)
                IslandSilhouette(shape: .notch, topRadius: open.isOn ? 6 : 3, bottomRadius: open.isOn ? 12 : 5)
                    .fill(Color.black)
                    .overlay(alignment: .top) {
                        if open.isOn {
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.22)).frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Capsule().fill(Color.white.opacity(0.32)).frame(width: 44, height: 4)
                                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 30, height: 4)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 16)
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                        }
                    }
                    .frame(width: open.isOn ? 150 : 64, height: open.isOn ? 50 : 10)
            }
            .frame(width: 200, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Button(open.isOn ? "Close Preview" : "Preview") {
                    let animation = tuning.isInstant ? nil : SparkVMotion.respecting(tuning.animation)
                    withAnimation(animation) { open.isOn.toggle() }
                }
                .accessibilityHint("Plays the island’s open or close motion")
                Text(tuning.isInstant ? "Appears at once." : "\(Int((tuning.response * 1000).rounded())) ms spring, \(tuning.dampingFraction >= 1 ? "no bounce" : "bounce \(String(format: "%.2f", 1 - tuning.dampingFraction))")")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Size (Appearance pane)

/// Drawer width, closed island width.
struct IslandSizeSettingsSection: View {
    @ObservedObject private var settings = IslandInteractionSettings.shared

    var body: some View {
        Section {
            Picker(selection: $settings.drawerSize) {
                ForEach(IslandDrawerSize.allCases) { size in
                    Text("\(size.title) (\(Int(size.width)) pt)").tag(size)
                }
            } label: {
                Text("Open drawer width")
                Text("Wider gives every tab more room. Heights stay as each tab needs.")
            }
            Picker(selection: $settings.closedWidth) {
                ForEach(IslandClosedWidth.allCases) { width in
                    Text(width.extra == 0 ? width.title : "\(width.title) (+\(Int(width.extra)) pt)").tag(width)
                }
            } label: {
                Text("Closed island width")
                Text("Extra shoulder beside the camera. On a display with a notch the height always matches the notch.")
            }
            IslandSizePreview(drawer: settings.drawerSize, closed: settings.closedWidth)
        } header: {
            Text("Island Size")
        } footer: {
            IslandFooterText(text: "The notch style, pill height and top margin are under Island Style.")
        }
    }
}

/// The screen's top edge with the closed island and the open drawer drawn
/// to scale (1:3.6).
struct IslandSizePreview: View {
    let drawer: IslandDrawerSize
    let closed: IslandClosedWidth
    private let scale: CGFloat = 1 / 3.6

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            sample(title: "Closed") {
                IslandSilhouette(shape: .notch, topRadius: 2.5, bottomRadius: 4)
                    .fill(Color.black)
                    .frame(width: (220 + closed.extra) * scale, height: 38 * scale)
            }
            sample(title: "Open") {
                ZStack(alignment: .top) {
                    IslandSilhouette(shape: .notch, topRadius: 4.5, bottomRadius: 9)
                        .fill(Color.black)
                        .frame(width: drawer.width * scale, height: 115 * scale)
                    // The standard drawer, drawn over it for comparison.
                    if drawer != .standard {
                        IslandSilhouette(shape: .notch, topRadius: 4.5, bottomRadius: 9)
                            .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 540 * scale, height: 115 * scale)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeInOut(SparkVMotion.Duration.standard)), value: drawer)
        .animation(SparkVMotion.respecting(SparkVMotion.easeInOut(SparkVMotion.Duration.standard)), value: closed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: closed island \(Int(220 + closed.extra)) points, open drawer \(Int(drawer.width)) points wide")
    }

    private func sample(title: String, @ViewBuilder island: () -> some View) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05))
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 38 * scale)
                island()
            }
            .frame(width: 200, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
        }
    }
}

// MARK: - Haptics (Accessibility pane)

struct IslandHapticsSettingsSection: View {
    @ObservedObject private var settings = IslandInteractionSettings.shared

    var body: some View {
        Section {
            Picker(selection: $settings.haptics) {
                ForEach(IslandHapticsLevel.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Trackpad haptics")
                Text(detail)
            }
            Button("Feel It") { SparkVHaptics.perform(.levelChange) }
                .disabled(settings.haptics == .off)
                .accessibilityHint("Plays one tap at this setting, with a finger on the trackpad")
        } header: {
            Text("Trackpad Haptics")
        } footer: {
            IslandFooterText(text: "Felt only with a finger on a Force Touch trackpad. Hovering never taps; swipes, clicks to open, drops on the shelf, the volume knob, pressing a call prompt, Clicky and Focus do.")
        }
    }

    private var detail: String {
        switch settings.haptics {
        case .off: "No taps anywhere in SparkV."
        case .gentle: "One light tap, never a run of them."
        case .standard: "As each feature designed it."
        }
    }
}

// MARK: - Other notch apps (Advanced pane)

/// Another notch, HUD or dictation app found running, and what SparkV can
/// turn off so the two don't fight over the same spot.
struct IslandCoexistenceSettingsSection: View {
    @ObservedObject private var settings = IslandInteractionSettings.shared
    @StateObject private var box = IslandInteractionBox()
    @StateObject private var checking = ViewFlag()

    var body: some View {
        Section {
            Toggle(isOn: $settings.warnAboutOtherNotchApps) {
                Text("Tell me when another notch app is running")
                Text("Checked when apps launch or quit, by app name and by windows parked over the notch. SparkV never changes or quits the other app.")
            }
            if let controller = box.controller {
                if controller.findings.isEmpty {
                    IslandStatusLine(text: "No other notch, HUD or menu bar app found.", symbol: "checkmark.circle.fill", tone: .good)
                } else {
                    ForEach(controller.findings) { finding in
                        IslandFindingRow(finding: finding, controller: controller,
                                         dismissed: settings.dismissedConflicts.contains(finding.id))
                    }
                }
                HStack {
                    Button(checking.isOn ? "Checking…" : "Check Again") {
                        checking.isOn = true
                        Task {
                            await controller.checkCoexistence()
                            checking.isOn = false
                        }
                    }
                    .disabled(checking.isOn)
                    if !settings.dismissedConflicts.isEmpty {
                        Button("Show Dismissed Notices Again") { settings.resetDismissedConflicts() }
                    }
                }
            } else {
                IslandStatusLine(text: "Shown once the island is running.")
            }
        } header: {
            Text("Other Notch Apps")
        } footer: {
            IslandFooterText(text: "Two apps at the notch draw over each other. The honest fix is to let one of them step aside: turn off the overlapping part here, or in the other app.")
        }
    }
}

private struct IslandFindingRow: View {
    let finding: IslandCoexistenceFinding
    @ObservedObject var controller: IslandInteractionController
    let dismissed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(finding.kind == .menuBarManager ? SparkVTheme.textSecondary : SparkVTheme.warning)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SparkVTheme.text)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !dismissed, finding.kind != .menuBarManager {
                    Button("Dismiss") { controller.dismiss(finding) }
                        .accessibilityLabel("Dismiss the notice about \(finding.name)")
                }
            }
            switch finding.kind {
            case .notchApp:
                let _ = controller.featureRevision
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("SparkV hides the macOS volume and brightness pop-up", isOn: Binding(
                        get: { controller.actions.systemHUDReplaced() }, set: { controller.setSystemHUDReplaced($0) }))
                    Toggle("Now Playing beside the notch", isOn: Binding(
                        get: { controller.actions.nowPlayingWings() }, set: { controller.setNowPlayingWings($0) }))
                    Toggle("Notification banners on the island", isOn: Binding(
                        get: { controller.actions.notificationBanners() }, set: { controller.setNotificationBanners($0) }))
                    Button("Hide SparkV’s Island for Now") { controller.actions.hideIsland() }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(.leading, 26)
            case .fnDictation:
                Button("Use Right Option for SparkV Dictation") { controller.useRightOptionForDictation() }
                    .padding(.leading, 26)
            case .menuBarManager:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch finding.kind {
        case .notchApp: "rectangle.on.rectangle"
        case .menuBarManager: "menubar.rectangle"
        case .fnDictation: "mic.fill"
        }
    }

    private var detail: String {
        switch finding.kind {
        case .notchApp: "Both apps draw in the same place. Turn off what overlaps, here or in \(finding.name)."
        case .menuBarManager: "Hover still opens the island; when its bar covers the island, the island steps aside."
        case .fnDictation: "Holding fn would start both. SparkV can listen to Right Option instead."
        }
    }
}

/// The band posted once per app found at the notch.
struct IslandCoexistenceBand: View {
    let finding: IslandCoexistenceFinding
    @StateObject private var hover = ViewFlag()

    static func activity(for finding: IslandCoexistenceFinding) -> LiveActivity {
        var activity = LiveActivity(
            id: "island.coexistence.\(finding.id)", kind: .notification, priority: 40, duration: 8,
            symbol: finding.kind == .fnDictation ? "mic.fill" : "rectangle.on.rectangle",
            tint: SparkVTheme.warning
        ) {
            IslandCoexistenceBand(finding: finding)
        }
        activity.isInteractive = true
        activity.title = finding.name
        activity.accessibilityText = "\(finding.message). Settings, Advanced, Other Notch Apps."
        return activity
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: finding.kind == .fnDictation ? "mic.fill" : "rectangle.on.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.warning)
                .accessibilityHidden(true)
            Text(finding.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button {
                SparkVSettings.show(.advanced)
            } label: {
                Text("Review")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.isApple ? Color.white : SparkVTheme.text)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(Capsule().fill(SparkVTheme.isApple ? Color.white.opacity(hover.isOn ? 0.26 : 0.18)
                                                                    : SparkVTheme.red.opacity(hover.isOn ? 0.72 : 0.58)))
                    .contentShape(Capsule())
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { hover.isOn = $0 }
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .accessibilityLabel("Review in Settings")
            Button {
                IslandInteractionController.current?.dismiss(finding)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(SparkVPressStyle())
            .accessibilityLabel("Don’t show this again")
        }
        .padding(.horizontal, 12)
        .frame(height: NotchMetrics.activityBandHeight)
    }
}

// MARK: - Gear menu

/// Gear menu › Island Behavior.
struct IslandInteractionMenuItems: View {
    @ObservedObject private var settings = IslandInteractionSettings.shared

    var body: some View {
        Toggle("Keep Drawer Open", isOn: Binding(
            get: { IslandInteractionActions.isPinned }, set: { IslandInteractionActions.setPinned($0) }))
        Divider()
        Picker("Open By", selection: $settings.openTrigger) {
            ForEach(IslandOpenTrigger.allCases) { Text($0.title).tag($0) }
        }
        Picker("Open After", selection: $settings.openDelay) {
            ForEach(IslandOpenDelay.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!settings.openTrigger.opensOnHover)
        Picker("Close After", selection: $settings.closeDelay) {
            ForEach(IslandCloseDelay.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Two-Finger Swipes", isOn: $settings.swipeGestures)
        Toggle("Click Outside Closes", isOn: $settings.clickOutsideCloses)
        Toggle("Esc Closes", isOn: $settings.escapeCloses)
        Toggle("\(IslandInteractionController.toggleShortcutLabel) Opens and Closes", isOn: $settings.toggleHotkeyEnabled)
        Divider()
        Picker("Motion", selection: $settings.motionStyle) {
            ForEach(IslandMotionStyle.allCases) { Text($0.title).tag($0) }
        }
        Picker("Speed", selection: $settings.motionSpeed) {
            ForEach(IslandMotionSpeed.allCases) { Text($0.title).tag($0) }
        }
        .disabled(settings.motionStyle == .instant)
        Picker("Drawer Width", selection: $settings.drawerSize) {
            ForEach(IslandDrawerSize.allCases) { Text($0.title).tag($0) }
        }
        Picker("Closed Width", selection: $settings.closedWidth) {
            ForEach(IslandClosedWidth.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Toggle("Keep Clear of Menu Bar Items", isOn: $settings.avoidMenuBarItems)
        Toggle("Compact Now Playing", isOn: $settings.compactNowPlaying)
        Picker("Trackpad Haptics", selection: $settings.haptics) {
            ForEach(IslandHapticsLevel.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("Island Behavior Settings…") { SparkVSettings.show(.island) }
    }
}

// MARK: - Agents hub tile (System)

/// Keep Open: one click pins the drawer open (or lets it close again).
/// Pinned to the header, it is a pin button there.
struct IslandInteractionHubTile: View {
    @EnvironmentObject private var state: NotchState
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            IslandInteractionActions.setPinned(!state.isPinned)
        } label: {
            face
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(state.isPinned ? "The drawer stays open. Click to let it close again." : "Keep the drawer open while you work")
        .accessibilityLabel("Keep drawer open")
        .accessibilityValue(state.isPinned ? "On" : "Off")
    }

    private var face: some View {
        let tint = Color(red: 0.98, green: 0.72, blue: 0.27)
        let active = state.isPinned
        return VStack(spacing: 5) {
            Image(systemName: active ? "pin.fill" : "pin")
                .font(.system(size: 16, weight: .semibold))
                .rotationEffect(.degrees(active ? 0 : 45))
                .foregroundStyle(LabsBHubTileBackground.glyph(isActive: active, isHovered: hover.isOn, tint: tint))
                .frame(height: 19)
                .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: active)
            Text(active ? "Pinned" : "Keep Open")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LabsBHubTileBackground.label(isActive: active, isHovered: hover.isOn))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(LabsBHubTileBackground(isActive: active, isHovered: hover.isOn, tint: tint))
        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
    }
}

// MARK: - On the island

extension IslandWingRoom {
    /// Text room in the right wing before the nearest menu bar item (the
    /// same arithmetic as `CompactTrailingView.textWidth`).
    func trailingTextRoom(besideMinimal: Bool) -> CGFloat {
        let room = clearance.trailing - NotchMetrics.wingInnerPadding - NotchMetrics.wingOuterPadding - 10 - (besideMinimal ? 25 : 0)
        // A few letters aren't a label: below that, the symbol alone.
        return room >= 28 ? room : 0
    }
}

extension View {
    /// A wing held short of a menu bar item: content that doesn't fit
    /// fades out at the wing's outer edge instead of being cut.
    func islandWingFit(content: CGFloat, wing: CGFloat, edge: HorizontalEdge) -> some View {
        let needed = content + NotchMetrics.wingInnerPadding + NotchMetrics.wingOuterPadding
        return modifier(IslandWingFit(overflows: content > 0 && needed > wing + 0.5, edge: edge))
    }
}

private struct IslandWingFit: ViewModifier {
    let overflows: Bool
    let edge: HorizontalEdge

    func body(content: Content) -> some View {
        if overflows {
            content.mask {
                HStack(spacing: 0) {
                    if edge == .leading {
                        Color.clear.frame(width: NotchMetrics.wingOuterPadding - 4)
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        Rectangle()
                    } else {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        Color.clear.frame(width: NotchMetrics.wingOuterPadding - 4)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// The open drawer's camera gap: a click there (on the notch) closes the
/// drawer. On a display without a notch a faint chevron shows on hover.
struct IslandNotchGapTarget: View {
    @EnvironmentObject private var state: NotchState
    @StateObject private var hover = ViewFlag()
    /// The header's width (the gap is never wider than the space between
    /// the two icon groups).
    let headerWidth: CGFloat

    /// Each icon group needs up to 156 pt (six 24 pt controls and gaps).
    static let groupWidth: CGFloat = 156
    /// Without a camera housing (a pill on a display without a notch) the
    /// gap is this wide, so the chevron and click-to-close exist there too.
    static let minimumWidth: CGFloat = 60

    var body: some View {
        let housing = state.surface.housingWidth > 0 ? state.surface.housingWidth - 16 : Self.minimumWidth
        let width = max(0, min(housing, headerWidth - 2 * Self.groupWidth))
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay {
                if !state.surface.hasNotch, hover.isOn {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Rectangle())
            .onTapGesture { IslandInteractionActions.close() }
            .onHover { hover.isOn = $0 }
            .help(state.isPinned ? "Click to let the drawer close" : "Click the notch to close")
            .accessibilityElement()
            .accessibilityLabel("Close the drawer")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { IslandInteractionActions.close() }
            .allowsHitTesting(width > 20)
    }
}

/// While the drawer is pinned open: a short accent bar at its bottom
/// edge. Click it to let the drawer close again.
struct IslandPinnedIndicator: View {
    @EnvironmentObject private var state: NotchState
    @StateObject private var hover = ViewFlag()

    var body: some View {
        if state.isPinned {
            Capsule()
                .fill(SparkVTheme.choose(apple: Color(red: 0.98, green: 0.72, blue: 0.27), sparkv: SparkVTheme.red))
                .opacity(hover.isOn ? 1 : 0.8)
                .frame(width: hover.isOn ? 40 : 32, height: 3)
                .frame(width: 56, height: 8)
                .contentShape(Rectangle())
                .onTapGesture { IslandInteractionActions.setPinned(false) }
                .onHover { hover.isOn = $0 }
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .help("Kept open. Click to let the drawer close.")
                .accessibilityElement()
                .accessibilityLabel("Drawer kept open")
                .accessibilityHint("Lets the drawer close again")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { IslandInteractionActions.setPinned(false) }
                .transition(.opacity.animation(SparkVMotion.easeOut(SparkVMotion.Duration.small)))
        }
    }
}

// MARK: - Window (until the Settings window hosts these sections)

/// Every Island Interaction section in one grouped Form (for a harness or
/// a standalone window).
struct IslandInteractionSettingsRoot: View {
    var body: some View {
        Form {
            IslandOpeningSettingsSection()
            IslandMenuBarSettingsSection()
            IslandMotionSettingsSection()
            IslandSizeSettingsSection()
            IslandHapticsSettingsSection()
            IslandCoexistenceSettingsSection()
        }
        .formStyle(.grouped)
    }
}
