import Foundation

// SparkV side, Foundation only: what the user asked each fan to do, the
// sensor-based curve, presets and their storage. Pure and unit tested.

/// How one fan is controlled. Auto is always the default.
enum FanControlMode: Codable, Equatable, Sendable {
    /// macOS controls the fan (thermalmonitord / SMC firmware).
    case auto
    /// A constant speed, clamped to the fan's own [min, max].
    case constant(rpm: Double)
    /// Linear curve on a sensor: the fan's minimum at `startC` and below,
    /// its maximum at `maxC` and above.
    case sensor(id: String, startC: Double, maxC: Double)

    var isManual: Bool { self != .auto }

    var shortTitle: String {
        switch self {
        case .auto: "Auto"
        case .constant: "Constant"
        case .sensor: "Sensor"
        }
    }
}

enum FanCurveMath {
    /// RPM for `temperature` on the linear curve, always inside `limits`.
    static func target(temperature: Double, startC: Double, maxC: Double, limits: ClosedRange<Double>) -> Double {
        guard temperature.isFinite else { return limits.upperBound }
        guard maxC > startC else { return temperature >= maxC ? limits.upperBound : limits.lowerBound }
        let fraction = min(max((temperature - startC) / (maxC - startC), 0), 1)
        return clamp(limits.lowerBound + fraction * (limits.upperBound - limits.lowerBound), to: limits)
    }

    /// Never below the minimum, never above the maximum. Non-finite input
    /// gives the maximum (the safe direction for a fan).
    static func clamp(_ rpm: Double, to limits: ClosedRange<Double>) -> Double {
        guard rpm.isFinite else { return limits.upperBound }
        return min(max(rpm, limits.lowerBound), limits.upperBound)
    }

    /// Rounds to `step` RPM, then clamps (so rounding can never go below
    /// the minimum). The limits themselves are kept exact.
    static func quantize(_ rpm: Double, step: Double = 25, limits: ClosedRange<Double>) -> Double {
        let clamped = clamp(rpm, to: limits)
        guard step > 0, clamped != limits.lowerBound, clamped != limits.upperBound else { return clamped }
        return clamp((clamped / step).rounded() * step, to: limits)
    }

    /// Valid curve settings: start below max, both within 20...110 °C.
    static func sanitizedCurve(startC: Double, maxC: Double) -> (startC: Double, maxC: Double) {
        let start = min(max(startC.isFinite ? startC : 50, 20), 105)
        let maxT = min(max(maxC.isFinite ? maxC : 85, start + 5), 110)
        return (start, maxT)
    }
}

/// Follows a curve without hunting: a rising temperature raises the speed
/// at once; a falling one lowers it only after the temperature dropped
/// `hysteresisC` below the reading that set the current speed. Changes
/// smaller than `minimumStep` are ignored unless they reach a limit.
struct FanCurveFollower: Equatable, Sendable {
    var hysteresisC = 2.0
    var minimumStep = 50.0
    private(set) var lastTarget: Double?
    private(set) var lastTemperature: Double?

    init(hysteresisC: Double = 2.0, minimumStep: Double = 50.0) {
        self.hysteresisC = hysteresisC
        self.minimumStep = minimumStep
    }

    mutating func reset() {
        lastTarget = nil
        lastTemperature = nil
    }

    mutating func next(temperature: Double, startC: Double, maxC: Double, limits: ClosedRange<Double>) -> Double {
        let raw = FanCurveMath.quantize(
            FanCurveMath.target(temperature: temperature, startC: startC, maxC: maxC, limits: limits),
            limits: limits)
        guard let current = lastTarget, let previousTemp = lastTemperature, limits.contains(current) else {
            lastTarget = raw
            lastTemperature = temperature
            return raw
        }
        if raw < current, temperature > previousTemp - hysteresisC {
            return current
        }
        let atLimit = raw == limits.lowerBound || raw == limits.upperBound
        if abs(raw - current) < minimumStep, !atLimit {
            return current
        }
        lastTarget = raw
        lastTemperature = temperature
        return raw
    }
}

