import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreBluetooth
import CoreGraphics
import CryptoKit
import EventKit
import ScreenCaptureKit
import Security
import Speech
import UserNotifications

/// The one place SparkV checks and asks for macOS privacy permissions.
///
/// Rules every feature gets for free:
/// - `status(_:)` / `isGranted(_:)` never prompt. Statuses are cached and
///   refreshed when SparkV or another app activates and when the
///   `com.apple.accessibility.api` distributed notification arrives.
/// - `request(_:from:)` shows a system prompt at most once per permission
///   per app session, only while the status is "not asked yet", and never
///   in the first seconds after launch unless onboarding is running.
///   Prompts are queued so only one system prompt is visible at a time
///   (for the Accessibility / Screen Recording alerts, which return before
///   they're answered, the queue stays closed until the alert went away).
///   Concurrent requests for the same permission share one prompt.
/// - ~/Downloads, whose first read is the prompt, is never read for a
///   status before SparkV asked for it through the queue.
/// - Denied or restricted permissions open the exact System Settings pane
///   instead (macOS ignores a second request once the user said no).
/// - Accessibility and Screen Recording cannot report "never asked", so
///   SparkV remembers whether it already asked with this code signature;
///   `CGRequestScreenCaptureAccess` and the Accessibility prompt run at most
///   once per signature, after that the Settings pane opens.
/// - A Screen Recording grant only applies after SparkV restarts:
///   `screenRecordingNeedsRelaunch` turns on and `relaunch()` restarts.
/// - `shareableContent(from:)` caches ScreenCaptureKit's window list for a
///   few seconds and refuses to run without the grant, so ScreenCaptureKit
///   never prompts on its own and macOS 15's recurring "bypass the private
///   window picker" confirmation is triggered as rarely as possible.
/// - Every prompt, Settings redirect and ScreenCaptureKit use is logged with
///   the feature that caused it.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter(system: SystemPermissionSystem(), defaults: .standard, observesSystem: true)

    // MARK: Types

    enum Permission: Hashable, Sendable, CustomStringConvertible {
        case accessibility
        case screenRecording
        case camera
        case microphone
        case speech
        case calendars
        case reminders
        /// System Audio Recording (process taps, macOS 14.4+).
        case systemAudio
        case notifications
        case bluetooth
        /// Apple Events to the app with this bundle id.
        case automation(bundleID: String)
        case downloadsFolder

        /// Stable key for persistence and logs.
        var key: String {
            switch self {
            case .accessibility: "accessibility"
            case .screenRecording: "screenRecording"
            case .camera: "camera"
            case .microphone: "microphone"
            case .speech: "speech"
            case .calendars: "calendars"
            case .reminders: "reminders"
            case .systemAudio: "systemAudio"
            case .notifications: "notifications"
            case .bluetooth: "bluetooth"
            case .automation(let bundleID): "automation." + bundleID
            case .downloadsFolder: "downloadsFolder"
            }
        }

        var description: String { key }

        /// Status can be read synchronously and cheaply (no prompt).
        var hasQuickStatus: Bool {
            switch self {
            case .notifications, .automation, .downloadsFolder: false
            default: true
            }
        }

        /// macOS reports "not allowed" without telling "never asked" from
        /// "switched off"; SparkV keeps its own record of asking.
        var reportsNotDetermined: Bool { self != .accessibility && self != .screenRecording }

        /// Grants that only apply after SparkV restarts.
        var needsRelaunchAfterGrant: Bool { self == .screenRecording }

        /// The system call returns as soon as the alert is up, not once it
        /// was answered (Accessibility, Screen Recording): the prompt queue
        /// stays closed until the alert likely went away.
        var promptReturnsBeforeAnswer: Bool { self == .accessibility || self == .screenRecording }

        /// Reading the status is itself the prompt the first time
        /// (~/Downloads): read only after SparkV asked through the queue.
        var readIsPrompt: Bool { self == .downloadsFolder }

        /// SparkV keeps its own "asked under this signature" record.
        var tracksPromptPerSignature: Bool { !reportsNotDetermined || readIsPrompt }

        /// The System Settings pane holding the switch.
        var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            case .camera: anchor = "Privacy_Camera"
            case .microphone: anchor = "Privacy_Microphone"
            case .speech: anchor = "Privacy_SpeechRecognition"
            case .calendars: anchor = "Privacy_Calendars"
            case .reminders: anchor = "Privacy_Reminders"
            case .systemAudio: anchor = "Privacy_AudioCapture"
            case .bluetooth: anchor = "Privacy_Bluetooth"
            case .automation: anchor = "Privacy_Automation"
            case .downloadsFolder: anchor = "Privacy_FilesAndFolders"
            case .notifications:
                let id = Bundle.main.bundleIdentifier ?? "com.sparkv.app"
                return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }

        /// The permissions every feature may use (automation targets aside).
        static let standard: [Permission] = [
            .accessibility, .screenRecording, .camera, .microphone, .speech,
            .calendars, .reminders, .notifications, .bluetooth, .downloadsFolder,
        ]
    }

    enum Status: String, Sendable, Equatable {
        case granted
        case denied
        case notDetermined
        /// Parental controls or a configuration profile blocks it.
        case restricted
        /// Calendars: add-only access.
        case limited
        /// Automation: macOS can only answer while the target app runs.
        case appNotRunning
        /// Automation: the target app isn't installed.
        case appNotInstalled
        case unknown

        var isGranted: Bool { self == .granted }
    }

    enum PermissionError: Error, LocalizedError, Equatable {
        case notGranted(Permission)

        var errorDescription: String? {
            switch self {
            case .notGranted(.screenRecording):
                "Allow Screen Recording for SparkV in System Settings › Privacy & Security, then restart SparkV."
            case .notGranted(let permission):
                "SparkV needs \(permission) access."
            }
        }
    }

    // MARK: Published state

    @Published private(set) var statuses: [Permission: Status] = [:]
    /// A Screen Recording request or Settings redirect happened this session
    /// and the grant isn't active yet: offer "Restart SparkV".
    @Published private(set) var screenRecordingNeedsRelaunch = false
    /// Last time a feature read the screen through ScreenCaptureKit.
    @Published private(set) var lastScreenCaptureUse: Date?
    /// Set by onboarding while its window is open: prompts are allowed then
    /// even in the first seconds after launch.
    var isOnboardingActive = false

    /// Shown next to Screen Recording rows and capture errors.
    static let screenCaptureReminderNote = """
    macOS 15 and later periodically asks you to confirm that SparkV may keep \
    capturing the screen ("…requesting to bypass the system private window \
    picker"). That's a macOS privacy reminder, not a lost permission: click \
    Allow and SparkV keeps working. SparkV only reads the screen when you use \
    a capture feature, which keeps these reminders rare.
    """

    // MARK: Tunables

    /// No prompts or Settings redirects this soon after launch (unless
    /// onboarding runs): features starting up must never ask.
    var launchQuietPeriod: TimeInterval = 4
    /// A request (hotkey, capture, button) for a denied permission opens
    /// its Settings pane at most this often; explicit "Open Settings"
    /// buttons (`openSettings`) only skip repeats within 2 seconds.
    var settingsRedirectCooldown: TimeInterval = 30
    /// How long a ScreenCaptureKit window list is reused.
    var shareableContentMaxAge: TimeInterval = 3
    /// Fallback re-check while a feature waits for a grant and no
    /// notification arrived (seconds; deliberately slow). Doubles after
    /// each idle check up to `maxFallbackPollInterval`.
    var fallbackPollInterval: TimeInterval = 10
    var maxFallbackPollInterval: TimeInterval = 60

    /// When SparkV started (the system's launch date).
    var launchDate: Date { system.launchDate }

    /// Seconds left in the launch quiet period (0 when over, or while
    /// onboarding runs). Features that touch protected resources on their
    /// own at launch (folder watchers) wait this long first.
    var launchQuietRemaining: TimeInterval {
        guard !isOnboardingActive else { return 0 }
        return max(0, launchQuietPeriod - Date().timeIntervalSince(system.launchDate))
    }

    var isInLaunchQuietPeriod: Bool { launchQuietRemaining > 0 }

    // MARK: Private state

    private let system: PermissionSystem
    private let defaults: UserDefaults
    private let signature: String
    private var promptedThisSession: Set<Permission> = []
    private var inFlight: [Permission: Task<Status, Never>] = [:]
    private var promptBusy = false
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []
    /// When each Settings pane was last opened (any reason).
    private var settingsOpenedAt: [URL: Date] = [:]
    /// When a request last sent the user to Settings, per permission.
    private var redirectedAt: [Permission: Date] = [:]
    private var lastQuickRefresh = Date.distantPast
    private var lastSlowRefresh = Date.distantPast
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessibilityRecheck: Task<Void, Never>?
    private var watchers: [Permission: Int] = [:]
    private var fallbackPoll: Task<Void, Never>?
    /// Fires after every re-check (app activation, the Accessibility
    /// notification, the fallback poll), changed or not.
    private let rechecked = PassthroughSubject<Void, Never>()
    private var screenRecordingRequestedThisSession = false
    private var contentCache: [String: (box: ShareableContentBox, at: Date)] = [:]
    private var contentInFlight: [String: Task<ShareableContentBox, Error>] = [:]

    /// `system` and `defaults` are test seams; tests pass a fake system and
    /// `observesSystem: false`, so nothing real is checked or prompted.
    init(system: PermissionSystem, defaults: UserDefaults, observesSystem: Bool, signature: String? = nil) {
        self.system = system
        self.defaults = defaults
        self.signature = signature ?? PermissionSignature.current
        var initial: [Permission: Status] = [:]
        for permission in Permission.standard where permission.hasQuickStatus {
            initial[permission] = resolve(permission, raw: system.quickStatus(permission))
        }
        statuses = initial
        rememberGrants(initial)
        if observesSystem { startObserving() }
    }

    // MARK: Reading (never prompts)

    /// Cached status; never prompts. Quick permissions not cached yet are
    /// read now; slow ones (notifications, automation, Downloads) return the
    /// cached value or `.unknown` and refresh in the background.
    func status(_ permission: Permission) -> Status {
        if let cached = statuses[permission] { return cached }
        if permission.hasQuickStatus {
            let fresh = resolve(permission, raw: system.quickStatus(permission))
            publishLater(permission, fresh)
            return fresh
        }
        Task { _ = await self.freshStatus(permission) }
        return .unknown
    }

    /// Live check for the cheap permissions (Accessibility, Screen Recording,
    /// capture devices…), cached value for the others. Never prompts. Use
    /// it in place of `AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()`.
    func isGranted(_ permission: Permission) -> Bool {
        guard permission.hasQuickStatus else { return status(permission).isGranted }
        let fresh = resolve(permission, raw: system.quickStatus(permission))
        if statuses[permission] != fresh { publishLater(permission, fresh) }
        return fresh.isGranted
    }

    /// Live status for the cheap permissions (cached value for the slow
    /// ones, like `status(_:)`). Never prompts.
    func liveStatus(_ permission: Permission) -> Status {
        guard permission.hasQuickStatus else { return status(permission) }
        let fresh = resolve(permission, raw: system.quickStatus(permission))
        if statuses[permission] != fresh { publishLater(permission, fresh) }
        return fresh
    }

    /// Accessibility trust for code running off the main actor (AX reads on
    /// a background thread). Same check as `isGranted(.accessibility)`;
    /// never prompts.
    nonisolated static var isAccessibilityTrustedNow: Bool { AXIsProcessTrusted() }

    /// Whether SparkV already showed (or can no longer show) the system
    /// prompt for `permission`: false only while it may still be asked.
    func hasAsked(_ permission: Permission) -> Bool {
        if promptedThisSession.contains(permission) { return true }
        if permission.tracksPromptPerSignature, defaults.bool(forKey: Keys.prompted(permission, signature)) { return true }
        let current = statuses[permission] ?? (permission.hasQuickStatus ? liveStatus(permission) : .unknown)
        return current != .notDetermined && current != .unknown && current != .limited
    }

    /// Reads the current status from macOS (async for the slow ones) and
    /// updates the cache. Never prompts: ~/Downloads, whose first read is
    /// the prompt, reports "not asked yet" until SparkV asked for it.
    @discardableResult
    func freshStatus(_ permission: Permission) async -> Status {
        if permission.readIsPrompt, !defaults.bool(forKey: Keys.prompted(permission, signature)) {
            store(permission, .notDetermined)
            return .notDetermined
        }
        let raw = permission.hasQuickStatus ? system.quickStatus(permission) : await system.slowStatus(permission)
        let status = resolve(permission, raw: raw)
        store(permission, status)
        return status
    }

    /// For features that touch a resource themselves and so caused (or
    /// passed) the system prompt outside the queue, e.g. reading
    /// ~/Downloads: SparkV may read its status from now on.
    func recordAsked(_ permission: Permission) {
        guard permission.tracksPromptPerSignature else { return }
        defaults.set(true, forKey: Keys.prompted(permission, signature))
    }

    /// After SparkV's entry was removed from Privacy & Security (the
    /// onboarding "remove old entry" fix runs `tccutil reset`): forget that
    /// SparkV asked, so the next `request` shows the prompt once more and
    /// macOS adds the current build to the list.
    func forgetPrompt(_ permission: Permission) {
        promptedThisSession.remove(permission)
        defaults.removeObject(forKey: Keys.prompted(permission, signature))
        AppLog.log("Permissions: forgot that \(permission) was asked (entry reset)")
        if permission.hasQuickStatus { store(permission, resolve(permission, raw: system.quickStatus(permission))) }
    }

    /// Re-reads every cached permission. Never prompts.
    func refreshAll() async {
        refreshQuick(force: true)
        await refreshSlow(force: true)
    }

    /// Calls `handler` whenever the status of `permission` changes (not for
    /// the current value). Keep the returned token.
    ///
    /// - `poll`: while not granted, re-check now and then in case no
    ///   notification arrives (slow, backing off to a minute). Defaults to
    ///   Accessibility only; everything else is re-read when any app
    ///   activates, which covers coming back from System Settings.
    /// - `includeRechecks`: also call `handler` after every re-check with
    ///   the unchanged status (e.g. to retry an event tap that failed to
    ///   install although Accessibility is on). The handler must be cheap
    ///   and idempotent.
    func onChange(
        of permission: Permission,
        poll: Bool? = nil,
        includeRechecks: Bool = false,
        _ handler: @escaping @MainActor (Status) -> Void
    ) -> AnyCancellable {
        let changes = $statuses
            .map { $0[permission] ?? .unknown }
            .removeDuplicates()
            .dropFirst()
            .eraseToAnyPublisher()
        let source: AnyPublisher<Status, Never>
        if includeRechecks {
            let again = rechecked
                .compactMap { [weak self] in self?.statuses[permission] }
                .eraseToAnyPublisher()
            source = changes.merge(with: again).eraseToAnyPublisher()
        } else {
            source = changes
        }
        let inner = source.sink { status in MainActor.assumeIsolated { handler(status) } }
        let polls = poll ?? (permission == .accessibility)
        guard polls else { return AnyCancellable { inner.cancel() } }
        watchers[permission, default: 0] += 1
        updateFallbackPoll()
        return AnyCancellable { [weak self] in
            inner.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchers[permission, default: 1] -= 1
                if self.watchers[permission] ?? 0 <= 0 { self.watchers[permission] = nil }
                self.updateFallbackPoll()
            }
        }
    }

    /// Runs `handler` each time `permission` becomes granted, e.g. to
    /// re-create event taps or global monitors installed before the grant.
    func whenGranted(_ permission: Permission, poll: Bool? = nil, _ handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        onChange(of: permission, poll: poll) { status in
            if status.isGranted { handler() }
        }
    }

    /// Number of subscriptions that keep the fallback poll alive (tests).
    var pollingWatcherCount: Int { watchers.values.reduce(0, +) }
    var isFallbackPolling: Bool { fallbackPoll != nil }

    /// True when SparkV saw this permission granted under a different code
    /// signature or app location: the switch in Settings likely points at
    /// an old build and has to be removed and re-added.
    func isLikelyStaleGrant(_ permission: Permission) -> Bool {
        guard !status(permission).isGranted,
              let last = defaults.string(forKey: Keys.lastGranted(permission)) else { return false }
        return last != signature
    }

    // MARK: Requesting

    /// For call sites: true when granted, asking first when allowed (see
    /// `request`). Call from a user action.
    func ensure(_ permission: Permission, from feature: String) async -> Bool {
        if permission.hasQuickStatus, isGranted(permission) { return true }
        return await request(permission, from: feature).isGranted
    }

    /// Asks for `permission` on behalf of `feature`. Shows the system prompt
    /// only when macOS hasn't asked yet, at most once per session, one prompt
    /// at a time; when denied or restricted, opens the System Settings pane.
    /// Call only from a user action.
    ///
    /// `openingSettings: false` never opens System Settings: a denied (or
    /// already asked) permission just returns its status, for callers that
    /// show their own message instead (timers, background starts).
    @discardableResult
    func request(_ permission: Permission, from feature: String, openingSettings: Bool = true) async -> Status {
        if let running = inFlight[permission] { return await running.value }
        let task = Task { await self.performRequest(permission, feature: feature, openingSettings: openingSettings) }
        inFlight[permission] = task
        let result = await task.value
        inFlight[permission] = nil
        return result
    }

    /// Opens the Settings pane for `permission` (deduplicated: a second call
    /// within two seconds for the same pane does nothing).
    func openSettings(_ permission: Permission, from feature: String) {
        let url = permission.settingsURL
        let now = Date()
        if let last = settingsOpenedAt[url], now.timeIntervalSince(last) < 2 { return }
        settingsOpenedAt[url] = now
        AppLog.log("Permissions: opening Settings for \(permission) (\(feature))")
        system.openSettings(url)
        if permission == .screenRecording { screenRecordingNeedsRelaunch = !isGranted(.screenRecording) }
    }

    /// Settings on behalf of a request (not a Settings button): once per
    /// `settingsRedirectCooldown` per permission, so a repeated hotkey or
    /// several features hitting the same denied permission don't keep
    /// bringing Settings to the front.
    private func redirectToSettings(_ permission: Permission, from feature: String) {
        let now = Date()
        if let last = redirectedAt[permission], now.timeIntervalSince(last) < settingsRedirectCooldown {
            AppLog.log("Permissions: \(permission) is off; Settings was opened \(Int(now.timeIntervalSince(last))) s ago, not again (\(feature))")
            return
        }
        redirectedAt[permission] = now
        openSettings(permission, from: feature)
    }

    /// Restarts SparkV so a fresh Screen Recording grant applies.
    func relaunch(from feature: String) {
        AppLog.log("Permissions: relaunching for Screen Recording (\(feature))")
        system.relaunch()
    }

    // MARK: ScreenCaptureKit

    /// ScreenCaptureKit's displays/windows, reused for `shareableContentMaxAge`
    /// seconds and shared between concurrent callers. Throws
    /// `PermissionError.notGranted(.screenRecording)` without touching
    /// ScreenCaptureKit when the grant is missing, so it never prompts.
    func shareableContent(
        from feature: String,
        excludingDesktopWindows: Bool = false,
        onScreenWindowsOnly: Bool = true,
        maxAge: TimeInterval? = nil
    ) async throws -> SCShareableContent {
        guard isGranted(.screenRecording) else {
            AppLog.log("Permissions: \(feature) needs Screen Recording; not calling ScreenCaptureKit")
            throw PermissionError.notGranted(.screenRecording)
        }
        let key = "\(excludingDesktopWindows)-\(onScreenWindowsOnly)"
        let age = maxAge ?? shareableContentMaxAge
        if let cached = contentCache[key], Date().timeIntervalSince(cached.at) < age {
            return cached.box.content
        }
        if let running = contentInFlight[key] { return try await running.value.content }
        AppLog.log("Permissions: ScreenCaptureKit window list for \(feature)")
        lastScreenCaptureUse = Date()
        let task = Task.detached(priority: .userInitiated) { () throws -> ShareableContentBox in
            let content = try await SCShareableContent.excludingDesktopWindows(
                excludingDesktopWindows, onScreenWindowsOnly: onScreenWindowsOnly
            )
            return ShareableContentBox(content)
        }
        contentInFlight[key] = task
        defer { contentInFlight[key] = nil }
        do {
            let box = try await task.value
            contentCache[key] = (box, Date())
            return box.content
        } catch {
            if Self.isCaptureDenial(error) {
                AppLog.log("Permissions: ScreenCaptureKit declined for \(feature)")
                store(.screenRecording, resolve(.screenRecording, raw: system.quickStatus(.screenRecording)))
            }
            throw error
        }
    }

    /// Forgets the cached window list (e.g. after a window was closed).
    func invalidateShareableContent() {
        contentCache.removeAll()
    }

    /// Records a ScreenCaptureKit use that bypasses `shareableContent`
    /// (a long-running SCStream), for the log and the UI note.
    func noteScreenCaptureUse(from feature: String) {
        AppLog.log("Permissions: ScreenCaptureKit stream for \(feature)")
        lastScreenCaptureUse = Date()
    }

    /// The user declined capture, or the grant is missing.
    nonisolated static func isCaptureDenial(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return false }
        return nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    // MARK: Request flow

    private func performRequest(_ permission: Permission, feature: String, openingSettings: Bool) async -> Status {
        let current = await freshStatus(permission)
        switch current {
        case .granted, .appNotInstalled:
            return current
        case .appNotRunning:
            AppLog.log("Permissions: \(permission) can't be asked while the app isn't running (\(feature))")
            return current
        case .unknown:
            return current
        case .denied, .restricted:
            guard openingSettings, mayInterrupt(permission, feature: feature) else { return current }
            if permission == .screenRecording, screenRecordingNeedsRelaunch {
                // Asked (or sent to Settings) already; the switch only takes
                // effect after a restart, which the caller offers.
                AppLog.log("Permissions: Screen Recording waits for a restart (\(feature))")
                return current
            }
            redirectToSettings(permission, from: feature)
            return current
        case .notDetermined, .limited:
            guard mayInterrupt(permission, feature: feature) else { return current }
            if promptedThisSession.contains(permission) {
                // Already asked this session: macOS won't show it again.
                if openingSettings { redirectToSettings(permission, from: feature) }
                return current
            }
            return await prompt(permission, feature: feature, openingSettings: openingSettings)
        }
    }

    private func prompt(_ permission: Permission, feature: String, openingSettings: Bool) async -> Status {
        await acquirePromptSlot()
        var releaseNow = true
        defer { if releaseNow { releasePromptSlot() } }
        // Another prompt may have been answered while this one waited.
        let before = await freshStatus(permission)
        guard before == .notDetermined || before == .limited else {
            if openingSettings, before == .denied || before == .restricted { redirectToSettings(permission, from: feature) }
            return before
        }
        promptedThisSession.insert(permission)
        if !permission.reportsNotDetermined { defaults.set(true, forKey: Keys.prompted(permission, signature)) }
        if permission == .screenRecording { screenRecordingRequestedThisSession = true }
        AppLog.log("Permissions: showing the \(permission) prompt for \(feature)")
        await system.prompt(permission)
        // The read that was the prompt is done: real reads from now on.
        if permission.readIsPrompt { defaults.set(true, forKey: Keys.prompted(permission, signature)) }
        let after = await freshStatus(permission)
        AppLog.log("Permissions: \(permission) is now \(after.rawValue) (\(feature))")
        if permission == .screenRecording, !after.isGranted { screenRecordingNeedsRelaunch = true }
        if permission == .accessibility, !after.isGranted { scheduleAccessibilityRecheck() }
        if permission.promptReturnsBeforeAnswer, !after.isGranted {
            // The alert is still on screen: keep the queue closed until it
            // goes away so a second system alert never stacks on top.
            releaseNow = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.system.waitForPromptToClose(permission)
                self.releasePromptSlot()
            }
        }
        return after
    }

    private func mayInterrupt(_ permission: Permission, feature: String) -> Bool {
        if isOnboardingActive { return true }
        let sinceLaunch = Date().timeIntervalSince(system.launchDate)
        guard sinceLaunch >= launchQuietPeriod else {
            AppLog.log("Permissions: not asking for \(permission) during launch (\(feature))")
            return false
        }
        return true
    }

    private func acquirePromptSlot() async {
        guard promptBusy else {
            promptBusy = true
            return
        }
        await withCheckedContinuation { promptWaiters.append($0) }
    }

    private func releasePromptSlot() {
        if promptWaiters.isEmpty {
            promptBusy = false
        } else {
            promptWaiters.removeFirst().resume()
        }
    }

    // MARK: Status bookkeeping

    /// Maps the raw system answer, turning "not allowed" into "not asked
    /// yet" for Accessibility / Screen Recording when SparkV never asked
    /// with this signature.
    private func resolve(_ permission: Permission, raw: Status) -> Status {
        guard !permission.reportsNotDetermined, raw == .denied else { return raw }
        return defaults.bool(forKey: Keys.prompted(permission, signature)) ? .denied : .notDetermined
    }

    private func store(_ permission: Permission, _ status: Status) {
        guard statuses[permission] != status else { return }
        let old = statuses[permission]
        statuses[permission] = status
        if status.isGranted {
            rememberGrants([permission: status])
            if permission == .screenRecording { screenRecordingNeedsRelaunch = false }
        }
        if let old, old != .unknown {
            AppLog.log("Permissions: \(permission) changed \(old.rawValue) → \(status.rawValue)")
        }
        if permission == .screenRecording { invalidateShareableContent() }
        updateFallbackPoll()
    }

    /// Publishing during a SwiftUI view update is not allowed; defer it.
    private func publishLater(_ permission: Permission, _ status: Status) {
        Task { @MainActor [weak self] in self?.store(permission, status) }
    }

    private func rememberGrants(_ granted: [Permission: Status]) {
        for (permission, status) in granted where status.isGranted {
            defaults.set(signature, forKey: Keys.lastGranted(permission))
            // Granted under this signature: SparkV is in the list, so a
            // later "off" is a switched-off grant (Settings), not "never asked".
            if permission.tracksPromptPerSignature { defaults.set(true, forKey: Keys.prompted(permission, signature)) }
        }
    }

    // MARK: Observing

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (PermissionCenter) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            }
            observers.append((center, token))
        }
        // Coming back from System Settings (or any app switch): cheap re-read.
        watch(workspace, NSWorkspace.didActivateApplicationNotification) { center in
            center.refreshQuick(force: false)
            Task { await center.refreshSlow(force: false) }
        }
        watch(local, NSApplication.didBecomeActiveNotification) { center in
            center.refreshQuick(force: true)
            Task { await center.refreshSlow(force: false) }
        }
        // Posted when any app's Accessibility switch changes; the trust value
        // lags the notification a little.
        watch(distributed, Notification.Name("com.apple.accessibility.api")) { center in
            center.scheduleAccessibilityRecheck()
        }
    }

    private func scheduleAccessibilityRecheck() {
        accessibilityRecheck?.cancel()
        accessibilityRecheck = Task { [weak self] in
            for delay in [0.3, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                let status = self.resolve(.accessibility, raw: self.system.quickStatus(.accessibility))
                self.store(.accessibility, status)
                self.rechecked.send()
                if status.isGranted { return }
            }
        }
    }

    /// Re-reads the cheap permissions now (as on app activation), e.g. from
    /// tests or after the user said they changed a switch.
    func recheck() {
        refreshQuick(force: true)
    }

    private func refreshQuick(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastQuickRefresh) >= 0.5 else { return }
        lastQuickRefresh = now
        let known = Set(statuses.keys).union(Permission.standard)
        for permission in known where permission.hasQuickStatus {
            store(permission, resolve(permission, raw: system.quickStatus(permission)))
        }
        rechecked.send()
    }

    private func refreshSlow(force: Bool) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastSlowRefresh) >= 5 else { return }
        lastSlowRefresh = now
        // freshStatus never reads ~/Downloads before SparkV asked for it.
        let slow = statuses.keys.filter { !$0.hasQuickStatus }
        for permission in slow where inFlight[permission] == nil {
            _ = await freshStatus(permission)
        }
        if statuses[.notifications] == nil { _ = await freshStatus(.notifications) }
    }

    /// Slow safety net: only while someone subscribed with `poll` waits for
    /// a quick permission that isn't granted (the notifications above
    /// normally cover it). Backs off while nothing changes.
    private func updateFallbackPoll() {
        let waiting = watchers.contains { permission, count in
            count > 0 && permission.hasQuickStatus && statuses[permission]?.isGranted != true
        }
        guard waiting else {
            fallbackPoll?.cancel()
            fallbackPoll = nil
            return
        }
        guard fallbackPoll == nil else { return }
        fallbackPoll = Task { [weak self] in
            var interval = self?.fallbackPollInterval ?? 10
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.refreshQuick(force: true)
                interval = min(interval * 2, max(self.maxFallbackPollInterval, self.fallbackPollInterval))
            }
        }
    }

    private enum Keys {
        static func prompted(_ permission: Permission, _ signature: String) -> String {
            "PermissionCenter.prompted.\(permission.key).\(signature)"
        }
        static func lastGranted(_ permission: Permission) -> String {
            "PermissionCenter.lastGranted.\(permission.key)"
        }
    }
}

