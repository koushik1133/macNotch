import AppKit
import Combine
import DiskArbitration
import Network
import SwiftUI

/// Short connection alerts: no internet / back online, VPN connected or
/// disconnected, Personal Hotspot joined, and "safe to remove" when an
/// external drive is ejected (or "removed without ejecting").
///
/// Event driven, and nothing leaves the Mac: NWPathMonitor for the path
/// (no pinging, no captive-portal probe), a getifaddrs scan of tunnel
/// interfaces on each path change for VPNs (macOS's own utun0-3 carry only
/// link-local addresses and are ignored), NSWorkspace mount notifications
/// and DiskArbitration's disk-disappeared callback for drives. Going
/// offline must last 4 s before it alerts, nothing alerts in the 10 s after
/// wake, and every alert stays quiet while the screen is shared. The
/// hotspot is a heuristic (iPhone hotspots mark Wi-Fi "expensive"); the
/// network name would need Location permission, so it isn't read.
@MainActor
final class ConnectivityMonitor: ObservableObject {
    static let shared = ConnectivityMonitor()

    static let enabledKey = "connectivity.isEnabled"
    static let offlineKey = "connectivity.offline"
    static let vpnKey = "connectivity.vpn"
    static let hotspotKey = "connectivity.hotspot"
    static let drivesKey = "connectivity.drives"
    static let activityID = "connectivity"
    static let driveActivityID = "connectivity.drive"

    @Published var isEnabled: Bool {
        didSet { guard isEnabled != oldValue else { return }; StatusDefaults.set(isEnabled, Self.enabledKey); apply() }
    }
    @Published var alertsOffline: Bool { didSet { StatusDefaults.set(alertsOffline, Self.offlineKey) } }
    @Published var alertsVPN: Bool { didSet { StatusDefaults.set(alertsVPN, Self.vpnKey) } }
    @Published var alertsHotspot: Bool { didSet { StatusDefaults.set(alertsHotspot, Self.hotspotKey) } }
    @Published var alertsDrives: Bool {
        didSet { guard alertsDrives != oldValue else { return }; StatusDefaults.set(alertsDrives, Self.drivesKey); apply() }
    }

    /// The latest path, for the Status page.
    @Published private(set) var observation: NetworkObservation?

