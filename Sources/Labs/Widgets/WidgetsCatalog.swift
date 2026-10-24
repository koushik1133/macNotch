import SwiftUI

// MARK: - Catalog

/// The notch widgets, in their default order.
enum WidgetKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case clocks
    case volume
    case habits
    case gauges
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clocks: "World Clocks"
        case .volume: "Volume Knob"
        case .habits: "Daily Habits"
        case .gauges: "System"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .clocks: "globe"
        case .volume: "dial.medium.fill"
        case .habits: "checklist.checked"
        case .gauges: "cpu"
        case .network: "arrow.up.arrow.down"
        }
    }

    /// Apple: each widget keeps its own color, like the system widgets.
    /// SparkV Red: every widget shares the one accent; the glyph tells them
    /// apart.
    var tint: Color {
        guard SparkVTheme.isApple else { return SparkVTheme.red }
        return switch self {
        case .clocks: Color.orange
        case .volume: Color.pink
        case .habits: Color.green
        case .gauges: Color.blue
        case .network: Color.teal
        }
    }

    /// Sizes this widget can take, largest first. The layout starts at the
    /// largest that fits the grid and steps down when space runs out.
    var sizes: [WidgetSize] {
        switch self {
        case .clocks: [.wide, .small]
        case .volume: [.small]
        case .habits: [.large, .wide, .small]
        case .gauges: [.wide, .small]
        case .network: [.wide, .small]
        }
    }

    /// Lower shrinks first when the widgets don't all fit: the sparkline
    /// extras go before the clocks and the habit grid.
    var shrinkPriority: Int {
        switch self {
        case .network: 0
        case .gauges: 1
        case .clocks: 2
        case .habits: 3
        case .volume: 4
        }
    }
}

/// Cell spans on the widget grid.
enum WidgetSize: Int, Comparable, Sendable {
    /// 1x1 cell (about 118x54 pt in the tall drawer, 118x69 pt in the short one).
    case small
    /// 2x1 cells.
    case wide
    /// 2x2 cells (tall drawer only).
    case large

    var columns: Int { self == .small ? 1 : 2 }
    var rows: Int { self == .large ? 2 : 1 }
    var area: Int { columns * rows }

    static func < (lhs: WidgetSize, rhs: WidgetSize) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Settings

/// Which widgets the Widgets tab shows, in order. Persisted.
@MainActor
final class WidgetsSettings: ObservableObject {
    static let shared = WidgetsSettings()
    static let enabledKey = "SparkV.widgets.enabled"

    @Published private(set) var enabled: [WidgetKind]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Self.enabledKey) as? [String] {
            var seen = Set<WidgetKind>()
            enabled = raw.compactMap(WidgetKind.init(rawValue:)).filter { seen.insert($0).inserted }
        } else {
            enabled = WidgetKind.allCases
        }
    }

    func isEnabled(_ kind: WidgetKind) -> Bool { enabled.contains(kind) }

    /// Turning a widget on adds it at the end; off removes it.
    func setEnabled(_ kind: WidgetKind, _ on: Bool) {
        if on, !enabled.contains(kind) {
            enabled.append(kind)
        } else if !on {
            enabled.removeAll { $0 == kind }
        } else {
            return
        }
        save()
    }

    func toggle(_ kind: WidgetKind) { setEnabled(kind, !isEnabled(kind)) }

    /// Moves a widget one place earlier (-1) or later (+1).
    func move(_ kind: WidgetKind, by offset: Int) {
        guard let index = enabled.firstIndex(of: kind) else { return }
        let target = index + offset
        guard enabled.indices.contains(target) else { return }
        enabled.swapAt(index, target)
        save()
    }

    func resetToDefaults() {
        enabled = WidgetKind.allCases
        save()
    }

    private func save() {
        defaults.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
    }
}

// MARK: - Layout engine

/// Where one widget sits on the grid.
struct WidgetPlacement: Equatable, Sendable {
    let kind: WidgetKind
    let size: WidgetSize
    let column: Int
    let row: Int
}

