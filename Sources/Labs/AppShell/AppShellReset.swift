import AppKit
import Security
import ServiceManagement
import SwiftUI

/// "Reset SparkV…" and "Uninstall SparkV…".
///
/// After a confirmation that lists exactly what goes (what moves to the
/// Trash, what is deleted for good), in this order:
/// 0. optionally export every Space to a Desktop folder first (on by
///    default when there are Spaces; a failed export stops everything),
/// 1. finish a recording or mode and stop every feature (the island's hook),
/// 2. remove the login item (SMAppService),
/// 3. optionally remove the Fan Control helper (one administrator prompt,
///    only when that box is ticked; fans go back to Auto),
/// 4. delete SparkV's own keychain items (Groq key, Face Unlock, Cloud Sync),
/// 5. move SparkV's folders in ~/Library to the Trash (recoverable),
/// 6. reset SparkV's privacy permissions (`tccutil reset All com.sparkv.app`,
///    no password needed for its own bundle id),
/// 7. remove its preferences (both bundle ids),
/// 8. Reset relaunches SparkV fresh; Uninstall moves SparkV.app to the Trash.
/// It ends with `exit(0)`, not a normal quit, so nothing writes its state
/// (or its preferences) back on the way out.
@MainActor
final class ResetController {
    static let shared = ResetController()

    enum Mode {
        case reset, uninstall
        var title: String { self == .reset ? "Reset SparkV" : "Uninstall SparkV" }
    }

    /// Options the confirmation shows (no @State).
    final class Options: ObservableObject {
        @Published var removeICloudFolder = false
        @Published var removeFanHelper: Bool
        @Published var exportSpacesFirst: Bool
        let mode: Mode
        let items: [ResetPlan.Item]
        let iCloudFolder: URL?
        let fanHelperInstalled: Bool
        /// Top-level Spaces (their folders and items go with them).
        let spaceCount: Int
        /// False when SparkV runs from Downloads (App Translocation) or a
        /// disk image: Uninstall can't move the app itself.
        let canTrashApp: Bool

        init(mode: Mode, items: [ResetPlan.Item], iCloudFolder: URL?, fanHelperInstalled: Bool,
             spaceCount: Int = 0, canTrashApp: Bool = true) {
            self.mode = mode
            self.items = items
            self.iCloudFolder = iCloudFolder
            self.fanHelperInstalled = fanHelperInstalled
            self.spaceCount = spaceCount
            self.canTrashApp = canTrashApp
            // A root helper must not outlive an uninstall; a reset keeps it.
            removeFanHelper = fanHelperInstalled && mode == .uninstall
            exportSpacesFirst = spaceCount > 0
        }
    }

    private(set) var isRunning = false

