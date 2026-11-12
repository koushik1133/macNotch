import Foundation
import Security

// Fans & Temperatures tests (read-only). Run with Tests/run-tests.sh. Every
// test reads a FakeSMC; the optional "live" section only READS this Mac's SMC.

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

// MARK: - Reading fans and sensors (fake SMC)

func testReader() {
    let m1 = FakeSMC.appleSilicon()
    let fans = FanSMCReader.fans(m1)
    check(fans.count == 2, "Apple silicon: two fans")
    check(approx(fans[0].actual, 1800) && approx(fans[0].minimum, 1499) && approx(fans[1].maximum, 4744), "Apple silicon: speeds and limits")
    check(fans.allSatisfy { $0.validLimits != nil }, "Apple silicon: limits valid")
    let intel = FakeSMC.intel()
    let one = FanSMCReader.fans(intel)
    check(one.count == 1 && approx(one[0].maximum, 6200), "Intel: fpe2 fan")
    let none = FakeSMC()
    check(FanSMCReader.fans(none).isEmpty, "no FNum: no fans")
    let sampler = FanSensorSampler(makeBackend: { m1 }, usesHID: false)
    let snap = sampler.sampleNow(.standard)
    check(snap.smcAvailable && snap.fans.count == 2, "sampler: fans")
    check(snap.sensor("agg.cpu.max").map { approx($0.celsius, 62) } ?? false, "sampler: hottest CPU 62")
    let broken = FakeSMC.appleSilicon()
    broken.broken = true
    let brokenSnap = FanSensorSampler(makeBackend: { broken }, usesHID: false).sampleNow(.standard)
    check(brokenSnap.fans.isEmpty, "broken SMC: no fans, no crash")
}

// MARK: - Controller (read-only)

@MainActor
func testController() {
    let store = FanMemoryStore()
    let controller = FanController(sampler: FanSensorSampler(makeBackend: { FakeSMC.appleSilicon() }, usesHID: false),
                                   store: store, observesSystem: false)
    var states: [FanActivityState?] = []
    controller.activitySink = { states.append($0) }
    var snap = FanSnapshot()
    snap.fans = FanSMCReader.fans(FakeSMC.appleSilicon())
    snap.smcAvailable = true
    controller.apply(snap)
    check(controller.hasFans && controller.name(for: 1) == "Fan 2", "controller: fans and names")
    check(controller.activityState == nil, "activity off by default")
    controller.settings.activity = .always
    check(controller.activityState?.rpms.count == 2, "activity on: two speeds")
    check(store.settings.activity == .always, "settings saved")
    controller.settings.fahrenheit = true
    check(controller.temperatureText(100) == "212°F", "Fahrenheit")
    // Settings from an older build (modes, presets, whileManual) still load.
    let old = #"{"restoreOnLaunch":true,"activity":"whileManual","fahrenheit":true,"showAllSensors":false,"lastModes":[],"customPresets":[]}"#
    let decoded = try? JSONDecoder().decode(FanSettings.self, from: Data(old.utf8))
    check(decoded?.fahrenheit == true && decoded?.activity == .never, "old settings decode")
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
FileManager.default.changeCurrentDirectoryPath(workDir)
testCodec()
testParamBlock()
testReader()
await MainActor.run { testController() }
if live { testLive() }
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
