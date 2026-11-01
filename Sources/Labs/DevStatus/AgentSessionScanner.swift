import CoreServices
import Darwin
import Foundation

/// Reads Claude Code, Codex and Cursor session folders read-only and turns
/// them into `CodingAgentSession`s. Driven by one FSEvents stream over the
/// folders (1 s latency) and by process-exit sources for running Claude
/// Code processes; nothing polls. A one-shot timer runs only while some
/// session still has to age from Working or Done to Idle.
///
/// Message text, prompts and tool input are never read into memory beyond
/// the JSON parser, never stored and never logged; only state, folder,
/// branch and (opt-in) token counts leave this class.
final class AgentSessionScanner: @unchecked Sendable {
    struct Options: Equatable, Sendable {
        var claude = true
        var codex = true
        var cursor = true
        var countTokens = false
    }

    /// Main-actor callback with every live session.
    var onUpdate: (@MainActor @Sendable ([CodingAgentSession]) -> Void)?

    private let queue = DispatchQueue(label: "SparkV.AgentSessions", qos: .utility)
    private var options = Options()
    private var stream: FSEventStreamRef?
    private var streamBox: StreamBox?
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var pendingScan: DispatchWorkItem?
    private var agingTimer: DispatchWorkItem?
    private var ledger: [String: TokenLedgerEntry] = [:]
    private var ledgerDay = Calendar.current.startOfDay(for: Date())
    private var isRunning = false

    private let home: URL
    private let fileManager = FileManager.default

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    private var claudeSessions: URL { home.appendingPathComponent(".claude/sessions") }
    private var claudeProjects: URL { home.appendingPathComponent(".claude/projects") }
    private var codexSessions: URL { home.appendingPathComponent(".codex/sessions") }
    private var cursorProjects: URL { home.appendingPathComponent(".cursor/projects") }

    // MARK: Control

    func start(_ options: Options) {
        queue.async { [self] in
            self.options = options
            isRunning = true
            restartStream()
            scanNow()
        }
    }

    func update(_ options: Options) {
        queue.async { [self] in
            guard isRunning, self.options != options else { return }
            let foldersChanged = self.options.claude != options.claude || self.options.codex != options.codex || self.options.cursor != options.cursor
            self.options = options
            if !options.countTokens { ledger.removeAll() }
            if foldersChanged { restartStream() }
            scanNow()
        }
    }

    func stop() {
        queue.async { [self] in
            isRunning = false
            stopStream()
            exitSources.values.forEach { $0.cancel() }
            exitSources.removeAll()
            pendingScan?.cancel()
            agingTimer?.cancel()
            ledger.removeAll()
        }
    }

    /// A rescan soon (opening the drawer, a hook event).
    func refresh() {
        queue.async { [self] in
            guard isRunning else { return }
            scheduleScan(after: 0.05)
        }
    }

    // MARK: FSEvents

    private final class StreamBox: @unchecked Sendable {
        let fire: @Sendable () -> Void
        init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
    }

    private func watchedFolders() -> [String] {
        var folders: [URL] = []
        if options.claude { folders += [claudeSessions, claudeProjects] }
        if options.codex { folders.append(codexSessions) }
        if options.cursor { folders.append(cursorProjects) }
        return folders.filter { fileManager.fileExists(atPath: $0.path) }.map(\.path)
    }

