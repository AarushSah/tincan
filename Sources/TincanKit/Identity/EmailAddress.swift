import Foundation

extension Address {
    /// Whether `text` is an email address: a local part, one @, and a domain with a dot.
    /// Stricter than `Address`, which takes anything with an @ for an email, so a typo such
    /// as `maya@` never becomes a new contact's email or a new conversation.
    public static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }
}
