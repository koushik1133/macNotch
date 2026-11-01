import Darwin
import Foundation
import SwiftUI

// MARK: - Readings (pure math)

/// Per-CPU tick counters from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
struct CPUTicks: Equatable, Sendable {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0
    var nice: UInt64 = 0

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

enum SystemGaugeMath {
    /// Busy fraction across all CPUs between two samples (iStat Menus' "CPU
    /// total"). 32-bit kernel counters can wrap, so each delta wraps too.
    static func cpuLoad(previous: [CPUTicks], current: [CPUTicks]) -> Double? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for (a, b) in zip(previous, current) {
            let du = delta32(a.user, b.user), ds = delta32(a.system, b.system)
            let dn = delta32(a.nice, b.nice), di = delta32(a.idle, b.idle)
            busy += du + ds + dn
            total += du + ds + dn + di
        }
        guard total > 0 else { return nil }
        return min(1, max(0, Double(busy) / Double(total)))
    }

    /// Difference of two counters that are really `UInt32` and may wrap.
    static func delta32(_ old: UInt64, _ new: UInt64) -> UInt64 {
        new >= old ? new - old : (new &+ (1 << 32)) &- old
    }

    /// Activity Monitor's "Memory Used": app memory (internal minus purgeable)
    /// plus wired plus compressed, over physical memory.
    static func memoryUsed(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                           compressedPages: UInt64, pageSize: UInt64, physical: UInt64) -> (bytes: UInt64, fraction: Double) {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let bytes = (app + wiredPages + compressedPages) * pageSize
        guard physical > 0 else { return (bytes, 0) }
        return (bytes, min(1, Double(bytes) / Double(physical)))
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }
}

/// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// Neutral while all is well; amber and SparkV red only when it matters.
    var color: Color {
        switch self {
        case .normal: SparkVTheme.text.opacity(0.85)
        case .warning: SparkVTheme.warning
        case .critical: SparkVTheme.destructive
        }
    }
}

extension ProcessInfo.ThermalState {
    var widgetLabel: String {
        switch self {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    var widgetFraction: Double {
        switch self {
        case .nominal: 0.25
        case .fair: 0.5
        case .serious: 0.75
        case .critical: 1
        @unknown default: 0
        }
    }

    var widgetColor: Color {
        switch self {
        case .nominal: SparkVTheme.text.opacity(0.85)
        case .fair: SparkVTheme.warning.opacity(0.8)
        case .serious: SparkVTheme.warning
        case .critical: SparkVTheme.destructive
        @unknown default: SparkVTheme.textTertiary
        }
    }
}

// MARK: - Probes (system calls)

enum SystemProbe {
    static func cpuTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                            idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    static func memory() -> (bytes: UInt64, fraction: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return SystemGaugeMath.memoryUsed(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(pageSize),
            physical: ProcessInfo.processInfo.physicalMemory
        )
    }

    static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }
}

// MARK: - Sampler

/// CPU, memory and thermal readings every 2 s while any gauge view is on
/// screen (reference-counted through `WidgetSamplingLoop`).
@MainActor
final class SystemGaugesSampler: ObservableObject {
    static let shared = SystemGaugesSampler()
    static let historyLength = 30

    @Published private(set) var cpu: Double?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryFraction: Double?
    @Published private(set) var memoryBytes: UInt64 = 0
    @Published private(set) var pressure: MemoryPressure = .normal
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var sampleCount = 0

    private var previousTicks: [CPUTicks] = []
    private lazy var loop = WidgetSamplingLoop { [weak self] in self?.sample() }

    var isRunning: Bool { loop.isRunning }
    func start() { loop.retain() }
    func stop() {
        loop.release()
        if !loop.isRunning { previousTicks = [] }
    }

    func sample() {
        sampleCount += 1
        if let ticks = SystemProbe.cpuTicks() {
            if let load = SystemGaugeMath.cpuLoad(previous: previousTicks, current: ticks) {
                cpu = load
                cpuHistory = Array((cpuHistory + [load]).suffix(Self.historyLength))
            }
            previousTicks = ticks
        }
        if let memory = SystemProbe.memory() {
            memoryFraction = memory.fraction
            memoryBytes = memory.bytes
        }
        pressure = SystemProbe.memoryPressure()
        thermal = ProcessInfo.processInfo.thermalState
    }

    /// Synthetic values for offscreen renders.
    func preview(cpu: Double, memory: Double, pressure: MemoryPressure, thermal: ProcessInfo.ThermalState, history: [Double]) {
        self.cpu = cpu
        memoryFraction = memory
        memoryBytes = UInt64(memory * 36 * 1_073_741_824)
        self.pressure = pressure
        self.thermal = thermal
        cpuHistory = history
    }

