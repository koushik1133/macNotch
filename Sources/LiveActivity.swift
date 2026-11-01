import AppKit
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
    enum Kind: String, CaseIterable {
        case volume, brightness, battery, airPods, timer, meeting, notification, call, media

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
            case .call: "phone.fill"
            case .media: "music.note"
            }
        }

        var tint: Color {
            switch self {
            case .volume, .notification, .media: SparkVTheme.text
            case .brightness: SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.text)
            case .battery: SparkVTheme.success
            case .airPods: SparkVTheme.text
            // Apple: the iOS Clock orange for timers, the accent for meetings.
            case .timer: SparkVTheme.choose(apple: Color.orange, sparkv: SparkVTheme.red)
            case .meeting: SparkVTheme.accent
            // Calls are green in both looks, as on iPhone.
            case .call: SparkVTheme.success
            }
        }

        /// Name for menus, lists and VoiceOver ("Timer", "Now Playing").
        var displayName: String {
            switch self {
            case .volume: "Volume"
            case .brightness: "Brightness"
            case .battery: "Battery"
            case .airPods: "AirPods"
            case .timer: "Timer"
            case .meeting: "Meeting"
            case .notification: "Notification"
            case .call: "Call"
            case .media: "Now Playing"
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
    /// Higher wins. Suggested: incoming call 95, HUDs 90, notifications 70,
    /// meetings 60, battery/AirPods 50, ongoing call 30, running timer 20,
    /// now playing 5.
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
    /// key) shows the expanded band for the peek time (Settings › Activities
    /// › Timing, 4 s by default), e.g. "soon" → "now" for a meeting.
    var peekKey: String?
    /// Custom compact views, about 20 pt tall and at most ~90 pt wide.
    var compactLeading: (() -> AnyView)?
    var compactTrailing: (() -> AnyView)?
    /// Single-icon form, shown next to another activity's compact views.
    var minimal: (() -> AnyView)?

    /// Short human name for the Live Activities list, the gear menu's
    /// "Show in Wings" picker and VoiceOver ("Timer 18:42", "Zoom call").
    /// Default: the kind's name.
    var title: String?
    /// The band has buttons: while the pointer is on it the panel takes
    /// clicks, and hovering it never opens the drawer (`opensTab` is
    /// ignored for the band, not for the wings).
    var isInteractive = false
    /// What VoiceOver reads for the closed island while this activity shows
    /// (band and wings read as one element). Never put hidden text here.
    var accessibilityText: String?
    /// Spoken to VoiceOver when the activity first appears or its `peekKey`
    /// changes (rate limited; see `ActivityAnnouncer`).
    var announcement: ActivityAnnouncement?

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
    /// `title`, else the kind's name plus the compact text ("Timer 12:04").
    var resolvedTitle: String {
        if let title, !title.isEmpty { return title }
        if let compactText, !compactText.isEmpty { return "\(kind.displayName) \(compactText)" }
        return kind.displayName
    }
    /// `accessibilityText`, else `resolvedTitle`.
    var resolvedAccessibilityText: String { accessibilityText ?? resolvedTitle }

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

    func titled(_ title: String?) -> LiveActivity {
        var copy = self
        copy.title = title
        return copy
    }

    /// The band takes clicks (buttons) while the pointer is on it.
    func interactive(_ isInteractive: Bool = true) -> LiveActivity {
        var copy = self
        copy.isInteractive = isInteractive
        return copy
    }

    /// What VoiceOver reads for the island while this activity shows.
    func accessibility(_ text: String?) -> LiveActivity {
        var copy = self
        copy.accessibilityText = text
        return copy
    }

    /// Spoken to VoiceOver when the activity appears or re-peeks, if the
    /// user keeps announcements of `category` on. `important` asks
    /// VoiceOver to speak it even while SparkV isn't the front app.
    func announcing(_ text: String?, as category: ActivityAnnouncement.Category, important: Bool = false) -> LiveActivity {
        var copy = self
        copy.announcement = text.map { ActivityAnnouncement(text: $0, category: category, isImportant: important) }
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

/// One running (persistent) activity, for lists and pickers.
struct LiveActivitySummary: Identifiable, Equatable {
    let id: String
    let kind: LiveActivity.Kind
    let title: String
    let symbol: String
    let priority: Int
    let opensTab: NotchState.Tab?
}

/// User timing the center reads (Settings › Activities). Closures so tests
/// can pin them.
struct ActivityCenterTiming {
    /// How long a persistent activity peeks in the band.
    var peekSeconds: @MainActor () -> TimeInterval
    /// Alerts in the band wait while the pointer is on them.
    var pausesOnHover: @MainActor () -> Bool
    /// Longest wait for a hovered alert, so a parked pointer can't freeze
    /// the queue.
    var hoverCap: TimeInterval
    /// Activities visible at once in the wings: 2 (compact + one minimal)
    /// or 3 (compact + a minimal on each side).
    var visibleLimit: @MainActor () -> Int

    /// Values from `ActivityTimingSettings` / `LiveActivitiesSettings`.
    static var live: ActivityCenterTiming {
        ActivityCenterTiming(
            peekSeconds: { ActivityTimingSettings.shared.peekSeconds },
            pausesOnHover: { ActivityTimingSettings.shared.pausesOnHover },
            hoverCap: ActivityTimingSettings.hoverHoldCap,
            visibleLimit: { LiveActivitiesSettings.shared.maxVisible }
        )
    }

    /// The built-in defaults, for tests.
    static var standard: ActivityCenterTiming {
        ActivityCenterTiming(
            peekSeconds: { NotchMetrics.activityPeekDuration },
            pausesOnHover: { true },
            hoverCap: 30,
            visibleLimit: { 3 }
        )
    }
}

/// Collects live activities from every feature and decides what the closed
/// island shows: one activity in the band (expanded), one in the wings
/// (compact) and up to two more as minimal icons beside it. Transient
/// alerts wait their turn by priority instead of overriding each other;
/// persistent activities stay in the wings while an alert plays in the band.
/// The user can pin which running activity rests in the wings
/// (`cycleCompact()`, `pin(id:)`).
@MainActor
final class ActivityCenter: ObservableObject {
    /// The activity in the band under the notch (expanded), or nil.
    @Published private(set) var current: LiveActivity?
    /// The activity in the wings beside the camera housing (compact), or nil.
    @Published private(set) var compact: LiveActivity?
    /// Another persistent activity, shown in its minimal form after the
    /// compact one's trailing view.
    @Published private(set) var secondary: LiveActivity?
    /// A third persistent activity, shown in its minimal form before the
    /// compact one's leading view (when the user allows three at once).
    @Published private(set) var tertiary: LiveActivity?
    /// Bumped on every post so views re-render when an activity updates in place.
    @Published private(set) var revision = 0
    /// Bumped only when the band's own activity is posted again or another
    /// one takes the band, so a band with buttons keeps its hover and press
    /// state while unrelated activities update.
    @Published private(set) var bandRevision = 0
    /// Content widths the island measured for the current wings.
    @Published private(set) var measuredWings = IslandWings.zero
    /// The running activity the user picked for the wings, if any. Cleared
    /// when it ends.
    @Published private(set) var pinnedCompactID: String?
    /// Every persistent activity, highest priority first.
    @Published private(set) var running: [LiveActivitySummary] = []

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

    /// The live activity with `id`, if posted.
    func activity(id: String) -> LiveActivity? { entries[id]?.activity }

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
    /// When the pointer came onto the band (nil while it isn't there).
    private var hoverStartedAt: Date?
    /// The alert kept on screen by the hover last time round.
    private var heldAlertID: String?
    /// The band's activity last time round.
    private var bandID: String?
    private let clock: () -> Date
    private let timing: ActivityCenterTiming
    private let announcer: ActivityAnnouncer

    init(clock: @escaping () -> Date = { Date() }, timing: ActivityCenterTiming? = nil, announcer: ActivityAnnouncer? = nil) {
        self.clock = clock
        self.timing = timing ?? .live
        self.announcer = announcer ?? .shared
    }

    // MARK: Posting

    func post(_ activity: LiveActivity) {
        let now = clock()
        postCounter &+= 1
        let transient = activity.duration.map { $0 <= NotchMetrics.alertMaxDuration } ?? false
        let wallExpiry = activity.duration.map { now.addingTimeInterval($0) }
        let peekTime = timing.peekSeconds()
        let isNew: Bool
        var peekKeyChanged = false

        if var entry = entries[activity.id] {
            isNew = false
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
                entry.peekUntil = now.addingTimeInterval(peekTime)
                peekKeyChanged = true
            }
            entries[activity.id] = entry
        } else {
            isNew = true
            var entry = Entry(
                activity: activity, order: postCounter, firstOrder: postCounter, lastPosted: now,
                isTransient: transient, remaining: activity.duration ?? 0, shownSince: nil,
                expiresAt: transient && !activity.kind.isLiveFeedback ? nil : wallExpiry, peekUntil: nil
            )
            // A persistent activity introduces itself in the band, then
            // tucks into the wings, unless it has a compact form already.
            if !transient, activity.peekKey != nil
                || (activity.presentation == .automatic && !activity.hasCustomCompact) {
                entry.peekUntil = now.addingTimeInterval(peekTime)
            }
            entries[activity.id] = entry
        }
        revision &+= 1
        if activity.id == bandID { bandRevision &+= 1 }
        recompute()
        announcer.consider(activity, isNew: isNew, peekKeyChanged: peekKeyChanged)
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

    /// Shows a persistent activity expanded for a while (default: the
    /// user's peek time), then back to compact.
    func peek(id: String, for duration: TimeInterval? = nil) {
        guard var entry = entries[id] else { return }
        entry.peekUntil = clock().addingTimeInterval(duration ?? timing.peekSeconds())
        entries[id] = entry
        recompute()
    }

    /// Re-evaluates expiries, peeks and the queue now (they also run on
    /// their own timers).
    func refresh() {
        recompute()
    }

    // MARK: Choosing what rests in the wings

    /// Rests `id` (a running persistent activity) in the wings until it
    /// ends; nil goes back to priority order.
    func pin(id: String?) {
        let target = id.flatMap { entries[$0] }.flatMap { $0.isTransient ? nil : $0.id }
        guard target != pinnedCompactID else { return }
        pinnedCompactID = target
        recompute()
    }

    /// Shows the next running activity in the wings (priority order, then
    /// back to automatic). Returns the activity now in the wings.
    @discardableResult
    func cycleCompact() -> LiveActivity? {
        let order = running.map(\.id)
        guard order.count > 1 else { return compact }
        let shown = compact.flatMap { c in order.contains(c.id) ? c.id : nil } ?? order[0]
        let index = order.firstIndex(of: shown) ?? 0
        let next = order[(index + 1) % order.count]
        pinnedCompactID = next == order[0] ? nil : next
        recompute()
        if let compact {
            announcer.announce("Showing \(compact.resolvedTitle)", id: "activities.cycle", category: .general)
        }
        return compact
    }

    // MARK: Island state

    /// While the drawer is open nothing shows, so queued alerts don't
    /// spend their time unseen.
    func setDrawerOpen(_ open: Bool) {
        guard isDrawerOpen != open else { return }
        isDrawerOpen = open
        if open { hoverStartedAt = nil }
        recompute()
    }

    /// Dictation or Clicky is using the band: alerts that wanted it show
    /// compact in the wings instead.
    func setBandHeld(_ held: Bool) {
        guard isBandHeld != held else { return }
        isBandHeld = held
        recompute()
    }

    /// The pointer is on the band under the notch: the alert there (and a
    /// peek) waits until it leaves, at most `hoverCap`.
    func setHovered(_ hovered: Bool) {
        if hovered {
            guard hoverStartedAt == nil else { return }
            hoverStartedAt = clock()
        } else {
            guard hoverStartedAt != nil else { return }
            hoverStartedAt = nil
            // A peek that ran out under the pointer lingers a moment.
            if let id = bandID, var entry = entries[id], !entry.isTransient, let until = entry.peekUntil {
                entry.peekUntil = max(until, clock().addingTimeInterval(1))
                entries[id] = entry
            }
        }
        recompute()
    }

    /// True while a hovered band holds its clock.
    var isHoldingForHover: Bool { isHolding(now: clock()) }

    func reportWings(_ wings: IslandWings) {
        guard abs(wings.leading - measuredWings.leading) > 0.5
            || abs(wings.trailing - measuredWings.trailing) > 0.5
        else { return }
        measuredWings = wings
    }

    // MARK: Resolution

    private func isHolding(now: Date) -> Bool {
        guard let since = hoverStartedAt, !isDrawerOpen, timing.pausesOnHover() else { return false }
        return now.timeIntervalSince(since) < timing.hoverCap
    }

    private func wantsBand(_ entry: Entry, now: Date, holding: Bool) -> Bool {
        let activity = entry.activity
        if activity.presentation == .expanded || activity.isUrgent { return true }
        if let until = entry.peekUntil, until > now { return true }
        // A peek under the pointer stays until the pointer leaves.
        if holding, entry.id == bandID, entry.peekUntil != nil { return true }
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

    private func prune(now: Date, holding: Bool) {
        let held = holding ? heldAlertID : nil
        entries = entries.filter { _, entry in
            if let expiry = entry.expiresAt, expiry <= now { return false }
            guard entry.isTransient, !entry.activity.kind.isLiveFeedback else { return true }
            if let since = entry.shownSince {
                return since.addingTimeInterval(entry.remaining) > now
            }
            // On screen with its clock held by the pointer.
            if entry.id == held { return true }
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
        let holding = isHolding(now: now)
        var band: Entry?
        var wings: Entry?
        var second: Entry?
        var third: Entry?
        var alertShown = false
        var lives: [Entry] = []

        // The pointer left (or the cap passed): the held alert's clock runs
        // again with the time it had left.
        if !holding, let held = heldAlertID {
            if var entry = entries[held], entry.shownSince == nil {
                entry.shownSince = now
                entries[held] = entry
            }
            heldAlertID = nil
        }

        for _ in 0..<4 {
            prune(now: now, holding: holding)
            band = nil
            wings = nil
            second = nil
            third = nil
            alertShown = false

            lives = entries.values.filter { !$0.isTransient }.sorted { lhs, rhs in
                lhs.priority == rhs.priority ? lhs.order > rhs.order : lhs.priority > rhs.priority
            }
            if let pinned = pinnedCompactID, !lives.contains(where: { $0.id == pinned }) {
                pinnedCompactID = nil
            }
            let alert = headAlert()

            if !isDrawerOpen {
                // The highest-priority persistent activity that wants the
                // band (urgent, expanded, peeking) gets it, even when a
                // higher one rests in the wings.
                let bandLive = lives.first { wantsBand($0, now: now, holding: holding) }
                if let alert {
                    let liveOutranks = bandLive.map { $0.priority > alert.priority } ?? false
                    if wantsBand(alert, now: now, holding: holding), !isBandHeld, !liveOutranks {
                        band = alert
                    } else {
                        // No room in the band: the alert still shows, compact.
                        wings = alert
                    }
                    alertShown = true
                }
                if let bandLive, !isBandHeld, band == nil {
                    band = bandLive
                }
                // The wings: the user's pick, else the top running activity
                // not in the band (e.g. a running timer while a meeting
                // announces itself).
                if wings == nil {
                    let pinned = pinnedCompactID.flatMap { id in lives.first { $0.id == id && $0.id != band?.id } }
                    wings = pinned ?? lives.first { $0.id != band?.id }
                }
                // More running activities ride along in minimal form.
                if let wingID = wings?.id, wings?.isTransient == false {
                    let others = lives.filter { $0.id != wingID && $0.id != band?.id }
                    second = others.first
                    if timing.visibleLimit() >= 3, others.count > 1 { third = others[1] }
                }
            }

            // Start or pause the alerts' clocks. A band under the pointer
            // keeps its alert on screen with the clock stopped.
            let shownID = alertShown ? alert?.id : nil
            let holdsShown = holding && shownID != nil && shownID == band?.id
            headAlertID = alert?.id
            var dropped = false
            for (id, var entry) in entries where entry.isTransient && !entry.activity.kind.isLiveFeedback {
                if id == shownID, !holdsShown {
                    if entry.shownSince == nil { entry.shownSince = now }
                } else if let since = entry.shownSince {
                    entry.remaining -= now.timeIntervalSince(since)
                    entry.shownSince = nil
                    if id == shownID {
                        // Held by the pointer: give it a moment once it leaves.
                        entry.remaining = max(entry.remaining, NotchMetrics.alertMinResume + 0.4)
                    } else if entry.remaining < NotchMetrics.alertMinResume {
                        // Not worth bringing back for a blink.
                        entries.removeValue(forKey: id)
                        dropped = true
                        continue
                    }
                } else {
                    continue
                }
                entries[id] = entry
            }
            heldAlertID = holdsShown ? shownID : nil
            if !dropped { break }
        }

        let newBandID = band?.id
        if newBandID != bandID {
            bandID = newBandID
            bandRevision &+= 1
        }
        current = band?.activity
        compact = wings?.activity
        secondary = second?.activity
        tertiary = third?.activity
        let summaries = lives.map {
            LiveActivitySummary(id: $0.id, kind: $0.activity.kind, title: $0.activity.resolvedTitle,
                                symbol: $0.activity.resolvedSymbol, priority: $0.priority, opensTab: $0.activity.opensTab)
        }
        if summaries != running { running = summaries }
        scheduleWake(now: now, holding: holding)
    }

    private func scheduleWake(now: Date, holding: Bool) {
        wakeTask?.cancel()
        wakeTask = nil
        var deadlines: [Date] = []
        for entry in entries.values {
            if let expiry = entry.expiresAt { deadlines.append(expiry) }
            if let until = entry.peekUntil, until > now { deadlines.append(until) }
            if entry.isTransient, !entry.activity.kind.isLiveFeedback {
                if let since = entry.shownSince {
                    deadlines.append(since.addingTimeInterval(entry.remaining))
                } else if entry.id != heldAlertID {
                    deadlines.append(entry.lastPosted.addingTimeInterval(NotchMetrics.alertQueueMaxWait))
                }
            }
        }
        // A parked pointer stops holding after the cap.
        if holding, let since = hoverStartedAt { deadlines.append(since.addingTimeInterval(timing.hoverCap)) }
        guard let next = deadlines.min() else { return }
        let delay = max(0.05, next.timeIntervalSince(now))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }
}

// MARK: - Motion helpers for bands, overlays and their panels

/// Small helpers on top of `SparkVMotion` for the live bands and the
/// floating panels they open (AppKit windows can't take a SwiftUI curve).
enum LiveBandMotion {
    /// `SparkVMotion.easeOut`'s curve, cubic-bezier(0.23, 1, 0.32, 1), for AppKit.
    static var easeOutTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    }

    /// Fades a panel (ordered front at alpha 0, or mid fade-out) to full
    /// opacity with a strong ease-out, rising `rise` points into place
    /// (Reduce Motion: fade only).
    @MainActor
    static func fadeIn(_ window: NSWindow, duration: Double = SparkVMotion.Duration.small, rise: CGFloat = 0) {
        let target = window.frame
        let lift = SparkVMotion.reduceMotion ? 0 : rise
        if lift != 0 { window.setFrame(target.offsetBy(dx: 0, dy: -lift), display: false) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = easeOutTiming
            window.animator().alphaValue = 1
            if lift != 0 { window.animator().setFrame(target, display: true) }
        }
    }

    /// Fades a panel out (ease-out, a touch faster than it came in), then
    /// orders it out and restores its alpha, unless it was shown again
    /// meanwhile (a fade-in set its alpha back to 1).
    @MainActor
    static func fadeOut(_ window: NSWindow, duration: Double = SparkVMotion.Duration.hover, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = easeOutTiming
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard window.alphaValue < 0.01 else { return }
                window.orderOut(nil)
                window.alphaValue = 1
                completion?()
            }
        })
    }
}

/// Press feedback for custom `ButtonStyle`s that draw their own fill:
/// 0.97 on press (100 ms), back a little slower (160 ms), no scale with
/// Reduce Motion. Same feel as `SparkVPressStyle`.
struct LiveBandPressEffect: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !SparkVMotion.reduceMotion ? SparkVMotion.pressedScale : 1)
            .animation(
                SparkVMotion.easeOut(isPressed ? SparkVMotion.Duration.press : SparkVMotion.Duration.release),
                value: isPressed
            )
    }
}
