import SwiftUI

/// Something shown briefly (or persistently) by the closed island: a volume
/// level, a charging battery, a countdown, the next meeting, a notification.
/// Feature controllers post these to `ActivityCenter`.
///
/// Like the Dynamic Island, an activity has two presentations:
/// - **compact**: the island grows sideways inside the menu bar, with a
///   leading view left of the camera housing and a trailing view right of it.
///   Nothing below the menu bar is covered. This is the resting form.
/// - **expanded**: the band under the notch (`view`, `height` tall), shown
///   for transient alerts that have no compact form, while an activity is
///   urgent, and for a few seconds when a persistent one first appears (a
///   "peek"). Then the island tucks back into the compact form.
///
/// Activities that don't provide compact views get an automatic one: their
/// `symbol` (or the kind's) on the left and `compactText` (or a small dot) on
/// the right.
struct LiveActivity: Identifiable {
    enum Kind: String {
        case volume, brightness, battery, airPods, timer, meeting, notification

        /// SF Symbol for the automatic compact and minimal forms.
        var symbol: String {
            switch self {
            case .volume: "speaker.wave.2.fill"
            case .brightness: "sun.max.fill"
            case .battery: "battery.100percent.bolt"
            case .airPods: "airpods"
            case .timer: "timer"
            case .meeting: "calendar"
            case .notification: "bell.fill"
            }
        }

        var tint: Color {
            switch self {
            case .volume, .notification: SparkVTheme.text
            case .brightness: SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.text)
            case .battery: SparkVTheme.success
            case .airPods: SparkVTheme.text
            // Apple: the iOS Clock orange for timers, the accent for meetings.
            case .timer: SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red)
            case .meeting: SparkVTheme.accent
            }
        }

        /// Instant feedback for a key press. Never queued behind other
        /// alerts: it runs on the wall clock and a newer one replaces it.
        var isLiveFeedback: Bool { self == .volume || self == .brightness }
    }

    enum Presentation: Equatable {
        /// Transient alerts without compact views use the band; everything
        /// else rests in the wings (persistent ones peek in the band first).
        /// A band taller than one line with no compact form (text to read)
        /// keeps the band for as long as it is posted.
        case automatic
        /// Always the wings, unless `isUrgent` or a `peekKey` change.
        case compact
        /// Always the band (e.g. a two-line answer the user must read).
        case expanded
    }

    /// Stable per source (e.g. "volume", "timer", "meeting.<eventID>").
    /// Posting again with the same id replaces the previous one in place.
    let id: String
    let kind: Kind
    /// Higher wins. Suggested: HUDs 90, notifications 70, meetings 60,
    /// battery/AirPods 50, running timer 20.
    let priority: Int
    /// How long it shows; nil stays until dismissed. Alerts of at most
    /// `NotchMetrics.alertMaxDuration` are queued: the time counts only
    /// while they are on screen.
    let duration: TimeInterval?
    /// When it disappears on its own; nil stays until dismissed.
    let expiresAt: Date?
    /// Band height below the notch (30 for one line, up to 48 for two).
    let height: CGFloat
    /// Hovering the island opens the drawer on this tab, if set (e.g. the
    /// Join button for a meeting lives there).
    let opensTab: NotchState.Tab?
    /// Expanded content: the band, laid out in roughly 360×`height` pt,
    /// dark background.
    let view: () -> AnyView

    var presentation: Presentation = .automatic
    /// Needs attention now (too close to the screen, a meeting starting):
    /// shown expanded for as long as it is posted with this set.
    var isUrgent = false
    /// Symbol and tint of the automatic compact form (default: the kind's).
    var symbol: String?
    var tint: Color?
    /// Short text for the automatic trailing view ("8 min", "45%", "12:04").
    var compactText: String?
    /// Posting with a different key than last time (or a first post with a
    /// key) shows the expanded band for `NotchMetrics.activityPeekDuration`,
    /// e.g. "soon" → "now" for a meeting.
    var peekKey: String?
    /// Custom compact views, about 20 pt tall and at most ~90 pt wide.
    var compactLeading: (() -> AnyView)?
    var compactTrailing: (() -> AnyView)?
    /// Single-icon form, shown next to another activity's compact views.
    var minimal: (() -> AnyView)?

    init(
        id: String,
        kind: Kind,
        priority: Int,
        duration: TimeInterval? = 2.5,
        height: CGFloat = NotchMetrics.activityBandHeight,
        opensTab: NotchState.Tab? = nil,
        presentation: Presentation = .automatic,
        urgent: Bool = false,
        symbol: String? = nil,
        tint: Color? = nil,
        compactText: String? = nil,
        peekKey: String? = nil,
        @ViewBuilder view: @escaping () -> some View
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.duration = duration
        self.expiresAt = duration.map { Date().addingTimeInterval($0) }
        self.height = height
        self.opensTab = opensTab
        self.view = { AnyView(view()) }
        self.presentation = presentation
        self.isUrgent = urgent
        self.symbol = symbol
        self.tint = tint
        self.compactText = compactText
        self.peekKey = peekKey
    }

    /// True when the caller gave the compact form something to say.
    var hasCustomCompact: Bool {
        compactLeading != nil || compactTrailing != nil || compactText != nil
    }

    /// The symbol and tint the automatic compact and minimal forms use.
    var resolvedSymbol: String { symbol ?? kind.symbol }
    var resolvedTint: Color { tint ?? kind.tint }

    // MARK: Builders

    /// Custom compact views beside the camera housing.
    func compact(
        @ViewBuilder leading: @escaping () -> some View,
        @ViewBuilder trailing: @escaping () -> some View
    ) -> LiveActivity {
        var copy = self
        copy.compactLeading = { AnyView(leading()) }
        copy.compactTrailing = { AnyView(trailing()) }
        return copy
    }

    func minimal(@ViewBuilder _ content: @escaping () -> some View) -> LiveActivity {
        var copy = self
        copy.minimal = { AnyView(content()) }
        return copy
    }

    func presentation(_ presentation: Presentation) -> LiveActivity {
        var copy = self
        copy.presentation = presentation
        return copy
    }

    func urgent(_ isUrgent: Bool = true) -> LiveActivity {
        var copy = self
        copy.isUrgent = isUrgent
        return copy
    }

    func peeking(on key: String?) -> LiveActivity {
        var copy = self
        copy.peekKey = key
        return copy
    }
}

