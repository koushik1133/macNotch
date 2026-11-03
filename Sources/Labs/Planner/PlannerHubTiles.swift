import SwiftUI

// Agents hub tiles for the Planner (category "Planner", the launcher
// "System"). Same face as the hub's own tiles: 48 pt tall, the glyph in the
// feature's tint (Apple) or monochrome lit red (SparkV Red), a 9 pt label
// that carries live state ("in 12 min", "3 due", "04:12", "12°").
// No required arguments: they use the drawer's environment objects.

/// The shared tile face.
struct PlannerHubTileFace<Glyph: View>: View {
    let title: String
    let tint: Color
    var isActive = false
    let help: String
    let action: () -> Void
    @ViewBuilder let glyph: Glyph

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                glyph
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LabsBHubTileBackground.glyph(isActive: isActive, isHovered: hover.isOn, tint: tint))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(LabsBHubTileBackground.label(isActive: isActive, isHovered: hover.isOn))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
            .background(LabsBHubTileBackground(isActive: isActive, isHovered: hover.isOn, tint: tint))
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Opens the Planner (the Today tab) on a page.
@MainActor
private func openPlanner(_ section: PlannerSection, state: NotchState) {
    PlannerRouter.shared.request(section)
    withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) { state.select(.today) }
}

/// Agenda: the next meeting's countdown, or "Agenda".
struct AgendaHubTile: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var meetings: MeetingsController

    var body: some View {
        let next = meetings.upcoming(limit: 1).first
        let title: String = {
            guard meetings.access == .granted, let next else { return "Agenda" }
            return MeetingsController.statusText(for: next, now: Date())
        }()
        PlannerHubTileFace(title: title, tint: PlannerSection.agenda.tint, isActive: next.map { meetings.timing(for: $0).hasStarted } ?? false,
                           help: next.map { "Agenda · next: \($0.title) (\(MeetingsController.timeFormatter.string(from: $0.start)))" } ?? "Agenda: day, week and month") {
            openPlanner(.agenda, state: state)
        } glyph: {
            Image(systemName: "calendar.day.timeline.left")
        }
        .contextMenu { MeetingsMenuItems(controller: meetings) }
    }
}

/// Reminders: how many are due ("3 due"), red-washed when some are late.
struct RemindersHubTile: View {
    @EnvironmentObject private var state: NotchState
    @ObservedObject private var reminders = RemindersController.shared

    var body: some View {
        let granted = reminders.access == .granted
        PlannerHubTileFace(title: granted && reminders.dueCount > 0 ? "\(reminders.dueCount) due" : "Reminders",
                           tint: PlannerSection.reminders.tint, isActive: granted && reminders.overdueCount > 0,
                           help: granted ? "Reminders: \(reminders.dueCount) due today\(reminders.overdueCount > 0 ? ", \(reminders.overdueCount) overdue" : "")" : "Reminders due today") {
            openPlanner(.reminders, state: state)
        } glyph: {
            Image(systemName: "checklist")
        }
        .remindersVisible(reminders)
        .contextMenu { RemindersMenuItems() }
    }
}

/// Timers: the soonest running timer's time, lit while one runs.
struct TimersHubTile: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var timer: TimerController

    var body: some View {
        let lead = timer.activeEntries.first
        Group {
            if let lead {
                TimerClock(entry: lead) { date in
                    face(title: lead.timeText(at: date), active: lead.isRunning, help: lead.spoken(at: date))
                }
            } else {
                face(title: timer.ringing == nil ? "Timers" : "Ringing", active: timer.ringing != nil, help: "Timers, stopwatches and Pomodoro")
            }
        }
        .contextMenu { TimerMenuItems(controller: timer) }
    }

    private func face(title: String, active: Bool, help: String) -> some View {
        PlannerHubTileFace(title: title, tint: PlannerSection.timers.tint, isActive: active, help: help) {
            openPlanner(.timers, state: state)
        } glyph: {
            Image(systemName: timer.ringing != nil ? "bell.and.waves.left.and.right.fill" : "timer")
        }
    }
}

/// Weather: the temperature now with the condition's symbol.
struct WeatherHubTile: View {
    @EnvironmentObject private var state: NotchState
    @ObservedObject private var weather = WeatherController.shared

    var body: some View {
        PlannerHubTileFace(title: weather.forecast.map { weather.temperature($0.current.temperature) + (weather.place.map { " \($0.name)" } ?? "") } ?? "Weather",
                           tint: PlannerSection.weather.tint,
                           help: weather.summary ?? (weather.isConfigured ? "Weather" : "Weather: choose a city to turn it on")) {
            openPlanner(.weather, state: state)
        } glyph: {
            if let forecast = weather.forecast {
                Image(systemName: WeatherCode.symbol(forecast.current.code, isDay: forecast.current.isDay))
                    .symbolRenderingMode(SparkVTheme.isApple ? .multicolor : .monochrome)
            } else {
                Image(systemName: "cloud.sun.fill")
            }
        }
        .weatherVisible(weather)
        .contextMenu { WeatherMenuItems() }
    }
}

/// Launcher: opens the grid of pinned apps and shortcuts; right-click runs one.
struct LauncherHubTile: View {
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var macros: MacroController

    var body: some View {
        PlannerHubTileFace(title: "Launcher", tint: PlannerSection.launcher.tint, help: "Launcher: pinned apps and shortcuts") {
            openPlanner(.launcher, state: state)
        } glyph: {
            Image(systemName: "square.grid.3x3.fill")
        }
        .contextMenu { LauncherMenuItems(macros: macros) }
    }
}
