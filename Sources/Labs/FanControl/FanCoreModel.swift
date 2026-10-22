import Foundation

// Shared by SparkV and the privileged helper: fan and sensor discovery on
// top of an `FanSMCBackend`. Foundation only.

// MARK: - Fans

/// One fan as the SMC reports it. RPM values are nil when unreadable.
struct FanInfo: Codable, Sendable, Equatable, Identifiable {
    let index: Int
    var actual: Double?
    var target: Double?
    /// The fan's own minimum and maximum (F<i>Mn / F<i>Mx).
    var minimum: Double?
    var maximum: Double?
    /// F<i>Md: 0 automatic, 1 manual (forced), 3 system-managed (Apple silicon).
    var mode: Int?

    var id: Int { index }

    /// Limits a manual speed can use: both known, minimum above zero and
    /// maximum above minimum. Without them manual control is refused.
    var validLimits: ClosedRange<Double>? {
        guard let minimum, let maximum, minimum > 0, maximum > minimum, maximum < 20_000 else { return nil }
        return minimum...maximum
    }
}

enum FanSMCKeys {
    static let count = FanSMCCode("FNum")!
    /// Diagnostic "force/test" flag (M4 generation): writing 1 lets the
    /// firmware accept a manual mode while thermalmonitord holds mode 3.
    static let test = FanSMCCode("Ftst")!
    /// Older Intel Macs: a bitmask of forced fans instead of F<i>Md.
    static let forcedMask = FanSMCCode("FS! ")!

    static func actual(_ i: Int) -> FanSMCCode? { .fan(i, "Ac") }
    static func target(_ i: Int) -> FanSMCCode? { .fan(i, "Tg") }
    static func minimum(_ i: Int) -> FanSMCCode? { .fan(i, "Mn") }
    static func maximum(_ i: Int) -> FanSMCCode? { .fan(i, "Mx") }

    /// "F<i>Md" on Intel, M1-M4; "F<i>md" on M5. nil if neither exists.
    static func mode(_ i: Int, in smc: FanSMCBackend) -> FanSMCCode? {
        for suffix in ["Md", "md"] {
            if let key = FanSMCCode.fan(i, suffix), smc.has(key) { return key }
        }
        return nil
    }
}

enum FanSMCReader {
    /// FNum, limited to the 10 fans the key scheme can address.
    static func fanCount(_ smc: FanSMCBackend) -> Int {
        guard let n = smc.number(FanSMCKeys.count), n.isFinite else { return 0 }
        return Int(min(max(n, 0), 10))
    }

    static func fan(_ i: Int, smc: FanSMCBackend) -> FanInfo {
        func value(_ key: FanSMCCode?) -> Double? { key.flatMap { smc.number($0) } }
        var mode: Int?
        if let key = FanSMCKeys.mode(i, in: smc), let m = smc.number(key) {
            mode = Int(m)
        } else if let mask = smc.number(FanSMCKeys.forcedMask) {
            mode = (Int(mask) >> i) & 1
        }
        return FanInfo(index: i,
                       actual: value(FanSMCKeys.actual(i)).map { max(0, $0) },
                       target: value(FanSMCKeys.target(i)),
                       minimum: value(FanSMCKeys.minimum(i)),
                       maximum: value(FanSMCKeys.maximum(i)),
                       mode: mode)
    }

    static func fans(_ smc: FanSMCBackend) -> [FanInfo] {
        (0..<fanCount(smc)).map { fan($0, smc: smc) }
    }
}

// MARK: - Sensors

enum FanSensorGroup: String, Codable, Sendable, CaseIterable {
    case cpu, gpu, soc, memory, storage, battery, power, airflow, other

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .memory: "Memory"
        case .storage: "SSD"
        case .battery: "Battery"
        case .power: "Power"
        case .airflow: "Enclosure"
        case .other: "Other"
        }
    }
}

enum FanSensorCatalog {
    /// Sensor reads of 0, negative, 127/128 sentinel or absurd values are dropped.
    static func isPlausible(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > 1 && celsius < 125
    }

