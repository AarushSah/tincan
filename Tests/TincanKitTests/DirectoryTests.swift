import Foundation
import Testing

@testable import TincanKit

@Suite("Addresses")
struct AddressTests {
    @Test func addressesAreClassifiedAndCanonicalized() {
        let phone = Address(" (415) 555-0142 ", region: "US")
        #expect(phone.kind == .phone)
        #expect(phone.value == "+14155550142")
        let email = Address("Maya.Ortiz@Example.com", region: "US")
        #expect(email.kind == .email)
        #expect(email.value == "maya.ortiz@example.com")
        #expect(Address("262966", region: "US").kind == .shortCode)
        #expect(Address("urn:biz:0123abcd", region: "US").kind == .other)
    }

    @Test(
        "Phone numbers are formatted for people",
        arguments: [
            ("+14155550142", "+1 (415) 555-0142"),
            ("+442079460000", "+44 20 7946 0000"),
            ("+819012345678", "+81 90 1234 5678"),
            ("+61412345678", "+61 4 1234 5678"),
        ])
    func formatting(raw: String, formatted: String) {
        #expect(Address(raw, region: "US").formatted == formatted)
    }

    @Test func otherAddressesAreShownAsStored() {
        #expect(Address("maya.ortiz@example.com", region: "US").formatted == "maya.ortiz@example.com")
        #expect(Address("262966", region: "US").formatted == "262966")
    }
}

@Suite("Directory")
struct DirectoryTests {
    typealias People = SampleContacts

    @Test func anE164AddressMatchesANumberSavedInLocalFormat() throws {
        let directory = Directory(contacts: [People.maya, People.samLee], region: "US")
        let matches = directory.matches(for: "+14155550142")
        #expect(matches.map(\.contact.id) == ["maya"])
        #expect(matches.first?.quality == .exact)
        #expect(directory.uniqueContact(for: "+14155550142")?.id == "maya")
        #expect(directory.displayName(for: "+14155550142") == "Maya Ortiz")
        #expect(directory.shortName(for: "+14155550142") == "Maya")
    }

    @Test func aNumberSavedWithoutItsCountryCodeMatchesNationally() throws {
        // Kenji's card says 090-1234-5678, saved on a Mac set to the US.
        let directory = Directory(contacts: [People.kenji], region: "US")
        let matches = directory.matches(for: "+819012345678")
        #expect(matches.map(\.contact.id) == ["kenji"])
        #expect(matches.first?.quality == .national)
        #expect(directory.displayName(for: "+819012345678") == "Kenji Sato")
    }

    @Test func aNationalMatchNeedsTheSameNationalNumber() {
        let directory = Directory(contacts: [People.kenji], region: "US")
        #expect(directory.matches(for: "+819012345679").isEmpty)
        #expect(directory.matches(for: "+14155550142").isEmpty)
    }

    @Test func numbersInDifferentCountriesNeverMatch() {
        // Same ten digits: a London number and a number in Maine.
        let london = Contact(id: "london", givenName: "Olivia", phones: [SampleContacts.phone("+44 20 7946 0000")])
        let maine = Contact(id: "maine", givenName: "Mason", phones: [SampleContacts.phone("(207) 946-0000")])
        #expect(Directory(contacts: [london], region: "US").matches(for: "+12079460000").isEmpty)
        #expect(Directory(contacts: [maine], region: "US").matches(for: "+442079460000").isEmpty)
        let both = Directory(contacts: [london, maine], region: "US")
        #expect(both.matches(for: "+12079460000").map(\.contact.id) == ["maine"])
        #expect(both.matches(for: "+442079460000").map(\.contact.id) == ["london"])
    }

    @Test func aForeignNumberSavedInItsNationalFormatMatchesOnlyItsCountry() {
        // Olivia's London number, saved the British way on a Mac set to the US.
        let london = Contact(id: "london", givenName: "Olivia", phones: [SampleContacts.phone("020 7946 0000")])
        let directory = Directory(contacts: [london], region: "US")
        #expect(directory.matches(for: "+442079460000").map(\.quality) == [.national])
        #expect(directory.matches(for: "+12079460000").isEmpty)
    }

