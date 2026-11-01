import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The meeting notes window: past meetings on the left, the selected one's
/// minutes, transcript and suggested answers on the right. NotchIsland is an
/// agent app, so it shows a Dock icon only while this window is open (the
/// same pattern as the Face Unlock settings window).
@MainActor
final class MeetingNotesWindowController: NSObject, NSWindowDelegate {
    private unowned let assistant: MeetingAssistant
    private let model = MeetingNotesWindowModel()
    private var window: NSWindow?

    private var appearanceObserver: NSObjectProtocol?

    init(assistant: MeetingAssistant) {
        self.assistant = assistant
        super.init()
        // The SwiftUI root rebuilds itself; the AppKit ground follows here.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.backgroundColor = NSColor(SparkVTheme.background)
            }
        }
    }

    func show(meetingID: UUID?) {
        let window = window ?? makeWindow()
        self.window = window
        model.window = window
        if let meetingID { model.select(meetingID, in: assistant) }
        else if model.selectedID == nil { model.selectedID = assistant.library.first?.id }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows a short status line in the window, if it's open.
    func flash(_ message: String) {
        model.flash(message)
    }

    private func makeWindow() -> NSWindow {
        let root = MeetingNotesRootView(model: model).followsAppearance().environmentObject(assistant)
        let hosting = NSHostingController(rootView: AnyView(root))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Meeting Notes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(SparkVTheme.background)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.setContentSize(NSSize(width: 980, height: 660))
        window.center()
        window.setFrameAutosaveName("SparkV.MeetingNotes")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// UI state of the notes window (no `@State` with the Command Line Tools).
@MainActor
final class MeetingNotesWindowModel: ObservableObject {
    enum DetailTab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case transcript = "Transcript"
        case answers = "Answers"
        var id: String { rawValue }
    }

    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { titleDraft = nil } }
    }
    @Published var tab: DetailTab = .notes
    /// Non-nil while the title is being edited.
    @Published var titleDraft: String?
    @Published private(set) var toast: String?
    @Published private(set) var isSavingToNotes = false

    weak var window: NSWindow?
    private var toastTask: Task<Void, Never>?

    func select(_ id: UUID, in assistant: MeetingAssistant) {
        selectedID = id
        // Live meetings open on the notepad (the transcript is one click away).
        tab = .notes
    }

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(message.count > 60 ? 6 : 3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Actions

    func copyMarkdown(_ record: MeetingRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MeetingFormat.markdown(for: record), forType: .string)
        flash("Copied as Markdown")
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flash("Copied")
    }

    func saveToAppleNotes(_ record: MeetingRecord) {
        guard !isSavingToNotes else { return }
        isSavingToNotes = true
        let title = record.title
        let html = MeetingFormat.notesHTML(for: record)
        Task { [weak self] in
            do {
                try await MeetingNotesExporter.saveToAppleNotes(title: title, html: html)
                self?.flash("Saved to Apple Notes")
            } catch {
                AppLog.log("Meetings: Apple Notes export failed: \(error.localizedDescription)")
                self?.flash(error.localizedDescription)
                if case MeetingNotesExporter.Failure.notAuthorized = error {
                    // Deduplicated: a request that already opened the pane doesn't open it twice.
                    PermissionCenter.shared.openSettings(
                        .automation(bundleID: MeetingNotesExporter.notesBundleID), from: "Meeting notes"
                    )
                }
            }
            self?.isSavingToNotes = false
        }
    }

    func exportMarkdown(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: record) + ".md"
        let markdown = MeetingFormat.markdown(for: record)
        Task { [weak self] in
            let response: NSApplication.ModalResponse
            if let window = self?.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(markdown.utf8).write(to: url, options: .atomic)
                self?.flash("Exported \(url.lastPathComponent)")
            } catch {
                self?.flash("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func confirmDelete(_ record: MeetingRecord, assistant: MeetingAssistant) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(record.title)”?"
        alert.informativeText = "Its notes, transcript and suggested answers will be removed from this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let id = record.id
        Task { [weak self] in
            let response: NSApplication.ModalResponse
            if let window = self?.window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return }
            assistant.delete(meetingID: id)
            if self?.selectedID == id { self?.selectedID = assistant.library.first?.id }
        }
    }

    private static func fileName(for record: MeetingRecord) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let name = record.title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Meeting Notes" : name
    }
}

// MARK: - Root

