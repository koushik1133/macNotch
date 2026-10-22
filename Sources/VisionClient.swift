import Foundation

// MARK: - Shared reply types

/// The Groq vision model Clicky asks (see console.groq.com/docs/vision).
/// `qwen/qwen3.6-27b` and Llama 4 Scout were shut down on Groq in 2026; their
/// stored ids map to the successor through `stored(_:)`.
enum ClickyModel: String, CaseIterable, Identifiable, Sendable {
    case qwen = "qwen/qwen3.8-27b"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qwen: "Qwen 3.8 27B (vision)"
        }
    }

    var shortTitle: String {
        switch self {
        case .qwen: "Qwen 3.8"
        }
    }

    /// The model for a stored defaults value; retired ids fall back to the default.
    static func stored(_ raw: String?) -> ClickyModel {
        raw.flatMap(ClickyModel.init(rawValue:)) ?? .qwen
    }
}

/// Where to point, in screenshot pixels (origin top-left, y down).
struct ClickyPoint: Equatable, Sendable {
    var x: Double
    var y: Double
    var label: String
}

struct ClickyReply: Equatable, Sendable {
    var answer: String
    var point: ClickyPoint?
}

/// A line of text read on screen, with its center on the `ClickyPrompt.grid`
/// (0...1000) scale, sent as a grounding hint next to the screenshot.
struct ClickyTextHint: Equatable, Sendable {
    var text: String
    var x: Int
    var y: Int
}

// MARK: - Parsing

/// Turns a model's reply into `ClickyReply`. Accepts the strict JSON the
/// prompt asks for, and also the usual deviations: code fences, prose around
/// the object, numbers sent as strings, `[x, y]` arrays, Qwen's `bbox_2d`
/// boxes, `[POINT:x,y:label]` tags, normalized (0...1) coordinates, and a
/// bare sentence with no JSON at all.
///
/// `coordinateScale` is the grid the prompt asked for: nil for screenshot
/// pixels, or e.g. 1000 when x and y run 0...1000 across the image (the
/// native grounding grid of Qwen 3 vision models). Either way the returned
/// point is in screenshot pixels.
enum ClickyReplyParser {
    static func parse(_ text: String, imageSize: CGSize, coordinateScale: Double? = nil) -> ClickyReply? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let object = jsonObject(in: trimmed) {
            var answerText = stringValue(object["answer"]) ?? stringValue(object["text"])
                ?? stringValue(object["response"]) ?? ""
            // A tag inside the answer string still counts as the point.
            let tagged = pointTag(in: answerText)
            answerText = tagged.text
            // Qwen's own grounding format puts the label next to the box:
            // {"bbox_2d": [...], "label": "Export"}.
            var topBox = rawPoint(object["bbox_2d"] ?? object["bbox"])
            if topBox != nil, topBox?.label.isEmpty == true {
                topBox?.label = stringValue(object["label"]) ?? stringValue(object["name"]) ?? ""
            }
            let point = pointValue(object["point"], imageSize: imageSize, coordinateScale: coordinateScale)
                ?? topBox.flatMap { point(fromRaw: $0, imageSize: imageSize, coordinateScale: coordinateScale) }
                ?? tagged.point.flatMap { point(fromRaw: $0, imageSize: imageSize, coordinateScale: coordinateScale) }
            let answer = cleanAnswer(spokenPositions(in: answerText, imageSize: imageSize, coordinateScale: coordinateScale))
            if !answer.isEmpty {
                return ClickyReply(answer: answer, point: point)
            }
            if let point {
                return ClickyReply(answer: pointOnlyAnswer(point), point: point)
            }
        }

