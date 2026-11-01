import AppKit
import ApplicationServices
import Combine
import SwiftUI

// MARK: - Preferences

/// Calls in the island (Settings › Activities › Calls). Keys start with "Calls.".
@MainActor
final class CallPreferences: ObservableObject {
    static let shared = CallPreferences()

    enum Keys {
        static let ongoing = "Calls.showsOngoing"
        static let incoming = "Calls.showsIncoming"
        static let windows = "Calls.watchesCallWindows"
        static let unmutes = "Calls.unmutesWhenCallEnds"
    }

    /// A green call timer beside the notch while a call goes on.
    @Published var showsOngoingCalls: Bool { didSet { defaults.set(showsOngoingCalls, forKey: Keys.ongoing) } }
    /// Accept / Decline for ringing FaceTime and iPhone calls.
    @Published var showsIncomingCalls: Bool { didSet { defaults.set(showsIncomingCalls, forKey: Keys.incoming) } }
    /// Also watch Zoom, Teams, WhatsApp, … for their own ringing windows
    /// (only windows they create, never their chats).
    @Published var watchesCallWindows: Bool { didSet { defaults.set(watchesCallWindows, forKey: Keys.windows) } }
    /// Unmute the microphone when the call whose Mute SparkV pressed ends.
    @Published var unmutesWhenCallEnds: Bool { didSet { defaults.set(unmutesWhenCallEnds, forKey: Keys.unmutes) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsOngoingCalls = defaults.object(forKey: Keys.ongoing) as? Bool ?? true
        showsIncomingCalls = defaults.object(forKey: Keys.incoming) as? Bool ?? true
        watchesCallWindows = defaults.object(forKey: Keys.windows) as? Bool ?? true
        unmutesWhenCallEnds = defaults.object(forKey: Keys.unmutes) as? Bool ?? true
    }
}

// MARK: - Controller

/// Calls in the closed island:
///
/// - **Ongoing**: while `MeetingCallDetector` sees a call (Zoom, Teams,
///   Meet, FaceTime, WhatsApp, …), a green timer rests beside the notch
///   (`Text(timerInterval:)`, redrawn by SwiftUI without a timer of ours)
///   and the band, when it peeks or is hovered, has Mute and Show. The
///   detector runs only while Meetings › Detect Calls is on; Settings and
///   the menu say so when it is off.
/// - **Incoming**: a ringing FaceTime / Phone call (a Notification Center
///   alert) or a call app's newly created ringing window gets an urgent
///   band with Decline and Accept, which press the call's own buttons
///   through Accessibility. Nothing is ever answered automatically, and
///   clicks in the band's first half second are ignored.
/// - **Mute**: the Mac's one microphone mute, `MicMuteController` (⌃⌥M,
///   follows input switches, undone after a crash). A mute pressed for a
///   call is undone when that call ends, if the user wants that.
@MainActor
final class CallsController: ObservableObject {
    static let ongoingID = "call.active"
    static let incomingID = "call.incoming"
    /// Below the REC wings (65) and the notes prompt (64), above a timer (20).
    static let ongoingPriority = 30
    /// Above everything: the phone is ringing.
    static let incomingPriority = 95
    static let incomingBandHeight: CGFloat = 52
    /// A call that rings longer than this has stopped ringing.
    static let ringTimeout: TimeInterval = 75

    static weak var current: CallsController?

    /// The call going on, with when it started.
    struct ActiveCall: Equatable {
        var key: String
        var service: String
        var title: String
        var hasGenericTitle: Bool
        var iconBundleID: String?
        var startedAt: Date
    }

    @Published private(set) var activeCall: ActiveCall?
    @Published private(set) var incoming: IncomingCallAlert?
    /// Meetings › Detect Calls is on (the ongoing-call timer needs it).
    @Published private(set) var detectsCalls = true

    let prefs: CallPreferences
    let microphone: MicMuteController
    let windowWatcher: CallWindowWatcher

    private let activities: ActivityCenter
    private let notifications: NotificationMonitor?
    private let calls: AnyPublisher<DetectedCall?, Never>
    private weak var meetingAssistant: MeetingAssistant?
    private let clock: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false
    private var ringTimeoutTask: Task<Void, Never>?
    private var incomingPostedAt: Date?
    /// The user pressed Mute for the call going on (from the band, tile or
    /// menu): that mute is undone when the call ends.
    private var mutedForCall = false
    private var iconCache: [String: NSImage] = [:]

