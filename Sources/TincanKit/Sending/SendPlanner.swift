import Foundation

/// Plans a send before anything goes: who a reference names, the conversation and address
/// that continue it, the service, and how the other person sees typing. A dry run previews
/// the `SendPlan` and a send executes it through `Sender`, so both do exactly the same.
///
/// Sending continues the single most recent one-to-one conversation, the one Messages itself
/// would use. An address given decides the conversation; a person whose conversations use
/// several addresses, or who has several addresses and no conversation, is the person's
/// choice, so planning stops with every candidate. So does a group named by its name, which
/// the people in it choose. Excluded people are never messaged. Refusals are `PlanRefusal`s
/// and warnings `PlanWarning`s, as data.
public struct SendPlanner {
    /// What a send asks for, once its options are parsed.
    public struct Request: Sendable {
        /// A name, number, email, `address:<address>`, `contact:<id>`, `chat:<id>` or `me`.
        public var reference: String
        public var bubbles: [String]
        /// Files `SendPlanner.check` allowed.
        public var files: [Attachments.File]
        /// The service asked for, if any.
        public var service: MessageService?
        public var typing: Config.TypingMode
        public var wordsPerMinute: Double
        /// Reproduces a plan's pauses exactly; random when nil.
        public var seed: UInt64?

        public init(
            reference: String, bubbles: [String], files: [Attachments.File] = [], service: MessageService? = nil,
            typing: Config.TypingMode, wordsPerMinute: Double, seed: UInt64? = nil
        ) {
            self.reference = reference
            self.bubbles = bubbles
            self.files = files
            self.service = service
            self.typing = typing
            self.wordsPerMinute = wordsPerMinute
            self.seed = seed
        }
    }

    /// What the reference names, and the addresses that decide the conversation.
    public struct Recipient: Sendable {
        public let target: Target
        /// The address given (or for `me`, your own addresses), which then decide the
        /// conversation; nil when the reference named a person or chat.
        public let addresses: [Address]?
        /// A send to `me`.
        public let isSelf: Bool
    }

    /// What decides whether tincan can type into Messages right now. `current` asks macOS;
    /// tests pass their own.
    public struct Conditions: Sendable {
        /// tincan is allowed Accessibility.
        public var accessibilityAllowed: @Sendable () -> Bool
        public var screenLocked: @Sendable () -> Bool
        /// Messages is in front and the person used the Mac in the last 30 seconds.
        public var messagesInUse: @Sendable () -> Bool

        public init(
            accessibilityAllowed: @escaping @Sendable () -> Bool, screenLocked: @escaping @Sendable () -> Bool,
            messagesInUse: @escaping @Sendable () -> Bool
        ) {
            self.accessibilityAllowed = accessibilityAllowed
            self.screenLocked = screenLocked
            self.messagesInUse = messagesInUse
        }

        public static let current = Conditions(
            accessibilityAllowed: { Permissions.accessibility() == .granted },
            screenLocked: { Permissions.isScreenLocked },
            messagesInUse: { MessagesKeyboard.messagesInUse }
        )
    }

    public let resolver: Resolver
    /// The region every address is read in.
    public let region: String?
    /// The latest message in each conversation, which decides the most recent one.
    public let activity: [Int64: Date]
    /// Canonical addresses the settings exclude. Every one-to-one conversation on them is
    /// excluded, including ones that don't exist yet.
    private let excludedCanonicalAddresses: Set<String>
    private let ownAddresses: () throws -> [String]
    private let relativeTime: (Date) -> String
    private let conditions: Conditions
    private let recentServices: (Int64) -> [ServiceUse]

    /// How many of a conversation's newest messages decide the service it uses.
    public static let recentMessageCount = 10
    /// How far back those messages may be. Older ones say little about today's service.
    public static let recentWindow: TimeInterval = 30 * 24 * 60 * 60

