import AppKit
import Darwin
import Foundation
import SwiftUI

// Developer toolkit pages for the Dev drawer: Git glance, Docker, Top
// (process hogs) and Tools (decode, regex, cron, snippets, pins).
// Everything runs on this Mac. Nothing here reads credential files or logs
// what the user types or copies. Anything that stops or kills asks first.

// MARK: - Shell

enum DevShell {
    /// Runs an executable with arguments, off the main thread, with a timeout.
    /// Returns stdout, or nil when it couldn't run or exited non-zero.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 6) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = env
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                guard process.terminationStatus == 0 else { continuation.resume(returning: nil); return }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @MainActor
    static func confirm(_ title: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Opens Terminal running one command (through a temporary .command file
    /// in SparkV's own temp folder).
    static func openInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sparkv-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh\nrm -f \"$0\"\n\(command)\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        } catch {
            AppLog.log("Dev Tools: couldn't open Terminal")
        }
    }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Shared row bits

private struct DevRowText: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(SparkVTheme.text).lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
        }
    }
}

private struct DevList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) { content }.padding(6)
        }
    }
}

// MARK: - Git glance

struct DevRepo: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let branch: String
    let changed: Int
    let ahead: Int
    let behind: Int
    var name: String { (path as NSString).lastPathComponent }
}

/// Repos open in your terminals, editors and coding agents: the working
/// folders of your own shells, editors and dev servers, walked up to the
/// nearest `.git`. Sampled only while the Git page is open.
@MainActor
final class DevGitController: ObservableObject {
    static let shared = DevGitController()
    @Published private(set) var repos: [DevRepo] = []
    @Published private(set) var scanned = false
    private var timer: Timer?
    private static let hosts: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "node", "python", "python3", "ruby",
                                            "Code Helper", "Cursor Helper", "claude", "codex", "gemini", "Xcode", "swift", "cargo", "go"]

    func beginViewing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in Task { @MainActor in DevGitController.shared.refresh() } }
    }

    func endViewing() { timer?.invalidate(); timer = nil }

    func refresh() {
        Task {
            let roots = await Self.findRoots()
            var found: [DevRepo] = []
            for root in roots.prefix(8) {
                if let repo = await Self.status(root) { found.append(repo) }
            }
            repos = found.sorted { ($0.changed > 0 ? 0 : 1, $0.name) < ($1.changed > 0 ? 0 : 1, $1.name) }
            scanned = true
        }
    }

    private nonisolated static func findRoots() async -> [String] {
        var roots = Set<String>()
        let home = NSHomeDirectory()
        for pid in LocalProcesses.userPIDs() {
            let name = LocalProcesses.name(of: pid)
            guard hosts.contains(name) || name.hasPrefix("Code") || name.hasPrefix("Cursor") else { continue }
            guard var dir = LocalProcesses.workingDirectory(of: pid), dir != "/", dir != home else { continue }
            // Walk up to the nearest .git (stop at home).
            while dir.count > home.count {
                if FileManager.default.fileExists(atPath: dir + "/.git") { roots.insert(dir); break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return roots.sorted()
    }

    private nonisolated static func status(_ path: String) async -> DevRepo? {
        guard let out = await DevShell.run("/usr/bin/git", ["-C", path, "status", "--porcelain=v1", "-b"]) else { return nil }
        var lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty, lines[0].hasPrefix("## ") else { return nil }
        let head = String(lines.removeFirst().dropFirst(3))
        var branch = head.components(separatedBy: "...").first ?? head
        if branch.hasPrefix("No commits yet on ") { branch = String(branch.dropFirst(18)) }
        branch = branch.components(separatedBy: " ").first ?? branch
        func number(after word: String) -> Int {
            guard let range = head.range(of: word + " ") else { return 0 }
            return Int(head[range.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        return DevRepo(path: path, branch: branch, changed: lines.count, ahead: number(after: "ahead"), behind: number(after: "behind"))
    }

    func openInTerminal(_ repo: DevRepo) { DevShell.openInTerminal("cd \(DevShell.quoted(repo.path)) && git status && exec zsh -l") }
    func reveal(_ repo: DevRepo) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)]) }
    func copyBranch(_ repo: DevRepo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(repo.branch, forType: .string)
    }
}

struct DevGitPage: View {
    @ObservedObject private var controller = DevGitController.shared

    var body: some View {
        Group {
            if controller.repos.isEmpty {
                ExtrasNotice(symbol: "arrow.triangle.branch",
                             title: controller.scanned ? "No open repos found" : "Looking for repos…",
                             detail: "Repos your terminals, editors and coding agents are working in show here with branch, changes and ahead/behind.")
            } else {
                DevList {
                    ForEach(controller.repos) { repo in
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(repo.changed > 0 ? SparkVTheme.warning : SparkVTheme.success)
                                .frame(width: 16)
                            DevRowText(title: repo.name, detail: repo.branch)
                            Spacer(minLength: 4)
                            if repo.changed > 0 { ExtrasPill(text: "\(repo.changed) changed", tint: SparkVTheme.warning) }
                            if repo.ahead > 0 { ExtrasPill(text: "↑\(repo.ahead)") }
                            if repo.behind > 0 { ExtrasPill(text: "↓\(repo.behind)", tint: SparkVTheme.warning) }
                            ExtrasIconButton(systemImage: "doc.on.doc", label: "Copy branch name") { controller.copyBranch(repo) }
                            ExtrasIconButton(systemImage: "terminal", label: "Open in Terminal") { controller.openInTerminal(repo) }
                        }
                        .padding(.horizontal, 6).frame(height: 30)
                        .contextMenu { Button("Show in Finder") { controller.reveal(repo) } }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(repo.name) on \(repo.branch), \(repo.changed) changed files")
                    }
                }
            }
        }
        .onAppear { controller.beginViewing() }
        .onDisappear { controller.endViewing() }
    }
}

