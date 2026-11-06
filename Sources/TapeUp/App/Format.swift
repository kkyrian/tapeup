import AppKit
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

    /// A recording's length in words, so it never reads as a time of day:
    /// "3 sec", "42 min", "1 hr 12 min".
    static func length(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) sec" }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
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

    /// "10:15 PM" or "22:15", as the user's clock reads.
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The width of the widest time this clock shows, so a column of times lines up.
    static let timeColumnWidth: CGFloat = {
        let sample = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 22, minute: 58))!
        let text = time(sample) as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return ceil(text.size(withAttributes: [.font: font]).width) + 2
    }()

    /// A day heading: "Today", "Yesterday", "Wednesday", or "Oct 28".
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
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

    /// "2.5 GB".
    static func gigabytes(_ bytes: Int64) -> String { "\(gigabytes(bytes, of: bytes)) GB" }

    /// The number alone, "0.8", for "0.8 of 2.5 GB".
    static func gigabytes(_ bytes: Int64, of total: Int64) -> String {
        String(format: "%.1f", Double(min(bytes, total)) / 1e9)
    }

    /// "32%", never 100% before it is done.
    static func percent(_ done: Int64, of total: Int64) -> String {
        "\(min(99, Int(Double(done) / Double(max(total, 1)) * 100)))%"
    }
}
