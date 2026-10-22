import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import Security

/// The root daemon's front end: a Unix stream socket at
/// `FanHelperConstants.socketPath`, one serial queue for everything
/// (accept, reads, the check timer, power and signal events), so the engine
/// never runs concurrently.
///
/// Every connection is checked before it may send a single command: the
/// peer's audit token (LOCAL_PEERTOKEN) is turned into a SecCode and must
/// satisfy the designated requirement of the SparkV build the user
/// installed from. Anyone else is refused and disconnected.
final class FanHelperServer: @unchecked Sendable {
    private final class Client {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    let queue = DispatchQueue(label: "com.sparkv.fanhelper")
    private let engine: FanHelperEngine
    private let requirement: SecRequirement
    private let socketPath: String
    private let log: (String) -> Void

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    /// The connection that last took manual control; its disconnect means
    /// SparkV quit or crashed.
    private var controllerFD: Int32?
    private var timer: DispatchSourceTimer?
    private var timerInterval: TimeInterval?
    private var signalSources: [DispatchSourceSignal] = []

    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    fileprivate var rootPowerPort: io_connect_t = 0

    static let maxClients = 4

    init(engine: FanHelperEngine, requirement: SecRequirement, socketPath: String = FanHelperConstants.socketPath,
         log: @escaping (String) -> Void) {
        self.engine = engine
        self.requirement = requirement
        self.socketPath = socketPath
        self.log = log
    }

    // MARK: Start

    func start() throws {
        try queue.sync {
            engine.start(now: Date())
            try openSocket()
            watchSignals()
            watchPower()
        }
    }

    private func openSocket() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        // Anyone may connect; the code signature check decides who may talk.
        chmod(socketPath, 0o666)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        listenSource = source
        log("listening on \(socketPath)")
    }

    // MARK: Clients

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard clients.count < Self.maxClients else {
                send(FanHelperResponse(id: nil, ok: false, error: "too many connections", status: nil), to: fd)
                close(fd)
                continue
            }
            if let reason = verifyPeer(fd) {
                log("refused a client: \(reason)")
                send(FanHelperResponse(id: nil, ok: false, error: "not authorized", status: nil), to: fd)
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let client = Client(fd: fd, source: source)
            source.setEventHandler { [weak self] in self?.readClient(fd) }
            source.setCancelHandler { close(fd) }
            clients[fd] = client
            source.resume()
        }
    }

    /// nil when the peer process satisfies the SparkV requirement.
    private func verifyPeer(_ fd: Int32) -> String? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return "no peer token" }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess, let code else {
            return "no code object for peer"
        }
        let status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        return status == errSecSuccess ? nil : "signature check failed (\(status))"
    }

    private func readClient(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 2048)
        let count = read(fd, &chunk, chunk.count)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
            drop(fd)
            return
        }
        guard count > 0 else { return }
        client.buffer.append(contentsOf: chunk[0..<count])
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer[client.buffer.startIndex..<newline]
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            handle(Data(line), from: fd)
            if clients[fd] == nil { return }
        }
        // A line longer than the protocol allows is a misbehaving client.
        if client.buffer.count > FanHelperConstants.maxLineBytes {
            send(FanHelperResponse(id: nil, ok: false, error: "request too long", status: nil), to: fd)
            drop(fd)
        }
    }

    private func handle(_ line: Data, from fd: Int32) {
        let response: FanHelperResponse
        switch FanRequestCodec.decode(line) {
        case .failure(let error):
            response = FanHelperResponse(id: nil, ok: false, error: error.message, status: nil)
        case .success(let request):
            let result = engine.handle(request.command, now: Date())
            if request.command.takesManualControl, result.ok { controllerFD = fd }
            response = FanHelperResponse(id: request.id, ok: result.ok, error: result.error, status: result.status)
        }
        send(response, to: fd)
        rescheduleTimer()
    }

    private func send(_ response: FanHelperResponse, to fd: Int32) {
        let data = response.encoded()
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        if written != data.count, clients[fd] != nil {
            // A client that does not read its answers is dropped.
            drop(fd)
        }
    }

    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.source.cancel()
        if controllerFD == fd || clients.isEmpty {
            controllerFD = nil
            engine.clientDisconnected(now: Date())
        }
        rescheduleTimer()
    }

    // MARK: Timer

    private func rescheduleTimer() {
        let wanted = engine.nextTickInterval
        guard wanted != timerInterval else { return }
        timer?.cancel()
        timer = nil
        timerInterval = wanted
        guard let wanted else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + wanted, repeating: wanted, leeway: .milliseconds(wanted < 0.5 ? 20 : 200))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.engine.tick(now: Date())
            self.rescheduleTimer()
        }
        source.resume()
        timer = source
    }

    // MARK: Signals and power

    private func watchSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.shutDown(signal: sig) }
            source.resume()
            signalSources.append(source)
        }
    }

    func shutDown(signal sig: Int32) {
        engine.returnAllToAuto(reason: "helper stopping (signal \(sig))", now: Date())
        unlink(socketPath)
        log("stopped")
        exit(0)
    }

    private func watchPower() {
        var notifier: io_object_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let root = IORegisterForSystemPower(context, &powerPort, fanHelperPowerCallback, &notifier)
        guard root != 0, let powerPort else {
            log("warning: no sleep notifications; SparkV still returns fans to Auto before sleep")
            return
        }
        rootPowerPort = root
        powerNotifier = notifier
        IONotificationPortSetDispatchQueue(powerPort, queue)
    }

    fileprivate func powerEvent(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        // kIOMessageCanSystemSleep 0xe0000270, kIOMessageSystemWillSleep 0xe0000280.
        switch message {
        case 0xE000_0270:
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        case 0xE000_0280:
            // The firmware clears Ftst over sleep anyway; leave nothing manual.
            engine.returnAllToAuto(reason: "system going to sleep", now: Date())
            rescheduleTimer()
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        default:
            break
        }
    }
}

private func fanHelperPowerCallback(_ context: UnsafeMutableRawPointer?, _ service: io_service_t,
                                    _ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<FanHelperServer>.fromOpaque(context).takeUnretainedValue().powerEvent(message, argument: argument)
}
