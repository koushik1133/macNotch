import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Summary panel

/// The recap card, floating under the notch when a session ends. A
/// non-activating panel so it never steals focus from the user's work.
@MainActor
final class FocusSummaryWindowController {
    static let shared = FocusSummaryWindowController()

    private var panel: NSPanel?
    /// Bumped on every show (see FocusOverlayController).
    private var generation = 0

    func show(controller: FocusController) {
        guard controller.lastSummary != nil else { return }
        generation &+= 1
        let panel = panel ?? makePanel()
        self.panel = panel
        let root = FocusSummaryPanelRoot(controller: controller) { [weak self] in self?.close() }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        let size = host.fittingSize
        // The notched display, like NotchWindowController, so the card sits under the island.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let menuBar = max(screen?.safeAreaInsets.top ?? 0, frame.maxY - (screen?.visibleFrame.maxY ?? frame.maxY - 38))
        // Below the 46 pt summary band that hangs from the notch at the same time.
        let top = frame.maxY - menuBar - NotchMetrics.activityAnswerBandHeight - 12
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = .sparkVEaseOut
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        let shownGeneration = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = .sparkVEaseOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.generation == shownGeneration else { return }
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

/// Follows `lastSummary`, so the model's recap replaces the template in place.
struct FocusSummaryPanelRoot: View {
    @ObservedObject var controller: FocusController
    var onClose: () -> Void

    var body: some View {
        if let record = controller.lastSummary {
            FocusSummaryCard(controller: controller, record: record, onClose: onClose)
                .environment(\.colorScheme, .dark)
                .followsAppearance()
        }
    }
}

// MARK: - Settings window

@MainActor
final class FocusSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = FocusSettingsWindowController()
    private var window: NSWindow?

    func show(controller: FocusController) {
        let window = window ?? makeWindow(controller: controller)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(controller: FocusController) -> NSWindow {
        let hosting = NSHostingController(rootView: FocusSettingsView(controller: controller, model: FocusSettingsModel(controller: controller)).followsAppearance())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Focus"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 720))
        window.center()
        window.setFrameAutosaveName("SparkV.Focus")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Text fields and async state for the settings view (no @State).
@MainActor
final class FocusSettingsModel: ObservableObject {
    @Published var newSite = ""
    @Published var permissionNote: String?
    let controller: FocusController

    init(controller: FocusController) {
        self.controller = controller
    }

    func addSite() {
        guard let site = FocusBlockRules.normalizeSite(newSite) else { return }
        if !controller.settings.blockedSites.contains(site) { controller.settings.blockedSites.append(site) }
        newSite = ""
    }

    func addApp(url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        add(FocusBlockedApp(bundleID: id, name: name))
    }

    func add(_ app: FocusBlockedApp) {
        guard !controller.settings.blockedApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        controller.settings.blockedApps.append(app)
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addApp)
    }

    func check(force: Bool) {
        let s = controller.settings
        Task {
            await controller.doNotDisturb.refresh(on: s.dndOnShortcut, off: s.dndOffShortcut, force: force)
            // Adopt a pair other apps' guides use when ours doesn't exist.
            if case .missing = controller.doNotDisturb.setup,
               s.dndOnShortcut == FocusSettings.defaultOnShortcut,
               let pair = FocusDoNotDisturb.detectPair(in: controller.doNotDisturb.library),
               pair.on != s.dndOnShortcut {
                controller.settings.dndOnShortcut = pair.on
                controller.settings.dndOffShortcut = pair.off
                await controller.doNotDisturb.refresh(on: pair.on, off: pair.off)
            }
        }
    }

    func test(on: Bool) {
        let s = controller.settings
        Task {
            let outcome = on ? await controller.doNotDisturb.turnOn(s.dndOnShortcut) : await controller.doNotDisturb.turnOff(s.dndOffShortcut)
            permissionNote = switch outcome {
            case .done: on ? "Do Not Disturb should be on now." : "Do Not Disturb should be off now."
            case .notSetUp: "Create the shortcut first."
            case .failed(let message): "The shortcut failed: \(FocusText.clip(message, 90))"
            }
        }
    }

    func allowBrowsers() {
        Task {
            let result = await FocusDistractionGuard.requestBrowserPermissions()
            if result.isEmpty {
                permissionNote = "Open your browser first, then allow it here."
            } else {
                permissionNote = result.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value ? "allowed" : "not allowed")" }.joined(separator: " · ")
            }
        }
    }
}

struct FocusSettingsView: View {
    @ObservedObject var controller: FocusController
    @ObservedObject var model: FocusSettingsModel
    @ObservedObject private var dnd: FocusDoNotDisturb
    @ObservedObject private var store: FocusStore

    init(controller: FocusController, model: FocusSettingsModel) {
        self.controller = controller
        self.model = model
        self.dnd = controller.doNotDisturb
        self.store = controller.store
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                section("Rounds", systemImage: "timer") { roundsSection }
                section("Screen Effects", systemImage: "rays") { effectsSection }
                section("Do Not Disturb", systemImage: "moon.zzz.fill") { dndSection }
                section("Distractions", systemImage: "hand.raised.fill") { distractionsSection }
                section("Summary", systemImage: "sparkles") { summarySection }
                section("History", systemImage: "chart.bar.fill") { historySection }
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 600, minHeight: 640)
        .background(LabsBWindowGround(glow: 0.8).ignoresSafeArea())
        .tint(SparkVTheme.accent)
        .foregroundStyle(SparkVTheme.text)
        .environment(\.colorScheme, .dark)
        .onAppear { model.check(force: false) }
    }

    private var binding: Binding<FocusSettings> { $controller.settings }

    // MARK: Sections

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(FocusPalette.accent)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(LabsBStyle.activeCardFill(FocusPalette.accent)))
                .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.red.opacity(0.35)))
            VStack(alignment: .leading, spacing: 4) {
                LabsBEyebrow("SparkV / Focus")
                Text("Focus")
                    .font(SparkVTheme.title(26))
                    .tracking(-0.8)
                    .foregroundStyle(SparkVTheme.text)
                Text("One tap mutes notifications, runs focus rounds, keeps distractions away and ends with a recap.")
                    .font(SparkVTheme.body(12))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Spacer()
            Button(controller.isActive ? "End Focus" : "Start Focus") { controller.toggle() }
                .buttonStyle(SparkVPrimaryButtonStyle())
        }
    }

    private var roundsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(FocusSettings.presets, id: \.focus) { preset in
                    let selected = controller.settings.focusMinutes == preset.focus && controller.settings.shortBreakMinutes == preset.rest
                    Button {
                        controller.settings.focusMinutes = preset.focus
                        controller.settings.shortBreakMinutes = preset.rest
                    } label: {
                        Text("\(preset.focus) / \(preset.rest)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(selected ? SparkVTheme.text : SparkVTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(selected ? SparkVTheme.choose(apple: SparkVTheme.accent, sparkv: SparkVTheme.redSoft) : SparkVTheme.surface))
                            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(selected ? LabsBStyle.selectedStroke : LabsBStyle.chipStroke))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SparkVPressStyle())
                }
            }
            Stepper("Focus: \(controller.settings.focusMinutes) min", value: binding.focusMinutes, in: 5...180, step: 5)
            Stepper("Short break: \(controller.settings.shortBreakMinutes) min", value: binding.shortBreakMinutes, in: 1...30)
            Stepper("Long break: \(controller.settings.longBreakMinutes) min", value: binding.longBreakMinutes, in: 5...60, step: 5)
            Stepper("Long break after \(controller.settings.longBreakEvery) rounds", value: binding.longBreakEvery, in: 2...8)
            Picker("Rounds per session", selection: binding.rounds) {
                ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                Text("Until I stop").tag(0)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            Text("Rounds run on SparkV’s timer, so they also show in Today and chime when they end.")
                .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A glowing border lights up every screen when focus starts (\(SparkVTheme.isApple ? "indigo" : "SparkV red")), when a break starts (green and amber) and when the session ends.")
                .font(.system(size: 12)).foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Border", selection: binding.edgeGlow) {
                ForEach(FocusEdgeGlowMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Group {
                Toggle("Shake the border and the notch band for a moment", isOn: binding.edgeGlowKick)
                Toggle("Tap the trackpad too (felt on Force Touch trackpads)", isOn: binding.edgeGlowHaptics)
                    .disabled(!controller.settings.edgeGlowKick)
                Toggle("Confetti when a session is completed", isOn: binding.edgeGlowConfetti)
            }
            .disabled(controller.settings.edgeGlow == .off)
            HStack(spacing: 8) {
                Text("Preview").font(.system(size: 12, weight: .semibold))
                ForEach(FocusGlowMood.allCases, id: \.self) { mood in
                    Button(mood.title) { controller.previewEdgeGlow(mood) }
                        .tint(FocusEffectSwatch.color(for: mood))
                }
            }
            Text(FocusEdgeGlowController.systemReduceMotion
                 ? "Reduce Motion is on, so the border just fades in and out."
                 : "The border never takes clicks and asks to be left out of screenshots and screen sharing (some recorders still capture it). With Reduce Motion on, it just fades.")
                .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    private var dndSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Turn on Do Not Disturb while focusing", isOn: binding.usesDoNotDisturb)
            HStack(spacing: 8) {
                statusDot
                Text(statusText).font(.system(size: 12))
                Spacer()
                Button("Check Again") { model.check(force: true) }
                    .buttonStyle(SparkVSecondaryButtonStyle())
            }
            HStack(spacing: 10) {
                shortcutPicker("On", selection: binding.dndOnShortcut)
                shortcutPicker("Off", selection: binding.dndOffShortcut)
            }
            if dnd.setup != .ready {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(FocusDoNotDisturb.guideSteps(on: controller.settings.dndOnShortcut, off: controller.settings.dndOffShortcut).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(SparkVTheme.choose(apple: Color.white.opacity(0.14), sparkv: SparkVTheme.redSoft)))
                                .overlay(Circle().strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.red.opacity(0.5)))
                            Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Button("Open Shortcuts") { FocusDoNotDisturb.openShortcutsToCreate() }
                            .buttonStyle(SparkVPrimaryButtonStyle())
                        Text("macOS has no public switch for Focus; a Shortcut is Apple’s supported way.")
                            .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
            } else {
                HStack {
                    Button("Test On") { model.test(on: true) }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                    Button("Test Off") { model.test(on: false) }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            Text("SparkV’s own notification previews are always muted during a session, even without the shortcuts.")
                .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
            if let note = model.permissionNote {
                Text(note).font(.system(size: 11)).foregroundStyle(SparkVTheme.warning)
            }
        }
    }

    private func shortcutPicker(_ title: String, selection: Binding<String>) -> some View {
        let names = Array(Set(dnd.library + [selection.wrappedValue])).sorted()
        return Picker(title, selection: selection) {
            ForEach(names, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260)
    }

    private var statusDot: some View {
        Circle()
            .fill(dnd.setup == .ready ? SparkVTheme.success : (dnd.setup == .checking || dnd.setup == .unknown ? SparkVTheme.textTertiary : SparkVTheme.warning))
            .frame(width: 8, height: 8)
    }

    private var statusText: String {
        switch dnd.setup {
        case .unknown, .checking: return "Checking your Shortcuts…"
        case .ready: return "Ready: “\(controller.settings.dndOnShortcut)” and “\(controller.settings.dndOffShortcut)”"
        case .missing(let names): return "Missing: " + names.map { "“\($0)”" }.joined(separator: ", ")
        case .failed(let message): return "Couldn’t read Shortcuts: \(FocusText.clip(message, 60))"
        }
    }

    private var distractionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show a gentle reminder when a distraction comes to the front", isOn: binding.blocksDistractions)
            Stepper("Snooze: \(controller.settings.snoozeMinutes) min", value: binding.snoozeMinutes, in: 1...30)
            Text("Apps").font(SparkVTheme.headline(12))
            FocusChips(items: controller.settings.blockedApps.map { ($0.bundleID, $0.name) }) { id in
                controller.settings.blockedApps.removeAll { $0.bundleID == id }
            }
            HStack {
                Button("Add App…") { model.chooseApp() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Menu("Suggestions") {
                    ForEach(FocusBlockRules.suggestedApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }) { app in
                        Button(app.name) { model.add(app) }
                    }
                }
                .fixedSize()
            }
            Text("Sites").font(SparkVTheme.headline(12))
            FocusChips(items: controller.settings.blockedSites.map { ($0, $0) }) { site in
                controller.settings.blockedSites.removeAll { $0 == site }
            }
            HStack {
                TextField("youtube.com", text: $model.newSite)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { model.addSite() }
                Button("Add") { model.addSite() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Menu("Suggestions") {
                    ForEach(FocusBlockRules.suggestedSites, id: \.self) { site in
                        Button(site) {
                            if !controller.settings.blockedSites.contains(site) { controller.settings.blockedSites.append(site) }
                        }
                    }
                }
                .fixedSize()
            }
            HStack {
                Button("Allow Site Checks in Browsers…") { model.allowBrowsers() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Text("Reads only the front tab’s address in Safari, Chrome, Arc, Edge or Brave.")
                    .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Note window and document titles (needs Accessibility)", isOn: binding.tracksWindowTitles)
            Toggle("Write the recap with the on-device model", isOn: binding.summarizesWithModel)
            Text(MeetingAIBackend.onDeviceAvailable
                 ? "Recaps are written on this Mac. Nothing leaves it."
                 : "On-device model unavailable (\(MeetingAIBackend.onDeviceUnavailableReason ?? "unknown")); SparkV writes a short recap itself.")
                .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    private var historySection: some View {
        let stats = FocusStats.compute(store.sessions, now: Date())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FocusStatTile(value: FocusText.compact(stats.todaySeconds), label: "today · \(stats.todaySessions) sessions", tint: FocusPalette.accent)
                FocusStatTile(value: FocusText.compact(stats.weekSeconds), label: "last 7 days", tint: SparkVTheme.text)
                FocusStatTile(value: "\(stats.streakDays)", label: stats.streakDays == 1 ? "day streak" : "days streak", tint: SparkVTheme.text)
            }
            FocusWeekBars(days: stats.days.map(\.seconds), accent: FocusPalette.accent, maxHeight: 40)
                .frame(height: 40)
            ForEach(store.sessions.prefix(8)) { s in
                HStack {
                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11.5).monospacedDigit())
                        .frame(width: 150, alignment: .leading)
                    Text(FocusText.duration(s.focusedSeconds))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .frame(width: 80, alignment: .leading)
                    Text(s.apps.prefix(2).map(\.name).joined(separator: ", "))
                        .font(.system(size: 11.5)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
                    Spacer()
                    Button("Recap") { showRecap(s) }.buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            if store.sessions.isEmpty {
                Text("No sessions yet.").font(.system(size: 12)).foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    private func showRecap(_ record: FocusSessionRecord) {
        let alert = NSAlert()
        alert.messageText = "Focus · \(FocusText.duration(record.focusedSeconds))"
        alert.informativeText = record.summary
        alert.runModal()
    }

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 16)
                LabsBEyebrow(title)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous).strokeBorder(FocusPalette.line))
    }
}

/// Removable chips that wrap onto new lines.
struct FocusChips: View {
    let items: [(id: String, title: String)]
    let onRemove: (String) -> Void

    var body: some View {
        if items.isEmpty {
            Text("None yet").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
        } else {
            FocusWrapLayout(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    HStack(spacing: 4) {
                        Text(item.title).font(.system(size: 11.5))
                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(SparkVPressStyle())
                        .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(SparkVTheme.surface))
                    .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                }
            }
        }
    }
}

/// Minimal wrapping layout (left to right, then down).
struct FocusWrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, maxX), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Button tints for the effect previews.
enum FocusEffectSwatch {
    static func color(for mood: FocusGlowMood) -> Color {
        switch mood {
        case .focus: FocusPalette.accent
        case .relax: FocusPalette.rest
        case .celebrate: SparkVTheme.warning
        }
    }
}