    /// `exclusions` are the settings' exclusion entries. `ownAddresses` reads your own
    /// Messages addresses, only for `me`. `relativeTime` words a conversation's last message
    /// for candidates, such as "4m ago". `recentServices` reads the service and direction of
    /// a conversation's newest messages, newest first, as
    /// `MessagesDatabase.recentServices(inChat:since:limit:)` does with `recentMessageCount`
    /// and `recentWindow`; without it every conversation keeps the service Messages lists.
    public init(
        resolver: Resolver, region: String?, activity: [Int64: Date], exclusions: [String],
        ownAddresses: @escaping () throws -> [String], relativeTime: @escaping (Date) -> String, conditions: Conditions = .current,
        recentServices: @escaping (Int64) -> [ServiceUse] = { _ in [] }
    ) {
        self.recentServices = recentServices
        self.resolver = resolver
        self.region = region
        self.activity = activity
        excludedCanonicalAddresses = Set(exclusions.compactMap { Exclusion.address(in: $0, region: region)?.value })
        self.ownAddresses = ownAddresses
        self.relativeTime = relativeTime
        self.conditions = conditions
    }

    /// Plans `request`: the recipient, the route, the method and the pacing. Warnings found
    /// on the way are added to `warnings`, in order, even when planning then stops.
    public func plan(_ request: Request, warnings: inout [PlanWarning]) throws -> SendPlan {
        let recipient = try self.recipient(for: request.reference)
        let route = try self.route(to: recipient, service: request.service, warnings: &warnings)
        let (method, reason) = try self.method(request.typing, for: route)
        let typing =
            method == .immediate
            ? TypingPlan.immediate(request.bubbles)
            : TypingPlan.make(request.bubbles, wordsPerMinute: request.wordsPerMinute, seed: request.seed ?? UInt64.random(in: 1...UInt64.max))
        return SendPlan(route: route, method: method, methodReason: reason, typing: typing, files: request.files)
    }

    // MARK: Recipient

    /// What `reference` names. `me` is you, on any of your addresses; `address:<address>`,
    /// as `tincan exclude list` shows it, is that address. Anything taken for an address
    /// must be a number or email, and a group is named only by its `chat:<id>`.
    public func recipient(for reference: String) throws -> Recipient {
        // Trimmed as `resolve` trims it, so ` me` is never read as a name.
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "me" {
            let own = try ownAddresses()
            guard let first = own.first else {
                throw PlanRefusal.issue(
                    PlanIssue(
                        code: "no_own_address", message: "tincan couldn't find your own Messages address.", hint: "Send to your number or email explicitly.",
                        kind: .needsInput))
            }
            // Your conversation with yourself may be on any of your addresses.
            return Recipient(target: .person(resolver.person(forAddress: first)), addresses: own.map { Address($0, region: region) }, isSelf: true)
        }
        let lowered = trimmed.lowercased()
        // `address:<address>`, as `tincan exclude list` shows it, is that address.
        let typed =
            lowered.hasPrefix(Exclusion.addressPrefix)
            ? String(trimmed.dropFirst(Exclusion.addressPrefix.count)).trimmingCharacters(in: .whitespaces)
            : trimmed
        let named = lowered.hasPrefix("chat:") || lowered.hasPrefix("contact:") || !Resolver.looksLikeAddress(typed)
        // A number without its country code, or too short, is refused as `incomplete_number`.
        let target: Target
        do {
            target = try resolver.resolve(reference)
        } catch let error as ResolveError {
            throw PlanRefusal.unresolved(error, command: "send")
        }
        // Anything taken for an address must be one, or a new conversation would start with
        // junk such as `@` or two numbers. An address Messages already has a conversation
        // with still works.
        if !named {
            let isPhone = !typed.contains("@") && PhoneNumber.parse(typed, region: region) != nil
            guard isPhone || Address.isEmail(typed) || !resolver.directChats(onAddress: typed).isEmpty else {
                throw PlanRefusal.issue(
                    .invalidInput(
                        "\"\(typed)\" is not a phone number or email address.",
                        hint:
                            "Send to one recipient: a name, a phone number with its country code, an email, contact:<id> or chat:<id>: `tincan send <reference> …`."
                    ))
            }
        }
        // The people in a group choose its name, so a name alone never picks a group to
        // send to. The person confirms the group, and the send names its chat:<id>.
        if case .chat(let chat) = target, chat.kind == .group, !lowered.hasPrefix("chat:") {
            throw PlanRefusal.issue(
                PlanIssue(
                    code: "ambiguous",
                    message: "\"\(reference)\" is a group's name. Groups are sent to by reference:",
                    hint:
                        "Group names are set by the people in them. Ask the person whether they mean this group, then use its reference: `\(PlanIssue.example("send"))`.",
                    kind: .needsInput,
                    candidates: [PlanIssue.Candidate(group: resolver.groupCandidate(chat))]
                ))
        }
        return Recipient(target: target, addresses: named ? nil : [Address(typed, region: region)], isSelf: false)
    }

