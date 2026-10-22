import AppKit
import Combine

/// First-launch setup: Welcome, Terms & Privacy, then a live permissions
/// checklist. Shows on first launch, when `OnboardingTerms.version` goes up,
/// and once per build when an Accessibility grant stopped matching after a
/// rebuild. Re-opens from the gear menu (`OnboardingMenuItems`).
@MainActor
final class OnboardingController: ObservableObject {
    static let shared = OnboardingController()

    /// Posted on the main thread when any permission turns on while the
    /// window is open, so features waiting for one can start right away.
    static let permissionsDidChange = Notification.Name("SparkV.onboarding.permissionsDidChange")

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, terms, permissions
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .terms: "Terms & Privacy"
            case .permissions: "Permissions"
            }
        }
    }

    @Published var step: Step = .welcome
    @Published var agreesToTerms = false
    @Published private(set) var statuses: [OnboardingPermission: OnboardingPermissionStatus] = [:]
    /// Rows whose prompt is up or whose request is still running.
    @Published private(set) var pending: Set<OnboardingPermission> = []
    @Published private(set) var requestedThisLaunch: Set<OnboardingPermission> = []
    @Published private(set) var diagnosis: OnboardingGrantDiagnosis = .notGranted(adHoc: false)
    /// The "SparkV still says Accessibility is missing" card is expanded.
    @Published var showsStaleHelp = false
    /// The user closed the card for an automatically detected stale grant.
    @Published private(set) var staleCardDismissed = false

    /// The user says Screen Recording is on in System Settings, but this
    /// build isn't allowed: the same stale-signature problem.
    @Published private(set) var showsScreenRecordingHelp = false

    var showsStaleCard: Bool { staleAccessibility || staleScreenRecording }

    /// Accessibility belongs to another build (detected, or reported).
    var staleAccessibility: Bool {
        guard !status(of: .accessibility).isGranted, diagnosis != .fine else { return false }
        return showsStaleHelp || (diagnosis.isStale && !staleCardDismissed)
    }

    /// Screen Recording reported as on (or last granted under a different
    /// code signature) but not allowed for this build.
    var staleScreenRecording: Bool {
        guard !status(of: .screenRecording).isGranted else { return false }
        return showsScreenRecordingHelp || (screenRecordingGrantIsStale && !staleCardDismissed)
    }

    /// The permissions the card is about, Accessibility first.
    var stalePermissions: [OnboardingPermission] {
        (staleAccessibility ? [.accessibility] : []) + (staleScreenRecording ? [.screenRecording] : [])
    }

    func hideStaleCard() {
        showsStaleHelp = false
        showsScreenRecordingHelp = false
        staleCardDismissed = true
    }
    @Published private(set) var resetNote: String?
    @Published private(set) var isVisible = false
    /// PermissionCenter saw Screen Recording granted under another signature.
    @Published private(set) var screenRecordingGrantIsStale = false
    /// PermissionCenter asked for Screen Recording (or sent the user to
    /// Settings) this session and the grant isn't active yet.
    @Published private(set) var centerNeedsRelaunch = false

    let store: OnboardingStore
    let probe: OnboardingPermissionProbe
    let identity: OnboardingCodeIdentity
    let center: PermissionCenter
    /// Opens the window; replaced in tests.
    var presenter: (OnboardingController) -> Void = { OnboardingWindowController.shared.show(controller: $0) }
    var dismisser: () -> Void = { OnboardingWindowController.shared.close() }

    private var userReportedGrant = false
    private var timer: Timer?
    private var isRefreshing = false
    /// Timer ticks since the last slow check (notifications, Downloads,
    /// Automation: Apple Events per target app).
    private var ticksSinceSlowRefresh = 0
    private var centerSubscriptions: Set<AnyCancellable> = []

    /// Live refresh while the window is open: cheap preflights every tick,
    /// the slow checks every `slowRefreshEvery` ticks (and after a click).
    static let refreshInterval: TimeInterval = 1
    static let slowRefreshEvery = 5

    init(
        store: OnboardingStore = OnboardingStore(),
        probe: OnboardingPermissionProbe? = nil,
        identity: OnboardingCodeIdentity = .current(),
        center: PermissionCenter? = nil
    ) {
        let center = center ?? .shared
        self.store = store
        self.center = center
        self.probe = probe ?? SystemPermissionProbe(center: center)
        self.identity = identity
        agreesToTerms = store.hasAcceptedCurrentTerms
        updateDiagnosis(trusted: self.probe.isAccessibilityTrusted())
    }

    // MARK: Launch

    /// First launch, a newer terms version, or (once per build) an
    /// Accessibility grant that belonged to an earlier build.
    var shouldShowOnLaunch: Bool {
        !store.hasAcceptedCurrentTerms || launchStaleNoticeIsDue
    }

    private var launchStaleNoticeIsDue: Bool {
        guard case .stale(_, .rebuilt) = diagnosis else { return false }
        return store.staleNoticeBuild != identity.buildKey
    }

    /// Call once from `applicationDidFinishLaunching`.
    func showIfNeeded() {
        updateDiagnosis(trusted: probe.isAccessibilityTrusted())
        guard shouldShowOnLaunch else { return }
        if store.hasAcceptedCurrentTerms, launchStaleNoticeIsDue {
            store.staleNoticeBuild = identity.buildKey
            showsStaleHelp = true
            show(step: .permissions)
        } else {
            show(step: .welcome)
        }
    }

    /// Opens the window. Without accepted terms it never skips past them.
    func show(step requested: Step? = nil) {
        var target = requested ?? (store.hasAcceptedCurrentTerms ? .permissions : .welcome)
        if target == .permissions, !store.hasAcceptedCurrentTerms { target = .terms }
        step = target
        agreesToTerms = store.hasAcceptedCurrentTerms
        isVisible = true
        // Prompts are allowed right after launch only while this is open.
        center.isOnboardingActive = true
        presenter(self)
        startRefreshing()
    }

    // MARK: Steps

    func next() {
        switch step {
        case .welcome: step = .terms
        case .terms: acceptTerms()
        case .permissions: finish()
        }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func acceptTerms() {
        guard agreesToTerms else { return }
        if !store.hasAcceptedCurrentTerms {
            store.acceptTerms()
            AppLog.log("Onboarding: accepted terms v\(OnboardingTerms.version)")
        }
        step = .permissions
        Task { await refresh() }
    }

    var termsAcceptedSummary: String? {
        guard store.hasAcceptedCurrentTerms, let date = store.termsAcceptedAt else { return nil }
        return "Accepted version \(store.acceptedTermsVersion) on \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Done.
    func finish() {
        store.markCompleted()
        OnboardingDragHelper.shared.close()
        dismisser()
        windowDidClose()
    }

    /// The window closed (Done, the close button, or quit).
    func windowDidClose() {
        isVisible = false
        center.isOnboardingActive = false
        stopRefreshing()
    }

    // MARK: Live status

    func startRefreshing() {
        guard timer == nil else { return }
        Task { await refresh() }
        ticksSinceSlowRefresh = 0
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Changes PermissionCenter notices (the Accessibility notification,
        // coming back from System Settings) show up at once.
        center.$statuses
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refresh(includeSlow: false) }
                }
            }
            .store(in: &centerSubscriptions)
        center.$screenRecordingNeedsRelaunch
            .removeDuplicates()
            .sink { [weak self] needs in
                MainActor.assumeIsolated { self?.centerNeedsRelaunch = needs }
            }
            .store(in: &centerSubscriptions)
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        centerSubscriptions.removeAll()
    }

    private func tick() async {
        ticksSinceSlowRefresh += 1
        let slow = ticksSinceSlowRefresh >= Self.slowRefreshEvery
        await refresh(includeSlow: slow)
    }

    func refresh(includeSlow: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Before the first full read every row needs a value.
        let slow = includeSlow || statuses.isEmpty
        if slow { ticksSinceSlowRefresh = 0 }
        var fresh = await probe.statuses(downloadsRequested: store.downloadsRequested, includeSlow: slow)
        if !slow {
            for permission in OnboardingPermission.allCases where fresh[permission] == nil {
                fresh[permission] = statuses[permission]
            }
        }
        let newlyGranted = fresh.contains { permission, status in
            status.isGranted && statuses[permission].map { !$0.isGranted } == true
        }
        if fresh != statuses { statuses = fresh }
        let srStale = center.isLikelyStaleGrant(.screenRecording)
        if srStale != screenRecordingGrantIsStale { screenRecordingGrantIsStale = srStale }
        // A prompt that never reports back (Bluetooth, an alert left open
        // while the switch was flipped in Settings) mustn't keep the row
        // spinning once the permission is on.
        let settled = pending.filter { fresh[$0]?.isGranted == true }
        if !settled.isEmpty { pending.subtract(settled) }
        updateDiagnosis(trusted: fresh[.accessibility]?.isGranted ?? probe.isAccessibilityTrusted())
        if let helping = OnboardingDragHelper.shared.visiblePermission, status(of: helping).isGranted {
            OnboardingDragHelper.shared.close()
        }
        if newlyGranted {
            NotificationCenter.default.post(name: Self.permissionsDidChange, object: self)
        }
    }

    func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus {
        statuses[permission] ?? .unknown
    }

    func action(for permission: OnboardingPermission) -> OnboardingRowAction {
        OnboardingRowAction.for(permission, status: status(of: permission))
    }

    /// Rows that count toward "x of y": automation for apps that aren't
    /// installed doesn't.
    var countedPermissions: [OnboardingPermission] {
        OnboardingPermission.allCases.filter { status(of: $0) != .appNotInstalled }
    }

    var grantedCount: Int { countedPermissions.filter { status(of: $0).isGranted }.count }

    var essentialsGranted: Bool {
        OnboardingPermission.allCases.filter(\.isEssential).allSatisfy { status(of: $0).isGranted }
    }

    // MARK: Actions

    /// A row's button. Every prompt goes through PermissionCenter: it shows
    /// at most once (per code signature for Accessibility and Screen
    /// Recording), one at a time, and denied rows open System Settings.
    func perform(_ permission: OnboardingPermission) {
        switch action(for: permission) {
        case .none:
            return
        case .openSettings:
            openSettings(for: permission)
        case .request, .launchAndRequest:
            guard !pending.contains(permission) else { return }
            pending.insert(permission)
            requestedThisLaunch.insert(permission)
            if permission == .downloads { store.downloadsRequested = true }
            Task {
                await probe.request(permission)
                pending.remove(permission)
                await refresh()
            }
        }
    }

    func openSettings(for permission: OnboardingPermission) {
        center.openSettings(permission.centerPermission, from: "Onboarding")
        if permission == .accessibility || permission == .screenRecording, !status(of: permission).isGranted {
            OnboardingDragHelper.shared.show(for: permission)
        }
        if permission == .screenRecording, !status(of: permission).isGranted {
            requestedThisLaunch.insert(.screenRecording)
        }
    }

    /// Restarts SparkV so a new Screen Recording grant applies.
    func relaunch() {
        center.relaunch(from: "Onboarding")
    }

    /// "It's already on in System Settings": the grant belongs to another
    /// build, so show how to renew it.
    func userReportsGranted(_ permission: OnboardingPermission = .accessibility) {
        staleCardDismissed = false
        if permission == .screenRecording {
            showsScreenRecordingHelp = true
            return
        }
        userReportedGrant = true
        showsStaleHelp = true
        updateDiagnosis(trusted: status(of: .accessibility).isGranted)
    }

    /// Removes SparkV's old entries for the permissions on the card (never
    /// any other app's), then asks again so this build is added fresh.
    func resetAccessibilityEntry() {
        let permissions = stalePermissions.isEmpty ? [.accessibility] : stalePermissions
        resetNote = permissions.count > 1 ? "Removing the old entries…" : "Removing the old entry…"
        if permissions.contains(.screenRecording) { requestedThisLaunch.insert(.screenRecording) }
        OnboardingFixes.resetEntries(for: permissions) { [weak self] ok in
            guard let self else { return }
            let restart = permissions.contains(.screenRecording) ? " Screen Recording applies after you restart SparkV." : ""
            self.resetNote = ok
                ? "Removed. Click “Open System Settings” in the alert and turn SparkV on.\(restart)"
                : "Couldn’t remove it automatically. Use the − button in System Settings instead."
            Task { await self.refresh() }
        }
    }

    /// Screen Recording only applies after SparkV restarts (asked here, or
    /// by any other feature through PermissionCenter, this session).
    var screenRecordingNeedsRestart: Bool {
        (requestedThisLaunch.contains(.screenRecording) || centerNeedsRelaunch) && !status(of: .screenRecording).isGranted
    }

    private func updateDiagnosis(trusted: Bool) {
        if trusted {
            if store.trustedBuild != identity.buildKey {
                store.trustedBuild = identity.buildKey
                store.trustedBuildIsAdHoc = !identity.grantsSurviveRebuilds
            }
            userReportedGrant = false
            showsStaleHelp = false
            resetNote = nil
        }
        // A stable signing identity keeps grants across rebuilds, so a new
        // build hash alone isn't a stale grant: ask PermissionCenter whether
        // the grant was last seen under another signature, or whether the
        // last trusted build was ad hoc (moving to a certificate loses it).
        var otherSignature: Bool?
        if identity.grantsSurviveRebuilds, !trusted {
            let fromAdHoc = store.trustedBuildIsAdHoc && store.trustedBuild.map { $0 != identity.buildKey } == true
            otherSignature = fromAdHoc || center.isLikelyStaleGrant(.accessibility)
        }
        let fresh = OnboardingGrantDiagnosis.evaluate(
            trusted: trusted,
            identity: identity,
            lastTrustedBuild: store.trustedBuild,
            userReportedGrant: userReportedGrant,
            grantFromOtherSignature: otherSignature
        )
        if fresh != diagnosis { diagnosis = fresh }
    }
}
