import AppKit
import SwiftUI

// MARK: - Rules (pure)

/// Which apps and sites count as distractions. Like Raycast Focus and
/// Session, a match doesn't kill anything: a calm overlay asks whether to go
/// back to work, with a snooze for when the user really needs the app.
enum FocusBlockRules {
    /// "https://www.YouTube.com/watch?v=1" → "youtube.com"; "*.reddit.com" → "reddit.com".
    static func normalizeSite(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if !text.contains("://") { text = "https://" + text }
        guard let host = URL(string: text)?.host?.lowercased(), host.contains(".") else { return nil }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedSites(_ sites: [String]) -> [String] {
        var seen = Set<String>()
        return sites.compactMap(normalizeSite).filter { seen.insert($0).inserted }
    }

    /// The blocked domain `url` falls under ("m.youtube.com" matches "youtube.com").
    static func matchingSite(_ url: URL, sites: [String]) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return sites.first { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isBlocked(bundleID: String?, apps: [FocusBlockedApp]) -> FocusBlockedApp? {
        guard let bundleID else { return nil }
        return apps.first { $0.bundleID == bundleID }
    }

    /// Suggestions for the settings list (only shown if installed).
    static let suggestedApps: [FocusBlockedApp] = [
        FocusBlockedApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
        FocusBlockedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        FocusBlockedApp(bundleID: "com.hnc.Discord", name: "Discord"),
        FocusBlockedApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        FocusBlockedApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram"),
        FocusBlockedApp(bundleID: "com.apple.news", name: "News"),
        FocusBlockedApp(bundleID: "com.apple.TV", name: "TV"),
        FocusBlockedApp(bundleID: "com.spotify.client", name: "Spotify"),
        FocusBlockedApp(bundleID: "com.apple.Music", name: "Music"),
        FocusBlockedApp(bundleID: "com.apple.mail", name: "Mail"),
    ]

    static let suggestedSites = ["youtube.com", "x.com", "reddit.com", "instagram.com", "facebook.com", "news.ycombinator.com", "tiktok.com", "netflix.com"]
}

// MARK: - Live guard

/// Watches the frontmost app (and, for blocked sites, the front browser tab
/// through Apple Events, only when Automation was already allowed) and shows
/// `FocusOverlayController` on a match.
@MainActor
final class FocusDistractionGuard {
    struct Hit: Equatable {
        var key: String
        var title: String
        var bundleID: String
        var isSite: Bool
    }

    var apps: [FocusBlockedApp] = []
    var sites: [String] = []
    var snoozeMinutes = 5
    /// Overlay events go to the controller.
    var onHit: ((Hit) -> Void)?

    private var snoozedUntil: [String: Date] = [:]
    private var browserPoll: Task<Void, Never>?
    /// Looks at the front app again when a snooze runs out, so a snoozed app
    /// that is still in front gets the reminder again (like Raycast Focus).
    private var snoozeRecheck: Task<Void, Never>?
    private(set) var isActive = false
    /// Last non-blocked app the user worked in, to return to.
    private(set) var lastWorkApp: NSRunningApplication?
    /// Browsers whose Automation permission was denied or not answered.
    private(set) var browsersNeedingPermission: Set<String> = []
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "SparkV"

    static let browserPollInterval: Duration = .seconds(2)

    func activate() {
        isActive = true
        if let app = NSWorkspace.shared.frontmostApplication { frontmostChanged(app) }
    }

    func deactivate() {
        isActive = false
        browserPoll?.cancel()
        browserPoll = nil
        snoozeRecheck?.cancel()
        snoozeRecheck = nil
    }

    func snooze(_ key: String, at now: Date = Date()) {
        let length = TimeInterval(snoozeMinutes * 60)
        snoozedUntil[key] = now.addingTimeInterval(length)
        snoozeRecheck?.cancel()
        snoozeRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 1))
            guard !Task.isCancelled, let self, self.isActive,
                  let app = NSWorkspace.shared.frontmostApplication else { return }
            self.frontmostChanged(app)
        }
    }

    func isSnoozed(_ key: String, at now: Date = Date()) -> Bool {
        (snoozedUntil[key] ?? .distantPast) > now
    }

    func resetSnoozes() {
        snoozedUntil.removeAll()
        snoozeRecheck?.cancel()
        snoozeRecheck = nil
    }

    func frontmostChanged(_ app: NSRunningApplication) {
        guard isActive else { return }
        let bundleID = app.bundleIdentifier
        browserPoll?.cancel()
        browserPoll = nil
        if bundleID == ownBundleID { return }
        if let blocked = FocusBlockRules.isBlocked(bundleID: bundleID, apps: apps) {
            let key = "app:" + blocked.bundleID
            if !isSnoozed(key) {
                onHit?(Hit(key: key, title: app.localizedName ?? blocked.name, bundleID: blocked.bundleID, isSite: false))
            }
            return
        }
        if let bundleID, let browser = SpaceConnectors.Browser.all.first(where: { $0.bundleID == bundleID }) {
            if !sites.isEmpty { watchBrowser(browser, app: app) }
            return
        }
        lastWorkApp = app
    }

    private func watchBrowser(_ browser: SpaceConnectors.Browser, app: NSRunningApplication) {
        browserPoll = Task { [weak self] in
            // Never prompts: a site check that would need consent is skipped
            // until the user allows it from Focus settings.
            let status = await SpaceAppleEvents.shared.permission(bundleID: browser.bundleID, askUser: false)
            guard status == noErr else {
                self?.browsersNeedingPermission.insert(browser.bundleID)
                return
            }
            self?.browsersNeedingPermission.remove(browser.bundleID)
            while !Task.isCancelled {
                guard let self, self.isActive,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.bundleID else { return }
                if case .success(let output) = await SpaceAppleEvents.shared.run(browser.tabScript, timeout: 4),
                   case .tab(let tab) = SpaceConnectors.parseBrowserOutput(output, browser: browser.name),
                   let site = FocusBlockRules.matchingSite(tab.url, sites: self.sites) {
                    let key = "site:" + site
                    if !Task.isCancelled, !self.isSnoozed(key) {
                        self.onHit?(Hit(key: key, title: site, bundleID: browser.bundleID, isSite: true))
                    }
                }
                try? await Task.sleep(for: Self.browserPollInterval)
            }
        }
    }

    /// Asks for Automation permission for every running supported browser
    /// (call from a button: it can show the system prompt). PermissionCenter
    /// shows the prompts one after another and opens Settings › Automation
    /// (once) for browsers that were already denied.
    static func requestBrowserPermissions() async -> [String: Bool] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var result: [String: Bool] = [:]
        for browser in SpaceConnectors.Browser.all where running.contains(browser.bundleID) {
            let status = await SpaceAppleEvents.shared.permission(bundleID: browser.bundleID, askUser: true, from: "Focus")
            result[browser.name] = status == noErr
        }
        return result
    }
}

