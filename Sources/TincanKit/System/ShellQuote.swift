import Foundation

/// Quotes an argument for display in a suggested command, so text someone typed, such as
/// `x $(id)`, is shown as one inert argument: `'x $(id)'`.
public func shellQuote(_ text: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-_.:@/"))
    if !text.isEmpty, text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
