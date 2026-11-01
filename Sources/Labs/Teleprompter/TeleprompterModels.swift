import Foundation

// Pure logic for the Teleprompter: settings, scroll math, script import
// cleanup and voice-paced position matching. Foundation only (tested).

struct TeleprompterSettings: Codable, Equatable, Sendable {
    /// Points per second.
    var speed: Double = 40
    var fontSize: Double = 26
    var lineSpacing: Double = 6
    /// Flip horizontally for beam-splitter glass.
    var mirrored = false
    /// 0, 3 or 5 seconds before scrolling starts.
    var countdown = 3
    var width: Double = 460
    var height: Double = 120
    var opacity: Double = 0.92
    /// Display to show on (CGDirectDisplayID); nil: the one with the notch.
    var displayID: UInt32?
    /// Scroll with your voice (on-device speech) instead of a fixed speed.
    var voicePacing = false
    var centered = true
    /// The ⌃⌥⇧T, ⌃⌥⇧Space and ⌃⌥⇧↑/↓ shortcuts.
    var hotkeysEnabled = true

    static let speedRange: ClosedRange<Double> = 10...240
    static let fontRange: ClosedRange<Double> = 16...56
    static let widthRange: ClosedRange<Double> = 320...760
    static let heightRange: ClosedRange<Double> = 70...260

    func clamped() -> TeleprompterSettings {
        var copy = self
        copy.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        copy.fontSize = min(max(fontSize, Self.fontRange.lowerBound), Self.fontRange.upperBound)
        copy.lineSpacing = min(max(lineSpacing, 0), 24)
        copy.width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        copy.height = min(max(height, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        copy.opacity = min(max(opacity, 0.5), 1)
        copy.countdown = [0, 3, 5].contains(countdown) ? countdown : 3
        return copy
    }

    /// One speed step: 10 % (at least 4 pt/s).
    static func stepped(_ speed: Double, faster: Bool) -> Double {
        let step = max(4, speed * 0.1)
        return min(max(speed + (faster ? step : -step), speedRange.lowerBound), speedRange.upperBound)
    }
}

/// The scroll position: a base offset plus speed × time while playing.
struct TeleprompterClock: Equatable, Sendable {
    var baseOffset: Double = 0
    var playingSince: Date?
    var speed: Double

    func offset(at date: Date) -> Double {
        guard let since = playingSince else { return baseOffset }
        return baseOffset + speed * max(0, date.timeIntervalSince(since))
    }

    mutating func play(at date: Date) {
        guard playingSince == nil else { return }
        playingSince = date
    }

    mutating func pause(at date: Date) {
        baseOffset = offset(at: date)
        playingSince = nil
    }

    /// A new speed keeps the current position.
    mutating func setSpeed(_ value: Double, at date: Date) {
        if playingSince != nil {
            baseOffset = offset(at: date)
            playingSince = date
        }
        speed = value
    }

    mutating func jump(to offset: Double, at date: Date) {
        baseOffset = max(0, offset)
        if playingSince != nil { playingSince = date }
    }
}

enum TeleprompterText {
    /// Plain text for the prompter from a .txt or .md file: headings, list
    /// markers, emphasis and link targets removed; paragraphs kept.
    static func fromMarkdown(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__|\*|_|`|~~)"#, with: "", options: .regularExpression)
            lines.append(line)
        }
        // Collapse runs of blank lines to one.
        var result: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, result.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A title from the first line (at most 40 characters).
    static func title(for text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !first.isEmpty else { return "Untitled Script" }
        return first.count > 40 ? String(first.prefix(39)) + "…" : first
    }

    /// Rough reading time at about 150 spoken words a minute.
    static func readingMinutes(_ text: String) -> Double {
        Double(words(in: text).count) / 150
    }

    struct Word: Equatable, Sendable {
        let text: String
        /// UTF-16 offset of the word in the script.
        let offset: Int
    }

    /// Words, lowercased with punctuation stripped, with their positions.
    static func words(in text: String) -> [Word] {
        var result: [Word] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .localized]) { word, range, _, _ in
            guard let word else { return }
            let normalized = normalize(word)
            if !normalized.isEmpty { result.append(Word(text: normalized, offset: range.location)) }
        }
        return result
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().folding(options: [.diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }
}

/// Follows a speaker through the script: the last few recognized words are
/// matched against the script just ahead of the current position, so the
/// prompter scrolls as you read (and waits when you pause or ad-lib).
enum TeleprompterVoiceMatcher {
    /// The script word index just after the best match, or nil when the
    /// recognized words don't match nearby (ad-lib, noise).
    static func advance(script: [String], cursor: Int, heard: [String], lookBehind: Int = 6, lookAhead: Int = 40) -> Int? {
        let tail = Array(heard.suffix(4)).filter { !$0.isEmpty }
        guard !tail.isEmpty, !script.isEmpty else { return nil }
        let start = max(0, cursor - lookBehind)
        let end = min(script.count - 1, cursor + lookAhead)
        guard start <= end else { return nil }
        var best: (index: Int, score: Int, distance: Int)?
        for position in start...end {
            // Score the tail ending at `position`.
            var score = 0
            for (k, word) in tail.reversed().enumerated() {
                let index = position - k
                guard index >= 0 else { break }
                if similar(script[index], word) { score += 1 }
            }
            let needed = tail.count >= 3 ? 2 : tail.count
            guard score >= needed else { continue }
            let distance = abs(position - cursor)
            if best == nil || score > best!.score || (score == best!.score && distance < best!.distance) {
                best = (position, score, distance)
            }
        }
        guard let best else { return nil }
        return min(best.index + 1, script.count)
    }

    /// Equal, or one edit apart for words of five letters or more.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(a, b, limit: 1) <= 1
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var current = [i] + Array(repeating: 0, count: y.count)
            var rowMin = current[0]
            for j in 1...max(1, y.count) where !y.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[y.count]
    }
}

/// When the voice pacer restarts recognition: soon after a task ends on a
/// pause, a little later after a failure, and never again after three
/// failures in a few seconds with nothing heard in between (it gives up
/// rather than toggle the microphone in a tight loop).
struct TeleprompterRestartBackoff: Equatable, Sendable {
    static let afterEnd: TimeInterval = 0.1
    static let afterFailure: TimeInterval = 0.5
    static let window: TimeInterval = 6
    static let maxFailures = 3

    private(set) var failures: [Date] = []

    /// The delay before the next start, or nil to give up.
    mutating func next(failed: Bool, at now: Date) -> TimeInterval? {
        guard failed else { return Self.afterEnd }
        failures = failures.filter { now.timeIntervalSince($0) < Self.window } + [now]
        return failures.count >= Self.maxFailures ? nil : Self.afterFailure * Double(failures.count)
    }

    /// Words came through: recognition works.
    mutating func noteHeard() { failures.removeAll() }
}
