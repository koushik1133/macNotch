import AppKit
import CoreAudio
import CoreGraphics
import Foundation

// The live trigger sources: NSWorkspace notifications (front app, Spaces),
// screen changes, the default audio output (CoreAudio, no Bluetooth
// permission), the window list for screen sharing and presentations (never
// prompts: without Screen Recording access window titles are just missing),
// idle time, the clock, and Spotlight for new screenshots. Controllers that
// already observe things (calls, downloads, clipboard, battery, calendar)
// report through the `report…` methods and input closures set in wiring.
//
// Nothing here records, captures or reads file contents.

/// A battery reading for the low-battery moment (from PowerMonitor).
struct MomentBatterySample: Sendable, Equatable {
    var level: Int
    var onBattery: Bool
    var minutesLeft: Int?
}

struct MomentFrontApp: Sendable, Equatable {
    var bundleID: String?
    var name: String?
    var pid: Int32
}

@MainActor
final class SmartMomentsLiveSources: ObservableObject {
    /// Another app shares the screen (wiring: `hooks.isScreenSharing`).
    @Published private(set) var isScreenSharing = false
    @Published private(set) var isPresenting = false
    private(set) var isRunning = false

    weak var engine: SmartMomentsController?

    // Inputs from wiring ----------------------------------------------------

    /// Today's meetings (MeetingsController.meetings).
    var meetings: @MainActor () -> [CalendarMeeting] = { [] }
    var isOnCall: @MainActor () -> Bool = { false }
    var isFocusSessionActive: @MainActor () -> Bool = { false }
    /// What SparkV is recording right now, if anything.
    var recordingKind: @MainActor () -> MomentRecordingKind? = { nil }
    var battery: @MainActor () -> MomentBatterySample? = { nil }

    // System readers (tests replace them) -----------------------------------

    var readWindows: @MainActor () -> [MomentWindowInfo] = { SmartMomentsSystemReaders.windows() }
    var readDisplays: @MainActor () -> [MomentDisplayInfo] = { SmartMomentsSystemReaders.displays() }
    var readIdleSeconds: @MainActor () -> TimeInterval = { SmartMomentsSystemReaders.idleSeconds() }
    var readFrontApp: @MainActor () -> MomentFrontApp? = { SmartMomentsSystemReaders.frontApp() }
    var now: @MainActor () -> Date = { Date() }
    var ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    var ownBundleID: String? = Bundle.main.bundleIdentifier

    nonisolated static let slowInterval: TimeInterval = 20
    nonisolated static let hotInterval: TimeInterval = 3
    nonisolated static let idleInterval: TimeInterval = 15

    // State -------------------------------------------------------------------

    private var dwell = MomentDwellTracker()
    private var night = MomentLateNightTracker()
    private var batteryWatch = MomentLowBatteryWatch()
    private var shareDebouncer = MomentEdgeDebouncer(onAfter: 2, offAfter: 2)
    private var presentDebouncer = MomentEdgeDebouncer(onAfter: 2, offAfter: 2)
    private var displayDiff = MomentDisplayDiff()
    private var lastSharer: MomentWindowInfo?
    private var lastPresentation: MomentPresentationHeuristics.Detection?
    private var hasExternalDisplay = false

    private var workspaceObservers: [NSObjectProtocol] = []
    private var centerObservers: [NSObjectProtocol] = []
    private var slowLoop: Task<Void, Never>?
    private var fastLoop: Task<Void, Never>?
    private var screenshotQuery: NSMetadataQuery?
    private var screenshotObserver: NSObjectProtocol?
    private var screenshotsSince = Date()
    private var seenScreenshots: Set<String> = []

