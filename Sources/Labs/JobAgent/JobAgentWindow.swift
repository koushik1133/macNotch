import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Job Agent window: tracker table with filters, notes and tailoring,
/// analytics, resume, settings. SparkV is an agent app, so it shows a
/// Dock icon only while this window is open (same as Meeting Notes).
@MainActor
final class JobAgentWindowController: NSObject, NSWindowDelegate {
    private unowned let controller: JobAgentController
    let model = JobAgentWindowModel()
    private var window: NSWindow?

    init(controller: JobAgentController) {
        self.controller = controller
        super.init()
    }

    func show(selecting id: UUID? = nil, tab: JobAgentWindowModel.Tab? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        if let tab { model.tab = tab }
        if let id {
            model.tab = .tracker
            model.select(id, in: controller.store)
        } else if model.selection == nil, let first = controller.store.jobs.first {
            model.select(first.id, in: controller.store)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = JobAgentRootView(controller: controller, store: controller.store, model: model)
        let hosting = NSHostingController(rootView: AnyView(root))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Job Agent"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        LabsBrand.styleWindow(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 980, height: 600)
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.center()
        window.setFrameAutosaveName("SparkV.JobAgent")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.flushNotes(controller)
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
final class JobAgentWindowModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case tracker = "Tracker", analytics = "Analytics", resume = "Resume", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .tracker: "tablecells"
            case .analytics: "chart.bar.xaxis"
            case .resume: "doc.text"
            case .settings: "gearshape"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest", fit = "Fit", applied = "Applied date", deadline = "Deadline", company = "Company"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .tracker
    @Published var selection: UUID? {
        didSet { if selection != oldValue { loadNotes() } }
    }
    @Published var statusFilter: JobStatus?
    @Published var search = ""
    @Published var minimumFit: Double = 0
    @Published var sort: Sort = .newest
    /// Kanban board (one column per status) instead of the table.
    @Published var showBoard = false
    @Published var notesDraft = ""
    @Published var toast: String?

    private weak var store: JobStore?
    private weak var controller: JobAgentController?
    private var notesJobID: UUID?
    private var notesTask: Task<Void, Never>?
    /// Typed but not yet saved (debounce pending).
    private var pendingNotes: (id: UUID, text: String)?

    func select(_ id: UUID, in store: JobStore) {
        self.store = store
        selection = id
    }

    func attach(_ store: JobStore) { self.store = store }

    func visibleJobs(_ jobs: [JobApplication]) -> [JobApplication] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = jobs.filter { job in
            (statusFilter == nil || job.status == statusFilter)
                && (minimumFit <= 0 || Double(job.fit?.overall ?? 0) >= minimumFit)
                && (query.isEmpty || [job.posting.company, job.posting.title, job.posting.location, job.notes]
                    .contains { $0.lowercased().contains(query) })
        }
        switch sort {
        case .newest: return filtered.sorted { $0.createdAt > $1.createdAt }
        case .fit: return filtered.sorted { ($0.fit?.overall ?? -1) > ($1.fit?.overall ?? -1) }
        case .applied: return filtered.sorted { ($0.appliedAt ?? .distantPast) > ($1.appliedAt ?? .distantPast) }
        case .deadline: return filtered.sorted { ($0.deadlineDate ?? .distantFuture) < ($1.deadlineDate ?? .distantFuture) }
        case .company: return filtered.sorted { $0.company.localizedCaseInsensitiveCompare($1.company) == .orderedAscending }
        }
    }

    private func loadNotes() {
        notesTask?.cancel()
        // Switching jobs right after typing still saves the last edit.
        if let pending = pendingNotes { controller?.setNotes(pending.id, pending.text) }
        pendingNotes = nil
        notesJobID = selection
        notesDraft = selection.flatMap { store?.job($0)?.notes } ?? ""
    }

    /// Debounced save of the notes field.
    func notesChanged(_ controller: JobAgentController) {
        guard let id = notesJobID else { return }
        self.controller = controller
        notesTask?.cancel()
        let text = notesDraft
        pendingNotes = (id, text)
        notesTask = Task { [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            controller?.setNotes(id, text)
            self?.pendingNotes = nil
        }
    }

    func flushNotes(_ controller: JobAgentController) {
        guard let id = notesJobID, let job = controller.store.job(id), job.notes != notesDraft else { return }
        notesTask?.cancel()
        pendingNotes = nil
        controller.setNotes(id, notesDraft)
    }

    func flash(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }
}

// MARK: - Root

struct JobAgentRootView: View {
    @ObservedObject var controller: JobAgentController
    @ObservedObject var store: JobStore
    @ObservedObject var model: JobAgentWindowModel
    @StateObject private var dropTarget = ViewFlag()
    @Namespace private var sidebarSelection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.3)
            Group {
                switch model.tab {
                case .tracker: JobTrackerView(controller: controller, store: store, model: model)
                case .analytics: JobAnalyticsView(store: store, controller: controller)
                case .resume: JobResumeView(controller: controller, store: store)
                case .settings: JobSettingsView(controller: controller, store: store, model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .labsWindowRoot()
        .foregroundStyle(SparkVTheme.text)
        .overlay(alignment: .bottom) {
            ZStack {
                if let toast = model.toast ?? importToast {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(SparkVTheme.background))
                        .background(Capsule().fill(SparkVTheme.surfaceHover))
                        .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                        .padding(.bottom, 16)
                        .transition(.labsToastRise)
                }
            }
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: model.toast ?? importToast)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SparkVTheme.accent.opacity(dropTarget.isOn ? 0.8 : 0), lineWidth: 2)
                .padding(4)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget.isOn) { providers in
            JobAgentDrop.load(providers) { urls in
                let images = urls.filter { JobAgentDrop.imageExtensions.contains($0.pathExtension.lowercased()) }
                if model.tab == .resume || images.isEmpty,
                   let resume = urls.first(where: { JobAgentDrop.resumeExtensions.contains($0.pathExtension.lowercased()) }) {
                    controller.importResume(resume)
                    model.tab = .resume
                } else if !images.isEmpty {
                    controller.importScreenshots(images)
                    model.flash("Importing \(images.count) screenshot\(images.count == 1 ? "" : "s")…")
                }
            }
            return true
        }
        .onAppear { model.attach(store) }
    }

