import AppKit
import Combine
import SwiftUI

/// "Ask about screen": select a region (or window), capture it, and open the
/// results panel beside it. Entry points: `beginSelection()` from the drawer
/// button, a menu item, or the global hotkey (⌃⌥S by default, registered by
/// `installHotkey()`).
@MainActor
final class ScreenRegionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case selecting
        case capturing
        /// The results panel is open.
        case showing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasScreenRecording = false
    /// Screen Recording was asked for this session but applies only after
    /// SparkV restarts (offer Restart instead of asking again).
    @Published private(set) var screenRecordingNeedsRelaunch = false
    /// The open (or most recent) selection.
    @Published private(set) var session: ScreenRegionSession?
    @Published private(set) var lastError: String?
    @Published private(set) var shortcut: ScreenRegionShortcut
    @Published private(set) var hotkeyRegistered = false
    /// This feature's own Groq opt-in (default off). See DESIGN.md.
    @Published var allowGroq: Bool {
        didSet {
            guard allowGroq != oldValue else { return }
            ScreenRegionSettings.allowGroq = allowGroq
            AppLog.log("Screen Region: Groq \(allowGroq ? "allowed" : "off")")
        }
    }

    /// Called right before the overlay appears. Wire to `clicky.cancel()`:
    /// ⌃⌥ is also Clicky's hold-to-talk chord.
    var onWillBeginSelection: (() -> Void)?
    /// Wire to `tray.accept(_:)` to offer "Save to Tray".
    var onSaveToTray: (([NSItemProvider]) -> Void)?
    /// Opens the capture in Tray AI. Defaults to `TrayAIPanelController.shared`
    /// with a temporary image item (never added to the tray).
    var onOpenInTrayAI: (([TrayItem]) -> Void)? = { items in TrayAIPanelController.shared.open(items: items) }

    let assistant = ScreenRegionAssistant()
    /// Copy Text (⌃⌥T): selection → OCR → clipboard. Started, stopped and
    /// given its hotkey together with this controller.
    let textGrab: ScreenTextGrabController
    /// Extra tile for the Screen tab (the screen recorder puts its Record
    /// button here). Kept as a closure so this folder doesn't depend on it.
    @Published var drawerAccessory: (() -> AnyView)?
    private let activities: ActivityCenter
    private let overlay = ScreenRegionOverlayController()
    private let panel = ScreenRegionPanelController()
    private let hotkey = ScreenRegionHotkey()
    private var captureTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var started = false
    private var warmUpTask: Task<Void, Never>?
    private var permissionSubscriptions: Set<AnyCancellable> = []

    /// Keep the last capture this long after its panel closed (for Reopen).
    static let keepLastCapture: Duration = .seconds(600)
    static let activityID = "screenRegion"

    init(activities: ActivityCenter) {
        self.activities = activities
        textGrab = ScreenTextGrabController(activities: activities)
        shortcut = ScreenRegionSettings.shortcut
        allowGroq = ScreenRegionSettings.allowGroq
        panel.onClose = { [weak self] in self?.panelClosed() }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        textGrab.onWillBegin = { [weak self] in self?.onWillBeginSelection?() }
        textGrab.isBusyElsewhere = { [weak self] in
            guard let self else { return false }
            return self.phase == .selecting || self.phase == .capturing
        }
        // Mirror PermissionCenter (no polling): the drawer row updates when
        // the grant changes or a restart becomes due.
        let center = PermissionCenter.shared
        center.$statuses
            .map { $0[.screenRecording]?.isGranted == true }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermission() } }
            .store(in: &permissionSubscriptions)
        center.$screenRecordingNeedsRelaunch
            .removeDuplicates()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermission() } }
            .store(in: &permissionSubscriptions)
    }

    var canSaveToTray: Bool { onSaveToTray != nil }
    var canOpenInTrayAI: Bool { onOpenInTrayAI != nil }
    /// Attributes-only keychain check; never prompts.
    var groqKeySaved: Bool { ClickyKeychain.hasKey() }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        ScreenRegionFiles.sweep()
        refreshPermission()
        warmUpTask?.cancel()
        warmUpTask = Task {
            // Off the launch path: OCR for Copy Text / Extract text.
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            ScreenTextRecognizer.warmUp()
        }
        AppLog.log("Screen Region: started (Screen Recording \(hasScreenRecording ? "granted" : "off"))")
    }

    func stop() {
        started = false
        warmUpTask?.cancel()
        captureTask?.cancel()
        captureTask = nil
        overlay.cancel()
        panel.close()
        session?.cancel()
        discardSession()
        uninstallHotkey()
        textGrab.stop()
        activities.dismiss(id: Self.activityID)
        ScreenRegionFiles.sweep()
        phase = .idle
    }

    // MARK: Hotkey

    /// Registers the global shortcut (Carbon; no permission needed).
    @discardableResult
    func installHotkey() -> Bool {
        hotkeyRegistered = hotkey.register(shortcut)
        if hotkeyRegistered { AppLog.log("Screen Region: hotkey \(shortcut.displayString)") }
        textGrab.installHotkey()
        return hotkeyRegistered
    }

    func uninstallHotkey() {
        hotkey.unregister()
        hotkeyRegistered = false
        textGrab.uninstallHotkey()
    }

    /// Changes (and saves) the shortcut; re-registers when one was registered.
    @discardableResult
    func setShortcut(_ newValue: ScreenRegionShortcut) -> Bool {
        guard newValue.isValidGlobal else { return false }
        let wasRegistered = hotkeyRegistered
        shortcut = newValue
        ScreenRegionSettings.shortcut = newValue
        return wasRegistered ? installHotkey() : true
    }

    private func hotkeyPressed() {
        switch phase {
        case .selecting: overlay.cancel()
        case .capturing: break
        case .idle, .showing: beginSelection()
        }
    }

    // MARK: Permission

    func refreshPermission() {
        let granted = ScreenRegionCapture.hasPermission
        if hasScreenRecording != granted { hasScreenRecording = granted }
        let relaunch = !granted && PermissionCenter.shared.screenRecordingNeedsRelaunch
        if screenRecordingNeedsRelaunch != relaunch { screenRecordingNeedsRelaunch = relaunch }
    }

    /// Only from an explicit "Allow" click. PermissionCenter shows the system
    /// request once per code signature; after that, System Settings.
    func requestScreenRecording() {
        ScreenRegionCapture.requestPermission(from: "Screen Region") { [weak self] _ in self?.refreshPermission() }
    }

    func openScreenRecordingSettings() {
        ScreenRegionCapture.openScreenRecordingSettings(from: "Screen Region")
        refreshPermission()
    }

    /// Screen Recording applies after a restart.
    func relaunchForScreenRecording() {
        ScreenRegionCapture.relaunch(from: "Screen Region")
    }

    // MARK: Selection

    /// Shows the selection overlay on every display.
    func beginSelection(mode: ScreenRegionOverlayState.Mode = .region) {
        guard phase != .selecting, phase != .capturing, textGrab.phase == .idle,
              !ScreenRegionOverlayController.isAnyActive else { return }
        refreshPermission()
        guard hasScreenRecording else {
            if screenRecordingNeedsRelaunch {
                fail("Restart SparkV so Screen Recording takes effect")
            } else {
                fail("Allow Screen Recording to ask about the screen")
            }
            return
        }
        lastError = nil
        let front = NSWorkspace.shared.frontmostApplication
        // From the panel's "Select again" we are in front: keep returning to
        // the app the first selection was made over.
        let previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? panel.returnApp : front
        onWillBeginSelection?()
        if panel.isOpen { panel.close(reactivating: false) }
        phase = .selecting
        NSApp.activate()
        overlay.begin(mode: mode) { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.phase = self.panel.isOpen ? .showing : .idle
                if let previousApp, !previousApp.isTerminated { previousApp.activate() }
                return
            }
            self.capture(selection, appName: previousApp?.localizedName, previousApp: previousApp)
        }
    }

    private func capture(_ selection: ScreenRegionSelection, appName: String?, previousApp: NSRunningApplication?) {
        phase = .capturing
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: 8) {
            ScreenRegionBandView(systemImage: "viewfinder", text: "Capturing selection…", busy: true)
        })
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            // Let the overlay leave the screen's compositor first.
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled else { return }
            do {
                let image = try await ScreenRegionCapture.capture(selection)
                let url = try ScreenRegionFiles.writePNG(image)
                let title: String?
                var app = appName
                switch selection {
                case .window(_, _, _, let windowApp, let windowTitle):
                    title = windowTitle
                    app = windowApp ?? appName
                case .region(let rect, _):
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    let under = ScreenRegionGeometry.window(at: center, in: ScreenRegionCapture.onScreenWindows())
                    title = under?.title
                    app = under?.appName ?? appName
                }
                guard !Task.isCancelled else {
                    ScreenRegionFiles.remove(url)
                    return
                }
                let result = ScreenRegionCaptureResult(image: image, fileURL: url, selection: selection, appName: app, windowTitle: title)
                self.present(result, previousApp: previousApp)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .idle
                self.fail(ScreenRegionAssistant.message(for: error))
                if let previousApp, !previousApp.isTerminated { previousApp.activate() }
            }
        }
    }

    private func present(_ capture: ScreenRegionCaptureResult, previousApp: NSRunningApplication?) {
        discardSession()
        let session = ScreenRegionSession(capture: capture, assistant: assistant)
        self.session = session
        session.prepare()
        activities.dismiss(id: Self.activityID)
        phase = .showing
        panel.show(session, controller: self, previousApp: previousApp)
    }

    /// Shows the last selection's panel again (drawer "Reopen").
    func reopen() {
        guard let session, phase == .idle, FileManager.default.fileExists(atPath: session.capture.fileURL.path) else { return }
        cleanupTask?.cancel()
        phase = .showing
        let front = NSWorkspace.shared.frontmostApplication
        let previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        panel.show(session, controller: self, previousApp: previous)
    }

    func closePanel() {
        panel.close()
    }

    /// Test seam: makes `session` the last selection without opening the panel.
    func adopt(_ session: ScreenRegionSession) {
        discardSession()
        self.session = session
    }

    private func panelClosed() {
        session?.cancel()
        if phase == .showing { phase = .idle }
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: Self.keepLastCapture)
            guard let self, !Task.isCancelled, self.phase == .idle else { return }
            self.discardSession()
        }
    }

    private func discardSession() {
        cleanupTask?.cancel()
        cleanupTask = nil
        if let session {
            session.cancel()
            assistant.forget(session.capture.fileURL)
            ScreenRegionFiles.remove(session.capture.fileURL)
        }
        session = nil
    }

    // MARK: Hand-offs

    func saveToTray(_ session: ScreenRegionSession) {
        let providers = session.trayProviders()
        guard !providers.isEmpty else { return }
        onSaveToTray?(providers)
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: 2) {
            ScreenRegionBandView(systemImage: "tray.and.arrow.down", text: "Saved to Tray", busy: false)
        })
    }

    /// Tray AI gets its own copy (swept on the next start), since ours is
    /// deleted when the selection is discarded.
    func openInTrayAI(_ session: ScreenRegionSession) {
        guard let onOpenInTrayAI, let url = try? ScreenRegionFiles.writePNG(session.capture.image, name: "tray-ai-\(UUID().uuidString)") else { return }
        panel.close()
        onOpenInTrayAI([ScreenRegionAssistant.trayItem(for: url)])
    }

    // MARK: Errors

    private func fail(_ message: String) {
        lastError = message
        AppLog.log("Screen Region: \(message)")
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 65, duration: 3.5) {
            ScreenRegionBandView(systemImage: "exclamationmark.triangle", text: message, busy: false)
        })
    }
}

