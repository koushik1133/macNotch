import AppKit
import SwiftUI

// Settings sections (Settings › Shelf), the gear menu's Shelf items and
// the Agents hub tiles for the shelf, drops and transfers package. Each
// section takes no arguments and reads the shared singletons.

// MARK: - Settings › Shelf

/// The Tray: how much it holds, for how long, and what dragging out does.
struct ShelfSettingsSection: View {
    @ObservedObject private var settings = ShelfSettings.shared

    var body: some View {
        Section {
            Stepper(value: $settings.capacity, in: ShelfSettings.capacityRange) {
                Text("Keep up to \(settings.capacity) items on the Tray")
                Text("When it's full, the oldest item makes room. More than five scroll sideways.")
            }
            Toggle(isOn: $settings.keepAcrossRestarts) {
                Text("Keep items after SparkV restarts")
                Text("Off: the Tray starts empty each time; its own copies go to the Trash.")
            }
            Picker(selection: $settings.expiry) {
                ForEach(ShelfSettings.Expiry.allCases) { expiry in
                    Text(expiry.title).tag(expiry)
                }
            } label: {
                Text("Remove items automatically")
                Text("Checked when you open the Tray or add something; no timer runs.")
            }
            Picker(selection: $settings.dragOut) {
                ForEach(ShelfSettings.DragOut.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Dragging a file out of the Tray")
                Text("Screenshots and copies the Tray made itself are always copied, so the card keeps its file.")
            }
        } header: {
            Text("Tray")
        } footer: {
            Text("Click a card, then: Space for Quick Look, ← → to move, ⌘A to select all, Delete to remove (⌘Z puts it back), Return to open.")
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
        }
    }
}

/// Which drags open the notch.
struct ShelfDragSettingsSection: View {
    @ObservedObject private var settings = ShelfSettings.shared

    var body: some View {
        Section {
            Picker(selection: $settings.openOnDrag) {
                ForEach(ShelfSettings.OpenOnDrag.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Open the drawer while dragging")
                Text(detail)
            }
        } header: {
            Text("Dragging to the Notch")
        }
    }

    private var detail: String {
        switch settings.openOnDrag {
        case .files: "Only drags that carry files, images or promised files (Mail, Photos) open it; browser tabs, links and text don't."
        case .anything: "Any drag that reaches the notch opens it, including tabs, links and text."
        case .never: "Dragging never opens the drawer. Open it first, or use the drop shelf."
        }
    }
}

/// LocalSend and the Share menu.
struct NearbyShareSettingsSection: View {
    @ObservedObject private var settings = ShelfSettings.shared
    @ObservedObject private var localSend = LocalSendController.shared

    var body: some View {
        Section {
            Toggle(isOn: $settings.localSendEnabled) {
                Text("Send to Android, Windows and Linux with LocalSend")
                Text("Off until you turn it on. When on, SparkV looks for devices on your local network only while the Nearby panel is open, and sends only after you pick a device and that device accepts. Nothing goes through the internet.")
            }
            if settings.localSendEnabled {
                TextField(text: $settings.localSendAlias, prompt: Text(ShelfSettings.defaultAlias)) {
                    Text("Name other devices see")
                }
                if localSend.isBlocked {
                    LabeledContent("Local network") {
                        Button("Allow in Privacy & Security…") { localSend.openLocalNetworkSettings() }
                    }
                }
            }
            Toggle(isOn: $settings.promoteNearby) {
                Text("Put nearby senders first in Share menus")
                Text("NearDrop (Quick Share for Android) and LocalSend, when installed, above Mail and Messages.")
            }
            LabeledContent("Try it") {
                Button("Open Nearby Share…") { LocalSendPanelController.shared.open() }
            }
        } header: {
            Text("Nearby Share")
        }
    }
}

/// Finder copy progress under the notch.
struct FileTransfersSettingsSection: View {
    @ObservedObject private var settings = ShelfSettings.shared
    @ObservedObject private var monitor = ShelfTransfersMonitor.shared

