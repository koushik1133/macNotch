import SwiftUI

/// Prompt Refiner's tab in the expanded drawer (about 508×114 pt, dark): a
/// field for the rough prompt, the target, and Refine, which opens the panel
/// for the questions. Needs `PromptRefinerController` as an environment object.
struct PromptRefinerDrawerView: View {
    @EnvironmentObject private var controller: PromptRefinerController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(controller.isWorking ? LabsTint.feature : SparkVTheme.textSecondary)
                Text("Prompt Refiner")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PRTargetMenu(controller: controller, compact: true)
                    .disabled(controller.isWorking)
                    .environment(\.colorScheme, .dark)
                DrawerIconButton(systemImage: "clock.arrow.circlepath", help: "History") { controller.showHistory() }
                    .disabled(controller.history.isEmpty)
                DrawerIconButton(systemImage: "arrow.up.forward.app", help: "Open panel") { controller.openPanel() }
            }

            HStack(spacing: 6) {
                if controller.canDictate {
                    DrawerIconButton(
                        systemImage: controller.isDictating ? "stop.circle.fill" : "mic.fill",
                        help: controller.isDictating ? "Stop dictating" : "Dictate the prompt",
                        tint: controller.isDictating ? SparkVTheme.recording : SparkVTheme.textSecondary
                    ) {
                        controller.toggleDictation(into: .draft)
                    }
                }
                TextField("Rough prompt, e.g. write a cold email", text: $controller.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SparkVTheme.text)
                    .onSubmit { if controller.canRefine, !controller.isWorking { controller.refine() } }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .labsFieldWell()
                PRButton(title: "Refine", systemImage: "wand.and.stars", isPrimary: true) { controller.refine() }
                    .disabled(!controller.canRefine || controller.isWorking)
            }

            HStack(spacing: 6) {
                if let last = controller.history.first {
                    Text("Last: \(last.title)")
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button("Copy again") { controller.copyLast() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SparkVTheme.link)
                } else {
                    Text("Asks 2–5 quick questions, then copies a structured prompt. Never runs it.")
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(controller.engineLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { controller.prepare() }
    }

    private var statusText: String {
        switch controller.phase {
        case .compose: return ""
        case .askingQuestions: return "Thinking of questions…"
        case .answering: return "\(controller.questions.count) questions waiting in the panel"
        case .refining: return "Refining…"
        case .done: return controller.toast ?? "Ready to copy"
        case .failed: return "Something went wrong"
        }
    }
}

private struct DrawerIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = SparkVTheme.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
