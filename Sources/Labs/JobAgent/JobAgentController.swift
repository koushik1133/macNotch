import AppKit
import Combine
import SwiftUI

/// Job Search Operations Agent.
///
/// - fn + Control (hold both, release) on a job posting: captures the front
///   window, reads the browser URL/title, OCRs, extracts the posting, scores
///   fit against the stored resume, saves it as "Considering" and shows the
///   result under the notch.
/// - The same chord on a confirmation page ("Application submitted", "Thanks
///   for applying", "Your application was sent to …"): verifies it is the
///   same job and marks it "Applied" with an expected response date.
/// - Screenshots of postings or emails can be dropped in to add/update jobs.
///
/// Everything runs on-device by default. Groq is used only behind its own
/// "Use Groq for job analysis" setting (off by default), with text only.
@MainActor
final class JobAgentController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    /// A confirmation that couldn't be tied to a job automatically.
    struct PendingConfirmation: Equatable {
        var jobID: UUID
        var message: String
        var evidence: String
    }

    @Published private(set) var phase: Phase = .idle
    /// The job captured by the last first press (what a second press verifies against).
    @Published private(set) var activeJobID: UUID?
    @Published private(set) var pendingConfirmation: PendingConfirmation?
    /// Browser that needs the Automation consent before its URL can be read.
    @Published private(set) var browserNeedingAccess: (bundleID: String, name: String)?
    @Published private(set) var importLog: [String] = []
    @Published private(set) var tailoringJobID: UUID?

    @Published var hotkeyEnabled: Bool = JobAgentSettings.hotkeyEnabled {
        didSet {
            JobAgentSettings.hotkeyEnabled = hotkeyEnabled
            if hotkeyEnabled { hotkey.start() } else { hotkey.stop() }
        }
    }
    @Published var useGroq: Bool = JobAgentSettings.useGroq {
        didSet {
            JobAgentSettings.useGroq = useGroq
            AppLog.log("Job Agent: Groq \(useGroq ? "allowed" : "not allowed")")
        }
    }
    @Published var useOnDeviceModel: Bool = JobAgentSettings.useOnDeviceModel {
        didSet { JobAgentSettings.useOnDeviceModel = useOnDeviceModel }
    }
    @Published var remindersEnabled: Bool = JobAgentSettings.reminders {
        didSet { JobAgentSettings.reminders = remindersEnabled }
    }

    let store: JobStore
    private unowned let activities: ActivityCenter
    private let hotkey = JobHotkeyMonitor()
    private let browser = JobBrowserBridge()
    private var task: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private lazy var windowController = JobAgentWindowController(controller: self)
    private var started = false
    /// Refreshes `hotkeyAvailable` when Accessibility changes (PermissionCenter
    /// observes the system; nothing polls here). Screen Recording needs a
    /// restart to change, so it isn't watched.
    private var accessibilityWatch: AnyCancellable?

    static let activityID = "jobAgent"

    /// `storeDirectory` is for tests; the app uses ~/Library/Application Support/SparkV/Jobs.
    init(activities: ActivityCenter, storeDirectory: URL? = nil) {
        self.activities = activities
        self.store = JobStore(directory: storeDirectory)
        hotkey.onTrigger = { [weak self] in self?.hotkeyFired() }
    }

    func start() {
        guard !started else { return }
        started = true
        store.load()
        if hotkeyEnabled { hotkey.start() }
        accessibilityWatch = PermissionCenter.shared.onChange(of: .accessibility) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func stop() {
        started = false
        accessibilityWatch = nil
        hotkey.stop()
        task?.cancel()
        task = nil
        refineTask?.cancel()
        refineTask = nil
    }

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    var hasResume: Bool { store.profile != nil }
    var hotkeyAvailable: Bool { JobHotkeyMonitor.isTrusted }
    var groqKeyPresent: Bool { ClickyKeychain.hasKey() }
    var onDeviceStatus: String { MeetingAIBackend.onDeviceUnavailableReason.map { "Unavailable: \($0)" } ?? "Available" }

    var activeJob: JobApplication? {
        activeJobID.flatMap(store.job) ?? store.jobs.first
    }

    // MARK: Window

    func showWindow(selecting id: UUID? = nil, tab: JobAgentWindowModel.Tab? = nil) {
        windowController.show(selecting: id, tab: tab)
    }

    // MARK: Hotkey

    func hotkeyFired() {
        guard !isBusy else { return }
        AppLog.log("Job Agent: fn+Control")
        task = Task { [weak self] in await self?.captureScreen() }
    }

    /// Also callable from a menu item / button.
    func captureNow() { hotkeyFired() }

    private func captureScreen() async {
        setPhase(.working("Reading the page…"))
        let captured: JobCapturedWindow
        do {
            captured = try await JobScreenCapture.captureFrontWindow()
        } catch {
            fail(error.localizedDescription)
            return
        }
        var page: JobBrowserPage?
        switch await browser.current(bundleID: captured.bundleID) {
        case .page(let value):
            page = value
            if browserNeedingAccess?.bundleID == captured.bundleID { browserNeedingAccess = nil }
        case .needsConsent(let name), .denied(let name):
            browserNeedingAccess = (captured.bundleID, name)
        case .notBrowser, .unavailable:
            break
        }
        let ocr = await JobOCR.recognize(JobImageBox(image: captured.image))
        guard !Task.isCancelled else { return }
        guard !ocr.isEmpty else {
            fail(ocr.error.map { "Couldn't read the screen (\($0))" } ?? "No text found on screen")
            return
        }
        await handleCapturedText(ocr: ocr, url: page?.url ?? "", pageTitle: page?.title ?? "", date: Date(), fromScreenshot: false)
    }

    // MARK: Routing

    /// Feeds already-read page text through the same path as a capture
    /// (posting → Considering, confirmation → Applied, status email → update).
    func ingest(text: String, url: String = "", pageTitle: String = "", date: Date = Date()) async {
        let lines = text.components(separatedBy: "\n").map { JobOCRLine(text: $0, rect: .zero, confidence: 1) }
        await handleCapturedText(ocr: JobOCRResult(lines: lines, pixelSize: .zero), url: url, pageTitle: pageTitle,
                                 date: date, fromScreenshot: false)
    }

    /// Imports resume text directly (tests, paste).
    func importResumeText(_ text: String, fileName: String = "pasted.txt") async {
        var profile = JobResumeParser.parse(text, fileName: fileName)
        profile = await JobAI.refineProfile(profile, text: text, options: .current())
        store.setResume(text: text, profile: profile)
        rescoreAll()
    }

    private func handleCapturedText(ocr: JobOCRResult, url: String, pageTitle: String, date: Date, fromScreenshot: Bool) async {
        let detection = JobConfirmation.detect(text: ocr.text, url: url)
        switch detection.kind {
        case .confirmation:
            await handleConfirmation(text: ocr.text, url: url, pageTitle: pageTitle, detection: detection, date: date)
        case .rejection, .interview, .offer:
            handleStatusEmail(text: ocr.text, url: url, pageTitle: pageTitle, detection: detection, date: date)
        case .none:
            await handlePosting(ocr: ocr, url: url, pageTitle: pageTitle, fromScreenshot: fromScreenshot)
        }
    }

    // MARK: First press: posting

    private func handlePosting(ocr: JobOCRResult, url: String, pageTitle: String, fromScreenshot: Bool) async {
        let posting = JobPostingParser.parse(text: ocr.text, lines: ocr.lines, url: url, pageTitle: pageTitle)
        guard posting.postingConfidence >= 0.3 || (!posting.title.isEmpty && !posting.requiredSkills.isEmpty) else {
            fail("This doesn't look like a job posting or a confirmation page")
            return
        }
        // Pressed again on the posting it just saved (before applying).
        if !fromScreenshot, let active = activeJobID.flatMap(store.job), active.status == .considering,
           let existing = store.existing(matching: posting), existing.id == active.id,
           Date().timeIntervalSince(active.createdAt) < 6 * 3600 {
            succeed("Still on \(active.title) — press fn+⌃ again after you submit", subtitle: fitLine(active))
            return
        }
        // Rules first so the band answers at once; a model refines it afterwards.
        let id = save(posting)
        activeJobID = id
        pendingConfirmation = nil
        guard let job = store.job(id) else { return }
        announce(job)
        AppLog.log("Job Agent: saved posting (\(posting.source.isEmpty ? "web" : posting.source), fit \(job.fit?.overall ?? -1))")

        let options = JobAI.Options.current()
        guard options.engine != .rules else { return }
        refineTask?.cancel()
        refineTask = Task { [weak self] in
            let refined = await JobAI.refinePosting(posting, options: options)
            guard let self, !Task.isCancelled, refined != posting, self.store.job(id) != nil else { return }
            let before = self.store.job(id)
            let fit = self.store.profile.map { JobFitScorer.score(profile: $0, resumeText: self.store.resumeText, posting: refined) }
            self.store.update(id) { job in
                job.posting = refined
                if let fit { job.fit = fit }
            }
            guard let after = self.store.job(id), self.activeJobID == id, !self.isBusy else { return }
            let fitChanged = abs((after.fit?.overall ?? 0) - (before?.fit?.overall ?? 0)) >= 3
            let namesFilled = (before?.posting.company.isEmpty == true && !after.posting.company.isEmpty)
                || (before?.posting.title.isEmpty == true && !after.posting.title.isEmpty)
            if fitChanged || namesFilled { self.announce(after) }
            AppLog.log("Job Agent: refined posting with \(options.engine.rawValue)")
        }
    }

    /// Saves a new job or updates the matching one (keeping its status); returns its id.
    private func save(_ posting: JobPosting) -> UUID {
        let fit = store.profile.map { JobFitScorer.score(profile: $0, resumeText: store.resumeText, posting: posting) }
        if let existing = store.existing(matching: posting) {
            store.update(existing.id) { job in
                job.posting = posting
                job.fit = fit ?? job.fit
            }
            return existing.id
        }
        var job = JobApplication(posting: posting)
        job.fit = fit
        job.history = [JobStatusChange(status: .considering, date: Date())]
        store.add(job)
        return job.id
    }

    private func announce(_ job: JobApplication) {
        let headline = "\(job.title) @ \(job.company)"
        if let fit = job.fit {
            let missing = fit.missingSkills.prefix(3).joined(separator: ", ")
            succeed("Fit \(fit.overall)% · \(headline)", subtitle: missing.isEmpty ? "No missing required skills" : "missing: \(missing)",
                    fit: fit.overall)
        } else {
            succeed("Saved \(headline)", subtitle: "Add your resume in Job Agent to see your fit")
        }
    }

    // MARK: Second press: confirmation

    private func handleConfirmation(text: String, url: String, pageTitle: String, detection: JobConfirmation.Detection, date: Date) async {
        let candidates = confirmationCandidates()
        // The same confirmation captured again for a job that is already past "Considering".
        let tracked = store.jobs.filter { $0.status != .considering }.first { job in
            if case .same = JobConfirmation.verify(job: job.posting, confirmationText: text, url: url, pageTitle: pageTitle, detection: detection) { return true }
            return false
        }
        if let tracked, !candidates.contains(where: { candidate in
            if case .same = JobConfirmation.verify(job: candidate.posting, confirmationText: text, url: url, pageTitle: pageTitle, detection: detection) { return true }
            return false
        }) {
            activeJobID = tracked.id
            succeed("Already \(tracked.status.rawValue) · \(tracked.title) @ \(tracked.company)", subtitle: "Nothing changed")
            return
        }
        guard !candidates.isEmpty else {
            fail("Looks like an application confirmation, but there's no saved job to match. Capture the posting first.")
            return
        }
        var firstVerdict: (JobApplication, JobConfirmation.Verdict)?
        for job in candidates {
            let verdict = JobConfirmation.verify(job: job.posting, confirmationText: text, url: url, pageTitle: pageTitle, detection: detection)
            if firstVerdict == nil { firstVerdict = (job, verdict) }
            if case .same(_, let reason) = verdict {
                await markApplied(job.id, at: date, evidence: "\(detection.evidence.joined(separator: ", ")) — \(reason)")
                return
            }
        }
        guard let (job, verdict) = firstVerdict else { return }
        switch verdict {
        case .different(let reason):
            fail("Not marked: \(reason)")
        case .uncertain(let reason):
            pendingConfirmation = PendingConfirmation(jobID: job.id, message: reason, evidence: detection.evidence.joined(separator: ", "))
            fail("Confirmation found, but can't tell which job. Open Job Agent to mark \(job.title) applied.")
        case .same:
            break
        }
    }

    /// The active job first, then other "Considering" jobs from the last 30 days, newest first.
    private func confirmationCandidates() -> [JobApplication] {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        var list = store.jobs.filter { $0.status == .considering && $0.createdAt > cutoff }
            .sorted { $0.createdAt > $1.createdAt }
        if let active = activeJobID, let index = list.firstIndex(where: { $0.id == active }) {
            list.insert(list.remove(at: index), at: 0)
        }
        return list
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        Task { await markApplied(pending.jobID, at: Date(), evidence: "Confirmed by you — \(pending.evidence)") }
    }

    func dismissPending() { pendingConfirmation = nil }

    func markApplied(_ id: UUID, at date: Date = Date(), evidence: String = "Marked by you") async {
        guard let job = store.job(id) else { return }
        let days = JobConfirmation.expectedResponseDays(source: job.posting.source)
        let expected = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        JobReminders.cancel(job.reminderID)
        let reminder = await JobReminders.schedule(company: job.company, title: job.title, on: expected)
        store.update(id) { job in
            job.setStatus(.applied, at: date, note: evidence)
            job.appliedAt = date
            job.expectedResponseAt = expected
            job.confirmationEvidence = evidence
            job.reminderID = reminder
        }
        activeJobID = id
        let formatted = expected.formatted(.dateTime.month(.abbreviated).day())
        succeed("Applied ✓ \(job.title) @ \(job.company)", subtitle: "Expect a reply by \(formatted)\(reminder == nil ? "" : " · reminder set")")
        AppLog.log("Job Agent: marked applied (\(job.posting.source), +\(days)d)")
    }

    // MARK: Status emails

    private func handleStatusEmail(text: String, url: String, pageTitle: String, detection: JobConfirmation.Detection, date: Date) {
        let status: JobStatus = detection.kind == .rejection ? .rejected : detection.kind == .interview ? .interview : .offer
        let match = store.jobs
            .map { ($0, JobConfirmation.verify(job: $0.posting, confirmationText: text, url: url, pageTitle: pageTitle, detection: detection)) }
            .compactMap { pair -> (JobApplication, Double)? in
                if case .same(let confidence, _) = pair.1 { return (pair.0, confidence) }
                return nil
            }
            .max { $0.1 < $1.1 }?.0
        guard let job = match else {
            fail("Found a\(status == .interview ? "n interview" : status == .offer ? "n offer" : " rejection") message, but it doesn't match a tracked job")
            return
        }
        store.update(job.id) { $0.setStatus(status, at: date, note: detection.evidence.joined(separator: ", ")) }
        if status != .applied { JobReminders.cancel(job.reminderID) }
        succeed("\(status.rawValue) · \(job.title) @ \(job.company)", subtitle: "Updated from the message")
    }

    // MARK: Screenshots

    func importScreenshots(_ urls: [URL]) {
        let images = urls.filter { JobAgentDrop.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return }
        // Runs after a capture or import already in progress instead of racing it.
        let previous = task
        task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            var log: [String] = []
            for (index, url) in images.enumerated() {
                self.setPhase(.working("Reading screenshot \(index + 1) of \(images.count)…"))
                let date = JobOCR.captureDate(of: url) ?? Date()
                let ocr = await Task.detached(priority: .userInitiated) { () -> JobOCRResult? in
                    guard let image = JobOCR.loadImage(at: url) else { return nil }
                    return JobOCR.recognizeSync(image)
                }.value
                guard let ocr, !ocr.isEmpty else {
                    log.append("\(url.lastPathComponent): no text found")
                    continue
                }
                await self.handleCapturedText(ocr: ocr, url: "", pageTitle: "", date: date, fromScreenshot: true)
                log.append("\(url.lastPathComponent): \(self.phaseText)")
            }
            self.importLog = log
        }
    }

    var phaseText: String {
        switch phase {
        case .idle: ""
        case .working(let text), .done(let text), .failed(let text): text
        }
    }

    // MARK: Resume

    func importResume(_ url: URL) {
        let previous = task
        task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            self.setPhase(.working("Reading \(url.lastPathComponent)…"), post: false)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try JobResumeFile.extractText(from: url) }
            }.value
            switch result {
            case .failure(let error):
                self.fail(error.localizedDescription, post: false)
            case .success(let text):
                var profile = JobResumeParser.parse(text, fileName: url.lastPathComponent)
                self.setPhase(.working("Extracting skills and experience…"), post: false)
                profile = await JobAI.refineProfile(profile, text: text, options: .current())
                self.store.setResume(text: text, profile: profile)
                self.rescoreAll()
                self.succeed("Resume added: \(profile.skills.count) skills, \(profile.experience.count) roles", subtitle: nil, post: false)
            }
        }
    }

    /// Re-runs fit for every job (after a new resume).
    func rescoreAll() {
        guard let profile = store.profile else { return }
        let resumeText = store.resumeText
        store.updateAll { $0.fit = JobFitScorer.score(profile: profile, resumeText: resumeText, posting: $0.posting) }
    }

    // MARK: Tailoring

    func tailor(_ id: UUID) {
        guard let profile = store.profile, let job = store.job(id) else { return }
        tailoringJobID = id
        Task { [weak self] in
            guard let self else { return }
            let fit = job.fit ?? JobFitScorer.score(profile: profile, resumeText: self.store.resumeText, posting: job.posting)
            var suggestions = JobTailor.suggestions(profile: profile, resumeText: self.store.resumeText, posting: job.posting, fit: fit)
            // Optional model rewording of the most relevant bullets, kept only when grounded.
            let options = JobAI.Options.current()
            if options.engine != .rules {
                let keywords = fit.matchedKeywords + job.posting.requiredSkills
                let bullets = profile.experience.flatMap(\.highlights)
                    .sorted { JobTailor.relevance($0, skills: job.posting.requiredSkills, keywords: keywords) > JobTailor.relevance($1, skills: job.posting.requiredSkills, keywords: keywords) }
                    .prefix(3)
                for bullet in bullets {
                    if let rewrite = await JobAI.reword(bullet, keywords: keywords, resumeText: self.store.resumeText, options: options) {
                        suggestions.append(TailorSuggestion(kind: .reword, location: "Experience", before: bullet, after: rewrite,
                                                            reason: "Same facts, closer to the posting's wording (checked: no new skills or numbers)."))
                    }
                }
            }
            self.store.update(id) { $0.tailoring = suggestions }
            self.tailoringJobID = nil
        }
    }

    // MARK: Editing

    func setStatus(_ id: UUID, _ status: JobStatus) {
        guard let job = store.job(id) else { return }
        if status == .applied, job.appliedAt == nil {
            Task { await markApplied(id) }
            return
        }
        store.update(id) { $0.setStatus(status) }
        if status != .applied { JobReminders.cancel(job.reminderID) }
    }

    func setNotes(_ id: UUID, _ notes: String) {
        store.update(id) { $0.notes = notes }
    }

    func delete(_ id: UUID) {
        JobReminders.cancel(store.job(id)?.reminderID)
        store.delete(id)
        if activeJobID == id { activeJobID = nil }
    }

    /// Applied jobs past their expected date by `days` with no reply → Ghosted.
    func markOverdueAsGhosted(olderThan days: Int = 21) {
        let now = Date()
        store.updateAll { job in
            guard job.status == .applied, let expected = job.expectedResponseAt,
                  now.timeIntervalSince(expected) > Double(days) * 86400 else { return }
            JobReminders.cancel(job.reminderID)
            job.setStatus(.ghosted, note: "No reply \(days) days after the expected date")
        }
    }

    func requestBrowserAccess() {
        guard let target = browserNeedingAccess else { return }
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.browser.requestAccess(bundleID: target.bundleID)
            if granted { self.browserNeedingAccess = nil }
            AppLog.log("Job Agent: \(target.name) automation \(granted ? "allowed" : "not allowed")")
        }
    }

    // MARK: Band

    private func fitLine(_ job: JobApplication) -> String? {
        guard let fit = job.fit else { return nil }
        return "Fit \(fit.overall)%" + (fit.missingSkills.isEmpty ? "" : " · missing: \(fit.missingSkills.prefix(3).joined(separator: ", "))")
    }

    private func setPhase(_ phase: Phase, post: Bool = true) {
        self.phase = phase
        guard post, case .working(let text) = phase else { return }
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 75, duration: 30) {
            JobAgentBandView(title: text, subtitle: nil, fit: nil, style: .working)
        })
    }

    private func succeed(_ title: String, subtitle: String?, fit: Int? = nil, post: Bool = true) {
        phase = .done(subtitle.map { "\(title) — \($0)" } ?? title)
        guard post else { return }
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 75, duration: 7,
                                     height: subtitle == nil ? NotchMetrics.activityBandHeight : NotchMetrics.activityAnswerBandHeight) {
            JobAgentBandView(title: title, subtitle: subtitle, fit: fit, style: .success)
        })
    }

    private func fail(_ message: String, post: Bool = true) {
        phase = .failed(message)
        AppLog.log("Job Agent: \(message)")
        guard post else { return }
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 75, duration: 6,
                                     height: NotchMetrics.activityAnswerBandHeight) {
            JobAgentBandView(title: "Job Agent", subtitle: message, fit: nil, style: .failure)
        })
    }
}
