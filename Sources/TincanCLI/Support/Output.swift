import ArgumentParser
import Foundation
import TincanKit

/// Options every command accepts.
struct GlobalOptions: ParsableArguments {
    @Flag(name: [.customShort("j"), .long], help: "Print one JSON document instead of formatted text. Also enabled by TINCAN_OUTPUT=json.")
    var json = false

    @Option(name: .long, help: "When to use color. NO_COLOR turns it off unless you say always.")
    var color: ColorMode = .auto

    var wantsJSON: Bool {
        json || ProcessInfo.processInfo.environment["TINCAN_OUTPUT"]?.lowercased() == "json"
    }
}

extension ColorMode: ExpressibleByArgument {}

/// A warning attached to a result: the command worked, but something limits the answer.
struct Notice: Encodable {
    let code: String
    let message: String
    /// Whether human output prints it. Renderers that say the same thing inline, such as a
    /// "more with --limit" footer, keep it for JSON only.
    var printed = true

    enum CodingKeys: String, CodingKey { case code, message }
}

/// Everything a command prints goes through here, so human and JSON output stay consistent.
final class Output {
    let command: String
    let json: Bool
    let terminal: Terminal
    let style: Style
    /// What tincan tells the terminal it is doing, in an interactive terminal only.
    let programStatus: ProgramStatus
    private(set) var notices: [Notice] = []

    init(command: String, options: GlobalOptions) {
        self.command = command
        json = options.wantsJSON
        terminal = Terminal.current(colorMode: json ? .never : options.color)
        style = Style(depth: terminal.colorDepth)
        programStatus = ProgramStatus(enabled: Terminal.reportsStatus(json: json))
    }

    // MARK: Human output

    /// Prints a line of human output. Ignored in JSON mode.
    func line(_ text: String = "") {
        guard !json else { return }
        FileHandle.standardOutput.write(Data((safe(text) + "\n").utf8))
    }

    /// Progress and prompts go to stderr so stdout stays clean for pipes.
    func status(_ text: String) {
        guard !json else { return }
        FileHandle.standardError.write(Data((safe(text) + "\n").utf8))
    }

    /// Prints a next step, such as `Earlier: tincan read …` or `More with --limit 40.`, muted,
    /// on stderr: stdout carries only the result when piped, while a terminal shows both in
    /// order. Pass plain text; an empty line separates a hint from the result. Ignored in
    /// JSON mode, where `next` and warnings say the same.
    func hint(_ text: String = "") {
        guard !json else { return }
        FileHandle.standardError.write(Data((safe(text.isEmpty ? "" : style.muted(text)) + "\n").utf8))
    }

    /// Human output mixes tincan's own styling with text other people wrote, which must
    /// not reach the terminal as escape sequences or controls. Only tincan's style markers
    /// become colors. JSON needs none of this.
    private func safe(_ text: String) -> String {
        TerminalText.sanitize(text, keepStyles: style.enabled)
    }

    /// Adds a warning. `printed: false` keeps it out of human output, for renderers that
    /// already say the same thing in place.
    func warn(_ code: String, _ message: String, printed: Bool = true) {
        guard !notices.contains(where: { $0.code == code }) else { return }
        notices.append(Notice(code: code, message: message, printed: printed))
    }

    /// Warns that a list stopped at `--limit` and more items exist. `command` is the whole
    /// command that shows more, for lists that can't page with a cursor; `pages` says
    /// `next.command` continues the list.
    func warnTruncated(_ shown: Int, _ noun: String, limit: Int, command: String? = nil, pages: Bool = false) {
        let more =
            command.map { "Run `\($0)` for more, or narrow the query." }
            ?? (pages ? "`next.command` continues, or narrow the query." : "Pass --limit \(max(limit * 2, 10)) or narrow the query.")
        warn("truncated", "Showing \(Formatting.plural(shown, noun)); more exist. " + more, printed: false)
    }

    /// Prints collected warnings after human output, once.
    func flushWarnings() {
        guard !json else { return }
        for notice in notices where notice.printed {
            let text = TextWidth.wrap(notice.message, width: max(20, terminal.width - 2))
            let lines = text.enumerated().map { ($0.offset == 0 ? style.warning("! ") : "  ") + $0.element }
            FileHandle.standardError.write(Data((safe(lines.joined(separator: "\n")) + "\n").utf8))
        }
        notices = notices.map {
            var notice = $0
            notice.printed = false
            return notice
        }
    }

    // MARK: JSON output

