import SwiftUI

// MARK: - Page

/// The Planner: the tall Today tab (508×114 pt of content). A slim rail on
/// the left picks the page (Today, Agenda, Reminders, Timers, Weather,
/// Launcher); the page fills the rest.
struct PlannerPage: View {
    @ObservedObject private var router = PlannerRouter.shared
    @EnvironmentObject private var meetings: MeetingsController
    @EnvironmentObject private var timer: TimerController

    var body: some View {
        HStack(spacing: 8) {
            PlannerRail(router: router)
                .frame(width: PlannerMetrics.railWidth)
            ZStack(alignment: .topLeading) {
                page(router.section)
                    .id(router.section)
                    .transition(.sparkVCrossfade)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A click switches pages: a quick crossfade (Reduce Motion: fade).
            .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: router.section)
        }
        .onAppear {
            let soon = meetings.isEnabled && meetings.meetings.contains { meetings.isInHeadsUp($0) }
            router.pageAppeared(meetingSoon: soon, ringing: timer.ringing != nil)
        }
    }

    @ViewBuilder
    private func page(_ section: PlannerSection) -> some View {
        switch section {
        case .today: PlannerTodaySection()
        case .agenda: AgendaSectionView()
        case .reminders: PlannerRemindersSection()
        case .timers: PlannerTimersSection()
        case .weather: PlannerWeatherSection()
        case .launcher: PlannerLauncherSection()
        }
    }
}

enum PlannerMetrics {
    static let railWidth: CGFloat = 24
    static let railButtonHeight: CGFloat = 18
    /// Tall enough for the Planner (the tall drawer gives 114 pt).
    static let minimumHeight: CGFloat = 100
}

/// Page icons stacked on the left: the active one on a soft pill, like the
/// header tabs.
struct PlannerRail: View {
    @ObservedObject var router: PlannerRouter
    @Namespace private var pill

    var body: some View {
        VStack(spacing: 1) {
            ForEach(PlannerSection.allCases) { section in
                PlannerRailButton(section: section, isActive: router.section == section, pill: pill) {
                    router.section = section
                }
            }
            Spacer(minLength: 0)
        }
        .animation(SparkVMotion.reduceMotion ? nil : SparkVMotion.easeInOut(SparkVMotion.Duration.small), value: router.section)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Planner pages")
    }
}

private struct PlannerRailButton: View {
    let section: PlannerSection
    let isActive: Bool
    let pill: Namespace.ID
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: section.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isActive ? (SparkVTheme.isApple ? section.tint : SparkVTheme.activeGlyph)
                                          : (hover.isOn ? SparkVTheme.text : SparkVTheme.inactiveGlyph))
                .frame(width: PlannerMetrics.railWidth, height: PlannerMetrics.railButtonHeight)
                .background {
                    if isActive {
                        Capsule()
                            .fill(SparkVTheme.activeTabFill)
                            .overlay(Capsule().strokeBorder(SparkVTheme.activeTabStroke, lineWidth: 0.5))
                            .matchedGeometryEffect(id: "plannerRailPill", in: pill)
                    } else {
                        Capsule().fill(SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0))
                    }
                }
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(section.help)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Shared pieces

/// Small round icon button (chevrons, refresh, options).
struct PlannerIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 18
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0)))
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "REMINDERS" style label: SF Pro semibold in Apple, SF Mono in SparkV Red.
struct PlannerEyebrow: View {
    let text: String
    var color: Color = SparkVTheme.textSecondary

