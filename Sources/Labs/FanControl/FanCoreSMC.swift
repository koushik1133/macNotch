import Foundation
import IOKit

// Shared by SparkV and the privileged helper (sparkv-fanhelper): Foundation
// and IOKit only, no SwiftUI, no top-level code.
//
// The System Management Controller is reached through the AppleSMC kernel
// user client. Every request is one 80-byte parameter block passed to
// selector 2 (kSMCHandleYPCEvent); the command byte says what to do:
// 9 = key info (size and type), 5 = read, 6 = write, 8 = key at index.
// The layout and command numbers are public knowledge (Apple's old
// AppleSMC sources, Asahi Linux, Stats by exelban, agoodkind/macos-smc-fan
// research notes). This file is an original implementation.

// MARK: - Keys

/// A four-character SMC key or type code ("F0Ac", "flt ").
struct FanSMCCode: Hashable, Sendable, CustomStringConvertible {
    let code: UInt32

    init(code: UInt32) { self.code = code }

    /// nil unless `string` is exactly four ASCII characters.
    init?(_ string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        code = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    var string: String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    var description: String { string }

    /// "F<i>Ac" style per-fan keys. nil for indexes that do not fit one
    /// character (the SMC only has 0-9 for fans).
    static func fan(_ index: Int, _ suffix: String) -> FanSMCCode? {
        guard (0...9).contains(index), suffix.utf8.count == 2 else { return nil }
        return FanSMCCode("F\(index)\(suffix)")
    }
}

struct FanSMCKeyInfo: Equatable, Sendable {
    let size: Int
    let type: FanSMCCode
    let attributes: UInt8
}

/// A raw SMC value with its type.
struct FanSMCValue: Equatable, Sendable {
    let key: FanSMCCode
    let type: FanSMCCode
    let bytes: [UInt8]

    var number: Double? { FanSMCCodec.decode(type: type, bytes: bytes) }
}

// MARK: - Codec

/// Converts SMC bytes to numbers and back. Pure, unit tested.
///
/// - `flt `: IEEE 754 Float32, little endian (Apple silicon fans and temps).
/// - `fpXY`: unsigned fixed point, big endian, X integer and Y fraction bits
///   in hex (`fpe2` = 14.2, Intel fan RPM: raw / 4).
/// - `spXY`: signed fixed point, big endian (`sp78` = 1 sign + 7.8, Intel temps: raw / 256).
/// - `ui8 `/`ui16`/`ui32`, `si8 `/`si16`/`si32`: big endian integers.
/// - `flag`: one byte, 0 or 1.
/// - `ioft`: 48.16 fixed point, little endian, 8 bytes.
enum FanSMCCodec {
    static let flt = FanSMCCode("flt ")!
    static let fpe2 = FanSMCCode("fpe2")!
    static let sp78 = FanSMCCode("sp78")!
    static let ui8 = FanSMCCode("ui8 ")!
    static let ui16 = FanSMCCode("ui16")!
    static let ui32 = FanSMCCode("ui32")!
    static let flag = FanSMCCode("flag")!

    private enum Kind: Equatable {
        case float32
        case unsignedFixed(fraction: Int)
        case signedFixed(fraction: Int)
        case unsigned(bytes: Int)
        case signed(bytes: Int)
        case flag
        case ioft
    }

    private static func kind(of type: FanSMCCode) -> Kind? {
        let s = type.string
        switch s {
        case "flt ": return .float32
        case "ui8 ": return .unsigned(bytes: 1)
        case "ui16": return .unsigned(bytes: 2)
        case "ui32": return .unsigned(bytes: 4)
        case "ui64": return .unsigned(bytes: 8)
        case "si8 ": return .signed(bytes: 1)
        case "si16": return .signed(bytes: 2)
        case "si32": return .signed(bytes: 4)
        case "flag": return .flag
        case "ioft": return .ioft
        default: break
        }
        let chars = Array(s)
        guard chars.count == 4,
              let whole = chars[2].hexDigitValue, let fraction = chars[3].hexDigitValue else { return nil }
        if chars[0] == "f", chars[1] == "p", whole + fraction == 16 { return .unsignedFixed(fraction: fraction) }
        if chars[0] == "s", chars[1] == "p", whole + fraction == 15 { return .signedFixed(fraction: fraction) }
        return nil
    }

