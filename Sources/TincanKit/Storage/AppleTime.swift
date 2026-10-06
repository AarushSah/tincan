import Foundation

/// Conversions for Apple's timestamps, which count from 2001-01-01 00:00:00 UTC.
///
/// Messages stores nanoseconds on current macOS and seconds on very old databases, in the
/// same columns. Call history stores fractional seconds.
public enum AppleTime {
    /// Values above this are nanoseconds. One hundred billion seconds is more than three
    /// thousand years, and one hundred billion nanoseconds is under two minutes after 2001.
    private static let nanosecondThreshold: Int64 = 100_000_000_000

    /// Converts a Messages `date`, `date_read`, `date_delivered` or `date_edited` value.
    /// Zero and negative values mean "never" and return nil.
    public static func messageDate(_ raw: Int64?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        if raw > nanosecondThreshold {
            return Date(timeIntervalSinceReferenceDate: TimeInterval(raw) / 1_000_000_000)
        }
        return Date(timeIntervalSinceReferenceDate: TimeInterval(raw))
    }

    /// The Messages representation (nanoseconds) of `date`, for query bounds. Dates beyond
    /// what the column can hold, about 290 years either side of 2001, become its limits.
    public static func messageValue(_ date: Date) -> Int64 {
        saturating(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    /// `value` rounded to the nearest Int64, or Int64's limit beyond it. NaN is 0.
    public static func saturating(_ value: Double) -> Int64 {
        guard !value.isNaN else { return 0 }
        // Both limits are powers of two, exact as Doubles.
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value.rounded())
    }

    /// Converts a call history `ZDATE`.
    public static func callDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    /// The call history representation (seconds) of `date`.
    public static func callValue(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }
}
