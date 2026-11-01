import AppKit
import SwiftUI

// MARK: - Navigation

/// Which page the Dev drawer tab shows, and how to open it (integrator
/// sets `openDrawer` to select the tab and expand the island).
@MainActor
final class DevStatusNavigator: ObservableObject {
    enum Section: String, CaseIterable, Hashable {
        case agents, servers, ci, scripts

        var title: String {
            switch self {
            case .agents: "Agents"
            case .servers: "Servers"
            case .ci: "CI"
            case .scripts: "Scripts"
            }
        }
    }

    static let shared = DevStatusNavigator()

    @Published var section: Section {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "SparkV.devStatus.section") }
    }

    /// Set by the integrator: select the Dev tab and open the drawer.
    var onOpenDrawer: (() -> Void)?

    init() {
        section = UserDefaults.standard.string(forKey: "SparkV.devStatus.section").flatMap(Section.init(rawValue:)) ?? .agents
    }

    func openDrawer() { onOpenDrawer?() }

    func open(_ section: Section) {
        self.section = section
        onOpenDrawer?()
    }
}

// MARK: - Drawer tab

/// The Dev drawer tab (tall drawer, about 508 x 114 pt): a page picker on
/// top, the page in a well below. Pages sample only while on screen.
struct DevStatusDrawerView: View {
    @ObservedObject private var nav = DevStatusNavigator.shared
    @ObservedObject private var agents = CodingAgentsController.shared
    @ObservedObject private var servers = DevServersController.shared
    @ObservedObject private var ci = DevCIController.shared
    @ObservedObject private var scripts = ScriptWidgetsController.shared

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ExtrasSegmented(options: DevStatusNavigator.Section.allCases.map { ($0, title(for: $0)) },
                                selection: $nav.section, label: "Developer page", compact: true)
                    .frame(width: 330)
                Spacer(minLength: 4)
                trailingActions
            }
            .frame(height: 24)
            ExtrasWell {
                page
                    .id(nav.section)
                    .transition(.sparkVCrossfade)
            }
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: nav.section)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var page: some View {
        switch nav.section {
        case .agents: CodingAgentsPage()
        case .servers: DevServersPage()
        case .ci: DevCIPage()
        case .scripts: ScriptWidgetsPage()
        }
    }

    private func title(for section: DevStatusNavigator.Section) -> String {
        switch section {
        case .agents:
            let waiting = agents.waitingCount
            let live = agents.sessions.filter { $0.state != .idle }.count
            return waiting > 0 ? "Agents · \(waiting)" : (live > 0 ? "Agents · \(live)" : "Agents")
        case .servers: return servers.servers.isEmpty ? "Servers" : "Servers · \(servers.servers.count)"
        case .ci:
            let failed = ci.allRuns.contains { $0.outcome == .failure }
            return failed ? "CI · ✕" : "CI"
        case .scripts: return scripts.configs.isEmpty ? "Scripts" : "Scripts · \(scripts.configs.count)"
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        HStack(spacing: 2) {
            switch nav.section {
            case .agents:
                ExtrasIconButton(systemImage: "arrow.clockwise", label: "Refresh") { agents.refresh() }
            case .servers:
                ExtrasIconButton(systemImage: servers.showsAll ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                                 label: servers.showsAll ? "Show dev servers only" : "Show every listening process") { servers.showsAll.toggle() }
            case .ci:
                ExtrasIconButton(systemImage: "arrow.clockwise", label: "Check now") { ci.refreshNow() }
            case .scripts:
                ExtrasIconButton(systemImage: "plus", label: "New Script…") { ScriptEditorWindowController.shared.show(nil) }
            }
            ExtrasIconButton(systemImage: "gearshape", label: "Developer settings") { ExtrasSettingsOpener.open() }
        }
    }
}

