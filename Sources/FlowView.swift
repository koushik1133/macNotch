import AppKit
import SwiftUI

/// The Flow panel inside the open drawer (about 508×70 pt): every dictation,
/// with raw vs. formatted text, a Scratchpad of notes that can be typed or
/// dictated, and the Dictionary and Snippets the formatter applies. A
/// History | Notes | Words switch sits on the left.
struct FlowView: View {
    @EnvironmentObject private var store: FlowStore
    @EnvironmentObject private var dictation: DictationController
    @StateObject private var model = FlowViewModel()

    var body: some View {
        HStack(spacing: 8) {
            FlowSectionSwitch(
                model: model, historyCount: store.history.count, noteCount: store.notes.count,
                wordCount: store.words.count + store.snippets.count
            )
            .frame(width: 86)

            Group {
                switch model.section {
                case .history: FlowHistoryStrip(model: model)
                case .notes: FlowNotesStrip(model: model)
                case .words: FlowWordsStrip(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - View model

@MainActor
final class FlowViewModel: ObservableObject {
    enum Section: String {
        case history
        case notes
        case words
    }

    @Published var section: Section {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
    }
    /// Note open in the editor.
    @Published var editingNoteID: UUID?
    /// Dictionary word or snippet open in the editor.
    @Published var editingWordID: UUID?
    @Published var editingSnippetID: UUID?
    /// Entry that just got copied, for the "Copied" tick.
    @Published private(set) var copiedID: UUID?
    /// Why the last note dictation could not run.
    @Published private(set) var noteError: String?

    private static let sectionKey = "flow.section"
    private var copiedTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    init() {
        section = UserDefaults.standard.string(forKey: Self.sectionKey).flatMap(Section.init(rawValue:)) ?? .history
    }

    func markCopied(_ id: UUID) {
        copiedID = id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copiedID = nil
        }
    }

    func showNoteError(_ message: String) {
        noteError = message
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.noteError = nil
        }
    }

    func clearNoteError() {
        errorTask?.cancel()
        noteError = nil
    }
}

/// Every deletion is confirmed first.
@MainActor
private enum FlowConfirm {
    static func ask(_ title: String, detail: String, button: String = "Delete", perform: @escaping @MainActor () -> Void) {
        // After the context menu or button has finished handling the click.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut())) { perform() }
        }
    }

    static func quoted(_ text: String) -> String {
        let line = FlowStyle.preview(text)
        return line.count > 40 ? "“\(line.prefix(40))…”" : "“\(line)”"
    }
}

// MARK: - Shared styling

private enum FlowStyle {
    static let cardWidth: CGFloat = 150
    static let cornerRadius: CGFloat = SparkVTheme.cornerMedium
    /// Flow's own color: the original soft sky blue in Apple, red in SparkV Red.
    static var accent: Color { SparkVTheme.choose(apple: Color(red: 0.55, green: 0.78, blue: 1.0), sparkv: SparkVTheme.red) }

    static func fill(_ highlighted: Bool) -> Color {
        if SparkVTheme.isApple { return Color.white.opacity(highlighted ? 0.12 : 0.065) }
        return highlighted ? SparkVTheme.surfaceHover : SparkVTheme.surface
    }

    static func shortDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The non-empty lines, so a two-line card shows a list's first item too.
    static func lines(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// First non-empty line, for one-glance previews.
    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

private struct FlowCardBackground: View {
    let highlighted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: FlowStyle.cornerRadius, style: .continuous)
            .fill(FlowStyle.fill(highlighted))
            .overlay(
                RoundedRectangle(cornerRadius: FlowStyle.cornerRadius, style: .continuous)
                    .strokeBorder(SparkVTheme.isApple ? Color.white.opacity(0.07) : (highlighted ? SparkVTheme.red.opacity(0.4) : SparkVTheme.stroke),
                                  lineWidth: SparkVTheme.isApple ? 0.5 : 1)
            )
    }
}

// MARK: - Section switch

private struct FlowSectionSwitch: View {
    @ObservedObject var model: FlowViewModel
    let historyCount: Int
    let noteCount: Int
    let wordCount: Int

    var body: some View {
        VStack(spacing: 2) {
            item(.history, title: "History", systemImage: "clock.arrow.circlepath", count: historyCount)
            item(.notes, title: "Notes", systemImage: "note.text", count: noteCount)
            item(.words, title: "Words", systemImage: "character.book.closed", count: wordCount)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke)
        )
    }

    private func item(_ section: FlowViewModel.Section, title: String, systemImage: String, count: Int) -> some View {
        let selected = model.section == section
        return Button {
            withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) { model.section = section }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 11)
                Text(title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? SparkVTheme.activeGlyph : SparkVTheme.textTertiary)
                }
            }
            .foregroundStyle(selected ? SparkVTheme.text : SparkVTheme.textSecondary)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(selected ? SparkVTheme.activeTabFill.opacity(SparkVTheme.isApple ? 0.8 : 1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
    }
}

// MARK: - History

private struct FlowHistoryStrip: View {
    @EnvironmentObject private var store: FlowStore
    @EnvironmentObject private var dictation: DictationController
    @ObservedObject var model: FlowViewModel

