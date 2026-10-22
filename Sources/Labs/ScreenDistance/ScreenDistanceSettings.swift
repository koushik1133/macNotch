import Foundation
import IOKit.ps

/// Everything Screen Distance remembers, in UserDefaults under
/// "screenDistance.*". No images, no face data: only preferences, one
/// calibration number and per-day totals.
struct ScreenDistanceSettings: Equatable, Sendable {
    static let thresholdRange: ClosedRange<Double> = 30...60
    static let intervalChoices: [TimeInterval] = [5, 10, 30]

    var isEnabled = false
    var thresholdCM: Double = 40
    /// Seconds between bursts while you are at a safe distance.
    var intervalSeconds: TimeInterval = 5
    /// Esc (and a Skip button) end the notice even while too close.
    var allowSkipping = false
    /// Pause while on battery below 20%.
    var pauseOnLowBattery = true
    /// Full-screen notice; off shows only the band under the notch.
    var showsFullScreenAlert = true
    /// Measured-to-real factor from calibration; 1 = uncalibrated.
    var calibrationScale: Double = 1
    var snoozedUntil: Date?

    enum Key {
        static let enabled = "screenDistance.enabled"
        static let threshold = "screenDistance.thresholdCM"
        static let interval = "screenDistance.intervalSeconds"
        static let allowSkipping = "screenDistance.allowSkipping"
        static let pauseOnLowBattery = "screenDistance.pauseOnLowBattery"
        static let fullScreen = "screenDistance.fullScreenAlert"
        static let calibration = "screenDistance.calibrationScale"
        static let snoozedUntil = "screenDistance.snoozedUntil"
        static let stats = "screenDistance.stats"
    }

    static func load(from defaults: UserDefaults) -> ScreenDistanceSettings {
        var s = ScreenDistanceSettings()
        s.isEnabled = defaults.bool(forKey: Key.enabled)
        if let v = defaults.object(forKey: Key.threshold) as? Double { s.thresholdCM = clampThreshold(v) }
        if let v = defaults.object(forKey: Key.interval) as? Double { s.intervalSeconds = min(60, max(3, v)) }
        s.allowSkipping = defaults.bool(forKey: Key.allowSkipping)
        if let v = defaults.object(forKey: Key.pauseOnLowBattery) as? Bool { s.pauseOnLowBattery = v }
        if let v = defaults.object(forKey: Key.fullScreen) as? Bool { s.showsFullScreenAlert = v }
        if let v = defaults.object(forKey: Key.calibration) as? Double, v.isFinite { s.calibrationScale = min(2, max(0.5, v)) }
        s.snoozedUntil = defaults.object(forKey: Key.snoozedUntil) as? Date
        return s
    }

    func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(thresholdCM, forKey: Key.threshold)
        defaults.set(intervalSeconds, forKey: Key.interval)
        defaults.set(allowSkipping, forKey: Key.allowSkipping)
        defaults.set(pauseOnLowBattery, forKey: Key.pauseOnLowBattery)
        defaults.set(showsFullScreenAlert, forKey: Key.fullScreen)
        defaults.set(calibrationScale, forKey: Key.calibration)
        if let snoozedUntil { defaults.set(snoozedUntil, forKey: Key.snoozedUntil) } else { defaults.removeObject(forKey: Key.snoozedUntil) }
    }

    static func clampThreshold(_ value: Double) -> Double {
        min(thresholdRange.upperBound, max(thresholdRange.lowerBound, value.isFinite ? value : 40))
    }

    static func loadStats(from defaults: UserDefaults) -> ScreenDistanceStatsLog {
        guard let data = defaults.data(forKey: Key.stats),
              let log = try? JSONDecoder().decode(ScreenDistanceStatsLog.self, from: data)
        else { return ScreenDistanceStatsLog() }
        return log
    }

    static func saveStats(_ log: ScreenDistanceStatsLog, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: Key.stats) }
    }
}

/// Reads the battery once per check (no notifications kept open).
enum ScreenDistancePower {
    /// True when running on battery at or below `percent`.
    static func isOnLowBattery(percent: Int = 20) -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        guard providing == kIOPSBatteryPowerValue else { return false }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let type = info[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return current * 100 / max <= percent
        }
        return false
    }
}
