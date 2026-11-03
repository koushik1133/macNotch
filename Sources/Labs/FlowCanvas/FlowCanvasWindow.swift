import AppKit
import SwiftUI

// The Flow Canvas window. SparkV is an agent app (LSUIElement), so the window
// switches the app to a regular activation policy while it's open (Dock icon,
// key focus) and back to accessory when it closes, like Meeting Notes.
// Without a main menu, the window's event monitor provides the canvas
// shortcuts and the text-editing ones (⌘C/V/X/A/Z) for its text fields.

@MainActor
final class FlowCanvasWindowController: NSObject, NSWindowDelegate {
    static let shared = FlowCanvasWindowController()

    /// The notch sets this so "Send to Tray" can hand files to the Tray.
    var onSendToTray: (([URL]) -> Void)? {
        didSet { editorIfLoaded?.onSendToTray = onSendToTray }
    }

    /// Optional: "Add to Spaces" (title, Markdown, source URL).
    var onSendToSpace: ((_ title: String, _ markdown: String, _ url: URL?) -> Void)? {
        didSet { editorIfLoaded?.onSendToSpace = onSendToSpace }
    }

    private var window: NSWindow?
    private var monitor: Any?
    private var editorIfLoaded: FCEditor?

    var editor: FCEditor {
        if let editorIfLoaded { return editorIfLoaded }
        let editor = FCEditor()
        editor.onSendToTray = onSendToTray
        editor.onSendToSpace = onSendToSpace
        editorIfLoaded = editor
        return editor
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        editor.window = window
        installMonitor()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the window and adds the items as cards on the current canvas.
    func show(adding inputs: [FlowCanvasInput]) {
        show()
        guard !inputs.isEmpty else { return }
        editor.add(inputs)
    }

    private func makeWindow() -> NSWindow {
        let root = FCRootView(editor: editor, library: editor.library, settings: FCSettingsModel.shared)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Flow Canvas — SparkV"
        LabsBrand.styleWindow(window)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1320, height: 840))
        window.center()
        window.setFrameAutosaveName("SparkV.FlowCanvas")
        window.tabbingMode = .disallowed
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        editorIfLoaded?.saveNow()
        removeMonitor()
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidResignKey(_ notification: Notification) {
        editorIfLoaded?.spaceHeld = false
    }

    // MARK: Events

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .magnify]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the event was used by the canvas.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        let editor = self.editor
        switch event.type {
        case .scrollWheel: return handleScroll(event, editor: editor)
        case .magnify:
            guard let point = canvasPoint(event, editor: editor), editor.fullscreenNodeID == nil else { return false }
            editor.zoom(by: 1 + event.magnification, around: point)
            return true
        case .keyDown:
            return FCKeyHandler.handle(event, editor: editor, window: window)
        case .keyUp:
            if event.keyCode == FCKeyHandler.space { editor.spaceHeld = false }
            return false
        default:
            return false
        }
    }

    /// The pointer in canvas coordinates, when it's over the canvas.
    private func canvasPoint(_ event: NSEvent, editor: FCEditor) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let local = content.convert(event.locationInWindow, from: nil)
        let flipped = content.isFlipped ? local : CGPoint(x: local.x, y: content.bounds.height - local.y)
        let frame = editor.canvasFrameInWindow
        guard frame.contains(flipped) else { return nil }
        return CGPoint(x: flipped.x - frame.minX, y: flipped.y - frame.minY)
    }

    private func handleScroll(_ event: NSEvent, editor: FCEditor) -> Bool {
        guard editor.fullscreenNodeID == nil, let point = canvasPoint(event, editor: editor) else { return false }
        // Let text editors and other scroll views on the canvas scroll themselves.
        if let content = window?.contentView, let hit = content.superview?.hitTest(event.locationInWindow) ?? content.hitTest(event.locationInWindow) {
            var view: NSView? = hit
            while let current = view, current !== content {
                if current is NSScrollView { return false }
                view = current.superview
            }
        }
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            editor.zoom(by: exp(delta * 0.01), around: point)
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            var dx = event.scrollingDeltaX * scale, dy = event.scrollingDeltaY * scale
            if event.modifierFlags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
            editor.pan(by: CGSize(width: dx, height: dy))
        }
        return true
    }
}

