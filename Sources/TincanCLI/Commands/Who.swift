import ArgumentParser
import Foundation
import TincanKit

struct Who: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show everything tincan knows about a person or group.",
        discussion: """
            Connects a contact card to every phone number and email Messages uses for them, each conversation across iMessage, SMS, RCS and groups, and their recent calls. When a number is on more than one card, tincan says so instead of picking one, and names the other cards even when you asked by name. A number that matched the card only without its country code is marked `match: national`.

            Examples:
              tincan who Maya
              tincan who +14155550142
              tincan who chat:42
              tincan who Maya --json
            """
    )

    @Argument(help: ArgumentHelp(Help.target, valueName: "who"))
    var who: String

    @OptionGroup var global: GlobalOptions

    struct AddressInfo: Encodable {
        let address: String
        let formatted: String
        let kind: String
        let label: String?
        /// Services Messages used with the address: `imessage`, `sms`, `rcs`, as everywhere.
        let services: [String]
    }

    struct Conversation: Encodable {
        let ref: String
        let kind: String
        let currentService: String
        let name: String
        /// For one-to-one conversations: the address it uses.
        let address: String?
        let messages: Int
        let lastActivity: Date?
        let unread: Int?
        /// Filed under Unknown Senders or Junk.
        let filtered: Bool?
    }

    struct CallSummary: Encodable {
        let total: Int
        let missed: Int
        /// Up to five calls, newest first.
        let recent: [Payload.Call]
        /// The command for the calls before `recent`, when there are more.
        var earlier: Output.Next? = nil
    }

    struct Result: Encodable {
        let name: String
        let ref: String
        let contact: Payload.Contact?
        /// `national` when the address you gave matched the card only without its country
        /// code, which is less certain than an exact match.
        var match: String? = nil
        /// Other cards with one of these addresses: messages and calls on it may be from any
        /// of them.
        let sharedWith: [Payload.PersonRef]?
        let addresses: [AddressInfo]
        let conversations: [Conversation]
        let participants: [Payload.PersonRef]?
        let calls: CallSummary?
    }

    func run() async throws {
        try await runCommand("who", options: global) { context in
            let database = try context.messages()
            let resolver = try context.resolver()
            var target = try context.resolve(who, command: "who")
            let isMe = who.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "me"
            if case .chat(let chat) = target, chat.kind == .direct {
                // A one-to-one conversation is about the person in it.
                target = .person(resolver.person(forAddress: chat.participants.first ?? chat.identifier))
            }
            let region = context.region
            let activity = try database.lastActivityByChat()
            let unread = try database.unreadCountByChat()
            let handles = try database.handles().values

            func conversation(_ chat: Chat, counts: [Int64: Int]) -> Conversation {
                Conversation(
                    ref: chat.reference,
                    kind: chat.kind.rawValue,
                    currentService: chat.service.rawValue,
                    name: resolver.title(for: chat),
                    address: chat.kind == .direct ? Address(chat.participants.first ?? chat.identifier, region: region).value : nil,
                    messages: counts[chat.id] ?? 0,
                    lastActivity: activity[chat.id],
                    unread: (unread[chat.id] ?? 0) > 0 ? unread[chat.id] : nil,
                    filtered: chat.isFiltered ? true : nil
                )
            }

            switch target {
            case .chat(let chat):
                let counts = try database.messageCounts(chatIDs: [chat.id])
                context.warnFiltered([chat])
                let participants = chat.participants.map { Payload.person($0, resolver: resolver) }
                let result = Result(
                    name: resolver.title(for: chat), ref: chat.reference, contact: nil, sharedWith: nil, addresses: [],
                    conversations: [conversation(chat, counts: counts)], participants: participants, calls: nil
                )
                context.output.result(result)
                if !context.output.json { renderGroup(result, context: context) }

            case .person(let person):
                let direct = resolver.directChats(with: person)
                let groups = resolver.groupChats(with: person)
                let chats = (direct + groups).sorted { (activity[$0.id] ?? .distantPast) > (activity[$1.id] ?? .distantPast) }
                let counts = try database.messageCounts(chatIDs: chats.map(\.id))

                let canonical = resolver.canonicalAddresses(of: person)
                var servicesByAddress: [String: Set<String>] = [:]
                for handle in handles {
                    let value = Address(handle.address, region: region).value
                    if canonical.contains(value) { servicesByAddress[value, default: []].insert(handle.service.rawValue) }
                }
                var labels: [String: String] = [:]
                if let contact = person.contact {
                    for phone in contact.phones { labels[Address(phone.value, region: region).value] = phone.label }
                    for email in contact.emails { labels[Address(email.value, region: region).value] = email.label }
                }
                // The card's order first (phones, then emails), then addresses only Messages knows.
                var cardOrder: [String: Int] = [:]
                if let contact = person.contact {
                    for (index, value) in (contact.phones.map(\.value) + contact.emails.map(\.value)).enumerated() {
                        let key = Address(value, region: region).value
                        if cardOrder[key] == nil { cardOrder[key] = index }
                    }
                }
                let ordered = person.addresses.enumerated().sorted { first, second in
                    let a = cardOrder[Address(first.element, region: region).value] ?? Int.max
                    let b = cardOrder[Address(second.element, region: region).value] ?? Int.max
                    return a != b ? a < b : first.offset < second.offset
                }.map(\.element)
                var seen = Set<String>()
                let addresses: [AddressInfo] = ordered.compactMap { raw in
                    let address = Address(raw, region: region)
                    guard seen.insert(address.value).inserted else { return nil }
                    return AddressInfo(
                        address: address.value,
                        formatted: address.formatted,
                        kind: address.kind.rawValue,
                        label: labels[address.value],
                        services: (servicesByAddress[address.value] ?? []).sorted()
                    )
                }

                var callSummary: CallSummary?
                do {
                    let history = try context.calls()
                    let calls = try history.calls(addresses: canonical)
                    let shown = Array(calls.prefix(5))
                    let followUps = Calls.followUps(for: shown, history: history, context: context, resolver: resolver)
                    let recent = shown.map { Payload.call($0, resolver: resolver, returned: followUps[$0.id]) }
                    var earlier: Output.Next?
                    if calls.count > shown.count, let oldest = shown.last {
                        let cursor = Formatting.cursor(oldest.date)
                        // `me` covers your own addresses that aren't on your card, as the summary does.
                        let reference = isMe ? "me" : person.reference
                        earlier = Output.Next(cursor: cursor, command: "tincan calls \(shellQuote(reference)) --before \(cursor) --json")
                    }
                    callSummary = CallSummary(total: calls.count, missed: calls.filter(\.isMissed).count, recent: recent, earlier: earlier)
                } catch {
                    let failure = TincanError.wrap(error)
                    context.output.warn("calls_unavailable", "Call history is unavailable: \(failure.message)")
                }

                context.warnExcludedConversations(with: person)
                context.warnFiltered(chats)
                let shared = person.sharedAddresses.flatMap { entry in
                    entry.contacts.map { Payload.PersonRef(name: $0.displayName, address: entry.address, contact: "contact:\($0.id)", ambiguous: nil) }
                }
                context.warnSharedAddress(person)
                let result = Result(
                    name: person.name,
                    ref: person.reference,
                    contact: person.contact.map(Payload.contact),
                    match: person.match == .national ? "national" : nil,
                    sharedWith: shared.isEmpty ? nil : shared,
                    addresses: addresses,
                    conversations: chats.map { conversation($0, counts: counts) },
                    participants: nil,
                    calls: callSummary
                )
                context.output.result(result)
                if !context.output.json { renderPerson(result, person: person, isMe: isMe, context: context) }
            }
        }
    }

    private func renderPerson(_ result: Result, person: Person, isMe: Bool, context: Context) {
        let style = context.style
        let output = context.output
        let width = min(context.terminal.width, 100)
        // A number or email no card names is already the title; its reference would repeat it.
        let repeatsTitle = person.contact == nil && Address(result.ref, region: context.region).formatted == result.name
        output.line(Layout.header(result.name, details: [], trailing: repeatsTitle ? "" : result.ref, width: width, style: style))
        var facts: [String] = []
        if let contact = person.contact {
            if !contact.nickname.isEmpty, contact.nickname != result.name { facts.append("“\(contact.nickname)”") }
            let work = [contact.jobTitle, contact.isOrganization ? "" : contact.organization].filter { !$0.isEmpty }.joined(separator: ", ")
            if !work.isEmpty { facts.append(work) }
            if let birthday = contact.birthday { facts.append("Birthday " + Self.birthday(birthday)) }
            for shared in person.sharedAddresses {
                facts.append("Shares \(Address(shared.address, region: context.region).formatted) with " + Formatting.list(shared.contacts.map(\.displayName)))
            }
        } else if person.otherContacts.count > 1 {
            facts.append("On \(person.otherContacts.count) contact cards: " + person.otherContacts.map(\.displayName).joined(separator: ", "))
        } else {
            facts.append("Not in your contacts")
        }
        for line in TextWidth.wrap(facts.joined(separator: " · "), width: width) where !facts.isEmpty { output.line(style.muted(line)) }

        if !result.addresses.isEmpty {
            output.line()
            output.line(style.accent(isMe ? "Your addresses" : "Reach them at"))
            let addressWidth = min(width / 2, result.addresses.map { TextWidth.columns($0.formatted) }.max() ?? 0)
            let labelWidth = min(12, result.addresses.map { TextWidth.columns($0.label ?? "") }.max() ?? 0)
            let servicesWidth = max(8, width - 2 - addressWidth - 2 - (labelWidth > 0 ? labelWidth + 2 : 0))
            for address in result.addresses {
                let names = address.services.map { MessageService(rawValue: $0)?.displayName ?? $0 }
                // Your own addresses send rather than appear in conversations, so no services show.
                let unused = isMe ? "" : "not used in Messages"
                let services =
                    names.isEmpty
                    ? style.muted(TextWidth.truncate(unused, to: servicesWidth)) : TextWidth.truncate(names.joined(separator: " · "), to: servicesWidth)
                let label = labelWidth > 0 ? style.muted(TextWidth.fit(address.label ?? "", to: labelWidth)) + "  " : ""
                output.line("  " + TextWidth.fit(address.formatted, to: addressWidth) + "  " + label + services)
            }
        }

        output.line()
        output.line(style.accent("Conversations"))
        if result.conversations.isEmpty {
            output.line(style.muted("  None yet."))
        }
        let shown = Array(result.conversations.prefix(12))
        let refWidth = shown.map { TextWidth.columns($0.ref) }.max() ?? 0
        // Room for a whole phone number, such as +1 (415) 555-0142, before details.
        let widestLabel = shown.map { TextWidth.columns(label($0)) }.max() ?? 0
        let nameWidth = min(max(10, (width - refWidth) / 3, min(18, widestLabel)), 30, widestLabel)
        let detailWidth = max(10, width - 2 - refWidth - 2 - nameWidth - 2)
        for conversation in shown {
            let service = MessageService(rawValue: conversation.currentService)?.displayName ?? conversation.currentService
            let parts: [Layout.Part] = [
                (service, style.muted),
                (conversation.messages.formatted() + (conversation.messages == 1 ? " message" : " messages"), style.muted),
                (conversation.lastActivity.map { Formatting.relative($0) } ?? "", style.muted),
                (conversation.unread.map { "\($0) unread" } ?? "", { style.color($0, .imessage) }),
                (conversation.filtered == true ? "junk" : "", style.muted),
            ]
            output.line(
                "  " + style.muted(TextWidth.padRight(conversation.ref, to: refWidth)) + "  "
                    + TextWidth.fit(label(conversation), to: nameWidth) + "  " + Layout.parts(parts, width: detailWidth, style: style, whole: true))
        }
        if result.conversations.count > shown.count {
            for line in TextWidth.wrapCommand(
                "… and \(result.conversations.count - shown.count) more: tincan chats --with \(shellQuote(who))", width: width - 2)
            {
                output.line("  " + style.muted(line))
            }
        }

        if let calls = result.calls {
            output.line()
            output.line(style.accent("Calls"))
            if calls.total == 0 {
                output.line(style.muted("  No calls."))
            } else {
                output.line("  " + Formatting.plural(calls.total, "call") + (calls.missed > 0 ? ", " + style.warning("\(calls.missed) missed") : ""))
                for line in CallsRendering.lines(calls.recent, style: style, width: width, showName: false, indent: 2) { output.line(line) }
            }
        }
    }

    /// A group's name, or for a one-to-one conversation the address it uses.
    private func label(_ conversation: Conversation) -> String {
        guard conversation.kind != "group" else { return conversation.name }
        return conversation.address.map { Address($0, region: nil).formatted } ?? "One-to-one"
    }

    private func renderGroup(_ result: Result, context: Context) {
        let style = context.style
        let output = context.output
        let width = min(context.terminal.width, 100)
        output.line(Layout.header(result.name, details: [], trailing: result.ref, width: width, style: style))
        if let conversation = result.conversations.first {
            let service = MessageService(rawValue: conversation.currentService)?.displayName ?? conversation.currentService
            output.line(
                style.muted(
                    TextWidth.truncate(
                        "Group · \(service) · \((result.participants?.count ?? 0) + 1) people · \(conversation.messages.formatted()) \(conversation.messages == 1 ? "message" : "messages")",
                        to: width)))
        }
        output.line()
        output.line(style.accent("People"))
        let people = result.participants ?? []
        let nameWidth = min(width / 2, people.map { TextWidth.columns($0.name) }.max() ?? 0)
        for person in people {
            let detail = person.contact != nil ? (person.address.map { Address($0, region: context.region).formatted } ?? "") : ""
            let name = detail.isEmpty ? TextWidth.truncate(person.name, to: width - 2) : TextWidth.fit(person.name, to: nameWidth)
            output.line("  " + name + (detail.isEmpty ? "" : "  " + style.muted(TextWidth.truncate(detail, to: max(4, width - 4 - nameWidth)))))
        }
        output.line("  " + style.muted("You"))
    }

    static func birthday(_ text: String) -> String {
        guard let components = BirthdayText.components(text), let month = components.month, let day = components.day,
            let date = Calendar.current.date(from: DateComponents(year: components.year ?? 2000, month: month, day: day))
        else { return text }
        if components.year != nil, components.year != NSDateComponentUndefined {
            return date.formatted(.dateTime.month(.wide).day().year())
        }
        return date.formatted(.dateTime.month(.wide).day())
    }
}
