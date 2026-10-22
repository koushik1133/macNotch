import AppKit
import Security

/// How this copy of SparkV is signed. macOS ties every privacy grant to the
/// app's designated requirement; for an ad-hoc signature that requirement is
/// the exact code hash, so each rebuild looks like a different app and old
/// grants stop applying even though their switches stay on in Settings.
struct OnboardingCodeIdentity: Equatable, Sendable {
    var isSigned: Bool
    var isAdHoc: Bool
    /// The code directory hash, in hex: changes with every build.
    var cdhash: String?
    var designatedRequirement: String?
    /// Common name of the signing certificate, when there is one.
    var signer: String?

    /// Identifies this exact build.
    var buildKey: String { cdhash ?? "unsigned" }

    /// Grants survive rebuilds only when the requirement names a
    /// certificate instead of a hash.
    var grantsSurviveRebuilds: Bool { isSigned && !isAdHoc && !(designatedRequirement ?? "").contains("cdhash") }

    static let unsigned = OnboardingCodeIdentity(isSigned: false, isAdHoc: false, cdhash: nil, designatedRequirement: nil, signer: nil)

    /// The running process.
    static func current() -> OnboardingCodeIdentity {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unsigned }
        return inspect(staticCode)
    }

    /// An app bundle or binary on disk.
    static func of(url: URL) -> OnboardingCodeIdentity {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return .unsigned }
        return inspect(staticCode)
    }

    private static func inspect(_ code: SecStaticCode) -> OnboardingCodeIdentity {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return .unsigned }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let cdhash = (dictionary[kSecCodeInfoUnique as String] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() }
        guard cdhash != nil else { return .unsigned }
        var signer: String?
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            signer = SecCertificateCopySubjectSummary(leaf) as String?
        }
        var requirement: SecRequirement?
        var requirementText: String?
        if SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess { requirementText = text as String? }
        }
        return OnboardingCodeIdentity(
            isSigned: true,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            cdhash: cdhash,
            designatedRequirement: requirementText,
            signer: signer
        )
    }
}

/// Whether an Accessibility switch that is "on" in System Settings may be
/// pointing at an older build.
enum OnboardingGrantDiagnosis: Equatable, Sendable {
    /// Accessibility works.
    case fine
    /// Not trusted, and nothing suggests it was granted before.
    case notGranted(adHoc: Bool)
    /// It worked for an earlier build, or the user says it's on: the
    /// grant in Settings belongs to a different signature.
    case stale(adHoc: Bool, reason: Reason)

    enum Reason: Equatable, Sendable {
        case rebuilt
        case userReported
    }