// MARK: - Band under the notch

struct ScreenRegionBandView: View {
    let systemImage: String
    let text: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(LabsTint.feature)
            }
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(SparkVTheme.text)
        .tint(SparkVTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Drawer tab content
//
// Three tools in a row (Ask about screen, Copy Text, and the recorder's tile
// when it is wired in), a status line underneath. Fits the 508×69 content of
// the 115 pt drawer and grows into 508×114 if the tab is made tall.

/// One large button on the Screen tab; the screen recorder's tile uses it too.
struct ScreenToolTile<Trailing: View>: View {
    let systemImage: String
    let title: String
    /// Used when `title` doesn't fit (e.g. "Record" for "Record screen").
    var shortTitle: String?
    let detail: String
    var tint: Color = SparkVTheme.text
    /// Filled with `tint` (e.g. while recording).
    var isActive = false
    var help: String = ""
    let action: () -> Void
    let trailing: Trailing

    init(systemImage: String, title: String, shortTitle: String? = nil, detail: String, tint: Color = SparkVTheme.text, isActive: Bool = false,
         help: String = "", action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.systemImage = systemImage
        self.title = title
        self.shortTitle = shortTitle
        self.detail = detail
        self.tint = tint
        self.isActive = isActive
        self.help = help
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        ViewThatFits(in: .horizontal) {
                            Text(title)
                            Text(shortTitle ?? title)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(isActive ? Color.white.opacity(0.85) : SparkVTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            trailing
        }
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .fill(isActive ? AnyShapeStyle(SparkVTheme.accent) : AnyShapeStyle(SparkVTheme.surface))
        )
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(isActive ? Color.white.opacity(0.18) : SparkVTheme.stroke))
        .foregroundStyle(isActive ? Color.white : SparkVTheme.text)
    }
}

