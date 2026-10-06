import Foundation

/// Decides what `contacts add` and `contacts edit` change before anything reaches Contacts:
/// the new card's fields, the edits to an existing card, and what the person should know
/// first. A number or email that another card already has stops a new card until the person
/// confirms they want a second one; the same name only warns, since two people can share a
/// name. Removing a number or email and adding it back relabels it instead of deleting it.
/// Refusals are `PlanRefusal`s and warnings `PlanWarning`s, as data.
public struct ContactEditPlanner {
    /// A new card's fields as the command line gives them. Phones and emails take an
    /// optional label: `mobile:+14155550142`, `work:maya@example.com`.
    public struct NewCard: Sendable {
        /// The full name; the last word becomes the family name.
        public var name: String?
        public var first: String?
        public var last: String?
        public var nickname: String?
        public var organization: String?
        public var jobTitle: String?
        public var phones: [String]
        public var emails: [String]
        /// `YYYY-MM-DD`, or `MM-DD` without a year.
        public var birthday: String?

        public init(
            name: String? = nil, first: String? = nil, last: String? = nil, nickname: String? = nil, organization: String? = nil,
            jobTitle: String? = nil, phones: [String] = [], emails: [String] = [], birthday: String? = nil
        ) {
            self.name = name
            self.first = first
            self.last = last
            self.nickname = nickname
            self.organization = organization
            self.jobTitle = jobTitle
            self.phones = phones
            self.emails = emails
            self.birthday = birthday
        }
    }

    /// Changes to a card as the command line gives them: nil leaves a field as it is, and an
    /// empty value clears it. Added numbers and emails take an optional label; removed ones
    /// match however they are formatted.
    public struct Changes: Sendable {
        public var first: String?
        public var middle: String?
        public var last: String?
        public var nickname: String?
        public var organization: String?
        public var jobTitle: String?
        public var birthday: String?
        public var addPhones: [String]
        public var removePhones: [String]
        public var addEmails: [String]
        public var removeEmails: [String]

        public init(
            first: String? = nil, middle: String? = nil, last: String? = nil, nickname: String? = nil, organization: String? = nil,
            jobTitle: String? = nil, birthday: String? = nil, addPhones: [String] = [], removePhones: [String] = [], addEmails: [String] = [],
            removeEmails: [String] = []
        ) {
            self.first = first
            self.middle = middle
            self.last = last
            self.nickname = nickname
            self.organization = organization
            self.jobTitle = jobTitle
            self.birthday = birthday
            self.addPhones = addPhones
            self.removePhones = removePhones
            self.addEmails = addEmails
            self.removeEmails = removeEmails
        }
    }

    /// What `contacts add` creates.
    public struct AddPlan: Sendable {
        public let draft: ContactDraft
        /// The card as it would be saved, with default labels, for a preview.
        public let preview: Contact
    }

    /// What `contacts edit` does to a card.
    public struct EditPlan: Sendable {
        /// In order: fields, removals, then additions, so a number removed and added back is
        /// relabeled rather than deleted.
        public let edits: [ContactEdit]
        /// Each change for people: `nickname → Mayo`, `remove phone +14155550142`.
        public let changes: [String]
        /// Canonical numbers and emails that leave the card.
        public let removed: [String]
    }

    /// A removed number or email and the conversations that use it, most recent first. They
    /// name this person through it today.
    public struct AddressInUse: Sendable {
        public struct Conversation: Sendable {
            /// `chat:<id>`.
            public let ref: String
            public let name: String
        }

        public let address: String
        public let conversations: [Conversation]
    }

    public let directory: Directory
    /// The region every address is read in.
    public let region: String?
    private let resolver: () -> Resolver?

    /// `resolver` opens Messages, only when an added number needs checking, and returns nil
    /// when Messages can't be read: then only the number's digits decide.
    public init(directory: Directory, region: String?, resolver: @escaping () -> Resolver?) {
        self.directory = directory
        self.region = region
        self.resolver = resolver
    }

    // MARK: Adding a card

