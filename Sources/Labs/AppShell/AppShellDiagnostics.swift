import AppKit
import MetricKit
import SwiftUI
import UniformTypeIdentifiers

/// One crash, hang or resource report, from MetricKit or from macOS's own
/// DiagnosticReports folder.
struct DiagnosticReport: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case metricKit, system }

    let url: URL
    let source: Source
    let kind: DiagnosticKind
    let date: Date
    /// "Crash · EXC_BAD_ACCESS (SIGSEGV)"
    let title: String
    /// "SparkV 1.0 (1) · macOS report"
    let detail: String
    let size: Int

    var id: String { url.path }
}

/// Crash and hang reports, kept on this Mac.
///
/// - MetricKit (`MXMetricManager`) hands SparkV its crash, hang, CPU and
///   disk-write diagnostics on the next launch; each payload is saved as
///   JSON in ~/Library/Application Support/SparkV/Diagnostics.
/// - macOS's own reports for SparkV in ~/Library/Logs/DiagnosticReports
///   (and Retired) are listed next to them, read only when the list opens.
/// - Nothing is ever sent. "Export Diagnostics…" writes a zip the user can
///   attach to an e-mail or a GitHub issue themselves; the log inside has
///   personal details removed.
@MainActor
final class DiagnosticsController: ObservableObject {
    static let shared = DiagnosticsController()
    static let enabledKey = "AppShell.diagnostics.metricKit"

    /// On by default: local only, nothing leaves the Mac.
    @Published var collectsMetricKit: Bool {
        didSet {
            guard collectsMetricKit != oldValue else { return }
            UserDefaults.standard.set(collectsMetricKit, forKey: Self.enabledKey)
            AppLog.log("Diagnostics: MetricKit reports \(collectsMetricKit ? "on" : "off")")
            if started { collectsMetricKit ? subscribe() : unsubscribe() }
        }
    }

