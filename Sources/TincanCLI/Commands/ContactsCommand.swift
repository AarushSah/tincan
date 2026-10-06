import ArgumentParser
import Foundation
import TincanKit

struct ContactsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Find, show, add and edit contacts in Apple Contacts.",
        discussion: """
            Changes go through Apple Contacts and sync like any other edit. Before changing a card, tincan saves a vCard copy of it in ~/Library/Application Support/tincan/backups.

            Without a terminal, or with --json, add and edit change nothing unless you pass --yes.

            Examples:
              tincan contacts Maya
              tincan contacts show Maya
              tincan contacts add --name "Maya Chen" --phone mobile:+14155550142 --dry-run
              tincan contacts edit Maya --add-email work:maya.chen@example.com --dry-run
            """,
        subcommands: [Find.self, Show.self, Add.self, Edit.self, Duplicates.self],
        defaultSubcommand: Find.self
    )

    struct Find: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search contacts by name, nickname, company, number or email.",
            discussion: """
                `tincan contacts <query>` is short for `tincan contacts find <query>`.

                Examples:
                  tincan contacts find maya
                  tincan contacts find "+1 415 555 0142"
                  tincan contacts find --limit 100
                """
        )

        @Argument(help: "Text to look for. Omit to list everyone.")
        var query: String?

        @Option(name: [.customShort("n"), .long], help: "Maximum number of contacts.")
        var limit: Int = 25

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("contacts find", options: global) { context in
                try requireLimit(limit)
                let directory = try context.directory(requireContacts: true)
                var contacts: [Contact]
                if let query, Resolver.looksLikeAddress(query) {
                    contacts = directory.matches(for: query).map(\.contact)
                    // A number typed without its area or country code (7 digits or more) finds
                    // the cards whose numbers end with it.
                    if Address(query, region: context.region).lacksCountryCode, let digits = PhoneNumber.parse(query, region: context.region)?.nationalNumber,
                        digits.count >= 7
                    {
                        for contact in directory.contacts where !contacts.contains(where: { $0.id == contact.id }) {
                            if contact.phones.contains(where: {
                                PhoneNumber.parse($0.value, region: context.region)?.nationalNumber.hasSuffix(digits) ?? false
                            }) {
                                contacts.append(contact)
                            }
                        }
                    }
                } else if let query {
                    contacts = directory.search(name: query).map(\.contact)
                } else {
                    contacts = directory.contacts
                }
                let total = contacts.count
                contacts = Array(contacts.prefix(limit))
                if total > contacts.count { context.output.warnTruncated(contacts.count, "contact", limit: limit) }
                context.output.result(contacts.map(Payload.contact))
                guard !context.output.json else { return }
                let style = context.style
                if contacts.isEmpty {
                    context.output.line(style.muted(query.map { "No contacts match “\($0)”." } ?? "No contacts yet."))
                    let next =
                        query == nil
                        ? "Add one with `tincan contacts add --name <name> --phone <number> --dry-run`."
                        : "Try part of a name, a number or an email. `tincan contacts` lists everyone."
                    for line in TextWidth.wrapKeepingCode(next, width: min(context.terminal.width, 100)) { context.output.hint(line) }
                    return
                }
                let width = min(context.terminal.width, 120)
                let region = context.region
                let rows = contacts.map { contact -> (name: String, details: [String], detail: String, reference: String) in
                    let reach = (contact.phones.first.map { Address($0.value, region: region).formatted } ?? contact.emails.first?.value) ?? ""
                    var extra = [reach]
                    if !contact.organization.isEmpty, !contact.isOrganization { extra.append(contact.organization) }
                    // Not "+1", which reads as a country code next to a number.
                    let more = contact.phones.count + contact.emails.count - 1
                    if more > 0 { extra.append("\(more) more") }
                    extra = extra.filter { !$0.isEmpty }
                    return (contact.displayName, extra, extra.joined(separator: " · "), "contact:\(contact.id)")
                }
                let referenceWidth = rows.map { TextWidth.columns($0.reference) }.max() ?? 0
                let nameWidth = min(28, max(10, width / 3), rows.map { TextWidth.columns($0.name) }.max() ?? 10)
                let widestDetail = rows.map { TextWidth.columns($0.detail) }.max() ?? 0
                let detailWidth = min(40, widestDetail, width - nameWidth - 2 - 2 - referenceWidth)
                // References are long; they go on their own line when a row can't hold them
                // beside a useful amount of detail.
                let inline = detailWidth >= min(widestDetail, 16)
                for row in rows {
                    let name = TextWidth.fit(row.name, to: nameWidth)
                    if inline {
                        context.output.line(
                            name + "  " + style.muted(TextWidth.padRight(Layout.fitting(row.details, separator: " · ", width: detailWidth), to: detailWidth))
                                + "  " + style.muted(row.reference))
                    } else {
                        let detail = Layout.fitting(row.details, separator: " · ", width: max(8, width - nameWidth - 2))
                        context.output.line(detail.isEmpty ? TextWidth.truncate(row.name, to: width) : name + "  " + style.muted(detail))
                        context.output.line("  " + style.muted(row.reference))
                    }
                }
                if total > contacts.count { context.output.hint("… \(total - contacts.count) more. Use --limit \(total) to see them all.") }
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a contact card.",
            discussion: """
                Examples:
                  tincan contacts show Maya
                  tincan contacts show +14155550142 --json
                """
        )

        @Argument(help: ArgumentHelp(Help.person, valueName: "who"))
        var who: String

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("contacts show", options: global) { context in
                let cards = try ContactsCommand.cards(context)
                let contact = try context.plan { _ in try cards.card(for: who, command: "contacts show") }
                if let warning = cards.sharedAddressWarning(for: contact) { context.warn([warning]) }
                context.output.result(Payload.contact(contact))
                guard !context.output.json else { return }
                render(contact, context: context)
            }
        }
    }

    /// Finds cards by reference in Contacts, opening Messages only for `me` and to check a number.
    static func cards(_ context: Context) throws -> ContactCards {
        ContactCards(
            directory: try context.directory(requireContacts: true), region: context.region,
            resolver: { try? context.resolver() }, ownAddresses: { try context.me().addresses }
        )
    }

    /// Plans changes to cards in Contacts, opening Messages only to check a number.
    static func planner(_ context: Context) throws -> ContactEditPlanner {
        ContactEditPlanner(directory: try context.directory(requireContacts: true), region: context.region, resolver: { try? context.resolver() })
    }

    struct Duplicates: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List cards that share a number or email, or have the same name.",
            discussion: """
                Two cards with one number can be a duplicate, a family line or a shared work phone; two cards with one name can be one person or two. tincan shows the evidence and never merges or picks: while an address is on several cards, tincan shows the address instead of a name and lists every card it could be. Each card shows how many conversations use its numbers and emails, and when the latest last had a message.

                To merge real duplicates, use Contacts → Card → Look for Duplicates. To remove a number from the wrong card, run `tincan contacts edit contact:<id> --remove-phone <number>`.

                Examples:
                  tincan contacts duplicates
                  tincan contacts duplicates --json
                """
        )

        @OptionGroup var global: GlobalOptions

        struct Group: Encodable {
            let kind: String
            let namesMatch: Bool
            let sharedAddresses: [String]
            let cards: [Payload.Contact]
        }

        func run() async throws {
            try await runCommand("contacts duplicates", options: global) { context in
                let directory = try context.directory(requireContacts: true)
                let groups = directory.contactGroups()
                // How much each card is used helps the person decide; tincan never picks one.
                let resolver: Resolver?
                do {
                    resolver = try context.resolver(requireContacts: true)
                } catch let error as TincanError where ["full_disk_access_required", "messages_missing"].contains(error.code) {
                    // The cards are still worth listing without Messages.
                    context.output.warn(
                        "messages_unavailable", "Cards show no conversations or last activity: \(TincanError.sentence(error.message)) \(error.hint)")
                    resolver = nil
                }
                func card(_ contact: Contact) -> Payload.Contact {
                    var card = Payload.contact(contact)
                    if let resolver {
                        let activity = resolver.conversationActivity(of: resolver.person(for: contact))
                        card.conversations = activity.count
                        card.lastActivity = activity.lastActivity
                    }
                    return card
                }
                let cards = Dictionary(groups.flatMap(\.contacts).map { ($0.id, card($0)) }, uniquingKeysWith: { first, _ in first })
                context.output.result(
                    groups.map { group in
                        Group(
                            kind: group.kind.rawValue, namesMatch: group.namesMatch, sharedAddresses: group.sharedAddresses,
                            cards: group.contacts.compactMap { cards[$0.id] })
                    })
                guard !context.output.json else { return }
                let style = context.style
                let output = context.output
                let shared = groups.filter { $0.kind == .sharedAddress }
                let usages = cards.mapValues { card -> String in
                    guard let count = card.conversations else { return "" }
                    guard count > 0 else { return "no conversations" }
                    return Formatting.plural(count, "conversation") + (card.lastActivity.map { ", last " + Formatting.relative($0) } ?? "")
                }
                let usageWidth = usages.values.map(TextWidth.columns).max() ?? 0
                let referenceWidth = groups.flatMap(\.contacts).map { TextWidth.columns("contact:\($0.id)") }.max() ?? 0
                /// A card's row: its label, conversations and last activity, and reference. The
                /// facts are a column when they fit beside the reference, otherwise a line of their own.
                func row(_ label: String, _ id: String, width: Int) {
                    let name = "    " + TextWidth.fit(label, to: width)
                    let reference = "  " + style.muted("contact:\(id)")
                    guard usageWidth > 0, let usage = usages[id] else { return output.line(name + reference) }
                    if 4 + width + 2 + usageWidth + 2 + referenceWidth <= context.terminal.width {
                        output.line(name + "  " + style.muted(TextWidth.padRight(usage, to: usageWidth)) + reference)
                    } else {
                        output.line(name + reference)
                        output.line("      " + style.muted(usage))
                    }
                }
                let sameName = groups.filter { $0.kind == .sameName }
                if groups.isEmpty {
                    output.line(style.muted("No cards share a number, an email or a name."))
                    return
                }
                // Card columns as wide as the longest entry, up to 28, so references sit close.
                let nameWidth = min(28, shared.flatMap(\.contacts).map { TextWidth.columns($0.displayName) }.max() ?? 0)
                func reach(_ card: Contact) -> String {
                    card.phones.first.map { Address($0.value, region: context.region).formatted } ?? card.emails.first?.value ?? "no number or email"
                }
                let reachWidth = min(28, sameName.flatMap(\.contacts).map { TextWidth.columns(reach($0)) }.max() ?? 0)
                if !shared.isEmpty {
                    output.line(style.accent("Cards that share a number or email") + style.muted("  \(shared.count)"))
                    for group in shared {
                        let addresses = group.sharedAddresses.map { Address($0, region: context.region).formatted }.joined(separator: ", ")
                        let verdict = group.namesMatch ? style.muted("same name, likely duplicates") : style.muted("different names")
                        output.line("  " + style.bold(addresses) + "  " + verdict)
                        for card in group.contacts {
                            row(card.displayName, card.id, width: nameWidth)
                        }
                    }
                }
                if !sameName.isEmpty {
                    if !shared.isEmpty { output.line() }
                    output.line(style.accent("Cards with the same name") + style.muted("  \(sameName.count)"))
                    for group in sameName {
                        output.line(
                            "  " + style.bold(group.contacts.first?.displayName ?? "")
                                + style.muted("  \(group.contacts.count) cards, no number or email in common"))
                        for card in group.contacts {
                            row(reach(card), card.id, width: reachWidth)
                        }
                    }
                }
                output.hint()
                for line in TextWidth.wrap(
                    "tincan never merges cards. Merge duplicates in Contacts → Card → Look for Duplicates.", width: min(context.terminal.width, 100))
                {
                    output.hint(line)
                }
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a contact.",
            discussion: """
                Phones and emails take an optional label: mobile:+14155550142, work:maya@example.com. tincan refuses to create a second card for a number or email that already has one; --allow-duplicate creates it anyway, once the person confirms they want a second card. In a terminal it asks before saving; without one, or with --json, it needs --yes.

                Examples:
                  tincan contacts add --name "Maya Chen" --phone mobile:+14155550142 --dry-run
                  tincan contacts add --first Sam --last Park --email sam@example.com --yes
                  tincan contacts add --org Northwind --phone +14155550100 --dry-run --json
                """
        )

        @Option(help: "Full name; the last word becomes the family name.")
        var name: String?
        @Option(help: "Given (first) name.")
        var first: String?
        @Option(help: "Family (last) name.")
        var last: String?
        @Option(help: "Nickname.")
        var nickname: String?
        @Option(help: "Company or organization.")
        var org: String?
        @Option(help: "Job title.")
        var title: String?
        @Option(help: ArgumentHelp("Phone number, optionally labeled: mobile:+14155550142. Repeatable.", valueName: "number"))
        var phone: [String] = []
        @Option(help: ArgumentHelp("Email address, optionally labeled: work:maya@example.com. Repeatable.", valueName: "email"))
        var email: [String] = []
        @Option(help: ArgumentHelp("Birthday: YYYY-MM-DD, or MM-DD without a year.", valueName: "date"))
        var birthday: String?
        @Flag(help: "Create the card even if another contact already has one of these numbers or emails.")
        var allowDuplicate = false
        @Flag(help: "Show what would be created without saving.")
        var dryRun = false
        @Flag(name: .shortAndLong, help: "Save without asking. Required when there's no terminal to ask in (scripts and assistants).")
        var yes = false

        @OptionGroup var global: GlobalOptions

        struct Result: Encodable {
            let contact: Payload.Contact
            let dryRun: Bool?
        }

        func run() async throws {
            try await runCommand("contacts add", options: global) { context in
                let fields = ContactEditPlanner.NewCard(
                    name: name, first: first, last: last, nickname: nickname, organization: org, jobTitle: title,
                    phones: phone, emails: email, birthday: birthday
                )
                let draft = try context.plan { _ in try ContactEditPlanner.draft(fields, region: context.region) }
                let planner = try ContactsCommand.planner(context)
                let preview = try context.plan { warnings in try planner.add(draft, allowDuplicate: allowDuplicate, warnings: &warnings) }.preview
                if dryRun {
                    context.output.result(Result(contact: Payload.contact(preview), dryRun: true))
                    if !context.output.json {
                        context.output.line(context.style.muted("Would create:"))
                        render(preview, context: context)
                        context.output.line(context.style.muted("Dry run: nothing was saved."))
                    }
                    return
                }
                try confirmChange(
                    yes: yes, context: context,
                    preview: {
                        render(preview, context: context)
                    }, question: "Create this contact?")
                let created = try context.contactsProvider().create(draft)
                context.output.result(Result(contact: Payload.contact(created), dryRun: nil))
                if !context.output.json {
                    context.output.line(
                        context.style.success("✓ ") + "Created " + context.style.bold(created.displayName) + context.style.muted("  contact:\(created.id)"))
                }
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a contact.",
            discussion: """
                Only the fields you pass change. Pass an empty value to clear a field: --nickname "". A vCard copy of the card is saved before the change. Removing a number or email that conversations use warns and lists them. In a terminal it asks before saving; without one, or with --json, it needs --yes.

                Examples:
                  tincan contacts edit Maya --nickname Mayo --dry-run
                  tincan contacts edit Maya --add-phone work:+14155550199 --dry-run --json
                  tincan contacts edit contact:ABC --remove-phone +14155550100 --yes
                  tincan contacts edit Maya --birthday 03-04 --dry-run
                """
        )

        @Argument(help: ArgumentHelp(Help.person, valueName: "who"))
        var who: String

        @Option(help: "Given (first) name.") var first: String?
        @Option(help: "Middle name.") var middle: String?
        @Option(help: "Family (last) name.") var last: String?
        @Option(help: "Nickname.") var nickname: String?
        @Option(help: "Company or organization.") var org: String?
        @Option(help: "Job title.") var title: String?
        @Option(help: ArgumentHelp("Birthday: YYYY-MM-DD, or MM-DD without a year. Empty removes it.", valueName: "date")) var birthday: String?
        @Option(help: ArgumentHelp("Add a phone number, optionally labeled: work:+14155550199. Repeatable.", valueName: "number")) var addPhone: [String] = []
        @Option(help: ArgumentHelp("Remove a phone number, however it is formatted. Repeatable.", valueName: "number")) var removePhone: [String] = []
        @Option(help: ArgumentHelp("Add an email, optionally labeled: work:maya@example.com. Repeatable.", valueName: "email")) var addEmail: [String] = []
        @Option(help: ArgumentHelp("Remove an email. Repeatable.", valueName: "email")) var removeEmail: [String] = []
        @Flag(help: "Show the change without saving.") var dryRun = false
        @Flag(name: .shortAndLong, help: "Save without asking. Required when there's no terminal to ask in (scripts and assistants).") var yes = false

        @OptionGroup var global: GlobalOptions

        struct Result: Encodable {
            let before: Payload.Contact
            let after: Payload.Contact?
            let changes: [String]
            /// Removed numbers and emails that conversations still use.
            let addressesInUse: [AddressInUse]?
            let backup: String?
            let dryRun: Bool?
        }

        /// A removed address and the conversations that use it. They name this person
        /// through it today.
        struct AddressInUse: Encodable {
            struct Conversation: Encodable {
                let ref: String
                let name: String
            }
            let address: String
            let conversations: [Conversation]
        }

        func run() async throws {
            try await runCommand("contacts edit", options: global) { context in
                let cards = try ContactsCommand.cards(context)
                let contact = try context.plan { _ in try cards.card(for: who, command: "contacts edit") }
                let requested = ContactEditPlanner.Changes(
                    first: first, middle: middle, last: last, nickname: nickname, organization: org, jobTitle: title, birthday: birthday,
                    addPhones: addPhone, removePhones: removePhone, addEmails: addEmail, removeEmails: removeEmail
                )
                let planner = try ContactsCommand.planner(context)
                let plan = try context.plan { warnings in try planner.edit(contact, requested, warnings: &warnings) }
                let edits = plan.edits
                let changes = plan.changes
                let inUse = Self.addressesInUse(plan.removed, of: contact, planner: planner, context: context)

                let style = context.style
                let showChanges = {
                    context.output.line(style.bold(contact.displayName) + style.muted("  contact:\(contact.id)"))
                    for change in changes {
                        for line in Layout.hanging(change, first: "  " + style.accent("•") + " ", rest: "    ", width: min(context.terminal.width, 100)) {
                            context.output.line(line)
                        }
                    }
                }
                if dryRun {
                    // The card as it would be saved, so the person sees labels and order too.
                    let preview = try FileContactsProvider.applying(edits, to: contact, region: context.region)
                    context.output.result(
                        Result(
                            before: Payload.contact(contact), after: Payload.contact(preview), changes: changes, addressesInUse: inUse, backup: nil,
                            dryRun: true))
                    if !context.output.json {
                        showChanges()
                        context.output.line(style.muted("Dry run: nothing was changed."))
                    }
                    return
                }
                try confirmChange(yes: yes, context: context, preview: showChanges, question: "Save these changes to \(contact.displayName)?")
                let provider = try context.contactsProvider()
                let backup = try Backups.saveVCard(try provider.vCard(id: contact.id), contactID: contact.id, sources: context.sources)
                let updated = try provider.update(id: contact.id, edits: edits)
                context.output.result(
                    Result(
                        before: Payload.contact(contact), after: Payload.contact(updated), changes: changes, addressesInUse: inUse, backup: backup, dryRun: nil)
                )
                if !context.output.json {
                    context.output.line(
                        style.success("✓ ") + "Saved. " + style.muted("Backup: \(backup.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"))
                }
            }
        }

        /// Conversations that use each removed address, most recent first, with a warning
        /// that names them; see `ContactEditPlanner.addressesInUse`.
        static func addressesInUse(_ removed: [String], of contact: Contact, planner: ContactEditPlanner, context: Context) -> [AddressInUse]? {
            guard !removed.isEmpty else { return nil }
            let resolver: Resolver
            do {
                resolver = try context.resolver()
            } catch {
                context.output.warn(
                    "messages_unavailable",
                    "Messages can't be read (\(TincanError.wrap(error).message)), so tincan can't say which conversations use what you remove.")
                return nil
            }
            var warnings: [PlanWarning] = []
            let found = planner.addressesInUse(removed, of: contact, resolver: resolver, warnings: &warnings)
            context.warn(warnings)
            return found?.map { entry in
                AddressInUse(address: entry.address, conversations: entry.conversations.map { .init(ref: $0.ref, name: $0.name) })
            }
        }
    }
}

