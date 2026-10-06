import Foundation
import Testing

@testable import TincanKit

/// The resolver is built the way the CLI builds it: contacts from a provider, chats and
/// handles from chat.db.
@Suite("Resolver")
struct ResolverTests {
    let fixture: MessagesFixture
    let resolver: Resolver
    let mayaIMessage: Int64
    let mayaSMS: Int64
    let mayaRCS: Int64
    let mayaEmail: Int64
    let mayaExcluded: Int64
    let climbing: Int64
    let unnamedGroup: Int64
    let bigGroup: Int64
    let excludedGroup: Int64

    init() throws {
        let fixture = try MessagesFixture()
        self.fixture = fixture
        // Maya writes over iMessage, SMS and RCS from one number, and from her email:
        // four handle rows, four one-to-one chats, one person.
        let mayaI = try fixture.addHandle("+14155550142", service: "iMessage")
        let mayaS = try fixture.addHandle("+14155550142", service: "SMS")
        let mayaR = try fixture.addHandle("+14155550142", service: "RCS")
        let mayaE = try fixture.addHandle("maya.ortiz@example.com", service: "iMessage")
        let samLee = try fixture.addHandle("+14155550143")
        let samPatel = try fixture.addHandle("+14155550144")
        let strangers = try (1...4).map { try fixture.addHandle("+1415555016\($0)") }

        mayaIMessage = try fixture.addChat("iMessage;-;+14155550142", participants: [mayaI])
        mayaSMS = try fixture.addChat("SMS;-;+14155550142", service: "SMS", participants: [mayaS])
        mayaRCS = try fixture.addChat("RCS;-;+14155550142", service: "RCS", participants: [mayaR])
        mayaEmail = try fixture.addChat("iMessage;-;maya.ortiz@example.com", participants: [mayaE])
        mayaExcluded = try fixture.addChat("any;-;+14155550142", participants: [mayaI])
        climbing = try fixture.addChat("iMessage;+;chat100200300", displayName: "Climbing crew", participants: [mayaI, samLee])
        unnamedGroup = try fixture.addChat("iMessage;+;chat400500600", participants: [mayaI, samPatel])
        bigGroup = try fixture.addChat("iMessage;+;chat700800900", participants: strangers)
        excludedGroup = try fixture.addChat("iMessage;+;chat999999999", displayName: "Surprise party", participants: [mayaI, samLee])

        let provider = InMemoryContactsProvider([SampleContacts.maya, SampleContacts.samLee, SampleContacts.samPatel])
        let excluded: Set<Int64> = [mayaExcluded, excludedGroup]
        let messages = try fixture.open(excluding: excluded)
        resolver = Resolver(
            directory: Directory(contacts: try provider.fetchAll(), region: "US"),
            chats: try messages.allChats(),
            handles: Array(try messages.handles().values),
            excludedChatIDs: messages.excludedChatIDs
        )
    }

    private func chat(_ reference: String) throws -> Chat {
        guard case .chat(let chat) = try resolver.resolve(reference) else {
            throw FixtureError(description: "\(reference) did not resolve to a chat")
        }
        return chat
    }

    private func person(_ reference: String) throws -> Person {
        guard case .person(let person) = try resolver.resolve(reference) else {
            throw FixtureError(description: "\(reference) did not resolve to a person")
        }
        return person
    }

    // MARK: Candidates

    @Test func ambiguousNamesListEveryCandidateWithTheFactsThatTellThemApart() throws {
        let activity = [climbing: Date(timeIntervalSinceReferenceDate: 800_000_000), unnamedGroup: Date(timeIntervalSinceReferenceDate: 810_000_000)]
        let described = Resolver(
            directory: resolver.directory, chats: resolver.chats, handles: [],
            extraAddresses: resolver.knownAddresses, excludedChatIDs: resolver.excludedChatIDs, activity: activity
        )
        do {
            _ = try described.resolve("Sam")
            Issue.record("Two people named Sam must be ambiguous")
        } catch ResolveError.ambiguous(_, let candidates) {
            #expect(candidates.count == 2)
            let lee = try #require(candidates.first { $0.addresses.contains("+14155550143") })
            let patel = try #require(candidates.first { $0.addresses.contains("+14155550144") })
            #expect(lee.conversations == 1)
            #expect(lee.lastActivity == activity[climbing])
            #expect(patel.lastActivity == activity[unnamedGroup])
            #expect(lee.reference != patel.reference)
        }
    }