// MARK: - Docker

struct DevContainer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let image: String
    let status: String
    let isRunning: Bool
    var cpu: String = ""
    var memory: String = ""
}

/// Docker containers through the `docker` CLI (Docker Desktop, OrbStack,
/// Colima). Polled only while the Docker page is open.
@MainActor
final class DevDockerController: ObservableObject {
    static let shared = DevDockerController()
    @Published private(set) var containers: [DevContainer] = []
    @Published private(set) var problem: String?
    @Published private(set) var scanned = false
    private var timer: Timer?

    static var docker: String? {
        DevShell.firstExisting(["/opt/homebrew/bin/docker", "/usr/local/bin/docker",
                                "/Applications/Docker.app/Contents/Resources/bin/docker",
                                NSHomeDirectory() + "/.orbstack/bin/docker"])
    }

    func beginViewing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in DevDockerController.shared.refresh() } }
    }

    func endViewing() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard let docker = Self.docker else {
            problem = "Docker isn't installed"
            scanned = true
            return
        }
        Task {
            guard let list = await DevShell.run(docker, ["ps", "-a", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}"]) else {
                problem = "Docker isn't running"
                containers = []
                scanned = true
                return
            }
            var items = list.split(separator: "\n").compactMap { line -> DevContainer? in
                let f = line.components(separatedBy: "\t")
                guard f.count >= 5 else { return nil }
                return DevContainer(id: f[0], name: f[1], image: f[2], status: f[4], isRunning: f[3] == "running")
            }
            if items.contains(where: \.isRunning),
               let stats = await DevShell.run(docker, ["stats", "--no-stream", "--format", "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}"], timeout: 8) {
                for line in stats.split(separator: "\n") {
                    let f = line.components(separatedBy: "\t")
                    guard f.count >= 3, let i = items.firstIndex(where: { f[0].hasPrefix($0.id) || $0.id.hasPrefix(f[0]) }) else { continue }
                    items[i].cpu = f[1]
                    items[i].memory = f[2].components(separatedBy: " / ").first ?? f[2]
                }
            }
            containers = items.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
            problem = nil
            scanned = true
        }
    }

    func start(_ c: DevContainer) { act(["start", c.id]) }

    func stop(_ c: DevContainer) {
        guard DevShell.confirm("Stop \(c.name)?", "The container stops. You can start it again from here.", button: "Stop") else { return }
        act(["stop", c.id])
    }

    func restart(_ c: DevContainer) {
        guard DevShell.confirm("Restart \(c.name)?", "The container stops and starts again.", button: "Restart") else { return }
        act(["restart", c.id])
    }

    func logs(_ c: DevContainer) {
        guard let docker = Self.docker else { return }
        DevShell.openInTerminal("\(DevShell.quoted(docker)) logs --tail 200 -f \(DevShell.quoted(c.id))")
    }

    private func act(_ args: [String]) {
        guard let docker = Self.docker else { return }
        Task {
            _ = await DevShell.run(docker, args, timeout: 30)
            refresh()
        }
    }
}