/// Measured widths of the compact content beside the camera housing,
/// without padding.
struct IslandWings: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
    static let zero = IslandWings(leading: 0, trailing: 0)
}

/// Collects live activities from every feature and decides what the closed
/// island shows: one activity in the band (expanded) and one in the wings
/// (compact). Transient alerts wait their turn by priority instead of
/// overriding each other; persistent activities stay in the wings while an
/// alert plays in the band.
@MainActor
final class ActivityCenter: ObservableObject {
    /// The activity in the band under the notch (expanded), or nil.
    @Published private(set) var current: LiveActivity?
    /// The activity in the wings beside the camera housing (compact), or nil.
    @Published private(set) var compact: LiveActivity?
    /// Another persistent activity, shown in its minimal form after the
    /// compact one's trailing view.
    @Published private(set) var secondary: LiveActivity?
    /// Bumped on every post so views re-render when an activity updates in place.
    @Published private(set) var revision = 0
    /// Content widths the island measured for the current wings.
    @Published private(set) var measuredWings = IslandWings.zero

    /// Transient alerts waiting for their turn (not counting the one showing).
    var queuedAlertIDs: [String] {
        let head = headAlertID
        return entries.values
            .filter { $0.isTransient && $0.id != head }
            .sorted { $0.firstOrder < $1.firstOrder }
            .map(\.id)
    }

    /// Ids of every live activity, for tests and diagnostics.
    var activeIDs: Set<String> { Set(entries.keys) }

    private struct Entry {
        var activity: LiveActivity
        /// Order of the latest post (newest wins among equal persistent ones).
        var order: Int
        /// Order of the first post (queue position among equal alerts).
        var firstOrder: Int
        var lastPosted: Date
        var isTransient: Bool
        /// Transient: display time left.
        var remaining: TimeInterval
        /// Transient: when it started showing this turn.
        var shownSince: Date?
        /// Wall-clock expiry (persistent with a duration, and live feedback).
        var expiresAt: Date?
        var peekUntil: Date?

        var id: String { activity.id }
        var priority: Int { activity.priority }
        var usesWallClock: Bool { !isTransient || activity.kind.isLiveFeedback }
    }