// MARK: - System seam

/// Everything that touches real TCC state. Tests use a fake.
@MainActor
protocol PermissionSystem: AnyObject {
    var launchDate: Date { get }
    /// Cheap, synchronous, never prompts. Accessibility and Screen Recording
    /// answer `.granted` or `.denied`.
    func quickStatus(_ permission: PermissionCenter.Permission) -> PermissionCenter.Status
    /// May hop off the main thread; never prompts.
    func slowStatus(_ permission: PermissionCenter.Permission) async -> PermissionCenter.Status
    /// Shows the system prompt and returns once it was answered (or, for
    /// Accessibility / Screen Recording, once the alert is up).
    func prompt(_ permission: PermissionCenter.Permission) async
    /// For prompts that return before they were answered
    /// (`promptReturnsBeforeAnswer`): returns once the alert likely closed.
    func waitForPromptToClose(_ permission: PermissionCenter.Permission) async
    func openSettings(_ url: URL)
    func relaunch()
}

extension PermissionSystem {
    func waitForPromptToClose(_ permission: PermissionCenter.Permission) async {}
}

/// The real macOS implementation (public APIs only).
@MainActor
final class SystemPermissionSystem: PermissionSystem {
    let launchDate = NSRunningApplication.current.launchDate ?? Date()
    /// UNUserNotificationCenter traps outside an app bundle.
    private let canUseNotifications = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    private var bluetoothRequester: PermissionBluetoothRequester?
    nonisolated private static let appleEventsQueue = DispatchQueue(label: "SparkV.Permissions.appleEvents", qos: .userInitiated)
    /// Consent alerts block their thread: separate queue so status checks
    /// never wait behind an open alert.
    nonisolated private static let appleEventsAskQueue = DispatchQueue(label: "SparkV.Permissions.appleEvents.ask", qos: .userInitiated)

