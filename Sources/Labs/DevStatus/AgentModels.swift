import Foundation

// Pure logic for Coding Agents (Claude Code, Codex, Cursor): the session
// model, read-only parsers for each tool's local session files, the local
// hook endpoint's HTTP framing and validation, hook event parsing and the
// Allow / Deny reply formats. Foundation only, so the test harness compiles
// this file on its own.

// MARK: - Model

enum CodingAgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, cursor

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var shortTitle: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        }
    }

    /// Bundle IDs of the tool's own desktop app (used to jump back to it).
    var appBundleIDs: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        }
    }
}

enum CodingAgentState: String, Sendable, Codable, Comparable {
    /// Waiting for an approval or for the user's input.
    case waiting
    case working
    /// Finished its turn a short while ago.
    case finished
    case idle

    var title: String {
        switch self {
        case .waiting: "Needs you"
        case .working: "Working"
        case .finished: "Done"
        case .idle: "Idle"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .working: "circle.dotted"
        case .finished: "checkmark"
        case .idle: "moon.zzz.fill"
        }
    }

    private var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .finished: 2
        case .idle: 3
        }
    }

    static func < (lhs: CodingAgentState, rhs: CodingAgentState) -> Bool { lhs.rank < rhs.rank }
}

struct CodingAgentSession: Identifiable, Equatable, Sendable {
    var kind: CodingAgentKind
    var sessionID: String
    /// The session's name (Claude Code names sessions), if any.
    var name: String?
    var cwd: String?
    var branch: String?
    var state: CodingAgentState
    /// A short, content-free status line ("Waiting to run Bash", "Turn finished").
    var detail: String?
    var updatedAt: Date
    var pid: Int32?
    var tokensToday: Int?
    /// Codex rate-limit window use, 0...100.
    var limitPercent: Double?

    var id: String { kind.rawValue + ":" + sessionID }

    var project: String {
        guard let cwd, !cwd.isEmpty else { return name ?? kind.title }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    /// Waiting first, then working, then by recency.
    static func ordered(_ sessions: [CodingAgentSession]) -> [CodingAgentSession] {
        sessions.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            return $0.updatedAt > $1.updatedAt
        }
    }
}

/// How long a finished turn shows as "Done" before turning idle, and how
/// long a silent session counts as live at all.
enum CodingAgentTiming {
    static let finishedWindow: TimeInterval = 10 * 60
    static let liveWindow: TimeInterval = 6 * 3600
    /// A Cursor transcript written this recently means the agent is working.
    static let cursorWorkingWindow: TimeInterval = 90
}

// MARK: - Claude Code session registry (~/.claude/sessions/<pid>.json)

/// One running Claude Code process, as it describes itself in
/// ~/.claude/sessions/<pid>.json. Undocumented; every field is optional.
struct ClaudeRegistryEntry: Equatable, Sendable {
    var pid: Int32
    var sessionID: String
    var cwd: String?
    var name: String?
    var status: String?
    var updatedAt: Date?
    var statusUpdatedAt: Date?

    static func parse(_ data: Data) -> ClaudeRegistryEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        let session = (object["sessionId"] as? String) ?? "pid-\(pid)"
        func date(_ key: String) -> Date? {
            guard let ms = (object[key] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms > 10_000_000_000 ? ms / 1000 : ms)
        }
        return ClaudeRegistryEntry(
            pid: pid, sessionID: session,
            cwd: object["cwd"] as? String,
            name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            status: object["status"] as? String,
            updatedAt: date("updatedAt"),
            statusUpdatedAt: date("statusUpdatedAt") ?? date("updatedAt")
        )
    }

    /// Maps the free-form status word to a state; an idle session that
    /// changed recently has just finished a turn.
    func state(now: Date) -> CodingAgentState {
        let word = (status ?? "").lowercased()
        if ["busy", "running", "working", "thinking", "responding", "streaming", "tool_use"].contains(word) { return .working }
        if word.contains("wait") || word.contains("permission") || word.contains("input") || word.contains("blocked") || word.contains("approval") {
            return .waiting
        }
        if let changed = statusUpdatedAt, now.timeIntervalSince(changed) < CodingAgentTiming.finishedWindow, word == "idle" {
            return .finished
        }
        return .idle
    }
}