struct DevDockerPage: View {
    @ObservedObject private var controller = DevDockerController.shared

    var body: some View {
        Group {
            if let problem = controller.problem {
                ExtrasNotice(symbol: "shippingbox", title: problem,
                             detail: "Start Docker Desktop, OrbStack or Colima and your containers show here with CPU, memory, start, stop and logs.")
            } else if controller.containers.isEmpty {
                ExtrasNotice(symbol: "shippingbox", title: controller.scanned ? "No containers" : "Asking Docker…",
                             detail: "Containers you create show here.")
            } else {
                DevList {
                    ForEach(controller.containers) { c in
                        HStack(spacing: 8) {
                            Circle().fill(c.isRunning ? SparkVTheme.success : SparkVTheme.textTertiary).frame(width: 7, height: 7)
                            DevRowText(title: c.name, detail: c.isRunning && !c.cpu.isEmpty ? "\(c.image) · \(c.cpu) CPU · \(c.memory)" : "\(c.image) · \(c.status)")
                            Spacer(minLength: 4)
                            ExtrasIconButton(systemImage: "text.alignleft", label: "Logs") { controller.logs(c) }
                            if c.isRunning {
                                ExtrasIconButton(systemImage: "arrow.clockwise", label: "Restart") { controller.restart(c) }
                                ExtrasIconButton(systemImage: "stop.fill", label: "Stop") { controller.stop(c) }
                            } else {
                                ExtrasIconButton(systemImage: "play.fill", label: "Start") { controller.start(c) }
                            }
                        }
                        .padding(.horizontal, 6).frame(height: 30)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(c.name), \(c.isRunning ? "running" : "stopped")")
                    }
                }
            }
        }
        .onAppear { controller.beginViewing() }
        .onDisappear { controller.endViewing() }
    }
}

// MARK: - Top (process hogs)

struct DevHog: Identifiable, Equatable, Sendable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let cpu: Double
    let memoryMB: Double
}

