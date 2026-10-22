import Foundation

// Meeting Intelligence, part C: app adapters for WrapUp.swift. Kept apart so
// WrapUp.swift builds (and is tested) without MeetingAssistant / SpaceStore.

/// MeetingAssistant as the wrap-up's meeting source.
@MainActor
final class MeetingAssistantWrapUpSource: MeetingWrapUpSource {
    private weak var assistant: MeetingAssistant?

    init(assistant: MeetingAssistant) {
        self.assistant = assistant
    }

    func record(id: UUID) -> MeetingRecord? {
        assistant?.record(id: id)
    }

    func isWritingNotes(for id: UUID) -> Bool {
        guard let assistant, assistant.current?.id == id else { return false }
        switch assistant.phase {
        case .recording, .summarizing: return true
        case .idle, .failed: return false
        }
    }

    var allowsGroq: Bool { assistant?.allowGroqForMeetings ?? false }

    func openNotes(meetingID: UUID) {
        assistant?.openNotesWindow(meetingID: meetingID)
    }
}

extension SpaceStore: MeetingWrapUpSpaces {
    func ingestInput(for record: MeetingRecord, attendees: [String]) -> SpaceIngestInput? {
        SpaceConnectors.meetingInput(record, attendees: attendees)
    }
}

extension MeetingWrapUpController {
    /// The contract init (DESIGN.md §6).
    convenience init(activities: ActivityCenter,
                     assistant: MeetingAssistant,
                     spaces: SpaceStore?,
                     reminders: any MeetingRemindersGate,
                     store: MeetingIntelSidecarStore = .shared) {
        self.init(activities: activities,
                  source: MeetingAssistantWrapUpSource(assistant: assistant),
                  spaces: spaces,
                  reminders: reminders,
                  store: store,
                  userName: MeetingAssistant.userName)
        monologueThreshold = MeetingIntelPreferences.shared.monologueSeconds
        // Read only when Polish falls back to Groq (allowGroqForMeetings on).
        groqKey = { await Task.detached(priority: .userInitiated) { ClickyKeychain.load() }.value }
    }
}
