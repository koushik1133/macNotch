import AppKit
import Carbon.HIToolbox
import SwiftUI

// Global, remappable keyboard shortcuts for the island: one to open and
// close it (⌃⌥O by default, off until switched on in Settings › Island or
// Settings › Accessibility) and one per drawer tab (none assigned until you
// record one). Saved in UserDefaults under "SparkV.drawerShortcuts.*".
// Hotkeys are Carbon `RegisterEventHotKey` (ScreenRegionHotkey): no
// Accessibility permission, no event tap, nothing runs between presses.
//
// Opened by one of these, the drawer takes the keyboard: ← → (or Tab when
// Full Keyboard Access is off) move between the header's tabs, ⌘1–⌘9 jump
// to one, Esc closes and hands the keyboard back to the app you were in.

/// What a drawer shortcut does.
enum DrawerShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case toggle
    case home, widgets, tray, today, converter, spaces, agents, flow, clicky

    var id: String { rawValue }

    /// The header control (Customize Layout id) a tab action opens.
    var headerID: String? { self == .toggle ? nil : rawValue }

    var tab: NotchState.Tab? { headerID.flatMap(HeaderTabs.tab(for:)) }

    var title: String {
        switch self {
        case .toggle: "Open and close the drawer"
        default: "Open " + (headerID.flatMap { HeaderCatalog.info($0)?.title } ?? rawValue.capitalized)
        }
    }

    static let tabActions: [DrawerShortcutAction] = allCases.filter { $0 != .toggle }
}

@MainActor
final class DrawerShortcutStore: ObservableObject {
    static let shared = DrawerShortcutStore()