    /// Apple silicon reports temperatures as `flt ` (and some as `ioft`);
    /// Intel Macs use fixed point (`sp78`). Key meanings differ between the
    /// two, so every lookup takes the key's type into account.
    static func isAppleSiliconType(_ type: FanSMCCode?) -> Bool {
        guard let type else { return false }
        return type == FanSMCCodec.flt || type.string == "ioft"
    }

    /// Well-known SMC temperature keys, collected from public SMC key
    /// lists. Anything not listed is grouped by prefix.
    static let knownCommon: [String: (name: String, group: FanSensorGroup)] = [
        "TB0T": ("Battery", .battery), "TB1T": ("Battery Cell 1", .battery), "TB2T": ("Battery Cell 2", .battery),
        "TB3T": ("Battery Cell 3", .battery), "TW0P": ("Wi-Fi", .other),
        "Ts0P": ("Palm Rest", .airflow), "Ts1P": ("Palm Rest 2", .airflow),
    ]
    static let knownIntel: [String: (name: String, group: FanSensorGroup)] = [
        "TC0P": ("CPU Proximity", .cpu), "TC0D": ("CPU Die", .cpu), "TC0E": ("CPU Die (PECI)", .cpu),
        "TC0F": ("CPU Die (Filtered)", .cpu), "TC0H": ("CPU Heatsink", .cpu),
        "TC1C": ("CPU Core 1", .cpu), "TC2C": ("CPU Core 2", .cpu), "TC3C": ("CPU Core 3", .cpu),
        "TC4C": ("CPU Core 4", .cpu), "TC5C": ("CPU Core 5", .cpu), "TC6C": ("CPU Core 6", .cpu),
        "TC7C": ("CPU Core 7", .cpu), "TC8C": ("CPU Core 8", .cpu),
        "TG0P": ("GPU Proximity", .gpu), "TG0D": ("GPU Die", .gpu), "TG0H": ("GPU Heatsink", .gpu),
        "TPCD": ("Platform Controller Hub", .soc), "TM0P": ("Memory Proximity", .memory),
        "TH0P": ("SSD Proximity", .storage), "TA0P": ("Ambient", .airflow),
        "TaLC": ("Airflow Left", .airflow), "TaRC": ("Airflow Right", .airflow),
    ]
    static let knownAppleSilicon: [String: (name: String, group: FanSensorGroup)] = [
        "TH0x": ("SSD", .storage), "TH0a": ("SSD (A)", .storage), "TH0b": ("SSD (B)", .storage),
        "TaLP": ("Airflow Left", .airflow), "TaRF": ("Airflow Right", .airflow),
    ]

    /// Every key with a known name, for the sampler's standard pass.
    static var knownKeys: Set<String> {
        Set(knownCommon.keys).union(knownIntel.keys).union(knownAppleSilicon.keys)
    }

    static func known(_ key: String, type: FanSMCCode?) -> (name: String, group: FanSensorGroup)? {
        if let common = knownCommon[key] { return common }
        return isAppleSiliconType(type) ? knownAppleSilicon[key] : knownIntel[key]
    }

    /// Group for any temperature key, nil if it is not a temperature key.
    static func group(smcKey key: String, type: FanSMCCode? = nil) -> FanSensorGroup? {
        guard key.utf8.count == 4, key.hasPrefix("T") else { return nil }
        if let known = known(key, type: type) { return known.group }
        let appleSilicon = isAppleSiliconType(type)
        switch String(key.prefix(2)) {
        // Apple silicon: Tp/Te performance and efficiency cores, Tf (M3+),
        // TC cluster readings. Intel: TC.
        case "Tp", "Te", "Tf", "TC": return .cpu
        case "Tg": return .gpu
        // Intel GPU; on Apple silicon TG0x are low ioft readings, not the GPU.
        case "TG": return appleSilicon ? .other : .gpu
        case "Tm", "TM": return .memory
        case "TH": return .storage
        case "TB": return .battery
        case "TP", "TR", "TV", "TD": return .power
        case "Ta", "TA", "Ts": return .airflow
        default: return .other
        }
    }

