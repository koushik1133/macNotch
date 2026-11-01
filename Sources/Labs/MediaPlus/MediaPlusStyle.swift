import AppKit
import SwiftUI

// Shared look for the Media package's settings sections, hub tiles and
// small windows. Colors come from SparkVTheme, motion from SparkVMotion.

// MARK: - Settings section

/// A settings block: icon, headline and one-line summary, then native
/// controls. About 440 pt wide; the Settings window stacks them.
struct MPSettingsSection<Accessory: View, Content: View>: View {
    let title: String
    let summary: String
    let systemImage: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SparkVTheme.choose(apple: SparkVTheme.accent, sparkv: SparkVTheme.red))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SparkVTheme.choose(apple: SparkVTheme.accent.opacity(0.16), sparkv: SparkVTheme.redSoft))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SparkVTheme.headline(13))
                        .tracking(-0.2)
                        .foregroundStyle(SparkVTheme.text)
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                accessory()
            }
            content()
                .font(.system(size: 12))
                .foregroundStyle(SparkVTheme.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .fill(SparkVTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .strokeBorder(SparkVTheme.stroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension MPSettingsSection where Accessory == EmptyView {
    init(title: String, summary: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, summary: summary, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}

/// A switch in a section header, labelled for VoiceOver.
struct MPHeaderSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(SparkVTheme.accent)
            .accessibilityLabel(label)
    }
}

/// Small explanatory text under a control.
struct MPNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(SparkVTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "What leaves your Mac" line for features that use the network.
struct MPPrivacyNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.warning.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Privacy: \(text)")
    }
}

/// A status dot and line ("Ready", "Needs permission").
struct MPStatusLine: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A label + trailing control row.
struct MPRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(SparkVTheme.text)
            Spacer(minLength: 8)
            control()
        }
    }
}

// MARK: - App icons

enum MPAppIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(bundleID: String?, path: String? = nil) -> NSImage? {
        let key = path ?? bundleID ?? ""
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached }
        let resolvedPath = path ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        guard let resolvedPath else { return nil }
        let image = NSWorkspace.shared.icon(forFile: resolvedPath)
        if cache.count >= 64 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

// MARK: - Hub tile

/// A tile in the Agents hub, matching `AgentTile`: glyph over a 9 pt label
/// on `LabsBHubTileBackground`; lit while its feature is on.
struct MPHubTileFace: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isActive = false
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LabsBHubTileBackground.glyph(isActive: isActive, isHovered: isHovered, tint: tint))
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LabsBHubTileBackground.label(isActive: isActive, isHovered: isHovered))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(LabsBHubTileBackground(isActive: isActive, isHovered: isHovered, tint: tint))
        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        .animation(SparkVMotion.hover(), value: isHovered)
    }
}

// MARK: - Windows

/// A small utility window for a Media view (App Volumes, Lyrics). SparkV is
/// an agent app: it becomes a regular app while one is open, like the other
/// settings windows.
@MainActor
final class MPWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let autosave: String
    private let size: NSSize
    private let minSize: NSSize
    private let makeContent: @MainActor () -> AnyView

    init(title: String, autosave: String, size: NSSize, minSize: NSSize, content: @escaping @MainActor () -> AnyView) {
        self.title = title
        self.autosave = autosave
        self.size = size
        self.minSize = minSize
        makeContent = content
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: makeContent())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName(autosave)
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - On-screen tracking

/// Reports whether a view is really on screen: in the hierarchy (appear /
/// disappear) *and* in a visible window. SwiftUI keeps a view "appeared"
/// while its window is closed but kept around (`isReleasedWhenClosed =
/// false`, the Settings window), so onDisappear alone would leave lyrics
/// lookups and mixer listeners running after the window closes.
///
/// The callback gets balanced true/false pairs (never two trues in a row),
/// so counters stay right; a view torn down while counted reports false.
struct MPOnScreenReporter: View {
    let report: @MainActor (Bool) -> Void
    @StateObject private var tracker = MPOnScreenTracker()

    var body: some View {
        MPWindowVisibilityProbe { tracker.setWindowVisible($0) }
            .frame(width: 0, height: 0)
            .onAppear { tracker.attach(report); tracker.setAppeared(true) }
            .onDisappear { tracker.setAppeared(false) }
            .accessibilityHidden(true)
    }
}

extension View {
    /// `report(true)` while this view is on screen, `report(false)` after.
    func mpReportsOnScreen(_ report: @escaping @MainActor (Bool) -> Void) -> some View {
        background(MPOnScreenReporter(report: report))
    }
}

@MainActor
final class MPOnScreenTracker: ObservableObject {
    private var report: (@MainActor (Bool) -> Void)?
    /// Pure state (MediaPlusLogic): reports changes only.
    private var gate = OnScreenGate()

    func attach(_ report: @escaping @MainActor (Bool) -> Void) { self.report = report }

    func setAppeared(_ value: Bool) {
        if let change = gate.setAppeared(value) { report?(change) }
    }

    func setWindowVisible(_ value: Bool) {
        if let change = gate.setWindowVisible(value) { report?(change) }
    }

    deinit {
        // Torn down while counted (rare: SwiftUI normally sends onDisappear).
        guard gate.reported, let report else { return }
        Task { @MainActor in report(false) }
    }
}

/// Watches the hosting window: closed, ordered out, miniaturized or fully
/// covered counts as not visible.
struct MPWindowVisibilityProbe: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.stopObserving()
    }

    final class ProbeView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private weak var observed: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observed else { return }
            stopObserving()
            observed = window
            guard let window else { return }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            for name in names {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.publish(closing: closing) }
                })
            }
            publish(closing: false)
        }

        private func publish(closing: Bool) {
            guard let window = observed else { return }
            let visible = !closing && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
            onChange?(visible)
        }

        func stopObserving() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
            observed = nil
        }
    }
}
