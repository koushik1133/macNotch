import CoreGraphics
import Foundation

// Writing the draft into the message box with exact Undo/Redo.
//
// Production tools insert at the field's selection: Grammarly's desktop app
// requires apps to expose the text and selected-text range through
// Accessibility, Raycast's Quick Fix "pastes back" over the selection, and
// macOS assistive apps replace `AXSelectedText`. So the draft replaces one
// range of the field (the user's notes, a selection, or an empty spot before
// the signature), and every later version replaces exactly the range the
// previous version occupies. Undo writes the previous version back into that
// range, so the original text comes back exactly and everything around it
// (quoted thread, signature) is never touched.

struct ReplyFieldState: Sendable, Equatable {
    var value: String
    /// UTF-16 range, as Accessibility reports it.
    var selection: NSRange?
    var placeholder: String = ""
}

enum ReplyInsertionPlanner {
    /// Where a signature starts ("-- " line, "Sent from my …", or the
    /// signature the user set), as a UTF-16 offset.
    static func signatureStart(in value: String, knownSignature: String? = nil) -> Int? {
        let ns = value as NSString
        var candidates: [Int] = []
        let patterns = [#"(?m)^--\s*$"#, #"(?m)^-- $"#, #"(?m)^Sent from my [^\n]+$"#, #"(?m)^Get Outlook for [^\n]+$"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) {
                candidates.append(match.range.location)
            }
        }
        if let known = knownSignature?.trimmingCharacters(in: .whitespacesAndNewlines), known.count >= 6 {
            // The first occurrence: the quoted thread below may repeat it.
            let range = ns.range(of: known)
            if range.location != NSNotFound { candidates.append(range.location) }
        }
        return candidates.min()
    }

    /// Where the quoted thread starts inside the message box, as a UTF-16
    /// offset. Apple Mail and Outlook keep the message being replied to in
    /// the compose field ("On … wrote:", "-----Original Message-----",
    /// Outlook's "From: … / Sent: …" header, "> " lines).
    static func quoteStart(in value: String) -> Int? {
        let ns = value as NSString
        let patterns = [
            #"(?m)^[ \t]*On [^\n]{6,240}wrote:[ \t]*$"#,
            #"(?mi)^[ \t]*-{2,}\s*(original message|forwarded message)\s*-{2,}"#,
            #"(?m)^[ \t]*Begin forwarded message:"#,
            #"(?m)^[ \t]*From:[^\n]+\n[ \t]*(Sent|Date):"#,
            #"(?m)^_{10,}[ \t]*$"#,
            #"(?m)^>"#,
        ]
        var candidates: [Int] = []
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) {
                candidates.append(match.range.location)
            }
        }
        return candidates.min()
    }

    /// End of the part the user writes in: before any signature and before
    /// the quoted thread.
    static func writableEnd(in value: String, knownSignature: String? = nil) -> Int {
        let length = (value as NSString).length
        return [signatureStart(in: value, knownSignature: knownSignature), quoteStart(in: value), length].compactMap { $0 }.min() ?? length
    }

    /// What the user typed in the message box, without placeholder,
    /// signature or quoted thread.
    static func userNotes(in value: String, placeholder: String, knownSignature: String? = nil) -> String {
        if value.isEmpty || value == placeholder { return "" }
        let ns = value as NSString
        return ns.substring(to: writableEnd(in: value, knownSignature: knownSignature)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The range the draft replaces.
    static func plan(_ state: ReplyFieldState, knownSignature: String? = nil) -> NSRange {
        let value = state.value == state.placeholder ? "" : state.value
        let ns = value as NSString
        if let selection = state.selection, selection.length > 0, selection.location != NSNotFound,
           NSMaxRange(selection) <= ns.length {
            return selection
        }
        let notes = ns.substring(to: writableEnd(in: value, knownSignature: knownSignature))
        let trimmedEnd = (notes as NSString).length - trailingWhitespaceLength(notes)
        if trimmedEnd <= 0 { return NSRange(location: 0, length: 0) }
        return NSRange(location: 0, length: trimmedEnd)
    }

    private static func trailingWhitespaceLength(_ text: String) -> Int {
        var count = 0
        for unit in text.utf16.reversed() {
            guard ReplyTextLocator.isSpace(unit) else { break }
            count += 1
        }
        return count
    }

    /// `value` with `range` replaced (UTF-16).
    static func applying(_ text: String, to value: String, in range: NSRange) -> String {
        let ns = value as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return value }
        return ns.replacingCharacters(in: range, with: text)
    }
}