    nonisolated static let prefix = Key.prefix
    /// Posted when a shortcut changes or recording starts or ends, so the
    /// open/close hotkey (Labs/IslandInteraction) re-registers.
    static let didChangeNotification = Notification.Name("SparkV.drawerShortcuts.didChange")
    static let defaultToggle = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey))

    nonisolated enum Key {
        static let prefix = "SparkV.drawerShortcuts."
        static let keyboardNavigation = prefix + "keyboardNavigation"
        static func shortcut(_ action: DrawerShortcutAction) -> String { prefix + action.rawValue }
    }

    /// Assigned shortcuts (the toggle is always present: ⌃⌥O unless changed).
    @Published private(set) var shortcuts: [DrawerShortcutAction: ScreenRegionShortcut] = [:]
    /// Tab shortcuts macOS refused (another app, or SparkV itself, owns them).
    @Published private(set) var taken: Set<DrawerShortcutAction> = []
    /// ← → / Tab / ⌘1–⌘9 move between tabs in a drawer opened by keyboard.
    @Published var keyboardNavigation: Bool {
        didSet { defaults.set(keyboardNavigation, forKey: Key.keyboardNavigation) }
    }
    /// A recorder is waiting for keys: every drawer hotkey is let go so the
    /// combination reaches it.
    @Published private(set) var isRecording = false

    /// The window controller opens or closes the drawer on a tab.
    var onTabShortcut: ((NotchState.Tab) -> Void)?

    private let defaults = UserDefaults.standard
    private var hotkeys: [DrawerShortcutAction: ScreenRegionHotkey] = [:]
    private var started = false

    private init() {
        keyboardNavigation = defaults.object(forKey: Key.keyboardNavigation) as? Bool ?? true
        var loaded: [DrawerShortcutAction: ScreenRegionShortcut] = [:]
        for action in DrawerShortcutAction.allCases {
            if let data = defaults.data(forKey: Key.shortcut(action)),
               let shortcut = try? JSONDecoder().decode(ScreenRegionShortcut.self, from: data), shortcut.isValidGlobal {
                loaded[action] = shortcut
            }
        }
        shortcuts = loaded
    }

    var toggleShortcut: ScreenRegionShortcut { shortcuts[.toggle] ?? Self.defaultToggle }

    func shortcut(for action: DrawerShortcutAction) -> ScreenRegionShortcut? {
        action == .toggle ? toggleShortcut : shortcuts[action]
    }

    /// The action already using `shortcut`, if any.
    func owner(of shortcut: ScreenRegionShortcut, except: DrawerShortcutAction) -> DrawerShortcutAction? {
        DrawerShortcutAction.allCases.first { $0 != except && self.shortcut(for: $0) == shortcut }
    }

    /// Assigns (or, with nil, clears; for the toggle, resets to ⌃⌥O).
    /// Returns a message when it could not be used.
    @discardableResult
    func set(_ shortcut: ScreenRegionShortcut?, for action: DrawerShortcutAction) -> String? {
        if let shortcut {
            guard shortcut.isValidGlobal else { return "Use ⌃, ⌥ or ⌘" }
            if let other = owner(of: shortcut, except: action) { return "Used by “\(other.title)”" }
        }
        if let shortcut, !(action == .toggle && shortcut == Self.defaultToggle) {
            shortcuts[action] = shortcut
            if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: Key.shortcut(action)) }
        } else {
            shortcuts[action] = nil
            defaults.removeObject(forKey: Key.shortcut(action))
        }
        AppLog.log("Shortcuts: \(action.rawValue) → \(self.shortcut(for: action)?.displayString ?? "none")")
        if action != .toggle { applyTabHotkeys() }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if action != .toggle, taken.contains(action) { return "Taken by another app" }
        return nil
    }

    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        applyTabHotkeys()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: Hotkeys

    func start() {
        guard !started else { return }
        started = true
        applyTabHotkeys()
    }

    func stop() {
        guard started else { return }
        started = false
        applyTabHotkeys()
    }

    private func applyTabHotkeys() {
        var nowTaken: Set<DrawerShortcutAction> = []
        for action in DrawerShortcutAction.tabActions {
            let want = started && !isRecording ? shortcuts[action] : nil
            guard let want else {
                hotkeys[action]?.unregister()
                hotkeys[action] = nil
                continue
            }
            if let existing = hotkeys[action], existing.isRegistered, existing.shortcut == want { continue }
            let hotkey = hotkeys[action] ?? ScreenRegionHotkey()
            hotkey.onPress = { [weak self] in
                guard let self, let tab = action.tab else { return }
                guard !LayoutSettings.shared.effectiveHeader.featureOff.contains(action.rawValue) else {
                    AppLog.log("Shortcuts: \(action.rawValue) is switched off (Customize Layout › Features)")
                    return
                }
                self.onTabShortcut?(tab)
            }
            if !hotkey.register(want) {
                nowTaken.insert(action)
                AppLog.log("Shortcuts: \(want.displayString) for \(action.rawValue) is taken")
            }
            hotkeys[action] = hotkey
        }
        // Keep "taken" for shortcuts still assigned but idle while recording.
        if isRecording { nowTaken.formUnion(taken.filter { shortcuts[$0] != nil }) }
        if nowTaken != taken { taken = nowTaken }
    }

    // MARK: Keyboard navigation (drawer opened by keyboard)

    /// The header's tabs, left to right, as Customize Layout shows them.
    static func headerTabs() -> [NotchState.Tab] {
        let placement = LayoutSettings.shared.effectiveHeader.placement(recording: false)
        var seen = Set<NotchState.Tab>()
        return (placement.left + placement.right).compactMap { HeaderTabs.tab(for: $0) }.filter { seen.insert($0).inserted }
    }

    /// Spoken name of a tab ("Tray").
    static func title(of tab: NotchState.Tab) -> String {
        if let id = HeaderCatalog.items.first(where: { HeaderTabs.tab(for: $0.id) == tab })?.id {
            return HeaderCatalog.info(id)?.title ?? "Drawer"
        }
        return NotchState.Tab.agentTabs.contains(tab) ? "Agents" : "Drawer"
    }
}

// MARK: - Settings

