import SwiftUI

// MARK: - Model

/// The Planner's calendar: a month grid to move around in, and the chosen
/// day or week as a list. One fetch covers the whole six-week grid; it runs
/// when the page appears, the month changes, or the calendar database or
/// the calendar settings change (`MeetingsController.calendarRevision`).
@MainActor
final class AgendaModel: ObservableObject {
    static let shared = AgendaModel()

    enum Mode: String, CaseIterable, Identifiable {
        case day
        case week
        var id: String { rawValue }
        var title: String { self == .day ? "Day" : "Week" }
    }

    /// Local midnight of the chosen day.
    @Published private(set) var selectedDay: Date
    /// Any date in the month the grid shows.
    @Published private(set) var displayedMonth: Date
    @Published var mode: Mode = .day
    @Published private(set) var events: [CalendarMeeting] = []
    /// Events per local day (midnight), multi-day ones on every day they touch.
    @Published private(set) var buckets: [Date: [CalendarMeeting]] = [:]
    @Published private(set) var isLoading = false

    /// Renders and tests replace the calendar.
    var fetch: ((Date, Date) async -> [CalendarMeeting])?
    /// Fixed "now" for renders.
    var fixedNow: Date?
    /// Tests set the calendar revision; otherwise it is read from
    /// `MeetingsController.current`.
    var revision: Int?

    private var task: Task<Void, Never>?
    private var loadedKey: String?
    /// The last time the user moved around; after a while away the page
    /// opens on today again.
    private var lastMove = Date.distantPast
    static let returnToTodayAfter: TimeInterval = 10 * 60

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        selectedDay = today
        displayedMonth = today
    }

    var now: Date { fixedNow ?? Date() }

    func select(_ day: Date, calendar: Calendar) {
        lastMove = Date()
        let start = calendar.startOfDay(for: day)
        selectedDay = start
        if !calendar.isDate(start, equalTo: displayedMonth, toGranularity: .month) {
            displayedMonth = start
            reload(calendar: calendar)
        }
    }

    func moveMonth(by months: Int, calendar: Calendar) {
        lastMove = Date()
        displayedMonth = CalendarGrid.addingMonths(months, to: CalendarGrid.monthStart(of: displayedMonth, calendar: calendar), calendar: calendar)
        reload(calendar: calendar)
    }

    /// Day mode: a day; week mode: a week.
    func step(by offset: Int, calendar: Calendar) {
        let days = mode == .day ? offset : offset * 7
        select(calendar.date(byAdding: .day, value: days, to: selectedDay) ?? selectedDay, calendar: calendar)
    }

    func goToToday(calendar: Calendar) {
        select(now, calendar: calendar)
        if !calendar.isDate(displayedMonth, equalTo: now, toGranularity: .month) {
            displayedMonth = calendar.startOfDay(for: now)
            reload(calendar: calendar)
        }
    }

    /// The page appeared: back to today when the user hasn't moved around
    /// for a while (or the day changed), then fetch.
    func appeared(calendar: Calendar) {
        if Date().timeIntervalSince(lastMove) > Self.returnToTodayAfter,
           !calendar.isDate(selectedDay, inSameDayAs: now) || !calendar.isDate(displayedMonth, equalTo: now, toGranularity: .month) {
            selectedDay = calendar.startOfDay(for: now)
            displayedMonth = selectedDay
        }
        reload(calendar: calendar)
    }

    /// Fetches the grid's range (again when `force`). The model outlives
    /// the page, so the key includes the calendar revision: a database
    /// change, a calendar hidden or shown, or access changing while another
    /// page showed is fetched again when the agenda next appears.
    func reload(calendar: Calendar, force: Bool = false) {
        let range = CalendarGrid.gridInterval(for: displayedMonth, calendar: calendar)
        let revision = self.revision ?? MeetingsController.current?.calendarRevision ?? 0
        let key = "\(range.start.timeIntervalSinceReferenceDate)|\(calendar.firstWeekday)|\(revision)"
        guard force || key != loadedKey else { return }
        loadedKey = key
        task?.cancel()
        isLoading = true
        let fetch = self.fetch ?? { start, end in await MeetingsController.current?.agenda(from: start, to: end) ?? [] }
        task = Task { [weak self] in
            let found = await fetch(range.start, range.end)
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            self.events = found
            self.buckets = Self.bucket(found, in: range, calendar: calendar)
        }
    }

    func events(on day: Date, calendar: Calendar) -> [CalendarMeeting] {
        buckets[calendar.startOfDay(for: day)] ?? []
    }

    /// The days the list shows.
    func listedDays(calendar: Calendar) -> [Date] {
        mode == .day ? [selectedDay] : CalendarGrid.week(containing: selectedDay, calendar: calendar)
    }

    static func bucket(_ events: [CalendarMeeting], in range: DateInterval, calendar: Calendar) -> [Date: [CalendarMeeting]] {
        var result: [Date: [CalendarMeeting]] = [:]
        for event in events {
            var day = calendar.startOfDay(for: max(event.start, range.start))
            var guardCount = 0
            while day < range.end, day < max(event.end, event.start.addingTimeInterval(1)), guardCount < 62 {
                if CalendarGrid.overlaps(start: event.start, end: event.end, day: day, calendar: calendar) {
                    result[day, default: []].append(event)
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? range.end
                guardCount += 1
            }
        }
        for key in result.keys {
            result[key]?.sort { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start == b.start ? a.title < b.title : a.start < b.start
            }
        }
        return result
    }

    /// Whether `day` falls in the chosen day (day mode) or week (week mode).
    func isSelected(_ day: Date, calendar: Calendar) -> Bool {
        if mode == .day { return calendar.isDate(day, inSameDayAs: selectedDay) }
        let week = CalendarGrid.weekInterval(selectedDay, calendar: calendar)
        return day >= week.start && day < week.end
    }
}

