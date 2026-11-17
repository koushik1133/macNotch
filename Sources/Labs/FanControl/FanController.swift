import AppKit
import Combine
import Foundation

/// What the live activity shows (FanActivity.swift turns it into a LiveActivity).
struct FanActivityState: Equatable {
    var rpms: [Double?]
    var hottest: Double?
    var hottestName: String?
    var fahrenheit: Bool
}

/// Fan Control, read-only: fan speeds and temperatures from the SMC and HID
/// sensors. macOS controls the fans; SparkV never writes to the SMC and has
/// no privileged helper.
@MainActor
final class FanController: ObservableObject {
    static let shared = FanController()

    @Published private(set) var snapshot = FanSnapshot()
    @Published var settings: FanSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if settings.activity != oldValue.activity { publishActivity(); updateLoop() }
            if settings.showAllSensors != oldValue.showAllSensors { tick() }
        }
    }

    /// LiveActivity hook (set by FanActivity.swift's `connect(activities:)`).
    var activitySink: ((FanActivityState?) -> Void)?

    private let sampler: FanSensorSampler
    private let store: FanSettingsStore
    private let observesSystem: Bool
    private var sampling = false
    private var viewers = 0
    private var started = false
    private var sleeping = false
    private var loop: Task<Void, Never>?
    private var loopInterval: TimeInterval?
    private var observers: [NSObjectProtocol] = []
    private var energyObserver: NSObjectProtocol?
    private var lastActivity: FanActivityState??

    init(sampler: FanSensorSampler = FanSensorSampler(),
         store: FanSettingsStore = FanUserDefaultsStore(),
         observesSystem: Bool = true) {
        self.sampler = sampler
        self.store = store
        self.observesSystem = observesSystem
        settings = store.load()
    }

    // MARK: Read-outs

    var fans: [FanInfo] { snapshot.fans }
    var hasFans: Bool { !snapshot.fans.isEmpty }

    func name(for fan: Int) -> String {
        snapshot.fans.count == 1 ? "Fan" : "Fan \(fan + 1)"
    }

    func temperatureText(_ celsius: Double?) -> String {
        FanFormat.temperature(celsius, fahrenheit: settings.fahrenheit)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if observesSystem { observeSystem() }
        // One pass to learn the fans; then the loop runs only while needed.
        tick()
        updateLoop()
    }

    func stop() {
        guard started else { return }
        started = false
        loop?.cancel()
        loop = nil
        loopInterval = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let energyObserver { NotificationCenter.default.removeObserver(energyObserver) }
        energyObserver = nil
        activitySink?(nil)
    }

    /// Views on screen call these so sampling runs only while something shows it.
    func attachViewer() {
        viewers += 1
        if viewers == 1 { tick() }
        updateLoop()
    }

    func detachViewer() {
        viewers = max(0, viewers - 1)
        updateLoop()
    }

    // MARK: Loop

    private var desiredInterval: TimeInterval? {
        guard !sleeping else { return nil }
        if viewers > 0 { return 1.5 }
        // The notch readout (Show in the Notch: Always): slower in Low Power Mode.
        if settings.activity == .always, hasFans { return SparkVEnergy.shared.isLowPowerMode ? 9 : 3 }
        return nil
    }

    private func updateLoop() {
        let wanted = started ? desiredInterval : nil
        guard wanted != loopInterval else { return }
        loop?.cancel()
        loop = nil
        loopInterval = wanted
        guard let wanted else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(wanted * 1000)))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private var scope: FanSampleScope {
        if viewers > 0 { return settings.showAllSensors ? .all : .standard }
        return .minimal(["agg.cpu.max"])
    }

    /// One sampling pass; the activity follows its result.
    func tick() {
        guard !sampling else { return }
        sampling = true
        sampler.sample(scope) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.sampling = false
                self.apply(snapshot)
            }
        }
    }

    /// Applies a reading (public for tests and harnesses).
    func apply(_ newSnapshot: FanSnapshot) {
        let hadFans = hasFans
        snapshot = newSnapshot
        if hadFans != hasFans { updateLoop() }
        publishActivity()
    }

    // MARK: System events

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = true
                self?.updateLoop()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = false
                self?.updateLoop()
                self?.tick()
            }
        })
        // Low Power Mode changes the background pace (`desiredInterval`).
        energyObserver = NotificationCenter.default.addObserver(forName: SparkVEnergy.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLoop() }
        }
    }

    // MARK: Live activity

    var activityState: FanActivityState? {
        guard hasFans, settings.activity == .always else { return nil }
        let hottest = snapshot.hottestCPU
        return FanActivityState(rpms: snapshot.fans.map(\.actual),
                                hottest: hottest?.celsius, hottestName: hottest?.group.title,
                                fahrenheit: settings.fahrenheit)
    }

    private func publishActivity() {
        let state = activityState
        if let last = lastActivity, last == state { return }
        lastActivity = .some(state)
        activitySink?(state)
    }
}
