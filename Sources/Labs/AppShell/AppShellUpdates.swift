import AppKit
import Combine
import SwiftUI

/// "Check for Updates…": asks GitHub's Releases API of
/// koushik1133/macNotch for the newest release, compares versions and shows
/// the release notes with a button to the download page. Nothing is
/// downloaded or installed by SparkV.
///
/// Network use is off until the user turns on automatic checks or clicks
/// Check for Updates. Automatic checks run at most once a day through
/// NSBackgroundActivityScheduler (the system picks an idle, efficient
/// moment; no timer polls), and stop when the switch is off.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(latest: String?)
        case available(GitHubRelease)
        case failed(String)
    }

    private enum Keys {
        static let automatic = "AppShell.updates.automatic"
        static let betas = "AppShell.updates.betas"
        static let lastCheck = "AppShell.updates.lastCheck"
        static let skipped = "AppShell.updates.skippedVersion"
        static let notified = "AppShell.updates.notifiedVersion"
    }

    @Published private(set) var phase: Phase = .idle
    /// A newer release found by any check (not skipped).
    @Published private(set) var availableRelease: GitHubRelease?
    @Published private(set) var lastCheck: Date?

    /// Off by default: SparkV contacts GitHub only after this is turned on.
    @Published var automaticChecks: Bool {
        didSet {
            guard automaticChecks != oldValue else { return }
            UserDefaults.standard.set(automaticChecks, forKey: Keys.automatic)
            AppLog.log("Updates: automatic checks \(automaticChecks ? "on" : "off")")
            reschedule()
            if automaticChecks, UpdatePolicy.isDue(lastCheck: lastCheck, now: Date()) { check(userInitiated: false) }
        }
    }

    @Published var includeBetas: Bool {
        didSet {
            guard includeBetas != oldValue else { return }
            UserDefaults.standard.set(includeBetas, forKey: Keys.betas)
            // A beta found earlier no longer counts on the stable channel.
            if !includeBetas, availableRelease?.prerelease == true || availableRelease?.version?.isPrerelease == true {
                availableRelease = nil
                if case .available = phase { phase = .idle }
            }
        }
    }

    var isChecking: Bool { phase == .checking }

    var skippedVersion: String? { UserDefaults.standard.string(forKey: Keys.skipped) }

    /// Gear menu / status item title.
    var menuTitle: String {
        if let release = availableRelease { return "Update Available: SparkV \(release.displayVersion)…" }
        return isChecking ? "Checking for Updates…" : "Check for Updates…"
    }

    private var scheduler: NSBackgroundActivityScheduler?
    /// One retry after an automatic check failed (offline, GitHub busy),
    /// about 90 minutes later instead of the next day.
    private var retryScheduler: NSBackgroundActivityScheduler?
    private var task: Task<Void, Never>?
    private var launchCheck: Task<Void, Never>?
    private var started = false

    private init() {
        let defaults = UserDefaults.standard
        automaticChecks = defaults.bool(forKey: Keys.automatic)
        includeBetas = defaults.bool(forKey: Keys.betas)
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    func start() {
        guard !started else { return }
        started = true
        reschedule()
        // A check that is due runs a little after launch, never during it.
        if automaticChecks, UpdatePolicy.isDue(lastCheck: lastCheck, now: Date()) {
            launchCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                self?.check(userInitiated: false)
            }
        }
    }

    func stop() {
        started = false
        scheduler?.invalidate()
        scheduler = nil
        retryScheduler?.invalidate()
        retryScheduler = nil
        launchCheck?.cancel()
        launchCheck = nil
        task?.cancel()
        task = nil
    }

    /// The menu item and the Settings button. With a release already
    /// found, shows it; otherwise checks and shows the result.
    func checkNow(userInitiated: Bool) {
        if userInitiated { UpdateWindowController.shared.show() }
        if userInitiated, let availableRelease, phase != .checking {
            phase = .available(availableRelease)
            return
        }
        check(userInitiated: userInitiated)
    }

    /// `sparkv://updates/check`: shows Software Update without contacting
    /// GitHub. A link may come from any web page, so the request goes out
    /// only when the user clicks Check Now (or one was already found).
    func showWindowWithoutChecking() {
        if let availableRelease, phase != .checking {
            phase = .available(availableRelease)
        } else if phase != .checking {
            phase = .idle
        }
        UpdateWindowController.shared.show()
    }

    func skip(_ release: GitHubRelease) {
        UserDefaults.standard.set(release.version?.description ?? release.tagName, forKey: Keys.skipped)
        availableRelease = nil
        phase = .idle
        AppLog.log("Updates: skipping \(release.displayVersion)")
        UpdateWindowController.shared.close()
    }

    func openDownloadPage(_ release: GitHubRelease) {
        NSWorkspace.shared.open(release.htmlUrl)
        UpdateWindowController.shared.close()
    }

    // MARK: Checking

    private func reschedule() {
        scheduler?.invalidate()
        scheduler = nil
        retryScheduler?.invalidate()
        retryScheduler = nil
        guard automaticChecks, started else { return }
        let activity = NSBackgroundActivityScheduler(identifier: "com.sparkv.app.update-check")
        activity.repeats = true
        activity.interval = UpdatePolicy.checkInterval
        activity.tolerance = 4 * 60 * 60
        activity.qualityOfService = .utility
        activity.schedule { completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let controller = UpdateController.shared
                    if controller.automaticChecks, UpdatePolicy.isDue(lastCheck: controller.lastCheck, now: Date(), interval: UpdatePolicy.checkInterval - 3600) {
                        controller.check(userInitiated: false)
                    }
                }
                completion(.finished)
            }
        }
        scheduler = activity
    }

    private func check(userInitiated: Bool) {
        guard task == nil else { return }
        phase = .checking
        let current = SparkVAppInfo.version
        let betas = includeBetas
        let skipped = userInitiated ? nil : skippedVersion
        AppLog.log("Updates: checking GitHub releases (\(userInitiated ? "by the user" : "automatic"))")
        task = Task { [weak self] in
            let result = await Self.fetchReleases()
            guard let self else { return }
            self.task = nil
            switch result {
            case .failure(let error):
                // lastCheck stays: a failed check is retried soon, not tomorrow.
                self.phase = .failed(error.message)
                AppLog.log("Updates: check failed: \(error.message)")
                if !userInitiated { self.scheduleRetry() }
            case .success(let releases):
                self.lastCheck = Date()
                UserDefaults.standard.set(self.lastCheck, forKey: Keys.lastCheck)
                self.retryScheduler?.invalidate()
                self.retryScheduler = nil
                switch UpdatePolicy.decide(current: current, releases: releases, includePrereleases: betas, skippedVersion: skipped) {
                case .available(let release):
                    self.availableRelease = release
                    self.phase = .available(release)
                    AppLog.log("Updates: \(release.displayVersion) is available")
                    if !userInitiated { self.remindGently(release) }
                case .skipped(let release):
                    self.phase = .upToDate(latest: release.displayVersion)
                case .upToDate(let latest):
                    self.availableRelease = nil
                    self.phase = .upToDate(latest: latest)
                    AppLog.log("Updates: up to date (newest \(latest ?? "none"))")
                }
            }
        }
    }

    /// One system-timed retry (no timer) after an automatic check failed.
    private func scheduleRetry() {
        guard automaticChecks, started, retryScheduler == nil else { return }
        let retry = NSBackgroundActivityScheduler(identifier: "com.sparkv.app.update-retry")
        retry.repeats = false
        retry.interval = UpdatePolicy.retryAfterFailure
        retry.tolerance = 30 * 60
        retry.qualityOfService = .utility
        retry.schedule { completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let controller = UpdateController.shared
                    controller.retryScheduler = nil
                    if controller.automaticChecks, controller.started { controller.check(userInitiated: false) }
                }
                completion(.finished)
            }
        }
        retryScheduler = retry
        AppLog.log("Updates: will retry in about \(Int(UpdatePolicy.retryAfterFailure / 60)) min")
    }

    /// A Dock-less app never pops a window for an automatic check: a short
    /// band on the island (once per version; its Show button opens the
    /// update) and a mark in the menus. The version counts as announced
    /// only once the band was actually posted.
    private func remindGently(_ release: GitHubRelease) {
        let version = release.version?.description ?? release.tagName
        guard UserDefaults.standard.string(forKey: Keys.notified) != version else { return }
        let posted = AppShellController.shared.post(LiveActivity(
            id: "appshell.update", kind: .notification, priority: 30, duration: 9,
            symbol: "arrow.down.circle.fill", tint: SparkVTheme.accent, compactText: release.displayVersion
        ) {
            UpdateBandView(version: release.displayVersion) {
                UpdateController.shared.checkNow(userInitiated: true)
            }
        }
        .interactive()
        .titled("SparkV \(release.displayVersion) available"))
        if posted { UserDefaults.standard.set(version, forKey: Keys.notified) }
    }

    /// GitHub's REST API, without cookies or caches. Sends only the request
    /// (no identifiers): the app name and version in the User-Agent, which
    /// GitHub requires.
    nonisolated private static func fetchReleases() async -> Result<[GitHubRelease], UpdateCheckError> {
        var request = URLRequest(url: UpdatePolicy.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("SparkV/\(version) (macOS)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                do { return .success(try UpdatePolicy.decodeReleases(data)) } catch {
                    return .failure(UpdateCheckError("GitHub sent a reply SparkV couldn’t read."))
                }
            case 403, 429: return .failure(UpdateCheckError("GitHub is limiting checks right now. Try again in an hour."))
            case 404: return .failure(UpdateCheckError("SparkV’s release page isn’t available."))
            default: return .failure(UpdateCheckError("GitHub answered with error \(status)."))
            }
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            return .failure(UpdateCheckError("You’re offline. Connect to the internet and try again."))
        } catch let error as URLError where error.code == .timedOut {
            return .failure(UpdateCheckError("GitHub didn’t answer in time. Try again later."))
        } catch {
            return .failure(UpdateCheckError(error.localizedDescription))
        }
    }
}

