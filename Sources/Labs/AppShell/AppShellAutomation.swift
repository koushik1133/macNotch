import AppKit
import SwiftUI

/// What the island side of SparkV does for automation commands. Set by
/// NotchWindowController (INTEGRATION.md); a command whose action is nil
/// reports "not available".
struct AutomationActions {
    var startTimer: ((Int) -> Void)?
    var startPomodoro: (() -> Void)?
    var pauseTimer: (() -> Void)?
    var resetTimer: (() -> Void)?
    var startFocus: ((Int?) -> Void)?
    var endFocus: (() -> Void)?
    var openMeeting: ((UUID) -> Void)?
    /// The color picker lab (another package) plugs in here.
    var pickColor: (() -> Void)?
}

/// A switch other tools may flip with sparkv://feature/<name>?on=1.
/// Only harmless, visible features belong here: never the camera, the
/// microphone, recording, dictation or anything that runs a script.
struct AutomationFeature {
    let name: String
    let title: String
    /// False for switches that send data off the Mac (update checks) or
    /// show other apps' content (notifications): a link may turn them off,
    /// never on. Only the user turns them on, in Settings.
    var allowsTurningOn = true
    let get: @MainActor () -> Bool
    let set: @MainActor (Bool) -> Void

    init(name: String, title: String, allowsTurningOn: Bool = true,
         get: @escaping @MainActor () -> Bool, set: @escaping @MainActor (Bool) -> Void) {
        self.name = name
        self.title = title
        self.allowsTurningOn = allowsTurningOn
        self.get = get
        self.set = set
    }
}

