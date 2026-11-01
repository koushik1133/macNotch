import AppKit
import Foundation

// MARK: - Pure model (BEGIN harness)

/// Local dev servers: TCP ports your own processes listen on, found with
/// public libproc (no lsof, no root, no permission). Sampled only while the
/// Servers page is on screen (every 4 s), never in the background.
struct DevServer: Identifiable, Equatable, Sendable {
    let port: UInt16
    let pid: Int32
    let process: String
    let folder: String?
    let isLoopbackOnly: Bool

    var id: String { "\(pid):\(port)" }
    var url: URL? { URL(string: "http://localhost:\(port)") }

    /// "my-app" (the working folder) or the process name.
    var title: String {
        if let folder, folder != "/" { return ExtrasFormat.folderName(folder) }
        return process
    }
}

enum DevServerFilter {
    /// Processes that listen on ports but aren't dev servers.
    static let systemProcesses: Set<String> = [
        "ControlCenter", "rapportd", "SparkV", "sharingd", "identityservicesd", "Spotify", "Dropbox",
        "Raycast", "Figma", "figma_agent", "Adobe Desktop Service", "CCLibrary", "Creative Cloud",
        "AirPlayXPCHelper", "WiFiAgent", "Google Chrome Helper", "Code Helper", "Cursor Helper",
        "OneDrive", "zoom.us", "Microsoft Teams", "Slack Helper", "Discord Helper",
    ]

    /// True for a listener that looks like something you started for
    /// development: a user process with a project folder, not an app bundle.
    static func isDevServer(process: String, folder: String?, executable: String?) -> Bool {
        if systemProcesses.contains(process) { return false }
        if let executable, executable.contains(".app/Contents/"), !executable.contains("/Developer/") {
            // App helpers (Chrome, Electron apps), unless it's a tool inside Xcode.
            return false
        }
        guard let folder, folder != "/" else { return false }
        return true
    }

    static func sorted(_ servers: [DevServer]) -> [DevServer] {
        servers.sorted { $0.port < $1.port }
    }
}

// MARK: - Pure model (END harness)

@MainActor
final class DevServersController: ObservableObject {
    static let shared = DevServersController()

    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var lastScan: Date?
    /// Show every listening process of yours, not just dev servers.
    @Published var showsAll: Bool { didSet { UserDefaults.standard.set(showsAll, forKey: "SparkV.devServers.showAll"); scanNow() } }

    private var viewers = 0
    private var loop: Task<Void, Never>?
    private static let interval: Duration = .seconds(4)

    init() {
        showsAll = UserDefaults.standard.bool(forKey: "SparkV.devServers.showAll")
    }

    /// Reference-counted: the Servers page calls these on appear/disappear.
    func beginViewing() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.scanNow()
                try? await Task.sleep(for: SparkVEnergy.shared.duration(Self.interval))
            }
        }
    }

    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    func stop() {
        viewers = 0
        loop?.cancel()
        loop = nil
    }

    func scanNow() {
        let all = showsAll
        Task.detached(priority: .utility) {
            let found = Self.scan(includeAll: all)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.servers != found { self.servers = found }
                self.lastScan = Date()
            }
        }
    }

    nonisolated static func scan(includeAll: Bool) -> [DevServer] {
        let own = getpid()
        var result: [DevServer] = []
        for pid in LocalProcesses.userPIDs() where pid != own {
            let listeners = LocalProcesses.listeners(of: pid)
            guard !listeners.isEmpty else { continue }
            let name = LocalProcesses.name(of: pid)
            let folder = LocalProcesses.workingDirectory(of: pid)
            if !includeAll, !DevServerFilter.isDevServer(process: name, folder: folder, executable: LocalProcesses.path(of: pid)) { continue }
            for listener in listeners {
                result.append(DevServer(port: listener.port, pid: pid, process: name, folder: folder, isLoopbackOnly: listener.isLoopbackOnly))
            }
        }
        // One row per port (IPv4 and IPv6 listeners of the same server).
        var seen = Set<UInt16>()
        return DevServerFilter.sorted(result).filter { seen.insert($0.port).inserted }
    }

    func open(_ server: DevServer) {
        guard let url = server.url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyURL(_ server: DevServer) {
        guard let url = server.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func revealFolder(_ server: DevServer) {
        guard let folder = server.folder else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
    }

    /// Asks the server to quit (SIGTERM), only from an explicit menu choice.
    func stopServer(_ server: DevServer) {
        guard server.pid > 1, server.pid != getpid() else { return }
        kill(server.pid, SIGTERM)
        AppLog.log("Dev Servers: sent SIGTERM to a process on port \(server.port)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.scanNow()
        }
    }
}