    private func restartStream() {
        stopStream()
        let paths = watchedFolders()
        guard !paths.isEmpty else { return }
        let box = StreamBox { [weak self] in
            guard let self else { return }
            self.queue.async { self.scheduleScan(after: 0.4) }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<StreamBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<StreamBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue().fire()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else {
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        streamBox = box
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        streamBox = nil
    }

    // MARK: Scanning

    private func scheduleScan(after delay: TimeInterval) {
        pendingScan?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanNow() }
        pendingScan = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scanNow() {
        guard isRunning else { return }
        pendingScan = nil
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        if today != ledgerDay {
            ledger.removeAll()
            ledgerDay = today
        }
        // One pass over the process table: names and folders of agent CLIs.
        let processes = agentProcesses()
        var sessions: [CodingAgentSession] = []
        if options.claude { sessions += scanClaude(now: now) }
        if options.codex { sessions += scanCodex(now: now, codexFolders: processes.codexFolders) }
        if options.cursor { sessions += scanCursor(now: now, cursorRunning: processes.cursorRunning) }
        scheduleAging(sessions, now: now)
        let ordered = CodingAgentSession.ordered(sessions)
        if let onUpdate {
            Task { @MainActor in onUpdate(ordered) }
        }
    }

    private func agentProcesses() -> (codexFolders: Set<String>, cursorRunning: Bool) {
        var codex = Set<String>()
        var cursor = false
        for pid in LocalProcesses.userPIDs() {
            let name = LocalProcesses.name(of: pid)
            if name == "codex" || name.hasPrefix("codex-") {
                if let folder = LocalProcesses.workingDirectory(of: pid) { codex.insert(folder) }
            } else if name == "Cursor" || name == "cursor-agent" {
                cursor = true
            }
        }
        return (codex, cursor)
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func children(_ url: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                              options: [.skipsHiddenFiles])) ?? []
    }

    // Claude Code: the live-process registry, enriched from each transcript.
    private func scanClaude(now: Date) -> [CodingAgentSession] {
        var sessions: [CodingAgentSession] = []
        var livePIDs = Set<Int32>()
        var seenSessions = Set<String>()
        for file in children(claudeSessions) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count < 64 * 1024,
                  let entry = ClaudeRegistryEntry.parse(data), LocalProcesses.isAlive(entry.pid) else { continue }
            livePIDs.insert(entry.pid)
            seenSessions.insert(entry.sessionID)
            var session = CodingAgentSession(
                kind: .claude, sessionID: entry.sessionID, name: entry.name, cwd: entry.cwd, branch: nil,
                state: entry.state(now: now), detail: nil,
                updatedAt: entry.statusUpdatedAt ?? entry.updatedAt ?? modified(file) ?? now, pid: entry.pid
            )
            if let transcript = claudeTranscript(cwd: entry.cwd, sessionID: entry.sessionID) {
                let summary = claudeSummary(transcript, now: now)
                session.branch = summary.branch
                if let last = summary.lastActivity { session.updatedAt = max(session.updatedAt, last) }
                if options.countTokens { session.tokensToday = tokensToday(transcript, now: now) }
            }
            sessions.append(session)
        }
        // Process exits drop a session at once.
        for pid in livePIDs where exitSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.exitSources[pid]?.cancel()
                self.exitSources[pid] = nil
                self.scheduleScan(after: 0.2)
            }
            source.resume()
            exitSources[pid] = source
        }
        for (pid, source) in exitSources where !livePIDs.contains(pid) {
            source.cancel()
            exitSources[pid] = nil
        }
        // Older Claude Code builds (no registry): recently written transcripts.
        let hasRegistry = fileManager.fileExists(atPath: claudeSessions.path)
        for project in hasRegistry ? [] : children(claudeProjects) {
            for file in children(project) where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard !seenSessions.contains(id), let date = modified(file),
                      now.timeIntervalSince(date) < CodingAgentTiming.finishedWindow else { continue }
                let summary = claudeSummary(file, now: now)
                guard summary.state != .idle else { continue }
                var session = CodingAgentSession(
                    kind: .claude, sessionID: summary.sessionID ?? id, name: nil,
                    cwd: summary.cwd, branch: summary.branch, state: summary.state,
                    detail: nil, updatedAt: summary.lastActivity ?? date, pid: nil
                )
                if options.countTokens { session.tokensToday = tokensToday(file, now: now) }
                sessions.append(session)
            }
        }
        return sessions
    }

    private func claudeTranscript(cwd: String?, sessionID: String) -> URL? {
        guard let cwd else { return nil }
        let encoded = AgentPaths.claudeProjectFolder(for: cwd)
        let url = claudeProjects.appendingPathComponent(encoded).appendingPathComponent(sessionID + ".jsonl")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func claudeSummary(_ url: URL, now: Date) -> ClaudeTranscriptSummary {
        guard let tail = JSONLTail.read(url, limit: 48 * 1024) else { return ClaudeTranscriptSummary() }
        return ClaudeTranscriptSummary.parse(lines: JSONLTail.lines(tail.data, startedMidFile: tail.midFile), now: now)
    }

    // Codex: today's and yesterday's rollouts, plus any written recently.
    private func scanCodex(now: Date, codexFolders: Set<String>) -> [CodingAgentSession] {
        let calendar = Calendar.current
        var folders: [URL] = []
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            folders.append(codexSessions.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d)))
        }
        var sessions: [CodingAgentSession] = []
        for folder in folders {
            for file in children(folder) where file.pathExtension == "jsonl" {
                guard let date = modified(file), now.timeIntervalSince(date) < CodingAgentTiming.liveWindow else { continue }
                guard let tail = JSONLTail.read(file, limit: 96 * 1024) else { continue }
                let head = JSONLTail.head(file, limit: 64 * 1024)
                let summary = CodexRolloutSummary.parse(head: head, lines: JSONLTail.lines(tail.data, startedMidFile: tail.midFile), now: now)
                let processAlive = summary.cwd.map { codexFolders.contains($0) } ?? false
                let recent = now.timeIntervalSince(date) < 30 * 60
                guard summary.state == .working || summary.state == .waiting || recent || processAlive else { continue }
                var state = summary.state
                if state == .working, !processAlive, now.timeIntervalSince(date) > 5 * 60 { state = .idle }
                sessions.append(CodingAgentSession(
                    kind: .codex, sessionID: summary.sessionID ?? file.deletingPathExtension().lastPathComponent,
                    name: nil, cwd: summary.cwd, branch: nil, state: state, detail: summary.detail,
                    updatedAt: summary.lastActivity ?? date, pid: nil,
                    tokensToday: options.countTokens ? summary.totalTokens : nil,
                    limitPercent: summary.limitPercent
                ))
            }
        }
        return sessions
    }

    // Cursor: agent transcripts written in the last hours.
    private func scanCursor(now: Date, cursorRunning: Bool) -> [CodingAgentSession] {
        var sessions: [CodingAgentSession] = []
        for project in children(cursorProjects) {
            let transcripts = project.appendingPathComponent("agent-transcripts")
            for folder in children(transcripts) {
                let id = folder.lastPathComponent
                let file = folder.appendingPathComponent(id + ".jsonl")
                guard let date = modified(file) ?? modified(folder),
                      now.timeIntervalSince(date) < (cursorRunning ? CodingAgentTiming.liveWindow : CodingAgentTiming.finishedWindow) else { continue }
                var role: String?
                if let tail = JSONLTail.read(file, limit: 16 * 1024) {
                    role = CursorTranscriptSummary.lastRole(lines: JSONLTail.lines(tail.data, startedMidFile: tail.midFile))
                }
                let summary = CursorTranscriptSummary(sessionID: id, projectKey: project.lastPathComponent, modified: date, lastRole: role)
                let state = summary.state(now: now, cursorRunning: cursorRunning)
                guard state != .idle || now.timeIntervalSince(date) < 3600 else { continue }
                let decoded = AgentPaths.decodeProjectFolder(project.lastPathComponent) { [fileManager] path in
                    var isDirectory: ObjCBool = false
                    return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
                sessions.append(CodingAgentSession(
                    kind: .cursor, sessionID: id, name: decoded == nil ? AgentPaths.readableProjectKey(project.lastPathComponent) : nil,
                    cwd: decoded, branch: nil, state: state, detail: nil, updatedAt: date, pid: nil
                ))
            }
        }
        return sessions
    }

    // MARK: Tokens (opt-in)

    private struct TokenLedgerEntry {
        var offset: UInt64
        var tokens: Int
    }

    /// Today's billable tokens in a Claude transcript, read incrementally:
    /// only bytes appended since the last scan, and only lines that carry a
    /// usage block are parsed.
    private func tokensToday(_ url: URL, now: Date) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ledger[url.path]?.tokens ?? 0 }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return 0 }
        var entry = ledger[url.path] ?? TokenLedgerEntry(offset: end > 24_000_000 ? end - 24_000_000 : 0, tokens: 0)
        if entry.offset > end { entry = TokenLedgerEntry(offset: 0, tokens: 0) }
        guard end > entry.offset else { return entry.tokens }
        try? handle.seek(toOffset: entry.offset)
        guard let data = try? handle.read(upToCount: Int(end - entry.offset)) else { return entry.tokens }
        // Only whole lines; a partial last line waits for the next scan.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return entry.tokens }
        let complete = data[data.startIndex...lastNewline]
        let usage = Data("\"usage\"".utf8)
        let calendar = Calendar.current
        for line in complete.split(separator: UInt8(ascii: "\n")) where line.range(of: usage) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let stamp = JSONLTail.date(object["timestamp"]), calendar.isDate(stamp, inSameDayAs: now),
                  let message = object["message"] as? [String: Any],
                  let usageBlock = message["usage"] as? [String: Any] else { continue }
            entry.tokens += ClaudeTranscriptSummary.tokens(usageBlock)
        }
        entry.offset += UInt64(complete.count)
        ledger[url.path] = entry
        return entry.tokens
    }

    // MARK: Aging

    private func scheduleAging(_ sessions: [CodingAgentSession], now: Date) {
        agingTimer?.cancel()
        agingTimer = nil
        let deadlines: [Date] = sessions.compactMap { session in
            switch session.state {
            case .finished: session.updatedAt.addingTimeInterval(CodingAgentTiming.finishedWindow)
            case .working where session.kind == .cursor: session.updatedAt.addingTimeInterval(CodingAgentTiming.cursorWorkingWindow)
            case .working: session.updatedAt.addingTimeInterval(15 * 60)
            default: nil
            }
        }
        guard let next = deadlines.min() else { return }
        let delay = min(max(next.timeIntervalSince(now) + 1, 30), 15 * 60)
        let item = DispatchWorkItem { [weak self] in self?.scanNow() }
        agingTimer = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
