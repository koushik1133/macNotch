import AppKit
import Foundation

/// Installs or removes the helper with ONE administrator prompt, the way
/// Macs Fan Control does: macOS's own password dialog runs the bundled
/// script as root. The same scripts can be run by hand in Terminal (see
/// USER-SETUP.md). Nothing here runs without the user clicking a button.
@MainActor
enum FanHelperInstaller {
    static var resources: URL? { Bundle.main.resourceURL?.appendingPathComponent("FanHelper", isDirectory: true) }
    static var installScript: URL? { resources?.appendingPathComponent("install-fanhelper.sh") }
    static var uninstallScript: URL? { resources?.appendingPathComponent("uninstall-fanhelper.sh") }
    static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(FanHelperConstants.label)")
    }

    /// The build contains the helper and both scripts.
    static var isBundled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: bundledHelper.path)
            && installScript.map { fm.fileExists(atPath: $0.path) } == true
            && uninstallScript.map { fm.fileExists(atPath: $0.path) } == true
    }

    private static var updateCheck: (date: Date, available: Bool)?

    /// The installed helper differs from the one in this build (SparkV was
    /// rebuilt or updated). Byte comparison of two ~400 KB files, cached for 30 s.
    static var updateAvailable: Bool {
        if let check = updateCheck, Date().timeIntervalSince(check.date) < 30 { return check.available }
        var available = false
        if isBundled,
           let installed = try? Data(contentsOf: URL(fileURLWithPath: FanHelperConstants.installedBinary), options: .mappedIfSafe),
           let bundled = try? Data(contentsOf: bundledHelper, options: .mappedIfSafe) {
            available = installed != bundled
        }
        updateCheck = (Date(), available)
        return available
    }

    static func forgetUpdateCheck() { updateCheck = nil }

    /// For people who prefer Terminal.
    static func terminalCommand(install: Bool) -> String {
        let script = (install ? installScript : uninstallScript)?.path ?? "SparkV.app/Contents/Resources/FanHelper/\(install ? "install" : "uninstall")-fanhelper.sh"
        return "sudo \"\(script)\""
    }

    /// Runs the script as root through osascript's administrator dialog, off
    /// the main thread. Paths go in as arguments, never spliced into script text.
    static func run(install: Bool, completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void) {
        guard let script = (install ? installScript : uninstallScript) else {
            completion(.failure(InstallerError("SparkV's fan helper scripts are missing from this build.")))
            return
        }
        let appPath = Bundle.main.bundleURL.path
        let prompt = install
            ? "SparkV wants to install its fan helper so it can set fan speeds. It runs as a small background service."
            : "SparkV wants to remove its fan helper."
        let source = [
            "on run argv",
            "do shell script \"/bin/zsh \" & quoted form of (item 1 of argv) & \" \" & quoted form of (item 2 of argv) with prompt (item 3 of argv) with administrator privileges",
            "end run",
        ]
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = source.flatMap { ["-e", $0] } + [script.path, appPath, prompt]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            let result: Result<String, Error>
            do {
                try process.run()
                // Read before waiting, so a full pipe can never block the script.
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    result = .success(out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if err.contains("-128") {
                    result = .failure(InstallerError("Cancelled."))
                } else {
                    result = .failure(InstallerError(err.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    struct InstallerError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

extension FanController {
    /// Install or remove the helper, then reconnect.
    func runHelperInstaller(install: Bool) {
        guard !isInstallingHelper else { return }
        // Installing restarts the helper and removing stops it; either way
        // the fans go to Auto, so the modes say so too.
        resetAllToAuto()
        setInstalling(true)
        FanHelperInstaller.run(install: install) { [weak self] result in
            guard let self else { return }
            self.setInstalling(false)
            FanHelperInstaller.forgetUpdateCheck()
            switch result {
            case .success:
                self.clearNotice()
            case .failure(let error):
                self.report(error.localizedDescription)
            }
            self.refreshHelper()
        }
    }
}