// MARK: - Presets

struct FanPreset: Codable, Identifiable, Equatable, Sendable {
    enum Builtin: String, Codable, Sendable, CaseIterable {
        case auto, quiet, performance, fullBlast
    }

    let id: String
    var name: String
    let builtin: Builtin?
    /// Per fan, by index (custom presets). Missing fans use Auto.
    var modes: [FanControlMode]

    static let hottestCPU = "agg.cpu.max"

    static let builtins: [FanPreset] = Builtin.allCases.map {
        FanPreset(id: "builtin.\($0.rawValue)", name: $0.title, builtin: $0, modes: [])
    }

    /// The modes this preset gives `fans` (built-ins adapt to each fan's limits).
    func modes(for fans: [FanInfo]) -> [FanControlMode] {
        fans.map { fan in
            switch builtin {
            case .auto: return .auto
            case .quiet: return .sensor(id: Self.hottestCPU, startC: 70, maxC: 95)
            case .performance: return .sensor(id: Self.hottestCPU, startC: 50, maxC: 80)
            case .fullBlast:
                guard let limits = fan.validLimits else { return .auto }
                return .constant(rpm: limits.upperBound)
            case nil:
                return modes.indices.contains(fan.index) ? modes[fan.index] : .auto
            }
        }
    }

    var subtitle: String {
        switch builtin {
        case .auto: "macOS controls the fans"
        case .quiet: "Hottest CPU 70 → 95 °C"
        case .performance: "Hottest CPU 50 → 80 °C"
        case .fullBlast: "Every fan at its maximum"
        case nil: "Saved preset"
        }
    }
}

extension FanPreset.Builtin {
    var title: String {
        switch self {
        case .auto: "Auto"
        case .quiet: "Quiet"
        case .performance: "Performance"
        case .fullBlast: "Full Blast"
        }
    }
}

// MARK: - Settings

struct FanSettings: Codable, Equatable, Sendable {
    enum ActivityStyle: String, Codable, Sendable, CaseIterable {
        /// Only while some fan is under manual control (the default).
        case whileManual
        case always
        case never
    }

    /// Re-apply the last fan modes when SparkV starts. Off: every launch
    /// starts on Auto.
    var restoreOnLaunch = false
    var activity: ActivityStyle = .whileManual
    var fahrenheit = false
    var showAllSensors = false
    /// The last modes, by fan index (restored only with `restoreOnLaunch`).
    var lastModes: [FanControlMode] = []
    var customPresets: [FanPreset] = []
}

/// Where settings live. The app uses UserDefaults; tests use memory.
protocol FanSettingsStore: AnyObject {
    func load() -> FanSettings
    func save(_ settings: FanSettings)
}

final class FanUserDefaultsStore: FanSettingsStore {
    private let defaults: UserDefaults
    private let key = "SparkV.fans.settings"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> FanSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(FanSettings.self, from: data) else { return FanSettings() }
        return settings
    }

    func save(_ settings: FanSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

final class FanMemoryStore: FanSettingsStore {
    var settings: FanSettings
    init(_ settings: FanSettings = FanSettings()) { self.settings = settings }
    func load() -> FanSettings { settings }
    func save(_ settings: FanSettings) { self.settings = settings }
}

enum FanFormat {
    static func rpm(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value < 50 { return "Off" }
        return "\(Int(value.rounded()))"
    }

    /// "2.4k" for tight spaces.
    static func compactRPM(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value < 50 { return "Off" }
        if value < 1000 { return "\(Int(value.rounded()))" }
        return String(format: "%.1fk", value / 1000)
    }

    static func temperature(_ celsius: Double?, fahrenheit: Bool) -> String {
        guard let celsius else { return "--" }
        if fahrenheit { return "\(Int((celsius * 9 / 5 + 32).rounded()))°F" }
        return "\(Int(celsius.rounded()))°C"
    }
}
