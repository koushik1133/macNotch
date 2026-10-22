import Foundation

// Runs one action node on its inputs. Pure with respect to the canvas: the
// editor gathers inputs (FCRunner.inputs), calls `run`, and stores the result.
// Long inputs are cut to the most relevant chunks, and on-device they're
// map-reduced first (notes per chunk, then the task over the notes).

/// A root source card, for citations and the report's Sources section.
struct FCSourceRef: Sendable, Equatable {
    var id: UUID
    var title: String
    var kind: FCNodeKind
    var url: URL?
    var fileURL: URL?

    var link: URL? { url ?? fileURL }
}

/// One connected input of an action, labelled S1, S2… in prompts.
struct FCInputItem: Sendable {
    var nodeID: UUID
    var label: String
    var title: String
    var kind: FCNodeKind
    var text: String
    var table: FCTable?
    var url: URL?
    var roots: [FCSourceRef]

    /// Text plus the table as Markdown, for prompts.
    var fullText: String {
        guard let table, !table.columns.isEmpty else { return text }
        let narrative = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return table.markdown + (narrative.isEmpty ? "" : "\n\n" + narrative)
    }
}

struct FCRunResult: Sendable {
    var output: FCOutput
    var model: String
}

enum FCRunError: LocalizedError {
    case noInputs
    case emptyInputs([String])
    case needsFields
    case needsPrompt
    case needsQuestion

    var errorDescription: String? {
        switch self {
        case .noInputs: "Connect at least one card to this step"
        case .emptyInputs(let names): "These inputs have no text yet: \(names.joined(separator: ", "))"
        case .needsFields: "List the fields to extract (e.g. price, plans, features)"
        case .needsPrompt: "Write the instruction for this step in the inspector"
        case .needsQuestion: "Type a question"
        }
    }
}

typealias FCProgress = @Sendable (String) -> Void

@MainActor
final class FCRunner {
    let ai: FCAI

    init(ai: FCAI? = nil) {
        self.ai = ai ?? .shared
    }

    // MARK: Inputs

    /// The node's direct inputs in canvas order, with their root sources.
    static func inputs(for nodeID: UUID, in document: FCDocument, assetURL: (FCNode) -> URL?) -> [FCInputItem] {
        FCGraph.inputs(of: nodeID, in: document).enumerated().map { index, node in
            let roots: [FCSourceRef]
            if node.kind.isSource {
                roots = [ref(node, assetURL: assetURL)]
            } else {
                roots = FCGraph.rootSources(of: node.id, in: document).map { ref($0, assetURL: assetURL) }
            }
            return FCInputItem(
                nodeID: node.id, label: "S\(index + 1)", title: node.citationLabel, kind: node.kind,
                text: node.kind.isSource ? sourceText(node) : (node.output?.text ?? ""),
                table: node.kind.isSource ? nil : node.output?.table,
                url: node.source?.url, roots: roots
            )
        }
    }

    static func ref(_ node: FCNode, assetURL: (FCNode) -> URL?) -> FCSourceRef {
        FCSourceRef(id: node.id, title: node.citationLabel, kind: node.kind,
                    url: node.source?.url.flatMap { $0.isFileURL ? nil : $0 }, fileURL: assetURL(node) ?? node.source?.url.flatMap { $0.isFileURL ? $0 : nil })
    }

    static func sourceText(_ node: FCNode) -> String {
        guard let source = node.source else { return "" }
        var parts: [String] = []
        if let description = source.imageDescription, !description.isEmpty { parts.append("[Image] " + description) }
        if !source.text.isEmpty { parts.append(source.text) }
        return parts.joined(separator: "\n")
    }

    // MARK: Run

