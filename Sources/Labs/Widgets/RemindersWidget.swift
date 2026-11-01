import AppKit
import Combine
import EventKit
import SwiftUI

// MARK: - Model

/// A reminder copied out of EventKit (so it can cross queues).
struct ReminderItem: Identifiable, Equatable, Sendable {
    /// `calendarItemIdentifier`.
    let id: String
    var title: String
    var due: Date?
    var hasTime: Bool
    /// 1 high … 9 low, 0 none.
    var priority: Int
    var listID: String
    var listTitle: String
    var listColor: CalendarRGBA

    func isOverdue(at now: Date, calendar: Calendar = .current) -> Bool {
        ReminderDue.isOverdue(due: due, hasTime: hasTime, now: now, calendar: calendar)
    }

    func dueLabel(at now: Date, calendar: Calendar = .current) -> String {
        ReminderDue.label(due: due, hasTime: hasTime, now: now, calendar: calendar)
    }

    /// "!!!" for high priority, "!!" medium, "!" low.
    var priorityMarks: String {
        switch priority {
        case 1...4: "!!!"
        case 5: "!!"
        case 6...9: "!"
        default: ""
        }
    }
}

/// A Reminders list.
struct ReminderList: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let color: CalendarRGBA
    let sourceTitle: String
    let allowsAdding: Bool
}

struct RemindersSnapshot: Sendable, Equatable {
    var items: [ReminderItem] = []
    var lists: [ReminderList] = []
    var defaultListID: String?
}

enum RemindersError: LocalizedError {
    case notFound
    case noList

    var errorDescription: String? {
        switch self {
        case .notFound: "That reminder is gone (changed on another device?)."
        case .noList: "There is no Reminders list to add to."
        }
    }
}

// MARK: - EventKit

