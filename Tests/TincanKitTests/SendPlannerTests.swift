import Foundation
import Testing

@testable import TincanKit

/// Where a send goes and how, decided from a fixture chat.db and address book. Nothing here
/// sends: the planner only reads.
@Suite("Send planning")
struct SendPlannerTests {
    let resolver: Resolver
    let mayaIMessage: Int64
    let mayaSMS: Int64
    let mayaEmail: Int64
    let samLeeChat: Int64
    let leeLine: Int64
    let junk: Int64
    let crew: Int64

    /// Two cards for one home line.
    static let jordan = Contact(id: "jordan-lee", givenName: "Jordan", familyName: "Lee", phones: [SampleContacts.phone("+14155550177", label: "home")])
    static let riley = Contact(id: "riley-lee", givenName: "Riley", familyName: "Lee", phones: [SampleContacts.phone("+14155550177", label: "home")])
    /// Two numbers, and no conversation yet.
    static let lena = Contact(
        id: "lena", givenName: "Lena", familyName: "Berg", phones: [SampleContacts.phone("+14155550135"), SampleContacts.phone("+14155550136")]
    )
    /// A number and an email, and no conversation yet.
    static let noor = Contact(
        id: "noor", givenName: "Noor", familyName: "Haddad", phones: [SampleContacts.phone("+14155550134")], emails: [SampleContacts.email("noor@example.com")]
    )

    init() throws {
        let fixture = try MessagesFixture()
        // Maya writes over iMessage and SMS from one number, and from her email.
        let mayaI = try fixture.addHandle("+14155550142", service: "iMessage")
        let mayaS = try fixture.addHandle("+14155550142", service: "SMS")
        let mayaE = try fixture.addHandle("maya.ortiz@example.com")
        let samLee = try fixture.addHandle("+14155550143")
        let lee = try fixture.addHandle("+14155550177")
        let stranger = try fixture.addHandle("+14155550161")
        let other = try fixture.addHandle("+14155550162")
        mayaIMessage = try fixture.addChat("iMessage;-;+14155550142", participants: [mayaI])
        mayaSMS = try fixture.addChat("SMS;-;+14155550142", service: "SMS", participants: [mayaS])
        mayaEmail = try fixture.addChat("iMessage;-;maya.ortiz@example.com", participants: [mayaE])
        samLeeChat = try fixture.addChat("iMessage;-;+14155550143", participants: [samLee])
        leeLine = try fixture.addChat("iMessage;-;+14155550177", participants: [lee])
        junk = try fixture.addChat("iMessage;-;+14155550161", participants: [stranger], isFiltered: true)
        crew = try fixture.addChat("iMessage;+;chat100200300", displayName: "Climbing crew", participants: [mayaI, samLee])
        // Someone you don't know called a group "Sam Lee", so Messages can show it under his name.
        try fixture.addChat("iMessage;+;chat400500600", displayName: "Sam Lee", participants: [other], isFiltered: true)

        let messages = try fixture.open(excluding: [])
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        resolver = Resolver(
            directory: Directory(
                contacts: [
                    SampleContacts.maya, SampleContacts.samLee, SampleContacts.samPatel, SampleContacts.kenji, Self.jordan, Self.riley, Self.lena, Self.noor,
                ],
                region: "US"
            ),
            chats: try messages.allChats(),
            handles: Array(try messages.handles().values),
            excludedChatIDs: messages.excludedChatIDs,
            // The SMS thread is Maya's most recent, then iMessage, then email.
            activity: [mayaSMS: day.addingTimeInterval(300), mayaIMessage: day.addingTimeInterval(200), mayaEmail: day.addingTimeInterval(100)]
        )
    }

    static func conditions(accessibility: Bool = true, locked: Bool = false, inUse: Bool = false) -> SendPlanner.Conditions {
        SendPlanner.Conditions(accessibilityAllowed: { accessibility }, screenLocked: { locked }, messagesInUse: { inUse })
    }

    func planner(
        _ resolver: Resolver? = nil, exclusions: [String] = [], own: [String] = ["+14155550101"],
        conditions: SendPlanner.Conditions = SendPlannerTests.conditions()
    ) -> SendPlanner {
        let resolver = resolver ?? self.resolver
        return SendPlanner(
            resolver: resolver, region: "US", activity: resolver.activity, exclusions: exclusions,
            ownAddresses: { own }, relativeTime: { _ in "recently" }, conditions: conditions
        )
    }

