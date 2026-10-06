import Foundation

/// Characters in message text that the person can't see, but an assistant reading the text
/// does.
///
/// Unicode tag characters (U+E0020–U+E007E) map one to one onto printable ASCII and render
/// as nothing, so a message can carry instructions the person never sees ("ASCII
/// smuggling"). Variation selectors can carry any bytes the same way, one selector per byte
/// after a character ("emoji smuggling"). Zero-width and other invisible format characters
/// can hide or split text too. The only legitimate use of tag characters is one of the
/// three subdivision flags Apple shows, such as England's: U+1F3F4, tag characters, then
/// CANCEL TAG (U+E007F). Other subdivision codes show as a plain black flag, hiding the
/// rest.
///
/// Deliberately not flagged, because text in ordinary use needs them and they hide nothing:
/// - U+200C and U+200D (zero-width non-joiner and joiner), which shape Persian, Indic and
///   other scripts and join emoji into one, such as family emoji;
/// - one variation selector after a character, such as U+FE0E and U+FE0F, which choose
///   text or emoji presentation, or an ideographic variation selector after a CJK
///   character. Two in a row, or one after nothing or a space, carry data;
/// - U+00AD (soft hyphen), a hyphenation hint that shows as a hyphen at a line break and is
///   common in text pasted from the web;
/// - U+200E, U+200F and U+061C (directional marks), which keep numbers and punctuation in
///   place in Arabic and Hebrew text. They are invisible, but only nudge the order of
///   neutral characters; the embeddings, overrides and isolates that reorder whole runs are
///   refused by `send` and dropped from terminal output.
public struct HiddenText: Sendable, Equatable {
    /// How many hidden characters the text has.
    public let characters: Int
    /// What the hidden characters spell, in order: the ASCII of tag characters and the UTF-8
    /// that runs of variation selectors encode. Nil when they spell nothing.
    public let decoded: String?

    /// A run of consecutive hidden characters.
    public struct Run: Sendable, Equatable {
        /// Scalar offsets of the run in the text's unicode scalars.
        public let range: Range<Int>
        /// What its tag characters and variation selectors spell, empty when nothing.
        public let decoded: String
    }

    /// The hidden characters in `text`, or nil when it has none.
    public static func find(in text: String) -> HiddenText? {
        let runs = runs(in: text)
        guard !runs.isEmpty else { return nil }
        let decoded = runs.map(\.decoded).joined()
        return HiddenText(characters: runs.reduce(0) { $0 + $1.range.count }, decoded: decoded.isEmpty ? nil : decoded)
    }

    /// Whether `text` has any hidden characters.
    public static func contains(_ text: String) -> Bool {
        !runs(in: text).isEmpty
    }

    /// The first hidden character in `text`, such as a zero-width space or a tag character
    /// outside an emoji tag sequence.
    public static func first(in text: String) -> Unicode.Scalar? {
        let scalars = Array(text.unicodeScalars)
        return runs(in: text).first.map { scalars[$0.range.lowerBound] }
    }

    /// The first character in `text` that can spell hidden text: a tag character outside
    /// an emoji flag, or a variation selector carrying data. Zero-width spaces alone spell
    /// nothing and are not counted.
    public static func firstSpelling(in text: String) -> Unicode.Scalar? {
        let scalars = Array(text.unicodeScalars)
        return runs(in: text).lazy.compactMap { run in scalars[run.range].first { isTag($0) || isVariationSelector($0) } }.first
    }

