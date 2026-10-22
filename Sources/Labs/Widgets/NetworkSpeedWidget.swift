import Darwin
import Foundation
import SwiftUI

// MARK: - Counters (pure math)

/// Byte counters of one interface from `getifaddrs` (`if_data`, 32-bit).
struct InterfaceCounters: Equatable, Sendable {
    let name: String
    let received: UInt64
    let sent: UInt64
}

enum NetworkSpeedMath {
    /// Interfaces that carry the same traffic again (VPN tunnels) or aren't
    /// real uplinks (AirDrop/AWDL, bridges, the iPhone USB link).
    static let excludedPrefixes = ["lo", "utun", "ipsec", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "vmenet", "XHC"]

    static func isCounted(_ name: String, isLoopback: Bool) -> Bool {
        !isLoopback && !excludedPrefixes.contains { name.hasPrefix($0) }
    }

    /// Bytes moved between two 32-bit counter readings. A drop means either a
    /// wrap at 4 GiB (old value near the top) or a counter reset (count the
    /// new value only), the heuristic Apple's DTS suggests for `if_data`.
    static func delta(old: UInt64, new: UInt64) -> UInt64 {
        if new >= old { return new - old }
        let wrapLimit: UInt64 = 1 << 32
        return old > wrapLimit * 3 / 4 ? (wrapLimit - old) + new : new
    }

    /// Total down/up bytes per second between two readings `seconds` apart.
    /// Interfaces that appeared since the last reading count from the next one.
    static func rates(previous: [InterfaceCounters], current: [InterfaceCounters], seconds: Double) -> (down: Double, up: Double)? {
        guard seconds > 0.2 else { return nil }
        let old = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var down: UInt64 = 0, up: UInt64 = 0
        for counters in current {
            guard let before = old[counters.name] else { continue }
            down += delta(old: before.received, new: counters.received)
            up += delta(old: before.sent, new: counters.sent)
        }
        return (Double(down) / seconds, Double(up) / seconds)
    }

    /// "14.2 MB/s", "512 KB/s", "0.0 KB/s"; decimal units like iStat Menus.
    static func format(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let units = ["KB/s", "MB/s", "GB/s"]
        var scaled = value / 1000
        var index = 0
        while scaled >= 999.5, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        let text = scaled < 99.95 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
        return "\(text) \(units[index])"
    }

    /// "↓ 14.2 MB/s ↑ 1.1 MB/s".
    static func summary(down: Double, up: Double) -> String {
        "↓ \(format(down)) ↑ \(format(up))"
    }

    /// The interface that moved the most bytes since `previous`. When nothing
    /// moved (idle), keeps `last` if it is still up, else prefers en0 (Wi-Fi
    /// on a MacBook) over idle Thunderbolt ports. Nil when no interface is up.
    static func activeInterface(previous: [InterfaceCounters], current: [InterfaceCounters], last: String?) -> String? {
        let old = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func moved(_ c: InterfaceCounters) -> UInt64 {
            guard let before = old[c.name] else { return 0 }
            return delta(old: before.received, new: c.received) + delta(old: before.sent, new: c.sent)
        }
        if let busiest = current.max(by: { moved($0) < moved($1) }), moved(busiest) > 0 { return busiest.name }
        if let last, current.contains(where: { $0.name == last }) { return last }
        return current.first { $0.name == "en0" }?.name ?? current.first?.name
    }

    static func friendlyName(_ interface: String?) -> String {
        guard let interface else { return "Offline" }
        if interface == "en0" { return "Wi-Fi" }
        if interface.hasPrefix("en") { return "Ethernet" }
        if interface.hasPrefix("pdp_ip") { return "Cellular" }
        return interface
    }
}

enum NetworkProbe {
    /// Link-layer counters of every up, counted interface.
    static func counters() -> [InterfaceCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var list: [InterfaceCounters] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = item.ifa_data else { continue }
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard NetworkSpeedMath.isCounted(name, isLoopback: flags & IFF_LOOPBACK != 0) else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            list.append(InterfaceCounters(name: name, received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes)))
        }
        return list
    }
}

// MARK: - Sampler