    // MARK: References

    @Test func chatReferencesUseTheIDOrTheGUID() throws {
        #expect(try chat("chat:\(climbing)").id == climbing)
        #expect(try chat("CHAT:\(climbing)").id == climbing)
        #expect(try chat("chat:iMessage;+;chat100200300").id == climbing)
    }

    @Test func unknownChatReferencesAreNotFound() {
        #expect(throws: ResolveError.self) { try resolver.resolve("chat:424242") }
    }

    @Test func excludedChatsRefuseToResolve() throws {
        let error = #expect(throws: ResolveError.self) { try resolver.resolve("chat:\(excludedGroup)") }
        guard case .excluded(let chat)? = error else {
            Issue.record("expected .excluded, got \(String(describing: error))")
            return
        }
        #expect(chat.id == excludedGroup)
    }

    @Test func contactReferencesUseTheContactID() throws {
        let maya = try person("contact:maya")
        #expect(maya.contact?.id == "maya")
        #expect(maya.name == "Maya Ortiz")
        #expect(maya.reference == "contact:maya")
        #expect(Set(maya.addresses) == ["+14155550142", "maya.ortiz@example.com"])
        #expect(throws: ResolveError.self) { try resolver.resolve("contact:nobody") }
    }

    @Test func phoneNumbersInAnyFormatFindTheContact() throws {
        #expect(try person("(415) 555-0142").contact?.id == "maya")
        #expect(try person("+1 415 555 0142").contact?.id == "maya")
    }

    @Test func emailsFindTheContactIgnoringCase() throws {
        #expect(try person("MAYA.ORTIZ@example.com").contact?.id == "maya")
    }

    @Test func unknownNumbersBecomeAddressOnlyPeople() throws {
        let stranger = try person("415-555-0161")
        #expect(stranger.contact == nil)
        #expect(stranger.name == "+1 (415) 555-0161")
        #expect(stranger.addresses == ["+14155550161"])
        #expect(stranger.reference == "+14155550161")
    }

    @Test func textLooksLikeAnAddressWhenItIsANumberOrEmail() {
        #expect(Resolver.looksLikeAddress("maya@example.com"))
        #expect(Resolver.looksLikeAddress("+44 20 7946 0000"))
        #expect(Resolver.looksLikeAddress("(415) 555-0142"))
        #expect(!Resolver.looksLikeAddress("Maya"))
        #expect(!Resolver.looksLikeAddress("Room 101"))
        #expect(!Resolver.looksLikeAddress("42"))
    }

    // MARK: Names

    @Test func aUniqueNameResolvesToThePerson() throws {
        #expect(try person("maya").contact?.id == "maya")
        #expect(try person("Patel").contact?.id == "sam-patel")
    }

    @Test func anExactFullNameWinsOverPartialMatches() throws {
        #expect(try person("Sam Lee").contact?.id == "sam-lee")
    }

    @Test func ambiguousNamesListEveryCandidate() throws {
        let error = #expect(throws: ResolveError.self) { try resolver.resolve("Sam") }
        guard case .ambiguous(let query, let candidates)? = error else {
            Issue.record("expected .ambiguous, got \(String(describing: error))")
            return
        }
        #expect(query == "Sam")
        #expect(candidates.map(\.reference) == ["contact:sam-lee", "contact:sam-patel"])
        #expect(candidates.map(\.name) == ["Sam Lee", "Sam Patel"])
        #expect(candidates.first?.detail == "+1 (415) 555-0143")
        #expect(candidates.last?.detail == "+1 (415) 555-0144 · Northwind")
    }

    @Test func unknownNamesAreNotFound() {
        let error = #expect(throws: ResolveError.self) { try resolver.resolve("Zed") }
        guard case .notFound(let query, let suggestion)? = error else {
            Issue.record("expected .notFound, got \(String(describing: error))")
            return
        }
        #expect(query == "Zed")
        #expect(suggestion != nil)
    }

