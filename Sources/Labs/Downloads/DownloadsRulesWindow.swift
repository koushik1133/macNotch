import AppKit
import SwiftUI

/// Selection state for the rules window (instead of @State).
@MainActor
final class DownloadsRulesEditorModel: ObservableObject {
    @Published var selection: UUID?
}

/// The rules editor window: watcher settings on top, the rule list on the
/// left, the selected rule on the right (Hazel's layout: conditions, then
/// the action), with a live preview against recent downloads.
@MainActor
final class DownloadsRulesWindowController: NSObject, NSWindowDelegate {
    static let shared = DownloadsRulesWindowController()

    private var window: NSWindow?
    private let model = DownloadsRulesEditorModel()
    private weak var controller: DownloadsController?

    func show(controller: DownloadsController, selecting ruleID: UUID? = nil) {
        if self.controller !== controller || window == nil {
            self.controller = controller
            window?.close()
            window = makeWindow(controller: controller)
        }
        model.selection = ruleID ?? model.selection ?? controller.rules.rules.first?.id
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private func makeWindow(controller: DownloadsController) -> NSWindow {
        let root = DownloadsRulesView(controller: controller, rules: controller.rules, model: model)
        let hosting = NSHostingController(rootView: root.followsAppearance())
        let window = NSWindow(contentViewController: hosting)
        window.title = "SparkV Download Rules"
        window.appearance = NSAppearance(named: .darkAqua)
        LabsWindowGround.follow(window)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(DownloadsRulesView.preferredSize)
        window.contentMinSize = CGSize(width: 680, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the window for next time; nothing to tear down.
    }
}

struct DownloadsRulesView: View {
    static let preferredSize = CGSize(width: 780, height: 520)

    @ObservedObject var controller: DownloadsController
    @ObservedObject var rules: DownloadRuleStore
    @ObservedObject var model: DownloadsRulesEditorModel

    var body: some View {
        VStack(spacing: 0) {
            settings
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider().overlay(SparkVTheme.stroke)
            HStack(spacing: 0) {
                ruleList
                    .frame(width: 250)
                    .background {
                        // Apple: a translucent sidebar, like Finder's. SparkV Red: a flat well.
                        if SparkVTheme.isApple {
                            VisualEffectBackdrop(material: .sidebar).overlay(Color.white.opacity(0.03))
                        } else {
                            SparkVTheme.surface.opacity(0.5)
                        }
                    }
                Divider().overlay(SparkVTheme.stroke)
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .foregroundStyle(SparkVTheme.text)
        .tint(SparkVTheme.red)
        .background(SparkVTheme.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Settings

    private var settings: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Watch the Downloads folder", isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text(watchStatus)
                    .font(.caption)
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
                if controller.status == .denied {
                    HStack(spacing: 8) {
                        Button("Open Privacy Settings") { controller.openPrivacySettings() }
                            .buttonStyle(SparkVPrimaryButtonStyle())
                        Button("Try Again") { controller.retry() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    }
                    .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show progress under the notch", isOn: $controller.showsActivity)
                    .controlSize(.small)
                Toggle("Suggest folders with Apple Intelligence", isOn: $controller.suggestsWithAI)
                    .controlSize(.small)
                Text(DownloadsAI.unavailableReason.map { "Not available: \($0). Rules still work." }
                     ?? "Runs on this Mac. Only the file name, kind, size and website are used.")
                    .font(.caption)
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var watchStatus: String {
        switch controller.status {
        case .off: "Off. SparkV doesn't open Downloads until you turn this on."
        case .starting: "Starting… allow access if macOS asks."
        case .running: "Watching \(controller.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        case .denied: "macOS blocked access: allow SparkV under Files & Folders."
        case .failed(let reason): reason
        }
    }

    // MARK: Rule list

    private var ruleList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rules.rules) { rule in
                        ruleRow(rule)
                    }
                }
                .padding(8)
            }
            Divider().overlay(SparkVTheme.stroke)
            HStack(spacing: 4) {
                Button { model.selection = rules.addRule(after: model.selection).id } label: { Image(systemName: "plus") }
                    .help("Add a rule")
                Button {
                    guard let id = model.selection else { return }
                    let index = rules.rules.firstIndex { $0.id == id } ?? 0
                    rules.remove(id)
                    model.selection = rules.rules.indices.contains(index) ? rules.rules[index].id : rules.rules.last?.id
                } label: { Image(systemName: "minus") }
                    .disabled(model.selection == nil)
                    .help("Delete the rule")
                Button { if let id = model.selection { model.selection = rules.duplicate(id)?.id } } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(model.selection == nil)
                    .help("Duplicate")
                Button { if let id = model.selection { rules.move(id, by: -1) } } label: { Image(systemName: "arrow.up") }
                    .disabled(model.selection == nil || rules.rules.first?.id == model.selection)
                    .help("Move up (rules run top to bottom; the first match wins)")
                Button { if let id = model.selection { rules.move(id, by: 1) } } label: { Image(systemName: "arrow.down") }
                    .disabled(model.selection == nil || rules.rules.last?.id == model.selection)
                    .help("Move down")
                Spacer()
                Menu {
                    Button("Reset to Default Rules") {
                        rules.resetToDefaults()
                        model.selection = rules.rules.first?.id
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func ruleRow(_ rule: DownloadRule) -> some View {
        let selected = model.selection == rule.id
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { on in if let index = rules.rules.firstIndex(where: { $0.id == rule.id }) { rules.rules[index].isEnabled = on } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .accessibilityLabel(rule.name.isEmpty ? "Untitled rule" : rule.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(rule.isEnabled ? SparkVTheme.text : SparkVTheme.textTertiary)
                    .lineLimit(1)
                Text(rule.destination.displayPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if rule.sortsAutomatically {
                Text("Auto")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(SparkVTheme.red))
                    .help("Moves matching downloads automatically")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(selected ? SparkVTheme.redSoft : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(selected && !SparkVTheme.isApple ? SparkVTheme.red.opacity(0.45) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = rule.id }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selection = rule.id }
    }

    // MARK: Editor

    private func binding(for id: UUID) -> Binding<DownloadRule>? {
        guard rules.rules.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { rules.rules.first { $0.id == id } ?? DownloadRule(name: "", conditions: [], destination: .space) },
            set: { value in if let index = rules.rules.firstIndex(where: { $0.id == id }) { rules.rules[index] = value } }
        )
    }

    @ViewBuilder
    private var editor: some View {
        if let id = model.selection, let rule = binding(for: id) {
            ScrollView {
                DownloadsRuleEditor(rule: rule, controller: controller)
                    .padding(18)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundStyle(SparkVTheme.textSecondary)
                Text("Select a rule, or add one with +").foregroundStyle(SparkVTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One rule: name, conditions (all/any), destination, auto-sort, preview.
struct DownloadsRuleEditor: View {
    @Binding var rule: DownloadRule
    @ObservedObject var controller: DownloadsController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Name").font(SparkVTheme.headline(12)).frame(width: 60, alignment: .leading)
                TextField("Rule name", text: $rule.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("If")
                    Picker("", selection: $rule.matchAll) {
                        Text("all").tag(true)
                        Text("any").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("If")
                    Text("of these conditions are met:")
                }
                ForEach($rule.conditions) { $condition in
                    conditionRow($condition)
                }
                Button {
                    rule.conditions.append(DownloadCondition(field: .fileExtension, op: .is, value: ""))
                } label: {
                    Label("Add Condition", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Then")
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { rule.destination == .space ? 1 : 0 },
                        set: { rule.destination = $0 == 1 ? .space : .folder(lastFolder) }
                    )) {
                        Text("Move to folder").tag(0)
                        Text("Send to a Space").tag(1)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Then")
                    if case .folder = rule.destination {
                        TextField("~/Downloads/Folder", text: Binding(
                            get: { if case .folder(let path) = rule.destination { path } else { "" } },
                            set: { rule.destination = .folder($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseFolder() }
                            .buttonStyle(SparkVSecondaryButtonStyle())
                    } else {
                        Text("SparkV's Spaces agents pick the Space.")
                            .font(.callout)
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                }
                if case .folder = rule.destination, rule.destination.folderURL() == nil {
                    Text("Use a full path or one starting with ~/")
                        .font(.caption)
                        .foregroundStyle(SparkVTheme.warning)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Sort automatically when a download finishes", isOn: $rule.sortsAutomatically)
                Text(rule.sortsAutomatically
                     ? "Matching downloads move as soon as they finish. Undo in the drawer puts them back."
                     : "Off: SparkV only suggests this folder; nothing moves until you click Sort.")
                    .font(.caption)
                    .foregroundStyle(SparkVTheme.textSecondary)
            }

            preview
        }
    }

    private var lastFolder: String {
        if case .folder(let path) = rule.destination { return path }
        return "~/Downloads"
    }

    private func conditionRow(_ condition: Binding<DownloadCondition>) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { condition.wrappedValue.field },
                set: { field in
                    var value = condition.wrappedValue
                    value.field = field
                    value.normalize()
                    condition.wrappedValue = value
                }
            )) {
                ForEach(DownloadCondition.Field.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            .accessibilityLabel("Field")
            Picker("", selection: condition.op) {
                ForEach(condition.wrappedValue.field.operators) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel("Operator")
            switch condition.wrappedValue.field {
            case .kind:
                Picker("", selection: condition.value) {
                    ForEach(DownloadCategory.allCases) { Text($0.singular).tag($0.rawValue) }
                }
                .labelsHidden()
                .accessibilityLabel("Value")
            case .browser:
                Picker("", selection: condition.value) {
                    ForEach(DownloadBrowser.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                }
                .labelsHidden()
                .accessibilityLabel("Category")
            default:
                TextField(condition.wrappedValue.field.hint, text: condition.value)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                rule.conditions.removeAll { $0.id == condition.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove condition")
            .accessibilityLabel("Remove condition")
        }
    }

    private var preview: some View {
        let finished = controller.items.filter { !$0.isActive }
        let matching = finished.filter { DownloadRuleEngine.matches(rule, DownloadRuleSubject(item: $0)) }
        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(finished.isEmpty
                 ? "No recent downloads to test against yet."
                 : "Matches \(matching.count) of \(finished.count) recent downloads\(matching.isEmpty ? "" : ":")")
                .font(.callout)
                .foregroundStyle(SparkVTheme.textSecondary)
            ForEach(matching.prefix(5)) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.category.symbol).foregroundStyle(SparkVTheme.textSecondary)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let domain = item.sourceDomain {
                        Text(domain).foregroundStyle(SparkVTheme.textSecondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = rule.destination.folderURL() ?? controller.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rule.destination = .folder(url: url)
    }
}