// MARK: - Page

/// Agenda page: the month grid on the left, the day or week on the right.
struct AgendaSectionView: View {
    @EnvironmentObject private var meetings: MeetingsController
    @ObservedObject var model: AgendaModel = .shared
    @ObservedObject private var preferences = CalendarPreferences.shared

    var body: some View {
        let calendar = preferences.calendar
        Group {
            switch meetings.access {
            case .granted where meetings.isEnabled:
                HStack(spacing: 10) {
                    MiniMonthView(model: model, calendar: calendar)
                        .frame(width: 156)
                    Rectangle()
                        .fill(SparkVTheme.choose(apple: Color.white.opacity(0.12), sparkv: SparkVTheme.stroke))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                    AgendaListView(model: model, calendar: calendar)
                }
            default:
                PlannerAccessCard(
                    symbol: meetings.access == .denied ? "calendar.badge.exclamationmark" : "calendar.badge.plus",
                    tint: PlannerSection.agenda.tint,
                    title: !meetings.isEnabled ? "Meetings are turned off" : (meetings.access == .denied ? "Calendar access is off" : "Your calendar, day by day"),
                    detail: !meetings.isEnabled ? "Turn Meetings on in Live Activities to see your calendar."
                        : "SparkV reads your calendars on this Mac (iCloud, Google, Exchange accounts added in Calendar). Nothing is uploaded.",
                    button: !meetings.isEnabled ? nil : (meetings.access == .denied ? "Open Settings" : (meetings.isRequestingAccess ? "Connecting…" : "Connect Calendar"))
                ) {
                    if meetings.access == .denied { meetings.openPrivacySettings() } else { meetings.requestAccess() }
                }
            }
        }
        .onAppear {
            meetings.recheckAuthorization()
            model.appeared(calendar: calendar)
        }
        .onChange(of: meetings.calendarRevision) { _, _ in model.reload(calendar: calendar, force: true) }
        .onChange(of: meetings.access) { _, access in if access == .granted { model.reload(calendar: calendar, force: true) } }
        .onChange(of: preferences.weekStart) { _, _ in model.reload(calendar: preferences.calendar, force: true) }
    }
}