    @Test func groupNamesResolveToTheGroup() throws {
        #expect(try chat("climbing crew").id == climbing)
        #expect(try chat("Climbing").id == climbing)
    }

    @Test func excludedGroupsCannotBeFoundByName() {
        #expect(throws: ResolveError.self) { try resolver.resolve("Surprise party") }
    }

    // MARK: Conversations

    @Test func directChatsMergeEveryServiceAndAddressOfAPerson() throws {
        let maya = try person("contact:maya")
        #expect(resolver.directChats(with: maya).map(\.id) == [mayaIMessage, mayaSMS, mayaRCS, mayaEmail])
    }

    @Test func directChatsForAnAddressOnlyPerson() throws {
        let unknown = try person("+1 415 555 0161")
        #expect(resolver.directChats(with: unknown).isEmpty)
        #expect(resolver.groupChats(with: unknown).map(\.id) == [bigGroup])
    }

    @Test func groupChatsIncludeThePersonAndSkipExcludedOnes() throws {
        let maya = try person("contact:maya")
        #expect(resolver.groupChats(with: maya).map(\.id) == [climbing, unnamedGroup])
        let samLee = try person("contact:sam-lee")
        #expect(resolver.groupChats(with: samLee).map(\.id) == [climbing])
        #expect(resolver.directChats(with: samLee).isEmpty)
    }

    @Test func titlesUseGroupNamesThenPeoplesNames() throws {
        let chats = Dictionary(uniqueKeysWithValues: resolver.chats.map { ($0.id, $0) })
        #expect(resolver.title(for: try #require(chats[mayaSMS])) == "Maya Ortiz")
        #expect(resolver.title(for: try #require(chats[climbing])) == "Climbing crew")
        #expect(resolver.title(for: try #require(chats[unnamedGroup])) == "Maya, Sam")
        #expect(resolver.title(for: try #require(chats[bigGroup])) == "+1 (415) 555-0161, +1 (415) 555-0162 and 2 others")
    }

    @Test func senderNamesFallBackToYouAndFormattedNumbers() {
        #expect(resolver.name(for: nil) == "You")
        #expect(resolver.name(for: "+14155550142") == "Maya Ortiz")
        #expect(resolver.name(for: "+14155550162") == "+1 (415) 555-0162")
    }
}

/// A single word is as likely to be someone's first name as another person's nickname or
/// whole name, so the resolver must ask instead of picking one.
@Suite("Name resolution")
struct NameResolutionTests {
    static let alexKim = Contact(id: "alex-kim", givenName: "Alex", familyName: "Kim", phones: [SampleContacts.phone("+1 415 555 0151")])
    static let alexander = Contact(
        id: "alexander", givenName: "Alexander", familyName: "Lee", nickname: "Alex", phones: [SampleContacts.phone("+1 415 555 0152")])
    static let alexOnly = Contact(id: "alex", givenName: "Alex", phones: [SampleContacts.phone("+1 415 555 0153")])

    private func resolver(_ contacts: [Contact], chats: [Chat] = []) -> Resolver {
        Resolver(directory: Directory(contacts: contacts, region: "US"), chats: chats, handles: [])
    }

    private func candidates(_ query: String, among contacts: [Contact]) -> Set<String>? {
        do {
            _ = try resolver(contacts).resolve(query)
            return nil
        } catch ResolveError.ambiguous(_, let candidates) {
            return Set(candidates.map(\.reference))
        } catch {
            return nil
        }
    }

    @Test func aNicknameDoesNotBeatSomeonesFirstName() {
        #expect(candidates("alex", among: [Self.alexKim, Self.alexander]) == ["contact:alex-kim", "contact:alexander"])
    }

    @Test func aOneWordCardDoesNotBeatSomeonesFirstName() {
        #expect(candidates("Alex", among: [Self.alexOnly, Self.alexKim]) == ["contact:alex", "contact:alex-kim"])
    }

    @Test func aFullNameOfSeveralWordsStillWins() throws {
        guard case .person(let person) = try resolver([Self.alexKim, Self.alexander, Self.alexOnly]).resolve("alex kim") else {
            Issue.record("expected a person")
            return
        }
        #expect(person.contact?.id == "alex-kim")
    }

