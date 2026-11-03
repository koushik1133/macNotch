import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The prompter

/// What the panel under the notch shows: the script scrolling past a
/// reading line near the top (closest to the camera), with controls on hover.
struct TeleprompterView: View {
    @ObservedObject var controller: TeleprompterController
    /// Keep the control bar visible (previews); otherwise it shows on hover.
    var alwaysShowsControls = false
    @StateObject private var hover = ViewFlag()
    @ObservedObject private var assistive = SparkVAssistive.shared

    /// The reading line, near the top edge: right under the lens.
    private let readingLine: CGFloat = 30

    var body: some View {
        let settings = controller.settings
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(Color.black.opacity(settings.opacity))
            // In an overlay, so the (tall) text never sizes the panel.
            Color.clear
                .overlay(alignment: .top) { scrollingText(settings) }
                .mask(fadeMask)
                .clipShape(shape)
            readingMarkers
            if let count = controller.countdownRemaining {
                countdown(count)
                    .transition(.opacity)
            } else if controller.reachedEnd {
                endCard.transition(.sparkVEnter)
            }
            controls
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
                .sparkVHoverRevealed(hover.isOn || alwaysShowsControls, assistive: assistive)
                .offset(y: hover.isOn || alwaysShowsControls || assistive.revealsHoverControls || SparkVMotion.reduceMotion ? 0 : 4)
                .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: hover.isOn)
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(shape)
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: controller.countdownRemaining)
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: controller.reachedEnd)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Teleprompter, \(controller.isPlaying ? "playing" : "paused")")
    }

    private func scrollingText(_ settings: TeleprompterSettings) -> some View {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        return TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30 : nil, paused: !controller.isClockRunning)) { context in
            let offset = controller.offset(at: context.date)
            Text(controller.text.isEmpty ? "Add your script in the editor." : controller.text)
                .font(.system(size: settings.fontSize, weight: .semibold))
                .lineSpacing(settings.lineSpacing)
                .multilineTextAlignment(settings.centered ? .center : .leading)
                .foregroundStyle(controller.text.isEmpty ? SparkVTheme.textTertiary : Color.white)
                .frame(width: TeleprompterLayout.textWidth(settings), alignment: settings.centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { controller.contentHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in controller.contentHeight = height }
                    }
                )
                .scaleEffect(x: settings.mirrored ? -1 : 1, y: 1)
                .offset(y: readingLine - settings.fontSize * 0.62 - offset)
                // Voice pacing moves the text in steps: ease each one (the
                // clock is stopped then, so nothing else animates it).
                .animation(settings.voicePacing && controller.isPlaying
                           ? SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)) : nil,
                           value: controller.positionRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onChange(of: offset >= controller.contentHeight && controller.contentHeight > 0) { _, atEnd in
                    if atEnd { controller.noteEnd() }
                }
        }
        .accessibilityLabel(controller.text)
    }

    private var fadeMask: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.35), location: 0),
            .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.72),
            .init(color: .black.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var readingMarkers: some View {
        let tint = SparkVTheme.choose(apple: Color.accentColor, sparkv: SparkVTheme.red)
        return HStack {
            Image(systemName: "arrowtriangle.right.fill")
            Spacer()
            Image(systemName: "arrowtriangle.left.fill")
        }
        .font(.system(size: 8))
        .foregroundStyle(tint.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.top, readingLine - 4)
        .accessibilityHidden(true)
    }

    private func countdown(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(Color.white)
            .frame(width: 64, height: 64)
            .background(Circle().fill(Color(white: 0.13).opacity(0.95)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .contentTransition(.numericText(countsDown: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Starting in \(count)")
    }

    private var endCard: some View {
        HStack(spacing: 8) {
            Text("End of script")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
            ExtrasCapsuleButton(title: "From the Top", systemImage: "backward.end.fill", prominent: true) { controller.restart() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        let settings = controller.settings
        return HStack(spacing: 2) {
            TeleprompterChip(systemImage: "backward.end.fill", label: "From the top") { controller.restart() }
            TeleprompterChip(systemImage: "tortoise.fill", label: "Slower (⌃⌥⇧↓)") { controller.slower() }
            TeleprompterChip(systemImage: controller.isPlaying || controller.countdownRemaining != nil ? "pause.fill" : "play.fill",
                             label: controller.isPlaying ? "Pause (⌃⌥⇧Space)" : "Play (⌃⌥⇧Space)", prominent: true) { controller.togglePlay() }
            TeleprompterChip(systemImage: "hare.fill", label: "Faster (⌃⌥⇧↑)") { controller.faster() }
            Text(settings.voicePacing ? (controller.voiceStatus ?? "Voice") : "\(Int(settings.speed))")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .frame(minWidth: 26)
            Divider().frame(height: 14).overlay(Color.white.opacity(0.2))
            TeleprompterChip(systemImage: "textformat.size.smaller", label: "Smaller text") { controller.smallerText() }
            TeleprompterChip(systemImage: "textformat.size.larger", label: "Larger text") { controller.biggerText() }
            TeleprompterChip(systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Mirror text",
                             isOn: settings.mirrored) { controller.settings.mirrored.toggle() }
            TeleprompterChip(systemImage: settings.voicePacing ? "waveform.circle.fill" : "waveform.circle", label: "Voice pacing (on-device)",
                             isOn: settings.voicePacing) { controller.settings.voicePacing.toggle() }
            TeleprompterChip(systemImage: "square.and.pencil", label: "Edit scripts") { TeleprompterEditorWindowController.shared.show() }
            TeleprompterChip(systemImage: "xmark", label: "Close (⌃⌥⇧T)") { controller.hide() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(white: 0.12).opacity(0.96)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct TeleprompterChip: View {
    let systemImage: String
    let label: String
    var prominent = false
    var isOn = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let tint = SparkVTheme.choose(apple: Color.accentColor, sparkv: SparkVTheme.red)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 11 : 10, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : (isOn ? tint : (hover.isOn ? Color.white : SparkVTheme.textSecondary)))
                .frame(width: prominent ? 26 : 22, height: 22)
                .background(Circle().fill(prominent ? tint : Color.white.opacity(hover.isOn ? 0.12 : 0)))
                .contentShape(Circle())
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "")
    }
}

// MARK: - Editor window

@MainActor
final class TeleprompterEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = TeleprompterEditorWindowController()
    private var window: NSWindow?

    func show() {
        TeleprompterController.shared.reloadScripts()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Teleprompter"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            LabsBWindowAppearance.follow(window)
            window.minSize = NSSize(width: 620, height: 420)
            window.delegate = self
            window.contentView = NSHostingView(rootView: TeleprompterEditorView().followsAppearance())
            window.center()
            window.setFrameAutosaveName("SparkV.Teleprompter.Editor")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}

struct TeleprompterEditorView: View {
    @ObservedObject private var controller = TeleprompterController.shared
    @StateObject private var dropTargeted = ViewFlag()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(Color.white.opacity(SparkVTheme.isApple ? 0.03 : 0.02))
            Rectangle().fill(SparkVTheme.stroke).frame(width: 1)
            editor
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(SparkVTheme.background)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { dropTargeted.isOn }, set: { dropTargeted.isOn = $0 })) { providers in
            loadDropped(providers)
            return true
        }
        .overlay {
            if dropTargeted.isOn {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(SparkVTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .overlay(Text("Drop .txt or .md to import").font(SparkVTheme.headline(13)).foregroundStyle(SparkVTheme.text))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(SparkVMotion.hover(), value: dropTargeted.isOn)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("— SCRIPTS")
                    .font(SparkVTheme.eyebrow())
                    .tracking(1.2)
                    .foregroundStyle(SparkVTheme.eyebrowDash)
                Spacer()
                ExtrasIconButton(systemImage: "square.and.arrow.down", label: "Import .txt or .md…") { importFromPanel() }
                ExtrasIconButton(systemImage: "plus", label: "New script") { controller.newScript() }
            }
            .padding(.top, 34)
            .padding(.horizontal, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(controller.scripts) { script in
                        TeleprompterScriptRow(script: script, isSelected: script.id == controller.currentScriptID) {
                            controller.currentScriptID = script.id
                        } delete: {
                            controller.deleteScript(script.id)
                        }
                    }
                    if controller.scripts.isEmpty {
                        Text("No scripts yet. Type on the right, or drop a .txt or .md file here.")
                            .font(.system(size: 11))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(TeleprompterText.title(for: controller.text))
                    .font(SparkVTheme.title(18))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1f min read", max(0.1, TeleprompterText.readingMinutes(controller.text))))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            TextEditor(text: $controller.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                .accessibilityLabel("Script")
            controls
            HStack(spacing: 8) {
                ExtrasNote(text: "The prompter is hidden from screenshots and screen sharing where macOS allows it. Some capture tools ignore that: share a window, not the whole screen.",
                           systemImage: "eye.slash")
                Spacer()
                Button(controller.isShown ? "Hide Prompter" : "Show Prompter") { controller.toggleShown() }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Button(controller.isPlaying ? "Pause" : "Play") { controller.togglePlay() }
                    .buttonStyle(SparkVPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                labeledSlider("Speed", value: $controller.settings.speed, range: TeleprompterSettings.speedRange,
                              text: controller.settings.voicePacing ? "Voice" : "\(Int(controller.settings.speed)) pt/s")
                    .disabled(controller.settings.voicePacing)
                labeledSlider("Text Size", value: $controller.settings.fontSize, range: TeleprompterSettings.fontRange,
                              text: "\(Int(controller.settings.fontSize)) pt")
            }
            HStack(spacing: 16) {
                labeledSlider("Width", value: $controller.settings.width, range: TeleprompterSettings.widthRange,
                              text: "\(Int(controller.settings.width))")
                labeledSlider("Height", value: $controller.settings.height, range: TeleprompterSettings.heightRange,
                              text: "\(Int(controller.settings.height))")
            }
            HStack(spacing: 12) {
                Text("Countdown").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SparkVTheme.textSecondary)
                ExtrasSegmented(options: [(0, "Off"), (3, "3 s"), (5, "5 s")], selection: $controller.settings.countdown,
                                label: "Countdown", compact: true)
                    .frame(width: 150)
                Spacer()
                displayPicker
            }
            HStack(spacing: 16) {
                Toggle("Mirror Text", isOn: $controller.settings.mirrored).fixedSize()
                Toggle("Voice Pacing", isOn: $controller.settings.voicePacing).fixedSize()
                    .help("Scrolls as you read, with on-device speech recognition (audio never leaves your Mac)")
                Toggle("Centered", isOn: $controller.settings.centered).fixedSize()
                Spacer()
            }
            .font(.system(size: 12))
            .toggleStyle(.checkbox)
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SparkVTheme.textSecondary)
                Spacer()
                Text(text).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(SparkVTheme.textTertiary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(SparkVTheme.accent)
                .accessibilityLabel(title)
                .accessibilityValue(text)
        }
    }

    private var displayPicker: some View {
        Menu {
            Button("Display with the Notch (Automatic)") { controller.settings.displayID = nil }
            Divider()
            ForEach(NSScreen.screens, id: \.self) { screen in
                Button(screen.localizedName) { controller.settings.displayID = ExtrasScreens.displayID(of: screen) }
            }
        } label: {
            Label(displayName, systemImage: "display")
        }
        .fixedSize()
        .help("On a Mac without a notch, or another display, choose where the camera is")
    }

    private var displayName: String {
        guard let id = controller.settings.displayID, let screen = ExtrasScreens.screen(displayID: id) else { return "Automatic" }
        return screen.localizedName
    }

    private func importFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK { controller.importFiles(panel.urls) }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in TeleprompterController.shared.importFiles([url]) }
            }
        }
    }
}

struct TeleprompterScriptRow: View {
    let script: TeleprompterController.Script
    let isSelected: Bool
    let select: () -> Void
    let delete: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Text("\(script.modified.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.0f", max(1, TeleprompterText.readingMinutes(script.text).rounded()))) min")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? SparkVTheme.accentSoft : SparkVTheme.hoverFill.opacity(hover.isOn ? 1 : 0))
            )
            .contentShape(Rectangle())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .contextMenu {
            Button("Move to Trash", action: delete)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Hub tile, menu, settings

/// Media category. Click: show or hide the prompter. Right-click: more.
struct TeleprompterHubTile: View {
    @ObservedObject private var controller = TeleprompterController.shared
    /// Its id in the Agents hub: adds the hub's Pin / Hide / Move items.
    var hubID: String? = nil

    var body: some View {
        ExtrasHubTileFace(
            title: controller.isPlaying ? "Prompting" : "Prompter",
            systemImage: controller.isPlaying ? "scroll.fill" : "scroll",
            tint: .indigo,
            isActive: controller.isShown,
            help: "Teleprompter under the camera (\(TeleprompterController.toggleShortcut.displayString))"
        ) {
            controller.toggleShown()
        }
        .contextMenu {
            TeleprompterMenuItems()
            ExtrasHubMenuTail(hubID: hubID)
        }
    }
}

struct TeleprompterMenuItems: View {
    @ObservedObject private var controller = TeleprompterController.shared

    var body: some View {
        Button(controller.isShown ? "Hide Teleprompter  \(TeleprompterController.toggleShortcut.displayString)"
                                  : "Show Teleprompter  \(TeleprompterController.toggleShortcut.displayString)") { controller.toggleShown() }
        if controller.isShown {
            Button(controller.isPlaying ? "Pause" : "Play") { controller.togglePlay() }
            Button("From the Top") { controller.restart() }
        }
        Button("Edit Scripts…") { TeleprompterEditorWindowController.shared.show() }
        if !controller.scripts.isEmpty {
            Menu("Script") {
                ForEach(controller.scripts) { script in
                    Button {
                        controller.currentScriptID = script.id
                    } label: {
                        if script.id == controller.currentScriptID { Label(script.title, systemImage: "checkmark") } else { Text(script.title) }
                    }
                }
            }
        }
        Divider()
        Toggle("Mirror Text", isOn: $controller.settings.mirrored)
        Toggle("Voice Pacing", isOn: $controller.settings.voicePacing)
    }
}

/// Extras pane.
struct TeleprompterSettingsSection: View {
    @ObservedObject private var controller = TeleprompterController.shared

    var body: some View {
        ExtrasSettingsCard(title: "Teleprompter",
                           subtitle: "Your script scrolls just under the camera. The panel never takes focus and is hidden from screen sharing where macOS honors that.",
                           systemImage: "scroll") {
            VStack(alignment: .leading, spacing: 2) {
                ExtrasToggleRow(title: "Keyboard Shortcuts",
                                detail: "\(TeleprompterController.toggleShortcut.displayString) shows or hides it. While it shows: \(TeleprompterController.playShortcut.displayString) plays or pauses, \(TeleprompterController.fasterLabel) and \(TeleprompterController.slowerLabel) change the speed.",
                                isOn: $controller.settings.hotkeysEnabled)
                ExtrasToggleRow(title: "Voice Pacing",
                                detail: "Follows you as you read, with on-device speech recognition. Asks for the microphone the first time; audio never leaves your Mac.",
                                isOn: $controller.settings.voicePacing)
                ExtrasToggleRow(title: "Mirror Text", detail: "For beam-splitter glass.", isOn: $controller.settings.mirrored)
                ExtrasControlRow(title: "Countdown") {
                    ExtrasSegmented(options: [(0, "Off"), (3, "3 s"), (5, "5 s")], selection: $controller.settings.countdown, label: "Countdown", compact: true)
                        .frame(width: 160)
                }
                ExtrasDivider()
                HStack(spacing: 8) {
                    Button("Edit Scripts…") { TeleprompterEditorWindowController.shared.show() }
                        .buttonStyle(SparkVPrimaryButtonStyle())
                    Button(controller.isShown ? "Hide Prompter" : "Show Prompter") { controller.toggleShown() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                    Spacer()
                }
                .padding(.horizontal, 8)
                ExtrasNote(text: "Scrolling stops when the displays sleep, the Mac sleeps or the screen locks, and runs at 30 fps in Low Power Mode. Scripts live in ~/Library/Application Support/SparkV/Teleprompter.",
                           systemImage: "leaf")
            }
        }
    }
}