/// Six weeks of the month: today filled, the chosen day ringed, a dot under
/// days with events. Click a day to list it.
struct MiniMonthView: View {
    @ObservedObject var model: AgendaModel
    let calendar: Calendar

    var body: some View {
        let days = CalendarGrid.monthGrid(for: model.displayedMonth, calendar: calendar)
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(Self.monthTitle(model.displayedMonth, calendar: calendar))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 2)
                PlannerIconButton(symbol: "chevron.left", help: "Previous month", size: 15) { model.moveMonth(by: -1, calendar: calendar) }
                PlannerIconButton(symbol: "chevron.right", help: "Next month", size: 15) { model.moveMonth(by: 1, calendar: calendar) }
            }
            .frame(height: 16)
            .padding(.bottom, 1)

            HStack(spacing: 0) {
                ForEach(Array(CalendarGrid.weekdayInitials(calendar: calendar).enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 10)

            ForEach(0..<6, id: \.self) { week in
                let isSelectedWeek = model.mode == .week && model.isSelected(days[week * 7], calendar: calendar)
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let day = days[week * 7 + column]
                        MiniMonthCell(
                            day: day,
                            calendar: calendar,
                            inMonth: calendar.isDate(day, equalTo: model.displayedMonth, toGranularity: .month),
                            isToday: calendar.isDate(day, inSameDayAs: model.now),
                            // A week shows as one band behind the row instead.
                            isSelected: model.mode == .day && model.isSelected(day, calendar: calendar),
                            eventCount: model.events(on: day, calendar: calendar).count
                        ) { model.select(day, calendar: calendar) }
                    }
                }
                .frame(height: 14.5)
                .background(
                    Capsule()
                        .fill(SparkVTheme.choose(apple: Color.white.opacity(0.14), sparkv: SparkVTheme.redSoft))
                        .padding(.horizontal, 1)
                        .opacity(isSelectedWeek ? 1 : 0)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Month: \(Self.monthTitle(model.displayedMonth, calendar: calendar))")
    }

    static func monthTitle(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: date)
    }
}

