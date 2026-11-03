import Foundation

// Pure logic for Labs/MediaPlus: no AppKit, no SwiftUI, no app types, so the
// test harness compiles this file on its own. Everything here is a value or
// a static function.

// MARK: - Lyrics (LRC)

/// One timed line of synced lyrics. Empty `text` is an instrumental gap.
struct LyricLine: Equatable, Sendable, Codable {
    var time: TimeInterval
    var text: String

    var isGap: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Parses LRC ("[mm:ss.xx] words"), the format LRCLIB returns in
/// `syncedLyrics`: several timestamps per line, `[offset:±ms]`, metadata tags
/// (`[ar:…]`, `[ti:…]`) and word-level `<mm:ss.xx>` stamps (stripped).
enum LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0
        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let seconds = timestamp(tag) {
                    stamps.append(seconds)
                } else if tag.lowercased().hasPrefix("offset:") {
                    // Positive offset shifts lyrics earlier (LRC convention).
                    let value = tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                    if let ms = Double(value) { offset = ms / 1000 }
                }
            }
            guard !stamps.isEmpty else { continue }
            let words = stripWordStamps(String(rest)).trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                lines.append(LyricLine(time: stamp, text: words))
            }
        }
        if offset != 0 {
            lines = lines.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
        }
        // Stable sort: equal times keep file order.
        let sorted = lines.enumerated().sorted { lhs, rhs in
            lhs.element.time == rhs.element.time ? lhs.offset < rhs.offset : lhs.element.time < rhs.element.time
        }.map(\.element)
        return collapseGaps(sorted)
    }

    /// "mm:ss", "mm:ss.x", "mm:ss.xx", "mm:ss.xxx", "mm:ss:xx", "h:mm:ss.xx".
    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        func number(_ part: Substring) -> Double? {
            guard part.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
            return Double(part)
        }
        if parts.count == 2 {
            guard parts[0].allSatisfy(\.isNumber), let minutes = Double(parts[0]), let seconds = number(parts[1]) else { return nil }
            return minutes * 60 + seconds
        }
        // Either h:mm:ss(.xx) or mm:ss:cc (centiseconds after a colon).
        guard let a = number(parts[0]), let b = number(parts[1]), let c = number(parts[2]) else { return nil }
        if parts[2].count == 2, !parts[2].contains("."), b < 60, parts[0].count <= 2, a < 60, !parts[1].contains(".") {
            // mm:ss:cc is far more common in the wild than h:mm:ss.
            return a * 60 + b + c / 100
        }
        return a * 3600 + b * 60 + c
    }

    /// Removes enhanced-LRC word stamps ("<00:12.34>word").
    static func stripWordStamps(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = ""
        var skipping = false
        for character in text {
            if character == "<" { skipping = true; continue }
            if character == ">", skipping { skipping = false; continue }
            if !skipping { out.append(character) }
        }
        return out
    }

    /// Consecutive empty lines say the same thing once.
    private static func collapseGaps(_ lines: [LyricLine]) -> [LyricLine] {
        var out: [LyricLine] = []
        for line in lines {
            if line.isGap, let last = out.last, last.isGap { continue }
            out.append(line)
        }
        return out
    }
}

/// Where playback is within synced lyrics.
enum LyricsTimeline {
    /// Index of the line being sung at `position` (the last line whose time
    /// has passed), or nil before the first line. Binary search.
    static func index(at position: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first, position >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Seconds of track time until the line after `position` starts; nil
    /// after the last line.
    static func timeUntilNextLine(at position: TimeInterval, in lines: [LyricLine]) -> TimeInterval? {
        let next = (index(at: position, in: lines) ?? -1) + 1
        guard next < lines.count else { return nil }
        return max(0, lines[next].time - position)
    }
}

/// Picks the best LRCLIB search result for a track.
enum LyricsMatch {
    struct Candidate: Equatable, Sendable {
        var id: Int
        var trackName: String
        var artistName: String
        var duration: TimeInterval?
        var hasSynced: Bool
        var hasPlain: Bool
        var instrumental: Bool
    }