/// Owns its EventKit store and works on its own serial queue, like the
/// calendar source. PermissionCenter asks for access.
final class RemindersSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.Reminders", qos: .userInitiated)
    private let lock = NSLock()
    private var storage: EKEventStore?

    private var store: EKEventStore {
        lock.lock()
        defer { lock.unlock() }
        if let storage { return storage }
        let created = EKEventStore()
        storage = created
        return created
    }

    /// Forgets cached state, e.g. after access was granted elsewhere.
    func reset() {
        queue.async { [self] in
            lock.lock()
            let existing = storage
            lock.unlock()
            existing?.reset()
        }
    }

    /// Incomplete reminders due by the end of today (overdue included), and
    /// undated ones when asked, from the shown lists.
    func fetch(hidden: Set<String>, showsUndated: Bool, now: Date) async -> RemindersSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let store = self.store
                let all = store.calendars(for: .reminder)
                let lists = all.map {
                    ReminderList(id: $0.calendarIdentifier, title: $0.title, color: CalendarRGBA($0.color),
                                 sourceTitle: $0.source?.title ?? "Other", allowsAdding: $0.allowsContentModifications)
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
                let selected = hidden.isEmpty ? nil : all.filter { !hidden.contains($0.calendarIdentifier) }
                if let selected, selected.isEmpty {
                    continuation.resume(returning: RemindersSnapshot(items: [], lists: lists, defaultListID: defaultID))
                    return
                }
                let calendar = Calendar.current
                let endOfToday = CalendarGrid.dayInterval(now, calendar: calendar).end
                let predicate = showsUndated
                    ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: selected)
                    : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: selected)
                store.fetchReminders(matching: predicate) { reminders in
                    let items = (reminders ?? []).compactMap { reminder -> ReminderItem? in
                        let components = reminder.dueDateComponents
                        let due = components.flatMap { calendar.date(from: $0) }
                        let hasTime = components?.hour != nil
                        guard ReminderDue.isShown(due: due, showsUndated: showsUndated, now: now, calendar: calendar) else { return nil }
                        let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return ReminderItem(
                            id: reminder.calendarItemIdentifier,
                            title: title.isEmpty ? "Untitled reminder" : title,
                            due: due,
                            hasTime: hasTime,
                            priority: reminder.priority,
                            listID: reminder.calendar?.calendarIdentifier ?? "",
                            listTitle: reminder.calendar?.title ?? "",
                            listColor: CalendarRGBA(reminder.calendar?.color)
                        )
                    }
                    let sorted = items.sorted { a, b in
                        ReminderDue.precedes(
                            ReminderDue.sortKey(due: a.due, hasTime: a.hasTime, priority: a.priority, title: a.title, now: now, calendar: calendar),
                            ReminderDue.sortKey(due: b.due, hasTime: b.hasTime, priority: b.priority, title: b.title, now: now, calendar: calendar)
                        )
                    }
                    continuation.resume(returning: RemindersSnapshot(items: sorted, lists: lists, defaultListID: defaultID))
                }
            }
        }
    }

    func setCompleted(_ id: String, _ completed: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let store = self.store
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    continuation.resume(throwing: RemindersError.notFound)
                    return
                }
                reminder.isCompleted = completed
                do {
                    try store.save(reminder, commit: true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Adds a reminder to the list (or the default one). A time adds an
    /// alert at that time, as Reminders itself does.
    func add(_ draft: ReminderDraft, listID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let store = self.store
                let reminder = EKReminder(eventStore: store)
                reminder.title = draft.title
                let list = listID.flatMap { id in store.calendars(for: .reminder).first { $0.calendarIdentifier == id } }
                guard let calendar = list ?? store.defaultCalendarForNewReminders() else {
                    continuation.resume(throwing: RemindersError.noList)
                    return
                }
                reminder.calendar = calendar
                if let due = draft.due {
                    let units: Set<Calendar.Component> = draft.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                    reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
                    if draft.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
                }
                do {
                    try store.save(reminder, commit: true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Controller

/// Apple Reminders due today in the Planner and the widget grid: check
/// them off (optimistic, rolled back on error) and quick-add new ones
/// ("Call Mom tomorrow at 5pm"). Asks for access only from the Connect
/// button, through PermissionCenter. Follows `.EKEventStoreChanged` (no
/// polling), and only fetches while a reminders view is on screen.
@MainActor
final class RemindersController: ObservableObject {
    static let shared = RemindersController()

    enum Access: Equatable {
        case notDetermined
        case granted
        case denied
    }

    enum Keys {
        static let hidden = "reminders.hiddenListIDs"
        static let undated = "reminders.showsUndated"
        static let defaultList = "reminders.defaultListID"
        static let dueToday = "reminders.quickAddDueToday"
    }

    @Published private(set) var access: Access
    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var lists: [ReminderList] = []
    /// Ticked a moment ago: drawn checked, then leave the list.
    @Published private(set) var completingIDs: Set<String> = []
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var isAdding = false
    /// Last error or confirmation, shown for a few seconds.
    @Published private(set) var message: String?
    /// The quick-add text, shared by every reminders view.
    @Published var draft = ""

    @Published var hiddenListIDs: Set<String> {
        didSet { defaults.set(Array(hiddenListIDs).sorted(), forKey: Keys.hidden); refreshIfWatched() }
    }
    @Published var showsUndated: Bool {
        didSet { defaults.set(showsUndated, forKey: Keys.undated); refreshIfWatched() }
    }
    /// nil adds to the default list in Reminders.
    @Published var defaultListID: String? {
        didSet { defaults.set(defaultListID, forKey: Keys.defaultList) }
    }
    /// Quick-add without a date makes the reminder due today, so it shows here.
    @Published var quickAddDueToday: Bool {
        didSet { defaults.set(quickAddDueToday, forKey: Keys.dueToday) }
    }

    private let defaults: UserDefaults
    private let source = RemindersSource()
    private var viewers = 0
    private var isStale = true
    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    private var accessWatch: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var messageTask: Task<Void, Never>?
    private var systemDefaultListID: String?
    /// Renders and tests: no EventKit.
    private var isSample = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenListIDs = Set(defaults.stringArray(forKey: Keys.hidden) ?? [])
        showsUndated = defaults.object(forKey: Keys.undated) as? Bool ?? false
        defaultListID = defaults.string(forKey: Keys.defaultList)
        quickAddDueToday = defaults.object(forKey: Keys.dueToday) as? Bool ?? true
        access = Self.currentAccess()
    }

    // MARK: Lifecycle

    /// Follows access and database changes. Never prompts.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        accessWatch = PermissionCenter.shared.onChange(of: .reminders) { [weak self] _ in
            guard let self, !self.isRequestingAccess else { return }
            self.recheckAccess()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        })
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        })
    }

    func stop() {
        isStarted = false
        accessWatch = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// A reminders view appeared (reference-counted): fetch if anything changed.
    func retain() {
        viewers += 1
        recheckAccess()
        if isStale { refresh() }
    }

    func release() {
        viewers = max(0, viewers - 1)
    }

    private func storeChanged() {
        isStale = true
        refreshIfWatched()
    }

    private func refreshIfWatched() {
        if viewers > 0 { refresh() } else { isStale = true }
    }

    // MARK: Access

    /// The Connect button. The system prompt shows while macOS hasn't asked
    /// yet; once refused, PermissionCenter opens Privacy & Security instead.
    func requestAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        AppLog.log("Reminders: requesting access")
        Task { [weak self] in
            let status = await PermissionCenter.shared.request(.reminders, from: "Reminders")
            guard let self else { return }
            self.isRequestingAccess = false
            AppLog.log("Reminders: access \(status.rawValue)")
            self.source.reset()
            self.recheckAccess()
            if self.access == .granted { self.refresh() }
        }
    }

    func openPrivacySettings() {
        PermissionCenter.shared.openSettings(.reminders, from: "Reminders")
    }

    private func recheckAccess() {
        guard !isSample else { return }
        let updated = Self.currentAccess()
        guard updated != access else { return }
        access = updated
        if updated == .granted {
            source.reset()
            if viewers > 0 { refresh() } else { isStale = true }
        } else {
            items = []
        }
    }

    private static func currentAccess() -> Access {
        switch PermissionCenter.shared.liveStatus(.reminders) {
        case .granted: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    // MARK: Reading

    func refresh() {
        guard access == .granted, !isSample else { return }
        isStale = false
        generation &+= 1
        let token = generation
        let hidden = hiddenListIDs
        let undated = showsUndated
        let source = self.source
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let snapshot = await source.fetch(hidden: hidden, showsUndated: undated, now: Date())
            guard let self, !Task.isCancelled, token == self.generation else { return }
            // Keep a just-ticked reminder drawn until its fade finishes.
            let keep = self.items.filter { self.completingIDs.contains($0.id) && !snapshot.items.map(\.id).contains($0.id) }
            let merged = snapshot.items + keep
            if merged != self.items { self.items = merged }
            if snapshot.lists != self.lists { self.lists = snapshot.lists }
            self.systemDefaultListID = snapshot.defaultListID
        }
    }

    /// Renders and tests.
    func setSample(items: [ReminderItem], lists: [ReminderList]) {
        isSample = true
        access = .granted
        self.items = items
        self.lists = lists
    }

    var visibleItems: [ReminderItem] { items }
    var dueCount: Int { items.filter { !completingIDs.contains($0.id) }.count }
    var overdueCount: Int { items.filter { !completingIDs.contains($0.id) && $0.isOverdue(at: Date()) }.count }

    /// Where quick-add puts new reminders.
    var addListID: String? { defaultListID ?? systemDefaultListID }
    var addListTitle: String {
        let id = addListID
        return lists.first { $0.id == id }?.title ?? "Reminders"
    }

    // MARK: Changes

    /// Ticks (or unticks) at once; saved in the background, rolled back if
    /// Reminders refuses.
    func toggle(_ item: ReminderItem) {
        if completingIDs.contains(item.id) {
            completingIDs.remove(item.id)
            save(item, completed: false)
            return
        }
        completingIDs.insert(item.id)
        save(item, completed: true)
        // Leaves the list after the check has been seen.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, self.completingIDs.contains(item.id) else { return }
            self.completingIDs.remove(item.id)
            self.items.removeAll { $0.id == item.id }
        }
    }

    private func save(_ item: ReminderItem, completed: Bool) {
        guard !isSample else { return }
        let source = self.source
        Task { [weak self] in
            do {
                try await source.setCompleted(item.id, completed)
                AppLog.log("Reminders: \(completed ? "completed" : "reopened") one")
            } catch {
                guard let self else { return }
                AppLog.log("Reminders: couldn't save: \(error.localizedDescription)")
                self.completingIDs.remove(item.id)
                if !self.items.contains(where: { $0.id == item.id }) { self.items.append(item) }
                self.show("Couldn’t update “\(item.title)”: \(error.localizedDescription)")
                self.refresh()
            }
        }
    }

    /// Quick add from `draft` ("Call Mom tomorrow at 5pm").
    func addDraft() {
        let text = draft
        guard let parsed = ReminderQuickAddParser.parse(text, defaultDue: quickAddDueToday ? Date() : nil),
              access == .granted, !isAdding else { return }
        isAdding = true
        let source = self.source
        let listID = addListID
        Task { [weak self] in
            do {
                try await source.add(parsed, listID: listID)
                guard let self else { return }
                self.isAdding = false
                if self.draft == text { self.draft = "" }
                AppLog.log("Reminders: added one\(parsed.due == nil ? "" : " with a due date")")
                if let due = parsed.due, !ReminderDue.isShown(due: due, showsUndated: self.showsUndated, now: Date(), calendar: .current) {
                    self.show("Added to \(self.addListTitle), due \(ReminderDue.label(due: due, hasTime: parsed.hasTime, now: Date(), calendar: .current))")
                }
                self.refresh()
            } catch {
                guard let self else { return }
                self.isAdding = false
                self.show("Couldn’t add it: \(error.localizedDescription)")
            }
        }
    }

    /// What quick-add will do with the text, for the hint under the field.
    var draftPreview: String? {
        guard let parsed = ReminderQuickAddParser.parse(draft, defaultDue: quickAddDueToday ? Date() : nil) else { return nil }
        guard let due = parsed.due else { return "No date · \(addListTitle)" }
        return "\(ReminderDue.label(due: due, hasTime: parsed.hasTime, now: Date(), calendar: .current)) · \(addListTitle)"
    }

    func openRemindersApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func isShown(_ listID: String) -> Bool { !hiddenListIDs.contains(listID) }

    func binding(for listID: String) -> Binding<Bool> {
        Binding(get: { self.isShown(listID) },
                set: { shown in if shown { self.hiddenListIDs.remove(listID) } else { self.hiddenListIDs.insert(listID) } })
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// Fetches reminders only while this view shows.
private struct RemindersVisibility: ViewModifier {
    let controller: RemindersController

    func body(content: Content) -> some View {
        content
            .onAppear { controller.retain() }
            .onDisappear { controller.release() }
    }
}

extension View {
    @MainActor func remindersVisible(_ controller: RemindersController? = nil) -> some View {
        modifier(RemindersVisibility(controller: controller ?? .shared))
    }
}

// MARK: - Views

/// One reminder: a check circle in its list's color, the title, the due
/// label (red when overdue) and priority marks.
struct ReminderRow: View {
    @ObservedObject var controller: RemindersController = .shared
    let item: ReminderItem
    var now = Date()
    var height: CGFloat = 20
    /// Narrow spots (the small widget): no due label or priority marks.
    var compact = false

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let done = controller.completingIDs.contains(item.id)
        let overdue = item.isOverdue(at: now)
        HStack(spacing: 6) {
            Button { controller.toggle(item) } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.listColor.color.opacity(done ? 0 : 0.95), lineWidth: 1.4)
                    Circle()
                        .fill(item.listColor.color)
                        .scaleEffect(done ? 1 : 0.4)
                        .opacity(done ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .opacity(done ? 1 : 0)
                }
                .frame(width: 13, height: 13)
                .frame(width: 18, height: height)
                .contentShape(Rectangle())
                .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: done)
            }
            .buttonStyle(SparkVPressStyle())
            .help(done ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(done ? "Done: \(item.title)" : "Mark \(item.title) as done")

            if !compact, !item.priorityMarks.isEmpty {
                Text(item.priorityMarks)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red))
                    .fixedSize()
            }
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(done ? SparkVTheme.textTertiary : SparkVTheme.text)
                .strikethrough(done, color: SparkVTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            let label = compact ? "" : item.dueLabel(at: now)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(overdue && !done ? SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red) : SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: height)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0)))
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .opacity(done ? 0.65 : 1)
        .onHover { hover.isOn = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title)\(spokenDue(overdue: overdue))")
        .contextMenu {
            Button(done ? "Mark as Not Done" : "Mark as Done") { controller.toggle(item) }
            Button("Open Reminders") { controller.openRemindersApp() }
        }
    }

    private func spokenDue(overdue: Bool) -> String {
        let due = item.dueLabel(at: now)
        guard !due.isEmpty else { return "" }
        return overdue ? ", overdue, \(due)" : ", due \(due)"
    }
}