    var body: some View {
        if store.history.isEmpty {
            FlowEmptyHint(
                systemImage: "waveform",
                title: "No dictations yet",
                detail: "\(holdHint) and talk. ⌃⌘V pastes the last one, ⌃⌘C copies it."
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(store.history) { entry in
                        FlowHistoryCard(entry: entry, model: model)
                    }
                }
            }
            .modifier(FlowEdgeFade())
        }
    }

    private var holdHint: String {
        switch dictation.hotkey {
        case .fn: "Hold fn"
        case .rightOption: "Hold Right ⌥"
        case .off: "Press Dictate"
        }
    }
}

private struct FlowHistoryCard: View {
    @EnvironmentObject private var store: FlowStore
    let entry: FlowEntry
    @ObservedObject var model: FlowViewModel
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let copied = model.copiedID == entry.id
        Button {
            store.copy(entry)
            model.markCopied(entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(FlowStyle.shortDate(entry.date))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    if let app = entry.appName, !app.isEmpty {
                        Text("·")
                        Text(app).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(SparkVTheme.success)
                            .transition(.opacity)
                    } else if hover.isOn {
                        Image(systemName: "doc.on.doc")
                            .transition(.opacity)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)

                Text(FlowStyle.lines(entry.text))
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: FlowStyle.cardWidth)
            .frame(maxHeight: .infinity)
            .background(FlowCardBackground(highlighted: hover.isOn || copied))
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hovering in
            withAnimation(SparkVMotion.hover()) { hover.isOn = hovering }
        }
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.hover), value: copied)
        .help(entry.text)
        .contextMenu {
            Button("Copy") {
                store.copy(entry)
                model.markCopied(entry.id)
            }
            Button("Copy Raw") {
                store.copyRaw(entry)
                model.markCopied(entry.id)
            }
            .disabled(entry.raw.isEmpty)
            Button("Paste Into App") { store.paste(entry) }
            Divider()
            Button("Delete…", role: .destructive) {
                FlowConfirm.ask(
                    "Delete this dictation?", detail: "\(FlowConfirm.quoted(entry.text)) will be removed from the history."
                ) { store.deleteEntry(entry) }
            }
            Button("Clear History…", role: .destructive) {
                let count = store.history.count
                FlowConfirm.ask(
                    "Clear dictation history?",
                    detail: "\(count) dictation\(count == 1 ? "" : "s") will be deleted from this Mac.",
                    button: "Clear"
                ) { store.clearHistory() }
            }
        }
    }
}

// MARK: - Notes

