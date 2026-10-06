import Foundation
import Testing

@testable import TincanKit

/// What `contacts add` and `contacts edit` would change, and which card a reference names,
/// decided from an address book in memory and a fixture chat.db. Nothing is saved.
@Suite("Contact planning")
struct ContactEditPlannerTests {
    let resolver: Resolver
    let mayaText: Int64
    let mayaMail: Int64
    let crew: Int64

    static let jordan = Contact(id: "jordan-lee", givenName: "Jordan", familyName: "Lee", phones: [SampleContacts.phone("+14155550177", label: "home")])
    static let riley = Contact(id: "riley-lee", givenName: "Riley", familyName: "Lee", phones: [SampleContacts.phone("+14155550177", label: "home")])
    static let maya = SampleContacts.maya

    init() throws {
        let fixture = try MessagesFixture()
        let mayaPhone = try fixture.addHandle("+14155550142")
        let mayaEmail = try fixture.addHandle("maya.ortiz@example.com")
        let samLee = try fixture.addHandle("+14155550143")
        mayaText = try fixture.addChat("SMS;-;+14155550142", service: "SMS", participants: [mayaPhone])
        mayaMail = try fixture.addChat("iMessage;-;maya.ortiz@example.com", participants: [mayaEmail])
        crew = try fixture.addChat("iMessage;+;chat100200300", displayName: "Climbing crew", participants: [mayaPhone, samLee])
        let messages = try fixture.open()
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        resolver = Resolver(
            directory: Directory(contacts: [Self.maya, SampleContacts.samLee, SampleContacts.samPatel, Self.jordan, Self.riley], region: "US"),
            chats: try messages.allChats(),
            handles: Array(try messages.handles().values),
            excludedChatIDs: messages.excludedChatIDs,
            activity: [crew: day.addingTimeInterval(200), mayaText: day.addingTimeInterval(100), mayaMail: day]
        )
    }

    var planner: ContactEditPlanner {
        let resolver = resolver
        return ContactEditPlanner(directory: resolver.directory, region: "US", resolver: { resolver })
    }