        // No usable JSON: speak the text itself, minus anything code-like.
        let tagged = pointTag(in: stripFences(trimmed))
        let fallback = cleanAnswer(spokenPositions(in: tagged.text, imageSize: imageSize, coordinateScale: coordinateScale))
        let tagPoint = tagged.point.flatMap { point(fromRaw: $0, imageSize: imageSize, coordinateScale: coordinateScale) }
        guard !fallback.isEmpty else {
            if let tagPoint { return ClickyReply(answer: pointOnlyAnswer(tagPoint), point: tagPoint) }
            return nil
        }
        guard fallback.hasPrefix("{") else { return ClickyReply(answer: fallback, point: tagPoint) }
        // Broken or cut-off JSON: a complete "answer" string is still speakable.
        if let answer = answerString(inBrokenJSON: fallback) {
            return ClickyReply(answer: answer, point: nil)
        }
        return nil
    }

    /// What to say for a reply that only pointed.
    static func pointOnlyAnswer(_ point: ClickyPoint) -> String {
        point.label == "Here" ? "It's right here." : "It's \(point.label), right here."
    }

    /// The value of a complete `"answer": "..."` pair in otherwise invalid JSON.
    static func answerString(inBrokenJSON text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""answer"\s*:\s*("(?:[^"\\]|\\.)*")"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let data = String(text[range]).data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        else { return nil }
        let answer = cleanAnswer(pointTag(in: decoded).text)
        return answer.isEmpty ? nil : answer
    }

    /// The first balanced `{...}` in `text` that parses as a JSON object.
    static func jsonObject(in text: String) -> [String: Any]? {
        let candidate = stripFences(text)
        let chars = Array(candidate.unicodeScalars)
        var index = 0
        while index < chars.count {
            if chars[index] == "{", let end = matchingBrace(chars, from: index) {
                let slice = String(String.UnicodeScalarView(chars[index...end]))
                if let data = slice.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return object
                }
            }
            index += 1
        }
        return nil
    }

    private static func matchingBrace(_ chars: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }

    private static func stripFences(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Raw coordinates before scaling: (x, y, label).
    struct RawPoint: Equatable {
        var x: Double
        var y: Double
        var label: String
    }

    private static let tagRegex = try? NSRegularExpression(
        pattern: #"\[POINT:\s*(-?[0-9.]+)\s*,\s*(-?[0-9.]+)\s*(?::\s*([^\]:]*))?(?::[^\]]*)?\]"#,
        options: [.caseInsensitive]
    )

    /// Removes `[POINT:x,y:label(:screenN)]` tags (the open-source Clicky
    /// format some models imitate) and returns the first one.
    static func pointTag(in text: String) -> (text: String, point: RawPoint?) {
        guard let regex = tagRegex, text.localizedCaseInsensitiveContains("[POINT:") else { return (text, nil) }
        let range = NSRange(text.startIndex..., in: text)
        var found: RawPoint?
        if let match = regex.firstMatch(in: text, range: range),
           let xr = Range(match.range(at: 1), in: text), let yr = Range(match.range(at: 2), in: text),
           let x = Double(text[xr]), let y = Double(text[yr]) {
            var label = ""
            if let lr = Range(match.range(at: 3), in: text) {
                label = String(text[lr]).trimmingCharacters(in: .whitespaces)
            }
            found = RawPoint(x: x, y: y, label: label)
        }
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (stripped, found)
    }

    private static let coordinateRegex = try? NSRegularExpression(
        pattern: #"(?:\s+(?:at|near|around))?\s*\(\s*(-?[0-9]+(?:\.[0-9]+)?)\s*,\s*(-?[0-9]+(?:\.[0-9]+)?)\s*\)"#,
        options: [.caseInsensitive]
    )

    /// Replaces "(1249, 221)" in an answer (small models echo the positions
    /// they were given) with words such as "at the top right": coordinates
    /// are useless spoken aloud.
    static func spokenPositions(in text: String, imageSize: CGSize, coordinateScale: Double?) -> String {
        guard let regex = coordinateRegex, text.contains("(") else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let xr = Range(match.range(at: 1), in: result), let yr = Range(match.range(at: 2), in: result),
                  let x = Double(result[xr]), let y = Double(result[yr]) else { continue }
            var words = ""
            if let point = point(fromRaw: RawPoint(x: x, y: y, label: ""), imageSize: imageSize, coordinateScale: coordinateScale) {
                words = " " + regionPhrase(x: point.x / Double(imageSize.width), y: point.y / Double(imageSize.height))
            }
            result.replaceSubrange(whole, with: words)
        }
        return result
    }

    /// "at the top right", "in the center", "on the left side"... for a
    /// position given as fractions of the screen (0...1, y down).
    static func regionPhrase(x: Double, y: Double) -> String {
        let column = x < 1.0 / 3 ? "left" : (x > 2.0 / 3 ? "right" : "")
        let row = y < 1.0 / 3 ? "top" : (y > 2.0 / 3 ? "bottom" : "")
        switch (row, column) {
        case ("", ""): return "in the center"
        case ("", let side): return "on the \(side) side"
        case (let edge, ""): return "at the \(edge)"
        case (let edge, let side): return "at the \(edge) \(side)"
        }
    }

    /// A point from `{"x","y","label"}`, `[x, y]`, `[x1, y1, x2, y2]` or a
    /// dict holding `bbox_2d`.
    private static func pointValue(_ value: Any?, imageSize: CGSize, coordinateScale: Double?) -> ClickyPoint? {
        guard let raw = rawPoint(value) else { return nil }
        return point(fromRaw: raw, imageSize: imageSize, coordinateScale: coordinateScale)
    }

    static func rawPoint(_ value: Any?) -> RawPoint? {
        switch value {
        case let dict as [String: Any]:
            let label = stringValue(dict["label"]) ?? stringValue(dict["name"]) ?? ""
            if let x = doubleValue(dict["x"]), let y = doubleValue(dict["y"]) {
                return RawPoint(x: x, y: y, label: label)
            }
            if var box = rawPoint(dict["bbox_2d"] ?? dict["bbox"] ?? dict["box"]) {
                box.label = label.isEmpty ? box.label : label
                return box
            }
            return nil
        case let array as [Any]:
            let numbers = array.compactMap(doubleValue)
            guard numbers.count == array.count else { return nil }
            if numbers.count == 2 { return RawPoint(x: numbers[0], y: numbers[1], label: "") }
            if numbers.count == 4 {
                return RawPoint(x: (numbers[0] + numbers[2]) / 2, y: (numbers[1] + numbers[3]) / 2, label: "")
            }
            return nil
        default:
            return nil
        }
    }

    static func point(fromRaw raw: RawPoint, imageSize: CGSize, coordinateScale: Double?) -> ClickyPoint? {
        var x = raw.x, y = raw.y
        guard x.isFinite, y.isFinite else { return nil }
        let width = Double(imageSize.width), height = Double(imageSize.height)
        guard width > 0, height > 0 else { return nil }

        if x > 0, y > 0, x <= 1, y <= 1, (x < 1 || y < 1), width > 2, height > 2 {
            // Some replies use 0...1 fractions despite the instructions.
            x *= width
            y *= height
        } else if let scale = coordinateScale, scale > 1,
                  x <= scale * 1.02, y <= scale * 1.02 {
            x = x / scale * width
            y = y / scale * height
        }
        // Otherwise (no grid, or values beyond it) the reply is in pixels.
        // A point well outside the image is a hallucination, not a target.
        let slackX = width * 0.05, slackY = height * 0.05
        guard x >= -slackX, x <= width + slackX, y >= -slackY, y <= height + slackY else { return nil }
        x = min(max(x, 0), width - 1)
        y = min(max(y, 0), height - 1)

        var label = cleanAnswer(raw.label)
        if label.isEmpty { label = "Here" }
        if label.count > 40 { label = String(label.prefix(39)) + "…" }
        return ClickyPoint(x: x, y: y, label: label)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // JSON booleans also arrive as NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// One line of speakable text: no markdown emphasis, headings or bullets,
    /// collapsed whitespace.
    static func cleanAnswer(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        let lines = s.components(separatedBy: .newlines).map { line -> String in
            var line = line.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { line.removeFirst(2) }
            return line
        }
        let parts = lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}

// MARK: - Prompt

extension ClickyExchange {
    /// The turn as the model would have written it, for conversation context.
    var replyJSON: String {
        var object: [String: Any] = ["answer": answer, "point": NSNull()]
        if let gridPoint {
            object["point"] = ["x": gridPoint.x.rounded(), "y": gridPoint.y.rounded(), "label": gridPoint.label]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return answer }
        return text
    }
}

enum ClickyPrompt {
    /// x and y in replies run 0...grid across the screenshot.
    static let grid: Double = 1000

    static var system: String { system(hasScreenshot: true) }

    static func system(hasScreenshot: Bool) -> String {
        let intro = """
        You are Clicky, a friendly screen assistant that lives in the notch of the user's Mac. \
        The user holds a hotkey, asks a question out loud about what is on their screen, and hears your answer spoken aloud. \
        The question comes from speech recognition, so it may contain misheard words; read it charitably. \
        Earlier turns of the conversation may come first; use them for follow-up questions such as "and then what?"
        """
        let input = hasScreenshot ? """
        You get one screenshot of the display under their mouse pointer, the pointer position, the frontmost app, \
        some of the text read on screen with its position, and the question. Always answer from the newest screenshot.
        """ : """
        This time there is NO screenshot: SparkV could not capture the screen. You only get the frontmost app and the question. \
        Answer from general knowledge of macOS and that app; never pretend to see the screen.
        """
        let format = """
        Reply with a single JSON object and nothing else:
        {"answer": "<1-3 short spoken sentences>", "point": {"x": <number>, "y": <number>, "label": "<element name>"} or null}

        answer: natural, concise speech, at most about 50 words. No markdown, lists, URLs, emoji or keyboard symbols; \
        say "Command S", not "⌘S". Be concrete: name the button, menu, tab or field and where it is.
        """
        let point = hasScreenshot ? """
        point: when the answer involves one specific element the user should look at or click, give the center of that \
        element in relative coordinates from 0 to 1000 (x from the left edge to the right edge, y from the top edge \
        to the bottom edge of the screenshot, so the center of the screen is 500, 500), with a 1-4 word label such as \
        "Export button". Otherwise null. \
        If the thing they ask about is not visible, say so briefly, suggest where to find it, and use null.
        """ : """
        point: always null.
        """
        return [intro, input, format, point].joined(separator: "\n")
    }

    /// Budget for on-screen text hints in the Groq prompt.
    static let hintCharacterBudget = 1400
    static let maxHints = 40

    static func userText(
        question: String, imageSize: CGSize, cursor: CGPoint?, appName: String?,
        screenText: [ClickyTextHint] = [], hasScreenshot: Bool = true
    ) -> String {
        var lines: [String] = []
        if hasScreenshot, imageSize.width > 0, imageSize.height > 0 {
            lines.append("Screenshot size: \(Int(imageSize.width))×\(Int(imageSize.height)) pixels.")
            if let cursor {
                let x = Int((cursor.x / imageSize.width * grid).rounded())
                let y = Int((cursor.y / imageSize.height * grid).rounded())
                lines.append("Mouse pointer at (\(x), \(y)) on the 0-1000 grid.")
            }
        } else {
            lines.append("No screenshot is available.")
        }
        if let appName, !appName.isEmpty {
            lines.append("Frontmost app: \(appName).")
        }
        if hasScreenshot, !screenText.isEmpty {
            lines.append("Some text read on screen, with its center on the 0-1000 grid:")
            var budget = hintCharacterBudget
            for hint in screenText.prefix(maxHints) {
                let text = hint.text.count > 60 ? String(hint.text.prefix(59)) + "…" : hint.text
                let line = "- \"\(text)\" (\(hint.x), \(hint.y))"
                guard budget - line.count >= 0 else { break }
                budget -= line.count
                lines.append(line)
            }
        }
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }

    /// Earlier turns sent before the new question, oldest first. Only recent
    /// ones count, so an old conversation never colours a fresh question.
    static func context(from exchanges: [ClickyExchange], now: Date = Date()) -> [ClickyExchange] {
        let recent = exchanges.filter { now.timeIntervalSince($0.date) < contextWindow }
        return Array(recent.prefix(maxContextTurns).reversed())
    }

    static let maxContextTurns = 3
    static let contextWindow: TimeInterval = 10 * 60

    /// Structured-output schema: the API then guarantees the shape above.
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "answer": ["type": "string"],
            "point": [
                "anyOf": [
                    [
                        "type": "object",
                        "properties": [
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                            "label": ["type": "string"],
                        ],
                        "required": ["x", "y", "label"],
                        "additionalProperties": false,
                    ] as [String: Any],
                    ["type": "null"],
                ],
            ] as [String: Any],
        ] as [String: Any],
        "required": ["answer", "point"],
        "additionalProperties": false,
    ] }
}