// MARK: - JSONL tails

enum JSONLTail {
    /// Complete lines in the last part of a file (the first, possibly cut,
    /// line is dropped when reading started mid-file).
    static func lines(_ data: Data, startedMidFile: Bool) -> [Data] {
        var parts = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
        if startedMidFile, !parts.isEmpty { parts.removeFirst() }
        return parts
    }

    /// Reads at most `limit` bytes from the end of the file.
    static func read(_ url: URL, limit: Int) -> (data: Data, midFile: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(limit) ? end - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }

    /// Reads at most `limit` bytes from the start of the file.
    static func head(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }

    /// The first `"key":"value"` string in raw JSON text, without parsing the
    /// whole (possibly huge) object.
    static func firstString(_ key: String, in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? Optional(String(decoding: data, as: UTF8.self)) else { return nil }
        let needle = "\"\(key)\":\""
        guard let range = text.range(of: needle) else { return nil }
        var result = ""
        var escaped = false
        for character in text[range.upperBound...] {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "/": result.append("/")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
            if result.count > 4096 { return nil }
        }
        return nil
    }

    // ISO8601DateFormatter is thread-safe for parsing.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let isoFormatterPlain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return isoFormatter.date(from: string) ?? isoFormatterPlain.date(from: string)
    }
}

/// What the tail of a Claude Code transcript (~/.claude/projects/*/<id>.jsonl)
/// says about its session. Message text is never kept.
struct ClaudeTranscriptSummary: Equatable, Sendable {
    var sessionID: String?
    var cwd: String?
    var branch: String?
    var lastActivity: Date?
    var state: CodingAgentState = .idle
    var tokensToday = 0

    static func parse(lines: [Data], now: Date, calendar: Calendar = .current) -> ClaudeTranscriptSummary {
        var summary = ClaudeTranscriptSummary()
        var lastKind: String?
        var lastStop: String?
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let type = object["type"] as? String
            if let id = object["sessionId"] as? String { summary.sessionID = id }
            if let cwd = object["cwd"] as? String { summary.cwd = cwd }
            if let branch = object["gitBranch"] as? String, !branch.isEmpty { summary.branch = branch }
            let stamp = JSONLTail.date(object["timestamp"])
            if let stamp { summary.lastActivity = max(summary.lastActivity ?? stamp, stamp) }
            guard type == "user" || type == "assistant" else { continue }
            if object["isSidechain"] as? Bool == true { continue }
            lastKind = type
            let message = object["message"] as? [String: Any]
            lastStop = message?["stop_reason"] as? String
            if type == "assistant", let usage = message?["usage"] as? [String: Any],
               let stamp, calendar.isDate(stamp, inSameDayAs: now) {
                summary.tokensToday += ClaudeTranscriptSummary.tokens(usage)
            }
        }
        switch (lastKind, lastStop) {
        case ("assistant", "end_turn"?), ("assistant", "stop_sequence"?), ("assistant", "max_tokens"?):
            summary.state = .finished
        case ("assistant", _), ("user", _):
            summary.state = .working
        default:
            summary.state = .idle
        }
        if summary.state != .idle, let last = summary.lastActivity {
            let age = now.timeIntervalSince(last)
            if summary.state == .finished, age > CodingAgentTiming.finishedWindow { summary.state = .idle }
            // A transcript that stopped mid-turn long ago was interrupted.
            if summary.state == .working, age > 15 * 60 { summary.state = .idle }
        }
        return summary
    }

    /// Billable tokens of one assistant message (input, output and cache writes;
    /// cache reads are cheap and excluded so the count tracks real use).
    static func tokens(_ usage: [String: Any]) -> Int {
        let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
        return keys.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
    }
}