    @Published private(set) var reports: [DiagnosticReport] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    /// Last export, or why it failed.
    @Published private(set) var exportNote: String?
    /// Reports MetricKit delivered this session.
    @Published private(set) var newThisSession = 0

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Diagnostics", isDirectory: true)
    }

    nonisolated static var systemDirectories: [URL] {
        let user = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        return [user, user.appendingPathComponent("Retired", isDirectory: true),
                URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)]
    }

    private let receiver = MetricKitReceiver(directory: DiagnosticsController.directory)
    private var subscribed = false
    private var started = false

    private init() {
        collectsMetricKit = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        if collectsMetricKit { subscribe() }
    }

    func stop() {
        started = false
        unsubscribe()
    }

    private func subscribe() {
        guard !subscribed else { return }
        subscribed = true
        receiver.onSaved = { count in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DiagnosticsController.shared.didSave(count) }
            }
        }
        MXMetricManager.shared.add(receiver)
        // Payloads delivered before SparkV subscribed this launch.
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { receiver.didReceive(past) }
    }

    private func unsubscribe() {
        guard subscribed else { return }
        subscribed = false
        MXMetricManager.shared.remove(receiver)
    }

    private func didSave(_ count: Int) {
        newThisSession += count
        AppLog.log("Diagnostics: saved \(count) MetricKit payload(s)")
        if !reports.isEmpty || isLoading { refresh() }
    }

    // MARK: Listing

    /// Scans both folders off the main thread.
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                let controller = DiagnosticsController.shared
                controller.reports = found
                controller.isLoading = false
            }
        }
    }

    nonisolated private static func scan() -> [DiagnosticReport] {
        let files = FileManager.default
        var out: [DiagnosticReport] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        if let saved = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) {
            for url in saved where url.pathExtension == "json" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let summary = MetricKitSummary.parse(data) else { continue }
                let kind = summary.primaryKind
                let title = [kind.title, summary.headline].compactMap { $0 }.joined(separator: " · ")
                let version = summary.appVersion.map { "SparkV \($0)" } ?? "SparkV"
                out.append(DiagnosticReport(
                    url: url, source: .metricKit, kind: kind,
                    date: summary.end ?? values?.contentModificationDate ?? .distantPast,
                    title: title, detail: "\(version) · \(summary.countText) · MetricKit",
                    size: values?.fileSize ?? data.count
                ))
            }
        }
        for folder in systemDirectories {
            guard let names = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for url in names where SystemReportFiles.isOwnReport(url.lastPathComponent) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let header = firstLine(of: url)
                let kind = SystemReportFiles.kind(name: url.lastPathComponent, header: header)
                let version = header.flatMap(SystemReportFiles.appVersion).map { "SparkV \($0)" } ?? "SparkV"
                let process = url.lastPathComponent.hasPrefix("com.sparkv.fanhelper") ? "Fan helper" : version
                out.append(DiagnosticReport(
                    url: url, source: .system, kind: kind,
                    date: values?.contentModificationDate ?? .distantPast,
                    title: kind.title, detail: "\(process) · macOS report",
                    size: values?.fileSize ?? 0
                ))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    nonisolated private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    /// The report's text for the viewer (at most 256 KB; JSON pretty-printed).
    nonisolated static func text(of report: DiagnosticReport) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: report.url) else { return "This report can’t be read." }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            if report.source == .metricKit,
               let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: pretty, as: UTF8.self)
            }
            var text = String(decoding: data, as: UTF8.self)
            if data.count == 256 * 1024 { text += "\n… (truncated; Reveal in Finder for the whole file)" }
            return text
        }.value
    }

    func reveal(_ report: DiagnosticReport) {
        NSWorkspace.shared.activateFileViewerSelecting([report.url])
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.directory])
    }

    /// To the Trash, so it can be put back.
    func trash(_ report: DiagnosticReport) {
        do {
            try FileManager.default.trashItem(at: report.url, resultingItemURL: nil)
            reports.removeAll { $0.id == report.id }
        } catch {
            exportNote = "Couldn’t move the report to the Trash: \(error.localizedDescription)"
        }
    }

    // MARK: Export

    /// Asks where to save, then writes the zip and shows it in Finder.
    func exportWithPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.message = "A zip with SparkV’s log, crash and hang reports and basic system information. Names, e-mail addresses, web paths and quoted text are removed. Nothing is sent."
        panel.nameFieldStringValue = "SparkV Diagnostics \(Self.stamp(Date())).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(to: destination)
    }

    /// Writes the zip; `reveal` shows it in Finder afterwards.
    func export(to destination: URL, reveal: Bool = true) {
        guard !isExporting else { return }
        isExporting = true
        exportNote = nil
        let version = SparkVAppInfo.versionText
        let homebrew = SparkVAppInfo.isHomebrewInstall
        Task.detached(priority: .userInitiated) {
            let names = DiagnosticsRedactor.nameVariants(
                fullName: NSFullUserName(), shortName: NSUserName(),
                hostNames: [Host.current().localizedName ?? "", ProcessInfo.processInfo.hostName]
            )
            let result = Self.writeArchive(to: destination, version: version, homebrew: homebrew, names: names)
            await MainActor.run {
                let controller = DiagnosticsController.shared
                controller.isExporting = false
                switch result {
                case .success:
                    controller.exportNote = "Saved \(destination.lastPathComponent)."
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                    AppLog.log("Diagnostics: exported a zip")
                case .failure(let error):
                    controller.exportNote = "Export failed: \(error.message)"
                    AppLog.log("Diagnostics: export failed: \(error.message)")
                }
            }
        }
    }

    struct ExportError: Error, Sendable { let message: String }

    nonisolated private static func writeArchive(to destination: URL, version: String, homebrew: Bool, names: [String]) -> Result<Void, ExportError> {
        // A log that grew past 5 MB since launch rotates first.
        AppShellLogMaintenance.rotateIfNeeded()
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        let stage = files.temporaryDirectory.appendingPathComponent("SparkV-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        let root = stage.appendingPathComponent("SparkV Diagnostics \(stamp(Date()))", isDirectory: true)
        defer { try? files.removeItem(at: stage) }
        do {
            try files.createDirectory(at: root.appendingPathComponent("MetricKit"), withIntermediateDirectories: true)
            try files.createDirectory(at: root.appendingPathComponent("Reports"), withIntermediateDirectories: true)

            let readme = """
            SparkV diagnostics, made on this Mac by Export Diagnostics.
            Nothing was sent anywhere. Attach this zip yourself to an e-mail or a GitHub issue:
            \(SparkVAppInfoStatic.newIssueURL)

            system.txt     SparkV version, macOS version, Mac model
            SparkV.log     the app log. Removed: your name and user name, this Mac's name,
                           e-mail addresses, the paths of web addresses, quoted text and
                           device names. File names it mentions without quotes can remain,
                           so read it before you send it.
            MetricKit/     crash and hang diagnostics macOS handed to SparkV
            Reports/       macOS crash and hang reports for SparkV, renamed to <kind>-<date>.
                           Removed: home folder, names, e-mail addresses and per-Mac ids;
                           everything a developer needs to read the crash is kept.
            """
            try readme.write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let system = """
            SparkV \(version)\(homebrew ? " (Homebrew)" : "")
            macOS \(os)
            Mac \(hardwareModel())
            Exported \(ISO8601DateFormatter().string(from: Date()))
            """
            try system.write(to: root.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)

            // The log: newest 2 MB of the current and previous file.
            let logs = files.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
            var log = ""
            for name in ["SparkV.1.log", "SparkV.log"] {
                let url = logs.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                log += String(decoding: data.suffix(2 * 1024 * 1024), as: UTF8.self)
            }
            try DiagnosticsRedactor.redact(log.isEmpty ? "(no log yet)" : log, home: home, names: names, profile: .log)
                .write(to: root.appendingPathComponent("SparkV.log"), atomically: true, encoding: .utf8)

            var taken: [DiagnosticReport.Source: Set<String>] = [:]
            for report in scan() {
                let folder = root.appendingPathComponent(report.source == .metricKit ? "MetricKit" : "Reports")
                guard report.size < 20 * 1024 * 1024, let data = try? Data(contentsOf: report.url) else { continue }
                // Reports keep their JSON intact (keys, exception, frames, UUIDs).
                let text = DiagnosticsRedactor.redact(String(decoding: data, as: UTF8.self), home: home, names: names, profile: .report)
                let name = DiagnosticsRedactor.exportFileName(
                    kind: report.kind, date: report.date, pathExtension: report.url.pathExtension, taken: taken[report.source] ?? []
                )
                taken[report.source, default: []].insert(name)
                try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }

            try? files.removeItem(at: destination)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { return .failure(ExportError(message: "ditto exited with \(ditto.terminationStatus)")) }
            return .success(())
        } catch {
            return .failure(ExportError(message: error.localizedDescription))
        }
    }

    nonisolated private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }
}