    func planning(
        _ reference: String, service: MessageService? = nil, typing: Config.TypingMode = .paced, planner: SendPlanner? = nil
    ) throws -> (plan: SendPlan, warnings: [PlanWarning]) {
        var warnings: [PlanWarning] = []
        let request = SendPlanner.Request(reference: reference, bubbles: ["hi"], service: service, typing: typing, wordsPerMinute: 42, seed: 7)
        let plan = try (planner ?? self.planner()).plan(request, warnings: &warnings)
        return (plan, warnings)
    }

    /// The refusal `body` throws, or nil when it plans.
    func refusal(_ body: () throws -> Any) -> PlanRefusal? {
        do {
            _ = try body()
            return nil
        } catch let refusal as PlanRefusal {
            return refusal
        } catch {
            Issue.record("Expected a PlanRefusal, got \(error)")
            return nil
        }
    }

    func refused(_ body: () throws -> Any) -> PlanIssue? {
        guard case .issue(let issue)? = refusal(body) else { return nil }
        return issue
    }

    // MARK: Routing

    @Test func anAddressDecidesTheConversation() throws {
        let number = try planning("+14155550142").plan
        #expect(number.route.chat?.id == mayaSMS)
        #expect(number.route.reason == "the most recent of 2 conversations with the address you gave")
        #expect(number.route.address == "+14155550142")
        #expect(number.request.chatID == mayaSMS)
        #expect(number.request.destination == .chat(guid: "SMS;-;+14155550142", service: .sms, address: "+14155550142"))
        let email = try planning("address:maya.ortiz@example.com").plan
        #expect(email.route.chat?.id == mayaEmail)
        #expect(email.route.reason == "the conversation with the address you gave")
    }

    @Test func aPersonTextedAtSeveralAddressesIsTheirChoice() throws {
        let issue = try #require(refused { try planning("Maya") })
        #expect(issue.code == "ambiguous_destination")
        #expect(issue.kind == .needsInput)
        #expect(issue.message == "You text Maya Ortiz at 2 addresses. Say which conversation:")
        #expect(issue.candidates.map(\.reference) == ["chat:\(mayaSMS)", "chat:\(mayaIMessage)", "chat:\(mayaEmail)"])
        #expect(issue.candidates.first?.name == "+1 (415) 555-0142 · SMS")
        #expect(issue.candidates.first?.detail == "last message recently")
        #expect(issue.candidates.allSatisfy { $0.conversations == 1 })
        // Hints never name a candidate.
        #expect(!issue.hint.contains("chat:\(mayaSMS)"))

        let sms = try planning("Maya", service: .sms).plan
        #expect(sms.route.chat?.id == mayaSMS)
        #expect(sms.route.reason == "your conversation with Maya Ortiz")
        // Over iMessage she still has two addresses.
        #expect(refused { try planning("Maya", service: .iMessage) }?.candidates.count == 2)
    }

    @Test func aConversationNamedByReferenceKeepsItsService() throws {
        let issue = try #require(refused { try planning("chat:\(mayaIMessage)", service: .sms) })
        #expect(issue.code == "invalid_input")
        #expect(issue.kind == .usage)
        #expect(issue.message == "chat:\(mayaIMessage) is an iMessage conversation.")
        let route = try planning("chat:\(mayaIMessage)").plan.route
        #expect(route.reason == "the conversation you named")
        #expect(route.name == "Maya Ortiz")
        guard case .address(let address) = route.addressee else {
            Issue.record("A one-to-one conversation is addressed to its other person, got \(route.addressee)")
            return
        }
        #expect(address == "+14155550142")
    }

    @Test func someoneNewIsANewConversationThatNeedsConsent() throws {
        let (plan, warnings) = try planning("+14155550133")
        #expect(plan.route.chat == nil)
        #expect(plan.route.serviceGuessed)
        #expect(plan.request.destination == .address("+14155550133", service: .iMessage))
        #expect(plan.route.reason == "a new conversation at +1 (415) 555-0133")
        #expect(warnings.map(\.code) == ["service_unknown"])
        #expect(plan.newConversationWarning?.code == "new_conversation")
        #expect(plan.question == "Start a new conversation with +1 (415) 555-0133 and send 1 message?")
        let refusedNew = try #require(refused { try plan.checkNewConversation(allowed: false) })
        #expect(refusedNew.code == "new_conversation")
        #expect(refusedNew.hint == "Only add --new-conversation after the person confirms this exact number or email.")
        #expect(refused { try plan.checkNewConversation(allowed: true) } == nil)
        // A service asked for is no guess, and an existing conversation needs no consent.
        #expect(try planning("+14155550133", service: .sms).warnings.isEmpty)
        let existing = try planning("maya.ortiz@example.com").plan
        #expect(existing.newConversationWarning == nil)
        #expect(existing.question == "Send 1 message to Maya Ortiz?")
    }

