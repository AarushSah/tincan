import ArgumentParser
import Foundation
import TincanKit

struct Inbox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What's new: unread messages, or everything since a time or cursor.",
        discussion: """
            Without options, shows unread messages grouped by conversation. With --since or --after, shows every new message across all conversations, plus reactions that arrived in the same span: the most recently active conversation first, and each conversation's messages oldest first. Conversations Messages filed under Unknown Senders or Junk are left out unless you pass --all.

            Assistants: keep the `cursor` from each result (m:<id>) and pass it back with --after to read exactly what arrived in between, with nothing missed or repeated. `next.command` is that command, with the same --limit, --mine and --all. With --after or --since, `truncated` means more is waiting: run `next.command` again. Without them, the cursor is the newest message now, so `next.command` reads what arrives later; `truncated` then means more unread messages than --limit, and a larger --limit shows them.

            A cursor newer than any message moves to the latest one, with a `cursor_ahead` warning: Messages' database may have been reset.

            Examples:
              tincan inbox
              tincan inbox --since 2h
              tincan inbox --after m:184022 --json
              tincan inbox --since today --mine
            """
    )

    @Option(help: ArgumentHelp("Everything after this cursor: the `cursor` of a previous result, such as m:184022.", valueName: "cursor"))
    var after: String?

    @Option(help: "Everything after this time: \(Help.times).")
    var since: String?

    @Flag(name: .customLong("mine"), help: ArgumentHelp(Help.mine))
    var includeMine = false

    @Flag(help: "Include conversations filtered as unknown senders or junk.")
    var all = false

    @Option(name: [.customShort("n"), .long], help: "Maximum number of messages.")
    var limit: Int = 200

    @OptionGroup var global: GlobalOptions

    struct Group: Encodable {
        let chat: String
        let name: String
        let kind: String
        /// Filed under Unknown Senders or Junk; shown only with --all.
        let filtered: Bool?
        let messages: [Payload.Message]
    }

    struct ReactionEvent: Encodable {
        let chat: String?
        let filtered: Bool?
        /// The reacted-to message's GUID, and `m:<id>` when it can be read.
        let target: String
        let targetRef: String?
        let reaction: String
        let emoji: String
        let from: String
        let fromAddress: String?
        let removed: Bool?
        let at: Date
    }

    struct Result: Encodable {
        let cursor: String
        let mode: String
        let conversations: [Group]
        let reactions: [ReactionEvent]?
        let truncated: Bool
    }

    func run() async throws {
        try await runCommand("inbox", options: global) { context in
            try requireLimit(limit)
            if after != nil && since != nil {
                throw TincanError.usage("Use either --after or --since, not both.", hint: "--after continues from a cursor; --since starts from a time.")
            }
            let database = try context.messages()
            let resolver = try context.resolver()
            let ceiling = try database.latestRowID()
            let excluded = database.excludedChatIDs
            let chatsByID = Dictionary(uniqueKeysWithValues: resolver.chats.map { ($0.id, $0) })
            // Left out in the query, so --limit counts only messages that are shown.
            let filtered = Set(resolver.chats.filter(\.isFiltered).map(\.id))
            let hidden = all ? [] : filtered
            var start: Int64?
            if let after {
                let cursor = try parseCursor(after, option: "--after")
                if cursor > ceiling {
                    // Continuing from a cursor past the end would silently skip everything
                    // until new rows passed it.
                    context.output.warn(
                        "cursor_ahead",
                        "\(messageCursor(cursor)) is newer than any message; Messages' database may have been reset. Continuing from the latest message, \(messageCursor(ceiling)). Use --since to catch up by time."
                    )
                }
                start = min(cursor, ceiling)
            } else if let since {
                start = try database.rowID(before: try parseTime(since, option: "--since"))
            }

            var messages: [Message]
            var truncated: Bool
            var truncatedByReactions = false
            var cursor = ceiling
            var reactions: [ReactionEvent]?
            var reactionRows: [(targetGUID: String, reaction: Reaction, removed: Bool, chatID: Int64?, rowID: Int64)]?
            if let start {
                let page = try database.messages(afterRowID: start, through: ceiling, limit: limit + 1, includeFromMe: includeMine, skipping: hidden)
                truncated = page.count > limit
                messages = Array(page.prefix(limit))
                if truncated, let last = messages.last { cursor = last.id }
                var rows = try database.reactionRows(afterRowID: start, limit: 1_000).filter { $0.rowID <= cursor }
                if rows.count == 1_000, let last = rows.last {
                    // More reactions than one page: stop the cursor here so none are skipped.
                    cursor = min(cursor, last.rowID)
                    rows = rows.filter { $0.rowID <= cursor }
                    truncatedByReactions = true
                }
                // Excluded conversations never appear, whatever the database returns.
                rows = rows.filter { row in
                    (row.chatID.map { !excluded.contains($0) && !hidden.contains($0) } ?? true) && (includeMine || row.reaction.from != nil)
                }
                reactionRows = rows
                let targets = try database.rowIDs(guids: rows.map(\.targetGUID))
                reactions = rows.map { row in
                    ReactionEvent(
                        chat: row.chatID.map { "chat:\($0)" },
                        filtered: row.chatID.map(filtered.contains) == true ? true : nil,
                        target: row.targetGUID,
                        targetRef: targets[row.targetGUID].map(messageCursor),
                        reaction: row.reaction.kind.rawValue,
                        emoji: row.reaction.symbol,
                        from: row.reaction.from.map { Payload.person($0, resolver: resolver).name } ?? "me",
                        fromAddress: row.reaction.from.map { Address($0, region: context.region).value },
                        removed: row.removed ? true : nil,
                        at: row.reaction.at
                    )
                }
            } else {
                let page = try database.unreadMessages(limit: limit + 1, skipping: hidden)
                truncated = page.count > limit
                messages = Array(page.suffix(limit))
                if truncated { context.output.warnTruncated(messages.count, "unread message", limit: limit) }
            }
            messages = messages.filter { $0.chatID.map { !excluded.contains($0) } ?? true }
            if truncatedByReactions {
                messages = messages.filter { $0.id <= cursor }
                truncated = true
            }

            var order: [Int64] = []
            var grouped: [Int64: [Message]] = [:]
            for message in messages {
                let chatID = message.chatID ?? -1
                if grouped[chatID] == nil { order.append(chatID) }
                grouped[chatID, default: []].append(message)
            }
            order.sort { (grouped[$0]?.last?.date ?? .distantPast) > (grouped[$1]?.last?.date ?? .distantPast) }
            let groups: [Group] = order.map { chatID in
                let chat = chatsByID[chatID]
                return Group(
                    chat: chat?.reference ?? "unknown",
                    name: chat.map { resolver.title(for: $0) } ?? "Unknown conversation",
                    kind: chat?.kind.rawValue ?? "direct",
                    filtered: chat?.isFiltered == true ? true : nil,
                    messages: (grouped[chatID] ?? []).map { Payload.message($0, resolver: resolver, includeChat: false) }
                )
            }
            // A sender on several cards shows as a bare number; say whose cards it is on.
            context.warnSharedSenders(
                messages.compactMap { $0.isFromMe ? nil : $0.sender } + (reactionRows ?? []).compactMap(\.reaction.from), resolver: resolver)
            context.warnHiddenText(messages)
            // The flags that shape the result carry over, so the next page reads the same way.
            let continuation = "tincan inbox --after \(messageCursor(cursor)) --limit \(limit)" + (includeMine ? " --mine" : "") + (all ? " --all" : "")
            let result = Result(
                cursor: messageCursor(cursor), mode: start == nil ? "unread" : "since", conversations: groups, reactions: reactions, truncated: truncated)
            context.output.result(result, next: Output.Next(cursor: messageCursor(cursor), command: continuation + " --json"))
            guard !context.output.json else { return }

            let style = context.style
            let output = context.output
            // For people: the command that reads what arrives after this, with the page size
            // only when they chose one.
            let later =
                "tincan inbox --after \(messageCursor(cursor))" + (limit == 200 ? "" : " --limit \(limit)") + (includeMine ? " --mine" : "")
                + (all ? " --all" : "")
            if groups.isEmpty && (reactionRows ?? []).isEmpty {
                output.line(style.muted(start == nil ? "No unread messages." : "Nothing new."))
                for line in TextWidth.wrapCommand("Later: " + later, width: min(context.terminal.width, 100)) { output.hint(line) }
                return
            }
            let directory = resolver.directory
            struct Row {
                let prefix: String
                let text: String
                let time: String
                let isEvent: Bool
            }
            let sections = order.enumerated().map { index, chatID -> (group: Group, count: Int, rows: [Row]) in
                let messages = grouped[chatID] ?? []
                let names = SenderNames((chatsByID[chatID]?.participants ?? []) + messages.compactMap(\.sender), directory: directory)
                let rows = messages.suffix(8).map { message -> Row in
                    let sender = message.isFromMe ? "You" : (groups[index].kind == "group" ? names.label(message.sender ?? "") : "")
                    let isEvent = message.event != nil
                    return Row(
                        prefix: sender.isEmpty || isEvent ? "" : TextWidth.truncate(sender, to: 16) + ": ",
                        text: (isEvent ? ConversationRenderer.summary(message, directory: directory) : ConversationRenderer.snippet(message))
                            .replacingOccurrences(of: "\n", with: " "),
                        time: Formatting.relative(message.date),
                        isEvent: isEvent
                    )
                }
                return (groups[index], messages.count, rows)
            }
            // As wide as the content needs, up to the terminal, so times sit near the text.
            let timeWidth = sections.flatMap(\.rows).map { TextWidth.columns($0.time) }.max() ?? 0
            let natural = sections.flatMap(\.rows).map { 2 + TextWidth.columns($0.prefix) + TextWidth.columns($0.text) + 2 + timeWidth }.max() ?? 0
            let width = min(context.terminal.width, 100, max(natural, 60))
            for (index, section) in sections.enumerated() {
                if index > 0 { output.line() }
                let count = Formatting.plural(section.count, start == nil ? "unread message" : "new message")
                let details = section.group.filtered == true ? [count, "filtered"] : [count]
                output.line(Layout.header(section.group.name, details: details, trailing: section.group.chat, width: width, style: style))
                for row in section.rows {
                    let available = max(8, width - 2 - TextWidth.columns(row.prefix) - 2 - timeWidth)
                    let body = TextWidth.fit(row.text, to: available)
                    output.line(
                        "  " + style.muted(row.prefix) + (row.isEvent ? style.italic(style.muted(body)) : body) + "  "
                            + style.muted(TextWidth.padLeft(row.time, to: timeWidth)))
                }
                if section.count > 8 {
                    output.line(style.muted(TextWidth.truncate("  … \(section.count - 8) earlier: tincan read \(section.group.chat)", to: width)))
                }
            }
            if let rows = reactionRows, !rows.isEmpty {
                output.line()
                output.line(style.accent("Reactions"))
                let targets = Dictionary(
                    (try? database.messages(guids: Array(Set(rows.map(\.targetGUID))))).map { $0.map { ($0.guid, $0) } } ?? [],
                    uniquingKeysWith: { first, _ in first })
                let shown = rows.suffix(8)
                let names = SenderNames(shown.compactMap(\.reaction.from), directory: directory)
                let heads = shown.map { row in
                    row.reaction.symbol + " " + TextWidth.truncate(names.label(row.reaction.from), to: 16) + (row.removed ? " (removed)" : "")
                }
                let headWidth = heads.map(TextWidth.columns).max() ?? 0
                for (row, head) in zip(shown, heads) {
                    let quote = targets[row.targetGUID].map { "“" + ConversationRenderer.snippet($0) + "”" } ?? ""
                    let room = width - 2 - headWidth - 2
                    output.line(
                        "  "
                            + (quote.isEmpty || room < 6
                                ? head : TextWidth.padRight(head, to: headWidth) + "  " + style.muted(TextWidth.truncate(quote, to: room))))
                }
                if rows.count > 8 { output.line(style.muted("  … and \(rows.count - 8) more")) }
            }
            output.hint()
            // Unread mode shows the newest unread messages; the cursor only reads what comes later.
            let footer: String
            if !truncated {
                footer = "Later: " + later
            } else if start == nil {
                footer = "More unread than shown: tincan inbox --limit \(limit * 2)\(all ? " --all" : ""), or tincan chats --unread"
            } else {
                footer = "More waiting: " + later
            }
            for line in TextWidth.wrapCommand(footer, width: width) { output.hint(line) }
        }
    }
}
