import Foundation

/// Help phrases shared by every command, so the same idea reads the same everywhere.
enum Help {
    static let target = "A name, phone number, email, address:<address>, contact:<id>, chat:<id>, or `me` for yourself."
    static let person = "A name, phone number, email, address:<address>, contact:<id>, or `me` for your own card."
    static let times = "30m, 2h, 3d, 1w, today, yesterday, 2026-09-01 or an ISO time"
    static let since = "Only messages after this time: \(times)."
    static let mine = "Include messages you sent."
}

/// Parses a time option or fails with an actionable message.
func parseTime(_ text: String, option: String) throws -> Date {
    guard let date = TimeExpression.parse(text), date.timeIntervalSinceReferenceDate.isFinite else {
        throw TincanError.usage("\(option) \"\(text)\" is not a time.", hint: "Use \(Help.times).")
    }
    return date
}

/// Parses a position in Messages' history, from `inbox` and `watch` results: `m:184022`, or
/// the bare number. `m:0` is the start.
func parseCursor(_ text: String, option: String) throws -> Int64 {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.lowercased().hasPrefix("m:") ? String(trimmed.dropFirst(2)) : trimmed
    guard let value = Int64(digits), value >= 0 else {
        throw TincanError.usage("\(option) \"\(text)\" is not a cursor.", hint: "Pass the `cursor` from a previous result, such as m:184022.")
    }
    return value
}

/// Parses a message reference: `m:184022` or the bare number. Nil when `text` is neither,
/// so an option can also take a time; fails when it starts with `m:` but names no message.
/// `orTime` adds times to the hint, for options that take either.
func parseMessageReference(_ text: String, option: String, orTime: Bool = false) throws -> Int64? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let isReference = trimmed.lowercased().hasPrefix("m:")
    guard let id = Int64(isReference ? String(trimmed.dropFirst(2)) : trimmed) else {
        guard isReference else { return nil }
        throw TincanError.usage("\(option) \"\(text)\" is not a message reference.", hint: messageReferenceHint(orTime: orTime))
    }
    guard id > 0 else {
        throw TincanError.usage("\(option) \"\(text)\" is not a message reference.", hint: messageReferenceHint(orTime: orTime))
    }
    return id
}

private func messageReferenceHint(orTime: Bool) -> String {
    "Use m:<id> from a previous result, such as m:184022" + (orTime ? ", or a time: \(Help.times)." : ".")
}

/// A message cursor as results print it: `m:184022`.
func messageCursor(_ id: Int64) -> String { "m:\(id)" }

extension TincanError {
    /// A message reference names no message tincan can read: it never existed, or it is in
    /// an excluded conversation. Exit 3.
    static func unknownMessage(_ reference: String, hint: String) -> TincanError {
        TincanError(code: "unknown_message", message: "\(reference) is not a message tincan can read.", hint: hint, exit: .needsInput)
    }
}

/// The largest `--limit`: more than any page needs, and far from where counting one more
/// row overflows.
let maximumLimit = 1_000_000

/// Fails unless `--limit` is from 1 to `maximumLimit`.
func requireLimit(_ limit: Int) throws {
    guard limit >= 1 else {
        throw TincanError.usage("--limit must be at least 1.", hint: "Pass a positive number, such as --limit 20.")
    }
    guard limit <= maximumLimit else {
        throw TincanError.usage("--limit must be at most \(maximumLimit).", hint: "Pass a smaller number, such as --limit 1000.")
    }
}
