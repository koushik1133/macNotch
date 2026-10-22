import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// State and actions behind the search panel and the Agents-hub drawer.
///
/// Data comes from the app's stores through `DataSource` and every side
/// effect goes through `Actions`, so the headless tests run the real ranking,
/// ask and keyboard logic on fixtures. `UniversalSearchController.live(…)`
/// wires the real stores.
@MainActor
final class UniversalSearchController: ObservableObject {
    enum Mode: Equatable {
        case search
        case ask
    }

    enum AskState: Equatable {
        case idle
        case thinking
        case answered(UniversalSearchAsk.Answer)
    }

    struct DataSource {
        /// A snapshot of every store (called on the main actor).
        var input: @MainActor () -> UniversalSearchCorpus.Input
        /// Spaces' keyword + semantic search, merged after the instant results.
        var semanticSpaces: (@MainActor (String) async -> [SpaceItem])?
        /// Fires when any store changes.
        var changes: AnyPublisher<Void, Never>
    }

    struct Actions {
        var openSpaceItem: @MainActor (UUID) -> Void
        var openMeeting: @MainActor (UUID) -> Void
        var openFlow: @MainActor (UniversalSearchTarget) -> Void
        /// Puts a clipboard-history item back on the clipboard (all representations).
        var copyClipboardItem: @MainActor (UUID) -> Bool
        /// Copies it and pastes into the front app (⌘↩).
        var pasteClipboardItem: @MainActor (UUID) -> Bool
        var revealTrayItem: @MainActor (UUID) -> Void
        var openTrayItem: @MainActor (UUID) -> Void
        var openURL: @MainActor (URL) -> Void
        var meetingMarkdown: @MainActor (UUID) -> String?
        var spaceItemURL: @MainActor (UUID) -> URL?
        var copyText: @MainActor (String) -> Void
        var startDictation: (@MainActor (@escaping @MainActor (String?) -> Void) -> Bool)?
        var stopDictation: (@MainActor () -> Void)?
    }

    // MARK: Published state

    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var mode: Mode = .search
    /// Source chip (nil = all). `in:` tokens narrow further.
    @Published private(set) var sourceFilter: UniversalSearchSource?
    @Published private(set) var dateFilter: UniversalSearchDateFilter = .any
    @Published private(set) var sections: [UniversalSearchSection] = []
    @Published private(set) var flat: [UniversalSearchResult] = []
    @Published var selectedID: String?
    @Published private(set) var isSearching = false
    @Published private(set) var askState: AskState = .idle
    /// Numbered sources of the current answer (number = index + 1).
    @Published private(set) var askSources: [UniversalSearchResult] = []
    @Published private(set) var askedQuestion = ""
    @Published private(set) var isDictating = false
    @Published private(set) var toast: String?
    @Published private(set) var indexedCount = 0
    @Published private(set) var countsBySource: [UniversalSearchSource: Int] = [:]
    /// Bumped to put the caret back in the search field.
    @Published private(set) var focusToken = 0
    @Published private(set) var isPanelOpen = false
    @Published private(set) var isRecordingShortcut = false

