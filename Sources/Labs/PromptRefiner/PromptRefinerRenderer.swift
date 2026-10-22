import Foundation

// Lays out a PromptSpec for the chosen target. The model only fills fields;
// the layout is fixed here so every target gets the structure its vendor
// recommends (see DESIGN.md):
// - Claude Code / Claude: XML-tagged sections, context first, verification last
//   (platform.claude.com prompting best practices, code.claude.com best practices).
// - ChatGPT: Markdown sections in the GPT-4.1 cookbook order (Role and
//   Objective, Instructions, Output Format, Examples, Context).
// - Gemini: <role>/<constraints>/<context>/<task> tags with the task at the end
//   (ai.google.dev prompting strategies).
// - Image models: one descriptive paragraph + aspect ratio + plain "avoid" list
//   (Vertex AI image prompt guide).

enum PromptRefinerRenderer {
    static func render(_ spec: PromptSpec, target: PromptTarget) -> String {
        switch target {
        case .claudeCode: return claudeCode(spec)
        case .chatGPT: return chatGPT(spec)
        case .gemini: return gemini(spec)
        case .general, .imageModel: return general(spec)
        }
    }

    /// Fixed closing lines; the model's copies of them are dropped as items.
    static let claudeCodeClosing = "Ask me before making assumptions that change the scope. Show evidence (test or build output) instead of claiming success."
    static let chatGPTClosing = "If anything essential is missing, ask me one short question before answering."

    // MARK: Claude Code

    private static func claudeCode(_ spec: PromptSpec) -> String {
        var out: [String] = []
        if !spec.role.isEmpty { out.append(spec.role) }
        out.append(tag("task", spec.objective))
        if !spec.context.isEmpty { out.append(tag("context", bullets(spec.context))) }
        if !spec.inputs.isEmpty { out.append(tag("inputs", bullets(spec.inputs.map(placeholder)))) }
        if !spec.requirements.isEmpty { out.append(tag("requirements", numbered(spec.requirements))) }
        if !spec.constraints.isEmpty { out.append(tag("constraints", bullets(spec.constraints))) }
        if !spec.example.isEmpty { out.append(tag("example", spec.example)) }
        if !spec.acceptanceCriteria.isEmpty {
            out.append(tag("done_when", bullets(spec.acceptanceCriteria)))
        }
        if !spec.outputFormat.isEmpty { out.append(tag("report", spec.outputFormat)) }
        out.append(claudeCodeClosing)
        return out.joined(separator: "\n\n")
    }

    // MARK: ChatGPT

    private static func chatGPT(_ spec: PromptSpec) -> String {
        var out: [String] = []
        out.append("# Role and Objective\n" + [spec.role, spec.objective].filter { !$0.isEmpty }.joined(separator: " "))
        let instructions = MeetingAIText.dedupe(spec.requirements + spec.constraints)
        if !instructions.isEmpty { out.append("# Instructions\n" + bullets(instructions)) }
        if !spec.outputFormat.isEmpty { out.append("# Output Format\n" + spec.outputFormat) }
        if !spec.acceptanceCriteria.isEmpty { out.append("# Success Criteria\n" + bullets(spec.acceptanceCriteria)) }
        if !spec.example.isEmpty { out.append("# Example\n" + spec.example) }
        if !spec.context.isEmpty { out.append("# Context\n" + bullets(spec.context)) }
        if !spec.inputs.isEmpty { out.append("# Inputs\n" + bullets(spec.inputs.map(placeholder))) }
        out.append(chatGPTClosing)
        return out.joined(separator: "\n\n")
    }

    // MARK: Gemini

    private static func gemini(_ spec: PromptSpec) -> String {
        var out: [String] = []
        if !spec.role.isEmpty { out.append(tag("role", spec.role)) }
        let constraints = MeetingAIText.dedupe(spec.constraints + spec.acceptanceCriteria)
        if !constraints.isEmpty { out.append(tag("constraints", bullets(constraints))) }
        if !spec.context.isEmpty { out.append(tag("context", bullets(spec.context))) }
        if !spec.inputs.isEmpty { out.append(tag("inputs", bullets(spec.inputs.map(placeholder)))) }
        if !spec.example.isEmpty { out.append(tag("example", spec.example)) }
        if !spec.outputFormat.isEmpty { out.append(tag("output_format", spec.outputFormat)) }
        var task = spec.objective
        if !spec.requirements.isEmpty { task += "\n" + numbered(spec.requirements) }
        out.append(tag("task", "Based on the information above: " + task))
        return out.joined(separator: "\n\n")
    }