private struct MeetingNotesRootView: View {
    @ObservedObject var model: MeetingNotesWindowModel
    @EnvironmentObject private var assistant: MeetingAssistant

    var body: some View {
        HStack(spacing: 0) {
            MeetingSidebar(model: model)
                .frame(width: 260)
            Divider()
            Group {
                if let id = model.selectedID, let record = assistant.record(id: id) {
                    MeetingDetail(model: model, record: record)
                } else {
                    MeetingEmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MeetingPalette.background)
        .tint(SparkVTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: assistant.library.map(\.id)) { _, ids in
            if let selected = model.selectedID, !ids.contains(selected), assistant.current?.id != selected {
                model.selectedID = ids.first
            } else if model.selectedID == nil {
                model.selectedID = ids.first
            }
        }
    }
}

enum MeetingPalette {
    // Apple: a macOS dark window (#1E1E1E content, vibrant sidebar, system
    // accent). SparkV Red (sparkv.si): near-black ground, hairlines, one red.
    static var background: Color {
        SparkVTheme.choose(apple: Color(red: 30 / 255, green: 30 / 255, blue: 32 / 255), sparkv: SparkVTheme.background)
    }
    static var sidebarColor: Color { Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255) }
    static var card: Color { SparkVTheme.choose(apple: Color.white.opacity(0.05), sparkv: SparkVTheme.surface) }
    static var cardStroke: Color { SparkVTheme.choose(apple: Color.white.opacity(0.08), sparkv: SparkVTheme.stroke) }
    static var accent: Color { SparkVTheme.accent }
}

/// The sidebar ground: macOS sidebar vibrancy in Apple, flat near-black in SparkV Red.
private struct MeetingSidebarBackground: View {
    var body: some View {
        if SparkVTheme.isApple {
            VisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
        } else {
            MeetingPalette.sidebarColor
        }
    }
}

// MARK: - Sidebar

private struct MeetingSidebar: View {
    @ObservedObject var model: MeetingNotesWindowModel
    @EnvironmentObject private var assistant: MeetingAssistant