    /// `grantFromOtherSignature`: for builds signed with a stable identity
    /// the build hash changes on every rebuild while grants carry over, so
    /// "trusted by another build" says nothing; pass whether the grant was
    /// last seen under a different code signature instead
    /// (`PermissionCenter.isLikelyStaleGrant`). Nil keeps the build check.
    static func evaluate(
        trusted: Bool,
        identity: OnboardingCodeIdentity,
        lastTrustedBuild: String?,
        userReportedGrant: Bool,
        grantFromOtherSignature: Bool? = nil
    ) -> OnboardingGrantDiagnosis {
        if trusted { return .fine }
        let adHoc = !identity.grantsSurviveRebuilds
        let rebuilt: Bool
        if let grantFromOtherSignature {
            rebuilt = grantFromOtherSignature
        } else if let lastTrustedBuild {
            rebuilt = lastTrustedBuild != identity.buildKey
        } else {
            rebuilt = false
        }
        if rebuilt { return .stale(adHoc: adHoc, reason: .rebuilt) }
        if userReportedGrant { return .stale(adHoc: adHoc, reason: .userReported) }
        return .notGranted(adHoc: adHoc)
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

/// The buttons in the "still says it's missing" card. Each runs only when
/// the user clicks it.
@MainActor
enum OnboardingFixes {
    static var appURL: URL { Bundle.main.bundleURL }

    /// The project folder when SparkV runs from its own `build/` folder.
    static var projectDirectory: URL? {
        let candidate = appURL.deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: signingScript(in: candidate).path) ? candidate : nil
    }

    static func signingScript(in project: URL) -> URL {
        project.appendingPathComponent("Scripts/create-signing-identity.sh")
    }

    static var signingCommand: String {
        if let project = projectDirectory {
            return "cd \(shellQuoted(project.path)) && ./Scripts/create-signing-identity.sh && ./build.sh"
        }
        return "./Scripts/create-signing-identity.sh && ./build.sh"
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens Privacy & Security › Accessibility and selects SparkV.app in
    /// Finder, so it can be dragged into the list after removing the old one.
    static func openAccessibilityAndRevealApp() {
        openSettingsAndRevealApp(for: .accessibility)
    }

    /// The same for any pane (Screen Recording has the same problem).
    static func openSettingsAndRevealApp(for permission: OnboardingPermission) {
        PermissionCenter.shared.openSettings(permission.centerPermission, from: "Onboarding stale-entry fix")
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
        OnboardingDragHelper.shared.show(for: permission)
    }

    static func revealSigningScript() {
        guard let project = projectDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([signingScript(in: project)])
    }

    /// Puts the one-line terminal command on the clipboard (user action).
    static func copySigningCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(signingCommand, forType: .string)
    }

    /// `tccutil` service names.
    static func tccService(for permission: OnboardingPermission) -> String? {
        switch permission {
        case .accessibility: "Accessibility"
        case .screenRecording: "ScreenCapture"
        default: nil
        }
    }

    /// Removes SparkV's own (stale) Accessibility entry with `tccutil`, then
    /// asks again so the current build is added fresh. Only touches SparkV.
    static func resetAccessibilityEntry(completion: @escaping @MainActor (Bool) -> Void) {
        resetEntries(for: [.accessibility], completion: completion)
    }

    /// `tccutil reset <service> <SparkV's bundle id>` for each permission (one
    /// service per run, SparkV only), then shows each macOS prompt again so
    /// this build gets a fresh entry. Runs only from a click.
    ///
    /// The reset removed the old entry, so this is the one case where asking
    /// again is right although SparkV already asked with this signature
    /// (only the prompt adds SparkV back to the list): PermissionCenter
    /// forgets that it asked, then asks through its queue, so the two
    /// alerts (Accessibility, Screen Recording) appear one after the other
    /// and Screen Recording offers the restart afterwards.
    static func resetEntries(
        for permissions: [OnboardingPermission],
        center: PermissionCenter? = nil,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sparkv.app"
        let reset = permissions.filter { tccService(for: $0) != nil }
        let services = reset.compactMap(tccService(for:))
        guard !services.isEmpty else { completion(false); return }
        runReset(services[...], bundleID: bundleID, allOK: true) { ok in
            let center = center ?? .shared
            for permission in reset { center.forgetPrompt(permission.centerPermission) }
            Task { @MainActor in
                for permission in reset {
                    _ = await center.request(permission.centerPermission, from: "Onboarding reset")
                }
            }
            completion(ok)
        }
    }

    private static func runReset(_ services: ArraySlice<String>, bundleID: String, allOK: Bool, done: @escaping @MainActor (Bool) -> Void) {
        guard let service = services.first else { done(allOK); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let ok = finished.terminationStatus == 0
            Task { @MainActor in
                AppLog.log("Onboarding: tccutil reset \(service) \(bundleID) -> \(ok ? "ok" : "failed")")
                runReset(services.dropFirst(), bundleID: bundleID, allOK: allOK && ok, done: done)
            }
        }
        do {
            try process.run()
        } catch {
            runReset(services.dropFirst(), bundleID: bundleID, allOK: false, done: done)
        }
    }

    /// Quits and reopens SparkV (Screen Recording applies after a restart).
    /// PermissionCenter waits until this process has really exited (quitting
    /// can take a few seconds while a screen recording is saved) before
    /// opening the app again.
    static func relaunch() {
        PermissionCenter.shared.relaunch(from: "Onboarding")
    }

    /// `$0` is the app, `$1` the PID to wait for (at most 30 s).
    static let relaunchScript = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$0\""
}