    static func isNumeric(_ type: FanSMCCode) -> Bool { kind(of: type) != nil }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// nil for unknown types, short data or non-finite floats.
    static func decode(type: FanSMCCode, bytes: [UInt8]) -> Double? {
        guard let kind = kind(of: type) else { return nil }
        switch kind {
        case .float32:
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case .unsignedFixed(let fraction):
            guard bytes.count >= 2 else { return nil }
            return Double(bigEndian(bytes[0..<2])) / Double(1 << fraction)
        case .signedFixed(let fraction):
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bigEndian(bytes[0..<2])))
            return Double(raw) / Double(1 << fraction)
        case .unsigned(let count):
            guard bytes.count >= count else { return nil }
            return Double(bigEndian(bytes[0..<count]))
        case .signed(let count):
            guard bytes.count >= count else { return nil }
            let raw = bigEndian(bytes[0..<count])
            let shift = UInt64(64 - count * 8)
            return Double(Int64(bitPattern: raw << shift) >> Int64(shift))
        case .flag:
            guard let first = bytes.first else { return nil }
            return first == 0 ? 0 : 1
        case .ioft:
            guard bytes.count >= 8 else { return nil }
            let raw = bytes[0..<8].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return Double(raw) / 65536
        }
    }

    /// Bytes for `value` in `type`, `size` bytes long (the key's reported
    /// size). nil when the value does not fit the type or is not finite;
    /// the caller never writes a value it could not encode exactly.
    static func encode(_ value: Double, type: FanSMCCode, size: Int) -> [UInt8]? {
        guard value.isFinite, let kind = kind(of: type) else { return nil }
        var out: [UInt8]
        switch kind {
        case .float32:
            let bits = Float(value).bitPattern
            out = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        case .unsignedFixed(let fraction):
            let raw = (value * Double(1 << fraction)).rounded()
            guard raw >= 0, raw <= Double(UInt16.max) else { return nil }
            let r = UInt16(raw)
            out = [UInt8(r >> 8), UInt8(r & 0xFF)]
        case .signedFixed(let fraction):
            let raw = (value * Double(1 << fraction)).rounded()
            guard raw >= Double(Int16.min), raw <= Double(Int16.max) else { return nil }
            let r = UInt16(bitPattern: Int16(raw))
            out = [UInt8(r >> 8), UInt8(r & 0xFF)]
        case .unsigned(let count):
            let raw = value.rounded()
            let limit = count >= 8 ? Double(UInt64.max) : Double((UInt64(1) << UInt64(count * 8)) - 1)
            guard raw >= 0, raw <= limit else { return nil }
            let r = UInt64(raw)
            out = (0..<count).reversed().map { UInt8(r >> UInt64($0 * 8) & 0xFF) }
        case .signed(let count):
            let raw = value.rounded()
            let half = Double(UInt64(1) << UInt64(count * 8 - 1))
            guard raw >= -half, raw <= half - 1 else { return nil }
            let r = UInt64(bitPattern: Int64(raw))
            out = (0..<count).reversed().map { UInt8(r >> UInt64($0 * 8) & 0xFF) }
        case .flag:
            guard value == 0 || value == 1 else { return nil }
            out = [UInt8(value)]
        case .ioft:
            let raw = (value * 65536).rounded()
            guard raw >= 0, raw < Double(UInt64.max) else { return nil }
            let r = UInt64(raw)
            out = (0..<8).map { UInt8(r >> UInt64($0 * 8) & 0xFF) }
        }
        guard size >= out.count, size <= 32 else { return nil }
        // The SMC wants exactly the key's size; pad on the right (never seen
        // for numeric fan keys, but keeps the block well formed).
        return out + Array(repeating: 0, count: size - out.count)
    }
}