/// Your own processes by CPU, sampled from libproc. A light check every
/// 20 s spots runaway dev tools (node, swift-frontend, python…) stuck above
/// 90% CPU for a minute, and says so once.
@MainActor
final class DevTopController: ObservableObject {
    static let shared = DevTopController()
    @Published private(set) var hogs: [DevHog] = []
    @Published var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "SparkV.devStatus.top.alerts"); scheduleBackground() }
    }
    weak var activities: ActivityCenter?
    var opensTab: NotchState.Tab?

    private var last: [pid_t: (time: UInt64, at: TimeInterval)] = [:]
    private var hotSince: [pid_t: TimeInterval] = [:]
    private var alerted = Set<pid_t>()
    private var viewTimer: Timer?
    private var backgroundTimer: Timer?
    private static let devTools: Set<String> = ["node", "swift-frontend", "swift-build", "python", "python3", "ruby", "java",
                                               "cargo", "rustc", "go", "clang", "ld", "esbuild", "tsc", "deno", "bun",
                                               "webpack", "vite", "gradle", "kotlin", "dotnet", "php", "SourceKitService"]

    init() {
        alertsEnabled = UserDefaults.standard.object(forKey: "SparkV.devStatus.top.alerts") as? Bool ?? true
    }

    func connect(activities: ActivityCenter, opensTab: NotchState.Tab?) {
        self.activities = activities
        self.opensTab = opensTab
        scheduleBackground()
    }

    private func scheduleBackground() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        guard alertsEnabled else { return }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in DevTopController.shared.sample() }
        }
    }

    func beginViewing() {
        refresh()
        viewTimer?.invalidate()
        viewTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in DevTopController.shared.sample() } }
    }

    func endViewing() { viewTimer?.invalidate(); viewTimer = nil }

    func refresh() {
        sample()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { DevTopController.shared.sample() }
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        var next: [pid_t: (UInt64, TimeInterval)] = [:]
        var rows: [DevHog] = []
        let me = getpid()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(timebase.denom)
        for pid in LocalProcesses.userPIDs() where pid != me {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let total = info.pti_total_user + info.pti_total_system
            next[pid] = (total, now)
            guard let prev = last[pid], now > prev.at, total >= prev.time else { continue }
            let cpu = Double(total - prev.time) * scale / ((now - prev.at) * 1_000_000_000) * 100
            rows.append(DevHog(pid: pid, name: LocalProcesses.name(of: pid), cpu: cpu, memoryMB: Double(info.pti_resident_size) / 1_048_576))
        }
        last = next.mapValues { (time: $0.0, at: $0.1) }
        guard !rows.isEmpty else { return }
        hogs = Array(rows.sorted { $0.cpu > $1.cpu }.prefix(8))
        checkRunaways(rows, now: now)
    }

    private func checkRunaways(_ rows: [DevHog], now: TimeInterval) {
        guard alertsEnabled else { return }
        let hot = rows.filter { $0.cpu > 90 && Self.devTools.contains($0.name) }
        let hotPIDs = Set(hot.map(\.pid))
        hotSince = hotSince.filter { hotPIDs.contains($0.key) }
        alerted = alerted.filter { hotPIDs.contains($0) }
        for hog in hot {
            let since = hotSince[hog.pid] ?? now
            hotSince[hog.pid] = since
            guard now - since >= 55, !alerted.contains(hog.pid), let activities else { continue }
            alerted.insert(hog.pid)
            let tint = SparkVTheme.warning
            let opensTab = opensTab
            activities.post(LiveActivity(id: "devStatus.hog", kind: .notification, priority: 60, duration: 7, opensTab: opensTab,
                                         symbol: "flame.fill", tint: tint) {
                CodingAgentEventBand(symbol: "flame.fill", tint: tint,
                                     title: "\(hog.name) is using \(Int(hog.cpu))% CPU",
                                     detail: "For over a minute · pid \(hog.pid)")
            })
            DevStatusNavigator.shared.section = .top
        }
    }

    func quit(_ hog: DevHog) {
        guard hog.pid > 1, hog.pid != getpid(),
              DevShell.confirm("Quit \(hog.name)?", "SparkV asks process \(hog.pid) to quit (SIGTERM). Unsaved work in it may be lost.", button: "Quit") else { return }
        kill(hog.pid, SIGTERM)
        refresh()
    }
}

struct DevTopPage: View {
    @ObservedObject private var controller = DevTopController.shared

    var body: some View {
        DevList {
            if controller.hogs.isEmpty {
                Text("Measuring…").font(.system(size: 10.5)).foregroundStyle(SparkVTheme.textTertiary).frame(height: 30)
            }
            ForEach(controller.hogs) { hog in
                HStack(spacing: 8) {
                    Text(String(format: "%.0f%%", hog.cpu))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hog.cpu > 80 ? SparkVTheme.destructive : (hog.cpu > 30 ? SparkVTheme.warning : SparkVTheme.textSecondary))
                        .frame(width: 44, alignment: .trailing)
                    DevRowText(title: hog.name, detail: String(format: "pid %d · %.0f MB", hog.pid, hog.memoryMB))
                    Spacer(minLength: 4)
                    ExtrasIconButton(systemImage: "xmark.circle", label: "Quit \(hog.name)…") { controller.quit(hog) }
                }
                .padding(.horizontal, 6).frame(height: 28)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(hog.name), \(Int(hog.cpu)) percent CPU")
            }
            ExtrasToggleRow(title: "Tell Me About Runaway Dev Tools", isOn: $controller.alertsEnabled)
                .padding(.horizontal, 6)
        }
        .onAppear { controller.beginViewing() }
        .onDisappear { controller.endViewing() }
    }
}

// MARK: - Tools page

struct DevToolsPage: View {
    enum Tool: String, CaseIterable, Hashable { case decode, regex, cron, snippets, pins }
    @AppStorage("SparkV.devStatus.tool") private var tool: Tool = .decode