    init(
        activities: ActivityCenter,
        notifications: NotificationMonitor?,
        calls: AnyPublisher<DetectedCall?, Never>,
        meetingAssistant: MeetingAssistant? = nil,
        prefs: CallPreferences? = nil,
        microphone: MicMuteController? = nil,
        windowWatcher: CallWindowWatcher? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.activities = activities
        self.notifications = notifications
        self.calls = calls
        self.meetingAssistant = meetingAssistant
        self.prefs = prefs ?? .shared
        self.microphone = microphone ?? .shared
        self.windowWatcher = windowWatcher ?? CallWindowWatcher()
        self.clock = clock
        Self.current = self
    }

    /// The app's wiring: calls from the meeting assistant's detector.
    convenience init(activities: ActivityCenter, notifications: NotificationMonitor, meetingAssistant: MeetingAssistant) {
        self.init(
            activities: activities,
            notifications: notifications,
            calls: meetingAssistant.callDetector.$activeCall.eraseToAnyPublisher(),
            meetingAssistant: meetingAssistant
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        calls
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] call in MainActor.assumeIsolated { self?.callChanged(call) } }
            .store(in: &cancellables)
        notifications?.$incomingCall
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.ringingChanged() } }
            .store(in: &cancellables)
        windowWatcher.$ringing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.ringingChanged() } }
            .store(in: &cancellables)
        microphone.$isMuted
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.microphoneChanged() } }
            .store(in: &cancellables)
        Publishers.CombineLatest(prefs.$showsOngoingCalls, prefs.$showsIncomingCalls)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in MainActor.assumeIsolated { self?.preferencesChanged() } }
            .store(in: &cancellables)
        prefs.$watchesCallWindows
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if on && self.prefs.showsIncomingCalls { self.windowWatcher.start() } else { self.windowWatcher.stop() }
                }
            }
            .store(in: &cancellables)
        if let meetingAssistant {
            meetingAssistant.$detectCalls
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] on in MainActor.assumeIsolated { self?.detectsCalls = on } }
                .store(in: &cancellables)
        }
    }

    func stop() {
        isStarted = false
        cancellables.removeAll()
        windowWatcher.stop()
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
        undoCallMuteIfNeeded()
        activities.dismiss(id: Self.ongoingID)
        activities.dismiss(id: Self.incomingID)
        activeCall = nil
        incoming = nil
    }

    /// Turns Meetings › Detect Calls on (from Calls settings or the menu).
    func turnOnCallDetection() {
        meetingAssistant?.detectCalls = true
    }

    // MARK: Ongoing

    private func callChanged(_ call: DetectedCall?) {
        guard let call else {
            if let ended = activeCall {
                AppLog.log("Calls: \(ended.service) call ended after \(Int(clock().timeIntervalSince(ended.startedAt))) s")
            }
            activeCall = nil
            activities.dismiss(id: Self.ongoingID)
            undoCallMuteIfNeeded()
            return
        }
        let isNew = activeCall?.key != call.key
        // The detector reports a call once its evidence held for a few
        // seconds: the call started that much earlier.
        let started = isNew
            ? CallMutePolicy.startedAt(detectedAt: clock(), startDelay: MeetingCallDebouncer().startDelay)
            : (activeCall?.startedAt ?? clock())
        activeCall = ActiveCall(key: call.key, service: call.serviceName, title: call.title,
                                hasGenericTitle: call.hasGenericTitle, iconBundleID: call.iconBundleID, startedAt: started)
        if isNew {
            AppLog.log("Calls: \(call.serviceName) call started")
            mutedForCall = false
        }
        postOngoing(peek: isNew)
    }

    /// Muted or unmuted (from the band, a tile, ⌃⌥M or the system): the
    /// wings show the new state. The mic's own feedback band says so.
    private func microphoneChanged() {
        if !microphone.isMuted { mutedForCall = false }
        guard activeCall != nil, prefs.showsOngoingCalls else { return }
        postOngoing(peek: false)
    }

    private func preferencesChanged() {
        if prefs.showsOngoingCalls { postOngoing(peek: false) } else { activities.dismiss(id: Self.ongoingID) }
        if !prefs.showsIncomingCalls { windowWatcher.stop() } else if prefs.watchesCallWindows { windowWatcher.start() }
        ringingChanged()
    }

    private func postOngoing(peek: Bool) {
        guard prefs.showsOngoingCalls, let call = activeCall else { return }
        let icon = icon(for: call.iconBundleID)
        let started = call.startedAt
        let muted = microphone.isMuted
        let title = call.hasGenericTitle ? "\(call.service) call" : call.title
        activities.post(LiveActivity(
            id: Self.ongoingID,
            kind: .call,
            priority: Self.ongoingPriority,
            duration: nil,
            height: 44,
            presentation: .compact,
            peekKey: peek ? call.key : activities.activity(id: Self.ongoingID)?.peekKey
        ) { [weak self] in
            if let self { OngoingCallBand(controller: self, call: call, icon: icon) }
        }
        .compact {
            CallAppBadge(icon: icon, size: 16)
        } trailing: {
            CallElapsedLabel(startedAt: started, isMuted: muted)
        }
        .minimal {
            CallMinimalBadge(isMuted: muted)
        }
        .titled(title)
        .interactive()
        .accessibility(muted ? "On a \(call.service) call, microphone muted" : "On a \(call.service) call"))
    }

    // MARK: Incoming

    private func ringingChanged() {
        let alert = prefs.showsIncomingCalls ? (notifications?.incomingCall ?? windowWatcher.ringing) : nil
        guard alert?.id != incoming?.id else { return }
        incoming = alert
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
        guard let alert else {
            incomingPostedAt = nil
            activities.dismiss(id: Self.incomingID)
            return
        }
        postIncoming(alert)
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringTimeout))
            guard !Task.isCancelled, let self, self.incoming?.id == alert.id else { return }
            self.incoming = nil
            self.activities.dismiss(id: Self.incomingID)
        }
    }

    /// The caller's name shows unless the user hides senders, or
    /// notification previews are off (also while Smart Moments pauses them
    /// for a screen share or a meeting).
    static func showsCaller(privacy: NotificationPrivacy, previewsOn: Bool) -> Bool {
        previewsOn && privacy != .appOnly
    }

    private func postIncoming(_ alert: IncomingCallAlert) {
        let privacy = NotificationPreferences.shared.privacy
        let previewsOn = notifications?.isEnabled ?? true
        let caller = Self.showsCaller(privacy: privacy, previewsOn: previewsOn) ? alert.caller : nil
        let icon = alert.bundleID.flatMap { icon(for: $0) } ?? alert.appName.flatMap(NotificationAppLocator.icon(forAppNamed:))
        let spoken = ActivityAnnouncementText.incomingCall(app: alert.appName, caller: caller)
        incomingPostedAt = clock()
        activities.post(LiveActivity(
            id: Self.incomingID,
            kind: .call,
            priority: Self.incomingPriority,
            duration: nil,
            height: Self.incomingBandHeight,
            presentation: .expanded,
            urgent: true
        ) { [weak self] in
            IncomingCallBand(
                caller: caller, appName: alert.appName, detail: privacy == .full && previewsOn ? alert.detail : nil, icon: icon,
                canAccept: alert.accept != nil, canDecline: alert.decline != nil,
                onAccept: { self?.answer(accept: true) },
                onDecline: { self?.answer(accept: false) }
            )
        }
        .compact {
            CallRingingBadge()
        } trailing: {
            Text("Ringing")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.success)
                .fixedSize()
        }
        .titled("Incoming call")
        .interactive()
        .accessibility(spoken)
        .announcing(spoken, as: .call, important: true))
    }

    /// Accept or Decline, pressed on the call's own alert or window. If
    /// that fails, the call app comes forward so it can be answered there.
    /// A click in the band's first half second is ignored: the band may
    /// have appeared under a click meant for something else.
    func answer(accept: Bool) {
        guard let alert = incoming else { return }
        guard IncomingCallGuard.acceptsAnswer(postedAt: incomingPostedAt, now: clock()) else {
            AppLog.log("Calls: ignored a click right as the call band appeared")
            return
        }
        incoming = nil
        incomingPostedAt = nil
        ringTimeoutTask?.cancel()
        activities.dismiss(id: Self.incomingID)
        let fallback: @MainActor (Bool) -> Void = { pressed in
            guard !pressed else { return }
            if let bundleID = alert.bundleID { NotificationAppLocator.open(bundleID: bundleID) }
            else { NotificationAppLocator.open(appNamed: alert.appName ?? "FaceTime") }
        }
        switch alert.source {
        case .notificationCenter:
            if let notifications { notifications.answerIncomingCall(alert, accept: accept, completion: fallback) } else { fallback(false) }
        case .appWindow:
            windowWatcher.press(alert, accept: accept, completion: fallback)
        }
    }

    // MARK: Actions on the ongoing call

    /// Mute / unmute the Mac's microphone (`MicMuteController`). A mute
    /// pressed during a call is remembered, so the call's end undoes it.
    func toggleMute() {
        guard microphone.canMute else {
            AppLog.log("Calls: the microphone can't be muted from here")
            return
        }
        let target = !microphone.isMuted
        microphone.setMuted(target)
        if target, microphone.isMuted, activeCall != nil { mutedForCall = true }
        if !target { mutedForCall = false }
    }

    /// Brings the call app (or the browser with the meeting) forward.
    func showCallApp() {
        NotificationAppLocator.open(bundleID: activeCall?.iconBundleID)
    }

    // MARK: Helpers

    private func undoCallMuteIfNeeded() {
        if CallMutePolicy.unmutesAtCallEnd(mutedForCall: mutedForCall, mutedBySparkV: microphone.mutedBySparkV,
                                          preference: prefs.unmutesWhenCallEnds) {
            AppLog.log("Calls: unmuting the microphone muted for the call")
            microphone.setMuted(false)
        }
        mutedForCall = false
    }

    private func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        if iconCache.count >= 64 { iconCache.removeAll() }
        if let found { iconCache[bundleID] = found }
        return found
    }
}

