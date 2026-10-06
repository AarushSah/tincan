import ArgumentParser
import Foundation
import TincanKit

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change settings.",
        discussion: """
            Settings live in ~/.config/tincan/config.toml. Keys:
              region        Country for numbers without a country code, such as US or GB
              send.wpm      Typing speed for sends, from 5 to 250 words per minute
              send.typing   auto, keyboard, paced or off

            Examples:
              tincan config
              tincan config set send.wpm 55
              tincan config set region GB
              tincan config reset
            """,
        subcommands: [Show.self, Set.self, Path.self, Reset.self],
        defaultSubcommand: Show.self
    )

    struct Values: Encodable {
        let path: String
        let region: String?
        let effectiveRegion: String?
        let sendWpm: Double
        let sendTyping: String
        let excluded: [String]
        /// Entries in `excluded` that are conversations, and people's addresses.
        let excludedConversations: Int
        let excludedAddresses: Int
        /// `address:` entries that are no phone number or email, which exclude nothing, as
        /// `tincan exclude list` shows them.
        var excludedNothing: Int? = nil
    }

    static func values(_ config: Config) -> Values {
        let counts = excludedCounts(config)
        return Values(
            path: Config.defaultPath, region: config.region, effectiveRegion: config.effectiveRegion, sendWpm: config.wordsPerMinute,
            sendTyping: config.typing.rawValue,
            excluded: config.excludedChats, excludedConversations: counts.conversations, excludedAddresses: counts.addresses,
            excludedNothing: counts.nothing > 0 ? counts.nothing : nil
        )
    }

    /// How many exclusions are conversations, how many people's addresses, and how many
    /// `address:` entries exclude nothing because they are no number or email.
    static func excludedCounts(_ config: Config) -> (conversations: Int, addresses: Int, nothing: Int) {
        let entries = config.excludedChats.compactMap { Exclusion.address(in: $0, region: config.effectiveRegion) }
        let nothing = entries.filter { $0.kind == .other }.count
        return (config.excludedChats.count - entries.count, entries.count - nothing, nothing)
    }

    /// "1 conversation and 2 addresses", or nil with no exclusions. `adjective` goes before
    /// each noun: "1 excluded conversation".
    static func excludedSummary(_ config: Config, adjective: String = "") -> String? {
        let counts = excludedCounts(config)
        let prefix = adjective.isEmpty ? "" : adjective + " "
        var parts: [String] = []
        if counts.conversations > 0 { parts.append(Formatting.plural(counts.conversations, prefix + "conversation")) }
        if counts.addresses > 0 { parts.append(Formatting.plural(counts.addresses, prefix + "address", prefix + "addresses")) }
        let summary = parts.isEmpty ? nil : parts.joined(separator: " and ")
        guard counts.nothing > 0 else { return summary }
        let nothing = Formatting.plural(counts.nothing, "entry that excludes nothing", "entries that exclude nothing")
        return summary.map { "\($0), and \(nothing)" } ?? nothing
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the current settings.",
            discussion: """
                Examples:
                  tincan config show
                  tincan config --json
                """
        )
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("config show", options: global) { context in
                let config = try context.config()
                context.output.result(ConfigCommand.values(config))
                guard !context.output.json else { return }
                let style = context.style
                let output = context.output
                output.line(
                    style.muted(TextWidth.truncateMiddle(Config.defaultPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"), to: context.terminal.width))
                )
                let region = config.region.map { $0 } ?? style.muted("\(config.effectiveRegion ?? "none") (from your Mac)")
                output.line("region       " + region)
                output.line("send.wpm     " + Config.formatNumber(config.wordsPerMinute))
                output.line("send.typing  " + config.typing.rawValue)
                let excluded = ConfigCommand.excludedSummary(config).map { $0 + " (tincan exclude list)" } ?? "none"
                output.line("excluded     " + style.muted(excluded))
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a setting: region, send.wpm or send.typing.",
            discussion: """
                Examples:
                  tincan config set region GB
                  tincan config set send.wpm 55
                  tincan config set send.typing paced
                  tincan config set region ""
                """
        )
        @Argument(help: "region, send.wpm or send.typing.") var key: String
        @Argument(help: "The new value. An empty region uses your Mac's.") var value: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("config set", options: global) { context in
                var config = try context.config()
                switch key {
                case "region":
                    let region = value.uppercased()
                    guard region.isEmpty || PhoneRegions.byRegion[region] != nil else {
                        throw TincanError.usage("\"\(value)\" is not a country code tincan knows.", hint: "Use an ISO code such as US, GB, JP or IN.")
                    }
                    config.region = region.isEmpty ? nil : region
                case "send.wpm", "wpm":
                    guard let wpm = Double(value), wpm >= 5, wpm <= 250 else {
                        throw TincanError.usage("send.wpm must be a number from 5 to 250.", hint: "The default is 80 words per minute.")
                    }
                    config.wordsPerMinute = wpm
                case "send.typing", "typing":
                    guard let mode = Config.TypingMode(rawValue: value) else {
                        throw TincanError.usage(
                            "send.typing must be auto, keyboard, paced or off.", hint: "auto shows the typing indicator when it can; see `tincan send --help`.")
                    }
                    config.typing = mode
                default:
                    throw TincanError.usage(
                        "Unknown setting \"\(key)\".", hint: "Settings are region, send.wpm and send.typing. Exclusions use `tincan exclude`.")
                }
                try config.save()
                context.output.result(ConfigCommand.values(config))
                if !context.output.json {
                    let shown = key == "region" && value.isEmpty ? "your Mac's region" : value
                    context.output.line(context.style.success("✓ ") + "\(key) = \(shown)")
                }
            }
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the settings file path.",
            discussion: """
                TINCAN_CONFIG names another file and XDG_CONFIG_HOME moves the folder. When TINCAN_CONFIG names a file that doesn't exist, or XDG_CONFIG_HOME leads to none while ~/.config/tincan/config.toml exists, other commands stop with config_missing rather than run without your exclusions.

                Examples:
                  tincan config path
                """
        )
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("config path", options: global) { context in
                context.output.result(["path": Config.defaultPath])
                context.output.line(Config.defaultPath)
            }
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore default settings. Exclusions are kept unless you pass --all.",
            discussion: """
                --all also clears excluded conversations, so tincan could read and send to them again. In a terminal it asks first. Without one, or with --json, it changes nothing unless you pass --yes; add --yes only after the person asks to clear exclusions.

                Examples:
                  tincan config reset
                  tincan config reset --all
                """
        )
        @Flag(help: "Also clear excluded conversations.") var all = false
        @Flag(
            name: .shortAndLong,
            help: "With --all, clear exclusions without asking. Required when there's no terminal to ask in; add it only after the person asks.")
        var yes = false
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("config reset", options: global) { context in
                var config = Config()
                if all {
                    // A settings path that points nowhere is a mistake, not a file to replace:
                    // writing defaults there would hide the real settings and their exclusions.
                    do {
                        _ = try context.config()
                    } catch let error as ConfigError {
                        throw TincanError.configMissing(error)
                    } catch {
                        // An unreadable file is what --all is for.
                    }
                    // Clearing exclusions is the person's decision, never a way past one.
                    let current = try? context.config()
                    let question: String
                    if let current {
                        question =
                            ConfigCommand.excludedSummary(current, adjective: "excluded").map {
                                "Restore defaults and clear \($0)? tincan could then read and send to them."
                            }
                            ?? "Restore default settings?"
                    } else {
                        question = "The settings file can't be read, so any exclusions in it will be lost. Restore defaults?"
                    }
                    try confirmChange(
                        yes: yes, context: context, preview: {}, question: question,
                        refusal: TincanError(
                            code: "confirmation_required",
                            message: "Clearing exclusions without a terminal needs --yes.",
                            hint: "Exclusions are the person's decision. Only add --yes after they ask to clear them.",
                            exit: .needsInput
                        ))
                } else {
                    // Exclusions survive a reset. If the file can't be read they can't be kept, so
                    // tincan stops rather than silently dropping them.
                    config.excludedChats = try context.config().excludedChats
                }
                try config.save()
                context.output.result(ConfigCommand.values(config))
                if !context.output.json {
                    context.output.line(context.style.success("✓ ") + "Settings restored to defaults" + (all ? "." : "; exclusions kept."))
                }
            }
        }
    }
}
