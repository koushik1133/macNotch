import AppKit
import Combine
import CoreAudio

/// Per-app volumes: which apps make sound, the saved level of each, and a
/// route (tap + aggregate) for every app playing at a level other than 100 %.
///
/// Event-driven: Core Audio listeners for the process list, each process's
/// "is playing" flag, the default output and its sample rate. Listeners run
/// only while the feature is on and either a level is set or the mixer is on
/// screen; otherwise nothing is registered at all.
///
/// Safety: taps mute their app only while read (`.mutedWhenTapped`). A route
/// that doesn't start, doesn't run, or delivers only silence while macOS
/// withholds the audio is torn down at once, so an app is never left silent.
/// Routes are torn down on sleep, on output changes (then rebuilt) and
/// synchronously on quit.
@MainActor
final class AppVolumeController: ObservableObject {
    static let shared = AppVolumeController()

    enum Status: Equatable {
        case off
        case ready
        /// System Audio Recording isn't allowed.
        case needsPermission
        case failed(String)
    }

    struct AppRow: Identifiable, Equatable {
        let id: String
        let name: String
        let appPath: String?
        var isPlaying: Bool
        var gain: Double
        /// A route is applying `gain` right now.
        var isRouted: Bool
        var problem: String?
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled { AppLog.log("AppVolume: turned on") } else { AppLog.log("AppVolume: turned off") }
            evaluateMonitoring()
        }
    }
    @Published private(set) var rows: [AppRow] = []
    @Published private(set) var status: Status = .off

    private enum Keys {
        static let enabled = "AppVolume.enabled"
        static let gains = "AppVolume.gains"
    }

    private let defaults: UserDefaults
    private var gains: [String: Double]
    private var groups: [AppAudioGroup] = []
    private var routes: [String: AppGainRoute] = [:]
    /// Routes whose start finished (main-actor copy of their state).
    private var liveRoutes: Set<String> = []
    private var problems: [String: String] = [:]
    /// Apps that stopped playing: their route is kept briefly (track gaps).
    private var stopTasks: [String: Task<Void, Never>] = [:]
    private var unityTasks: [String: Task<Void, Never>] = [:]
    private var healthTasks: [String: Task<Void, Never>] = [:]
    /// Debounced re-taps (a newly playing helper the route doesn't cover).
    private var restartTasks: [String: Task<Void, Never>] = [:]
    private var mixerViews = 0
    private var isStarted = false
    private var isMonitoring = false
    private var isAsleep = false
    /// Set once a tap delivered real sound: System Audio Recording works.
    private var hasHeardTapAudio = false
    /// Apps whose level the user changed this session (may start a tap even
    /// when macOS can't report the permission).
    private var userSetIDs: Set<String> = []

    // Listener bookkeeping (registered and removed on `queue`).
    nonisolated let queue = DispatchQueue(label: "SparkV.AppVolume.hal", qos: .userInitiated)
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var processBlock: AudioObjectPropertyListenerBlock?
    private var watchedProcesses: Set<AudioObjectID> = []
    /// The output device whose sample rate is watched; only touched on `queue`.
    private let deviceWatch = MPDeviceWatch()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshQueued = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        gains = (defaults.dictionary(forKey: Keys.gains) as? [String: Double]) ?? [:]
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = true
                self?.tearDownAll(reason: "sleep")
            }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = false
                self?.refresh()
            }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }))
        evaluateMonitoring()
    }

    /// Synchronous: every tap and aggregate is gone when this returns.
    func stop() {
        isStarted = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        stopMonitoring(synchronously: true)
        tearDownAll(reason: "stop")
    }

    /// The mixer (panel, settings) is on screen: list apps even without levels.
    func setMixerVisible(_ visible: Bool) {
        mixerViews = max(0, mixerViews + (visible ? 1 : -1))
        evaluateMonitoring()
        if visible { refresh() }
    }

    // MARK: Levels

    func gain(for id: String) -> Double { gains[id] ?? 1 }

    /// From the slider (a user action: may show the System Audio Recording
    /// prompt the first time a level leaves 100 %).
    func setGain(_ value: Double, for id: String) {
        let gain = AppGainMath.snapped(value)
        let wasUnity = AppGainMath.isUnity(self.gain(for: id))
        if AppGainMath.isUnity(gain) { gains.removeValue(forKey: id) } else { gains[id] = gain }
        defaults.set(gains, forKey: Keys.gains)
        updateRows()
        if let route = routes[id] { route.state.setGain(Float(gain)) }

        if AppGainMath.isUnity(gain) {
            // Dragging through 100 % shouldn't tear down and rebuild.
            unityTasks[id]?.cancel()
            unityTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, !Task.isCancelled, AppGainMath.isUnity(self.gain(for: id)) else { return }
                self.unityTasks[id] = nil
                self.reconcile()
                self.evaluateMonitoring()
            }
            return
        }
        unityTasks[id]?.cancel()
        unityTasks[id] = nil
        if wasUnity {
            userSetIDs.insert(id)
            ensurePermissionThenReconcile()
        }
        evaluateMonitoring()
    }

    func resetAll() {
        gains.removeAll()
        defaults.set(gains, forKey: Keys.gains)
        tearDownAll(reason: "reset")
        updateRows()
        evaluateMonitoring()
    }

    var hasLevels: Bool { !gains.isEmpty }

    // MARK: Permission

    private func ensurePermissionThenReconcile() {
        switch AmbientAudioPermission.preflight() {
        case .granted, .unknown:
            if status == .needsPermission { status = .ready }
            reconcile()
        case .denied:
            status = .needsPermission
        case .notDetermined:
            Task {
                let answer = await PermissionCenter.shared.request(.systemAudio, from: "App Volumes", openingSettings: false)
                switch answer {
                case .denied, .restricted:
                    self.status = .needsPermission
                default:
                    if self.status == .needsPermission { self.status = .ready }
                    self.reconcile()
                }
            }
        }
    }

    func openPermissionSettings() {
        PermissionCenter.shared.openSettings(.systemAudio, from: "App Volumes")
    }

    // MARK: Monitoring

    private var wantsMonitoring: Bool {
        isEnabled && isStarted && !isAsleep && (!gains.isEmpty || mixerViews > 0)
    }

    private func evaluateMonitoring() {
        if wantsMonitoring {
            if !isMonitoring { startMonitoring() }
            if status == .off { status = AmbientAudioPermission.preflight() == .denied ? .needsPermission : .ready }
        } else {
            if isMonitoring { stopMonitoring() }
            if !isEnabled {
                tearDownAll(reason: "off")
                status = .off
                rows = []
            }
        }
    }

    private func startMonitoring() {
        isMonitoring = true
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let outputChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.outputChanged() }
        }
        systemBlock = outputChanged
        processBlock = changed
        let queue = queue
        // Async: the first HAL call can take a while; removal (stop, quit)
        // is queued behind it on the same serial queue.
        let changedBox = MPListenerBox(changed)
        let outputBox = MPListenerBox(outputChanged)
        queue.async {
            var list = MPAudioHAL.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(MPAudioHAL.system, &list, queue, changedBox.block)
            var output = MPAudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectAddPropertyListenerBlock(MPAudioHAL.system, &output, queue, outputBox.block)
        }
        watchOutputDevice()
        refresh()
    }

    /// Synchronous only on quit / stop; otherwise queued (no main-thread wait).
    private func stopMonitoring(synchronously: Bool = false) {
        guard isMonitoring else { return }
        isMonitoring = false
        let processes = watchedProcesses
        let processBox = processBlock.map(MPListenerBox.init)
        let systemBox = systemBlock.map(MPListenerBox.init)
        let deviceWatch = deviceWatch
        let queue = queue
        let work: @Sendable () -> Void = {
            if let processBlock = processBox?.block {
                var list = MPAudioHAL.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(MPAudioHAL.system, &list, queue, processBlock)
                for object in processes {
                    var running = MPAudioHAL.address(kAudioProcessPropertyIsRunningOutput)
                    AudioObjectRemovePropertyListenerBlock(object, &running, queue, processBlock)
                }
            }
            if let systemBlock = systemBox?.block {
                var output = MPAudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
                AudioObjectRemovePropertyListenerBlock(MPAudioHAL.system, &output, queue, systemBlock)
            }
            deviceWatch.remove(queue: queue)
        }
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) }
        watchedProcesses = []
        self.processBlock = nil
        self.systemBlock = nil
    }

    /// Follows the default output's sample rate (Bluetooth headsets switch
    /// to 16/24 kHz for calls): routes are rebuilt when it changes.
    private func watchOutputDevice() {
        let queue = queue
        let deviceWatch = deviceWatch
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebuildAll(reason: "sample rate changed") }
        }
        let box = MPListenerBox(block)
        queue.async {
            deviceWatch.remove(queue: queue)
            let device = MPAudioHAL.defaultOutput()
            guard device != kAudioObjectUnknown else { return }
            var rate = MPAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
            if AudioObjectAddPropertyListenerBlock(device, &rate, queue, box.block) == noErr {
                deviceWatch.device = device
                deviceWatch.block = box.block
            }
        }
    }

    private func outputChanged() {
        guard isMonitoring else { return }
        watchOutputDevice()
        rebuildAll(reason: "output changed")
    }

    /// Re-reads the process list (coalesced) and reconciles routes.
    func refresh() {
        guard isMonitoring, !refreshQueued else { return }
        refreshQueued = true
        let own = getpid()
        let queue = queue
        queue.async { [weak self] in
            let processes = AppAudioProcesses.read(excludingPID: own)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshQueued = false
                    guard self.isMonitoring else { return }
                    self.watch(processes.map(\.object))
                    self.groups = AppAudioProcesses.group(processes) { process, appPath in
                        Self.displayName(process, appPath: appPath)
                    }
                    self.updateRows()
                    self.reconcile()
                }
            }
        }
    }

    /// Adds "is playing" listeners for new process objects.
    private func watch(_ objects: [AudioObjectID]) {
        guard let block = processBlock else { return }
        let fresh = Set(objects).subtracting(watchedProcesses)
        let gone = watchedProcesses.subtracting(objects)
        guard !fresh.isEmpty || !gone.isEmpty else { return }
        watchedProcesses = watchedProcesses.union(fresh).subtracting(gone)
        let queue = queue
        let box = MPListenerBox(block)
        queue.async {
            for object in fresh {
                var running = MPAudioHAL.address(kAudioProcessPropertyIsRunningOutput)
                AudioObjectAddPropertyListenerBlock(object, &running, queue, box.block)
            }
            for object in gone {
                var running = MPAudioHAL.address(kAudioProcessPropertyIsRunningOutput)
                AudioObjectRemovePropertyListenerBlock(object, &running, queue, box.block)
            }
        }
    }

    private static func displayName(_ process: AppAudioProcess, appPath: String?) -> String? {
        if let appPath {
            if let id = Bundle(path: appPath)?.bundleIdentifier,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
               let name = app.localizedName { return name }
            return FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        }
        // WebKit's media process names itself after its host
        // ("Safari Graphics and Media").
        return NSRunningApplication(processIdentifier: process.pid)?.localizedName
    }

    // MARK: Routes

    private func updateRows() {
        let list = groups.filter { $0.isPlaying || gains[$0.id] != nil }.map { group in
            AppRow(id: group.id, name: group.name, appPath: group.appPath, isPlaying: group.isPlaying,
                   gain: gain(for: group.id), isRouted: liveRoutes.contains(group.id), problem: problems[group.id])
        }
        let sorted = list.sorted { lhs, rhs in
            lhs.isPlaying != rhs.isPlaying ? lhs.isPlaying : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if rows != sorted { rows = sorted }
    }

    /// Starts routes that should run, stops the rest.
    private func reconcile() {
        guard isEnabled, isStarted, !isAsleep else { return }
        // Never prompt from here (an app starting to play is not a user
        // action): start only when allowed, or when macOS can't say and the
        // user just set this level.
        let permission = AmbientAudioPermission.preflight()
        for group in groups {
            let mayStart = permission == .granted
                || (permission == .unknown && (hasHeardTapAudio || userSetIDs.contains(group.id)))
            let gain = gain(for: group.id)
            let wanted = !AppGainMath.isUnity(gain) && group.isPlaying
            if wanted {
                stopTasks[group.id]?.cancel()
                stopTasks[group.id] = nil
                if let route = routes[group.id] {
                    // Only a process that plays and isn't tapped needs a new
                    // route; helpers coming and going (browsers) don't. Each
                    // restart briefly plays the app at 100 %, so wait 1 s for
                    // the process list to settle first.
                    if AppGainMath.needsRetap(tapped: route.objects, playing: group.playingObjects) {
                        scheduleRestart(group.id)
                    } else {
                        restartTasks.removeValue(forKey: group.id)?.cancel()
                    }
                } else if mayStart {
                    if problems[group.id] == nil { start(group, gain: gain) }
                } else {
                    status = .needsPermission
                }
            } else if routes[group.id] != nil, stopTasks[group.id] == nil {
                let id = group.id
                let delay: Double = AppGainMath.isUnity(gain) ? 0 : 2.5
                stopTasks[id] = Task { [weak self] in
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard let self, !Task.isCancelled else { return }
                    self.stopTasks[id] = nil
                    let stillWanted = self.groups.first { $0.id == id }.map { $0.isPlaying && !AppGainMath.isUnity(self.gain(for: id)) } ?? false
                    if !stillWanted { self.stopRoute(id) }
                }
            }
        }
        // Apps that quit.
        for id in routes.keys where !groups.contains(where: { $0.id == id }) {
            stopRoute(id)
        }
        updateRows()
    }

    private func start(_ group: AppAudioGroup, gain: Double) {
        let route = AppGainRoute(key: group.id, name: group.name, objects: group.objects, gain: Float(gain))
        routes[group.id] = route
        let id = group.id
        let name = group.name
        queue.async { [weak self] in
            var failure: String?
            var short: String?
            do {
                try route.start()
            } catch {
                failure = error.localizedDescription
                short = (error as? AppVolumeError)?.shortText ?? "Couldn’t adjust this app"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { route.stop(); return }
                    guard self.routes[id] === route else {
                        self.queue.async { route.stop() }
                        return
                    }
                    if let failure {
                        AppLog.log("AppVolume: couldn’t route \(name): \(failure)")
                        self.routes[id] = nil
                        self.problems[id] = short ?? failure
                        self.updateRows()
                        return
                    }
                    AppLog.log("AppVolume: \(name) at \(AppGainMath.percentText(self.gain(for: id)))")
                    self.liveRoutes.insert(id)
                    self.problems[id] = nil
                    self.updateRows()
                    self.checkHealth(id: id, route: route)
                }
            }
        }
    }

    private func scheduleRestart(_ id: String) {
        guard restartTasks[id] == nil else { return }
        restartTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.restartTasks[id] = nil
            guard let group = self.groups.first(where: { $0.id == id }), let route = self.routes[id],
                  group.isPlaying, !AppGainMath.isUnity(self.gain(for: id)),
                  AppGainMath.needsRetap(tapped: route.objects, playing: group.playingObjects) else { return }
            AppLog.log("AppVolume: \(group.name) has a new playing process; re-tapping")
            self.stopRoute(id)
            self.start(group, gain: self.gain(for: id))
        }
    }

    private func stopRoute(_ id: String) {
        healthTasks.removeValue(forKey: id)?.cancel()
        restartTasks.removeValue(forKey: id)?.cancel()
        liveRoutes.remove(id)
        guard let route = routes.removeValue(forKey: id) else { return }
        queue.async { route.stop() }
        AppLog.log("AppVolume: \(route.name) back to normal output")
        updateRows()
    }

    /// The IO block must run within a second; if it delivers nothing but
    /// zeros while the app plays and System Audio Recording isn't granted,
    /// macOS is withholding the audio (the app would be silent): undo.
    private func checkHealth(id: String, route: AppGainRoute) {
        healthTasks[id]?.cancel()
        healthTasks[id] = Task { [weak self] in
            // Bluetooth outputs can take a second to start.
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.routes[id] === route else { return }
            if route.state.cycles.load(ordering: .relaxed) == 0 {
                AppLog.log("AppVolume: \(route.name)’s route isn’t running; undoing it")
                self.problems[id] = "Couldn’t adjust this app"
                self.stopRoute(id)
                return
            }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, self.routes[id] === route else { return }
            if route.state.audibleCycles.load(ordering: .relaxed) > 0 {
                self.hasHeardTapAudio = true
                return
            }
            if AmbientAudioPermission.preflight() != .granted, !self.hasHeardTapAudio {
                AppLog.log("AppVolume: \(route.name) delivers only silence; System Audio Recording looks off")
                self.status = .needsPermission
                self.problems[id] = "Needs audio permission"
                self.stopRoute(id)
            }
        }
    }

    private func rebuildAll(reason: String) {
        guard !routes.isEmpty else { return }
        AppLog.log("AppVolume: rebuilding routes (\(reason))")
        let ids = Array(routes.keys)
        for id in ids { stopRoute(id) }
        problems.removeAll()
        // Give the HAL a moment to settle on the new device.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.reconcile()
        }
    }

    private func tearDownAll(reason: String) {
        for task in stopTasks.values { task.cancel() }
        stopTasks.removeAll()
        for task in healthTasks.values { task.cancel() }
        healthTasks.removeAll()
        for task in restartTasks.values { task.cancel() }
        restartTasks.removeAll()
        let all = Array(routes.values)
        routes.removeAll()
        liveRoutes.removeAll()
        guard !all.isEmpty else { return }
        AppLog.log("AppVolume: removing \(all.count) route(s) (\(reason))")
        // Synchronous: on quit and sleep nothing may be left behind.
        queue.sync { for route in all { route.stop() } }
        updateRows()
    }

    /// Clears a failed app so the next play tries again.
    func retry(_ id: String) {
        problems[id] = nil
        if status == .needsPermission, AmbientAudioPermission.preflight() == .granted { status = .ready }
        reconcile()
    }
}

/// The watched output device and its listener. Only read and written on the
/// controller's HAL queue (hence unchecked).
final class MPDeviceWatch: @unchecked Sendable {
    var device = AudioObjectID(kAudioObjectUnknown)
    var block: AudioObjectPropertyListenerBlock?

    /// Call on the HAL queue.
    func remove(queue: DispatchQueue) {
        if let block, device != kAudioObjectUnknown {
            var rate = MPAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &rate, queue, block)
        }
        device = AudioObjectID(kAudioObjectUnknown)
        block = nil
    }
}

/// Carries a Core Audio listener block to the HAL queue (the block itself
/// only hops back to the main actor, so sharing it is safe).
final class MPListenerBox: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock
    init(_ block: @escaping AudioObjectPropertyListenerBlock) { self.block = block }
}
