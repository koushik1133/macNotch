import Foundation

// Shared by SparkV and the privileged helper: the wire protocol, its strict
// validation and the thermal/heartbeat failsafe policy. Foundation only.
//
// Transport: a root-owned Unix stream socket. One JSON object per line,
// at most `FanHelperConstants.maxLineBytes` bytes. The helper answers every
// request with one line. Requests:
//   {"id":1,"op":"hello","version":1}
//   {"id":2,"op":"status"}
//   {"id":3,"op":"heartbeat"}
//   {"id":4,"op":"set","fan":0,"rpm":2400}
//   {"id":5,"op":"auto","fan":0}
//   {"id":6,"op":"allAuto"}
// Anything else (unknown op, extra or missing fields, wrong types, a fan
// index out of range, an RPM outside the fan's own [min, max]) is refused.

enum FanHelperConstants {
    static let protocolVersion = 1
    static let label = "com.sparkv.fanhelper"
    static let socketPath = "/var/run/com.sparkv.fanhelper.sock"
    static let installedBinary = "/Library/PrivilegedHelperTools/com.sparkv.fanhelper"
    static let launchdPlist = "/Library/LaunchDaemons/com.sparkv.fanhelper.plist"
    /// Root-only record of the fans the helper holds, so a restarted helper
    /// releases exactly those (and never fans another app controls).
    /// /var/run is emptied at boot, like the SMC's fan modes.
    static let stateFile = "/var/run/com.sparkv.fanhelper.state"
    static let maxLineBytes = 512
    /// The helper returns every fan to Auto when no request arrives for this long.
    static let heartbeatTimeout: TimeInterval = 10
    /// SparkV talks to the helper on every pass (about every 2 s) while it
    /// controls a fan; this is the longest gap it allows itself.
    static let heartbeatInterval: TimeInterval = 3
    /// Any CPU/GPU die sensor above this returns all fans to Auto.
    static let thermalLimit: Double = 95
    /// Manual control is allowed again once every die sensor is below this...
    static let thermalResume: Double = 85
    /// ...and at least this long after the failsafe tripped.
    static let thermalCooldown: TimeInterval = 30
}

// MARK: - Commands

enum FanCommand: Equatable, Sendable {
    case hello(version: Int)
    case status
    case heartbeat
    case setTarget(fan: Int, rpm: Double)
    case auto(fan: Int)
    case allAuto

    var op: String {
        switch self {
        case .hello: "hello"
        case .status: "status"
        case .heartbeat: "heartbeat"
        case .setTarget: "set"
        case .auto: "auto"
        case .allAuto: "allAuto"
        }
    }

    /// Commands that change fan state (the failsafe can refuse these).
    var takesManualControl: Bool {
        if case .setTarget = self { return true }
        return false
    }
}

struct FanProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum FanRequestCodec {
    /// The exact field set each op takes ("id" is optional on every op).
    private static let fields: [String: Set<String>] = [
        "hello": ["op", "version"],
        "status": ["op"],
        "heartbeat": ["op"],
        "set": ["op", "fan", "rpm"],
        "auto": ["op", "fan"],
        "allAuto": ["op"],
    ]

