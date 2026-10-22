import Foundation
import Security

// Fan Control tests. Run with Tests/run-tests.sh. No SMC writes reach real
// hardware: every engine test uses FakeSMC. The optional "live" section only
// READS this Mac's SMC (fans and temperatures).

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL [\(line)] \(name)")
    }
}

func approx(_ a: Double?, _ b: Double, _ tolerance: Double = 0.001) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

func code(_ s: String) -> FanSMCCode { FanSMCCode(s)! }

// MARK: - Codec

func testCodec() {
    let C = FanSMCCodec.self
    // fpe2: 14.2 fixed point, big endian (Intel fan RPM).
    check(approx(C.decode(type: C.fpe2, bytes: [0x17, 0x70]), 1500), "fpe2 decode 1500")
    check(C.encode(1500, type: C.fpe2, size: 2) == [0x17, 0x70], "fpe2 encode 1500")
    check(approx(C.decode(type: C.fpe2, bytes: [0x60, 0xE0]), 6200), "fpe2 decode 6200")
    check(approx(C.decode(type: C.fpe2, bytes: [0x00, 0x05]), 1.25), "fpe2 fraction")
    check(C.encode(-1, type: C.fpe2, size: 2) == nil, "fpe2 rejects negative")
    check(C.encode(20000, type: C.fpe2, size: 2) == nil, "fpe2 rejects overflow (max 16383.75)")
    check(C.encode(16383.75, type: C.fpe2, size: 2) == [0xFF, 0xFF], "fpe2 max")
    // flt: little-endian Float32 (Apple silicon). Bytes read from this Mac's F0Mn / F0Ac.
    check(approx(C.decode(type: C.flt, bytes: [0, 96, 187, 68]), 1499), "flt decode real F0Mn")
    check(approx(C.decode(type: C.flt, bytes: [154, 94, 226, 68]), 1810.9563, 0.001), "flt decode real F0Ac")
    check(C.encode(1499, type: C.flt, size: 4) == [0, 96, 187, 68], "flt encode 1499")
    check(C.encode(4744, type: C.flt, size: 4) == [0, 64, 148, 69], "flt encode real F1Mx")
    check(C.encode(.nan, type: C.flt, size: 4) == nil, "flt rejects NaN")
    check(C.encode(.infinity, type: C.flt, size: 4) == nil, "flt rejects infinity")
    check(C.decode(type: C.flt, bytes: [0, 0, 0xC0, 0x7F]) == nil, "flt decode NaN is nil")
    check(C.decode(type: C.flt, bytes: [0, 0]) == nil, "flt short data")
    // sp78: signed 7.8 (Intel temperatures).
    check(approx(C.decode(type: C.sp78, bytes: [0x28, 0x80]), 40.5), "sp78 decode 40.5")
    check(approx(C.decode(type: C.sp78, bytes: [0xFF, 0x00]), -1), "sp78 negative")
    check(C.encode(40.5, type: C.sp78, size: 2) == [0x28, 0x80], "sp78 encode")
    check(C.encode(-1, type: C.sp78, size: 2) == [0xFF, 0x00], "sp78 encode negative")
    check(C.encode(200, type: C.sp78, size: 2) == nil, "sp78 overflow")
    // Integers: big endian.
    check(approx(C.decode(type: C.ui8, bytes: [5]), 5), "ui8")
    check(approx(C.decode(type: C.ui16, bytes: [0, 6]), 6), "ui16")
    check(approx(C.decode(type: C.ui16, bytes: [0x12, 0x34]), 0x1234), "ui16 big endian")
    check(approx(C.decode(type: C.ui32, bytes: [0, 0, 0, 95]), 95), "ui32")
    check(approx(C.decode(type: C.ui32, bytes: [0, 0, 0x08, 0x83]), 2179), "ui32 #KEY")
    check(C.encode(6, type: C.ui16, size: 2) == [0, 6], "ui16 encode")
    check(C.encode(1, type: C.ui8, size: 1) == [1], "ui8 encode")
    check(C.encode(256, type: C.ui8, size: 1) == nil, "ui8 overflow")
    check(C.encode(-1, type: C.ui8, size: 1) == nil, "ui8 negative")
    check(C.encode(65535, type: C.ui16, size: 2) == [0xFF, 0xFF], "ui16 max")
    check(approx(C.decode(type: code("si8 "), bytes: [0xFF]), -1), "si8 negative")
    check(approx(C.decode(type: code("si16"), bytes: [0xFF, 0xFE]), -2), "si16 negative")
    check(C.encode(-2, type: code("si16"), size: 2) == [0xFF, 0xFE], "si16 encode")
    check(approx(C.decode(type: C.flag, bytes: [1]), 1), "flag")
    check(C.encode(2, type: C.flag, size: 1) == nil, "flag only 0/1")
    // ioft (Apple silicon some temps): 48.16 little endian.
    check(approx(C.decode(type: code("ioft"), bytes: [0x00, 0x80, 0x26, 0, 0, 0, 0, 0]), 38.5), "ioft")
    check(C.decode(type: code("hex_"), bytes: [0, 0, 0, 0]) == nil, "unknown type")
    check(C.isNumeric(code("fp88")) && approx(C.decode(type: code("fp88"), bytes: [0x01, 0x80]), 1.5), "fp88")
    check(!C.isNumeric(code("fpzz")), "bad fixed point")
    check(C.encode(5, type: C.ui8, size: 4) == [5, 0, 0, 0], "encode pads to key size")
    check(C.encode(5, type: C.ui16, size: 1) == nil, "encode refuses a smaller key size")
    // Four-character codes.
    check(FanSMCCode("F0Ac")?.string == "F0Ac", "fourcc round trip")
    check(FanSMCCode("F0Ac")?.code == 0x4630_4163, "fourcc value")
    check(FanSMCCode("F10Ac") == nil && FanSMCCode("") == nil && FanSMCCode("Fé0A") == nil, "fourcc rejects bad input")
    check(FanSMCCode.fan(10, "Ac") == nil && FanSMCCode.fan(-1, "Ac") == nil, "fan index 0-9 only")
    check(FanSMCCode.fan(3, "Tg")?.string == "F3Tg", "fan key")
}

// MARK: - Parameter block layout

