import AppKit
import Foundation
import Security

// MARK: - Pure model (BEGIN harness)

/// One GitHub Actions workflow run, as the island shows it.
struct CIRun: Identifiable, Equatable, Sendable, Codable {
    enum Outcome: String, Sendable, Codable {
        case queued, running, success, failure, cancelled, skipped, neutral
    }

    let id: Int
    let repo: String
    let workflow: String
    let branch: String?
    let event: String?
    let outcome: Outcome
    let url: URL?
    let updatedAt: Date?
    let number: Int?

    var isActive: Bool { outcome == .queued || outcome == .running }
}

enum CIParsing {
    /// `GET /repos/{owner}/{repo}/actions/runs` → runs (newest first).
    static func runs(from data: Data, repo: String) -> [CIRun]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["workflow_runs"] as? [[String: Any]] else { return nil }
        return list.compactMap { run in
            guard let id = (run["id"] as? NSNumber)?.intValue else { return nil }
            let status = run["status"] as? String
            let conclusion = run["conclusion"] as? String
            return CIRun(
                id: id, repo: repo,
                workflow: (run["name"] as? String) ?? (run["display_title"] as? String) ?? "Workflow",
                branch: run["head_branch"] as? String,
                event: run["event"] as? String,
                outcome: outcome(status: status, conclusion: conclusion),
                url: (run["html_url"] as? String).flatMap(URL.init(string:)),
                updatedAt: JSONLTail.date(run["updated_at"]),
                number: (run["run_number"] as? NSNumber)?.intValue
            )
        }
    }

    static func outcome(status: String?, conclusion: String?) -> CIRun.Outcome {
        switch status {
        case "queued"?, "waiting"?, "pending"?, "requested"?: return .queued
        case "in_progress"?: return .running
        default: break
        }
        switch conclusion {
        case "success"?: return .success
        case "failure"?, "timed_out"?, "startup_failure"?, "action_required"?: return .failure
        case "cancelled"?: return .cancelled
        case "skipped"?: return .skipped
        default: return .neutral
        }
    }

    /// The first failed job's page from `/actions/runs/{id}/jobs`.
    static func failingJobURL(from data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = object["jobs"] as? [[String: Any]] else { return nil }
        let failed = jobs.first { ($0["conclusion"] as? String) == "failure" } ?? jobs.first
        return (failed?["html_url"] as? String).flatMap(URL.init(string:))
    }

    /// "owner/repo" from what the user typed (a URL or the short form).
    static func normalizeRepo(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let host = url.host, host.hasSuffix("github.com") {
            value = url.path
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// Seconds to the next poll: 60 s while something runs, else 5 min.
    static func nextInterval(runs: [CIRun]) -> TimeInterval {
        runs.contains(where: \.isActive) ? 60 : 300
    }

    /// Runs that changed into a failure since the previous poll.
    static func newFailures(previous: [CIRun], current: [CIRun]) -> [CIRun] {
        let before = Dictionary(previous.map { ($0.id, $0.outcome) }, uniquingKeysWith: { a, _ in a })
        return current.filter { run in
            run.outcome == .failure && before[run.id].map { $0 != .failure } ?? !previous.isEmpty
        }
    }
}

// MARK: - Pure model (END harness)

// MARK: - Token storage

/// The optional GitHub token (a fine-grained, read-only "Actions" token) in
/// the login keychain. Never written to UserDefaults or the log.
enum DevCIKeychain {
    private static let service = "SparkV.devStatus.github"
    private static let account = "token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func hasToken() -> Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "SparkV Dev Status (GitHub token)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Controller

/// GitHub Actions status for repos you list. Off until you turn it on (it
/// asks api.github.com over HTTPS). Polls every 60 s while a run is in
/// progress, else every 5 minutes, with ETags (a 304 costs nothing against
/// the rate limit); pauses while the Mac sleeps, in Low Power Mode and when
/// turned off. A new failure posts a band; clicking a run opens the failing
/// job on github.com.
@MainActor
final class DevCIController: ObservableObject {
    static let shared = DevCIController()

    enum Status: Equatable {
        case off
        case idle
        case loading
        case error(String)
        case rateLimited(until: Date?)
    }

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.key("enabled")); reschedule(now: true) } }
    @Published private(set) var repos: [String]
    @Published private(set) var runs: [String: [CIRun]] = [:]
    @Published private(set) var status: Status = .off
    @Published private(set) var hasToken = false
    @Published var notifiesFailures: Bool { didSet { defaults.set(notifiesFailures, forKey: Self.key("notify")) } }

    var opensTab: NotchState.Tab?
    private weak var activities: ActivityCenter?
    private let defaults: UserDefaults
    private var etags: [String: String] = [:]
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isAsleep = false
    private var isRunning = false
    private let session: URLSession

    private static func key(_ name: String) -> String { "SparkV.devStatus.ci." + name }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.key("enabled"))
        repos = defaults.stringArray(forKey: Self.key("repos")) ?? []
        notifiesFailures = defaults.object(forKey: Self.key("notify")) == nil ? true : defaults.bool(forKey: Self.key("notify"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        session = URLSession(configuration: configuration)
    }

    func connect(activities: ActivityCenter, opensTab: NotchState.Tab?) {
        self.activities = activities
        self.opensTab = opensTab
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hasToken = DevCIKeychain.hasToken()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAsleep = true; self?.loop?.cancel(); self?.loop = nil }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAsleep = false; self?.reschedule(now: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule(now: false) }
        })
        reschedule(now: true)
    }

    func stop() {
        isRunning = false
        loop?.cancel()
        loop = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Editing

    @discardableResult
    func addRepo(_ text: String) -> Bool {
        guard let repo = CIParsing.normalizeRepo(text), !repos.contains(repo) else { return false }
        repos.append(repo)
        defaults.set(repos, forKey: Self.key("repos"))
        reschedule(now: true)
        return true
    }

    func removeRepo(_ repo: String) {
        repos.removeAll { $0 == repo }
        runs[repo] = nil
        etags[repo] = nil
        defaults.set(repos, forKey: Self.key("repos"))
        // The last one gone: stop the loop (it would wake to poll nothing).
        if repos.isEmpty { reschedule(now: false) }
    }

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            DevCIKeychain.delete()
        } else {
            DevCIKeychain.save(trimmed)
        }
        hasToken = DevCIKeychain.hasToken()
        etags.removeAll()
        reschedule(now: true)
    }

    func refreshNow() { reschedule(now: true) }

    var allRuns: [CIRun] {
        repos.compactMap { runs[$0]?.first }
    }

    // MARK: Polling

    private func reschedule(now: Bool) {
        loop?.cancel()
        loop = nil
        guard isRunning, isEnabled, !repos.isEmpty, !isAsleep else {
            status = isEnabled ? .idle : .off
            return
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled, !now {
            status = .idle
            return
        }
        loop = Task { [weak self] in
            if !now {
                let wait = CIParsing.nextInterval(runs: self?.runs.values.flatMap { $0 } ?? [])
                try? await Task.sleep(for: .seconds(wait))
            }
            while !Task.isCancelled, let self {
                await self.pollAll()
                if ProcessInfo.processInfo.isLowPowerModeEnabled { return }
                let wait = CIParsing.nextInterval(runs: self.runs.values.flatMap { $0 })
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func pollAll() async {
        status = .loading
        let token = DevCIKeychain.load()
        for repo in repos {
            guard !Task.isCancelled else { return }
            await poll(repo, token: token)
        }
        if case .loading = status { status = .idle }
    }

    private func poll(_ repo: String, token: String?) async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs?per_page=5") else { return }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag = etags[repo] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: request)
            // Removed while the request was in flight: drop the answer.
            guard repos.contains(repo), let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                if let etag = http.value(forHTTPHeaderField: "ETag") { etags[repo] = etag }
                guard let parsed = CIParsing.runs(from: data, repo: repo) else { return }
                let previous = runs[repo] ?? []
                runs[repo] = parsed
                if notifiesFailures {
                    for failure in CIParsing.newFailures(previous: previous, current: parsed).prefix(1) { postFailure(failure) }
                }
            case 304:
                break
            case 401:
                status = .error("GitHub refused the token. Check it in Settings › Extras.")
            case 403, 429:
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                status = .rateLimited(until: reset)
            case 404:
                status = .error("\(repo) wasn't found. Private repos need a token.")
            default:
                status = .error("GitHub answered \(http.statusCode).")
            }
        } catch {
            if (error as? URLError)?.code != .cancelled { status = .error("Couldn't reach GitHub.") }
        }
    }

    // MARK: Opening

    /// Opens the failing job (or the run) in the browser.
    func open(_ run: CIRun) {
        guard run.outcome == .failure, let url = URL(string: "https://api.github.com/repos/\(run.repo)/actions/runs/\(run.id)/jobs") else {
            if let page = run.url { NSWorkspace.shared.open(page) }
            return
        }
        Task {
            var request = URLRequest(url: url)
            if let token = DevCIKeychain.load() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let job = (try? await session.data(for: request)).flatMap { CIParsing.failingJobURL(from: $0.0) }
            if let target = job ?? run.url { NSWorkspace.shared.open(target) }
        }
    }

    private func postFailure(_ run: CIRun) {
        guard let activities else { return }
        let tint = SparkVTheme.destructive
        activities.post(LiveActivity(id: "devStatus.ci", kind: .notification, priority: 66, duration: 6, opensTab: opensTab,
                                     symbol: "xmark.octagon.fill", tint: tint) {
            CodingAgentEventBand(symbol: "xmark.octagon.fill", tint: tint,
                                 title: "\(run.workflow) failed",
                                 detail: CodingAgentsController.redacted([run.repo, run.branch].compactMap { $0 }.joined(separator: " · ")))
        })
    }
}