/// What a Codex rollout (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) says.
struct CodexRolloutSummary: Equatable, Sendable {
    var sessionID: String?
    var cwd: String?
    var lastActivity: Date?
    var state: CodingAgentState = .idle
    var detail: String?
    var totalTokens: Int?
    var limitPercent: Double?

    /// `head` is the start of the file (the session_meta line), `lines` the tail.
    static func parse(head: Data?, lines: [Data], now: Date) -> CodexRolloutSummary {
        var summary = CodexRolloutSummary()
        if let head {
            summary.sessionID = JSONLTail.firstString("id", in: head)
            summary.cwd = JSONLTail.firstString("cwd", in: head)
        }
        var lastEvent: String?
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let stamp = JSONLTail.date(object["timestamp"]) {
                summary.lastActivity = max(summary.lastActivity ?? stamp, stamp)
            }
            guard let payload = object["payload"] as? [String: Any] else { continue }
            let type = object["type"] as? String
            if type == "session_meta" {
                summary.sessionID = (payload["id"] as? String) ?? summary.sessionID
                summary.cwd = (payload["cwd"] as? String) ?? summary.cwd
            }
            if type == "turn_context", let cwd = payload["cwd"] as? String { summary.cwd = cwd }
            guard type == "event_msg", let event = payload["type"] as? String else { continue }
            switch event {
            case "task_started", "task_complete", "turn_aborted", "exec_approval_request", "apply_patch_approval_request",
                 "request_user_input", "error", "agent_message", "user_message", "exec_command_begin", "exec_command_end":
                lastEvent = event
            case "token_count":
                if let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any],
                   let value = (total["total_tokens"] as? NSNumber)?.intValue {
                    summary.totalTokens = value
                }
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
                    let used = windows.compactMap { ($0["used_percent"] as? NSNumber)?.doubleValue }
                    if let worst = used.max() { summary.limitPercent = worst }
                }
            default:
                break
            }
        }
        switch lastEvent {
        case "exec_approval_request"?, "apply_patch_approval_request"?:
            summary.state = .waiting
            summary.detail = "Waiting for approval"
        case "request_user_input"?:
            summary.state = .waiting
            summary.detail = "Waiting for your answer"
        case "task_started"?, "agent_message"?, "user_message"?, "exec_command_begin"?, "exec_command_end"?:
            summary.state = .working
        case "task_complete"?:
            summary.state = .finished
            summary.detail = "Turn finished"
        case "turn_aborted"?, "error"?:
            summary.state = .idle
            summary.detail = lastEvent == "error" ? "Stopped with an error" : "Interrupted"
        default:
            summary.state = .idle
        }
        if let last = summary.lastActivity {
            let age = now.timeIntervalSince(last)
            if summary.state == .finished, age > CodingAgentTiming.finishedWindow { summary.state = .idle }
            if summary.state == .working, age > 15 * 60 { summary.state = .idle }
        }
        return summary
    }
}

/// Cursor keeps agent transcripts in
/// ~/.cursor/projects/<path-with-dashes>/agent-transcripts/<id>/<id>.jsonl
/// without timestamps, so the file's modification time is the signal.
struct CursorTranscriptSummary: Equatable, Sendable {
    var sessionID: String
    var projectKey: String
    var modified: Date
    var lastRole: String?

    func state(now: Date, cursorRunning: Bool) -> CodingAgentState {
        let age = now.timeIntervalSince(modified)
        if cursorRunning, age < CodingAgentTiming.cursorWorkingWindow, lastRole != "assistant-final" {
            return lastRole == "assistant" && age > 20 ? .finished : .working
        }
        if age < CodingAgentTiming.finishedWindow { return .finished }
        return .idle
    }

    static func lastRole(lines: [Data]) -> String? {
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let role = object["role"] as? String { return role }
        }
        return nil
    }
}

// MARK: - Folder names

