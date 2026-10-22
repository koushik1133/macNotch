import AppKit
import SwiftUI

/// Items for the gear menu's "Quick Capture" submenu.
struct QuickCaptureMenuItems: View {
    @ObservedObject var capture: QuickCaptureController
    @ObservedObject var settings: QuickCaptureSettings
    @ObservedObject var screenshots: ScreenshotClipboardController

    init(capture: QuickCaptureController, screenshots: ScreenshotClipboardController) {
        self.capture = capture
        self.settings = capture.settings
        self.screenshots = screenshots
    }

    var body: some View {
        Button("Capture to Spaces Now  \(settings.shortcut.displayString)") { capture.captureNow() }
            .disabled(capture.isBusy)
        if let record = capture.lastRecord {
            Button("Undo Last Capture (\(record.kind.label))") { capture.undo() }
        }
        Toggle("Quick Capture Hotkey", isOn: $settings.isEnabled)
        Toggle("Copy New Screenshots to Clipboard", isOn: Binding(
            get: { screenshots.isEnabled },
            set: { screenshots.setEnabled($0) }
        ))
        if screenshots.needsConsent {
            Button("Watch \(screenshots.folder.lastPathComponent) for Screenshots") { screenshots.allowWatching() }
        }
        Divider()
        Button("Quick Capture Settings…") {
            QuickCaptureSettingsWindow.shared.show(capture: capture, screenshots: screenshots)
        }
    }
}

/// Full settings for quick capture and screenshot-to-clipboard.
struct QuickCaptureSettingsView: View {
    @ObservedObject var capture: QuickCaptureController
    @ObservedObject var settings: QuickCaptureSettings
    @ObservedObject var screenshots: ScreenshotClipboardController

    static let size = CGSize(width: 460, height: 600)

    init(capture: QuickCaptureController, screenshots: ScreenshotClipboardController) {
        self.capture = capture
        self.settings = capture.settings
        self.screenshots = screenshots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            QuickCaptureSection(title: "Quick Capture to Spaces", symbol: "square.and.arrow.down.on.square") {
                QuickCaptureSwitchRow("Capture with a global shortcut", isOn: $settings.isEnabled)
                HStack {
                    Text("Shortcut")
                    Spacer()
                    QuickCaptureShortcutRecorder(shortcut: settings.shortcut,
                                                 onRecordingChange: { capture.setHotkeySuspended($0) },
                                                 onRecord: { capture.setShortcut($0) })
                        .disabled(!settings.isEnabled)
                }
                if let problem = capture.hotkeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.warning)
                }
                Divider()
                Text("Captures the first of these that applies")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                QuickCaptureSwitchRow("Selected text in the front app", isOn: $settings.capturesSelection)
                QuickCaptureSwitchRow("Add the browser page as the source", isOn: $settings.selectionIncludesPage)
                    .padding(.leading, 18)
                    .disabled(!settings.capturesSelection)
                QuickCaptureSwitchRow("The page open in Safari, Chrome, Arc, Edge or Brave", isOn: $settings.capturesWebPage)
                QuickCaptureSwitchRow("Otherwise, an interactive screenshot", isOn: $settings.capturesScreenshot)
                Divider()
                Picker("When no Space fits", selection: $settings.fallback) {
                    ForEach(QuickCaptureFallback.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.capturesSelection, !QuickCaptureSelectionReader.isTrusted {
                    permissionRow("Reading selections needs Accessibility for SparkV.")
                }
            }
            QuickCaptureSection(title: "Screenshot to Clipboard", symbol: "doc.on.clipboard") {
                QuickCaptureSwitchRow("Copy every new screenshot to the clipboard", isOn: Binding(
                    get: { screenshots.isEnabled },
                    set: { screenshots.setEnabled($0) }
                ))
                QuickCaptureSwitchRow("Show “Copied screenshot” under the notch", isOn: $screenshots.showsBand)
                    .disabled(!screenshots.isEnabled)
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(SparkVTheme.textSecondary)
                    Text(Self.displayPath(screenshots.folder))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    statusLabel
                }
                if screenshots.needsConsent {
                    Button("Watch \(screenshots.folder.lastPathComponent) for Screenshots") { screenshots.allowWatching() }
                        .buttonStyle(SparkVPrimaryButtonStyle())
                }
                Text("The file stays where macOS saves it. SparkV doesn’t change your screenshot settings; set the folder in the Screenshot app’s Options menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .foregroundStyle(SparkVTheme.text)
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(SparkVTheme.accent)
        .background { AppearanceWindowBackground() }
        .background(alignment: .topTrailing) {
            SparkVTheme.glow.frame(width: 320, height: 220).allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { screenshots.refreshLocation() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(SparkVTheme.red)
            VStack(alignment: .leading, spacing: 2) {
                // SparkV Red: the sparkv.si eyebrow. Apple: just the title, as in System Settings.
                if !SparkVTheme.isApple {
                    HStack(spacing: 6) {
                        Rectangle().fill(SparkVTheme.eyebrowDash).frame(width: 12, height: 1.5)
                        Text("SPARKV / CAPTURE")
                            .font(SparkVTheme.eyebrow())
                            .tracking(1.2)
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                }
                Text("Quick Capture").font(SparkVTheme.title(18)).tracking(SparkVTheme.isApple ? -0.2 : -0.4)
                Text("Press \(settings.shortcut.displayString) to save a selection, page or screenshot straight into the right Space.")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !screenshots.isEnabled {
            Text("Off").font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary)
        } else if screenshots.isWatching {
            Label("Watching", systemImage: "circle.fill")
                .labelStyle(QuickCaptureDotLabelStyle(color: SparkVTheme.success))
        } else {
            Label("Waiting", systemImage: "circle.fill")
                .labelStyle(QuickCaptureDotLabelStyle(color: SparkVTheme.warning))
        }
    }

    private func permissionRow(_ text: String) -> some View {
        HStack {
            Label(text, systemImage: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.warning)
            Spacer()
            Button("Allow…") {
                // The macOS prompt once per signature, then the Accessibility pane.
                Task { await PermissionCenter.shared.request(.accessibility, from: "Quick Capture") }
            }
            .buttonStyle(SparkVPrimaryButtonStyle())
        }
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Label on the left, switch on the right (System Settings layout).
private struct QuickCaptureSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(isEnabled ? SparkVTheme.text : SparkVTheme.textTertiary)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden()
        }
    }
}

private struct QuickCaptureDotLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title.font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary)
        }
    }
}