private struct FlowNotesStrip: View {
    @EnvironmentObject private var store: FlowStore
    @EnvironmentObject private var dictation: DictationController
    @ObservedObject var model: FlowViewModel

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 4) {
                FlowNoteMicButton(model: model)
                FlowSmallButton(title: "New", systemImage: "plus") {
                    let note = store.addNote("")
                    model.editingNoteID = note.id
                }
            }
            .frame(width: 62)

            if let id = model.editingNoteID, let note = store.notes.first(where: { $0.id == id }) {
                FlowNoteEditor(note: note, model: model)
            } else {
                noteList
            }
        }
    }

    @ViewBuilder
    private var noteList: some View {
        let showsLive = dictation.isDictatingNote || model.noteError != nil
        if store.notes.isEmpty && !showsLive {
            FlowEmptyHint(
                systemImage: "note.text",
                title: "Scratchpad",
                detail: "Dictate a note with the mic, or start a new one."
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    if showsLive { FlowLiveNoteChip(model: model) }
                    ForEach(store.notes) { note in
                        FlowNoteChip(note: note, model: model)
                    }
                }
            }
            .modifier(FlowEdgeFade())
        }
    }
}

/// Starts and stops a note dictation.
private struct FlowNoteMicButton: View {
    @EnvironmentObject private var store: FlowStore
    @EnvironmentObject private var dictation: DictationController
    @ObservedObject var model: FlowViewModel

    var body: some View {
        let recording = dictation.isDictatingNote
        let formatting = recording && dictation.phase == .formatting
        let busyElsewhere = !recording && (dictation.isActive || dictation.isCapturingCommand)
        FlowSmallButton(
            title: formatting ? "Saving" : (recording ? "Stop" : "Dictate"),
            systemImage: recording ? "stop.fill" : "mic.fill",
            tint: recording ? SparkVTheme.choose(apple: Color.red.opacity(0.4), sparkv: SparkVTheme.red) : nil,
            iconColor: recording ? .white : FlowStyle.accent
        ) {
            toggle()
        }
        .disabled(formatting || busyElsewhere)
        .help(recording ? "Finish the note" : "Dictate a new note")
    }

    private func toggle() {
        if dictation.isDictatingNote {
            dictation.finishNoteDictation()
            return
        }
        model.clearNoteError()
        let store = store
        let dictation = dictation
        let model = model
        let started = dictation.startNoteDictation { text in
            if let text {
                withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut())) { _ = store.addNote(text) }
                return
            }
            // A failure is published right after the completion runs.
            Task { @MainActor in
                if case .failed(let message) = dictation.phase { model.showNoteError(message) }
            }
        }
        if !started, case .failed(let message) = dictation.phase {
            model.showNoteError(message)
        }
    }
}

/// Live words while a note is being dictated (or why it could not start).
private struct FlowLiveNoteChip: View {
    @EnvironmentObject private var dictation: DictationController
    @ObservedObject var model: FlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let error = model.noteError, !dictation.isDictatingNote {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SparkVTheme.warning)
                    Text(error).lineLimit(1)
                } else {
                    Circle().fill(SparkVTheme.recording).frame(width: 6, height: 6)
                    Text(dictation.phase == .formatting ? "Formatting…" : "Listening")
                    Spacer(minLength: 2)
                    Text(dictation.hotkey == .off ? "Stop to save" : dictation.hotkeyHint.replacingOccurrences(of: "stop", with: "save"))
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(SparkVTheme.textSecondary)

            if dictation.isDictatingNote {
                Text(dictation.liveText.isEmpty ? "Start talking…" : dictation.liveText)
                    .font(.system(size: 11))
                    .foregroundStyle(dictation.liveText.isEmpty ? SparkVTheme.textSecondary : SparkVTheme.text)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: FlowStyle.cardWidth + 30)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: FlowStyle.cornerRadius, style: .continuous)
                .fill(SparkVTheme.recording.opacity(dictation.isDictatingNote ? 0.12 : 0.0))
                .background(FlowCardBackground(highlighted: false))
        )
    }
}

