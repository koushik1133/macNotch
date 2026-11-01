import AppKit
import Combine
import SwiftUI

/// Sends files to Android, Windows and Linux devices running LocalSend on
/// the same network (the open LocalSend v2 protocol).
///
/// Safety rules: off until the user turns it on (it talks to other devices,
/// so it's off-Mac traffic and says so); it looks for devices only while the
/// Nearby panel is open (8 s, then stops); it talks only to private /
/// link-local IPv4 addresses; nothing is sent until the user picks a device
/// and clicks Send, and the other device then asks its user to accept;
/// HTTPS certificates must match the fingerprint the device announced;
/// files stream from disk and are never read into memory. SparkV never
/// listens for incoming files.
@MainActor
final class LocalSendController: ObservableObject {
    static let shared = LocalSendController()

    enum Phase: Equatable {
        case idle
        case searching
        /// Waiting for the receiver's Accept.
        case waiting(String)
        case sending(String)
        case sent(String, Int)
        case failed(String)
    }

    @Published private(set) var devices: [LocalSendDevice] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var files: [URL] = []
    @Published private(set) var skippedFolders = 0
    @Published var selectedDeviceID: String?
    /// macOS refused local network access.
    @Published private(set) var isBlocked = false
    /// Bytes sent / total for the running send.
    @Published private(set) var sentBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0

    let settings: ShelfSettings
    /// Random per launch; filters SparkV's own announcement echo.
    let fingerprint = LocalSendFingerprint.random()
    /// Test seam: also talk to 127.0.0.1.
    var allowsLoopback = false

    private let discovery = LocalSendDiscovery()
    private var sendTask: Task<Void, Never>?
    private var transferID: UUID?

    init(settings: ShelfSettings? = nil) {
        self.settings = settings ?? .shared
    }

    var isEnabled: Bool { settings.localSendEnabled }
    var isSearching: Bool { phase == .searching }
    var isBusy: Bool {
        switch phase {
        case .waiting, .sending: true
        default: false
        }
    }

    var selectedDevice: LocalSendDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var fraction: Double? {
        totalBytes > 0 ? min(1, Double(sentBytes) / Double(totalBytes)) : nil
    }

    // MARK: Files

    func setFiles(_ urls: [URL]) {
        guard !isBusy else { return }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        let entries = LocalSendFiles.entries(for: existing)
        files = entries.entries.map(\.url)
        skippedFolders = entries.skipped
        if case .sent = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        setFiles(files + panel.urls)
    }

    func removeFile(_ url: URL) {
        guard !isBusy else { return }
        files.removeAll { $0 == url }
    }

