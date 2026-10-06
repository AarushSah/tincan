import Testing

@testable import TincanKit

@Suite("Contact groups")
struct ContactGroupsTests {
    private func phone(_ value: String) -> Contact.Phone {
        Contact.Phone(label: "mobile", value: value, normalized: nil)
    }

    @Test func cardsSharingANumberFormOneGroupWithTheSharedNumber() throws {
        let directory = Directory(
            contacts: [
                Contact(id: "a", givenName: "Maya", familyName: "Chen", phones: [phone("+14155550142")]),
                Contact(id: "b", givenName: "Sam", familyName: "Chen", phones: [phone("(415) 555-0142"), phone("+14155550100")]),
                Contact(id: "c", givenName: "Ana", familyName: "Ruiz", phones: [phone("+14155550199")]),
            ], region: "US")
        let groups = directory.contactGroups()
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.kind == .sharedAddress)
        #expect(Set(group.contacts.map(\.id)) == ["a", "b"])
        #expect(group.sharedAddresses == ["+14155550142"])
        #expect(!group.namesMatch)
    }

    @Test func duplicateCardsWithTheSameNameAndNumberAreMarkedAsMatchingNames() throws {
        let directory = Directory(
            contacts: [
                Contact(id: "a", givenName: "Maya", familyName: "Chen", phones: [phone("+14155550142")]),
                Contact(
                    id: "b", givenName: "maya", familyName: "chen", phones: [phone("415-555-0142")],
                    emails: [Contact.Email(label: nil, value: "maya@example.com")]),
            ], region: "US")
        let group = try #require(directory.contactGroups().first)
        #expect(group.kind == .sharedAddress)
        #expect(group.namesMatch)
    }

    @Test func sameNameWithoutSharedAddressesIsReportedSeparately() throws {
        let directory = Directory(
            contacts: [
                Contact(id: "a", givenName: "Alex", familyName: "Kim", phones: [phone("+14155550101")]),
                Contact(id: "b", givenName: "Alex", familyName: "Kim", phones: [phone("+14155550102")]),
            ], region: "US")
        let group = try #require(directory.contactGroups().first)
        #expect(group.kind == .sameName)
        #expect(group.sharedAddresses.isEmpty)
        #expect(group.contacts.count == 2)
    }

    @Test func chainsOfSharedAddressesJoinIntoOneGroup() {
        let directory = Directory(
            contacts: [
                Contact(id: "a", givenName: "A", phones: [phone("+14155550101")]),
                Contact(id: "b", givenName: "B", phones: [phone("+14155550101"), phone("+14155550102")]),
                Contact(id: "c", givenName: "C", phones: [phone("+14155550102")]),
            ], region: "US")
        let groups = directory.contactGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.contacts.count == 3)
        #expect(groups.first?.sharedAddresses == ["+14155550101", "+14155550102"])
    }

    @Test func distinctPeopleProduceNoGroups() {
        let directory = Directory(
            contacts: [
                Contact(id: "a", givenName: "Maya", familyName: "Chen", phones: [phone("+14155550142")]),
                Contact(id: "b", givenName: "Sam", familyName: "Park", phones: [phone("+14155550143")]),
            ], region: "US")
        #expect(directory.contactGroups().isEmpty)
    }
}
