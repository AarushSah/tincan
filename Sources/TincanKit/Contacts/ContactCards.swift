import Foundation

/// Finds the one contact card a reference names, for commands that show or change a card:
/// `contact:<id>`, `me` (the card with your own Messages addresses), a number or email
/// (`address:<address>` too), or a name. No card, or several, stops with every candidate;
/// tincan never picks one. Refusals are `PlanRefusal`s.
public struct ContactCards {
    public let directory: Directory
    /// The region every address is read in.
    public let region: String?
    private let resolver: () -> Resolver?
    private let ownAddresses: () throws -> [String]

    /// `resolver` opens Messages, only when a number needs checking, and returns nil when
    /// Messages can't be read. `ownAddresses` reads your own Messages addresses, only for `me`.
    public init(directory: Directory, region: String?, resolver: @escaping () -> Resolver?, ownAddresses: @escaping () throws -> [String]) {
        self.directory = directory
        self.region = region
        self.resolver = resolver
        self.ownAddresses = ownAddresses
    }

    /// The one card `reference` names. `command` is the command hints suggest, such as
    /// `contacts show`.
    public func card(for reference: String, command: String) throws -> Contact {
        if reference.lowercased().hasPrefix("contact:") {
            guard let contact = directory.contact(id: String(reference.dropFirst(8))) else {
                throw PlanRefusal.issue(
                    PlanIssue(
                        code: "contact_not_found", message: "No contact has the reference \(reference).",
                        hint: "Find the card with `tincan contacts <name>`; references differ between Macs.", kind: .needsInput))
            }
            return contact
        }
        if reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "me" {
            return try ownCard(command: command)
        }
        // `address:<address>`, as `tincan exclude list` shows it, is that address.
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAddressReference = trimmed.lowercased().hasPrefix(Exclusion.addressPrefix)
        let address = isAddressReference ? String(trimmed.dropFirst(Exclusion.addressPrefix.count)).trimmingCharacters(in: .whitespaces) : reference
        if isAddressReference, !Resolver.looksLikeAddress(address) {
            throw PlanRefusal.issue(
                PlanIssue(
                    code: "not_found", message: "Nothing matches \"\(reference)\".",
                    hint: "Use address: with a phone number or email, such as address:<+number>.", kind: .needsInput))
        }
        if Resolver.looksLikeAddress(address) {
            // A number that names no line stops with its possible full numbers, as everywhere else.
            try Self.requireComplete(address, resolver: resolver(), region: region, command: command)
            let matches = directory.matches(for: address)
            if matches.count == 1 { return matches[0].contact }
            if matches.isEmpty {
                throw PlanRefusal.issue(
                    PlanIssue(
                        code: "not_found", message: "No contact has \(address).",
                        hint: "Create one with `tincan contacts add --name <name> --\(Address.isEmail(address) ? "email" : "phone") \(shellQuote(address))`.",
                        kind: .needsInput))
            }
            throw PlanRefusal.issue(
                PlanIssue(
                    code: "ambiguous", message: "\(address) is on \(matches.count) contact cards. Say which one:",
                    hint: "Ask the person which card they mean, then use its reference: `\(PlanIssue.example(command))`.", kind: .needsInput,
                    candidates: matches.map {
                        PlanIssue.Candidate(contact: $0.contact, detail: $0.contact.organization.isEmpty ? nil : $0.contact.organization, directory: directory)
                    }
                ))
        }
        let found = directory.search(name: reference)
        guard let best = found.first?.rank else {
            throw PlanRefusal.issue(
                PlanIssue(
                    code: "not_found", message: "No contact matches \"\(reference)\".",
                    hint: "List contacts with `tincan contacts`, or search by number or email.", kind: .needsInput))
        }
        // As ambiguous as the same name is everywhere else, so editing never picks a card
        // that sending would ask about.
        let top = found.filter { $0.rank <= Directory.cutoff(best: best, query: reference) }
        if top.count == 1 { return top[0].contact }
        throw PlanRefusal.issue(
            PlanIssue(
                code: "ambiguous", message: "\"\(reference)\" could mean \(top.count) contacts. Say which one:",
                hint: "Ask the person which one they mean, then use its reference: `\(PlanIssue.example(command))`.", kind: .needsInput,
                candidates: top.prefix(12).map { match in
                    PlanIssue.Candidate(
                        contact: match.contact, detail: match.contact.phones.first.map { Address($0.value, region: region).formatted }, directory: directory)
                }
            ))
    }

    /// Your card: the one card that has your own Messages addresses. Several stop with every
    /// candidate, and none with a hint, as for any other reference.
    private func ownCard(command: String) throws -> Contact {
        let own = try ownAddresses()
        var seen = Set<String>()
        let cards = own.flatMap { directory.matches(for: $0).map(\.contact) }.filter { seen.insert($0.id).inserted }
        if cards.count == 1 { return cards[0] }
        if cards.isEmpty {
            let addresses = Wording.list(own.prefix(3).map { Address($0, region: region).formatted })
            throw PlanRefusal.issue(
                PlanIssue(
                    code: "not_found", message: "No contact card has your Messages addresses (\(addresses)).",
                    hint: "Add them to your card in Contacts, or use its reference: `\(PlanIssue.example(command))`.", kind: .needsInput
                ))
        }
        throw PlanRefusal.issue(
            PlanIssue(
                code: "ambiguous", message: "Your Messages addresses are on \(cards.count) contact cards. Say which one:",
                hint: "Ask the person which card is theirs, then use its reference: `\(PlanIssue.example(command))`.", kind: .needsInput,
                candidates: cards.prefix(12).map {
                    PlanIssue.Candidate(contact: $0, detail: $0.organization.isEmpty ? nil : $0.organization, directory: directory)
                }
            ))
    }

    /// The `shared_address` warning for the card's numbers and emails that other cards have
    /// too, as `who` and `read` say, so a number read off one card isn't taken for that
    /// person's alone. Nil when no other card has any of them.
    public func sharedAddressWarning(for contact: Contact) -> PlanWarning? {
        var parts: [String] = []
        var seen = Set<String>()
        for raw in contact.phones.map(\.value) + contact.emails.map(\.value) {
            let address = Address(raw, region: region)
            guard seen.insert(address.value).inserted else { continue }
            let others = directory.matches(for: raw).map(\.contact).filter { $0.id != contact.id }
            guard !others.isEmpty else { continue }
            parts.append("\(address.formatted) with " + Wording.list(others.map { "\($0.displayName) (contact:\($0.id))" }))
        }
        guard !parts.isEmpty else { return nil }
        return .notice(
            code: "shared_address",
            message:
                "\(contact.displayName) shares \(Wording.list(parts)). tincan can't tell which of them a message or call on \(parts.count == 1 ? "it" : "those") is from."
        )
    }

    /// Refuses a phone number that names no line; see `Resolver.requireComplete`. Without
    /// Messages, only the digits decide.
    static func requireComplete(_ raw: String, resolver: Resolver?, region: String?, command: String) throws {
        if let resolver {
            do { try resolver.requireComplete(raw) } catch let error as ResolveError { throw PlanRefusal.unresolved(error, command: command) }
            return
        }
        let address = Address(raw, region: region)
        let tooShort = address.kind != .email && raw.filter(\.isNumber).count < 5
        if tooShort || address.lacksCountryCode {
            throw PlanRefusal.unresolved(.incompleteNumber(query: raw, tooShort: tooShort, options: []), command: command)
        }
    }
}
