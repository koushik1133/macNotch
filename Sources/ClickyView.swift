import SwiftUI

/// Clicky's panel inside the expanded drawer (about 508 x 70 pt): what Clicky
/// is doing, a field to type a question, recent answers, and the API key and
/// model settings.
struct ClickyView: View {
    @EnvironmentObject private var clicky: ClickyController
    @StateObject private var ui = ClickyViewState()

    var body: some View {
        Group {
            switch ui.pane {
            case .main: mainPane
            case .history: historyPane
            case .settings: settingsPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
    }

    // MARK: - Main

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                statusIcon
                    .frame(width: 14, height: 14)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(clicky.phase == .listening ? .head : .tail)
                    .help(statusText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if clicky.isSpeaking {
                    SmallIconButton(systemImage: "speaker.slash.fill", help: "Stop speaking") {
                        clicky.stopSpeaking()
                    }
                }
                SmallIconButton(systemImage: "clock.arrow.circlepath", help: "Recent answers", isOn: false) {
                    ui.pane = .history
                }
                .disabled(clicky.exchanges.isEmpty)
                SmallIconButton(systemImage: "key.fill", help: "Groq API key and model") {
                    ui.keyDraft = ""
                    ui.pane = .settings
                }
            }

            HStack(spacing: 6) {
                SmallIconButton(
                    systemImage: clicky.phase == .listening ? "stop.circle.fill" : "mic.fill",
                    help: clicky.phase == .listening ? "Send what you said" : "Ask out loud (or hold ⌃⌥)",
                    tint: clicky.phase == .listening ? SparkVTheme.recording : SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.text)
                ) {
                    clicky.toggleListening()
                }

                TextField("Ask about your screen…", text: $ui.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.text)
                    .onSubmit(send)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))