/// Finds text in a field even when the app changed its whitespace
/// (contenteditable fields turn "\n\n" into paragraphs, NBSPs, …).
enum ReplyTextLocator {
    static func isSpace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 0xA0 || unit == 0x2028 || unit == 0x2029 || unit == 0x200B
    }

    /// Whitespace runs collapsed to one space; `map[i]` is the UTF-16 offset
    /// in the original of normalized unit `i`.
    static func normalize(_ text: String) -> (units: [UInt16], map: [Int]) {
        var units: [UInt16] = []
        var map: [Int] = []
        var previousSpace = true
        for (offset, unit) in text.utf16.enumerated() {
            if isSpace(unit) {
                if !previousSpace {
                    units.append(32)
                    map.append(offset)
                }
                previousSpace = true
            } else {
                units.append(unit)
                map.append(offset)
                previousSpace = false
            }
        }
        if units.last == 32 {
            units.removeLast()
            map.removeLast()
        }
        return (units, map)
    }

    static func normalizedEqual(_ a: String, _ b: String) -> Bool {
        normalize(a).units == normalize(b).units
    }

    /// The UTF-16 range of `needle` in `haystack`, the occurrence closest to
    /// `near`. An empty needle is a zero-length range at `near`.
    static func locate(_ needle: String, in haystack: String, near: Int) -> NSRange? {
        let length = (haystack as NSString).length
        let target = normalize(needle).units
        guard !target.isEmpty else { return NSRange(location: min(max(0, near), length), length: 0) }
        let (units, map) = normalize(haystack)
        guard units.count >= target.count else { return nil }
        var best: NSRange?
        var bestDistance = Int.max
        let first = target[0]
        var i = 0
        let last = units.count - target.count
        while i <= last {
            if units[i] == first, Array(units[i..<(i + target.count)]) == target {
                let start = map[i]
                let end = map[i + target.count - 1] + 1
                let distance = abs(start - near)
                if distance < bestDistance {
                    best = NSRange(location: start, length: end - start)
                    bestDistance = distance
                }
                i += target.count
            } else {
                i += 1
            }
        }
        return best
    }
}

/// The versions written into one field: [0] is what was there before.
struct ReplyEditHistory: Sendable, Equatable {
    struct Version: Sendable, Equatable {
        var body: String
        /// nil = the Subject field is not touched.
        var subject: String?
    }

    private(set) var versions: [Version]
    private(set) var index: Int
    /// Where `current.body` sits in the field now (UTF-16).
    var bodyRange: NSRange

    init(original: Version, range: NSRange) {
        versions = [original]
        index = 0
        bodyRange = range
    }

    var current: Version { versions[index] }
    var original: Version { versions[0] }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < versions.count - 1 }
    var draftCount: Int { versions.count - 1 }

    /// A new version after the current one (drops anything that was undone).
    mutating func push(_ version: Version) {
        versions = Array(versions[...index]) + [version]
        index = versions.count - 1
    }

    mutating func moveBack() -> Version? {
        guard canUndo else { return nil }
        index -= 1
        return versions[index]
    }

    mutating func moveForward() -> Version? {
        guard canRedo else { return nil }
        index += 1
        return versions[index]
    }

    /// Steps back after a failed write, so the history matches the field.
    mutating func revert(to previous: Int) {
        index = max(0, min(previous, versions.count - 1))
    }
}

// MARK: - Fields