    /// Every run of hidden characters in `text`, in order.
    public static func runs(in text: String) -> [Run] {
        // Most text has no candidate at all; skip the work.
        guard text.unicodeScalars.contains(where: { isTag($0) || isInvisible($0) || isVariationSelector($0) }) else { return [] }
        let scalars = Array(text.unicodeScalars)
        var hidden = [Bool](repeating: false, count: scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1F3F4, let end = emojiTagSequenceEnd(scalars, from: index + 1) {
                index = end
                continue
            }
            if isVariationSelector(scalar) {
                var end = index
                while end < scalars.count, isVariationSelector(scalars[end]) { end += 1 }
                // One selector after a character chooses how it looks. More, or one after
                // nothing or a space, carry data.
                if end - index > 1 || index == 0 || scalars[index - 1].properties.isWhitespace {
                    for selector in index..<end { hidden[selector] = true }
                }
                index = end
                continue
            }
            hidden[index] = isTag(scalar) || isInvisible(scalar)
            index += 1
        }
        var runs: [Run] = []
        index = 0
        while index < scalars.count {
            guard hidden[index] else {
                index += 1
                continue
            }
            var end = index
            var decoded = ""
            var bytes: [UInt8] = []
            func spellBytes() {
                decoded += String(decoding: bytes, as: UTF8.self)
                bytes = []
            }
            while end < scalars.count, hidden[end] {
                let value = scalars[end].value
                if let byte = selectorByte(value) {
                    bytes.append(byte)
                } else {
                    spellBytes()
                    if case 0xE0020...0xE007E = value { decoded.unicodeScalars.append(Unicode.Scalar(value - 0xE0000)!) }
                }
                end += 1
            }
            spellBytes()
            runs.append(Run(range: index..<end, decoded: decoded))
            index = end
        }
        return runs
    }

    /// `text` with each run of hidden characters replaced by `transform(run)`.
    public static func replacingRuns(in text: String, _ transform: (Run) -> String) -> String {
        let runs = runs(in: text)
        guard !runs.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        for run in runs {
            result.append(contentsOf: scalars[index..<run.range.lowerBound])
            result.append(contentsOf: transform(run).unicodeScalars)
            index = run.range.upperBound
        }
        result.append(contentsOf: scalars[index...])
        return String(result)
    }

    /// The subdivision flags Apple shows: England, Scotland and Wales.
    static let flags = ["gbeng", "gbsct", "gbwls"]

    /// The end of an emoji tag sequence whose tag characters start at `start`: one of
    /// `flags` in tag characters, then CANCEL TAG (U+E007F). Nil when none starts there.
    /// Anything else shows as a black flag with the tags hidden, so it is hidden text.
    private static func emojiTagSequenceEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let end = start + 5
        guard end < scalars.count, scalars[end].value == 0xE007F else { return nil }
        let code = String(String.UnicodeScalarView(scalars[start..<end].compactMap { Unicode.Scalar($0.value &- 0xE0000) }))
        return flags.contains(code) ? end + 1 : nil
    }

    /// Variation selectors: U+FE00–U+FE0F and the ideographic ones, U+E0100–U+E01EF.
    static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        selectorByte(scalar.value) != nil
    }

    /// The byte a variation selector carries when used to smuggle data: U+FE00–U+FE0F are
    /// 0–15 and U+E0100–U+E01EF are 16–255.
    static func selectorByte(_ value: UInt32) -> UInt8? {
        switch value {
        case 0xFE00...0xFE0F: return UInt8(value - 0xFE00)
        case 0xE0100...0xE01EF: return UInt8(value - 0xE0100 + 16)
        default: return nil
        }
    }

    /// The Tags block, U+E0000–U+E007F.
    static func isTag(_ scalar: Unicode.Scalar) -> Bool {
        (0xE0000...0xE007F).contains(scalar.value)
    }

    /// Invisible characters that carry no meaning a reader could see: zero-width space
    /// (U+200B), word joiner and invisible math operators (U+2060–U+2064), the Mongolian
    /// vowel separator (U+180E), the byte order mark anywhere (U+FEFF) and the Hangul fillers
    /// (U+115F, U+1160, U+3164, U+FFA0), which render as blank space in most fonts.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B, 0x2060...0x2064, 0x180E, 0xFEFF, 0x115F, 0x1160, 0x3164, 0xFFA0: return true
        default: return false
        }
    }
}
