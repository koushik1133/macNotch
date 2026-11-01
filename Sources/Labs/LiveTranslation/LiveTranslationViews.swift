import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// Views for Live Translation: the band under the notch, the floating caption
// window (styled after macOS Live Captions), the language download window and
// the settings menu.

// MARK: - Band under the notch

/// Replaces the recording band while captions flow: recording dot, language
/// chip, the newest translated caption on up to two lines, elapsed time.
/// Laid out in 368×48 pt on black (LiveActivity).
struct LiveTranslationBand: View {
    @ObservedObject var controller: LiveTranslationController
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            HStack(alignment: .center, spacing: 9) {
                MeetingPulsingDot(isOn: Int(elapsed) % 2 == 0)

                if let line = controller.bandCaption {
                    VStack(alignment: .leading, spacing: 2) {
                        LiveTranslationChip(line: line)
                        Text(line.displayText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(line.failed ? SparkVTheme.textSecondary : SparkVTheme.text)
                            .lineLimit(2)
                            .truncationMode(.head)
                            .fixedSize(horizontal: false, vertical: true)
                            .animation(nil, value: line.displayText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Live translation · listening…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SparkVTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(MeetingFormat.clock(elapsed))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }
}

/// "ES → EN · Others" (or "Not translated").
struct LiveTranslationChip: View {
    let line: LiveTranslatedLine

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 8, weight: .bold))
            Text("\(LiveTranslationLanguages.shortTag(line.sourceLanguage)) → \(LiveTranslationLanguages.shortTag(line.targetLanguage))")
                .font(.system(size: 9, weight: .bold).monospaced())
            Text(line.speaker == .me ? "· You" : "· Others")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(SparkVTheme.textTertiary)
            if line.failed {
                Text("· not translated")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(SparkVTheme.warning)
            }
        }
        .foregroundStyle(LabsBStyle.tint(.green))
        .lineLimit(1)
    }
}

// MARK: - Caption window

/// Floating captions, like macOS Live Captions: a dark translucent rounded
/// panel on all Spaces that never takes focus from the meeting app.
@MainActor
final class LiveTranslationCaptionWindowController {
    private unowned let controller: LiveTranslationController
    private var panel: NSPanel?

    init(controller: LiveTranslationController) {
        self.controller = controller
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        // Opening (or reopened mid fade-out): a short ease-out fade, no
        // movement since it sits where the user left it.
        if panel.alphaValue < 1 { LiveBandMotion.fadeIn(panel) }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        LiveBandMotion.fadeOut(panel)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 640, height: 150)
        let panel = LiveTranslationCaptionPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 96)
        panel.title = "SparkV Live Translation"
        let host = NSHostingView(rootView: LiveTranslationCaptionView(
            controller: controller,
            onClose: { [weak self] in
                guard let self else { return }
                self.close()
                self.controller.showsCaptionWindow = false
            }
        ).followsAppearance())
        host.sizingOptions = []
        panel.contentView = host
        if !panel.setFrameUsingName("SparkV.LiveTranslation.Captions"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
        }
        panel.setFrameAutosaveName("SparkV.LiveTranslation.Captions")
        return panel
    }
}

