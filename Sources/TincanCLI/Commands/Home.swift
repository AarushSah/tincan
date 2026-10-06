import Foundation
import TincanKit

/// `tincan` with no command: what needs attention right now.
enum Home {
    struct Result: Encodable {
        let setupNeeded: Bool
        /// Every conversation with unread messages, and their unread messages, not only the
        /// ones listed in `unread`. Absent when setup is needed.
        var unreadConversations: Int? = nil
        var unreadMessages: Int? = nil
        let unread: [Payload.Chat]
        let missedCalls: [Payload.Call]
    }

    /// How many unread conversations home lists.
    static let shown = 5

    static func run(options: GlobalOptions) async throws {
        try await runCommand("home", options: options) { context in
            let style = context.style
            let output = context.output
            guard context.sources.fullDiskAccess() != .denied else {
                output.result(Result(setupNeeded: true, unread: [], missedCalls: []))
                output.line(style.bold("tincan") + style.muted("  your texts, calls and contacts"))
                output.line()
                output.line("tincan needs Full Disk Access\(PermissionHost.current.titleSuffix) before it can read your messages.")
                output.hint("Run `tincan doctor --fix` to set it up. It takes about a minute.")
                return
            }
            let database = try context.messages()
            let resolver = try context.resolver()
            let excluded = database.excludedChatIDs
            // Excluded conversations never appear here, whatever the database counts as unread.
            let everyUnread = try database.chatSummaries(limit: nil, unreadOnly: true).filter { !excluded.contains($0.chat.id) }
            let unread = Array(everyUnread.prefix(Self.shown))
            let unreadMessages = everyUnread.reduce(0) { $0 + $1.unreadCount }
            if everyUnread.count > unread.count {
                output.warn(
                    "truncated", "Showing \(unread.count) of \(everyUnread.count) unread conversations. See them all with `tincan chats --unread`.",
                    printed: false)
            }
            var missed: [Payload.Call] = []
            do {
                let history = try context.calls()
                let calls = try history.calls(since: Date().addingTimeInterval(-7 * 86_400), missedOnly: true)
                let followUps = Calls.followUps(for: calls, history: history, context: context, resolver: resolver)
                // Hidden callers stay: you still missed them, even if they can't be called back.
                missed = calls.filter { followUps[$0.id] == nil && !$0.isJunk }.prefix(5).map { Payload.call($0, resolver: resolver) }
            } catch {
                // Many Macs have no call history; say so to agents without nagging people.
                let failure = TincanError.wrap(error)
                output.warn("calls_unavailable", "Missed calls aren't shown: \(failure.message)", printed: failure.code != "call_history_missing")
            }
            context.warnHiddenText(unread.compactMap(\.lastMessage))
            output.result(
                Result(
                    setupNeeded: false, unreadConversations: everyUnread.count, unreadMessages: unreadMessages,
                    unread: unread.map { Payload.chat($0, resolver: resolver, excluded: false) }, missedCalls: missed
                ))
            guard !output.json else { return }

            let width = min(context.terminal.width, 100)
            output.line(style.bold("tincan") + style.muted("  " + Date().formatted(date: .complete, time: .omitted)))
            output.line()
            if unread.isEmpty {
                output.line(style.muted("No unread messages."))
            } else {
                // Counted over every unread conversation, not only the ones listed.
                output.line(
                    style.accent("Unread")
                        + style.muted("  \(Formatting.plural(unreadMessages, "message")) in \(Formatting.plural(everyUnread.count, "conversation"))"))
                let refWidth = unread.map { TextWidth.columns($0.chat.reference) }.max() ?? 0
                // At least a whole phone number, as in the missed calls below.
                let nameWidth = min(22, max(17, (width - refWidth) / 3), unread.map { TextWidth.columns(resolver.title(for: $0.chat)) }.max() ?? 0)
                let snippets = unread.map { summary -> String in
                    let snippet = summary.lastMessage.map { ConversationRenderer.summary($0, directory: resolver.directory) } ?? ""
                    return summary.unreadCount > 1 ? "(\(summary.unreadCount)) " + snippet : snippet
                }
                // Sized to the longest snippet, so references sit near the text.
                let snippetWidth = max(8, min(snippets.map(TextWidth.columns).max() ?? 0, width - 4 - nameWidth - 2 - 2 - refWidth))
                for (summary, snippet) in zip(unread, snippets) {
                    let name = TextWidth.fit(resolver.title(for: summary.chat), to: nameWidth)
                    output.line(
                        "  " + style.color("●", .imessage) + " " + style.bold(name) + "  "
                            + style.muted(TextWidth.fit(snippet, to: snippetWidth)) + "  " + style.muted(summary.chat.reference))
                }
                if everyUnread.count > unread.count {
                    output.line(style.muted(TextWidth.truncate("  … and \(everyUnread.count - unread.count) more: tincan chats --unread", to: width)))
                }
            }
            if !missed.isEmpty {
                output.line()
                let scope = "  last 7 days, not called or texted back"
                output.line(style.accent("Missed calls") + (12 + TextWidth.columns(scope) <= width ? style.muted(scope) : ""))
                for line in CallsRendering.lines(missed, style: style, width: width, showName: true, indent: 2) { output.line(line) }
            }
            output.hint()
            // Whole commands only: a narrow terminal drops the last ones instead of cutting one.
            let commands = ["tincan read <name>", "tincan send <name> \"…\"", "tincan --help"]
            output.hint(Layout.parts(commands.map { ($0, { $0 }) }, width: width, style: Style(depth: .none), whole: true))
        }
    }
}
