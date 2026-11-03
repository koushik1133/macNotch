import Foundation

/// Short, plain formats shared by the Extras labs (pure, tested).
enum ExtrasFormat {
    /// "now", "12 s", "4 min", "2 h", "3 d".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    /// "1.2k", "34k", "1.8M" token counts.
    static func compactCount(_ value: Int) -> String {
        let v = Double(value)
        if value < 1000 { return "\(value)" }
        if value < 10_000 { return String(format: "%.1fk", v / 1000) }
        if value < 1_000_000 { return "\(Int((v / 1000).rounded()))k" }
        return String(format: "%.1fM", v / 1_000_000)
    }

    /// "42 s", "3 min 05 s", "1 h 12 min".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d min %02d s", s / 60, s % 60) }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// "1 min", "5 min", "1 h", "6 h" for refresh intervals.
    static func every(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(max(1, seconds / 60)) min" }
        let hours = Double(seconds) / 3600
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }

    /// Text for an island wing: whole entries only. A headline longer than
    /// `limit` is cut at its last double-space separator ("BTC 67k ▼1.2%
    /// ETH 3k ▲2.3%" -> "BTC 67k ▼1.2%"), else at its last space, else
    /// shortened with an ellipsis.
    static func wingText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit, limit > 1 else { return trimmed }
        let head = String(trimmed.prefix(limit + 1))
        if let range = head.range(of: "  ", options: .backwards), range.lowerBound > head.startIndex {
            return String(head[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if let space = head.lastIndex(of: " "), space > head.startIndex {
            let cut = String(head[..<space]).trimmingCharacters(in: .whitespaces)
            if cut.count >= limit / 2 { return cut + "…" }
        }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// The last path component of a folder, "~" for home.
    static func folderName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "Unknown folder" }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