private struct MiniMonthCell: View {
    let day: Date
    let calendar: Calendar
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let eventCount: Int
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            ZStack {
                if isToday {
                    Circle().fill(SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red))
                        .frame(width: 14, height: 14)
                } else if isSelected {
                    Capsule().fill(SparkVTheme.choose(apple: Color.white.opacity(0.16), sparkv: SparkVTheme.redSoft))
                        .frame(width: 18, height: 14)
                } else if hover.isOn {
                    Capsule().fill(SparkVTheme.hoverFill).frame(width: 18, height: 14)
                }
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 8.5, weight: isToday || isSelected ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : (inMonth ? SparkVTheme.text.opacity(0.9) : SparkVTheme.textTertiary.opacity(0.7)))
                    .offset(y: eventCount > 0 && !isToday ? -1.5 : 0)
                if eventCount > 0 && !isToday {
                    Circle()
                        .fill(inMonth ? SparkVTheme.choose(apple: Color.white.opacity(0.55), sparkv: SparkVTheme.red.opacity(0.85)) : SparkVTheme.textTertiary.opacity(0.5))
                        .frame(width: 2.5, height: 2.5)
                        .offset(y: 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(Self.spoken(day, calendar: calendar, count: eventCount, today: isToday))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    static func spoken(_ day: Date, calendar: Calendar, count: Int, today: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let events = count == 0 ? "no events" : (count == 1 ? "1 event" : "\(count) events")
        return "\(today ? "Today, " : "")\(formatter.string(from: day)), \(events)"
    }
}

/// The chosen day (or week) as a list: time, calendar color, title, Join.
struct AgendaListView: View {
    @EnvironmentObject private var meetings: MeetingsController
    @ObservedObject var model: AgendaModel
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            let days = model.listedDays(calendar: calendar)
            let isEmpty = days.allSatisfy { model.events(on: $0, calendar: calendar).isEmpty }
            let pinned = model.mode == .day && CalendarPreferences.shared.showsAllDay
                ? model.events(on: model.selectedDay, calendar: calendar).filter(\.isAllDay) : []
            if !pinned.isEmpty {
                HStack(spacing: 4) {
                    Text("ALL DAY")
                        .font(SparkVTheme.eyebrow(8.5))
                        .tracking(0.6)
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .frame(width: 46, alignment: .leading)
                    ForEach(pinned.prefix(3)) { event in
                        AllDayChip(event: event) { meetings.open(event) }
                    }
                    if pinned.count > 3 {
                        Text("+\(pinned.count - 3)")
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .frame(height: 16)
            }
            if isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: model.isLoading ? "hourglass" : "calendar")
                        .font(.system(size: 14, weight: .medium))
                    Text(model.isLoading ? "Loading…" : (model.mode == .day ? "Nothing on this day" : "Nothing this week"))
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(SparkVTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if days.count == 1, model.events(on: days[0], calendar: calendar).allSatisfy(\.isAllDay) {
                Text("No timed events")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(days, id: \.self) { day in
                                let all = model.events(on: day, calendar: calendar)
                                // Day mode pins all-day events above the list.
                                let items = model.mode == .day ? all.filter { !$0.isAllDay } : all
                                if model.mode == .week, !items.isEmpty {
                                    AgendaDayHeader(day: day, calendar: calendar, isToday: calendar.isDate(day, inSameDayAs: model.now), count: items.count)
                                        .id("header|\(day.timeIntervalSinceReferenceDate)")
                                }
                                ForEach(items) { event in
                                    AgendaRow(event: event, day: day, now: model.now, calendar: calendar) { meetings.open(event) } join: { meetings.join(event) }
                                        .id("\(day.timeIntervalSinceReferenceDate)|\(event.id)")
                                }
                            }
                        }
                    }
                    // Rows fade out at the bottom edge: there's more to scroll.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
                                                 .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom))
                    .onAppear { scrollToNow(proxy, days: days) }
                    .onChange(of: model.selectedDay) { _, _ in scrollToNow(proxy, days: model.listedDays(calendar: calendar)) }
                    .onChange(of: model.mode) { _, _ in scrollToNow(proxy, days: model.listedDays(calendar: calendar)) }
                }
            }
        }
    }

    /// Today: start at the first event that hasn't ended (week: today's header).
    private func scrollToNow(_ proxy: ScrollViewProxy, days: [Date]) {
        guard let today = days.first(where: { calendar.isDate($0, inSameDayAs: model.now) }) else { return }
        if model.mode == .week {
            if !model.events(on: today, calendar: calendar).isEmpty {
                proxy.scrollTo("header|\(today.timeIntervalSinceReferenceDate)", anchor: .top)
            }
            return
        }
        guard let next = model.events(on: today, calendar: calendar).first(where: { !$0.isAllDay && $0.end > model.now }) else { return }
        proxy.scrollTo("\(today.timeIntervalSinceReferenceDate)|\(next.id)", anchor: .top)
    }

    private var header: some View {
        HStack(spacing: 4) {
            PlannerIconButton(symbol: "chevron.left", help: model.mode == .day ? "Previous day" : "Previous week", size: 16) { model.step(by: -1, calendar: calendar) }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            PlannerIconButton(symbol: "chevron.right", help: model.mode == .day ? "Next day" : "Next week", size: 16) { model.step(by: 1, calendar: calendar) }
            Spacer(minLength: 4)
            if !isShowingToday {
                WidgetChip(title: "Today", help: "Back to today") { model.goToToday(calendar: calendar) }
            }
            ForEach(AgendaModel.Mode.allCases) { mode in
                WidgetChip(title: mode.title, isOn: model.mode == mode, help: "Show a \(mode.rawValue)") { model.mode = mode }
            }
            Menu {
                CalendarPickerItems(controller: meetings)
                Divider()
                Toggle("Show All-Day Events", isOn: Binding(get: { CalendarPreferences.shared.showsAllDay },
                                                             set: { CalendarPreferences.shared.showsAllDay = $0 }))
                Button("Open in \(MeetingsController.title(for: CalendarPreferences.shared.openTarget))") { meetings.openDay(model.selectedDay) }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Calendars and options")
            .accessibilityLabel("Calendars and options")
        }
        .frame(height: 20)
    }

    private var isShowingToday: Bool {
        model.isSelected(calendar.startOfDay(for: model.now), calendar: calendar)
    }

    private var title: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        if model.mode == .day {
            if calendar.isDate(model.selectedDay, inSameDayAs: model.now) {
                formatter.setLocalizedDateFormatFromTemplate("dMMMM")
                return "Today, \(formatter.string(from: model.selectedDay))"
            }
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
            return formatter.string(from: model.selectedDay)
        }
        let week = CalendarGrid.week(containing: model.selectedDay, calendar: calendar)
        guard let first = week.first, let last = week.last else { return "" }
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "\(formatter.string(from: first)) – \(formatter.string(from: last))"
    }
}