// MARK: - Errors

enum FanSMCError: Error, Equatable, CustomStringConvertible {
    case serviceNotFound
    case openFailed(Int32)
    case callFailed(Int32)
    /// The caller is not root (kIOReturnNotPrivileged): SMC writes need the helper.
    case notPrivileged
    /// The SMC's own result byte (0x84 = key not found, 0x82 = command refused...).
    case smcResult(UInt8)
    case keyNotFound(String)
    case badValue(String)

    var description: String {
        switch self {
        case .serviceNotFound: "AppleSMC service not found"
        case .openFailed(let code): String(format: "could not open AppleSMC (0x%08x)", UInt32(bitPattern: code))
        case .callFailed(let code): String(format: "SMC call failed (0x%08x)", UInt32(bitPattern: code))
        case .notPrivileged: "writing to the SMC needs root"
        case .smcResult(let code): String(format: "SMC refused (0x%02x)", code)
        case .keyNotFound(let key): "SMC key \(key) not found"
        case .badValue(let detail): "bad SMC value: \(detail)"
        }
    }
}

// MARK: - Backend protocol (real SMC, or a fake in tests)

protocol FanSMCBackend: AnyObject {
    func keyInfo(_ key: FanSMCCode) throws -> FanSMCKeyInfo
    func read(_ key: FanSMCCode) throws -> FanSMCValue
    func write(_ key: FanSMCCode, bytes: [UInt8]) throws
    func key(at index: Int) throws -> FanSMCCode
}

extension FanSMCBackend {
    func number(_ key: FanSMCCode) -> Double? { try? read(key).number }
    func number(_ key: String) -> Double? { FanSMCCode(key).flatMap { number($0) } }
    func has(_ key: FanSMCCode) -> Bool { (try? keyInfo(key)) != nil }

    /// Encodes `value` in the key's own type and size, then writes it.
    func writeNumber(_ key: FanSMCCode, _ value: Double) throws {
        let info = try keyInfo(key)
        guard let bytes = FanSMCCodec.encode(value, type: info.type, size: info.size) else {
            throw FanSMCError.badValue("\(value) does not fit \(key) (\(info.type))")
        }
        try write(key, bytes: bytes)
    }

    /// Number of keys the SMC exposes ("#KEY").
    func keyCount() -> Int { Int(number("#KEY") ?? 0) }
}

// MARK: - The 80-byte parameter block

/// Offsets of the C `SMCKeyData_t` (natural alignment, 80 bytes):
/// key 0, vers 4 (6 bytes), pLimitData 12 (16 bytes), keyInfo 28
/// (dataSize 28, dataType 32, attributes 36), result 40, status 41,
/// data8 (command) 42, data32 44, bytes 48..<80. Built byte by byte so the
/// layout never depends on Swift struct layout.
struct FanSMCParamBlock: Equatable {
    static let size = 80
    static let selector: UInt32 = 2
    enum Command: UInt8 { case read = 5, write = 6, keyAtIndex = 8, keyInfo = 9 }

    var raw = [UInt8](repeating: 0, count: FanSMCParamBlock.size)

    init() {}
    init(raw: [UInt8]) { self.raw = raw.count == Self.size ? raw : [UInt8](repeating: 0, count: Self.size) }