// MARK: - Client

enum VisionClientError: LocalizedError, Equatable {
    case invalidKey
    case rateLimited
    case overloaded
    case refused
    case truncated
    case badResponse
    case timedOut
    case modelUnavailable(String)
    case http(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Groq rejected the API key"
        case .rateLimited: "Groq rate limit hit, try again shortly"
        case .overloaded: "Groq is busy right now, try again"
        case .refused: "The model declined to answer that"
        case .truncated: "The answer was cut off"
        case .badResponse: "Couldn't read the model's answer"
        case .timedOut: "Groq took too long. Try again"
        case .modelUnavailable(let model): "Groq no longer offers \(model). Update SparkV"
        case .http(let code, _): "Groq error \(code). Try again"
        case .network: "Can't reach Groq. Check your connection"
        }
    }
}

/// One HTTPS round trip, injectable so tests never touch the network.
protocol ClickyHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?)
}

/// Ephemeral session: nothing (screenshots included) is cached on disk.
struct ClickyURLSessionTransport: ClickyHTTPTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = VisionClient.attemptTimeout
        configuration.timeoutIntervalForResource = VisionClient.overallTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await Self.session.data(for: request)
        return (data, response as? HTTPURLResponse)
    }
}

/// When a failed Groq call is worth one more try, and after how long.
struct ClickyRetryPolicy: Sendable, Equatable {
    var maxAttempts = 2
    var baseDelay: Double = 0.6
    /// A longer Retry-After is not worth waiting for in a spoken exchange.
    var maxRetryAfter: Double = 4

