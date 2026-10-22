import Foundation

/// The helper's fan logic, independent of sockets so tests can drive it
/// with a fake SMC. Not thread safe: the server calls it from one queue.
///
/// Rules it enforces no matter what a client asks:
/// - a manual RPM is always within the fan's own [F<i>Mn, F<i>Mx], read
///   from the SMC here, never taken from the client;
/// - every fan returns to Auto when a CPU/GPU die sensor passes the thermal
///   limit, when no die sensor can be read, when no request arrives for
///   `heartbeatTimeout`, when the client disconnects, before sleep, on
///   SIGTERM and when the helper starts (a crashed helper leaves no fan manual);
/// - it only ever touches fans it switched to manual itself (recorded in
///   `FanHeldStore` so a restart finds them). The system's own mode 3 and
///   fans another app (Macs Fan Control, TG Pro...) holds are left alone,
///   and a fan another app holds is refused rather than fought over.
final class FanHelperEngine {
    private struct Pending {
        let rpm: Double
        let deadline: Date
    }

    private let smc: FanSMCBackend
    private var sensors: FanSMCSensorList
    /// When the sensor list was last discovered (rediscovered while it has
    /// no CPU/GPU die sensor, e.g. the SMC was not ready at boot).
    private var sensorsDiscoveredAt: Date?
    private let held: FanHeldStore
    private let log: (String) -> Void
    private var lastSaved: FanHeldState?

    private(set) var fans: [FanInfo] = []
    /// Fans held in manual mode and their RPM.
    private(set) var manual: [Int: Double] = [:]
    /// Fans waiting for the firmware to accept manual mode (Ftst path).
    private var pending: [Int: Pending] = [:]
    /// This helper set Ftst=1 and must clear it when the last fan is released.
    private(set) var usedTestFlag = false
    var failsafe = FanFailsafe()
    private(set) var lastHeartbeat: Date?
    private(set) var hottestDie: Double?
    private(set) var lastAutoReason: String?

    /// How long the Ftst unlock may take before giving up (research: 4-6 s typical).
    var unlockTimeout: TimeInterval = 10

    init(smc: FanSMCBackend, sensors: FanSMCSensorList? = nil, held: FanHeldStore = FanHeldMemory(),
         log: @escaping (String) -> Void = { _ in }) {
        self.smc = smc
        self.sensors = sensors ?? FanSMCSensorList(smc: smc)
        self.held = held
        self.log = log
    }

    var isControlling: Bool { !manual.isEmpty || !pending.isEmpty }

    /// nil: nothing to watch, no timer needed. Fast while waiting for an unlock.
    var nextTickInterval: TimeInterval? {
        if !pending.isEmpty { return 0.1 }
        if !manual.isEmpty { return 1 }
        return nil
    }

    // MARK: Lifecycle

    func start(now: Date) {
        fans = FanSMCReader.fans(smc)
        log("found \(fans.count) fan(s), \(sensors.sensors.filter(\.isDie).count) CPU/GPU sensors")
        // A previous run that crashed or was killed: release what it held.
        let leftover = held.load()
        for fan in leftover.fans.sorted() where FanSMCReader.fan(fan, smc: smc).mode == 1 {
            if !setMode(fan, manual: false) { log("fan \(fan): could not return to Auto") }
        }
        if leftover.testFlag, smc.has(FanSMCKeys.test) {
            do { try smc.writeNumber(FanSMCKeys.test, 0) } catch { log("could not clear Ftst: \(error)") }
        }
        if !leftover.fans.isEmpty || leftover.testFlag {
            lastAutoReason = "helper restarted"
            log("released fans left by the previous run: \(leftover.fans.sorted())")
        }
        persist(force: true)
    }

    private func persist(force: Bool = false) {
        let state = FanHeldState(fans: Set(manual.keys).union(pending.keys), testFlag: usedTestFlag)
        guard force || state != lastSaved else { return }
        held.save(state)
        lastSaved = state
    }

    /// The controlling client went away (SparkV quit or crashed).
    func clientDisconnected(now: Date) {
        lastHeartbeat = nil
        if isControlling { returnAllToAuto(reason: "SparkV disconnected", now: now) }
    }

    // MARK: Requests