    @Test(
        "Numbers saved with another country's trunk prefix match nationally",
        arguments: [
            ("0412 345 678", "+61412345678"), // Australia
            ("8 912 345-67-89", "+79123456789"), // Russia
        ])
    func foreignTrunkPrefixes(saved: String, address: String) {
        let contact = Contact(id: "abroad", givenName: "Ada", phones: [SampleContacts.phone(saved)])
        let matches = Directory(contacts: [contact], region: "US").matches(for: address)
        #expect(matches.map(\.contact.id) == ["abroad"])
        #expect(matches.map(\.quality) == [.national])
    }

    @Test func emailsMatchIgnoringCase() throws {
        let directory = Directory(contacts: [People.maya], region: "US")
        #expect(directory.uniqueContact(for: "maya.ortiz@example.com")?.id == "maya")
        #expect(directory.uniqueContact(for: "MAYA.ORTIZ@EXAMPLE.COM")?.id == "maya")
        #expect(directory.matches(for: "maya.ortiz@example.com").first?.quality == .exact)
    }

    @Test func aNumberWithAnExtensionDoesNotClaimTheMainLine() {
        // Calls and texts from a clinic's main number come from the clinic, not Dr. Ortiz.
        let doctor = Contact(id: "doctor", givenName: "Ana", familyName: "Ortiz", phones: [SampleContacts.phone("+1 415 555 0100 ext. 23", label: "work")])
        let directory = Directory(contacts: [doctor], region: "US")
        #expect(directory.matches(for: "+14155550100").isEmpty)
        #expect(directory.addresses(of: doctor).isEmpty)
    }

    @Test func blankEmailsOnACardMatchNothing() {
        // A synced card with an empty email must not claim senders Messages did not record.
        let synced = Contact(id: "synced", givenName: "Robin", emails: [SampleContacts.email(""), SampleContacts.email("  ")])
        let directory = Directory(contacts: [synced], region: "US")
        #expect(directory.matches(for: "").isEmpty)
        #expect(directory.matches(for: " ").isEmpty)
        #expect(directory.shortName(for: "") == "")
    }

    @Test func emailsSavedWithSurroundingWhitespaceMatch() {
        let pasted = Contact(id: "pasted", givenName: "Maya", emails: [SampleContacts.email(" Maya@Example.com\n")])
        #expect(Directory(contacts: [pasted], region: "US").uniqueContact(for: "maya@example.com")?.id == "pasted")
    }

    @Test func aNumberOnTwoCardsIsNeverAttributedToEither() throws {
        let parent = Contact(id: "parent", givenName: "Robin", familyName: "Ortiz", phones: [SampleContacts.phone("+1 415-555-0150", label: "home")])
        let child = Contact(id: "child", givenName: "Ari", familyName: "Ortiz", phones: [SampleContacts.phone("(415) 555-0150", label: "home")])
        let directory = Directory(contacts: [parent, child], region: "US")
        let matches = directory.matches(for: "+14155550150")
        #expect(matches.count == 2)
        #expect(matches.map(\.contact.id) == ["child", "parent"]) // sorted by name: Ari, Robin
        #expect(directory.uniqueContact(for: "+14155550150") == nil)
        #expect(directory.displayName(for: "+14155550150") == "+1 (415) 555-0150")
    }

    @Test func unknownAddressesShowAsFormattedNumbers() {
        let directory = Directory(contacts: [People.maya], region: "US")
        #expect(directory.uniqueContact(for: "+14155550199") == nil)
        #expect(directory.displayName(for: "+14155550199") == "+1 (415) 555-0199")
        #expect(directory.displayName(for: "someone@example.com") == "someone@example.com")
    }

