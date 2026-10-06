import Foundation

/// Someone you exchange messages or calls with: a contact card, a bare address, or both.
public struct Person: Sendable {
    /// The contact card, when exactly one card has the person's address.
    public let contact: Contact?
    /// Other cards that share the address (a family line, or duplicate cards).
    public let otherContacts: [Contact]
    /// Every address that reaches this person, as Messages and call history store them.
    public let addresses: [String]
    public let name: String
    /// The person's addresses that other cards have too, with those cards. Without a card of
    /// its own, a person's address on several cards lists all of them.
    public var sharedAddresses: [SharedAddress] = []
    /// How the address that named this person matched their card, when an address did.
    /// `.national` means one side had no country code, which is less certain.
    public var match: MatchQuality?

    /// `contact:<id>` when known, otherwise the address.
    public var reference: String {
        if let contact { return "contact:\(contact.id)" }
        return addresses.first ?? name
    }

    /// Other cards that share any of the person's addresses: a family line, a shared work
    /// phone or a duplicate card. tincan can't tell which of them used the address.
    public var sharedWith: [Contact] {
        var seen = Set<String>()
        return sharedAddresses.flatMap(\.contacts).filter { seen.insert($0.id).inserted }
    }
}

/// One of a person's addresses that is also on other contact cards.
public struct SharedAddress: Sendable {
    /// The canonical address.
    public let address: String
    /// The other cards that have it.
    public let contacts: [Contact]
}

/// What a command argument such as `Maya`, `+14155550142` or `chat:42` refers to.
public enum Target: Sendable {
    case person(Person)
    case chat(Chat)
}

/// A possible meaning of an ambiguous reference, with the facts that tell candidates
/// apart. tincan lists candidates and never chooses among them.
public struct Candidate: Sendable {
    public let reference: String
    public let name: String
    /// One line for people: the first address, how many more, the company.
    public let detail: String?
    /// Every canonical address, for people.
    public var addresses: [String] = []
    public var organization: String?
    /// One-to-one and group conversations with this person, or 1 for a conversation.
    public var conversations: Int = 0
    /// The latest message in any of those conversations.
    public var lastActivity: Date?
    /// One-to-one conversations with this person that are excluded: counted, never read,
    /// so neither `conversations` nor `lastActivity` includes them.
    public var excludedConversations: Int = 0
    /// Other cards with one of this candidate's addresses. Their conversations on that
    /// address are the same conversations.
    public var sharesAddressWith: [SharedCard] = []

    /// Another card with one of a candidate's addresses.
    public struct SharedCard: Sendable {
        /// `contact:<id>`.
        public let reference: String
        public let name: String
        /// The canonical address both cards have.
        public let address: String
        /// One-to-one conversations on that address, most recent first.
        public let chats: [String]
    }

    public init(
        reference: String, name: String, detail: String?, addresses: [String] = [], organization: String? = nil, conversations: Int = 0,
        lastActivity: Date? = nil, sharesAddressWith: [SharedCard] = []
    ) {
        self.reference = reference
        self.name = name
        self.detail = detail
        self.addresses = addresses
        self.organization = organization
        self.conversations = conversations
        self.lastActivity = lastActivity
        self.sharesAddressWith = sharesAddressWith
    }
}

public enum ResolveError: Error, Sendable {
    case notFound(query: String, suggestion: String?)
    case ambiguous(query: String, candidates: [Candidate])
    case excluded(Chat)
    /// A phone number without a country code that the region can't complete, or one too
    /// short for a phone number or a short code Messages knows. `options` are the full
    /// numbers it could be, each with the cards that have it; tincan never picks one.
    case incompleteNumber(query: String, tooShort: Bool, options: [(address: Address, contacts: [Contact])])
}