    var body: some View {
        VStack(spacing: 4) {
            ExtrasSegmented(options: Tool.allCases.map { ($0, title($0)) }, selection: $tool, label: "Tool", compact: true)
                .padding(.horizontal, 6).padding(.top, 5)
            Group {
                switch tool {
                case .decode: DevDecodeTool()
                case .regex: DevRegexTool()
                case .cron: DevCronTool()
                case .snippets: DevSnippetsTool()
                case .pins: DevPinsTool()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func title(_ t: Tool) -> String {
        switch t {
        case .decode: "Decode"
        case .regex: "Regex"
        case .cron: "Cron"
        case .snippets: "Snippets"
        case .pins: "Pins"
        }
    }
}

private struct DevField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, 7).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

final class DevTextBox: ObservableObject {
    @Published var text = ""
    @Published var copied: UUID?
}

// MARK: Decode

/// Figures out what a piece of text is and shows it decoded.
enum DevDecoder {
    struct Result: Equatable { let kind: String; let output: String }

    static func decode(_ raw: String) -> [Result] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var results: [Result] = []
        if let json = prettyJSON(text) { results.append(Result(kind: "JSON", output: json)) }
        if let jwt = jwt(text) { results.append(jwt) }
        if let seconds = Double(text), (1e9...1e13).contains(seconds) {
            let date = Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
            results.append(Result(kind: "Timestamp", output: date.formatted(date: .complete, time: .standard) + "\n" + ISO8601DateFormatter().string(from: date)))
        }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var lines = ["\(comps.host ?? "")\(comps.path)"]
            for item in comps.queryItems ?? [] { lines.append("\(item.name) = \(item.value ?? "")") }
            results.append(Result(kind: "URL", output: lines.joined(separator: "\n")))
        } else if text.contains("%"), let decoded = text.removingPercentEncoding, decoded != text {
            results.append(Result(kind: "URL-decoded", output: decoded))
        }
        if results.isEmpty, text.count >= 8, let data = base64(text), let string = String(data: data, encoding: .utf8),
           string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) {
            results.append(Result(kind: "Base64", output: prettyJSON(string) ?? string))
        }
        if UUID(uuidString: text) != nil { results.append(Result(kind: "UUID", output: text.lowercased())) }
        if results.isEmpty, let data = text.data(using: .utf8) {
            results.append(Result(kind: "Base64-encoded", output: data.base64EncodedString()))
        }
        return results
    }

    static func prettyJSON(_ text: String) -> String? {
        guard let first = text.first, first == "{" || first == "[", let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func base64(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard s.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }) else { return nil }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func jwt(_ text: String) -> Result? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, text.hasPrefix("eyJ"),
              let header = base64(String(parts[0])).flatMap({ String(data: $0, encoding: .utf8) }),
              let payload = base64(String(parts[1])).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        var out = "Header\n" + (prettyJSON(header) ?? header) + "\nPayload\n" + (prettyJSON(payload) ?? payload)
        if let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let exp = object["exp"] as? Double {
            let date = Date(timeIntervalSince1970: exp)
            out += "\n" + (date < Date() ? "Expired " : "Expires ") + date.formatted(date: .abbreviated, time: .shortened)
        }
        out += "\n(Signature not checked)"
        return Result(kind: "JWT", output: out)
    }
}

