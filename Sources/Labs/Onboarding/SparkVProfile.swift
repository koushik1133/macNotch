import Foundation

/// The name the user gives in onboarding. Used only on this Mac: meeting
/// notes ("Priya's tasks" vs yours), spotting questions aimed at you in
/// live captions, and signing reply drafts. Empty falls back to the macOS
/// account name.
enum SparkVProfile {
    static let key = "SparkV.profile.name"

    static var savedName: String {
        get { UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key) }
    }

    /// The saved name, else the macOS account's full name.
    static var fullName: String {
        let saved = savedName
        return saved.isEmpty ? NSFullUserName() : saved
    }

    static var firstName: String {
        let first = fullName.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return first.isEmpty ? NSUserName() : first
    }
}