    static var iCloudFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/SparkV", isDirectory: true)
    }

    static var fanHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: FanHelperConstants.launchdPlist)
            || FileManager.default.fileExists(atPath: FanHelperConstants.installedBinary)
    }

    /// Existing items only, plus the preference files.
    static func currentItems() -> [ResetPlan.Item] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = FileManager.default
        return (ResetPlan.items(home: home) + ResetPlan.preferenceFiles(home: home)).filter { files.fileExists(atPath: $0.url.path) }
    }

    func options(for mode: Mode) -> Options {
        let iCloud = Self.iCloudFolder
        return Options(
            mode: mode,
            items: Self.currentItems(),
            iCloudFolder: FileManager.default.fileExists(atPath: iCloud.path) ? iCloud : nil,
            fanHelperInstalled: Self.fanHelperInstalled,
            spaceCount: Self.rootSpaces().count,
            canTrashApp: Self.canTrashApp
        )
    }

    static func rootSpaces() -> [Space] {
        SpaceStore.shared.spaces.filter { $0.parentID == nil }
    }

    static var canTrashApp: Bool {
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent().path
        return ResetPlan.canMoveAppToTrash(bundlePath: bundle.path, parentWritable: FileManager.default.isWritableFile(atPath: parent))
    }

    /// Every top-level Space as a .sparkvspace package in
    /// ~/Desktop/SparkV Spaces <date>. Returns the folder, or why it failed.
    static func exportSpaces() -> Result<URL, Error> {
        let files = FileManager.default
        let desktop = files.urls(for: .desktopDirectory, in: .userDomainMask).first ?? files.homeDirectoryForCurrentUser
        let folder = desktop.appendingPathComponent("SparkV Spaces \(DiagnosticsController.stamp(Date()))", isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            var taken: Set<String> = []
            for space in rootSpaces() {
                let name = ResetPlan.spaceExportName(space.name, taken: taken)
                taken.insert(name)
                try SpaceStore.shared.exportSpace(space.id, to: folder.appendingPathComponent(name))
            }
            return .success(folder)
        } catch {
            return .failure(error)
        }
    }

    /// The confirmation. Cancel is the default button; the destructive
    /// button is red and needs a click (or Tab + Space).
    func confirm(_ mode: Mode) {
        guard !isRunning else { return }
        let options = options(for: mode)
        let alert = Self.makeAlert(options)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppLog.log("Reset: \(mode.title) confirmed (iCloud \(options.removeICloudFolder), fan helper \(options.removeFanHelper))")
        isRunning = true
        Task { await perform(mode, options: options) }
    }

    /// The confirmation alert (built separately so it can be rendered).
    static func makeAlert(_ options: Options) -> NSAlert {
        let mode = options.mode
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = mode == .reset ? "Reset SparkV?" : "Uninstall SparkV?"
        alert.informativeText = mode == .reset
            ? "SparkV quits, moves its files to the Trash, deletes its settings, keychain items and permissions, and starts again like the first time. Files in the Trash can be put back; the rest can’t."
            : "SparkV quits, moves itself and its files to the Trash, and deletes its settings, keychain items, login item and permissions. Files in the Trash can be put back; the rest can’t."
        let destructive = alert.addButton(withTitle: mode == .reset ? "Reset SparkV" : "Uninstall SparkV")
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let accessory = NSHostingView(rootView: ResetConfirmationView(options: options).environment(\.colorScheme, .dark))
        accessory.frame = NSRect(origin: .zero, size: accessory.fittingSize)
        alert.accessoryView = accessory
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.icon = SparkVAppMark.image(size: 64)
        return alert
    }

    private func perform(_ mode: Mode, options: Options) async {
        // 0. Spaces out first, while everything still runs. If that fails
        //    nothing is touched.
        if options.exportSpacesFirst, options.spaceCount > 0 {
            switch Self.exportSpaces() {
            case .success(let folder):
                AppLog.log("Reset: exported \(options.spaceCount) Space(s) to the Desktop")
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            case .failure(let error):
                AppLog.log("Reset: Space export failed, nothing removed: \(error.localizedDescription)")
                isRunning = false
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "SparkV wasn’t \(mode == .reset ? "reset" : "uninstalled")"
                alert.informativeText = "Your Spaces couldn’t be exported, so nothing was removed. \(error.localizedDescription)"
                alert.runModal()
                return
            }
        }

        // 1. Recordings and modes finish; features stop and let go of files.
        if let prepare = AppShellController.shared.prepareForReset { await prepare() }
        AppShellController.shared.stop()

        // 2. Login item.
        do { try await SMAppService.mainApp.unregister() } catch { AppLog.log("Reset: login item: \(error.localizedDescription)") }

        // 3. Fan helper (its own administrator prompt).
        if options.removeFanHelper, Self.fanHelperInstalled {
            FanController.shared.stop()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                FanHelperInstaller.run(install: false) { result in
                    if case .failure(let error) = result { AppLog.log("Reset: fan helper not removed: \(error.localizedDescription)") }
                    done.resume()
                }
            }
        }

        // 4. Keychain.
        let removedKeys = Self.deleteOwnKeychainItems()

        // 5. Files to the Trash (the log last, so this run is still logged).
        AppLog.log("Reset: removed \(removedKeys) keychain item(s); moving files to the Trash")
        try? await Task.sleep(for: .milliseconds(300))
        var targets = Self.currentItems().map(\.url).filter { $0.pathExtension != "plist" }
        if options.removeICloudFolder, let iCloud = options.iCloudFolder { targets.append(iCloud) }
        let files = FileManager.default
        for url in targets.sorted(by: { ($0.pathExtension == "log" ? 1 : 0) < ($1.pathExtension == "log" ? 1 : 0) }) {
            do { try files.trashItem(at: url, resultingItemURL: nil) } catch {
                NSLog("SparkV reset: couldn’t move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
        }

        // 6. Privacy permissions for SparkV's own bundle id.
        for id in ResetPlan.bundleIDs { Self.run("/usr/bin/tccutil", ["reset", "All", id]) }

        // 7. Preferences. Nothing may write a default after this point.
        for id in ResetPlan.bundleIDs {
            UserDefaults.standard.removePersistentDomain(forName: id)
            CFPreferencesAppSynchronize(id as CFString)
        }

        // 8. Relaunch or remove the app.
        let bundle = Bundle.main.bundleURL
        switch mode {
        case .reset:
            // A detached shell waits for this process to exit, then opens SparkV again.
            let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), bundle.path]
            try? relaunch.run()
            exit(0)
        case .uninstall:
            guard options.canTrashApp else {
                Self.askToTrashAppByHand(bundle, reason: "SparkV is running from a read-only copy (opened from Downloads or a disk image).")
                exit(0)
            }
            NSWorkspace.shared.recycle([bundle]) { _, error in
                MainActor.assumeIsolated {
                    if let error {
                        NSLog("SparkV uninstall: couldn’t move SparkV.app to the Trash: \(error.localizedDescription)")
                        Self.askToTrashAppByHand(bundle, reason: error.localizedDescription)
                    }
                    exit(0)
                }
            }
            // If Finder never answers, still quit.
            try? await Task.sleep(for: .seconds(8))
            exit(0)
        }
    }

    /// The data is gone but the app stayed: say so, and show it in Finder
    /// (not possible under translocation, where the original location
    /// isn't known: then the Applications and Downloads folders).
    private static func askToTrashAppByHand(_ bundle: URL, reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Drag SparkV.app to the Trash"
        alert.informativeText = "SparkV’s data is removed, but it couldn’t move its own app to the Trash. \(reason)"
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if bundle.path.contains("/AppTranslocation/") {
            let files = FileManager.default
            let folders = [URL(fileURLWithPath: "/Applications"), files.urls(for: .downloadsDirectory, in: .userDomainMask).first].compactMap { $0 }
            for folder in folders { NSWorkspace.shared.open(folder) }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([bundle])
        }
    }

    /// Generic passwords whose service belongs to SparkV (or its old name).
    /// Reads attributes only (no secrets, no prompt), then deletes matches.
    nonisolated static func deleteOwnKeychainItems() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return 0 }
        let services = Set(items.compactMap { $0[kSecAttrService as String] as? String }.filter(ResetPlan.isOwnKeychainService))
        var removed = 0
        for service in services {
            let delete: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            if SecItemDelete(delete as CFDictionary) == errSecSuccess { removed += 1 }
        }
        return removed
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// The confirmation's lists and options (inside the NSAlert): what moves
/// to the Trash (recoverable) and what is deleted for good.
struct ResetConfirmationView: View {
    @ObservedObject var options: ResetController.Options

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Moves to the Trash (you can put it back)")
            list(scrolls: trashRowCount > 6) {
                if options.mode == .uninstall, options.canTrashApp {
                    row("SparkV.app", symbol: "app")
                }
                if trashItems.isEmpty, !(options.mode == .uninstall && options.canTrashApp) {
                    row("No files saved yet", symbol: "checkmark")
                }
                ForEach(trashItems, id: \.url) { item in
                    row(item.label, symbol: item.url.pathExtension == "log" ? "doc.text" : "folder")
                }
            }