    private func u32(at offset: Int) -> UInt32 {
        raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
    private mutating func setU32(_ value: UInt32, at offset: Int) {
        raw.withUnsafeMutableBytes { $0.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
    }

    var key: FanSMCCode {
        get { FanSMCCode(code: u32(at: 0)) }
        set { setU32(newValue.code, at: 0) }
    }
    var dataSize: Int {
        get { Int(u32(at: 28)) }
        set { setU32(UInt32(max(0, newValue)), at: 28) }
    }
    var dataType: FanSMCCode {
        get { FanSMCCode(code: u32(at: 32)) }
        set { setU32(newValue.code, at: 32) }
    }
    var dataAttributes: UInt8 { raw[36] }
    var result: UInt8 { raw[40] }
    var command: UInt8 {
        get { raw[42] }
        set { raw[42] = newValue }
    }
    var data32: UInt32 {
        get { u32(at: 44) }
        set { setU32(newValue, at: 44) }
    }
    var bytes: [UInt8] {
        get { Array(raw[48..<80]) }
        set {
            let value = Array(newValue.prefix(32))
            for i in 0..<32 { raw[48 + i] = i < value.count ? value[i] : 0 }
        }
    }
}

// MARK: - The real AppleSMC

/// The AppleSMC user client. Reading works for any user; writing returns
/// `.notPrivileged` unless the process is root (only the helper writes).
final class FanAppleSMC: FanSMCBackend, @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [FanSMCCode: FanSMCKeyInfo] = [:]
    private var missing: Set<FanSMCCode> = []

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanSMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard status == kIOReturnSuccess else { throw FanSMCError.openFailed(status) }
        connection = conn
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: FanSMCParamBlock) throws -> FanSMCParamBlock {
        var output = FanSMCParamBlock()
        var outSize = FanSMCParamBlock.size
        let status = input.raw.withUnsafeBytes { inPtr in
            output.raw.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(connection, FanSMCParamBlock.selector,
                                          inPtr.baseAddress, FanSMCParamBlock.size,
                                          outPtr.baseAddress, &outSize)
            }
        }
        if status == kIOReturnNotPrivileged { throw FanSMCError.notPrivileged }
        guard status == kIOReturnSuccess else { throw FanSMCError.callFailed(status) }
        guard output.result == 0 else { throw FanSMCError.smcResult(output.result) }
        return output
    }

    func keyInfo(_ key: FanSMCCode) throws -> FanSMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        return try keyInfoLocked(key)
    }

    private func keyInfoLocked(_ key: FanSMCCode) throws -> FanSMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        if missing.contains(key) { throw FanSMCError.keyNotFound(key.string) }
        var block = FanSMCParamBlock()
        block.key = key
        block.command = FanSMCParamBlock.Command.keyInfo.rawValue
        do {
            let out = try call(block)
            let info = FanSMCKeyInfo(size: out.dataSize, type: out.dataType, attributes: out.dataAttributes)
            guard info.size > 0, info.size <= 32 else { throw FanSMCError.badValue("size \(info.size) for \(key)") }
            infoCache[key] = info
            return info
        } catch FanSMCError.smcResult(0x84) {
            missing.insert(key)
            throw FanSMCError.keyNotFound(key.string)
        }
    }

    func read(_ key: FanSMCCode) throws -> FanSMCValue {
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfoLocked(key)
        var block = FanSMCParamBlock()
        block.key = key
        block.dataSize = info.size
        block.command = FanSMCParamBlock.Command.read.rawValue
        let out = try call(block)
        return FanSMCValue(key: key, type: info.type, bytes: Array(out.bytes.prefix(info.size)))
    }

    func write(_ key: FanSMCCode, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfoLocked(key)
        guard bytes.count == info.size else { throw FanSMCError.badValue("\(bytes.count) bytes for \(key) (needs \(info.size))") }
        var block = FanSMCParamBlock()
        block.key = key
        block.dataSize = info.size
        block.command = FanSMCParamBlock.Command.write.rawValue
        block.bytes = bytes
        _ = try call(block)
    }

    func key(at index: Int) throws -> FanSMCCode {
        lock.lock(); defer { lock.unlock() }
        var block = FanSMCParamBlock()
        block.command = FanSMCParamBlock.Command.keyAtIndex.rawValue
        block.data32 = UInt32(max(0, index))
        return try call(block).key
    }
}
