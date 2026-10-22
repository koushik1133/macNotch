import Foundation

/// One-time move from the app's old name (NotchIsland, bundle id
/// com.notchisland.app) to SparkV: settings, the Application Support folder
/// (tray, meetings, Flow, face unlock, converted files) and the log.
/// Runs before anything else touches those locations.
enum AppMigration {
    private static let oldBundleID = "com.notchisland.app"
    private static let doneKey = "SparkV.migratedFromNotchIsland"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        // Settings: copy every old key that the new domain doesn't have yet.
        if let old = UserDefaults.standard.persistentDomain(forName: oldBundleID) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldData = support.appendingPathComponent("NotchIsland", isDirectory: true)
        let newData = support.appendingPathComponent("SparkV", isDirectory: true)
        if files.fileExists(atPath: oldData.path), !files.fileExists(atPath: newData.path) {
            try? files.moveItem(at: oldData, to: newData)
        }

        let logs = files.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        let oldLog = logs.appendingPathComponent("NotchIsland.log")
        let newLog = logs.appendingPathComponent("SparkV.log")
        if files.fileExists(atPath: oldLog.path), !files.fileExists(atPath: newLog.path) {
            try? files.moveItem(at: oldLog, to: newLog)
        }

        defaults.set(true, forKey: doneKey)
    }
}