    var totalFileBytes: Int64 {
        files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])).flatMap { $0.totalFileSize ?? $0.fileSize } ?? 0) }
    }

    // MARK: Discovery

    /// The panel's "Turn On" button: the user's explicit go-ahead.
    func turnOnAndSearch() {
        settings.localSendEnabled = true
        AppLog.log("LocalSend: turned on by the user")
        search()
    }

    /// Looks for devices for a few seconds (only when turned on). The first
    /// search is what makes macOS ask about local network access.
    func search() {
        guard settings.localSendEnabled, !isBusy else { return }
        isBlocked = false
        phase = .searching
        // Devices not heard from in this search drop off at its end.
        let started = Date()
        let own = fingerprint
        let loopback = allowsLoopback
        discovery.start(
            announcement: .sparkV(alias: settings.effectiveAlias, fingerprint: own),
            onFound: { [weak self] announcement, host in
                guard let device = LocalSendDevice.from(announcement, host: host, ownFingerprint: own, allowLoopback: loopback) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.found(device) } }
            },
            onEnd: { [weak self] outcome in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.searchEnded(outcome, started: started) } }
            }
        )
        AppLog.log("LocalSend: searching")
    }

    func stopSearching() {
        discovery.stop()
    }

    func found(_ device: LocalSendDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            devices.sort { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
            AppLog.log("LocalSend: found a \(device.deviceType) device")
        }
        if selectedDeviceID == nil, devices.count == 1 { selectedDeviceID = device.id }
    }

    func searchEnded(_ outcome: LocalSendDiscovery.Outcome, started: Date) {
        devices.removeAll { $0.lastSeen < started.addingTimeInterval(-1) && $0.id != selectedDeviceID }
        if phase == .searching { phase = .idle }
        switch outcome {
        case .finished: break
        case .blocked:
            isBlocked = true
            AppLog.log("LocalSend: macOS blocked local network access")
        case .offline:
            phase = .failed("Not connected to a network. Join the same Wi-Fi as the other device, then search again.")
            AppLog.log("LocalSend: no network for the search")
        case .failed(let reason):
            phase = .failed("Couldn't search the network: \(reason)")
        }
    }

    func openLocalNetworkSettings() {
        PermissionCenter.shared.openLocalNetworkSettings(from: "LocalSend")
    }

    // MARK: Sending

    /// The Send button.
    func send() {
        guard settings.localSendEnabled, let device = selectedDevice, !isBusy else { return }
        guard LocalSendNetwork.isLocal(device.host, allowLoopback: allowsLoopback) else {
            phase = .failed("SparkV only sends to devices on your local network")
            return
        }
        let built = LocalSendFiles.entries(for: files)
        guard !built.entries.isEmpty else {
            phase = .failed(built.skipped > 0 ? "Folders can't be sent; zip them first" : "Nothing to send")
            return
        }
        discovery.stop()
        let entries = built.entries
        let total = entries.reduce(Int64(0)) { $0 + $1.meta.size }
        sentBytes = 0
        totalBytes = total
        phase = .waiting(device.alias)
        let name = entries.count == 1 ? entries[0].meta.fileName : "\(entries.count) files"
        let id = ShelfTransfersMonitor.shared.begin(kind: .localSend, name: name, destination: device.alias, total: total) { [weak self] in
            self?.cancel()
        }
        transferID = id
        ShelfTransfersMonitor.shared.setMessage(id: id, "Waiting for \(device.alias) to accept…")
        let request = LocalSendFiles.request(for: entries, alias: settings.effectiveAlias, fingerprint: fingerprint)
        AppLog.log("LocalSend: sending \(entries.count) file(s)")
        sendTask = Task { [weak self] in
            let session = LocalSendSession(device: device)
            defer { session.invalidate() }
            var remoteSession: String?
            do {
                switch try await session.prepare(request) {
                case .nothingToSend:
                    self?.finished(device: device, count: 0, id: id)
                    return
                case .accepted(let response):
                    remoteSession = response.sessionId
                    self?.phase = .sending(device.alias)
                    self?.reportProgress(0, id: id)
                    var base: Int64 = 0
                    var sentCount = 0
                    for entry in entries {
                        try Task.checkCancellation()
                        // The receiver may skip files it doesn't want (no token).
                        guard let token = response.files[entry.id] else { base += entry.meta.size; continue }
                        let offset = base
                        let report: @Sendable (Int64) -> Void = { [weak self] sent in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { self?.reportProgress(offset + sent, id: id) }
                            }
                        }
                        try await session.upload(entry, sessionID: response.sessionId, token: token, progress: report)
                        base += entry.meta.size
                        sentCount += 1
                    }
                    self?.finished(device: device, count: sentCount, id: id)
                }
            } catch {
                let failure = (error as? LocalSendSession.Failure) ?? (error is CancellationError ? .cancelled : .network(error.localizedDescription))
                if let remoteSession, failure == .cancelled { await session.cancelRemote(sessionID: remoteSession) }
                self?.failed(failure, id: id)
            }
        }
    }

    func cancel() {
        sendTask?.cancel()
    }

    fileprivate func reportProgress(_ bytes: Int64, id: UUID) {
        guard transferID == id else { return }
        sentBytes = min(bytes, totalBytes)
        ShelfTransfersMonitor.shared.progress(id: id, completed: sentBytes, message: nil)
    }

    private func finished(device: LocalSendDevice, count: Int, id: UUID) {
        sendTask = nil
        transferID = nil
        sentBytes = totalBytes
        phase = .sent(device.alias, count)
        ShelfTransfersMonitor.shared.finish(id: id, phase: .finished)
        AppLog.log("LocalSend: sent \(count) file(s)")
    }

    private func failed(_ failure: LocalSendSession.Failure, id: UUID) {
        sendTask = nil
        transferID = nil
        if failure == .cancelled {
            phase = .idle
            ShelfTransfersMonitor.shared.finish(id: id, phase: .cancelled)
        } else {
            phase = .failed(failure.message)
            ShelfTransfersMonitor.shared.finish(id: id, phase: .failed, message: failure.message)
        }
        AppLog.log("LocalSend: send ended (\(failure.message))")
    }

    /// The panel closed: stop looking, keep a running send going.
    func panelClosed() {
        discovery.stop()
        if case .sent = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }
}