// MARK: - Ringing windows of call apps

/// Spots call apps that ring in a window of their own (Zoom, Teams,
/// WhatsApp, Webex, …). An `AXObserver` per running call app reports only
/// *new windows* (`kAXWindowCreatedNotification`, never element churn in
/// a chat); each new window is read once, about 150 ms after it appears
/// (and once more if its contents were still filling in). It rings when it
/// has Accept and Decline and says it's a call ("Incoming call", "is
/// calling", …). While it rings, only that window is watched for going
/// away (its destroyed event, and a 2 s check of that window alone, for
/// at most the ring timeout).
///
/// Needs Accessibility (never prompted from here). Apps that don't expose
/// their buttons to Accessibility (Electron apps without assistive mode)
/// can't be seen; SparkV never switches that mode on, it slows them down.
@MainActor
final class CallWindowWatcher: ObservableObject {
    struct App: Equatable {
        let name: String
        let bundleIDs: [String]
    }

    static let apps: [App] = [
        App(name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        App(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        App(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        App(name: "Webex", bundleIDs: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]),
        App(name: "Skype", bundleIDs: ["com.skype.skype"]),
        App(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram"]),
        App(name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"]),
        App(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
    ]

    static func app(bundleID: String?) -> App? {
        guard let bundleID else { return nil }
        return apps.first { $0.bundleIDs.contains(bundleID) }
    }

    /// Delay before reading a new window (its buttons fill in right after).
    static let readDelay: TimeInterval = 0.15

    @Published private(set) var ringing: IncomingCallAlert?
    private(set) var isRunning = false

    private struct Watch {
        let observer: AXObserver
        let bundleID: String
        let name: String
    }

    private var watches: [pid_t: Watch] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var trustWatch: AnyCancellable?
    private var ringingPID: pid_t?
    private var ringingWindow: AXElementBox?
    private var recheck: Task<Void, Never>?
    private var pendingReads: [pid_t: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "SparkV.CallWindowWatcher", qos: .userInitiated)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier ?? 0
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.attach(pid: pid, bundleID: bundleID) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            MainActor.assumeIsolated { self?.detach(pid: pid) }
        })
        trustWatch = PermissionCenter.shared.onChange(of: .accessibility, poll: false) { [weak self] status in
            guard let self, self.isRunning else { return }
            self.detachAll()
            if status.isGranted { self.attachRunning() }
        }
        attachRunning()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        trustWatch = nil
        detachAll()
    }

    /// Presses Accept or Decline in the ringing window (off the main thread).
    func press(_ alert: IncomingCallAlert, accept: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard let control = accept ? alert.accept : alert.decline else { completion(false); return }
        queue.async {
            let pressed = NotificationAXScanner.press(control)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(pressed) } }
        }
        if ringing?.id == alert.id { setRinging(nil, pid: nil, window: nil) }
    }

