import Darwin
import Foundation

/// One JSON line from runner.mjs. Every field is optional; `type` says which
/// ones are set (see Vendor/browser-recorder/PROTOCOL.md).
struct BRRunnerEvent: Decodable, Sendable {
    let type: String
    var index: Int?
    var row: Int?
    var rows: Int?
    var steps: Int?
    var attempt: Int?
    var stepId: String?
    var title: String?
    var message: String?
    var code: String?
    var reason: String?
    var words: [String]?
    var missing: [String]?
    var screenshot: String?
    var via: String?
    var selectorIndex: Int?
    var score: Double?
    var selectors: [BRSelector]?
    var fingerprint: BRJSON?
    var step: BRStep?
    var flow: BRFlow?
    var ok: Bool?
    var passedRows: Int?
    var failedRows: Int?
    var healed: Int?
    var durationMs: Double?
    var stopped: Bool?
    var playwright: String?
    var chromium: String?

    /// Decodes leniently: a line that does not match the shape is dropped by the caller.
    static func decode(_ line: Data) -> BRRunnerEvent? {
        try? JSONDecoder().decode(BRRunnerEvent.self, from: line)
    }
}

/// Where node and runner.mjs live. Nothing here touches the network or asks
/// for permissions; it only checks files.
enum BRRunnerLocator {
    static let nodePathKey = "BrowserRecorder.nodePath"
    static let runnerDirKey = "BrowserRecorder.runnerDir"

    /// `Contents/Resources/BrowserRecorder` in the app bundle (see the lead's
    /// build.sh step), then a `BrowserRecorder.runnerDir` override, then the
    /// NOTCHISLAND_BROWSER_RECORDER_DIR environment variable.
    static func runnerDirectory() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("BrowserRecorder", isDirectory: true))
        }
        if let custom = UserDefaults.standard.string(forKey: runnerDirKey), !custom.isEmpty {
            candidates.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let env = ProcessInfo.processInfo.environment["NOTCHISLAND_BROWSER_RECORDER_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        let fm = FileManager.default
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("runner.mjs").path)
                && fm.fileExists(atPath: $0.appendingPathComponent("node_modules/playwright-core/package.json").path)
        }
    }

    /// A `BrowserRecorder.nodePath` override, then the usual install locations.
    /// GUI apps don't get the login shell's PATH, so this does not rely on it.
    static func nodeExecutable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let custom = UserDefaults.standard.string(forKey: nodePathKey), !custom.isEmpty {
            paths.append((custom as NSString).expandingTildeInPath)
        }
        paths += [
            "\(home)/.local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
            "\(home)/.nodenv/shims/node",
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

/// A running `node runner.mjs …`. Splits stdout into JSON lines and hands
/// each decoded event to `onEvent` on the main queue, in order. stdin stays
/// open for `send(_:)`; closing it (or the app quitting) makes the runner stop.
final class BRRunnerProcess: @unchecked Sendable {
    typealias EventHandler = @MainActor (BRRunnerEvent) -> Void
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
    private var exited = false
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
        // A write after node exits must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readStderr(handle.availableData)
        }
        // Strong capture: keeps this object alive until the process exits
        // (`finish` clears the handlers).
        process.terminationHandler = { [self] proc in
            let status = proc.terminationStatus
            // Let the last lines arrive before reporting the exit.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [self] in
                finish(status: status)
            }
        }
        try process.run()
    }

    /// Sends one JSON line (`{"cmd":"stop"}`, `{"vars":{…}}`).
    func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.lock()
        let closed = stdinClosed || exited
        lock.unlock()
        guard !closed else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            AppLog.log("BrowserRecorder: runner stdin write failed: \(error.localizedDescription)")
        }
    }

    /// Asks politely (stop line), then SIGTERM after `grace`, SIGKILL 4 s later.
    func stop(grace: TimeInterval = 6) {
        send(["cmd": "stop"])
        let process = process
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace + 4) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func readStdout(_ chunk: Data) {
        var lines: [Data] = []
        lock.lock()
        if chunk.isEmpty {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            if !buffer.isEmpty { lines.append(buffer); buffer.removeAll() }
        } else {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        lock.unlock()
        let events = lines.compactMap { line -> BRRunnerEvent? in
            guard !line.isEmpty else { return nil }
            if let event = BRRunnerEvent.decode(line) { return event }
            AppLog.log("BrowserRecorder: runner said: \(String(decoding: line.prefix(300), as: UTF8.self))")
            return nil
        }
        guard !events.isEmpty else { return }
        let handler = onEvent
        // The main queue keeps the events in order (a Task per event would not).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for event in events { handler(event) }
            }
        }
    }

    private func readStderr(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if chunk.isEmpty {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        stderrTail.append(chunk)
        if stderrTail.count > 8192 { stderrTail = stderrTail.suffix(4096) }
    }

    private func finish(status: Int32) {
        lock.lock()
        guard !exited else { lock.unlock(); return }
        exited = true
        stdinClosed = true
        let rest = buffer
        buffer.removeAll()
        let tail = String(decoding: stderrTail.suffix(1500), as: UTF8.self)
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        let events = rest.isEmpty ? [] : [BRRunnerEvent.decode(rest)].compactMap { $0 }
        let eventHandler = onEvent
        let exitHandler = onExit
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for event in events { eventHandler(event) }
                exitHandler(status, tail)
            }
        }
    }
}