    // Settings
    @Published var hotkeyEnabled: Bool {
        didSet {
            guard hotkeyEnabled != oldValue else { return }
            defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled)
            installHotkey()
        }
    }
    @Published private(set) var shortcut: ScreenRegionShortcut
    @Published private(set) var hotkeyRegistered = false
    @Published private(set) var enabledSources: Set<UniversalSearchSource>
    /// Lets Ask send the top results to Groq (Clicky key) when the on-device
    /// model can't answer. Off by default.
    @Published var allowGroq: Bool {
        didSet { defaults.set(allowGroq, forKey: Key.allowGroq) }
    }

    /// Shows the Flow drawer tab (the lead owns the drawer). Takes
    /// precedence over `Actions.openFlow`.
    var openFlowHandler: (@MainActor (UniversalSearchTarget) -> Void)?
        /// Set by the panel controller; the app closes the panel through it.
    var requestClose: (() -> Void)?
    var requestOpen: (() -> Void)?
    /// Test seam for Ask (instructions, prompt) -> reply.
    var askModelOverride: (@Sendable (String, String) async throws -> String)?
    /// Seconds after which reopening starts with an empty box (Raycast's
    /// "pop to root").
    var resetAfter: TimeInterval = 90
    var now: () -> Date = Date.init

    private let dataSource: DataSource
    private let actions: Actions
    private let defaults: UserDefaults
    private let knowledgeFile: UniversalSearchKnowledgeFile?
    private(set) var knowledge: UniversalSearchKnowledge
    private(set) var documents: [UniversalSearchDocument] = []
    private var docIndex: [String: UniversalSearchDocument] = [:]
    private var lastResults: [UniversalSearchResult] = []
    private var corpusDirty = true
    private var corpusTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var changeSubscription: AnyCancellable?
    private var lastClosedAt: Date?
    private var drawerVisible = false
    private let hotkey = ScreenRegionHotkey()
    private(set) lazy var panel = UniversalSearchPanelController(controller: self)

    private enum Key {
        static let hotkeyEnabled = "UniversalSearch.hotkeyEnabled"
        static let shortcut = "UniversalSearch.shortcut"
        static let disabledSources = "UniversalSearch.disabledSources"
        static let allowGroq = "UniversalSearch.allowGroq"
    }

    /// ⌥Space, as Alfred ships (and Raycast suggests).
    static let defaultShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    static let shortcutPresets: [ScreenRegionShortcut] = [
        defaultShortcut,
        ScreenRegionShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey)),
        ScreenRegionShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey)),
        ScreenRegionShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey)),
        ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(controlKey | optionKey)),
    ]

    init(dataSource: DataSource, actions: Actions, defaults: UserDefaults = .standard,
         knowledgeFile: UniversalSearchKnowledgeFile? = UniversalSearchKnowledgeFile(url: UniversalSearchKnowledgeFile.defaultURL)) {
        self.dataSource = dataSource
        self.actions = actions
        self.defaults = defaults
        self.knowledgeFile = knowledgeFile
        knowledge = knowledgeFile?.load() ?? UniversalSearchKnowledge()
        hotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        allowGroq = defaults.bool(forKey: Key.allowGroq)
        if let data = defaults.data(forKey: Key.shortcut),
           let saved = try? JSONDecoder().decode(ScreenRegionShortcut.self, from: data), saved.isValidGlobal {
            shortcut = saved
        } else {
            shortcut = Self.defaultShortcut
        }
        let disabled = Set((defaults.stringArray(forKey: Key.disabledSources) ?? []).compactMap(UniversalSearchSource.init(rawValue:)))
        enabledSources = Set(UniversalSearchSource.allCases).subtracting(disabled)
        hotkey.onPress = { [weak self] in self?.togglePanel() }
        changeSubscription = dataSource.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.storesChanged() }
            }
    }

    // MARK: Lifecycle

    func start() {
        installHotkey()
        rebuildCorpus()
    }

    func stop() {
        hotkey.unregister()
        hotkeyRegistered = false
        closePanel()
        corpusTask?.cancel()
        searchTask?.cancel()
        askTask?.cancel()
        closeTask?.cancel()
        toastTask?.cancel()
        if isDictating { actions.stopDictation?() }
    }

    // MARK: Panel

    func togglePanel() {
        if isPanelOpen { closePanel() } else { openPanel() }
    }

    func openPanel(query newQuery: String? = nil, mode newMode: Mode = .search) {
        closeTask?.cancel()
        if let closed = lastClosedAt, now().timeIntervalSince(closed) > resetAfter, newQuery == nil {
            query = ""
            sourceFilter = nil
            dateFilter = .any
        }
        if let newQuery { query = newQuery }
        if corpusDirty { rebuildCorpus() } else { search(immediate: true) }
        setMode(newMode)
        isPanelOpen = true
        focusToken += 1
        if requestOpen == nil { _ = panel }
        requestOpen?()
    }

    func closePanel() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        lastClosedAt = now()
        if isRecordingShortcut { cancelShortcutRecording() }
        if isDictating { actions.stopDictation?() }
        requestClose?()
    }

    /// The drawer view reports whether it is on screen (keeps the corpus fresh).
    func setDrawerVisible(_ visible: Bool) {
        drawerVisible = visible
        if visible {
            // The drawer can't show an answer: an Ask left over from a panel
            // closed by a click outside would otherwise stop typing from searching.
            if mode == .ask, !isPanelOpen { setMode(.search) }
            if corpusDirty { rebuildCorpus() }
            focusToken += 1
        }
    }

    /// Esc: leave Ask, then clear the box, then close (Spotlight order).
    func escape() {
        if isRecordingShortcut {
            cancelShortcutRecording()
        } else if mode == .ask {
            setMode(.search)
        } else if !query.isEmpty {
            query = ""
        } else {
            closePanel()
        }
    }

    // MARK: Corpus

    private func storesChanged() {
        corpusDirty = true
        guard isPanelOpen || drawerVisible else { return }
        corpusTask?.cancel()
        corpusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuildCorpus()
        }
    }

    /// Re-reads every store. Folding and indexing run off the main thread.
    func rebuildCorpus() {
        corpusDirty = false
        let input = dataSource.input()
        let enabled = enabledSources
        corpusTask?.cancel()
        corpusTask = Task { [weak self] in
            let docs = await UniversalSearchBackground.run {
                UniversalSearchCorpus.build(input, enabled: enabled)
            }
            guard !Task.isCancelled, let self else { return }
            self.install(docs)
        }
    }

    /// Same as `rebuildCorpus` but waits (tests, first open).
    func rebuildCorpusNow() async {
        corpusDirty = false
        let input = dataSource.input()
        let enabled = enabledSources
        corpusTask?.cancel()
        let docs = await UniversalSearchBackground.run {
            UniversalSearchCorpus.build(input, enabled: enabled)
        }
        install(docs)
    }

    private func install(_ docs: [UniversalSearchDocument]) {
        documents = docs
        docIndex = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        indexedCount = docs.count
        var counts: [UniversalSearchSource: Int] = [:]
        for d in docs { counts[d.source, default: 0] += 1 }
        countsBySource = counts
        // In Ask the list isn't shown; leaving Ask searches again.
        if mode == .search { search(immediate: true) }
    }

    // MARK: Filters

    func setSourceFilter(_ source: UniversalSearchSource?) {
        sourceFilter = sourceFilter == source ? nil : source
        search(immediate: true)
        focusToken += 1
    }

    func setDateFilter(_ filter: UniversalSearchDateFilter) {
        dateFilter = filter
        search(immediate: true)
        focusToken += 1
    }

    func cycleDateFilter() {
        let all = UniversalSearchDateFilter.allCases
        let i = all.firstIndex(of: dateFilter) ?? 0
        setDateFilter(all[(i + 1) % all.count])
    }

    func setSourceEnabled(_ source: UniversalSearchSource, _ enabled: Bool) {
        if enabled { enabledSources.insert(source) } else { enabledSources.remove(source) }
        let disabled = UniversalSearchSource.allCases.filter { !enabledSources.contains($0) }.map(\.rawValue)
        defaults.set(disabled, forKey: Key.disabledSources)
        if !enabled, sourceFilter == source { sourceFilter = nil }
        rebuildCorpus()
    }

    func options(for parsed: UniversalSearchQuery, mode: UniversalSearchEngine.Mode = .all) -> UniversalSearchEngine.Options {
        var sources = enabledSources
        if let sourceFilter { sources = sources.intersection([sourceFilter]) }
        if let tokens = parsed.sources { sources = sources.intersection(tokens) }
        return UniversalSearchEngine.Options(
            sources: sources, date: parsed.date ?? dateFilter, mode: mode, limit: 200, now: now()
        )
    }

    // MARK: Search

    private func queryChanged() {
        resetSelection = true
        if mode == .ask {
            // A new question waits for Enter.
            return
        }
        search(immediate: false)
    }

    /// Instant local results, then Spaces' semantic hits merged in.
    func search(immediate: Bool) {
        searchTask?.cancel()
        let parsed = UniversalSearchQuery.parse(query)
        let options = options(for: parsed)
        if parsed.isEmpty {
            isSearching = false
            lastResults = []
            let recents = UniversalSearchEngine.recents(documents, options: options, knowledge: knowledge,
                                                        perSource: options.sources.count == 1 ? 12 : 3)
            publish(recents)
            return
        }
        let docs = documents
        let knowledge = knowledge
        isSearching = true
        searchTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 15_000_000) }
            guard !Task.isCancelled else { return }
            // Cancelled by the next keystroke, so stale searches stop early.
            let results = await UniversalSearchBackground.run {
                UniversalSearchEngine.search(parsed, in: docs, options: options, knowledge: knowledge)
            }
            guard !Task.isCancelled, let self else { return }
            self.apply(results, options: options)
            guard let semantic = self.dataSource.semanticSpaces, options.sources.contains(.spaces),
                  parsed.text.count >= 3 else {
                self.isSearching = false
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let items = await semantic(parsed.text)
            guard !Task.isCancelled else { return }
            let merged = self.mergeSemantic(items, into: results, terms: parsed.terms, options: options)
            self.apply(merged, options: options)
            self.isSearching = false
        }
    }

    /// Waits for the current search (tests).
    func waitForSearch() async {
        await searchTask?.value
    }

    private func apply(_ results: [UniversalSearchResult], options: UniversalSearchEngine.Options) {
        lastResults = results
        publish(UniversalSearchEngine.sections(results, perSource: 4, singleSource: options.sources.count == 1))
    }

    private func publish(_ newSections: [UniversalSearchSection]) {
        sections = newSections
        flat = newSections.flatMap(\.results)
        // A new query selects the best hit again; a refresh of the same
        // query (semantic merge, store change) keeps the selection.
        if mode == .search, resetSelection || selectedID == nil || !flat.contains(where: { $0.id == selectedID }) {
            selectedID = flat.first?.id
        }
        resetSelection = false
    }

    private var resetSelection = false

    func mergeSemantic(_ items: [SpaceItem], into results: [UniversalSearchResult], terms: [String],
                       options: UniversalSearchEngine.Options) -> [UniversalSearchResult] {
        var out = results
        var seen = Set(results.map(\.id))
        let floor = results.filter { $0.source == .spaces }.map(\.score).min() ?? 40
        for (i, item) in items.prefix(10).enumerated() {
            let id = "space:\(item.id.uuidString)"
            guard !seen.contains(id), let doc = docIndex[id], options.date.contains(doc.date, now: options.now) else { continue }
            seen.insert(id)
            let (snippet, ranges) = UniversalSearchEngine.excerpt(doc, terms: terms)
            out.append(UniversalSearchResult(document: doc, score: floor * 0.5 - Double(i), titleHighlights: [],
                                             snippet: snippet, snippetHighlights: ranges, isRelated: true))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.document.date > $1.document.date }
        return out
    }

    // MARK: Selection

    var selected: UniversalSearchResult? {
        let list = mode == .ask ? askSources : flat
        return list.first { $0.id == selectedID } ?? (mode == .search ? list.first : nil)
    }

    func move(_ delta: Int) {
        let list = mode == .ask ? askSources : flat
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = max(0, min(list.count - 1, current + delta))
        selectedID = list[next].id
    }

    /// ⌘↓ / ⌘↑: first row of the next / previous section.
    func jumpSection(_ delta: Int) {
        guard mode == .search, !sections.isEmpty else { return }
        let current = sections.firstIndex { s in s.results.contains { $0.id == selectedID } } ?? 0
        let next = max(0, min(sections.count - 1, current + delta))
        selectedID = sections[next].results.first?.id
    }

    func select(_ id: String) {
        selectedID = id
        focusToken += 1
    }

    // MARK: Actions

    /// Enter (or ⌘Enter with `alternate`).
    func submit(alternate: Bool = false) {
        if mode == .ask {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q != askedQuestion || askState == .idle {
                runAsk()
            } else if let s = selected {
                activate(s, alternate: alternate)
            }
            // Same question, already thinking or answered, nothing selected:
            // Enter again doesn't restart the model.
            return
        }
        guard let r = selected else {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                // Nothing matched: Enter asks, like Raycast's "Ask AI" fallback.
                setMode(.ask)
                runAsk()
            }
            return
        }
        activate(r, alternate: alternate)
    }

    func primaryTitle(for r: UniversalSearchResult) -> String {
        switch r.document.target {
        case .spaceItem: "Open in Spaces"
        case .meeting: "Open Notes"
        case .flowEntry, .flowNote: "Show in Flow"
        case .clipboard: "Copy"
        case .trayItem: r.document.symbol == "text.alignleft" ? "Copy" : "Reveal in Finder"
        }
    }

    func alternateTitle(for r: UniversalSearchResult) -> String? {
        switch r.document.target {
        case .clipboard: "Paste"
        case .trayItem: r.document.symbol == "text.alignleft" ? nil : "Open"
        case .spaceItem(let id): actions.spaceItemURL(id) != nil ? "Open Link" : nil
        default: nil
        }
    }

    func activate(_ r: UniversalSearchResult, alternate: Bool = false) {
        remember(r)
        let target = r.document.target
        if alternate {
            switch target {
            case .clipboard(let id):
                closePanel()
                _ = actions.pasteClipboardItem(id)
                return
            case .trayItem(let id) where r.document.symbol != "text.alignleft":
                closePanel()
                actions.openTrayItem(id)
                return
            case .spaceItem(let id):
                if let url = actions.spaceItemURL(id) {
                    closePanel()
                    actions.openURL(url)
                    return
                }
            default:
                break
            }
        }
        switch target {
        case .spaceItem(let id):
            closePanel()
            actions.openSpaceItem(id)
        case .meeting(let id):
            closePanel()
            actions.openMeeting(id)
        case .flowEntry, .flowNote:
            closePanel()
            if let openFlowHandler { openFlowHandler(target) } else { actions.openFlow(target) }
        case .clipboard(let id):
            if actions.copyClipboardItem(id) {
                flash("Copied to Clipboard")
                closeSoon()
            } else {
                flash("That clipboard item is gone")
            }
        case .trayItem(let id):
            if r.document.symbol == "text.alignleft", let text = r.document.copyText {
                actions.copyText(text)
                flash("Copied to Clipboard")
                closeSoon()
            } else {
                closePanel()
                actions.revealTrayItem(id)
            }
        }
    }

    /// ⌘C.
    func copySelected() {
        guard let r = selected else { return }
        copy(r)
    }

    func copy(_ r: UniversalSearchResult) {
        remember(r)
        switch r.document.target {
        case .clipboard(let id):
            guard actions.copyClipboardItem(id) else {
                flash("That clipboard item is gone")
                return
            }
        case .meeting(let id):
            actions.copyText(actions.meetingMarkdown(id) ?? r.document.title)
        default:
            actions.copyText(r.document.copyText ?? r.document.title)
        }
        flash("Copied to Clipboard")
        closeSoon()
    }

    /// Closes after the "Copied" confirmation has been seen. Cancelled by a
    /// reopen, so an old copy never closes a panel opened since.
    private func closeSoon() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.closePanel()
        }
    }

    private var closeTask: Task<Void, Never>?

    private func remember(_ r: UniversalSearchResult) {
        let q = mode == .ask ? "" : UniversalSearchQuery.parse(query).text
        knowledge.record(itemID: r.id, query: q, now: now())
        let snapshot = knowledge
        knowledgeFile?.saveInBackground(snapshot)
    }

    func clearHistory() {
        knowledge = UniversalSearchKnowledge()
        knowledgeFile?.deleteInBackground()
        search(immediate: true)
        flash("Search history cleared")
    }

    // MARK: Ask

    func toggleAsk() {
        setMode(mode == .search ? .ask : .search)
        if mode == .ask, !query.trimmingCharacters(in: .whitespaces).isEmpty,
           query.trimmingCharacters(in: .whitespacesAndNewlines) != askedQuestion {
            runAsk()
        }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .search {
            askTask?.cancel()
            askTask = nil
            if askState == .thinking { askState = .idle }
            selectedID = flat.first?.id
            search(immediate: true)
        } else {
            searchTask?.cancel()
            isSearching = false
            selectedID = nil
        }
        focusToken += 1
    }

    func runAsk() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if mode != .ask {
            mode = .ask
        }
        searchTask?.cancel()
        isSearching = false
        askTask?.cancel()
        askedQuestion = question
        askState = .thinking
        askSources = []
        selectedID = nil
        let parsed = UniversalSearchQuery.parse(question)
        let options = options(for: parsed, mode: .any)
        let docs = documents
        let knowledge = knowledge
        let backends = UniversalSearchAsk.Backends(
            allowGroq: allowGroq,
            groqKey: allowGroq ? ClickyKeychain.load() : nil,
            model: askModelOverride
        )
        askTask = Task { [weak self] in
            var results = await UniversalSearchBackground.run {
                UniversalSearchEngine.search(parsed, in: docs, options: options, knowledge: knowledge)
            }
            guard !Task.isCancelled, let self else { return }
            if let semantic = self.dataSource.semanticSpaces, options.sources.contains(.spaces) {
                let items = await semantic(parsed.text)
                guard !Task.isCancelled else { return }
                results = self.mergeSemantic(items, into: results, terms: parsed.terms, options: options)
                // Keep a few semantic Space hits in the top 8 even when
                // keyword hits elsewhere outrank them.
                let related = results.filter(\.isRelated).prefix(2)
                var top = Array(results.filter { !$0.isRelated }.prefix(6))
                top += related
                results = top
            }
            let (answer, sources) = await UniversalSearchAsk.answer(
                question: question, results: Array(results.prefix(8)), backends: backends
            )
            guard !Task.isCancelled else { return }
            let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.askSources = sources.compactMap { byID[$0.resultID] }
            self.askState = .answered(answer)
        }
    }

    func waitForAsk() async {
        await askTask?.value
    }

    /// From the drawer: Ask happens in the panel, which has room for the answer.
    func askInPanel() {
        let q = query
        openPanel(query: q, mode: .ask)
        if !q.trimmingCharacters(in: .whitespaces).isEmpty, q.trimmingCharacters(in: .whitespacesAndNewlines) != askedQuestion || askState == .idle {
            runAsk()
        }
    }

    /// Enter in the drawer: open the selection, or ask in the panel when
    /// nothing matched.
    func submitFromDrawer(alternate: Bool) {
        if mode == .search, selected != nil {
            submit(alternate: alternate)
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            askInPanel()
        }
    }

    /// A [n] citation in the answer was clicked.
    func openCitation(_ number: Int) {
        guard number >= 1, number <= askSources.count else { return }
        activate(askSources[number - 1])
    }

    // MARK: Dictation

    func toggleDictation() {
        if isDictating {
            actions.stopDictation?()
            return
        }
        guard let start = actions.startDictation else {
            flash("Dictation isn't available")
            return
        }
        let started = start { [weak self] text in
            guard let self else { return }
            self.isDictating = false
            self.focusToken += 1
            let spoken = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            if UniversalSearchAsk.looksLikeQuestion(spoken) {
                self.query = spoken
                if self.isPanelOpen {
                    self.setMode(.ask)
                    self.runAsk()
                } else if self.drawerVisible {
                    // The drawer has no room for an answer.
                    self.askInPanel()
                }
                // Closed meanwhile: keep the question in the box, ask nothing.
            } else {
                // Dictation adds sentence punctuation a search doesn't want.
                self.query = spoken.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            }
        }
        isDictating = started
        if !started { flash("Couldn't start dictation") }
    }

    // MARK: Hotkey

    func installHotkey() {
        guard hotkeyEnabled, !isRecordingShortcut else {
            hotkey.unregister()
            hotkeyRegistered = false
            return
        }
        hotkeyRegistered = hotkey.register(shortcut)
        if hotkeyRegistered { AppLog.log("Universal Search: hotkey \(shortcut.displayString)") }
    }

    @discardableResult
    func setShortcut(_ newValue: ScreenRegionShortcut) -> Bool {
        guard newValue.isValidGlobal else {
            flash("Use ⌃, ⌥ or ⌘ in the shortcut")
            return false
        }
        shortcut = newValue
        if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Key.shortcut) }
        installHotkey()
        if hotkeyEnabled, !hotkeyRegistered {
            flash("\(newValue.displayString) is taken by another app — pick another")
        }
        return hotkeyRegistered || !hotkeyEnabled
    }

    func beginShortcutRecording() {
        isRecordingShortcut = true
        hotkey.unregister()
        hotkeyRegistered = false
        if !isPanelOpen { openPanel() }
    }

    func cancelShortcutRecording() {
        isRecordingShortcut = false
        installHotkey()
    }

    /// A key pressed while recording. True when it was used.
    @discardableResult
    func recordShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isRecordingShortcut else { return false }
        if keyCode == 53 {
            cancelShortcutRecording()
            return true
        }
        let candidate = ScreenRegionShortcut(keyCode: keyCode, modifiers: modifiers.intersection(.deviceIndependentFlagsMask))
        guard candidate.isValidGlobal else {
            flash("Hold ⌃, ⌥ or ⌘ with the key")
            return true
        }
        isRecordingShortcut = false
        if setShortcut(candidate) { flash("Search shortcut is now \(candidate.displayString)") }
        return true
    }

    // MARK: Toast

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    var placeholder: String {
        if mode == .ask { return "Ask about your meetings, notes, Spaces, clipboard…" }
        if let sourceFilter { return "Search \(sourceFilter.title)" }
        return "Search Spaces, meetings, Flow, clipboard and Tray"
    }
}

