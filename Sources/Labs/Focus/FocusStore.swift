import Foundation

/// Saved Focus sessions (Application Support/SparkV/Focus/sessions.json) and
/// the in-flight session (active.json), which lets a relaunch pick a running
/// session back up and undo its muting even after a crash.
@MainActor
final class FocusStore: ObservableObject {
    static let historyLimit = 500

    @Published private(set) var sessions: [FocusSessionRecord] = []

    let directory: URL
    private var sessionsURL: URL { directory.appendingPathComponent("sessions.json") }
    private var activeURL: URL { directory.appendingPathComponent("active.json") }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/Focus", isDirectory: true)
    }

    /// `directory` is a seam for tests.
    init(directory: URL = FocusStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: sessionsURL),
           let saved = try? Self.decoder.decode([FocusSessionRecord].self, from: data) {
            sessions = saved.sorted { $0.startedAt > $1.startedAt }
        }
    }

    func add(_ record: FocusSessionRecord) {
        sessions.removeAll { $0.id == record.id }
        sessions.insert(record, at: 0)
        if sessions.count > Self.historyLimit { sessions.removeLast(sessions.count - Self.historyLimit) }
        save()
    }

    /// Replaces a saved session (e.g. when the model summary arrives later).
    func update(_ record: FocusSessionRecord) {
        guard let index = sessions.firstIndex(where: { $0.id == record.id }) else { return }
        sessions[index] = record
        save()
    }

    func stats(now: Date = Date(), calendar: Calendar = .current) -> FocusStats {
        FocusStats.compute(sessions, now: now, calendar: calendar)
    }

    // MARK: Active session

    func saveActive(_ active: FocusActiveSession?) {
        guard let active else {
            try? FileManager.default.removeItem(at: activeURL)
            return
        }
        // Exact dates (not ISO 8601, which drops fractions) keep the schedule precise.
        guard let data = try? JSONEncoder().encode(active) else { return }
        try? data.write(to: activeURL, options: .atomic)
    }

    func loadActive() -> FocusActiveSession? {
        guard let data = try? Data(contentsOf: activeURL) else { return nil }
        return try? JSONDecoder().decode(FocusActiveSession.self, from: data)
    }

    // MARK: IO

    private func save() {
        guard let data = try? Self.encoder.encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Everything about a running session that must survive a relaunch.
struct FocusActiveSession: Codable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var schedule: FocusSchedule
    var plannedFocusMinutes: Int
    /// The Do Not Disturb "on" shortcut ran, so "off" must run at the end.
    var didEnableDoNotDisturb: Bool
    /// SparkV's notification previews were on before the session muted them.
    var previewsWereEnabled: Bool?
    var usage: FocusUsageSnapshot
    var artifacts: [FocusArtifact]
    var interruptions: [FocusInterruption]
}