/// The quick-add field: type, Return. Dates in the text set the due date.
struct ReminderQuickAddField: View {
    @ObservedObject var controller: RemindersController = .shared
    var placeholder = "Add a reminder… “Call Mom at 5pm”"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: controller.isAdding ? "hourglass" : "plus.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red))
            TextField(placeholder, text: $controller.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.text)
                .onSubmit { controller.addDraft() }
                .accessibilityLabel("New reminder")
            if let preview = controller.draftPreview, !controller.draft.isEmpty {
                Text(preview)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: controller.draft.isEmpty)
        .disabled(controller.access != .granted)
    }
}

/// Connect / Open Settings prompts, or nil when access is granted.
struct RemindersAccessPrompt: View {
    @ObservedObject var controller: RemindersController = .shared
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            Image(systemName: controller.access == .denied ? "checklist.unchecked" : "checklist")
                .font(.system(size: compact ? 13 : 16, weight: .semibold))
                .foregroundStyle(WidgetKind.reminders.tint)
            Text(controller.access == .denied ? "Reminders access is off" : "See what’s due today")
                .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
            Button(controller.access == .denied ? "Open Settings" : (controller.isRequestingAccess ? "Connecting…" : "Connect Reminders")) {
                if controller.access == .denied { controller.openPrivacySettings() } else { controller.requestAccess() }
            }
            .buttonStyle(SparkVPrimaryButtonStyle())
            .controlSize(.small)
            .disabled(controller.isRequestingAccess)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reminders on the widget grid: due today and overdue, with check-off; the
/// large size adds quick add.
struct RemindersWidget: View {
    @ObservedObject var controller: RemindersController = .shared
    var size: WidgetSize = .wide
    var fixedDate: Date? = nil