    /// CPU and GPU die sensors: the ones the helper's thermal failsafe watches.
    static func isDie(smcKey key: String, type: FanSMCCode? = nil) -> Bool {
        let g = group(smcKey: key, type: type)
        guard g == .cpu || g == .gpu else { return false }
        // Proximity and heatsink sensors read lower than the die; keep them
        // out so the failsafe watches the hottest real silicon.
        return !["TC0P", "TC0H", "TG0P", "TG0H"].contains(key)
    }

    static func name(smcKey key: String, type: FanSMCCode? = nil) -> String {
        if let known = known(key, type: type) { return known.name }
        return "\(group(smcKey: key, type: type)?.title ?? "Sensor") \(key)"
    }

    /// Friendly names for the Apple silicon HID sensors.
    static func classify(hidName raw: String) -> (name: String, group: FanSensorGroup) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let number = name.split(separator: " ").last.flatMap { Int($0.filter(\.isNumber)) }
        let suffix = number.map { " \($0)" } ?? ""
        let lower = name.lowercased()
        if lower.hasPrefix("pacc") { return ("CPU Performance Core\(suffix)", .cpu) }
        if lower.hasPrefix("eacc") { return ("CPU Efficiency Core\(suffix)", .cpu) }
        if lower.hasPrefix("gpu") { return ("GPU\(suffix)", .gpu) }
        if lower.hasPrefix("soc") { return ("SoC\(suffix)", .soc) }
        if lower.hasPrefix("ane") { return ("Neural Engine\(suffix)", .soc) }
        if lower.hasPrefix("isp") { return ("Image Processor\(suffix)", .soc) }
        if lower.contains("nand") { return ("SSD (NAND)", .storage) }
        if lower.contains("battery") { return ("Battery (Gauge)", .battery) }
        if lower.hasPrefix("pmu tdie") { return ("Power Manager Die\(suffix)", .power) }
        if lower.hasPrefix("pmu tdev") { return ("Power Manager Device\(suffix)", .power) }
        if lower.hasPrefix("pmu") { return ("Power Manager \(name.dropFirst(4))", .power) }
        return (name, .other)
    }
}

/// Discovers the SMC temperature keys once (enumerating ~2000 keys takes a
/// few milliseconds) and reads only those afterwards.
final class FanSMCSensorList: @unchecked Sendable {
    struct Sensor: Sendable, Equatable {
        let key: FanSMCCode
        let group: FanSensorGroup
        let isDie: Bool
        let name: String
        /// Has a real name (not just "CPU Tp09").
        let isNamed: Bool
    }

    private(set) var sensors: [Sensor] = []

    init(smc: FanSMCBackend) {
        let count = min(smc.keyCount(), 10_000)
        var found: [Sensor] = []
        for i in 0..<count {
            guard let key = try? smc.key(at: i) else { continue }
            let name = key.string
            guard name.hasPrefix("T"), let value = try? smc.read(key), FanSMCCodec.isNumeric(value.type),
                  let group = FanSensorCatalog.group(smcKey: name, type: value.type),
                  let celsius = value.number, FanSensorCatalog.isPlausible(celsius) else { continue }
            found.append(Sensor(key: key, group: group,
                                isDie: FanSensorCatalog.isDie(smcKey: name, type: value.type),
                                name: FanSensorCatalog.name(smcKey: name, type: value.type),
                                isNamed: FanSensorCatalog.known(name, type: value.type) != nil))
        }
        sensors = found
    }

    /// Current readings (implausible ones skipped).
    func read(_ smc: FanSMCBackend, onlyDie: Bool = false) -> [(sensor: Sensor, celsius: Double)] {
        sensors.compactMap { sensor in
            guard !onlyDie || sensor.isDie, let c = smc.number(sensor.key), FanSensorCatalog.isPlausible(c) else { return nil }
            return (sensor, c)
        }
    }

    /// The hottest CPU/GPU die reading, nil if none could be read.
    func hottestDie(_ smc: FanSMCBackend) -> Double? {
        read(smc, onlyDie: true).map(\.celsius).max()
    }
}