    private var importToast: String? {
        if case .working(let text) = controller.phase { return text }
        return nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "briefcase.fill").foregroundStyle(SparkVTheme.choose(apple: Color(red: 0.5, green: 0.75, blue: 1), sparkv: SparkVTheme.brandRed))
                Text("Job Agent").font(SparkVTheme.title(16)).tracking(-0.3)
            }
            .padding(.top, 40).padding(.bottom, 14).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(JobAgentWindowModel.Tab.allCases) { tab in
                    JobSidebarRow(tab: tab, isSelected: model.tab == tab, selection: sidebarSelection) { model.tab = tab }
                        .padding(.horizontal, SparkVTheme.isApple ? 8 : 0)
                }
            }
            // The selection pill slides between rows: on-screen movement,
            // strong ease-in-out under 300 ms (Reduce Motion: a short fade).
            .animation(SparkVMotion.respecting(SparkVMotion.easeInOut()), value: model.tab)

            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("fn + ⌃ on a posting saves it.").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                Text("Again on the confirmation marks it applied.").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                Text("Drop screenshots anywhere here.").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
            }
            .padding(10)
        }
        .frame(width: 190)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - Tracker

struct JobTrackerView: View {
    @ObservedObject var controller: JobAgentController
    @ObservedObject var store: JobStore
    @ObservedObject var model: JobAgentWindowModel