    // MARK: Route

    /// The conversation or address a send to `recipient` goes to, on `service` when one is
    /// asked for. Refuses excluded people, a choice between addresses, and a conversation
    /// named by reference on another service. Warns, in this order, when the address is on
    /// other cards too, when the service differs from Messages' record of the conversation
    /// or from its recent messages, when Messages filed the conversation as junk, and when no
    /// conversation shows which service a new address uses.
    public func route(to recipient: Recipient, service: MessageService?, warnings: inout [PlanWarning]) throws -> SendRoute {
        let target = recipient.target
        let typed = recipient.addresses
        // Excluding someone means tincan never messages them, on any thread or address.
        let person: Person?
        switch target {
        case .person(let value): person = value
        case .chat(let chat) where chat.kind == .direct: person = resolver.person(forAddress: chat.participants.first ?? chat.identifier)
        case .chat: person = nil
        }
        if let person {
            var excluded = excludedDirectChats(with: person)
            // An excluded address covers conversations that don't exist yet.
            var addresses = excludedAddresses(of: person)
            if recipient.isSelf, let typed {
                let own = Set(typed.map(\.value))
                excluded = resolver.chats.filter { chat in
                    guard chat.kind == .direct, resolver.excludedChatIDs.contains(chat.id) else { return false }
                    let others = chat.participants.isEmpty ? [chat.identifier] : chat.participants
                    return others.allSatisfy { own.contains(Address($0, region: region).value) }
                }
                addresses = addresses.filter(own.contains)
            }
            if !excluded.isEmpty || !addresses.isEmpty { throw PlanRefusal.excludedPerson(person, chats: excluded) }
        }

        var route = try destination(for: target, recipient: recipient, person: person, service: service)
        describeSharing(&route, warnings: &warnings)
        if let warning = serviceWarning(route, asked: service) { warnings.append(warning) }
        if let chat = route.chat, chat.isFiltered {
            warnings.append(.filteredConversation(chat, consequence: "Check that this is who you mean before sending."))
        }
        if route.serviceGuessed {
            let address = route.address.map { Address($0, region: region) }
            let shown = address?.formatted ?? "this address"
            let phone = address?.kind == .phone ? " If the person knows the number doesn't use iMessage, pass --service sms." : ""
            warnings.append(
                .notice(
                    code: "service_unknown",
                    message:
                        "tincan can't tell whether \(shown) uses iMessage: there is no conversation to show it. It asks Messages to send over iMessage, and Messages decides whether the message goes.\(phone)"
                ))
        }
        return route
    }

