import CryptoKit
import Foundation
import UniformTypeIdentifiers

// LocalSend protocol v2 (https://github.com/localsend/protocol), the sending
// half only. SparkV never listens for incoming transfers.
//
// Discovery: a JSON announcement to the multicast group 224.0.0.167:53317;
// devices answer with their own info (by multicast, since SparkV runs no
// server for their HTTP "register" reply).
// Sending: POST /api/localsend/v2/prepare-upload with the file list (the
// receiver shows an Accept dialog), then one POST /api/localsend/v2/upload
// per file with the raw bytes, streamed from disk. /cancel ends a session.

enum LocalSendProtocol {
    static let multicastHost = "224.0.0.167"
    static let port: UInt16 = 53317
    static let version = "2.1"
    static let apiPrefix = "/api/localsend/v2"
}

/// What a device says about itself (multicast announcement or response).
struct LocalSendAnnouncement: Codable, Equatable, Sendable {
    var alias: String
    var version: String?
    var deviceModel: String?
    var deviceType: String?
    var fingerprint: String
    var port: Int?
    /// "https" (default) or "http".
    var `protocol`: String?
    var download: Bool?
    /// v2: `announce`, v1: `announcement`. True asks others to reply.
    var announce: Bool?
    var announcement: Bool?

    var isAnnouncement: Bool { announce ?? announcement ?? false }

    /// SparkV's own announcement.
    static func sparkV(alias: String, fingerprint: String) -> LocalSendAnnouncement {
        LocalSendAnnouncement(alias: alias, version: LocalSendProtocol.version, deviceModel: "Mac", deviceType: "desktop",
                              fingerprint: fingerprint, port: Int(LocalSendProtocol.port), protocol: "https",
                              download: false, announce: true, announcement: true)
    }
}

/// "info" in prepare-upload (the announcement minus the announce flags).
struct LocalSendSenderInfo: Codable, Equatable, Sendable {
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: String?
    var fingerprint: String
    var port: Int
    var `protocol`: String
    var download: Bool
}

struct LocalSendFileMeta: Codable, Equatable, Sendable {
    var id: String
    var fileName: String
    var size: Int64
    var fileType: String
    var sha256: String?
    var preview: String?
}

struct LocalSendPrepareRequest: Codable, Equatable, Sendable {
    var info: LocalSendSenderInfo
    var files: [String: LocalSendFileMeta]
}

struct LocalSendPrepareResponse: Codable, Equatable, Sendable {
    var sessionId: String
    /// fileId → upload token.
    var files: [String: String]
}

/// A device found on the network.
struct LocalSendDevice: Identifiable, Equatable, Sendable {
    var id: String { fingerprint }
    var alias: String
    var deviceModel: String?
    var deviceType: String
    var fingerprint: String
    var host: String
    var port: Int
    var usesTLS: Bool
    var lastSeen: Date

    /// SF Symbol for the device type.
    var symbol: String {
        switch deviceType {
        case "mobile": "iphone.gen3"
        case "web": "globe"
        case "headless", "server": "server.rack"
        default: "desktopcomputer"
        }
    }

    var subtitle: String {
        var parts: [String] = []
        if let model = deviceModel, !model.isEmpty { parts.append(model) }
        parts.append(host)
        return parts.joined(separator: " · ")
    }

    /// From an announcement received from `host`; nil when it isn't usable
    /// (no alias, a host that isn't on the local network, our own echo).
    static func from(_ announcement: LocalSendAnnouncement, host: String, ownFingerprint: String, allowLoopback: Bool = false,
                     now: Date = Date()) -> LocalSendDevice? {
        // The multicast group is IPv4, so replies come from IPv4 addresses.
        guard announcement.fingerprint != ownFingerprint, !announcement.alias.trimmingCharacters(in: .whitespaces).isEmpty,
              LocalSendNetwork.ipv4Octets(host) != nil,
              LocalSendNetwork.isLocal(host, allowLoopback: allowLoopback) else { return nil }
        let port = announcement.port ?? Int(LocalSendProtocol.port)
        guard (1...65535).contains(port) else { return nil }
        return LocalSendDevice(alias: String(announcement.alias.prefix(60)), deviceModel: announcement.deviceModel.map { String($0.prefix(60)) },
                               deviceType: announcement.deviceType ?? "desktop", fingerprint: announcement.fingerprint,
                               host: host, port: port, usesTLS: (announcement.protocol ?? "https").lowercased() != "http",
                               lastSeen: now)
    }

