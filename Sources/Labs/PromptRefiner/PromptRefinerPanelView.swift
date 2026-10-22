import AppKit
import SwiftUI

/// Content of the Prompt Refiner panel: compose → questions → result, plus
/// the history list. No `@State` (its macro plugin isn't in the Command Line
/// Tools): all state lives in the controller.
struct PromptRefinerPanelView: View {
    @ObservedObject var controller: PromptRefinerController

    var body: some View {
        TrayAICard(material: .hudWindow) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(TrayAIWindowDragArea())
                Divider().opacity(0.5)
                ZStack {
                    if controller.showsHistory {
                        PRHistoryList(controller: controller)
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { toast }
            }
        }
        .frame(width: PromptRefinerPanelMetrics.cardSize.width, height: PromptRefinerPanelMetrics.cardSize.height)
        .padding(PromptRefinerPanelMetrics.margin)
        .environment(\.colorScheme, .dark)
        .tint(SparkVTheme.accent)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            TrayAICircleButton(systemImage: "xmark", help: "Close (Esc)") { controller.closePanel() }
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LabsTint.feature)
            Text(controller.showsHistory ? "History" : "Prompt Refiner")
                .font(SparkVTheme.headline(14))
                .tracking(-0.2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            PRTargetMenu(controller: controller)
                .disabled(controller.isWorking)
            TrayAICircleButton(
                systemImage: controller.showsHistory ? "chevron.backward" : "clock.arrow.circlepath",
                help: controller.showsHistory ? "Back" : "History"
            ) {
                controller.cancelPendingDelete()
                controller.showsHistory.toggle()
            }
            PRSettingsButton(controller: controller)
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .compose: compose
        case .askingQuestions:
            if controller.streamingQuestions.isEmpty {
                working(title: "Thinking of a few questions…", showsSkip: true)
            } else {
                streamingQuestions
            }
        case .answering: answering
        case .refining:
            if controller.streamingText.isEmpty {
                working(title: "Writing your refined prompt…", showsSkip: false)
            } else {
                streamingResult
            }
        case .done: result
        case .failed(let message): failed(message)
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rough prompt")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            PRTextArea(text: $controller.draft, placeholder: "e.g. make a landing page for my app", monospaced: false)
                .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                if controller.canDictate {
                    PRMicButton(isOn: controller.isDictating(into: .draft)) { controller.toggleDictation(into: .draft) }
                }
                Toggle("Ask clarifying questions first", isOn: $controller.askQuestionsFirst)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                PRButton(title: "Refine", systemImage: "wand.and.stars", isPrimary: true, shortcut: "⌘↩") {
                    controller.refine()
                }
                .disabled(!controller.canRefine)
            }
            footnote("\(controller.engineLabel) · your prompt is only refined, never run.")
        }
        .padding(14)
    }

    private func working(title: String, showsSkip: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.regular)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let started = controller.workStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(started))))s · \(controller.engineLabel)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("“\(controller.sessionRough)”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            HStack(spacing: 10) {
                PRButton(title: "Cancel", systemImage: nil, isPrimary: false) { controller.cancelWork() }
                if showsSkip {
                    PRButton(title: "Skip questions", systemImage: "forward.fill", isPrimary: false) {
                        controller.skipQuestions()
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(14)
    }

    private var elapsedLabel: some View {
        Group {
            if let started = controller.workStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(started))))s · \(controller.engineLabel)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Questions as the model writes them (read-only until complete).
    private var streamingQuestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing questions…").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                elapsedLabel
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(controller.streamingQuestions.enumerated()), id: \.offset) { index, question in
                        PRQuestionPreview(index: index, question: question)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            Divider().opacity(0.5)
            HStack {
                Spacer()
                PRButton(title: "Cancel", systemImage: nil, isPrimary: false) { controller.cancelWork() }
                PRButton(title: "Skip questions", systemImage: "forward.fill", isPrimary: false) {
                    controller.skipQuestions()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// The prompt as the model writes it.
    private var streamingResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing your prompt…").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                elapsedLabel
            }
            ScrollView {
                Text(controller.streamingText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.03)))
            HStack {
                Spacer()
                PRButton(title: "Cancel", systemImage: nil, isPrimary: false) { controller.cancelWork() }
            }
        }
        .padding(14)
    }

    private var answering: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("A few questions to tailor your prompt")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("“\(controller.sessionRough)” · tap a suggestion or type your own; leave any blank.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(controller.questions.enumerated()), id: \.element.id) { index, question in
                        PRQuestionCard(controller: controller, index: index, question: question)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                footnote(controller.questionSource.map {
                    String(format: "%@ · %.1fs", $0.label, controller.questionLatency)
                } ?? "")
                Spacer()
                PRButton(title: "Skip questions", systemImage: "forward.fill", isPrimary: false) {
                    controller.skipQuestions()
                }
                PRButton(title: "Refine", systemImage: "wand.and.stars", isPrimary: true, shortcut: "⌘↩") {
                    controller.submitAnswers()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(controller.refinedTitle.isEmpty ? "Refined prompt" : controller.refinedTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text("for \(controller.target.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("editable")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            PRTextArea(text: $controller.refinedText, placeholder: "", monospaced: true)
                .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                Text("Refine:")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(PromptRefinerController.quickRefinements, id: \.self) { choice in
                    PRChip(title: choice, isOn: false) { controller.quickRefine(choice) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if controller.canDictate {
                    PRMicButton(isOn: controller.isDictating(into: .feedback)) { controller.toggleDictation(into: .feedback) }
                }
                TextField("What should change? (optional, e.g. shorter, add tests)", text: $controller.feedback)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .labsFieldWell()
                    .onSubmit { controller.refineAgain() }
                PRButton(title: "Refine again", systemImage: "arrow.clockwise", isPrimary: false) {
                    controller.refineAgain()
                }
            }
            HStack(spacing: 8) {
                footnote(controller.lastRefinement.map {
                    String(format: "%@ · %.1fs · %d chars", $0.source.label, $0.latency, controller.refinedText.count)
                } ?? "")
                Spacer()
                PRButton(title: "New", systemImage: "square.and.pencil", isPrimary: false) { controller.startOver() }
                PRButton(title: "Copy", systemImage: "doc.on.doc", isPrimary: true, shortcut: "⌘↩") {
                    controller.copyRefined()
                }
            }
        }
        .padding(14)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(SparkVTheme.warning)
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
            PRButton(title: "Try again", systemImage: "arrow.clockwise", isPrimary: true) { controller.refine() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(14)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private var toast: some View {
        if let toast = controller.toast {
            Text(toast)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(SparkVTheme.background.opacity(0.92)))
                .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                .padding(.bottom, 58)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Question card

private struct PRQuestionCard: View {
    @ObservedObject var controller: PromptRefinerController
    let index: Int
    let question: ClarifyingQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(LabsTint.feature)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(LabsTint.featureSoft))
                Text(question.question)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                PRFlowLayout(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        PRChip(title: option, isOn: question.selected.contains(option)) {
                            controller.toggle(option: option, questionID: question.id)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(question.options.isEmpty ? "Your answer" : "Or type your own…", text: binding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .labsFieldWell()
                if controller.canDictate {
                    PRMicButton(isOn: controller.isDictating(into: .question(question.id))) {
                        controller.toggleDictation(into: .question(question.id))
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .strokeBorder(question.isAnswered ? SparkVTheme.choose(apple: Color.accentColor.opacity(0.5), sparkv: SparkVTheme.brandRed.opacity(0.5)) : SparkVTheme.stroke)
        )
    }

    private var binding: Binding<String> {
        let id = question.id
        return Binding(
            get: { controller.questions.first { $0.id == id }?.freeText ?? "" },
            set: { newValue in
                guard let index = controller.questions.firstIndex(where: { $0.id == id }) else { return }
                controller.questions[index].freeText = newValue
            }
        )
    }
}

private struct PRQuestionPreview: View {
    let index: Int
    let question: ClarifyingQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(LabsTint.feature)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(LabsTint.featureSoft))
                Text(question.question)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            PRFlowLayout(spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                    Text(option)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(SparkVTheme.surface))
                        .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .labsCard(SparkVTheme.cornerMedium, fill: Color.white.opacity(0.04))
        .opacity(0.8)
    }
}

// MARK: - History

private struct PRHistoryList: View {
    @ObservedObject var controller: PromptRefinerController

    var body: some View {
        if controller.history.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("Refined prompts appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(controller.history) { record in
                            PRHistoryRow(controller: controller, record: record)
                        }
                    }
                    .padding(12)
                }
                Divider().opacity(0.5)
                HStack {
                    if controller.confirmsClearHistory {
                        Text(controller.history.count == 1
                             ? "Delete the saved prompt? This can't be undone."
                             : "Delete all \(controller.history.count) saved prompts? This can't be undone.")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(SparkVTheme.warning)
                            .lineLimit(1)
                        Spacer()
                        PRButton(title: "Cancel", systemImage: nil, isPrimary: false) { controller.cancelPendingDelete() }
                        PRButton(title: "Delete all", systemImage: "trash", isPrimary: false, isDestructive: true) {
                            controller.clearHistory()
                        }
                    } else {
                        Text("\(controller.history.count) saved · stored on this Mac only")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        PRButton(title: "Clear all", systemImage: "trash", isPrimary: false) { controller.requestClearHistory() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }
}

private struct PRHistoryRow: View {
    @ObservedObject var controller: PromptRefinerController
    let record: PromptRefinementRecord
    @StateObject private var isHovered = ViewFlag()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.target.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isHovered.isOn ? LabsTint.feature : SparkVTheme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(record.rough)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(record.target.title) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if controller.pendingDeleteID == record.id {
                PRButton(title: "Cancel", systemImage: nil, isPrimary: false) { controller.cancelPendingDelete() }
                PRButton(title: "Delete", systemImage: "trash", isPrimary: false, isDestructive: true) {
                    controller.deleteHistory(id: record.id)
                }
            } else if isHovered.isOn {
                TrayAICircleButton(systemImage: "doc.on.doc", help: "Copy") { controller.copy(record) }
                TrayAICircleButton(systemImage: "trash", help: "Delete…") { controller.requestDelete(id: record.id) }
            }
        }
        .padding(9)
        .labsCard(SparkVTheme.cornerSmall, fill: isHovered.isOn ? SparkVTheme.surfaceHover : Color.white.opacity(0.04))
        .contentShape(Rectangle())
        .onHover { isHovered.isOn = $0 }
        .onTapGesture { controller.restore(record) }
        .help("Open this refinement")
    }
}

// MARK: - Controls

struct PRTargetMenu: View {
    @ObservedObject var controller: PromptRefinerController
    var compact = false

    var body: some View {
        Menu {
            ForEach(PromptTarget.allCases) { target in
                Button {
                    controller.target = target
                } label: {
                    if target == controller.target {
                        Label(target.title, systemImage: "checkmark")
                    } else {
                        Text(target.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.target.systemImage)
                Text(controller.target.title)
            }
            .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(SparkVTheme.text)
        .fixedSize()
        .help("Which assistant the prompt is for")
    }
}

private struct PRSettingsButton: View {
    @ObservedObject var controller: PromptRefinerController

    var body: some View {
        TrayAICircleButton(systemImage: "gearshape", help: "Settings") { controller.showsSettings.toggle() }
            .popover(isPresented: $controller.showsSettings, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt Refiner")
                        .font(.system(size: 12, weight: .semibold))
                    Toggle("Ask clarifying questions first", isOn: $controller.askQuestionsFirst)
                        .toggleStyle(.checkbox)
                    Toggle("Use Groq when a Clicky key is saved", isOn: $controller.allowGroq)
                        .toggleStyle(.checkbox)
                    Text("Off: everything runs on this Mac (Apple Intelligence, or built-in templates when it's unavailable). On: your rough prompt and answers are sent to api.groq.com.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .padding(12)
                .frame(width: 280)
                .tint(SparkVTheme.accent)
            }
    }
}

struct PRButton: View {
    let title: String
    let systemImage: String?
    let isPrimary: Bool
    var shortcut: String?
    var isDestructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
                if let shortcut, isPrimary {
                    Text(shortcut).font(.system(size: 9.5, weight: .medium)).opacity(0.65)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .foregroundStyle(isPrimary ? Color.white : isDestructive ? SparkVTheme.destructive : SparkVTheme.text)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(isPrimary ? SparkVTheme.accent : isDestructive ? SparkVTheme.recordingSoft : SparkVTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .strokeBorder(isPrimary ? Color.clear : isDestructive ? SparkVTheme.destructive.opacity(0.5) : SparkVTheme.stroke)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PRMicButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? SparkVTheme.recording : SparkVTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(isOn ? SparkVTheme.recordingSoft : SparkVTheme.surface))
                .overlay(Circle().strokeBorder(isOn ? SparkVTheme.recording.opacity(0.5) : SparkVTheme.stroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Stop dictating" : "Dictate")
    }
}

private struct PRChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .foregroundStyle(isOn ? Color.white : SparkVTheme.text)
            .background(Capsule().fill(isOn ? SparkVTheme.accent : SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : SparkVTheme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Multi-line text field with a placeholder.
struct PRTextArea: View {
    @Binding var text: String
    let placeholder: String
    let monospaced: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(SparkVTheme.stroke))
    }
}

/// Wraps chips onto as many lines as needed.
struct PRFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row(indices: [], y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