/// Runs sparkv:// links from Shortcuts ("Open URLs"), Terminal
/// (`open -g "sparkv://…"`), scripts and other apps.
///
/// Safety: any web page can open a sparkv:// link, so
/// - links that only open a window (Settings, About, a meeting's notes)
///   always work;
/// - everything that changes something or shows text on the island needs
///   Automation turned on in Settings › Advanced (off by default);
/// - nothing a link can do starts the camera, the microphone, a recording,
///   dictation, a shortcut or a script;
/// - text is cleaned and capped, ids are namespaced ("ext."), external
///   activities rank below meetings, recordings and system HUDs, and a
///   rate limit stops floods.
@MainActor
final class AutomationRouter: ObservableObject {
    static let shared = AutomationRouter()
    static let enabledKey = "AppShell.automation.enabled"
    /// Priority of activities posted by other tools (meetings 60,
    /// notifications 70, HUDs 90).
    static let externalPriority = 40

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let summary: String
        let outcome: String
        let ok: Bool
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            AppLog.log("Automation: \(isEnabled ? "on" : "off")")
        }
    }

    /// The last few commands, newest first (Settings › Advanced shows them).
    @Published private(set) var recent: [LogEntry] = []

    var actions = AutomationActions()
    private(set) var features: [String: AutomationFeature] = [:]

    private var ready = false
    private var pending: [URL] = []
    private var limiter = AutomationRateLimiter()
    /// Requests deferred by the rate limiter, newest per key, and the task
    /// that delivers each one at the end of its interval.
    private var deferred: [String: AutomationCommand] = [:]
    private var deferredTasks: [String: Task<Void, Never>] = [:]
    private var lastBlockedNotice: Date?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        registerBuiltInFeatures()
    }

    func register(_ feature: AutomationFeature) {
        features[feature.name] = feature
    }

    /// Links that arrived during launch run once the island is connected.
    func start() {
        ready = true
        let queued = pending
        pending.removeAll()
        if !queued.isEmpty { handle(queued) }
    }

    func stop() {
        ready = false
        for task in deferredTasks.values { task.cancel() }
        deferredTasks.removeAll()
        deferred.removeAll()
    }

    func handle(_ urls: [URL]) {
        guard ready else {
            pending.append(contentsOf: urls.prefix(10))
            return
        }
        for url in urls.prefix(10) { handle(url) }
    }

    private func handle(_ url: URL) {
        switch AutomationURL.parse(url) {
        case .failure(let error):
            note(url.host ?? url.absoluteString.prefix(40).description, outcome: error.message, ok: false)
        case .success(let command):
            if command.requiresAutomationEnabled, !isEnabled {
                note(command.summary, outcome: "Blocked: Automation is off", ok: false)
                showBlockedNotice(command)
                return
            }
            let key = rateKey(command)
            switch limiter.decide(key, now: Date(), exempt: isExempt(command)) {
            case .drop:
                note(command.summary, outcome: "Ignored: too many requests", ok: false)
            case .now:
                deferred[key] = nil
                execute(command)
            case .later(let date):
                deferCommand(command, key: key, until: date)
            }
        }
    }

    private func execute(_ command: AutomationCommand) {
        let outcome = run(command, fromLink: true)
        note(command.summary, outcome: outcome.message, ok: outcome.ok)
    }

    /// Coalesces: the newest request for a key replaces an older deferred
    /// one and is delivered once the key's interval has passed.
    private func deferCommand(_ command: AutomationCommand, key: String, until date: Date) {
        deferred[key] = command
        guard deferredTasks[key] == nil else { return }
        let delay = max(0, date.timeIntervalSinceNow)
        deferredTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 5))
            guard !Task.isCancelled, let self else { return }
            self.deferredTasks[key] = nil
            guard self.ready, let command = self.deferred.removeValue(forKey: key) else { return }
            self.limiter.noteDelivered(key, at: Date())
            self.execute(command)
        }
    }

    /// Removing something never spends the budget, so it can't be dropped.
    private func isExempt(_ command: AutomationCommand) -> Bool {
        switch command {
        case .dismissActivity, .closeDrawer, .endFocus: true
        case .setFeature(_, let on): on == false
        default: false
        }
    }

    /// Runs a command. The Automation Guide's Try buttons call this
    /// directly (`fromLink` false: the user clicked), so they work while
    /// Automation is off and may reveal a hidden island.
    @discardableResult
    func run(_ command: AutomationCommand, fromLink: Bool = false) -> (ok: Bool, message: String) {
        let shell = AppShellController.shared
        func unavailable(_ what: String) -> (Bool, String) { (false, "\(what) isn’t available in this build") }
        switch command {
        case .openSettings(let pane):
            SparkVSettings.show(SparkVSettingsPane(slug: pane))
            return (true, "Opened Settings")
        case .openDrawer(let slug):
            guard let open = shell.openDrawer else { return unavailable("The drawer") }
            var tab: NotchState.Tab?
            if let slug {
                guard let named = AppShellTabs.tab(for: slug) else { return (false, "No tab named “\(slug)”") }
                tab = named
            }
            // A link never brings a hidden island back (full screen, an
            // excluded app, screen sharing, hidden by the user).
            guard open(tab, !fromLink) else { return (false, "The island is hidden right now") }
            return (true, "Opened the drawer")
        case .closeDrawer:
            guard let close = shell.closeDrawer else { return unavailable("The drawer") }
            close()
            return (true, "Closed the drawer")
        case .toggleDrawer:
            guard let toggle = shell.toggleDrawer else { return unavailable("The drawer") }
            toggle()
            return (true, "Toggled the drawer")
        case .startTimer(let minutes):
            guard let start = actions.startTimer else { return unavailable("The timer") }
            start(minutes)
            return (true, "Timer started")
        case .startPomodoro:
            guard let start = actions.startPomodoro else { return unavailable("The timer") }
            start()
            return (true, "Pomodoro started")
        case .pauseTimer:
            guard let pause = actions.pauseTimer else { return unavailable("The timer") }
            pause()
            return (true, "Timer paused or resumed")
        case .resetTimer:
            guard let reset = actions.resetTimer else { return unavailable("The timer") }
            reset()
            return (true, "Timer reset")
        case .startFocus(let minutes):
            guard let start = actions.startFocus else { return unavailable("Focus") }
            start(minutes)
            return (true, "Focus started")
        case .endFocus:
            guard let end = actions.endFocus else { return unavailable("Focus") }
            end()
            return (true, "Focus ended")
        case .postActivity(let request):
            guard shell.post(Self.activity(for: request)) else { return unavailable("The island") }
            return (true, "Shown on the island")
        case .dismissActivity(let id):
            guard let dismiss = shell.dismissActivity else { return unavailable("The island") }
            dismiss(id)
            return (true, "Removed")
        case .setFeature(let name, let on):
            guard let feature = features[name] else {
                return (false, "No feature named “\(name)” (see the Automation Guide)")
            }
            let value = on ?? !feature.get()
            if value, fromLink, !feature.allowsTurningOn, !feature.get() {
                return (false, "\(feature.title) can only be turned on in Settings")
            }
            feature.set(value)
            return (true, "\(feature.title) \(value ? "on" : "off")")
        case .setAppearance(let raw):
            guard let style = AppearanceStyle(rawValue: raw) else { return (false, "Unknown look") }
            AppearanceSettings.shared.style = style
            return (true, "Look: \(style.title)")
        case .pickColor:
            guard let pick = actions.pickColor else { return unavailable("The color picker") }
            pick()
            return (true, "Color picker opened")
        case .checkForUpdates:
            // From a link: the window only. GitHub is contacted when the
            // user clicks Check Now (a Try button counts as that click).
            if fromLink {
                UpdateController.shared.showWindowWithoutChecking()
                return (true, "Opened Software Update")
            }
            UpdateController.shared.checkNow(userInitiated: true)
            return (true, "Checking for updates")
        case .showAbout:
            SparkVAppInfo.showAbout()
            return (true, "Showed About")
        case .showDiagnostics:
            DiagnosticsWindowController.shared.show()
            return (true, "Showed reports")
        case .openMeeting(let id):
            guard let open = actions.openMeeting else { return unavailable("Meeting notes") }
            open(id)
            return (true, "Opened the meeting")
        }
    }

    private func rateKey(_ command: AutomationCommand) -> String {
        switch command {
        // One key per activity: a dismiss replaces a deferred post of the
        // same id, so the order a script sends them in is kept.
        case .postActivity(let request): "activity." + request.id
        case .dismissActivity(let id): "activity." + id
        case .setFeature(let name, _): "feature." + name
        default: command.summary
        }
    }

    private func note(_ summary: String, outcome: String, ok: Bool) {
        recent.insert(LogEntry(date: Date(), summary: summary, outcome: outcome, ok: ok), at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
        AppLog.log("Automation: \(summary): \(outcome)")
    }

    /// One quiet band (at most every 30 s) when a link was blocked, so the
    /// user knows why nothing happened and where the switch is.
    private func showBlockedNotice(_ command: AutomationCommand) {
        let now = Date()
        if let last = lastBlockedNotice, now.timeIntervalSince(last) < 30 { return }
        lastBlockedNotice = now
        let posted = AppShellController.shared.post(LiveActivity(
            id: "appshell.automation.blocked", kind: .notification, priority: 35, duration: 5,
            symbol: "lock.fill", compactText: "Off"
        ) {
            ExternalActivityBand(
                title: "A link asked SparkV to \(command.blockedPhrase)",
                subtitle: "Turn on Automation in Settings › Advanced to allow it",
                symbol: "lock.fill", tint: nil, progress: nil
            )
        })
        if !posted { NSSound.beep() }
    }

    // MARK: External activities

    static func activity(for request: ExternalActivityRequest) -> LiveActivity {
        let symbol = request.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil } ?? "app.badge"
        let tint = color(named: request.tint)
        let tall = request.subtitle != nil
        return LiveActivity(
            id: request.id,
            kind: .notification,
            priority: externalPriority,
            duration: request.duration ?? ExternalActivityRequest.maxDuration,
            height: tall ? NotchMetrics.activityAnswerBandHeight : NotchMetrics.activityBandHeight,
            symbol: symbol,
            tint: tint ?? SparkVTheme.text,
            compactText: request.compactText,
            peekKey: request.title
        ) {
            ExternalActivityBand(title: request.title, subtitle: request.subtitle, symbol: symbol, tint: tint, progress: request.progress)
        }
    }

    /// Apple: the named system color. SparkV Red: the accent for any tint.
    static func color(named name: String?) -> Color? {
        guard let name else { return nil }
        guard SparkVTheme.isApple else { return SparkVTheme.red }
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "gray", "grey": return .gray
        case "white": return .white
        default: return nil
        }
    }

    // MARK: Built-in features (singletons only; the rest come from INTEGRATION.md)

    private func registerBuiltInFeatures() {
        register(AutomationFeature(
            name: "menu-bar-icon", title: "Menu bar icon",
            get: { StatusItemController.shared.isVisible },
            set: { StatusItemController.shared.setVisible($0) }
        ))
        // Contacts api.github.com: a link may only turn it off.
        register(AutomationFeature(
            name: "update-checks", title: "Automatic update checks", allowsTurningOn: false,
            get: { UpdateController.shared.automaticChecks },
            set: { UpdateController.shared.automaticChecks = $0 }
        ))
        register(AutomationFeature(
            name: "ambient-light", title: "Ambient Light",
            get: { AmbientLightSettings.shared.isEnabled },
            set: { AmbientLightSettings.shared.isEnabled = $0 }
        ))
    }
}

