import ArgumentParser
import Foundation
import TincanKit

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream new messages as they arrive.",
        discussion: """
            Starts from now, or from a cursor (m:<id>) with --after, and prints each new message and reaction in the order Messages recorded them. Conversations Messages filed under Unknown Senders or Junk are left out unless you pass --all, or name them with --in or --from. With --json it prints one JSON object per line (JSON Lines), the only command that streams. Every line carries a cursor; pass the last one you handled back with --after to resume without missing anything. Stop with Ctrl-C.

            --batch groups a conversation's messages into one event when each was sent within that many seconds of the one before, by the messages' own times, so catching up on a backlog batches the same way as watching live. A batch prints once that many seconds pass with nothing new, and nothing after it prints first, so a reaction never comes before the message it reacts to. While a batch waits, cursors stay before it, so a resume can repeat a message from a burst that overlapped another conversation's; skip message ids you have already handled.

            A cursor newer than any message moves to the latest one, and the `ready` line carries a `cursor_ahead` warning: Messages' database may have been reset.

            Examples:
              tincan watch
              tincan watch --in Maya --json
              tincan watch --json --batch 20 --after m:184022
              tincan watch --from me
            """
    )

    @Option(
        help: ArgumentHelp(
            "Only this conversation, or a person's conversations, including ones that start while watching: a name, phone number, email, address:<address>, contact:<id>, chat:<id>, or `me` for yourself.",
            valueName: "who"))
    var `in`: String?

    @Option(
        help: ArgumentHelp(
            "Only messages and reactions from this person, or `me` for your own: a name, phone number, email, address:<address> or contact:<id>.",
            valueName: "who"))
    var from: String?

    @Flag(
        name: .customLong("mine"),
        help: ArgumentHelp("Include messages and reactions you send. Not with --from <person>: use --in <person> --mine for both sides."))
    var includeMine = false

    @Option(help: ArgumentHelp("Start after this cursor instead of now: the `cursor` of a line you handled, such as m:184022.", valueName: "cursor"))
    var after: String?

    @Flag(help: "Include conversations filtered as unknown senders or junk.")
    var all = false

    @Option(help: ArgumentHelp("Group a conversation's messages sent within this many seconds of each other.", valueName: "seconds"))
    var batch: Double?

    @Option(help: ArgumentHelp("Seconds between checks, from 0.2 to 3600.", valueName: "seconds"))
    var interval: Double = 1

    @OptionGroup var global: GlobalOptions

    struct MessageEvent: Encodable {
        let type = "message"
        let cursor: String
        let chat: String?
        let chatName: String
        /// Filed under Unknown Senders or Junk.
        let filtered: Bool?
        let message: Payload.Message
        /// `shared_address` when the sender's number is on several cards.
        var warnings: [Notice]? = nil
    }

    struct BatchEvent: Encodable {
        let type = "batch"
        let cursor: String
        let chat: String?
        let chatName: String
        let filtered: Bool?
        let messages: [Payload.Message]
        var warnings: [Notice]? = nil
    }

    struct ReactionEvent: Encodable {
        let type = "reaction"
        let cursor: String
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
        var warnings: [Notice]? = nil
    }

    struct ReadyEvent: Encodable {
        let type = "ready"
        let cursor: String
        /// What limits the stream: a cursor newer than any message (`cursor_ahead`), or a
        /// sender whose number is on several cards (`shared_address`).
        var warnings: [Notice]? = nil
    }

    typealias ReactionRow = (targetGUID: String, reaction: Reaction, removed: Bool, chatID: Int64?, rowID: Int64)

    /// A message, batch or reaction waiting to print. Events print in the order of their first
    /// row, so nothing appears before a message that Messages recorded earlier.
    struct Pending {
        let chatID: Int64?
        var messages: [Message] = []
        var reaction: ReactionRow?
        /// The row of the message `reaction` targets, when it can be read.
        var targetID: Int64? = nil
        let firstRow: Int64
        var lastRow: Int64
        /// A batch that may still take messages. Nothing behind it prints until it closes.
        var open = false
        /// When the batch's latest message was read, so a sender's skewed clock can't hold it open.
        var lastSeen = Date()
    }

    /// How many rows one check reads at most; the rest wait for the next check.
    static let window = 1_000

    func run() async throws {
        try await runCommand("watch", options: global) { context in
            guard (0.2...3600).contains(interval) else {
                throw TincanError.usage("--interval must be from 0.2 to 3600 seconds.", hint: "The default checks every second.")
            }
            if let batch, !(batch > 0 && batch.isFinite) {
                throw TincanError.usage("--batch must be a number of seconds more than 0.", hint: "For example: --batch 20")
            }
            let database = try context.messages()
            var resolver = try context.resolver()
            let region = context.region
            var chatFilter: Set<Int64>?
            var senderFilter: Set<String>?
            var onlyMine = false
            /// The people --in and --from name. Their conversations and addresses are found
            /// again when new ones appear, such as a first SMS thread or a new group.
            var scopePerson: Person?
            var fromPerson: Person?
            if let scope = `in` {
                switch try context.resolve(scope, command: "watch --in") {
                case .chat(let chat):
                    chatFilter = [chat.id]
                    context.warnFiltered([chat])
                case .person(let person):
                    scopePerson = person
                    chatFilter = Self.conversations(with: person, resolver: resolver)
                    context.warnFiltered(resolver.directChats(with: person) + resolver.groupChats(with: person))
                    context.warnSharedAddress(person)
                    context.warnExcludedConversations(with: person, "not watched")
                }
            }
            if let from {
                if from.lowercased() == "me" {
                    onlyMine = true
                } else {
                    guard case .person(let person) = try context.resolve(from, command: "watch --from") else {
                        throw TincanError.usage("--from takes a person, not a conversation.", hint: "Use --in for a conversation.")
                    }
                    if includeMine {
                        throw TincanError.usage(
                            "--mine can't be combined with --from \(from); --from shows only their messages.",
                            hint: "To follow both sides of a conversation, use --in \(shellQuote(from)) --mine."
                        )
                    }
                    fromPerson = person
                    senderFilter = resolver.canonicalAddresses(of: person)
                    context.warnSharedAddress(person)
                    context.warnExcludedConversations(with: person, "not watched")
                }
            }
            let includeMine = self.includeMine || onlyMine
            /// Conversations under Unknown Senders or Junk, left out unless asked for by --all or
            /// by naming them. Found again as new conversations appear.
            var filtered = Set(resolver.chats.filter(\.isFiltered).map(\.id))
            let showFiltered = all || scopePerson != nil || chatFilter != nil || fromPerson != nil

            /// Whether a message or reaction passes the filters. `sender` is nil for you.
            func wanted(chatID: Int64?, sender: String?, isFromMe: Bool) -> Bool {
                if let chatID, database.excludedChatIDs.contains(chatID) { return false }
                if !showFiltered, let chatID, filtered.contains(chatID) { return false }
                if let chatFilter, !(chatID.map(chatFilter.contains) ?? false) { return false }
                if isFromMe { return includeMine && senderFilter == nil }
                if onlyMine { return false }
                if let senderFilter {
                    guard let sender, senderFilter.contains(Address(sender, region: region).value) else { return false }
                }
                return true
            }

            var scanned = try database.latestRowID()
            var warnings: [Notice] = []
            if let after {
                let cursor = try parseCursor(after, option: "--after")
                if cursor > scanned {
                    // Waiting for rows past the end would print nothing until the database caught up.
                    warnings.append(
                        Notice(
                            code: "cursor_ahead",
                            message:
                                "\(messageCursor(cursor)) is newer than any message; Messages' database may have been reset. Continuing from the latest message, \(messageCursor(scanned))."
                        ))
                } else {
                    scanned = cursor
                }
            }
            /// Events in row order, waiting for the front to be ready.
            var queue: [Pending] = []
            /// The highest row printed so far, or the start.
            var printed = scanned
            // The day of the last line printed. Catching up across days prints a heading at each
            // new day, as `read` does; watching live today prints none.
            var shownDay: Date?
            /// Senders whose `shared_address` warning human output has considered, so it prints once.
            var warnedSenders = Set<String>()

            let output = context.output
            if output.json {
                let readyWarnings = warnings + output.notices
                output.streamLine(ReadyEvent(cursor: messageCursor(scanned), warnings: readyWarnings.isEmpty ? nil : readyWarnings))
            } else {
                for warning in warnings { Self.printWarning(warning.message, context: context) }
                output.status(context.style.muted("Watching for new messages… (Ctrl-C to stop)"))
                output.flushWarnings()
            }

            var knownChats = Set(resolver.chats.map(\.id))
            while !Task.isCancelled {
                let latest = try database.latestRowID()
                var caughtUp = true
                if latest > scanned {
                    // A new conversation on an excluded person's address is excluded before
                    // any of its messages are read.
                    try database.refreshExclusions()
                    var messages = try database.messages(afterRowID: scanned, through: latest, limit: Self.window, includeFromMe: includeMine)
                    var reactions = try database.reactionRows(afterRowID: scanned, limit: Self.window)
                    // New conversations and new handles appear while watching. A reaction can be
                    // the first sign of one, when your own message started it.
                    func isNew(_ chatID: Int64?) -> Bool { chatID.map { !knownChats.contains($0) } ?? false }
                    if messages.contains(where: { isNew($0.chatID) || (!$0.isFromMe && $0.sender == nil) }) || reactions.contains(where: { isNew($0.chatID) }) {
                        database.invalidateCaches()
                        messages = try database.messages(afterRowID: scanned, through: latest, limit: Self.window, includeFromMe: includeMine)
                        reactions = try database.reactionRows(afterRowID: scanned, limit: Self.window)
                        resolver = Resolver(
                            directory: resolver.directory, chats: try database.allChats(),
                            handles: try database.handles().values.sorted { $0.rowID < $1.rowID }, excludedChatIDs: database.excludedChatIDs)
                        knownChats = Set(resolver.chats.map(\.id))
                        filtered = Set(resolver.chats.filter(\.isFiltered).map(\.id))
                        // A person's new thread or group belongs to the stream as much as the old ones.
                        if let person = scopePerson.map({ Self.refreshed($0, resolver: resolver) }) {
                            scopePerson = person
                            chatFilter = Self.conversations(with: person, resolver: resolver)
                        }
                        if let person = fromPerson.map({ Self.refreshed($0, resolver: resolver) }) {
                            fromPerson = person
                            senderFilter = resolver.canonicalAddresses(of: person)
                        }
                    }
                    // Stop where either list was cut off, so the next check picks up the rest.
                    var reached = latest
                    if messages.count == Self.window, let last = messages.last { reached = min(reached, last.id) }
                    if reactions.count == Self.window, let last = reactions.last { reached = min(reached, last.rowID) }
                    messages = messages.filter { $0.id <= reached }
                    reactions = reactions.filter { $0.rowID <= reached }

                    let targets = try database.rowIDs(guids: reactions.map(\.targetGUID))
                    // Messages and reactions in the order Messages recorded them.
                    var events: [(row: Int64, message: Message?, reaction: ReactionRow?)] = messages.map { ($0.id, $0, nil) }
                    events += reactions.map { ($0.rowID, nil, $0) }
                    events.sort { $0.row < $1.row }
                    for event in events {
                        if let message = event.message {
                            guard wanted(chatID: message.chatID, sender: message.sender, isFromMe: message.isFromMe) else { continue }
                            guard let batch else {
                                queue.append(Pending(chatID: message.chatID, messages: [message], firstRow: event.row, lastRow: event.row))
                                continue
                            }
                            // A message joins its conversation's open batch when it was sent within
                            // `batch` seconds of the batch's latest message. Otherwise that batch is done.
                            if let index = queue.lastIndex(where: { $0.open && $0.chatID == message.chatID }) {
                                if let previous = queue[index].messages.last, abs(message.date.timeIntervalSince(previous.date)) <= batch {
                                    queue[index].messages.append(message)
                                    queue[index].lastRow = event.row
                                    queue[index].lastSeen = Date()
                                    continue
                                }
                                queue[index].open = false
                            }
                            queue.append(Pending(chatID: message.chatID, messages: [message], firstRow: event.row, lastRow: event.row, open: true))
                        } else if let row = event.reaction {
                            guard wanted(chatID: row.chatID, sender: row.reaction.from, isFromMe: row.reaction.from == nil) else { continue }
                            queue.append(Pending(chatID: row.chatID, reaction: row, targetID: targets[row.targetGUID], firstRow: event.row, lastRow: event.row))
                        }
                    }
                    scanned = reached
                    caughtUp = reached >= latest
                }
                if let batch, caughtUp {
                    // A batch closes once `batch` seconds pass after its latest message: by that
                    // message's time, or by when tincan read it if the sender's clock runs ahead.
                    let now = Date()
                    for index in queue.indices where queue[index].open {
                        let latestDate = queue[index].messages.last?.date ?? now
                        if now.timeIntervalSince(min(latestDate, queue[index].lastSeen)) >= batch { queue[index].open = false }
                    }
                }
                if !queue.isEmpty {
                    let chatsByID = Dictionary(uniqueKeysWithValues: resolver.chats.map { ($0.id, $0) })
                    while let first = queue.first, !first.open {
                        queue.removeFirst()
                        printed = max(printed, first.lastRow)
                        // Every row at or below the cursor has printed; batches still waiting keep it below them.
                        let cursor = messageCursor(min(printed, (queue.first?.firstRow ?? .max) - 1))
                        if !context.output.json, let date = first.reaction?.reaction.at ?? first.messages.first?.date {
                            let day = Calendar.current.startOfDay(for: date)
                            if day != shownDay, shownDay != nil || !Calendar.current.isDateInToday(date) {
                                if shownDay != nil { context.output.line() }
                                context.output.line(context.style.muted(Formatting.dayHeading(date)))
                            }
                            shownDay = day
                        }
                        if !context.output.json {
                            // JSON events carry these in `warnings`; people see each once, before the first event it concerns.
                            let senders = first.reaction.map { [$0.reaction.from] } ?? first.messages.map { $0.isFromMe ? nil : $0.sender }
                            let unwarned = senders.compactMap { $0 }.filter { warnedSenders.insert(Address($0, region: context.region).value).inserted }
                            for notice in context.sharedSenderNotices(unwarned, resolver: resolver) ?? [] {
                                Self.printWarning(notice.message, context: context)
                            }
                        }
                        if let row = first.reaction {
                            emitReaction(row, targetID: first.targetID, cursor: cursor, chatsByID: chatsByID, resolver: resolver, context: context)
                        } else if batch != nil {
                            emitBatch(first.messages, chatID: first.chatID, cursor: cursor, chatsByID: chatsByID, resolver: resolver, context: context)
                        } else if let message = first.messages.first {
                            emit(message, cursor: cursor, chatsByID: chatsByID, resolver: resolver, context: context)
                        }
                    }
                }
                // A backlog longer than one read continues at once.
                if !caughtUp { continue }
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// A person's one-to-one and group conversations, as `--in` follows them.
    static func conversations(with person: Person, resolver: Resolver) -> Set<Int64> {
        Set((resolver.directChats(with: person) + resolver.groupChats(with: person)).map(\.id))
    }

    /// `person` as `resolver` knows them now: a card gains addresses Messages started using.
    static func refreshed(_ person: Person, resolver: Resolver) -> Person {
        guard let contact = person.contact else { return person }
        return resolver.person(for: contact)
    }

    // MARK: Output

    private func emit(_ message: Message, cursor: String, chatsByID: [Int64: Chat], resolver: Resolver, context: Context) {
        let chat = message.chatID.flatMap { chatsByID[$0] }
        let name = chat.map { resolver.title(for: $0) } ?? "Unknown conversation"
        if context.output.json {
            context.output.streamLine(
                MessageEvent(
                    cursor: cursor, chat: chat?.reference, chatName: name, filtered: chat?.isFiltered == true ? true : nil,
                    message: Payload.message(message, resolver: resolver, includeChat: false),
                    warnings: Self.notices(
                        context.sharedSenderNotices([message.isFromMe ? nil : message.sender], resolver: resolver), context.hiddenTextNotice([message]))
                ))
            return
        }
        let style = context.style
        let width = min(context.terminal.width, 100)
        let time = Self.clock(message.date)
        // The stream mixes conversations, so one-to-one senders get their full names.
        let sender: String
        if message.isFromMe {
            sender = "You"
        } else if chat?.kind == .group {
            sender = SenderNames(chat?.participants ?? [], directory: resolver.directory).label(message.sender ?? "")
        } else {
            sender = resolver.directory.displayName(for: message.sender ?? "")
        }
        let color: Style.Role = message.isFromMe ? (message.service == .iMessage ? .imessage : .sms) : .accent
        // A group event such as "Maya added Sam" names who did it, so it goes under the group.
        let isGroupEvent = message.event != nil && chat?.kind == .group
        let place = chat?.kind == .group && !isGroupEvent ? " in " + TextWidth.truncate(name, to: 24) : ""
        let head =
            style.muted(time) + "  " + style.color(style.bold(isGroupEvent ? TextWidth.truncate(name, to: 24) : TextWidth.truncate(sender, to: 20)), color)
        let prefix = head + style.muted(place + " › ")
        let indent = String(repeating: " ", count: TextWidth.columns(time) + 2)
        let summary = ConversationRenderer.summary(message, directory: resolver.directory)
        let firstRoom = width - TextWidth.columns(prefix)
        let restRoom = width - indent.count
        var lines: [String]
        if TextWidth.columns(summary) > firstRoom, firstRoom < restRoom / 2 {
            // A long name and group leave little room: the text starts on the next line.
            lines = [head + style.muted(place + " ›")] + TextWidth.wrap(summary, width: max(12, restRoom)).map { indent + $0 }
        } else {
            lines = TextWidth.wrap(summary, width: max(12, firstRoom)).enumerated().map { ($0.offset == 0 ? prefix : indent) + $0.element }
        }
        // Unknown senders and junk appear only with --all or when named; say which they are.
        if let reference = chat.map({ $0.isFiltered ? "junk  " + $0.reference : $0.reference }), let last = lines.last {
            if TextWidth.columns(last) + 2 + TextWidth.columns(reference) <= width {
                lines[lines.count - 1] = last + "  " + style.muted(reference)
            } else {
                lines.append(indent + style.muted(reference))
            }
        }
        for line in lines { context.output.line(line) }
    }

    private func emitBatch(_ messages: [Message], chatID: Int64?, cursor: String, chatsByID: [Int64: Chat], resolver: Resolver, context: Context) {
        let chat = chatID.flatMap { chatsByID[$0] }
        let name = chat.map { resolver.title(for: $0) } ?? "Unknown conversation"
        if context.output.json {
            context.output.streamLine(
                BatchEvent(
                    cursor: cursor, chat: chat?.reference, chatName: name, filtered: chat?.isFiltered == true ? true : nil,
                    messages: messages.map { Payload.message($0, resolver: resolver, includeChat: false) },
                    warnings: Self.notices(
                        context.sharedSenderNotices(messages.map { $0.isFromMe ? nil : $0.sender }, resolver: resolver), context.hiddenTextNotice(messages))
                ))
            return
        }
        for message in messages { emit(message, cursor: cursor, chatsByID: chatsByID, resolver: resolver, context: context) }
    }

    private func emitReaction(_ row: ReactionRow, targetID: Int64?, cursor: String, chatsByID: [Int64: Chat], resolver: Resolver, context: Context) {
        let from = row.reaction.from.map { Payload.person($0, resolver: resolver).name } ?? "me"
        if context.output.json {
            let filtered = row.chatID.flatMap { chatsByID[$0] }?.isFiltered == true
            context.output.streamLine(
                ReactionEvent(
                    cursor: cursor, chat: row.chatID.map { "chat:\($0)" }, filtered: filtered ? true : nil,
                    target: row.targetGUID, targetRef: targetID.map(messageCursor),
                    reaction: row.reaction.kind.rawValue, emoji: row.reaction.symbol, from: from,
                    fromAddress: row.reaction.from.map { Address($0, region: context.region).value },
                    removed: row.removed ? true : nil, at: row.reaction.at,
                    warnings: context.sharedSenderNotices([row.reaction.from], resolver: resolver)
                ))
            return
        }
        let style = context.style
        let who = row.reaction.from == nil ? "You" : TextWidth.truncate(from, to: 24)
        let verb = row.removed ? "removed" : "reacted"
        let junk = row.chatID.flatMap { chatsByID[$0] }?.isFiltered == true ? "  junk" : ""
        context.output.line(
            style.muted(Self.clock(row.reaction.at)) + "  " + style.muted("\(who) \(verb) ") + row.reaction.symbol
                + style.muted(junk + (row.chatID.map { "  chat:\($0)" } ?? "")))
    }

    /// An event's warnings, nil when there are none.
    static func notices(_ notices: [Notice]?, _ hidden: Notice?) -> [Notice]? {
        let all = (notices ?? []) + (hidden.map { [$0] } ?? [])
        return all.isEmpty ? nil : all
    }

    /// A warning in human output, wrapped like the warnings other commands print.
    private static func printWarning(_ message: String, context: Context) {
        let lines = TextWidth.wrap(message, width: max(20, context.terminal.width - 2))
        context.output.status(lines.enumerated().map { ($0.offset == 0 ? context.style.warning("! ") : "  ") + $0.element }.joined(separator: "\n"))
    }

    /// The time of day, padded so the text after it lines up ("9:41 AM" and "11:05 PM").
    static func clock(_ date: Date) -> String {
        TextWidth.padLeft(Formatting.time(date), to: clockWidth)
    }

    /// The widest time of day in this locale, such as "11:59 PM".
    static let clockWidth: Int = {
        let late = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 59, second: 0, of: Date()) ?? Date()
        return max(TextWidth.columns(Formatting.time(late)), TextWidth.columns(Formatting.time(noon)))
    }()
}