    func quickStatus(_ permission: PermissionCenter.Permission) -> PermissionCenter.Status {
        switch permission {
        case .accessibility: return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording: return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .camera: return Self.capture(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: return Self.capture(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech: return Self.speech(SFSpeechRecognizer.authorizationStatus())
        case .calendars: return Self.calendar(EKEventStore.authorizationStatus(for: .event))
        case .reminders: return Self.calendar(EKEventStore.authorizationStatus(for: .reminder))
        case .systemAudio:
            switch AmbientAudioPermission.rawPreflight() {
            case .granted: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            case .unknown: return .unknown
            }
        case .bluetooth: return Self.bluetooth(CBManager.authorization)
        case .notifications, .automation, .downloadsFolder: return .unknown
        }
    }

    func slowStatus(_ permission: PermissionCenter.Permission) async -> PermissionCenter.Status {
        switch permission {
        case .notifications:
            guard canUseNotifications else { return .unknown }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return Self.notification(settings.authorizationStatus)
        case .automation(let bundleID):
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return .appNotInstalled }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return .appNotRunning }
            return Self.automation(await Self.appleEventsPermission(bundleID: bundleID, askUser: false))
        case .downloadsFolder:
            return await Self.downloadsStatus()
        default:
            return quickStatus(permission)
        }
    }