private struct AgendaDayHeader: View {
    let day: Date
    let calendar: Calendar
    let isToday: Bool
    let count: Int

    var body: some View {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEd")
        return HStack(spacing: 4) {
            Text(formatter.string(from: day).uppercased())
                .font(SparkVTheme.eyebrow(8.5))
                .tracking(0.6)
                .foregroundStyle(isToday ? SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red) : SparkVTheme.textSecondary)
            Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
        }
        .frame(height: 13)
        .padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One event: time (or "All day"), a bar in the calendar's color, the title,
/// and Join for calls that haven't ended. Click opens the event.
struct AgendaRow: View {
    let event: CalendarMeeting
    let day: Date
    let now: Date
    let calendar: Calendar
    let open: () -> Void
    let join: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let ended = event.end <= now && !event.isAllDay
        let live = event.start <= now && event.end > now && !event.isAllDay
        Button(action: open) {
            HStack(spacing: 6) {
                Text(timeText(live: live))
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(live ? SparkVTheme.choose(apple: SparkVTheme.success, sparkv: SparkVTheme.red) : SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 46, alignment: .leading)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(event.calendarColor.color.opacity(event.isFree ? 0.45 : 1))
                    .frame(width: 3, height: 13)
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ended ? SparkVTheme.textTertiary : SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let location = event.location, event.link == nil {
                    Text(location)
                        .font(.system(size: 9.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 2)
                if let link = event.link, !ended {
                    AgendaJoinPill(isLive: live, provider: link.provider, action: join)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0)))
            .contentShape(Rectangle())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help("\(event.title)\(event.calendarTitle.isEmpty ? "" : " · \(event.calendarTitle)") · click to open")
        .contextMenu { CalendarEventMenuItems(meeting: event) }
        .accessibilityLabel("\(timeText(live: live)), \(event.title)\(event.calendarTitle.isEmpty ? "" : ", \(event.calendarTitle)")")
        .accessibilityHint("Opens the event")
    }

    private func timeText(live: Bool) -> String {
        if event.isAllDay { return "All day" }
        if live { return "Now" }
        // A meeting that began the day before shows as continuing.
        if event.start < calendar.startOfDay(for: day) { return "…" + MeetingsController.timeFormatter.string(from: event.end) }
        return MeetingsController.timeFormatter.string(from: event.start)
    }
}

private struct AgendaJoinPill: View {
    let isLive: Bool
    let provider: MeetingLink.Provider
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "video.fill").font(.system(size: 7, weight: .bold))
                Text("Join").font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(isLive ? Color.white : SparkVTheme.text)
            .padding(.horizontal, 7)
            .frame(height: 15)
            .background(Capsule().fill(isLive ? SparkVTheme.choose(apple: Color.green, sparkv: SparkVTheme.red).opacity(hover.isOn ? 0.8 : 1)
                                              : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .fixedSize()
        .onHover { hover.isOn = $0 }
        .help("Join on \(provider.displayName)")
        .accessibilityLabel("Join on \(provider.displayName)")
    }
}