    /// Prefers synced lyrics within 3 s of the track's length, then plain
    /// ones, then the closest length. nil when nothing plausible.
    static func best(_ candidates: [Candidate], title: String, artist: String, duration: TimeInterval?) -> Candidate? {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let wantTitle = norm(stripDecorations(title))
        let plausible = candidates.filter { candidate in
            guard candidate.hasSynced || candidate.hasPlain || candidate.instrumental else { return false }
            if let duration, duration > 0, let theirs = candidate.duration, abs(theirs - duration) > 8 { return false }
            let theirTitle = norm(stripDecorations(candidate.trackName))
            return theirTitle == wantTitle || theirTitle.contains(wantTitle) || wantTitle.contains(theirTitle)
        }
        return plausible.min { lhs, rhs in
            score(lhs, artist: norm(artist), duration: duration, norm: norm) < score(rhs, artist: norm(artist), duration: duration, norm: norm)
        }
    }

    private static func score(_ c: Candidate, artist: String, duration: TimeInterval?, norm: (String) -> String) -> Double {
        var score = 0.0
        if !c.hasSynced { score += 10 }
        if norm(c.artistName) != artist { score += 4 }
        if let duration, duration > 0, let theirs = c.duration { score += abs(theirs - duration) }
        return score
    }

    /// "Song (Remastered 2011)" → "Song"; "Song - Live" → "Song".
    static func stripDecorations(_ title: String) -> String {
        var out = title
        for marker in [" (", " [", " - "] {
            if let range = out.range(of: marker), range.lowerBound > out.startIndex {
                let tail = out[range.lowerBound...].lowercased()
                let decorative = ["remaster", "live", "version", "edit", "mono", "stereo", "feat", "deluxe", "bonus", "mix"]
                if decorative.contains(where: tail.contains) { out = String(out[..<range.lowerBound]) }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Media sources

enum MediaSourceList {
    /// Seen apps plus excluded ones (so an exclusion can always be undone),
    /// most recent first.
    static func sources(seen: [String], excluded: Set<String>) -> [String] {
        var list = seen
        for id in excluded.sorted() where !list.contains(id) { list.append(id) }
        return list
    }
}

// MARK: - Swipe gestures

/// What a horizontal two-finger swipe over the media column does.
enum MediaSwipeAction: String, CaseIterable, Identifiable, Sendable {
    case off
    case tracks
    case seek10
    case seek15

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .tracks: "Next / Previous Track"
        case .seek10: "Skip 10 Seconds"
        case .seek15: "Skip 15 Seconds"
        }
    }
}

/// Turns a stream of scroll-wheel events into at most one swipe per gesture.
/// Horizontal only (|dx| > 2 |dy|), trackpad only (precise deltas), momentum
/// ignored, fires once past `threshold` points.
struct MediaSwipeAccumulator: Sendable {
    enum Phase: Sendable { case began, changed, ended, none }
    enum Direction: Equatable, Sendable { case forward, backward }

    var threshold: Double = 50
    private(set) var dx: Double = 0
    private(set) var dy: Double = 0
    private(set) var fired = false
    private(set) var active = false

    init(threshold: Double = 50) {
        self.threshold = threshold
    }

    /// Feed one event. Returns a direction the moment the gesture crosses the
    /// threshold (once per gesture). `naturalScrolling` is
    /// `isDirectionInvertedFromDevice`: deltas follow the fingers then, so a
    /// swipe left (fingers moving left) means "next" either way.
    /// `reversed` is the user's own toggle.
    mutating func handle(
        phase: Phase,
        isMomentum: Bool,
        deltaX: Double,
        deltaY: Double,
        precise: Bool,
        naturalScrolling: Bool,
        reversed: Bool
    ) -> Direction? {
        guard precise, !isMomentum else { return nil }
        switch phase {
        case .began:
            dx = 0; dy = 0; fired = false; active = true
        case .ended:
            active = false
            dx = 0; dy = 0
            return nil
        case .changed, .none:
            if !active { return nil }
        }
        dx += deltaX
        dy += deltaY
        guard !fired, abs(dx) >= threshold, abs(dx) > 2 * abs(dy) else { return nil }
        fired = true
        // Fingers moving left: natural scrolling reports negative dx, classic
        // scrolling positive. Both mean "next".
        let fingersLeft = naturalScrolling ? dx < 0 : dx > 0
        var direction: Direction = fingersLeft ? .forward : .backward
        if reversed { direction = direction == .forward ? .backward : .forward }
        return direction
    }

    /// True while a gesture this accumulator tracks is still horizontal
    /// enough to keep (the monitor swallows only those events).
    var isHorizontal: Bool { active && abs(dx) > 2 * abs(dy) && abs(dx) > 4 }
}

// MARK: - Skip buttons

/// What the two buttons beside play/pause do.
enum MediaSkipStyle: String, CaseIterable, Identifiable, Sendable {
    /// Tracks for music; ±15 s for podcasts, audiobooks and long videos.
    case automatic
    case tracks
    case seconds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .tracks: "Previous / Next Track"
        case .seconds: "Back / Forward 15 Seconds"
        }
    }