    func cards(own: [String] = ["+14155550142"], messages: Bool = true) -> ContactCards {
        let resolver = messages ? resolver : nil
        return ContactCards(directory: self.resolver.directory, region: "US", resolver: { resolver }, ownAddresses: { own })
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

    func add(_ card: ContactEditPlanner.NewCard, allowDuplicate: Bool = false) throws -> (plan: ContactEditPlanner.AddPlan, warnings: [PlanWarning]) {
        var warnings: [PlanWarning] = []
        let plan = try planner.add(try ContactEditPlanner.draft(card, region: "US"), allowDuplicate: allowDuplicate, warnings: &warnings)
        return (plan, warnings)
    }

    func edit(
        _ changes: ContactEditPlanner.Changes, of contact: Contact = ContactEditPlannerTests.maya
    ) throws -> (plan: ContactEditPlanner.EditPlan, warnings: [PlanWarning]) {
        var warnings: [PlanWarning] = []
        let plan = try planner.edit(contact, changes, warnings: &warnings)
        return (plan, warnings)
    }

    // MARK: Adding

    @Test func aNewCardsFieldsAreChecked() throws {
        let card = ContactEditPlanner.NewCard(name: "Riya Q Shah", phones: ["work:+14155550133"], emails: ["riya@example.com"], birthday: "03-04")
        let draft = try ContactEditPlanner.draft(card, region: "US")
        #expect(draft.givenName == "Riya Q")
        #expect(draft.familyName == "Shah")
        #expect(draft.phones == [Contact.Phone(label: "work", value: "+14155550133", normalized: nil)])
        #expect(draft.emails == [Contact.Email(label: nil, value: "riya@example.com")])
        #expect(draft.birthday == "03-04")
        // --first and --last win over --name; a URL scheme is no label.
        let named = try ContactEditPlanner.draft(.init(name: "Riya Shah", first: "Ria", phones: ["tel:+14155550133"]), region: "US")
        #expect(named.givenName == "Ria")
        #expect(named.familyName == "Shah")
        #expect(named.phones.first?.label == nil)

        for (card, message) in [
            (ContactEditPlanner.NewCard(name: "Riya", phones: ["mobile:not a number"]), "\"not a number\" is not a phone number."),
            (ContactEditPlanner.NewCard(name: "Riya", emails: ["maya@"]), "\"maya@\" is not an email address."),
            (ContactEditPlanner.NewCard(name: "Riya", birthday: "02-30"), "--birthday \"02-30\" is not a date."),
            (ContactEditPlanner.NewCard(jobTitle: "Chef"), "A contact needs a name, company, phone number or email."),
        ] {
            let issue = try #require(refused { try ContactEditPlanner.draft(card, region: "US") })
            #expect(issue.code == "invalid_input")
            #expect(issue.kind == .usage)
            #expect(issue.message == message)
        }
    }

    @Test func aSecondCardForANumberNeedsThePersonsConfirmation() throws {
        let duplicate = try #require(refused { try add(.init(name: "Maya O", phones: ["+1 415 555 0142"])) })
        #expect(duplicate.code == "duplicate_contact")
        #expect(duplicate.kind == .needsInput)
        #expect(duplicate.message == "A card already has this number:")
        #expect(duplicate.candidates.map(\.reference) == ["contact:maya"])
        #expect(duplicate.candidates.first?.addresses == ["+14155550142", "maya.ortiz@example.com"])
        #expect(duplicate.candidates.first?.conversations == nil)
        #expect(!duplicate.hint.contains("contact:maya"))

        let (allowed, warnings) = try add(.init(name: "Maya O", phones: ["+1 415 555 0142"]), allowDuplicate: true)
        #expect(allowed.preview.id == "new")
        guard case .notice(let code, let message)? = warnings.first else {
            Issue.record("The card that has the number is still named")
            return
        }
        #expect(code == "duplicate_contact")
        #expect(message == "A card already has this number: Maya Ortiz (contact:maya). With --allow-duplicate, tincan adds another card anyway.")

        #expect(ContactEditPlanner.alreadyTaken(cards: 2, phones: 1, emails: 0) == "2 cards already have this number")
        #expect(ContactEditPlanner.alreadyTaken(cards: 1, phones: 0, emails: 2) == "A card already has these emails")
        #expect(ContactEditPlanner.alreadyTaken(cards: 3, phones: 1, emails: 1) == "3 cards already have these numbers and emails")
        let shared = try #require(refused { try add(.init(name: "Robin Vale", phones: ["+14155550177"])) })
        #expect(shared.message == "2 cards already have this number:")
    }

    @Test func aSameNamedCardOnlyWarns() throws {
        let (plan, warnings) = try add(.init(name: "Sam Lee", phones: ["+14155550133"], emails: ["sam@example.com"]))
        #expect(warnings.map(\.code) == ["same_name_exists"])
        // The preview shows the labels Contacts would give.
        #expect(plan.preview.phones.map(\.label) == ["mobile"])
        #expect(plan.preview.emails.map(\.label) == ["home"])
        #expect(!plan.preview.isOrganization)
        let company = try add(.init(organization: "Northwind Traders", phones: ["+14155550198"])).plan.preview
        #expect(company.isOrganization)
        #expect(company.displayName == "Northwind Traders")
    }

    @Test func aNumberOrEmailGivenTwiceIsRefused() throws {
        let phones = try #require(refused { try add(.init(name: "Robin Vale", phones: ["+14155550133", "415-555-0133"])) })
        #expect(phones.message == "415-555-0133 is given twice.")
        let emails = try #require(refused { try edit(.init(addEmails: ["robin@example.com", "work:Robin@Example.com"])) })
        #expect(emails.message == "Robin@Example.com is given twice.")
    }

    @Test func aNumberThatNamesNoLineIsRefused() throws {
        for (resolver, options) in [(Optional(resolver), 1), (nil, 0)] {
            let planner = ContactEditPlanner(directory: self.resolver.directory, region: "US", resolver: { resolver })
            var warnings: [PlanWarning] = []
            let draft = try ContactEditPlanner.draft(.init(name: "Robin Vale", phones: ["555-0142"]), region: "US")
            let refused = refusal { try planner.add(draft, allowDuplicate: false, warnings: &warnings) }
            guard case .unresolved(.incompleteNumber(let query, _, let found), let command)? = refused else {
                Issue.record("555-0142 names no line")
                continue
            }
            #expect(query == "555-0142")
            #expect(command == "contacts add --phone")
            // With Messages, the full numbers it could be; without, only the digits decide.
            #expect(found.count == options)
        }
    }

    // MARK: Editing

    @Test func fieldsAreSetOrCleared() throws {
        let plan = try edit(.init(nickname: "Mayo", organization: "", birthday: "")).plan
        #expect(plan.edits == [.setNickname("Mayo"), .setOrganization(""), .setBirthday(nil)])
        #expect(plan.changes == ["nickname → Mayo", "clear company", "clear birthday"])
        #expect(plan.removed.isEmpty)
        let nothing = try #require(refused { try edit(.init()) })
        #expect(nothing.message == "Nothing to change.")
    }

    @Test func removingAndAddingANumberBackRelabelsIt() throws {
        let plan = try edit(.init(addPhones: ["work:+14155550142"], removePhones: ["+14155550142"])).plan
        // The card's own way of writing the number is kept.
        #expect(plan.edits == [.removePhone("+14155550142"), .addPhone(label: "work", value: "(415) 555-0142")])
        #expect(plan.changes == ["remove phone +14155550142", "add phone +14155550142 (work)"])
        // Not leaving the card, so no conversation changes who it is from.
        #expect(plan.removed.isEmpty)
        let email = try edit(.init(addEmails: ["work:maya.ortiz@example.com"], removeEmails: ["MAYA.ORTIZ@example.com"])).plan
        #expect(email.edits.last == .addEmail(label: "work", value: "Maya.Ortiz@Example.com"))
        #expect(email.removed.isEmpty)
        let removed = try edit(.init(removePhones: ["(415) 555-0142"], removeEmails: ["maya.ortiz@example.com"])).plan
        #expect(removed.removed == ["+14155550142", "maya.ortiz@example.com"])
    }

    /// A number with an extension is its own entry: removing one leaves the other.
    @Test func extensionsAreSeparateEntries() throws {
        let office = Contact(
            id: "northwind", organization: "Northwind Dental",
            phones: [SampleContacts.phone("+1 415 555 0100", label: "main"), SampleContacts.phone("+1 415 555 0100 x23", label: "billing")])
        let plan = try edit(.init(removePhones: ["+1 415 555 0100 x23"]), of: office).plan
        #expect(plan.changes == ["remove phone +1 415 555 0100 x23"])
        let provider = InMemoryContactsProvider([office])
        let saved = try provider.update(id: office.id, edits: plan.edits)
        #expect(saved.phones.map(\.value) == ["+1 415 555 0100"])
        // Adding the extension beside the plain number isn't a duplicate.
        let added = try edit(.init(addPhones: ["other:+1 415 555 0100 x24"]), of: office).plan
        #expect(added.changes == ["add phone +1 415 555 0100 x24 (other)"])
        // The same number twice on a card goes as two entries, and the preview says so.
        let twice = Contact(id: "twice", givenName: "Ava", phones: [SampleContacts.phone("+14155550123"), SampleContacts.phone("(415) 555-0123")])
        #expect(try edit(.init(removePhones: ["+14155550123"]), of: twice).plan.changes == ["remove phone +14155550123 (2 entries)"])
    }

    @Test func addingWhatTheCardHasOrRemovingWhatItLacksIsRefused() throws {
        let phone = try #require(refused { try edit(.init(addPhones: ["+14155550142"])) })
        #expect(phone.message == "Maya Ortiz already has (415) 555-0142 (mobile).")
        #expect(phone.hint.contains("contact:maya --remove-phone <number> --add-phone <label>:<number>"))
        let email = try #require(refused { try edit(.init(addEmails: ["MAYA.ORTIZ@example.com"])) })
        #expect(email.hint.contains("contact:maya --remove-email <email> --add-email <label>:<email>"))
        let missing = try #require(refused { try edit(.init(removeEmails: ["nobody@example.com"])) })
        #expect(missing.message == "Maya Ortiz has no email nobody@example.com.")
        let number = try #require(refused { try edit(.init(removePhones: ["+14155550199"])) })
        #expect(number.message == "Maya Ortiz has no phone number +14155550199.")
    }

    @Test func anAddressOtherCardsHaveWarnsEvenWhenTheEditStops() throws {
        let (plan, warnings) = try edit(.init(addPhones: ["+14155550177"]))
        #expect(plan.changes == ["add phone +14155550177"])
        guard case .notice(let code, let message)? = warnings.first else {
            Issue.record("The shared line is named")
            return
        }
        #expect(code == "shared_address")
        #expect(
            message
                == "+1 (415) 555-0177 is also on Jordan Lee (contact:jordan-lee) and Riley Lee (contact:riley-lee). tincan can't tell which of them a message or call on it is from."
        )
        // Found before a later value stopped the edit, the warning still reaches the person.
        var partial: [PlanWarning] = []
        #expect(refused { try planner.edit(Self.maya, .init(addPhones: ["+14155550177", "junk"]), warnings: &partial) }?.code == "invalid_input")
        #expect(partial.map(\.code) == ["shared_address"])
    }

