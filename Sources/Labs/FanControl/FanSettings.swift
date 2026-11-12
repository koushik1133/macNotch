import Foundation

// Fan Control settings and formatting. Read-only: there are no fan modes,
// curves or presets (macOS controls the fans).

struct FanSettings: Codable, Equatable, Sendable {
    enum ActivityStyle: String, Codable, Sendable, CaseIterable {
        /// Fan speed and the hottest CPU reading beside the notch.
        case always
        case never
    }

    var activity: ActivityStyle = .never
    var fahrenheit = false
    var showAllSensors = false

    init() {}

    /// Tolerant: settings saved by older builds (with modes, presets and a
    /// "whileManual" activity) still load; unknown values fall back.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activity = (try? c.decode(ActivityStyle.self, forKey: .activity)) ?? .never
        fahrenheit = (try? c.decode(Bool.self, forKey: .fahrenheit)) ?? false
        showAllSensors = (try? c.decode(Bool.self, forKey: .showAllSensors)) ?? false
    }
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