private struct FlowNoteChip: View {
    @EnvironmentObject private var store: FlowStore
    let note: FlowNote
    @ObservedObject var model: FlowViewModel
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let isEmpty = note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button {
            model.editingNoteID = note.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(FlowStyle.shortDate(note.date))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    Spacer(minLength: 2)
                    if hover.isOn {
                        Image(systemName: "pencil")
                            .transition(.opacity)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)

                Text(isEmpty ? "Empty note" : note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(isEmpty ? SparkVTheme.textSecondary : SparkVTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: FlowStyle.cardWidth)
            .frame(maxHeight: .infinity)
            .background(FlowCardBackground(highlighted: hover.isOn))
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hovering in
            withAnimation(SparkVMotion.hover()) { hover.isOn = hovering }
        }
        .help(note.text)
        .contextMenu {
            Button("Edit") { model.editingNoteID = note.id }
            Button("Copy") { TextInserter.copy(note.text) }
                .disabled(isEmpty)
            Divider()
            Button("Delete…", role: .destructive) {
                if isEmpty {
                    withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut())) { store.deleteNote(note) }
                } else {
                    FlowConfirm.ask("Delete this note?", detail: "\(FlowConfirm.quoted(note.text)) will be deleted.") {
                        store.deleteNote(note)
                    }
                }
            }
        }
    }
}

/// Inline editor for one note; Done closes it (an empty note is dropped).
private struct FlowNoteEditor: View {
    @EnvironmentObject private var store: FlowStore
    let note: FlowNote
    @ObservedObject var model: FlowViewModel

    var body: some View {
        HStack(spacing: 6) {
            TextEditor(text: textBinding)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.text)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(FlowCardBackground(highlighted: true))

            VStack(spacing: 4) {
                FlowIconButton(systemImage: "checkmark", help: "Done") { close() }
                FlowIconButton(systemImage: "doc.on.doc", help: "Copy note") {
                    TextInserter.copy(currentText)
                }
                FlowIconButton(systemImage: "trash", help: "Delete note", color: SparkVTheme.choose(apple: Color.red.opacity(0.85), sparkv: SparkVTheme.red)) {
                    let text = currentText
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        close()
                        return
                    }
                    FlowConfirm.ask("Delete this note?", detail: "\(FlowConfirm.quoted(text)) will be deleted.") {
                        model.editingNoteID = nil
                        if let stored = store.notes.first(where: { $0.id == note.id }) { store.deleteNote(stored) }
                    }
                }
            }
        }
        .onExitCommand { close() }
    }

    private var currentText: String {
        store.notes.first { $0.id == note.id }?.text ?? note.text
    }

    private var textBinding: Binding<String> {
        let store = store
        let id = note.id
        return Binding(
            get: { store.notes.first { $0.id == id }?.text ?? "" },
            set: { newValue in
                guard var updated = store.notes.first(where: { $0.id == id }), updated.text != newValue else { return }
                updated.text = newValue
                updated.date = Date()
                store.updateNote(updated)
            }
        )
    }

    private func close() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.editingNoteID = nil
        if text.isEmpty, let stored = store.notes.first(where: { $0.id == note.id }) {
            store.deleteNote(stored)
        }
    }
}

// MARK: - Dictionary and Snippets

private struct FlowWordsStrip: View {
    @EnvironmentObject private var store: FlowStore
    @ObservedObject var model: FlowViewModel

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 4) {
                FlowSmallButton(title: "Word", systemImage: "plus", iconColor: FlowStyle.accent) {
                    model.editingSnippetID = nil
                    model.editingWordID = store.addWord().id
                }
                .help("Add a name or term to spell right")
                FlowSmallButton(title: "Snippet", systemImage: "plus", iconColor: FlowStyle.accent) {
                    model.editingWordID = nil
                    model.editingSnippetID = store.addSnippet().id
                }
                .help("Add a phrase that types a longer text")
            }
            .frame(width: 62)

            if let id = model.editingWordID, let word = store.words.first(where: { $0.id == id }) {
                FlowWordEditor(word: word, model: model)
            } else if let id = model.editingSnippetID, let snippet = store.snippets.first(where: { $0.id == id }) {
                FlowSnippetEditor(snippet: snippet, model: model)
            } else if store.words.isEmpty && store.snippets.isEmpty {
                FlowEmptyHint(
                    systemImage: "character.book.closed",
                    title: "Dictionary & Snippets",
                    detail: "Words are spelled your way. Say a snippet's trigger to type its text."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(store.snippets) { snippet in
                            FlowVocabularyChip(
                                kind: "Snippet", systemImage: "text.quote",
                                title: snippet.trigger.isEmpty ? "No trigger" : "“\(snippet.trigger)”",
                                detail: snippet.expansion.isEmpty ? "No text yet" : FlowStyle.preview(snippet.expansion),
                                help: snippet.expansion,
                                edit: { model.editingSnippetID = snippet.id },
                                delete: {
                                    FlowConfirm.ask(
                                        "Delete this snippet?",
                                        detail: "Saying “\(snippet.trigger)” will no longer type its text."
                                    ) { store.deleteSnippet(snippet) }
                                }
                            )
                        }
                        ForEach(store.words) { word in
                            let heard = word.heardAs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            FlowVocabularyChip(
                                kind: "Word", systemImage: "character.book.closed",
                                title: word.term.isEmpty ? "No word" : word.term,
                                detail: heard.isEmpty ? "Always spelled this way" : "for " + heard.joined(separator: ", "),
                                help: word.term,
                                edit: { model.editingWordID = word.id },
                                delete: {
                                    FlowConfirm.ask(
                                        "Delete “\(word.term)” from the Dictionary?",
                                        detail: "Dictation will stop correcting its spelling."
                                    ) { store.deleteWord(word) }
                                }
                            )
                        }
                    }
                }
                .modifier(FlowEdgeFade())
            }
        }
    }
}