            heading("Deleted for good")
            list(scrolls: false) {
                ForEach(ResetPlan.permanentItems, id: \.self) { line in
                    row(line, symbol: "xmark.circle")
                }
            }

            if options.spaceCount > 0 {
                Toggle(isOn: $options.exportSpacesFirst) {
                    Text("Export my \(options.spaceCount == 1 ? "Space" : "\(options.spaceCount) Spaces") to the Desktop first (.sparkvspace)")
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            }
            if options.iCloudFolder != nil {
                Toggle("Also move iCloud Drive › SparkV to the Trash (on every device)", isOn: $options.removeICloudFolder)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }
            if options.fanHelperInstalled {
                Toggle("Remove the Fan Control helper (asks for your administrator password)", isOn: $options.removeFanHelper)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }
            if options.mode == .uninstall, !options.canTrashApp {
                note("SparkV is running from a read-only copy (opened from Downloads or a disk image), so it can’t move its own app. Afterwards, drag SparkV.app to the Trash.")
            }
            if options.mode == .uninstall, SparkVAppInfo.isHomebrewInstall {
                note("Installed with Homebrew? Afterwards, run “\(ResetPlan.brewZapCommand)” in Terminal so Homebrew forgets it too.")
            }
        }
        .frame(width: 360, alignment: .leading)
    }

    private var trashItems: [ResetPlan.Item] {
        options.items.filter { $0.url.pathExtension != "plist" }
    }

    private var trashRowCount: Int {
        max(1, trashItems.count + (options.mode == .uninstall && options.canTrashApp ? 1 : 0))
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SparkVTheme.textSecondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(SparkVTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A long list scrolls in a fixed height (the alert can't grow later).
    @ViewBuilder
    private func list<Content: View>(scrolls: Bool, @ViewBuilder content: () -> Content) -> some View {
        let stack = VStack(alignment: .leading, spacing: 5) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        Group {
            if scrolls {
                ScrollView { stack }.frame(height: 160)
            } else {
                stack
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private func row(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
