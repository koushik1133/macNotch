import AppKit
import SwiftUI

/// The flow editor window. SparkV is an agent app, so while it is open
/// the app becomes `.regular` (Dock icon, key window, text input), the same
/// way the Tray AI panel does it. Closing it goes back to `.accessory` unless
/// another real window is still open.
@MainActor
final class BrowserRecorderWindowController: NSObject, NSWindowDelegate {
    static let shared = BrowserRecorderWindowController()

    private var window: NSWindow?
    private var keyMonitor: Any?

    var isOpen: Bool { window?.isVisible ?? false }

    func show(controller: BrowserRecorderController) {
        let window = window ?? makeWindow(controller: controller)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        AppLog.log("BrowserRecorder: window open")
    }

    func close() {
        window?.performClose(nil)
    }

    private func makeWindow(controller: BrowserRecorderController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser Flows"
        window.titlebarAppearsTransparent = true
        LabsBrand.styleWindow(window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 520)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserRecorderWindowView(controller: controller))
        window.setFrameAutosaveName("SparkV.BrowserRecorder")
        if !window.setFrameUsingName("SparkV.BrowserRecorder") { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        let closing = notification.object as? NSWindow
        let stillOpen = NSApp.windows.contains { $0 !== closing && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        AppLog.log("BrowserRecorder: window closed")
    }

    // Cmd-C/V/X/A/Z and Cmd-W: the agent app has no Edit menu to supply them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = BRKeyPress(
                windowNumber: event.windowNumber,
                flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                characters: event.charactersIgnoringModifiers?.lowercased() ?? ""
            )
            let consumed = MainActor.assumeIsolated { self?.handleKey(key) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ key: BRKeyPress) -> Bool {
        guard let window, window.isVisible, key.windowNumber == window.windowNumber else { return false }
        let flags = key.flags
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let selector: Selector
        switch key.characters {
        case "c": selector = #selector(NSText.copy(_:))
        case "v": selector = #selector(NSText.paste(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "w":
            window.performClose(nil)
            return true
        default:
            return false
        }
        return NSApp.sendAction(selector, to: nil, from: window)
    }
}

private struct BRKeyPress: Sendable {
    let windowNumber: Int
    let flags: NSEvent.ModifierFlags
    let characters: String
}

/// UserDefaults-backed toggles (no @AppStorage/@State dependency).
@MainActor
final class BRSettings: ObservableObject {
    @Published var useChrome: Bool {
        didSet { UserDefaults.standard.set(useChrome, forKey: BrowserRecorderController.useChromeKey) }
    }
    @Published var autoApplyHealing: Bool {
        didSet { UserDefaults.standard.set(autoApplyHealing, forKey: BrowserRecorderController.autoApplyHealingKey) }
    }

    init() {
        useChrome = UserDefaults.standard.bool(forKey: BrowserRecorderController.useChromeKey)
        autoApplyHealing = UserDefaults.standard.object(forKey: BrowserRecorderController.autoApplyHealingKey) as? Bool ?? true
    }
}

// MARK: - Root view

struct BrowserRecorderWindowView: View {
    @ObservedObject var controller: BrowserRecorderController
    @StateObject private var settings = BRSettings()