/// Which ends of a horizontal strip have cards scrolled out of view.
private struct FlowEdges: Equatable {
    var leading = false
    var trailing = false
}

private final class FlowEdgesBox: ObservableObject {
    @Published var edges = FlowEdges()
}

/// Fades a horizontal strip's edge only while cards are clipped there, so
/// the strip reads as scrollable without dimming a card that fits. Updates
/// only when the scroll position or content size changes (no polling).
private struct FlowEdgeFade: ViewModifier {
    @StateObject private var box = FlowEdgesBox()
    private let width: CGFloat = 14

    func body(content: Content) -> some View {
        let edges = box.edges
        content
            .onScrollGeometryChange(for: FlowEdges.self) { geometry in
                let x = geometry.contentOffset.x
                return FlowEdges(
                    leading: x > 1,
                    trailing: geometry.contentSize.width - x - geometry.containerSize.width > 1
                )
            } action: { _, new in
                box.edges = new
            }
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [Color.black.opacity(edges.leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                    Color.black
                    LinearGradient(colors: [.black, Color.black.opacity(edges.trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                }
                .animation(SparkVMotion.hover(), value: edges)
            )
    }
}

private struct FlowVocabularyChip: View {
    let kind: String
    let systemImage: String
    let title: String
    let detail: String
    let help: String
    let edit: () -> Void
    let delete: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                    Text(kind)
                    Spacer(minLength: 2)
                    if hover.isOn {
                        Image(systemName: "pencil").transition(.opacity)
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: FlowStyle.cardWidth - 20)
            .frame(maxHeight: .infinity)
            .background(FlowCardBackground(highlighted: hover.isOn))
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hovering in
            withAnimation(SparkVMotion.hover()) { hover.isOn = hovering }
        }
        .help(help)
        .contextMenu {
            Button("Edit", action: edit)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
    }
}

/// Two labelled fields and Done / Delete, shared by both editors.
private struct FlowPairEditor: View {
    let firstLabel: String
    let firstPrompt: String
    let first: Binding<String>
    let secondLabel: String
    let secondPrompt: String
    let second: Binding<String>
    let done: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 4) {
                field(firstLabel, firstPrompt, first)
                field(secondLabel, secondPrompt, second)
            }
            VStack(spacing: 4) {
                FlowIconButton(systemImage: "checkmark", help: "Done", action: done)
                FlowIconButton(systemImage: "trash", help: "Delete", color: SparkVTheme.choose(apple: Color.red.opacity(0.85), sparkv: SparkVTheme.red), action: delete)
            }
        }
        .onExitCommand(perform: done)
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 50, alignment: .trailing)
            TextField("", text: text, prompt: Text(prompt).foregroundColor(SparkVTheme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.text)
                .onSubmit(done)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(FlowCardBackground(highlighted: true))
    }
}

private struct FlowWordEditor: View {
    @EnvironmentObject private var store: FlowStore
    let word: FlowWord
    @ObservedObject var model: FlowViewModel

