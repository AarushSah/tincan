import Foundation

/// Escape sequences and control characters in text bound for a terminal.
///
/// Message text, names, group names and attachment names come from other people. Printed
/// raw, they could clear the screen, write the clipboard (OSC 52), show a link that goes
/// somewhere else (OSC 8), return the cursor to overwrite what tincan printed, hide text
/// (SGR 8) or reverse the order of the characters that follow.
///
/// So no escape sequence in the text reaches the terminal, not even a color. tincan's own
/// styling travels through rendering as style markers instead: `style(_:)` writes a
/// private-use character, a nonce chosen at random for each run, and SGR parameters.
/// Nobody else knows the nonce, so nobody else can write a marker. `sanitize` removes
/// every escape sequence and control character, and only then turns markers into SGR
/// sequences.
enum TerminalText {
    /// A tab prints as this many spaces, and counts as this many columns.
    static let tabWidth = 4

    /// Turns every style off. Ends each line that has a style, so a style can't spread to
    /// the lines after it.
    static let reset = "\u{1B}[0m"

    /// Starts a style marker. A private-use character, which output drops wherever it does
    /// not start a marker with this run's nonce.
    static let marker: Unicode.Scalar = "\u{E01B}"

    /// This run's nonce: 16 random digits. Text other people wrote can't contain it, so
    /// only `style(_:)` makes markers that become SGR sequences.
    static let nonce: String = String((0..<16).map { _ in Character(String(Int.random(in: 0...9))) })

    /// tincan's own SGR sequence with `parameters`, such as "1" for bold, as a style marker.
    static func style(_ parameters: String) -> String {
        "\(Character(marker))\(nonce)[\(parameters)m"
    }