    struct Envelope<T: Encodable>: Encodable {
        let tincan: String
        let schema: Int
        let command: String
        let ok: Bool
        let data: T?
        let next: Next?
        /// Present on paginated list results, including false at the end.
        let hasMore: Bool?
        let warnings: [Notice]
        let error: ErrorBody?
    }

    /// Where to continue when a result is one page of more.
    struct Next: Encodable {
        /// Pass back with the option the command documents (`--before`, `--after`, …).
        let cursor: String
        /// The full command to run for the next page.
        let command: String
    }

    struct ErrorBody: Encodable {
        let code: String
        let message: String
        let hint: String
        let candidates: [TincanError.Candidate]?
    }

    /// Emits the result. In JSON mode this is the single document on stdout; human output
    /// follows from the renderer, and warnings print after it.
    func result<T: Encodable>(_ data: T, next: Next? = nil, hasMore: Bool? = nil) {
        guard json else { return }
        write(
            Envelope(
                tincan: TincanVersion.current, schema: 1, command: command, ok: true, data: data, next: next, hasMore: hasMore,
                warnings: notices, error: nil))
    }

    /// Reports a failure on stderr (human) or as the JSON document (agents). `data` keeps
    /// what did happen, such as each bubble of a send that stopped partway.
    func failure(_ error: TincanError) {
        failure(error, data: Empty?.none)
    }

    func failure<T: Encodable>(_ error: TincanError, data: T?) {
        if json {
            let body = ErrorBody(code: error.code, message: error.message, hint: error.hint, candidates: error.candidates.isEmpty ? nil : error.candidates)
            write(
                Envelope(
                    tincan: TincanVersion.current, schema: 1, command: command, ok: false, data: data, next: nil, hasMore: nil,
                    warnings: notices, error: body))
            return
        }
        flushWarnings()
        FileHandle.standardError.write(Data(safe(Self.describe(error, style: style, width: terminal.width)).utf8))
    }

    /// The human form of an error: the message, any candidates, and the hint.
    static func describe(_ error: TincanError, style: Style, width: Int) -> String {
        let width = max(40, width)
        var lines: [String] = []
        // A question when the person has something to change or decide, a cross for a failure.
        let marker = error.exit == .needsInput || error.exit == .usage ? "? " : "✗ "
        for (index, line) in TextWidth.wrap(error.message, width: width - 2).enumerated() {
            lines.append((index == 0 ? style.danger(marker) : "  ") + line)
        }
        if !error.candidates.isEmpty {
            let nameWidth = min(32, error.candidates.map { TextWidth.columns($0.name) }.max() ?? 0)
            let referenceWidth = error.candidates.map { TextWidth.columns($0.reference) }.max() ?? 0
            let widestDetail = error.candidates.map { TextWidth.columns($0.detail ?? "") }.max() ?? 0
            // Details shorten before references move to their own lines.
            let detailWidth = min(40, widestDetail, max(0, width - 4 - nameWidth - 2 - 2 - referenceWidth))
            let inline = detailWidth >= min(widestDetail, 12) && 4 + nameWidth + 2 + referenceWidth <= width
            let rows = error.candidates.map { candidate -> (name: String, detail: String, reference: String) in
                (
                    TextWidth.truncate(candidate.name, to: nameWidth),
                    TextWidth.truncate(candidate.detail ?? "", to: inline ? detailWidth : width - 6 - nameWidth), candidate.reference
                )
            }
            for row in rows {
                if inline {
                    let detail = detailWidth > 0 ? "  " + style.muted(TextWidth.padRight(row.detail, to: detailWidth)) : ""
                    lines.append("    " + TextWidth.padRight(row.name, to: nameWidth) + detail + "  " + style.accent(row.reference))
                } else {
                    // Too wide for one line: references go underneath, never truncated.
                    lines.append("    " + row.name + (row.detail.isEmpty ? "" : "  " + style.muted(row.detail)))
                    lines.append("      " + style.accent(row.reference))
                }
            }
        }
        for (index, line) in TextWidth.wrapKeepingCode(error.hint, width: width - 4).enumerated() {
            lines.append(style.muted((index == 0 ? "  → " : "    ") + line))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct Empty: Encodable {}

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Formatting.iso(date))
        }
        return encoder
    }()

    private func write<T: Encodable>(_ value: T) {
        do {
            var data = try Self.encoder.encode(value)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data("tincan: could not encode JSON: \(error)\n".utf8))
        }
    }

    /// One JSON object per line, for streams such as `tincan watch --json`.
    func streamLine<T: Encodable>(_ value: T) {
        do {
            var data = try Self.encoder.encode(value)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data("tincan: could not encode JSON: \(error)\n".utf8))
        }
    }
}