    /// A new card's fields, each checked: numbers, emails and the birthday must be what they
    /// say, and the card needs a name, company, number or email. Needs no data, so it runs
    /// before Contacts is opened.
    public static func draft(_ card: NewCard, region: String?) throws -> ContactDraft {
        var draft = ContactDraft()
        if let name = card.name {
            let words = name.split(separator: " ").map(String.init)
            if words.count > 1 {
                draft.givenName = words.dropLast().joined(separator: " ")
                draft.familyName = words.last ?? ""
            } else {
                draft.givenName = name
            }
        }
        if let first = card.first { draft.givenName = first }
        if let last = card.last { draft.familyName = last }
        draft.nickname = card.nickname ?? ""
        draft.organization = card.organization ?? ""
        draft.jobTitle = card.jobTitle ?? ""
        draft.phones = try card.phones.map { value in
            let (label, number) = splitLabel(value)
            guard PhoneNumber.parse(number, region: region) != nil else {
                throw PlanRefusal.issue(
                    .invalidInput("\"\(number)\" is not a phone number.", hint: "Use digits with an optional label, such as mobile:+14155550142."))
            }
            return Contact.Phone(label: label, value: number, normalized: nil)
        }
        draft.emails = try card.emails.map { value in
            let (label, address) = splitLabel(value)
            guard Address.isEmail(address) else {
                throw PlanRefusal.issue(
                    .invalidInput("\"\(address)\" is not an email address.", hint: "Use an address with an optional label, such as work:maya@example.com."))
            }
            return Contact.Email(label: label, value: address)
        }
        if let birthday = card.birthday {
            guard BirthdayText.components(birthday) != nil else { throw PlanRefusal.issue(invalidBirthday(birthday)) }
            draft.birthday = birthday
        }
        guard !draft.isEmpty else {
            throw PlanRefusal.issue(
                .invalidInput(
                    "A contact needs a name, company, phone number or email.",
                    hint: "For example: `tincan contacts add --name \"Maya Chen\" --phone +14155550142`."))
        }
        return draft
    }