    var body: some View {
        Section {
            Toggle(isOn: $settings.transfersEnabled) {
                Text("Show copy progress under the notch")
                Text("Finder copies into the folders below and onto external drives, with Pause, Cancel and Reveal. SparkV listens for the progress Finder publishes; it never lists or reads the folders.")
            }
            if settings.transfersEnabled {
                ForEach(settings.transferFolders, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(SparkVTheme.accent)
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            settings.transferFolders.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(SparkVTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop watching \(path)")
                        .accessibilityLabel("Remove \(path)")
                    }
                }
                HStack {
                    Button("Add Folder…") { ShelfSettingsActions.addTransferFolders() }
                    Spacer()
                }
                Toggle("Also the top level of external drives", isOn: $settings.transferVolumes)
            }
        } header: {
            Text("Copy Progress")
        } footer: {
            Text("macOS reports progress for items landing directly in a watched folder, not in its subfolders. Downloads have their own watcher (Downloads tab).")
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
        }
    }
}

/// Actions shared by the Settings sections and the gear menu.
@MainActor
enum ShelfSettingsActions {
    /// Picks folders to watch for Finder copy progress.
    static func addTransferFolders() {
        let settings = ShelfSettings.shared
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "SparkV shows Finder copy progress for items landing directly in these folders."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var folders = settings.transferFolders
        for path in panel.urls.map({ ShelfPaths.abbreviate($0) }) where !folders.contains(path) {
            folders.append(path)
        }
        settings.transferFolders = folders
        AppLog.log("Shelf: watching \(folders.count) folders for copy progress")
    }

    /// Asks for the name LocalSend devices see.
    static func renameNearbyDevice() {
        let settings = ShelfSettings.shared
        let alert = NSAlert()
        alert.messageText = "Name Other Devices See"
        alert.informativeText = "Shown in LocalSend on the phone or PC you send to."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = settings.localSendAlias
        field.placeholderString = ShelfSettings.defaultAlias
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.localSendAlias = field.stringValue
    }
}

/// The download watcher's switches (Settings › Shelf).
struct DownloadsSettingsSection: View {
    var body: some View {
        if let controller = DownloadsController.current {
            DownloadsSettingsSectionContent(controller: controller)
        } else {
            Section {
                Text("The download watcher starts with the notch.")
                    .foregroundStyle(SparkVTheme.textSecondary)
            } header: {
                Text("Downloads")
            }
        }
    }
}

private struct DownloadsSettingsSectionContent: View {
    @ObservedObject var controller: DownloadsController

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) })) {
                Text("Watch the Downloads folder")
                Text("Progress for Safari, Chrome, Arc, Edge, Brave and Firefox downloads, with Pause and Cancel where the browser allows it, then a suggested folder.")
            }
            Toggle("Show download progress under the notch", isOn: $controller.showsActivity)
                .disabled(!controller.isEnabled)
            Toggle(isOn: $controller.suggestsWithAI) {
                Text("Suggest folders with Apple Intelligence")
                Text("On this Mac; nothing is sent anywhere.")
            }
            LabeledContent("Sorting") {
                Button("Edit Rules…") { controller.openRulesEditor() }
            }
            if controller.status == .denied {
                LabeledContent("Access") {
                    Button("Open Privacy & Security…") { controller.openPrivacySettings() }
                }
            }
        } header: {
            Text("Downloads")
        }
    }
}

// MARK: - Gear menu

/// Items for `Menu("Shelf") { ShelfMenuItems() }` in the gear menu.
struct ShelfMenuItems: View {
    @ObservedObject private var settings = ShelfSettings.shared