    private var meetings: [MeetingRecord] {
        var list = assistant.library
        if let live = assistant.current {
            if let index = list.firstIndex(where: { $0.id == live.id }) { list[index] = live }
            else { list.insert(live, at: 0) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SparkVEyebrowLabel(text: "Meetings")
                Spacer()
                recordButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 36)
            .padding(.bottom, 8)

            if meetings.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No meetings yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(meetings) { record in
                        MeetingRow(record: record, isLive: assistant.isLive(record.id))
                            .tag(record.id)
                            .contextMenu {
                                Button("Copy as Markdown") { model.copyMarkdown(record) }
                                Button("Delete…") { model.confirmDelete(record, assistant: assistant) }
                                    .disabled(assistant.isLive(record.id))
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Suggest answers to questions", isOn: $assistant.suggestAnswers)
                Toggle("Use Groq for notes and answers", isOn: $assistant.allowGroqForMeetings)
                    .help("Sends the transcript to Groq with Clicky's API key. Off: everything stays on this Mac.")
            }
            .toggleStyle(.switch)
            .tint(SparkVTheme.accent)
            .controlSize(.mini)
            .font(.system(size: 11))
            .padding(12)
        }
        .background(MeetingSidebarBackground())
    }

    @ViewBuilder
    private var recordButton: some View {
        switch assistant.phase {
        case .recording:
            Button {
                assistant.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(SparkVPrimaryButtonStyle(tint: SparkVTheme.recording))
        case .summarizing:
            ProgressView().controlSize(.small)
        case .idle, .failed:
            Button {
                assistant.start(title: nil, calendarEventID: nil)
                if let id = assistant.current?.id { model.select(id, in: assistant) }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(SparkVPrimaryButtonStyle(tint: SparkVTheme.recording))
        }
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isLive {
                    SparkVStatusDot(kind: .recording, color: SparkVTheme.recording, size: 7, label: "Live")
                }
                Text(record.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(record.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                Text("·")
                Text(isLive ? "Recording" : MeetingFormat.duration(MeetingFormat.duration(of: record)))
                if let mine = record.notes?.myTasks.filter({ !$0.isDone }).count, mine > 0 {
                    Spacer(minLength: 4)
                    Text("\(mine)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.white)
                        .background(Capsule().fill(MeetingPalette.accent))
                        .help("\(mine) open task\(mine == 1 ? "" : "s") for you")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct MeetingEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Record a meeting to get notes, your tasks and live answers.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail

private struct MeetingDetail: View {
    @ObservedObject var model: MeetingNotesWindowModel
    @EnvironmentObject private var assistant: MeetingAssistant
    let record: MeetingRecord

    private var isLive: Bool { assistant.isLive(record.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 12)

            if isLive && assistant.phase == .recording {
                consentBanner
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            Picker("", selection: $model.tab) {
                ForEach(MeetingNotesWindowModel.DetailTab.allCases) { tab in
                    Text(tabTitle(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
            .accessibilityLabel("Section")

            Divider()

            switch model.tab {
            case .notes: MeetingNotesTab(record: record, isLive: isLive)
            case .transcript: MeetingTranscriptTab(record: record, isLive: isLive)
            case .answers: MeetingAnswersTab(model: model, record: record)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(SparkVTheme.background.opacity(0.95)))
                    .overlay(Capsule().stroke(MeetingPalette.cardStroke))
                    .padding(.bottom, 18)
                    .transition(.labsToastRise)
            }
        }
        // Toast enters and leaves: strong ease-out (was ease-in-out 0.2 s).
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: model.toast)
    }

    private func tabTitle(_ tab: MeetingNotesWindowModel.DetailTab) -> String {
        switch tab {
        case .answers where !record.answers.isEmpty: "Answers (\(record.answers.count))"
        default: tab.rawValue
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let draft = model.titleDraft {
                    TextField("Title", text: Binding(
                        get: { draft },
                        set: { model.titleDraft = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(SparkVTheme.title(24))
                    .tracking(-0.6)
                    .onSubmit { commitTitle() }
                    .onExitCommand { model.titleDraft = nil }
                } else {
                    HStack(spacing: 6) {
                        Text(record.title)
                            .font(SparkVTheme.title(24))
                            .tracking(-0.6)
                            .foregroundStyle(SparkVTheme.text)
                            .lineLimit(1)
                            .onTapGesture(count: 2) { model.titleDraft = record.title }
                        Button {
                            model.titleDraft = record.title
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(SparkVPressStyle())
                        .help("Rename")
                        .accessibilityLabel("Rename")
                    }
                }
                metadata
            }
            Spacer(minLength: 12)
            toolbar
        }
    }

    private func commitTitle() {
        if let draft = model.titleDraft {
            assistant.rename(meetingID: record.id, to: draft)
        }
        model.titleDraft = nil
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
            Text("·")
            if isLive && assistant.phase == .recording {
                TimelineView(.periodic(from: record.startedAt, by: 1)) { context in
                    HStack(spacing: 4) {
                        SparkVStatusDot(kind: .recording, color: SparkVTheme.recording, size: 6, label: "")
                        Text("Recording " + MeetingFormat.clock(context.date.timeIntervalSince(record.startedAt)))
                            .monospacedDigit()
                    }
                }
            } else if isLive {
                Text("Writing notes…")
            } else {
                Text(MeetingFormat.duration(MeetingFormat.duration(of: record)))
            }
            if let by = record.notes?.generatedBy, !by.isEmpty {
                Text("·")
                Text(by)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("doc.on.doc", "Copy as Markdown") { model.copyMarkdown(record) }
            toolButton(model.isSavingToNotes ? "hourglass" : "note.text.badge.plus", "Save to Apple Notes") {
                model.saveToAppleNotes(record)
            }
            .disabled(model.isSavingToNotes)
            toolButton("square.and.arrow.up", "Export .md") { model.exportMarkdown(record) }
            toolButton("text.badge.checkmark", "Wrap-up") {
                MeetingWrapUpController.current?.openWindow(meetingID: record.id)
            }
            .disabled(isLive || MeetingWrapUpController.current == nil)
            if assistant.regenerating.contains(record.id) {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                toolButton("arrow.clockwise", "Regenerate notes") {
                    assistant.regenerateNotes(meetingID: record.id)
                    model.tab = .notes
                }
                .disabled(isLive || record.segments.isEmpty)
            }
            toolButton("trash", "Delete") { model.confirmDelete(record, assistant: assistant) }
                .disabled(isLive)
        }
    }

    private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private var consentBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(SparkVTheme.warning)
            Text("Let participants know you're recording. Recording others without consent may be illegal where you are.")
                .font(.system(size: 12))
            Spacer(minLength: 0)
            MeetingLevelMeter(symbol: "mic.fill", level: assistant.recorder.micLevel)
            MeetingLevelMeter(symbol: "speaker.wave.2.fill", level: assistant.recorder.systemLevel)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.warning.opacity(0.3)))
    }
}

// MARK: - Notes tab

private struct MeetingNotesTab: View {
    @EnvironmentObject private var assistant: MeetingAssistant
    let record: MeetingRecord
    let isLive: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLive, let live = LiveMeetingAssist.current {
                    MeetingLiveFlagsSection(assist: live, meetingID: record.id)
                }
                if let notes = record.notes {
                    content(notes)
                } else {
                    placeholder
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func content(_ notes: MeetingNotes) -> some View {
        let name = MeetingAssistant.userName
        MeetingCard(title: "\(name)'s tasks", symbol: "person.crop.circle.badge.checkmark", tint: MeetingPalette.accent) {
            if notes.myTasks.isEmpty {
                Text("Nothing assigned to you.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notes.myTasks) { task in
                    MeetingTaskRow(task: task, showOwner: false) { done in
                        assistant.setTask(task.id, done: done, meetingID: record.id)
                    }
                }
            }
        }

        if !notes.summary.isEmpty {
            MeetingSection(title: "Minutes of meeting") {
                Text(notes.summary)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        bullets("Key points", notes.keyPoints, symbol: "circle.fill")
        bullets("Decisions", notes.decisions, symbol: "checkmark.seal.fill")

        if !notes.othersTasks.isEmpty {
            MeetingSection(title: "Others' tasks") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(MeetingFormat.groupedByOwner(notes.othersTasks), id: \.0) { owner, tasks in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(owner)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(tasks) { task in
                                MeetingTaskRow(task: task, showOwner: false) { done in
                                    assistant.setTask(task.id, done: done, meetingID: record.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        bullets("Open questions", notes.openQuestions, symbol: "questionmark.circle")
        bullets("Next steps", notes.nextSteps, symbol: "arrow.right.circle")

        MeetingSection(title: "My notes") {
            MeetingUserNotesEditor(record: record, minHeight: 90)
        }
    }

    @ViewBuilder
    private func bullets(_ title: String, _ items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            MeetingSection(title: title) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: symbol)
                                .font(.system(size: symbol == "circle.fill" ? 5 : 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(item)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if isLive && assistant.phase == .summarizing || assistant.regenerating.contains(record.id) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Writing notes…")
                    .foregroundStyle(.secondary)
            }
        } else if isLive {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes are written when you stop recording.")
                    .font(.system(size: 14, weight: .medium))
                Text("\(record.segments.count) transcript segment\(record.segments.count == 1 ? "" : "s") so far. Questions aimed at you get a suggested answer under the notch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            MeetingSection(title: "My notes") {
                VStack(alignment: .leading, spacing: 6) {
                    MeetingUserNotesEditor(record: record, minHeight: 220)
                    Text("Jot down what matters; the minutes are written around your points. Lines starting with \"todo:\" or \"[ ]\" become your tasks.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        } else if record.segments.isEmpty {
            Text("Nothing was transcribed in this meeting.")
                .foregroundStyle(.secondary)
            if record.userNotes?.isEmpty == false {
                MeetingSection(title: "My notes") {
                    MeetingUserNotesEditor(record: record, minHeight: 90)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No notes yet for this meeting.")
                    .font(.system(size: 14, weight: .medium))
                Button("Write notes") { assistant.regenerateNotes(meetingID: record.id) }
                    .buttonStyle(SparkVPrimaryButtonStyle())
            }
            MeetingSection(title: "My notes") {
                MeetingUserNotesEditor(record: record, minHeight: 90)
            }
        }
    }
}

/// The user's own notepad for a meeting (typed during or after it).
private struct MeetingUserNotesEditor: View {
    @EnvironmentObject private var assistant: MeetingAssistant
    let record: MeetingRecord
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: Binding(
            get: { record.userNotes ?? "" },
            set: { assistant.setUserNotes($0, meetingID: record.id) }
        ))
        .font(.system(size: 13))
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(MeetingPalette.card))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(MeetingPalette.cardStroke))
        .overlay(alignment: .topLeading) {
            if (record.userNotes ?? "").isEmpty {
                Text("Type your notes…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct MeetingCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .labelStyle(SparkVTintedIconLabelStyle(tint: tint))
            VStack(alignment: .leading, spacing: 8) { content() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .fill(SparkVTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }
}

private struct MeetingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SparkVEyebrowLabel(text: title)
            content()
        }
    }
}

private struct MeetingTaskRow: View {
    let task: ActionItem
    let showOwner: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { task.isDone }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(task.task)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.task)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if showOwner || (task.due?.isEmpty == false) {
                    HStack(spacing: 6) {
                        if showOwner { Text(task.owner) }
                        if let due = task.due, !due.isEmpty {
                            Label(due, systemImage: "calendar")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Transcript tab

private struct MeetingTranscriptTab: View {
    let record: MeetingRecord
    let isLive: Bool

    var body: some View {
        if record.segments.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: isLive ? "waveform" : "text.bubble")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(isLive ? "Listening… the transcript appears here as people talk." : "No transcript.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(record.segments) { segment in
                            MeetingBubble(segment: segment)
                                .id(segment.id)
                        }
                        Color.clear.frame(height: 1).id(MeetingTranscriptTab.bottomID)
                    }
                    .padding(20)
                }
                .onAppear { proxy.scrollTo(MeetingTranscriptTab.bottomID, anchor: .bottom) }
                .onChange(of: record.segments.last?.text) { _, _ in
                    guard isLive else { return }
                    // Follows a live transcript that updates every few
                    // seconds: a short strong ease-out keeps up without
                    // lagging; Reduce Motion jumps.
                    if SparkVMotion.reduceMotion {
                        proxy.scrollTo(MeetingTranscriptTab.bottomID, anchor: .bottom)
                    } else {
                        withAnimation(SparkVMotion.easeOut(SparkVMotion.Duration.hover)) {
                            proxy.scrollTo(MeetingTranscriptTab.bottomID, anchor: .bottom)
                        }
                    }

                }
            }
        }
    }

    static let bottomID = "transcript.bottom"
}

private struct MeetingBubble: View {
    let segment: TranscriptSegment

    private var isMe: Bool { segment.speaker == .me }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 80) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isMe ? MeetingAssistant.userName : "Others")
                        .font(.system(size: 11, weight: .semibold))
                    Text(MeetingFormat.clock(segment.start))
                        .font(.system(size: 10).monospacedDigit())
                }
                .foregroundStyle(.secondary)
                Text(segment.text)
                    .font(.system(size: 13))
                    .italic(!segment.isFinal)
                    .opacity(segment.isFinal ? 1 : 0.65)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                            .fill(isMe ? SparkVTheme.redSoft : SparkVTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                            .strokeBorder(isMe ? SparkVTheme.red.opacity(0.35) : SparkVTheme.stroke)
                    )
            }
            if !isMe { Spacer(minLength: 80) }
        }
    }
}

// MARK: - Answers tab

private struct MeetingAnswersTab: View {
    @ObservedObject var model: MeetingNotesWindowModel
    @EnvironmentObject private var assistant: MeetingAssistant
    let record: MeetingRecord

    var body: some View {
        if record.answers.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(assistant.suggestAnswers
                     ? "When someone asks you a question, a suggested answer shows up here and under the notch."
                     : "Suggested answers are off.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(record.answers.reversed()) { answer in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Q")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(MeetingPalette.accent)
                                Text(answer.question)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Spacer()
                                Text(MeetingFormat.clock(answer.askedAt))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            HStack(alignment: .firstTextBaseline) {
                                Text("A")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(SparkVTheme.text)
                                Text(answer.answer)
                                    .font(.system(size: 14))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button {
                                    model.copy(answer.answer)
                                } label: {
                                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                                }
                                .buttonStyle(.borderless)
                                .help("Copy answer")
                                .accessibilityLabel("Copy answer")
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(
                            assistant.liveAnswer?.id == answer.id ? SparkVTheme.redSoft : MeetingPalette.card
                        ))
                        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(
                            assistant.liveAnswer?.id == answer.id ? SparkVTheme.red.opacity(0.4) : MeetingPalette.cardStroke
                        ))
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Brand pieces

/// sparkv.si eyebrow: a short red dash and a small uppercase monospaced label.
private struct SparkVEyebrowLabel: View {
    let text: String

    var body: some View {
        if SparkVTheme.isApple {
            // Apple: a plain semibold section title, like Notes or Mail.
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
        } else {
            HStack(spacing: 7) {
                Capsule()
                    .fill(SparkVTheme.eyebrowDash)
                    .frame(width: 12, height: 2)
                Text(text.uppercased())
                    .font(SparkVTheme.eyebrow(10.5))
                    .tracking(1.2)
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
        }
    }
}

/// A label whose icon takes the accent while the title stays white.
private struct SparkVTintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