    // MARK: Observers

    private func attachRunning() {
        guard PermissionCenter.shared.isGranted(.accessibility) else { return }
        for app in NSWorkspace.shared.runningApplications {
            attach(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }
    }

    private func attach(pid: pid_t, bundleID: String?) {
        guard isRunning, pid > 0, watches[pid] == nil, let app = Self.app(bundleID: bundleID), let bundleID,
              PermissionCenter.shared.isGranted(.accessibility)
        else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, callWindowWatcherCallback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // New windows only: element churn (scrolling a chat) never wakes us.
        _ = AXObserverAddNotification(created, element, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        watches[pid] = Watch(observer: created, bundleID: bundleID, name: app.name)
        AppLog.log("Calls: watching \(app.name) for ringing windows")
    }

    private func detach(pid: pid_t) {
        pendingReads.removeValue(forKey: pid)?.cancel()
        guard let watch = watches.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .defaultMode)
        if ringingPID == pid { setRinging(nil, pid: nil, window: nil) }
    }

    private func detachAll() {
        for pid in Array(watches.keys) { detach(pid: pid) }
        setRinging(nil, pid: nil, window: nil)
    }

    fileprivate func handleEvent(observer: AXObserver, element: AXUIElement, name: String) {
        guard let pid = watches.first(where: { CFEqual($0.value.observer, observer) })?.key else { return }
        if name == kAXUIElementDestroyedNotification {
            // Only ever registered on the ringing window.
            if ringingPID == pid { setRinging(nil, pid: nil, window: nil) }
            return
        }
        guard name == kAXWindowCreatedNotification else { return }
        // A burst of new windows: read the latest one once things settle.
        let window = AXElementBox(element: element)
        pendingReads[pid]?.cancel()
        pendingReads[pid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readDelay))
            guard !Task.isCancelled, let self else { return }
            self.pendingReads[pid] = nil
            self.read(window: window, pid: pid, retry: true)
        }
    }

    /// Reads one window off the main thread. `retry`: a window whose
    /// buttons aren't there yet gets one more look 400 ms later.
    private func read(window: AXElementBox, pid: pid_t, retry: Bool) {
        guard let watch = watches[pid] else { return }
        let name = watch.name
        let bundleID = watch.bundleID
        queue.async { [weak self] in
            let found = CallWindowScanner.ringing(in: window.element)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.watches[pid] != nil else { return }
                    if let found {
                        let alert = IncomingCallAlert(
                            id: "\(bundleID).\(pid).\(found.signature)", appName: name, caller: found.caller,
                            detail: nil, accept: found.accept, decline: found.decline, source: .appWindow(bundleID: bundleID)
                        )
                        self.setRinging(alert, pid: pid, window: window)
                    } else if self.ringingPID == pid, let ringingWindow = self.ringingWindow, CFEqual(ringingWindow.element, window.element) {
                        self.setRinging(nil, pid: nil, window: nil)
                    } else if retry {
                        Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(400))
                            self?.read(window: window, pid: pid, retry: false)
                        }
                    }
                }
            }
        }
    }

    private func setRinging(_ alert: IncomingCallAlert?, pid: pid_t?, window: AXElementBox?) {
        if alert?.id != ringing?.id {
            if let alert { AppLog.log("Calls: \(alert.appName ?? "a call app") is ringing") }
            ringing = alert
        }
        // Destroyed events only on the ringing window, only while it rings.
        if let old = ringingWindow, let oldPID = ringingPID, let watch = watches[oldPID],
           window.map({ !CFEqual($0.element, old.element) }) ?? true {
            AXObserverRemoveNotification(watch.observer, old.element, kAXUIElementDestroyedNotification as CFString)
        }
        if let window, let pid, let watch = watches[pid],
           ringingWindow.map({ !CFEqual($0.element, window.element) }) ?? true {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            _ = AXObserverAddNotification(watch.observer, window.element, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        ringingPID = alert == nil ? nil : pid
        ringingWindow = alert == nil ? nil : window
        recheck?.cancel()
        recheck = nil
        guard alert != nil, let pid, let window else { return }
        // While it rings: the same window, read again every 2 s (answered
        // in the app, the buttons go and so does the band).
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.read(window: window, pid: pid, retry: false)
        }
    }
}

