import Foundation

/// Splits a command line the way a POSIX shell would for the simple commands tincan prints
/// and documents: whitespace-separated words with '…' and "…" quoting and \ escapes.
enum Shell {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaped = true
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                escaped = true
                inWord = true
            case " ", "\t":
                if inWord { words.append(current) }
                current = ""
                inWord = false
            default:
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