struct UpdateCheckError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The island band for an available update.
struct UpdateBandView: View {
    let version: String
    /// Shows the update (release notes, download page).
    var show: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.accent)
                .accessibilityHidden(true)
            Text("SparkV \(version) is available")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Button("Show", action: show)
                .buttonStyle(SparkVBandButtonStyle())
                .accessibilityLabel("Show the SparkV \(version) update")
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
    }
}

/// A compact pill button for island bands.
struct SparkVBandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.14)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !SparkVMotion.reduceMotion ? SparkVMotion.pressedScale : 1)
            .animation(
                SparkVMotion.easeOut(configuration.isPressed ? SparkVMotion.Duration.press : SparkVMotion.Duration.release),
                value: configuration.isPressed
            )
    }
}

// MARK: - Update window

@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateWindowController()
    private var window: NSWindow?
    private var phaseObserver: AnyCancellable?

    /// Release notes need room; the other states are a short card.
    static func contentHeight(for phase: UpdateController.Phase) -> CGFloat {
        if case .available = phase { return 470 }
        return 310
    }

    func show() {
        let window = window ?? make()
        self.window = window
        fit(UpdateController.shared.phase, animate: false)
        phaseObserver = UpdateController.shared.$phase.removeDuplicates().sink { [weak self] phase in
            DispatchQueue.main.async { self?.fit(phase, animate: true) }
        }
        AppShellWindowStyle.present(window, centerIfNew: true)
    }

    /// Grows or shrinks from the top edge (AppKit's short resize; none
    /// under Reduce Motion).
    private func fit(_ phase: UpdateController.Phase, animate: Bool) {
        guard let window else { return }
        let height = Self.contentHeight(for: phase)
        var frame = window.frame
        let delta = height - window.contentRect(forFrameRect: frame).height
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: animate && window.isVisible && !SparkVMotion.reduceMotion)
    }

    func close() { window?.performClose(nil) }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: UpdateRootView().followsAppearance())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        AppShellWindowStyle.apply(to: window)
        window.setContentSize(NSSize(width: 560, height: 470))
        window.setFrameAutosaveName("SparkV.SoftwareUpdate")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        phaseObserver = nil
        AppShellWindowStyle.didClose(window)
    }
}