/// A text field in another app (or a test double).
@MainActor
protocol ReplyWritableField: AnyObject {
    /// nil when the field's text can't be read.
    func read() async -> ReplyFieldState?
    /// Replaces `range` (UTF-16) with `text`. `NSNotFound` = at the caret.
    func replace(_ range: NSRange, with text: String) async -> Bool
    /// The app's own Undo / Redo (⌘Z / ⇧⌘Z) for fields that can't be read.
    func nativeUndo() async -> Bool
    func nativeRedo() async -> Bool
    /// Global Quartz frame, for placing the bar.
    var frame: CGRect? { get }
    /// Puts the caret back in this field (after filling the Subject).
    func focus() async
}

extension ReplyWritableField {
    func focus() async {}
}

/// Applies draft versions to the message box (and an empty Subject) and
/// walks the history. Never presses Send.
@MainActor
final class ReplyFieldEditor {
    enum Failure: Error, Equatable {
        /// The text SparkV wrote isn't there any more (the user edited it).
        case changedByUser
        case writeFailed
    }

    let body: ReplyWritableField
    let subject: ReplyWritableField?
    let knownSignature: String?
    private(set) var history: ReplyEditHistory?
    /// The field can't be read: Undo/Redo use the app's own ⌘Z.
    private(set) var usesNativeUndo = false

    init(body: ReplyWritableField, subject: ReplyWritableField?, knownSignature: String? = nil) {
        self.body = body
        self.subject = subject
        self.knownSignature = knownSignature
    }

    var canUndo: Bool { history?.canUndo ?? false }
    var canRedo: Bool { history?.canRedo ?? false }

    /// Writes the first draft. The Subject is filled only when it is empty.
    func insert(_ draft: ReplyDraft, fillSubject: Bool) async throws {
        let state = await body.read()
        var range: NSRange
        var originalBody = ""
        if let state {
            range = ReplyInsertionPlanner.plan(state, knownSignature: knownSignature)
            let value = state.value == state.placeholder ? "" : state.value
            if state.value == state.placeholder, !state.placeholder.isEmpty {
                range = NSRange(location: 0, length: 0)
            }
            originalBody = (value as NSString).substring(with: range)
        } else {
            usesNativeUndo = true
            range = NSRange(location: NSNotFound, length: 0)
        }
        guard await body.replace(range, with: draft.body) else { throw Failure.writeFailed }

        var originalSubject: String?
        var newSubject: String?
        if fillSubject, let subject, let text = draft.subject, !text.isEmpty {
            let current = await subject.read()
            if let current, current.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current.value == current.placeholder {
                let whole = NSRange(location: 0, length: (current.value == current.placeholder ? 0 : (current.value as NSString).length))
                if await subject.replace(whole, with: text) {
                    originalSubject = current.value == current.placeholder ? "" : current.value
                    newSubject = text
                    await body.focus()
                }
            }
        }
        var history = ReplyEditHistory(original: .init(body: originalBody, subject: originalSubject), range: range)
        history.push(.init(body: draft.body, subject: newSubject))
        history.bodyRange = await locate(draft.body, near: range.location, fallbackLength: (draft.body as NSString).length)
        self.history = history
    }

    /// A new version (Regenerate, Shorter, …) replaces the current one.
    func apply(_ draft: ReplyDraft) async throws {
        guard var history else { return try await insert(draft, fillSubject: false) }
        let target = ReplyEditHistory.Version(body: draft.body, subject: history.current.subject == nil ? nil : (draft.subject ?? history.current.subject))
        let previous = history.index
        history.push(target)
        self.history = history
        do {
            try await write(fromIndex: previous, toIndex: history.index)
        } catch {
            self.history?.revert(to: previous)
            if let h = self.history { self.history = Self.trimmed(h) }
            throw error
        }
    }

    func undo() async throws {
        guard var history, history.canUndo else { return }
        let from = history.index
        guard history.moveBack() != nil else { return }
        self.history = history
        do {
            try await write(fromIndex: from, toIndex: history.index)
        } catch {
            self.history?.revert(to: from)
            throw error
        }
    }