    var body: some View {
        FlowPairEditor(
            firstLabel: "Word", firstPrompt: "Name or term, spelled your way", first: binding(\.term),
            secondLabel: "Heard as", secondPrompt: "Optional: what dictation writes, comma separated",
            second: heardBinding, done: close,
            delete: {
                let current = store.words.first { $0.id == word.id } ?? word
                guard !current.term.trimmingCharacters(in: .whitespaces).isEmpty else { return close() }
                FlowConfirm.ask(
                    "Delete “\(current.term)” from the Dictionary?", detail: "Dictation will stop correcting its spelling."
                ) {
                    model.editingWordID = nil
                    store.deleteWord(current)
                }
            }
        )
    }

    private func binding(_ path: WritableKeyPath<FlowWord, String>) -> Binding<String> {
        let store = store
        let id = word.id
        return Binding(
            get: { store.words.first { $0.id == id }?[keyPath: path] ?? "" },
            set: { value in
                guard var updated = store.words.first(where: { $0.id == id }) else { return }
                updated[keyPath: path] = value
                store.updateWord(updated)
            }
        )
    }

    /// Kept exactly as typed (split on commas only), so typing ", " works.
    private var heardBinding: Binding<String> {
        let store = store
        let id = word.id
        return Binding(
            get: { store.words.first { $0.id == id }?.heardAs.joined(separator: ",") ?? "" },
            set: { value in
                guard var updated = store.words.first(where: { $0.id == id }) else { return }
                updated.heardAs = value.isEmpty ? [] : value.components(separatedBy: ",")
                store.updateWord(updated)
            }
        )
    }

    private func close() {
        model.editingWordID = nil
        guard let stored = store.words.first(where: { $0.id == word.id }) else { return }
        if stored.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.deleteWord(stored)
        }
    }
}

private struct FlowSnippetEditor: View {
    @EnvironmentObject private var store: FlowStore
    let snippet: FlowSnippet
    @ObservedObject var model: FlowViewModel

    var body: some View {
        FlowPairEditor(
            firstLabel: "Say", firstPrompt: "Trigger phrase, e.g. my calendar link", first: binding(\.trigger),
            secondLabel: "Types", secondPrompt: "The text to type instead", second: binding(\.expansion),
            done: close,
            delete: {
                let current = store.snippets.first { $0.id == snippet.id } ?? snippet
                guard !(current.trigger + current.expansion).trimmingCharacters(in: .whitespaces).isEmpty else {
                    return close()
                }
                FlowConfirm.ask("Delete this snippet?", detail: "Saying “\(current.trigger)” will no longer type its text.") {
                    model.editingSnippetID = nil
                    store.deleteSnippet(current)
                }
            }
        )
    }

    private func binding(_ path: WritableKeyPath<FlowSnippet, String>) -> Binding<String> {
        let store = store
        let id = snippet.id
        return Binding(
            get: { store.snippets.first { $0.id == id }?[keyPath: path] ?? "" },
            set: { value in
                guard var updated = store.snippets.first(where: { $0.id == id }) else { return }
                updated[keyPath: path] = value
                store.updateSnippet(updated)
            }
        )
    }

    /// A snippet left blank is dropped on close (a half-filled one is kept
    /// for later and simply does nothing until both parts are filled in).
    private func close() {
        model.editingSnippetID = nil
        guard let stored = store.snippets.first(where: { $0.id == snippet.id }) else { return }
        if (stored.trigger + stored.expansion).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.deleteSnippet(stored)
        }
    }
}

// MARK: - Small controls

private struct FlowSmallButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var iconColor: Color = SparkVTheme.textSecondary
    let action: () -> Void
    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(tint.map { hover.isOn ? (SparkVTheme.isApple ? $0.opacity(0.75) : SparkVTheme.redDeep) : $0 } ?? (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .strokeBorder(tint == nil && !SparkVTheme.isApple ? SparkVTheme.stroke : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
    }
}

private struct FlowIconButton: View {
    let systemImage: String
    let help: String
    var color: Color = SparkVTheme.text
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
    }
}

private struct FlowEmptyHint: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(FlowStyle.accent.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowCardBackground(highlighted: false))
    }
}