    @Test func aFirstMessageGoesToTheOnlyNumberAndNeverToAGuess() throws {
        // A phone number wins over an email.
        #expect(try planning("Noor").plan.route.address == "+14155550134")
        let lena = try #require(refused { try planning("Lena") })
        #expect(lena.code == "ambiguous_address")
        #expect(lena.candidates.map(\.reference) == ["+14155550135", "+14155550136"])
        #expect(lena.candidates.allSatisfy { $0.conversations == 0 && $0.detail == "phone" })
        // A number saved without its country code names no line.
        guard case .incompleteNumber(let number, let owner, _, _, let command)? = refusal({ try planning("Kenji") }) else {
            Issue.record("Kenji's number has no country code")
            return
        }
        #expect(number == "09012345678")
        #expect(owner == "Kenji Sato")
        #expect(command == "send")
    }

    @Test func meIsYourOwnConversation() throws {
        let plan = try planning("me").plan
        #expect(plan.route.isSelf)
        #expect(plan.route.reason == "a new conversation with yourself at +1 (415) 555-0101")
        #expect(plan.question == "Start a conversation with yourself at +1 (415) 555-0101 and send 1 message?")
        let refusedNew = try #require(refused { try plan.checkNewConversation(allowed: false) })
        #expect(
            refusedNew.message
                == "You have no conversation with yourself yet. Sending to yourself at +1 (415) 555-0101 starts one, which needs --new-conversation.")
        // With Maya's number as your own, `me` continues that conversation.
        let own = try planning(" ME ", planner: planner(own: ["+14155550142"])).plan
        #expect(own.route.chat?.id == mayaSMS)
        #expect(own.route.reason == "the most recent of 2 conversations with yourself")
        let nobody = try #require(refused { try planning("me", planner: planner(own: [])) })
        #expect(nobody.code == "no_own_address")
    }

    @Test func onlyNumbersAndEmailsAreAddresses() throws {
        for reference in ["@", "maya@", "@example.com", "+14155550142 or +14155550188", "address:@"] {
            let issue = try #require(refused { try planning(reference) }, "\(reference)")
            #expect(issue.code == "invalid_input", "\(reference)")
            #expect(issue.hint.contains("`tincan send <reference> …`"))
        }
        // An incomplete or unknown reference is identity's to describe.
        guard case .unresolved(.incompleteNumber, let command)? = refusal({ try planning("555-0142") }) else {
            Issue.record("555-0142 names no line")
            return
        }
        #expect(command == "send")
        guard case .unresolved(.notFound, _)? = refusal({ try planning("Nobody Known") }) else {
            Issue.record("Nobody is called that")
            return
        }
    }

    @Test func aGroupIsSentToOnlyByItsReference() throws {
        let issue = try #require(refused { try planning("Climbing crew") })
        #expect(issue.code == "ambiguous")
        #expect(issue.candidates.map(\.reference) == ["chat:\(crew)"])
        #expect(issue.candidates.first?.detail == "group with Maya Ortiz, Sam Lee and you")
        #expect(issue.hint.contains("`tincan send <reference> …`"))
        let (plan, _) = try planning("chat:\(crew)", typing: .auto)
        #expect(plan.route.participants == ["+14155550142", "+14155550143"])
        #expect(plan.route.keyboardAddress == nil)
        #expect(plan.method == .paced)
        #expect(plan.methodReason == "groups are paced without the typing indicator")
        guard case .group(let title) = plan.route.addressee else {
            Issue.record("A group is addressed by its title")
            return
        }
        #expect(title == "Climbing crew")
    }

    @Test func excludedPeopleAreNeverMessaged() throws {
        // Excluding one of Maya's conversations refuses every one of them.
        let fixture = try MessagesFixture()
        let handle = try fixture.addHandle("+14155550142")
        let text = try fixture.addChat("SMS;-;+14155550142", service: "SMS", participants: [handle])
        let mail = try fixture.addChat("iMessage;-;maya.ortiz@example.com", participants: [try fixture.addHandle("maya.ortiz@example.com")])
        let messages = try fixture.open(excluding: [text])
        let excluded = Resolver(
            directory: resolver.directory, chats: try messages.allChats(), handles: Array(try messages.handles().values),
            excludedChatIDs: messages.excludedChatIDs
        )
        for reference in ["Maya", "maya.ortiz@example.com", "chat:\(mail)"] {
            guard case .excludedPerson(let person, let chats)? = refusal({ try planning(reference, planner: planner(excluded)) }) else {
                Issue.record("\(reference) is excluded")
                continue
            }
            #expect(person.name == "Maya Ortiz")
            #expect(chats.map(\.id) == [text])
        }
        // An excluded address covers conversations that don't exist yet.
        guard case .excludedPerson(_, let chats)? = refusal({ try planning("+14155550133", planner: planner(exclusions: ["address:+14155550133"])) }) else {
            Issue.record("An excluded address is never messaged")
            return
        }
        #expect(chats.isEmpty)
    }

    @Test func anAddressOnSeveralCardsReachesWhoeverUsesIt() throws {
        let (jordan, jordanWarnings) = try planning("Jordan Lee")
        #expect(jordan.route.chat?.id == leeLine)
        #expect(jordan.route.shared?.cards.map(\.id) == ["jordan-lee", "riley-lee"])
        #expect(jordan.route.shared?.others?.map(\.id) == ["riley-lee"])
        guard case .sharedAddress(let person, let consequence)? = jordanWarnings.first else {
            Issue.record("The shared line is named")
            return
        }
        #expect(person.sharedAddresses.map(\.address) == ["+14155550177"])
        #expect(consequence == "A message there reaches whoever uses it, not only Jordan Lee.")

        // The number alone is on no card of its own.
        let (line, lineWarnings) = try planning("+14155550177")
        #expect(line.route.shared?.cards.count == 2)
        #expect(line.route.shared?.others == nil)
        guard case .sharedAddress(_, let lineConsequence)? = lineWarnings.first else {
            Issue.record("The shared line is named")
            return
        }
        #expect(lineConsequence == "A message there reaches whoever uses it.")
    }

    @Test func aConversationFiledAsJunkIsNamed() throws {
        let (plan, warnings) = try planning("chat:\(junk)")
        #expect(plan.route.chat?.isFiltered == true)
        #expect(warnings.map(\.code) == ["filtered_conversation"])
    }

    // MARK: Method

    @Test func theTypingIndicatorNeedsAOneToOneConversationAndAccessibility() throws {
        let off = try planning("Sam Lee", typing: .off).plan
        #expect(off.method == .immediate)
        #expect(off.methodReason == "pacing is off")
        #expect(off.typing.bubbles.allSatisfy { $0.typingDuration == 0 })
        let group = try #require(refused { try planning("chat:\(crew)", typing: .keyboard) })
        #expect(group.code == "invalid_input")
        let denied = try #require(refused { try planning("Sam Patel", typing: .keyboard, planner: planner(conditions: Self.conditions(accessibility: false))) })
        #expect(denied.code == "accessibility_required")
        #expect(denied.kind == .permission)
        #expect(try planning("Sam Patel", typing: .keyboard).plan.method == .keyboard)

        for (conditions, reason) in [
            (Self.conditions(accessibility: false), "Accessibility isn't allowed, so no typing indicator"),
            (Self.conditions(locked: true), "the screen is locked, so Messages can't be typed into"),
            (Self.conditions(inUse: true), "you're using Messages right now, so tincan won't type into it"),
        ] {
            let paced = try planning("Sam Patel", typing: .auto, planner: planner(conditions: conditions)).plan
            #expect(paced.method == .paced)
            #expect(paced.methodReason == reason)
        }
        #expect(try planning("Sam Patel", typing: .auto).plan.methodReason == "typing into Messages")
    }

    @Test func aGroupNamedLikeThePersonKeepsTincanFromTypingIntoMessages() throws {
        for mode in [Config.TypingMode.keyboard, .auto] {
            let plan = try planning("Sam Lee", typing: mode).plan
            #expect(plan.route.chat?.id == samLeeChat)
            #expect(plan.method == .paced)
            #expect(plan.methodReason == "a group is also called “Sam Lee”, so tincan won't type into Messages")
        }
    }

    @Test func thePlanIsWhatTheSendRuns() throws {
        let first = try planning("Sam Lee").plan
        let again = try planning("Sam Lee").plan
        #expect(first.typing == again.typing)
        let request = first.request
        #expect(request.chatID == samLeeChat)
        #expect(request.keyboardAddress == "+14155550143")
        #expect(request.keyboardService == .iMessage)
        #expect(request.expectedTitles == ["Sam Lee", "+14155550143", "+1 (415) 555-0143"])
        #expect(request.method == .paced)
        // Two cards named Sam Lee would leave the name out: only the number identifies him.
        let twin = Contact(id: "sam-lee-2", givenName: "Sam", familyName: "Lee", phones: [SampleContacts.phone("+14155550199")])
        let twins = Resolver(
            directory: Directory(contacts: resolver.directory.contacts + [twin], region: "US"), chats: resolver.chats, handles: [],
            extraAddresses: resolver.knownAddresses
        )
        #expect(try planning("chat:\(samLeeChat)", planner: planner(twins)).plan.route.titles == ["+14155550143", "+1 (415) 555-0143"])
        // Names that differ only in punctuation or spaces look the same in Messages' titles.
        let lookalike = Contact(id: "sam-lee-3", givenName: "Sam", familyName: "Lée.", phones: [SampleContacts.phone("+14155550198")])
        let lookalikes = Resolver(
            directory: Directory(contacts: resolver.directory.contacts + [lookalike], region: "US"), chats: resolver.chats, handles: [],
            extraAddresses: resolver.knownAddresses
        )
        #expect(try planning("chat:\(samLeeChat)", planner: planner(lookalikes)).plan.route.titles == ["+14155550143", "+1 (415) 555-0143"])
    }

    // MARK: Bubbles and files

    @Test func bubblesAreChecked() throws {
        let empty = try #require(refused { try SendPlanner.check([], files: [], wordsPerMinute: nil, to: "Maya Ortiz") })
        #expect(empty.message == "Nothing to send.")
        #expect(empty.hint == "Pass the text as arguments: `tincan send 'Maya Ortiz' \"hello\"`.")
        let many = try #require(refused { try SendPlanner.check((1...13).map { "bubble \($0)" }, files: [], wordsPerMinute: nil, to: "Maya") })
        #expect(many.message == "That's 13 bubbles; tincan sends at most 12 at a time.")
        let long = try #require(refused { try SendPlanner.check([String(repeating: "a", count: 4_001)], files: [], wordsPerMinute: nil, to: "Maya") })
        #expect(long.kind == .usage)
        let slow = try #require(refused { try SendPlanner.check(["hi"], files: [], wordsPerMinute: 4, to: "Maya") })
        #expect(slow.message == "--wpm must be between 5 and 250.")
        #expect(try SendPlanner.check(["hi"], files: [], wordsPerMinute: 42, to: "Maya").isEmpty)

        for (bubbles, message) in [
            (["fine", "look \u{1B}[2Jhere"], "Bubble 2 contains a control character, U+001B (escape), which Messages would send as is."),
            (
                ["invoice \u{202E}fdp.exe"],
                "The bubble contains U+202E (right-to-left override), which changes how Messages shows the text, so the preview isn't what they would see."
            ),
            (["lunch?\u{E0049}\u{E0067}"], "The bubble contains U+E0049 (tag character), which Messages doesn't show, so it would hide text from them."),
        ] {
            let issue = try #require(refused { try SendPlanner.check(bubbles, files: [], wordsPerMinute: nil, to: "Maya") })
            #expect(issue.message == message)
        }
        // Emoji that join, select presentation or carry a flag's tags are text; so are new lines and tabs.
        let text = [
            "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} 👨\u{200D}👩\u{200D}👧 1\u{FE0F}\u{20E3}", "two\nlines\tand a tab", "pass\u{200B}word",
        ]
        #expect(BubbleText.firstHiddenCharacter(in: text) == nil)
        let separator = BubbleText.HiddenCharacter(index: 1, description: "U+2028 (line separator)", kind: .layout)
        #expect(BubbleText.firstHiddenCharacter(in: ["ok", "a\u{2028}b"]) == separator)
        #expect(BubbleText.firstHiddenCharacter(in: ["c1 \u{9B}31m"])?.description == "U+009B")
    }

    @Test func filesAreCheckedWhereTheyReallyAre() throws {
        let device = try #require(refused { try SendPlanner.check(["hi"], files: ["/dev/zero"], wordsPerMinute: nil, to: "Maya") })
        #expect(device.code == "file_not_allowed")
        #expect(device.kind == .needsInput)
        #expect(device.message == "/dev/zero is a device, not a file.")
        let missing = try #require(refused { try SendPlanner.check(["hi"], files: ["/nonexistent/itinerary.pdf"], wordsPerMinute: nil, to: "Maya") })
        #expect(missing.code == "invalid_input")
        #expect(missing.message == "Can't read /nonexistent/itinerary.pdf.")
        let large = SendPlanner.issue(for: .tooLarge(path: "/Volumes/Photos/movie.mov", bytes: 250_000_000), given: "movie.mov")
        #expect(large.code == "file_too_large")
        #expect(large.message == "/Volumes/Photos/movie.mov is 250 MB, larger than the 100 MB Messages sends.")
        let home = NSHomeDirectory() + "/Library"
        let library = SendPlanner.issue(for: .protectedLocation(path: home, folder: home), given: "~/Library")
        #expect(library.message == "tincan doesn't attach ~/Library, which holds private data.")
    }
}