    /// Seconds to wait before attempt `attempt + 1`, or nil to give up.
    func delay(after error: VisionClientError, attempt: Int, retryAfter: Double?) -> Double? {
        guard attempt < maxAttempts else { return nil }
        switch error {
        case .overloaded, .network:
            return baseDelay * Double(attempt)
        case .rateLimited:
            let wait = retryAfter ?? 1.5
            return wait <= maxRetryAfter ? max(wait, baseDelay) : nil
        case .http(let code, _) where code >= 500:
            return baseDelay * Double(attempt)
        default:
            return nil
        }
    }
}

/// Everything one question sends to a model.
struct ClickyVisionInput: Sendable {
    var question: String
    /// nil when the screen could not be captured: the request is text-only.
    var jpeg: Data?
    /// Pixel size of the screenshot (`.zero` without one).
    var imageSize: CGSize
    var cursor: CGPoint?
    var appName: String?
    var history: [ClickyExchange] = []
    var screenText: [ClickyTextHint] = []

    var hasScreenshot: Bool { jpeg != nil && imageSize.width > 0 && imageSize.height > 0 }
}

/// Minimal Groq client (OpenAI-compatible Chat Completions over raw HTTPS).
/// One request per question: screenshot + question in, a small JSON reply out.
/// The API key is passed in per request and only ever sent to api.groq.com.
struct VisionClient: Sendable {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    /// One attempt; a spoken answer that takes longer is not worth waiting for.
    static let attemptTimeout: TimeInterval = 20
    /// All attempts together.
    static let overallTimeout: TimeInterval = 35