    private var isStarted = false
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "SparkV.Connectivity", qos: .utility)
    private var tracker = ConnectivityTracker()
    private var deadlineTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    // Drives
    private var driveObservers: [NSObjectProtocol] = []
    private var session: DASession?
    /// Mounted removable volumes by path: name and BSD name (from the mount).
    private var volumes: [String: (name: String, bsd: String?)] = [:]
    /// Requested unmounts/ejects and disappearances, by BSD name.
    private var removals = DriveRemovalTracker()

    private init() {
        isEnabled = StatusDefaults.bool(Self.enabledKey, default: true)
        alertsOffline = StatusDefaults.bool(Self.offlineKey, default: true)
        alertsVPN = StatusDefaults.bool(Self.vpnKey, default: true)
        alertsHotspot = StatusDefaults.bool(Self.hotspotKey, default: true)
        alertsDrives = StatusDefaults.bool(Self.drivesKey, default: true)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        apply()
    }

    func stop() {
        isStarted = false
        apply()
    }

    // MARK: Lifecycle

    private func apply() {
        let wantsPath = isStarted && isEnabled
        if wantsPath, monitor == nil {
            tracker = ConnectivityTracker()
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { [weak self] path in
                // On `queue`: scan tunnels here, then hand plain values over.
                let observation = Self.observation(for: path)
                Task { @MainActor [weak self] in self?.handle(observation) }
            }
            pathMonitor.start(queue: queue)
            monitor = pathMonitor
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tracker.noteWake(at: Date())
                    self.scheduleDeadline()
                }
            }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A deadline armed just before sleep must not fire on wake.
                    self.deadlineTask?.cancel()
                    self.deadlineTask = nil
                    self.tracker.noteSleep()
                }
            }
            AppLog.log("Connectivity: watching the network")
        } else if !wantsPath, let pathMonitor = monitor {
            pathMonitor.cancel()
            monitor = nil
            deadlineTask?.cancel()
            deadlineTask = nil
            observation = nil
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
            wakeObserver = nil
            if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
            sleepObserver = nil
            SystemStatusCenter.shared.dismiss(id: Self.activityID)
        }
        if wantsPath, alertsDrives { startDrives() } else { stopDrives() }
    }

    // MARK: Path

    nonisolated private static func observation(for path: NWPath) -> NetworkObservation {
        let interface: NetworkInterfaceKind
        if path.status != .satisfied { interface = .none }
        else if path.usesInterfaceType(.wifi) { interface = .wifi }
        else if path.usesInterfaceType(.wiredEthernet) { interface = .ethernet }
        else if path.usesInterfaceType(.cellular) { interface = .cellular }
        else { interface = .other }
        return NetworkObservation(
            isOnline: path.status == .satisfied,
            interface: interface,
            isExpensive: path.isExpensive,
            tunnels: TunnelInterfaceFilter.activeTunnels(readInterfaces())
        )
    }

    /// getifaddrs, as plain values.
    nonisolated private static func readInterfaces() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(InterfaceAddress(
                name: String(cString: entry.pointee.ifa_name),
                isIPv4: family == AF_INET,
                address: address,
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
            ))
        }
        return result
    }

    private func handle(_ new: NetworkObservation) {
        guard monitor != nil else { return }
        observation = new
        let events = tracker.update(new, at: Date())
        events.forEach(announce)
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let due = tracker.nextDeadline else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, due.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.tracker.tick(now: Date()).forEach(self.announce)
        }
    }

    // MARK: Drives

    private func startDrives() {
        guard driveObservers.isEmpty else { return }
        if let newSession = DASessionCreate(kCFAllocatorDefault) {
            DASessionScheduleWithRunLoop(newSession, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let context = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskDisappearedCallback(newSession, nil, { disk, context in
                guard let context, let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
                // Scheduled on the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<ConnectivityMonitor>.fromOpaque(context).takeUnretainedValue().diskDisappeared(bsd)
                }
            }, context)
            // Approval callbacks run only for a requested unmount or eject
            // (Finder, Disk Utility, diskutil), never for a drive pulled
            // out. Returning nil approves at once; nothing is ever blocked.
            DARegisterDiskUnmountApprovalCallback(newSession, nil, { disk, context in
                if let context, let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) {
                    MainActor.assumeIsolated {
                        Unmanaged<ConnectivityMonitor>.fromOpaque(context).takeUnretainedValue().removalRequested(bsd)
                    }
                }
                return nil
            }, context)
            DARegisterDiskEjectApprovalCallback(newSession, nil, { disk, context in
                if let context, let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) {
                    MainActor.assumeIsolated {
                        Unmanaged<ConnectivityMonitor>.fromOpaque(context).takeUnretainedValue().removalRequested(bsd)
                    }
                }
                return nil
            }, context)
            session = newSession
        }
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            remember(url)
        }
        let center = NSWorkspace.shared.notificationCenter
        driveObservers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { if let url { self?.remember(url) } }
        })
        driveObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            let name = note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
            MainActor.assumeIsolated { if let url { self?.unmounted(url, name: name) } }
        })
    }

    private func stopDrives() {
        driveObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        driveObservers.removeAll()
        if let session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            self.session = nil
        }
        volumes.removeAll()
        removals = DriveRemovalTracker()
    }

    /// Keeps removable, local, non-disk-image volumes (names and BSD names
    /// can't be read once they are gone).
    private func remember(_ url: URL) {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeLocalizedNameKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.volumeIsLocal == true, values.volumeIsRootFileSystem != true,
              values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false
        else { return }
        var bsd: String?
        if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
            let description = DADiskCopyDescription(disk) as? [String: Any]
            let model = (description?[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces)
            let transport = description?[kDADiskDescriptionDeviceProtocolKey as String] as? String
            // Mounted disk images (.dmg) are "ejected" all the time: not drives.
            if model == "Disk Image" || transport == "Disk Image" || transport == "Virtual Interface" { return }
            bsd = DADiskGetBSDName(disk).map { String(cString: $0) }
        }
        volumes[url.path] = (values.volumeLocalizedName ?? url.lastPathComponent, bsd)
        // A reused BSD name starts clean.
        if let bsd { removals.noteMounted(bsd) }
    }

    private func diskDisappeared(_ bsd: String) {
        removals.noteDisappeared(bsd, at: Date())
    }

    private func removalRequested(_ bsd: String) {
        removals.noteRequested(bsd, at: Date())
    }

    /// Decided by whether the unmount was requested (see
    /// `DriveRemovalTracker`), not by the order of two notifications.
    private func unmounted(_ url: URL, name: String?) {
        guard let volume = volumes.removeValue(forKey: url.path) else { return }
        let unmountedAt = Date()
        let displayName = name ?? volume.name
        Task { [weak self] in
            // A pulled drive's "disappeared" lands within a second.
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.alertsDrives, !self.driveObservers.isEmpty else { return }
            switch self.removals.outcome(for: volume.bsd, unmountedAt: unmountedAt, now: Date()) {
            case .ejected: self.announce(.driveEjected(name: displayName))
            case .removedUnsafely: self.announce(.driveRemovedUnsafely(name: displayName))
            }
        }
    }

    // MARK: Bands

    private func announce(_ event: ConnectivityEvent) {
        guard isStarted, isEnabled else { return }
        if SystemStatusCenter.shared.isScreenSharing() {
            AppLog.log("Connectivity: \(event) (quiet while sharing the screen)")
            return
        }
        let band: (symbol: String, tint: Color, title: String, detail: String?, id: String, priority: Int, duration: TimeInterval)
        switch event {
        case .offline:
            guard alertsOffline else { return }
            band = ("wifi.slash", SparkVTheme.warning, "No internet connection", observation?.interface == NetworkInterfaceKind.none ? "Not connected to a network" : nil,
                    Self.activityID, 60, 4)
        case .online(let kind):
            guard alertsOffline else { return }
            band = (kind.symbol, SparkVTheme.success, "Back online", kind == .none ? nil : kind.title, Self.activityID, 45, 2.5)
        case .vpnConnected:
            guard alertsVPN else { return }
            band = ("lock.shield.fill", SparkVTheme.success, "VPN connected", nil, Self.activityID, 45, 3)
        case .vpnDisconnected:
            guard alertsVPN else { return }
            band = ("lock.open.fill", SparkVTheme.warning, "VPN disconnected", "Traffic goes out directly", Self.activityID, 55, 3.5)
        case .hotspot:
            guard alertsHotspot else { return }
            band = ("personalhotspot", SparkVTheme.success, "Personal Hotspot", "Using cellular data", Self.activityID, 45, 3)
        case .driveEjected(let name):
            band = ("externaldrive.badge.checkmark", SparkVTheme.success, "\(name) ejected", "Safe to remove", Self.driveActivityID, 50, 3)
        case .driveRemovedUnsafely(let name):
            band = ("externaldrive.badge.xmark", SparkVTheme.warning, "\(name) removed", "Eject drives before unplugging", Self.driveActivityID, 55, 4)
        }
        AppLog.log("Connectivity: \(band.title)\(band.detail.map { " · \($0)" } ?? "")")
        SystemStatusCenter.shared.post(LiveActivity(id: band.id, kind: .notification, priority: band.priority, duration: band.duration,
                                                    symbol: band.symbol, tint: band.tint) {
            StatusBand(symbol: band.symbol, tint: band.tint, title: band.title, detail: band.detail)
        }
        .titled(band.id == Self.driveActivityID ? "Drives" : "Connection")
        .accessibility(band.title + (band.detail.map { ". \($0)" } ?? "")))
    }
}