/// sparkv://open?tab=… names → drawer tabs.
@MainActor
enum AppShellTabs {
    static let names: [String: NotchState.Tab] = [
        "home": .nook, "nook": .nook, "media": .nook,
        "widgets": .widgets, "tray": .tray, "shelf": .tray,
        "today": .today, "calendar": .today, "meetings": .today, "timer": .today,
        "converter": .converter, "convert": .converter,
        "spaces": .spaces, "agents": .agents, "hub": .agents,
        "flow": .flow, "dictation": .flow, "notes": .flow,
        "clicky": .clicky, "clipboard": .clipboard, "focus": .focus,
        "search": .search, "downloads": .downloads, "fans": .fans,
        "file-drop": .fileDrop, "files": .fileDrop, "reply": .replyDrafter,
        "screen": .screen, "ask-screen": .screen, "prompt": .promptRefiner,
        "browser": .browser, "jobs": .jobs, "ui-audit": .uiAudit, "distance": .screenDistance,
    ]

    static func tab(for slug: String) -> NotchState.Tab? { names[slug] }
}

/// The band an external activity shows under the notch.
struct ExternalActivityBand: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color?
    let progress: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? SparkVTheme.text)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let progress {
                HStack(spacing: 6) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 64, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint ?? SparkVTheme.progressTint).frame(width: max(4, 64 * progress), height: 4)
                        }
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: progress)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, subtitle, progress.map { "\(Int(($0 * 100).rounded())) percent" }].compactMap { $0 }.joined(separator: ", "))
    }
}
