import Foundation

/// English for sentences people read. Planners and the CLI share it, so a count, a list or a
/// size reads the same wherever it is written.
public enum Wording {
    /// "1 message", "3 messages"; `plural` for a noun whose plural isn't regular.
    public static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? pluralize(singular)))"
    }

    /// English plural for the nouns tincan counts: "match" → "matches", "reply" → "replies".
    public static func pluralize(_ noun: String) -> String {
        if noun.hasSuffix("ch") || noun.hasSuffix("sh") || noun.hasSuffix("s") || noun.hasSuffix("x") { return noun + "es" }
        if noun.hasSuffix("y"), let before = noun.dropLast().last, !"aeiou".contains(before) { return noun.dropLast() + "ies" }
        return noun + "s"
    }

    /// `a`, `a and b`, `a, b and c`.
    public static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A file size as Finder shows it: "2 KB", "100 MB".
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
