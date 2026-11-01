import AppKit

// Local Network, routed through PermissionCenter like every other
// permission redirect. It is a helper, not a `Permission` case: Local
// Network has no public status or request API, and `SmartMomentsViews`
// switches over `Permission` exhaustively. It lives in this lab so the lab
// compiles on its own; INTEGRATION.md (Step 1b, optional) moves it into
// PermissionCenter.swift verbatim.
extension PermissionCenter {
    /// macOS asks the first time SparkV sends to the local network
    /// (LocalSend's search, which runs only after the user clicks Turn On).
    /// This opens the pane to change it, logged.
    static let localNetworkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    func openLocalNetworkSettings(from feature: String) {
        AppLog.log("Permissions: opening Settings for localNetwork (\(feature))")
        NSWorkspace.shared.open(Self.localNetworkSettingsURL)
    }
}