    var body: some View {
        Text(text.uppercased())
            .font(SparkVTheme.eyebrow(8.5))
            .tracking(SparkVTheme.isApple ? 0.4 : 0.8)
            .foregroundStyle(color)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A centered card for "connect" and "turned off" states.
struct PlannerAccessCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(SparkVTheme.isApple ? 0.18 : 0.14))
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let button {
                    Button(button, action: action)
                        .buttonStyle(SparkVPrimaryButtonStyle())
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: 330, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Today

/// Today: the date and weather on top, today's meetings and the timer below.
struct PlannerTodaySection: View {
    @EnvironmentObject private var meetings: MeetingsController
    @ObservedObject private var reminders = RemindersController.shared
    var fixedDate: Date? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(dateTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    if reminders.access == .granted, reminders.dueCount > 0 {
                        Button { PlannerRouter.shared.section = .reminders } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "checklist").font(.system(size: 8.5, weight: .bold))
                                Text("\(reminders.dueCount) due").font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(reminders.overdueCount > 0 ? SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red) : SparkVTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .frame(height: 15)
                            .background(Capsule().fill(SparkVTheme.surface))
                        }
                        .buttonStyle(SparkVPressStyle())
                        .help("Reminders due today")
                        .accessibilityLabel("\(reminders.dueCount) reminders due")
                    }
                    Spacer(minLength: 4)
                    WeatherGlance(showsCity: true, showsDay: true, size: 10.5)
                        .onTapGesture { PlannerRouter.shared.section = .weather }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { PlannerRouter.shared.section = .weather }
                }
                .frame(height: 16)
                Group {
                    if let intel = MeetingIntelCenter.current {
                        MeetingStartTodaySlot(coordinator: intel.coordinator) { MeetingsView() }
                    } else {
                        MeetingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle()
                .fill(SparkVTheme.choose(apple: Color.white.opacity(0.15), sparkv: SparkVTheme.stroke))
                .frame(width: 1)
                .padding(.vertical, 10)
            TimerView()
                .frame(width: 172)
        }
        .remindersVisible(reminders)
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: fixedDate ?? Date())
    }
}

// MARK: - Reminders

/// Reminders due today and overdue in two columns, with quick add.
struct PlannerRemindersSection: View {
    @ObservedObject var controller: RemindersController = .shared
    var fixedDate: Date? = nil

    var body: some View {
        Group {
            if controller.access == .granted {
                content
            } else {
                PlannerAccessCard(
                    symbol: controller.access == .denied ? "checklist.unchecked" : "checklist",
                    tint: PlannerSection.reminders.tint,
                    title: controller.access == .denied ? "Reminders access is off" : "Reminders due today",
                    detail: "Check off and add Apple Reminders from the notch. They stay in Reminders and sync through iCloud as usual.",
                    button: controller.access == .denied ? "Open Settings" : (controller.isRequestingAccess ? "Connecting…" : "Connect Reminders")
                ) {
                    if controller.access == .denied { controller.openPrivacySettings() } else { controller.requestAccess() }
                }
            }
        }
        .remindersVisible(controller)
    }

    private var content: some View {
        let now = fixedDate ?? Date()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                PlannerEyebrow(text: "Due today", color: SparkVTheme.textSecondary)
                Text(countText)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(controller.overdueCount > 0 ? SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red) : SparkVTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                ReminderQuickAddField(controller: controller)
                    .frame(width: 262)
                Menu {
                    RemindersListItems(controller: controller)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Lists and options")
                .accessibilityLabel("Reminder lists and options")
                PlannerIconButton(symbol: "arrow.up.forward.app", help: "Open Reminders", size: 18) { controller.openRemindersApp() }
            }
            .frame(height: 22)

            if controller.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(PlannerSection.reminders.tint)
                    Text("Nothing due today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                    Text(controller.showsUndated ? "Undated reminders show here too" : "Type above to add one")
                        .font(.system(size: 9.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 2) {
                        ForEach(controller.items) { item in
                            ReminderRow(controller: controller, item: item, now: now, height: 20)
                                .transition(.opacity)
                        }
                    }
                    .animation(SparkVMotion.easeOut(SparkVMotion.Duration.standard), value: controller.items.map(\.id))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = controller.message {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .background(Capsule().fill(SparkVTheme.background.opacity(0.96)))
                    .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                    .transition(.sparkVEnter)
            }
        }
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: controller.message)
    }

    private var countText: String {
        let due = controller.dueCount
        let late = controller.overdueCount
        if due == 0 { return "" }
        return late > 0 ? "\(due) · \(late) overdue" : "\(due)"
    }
}

/// Lists to show, undated reminders and where quick add puts new ones.
struct RemindersListItems: View {
    @ObservedObject var controller: RemindersController

