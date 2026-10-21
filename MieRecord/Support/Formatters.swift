import Foundation

enum Formatters {
    /// `m:ss` below an hour, `h:mm:ss` above.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func defaultTitle(for date: Date = Date()) -> String {
        "Recording \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