    private func destination(for target: Target, recipient: Recipient, person: Person?, service: MessageService?) throws -> SendRoute {
        let typed = recipient.addresses
        switch target {
        case .chat(let chat):
            if let service, !uses(chat, service) {
                // iMessage, SMS and RCS all start with a vowel sound.
                let article = [.iMessage, .sms, .rcs].contains(chat.service) ? "an" : "a"
                throw PlanRefusal.issue(
                    .invalidInput(
                        "\(chat.reference) is \(article) \(chat.service.displayName) conversation.",
                        hint: "Drop --service to send in it, or send to the person instead."))
            }
            let name = resolver.title(for: chat)
            let only = chat.kind == .direct ? (chat.participants.first ?? chat.identifier) : nil
            let choice = serviceChoice(for: chat, asked: service)
            return SendRoute(
                addressee: only.map { .address($0) } ?? .group(name),
                name: only.map { resolver.directory.displayName(for: $0) } ?? name,
                address: only.map { Address($0, region: resolver.directory.region).value }, region: region,
                chat: chat, destination: .chat(guid: chat.guid, service: choice.service, address: only), service: choice.service,
                keyboardAddress: only, titles: titles(name: name, address: only), reason: "the conversation you named" + choice.reasonSuffix,
                recipient: person,
                participants: chat.kind == .group ? chat.participants : [],
                serviceSwitched: choice.switched, recentService: choice.recent
            )

        case .person(let person):
            let isSelf = recipient.isSelf
            func addressOf(_ chat: Chat) -> String { Address(chat.participants.first ?? chat.identifier, region: region).value }
            var threads: [Chat]
            if isSelf, let typed {
                var seen = Set<Int64>()
                threads = typed.flatMap { resolver.directChats(onAddress: $0.value) }.filter { seen.insert($0.id).inserted }
            } else {
                threads = resolver.directChats(with: person)
                if let typed {
                    // An address decides the conversation: never another of the person's addresses.
                    let wanted = Set(typed.map(\.value))
                    threads = threads.filter { wanted.contains(addressOf($0)) }
                }
            }
            threads = threads.filter { chat in service.map { uses(chat, $0) } ?? true }
            threads.sort { (activity[$0.id] ?? .distantPast) > (activity[$1.id] ?? .distantPast) }
            let addresses = Array(Set(threads.map(addressOf)))
            if addresses.count > 1 {
                throw PlanRefusal.issue(
                    PlanIssue(
                        code: "ambiguous_destination",
                        message: (isSelf ? "You text yourself" : "You text \(person.name)") + " at \(addresses.count) addresses. Say which conversation:",
                        hint: "Ask the person which conversation they mean, then send to its reference: `tincan send <reference> …`.",
                        kind: .needsInput,
                        candidates: threads.map { chat in
                            // The service a send would use, which the person chooses by, not
                            // only the one Messages lists for the conversation.
                            let choice = serviceChoice(for: chat, asked: service)
                            let details = [
                                activity[chat.id].map { "last message " + relativeTime($0) },
                                choice.switched ? "Messages lists it as \(chat.service.displayName)" : nil,
                            ].compactMap { $0 }
                            return PlanIssue.Candidate(
                                reference: chat.reference,
                                name: Address(addressOf(chat), region: region).formatted + " · " + choice.service.displayName,
                                detail: details.isEmpty ? nil : details.joined(separator: " · "),
                                addresses: [addressOf(chat)], conversations: 1, lastActivity: activity[chat.id]
                            )
                        }
                    ))
            }
            if let chat = threads.first {
                let address = chat.participants.first ?? chat.identifier
                let others = threads.count - 1
                let reason: String
                if isSelf {
                    reason = others > 0 ? "the most recent of \(threads.count) conversations with yourself" : "your conversation with yourself"
                } else if typed != nil {
                    reason =
                        others > 0
                        ? "the most recent of \(threads.count) conversations with the address you gave" : "the conversation with the address you gave"
                } else {
                    reason =
                        others > 0
                        ? "the most recent of \(threads.count) conversations with \(Address(address, region: region).formatted)"
                        : "your conversation with \(person.name)"
                }
                let choice = serviceChoice(for: chat, asked: service)
                return SendRoute(
                    addressee: .person(person, address: addressOf(chat)), name: person.name, address: addressOf(chat), region: region,
                    chat: chat, destination: .chat(guid: chat.guid, service: choice.service, address: address), service: choice.service,
                    keyboardAddress: address, titles: titles(name: person.name, address: address), reason: reason + choice.reasonSuffix,
                    recipient: person, isSelf: isSelf, serviceSwitched: choice.switched, recentService: choice.recent
                )
            }
            // No conversation yet: the address given, or the person's only one; never a guess.
            let chosen: Address
            if let first = typed?.first {
                chosen = first
            } else {
                var seen = Set<String>()
                let usable = person.addresses.map { Address($0, region: region) }
                    .filter { ($0.kind == .phone || $0.kind == .email) && seen.insert($0.value).inserted }
                    .sorted()
                // A number saved without its country code can't be sent to as it is.
                let candidates = usable.filter { !$0.lacksCountryCode }
                let phones = candidates.filter { $0.kind == .phone }
                if phones.count == 1 {
                    chosen = phones[0]
                } else if phones.isEmpty, candidates.count == 1 {
                    chosen = candidates[0]
                } else if candidates.isEmpty, let incomplete = usable.first {
                    throw PlanRefusal.incompleteNumber(
                        incomplete.value, owner: person.name, tooShort: resolver.isTooShort(incomplete.value),
                        options: resolver.completeNumbers(for: incomplete.value), command: "send"
                    )
                } else if candidates.isEmpty {
                    throw PlanRefusal.issue(
                        PlanIssue(
                            code: "no_address", message: "\(person.name) has no phone number or email to send to.",
                            hint: "Ask the person which number or email to use, then send to it directly.", kind: .needsInput))
                } else {
                    throw PlanRefusal.issue(
                        PlanIssue(
                            code: "ambiguous_address",
                            message: "You have no conversation with \(person.name) yet, and they have \(candidates.count) addresses. Say which one:",
                            hint: "Ask the person which address they mean, then send to it: `tincan send <address> …`.",
                            kind: .needsInput,
                            candidates: candidates.map {
                                PlanIssue.Candidate(reference: $0.value, name: $0.formatted, detail: $0.kind.rawValue, addresses: [$0.value], conversations: 0)
                            }
                        ))
                }
            }
            let chosenService = service ?? .iMessage
            return SendRoute(
                addressee: .person(person, address: chosen.value), name: person.name, address: chosen.value, region: region,
                chat: nil, destination: .address(chosen.value, service: chosenService), service: chosenService,
                keyboardAddress: chosen.value, titles: titles(name: person.name, address: chosen.value),
                reason: isSelf ? "a new conversation with yourself at \(chosen.formatted)" : "a new conversation at \(chosen.formatted)",
                recipient: person, isSelf: isSelf, serviceGuessed: service == nil
            )
        }
    }

