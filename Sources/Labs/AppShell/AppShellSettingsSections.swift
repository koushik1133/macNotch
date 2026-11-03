import AppKit
import GlanceKit
import ServiceManagement
import SwiftUI

// The app shell's own Settings sections. Each takes no arguments and reads
// `.shared` singletons, like every package's <X>SettingsSection.

// MARK: - General › About (hero)

/// The top of General: SparkV's mark, version, update state, About and Quit.
struct AppShellAboutSettingsSection: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                SparkVAppMark(size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SparkV")
                        .font(SparkVTheme.title(18))
                        .foregroundStyle(SparkVTheme.text)
                    Text("Version \(SparkVAppInfo.versionText)")
                        .font(.system(size: 12))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .textSelection(.enabled)
                    updateLine
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Button(updates.availableRelease == nil ? "Check for Updates…" : "View Update…") {
                        updates.checkNow(userInitiated: true)
                    }
                    .disabled(updates.isChecking)
                    HStack(spacing: 6) {
                        Button("About") { SparkVAppInfo.showAbout() }
                        Button("Quit SparkV") { SparkVAppInfo.quit() }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var updateLine: some View {
        if let release = updates.availableRelease {
            AppShellStatusLabel(text: "SparkV \(release.displayVersion) is available", symbol: "arrow.down.circle.fill", tone: .accent)
        } else if updates.isChecking {
            AppShellStatusLabel(text: "Checking for updates…", symbol: "arrow.triangle.2.circlepath", tone: .neutral)
        } else if case .upToDate = updates.phase {
            AppShellStatusLabel(text: "Up to date", symbol: "checkmark.circle.fill", tone: .good)
        }
    }
}

// MARK: - General › Startup

/// Launch at login through SMAppService, with the "needs approval" state.
@MainActor
final class AppShellLoginItem: ObservableObject {
    static let shared = AppShellLoginItem()
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?
    private var observer: NSObjectProtocol?

    private init() {
        // The user may approve or remove it in System Settings meanwhile.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppShellLoginItem.shared.reload() }
        }
    }

    func reload() { status = SMAppService.mainApp.status }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppLog.log("Login item: change failed: \(error.localizedDescription)")
        }
        reload()
        if enabled, status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

struct AppShellStartupSettingsSection: View {
    @ObservedObject private var login = AppShellLoginItem.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) })) {
                Text("Open SparkV at login")
                if login.status == .requiresApproval {
                    Text("Waiting for your approval in System Settings › General › Login Items.")
                }
            }
            if login.status == .requiresApproval {
                LabeledContent("Approval") {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let error = login.lastError {
                AppShellStatusLabel(text: "Couldn’t change it: \(error)", symbol: "exclamationmark.triangle.fill", tone: .warning)
            }
        } header: {
            Text("Startup")
        }
        .onAppear { login.reload() }
    }
}

// MARK: - General › Menu bar and reopening

struct AppShellMenuBarSettingsSection: View {
    @ObservedObject private var statusItem = StatusItemController.shared
    @ObservedObject private var shell = AppShellController.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { statusItem.isVisible }, set: { statusItem.setVisible($0) })) {
                Text("Show SparkV in the menu bar")
                Text("A small ✦ icon with Settings, updates and Quit. ⌘-drag it out of the menu bar to hide it again.")
            }
            Picker(selection: $shell.reopenAction) {
                ForEach(AppShellController.ReopenAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            } label: {
                Text("When SparkV is opened again")
                Text("From Finder, Spotlight or Launchpad, while it is running.")
            }
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Settings are always one step away: the gear in the drawer, ⌘, while SparkV is in front, or opening SparkV again, even with the icon hidden.")
                .settingsFooterStyle()
        }
    }
}

// MARK: - General › Updates