struct UpdateRootView: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        UpdateContentView(phase: updates.phase, includeBetas: updates.includeBetas)
            .background(SparkVSettingsGround())
            .environment(\.colorScheme, .dark)
    }
}

/// The window's content for one phase (separate so it renders with sample data).
struct UpdateContentView: View {
    let phase: UpdateController.Phase
    var includeBetas = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 16)
            Group {
                if case .available(let release) = phase {
                    ReleaseNotesView(release: release)
                } else {
                    statusBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 520, minHeight: 280)
        .tint(SparkVTheme.accent)
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: phaseKey)
    }

    private var phaseKey: String {
        switch phase {
        case .idle: "idle"
        case .checking: "checking"
        case .upToDate: "upToDate"
        case .available(let r): "available-" + r.tagName
        case .failed: "failed"
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            SparkVAppMark(size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SparkVTheme.title(19))
                    .foregroundStyle(SparkVTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch phase {
        case .idle: "Check for SparkV Updates"
        case .checking: "Checking for Updates…"
        case .upToDate: "SparkV Is Up to Date"
        case .available(let release): "SparkV \(release.displayVersion) Is Available"
        case .failed: "Couldn’t Check for Updates"
        }
    }

    private var subtitle: String {
        let mine = "You have SparkV \(SparkVAppInfo.versionText)."
        switch phase {
        case .idle: return "\(mine) Click Check Now to ask GitHub for the newest release."
        case .checking: return "Asking GitHub for the newest release."
        case .upToDate(let latest):
            if let latest { return "\(mine) \(latest) is the newest \(includeBetas ? "release or beta" : "release")." }
            return "\(mine) No newer release has been published."
        case .available(let release):
            let date = release.publishedAt.map { " Released \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
            return mine + date + (release.prerelease ? " This is a beta." : "")
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var statusBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .idle:
                AppShellStatusLabel(text: "Nothing has been sent yet.", symbol: "lock.fill", tone: .neutral)
            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Contacting api.github.com…")
                        .font(.system(size: 12))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            case .upToDate:
                AppShellStatusLabel(text: "Nothing to install.", symbol: "checkmark.seal.fill", tone: .good)
            case .failed:
                AppShellStatusLabel(text: "Your settings and data are unchanged.", symbol: "exclamationmark.triangle.fill", tone: .warning)
            case .available:
                EmptyView()
            }
            privacyNote
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
    }

    private var privacyNote: some View {
        Text("SparkV asks GitHub’s public Releases API. It sends nothing about you or this Mac, and downloads nothing by itself.")
            .font(.system(size: 11))
            .foregroundStyle(SparkVTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .available(let release):
                Button("Skip This Version") { UpdateController.shared.skip(release) }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Spacer()
                Button("Remind Me Later") { UpdateWindowController.shared.close() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Open Download Page") { UpdateController.shared.openDownloadPage(release) }
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Releases on GitHub") { NSWorkspace.shared.open(UpdatePolicy.releasesPage) }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Spacer()
                Button("Close") { UpdateWindowController.shared.close() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { UpdateController.shared.checkNow(userInitiated: true) }
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .idle:
                Spacer()
                Button("Close") { UpdateWindowController.shared.close() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Check Now") { UpdateController.shared.checkNow(userInitiated: true) }
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            default:
                Spacer()
                Button("OK") { UpdateWindowController.shared.close() }
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .checking)
            }
        }
    }
}

/// Release notes drawn natively from GitHub Markdown, plus the Homebrew hint.
struct ReleaseNotesView: View {
    let release: GitHubRelease

    var body: some View {
        let blocks = ReleaseNotes.parse(release.body ?? "")
        VStack(alignment: .leading, spacing: 10) {
            Text("Release Notes")
                .font(SparkVTheme.eyebrow())
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(SparkVTheme.textTertiary)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if blocks.isEmpty {
                        Text("This release has no notes. The download page lists what changed.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
            if SparkVAppInfo.isHomebrewInstall {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(SparkVTheme.textSecondary)
                    Text("Installed with Homebrew:").font(.system(size: 11.5)).foregroundStyle(SparkVTheme.textSecondary)
                    AppShellCopyRow(text: SparkVAppInfo.brewUpgradeCommand)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesBlock) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(inline(text))
                .font(.system(size: level <= 2 ? 14 : 12.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 12.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(depth == 0 ? "•" : "◦")
                    .foregroundStyle(SparkVTheme.accent)
                Text(inline(text))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12.5))
            .padding(.leading, CGFloat(depth) * 14)
        case .rule:
            Rectangle().fill(SparkVTheme.stroke).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