    // MARK: Service

    /// The service a send in `chat` uses, and how it relates to the conversation's recent
    /// messages.
    struct ServiceChoice {
        let service: MessageService
        /// No service was asked for, and the recent messages changed it from the one Messages
        /// lists for the conversation.
        let switched: Bool
        /// The service of the conversation's newest recent message, when there is one.
        let recent: MessageService?

        /// Added to the route's reason: why the service isn't the one Messages lists, or that
        /// the recent messages went another way.
        var reasonSuffix: String {
            if switched { return ", over \(service.displayName) like its recent messages" }
            if let recent, recent != service { return "; its recent messages went over \(recent.displayName)" }
            return ""
        }
    }

    /// The services a conversation's recent messages went over, newest first, counting only
    /// iMessage, SMS and RCS. Groups keep their own service, so they have none.
    private func recentUse(of chat: Chat) -> [ServiceUse] {
        guard chat.kind == .direct else { return [] }
        return recentServices(chat.id).filter { [.iMessage, .sms, .rcs].contains($0.service) }
    }

    /// Whether `chat` can carry a send over `service` asked for: the service Messages lists
    /// for it, or one its recent messages went over, since Messages keeps one conversation
    /// for a number whatever service each message uses.
    private func uses(_ chat: Chat, _ service: MessageService) -> Bool {
        chat.service == service || recentUse(of: chat).contains { $0.service == service }
    }

