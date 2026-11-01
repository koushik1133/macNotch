import SwiftUI

// MARK: - Model

/// A city the user picked: a time zone plus the name to show.
struct WorldClockCity: Codable, Hashable, Identifiable, Sendable {
    let identifier: String
    let city: String
    var id: String { identifier + "|" + city }

    var timeZone: TimeZone { TimeZone(identifier: identifier) ?? .current }
}

/// The 2-3 cities shown by the world clock widget. Persisted as JSON.
@MainActor
final class WorldClockStore: ObservableObject {
    static let shared = WorldClockStore()
    static let key = "SparkV.widgets.worldClocks"
    static let maxCities = 3

    @Published private(set) var cities: [WorldClockCity]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([WorldClockCity].self, from: data) {
            cities = Array(saved.filter { TimeZone(identifier: $0.identifier) != nil }.prefix(Self.maxCities))
        } else {
            cities = Self.defaultCities(excluding: TimeZone.current)
        }
    }

    var isFull: Bool { cities.count >= Self.maxCities }

    func contains(_ city: WorldClockCity) -> Bool {
        cities.contains { $0.identifier == city.identifier && $0.city == city.city }
    }

    func add(_ city: WorldClockCity) {
        guard !isFull, !contains(city) else { return }
        cities.append(city)
        save()
    }

    func remove(_ city: WorldClockCity) {
        cities.removeAll { $0 == city }
        save()
    }

    func move(_ city: WorldClockCity, by offset: Int) {
        guard let index = cities.firstIndex(of: city), cities.indices.contains(index + offset) else { return }
        cities.swapAt(index, index + offset)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cities) { defaults.set(data, forKey: Self.key) }
    }

    /// India, Chicago and London by default; the user can search, add,
    /// remove and reorder cities from the widget.
    static func defaultCities(excluding local: TimeZone) -> [WorldClockCity] {
        Array([
            WorldClockCity(identifier: "Asia/Kolkata", city: "India"),
            WorldClockCity(identifier: "America/Chicago", city: "Chicago"),
            WorldClockCity(identifier: "Europe/London", city: "London"),
        ].prefix(maxCities))
    }
}

// MARK: - Time math (pure)

enum WorldClockMath {
    enum DayRelation: Equatable { case yesterday, today, tomorrow }

    /// Whether the city's calendar day is before, equal to or after the local one.
    static func dayRelation(of zone: TimeZone, at date: Date, local: TimeZone = .current) -> DayRelation {
        let remote = dayNumber(date, in: zone)
        let here = dayNumber(date, in: local)
        if remote < here { return .yesterday }
        if remote > here { return .tomorrow }
        return .today
    }