    var body: some View {
        if controller.lists.isEmpty {
            Text("No lists")
        } else {
            Section("Show Lists") {
                ForEach(controller.lists) { list in
                    Toggle(list.title, isOn: controller.binding(for: list.id))
                }
            }
            Picker("Add New Reminders To", selection: Binding(get: { controller.defaultListID ?? "" },
                                                              set: { controller.defaultListID = $0.isEmpty ? nil : $0 })) {
                Text("Default List").tag("")
                ForEach(controller.lists.filter(\.allowsAdding)) { list in
                    Text(list.title).tag(list.id)
                }
            }
        }
        Divider()
        Toggle("Show Reminders Without a Date", isOn: $controller.showsUndated)
        Toggle("New Reminders Are Due Today", isOn: $controller.quickAddDueToday)
    }
}

// MARK: - Timers

/// Every timer as a card, plus a card to start a new one.
struct PlannerTimersSection: View {
    @EnvironmentObject private var timer: TimerController

    var body: some View {
        Group {
            if timer.isEnabled {
                HStack(spacing: 6) {
                    // Timers scroll sideways; the New card stays put on the right.
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(timer.entries) { entry in
                                    PlannerTimerCard(entry: entry, isRinging: isRinging(entry))
                                        .frame(width: 140)
                                        .id(entry.id)
                                        .transition(.sparkVEnter)
                                }
                            }
                            .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: timer.entries.map(\.id))
                        }
                        // More than two: the third peeks in and fades, so it reads as scrollable.
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: timer.entries.count > 2 ? 0.9 : 1),
                                                     .init(color: .black.opacity(timer.entries.count > 2 ? 0 : 1), location: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                        .onChange(of: timer.extras.count) { old, new in
                            // A new timer scrolls into view.
                            if new > old, let last = timer.extras.last {
                                withAnimation(SparkVMotion.respecting(SparkVMotion.easeInOut(SparkVMotion.Duration.standard))) {
                                    proxy.scrollTo(last.id.uuidString, anchor: .trailing)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PlannerTimerComposer(isFull: !timer.canAddTimer)
                        .frame(width: 166)
                }
            } else {
                PlannerAccessCard(symbol: "timer", tint: PlannerSection.timers.tint, title: "The timer is off",
                                  detail: "Turn it on to use countdowns, stopwatches and Pomodoro.", button: "Turn On") {
                    timer.isEnabled = true
                }
            }
        }
    }

    private func isRinging(_ entry: TimerEntry) -> Bool {
        guard let ringing = timer.ringing else { return false }
        return ringing.includes(entry.itemID)
    }
}

/// One timer: name, ring and time, controls, and what's next.
struct PlannerTimerCard: View {
    @EnvironmentObject private var timer: TimerController
    @ObservedObject private var preferences = TimerPreferences.shared
    let entry: TimerEntry
    var isRinging = false