enum AgentPaths {
    /// Claude Code and Cursor name project folders after the path with every
    /// "/" (and ".") turned into "-". Dashes inside names make that lossy, so
    /// the decoder walks the real disk: at each step it joins the next
    /// segment with "/" if that folder exists, else with "-" (or ".").
    static func decodeProjectFolder(_ encoded: String, exists: (String) -> Bool) -> String? {
        let segments = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty else { return nil }
        var budget = 4096
        // `path` ends in a component that may still grow ("Test" -> "Test-01");
        // starting a new component with "/" needs the current one to exist.
        func search(_ index: Int, _ path: String) -> String? {
            budget -= 1
            guard budget > 0 else { return nil }
            if index == segments.count { return exists(path) ? path : nil }
            let segment = segments[index]
            if segment.isEmpty {
                // "--" stands for "/." (a hidden folder) or a literal dash.
                if exists(path), let found = search(index + 1, path + "/.") { return found }
                return search(index + 1, path + "-")
            }
            if path.isEmpty || exists(path), let found = search(index + 1, path + "/" + segment) { return found }
            guard !path.isEmpty else { return nil }
            if let found = search(index + 1, path + "-" + segment) { return found }
            return search(index + 1, path + "." + segment)
        }
        let start = segments.first == "" ? 1 : 0
        return search(start, "")
    }

    /// Claude Code's project folder for a working folder: every character
    /// other than a letter, digit or dash becomes "-".
    static func claudeProjectFolder(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            let isWord = (scalar.value < 128) && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            return isWord ? Character(scalar) : "-"
        })
    }

    /// A readable fallback when the folder no longer exists: drop the
    /// "Users-<name>-" prefix and keep the rest.
    static func readableProjectKey(_ encoded: String, user: String = NSUserName()) -> String {
        var key = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        for prefix in ["Users-\(user)-", "Users-\(user)"] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
            break
        }
        return key.isEmpty ? "~" : key
    }
}

// MARK: - Hook endpoint: HTTP

/// Minimal HTTP/1.1 request framing for the 127.0.0.1 hook endpoint.
struct AgentHTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Lower-cased header names.
    var headers: [String: String]
    var body: Data
}

enum AgentHTTPParse: Equatable, Sendable {
    case needMore
    case complete(AgentHTTPRequest)
    case invalid(status: Int)
}

enum AgentHTTP {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 512 * 1024

