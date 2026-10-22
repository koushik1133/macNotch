import Foundation

// Shared types for the meeting assistant: capture (MeetingRecorder), notes and
// live answers (MeetingSummarizer, QuestionAnswerer) and the coordinator/UI
// (MeetingAssistant, MeetingNotesWindow).

/// Who was speaking. The microphone is "me"; system audio (Zoom, Meet,
/// Teams, …) is everyone else.
enum MeetingSpeaker: String, Codable, Sendable {
    case me
    case others
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let speaker: MeetingSpeaker
    var text: String
    /// Seconds since the recording started.
    var start: TimeInterval
    var end: TimeInterval
    /// Volatile (still being recognized) segments are replaced in place by
    /// the final one with the same id.
    var isFinal: Bool
}

struct ActionItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// Who owns it, as said in the meeting ("Koushik", "Priya", "Team").
    var owner: String
    var task: String
    /// Due date or timeframe as spoken ("Friday", "next sprint"), if any.
    var due: String?
    /// True when the owner is the user.
    var isMine: Bool
    var isDone: Bool
}

/// Minutes of meeting.
struct MeetingNotes: Codable, Equatable, Sendable {
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var myTasks: [ActionItem]
    var othersTasks: [ActionItem]
    var openQuestions: [String]
    var nextSteps: [String]
    /// Which backend produced these notes ("On-device" or "Groq <model>").
    var generatedBy: String
}

struct SuggestedAnswer: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let question: String
    var answer: String
    /// Seconds since the recording started.
    let askedAt: TimeInterval
}

struct MeetingRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    /// EventKit identifier when started from a calendar event.
    var calendarEventID: String?
    var segments: [TranscriptSegment]
    var notes: MeetingNotes?
    var answers: [SuggestedAnswer]
    /// What the user typed during the meeting (Granola-style notepad). The
    /// minutes are written around these points. Optional so meetings saved
    /// before this field existed still decode.
    var userNotes: String? = nil
}
