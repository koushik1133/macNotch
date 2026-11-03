import AppKit
import Carbon.HIToolbox
import Combine

/// Island placement and visibility: which display, which style, and when
/// the island gets out of the way. NotchWindowController owns one, starts
/// it after laying out the panel and asks it for every decision.
///
/// Everything is event driven (workspace, screen and session
/// notifications); the only timer is the full-screen watcher's slow check,
/// which runs only while full screen is on or likely.
@MainActor
final class IslandPlacementController: ObservableObject {
    /// For Smart Moments ("Quiet the notch", "Move island here") and the
    /// settings views.
    static weak var current: IslandPlacementController?

    let settings: IslandPlacementSettings
    let fullScreen = IslandFullScreenWatcher()
    let capture: IslandCapturePrivacy
    let blackMenuBar: IslandBlackMenuBar

    struct FrontApp: Equatable {
        var bundleID: String
        var name: String
    }

    @Published private(set) var displays: [IslandDisplayInfo] = []
    @Published private(set) var builtInActive = true
    @Published private(set) var fullScreenDisplays: Set<CGDirectDisplayID> = []
    @Published private(set) var frontApp: FrontApp?
    @Published private(set) var isManuallyHidden = false
    /// A timed hide ("Hide for 1 Hour") ends at this time.
    @Published private(set) var hiddenUntil: Date?
    @Published private(set) var quietReasons: Set<String> = []
    @Published private(set) var sessionActive = true
    /// The display the island is on, as NotchWindowController laid it out.
    @Published private(set) var islandDisplayID: CGDirectDisplayID?
    /// The saved display is unplugged and the island waits elsewhere.
    @Published private(set) var isWaitingForDisplay = false
    /// The last visibility decision (for Settings and the gear menu).
    @Published private(set) var decision = IslandVisibilityDecision.shown
    /// Hotkey registration failed (taken by another app).
    @Published private(set) var hotkeyUnavailable = false

    /// The display under the pointer (follow modes), set by the window controller.
    var pointerDisplayID: CGDirectDisplayID?
    /// All Displays' mirror displays, set by the window controller.
    var mirrorDisplayIDs: Set<CGDirectDisplayID> = []

    /// Re-run layout and visibility (settings or displays changed).
    var onLayoutNeeded: (() -> Void)?
    /// Re-run visibility only (full screen, front app, hide, quiet).
    var onVisibilityNeeded: (() -> Void)?
    /// ⌃⌥H pressed.
    var onHotkey: (() -> Void)?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var bag: Set<AnyCancellable> = []
    private var hideTimer: Task<Void, Never>?
    private let hotkey = ScreenRegionHotkey()
    private var started = false

