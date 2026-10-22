import Foundation

/// The end-of-session recap. Facts come from the record (always shown as
/// numbers in the card); the paragraph is written by the on-device model
/// (FoundationModels through `MeetingAIBackend`, never the network) and
/// falls back to a template when the model is unavailable or slow.
enum FocusSummarizer {
    static let modelName = "Apple Intelligence (on-device)"
    static let templateName = "SparkV"

    static let instructions = """
    You write a short, warm recap of the user's focus session for a Mac app. \
    Use only the facts given. Write two or three sentences addressed to the user as "you". \
    Mention how long they focused, the main apps or documents, and anything they created. \
    Only mention apps, documents, items or distractions that appear in the facts; skip anything not listed. \
    No lists, no headings, no emoji, no advice.
    """

    /// The facts handed to the model: names and counts only, titles clipped.
    static func prompt(for record: FocusSessionRecord) -> String {
        var lines: [String] = []
        lines.append("Focused: \(FocusText.duration(record.focusedSeconds)) of a planned \(record.plannedFocusMinutes) min; rounds completed: \(record.roundsCompleted); ended: \(record.endReason.rawValue).")
        let apps = record.apps.prefix(5).map { "\($0.name) (\(FocusText.duration($0.seconds)))" }
        if apps.isEmpty {
            lines.append("No app details were recorded; do not mention apps or documents.")
        } else {
            lines.append("Apps: " + apps.joined(separator: ", ") + ".")
        }
        let docs = record.documents.prefix(5).map { "\(FocusText.clip($0.title, 50)) in \($0.appName)" }
        if !docs.isEmpty { lines.append("Windows and documents: " + docs.joined(separator: "; ") + ".") }
        for kind in FocusArtifact.Kind.allCases {
            let items = record.artifacts.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            let titles = items.prefix(4).map { "\"\(FocusText.clip($0.title, 50))\"" }.joined(separator: ", ")
            lines.append("\(kind.countLabel(items.count)): \(titles).")
        }
        if !record.interruptions.isEmpty {
            let targets = Array(Set(record.interruptions.map(\.target))).sorted().prefix(3)
            lines.append("Distractions blocked: \(record.interruptions.count) (\(targets.joined(separator: ", "))).")
        }
        return "Session facts:\n" + lines.joined(separator: "\n") + "\n\nWrite the recap."
    }

    /// Template recap, also the instant first version shown before the model answers.
    static func template(for record: FocusSessionRecord) -> String {
        var sentences: [String] = []
        let focused = FocusText.duration(record.focusedSeconds)
        let apps = record.apps.prefix(3).map(\.name)
        if apps.isEmpty {
            sentences.append("You focused for \(focused).")
        } else {
            sentences.append("You focused for \(focused), mostly in \(FocusText.list(apps)).")
        }
        if let doc = record.documents.first {
            sentences.append("Most of that went to “\(FocusText.clip(doc.title, 48))”.")
        }
        let made = FocusArtifact.Kind.allCases.compactMap { kind -> String? in
            let n = record.count(of: kind)
            return n > 0 ? kind.countLabel(n) : nil
        }
        if !made.isEmpty { sentences.append("Along the way you added \(FocusText.list(made)).") }
        if !record.interruptions.isEmpty {
            let n = record.interruptions.count
            sentences.append("SparkV caught \(n) distraction\(n == 1 ? "" : "s").")
        }
        return sentences.joined(separator: " ")
    }

    /// Model recap, or nil (unavailable, failed, timed out, empty).
    static func modelSummary(for record: FocusSessionRecord, timeout: Double = 25) async -> String? {
        guard MeetingAIBackend.onDeviceAvailable else { return nil }
        do {
            let text = try await MeetingAIBackend.onDevice(
                instructions: instructions,
                prompt: prompt(for: record),
                schema: nil,
                maxTokens: 180,
                timeout: timeout,
                permissive: true
            )
            return clean(text)
        } catch {
            AppLog.log("Focus: on-device summary unavailable (\(type(of: error)))")
            return nil
        }
    }

    /// Strips quotes, headings and stray markdown; nil when nothing is left.
    static func clean(_ text: String) -> String? {
        var t = MeetingAIJSON.stripReasoning(text).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Recap:", "Summary:", "**Recap:**", "**Summary:**"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        t = t.replacingOccurrences(of: "**", with: "")
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 2 { t = String(t.dropFirst().dropLast()) }
        t = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        if t.count > 600 { t = String(t.prefix(599)) + "…" }
        return t.isEmpty ? nil : t
    }
}