/// Borderless panels can't become key by default; the language menu and
/// buttons need key status without activating SparkV.
final class LiveTranslationCaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct LiveTranslationCaptionView: View {
    @ObservedObject var controller: LiveTranslationController
    var onClose: () -> Void = {}
    @StateObject private var hovering = ViewFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        if controller.captions.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(SparkVTheme.textSecondary)
                        }
                        ForEach(controller.captions) { line in
                            LiveTranslationCaptionRow(line: line, showsOriginal: controller.showsOriginal)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Newest at the bottom, also when the window opens mid-meeting.
                .defaultScrollAnchor(.bottom)
                .onChange(of: controller.captions.last?.displayText) { _, _ in
                    if let last = controller.captions.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous)
            if SparkVTheme.isApple {
                // macOS Live Captions: a dark translucent HUD.
                VisualEffectBackdrop(material: .hudWindow, blending: .behindWindow)
                    .overlay(Color.black.opacity(0.35))
                    .clipShape(shape)
            } else {
                shape.fill(SparkVTheme.background.opacity(0.9))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous)
                .strokeBorder(SparkVTheme.stroke)
        )
        .onHover { hovering.isOn = $0 }
        .environment(\.colorScheme, .dark)
    }

    private var placeholder: String {
        switch controller.status {
        case .needsDownload, .unavailable: return controller.statusText
        case .off: return "Live translation is off"
        default:
            return controller.isRecording ? "Translated captions appear here" : "Starts when a meeting is recorded"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 11))
                .foregroundStyle(LabsBStyle.tint(.green))
            Text("LIVE TRANSLATION")
                .font(SparkVTheme.eyebrow(9.5))
                .tracking(LabsBStyle.eyebrowTracking(1.2))
                .foregroundStyle(SparkVTheme.text.opacity(0.85))
            Text(controller.statusText)
                .font(.system(size: 10))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let message = controller.notesMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SparkVTheme.success)
                    .lineLimit(1)
            }
            Menu {
                Picker("Translate To", selection: $controller.targetLanguage) {
                    ForEach(controller.targets, id: \.self) { id in
                        Text(LiveTranslationLanguages.displayName(id)).tag(id)
                    }
                }
                Toggle("Show Original Text", isOn: $controller.showsOriginal)
                Toggle("Translate My Own Speech", isOn: $controller.translatesMySpeech)
                Divider()
                Button("Add Translation to Meeting Notes") {
                    Task { await controller.addToMeetingNotes() }
                }
                .disabled(controller.meetingID == nil)
                Button("Copy Translated Transcript") { controller.copyTranscript() }
                    .disabled(controller.lineCount == 0)
                if controller.downloadPair != nil {
                    Divider()
                    Button("Download Languages…") { controller.requestLanguageDownload() }
                }
            } label: {
                // One Text so the borderless menu keeps the chevron after the name.
                (Text(LiveTranslationLanguages.displayName(controller.targetLanguage) + " ")
                    + Text(Image(systemName: "chevron.down")))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text.opacity(0.85))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering.isOn ? SparkVTheme.textSecondary : SparkVTheme.textTertiary)
                    .animation(SparkVMotion.hover(), value: hovering.isOn)
            }
            .buttonStyle(SparkVPressStyle())
            .help("Hide captions")
            .accessibilityLabel("Hide captions")
        }
    }
}

struct LiveTranslationCaptionRow: View {
    let line: LiveTranslatedLine
    let showsOriginal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.speaker == .me ? "YOU" : "OTHERS")
                    .font(SparkVTheme.eyebrow(9.5))
                    .tracking(LabsBStyle.eyebrowTracking(0.8))
                    .foregroundStyle(line.speaker == .me ? SparkVTheme.textTertiary : LabsBStyle.tint(.green))
                Text(line.displayText)
                    .font(.system(size: 17, weight: line.isFinal ? .semibold : .regular))
                    .tracking(-0.2)
                    .foregroundStyle(line.failed ? SparkVTheme.textSecondary : SparkVTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if line.failed {
                Text("Not translated")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SparkVTheme.warning)
                    .padding(.leading, 2)
            } else if showsOriginal {
                Text("\(LiveTranslationLanguages.displayName(line.sourceLanguage)): \(line.sourceText)")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(2)
                    .padding(.leading, 2)
            }
        }
        .opacity(line.isFinal ? 1 : 0.9)
    }
}

// MARK: - Language download

/// A small window that asks macOS to download a language pair for on-device
/// translation. The download consent sheet comes from the system, attached
/// to this window, through `.translationTask` + `prepareTranslation()`.
@MainActor
final class LiveTranslationDownloadWindowController {
    private unowned let controller: LiveTranslationController
    private var window: NSWindow?
    private let model = LiveTranslationDownloadModel()

    init(controller: LiveTranslationController) {
        self.controller = controller
    }

    func show(source: String, target: String) {
        model.source = source
        model.target = target
        model.state = .idle
        model.onDone = { [weak self] in
            self?.controller.languagesDownloaded()
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 170),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "SparkV Live Translation"
            window.appearance = NSAppearance(named: .darkAqua)
            LabsBWindowAppearance.follow(window)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LiveTranslationDownloadView(model: model).followsAppearance())
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }
}

