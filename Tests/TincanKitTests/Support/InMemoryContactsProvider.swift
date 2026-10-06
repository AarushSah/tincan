import Foundation

@testable import TincanKit

/// A `ContactsProvider` backed by an array, so tests never touch the real address book.
final class InMemoryContactsProvider: ContactsProvider {
    var authorization: ContactsAuthorization
    /// What `requestAccess()` grants when access has not been decided yet.
    var answerToRequest: ContactsAuthorization
    private(set) var contacts: [Contact]
    private let region: String?
    private var nextID = 1

    init(
        _ contacts: [Contact] = [], authorization: ContactsAuthorization = .authorized, answerToRequest: ContactsAuthorization = .authorized,
        region: String? = "US"
    ) {
        self.contacts = contacts
        self.authorization = authorization
        self.answerToRequest = answerToRequest
        self.region = region
    }

    func requestAccess() -> ContactsAuthorization {
        if authorization == .notDetermined { authorization = answerToRequest }
        return authorization
    }

    func fetchAll() throws -> [Contact] {
        try requireAccess()
        return contacts
    }

    func fetch(id: String) throws -> Contact? {
        try requireAccess()
        return contacts.first { $0.id == id }
    }

    func create(_ draft: ContactDraft) throws -> Contact {
        try requireAccess()
        defer { nextID += 1 }
        let contact = Contact(
            id: "in-memory-\(nextID)", givenName: draft.givenName, middleName: draft.middleName, familyName: draft.familyName,
            nickname: draft.nickname, organization: draft.organization, jobTitle: draft.jobTitle,
            isOrganization: draft.givenName.isEmpty && draft.familyName.isEmpty && !draft.organization.isEmpty,
            phones: draft.phones, emails: draft.emails, birthday: draft.birthday
        )
        contacts.append(contact)
        return contact
    }

    func update(id: String, edits: [ContactEdit]) throws -> Contact {
        try requireAccess()
        guard !edits.isEmpty else { throw ContactsError.nothingToChange }
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { throw ContactsError.notFound(id: id) }
        var contact = contacts[index]
        for edit in edits {
            switch edit {
            case .setGivenName(let value): contact.givenName = value
            case .setMiddleName(let value): contact.middleName = value
            case .setFamilyName(let value): contact.familyName = value
            case .setNickname(let value): contact.nickname = value
            case .setOrganization(let value): contact.organization = value
            case .setJobTitle(let value): contact.jobTitle = value
            case .setBirthday(let value):
                if let value, BirthdayText.components(value) == nil { throw ContactsError.invalidBirthday(value) }
                contact.birthday = value
            case .addPhone(let label, let value):
                let normalized = PhoneNumber.parse(value, region: region).flatMap { $0.isE164 ? $0.normalized : nil }
                contact.phones.append(Contact.Phone(label: label, value: value, normalized: normalized))
            case .removePhone(let value):
                let target = PhoneNumber.parse(value, region: region)
                contact.phones.removeAll { phone in
                    if let target, let stored = PhoneNumber.parse(phone.value, region: region) { return stored.isSameEntry(target) }
                    return phone.value == value
                }
            case .addEmail(let label, let value):
                contact.emails.append(Contact.Email(label: label, value: value))
            case .removeEmail(let value):
                contact.emails.removeAll { $0.value.caseInsensitiveCompare(value) == .orderedSame }
            }
        }
        contacts[index] = contact
        return contact
    }

    func vCard(id: String) throws -> Data {
        guard let contact = try fetch(id: id) else { throw ContactsError.notFound(id: id) }
        let lines =
            ["BEGIN:VCARD", "VERSION:3.0", "FN:\(contact.displayName)"]
            + contact.phones.map { "TEL:\($0.value)" }
            + contact.emails.map { "EMAIL:\($0.value)" }
            + ["END:VCARD"]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func requireAccess() throws {
        guard authorization == .authorized || authorization == .limited else { throw ContactsError.notAuthorized(authorization) }
    }
}
