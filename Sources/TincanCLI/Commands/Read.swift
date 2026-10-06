import ArgumentParser
import Foundation
import TincanKit

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a conversation with a person or group.",
        discussion: """
            A person's iMessage, SMS and RCS threads are merged into one conversation, the way you think of it. Use chat:<id> to read one thread or a group. Reading never marks messages as read.

            When there are earlier messages, tincan shows the command that reads them: --before with the oldest message's reference. --after reads forward from a message, oldest first, and --around shows a message in context, such as a search result. Message references are m:<id>, or just the number. These options also take a message's GUID, such as a reply's `reply_to` or a reaction's `target`. A reaction is not a message: pass the message it reacts to.

            With --json, `next` continues the way you read: backward by default and with --before, forward with --after and --around. `has_more` says there is more that way. `earlier` and `later` hold the command for each direction that has more, whichever way you read. After --since, `earlier` also points before the window when older messages exist, without loading them or making them `next`.

            Examples:
              tincan read Maya
              tincan read +14155550142 --limit 100
              tincan read Maya --before m:184013
              tincan read Maya --after m:184013
              tincan read chat:42 --around m:184013 --limit 10
              tincan read chat:42 --before 2026-09-01
              tincan read Maya --since yesterday --json
            """
    )

    @Argument(help: ArgumentHelp(Help.target, valueName: "who"))
    var who: String

    @Option(
        name: [.customShort("n"), .long],
        help: "Number of messages: the most recent in the range, the first ones with --after, or those around the message with --around.")
    var limit: Int = Self.defaultLimit

    static let defaultLimit = 40

    @Option(
        help: ArgumentHelp(
            "Only messages before this: a message reference from a previous page (m:<id>) or a message GUID, or a time: \(Help.times).",
            valueName: "m:<id>|time"))
    var before: String?

    @Option(
        help: ArgumentHelp(
            "Only messages after this message, oldest first: read forward from a search result or a previous page. m:<id> or a message GUID.",
            valueName: "m:<id>"))
    var after: String?

    @Option(help: ArgumentHelp("The messages around this one: about half before and half after, including it. m:<id> or a message GUID.", valueName: "m:<id>"))
    var around: String?

    @Option(help: ArgumentHelp(Help.since))
    var since: String?

    @Flag(help: "Show message references (m:<id>) in formatted output.")
    var ids = false

    @OptionGroup var global: GlobalOptions

    struct Result: Encodable {
        struct Conversation: Encodable {
            let name: String
            let ref: String
            let kind: String
            let person: Payload.PersonRef?
            let chats: [String]
            let currentServices: [String]
            /// Services on messages in this page, not a claim about the full history.
            let messageServices: [String]
            /// Messages filed the conversation, or one of its threads, under Unknown Senders
            /// or Junk.
            let filtered: Bool?
        }
        let conversation: Conversation
        let messages: [Payload.Message]
        /// Older messages: `--before` the oldest one shown.
        let earlier: Output.Next?
        /// Newer messages: `--after` the newest one shown.
        let later: Output.Next?
    }

    /// Where a page starts.
    enum Anchor {
        /// The newest messages, or the newest before `--before`.
        case latest
        /// The oldest messages after a message.
        case after(Int64)
        /// A message with the ones around it.
        case around(Message)
    }

    func run() async throws {
        try await runCommand("read", options: global) { context in
            try requireLimit(limit)
            if around != nil, before != nil || after != nil || since != nil {
                throw TincanError.usage(
                    "--around can't be combined with --before, --after or --since.", hint: "--around shows the messages on both sides of one message.")
            }
            if after != nil, before != nil || since != nil {
                throw TincanError.usage(
                    "--after can't be combined with --before or --since.",
                    hint: "--after reads forward from one message; --before and --since bound a page that ends with the newest messages.")
            }
            let database = try context.messages()
            let resolver = try context.resolver()
            let target = try context.resolve(who, command: "read")

            /// A message option, checked against what tincan may read: m:<id>, the bare
            /// number, or a message's GUID, such as a reply's `reply_to` or a reaction's
            /// `target`. Nil when `text` is none of them, so --before can take a time.
            func message(_ text: String, option: String, orTime: Bool = false) throws -> Message? {
                let hint =
                    orTime
                    ? "Use the next.cursor from a previous read result, or a time: \(Help.times)."
                    : "Use a message reference (m:<id>) from a previous result."
                if let id = try parseMessageReference(text, option: option, orTime: orTime) {
                    if let message = try database.message(id: id) { return message }
                    if let target = try database.reactionTarget(id: id) { throw try reaction(text, target: target, option: option) }
                    throw TincanError.unknownMessage(text, hint: hint)
                }
                if orTime, TimeExpression.parse(text) != nil { return nil }
                let guid = text.trimmingCharacters(in: .whitespaces)
                if let message = try database.message(guid: guid) { return message }
                if let target = try database.reactionTarget(guid: guid) { throw try reaction(text, target: target, option: option) }
                if UUID(uuidString: guid) != nil { throw TincanError.unknownMessage(text, hint: hint) }
                if orTime { return nil }
                throw TincanError.usage(
                    "\(option) \"\(text)\" is not a message reference.",
                    hint: "Use m:<id> from a previous result, such as m:184022, or a message GUID." + (option == "--after" ? " For a time, use --since." : "")
                )
            }
            /// A reaction named where a message belongs. Reactions are folded onto the
            /// message they react to, so point there.
            func reaction(_ text: String, target: String, option: String) throws -> TincanError {
                let reference = try database.message(guid: target)?.reference
                return TincanError(
                    code: "unknown_message",
                    message: "\(text) is a reaction, not a message.",
                    hint: "Reactions point at the message they react to with `target`"
                        + (reference.map { ": pass \(option) \($0). Run `tincan read \(shellQuote(who)) \(option) \($0)`." } ?? "; pass that message instead."),
                    exit: .needsInput
                )
            }
            var beforeMessage: Int64?
            var beforeDate: Date?
            if let before {
                if let found = try message(before, option: "--before", orTime: true) {
                    beforeMessage = found.id
                } else {
                    beforeDate = try parseTime(before, option: "--before")
                }
            }
            var anchor = Anchor.latest
            if let after, let found = try message(after, option: "--after") { anchor = .after(found.id) }
            if let around, let found = try message(around, option: "--around") { anchor = .around(found) }
            let sinceDate = try since.map { try parseTime($0, option: "--since") }

            let chats: [Chat]
            let name: String
            let ref: String
            var personRef: Payload.PersonRef?
            switch target {
            case .chat(let chat):
                chats = [chat]
                name = resolver.title(for: chat)
                ref = chat.reference
                if chat.kind == .direct {
                    let other = resolver.person(forAddress: chat.participants.first ?? chat.identifier)
                    if other.contact == nil { context.warnSharedAddress(other) }
                }
            case .person(let person):
                chats = resolver.directChats(with: person)
                name = person.name
                ref = person.reference
                personRef = Payload.person(person, region: context.region)
                context.warnSharedAddress(person)
                let excluded = context.excludedDirectChats(with: person)
                if chats.isEmpty {
                    let groups = resolver.groupChats(with: person)
                    if !excluded.isEmpty || !context.excludedAddresses(of: person).isEmpty {
                        throw TincanError.excludedPerson(person, chats: excluded, groups: groups.count)
                    }
                    throw TincanError(
                        code: "no_conversation",
                        message: "You have no one-to-one conversation with \(person.name).",
                        hint: groups.isEmpty
                            ? "There is nothing to read. A first message would start a new conversation; send one only if the person asks."
                            : "They are in \(Formatting.plural(groups.count, "group")): run `tincan chats --with \(shellQuote(person.reference))`.",
                        exit: .needsInput
                    )
                }
                if !excluded.isEmpty {
                    context.output.warn(
                        "excluded_conversations",
                        "\(Formatting.plural(excluded.count, "conversation")) with \(person.name) \(excluded.count == 1 ? "is" : "are") excluded and not shown."
                    )
                }
            }

            let chatIDs = chats.map(\.id)
            // Cursors must come from this conversation; another one's would page by its time
            // and return a confusing empty page.
            var cursors: [Int64] = []
            if let beforeMessage { cursors.append(beforeMessage) }
            if case .after(let id) = anchor { cursors.append(id) }
            for id in cursors {
                guard let message = try database.message(id: id) else { continue }
                guard let chatID = message.chatID, chatIDs.contains(chatID) else {
                    throw TincanError(
                        code: "unknown_message",
                        message: "\(message.reference) isn't in your conversation with \(name).",
                        hint: message.chatID.map { "It is in chat:\($0). Use a message reference from this conversation's results." }
                            ?? "Use a message reference from this conversation's results.",
                        exit: .needsInput
                    )
                }
            }
            var messages: [Message]
            var hasEarlier = false
            var hasLater = false
            /// Older messages exist, but only before the --since window: pointed to, not loaded.
            var olderThanWindow: String?
            switch anchor {
            case .latest:
                let page = try database.messages(inChats: chatIDs, before: beforeDate, after: sinceDate, beforeMessage: beforeMessage, limit: limit + 1)
                hasEarlier = page.count > limit
                messages = Array(page.suffix(limit))
                // Only a page that ends before the present can have newer messages.
                if beforeDate != nil || beforeMessage != nil, let newest = messages.last {
                    hasLater = try !database.messages(inChats: chatIDs, afterMessage: newest.id, limit: 1).isEmpty
                }
                // The whole window fits the page: say where the messages before it start.
                if let sinceDate, !hasEarlier {
                    if let oldest = messages.first {
                        if try !database.messages(inChats: chatIDs, beforeMessage: oldest.id, limit: 1).isEmpty { olderThanWindow = oldest.reference }
                    } else {
                        let end = min(sinceDate, beforeDate ?? sinceDate)
                        if try !database.messages(inChats: chatIDs, before: end, beforeMessage: beforeMessage, limit: 1).isEmpty {
                            olderThanWindow = Formatting.iso(end)
                        }
                    }
                }
            case .after(let id):
                let page = try database.messages(inChats: chatIDs, afterMessage: id, limit: limit + 1)
                hasLater = page.count > limit
                messages = Array(page.prefix(limit))
                if let oldest = messages.first {
                    hasEarlier = try !database.messages(inChats: chatIDs, beforeMessage: oldest.id, limit: 1).isEmpty
                }
            case .around(let center):
                guard let chatID = center.chatID, chatIDs.contains(chatID) else {
                    // The message exists, but showing it here would mix in another conversation.
                    throw TincanError(
                        code: "unknown_message",
                        message: "\(center.reference) isn't in your conversation with \(name).",
                        hint: center.chatID.map { "It is in chat:\($0): run `tincan read chat:\($0) --around \(center.reference)`." }
                            ?? "Use a message reference from this conversation's results.",
                        exit: .needsInput
                    )
                }
                // The message itself, then about half the rest on each side. Near either end of
                // the conversation, the other side fills the page.
                let rest = limit - 1
                let older = try database.messages(inChats: chatIDs, beforeMessage: center.id, limit: rest + 1)
                let newer = try database.messages(inChats: chatIDs, afterMessage: center.id, limit: rest + 1)
                let earlierCount = min(older.count, max(rest / 2, rest - newer.count))
                let laterCount = min(newer.count, rest - earlierCount)
                hasEarlier = older.count > earlierCount
                hasLater = newer.count > laterCount
                messages = older.suffix(earlierCount) + [center] + newer.prefix(laterCount)
            }
            let replyGUIDs = Set(messages.compactMap(\.replyToGUID))
            var quotes: [String: Message] = [:]
            for message in messages where replyGUIDs.contains(message.guid) { quotes[message.guid] = message }
            let missing = replyGUIDs.subtracting(quotes.keys)
            if !missing.isEmpty {
                for message in try database.messages(guids: Array(missing)) { quotes[message.guid] = message }
            }

            let multiThread = chats.count > 1
            let isGroup = chats.count == 1 && chats[0].kind == .group
            let conversation = Result.Conversation(
                name: name,
                ref: ref,
                kind: isGroup ? "group" : "direct",
                person: personRef,
                chats: chats.map(\.reference),
                currentServices: Array(Set(chats.map(\.service.rawValue))).sorted(),
                messageServices: Array(Set(messages.map(\.service.rawValue))).sorted(),
                filtered: chats.contains(where: \.isFiltered) ? true : nil
            )
            context.warnFiltered(chats)
            // A group member on a shared number, or a reaction from one, shows as the bare number.
            context.warnSharedSenders(
                messages.flatMap { message in
                    (message.isFromMe ? [] : [message.sender].compactMap { $0 }) + message.reactions.compactMap(\.from)
                }, resolver: resolver)
            // The commands that read on keep the page size, and earlier pages the --since bound.
            // JSON names the conversation by its reference and people see what they typed;
            // otherwise the commands are the same.
            func pageCommand(_ reference: String, _ cursor: String, forPeople: Bool, window: Bool = true) -> String {
                var command = "tincan read \(shellQuote(reference)) \(cursor)"
                if !forPeople || limit != Self.defaultLimit { command += " --limit \(limit)" }
                if window, cursor.hasPrefix("--before"), case .latest = anchor, let since { command += " --since \(shellQuote(since))" }
                return command + (forPeople ? (ids ? " --ids" : "") : " --json")
            }
            var earlier: Output.Next?
            if hasEarlier, let oldest = messages.first {
                earlier = Output.Next(cursor: oldest.reference, command: pageCommand(ref, "--before \(oldest.reference)", forPeople: false))
            } else if let olderThanWindow {
                // Outside the window asked for, so not `next`: only where to look.
                earlier = Output.Next(
                    cursor: olderThanWindow, command: pageCommand(ref, "--before \(shellQuote(olderThanWindow))", forPeople: false, window: false))
            }
            var later: Output.Next?
            if hasLater, let newest = messages.last {
                later = Output.Next(cursor: newest.reference, command: pageCommand(ref, "--after \(newest.reference)", forPeople: false))
            }
            let next: Output.Next?
            if case .latest = anchor {
                next = olderThanWindow == nil ? earlier : nil
            } else {
                next = later
            }
            context.warnHiddenText(messages)
            context.output.result(
                Result(
                    conversation: conversation,
                    messages: messages.map { Payload.message($0, resolver: resolver, includeChat: multiThread) },
                    earlier: earlier,
                    later: later
                ),
                next: next, hasMore: next != nil
            )
            guard !context.output.json else { return }

            let style = context.style
            let output = context.output
            let width = min(context.terminal.width, 100)
            let services = Array(Set(chats.map(\.service))).sorted { $0.rawValue < $1.rawValue }.map(\.displayName)
            var details = ["Current: " + services.joined(separator: " + ")]
            let messageServices = Array(Set(messages.map(\.service))).sorted { $0.rawValue < $1.rawValue }.map(\.displayName)
            if !messageServices.isEmpty, messageServices != services { details.append("Shown: " + messageServices.joined(separator: " + ")) }
            // The address, unless it is already the title because no card names it.
            if case .person(let person) = target, let address = person.addresses.first, Address(address, region: context.region).formatted != name {
                details.append(Address(address, region: context.region).formatted)
            }
            if isGroup { details.append("\(chats[0].participants.count + 1) people") }
            // A number on several cards names nobody; say who it could be.
            if !isGroup, let address = chats.first.map({ $0.participants.first ?? $0.identifier }) {
                let cards = resolver.directory.matches(for: address).map(\.contact.displayName)
                if cards.count > 1 { details.insert("shared by " + Formatting.list(cards), at: 0) }
            }
            let refs = chats.count == 1 ? chats[0].reference : ref
            output.line(Layout.header(name, details: details, trailing: refs, width: width, style: style))
            output.line(style.muted(String(repeating: "─", count: width)))
            if messages.isEmpty {
                let bounded: Bool
                if case .latest = anchor { bounded = beforeMessage != nil || beforeDate != nil || sinceDate != nil } else { bounded = true }
                output.line(style.muted(bounded ? "No messages in this range." : "No messages yet."))
                if let olderThanWindow {
                    for line in TextWidth.wrapCommand(
                        "Earlier: " + pageCommand(who, "--before \(shellQuote(olderThanWindow))", forPeople: true, window: false), width: width)
                    {
                        output.hint(line)
                    }
                }
                return
            }
            if hasEarlier || olderThanWindow != nil {
                // Within the window, the next page keeps --since; before it, the window ends.
                for line in TextWidth.wrapCommand(
                    "Earlier: " + pageCommand(who, "--before \(messages[0].reference)", forPeople: true, window: hasEarlier), width: width)
                {
                    output.hint(line)
                }
                output.hint()
            }
            var renderer = ConversationRenderer(style: style, width: width, resolver: resolver, isGroup: isGroup, showIDs: ids)
            // Delivery status goes under your newest message in the conversation, as in
            // Messages; with later messages, that one may be on a later page.
            if hasLater, let mine = messages.last(where: ConversationRenderer.showsStatus) {
                renderer.youSentLater = try chatIDs.contains { chatID in
                    let later = try database.latestOutgoing(inChat: chatID, after: mine.date)
                    // Twenty unsent messages or group changes in a row could hide an older one.
                    return later.count >= 20 || later.contains { $0.id != mine.id && ConversationRenderer.showsStatus($0) }
                }
            }
            for line in renderer.render(messages, quotes: quotes) { output.line(line) }
            if hasLater, let newest = messages.last {
                output.hint()
                for line in TextWidth.wrapCommand("Later: " + pageCommand(who, "--after \(newest.reference)", forPeople: true), width: width) {
                    output.hint(line)
                }
            }
        }
    }
}