// MARK: - Overlay

/// A dimmed, blurred full-screen panel with one card: "Back to work",
/// "N more minutes" or "End Focus". Sits just under the notch panel and over
/// full-screen apps, and never takes keyboard focus.
@MainActor
final class FocusOverlayController {
    private var panel: NSPanel?
    private(set) var currentKey: String?
    /// Bumped on every show, so a fade-out that ends after a newer show
    /// doesn't order the new overlay out.
    private var generation = 0

    var isVisible: Bool { panel?.isVisible == true }

    func show(model: FocusOverlayModel, actions: FocusOverlayView.Actions) {
        currentKey = model.key
        generation &+= 1
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        let host = NSHostingView(rootView: FocusOverlayView(model: model, actions: actions).followsAppearance())
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        currentKey = nil
        guard let panel, panel.isVisible else { return }
        let shownGeneration = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.generation == shownGeneration else { return }
                panel.orderOut(nil)
                // Free the hosting view (and the closures it holds) until the next show.
                panel.contentView = nil
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Below the notch panel (.statusBar) so the band stays visible.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

struct FocusOverlayModel: Equatable {
    var key: String
    var target: String
    var isSite: Bool
    var timeLeft: String
    var snoozeMinutes: Int
}

struct FocusOverlayView: View {
    struct Actions {
        var backToWork: () -> Void
        var snooze: () -> Void
        var endFocus: () -> Void
    }

    let model: FocusOverlayModel
    let actions: Actions

    var body: some View {
        ZStack {
            FocusBlurBackground()
                .ignoresSafeArea()
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            card
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(FocusPalette.accent)
                .frame(width: 60, height: 60)
                .background(Circle().fill(LabsBStyle.activeCardFill(FocusPalette.accent)))
                .overlay(Circle().strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.red.opacity(0.35)))
                .padding(.bottom, 2)
            LabsBEyebrow("SparkV / Focus")
            Text("You’re focusing")
                .font(SparkVTheme.title(24))
                .tracking(-0.6)
                .foregroundStyle(SparkVTheme.text)
            Text("\(model.target) is on your distraction list. \(model.timeLeft) left in this round.")
                .font(.system(size: 13))
                .foregroundStyle(SparkVTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            VStack(spacing: 8) {
                Button(action: actions.backToWork) {
                    Text("Back to Work")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(FocusPalette.accent))
                        .foregroundStyle(Color.white)
                        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    Button(action: actions.snooze) {
                        Text("\(model.snoozeMinutes) More Minutes")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
                            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
                            .foregroundStyle(SparkVTheme.text)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(action: actions.endFocus) {
                        Text("End Focus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
                            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
                            .foregroundStyle(SparkVTheme.text)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 280)
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .background(
            ZStack {
                SparkVTheme.background.opacity(0.96)
                SparkVTheme.glow
            }
            .clipShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous)
                .strokeBorder(SparkVTheme.stroke)
        )
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
    }
}

/// Behind-window blur for the overlay.
struct FocusBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