    func redo() async throws {
        guard var history, history.canRedo else { return }
        let from = history.index
        guard history.moveForward() != nil else { return }
        self.history = history
        do {
            try await write(fromIndex: from, toIndex: history.index)
        } catch {
            self.history?.revert(to: from)
            throw error
        }
    }

    /// Replaces version `fromIndex` (in the field now) with `toIndex`.
    private func write(fromIndex: Int, toIndex: Int) async throws {
        guard var history else { return }
        let from = history.versions[fromIndex]
        let target = history.versions[toIndex]
        if usesNativeUndo {
            // Unreadable field: each SparkV version is one paste. ⌘Z removes
            // the version in the field; then the target is pasted (unless the
            // target is what was there before SparkV wrote anything).
            if fromIndex > 0 { guard await body.nativeUndo() else { throw Failure.writeFailed } }
            if toIndex > 0 {
                guard await body.replace(NSRange(location: NSNotFound, length: 0), with: target.body) else { throw Failure.writeFailed }
            }
        } else {
            guard let state = await body.read() else { throw Failure.writeFailed }
            guard let range = ReplyTextLocator.locate(from.body, in: state.value, near: history.bodyRange.location) else {
                throw Failure.changedByUser
            }
            guard await body.replace(range, with: target.body) else { throw Failure.writeFailed }
            history.bodyRange = await locate(target.body, near: range.location, fallbackLength: (target.body as NSString).length)
        }
        if let subject, let text = target.subject ?? history.original.subject, from.subject != target.subject {
            if let current = await subject.read() {
                let whole = NSRange(location: 0, length: current.value == current.placeholder ? 0 : (current.value as NSString).length)
                _ = await subject.replace(whole, with: text)
            }
        }
        self.history?.bodyRange = history.bodyRange
    }

    private func locate(_ text: String, near location: Int, fallbackLength: Int) async -> NSRange {
        let start = location == NSNotFound ? 0 : location
        guard let state = await body.read() else { return NSRange(location: start, length: fallbackLength) }
        return ReplyTextLocator.locate(text, in: state.value, near: start) ?? NSRange(location: start, length: fallbackLength)
    }

    /// Drops versions after the current one (after a failed new version).
    private static func trimmed(_ history: ReplyEditHistory) -> ReplyEditHistory {
        var copy = ReplyEditHistory(original: history.versions[0], range: history.bodyRange)
        for version in history.versions.dropFirst().prefix(history.index) { copy.push(version) }
        copy.bodyRange = history.bodyRange
        return copy
    }
}

// MARK: - Bar placement

enum ReplyBarGeometry {
    /// AppKit frame for the bar: just above the message box, right-aligned
    /// with it; below it when there's no room; clamped to the screen.
    /// `field` is in global Quartz coordinates (top-left origin).
    static func frame(forField field: CGRect?, window: CGRect?, barSize: CGSize, visible: CGRect, primaryHeight: CGFloat, gap: CGFloat = 8) -> CGRect {
        let anchorQuartz = field ?? window.map { CGRect(x: $0.minX, y: $0.maxY - 80, width: $0.width, height: 60) }
        guard let anchorQuartz else {
            return CGRect(x: visible.midX - barSize.width / 2, y: visible.maxY - barSize.height - 60, width: barSize.width, height: barSize.height)
        }
        let anchor = CGRect(x: anchorQuartz.minX, y: primaryHeight - anchorQuartz.maxY, width: anchorQuartz.width, height: anchorQuartz.height)
        var x = anchor.maxX - barSize.width
        if anchor.width < barSize.width { x = anchor.midX - barSize.width / 2 }
        var y = anchor.maxY + gap
        if y + barSize.height > visible.maxY { y = anchor.minY - gap - barSize.height }
        if y < visible.minY { y = visible.minY + gap }
        x = min(max(x, visible.minX + gap), visible.maxX - barSize.width - gap)
        y = min(max(y, visible.minY + gap), visible.maxY - barSize.height - gap)
        return CGRect(x: x.rounded(), y: y.rounded(), width: barSize.width, height: barSize.height)
    }
}
