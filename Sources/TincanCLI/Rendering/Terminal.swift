import Foundation

/// When to use ANSI styling in human output.
public enum ColorMode: String, CaseIterable, Sendable {
    case auto, always, never
}

/// Facts about the terminal that human output adapts to.
struct Terminal {
    enum ColorDepth: Int, Comparable {
        case none = 0
        case basic, extended, truecolor
        static func < (lhs: ColorDepth, rhs: ColorDepth) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let isInteractive: Bool
    let width: Int
    let colorDepth: ColorDepth

    static func current(colorMode: ColorMode, environment: [String: String] = ProcessInfo.processInfo.environment) -> Terminal {
        let interactive = isatty(STDOUT_FILENO) == 1
        return Terminal(
            isInteractive: interactive,
            width: detectWidth(environment: environment, interactive: interactive),
            colorDepth: detectColorDepth(mode: colorMode, environment: environment, interactive: interactive)
        )
    }

    /// Whether stdin is a terminal a person can answer prompts from.
    static var canPrompt: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    /// Whether tincan reports its status to the terminal (`ProgramStatus`): only when
    /// standard error is a terminal, never for JSON, and not when TERM is `dumb`.
    static func reportsStatus(
        json: Bool, environment: [String: String] = ProcessInfo.processInfo.environment, standardError: Bool = isatty(STDERR_FILENO) == 1
    ) -> Bool {
        !json && standardError && environment["TERM"] != "dumb"
    }

    static func detectWidth(environment: [String: String], interactive: Bool) -> Int {
        if let columns = environment["COLUMNS"].flatMap(Int.init), columns >= 20 { return columns }
        var size = winsize()
        if interactive, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col >= 20 {
            return Int(size.ws_col)
        }
        return 100
    }

    static func detectColorDepth(mode: ColorMode, environment: [String: String], interactive: Bool) -> ColorDepth {
        switch mode {
        case .never:
            return .none
        case .auto:
            if environment["NO_COLOR"].map({ !$0.isEmpty }) == true { return .none }
            let forced = environment["FORCE_COLOR"].map { !$0.isEmpty && $0 != "0" } ?? false
            if !interactive && !forced { return .none }
            if environment["TERM"] == "dumb" && !forced { return .none }
        case .always:
            break
        }
        let colorTerm = (environment["COLORTERM"] ?? "").lowercased()
        if colorTerm == "truecolor" || colorTerm == "24bit" { return .truecolor }
        let program = environment["TERM_PROGRAM"] ?? ""
        if ["iTerm.app", "WezTerm", "ghostty", "vscode", "WarpTerminal"].contains(program) { return .truecolor }
        if (environment["TERM"] ?? "").contains("256color") { return .extended }
        return .basic
    }
}