extension ScreenToolTile where Trailing == EmptyView {
    init(systemImage: String, title: String, shortTitle: String? = nil, detail: String, tint: Color = SparkVTheme.text, isActive: Bool = false,
         help: String = "", action: @escaping () -> Void) {
        self.init(systemImage: systemImage, title: title, shortTitle: shortTitle, detail: detail, tint: tint, isActive: isActive,
                  help: help, action: action) { EmptyView() }
    }
}

/// Small chevron menu for a tile's options.
struct ScreenToolTileMenu<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 18, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(SparkVTheme.textSecondary)
        .fixedSize()
        .padding(.trailing, 3)
    }
}

struct ScreenRegionDrawerView: View {
    @ObservedObject var controller: ScreenRegionController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ScreenToolTile(
                    systemImage: "text.viewfinder", title: "Ask about screen", shortTitle: "Ask screen",
                    detail: controller.shortcut.displayString,
                    help: "Select a region of the screen (\(controller.shortcut.displayString)); Space picks a window",
                    action: { controller.beginSelection() }
                ) {
                    ScreenToolTileMenu {
                        Button("Select a Region…") { controller.beginSelection() }
                        Button("Pick a Window…") { controller.beginSelection(mode: .window) }
                        Divider()
                        Toggle("Allow Groq Vision (uses Clicky's key)", isOn: $controller.allowGroq)
                    }
                }
                ScreenTextGrabTile(textGrab: controller.textGrab)
                if let accessory = controller.drawerAccessory {
                    accessory()
                }
            }
            .frame(maxHeight: .infinity)
            ScreenRegionDrawerStatusRow(controller: controller, textGrab: controller.textGrab)
                .frame(height: 18)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(SparkVTheme.text)
        .environment(\.colorScheme, .dark)
        .tint(SparkVTheme.accent)
        .onAppear { controller.refreshPermission() }
    }
}

