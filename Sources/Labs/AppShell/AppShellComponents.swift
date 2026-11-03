import AppKit
import SwiftUI

/// SparkV's mark: the app icon when the bundle has one, otherwise a drawn
/// squircle with the island and a red spark (the logo stays red in both looks).
struct SparkVAppMark: View {
    var size: CGFloat = 56

    private static var bundleIcon: NSImage? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil else { return nil }
        return NSApp.applicationIconImage
    }

    var body: some View {
        Group {
            if let icon = Self.bundleIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                drawn
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("SparkV")
    }

    /// The mark as an image (alerts, the About panel).
    @MainActor
    static func image(size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: SparkVAppMark(size: size).padding(size * 0.06))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    private var drawn: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        return ZStack(alignment: .top) {
            shape.fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(Color.white.opacity(0.14), lineWidth: max(0.5, size / 112))
            Capsule()
                .fill(Color.black)
                .frame(width: size * 0.5, height: size * 0.15)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .padding(.top, size * 0.13)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(SparkVTheme.brandRed)
                .shadow(color: SparkVTheme.brandRed.opacity(0.55), radius: size * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, size * 0.16)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: size * 0.05, y: size * 0.02)
    }
}

/// Icon + text status (never color alone).
struct AppShellStatusLabel: View {
    enum Tone { case good, warning, neutral, accent, bad }
    let text: String
    let symbol: String
    var tone: Tone = .neutral

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(SparkVTheme.textSecondary)
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
        case .accent: SparkVTheme.accent
        case .bad: SparkVTheme.destructive
        }
    }
}

/// A command or link in monospace with a Copy button that confirms itself.
struct AppShellCopyRow: View {
    let text: String
    var caption: String? = nil
    @StateObject private var copied = ViewFlag()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(SparkVTheme.text)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied.isOn = true
                Task { @MainActor [copied] in
                    try? await Task.sleep(for: .seconds(1.4))
                    copied.isOn = false
                }
            } label: {
                Label(copied.isOn ? "Copied" : "Copy", systemImage: copied.isOn ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 64)
                    .contentTransition(.opacity)
            }
            .controlSize(.small)
            .accessibilityLabel(copied.isOn ? "Copied" : "Copy \(caption ?? text)")
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: copied.isOn)
    }
}

/// Puts an AppKit window on the look's ground and keeps it there when the
/// look changes.
@MainActor
enum AppShellWindowStyle {
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func apply(to window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(SparkVTheme.windowBackground)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed
        let key = ObjectIdentifier(window)
        guard observers[key] == nil else { return }
        observers[key] = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated { window?.backgroundColor = NSColor(SparkVTheme.windowBackground) }
        }
    }

    /// Opens a shell window in front, the way Settings does.
    static func present(_ window: NSWindow, centerIfNew: Bool) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if centerIfNew, !window.isVisible, let screen = NSScreen.main {
            let area = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.06))
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// From `windowWillClose`: back to a Dock-less agent when nothing else is open.
    static func didClose(_ window: NSWindow?) {
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