// MARK: - Live wiring

extension UniversalSearchController {
    /// The controller over the app's real stores. Set `openFlowHandler`
    /// afterwards to show the Flow drawer tab.
    static func live(
        flow: FlowStore,
        meetings: MeetingAssistant,
        clipboard: ClipboardController,
        tray: TrayStore,
        spaces: SpaceStore,
        dictation: DictationController
    ) -> UniversalSearchController {
        let changes = Publishers.MergeMany([
            flow.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            meetings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            clipboard.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            tray.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            spaces.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]).eraseToAnyPublisher()

        let dataSource = DataSource(
            input: { [weak flow, weak meetings, weak clipboard, weak tray, weak spaces] in
                var input = UniversalSearchCorpus.Input()
                input.flowHistory = flow?.history ?? []
                input.flowNotes = flow?.notes ?? []
                if let meetings {
                    var records = meetings.library
                    if let live = meetings.current, !records.contains(where: { $0.id == live.id }) { records.insert(live, at: 0) }
                    input.meetings = records
                }
                if let clipboard {
                    input.clipboard = clipboard.items
                    var names: [String: String] = [:]
                    for id in Set(clipboard.items.compactMap(\.sourceBundleID)) {
                        if let name = clipboard.appName(for: id) { names[id] = name }
                    }
                    input.appNames = names
                }
                input.tray = tray?.items ?? []
                input.spaceItems = spaces?.items ?? []
                input.spaces = spaces?.spaces ?? []
                return input
            },
            semanticSpaces: { [weak spaces] q in await spaces?.search(q, in: nil) ?? [] },
            changes: changes
        )

        let actions = Actions(
            openSpaceItem: { id in SpacesWindowController.shared.show(itemID: id) },
            openMeeting: { [weak meetings] id in meetings?.openNotesWindow(meetingID: id) },
            openFlow: { _ in AppLog.log("Universal Search: openFlowHandler is not set") },
            copyClipboardItem: { [weak clipboard] id in
                guard let clipboard, let item = clipboard.items.first(where: { $0.id == id }) else { return false }
                clipboard.copy(item)
                return true
            },
            pasteClipboardItem: { [weak clipboard] id in
                guard let clipboard, let item = clipboard.items.first(where: { $0.id == id }) else { return false }
                clipboard.paste(item)
                return true
            },
            revealTrayItem: { [weak tray] id in
                guard let url = tray?.items.first(where: { $0.id == id })?.url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            openTrayItem: { [weak tray] id in
                guard let url = tray?.items.first(where: { $0.id == id })?.url else { return }
                NSWorkspace.shared.open(url)
            },
            openURL: { url in NSWorkspace.shared.open(url) },
            meetingMarkdown: { [weak meetings] id in meetings?.record(id: id).map(MeetingFormat.markdown(for:)) },
            spaceItemURL: { [weak spaces] id in
                guard let url = spaces?.item(id)?.url, url.scheme == "http" || url.scheme == "https" else { return nil }
                return url
            },
            copyText: { text in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            },
            startDictation: { [weak dictation] done in dictation?.startNoteDictation(completion: done) ?? false },
            stopDictation: { [weak dictation] in dictation?.finishNoteDictation() }
        )
        return UniversalSearchController(dataSource: dataSource, actions: actions)
    }
}
