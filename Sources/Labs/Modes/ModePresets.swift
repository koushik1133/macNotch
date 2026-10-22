import Foundation

/// The modes SparkV ships with. They have fixed IDs so "Reset Built-in
/// Modes" can put an edited one back, and so a preset the user deleted isn't
/// added again (see `ModeLibraryFile.seededBuiltIns`).
///
/// Actions run top to bottom: quiet things down first (Do Not Disturb,
/// hiding chat apps), then the look (wallpaper, appearance), then sound
/// (volume before the music starts, so it doesn't blast), and the timer last.
enum ModePresets {
    static let concentrationID = UUID(uuidString: "5A4B7C00-0000-4000-8000-000000000001")!
    static let studyID = UUID(uuidString: "5A4B7C00-0000-4000-8000-000000000002")!
    static let relaxID = UUID(uuidString: "5A4B7C00-0000-4000-8000-000000000003")!
    static let meetingID = UUID(uuidString: "5A4B7C00-0000-4000-8000-000000000004")!
    static let presentationID = UUID(uuidString: "5A4B7C00-0000-4000-8000-000000000005")!
    static let nightID = UUID(uuidString: "5A4B7C00-0000-4000-8000-000000000006")!

    /// Long, well-known YouTube streams and mixes (normal watch URLs, which
    /// autoplay in a regular Safari window).
    enum Music {
        // Same URLs and titles as ModeMusicLibrary's lofiStudy, classicalStudy
        // and the Calm rainstorm entry, so the player has their alternates
        // if a stream is replaced. (jfKfPfyJRdk, the 2022-2025 Lofi Girl
        // stream, has ended; the library redirects it to rFZHOHl-L8A.)
        static let lofi = ModeMusicChoice(
            title: "lofi hip hop radio – beats to relax/study to",
            url: "https://www.youtube.com/watch?v=rFZHOHl-L8A",
            volume: nil,
            openInBackground: true
        )
        static let classical = ModeMusicChoice(
            title: "Mozart – Classical Music for Studying, Working & Brain Power",
            url: "https://www.youtube.com/watch?v=3AkZazth0a0",
            volume: nil,
            openInBackground: true
        )
        static let rain = ModeMusicChoice(
            title: "Rainstorm Sounds for Relaxing, Focus or Deep Sleep – 8 Hours",
            url: "https://www.youtube.com/watch?v=yIQd2Ya0Ziw",
            volume: nil,
            openInBackground: true
        )
    }

    enum Apps {
        static let slack = "com.tinyspeck.slackmacgap"
        static let messages = "com.apple.MobileSMS"
        static let mail = "com.apple.mail"
        static let calendar = "com.apple.iCal"
        static let music = "com.apple.Music"
    }

    static var all: [SparkMode] { [concentration, study, relax, meeting, presentation, night] }

    static var ids: Set<UUID> { Set(all.map(\.id)) }

    static func builtIn(_ id: UUID) -> SparkMode? { all.first { $0.id == id } }

    static func isBuiltIn(_ id: UUID) -> Bool { ids.contains(id) }

    static var concentration: SparkMode {
        SparkMode(
            id: concentrationID,
            name: "Concentration",
            symbol: "brain.head.profile",
            colorHex: "#7C5CFF",
            actions: [
                .doNotDisturb(true),
                .hideApps([Apps.slack, Apps.messages, Apps.mail]),
                .wallpaper(.solid(colorHex: "#000000")),
                .volume(0.35),
                .music(Music.lofi),
                .pomodoro(focusMinutes: 50, breakMinutes: 10),
            ],
            restoreOnExit: true,
            autoEndMinutes: nil
        )
    }

    static var study: SparkMode {
        SparkMode(
            id: studyID,
            name: "Study",
            symbol: "book.fill",
            colorHex: "#3D7BFF",
            actions: [
                .doNotDisturb(true),
                .wallpaper(.solid(colorHex: "#0B1A33")),
                .volume(0.3),
                .music(Music.classical),
                .pomodoro(focusMinutes: 25, breakMinutes: 5),
            ],
            restoreOnExit: true,
            autoEndMinutes: nil
        )
    }

    static var relax: SparkMode {
        SparkMode(
            id: relaxID,
            name: "Relax",
            symbol: "leaf.fill",
            colorHex: "#FF8A5B",
            actions: [
                .doNotDisturb(false),
                .wallpaper(.gradient(fromHex: "#FF7E5F", toHex: "#FEB47B")),
                .volume(0.25),
                .music(Music.rain),
            ],
            restoreOnExit: true,
            autoEndMinutes: nil
        )
    }

    static var meeting: SparkMode {
        SparkMode(
            id: meetingID,
            name: "Meeting",
            symbol: "person.2.fill",
            colorHex: "#34C759",
            actions: [
                .doNotDisturb(true),
                .muteNotificationsPreviews(true),
                .hideApps([Apps.music]),
                .openApps([Apps.calendar]),
            ],
            restoreOnExit: true,
            autoEndMinutes: 60
        )
    }

    static var presentation: SparkMode {
        SparkMode(
            id: presentationID,
            name: "Presentation",
            symbol: "play.rectangle.fill",
            colorHex: "#8E8E93",
            actions: [
                .doNotDisturb(true),
                .muteNotificationsPreviews(true),
                .hideApps([ModeAction.allOtherApps]),
                .wallpaper(.solid(colorHex: "#3A3A3C")),
            ],
            restoreOnExit: true,
            autoEndMinutes: nil
        )
    }

    static var night: SparkMode {
        SparkMode(
            id: nightID,
            name: "Night",
            symbol: "moon.stars.fill",
            colorHex: "#5E5CE6",
            actions: [
                .darkMode(true),
                .brightness(0.4),
            ],
            restoreOnExit: true,
            autoEndMinutes: nil
        )
    }
}