    var body: some View {
        let rows = model.visibleJobs(store.jobs)
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                if model.showBoard {
                    JobBoardView(controller: controller, model: model, jobs: rows)
                        .frame(minWidth: 520)
                } else {
                Table(rows, selection: $model.selection) {
                    TableColumn("Company") { (job: JobApplication) in Text(job.company).lineLimit(1) }
                        .width(min: 80, ideal: 110)
                    TableColumn("Title") { (job: JobApplication) in Text(job.title).lineLimit(1) }
                        .width(min: 100, ideal: 150)
                    TableColumn("Fit") { (job: JobApplication) in
                        if let fit = job.fit {
                            Text("\(fit.overall)%").foregroundStyle(JobAgentStyle.fitColor(fit.overall)).monospacedDigit()
                        } else {
                            Text("—").foregroundStyle(Color.secondary)
                        }
                    }
                    .width(min: 40, ideal: 46)
                    TableColumn("Status") { (job: JobApplication) in
                        Label(job.status.rawValue, systemImage: job.status.symbol)
                            .foregroundStyle(JobAgentStyle.statusColor(job.status))
                    }
                    .width(min: 86, ideal: 100)
                    TableColumn("Deadline") { (job: JobApplication) in
                        HStack(spacing: 4) {
                            Text(job.deadlineDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                            if let days = job.daysUntilDeadline(), days <= 3 {
                                Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(SparkVTheme.warning)
                                    .help(days == 0 ? "Closes today" : "Closes in \(days) day\(days == 1 ? "" : "s")")
                            }
                        }
                    }
                    .width(min: 80, ideal: 92)
                    TableColumn("Applied") { (job: JobApplication) in
                        Text(job.appliedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    }
                    .width(min: 80, ideal: 92)
                    TableColumn("Expected reply") { (job: JobApplication) in
                        HStack(spacing: 4) {
                            Text(job.expectedResponseAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                            if job.status == .applied, let date = job.expectedResponseAt, date < Date() {
                                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(SparkVTheme.warning).help("Past the expected reply date")
                            }
                        }
                    }
                    .width(min: 96, ideal: 110)
                }
                .scrollContentBackground(.hidden)
                .frame(minWidth: 520)
                }
                Divider().opacity(0.3)
                Group {
                    if let id = model.selection, let job = store.job(id) {
                        JobDetailView(controller: controller, model: model, job: job)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "briefcase").font(.system(size: 30)).foregroundStyle(Color.white.opacity(0.3))
                            Text(store.jobs.isEmpty ? "No jobs yet. Hold fn + ⌃ on a job posting, or drop screenshots here."
                                 : "Select a job").font(.system(size: 12)).foregroundStyle(SparkVTheme.textTertiary)
                                .multilineTextAlignment(.center).frame(maxWidth: 260)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 380)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search company, title, notes", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            Picker("Status", selection: $model.statusFilter) {
                Text("All statuses").tag(JobStatus?.none)
                ForEach(JobStatus.allCases) { status in Text(status.rawValue).tag(JobStatus?.some(status)) }
            }
            .frame(width: 170)
            Picker("Sort", selection: $model.sort) {
                ForEach(JobAgentWindowModel.Sort.allCases) { sort in Text(sort.rawValue).tag(sort) }
            }
            .frame(width: 150)
            HStack(spacing: 4) {
                Text("Fit ≥ \(Int(model.minimumFit))").font(.system(size: 11)).monospacedDigit().frame(width: 52)
                Slider(value: $model.minimumFit, in: 0...100, step: 5).frame(width: 90)
                    .accessibilityLabel("Minimum fit")
            }
            Picker("", selection: $model.showBoard) {
                Image(systemName: "tablecells").help("Table").tag(false)
                Image(systemName: "rectangle.split.3x1").help("Board").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 76)
            .accessibilityLabel("View")
            Spacer()
            Button { pickScreenshots() } label: { Label("Import screenshots…", systemImage: "photo.on.rectangle").lineLimit(1) }
                .buttonStyle(LabsSecondaryButtonStyle())
            Menu {
                Button("Export CSV…") { exportCSV() }
                Button("Mark overdue (21+ days) as Ghosted") { controller.markOverdueAsGhosted() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 30)
                .accessibilityLabel("More")
        }
        .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 10)
    }

    private func pickScreenshots() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose screenshots of job posts or confirmation / status emails"
        guard panel.runModal() == .OK else { return }
        controller.importScreenshots(panel.urls)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Job applications.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.csv().write(to: url, atomically: true, encoding: .utf8)
            model.flash("Exported \(store.jobs.count) jobs")
        } catch {
            model.flash("Export failed: \(error.localizedDescription)")
        }
    }
}