    func prompt(_ permission: PermissionCenter.Permission) async {
        switch permission {
        case .accessibility:
            // "AXTrustedCheckOptionPrompt" is kAXTrustedCheckOptionPrompt (a C global var).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            _ = await Task.detached(priority: .userInitiated) { CGRequestScreenCaptureAccess() }.value
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            await Self.requestSpeech()
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .systemAudio:
            _ = await AmbientAudioPermission.rawRequest()
        case .notifications:
            guard canUseNotifications else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .bluetooth:
            guard CBManager.authorization == .notDetermined, bluetoothRequester == nil else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                bluetoothRequester = PermissionBluetoothRequester { [weak self] in
                    self?.bluetoothRequester = nil
                    continuation.resume()
                }
            }
        case .automation(let bundleID):
            _ = await Self.appleEventsPermission(bundleID: bundleID, askUser: true)
        case .downloadsFolder:
            // Not sandboxed: macOS asks on the first read of ~/Downloads.
            _ = await Self.downloadsStatus()
        }
    }

    /// The Accessibility and Screen Recording alerts don't report when they
    /// close. They're gone once the user clicks a button: "Open System
    /// Settings" activates Settings, "Deny" hands focus back. So: the first
    /// app activation a moment after the alert appeared, a change of the
    /// status, or 12 seconds, whichever comes first.
    func waitForPromptToClose(_ permission: PermissionCenter.Permission) async {
        guard permission.promptReturnsBeforeAnswer else { return }
        let shown = Date()
        let initial = quickStatus(permission)
        let flag = PromptCloseFlag()
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if Date().timeIntervalSince(shown) > 0.8 { flag.activated = true }
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        while Date().timeIntervalSince(shown) < 12, !flag.activated, quickStatus(permission) == initial {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func openSettings(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits (up to 30 s) for this process to exit, then reopens the app.
        let script = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$0\""
        process.arguments = ["-c", script, Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            AppLog.log("Permissions: relaunch failed: \(error.localizedDescription)")
        }
    }

    // MARK: Mapping

    nonisolated static func capture(_ status: AVAuthorizationStatus) -> PermissionCenter.Status {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    nonisolated static func speech(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionCenter.Status {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    nonisolated static func calendar(_ status: EKAuthorizationStatus) -> PermissionCenter.Status {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    nonisolated static func bluetooth(_ status: CBManagerAuthorization) -> PermissionCenter.Status {
        switch status {
        case .allowedAlways: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    nonisolated static func notification(_ status: UNAuthorizationStatus) -> PermissionCenter.Status {
        switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Result codes of AEDeterminePermissionToAutomateTarget.
    nonisolated static func automation(_ code: OSStatus) -> PermissionCenter.Status {
        switch code {
        case noErr: .granted
        case OSStatus(errAEEventNotPermitted): .denied
        case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
        case OSStatus(procNotFound): .appNotRunning
        default: .unknown
        }
    }

    // MARK: Helpers

    nonisolated private static func requestSpeech() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    nonisolated private static func downloadsStatus() async -> PermissionCenter.Status {
        await Task.detached(priority: .userInitiated) {
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: downloads.path)
                return PermissionCenter.Status.granted
            } catch {
                let code = (error as NSError).code
                return code == NSFileReadNoPermissionError || code == Int(EPERM) || code == Int(EACCES) ? .denied : .unknown
            }
        }.value
    }

    /// Off the main thread: with `askUser` it blocks until the user answers.
    nonisolated private static func appleEventsPermission(bundleID: String, askUser: Bool) async -> OSStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<OSStatus, Never>) in
            (askUser ? appleEventsAskQueue : appleEventsQueue).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                guard let address = target.aeDesc else {
                    continuation.resume(returning: OSStatus(paramErr))
                    return
                }
                continuation.resume(returning: AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser))
            }
        }
    }
}

/// Creating a CBCentralManager is what makes macOS ask for Bluetooth.
private final class PermissionBluetoothRequester: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var manager: CBCentralManager?
    private let onDecision: @MainActor () -> Void

    @MainActor
    init(onDecision: @escaping @MainActor () -> Void) {
        self.onDecision = onDecision
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        MainActor.assumeIsolated {
            manager?.delegate = nil
            manager = nil
            onDecision()
        }
    }
}

/// Set on the main queue only (see `waitForPromptToClose`).
private final class PromptCloseFlag: @unchecked Sendable {
    var activated = false
}

/// SCShareableContent is an immutable snapshot but isn't marked Sendable.
final class ShareableContentBox: @unchecked Sendable {
    let content: SCShareableContent
    init(_ content: SCShareableContent) { self.content = content }
}

// MARK: - Signature

/// What macOS keys privacy grants on: the designated requirement (names the
/// certificate for a stable identity, the code hash for ad-hoc builds). For
/// ad-hoc builds the app's path is added, since moving it also loses grants.
enum PermissionSignature {
    nonisolated static let current: String = compute()

    nonisolated private static func compute() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return fallback() }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return fallback() }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return fallback() }
        var source = text as String
        if source.contains("cdhash") { source += "|" + Bundle.main.bundlePath }
        return hash(source)
    }

    nonisolated private static func fallback() -> String {
        hash("unsigned|" + Bundle.main.bundlePath)
    }

    nonisolated private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