    var body: some View {
        WidgetCard(padding: 8) {
            TimerClock(entry: entry) { date in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(entry.accent)
                        Text(entry.title.uppercased())
                            .font(SparkVTheme.eyebrow(8.5))
                            .tracking(0.6)
                            .foregroundStyle(entry.accent)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let session = entry.session {
                            Text(session)
                                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(SparkVTheme.textTertiary)
                                .fixedSize()
                        }
                        Spacer(minLength: 2)
                        if let id = entry.itemID {
                            PlannerIconButton(symbol: "xmark", help: "Remove \(entry.title)", size: 15) { timer.remove(id) }
                        }
                    }
                    .frame(height: 15)

                    if isRinging {
                        HStack(spacing: 6) {
                            TimerRingingGlyph(size: 15)
                            Text("Time’s up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SparkVTheme.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 34)
                        HStack(spacing: 4) {
                            TimerTextButton(title: "Stop", isProminent: true) { timer.stopRinging() }
                            TimerTextButton(title: "Snooze \(preferences.snoozeMinutes)m") { timer.snooze() }
                        }
                    } else {
                        HStack(spacing: 8) {
                            TimerRing(entry: entry, date: date, lineWidth: 3.5, glyphSize: 11)
                                .frame(width: 34, height: 34)
                            Text(entry.timeText(at: date))
                                .font(.system(size: 21, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .tracking(-0.5)
                                .foregroundStyle(entry.isPaused ? SparkVTheme.textTertiary : SparkVTheme.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        TimerControls(entry: entry)
                    }
                    Spacer(minLength: 0)
                    Text(footer(date))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(entry.spoken(at: date))
            }
        }
        .contextMenu { TimerPresetItems(entry: entry) }
    }

    private func footer(_ date: Date) -> String {
        if isRinging { return "Ringing" }
        switch entry.kind {
        case .pomodoro:
            if entry.isPending(at: date) { return "Next phase starting…" }
            let next = Pomodoro.next(after: entry.countdown.phase, completedFocus: entry.countdown.completedFocus).phase
            return "Then \(TimerFormat.longName(of: next).lowercased()), \(Int(Pomodoro.duration(of: next) / 60)) min"
        case .countdown:
            if let end = entry.countdown.endsAt { return "Ends at \(MeetingsController.timeFormatter.string(from: end))" }
            return entry.isPaused ? "Paused" : "\(TimerDurationParser.spoken(entry.countdown.duration)) · ready"
        case .stopwatch:
            if entry.stopwatch.laps.isEmpty { return entry.isIdle ? "Ready" : (entry.isRunning ? "Running" : "Paused") }
            return "Lap \(entry.stopwatch.laps.count + 1) · \(TimerFormat.elapsed(entry.stopwatch.currentLap(at: date)))"
        }
    }
}

@MainActor
final class PlannerTimerDraft: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case countdown, stopwatch
        var id: String { rawValue }
    }

    @Published var name = ""
    @Published var duration = ""
    @Published var kind: Kind = .countdown
    @Published var error: String?

    var seconds: TimeInterval? { TimerDurationParser.seconds(from: duration) }
}

/// New timer: a name, a length ("5", "1:30", "1h 30m") or Stopwatch, Start.
struct PlannerTimerComposer: View {
    @EnvironmentObject private var timer: TimerController
    @StateObject private var draft = PlannerTimerDraft()
    var isFull = false

    var body: some View {
        WidgetCard(padding: 8) {
            if isFull {
                VStack(spacing: 4) {
                    Image(systemName: "timer").font(.system(size: 15, weight: .semibold)).foregroundStyle(SparkVTheme.textTertiary)
                    Text("\(TimerController.maxExtras + 1) timers is the most")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                    Text("Remove one to add another")
                        .font(.system(size: 9))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                PlannerEyebrow(text: "New", color: SparkVTheme.textSecondary)
                Spacer(minLength: 2)
                ForEach(PlannerTimerDraft.Kind.allCases) { kind in
                    WidgetChip(title: kind == .countdown ? "Timer" : "Stopwatch", isOn: draft.kind == kind,
                               help: kind == .countdown ? "A countdown" : "A stopwatch") { draft.kind = kind }
                }
            }
            .frame(height: 20)
            PlannerField(placeholder: "Name (optional)", text: $draft.name, symbol: "textformat") { start() }
            if draft.kind == .countdown {
                PlannerField(placeholder: "Length: 5, 1:30, 1h 30m", text: $draft.duration, symbol: "timer",
                             isInvalid: !draft.duration.isEmpty && draft.seconds == nil) { start() }
                HStack(spacing: 3) {
                    ForEach([1, 5, 10, 25], id: \.self) { minutes in
                        WidgetChip(title: "\(minutes)m", help: "Start a \(minutes)-minute timer") {
                            draft.duration = "\(minutes)"
                            start()
                        }
                    }
                }
            } else {
                Text("Counts up from zero. Laps with the flag.")
                    .font(.system(size: 9))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .frame(height: 20)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack {
                if let error = draft.error {
                    Text(error).font(.system(size: 9)).foregroundStyle(SparkVTheme.warning).lineLimit(1)
                }
                Spacer(minLength: 0)
                TimerTextButton(title: "Start", isProminent: true, height: 20) { start() }
                    .disabled(draft.kind == .countdown && draft.seconds == nil)
            }
        }
    }

    private func start() {
        switch draft.kind {
        case .countdown:
            guard let seconds = draft.seconds else {
                draft.error = draft.duration.isEmpty ? "Type a length" : "Try 5, 1:30 or 1h 30m"
                return
            }
            timer.addCountdown(seconds: seconds, name: draft.name)
        case .stopwatch:
            timer.addStopwatch(name: draft.name)
        }
        draft.name = ""
        draft.duration = ""
        draft.error = nil
    }
}

/// A plain text field on a capsule (the Planner's inputs).
struct PlannerField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String = "pencil"
    var isInvalid = false
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(isInvalid ? SparkVTheme.warning : SparkVTheme.textTertiary)
                .frame(width: 11)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.text)
                .onSubmit(onSubmit)
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(isInvalid ? SparkVTheme.warning.opacity(0.7) : SparkVTheme.stroke, lineWidth: 1))
    }
}

// MARK: - Weather

@MainActor
final class PlannerWeatherUI: ObservableObject {
    @Published var isEditing = false
}

/// Weather: now, the next hours and days; or the city picker while it's off.
struct PlannerWeatherSection: View {
    @ObservedObject var controller: WeatherController = .shared
    @StateObject private var ui = PlannerWeatherUI()
    var fixedDate: Date? = nil

