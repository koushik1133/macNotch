import SwiftUI

// MARK: - Model

struct Habit: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    /// Index into `HabitPalette.colors`.
    var colorIndex: Int
}

enum HabitPalette {
    /// Apple: each habit has its own system color (the eight slots map to
    /// saved `colorIndex` values). SparkV Red keeps habits on one accent: a
    /// done day is signal red.
    static var colors: [Color] {
        SparkVTheme.isApple
            ? [Color.green, Color.blue, Color.orange, Color.pink, Color.purple, Color.teal, Color.yellow, Color.indigo]
            : Array(repeating: SparkVTheme.red, count: 8)
    }

    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }

    /// Picks a symbol from the habit's name.
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        let table: [([String], String)] = [
            (["water", "drink", "hydrat"], "drop.fill"),
            (["read", "book"], "book.fill"),
            (["run", "jog"], "figure.run"),
            (["walk", "steps"], "figure.walk"),
            (["exercise", "workout", "gym", "lift", "train", "sport"], "dumbbell.fill"),
            (["yoga", "stretch"], "figure.mind.and.body"),
            (["meditat", "breath", "mindful"], "leaf.fill"),
            (["sleep", "bed"], "bed.double.fill"),
            (["journal", "write", "diary"], "pencil.line"),
            (["code", "program", "leetcode"], "chevron.left.forwardslash.chevron.right"),
            (["vitamin", "pill", "medic"], "pills.fill"),
            (["fruit", "veg", "eat", "diet", "cook"], "carrot.fill"),
            (["music", "guitar", "piano", "practice"], "music.note"),
            (["learn", "study", "course", "language"], "graduationcap.fill"),
            (["phone", "screen", "social"], "iphone.slash"),
            (["clean", "tidy"], "sparkles"),
            (["sun", "outside", "outdoor"], "sun.max.fill"),
        ]
        return table.first { keys, _ in keys.contains { n.contains($0) } }?.1 ?? "checkmark.circle.fill"
    }
}

/// Day keys and streaks in the user's local calendar (pure).
enum HabitCalendar {
    /// "2026-10-21" for the local day containing `date`.
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The last `count` local days, oldest first, ending with the day of `date`.
    static func lastDays(_ count: Int, endingAt date: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: date)
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    /// Consecutive done days ending today, or ending yesterday while today is
    /// still open (a streak isn't broken until the day is over).
    static func streak(done: Set<String>, today date: Date, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: date)
        if !done.contains(key(for: day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while done.contains(key(for: day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// One-letter weekday ("M") in the user's locale.
    static func weekdayLetter(_ date: Date, calendar: Calendar = .current) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }
}

/// User-defined habits with a done flag per local day. Persisted as JSON in
/// UserDefaults; "today" is always the current local day, so the grid rolls
/// over at midnight on its own.
@MainActor
final class HabitStore: ObservableObject {
    static let shared = HabitStore()
    static let key = "SparkV.widgets.habits"
    static let maxHabits = 6
    /// Days kept for streaks; older ones are pruned on save.
    static let historyDays = 400
    static let suggestions = ["Exercise", "Water", "Read", "Meditate", "Stretch", "Sleep 8h", "Journal", "Walk"]

    private struct Saved: Codable {
        var habits: [Habit]
        var done: [String: [String]]
    }

    @Published private(set) var habits: [Habit]
    /// Habit id -> day keys it was done.
    @Published private(set) var done: [UUID: Set<String>]

    private let defaults: UserDefaults
    /// Follows time zone changes (travel), so "today" is always the local day.
    var calendar: Calendar = .autoupdatingCurrent
    /// Overridable clock for tests and renders.
    var now: () -> Date = { Date() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            habits = saved.habits
            var map: [UUID: Set<String>] = [:]
            for (id, days) in saved.done {
                if let uuid = UUID(uuidString: id) { map[uuid] = Set(days) }
            }
            done = map
        } else {
            habits = ["Exercise", "Water", "Read"].enumerated().map { index, name in
                Habit(id: UUID(), name: name, symbol: HabitPalette.symbol(for: name), colorIndex: index)
            }
            done = [:]
        }
    }

    var isFull: Bool { habits.count >= Self.maxHabits }

    func isDone(_ habit: Habit, on day: Date) -> Bool {
        done[habit.id]?.contains(HabitCalendar.key(for: day, calendar: calendar)) ?? false
    }

    func isDoneToday(_ habit: Habit) -> Bool { isDone(habit, on: now()) }

    /// Toggles a day. Only the last 7 days can change; future days can't.
    func toggle(_ habit: Habit, on day: Date) {
        let today = calendar.startOfDay(for: now())
        let target = calendar.startOfDay(for: day)
        guard target <= today,
              let oldest = calendar.date(byAdding: .day, value: -6, to: today), target >= oldest else { return }
        let key = HabitCalendar.key(for: target, calendar: calendar)
        var days = done[habit.id] ?? []
        if days.contains(key) { days.remove(key) } else { days.insert(key) }
        done[habit.id] = days
        save()
    }

    func toggleToday(_ habit: Habit) { toggle(habit, on: now()) }

    func streak(_ habit: Habit) -> Int {
        HabitCalendar.streak(done: done[habit.id] ?? [], today: now(), calendar: calendar)
    }

    var doneTodayCount: Int { habits.filter(isDoneToday).count }

    func days(_ count: Int = 7) -> [Date] { HabitCalendar.lastDays(count, endingAt: now(), calendar: calendar) }

    @discardableResult
    func add(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isFull,
              !habits.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        let used = Set(habits.map(\.colorIndex))
        let color = (0..<HabitPalette.colors.count).first { !used.contains($0) } ?? habits.count
        habits.append(Habit(id: UUID(), name: String(name.prefix(24)), symbol: HabitPalette.symbol(for: name), colorIndex: color))
        save()
        return true
    }

    func remove(_ habit: Habit) {
        habits.removeAll { $0.id == habit.id }
        done[habit.id] = nil
        save()
    }

    func move(_ habit: Habit, by offset: Int) {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }), habits.indices.contains(index + offset) else { return }
        habits.swapAt(index, index + offset)
        save()
    }

