import AppKit
import Combine
import CoreAudio
import QuartzCore

/// SparkV DJ: turns system-wide sound processing on and off, follows the
/// default output (speakers ↔ AirPods), keeps App Volumes' apps out of its
/// tap, ramps preset changes and runs the beat/spectrum analysis the page
/// draws. Off at every launch; only the user's click turns it on.
@MainActor
final class DJController: ObservableObject {
    static let shared = DJController()

    enum Status: Equatable {
        case off
        case starting
        case running
        case needsPermission
        case failed(String)
    }

    @Published private(set) var isOn = false
    @Published private(set) var status: Status = .off
    /// A/B compare: the route keeps running but plays the untouched sound.
    @Published var isBypassed = false {
        didSet { route?.state.set(wet: isBypassed ? 0 : 1) }
    }
    @Published private(set) var outputName = ""
    /// Sample rate of the running route (for the stats line).
    @Published private(set) var sampleRate: Double = 0

    let settings = DJSettings.shared
    /// The analysis the page reads (DJ route when on, a listen-only tap while
    /// the page is open and DJ is off). nil when nothing captures.
    private(set) var pump: DJAnalysisPump?

    private var route: DJRoute?
    private var monitor: AmbientProcessTapSource?
    private var generation = 0
    private var visibleCount = 0
    private var cancellables: Set<AnyCancellable> = []
    private var rampTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var lastCycles = 0
    private var stalledSeconds = 0
    private var isCheckingStall = false
    private var rebuildTask: Task<Void, Never>?
    private var rebuildAttempts = 0
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rateListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var excludedObjects: [AudioObjectID] = []
    /// The parameters currently in the engine (ramps start from here).
    private var applied = DJSound.flat
    private var hasHeardTapAudio = false