    /// Plans adding `draft`. Every number must name a line, and no number or email may be
    /// given twice. A number or email another card has refuses the card unless
    /// `allowDuplicate`, and then warns; a card with the same name warns.
    public func add(_ draft: ContactDraft, allowDuplicate: Bool, warnings: inout [PlanWarning]) throws -> AddPlan {
        for phone in draft.phones { try ContactCards.requireComplete(phone.value, resolver: resolver(), region: region, command: "contacts add --phone") }
        try Self.refuseRepeats(draft.phones.map(\.value), draft.emails.map(\.value), region: region)
        // Cards that already have one of these numbers or emails.
        var duplicates: [Contact] = []
        var matched = (phones: 0, emails: 0)
        for (value, isPhone) in draft.phones.map({ ($0.value, true) }) + draft.emails.map({ ($0.value, false) }) {
            let cards = directory.matches(for: value).map(\.contact)
            guard !cards.isEmpty else { continue }
            if isPhone { matched.phones += 1 } else { matched.emails += 1 }
            for card in cards where !duplicates.contains(where: { $0.id == card.id }) { duplicates.append(card) }
        }
        if !duplicates.isEmpty {
            let taken = Self.alreadyTaken(cards: duplicates.count, phones: matched.phones, emails: matched.emails)
            guard allowDuplicate else {
                throw PlanRefusal.issue(
                    PlanIssue(
                        code: "duplicate_contact",
                        message: taken + ":",
                        hint:
                            "Ask the person whether to edit \(duplicates.count == 1 ? "that card" : "one of those cards") instead: `tincan contacts edit <reference> …`. Pass --allow-duplicate only after they confirm they want another card.",
                        kind: .needsInput,
                        candidates: duplicates.map { card in
                            PlanIssue.Candidate(
                                contact: card,
                                detail: card.phones.first.map { Address($0.value, region: region).formatted } ?? card.emails.first?.value,
                                directory: directory
                            )
                        }
                    ))
            }
            let cards = Wording.list(duplicates.map { "\($0.displayName) (contact:\($0.id))" })
            warnings.append(.notice(code: "duplicate_contact", message: "\(taken): \(cards). With --allow-duplicate, tincan adds another card anyway."))
        }
        // Two people can share a name, so a same-named card is reported, not refused.
        let fullName = [draft.givenName, draft.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !fullName.isEmpty {
            let sameName = directory.search(name: fullName).filter { $0.rank == 0 }.map(\.contact)
            if !sameName.isEmpty {
                let references = sameName.map { "contact:\($0.id)" }.joined(separator: ", ")
                warnings.append(
                    .notice(
                        code: "same_name_exists",
                        message:
                            "\(sameName.count == 1 ? "A card" : "\(sameName.count) cards") named \(fullName) already exist\(sameName.count == 1 ? "s" : ""): \(references). Check \(sameName.count == 1 ? "it isn't" : "none of them is") the same person before adding another."
                    ))
            }
        }
        let preview = Contact(
            id: "new", givenName: draft.givenName, familyName: draft.familyName, nickname: draft.nickname,
            organization: draft.organization, jobTitle: draft.jobTitle,
            isOrganization: draft.givenName.isEmpty && draft.familyName.isEmpty && !draft.organization.isEmpty,
            phones: draft.phones.map { Contact.Phone(label: $0.label ?? "mobile", value: $0.value, normalized: nil) },
            emails: draft.emails.map { Contact.Email(label: $0.label ?? "home", value: $0.value) },
            birthday: draft.birthday
        )
        return AddPlan(draft: draft, preview: preview)
    }

    /// "A card already has this number", "2 cards already have these numbers and emails".
    static func alreadyTaken(cards: Int, phones: Int, emails: Int) -> String {
        let subject = cards == 1 ? "A card already has" : "\(cards) cards already have"
        let things: String
        switch (phones, emails) {
        case (_, 0): things = phones == 1 ? "this number" : "these numbers"
        case (0, _): things = emails == 1 ? "this email" : "these emails"
        default: things = "these numbers and emails"
        }
        return subject + " " + things
    }

    // MARK: Editing a card

    /// Plans `requested` on `contact`. A number or email to remove must be on the card, one
    /// to add must not be (unless it is removed too, which relabels it), and each added
    /// number must name a line. An added address that other cards have too is allowed, with
    /// a warning, since tincan then can't tell which card a message on it is from. Warnings
    /// are added to `warnings` as they are found, even when planning then stops.
    public func edit(_ contact: Contact, _ requested: Changes, warnings: inout [PlanWarning]) throws -> EditPlan {
        var edits: [ContactEdit] = []
        var changes: [String] = []
        func set(_ value: String?, _ label: String, _ make: (String) -> ContactEdit) {
            guard let value else { return }
            edits.append(make(value))
            changes.append(value.isEmpty ? "clear \(label)" : "\(label) → \(value)")
        }
        /// An added number or email that other cards have too: a family line, a shared
        /// work phone or a duplicate. Allowed, and said, since tincan then can't tell
        /// which card a message on it is from.
        func warnShared(_ value: String) {
            let others = directory.matches(for: value).map(\.contact).filter { $0.id != contact.id }
            guard !others.isEmpty else { return }
            let cards = Wording.list(others.map { "\($0.displayName) (contact:\($0.id))" })
            warnings.append(
                .notice(
                    code: "shared_address",
                    message: "\(Address(value, region: region).formatted) is also on \(cards). tincan can't tell which of them a message or call on it is from."
                ))
        }
        set(requested.first, "first name", ContactEdit.setGivenName)
        set(requested.middle, "middle name", ContactEdit.setMiddleName)
        set(requested.last, "last name", ContactEdit.setFamilyName)
        set(requested.nickname, "nickname", ContactEdit.setNickname)
        set(requested.organization, "company", ContactEdit.setOrganization)
        set(requested.jobTitle, "job title", ContactEdit.setJobTitle)
        if let birthday = requested.birthday {
            if birthday.isEmpty {
                edits.append(.setBirthday(nil))
                changes.append("clear birthday")
            } else {
                guard BirthdayText.components(birthday) != nil else { throw PlanRefusal.issue(Self.invalidBirthday(birthday)) }
                edits.append(.setBirthday(birthday))
                changes.append("birthday → \(birthday)")
            }
        }
        var removed: [String] = []
        for number in requested.removePhones {
            let target = PhoneNumber.parse(number, region: region)
            let stored = contact.phones.filter { stored in
                guard let target, let parsed = PhoneNumber.parse(stored.value, region: region) else { return stored.value == number }
                return parsed.isSameEntry(target)
            }
            removed += stored.map { Address($0.value, region: region).value }
            guard !stored.isEmpty else {
                throw PlanRefusal.issue(
                    .invalidInput(
                        "\(contact.displayName) has no phone number \(number).",
                        hint: "See the card's numbers with `tincan contacts show \(shellQuote("contact:" + contact.id))`."))
            }
            edits.append(.removePhone(number))
            // The card can hold the same number more than once; each copy goes.
            changes.append("remove phone \(number)" + (stored.count > 1 ? " (\(stored.count) entries)" : ""))
        }
        for address in requested.removeEmails {
            guard contact.emails.contains(where: { $0.value.caseInsensitiveCompare(address) == .orderedSame }) else {
                throw PlanRefusal.issue(
                    .invalidInput(
                        "\(contact.displayName) has no email \(address).",
                        hint: "See the card's emails with `tincan contacts show \(shellQuote("contact:" + contact.id))`."))
            }
            edits.append(.removeEmail(address))
            changes.append("remove email \(address)")
            removed.append(Address(address, region: region).value)
        }
        // Additions after removals, so removing a number or email and adding it back
        // with another label relabels it instead of deleting it.
        try Self.refuseRepeats(requested.addPhones.map { Self.splitLabel($0).1 }, requested.addEmails.map { Self.splitLabel($0).1 }, region: region)
        for value in requested.addPhones {
            let (label, number) = Self.splitLabel(value)
            guard PhoneNumber.parse(number, region: region) != nil else {
                throw PlanRefusal.issue(
                    .invalidInput("\"\(number)\" is not a phone number.", hint: "Use digits with an optional label, such as work:+14155550199."))
            }
            try ContactCards.requireComplete(number, resolver: resolver(), region: region, command: "contacts edit --add-phone")
            // A second copy of a number the card keeps is a duplicate entry, not a change.
            let target = PhoneNumber.parse(number, region: region)
            let kept = contact.phones.filter { stored in
                guard let target, let parsed = PhoneNumber.parse(stored.value, region: region), parsed.isSameEntry(target) else { return false }
                return !edits.contains { edit in
                    guard case .removePhone(let removed) = edit, let gone = PhoneNumber.parse(removed, region: region) else { return false }
                    return gone.isSameEntry(parsed)
                }
            }
            if let existing = kept.first {
                throw PlanRefusal.issue(
                    .invalidInput(
                        "\(contact.displayName) already has \(existing.value)\(existing.label.map { " (\($0))" } ?? "").",
                        hint:
                            "To change its label, remove it and add it back: `tincan contacts edit \(shellQuote("contact:" + contact.id)) --remove-phone <number> --add-phone <label>:<number>`."
                    ))
            }
            warnShared(number)
            // A relabeled number keeps the way the card wrote it.
            let relabeled = contact.phones.first { stored in
                guard let target, let parsed = PhoneNumber.parse(stored.value, region: region) else { return false }
                return parsed.isSameEntry(target)
            }?.value
            edits.append(.addPhone(label: label, value: relabeled ?? number))
            changes.append("add phone \(number)\(label.map { " (\($0))" } ?? "")")
        }
        for value in requested.addEmails {
            let (label, address) = Self.splitLabel(value)
            guard Address.isEmail(address) else {
                throw PlanRefusal.issue(
                    .invalidInput("\"\(address)\" is not an email address.", hint: "Use an address with an optional label, such as work:maya@example.com."))
            }
            let removing = requested.removeEmails.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
            if !removing, let existing = contact.emails.first(where: { $0.value.caseInsensitiveCompare(address) == .orderedSame }) {
                throw PlanRefusal.issue(
                    .invalidInput(
                        "\(contact.displayName) already has \(existing.value)\(existing.label.map { " (\($0))" } ?? "").",
                        hint:
                            "To change its label, remove it and add it back: `tincan contacts edit \(shellQuote("contact:" + contact.id)) --remove-email <email> --add-email <label>:<email>`."
                    ))
            }
            warnShared(address)
            let relabeled = contact.emails.first { $0.value.caseInsensitiveCompare(address) == .orderedSame }?.value
            edits.append(.addEmail(label: label, value: relabeled ?? address))
            changes.append("add email \(address)\(label.map { " (\($0))" } ?? "")")
        }
        // A number or email added back isn't leaving the card.
        let kept = Set(
            requested.addPhones.map { Address(Self.splitLabel($0).1, region: region).value }
                + requested.addEmails.map { Address(Self.splitLabel($0).1, region: region).value })
        removed.removeAll { kept.contains($0) }
        guard !edits.isEmpty else {
            throw PlanRefusal.issue(
                .invalidInput("Nothing to change.", hint: "Pass the fields to change, for example --nickname Mayo. See `tincan contacts edit --help`."))
        }
        return EditPlan(edits: edits, changes: changes, removed: removed)
    }

    /// Conversations that use each of `removed`, most recent first, with an `address_in_use`
    /// warning that names them: after the change they no longer name this person through it.
    /// Nil when none does.
    public func addressesInUse(_ removed: [String], of contact: Contact, resolver: Resolver, warnings: inout [PlanWarning]) -> [AddressInUse]? {
        let activity = resolver.activity
        var seen = Set<String>()
        let result: [AddressInUse] = removed.filter { seen.insert($0).inserted }.compactMap { address in
            let chats = resolver.chats.filter { chat in
                guard !resolver.excludedChatIDs.contains(chat.id) else { return false }
                let others = chat.participants.isEmpty ? [chat.identifier] : chat.participants
                return others.contains { Address($0, region: region).value == address }
            }.sorted { (activity[$0.id] ?? .distantPast) > (activity[$1.id] ?? .distantPast) }
            guard !chats.isEmpty else { return nil }
            return AddressInUse(address: address, conversations: chats.map { .init(ref: $0.reference, name: resolver.title(for: $0)) })
        }
        guard !result.isEmpty else { return nil }
        let parts = result.map { entry -> String in
            let shown = entry.conversations.prefix(5).map { "\($0.name) (\($0.ref))" }
            let more = entry.conversations.count - shown.count
            return "\(Address(entry.address, region: region).formatted) is used in \(Wording.plural(entry.conversations.count, "conversation")): "
                + Wording.list(shown + (more > 0 ? ["\(more) more"] : []))
        }
        warnings.append(
            .notice(
                code: "address_in_use",
                message: parts.joined(separator: "; ")
                    + ". Removing \(result.count == 1 ? "it" : "them") from \(contact.displayName)'s card changes who tincan and Messages say those messages are from."
            ))
        return result
    }

    // MARK: Values

    /// `mobile:+1…` → ("mobile", "+1…"). URL schemes are not labels.
    static func splitLabel(_ value: String) -> (String?, String) {
        guard let colon = value.firstIndex(of: ":") else { return (nil, value.trimmingCharacters(in: .whitespaces)) }
        let label = value[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if ["tel", "mailto", "sms", "imessage"].contains(label.lowercased()) { return (nil, rest) }
        return (label.isEmpty ? nil : label, rest)
    }

    /// Refuses a number or email given twice in one command, in any format or case: the card
    /// would end up with two copies of it.
    static func refuseRepeats(_ phones: [String], _ emails: [String], region: String?) throws {
        var numbers: [PhoneNumber] = []
        for value in phones {
            guard let number = PhoneNumber.parse(value, region: region) else { continue }
            if numbers.contains(where: { $0.isSameEntry(number) }) {
                throw PlanRefusal.issue(.invalidInput("\(value) is given twice.", hint: "Give each number once, with the label it should have."))
            }
            numbers.append(number)
        }
        var seen = Set<String>()
        for value in emails where !seen.insert(value.lowercased()).inserted {
            throw PlanRefusal.issue(.invalidInput("\(value) is given twice.", hint: "Give each email once, with the label it should have."))
        }
    }

    static func invalidBirthday(_ text: String) -> PlanIssue {
        .invalidInput("--birthday \"\(text)\" is not a date.", hint: "Use YYYY-MM-DD, or MM-DD without a year.")
    }
}
