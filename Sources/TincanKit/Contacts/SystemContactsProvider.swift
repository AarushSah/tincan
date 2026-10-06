@preconcurrency import Contacts
import Foundation

/// Apple Contacts through Contacts.framework. Reads unified contacts, the same merged view
/// the Contacts app shows. tincan never reads the AddressBook database files directly.
public final class SystemContactsProvider: ContactsProvider {
    private let store = CNContactStore()
    private let region: String?

    public init(region: String? = PhoneRegions.systemRegion) {
        self.region = region
    }

    public var authorization: ContactsAuthorization {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    public func requestAccess() -> ContactsAuthorization {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return authorization }
        let semaphore = DispatchSemaphore(value: 0)
        store.requestAccess(for: .contacts) { _, _ in semaphore.signal() }
        semaphore.wait()
        return authorization
    }

    public func fetchAll() throws -> [Contact] {
        try requireAccess()
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        request.unifyResults = true
        request.sortOrder = .userDefault
        var contacts: [Contact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(self.convert(contact))
        }
        return contacts
    }

    public func fetch(id: String) throws -> Contact? {
        try requireAccess()
        do {
            return convert(try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys))
        } catch let error as CNError where error.code == .recordDoesNotExist {
            return nil
        }
    }

    public func create(_ draft: ContactDraft) throws -> Contact {
        try requireAccess()
        let contact = CNMutableContact()
        contact.givenName = draft.givenName
        contact.middleName = draft.middleName
        contact.familyName = draft.familyName
        contact.nickname = draft.nickname
        contact.organizationName = draft.organization
        contact.jobTitle = draft.jobTitle
        if draft.givenName.isEmpty, draft.familyName.isEmpty, !draft.organization.isEmpty {
            contact.contactType = .organization
        }
        contact.phoneNumbers = draft.phones.map {
            CNLabeledValue(label: Self.phoneLabel($0.label), value: CNPhoneNumber(stringValue: $0.value))
        }
        contact.emailAddresses = draft.emails.map {
            CNLabeledValue(label: Self.emailLabel($0.label), value: $0.value as NSString)
        }
        if let birthday = draft.birthday {
            guard let components = BirthdayText.components(birthday) else { throw ContactsError.invalidBirthday(birthday) }
            contact.birthday = components
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try execute(request)
        guard let saved = try fetch(id: contact.identifier) else { throw ContactsError.saveFailed("the new contact could not be read back") }
        return saved
    }

    public func update(id: String, edits: [ContactEdit]) throws -> Contact {
        try requireAccess()
        guard !edits.isEmpty else { throw ContactsError.nothingToChange }
        let existing: CNContact
        do {
            existing = try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ContactsError.notFound(id: id)
        }
        guard let contact = existing.mutableCopy() as? CNMutableContact else { throw ContactsError.saveFailed("the contact is read-only") }
        for edit in edits {
            switch edit {
            case .setGivenName(let value): contact.givenName = value
            case .setMiddleName(let value): contact.middleName = value
            case .setFamilyName(let value): contact.familyName = value
            case .setNickname(let value): contact.nickname = value
            case .setOrganization(let value): contact.organizationName = value
            case .setJobTitle(let value): contact.jobTitle = value
            case .setBirthday(let value):
                if let value {
                    guard let components = BirthdayText.components(value) else { throw ContactsError.invalidBirthday(value) }
                    contact.birthday = components
                } else {
                    contact.birthday = nil
                }
            case .addPhone(let label, let value):
                contact.phoneNumbers.append(CNLabeledValue(label: Self.phoneLabel(label), value: CNPhoneNumber(stringValue: value)))
            case .removePhone(let value):
                let target = PhoneNumber.parse(value, region: region)
                contact.phoneNumbers.removeAll { entry in
                    let stored = entry.value.stringValue
                    if let target, let parsed = PhoneNumber.parse(stored, region: region) { return parsed.isSameEntry(target) }
                    return stored == value
                }
            case .addEmail(let label, let value):
                contact.emailAddresses.append(CNLabeledValue(label: Self.emailLabel(label), value: value as NSString))
            case .removeEmail(let value):
                contact.emailAddresses.removeAll { ($0.value as String).caseInsensitiveCompare(value) == .orderedSame }
            }
        }
        let request = CNSaveRequest()
        request.update(contact)
        try execute(request)
        guard let saved = try fetch(id: id) else { throw ContactsError.saveFailed("the contact could not be read back") }
        return saved
    }

    public func vCard(id: String) throws -> Data {
        try requireAccess()
        let contact: CNContact
        do {
            contact = try store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()])
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ContactsError.notFound(id: id)
        }
        return try CNContactVCardSerialization.data(with: [contact])
    }

    // MARK: Conversion

    static let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactTypeKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
    ]

    private func convert(_ contact: CNContact) -> Contact {
        Contact(
            id: contact.identifier,
            givenName: contact.givenName,
            middleName: contact.middleName,
            familyName: contact.familyName,
            nickname: contact.nickname,
            organization: contact.organizationName,
            jobTitle: contact.jobTitle,
            isOrganization: contact.contactType == .organization,
            phones: contact.phoneNumbers.map { entry in
                let value = entry.value.stringValue
                return Contact.Phone(
                    label: entry.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) },
                    value: value,
                    normalized: PhoneNumber.parse(value, region: region).flatMap { $0.isE164 ? $0.normalized : nil }
                )
            },
            emails: contact.emailAddresses.map { entry in
                Contact.Email(label: entry.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }, value: entry.value as String)
            },
            birthday: BirthdayText.text(contact.birthday)
        )
    }

    private func requireAccess() throws {
        let status = authorization
        guard status == .authorized || status == .limited else { throw ContactsError.notAuthorized(status) }
    }

    private func execute(_ request: CNSaveRequest) throws {
        do {
            try store.execute(request)
        } catch {
            throw ContactsError.saveFailed(error.localizedDescription)
        }
    }

    static func map(_ status: CNAuthorizationStatus) -> ContactsAuthorization {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .limited: return .limited
        @unknown default: return .denied
        }
    }

    static func phoneLabel(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return CNLabelPhoneNumberMobile }
        switch label.lowercased() {
        case "mobile", "cell": return CNLabelPhoneNumberMobile
        case "iphone": return CNLabelPhoneNumberiPhone
        case "main": return CNLabelPhoneNumberMain
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "school": return CNLabelSchool
        case "other": return CNLabelOther
        case "home fax": return CNLabelPhoneNumberHomeFax
        case "work fax": return CNLabelPhoneNumberWorkFax
        case "pager": return CNLabelPhoneNumberPager
        default: return label
        }
    }

    static func emailLabel(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return CNLabelHome }
        switch label.lowercased() {
        case "home", "personal": return CNLabelHome
        case "work": return CNLabelWork
        case "school": return CNLabelSchool
        case "icloud": return CNLabelEmailiCloud
        case "other": return CNLabelOther
        default: return label
        }
    }
}
