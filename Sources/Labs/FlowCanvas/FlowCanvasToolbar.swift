import AppKit
import SwiftUI

// Floating chrome over the canvas: the "What do you want to do with these?"
// prompt bar, the suggested-plan bar (Accept / Discard), the bottom toolbar
// (undo, redo, tools, add, run, zoom), the engine/settings menu and toasts.

struct FCPromptBar: View {
    @ObservedObject var editor: FCEditor
    let palette: FCPalette

    var body: some View {
        let scope = editor.planSources.count
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.edge)
                TextField("What do you want to do with these?", text: $editor.goal)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.text)
                    .onSubmit { editor.proposePlan() }
                Text(scope == 0 ? "no cards" : editor.selectedNodes.contains(where: { $0.kind.isSource }) ? "\(scope) selected" : "\(scope) card\(scope == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(palette.cardRaised))
                if editor.isPlanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        editor.proposePlan()
                    } label: {
                        Text("Suggest steps")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(editor.goal.trimmingCharacters(in: .whitespaces).isEmpty ? palette.tertiary : palette.edge))
                    }
                    .buttonStyle(SparkVPressStyle())
                    .disabled(editor.goal.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(palette.chrome))
            .overlay(Capsule().strokeBorder(palette.border))
            .shadow(color: palette.shadow, radius: 12, y: 4)

            if let ghost = editor.ghost {
                FCPlanBar(editor: editor, ghost: ghost, palette: palette)
            }
        }
        .frame(maxWidth: 640)
    }
}

struct FCPlanBar: View {
    @ObservedObject var editor: FCEditor
    let ghost: FCGhostPlan
    let palette: FCPalette

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ForEach(Array(ghost.plan.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(palette.tertiary) }
                        Label(step.title, systemImage: step.kind.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                    }
                }
                Text(ghost.plan.note ?? ghost.plan.producedBy)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Discard") { editor.discardPlan() }
                .buttonStyle(SparkVPressStyle())
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.secondary)
            Button {
                editor.acceptPlan()
            } label: {
                Text("Accept")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(palette.accent))
            }
            .buttonStyle(SparkVPressStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.chrome))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.accent.opacity(0.5)))
        .shadow(color: palette.shadow, radius: 10, y: 3)
    }
}

// MARK: - Bottom toolbar

struct FCToolbar: View {
    @ObservedObject var editor: FCEditor
    let palette: FCPalette

    var body: some View {
        HStack(spacing: 2) {
            tool(symbol: "arrow.uturn.backward", help: "Undo" + (editor.undoName.map { " \($0.lowercased())" } ?? "") + " (⌘Z)", enabled: editor.canUndo) { editor.undo() }
            tool(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: editor.canRedo) { editor.redo() }
            separator
            tool(symbol: "cursorarrow", help: "Select (V)", active: editor.tool == .select) { editor.tool = .select }
            tool(symbol: "hand.raised", help: "Pan (H, or hold Space)", active: editor.tool == .hand) { editor.tool = .hand }
            tool(symbol: "rectangle.dashed", help: "Frame (R): drag to draw", active: editor.tool == .frame) { editor.addFrame() }
            tool(symbol: "point.topleft.down.to.point.bottomright.curvepath", help: "Connect (C): drag from one card to an AI step", active: editor.tool == .connect) {
                editor.tool = editor.tool == .connect ? .select : .connect
            }
            separator
            tool(symbol: "note.text.badge.plus", help: "Text note (N)") { editor.addNote(edit: true) }
            addMenu
            separator
            if editor.isBusy {
                Button {
                    editor.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(palette.text)
                        .background(Capsule().fill(palette.cardRaised))
                }
                .buttonStyle(SparkVPressStyle())
            } else {
                Button {
                    editor.runAll()
                } label: {
                    Label("Run all", systemImage: "play.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(palette.edge))
                }
                .buttonStyle(SparkVPressStyle())
                .help("Run every AI step in order (⌘↩)")
            }
            separator
            tool(symbol: "minus.magnifyingglass", help: "Zoom out (⌘-)") { editor.zoom(by: 1 / 1.2) }
            Button {
                editor.fitAll()
            } label: {
                Text("\(Int((editor.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.text)
                    .frame(width: 44, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SparkVPressStyle())
            .help("Fit all (⌘0)")
            tool(symbol: "plus.magnifyingglass", help: "Zoom in (⌘+)") { editor.zoom(by: 1.2) }
        }
        .padding(5)
        .background(Capsule().fill(palette.chrome))
        .overlay(Capsule().strokeBorder(palette.border))
        .shadow(color: palette.shadow, radius: 14, y: 4)
    }

    private var separator: some View {
        Rectangle().fill(palette.border).frame(width: 1, height: 18).padding(.horizontal, 4)
    }

    private func tool(symbol: String, help: String, active: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.white : (enabled ? palette.text : palette.tertiary))
                .frame(width: 32, height: 28)
                .background(Capsule().fill(active ? palette.accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var addMenu: some View {
        Menu {
            Section("Sources") {
                Button("Paste (⌘V)") { editor.paste() }
                Button("Files…") { editor.chooseFilesToAdd() }
                Button("Link slot") { editor.addSlot(.link) }
                Button("Image slot") { editor.addSlot(.image) }
                Button("PDF slot") { editor.addSlot(.pdf) }
            }
            Section("AI steps (connected to the selection)") {
                ForEach(FCNodeKind.actions) { kind in
                    Button {
                        editor.addAction(kind)
                    } label: {
                        Label(kind.title + " — " + kind.blurb, systemImage: kind.symbol)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 32, height: 28)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a card")
    }
}

// MARK: - Engine / settings

struct FCEngineMenu: View {
    @ObservedObject var editor: FCEditor
    @ObservedObject var settings: FCSettingsModel
    let palette: FCPalette

    var body: some View {
        Menu {
            Text("Running on: " + editor.ai.statusLine)
            Divider()
            Toggle("Allow Flow Canvas to use my Groq key", isOn: $settings.allowsGroq)
            Text(settings.allowsGroq
                 ? "Text goes to api.groq.com (\(FCSettings.textModel); images: \(FCSettings.visionModel))."
                 : "Off: everything runs on this Mac (Apple Intelligence, Vision).")
            Divider()
            Button("Save canvas as template…") { editor.promptSaveAsTemplate() }
            Button(editor.sidebarVisible ? "Hide sidebar" : "Show sidebar") { editor.sidebarVisible.toggle() }
            Button(editor.inspectorVisible ? "Hide inspector" : "Show inspector") { editor.inspectorVisible.toggle() }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(settings.allowsGroq ? palette.accent : SparkVTheme.success).frame(width: 7, height: 7)
                Text(settings.allowsGroq ? "Groq allowed" : "On this Mac")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.text)
                Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(palette.chrome))
            .overlay(Capsule().strokeBorder(palette.border))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Observable wrapper for the Groq opt-in (UserDefaults FlowCanvasAllowsGroq).
@MainActor
final class FCSettingsModel: ObservableObject {
    static let shared = FCSettingsModel()

    @Published var allowsGroq: Bool {
        didSet { if allowsGroq != FCSettings.allowsGroq { FCSettings.allowsGroq = allowsGroq } }
    }

    init() {
        allowsGroq = FCSettings.allowsGroq
    }
}

struct FCToast: View {
    let message: String
    let palette: FCPalette

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(palette.chrome))
            .overlay(Capsule().strokeBorder(palette.border))
            .shadow(color: palette.shadow, radius: 10, y: 3)
            // Drops 4 pt from 96 % (not its whole height); Reduce Motion: fade.
            .transition(.sparkVEnter)
    }
}