    var body: some View {
        Picker("Tray Holds", selection: $settings.capacity) {
            ForEach(capacityChoices, id: \.self) { count in
                Text("\(count) Items").tag(count)
            }
        }
        Picker("Remove Items", selection: $settings.expiry) {
            ForEach(ShelfSettings.Expiry.allCases) { expiry in
                Text(expiry.title).tag(expiry)
            }
        }
        Toggle("Keep Items After Restart", isOn: $settings.keepAcrossRestarts)
        Picker("Dragging Files Out", selection: $settings.dragOut) {
            ForEach(ShelfSettings.DragOut.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        Divider()
        Picker("Open Drawer While Dragging", selection: $settings.openOnDrag) {
            ForEach(ShelfSettings.OpenOnDrag.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        Toggle("Shake a File Drag for a Shelf at the Pointer", isOn: $settings.shakeForShelf)
        Divider()
        Button("Send to Android / Windows…") { LocalSendPanelController.shared.open() }
        Toggle("Nearby Senders First in Share Menus", isOn: $settings.promoteNearby)
        Button("Name Other Devices See…") { ShelfSettingsActions.renameNearbyDevice() }
            .disabled(!settings.localSendEnabled)
        Divider()
        Toggle("Show Copy Progress Under the Notch", isOn: $settings.transfersEnabled)
        Menu("Copy Progress Folders") {
            ForEach(settings.transferFolders, id: \.self) { path in
                Button("Stop Watching \(path)") { settings.transferFolders.removeAll { $0 == path } }
            }
            if !settings.transferFolders.isEmpty { Divider() }
            Button("Add Folder…") { ShelfSettingsActions.addTransferFolders() }
        }
        .disabled(!settings.transfersEnabled)
        Toggle("Also External Drives", isOn: $settings.transferVolumes)
            .disabled(!settings.transfersEnabled)
    }

    private var capacityChoices: [Int] {
        Array(Set([5, 8, 10, 15, 20, 30, settings.capacity])).sorted()
    }
}

// MARK: - Agents hub tiles (category: Files)

/// Nearby Share: opens the LocalSend panel with the Tray's picked items
/// (or all of them). Right-click: settings.
struct NearbyShareHubTile: View {
    @EnvironmentObject private var tray: TrayStore
    @ObservedObject private var localSend = LocalSendController.shared
    @ObservedObject private var settings = ShelfSettings.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let active = localSend.isBusy
        let tint = NearbyStyle.tint
        Button {
            let items = tray.selection.isEmpty ? tray.items : tray.keyboardTargets
            LocalSendPanelController.shared.open(files: ShelfShare.fileURLs(for: items))
        } label: {
            ShelfHubTileFace(symbol: "wave.3.right.circle.fill", title: active ? "Sending…" : "Nearby", tint: tint,
                             isActive: active, isHovered: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(settings.localSendEnabled
              ? "Send Tray items to Android, Windows or Linux with LocalSend"
              : "Nearby Share: send to Android, Windows or Linux with LocalSend (off until you turn it on)")
        .contextMenu {
            Toggle("Nearby Share (LocalSend)", isOn: $settings.localSendEnabled)
            Toggle("Nearby Senders First in Share Menus", isOn: $settings.promoteNearby)
        }
        .accessibilityLabel("Nearby Share")
    }
}

/// Copies and sends in flight; opens the Downloads tab, where they're listed
/// with Pause and Cancel. Right-click: copy progress on or off.
struct FileTransfersHubTile: View {
    @EnvironmentObject private var state: NotchState
    @ObservedObject private var monitor = ShelfTransfersMonitor.shared
    @ObservedObject private var settings = ShelfSettings.shared
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let active = monitor.activeTransfers
        let summary = ShelfTransfersBand.summary(active)
        let title: String = if active.isEmpty {
            "Transfers"
        } else if let fraction = summary.fraction {
            DownloadFormat.percent(fraction)
        } else {
            "\(active.count) active"
        }
        Button {
            withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) { state.select(.downloads) }
        } label: {
            ShelfHubTileFace(symbol: "doc.on.doc.fill", title: title, tint: .blue, isActive: !active.isEmpty, isHovered: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(settings.transfersEnabled ? "Copy and send progress (opens Downloads)" : "Copy progress is off: right-click to turn it on")
        .contextMenu {
            Toggle("Show Copy Progress Under the Notch", isOn: $settings.transfersEnabled)
            Button("Send to Android / Windows…") { LocalSendPanelController.shared.open() }
        }
        .accessibilityLabel(active.isEmpty ? "Transfers" : "Transfers, \(title)")
    }
}

/// The hub's tile face (same metrics as `AgentTile`): Apple tints the glyph,
/// SparkV Red lights it red.
struct ShelfHubTileFace: View {
    let symbol: String
    let title: String
    let tint: Color
    let isActive: Bool
    let isHovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        let apple = SparkVTheme.usesTileTints
        let lit = isActive || isHovered
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(apple ? tint : (lit ? SparkVTheme.red : SparkVTheme.text.opacity(0.88)))
                // Same glyph box for every tile, so the labels line up.
                .frame(height: 20)
            Text(title)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(LabsBHubTileBackground.label(isActive: isActive, isHovered: isHovered))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background {
            if apple {
                LabsBHubTileBackground(isActive: isActive, isHovered: isHovered, tint: tint)
            } else {
                shape.fill(isActive ? SparkVTheme.redSoft : (isHovered ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface))
                    .overlay(shape.strokeBorder(lit ? SparkVTheme.red.opacity(isActive ? 0.55 : 0.35) : SparkVTheme.stroke, lineWidth: 1))
            }
        }
        .contentShape(shape)
        .animation(SparkVMotion.hover(), value: isHovered)
    }
}