/// Turns references into people and chats, and people into their conversations.
///
/// Names are matched against Contacts and group names. An exact full name of several words
/// wins. One word that is exactly someone's name, nickname, first or last name is equally
/// good for each of them. Anything that leaves more than one equally good match is reported
/// as ambiguous with every candidate, never resolved by guessing, unless every match is a
/// card with exactly the same addresses: then the name means those addresses, and no card
/// is chosen, as when one of them is typed. Other people choose group names, so a group
/// never outranks a contact, and groups filed under Unknown Senders or Junk are never
/// matched by name.
public final class Resolver {
    public let directory: Directory
    public let chats: [Chat]
    public let excludedChatIDs: Set<Int64>
    /// Every address Messages knows, deduplicated.
    public let knownAddresses: [String]
    private var addressesByContact: [String: [String]] = [:]
    private let region: String?
    /// Each chat's other participants as canonical addresses, parsed once.
    private var canonicalParticipants: [Int64: [String]] = [:]

    /// Latest message date per chat, used to describe candidates. Optional.
    public let activity: [Int64: Date]

    public init(
        directory: Directory, chats: [Chat], handles: [Handle], extraAddresses: [String] = [], excludedChatIDs: Set<Int64> = [], activity: [Int64: Date] = [:]
    ) {
        self.activity = activity
        for chat in chats {
            let others = chat.participants.isEmpty ? [chat.identifier] : chat.participants
            canonicalParticipants[chat.id] = others.map { Address($0, region: directory.region).value }
        }
        self.directory = directory
        self.chats = chats
        self.excludedChatIDs = excludedChatIDs
        region = directory.region
        var seen = Set<String>()
        var addresses: [String] = []
        // Handle order decides a person's first address; keep it stable between runs.
        let orderedHandles = handles.sorted { $0.rowID < $1.rowID }
        for address in orderedHandles.map(\.address) + chats.flatMap(\.participants) + extraAddresses where seen.insert(address).inserted {
            addresses.append(address)
        }
        knownAddresses = addresses
        for address in addresses {
            for match in directory.matches(for: address) {
                addressesByContact[match.contact.id, default: []].append(address)
            }
        }
    }

    // MARK: Resolving references

    public func resolve(_ query: String) throws -> Target {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResolveError.notFound(query: query, suggestion: nil) }
        let lowered = text.lowercased()