// MARK: - Keys

@MainActor
enum FCKeyHandler {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76

    /// True when the event was used.
    static func handle(_ event: NSEvent, editor: FCEditor, window: NSWindow) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // A text field or editor has focus: only editing shortcuts (there is
        // no Edit menu in an agent app) and Escape to stop editing.
        if window.firstResponder is NSText || window.firstResponder is NSTextView {
            if event.keyCode == escape {
                window.makeFirstResponder(nil)
                editor.editingNoteID = nil
                return true
            }
            guard command else { return false }
            let action: Selector? = switch key {
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": shift ? Selector(("redo:")) : Selector(("undo:"))
            default: nil
            }
            if let action { return NSApp.sendAction(action, to: nil, from: nil) }
            if key == "w" { window.performClose(nil); return true }
            return false
        }

        if command {
            switch key {
            case "z":
                if shift { editor.redo() } else { editor.undo() }
            case "0": editor.fitAll()
            case "=", "+": editor.zoom(by: 1.25)
            case "-": editor.zoom(by: 0.8)
            case "v": editor.paste()
            case "c": if let node = editor.primarySelection { editor.copyOutput(node.id) } else { return false }
            case "a": editor.selectAll()
            case "d": editor.duplicateSelection()
            case "w": window.performClose(nil)
            case "n": editor.newCanvas()
            default:
                if event.keyCode == returnKey || event.keyCode == enter { editor.runAll() } else { return false }
            }
            return true
        }
        guard !flags.contains(.option), !flags.contains(.control) else { return false }

        switch event.keyCode {
        case space:
            if !event.isARepeat { editor.spaceHeld = true }
            return true
        case delete, forwardDelete:
            editor.deleteSelection()
            return true
        case escape:
            if editor.fullscreenNodeID != nil { editor.fullscreenNodeID = nil }
            else if editor.ghost != nil { editor.discardPlan() }
            else if editor.pendingEdge != nil { editor.pendingEdge = nil }
            else if editor.tool != .select { editor.tool = .select }
            else { editor.selection = []; editor.selectedEdge = nil }
            return true
        case returnKey, enter:
            if editor.ghost != nil { editor.acceptPlan() } else { editor.runSelected() }
            return true
        default:
            break
        }
        switch key {
        case "d": editor.deleteSelection()
        case "f": editor.toggleFullscreen()
        case "z": editor.zoomToSelection()
        case "v": editor.tool = .select
        case "h": editor.tool = .hand
        case "c": editor.tool = editor.tool == .connect ? .select : .connect
        case "r": editor.addFrame()
        case "n": editor.addNote(edit: true)
        case "i": editor.inspectorVisible.toggle()
        default: return false
        }
        return true
    }
}

// MARK: - Root view

struct FCRootView: View {
    @ObservedObject var editor: FCEditor
    @ObservedObject var library: FCLibrary
    @ObservedObject var settings: FCSettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = FCPalette(scheme: scheme)
        HStack(spacing: 0) {
            if editor.sidebarVisible {
                FCSidebar(editor: editor, library: library, palette: palette)
                Divider()
            }
            FCCanvasArea(editor: editor, settings: settings, palette: palette)
            if editor.inspectorVisible && (editor.primarySelection != nil || editor.selectedEdge != nil || editor.selection.count > 1) {
                Divider()
                FCInspector(editor: editor)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .labsWindowRoot()
    }
}

/// Canvas plus its floating chrome.
struct FCCanvasArea: View {
    @ObservedObject var editor: FCEditor
    @ObservedObject var settings: FCSettingsModel
    let palette: FCPalette

