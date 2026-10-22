import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device folder suggestion for a finished download. The model only
/// picks one of the given folder names: guided generation with an `anyOf`
/// string schema constrains the decoder to the list (plus "None"), so it
/// can't invent a path. Runs on this Mac only (Apple Intelligence through
/// FoundationModels); nothing leaves the machine and there is no cloud
/// fallback. Without Apple Intelligence the rules alone decide.
enum DownloadsAI {
    static let noneChoice = "None"

    static let instructions = """
    You file downloaded files into folders. You get a file's name, kind, size and the website it came from, \
    and a list of folder names. Pick the single folder where a careful person would keep this file. \
    Prefer a specific folder (for example "Invoices" for an invoice PDF, or a project folder whose name matches) \
    over a generic one. Answer None when no folder fits.
    """

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    /// Why it can't run, or nil.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "needs macOS 26" }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "this Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off"
        case .unavailable(.modelNotReady): return "the model is still downloading"
        case .unavailable: return "Apple Intelligence is unavailable"
        }
        #else
        return "needs macOS 26"
        #endif
    }

    /// The facts the model sees, one per line. No file contents are read.
    static func prompt(name: String, category: DownloadCategory, domain: String?, size: Int64, folders: [String]) -> String {
        var lines = [
            "File name: \(name)",
            "Kind: \(category.singular)",
            "Size: \(DownloadFormat.bytes(size))",
        ]
        if let domain { lines.append("Downloaded from: \(domain)") }
        lines.append("Folders:")
        lines += folders.map { "- \($0)" }
        lines.append("Which folder fits best?")
        return lines.joined(separator: "\n")
    }

    /// One of `folders`, or nil (no fit, unavailable, timed out or failed).
    static func suggestFolder(name: String, category: DownloadCategory, domain: String?, size: Int64,
                              folders: [String], timeout: Double = 10) async -> String? {
        let choices = Array(NSOrderedSet(array: folders.filter { !$0.isEmpty && $0 != noneChoice })) as? [String] ?? []
        guard !choices.isEmpty, isAvailable else { return nil }
        let text = prompt(name: name, category: category, domain: domain, size: size, folders: choices)
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        let answer: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await respond(prompt: text, choices: choices) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answer, answer != noneChoice, choices.contains(answer) else { return nil }
        return answer
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func respond(prompt: String, choices: [String]) async -> String? {
        do {
            let folder = DynamicGenerationSchema(name: "Folder", description: "One folder name from the list, or None",
                                                 anyOf: choices + [noneChoice])
            let root = DynamicGenerationSchema(name: "FolderChoice", properties: [
                DynamicGenerationSchema.Property(name: "folder", description: "The chosen folder", schema: folder),
            ])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(model: SystemLanguageModel(useCase: .general), instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40)
            let response = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true, options: options)
            return try response.content.value(String.self, forProperty: "folder")
        } catch {
            AppLog.log("Downloads: on-device suggestion failed (\(type(of: error)))")
            return nil
        }
    }
    #endif
}
