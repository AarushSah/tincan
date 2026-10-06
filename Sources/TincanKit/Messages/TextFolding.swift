import Foundation

/// How search compares text: ignoring case and accents, and treating typographic
/// punctuation as its plain form, so `geht's` finds `geht’s` and `wait...` finds `wait…`.
/// Phones type curly quotes and dashes where keyboards type straight ones.
public enum TextFolding {
    /// Typographic characters and their plain forms.
    static let plain: [Unicode.Scalar: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'", "\u{2032}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{2033}": "\"",
        "\u{2010}": "-", "\u{2011}": "-", "\u{2013}": "-", "\u{2014}": "-", "\u{2212}": "-",
        "\u{2026}": "...", "\u{00A0}": " ", "\u{202F}": " ",
    ]

    /// `text` without case, accents or typographic punctuation.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard folded.unicodeScalars.contains(where: { plain[$0] != nil }) else { return folded }
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if let replacement = plain[scalar] {
                result.append(contentsOf: replacement.unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// The range of the first match of `query` in `text`, compared as `fold` does.
    public static func range(of query: String, in text: String) -> Range<String.Index>? {
        let needle = Array(fold(query))
        guard !needle.isEmpty else { return nil }
        // Fold each character on its own, remembering which one each folded character came from.
        var folded: [Character] = []
        var origins: [String.Index] = []
        for index in text.indices {
            for character in fold(String(text[index])) {
                folded.append(character)
                origins.append(index)
            }
        }
        guard folded.count >= needle.count else { return nil }
        for start in 0...(folded.count - needle.count) where folded[start..<start + needle.count].elementsEqual(needle) {
            return origins[start]..<text.index(after: origins[start + needle.count - 1])
        }
        return nil
    }
}
