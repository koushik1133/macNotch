import Foundation

// Value types for the Job Search Operations Agent. Everything here is plain
// Codable/Sendable data, independent of AppKit, so the parsing and scoring
// code can be tested outside the app.

// MARK: - Status

enum JobStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case considering = "Considering"
    case applied = "Applied"
    case interview = "Interview"
    case offer = "Offer"
    case rejected = "Rejected"
    case ghosted = "Ghosted"

    var id: String { rawValue }

    /// Funnel stage (Considering 0 … Offer 3); Rejected and Ghosted end the funnel.
    var funnelRank: Int {
        switch self {
        case .considering: 0
        case .applied, .rejected, .ghosted: 1
        case .interview: 2
        case .offer: 3
        }
    }

    var symbol: String {
        switch self {
        case .considering: "eye"
        case .applied: "paperplane.fill"
        case .interview: "person.2.fill"
        case .offer: "star.fill"
        case .rejected: "xmark.circle.fill"
        case .ghosted: "moon.zzz.fill"
        }
    }
}

// MARK: - Resume profile

struct ResumeExperience: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var company: String
    /// "Jan 2020", "2018", … as written.
    var start: String
    var end: String
    /// Months, when the dates parse.
    var months: Int?
    var highlights: [String]
}

struct ResumeEducation: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var degree: String
    var field: String
    var school: String
    var year: String
    /// 1 associate, 2 bachelor, 3 master/MBA, 4 doctorate, 0 other.
    var level: Int
}

struct ResumeProfile: Codable, Sendable, Equatable {
    var name: String = ""
    var headline: String = ""
    var summary: String = ""
    /// Canonical skill names (dictionary + skills section), deduped.
    var skills: [String] = []
    /// Skills listed in the resume's Skills section (as canonical names when known).
    var declaredSkills: [String] = []
    var experience: [ResumeExperience] = []
    var education: [ResumeEducation] = []
    /// Best estimate of total professional experience.
    var yearsExperience: Double?
    /// "dictionary", "on-device", "groq" (what produced the structured parts).
    var source: String = "dictionary"
    var fileName: String = ""
    var importedAt = Date()

    var highestEducationLevel: Int { education.map(\.level).max() ?? 0 }
    var titles: [String] { experience.map(\.title).filter { !$0.isEmpty } }
}

// MARK: - Posting

struct JobPosting: Codable, Sendable, Equatable {
    var company: String = ""
    var title: String = ""
    var location: String = ""
    var salary: String = ""
    var employmentType: String = ""
    var deadline: String = ""
    var sourceURL: String = ""
    var pageTitle: String = ""
    /// Detected ATS/board ("Greenhouse", "Lever", "LinkedIn", …) or "".
    var source: String = ""
    /// Job id parsed from the URL, when the ATS has one.
    var jobID: String = ""
    var requirements: [String] = []
    var preferred: [String] = []
    /// Canonical skills found in requirement lines (or the whole JD when there are none).
    var requiredSkills: [String] = []
    var preferredSkills: [String] = []
    /// "5+ years" → 5.
    var minYears: Double?
    /// 0 none stated, 2 bachelor, 3 master, 4 doctorate.
    var educationLevel: Int = 0
    var educationFlexible: Bool = false
    /// Cleaned OCR / page text (truncated).
    var text: String = ""
    /// 0…1: how much the text looks like a job posting.
    var postingConfidence: Double = 0
    var extractedBy: String = "rules"
}

// MARK: - Fit

struct JobFitComponent: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    /// 0…1, nil when there was nothing to measure.
    var score: Double?
    var weight: Double
    var detail: String
}

struct JobFitReport: Codable, Sendable, Equatable {
    var overall: Int
    var matchingSkills: [String]
    var missingSkills: [String]
    var missingPreferred: [String]
    var keywordCoverage: Double
    var matchedKeywords: [String]
    var missingKeywords: [String]
    var experienceNote: String
    var components: [JobFitComponent]
    /// Plain-language explanation, several sentences, honest about gaps and uncertainty.
    var explanation: String
    var computedAt = Date()