    /// Apps whose content is spoken word.
    static let spokenWordApps: Set<String> = [
        "com.apple.podcasts", "com.apple.iBooksX", "com.audible.mac", "com.overcast.mac",
        "fm.castro.mac", "au.com.shiftyjelly.PocketCasts", "com.pocketcasts.mac",
    ]

    /// True when the buttons should skip 15 s instead of changing tracks.
    func usesSeconds(bundleID: String?, duration: TimeInterval, reportsSkip15: Bool, canSeek: Bool) -> Bool {
        switch self {
        case .tracks: return false
        case .seconds: return canSeek || reportsSkip15
        case .automatic:
            guard canSeek || reportsSkip15 else { return false }
            if let bundleID, Self.spokenWordApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) { return true }
            // Long-form (talks, podcasts in a browser, films): 20 min or more.
            return duration >= 20 * 60
        }
    }
}

// MARK: - Idle Home

/// What the Home column shows when nothing plays.
enum IdleHomeMode: String, CaseIterable, Identifiable, Sendable {
    case media
    case upNext
    case clock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: "Media Player"
        case .upNext: "Next Meeting & Timer"
        case .clock: "Clock & Timer"
        }
    }
}

enum IdleHomeDecision {
    /// Kind of source, reduced to what the decision needs.
    enum SourceKind: Sendable { case none, playing, paused, needsPermission, stoppedPlayer }

    /// True when Home should show the idle column instead of media.
    static func showsIdle(mode: IdleHomeMode, showsMediaControls: Bool, source: SourceKind) -> Bool {
        if !showsMediaControls { return true }
        guard mode != .media else { return false }
        switch source {
        case .none, .stoppedPlayer: return true
        // "Connect Music" must stay visible: it's how access is granted.
        case .playing, .paused, .needsPermission: return false
        }
    }

    /// Becoming idle waits this long (the source flips to none between
    /// tracks and while the adapter restarts); becoming busy is instant.
    static let idleDelay: TimeInterval = 3
}

// MARK: - Per-app gain (realtime-safe DSP)

enum AppGainMath {
    /// A live route needs rebuilding only when a process of the app is
    /// playing that its tap doesn't include. Helpers that stop or quit, and
    /// new idle helpers, leave the route alone (object ids are UInt32,
    /// Core Audio's AudioObjectID).
    static func needsRetap(tapped: [UInt32], playing: [UInt32]) -> Bool {
        !Set(playing).isSubset(of: Set(tapped))
    }

    static let range: ClosedRange<Double> = 0...2

