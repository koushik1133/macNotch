import Foundation
import os

/// Plain-text diagnostics in ~/Library/Logs/SparkV.log (also mirrored to
/// the unified log, marked private), so behavior can be checked after the
/// fact.
///
/// Never put user content in a message: no song, meeting or item titles,
/// no dropped or copied text, no URLs or domains. Log the kind, a count, a
/// length or a bundle id instead. The file is created 0600. Formatting and
/// writing happen on a utility queue, never on the caller's thread.
enum AppLog {
    private static let queue = DispatchQueue(label: "SparkV.AppLog", qos: .utility)
    private static let fileURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/SparkV.log")
    private static let logger = Logger(subsystem: "com.sparkv.app", category: "SparkV")
    /// Only touched on `queue`.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static var checkedMode = false

    static func log(_ message: String) {
        let date = Date()
        queue.async {
            // Private in the unified log: shown as <private> unless a
            // profile on this Mac turns private data on.
            logger.log("\(message, privacy: .private)")
            let line = "\(formatter.string(from: date)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let path = fileURL.path
            if !checkedMode {
                checkedMode = true
                // Older builds created the log 0644.
                if FileManager.default.fileExists(atPath: path) { chmod(path, 0o600) }
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