/// Values the background export needs without the main actor.
enum SparkVAppInfoStatic {
    static let newIssueURL = "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repository)/issues/new"
}

/// MetricKit calls this on a background queue; it only writes files.
final class MetricKitReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var _onSaved: (@Sendable (Int) -> Void)?

    var onSaved: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onSaved } }
        set { lock.withLock { _onSaved = newValue } }
    }

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved = 0
        for payload in payloads {
            let data = payload.jsonRepresentation()
            // Same payload delivered twice (past + live) is written once.
            let name = "metrickit-\(DiagnosticsController.stamp(payload.timeStampEnd).replacingOccurrences(of: " ", with: "_"))-\(data.count).json"
            let url = directory.appendingPathComponent(name)
            guard !files.fileExists(atPath: url.path) else { continue }
            if (try? data.write(to: url, options: .atomic)) != nil { saved += 1 }
        }
        if saved > 0 { onSaved?(saved) }
    }
}

// MARK: - Viewer window

@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    static let shared = DiagnosticsWindowController()
    private var window: NSWindow?

    func show() {
        let window = window ?? make()
        self.window = window
        DiagnosticsController.shared.refresh()
        AppShellWindowStyle.present(window, centerIfNew: true)
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: DiagnosticsRootView().followsAppearance())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Crash & Hang Reports"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        AppShellWindowStyle.apply(to: window)
        window.setContentSize(NSSize(width: 820, height: 540))
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.setFrameAutosaveName("SparkV.Diagnostics")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        AppShellWindowStyle.didClose(window)
    }
}