    @Test func groupTitlesUseFullNamesWhenShortNamesCollide() {
        let group = Chat(
            id: 1, guid: "iMessage;+;chat100", kind: .group, service: .iMessage, displayName: nil, identifier: "chat100",
            participants: ["+14155550143", "+14155550144", "+14155550142"], isArchived: false, isFiltered: false, sendsReadReceipts: nil
        )
        let resolver = resolver([SampleContacts.samLee, SampleContacts.samPatel, SampleContacts.maya], chats: [group])
        #expect(resolver.title(for: group) == "Sam Lee, Sam Patel, Maya")
    }
}

@Suite("Contacts providers")
struct ContactsProviderTests {
    @Test(
        "Contacts permission reflects the provider's authorization",
        arguments: [
            (ContactsAuthorization.authorized, Permissions.State.granted),
            (.limited, .granted),
            (.notDetermined, .notDetermined),
            (.denied, .denied),
            (.restricted, .denied),
        ])
    func permission(authorization: ContactsAuthorization, state: Permissions.State) {
        #expect(Permissions.contacts(InMemoryContactsProvider(authorization: authorization)) == state)
    }

    @Test func contactsAreUnavailableWithoutAccess() {
        let provider = InMemoryContactsProvider([SampleContacts.maya], authorization: .denied)
        #expect(throws: ContactsError.self) { try provider.fetchAll() }
    }
}

/// A family line on two cards: whichever name you use, tincan says the number is shared and
/// with whom, and never lets either name hide the other.
@Suite("Shared addresses")
struct SharedAddressTests {
    static let robin = Contact(id: "robin", givenName: "Robin", familyName: "Ortiz", phones: [SampleContacts.phone("+1 415-555-0150", label: "home")])
    static let ari = Contact(
        id: "ari", givenName: "Ari", familyName: "Ortiz",
        phones: [SampleContacts.phone("(415) 555-0150", label: "home"), SampleContacts.phone("+1 415 555 0151")])
    static let home = Chat(
        id: 7, guid: "iMessage;-;+14155550150", kind: .direct, service: .iMessage, displayName: nil, identifier: "+14155550150",
        participants: ["+14155550150"], isArchived: false, isFiltered: false, sendsReadReceipts: nil
    )

    private let resolver = Resolver(
        directory: Directory(contacts: [robin, ari, SampleContacts.maya], region: "US"),
        chats: [home], handles: [], activity: [7: Date(timeIntervalSinceReferenceDate: 800_000_000)]
    )

    @Test func aNamedPersonListsTheOtherCardsOnTheirNumber() {
        let robin = resolver.person(for: Self.robin)
        #expect(robin.sharedWith.map(\.id) == ["ari"])
        #expect(robin.sharedAddresses.map(\.address) == ["+14155550150"])
        // Ari's second number is theirs alone.
        let ari = resolver.person(for: Self.ari)
        #expect(ari.sharedAddresses.map(\.address) == ["+14155550150"])
        #expect(ari.sharedWith.map(\.id) == ["robin"])
        #expect(resolver.person(for: SampleContacts.maya).sharedWith.isEmpty)
    }

    @Test func aSharedNumberOnItsOwnListsEveryCard() {
        let number = resolver.person(forAddress: "+14155550150")
        #expect(number.contact == nil)
        #expect(Set(number.sharedWith.map(\.id)) == ["robin", "ari"])
    }

    @Test func candidatesSayTheyShareTheNumberAndTheConversation() throws {
        do {
            _ = try resolver.resolve("Ortiz")
            Issue.record("Two cards named Ortiz must be ambiguous")
        } catch ResolveError.ambiguous(_, let candidates) {
            let robin = try #require(candidates.first { $0.reference == "contact:robin" })
            #expect(robin.detail == "same number as Ari Ortiz · chat:7")
            let shared = try #require(robin.sharesAddressWith.first)
            #expect(shared.reference == "contact:ari")
            #expect(shared.address == "+14155550150")
            #expect(shared.chats == ["chat:7"])
            #expect(robin.conversations == 1)
            #expect(robin.lastActivity == Date(timeIntervalSinceReferenceDate: 800_000_000))
            let ari = try #require(candidates.first { $0.reference == "contact:ari" })
            #expect(ari.detail == "same number as Robin Ortiz · chat:7 · +1 more")
        }
    }

