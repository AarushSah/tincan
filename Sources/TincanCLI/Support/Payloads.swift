import Foundation
import TincanKit

/// JSON shapes. Keys are snake_case; empty and false fields are omitted to keep results small.
enum Payload {
    struct PersonRef: Encodable {
        let name: String
        let address: String?
        let contact: String?
        /// True when the address is on several contact cards, so `name` is only the address.
        var ambiguous: Bool?
        /// Every card that has the address, when there is more than one. tincan does not
        /// choose between them; the person or assistant decides who it is.
        var possibleContacts: [ContactRef]? = nil
        /// `national` when the card's number has no country code and matched on the national
        /// number alone, which is less certain than an exact match.
        var match: String? = nil
        /// For a named person: other cards that have one of their addresses. Messages and
        /// calls on it may be from any of them, and a message to it reaches whoever uses it.
        var sharedWith: [ContactRef]? = nil
    }

    struct ContactRef: Encodable {
        let contact: String
        let name: String
    }

    struct Attachment: Encodable {
        let type: String
        let name: String?
        let mime: String?
        let bytes: Int64?
        let path: String?
        let description: String?
    }

    struct ReactionItem: Encodable {
        let reaction: String
        let emoji: String
        let from: String
        let fromAddress: String?
        let part: Int?
    }

    struct Hidden: Encodable {
        let characters: Int
        /// The text that hidden tag characters and variation selectors spell.
        let decoded: String?
    }

    struct Event: Encodable {
        let kind: String
        let subject: String?
        let subjectAddress: String?
        let title: String?
    }

    struct ReplyPreview: Encodable {
        let text: String
        let truncated: Bool
        let hiddenText: Hidden?
    }

    struct Message: Encodable {
        let id: Int64
        /// `m:<id>`: what `--before`, `--after` and `--around` take.
        let ref: String
        let guid: String
        let chat: String?
        let at: Date
        let from: String
        let fromAddress: String?
        let text: String?
        /// Characters in `text` the person can't see; see `HiddenText`.
        let hiddenText: Hidden?
        let kind: String?
        let service: String
        let attachments: [Attachment]?
        let reactions: [ReactionItem]?
        /// GUID of the message this replies to.
        let replyTo: String?
        /// `m:<id>` of the message this replies to, when tincan may read it: what
        /// `read --around` takes.
        let replyToRef: String?
        let replyToPreview: ReplyPreview?
        let edited: Bool?
        let unsent: Bool?
        let event: Event?
        let app: String?
        let subject: String?
        let effect: String?
        let deliveredAt: Date?
        let readAt: Date?
        let failed: Bool?
        let unread: Bool?
        /// tincan sent it, by its send ledger.
        let sentByTincan: Bool?
    }

    struct Chat: Encodable {
        let ref: String
        let kind: String
        /// The service currently recorded on the thread, not its historical messages.
        let currentService: String
        let name: String
        let participants: [PersonRef]
        let lastActivity: Date?
        let unread: Int?
        let lastMessage: Message?
        /// Excluded conversations are listed so you know they exist, without content.
        let excluded: Bool?
        let filtered: Bool?
        let archived: Bool?
        let sendsReadReceipts: Bool?
    }

    struct Call: Encodable {
        let id: Int64
        let at: Date
        let direction: String
        let outcome: String
        let kind: String
        let durationSeconds: Int
        let with: [PersonRef]
        /// `unknown` when the call history has no address for the other side: a hidden
        /// number or an unknown caller. `with` is then empty.
        let caller: String?
        let provider: String?
        let location: String?
        let junk: Bool?
        /// For missed calls: how and when you got back to them, if you did.
        let returned: FollowUp?
    }

    struct FollowUp: Encodable {
        let via: String
        let at: Date
    }

    struct Contact: Encodable {
        struct Phone: Encodable {
            let label: String?
            let value: String
            let normalized: String?
        }
        struct Email: Encodable {
            let label: String?
            let value: String
        }
        let ref: String
        let name: String
        let givenName: String?
        let middleName: String?
        let familyName: String?
        let nickname: String?
        let organization: String?
        let jobTitle: String?
        let isOrganization: Bool?
        let phones: [Phone]
        let emails: [Email]
        let birthday: String?
        /// Conversations on the card's numbers and emails, where a command reports them.
        var conversations: Int? = nil
        /// When the latest of those conversations last had a message.
        var lastActivity: Date? = nil
    }

    // MARK: Builders

    static func person(_ address: String, resolver: Resolver) -> PersonRef {
        let matches = resolver.directory.matches(for: address)
        let canonical = Address(address, region: resolver.directory.region)
        if matches.count == 1 {
            return PersonRef(
                name: matches[0].contact.displayName, address: canonical.value, contact: "contact:\(matches[0].contact.id)", ambiguous: nil,
                match: matches[0].quality == .national ? "national" : nil
            )
        }
        return PersonRef(
            name: canonical.formatted, address: canonical.value, contact: nil, ambiguous: matches.count > 1 ? true : nil,
            possibleContacts: matches.count > 1 ? matches.map { ContactRef(contact: "contact:\($0.contact.id)", name: $0.contact.displayName) } : nil
        )
    }

