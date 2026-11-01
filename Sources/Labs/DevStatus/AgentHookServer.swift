import Foundation
import Network

/// The optional local hook endpoint: HTTP on 127.0.0.1 only (never on the
/// network), one request per connection, a per-install token, and no
/// requests from browsers (see `AgentHTTP.rejection`). A hook that waits for
/// Allow / Deny keeps its connection open until `reply` is called or the
/// controller's timeout answers "ask".
///
/// Everything here runs on one private serial queue; the controller gets
/// requests on the main actor through `onRequest`.
final class AgentHookServer: @unchecked Sendable {
    /// Answers one request exactly once (later calls do nothing).
    struct Reply: Sendable {
        /// Identifies the request (and its connection) for `onClientGone`.
        let id: UUID
        fileprivate let send: @Sendable (_ status: Int, _ body: Data) -> Void
        func callAsFunction(status: Int = 200, body: Data = Data()) { send(status, body) }
    }

    enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// Called on the main actor for every accepted request.
    var onRequest: (@MainActor @Sendable (AgentHTTPRequest, Reply) -> Void)?
    /// Called on the main actor when the state changes.
    var onState: (@MainActor @Sendable (State) -> Void)?
    /// Called on the main actor when a client hung up before its answer
    /// (e.g. you answered in the terminal and the tool ended the hook).
    var onClientGone: (@MainActor @Sendable (UUID) -> Void)?

    private let queue = DispatchQueue(label: "SparkV.AgentHookServer", qos: .userInitiated)
    private var listener: NWListener?
    private var token = ""
    private var port: UInt16 = 0
    private var candidates: [UInt16] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Starts on the first free port of `ports` (bound to 127.0.0.1).
    func start(ports: [UInt16], token: String) {
        queue.async { [self] in
            stopLocked()
            self.token = token
            candidates = ports
            publish(.starting)
            tryNextPort()
        }
    }

    func stop() {
        queue.async { [self] in
            stopLocked()
            publish(.stopped)
        }
    }

    func updateToken(_ token: String) {
        queue.async { [self] in self.token = token }
    }

    // MARK: Queue-confined

    private func stopLocked() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        port = 0
    }

    private func tryNextPort() {
        guard !candidates.isEmpty else {
            publish(.failed("No free local port for the hook endpoint."))
            return
        }
        let next = candidates.removeFirst()
        guard let nwPort = NWEndpoint.Port(rawValue: next) else { tryNextPort(); return }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            tryNextPort()
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.queue.async { self.listenerChanged(listener, state, port: next) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.queue.async { self.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func listenerChanged(_ changed: NWListener, _ state: NWListener.State, port: UInt16) {
        guard changed === listener else { return }
        switch state {
        case .ready:
            self.port = port
            publish(.listening(port: port))
        case .failed:
            changed.cancel()
            listener = nil
            tryNextPort()
        case .waiting:
            // Address in use: move on.
            changed.cancel()
            listener = nil
            tryNextPort()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        // Loopback only, as a second guard to the listener's endpoint.
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address) where address.isLoopback: break
            case .ipv6(let address) where address.isLoopback: break
            default:
                connection.cancel()
                return
            }
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                self.queue.async { self.connections[id] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // A client that never finishes its request is dropped after 10 s.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil, connection.state != .cancelled else { return }
            if self.awaitingBody.contains(id) { self.respond(connection, status: 408, body: Data()) }
        }
        awaitingBody.insert(id)
    }

    private var awaitingBody = Set<ObjectIdentifier>()

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                var buffer = buffer
                if let data { buffer.append(data) }
                switch AgentHTTP.parse(buffer) {
                case .needMore:
                    if isComplete || error != nil {
                        self.respond(connection, status: 400, body: Data())
                    } else {
                        self.receive(on: connection, buffer: buffer)
                    }
                case .invalid(let status):
                    self.respond(connection, status: status, body: Data())
                case .complete(let request):
                    self.awaitingBody.remove(ObjectIdentifier(connection))
                    self.handle(request, on: connection)
                }
            }
        }
    }

    private func handle(_ request: AgentHTTPRequest, on connection: NWConnection) {
        if let status = AgentHTTP.rejection(request, token: token, port: port) {
            respond(connection, status: status, body: Data())
            return
        }
        let once = OnceFlag()
        let id = UUID()
        let reply = Reply(id: id) { [weak self, weak connection] status, body in
            guard once.claim(), let self, let connection else { return }
            self.queue.async { self.respond(connection, status: status, body: body) }
        }
        // The client sends nothing more; a read that ends means it hung up.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard isComplete || error != nil, once.claim(), let self else { return }
            connection.cancel()
            if let gone = self.onClientGone {
                Task { @MainActor in gone(id) }
            }
        }
        guard let onRequest else {
            reply(status: 200)
            return
        }
        Task { @MainActor in onRequest(request, reply) }
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data) {
        let id = ObjectIdentifier(connection)
        awaitingBody.remove(id)
        let data = AgentHTTP.response(status: status, body: body)
        connection.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            guard let self else { return }
            self.queue.async { self.connections[id] = nil }
        })
    }

    private func publish(_ state: State) {
        guard let onState else { return }
        Task { @MainActor in onState(state) }
    }
}

/// Thread-safe "first caller wins".
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Writes small secrets (the hook token) so no other user can read them at
/// any moment: a new 0600 file next to the target, then an atomic rename.
enum PrivateFile {
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return buffer.count == 0 }
            return Foundation.write(fd, base, buffer.count) == buffer.count
        }
        fchmod(fd, 0o600)
        close(fd)
        guard written, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            return false
        }
        return true
    }
}