    static let sky = Contact(id: "sky", givenName: "Sky", familyName: "Ortiz", phones: [SampleContacts.phone("415.555.0150", label: "home")])

    @Test func cardsWithExactlyTheSameAddressesAreTheAddressNotEitherCard() throws {
        let resolver = Resolver(directory: Directory(contacts: [Self.robin, Self.sky, SampleContacts.samLee], region: "US"), chats: [Self.home], handles: [])
        guard case .person(let person) = try resolver.resolve("Ortiz") else {
            Issue.record("expected a person")
            return
        }
        #expect(person.contact == nil)
        #expect(person.reference == "+14155550150")
        #expect(person.name == "+1 (415) 555-0150")
        #expect(Set(person.otherContacts.map(\.id)) == ["robin", "sky"])
        #expect(Set(person.sharedWith.map(\.id)) == ["robin", "sky"])
        #expect(resolver.directChats(with: person).map(\.id) == [7])
        // Maya Ortiz has another number, so the family name could mean her too.
        let withMaya = Resolver(directory: Directory(contacts: [Self.robin, Self.sky, SampleContacts.maya], region: "US"), chats: [Self.home], handles: [])
        #expect(throws: ResolveError.self) { try withMaya.resolve("Ortiz") }
    }

    @Test func cardsSharingSeveralAddressesAreAllOfThem() throws {
        let robin = Contact(
            id: "robin", givenName: "Robin", familyName: "Ortiz", phones: [SampleContacts.phone("+14155550150")],
            emails: [SampleContacts.email("home@example.com")])
        let sky = Contact(
            id: "sky", givenName: "Sky", familyName: "Ortiz", phones: [SampleContacts.phone("(415) 555-0150")],
            emails: [SampleContacts.email("Home@Example.com")])
        let resolver = Resolver(directory: Directory(contacts: [robin, sky], region: "US"), chats: [], handles: [])
        guard case .person(let person) = try resolver.resolve("Ortiz") else {
            Issue.record("expected a person")
            return
        }
        #expect(person.contact == nil)
        #expect(resolver.canonicalAddresses(of: person) == ["+14155550150", "home@example.com"])
        #expect(Set(person.otherContacts.map(\.id)) == ["robin", "sky"])
        #expect(person.sharedAddresses.map(\.address) == ["+14155550150", "home@example.com"])
    }

    @Test func anyDifferenceInAddressesKeepsTheNameAmbiguous() {
        // Ari's second number is theirs alone, so "Ortiz" could mean either card.
        #expect(throws: ResolveError.self) { try resolver.resolve("Ortiz") }
        // A card with no address at all shares nothing.
        let blank = Contact(id: "blank", givenName: "Pat", familyName: "Ortiz")
        let another = Contact(id: "another", givenName: "Lou", familyName: "Ortiz")
        let empty = Resolver(directory: Directory(contacts: [blank, another], region: "US"), chats: [], handles: [])
        #expect(throws: ResolveError.self) { try empty.resolve("Ortiz") }
    }
}

/// A number typed without its country code names no line on its own.
@Suite("Numbers without a country code")
struct IncompleteNumberTests {
    static let kenji = Contact(id: "kenji", givenName: "Kenji", familyName: "Sato", phones: [SampleContacts.phone("+81 90-1234-5678")])

    @Test func onlyNumbersTheRegionCantCompleteLackACountryCode() {
        #expect(Address("09012345678", region: "US").lacksCountryCode)
        #expect(Address("555-0142", region: "US").lacksCountryCode)
        #expect(!Address("(415) 555-0142", region: "US").lacksCountryCode)
        #expect(!Address("09012345678", region: "JP").lacksCountryCode)
        #expect(!Address("262966", region: "US").lacksCountryCode)
        #expect(!Address("maya@example.com", region: "US").lacksCountryCode)
    }