    /// Handles one validated-syntax command. Every request counts as a heartbeat.
    func handle(_ command: FanCommand, now: Date) -> FanHelperResponse {
        lastHeartbeat = now
        fans = FanSMCReader.fans(smc)
        if let error = FanRequestValidator.validate(command, fans: fans) {
            return FanHelperResponse(id: nil, ok: false, error: error.message, status: nil)
        }
        switch command {
        case .hello, .status, .heartbeat:
            return FanHelperResponse(id: nil, ok: true, error: nil, status: status())
        case .allAuto:
            returnAllToAuto(reason: nil, now: now)
            return FanHelperResponse(id: nil, ok: true, error: nil, status: status())
        case .auto(let fan):
            release(fan)
            return FanHelperResponse(id: nil, ok: true, error: nil, status: status())
        case .setTarget(let fan, let rpm):
            rediscoverSensorsIfNeeded(now: now)
            hottestDie = sensors.hottestDie(smc)
            _ = failsafe.evaluate(now: now, hottestDie: hottestDie, lastHeartbeat: now, manualActive: false)
            if let refusal = failsafe.allowsManual(hottestDie: hottestDie) {
                if isControlling { returnAllToAuto(reason: refusal.message, now: now) }
                return FanHelperResponse(id: nil, ok: false, error: refusal.message, status: status())
            }
            if let error = takeManual(fan, rpm: rpm, now: now) {
                return FanHelperResponse(id: nil, ok: false, error: error, status: status())
            }
            return FanHelperResponse(id: nil, ok: true, error: nil, status: status())
        }
    }

    // MARK: Periodic check

    func tick(now: Date) {
        guard isControlling else { return }
        hottestDie = sensors.hottestDie(smc)
        if let reason = failsafe.evaluate(now: now, hottestDie: hottestDie, lastHeartbeat: lastHeartbeat, manualActive: true) {
            returnAllToAuto(reason: reason.text, now: now)
            return
        }
        for (fan, wait) in pending.sorted(by: { $0.key < $1.key }) {
            if setMode(fan, manual: true) {
                pending[fan] = nil
                manual[fan] = wait.rpm
                writeTarget(fan, wait.rpm)
                log("fan \(fan) manual at \(Int(wait.rpm)) rpm after unlock")
            } else if now >= wait.deadline {
                pending[fan] = nil
                log("fan \(fan): firmware did not accept manual mode; back to Auto")
                lastAutoReason = "the firmware did not accept manual mode"
                finishReleaseIfIdle()
            }
        }
        persist()
        // thermalmonitord can reclaim a fan; hold the mode and target.
        for (fan, held) in manual.sorted(by: { $0.key < $1.key }) {
            let info = FanSMCReader.fan(fan, smc: smc)
            // The limits were checked when the request came in; if the SMC
            // now reports different ones, never hold a speed outside them.
            var rpm = held
            if let limits = info.validLimits, !limits.contains(rpm) {
                rpm = min(max(rpm, limits.lowerBound), limits.upperBound)
                manual[fan] = rpm
                log("fan \(fan): limits changed, holding \(Int(rpm)) rpm")
            }
            if info.mode != 1, !setMode(fan, manual: true) {
                log("fan \(fan) left manual mode (mode \(info.mode ?? -1))")
            }
            if let target = info.target, abs(target - rpm) <= 1 { continue }
            writeTarget(fan, rpm)
        }
    }

    private func rediscoverSensorsIfNeeded(now: Date) {
        guard !sensors.sensors.contains(where: \.isDie) else { return }
        if let last = sensorsDiscoveredAt, now.timeIntervalSince(last) < 30 { return }
        sensorsDiscoveredAt = now
        sensors = FanSMCSensorList(smc: smc)
        log("rediscovered sensors: \(sensors.sensors.filter(\.isDie).count) CPU/GPU")
    }

    // MARK: Fan control

    private func takeManual(_ fan: Int, rpm: Double, now: Date) -> String? {
        defer { persist() }
        if manual[fan] == nil, pending[fan] == nil, fans.indices.contains(fan), fans[fan].mode == 1 {
            // Manual, but not by this helper: another fan app holds it.
            return "fan \(fan) is controlled by another app; set it to Auto there first"
        }
        if manual[fan] != nil {
            manual[fan] = rpm
            writeTarget(fan, rpm)
            return nil
        }
        if pending[fan] != nil {
            pending[fan] = Pending(rpm: rpm, deadline: pending[fan]!.deadline)
            return nil
        }
        if setMode(fan, manual: true) {
            manual[fan] = rpm
            writeTarget(fan, rpm)
            log("fan \(fan) manual at \(Int(rpm)) rpm")
            return nil
        }
        // M4-style firmware: the mode write is refused while the system holds
        // mode 3 until the diagnostic flag is set; then retry until accepted.
        guard smc.has(FanSMCKeys.test) else { return "the firmware refused manual mode for fan \(fan)" }
        if !usedTestFlag {
            do {
                try smc.writeNumber(FanSMCKeys.test, 1)
                usedTestFlag = true
            } catch {
                return "could not unlock manual mode: \(error)"
            }
        }
        pending[fan] = Pending(rpm: rpm, deadline: now.addingTimeInterval(unlockTimeout))
        log("fan \(fan) waiting for manual mode")
        return nil
    }