    @Test func contactsAreFoundByID() {
        let directory = Directory(contacts: [People.maya], region: "US")
        #expect(directory.contact(id: "maya")?.displayName == "Maya Ortiz")
        #expect(directory.contact(id: "nobody") == nil)
    }

    @Test func aCardsAddressesAreCanonicalAndUnique() {
        let doubled = Contact(
            id: "maya", givenName: "Maya",
            phones: [SampleContacts.phone("(415) 555-0142"), SampleContacts.phone("+1 415 555 0142", label: "iPhone")],
            emails: [SampleContacts.email("Maya@Example.com")]
        )
        let directory = Directory(contacts: [doubled], region: "US")
        #expect(directory.addresses(of: doubled).map(\.value) == ["+14155550142", "maya@example.com"])
    }

    // MARK: Name search

    @Test func nameSearchRanksExactNameThenNicknameThenFirstOrLastThenPrefixThenSubstring() {
        let contacts = [
            Contact(id: "substring", givenName: "Samaya", familyName: "Lee"),
            Contact(id: "prefix", givenName: "Mayanka", familyName: "Rao"),
            Contact(id: "given", givenName: "Maya", familyName: "Ortiz"),
            Contact(id: "nickname", givenName: "Margaret", familyName: "Young", nickname: "Maya"),
            Contact(id: "exact", givenName: "Maya"),
            Contact(id: "unrelated", givenName: "Sam", familyName: "Patel"),
        ]
        let results = Directory(contacts: contacts, region: "US").search(name: "maya")
        #expect(results.map(\.contact.id) == ["exact", "nickname", "given", "prefix", "substring"])
        #expect(results.map(\.rank) == [0, 1, 2, 3, 4])
    }

    @Test func aFullNameMatchesExactly() {
        let directory = Directory(contacts: [People.maya, People.samLee, People.samPatel], region: "US")
        let results = directory.search(name: "  Sam   LEE ")
        #expect(results.first?.contact.id == "sam-lee")
        #expect(results.first?.rank == 0)
    }

    @Test func nameSearchIgnoresDiacritics() {
        let directory = Directory(contacts: [People.jose], region: "US")
        #expect(directory.search(name: "jose alvarez").map(\.rank) == [0])
        #expect(directory.search(name: "ÁLVAREZ").map(\.rank) == [2])
    }

    @Test func organizationsAreSearchable() {
        let company = Contact(id: "bakery", organization: "Sunrise Bakery", isOrganization: true)
        let directory = Directory(contacts: [company, People.samPatel], region: "US")
        #expect(directory.search(name: "sunrise bakery").map(\.contact.id) == ["bakery"])
        #expect(directory.search(name: "sunrise bakery").first?.rank == 0)
        // Sam's employer is found too, but only as a name part.
        #expect(directory.search(name: "northwind").map(\.rank) == [2])
    }

    @Test func tiesAreOrderedByName() {
        let directory = Directory(contacts: [People.samPatel, People.samLee], region: "US")
        #expect(directory.search(name: "sam").map(\.contact.id) == ["sam-lee", "sam-patel"])
    }

    @Test("Names written family name first, with or without a space, match exactly", arguments: ["佐藤 健二", "佐藤健二", "健二 佐藤"])
    func familyNameFirst(query: String) {
        let kenji = Contact(id: "kenji", givenName: "健二", familyName: "佐藤")
        let results = Directory(contacts: [kenji], region: "JP").search(name: query)
        #expect(results.map(\.contact.id) == ["kenji"])
        #expect(results.map(\.rank) == [0])
    }

    @Test func namesWithCombiningMarksMatchTheirPrecomposedForm() {
        let decomposed = Contact(id: "jose", givenName: "Jose\u{301}", familyName: "A\u{301}lvarez")
        #expect(Directory(contacts: [decomposed], region: "US").search(name: "José Álvarez").map(\.rank) == [0])
    }

    @Test func blankQueriesMatchNobody() {
        #expect(Directory(contacts: [People.maya], region: "US").search(name: "   ").isEmpty)
    }
}
