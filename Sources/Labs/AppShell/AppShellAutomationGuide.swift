import AppKit
import SwiftUI

/// The sparkv:// reference inside the app: every command with Copy and
/// Try buttons, how to use it from Shortcuts and Terminal, and the switch.
@MainActor
final class AutomationGuideWindowController: NSObject, NSWindowDelegate {
    static let shared = AutomationGuideWindowController()
    private var window: NSWindow?

    func show() {
        let window = window ?? make()
        self.window = window
        AppShellWindowStyle.present(window, centerIfNew: true)
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: AutomationGuideRootView().followsAppearance())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Automation Guide"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        AppShellWindowStyle.apply(to: window)
        window.setContentSize(NSSize(width: 700, height: 640))
        window.contentMinSize = NSSize(width: 600, height: 420)
        window.setFrameAutosaveName("SparkV.AutomationGuide")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        AppShellWindowStyle.didClose(window)
    }
}

struct AutomationGuideRootView: View {
    @ObservedObject private var router = AutomationRouter.shared

    var body: some View {
        AutomationGuideView(isEnabled: $router.isEnabled)
            .background(SparkVSettingsGround())
            .environment(\.colorScheme, .dark)
    }
}

struct AutomationGuideView: View {
    @Binding var isEnabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                howTo
                ForEach(AutomationCatalog.groups, id: \.title) { group in
                    groupView(group)
                }
                Text("Links can never start the camera, the microphone, a recording, dictation, a shortcut or a script. Text from links is shortened and cleaned, and too many requests in a row are ignored.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(SparkVTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Control SparkV with links")
                    .font(SparkVTheme.title(20))
                    .foregroundStyle(SparkVTheme.text)
                Text("Shortcuts, scripts and other apps can open sparkv:// links to open the drawer, start a timer or show their own live activity on the island.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Allow links to change things in SparkV", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.top, 4)
                Text(isEnabled ? "On: every command below works." : "Off: only the Windows links work. Try buttons always work.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Shortcuts", "Add the “Open URLs” action and paste a link.", symbol: "square.stack.3d.up.fill")
            label("Terminal or scripts", "Run open -g with the link: -g keeps your current app in front.", symbol: "terminal.fill")
            AppShellCopyRow(text: "open -g \"sparkv://timer/start?minutes=25\"")
                .padding(.leading, 30)
        }
        .padding(16)
        .background(card)
    }

    private func label(_ title: String, _ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(Self.styled(title, text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupView(_ group: AutomationGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                if !group.alwaysAllowed {
                    Text(isEnabled ? "Allowed" : "Needs Automation on")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isEnabled ? SparkVTheme.success : SparkVTheme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SparkVTheme.surface))
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.url) { index, item in
                    if index > 0 { Rectangle().fill(SparkVTheme.stroke).frame(height: 1).padding(.leading, 14) }
                    AutomationGuideRow(item: item)
                }
            }
            .background(card)
        }
    }

    /// Bold title, then the explanation, in one wrapping line.
    private static func styled(_ title: String, _ text: String) -> AttributedString {
        var head = AttributedString(title + "  ")
        head.font = .system(size: 12.5, weight: .semibold)
        head.foregroundColor = SparkVTheme.text
        var tail = AttributedString(text)
        tail.font = .system(size: 12.5)
        tail.foregroundColor = SparkVTheme.textSecondary
        return head + tail
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
            .fill(SparkVTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
    }
}

private struct AutomationGuideRow: View {
    let item: AutomationExample

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                Text(item.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SparkVTheme.accent)
                    .textSelection(.enabled)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            .controlSize(.small)
            .accessibilityLabel("Copy \(item.title) link")
            Button("Try") {
                if let url = URL(string: item.url), case .success(let command) = AutomationURL.parse(url) {
                    AutomationRouter.shared.run(command)
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Try \(item.title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