    var body: some View {
        WidgetCard(padding: size == .large ? 8 : 6) {
            if controller.access != .granted {
                RemindersAccessPrompt(controller: controller, compact: true)
            } else {
                content
            }
        }
        .remindersVisible(controller)
    }

    private var content: some View {
        GeometryReader { geo in
            list(height: geo.size.height)
        }
    }

    /// As many rows as the cell holds (54 pt in the tall drawer, 69 pt in the
    /// short one, 114 pt for large).
    private func list(height: CGFloat) -> some View {
        let now = fixedDate ?? Date()
        let rowHeight: CGFloat = size == .large ? 17 : 15
        let fixed: CGFloat = 11 + (size == .large ? 26 : 0)
        let rows = max(1, Int((height - fixed) / rowHeight))
        let more = controller.items.count - rows
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("REMINDERS")
                    .font(WidgetStyle.label(8.5))
                    .tracking(WidgetStyle.labelTracking)
                    .foregroundStyle(WidgetStyle.secondaryText)
                Spacer(minLength: 2)
                if controller.overdueCount > 0, size != .small {
                    Text("\(controller.overdueCount) late")
                        .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red))
                }
                // Small: the count turns red when some are late.
                Text(more > 0 && size != .small ? "\(controller.dueCount) · +\(more)" : "\(controller.dueCount)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(size == .small && controller.overdueCount > 0 ? SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red) : SparkVTheme.text)
            }
            .frame(height: 11)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reminders: \(controller.dueCount) due, \(controller.overdueCount) overdue")
            if size == .large {
                ReminderQuickAddField(controller: controller, placeholder: "Add a reminder")
                    .padding(.vertical, 2)
            }
            if controller.items.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle").font(.system(size: 10, weight: .semibold))
                    Text("Nothing due today").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(WidgetStyle.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(controller.items.prefix(rows)) { item in
                    ReminderRow(controller: controller, item: item, now: now, height: rowHeight, compact: size == .small)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