struct AppShellUpdatesSettingsSection: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        Section {
            Toggle(isOn: $updates.automaticChecks) {
                Text("Check for updates automatically")
                Text("About once a day. Off until you turn it on.")
            }
            Toggle(isOn: $updates.includeBetas) {
                Text("Include beta versions")
                Text("Pre-releases can be less stable.")
            }
            LabeledContent {
                Button(updates.isChecking ? "Checking…" : "Check Now") { updates.checkNow(userInitiated: true) }
                    .disabled(updates.isChecking)
            } label: {
                Text("Last checked")
                Text(lastCheckedText)
            }
            if let release = updates.availableRelease {
                LabeledContent {
                    Button("View Release Notes…") { updates.checkNow(userInitiated: true) }
                } label: {
                    AppShellStatusLabel(text: "SparkV \(release.displayVersion) is available", symbol: "arrow.down.circle.fill", tone: .accent)
                }
            } else if case .failed(let message) = updates.phase {
                AppShellStatusLabel(text: message, symbol: "exclamationmark.triangle.fill", tone: .warning)
            }
            if SparkVAppInfo.isHomebrewInstall {
                AppShellCopyRow(text: SparkVAppInfo.brewUpgradeCommand, caption: "Installed with Homebrew: update from Terminal")
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Checking contacts GitHub (api.github.com) to read SparkV’s public release list. Nothing about you or this Mac is sent, and SparkV never downloads or installs anything by itself: you get the release notes and a link to the download page.")
                .settingsFooterStyle()
        }
    }

    private var lastCheckedText: String {
        guard let date = updates.lastCheck else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: - Appearance › Look

/// Apple (default) or SparkV Red, with a small preview of each.
struct AppShellLookSettingsSection: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ForEach(AppearanceStyle.allCases) { style in
                    AppShellLookCard(style: style, isSelected: appearance.style == style) {
                        appearance.style = style
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Look")
        } footer: {
            Text("Applies to the island, the drawer and every SparkV window right away.")
                .settingsFooterStyle()
        }
    }
}

private struct AppShellLookCard: View {
    let style: AppearanceStyle
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 74)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(isSelected ? SparkVTheme.accent : Color.white.opacity(hover.isOn ? 0.22 : 0.10), lineWidth: isSelected ? 2 : 1))
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? SparkVTheme.accent : SparkVTheme.textTertiary)
                    Text(style.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(SparkVTheme.text)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// A miniature island with tabs and an active pill, in that look's colors.
    private var preview: some View {
        let apple = style == .apple
        let ground = apple ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : Color(red: 9 / 255, green: 9 / 255, blue: 10 / 255)
        let accent = apple ? Color.accentColor : SparkVTheme.brandRed
        return ZStack(alignment: .top) {
            ground
            if !apple {
                RadialGradient(colors: [SparkVTheme.brandRed.opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: 120)
            }
            VStack(spacing: 7) {
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 150, height: 40)
                    .overlay(
                        HStack(spacing: 6) {
                            ForEach(0..<4, id: \.self) { index in
                                Capsule()
                                    .fill(index == 0 ? (apple ? Color.white.opacity(0.16) : accent.opacity(0.18)) : Color.clear)
                                    .frame(width: 20, height: 14)
                                    .overlay(Circle().fill(index == 0 ? (apple ? Color.white : accent) : Color.white.opacity(0.45)).frame(width: 5, height: 5))
                            }
                        }
                        .padding(.top, 14)
                    )
                Capsule()
                    .fill(accent)
                    .frame(width: 54, height: 12)
            }
        }
    }
}

// MARK: - Accessibility › What SparkV follows

@MainActor
final class AppShellAccessibilityModel: ObservableObject {
    static let shared = AppShellAccessibilityModel()
    @Published private(set) var reduceMotion = false
    @Published private(set) var increaseContrast = false
    @Published private(set) var reduceTransparency = false
    @Published private(set) var differentiateWithoutColor = false
    private var observer: NSObjectProtocol?

    private init() {
        read()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppShellAccessibilityModel.shared.read() }
        }
    }

    func read() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    static let displaySettingsURL = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display")!
}

struct AppShellAccessibilityStatusSection: View {
    @ObservedObject private var model = AppShellAccessibilityModel.shared

    var body: some View {
        Section {
            row("Reduce motion", on: model.reduceMotion, effect: "Springs, slides and scaling become short fades.")
            row("Increase contrast", on: model.increaseContrast, effect: "Read from System Settings for the island’s text and borders.")
            row("Reduce transparency", on: model.reduceTransparency, effect: "Read from System Settings for SparkV’s window backgrounds.")
            row("Differentiate without color", on: model.differentiateWithoutColor, effect: "Status always shows an icon or text, never color alone.")
            LabeledContent("System Settings") {
                Button("Open Display Accessibility…") { NSWorkspace.shared.open(AppShellAccessibilityModel.displaySettingsURL) }
            }
        } header: {
            Text("Follows macOS")
        } footer: {
            Text("SparkV reads these switches from System Settings › Accessibility › Display and updates as soon as you change them.")
                .settingsFooterStyle()
        }
    }