private struct QuickCaptureSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.red)
                Text(title)
                    .font(SparkVTheme.headline(12))
                    .tracking(-0.1)
                    .foregroundStyle(SparkVTheme.text)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
        }
    }
}

// MARK: - Shortcut recorder

@MainActor
final class QuickCaptureRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var message: String?
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?

    func begin(onRecord: @escaping (ScreenRegionShortcut) -> Bool) {
        end()
        isRecording = true
        message = "Type a shortcut"
        // Closing the window mid-recording must not leave a key monitor
        // behind (it would swallow keystrokes in other SparkV windows).
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.end()
                return nil
            }
            let shortcut = ScreenRegionShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
            guard shortcut.isValidGlobal else {
                self.message = "Use ⌃, ⌥ or ⌘"
                return nil
            }
            self.end()
            let ok = onRecord(shortcut)
            self.message = ok ? nil : "Taken by another app"
            return nil
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        isRecording = false
        message = nil
    }
}

/// Click, then press the new combination (Esc cancels).
struct QuickCaptureShortcutRecorder: View {
    let shortcut: ScreenRegionShortcut
    var onRecordingChange: (Bool) -> Void = { _ in }
    let onRecord: (ScreenRegionShortcut) -> Bool
    @StateObject private var model = QuickCaptureRecorderModel()

    var body: some View {
        HStack(spacing: 6) {
            if let message = model.message, !model.isRecording {
                Text(message).font(.system(size: 10)).foregroundStyle(SparkVTheme.warning)
            }
            Button {
                if model.isRecording { model.end() } else { model.begin(onRecord: onRecord) }
            } label: {
                Text(model.isRecording ? (model.message ?? "Type a shortcut") : shortcut.displayString)
                    .font(.system(size: 12, weight: .medium, design: model.isRecording ? .default : .rounded))
                    .frame(minWidth: 96)
            }
            .help("Click, then press the new shortcut. Esc cancels.")
            if shortcut != QuickCaptureSettings.defaultShortcut, !model.isRecording {
                Button {
                    _ = onRecord(QuickCaptureSettings.defaultShortcut)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(QuickCaptureSettings.defaultShortcut.displayString)")
            }
        }
        .onChange(of: model.isRecording) { _, recording in onRecordingChange(recording) }
        .onDisappear {
            // onChange doesn't fire once the view is gone: resume the hotkey here.
            let wasRecording = model.isRecording
            model.end()
            if wasRecording { onRecordingChange(false) }
        }
    }
}

// MARK: - Window

@MainActor
final class QuickCaptureSettingsWindow: NSObject, NSWindowDelegate {
    static let shared = QuickCaptureSettingsWindow()
    private var window: NSWindow?
    private weak var capture: QuickCaptureController?

    func show(capture: QuickCaptureController, screenshots: ScreenshotClipboardController) {
        self.capture = capture
        if window == nil {
            let host = NSHostingView(rootView: QuickCaptureSettingsView(capture: capture, screenshots: screenshots).followsAppearance())
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: QuickCaptureSettingsView.size),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "SparkV Quick Capture"
            window.appearance = NSAppearance(named: .darkAqua)
            LabsWindowGround.follow(window)
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // A recorder left listening must not keep the global hotkey off.
        capture?.setHotkeySuspended(false)
    }
}
