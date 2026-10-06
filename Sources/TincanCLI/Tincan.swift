import ArgumentParser
import Foundation
import TincanKit

public struct Tincan: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tincan",
        abstract: "Your texts, calls and contacts, for you and your assistants.",
        discussion: """
            On its own, tincan shows unread conversations and missed calls you haven't returned. For assistants: add --json to any command, and read `tincan skill`.

            Start here:
              tincan doctor              Check permissions and set tincan up
              tincan chats               Recent conversations
              tincan read Maya           Read a conversation (iMessage, SMS and RCS merged)
              tincan who Maya            Everything about a person: numbers, threads, calls
              tincan send Maya "hey!"    Send, paced like a person typing
              tincan calls --missed      Missed calls
            """,
        version: TincanVersion.current,
        subcommands: [
            Doctor.self,
            Chats.self,
            Read.self,
            Who.self,
            Inbox.self,
            Search.self,
            Send.self,
            Watch.self,
            Calls.self,
            ContactsCommand.self,
            ConfigCommand.self,
            Exclude.self,
            Skill.self,
        ]
    )

    @OptionGroup var global: GlobalOptions

    public init() {}

    public func run() async throws {
        try await Home.run(options: global)
    }
}

/// Entry point used by the executable. Calling `main()` from an async function makes Swift
/// choose ArgumentParser's asynchronous overload.
public enum TincanMain {
    public static func run() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let wantsJSON = asksForJSON(arguments) || ProcessInfo.processInfo.environment["TINCAN_OUTPUT"]?.lowercased() == "json"
        do {
            var command = try Tincan.parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(report(error, wantsJSON: wantsJSON, arguments: arguments))
        }
    }

    /// Reports parse errors, help and version. A command line that doesn't parse exits with
    /// 64 (`EX_USAGE`), like tincan's own `invalid_input`, and becomes a JSON error document
    /// with --json.
    private static func report(_ error: Error, wantsJSON: Bool, arguments: [String]) -> Int32 {
        let code = Tincan.exitCode(for: error)
        if let exitCode = error as? ExitCode {
            return exitCode.rawValue
        }
        if code == .success {
            // --help and --version.
            print(Tincan.fullMessage(for: error))
            return 0
        }
        guard wantsJSON else {
            if let unknown = unknownCommand(error, arguments: arguments) {
                // Only --color matters here; the rest of the arguments didn't parse.
                var color: [String] = []
                if let index = arguments.firstIndex(of: "--color"), index + 1 < arguments.count { color = ["--color", arguments[index + 1]] }
                if let options = (try? GlobalOptions.parse(color)) ?? (try? GlobalOptions.parse([])) {
                    Output(command: "home", options: options).failure(unknown)
                    return unknown.exit.rawValue
                }
            }
            FileHandle.standardError.write(Data((Tincan.fullMessage(for: error) + "\n").utf8))
            return code == .validationFailure ? TincanError.Exit.usage.rawValue : code.rawValue
        }
        let command = commandPath(arguments)
        let message = Tincan.message(for: error).trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = TincanError(
            code: "invalid_arguments",
            message: message.isEmpty ? "The command could not be understood." : TincanError.sentence(message),
            hint: "Run `tincan \(command == "home" ? "" : command + " ")--help` for usage.",
            exit: .usage
        )
        var options = GlobalOptions()
        options.json = true
        Output(command: command, options: options).failure(failure)
        return failure.exit.rawValue
    }

    /// Whether `arguments` ask for JSON, read before ArgumentParser so a command line it
    /// rejects is still reported as JSON: `--json`, or `-j` alone or among other short flags,
    /// as in `-yj`, before any `--`.
    static func asksForJSON(_ arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "--" { return false }
            if argument == "--json" { return true }
            let flags = argument.dropFirst()
            if argument.hasPrefix("-"), !flags.isEmpty, flags.allSatisfy({ $0.isASCII && $0.isLetter }), flags.contains("j") { return true }
        }
        return false
    }

    /// For people who type a word tincan has no command for, such as `tincan chat` or
    /// `tincan Maya`: the command they probably meant, or how to read a conversation.
    /// Nil for every other mistake, which ArgumentParser explains well.
    static func unknownCommand(_ error: Error, arguments: [String]) -> TincanError? {
        guard Tincan.message(for: error).lowercased().contains("unexpected argument") else { return nil }
        let path = commandPath(arguments)
        guard path == "home" else { return unquotedWords(arguments, path: path) }
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--color" {
                index += 2
                continue
            }
            if !arguments[index].hasPrefix("-") { words.append(arguments[index]) }
            index += 1
        }
        guard let word = words.first else { return nil }
        let typed = word.lowercased()
        let names = Tincan.configuration.subcommands.map { $0._commandName }
        let closest = names.map { editDistance($0, typed) }.min() ?? .max
        var close = names.filter { editDistance($0, typed) == closest && closest <= (typed.count > 3 ? 2 : 1) }
        if close.isEmpty, typed.count >= 3 { close = names.filter { $0.hasPrefix(typed) } }
        if close.count == 1, let command = close.first {
            let rest = words.dropFirst().map(shellQuote).joined(separator: " ")
            return TincanError(
                code: "unknown_command",
                message: "\"\(word)\" isn't a tincan command. Did you mean \(command)?",
                hint: "Run `tincan \(command)\(rest.isEmpty ? "" : " " + rest)`, or `tincan --help` for every command.",
                exit: .usage
            )
        }
        if !close.isEmpty {
            return TincanError(
                code: "unknown_command",
                message: "\"\(word)\" isn't a tincan command. Did you mean \(Formatting.list(close).replacingOccurrences(of: " and ", with: " or "))?",
                hint: "`tincan --help` lists every command.",
                exit: .usage
            )
        }
        return TincanError(
            code: "unknown_command",
            message: "\"\(word)\" isn't a tincan command.",
            hint: words.count == 1
                ? "To read a conversation, run `tincan read \(shellQuote(word))`. `tincan --help` lists every command."
                : "Start with a command, such as `tincan read <name>`. `tincan --help` lists every command.",
            exit: .usage
        )
    }

    /// For `tincan who Sam Park`: a name of several words without quotes. The words right
    /// after the command, up to the first option, become one quoted argument.
    static func unquotedWords(_ arguments: [String], path: String) -> TincanError? {
        let names = path.split(separator: " ").map(String.init)
        guard let start = arguments.firstIndex(of: names.last ?? "") else { return nil }
        let rest = arguments[(start + 1)...]
        let words = rest.prefix { !$0.hasPrefix("-") }
        guard words.count > 1, arguments[..<start].allSatisfy({ names.contains($0) }) else { return nil }
        let joined = words.joined(separator: " ")
        let command = (["tincan"] + names + [shellQuote(joined)] + rest.dropFirst(words.count).map(shellQuote)).joined(separator: " ")
        return TincanError(
            code: "invalid_arguments",
            message: "\"\(joined)\" needs quotes to be one argument.",
            hint: "Run `\(command)`.",
            exit: .usage
        )
    }

    /// Edit distance counting a swap of two neighbors as one edit, for suggesting a command.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }

    /// The command named in `arguments`, such as `contacts add`, as JSON envelopes report
    /// it. Before a command is found, unknown words are skipped as option values; after,
    /// the first unknown word is an argument and ends the search.
    static func commandPath(_ arguments: [String]) -> String {
        var command: ParsableCommand.Type = Tincan.self
        var path: [String] = []
        for argument in arguments where !argument.hasPrefix("-") {
            if let next = command.configuration.subcommands.first(where: { $0._commandName == argument }) {
                command = next
                path.append(argument)
            } else if !path.isEmpty {
                break
            }
        }
        if let fallback = command.configuration.defaultSubcommand, !path.isEmpty {
            path.append(fallback._commandName)
        }
        return path.isEmpty ? "home" : path.joined(separator: " ")
    }
}