/// Packs widgets on a columns x rows grid. Each widget starts at its largest
/// size that fits; while they don't all fit, the biggest one (ties: lowest
/// `shrinkPriority`) steps down a size. When even the smallest sizes overflow,
/// the rest flows onto further pages, and each page then grows its widgets
/// back into any free cells. Pure, so it is unit-tested.
enum WidgetGridLayout {
    static func pages(for kinds: [WidgetKind], columns: Int, rows: Int) -> [[WidgetPlacement]] {
        guard columns > 0, rows > 0, !kinds.isEmpty else { return [] }
        let fitting: (WidgetKind) -> [WidgetSize] = { kind in
            let sizes = kind.sizes.filter { $0.columns <= columns && $0.rows <= rows }
            return sizes.isEmpty ? [.small] : sizes
        }
        var sizes = kinds.map { fitting($0)[0] }

        // 1. Shrink until everything fits on one page.
        while pack(Array(zip(kinds, sizes)), columns: columns, rows: rows) == nil {
            let candidates = kinds.indices.filter { sizes[$0] > fitting(kinds[$0]).last! }
            guard let pick = candidates.max(by: { a, b in
                if sizes[a].area != sizes[b].area { return sizes[a].area < sizes[b].area }
                return kinds[a].shrinkPriority > kinds[b].shrinkPriority
            }) else { break }
            sizes[pick] = nextSmaller(sizes[pick], in: fitting(kinds[pick]))
        }
        if let page = pack(Array(zip(kinds, sizes)), columns: columns, rows: rows) {
            return [grow(page, columns: columns, rows: rows, fitting: fitting)]
        }

        // 2. Smallest sizes still overflow: paginate in order.
        var pages: [[(WidgetKind, WidgetSize)]] = [[]]
        for item in zip(kinds, sizes) {
            if pack(pages[pages.count - 1] + [item], columns: columns, rows: rows) != nil {
                pages[pages.count - 1].append(item)
            } else {
                pages.append([item])
            }
        }
        return pages.compactMap { items in
            pack(items, columns: columns, rows: rows).map { grow($0, columns: columns, rows: rows, fitting: fitting) }
        }
    }

    /// Row-major first-fit in the widgets' order; when that fragments the
    /// grid (a 2x2 after two wides), retries biggest-first. Nil when one doesn't fit.
    static func pack(_ items: [(WidgetKind, WidgetSize)], columns: Int, rows: Int) -> [WidgetPlacement]? {
        if let placed = packInOrder(items, columns: columns, rows: rows) { return placed }
        let biggestFirst = items.enumerated().sorted { a, b in
            a.element.1.area != b.element.1.area ? a.element.1.area > b.element.1.area : a.offset < b.offset
        }.map(\.element)
        guard let placed = packInOrder(biggestFirst, columns: columns, rows: rows) else { return nil }
        // Keep the caller's order in the result.
        return items.compactMap { item in placed.first { $0.kind == item.0 } }
    }

    private static func packInOrder(_ items: [(WidgetKind, WidgetSize)], columns: Int, rows: Int) -> [WidgetPlacement]? {
        var used = Array(repeating: Array(repeating: false, count: columns), count: rows)
        var placements: [WidgetPlacement] = []
        for (kind, size) in items {
            var spot: (Int, Int)?
            search: for row in 0..<rows {
                for column in 0..<columns where fits(size, at: column, row, used, columns, rows) {
                    spot = (column, row)
                    break search
                }
            }
            guard let (column, row) = spot else { return nil }
            for r in row..<(row + size.rows) {
                for c in column..<(column + size.columns) { used[r][c] = true }
            }
            placements.append(WidgetPlacement(kind: kind, size: size, column: column, row: row))
        }
        return placements
    }

    /// Cells no placement covers.
    static func freeCells(_ placements: [WidgetPlacement], columns: Int, rows: Int) -> [(column: Int, row: Int)] {
        var used = Array(repeating: Array(repeating: false, count: columns), count: rows)
        for p in placements {
            for r in p.row..<min(rows, p.row + p.size.rows) {
                for c in p.column..<min(columns, p.column + p.size.columns) { used[r][c] = true }
            }
        }
        var free: [(column: Int, row: Int)] = []
        for row in 0..<rows {
            for column in 0..<columns where !used[row][column] { free.append((column, row)) }
        }
        return free
    }

    private static func fits(_ size: WidgetSize, at column: Int, _ row: Int, _ used: [[Bool]], _ columns: Int, _ rows: Int) -> Bool {
        guard column + size.columns <= columns, row + size.rows <= rows else { return false }
        for r in row..<(row + size.rows) {
            for c in column..<(column + size.columns) where used[r][c] { return false }
        }
        return true
    }

    private static func nextSmaller(_ size: WidgetSize, in sizes: [WidgetSize]) -> WidgetSize {
        sizes.first { $0 < size } ?? size
    }