    /// The service to send over in `chat`. A service asked for always wins. Otherwise the
    /// one Messages lists for the conversation, unless it is SMS or RCS while every recent
    /// message went over iMessage, including at least one from the other person, which
    /// shows their address receives iMessage: then iMessage, as the conversation goes.
    /// Nothing else changes the service; a mix is left as Messages has it.
    func serviceChoice(for chat: Chat, asked: MessageService?) -> ServiceChoice {
        let recent = recentUse(of: chat)
        let newest = recent.first?.service
        if let asked { return ServiceChoice(service: asked, switched: false, recent: newest) }
        if [.sms, .rcs].contains(chat.service), !recent.isEmpty, recent.allSatisfy({ $0.service == .iMessage }), recent.contains(where: { !$0.isFromMe }) {
            return ServiceChoice(service: .iMessage, switched: true, recent: newest)
        }
        return ServiceChoice(service: chat.service, switched: false, recent: newest)
    }

    /// Warns when the send goes over another service than Messages lists for the
    /// conversation, or than its recent messages went over.
    private func serviceWarning(_ route: SendRoute, asked: MessageService?) -> PlanWarning? {
        guard let chat = route.chat else { return nil }
        let whom = route.isSelf ? "yourself" : route.name
        if route.serviceSwitched {
            return .notice(
                code: "service_switched",
                message:
                    "Messages lists your conversation with \(whom) as \(chat.service.displayName), but its recent messages, theirs included, went over \(route.service.displayName), so tincan sends over \(route.service.displayName)."
            )
        }
        guard let recent = route.recentService, recent != route.service else { return nil }
        let listed = asked != nil ? "asked for" : "Messages lists for the conversation"
        return .notice(
            code: "service_differs",
            message:
                "Your recent messages with \(whom) went over \(recent.displayName), but tincan sends over \(route.service.displayName), the service \(listed). If it doesn't arrive, it may need \(recent.displayName)."
        )
    }

    /// Notes every card that has the address a one-to-one send goes to, and warns when it
    /// is on more cards than the recipient's: the message reaches whoever uses it.
    private func describeSharing(_ route: inout SendRoute, warnings: inout [PlanWarning]) {
        guard let address = route.keyboardAddress, let recipient = route.recipient else { return }
        let value = Address(address, region: region).value
        let matches = resolver.directory.matches(for: address)
        if let contact = recipient.contact, let match = matches.first(where: { $0.contact.id == contact.id }), match.quality == .national {
            route.nationalMatch = true
        }
        var scoped = recipient
        scoped.sharedAddresses = recipient.sharedAddresses.filter { $0.address == value }
        guard let shared = scoped.sharedAddresses.first else { return }
        let cards = matches.map(\.contact)
        if recipient.contact == nil {
            route.shared = SendRoute.SharedDestination(cards: cards, others: nil)
            warnings.append(.sharedAddress(scoped, consequence: "A message there reaches whoever uses it."))
        } else {
            route.shared = SendRoute.SharedDestination(cards: cards, others: shared.contacts)
            warnings.append(.sharedAddress(scoped, consequence: "A message there reaches whoever uses it, not only \(recipient.name)."))
        }
    }

    /// Titles that identify the conversation in Messages before typing into it. A name is
    /// included only when no other card shares it, so tincan can never type into a
    /// same-named person's conversation.
    private func titles(name: String, address: String?) -> [String] {
        var titles: [String] = []
        // Compared as Messages' titles are, so Mary-Ann Lee and Mary Ann Lee share a name.
        let sameName = resolver.directory.contacts.filter { MessagesKeyboard.fold($0.displayName) == MessagesKeyboard.fold(name) }
        if sameName.count <= 1 { titles.append(name) }
        if let address {
            titles.append(address)
            titles.append(Address(address, region: region).formatted)
        }
        return titles
    }