    private var entries: [String: Entry] = [:]
    private var postCounter = 0
    private var headAlertID: String?
    private var wakeTask: Task<Void, Never>?
    private var isDrawerOpen = false
    private var isBandHeld = false
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: Posting

    func post(_ activity: LiveActivity) {
        let now = clock()
        postCounter &+= 1
        let transient = activity.duration.map { $0 <= NotchMetrics.alertMaxDuration } ?? false
        let wallExpiry = activity.duration.map { now.addingTimeInterval($0) }

        if var entry = entries[activity.id] {
            let oldKey = entry.activity.peekKey
            let wasShowing = entry.shownSince != nil
            entry.activity = activity
            entry.order = postCounter
            entry.lastPosted = now
            entry.isTransient = transient
            entry.remaining = activity.duration ?? 0
            // Coalesced in place: an alert on screen keeps its turn and
            // restarts its time; a waiting one keeps its place in line.
            entry.shownSince = transient && wasShowing ? now : nil
            entry.expiresAt = transient && !activity.kind.isLiveFeedback ? nil : wallExpiry
            if let key = activity.peekKey, key != oldKey {
                entry.peekUntil = now.addingTimeInterval(NotchMetrics.activityPeekDuration)
            }
            entries[activity.id] = entry
        } else {
            var entry = Entry(
                activity: activity, order: postCounter, firstOrder: postCounter, lastPosted: now,
                isTransient: transient, remaining: activity.duration ?? 0, shownSince: nil,
                expiresAt: transient && !activity.kind.isLiveFeedback ? nil : wallExpiry, peekUntil: nil
            )
            // A persistent activity introduces itself in the band, then
            // tucks into the wings, unless it has a compact form already.
            if !transient, activity.peekKey != nil
                || (activity.presentation == .automatic && !activity.hasCustomCompact) {
                entry.peekUntil = now.addingTimeInterval(NotchMetrics.activityPeekDuration)
            }
            entries[activity.id] = entry
        }
        revision &+= 1
        recompute()
    }

    func dismiss(id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        revision &+= 1
        recompute()
    }

    func dismissAll(kind: LiveActivity.Kind) {
        let before = entries.count
        entries = entries.filter { $0.value.activity.kind != kind }
        guard entries.count != before else { return }
        revision &+= 1
        recompute()
    }

    /// Shows a persistent activity expanded for a while (default
    /// `NotchMetrics.activityPeekDuration`), then back to compact.
    func peek(id: String, for duration: TimeInterval = NotchMetrics.activityPeekDuration) {
        guard var entry = entries[id] else { return }
        entry.peekUntil = clock().addingTimeInterval(duration)
        entries[id] = entry
        recompute()
    }

    /// Re-evaluates expiries, peeks and the queue now (they also run on
    /// their own timers).
    func refresh() {
        recompute()
    }

    // MARK: Island state

    /// While the drawer is open nothing shows, so queued alerts don't
    /// spend their time unseen.
    func setDrawerOpen(_ open: Bool) {
        guard isDrawerOpen != open else { return }
        isDrawerOpen = open
        recompute()
    }

    /// Dictation or Clicky is using the band: alerts that wanted it show
    /// compact in the wings instead.
    func setBandHeld(_ held: Bool) {
        guard isBandHeld != held else { return }
        isBandHeld = held
        recompute()
    }

    func reportWings(_ wings: IslandWings) {
        guard abs(wings.leading - measuredWings.leading) > 0.5
            || abs(wings.trailing - measuredWings.trailing) > 0.5
        else { return }
        measuredWings = wings
    }

    // MARK: Resolution

    private func wantsBand(_ entry: Entry, now: Date) -> Bool {
        let activity = entry.activity
        if activity.presentation == .expanded || activity.isUrgent { return true }
        if let until = entry.peekUntil, until > now { return true }
        // A taller-than-one-line band without a compact form is text to read
        // (a suggested meeting answer, live captions): a symbol and a dot
        // would hide it, so it keeps the band. `.compact` opts out.
        if activity.presentation == .automatic, !activity.hasCustomCompact,
           activity.height > NotchMetrics.activityBandHeight + 0.5 {
            return true
        }
        if entry.isTransient { return activity.presentation == .automatic && !activity.hasCustomCompact }
        return false
    }

