import ArgumentParser
import Foundation
import TincanKit

struct Chats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List conversations, newest first.",
        discussion: """
            Shows each conversation's reference (chat:<id>), who is in it, the latest message and unread count. Conversations Messages filed under Unknown Senders or Junk are hidden unless you pass --all. Excluded conversations are listed without their messages. Continue with --before chat:<id> from the last result; in JSON, has_more and next.command say whether and how to continue. The list reflects current activity, so conversations can move between pages when new messages arrive.

            Examples:
              tincan chats
              tincan chats --unread
              tincan chats --with "Maya Chen"
              tincan chats --limit 50 --json
            """
    )

    @Option(name: [.customShort("n"), .long], help: "Number of conversations to show.")
    var limit: Int = 20

    @Flag(help: "Only conversations with unread messages.")
    var unread = false

    @Option(
        help: ArgumentHelp(
            "Only conversations with this person: a name, phone number, email, address:<address>, contact:<id>, or `me` for yourself.", valueName: "who"))
    var with: String?

    @Flag(help: "Include conversations filtered as unknown senders or junk.")
    var all = false

    @Option(help: "Continue after this conversation in the current list. Copy chat:<id> from next.cursor.")
    var before: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runCommand("chats", options: global) { context in
            try requireLimit(limit)
            let messages = try context.messages()
            let resolver = try context.resolver()
            let excluded = messages.excludedChatIDs
            var chatIDs: Set<Int64>?
            if let with {
                switch try context.resolve(with, command: "chats --with") {
                case .person(let person):
                    chatIDs = Set((resolver.directChats(with: person) + resolver.groupChats(with: person)).map(\.id))
                    context.warnSharedAddress(person)
                    context.warnExcludedConversations(with: person)
                case .chat(let chat):
                    chatIDs = [chat.id]
                }
            }
            var beforeChat: Int64?
            if let before {
                guard before.hasPrefix("chat:"), let id = Int64(before.dropFirst(5)), id > 0 else {
                    throw TincanError.usage("--before needs a conversation reference.", hint: "Copy chat:<id> from next.cursor in a chats result.")
                }
                beforeChat = id
            }
            var summaries: [ChatSummary]
            do {
                summaries = try messages.chatSummaries(limit: limit + 1, unreadOnly: unread, includeFiltered: all, chatIDs: chatIDs, beforeChat: beforeChat)
            } catch MessagesDatabase.ChatCursorError.notInResults {
                throw TincanError.usage("That conversation is no longer in this list.", hint: "Run tincan chats again with the same filters, without --before.")
            }
            let truncated = summaries.count > limit
            summaries = Array(summaries.prefix(limit))
            let next =
                truncated
                ? summaries.last.map {
                    Output.Next(cursor: $0.chat.reference, command: pageCommand($0.chat.reference) + " --json")
                } : nil
            if truncated { context.output.warnTruncated(summaries.count, "conversation", limit: limit, pages: true) }
            context.warnHiddenText(summaries.filter { !excluded.contains($0.chat.id) }.compactMap(\.lastMessage))
            context.output.result(
                summaries.map { Payload.chat($0, resolver: resolver, excluded: excluded.contains($0.chat.id)) }, next: next, hasMore: truncated)
            guard !context.output.json else { return }
            render(summaries, truncated: truncated, context: context, resolver: resolver, excluded: excluded)
        }
    }

    private func render(_ summaries: [ChatSummary], truncated: Bool, context: Context, resolver: Resolver, excluded: Set<Int64>) {
        let style = context.style
        let output = context.output
        guard !summaries.isEmpty else {
            output.line(style.muted(unread ? "No unread conversations." : with != nil ? "No conversations with \(with ?? "them")." : "No conversations yet."))
            return
        }
        let width = min(context.terminal.width, 120)
        let titles = summaries.map { title($0, resolver) }
        let times = summaries.map { $0.lastActivity.map { Formatting.relative($0) } ?? "" }
        let refWidth = summaries.map { TextWidth.columns($0.chat.reference) }.max() ?? 7
        let timeWidth = times.map(TextWidth.columns).max() ?? 0
        let widest = titles.map(TextWidth.columns).max() ?? 12
        // A narrow terminal drops the time, then the snippet, rather than cut names below 10
        // columns; the list is newest first either way.
        let fewest = min(10, widest) + 8
        let showTime = width - (2 + 2 + 2 + timeWidth + 2 + refWidth) >= fewest
        let showSnippet = showTime || width - (2 + 2 + 2 + refWidth) >= fewest
        let fixed = 2 + (showSnippet ? 2 : 0) + (showTime ? 2 + timeWidth : 0) + 2 + refWidth
        // Names take up to 26 columns, and more on a wide terminal once snippets have their 60.
        // A whole phone number (17 columns) when snippets still keep 12.
        let floor = min(17, widest, max(10, width - fixed - 12))
        let nameWidth =
            showSnippet
            ? min(widest, max(min(26, max(floor, (width - fixed) * 2 / 5)), min(40, width - fixed - 60)))
            : max(1, min(widest, width - fixed))
        // At most the room left, and no wider than the longest snippet needs.
        let snippetWidth = max(8, min(width - fixed - nameWidth, 60))
        // Several threads with one person: say which address each uses.
        let repeated = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys
        for (index, summary) in summaries.enumerated() {
            let chat = summary.chat
            let isExcluded = excluded.contains(chat.id)
            let unreadCount = isExcluded ? 0 : summary.unreadCount
            let dot = unreadCount > 0 ? style.color("●", .imessage) : " "
            let name = TextWidth.fit(titles[index], to: nameWidth)
            var snippet = ""
            if isExcluded {
                snippet = "excluded"
            } else if let last = summary.lastMessage {
                if last.isFromMe {
                    snippet = "You: "
                } else if chat.kind == .group, let sender = last.sender {
                    snippet = SenderNames(chat.participants, directory: resolver.directory).label(sender) + ": "
                }
                snippet += ConversationRenderer.summary(last, directory: resolver.directory)
            }
            if unreadCount > 1 { snippet = "(\(unreadCount)) " + snippet }
            var badges: [Layout.Part] = []
            if chat.isFiltered { badges.append(("junk", style.muted)) }
            if chat.service != .iMessage { badges.append((chat.service.displayName, { style.color($0, .sms) })) }
            if chat.kind == .direct, repeated.contains(titles[index]) {
                badges.append((Address(chat.participants.first ?? chat.identifier, region: context.region).formatted, style.muted))
            }
            let badge = Layout.parts(badges, width: snippetWidth / 2, style: style, whole: true)
            let badgeWidth = TextWidth.columns(badge)
            let text = TextWidth.truncate(snippet, to: snippetWidth - (badgeWidth > 0 ? badgeWidth + 2 : 0))
            let styled = isExcluded ? style.italic(style.muted(text)) : style.muted(text)
            let snippetCell = TextWidth.padRight(styled, to: snippetWidth - badgeWidth) + badge
            let nameCell = unreadCount > 0 ? style.bold(name) : name
            var line = "\(dot) \(nameCell)"
            if showSnippet { line += "  " + snippetCell }
            if showTime { line += "  " + style.muted(TextWidth.padLeft(times[index], to: timeWidth)) }
            output.line(line + "  " + style.muted(chat.reference))
        }
        if truncated, let last = summaries.last {
            output.hint("More: " + pageCommand(last.chat.reference))
        }
    }

    /// Continue the list with the same page size and filters.
    func pageCommand(_ cursor: String) -> String {
        var command = "tincan chats --before \(cursor) --limit \(limit)"
        if unread { command += " --unread" }
        if let with { command += " --with \(shellQuote(with))" }
        if all { command += " --all" }
        return command
    }

    private func title(_ summary: ChatSummary, _ resolver: Resolver) -> String {
        let chat = summary.chat
        let name = resolver.title(for: chat)
        return chat.kind == .group && chat.displayName != nil ? "\(name) (\(chat.participants.count + 1))" : name
    }
}
