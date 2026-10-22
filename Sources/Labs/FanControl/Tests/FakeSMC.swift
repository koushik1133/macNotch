import Foundation

/// An in-memory SMC for tests. Behaves like the real one where it matters:
/// keys have a type and size, missing keys report 0x84, writes need "root",
/// and the M4 profile refuses manual mode until the Ftst flag is set.
final class FakeSMC: FanSMCBackend, @unchecked Sendable {
    struct Entry {
        var type: FanSMCCode
        var bytes: [UInt8]
    }

    private(set) var entries: [FanSMCCode: Entry] = [:]
    private var order: [FanSMCCode] = []
    private(set) var writes: [(key: String, value: Double?)] = []
    var isRoot = true
    /// M4: F<i>Md writes fail with 0x82 while Ftst != 1, then for `unlockAttempts` more tries.
    var refusesModeUntilTest = false
    var unlockAttempts = 0
    private var attempts = 0
    /// Simulates a read failure for every key (SMC gone).
    var broken = false
    /// The real AppleSMC client is locked; so is the fake (the sampler reads
    /// it on its own queue while tests change values on main).
    private let lock = NSRecursiveLock()

    func set(_ key: String, _ value: Double, type: String = "flt ") {
        lock.lock()
        defer { lock.unlock() }
        let code = FanSMCCode(key)!
        let typeCode = FanSMCCode(type)!
        let size: Int
        switch type {
        case "flt ", "ui32": size = 4
        case "ui8 ", "flag": size = 1
        default: size = 2
        }
        let bytes = FanSMCCodec.encode(value, type: typeCode, size: size)!
        if entries[code] == nil { order.append(code) }
        entries[code] = Entry(type: typeCode, bytes: bytes)
        let countKey = FanSMCCode("#KEY")!
        if code != countKey {
            if entries[countKey] == nil { order.insert(countKey, at: 0) }
            entries[countKey] = Entry(type: FanSMCCodec.ui32, bytes: FanSMCCodec.encode(Double(order.count), type: FanSMCCodec.ui32, size: 4)!)
        }
    }

    func value(_ key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[FanSMCCode(key)!] else { return nil }
        return FanSMCCodec.decode(type: entry.type, bytes: entry.bytes)
    }

    func clearWrites() { lock.lock(); defer { lock.unlock() }; writes.removeAll() }

    // MARK: FanSMCBackend

    func keyInfo(_ key: FanSMCCode) throws -> FanSMCKeyInfo {
        lock.lock()
        defer { lock.unlock() }
        guard !broken, let entry = entries[key] else { throw FanSMCError.keyNotFound(key.string) }
        return FanSMCKeyInfo(size: entry.bytes.count, type: entry.type, attributes: 0)
    }

    func read(_ key: FanSMCCode) throws -> FanSMCValue {
        lock.lock()
        defer { lock.unlock() }
        guard !broken, let entry = entries[key] else { throw FanSMCError.keyNotFound(key.string) }
        return FanSMCValue(key: key, type: entry.type, bytes: entry.bytes)
    }

    func write(_ key: FanSMCCode, bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isRoot else { throw FanSMCError.notPrivileged }
        guard var entry = entries[key] else { throw FanSMCError.keyNotFound(key.string) }
        guard bytes.count == entry.bytes.count else { throw FanSMCError.badValue("size") }
        let name = key.string
        if refusesModeUntilTest, name.hasPrefix("F"), name.hasSuffix("Md"), FanSMCCodec.decode(type: entry.type, bytes: bytes) == 1 {
            guard value("Ftst") == 1 else { throw FanSMCError.smcResult(0x82) }
            attempts += 1
            guard attempts > unlockAttempts else { throw FanSMCError.smcResult(0x82) }
        }
        entry.bytes = bytes
        entries[key] = entry
        writes.append((name, FanSMCCodec.decode(type: entry.type, bytes: bytes)))
    }

    func key(at index: Int) throws -> FanSMCCode {
        lock.lock()
        defer { lock.unlock() }
        guard order.indices.contains(index) else { throw FanSMCError.smcResult(0x84) }
        return order[index]
    }

    // MARK: Profiles

    /// An M1 Pro like this Mac: two fans, flt values, F<i>Md, no Ftst.
    static func appleSilicon() -> FakeSMC {
        let smc = FakeSMC()
        smc.set("FNum", 2, type: "ui8 ")
        for (i, maxRPM) in [4296.0, 4744.0].enumerated() {
            smc.set("F\(i)Ac", 1800)
            smc.set("F\(i)Mn", 1499)
            smc.set("F\(i)Mx", maxRPM)
            smc.set("F\(i)Tg", 1800)
            smc.set("F\(i)Md", 0, type: "ui8 ")
        }
        smc.set("Tp01", 60)
        smc.set("Tp05", 62)
        smc.set("Tg05", 55)
        smc.set("TB0T", 35)
        smc.set("TH0x", 36)
        return smc
    }

    /// M4 generation: manual mode needs the Ftst unlock.
    static func m4() -> FakeSMC {
        let smc = appleSilicon()
        smc.set("Ftst", 0, type: "ui8 ")
        smc.set("F0Md", 3, type: "ui8 ")
        smc.set("F1Md", 3, type: "ui8 ")
        smc.refusesModeUntilTest = true
        smc.unlockAttempts = 3
        return smc
    }

    /// An older Intel MacBook Pro: fpe2 speeds, the FS! bitmask, sp78 temps.
    static func intel() -> FakeSMC {
        let smc = FakeSMC()
        smc.set("FNum", 1, type: "ui8 ")
        smc.set("F0Ac", 2000, type: "fpe2")
        smc.set("F0Mn", 2000, type: "fpe2")
        smc.set("F0Mx", 6200, type: "fpe2")
        smc.set("F0Tg", 2000, type: "fpe2")
        smc.set("FS! ", 0, type: "ui16")
        smc.set("TC0D", 50, type: "sp78")
        smc.set("TC0P", 45, type: "sp78")
        smc.set("TB0T", 30, type: "sp78")
        return smc
    }
}