    let apiKey: String
    let model: ClickyModel
    var transport: any ClickyHTTPTransport = ClickyURLSessionTransport()
    var retry = ClickyRetryPolicy()
    /// Injectable pause between attempts (tests pass a no-op).
    var sleep: @Sendable (Double) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    init(apiKey: String, model: ClickyModel, transport: any ClickyHTTPTransport = ClickyURLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    @MainActor private static var lastPrewarm = Date.distantPast

    /// Opens (or refreshes) the TLS connection to Groq in the shared session
    /// while the user is still speaking, so the real request skips the
    /// handshake. Sends no key and no data; at most once every 30 s.
    @MainActor
    static func prewarm() {
        let now = Date()
        guard now.timeIntervalSince(lastPrewarm) > 30 else { return }
        lastPrewarm = now
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let session = ClickyURLSessionTransport.session
        Task.detached(priority: .utility) { _ = try? await session.data(for: request) }
    }

    /// Request body as JSON data. Separate from `ask` so it can be checked
    /// without a network call. `history` is earlier turns, oldest first; only
    /// their text is sent (Groq takes at most three images per request).
    static func requestBody(model: ClickyModel, input: ClickyVisionInput) throws -> Data {
        let hasScreenshot = input.hasScreenshot
        var messages: [[String: Any]] = [["role": "system", "content": ClickyPrompt.system(hasScreenshot: hasScreenshot)]]
        for turn in input.history {
            messages.append(["role": "user", "content": "Question: \(turn.question)"])
            messages.append(["role": "assistant", "content": turn.replyJSON])
        }
        let text = ClickyPrompt.userText(
            question: input.question, imageSize: input.imageSize, cursor: input.cursor,
            appName: input.appName, screenText: input.screenText, hasScreenshot: hasScreenshot
        )
        if hasScreenshot, let jpeg = input.jpeg {
            messages.append([
                "role": "user",
                "content": [
                    ["type": "text", "text": text],
                    [
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
                    ] as [String: Any],
                ],
            ])
        } else {
            messages.append(["role": "user", "content": text])
        }
        let body: [String: Any] = [
            "model": model.rawValue,
            "max_completion_tokens": 512,
            "temperature": 0.2,
            // A spoken answer must come fast; Qwen's thinking adds seconds.
            "reasoning_effort": "none",
            "response_format": ["type": "json_object"],
            "messages": messages,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Compatibility wrapper for the screenshot case.
    static func requestBody(
        model: ClickyModel, question: String, jpeg: Data, imageSize: CGSize, cursor: CGPoint?, appName: String?,
        history: [ClickyExchange] = []
    ) throws -> Data {
        try requestBody(model: model, input: ClickyVisionInput(
            question: question, jpeg: jpeg, imageSize: imageSize, cursor: cursor, appName: appName, history: history
        ))
    }

    func makeRequest(_ input: ClickyVisionInput) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.attemptTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.httpBody = try Self.requestBody(model: model, input: input)
        return request
    }

    /// Asks once, retrying a transient failure (busy, dropped connection,
    /// short rate limit) at most `retry.maxAttempts - 1` times.
    func ask(_ input: ClickyVisionInput) async throws -> ClickyReply {
        let request = try makeRequest(input)
        let started = Date()
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await attemptOnce(request, imageSize: input.imageSize)
            } catch let failure as AttemptFailure {
                let elapsed = Date().timeIntervalSince(started)
                guard let wait = retry.delay(after: failure.error, attempt: attempt, retryAfter: failure.retryAfter),
                      elapsed + wait + 2 < Self.overallTimeout
                else { throw failure.error }
                AppLog.log("Clicky: Groq attempt \(attempt) failed (\(failure.error)); retrying in \(String(format: "%.1f", wait)) s")
                try await sleep(wait)
                attempt += 1
            }
        }
    }

