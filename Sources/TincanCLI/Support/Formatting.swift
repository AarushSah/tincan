import Foundation
import TincanKit

/// Dates, durations and sizes for human output.
enum Formatting {
    /// "just now", "4m ago", "9:41 PM" (today), "yesterday", "Tue", "Mar 4", "Mar 4, 2024".
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 && seconds > -45 { return "just now" }
        if seconds > 0 && seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        if seconds > 0 && seconds < 6 * 86_400 { return weekday(date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return monthDay(date) }
        return monthDayYear(date)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func monthDayYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Heading for a day in a conversation: "Today", "Yesterday", "Tuesday, March 4".
    static func dayHeading(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    /// "42s", "3m 05s", "1h 02m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    /// A rounded interval for "texted back 5m later": "40s", "5m", "1h 4m", "2d".
    static func gap(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86_400 { return total % 3600 < 60 ? "\(total / 3600)h" : "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86_400)d"
    }

    static func bytes(_ count: Int64) -> String { Wording.bytes(count) }

    /// ISO 8601 with the local offset, as used in JSON output.
    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// One formatter for every date in a result; creating one per date is slow in long lists.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// A time cursor for `--before`: ISO 8601 with milliseconds, rounded down so the item it
    /// came from is never repeated on the next page.
    static func cursor(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let milliseconds = (date.timeIntervalSinceReferenceDate * 1000).rounded(.down) / 1000
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: milliseconds))
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        Wording.plural(count, singular, plural)
    }

    /// `a`, `a and b`, `a, b and c`.
    static func list(_ items: [String]) -> String { Wording.list(items) }
}

/// Parses times people and agents write: `2h`, `3d`, `1w`, `today`, `yesterday`,
/// `2026-09-01`, `2026-09-01T14:00`, or full ISO 8601.
enum TimeExpression {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "now" { return now }
        if value == "today" { return calendar.startOfDay(for: now) }
        if value == "yesterday" { return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) }
        if let last = value.last, "mhdw".contains(last), let amount = Double(value.dropLast()), amount.isFinite, amount >= 0 {
            let seconds: Double
            switch last {
            case "m": seconds = amount * 60
            case "h": seconds = amount * 3600
            case "d": seconds = amount * 86_400
            default: seconds = amount * 7 * 86_400
            }
            return now.addingTimeInterval(-seconds)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