    static func parse(_ buffer: Data) -> AgentHTTPParse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431) : .needMore
        }
        guard end.lowerBound <= maxHeaderBytes else { return .invalid(status: 431) }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid(status: 400) }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(status: 400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(status: 411) }
        let length: Int
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid(status: 400) }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .invalid(status: 413) }
        let bodyStart = end.upperBound
        let available = buffer.endIndex - bodyStart
        guard available >= length else { return .needMore }
        let body = buffer[bodyStart..<(bodyStart + length)]
        return .complete(AgentHTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body)))
    }

    /// Why a request is refused, or nil to accept it. Browsers can reach
    /// 127.0.0.1, so anything carrying an Origin or Fetch Metadata header is
    /// refused, the Host must be the loopback address (DNS rebinding), and the
    /// per-install token must match.
    static func rejection(_ request: AgentHTTPRequest, token: String, port: UInt16) -> Int? {
        guard request.method == "POST" else { return 405 }
        guard ["/v1/hook", "/v1/command"].contains(request.path) else { return 404 }
        if request.headers["origin"] != nil || request.headers["sec-fetch-site"] != nil || request.headers["sec-fetch-mode"] != nil {
            return 403
        }
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else { return 403 }
        guard let presented = request.headers["x-sparkv-token"], constantTimeEqual(presented, token), !token.isEmpty else { return 401 }
        return nil
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    static func response(status: Int, body: Data = Data(), contentType: String = "application/json") -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// 32 random bytes as hex.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

// MARK: - Hook events

/// How a hook expects Allow / Deny back, if at all.
enum AgentReplyStyle: String, Sendable, Equatable {
    case none
    /// Claude Code `PermissionRequest`.
    case claudePermissionRequest
    /// Claude Code `PreToolUse`.
    case claudePreToolUse
    /// Cursor `beforeShellExecution` / `beforeMCPExecution`.
    case cursorPermission
}

enum AgentDecision: String, Sendable, Equatable {
    case allow, deny
    /// Let the tool ask in its own window (timeout, "In Terminal").
    case ask
}

struct AgentHookEvent: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case started
        case working
        case needsApproval
        case needsInput
        case finished
        case ended
        case other
    }

    var kind: CodingAgentKind
    var eventName: String
    var phase: Phase
    var sessionID: String
    var cwd: String?
    var toolName: String?
    /// What the approval is about ("npm test", "Edit · App.swift"). Shown in
    /// the band for the user's decision; never logged.
    var toolSummary: String?
    /// The tool's own short notification text ("Claude is waiting for your input").
    var message: String?
    var replyStyle: AgentReplyStyle
    /// The hook script's parent process (the agent, or a shell under it).
    var callerPID: Int32?
    var terminalProgram: String?

    /// Parses a hook body. `source` is the X-SparkV-Source header.
    static func parse(body: Data, source: String?, callerPID: Int32?, terminalProgram: String?) -> AgentHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let term = terminalProgram.flatMap { $0.isEmpty ? nil : $0 }
        // Codex `notify` (agent-turn-complete).
        if source == "codex" || object["type"] as? String == "agent-turn-complete" {
            let type = object["type"] as? String ?? "notify"
            let thread = (object["thread-id"] as? String) ?? (object["thread_id"] as? String) ?? (object["turn-id"] as? String) ?? "codex"
            return AgentHookEvent(
                kind: .codex, eventName: type,
                phase: type == "agent-turn-complete" ? .finished : .other,
                sessionID: thread, cwd: object["cwd"] as? String,
                toolName: nil, toolSummary: nil, message: nil, replyStyle: .none,
                callerPID: callerPID, terminalProgram: term
            )
        }
        let name = (object["hook_event_name"] as? String) ?? (object["hookEventName"] as? String) ?? ""
        if source == "cursor" || object["conversation_id"] != nil {
            let roots = object["workspace_roots"] as? [String]
            let cwd = (object["cwd"] as? String) ?? roots?.first
            let session = (object["conversation_id"] as? String) ?? "cursor"
            var phase: Phase = .working
            var style: AgentReplyStyle = .none
            var tool: String?
            var summary: String?
            switch name {
            case "beforeShellExecution":
                phase = .needsApproval; style = .cursorPermission; tool = "Shell"
                summary = (object["command"] as? String).map { ToolSummary.command($0) }
            case "beforeMCPExecution":
                phase = .needsApproval; style = .cursorPermission
                tool = (object["tool_name"] as? String) ?? "MCP"
                summary = tool.map { ToolSummary.mcpName($0) }
            case "stop":
                phase = .finished
            case "beforeSubmitPrompt":
                phase = .working
            default:
                phase = .working
            }
            return AgentHookEvent(kind: .cursor, eventName: name, phase: phase, sessionID: session, cwd: cwd,
                                  toolName: tool, toolSummary: summary, message: nil, replyStyle: style,
                                  callerPID: callerPID, terminalProgram: term)
        }
        // Claude Code.
        let session = (object["session_id"] as? String) ?? "claude"
        let cwd = object["cwd"] as? String
        let tool = object["tool_name"] as? String
        let input = object["tool_input"] as? [String: Any]
        var phase: Phase = .other
        var style: AgentReplyStyle = .none
        switch name {
        case "SessionStart": phase = .started
        case "UserPromptSubmit", "PostToolUse", "PreCompact", "SubagentStop": phase = .working
        case "PermissionRequest": phase = .needsApproval; style = .claudePermissionRequest
        case "PreToolUse": phase = .needsApproval; style = .claudePreToolUse
        case "Notification":
            let type = (object["notification_type"] as? String) ?? ""
            let text = (object["message"] as? String) ?? ""
            phase = (type.contains("permission") || text.localizedCaseInsensitiveContains("permission")) ? .needsApproval : .needsInput
        case "Stop": phase = .finished
        case "SessionEnd": phase = .ended
        default: phase = .other
        }
        let message = (object["message"] as? String).map { String($0.prefix(140)) }
        return AgentHookEvent(
            kind: .claude, eventName: name, phase: phase, sessionID: session, cwd: cwd,
            toolName: tool, toolSummary: tool.map { ToolSummary.claude(tool: $0, input: input) },
            message: name == "Notification" ? message : nil, replyStyle: style,
            callerPID: callerPID, terminalProgram: term
        )
    }

    /// The reply body for a decision (empty: no opinion, the tool asks).
    func replyBody(_ decision: AgentDecision) -> Data {
        let object: [String: Any]
        switch (replyStyle, decision) {
        case (.none, _), (.claudePermissionRequest, .ask):
            return Data()
        case (.claudePermissionRequest, .allow):
            object = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        case (.claudePermissionRequest, .deny):
            object = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                             "decision": ["behavior": "deny", "message": "Denied from SparkV."]]]
        case (.claudePreToolUse, _):
            let reason: String = switch decision {
            case .allow: "Allowed from SparkV."
            case .deny: "Denied from SparkV."
            case .ask: "Ask in the terminal."
            }
            object = ["hookSpecificOutput": ["hookEventName": "PreToolUse",
                                             "permissionDecision": decision.rawValue,
                                             "permissionDecisionReason": reason]]
        case (.cursorPermission, _):
            var reply: [String: Any] = ["permission": decision.rawValue]
            if decision == .deny {
                reply["userMessage"] = "Denied from SparkV."
                reply["agentMessage"] = "The user denied this command."
            }
            object = reply
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// Short, content-light descriptions of what an agent wants to do.
enum ToolSummary {
    static func command(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
    }

