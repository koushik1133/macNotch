import Foundation

/// One temperature as SparkV shows it.
struct FanSensorReading: Identifiable, Sendable, Equatable {
    /// "agg.cpu.max", "smc.TB0T", "hid.NAND CH0 temp".
    let id: String
    let name: String
    let group: FanSensorGroup
    let celsius: Double
    /// Hottest/average of a group rather than one sensor.
    let isAggregate: Bool
}

/// Fans plus temperatures at one moment.
struct FanSnapshot: Sendable, Equatable {
    var fans: [FanInfo] = []
    var sensors: [FanSensorReading] = []
    var date = Date()
    /// False when AppleSMC could not be opened (a VM, a future Mac).
    var smcAvailable = false

    func sensor(_ id: String) -> FanSensorReading? { sensors.first { $0.id == id } }
    var hottestCPU: FanSensorReading? { sensor("agg.cpu.max") ?? sensor("agg.gpu.max") }
}

/// What to read on a pass. Background control reads only what it needs.
enum FanSampleScope: Equatable, Sendable {
    /// Fans plus the sensors these ids need (curves, live activity).
    case minimal(Set<String>)
    /// Fans, CPU/GPU, memory and the named sensors (drawer page, window).
    case standard
    /// Every temperature key and HID sensor ("Show all sensors").
    case all
}

/// Reads the SMC and HID sensors on its own utility queue, never on main.
final class FanSensorSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sparkv.fans.sampler", qos: .utility)
    private var smc: FanSMCBackend?
    private var list: FanSMCSensorList?
    private var hid: FanHIDTemperatures?
    private var opened = false
    private let makeBackend: () -> FanSMCBackend?
    private let usesHID: Bool

    init(makeBackend: @escaping () -> FanSMCBackend? = { try? FanAppleSMC() }, usesHID: Bool = true) {
        self.makeBackend = makeBackend
        self.usesHID = usesHID
    }

    func sample(_ scope: FanSampleScope, completion: @escaping @Sendable (FanSnapshot) -> Void) {
        queue.async { [self] in completion(sampleNow(scope)) }
    }

    private let lock = NSLock()

    /// Synchronous, on the caller's thread (tests, harnesses). Serialized,
    /// so a direct call never races the queue.
    func sampleNow(_ scope: FanSampleScope) -> FanSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if !opened {
            opened = true
            smc = makeBackend()
            if let smc { list = FanSMCSensorList(smc: smc) }
        }
        guard let smc, let list else { return FanSnapshot(date: Date(), smcAvailable: false) }
        var snapshot = FanSnapshot(fans: FanSMCReader.fans(smc), sensors: [], date: Date(), smcAvailable: true)

        // Which SMC sensors to read on this pass.
        let wantedGroups: Set<FanSensorGroup>
        var wantedKeys: Set<String> = []
        /// Keys asked for by id (a curve on one sensor), listed even unnamed.
        var explicitKeys: Set<String> = []
        var wantsHID = false
        switch scope {
        case .all:
            wantedGroups = Set(FanSensorGroup.allCases)
            wantsHID = true
        case .standard:
            wantedGroups = [.cpu, .gpu, .memory]
            wantedKeys = FanSensorCatalog.knownKeys
        case .minimal(let ids):
            var groups: Set<FanSensorGroup> = []
            for id in ids {
                if id.hasPrefix("agg."), let group = FanSensorGroup(rawValue: String(id.dropFirst(4).prefix { $0 != "." })) {
                    groups.insert(group)
                } else if id.hasPrefix("smc.") {
                    wantedKeys.insert(String(id.dropFirst(4)))
                    explicitKeys.insert(String(id.dropFirst(4)))
                } else if id.hasPrefix("hid.") {
                    wantsHID = true
                }
            }
            wantedGroups = groups
        }
        let dieCount = list.sensors.filter(\.isDie).count

        var readings: [(sensor: FanSMCSensorList.Sensor, celsius: Double)] = []
        for sensor in list.sensors where wantedGroups.contains(sensor.group) || wantedKeys.contains(sensor.key.string) {
            guard let c = smc.number(sensor.key), FanSensorCatalog.isPlausible(c) else { continue }
            readings.append((sensor, c))
        }

        // HID sensors: needed when the SMC has (almost) no die sensors, or
        // when asked for. ~60 ms per read on an M1 Pro, so not by default.
        var hidReadings: [FanSensorReading] = []
        if usesHID, wantsHID || dieCount < 4 {
            if hid == nil { hid = FanHIDTemperatures() }
            var byName: [String: Double] = [:]
            for reading in hid?.read() ?? [] { byName[reading.name] = max(byName[reading.name] ?? -.infinity, reading.celsius) }
            for (raw, celsius) in byName.sorted(by: { $0.key < $1.key }) {
                let info = FanSensorCatalog.classify(hidName: raw)
                hidReadings.append(FanSensorReading(id: "hid.\(raw)", name: info.name, group: info.group, celsius: celsius, isAggregate: false))
            }
        }

        // Aggregates per group: hottest and average.
        var sensors: [FanSensorReading] = []
        for group in FanSensorGroup.allCases where group != .other {
            var values = readings.filter { $0.sensor.group == group }.map(\.celsius)
            if dieCount < 4 { values += hidReadings.filter { $0.group == group }.map(\.celsius) }
            guard let hottest = values.max() else { continue }
            if group == .cpu || group == .gpu {
                sensors.append(FanSensorReading(id: "agg.\(group.rawValue).max", name: "\(group.title) Hottest", group: group, celsius: hottest, isAggregate: true))
                sensors.append(FanSensorReading(id: "agg.\(group.rawValue).avg", name: "\(group.title) Average", group: group,
                                                celsius: values.reduce(0, +) / Double(values.count), isAggregate: true))
            } else {
                sensors.append(FanSensorReading(id: "agg.\(group.rawValue).max", name: "\(group.title) Hottest", group: group, celsius: hottest, isAggregate: true))
            }
        }
        // Named sensors (and every raw key with `.all`).
        for reading in readings where scope == .all || reading.sensor.isNamed || explicitKeys.contains(reading.sensor.key.string) {
            sensors.append(FanSensorReading(id: "smc.\(reading.sensor.key.string)", name: reading.sensor.name,
                                            group: reading.sensor.group, celsius: reading.celsius, isAggregate: false))
        }
        sensors += hidReadings
        snapshot.sensors = sensors
        return snapshot
    }
}