    /// "+5:30", "-8h", "Same time".
    static func offsetLabel(of zone: TimeZone, at date: Date, local: TimeZone = .current) -> String {
        let delta = zone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)
        if delta == 0 { return "Same time" }
        let sign = delta > 0 ? "+" : "-"
        let minutes = abs(delta) / 60
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(sign)\(hours)h" : "\(sign)\(hours):" + String(format: "%02d", rest)
    }

    /// "Today, +5:30" / "Tomorrow, +9h" / "Yesterday, -8h"; `short` abbreviates the day.
    static func detail(of zone: TimeZone, at date: Date, local: TimeZone = .current, short: Bool = false) -> String {
        let day: String = switch dayRelation(of: zone, at: date, local: local) {
        case .yesterday: short ? "Yest" : "Yesterday"
        case .today: "Today"
        case .tomorrow: short ? "Tmrw" : "Tomorrow"
        }
        let offset = offsetLabel(of: zone, at: date, local: local)
        return offset == "Same time" ? "\(day), same" : "\(day), \(offset)"
    }

    /// Name for the narrow rows: multi-word names longer than 8 letters
    /// become initials ("San Francisco" -> "SF"); others stay whole.
    static func shortName(_ city: String) -> String {
        let words = city.split(separator: " ")
        guard city.count > 8, words.count > 1 else { return city }
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Local hour (0-23) in the city.
    static func hour(in zone: TimeZone, at date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.hour, from: date)
    }

    /// Day from 6 am to 6 pm, the rule the macOS World Clock widget uses for its light dial.
    static func isDaytime(in zone: TimeZone, at date: Date) -> Bool {
        (6..<18).contains(hour(in: zone, at: date))
    }

    /// "9:41" (12-hour locales drop the AM/PM here; `period` returns it).
    static func time(in zone: TimeZone, at date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(uses24Hour(locale) ? "HHmm" : "hmm")
        // Strip the day period so it can be drawn smaller.
        return formatter.string(from: date)
            .replacingOccurrences(of: formatter.amSymbol, with: "")
            .replacingOccurrences(of: formatter.pmSymbol, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func period(in zone: TimeZone, at date: Date, locale: Locale = .current) -> String? {
        guard !uses24Hour(locale) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        return hour(in: zone, at: date) < 12 ? formatter.amSymbol : formatter.pmSymbol
    }

    static func uses24Hour(_ locale: Locale) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return !format.contains("a")
    }

    private static func dayNumber(_ date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}

// MARK: - Time zone search

enum WorldClockSearch {
    /// Cities that aren't the last path component of a time zone identifier.
    static let aliases: [(city: String, identifier: String)] = [
        ("San Francisco", "America/Los_Angeles"), ("Seattle", "America/Los_Angeles"),
        ("Austin", "America/Chicago"), ("Dallas", "America/Chicago"), ("Boston", "America/New_York"),
        ("Washington DC", "America/New_York"), ("Miami", "America/New_York"), ("Atlanta", "America/New_York"),
        ("Bengaluru", "Asia/Kolkata"), ("Mumbai", "Asia/Kolkata"), ("New Delhi", "Asia/Kolkata"),
        ("Hyderabad", "Asia/Kolkata"), ("Chennai", "Asia/Kolkata"), ("Pune", "Asia/Kolkata"),
        ("Beijing", "Asia/Shanghai"), ("Shenzhen", "Asia/Shanghai"), ("Munich", "Europe/Berlin"),
        ("Barcelona", "Europe/Madrid"), ("Milan", "Europe/Rome"), ("Zurich", "Europe/Zurich"),
        ("Tel Aviv", "Asia/Jerusalem"), ("Abu Dhabi", "Asia/Dubai"), ("Melbourne", "Australia/Melbourne"),
        ("Auckland", "Pacific/Auckland"), ("Toronto", "America/Toronto"), ("Vancouver", "America/Vancouver"),
        ("São Paulo", "America/Sao_Paulo"), ("Mexico City", "America/Mexico_City"), ("Lagos", "Africa/Lagos"),
        ("UTC", "UTC"),
    ]

    struct Entry: Hashable, Sendable {
        let city: WorldClockCity
        let region: String
        let keywords: String
    }

    /// Every known zone (its city plus the aliases), sorted by city name.
    static let entries: [Entry] = {
        var list: [Entry] = []
        var seen = Set<String>()
        func add(_ city: String, _ identifier: String) {
            guard let zone = TimeZone(identifier: identifier), seen.insert(city + identifier).inserted else { return }
            let region = identifier.split(separator: "/").first.map(String.init) ?? identifier
            let generic = zone.localizedName(for: .generic, locale: Locale(identifier: "en_US")) ?? ""
            let abbreviation = zone.abbreviation() ?? ""
            let keywords = [city, identifier.replacingOccurrences(of: "_", with: " "), generic, abbreviation]
                .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            list.append(Entry(city: WorldClockCity(identifier: identifier, city: city), region: region, keywords: keywords))
        }
        for (city, identifier) in aliases { add(city, identifier) }
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard identifier.contains("/"), !identifier.hasPrefix("Etc/") else { continue }
            let city = identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? identifier
            add(city, identifier)
        }
        return list.sorted { $0.city.city.localizedCaseInsensitiveCompare($1.city.city) == .orderedAscending }
    }()

    /// Matches by city, region, zone name ("Pacific Time") or abbreviation; city
    /// prefixes rank first.
    static func search(_ query: String, limit: Int = 30) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else {
            let popular = ["London", "New York", "San Francisco", "Tokyo", "Bengaluru", "Berlin", "Sydney", "Singapore", "Dubai", "Paris"]
            return popular.compactMap { name in entries.first { $0.city.city == name } }
        }
        let matches = entries.filter { $0.keywords.contains(q) }
        let ranked = matches.sorted { a, b in
            let ap = a.city.city.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(q)
            let bp = b.city.city.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(q)
            if ap != bp { return ap }
            return a.city.city.localizedCaseInsensitiveCompare(b.city.city) == .orderedAscending
        }
        return Array(ranked.prefix(limit))
    }
}

