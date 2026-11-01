import Foundation

/// Runs one shell command with a hard timeout and an output cap: stdin is
/// /dev/null, stdout and stderr are read as they arrive (so a chatty command
/// can't block on a full pipe), and on timeout the shell and everything it
/// started (pipelines, `a && b`, subshells) get SIGINT, then SIGTERM after
/// 2 s, then SIGKILL after 4 s. A background child that keeps the pipe open
/// can't hold the result past the exit plus 1 s.
enum ScriptRunner {
    struct Result: Equatable, Sendable {
        var output: String
        var errorOutput: String
        var exitCode: Int32
        var timedOut: Bool
        var duration: TimeInterval
    }

    static let shell = URL(fileURLWithPath: "/bin/zsh")

    static func run(_ command: String, timeout: TimeInterval, outputLimit: Int = 16 * 1024) async -> Result {
        await withCheckedContinuation { continuation in
            let job = ScriptJob(command: command, outputLimit: outputLimit) { continuation.resume(returning: $0) }
            job.start(timeout: timeout)
        }
    }
}

private final class ScriptJob: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSCondition()
    private var output = Data()
    private var errorOutput = Data()
    private var openStreams = 2
    private var closed = false
    private var timedOut = false
    private var finished = false
    private let limit: Int
    private let started = Date()
    private let completion: @Sendable (ScriptRunner.Result) -> Void

    init(command: String, outputLimit: Int, completion: @escaping @Sendable (ScriptRunner.Result) -> Void) {
        limit = outputLimit
        self.completion = completion
        process.executableURL = ScriptRunner.shell
        // A login shell, so the PATH from ~/.zprofile (Homebrew, nvm) applies.
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["SPARKV_SCRIPT"] = "1"
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
    }

    func start(timeout: TimeInterval) {
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in read(handle, error: false) }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in read(handle, error: true) }
        process.terminationHandler = { [self] _ in
            DispatchQueue.global(qos: .utility).async { self.exited() }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            closePipes()
            finish(ScriptRunner.Result(output: "", errorOutput: "Couldn't start /bin/zsh: \(error.localizedDescription)",
                                       exitCode: -1, timedOut: false, duration: 0))
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in self?.timeoutFired() }
    }

    private func timeoutFired() {
        guard process.isRunning else { return }
        lock.withLock { timedOut = true }
        let pid = process.processIdentifier
        // zsh execs in place only for one simple command; with a pipeline,
        // `&&` or a `cd` first it stays the parent. Its children are found
        // before each signal (once zsh is gone they'd be orphans out of
        // reach). No process-group kill: the group is SparkV's own.
        let first = LocalProcesses.descendants(of: pid)
        Self.signal([pid] + first, SIGINT)
        let process = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            let tree = Self.tree(pid, process: process, known: first)
            if process.isRunning { process.terminate() }
            Self.signal(tree, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                let all = Self.tree(pid, process: process, known: tree)
                Self.signal((process.isRunning ? [pid] : []) + all, SIGKILL)
            }
        }
    }

    /// `known` plus whatever the shell started since, if it still runs.
    private static func tree(_ pid: pid_t, process: Process, known: [pid_t]) -> [pid_t] {
        guard process.isRunning else { return known }
        let now = LocalProcesses.descendants(of: pid)
        return known + now.filter { !known.contains($0) }
    }

    private static func signal(_ pids: [pid_t], _ signal: Int32) {
        for pid in pids where pid > 0 && pid != getpid() && LocalProcesses.isAlive(pid) {
            kill(pid, signal)
        }
    }

    private func read(_ handle: FileHandle, error: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            openStreams -= 1
            lock.broadcast()
            return
        }
        if error {
            if errorOutput.count < limit { errorOutput.append(chunk.prefix(limit - errorOutput.count)) }
        } else if output.count < limit {
            output.append(chunk.prefix(limit - output.count))
        }
    }

    private func exited() {
        lock.lock()
        let deadline = Date().addingTimeInterval(1)
        while openStreams > 0, lock.wait(until: deadline) {}
        lock.unlock()
        closePipes()
        process.terminationHandler = nil
        let (out, err, timedOut) = lock.withLock { (output, errorOutput, self.timedOut) }
        finish(ScriptRunner.Result(
            output: String(decoding: out, as: UTF8.self),
            errorOutput: String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus, timedOut: timedOut,
            duration: Date().timeIntervalSince(started)
        ))
    }

    private func closePipes() {
        let wasClosed = lock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        handles.forEach { $0.readabilityHandler = nil }
        lock.withLock { handles.forEach { try? $0.close() } }
    }

    private func finish(_ result: ScriptRunner.Result) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        if first { completion(result) }
    }
}