    private init() {
        settings.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applySound(animated: true) }
            .store(in: &cancellables)
        AppVolumeController.shared.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncExclusions() }
            .store(in: &cancellables)
    }

    // MARK: On / off

    func toggle() { setEnabled(!isOn) }

    func setEnabled(_ on: Bool) {
        if on {
            guard !isOn else { return }
            isOn = true
            isBypassed = false
            ensurePermissionThenStart()
        } else {
            guard isOn else { return }
            isOn = false
            fadeOutAndStop()
        }
    }

    private func ensurePermissionThenStart() {
        switch AmbientAudioPermission.preflight() {
        case .granted, .unknown:
            startRoute()
        case .denied:
            isOn = false
            status = .needsPermission
        case .notDetermined:
            status = .starting
            Task {
                let answer = await PermissionCenter.shared.request(.systemAudio, from: "SparkV DJ", openingSettings: false)
                guard self.isOn else { return }
                switch answer {
                case .denied, .restricted:
                    self.isOn = false
                    self.status = .needsPermission
                default:
                    self.startRoute()
                }
            }
        }
    }

    func openPermissionSettings() {
        PermissionCenter.shared.openSettings(.systemAudio, from: "SparkV DJ")
    }

    private func startRoute() {
        stopMonitor()
        generation += 1
        let myGeneration = generation
        status = .starting
        let ring = AmbientSampleRing(capacity: 1 << 16)
        let newRoute = DJRoute(ring: ring)
        let excluded = AppVolumeController.shared.routedProcessObjects
        excludedObjects = excluded
        // Core Audio can stall (AirPods connecting); give up after 4 s and
        // clean up whenever the start finally returns.
        let race = AmbientStartRace()
        DJAudio.queue.async {
            let result: Result<Void, Error> = Result { try newRoute.start(excluding: excluded) }
            Task { @MainActor in
                guard race.claim() else {
                    DJAudio.queue.async { newRoute.stop() }
                    return
                }
                self.routeStarted(newRoute, ring: ring, result: result, generation: myGeneration)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard race.claim() else { return }
            self.routeStarted(newRoute, ring: ring, result: .failure(DJError.engine("Core Audio didn’t respond")), generation: myGeneration)
        }
    }

    private func routeStarted(_ newRoute: DJRoute, ring: AmbientSampleRing, result: Result<Void, Error>, generation myGeneration: Int) {
        guard myGeneration == generation, isOn else {
            DJAudio.queue.async { newRoute.stop() }
            return
        }
        switch result {
        case .failure(let error):
            DJAudio.queue.async { newRoute.stop() }
            AppLog.log("DJ: start failed (\(error.localizedDescription))")
            if case DJError.sampleRateMismatch = error, rebuildAttempts < 3 {
                // Bluetooth headsets switch rate as they connect: try again.
                rebuildAttempts += 1
                scheduleRebuild(after: 1.2, reason: "rate settling")
                return
            }
            isOn = false
            status = .failed((error as? DJError)?.shortText ?? "Couldn’t start sound processing")
            refreshMonitor()
        case .success:
            route = newRoute
            sampleRate = newRoute.sampleRate
            outputName = Self.deviceName(newRoute.outputID)
            newRoute.state.set(wet: isBypassed ? 0 : 1)
            newRoute.state.set(master: 1)
            applied = .flat
            applySound(animated: false)
            let pump = DJAnalysisPump(ring: ring, sampleRate: newRoute.sampleRate)
            pump.start()
            self.pump?.stop()
            self.pump = pump
            status = .running
            listenForOutputChanges(device: newRoute.outputID)
            startWatchdog()
            checkHealth(newRoute)
            AppLog.log("DJ: on (\(Int(newRoute.sampleRate)) Hz)")
            objectWillChange.send()
        }
    }

    /// Crossfades to the untouched sound, then removes the tap (the Mac's
    /// own output takes over seamlessly).
    private func fadeOutAndStop() {
        generation += 1
        rampTask?.cancel()
        healthTask?.cancel()
        rebuildTask?.cancel()
        stopWatchdog()
        removeListeners()
        rebuildAttempts = 0
        guard let route else {
            status = .off
            refreshMonitor()
            return
        }
        self.route = nil
        route.state.set(wet: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            DJAudio.queue.async { route.stop() }
        }
        pump?.stop()
        pump = nil
        sampleRate = 0
        status = .off
        AppLog.log("DJ: off")
        refreshMonitor()
    }

    /// Quit: tap and aggregate are gone when this returns (bounded wait; the
    /// tap would die with the process anyway).
    func stopNow() {
        generation += 1
        isOn = false
        stopWatchdog()
        removeListeners()
        rampTask?.cancel()
        healthTask?.cancel()
        rebuildTask?.cancel()
        pump?.stop()
        pump = nil
        let route = self.route
        let monitor = self.monitor
        self.route = nil
        self.monitor = nil
        let done = DispatchSemaphore(value: 0)
        DJAudio.queue.async {
            route?.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
        if let monitor { AmbientAudioEngine.tearDown(monitor) }
        status = .off
    }

    // MARK: Rebuilds (output switched, rate changed, wake, stalled IO)

    private func scheduleRebuild(after delay: Double, reason: String) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isOn else { return }
            AppLog.log("DJ: rebuilding (\(reason))")
            self.tearDownRouteQuietly()
            self.startRoute()
        }
    }

    private func tearDownRouteQuietly() {
        generation += 1
        healthTask?.cancel()
        stopWatchdog()
        removeListeners()
        if let route {
            self.route = nil
            DJAudio.queue.async { route.stop() }
        }
    }

    private func listenForOutputChanges(device: AudioObjectID) {
        removeListeners()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.isOn, let route = self.route else { return }
                guard let uid = try? AmbientProcessTapSource.defaultOutputUID(), uid != route.outputUID else { return }
                self.rebuildAttempts = 0
                self.scheduleRebuild(after: 0.4, reason: "output changed")
            }
        }
        var address = MPAudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(MPAudioHAL.system, &address, DispatchQueue.main, block) == noErr {
            outputListener = block
        }
        let rate: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.isOn, let route = self.route else { return }
                if let now = AppGainRoute.nominalRate(of: device), abs(now - route.sampleRate) > 1 {
                    self.scheduleRebuild(after: 0.6, reason: "sample rate \(Int(now)) Hz")
                }
            }
        }
        var rateAddress = MPAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
        if device != kAudioObjectUnknown,
           AudioObjectAddPropertyListenerBlock(device, &rateAddress, DispatchQueue.main, rate) == noErr {
            rateListener = (device, rate)
        }
        if observers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tearDownRouteQuietly() }
            }))
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isOn else { return }
                    self.scheduleRebuild(after: 1.5, reason: "wake")
                }
            }))
        }
    }

    private func removeListeners() {
        if let outputListener {
            var address = MPAudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(MPAudioHAL.system, &address, DispatchQueue.main, outputListener)
            self.outputListener = nil
        }
        if case let (device, block)? = rateListener {
            var address = MPAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
            rateListener = nil
        }
        // Sleep/wake observers stay while DJ is on; removed when it's off.
        if !isOn {
            for (center, token) in observers { center.removeObserver(token) }
            observers.removeAll()
        }
    }

    // MARK: Health

    /// The IO block must run within 8 s; a tap that only delivers zeros
    /// while System Audio Recording isn't granted means macOS withholds the
    /// audio (everything would be silent): undo at once.
    private func checkHealth(_ route: DJRoute) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            // Bluetooth outputs (AirPods waking up) can take several seconds
            // before the first IO cycle; wait up to 8 s for it.
            var waited = 0
            while waited < 32, route.state.cycles.load(ordering: .relaxed) == 0 {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 1
                guard !Task.isCancelled else { return }
            }
            guard let self, !Task.isCancelled, self.route === route else { return }
            // The aggregate's IO idles while no app plays and starts by
            // itself with the first sound, so no cycles is only a failure
            // while something is actually playing.
            if route.state.cycles.load(ordering: .relaxed) == 0, await Self.othersArePlaying(ignoring: self.excludedObjects) {
                guard self.route === route else { return }
                AppLog.log("DJ: route isn’t running while audio plays; undoing it")
                self.isOn = false
                self.fadeOutAndStop()
                self.status = .failed("Couldn’t start on this output")
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self.route === route else { return }
            if route.state.audibleCycles.load(ordering: .relaxed) > 0 {
                self.hasHeardTapAudio = true
                return
            }
            if AmbientAudioPermission.preflight() != .granted, !self.hasHeardTapAudio {
                AppLog.log("DJ: tap delivers only silence; System Audio Recording looks off")
                self.isOn = false
                self.fadeOutAndStop()
                self.status = .needsPermission
            }
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        lastCycles = 0
        stalledSeconds = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watch() {
        guard let route, isOn, !isCheckingStall else { return }
        let cycles = route.state.cycles.load(ordering: .relaxed)
        guard cycles == lastCycles else {
            lastCycles = cycles
            stalledSeconds = 0
            if cycles > 200 { rebuildAttempts = 0 }
            return
        }
        // No new cycles: normal while nothing plays (the IO idles). A stall
        // only counts while some app is sending audio.
        isCheckingStall = true
        Task { [weak self] in
            let playing = await Self.othersArePlaying(ignoring: self?.excludedObjects ?? [])
            guard let self else { return }
            self.isCheckingStall = false
            guard self.route === route, self.isOn else { return }
            self.stalledSeconds = playing ? self.stalledSeconds + 1 : 0
            self.handleStall()
        }
    }

    private func handleStall() {
        if stalledSeconds >= 3 {
            stalledSeconds = 0
            rebuildAttempts += 1
            if rebuildAttempts > 3 {
                AppLog.log("DJ: IO keeps stalling; turning off")
                isOn = false
                fadeOutAndStop()
                status = .failed("The output stopped responding")
            } else {
                scheduleRebuild(after: 0.2, reason: "IO stalled")
            }
        }
    }

    /// Another app is sending audio right now (HAL read off the main thread).
    /// `ignoring`: process objects left out of the tap (App Volumes' apps).
    nonisolated static func othersArePlaying(ignoring: [AudioObjectID] = []) async -> Bool {
        let ignored = Set(ignoring)
        return await withCheckedContinuation { continuation in
            DJAudio.queue.async {
                let own = getpid()
                continuation.resume(returning: AppAudioProcesses.read(excludingPID: own)
                    .contains { $0.isRunningOutput && !ignored.contains($0.object) })
            }
        }
    }

    // MARK: App Volumes

    private func syncExclusions() {
        guard isOn, let route else { return }
        let now = AppVolumeController.shared.routedProcessObjects
        guard Set(now) != Set(excludedObjects) else { return }
        excludedObjects = now
        DJAudio.queue.async {
            let ok = route.updateExclusions(now)
            if !ok {
                Task { @MainActor in self.scheduleRebuild(after: 0.2, reason: "App Volumes changed") }
            }
        }
    }

    // MARK: Sound

    func choose(_ preset: DJPreset) {
        if preset == .custom, settings.preset != .custom {
            // Start Custom from what is playing now.
            settings.custom = settings.preset.sound ?? settings.custom
        }
        settings.preset = preset
    }

    /// Moving one band switches to Custom (seeded from the current preset).
    func setBand(_ index: Int, gain: Float) {
        guard index >= 0, index < DJBands.count else { return }
        if settings.preset != .custom {
            settings.custom = settings.preset.sound ?? settings.custom
            settings.preset = .custom
        }
        var sound = settings.custom
        sound.gains[index] = min(DJBands.range.upperBound, max(DJBands.range.lowerBound, gain))
        settings.custom = sound
    }

    func setCustom(width: Float? = nil, room: DJRoom? = nil, reverbMix: Float? = nil) {
        if settings.preset != .custom {
            settings.custom = settings.preset.sound ?? settings.custom
            settings.preset = .custom
        }
        var sound = settings.custom
        if let width { sound.width = width }
        if let room { sound.room = room }
        if let reverbMix { sound.reverbMix = reverbMix }
        settings.custom = sound
    }

    /// The bands shown in the EQ (the active preset's, at 100 %).
    var displayedGains: [Float] {
        (settings.preset.sound ?? settings.custom).gains
    }

    private func applySound(animated: Bool) {
        guard let route, let chain = route.chain else { return }
        let target = settings.sound
        route.state.set(width: target.width)
        rampTask?.cancel()
        let from = applied
        guard animated else {
            chain.set(room: target.room)
            chain.set(gains: target.gains, globalGain: DJMath.headroom(for: target.gains, reverbMix: target.reverbMix), reverbMix: target.reverbMix)
            applied = target
            return
        }
        rampTask = Task { [weak self] in
            // New room: fade the old reverb out first, swap, fade in.
            var start = from
            if target.room != chain.room, from.reverbMix > 0 {
                for step in 1...6 {
                    let k = Float(step) / 6
                    chain.set(gains: from.gains, globalGain: DJMath.headroom(for: from.gains, reverbMix: from.reverbMix * (1 - k)), reverbMix: from.reverbMix * (1 - k))
                    try? await Task.sleep(for: .milliseconds(20))
                    if Task.isCancelled { return }
                }
                start.reverbMix = 0
            }
            chain.set(room: target.room)
            let steps = 12
            for step in 1...steps {
                let k = Float(step) / Float(steps)
                let gains = zip(start.gains, target.gains).map { $0 + ($1 - $0) * k }
                let mix = start.reverbMix + (target.reverbMix - start.reverbMix) * k
                chain.set(gains: gains, globalGain: DJMath.headroom(for: gains, reverbMix: mix), reverbMix: mix)
                var now = target
                now.gains = gains
                now.reverbMix = mix
                self?.applied = now
                if step < steps { try? await Task.sleep(for: .milliseconds(18)) }
                if Task.isCancelled { return }
            }
            self?.applied = target
        }
    }

    // MARK: Listen-only analysis while the page shows and DJ is off

    func pageAppeared() {
        visibleCount += 1
        // Granted in System Settings since we last asked: clear the notice.
        if status == .needsPermission, AmbientAudioPermission.preflight() == .granted { status = .off }
        refreshMonitor()
    }

    func pageDisappeared() {
        visibleCount = max(0, visibleCount - 1)
        refreshMonitor()
    }

    private func refreshMonitor() {
        let wants = visibleCount > 0 && !isOn
        if wants, monitor == nil {
            switch AmbientAudioPermission.preflight() {
            case .granted, .unknown: break
            case .denied, .notDetermined: return
            }
            let ring = AmbientSampleRing(capacity: 1 << 16)
            let source = AmbientProcessTapSource(ring: ring)
            monitor = source
            let myGeneration = generation
            AmbientAudioEngine.halQueue.async {
                let rate = try? source.startBlocking()
                Task { @MainActor in
                    guard self.monitor === source, self.generation == myGeneration, let rate else {
                        if self.monitor === source { self.monitor = nil }
                        AmbientAudioEngine.tearDown(source)
                        return
                    }
                    let pump = DJAnalysisPump(ring: ring, sampleRate: rate)
                    pump.start()
                    self.pump?.stop()
                    self.pump = pump
                    self.objectWillChange.send()
                }
            }
        } else if !wants {
            stopMonitor()
        }
    }

    private func stopMonitor() {
        guard let monitor else { return }
        self.monitor = nil
        AmbientAudioEngine.tearDown(monitor)
        if !isOn {
            pump?.stop()
            pump = nil
        }
    }

    // MARK: Helpers

    /// Why the stats are empty (shown under the meter).
    var statsIdleText: String {
        switch AmbientAudioPermission.preflight() {
        case .denied, .notDetermined: "Needs System Audio Recording"
        default: isOn ? "Starting…" : "Play music to see the beat"
        }
    }

    /// macOS gives System Audio Recording to the copy of SparkV that Launch
    /// Services knows for `com.sparkv.app`. Leftover copies (an iCloud
    /// "SparkV 2.app") can hold the permission instead of this one.
    var otherCopyHoldingIdentity: URL? {
        guard let id = Bundle.main.bundleIdentifier,
              let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return registered.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL ? nil : registered
    }

    var permissionHelp: String {
        if let other = otherCopyHoldingIdentity {
            return "Another copy of SparkV (\(other.path)) is registered for this app, so macOS may give it the permission. Remove that copy, then allow SparkV in System Settings › Privacy & Security › Screen & System Audio Recording."
        }
        return "Allow SparkV in System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."
    }

    /// Counters for the self-test: IO cycles, failed renders, peaks since
    /// the last call. nil while no route runs. Levels only, never audio.
    func selfTestSnapshot() -> (cycles: Int, failures: Int, output: Float, input: Float)? {
        guard let route else { return nil }
        let peaks = route.state.takePeaks()
        return (route.state.cycles.load(ordering: .relaxed), route.state.renderFailures.load(ordering: .relaxed),
                peaks.output, peaks.input)
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        guard device != kAudioObjectUnknown else { return "" }
        return MPAudioHAL.string(device, kAudioObjectPropertyName) ?? ""
    }
}