    func run(_ node: FCNode, inputs: [FCInputItem], progress: @escaping FCProgress = { _ in }) async throws -> FCRunResult {
        guard !inputs.isEmpty else { throw FCRunError.noInputs }
        let empty = inputs.filter { $0.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if empty.count == inputs.count { throw FCRunError.emptyInputs(empty.map(\.title)) }
        let usable = inputs.filter { !$0.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let llm = FCLLM(backend: ai.backend())
        switch node.kind {
        case .summarize: return try await summarize(node, usable, llm, progress)
        case .extract: return try await extract(node, usable, llm, progress)
        case .compare: return try await compare(node, usable, llm, progress)
        case .report: return try await report(node, usable, llm, progress)
        case .translate: return try await translate(node, usable, llm, progress)
        case .custom: return try await custom(node, usable, llm, progress)
        case .chat:
            // "Run" on a chat node gives an overview to start the conversation.
            let message = try await chat(node, question: "Give a short overview of what these sources cover.", inputs: usable, progress: progress)
            return FCRunResult(output: FCOutput(format: .markdown, text: message.text, citations: message.citations), model: message.model ?? llm.label)
        default:
            throw FCRunError.noInputs
        }
    }

    private func allRoots(_ inputs: [FCInputItem]) -> [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for item in inputs {
            for root in item.roots where seen.insert(root.id).inserted { ids.append(root.id) }
            if item.roots.isEmpty, seen.insert(item.nodeID).inserted { ids.append(item.nodeID) }
        }
        return ids
    }

    // MARK: Context building (chunking / map-reduce)

    /// "[S1] Title (url)" headers with each input cut to its share of
    /// `budget`. On-device, inputs longer than their share are first reduced
    /// to notes about `focus`, one model call per chunk (map), at most 6.
    func context(_ inputs: [FCInputItem], llm: FCLLM, focus: String, budget: Int, progress: FCProgress) async throws -> String {
        let terms = FCText.keywords(focus)
        let share = max(500, budget / max(inputs.count, 1) - 60)
        var parts: [String] = []
        for item in inputs {
            try Task.checkCancellation()
            var text = item.fullText
            if text.count > share, case .onDevice = llm.backend {
                text = try await mapNotes(text, title: item.title, focus: focus, llm: llm, share: share, progress: progress)
            }
            let header = "[\(item.label)] \(item.title)" + (item.url.map { " (\($0.absoluteString))" } ?? "")
            parts.append(header + "\n" + FCText.select(text, terms: terms, budget: share))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Map step: bullet notes per chunk (the most relevant 6 chunks).
    func mapNotes(_ text: String, title: String, focus: String, llm: FCLLM, share: Int, progress: FCProgress) async throws -> String {
        let size = llm.backend.budget(for: text)
        var chunks = TrayAIPrompts.chunks(text, size: size)
        let terms = FCText.keywords(focus)
        if chunks.count > 6 {
            let keep = Set(chunks.indices.sorted { FCText.score(chunks[$0], terms: terms) > FCText.score(chunks[$1], terms: terms) }.prefix(6))
            chunks = chunks.indices.filter { keep.contains($0) }.map { chunks[$0] }
        }
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress("Reading \(title) (\(index + 1)/\(chunks.count))")
            let note = try await llm.complete(
                prompt: "Excerpt from \"\(title)\":\n\(chunk)\n\nTask: List the facts in this excerpt that matter for: \(focus). Keep exact numbers, prices, names and dates. 3-8 short \"- \" bullets. If nothing is relevant, reply \"- (nothing relevant)\".",
                maxTokens: 400
            )
            notes.append(note)
        }
        let joined = notes.joined(separator: "\n").replacingOccurrences(of: "- (nothing relevant)\n", with: "")
        return joined.count > share ? FCText.select(joined, terms: terms, budget: share) : joined
    }

    // MARK: Summarize

    private func summarize(_ node: FCNode, _ inputs: [FCInputItem], _ llm: FCLLM, _ progress: @escaping FCProgress) async throws -> FCRunResult {
        let extra = node.config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let roots = allRoots(inputs)
        if case .rules(let reason) = llm.backend {
            let body = inputs.map { item -> String in
                if let table = item.table, !table.columns.isEmpty { return "### \(item.title)\n" + table.markdown }
                return "### \(item.title)\n" + FCText.extractive(item.text, sentences: inputs.count > 2 ? 3 : 5)
            }.joined(separator: "\n\n")
            let text = body + "\n\n_Extractive summary (key sentences): Apple Intelligence \(reason)._"
            return FCRunResult(output: FCOutput(format: .markdown, text: text, citations: roots), model: llm.label)
        }
        let task = "Summarize the sources as 4-8 \"- \" bullets" + (inputs.count > 1 ? ", grouped under a short \"### \" heading per source" : "")
            + ". Keep numbers and names. Cite [S#]." + (extra.isEmpty ? "" : " Focus: \(extra)")
        progress("Summarizing…")
        if inputs.count == 1, case .onDevice = llm.backend, inputs[0].fullText.count > llm.backend.budget(for: inputs[0].fullText) {
            // Tray AI's map-reduce summarizer (≤ 6 chunks, then combine).
            let text = try await TrayAIOnDevice.summarize(inputs[0].fullText, task: task, report: progress)
            return FCRunResult(output: FCOutput(format: .markdown, text: TrayAIText.clean(text), citations: roots), model: llm.label)
        }
        let budget = llm.backend.budget(for: inputs.map(\.text).joined()) - 400
        let context = try await context(inputs, llm: llm, focus: extra.isEmpty ? "the main points" : extra, budget: budget, progress: progress)
        progress("Summarizing…")
        let text = try await llm.complete(prompt: context + "\n\nTask: " + task, maxTokens: 900)
        return FCRunResult(output: FCOutput(format: .markdown, text: text, citations: roots), model: llm.label)
    }

    // MARK: Extract

    private func extract(_ node: FCNode, _ inputs: [FCInputItem], _ llm: FCLLM, _ progress: @escaping FCProgress) async throws -> FCRunResult {
        let fields = node.config.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !fields.isEmpty else { throw FCRunError.needsFields }
        let (table, model, notes) = try await extractTable(fields: fields, inputs: inputs, llm: llm, progress: progress)
        var text = "\(table.rows.count) source\(table.rows.count == 1 ? "" : "s") · \(fields.count) field\(fields.count == 1 ? "" : "s")"
        if !notes.isEmpty { text += "\n\n" + notes.joined(separator: "\n") }
        return FCRunResult(output: FCOutput(format: .table, text: text, table: table, citations: allRoots(inputs)), model: model)
    }

    /// One row per input. Upstream tables contribute their rows directly
    /// when they already have the requested columns.
    func extractTable(fields: [String], inputs: [FCInputItem], llm: FCLLM, progress: @escaping FCProgress) async throws -> (FCTable, String, [String]) {
        var rows: [[String]] = []
        var notes: [String] = []
        var usedRules = false
        let terms = FCRuleExtractor.terms(for: fields)
        for (index, item) in inputs.enumerated() {
            try Task.checkCancellation()
            progress("Extracting from \(item.title) (\(index + 1)/\(inputs.count))")
            var values: [String: String] = [:]
            let budget = max(1500, llm.backend.budget(for: item.fullText) - 900)
            let text = FCText.select(item.fullText, terms: terms, budget: budget)
            if llm.backend.isModel {
                do {
                    values = try await llm.fields(fields, from: text, about: item.title)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    notes.append("\(item.title): the model failed (\(error.localizedDescription)); used pattern matching.")
                    values = FCRuleExtractor.extract(fields, from: item.fullText)
                    usedRules = true
                }
            } else {
                values = FCRuleExtractor.extract(fields, from: item.fullText)
                usedRules = true
            }
            rows.append([item.title] + fields.map { field in
                let value = values[field] ?? ""
                return value.isEmpty ? "—" : value
            })
        }
        let columns = ["Source"] + fields.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let model = llm.backend.isModel ? (usedRules ? llm.label + " + rules" : llm.label) : llm.label
        return (FCTable(columns: columns, rows: rows), model, notes)
    }

    // MARK: Compare

    private func compare(_ node: FCNode, _ inputs: [FCInputItem], _ llm: FCLLM, _ progress: @escaping FCProgress) async throws -> FCRunResult {
        let tables = inputs.compactMap { $0.table }.filter { !$0.rows.isEmpty }
        var table: FCTable
        var model = llm.label
        if !tables.isEmpty {
            table = Self.merge(tables)
            // Text-only inputs get the same columns by extraction.
            let textOnly = inputs.filter { $0.table == nil }
            if !textOnly.isEmpty {
                let fields = Array(table.columns.dropFirst())
                let (extra, extraModel, _) = try await extractTable(fields: fields, inputs: textOnly, llm: llm, progress: progress)
                table.rows += extra.rows
                model = extraModel
            }
        } else {
            let criteria = try await criteria(for: inputs, prompt: node.config.prompt, llm: llm)
            let (built, builtModel, _) = try await extractTable(fields: criteria, inputs: inputs, llm: llm, progress: progress)
            table = built
            model = builtModel
        }
        progress("Comparing…")
        var narrative: String
        if llm.backend.isModel {
            let focus = node.config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                narrative = try await llm.complete(
                    prompt: "Comparison table:\n\(FCText.select(table.markdown, terms: [], budget: llm.backend.budget(for: table.markdown) - 600))\n\n"
                        + "Task: Compare the rows side by side. Start with 2-3 sentences on the most important differences, then \"- \" bullets for: best value, most complete offer, notable gaps. Refer to each row by its Source name. Use only the table."
                        + (focus.isEmpty ? "" : " Focus: \(focus)"),
                    maxTokens: 700
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                narrative = Self.ruleNarrative(table) + "\n\n_The model couldn't write the verdict (\(error.localizedDescription))._"
            }
        } else {
            narrative = Self.ruleNarrative(table)
        }
        return FCRunResult(output: FCOutput(format: .table, text: narrative, table: table, citations: allRoots(inputs)), model: model)
    }

    /// Columns for a comparison when no input is a table yet.
    private func criteria(for inputs: [FCInputItem], prompt: String, llm: FCLLM) async throws -> [String] {
        let fallback = FCRuleExtractor.criteria(fromPrompt: prompt) ?? ["key points", "price", "strengths", "limitations"]
        guard llm.backend.isModel else { return FCRuleExtractor.criteria(fromPrompt: prompt) ?? ["key points", "price"] }
        let preview = inputs.map { "[\($0.label)] \($0.title): " + TrayAIPrompts.truncate($0.fullText, to: 300) }.joined(separator: "\n")
        do {
            let object = try await llm.completeJSON(
                prompt: "Sources:\n\(preview)\n\nGoal: \(prompt.isEmpty ? "compare these sources" : prompt)\n\nTask: Pick 3-5 short criteria (column names, 1-3 words each) to compare these sources on. Reply as JSON: {\"criteria\": [\"...\"]}",
                maxTokens: 200
            )
            let list = (object["criteria"] as? [Any])?.map { FCJSON.string($0) }.filter { !$0.isEmpty && $0.count <= 40 } ?? []
            return list.isEmpty ? fallback : Array(list.prefix(5))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback
        }
    }

    static func merge(_ tables: [FCTable]) -> FCTable {
        var columns: [String] = ["Source"]
        for table in tables {
            for column in table.columns where !columns.contains(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) {
                columns.append(column)
            }
        }
        var rows: [[String]] = []
        for table in tables {
            let map = table.columns.enumerated().reduce(into: [String: Int]()) { $0[$1.element.lowercased()] = $1.offset }
            for row in table.normalizedRows {
                rows.append(columns.map { column in map[column.lowercased()].map { row[$0] } ?? "—" })
            }
        }
        return FCTable(columns: columns, rows: rows)
    }

    /// A verdict without a model: price range and coverage per row.
    static func ruleNarrative(_ table: FCTable) -> String {
        var lines: [String] = []
        let rows = table.normalizedRows
        if let priceColumn = table.columns.firstIndex(where: { FCRuleExtractor.isPriceField($0) }) {
            let priced = rows.compactMap { row -> (String, Double)? in
                guard let amount = FCRuleExtractor.lowestPaidAmount(row[priceColumn]) else { return nil }
                return (row[0], amount)
            }
            if let cheapest = priced.min(by: { $0.1 < $1.1 }), let priciest = priced.max(by: { $0.1 < $1.1 }), priced.count > 1 {
                lines.append("- Lowest listed paid price: **\(cheapest.0)** (\(Self.format(cheapest.1))); highest: **\(priciest.0)** (\(Self.format(priciest.1))).")
            }
            let free = rows.filter { $0[priceColumn].range(of: "free", options: .caseInsensitive) != nil }.map { $0[0] }
            if !free.isEmpty { lines.append("- Mentions a free option: \(free.joined(separator: ", ")).") }
        }
        if let featureColumn = table.columns.firstIndex(where: { $0.lowercased().contains("feature") }) {
            let counts = rows.map { ($0[0], $0[featureColumn] == "—" ? 0 : $0[featureColumn].components(separatedBy: ";").count) }
            if let most = counts.max(by: { $0.1 < $1.1 }), most.1 > 0 {
                lines.append("- Most features listed: **\(most.0)** (\(most.1)).")
            }
        }
        for row in rows {
            let missing = zip(table.columns.dropFirst(), row.dropFirst()).filter { $0.1 == "—" }.map { $0.0.lowercased() }
            if !missing.isEmpty { lines.append("- \(row[0]): no \(missing.joined(separator: ", ")) found.") }
        }
        if lines.isEmpty { lines.append("- \(rows.count) sources compared; see the table.") }
        return "Rule-based comparison (no language model available):\n" + lines.joined(separator: "\n")
    }

    private static func format(_ amount: Double) -> String {
        amount == amount.rounded() ? String(Int(amount)) : String(format: "%.2f", amount)
    }

    // MARK: Report

    private func report(_ node: FCNode, _ inputs: [FCInputItem], _ llm: FCLLM, _ progress: @escaping FCProgress) async throws -> FCRunResult {
        var refs: [FCSourceRef] = []
        for item in inputs {
            for root in item.roots where !refs.contains(where: { $0.id == root.id }) { refs.append(root) }
        }
        let title = node.title == FCNodeKind.report.title ? "Report" : node.title
        let goal = node.config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcesSection = Self.sourcesSection(refs)
        let tables = inputs.compactMap(\.table).filter { !$0.rows.isEmpty }
        var body: String
        if llm.backend.isModel {
            let legend = refs.enumerated().map { "[S\($0.offset + 1)] \($0.element.title)" }.joined(separator: "\n")
            // Inputs keep their own labels in the context, so relabel them by name.
            var material = inputs
            for index in material.indices { material[index].label = "Input \(index + 1)" }
            let budget = llm.backend.budget(for: inputs.map(\.text).joined()) - 900 - legend.count
            let context = try await context(material, llm: llm, focus: goal.isEmpty ? "findings, numbers, comparisons" : goal, budget: budget, progress: progress)
            progress("Writing the report…")
            body = try await llm.complete(
                prompt: "Source legend:\n\(legend)\n\nMaterial:\n\(context)\n\n"
                    + "Task: Write a report in Markdown titled \"# \(title)\". Sections: \"## Summary\" (3-5 sentences), \"## Findings\" (\"- \" bullets; cite the source legend labels like [S1] when a fact comes from a specific source)"
                    + (tables.isEmpty ? "" : ", \"## Comparison\" (reproduce the most useful table in Markdown)")
                    + ", \"## Recommendation\". Do not add a Sources section; it is appended automatically."
                    + (goal.isEmpty ? "" : " The report is for: \(goal)"),
                maxTokens: 1600
            )
            if !body.hasPrefix("#") { body = "# \(title)\n\n" + body }
        } else {
            var parts = ["# \(title)", "## Summary"]
            // Narratives of upstream comparisons first, then key sentences per text input.
            for item in inputs where item.table != nil && !item.text.isEmpty {
                parts.append(item.text)
            }
            for item in inputs where item.table == nil {
                // Upstream AI steps are already condensed; sources get key sentences.
                let body = item.kind.isAction ? Self.demotingHeadings(item.text) : FCText.extractive(item.text, sentences: 4)
                parts.append("### \(item.title)\n" + body)
            }
            for (index, table) in tables.enumerated() {
                parts.append(index == 0 ? "## Comparison\n\n" + table.markdown : table.markdown)
            }
            parts.append("_Assembled without a language model (key sentences and tables only)._")
            body = parts.joined(separator: "\n\n")
        }
        body = Self.strippingSources(body)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + sourcesSection
        return FCRunResult(output: FCOutput(format: .markdown, text: text, citations: refs.map(\.id)), model: llm.label)
    }

    /// "# A" → "#### A" so nested Markdown stays under the report's sections.
    static func demotingHeadings(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.hasPrefix("#") ? "###" + line : line
        }.joined(separator: "\n")
    }

    /// "## Sources" with a link per source card (web URL or the canvas's file copy).
    static func sourcesSection(_ refs: [FCSourceRef]) -> String {
        guard !refs.isEmpty else { return "## Sources\n\n_No source cards are connected._" }
        let lines = refs.enumerated().map { index, ref -> String in
            let label = "[S\(index + 1)]"
            let title = ref.title.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            if let url = ref.link {
                let host = url.isFileURL ? url.lastPathComponent : (url.host ?? "")
                return "- \(label) [\(title)](\(url.absoluteString))" + (host.isEmpty ? "" : " — \(host)")
            }
            return "- \(label) \(title) (\(ref.kind.title.lowercased()))"
        }
        return "## Sources\n\n" + lines.joined(separator: "\n")
    }

    /// Drops a Sources section the model added anyway.
    static func strippingSources(_ text: String) -> String {
        guard let range = text.range(of: #"(?m)^#{1,3}\s*(Sources|References)\s*$"#, options: .regularExpression) else { return text }
        return String(text[..<range.lowerBound])
    }

    // MARK: Translate / Custom

    private func translate(_ node: FCNode, _ inputs: [FCInputItem], _ llm: FCLLM, _ progress: @escaping FCProgress) async throws -> FCRunResult {
        let target = node.config.language.isEmpty ? "English" : node.config.language
        let text = inputs.map { inputs.count > 1 ? "## \($0.title)\n\($0.fullText)" : $0.fullText }.joined(separator: "\n\n")
        let roots = allRoots(inputs)
        progress("Translating to \(target)…")
        switch llm.backend {
        case .groq(let groq):
            let reply = try await groq.complete(
                system: TrayAIPrompts.onDeviceTransformSystem,
                messages: [("user", "Task: Translate into \(target). Keep Markdown formatting.\n\n<text>\n\(TrayAIPrompts.truncate(text, to: 60_000))\n</text>")],
                json: false, maxTokens: min(8000, text.count / 2 + 600)
            )
            return FCRunResult(output: FCOutput(format: .markdown, text: TrayAIText.stripWrapper(reply.text), citations: roots), model: reply.model)
        default:
            // Apple Translation first (exact, installed languages only), then the on-device model.
            if let detected = TrayAIOCR.detectLanguage(text)?.rawValue, let code = TrayAITranslator.languageCode(for: target) {
                if TrayAITranslator.sameLanguage(detected, code) {
                    return FCRunResult(output: FCOutput(format: .markdown, text: text + "\n\n_Already in \(target)._", citations: roots), model: "No change")
                }
                if let translated = try? await TrayAITranslator.translate(text, from: detected, to: code) {
                    return FCRunResult(output: FCOutput(format: .markdown, text: translated, citations: roots), model: "Apple Translation (on-device)")
                }
            }
            guard case .onDevice = llm.backend else {
                throw FCLLM.Failure.needsModel("Translation needs Apple Translation languages installed (System Settings › General › Language & Region › Translation Languages), Apple Intelligence, or the Groq opt-in.")
            }
            let translated = try await TrayAIOnDevice.transformChunks(text, task: "Translate into \(target). Keep the formatting.", report: progress)
            return FCRunResult(output: FCOutput(format: .markdown, text: translated, citations: roots), model: llm.label)
        }
    }

    private func custom(_ node: FCNode, _ inputs: [FCInputItem], _ llm: FCLLM, _ progress: @escaping FCProgress) async throws -> FCRunResult {
        let instruction = node.config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw FCRunError.needsPrompt }
        let budget = llm.backend.budget(for: inputs.map(\.text).joined()) - 500 - instruction.count
        let context = try await context(inputs, llm: llm, focus: instruction, budget: budget, progress: progress)
        progress("Working…")
        let text = try await llm.complete(prompt: context + "\n\nTask: " + instruction + "\nCite [S#] where it helps.", maxTokens: 1400)
        return FCRunResult(output: FCOutput(format: .markdown, text: text, citations: allRoots(inputs)), model: llm.label)
    }

    // MARK: Chat

    /// One answer for a chat node, grounded in its connected cards. The
    /// answer's citations are the cards whose [S#] labels it used.
    func chat(_ node: FCNode, question: String, inputs: [FCInputItem], progress: @escaping FCProgress = { _ in }) async throws -> FCChatMessage {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw FCRunError.needsQuestion }
        let usable = inputs.filter { !$0.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { throw inputs.isEmpty ? FCRunError.noInputs : FCRunError.emptyInputs(inputs.map(\.title)) }
        let llm = FCLLM(backend: ai.backend())
        // A short follow-up ("and Pro?") borrows the previous question's words.
        var terms = FCText.keywords(question)
        if terms.count < 2, let previous = node.chat.last(where: { $0.role == .user })?.text { terms += FCText.keywords(previous) }

        if case .rules(let reason) = llm.backend {
            let passages = Self.retrieve(terms: terms, from: usable, limit: 4)
            let text: String
            if passages.isEmpty {
                text = "I couldn't find passages about that in the connected cards."
            } else {
                text = "The most relevant passages:\n" + passages.map { "- \($0.text) [\($0.label)]" }.joined(separator: "\n")
            }
            let cited = Array(Set(passages.map(\.nodeID)))
            return FCChatMessage(role: .assistant, text: text + "\n\n_Apple Intelligence \(reason), so these are quoted passages, not an answer._",
                                 citations: usable.filter { cited.contains($0.nodeID) }.map(\.nodeID), model: llm.label)
        }

        let history = node.chat.suffix(6).map { ($0.role == .user ? "user" : "assistant", TrayAIPrompts.truncate($0.text, to: 1200)) }
        let historyLength = history.reduce(0) { $0 + $1.1.count }
        let budget = max(1500, llm.backend.budget(for: usable.map(\.text).joined()) - 700 - historyLength)
        let share = max(400, budget / usable.count - 60)
        var parts: [String] = []
        for item in usable {
            let header = "[\(item.label)] \(item.title)" + (item.url.map { " (\($0.absoluteString))" } ?? "")
            parts.append(header + "\n" + FCText.select(item.fullText, terms: terms, budget: share, chunkSize: 900))
        }
        progress("Thinking…")
        let answer = try await llm.complete(
            prompt: "Sources:\n" + parts.joined(separator: "\n\n") + "\n\nQuestion: \(question)\n\nAnswer from the sources. Put the label of the card you used after each claim, like [S1]. If the sources don't say, say so.",
            history: history, maxTokens: 900
        )
        let cited = Self.citedLabels(in: answer).compactMap { label in usable.first { $0.label == label }?.nodeID }
        return FCChatMessage(role: .assistant, text: answer, citations: cited, model: llm.label)
    }

    static func citedLabels(in text: String) -> [String] {
        var labels: [String] = []
        for group in TrayAIRegex.groups(#"\[(S\d+(?:\s*,\s*S\d+)*)\]"#, in: text) {
            guard let inner = group.first else { continue }
            for label in inner.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !labels.contains(label) {
                labels.append(label)
            }
        }
        return labels
    }

    struct Passage { var text: String; var label: String; var nodeID: UUID; var score: Double }

    /// Keyword retrieval over sentences (the no-model chat fallback).
    static func retrieve(terms: [String], from inputs: [FCInputItem], limit: Int) -> [Passage] {
        guard !terms.isEmpty else { return [] }
        var passages: [Passage] = []
        for item in inputs {
            for sentence in FCText.sentences(item.fullText) where sentence.count >= 15 && sentence.count <= 500 {
                let score = FCText.score(sentence, terms: terms)
                if score > 0 { passages.append(Passage(text: sentence, label: item.label, nodeID: item.nodeID, score: score)) }
            }
        }
        return Array(passages.sorted { $0.score > $1.score }.prefix(limit))
    }
}

// MARK: - Rule-based extraction

/// Pattern matching for Extract fields when no model is available (and as a
/// fallback when the model fails): prices, plan names, feature bullets, and
/// "Field: value" lines.
enum FCRuleExtractor {
    static let planWords = ["Free", "Hobby", "Starter", "Basic", "Personal", "Plus", "Pro", "Professional", "Premium",
                            "Growth", "Team", "Teams", "Business", "Scale", "Enterprise", "Ultimate", "Standard", "Advanced"]

    static func isPriceField(_ field: String) -> Bool {
        let lower = field.lowercased()
        return ["price", "pricing", "cost", "fee", "rate"].contains { lower.contains($0) }
    }

    static func isPlanField(_ field: String) -> Bool {
        let lower = field.lowercased()
        return lower.contains("plan") || lower.contains("tier") || lower.contains("edition")
    }

    static func isFeatureField(_ field: String) -> Bool {
        field.lowercased().contains("feature")
    }

    static func terms(for fields: [String]) -> [String] {
        var terms: [String] = []
        for field in fields {
            terms += FCText.keywords(field)
            if isPriceField(field) { terms += ["price", "pricing", "$", "€", "£", "/mo", "month", "year", "per user", "billed"] }
            if isPlanField(field) { terms += planWords.map { $0.lowercased() } + ["plan", "tier"] }
            if isFeatureField(field) { terms += ["feature", "include", "unlimited", "support", "integration"] }
        }
        return terms
    }

    static func extract(_ fields: [String], from text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for field in fields {
            if isPriceField(field) {
                result[field] = distinct(TrayAIRegex.matches(FCText.pricePattern, in: text).map { $0.trimmingCharacters(in: .whitespaces) }, limit: 6)
            } else if isPlanField(field) {
                var found: [String] = []
                for word in planWords where text.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
                    found.append(word)
                }
                result[field] = distinct(found, limit: 6)
            } else if isFeatureField(field) {
                let bullets = lines.filter { $0.hasPrefix("•") || $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("✓") }
                    .map { String($0.drop(while: { "•-*✓ ".contains($0) }).prefix(70)) }
                result[field] = distinct(bullets, limit: 6)
            } else {
                let key = field.lowercased()
                let matches = lines.filter { $0.lowercased().contains(key) }.map { line -> String in
                    if let colon = line.firstIndex(of: ":"), line[..<colon].lowercased().contains(key) {
                        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    }
                    return String(line.prefix(120))
                }
                result[field] = distinct(matches, limit: 2)
            }
        }
        return result
    }

    /// The smallest non-zero amount in a price cell ("Free; $12/mo; $30/mo" → 12).
    static func lowestPaidAmount(_ cell: String) -> Double? {
        TrayAIRegex.matches(#"[$€£¥₹]\s?\d[\d,]*(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:USD|EUR|GBP)"#, in: cell)
            .compactMap(FCText.amount).filter { $0 > 0 }.min()
    }

    /// "compare price, support and integrations" → ["price", "support", "integrations"].
    static func criteria(fromPrompt prompt: String) -> [String]? {
        let lower = prompt.lowercased()
        guard let range = lower.range(of: #"(compare|on|by|across)\s+"#, options: .regularExpression) else { return nil }
        let tail = lower[range.upperBound...].components(separatedBy: CharacterSet(charactersIn: ".?!")).first ?? ""
        let parts = tail.replacingOccurrences(of: " and ", with: ",").components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.split(separator: " ").count <= 3 }
        return parts.count >= 2 ? Array(parts.prefix(5)) : nil
    }

    private static func distinct(_ values: [String], limit: Int) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for value in values where !value.isEmpty && seen.insert(value.lowercased()).inserted {
            kept.append(value)
            if kept.count == limit { break }
        }
        return kept.joined(separator: "; ")
    }
}
