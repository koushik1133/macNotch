import SwiftUI

// Settings › Shortcuts: every keyboard shortcut SparkV has, in one list.
// These are the default keys. The features own their hotkeys (and, where
// they can be changed or switched off, the setting for it); this file only
// lists them, grouped like the Agents hub.

/// One shortcut in the list.
struct ShortcutReferenceItem: Identifiable, Equatable, Sendable {
    let keys: String
    let title: String
    /// A short note: "off until switched on", where to change it…
    var note: String?

    var id: String { keys + title }
}

/// A named group of shortcuts.
struct ShortcutReferenceGroup: Identifiable, Equatable, Sendable {
    let title: String
    let symbol: String
    let items: [ShortcutReferenceItem]

    var id: String { title }
}

enum ShortcutReference {
    static let groups: [ShortcutReferenceGroup] = [
        ShortcutReferenceGroup(title: "Island", symbol: "rectangle.topthird.inset.filled", items: [
            ShortcutReferenceItem(keys: "⌃⌥O", title: "Open and close the drawer", note: "Off until switched on below"),
            ShortcutReferenceItem(keys: "⌃⌥H", title: "Hide or show the island", note: "Off until switched on in Island"),
            ShortcutReferenceItem(keys: "⌃⌥A", title: "Show the next live activity"),
            ShortcutReferenceItem(keys: "⌃⌥B", title: "Show menu bar icons hidden by the notch"),
            ShortcutReferenceItem(keys: "⌘,", title: "Settings", note: "While SparkV is in front"),
        ]),
        ShortcutReferenceGroup(title: "Write", symbol: "text.cursor", items: [
            ShortcutReferenceItem(keys: "Hold fn", title: "Dictate while held", note: "Double-tap for hands-free. The key is chosen in Flow."),
            ShortcutReferenceItem(keys: "⌃⌘V", title: "Paste the last dictation"),
            ShortcutReferenceItem(keys: "⌃⌘C", title: "Copy the last dictation"),
            ShortcutReferenceItem(keys: "⌘⇧V", title: "Open the clipboard stack"),
            ShortcutReferenceItem(keys: "⌘ 1…9 V", title: "Paste copy number 1 to 9", note: "Hold ⌘, tap the number, then V"),
            ShortcutReferenceItem(keys: "⌃⌥R", title: "Draft a reply"),
        ]),
        ShortcutReferenceGroup(title: "Screen", symbol: "viewfinder", items: [
            ShortcutReferenceItem(keys: "Hold ⌃⌥", title: "Ask Clicky about your screen"),
            ShortcutReferenceItem(keys: "⌃⌥S", title: "Ask about part of the screen"),
            ShortcutReferenceItem(keys: "⌃⌥T", title: "Copy text from the screen"),
            ShortcutReferenceItem(keys: "⌃⌥P", title: "Pick a color"),
            ShortcutReferenceItem(keys: "⌃⌥⇧R", title: "Record the screen", note: "Press again to stop"),
        ]),
        ShortcutReferenceGroup(title: "Files and search", symbol: "magnifyingglass", items: [
            ShortcutReferenceItem(keys: "⌥Space", title: "Search everything"),
            ShortcutReferenceItem(keys: "⌃⌥C", title: "Capture what you're looking at to Spaces"),
        ]),
        ShortcutReferenceGroup(title: "Focus and planner", symbol: "calendar", items: [
            ShortcutReferenceItem(keys: "⌃⌥1…5", title: "Switch mode 1 to 5 on or off"),
            ShortcutReferenceItem(keys: "⌃⌥J", title: "Join the next meeting"),
            ShortcutReferenceItem(keys: "⌃⌥⇧P", title: "Start, pause or silence the timer"),
            ShortcutReferenceItem(keys: "fn ⌃", title: "Job Agent: capture the job on screen"),
        ]),
        ShortcutReferenceGroup(title: "Sound and presenting", symbol: "speaker.wave.2", items: [
            ShortcutReferenceItem(keys: "⌃⌥M", title: "Mute the microphone for every app"),
            ShortcutReferenceItem(keys: "⌃⌥⇧T", title: "Show or close the teleprompter"),
            ShortcutReferenceItem(keys: "⌃⌥⇧Space", title: "Play or pause the teleprompter"),
            ShortcutReferenceItem(keys: "⌃⌥⇧↑ ↓", title: "Teleprompter speed"),
        ]),
    ]

    /// Shortcuts listed under more than one action (a list mistake, or two
    /// features on the same keys).
    static var duplicateKeys: [String] {
        let all = groups.flatMap(\.items).map(\.keys)
        return Array(Set(all.filter { key in all.filter { $0 == key }.count > 1 })).sorted()
    }
}

/// Settings › Shortcuts: the whole list, one group per card section.
struct ShortcutsReferenceSettingsSection: View {
    var body: some View {
        ForEach(ShortcutReference.groups) { group in
            Section {
                ForEach(group.items) { item in
                    LabeledContent {
                        ShortcutKeysLabel(keys: item.keys)
                    } label: {
                        Text(item.title)
                        if let note = item.note { Text(note) }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Label(group.title, systemImage: group.symbol)
            } footer: {
                if group.id == ShortcutReference.groups.last?.id {
                    Text("These are the default keys. A shortcut does nothing while its feature is off, and one that another app already uses stays with that app. Drawer shortcuts can be changed below; a feature that lets you change its keys does so on its own page.")
                        .settingsFooterStyle()
                }
            }
        }
    }
}

/// The keys in a quiet rounded cap, like a menu's shortcut column.
struct ShortcutKeysLabel: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .accessibilityLabel(ShortcutKeysLabel.spoken(keys))
    }

    /// "⌃⌥S" as "Control Option S" for VoiceOver.
    static func spoken(_ keys: String) -> String {
        let names: [Character: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command", "↑": "Up", "↓": "Down", "…": "to"]
        return keys.map { names[$0] ?? String($0) }.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }
}