    /// Above `knee` the signal bends smoothly toward ±1 instead of clipping
    /// (only reachable with gains above 100 %).
    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.8
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let over = (magnitude - knee) / (1 - knee)
        // Rational tanh-like curve: no libm call on the audio thread.
        let bent = knee + (1 - knee) * (over / (1 + over))
        return x < 0 ? -bent : bent
    }

    /// Copies `frames` of stereo from the tap to the output with a gain that
    /// ramps from `from` to `to` (no zipper noise), soft-clipped above 100 %.
    /// Pointers are strided (interleaved buffers). Returns the input peak, to
    /// tell real audio from digital silence. Allocation-free, lock-free.
    @inline(__always)
    static func render(
        left: UnsafePointer<Float>, right: UnsafePointer<Float>, inStride: Int,
        outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>?, outStride: Int,
        frames: Int, from: Float, to: Float
    ) -> Float {
        guard frames > 0 else { return 0 }
        let step = (to - from) / Float(frames)
        let clips = to > 1 || from > 1
        var gain = from
        var peak: Float = 0
        for frame in 0..<frames {
            gain += step
            let l = left[frame * inStride]
            let r = right[frame * inStride]
            peak = max(peak, max(abs(l), abs(r)))
            var outL = l * gain
            var outR = r * gain
            if clips {
                outL = softClip(outL)
                outR = softClip(outR)
            }
            if let outRight {
                outLeft[frame * outStride] = outL
                outRight[frame * outStride] = outR
            } else {
                outLeft[frame * outStride] = 0.5 * (outL + outR)
            }
        }
        return peak
    }

    /// Slider value with a soft detent at 100 %.
    static func snapped(_ value: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return abs(clamped - 1) < 0.04 ? 1 : clamped
    }

    static func isUnity(_ gain: Double) -> Bool { abs(gain - 1) < 0.005 }

    static func percentText(_ gain: Double) -> String { "\(Int((gain * 100).rounded()))%" }
}

// MARK: - Output devices

enum AudioDeviceFilter {
    /// A device worth offering in the output picker.
    static func isUserFacing(name: String, uid: String, isHidden: Bool, hasOutput: Bool, isAggregate: Bool) -> Bool {
        guard hasOutput, !isHidden, !name.isEmpty else { return false }
        let lowerUID = uid.lowercased()
        // SparkV's own taps (Ambient Light, App Volumes) and the system's
        // private default-device aggregates.
        if lowerUID.hasPrefix("com.sparkv.") || lowerUID.hasPrefix("cadefaultdeviceaggregate") { return false }
        if isAggregate, name.localizedCaseInsensitiveContains("sparkv") { return false }
        // Meeting apps' private loopback devices.
        let hiddenNames = ["zoomaudiodevice", "microsoft teams audio", "ms teams audio device"]
        if hiddenNames.contains(name.lowercased()) { return false }
        return true
    }
}

// MARK: - Visualizer

enum MediaVisualizerMath {
    /// Seconds between redraws of the closed-island progress line so each
    /// step moves about 1 pt: length / rate / width, between 1 s and 10 s.
    static func progressTick(duration: TimeInterval, rate: Double, width: CGFloat) -> TimeInterval {
        guard duration > 0, rate > 0, width >= 1 else { return 1 }
        return min(10, max(1, duration / rate / Double(width)))
    }

    /// Four bar heights (0.25…1) from band envelopes: bass, low-mid, mid,
    /// treble. Square root lifts quiet bands so the bars read at 13 pt.
    static func bars(bass: Float, mid: Float, treble: Float, level: Float) -> [Double] {
        func shape(_ v: Float) -> Double {
            let clamped = Double(min(1, max(0, v)))
            return 0.25 + 0.75 * clamped.squareRoot()
        }
        let lowMid = 0.55 * bass + 0.45 * mid
        let presence = max(treble, 0.6 * level)
        return [shape(bass), shape(lowMid), shape(mid), shape(presence)]
    }
}

// MARK: - On-screen gate

/// "On screen" = appeared in SwiftUI *and* its window visible. Reports only
/// changes, so a counter fed by it always sees true/false pairs. The window
/// starts as visible (unknown until the probe lands in one).
struct OnScreenGate: Sendable {
    private(set) var appeared = false
    private(set) var windowVisible = true
    private(set) var reported = false

    /// The new on-screen value when it changed, nil otherwise.
    mutating func setAppeared(_ value: Bool) -> Bool? {
        appeared = value
        return settle()
    }

    mutating func setWindowVisible(_ value: Bool) -> Bool? {
        windowVisible = value
        return settle()
    }

    private mutating func settle() -> Bool? {
        let now = appeared && windowVisible
        guard now != reported else { return nil }
        reported = now
        return now
    }
}