        if let reference = ChatReference.parse(text, requirePrefix: true) {
            let chat = chats.first { reference.matches($0) }
            guard let chat else { throw ResolveError.notFound(query: text, suggestion: "List conversations with `tincan chats`.") }
            if excludedChatIDs.contains(chat.id) { throw ResolveError.excluded(chat) }
            return .chat(chat)
        }
        if lowered.hasPrefix("contact:") {
            let id = String(text.dropFirst(8))
            guard let contact = directory.contact(id: id) else {
                throw ResolveError.notFound(query: text, suggestion: "Find contacts with `tincan contacts <name>`.")
            }
            return .person(person(for: contact))
        }
        // `address:<address>`, as `tincan exclude list` shows a person's excluded address.
        if lowered.hasPrefix(Exclusion.addressPrefix) {
            let address = String(text.dropFirst(Exclusion.addressPrefix.count)).trimmingCharacters(in: .whitespaces)
            guard Self.looksLikeAddress(address) else {
                throw ResolveError.notFound(query: text, suggestion: "Use address: with a phone number or email, such as address:<+number>.")
            }
            try requireComplete(address)
            return .person(person(forAddress: address))
        }
        if Self.looksLikeAddress(text) {
            try requireComplete(text)
            return .person(person(forAddress: text))
        }
        return try resolveName(text)
    }

    /// Whether `text` should be treated as a phone number or email rather than a name.
    public static func looksLikeAddress(_ text: String) -> Bool {
        if text.contains("@") { return true }
        let digits = text.filter(\.isNumber).count
        let letters = text.filter(\.isLetter).count
        if text.hasPrefix("+") && digits >= 3 { return true }
        return digits >= 3 && letters == 0
    }

    /// Throws `incompleteNumber` when `raw`, a phone number, names no line: it has no
    /// country code and the region can't complete it (`555-0142`), or it has fewer than five
    /// digits (`0142`) and isn't a code Messages already has a conversation with, such as a
    /// carrier's.
    public func requireComplete(_ raw: String) throws {
        let tooShort = isTooShort(raw)
        guard tooShort || Address(raw, region: region).lacksCountryCode else { return }
        throw ResolveError.incompleteNumber(query: raw, tooShort: tooShort, options: completeNumbers(for: raw))
    }

    /// Fewer than five digits: too short for a phone number or a short code, so a new
    /// conversation with it would go nowhere anyone meant. A code Messages already has a
    /// conversation with, such as a carrier's, still works.
    public func isTooShort(_ raw: String) -> Bool {
        let address = Address(raw, region: region)
        guard address.kind != .email, raw.filter(\.isNumber).count < 5 else { return false }
        return !knownAddresses.contains { Address($0, region: region).value == address.value }
    }

    /// You, from your own addresses, most used first: the card that has them when there is
    /// one, with every one of your addresses. Nil without any.
    public func person(forOwnAddresses own: [String]) -> Person? {
        guard let first = own.first else { return nil }
        let me = person(forAddress: first)
        var seen = canonicalAddresses(of: me)
        let more = own.filter { seen.insert(Address($0, region: region).value).inserted }
        guard !more.isEmpty else { return me }
        return Person(
            contact: me.contact, otherContacts: me.otherContacts, addresses: me.addresses + more, name: me.name,
            sharedAddresses: me.sharedAddresses, match: me.match
        )
    }

    private func resolveName(_ text: String) throws -> Target {
        struct Option {
            let rank: Int
            let target: Target
            let candidate: Candidate
            var isGroup: Bool { if case .chat = target { return true } else { return false } }
        }
        var options: [Option] = []
        for match in directory.search(name: text) {
            let person = person(for: match.contact)
            options.append(Option(rank: match.rank, target: .person(person), candidate: candidate(for: person)))
        }
        let needle = Directory.fold(text)
        // Groups in Unknown Senders or Junk were named by people you don't know.
        for chat in chats where chat.kind == .group && !chat.isFiltered && !excludedChatIDs.contains(chat.id) {
            guard let name = chat.displayName else { continue }
            let folded = Directory.fold(name)
            let rank: Int? = folded == needle ? 0 : (folded.contains(needle) ? 4 : nil)
            if let rank { options.append(Option(rank: rank, target: .chat(chat), candidate: groupCandidate(chat))) }
        }
        guard let best = options.map(\.rank).min() else {
            // A message reference where a person or conversation belongs, as from a search result.
            if text.hasPrefix("m:"), !text.dropFirst(2).isEmpty, text.dropFirst(2).allSatisfy(\.isNumber) {
                throw ResolveError.notFound(
                    query: text, suggestion: "\(text) is a message. Read it in its conversation with `tincan read <chat> --around \(text)`.")
            }
            throw ResolveError.notFound(query: text, suggestion: "Try a phone number, an email address, or `tincan contacts \(shellQuote(text))`.")
        }
        func cutoff(_ best: Int) -> Int { Directory.cutoff(best: best, query: text) }
        var top = options.filter { $0.rank <= cutoff(best) }
        // The people in a group choose its name, so it never outranks your contacts: a
        // group among the best matches is ambiguous with every contact the name matches
        // at all, listed first.
        let people = options.filter { !$0.isGroup }
        if top.contains(where: \.isGroup), let bestPerson = people.map(\.rank).min() {
            top = people.filter { $0.rank <= cutoff(bestPerson) } + top.filter(\.isGroup)
        }
        if top.count == 1 { return top[0].target }
        // Cards with exactly the same addresses, such as two people on a family's home line,
        // lead to the same conversations. The name then means those addresses, on no card.
        let cards = top.compactMap { option -> Person? in
            if case .person(let person) = option.target { return person } else { return nil }
        }
        if cards.count == top.count, let shared = person(sharing: cards) { return .person(shared) }
        throw ResolveError.ambiguous(query: text, candidates: top.prefix(12).map(\.candidate))
    }

    /// The identity of `people` when every one has exactly the same addresses: those
    /// addresses, with no card chosen, as when one of them is typed. Nil when any address
    /// differs, or when they have none.
    private func person(sharing people: [Person]) -> Person? {
        guard let first = people.first else { return nil }
        let wanted = canonicalAddresses(of: first)
        guard !wanted.isEmpty, people.dropFirst().allSatisfy({ canonicalAddresses(of: $0) == wanted }) else { return nil }
        var seen = Set<String>()
        let ordered = first.addresses.map { Address($0, region: region).value }.filter { seen.insert($0).inserted }
        var result: Person?
        for address in ordered {
            let next = person(forAddress: address)
            // An address on one card only would name that card; then the cards differ.
            guard next.contact == nil else { return nil }
            guard let merged = result else {
                result = next
                continue
            }
            var cards = merged.otherContacts
            for card in next.otherContacts where !cards.contains(where: { $0.id == card.id }) { cards.append(card) }
            result = Person(
                contact: nil, otherContacts: cards, addresses: merged.addresses + next.addresses, name: merged.name,
                sharedAddresses: merged.sharedAddresses + next.sharedAddresses
            )
        }
        return result
    }

    /// A group as a candidate: its name, and everyone in it in `detail` and `addresses`,
    /// so the person can tell it apart from a contact or another group.
    public func groupCandidate(_ chat: Chat) -> Candidate {
        let names = chat.participants.map { directory.displayName(for: $0) }
        let shown = names.count > 5 ? Array(names.prefix(4)) + ["\(names.count - 4) others"] : names
        var seen = Set<String>()
        let addresses = chat.participants.map { Address($0, region: region).value }.filter { seen.insert($0).inserted }
        return Candidate(
            reference: chat.reference, name: title(for: chat),
            detail: "group with " + (shown.isEmpty ? "" : shown.joined(separator: ", ") + " and ") + "you",
            addresses: addresses, conversations: 1, lastActivity: activity[chat.id]
        )
    }

    /// Group conversations Messages could show under one of `titles`, the names and numbers
    /// a keyboard-mode send checks before typing: a group named like the person, or an
    /// unnamed group whose only other member is shown by name or number. Excluded and
    /// filtered groups count too, since Messages can show any of them.
    public func groups(titled titles: [String]) -> [Chat] {
        chats.filter { chat in
            guard chat.kind == .group else { return false }
            var shown = [title(for: chat)]
            if chat.displayName == nil, chat.participants.count == 1, let only = chat.participants.first {
                shown += [directory.displayName(for: only), only]
            }
            return shown.contains { MessagesKeyboard.title($0, exactlyMatches: titles) }
        }
    }

    private func candidate(for person: Person) -> Candidate {
        var details: [String] = []
        // Cards that share a number share its conversation too; say so first.
        let shared = person.sharedAddresses.flatMap { entry in
            entry.contacts.map { contact in
                Candidate.SharedCard(
                    reference: "contact:\(contact.id)", name: contact.displayName, address: entry.address,
                    chats: directChats(onAddress: entry.address).map(\.reference)
                )
            }
        }
        if let first = shared.first {
            let kind = Address(first.address, region: region).kind == .email ? "email" : "number"
            let others = Set(shared.filter { $0.address == first.address }.map(\.reference)).count
            details.append("same \(kind) as " + (others == 1 ? first.name : "\(others) other cards"))
            if let chat = first.chats.first { details.append(chat) }
        } else if let first = person.addresses.first {
            details.append(Address(first, region: region).formatted)
        }
        if person.addresses.count > 1 { details.append("+\(person.addresses.count - 1) more") }
        let organization = person.contact.flatMap { $0.isOrganization || $0.organization.isEmpty ? nil : $0.organization }
        if let organization { details.append(organization) }
        let (conversations, last) = conversationActivity(of: person)
        let excluded = excludedConversationCount(of: person)
        if conversations == 0 {
            // Excluded conversations still exist; "no conversations" would say otherwise.
            details.append(excluded == 0 ? "no conversations" : excluded == 1 ? "1 excluded conversation" : "\(excluded) excluded conversations")
        }
        var seen = Set<String>()
        let addresses = person.addresses.map { Address($0, region: region).value }.filter { seen.insert($0).inserted }
        var candidate = Candidate(
            reference: person.reference, name: person.name, detail: details.isEmpty ? nil : details.joined(separator: " · "),
            addresses: addresses, organization: organization, conversations: conversations, lastActivity: last,
            sharesAddressWith: shared
        )
        candidate.excludedConversations = excluded
        return candidate
    }

    /// How many one-to-one conversations with `person` are excluded, as excluding a person
    /// excludes them. Only the count: nothing about them is read.
    public func excludedConversationCount(of person: Person) -> Int {
        let wanted = canonicalAddresses(of: person)
        return chats.filter { chat in
            chat.kind == .direct && excludedChatIDs.contains(chat.id)
                && (canonicalParticipants[chat.id] ?? []).allSatisfy { wanted.contains($0) }
        }.count
    }

    // MARK: People

    public func person(for contact: Contact) -> Person {
        var addresses = addressesByContact[contact.id] ?? []
        for address in directory.addresses(of: contact) where !addresses.contains(where: { Address($0, region: region).value == address.value }) {
            // A number saved without its country code is the same line as the full number
            // Messages uses for it; keep only the full one.
            if address.lacksCountryCode, let saved = address.phone,
                addresses.contains(where: { Address($0, region: region).phone.map { $0.isE164 && $0.matches(saved) } ?? false })
            {
                continue
            }
            addresses.append(address.value)
        }
        return Person(
            contact: contact, otherContacts: [], addresses: addresses, name: contact.displayName, sharedAddresses: sharedAddresses(addresses, of: contact))
    }

    public func person(forAddress raw: String) -> Person {
        let canonical = Address(raw, region: region)
        let matches = directory.matches(for: raw)
        if matches.count == 1 {
            var person = self.person(for: matches[0].contact)
            person.match = matches[0].quality
            // A number typed without its country code is not an address: it names the card's
            // full number, never a second one.
            if !canonical.lacksCountryCode, !person.addresses.contains(where: { Address($0, region: region).value == canonical.value }) {
                // The card's digits without a country code are this same line.
                let others = person.addresses.filter { raw in
                    let saved = Address(raw, region: region)
                    return !(saved.lacksCountryCode && saved.phone.map { canonical.phone?.matches($0) ?? false } ?? false)
                }
                person = Person(
                    contact: person.contact, otherContacts: [], addresses: [canonical.value] + others, name: person.name,
                    sharedAddresses: person.sharedAddresses, match: person.match
                )
            }
            return person
        }
        // Unknown, or on several cards: the address is the identity.
        let variants = knownAddresses.filter { Address($0, region: region).value == canonical.value }
        let addresses = variants.isEmpty ? [canonical.value] : variants
        let cards = matches.map(\.contact)
        return Person(
            contact: nil, otherContacts: cards, addresses: addresses, name: canonical.formatted,
            sharedAddresses: cards.count > 1 ? [SharedAddress(address: canonical.value, contacts: cards)] : []
        )
    }

    /// The addresses in `addresses` that cards other than `contact` have too.
    private func sharedAddresses(_ addresses: [String], of contact: Contact) -> [SharedAddress] {
        var seen = Set<String>()
        var result: [SharedAddress] = []
        for raw in addresses {
            let value = Address(raw, region: region).value
            guard seen.insert(value).inserted else { continue }
            let others = directory.matches(for: raw).map(\.contact).filter { $0.id != contact.id }
            if !others.isEmpty { result.append(SharedAddress(address: value, contacts: others)) }
        }
        return result
    }

    /// Full numbers that `raw`, a phone number typed without its country code, could stand
    /// for: numbers on contact cards and in Messages whose national form it is, and numbers
    /// on cards that end with it (a local number typed without its area code), each with the
    /// cards that have it. The same digits can be a number in several places, so callers list
    /// every one and never pick.
    public func completeNumbers(for raw: String) -> [(address: Address, contacts: [Contact])] {
        let typed = Address(raw, region: region)
        guard typed.kind == .phone, let number = typed.phone, !number.isE164, number.nationalNumber.count >= 7 else { return [] }
        let digits = number.nationalNumber
        let cards = directory.contacts.flatMap { directory.addresses(of: $0) }
        // A number known only from excluded conversations is never offered: that would say
        // the conversation exists.
        let visible = Set(chats.filter { !excludedChatIDs.contains($0.id) }.flatMap { canonicalParticipants[$0.id] ?? [] })
        let hidden = Set(chats.filter { excludedChatIDs.contains($0.id) }.flatMap { canonicalParticipants[$0.id] ?? [] }).subtracting(visible)
        let known = knownAddresses.map { Address($0, region: region) }.filter { !hidden.contains($0.value) }
        let national = (cards + known).filter {
            $0.kind == .phone && ($0.phone?.nationalForms.contains(digits) ?? false)
        }
        let local = cards.filter { address in
            guard address.kind == .phone, let phone = address.phone, phone.isE164 else { return false }
            return phone.nationalNumber.count > digits.count && phone.nationalNumber.hasSuffix(digits)
        }
        var seen = Set<String>()
        return (national + local)
            .filter { seen.insert($0.value).inserted }
            .sorted()
            .map { ($0, directory.matches(for: $0.value).map(\.contact)) }
    }

    /// Canonical values of a person's addresses.
    public func canonicalAddresses(of person: Person) -> Set<String> {
        Set(person.addresses.map { Address($0, region: region).value })
    }

    /// One-to-one conversations with `person` across iMessage, SMS and RCS, in database order.
    public func directChats(with person: Person) -> [Chat] {
        let wanted = canonicalAddresses(of: person)
        return chats.filter { chat in
            guard chat.kind == .direct, !excludedChatIDs.contains(chat.id) else { return false }
            return (canonicalParticipants[chat.id] ?? []).allSatisfy { wanted.contains($0) }
        }
    }

    /// One-to-one conversations on one address, whoever's card has it, most recent first.
    public func directChats(onAddress raw: String) -> [Chat] {
        let wanted = Address(raw, region: region).value
        return chats.filter { chat in
            guard chat.kind == .direct, !excludedChatIDs.contains(chat.id) else { return false }
            return (canonicalParticipants[chat.id] ?? []).allSatisfy { $0 == wanted }
        }.sorted { (activity[$0.id] ?? .distantPast) > (activity[$1.id] ?? .distantPast) }
    }

    /// How many conversations, one-to-one and group, include `person`, and when the latest
    /// of them last had a message. Excluded conversations don't count.
    public func conversationActivity(of person: Person) -> (count: Int, lastActivity: Date?) {
        let conversations = directChats(with: person) + groupChats(with: person)
        return (conversations.count, conversations.compactMap { activity[$0.id] }.max())
    }

    /// Group conversations that include `person`.
    public func groupChats(with person: Person) -> [Chat] {
        let wanted = canonicalAddresses(of: person)
        return chats.filter { chat in
            chat.kind == .group && !excludedChatIDs.contains(chat.id)
                && (canonicalParticipants[chat.id] ?? []).contains { wanted.contains($0) }
        }
    }

    /// The display name for a sender address.
    public func name(for address: String?) -> String {
        guard let address else { return "You" }
        return directory.displayName(for: address)
    }

    /// A title for a conversation: its group name, the person's name, or participant names.
    public func title(for chat: Chat) -> String {
        if let name = chat.displayName { return name }
        let others = chat.participants.isEmpty ? [chat.identifier] : chat.participants
        if chat.kind == .direct, let only = others.first { return directory.displayName(for: only) }
        let names = shortNames(for: others)
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) others"
    }

    /// Short names for the people in one conversation, with full names for people who
    /// would otherwise share one (two Sams become Sam Lee and Sam Patel).
    public func shortNames(for addresses: [String]) -> [String] {
        // Count people, not addresses: one person's phone and email must not collide.
        var people: [String: Set<String>] = [:]
        for address in addresses {
            let person = directory.uniqueContact(for: address).map { "contact:\($0.id)" } ?? Address(address, region: region).value
            people[directory.shortName(for: address), default: []].insert(person)
        }
        return addresses.map { address in
            let short = directory.shortName(for: address)
            return (people[short]?.count ?? 0) > 1 ? directory.displayName(for: address) : short
        }
    }
}
