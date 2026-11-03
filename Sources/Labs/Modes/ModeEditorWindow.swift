import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Modes editor, laid out like Focus in System Settings: modes in a
// sidebar, and for the selected one its icon and name, what happens when it
// turns on (an ordered list of actions, each with its own small editor), and
// what happens when it ends.

// MARK: - Window

@MainActor
final class ModeEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = ModeEditorWindowController()
    private var window: NSWindow?
    let model = ModeEditorModel(engine: .shared)

    func show() { show(selecting: nil) }

    /// Opens the editor, optionally on one mode.
    func show(selecting id: UUID?) {
        if let id { model.select(id) } else { model.ensureSelection() }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ModeEditorView(model: model).followsAppearance())
        let window = NSWindow(contentViewController: hosting)
        window.title = "SparkV Modes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.isReleasedWhenClosed = false
        window.setContentSize(ModeEditorView.preferredSize)
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.center()
        window.setFrameAutosaveName("SparkV.Modes")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.stopTest()
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Action kinds (editor side)

extension ModeStepKind {
    /// Tile accent. Apple gives each action its own System Settings–style
    /// color; SparkV Red keeps action tiles monochrome (dark tile, white
    /// glyph) and the brand red marks the step being edited.
    var tint: Color {
        guard SparkVTheme.isApple else { return SparkVTheme.red }
        return switch self {
        case .wallpaper: Color.cyan
        case .music: Color.pink
        case .volume: Color.blue
        case .brightness: Color.yellow
        case .darkMode: Color(white: 0.55)
        case .doNotDisturb, .focusSession: Color.indigo
        case .muteNotificationsPreviews: Color.red
        case .pomodoro: Color.orange
        case .openApps: Color.blue
        case .hideApps: Color(white: 0.55)
        case .quitApps: Color.red
        case .openURLs: Color.teal
        case .runShortcut: Color.purple
        }
    }

    /// Groups in the Add Action menu.
    static let editorGroups: [(String, [ModeStepKind])] = [
        ("Look & Sound", [.wallpaper, .music, .volume, .brightness, .darkMode]),
        ("Quiet", [.doNotDisturb, .muteNotificationsPreviews, .focusSession, .pomodoro]),
        ("Apps & Web", [.openApps, .hideApps, .quitApps, .openURLs]),
        ("Automation", [.runShortcut]),
    ]

    /// Kinds a mode holds only once (a second wallpaper would just win).
    var isSingle: Bool {
        switch self {
        case .openApps, .hideApps, .quitApps, .openURLs, .runShortcut: false
        default: true
        }
    }

    /// What a new step starts as: a preset or curated stream rather than
    /// an empty value, so a new step works right away.
    var editorDefaultAction: ModeAction {
        switch self {
        case .wallpaper: .wallpaper(ModeWallpaperFactory.presets.first?.choice ?? .solid(colorHex: "#000000"))
        case .music: .music(ModeMusicLibrary.entries.first?.choice ?? ModeMusicChoice(title: ModeMusicLibrary.customURLTitle, url: ""))
        default: defaultAction
        }
    }
}

extension ModeAction {
    /// One line under the action's title: "Pure Black", "35%", "Slack, Mail".
    @MainActor var editorSummary: String {
        switch self {
        case .wallpaper(let choice): ModeWallpaperFactory.title(for: choice)
        case .music(let music):
            music.url.isEmpty ? "Choose music" : music.openInBackground ? "\(music.title) · in the background" : music.title
        case .volume(let v), .brightness(let v): "\(ModeAction.percent(v))%"
        case .muteNotificationsPreviews(let on): on ? "Hidden while the mode is on" : "Shown"
        case .focusSession: "SparkV Focus: timer and quieter notifications"
        case .openApps(let ids), .hideApps(let ids), .quitApps(let ids):
            ids.isEmpty ? "No apps chosen" : ModeAppCatalog.listText(ids)
        case .openURLs(let urls):
            urls.isEmpty ? "No websites yet" : urls.map(ModeAppCatalog.shortHost).joined(separator: ", ")
        case .runShortcut(let name): name.isEmpty ? "No shortcut chosen" : "“\(name)”"
        default: detail
        }
    }
}

// MARK: - Model

/// Selection, expanded rows and other editor state (no @State in this build).
@MainActor
final class ModeEditorModel: ObservableObject {
    let engine: ModeEngine
    @Published var selectedID: UUID?
    /// The action row whose editor is open, by index in the selected mode.
    @Published var expandedAction: Int?
    @Published var confirmingDelete = false
    /// The Icon & Color grid is folded away until asked for.
    @Published var showsAppearance = false
    @Published var shortcutNames: [String] = []
    @Published var shortcutsNote: String?
    @Published var testNote: String?
    /// Its own player, so testing never touches the active mode's music.
    let testPlayer = ModeMusicPlayer()

    init(engine: ModeEngine) {
        self.engine = engine
        selectedID = engine.activeModeID ?? engine.modes.first?.id
    }

    var selected: SparkMode? { engine.modes.first { $0.id == selectedID } }