    // MARK: General

    private static func general(_ spec: PromptSpec) -> String {
        var out: [String] = []
        if !spec.role.isEmpty { out.append("## Role\n" + spec.role) }
        if !spec.context.isEmpty { out.append("## Context\n" + bullets(spec.context)) }
        out.append("## Task\n" + spec.objective + (spec.requirements.isEmpty ? "" : "\n" + numbered(spec.requirements)))
        if !spec.constraints.isEmpty { out.append("## Constraints\n" + bullets(spec.constraints)) }
        if !spec.inputs.isEmpty { out.append("## Inputs\n" + bullets(spec.inputs.map(placeholder))) }
        if !spec.outputFormat.isEmpty { out.append("## Output format\n" + spec.outputFormat) }
        if !spec.acceptanceCriteria.isEmpty { out.append("## A good answer\n" + bullets(spec.acceptanceCriteria)) }
        if !spec.example.isEmpty { out.append("## Example\n" + spec.example) }
        return out.joined(separator: "\n\n")
    }

    // MARK: Image

    static func render(_ spec: ImagePromptSpec) -> String {
        var sentence: [String] = []
        let lead = [spec.style, spec.subject].filter { !$0.isEmpty }
        if !lead.isEmpty {
            // "Photorealistic photo of …" reads better than "subject, style".
            sentence.append(spec.style.isEmpty ? spec.subject : "\(medium(spec.style)) of \(lowerFirst(spec.subject))")
        }
        if !spec.setting.isEmpty { sentence.append(spec.setting) }
        if !spec.composition.isEmpty { sentence.append(spec.composition) }
        if !spec.lighting.isEmpty { sentence.append(spec.lighting) }
        if !spec.colors.isEmpty { sentence.append(spec.colors) }
        if !spec.mood.isEmpty { sentence.append(spec.mood + " mood") }
        sentence += spec.details
        var text = sentence
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .,;")) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { $0.offset == 0 ? $0.element : lowerFirst($0.element) }
            .joined(separator: ", ")
        if !text.isEmpty { text = PromptRefinerTemplates.sentence(text) }
        var out = [text, "Aspect ratio: \(spec.aspectRatio)"]
        if !spec.avoid.isEmpty {
            out.append("Avoid: " + spec.avoid.map { lowerFirst(stripNegation($0)) }.joined(separator: ", "))
        }
        return out.joined(separator: "\n\n")
    }

    /// "Photorealistic" -> "Photorealistic image"; "3D render" stays.
    private static func medium(_ style: String) -> String {
        let nouns = ["photo", "photograph", "render", "illustration", "painting", "drawing", "artwork", "image",
                     "sketch", "watercolor", "poster", "logo", "icon", "art", "shot", "portrait", "graphic", "design"]
        let last = style.lowercased().split(separator: " ").last.map(String.init) ?? ""
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        return nouns.contains(where: { last == $0 || last == $0 + "s" }) ? trimmed : trimmed + " image"
    }

    // MARK: Helpers

    static func tag(_ name: String, _ body: String) -> String {
        "<\(name)>\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n</\(name)>"
    }

    static func bullets(_ items: [String]) -> String {
        items.map { "- " + $0 }.joined(separator: "\n")
    }

    static func numbered(_ items: [String]) -> String {
        items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// "The code" -> "[paste: the code]" so the user sees what to fill in.
    static func placeholder(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{{") { return trimmed }
        return "[paste: \(lowerFirst(trimmed))]"
    }

    private static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep acronyms and proper nouns ("API", "iPhone").
        let second = text.dropFirst().first
        if first.isUppercase, second?.isUppercase == true { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Image negative prompts work better as plain nouns ("text") than
    /// negations ("no text") — Vertex AI image prompt guide.
    private static func stripNegation(_ item: String) -> String {
        var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["no ", "don't include ", "do not include ", "without ", "avoid "]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text
    }
}