    init(engine: SmartMomentsController) {
        self.engine = engine
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        _ = displayDiff.update(readDisplays()) // baseline
        hasExternalDisplay = readDisplays().contains { !$0.isBuiltin }
        if let front = readFrontApp() { dwell.frontmostChanged(bundleID: front.bundleID, appName: front.name, at: now()) }

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let front = app.map { MomentFrontApp(bundleID: $0.bundleIdentifier, name: $0.localizedName, pid: $0.processIdentifier) }
            MainActor.assumeIsolated { self?.appActivated(front) }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFast(after: 0.6) }
        })
        centerObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        scheduleSlow(after: 2)
        scheduleFast(after: 2)
        updateScreenshotQuery()
        AppLog.log("SmartMoments: sources started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        slowLoop?.cancel()
        fastLoop?.cancel()
        slowLoop = nil
        fastLoop = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in centerObservers { NotificationCenter.default.removeObserver(observer) }
        workspaceObservers = []
        centerObservers = []
        stopScreenshotQuery()
        // Whatever was in effect ends, so the engine puts it back.
        if shareDebouncer.isOn { engine?.handle(.screenSharingEnded) }
        if presentDebouncer.isOn { engine?.handle(.presentationEnded) }
        shareDebouncer.reset()
        presentDebouncer.reset()
        isScreenSharing = false
        isPresenting = false
    }

    // MARK: - Reports from controllers (wiring)

    /// MeetingCallDetector events. `.updated` only renames the call.
    func reportCallEvent(_ event: MeetingCallEvent, recordedMeetingID: UUID?) {
        switch event {
        case .started(let call): engine?.handle(.meetingStarted(call))
        case .ended(let call): engine?.handle(.meetingEnded(call, recordedMeetingID: recordedMeetingID))
        case .updated: break
        }
    }

    func reportDownloadFinished(itemID: UUID, url: URL, suggestedFolder: String?) {
        engine?.handle(.downloadFinished(itemID: itemID, url: url, suggestedFolder: suggestedFolder))
    }

    /// A copy ClipboardController recorded and detected as a link or code.
    /// `preview` is what the band shows (the host for a link).
    func reportCopied(_ kind: MomentCopiedKind, preview: String, itemID: UUID?) {
        guard !isScreenSharing else { return }
        engine?.handle(.copied(kind, preview: preview, itemID: itemID))
    }

    /// A screenshot from the system (Spotlight, below) or ScreenRegion.
    func reportScreenshot(url: URL) {
        guard !seenScreenshots.contains(url.path) else { return }
        seenScreenshots.insert(url.path)
        if seenScreenshots.count > 200 { seenScreenshots = [url.path] }
        engine?.handle(.screenshotTaken(url: url))
    }

    // MARK: - Slow loop: calendar, dwell, late night, battery

    private func scheduleSlow(after delay: TimeInterval) {
        slowLoop?.cancel()
        slowLoop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.sampleSlow()
            self.scheduleSlow(after: Self.slowInterval)
        }
    }

    /// One slow sample. Internal so tests drive it with fakes.
    func sampleSlow() {
        guard let engine else { return }
        let now = now()
        let tunables = engine.settings.tunables

        if engine.wants(.meetingSoon) {
            for (meeting, minutes) in MomentMeetingSoonScanner.due(meetings(), now: now, leadMinutes: tunables.meetingLeadMinutes) {
                engine.handle(.meetingSoon(meeting, minutesUntilStart: minutes))
            }
        }

        let idle = readIdleSeconds()
        if engine.wants(.deepWork) {
            if let front = readFrontApp() { dwell.frontmostChanged(bundleID: front.bundleID, appName: front.name, at: now) }
            if let trigger = dwell.sample(
                now: now, idleSeconds: idle, thresholdMinutes: tunables.deepWorkMinutes,
                excluded: Set(tunables.deepWorkExcludedBundleIDs), ownBundleID: ownBundleID,
                blocked: isFocusSessionActive() || isOnCall()
            ) {
                engine.handle(trigger)
            }
        }

        if engine.wants(.lateNight), let trigger = night.sample(now: now, idleSeconds: idle, startHour: tunables.lateNightHour) {
            engine.handle(trigger)
        }

        if engine.wants(.lowBatteryRecording), let reading = battery(),
           let trigger = batteryWatch.sample(
               level: reading.level, onBattery: reading.onBattery, minutesLeft: reading.minutesLeft,
               recording: recordingKind(), thresholdPercent: tunables.lowBatteryPercent
           ) {
            engine.handle(trigger)
        }

        updateScreenshotQuery()
        // A settings change turned on a moment that needs the fast loop.
        if fastLoop == nil, wantsFastLoop { scheduleFast(after: 0.6) }
    }

    // MARK: - Fast loop: screen sharing, presentations

    private var pollsSharing: Bool {
        guard let engine else { return false }
        return engine.wants(.screenSharing) || MomentEngineRules.contentMoments.contains { engine.wants($0) } || shareDebouncer.isOn
    }

    private var isHot: Bool {
        if isOnCall() || isScreenSharing || isPresenting || hasExternalDisplay { return true }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return !running.isDisjoint(with: MomentPresentationHeuristics.slideshowApps.keys)
    }

    /// The fast loop is only scheduled while a moment needs it (sharing or
    /// presentation detection, or one still in effect): idle, nothing wakes.
    private var wantsFastLoop: Bool {
        guard let engine else { return false }
        return pollsSharing || engine.wants(.presentation) || presentDebouncer.isOn
    }

    private func scheduleFast(after delay: TimeInterval) {
        guard isRunning else { return }
        fastLoop?.cancel()
        fastLoop = nil
        guard wantsFastLoop else { return }
        fastLoop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(max(0.2, delay * 0.1)))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.sampleFast()
            self.scheduleFast(after: self.isHot ? Self.hotInterval : Self.idleInterval)
        }
    }

    /// One fast sample. Internal so tests drive it with fakes.
    func sampleFast() {
        guard let engine else { return }
        let sharing = pollsSharing
        let presenting = engine.wants(.presentation) || presentDebouncer.isOn
        guard sharing || presenting else { return }
        let windows = readWindows()

        if sharing {
            let sharer = MomentScreenShareHeuristics.sharer(in: windows, ownPID: ownPID)
            if let sharer { lastSharer = sharer }
            if let flipped = shareDebouncer.feed(sharer != nil) {
                isScreenSharing = flipped
                if flipped {
                    engine.handle(.screenSharingStarted(appBundleID: lastSharer?.bundleID, appName: lastSharer?.ownerName))
                } else {
                    engine.handle(.screenSharingEnded)
                }
            }
        }

        if presenting {
            let front = readFrontApp()
            let detection = MomentPresentationHeuristics.detect(
                frontBundleID: front?.bundleID, frontName: front?.name, frontPID: front?.pid,
                windows: windows, displays: readDisplays(), ownPID: ownPID
            )
            if let detection { lastPresentation = detection }
            if let flipped = presentDebouncer.feed(detection != nil) {
                isPresenting = flipped
                if flipped, let shown = lastPresentation {
                    engine.handle(.presentationStarted(appBundleID: shown.bundleID, appName: shown.appName, isSlideshow: shown.isSlideshow))
                } else if !flipped {
                    engine.handle(.presentationEnded)
                }
            }
        }
    }

    // MARK: - Events

    func appActivated(_ front: MomentFrontApp?) {
        dwell.frontmostChanged(bundleID: front?.bundleID, appName: front?.name, at: now())
        scheduleFast(after: 0.8)
    }

    func screensChanged() {
        let displays = readDisplays()
        hasExternalDisplay = displays.contains { !$0.isBuiltin }
        let added = displayDiff.update(displays)
        guard let engine, engine.wants(.displayConnected) else { return }
        for display in added {
            engine.handle(.displayConnected(displayID: display.id, name: display.name))
        }
    }

    // MARK: - Screenshots (Spotlight's kMDItemIsScreenCapture)

    private func updateScreenshotQuery() {
        let wanted = isRunning && (engine?.wants(.screenshotTaken) ?? false)
        if wanted, screenshotQuery == nil {
            startScreenshotQuery()
        } else if !wanted, screenshotQuery != nil {
            stopScreenshotQuery()
        }
    }

    private func startScreenshotQuery() {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [SmartMomentsSystemReaders.screenshotFolder()]
        screenshotsSince = now()
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
        ) { [weak self] note in
            let added = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
            let found = added.compactMap { item -> (path: String, created: Date?)? in
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                return (path, item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)
            }
            MainActor.assumeIsolated { self?.screenshotsAdded(found) }
        }
        if query.start() {
            screenshotQuery = query
        } else {
            AppLog.log("SmartMoments: screenshot query did not start")
        }
    }

    private func stopScreenshotQuery() {
        screenshotQuery?.stop()
        screenshotQuery = nil
        if let observer = screenshotObserver { NotificationCenter.default.removeObserver(observer) }
        screenshotObserver = nil
    }

    func screenshotsAdded(_ items: [(path: String, created: Date?)]) {
        for item in items {
            if let created = item.created, created < screenshotsSince.addingTimeInterval(-2) { continue }
            reportScreenshot(url: URL(fileURLWithPath: item.path))
        }
    }
}