@MainActor
final class LiveTranslationDownloadModel: ObservableObject {
    enum State: Equatable { case idle, downloading, done, failed(String) }

    @Published var source = "en"
    @Published var target = "es"
    @Published var state: State = .idle
    #if canImport(Translation)
    @Published var configuration: TranslationSession.Configuration?
    #endif
    var onDone: () -> Void = {}

    func start() {
        state = .downloading
        #if canImport(Translation)
        let config = TranslationSession.Configuration(
            source: LiveTranslationLanguages.language(source), target: LiveTranslationLanguages.language(target)
        )
        if configuration == config {
            configuration?.invalidate()
        } else {
            configuration = config
        }
        #endif
    }

    #if canImport(Translation)
    func prepare(_ session: TranslationSession) async {
        nonisolated(unsafe) let session = session
        do {
            try await session.prepareTranslation()
            state = .done
            onDone()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
    #endif
}

struct LiveTranslationDownloadView: View {
    @ObservedObject var model: LiveTranslationDownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(SparkVTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(LiveTranslationLanguages.displayName(model.source)) → \(LiveTranslationLanguages.displayName(model.target))")
                        .font(SparkVTheme.headline(14))
                        .tracking(-0.2)
                        .foregroundStyle(SparkVTheme.text)
                    Text("Download these languages so meetings are translated on this Mac, privately and without a network connection.")
                        .font(SparkVTheme.body(12))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                switch model.state {
                case .idle:
                    EmptyView()
                case .downloading:
                    ProgressView().controlSize(.small)
                    Text("Waiting for macOS…").font(SparkVTheme.body(12)).foregroundStyle(SparkVTheme.textSecondary)
                case .done:
                    Label("Ready", systemImage: "checkmark.circle.fill").font(SparkVTheme.headline(12)).foregroundStyle(SparkVTheme.success)
                case .failed(let message):
                    Text(message).font(SparkVTheme.body(12)).foregroundStyle(SparkVTheme.warning).lineLimit(2)
                }
                Spacer()
                Button(model.state == .done ? "Done" : "Download") {
                    if model.state == .done {
                        NSApp.keyWindow?.orderOut(nil)
                    } else {
                        model.start()
                    }
                }
                .buttonStyle(SparkVPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.state == .downloading)
                .opacity(model.state == .downloading ? 0.5 : 1)
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(LabsBWindowGround(glow: 0).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        #if canImport(Translation)
        .translationTask(model.configuration) { session in
            await model.prepare(session)
        }
        #endif
    }
}

// MARK: - Settings menu

/// "Live Translation" submenu for the gear menu (SettingsMenu → Meetings).
struct LiveTranslationMenu: View {
    @ObservedObject var controller: LiveTranslationController

    var body: some View {
        Menu("Live Translation") {
            Toggle("Translate Meetings Live", isOn: $controller.isEnabled)
            Picker("Translate To", selection: $controller.targetLanguage) {
                ForEach(controller.targets, id: \.self) { id in
                    Text(LiveTranslationLanguages.displayName(id)).tag(id)
                }
            }
            // Speech is transcribed in this language from the next recording.
            Picker("Others Speak", selection: $controller.othersSpeak) {
                Text("Same as This Mac").tag("")
                Divider()
                ForEach(LiveTranslationSpokenLanguage.locales, id: \.self) { id in
                    Text(LiveTranslationSpokenLanguage.displayName(id)).tag(id)
                }
            }
            Divider()
            Toggle("Show Under the Notch", isOn: $controller.showsInNotch)
            Toggle("Show Caption Window", isOn: $controller.showsCaptionWindow)
            Toggle("Show Original Text", isOn: $controller.showsOriginal)
            Toggle("Translate My Own Speech", isOn: $controller.translatesMySpeech)
            Toggle("Allow Live Translation to Use My Groq Key", isOn: $controller.allowGroq)
            Divider()
            if controller.downloadPair != nil {
                Button("Download Languages for On-Device Translation…") { controller.requestLanguageDownload() }
            }
            Button("Open Caption Window") { controller.openCaptionWindow() }
            Button("Add Translation to Meeting Notes") {
                Task { await controller.addToMeetingNotes() }
            }
            .disabled(controller.meetingID == nil)
        }
    }
}