    private struct AttemptFailure: Error {
        let error: VisionClientError
        let retryAfter: Double?
    }

    private func attemptOnce(_ request: URLRequest, imageSize: CGSize) async throws -> ClickyReply {
        let data: Data
        let response: HTTPURLResponse?
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw VisionClientError.timedOut
            case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
                // Offline: retrying in under a second won't help.
                throw VisionClientError.network(error.localizedDescription)
            default:
                throw AttemptFailure(error: .network(error.localizedDescription), retryAfter: nil)
            }
        } catch {
            throw AttemptFailure(error: .network(error.localizedDescription), retryAfter: nil)
        }
        let status = response?.statusCode ?? 0
        do {
            return try Self.parseResponse(data: data, status: status, imageSize: imageSize, model: model.rawValue)
        } catch let error as VisionClientError {
            let retryAfter = (response?.value(forHTTPHeaderField: "retry-after")).flatMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            throw AttemptFailure(error: error, retryAfter: retryAfter)
        }
    }

    /// Interprets a Chat Completions response (any status code). Points are
    /// read on `ClickyPrompt.grid` and returned in screenshot pixels.
    static func parseResponse(data: Data, status: Int, imageSize: CGSize, model: String = ClickyModel.qwen.rawValue) throws -> ClickyReply {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard status == 200 else {
            let error = json?["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? ""
            let code = (error?["code"] as? String) ?? ""
            AppLog.log("Clicky: Groq HTTP \(status) \(code) \(message.prefix(160))")
            // JSON mode rejected an almost-right reply; it is often still usable.
            if code == "json_validate_failed", let failed = error?["failed_generation"] as? String,
               let reply = ClickyReplyParser.parse(stripReasoning(failed), imageSize: imageSize, coordinateScale: ClickyPrompt.grid) {
                return reply
            }
            if code == "model_decommissioned" || code == "model_not_found"
                || (status == 404 && message.localizedCaseInsensitiveContains("model")) {
                throw VisionClientError.modelUnavailable(model)
            }
            switch status {
            case 401, 403: throw VisionClientError.invalidKey
            case 429: throw VisionClientError.rateLimited
            case 498, 500, 502, 503, 504: throw VisionClientError.overloaded
            case 0: throw VisionClientError.badResponse
            default: throw VisionClientError.http(status, String(message.prefix(80)))
            }
        }
        guard let json,
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else { throw VisionClientError.badResponse }

        let finishReason = choice["finish_reason"] as? String
        let text = stripReasoning(message["content"] as? String ?? "")
        if let usage = json["usage"] as? [String: Any] {
            AppLog.log("Clicky: \(json["model"] as? String ?? "?") in=\(usage["prompt_tokens"] ?? "?") out=\(usage["completion_tokens"] ?? "?") finish=\(finishReason ?? "?")")
        }
        if let reply = ClickyReplyParser.parse(text, imageSize: imageSize, coordinateScale: ClickyPrompt.grid) {
            return reply
        }
        if message["refusal"] is String { throw VisionClientError.refused }
        if finishReason == "length" { throw VisionClientError.truncated }
        if finishReason == "content_filter" { throw VisionClientError.refused }
        throw VisionClientError.badResponse
    }

    /// Reasoning models may prefix their thinking; only what follows matters.
    /// An unterminated `<think>` (cut off mid-thought) leaves nothing.
    static func stripReasoning(_ text: String) -> String {
        if let range = text.range(of: "</think>", options: .backwards) {
            return String(text[range.upperBound...])
        }
        if let open = text.range(of: "<think>") {
            return String(text[..<open.lowerBound])
        }
        return text
    }
}