    /// Grows widgets (most important first) while the page still packs.
    private static func grow(_ page: [WidgetPlacement], columns: Int, rows: Int,
                             fitting: (WidgetKind) -> [WidgetSize]) -> [WidgetPlacement] {
        var items = page.map { ($0.kind, $0.size) }
        var current = page
        var changed = true
        while changed {
            changed = false
            let order = items.indices.sorted { items[$0].0.shrinkPriority > items[$1].0.shrinkPriority }
            for index in order {
                guard let bigger = fitting(items[index].0).last(where: { $0 > items[index].1 }) else { continue }
                var trial = items
                trial[index].1 = bigger
                if let packed = pack(trial, columns: columns, rows: rows) {
                    items = trial
                    current = packed
                    changed = true
                    break
                }
            }
        }
        return current
    }
}

// MARK: - Shared styling

enum WidgetStyle {
    static let spacing: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    /// Smallest cell the grid will lay out; a 484 pt wide area gives 4 columns.
    static let minCellWidth: CGFloat = 108
    static let minCellHeight: CGFloat = 50
    static let railWidth: CGFloat = 18
    // Computed, so they follow a change of look.
    static var cardFill: Color { SparkVTheme.surface }
    /// Apple cards are flat (no hairline), like Control Center modules.
    static var cardStroke: Color { SparkVTheme.choose(apple: Color.white.opacity(0.04), sparkv: SparkVTheme.stroke) }
    static var secondaryText: Color { SparkVTheme.textSecondary }
    static var tertiaryText: Color { SparkVTheme.textTertiary }
    /// Tiny uppercase card label ("CPU", "VOLUME"): SF Pro semibold in
    /// Apple, SF Mono in SparkV Red. Same size in both, so it fits the
    /// narrow gauge columns.
    static func label(_ size: CGFloat) -> Font {
        SparkVTheme.isApple ? .system(size: size, weight: .semibold) : SparkVTheme.eyebrow(size)
    }
    static var labelTracking: CGFloat { SparkVTheme.isApple ? 0.3 : 0.6 }
}

/// Rounded dark card every widget sits on.
struct WidgetCard<Content: View>: View {
    var padding: CGFloat = 7
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                    .fill(WidgetStyle.cardFill)
            )
            .clipShape(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                    .strokeBorder(WidgetStyle.cardStroke, lineWidth: 1)
            )
    }
}

/// Ring gauge: track, value arc, and a center label.
struct WidgetRing<Center: View>: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 3.5
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Data tween between samples (seconds apart), not a UI response.
                .animation(SparkVMotion.easeOut(0.45), value: fraction)
            center
        }
        .padding(lineWidth / 2)
    }
}

/// Tiny area/line chart of recent samples (0...1 after scaling by `peak`).
struct WidgetSparkline: View {
    let values: [Double]
    let peak: Double
    let tint: Color
    var filled = true

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, peak: peak, size: geo.size)
            ZStack {
                if filled, points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                }
                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    static func points(_ values: [Double], peak: Double, size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 0 else { return [] }
        let top = max(peak, 0.000_001)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let y = size.height - CGFloat(min(1, max(0, value / top))) * (size.height - 1.5) - 0.75
            return CGPoint(x: CGFloat(index) * step, y: y)
        }
    }
}

/// Calls `start` when the view appears and `stop` when it goes away, so
/// samplers only run while a widget is on screen.
struct WidgetVisibility: ViewModifier {
    let start: @MainActor () -> Void
    let stop: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { start() }
            .onDisappear { stop() }
    }
}

extension View {
    func whileVisible(start: @escaping @MainActor () -> Void, stop: @escaping @MainActor () -> Void) -> some View {
        modifier(WidgetVisibility(start: start, stop: stop))
    }
}

/// Reference-counted 2 s sampling loop shared by every view of one sampler.
@MainActor
final class WidgetSamplingLoop {
    private var users = 0
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let tick: @MainActor () -> Void

    init(interval: Duration = .seconds(2), tick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    /// Delay before the second reading.
    static let firstInterval: Duration = .milliseconds(600)

    var isRunning: Bool { task != nil }
    var userCount: Int { users }

    func retain() {
        users += 1
        guard task == nil else { return }
        tick()
        let interval = interval
        // CPU load and throughput need two readings, so the second comes
        // sooner: a glance at the drawer shows numbers within ~0.6 s
        // instead of "--" for the first 2 s.
        let first = min(interval, Self.firstInterval)
        task = Task { @MainActor [weak self] in
            var wait = first
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                wait = interval
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        task?.cancel()
        task = nil
    }
}