    /// Writes the target in the key's own type. Values were range checked.
    private func writeTarget(_ fan: Int, _ rpm: Double) {
        guard let key = FanSMCKeys.target(fan) else { return }
        do { try smc.writeNumber(key, rpm) } catch { log("fan \(fan) target write failed: \(error)") }
    }

    /// Sets F<i>Md to 1 (manual) or 0 (auto), or the FS! bit on older Intel
    /// Macs. Returns true when the SMC reads back the requested mode.
    @discardableResult
    private func setMode(_ fan: Int, manual: Bool) -> Bool {
        let wanted = manual ? 1.0 : 0.0
        if let key = FanSMCKeys.mode(fan, in: smc) {
            do { try smc.writeNumber(key, wanted) } catch { return false }
            return smc.number(key) == wanted
        }
        if smc.has(FanSMCKeys.forcedMask) {
            let current = Int(smc.number(FanSMCKeys.forcedMask) ?? 0)
            let next = manual ? current | (1 << fan) : current & ~(1 << fan)
            do { try smc.writeNumber(FanSMCKeys.forcedMask, Double(next)) } catch { return false }
            return Int(smc.number(FanSMCKeys.forcedMask) ?? -1) == next
        }
        return false
    }

    /// Only a fan this helper holds is switched back; anything else is not ours.
    private func release(_ fan: Int) {
        let wasHeld = manual.removeValue(forKey: fan) != nil || pending.removeValue(forKey: fan) != nil
        if wasHeld, !setMode(fan, manual: false) { log("fan \(fan): could not return to Auto") }
        finishReleaseIfIdle()
        persist()
    }

    private func finishReleaseIfIdle() {
        guard manual.isEmpty, pending.isEmpty, usedTestFlag else { return }
        // Clearing the flag hands control back to thermalmonitord. Only a
        // flag this helper set: another app may rely on its own.
        do { try smc.writeNumber(FanSMCKeys.test, 0) } catch { log("could not clear Ftst: \(error)") }
        usedTestFlag = false
    }

    /// Every fan this helper holds goes back to Auto.
    func returnAllToAuto(reason: String?, now: Date) {
        let heldFans = Set(manual.keys).union(pending.keys)
        manual.removeAll()
        pending.removeAll()
        for fan in heldFans.sorted() where !setMode(fan, manual: false) {
            log("fan \(fan): could not return to Auto")
        }
        finishReleaseIfIdle()
        persist()
        if let reason {
            lastAutoReason = reason
            if !heldFans.isEmpty { log("all fans Auto: \(reason)") }
        }
    }

    // MARK: Status

    func status() -> FanHelperStatus {
        let current = FanSMCReader.fans(smc)
        return FanHelperStatus(
            version: FanHelperConstants.protocolVersion,
            fans: current.map { fan in
                FanHelperStatus.Fan(index: fan.index, actual: fan.actual, target: fan.target,
                                    minimum: fan.minimum, maximum: fan.maximum, mode: fan.mode,
                                    manual: manual[fan.index] != nil || pending[fan.index] != nil,
                                    requested: manual[fan.index] ?? pending[fan.index]?.rpm)
            },
            hottestDie: hottestDie,
            failsafe: failsafe.isTripped ? failsafe.tripReason?.text : nil,
            thermalLimit: failsafe.limit,
            lastAutoReason: lastAutoReason
        )
    }
}

// MARK: - Held-fan record

struct FanHeldState: Codable, Equatable {
    var fans: Set<Int> = []
    var testFlag = false
}

protocol FanHeldStore: AnyObject {
    func load() -> FanHeldState
    func save(_ state: FanHeldState)
}

final class FanHeldMemory: FanHeldStore {
    var state = FanHeldState()
    func load() -> FanHeldState { state }
    func save(_ state: FanHeldState) { self.state = state }
}

/// A small JSON file, root-only (0600), written atomically.
final class FanHeldFile: FanHeldStore {
    private let path: String
    init(path: String = FanHelperConstants.stateFile) { self.path = path }

    func load() -> FanHeldState {
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONDecoder().decode(FanHeldState.self, from: data) else { return FanHeldState() }
        return FanHeldState(fans: state.fans.filter { (0...9).contains($0) }, testFlag: state.testFlag)
    }

    func save(_ state: FanHeldState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
        chmod(path, 0o600)
    }
}