    /// `text` with only printable characters and, when `keepStyles`, tincan's own styles.
    /// Drops every escape sequence (CSI, including SGR, OSC, DCS, APC, PM, SOS and
    /// two-character escapes), C0 controls except newline, DEL, C1 controls, carriage
    /// returns, and bidirectional embeddings, overrides and isolates. Tabs become spaces, and
    /// so do line and paragraph separators (`TextWidth.wrap` breaks lines there first).
    /// Only then do style markers become SGR sequences; any other marker character is
    /// dropped. Without `keepStyles` markers are dropped too.
    static func sanitize(_ text: String, keepStyles: Bool) -> String {
        guard text.unicodeScalars.contains(where: needsCleaning) else { return text }
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // First the text without escape sequences and controls, markers kept as they are.
            var plain = String.UnicodeScalarView()
            var index = line.startIndex
            while index < line.endIndex {
                let scalar = line[index]
                if scalar == "\u{1B}" {
                    index = sequence(in: line, at: index)
                    continue
                }
                if scalar == "\t" {
                    plain.append(contentsOf: String(repeating: " ", count: tabWidth).unicodeScalars)
                } else if isSeparator(scalar) {
                    // A terminal may break the line there, or not; either way the layout breaks.
                    plain.append(" ")
                } else if !isRemoved(scalar) {
                    plain.append(scalar)
                }
                index = line.index(after: index)
            }
            // Then tincan's markers become SGR sequences, and nothing else can.
            var result = String.UnicodeScalarView()
            var styled = false
            index = plain.startIndex
            while index < plain.endIndex {
                let scalar = plain[index]
                guard scalar == marker else {
                    result.append(scalar)
                    index = plain.index(after: index)
                    continue
                }
                guard let style = styleMarker(in: plain, at: index) else {
                    index = plain.index(after: index)
                    continue
                }
                if keepStyles {
                    result.append("\u{1B}")
                    result.append("[")
                    result.append(contentsOf: plain[style.parameters])
                    result.append("m")
                    styled = true
                }
                index = style.end
            }
            if styled { result.append(contentsOf: reset.unicodeScalars) }
            return String(result)
        }
        return lines.joined(separator: "\n")
    }

    /// Characters that never reach the terminal: controls other than newline and tab, and
    /// bidirectional formatting that reorders the text around it.
    static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// U+2028 and U+2029: line breaks in text, which a terminal shows as it likes.
    static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x2028 || scalar.value == 0x2029
    }

    private static func needsCleaning(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\t" || scalar == marker || isRemoved(scalar) || isSeparator(scalar)
    }

    /// The end of the style marker that starts with the marker character at `start`, and
    /// the range of its SGR parameters. Nil when the character starts no marker with this
    /// run's nonce: then it is only a character someone wrote.
    static func styleMarker<Scalars: BidirectionalCollection>(
        in scalars: Scalars, at start: Scalars.Index
    ) -> (end: Scalars.Index, parameters: Range<Scalars.Index>)?
    where Scalars.Element == Unicode.Scalar {
        var index = scalars.index(after: start)
        for expected in nonce.unicodeScalars {
            guard index < scalars.endIndex, scalars[index] == expected else { return nil }
            index = scalars.index(after: index)
        }
        guard index < scalars.endIndex, scalars[index] == "[" else { return nil }
        index = scalars.index(after: index)
        let parameters = index
        while index < scalars.endIndex, "0123456789;:".unicodeScalars.contains(scalars[index]) {
            index = scalars.index(after: index)
        }
        guard index < scalars.endIndex, scalars[index] == "m" else { return nil }
        return (scalars.index(after: index), parameters..<index)
    }

    /// The end of the escape sequence that starts with the ESC at `start`. An ESC that
    /// starts no complete sequence ends right after itself, so what follows it is ordinary
    /// text.
    static func sequence<Scalars: BidirectionalCollection>(in scalars: Scalars, at start: Scalars.Index) -> Scalars.Index
    where Scalars.Element == Unicode.Scalar {
        let lone = scalars.index(after: start)
        let introducer = scalars.index(after: start)
        guard introducer < scalars.endIndex else { return lone }
        let first = scalars[introducer].value
        var index = scalars.index(after: introducer)
        switch first {
        case 0x5B: // CSI: ESC [ parameters intermediates final
            while index < scalars.endIndex, (0x30...0x3F).contains(scalars[index].value) {
                index = scalars.index(after: index)
            }
            while index < scalars.endIndex, (0x20...0x2F).contains(scalars[index].value) {
                index = scalars.index(after: index)
            }
            guard index < scalars.endIndex, (0x40...0x7E).contains(scalars[index].value) else { return lone }
            return scalars.index(after: index)
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // OSC, DCS, SOS, PM and APC: strings ended by BEL or ST
            while index < scalars.endIndex {
                let value = scalars[index].value
                if value == 0x07 || value == 0x9C { return scalars.index(after: index) }
                let next = scalars.index(after: index)
                if value == 0x1B, next < scalars.endIndex, scalars[next] == "\\" { return scalars.index(after: next) }
                index = next
            }
            return lone
        case 0x20...0x2F: // ESC intermediates final, such as a character set choice
            while index < scalars.endIndex, (0x20...0x2F).contains(scalars[index].value) {
                index = scalars.index(after: index)
            }
            guard index < scalars.endIndex, (0x30...0x7E).contains(scalars[index].value) else { return lone }
            return scalars.index(after: index)
        case 0x30...0x7E: // Two-character escapes, such as ESC c (reset) and ESC 7 (save cursor)
            return index
        default:
            return lone
        }
    }

    /// A piece of text for width calculations: one escape sequence or style marker, which
    /// takes no columns and is never split, or one character. A marker character that
    /// starts no marker is a piece of its own too, since output drops it.
    enum Piece {
        case escape(Substring)
        case character(Character)

        var text: String {
            switch self {
            case .escape(let sequence): return String(sequence)
            case .character(let character): return String(character)
            }
        }
    }

    /// Calls `body` with each escape sequence, style marker and character of `text`, in order.
    static func forEachPiece(_ text: String, _ body: (Piece) -> Void) {
        let scalars = text.unicodeScalars
        guard scalars.contains(where: { $0 == "\u{1B}" || $0 == marker }) else {
            for character in text { body(.character(character)) }
            return
        }
        var runStart = scalars.startIndex
        var index = scalars.startIndex
        func flush(to end: String.Index) {
            guard runStart < end else { return }
            for character in Substring(scalars[runStart..<end]) { body(.character(character)) }
        }
        while index < scalars.endIndex {
            let end: String.Index
            if scalars[index] == "\u{1B}" {
                end = sequence(in: scalars, at: index)
            } else if scalars[index] == marker {
                end = styleMarker(in: scalars, at: index)?.end ?? scalars.index(after: index)
            } else {
                index = scalars.index(after: index)
                continue
            }
            flush(to: index)
            body(.escape(Substring(scalars[index..<end])))
            index = end
            runStart = end
        }
        flush(to: scalars.endIndex)
    }
}