    private func save() {
        let cutoff = calendar.date(byAdding: .day, value: -Self.historyDays, to: now()).map { HabitCalendar.key(for: $0, calendar: calendar) } ?? ""
        let ids = Set(habits.map(\.id))
        var out: [String: [String]] = [:]
        for (id, days) in done where ids.contains(id) {
            // Keys sort lexically by date.
            out[id.uuidString] = days.filter { $0 >= cutoff }.sorted()
        }
        if let data = try? JSONEncoder().encode(Saved(habits: habits, done: out)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Views

/// Daily habits: small = today's check buttons; wide/large = a 7-day grid with streaks.
struct HabitsWidget: View {
    @ObservedObject var store: HabitStore = .shared
    var size: WidgetSize = .wide
    var onEdit: (() -> Void)? = nil
    /// Fixed day for renders; live views re-evaluate every minute so "today" rolls over at midnight.
    var fixedDate: Date? = nil

    var body: some View {
        WidgetCard(padding: size == .large ? 7 : 6) {
            if store.habits.isEmpty {
                Button { onEdit?() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "checklist.checked").font(.system(size: 15, weight: .semibold)).foregroundStyle(WidgetKind.habits.tint)
                        Text("Add habits").font(.system(size: 9.5, weight: .medium)).foregroundStyle(WidgetStyle.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SparkVPressStyle())
            } else if fixedDate != nil {
                content
            } else {
                // The rows don't read the timeline's date, so SwiftUI would
                // skip re-rendering them; keying them by the local day makes
                // "today" (and the streaks) roll over at midnight while open.
                TimelineView(.everyMinute) { context in
                    content.id(HabitCalendar.key(for: context.date, calendar: store.calendar))
                }
            }
        }
        // No right-click menu here: an inner one would replace the Widgets
        // tab's (move, hide, edit), which already has the editor item.
    }

    @ViewBuilder
    private var content: some View {
        switch size {
        case .small: HabitsTodayView(store: store)
        case .wide: HabitsGridView(store: store, maxRows: 3)
        case .large: HabitsGridView(store: store, maxRows: HabitStore.maxHabits)
        }
    }
}

/// Today's habits as round check buttons, plus "2/3 today".
private struct HabitsTodayView: View {
    @ObservedObject var store: HabitStore

    /// Checking a habit off is a small daily reward, so it keeps a little
    /// bounce, capped at 0.3 (was response 0.25 / damping 0.6, about 0.4).
    static var checkSpring: Animation {
        SparkVMotion.respecting(.spring(duration: 0.28, bounce: 0.3))
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text("TODAY")
                    .font(SparkVTheme.eyebrow(8))
                    .tracking(LabsBStyle.eyebrowTracking(0.8))
                    .foregroundStyle(WidgetStyle.tertiaryText)
                Spacer(minLength: 0)
                Text("\(store.doneTodayCount)/\(store.habits.count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(store.doneTodayCount == store.habits.count ? WidgetKind.habits.tint : WidgetStyle.secondaryText)
            }
            GeometryReader { geo in
                let shown = Array(store.habits.prefix(4))
                let spacing: CGFloat = 4
                let side = max(14, min(24, geo.size.height, (geo.size.width - spacing * CGFloat(max(0, shown.count - 1))) / CGFloat(max(1, shown.count))))
                HStack(spacing: spacing) {
                    ForEach(shown) { habit in
                        let on = store.isDoneToday(habit)
                        let tint = HabitPalette.color(habit.colorIndex)
                        Button { withAnimation(Self.checkSpring) { store.toggleToday(habit) } } label: {
                            ZStack {
                                Circle().fill(on ? tint : SparkVTheme.surface)
                                Circle().strokeBorder(on ? Color.clear : Color.white.opacity(0.16), lineWidth: 1)
                                Image(systemName: on ? "checkmark" : habit.symbol)
                                    .font(.system(size: side * (on ? 0.42 : 0.4), weight: .bold))
                                    .foregroundStyle(on ? Color.white : SparkVTheme.textSecondary)
                            }
                            .frame(width: side, height: side)
                            .contentShape(Circle())
                        }
                        .buttonStyle(SparkVPressStyle())
                        .help("\(habit.name): \(on ? "done today" : "not yet today")\(store.streak(habit) > 1 ? ", \(store.streak(habit))-day streak" : "")")
                        .accessibilityLabel("\(habit.name): \(on ? "done today" : "not yet today")\(store.streak(habit) > 1 ? ", \(store.streak(habit))-day streak" : "")")
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

/// How many habit rows of what height fit in a cell (pure, tested).
enum HabitGridFit {
    static let headerHeight: CGFloat = 9
    static let gap: CGFloat = 1.5

    struct Fit: Equatable {
        let rows: Int
        let rowHeight: CGFloat
        let showsHeader: Bool
    }


    /// Pure, so it is tested: how many rows of what height fit in `height`.
    static func fit(habits: Int, maxRows: Int, height: CGFloat) -> Fit {
        var rows = max(1, min(habits, maxRows))
        while rows > 1 {
            let withHeader = (height - headerHeight - gap - CGFloat(rows - 1) * gap) / CGFloat(rows)
            if withHeader >= 11 { return Fit(rows: rows, rowHeight: min(13, withHeader), showsHeader: true) }
            let bare = (height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            if bare >= 11 { return Fit(rows: rows, rowHeight: min(13, bare), showsHeader: false) }
            rows -= 1
        }
        let withHeader = height - headerHeight - gap
        return withHeader >= 11
            ? Fit(rows: 1, rowHeight: min(13, withHeader), showsHeader: true)
            : Fit(rows: 1, rowHeight: max(9, min(13, height)), showsHeader: false)
    }

}

/// Rows of habits by the last 7 days, oldest left, today right. Fits itself
/// to the cell: the weekday header and row height give way before rows do.
private struct HabitsGridView: View {
    @ObservedObject var store: HabitStore
    let maxRows: Int

    static let headerHeight = HabitGridFit.headerHeight
    static let gap = HabitGridFit.gap

    var body: some View {
        GeometryReader { geo in
            let days = store.days(7)
            let fit = HabitGridFit.fit(habits: store.habits.count, maxRows: maxRows, height: geo.size.height)
            let box = fit.rowHeight - 2
            VStack(spacing: Self.gap) {
                if fit.showsHeader {
                    HStack(spacing: 3) {
                        Text("HABITS")
                            .font(SparkVTheme.eyebrow(7.5))
                            .tracking(LabsBStyle.eyebrowTracking(0.8))
                            .foregroundStyle(WidgetStyle.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(days, id: \.self) { day in
                            let isToday = store.calendar.isDate(day, inSameDayAs: store.now())
                            Text(HabitCalendar.weekdayLetter(day, calendar: store.calendar))
                                .font(.system(size: 7.5, weight: isToday ? .heavy : .medium))
                                .foregroundStyle(isToday ? SparkVTheme.text : WidgetStyle.tertiaryText)
                                .frame(width: box)
                        }
                        Image(systemName: "flame.fill").font(.system(size: 7)).foregroundStyle(SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red.opacity(0.8)))
                            .frame(width: 16)
                    }
                    .frame(height: Self.headerHeight)
                }
                if store.habits.count > fit.rows {
                    // More habits than fit: the rows scroll, with a fade
                    // at the bottom edge hinting at the rest.
                    ScrollView(.vertical, showsIndicators: false) {
                        rows(store.habits[...], days: days, fit: fit, box: box)
                    }
                    .mask(
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                                .frame(height: fit.rowHeight * 0.8)
                        }
                    )
                    .help("\(store.habits.count) habits: scroll for \(store.habits.dropFirst(fit.rows).map(\.name).joined(separator: ", "))")
                } else {
                    rows(store.habits[...], days: days, fit: fit, box: box)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func rows(_ habits: ArraySlice<Habit>, days: [Date], fit: HabitGridFit.Fit, box: CGFloat) -> some View {
        VStack(spacing: Self.gap) {
            ForEach(habits) { habit in
                HabitRow(store: store, habit: habit, days: days, box: box)
                    .frame(height: fit.rowHeight)
            }
        }
    }
}

private struct HabitRow: View {
    @ObservedObject var store: HabitStore
    let habit: Habit
    let days: [Date]
    let box: CGFloat

    var body: some View {
        let tint = HabitPalette.color(habit.colorIndex)
        let streak = store.streak(habit)
        HStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: habit.symbol).font(.system(size: 7.5, weight: .bold)).foregroundStyle(SparkVTheme.textSecondary).frame(width: 10)
                Text(habit.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(SparkVTheme.text.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(days, id: \.self) { day in
                let on = store.isDone(habit, on: day)
                let isToday = store.calendar.isDate(day, inSameDayAs: store.now())
                Button { withAnimation(SparkVMotion.easeOut(SparkVMotion.Duration.hover)) { store.toggle(habit, on: day) } } label: {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(on ? tint : Color.white.opacity(isToday ? 0.12 : 0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .stroke(isToday && !on ? Color.white.opacity(0.35) : .clear, lineWidth: 0.8)
                        )
                        .overlay(on ? Image(systemName: "checkmark").font(.system(size: box * 0.55, weight: .heavy)).foregroundStyle(Color.white) : nil)
                        .frame(width: box, height: box)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SparkVPressStyle())
                .help("\(habit.name), \(day.formatted(.dateTime.weekday(.wide).month().day())): \(on ? "done" : "not done")")
                .accessibilityLabel("\(habit.name), \(day.formatted(.dateTime.weekday(.wide).month().day())): \(on ? "done" : "not done")")
            }
            Text(streak > 0 ? "\(streak)" : "-")
                .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                .foregroundStyle(streak > 0 ? SparkVTheme.text : WidgetStyle.tertiaryText)
                .frame(width: 16)
                .help(streak > 0 ? "\(streak)-day streak" : "No streak yet")
        }
    }
}

// MARK: - Editor (inside the Widgets tab's edit page)

@MainActor
final class HabitEditorUI: ObservableObject {
    @Published var draft = ""
}

struct HabitEditor: View {
    @ObservedObject var store: HabitStore = .shared
    @StateObject private var ui = HabitEditorUI()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.habits) { habit in
                        WidgetChip(title: habit.name, symbol: "xmark", tint: HabitPalette.color(habit.colorIndex),
                                   help: "Remove \(habit.name) and its history") {
                            store.remove(habit)
                        }
                    }
                    if store.habits.isEmpty {
                        Text("No habits yet").font(.system(size: 9.5)).foregroundStyle(WidgetStyle.tertiaryText)
                    }
                }
            }
            .frame(height: 20)
            HStack(spacing: 6) {
                WidgetSearchField(placeholder: "New habit, then Return", text: $ui.draft, symbol: "plus") {
                    if store.add(named: ui.draft) { ui.draft = "" }
                }
                .frame(width: 150)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(HabitStore.suggestions.filter { s in !store.habits.contains { $0.name == s } }, id: \.self) { name in
                            WidgetChip(title: name, symbol: "plus", tint: WidgetKind.habits.tint, isDisabled: store.isFull,
                                       help: store.isFull ? "Up to \(HabitStore.maxHabits) habits" : "Add \(name)") {
                                store.add(named: name)
                            }
                        }
                    }
                }
            }
            .frame(height: 20)
        }
    }
}