    static let hotkeyShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(controlKey | optionKey))
    static var hotkeyLabel: String { hotkeyShortcut.displayString }

    init(settings: IslandPlacementSettings? = nil,
         capture: IslandCapturePrivacy? = nil,
         blackMenuBar: IslandBlackMenuBar? = nil) {
        self.settings = settings ?? .shared
        self.capture = capture ?? .shared
        self.blackMenuBar = blackMenuBar ?? .shared
        refreshDisplays()
        noteFrontApp(NSWorkspace.shared.frontmostApplication)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Self.current = self
        // Only the island's own displays keep the slow full-screen check alive.
        fullScreen.watchedDisplays = { [weak self] in
            guard let self, let id = self.islandDisplayID else { return nil }
            return self.mirrorDisplayIDs.union([id])
        }
        fullScreen.onChange = { [weak self] set in
            self?.fullScreenDisplays = set
            self?.onVisibilityNeeded?()
        }
        fullScreen.start()
        fullScreenDisplays = fullScreen.fullScreenDisplays

        let workspace = NSWorkspace.shared.notificationCenter
        let activate = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteFrontApp(app)
                self.onVisibilityNeeded?()
            }
        }
        observers.append((workspace, activate))

        // Any setting change: lay out again on the next turn (values are stored by then).
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateHotkey()
                self.onLayoutNeeded?()
            }
            .store(in: &bag)

        capture.start()
        blackMenuBar.start()
        updateHotkey()
        AppLog.log("Island: placement \(settings.displayMode.rawValue), hide in full screen \(settings.hideInFullScreen ? "on" : "off")")
    }

    func stop() {
        started = false
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        bag.removeAll()
        fullScreen.stop()
        capture.stop()
        blackMenuBar.stop()
        hotkey.unregister()
        hideTimer?.cancel()
        hideTimer = nil
        // Every suppression reason goes with SparkV.
        quietReasons.removeAll()
        isManuallyHidden = false
    }

    // MARK: Displays

    /// Re-reads the connected displays. True when the set changed.
    @discardableResult
    func refreshDisplays() -> Bool {
        let now = IslandDisplays.current()
        let active = IslandDisplays.builtInActive()
        let changed = now != displays || active != builtInActive
        displays = now
        builtInActive = active
        return changed
    }

    func resolve() -> IslandDisplayResolution {
        let resolution = IslandDisplayResolver.resolve(
            mode: settings.displayMode,
            savedUUID: settings.displayUUID,
            displays: displays,
            pointerDisplayID: settings.displayMode.followsPointer ? pointerDisplayID : nil,
            currentDisplayID: islandDisplayID
        )
        if isWaitingForDisplay != resolution.isFallback { isWaitingForDisplay = resolution.isFallback }
        return resolution
    }

    /// The window controller laid the island out on this display.
    func noteIslandDisplay(_ id: CGDirectDisplayID?) {
        if islandDisplayID != id { islandDisplayID = id }
        IslandScreen.displayID = id
    }

    func info(for id: CGDirectDisplayID?) -> IslandDisplayInfo? {
        id.flatMap { id in displays.first { $0.id == id } }
    }

    /// Smart Moments' "Move island here", Settings' display list.
    func moveIsland(toDisplayID id: CGDirectDisplayID) -> Bool {
        refreshDisplays()
        guard let display = displays.first(where: { $0.id == id }) else { return false }
        settings.choose(display: display)
        AppLog.log("Island: moved to \(display.name)")
        return true
    }

    // MARK: Visibility inputs

    func record(_ newDecision: IslandVisibilityDecision) {
        if decision != newDecision {
            if newDecision.reasons != decision.reasons {
                AppLog.log(newDecision.isHidden
                    ? "Island: hidden (\(newDecision.reasons.map(\.rawValue).joined(separator: ", ")))\(newDecision.isPassThrough ? ", band passes through" : "")"
                    : "Island: shown")
            }
            decision = newDecision
        }
        IslandScreen.isSuppressed = newDecision.isHidden || newDecision.ignoresHover
    }

    func isFullScreen(_ id: CGDirectDisplayID?) -> Bool {
        guard let id else { return false }
        return fullScreenDisplays.contains(id)
    }

    var isFrontAppExcluded: Bool { settings.isExcluded(frontApp?.bundleID) }

    private func noteFrontApp(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }
        let front = FrontApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
        if frontApp != front { frontApp = front }
    }

    /// "Disable SparkV in <App>" from the gear menu.
    func setFrontAppExcluded(_ excluded: Bool) {
        guard let frontApp else { return }
        settings.setExcluded(frontApp.bundleID, excluded)
        onVisibilityNeeded?()
    }

    func setSessionActive(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        if active { fullScreen.resume() } else { fullScreen.pause() }
        onVisibilityNeeded?()
    }

    func pauseWatching() { fullScreen.pause() }
    func resumeWatching() { fullScreen.resume() }

    /// Re-check full screen now (Space change, wake).
    func recheckFullScreen() { fullScreen.evaluate(followUp: true) }

    // MARK: Manual hide

    /// Hides until shown again (hotkey) or for `duration` (gear menu).
    func hide(for duration: TimeInterval? = nil) {
        hideTimer?.cancel()
        hideTimer = nil
        isManuallyHidden = true
        if let duration {
            let until = Date().addingTimeInterval(duration)
            hiddenUntil = until
            hideTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.unhide()
            }
        } else {
            hiddenUntil = nil
        }
        AppLog.log("Island: hidden by the user\(duration.map { " for \(Int($0 / 60)) min" } ?? "")")
        onVisibilityNeeded?()
    }

    func unhide() {
        hideTimer?.cancel()
        hideTimer = nil
        hiddenUntil = nil
        guard isManuallyHidden else { return }
        isManuallyHidden = false
        onVisibilityNeeded?()
    }

    // MARK: Quiet (Smart Moments)

    /// The Presentation moment's "Quiet the notch" (see INTEGRATION.md).
    static let smartMomentsQuietReason = "smartMoments.presentation"

    /// Hides the island (and with it every live activity) while `reason`
    /// holds it, e.g. a presentation. Each reason is put back separately.
    func setQuiet(_ quiet: Bool, reason: String) {
        var reasons = quietReasons
        if quiet { reasons.insert(reason) } else { reasons.remove(reason) }
        guard reasons != quietReasons else { return }
        quietReasons = reasons
        onVisibilityNeeded?()
    }

    // MARK: Hotkey

    private func updateHotkey() {
        if settings.hotkeyEnabled {
            guard !hotkey.isRegistered else { return }
            hotkey.onPress = { [weak self] in self?.onHotkey?() }
            let ok = hotkey.register(Self.hotkeyShortcut)
            hotkeyUnavailable = !ok
            if !ok { AppLog.log("Island: \(Self.hotkeyLabel) is taken by another app") }
        } else if hotkey.isRegistered {
            hotkey.unregister()
            hotkeyUnavailable = false
        }
    }

    // MARK: Status text

    /// One line for Settings: where the island is and why it hides.
    var statusLine: String {
        let name = info(for: islandDisplayID)?.name ?? "No display"
        if decision.isHidden {
            return "Hidden on \(name): \(decision.reasons.map(\.title).joined(separator: ", ").lowercasedFirst)"
        }
        if isWaitingForDisplay, let saved = settings.displayName {
            return "On \(name) until \(saved) is connected again"
        }
        return "Showing on \(name)"
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
