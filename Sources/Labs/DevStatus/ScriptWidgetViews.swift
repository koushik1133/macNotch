import AppKit
import SwiftUI

// MARK: - Drawer page

struct ScriptWidgetsPage: View {
    @ObservedObject private var controller = ScriptWidgetsController.shared
    @StateObject private var appeared = ViewFlag()

    var body: some View {
        Group {
            if controller.configs.isEmpty {
                ExtrasNotice(symbol: "terminal",
                             title: "No scripts yet",
                             detail: "Show a command's output here, xbar-style: the first line big, the rest below. Presets include crypto prices, disk space and git status.",
                             action: ("New Script…", { ScriptEditorWindowController.shared.show(nil) }))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(controller.configs.enumerated()), id: \.element.id) { index, config in
                            ScriptWidgetRow(config: config, state: controller.states[config.id], controller: controller)
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

enum ScriptLineColor {
    static func color(_ name: String?) -> Color? {
        guard let name else { return nil }
        switch name {
        case "red": return SparkVTheme.destructive
        case "green": return SparkVTheme.success
        case "orange", "yellow": return SparkVTheme.warning
        case "blue": return SparkVTheme.choose(apple: Color.accentColor, sparkv: SparkVTheme.text)
        case "gray", "grey": return SparkVTheme.textSecondary
        default:
            guard name.hasPrefix("#"), name.count == 7, let value = UInt32(name.dropFirst(), radix: 16) else { return nil }
            return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
    }
}

struct ScriptWidgetRow: View {
    let config: ScriptWidgetConfig
    let state: ScriptWidgetsController.RunState?
    @ObservedObject var controller: ScriptWidgetsController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: config.showsInWings ? "pin.fill" : "terminal")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(config.showsInWings ? SparkVTheme.accent : SparkVTheme.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .help(config.showsInWings ? "Shown beside the notch" : config.title)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                outputLine
            }
            Spacer(minLength: 4)
            if config.isApproved {
                if let last = state?.lastRun {
                    Text(ExtrasFormat.ago(last))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                if state?.isRunning == true {
                    ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
                        .frame(width: 22, height: 22)
                } else {
                    ExtrasIconButton(systemImage: "arrow.clockwise", label: "Run \(config.title) now") { controller.runNow(config.id) }
                }
            } else {
                ExtrasCapsuleButton(title: "Review & Run", systemImage: "eye") { ScriptEditorWindowController.shared.show(config) }
                    .help("See the command before it runs for the first time")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .sparkVHoverFill(hover.isOn, cornerRadius: 8)
        .onHover { hover.isOn = $0 }
        .contextMenu {
            if let menu = state?.output.menu, !menu.isEmpty {
                ForEach(Array(menu.enumerated()), id: \.offset) { _, line in
                    if let link = line.link {
                        Button(line.text) { NSWorkspace.shared.open(link) }
                    } else {
                        Text(line.text)
                    }
                }
                Divider()
            }
            Button("Run Now") { controller.runNow(config.id) }.disabled(!config.isApproved)
            Button("Edit…") { ScriptEditorWindowController.shared.show(config) }
            Button(config.showsInWings ? "Remove from Beside the Notch" : "Show Beside the Notch") {
                controller.setShowsInWings(config.id, !config.showsInWings)
            }
            .disabled(!config.isApproved)
            Divider()
            Button("Move Up") { controller.move(config.id, by: -1) }
            Button("Move Down") { controller.move(config.id, by: 1) }
            Button("Delete") { controller.remove(config.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(config.title): \(state?.output.headline?.text ?? state?.error ?? "not run yet")")
    }

    @ViewBuilder
    private var outputLine: some View {
        if !config.isApproved {
            Text(config.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if let error = state?.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.warning)
                .lineLimit(1)
        } else if let headline = state?.output.headline {
            HStack(spacing: 6) {
                Text(headline.text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ScriptLineColor.color(headline.color) ?? SparkVTheme.text)
                    .lineLimit(1)
                if let extra = state?.output.body.first {
                    Text(extra.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ScriptLineColor.color(extra.color) ?? SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .onTapGesture { if let link = headline.link { NSWorkspace.shared.open(link) } }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if let link = headline.link { NSWorkspace.shared.open(link) } }
        } else {
            Text(state?.isRunning == true ? "Running…" : "No output yet")
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
    }
}

/// A Widgets-grid cell for one script (optional integration, see
/// INTEGRATION.md): headline big, body lines below.
struct ScriptWidgetCell: View {
    @ObservedObject private var controller = ScriptWidgetsController.shared
    var compact = false

    var body: some View {
        let config = controller.configs.first(where: \.isApproved) ?? controller.configs.first
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "terminal.fill").font(.system(size: 9, weight: .semibold))
                Text(config?.title ?? "Scripts").font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(SparkVTheme.textSecondary)
            if let config, config.isApproved, let state = controller.states[config.id], let headline = state.output.headline {
                Text(headline.text)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ScriptLineColor.color(headline.color) ?? SparkVTheme.text)
                    .lineLimit(compact ? 2 : 1)
                    .minimumScaleFactor(0.7)
                if !compact {
                    ForEach(Array(state.output.body.prefix(2).enumerated()), id: \.offset) { _, line in
                        Text(line.text).font(.system(size: 10)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
                    }
                }
            } else {
                Text(config == nil ? "Add a script" : "Review it first")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let config, !config.isApproved { ScriptEditorWindowController.shared.show(config) }
            else if config == nil { ScriptEditorWindowController.shared.show(nil) }
        }
        .onAppear { controller.beginViewing() }
        .onDisappear { controller.endViewing() }
    }
}

// MARK: - Editor window

@MainActor
final class ScriptDraft: ObservableObject {
    @Published var title: String
    @Published var command: String
    @Published var interval: Int
    @Published var timeout: Int
    @Published var showsInWings: Bool
    let original: ScriptWidgetConfig?

    init(_ config: ScriptWidgetConfig?) {
        original = config
        title = config?.title ?? ""
        command = config?.command ?? ""
        interval = config?.intervalSeconds ?? 300
        timeout = config?.timeoutSeconds ?? 10
        showsInWings = config?.showsInWings ?? false
    }

    var config: ScriptWidgetConfig {
        var base = original ?? ScriptWidgetConfig(title: "", command: "", intervalSeconds: 300, timeoutSeconds: 10)
        base.title = title
        base.command = command
        base.intervalSeconds = interval
        base.timeoutSeconds = timeout
        base.showsInWings = showsInWings
        return base.normalized()
    }

    func apply(_ preset: ScriptPresets.Preset) {
        title = preset.title
        command = preset.command
        interval = preset.interval
    }
}

@MainActor
final class ScriptEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = ScriptEditorWindowController()
    private var window: NSWindow?

    /// nil: a new script.
    func show(_ config: ScriptWidgetConfig?) {
        window?.close()
        let draft = ScriptDraft(config)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = config == nil ? "New Script" : "Edit Script"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScriptEditorView(draft: draft, close: { [weak window] in window?.close() }).followsAppearance())
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}

struct ScriptEditorView: View {
    @ObservedObject var draft: ScriptDraft
    let close: () -> Void
    @ObservedObject private var controller = ScriptWidgetsController.shared

    private static let intervals: [(Int, String)] = [(60, "1 min"), (300, "5 min"), (900, "15 min"), (1800, "30 min"), (3600, "1 hour"), (21600, "6 hours")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.original == nil ? "New Script" : "Edit Script")
                    .font(SparkVTheme.title(18))
                    .foregroundStyle(SparkVTheme.text)
                Spacer()
                Menu("Presets") {
                    ForEach(ScriptPresets.all) { preset in
                        Button(preset.title + (preset.usesNetwork ? " (internet)" : "")) { draft.apply(preset) }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Presets")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Name").font(.system(size: 11, weight: .semibold)).foregroundStyle(SparkVTheme.textSecondary)
                TextField("Crypto prices", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Command (runs with /bin/zsh -lc)").font(.system(size: 11, weight: .semibold)).foregroundStyle(SparkVTheme.textSecondary)
                TextEditor(text: $draft.command)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                    .accessibilityLabel("Command")
                Text("First line of output is the headline; lines after --- go in the right-click menu; add | href=https://… to make a line a link, | color=red to color it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Refresh Every").font(.system(size: 11, weight: .semibold)).foregroundStyle(SparkVTheme.textSecondary)
                    Picker("", selection: $draft.interval) {
                        ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityLabel("Refresh every")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Time Limit").font(.system(size: 11, weight: .semibold)).foregroundStyle(SparkVTheme.textSecondary)
                    Stepper("\(draft.timeout) s", value: $draft.timeout, in: ScriptWidgetConfig.minimumTimeout...ScriptWidgetConfig.maximumTimeout)
                        .font(.system(size: 12).monospacedDigit())
                }
                Spacer()
            }
            ExtrasToggleRow(title: "Show Beside the Notch",
                            detail: "Its first line stays in the island wings and refreshes while the drawer is closed (at most once per interval).",
                            isOn: $draft.showsInWings)
                .padding(.horizontal, -8)
            warning
            HStack {
                if let original = draft.original {
                    Button("Delete") {
                        controller.remove(original.id)
                        close()
                    }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(run: false) }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .disabled(draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // Running is never the default action: it takes a click.
                Button("Save & Run") { save(run: true) }
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .disabled(draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .padding(.top, 10)
        .frame(width: 560)
        .background(SparkVTheme.background)
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(SparkVTheme.warning)
                .accessibilityHidden(true)
            Text("This command runs on your Mac with your permissions, like in Terminal. SparkV runs it only after you choose Save & Run, and again only while its widget is on screen (or beside the notch, if you pin it). Commands never sync or import.")
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SparkVTheme.warning.opacity(0.10)))
    }

    private func save(run: Bool) {
        var config = draft.config
        if let original = draft.original {
            controller.update(config)
            config = controller.configs.first { $0.id == original.id } ?? config
        } else {
            controller.add(config)
            config = controller.configs.last ?? config
        }
        if run { controller.approveAndRun(config.id) }
        if draft.showsInWings { controller.setShowsInWings(config.id, true) }
        close()
    }
}

// MARK: - Hub tile, menu, settings

/// Developer category: the Scripts page.
struct ScriptWidgetHubTile: View {
    @ObservedObject private var controller = ScriptWidgetsController.shared
    var onOpen: (() -> Void)? = nil
    /// Its id in the Agents hub: adds the hub's Pin / Hide / Move items.
    var hubID: String? = nil

    var body: some View {
        let pinned = controller.wingScript
        let headline = pinned.flatMap { controller.states[$0.id]?.output.headline?.text }
        ExtrasHubTileFace(
            title: headline.map { ExtrasFormat.wingText($0, limit: 12) } ?? "Scripts",
            systemImage: "terminal.fill",
            tint: Color(white: 0.78),
            isActive: pinned != nil,
            help: "Scripts: your shell commands' output, xbar-style"
        ) {
            DevStatusNavigator.shared.section = .scripts
            (onOpen ?? DevStatusNavigator.shared.openDrawer)()
        }
        .contextMenu {
            ScriptWidgetMenuItems()
            ExtrasHubMenuTail(hubID: hubID)
        }
    }
}

struct ScriptWidgetMenuItems: View {
    @ObservedObject private var controller = ScriptWidgetsController.shared

    var body: some View {
        ForEach(controller.configs) { config in
            Button("Run \(config.title)") { controller.runNow(config.id) }
                .disabled(!config.isApproved)
        }
        if !controller.configs.isEmpty { Divider() }
        Button("New Script…") { ScriptEditorWindowController.shared.show(nil) }
        Menu("Add Preset") {
            ForEach(ScriptPresets.all) { preset in
                Button(preset.title) {
                    let config = controller.addPreset(preset)
                    ScriptEditorWindowController.shared.show(config)
                }
            }
        }
    }
}

/// Extras pane: every script, presets (tickers live here) and the rules.
struct ScriptWidgetSettingsSection: View {
    @ObservedObject private var controller = ScriptWidgetsController.shared

    var body: some View {
        ExtrasSettingsCard(title: "Scripts & Tickers",
                           subtitle: "Shell commands whose output shows in the Dev tab or beside the notch. Each runs only after you review it, at most once a minute, with a 30-second limit.",
                           systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(controller.configs) { config in
                    HStack(spacing: 8) {
                        Image(systemName: config.showsInWings ? "pin.fill" : "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(config.showsInWings ? SparkVTheme.accent : SparkVTheme.textTertiary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(config.title).font(.system(size: 12, weight: .medium)).foregroundStyle(SparkVTheme.text)
                            Text(config.command)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(SparkVTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if !config.isApproved {
                            ExtrasPill(text: "Not reviewed", tint: SparkVTheme.warning)
                        }
                        Text("Every " + ExtrasFormat.every(config.intervalSeconds))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(SparkVTheme.textSecondary)
                        Button("Edit…") { ScriptEditorWindowController.shared.show(config) }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
                if controller.configs.isEmpty {
                    ExtrasNote(text: "No scripts yet.", systemImage: "tray")
                }
                ExtrasDivider()
                HStack(spacing: 8) {
                    Button("New Script…") { ScriptEditorWindowController.shared.show(nil) }
                        .buttonStyle(SparkVPrimaryButtonStyle())
                    Menu("Add Preset") {
                        ForEach(ScriptPresets.all) { preset in
                            Button(preset.title + (preset.isTemplate ? " (template)" : "")) {
                                ScriptEditorWindowController.shared.show(controller.addPreset(preset))
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                }
                .padding(.horizontal, 8)
                ExtrasNote(text: "Tickers are presets: crypto prices come from CoinGecko's free public API (no key, delayed, not financial advice). No stock quote API is free, keyless and reliable, so the stock preset is a template for your own provider's key. Presets that use the internet say so.",
                           systemImage: "chart.line.uptrend.xyaxis")
            }
        }
    }
}