func testParamBlock() {
    check(FanSMCParamBlock.size == Int(fan_test_size()), "block size matches C (\(fan_test_size()))")
    var block = FanSMCParamBlock()
    block.key = code("F0Ac")
    block.dataSize = 4
    block.dataType = FanSMCCodec.flt
    block.command = FanSMCParamBlock.Command.read.rawValue
    block.data32 = 0xA1B2C3D4
    block.bytes = [9, 8, 7]
    let raw = block.raw
    func u32(_ at: Int) -> UInt32 { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
    check(u32(0) == code("F0Ac").code, "key at 0")
    check(u32(Int(fan_test_offset_keyInfo())) == 4, "dataSize at C offset \(fan_test_offset_keyInfo())")
    check(u32(Int(fan_test_offset_dataType())) == FanSMCCodec.flt.code, "dataType at C offset \(fan_test_offset_dataType())")
    check(raw[Int(fan_test_offset_data8())] == 5, "command at C offset \(fan_test_offset_data8())")
    check(u32(Int(fan_test_offset_data32())) == 0xA1B2C3D4, "data32 at C offset \(fan_test_offset_data32())")
    check(Array(raw[Int(fan_test_offset_bytes())..<Int(fan_test_offset_bytes()) + 3]) == [9, 8, 7], "bytes at C offset \(fan_test_offset_bytes())")
    check(fan_test_offset_result() == 40 && fan_test_offset_attributes() == 36, "result 40, attributes 36")
    block.bytes = Array(repeating: 1, count: 40)
    check(block.raw.count == 80 && block.raw[79] == 1, "bytes truncated to 32")
    check(FanSMCParamBlock(raw: [1, 2]).raw.count == 80, "short raw becomes empty block")
}

// MARK: - Protocol and validation

func decode(_ s: String) -> Result<(id: Int?, command: FanCommand), FanProtocolError> {
    FanRequestCodec.decode(Data(s.utf8))
}

func isFailure(_ r: Result<(id: Int?, command: FanCommand), FanProtocolError>) -> Bool {
    if case .failure = r { return true }
    return false
}

func command(_ r: Result<(id: Int?, command: FanCommand), FanProtocolError>) -> FanCommand? {
    if case .success(let v) = r { return v.command }
    return nil
}

func testProtocol() {
    check(command(decode(#"{"id":4,"op":"set","fan":0,"rpm":2400}"#)) == .setTarget(fan: 0, rpm: 2400), "valid set")
    check(command(decode(#"{"op":"set","fan":1,"rpm":2400.5}"#)) == .setTarget(fan: 1, rpm: 2400.5), "set without id")
    check(command(decode(#"{"op":"auto","fan":1}"#)) == .auto(fan: 1), "auto")
    check(command(decode(#"{"op":"allAuto"}"#)) == .allAuto, "allAuto")
    check(command(decode(#"{"op":"hello","version":1}"#)) == .hello(version: 1), "hello")
    check(isFailure(decode(#"{"op":"writeKey","key":"F0Md","value":1}"#)), "unknown op rejected (no raw SMC access)")
    check(isFailure(decode(#"{"op":"set","fan":0,"rpm":2400,"key":"F0Tg"}"#)), "extra field rejected")
    check(isFailure(decode(#"{"op":"set","fan":0}"#)), "missing rpm rejected")
    check(isFailure(decode(#"{"op":"set","fan":true,"rpm":2400}"#)), "bool fan rejected")
    check(isFailure(decode(#"{"op":"set","fan":0.5,"rpm":2400}"#)), "fractional fan rejected")
    check(isFailure(decode(#"{"op":"set","fan":"0","rpm":2400}"#)), "string fan rejected")
    check(isFailure(decode(#"{"op":"set","fan":0,"rpm":"max"}"#)), "string rpm rejected")
    check(isFailure(decode(#"{"op":"set","fan":0,"rpm":1e400}"#)), "infinite rpm rejected")
    check(isFailure(decode(#"{"op":"status","id":"x"}"#)), "string id rejected")
    check(isFailure(decode(#"[1,2]"#)) && isFailure(decode("garbage")) && isFailure(decode("")), "non-object rejected")
    check(isFailure(decode(#"{"op":"status","pad":""# + String(repeating: "x", count: 600) + #""}"#)), "long line rejected")
    // Round trip through the encoder.
    for cmd: FanCommand in [.hello(version: 1), .status, .heartbeat, .setTarget(fan: 1, rpm: 3000), .auto(fan: 0), .allAuto] {
        var data = FanRequestCodec.encode(cmd, id: 9)
        data.removeLast()
        check(command(FanRequestCodec.decode(data)) == cmd, "encode/decode \(cmd.op)")
    }

    let fans = [FanInfo(index: 0, actual: 1800, target: 1800, minimum: 1499, maximum: 4296, mode: 0),
                FanInfo(index: 1, actual: 1800, target: 1800, minimum: 0, maximum: 4744, mode: 0)]
    let V = FanRequestValidator.self
    check(V.validate(.setTarget(fan: 0, rpm: 1499), fans: fans) == nil, "rpm at minimum accepted")
    check(V.validate(.setTarget(fan: 0, rpm: 4296), fans: fans) == nil, "rpm at maximum accepted")
    check(V.validate(.setTarget(fan: 0, rpm: 1498.9), fans: fans)?.message.contains("minimum") == true, "rpm below minimum refused")
    check(V.validate(.setTarget(fan: 0, rpm: 4296.1), fans: fans)?.message.contains("maximum") == true, "rpm above maximum refused")
    check(V.validate(.setTarget(fan: 0, rpm: 0), fans: fans) != nil, "zero rpm refused")
    check(V.validate(.setTarget(fan: 1, rpm: 2000), fans: fans) != nil, "unknown limits (min 0) refused")
    check(V.validate(.setTarget(fan: 2, rpm: 2000), fans: fans) != nil, "fan index out of range refused")
    check(V.validate(.setTarget(fan: -1, rpm: 2000), fans: fans) != nil, "negative fan refused")
    check(V.validate(.auto(fan: 5), fans: fans) != nil, "auto on missing fan refused")
    check(V.validate(.hello(version: 2), fans: fans) != nil, "other protocol version refused")
    check(V.validate(.allAuto, fans: []) == nil, "allAuto always allowed")
}

// MARK: - Curve

func testCurve() {
    let limits = 1499.0...4296.0
    let M = FanCurveMath.self
    check(M.target(temperature: 40, startC: 50, maxC: 80, limits: limits) == 1499, "below start = minimum")
    check(M.target(temperature: 50, startC: 50, maxC: 80, limits: limits) == 1499, "at start = minimum")
    check(M.target(temperature: 80, startC: 50, maxC: 80, limits: limits) == 4296, "at max = maximum")
    check(M.target(temperature: 99, startC: 50, maxC: 80, limits: limits) == 4296, "above max = maximum")
    check(approx(M.target(temperature: 65, startC: 50, maxC: 80, limits: limits), 2897.5), "midpoint linear")
    check(M.target(temperature: .nan, startC: 50, maxC: 80, limits: limits) == 4296, "NaN temperature = maximum (safe)")
    check(M.target(temperature: 60, startC: 70, maxC: 70, limits: limits) == 1499, "degenerate curve below")
    check(M.target(temperature: 70, startC: 70, maxC: 60, limits: limits) == 4296, "inverted curve at/above max")
    check(M.quantize(1490, limits: limits) == 1499 && M.quantize(1499, limits: limits) == 1499, "quantize never below minimum, keeps the exact minimum")
    check(M.quantize(1512, limits: limits) == 1499 || M.quantize(1512, limits: limits) == 1500, "quantize near minimum")
    check(M.quantize(2412, limits: limits) == 2400, "quantize 25 rpm steps")
    check(M.quantize(9999, limits: limits) == 4296, "quantize clamps to maximum")
    check(M.clamp(-5, to: limits) == 1499 && M.clamp(.infinity, to: limits) == 4296, "clamp")
    let s = M.sanitizedCurve(startC: 90, maxC: 60)
    check(s.startC == 90 && s.maxC == 95, "sanitized: max at least start + 5")
    let t = M.sanitizedCurve(startC: -10, maxC: 500)
    check(t.startC == 20 && t.maxC == 110, "sanitized: clamped range")

    var f = FanCurveFollower()
    let first = f.next(temperature: 60, startC: 50, maxC: 80, limits: limits)
    check(first == M.quantize(M.target(temperature: 60, startC: 50, maxC: 80, limits: limits), limits: limits), "follower first value")
    let up = f.next(temperature: 70, startC: 50, maxC: 80, limits: limits)
    check(up > first, "rising temperature raises at once")
    let smallDrop = f.next(temperature: 68.5, startC: 50, maxC: 80, limits: limits)
    check(smallDrop == up, "drop under hysteresis holds speed")
    let bigDrop = f.next(temperature: 67, startC: 50, maxC: 80, limits: limits)
    check(bigDrop < up, "drop past hysteresis lowers speed")
    let tiny = f.next(temperature: 67.3, startC: 50, maxC: 80, limits: limits)
    check(tiny == bigDrop, "change under 50 rpm ignored")
    let top = f.next(temperature: 95, startC: 50, maxC: 80, limits: limits)
    check(top == 4296, "reaches maximum")
    let bottom = f.next(temperature: 30, startC: 50, maxC: 80, limits: limits)
    check(bottom == 1499, "big drop returns to minimum")
    f.reset()
    check(f.lastTarget == nil, "reset")

    // Presets adapt to each fan.
    let fans = [FanInfo(index: 0, actual: 0, target: 0, minimum: 1499, maximum: 4296, mode: 0),
                FanInfo(index: 1, actual: 0, target: 0, minimum: nil, maximum: 4744, mode: 0)]
    let full = FanPreset.builtins.first { $0.builtin == .fullBlast }!
    check(full.modes(for: fans) == [.constant(rpm: 4296), .auto], "full blast uses each max; unknown limits stay Auto")
    check(FanPreset.builtins[0].modes(for: fans) == [.auto, .auto], "auto preset")
    let custom = FanPreset(id: "c", name: "Mine", builtin: nil, modes: [.constant(rpm: 2000)])
    check(custom.modes(for: fans) == [.constant(rpm: 2000), .auto], "custom preset pads with Auto")
    // Settings round trip.
    var settings = FanSettings()
    settings.lastModes = [.sensor(id: "agg.cpu.max", startC: 50, maxC: 80), .constant(rpm: 2000), .auto]
    settings.customPresets = [custom]
    let data = try! JSONEncoder().encode(settings)
    check((try? JSONDecoder().decode(FanSettings.self, from: data)) == settings, "settings Codable round trip")
    check(FanSettings().restoreOnLaunch == false && FanSettings().activity == .whileManual, "safe defaults")
    check(FanFormat.rpm(12) == "Off" && FanFormat.rpm(1810.6) == "1811" && FanFormat.compactRPM(2412) == "2.4k", "rpm formats")
    check(FanFormat.temperature(100, fahrenheit: true) == "212°F" && FanFormat.temperature(nil, fahrenheit: false) == "--", "temperature formats")
}

// MARK: - Failsafe policy

func testFailsafe() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var f = FanFailsafe()
    check(f.evaluate(now: t0, hottestDie: 60, lastHeartbeat: t0, manualActive: true) == nil, "normal: no action")
    check(f.evaluate(now: t0.addingTimeInterval(1), hottestDie: 96, lastHeartbeat: t0, manualActive: true) == nil, "one sample over limit tolerated")
    check(f.evaluate(now: t0.addingTimeInterval(2), hottestDie: 96, lastHeartbeat: t0, manualActive: true) == .overheat(96), "two samples over limit trip")
    check(f.isTripped, "tripped")
    check(f.allowsManual(hottestDie: 80) != nil, "manual refused while tripped")
    _ = f.evaluate(now: t0.addingTimeInterval(10), hottestDie: 80, lastHeartbeat: t0, manualActive: false)
    check(f.isTripped, "still tripped before cooldown")
    _ = f.evaluate(now: t0.addingTimeInterval(40), hottestDie: 88, lastHeartbeat: t0, manualActive: false)
    check(f.isTripped, "still tripped above resume temperature")
    _ = f.evaluate(now: t0.addingTimeInterval(41), hottestDie: 84, lastHeartbeat: t0, manualActive: false)
    check(f.isTripped, "88 °C one second ago: cooldown restarts (needs 30 s below 85 °C)")
    _ = f.evaluate(now: t0.addingTimeInterval(69), hottestDie: 80, lastHeartbeat: t0, manualActive: false)
    check(f.isTripped, "29 s below 85 °C: still tripped")
    _ = f.evaluate(now: t0.addingTimeInterval(71), hottestDie: 84, lastHeartbeat: t0, manualActive: false)
    check(!f.isTripped && f.allowsManual(hottestDie: 84) == nil, "clears after 30 s below 85 °C")

    // A long overheat must not end the cooldown the moment it dips below 85 °C.
    var long = FanFailsafe()
    _ = long.evaluate(now: t0, hottestDie: 104, lastHeartbeat: t0, manualActive: true)
    for s in stride(from: 2.0, through: 300, by: 2) {
        _ = long.evaluate(now: t0.addingTimeInterval(s), hottestDie: 99, lastHeartbeat: t0, manualActive: false)
    }
    _ = long.evaluate(now: t0.addingTimeInterval(302), hottestDie: 84, lastHeartbeat: t0, manualActive: false)
    check(long.isTripped && long.allowsManual(hottestDie: 84) != nil, "5 min overheat then dip: still refused")
    _ = long.evaluate(now: t0.addingTimeInterval(331), hottestDie: 83, lastHeartbeat: t0, manualActive: false)
    check(!long.isTripped, "5 min overheat: cleared 30 s after the last hot reading")
    // Retrip after clearing works again.
    _ = long.evaluate(now: t0.addingTimeInterval(332), hottestDie: 104, lastHeartbeat: t0, manualActive: false)
    check(long.isTripped, "retrips after clearing")

    var g = FanFailsafe()
    check(g.evaluate(now: t0, hottestDie: 104, lastHeartbeat: t0, manualActive: true) == .overheat(104), "big spike trips at once")
    var h = FanFailsafe()
    _ = h.evaluate(now: t0, hottestDie: 96, lastHeartbeat: t0, manualActive: true)
    _ = h.evaluate(now: t0.addingTimeInterval(1), hottestDie: 90, lastHeartbeat: t0, manualActive: true)
    check(h.evaluate(now: t0.addingTimeInterval(2), hottestDie: 96, lastHeartbeat: t0, manualActive: true) == nil, "non-consecutive spikes do not trip")
    var k = FanFailsafe()
    check(k.evaluate(now: t0.addingTimeInterval(10), hottestDie: 60, lastHeartbeat: t0, manualActive: true) == nil, "heartbeat at 10 s ok")
    check(k.evaluate(now: t0.addingTimeInterval(10.1), hottestDie: 60, lastHeartbeat: t0, manualActive: true) == .heartbeatLost, "heartbeat lost after 10 s")
    check(k.evaluate(now: t0, hottestDie: 60, lastHeartbeat: nil, manualActive: true) == .heartbeatLost, "no heartbeat at all")
    check(k.evaluate(now: t0, hottestDie: nil, lastHeartbeat: t0, manualActive: true) == .noSensors, "no sensors while manual")
    check(k.allowsManual(hottestDie: nil) != nil, "no sensors: manual refused")
    check(k.allowsManual(hottestDie: 96) != nil, "over limit: manual refused even before trip")
    check(k.evaluate(now: t0, hottestDie: nil, lastHeartbeat: nil, manualActive: false) == nil, "nothing manual: nothing to do")
}

// MARK: - Helper engine on a fake SMC

func makeEngine(_ smc: FakeSMC, now: Date) -> FanHelperEngine {
    let engine = FanHelperEngine(smc: smc)
    engine.start(now: now)
    return engine
}

func testEngineAppleSilicon() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    let smc = FakeSMC.appleSilicon()
    let engine = makeEngine(smc, now: t0)
    check(smc.writes.isEmpty, "start on a clean Mac writes nothing")
    check(engine.handle(.setTarget(fan: 0, rpm: 1000), now: t0).ok == false, "engine refuses rpm below minimum")
    check(smc.value("F0Md") == 0, "refused request changed nothing")
    let r = engine.handle(.setTarget(fan: 0, rpm: 2400), now: t0)
    check(r.ok, "set accepted: \(r.error ?? "")")
    check(smc.value("F0Md") == 1 && smc.value("F0Tg") == 2400, "mode 1, target 2400 (flt)")
    check(r.status?.fans.first?.manual == true && r.status?.fans.last?.manual == false, "status shows which fan is manual")
    check(engine.nextTickInterval == 1, "1 s checks while manual")
    // thermalmonitord reclaims the fan: the helper holds it.
    smc.set("F0Md", 3, type: "ui8 ")
    smc.set("F0Tg", 1500)
    engine.tick(now: t0.addingTimeInterval(1))
    check(smc.value("F0Md") == 1 && smc.value("F0Tg") == 2400, "re-asserts mode and target")
    // Heartbeat.
    engine.tick(now: t0.addingTimeInterval(9))
    check(smc.value("F0Md") == 1, "still manual at 9 s")
    engine.tick(now: t0.addingTimeInterval(10.5))
    check(smc.value("F0Md") == 0 && !engine.isControlling, "no heartbeat for 10 s: Auto")
    check(engine.lastAutoReason == FanFailsafe.Reason.heartbeatLost.text, "reason recorded")
    check(engine.nextTickInterval == nil, "idle helper needs no timer")
    // Auto for one fan.
    let t1 = t0.addingTimeInterval(100)
    _ = engine.handle(.setTarget(fan: 0, rpm: 3000), now: t1)
    _ = engine.handle(.setTarget(fan: 1, rpm: 4744), now: t1)
    _ = engine.handle(.auto(fan: 0), now: t1)
    check(smc.value("F0Md") == 0 && smc.value("F1Md") == 1, "auto releases one fan only")
    // Disconnect.
    engine.clientDisconnected(now: t1)
    check(smc.value("F1Md") == 0, "client disconnect: Auto")
    // Overheat.
    let t2 = t0.addingTimeInterval(200)
    _ = engine.handle(.setTarget(fan: 1, rpm: 3000), now: t2)
    smc.set("Tp05", 97)
    engine.tick(now: t2.addingTimeInterval(1))
    check(smc.value("F1Md") == 1, "one hot sample tolerated")
    _ = engine.handle(.heartbeat, now: t2.addingTimeInterval(1.5))
    engine.tick(now: t2.addingTimeInterval(2))
    check(smc.value("F1Md") == 0, "overheat: Auto")
    let refused = engine.handle(.setTarget(fan: 1, rpm: 3000), now: t2.addingTimeInterval(3))
    check(!refused.ok && refused.status?.failsafe != nil, "manual refused while tripped; status says why")
    smc.set("Tp05", 70)
    check(!engine.handle(.setTarget(fan: 1, rpm: 3000), now: t2.addingTimeInterval(20)).ok, "still refused inside cooldown")
    check(engine.handle(.setTarget(fan: 1, rpm: 3000), now: t2.addingTimeInterval(40)).ok, "allowed after cooldown below 85 °C")
    // Spike.
    smc.set("Tg05", 110)
    engine.tick(now: t2.addingTimeInterval(41))
    check(smc.value("F1Md") == 0, "110 °C spike: Auto at once")
    smc.set("Tg05", 55)
    // No die sensor readable.
    let t3 = t0.addingTimeInterval(400)
    _ = engine.handle(.setTarget(fan: 0, rpm: 2000), now: t3)
    for key in ["Tp01", "Tp05", "Tg05"] { smc.set(key, 0) }
    engine.tick(now: t3.addingTimeInterval(1))
    check(smc.value("F0Md") == 0, "no readable CPU/GPU sensor: Auto")
    check(!engine.handle(.setTarget(fan: 0, rpm: 2000), now: t3.addingTimeInterval(2)).ok, "no sensors: manual refused")
    for (key, v) in [("Tp01", 60.0), ("Tp05", 62.0), ("Tg05", 55.0)] { smc.set(key, v) }
    // allAuto and sleep.
    let t4 = t0.addingTimeInterval(500)
    _ = engine.handle(.setTarget(fan: 0, rpm: 2000), now: t4)
    _ = engine.handle(.setTarget(fan: 1, rpm: 2000), now: t4)
    engine.returnAllToAuto(reason: "system going to sleep", now: t4)
    check(smc.value("F0Md") == 0 && smc.value("F1Md") == 0, "sleep: every fan Auto")
    // The system's own mode 3 is never overwritten.
    smc.set("F0Md", 3, type: "ui8 ")
    smc.clearWrites()
    engine.returnAllToAuto(reason: "test", now: t4)
    check(smc.writes.isEmpty && smc.value("F0Md") == 3, "fans in system mode 3 are left alone")
    // A helper restart after a crash releases exactly what the old run held.
    let record = FanHeldMemory()
    let crashed = FanHelperEngine(smc: smc, held: record)
    crashed.start(now: t4)
    smc.set("F0Md", 0, type: "ui8 ")
    _ = crashed.handle(.setTarget(fan: 0, rpm: 2600), now: t4)
    check(record.state.fans == [0], "held fans recorded")
    // (crash: no cleanup). Meanwhile another app takes fan 1.
    smc.set("F1Md", 1, type: "ui8 ")
    let restarted = FanHelperEngine(smc: smc, held: record)
    restarted.start(now: t4)
    check(smc.value("F0Md") == 0, "helper restart: the fan it held goes back to Auto")
    check(smc.value("F1Md") == 1, "helper restart: another app's fan is left alone")
    check(record.state.fans.isEmpty, "record cleared after restart")
    // Another app's fan: never released, never taken over.
    smc.clearWrites()
    restarted.returnAllToAuto(reason: "test", now: t4)
    _ = restarted.handle(.auto(fan: 1), now: t4)
    check(smc.writes.isEmpty && smc.value("F1Md") == 1, "Auto paths never touch a fan this helper does not hold")
    let taken = restarted.handle(.setTarget(fan: 1, rpm: 3000), now: t4)
    check(!taken.ok && (taken.error ?? "").contains("another app") && smc.writes.isEmpty, "a fan another app holds is refused, not fought over")
    smc.set("F1Md", 0, type: "ui8 ")
    // Not root: writes fail, nothing claims success.
    let user = FakeSMC.appleSilicon()
    user.isRoot = false
    let userEngine = makeEngine(user, now: t0)
    check(!userEngine.handle(.setTarget(fan: 0, rpm: 2000), now: t0).ok && !userEngine.isControlling, "without root: refused")
}

func testEngineEdgeCases() {
    let t0 = Date(timeIntervalSince1970: 2_500_000)
    // The SMC reports a higher minimum while a fan is held: never hold below it.
    let smc = FakeSMC.appleSilicon()
    let engine = makeEngine(smc, now: t0)
    check(engine.handle(.setTarget(fan: 0, rpm: 1600), now: t0).ok, "edge: set 1600")
    smc.set("F0Mn", 2000)
    smc.set("F0Tg", 1600)
    engine.tick(now: t0.addingTimeInterval(1))
    check(smc.value("F0Tg") == 2000 && engine.manual[0] == 2000, "edge: minimum rose to 2000, held speed raised to it")
    smc.set("F0Mx", 1900 + 600)
    smc.set("F0Mn", 1499)
    check(engine.handle(.setTarget(fan: 0, rpm: 2500), now: t0.addingTimeInterval(2)).ok, "edge: set 2500")
    smc.set("F0Mx", 2200)
    engine.tick(now: t0.addingTimeInterval(3))
    check(smc.value("F0Tg") == 2200, "edge: maximum fell, held speed lowered to it")
    engine.returnAllToAuto(reason: nil, now: t0.addingTimeInterval(4))

    // No die sensor readable when the helper started (SMC not ready at boot):
    // manual is refused, then allowed once the sensors appear.
    let cold = FakeSMC.appleSilicon()
    for key in ["Tp01", "Tp05", "Tg05"] { cold.set(key, 0) }
    let late = makeEngine(cold, now: t0)
    check(!late.handle(.setTarget(fan: 0, rpm: 2000), now: t0).ok, "edge: no sensors at start: refused")
    for (key, v) in [("Tp01", 60.0), ("Tp05", 62.0), ("Tg05", 55.0)] { cold.set(key, v) }
    check(!late.handle(.setTarget(fan: 0, rpm: 2000), now: t0.addingTimeInterval(5)).ok, "edge: rediscovery rate limited")
    let ok = late.handle(.setTarget(fan: 0, rpm: 2000), now: t0.addingTimeInterval(31))
    check(ok.ok && cold.value("F0Md") == 1, "edge: sensors rediscovered, manual allowed: \(ok.error ?? "")")
    late.returnAllToAuto(reason: nil, now: t0.addingTimeInterval(32))
    check(cold.value("F0Md") == 0, "edge: back to Auto")
}

func testEngineM4() {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    let smc = FakeSMC.m4()
    let engine = makeEngine(smc, now: t0)
    let r = engine.handle(.setTarget(fan: 0, rpm: 2500), now: t0)
    check(r.ok, "M4: request accepted (pending unlock)")
    check(smc.value("Ftst") == 1, "M4: Ftst set")
    check(engine.nextTickInterval == 0.1, "M4: fast retries while unlocking")
    check(r.status?.fans.first?.manual == true, "M4: pending fan reported as under control")
    for i in 1...3 { engine.tick(now: t0.addingTimeInterval(Double(i) * 0.1)) }
    check(smc.value("F0Md") == 3, "M4: still refused for the first attempts")
    engine.tick(now: t0.addingTimeInterval(0.4))
    check(smc.value("F0Md") == 1 && smc.value("F0Tg") == 2500, "M4: manual after unlock")
    _ = engine.handle(.auto(fan: 0), now: t0.addingTimeInterval(1))
    check(smc.value("F0Md") == 0 && smc.value("Ftst") == 0, "M4: releasing the last fan clears Ftst")
    // Unlock timeout.
    let slow = FakeSMC.m4()
    slow.unlockAttempts = 1000
    let slowEngine = makeEngine(slow, now: t0)
    _ = slowEngine.handle(.setTarget(fan: 1, rpm: 2500), now: t0)
    slowEngine.tick(now: t0.addingTimeInterval(5))
    check(slowEngine.isControlling, "M4: waiting within 10 s")
    _ = slowEngine.handle(.heartbeat, now: t0.addingTimeInterval(9))
    slowEngine.tick(now: t0.addingTimeInterval(10.1))
    check(!slowEngine.isControlling && slow.value("Ftst") == 0 && slow.value("F1Md") == 3, "M4: gives up after 10 s, Ftst cleared")
    // Start clears a leftover Ftst it set itself, and not one another app set.
    let leftover = FakeSMC.m4()
    leftover.set("Ftst", 1, type: "ui8 ")
    let ours = FanHeldMemory()
    ours.state = FanHeldState(fans: [], testFlag: true)
    FanHelperEngine(smc: leftover, held: ours).start(now: t0)
    check(leftover.value("Ftst") == 0, "M4: helper start clears its own leftover Ftst")
    leftover.set("Ftst", 1, type: "ui8 ")
    FanHelperEngine(smc: leftover, held: FanHeldMemory()).start(now: t0)
    check(leftover.value("Ftst") == 1, "M4: another app's Ftst is left alone")
    // The file store round trip (in the work directory).
    let file = FanHeldFile(path: "fan-held-test.json")
    file.save(FanHeldState(fans: [0, 1, 42], testFlag: true))
    check(file.load() == FanHeldState(fans: [0, 1], testFlag: true), "held file round trip drops impossible fan indexes")
    unlink("fan-held-test.json")
    check(FanHeldFile(path: "missing.json").load() == FanHeldState(), "missing held file = nothing held")
}

func testEngineIntel() {
    let t0 = Date(timeIntervalSince1970: 4_000_000)
    let smc = FakeSMC.intel()
    let engine = makeEngine(smc, now: t0)
    check(engine.handle(.setTarget(fan: 0, rpm: 4000), now: t0).ok, "Intel: set accepted")
    check(smc.value("FS! ") == 1 && smc.value("F0Tg") == 4000, "Intel: FS! bit 0 and fpe2 target")
    check(engine.handle(.setTarget(fan: 0, rpm: 1999), now: t0).ok == false, "Intel: below 2000 minimum refused")
    _ = engine.handle(.auto(fan: 0), now: t0)
    check(smc.value("FS! ") == 0, "Intel: bit cleared")
    smc.set("TC0D", 99, type: "sp78")
    _ = engine.handle(.setTarget(fan: 0, rpm: 4000), now: t0)
    check(smc.value("FS! ") == 0, "Intel: sp78 die over the limit refuses manual")
    check(FanSensorCatalog.isDie(smcKey: "TC0D") && !FanSensorCatalog.isDie(smcKey: "TC0P") && !FanSensorCatalog.isDie(smcKey: "TB0T"),
          "die sensor classification")
}

// MARK: - Socket server + client, end to end (fake SMC, temp socket)

func testServerAndClient(workDir: String) {
    FileManager.default.changeCurrentDirectoryPath(workDir)
    FileManager.default.createFile(atPath: "fan-test.plist", contents: Data())
    var always: SecRequirement?
    var never: SecRequirement?
    SecRequirementCreateWithString("always" as CFString, SecCSFlags(), &always)
    SecRequirementCreateWithString("never" as CFString, SecCSFlags(), &never)
    let smc = FakeSMC.appleSilicon()
    let engine = FanHelperEngine(smc: smc)
    let server = FanHelperServer(engine: engine, requirement: always!, socketPath: "fan-ok.sock", log: { _ in })
    do { try server.start() } catch { check(false, "server start: \(error)"); return }
    let client = FanHelperClient(socketPath: "fan-ok.sock", plistPath: "fan-test.plist", requiredOwner: getuid())
    if case .success(let r) = client.sendAndWait(.status) {
        check(r.ok && r.status?.version == FanHelperConstants.protocolVersion && r.status?.fans.count == 2, "e2e: status over the socket")
    } else { check(false, "e2e: status") }
    if case .success(let r) = client.sendAndWait(.setTarget(fan: 0, rpm: 2400)) {
        check(r.ok, "e2e: set ok")
    } else { check(false, "e2e: set") }
    check(server.queue.sync { smc.value("F0Md") == 1 && smc.value("F0Tg") == 2400 }, "e2e: fake SMC switched to manual")
    if case .success(let r) = client.sendAndWait(.setTarget(fan: 0, rpm: 100)) {
        check(!r.ok && (r.error ?? "").contains("minimum"), "e2e: below-minimum refused by helper")
    } else { check(false, "e2e: below minimum") }

    // A raw client sending a forged command.
    let raw = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array("fan-ok.sock".utf8) + [0]) }
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    let forged = #"{"op":"set","fan":0,"rpm":2400,"key":"F0Mn"}"# + "\n"
    _ = forged.withCString { write(raw, $0, strlen($0)) }
    var reply = [UInt8](repeating: 0, count: 1024)
    let n = read(raw, &reply, reply.count)
    let text = n > 0 ? String(decoding: reply[0..<n], as: UTF8.self) : ""
    check(text.contains("\"ok\":false") && text.contains("wrong fields"), "e2e: forged command refused")
    let huge = String(repeating: "x", count: 2000)
    _ = huge.withCString { write(raw, $0, strlen($0)) }
    usleep(100_000)
    let after = read(raw, &reply, reply.count)
    check(after >= 0, "e2e: overlong line answered then dropped")
    close(raw)

    client.disconnect()
    usleep(200_000)
    check(server.queue.sync { smc.value("F0Md") == 0 }, "e2e: client disconnect returns the fan to Auto")

    // A client that fails the code-signing requirement.
    let strictSMC = FakeSMC.appleSilicon()
    let strict = FanHelperServer(engine: FanHelperEngine(smc: strictSMC), requirement: never!, socketPath: "fan-no.sock", log: { _ in })
    do { try strict.start() } catch { check(false, "strict server start"); return }
    let outsider = FanHelperClient(socketPath: "fan-no.sock", plistPath: "fan-test.plist", requiredOwner: getuid())
    if case .failure(let e) = outsider.sendAndWait(.setTarget(fan: 0, rpm: 2400)) {
        check(e.state == .unauthorized, "e2e: unsigned client refused (\(e.state))")
    } else { check(false, "e2e: outsider should fail") }
    check(strict.queue.sync { strictSMC.value("F0Md") == 0 }, "e2e: refused client changed nothing")

    // Ownership check: the app only talks to a root-owned socket.
    let picky = FanHelperClient(socketPath: "fan-ok.sock", plistPath: "fan-test.plist", requiredOwner: 0)
    if case .failure(let e) = picky.sendAndWait(.status) {
        check(getuid() == 0 || e.message == "untrusted socket", "e2e: non-root socket not trusted")
    } else { check(getuid() == 0, "e2e: non-root socket must not be trusted") }
    let missing = FanHelperClient(socketPath: "nope.sock", plistPath: "nope.plist", requiredOwner: getuid())
    if case .failure(let e) = missing.sendAndWait(.status) { check(e.state == .notInstalled, "e2e: not installed") }
    for f in ["fan-ok.sock", "fan-no.sock", "fan-test.plist"] { unlink(f) }
}

// MARK: - Controller with the engine behind a fake transport

final class EngineTransport: FanHelperTransport, @unchecked Sendable {
    let engine: FanHelperEngine
    var installed = true
    var failing: FanHelperClientError?
    private(set) var sent: [FanCommand] = []
    private let lock = NSLock()

    init(engine: FanHelperEngine) { self.engine = engine }

    var isInstalled: Bool { installed }

    private func answer(_ command: FanCommand) -> Result<FanHelperResponse, FanHelperClientError> {
        lock.lock(); defer { lock.unlock() }
        sent.append(command)
        if let failing { return .failure(failing) }
        return .success(engine.handle(command, now: Date()))
    }

    func send(_ command: FanCommand, completion: @escaping @Sendable (Result<FanHelperResponse, FanHelperClientError>) -> Void) {
        completion(answer(command))
    }

    func sendAndWait(_ command: FanCommand) -> Result<FanHelperResponse, FanHelperClientError> { answer(command) }
    func disconnect() {}
}

@MainActor
func settle() async {
    // One controller pass hops to the sampler queue and back; 400 ms is
    // plenty even under Thread Sanitizer.
    for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor
func testController() async {
    let smc = FakeSMC.appleSilicon()
    let engine = FanHelperEngine(smc: smc)
    engine.start(now: Date())
    let transport = EngineTransport(engine: engine)
    let store = FanMemoryStore()
    let sampler = FanSensorSampler(makeBackend: { smc }, usesHID: false)
    let controller = FanController(sampler: sampler, helper: transport, store: store, observesSystem: false)
    var activity: [FanActivityState?] = []
    controller.activitySink = { activity.append($0) }

    controller.apply(sampler.sampleNow(.standard))
    check(controller.modes == [.auto, .auto], "controller: Auto by default")
    check(transport.sent.isEmpty, "controller: nothing sent while everything is Auto")
    check(controller.snapshot.sensor("agg.cpu.max")?.celsius == 62, "controller: hottest CPU aggregate")
    check(controller.snapshot.sensor("smc.TB0T")?.name == "Battery", "controller: named sensor")
    check(controller.activityState == nil, "controller: no activity while Auto")

    check(controller.setMode(.constant(rpm: 1000), for: 0), "controller: constant accepted")
    check(controller.mode(for: 0) == .constant(rpm: 1499), "controller: below-minimum request clamped to minimum")
    await settle()
    check(smc.value("F0Md") == 1 && smc.value("F0Tg") == 1499, "controller → engine → SMC: fan 0 at its minimum")
    check(controller.isManual(0) && controller.manualFanCount == 1, "controller: fan 0 shown manual")
    check(controller.activityState?.manualFans == 1, "controller: live activity while manual")
    check(activity.last??.manualFans == 1, "controller: activity posted")

    smc.set("Tp05", 65)
    controller.setMode(.sensor(id: "agg.cpu.max", startC: 50, maxC: 80), for: 1)
    await settle()
    check(smc.value("F1Tg") == 3125, "controller: sensor curve target 65 °C → 3125 rpm (got \(smc.value("F1Tg") ?? -1))")

    // Heartbeat when nothing changes.
    let before = transport.sent.count
    var later = sampler.sampleNow(.minimal(["agg.cpu.max"]))
    later.date = Date().addingTimeInterval(5)
    controller.apply(later)
    await settle()
    check(transport.sent.count == before + 1 && transport.sent.last == .heartbeat, "controller: heartbeat while idle-manual")

    // A sensor that vanished.
    controller.setMode(.sensor(id: "smc.ZZZZ", startC: 50, maxC: 80), for: 1)
    await settle()
    check(smc.value("F1Md") == 0 && (controller.notice ?? "").contains("sensor unavailable"), "controller: missing sensor → Auto + notice")

    // Presets.
    controller.applyPreset(FanPreset.builtins.first { $0.builtin == .fullBlast }!)
    await settle()
    check(smc.value("F0Tg") == 4296 && smc.value("F1Tg") == 4744, "controller: full blast = each fan's maximum")
    check(controller.activePresetID == "builtin.fullBlast", "controller: active preset")
    controller.saveCurrentAsPreset(named: "  Loud  ")
    check(store.settings.customPresets.first?.name == "Loud" && store.settings.customPresets.first?.modes == [.constant(rpm: 4296), .constant(rpm: 4744)],
          "controller: custom preset saved")
    controller.resetAllToAuto()
    await settle()
    check(smc.value("F0Md") == 0 && smc.value("F1Md") == 0 && controller.modes == [.auto, .auto], "controller: all to Auto")
    check(controller.activityState == nil, "controller: activity gone after Auto")

    // Failsafe through the whole chain.
    controller.setMode(.constant(rpm: 3000), for: 0)
    await settle()
    smc.set("Tp05", 110)
    engine.tick(now: Date())
    check(smc.value("F0Md") == 0, "failsafe: engine put the fan on Auto")
    controller.apply(sampler.sampleNow(.standard))
    await settle()
    check(controller.failsafeText != nil && !controller.isManual(0) && smc.value("F0Md") == 0, "failsafe: controller cannot re-take control")
    check(controller.activityState?.failsafe != nil, "failsafe: shown in the notch")
    smc.set("Tp05", 62)

    // Sleep and quit.
    controller.willSleep()
    check(transport.sent.last == .allAuto, "sleep: allAuto sent synchronously")
    controller.didWake(delay: .milliseconds(1))
    await settle()

    // Helper gone.
    transport.failing = FanHelperClientError(state: .notRunning, message: "closed")
    controller.setMode(.constant(rpm: 2000), for: 1)
    await settle()
    check(controller.helperState == .notRunning && (controller.notice ?? "").contains("Auto"), "helper lost: state and notice")
    transport.failing = nil

    // Not installed.
    transport.installed = false
    check(!controller.setMode(.constant(rpm: 2000), for: 0), "not installed: manual refused")
    check(controller.helperState == .notInstalled, "not installed: state")
    transport.installed = true

    // Restore on launch: off by default.
    let restoreStore = FanMemoryStore()
    restoreStore.settings.lastModes = [.constant(rpm: 2000), .auto]
    let c2 = FanController(sampler: FanSensorSampler(makeBackend: { smc }, usesHID: false), helper: transport, store: restoreStore, observesSystem: false)
    c2.apply(FanSensorSampler(makeBackend: { smc }, usesHID: false).sampleNow(.standard))
    check(c2.modes == [.auto, .auto], "restore off: launch on Auto")
    restoreStore.settings.restoreOnLaunch = true
    let c3 = FanController(sampler: FanSensorSampler(makeBackend: { smc }, usesHID: false), helper: transport, store: restoreStore, observesSystem: false)
    c3.apply(FanSensorSampler(makeBackend: { smc }, usesHID: false).sampleNow(.standard))
    check(c3.modes == [.constant(rpm: 2000), .auto], "restore on: last modes")
    c3.start()
    await settle()
    c3.stop()
    check(transport.sent.last == .allAuto, "quit: allAuto")

    // Another app (Macs Fan Control...) holds fan 1: SparkV stays off it.
    let shared = FakeSMC.appleSilicon()
    let sharedEngine = FanHelperEngine(smc: shared)
    sharedEngine.start(now: Date())
    let sharedTransport = EngineTransport(engine: sharedEngine)
    let sharedSampler = FanSensorSampler(makeBackend: { shared }, usesHID: false)
    let c5 = FanController(sampler: sharedSampler, helper: sharedTransport, store: FanMemoryStore(), observesSystem: false)
    shared.set("F1Md", 1, type: "ui8 ")
    shared.set("F1Tg", 3333)
    c5.apply(sharedSampler.sampleNow(.standard))
    check(c5.isControlledElsewhere(1) && !c5.isControlledElsewhere(0), "other app: fan 1 detected as held elsewhere")
    check(c5.conflictText != nil, "other app: conflict explained")
    check(!c5.setMode(.constant(rpm: 2000), for: 1) && c5.mode(for: 1) == .auto, "other app: SparkV refuses to take its fan")
    c5.applyPreset(FanPreset.builtins.first { $0.builtin == .fullBlast }!)
    await settle()
    check(c5.mode(for: 1) == .auto && shared.value("F1Tg") == 3333 && shared.value("F1Md") == 1, "other app: presets skip its fan, its target untouched")
    check(shared.value("F0Md") == 1 && shared.value("F0Tg") == 4296, "other app: SparkV still controls the free fan")
    c5.resetAllToAuto()
    await settle()
    check(shared.value("F0Md") == 0 && shared.value("F1Md") == 1, "other app: All to Auto releases only SparkV's fan")

    // No fans (MacBook Air): read-only, no commands.
    let air = FakeSMC()
    air.set("FNum", 0, type: "ui8 ")
    air.set("Tp01", 50)
    let airTransport = EngineTransport(engine: FanHelperEngine(smc: air))
    let c4 = FanController(sampler: FanSensorSampler(makeBackend: { air }, usesHID: false), helper: airTransport, store: FanMemoryStore(), observesSystem: false)
    c4.apply(FanSensorSampler(makeBackend: { air }, usesHID: false).sampleNow(.standard))
    check(!c4.hasFans && !c4.setMode(.constant(rpm: 2000), for: 0) && c4.snapshot.sensor("agg.cpu.max") != nil, "no fans: temperatures only")
    // SMC unavailable.
    let none = FanSensorSampler(makeBackend: { nil }, usesHID: false).sampleNow(.standard)
    check(!none.smcAvailable && none.fans.isEmpty, "no SMC: empty snapshot")
}

// MARK: - Live, read-only

func testLive() {
    guard let smc = try? FanAppleSMC() else { print("live: no AppleSMC"); return }
    let sampler = FanSensorSampler(makeBackend: { smc }, usesHID: true)
    var start = Date()
    let first = sampler.sampleNow(.standard)
    let firstMS = Date().timeIntervalSince(start) * 1000
    start = Date()
    let standard = sampler.sampleNow(.standard)
    let standardMS = Date().timeIntervalSince(start) * 1000
    start = Date()
    let minimal = sampler.sampleNow(.minimal(["agg.cpu.max"]))
    let minimalMS = Date().timeIntervalSince(start) * 1000
    start = Date()
    let all = sampler.sampleNow(.all)
    let allMS = Date().timeIntervalSince(start) * 1000
    _ = first
    print(String(format: "live: first pass %.0f ms (discovery), standard %.1f ms, minimal %.1f ms, all %.0f ms", firstMS, standardMS, minimalMS, allMS))
    for fan in standard.fans {
        print("live: fan \(fan.index): \(FanFormat.rpm(fan.actual)) rpm (target \(FanFormat.rpm(fan.target)), min \(FanFormat.rpm(fan.minimum)), max \(FanFormat.rpm(fan.maximum)), mode \(fan.mode ?? -1))")
    }
    for s in standard.sensors.prefix(12) { print("live: \(s.name): \(String(format: "%.1f", s.celsius)) °C") }
    print("live: sensors standard \(standard.sensors.count), minimal \(minimal.sensors.count), all \(all.sensors.count)")
    check(!standard.fans.isEmpty || FanSMCReader.fanCount(smc) == 0, "live: fans read")
    check(standard.fans.allSatisfy { $0.validLimits != nil }, "live: every fan reports limits")
    check(standard.sensor("agg.cpu.max") != nil, "live: hottest CPU readable")
    // Read-only by design: the live section never calls write().
}

// MARK: - Run

let workDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let live = CommandLine.arguments.contains("--live")
// Every file the tests create (sockets, the held-fan record) lands in the work directory.
FileManager.default.changeCurrentDirectoryPath(workDir)
testCodec()
testParamBlock()
testProtocol()
testCurve()
testFailsafe()
testEngineAppleSilicon()
testEngineEdgeCases()
testEngineM4()
testEngineIntel()
testServerAndClient(workDir: workDir)
await testController()
if live { testLive() }
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