    static func mcpName(_ name: String) -> String {
        // mcp__server__tool -> "server › tool"
        let parts = name.components(separatedBy: "__").filter { !$0.isEmpty }
        if parts.count >= 3, parts[0] == "mcp" { return parts[1] + " › " + parts[2...].joined(separator: "_") }
        return name
    }

    static func claude(tool: String, input: [String: Any]?) -> String {
        let input = input ?? [:]
        func file(_ key: String) -> String? {
            (input[key] as? String).map { ($0 as NSString).lastPathComponent }
        }
        switch tool {
        case "Bash":
            return (input["command"] as? String).map(command) ?? "Run a command"
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return file("file_path").map { "\(tool) · \($0)" } ?? file("notebook_path").map { "\(tool) · \($0)" } ?? tool
        case "WebFetch":
            if let raw = input["url"] as? String, let host = URL(string: raw)?.host { return "Fetch · \(host)" }
            return "Fetch a web page"
        case "WebSearch":
            return "Search the web"
        case "Task", "Agent":
            return "Start a subagent"
        default:
            return tool.hasPrefix("mcp__") ? mcpName(tool) : tool
        }
    }
}

/// A finished shell command from the optional zsh hook (/v1/command).
struct ShellCommandEvent: Equatable, Sendable {
    var command: String
    var exitCode: Int
    var duration: Double
    var folder: String?
    var terminalProgram: String?