/// Opens SparkV's Settings on a pane: through `handler` when the
/// integrator sets it, else through the app shell's `sparkv://settings/<pane>`
/// link (does nothing if no shell handles it).
@MainActor
enum ExtrasSettingsOpener {
    static var handler: ((String) -> Void)?
    static func open(pane: String = "extras") {
        if let handler { handler(pane); return }
        if let url = URL(string: "sparkv://settings/\(pane)") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Servers page

struct DevServersPage: View {
    @ObservedObject private var controller = DevServersController.shared
    @StateObject private var appeared = ViewFlag()

    var body: some View {
        Group {
            if controller.servers.isEmpty {
                ExtrasNotice(symbol: "network",
                             title: controller.lastScan == nil ? "Looking for local servers…" : "No dev servers running",
                             detail: "Ports your own processes listen on (npm run dev, rails s, python -m http.server) show here. Checked only while this page is open.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(controller.servers.enumerated()), id: \.element.id) { index, server in
                            DevServerRow(server: server, controller: controller)
                                .sparkVStaggeredEntrance(appeared.isOn, index: index)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .onAppear {
            appeared.isOn = true
            controller.beginViewing()
        }
        .onDisappear {
            appeared.isOn = false
            controller.endViewing()
        }
    }
}

struct DevServerRow: View {
    let server: DevServer
    @ObservedObject var controller: DevServersController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        HStack(spacing: 8) {
            Text(":\(String(server.port))")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(SparkVTheme.isApple ? Color.accentColor : SparkVTheme.red)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Text("\(server.process) · pid \(String(server.pid))")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: server.isLoopbackOnly ? "lock.fill" : "wifi")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(server.isLoopbackOnly ? SparkVTheme.textTertiary : SparkVTheme.warning)
                .help(server.isLoopbackOnly ? "Only this Mac can reach it" : "Reachable from your network")
                .accessibilityLabel(server.isLoopbackOnly ? "Local only" : "Open to the network")
            ExtrasIconButton(systemImage: "doc.on.doc", label: "Copy URL") { controller.copyURL(server) }
            ExtrasCapsuleButton(title: "Open", systemImage: "safari") { controller.open(server) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .sparkVHoverFill(hover.isOn, cornerRadius: 8)
        .onHover { hover.isOn = $0 }
        .contextMenu {
            Button("Open http://localhost:\(String(server.port))") { controller.open(server) }
            Button("Copy URL") { controller.copyURL(server) }
            if server.folder != nil { Button("Open Folder") { controller.revealFolder(server) } }
            Divider()
            Button("Stop Server (\(server.process))") { controller.stopServer(server) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Port \(server.port), \(server.title), \(server.process)")
        .accessibilityAction(named: "Open") { controller.open(server) }
    }
}

// MARK: - CI page

struct DevCIPage: View {
    @ObservedObject private var controller = DevCIController.shared

    var body: some View {
        if !controller.isEnabled {
            ExtrasNotice(symbol: "checkmark.seal",
                         title: "GitHub Actions is off",
                         detail: "Shows your latest workflow runs and tells you when one fails. Turning it on asks api.github.com for the repos you add.",
                         action: ("Set Up", { ExtrasSettingsOpener.open() }))
        } else if controller.repos.isEmpty {
            ExtrasNotice(symbol: "plus.rectangle.on.folder",
                         title: "No repositories yet",
                         detail: "Add owner/repo in Settings › Extras. Public repos need no token; private ones need a read-only token.",
                         action: ("Add Repo", { ExtrasSettingsOpener.open() }))
        } else {
            VStack(spacing: 0) {
                if let note = statusNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.warning)
                        .lineLimit(1)
                        .padding(.top, 5)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(controller.repos, id: \.self) { repo in
                            if let run = controller.runs[repo]?.first {
                                DevCIRow(run: run) { controller.open(run) }
                            } else {
                                HStack {
                                    Text(repo).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                                    Spacer()
                                    Text("Waiting for GitHub…").font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private var statusNote: String? {
        switch controller.status {
        case .error(let message): message
        case .rateLimited(let until): "GitHub rate limit reached" + (until.map { ", back at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        default: nil
        }
    }
}

struct DevCIRow: View {
    let run: CIRun
    let open: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                outcomeIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.workflow + (run.number.map { " #\($0)" } ?? ""))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    Text([run.repo, run.branch, run.event].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let updated = run.updatedAt {
                    Text(ExtrasFormat.ago(updated))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textTertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .sparkVHoverFill(hover.isOn, cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(run.outcome == .failure ? "Open the failing job on GitHub" : "Open the run on GitHub")
        .accessibilityLabel("\(run.workflow), \(run.repo), \(run.outcome.rawValue)")
    }

    @ViewBuilder
    private var outcomeIcon: some View {
        let (symbol, tint): (String, Color) = switch run.outcome {
        case .success: ("checkmark.circle.fill", SparkVTheme.success)
        case .failure: ("xmark.octagon.fill", SparkVTheme.destructive)
        case .running: ("circle.dotted", SparkVTheme.choose(apple: Color.accentColor, sparkv: SparkVTheme.text))
        case .queued: ("clock", SparkVTheme.textSecondary)
        case .cancelled: ("slash.circle", SparkVTheme.textTertiary)
        case .skipped, .neutral: ("minus.circle", SparkVTheme.textTertiary)
        }
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.rotate, options: .repeating, isActive: run.outcome == .running && !SparkVMotion.reduceMotion)
            .frame(width: 22)
            .accessibilityHidden(true)
    }
}

// MARK: - Hub tile, menu, settings

/// Developer category: the Servers / CI / Scripts pages.
struct DevStatusHubTile: View {
    @ObservedObject private var ci = DevCIController.shared
    var onOpen: (() -> Void)? = nil
    /// Its id in the Agents hub: adds the hub's Pin / Hide / Move items.
    var hubID: String? = nil

    var body: some View {
        let failed = ci.isEnabled && ci.allRuns.contains { $0.outcome == .failure }
        let running = ci.isEnabled && ci.allRuns.contains(where: \.isActive)
        ExtrasHubTileFace(
            title: failed ? "CI Failed" : "Dev",
            systemImage: failed ? "xmark.octagon.fill" : "server.rack",
            tint: failed ? SparkVTheme.destructive : .teal,
            isActive: failed || running,
            help: "Dev Status: local servers, GitHub Actions, scripts"
        ) {
            let nav = DevStatusNavigator.shared
            if nav.section == .agents { nav.section = failed ? .ci : .servers }
            (onOpen ?? nav.openDrawer)()
        }
        .contextMenu {
            DevStatusMenuItems()
            ExtrasHubMenuTail(hubID: hubID)
        }
    }
}

struct DevStatusMenuItems: View {
    @ObservedObject private var ci = DevCIController.shared
    @ObservedObject private var servers = DevServersController.shared

    var body: some View {
        Button("Local Servers") { DevStatusNavigator.shared.open(.servers) }
        Button("GitHub Actions") { DevStatusNavigator.shared.open(.ci) }
        Button("Scripts") { DevStatusNavigator.shared.open(.scripts) }
        Divider()
        Toggle("Watch GitHub Actions", isOn: $ci.isEnabled)
        Toggle("Band When a Run Fails", isOn: $ci.notifiesFailures)
            .disabled(!ci.isEnabled)
        Button("New Script…") { ScriptEditorWindowController.shared.show(nil) }
    }
}

/// Extras pane: local servers and GitHub Actions.
struct DevStatusSettingsSection: View {
    @ObservedObject private var ci = DevCIController.shared
    @ObservedObject private var servers = DevServersController.shared
    @StateObject private var draft = DevCIDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtrasSettingsCard(title: "Local Servers",
                               subtitle: "Ports your own processes listen on, read from the process table (no permission). Checked only while the Servers page is open.",
                               systemImage: "server.rack") {
                ExtrasToggleRow(title: "Show Every Listening Process",
                                detail: "Off: only processes started from a project folder, not app helpers.",
                                isOn: $servers.showsAll)
            }
            ExtrasSettingsCard(title: "GitHub Actions",
                               subtitle: "Your latest workflow runs, and a band when one fails. Off until you turn it on: it asks api.github.com over HTTPS for the repos below.",
                               systemImage: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 6) {
                    ExtrasToggleRow(title: "Watch GitHub Actions",
                                    detail: "Every minute while a run is in progress, every 5 minutes otherwise; paused while the Mac sleeps and in Low Power Mode.",
                                    isOn: $ci.isEnabled)
                    ExtrasToggleRow(title: "Band When a Run Fails", isOn: $ci.notifiesFailures)
                        .disabled(!ci.isEnabled)
                    ExtrasDivider()
                    ForEach(ci.repos, id: \.self) { repo in
                        HStack {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                            Text(repo).font(.system(size: 12, design: .monospaced)).foregroundStyle(SparkVTheme.text)
                            Spacer()
                            ExtrasIconButton(systemImage: "minus.circle", label: "Remove \(repo)") { ci.removeRepo(repo) }
                        }
                        .padding(.horizontal, 8)
                    }
                    HStack(spacing: 8) {
                        TextField("owner/repo or a GitHub URL", text: $draft.repo)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit(addRepo)
                        Button("Add", action: addRepo)
                            .buttonStyle(SparkVSecondaryButtonStyle())
                            .disabled(CIParsing.normalizeRepo(draft.repo) == nil)
                    }
                    .padding(.horizontal, 8)
                    ExtrasDivider()
                    HStack(spacing: 8) {
                        SecureField(ci.hasToken ? "Token saved in the keychain" : "Optional token (read-only, Actions)", text: $draft.token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Button(ci.hasToken && draft.token.isEmpty ? "Remove" : "Save") {
                            ci.setToken(draft.token)
                            draft.token = ""
                        }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .disabled(!ci.hasToken && draft.token.isEmpty)
                    }
                    .padding(.horizontal, 8)
                    ExtrasNote(text: "Public repos work without a token (60 requests an hour). Use a fine-grained token with read-only Actions access for private repos; it stays in your keychain and is never logged.",
                               systemImage: "key")
                }
            }
        }
    }

    private func addRepo() {
        if ci.addRepo(draft.repo) { draft.repo = "" }
    }
}

@MainActor
final class DevCIDraft: ObservableObject {
    @Published var repo = ""
    @Published var token = ""
}
