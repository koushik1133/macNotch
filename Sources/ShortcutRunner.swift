import Foundation

enum ShortcutError: LocalizedError {
    case launchFailed(Error)
    case timedOut
    case failed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let error): "Could not start shortcuts: \(error.localizedDescription)"
        case .timedOut: "The shortcut took too long and was stopped."
        case .failed(let status, let message):
            message.isEmpty ? "The shortcut exited with status \(status)." : message
        }
    }
}

/// Runs macOS Shortcuts through `/usr/bin/shortcuts` off the main thread.
struct ShortcutRunner: Sendable {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

    var timeout: TimeInterval = 60

    /// Runs `shortcuts run <name>` and returns its stdout. Throws
    /// `ShortcutError` on launch failure, timeout or a non-zero exit status.
    /// The CLI takes a shortcut's identifier in place of its name too.
    func run(_ shortcutName: String) async throws -> String {
        try await execute(["run", shortcutName], timeout: timeout)
    }

    /// Names of every shortcut in the user's library, in library order.
    func listShortcuts() async throws -> [String] {
        let output = try await execute(["list"], timeout: 15)
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Every shortcut with its identifier (`shortcuts list --show-identifiers`),
    /// which survives renames; one process, like `listShortcuts()`. A folder
    /// name (or identifier) lists just that folder.
    func listShortcutsWithIdentifiers(folder: String? = nil) async throws -> [ShortcutInfo] {
        var arguments = ["list", "--show-identifiers"]
        if let folder { arguments += ["--folder-name", folder] }
        return ShortcutListParser.parse(try await execute(arguments, timeout: 15))
    }

    /// Folder names in the Shortcuts library.
    func listFolders() async throws -> [String] {
        let output = try await execute(["list", "--folders"], timeout: 15)
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func execute(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ShortcutProcess(arguments: arguments, continuation: continuation).start(timeout: timeout)
        }
    }
}

/// One `shortcuts` invocation.
///
/// Output is collected with readability handlers and the run ends when the
/// process exits, not when its pipes reach EOF: a shortcut that starts a
/// background process hands it our pipes, so EOF may never come. After exit
/// it waits at most `trailingOutputWait` for the last output, then closes the
/// pipes and resumes the continuation exactly once.
private final class ShortcutProcess: @unchecked Sendable {
    private static let trailingOutputWait: TimeInterval = 0.5

    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    // Guards everything below.
    private let condition = NSCondition()
    private var output = Data()
    private var errorOutput = Data()
    private var openStreams = 2
    private var isClosed = false
    private var timedOut = false
    private var continuation: CheckedContinuation<String, Error>?

    init(arguments: [String], continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
        process.executableURL = ShortcutRunner.executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start(timeout: TimeInterval) {
        // The handlers and the termination handler keep `self` alive until
        // `finish()` clears them.
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in read(handle, isError: false) }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in read(handle, isError: true) }
        process.terminationHandler = { [self] _ in
            DispatchQueue.global(qos: .userInitiated).async { self.processExited() }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            closePipes()
            resume(with: .failure(ShortcutError.launchFailed(error)))
            return
        }

        // On timeout: SIGINT first (the CLI's own cancel path), then
        // SIGTERM, then SIGKILL for a shortcut that ignores both.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.timeoutFired()
        }
    }

    private func timeoutFired() {
        guard process.isRunning else { return }
        condition.withLock { timedOut = true }
        process.interrupt()
        let process = process
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func read(_ handle: FileHandle, isError: Bool) {
        condition.lock()
        defer { condition.unlock() }
        // The pipe may already be closed by `finish()`; reading it then would raise.
        guard !isClosed else { return }
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            openStreams -= 1
            condition.broadcast()
        } else if isError {
            errorOutput.append(chunk)
        } else {
            output.append(chunk)
        }
    }

    private func processExited() {
        condition.lock()
        let deadline = Date().addingTimeInterval(Self.trailingOutputWait)
        while openStreams > 0, condition.wait(until: deadline) {}
        if openStreams > 0 {
            AppLog.log("Shortcuts: output pipe still open after exit (a background process kept it); closing it")
        }
        condition.unlock()

        closePipes()
        process.terminationHandler = nil

        let (output, errorOutput, timedOut) = condition.withLock { (self.output, self.errorOutput, self.timedOut) }
        if timedOut {
            resume(with: .failure(ShortcutError.timedOut))
            return
        }
        let status = process.terminationStatus
        guard status == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            resume(with: .failure(ShortcutError.failed(status: status, message: message)))
            return
        }
        resume(with: .success(String(decoding: output, as: UTF8.self)))
    }

    private func closePipes() {
        let wasClosed = condition.withLock {
            defer { isClosed = true }
            return isClosed
        }
        guard !wasClosed else { return }
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        // Outside the lock, so an in-flight handler can finish; any handler
        // that runs afterwards sees `isClosed` and leaves the handle alone.
        handles.forEach { $0.readabilityHandler = nil }
        // Under the lock, so the handles never close mid-read.
        condition.withLock {
            for handle in handles { try? handle.close() }
        }
    }

    private func resume(with result: Result<String, Error>) {
        let pending = condition.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}