    static func encode(_ command: FanCommand, id: Int) -> Data {
        var object: [String: Any] = ["id": id, "op": command.op]
        switch command {
        case .hello(let version): object["version"] = version
        case .setTarget(let fan, let rpm):
            object["fan"] = fan
            object["rpm"] = rpm
        case .auto(let fan): object["fan"] = fan
        case .status, .heartbeat, .allAuto: break
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value, !isBool(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1_000_000 else { return nil }
        return Int(double)
    }

    private static func real(_ value: Any?) -> Double? {
        guard let value, !isBool(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// Syntax only: one JSON object with exactly the op's fields and the
    /// right types. Range checks need the fans (`FanRequestValidator`).
    static func decode(_ line: Data) -> Result<(id: Int?, command: FanCommand), FanProtocolError> {
        guard line.count <= FanHelperConstants.maxLineBytes else { return .failure(.init("request too long")) }
        guard let object = (try? JSONSerialization.jsonObject(with: line, options: [])) as? [String: Any] else {
            return .failure(.init("not a JSON object"))
        }
        guard let op = object["op"] as? String, let allowed = fields[op] else { return .failure(.init("unknown op")) }
        let keys = Set(object.keys).subtracting(["id"])
        guard keys == allowed else { return .failure(.init("wrong fields for \(op)")) }
        let id: Int?
        if object["id"] != nil {
            guard let parsed = integer(object["id"]) else { return .failure(.init("bad id")) }
            id = parsed
        } else {
            id = nil
        }
        switch op {
        case "hello":
            guard let version = integer(object["version"]) else { return .failure(.init("bad version")) }
            return .success((id, .hello(version: version)))
        case "status": return .success((id, .status))
        case "heartbeat": return .success((id, .heartbeat))
        case "allAuto": return .success((id, .allAuto))
        case "auto":
            guard let fan = integer(object["fan"]) else { return .failure(.init("bad fan")) }
            return .success((id, .auto(fan: fan)))
        case "set":
            guard let fan = integer(object["fan"]) else { return .failure(.init("bad fan")) }
            guard let rpm = real(object["rpm"]) else { return .failure(.init("bad rpm")) }
            return .success((id, .setTarget(fan: fan, rpm: rpm)))
        default:
            return .failure(.init("unknown op"))
        }
    }
}

enum FanRequestValidator {
    /// Semantic checks against the fans the helper itself just read from
    /// the SMC (never against numbers the client sent).
    static func validate(_ command: FanCommand, fans: [FanInfo]) -> FanProtocolError? {
        switch command {
        case .hello(let version):
            return version == FanHelperConstants.protocolVersion ? nil : .init("protocol version \(version) not supported")
        case .status, .heartbeat, .allAuto:
            return nil
        case .auto(let fan):
            return fans.indices.contains(fan) ? nil : .init("no fan \(fan)")
        case .setTarget(let fan, let rpm):
            guard fans.indices.contains(fan) else { return .init("no fan \(fan)") }
            guard let limits = fans[fan].validLimits else { return .init("fan \(fan) limits unknown") }
            guard rpm.isFinite else { return .init("bad rpm") }
            guard rpm >= limits.lowerBound else { return .init("rpm below the fan's minimum \(Int(limits.lowerBound))") }
            guard rpm <= limits.upperBound else { return .init("rpm above the fan's maximum \(Int(limits.upperBound))") }
            return nil
        }
    }
}

// MARK: - Responses

struct FanHelperStatus: Codable, Equatable, Sendable {
    struct Fan: Codable, Equatable, Sendable {
        let index: Int
        let actual: Double?
        let target: Double?
        let minimum: Double?
        let maximum: Double?
        let mode: Int?
        /// Under manual control by the helper right now.
        let manual: Bool
        /// The RPM the helper is holding (nil while Auto).
        let requested: Double?
    }

    let version: Int
    let fans: [Fan]
    let hottestDie: Double?
    /// Non-nil while the failsafe holds every fan in Auto.
    let failsafe: String?
    let thermalLimit: Double
    /// The last time the failsafe or a disconnect returned the fans to Auto, and why.
    let lastAutoReason: String?
}

struct FanHelperResponse: Codable, Equatable, Sendable {
    let id: Int?
    let ok: Bool
    let error: String?
    let status: FanHelperStatus?

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(self)) ?? Data(#"{"ok":false}"#.utf8)
        data.append(0x0A)
        return data
    }
}

// MARK: - Failsafe policy

/// Pure decision logic used by the helper once a second. Unit tested.
struct FanFailsafe: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case overheat(Double)
        case heartbeatLost
        case noSensors

        var text: String {
            switch self {
            case .overheat(let c): String(format: "CPU/GPU at %.0f °C", c)
            case .heartbeatLost: "SparkV stopped responding"
            case .noSensors: "no CPU/GPU temperature readable"
            }
        }
    }

    var limit = FanHelperConstants.thermalLimit
    var resumeBelow = FanHelperConstants.thermalResume
    var cooldown = FanHelperConstants.thermalCooldown
    var heartbeatTimeout = FanHelperConstants.heartbeatTimeout
    /// A reading this far over the limit trips at once; smaller overshoots
    /// must persist for two consecutive checks (one glitchy sample does not).
    var spikeMargin = 8.0

    private(set) var trippedAt: Date?
    private(set) var tripReason: Reason?
    private var overCount = 0
    /// While tripped: the last reading at or above `resumeBelow`. The
    /// cooldown counts from here, so it means "below 85 °C for 30 s", not
    /// "30 s after the first trip" (a long overheat must not end the
    /// cooldown the moment the temperature dips).
    private var lastHotAt: Date?

    var isTripped: Bool { trippedAt != nil }

    /// Called every check. Returns a reason when every fan must go to Auto now.
    mutating func evaluate(now: Date, hottestDie: Double?, lastHeartbeat: Date?, manualActive: Bool) -> Reason? {
        // Thermal state is tracked even while nothing is manual, so a
        // request arriving during a heat spike is refused.
        if let hot = hottestDie {
            if hot > limit {
                overCount += 1
                if hot >= limit + spikeMargin || overCount >= 2 {
                    trippedAt = trippedAt ?? now
                    tripReason = .overheat(hot)
                }
            } else {
                overCount = 0
            }
            if trippedAt != nil {
                if hot >= resumeBelow { lastHotAt = now }
                let since = lastHotAt ?? trippedAt ?? now
                if hot < resumeBelow, now.timeIntervalSince(since) >= cooldown {
                    trippedAt = nil
                    tripReason = nil
                    lastHotAt = nil
                }
            }
        }
        guard manualActive else { return nil }
        if hottestDie == nil { return .noSensors }
        if let reason = tripReason, trippedAt != nil { return reason }
        guard let beat = lastHeartbeat, now.timeIntervalSince(beat) <= heartbeatTimeout else { return .heartbeatLost }
        return nil
    }

    /// Whether a new manual request may be accepted right now.
    func allowsManual(hottestDie: Double?) -> FanProtocolError? {
        guard let hot = hottestDie else { return .init("no CPU/GPU temperature readable; staying on Auto") }
        if let reason = tripReason, trippedAt != nil {
            return .init("failsafe: \(reason.text); fans stay on Auto until below \(Int(resumeBelow)) °C")
        }
        if hot > limit { return .init(String(format: "CPU/GPU at %.0f °C; staying on Auto", hot)) }
        return nil
    }
}