private struct DevDecodeTool: View {
    @StateObject private var box = DevTextBox()
    private var input: String { box.text }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                DevField(placeholder: "Paste JSON, JWT, Base64, URL, timestamp…", text: $box.text)
                ExtrasIconButton(systemImage: "doc.on.clipboard", label: "Use clipboard") {
                    box.text = NSPasteboard.general.string(forType: .string) ?? ""
                }
                ExtrasIconButton(systemImage: "number", label: "New UUID") { box.text = UUID().uuidString.lowercased() }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(DevDecoder.decode(input).enumerated()), id: \.offset) { _, result in
                        HStack(alignment: .top, spacing: 6) {
                            ExtrasPill(text: result.kind)
                            Text(result.output).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SparkVTheme.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            ExtrasIconButton(systemImage: "doc.on.doc", label: "Copy \(result.kind)") { copyToClipboard(result.output) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}

// MARK: Regex

private struct DevRegexTool: View {
    @AppStorage("SparkV.devStatus.regex.pattern") private var pattern = ""
    @StateObject private var box = DevTextBox()
    private var sample: String { box.text }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                DevField(placeholder: "Pattern, e.g. (\\w+)@(\\w+)\\.com", text: $pattern)
                DevField(placeholder: "Test text", text: $box.text)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(isError ? SparkVTheme.destructive : SparkVTheme.textSecondary)
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, groups in
                        Text("\(index + 1). " + groups.enumerated().map { $0.offset == 0 ? "“\($0.element)”" : "$\($0.offset)=\($0.element)" }.joined(separator: "  "))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SparkVTheme.text).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
    }

    private var regex: NSRegularExpression? { pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern) }
    private var isError: Bool { !pattern.isEmpty && regex == nil }

    private var matches: [[String]] {
        guard let regex else { return [] }
        let ns = sample as NSString
        return regex.matches(in: sample, range: NSRange(location: 0, length: ns.length)).prefix(20).map { match in
            (0..<match.numberOfRanges).map { i in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "–" : ns.substring(with: r)
            }
        }
    }

    private var summary: String {
        if pattern.isEmpty { return "Type a pattern and some text to test it." }
        if isError { return "That pattern isn't valid." }
        let count = matches.count
        return count == 0 ? "No matches" : "\(count) match\(count == 1 ? "" : "es")"
    }
}

// MARK: Cron

/// Standard 5-field cron (minute hour day month weekday) with *, lists,
/// ranges and steps.
enum DevCron {
    static func field(_ text: Substring, _ range: ClosedRange<Int>) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            var lo = range.lowerBound, hi = range.upperBound
            let base = pieces[0]
            if base != "*" {
                let bounds = base.split(separator: "-", maxSplits: 1).map { Int($0) }
                guard let a = bounds.first ?? nil else { return nil }
                lo = a
                hi = bounds.count == 2 ? (bounds[1] ?? -1) : (pieces.count == 2 ? range.upperBound : a)
            }
            guard range.contains(lo), range.contains(hi), lo <= hi else { return nil }
            values.formUnion(stride(from: lo, through: hi, by: step))
        }
        return values.isEmpty ? nil : values
    }

    static func next(_ expression: String, count: Int = 5, from start: Date = Date()) -> [Date]? {
        let f = expression.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count == 5,
              let minutes = field(f[0], 0...59), let hours = field(f[1], 0...23),
              let days = field(f[2], 1...31), let months = field(f[3], 1...12),
              var weekdays = field(f[4], 0...7) else { return nil }
        if weekdays.contains(7) { weekdays.insert(0) }
        let dayAny = f[2] == "*", weekAny = f[4] == "*"
        let calendar = Calendar.current
        guard var date = calendar.date(bySetting: .second, value: 0, of: start.addingTimeInterval(60)) else { return nil }
        date = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
        var out: [Date] = []
        var steps = 0
        while out.count < count, steps < 600_000 {
            steps += 1
            let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: date)
            guard let month = c.month, months.contains(month) else {
                date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date; continue
            }
            let dayOK = days.contains(c.day ?? 0), weekOK = weekdays.contains((c.weekday ?? 1) - 1)
            let matchesDay = dayAny && weekAny ? true : (dayAny ? weekOK : (weekAny ? dayOK : dayOK || weekOK))
            guard matchesDay else {
                date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date; continue
            }
            guard hours.contains(c.hour ?? 0) else {
                date = calendar.date(byAdding: .hour, value: 1, to: calendar.date(bySetting: .minute, value: 0, of: date) ?? date) ?? date
                date = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
                continue
            }
            if minutes.contains(c.minute ?? 0) { out.append(date) }
            date = date.addingTimeInterval(60)
        }
        return out
    }
}

private struct DevCronTool: View {
    @AppStorage("SparkV.devStatus.cron") private var expression = "*/15 9-17 * * 1-5"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DevField(placeholder: "minute hour day month weekday", text: $expression)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    if let runs = DevCron.next(expression) {
                        if runs.isEmpty { Text("Never runs").font(.system(size: 10.5)).foregroundStyle(SparkVTheme.warning) }
                        ForEach(runs, id: \.self) { date in
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SparkVTheme.text)
                        }
                    } else {
                        Text("Five fields: minute hour day-of-month month day-of-week").font(.system(size: 10.5)).foregroundStyle(SparkVTheme.destructive)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}