    var body: some View {
        HStack(spacing: 0) {
            BRSidebar(controller: controller, settings: settings)
                .frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                BRDetailHeader(controller: controller)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BRMessageBar(controller: controller)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .labsWindowRoot()
        .sheet(item: $controller.pendingRun) { run in
            BRVariablesSheet(run: run, controller: controller)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if controller.phase == .recording {
            BRLiveRecordingView(steps: controller.liveSteps)
        } else if let flow = controller.selectedFlow {
            switch controller.detailMode {
            case .steps:
                BRStepList(controller: controller, flow: flow)
            case .graph:
                BrowserRecorderGraphView(flow: flow, statuses: controller.progress?.flowID == flow.id ? controller.progress?.statuses ?? [:] : [:])
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34))
                    .foregroundStyle(SparkVTheme.textTertiary)
                Text("Record a browser task to make your first flow.")
                    .foregroundStyle(SparkVTheme.textSecondary)
                Text("A Chromium window opens with its own profile, so sign-ins stay for next time. Password fields are never recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
    }
}

// MARK: - Sidebar

private struct BRSidebar: View {
    @ObservedObject var controller: BrowserRecorderController
    @ObservedObject var settings: BRSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Flows")
                    .font(SparkVTheme.title(17))
                    .tracking(-0.3)
                Spacer()
                Text("\(controller.flows.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 6)

            List(selection: $controller.selectedFlowID) {
                ForEach(controller.flows) { flow in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flow.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(BRTemplate.stepCount(flow.steps.count))
                            if !flow.variables.isEmpty { Text("· \(flow.variables.count) vars") }
                            if !flow.riskyWords.isEmpty {
                                Image(systemName: "exclamationmark.shield").foregroundStyle(SparkVTheme.warning)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(flow.id)
                    .contextMenu {
                        Button("Replay") { controller.replay(flowID: flow.id) }.disabled(controller.isBusy)
                        Button("Replay with Data…") { controller.replayWithData(flowID: flow.id) }.disabled(controller.isBusy)
                        Divider()
                        Button("Duplicate") { controller.duplicateFlow(flow.id) }
                        Button("Export…") { controller.exportFlow(flow.id) }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { controller.confirmDeleteFlow(flow.id) }
                            .disabled(controller.isBusy && controller.progress?.flowID == flow.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Apply self-healed selectors", isOn: $settings.autoApplyHealing)
                Toggle("Use installed Google Chrome", isOn: $settings.useChrome)
                HStack {
                    Button("Check Runtime") { controller.checkRuntime() }
                        .disabled(controller.isBusy || !controller.runtimeAvailable)
                    Spacer()
                    Button {
                        controller.importFlows()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Import flow files (.json)")
                    .accessibilityLabel("Import flow files (.json)")
                    Button {
                        NSWorkspace.shared.open(BrowserFlowStore.defaultDirectory)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show the Flows folder")
                    .accessibilityLabel("Show the Flows folder")
                }
                Text(controller.runtimeStatus)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .padding(12)
        }
        .background(Color.white.opacity(0.02))
    }
}

// MARK: - Header (Record / Stop / Replay / Replay with data)

private struct BRDetailHeader: View {
    @ObservedObject var controller: BrowserRecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("Start page for a new recording (optional), e.g. example.com", text: $controller.recordStartURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .disabled(controller.isBusy)
                    .onSubmit { controller.startRecording() }
                recordButton
                Spacer()
                if controller.phase == .replaying {
                    Button(role: .cancel) { controller.cancelReplay() } label: {
                        Label("Stop Replay", systemImage: "stop.fill")
                    }
                    .buttonStyle(LabsSecondaryButtonStyle())
                }
            }

            if let flow = controller.selectedFlow, controller.phase != .recording {
                HStack(spacing: 8) {
                    TextField("Flow name", text: Binding(
                        get: { flow.name },
                        set: { controller.renameFlow(flow.id, to: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: 380)

                    Spacer()

                    Picker("", selection: $controller.detailMode) {
                        Text("Steps").tag(BrowserRecorderController.DetailMode.steps)
                        Text("Graph").tag(BrowserRecorderController.DetailMode.graph)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel("Detail")

                    BRAddStepMenu(controller: controller, flowID: flow.id, afterStepID: nil)

                    Button {
                        controller.replayWithData(flowID: flow.id)
                    } label: {
                        Label("Replay with Data…", systemImage: "tablecells")
                    }
                    .buttonStyle(LabsSecondaryButtonStyle())
                    .disabled(controller.isBusy || flow.steps.isEmpty)
                    .help("Run once per CSV row; columns fill {{variables}}")

                    Button {
                        controller.replay(flowID: flow.id)
                    } label: {
                        Label("Replay", systemImage: "play.fill")
                    }
                    .buttonStyle(LabsPrimaryButtonStyle())
                    .disabled(controller.isBusy || flow.steps.isEmpty)
                }
                if let progress = controller.progress, progress.flowID == flow.id, controller.phase == .replaying || progress.finished {
                    BRProgressRow(progress: progress, isRunning: controller.phase == .replaying) {
                        controller.revealScreenshot()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var recordButton: some View {
        if controller.phase == .recording {
            Button { controller.stopRecording() } label: {
                Label("Stop Recording", systemImage: "stop.fill")
            }
            .buttonStyle(LabsSecondaryButtonStyle())
        } else {
            Button { controller.startRecording() } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(LabsPrimaryButtonStyle())
            .disabled(controller.isBusy || !controller.runtimeAvailable)
        }
    }
}

private struct BRProgressRow: View {
    let progress: BRReplayProgress
    let isRunning: Bool
    let revealScreenshot: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(progress.finished ? (progress.ok ? SparkVTheme.success : SparkVTheme.warning) : SparkVTheme.accent)
                .frame(width: 180)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if progress.healedCount > 0 {
                Label("\(progress.healedCount) self-healed", systemImage: "bandage")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.warning)
            }
            Spacer()
            if progress.failureScreenshot != nil {
                Button("Show Failure Screenshot", action: revealScreenshot)
                    .controlSize(.small)
            }
        }
    }

    private var statusText: String {
        let rows = progress.rows > 1 ? "Row \(progress.row + 1)/\(progress.rows) · " : ""
        if progress.finished { return rows + (progress.ok ? "Finished" : (progress.lastMessage ?? "Stopped")) }
        let step = progress.currentIndex.map { "Step \($0 + 1)" } ?? "Starting"
        return "\(rows)\(step): \(progress.lastMessage ?? progress.currentTitle)"
    }
}

// MARK: - Step list editor

private struct BRStepList: View {
    @ObservedObject var controller: BrowserRecorderController
    let flow: BRFlow

    var body: some View {
        if flow.steps.isEmpty {
            Text("No steps. Use “Add Step” to add one.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(flow.steps.enumerated()), id: \.element.id) { offset, step in
                    BRStepRow(
                        controller: controller,
                        flowID: flow.id,
                        step: step,
                        index: offset,
                        count: flow.steps.count,
                        status: controller.progress?.flowID == flow.id ? controller.progress?.statuses[step.id] : nil
                    )
                }
                .onMove { source, destination in
                    controller.moveSteps(flowID: flow.id, from: source, to: destination)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct BRStepRow: View {
    @ObservedObject var controller: BrowserRecorderController
    let flowID: String
    let step: BRStep
    let index: Int
    let count: Int
    let status: BRStepStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(SparkVTheme.surfaceHover)
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .strokeBorder(SparkVTheme.stroke)
                Image(systemName: step.kind?.symbol ?? "questionmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(step.isDisabled ? SparkVTheme.textTertiary : SparkVTheme.text)
            }
            .frame(width: 26, height: 26)
            .overlay(alignment: .topTrailing) {
                if let status, let symbol = status.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(status == .failed || status == .running ? Color.white : Color.black)
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(status.color))
                        .offset(x: 5, y: -5)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    TextField("Step name", text: binding(\.title, default: step.displayTitle))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                    Text(step.kind?.label ?? step.type)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SparkVTheme.surface))
                        .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                        .foregroundStyle(.secondary)
                    if step.masked == true {
                        Label("masked", systemImage: "lock.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(SparkVTheme.warning)
                    }
                }
                valueEditor
                if let selectors = step.selectors, !selectors.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(selectors.enumerated()), id: \.offset) { i, selector in
                                Text("\(i + 1). \(selector.kind): \(selector.summary)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            if step.fingerprint != nil {
                                Text("+ element fingerprint for fuzzy matching")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } label: {
                        Text("\(selectors.count) selector candidates")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Toggle("", isOn: Binding(
                    get: { !step.isDisabled },
                    set: { on in controller.updateStep(flowID: flowID, stepID: step.id) { $0.disabled = on ? nil : true } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(step.isDisabled ? "Skipped during replay" : "Runs during replay")
                .accessibilityLabel("Run this step during replay")
                Button { controller.moveStep(flowID: flowID, stepID: step.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("Move step up")
                Button { controller.moveStep(flowID: flowID, stepID: step.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
                    .accessibilityLabel("Move step down")
                BRAddStepMenu(controller: controller, flowID: flowID, afterStepID: step.id, compact: true, template: step)
                Button(role: .destructive) { controller.deleteStep(flowID: flowID, stepID: step.id) } label: { Image(systemName: "trash") }
                    .help("Delete step")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(SparkVTheme.textSecondary)
        }
        .padding(.vertical, 4)
        .opacity(step.isDisabled ? 0.55 : 1)
        .contextMenu {
            Button("Replay from Here") { controller.replay(flowID: flowID, fromStepID: step.id) }
                .disabled(controller.isBusy || step.isDisabled)
            Button(step.isDisabled ? "Enable Step" : "Skip Step") {
                controller.updateStep(flowID: flowID, stepID: step.id) { $0.disabled = step.isDisabled ? nil : true }
            }
            Divider()
            Button("Delete Step", role: .destructive) { controller.deleteStep(flowID: flowID, stepID: step.id) }
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch step.kind {
        case .navigate:
            field("URL", binding(\.url, default: ""))
        case .fill:
            HStack(spacing: 6) {
                if step.masked == true {
                    field("Variable", binding(\.value, default: "{{password}}"))
                    Text("Asked at replay; never saved.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    field("Text to type, or {{variable}}", binding(\.value, default: ""))
                    if BRTemplate.names(in: step.value ?? "").isEmpty {
                        Button("Make Variable") { controller.makeVariable(flowID: flowID, stepID: step.id) }
                            .controlSize(.small)
                    }
                }
            }
        case .upload:
            field("File path(s), | separated, or {{file}}", binding(\.value, default: ""))
        case .press:
            field("Key (Enter, Tab, Escape, Control+A…)", binding(\.key, default: "Enter"))
        case .delay:
            HStack(spacing: 6) {
                Text("Seconds").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("1.0", value: Binding(
                    get: { (step.ms ?? 1000) / 1000 },
                    set: { seconds in controller.updateStep(flowID: flowID, stepID: step.id) { $0.ms = max(0, min(120, seconds)) * 1000 } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                Text("max 120 s").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        case .waitText:
            field("Text that must appear", binding(\.value, default: ""))
        case .waitURL:
            field("URL must contain", binding(\.value, default: ""))
        case .comment:
            field("Note", binding(\.value, default: ""))
        case .select:
            Text("Option: \(step.detail)").font(.system(size: 10)).foregroundStyle(.secondary)
        default:
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func field(_ placeholder: String, _ binding: Binding<String>) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .frame(maxWidth: 420)
    }

    private func binding(_ keyPath: WritableKeyPath<BRStep, String?>, default fallback: String) -> Binding<String> {
        let id = step.id
        let flowID = flowID
        let controller = controller
        return Binding(
            get: { step[keyPath: keyPath] ?? fallback },
            set: { newValue in controller.updateStep(flowID: flowID, stepID: id) { $0[keyPath: keyPath] = newValue } }
        )
    }
}

/// "Add Step" menu: Delay, Wait for element / text / URL, Open page, Press, Note.
private struct BRAddStepMenu: View {
    @ObservedObject var controller: BrowserRecorderController
    let flowID: String
    let afterStepID: String?
    var compact = false
    /// Step whose element "Wait for this element" targets.
    var template: BRStep? = nil

    var body: some View {
        Menu {
            Button("Delay 1 s") { add(.delay(seconds: 1)) }
            Button("Delay 3 s") { add(.delay(seconds: 3)) }
            Divider()
            if let template, template.selectors?.isEmpty == false {
                Button("Wait for This Element") { add(.waitFor(targetOf: template)) }
            }
            Button("Wait for Text…") { add(.waitText("Done")) }
            Button("Wait for URL…") { add(.waitURL("/")) }
            Divider()
            Button("Open Page") {
                var step = BRStep(type: .navigate, title: "Open page")
                step.url = "https://"
                step.pageIndex = 0
                add(step)
            }
            Button("Press Enter") {
                var step = BRStep(type: .press, title: "Press Enter")
                step.key = "Enter"
                step.selectors = []
                add(step)
            }
            Button("Note") {
                var step = BRStep(type: .comment, title: "Note")
                step.value = ""
                add(step)
            }
        } label: {
            if compact {
                Image(systemName: "plus")
            } else {
                Label("Add Step", systemImage: "plus")
            }
        }
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .help("Add a step after this one")
    }

    private func add(_ step: BRStep) {
        controller.insertStep(step, flowID: flowID, after: afterStepID)
    }
}

// MARK: - Live recording

private struct BRLiveRecordingView: View {
    let steps: [BRStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SparkVStatusDot(kind: .recording, color: SparkVTheme.recording, size: 9, label: "")
                Text("Recording in the Chromium window")
                    .font(.system(size: 13, weight: .semibold))
                Text("Use the overlay's “Wait for element” to add waits. Passwords are masked.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { offset, step in
                        HStack(spacing: 10) {
                            Text("\(offset + 1)")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            Image(systemName: step.kind?.symbol ?? "questionmark")
                                .foregroundStyle(step.kind?.group.color ?? .gray)
                                .frame(width: 18)
                            Text(step.displayTitle).font(.system(size: 12))
                            Text(step.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .id(step.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: steps.count) { _, _ in
                    // Following the live log is on-screen movement: strong
                    // ease-in-out, under 300 ms; Reduce Motion jumps.
                    if let last = steps.last {
                        if SparkVMotion.reduceMotion {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        } else {
                            withAnimation(SparkVMotion.easeInOut()) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }

                }
            }
        }
    }
}

// MARK: - Messages

private struct BRMessageBar: View {
    @ObservedObject var controller: BrowserRecorderController

    var body: some View {
        if let text = controller.lastError ?? controller.lastNotice {
            let isError = controller.lastError != nil
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(isError ? SparkVTheme.warning : SparkVTheme.textSecondary)
                Text(text)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer()
                Button { controller.clearMessages() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss messages")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(SparkVTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(SparkVTheme.stroke).frame(height: 1) }
        }
    }
}

// MARK: - Variables sheet

@MainActor
private final class BRVariablesModel: ObservableObject {
    @Published var values: [String: String]
    init(values: [String: String]) { self.values = values }
}

private struct BRVariablesSheet: View {
    let run: BRPendingRun
    let controller: BrowserRecorderController
    @StateObject private var model: BRVariablesModel

    init(run: BRPendingRun, controller: BrowserRecorderController) {
        self.run = run
        self.controller = controller
        _model = StateObject(wrappedValue: BRVariablesModel(values: run.values))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(run.csvURL == nil ? "Values for this replay" : "Replay with \(run.csvURL?.lastPathComponent ?? "CSV")")
                .font(.system(size: 15, weight: .semibold))
            if run.csvURL != nil {
                Text("\(run.csvRows) row\(run.csvRows == 1 ? "" : "s"), columns: \(run.csvColumns.joined(separator: ", ")). Each row is one replay.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(run.variables, id: \.self) { name in
                HStack {
                    Text("{{\(name)}}")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140, alignment: .leading)
                    if BRTemplate.isSecret(name) {
                        SecureField("Not saved", text: binding(name))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Value", text: binding(name))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Text("Secret values (passwords, tokens, card fields) are passed to the browser for this run only and never written to disk.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { controller.cancelPendingRun() }
                    .keyboardShortcut(.cancelAction)
                Button("Replay") {
                    var submitted = run
                    submitted.values = model.values
                    controller.submitPendingRun(submitted)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(LabsPrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 440)
        .labsWindowRoot()
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { self.model.values[name] ?? "" }, set: { self.model.values[name] = $0 })
    }
}
