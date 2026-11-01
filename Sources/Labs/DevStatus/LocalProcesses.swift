import AppKit
import Darwin
import Foundation

/// Read-only process facts from public libproc (no root, no Accessibility):
/// the current user's processes, their names, working folders, parents,
/// controlling terminals and listening TCP ports. Every call is cheap
/// (a few microseconds per process) and has no side effects.
enum LocalProcesses {
    /// A TCP socket in LISTEN state.
    struct Listener: Hashable, Sendable {
        let port: UInt16
        /// Bound to 127.0.0.1 / ::1 only (not reachable from the network).
        let isLoopbackOnly: Bool
    }

    struct Info: Sendable, Equatable {
        let pid: pid_t
        let parent: pid_t
        let name: String
        let tty: String?
    }

    /// Every process of the current user.
    static func userPIDs() -> [pid_t] {
        let uid = UInt32(getuid())
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Full path of the executable.
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The process's current working folder.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func info(of pid: pid_t) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let device = dev_t(bitPattern: bsd.e_tdev)
        var tty: String?
        if device != -1, let name = devname(device, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        let comm = withUnsafeBytes(of: bsd.pbi_name) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        let shortComm = withUnsafeBytes(of: bsd.pbi_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return Info(pid: pid, parent: pid_t(bitPattern: bsd.pbi_ppid), name: comm.isEmpty ? shortComm : comm, tty: tty)
    }

    /// Every process below `root` (children, grandchildren, …) among the
    /// current user's processes, nearest first.
    static func descendants(of root: pid_t) -> [pid_t] {
        var parents: [pid_t: pid_t] = [:]
        for pid in userPIDs() {
            if let info = info(of: pid) { parents[pid] = info.parent }
        }
        return descendants(of: root, parents: parents)
    }

    /// The tree walk, on a pid -> parent map (pure, tested).
    static func descendants(of root: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents where pid != parent { children[parent, default: []].append(pid) }
        var result: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var queue = [root]
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            for child in (children[pid] ?? []).sorted() where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// TCP sockets this process listens on.
    static func listeners(of pid: pid_t) -> [Listener] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let got = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return [] }
        var result = Set<Listener>()
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize else { continue }
            guard socket.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport).byteSwapped
            guard port > 0 else { continue }
            let loopback: Bool
            if tcp.tcpsi_ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                let address = UInt32(bigEndian: tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr)
                loopback = (address >> 24) == 127
            } else {
                var v6 = tcp.tcpsi_ini.insi_laddr.ina_6
                loopback = withUnsafeBytes(of: &v6) { raw in
                    raw.prefix(15).allSatisfy { $0 == 0 } && raw[15] == 1
                }
            }
            result.insert(Listener(port: port, isLoopbackOnly: loopback))
        }
        return result.sorted { $0.port < $1.port }
    }

    /// The parent chain from `pid` upward (at most 24 steps), `pid` first.
    static func ancestry(of pid: pid_t) -> [Info] {
        var chain: [Info] = []
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, chain.count < 24, seen.insert(current).inserted, let info = info(of: current) {
            chain.append(info)
            current = info.parent
        }
        return chain
    }

    /// The first ancestor (or `pid` itself) that is a regular app: the
    /// terminal, IDE or desktop app hosting a command-line tool.
    @MainActor
    static func hostingApp(of pid: pid_t) -> NSRunningApplication? {
        for info in ancestry(of: pid) {
            if let app = NSRunningApplication(processIdentifier: info.pid), app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    /// The controlling terminal of the first process in the chain that has one.
    static func terminal(of pid: pid_t) -> String? {
        ancestry(of: pid).lazy.compactMap(\.tty).first
    }
}