    private func row(_ title: String, on: Bool, effect: String) -> some View {
        LabeledContent {
            AppShellStatusLabel(text: on ? "On" : "Off", symbol: on ? "checkmark.circle.fill" : "circle", tone: on ? .good : .neutral)
        } label: {
            Text(title)
            Text(effect)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - System › Permissions

struct AppShellPermissionsSettingsSection: View {
    var body: some View {
        Section {
            LabeledContent {
                Button("Permissions & Setup…") { OnboardingController.shared.show(step: .permissions) }
            } label: {
                Text("Privacy permissions")
                Text("See what SparkV may use and allow only what your features need.")
            }
            LabeledContent {
                Button("Terms & Privacy…") { OnboardingController.shared.show(step: .terms) }
            } label: {
                Text("Terms and privacy")
                Text("Everything runs on this Mac unless you turn on an online feature.")
            }
        } header: {
            Text("Permissions")
        }
    }
}

// MARK: - Advanced › Automation

struct AppShellAutomationSettingsSection: View {
    @ObservedObject private var router = AutomationRouter.shared
    @StateObject private var showsLog = ViewFlag()

    var body: some View {
        Section {
            Toggle(isOn: $router.isEnabled) {
                Text("Allow sparkv:// links to change things")
                Text("Lets Shortcuts, scripts and other apps open the drawer, start timers and show their own live activities.")
            }
            AppShellCopyRow(text: "sparkv://timer/start?minutes=25", caption: "Paste into Shortcuts › Open URLs, or run with open -g in Terminal")
            LabeledContent {
                Button("Automation Guide…") { AutomationGuideWindowController.shared.show() }
            } label: {
                Text("Every command")
                Text("Switches: " + router.features.keys.sorted().joined(separator: ", "))
            }
            if !router.recent.isEmpty {
                DisclosureGroup(isExpanded: $showsLog.isOn) {
                    ForEach(router.recent) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(entry.ok ? SparkVTheme.success : SparkVTheme.warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.summary).font(.system(size: 12))
                                Text(entry.outcome).font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary)
                            }
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(SparkVTheme.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } label: {
                    Text("Recent links (\(router.recent.count))")
                }
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("Off by default. Links that only open a window (Settings, About, a meeting’s notes) always work. No link can start the camera, the microphone, a recording, dictation, a shortcut or a script.")
                .settingsFooterStyle()
        }
    }
}

// MARK: - Advanced › Crash & hang reports

struct AppShellDiagnosticsSettingsSection: View {
    @ObservedObject private var diagnostics = DiagnosticsController.shared

    var body: some View {
        Section {
            Toggle(isOn: $diagnostics.collectsMetricKit) {
                Text("Keep crash and hang reports from macOS")
                Text("macOS hands them to SparkV through MetricKit on the next launch; they’re saved in Application Support › SparkV › Diagnostics.")
            }
            LabeledContent {
                HStack(spacing: 6) {
                    Button("Show Reports…") { DiagnosticsWindowController.shared.show() }
                    Button(diagnostics.isExporting ? "Exporting…" : "Export…") { diagnostics.exportWithPanel() }
                        .disabled(diagnostics.isExporting)
                }
            } label: {
                Text("Reports")
                Text(diagnostics.newThisSession > 0 ? "\(diagnostics.newThisSession) new since SparkV started" : "Crashes, hangs, high CPU and disk writes")
            }
            if let note = diagnostics.exportNote {
                AppShellStatusLabel(text: note, symbol: note.hasPrefix("Export failed") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                    tone: note.hasPrefix("Export failed") ? .warning : .good)
            }
        } header: {
            Text("Crash & Hang Reports")
        } footer: {
            Text("Nothing is sent automatically. Export makes a zip you can attach to a GitHub issue or an e-mail yourself. Your name, this Mac’s name, e-mail addresses, web paths and quoted text are removed from the log; file names it mentions without quotes can remain, so look it over first. Crash reports keep the details needed to read them.")
                .settingsFooterStyle()
        }
    }
}

// MARK: - Advanced › Reset and uninstall

struct AppShellResetSettingsSection: View {
    @StateObject private var showsGuide = ViewFlag()

    var body: some View {
        Section {
            LabeledContent {
                Button("Reset SparkV…") { ResetController.shared.confirm(.reset) }
            } label: {
                Text("Start over")
                Text("Moves SparkV’s files (meeting notes, Spaces, Flow notes) to the Trash and deletes its settings, keychain items, login item and permissions for good, then opens SparkV fresh. You can export Spaces first.")
            }
            LabeledContent {
                Button("Uninstall SparkV…") { ResetController.shared.confirm(.uninstall) }
                    .foregroundStyle(SparkVTheme.destructive)
            } label: {
                Text("Remove SparkV")
                Text("Does the same, then moves SparkV.app to the Trash.")
            }
            DisclosureGroup(isExpanded: $showsGuide.isOn) {
                UninstallGuideView()
            } label: {
                Text("Uninstall by hand")
            }
        } header: {
            Text("Reset & Uninstall")
        }
    }
}

/// What to remove by hand (or with Homebrew), in order: the helper first,
/// while SparkV (and its Fans pane) still runs, the app itself last.
struct UninstallGuideView: View {
    /// Where this copy of SparkV runs from (not always /Applications).
    var appPath: String = Bundle.main.bundlePath

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Remove the Fan Control helper, if you installed it", "While SparkV still runs: Fans › Uninstall Helper. Or in Terminal:")
            AppShellCopyRow(text: "sudo \"\(appPath)/Contents/Resources/FanHelper/uninstall-fanhelper.sh\"")
                .padding(.leading, 26)
            step(2, "Quit SparkV", "Gear menu › Quit SparkV. A screen recording or mode finishes first.")
            step(3, "Remove the login item", "System Settings › General › Login Items: select SparkV and click −.")
            step(4, "Move SparkV’s files to the Trash", "In Finder › Go › Go to Folder…. Application Support › SparkV holds your meeting notes, transcripts, Spaces and Flow notes: export Spaces first if you want to keep them.")
            VStack(alignment: .leading, spacing: 6) {
                AppShellCopyRow(text: "~/Library/Application Support/SparkV")
                AppShellCopyRow(text: "~/Library/Preferences/com.sparkv.app.plist")
                AppShellCopyRow(text: "~/Library/Caches/com.sparkv.app")
                AppShellCopyRow(text: "~/Library/Logs/SparkV.log")
            }
            .padding(.leading, 26)
            step(5, "Remove privacy permissions", "In Terminal (no password needed), then delete SparkV from Accessibility and Screen Recording with −:")
            AppShellCopyRow(text: "tccutil reset All com.sparkv.app")
                .padding(.leading, 26)
            step(6, "Move SparkV.app to the Trash", "Drag it from Finder to the Trash:")
            AppShellCopyRow(text: appPath)
                .padding(.leading, 26)
            Text("Installed with Homebrew? Instead of steps 1 and 4 to 6, quit SparkV and run this; it removes the app, the Fan helper and the files of step 4:")
                .font(.system(size: 11.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
            AppShellCopyRow(text: ResetPlan.brewZapCommand)
                .padding(.leading, 26)
        }
        .padding(.vertical, 6)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .frame(width: 16, height: 16)
                .background(Circle().fill(SparkVTheme.surfaceHover))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Links to existing settings windows (until their packages add sections)

/// One row that opens a feature's own settings window.
struct AppShellLinkRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: @MainActor () -> Void

    var body: some View {
        LabeledContent {
            Button("Open…", action: action)
                .accessibilityLabel("Open \(title)")
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 22, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            }
        }
    }
}

/// Island pane: Notch Theme and Ambient Light keep their own windows.
struct AppShellIslandLinksSettingsSection: View {
    var body: some View {
        Section {
            AppShellLinkRow(title: "Ambient Light", detail: "A glow around the notch that follows your music.", symbol: "light.max") {
                AmbientLightSettingsWindowController.shared.show()
            }
        } header: {
            Text("Island Looks")
        }
    }
}

/// Extras pane: features with their own windows.
struct AppShellExtrasLinksSettingsSection: View {
    var body: some View {
        Section {
            AppShellLinkRow(title: "Spaces", detail: "Knowledge folders per organization.", symbol: "square.stack.3d.up.fill") {
                SpacesWindowController.shared.show()
            }
            AppShellLinkRow(title: "Modes", detail: "Wallpaper, music, apps and Focus in one switch.", symbol: "theatermasks.fill") {
                ModeEditorWindowController.shared.show()
            }
            AppShellLinkRow(title: "Sync to iPhone", detail: "Keeps iCloud Drive › SparkV up to date.", symbol: "iphone.and.arrow.forward") {
                CloudSyncWindowController.shared.show()
            }
            AppShellLinkRow(title: "Fan Control", detail: "Fan speeds, temperatures and presets.", symbol: "fan.fill") {
                FanControlWindowController.shared.show()
            }
            AppShellLinkRow(title: FaceUnlock.isSetUp ? "Face Unlock" : "Set Up Face Unlock",
                            detail: "Unlock this Mac with your face (on-device).", symbol: "faceid") {
                FaceUnlock.openSettings()
            }
        } header: {
            Text("More Settings")
        }
    }
}

// MARK: - Shared styling

extension View {
    /// Footer text under a settings group. textSecondary, not tertiary:
    /// footers carry the privacy disclosures and must reach 4.5:1.
    func settingsFooterStyle() -> some View {
        font(.system(size: 11.5))
            .foregroundStyle(SparkVTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