    var body: some View {
        Group {
            if let place = controller.place, let forecast = controller.forecast, !ui.isEditing {
                forecastView(place: place, forecast: forecast, now: fixedDate ?? Date())
            } else if controller.isConfigured, !ui.isEditing {
                VStack(spacing: 6) {
                    if case .failed(let message) = controller.status {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 16, weight: .medium)).foregroundStyle(SparkVTheme.textTertiary)
                        Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(SparkVTheme.textSecondary)
                        Button("Try Again") { controller.refresh() }.buttonStyle(SparkVSecondaryButtonStyle())
                    } else {
                        ProgressView().controlSize(.small).tint(SparkVTheme.progressTint)
                        Text("Loading \(controller.place?.name ?? "")…").font(.system(size: 10.5)).foregroundStyle(SparkVTheme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                setup
            }
        }
        .weatherVisible(controller)
    }

    private var setup: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "cloud.sun.fill")
                        .symbolRenderingMode(SparkVTheme.isApple ? .multicolor : .hierarchical)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SparkVTheme.isApple ? Color.white : SparkVTheme.text)
                    Text(controller.isConfigured ? "Change city" : "Weather is off")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                }
                Text("Pick a city and SparkV asks Open-Meteo for its forecast, using only the city’s rounded coordinates: every 30 minutes while weather is on screen, hourly with rain alerts. No account, no location access. Typing a city sends the text to Open-Meteo’s search.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.isConfigured {
                    Button("Done") { ui.isEditing = false }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            .frame(width: 190, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                WeatherCityEditor(controller: controller, showsDisclosure: false)
                Toggle("Rain alerts under the notch", isOn: $controller.rainAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .tint(SparkVTheme.accent)
                    .disabled(!controller.isConfigured)
                Text(OpenMeteo.attribution)
                    .font(.system(size: 8.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: controller.place) { _, place in if place != nil { ui.isEditing = false } }
    }

    private func forecastView(place: WeatherPlace, forecast: WeatherForecast, now: Date) -> some View {
        let today = forecast.day(containing: now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                // Now
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "location.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(SparkVTheme.textTertiary)
                        Text(place.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        WeatherGlyph(code: forecast.current.code, isDay: forecast.current.isDay, size: 21)
                        Text(controller.temperature(forecast.current.temperature))
                            .font(.system(size: 30, weight: .semibold).monospacedDigit())
                            .tracking(-0.8)
                            .foregroundStyle(SparkVTheme.text)
                    }
                    Text(WeatherCode.description(forecast.current.code))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                    if let today {
                        Text("H \(controller.temperature(today.high))  L \(controller.temperature(today.low))  ·  feels \(controller.temperature(forecast.current.apparent))")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 138, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(controller.summary ?? "")

                // Next hours
                HStack(spacing: 0) {
                    ForEach(Array(forecast.upcomingHours(from: now, count: 7).enumerated()), id: \.element.time) { index, hour in
                        VStack(spacing: 3) {
                            Text(index == 0 ? "Now" : WeatherFormat.hour(hour.time, zone: forecast.timeZone))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(index == 0 ? SparkVTheme.text : SparkVTheme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            WeatherGlyph(code: hour.code, isDay: hour.isDay, size: 12)
                            Text(controller.temperature(hour.temperature))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(SparkVTheme.text)
                            Text(hour.precipitationProbability >= WeatherFormat.rainShownFrom ? "\(hour.precipitationProbability)%" : " ")
                                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(WeatherFormat.rainColor)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(index == 0 ? "Now" : WeatherFormat.hour(hour.time, zone: forecast.timeZone)): \(controller.temperature(hour.temperature)), \(WeatherCode.description(hour.code)), \(hour.precipitationProbability)% chance of rain")
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SparkVTheme.surface))
                .frame(maxWidth: .infinity)

                // Next days
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(forecast.daily.filter { $0.date.addingTimeInterval(86_400) > now }.prefix(4).enumerated()), id: \.element.date) { index, day in
                        HStack(spacing: 4) {
                            Text(index == 0 ? "Today" : WeatherFormat.weekday(day.date.addingTimeInterval(43_200), zone: forecast.timeZone))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(SparkVTheme.textSecondary)
                                .frame(width: 32, alignment: .leading)
                            WeatherGlyph(code: day.code, size: 10)
                            Spacer(minLength: 0)
                            Text(controller.temperature(day.high))
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(SparkVTheme.text)
                            Text(controller.temperature(day.low))
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(SparkVTheme.textTertiary)
                                .frame(width: 22, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(index == 0 ? "Today" : WeatherFormat.weekday(day.date, zone: forecast.timeZone)): high \(controller.temperature(day.high)), low \(controller.temperature(day.low)), \(WeatherCode.description(day.code))")
                    }
                }
                .frame(width: 104)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(controller.updatedText)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
                if case .failed(let message) = controller.status {
                    Text("· \(message)").font(.system(size: 9, weight: .medium)).foregroundStyle(SparkVTheme.warning)
                }
                Text("· \(OpenMeteo.attribution)")
                    .font(.system(size: 9))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if controller.rainAlerts {
                    Image(systemName: "cloud.rain")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .help("Rain alerts are on (\(controller.rainThreshold)%)")
                }
                PlannerIconButton(symbol: "arrow.clockwise", help: "Refresh", size: 16) { controller.refresh() }
                    .disabled(controller.status == .loading)
                PlannerIconButton(symbol: "slider.horizontal.3", help: "City, units and rain alerts", size: 16) { ui.isEditing = true }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Launcher

/// Pinned apps, shortcuts and SparkV actions: click to open or run.
struct PlannerLauncherSection: View {
    @EnvironmentObject private var macros: MacroController

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Self.columns, spacing: 6) {
                ForEach(macros.launcher) { item in
                    LauncherTile(item: item, status: macros.launcherStatus(for: item))
                        .transition(.sparkVEnter)
                }
                if macros.canAddToLauncher {
                    LauncherAddTile()
                }
            }
            .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: macros.launcher.map(\.id))
            Spacer(minLength: 0)
            // One row of tiles leaves room for a hint.
            if macros.launcher.count < 6 {
                HStack(spacing: 5) {
                    Image(systemName: "hand.point.up.left").font(.system(size: 9, weight: .semibold))
                    Text("Click to open or run. Right-click a tile to move or remove it. Shortcuts run in the background.")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 9.5))
                .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { macros.refreshLibraryIfStale() }
    }
}

struct LauncherTile: View {
    @EnvironmentObject private var macros: MacroController
    let item: MacroController.LauncherItem
    let status: MacroController.Status

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let assignment = item.assignment
        Button { macros.runLauncher(item) } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    icon(assignment)
                        .frame(width: 26, height: 26)
                    badge
                        .offset(x: 5, y: 3)
                }
                Text(label(assignment))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 3)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(LabsBHubTileBackground(isActive: status == .running, isHovered: hover.isOn, tint: PlannerSection.launcher.tint))
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(status == .running)
        .onHover { hover.isOn = $0 }
        .help(help(assignment))
        .accessibilityLabel(accessibility(assignment))
        .contextMenu {
            Button("Move Earlier") { macros.moveLauncherItem(item.id, by: -1) }
                .disabled(macros.launcher.first?.id == item.id)
            Button("Move Later") { macros.moveLauncherItem(item.id, by: 1) }
                .disabled(macros.launcher.last?.id == item.id)
            if case .shortcut? = assignment {
                Button("Open Shortcuts") { macros.openShortcutsApp() }
            }
            Divider()
            Button("Remove from Launcher") { macros.removeFromLauncher(item.id) }
        }
    }

    @ViewBuilder
    private func icon(_ assignment: MacroController.Assignment?) -> some View {
        switch assignment {
        case .app?:
            if let image = assignment.flatMap(LauncherIcons.icon(for:)) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 20)).foregroundStyle(SparkVTheme.textTertiary)
            }
        case .shortcut?:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(SparkVTheme.isApple ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                          : AnyShapeStyle(SparkVTheme.redSoft))
                .overlay(Image(systemName: "square.2.layers.3d.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.isApple ? Color.white : SparkVTheme.red))
        case .builtIn(let action)?:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(SparkVTheme.choose(apple: Color.white.opacity(0.14), sparkv: SparkVTheme.surfaceHover))
                .overlay(Image(systemName: action.systemImage).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red)))
        case nil:
            Image(systemName: "questionmark.square.dashed").font(.system(size: 20)).foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
                .frame(width: 12, height: 12)
                .background(Circle().fill(SparkVTheme.background))
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(SparkVTheme.success)
                .background(Circle().fill(SparkVTheme.background))
        case .failed, .missing:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(status == .missing ? SparkVTheme.warning : SparkVTheme.destructive)
        default:
            EmptyView()
        }
    }

    private func label(_ assignment: MacroController.Assignment?) -> String {
        if case .failed = status { return "Failed" }
        return assignment?.title ?? "Missing"
    }

    private var labelColor: Color {
        switch status {
        case .failed: SparkVTheme.destructive
        case .missing: SparkVTheme.warning
        default: hover.isOn ? SparkVTheme.text : SparkVTheme.text.opacity(0.85)
        }
    }

    private func help(_ assignment: MacroController.Assignment?) -> String {
        let name = assignment?.title ?? ""
        switch status {
        case .failed(let message): return "\(name): \(message)"
        case .missing: return "“\(name)” can’t be found. Right-click to remove it."
        default:
            switch assignment {
            case .app?: return "Open \(name)"
            case .shortcut?: return "Run the shortcut “\(name)”"
            default: return name
            }
        }
    }

    private func accessibility(_ assignment: MacroController.Assignment?) -> String {
        let name = assignment?.title ?? "Missing item"
        switch assignment {
        case .app?: return "Open \(name)"
        case .shortcut?: return "Run shortcut \(name)"
        default: return name
        }
    }
}

