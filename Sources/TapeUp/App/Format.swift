import Foundation

enum Format {
    /// 4:05, 42:10, 1:12:40.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: seconds) ?? duration(seconds)
    }

    /// "Today 2:00 PM", "Yesterday 9:30 AM", "Mon 4:15 PM", "Oct 28, 4:15 PM".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        return date.formatted(.dateTime.month(.abbreviated).day()) + ", " + time
    }

    /// "Thu, Nov 7 at 10:15 PM".
    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " at "
            + date.formatted(date: .omitted, time: .shortened)
    }

    /// A path with the home folder shortened to ~.
    static func short(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
