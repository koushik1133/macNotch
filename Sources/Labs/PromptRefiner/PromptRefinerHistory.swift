import Foundation

/// Past refinements as JSON in
/// ~/Library/Application Support/SparkV/PromptRefiner/history.json
/// (newest first, at most `limit`). Local only; never synced or uploaded.
@MainActor
final class PromptRefinerHistory {
    static let limit = 200

    private(set) var records: [PromptRefinementRecord] = []
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkV/PromptRefiner", isDirectory: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ record: PromptRefinementRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        save()
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            records = try decoder.decode([PromptRefinementRecord].self, from: data)
        } catch {
            AppLog.log("Prompt Refiner: history unreadable (\(error.localizedDescription)); starting empty")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.log("Prompt Refiner: couldn't save history (\(error.localizedDescription))")
        }
    }
}
