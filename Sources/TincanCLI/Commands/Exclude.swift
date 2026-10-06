import ArgumentParser
import Foundation
import TincanKit

struct Exclude: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep conversations out of tincan entirely.",
        discussion: """
            Excluded conversations are filtered out inside the database queries, before any message is decoded. They are never read, searched, streamed, summarized or sent to, by you or an assistant using tincan. Excluding a person excludes every one-to-one conversation with them, including ones on their numbers and emails that start later; groups they are in stay readable.

            Exclusions are stored in the settings file by the conversation's GUID, and a person's by each of their addresses too (`address:+14155550142`), so they survive Messages rebuilding its database. Removing one asks first in a terminal; without one, or with --json, it needs --yes, added only after the person asks.

            Examples:
              tincan exclude add chat:42
              tincan exclude add "Maya Chen"
              tincan exclude list
              tincan exclude remove chat:42
            """,
        subcommands: [Add.self, Remove.self, List.self],
        defaultSubcommand: List.self
    )

    struct Item: Encodable {
        let ref: String
        let name: String
        /// For a person's address: the canonical address, whose every one-to-one
        /// conversation is excluded.
        var address: String? = nil
        /// Set on entries the `exclude add` that printed the list created.
        var added: Bool? = nil
    }

    static func items(_ references: [String], context: Context, added: Set<String> = []) -> [Item] {
        let chats = (try? context.messages().allChats()) ?? []
        let resolver = try? context.resolver()
        return references.map { reference in
            if let address = Exclusion.address(in: reference, region: context.region) {
                // A hand-edited entry that is no phone number or email matches no conversation;
                // never list it as keeping someone out.
                guard address.kind != .other else {
                    return Item(
                        ref: Exclusion.entry(for: address), name: "Excludes nothing: not a number or email", added: added.contains(reference) ? true : nil)
                }
                let name = resolver?.person(forAddress: address.value).name ?? address.formatted
                return Item(ref: Exclusion.entry(for: address), name: name, address: address.value, added: added.contains(reference) ? true : nil)
            }
            let parsed = ChatReference.parse(reference)
            let chat = parsed.flatMap { parsed in chats.first { parsed.matches($0) } }
            let name = chat.flatMap { chat in resolver.map { $0.title(for: chat) } } ?? "Conversation not on this Mac"
            return Item(ref: chat?.reference ?? reference, name: name, added: added.contains(reference) ? true : nil)
        }
    }

    /// The stored form of a conversation: its GUID.
    static func key(for chat: Chat) -> String { chat.guid }

    /// What an address entry covers, for people reading the list.
    static func coverage(_ address: String, region: String?, glued: Bool = false) -> String {
        let formatted = Address(address, region: region).formatted
        return "every one-to-one conversation at " + (glued ? formatted.replacingOccurrences(of: " ", with: String(TextWidth.glue)) : formatted)
    }

    /// `✓ Excluded Maya Chen  chat:42`, wrapped to the terminal with the number kept whole.
    static func printExcluded(_ name: String, _ detail: String, context: Context) {
        let style = context.style
        let text = "Excluded " + style.bold(name) + style.muted("  " + detail)
        let width = min(context.terminal.width, 100)
        for (index, line) in TextWidth.wrapGlued(text, width: width - 2).enumerated() {
            context.output.line((index == 0 ? style.success("✓ ") : "  ") + (index == 0 ? line : style.muted(line)))
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Exclude a conversation, or every one-to-one conversation with a person.",
            discussion: """
                Examples:
                  tincan exclude add chat:42
                  tincan exclude add "Maya Chen"
                """
        )
        @Argument(
            help: ArgumentHelp(
                "chat:<id>, a group name, or a person: a name, phone number, email, contact:<id>, or address:<address> for that address alone, as `tincan exclude list` shows it.",
                valueName: "who"))
        var reference: String
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("exclude add", options: global) { context in
                var config = try context.config()
                let target: Target
                do {
                    target = try context.resolve(reference, command: "exclude add")
                } catch let error as TincanError where error.code == "excluded" {
                    if !context.output.json { context.output.line(context.style.muted("Already excluded.")) }
                    context.output.result(Exclude.items(config.excludedChats, context: context))
                    return
                }
                let chats: [Chat]
                var addresses: [Address] = []
                var person: Person?
                let typedAddress = Exclusion.address(in: reference, region: context.region)
                switch target {
                case .chat(let chat): chats = [chat]
                case .person(let named):
                    person = named
                    if let typed = typedAddress {
                        // `address:<address>` is that address alone, as `exclude list` shows it
                        // and `exclude remove` lifts it, never the rest of the card that has it.
                        // Its entry covers its one-to-one conversations, now and later.
                        let storable = typed.kind != .other && !typed.lacksCountryCode
                        chats = storable ? [] : try context.resolver().directChats(onAddress: typed.value)
                        addresses = storable ? [typed] : []
                    } else {
                        chats = try context.resolver().directChats(with: named)
                        // Their addresses exclude conversations that start later, too.
                        addresses = Exclusion.addresses(of: named, region: context.region)
                    }
                    guard !chats.isEmpty || !addresses.isEmpty else {
                        throw TincanError(
                            code: "no_conversation",
                            message: "You have no one-to-one conversation with \(named.name) to exclude.",
                            hint: "Exclude a group with its chat:<id>; find it with `tincan chats --with \(shellQuote(reference))`.",
                            exit: .needsInput
                        )
                    }
                    // The exclusion covers the address, whoever uses it: say whose cards it is on.
                    // A card's other shared addresses don't matter to one address.
                    if typedAddress == nil || named.contact == nil {
                        context.warnSharedAddress(
                            named,
                            consequence: named.contact == nil
                                ? "Excluding it keeps out every one-to-one conversation on it, whichever of them uses it."
                                : "Excluding \(named.name) keeps out every one-to-one conversation on \(named.sharedAddresses.count == 1 ? "it" : "those"), whichever of them uses \(named.sharedAddresses.count == 1 ? "it" : "them")."
                        )
                    }
                    // Groups stay readable; an assistant must not tell the person everything is excluded.
                    let resolver = try context.resolver()
                    let groups = resolver.groupChats(with: named).filter { group in
                        guard let typed = typedAddress else { return true }
                        return group.participants.contains { Address($0, region: context.region).value == typed.value }
                    }
                    if !groups.isEmpty {
                        let names = Formatting.list(groups.map { "\(resolver.title(for: $0)) (\($0.reference))" })
                        context.output.warn(
                            "groups_not_excluded",
                            "\(named.name) is in \(Formatting.plural(groups.count, "group conversation")) that stay\(groups.count == 1 ? "s" : "") readable: \(names). Exclude a group with `tincan exclude add chat:<id>` only if the person asks."
                        )
                    }
                }
                let storedAddresses = Set(config.excludedChats.compactMap { Exclusion.address(in: $0, region: context.region)?.value })
                let newChats = chats.filter { !config.excludedChats.contains(Exclude.key(for: $0)) && !config.excludedChats.contains($0.reference) }
                let newAddresses = addresses.filter { !storedAddresses.contains($0.value) }
                guard !newChats.isEmpty || !newAddresses.isEmpty else {
                    if !context.output.json {
                        context.output.line(context.style.muted("Conversations with \(person?.name ?? reference) are already excluded."))
                    }
                    context.output.result(Exclude.items(config.excludedChats, context: context))
                    return
                }
                let added = newChats.map(Exclude.key(for:)) + newAddresses.map(Exclusion.entry(for:))
                config.excludedChats += added
                try config.save()
                context.output.result(Exclude.items(config.excludedChats, context: context, added: Set(added)))
                guard !context.output.json else { return }
                let resolver = try context.resolver()
                for chat in newChats {
                    Exclude.printExcluded(resolver.title(for: chat), chat.reference, context: context)
                }
                for address in newAddresses {
                    Exclude.printExcluded(
                        person?.name ?? address.formatted, Exclude.coverage(address.value, region: context.region, glued: true), context: context)
                }
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Allow an excluded conversation or person again.",
            discussion: """
                tincan can then read and send to the conversation again. Removing a person lifts their conversations and addresses; removing a one-to-one conversation lifts its address too; removing an address:<address> lifts only that address. In a terminal it asks first. Without one, or with --json, it changes nothing unless you pass --yes; add --yes only after the person asks to remove the exclusion.

                Examples:
                  tincan exclude remove chat:42
                  tincan exclude remove "Maya Chen"
                """
        )
        @Argument(
            help: ArgumentHelp("chat:<id> or address:<address> from `tincan exclude list`, or a person whose conversations you excluded.", valueName: "who"))
        var reference: String
        @Flag(name: .shortAndLong, help: "Remove without asking. Required when there's no terminal to ask in; add it only after the person asks.")
        var yes = false
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("exclude remove", options: global) { context in
                var config = try context.config()
                let region = context.region
                let chats = (try? context.messages().allChats()) ?? []
                let resolver = try? context.resolver()
                let typed = ChatReference.parse(reference, requirePrefix: true)
                let typedAddress = Exclusion.address(in: reference, region: region)
                var matched: [Chat] = []
                /// Addresses whose exclusion is lifted: the person's, or the conversation's.
                var addresses = Set<String>()
                /// Whose addresses those are, to name every card that shares one.
                var owner: Person?
                if let typedAddress {
                    addresses = [typedAddress.value]
                } else if let typed, let chat = chats.first(where: { typed.matches($0) }) {
                    matched = [chat]
                    // Letting a one-to-one conversation back in lifts its address's exclusion,
                    // which would otherwise keep it out.
                    if chat.kind == .direct {
                        addresses = Set((chat.participants.isEmpty ? [chat.identifier] : chat.participants).map { Address($0, region: region).value })
                        owner = resolver?.person(forAddress: chat.participants.first ?? chat.identifier)
                    }
                } else if typed == nil, let resolver, case .person(let person)? = try? resolver.resolve(reference) {
                    matched = context.excludedDirectChats(with: person)
                    addresses = resolver.canonicalAddresses(of: person)
                    owner = person
                }
                // Stored entries are GUIDs, `address:` entries, or chat:<id> from older configs, in any case.
                func isRemoved(_ entry: String) -> Bool {
                    if let address = Exclusion.address(in: entry, region: region) { return addresses.contains(address.value) }
                    guard let stored = ChatReference.parse(entry) else { return false }
                    if let typed, stored == typed { return true }
                    return matched.contains { stored.matches($0) }
                }
                guard config.excludedChats.contains(where: isRemoved) else {
                    throw TincanError.usage(
                        "\(matched.first?.reference ?? reference) isn't excluded.", hint: "See what is excluded with `tincan exclude list`.")
                }
                let lifted = config.excludedChats.compactMap { entry in isRemoved(entry) ? Exclusion.address(in: entry, region: region)?.value : nil }
                // The exclusion covers the address, whoever uses it: say whose cards it is on,
                // as `exclude add` does, so lifting it for one card never quietly lifts another's.
                if let owner, !lifted.isEmpty {
                    let one = owner.sharedAddresses.count == 1
                    context.warnSharedAddress(
                        owner,
                        consequence:
                            "Removing the exclusion lets tincan read and send to every one-to-one conversation on \(one ? "it" : "those") again, whichever of them uses \(one ? "it" : "them")."
                    )
                }
                // Lifting an exclusion is the person's decision, never an assistant's.
                var named = matched.map { chat in resolver.map { "\($0.title(for: chat)) (\(chat.reference))" } ?? chat.reference }
                named += lifted.map { Exclude.coverage($0, region: region) }
                try confirmChange(
                    yes: yes, context: context, preview: {},
                    question: "Let tincan read and send to \(Formatting.list(named.isEmpty ? [reference] : named)) again?",
                    refusal: TincanError(
                        code: "confirmation_required",
                        message: "Removing an exclusion without a terminal needs --yes.",
                        hint: "Exclusions are the person's decision. Only add --yes after they ask to remove this one.",
                        exit: .needsInput
                    ))
                config.excludedChats.removeAll(where: isRemoved)
                try config.save()
                context.output.result(Exclude.items(config.excludedChats, context: context))
                guard !context.output.json else { return }
                // Named as `exclude add` names them: each title once with its references, then
                // the addresses whose conversations are let back in.
                var titles: [String] = []
                var references: [String: [String]] = [:]
                for chat in matched {
                    let title = resolver?.title(for: chat) ?? chat.reference
                    if references[title] == nil { titles.append(title) }
                    references[title, default: []].append(chat.reference)
                }
                var names = titles.map { title in
                    title == references[title]?.first ? title : "\(title) (\(references[title, default: []].joined(separator: ", ")))"
                }
                if !lifted.isEmpty {
                    names.append(
                        "one-to-one conversations at "
                            + Formatting.list(lifted.map { Address($0, region: region).formatted.replacingOccurrences(of: " ", with: String(TextWidth.glue)) }))
                }
                if names.isEmpty { names = [reference] }
                let sentence = "No longer excluded: \(Formatting.list(names))."
                for (index, line) in TextWidth.wrapGlued(sentence, width: min(context.terminal.width, 100) - 2).enumerated() {
                    context.output.line((index == 0 ? context.style.success("✓ ") : "  ") + line)
                }
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List excluded conversations and people's addresses.",
            discussion: """
                Examples:
                  tincan exclude list
                  tincan exclude --json
                """
        )
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runCommand("exclude list", options: global) { context in
                let config = try context.config()
                let items = Exclude.items(config.excludedChats, context: context)
                context.output.result(items)
                guard !context.output.json else { return }
                if items.isEmpty {
                    context.output.line(context.style.muted("No conversations are excluded."))
                    return
                }
                let width = min(context.terminal.width, 100)
                // A person's address says what it covers; a conversation shows its reference.
                let details = items.map { item in item.address.map { Exclude.coverage($0, region: context.region, glued: true) } ?? item.ref }
                let detailWidth = details.map { TextWidth.columns($0) }.max() ?? 0
                let nameWidth = min(max(10, width - detailWidth - 2), 40, items.map { TextWidth.columns($0.name) }.max() ?? 0)
                for (item, detail) in zip(items, details) {
                    // Details wrap under themselves when the terminal is narrow.
                    for (index, line) in TextWidth.wrapGlued(detail, width: max(12, width - nameWidth - 2)).enumerated() {
                        let name = index == 0 ? TextWidth.fit(item.name, to: nameWidth) : String(repeating: " ", count: nameWidth)
                        context.output.line(name + "  " + context.style.muted(line))
                    }
                }
            }
        }
    }
}
