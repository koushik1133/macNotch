import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Reply Drafter: on the hotkey (⌃⌥R), the Agents tile or the header button,
/// reads the frontmost conversation (Accessibility first, window capture +
/// Vision OCR as fallback), drafts a reply in the user's tone with the most
/// relevant Space as context, and writes it into the message box (plus an
/// empty email Subject). A floating bar next to the field offers Undo, Redo,
/// Regenerate, Shorter, Longer, More formal, More casual and Close.
///
/// It never presses Send or Return and never clicks a button in the other
/// app. Message text, screen content and keys are never logged.
@MainActor
final class ReplyDrafterController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case reading
        case drafting
        case revising(ReplyRevision)
        /// Undo / Redo / Insert writing into the other app.
        case writing
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .reading, .drafting, .revising, .writing: true
            default: false
            }
        }
    }

    // MARK: Published state (the bar and the drawer)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var kind: ReplyAppKind = .generic
    /// "Slack · #design · 6 messages".
    @Published private(set) var contextLine = ""
    @Published private(set) var draft: ReplyDraft?
    /// The draft shown is currently in the message box.
    @Published private(set) var isInField = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var notice: String?
    @Published private(set) var spaceName: String?
    @Published private(set) var readFromScreen = false
    @Published private(set) var needsAccessibility = false
    @Published private(set) var suggestsScreenRecording = false
    @Published private(set) var isBarVisible = false
    @Published private(set) var engineLabel = ""

    let settings: ReplyDrafterSettings

    // MARK: Private

    private let activities: ActivityCenter
    private lazy var bar = ReplyDrafterBarController(controller: self)
    private let hotkey = ScreenRegionHotkey()
    private var lastExternalApp: NSRunningApplication?
    private var targetPID: pid_t?
    private var fieldFrame: CGRect?
    private var windowFrame: CGRect?
    private var request: ReplyDraftRequest?
    private var editor: ReplyFieldEditor?
    /// Drafts shown but not in a field (no message box / auto-insert off).
    private var previews: [ReplyDraft] = []
    private var previewIndex = 0
    private var work: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false
    private static let activityID = "replyDrafter"

    init(activities: ActivityCenter, settings: ReplyDrafterSettings? = nil) {
        self.activities = activities
        self.settings = settings ?? ReplyDrafterSettings()
        engineLabel = makeEngine(readKey: false).engineLabel
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID { lastExternalApp = front }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.applicationActivated(app) }
        })
        hotkey.onPress = { [weak self] in self?.draftReply() }
        installHotkey()
        settings.$hotkeyEnabled.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.installHotkey() } }.store(in: &cancellables)
        settings.$shortcut.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.installHotkey() } }.store(in: &cancellables)
        settings.$allowGroq.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.engineLabel = self.makeEngine(readKey: false).engineLabel
                AppLog.log("Reply Drafter: Groq \(self.settings.allowGroq ? "allowed" : "not allowed")")
            }
        }.store(in: &cancellables)
        AppLog.log("Reply Drafter: started (hotkey \(settings.hotkeyEnabled ? settings.shortcut.displayString : "off"))")
    }

    func stop() {
        work?.cancel()
        work = nil
        hotkey.unregister()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        cancellables = []
        close()
        isStarted = false
    }

    /// Registers ⌃⌥R (or the user's shortcut) when enabled.
    func installHotkey() {
        hotkey.unregister()
        guard settings.hotkeyEnabled else { return }
        if !hotkey.register(settings.shortcut) {
            AppLog.log("Reply Drafter: shortcut \(settings.shortcut.displayString) is taken by another app")
        }
    }

    var shortcutLabel: String { settings.hotkeyEnabled ? settings.shortcut.displayString : "" }

    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    private func applicationActivated(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ownPID else { return }
        lastExternalApp = app
        // The user moved on to another app: the bar belongs to the old one.
        if isBarVisible, let targetPID, app.processIdentifier != targetPID, !phase.isBusy { close() }
    }

    // MARK: Entry point

    /// Hotkey, Agents tile, header button.
    func draftReply() {
        if phase.isBusy { return }
        work?.cancel()
        resetSession()
        guard let app = targetApplication() else {
            phase = .failed("Open a chat or an email first, then try again.")
            showBar()
            return
        }
        targetPID = app.processIdentifier
        guard PermissionCenter.shared.isGranted(.accessibility) else {
            needsAccessibility = true
            phase = .failed("Allow Accessibility for SparkV so it can read the conversation and write the reply.")
            showBar()
            return
        }
        phase = .reading
        contextLine = app.localizedName ?? "Reading…"
        showBar()
        postActivity("Reading the conversation…", working: true)
        work = Task { [weak self] in await self?.run(app) }
    }

    private func targetApplication() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID, front.activationPolicy == .regular {
            return front
        }
        if let last = lastExternalApp, !last.isTerminated { return last }
        return nil
    }

    private func run(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bundleID
        let started = Date()
        guard let live = await Task.detached(priority: .userInitiated, operation: {
            ReplyAXReader.capture(pid: pid, bundleID: bundleID, appName: name)
        }).value else {
            fail("Couldn't read this window. Click into the conversation and try again.")
            return
        }
        guard !Task.isCancelled else { return }
        let snapshot = live.snapshot
        let kind = ReplyContextDetector.detect(bundleID: bundleID, windowTitle: snapshot.windowTitle, url: snapshot.url)
        self.kind = kind
        windowFrame = snapshot.windowFrame
        let me = ReplyIdentity(fullName: settings.effectiveUserName, extraNames: [NSFullUserName()])
        var conversation = ReplyConversationReader.read(snapshot, kind: kind, me: me)

        var bodyField: ReplyAXField?
        var subjectField: ReplyAXField?
        if let index = conversation.composeIndex, index < live.elements.count {
            bodyField = ReplyAXField(element: live.elements[index], pid: pid, bundleID: bundleID, role: snapshot.nodes[index].role)
            fieldFrame = snapshot.nodes[index].frame
        }
        if let index = conversation.subjectIndex, index < live.elements.count {
            subjectField = ReplyAXField(element: live.elements[index], pid: pid, bundleID: bundleID, role: snapshot.nodes[index].role)
        }
        if let bodyField { editor = ReplyFieldEditor(body: bodyField, subject: subjectField, knownSignature: conversation.signature) }
        bar.reposition()

        // Apps that hide their text from Accessibility: read the window instead.
        if conversation.characterCount < 40, settings.readScreen {
            if ScreenRegionCapture.hasPermission {
                if let screen = await readScreen(pid: pid, axWindow: snapshot.windowFrame, kind: kind, title: snapshot.windowTitle, me: me),
                   screen.messages.count >= max(1, conversation.messages.count) {
                    conversation.messages = screen.messages
                    conversation.participants = screen.participants
                    if conversation.subject == nil { conversation.subject = screen.subject }
                    if conversation.title.isEmpty { conversation.title = screen.title }
                    conversation.source = .screen
                    readFromScreen = true
                }
            } else {
                suggestsScreenRecording = true
            }
        }
        guard !Task.isCancelled else { return }
        AppLog.log("Reply Drafter: \(kind.rawValue), \(conversation.messages.count) message(s) via \(conversation.source.rawValue), field \(conversation.composeIndex == nil ? "not found" : "found") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        guard !conversation.messages.isEmpty || !conversation.existingDraft.isEmpty else {
            fail(suggestsScreenRecording
                 ? "This app hides its text. Allow Screen Recording so SparkV can read the window, or type a few words of what to say in the message box."
                 : "Couldn't find a conversation here. Open a chat or an email, or type a few words of what to say in the message box, then try again.")
            return
        }
        contextLine = Self.contextLine(conversation)

        let tone = ReplyToneLearner.learn(
            from: conversation.messages, kind: kind, userName: settings.effectiveUserName,
            preference: settings.tone, signOff: settings.signOff
        )
        var space = ReplySpaceContext()
        if settings.useSpaces { space = await spaceContext(for: conversation) }
        // Closed while Spaces were searched: posting "Drafting…" now would
        // leave a band that nothing dismisses.
        guard !Task.isCancelled else { return }
        spaceName = space.spaceName
        let wantsSubject = settings.fillSubject && conversation.shouldFillSubject && subjectField != nil
        let request = ReplyDraftRequest(conversation: conversation, tone: tone, space: space, wantsSubject: wantsSubject)
        self.request = request

        phase = .drafting
        postActivity("Drafting a reply in your tone…", working: true)
        let engine = makeEngine(readKey: true)
        engineLabel = engine.engineLabel
        do {
            let draft = try await engine.draft(request)
            guard !Task.isCancelled else { return }
            self.draft = draft
            engineLabel = draft.producedBy
            await place(draft, first: true, fillSubject: wantsSubject)
            AppLog.log("Reply Drafter: draft ready (\(draft.body.count) chars, \(draft.producedBy)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch is CancellationError {
            return
        } catch {
            fail("Couldn't write a draft (\(ReplyDraftEngine.category(error))).")
        }
    }

    /// Puts a draft into the field (or keeps it in the bar).
    private func place(_ draft: ReplyDraft, first: Bool, fillSubject: Bool) async {
        if settings.autoInsert, let editor {
            do {
                if first || editor.history == nil {
                    try await editor.insert(draft, fillSubject: fillSubject)
                } else {
                    try await editor.apply(draft)
                }
                isInField = true
                notice = "In the message box. Check it, then send it yourself."
            } catch let failure as ReplyFieldEditor.Failure {
                isInField = false
                notice = failure == .changedByUser
                    ? "You edited the reply, so SparkV left the message box as it is."
                    : "Couldn't write into this field. Use Copy, or click the message box and press Insert."
                addPreview(draft)
            } catch {
                addPreview(draft)
            }
        } else {
            addPreview(draft)
            notice = editor == nil ? "Click the message box, then press Insert." : "Press Insert to put it in the message box."
        }
        // Closed while writing: the text stays as it is and the bar is gone.
        guard !Task.isCancelled else { return }
        sync()
        phase = .ready
        postActivity(isInField ? "Reply drafted. Review before sending" : "Reply drafted", working: false, duration: 2.5)
    }

    private func addPreview(_ draft: ReplyDraft) {
        if !previews.isEmpty { previews = Array(previews[...previewIndex]) }
        previews.append(draft)
        previewIndex = previews.count - 1
    }

    // MARK: Bar actions

    func revise(_ revision: ReplyRevision) {
        guard !phase.isBusy, var request, let current = draft else { return }
        if revision == .regenerate {
            request.variation += 1
            self.request = request
        }
        phase = .revising(revision)
        postActivity("\(revision.title)…", working: true)
        let engine = makeEngine(readKey: true)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await engine.revise(request, current: current, revision: revision)
                guard !Task.isCancelled else { return }
                self.draft = next
                self.engineLabel = next.producedBy
                if self.isInField, let editor = self.editor {
                    do {
                        try await editor.apply(next)
                        self.notice = "\(revision.title) version in the message box."
                    } catch let failure as ReplyFieldEditor.Failure {
                        self.isInField = false
                        self.addPreview(next)
                        self.notice = failure == .changedByUser
                            ? "You edited the reply, so SparkV didn't replace it. Use Copy for the new version."
                            : "Couldn't update the message box. Use Copy for the new version."
                    }
                } else {
                    self.addPreview(next)
                }
                self.sync()
                self.phase = .ready
                self.postActivity("Reply updated", working: false, duration: 1.8)
            } catch is CancellationError {
                return
            } catch {
                self.phase = .ready
                self.notice = "Couldn't rework the draft (\(ReplyDraftEngine.category(error)))."
                self.activities.dismiss(id: Self.activityID)
            }
        }
    }

    func undo() {
        guard !phase.isBusy else { return }
        if let editor, editor.canUndo {
            run { try await editor.undo() } done: { [weak self] in
                guard let self else { return }
                if editor.history?.index == 0 { self.notice = "Undone. Your original text is back." }
            }
        } else if previewIndex > 0 {
            previewIndex -= 1
            draft = previews[previewIndex]
            sync()
        }
    }

    func redo() {
        guard !phase.isBusy else { return }
        if let editor, editor.canRedo {
            run { try await editor.redo() } done: { [weak self] in self?.notice = "In the message box. Check it, then send it yourself." }
        } else if previewIndex < previews.count - 1 {
            previewIndex += 1
            draft = previews[previewIndex]
            sync()
        }
    }

    /// Writes the shown draft into the message box (when it wasn't written
    /// automatically or the field wasn't found).
    func insertIntoField() {
        guard !phase.isBusy, let draft else { return }
        // No version written yet (the field wasn't found or refused the
        // write): use the field the user clicked since, not the one that failed.
        if editor?.history == nil {
            editor = focusedFieldEditor() ?? editor ?? caretEditor()
        }
        guard let editor else { return }
        let wantsSubject = request?.wantsSubject ?? false
        phase = .writing
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if editor.history == nil {
                    try await editor.insert(draft, fillSubject: wantsSubject)
                } else {
                    try await editor.apply(draft)
                }
                self.isInField = true
                self.notice = "In the message box. Check it, then send it yourself."
            } catch {
                self.notice = "Couldn't write into this field. Use Copy instead."
            }
            self.sync()
            self.phase = .ready
        }
    }

    func copyDraft() {
        guard let draft else { return }
        TextInserter.copy(draft.body)
        notice = "Copied."
    }

    /// Closes the bar. The text stays in the message box as it is.
    func close() {
        work?.cancel()
        work = nil
        bar.hide()
        isBarVisible = false
        activities.dismiss(id: Self.activityID)
        resetSession()
        phase = .idle
    }

    /// The bar's button. PermissionCenter shows the Accessibility alert once
    /// per code signature (it adds SparkV to the list), then opens Settings.
    func openAccessibilitySettings() {
        Task {
            if await PermissionCenter.shared.ensure(.accessibility, from: "Reply Drafter") { needsAccessibility = false }
        }
    }

    /// Screen Recording, only from the bar's button: the system request once
    /// per code signature, then Settings; it applies after a restart.
    func allowScreenRecording() {
        ScreenRegionCapture.requestPermission(from: "Reply Drafter") { [weak self] granted in
            guard let self, !granted, ScreenRegionCapture.needsRelaunch else { return }
            self.notice = "Turned on Screen Recording? Restart SparkV for it to take effect."
        }
    }

    // MARK: Helpers

    private func run(_ operation: @escaping () async throws -> Void, done: @escaping () -> Void) {
        phase = .writing
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                done()
            } catch let failure as ReplyFieldEditor.Failure {
                self.notice = failure == .changedByUser
                    ? "The message box changed since SparkV wrote it, so it was left alone. Use ⌘Z in the app."
                    : "Couldn't change the message box."
            } catch {}
            self.sync()
            self.phase = .ready
        }
    }

    private func sync() {
        if let history = editor?.history {
            canUndo = history.canUndo
            canRedo = history.canRedo
            isInField = history.index > 0
            if history.index > 0, var shown = draft {
                shown.body = history.current.body
                if let subject = history.current.subject, !subject.isEmpty { shown.subject = subject }
                draft = shown
            }
        } else {
            canUndo = previewIndex > 0
            canRedo = previewIndex < previews.count - 1
        }
    }

    private func resetSession() {
        editor = nil
        request = nil
        draft = nil
        previews = []
        previewIndex = 0
        notice = nil
        spaceName = nil
        readFromScreen = false
        needsAccessibility = false
        suggestsScreenRecording = false
        isInField = false
        canUndo = false
        canRedo = false
        fieldFrame = nil
        windowFrame = nil
        contextLine = ""
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        activities.dismiss(id: Self.activityID)
    }

    /// The message box the user clicked after the draft was made.
    private func focusedFieldEditor() -> ReplyFieldEditor? {
        guard let pid = targetPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Runs on the main thread: a hung app must not freeze SparkV for the
        // default 6 s AX timeout.
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = ReplyAXReader.element(app, kAXFocusedUIElementAttribute),
              let node = ReplyAXReader.node(for: focused), node.isEditable,
              !ReplyConversationReader.isExcludedField(node) else { return nil }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        fieldFrame = node.frame
        bar.reposition()
        return ReplyFieldEditor(body: ReplyAXField(element: ReplyAXElement(focused), pid: pid, bundleID: bundleID, role: node.role), subject: nil)
    }

    /// Last resort: paste at the caret; Undo is the app's own ⌘Z.
    private func caretEditor() -> ReplyFieldEditor? {
        guard let pid = targetPID else { return nil }
        return ReplyFieldEditor(body: ReplyCaretField(pid: pid), subject: nil)
    }

    private func makeEngine(readKey: Bool) -> ReplyDraftEngine {
        // The keychain is touched only when the user allowed Groq here.
        guard settings.allowGroq, ClickyKeychain.hasKey() else { return ReplyDraftEngine() }
        guard readKey else { return ReplyDraftEngine(groq: MeetingAIConfig(useGroq: true, groqKey: "pending")) }
        guard let key = ClickyKeychain.load() else { return ReplyDraftEngine() }
        return ReplyDraftEngine(groq: MeetingAIConfig(useGroq: true, groqKey: key))
    }

    private func spaceContext(for conversation: ReplyConversation) async -> ReplySpaceContext {
        let query = ReplySpaceContextBuilder.query(for: conversation)
        guard !query.isEmpty else { return ReplySpaceContext() }
        let store = SpaceStore.shared
        let hits = await store.search(query, in: nil)
        var memories: [UUID: String] = [:]
        for space in store.spaces { if let memory = store.memory(of: space.id) { memories[space.id] = memory } }
        return ReplySpaceContextBuilder.pick(hits: hits, spaces: store.spaces, query: query, background: { memories[$0] })
    }

    /// Captures only the target window (never SparkV), OCRs it in memory and
    /// parses it. Nothing is written to disk.
    private func readScreen(pid: pid_t, axWindow: CGRect, kind: ReplyAppKind, title: String, me: ReplyIdentity) async -> ReplyConversation? {
        let candidates = ScreenRegionCapture.onScreenWindows().filter { $0.ownerPID == pid }
        guard let window = Self.matchingWindow(candidates, axFrame: axWindow, primaryHeight: ScreenRegionCapture.primaryHeight),
              let display = ScreenRegionGeometry.display(for: window.frame, in: ScreenRegionCapture.displays()) else { return nil }
        let selection = ScreenRegionSelection.window(id: window.id, frame: window.frame, display: display, appName: window.appName, title: window.title)
        guard let image = try? await ScreenRegionCapture.capture(selection, from: "Reply Drafter") else { return nil }
        let analysis = await TrayAIOCR.analyze(TrayAIImageBox(image: image))
        let observations = analysis.lines.map { ReplyOCRReader.Observation(text: $0.text, rect: $0.rect) }
        let scale = CGFloat(image.width) / max(1, window.frame.width)
        let windowQuartzOrigin = CGPoint(x: window.frame.minX, y: ScreenRegionCapture.primaryHeight - window.frame.maxY)
        let compose = fieldFrame.map { $0.offsetBy(dx: -windowQuartzOrigin.x, dy: -windowQuartzOrigin.y) }
        return ReplyOCRReader.read(observations: observations, scale: scale, windowSize: window.frame.size, kind: kind, composeFrame: compose, me: me, title: title)
    }

    /// The on-screen window that is the one read through Accessibility
    /// (`axFrame` is Quartz); the frontmost of the app's windows otherwise.
    /// Picking by frame keeps a palette, popover or second window of the
    /// same app from being captured instead.
    static func matchingWindow(_ windows: [ScreenRegionWindowInfo], axFrame: CGRect, primaryHeight: CGFloat) -> ScreenRegionWindowInfo? {
        guard axFrame.width > 0, axFrame.height > 0 else { return windows.first }
        func mismatch(_ window: ScreenRegionWindowInfo) -> CGFloat {
            let quartz = ScreenRegionGeometry.quartzRect(fromAppKit: window.frame, primaryHeight: primaryHeight)
            return abs(quartz.minX - axFrame.minX) + abs(quartz.minY - axFrame.minY)
                + abs(quartz.width - axFrame.width) + abs(quartz.height - axFrame.height)
        }
        if let best = windows.min(by: { mismatch($0) < mismatch($1) }), mismatch(best) < 24 { return best }
        return windows.first
    }

    static func contextLine(_ conversation: ReplyConversation) -> String {
        var parts = [conversation.kind.displayName]
        let title = conversation.kind.isEmail ? (conversation.subject ?? conversation.title) : conversation.title
        if !title.isEmpty { parts.append(String(title.prefix(40))) }
        if conversation.isNewEmail {
            parts.append("new email")
        } else {
            parts.append("\(conversation.messages.count) message\(conversation.messages.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Bar & band

    private func showBar() {
        isBarVisible = true
        bar.show()
    }

    /// Where the bar goes (Quartz frames of the field and window).
    var anchor: (field: CGRect?, window: CGRect?) { (fieldFrame, windowFrame) }

    private func postActivity(_ text: String, working: Bool, duration: TimeInterval? = nil) {
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 62, duration: duration) {
            ReplyDrafterActivityView(text: text, isWorking: working)
        })
    }
}

