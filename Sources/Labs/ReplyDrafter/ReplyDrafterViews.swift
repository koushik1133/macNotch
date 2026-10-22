import AppKit
import SwiftUI

/// Reply Drafter's page in the drawer (about 508×114 pt, dark), opened from
/// its Agents tile. Needs `ReplyDrafterController` as an environment object.
struct ReplyDrafterDrawerView: View {
    @EnvironmentObject private var controller: ReplyDrafterController

    var body: some View {
        ReplyDrafterDrawerContent(controller: controller, settings: controller.settings)
    }
}

struct ReplyDrafterDrawerContent: View {
    @ObservedObject var controller: ReplyDrafterController
    @ObservedObject var settings: ReplyDrafterSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                Text("Reply Drafter")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text("Drafts in your tone and writes it in the message box. You press Send.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ReplyIconButton(systemImage: "gearshape", help: "Reply Drafter settings") { ReplyDrafterSettingsWindow.shared.show(settings: settings) }
            }
            HStack(spacing: 8) {
                Button { controller.draftReply() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 11, weight: .semibold))
                        Text("Draft Reply").font(.system(size: 12, weight: .semibold))
                        if !controller.shortcutLabel.isEmpty {
                            Text(controller.shortcutLabel).font(.system(size: 10.5, weight: .medium)).opacity(0.65)
                        }
                    }
                    .foregroundStyle(SparkVTheme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(SparkVTheme.accent))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Reads the window in front and drafts a reply")
                Menu {
                    ForEach(ReplyDrafterSettings.tonePresets, id: \.title) { preset in
                        Button(preset.title) { settings.tone = preset.text }
                    }
                    Divider()
                    Button("Custom Tone…") { ReplyDrafterSettingsWindow.shared.show(settings: settings) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").font(.system(size: 9.5, weight: .semibold))
                        Text("Tone: \(settings.tonePresetTitle)").font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(SparkVTheme.text)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .environment(\.colorScheme, .dark)
                Spacer(minLength: 0)
                Text(controller.engineLabel == ReplyDraftEngine.groqName ? "Groq" : (controller.engineLabel == ReplyTemplate.producedBy ? "Basic (Apple Intelligence off)" : "On this Mac"))
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            HStack(spacing: 5) {
                ReplyToggleChip(title: "Write into box", isOn: $settings.autoInsert)
                ReplyToggleChip(title: "Fill subject", isOn: $settings.fillSubject)
                ReplyToggleChip(title: "Use Spaces", isOn: $settings.useSpaces)
                ReplyToggleChip(title: "Read screen", isOn: $settings.readScreen)
                ReplyToggleChip(title: "Groq", isOn: $settings.allowGroq)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ReplyToggleChip: View {
    let title: String
    @Binding var isOn: Bool
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isOn ? SparkVTheme.accent : SparkVTheme.textTertiary)
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
                    .foregroundStyle(SparkVTheme.text)
            }
            .padding(.horizontal, 7)
            .frame(height: 21)
            .background(Capsule().fill(isOn ? SparkVTheme.accentSoft : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(isOn ? SparkVTheme.accent.opacity(0.4) : SparkVTheme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}

/// Header-friendly icon (24×22 pt, same as IconTab, gray → white on hover) that drafts a reply
/// for the window in front.
struct ReplyDrafterNotchButton: View {
    @EnvironmentObject private var controller: ReplyDrafterController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button { controller.draftReply() } label: {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover.isOn ? SparkVTheme.activeGlyph : SparkVTheme.inactiveGlyph)
                .frame(width: 24, height: 22)
                .background(Capsule().fill(hover.isOn ? SparkVTheme.choose(apple: SparkVTheme.hoverFill, sparkv: SparkVTheme.accentSoft) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(controller.shortcutLabel.isEmpty ? "Draft a reply" : "Draft a reply  \(controller.shortcutLabel)")
    }
}

// MARK: - Settings window

struct ReplyDrafterSettingsView: View {
    @ObservedObject var settings: ReplyDrafterSettings

    var body: some View {
        Form {
            Section("Your voice") {
                TextField("Your name", text: $settings.userName, prompt: Text(NSFullUserName()))
                TextField("Email sign-off", text: $settings.signOff, prompt: Text("Learned from your emails, e.g. Best,"))
                Picker("Tone", selection: $settings.tone) {
                    ForEach(ReplyDrafterSettings.tonePresets, id: \.title) { preset in Text(preset.title).tag(preset.text) }
                    if !ReplyDrafterSettings.tonePresets.contains(where: { $0.text == settings.tone }) {
                        Text("Custom").tag(settings.tone)
                    }
                }
                TextField("Describe your tone", text: $settings.tone, prompt: Text("e.g. Warm but brief, no emojis, never use 'circle back'"), axis: .vertical)
                    .lineLimit(2...4)
                Text("SparkV also learns from your own messages it sees in the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Write the draft into the message box", isOn: $settings.autoInsert)
                Toggle("Fill an empty email Subject", isOn: $settings.fillSubject)
                Toggle("Use my Spaces as context", isOn: $settings.useSpaces)
                Toggle("Read the window when an app hides its text (Screen Recording)", isOn: $settings.readScreen)
                Toggle("Shortcut \(settings.shortcut.displayString)", isOn: $settings.hotkeyEnabled)
                Text("SparkV never presses Send. Undo in the bar puts back exactly what was there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                Toggle("Allow Reply Drafter to use my Groq key", isOn: $settings.allowGroq)
                Text(settings.allowGroq
                     ? "The conversation is sent to Groq (api.groq.com) with your Clicky key when drafting."
                     : "Drafts are written on this Mac with Apple Intelligence. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 460, height: 720)
        .labsWindowRoot()
    }
}

@MainActor
final class ReplyDrafterSettingsWindow: NSObject, NSWindowDelegate {
    static let shared = ReplyDrafterSettingsWindow()
    private var window: NSWindow?

    func show(settings: ReplyDrafterSettings) {
        let window = window ?? makeWindow(settings)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(_ settings: ReplyDrafterSettings) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reply Drafter"
        LabsBrand.styleWindow(window)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReplyDrafterSettingsView(settings: settings))
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let stillOpen = NSApp.windows.contains { $0 !== closing && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
