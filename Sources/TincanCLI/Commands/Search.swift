import ArgumentParser
import Foundation
import TincanKit

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search the text of your messages.",
        discussion: """
            Matches message text, ignoring case and accents, newest first. Curly and straight quotes and apostrophes match each other, as do dashes and hyphens, and … and three dots. Conversations Messages filed under Unknown Senders or Junk are left out unless you pass --all, or name them with --in or --from. To find a person rather than words they wrote, use `tincan who <name>`. With --json, `has_more` and `next.command` say whether and how to continue.

            Examples:
              tincan search "dinner reservation"
              tincan search tickets --in Maya
              tincan search flight --from me --since 30d
              tincan search "see you" --limit 5 --json
            """
    )

    @Argument(help: "Words to find.")
    var query: String

    @Option(
        help: ArgumentHelp(
            "Only this conversation or person: a name, phone number, email, address:<address>, contact:<id>, chat:<id>, or `me` for yourself.",
            valueName: "who"))
    var `in`: String?

    @Option(
        help: ArgumentHelp(
            "Only messages from this person, or `me` for your own: a name, phone number, email, address:<address> or contact:<id>.", valueName: "who"))
    var from: String?

    @Option(help: ArgumentHelp(Help.since))
    var since: String?

    @Option(
        help: ArgumentHelp(
            "Only matches older than this message (m:<id>, from a previous page's next.cursor) or time: \(Help.times).", valueName: "m:<id>|time"))
    var before: String?

    @Option(name: [.customShort("n"), .long], help: "Maximum number of results.")
    var limit: Int = 20

    @Flag(help: "Include conversations filtered as unknown senders or junk.")
    var all = false

    @OptionGroup var global: GlobalOptions

    struct Match: Encodable {
        let chat: String?
        let chatName: String
        /// Filed under Unknown Senders or Junk.
        let filtered: Bool?
        let message: Payload.Message
    }

    func run() async throws {
        try await runCommand("search", options: global) { context in
            try requireLimit(limit)
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw TincanError.usage("Search for at least one character.", hint: "For example: `tincan search \"dinner\"`.")
            }
            let database = try context.messages()
            let resolver = try context.resolver()
            var chatIDs: [Int64]?
            if let scope = `in` {
                switch try context.resolve(scope, command: "search --in") {
                case .chat(let chat):
                    chatIDs = [chat.id]
                    context.warnFiltered([chat])
                case .person(let person):
                    let chats = resolver.directChats(with: person) + resolver.groupChats(with: person)
                    chatIDs = chats.map(\.id)
                    context.warnFiltered(chats)
                    context.warnSharedAddress(person)
                    context.warnExcludedConversations(with: person, "not searched")
                }
            }
            var fromMe: Bool?
            var senders: Set<String>?
            if let from {
                if from.lowercased() == "me" {
                    fromMe = true
                } else {
                    fromMe = false
                    switch try context.resolve(from, command: "search --from") {
                    case .person(let person):
                        context.warnSharedAddress(person)
                        context.warnExcludedConversations(with: person, "not searched")
                        let wanted = resolver.canonicalAddresses(of: person)
                        senders = Set(resolver.knownAddresses.filter { wanted.contains(Address($0, region: context.region).value) })
                    case .chat:
                        throw TincanError.usage("--from takes a person, not a conversation.", hint: "Use --in for a conversation.")
                    }
                }
            }
            var beforeDate: Date?
            var beforeMessage: Int64?
            if let before {
                if let id = try parseMessageReference(before, option: "--before", orTime: true) {
                    guard try database.message(id: id) != nil else {
                        throw TincanError.unknownMessage(before, hint: "Use the next.cursor from a previous search result, or a time such as 2026-09-01.")
                    }
                    beforeMessage = id
                } else {
                    beforeDate = try parseTime(before, option: "--before")
                }
            }
            // Unknown senders and junk only when asked for, or named with --in or --from.
            let named = chatIDs != nil || senders != nil
            let hidden = all || named ? [] : Set(resolver.chats.filter(\.isFiltered).map(\.id))
            var results = try database.search(
                query,
                inChats: chatIDs,
                fromMeOnly: fromMe,
                senders: senders,
                after: try since.map { try parseTime($0, option: "--since") },
                before: beforeDate,
                beforeMessage: beforeMessage,
                skipping: hidden,
                limit: limit + 1
            )
            let excluded = database.excludedChatIDs
            results = results.filter { $0.chatID.map { !excluded.contains($0) } ?? true }
            let truncated = results.count > limit
            results = Array(results.prefix(limit))
            if truncated { context.output.warnTruncated(results.count, "match", limit: limit, pages: true) }
            context.warnSharedSenders(results.compactMap { $0.isFromMe ? nil : $0.sender }, resolver: resolver)
            context.warnHiddenText(results)
            let chatsByID = Dictionary(uniqueKeysWithValues: resolver.chats.map { ($0.id, $0) })
            // Newest first, as the database found them.
            let matches = results.map { message in
                let chat = message.chatID.flatMap { chatsByID[$0] }
                return Match(
                    chat: message.chatID.map { "chat:\($0)" },
                    chatName: chat.map { resolver.title(for: $0) } ?? "Unknown conversation",
                    filtered: chat?.isFiltered == true ? true : nil,
                    message: Payload.message(message, resolver: resolver, includeChat: false)
                )
            }
            var next: Output.Next?
            if truncated, let oldest = results.last {
                var command = ["tincan", "search", shellQuote(query), "--before", oldest.reference, "--limit", String(limit), "--json"]
                if let scope = `in` { command += ["--in", shellQuote(scope)] }
                if let from { command += ["--from", shellQuote(from)] }
                if let since { command += ["--since", shellQuote(since)] }
                if all { command.append("--all") }
                next = Output.Next(cursor: oldest.reference, command: command.joined(separator: " "))
            }
            context.output.result(matches, next: next, hasMore: truncated)
            guard !context.output.json else { return }

            let style = context.style
            let output = context.output
            if matches.isEmpty {
                output.line(style.muted("No messages contain “\(query)”."))
                let narrowing = [(`in` != nil, "--in"), (from != nil, "--from"), (since != nil, "--since"), (before != nil, "--before")].filter(\.0).map(\.1)
                let next =
                    !narrowing.isEmpty
                    ? "Try fewer words, or search without \(Formatting.list(narrowing).replacingOccurrences(of: " and ", with: " or "))."
                    : all ? "Try fewer or different words." : "Try fewer words, or --all to include Unknown Senders and Junk."
                for line in TextWidth.wrap(next, width: min(context.terminal.width, 110)) { output.hint(line) }
                return
            }
            let width = min(context.terminal.width, 110)
            let nameWidth = min(22, max(8, width / 4), matches.map { TextWidth.columns($0.chatName) }.max() ?? 10)
            for match in matches {
                // In a one-to-one conversation the name column already says who wrote it.
                let from = match.message.from == "me" ? "You" : match.message.from
                let prefix = from == match.chatName ? "" : TextWidth.truncate(from, to: 18) + ": "
                let text = ConversationRenderer.revealed(match.message.text ?? "").replacingOccurrences(of: "\n", with: " ")
                let available = max(8, width - nameWidth - 2 - TextWidth.columns(prefix))
                let snippet = highlight(Self.window(text, around: query, width: available), query: query, style: style)
                output.line(TextWidth.fit(match.chatName, to: nameWidth) + "  " + style.muted(prefix) + snippet)
                let meta = "\(Formatting.relative(match.message.at)) · \(match.chat ?? "") · m:\(match.message.id)"
                output.line(String(repeating: " ", count: nameWidth + 2) + style.muted(TextWidth.truncate(meta, to: width - nameWidth - 2)))
            }
            if truncated { output.hint("More with --limit \(limit * 2).") }
        }
    }

    /// A slice of `text` of at most `width` columns that contains the first match.
    static func window(_ text: String, around query: String, width: Int) -> String {
        guard TextWidth.columns(text) > width,
            let range = TextFolding.range(of: query, in: text)
        else {
            return TextWidth.truncate(text, to: width)
        }
        let before = text.distance(from: text.startIndex, to: range.lowerBound)
        let start = text.index(text.startIndex, offsetBy: max(0, before - width / 3))
        let slice = String(text[start...])
        return start > text.startIndex ? "…" + TextWidth.truncate(slice, to: width - 1) : TextWidth.truncate(slice, to: width)
    }

    private func highlight(_ text: String, query: String, style: Style) -> String {
        guard style.enabled, let range = TextFolding.range(of: query, in: text) else { return text }
        return String(text[..<range.lowerBound]) + style.bold(style.accent(String(text[range]))) + String(text[range.upperBound...])
    }
}
