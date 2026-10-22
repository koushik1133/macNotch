import Foundation

/// Test stand-in for Sources/AppLog.swift: prints instead of writing
/// ~/Library/Logs/NotchIsland.log.
enum AppLog {
    static func log(_ message: String) {
        if ProcessInfo.processInfo.environment["CLIPBOARD_TEST_VERBOSE"] != nil { print("log: \(message)") }
    }
}