/// AXObserver C callback (main run loop).
private func callWindowWatcherCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ name: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let notification = name as String
    MainActor.assumeIsolated {
        let watcher = Unmanaged<CallWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
        watcher.handleEvent(observer: observer, element: element, name: notification)
    }
}

/// Read-only walk of one call-app window for Accept, Decline and call
/// wording.
enum CallWindowScanner {
    struct Found: Sendable {
        var signature: String
        var caller: String?
        var accept: NotificationControl?
        var decline: NotificationControl?
    }

    private static let maxNodes = 400
    private static let maxDepth = 12
    private static let maxTexts = 12

    nonisolated static func ringing(in window: AXUIElement) -> Found? {
        AXUIElementSetMessagingTimeout(window, 0.5)
        var controls: [NotificationControl] = []
        var texts: [String] = []
        var budget = maxNodes
        walk(window, depth: 0, controls: &controls, texts: &texts, budget: &budget)
        let title = NotificationAXScanner.string(window, kAXTitleAttribute) ?? ""
        guard IncomingCallClassifier.isRingingWindow(title: title, texts: texts, roles: controls.map(\.role)) else { return nil }
        return Found(
            signature: title.isEmpty ? "window" : title,
            caller: callerName(windowTitle: title, texts: texts),
            accept: controls.first { $0.role == .accept },
            decline: controls.first { $0.role == .decline }
        )
    }