    @Test func aNationalMatchNamesTheCardWithoutAddingTheTypedDigits() {
        let resolver = Resolver(directory: Directory(contacts: [Self.kenji], region: "US"), chats: [], handles: [])
        let kenji = resolver.person(forAddress: "09012345678")
        #expect(kenji.contact?.id == "kenji")
        #expect(kenji.match == .national)
        #expect(kenji.addresses == ["+819012345678"])
        // A full number keeps being added, and matches exactly.
        let full = resolver.person(forAddress: "+81 90 1234 5678")
        #expect(full.match == .exact)
    }

    @Test func aFullNumberMatchingANationallySavedCardIsMarkedNational() {
        let resolver = Resolver(directory: Directory(contacts: [SampleContacts.kenji], region: "US"), chats: [], handles: [])
        let kenji = resolver.person(forAddress: "+819012345678")
        #expect(kenji.match == .national)
        #expect(kenji.addresses == ["+819012345678"])
    }

    @Test func aCardNumberWithoutItsCountryCodeGivesWayToTheFullNumberMessagesUses() {
        let directory = Directory(contacts: [SampleContacts.kenji], region: "US")
        let known = Resolver(directory: directory, chats: [], handles: [Handle(rowID: 1, address: "+819012345678", service: .iMessage)])
        #expect(known.person(for: SampleContacts.kenji).addresses == ["+819012345678"])
        // Without it, the card's digits are all tincan knows; `send` refuses them.
        let unknown = Resolver(directory: directory, chats: [], handles: [])
        #expect(unknown.person(for: SampleContacts.kenji).addresses == ["09012345678"])
    }

    /// A number known only from an excluded conversation is never offered as a completion:
    /// the list would say that conversation exists.
    @Test func completeNumbersLeaveOutAddressesOnlyInExcludedConversations() {
        let excluded = Chat(
            id: 7, guid: "SMS;-;+442090123456", kind: .direct, service: .sms, displayName: nil, identifier: "+442090123456",
            participants: ["+442090123456"], isArchived: false, isFiltered: false, sendsReadReceipts: nil
        )
        let resolver = Resolver(
            directory: Directory(contacts: [SampleContacts.maya], region: "US"), chats: [excluded],
            handles: [Handle(rowID: 1, address: "+442090123456", service: .sms)], excludedChatIDs: [7]
        )
        #expect(resolver.completeNumbers(for: "020 9012 3456").isEmpty)
    }

    @Test func completeNumbersListEveryFullNumberWithThoseDigits() {
        let resolver = Resolver(
            directory: Directory(contacts: [Self.kenji, SampleContacts.maya], region: "US"), chats: [],
            handles: [Handle(rowID: 1, address: "+442090123456", service: .iMessage)]
        )
        let options = resolver.completeNumbers(for: "09012345678")
        #expect(options.map(\.address.value) == ["+819012345678"])
        #expect(options.first?.contacts.map(\.id) == ["kenji"])
        // A number in Messages with no card is listed too.
        #expect(resolver.completeNumbers(for: "020 9012 3456").map(\.address.value) == ["+442090123456"])
        #expect(resolver.completeNumbers(for: "(415) 555-0142").isEmpty)
        // A local number without its area code: the card numbers that end with it.
        let local = resolver.completeNumbers(for: "555-0142")
        #expect(local.map(\.address.value) == ["+14155550142"])
        #expect(local.first?.contacts.map(\.id) == ["maya"])
        // Only cards count for that; a number in Messages alone ending the same way doesn't.
        #expect(resolver.completeNumbers(for: "012-3456").isEmpty)
        // Fewer than seven digits name nothing.
        #expect(resolver.completeNumbers(for: "50142").isEmpty)
    }
}

/// The people in a group choose its name, so a group name can find a conversation but never
/// outrank a contact, and groups filed under Unknown Senders or Junk are never found by name.
@Suite("Group names")
struct GroupNameTests {
    static let mom = Contact(id: "mom", givenName: "Ana", familyName: "Ortiz", nickname: "Mom", phones: [SampleContacts.phone("+1 415 555 0152")])