    static func person(_ person: Person, region: String?) -> PersonRef {
        let address = person.addresses.first.map { Address($0, region: region).value }
        var possible = person.otherContacts.count > 1 ? person.otherContacts : []
        var shared: [TincanKit.Contact] = []
        if let contact = person.contact {
            shared = person.sharedWith
            // Every card with the address shown, this person's included.
            if let entry = person.sharedAddresses.first(where: { $0.address == address }) { possible = [contact] + entry.contacts }
        }
        return PersonRef(
            name: person.name,
            address: address,
            contact: person.contact.map { "contact:\($0.id)" },
            ambiguous: person.otherContacts.count > 1 ? true : nil,
            possibleContacts: possible.isEmpty ? nil : possible.map(ContactRef.init),
            match: person.match == .national ? "national" : nil,
            sharedWith: shared.isEmpty ? nil : shared.map(ContactRef.init)
        )
    }

    static func message(_ message: TincanKit.Message, resolver: Resolver, includeChat: Bool) -> Message {
        let sender = message.sender.map { person($0, resolver: resolver) }
        let attachments = message.attachments.map { attachment in
            Attachment(
                type: attachment.category,
                name: attachment.name,
                mime: attachment.mimeType,
                bytes: attachment.bytes > 0 ? attachment.bytes : nil,
                path: attachment.path,
                description: attachment.summary
            )
        }
        let reactions = message.reactions.map { reaction in
            ReactionItem(
                reaction: reaction.kind.rawValue,
                emoji: reaction.symbol,
                from: reaction.from.map { person($0, resolver: resolver).name } ?? "me",
                fromAddress: reaction.from.map { Address($0, region: resolver.directory.region).value },
                part: reaction.part > 0 ? reaction.part : nil
            )
        }
        let event = message.event.map { event in
            Event(
                kind: event.kind.rawValue,
                subject: event.subject.map { person($0, resolver: resolver).name },
                subjectAddress: event.subject.map { Address($0, region: resolver.directory.region).value },
                title: event.title
            )
        }
        let text = message.text
        return Message(
            id: message.id,
            ref: message.reference,
            guid: message.guid,
            chat: includeChat ? message.chatID.map { "chat:\($0)" } : nil,
            at: message.date,
            from: message.isFromMe ? "me" : (sender?.name ?? "unknown"),
            fromAddress: sender?.address,
            text: text.isEmpty ? nil : text,
            hiddenText: HiddenText.find(in: text).map { Hidden(characters: $0.characters, decoded: $0.decoded) },
            kind: message.kind == .message ? nil : message.kind.rawValue,
            service: message.service.rawValue,
            attachments: attachments.isEmpty ? nil : attachments,
            reactions: reactions.isEmpty ? nil : reactions,
            replyTo: message.replyToGUID,
            replyToRef: message.replyToReference,
            replyToPreview: message.replyToPreview.map {
                ReplyPreview(
                    text: $0.text, truncated: $0.truncated,
                    hiddenText: HiddenText.find(in: $0.text).map { Hidden(characters: $0.characters, decoded: $0.decoded) })
            },
            edited: message.isEdited ? true : nil,
            unsent: message.isUnsent ? true : nil,
            event: event,
            app: message.appName,
            subject: message.subject,
            effect: message.expressiveEffect,
            deliveredAt: message.deliveredAt,
            readAt: message.readAt,
            failed: message.failed ? true : nil,
            unread: !message.isFromMe && !message.isRead ? true : nil,
            sentByTincan: message.sentByTincan ? true : nil
        )
    }

    static func chat(_ summary: ChatSummary, resolver: Resolver, excluded: Bool) -> Chat {
        let chat = summary.chat
        let others = chat.participants.isEmpty ? [chat.identifier] : chat.participants
        return Chat(
            ref: chat.reference,
            kind: chat.kind.rawValue,
            currentService: chat.service.rawValue,
            name: resolver.title(for: chat),
            participants: others.map { person($0, resolver: resolver) },
            lastActivity: summary.lastActivity,
            unread: !excluded && summary.unreadCount > 0 ? summary.unreadCount : nil,
            lastMessage: excluded ? nil : summary.lastMessage.map { message($0, resolver: resolver, includeChat: false) },
            excluded: excluded ? true : nil,
            filtered: chat.isFiltered ? true : nil,
            archived: chat.isArchived ? true : nil,
            sendsReadReceipts: chat.sendsReadReceipts
        )
    }

    static func call(_ call: TincanKit.Call, resolver: Resolver, returned: FollowUp? = nil) -> Call {
        Call(
            id: call.id,
            at: call.date,
            direction: call.direction.rawValue,
            outcome: call.outcome.rawValue,
            kind: call.kind.rawValue,
            durationSeconds: Int(call.duration.rounded()),
            with: call.addresses.map { person($0, resolver: resolver) },
            caller: call.addresses.isEmpty ? "unknown" : nil,
            provider: call.provider,
            location: call.location,
            junk: call.isJunk ? true : nil,
            returned: returned
        )
    }

    static func contact(_ contact: TincanKit.Contact) -> Contact {
        func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
        return Contact(
            ref: "contact:\(contact.id)",
            name: contact.displayName,
            givenName: nonEmpty(contact.givenName),
            middleName: nonEmpty(contact.middleName),
            familyName: nonEmpty(contact.familyName),
            nickname: nonEmpty(contact.nickname),
            organization: nonEmpty(contact.organization),
            jobTitle: nonEmpty(contact.jobTitle),
            isOrganization: contact.isOrganization ? true : nil,
            phones: contact.phones.map { Contact.Phone(label: $0.label, value: $0.value, normalized: $0.normalized) },
            emails: contact.emails.map { Contact.Email(label: $0.label, value: $0.value) },
            birthday: contact.birthday
        )
    }
}

extension Payload.ContactRef {
    init(_ contact: TincanKit.Contact) {
        self.init(contact: "contact:\(contact.id)", name: contact.displayName)
    }
}