// MARK: - Renders and tests

extension ReplyDrafterController {
    /// Sets what the bar shows without reading any app (offscreen renders).
    func loadPreviewState(
        phase: Phase, kind: ReplyAppKind, contextLine: String, draft: ReplyDraft?, notice: String?,
        spaceName: String? = nil, readFromScreen: Bool = false, needsAccessibility: Bool = false,
        canUndo: Bool = false, canRedo: Bool = false, isInField: Bool = false
    ) {
        self.phase = phase
        self.kind = kind
        self.contextLine = contextLine
        self.draft = draft
        self.notice = notice
        self.spaceName = spaceName
        self.readFromScreen = readFromScreen
        self.needsAccessibility = needsAccessibility
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.isInField = isInField
        if let draft { engineLabel = draft.producedBy }
    }
}

/// A field that can't be read: insert at the caret, ⌘Z to undo.
@MainActor
final class ReplyCaretField: ReplyWritableField {
    let pid: pid_t
    init(pid: pid_t) { self.pid = pid }

    var frame: CGRect? { nil }

    func read() async -> ReplyFieldState? { nil }

    func replace(_ range: NSRange, with text: String) async -> Bool {
        await front()
        if text.isEmpty { return true }
        return await TextInserter.insert(text) == .inserted
    }

    func nativeUndo() async -> Bool {
        await front()
        ReplyKeys.post(keyCode: 6, command: true) // kVK_ANSI_Z
        return true
    }

    func nativeRedo() async -> Bool {
        await front()
        ReplyKeys.post(keyCode: 6, command: true, shift: true)
        return true
    }

    private func front() async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