private func render(_ contact: Contact, context: Context) {
    let style = context.style
    let output = context.output
    let width = min(context.terminal.width, 100)
    let reference = contact.id == "new" ? "" : "contact:\(contact.id)"
    if reference.isEmpty || TextWidth.columns(contact.displayName) + 2 + TextWidth.columns(reference) <= width {
        output.line(style.bold(contact.displayName) + (reference.isEmpty ? "" : style.muted("  " + reference)))
    } else {
        // A name too long to share its line keeps its words; the reference goes below.
        for line in TextWidth.wrap(contact.displayName, width: width) { output.line(style.bold(line)) }
        output.line(style.muted(reference))
    }
    var facts: [String] = []
    if !contact.nickname.isEmpty { facts.append("“\(contact.nickname)”") }
    let work = [contact.jobTitle, contact.isOrganization ? "" : contact.organization].filter { !$0.isEmpty }.joined(separator: ", ")
    if !work.isEmpty { facts.append(work) }
    if let birthday = contact.birthday { facts.append("Birthday " + Who.birthday(birthday)) }
    for line in TextWidth.wrap(facts.joined(separator: " · "), width: width) where !facts.isEmpty { output.line(style.muted(line)) }
    let labelWidth = min(12, (contact.phones.map { $0.label ?? "" } + contact.emails.map { $0.label ?? "" }).map { TextWidth.columns($0) }.max() ?? 0)
    let valueWidth = max(8, width - 2 - labelWidth - 2)
    for phone in contact.phones {
        output.line(
            "  " + style.muted(TextWidth.fit(phone.label ?? "", to: labelWidth)) + "  "
                + TextWidth.truncate(Address(phone.value, region: context.region).formatted, to: valueWidth))
    }
    for email in contact.emails {
        output.line("  " + style.muted(TextWidth.fit(email.label ?? "", to: labelWidth)) + "  " + TextWidth.truncate(email.value, to: valueWidth))
    }
}