    static func parse(_ body: Data) -> ShellCommandEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let raw = (object["cmd"] as? String) ?? ""
        let duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        let exit = (object["exit"] as? NSNumber)?.intValue ?? 0
        guard !raw.isEmpty, duration >= 0 else { return nil }
        return ShellCommandEvent(command: ToolSummary.command(raw), exitCode: exit, duration: duration,
                                 folder: object["pwd"] as? String, terminalProgram: (object["term"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Setup snippets (shown to the user; SparkV never edits these files)

enum AgentSetupSnippets {
    /// JSON-escaped, quoted hook command for the given script path.
    static func quotedCommand(script: String, flag: String) -> String {
        "\\\"\(script)\\\" \(flag)"
    }

    static func claudeSettings(script: String) -> String {
        let command = quotedCommand(script: script, flag: "--claude")
        func entry(_ event: String, matcher: Bool, timeout: Int) -> String {
            let match = matcher ? "\"matcher\": \"*\", " : ""
            return "    \"\(event)\": [{ \(match)\"hooks\": [{ \"type\": \"command\", \"command\": \"\(command)\", \"timeout\": \(timeout) }] }]"
        }
        let events = [
            entry("SessionStart", matcher: false, timeout: 5),
            entry("UserPromptSubmit", matcher: false, timeout: 5),
            entry("PermissionRequest", matcher: true, timeout: 60),
            entry("Notification", matcher: false, timeout: 5),
            entry("Stop", matcher: false, timeout: 5),
            entry("SessionEnd", matcher: false, timeout: 5),
        ]
        return "{\n  \"hooks\": {\n" + events.joined(separator: ",\n") + "\n  }\n}"
    }

    static func codexConfig(script: String) -> String {
        "notify = [\"\(script)\", \"--codex\"]"
    }

    static func cursorHooks(script: String) -> String {
        let command = quotedCommand(script: script, flag: "--cursor")
        return """
        {
          "version": 1,
          "hooks": {
            "beforeShellExecution": [{ "command": "\(command)" }],
            "beforeMCPExecution": [{ "command": "\(command)" }],
            "stop": [{ "command": "\(command)" }]
          }
        }
        """
    }

    static func zshLongCommand(script: String, minimumSeconds: Int) -> String {
        """
        # SparkV: tell the island when a long command finishes.
        zmodload zsh/datetime
        autoload -Uz add-zsh-hook
        _sparkv_preexec() { _sparkv_cmd="$1"; _sparkv_t0=$EPOCHREALTIME }
        _sparkv_precmd() {
          local code=$?
          [[ -n $_sparkv_t0 ]] || return
          local secs=$(( EPOCHREALTIME - _sparkv_t0 )); _sparkv_t0=
          (( secs >= \(minimumSeconds) )) && "\(script)" --command $code $secs "$_sparkv_cmd" &!
        }
        add-zsh-hook preexec _sparkv_preexec
        add-zsh-hook precmd _sparkv_precmd
        """
    }

    /// The hook script SparkV writes to its own Application Support folder.
    static let hookScript = """
    #!/bin/sh
    # SparkV agent hook: forwards a coding-agent or shell event to SparkV on
    # this Mac (127.0.0.1 only) and prints SparkV's answer, if any. Exits 0
    # quietly when SparkV isn't running, so your tool asks as it always does.
    # Usage: agent-hook --claude | --cursor   (event JSON on stdin)
    #        agent-hook --codex <json>        (Codex notify)
    #        agent-hook --command <exit> <seconds> <command>
    DIR="$HOME/Library/Application Support/SparkV"
    [ -r "$DIR/agent-hook.port" ] && [ -r "$DIR/agent-hook.header" ] || exit 0
    PORT=$(cat "$DIR/agent-hook.port")
    MODE="${1:---claude}"
    case "$MODE" in
      --codex) for LAST; do :; done; BODY="$LAST"; SRC=codex; ROUTE=hook ;;
      --command)
        SRC=shell; ROUTE=command
        BODY=$(/usr/bin/jq -cn --arg cmd "$4" --arg code "$2" --arg secs "$3" --arg pwd "$PWD" --arg term "${TERM_PROGRAM:-}" \\
          '{cmd:$cmd, exit:($code|tonumber? // 0), duration:($secs|tonumber? // 0), pwd:$pwd, term:$term}') || exit 0 ;;
      --cursor) SRC=cursor; ROUTE=hook; BODY=$(cat) ;;
      *) SRC=claude; ROUTE=hook; BODY=$(cat) ;;
    esac
    printf '%s' "$BODY" | /usr/bin/curl -sS --fail --max-time 58 --connect-timeout 1 \\
      -H @"$DIR/agent-hook.header" -H "Content-Type: application/json" \\
      -H "X-SparkV-Source: $SRC" -H "X-SparkV-PPID: $PPID" -H "X-SparkV-Term: ${TERM_PROGRAM:-}" \\
      --data-binary @- "http://127.0.0.1:$PORT/v1/$ROUTE" 2>/dev/null
    exit 0

    """
}