// MARK: Snippets

struct DevSnippet: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var text: String
}

@MainActor
final class DevSnippetStore: ObservableObject {
    static let shared = DevSnippetStore()
    private static let key = "SparkV.devStatus.snippets"
    @Published var snippets: [DevSnippet] { didSet { save() } }

    init() {
        snippets = (UserDefaults.standard.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([DevSnippet].self, from: $0) } ?? []
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(snippets), forKey: Self.key) }

    func addFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        snippets.insert(DevSnippet(title: String(first.prefix(60)), text: text), at: 0)
    }
}

private struct DevSnippetsTool: View {
    @ObservedObject private var store = DevSnippetStore.shared
    @StateObject private var box = DevTextBox()

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(store.snippets.isEmpty ? "Copy a command or code, then save it here." : "Click to copy")
                    .font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                Spacer()
                ExtrasCapsuleButton(title: "Save Clipboard", systemImage: "plus") { store.addFromClipboard() }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(store.snippets) { snippet in
                        HStack(spacing: 6) {
                            Button {
                                copyToClipboard(snippet.text)
                                box.copied = snippet.id
                            } label: {
                                HStack {
                                    Image(systemName: box.copied == snippet.id ? "checkmark" : "chevron.left.forwardslash.chevron.right")
                                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(SparkVTheme.textSecondary).frame(width: 14)
                                    Text(snippet.title).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SparkVTheme.text).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ExtrasIconButton(systemImage: "trash", label: "Delete snippet", size: 18) {
                                store.snippets.removeAll { $0.id == snippet.id }
                            }
                        }
                        .frame(height: 20)
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}

// MARK: Pins

/// Text pinned to the notch (an error or stack trace you're fixing): a
/// persistent island band until you unpin it. Kept in memory only.
@MainActor
final class DevPins: ObservableObject {
    static let shared = DevPins()
    @Published private(set) var pins: [DevSnippet] = []
    weak var activities: ActivityCenter?
    var opensTab: NotchState.Tab?

    func pinClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let lines = text.split(separator: "\n").map(String.init)
        // Prefer the line that looks like the error.
        let headline = lines.first { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("exception") } ?? lines.first ?? text
        let pin = DevSnippet(title: String(headline.trimmingCharacters(in: .whitespaces).prefix(120)), text: text)
        pins.insert(pin, at: 0)
        post(pin)
    }

    func unpin(_ pin: DevSnippet) {
        pins.removeAll { $0.id == pin.id }
        activities?.dismiss(id: "devStatus.pin.\(pin.id.uuidString)")
    }

    private func post(_ pin: DevSnippet) {
        guard let activities else { return }
        let tint = SparkVTheme.destructive
        activities.post(LiveActivity(id: "devStatus.pin.\(pin.id.uuidString)", kind: .notification, priority: 40, duration: nil,
                                     opensTab: opensTab, symbol: "pin.fill", tint: tint, compactText: "Pinned") {
            CodingAgentEventBand(symbol: "pin.fill", tint: tint, title: pin.title, detail: "Pinned · unpin in Dev › Tools › Pins")
        })
    }
}

private struct DevPinsTool: View {
    @ObservedObject private var pins = DevPins.shared

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(pins.pins.isEmpty ? "Copy an error, then pin it to the notch while you fix it." : "Pinned to the notch")
                    .font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                Spacer()
                ExtrasCapsuleButton(title: "Pin Clipboard", systemImage: "pin") { pins.pinClipboard() }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(pins.pins) { pin in
                        HStack(spacing: 6) {
                            Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(SparkVTheme.destructive).frame(width: 14)
                            Text(pin.title).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SparkVTheme.text).lineLimit(1)
                            Spacer(minLength: 0)
                            ExtrasIconButton(systemImage: "doc.on.doc", label: "Copy", size: 18) { copyToClipboard(pin.text) }
                            ExtrasIconButton(systemImage: "pin.slash", label: "Unpin", size: 18) { pins.unpin(pin) }
                        }
                        .frame(height: 20)
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}