/// Settings › Accessibility › Keyboard Shortcuts.
struct DrawerShortcutsSettingsSection: View {
    @ObservedObject private var store = DrawerShortcutStore.shared
    @ObservedObject private var interaction = IslandInteractionSettings.shared

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    DrawerShortcutRecorder(action: .toggle)
                    Toggle("On", isOn: $interaction.toggleHotkeyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Open and close shortcut on")
                }
            } label: {
                Text("Open and close the drawer")
                Text("Opens at once on the last tab; a second press closes it, even when kept open.")
            }
            ForEach(DrawerShortcutAction.tabActions) { action in
                LabeledContent(action.title) {
                    DrawerShortcutRecorder(action: action)
                }
            }
            Toggle(isOn: $store.keyboardNavigation) {
                Text("Arrow keys move between tabs")
                Text("When a shortcut opens the drawer: ← → (or Tab), ⌘1–⌘9 jump to a tab, Esc closes.")
            }
        } header: {
            Text("Keyboard Shortcuts")
        } footer: {
            Text("Click a shortcut, then press the new keys (with ⌃, ⌥ or ⌘). Esc cancels, ⌫ clears. Tab shortcuts are off until you set one. A drawer opened by keyboard closes with Esc and gives the keyboard back to the app you were in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Click, then press the new combination (Esc cancels, Delete clears).
struct DrawerShortcutRecorder: View {
    let action: DrawerShortcutAction
    @ObservedObject private var store = DrawerShortcutStore.shared
    @StateObject private var model = DrawerShortcutRecorderModel()

    var body: some View {
        let current = store.shortcut(for: action)
        HStack(spacing: 6) {
            if let message = model.message, !model.isRecording {
                Text(message).font(.system(size: 10)).foregroundStyle(SparkVTheme.warning)
            } else if action != .toggle, store.taken.contains(action) {
                Label("Taken by another app", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.warning)
            }
            Button {
                if model.isRecording { model.end() } else { model.begin(action: action) }
            } label: {
                Text(model.isRecording ? "Type a shortcut" : (current?.displayString ?? "Record Shortcut"))
                    .font(.system(size: 12, weight: .medium, design: model.isRecording || current == nil ? .default : .rounded))
                    .frame(minWidth: 110)
            }
            .help("Click, then press the new shortcut. Esc cancels, Delete clears.")
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(model.isRecording ? "Recording, press the new keys" : (current?.displayString ?? "None"))
            .accessibilityHint("Press to record a new shortcut")
            if !model.isRecording, action == .toggle ? store.shortcuts[.toggle] != nil : current != nil {
                Button {
                    model.message = store.set(nil, for: action)
                } label: {
                    Image(systemName: action == .toggle ? "arrow.counterclockwise" : "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(action == .toggle ? "Reset to \(DrawerShortcutStore.defaultToggle.displayString)" : "Clear")
                .accessibilityLabel(action == .toggle ? "Reset to \(DrawerShortcutStore.defaultToggle.displayString)" : "Clear \(action.title) shortcut")
            }
        }
        .onDisappear { model.end() }
    }
}

@MainActor
final class DrawerShortcutRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var message: String?
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?

    func begin(action: DrawerShortcutAction) {
        end()
        isRecording = true
        message = nil
        DrawerShortcutStore.shared.setRecording(true)
        // Closing the window mid-recording must not leave a key monitor behind.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
                self.end()
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete), flags.isEmpty {
                self.end()
                self.message = DrawerShortcutStore.shared.set(nil, for: action)
                return nil
            }
            let shortcut = ScreenRegionShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
            guard shortcut.isValidGlobal else {
                self.message = "Use ⌃, ⌥ or ⌘"
                SparkVAssistive.announce("Use Control, Option or Command")
                return nil
            }
            self.end()
            self.message = DrawerShortcutStore.shared.set(shortcut, for: action)
            SparkVAssistive.announce(self.message ?? "\(action.title): \(shortcut.displayString)")
            return nil
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if isRecording {
            isRecording = false
            DrawerShortcutStore.shared.setRecording(false)
        }
    }
}