    static let empty = JobFitReport(
        overall: 0, matchingSkills: [], missingSkills: [], missingPreferred: [], keywordCoverage: 0,
        matchedKeywords: [], missingKeywords: [], experienceNote: "", components: [], explanation: ""
    )
}

// MARK: - Tailoring

struct TailorSuggestion: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case reorder = "Reorder"
        case emphasize = "Emphasize"
        case mirrorKeyword = "Mirror wording"
        case addToSkills = "Skills section"
        case summary = "Summary"
        case reword = "Reword"
        case gap = "Gap (only if true)"
    }

    var id = UUID()
    var kind: Kind
    /// Where it applies ("Acme · Senior iOS Engineer", "Skills", "Summary").
    var location: String
    var before: String
    var after: String
    var reason: String
}

// MARK: - Application

struct JobStatusChange: Codable, Sendable, Equatable {
    var status: JobStatus
    var date: Date
    var note: String = ""
}

struct JobApplication: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var posting: JobPosting
    var status: JobStatus = .considering
    var history: [JobStatusChange] = []
    var createdAt = Date()
    var appliedAt: Date?
    var expectedResponseAt: Date?
    var fit: JobFitReport?
    var notes: String = ""
    var tailoring: [TailorSuggestion] = []
    /// Text of the confirmation page/email that marked it applied.
    var confirmationEvidence: String = ""
    var reminderID: String?

    var company: String { posting.company.isEmpty ? "Unknown company" : posting.company }
    var title: String { posting.title.isEmpty ? "Untitled role" : posting.title }

    /// Application deadline from the posting, when it parses.
    var deadlineDate: Date? { JobPostingParser.deadlineDate(posting.deadline) }

    /// Whole days until the deadline (0 = today), nil when unknown or past,
    /// or when the job is no longer at the "Considering" stage.
    func daysUntilDeadline(now: Date = Date()) -> Int? {
        guard status == .considering, let deadline = deadlineDate, deadline >= now else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: deadline)).day
    }

    /// Highest funnel rank ever reached (for the funnel chart).
    var maxFunnelRank: Int {
        (history.map(\.status.funnelRank) + [status.funnelRank]).max() ?? 0
    }

    /// Applied at some point (any status past Considering counts).
    var everApplied: Bool { appliedAt != nil || maxFunnelRank >= 1 }

    /// Got any answer (interview, offer or rejection).
    var gotResponse: Bool {
        let statuses = Set(history.map(\.status) + [status])
        return !statuses.isDisjoint(with: [.interview, .offer, .rejected])
    }

    mutating func setStatus(_ new: JobStatus, at date: Date = Date(), note: String = "") {
        guard new != status else { return }
        status = new
        history.append(JobStatusChange(status: new, date: date, note: note))
        if new == .applied, appliedAt == nil { appliedAt = date }
    }
}

// MARK: - Settings keys

enum JobAgentSettings {
    static let useGroqKey = "jobAgent.useGroq"
    static let hotkeyEnabledKey = "jobAgent.hotkeyEnabled"
    static let remindersKey = "jobAgent.reminders"
    static let onDeviceModelKey = "jobAgent.useOnDeviceModel"

    /// Off unless the user turns on "Use Groq for job analysis".
    static var useGroq: Bool {
        get { UserDefaults.standard.bool(forKey: useGroqKey) }
        set { UserDefaults.standard.set(newValue, forKey: useGroqKey) }
    }

    /// `bool(forKey:)` also reads "NO"/"YES" strings (argument domain); default true when unset.
    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    static var hotkeyEnabled: Bool {
        get { flag(hotkeyEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: hotkeyEnabledKey) }
    }

    static var reminders: Bool {
        get { flag(remindersKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: remindersKey) }
    }

    static var useOnDeviceModel: Bool {
        get { flag(onDeviceModelKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: onDeviceModelKey) }
    }
}
