@testable import TincanKit

/// Invented address book entries shared by the identity tests. Numbers use the 555-01xx
/// range reserved for fiction; emails use example.com.
enum SampleContacts {
    static func phone(_ value: String, label: String? = "mobile") -> Contact.Phone {
        Contact.Phone(label: label, value: value, normalized: nil)
    }

    static func email(_ value: String, label: String? = "home") -> Contact.Email {
        Contact.Email(label: label, value: value)
    }

    static let maya = Contact(
        id: "maya", givenName: "Maya", familyName: "Ortiz",
        phones: [phone("(415) 555-0142")], emails: [email("Maya.Ortiz@Example.com")]
    )
    static let samLee = Contact(id: "sam-lee", givenName: "Sam", familyName: "Lee", phones: [phone("415-555-0143")])
    static let samPatel = Contact(
        id: "sam-patel", givenName: "Sam", familyName: "Patel", organization: "Northwind",
        phones: [phone("+1 415 555 0144")]
    )
    static let jose = Contact(id: "jose", givenName: "José", familyName: "Álvarez", phones: [phone("+34 612 345 678")])
    static let kenji = Contact(id: "kenji", givenName: "Kenji", familyName: "Sato", phones: [phone("090-1234-5678")])
}