// MARK: - System readers

@MainActor
enum SmartMomentsSystemReaders {
    static func windows() -> [MomentWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var bundleIDs: [Int32: String?] = [:]
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            if bundleIDs[pid] == nil {
                bundleIDs[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            return MomentWindowInfo(
                ownerPID: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String,
                bundleID: bundleIDs[pid] ?? nil,
                name: info[kCGWindowName as String] as? String,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                isOnscreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            )
        }
    }

    static func displays() -> [MomentDisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return MomentDisplayInfo(
                id: id, name: screen.localizedName, frame: CGDisplayBounds(id), isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    /// Seconds since the last keyboard, mouse or trackpad event (no
    /// permission needed).
    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static func frontApp() -> MomentFrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return MomentFrontApp(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier)
    }

    /// The default output device, from CoreAudio.
    static func defaultOutput() -> MomentAudioOutput? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let name = string(device, kAudioObjectPropertyName) ?? "Sound output"
        let uid = string(device, kAudioDevicePropertyDeviceUID) ?? "\(device)"
        return MomentAudioOutput(uid: uid, name: name, isBluetooth: isBluetooth)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Where macOS saves screenshots (`defaults read com.apple.screencapture
    /// location`), else the Desktop.
    static func screenshotFolder() -> URL {
        if let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