    /// One-to-one conversations with `person` that are excluded.
    private func excludedDirectChats(with person: Person) -> [Chat] {
        guard !resolver.excludedChatIDs.isEmpty else { return [] }
        let wanted = resolver.canonicalAddresses(of: person)
        return resolver.chats.filter { chat in
            guard chat.kind == .direct, resolver.excludedChatIDs.contains(chat.id) else { return false }
            let others = chat.participants.isEmpty ? [chat.identifier] : chat.participants
            return others.allSatisfy { wanted.contains(Address($0, region: region).value) }
        }
    }

    /// `person`'s addresses that the settings exclude, canonical.
    private func excludedAddresses(of person: Person) -> [String] {
        guard !excludedCanonicalAddresses.isEmpty else { return [] }
        return resolver.canonicalAddresses(of: person).filter(excludedCanonicalAddresses.contains).sorted()
    }

    // MARK: Method

    /// How to send in `mode`. The typing indicator needs a one-to-one conversation and
    /// Accessibility. Keyboard mode finds the conversation by its title, so with a group
    /// Messages could show under the same title it could type into the group, and tincan
    /// paces instead. `auto` also paces while the screen is locked or you are using Messages.
    public func method(_ mode: Config.TypingMode, for route: SendRoute) throws -> (method: SendMethod, reason: String) {
        let lookalike = resolver.groups(titled: route.titles).first.map(resolver.title)
        let lookalikeReason = lookalike.map { "a group is also called “\($0)”, so tincan won't type into Messages" }
        switch mode {
        case .off: return (.immediate, "pacing is off")
        case .paced: return (.paced, "paced without the typing indicator")
        case .keyboard:
            guard route.keyboardAddress != nil else {
                throw PlanRefusal.issue(.invalidInput("The typing indicator works in one-to-one conversations only.", hint: "Use --typing paced for groups."))
            }
            if let lookalikeReason { return (.paced, lookalikeReason) }
            guard conditions.accessibilityAllowed() else {
                let host = PermissionHost.current
                throw PlanRefusal.issue(
                    PlanIssue(
                        code: "accessibility_required", message: "Showing the typing indicator needs Accessibility for \(host.subject).",
                        hint: host.grantStep(.accessibility) + " Or use --typing paced.", kind: .permission))
            }
            return (.keyboard, "typing into Messages")
        case .auto:
            guard route.keyboardAddress != nil else { return (.paced, "groups are paced without the typing indicator") }
            if let lookalikeReason { return (.paced, lookalikeReason) }
            guard conditions.accessibilityAllowed() else { return (.paced, "Accessibility isn't allowed, so no typing indicator") }
            if conditions.screenLocked() {
                return (.paced, "the screen is locked, so Messages can't be typed into")
            }
            if conditions.messagesInUse() {
                return (.paced, "you're using Messages right now, so tincan won't type into it")
            }
            return (.keyboard, "typing into Messages")
        }
    }
}

/// Where a send goes: the conversation, or the address a new one starts at, the service,
/// and who it reaches.
public struct SendRoute: Sendable {
    /// Who the send is to, as the reference named them.
    public enum Addressee: Sendable {
        /// The other person in a one-to-one conversation named by reference, by the address
        /// Messages stores.
        case address(String)
        /// A group, by its title.
        case group(String)
        /// A person, at the canonical address the send goes to.
        case person(Person, address: String)
    }

    /// The address a one-to-one send goes to is on other cards than the recipient's, so a
    /// message there reaches whoever uses it.
    public struct SharedDestination: Sendable {
        /// Every card that has the address.
        public let cards: [Contact]
        /// When the recipient has a card of their own, the other cards that have the address.
        /// Nil when the address is all tincan knows of them.
        public let others: [Contact]?
    }

