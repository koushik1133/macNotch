import Darwin
import Foundation

/// Where SparkV stands with the privileged helper.
enum FanHelperState: Equatable, Sendable {
    /// No LaunchDaemon installed: speeds can be read, not set.
    case notInstalled
    /// Installed but its socket is missing (stopped, disabled in Login Items, crashed in a loop).
    case notRunning
    case connected
    /// The helper speaks another protocol version: reinstall from this SparkV.
    case outdated(String)
    /// The helper refused this app's code signature (rebuilt ad hoc, or a
    /// different certificate): reinstall from this SparkV.
    case unauthorized
    case failed(String)

    var canControl: Bool { self == .connected }

    var title: String {
        switch self {
        case .notInstalled: "Helper not installed"
        case .notRunning: "Helper not running"
        case .connected: "Helper connected"
        case .outdated: "Helper needs an update"
        case .unauthorized: "Helper does not trust this SparkV build"
        case .failed(let why): "Helper error: \(why)"
        }
    }
}

struct FanHelperClientError: Error, Equatable, Sendable {
    let state: FanHelperState
    let message: String
}

/// One persistent connection to the helper's Unix socket. Its lifetime is
/// what the helper watches: when SparkV quits or crashes the socket closes
/// and the helper returns every fan to Auto. Blocking I/O with 2 s
/// timeouts, on its own serial queue.
final class FanHelperClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sparkv.fans.helper-client", qos: .userInitiated)
    private let socketPath: String
    private let plistPath: String
    private var fd: Int32 = -1
    private var nextID = 1
    private var buffer = Data()
    /// The socket must belong to this user (root; tests use their own uid).
    private let requiredOwner: uid_t

    init(socketPath: String = FanHelperConstants.socketPath, plistPath: String = FanHelperConstants.launchdPlist,
         requiredOwner: uid_t = 0) {
        self.socketPath = socketPath
        self.plistPath = plistPath
        self.requiredOwner = requiredOwner
    }

    deinit { if fd >= 0 { close(fd) } }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    func send(_ command: FanCommand, completion: @escaping @Sendable (Result<FanHelperResponse, FanHelperClientError>) -> Void) {
        queue.async { [self] in completion(sendNow(command)) }
    }

    /// Blocks the caller until answered or timed out (quit and sleep paths).
    func sendAndWait(_ command: FanCommand) -> Result<FanHelperResponse, FanHelperClientError> {
        queue.sync { sendNow(command) }
    }

    func disconnect() {
        queue.sync { closeSocket() }
    }

    // MARK: Private (on `queue`)

    private func closeSocket() {
        if fd >= 0 { close(fd) }
        fd = -1
        buffer.removeAll()
    }

    private func sendNow(_ command: FanCommand) -> Result<FanHelperResponse, FanHelperClientError> {
        if fd < 0 {
            if let error = connectSocket() { return .failure(error) }
        }
        switch exchange(command) {
        case .success(let response):
            return .success(response)
        case .failure(let error):
            // One retry on a fresh connection: the helper may have restarted.
            closeSocket()
            guard error.state == .notRunning else { return .failure(error) }
            if let error = connectSocket() { return .failure(error) }
            let retry = exchange(command)
            if case .failure = retry { closeSocket() }
            return retry
        }
    }

    private func connectSocket() -> FanHelperClientError? {
        guard isInstalled else { return .init(state: .notInstalled, message: "not installed") }
        // Only a root-owned socket is the real helper (only root can write /var/run).
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { return .init(state: .notRunning, message: "no socket") }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == requiredOwner else {
            return .init(state: .failed("socket is not owned by root"), message: "untrusted socket")
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return .init(state: .failed("socket()"), message: "socket failed") }
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socketFD)
            return .init(state: .failed("socket path too long"), message: "path")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(socketFD)
            return .init(state: .notRunning, message: "connect failed (\(errno))")
        }
        fd = socketFD
        // Handshake: version check, and the helper's signature check answers here.
        switch exchange(.hello(version: FanHelperConstants.protocolVersion)) {
        case .success(let response) where response.ok:
            return nil
        case .success(let response):
            closeSocket()
            let message = response.error ?? "refused"
            if message.contains("not authorized") { return .init(state: .unauthorized, message: message) }
            if message.contains("version") { return .init(state: .outdated(message), message: message) }
            return .init(state: .failed(message), message: message)
        case .failure(let error):
            closeSocket()
            return error
        }
    }

    private func exchange(_ command: FanCommand) -> Result<FanHelperResponse, FanHelperClientError> {
        let id = nextID
        nextID &+= 1
        let data = FanRequestCodec.encode(command, id: id)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        // A failed write still reads on: a helper that refused this client at
        // accept wrote "not authorized" before closing, and that line is the answer.
        let wroteAll = written == data.count
        // Read until one full line; the helper answers every request with one.
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let response = try? JSONDecoder().decode(FanHelperResponse.self, from: Data(line)) else {
                    return .failure(.init(state: .failed("unreadable answer"), message: "decode"))
                }
                // An unsolicited refusal (id nil) from the accept check is still the answer.
                if let rid = response.id, rid != id { continue }
                return .success(response)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                return .failure(.init(state: .notRunning, message: !wroteAll ? "write failed" : count == 0 ? "closed" : "timeout"))
            }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > 256 * 1024 { return .failure(.init(state: .failed("answer too long"), message: "size")) }
        }
    }
}
