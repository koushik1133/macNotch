import AppKit
import SwiftUI
import Combine
import Foundation
import IOKit.ps

/// One place that knows how hard SparkV may work right now: Low Power Mode,
/// the thermal state and whether the displays are asleep. Event-driven only
/// (ProcessInfo and NSWorkspace notifications); it never polls.
///
/// - Low Power Mode or a serious/critical thermal state is "constrained":
///   decorative frame rates halve and refresh loops wait three times longer.
/// - A serious/critical thermal state or sleeping displays "pause
///   decoration": decorative motion shows its still (Reduce Motion) look and
///   periodic refreshes skip their work.
///
/// Views observe `shared`; controllers read it when they schedule the next
/// wait, or subscribe to `didChange` to restart a loop at the new pace.
@MainActor
final class SparkVEnergy: ObservableObject {
    static let shared = SparkVEnergy()

    /// Posted on the main queue whenever any of the inputs change.
    static let didChange = Notification.Name("SparkVEnergyDidChange")

    @Published private(set) var isLowPowerMode: Bool
    @Published private(set) var thermalState: ProcessInfo.ThermalState
    @Published private(set) var screensAsleep = false
    /// Settings › System › Energy. Off by default.
    @Published var batterySaver: SparkVBatterySaver {
        didSet {
            guard batterySaver != oldValue else { return }
            UserDefaults.standard.set(batterySaver.rawValue, forKey: SparkVBatterySaver.defaultsKey)
            updatePowerSourceWatch()
            AppLog.log("Energy: battery saver \(batterySaver.rawValue)")
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
    /// Running on battery (only tracked while Battery Saver is On Battery).
    @Published private(set) var isOnBattery = false
    private var powerSource: CFRunLoopSource?

    /// How much longer a refresh loop waits while constrained.
    static let constrainedIntervalFactor: Double = 3

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var memorySource: DispatchSourceMemoryPressure?
    private var purges: [@MainActor () -> Void] = []

    private init() {
        let info = ProcessInfo.processInfo
        isLowPowerMode = info.isLowPowerModeEnabled
        thermalState = info.thermalState
        batterySaver = UserDefaults.standard.string(forKey: SparkVBatterySaver.defaultsKey)
            .flatMap(SparkVBatterySaver.init(rawValue:)) ?? .off
        observe()
        updatePowerSourceWatch()
        watchMemoryPressure()
    }

    // MARK: Memory pressure

    /// Runs `purge` on the main actor whenever macOS reports memory pressure
    /// (warning or critical). For caches that can be rebuilt; register once.
    func onMemoryPressure(_ purge: @escaping @MainActor () -> Void) {
        purges.append(purge)
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let footprint = Self.footprintMB().map { "\($0) MB" } ?? "unknown"
                AppLog.log("Energy: memory pressure (footprint \(footprint)), purging \(self.purges.count) caches")
                self.purges.forEach { $0() }
            }
        }
        source.resume()
        memorySource = source
    }

    /// SparkV's physical footprint (TASK_VM_INFO phys_footprint), the number
    /// Activity Monitor shows as Memory. Read on memory pressure only: no
    /// timer.
    nonisolated static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    // MARK: State

    var isThermallyLimited: Bool { thermalState == .serious || thermalState == .critical }

    /// Low Power Mode or a hot Mac: slow down.
    var isConstrained: Bool { isLowPowerMode || isThermallyLimited || batterySaverActive }

    /// The user's Battery Saver is in effect right now.
    var batterySaverActive: Bool {
        switch batterySaver {
        case .off: false
        case .onBattery: isOnBattery
        case .always: true
        }
    }

    /// Hot Mac or nobody can see the screen: stop decorative motion.
    var pausesDecoration: Bool { isThermallyLimited || screensAsleep || batterySaverActive }

    // MARK: Pacing helpers

    /// Minimum frame interval for a decorative `TimelineView(.animation)`:
    /// `base` (nil means display rate, taken as 60 fps), doubled while
    /// constrained.
    func frameInterval(_ base: Double?) -> Double? {
        guard isConstrained else { return base }
        return (base ?? 1.0 / 60) * 2
    }

    /// Wait before the next periodic refresh, longer while constrained.
    func interval(_ base: TimeInterval) -> TimeInterval {
        isConstrained ? base * Self.constrainedIntervalFactor : base
    }

    /// `interval(_:)` for `Duration`-based sleeps.
    func duration(_ base: Duration) -> Duration {
        isConstrained ? base * Int(Self.constrainedIntervalFactor) : base
    }

    // MARK: Observation

    private func observe() {
        let center = NotificationCenter.default
        tokens.append((center, center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }))
        tokens.append((center, center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        let sleepEvents: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
        ]
        for (name, asleep) in sleepEvents {
            tokens.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensAsleep(asleep) }
            }))
        }
    }

    // MARK: Power source (Battery Saver: On Battery)

    private func updatePowerSourceWatch() {
        if batterySaver == .onBattery {
            guard powerSource == nil else { return }
            let callback: IOPowerSourceCallbackType = { _ in
                // Added to the main run loop: runs on the main thread.
                MainActor.assumeIsolated { SparkVEnergy.shared.powerSourceChanged() }
            }
            guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
            powerSourceChanged()
        } else if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
            if isOnBattery { isOnBattery = false }
        }
    }

    private func powerSourceChanged() {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = snapshot.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let onBattery = type == kIOPMBatteryPowerKey
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        let lowPower = info.isLowPowerModeEnabled
        let thermal = info.thermalState
        guard lowPower != isLowPowerMode || thermal != thermalState else { return }
        isLowPowerMode = lowPower
        thermalState = thermal
        AppLog.log("Energy: low power \(lowPower ? "on" : "off"), thermal \(Self.describe(thermal))")
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func setScreensAsleep(_ asleep: Bool) {
        guard asleep != screensAsleep else { return }
        screensAsleep = asleep
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Settings › System › Energy › Battery Saver: decorative motion rests and
/// refresh loops slow down, like Low Power Mode, by the user's choice.
enum SparkVBatterySaver: String, CaseIterable, Identifiable {
    case off, onBattery, always

    static let defaultsKey = "SparkV.energy.batterySaver"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .onBattery: "On Battery"
        case .always: "Always"
        }
    }
}

/// Settings › System: the Battery Saver choice.
struct EnergySettingsSection: View {
    @ObservedObject private var energy = SparkVEnergy.shared

    var body: some View {
        Section {
            Picker("Battery Saver", selection: $energy.batterySaver) {
                ForEach(SparkVBatterySaver.allCases) { Text($0.title).tag($0) }
            }
            if energy.isLowPowerMode {
                Text("Low Power Mode is on, so SparkV is already saving energy.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Energy")
        } footer: {
            Text("Battery Saver rests decorative motion (level bars, scrolling titles, theme effects) and checks for changes less often. Timers, countdowns and alerts are not affected.")
        }
    }
}
