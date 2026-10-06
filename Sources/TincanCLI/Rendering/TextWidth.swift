import Foundation

/// Terminal column widths for text that mixes Latin script, CJK, emoji and combining marks.
/// Alignment of tables and conversation bubbles depends on this being right.
enum TextWidth {
    /// Number of terminal columns `text` occupies. Escape sequences and style markers count
    /// as zero.
    static func columns(_ text: String) -> Int {
        var total = 0
        TerminalText.forEachPiece(text) { piece in
            if case .character(let character) = piece { total += columns(of: character) }
        }
        return total
    }

    /// Removes escape sequences and style markers, including an ESC or marker character that
    /// starts no complete one.
    static func stripEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == TerminalText.marker }) else { return text }
        var result = ""
        TerminalText.forEachPiece(text) { piece in
            if case .character(let character) = piece { result.append(character) }
        }
        return result
    }

    static func columns(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        // Emoji presentation: flags, keycaps, ZWJ sequences and emoji with VS16 are wide.
        if scalars.count > 1 {
            if scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x200D || $0.value == 0x20E3 }) { return 2 }
            if scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) { return 2 }
        }
        if first.properties.isEmojiPresentation { return 2 }
        let value = first.value
        if value == 0x09 { return TerminalText.tabWidth }
        // Output drops controls, bidirectional formatting and stray marker characters; see
        // `TerminalText.sanitize`.
        if TerminalText.isRemoved(first) || first == TerminalText.marker || value == 0x0A { return 0 }
        if first.properties.generalCategory == .nonspacingMark || first.properties.generalCategory == .enclosingMark { return 0 }
        if value == 0x200B || value == 0x200C || value == 0x200D || value == 0xFEFF { return 0 }
        return isWide(value) ? 2 : 1
    }

    /// East Asian Wide and Fullwidth ranges.
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// Truncates `text` to at most `width` columns, ending with an ellipsis when shortened.
    /// Escape sequences and style markers are never cut, and those after the cut are kept, so
    /// styles still end.
    static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if columns(text) <= width { return text }
        var result = ""
        var used = 0
        var full = false
        TerminalText.forEachPiece(text) { piece in
            switch piece {
            case .escape(let sequence):
                result += sequence
            case .character(let character):
                guard !full else { return }
                let next = columns(of: character)
                if used + next > width - 1 {
                    full = true
                    result += "…"
                    return
                }
                result.append(character)
                used += next
            }
        }
        return result
    }

    /// Shortens `text` to `width` columns by replacing its middle with an ellipsis, for
    /// paths, whose start and end matter most.
    static func truncateMiddle(_ text: String, to width: Int) -> String {
        guard columns(text) > width, width > 3 else { return truncate(text, to: width) }
        var pieces: [TerminalText.Piece] = []
        TerminalText.forEachPiece(text) { pieces.append($0) }
        var start = pieces.endIndex
        var used = 0
        while start > pieces.startIndex {
            if case .character(let character) = pieces[start - 1] {
                let next = columns(of: character)
                if used + next > (width - 1) * 2 / 3 { break }
                used += next
            }
            start -= 1
        }
        let head = pieces[..<start].map(\.text).joined()
        let tail = pieces[start...].map(\.text).joined()
        // `truncate` ends the start with the ellipsis.
        return truncate(head, to: width - used) + tail
    }

    /// Truncates and pads `text` to exactly `width` columns.
    static func fit(_ text: String, to width: Int) -> String {
        padRight(truncate(text, to: width), to: width)
    }

    /// Pads `text` with spaces on the right to `width` columns.
    static func padRight(_ text: String, to width: Int) -> String {
        let missing = width - columns(text)
        return missing > 0 ? text + String(repeating: " ", count: missing) : text
    }

    /// Pads `text` with spaces on the left to `width` columns.
    static func padLeft(_ text: String, to width: Int) -> String {
        let missing = width - columns(text)
        return missing > 0 ? String(repeating: " ", count: missing) + text : text
    }

    /// Greedy word wrap to `width` columns. Long words are split. Existing line breaks are
    /// kept, including line and paragraph separators (U+2028, U+2029).
    /// Each character is measured once, so a very long word takes time in proportion to it.
    private static let lineBreaks = CharacterSet(charactersIn: "\n\u{2028}\u{2029}")

    /// Joins words that must stay on one line: `wrapGlued` never breaks there, and prints
    /// it as an ordinary space.
    static let glue: Character = "\u{00A0}"

    /// `wrap`, then every `glue` back to a space.
    static func wrapGlued(_ text: String, width: Int) -> [String] {
        wrap(text, width: width).map { String($0.map { $0 == glue ? " " : $0 }) }
    }

    /// `wrap`, keeping each `code span` that fits on a line whole, so a command in a hint
    /// is never split between lines.
    static func wrapKeepingCode(_ text: String, width: Int) -> [String] {
        guard text.contains("`") else { return wrap(text, width: width) }
        var glued = ""
        var span: String?
        for character in text {
            guard var code = span else {
                if character == "`" { span = "`" } else { glued.append(character) }
                continue
            }
            code.append(character)
            span = code
            if character == "`" {
                glued += columns(code) <= width ? String(code.map { $0 == " " ? glue : $0 }) : code
                span = nil
            }
        }
        glued += span ?? ""
        return wrapGlued(glued, width: width)
    }

    /// Punctuation that must not start a line in Chinese and Japanese text.
    static let noLineStart: Set<Character> = [
        "。", "、", "，", "．", "！", "？", "：", "；", "）", "」", "』", "】", "〉", "》", "ー", "ゃ", "ゅ", "ょ", "っ", "ャ", "ュ", "ョ", "ッ", "…",
    ]

    /// `wrap` for a line that shows a command, such as `Earlier: tincan read chat:42
    /// --before m:31 --limit 6`: an option stays on the same line as its value.
    static func wrapCommand(_ text: String, width: Int) -> [String] {
        var words: [String] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if let last = words.last, last.hasPrefix("--"), !last.contains(glue), !last.hasSuffix(","), !word.isEmpty, !word.hasPrefix("-"),
                columns(last) + 1 + columns(word) <= width
            {
                words[words.count - 1] = last + String(glue) + word
            } else {
                words.append(word)
            }
        }
        return wrapGlued(words.joined(separator: " "), width: width)
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 1 else { return [text] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: lineBreaks) {
            var line = ""
            var lineWidth = 0
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let wordWidth = columns(word)
                if lineWidth > 0 && lineWidth + 1 + wordWidth <= width {
                    line += " " + word
                    lineWidth += 1 + wordWidth
                    continue
                }
                if lineWidth > 0 {
                    lines.append(line)
                    line = ""
                    lineWidth = 0
                }
                guard wordWidth > width else {
                    line = word
                    lineWidth = wordWidth
                    continue
                }
                // Too long for a line: split it, keeping escape sequences and markers whole.
                var head = ""
                var headWidth = 0
                TerminalText.forEachPiece(word) { piece in
                    switch piece {
                    case .escape(let sequence):
                        head += sequence
                    case .character(let character):
                        let next = columns(of: character)
                        if headWidth > 0 && headWidth + next > width {
                            // Closing punctuation such as 。 never starts a line (kinsoku):
                            // the character before it moves down with it.
                            if noLineStart.contains(character), head.count > 1, let last = head.last,
                                !head.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == TerminalText.marker })
                            {
                                head.removeLast()
                                lines.append(head)
                                head = String(last)
                                headWidth = columns(of: last)
                            } else {
                                lines.append(head)
                                head = ""
                                headWidth = 0
                            }
                        }
                        head.append(character)
                        headWidth += next
                    }
                }
                line = head
                lineWidth = headWidth
            }
            lines.append(line)
        }
        return lines
    }
}