    @Test func removedAddressesNameTheConversationsThatUseThem() throws {
        var warnings: [PlanWarning] = []
        let removed = ["+14155550142", "+14155550142", "+14155550199"]
        let inUse = try #require(planner.addressesInUse(removed, of: Self.maya, resolver: resolver, warnings: &warnings))
        #expect(inUse.map(\.address) == ["+14155550142"])
        // Most recent first.
        #expect(inUse.first?.conversations.map(\.ref) == ["chat:\(crew)", "chat:\(mayaText)"])
        #expect(inUse.first?.conversations.map(\.name) == ["Climbing crew", "Maya Ortiz"])
        guard case .notice(let code, let message)? = warnings.first else {
            Issue.record("The conversations are named")
            return
        }
        #expect(code == "address_in_use")
        #expect(
            message
                == "+1 (415) 555-0142 is used in 2 conversations: Climbing crew (chat:\(crew)) and Maya Ortiz (chat:\(mayaText)). Removing it from Maya Ortiz's card changes who tincan and Messages say those messages are from."
        )
        var none: [PlanWarning] = []
        #expect(planner.addressesInUse(["+14155550199"], of: Self.maya, resolver: resolver, warnings: &none) == nil)
        #expect(none.isEmpty)
    }

    // MARK: Cards

    @Test func aReferenceNamesOneCard() throws {
        let cards = cards()
        #expect(try cards.card(for: "contact:maya", command: "contacts show").id == "maya")
        #expect(try cards.card(for: "Address: maya.ortiz@example.com", command: "contacts show").id == "maya")
        #expect(try cards.card(for: "(415) 555-0142", command: "contacts show").id == "maya")
        #expect(try cards.card(for: "Patel", command: "contacts show").id == "sam-patel")
        #expect(refused { try cards.card(for: "contact:nobody", command: "contacts show") }?.code == "contact_not_found")
        let notAnAddress = try #require(refused { try cards.card(for: "address:Maya", command: "contacts show") })
        #expect(notAnAddress.code == "not_found")
        #expect(notAnAddress.hint.contains("address:<+number>"))
        let unknown = try #require(refused { try cards.card(for: "nobody@example.com", command: "contacts show") })
        #expect(unknown.hint.contains("--email nobody@example.com"))
    }

    /// A one-word name is as ambiguous here as when sending: a card named just Sam doesn't
    /// beat Sam Park, and a nickname doesn't beat a first name.
    @Test func aOneWordNameIsAsAmbiguousAsEverywhereElse() throws {
        let sam = Contact(id: "sam", givenName: "Sam", phones: [SampleContacts.phone("+14155550161")])
        let samPark = Contact(id: "sam-park", givenName: "Sam", familyName: "Park", phones: [SampleContacts.phone("+14155550162")])
        let alexander = Contact(id: "alexander", givenName: "Alexander", nickname: "Alex", phones: [SampleContacts.phone("+14155550163")])
        let alex = Contact(id: "alex-kim", givenName: "Alex", familyName: "Kim", phones: [SampleContacts.phone("+14155550164")])
        let directory = Directory(contacts: [sam, samPark, alexander, alex], region: "US")
        let cards = ContactCards(directory: directory, region: "US", resolver: { nil }, ownAddresses: { [] })
        for (name, expected) in [("Sam", ["contact:sam", "contact:sam-park"]), ("alex", ["contact:alex-kim", "contact:alexander"])] {
            let refusal = try #require(refused { try cards.card(for: name, command: "contacts edit") }, "\(name)")
            #expect(refusal.code == "ambiguous")
            #expect(Set(refusal.candidates.map(\.reference)) == Set(expected))
        }
        // A full name, or a word that only one card has, still names one card.
        #expect(try cards.card(for: "Sam Park", command: "contacts edit").id == "sam-park")
        #expect(try cards.card(for: "Kim", command: "contacts edit").id == "alex-kim")
    }

    @Test func severalCardsAreEveryCandidateAndNeverAChoice() throws {
        let cards = cards()
        let line = try #require(refused { try cards.card(for: "address:+14155550177", command: "contacts edit") })
        #expect(line.code == "ambiguous")
        #expect(line.message == "+14155550177 is on 2 contact cards. Say which one:")
        #expect(line.candidates.map(\.reference) == ["contact:jordan-lee", "contact:riley-lee"])
        #expect(line.hint.contains("`tincan contacts edit <reference>`"))
        let sam = try #require(refused { try cards.card(for: "Sam", command: "contacts show") })
        #expect(sam.message == "\"Sam\" could mean 2 contacts. Say which one:")
        #expect(sam.candidates.map(\.detail) == ["+1 (415) 555-0143", "+1 (415) 555-0144"])
        #expect(sam.candidates.last?.organization == "Northwind")
    }

    @Test func meIsTheCardWithYourOwnAddresses() throws {
        #expect(try cards().card(for: " me ", command: "contacts show").id == "maya")
        let none = try #require(refused { try cards(own: ["+14155550101"]).card(for: "me", command: "contacts show") })
        #expect(none.message == "No contact card has your Messages addresses (+1 (415) 555-0101).")
        let two = try #require(refused { try cards(own: ["+14155550177"]).card(for: "me", command: "contacts show") })
        #expect(two.code == "ambiguous")
        #expect(two.candidates.count == 2)
    }

    @Test func anIncompleteNumberNamesNoCard() throws {
        for messages in [true, false] {
            let refused = refusal { try cards(messages: messages).card(for: "555-0142", command: "contacts show") }
            guard case .unresolved(.incompleteNumber(let query, _, _), let command)? = refused else {
                Issue.record("555-0142 names no line")
                continue
            }
            #expect(query == "555-0142")
            #expect(command == "contacts show")
        }
    }

    @Test func aSharedNumberIsNamedOnTheCard() throws {
        let cards = cards()
        let warning = try #require(cards.sharedAddressWarning(for: Self.jordan))
        #expect(warning.code == "shared_address")
        guard case .notice(_, let message) = warning else {
            Issue.record("The card's shared number is named")
            return
        }
        #expect(
            message
                == "Jordan Lee shares +1 (415) 555-0177 with Riley Lee (contact:riley-lee). tincan can't tell which of them a message or call on it is from.")
        #expect(cards.sharedAddressWarning(for: Self.maya) == nil)
    }

    @Test func hintsUseAPlaceholderForTheReference() {
        #expect(PlanIssue.example("send") == "tincan send <reference> …")
        #expect(PlanIssue.example("contacts edit --add-phone") == "tincan contacts edit --add-phone <reference> …")
        #expect(PlanIssue.example("contacts show") == "tincan contacts show <reference>")
    }
}