struct JobDetailView: View {
    @ObservedObject var controller: JobAgentController
    @ObservedObject var model: JobAgentWindowModel
    let job: JobApplication

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                facts
                if let fit = job.fit { fitSection(fit) } else {
                    Text("Add your resume (Resume tab) to score this job.").font(.system(size: 12)).foregroundStyle(SparkVTheme.textSecondary)
                }
                tailoring
                notes
                if !job.confirmationEvidence.isEmpty {
                    section("Applied evidence") {
                        Text(job.confirmationEvidence).font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary)
                    }
                }
                HStack {
                    Spacer()
                    Button(role: .destructive) { confirmDelete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .padding(16)
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(job.title) @ \(job.company)?"
        alert.informativeText = "Its status history, fit report, tailoring and notes are removed. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.delete(job.id)
        model.selection = nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title).font(SparkVTheme.title(20)).tracking(-0.4).textSelection(.enabled)
            Text(job.company).font(.system(size: 14, weight: .medium)).foregroundStyle(SparkVTheme.textSecondary)
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { job.status }, set: { controller.setStatus(job.id, $0) })) {
                    ForEach(JobStatus.allCases) { status in Label(status.rawValue, systemImage: status.symbol).tag(status) }
                }
                .labelsHidden().frame(width: 140)
                .accessibilityLabel("Status")
                if job.status == .considering {
                    Button("Mark applied now") { Task { await controller.markApplied(job.id) } }
                        .buttonStyle(LabsPrimaryButtonStyle())
                }
                if let url = URL(string: job.posting.sourceURL), url.scheme?.hasPrefix("http") == true {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }.help(job.posting.sourceURL)
                }
            }
        }
    }

    private var facts: some View {
        let rows: [(String, String)] = [
            ("Location", job.posting.location), ("Salary", job.posting.salary), ("Type", job.posting.employmentType),
            ("Deadline", job.posting.deadline), ("Source", job.posting.source),
            ("Saved", job.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ("Applied", job.appliedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""),
            ("Expected reply", job.expectedResponseAt?.formatted(date: .abbreviated, time: .omitted) ?? ""),
        ].filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0).font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary).frame(width: 96, alignment: .leading)
                    Text(row.1).font(.system(size: 12)).textSelection(.enabled)
                }
            }
        }
    }

    private func fitSection(_ fit: JobFitReport) -> some View {
        section("Fit") {
            HStack(alignment: .top, spacing: 12) {
                JobFitRing(value: fit.overall, size: 54, lineWidth: 5)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fit.components) { component in
                        HStack(spacing: 6) {
                            Text(component.name).font(.system(size: 11)).frame(width: 74, alignment: .leading)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.1))
                                    if let score = component.score {
                                        Capsule().fill(JobAgentStyle.fitFill(Int(score * 100))).frame(width: proxy.size.width * score)
                                    }
                                }
                            }
                            .frame(height: 6)
                            Text(component.score.map { "\(Int(($0 * 100).rounded()))" } ?? "n/a")
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(SparkVTheme.textSecondary).frame(width: 26)
                        }
                        .help(component.detail)
                    }
                }
            }
            Text(fit.explanation).font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary).textSelection(.enabled)
            if !fit.matchingSkills.isEmpty { chips("Matching", fit.matchingSkills, SparkVTheme.success.opacity(0.22)) }
            if !fit.missingSkills.isEmpty { chips("Missing", fit.missingSkills, SparkVTheme.choose(apple: JobAgentStyle.coral.opacity(0.25), sparkv: SparkVTheme.brandRed.opacity(0.25))) }
            if !fit.missingPreferred.isEmpty { chips("Nice-to-have gaps", fit.missingPreferred, Color.white.opacity(0.1)) }
            if !fit.missingKeywords.isEmpty { chips("Keywords not in resume", Array(fit.missingKeywords.prefix(10)), Color.white.opacity(0.08)) }
        }
    }

    private var tailoring: some View {
        section("Tailor resume") {
            HStack {
                Button {
                    controller.tailor(job.id)
                } label: {
                    Label(job.tailoring.isEmpty ? "Suggest truthful edits" : "Refresh suggestions", systemImage: "wand.and.stars")
                }
                .disabled(!controller.hasResume || controller.tailoringJobID == job.id)
                if controller.tailoringJobID == job.id { ProgressView().controlSize(.small) }
            }
            Text("Only reorders, surfaces and re-words what's already in your resume. Gaps are listed, never filled in.")
                .font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
            ForEach(job.tailoring) { suggestion in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        JobChip(text: suggestion.kind.rawValue, color: suggestion.kind == .gap ? SparkVTheme.warning.opacity(0.3) : Color.white.opacity(0.14))
                        Text(suggestion.location).font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary).lineLimit(1)
                    }
                    if !suggestion.before.isEmpty, suggestion.before != suggestion.after {
                        diffLine("−", suggestion.before, SparkVTheme.choose(apple: JobAgentStyle.coral, sparkv: SparkVTheme.brandRed))
                    }
                    diffLine(suggestion.kind == .gap ? "?" : suggestion.before == suggestion.after ? "★" : "+", suggestion.after,
                             suggestion.kind == .gap ? SparkVTheme.warning : SparkVTheme.success)
                    Text(suggestion.reason).font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
            }
        }
    }

    private var notes: some View {
        section("Notes") {
            TextEditor(text: Binding(get: { model.notesDraft }, set: { model.notesDraft = $0; model.notesChanged(controller) }))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 80)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surface))
        }
    }

    private func diffLine(_ marker: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker).font(.system(size: 11, weight: .bold).monospaced()).foregroundStyle(color)
            Text(text).font(.system(size: 11)).foregroundStyle(SparkVTheme.text).textSelection(.enabled)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.10)))
    }

    private func chips(_ title: String, _ items: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(SparkVTheme.textTertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in JobChip(text: item, color: color) }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(SparkVTheme.eyebrow()).tracking(1.2).foregroundStyle(SparkVTheme.textTertiary)
            content()
        }
    }
}