/// Selection and the loaded text (no @State).
@MainActor
final class DiagnosticsViewerModel: ObservableObject {
    @Published var selectedID: String?
    @Published private(set) var text = ""
    @Published private(set) var loadingText = false
    private var loadTask: Task<Void, Never>?

    func select(_ report: DiagnosticReport?) {
        selectedID = report?.id
        loadTask?.cancel()
        guard let report else { text = ""; return }
        loadingText = true
        loadTask = Task { [weak self] in
            let text = await DiagnosticsController.text(of: report)
            guard !Task.isCancelled, let self else { return }
            self.text = text
            self.loadingText = false
        }
    }
}

struct DiagnosticsRootView: View {
    @ObservedObject private var controller = DiagnosticsController.shared
    @StateObject private var model = DiagnosticsViewerModel()

    var body: some View {
        DiagnosticsContentView(
            reports: controller.reports,
            isLoading: controller.isLoading,
            isExporting: controller.isExporting,
            note: controller.exportNote,
            model: model
        )
        .background(SparkVSettingsGround())
        .environment(\.colorScheme, .dark)
        .onChange(of: controller.reports) { _, reports in
            if model.selectedID == nil || !reports.contains(where: { $0.id == model.selectedID }) {
                model.select(reports.first)
            }
        }
        .onAppear { if model.selectedID == nil { model.select(controller.reports.first) } }
    }
}

struct DiagnosticsContentView: View {
    let reports: [DiagnosticReport]
    let isLoading: Bool
    let isExporting: Bool
    let note: String?
    @ObservedObject var model: DiagnosticsViewerModel

    private var selected: DiagnosticReport? { reports.first { $0.id == model.selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            if reports.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 290)
                    Rectangle().fill(SparkVTheme.stroke).frame(width: 1)
                    detail
                }
            }
            Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        }
    }

    /// No reports: one calm message across the window.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isLoading ? "hourglass" : "checkmark.seal")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(isLoading ? SparkVTheme.textTertiary : SparkVTheme.success)
                .accessibilityHidden(true)
            Text(isLoading ? "Looking for reports…" : "No crash or hang reports")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
            Text(isLoading ? " " : "SparkV hasn’t crashed or stopped responding on this Mac, or its reports were removed. When macOS records one, it shows up here after SparkV’s next launch.")
                .font(.system(size: 12.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(reports) { report in
                    DiagnosticRow(report: report, isSelected: report.id == model.selectedID) { model.select(report) }
                }
            }
            .padding(8)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report = selected {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SparkVTheme.text)
                        Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(report.size), countStyle: .file))")
                            .font(.system(size: 11))
                            .foregroundStyle(SparkVTheme.textSecondary)
                        Text(report.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button { DiagnosticsController.shared.reveal(report) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy the report")
                        .accessibilityLabel("Copy the report")
                    Button { DiagnosticsController.shared.trash(report) } label: { Image(systemName: "trash") }
                        .help("Move to Trash")
                        .accessibilityLabel("Move the report to the Trash")
                }
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
                ScrollView([.vertical, .horizontal]) {
                    Text(model.loadingText ? "Loading…" : model.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
            } else {
                VStack(spacing: 6) {
                    Text("Select a report")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(SparkVTheme.textTertiary)
                .accessibilityHidden(true)
            Text(note ?? "Reports stay on this Mac. Nothing is sent unless you export a zip and share it yourself.")
                .font(.system(size: 11.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button("Refresh") { DiagnosticsController.shared.refresh() }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .disabled(isLoading)
            Button(isExporting ? "Exporting…" : "Export Diagnostics…") { DiagnosticsController.shared.exportWithPanel() }
                .buttonStyle(SparkVPrimaryButtonStyle())
                .disabled(isExporting)
        }
    }
}

private struct DiagnosticRow: View {
    let report: DiagnosticReport
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: report.kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(report.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                    Text(report.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(isSelected ? SparkVTheme.accentSoft : SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .accessibilityLabel("\(report.title), \(report.date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tint: Color {
        switch report.kind {
        case .crash: SparkVTheme.destructive
        case .hang: SparkVTheme.warning
        default: SparkVTheme.textSecondary
        }
    }
}
