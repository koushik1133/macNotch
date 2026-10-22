import Foundation

/// Plain-text diagnostics in ~/Library/Logs/SparkV.log (also mirrored to
/// the unified log), so behavior can be checked after the fact.
enum AppLog {
    private static let queue = DispatchQueue(label: "SparkV.AppLog", qos: .utility)
    private static let fileURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/SparkV.log")

    static func log(_ message: String) {
        NSLog("SparkV: %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: fileURL)
            }
        }
    }
}
