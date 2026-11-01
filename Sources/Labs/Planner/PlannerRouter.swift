import SwiftUI

/// The pages of the Planner (the tall Today tab).
enum PlannerSection: String, CaseIterable, Identifiable, Sendable {
    case today
    case agenda
    case reminders
    case timers
    case weather
    case launcher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .agenda: "Agenda"
        case .reminders: "Reminders"
        case .timers: "Timers"
        case .weather: "Weather"
        case .launcher: "Launcher"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.horizon.fill"
        case .agenda: "calendar"
        case .reminders: "checklist"
        case .timers: "timer"
        case .weather: "cloud.sun.fill"
        case .launcher: "square.grid.3x3.fill"
        }
    }

    var help: String {
        switch self {
        case .today: "Today: meetings, reminders, weather and the timer"
        case .agenda: "Agenda: day, week and month"
        case .reminders: "Reminders due today"
        case .timers: "Timers, stopwatches and Pomodoro"
        case .weather: "Weather"
        case .launcher: "Launcher: pinned apps and shortcuts"
        }
    }

    /// Apple: each page keeps its app's color; SparkV Red uses the accent.
    var tint: Color {
        guard SparkVTheme.isApple else { return SparkVTheme.red }
        return switch self {
        case .today: Color.yellow
        case .agenda: Color.red
        case .reminders: Color.orange
        case .timers: Color.orange
        case .weather: Color.cyan
        case .launcher: Color.indigo
        }
    }
}

/// Which Planner page shows, remembered across launches (`planner.section`).
/// Hub tiles, menus and the timer's "All Timers…" switch it.
@MainActor
final class PlannerRouter: ObservableObject {
    static let shared = PlannerRouter()
    static let sectionKey = "planner.section"

    @Published var section: PlannerSection {
        didSet {
            defaults.set(section.rawValue, forKey: Self.sectionKey)
            lastPicked = Date()
        }
    }

    /// When the page last changed; after a while away the Planner opens on Today.
    private(set) var lastPicked = Date()
    static let returnToTodayAfter: TimeInterval = 10 * 60
    /// A hub tile or menu asked for a page just now: the next appearance keeps it.
    private var requestedAt: Date?

    /// Set by the window controller: opens the drawer on the Today tab, for
    /// menu items outside the drawer (the gear menu, notifications).
    var openDrawer: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        section = defaults.string(forKey: Self.sectionKey).flatMap(PlannerSection.init(rawValue:)) ?? .today
    }

    /// The Planner appeared (the drawer opened on Today). Today shows when a
    /// meeting is about to start, a timer rings (the Timers page also has
    /// Stop), or the last page was picked a while ago; otherwise the page the
    /// user left stays.
    func pageAppeared(meetingSoon: Bool, ringing: Bool, now: Date = Date()) {
        if let requestedAt {
            self.requestedAt = nil
            if now.timeIntervalSince(requestedAt) < 5 { return }
        }
        if ringing {
            if section != .timers, section != .today { section = .today }
        } else if meetingSoon || now.timeIntervalSince(lastPicked) > Self.returnToTodayAfter {
            if section != .today { section = .today }
        }
    }

    /// Switches the page (at once: it's a click or a menu choice) and opens
    /// the drawer when it is closed.
    func show(_ section: PlannerSection) {
        request(section)
        openDrawer?()
    }

    /// Picks the page the drawer is about to show (hub tiles, menus): kept
    /// even if a meeting is about to start.
    func request(_ section: PlannerSection) {
        self.section = section
        requestedAt = Date()
    }
}