    var body: some View {
        ZStack {
            FCCanvasView(editor: editor)
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    if !editor.sidebarVisible {
                        chromeButton("sidebar.left", help: "Show sidebar") { editor.sidebarVisible = true }
                    }
                    Spacer(minLength: 12)
                    FCPromptBar(editor: editor, palette: palette)
                    Spacer(minLength: 12)
                    FCEngineMenu(editor: editor, settings: settings, palette: palette)
                    if !editor.inspectorVisible {
                        chromeButton("sidebar.right", help: "Show inspector (I)") { editor.inspectorVisible = true }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                if let message = editor.flashMessage {
                    FCToast(message: message, palette: palette)
                }
                Spacer()
                FCToolbar(editor: editor, palette: palette)
                    .padding(.bottom, 16)
            }
            if let id = editor.fullscreenNodeID {
                FCFullscreenView(editor: editor, nodeID: id)
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: editor.flashMessage)
    }

    private func chromeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(palette.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.chrome))
                .overlay(Circle().strokeBorder(palette.border))
        }
        .buttonStyle(SparkVPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Sidebar

struct FCSidebar: View {
    @ObservedObject var editor: FCEditor
    @ObservedObject var library: FCLibrary
    let palette: FCPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Flow Canvas", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(SparkVTheme.headline(14))
                    .tracking(-0.2)
                    .foregroundStyle(palette.text)
                Spacer()
                Menu {
                    Button("Blank canvas") { editor.newCanvas() }
                    Divider()
                    ForEach(FCTemplates.builtIn + library.userTemplates) { template in
                        Button(template.name) { editor.newCanvas(from: template) }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New canvas")
                .accessibilityLabel("New canvas")
                Button {
                    editor.sidebarVisible = false
                } label: {
                    Image(systemName: "sidebar.left").foregroundStyle(palette.secondary)
                }
                .buttonStyle(SparkVPressStyle())
                .help("Hide sidebar")
                .accessibilityLabel("Hide sidebar")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header("Canvases")
                    ForEach(library.canvases) { summary in
                        canvasRow(summary)
                    }
                    header("Templates").padding(.top, 10)
                    ForEach(FCTemplates.builtIn + library.userTemplates) { template in
                        templateRow(template)
                    }
                    Button {
                        editor.promptSaveAsTemplate()
                    } label: {
                        Label("Save this canvas as a template…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(SparkVPressStyle())
                }
                .padding(8)
            }
        }
        .frame(width: 236)
        .background(palette.card)
    }

    private func header(_ title: String) -> some View {
        LabsEyebrow(title, color: palette.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func canvasRow(_ summary: FCCanvasSummary) -> some View {
        let isCurrent = summary.id == editor.document.id
        let name = isCurrent ? editor.document.name : summary.name
        if editor.renamingCanvasID == summary.id {
            TextField("Name", text: $editor.renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { editor.renameCanvas(summary.id, to: editor.renameDraft) }
                .padding(.horizontal, 6)
        } else {
            Button {
                editor.openCanvas(summary.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular)).foregroundStyle(palette.text).lineLimit(1)
                    Text("\(summary.nodeCount) card\(summary.nodeCount == 1 ? "" : "s") · \(summary.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(isCurrent ? LabsTint.selectionFill : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(SparkVPressStyle())
            .contextMenu {
                Button("Rename") {
                    editor.renameDraft = name
                    editor.renamingCanvasID = summary.id
                }
                Button("Duplicate") { editor.duplicateCanvas(summary.id) }
                Divider()
                Button("Delete…") { editor.confirmDeleteCanvas(summary.id) }
            }
        }
    }

    private func templateRow(_ template: FCTemplate) -> some View {
        Button {
            editor.newCanvas(from: template)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: template.symbol).font(.system(size: 12)).foregroundStyle(palette.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name).font(.system(size: 12)).foregroundStyle(palette.text).lineLimit(1)
                    Text(template.summary).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .contextMenu {
            if !template.isBuiltIn {
                Button("Delete template") { library.deleteTemplate(template.id) }
            }
        }
    }
}

// MARK: - Notch integration

/// Header icon for the notch drawer: opens the Flow Canvas window.
struct FlowCanvasNotchButton: View {
    var help = "Flow Canvas"
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            FlowCanvasWindowController.shared.show()
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover.isOn ? SparkVTheme.activeGlyph : SparkVTheme.inactiveGlyph)
                .frame(width: 26, height: 22)
                .background(Capsule().fill(hover.isOn ? SparkVTheme.choose(apple: SparkVTheme.hoverFill, sparkv: SparkVTheme.accentSoft) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
        .accessibilityLabel(help)
    }
}
