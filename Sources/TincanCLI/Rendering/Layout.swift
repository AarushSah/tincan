import Foundation

/// Line layouts shared by the renderers. Each result fits in `width` columns.
enum Layout {
    /// `Name  ·  detail  ·  detail            trailing`: a bold title, muted details that
    /// shorten first when space runs out, and a muted reference on the right.
    static func header(_ title: String, details: [String], trailing: String, width: Int, style: Style) -> String {
        let trailingWidth = TextWidth.columns(trailing)
        let available = max(8, width - trailingWidth - 2)
        let name = TextWidth.truncate(title, to: available)
        var line = style.bold(name)
        let room = available - TextWidth.columns(name) - 5
        let detail = fitting(details, separator: "  ·  ", width: room)
        if !detail.isEmpty, room >= 6 {
            line += style.muted("  ·  " + detail)
        }
        guard !trailing.isEmpty else { return line }
        if TextWidth.columns(line) + 2 + trailingWidth > width { return line }
        return TextWidth.padRight(line, to: width - trailingWidth) + style.muted(trailing)
    }

    /// `parts` joined with `separator`, as many whole parts as fit in `width`; only the first
    /// part is shortened when even it doesn't fit. Unstyled.
    static func fitting(_ parts: [String], separator: String, width: Int) -> String {
        var text = ""
        for part in parts where !part.isEmpty {
            let next = text.isEmpty ? part : text + separator + part
            guard TextWidth.columns(next) <= width else {
                return text.isEmpty ? TextWidth.truncate(part, to: width) : text
            }
            text = next
        }
        return text
    }

    /// Word-wrapped text with a first-line prefix and a hanging indent for the rest.
    static func hanging(_ text: String, first: String, rest: String, width: Int) -> [String] {
        let room = max(8, width - max(TextWidth.columns(first), TextWidth.columns(rest)))
        return TextWidth.wrap(text, width: room).enumerated().map { ($0.offset == 0 ? first : rest) + $0.element }
    }

    /// A styled piece of a line: its text and how to color it.
    typealias Part = (text: String, apply: (String) -> String)

    /// Joins parts with a muted ` · `, truncating the text (never the escapes) to `width`.
    /// Parts that no longer fit are dropped; with `whole`, a part is shown whole or not at all.
    static func parts(_ parts: [Part], width: Int, style: Style, whole: Bool = false) -> String {
        var line = ""
        var used = 0
        for part in parts where !part.text.isEmpty {
            let separator = used == 0 ? "" : " · "
            let room = width - used - TextWidth.columns(separator)
            guard room > 1, !whole || TextWidth.columns(part.text) <= room else { break }
            let text = TextWidth.truncate(part.text, to: room)
            line += (separator.isEmpty ? "" : style.muted(separator)) + part.apply(text)
            used += TextWidth.columns(separator) + TextWidth.columns(text)
            if text != part.text { break }
        }
        return line
    }
}
