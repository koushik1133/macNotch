import AppKit
import Foundation

/// Local-only persistence: ~/Library/Application Support/SparkV/Jobs
/// - jobs.json      tracked applications
/// - profile.json   structured resume profile
/// - resume.txt     extracted resume text (the original file is not copied)
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [JobApplication] = []
    @Published private(set) var profile: ResumeProfile?
    @Published private(set) var resumeText: String = ""

    let directory: URL
    private let writeQueue = DispatchQueue(label: "SparkV.JobStore", qos: .utility)

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Jobs", isDirectory: true)
    }

    private var jobsURL: URL { directory.appendingPathComponent("jobs.json") }
    private var profileURL: URL { directory.appendingPathComponent("profile.json") }
    private var resumeURL: URL { directory.appendingPathComponent("resume.txt") }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: jobsURL) {
            do {
                jobs = try Self.decoder.decode([JobApplication].self, from: data)
            } catch {
                // Keep the unreadable file for recovery instead of overwriting it.
                let backup = directory.appendingPathComponent("jobs.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: jobsURL, to: backup)
                AppLog.log("Job Agent: jobs.json unreadable (\(error)); kept a copy")
            }
        }
        if let data = try? Data(contentsOf: profileURL) { profile = try? Self.decoder.decode(ResumeProfile.self, from: data) }
        resumeText = (try? String(contentsOf: resumeURL, encoding: .utf8)) ?? ""
        AppLog.log("Job Agent: loaded \(jobs.count) job(s), resume \(profile == nil ? "missing" : "present")")
    }

    // MARK: Jobs

    func job(_ id: UUID) -> JobApplication? { jobs.first { $0.id == id } }

    func add(_ job: JobApplication) {
        jobs.insert(job, at: 0)
        saveJobs()
    }

    func update(_ id: UUID, _ change: (inout JobApplication) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        saveJobs()
    }

    /// Changes every job with one save (rescoring after a new resume).
    func updateAll(_ change: (inout JobApplication) -> Void) {
        guard !jobs.isEmpty else { return }
        for index in jobs.indices { change(&jobs[index]) }
        saveJobs()
    }

    func delete(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        saveJobs()
    }

    func deleteAll() {
        jobs = []
        profile = nil
        resumeText = ""
        // On the write queue, after any save still pending, so it can't recreate a file.
        let urls = [jobsURL, profileURL, resumeURL]
        writeQueue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Waits for queued writes (tests).
    func flush() { writeQueue.sync {} }

    /// An existing job that is the same posting (same ATS job id, same URL, or same company + title).
    func existing(matching posting: JobPosting) -> JobApplication? {
        let info = JobPostingParser.urlInfo(posting.sourceURL)
        return jobs.first { job in
            if !posting.sourceURL.isEmpty, job.posting.sourceURL == posting.sourceURL { return true }
            if !info.jobID.isEmpty, job.posting.jobID == info.jobID, JobPostingParser.urlInfo(job.posting.sourceURL).host == info.host { return true }
            return !posting.company.isEmpty && !posting.title.isEmpty
                && JobConfirmation.companySimilarity(job.posting.company, posting.company) >= 0.85
                && JobFitScorer.titleSimilarity(job.posting.title, posting.title) >= 0.85
                && job.posting.title.lowercased() == posting.title.lowercased()
        }
    }

    // MARK: Resume

    func setResume(text: String, profile: ResumeProfile) {
        resumeText = text
        self.profile = profile
        write(Data(text.utf8), to: resumeURL)
        if let data = try? Self.encoder.encode(profile) { write(data, to: profileURL) }
    }

    // MARK: Analytics / export

    var analytics: JobAnalytics { JobAnalytics.compute(jobs) }

    func csv() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        func field(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["company,title,status,location,salary,source,url,applied,expected_response,fit,missing_skills,notes"]
        for job in jobs {
            rows.append([
                field(job.posting.company), field(job.posting.title), job.status.rawValue, field(job.posting.location),
                field(job.posting.salary), field(job.posting.source), field(job.posting.sourceURL),
                job.appliedAt.map(formatter.string(from:)) ?? "", job.expectedResponseAt.map(formatter.string(from:)) ?? "",
                job.fit.map { String($0.overall) } ?? "", field((job.fit?.missingSkills ?? []).joined(separator: "; ")), field(job.notes),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    // MARK: Writing

    private func saveJobs() {
        guard let data = try? Self.encoder.encode(jobs) else { return }
        write(data, to: jobsURL)
    }

    private func write(_ data: Data, to url: URL) {
        let directory = directory
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            } catch {
                AppLog.log("Job Agent: couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