    private func prune(now: Date) {
        entries = entries.filter { _, entry in
            if let expiry = entry.expiresAt, expiry <= now { return false }
            guard entry.isTransient, !entry.activity.kind.isLiveFeedback else { return true }
            if let since = entry.shownSince {
                return since.addingTimeInterval(entry.remaining) > now
            }
            // Stale: an alert that waited this long is old news.
            return now.timeIntervalSince(entry.lastPosted) < NotchMetrics.alertQueueMaxWait
                && entry.remaining > 0.05
        }
    }

    /// Highest priority; among equals the one on screen keeps its turn, then
    /// first come first served, except key-press feedback where newest wins.
    private func headAlert() -> Entry? {
        entries.values.filter(\.isTransient).max { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return tieRank(lhs) < tieRank(rhs)
        }
    }

    private func tieRank(_ entry: Entry) -> Double {
        // Key-press feedback: the newest is the one that matters.
        if entry.activity.kind.isLiveFeedback { return Double(entry.order) }
        if entry.shownSince != nil || entry.id == headAlertID { return .infinity }
        return -Double(entry.firstOrder)
    }

    private func recompute() {
        let now = clock()
        var band: Entry?
        var wings: Entry?
        var second: Entry?
        var alertShown = false

        for _ in 0..<4 {
            prune(now: now)
            band = nil
            wings = nil
            second = nil
            alertShown = false

            let lives = entries.values.filter { !$0.isTransient }.sorted { lhs, rhs in
                lhs.priority == rhs.priority ? lhs.order > rhs.order : lhs.priority > rhs.priority
            }
            let live = lives.first
            let alert = headAlert()

            if !isDrawerOpen {
                let liveWantsBand = live.map { wantsBand($0, now: now) } ?? false
                if let alert {
                    let liveOutranks = live.map { liveWantsBand && $0.priority > alert.priority } ?? false
                    if wantsBand(alert, now: now), !isBandHeld, !liveOutranks {
                        band = alert
                    } else {
                        // No room in the band: the alert still shows, compact.
                        wings = alert
                    }
                    alertShown = true
                }
                if let live {
                    if liveWantsBand, !isBandHeld, band == nil {
                        band = live
                    } else if wings == nil {
                        wings = live
                    }
                }
                // While the top one peeks in the band, the next one keeps
                // the wings (e.g. a running timer while a meeting announces itself).
                if wings == nil, let next = lives.first(where: { $0.id != band?.id }) {
                    wings = next
                }
                // A second persistent activity rides along in minimal form.
                if let wingID = wings?.id, wings?.isTransient == false {
                    second = lives.first { $0.id != wingID && $0.id != band?.id }
                }
            }

            // Start or pause the alerts' clocks.
            let shownID = alertShown ? alert?.id : nil
            headAlertID = alert?.id
            var dropped = false
            for (id, var entry) in entries where entry.isTransient && !entry.activity.kind.isLiveFeedback {
                if id == shownID {
                    if entry.shownSince == nil { entry.shownSince = now }
                } else if let since = entry.shownSince {
                    entry.remaining -= now.timeIntervalSince(since)
                    entry.shownSince = nil
                    // Not worth bringing back for a blink.
                    if entry.remaining < NotchMetrics.alertMinResume {
                        entries.removeValue(forKey: id)
                        dropped = true
                        continue
                    }
                } else {
                    continue
                }
                entries[id] = entry
            }
            if !dropped { break }
        }

        current = band?.activity
        compact = wings?.activity
        secondary = second?.activity
        scheduleWake(now: now)
    }

    private func scheduleWake(now: Date) {
        wakeTask?.cancel()
        wakeTask = nil
        var deadlines: [Date] = []
        for entry in entries.values {
            if let expiry = entry.expiresAt { deadlines.append(expiry) }
            if let until = entry.peekUntil, until > now { deadlines.append(until) }
            if entry.isTransient, !entry.activity.kind.isLiveFeedback {
                if let since = entry.shownSince {
                    deadlines.append(since.addingTimeInterval(entry.remaining))
                } else {
                    deadlines.append(entry.lastPosted.addingTimeInterval(NotchMetrics.alertQueueMaxWait))
                }
            }
        }
        guard let next = deadlines.min() else { return }
        let delay = max(0.05, next.timeIntervalSince(now))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }
}