// MARK: - Views

/// World clocks: city, time, day offset and a day/night glyph per city.
struct WorldClockWidget: View {
    @ObservedObject var store: WorldClockStore = .shared
    var size: WidgetSize = .wide
    /// Opens the city picker (the Widgets tab's edit page).
    var onEdit: (() -> Void)? = nil
    /// Fixed time for offscreen renders and tests.
    var fixedDate: Date? = nil

    var body: some View {
        WidgetCard(padding: size == .small ? 7 : 8) {
            if store.cities.isEmpty {
                emptyState
            } else if let fixedDate {
                content(at: fixedDate)
            } else {
                TimelineView(.everyMinute) { context in content(at: context.date) }
            }
        }
        .help(store.cities.map { "\($0.city): \(WorldClockMath.detail(of: $0.timeZone, at: Date()))" }.joined(separator: "\n"))
        // No right-click menu here: an inner one would replace the Widgets
        // tab's (move, hide, edit), which already has the editor item.
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.cities) { city in
                    WorldClockRow(city: city, date: date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(store.cities.enumerated()), id: \.element.id) { index, city in
                    if index > 0 {
                        Rectangle().fill(SparkVTheme.stroke).frame(width: 1).padding(.vertical, 4)
                    }
                    WorldClockColumn(city: city, date: date, large: size == .large)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var emptyState: some View {
        Button { onEdit?() } label: {
            VStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 15, weight: .semibold)).foregroundStyle(WidgetKind.clocks.tint)
                Text("Add cities").font(.system(size: 9.5, weight: .medium)).foregroundStyle(WidgetStyle.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
    }
}

private struct DayNightGlyph: View {
    let isDay: Bool
    var size: CGFloat = 8.5

    var body: some View {
        Image(systemName: isDay ? "sun.max.fill" : "moon.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isDay ? SparkVTheme.text.opacity(0.85) : SparkVTheme.textTertiary)
            .frame(width: size + 3)
    }
}

/// One line in the small widget: glyph, city, time.
private struct WorldClockRow: View {
    let city: WorldClockCity
    let date: Date

    var body: some View {
        let zone = city.timeZone
        HStack(spacing: 4) {
            DayNightGlyph(isDay: WorldClockMath.isDaytime(in: zone, at: date), size: 8)
            Text(WorldClockMath.shortName(city.city))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(WorldClockMath.time(in: zone, at: date))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
                if let period = WorldClockMath.period(in: zone, at: date) {
                    Text(period).font(.system(size: 6.5, weight: .semibold)).foregroundStyle(WidgetStyle.secondaryText)
                }
            }
            .layoutPriority(1)
        }
        .frame(maxHeight: .infinity)
    }
}

/// One column in the wide widget.
private struct WorldClockColumn: View {
    let city: WorldClockCity
    let date: Date
    var large = false

    var body: some View {
        let zone = city.timeZone
        VStack(spacing: large ? 4 : 1) {
            HStack(spacing: 3) {
                DayNightGlyph(isDay: WorldClockMath.isDaytime(in: zone, at: date), size: 8)
                Text(city.city)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                Text(WorldClockMath.time(in: zone, at: date))
                    .font(.system(size: large ? 22 : 17, weight: .semibold).monospacedDigit())
                    .tracking(-0.4)
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let period = WorldClockMath.period(in: zone, at: date) {
                    Text(period).font(.system(size: 7.5, weight: .bold)).foregroundStyle(WidgetStyle.secondaryText)
                }
            }
            Text(WorldClockMath.detail(of: zone, at: date, short: true))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(WidgetStyle.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 3)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - City editor (inside the Widgets tab's edit page)

@MainActor
final class WorldClockEditorUI: ObservableObject {
    @Published var query = ""
}

struct WorldClockEditor: View {
    @ObservedObject var store: WorldClockStore = .shared
    @StateObject private var ui = WorldClockEditorUI()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ForEach(store.cities) { city in
                    WidgetChip(title: city.city, detail: WorldClockMath.offsetLabel(of: city.timeZone, at: Date()),
                               symbol: "xmark", tint: WidgetKind.clocks.tint, help: "Remove \(city.city)") {
                        store.remove(city)
                    }
                }
                if store.cities.isEmpty {
                    Text("No cities yet").font(.system(size: 9.5)).foregroundStyle(WidgetStyle.tertiaryText)
                }
                Spacer(minLength: 4)
                Text("\(store.cities.count)/\(WorldClockStore.maxCities)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(WidgetStyle.tertiaryText)
            }
            .frame(height: 20)

            HStack(spacing: 6) {
                WidgetSearchField(placeholder: "Search a city or time zone", text: $ui.query)
                    .frame(width: 150)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(WorldClockSearch.search(ui.query), id: \.self) { entry in
                            let added = store.contains(entry.city)
                            WidgetChip(title: entry.city.city,
                                       detail: WorldClockMath.offsetLabel(of: entry.city.timeZone, at: Date()),
                                       symbol: added ? "checkmark" : "plus", tint: WidgetKind.clocks.tint,
                                       isDisabled: added || store.isFull,
                                       help: store.isFull && !added ? "Remove a city first (up to 3)" : "\(entry.city.city), \(entry.region)") {
                                store.add(entry.city)
                                ui.query = ""
                            }
                        }
                    }
                }
            }
            .frame(height: 20)
        }
    }
}

// MARK: - Shared editor controls

struct WidgetChip: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var tint: Color = .white
    var isOn = false
    var isDisabled = false
    var help: String? = nil
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : (isDisabled ? SparkVTheme.textTertiary : SparkVTheme.text.opacity(0.9)))
                if let detail {
                    Text(detail).font(.system(size: 8.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(isOn ? Color.white.opacity(0.7) : WidgetStyle.tertiaryText)
                }
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 7, weight: .bold))
                        .foregroundStyle(isOn ? Color.white : (isDisabled ? SparkVTheme.textTertiary : (hover.isOn ? tint : SparkVTheme.textSecondary)))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(isOn ? SparkVTheme.choose(apple: Color.white.opacity(0.18), sparkv: SparkVTheme.red) : (hover.isOn && !isDisabled ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : LabsBStyle.chipStroke, lineWidth: 1))
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle(scale: isDisabled ? 1 : SparkVMotion.pressedScale))
        .disabled(isDisabled)
        .onHover { hover.isOn = $0 }
        .help(help ?? title)
    }
}

struct WidgetSearchField: View {
    let placeholder: String
    @Binding var text: String
    var symbol = "magnifyingglass"
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(SparkVTheme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(SparkVTheme.text)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 9)).foregroundStyle(SparkVTheme.textTertiary)
                }
                .buttonStyle(SparkVPressStyle())
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
    }
}
