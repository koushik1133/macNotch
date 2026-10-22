import CoreGraphics
import Foundation

// AI-assisted building: the user types a goal in the prompt bar and SparkV
// proposes action cards and connections. The model writes a JSON plan
// limited to the known action types (guided generation on-device); the plan
// is validated, and a keyword heuristic produces one when the model is
// unavailable or returns something invalid. Plans are previewed as ghost
// cards until the user accepts them.

struct FCPlan: Equatable, Sendable {
    enum Ref: Equatable, Sendable {
        case allSources
        case source(Int)      // 0-based index into the plan's sources
        case step(String)
    }

    struct Step: Equatable, Sendable {
        var key: String
        var kind: FCNodeKind
        var title: String
        var inputs: [Ref]
        var fields: [String] = []
        var language: String?
        var prompt: String?
    }

    var steps: [Step]
    /// "On-device (Apple Intelligence)", "Groq …", or "Suggested by SparkV (rules)".
    var producedBy: String
    var note: String?

    var summary: String { steps.map(\.title).joined(separator: " → ") }
}

enum FCPlanError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "The suggested plan wasn't usable: \(reason)"
        }
    }
}

enum FCPlanner {
    static let actionNames: [String: FCNodeKind] = [
        "chat": .chat, "ask": .chat, "summarize": .summarize, "summary": .summarize, "extract": .extract,
        "compare": .compare, "report": .report, "write report": .report, "translate": .translate, "custom": .custom,
    ]
    static let maxSteps = 6

    // MARK: Model plan

