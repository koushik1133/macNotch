import Darwin
import Foundation

/// Finds node and the bundled runner. Only checks files; never touches the
/// network or asks for permissions.
enum UIAuditRunnerLocator {
    /// `uiAudit.runnerDir` override, then `Contents/Resources/ui-audit` in
    /// the app bundle (build.sh step), then the source tree's
    /// Vendor/ui-audit (development builds run from the repo).
    static func runnerDirectory() -> URL? {
        var candidates: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: UIAuditSettings.runnerDirKey), !custom.isEmpty {
            candidates.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("ui-audit", isDirectory: true))
        }
        // Sources/Labs/UIAudit/<this file> -> <repo>/Vendor/ui-audit
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("Vendor/ui-audit", isDirectory: true))
        let fm = FileManager.default
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("audit.mjs").path)
                && fm.fileExists(atPath: $0.appendingPathComponent("node_modules/playwright-core/package.json").path)
                && fm.fileExists(atPath: $0.appendingPathComponent("node_modules/axe-core/axe.min.js").path)
        }
    }

    /// A `uiAudit.nodePath` override, then the usual install locations. GUI
    /// apps don't inherit the login shell's PATH, so this doesn't rely on it.
    static func nodeExecutable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let custom = UserDefaults.standard.string(forKey: UIAuditSettings.nodePathKey), !custom.isEmpty {
            paths.append((custom as NSString).expandingTildeInPath)
        }
        paths += [
            "\(home)/.local/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node",
            "\(home)/.volta/bin/node", "\(home)/.asdf/shims/node", "\(home)/.nodenv/shims/node",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            paths += sorted.map { "\(nvm)/\($0)/bin/node" }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            paths.append("\(dir)/node")
        }
        return paths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// A running `node audit.mjs --config … --stdin-control`. Splits stdout into
/// JSON lines and delivers decoded events on the main queue, in order.
/// stdin carries `pause` / `resume` / `stop`; closing it stops the runner, so
/// an app crash never leaves a browser crawling on its own.
final class UIAuditProcess: @unchecked Sendable {
    typealias EventHandler = @MainActor (UIAuditEvent) -> Void
    typealias ExitHandler = @MainActor (_ status: Int32, _ stderrTail: String) -> Void

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let onEvent: EventHandler
    private let onExit: ExitHandler
    // Guards everything below.
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = Data()
    private var stdoutClosed = false
    private var terminated: Int32?
    private var reported = false
    private var stdinClosed = false

    init(node: URL, script: URL, arguments: [String], onEvent: @escaping EventHandler, onExit: @escaping ExitHandler) {
        self.onEvent = onEvent
        self.onExit = onExit
        process.executableURL = node
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "NODE_OPTIONS")
        env["PATH"] = [node.deletingLastPathComponent().path, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"] = "1"
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Writing after node exited must fail with EPIPE instead of SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] proc in
            self?.didTerminate(proc.terminationStatus)
        }
        try process.run()
    }

    /// Sends one command line (pause, resume, stop).
    func send(_ command: String) {
        lock.lock()
        let closed = stdinClosed || terminated != nil
        lock.unlock()
        guard !closed else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            AppLog.log("UI audit: runner stdin write failed: \(error.localizedDescription)")
        }
    }

    /// Asks the runner to stop (it writes a partial report), then SIGTERM
    /// after `grace`, then SIGKILL. The runner also finalizes on SIGTERM.
    func stop(grace: TimeInterval = 3) {
        send("stop")
        let process = process
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace + 6) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    /// Immediate SIGKILL (app quitting). Chromium exits with its pipe.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    // MARK: Pipes

    private func readStdout(_ chunk: Data) {
        var lines: [Data] = []
        lock.lock()
        if chunk.isEmpty {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            if !buffer.isEmpty { lines.append(buffer); buffer.removeAll() }
            stdoutClosed = true
        } else {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            // A runaway line without newline must not grow forever.
            if buffer.count > 4_000_000 { buffer.removeAll() }
        }
        let finishNow = stdoutClosed && terminated != nil && !reported
        if finishNow { reported = true }
        let status = terminated ?? 0
        let tail = String(decoding: stderrTail, as: UTF8.self)
        lock.unlock()

        let events = lines.compactMap(UIAuditEvent.decode)
        let onEvent = onEvent
        let onExit = onExit
        if !events.isEmpty || finishNow {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for event in events { onEvent(event) }
                    if finishNow { onExit(status, tail) }
                }
            }
        }
    }

    private func readStderr(_ chunk: Data) {
        lock.lock()
        if chunk.isEmpty {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        } else {
            stderrTail.append(chunk)
            if stderrTail.count > 8000 { stderrTail = stderrTail.suffix(4000) }
        }
        lock.unlock()
    }

    private func didTerminate(_ status: Int32) {
        lock.lock()
        terminated = status
        stdinClosed = true
        let finishNow = stdoutClosed && !reported
        if finishNow { reported = true }
        lock.unlock()
        try? stdinPipe.fileHandleForWriting.close()
        if finishNow {
            deliverExit(status)
        } else {
            // stdout EOF normally follows within milliseconds; don't wait forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let late = !self.reported
                if late { self.reported = true }
                self.lock.unlock()
                if late { self.deliverExit(status) }
            }
        }
    }

    private func deliverExit(_ status: Int32) {
        lock.lock()
        let tail = String(decoding: stderrTail, as: UTF8.self)
        lock.unlock()
        let onExit = onExit
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onExit(status, tail) }
        }
    }
}