                SmallIconButton(systemImage: "arrow.up.circle.fill", help: "Ask", tint: SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red), size: 15, action: send)
                    .disabled(ui.draft.trimmingCharacters(in: .whitespaces).isEmpty || clicky.phase == .thinking)
            }

            Text(footnote)
                .font(.system(size: 9))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(footnote)
        }
    }

    private func send() {
        let text = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, clicky.phase != .thinking else { return }
        clicky.ask(text)
        ui.draft = ""
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch clicky.phase {
        case .idle:
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red))
        case .listening:
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.recording)
        case .thinking:
            ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
        case .answering:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(SparkVTheme.warning)
        }
    }

    private var statusText: String {
        switch clicky.phase {
        case .idle:
            if !clicky.hotkeyAvailable {
                return "Allow Accessibility to use ⌃⌥ hold-to-ask, or type a question"
            }
            if let last = clicky.exchanges.first {
                return last.answer
            }
            return "Hold ⌃⌥ and ask about anything on your screen"
        case .listening:
            return clicky.liveQuestion.isEmpty ? "Listening… release ⌃⌥ to ask" : clicky.liveQuestion
        case .thinking:
            return clicky.liveQuestion.isEmpty ? "Looking at your screen…" : "Looking at your screen: “\(clicky.liveQuestion)”"
        case .answering(let answer):
            return answer
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch clicky.phase {
        case .failed: SparkVTheme.warning
        case .idle where !clicky.hotkeyAvailable: SparkVTheme.warning
        case .idle where !clicky.exchanges.isEmpty: SparkVTheme.textSecondary
        case .idle, .thinking: SparkVTheme.textSecondary
        case .listening where clicky.liveQuestion.isEmpty: SparkVTheme.textSecondary
        default: .white
        }
    }

    private var footnote: String {
        if clicky.hasAPIKey {
            return "\(clicky.model.shortTitle) · Screenshots are taken only while you ask and sent only to Groq with your key"
        }
        return "On-device mode: reads screen text only and can't see images. Add a Groq key for full answers"
    }

    // MARK: - History

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 3) {
            PaneHeader(title: "Recent answers") { ui.pane = .main }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(clicky.exchanges) { exchange in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(exchange.question)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(SparkVTheme.textTertiary)
                                .lineLimit(1)
                            Text(exchange.answer)
                                .font(.system(size: 10))
                                .foregroundStyle(SparkVTheme.text)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Settings

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(clicky.hasAPIKey ? SparkVTheme.success : SparkVTheme.textTertiary)
                SecureField(clicky.hasAPIKey ? "Key saved in Keychain. Paste a new one to replace it" : "Paste your Groq API key (gsk_…)", text: $ui.keyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit(saveKey)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
                TextButton(title: "Save", isPrimary: true, action: saveKey)
                    .disabled(ui.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if clicky.hasAPIKey {
                    TextButton(title: "Remove", tint: SparkVTheme.warning) {
                        clicky.setAPIKey(nil)
                        ui.keyDraft = ""
                    }
                }
                TextButton(title: "Done") { ui.pane = .main }
            }

            HStack(spacing: 8) {
                if ClickyModel.allCases.count > 1 {
                    Picker("Model", selection: $clicky.model) {
                        ForEach(ClickyModel.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .tint(SparkVTheme.red)
                    .frame(width: 250)
                    .disabled(!clicky.hasAPIKey)
                } else {
                    Label(clicky.model.title, systemImage: "eye")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(clicky.hasAPIKey ? SparkVTheme.text : SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(clicky.hasAPIKey ? "Uses your Groq account" : "Without a key Clicky stays on-device")
                    .font(.system(size: 9))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
            }

            Text("Privacy: Clicky captures the screen under your mouse only while you ask, and sends it only to Groq with your own key. Nothing is stored.")
                .font(.system(size: 9))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Clicky captures the display under your mouse only when you release ⌃⌥ or press Ask. With a key, that one screenshot and your question go to Groq's API over HTTPS using your key; without one, everything stays on this Mac. Screenshots are not saved.")
        }
    }

    private func saveKey() {
        let key = ui.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        clicky.setAPIKey(key)
        ui.keyDraft = ""
        if clicky.hasAPIKey { ui.pane = .main }
    }
}

/// View-local state (`@State` is unavailable with the Command Line Tools).
@MainActor
final class ClickyViewState: ObservableObject {
    enum Pane {
        case main
        case history
        case settings
    }

    @Published var pane: Pane = .main
    @Published var draft = ""
    @Published var keyDraft = ""
}

private struct PaneHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if !SparkVTheme.isApple {
                    Capsule().fill(SparkVTheme.eyebrowDash).frame(width: 10, height: 2)
                }
                Text(SparkVTheme.isApple ? title : title.uppercased())
                    .font(SparkVTheme.isApple ? .system(size: 11, weight: .semibold) : SparkVTheme.eyebrow(9.5))
                    .tracking(SparkVTheme.isApple ? 0 : 1.2)
                    .foregroundStyle(SparkVTheme.choose(apple: SparkVTheme.text, sparkv: SparkVTheme.textSecondary))
            }
            Spacer()
            TextButton(title: "Done", action: close)
        }
    }
}

private struct SmallIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = SparkVTheme.textSecondary
    var size: CGFloat = 11
    var isOn = false
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    init(systemImage: String, help: String, isOn: Bool = false, tint: Color = SparkVTheme.textSecondary, size: CGFloat = 11, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isOn = isOn
        self.tint = tint
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isOn ? SparkVTheme.activeGlyph : tint)
                .frame(width: 18, height: 18)
                .sparkVHoverFill(hover.isOn, cornerRadius: 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TextButton: View {
    let title: String
    var tint: Color = SparkVTheme.text
    /// Filled red (sparkv.si primary button) instead of the frosted pill.
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.white : tint)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(isPrimary ? SparkVTheme.red : SparkVTheme.surface))
                .overlay(Capsule().strokeBorder(isPrimary || SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .fixedSize()
    }
}