    @MainActor
    static func plan(goal: String, sources: [FCNode], ai: FCAI) async -> FCPlan {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = ai.backend()
        let prompt = Self.prompt(goal: goal, sources: sources)
        var failure: String?
        switch backend {
        case .rules(let reason):
            failure = "Apple Intelligence \(reason)"
        case .onDevice:
            do {
                var json: String?
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    json = try await FCGuided.plan(prompt: prompt, actions: ["chat", "summarize", "extract", "compare", "report", "translate", "custom"])
                }
                #endif
                if json == nil {
                    json = try await FCLLM(backend: backend).complete(system: FCPrompts.plannerSystem, prompt: prompt + jsonInstructions, maxTokens: 700)
                }
                var plan = try parse(json ?? "", sourceCount: sources.count)
                plan.producedBy = backend.label
                return plan
            } catch {
                failure = error.localizedDescription
            }
        case .groq:
            do {
                let json = try await FCLLM(backend: backend).complete(system: FCPrompts.plannerSystem, prompt: prompt + jsonInstructions, maxTokens: 900, json: true)
                var plan = try parse(json, sourceCount: sources.count)
                plan.producedBy = backend.label
                return plan
            } catch {
                failure = error.localizedDescription
            }
        }
        var plan = heuristic(goal: goal, sourceCount: sources.count)
        plan.note = failure.map { "Used SparkV's built-in planner (\($0))." }
        return plan
    }

    static func prompt(goal: String, sources: [FCNode]) -> String {
        let list = sources.enumerated().map { index, node in
            "S\(index + 1): \(node.kind.title) — \(node.citationLabel)" + (node.source?.url.map { " (\($0.host ?? $0.lastPathComponent))" } ?? "")
        }.joined(separator: "\n")
        return "Source cards on the canvas:\n\(list.isEmpty ? "(none yet)" : list)\n\nGoal: \(goal)"
    }

    static let jsonInstructions = """


    Reply with only a JSON object: {"steps":[{"id":"a","action":"extract","title":"Pricing table","inputs":["sources"],"fields":["price","plans"]},{"id":"b","action":"compare","title":"Compare","inputs":["a"]}]}. \
    action is one of chat, summarize, extract, compare, report, translate, custom. extract needs "fields"; translate needs "language"; custom needs "prompt".
    """

    /// Validates a model's JSON plan.
    static func parse(_ json: String, sourceCount: Int) throws -> FCPlan {
        guard let object = ClickyReplyParser.jsonObject(in: json) else { throw FCPlanError.invalid("not JSON") }
        guard let rawSteps = object["steps"] as? [[String: Any]], !rawSteps.isEmpty else { throw FCPlanError.invalid("no steps") }
        var steps: [FCPlan.Step] = []
        var keys = Set<String>()
        for (index, raw) in rawSteps.prefix(maxSteps).enumerated() {
            let action = FCJSON.string(raw["action"]).lowercased()
            guard let kind = actionNames[action] else { throw FCPlanError.invalid("unknown action \"\(action)\"") }
            var key = FCJSON.string(raw["id"])
            if key.isEmpty || keys.contains(key) { key = "step\(index + 1)" }
            var refs: [FCPlan.Ref] = []
            let rawInputs = (raw["inputs"] as? [Any])?.map { FCJSON.string($0) } ?? [FCJSON.string(raw["inputs"])]
            for input in rawInputs where !input.isEmpty {
                let lower = input.lowercased()
                if lower == "sources" || lower == "all" || lower == "all sources" {
                    refs.append(.allSources)
                } else if lower.hasPrefix("s"), let number = Int(lower.dropFirst()), number >= 1 {
                    guard number <= max(sourceCount, 1) else { throw FCPlanError.invalid("refers to a missing source \(input)") }
                    if sourceCount > 0 { refs.append(.source(number - 1)) } else { refs.append(.allSources) }
                } else if keys.contains(input) {
                    refs.append(.step(input))
                } else {
                    // Only earlier steps may feed a step, so plans can't loop.
                    throw FCPlanError.invalid("step \(key) uses \"\(input)\", which isn't an earlier step")
                }
            }
            if refs.isEmpty { refs = steps.last.map { [.step($0.key)] } ?? [.allSources] }
            var step = FCPlan.Step(key: key, kind: kind, title: cleanTitle(FCJSON.string(raw["title"]), kind: kind), inputs: unique(refs))
            switch kind {
            case .extract:
                step.fields = ((raw["fields"] as? [Any])?.map { FCJSON.string($0) } ?? FCJSON.string(raw["fields"]).components(separatedBy: ","))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 40 }
                if step.fields.isEmpty { throw FCPlanError.invalid("extract step without fields") }
                step.fields = Array(step.fields.prefix(8))
            case .translate:
                let language = FCJSON.string(raw["language"])
                step.language = language.isEmpty ? "English" : language
            case .custom:
                let prompt = FCJSON.string(raw["prompt"])
                if prompt.isEmpty { throw FCPlanError.invalid("custom step without a prompt") }
                step.prompt = prompt
            default:
                let prompt = FCJSON.string(raw["prompt"])
                if !prompt.isEmpty { step.prompt = prompt }
            }
            keys.insert(key)
            steps.append(step)
        }
        return FCPlan(steps: mergingPerSourceSteps(steps), producedBy: "Model")
    }

    /// Models sometimes write one step per source ("extract from S1",
    /// "extract from S2"…). Same-kind, same-settings steps that each read
    /// single sources become one step reading all of them.
    static func mergingPerSourceSteps(_ steps: [FCPlan.Step]) -> [FCPlan.Step] {
        func onlySources(_ refs: [FCPlan.Ref]) -> Bool {
            !refs.isEmpty && refs.allSatisfy { if case .source = $0 { return true } else { return false } }
        }
        var result: [FCPlan.Step] = []
        var renamed: [String: String] = [:]
        for var step in steps {
            step.inputs = unique(step.inputs.map { ref in
                if case .step(let key) = ref, let target = renamed[key] { return .step(target) }
                return ref
            })
            if step.kind != .chat, onlySources(step.inputs),
               let index = result.lastIndex(where: { $0.kind == step.kind && $0.fields == step.fields && $0.language == step.language
                   && $0.prompt == step.prompt && onlySources($0.inputs) }) {
                result[index].inputs = unique(result[index].inputs + step.inputs)
                result[index].title = step.kind == .extract && !step.fields.isEmpty ? title(for: step.fields) : step.kind.title
                renamed[step.key] = result[index].key
                continue
            }
            result.append(step)
        }
        return result
    }

    private static func unique(_ refs: [FCPlan.Ref]) -> [FCPlan.Ref] {
        var result: [FCPlan.Ref] = []
        for ref in refs where !result.contains(ref) { result.append(ref) }
        if result.contains(.allSources) { result.removeAll { if case .source = $0 { return true }; return false } }
        return result
    }

    private static func cleanTitle(_ title: String, kind: FCNodeKind) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        return trimmed.isEmpty || trimmed.count > 40 ? kind.title : trimmed
    }

    // MARK: Heuristic plan

    /// Keyword plan: extract → compare → report, summarize, translate, chat.
    static func heuristic(goal: String, sourceCount: Int) -> FCPlan {
        let lower = goal.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        var steps: [FCPlan.Step] = []
        var last: String?

        let fields = fields(in: lower)
        let wantsCompare = has(["compare", "comparison", " vs", "versus", "competitor", "side by side", "difference", "better"])
        let wantsExtract = !fields.isEmpty || has(["extract", "pull out", "table", "fields", "spreadsheet"])
        let wantsReport = has(["report", "brief", "write up", "write-up", "document", "memo", "article", "source links", "with sources"])
        let wantsSummary = has(["summar", "tl;dr", "tldr", "overview", "key points", "gist", "notes"])
        let language = translationTarget(lower)
        let wantsChat = has(["ask", "chat", "question", "q&a", "talk to"])

        if wantsExtract || (wantsCompare && sourceCount > 1) {
            let list = fields.isEmpty ? (wantsCompare ? ["key points", "price", "strengths", "limitations"] : ["key points"]) : fields
            steps.append(FCPlan.Step(key: "extract", kind: .extract, title: title(for: list), inputs: [.allSources], fields: list))
            last = "extract"
        }
        if wantsCompare {
            steps.append(FCPlan.Step(key: "compare", kind: .compare, title: "Compare", inputs: last.map { [.step($0)] } ?? [.allSources],
                                     prompt: goal))
            last = "compare"
        }
        if wantsSummary && !wantsCompare {
            steps.append(FCPlan.Step(key: "summary", kind: .summarize, title: has(["notes"]) ? "Notes" : "Summary", inputs: [.allSources]))
            last = last ?? "summary"
        }
        if let language {
            steps.append(FCPlan.Step(key: "translate", kind: .translate, title: "Translate to \(language)",
                                     inputs: last.map { [.step($0)] } ?? [.allSources], language: language))
            last = "translate"
        }
        if wantsReport {
            // The comparison already carries the extracted table.
            var inputs: [FCPlan.Ref] = steps.filter { $0.kind != .translate && !(wantsCompare && $0.kind == .extract) }.map { .step($0.key) }
            if inputs.isEmpty { inputs = [.allSources] }
            steps.append(FCPlan.Step(key: "report", kind: .report, title: wantsCompare ? "Comparison report" : "Report", inputs: inputs, prompt: goal))
        }
        if wantsChat || steps.isEmpty {
            if steps.isEmpty && !wantsChat {
                steps.append(FCPlan.Step(key: "custom", kind: .custom, title: "Custom prompt", inputs: [.allSources], prompt: goal))
            } else {
                steps.append(FCPlan.Step(key: "chat", kind: .chat, title: "Ask", inputs: [.allSources]))
            }
        }
        return FCPlan(steps: Array(steps.prefix(maxSteps)), producedBy: "Suggested by SparkV (rules)")
    }

    /// Field names mentioned in a goal ("pricing and features" → price, plans, features).
    static func fields(in lower: String) -> [String] {
        var fields: [String] = []
        if let range = lower.range(of: #"(fields?|columns?)\s*[:=]\s*"#, options: .regularExpression) {
            let tail = lower[range.upperBound...].components(separatedBy: CharacterSet(charactersIn: ".;\n")).first ?? ""
            fields = tail.replacingOccurrences(of: " and ", with: ",").components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !fields.isEmpty { return Array(fields.prefix(8)) }
        }
        if lower.contains("pric") || lower.contains("cost") { fields += ["price", "plans"] }
        if lower.contains("plan") && !fields.contains("plans") { fields.append("plans") }
        if lower.contains("feature") { fields.append("features") }
        if lower.contains("integration") { fields.append("integrations") }
        if lower.contains("support") { fields.append("support") }
        if lower.contains("free trial") || lower.contains("trial") { fields.append("free trial") }
        if lower.contains("date") || lower.contains("deadline") { fields.append("dates") }
        if lower.contains("contact") || lower.contains("email") { fields.append("contact") }
        return fields
    }

    private static func title(for fields: [String]) -> String {
        let joined = fields.prefix(3).joined(separator: ", ")
        return joined.count <= 32 ? joined.prefix(1).uppercased() + joined.dropFirst() : "Extract fields"
    }

    static func translationTarget(_ lower: String) -> String? {
        guard let range = lower.range(of: #"translat\w*\s+(?:it\s+|them\s+|this\s+)?(?:in)?to\s+([a-z]+)"#, options: .regularExpression) else { return nil }
        let word = lower[range].split(separator: " ").last.map(String.init) ?? ""
        return word.isEmpty ? nil : word.prefix(1).uppercased() + word.dropFirst()
    }

    // MARK: Layout as ghost cards

    /// Cards and edges for a plan, placed to the right of `sources`.
    static func materialize(_ plan: FCPlan, sources: [FCNode], near origin: CGPoint) -> ([FCNode], [FCEdge]) {
        let startX = (sources.map { $0.x + $0.width }.max() ?? Double(origin.x)) + 120
        let midY = sources.isEmpty ? Double(origin.y) : (sources.map(\.y).min()! + sources.map(\.y).max()!) / 2
        var nodes: [FCNode] = []
        var edges: [FCEdge] = []
        var byKey: [String: FCNode] = [:]
        var depth: [String: Int] = [:]
        var rows: [Int: Int] = [:]
        for step in plan.steps {
            let level = step.inputs.compactMap { ref -> Int? in
                if case .step(let key) = ref { return depth[key] }
                return nil
            }.max().map { $0 + 1 } ?? 0
            depth[step.key] = level
            let row = rows[level, default: 0]
            rows[level] = row + 1
            var config = FCActionConfig()
            config.fields = step.fields
            config.language = step.language ?? "English"
            config.prompt = step.prompt ?? ""
            let x = startX + Double(level) * 380
            let y = midY - 60 + Double(row) * 300
            let node = FCNode(kind: step.kind, title: step.title, at: CGPoint(x: x, y: y), config: config)
            byKey[step.key] = node
            nodes.append(node)
            for ref in step.inputs {
                switch ref {
                case .allSources:
                    edges += sources.map { FCEdge(from: $0.id, to: node.id) }
                case .source(let index):
                    if sources.indices.contains(index) { edges.append(FCEdge(from: sources[index].id, to: node.id)) }
                case .step(let key):
                    if let from = byKey[key] { edges.append(FCEdge(from: from.id, to: node.id)) }
                }
            }
        }
        return (nodes, edges)
    }
}