// MARK: - Analytics

struct JobAnalyticsView: View {
    @ObservedObject var store: JobStore
    @ObservedObject var controller: JobAgentController

    var body: some View {
        let a = store.analytics
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Analytics").font(.system(size: 20, weight: .bold)).padding(.top, 30)
                HStack(spacing: 12) {
                    tile("Tracked", "\(a.totalTracked)")
                    tile("Applied", "\(a.totalApplied)")
                    tile("Response rate", a.totalApplied == 0 ? "–" : "\(Int((a.responseRate * 100).rounded()))%")
                    tile("Avg fit (applied)", a.averageFitApplied.map { "\(Int($0.rounded()))%" } ?? "–")
                    tile("Interviews", "\(a.interviews)")
                    tile("Overdue", "\(a.overdue)")
                    tile("Closing ≤ 7 days", "\(a.closingSoon)")
                }
                card("Applications per week") { weekly(a.weeks) }
                HStack(alignment: .top, spacing: 14) {
                    card("Status funnel") { funnel(a.funnel) }
                    card("Top missing skills (applied jobs)") { missing(a.topMissingSkills) }
                }
                card("By status") {
                    HStack(spacing: 14) {
                        ForEach(JobStatus.allCases) { status in
                            Label("\(status.rawValue) \(a.statusCounts[status] ?? 0)", systemImage: status.symbol)
                                .font(.system(size: 12)).foregroundStyle(JobAgentStyle.statusColor(status))
                        }
                    }
                }
                Text("Response rate counts interviews, offers and rejections among applied jobs. Ghosted and pending don't count as replies.")
                    .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit())
            Text(title).font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
    }

    private func weekly(_ weeks: [JobAnalytics.Week]) -> some View {
        let peak = max(1, weeks.map(\.count).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(weeks) { week in
                VStack(spacing: 4) {
                    Text(week.count == 0 ? "" : "\(week.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(SparkVTheme.textSecondary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(week.count == 0 ? SparkVTheme.surfaceHover : SparkVTheme.choose(apple: JobAgentStyle.blue.opacity(0.85), sparkv: SparkVTheme.brandRed))
                        .frame(height: max(3, CGFloat(week.count) / CGFloat(peak) * 110))
                    Text(week.start.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 9)).foregroundStyle(SparkVTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150, alignment: .bottom)
    }

    private func funnel(_ stages: [JobAnalytics.FunnelStage]) -> some View {
        let top = max(1, stages.first?.count ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(stages) { stage in
                HStack(spacing: 8) {
                    Text(stage.name).font(.system(size: 11)).frame(width: 72, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(SparkVTheme.choose(apple: JobAgentStyle.purple.opacity(0.75), sparkv: SparkVTheme.brandRed.opacity(0.85)))
                            .frame(width: max(2, proxy.size.width * CGFloat(stage.count) / CGFloat(top)))
                    }
                    .frame(height: 14)
                    Text("\(stage.count)").font(.system(size: 11).monospacedDigit()).frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    private func missing(_ skills: [(skill: String, count: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if skills.isEmpty {
                Text("No gaps recorded yet.").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
            }
            ForEach(skills, id: \.skill) { item in
                HStack {
                    Text(item.skill).font(.system(size: 12))
                    Spacer()
                    Text("\(item.count) job\(item.count == 1 ? "" : "s")").font(.system(size: 11).monospacedDigit()).foregroundStyle(SparkVTheme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Resume

struct JobResumeView: View {
    @ObservedObject var controller: JobAgentController
    @ObservedObject var store: JobStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Resume").font(SparkVTheme.title(24)).tracking(-0.5).padding(.top, 30)
                HStack(spacing: 12) {
                    Button { pickResume() } label: {
                        Label(store.profile == nil ? "Choose resume (PDF, DOCX, TXT)…" : "Replace resume…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(LabsPrimaryButtonStyle())
                    switch controller.phase {
                    case .working(let text): HStack { ProgressView().controlSize(.small); Text(text).font(.system(size: 12)) }
                    case .failed(let text): Text(text).font(.system(size: 12)).foregroundStyle(LabsTint.errorText)
                    default: EmptyView()
                    }
                }
                Text("Text is extracted on this Mac and stored only in ~/Library/Application Support/SparkV/Jobs. You can also drop the file on this window.")
                    .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                if let profile = store.profile {
                    profileView(profile)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .frame(height: 160)
                        .overlay(Text("Drop your resume here").foregroundStyle(SparkVTheme.textTertiary))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    private func profileView(_ profile: ResumeProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(profile.name.isEmpty ? "Your profile" : profile.name).font(.system(size: 17, weight: .semibold))
                if !profile.headline.isEmpty { Text(profile.headline).foregroundStyle(SparkVTheme.textSecondary) }
                Spacer()
                Text("\(profile.fileName) · extracted by \(profile.source)").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
            }
            if let years = profile.yearsExperience {
                Text("About \(JobFitScorer.format(years)) years of experience").font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("SKILLS (\(profile.skills.count))").font(SparkVTheme.eyebrow()).tracking(1.2).foregroundStyle(SparkVTheme.textTertiary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 5, alignment: .leading)], alignment: .leading, spacing: 5) {
                    ForEach(profile.skills, id: \.self) { JobChip(text: $0) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("EXPERIENCE").font(SparkVTheme.eyebrow()).tracking(1.2).foregroundStyle(SparkVTheme.textTertiary)
                ForEach(profile.experience) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([role.title, role.company].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12, weight: .semibold))
                        Text("\(role.start) – \(role.end)").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                        ForEach(role.highlights, id: \.self) { Text("• \($0)").font(.system(size: 11)).foregroundStyle(SparkVTheme.text.opacity(0.9)) }
                    }
                }
                if profile.experience.isEmpty {
                    Text("No dated roles found. Fit still uses your skills; experience isn't scored.").font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("EDUCATION").font(SparkVTheme.eyebrow()).tracking(1.2).foregroundStyle(SparkVTheme.textTertiary)
                ForEach(profile.education) { entry in
                    Text([entry.degree, entry.school, entry.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12))
                }
            }
        }
    }

    private func pickResume() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.pdf, .plainText, .rtf]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let doc = UTType(filenameExtension: "doc") { types.append(doc) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.importResume(url)
    }
}

// MARK: - Settings

struct JobSettingsView: View {
    @ObservedObject var controller: JobAgentController
    @ObservedObject var store: JobStore
    @ObservedObject var model: JobAgentWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(SparkVTheme.title(24)).tracking(-0.5).padding(.top, 30)
                group("Hotkey") {
                    Toggle("fn + Control captures the current page", isOn: $controller.hotkeyEnabled)
                    Text(controller.hotkeyAvailable ? "Accessibility is granted." : "Needs Accessibility (already used by dictation and Clicky).")
                        .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                    Text("Screen Recording: \(JobScreenCapture.hasPermission ? "granted" : "not granted — allow it in System Settings › Privacy & Security")")
                        .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                    if let browser = controller.browserNeedingAccess {
                        Button("Allow reading the page URL from \(browser.name)") { controller.requestBrowserAccess() }
                    }
                }
                group("Analysis") {
                    Toggle("Use Apple's on-device model to refine extraction", isOn: $controller.useOnDeviceModel)
                    Text("On-device model: \(controller.onDeviceStatus). Rules and the skills dictionary always run.")
                        .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                    Toggle("Use Groq for job analysis", isOn: $controller.useGroq)
                    Text(controller.groqKeyPresent
                         ? "Off by default. When on, the extracted posting/resume text (never screenshots) is sent to api.groq.com with your Clicky Groq key."
                         : "Needs a Groq key (set it in Clicky). Off by default; text only, never screenshots.")
                        .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                }
                group("Reminders") {
                    Toggle("Remind me on the expected reply date", isOn: $controller.remindersEnabled)
                    Text("Only when SparkV notifications are already allowed; the Job Agent never asks for permission. Greenhouse/Lever/Ashby +7 days, LinkedIn/Indeed +10, Workday/iCIMS/Taleo and others +14.")
                        .font(.system(size: 11)).foregroundStyle(SparkVTheme.textTertiary)
                }
                group("Data") {
                    Text(store.directory.path).font(.system(size: 11).monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
                        Button("Delete all job data…", role: .destructive) { confirmDelete() }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            .toggleStyle(.switch)
            .tint(SparkVTheme.accent)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete all tracked jobs and your stored resume?"
        alert.informativeText = "This removes jobs.json, profile.json and resume.txt. It can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for job in store.jobs { JobReminders.cancel(job.reminderID) }
        store.deleteAll()
        model.selection = nil
    }
}

// MARK: - Board

/// Kanban board: one column per status. Drag a card to another column (or
/// use its menu) to move it; click to open it in the detail pane.
struct JobBoardView: View {
    @ObservedObject var controller: JobAgentController
    @ObservedObject var model: JobAgentWindowModel
    let jobs: [JobApplication]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(JobStatus.allCases) { status in column(status) }
            }
            .padding(12)
        }
    }

    private func column(_ status: JobStatus) -> some View {
        let items = jobs.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.symbol).foregroundStyle(JobAgentStyle.statusColor(status))
                Text(status.rawValue).font(.system(size: 12, weight: .semibold))
                Text("\(items.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(SparkVTheme.textTertiary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { job in card(job) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(width: 172)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(Color.white.opacity(0.04)))
        .dropDestination(for: String.self) { ids, _ in
            let moved = ids.compactMap(UUID.init(uuidString:))
            for id in moved { controller.setStatus(id, status) }
            return !moved.isEmpty
        }
    }

    private func card(_ job: JobApplication) -> some View {
        let selected = model.selection == job.id
        return HStack(alignment: .top, spacing: 8) {
            if let fit = job.fit { JobFitRing(value: fit.overall, size: 26, lineWidth: 3) }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                Text(job.company).font(.system(size: 10)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
                if let days = job.daysUntilDeadline() {
                    Text(days == 0 ? "Closes today" : "Closes in \(days)d").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(days <= 3 ? SparkVTheme.warning : SparkVTheme.textTertiary)
                } else if let applied = job.appliedAt {
                    Text("Applied \(applied.formatted(.dateTime.month(.abbreviated).day()))").font(.system(size: 9))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(selected ? SparkVTheme.accentSoft : SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.accent.opacity(selected ? 0.8 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = job.id }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selection = job.id }
        .draggable(job.id.uuidString)
        .contextMenu {
            Menu("Move to") {
                ForEach(JobStatus.allCases.filter { $0 != job.status }) { status in
                    Button(status.rawValue) { controller.setStatus(job.id, status) }
                }
            }
        }
    }
}

/// One Job Agent sidebar row: the selection pill is a single shape that
/// moves between rows (matched geometry), other rows get the soft hover fill.
private struct JobSidebarRow: View {
    let tab: JobAgentWindowModel.Tab
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Label {
                Text(tab.rawValue)
            } icon: {
                // Apple: fixed-width icons so the titles line up, as in a macOS sidebar.
                Image(systemName: tab.symbol).frame(width: SparkVTheme.isApple ? 18 : nil)
            }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .sparkVHoverFill(hover.isOn && !isSelected, cornerRadius: SparkVTheme.cornerSmall)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                            .fill(LabsTint.selectionFill)
                            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(LabsTint.selectionStroke))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}