/// Down/up throughput every 2 s while a network view is on screen.
@MainActor
final class NetworkSpeedSampler: ObservableObject {
    static let shared = NetworkSpeedSampler()
    static let historyLength = 30

    @Published private(set) var down: Double?
    @Published private(set) var up: Double?
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []
    /// Busiest interface in the last interval ("en0").
    @Published private(set) var activeInterface: String?

    private var previous: [InterfaceCounters] = []
    private var previousAt: ContinuousClock.Instant?
    private let read: () -> [InterfaceCounters]
    private lazy var loop = WidgetSamplingLoop { [weak self] in self?.sample() }

    init(read: @escaping () -> [InterfaceCounters] = NetworkProbe.counters) {
        self.read = read
    }

    var isRunning: Bool { loop.isRunning }
    func start() { loop.retain() }
    func stop() {
        loop.release()
        if !loop.isRunning {
            // Restart measures from scratch instead of averaging the hidden time.
            previous = []
            previousAt = nil
        }
    }

    func sample(at now: ContinuousClock.Instant = .now) {
        let current = read()
        if let previousAt, let rates = NetworkSpeedMath.rates(
            previous: previous, current: current,
            seconds: Double((now - previousAt).components.seconds) + Double((now - previousAt).components.attoseconds) / 1e18
        ) {
            down = rates.down
            up = rates.up
            downHistory = Array((downHistory + [rates.down]).suffix(Self.historyLength))
            upHistory = Array((upHistory + [rates.up]).suffix(Self.historyLength))
            activeInterface = NetworkSpeedMath.activeInterface(previous: previous, current: current, last: activeInterface)
        } else if activeInterface == nil {
            activeInterface = NetworkSpeedMath.activeInterface(previous: [], current: current, last: nil)
        }
        previous = current
        previousAt = now
    }

    var summary: String {
        guard let down, let up else { return "Measuring…" }
        return NetworkSpeedMath.summary(down: down, up: up)
    }

    func preview(down: Double, up: Double, downHistory: [Double], upHistory: [Double], interface: String) {
        self.down = down
        self.up = up
        self.downHistory = downHistory
        self.upHistory = upHistory
        activeInterface = interface
    }
}

// MARK: - Views

struct NetworkSpeedWidget: View {
    @ObservedObject var sampler: NetworkSpeedSampler = .shared
    var size: WidgetSize = .wide
    var samples = true

    /// Apple: download blue, upload green (Activity Monitor). SparkV Red:
    /// download red, upload white.
    static var downTint: Color { SparkVTheme.choose(apple: Color.blue, sparkv: SparkVTheme.red) }
    static var upTint: Color { SparkVTheme.choose(apple: Color.green, sparkv: SparkVTheme.text.opacity(0.75)) }

    var body: some View {
        WidgetCard(padding: 7) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    rateRow(symbol: "arrow.down", tint: Self.downTint, value: sampler.down)
                    rateRow(symbol: "arrow.up", tint: Self.upTint, value: sampler.up)
                    Text(NetworkSpeedMath.friendlyName(sampler.activeInterface))
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(WidgetStyle.tertiaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: size == .small ? .infinity : nil, alignment: .leading)
                .fixedSize(horizontal: size != .small, vertical: false)
                if size != .small {
                    let peak = max(1000, (sampler.downHistory + sampler.upHistory).max() ?? 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("last minute, peak \(NetworkSpeedMath.format(peak))")
                            .font(.system(size: 7, weight: .medium).monospacedDigit())
                            .foregroundStyle(WidgetStyle.tertiaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        ZStack {
                            WidgetSparkline(values: sampler.downHistory, peak: peak, tint: Self.downTint)
                            WidgetSparkline(values: sampler.upHistory, peak: peak, tint: Self.upTint, filled: false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .help("\(sampler.summary) on \(NetworkSpeedMath.friendlyName(sampler.activeInterface)) (\(sampler.activeInterface ?? "no interface")). Updates every 2 seconds.")
        .whileVisible(start: { if samples { sampler.start() } }, stop: { if samples { sampler.stop() } })
    }

    private func rateRow(symbol: String, tint: Color, value: Double?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(tint)
                .frame(width: 10)
            Text(value.map(NetworkSpeedMath.format) ?? "--")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}