    func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        expandedAction = nil
        showsAppearance = false
    }

    func ensureSelection() {
        if selected == nil { select(engine.activeModeID ?? engine.modes.first?.id) }
    }

    /// The selected mode as a binding that saves through the engine.
    func binding(_ id: UUID) -> Binding<SparkMode> {
        Binding(
            get: { [engine] in
                engine.modes.first { $0.id == id }
                    ?? SparkMode(id: id, name: "", symbol: "circle", colorHex: "#5E5CE6", actions: [], restoreOnExit: true, autoEndMinutes: nil)
            },
            set: { [engine] in engine.update($0) }
        )
    }

    func newMode() {
        let mode = SparkMode(id: UUID(), name: uniqueName("New Mode"), symbol: "sparkles",
                             colorHex: ModeColors.swatches[engine.modes.count % ModeColors.swatches.count],
                             actions: [], restoreOnExit: true, autoEndMinutes: nil)
        engine.add(mode)
        select(mode.id)
        showsAppearance = true
    }

    func duplicateSelected() {
        guard let id = selectedID else { return }
        let before = Set(engine.modes.map(\.id))
        engine.duplicate(id)
        if let copy = engine.modes.first(where: { !before.contains($0.id) }) { select(copy.id) }
    }

    func deleteSelected() {
        guard let id = selectedID, let index = engine.modes.firstIndex(where: { $0.id == id }) else { return }
        // Deleting the active mode ends it first (the engine restores).
        engine.delete(id)
        let next = engine.modes.indices.contains(index) ? engine.modes[index] : engine.modes.last
        select(next?.id)
    }

    func moveSelected(by offset: Int) {
        guard let id = selectedID, let index = engine.modes.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard engine.modes.indices.contains(target) else { return }
        engine.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(engine.modes.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // Actions

    func addAction(_ kind: ModeStepKind, to id: UUID) {
        let mode = binding(id)
        if kind.isSingle, let existing = mode.wrappedValue.actions.firstIndex(where: { $0.kind == kind }) {
            expandedAction = existing
            return
        }
        mode.wrappedValue.actions.append(kind.editorDefaultAction)
        expandedAction = mode.wrappedValue.actions.count - 1
    }

    func removeAction(at index: Int, from id: UUID) {
        let mode = binding(id)
        guard mode.wrappedValue.actions.indices.contains(index) else { return }
        mode.wrappedValue.actions.remove(at: index)
        if expandedAction == index { expandedAction = nil }
        else if let open = expandedAction, open > index { expandedAction = open - 1 }
    }

    func moveAction(at index: Int, by offset: Int, in id: UUID) {
        let mode = binding(id)
        let target = index + offset
        guard mode.wrappedValue.actions.indices.contains(index), mode.wrappedValue.actions.indices.contains(target) else { return }
        mode.wrappedValue.actions.swapAt(index, target)
        if expandedAction == index { expandedAction = target }
        else if expandedAction == target { expandedAction = index }
    }

    func toggleExpanded(_ index: Int) {
        expandedAction = expandedAction == index ? nil : index
    }

    // Shortcuts library

    func loadShortcuts() {
        shortcutsNote = "Loading your shortcuts…"
        Task {
            do {
                shortcutNames = try await ShortcutRunner().listShortcuts()
                shortcutsNote = shortcutNames.isEmpty ? "Your Shortcuts library is empty." : nil
            } catch {
                shortcutsNote = error.localizedDescription
            }
        }
    }

    // Music test

    /// Plays `choice` with the editor's own player, or stops it if it is
    /// the one playing. Errors show under the Test button.
    func test(_ choice: ModeMusicChoice) {
        if testPlayer.isPlaying, testPlayer.current?.url == choice.url { stopTest(); return }
        do {
            _ = try ModeMusicSource.parse(choice.url)
        } catch {
            testNote = error.localizedDescription
            return
        }
        testNote = nil
        Task {
            do {
                try await testPlayer.start(choice)
            } catch {
                testNote = error.localizedDescription
            }
        }
    }

    func stopTest() {
        testNote = nil
        guard testPlayer.isPlaying else { return }
        Task { await testPlayer.stop() }
    }
}

// MARK: - Root view

struct ModeEditorView: View {
    static let preferredSize = NSSize(width: 820, height: 640)
    @ObservedObject var model: ModeEditorModel

    var body: some View {
        HStack(spacing: 0) {
            ModeSidebar(model: model, engine: model.engine)
                .frame(width: 220)
            Rectangle().fill(SparkVTheme.stroke).frame(width: 1)
            Group {
                if let id = model.selected?.id {
                    ModeDetail(model: model, mode: model.binding(id), engine: model.engine)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LabsBWindowGround(glow: 0.6).ignoresSafeArea())
        .tint(SparkVTheme.accent)
        .foregroundStyle(SparkVTheme.text)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { model.ensureSelection() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "switch.2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(SparkVTheme.textTertiary)
            Text("No mode selected")
                .font(SparkVTheme.title(17))
                .tracking(-0.3)
            Text("A mode sets up your Mac in one click: wallpaper, music, apps and Do Not Disturb.")
                .font(.system(size: 12))
                .foregroundStyle(SparkVTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("New Mode") { model.newMode() }
                .buttonStyle(SparkVPrimaryButtonStyle())
        }
    }
}

// MARK: - Sidebar

/// Motion for the Modes editor (tokens from SparkVMotion).
private enum ModeMotion {
    /// Disclosure rows and inline editors opening: strong ease-out, 180 ms;
    /// Reduce Motion keeps a short fade.
    static var disclose: Animation { SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)) }
    /// The sidebar selection pill sliding to another mode: strong ease-in-out.
    static var selection: Animation { SparkVMotion.respecting(SparkVMotion.easeInOut()) }
}

private struct ModeSidebar: View {
    @ObservedObject var model: ModeEditorModel
    @ObservedObject var engine: ModeEngine
    @Namespace private var selectionPill

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabsBEyebrow("SparkV / Modes")
                .padding(.horizontal, 18)
                .padding(.top, 40)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(engine.modes) { mode in
                        ModeSidebarRow(mode: mode,
                                       isSelected: model.selectedID == mode.id,
                                       isActive: engine.activeModeID == mode.id,
                                       selectionPill: selectionPill) {
                            model.select(mode.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .animation(ModeMotion.selection, value: model.selectedID)
            }
            Spacer(minLength: 0)
            Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
            HStack(spacing: 2) {
                ModeBarButton(systemImage: "plus", help: "New Mode") { model.newMode() }
                ModeBarButton(systemImage: "minus", help: "Delete Mode") { model.confirmingDelete = true }
                    .disabled(model.selected == nil)
                ModeBarButton(systemImage: "plus.square.on.square", help: "Duplicate Mode") { model.duplicateSelected() }
                    .disabled(model.selected == nil)
                Spacer()
                Menu {
                    Button("Move Up") { model.moveSelected(by: -1) }
                    Button("Move Down") { model.moveSelected(by: 1) }
                    Divider()
                    if let selected = model.selected, engine.isBuiltIn(selected.id) {
                        Button("Reset “\(selected.name)” to Original") { engine.resetBuiltIn(selected.id) }
                    }
                    Button("Restore All Built-in Modes") { engine.resetBuiltIns() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 24)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
        .background {
            if SparkVTheme.isApple {
                VisualEffectBackdrop(material: .sidebar, blending: .behindWindow).ignoresSafeArea()
            } else {
                Color.white.opacity(0.02)
            }
        }
        .foregroundStyle(SparkVTheme.textSecondary)
        .confirmationDialog(
            "Delete “\(model.selected?.name ?? "")”?",
            isPresented: $model.confirmingDelete
        ) {
            Button("Delete Mode", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("This removes the mode and its actions. It doesn’t change anything on your Mac.")
        }
    }
}

private struct ModeSidebarRow: View {
    let mode: SparkMode
    let isSelected: Bool
    let isActive: Bool
    let selectionPill: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ModeBadge(symbol: mode.symbol, colorHex: mode.colorHex, size: 24)
                Text(mode.name.isEmpty ? "Untitled" : mode.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isActive {
                    HStack(spacing: 4) {
                        Circle().fill(SparkVTheme.choose(apple: SparkVTheme.success, sparkv: SparkVTheme.red)).frame(width: 5, height: 5)
                        Text("ON")
                            .font(SparkVTheme.eyebrow(9))
                            .tracking(LabsBStyle.eyebrowTracking(0.8))
                            .foregroundStyle(SparkVTheme.choose(apple: SparkVTheme.success, sparkv: SparkVTheme.red))
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .sparkVHoverFill(hover.isOn && !isSelected, cornerRadius: SparkVTheme.cornerSmall)
            .background {
                // One pill that slides between rows (matched geometry).
                if isSelected {
                    RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                        .fill(SparkVTheme.surfaceHover)
                        .overlay(
                            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                                .strokeBorder(SparkVTheme.stroke)
                        )
                        .matchedGeometryEffect(id: "selection", in: selectionPill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }

}

private struct ModeBarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Detail

private struct ModeDetail: View {
    @ObservedObject var model: ModeEditorModel
    @Binding var mode: SparkMode
    @ObservedObject var engine: ModeEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ModeGroup(
                    title: "When \(mode.name.isEmpty ? "this mode" : mode.name) turns on",
                    footer: "Actions run from top to bottom."
                ) { actions }
                ModeGroup(title: "When it ends") { options }
                ModeGroup(title: "Icon & Color") {
                    Button {
                        withAnimation(ModeMotion.disclose) { model.showsAppearance.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            ModeBadge(symbol: mode.symbol, colorHex: mode.colorHex, size: 26)
                            Text("Change Icon and Color")
                                .font(.system(size: 13))
                                .foregroundStyle(SparkVTheme.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(SparkVTheme.textTertiary)
                                .rotationEffect(.degrees(model.showsAppearance ? 90 : 0))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if model.showsAppearance {
                        ModeRowDivider()
                        appearance
                    }
                }
                problems
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    /// The last error, and the steps that failed while this mode is on.
    @ViewBuilder private var problems: some View {
        // lastError already lists the failed steps when it is set.
        let failures = engine.activeModeID == mode.id && engine.lastError == nil ? engine.failures : []
        if engine.lastError != nil || !failures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let error = engine.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                }
                ForEach(failures) { failure in
                    Label(failure.text, systemImage: "xmark.circle")
                }
                if engine.lastError != nil {
                    Button("Dismiss") { engine.lastError = nil }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(SparkVTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Header: big icon, name, on/off.

    private var header: some View {
        let isActive = engine.activeModeID == mode.id
        return HStack(spacing: 16) {
            Button {
                withAnimation(ModeMotion.disclose) { model.showsAppearance = true }
            } label: {
                ModeBadge(symbol: mode.symbol, colorHex: mode.colorHex, size: 58)
            }
            .buttonStyle(SparkVPressStyle())
            .help("Change Icon and Color")
            VStack(alignment: .leading, spacing: 4) {
                TextField("Mode Name", text: $mode.name)
                    .textFieldStyle(.plain)
                    .font(SparkVTheme.title(24))
                    .tracking(-0.6)
                    .foregroundStyle(SparkVTheme.text)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                Task { await engine.toggle(mode.id) }
            } label: {
                Text(engine.isBusy ? "Working…" : isActive ? "Turn Off" : "Turn On")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? SparkVTheme.text : Color.white)
                    .fixedSize()
                    .padding(.horizontal, 16)
                    .frame(minWidth: 96, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                            .fill(isActive ? SparkVTheme.surface : SparkVTheme.accent)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                            .strokeBorder(isActive ? SparkVTheme.stroke : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous))
            }
            .buttonStyle(SparkVPressStyle())
            .fixedSize()
            .disabled(engine.isBusy)
            .help(isActive ? (mode.restoreOnExit ? "Turn off and put your setup back" : "Turn off") : "Turn on now")
        }
    }

    private var headerSubtitle: String {
        let count = mode.actions.count
        var parts = [count == 0 ? "No actions yet" : count == 1 ? "1 action" : "\(count) actions"]
        if let minutes = mode.autoEndMinutes, minutes > 0 { parts.append("ends after \(ModeStatusText.duration(minutes))") }
        if engine.activeModeID == mode.id { parts.insert("On now", at: 0) }
        return parts.joined(separator: " · ")
    }

    // Icon & color

    private static let symbols = [
        "brain.head.profile", "book.fill", "graduationcap.fill", "laptopcomputer", "lightbulb.fill",
        "moon.fill", "moon.stars.fill", "sun.max.fill", "leaf.fill", "cup.and.saucer.fill", "headphones",
        "music.note", "figure.mind.and.body", "figure.run", "gamecontroller.fill", "film.fill", "person.2.fill",
        "video.fill", "briefcase.fill", "house.fill", "bed.double.fill", "sparkles",
        "flame.fill", "bolt.fill", "target", "heart.fill",
    ]

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(ModeColors.swatches, id: \.self) { hex in
                    Button { mode.colorHex = hex } label: {
                        Circle()
                            .fill(ModeColors.color(hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: mode.colorHex.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 0))
                            .padding(2)
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help(hex)
                }
                ColorPicker("Custom Color", selection: ModeColors.binding($mode.colorHex), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 40)
                    .help("Custom Color")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 36), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    let isOn = mode.symbol == symbol
                    Button { mode.symbol = symbol } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isOn ? Color.white : SparkVTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                                    .fill(isOn ? ModeColors.color(mode.colorHex) : SparkVTheme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                                    .strokeBorder(isOn ? Color.clear : SparkVTheme.stroke)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SparkVPressStyle())
                    .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                }
            }
        }
        .padding(14)
    }

    // Actions

    private var actions: some View {
        VStack(spacing: 0) {
            ForEach(Array(mode.actions.enumerated()), id: \.offset) { index, action in
                if index > 0 { ModeRowDivider() }
                ModeActionRow(
                    action: action,
                    isExpanded: model.expandedAction == index,
                    isFirst: index == 0,
                    isLast: index == mode.actions.count - 1,
                    onToggle: { withAnimation(ModeMotion.disclose) { model.toggleExpanded(index) } },
                    onMove: { model.moveAction(at: index, by: $0, in: mode.id) },
                    onRemove: { model.removeAction(at: index, from: mode.id) }
                )
                if model.expandedAction == index, mode.actions.indices.contains(index) {
                    ModeActionEditor(model: model, action: actionBinding(index))
                        .padding(.leading, 52)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                }
            }
            if !mode.actions.isEmpty { ModeRowDivider() }
            addActionMenu
        }
    }

    private func actionBinding(_ index: Int) -> Binding<ModeAction> {
        Binding(
            get: { mode.actions.indices.contains(index) ? mode.actions[index] : .focusSession },
            set: { if mode.actions.indices.contains(index) { mode.actions[index] = $0 } }
        )
    }

    private var addActionMenu: some View {
        let present = Set(mode.actions.map(\.kind))
        return Menu {
            ForEach(ModeStepKind.editorGroups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { kind in
                        Button {
                            withAnimation(ModeMotion.disclose) { model.addAction(kind, to: mode.id) }
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                        .disabled(kind.isSingle && present.contains(kind))
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(SparkVTheme.accent)
                Text("Add Action")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SparkVTheme.accent)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    // Options

    private var options: some View {
        VStack(spacing: 0) {
            ModeToggleRow(
                title: "Put my setup back",
                detail: "Puts back the wallpaper, volume, brightness, appearance and the apps it hid or quit. Music, Do Not Disturb and the Pomodoro always end with the mode.",
                isOn: $mode.restoreOnExit
            )
            ModeRowDivider()
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("End automatically")
                        .font(.system(size: 13))
                    Text(mode.autoEndMinutes.map { "Turns off after \(ModeStatusText.duration($0))." } ?? "Stays on until you turn it off.")
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                Spacer()
                if mode.autoEndMinutes != nil {
                    Stepper(
                        ModeStatusText.duration(mode.autoEndMinutes ?? 60),
                        value: Binding(get: { mode.autoEndMinutes ?? 60 }, set: { mode.autoEndMinutes = $0 }),
                        in: 15...600, step: 15
                    )
                    .font(.system(size: 12).monospacedDigit())
                    .fixedSize()
                }
                Toggle("", isOn: Binding(
                    get: { mode.autoEndMinutes != nil },
                    set: { mode.autoEndMinutes = $0 ? (mode.autoEndMinutes ?? 60) : nil }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Turn off automatically")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Grouped sections

private struct ModeGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LabsBEyebrow(title)
                .padding(.leading, 4)
                .padding(.bottom, 2)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                        .fill(SparkVTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                        .strokeBorder(SparkVTheme.stroke)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }
}

private struct ModeRowDivider: View {
    var body: some View {
        Rectangle().fill(SparkVTheme.stroke).frame(height: 1).padding(.leading, 14)
    }
}

private struct ModeToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Action row

private struct ModeActionRow: View {
    let action: ModeAction
    let isExpanded: Bool
    let isFirst: Bool
    let isLast: Bool
    let onToggle: () -> Void
    let onMove: (Int) -> Void
    let onRemove: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let kind = action.kind
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                        .fill(SparkVTheme.isApple ? kind.tint : (isExpanded || hover.isOn ? SparkVTheme.redSoft : SparkVTheme.surfaceHover))
                        .frame(width: 26, height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                                .strokeBorder(SparkVTheme.isApple ? Color.white.opacity(0.12) : (isExpanded ? kind.tint.opacity(0.6) : SparkVTheme.stroke))
                        )
                        .overlay(
                            // Apple: a System Settings icon (white glyph on
                            // the action's color).
                            Image(systemName: kind.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SparkVTheme.isApple ? Color.white : (isExpanded || hover.isOn ? kind.tint : SparkVTheme.text))
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                            .font(.system(size: 13))
                            .foregroundStyle(SparkVTheme.text)
                        Text(action.editorSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 2) {
                smallButton("chevron.up", help: "Move Up", disabled: isFirst) { onMove(-1) }
                smallButton("chevron.down", help: "Move Down", disabled: isLast) { onMove(1) }
            }
            .opacity(hover.isOn || isExpanded ? 1 : 0.35)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            .buttonStyle(SparkVPressStyle())
            .help("Remove Action")
            .accessibilityLabel("Remove Action")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }

    private func smallButton(_ symbol: String, help: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(disabled ? SparkVTheme.textTertiary.opacity(0.5) : SparkVTheme.textSecondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(disabled ? Color.clear : SparkVTheme.surface))
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Per-action editors

private struct ModeActionEditor: View {
    @ObservedObject var model: ModeEditorModel
    @Binding var action: ModeAction

    var body: some View {
        switch action {
        case .wallpaper(let choice):
            ModeWallpaperEditor(choice: Binding(get: { choice }, set: { action = .wallpaper($0) }))
        case .music(let music):
            ModeMusicEditor(model: model, choice: Binding(get: { music }, set: { action = .music($0) }))
        case .volume(let value):
            ModePercentSlider(label: "Output volume", lowSymbol: "speaker.fill", highSymbol: "speaker.wave.3.fill",
                              value: Binding(get: { value }, set: { action = .volume($0) }))
        case .brightness(let value):
            ModePercentSlider(label: "Display brightness", lowSymbol: "sun.min.fill", highSymbol: "sun.max.fill",
                              value: Binding(get: { value }, set: { action = .brightness($0) }),
                              note: "Built-in display only.")
        case .doNotDisturb(let on):
            ModeOnOffPicker(isOn: Binding(get: { on }, set: { action = .doNotDisturb($0) }),
                            note: "Runs the Do Not Disturb shortcuts named in SparkV’s Focus settings (“SparkV Focus On” and “SparkV Focus Off” by default). If they’re missing, this step says what to set up and the rest of the mode still runs.")
        case .muteNotificationsPreviews(let on):
            ModeOnOffPicker(isOn: Binding(get: { on }, set: { action = .muteNotificationsPreviews($0) }),
                            onTitle: "Hide", offTitle: "Show",
                            note: "Hides the notification previews SparkV shows in the notch.")
        case .darkMode(let dark):
            Picker("", selection: Binding(get: { dark }, set: { action = .darkMode($0) })) {
                Text("Dark").tag(true)
                Text("Light").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .modeNote("macOS asks once to let SparkV control System Events.")
            .accessibilityLabel("Appearance")
        case .pomodoro(let focus, let rest):
            VStack(alignment: .leading, spacing: 8) {
                Stepper("Focus for \(focus) min", value: Binding(get: { focus }, set: { action = .pomodoro(focusMinutes: $0, breakMinutes: rest) }), in: 5...180, step: 5)
                Stepper("Break for \(rest) min", value: Binding(get: { rest }, set: { action = .pomodoro(focusMinutes: focus, breakMinutes: $0) }), in: 1...60)
            }
            .font(.system(size: 12).monospacedDigit())
            .fixedSize()
        case .focusSession:
            Text("Starts a SparkV Focus session: a timer in the notch and quieter notifications, ended with the mode.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .openApps(let ids):
            ModeAppListEditor(ids: Binding(get: { ids }, set: { action = .openApps($0) }), verb: "Open",
                              note: "Opens each app when the mode turns on.")
        case .hideApps(let ids):
            ModeAppListEditor(ids: Binding(get: { ids }, set: { action = .hideApps($0) }), verb: "Hide",
                              note: "Hidden apps keep running and come back when the mode ends.",
                              allowsAllOthers: true)
        case .quitApps(let ids):
            VStack(alignment: .leading, spacing: 10) {
                ModeAppListEditor(ids: Binding(get: { ids }, set: { action = .quitApps($0) }), verb: "Quit",
                                  note: "SparkV asks before quitting each app the first time and never force quits, so unsaved work still prompts.")
                ModeQuitApprovals(ids: ids, engine: model.engine)
            }
        case .openURLs(let urls):
            ModeURLListEditor(urls: Binding(get: { urls }, set: { action = .openURLs($0) }))
        case .runShortcut(let name):
            ModeShortcutEditor(model: model, name: Binding(get: { name }, set: { action = .runShortcut($0) }))
        }
    }
}

private extension View {
    func modeNote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            self
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ModePercentSlider: View {
    let label: String
    let lowSymbol: String
    let highSymbol: String
    @Binding var value: Double
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: lowSymbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $value, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel(label)
                Image(systemName: highSymbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .accessibilityLabel(label)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ModeOnOffPicker: View {
    @Binding var isOn: Bool
    var onTitle = "On"
    var offTitle = "Off"
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $isOn) {
                Text(onTitle).tag(true)
                Text(offTitle).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .accessibilityLabel("\(onTitle) or \(offTitle)")
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Wallpaper

/// What a wallpaper choice looks like, at any size (used for the presets,
/// the live preview and the custom options).
struct ModeWallpaperSwatch: View {
    let choice: ModeWallpaperChoice

    var body: some View {
        switch choice {
        case .solid(let hex):
            ModeColors.color(hex)
        case .gradient(let from, let to):
            // Top to bottom, like the PNG ModeWallpaperFactory renders.
            LinearGradient(colors: [ModeColors.color(from), ModeColors.color(to)], startPoint: .top, endPoint: .bottom)
        case .builtIn(let id):
            ModeWallpaperSwatch(choice: ModeWallpaperFactory.preset(id: id)?.rendering ?? .solid(colorHex: "#000000"))
        case .file(let path):
            if let image = ModeThumbnailCache.image(path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.16)
                    Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

@MainActor
enum ModeThumbnailCache {
    private static var cache: [String: NSImage] = [:]
    private static var purgeRegistered = false

    static func image(_ path: String) -> NSImage? {
        if let hit = cache[path] { return hit }
        guard FileManager.default.isReadableFile(atPath: path),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // 640 px thumbnails: bounded, and dropped under memory pressure.
        if !purgeRegistered {
            purgeRegistered = true
            SparkVEnergy.shared.onMemoryPressure { cache.removeAll() }
        }
        if cache.count >= 24 { cache.removeAll() }
        cache[path] = image
        return image
    }
}

/// A small desktop (menu bar, notch, Dock) showing the chosen wallpaper.
struct ModeDesktopPreview: View {
    let choice: ModeWallpaperChoice
    var width: CGFloat = 200

    var body: some View {
        let height = width * 10 / 16
        ZStack(alignment: .top) {
            ModeWallpaperSwatch(choice: choice)
                .frame(width: width, height: height)
                .clipped()
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: height * 0.07)
            UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                .fill(Color.black)
                .frame(width: width * 0.16, height: height * 0.07)
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: width * 0.45, height: height * 0.08)
                    .padding(.bottom, height * 0.03)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
    }
}

private struct ModeWallpaperEditor: View {
    @Binding var choice: ModeWallpaperChoice

    private enum Style { case preset, solid, gradient, file }

    private var style: Style {
        if ModeWallpaperFactory.presets.contains(where: { choice == $0.choice || choice == $0.rendering }) { return .preset }
        return switch choice {
        case .builtIn: .preset
        case .solid: .solid
        case .gradient: .gradient
        case .file: .file
        }
    }

    var body: some View {
        // Side by side when the window is wide enough; stacked at the
        // editor's minimum width (720 pt), where the row would overflow.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { preview; options }
            VStack(alignment: .leading, spacing: 12) { preview; options }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var preview: some View {
        VStack(spacing: 6) {
            ModeDesktopPreview(choice: choice, width: 180)
            Text(ModeWallpaperFactory.title(for: choice))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180)
        }
    }

    private var options: some View {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
                    ForEach(ModeWallpaperFactory.presets) { preset in
                        tile(preset.name, selected: choice == preset.choice || choice == preset.rendering) {
                            ModeWallpaperSwatch(choice: preset.choice)
                        } action: { choice = preset.choice }
                    }
                    tile("Color", selected: style == .solid) {
                        ZStack {
                            ModeWallpaperSwatch(choice: currentSolid)
                            Image(systemName: "paintpalette.fill").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.8))
                        }
                    } action: { choice = currentSolid }
                    tile("Gradient", selected: style == .gradient) {
                        ModeWallpaperSwatch(choice: currentGradient)
                    } action: { choice = currentGradient }
                    tile("Image…", selected: style == .file) {
                        if case .file = choice { ModeWallpaperSwatch(choice: choice) } else {
                            ZStack {
                                Color.white.opacity(0.08)
                                Image(systemName: "photo.badge.plus").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    } action: { chooseFile() }
                }
                customControls
            }
            // The width of the 4-column tile grid, so a long file path
            // truncates instead of widening the row.
            .frame(width: 4 * 58 + 3 * 8, alignment: .leading)
    }

    private var currentSolid: ModeWallpaperChoice {
        if case .solid = choice, style == .solid { return choice }
        return .solid(colorHex: "#1C1C1E")
    }

    private var currentGradient: ModeWallpaperChoice {
        if case .gradient = choice, style == .gradient { return choice }
        return .gradient(fromHex: "#1C1C3A", toHex: "#5E5CE6")
    }

    @ViewBuilder private var customControls: some View {
        if style != .preset { customEditors }
    }

    @ViewBuilder private var customEditors: some View {
        switch choice {
        case .solid(let hex):
            ColorPicker("Color", selection: ModeColors.binding(Binding(get: { hex }, set: { choice = .solid(colorHex: $0) })), supportsOpacity: false)
                .font(.system(size: 12))
                .fixedSize()
        case .gradient(let from, let to):
            HStack(spacing: 14) {
                ColorPicker("From", selection: ModeColors.binding(Binding(get: { from }, set: { choice = .gradient(fromHex: $0, toHex: to) })), supportsOpacity: false)
                ColorPicker("To", selection: ModeColors.binding(Binding(get: { to }, set: { choice = .gradient(fromHex: from, toHex: $0) })), supportsOpacity: false)
            }
            .font(.system(size: 12))
            .fixedSize()
        case .file(let path):
            HStack(spacing: 8) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(FileManager.default.isReadableFile(atPath: path) ? SparkVTheme.textSecondary : SparkVTheme.warning)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { chooseFile() }.controlSize(.small)
            }
        case .builtIn:
            EmptyView()
        }
    }

    private func tile(_ title: String, selected: Bool, @ViewBuilder preview: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                preview()
                    .frame(width: 58, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(selected ? SparkVTheme.accent : SparkVTheme.stroke, lineWidth: selected ? 2 : 1)
                    )
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .help(title)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for this mode’s wallpaper"
        panel.prompt = "Use Picture"
        if case .file(let path) = choice { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        else { panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choice = .file(path: url.path)
    }
}

// MARK: Music

private struct ModeMusicEditor: View {
    @ObservedObject var model: ModeEditorModel
    @ObservedObject var player: ModeMusicPlayer
    @Binding var choice: ModeMusicChoice

    init(model: ModeEditorModel, choice: Binding<ModeMusicChoice>) {
        self.model = model
        self.player = model.testPlayer
        self._choice = choice
    }

    private var entry: ModeMusicLibraryEntry? { ModeMusicLibrary.entry(matching: choice.url) }
    private var isCustom: Bool { entry == nil }
    private var isTesting: Bool { player.isPlaying && player.current?.url == choice.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(SparkVTheme.choose(apple: Color.pink, sparkv: SparkVTheme.redSoft))
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.choose(apple: Color.white.opacity(0.12), sparkv: SparkVTheme.red.opacity(0.35))))
                    .overlay(Image(systemName: entry?.symbol ?? "link").font(.system(size: 16, weight: .semibold)).foregroundStyle(SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCustom ? (choice.url.isEmpty ? "Custom URL" : choice.title) : (entry?.title ?? choice.title))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let entry {
                            Text(entry.channel)
                            if entry.isLive {
                                Text("LIVE")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(SparkVTheme.recording))
                                    .foregroundStyle(Color.white)
                            }
                        } else {
                            Text(choice.url.isEmpty ? "Paste a YouTube or audio stream link below" : ModeAppCatalog.shortHost(choice.url))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                picker
            }
            if isCustom {
                HStack(spacing: 8) {
                    TextField("Name", text: $choice.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("https://www.youtube.com/watch?v=…", text: $choice.url)
                        .textFieldStyle(.roundedBorder)
                }
                .font(.system(size: 12))
            }
            HStack(spacing: 10) {
                Toggle("Keep Safari in the background", isOn: $choice.openInBackground)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                Button {
                    model.test(choice)
                } label: {
                    Label(isTesting ? "Stop" : "Test", systemImage: isTesting ? "stop.fill" : "play.fill")
                }
                .controlSize(.small)
                .disabled(choice.url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(model.testNote ?? player.statusText ?? "Plays in its own Safari window behind your work; when the mode ends SparkV closes only that window. \(ModeMusicPlayer.autoplayHint)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picker: some View {
        Menu {
            ForEach(ModeMusicLibraryEntry.Category.allCases, id: \.self) { category in
                let items = ModeMusicLibrary.entries(in: category)
                if !items.isEmpty {
                    Section(category.rawValue) {
                        ForEach(items) { item in
                            Toggle(isOn: Binding(get: { entry?.id == item.id }, set: { _ in pick(item) })) {
                                Label(item.isLive ? "\(item.title) (live)" : item.title, systemImage: item.symbol)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("\(ModeMusicLibrary.customURLTitle)…") {
                choice = ModeMusicChoice(title: "Custom", url: "", volume: choice.volume, openInBackground: choice.openInBackground)
            }
        } label: {
            Text("Choose…")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private func pick(_ item: ModeMusicLibraryEntry) {
        choice = ModeMusicChoice(title: item.title, url: item.url, volume: choice.volume, openInBackground: choice.openInBackground)
    }
}

// MARK: Apps

/// Names and icons for bundle identifiers, from the running and installed apps.
@MainActor
enum ModeAppCatalog {
    struct App: Identifiable, Hashable {
        let id: String   // bundle identifier
        let name: String
    }

    /// A bundle id, an app path ("/Applications/Xcode.app") or "*" (all
    /// other apps), as the engine stores them.
    static func name(_ identifier: String) -> String {
        if identifier == ModeAction.allOtherApps || identifier.hasSuffix(".app") || ModeAppNames.known[identifier] != nil {
            return ModeAppNames.displayName(for: identifier)
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first,
           let name = running.localizedName { return name }
        if let url = appURL(identifier) {
            return url.deletingPathExtension().lastPathComponent
        }
        return identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    static func icon(_ identifier: String) -> NSImage? {
        guard let url = appURL(identifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func appURL(_ identifier: String) -> URL? {
        if identifier.hasSuffix(".app") { return URL(fileURLWithPath: identifier) }
        if identifier == ModeAction.allOtherApps { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    static func listText(_ ids: [String]) -> String {
        let names = ids.map(name)
        return names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }

    /// Regular apps running now, by name, without SparkV itself.
    static func runningApps() -> [App] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> App? in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return App(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func shortHost(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private struct ModeAppListEditor: View {
    @Binding var ids: [String]
    let verb: String
    let note: String
    /// Offers "All Other Apps" (hides everything but the front app).
    var allowsAllOthers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ids.isEmpty {
                ModeFlowLayout(spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        HStack(spacing: 5) {
                            if let icon = ModeAppCatalog.icon(id) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            } else if id == ModeAction.allOtherApps {
                                Image(systemName: "square.stack.3d.down.right.fill").font(.system(size: 11))
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: 12))
                            }
                            Text(ModeAppCatalog.name(id)).font(.system(size: 12)).lineLimit(1)
                            Button { ids.removeAll { $0 == id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.45))
                            }
                            .buttonStyle(SparkVPressStyle())
                            .help("Remove \(ModeAppCatalog.name(id))")
                            .accessibilityLabel("Remove \(ModeAppCatalog.name(id))")
                        }
                        .padding(.leading, 6)
                        .padding(.trailing, 5)
                        .frame(height: 24)
                        .background(Capsule().fill(SparkVTheme.surface)).overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                    }
                }
            }
            Menu {
                if allowsAllOthers, !ids.contains(ModeAction.allOtherApps) {
                    Button("All Other Apps (Keep the Front App)") { ids.append(ModeAction.allOtherApps) }
                    Divider()
                }
                let running = ModeAppCatalog.runningApps().filter { !ids.contains($0.id) }
                if !running.isEmpty {
                    Section("Open Now") {
                        ForEach(running) { app in
                            Button(app.name) { ids.append(app.id) }
                        }
                    }
                }
                Divider()
                Button("Choose from Applications…") { chooseApps() }
            } label: {
                Label("Add App to \(verb)", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ids.contains(id) { ids.append(id) }
        }
    }
}

/// Apps in this list the user already allowed SparkV to quit without asking,
/// each with Ask Again.
private struct ModeQuitApprovals: View {
    let ids: [String]
    @ObservedObject var engine: ModeEngine

    var body: some View {
        let approved = engine.quitApprovals.filter(ids.contains)
        if !approved.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quits without asking")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(approved, id: \.self) { id in
                    HStack(spacing: 8) {
                        Text(ModeAppCatalog.name(id)).font(.system(size: 12))
                        Button("Ask Again") {
                            engine.forgetQuitApproval(id)
                            engine.objectWillChange.send()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Wraps chips onto as many lines as they need.
private struct ModeFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: Websites

private struct ModeURLListEditor: View {
    @Binding var urls: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(urls.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("https://", text: Binding(
                        get: { urls.indices.contains(index) ? urls[index] : "" },
                        set: { if urls.indices.contains(index) { urls[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    Button { if urls.indices.contains(index) { urls.remove(at: index) } } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help("Remove")
                    .accessibilityLabel("Remove")
                }
            }
            Button {
                urls.append("https://")
            } label: {
                Label("Add Website", systemImage: "plus").font(.system(size: 12))
            }
            .controlSize(.small)
            Text("Opens in your default browser.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Shortcut

private struct ModeShortcutEditor: View {
    @ObservedObject var model: ModeEditorModel
    @Binding var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Shortcut name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Menu {
                    if model.shortcutNames.isEmpty {
                        Button("Load My Shortcuts") { model.loadShortcuts() }
                    } else {
                        ForEach(model.shortcutNames, id: \.self) { item in
                            Button(item) { name = item }
                        }
                        Divider()
                        Button("Reload") { model.loadShortcuts() }
                    }
                } label: {
                    Text("Choose")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
            Text(model.shortcutsNote ?? "Runs with /usr/bin/shortcuts. Tip: a shortcut with “Set Focus” can turn on any real Focus, like Work or Sleep.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if model.shortcutNames.isEmpty, model.shortcutsNote == nil { model.loadShortcuts() } }
    }
}