    static func cpuColor(_ load: Double) -> Color {
        load < 0.5 ? SparkVTheme.text.opacity(0.85) : load < 0.8 ? SparkVTheme.warning : SparkVTheme.destructive
    }
}

// MARK: - Views

/// CPU load, memory used (colored by pressure) and thermal state, as rings.
struct SystemGaugesWidget: View {
    @ObservedObject var sampler: SystemGaugesSampler = .shared
    var size: WidgetSize = .wide
    /// Draw without starting the sampler (offscreen renders).
    var samples = true

    var body: some View {
        WidgetCard(padding: 6) {
            if size == .small {
                HStack(spacing: 4) {
                    cpuRing(showLabel: true)
                    memoryRing(showLabel: true)
                    thermalRing(showLabel: true)
                }
            } else {
                HStack(spacing: 6) {
                    gaugeColumn(ring: cpuRing(showLabel: false), title: "CPU",
                                value: sampler.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                                detail: nil, history: sampler.cpuHistory)
                    gaugeColumn(ring: memoryRing(showLabel: false), title: "Memory",
                                value: sampler.memoryFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                                detail: sampler.memoryFraction == nil ? nil : SystemGaugeMath.gigabytes(sampler.memoryBytes),
                                history: nil)
                    gaugeColumn(ring: thermalRing(showLabel: false), title: "Thermal",
                                value: sampler.thermal.widgetLabel, detail: nil, history: nil)
                }
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("System gauges")
        .accessibilityValue(helpText.replacingOccurrences(of: "\n", with: ", "))
        .whileVisible(start: { if samples { sampler.start() } }, stop: { if samples { sampler.stop() } })
    }

    private var helpText: String {
        let cpu = sampler.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "measuring"
        let memory = sampler.memoryFraction.map { "\(Int(($0 * 100).rounded()))% (\(SystemGaugeMath.gigabytes(sampler.memoryBytes)))" } ?? "measuring"
        return "CPU \(cpu)\nMemory \(memory), pressure \(sampler.pressure.label.lowercased())\nThermal state: \(sampler.thermal.widgetLabel)"
    }

    private func gaugeColumn<Ring: View>(ring: Ring, title: String, value: String, detail: String?, history: [Double]?) -> some View {
        HStack(spacing: 4) {
            ring.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased()).font(WidgetStyle.label(7)).tracking(WidgetStyle.labelTracking).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(WidgetStyle.tertiaryText)
                Text(value)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let detail {
                    Text(detail).font(.system(size: 7.5, weight: .medium).monospacedDigit()).foregroundStyle(WidgetStyle.tertiaryText).lineLimit(1)
                } else if let history, history.count > 1 {
                    WidgetSparkline(values: history, peak: 1, tint: SystemGaugesSampler.cpuColor(sampler.cpu ?? 0), filled: false)
                        .frame(height: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func smallLabel<Ring: View>(_ ring: Ring, _ title: String) -> some View {
        VStack(spacing: 2) {
            ring.aspectRatio(1, contentMode: .fit)
            Text(title).font(WidgetStyle.label(7)).tracking(WidgetStyle.labelTracking).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(WidgetStyle.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cpuRing(showLabel: Bool) -> some View {
        let load = sampler.cpu ?? 0
        let ring = WidgetRing(fraction: load, tint: SystemGaugesSampler.cpuColor(load), lineWidth: 3) {
            Text(sampler.cpu.map { "\(Int(($0 * 100).rounded()))" } ?? "-")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .minimumScaleFactor(0.6)
        }
        if showLabel { smallLabel(ring, "CPU") } else { ring }
    }

    @ViewBuilder
    private func memoryRing(showLabel: Bool) -> some View {
        let ring = WidgetRing(fraction: sampler.memoryFraction ?? 0, tint: sampler.pressure.color, lineWidth: 3) {
            Text(sampler.memoryFraction.map { "\(Int(($0 * 100).rounded()))" } ?? "-")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .minimumScaleFactor(0.6)
        }
        if showLabel { smallLabel(ring, "MEM") } else { ring }
    }

    @ViewBuilder
    private func thermalRing(showLabel: Bool) -> some View {
        let ring = WidgetRing(fraction: sampler.thermal.widgetFraction, tint: sampler.thermal.widgetColor, lineWidth: 3) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(sampler.thermal.widgetColor)
        }
        if showLabel { smallLabel(ring, "TEMP") } else { ring }
    }
}