    /// `https://host:port/api/localsend/v2/<path>?query`.
    func url(_ path: String, query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = usesTLS ? "https" : "http"
        components.host = host
        components.port = port
        components.path = LocalSendProtocol.apiPrefix + "/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }
}

/// LAN checks: SparkV only ever talks to private / link-local addresses.
enum LocalSendNetwork {
    /// RFC 1918 private IPv4, 169.254/16 link-local, IPv6 link-local
    /// (fe80::/10) and unique-local (fc00::/7). Loopback only for tests.
    static func isLocal(_ host: String, allowLoopback: Bool = false) -> Bool {
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        if let v4 = ipv4Octets(bare) {
            switch (v4[0], v4[1]) {
            case (10, _): return true
            case (172, 16...31): return true
            case (192, 168): return true
            case (169, 254): return true
            case (127, _): return allowLoopback
            default: return false
            }
        }
        let lower = bare.lowercased()
        guard lower.contains(":") else { return false }
        if lower == "::1" { return allowLoopback }
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        return false
    }

    static func ipv4Octets(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }
}

/// Certificate pinning: LocalSend receivers use a self-signed certificate
/// whose SHA-256 (of the DER bytes) they announce as their fingerprint.
enum LocalSendFingerprint {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Case- and separator-insensitive comparison ("AB:CD…" == "abcd…").
    static func matches(certificateDER: Data, announced: String) -> Bool {
        let clean = announced.lowercased().filter { $0.isHexDigit }
        guard clean.count == 64 else { return false }
        return sha256Hex(certificateDER) == clean
    }

    /// A random fingerprint for SparkV's own announcements (new each
    /// launch: SparkV runs no HTTPS server, so there's no certificate).
    static func random() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Building the prepare-upload request for files on disk (sizes from the
/// file system; contents are never read here).
enum LocalSendFiles {
    struct Entry: Equatable, Sendable {
        let id: String
        let url: URL
        let meta: LocalSendFileMeta
    }

    /// One entry per regular file; folders and unreadable items are skipped
    /// (`skipped` counts them).
    static func entries(for urls: [URL]) -> (entries: [Entry], skipped: Int) {
        var entries: [Entry] = []
        var skipped = 0
        var usedNames = Set<String>()
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileSizeKey, .contentTypeKey])
            guard values?.isRegularFile == true else { skipped += 1; continue }
            let size = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
            var name = url.lastPathComponent
            // Two files with one name would overwrite each other on the receiver.
            if usedNames.contains(name.lowercased()) {
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                var n = 2
                repeat {
                    name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    n += 1
                } while usedNames.contains(name.lowercased())
            }
            usedNames.insert(name.lowercased())
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let id = UUID().uuidString.lowercased()
            entries.append(Entry(id: id, url: url, meta: LocalSendFileMeta(id: id, fileName: name, size: size, fileType: mime, sha256: nil, preview: nil)))
        }
        return (entries, skipped)
    }

    static func request(for entries: [Entry], alias: String, fingerprint: String) -> LocalSendPrepareRequest {
        let info = LocalSendSenderInfo(alias: alias, version: LocalSendProtocol.version, deviceModel: "Mac", deviceType: "desktop",
                                       fingerprint: fingerprint, port: Int(LocalSendProtocol.port), protocol: "https", download: false)
        return LocalSendPrepareRequest(info: info, files: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.meta) }))
    }
}

/// What a prepare-upload HTTP status means for the user.
enum LocalSendStatus {
    static func message(forPrepareStatus status: Int) -> String? {
        switch status {
        case 200: nil
        case 204: "The device already has these files"
        case 401: "That device asks for a PIN. Turn off its PIN in LocalSend, then try again."
        case 403: "The other device declined"
        case 409: "That device is busy with another transfer"
        case 429: "That device is getting too many requests. Try again in a moment."
        case 400: "The device didn't understand the request"
        default: "The device reported an error (\(status))"
        }
    }
}