    public let addressee: Addressee
    /// The recipient's name, as results show it: the card's name, the group's title, or the
    /// formatted address.
    public let name: String
    /// The canonical address the send goes to; nil for a group.
    public let address: String?
    /// The region `address` is formatted in.
    let region: String?
    public let chat: Chat?
    public let destination: SendDestination
    public let service: MessageService
    /// Set for one-to-one conversations, where the typing indicator can be shown.
    public let keyboardAddress: String?
    /// Titles that identify the conversation in Messages before typing into it.
    public let titles: [String]
    /// Why this conversation: the one named, the thread with the address given, or the
    /// most recent of one address's threads.
    public let reason: String
    /// Who a one-to-one send reaches, to check the address against Contacts.
    public var recipient: Person? = nil
    /// Everyone in a group besides you, by address.
    public var participants: [String] = []
    /// A send to `me`.
    public var isSelf = false
    /// No conversation shows which service the address uses, and none was asked for:
    /// tincan asks for iMessage, and Messages decides.
    public var serviceGuessed = false
    /// No service was asked for, and the send goes over iMessage although Messages lists the
    /// conversation as SMS or RCS, because its recent messages went over iMessage.
    public var serviceSwitched = false
    /// The service of the conversation's newest recent message, when there is one.
    public var recentService: MessageService? = nil
    /// The recipient's card has the address without its country code, which matches less
    /// certainly.
    public internal(set) var nationalMatch = false
    public internal(set) var shared: SharedDestination?

    /// The address, formatted for people, or "this address".
    var shownAddress: String { address.map { Address($0, region: region).formatted } ?? "this address" }
    /// Someone without a card is only their address; don't say it twice.
    var whom: String { name == shownAddress ? shownAddress : "\(name) at \(shownAddress)" }
}

/// Everything a send does, decided before anything goes: the route, the method, the pacing
/// and the files. A dry run shows it; a send executes `request`.
public struct SendPlan: Sendable {
    public let route: SendRoute
    public let method: SendMethod
    /// Why this method, for people: "typing into Messages", "pacing is off".
    public let methodReason: String
    public let typing: TypingPlan
    public let files: [Attachments.File]

    /// What `Sender` runs.
    public var request: Sender.Request {
        Sender.Request(
            destination: route.destination,
            chatID: route.chat?.id,
            plan: typing,
            files: files.map(\.path),
            method: method,
            keyboardAddress: route.keyboardAddress,
            keyboardService: route.service,
            expectedTitles: route.titles
        )
    }

    /// For a preview: sending starts a new conversation, and without a terminal that needs
    /// `--new-conversation`. Nil when the conversation exists.
    public var newConversationWarning: PlanWarning? {
        guard route.chat == nil else { return nil }
        // The preview must say what the send will ask for, before anyone approves it.
        return .notice(
            code: "new_conversation",
            message: route.isSelf
                ? "You have no conversation with yourself yet; sending starts one at \(route.shownAddress). Without a terminal that needs --new-conversation, added only after the person confirms it is their own address."
                : "You have never messaged \(route.whom); sending starts a new conversation. Without a terminal that needs --new-conversation, added only after the person confirms this exact number or email."
        )
    }

    /// Refuses to start a new conversation unless `allowed`, as a send without a terminal
    /// must: only the person can confirm the exact number or email.
    public func checkNewConversation(allowed: Bool) throws {
        guard route.chat == nil && !allowed else { return }
        throw PlanRefusal.issue(
            route.isSelf
                ? PlanIssue(
                    code: "new_conversation",
                    message:
                        "You have no conversation with yourself yet. Sending to yourself at \(route.shownAddress) starts one, which needs --new-conversation.",
                    hint: "Only add --new-conversation after the person confirms \(route.shownAddress) is their own number or email.",
                    kind: .needsInput
                )
                : PlanIssue(
                    code: "new_conversation",
                    message: "You have never messaged \(route.whom). Starting a new conversation needs --new-conversation.",
                    hint: "Only add --new-conversation after the person confirms this exact number or email.",
                    kind: .needsInput
                ))
    }

    /// What to ask the person in a terminal before sending.
    public var question: String {
        let count = Wording.plural(typing.bubbles.count + files.count, "message")
        guard route.chat == nil else { return "Send \(count) to \(route.name)?" }
        return route.isSelf
            ? "Start a conversation with yourself at \(route.shownAddress) and send \(count)?"
            : "Start a new conversation with \(route.whom) and send \(count)?"
    }
}