    static func group(_ id: Int64, _ name: String?, participants: [String] = ["+14155550171", "+14155550172"], filtered: Bool = false) -> Chat {
        Chat(
            id: id, guid: "iMessage;+;chat\(id)", kind: .group, service: .iMessage, displayName: name, identifier: "chat\(id)",
            participants: participants, isArchived: false, isFiltered: filtered, sendsReadReceipts: nil
        )
    }

    private func resolver(_ chats: [Chat], contacts: [Contact] = [SampleContacts.maya, SampleContacts.samLee], excluded: Set<Int64> = []) -> Resolver {
        Resolver(directory: Directory(contacts: contacts, region: "US"), chats: chats, handles: [], excludedChatIDs: excluded)
    }

    /// What `query` resolves to: one reference, or every candidate's when it is ambiguous.
    private func references(_ query: String, _ resolver: Resolver) throws -> [String] {
        do {
            switch try resolver.resolve(query) {
            case .person(let person): return [person.reference]
            case .chat(let chat): return [chat.reference]
            }
        } catch ResolveError.ambiguous(_, let candidates) {
            return candidates.map(\.reference)
        }
    }

    @Test func junkGroupsAreNeverFoundByName() throws {
        // Anyone can start a group with you and call it Mom.
        let junk = Self.group(1, "Mom", filtered: true)
        #expect(throws: ResolveError.self) { try resolver([junk]).resolve("Mom") }
        #expect(try references("Mom", resolver([junk], contacts: [Self.mom])) == ["contact:mom"])
        // Its reference still works, for reading it on purpose.
        #expect(try references("chat:1", resolver([junk])) == ["chat:1"])
    }

    @Test func aGroupNeverOutranksAContact() throws {
        // "Maya O" is only the start of Maya Ortiz's name, but a group's exact name.
        #expect(try references("Maya O", resolver([Self.group(2, "Maya O")])) == ["contact:maya", "chat:2"])
        #expect(try references("Maya Ortiz", resolver([Self.group(3, "maya ortiz")])) == ["contact:maya", "chat:3"])
        #expect(try references("Mom", resolver([Self.group(4, "Mom")], contacts: [Self.mom])) == ["contact:mom", "chat:4"])
    }

    @Test func aContactStillWinsOverAGroupThatOnlyMentionsTheName() throws {
        #expect(try references("Maya", resolver([Self.group(5, "Maya's birthday")])) == ["contact:maya"])
    }

    @Test func aGroupNameNoContactMatchesStillFindsTheGroup() throws {
        #expect(try references("climbing", resolver([Self.group(6, "Climbing crew"), Self.group(7, "Mom", filtered: true)])) == ["chat:6"])
    }

    @Test func groupCandidatesSayWhoIsInThem() throws {
        let group = Self.group(8, "Maya O", participants: ["+14155550142", "+14155550143", "+14155550171"])
        let candidate = resolver([group]).groupCandidate(group)
        #expect(candidate.reference == "chat:8")
        #expect(candidate.name == "Maya O")
        #expect(candidate.detail == "group with Maya Ortiz, Sam Lee, +1 (415) 555-0171 and you")
        #expect(candidate.addresses == ["+14155550142", "+14155550143", "+14155550171"])
        let big = Self.group(9, nil, participants: (0..<7).map { "+1415555018\($0)" })
        #expect(resolver([big]).groupCandidate(big).detail?.hasSuffix(", 3 others and you") == true)
    }

    @Test func groupsThatMessagesCouldShowUnderTheRecipientsTitle() throws {
        let titles = ["Maya Ortiz", "+14155550142", "+1 (415) 555-0142"]
        let chats = [
            Self.group(10, "Maya Ortiz"),
            Self.group(11, "MAYA  ORTIZ", filtered: true),
            Self.group(12, "+1 415-555-0142"),
            Self.group(13, nil, participants: ["+14155550142"]),
            Self.group(14, "Maya's birthday"),
            Self.group(15, nil, participants: ["+14155550142", "+14155550143"]),
            Self.group(16, "Maya Ortiz", participants: ["+14155550171"]),
        ]
        let found = resolver(chats, excluded: [16]).groups(titled: titles).map(\.id)
        // Excluded and filtered groups count: Messages can show any of them.
        #expect(found == [10, 11, 12, 13, 16])
    }
}
