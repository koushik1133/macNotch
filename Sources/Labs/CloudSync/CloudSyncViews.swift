import AppKit
import SwiftUI

// UI for "Sync to iPhone": the settings window and a compact status row for
// the drawer or Settings. Styled with SparkVTheme (no @State: CLT builds).

/// The full settings and status page.
struct CloudSyncSettingsView: View {
    @ObservedObject var controller: CloudSyncController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if controller.settings.isEnabled {
                    statusCard
                    categoriesCard
                    optionsCard
                    phoneCard
                    activityCard
                } else {
                    introCard
                    phoneCard
                }
            }
            .padding(24)
        }
        .background { AppearanceWindowBackground().ignoresSafeArea() }
        .background(SparkVTheme.glow.ignoresSafeArea())
        .foregroundStyle(SparkVTheme.text)
        .tint(SparkVTheme.accent)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // SparkV Red: the sparkv.si eyebrow. Apple: just the title, as in System Settings.
            if !SparkVTheme.isApple {
                Text("SPARKV / SYNC")
                    .font(SparkVTheme.eyebrow())
                    .tracking(1.2)
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            Text("Sync to iPhone")
                .font(SparkVTheme.title(24))
            Text("SparkV keeps a folder in iCloud Drive up to date. Open it on your iPhone or iPad in the Files app.")
                .font(SparkVTheme.body(12.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var introCard: some View {
        CloudSyncCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Your meetings, notes, Spaces and more, readable anywhere", systemImage: "iphone.and.arrow.forward")
                    .font(SparkVTheme.headline(13))
                Text("Files are written to iCloud Drive › SparkV as Markdown and copies. Nothing is ever deleted: files SparkV no longer needs move to a hidden trash folder. Pinned clipboard sync stays off until you turn it on.")
                    .font(SparkVTheme.body())
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Turn On Sync") { controller.setEnabled(true) }
                        .buttonStyle(SparkVPrimaryButtonStyle())
                    Button("Use Another Folder…") {
                        if controller.chooseFolder() { controller.setEnabled(true) }
                    }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        CloudSyncCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    CloudSyncStatusDot(status: controller.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.status.label)
                            .font(SparkVTheme.headline(13))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detailLine)
                            .font(SparkVTheme.caption())
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    Spacer(minLength: 8)
                }
                HStack(spacing: 8) {
                    statusButtons
                }
                if let report = controller.lastReport, !report.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(report.skipped.prefix(4).enumerated()), id: \.offset) { _, line in
                            Text(line).font(SparkVTheme.caption()).foregroundStyle(SparkVTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusButtons: some View {
        if controller.isBlockedByPrivacy {
            Button("Open Privacy Settings") { controller.openPrivacySettings() }
                .buttonStyle(SparkVPrimaryButtonStyle())
            Button("Retry") { controller.syncNow() }
                .buttonStyle(SparkVSecondaryButtonStyle())
        } else if case .paused(let reason) = controller.status, reason != nil {
            Button("Create the Folder Again") { controller.recreateFolder() }
                .buttonStyle(SparkVPrimaryButtonStyle())
            Button("Turn Off Sync") { controller.setEnabled(false) }
                .buttonStyle(SparkVSecondaryButtonStyle())
        } else if controller.heldRemovals > 0 {
            Button("Move \(controller.heldRemovals) Files to Trash") { controller.applyHeldRemovals() }
                .buttonStyle(SparkVPrimaryButtonStyle())
            Button("Show Folder") { controller.revealInFinder() }
                .buttonStyle(SparkVSecondaryButtonStyle())
        } else if case .attention = controller.status, controller.settings.customFolderPath == nil {
            Button("Open iCloud Settings") { controller.openICloudSettings() }
                .buttonStyle(SparkVPrimaryButtonStyle())
            Button("Use Another Folder…") { controller.chooseFolder() }
                .buttonStyle(SparkVSecondaryButtonStyle())
        } else {
            Button(controller.settings.isPaused ? "Resume" : "Sync Now") { controller.syncNow() }
                .buttonStyle(SparkVPrimaryButtonStyle())
                .disabled(controller.status == .syncing)
            if !controller.settings.isPaused {
                Button("Pause") { controller.setPaused(true) }
                    .buttonStyle(SparkVSecondaryButtonStyle())
            }
            Button("Show in Finder") { controller.revealInFinder() }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .disabled(controller.destination == nil)
        }
        Spacer(minLength: 0)
        Button("Turn Off") { controller.setEnabled(false) }
            .buttonStyle(.plain)
            .font(SparkVTheme.caption(11))
            .foregroundStyle(SparkVTheme.textTertiary)
    }

    private var detailLine: String {
        var parts = [controller.locationDescription]
        if let date = controller.lastSync {
            parts.append("checked \(date.formatted(.relative(presentation: .named)))")
        }
        if controller.trackedFiles > 0 { parts.append("\(controller.trackedFiles) files") }
        return parts.joined(separator: " · ")
    }

    // MARK: Categories

    private var categoriesCard: some View {
        CloudSyncCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("What to sync")
                ForEach(CloudSyncCategory.allCases) { category in
                    CloudSyncToggleRow(
                        systemImage: category.systemImage, title: category.title, detail: category.detail,
                        isOn: Binding(get: { controller.isOn(category) }, set: { controller.setCategory(category, $0) })
                    )
                }
                Text("Turning a category off stops updating it; its files stay in iCloud Drive.")
                    .font(SparkVTheme.caption())
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    private var optionsCard: some View {
        CloudSyncCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Options")
                CloudSyncToggleRow(
                    systemImage: "tray.and.arrow.down.fill", title: "Import from the Inbox folder",
                    detail: "Notes, links, photos and files saved to SparkV › Inbox on the iPhone come into Spaces and the Tray",
                    isOn: Binding(get: { controller.settings.importsInbox }, set: { controller.setImportsInbox($0) })
                )
                CloudSyncToggleRow(
                    systemImage: "text.quote", title: "Include meeting transcripts",
                    detail: "Off keeps meeting files to notes, tasks and decisions",
                    isOn: Binding(get: { controller.settings.includesTranscripts }, set: { controller.setIncludesTranscripts($0) })
                )
                CloudSyncToggleRow(
                    systemImage: "paperclip", title: "Include Spaces attachments",
                    detail: "Copies screenshots and files next to their notes (up to 100 MB each)",
                    isOn: Binding(get: { controller.settings.includesSpaceAttachments }, set: { controller.setIncludesSpaceAttachments($0) })
                )
                Divider().overlay(SparkVTheme.stroke)
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(SparkVTheme.textSecondary)
                    Text(controller.locationDescription).font(SparkVTheme.body())
                    Spacer()
                    if controller.settings.customFolderPath != nil {
                        Button("Use iCloud Drive") { controller.useICloudDrive() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                    Button("Change…") { controller.chooseFolder() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                    Button("Trash") { controller.revealTrash() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .disabled(controller.destination == nil)
                }
            }
        }
    }

    // MARK: iPhone

    private var phoneCard: some View {
        CloudSyncCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("On your iPhone")
                step(1, "Open the Files app and tap Browse › iCloud Drive › SparkV.")
                step(2, "Tap a meeting or note to read it. Long-press › Share to send it anywhere.")
                step(3, "To send something to this Mac, use the share sheet: Save to Files › SparkV › Inbox.")
                Text("Same Apple Account on both devices, iCloud Drive on. Universal Clipboard and Handoff already work between your Mac and iPhone.")
                    .font(SparkVTheme.caption())
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(SparkVTheme.caption(10))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(SparkVTheme.red))
            Text(text)
                .font(SparkVTheme.body())
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Activity

    @ViewBuilder private var activityCard: some View {
        if !controller.activity.isEmpty {
            CloudSyncCard {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Recent activity")
                    ForEach(controller.activity.prefix(12)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.date.formatted(date: .omitted, time: .shortened))
                                .font(SparkVTheme.caption())
                                .foregroundStyle(SparkVTheme.textTertiary)
                                .frame(width: 58, alignment: .leading)
                            Text(line.text)
                                .font(SparkVTheme.body(11.5))
                                .foregroundStyle(SparkVTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SparkVTheme.eyebrow())
            .tracking(SparkVTheme.isApple ? 0.6 : 1.2)
            .foregroundStyle(SparkVTheme.textTertiary)
    }
}

/// A raised SparkV card.
struct CloudSyncCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke)
            )
    }
}

struct CloudSyncToggleRow: View {
    let systemImage: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? SparkVTheme.red : SparkVTheme.textTertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(SparkVTheme.headline(12.5))
                Text(detail)
                    .font(SparkVTheme.caption())
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct CloudSyncStatusDot: View {
    let status: CloudSyncStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(SparkVTheme.isApple ? 0 : 0.6), radius: 4)
    }

    private var color: Color {
        switch status {
        case .off: SparkVTheme.textTertiary
        case .idle: SparkVTheme.success
        case .syncing: SparkVTheme.red
        case .paused: SparkVTheme.textSecondary
        case .attention: SparkVTheme.warning
        case .failed: SparkVTheme.destructive
        }
    }
}

/// One line for the drawer, a hub tile or Settings: state, last sync and a
/// button that opens the full page.
struct CloudSyncStatusRow: View {
    @ObservedObject var controller: CloudSyncController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(controller.settings.isEnabled ? SparkVTheme.red : SparkVTheme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sync to iPhone").font(SparkVTheme.headline(12))
                HStack(spacing: 5) {
                    CloudSyncStatusDot(status: controller.status)
                    Text(subtitle)
                        .font(SparkVTheme.caption())
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button(controller.settings.isEnabled ? "Open" : "Set Up") { CloudSyncWindowController.shared.show() }
                .buttonStyle(SparkVSecondaryButtonStyle())
        }
    }

    private var subtitle: String {
        switch controller.status {
        case .idle:
            if let date = controller.lastSync { return "Up to date · \(date.formatted(date: .omitted, time: .shortened))" }
            return "Up to date"
        default:
            return controller.status.label
        }
    }
}

// MARK: - Window

@MainActor
final class CloudSyncWindowController: NSObject, NSWindowDelegate {
    static let shared = CloudSyncWindowController()
    private var window: NSWindow?

    func show(controller given: CloudSyncController? = nil) {
        let window = window ?? makeWindow(controller: given ?? CloudSyncController.shared)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(controller: CloudSyncController) -> NSWindow {
        let hosting = NSHostingController(rootView: CloudSyncSettingsView(controller: controller).followsAppearance())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sync to iPhone"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsWindowGround.follow(window)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 600, height: 720))
        window.minSize = NSSize(width: 480, height: 420)
        window.center()
        window.setFrameAutosaveName("SparkV.CloudSync")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Notch band

extension CloudSyncController {
    static let importActivityID = "cloudsync.import"

    /// A short band for `onImport`: "2 items arrived from iPhone".
    static func importActivity(_ message: String) -> LiveActivity {
        LiveActivity(id: importActivityID, kind: .notification, priority: 55, duration: 4,
                     symbol: "iphone.and.arrow.forward", tint: SparkVTheme.red) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.red)
                Text(message)
                    .font(SparkVTheme.headline(12))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
            }
        }
    }
}