/// The "+" tile: pick an app, a running app, a shortcut or a SparkV action.
struct LauncherAddTile: View {
    @EnvironmentObject private var macros: MacroController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Menu {
            LauncherAddItems(macros: macros)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                Text("Add").font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(hover.isOn ? LabsBStyle.hoverGlyph : SparkVTheme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                    .strokeBorder(hover.isOn ? SparkVTheme.choose(apple: Color.white.opacity(0.4), sparkv: SparkVTheme.red.opacity(0.6)) : Color.white.opacity(0.15),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover.isOn = $0 }
        .help("Pin an app, a shortcut or a SparkV action")
        .accessibilityLabel("Add to launcher")
    }
}

/// Menu content: choose an app, running apps, shortcuts, SparkV actions.
struct LauncherAddItems: View {
    @ObservedObject var macros: MacroController

    var body: some View {
        Button("Choose an App…") {
            macros.chooseApp { assignment in
                if let assignment { macros.addToLauncher(assignment) }
            }
        }
        Menu("Running Apps") {
            let apps = macros.runningApps.filter { !macros.isPinned($0) }
            if apps.isEmpty { Text("None") }
            ForEach(apps, id: \.storageValue) { app in
                Button(app.title) { macros.addToLauncher(app) }
            }
        }
        Menu("Shortcuts") {
            if macros.libraryEntries.isEmpty {
                Text("No shortcuts found")
            }
            ForEach(macros.libraryEntries) { entry in
                let assignment = MacroController.Assignment.shortcut(entry.name)
                Button(entry.name) { macros.addToLauncher(assignment, shortcutID: entry.identifier) }
                    .disabled(macros.isPinned(assignment))
            }
            Divider()
            Button("Open Shortcuts…") { macros.openShortcutsApp() }
        }
        Menu("SparkV") {
            ForEach(MacroController.BuiltInAction.allCases) { action in
                Button(action.title) { macros.addToLauncher(.builtIn(action)) }
                    .disabled(macros.isPinned(.builtIn(action)))
            }
        }
    }
}