private struct ScreenTextGrabTile: View {
    @ObservedObject var textGrab: ScreenTextGrabController
    @ObservedObject var settings: ScreenTextGrabSettings

    init(textGrab: ScreenTextGrabController) {
        self.textGrab = textGrab
        self.settings = textGrab.settings
    }

    var body: some View {
        ScreenToolTile(
            systemImage: "doc.text.viewfinder", title: "Copy text",
            detail: textGrab.phase == .reading ? "Reading…" : settings.shortcut.displayString,
            help: "Select any text on screen and copy it (\(settings.shortcut.displayString))",
            action: { textGrab.begin() }
        ) {
            ScreenToolTileMenu {
                Button("Copy Text from a Window…") { textGrab.begin(mode: .window) }
                Divider()
                Toggle("Keep Line Breaks", isOn: $settings.keepLineBreaks)
                Toggle("Read QR Codes and Barcodes", isOn: $settings.detectCodes)
                Toggle("Add to Clipboard Instead of Replacing", isOn: $settings.appendToClipboard)
            }
        }
    }
}

private struct ScreenRegionDrawerStatusRow: View {
    @ObservedObject var controller: ScreenRegionController
    @ObservedObject var textGrab: ScreenTextGrabController

    var body: some View {
        HStack(spacing: 8) {
            if !controller.hasScreenRecording, controller.screenRecordingNeedsRelaunch {
                Image(systemName: "arrow.clockwise.circle").font(.system(size: 10, weight: .semibold))
                Text("Turned on Screen Recording? Restart SparkV to use it").font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 0)
                Button("Restart") { controller.relaunchForScreenRecording() }.controlSize(.mini)
                Button("Settings") { controller.openScreenRecordingSettings() }.controlSize(.mini)
            } else if !controller.hasScreenRecording {
                Image(systemName: "lock.shield").font(.system(size: 10, weight: .semibold))
                Text("Screen Recording is off for SparkV").font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 0)
                Button("Allow…") { controller.requestScreenRecording() }.controlSize(.mini)
                Button("Settings") { controller.openScreenRecordingSettings() }.controlSize(.mini)
            } else if let outcome = textGrab.lastOutcome, outcome.kind != .nothing {
                Image(systemName: "doc.on.clipboard").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(SparkVTheme.success)
                Text(outcome.title).font(.system(size: 10.5, weight: .semibold))
                Text(outcome.copied.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary).truncationMode(.tail)
                Spacer(minLength: 0)
                sessionButton
            } else if let session = controller.session {
                ScreenRegionLastSessionRow(session: session, controller: controller)
            } else {
                Text("Drag over anything on screen  ·  Space picks a window  ·  Esc cancels")
                    .font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var sessionButton: some View {
        if controller.session != nil, controller.phase == .idle {
            Button("Reopen Answer") { controller.reopen() }.controlSize(.mini)
        }
    }
}

private struct ScreenRegionLastSessionRow: View {
    @ObservedObject var session: ScreenRegionSession
    @ObservedObject var controller: ScreenRegionController

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: session.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 17)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(session.lastAction?.title ?? session.subtitle)
                .font(.system(size: 10.5, weight: .semibold))
            Text(session.text.isEmpty ? (session.status ?? "No answer yet") : session.text)
                .font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
            Spacer(minLength: 0)
            if controller.phase == .idle {
                Button("Reopen") { controller.reopen() }.controlSize(.mini)
            }
        }
    }
}
