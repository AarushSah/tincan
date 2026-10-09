import Foundation

/// Tells the terminal what tincan is doing with OSC 7501, the Program Status Protocol
/// (https://www.superlogical.com/rex/docs/build/program-status): that a send is under way
/// and how far along it is, that tincan is waiting for an answer, and how it ended. A
/// terminal that supports it can show this on a tab nobody is looking at; others ignore it.
///
/// tincan reports only where a person might walk away: while it sends, asks a question, or
/// waits for macOS or System Settings. The terminal drops `working` and `blocked` when
/// tincan exits and keeps `done` and `error`, so only long work, `send` and doctor's setup,
/// reports how it ended (`keepsOutcome`). A quick change leaves `working` after its question
/// for the terminal to drop. Reports go to standard error, and only where
/// `Terminal.reportsStatus` allows.
final class ProgramStatus {
    enum State: String {
        case idle, working, blocked, done, error
    }

    /// What a blocked tincan needs from the person.
    enum Kind: String {
        /// Approval to do something, such as sending.
        case permission
        /// An answer typed at the prompt.
        case question
        /// A grant in System Settings, or an answer to a question macOS asks.
        case auth
    }

    /// The program's name in every report.
    static let app = "tincan"
    /// The longest `msg`, in UTF-8 bytes before encoding. The protocol allows 2048, but a
    /// status is read at a glance.
    static let messageLimit = 200

    let enabled: Bool
    /// Whether this command has reported.
    private(set) var started = false
    /// Whether it reported how it ended: `done`, `error` or `idle`.
    private(set) var ended = false
    /// Set by long work, such as a send, whose result the terminal should keep: only then do
    /// `done` and `error` report.
    var keepsOutcome = false
    private let write: (String) -> Void

    /// `write` receives each report whole.
    init(enabled: Bool, write: @escaping (String) -> Void = ProgramStatus.writeToStandardError) {
        self.enabled = enabled
        self.write = write
    }

    // MARK: Reporting

    /// tincan is running. `progress` is a percentage; without it, how long is unknown.
    func working(_ message: String? = nil, progress: Int? = nil) {
        report(.working, progress: progress, message: message)
    }

    /// tincan waits for the person.
    func blocked(_ kind: Kind, _ message: String) {
        report(.blocked, kind: kind, message: message)
    }

    /// The person declined, and tincan stops. Only after a report.
    func idle(_ message: String?) {
        end(.idle, message)
    }

    /// Long work succeeded. Only after a report, and only with `keepsOutcome`.
    func done(_ message: String?) {
        guard keepsOutcome else { return }
        end(.done, message)
    }

    /// Long work failed. Only after a report, and only with `keepsOutcome`.
    func failed(_ message: String?) {
        guard keepsOutcome else { return }
        end(.error, message)
    }

    private func report(_ state: State, kind: Kind? = nil, progress: Int? = nil, message: String?) {
        guard enabled else { return }
        started = true
        ended = false
        write(Self.sequence(state, kind: kind, progress: progress, message: message))
    }

    private func end(_ state: State, _ message: String?) {
        guard enabled, started, !ended else { return }
        ended = true
        write(Self.sequence(state, message: message))
    }

    // MARK: Encoding

    /// One report: `ESC ] 7501 ; state=…:kind=…:progress=…:app=tincan:msg=… ESC \`. `kind`
    /// goes only with `blocked`, `progress` (0 to 100) only with `working` and `blocked`, and
    /// `msg` is `line(message)` in base64, left out when empty.
    static func sequence(_ state: State, kind: Kind? = nil, progress: Int? = nil, message: String? = nil) -> String {
        var fields = ["state=" + state.rawValue]
        if state == .blocked, let kind { fields.append("kind=" + kind.rawValue) }
        if state == .working || state == .blocked, let progress { fields.append("progress=\(min(100, max(0, progress)))") }
        fields.append("app=" + app)
        if let message {
            let text = Self.line(message)
            if !text.isEmpty { fields.append("msg=" + Data(text.utf8).base64EncodedString()) }
        }
        return "\u{1B}]7501;" + fields.joined(separator: ":") + "\u{1B}\\"
    }

    /// `text` as one short line: control characters, line breaks and bidirectional formatting
    /// become spaces, runs of spaces one, and text longer than `limit` UTF-8 bytes ends in
    /// "…" at a character boundary.
    static func line(_ text: String, limit: Int = messageLimit) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let blank = scalar == " " || scalar.value < 0x20 || TerminalText.isRemoved(scalar) || TerminalText.isSeparator(scalar)
            if blank {
                if let last = scalars.last, last != " " { scalars.append(" ") }
            } else {
                scalars.append(scalar)
            }
        }
        let line = String(scalars).trimmingCharacters(in: .whitespaces)
        guard line.utf8.count > limit else { return line }
        var shortened = ""
        var bytes = 0
        for character in line {
            bytes += character.utf8.count
            guard bytes <= limit - "…".utf8.count else { break }
            shortened.append(character)
        }
        return shortened.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Writing

    static func writeToStandardError(_ report: String) {
        FileHandle.standardError.write(Data(report.utf8))
    }
}
