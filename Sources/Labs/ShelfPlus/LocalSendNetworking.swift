import Foundation
import Network
import Security

/// Looks for LocalSend devices on the local network for a few seconds.
///
/// Joins the LocalSend multicast group (UDP 224.0.0.167:53317), announces
/// SparkV three times (0, 1 and 3 s) and collects the devices that answer.
/// It runs only while the Nearby panel asks for it and stops on its own
/// after `duration`; no socket stays open. All state lives on one serial
/// queue; callbacks arrive on that queue.
final class LocalSendDiscovery: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case finished
        /// macOS refused local network access (Privacy & Security › Local Network).
        case blocked
        /// No usable network (Wi-Fi off, no route): not a permission problem.
        case offline
        case failed(String)
    }

    typealias FoundHandler = @Sendable (LocalSendAnnouncement, String) -> Void
    typealias EndHandler = @Sendable (Outcome) -> Void

    private let queue = DispatchQueue(label: "SparkV.LocalSend.discovery", qos: .userInitiated)
    private var group: NWConnectionGroup?
    private var pending: [DispatchWorkItem] = []
    private var onEnd: EndHandler?
    private var generation = 0

    /// Seconds of listening per search.
    static let duration: TimeInterval = 8
    static let announceDelays: [TimeInterval] = [0, 1, 3]

    func start(announcement: LocalSendAnnouncement, onFound: @escaping FoundHandler, onEnd: @escaping EndHandler) {
        guard let payload = try? JSONEncoder().encode(announcement) else { return onEnd(.failed("Couldn't build the announcement")) }
        queue.async { [self] in
            stopLocked(outcome: nil)
            generation &+= 1
            let current = generation
            self.onEnd = onEnd
            let group: NWConnectionGroup
            do {
                let host = NWEndpoint.Host(LocalSendProtocol.multicastHost)
                guard let port = NWEndpoint.Port(rawValue: LocalSendProtocol.port) else { return }
                let multicast = try NWMulticastGroup(for: [.hostPort(host: host, port: port)])
                let parameters = NWParameters.udp
                // LocalSend itself may be running on this Mac on the same port.
                parameters.allowLocalEndpointReuse = true
                // Never over a phone hotspot's cellular side or a VPN tunnel
                // (they don't carry the LAN's multicast).
                parameters.prohibitedInterfaceTypes = [.cellular, .other]
                group = NWConnectionGroup(with: multicast, using: parameters)
            } catch {
                return finishLocked(.failed(error.localizedDescription))
            }
            group.setReceiveHandler(maximumMessageSize: 16_384, rejectOversizedMessages: true) { message, content, _ in
                guard let content, let endpoint = message.remoteEndpoint, case .hostPort(let host, _) = endpoint,
                      case .ipv4(let address) = host,
                      let announcement = try? JSONDecoder().decode(LocalSendAnnouncement.self, from: content)
                else { return }
                onFound(announcement, Self.string(address))
            }
            group.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.scheduleAnnouncements(payload, generation: current)
                case .failed(let error):
                    self.finishLocked(Self.outcome(for: error))
                case .waiting(let error):
                    let outcome = Self.outcome(for: error)
                    if outcome == .blocked || outcome == .offline { self.finishLocked(outcome) }
                default:
                    break
                }
            }
            self.group = group
            group.start(queue: queue)
            let stop = DispatchWorkItem { [weak self] in
                guard let self, self.generation == current else { return }
                self.finishLocked(.finished)
            }
            pending.append(stop)
            queue.asyncAfter(deadline: .now() + Self.duration, execute: stop)
        }
    }

    func stop() {
        queue.async { [self] in stopLocked(outcome: .finished) }
    }

    // MARK: Queue-only

    private func scheduleAnnouncements(_ payload: Data, generation current: Int) {
        for delay in Self.announceDelays {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == current, let group = self.group else { return }
                group.send(content: payload) { [weak self] error in
                    guard let error, let self else { return }
                    self.queue.async {
                        guard self.generation == current else { return }
                        let outcome = Self.outcome(for: error)
                        if outcome == .blocked || outcome == .offline {
                            self.finishLocked(outcome)
                        } else {
                            AppLog.log("LocalSend: announcement failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
            pending.append(work)
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func finishLocked(_ outcome: Outcome) {
        stopLocked(outcome: outcome)
    }

    private func stopLocked(outcome: Outcome?) {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        group?.stateUpdateHandler = nil
        group?.cancel()
        group = nil
        if let outcome, let onEnd {
            self.onEnd = nil
            onEnd(outcome)
        }
    }

    /// Local Network privacy refusals surface as "not permitted" or the DNS
    /// policy error. "No route" and "network down" mean there's no network
    /// (Wi-Fi off), which Privacy settings can't fix.
    static func isPolicyDenied(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code): return code == .EPERM || code == .EACCES
        case .dns(let code): return code == -65570 // kDNSServiceErr_PolicyDenied
        default: return false
        }
    }

    static func isOffline(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .EHOSTUNREACH || code == .ENETUNREACH || code == .ENETDOWN || code == .EADDRNOTAVAIL
        }
        return false
    }

    static func outcome(for error: NWError) -> Outcome {
        if isPolicyDenied(error) { return .blocked }
        if isOffline(error) { return .offline }
        return .failed(error.localizedDescription)
    }

    static func string(_ address: IPv4Address) -> String {
        address.rawValue.map(String.init).joined(separator: ".")
    }
}

/// One LocalSend send session to one device: prepare (the receiver says yes
/// or no), then each file streamed from disk. The HTTPS certificate must
/// hash to the fingerprint the device announced; anything else is refused.
/// Redirects are never followed.
final class LocalSendSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable {
        case http(Int, String)
        case declined
        case untrusted
        case badResponse
        case cancelled
        case network(String)

        var message: String {
            switch self {
            case .http(_, let text): text
            case .declined: "The other device declined"
            case .untrusted: "That device's security certificate didn't match what it announced, so nothing was sent"
            case .badResponse: "The device sent an answer SparkV couldn't read"
            case .cancelled: "Cancelled"
            case .network(let text): text
            }
        }
    }

    enum Prepared: Equatable, Sendable {
        case accepted(LocalSendPrepareResponse)
        /// 204: nothing to transfer.
        case nothingToSend
    }

    let device: LocalSendDevice
    private var session: URLSession!
    private let lock = NSLock()
    private var untrusted = false

    /// `acceptTimeout`: how long the receiver may take to tap Accept.
    init(device: LocalSendDevice, acceptTimeout: TimeInterval = 120) {
        self.device = device
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = acceptTimeout
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Ends the URLSession (it holds its delegate until then).
    func invalidate() {
        session.invalidateAndCancel()
    }

    func prepare(_ body: LocalSendPrepareRequest) async throws -> Prepared {
        guard let url = device.url("prepare-upload") else { throw Failure.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform { try await self.session.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        switch http.statusCode {
        case 200:
            guard let decoded = try? JSONDecoder().decode(LocalSendPrepareResponse.self, from: data) else { throw Failure.badResponse }
            return .accepted(decoded)
        case 204:
            return .nothingToSend
        case 403:
            throw Failure.declined
        default:
            throw Failure.http(http.statusCode, LocalSendStatus.message(forPrepareStatus: http.statusCode) ?? "Error \(http.statusCode)")
        }
    }

    /// Streams one file. `progress` gets the bytes sent so far (on a background queue).
    func upload(_ entry: LocalSendFiles.Entry, sessionID: String, token: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let url = device.url("upload", query: ["sessionId": sessionID, "fileId": entry.id, "token": token]) else {
            throw Failure.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(entry.meta.fileType, forHTTPHeaderField: "Content-Type")
        let reporter = LocalSendUploadReporter(progress)
        let (_, response) = try await perform { try await self.session.upload(for: request, fromFile: entry.url, delegate: reporter) }
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode == 200 else {
            throw Failure.http(http.statusCode, http.statusCode == 403 ? "The device stopped accepting files" : "Upload failed (\(http.statusCode))")
        }
    }

    /// Tells the receiver to drop the session (best effort, short timeout).
    func cancelRemote(sessionID: String) async {
        guard let url = device.url("cancel", query: ["sessionId": sessionID]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        _ = try? await session.data(for: request)
    }

    private func perform<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as Failure {
            throw error
        } catch is CancellationError {
            throw Failure.cancelled
        } catch let error as URLError {
            if error.code == .cancelled {
                throw lock.withLock({ untrusted }) ? Failure.untrusted : Failure.cancelled
            }
            if error.code == .serverCertificateUntrusted || error.code == .secureConnectionFailed { throw Failure.untrusted }
            if error.code == .timedOut { throw Failure.network("No answer from \(device.alias). Is LocalSend open there?") }
            throw Failure.network(error.localizedDescription)
        }
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        guard device.usesTLS, space.host == device.host, let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              LocalSendFingerprint.matches(certificateDER: SecCertificateCopyData(leaf) as Data, announced: device.fingerprint)
        else {
            lock.withLock { untrusted = true }
            AppLog.log("LocalSend: certificate of \(device.host) doesn't match its fingerprint; refusing")
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Upload progress for one task, at most ten reports a second (a fast LAN
/// calls back for every chunk).
final class LocalSendUploadReporter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var last: TimeInterval = 0
    static let interval: TimeInterval = 0.1

    init(_ progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        let due = lock.withLock { () -> Bool in
            let finished = totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend
            guard finished || now - last >= Self.interval else { return false }
            last = now
            return true
        }
        if due { progress(totalBytesSent) }
    }
}