    /// The caller: the first text that isn't the app's own wording.
    nonisolated static func callerName(windowTitle: String, texts: [String]) -> String? {
        let generic = ["incoming call", "incoming video call", "incoming audio call", "is calling", "calling", "ringing",
                       "zoom", "microsoft teams", "whatsapp", "webex", "skype", "telegram", "signal", "discord"]
        let candidates = texts + [windowTitle]
        return candidates
            .map { NotificationParser.clean($0) }
            .first { text in
                let lower = text.lowercased()
                return !text.isEmpty && text.count <= 60 && !generic.contains(lower)
                    && !generic.contains { lower.hasPrefix($0) }
                    && !IncomingCallClassifier.ringingWording.contains { lower.contains($0) }
                    && NotificationControlClassifier.role(for: text) == .other
            }
    }

    private nonisolated static func walk(
        _ element: AXUIElement, depth: Int,
        controls: inout [NotificationControl], texts: inout [String], budget: inout Int
    ) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1
        let role = NotificationAXScanner.string(element, kAXRoleAttribute) ?? ""
        switch role {
        case kAXButtonRole:
            let title = NotificationAXScanner.string(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                ?? NotificationAXScanner.string(element, kAXDescriptionAttribute) ?? ""
            let kind = NotificationControlClassifier.role(for: title)
            if kind == .accept || kind == .decline, !controls.contains(where: { $0.role == kind }) {
                controls.append(NotificationControl(title: title, role: kind, element: AXElementBox(element: element), actionName: kAXPressAction))
            }
            return
        case kAXStaticTextRole:
            if texts.count < maxTexts, let value = NotificationAXScanner.string(element, kAXValueAttribute), !value.isEmpty {
                texts.append(value)
            }
            return
        default:
            break
        }
        for child in NotificationAXScanner.elements(element, kAXChildrenAttribute) {
            walk(child, depth: depth + 1, controls: &controls, texts: &texts, budget: &budget)
        }
    }
}
