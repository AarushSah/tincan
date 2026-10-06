import Foundation
import TincanKit

/// Contacts from a JSON file, used instead of Apple Contacts when `TINCAN_CONTACTS_FILE` is
/// set. Tests and demos use it so tincan runs on invented people and never touches the
/// real address book.
///
/// The file is an array of cards in the shape `tincan contacts --json` prints:
///
///     [{"ref": "contact:maya", "given_name": "Maya", "family_name": "Chen",
///       "phones": [{"label": "mobile", "value": "+14155550142"}],
///       "emails": ["maya@example.com"]}]
///
/// `id` may replace `ref`, and phones and emails may be plain strings. An object
/// `{"authorization": "denied", "contacts": […]}` also sets the access status to simulate,
/// and `"answer_to_request": "authorized"` beside `"authorization": "not_determined"` the
/// answer to simulate when tincan asks for access. Adding or editing a contact rewrites the
/// file.
final class FileContactsProvider: ContactsProvider {
    let path: String
    private let region: String?
    private var contacts: [Contact]
    private(set) var authorization: ContactsAuthorization
    /// What asking for access answers while it is not determined; nil leaves it so.
    private let answerToRequest: ContactsAuthorization?

    init(path: String, region: String?) throws {
        self.path = path
        self.region = region
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw TincanError(
                code: "contacts_file_unreadable",
                message: "\(DataSources.contactsVariable) points at \(path), which can't be read.",
                hint: "Fix the path. Unset \(DataSources.contactsVariable) only if the person wants tincan to use this Mac's Apple Contacts."
            )
        }
        do {
            let file = try Self.decoder.decode(File.self, from: data)
            authorization = file.authorization ?? .authorized
            answerToRequest = file.answerToRequest
            contacts = file.contacts.enumerated().map { Self.contact($1, index: $0, region: region) }
        } catch {
            throw TincanError(
                code: "contacts_file_invalid",
                message: "\(path) is not a contacts file: \(Self.describe(error))",
                hint: "It must be a JSON array of contacts, like the `data` of `tincan contacts --json`."
            )
        }
    }

    func requestAccess() -> ContactsAuthorization {
        if authorization == .notDetermined, let answerToRequest { authorization = answerToRequest }
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
        var number = contacts.count + 1
        while contacts.contains(where: { $0.id == "file-\(number)" }) { number += 1 }
        let contact = Contact(
            id: "file-\(number)", givenName: draft.givenName, middleName: draft.middleName, familyName: draft.familyName,
            nickname: draft.nickname, organization: draft.organization, jobTitle: draft.jobTitle,
            isOrganization: draft.givenName.isEmpty && draft.familyName.isEmpty && !draft.organization.isEmpty,
            phones: draft.phones.map { phone($0.value, label: $0.label ?? "mobile") },
            emails: draft.emails.map { Contact.Email(label: $0.label ?? "home", value: $0.value) },
            birthday: draft.birthday
        )
        contacts.append(contact)
        try save()
        return contact
    }

    func update(id: String, edits: [ContactEdit]) throws -> Contact {
        try requireAccess()
        guard !edits.isEmpty else { throw ContactsError.nothingToChange }
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { throw ContactsError.notFound(id: id) }
        let contact = try Self.applying(edits, to: contacts[index], region: region)
        contacts[index] = contact
        try save()
        return contact
    }

    /// `contact` after `edits`, with Apple Contacts' default labels: mobile for a number and
    /// home for an email. `contacts edit --dry-run` previews a change with it.
    static func applying(_ edits: [ContactEdit], to contact: Contact, region: String?) throws -> Contact {
        var contact = contact
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
                contact.phones.append(PhoneNormalizer(region: region).phone(value, label: label ?? "mobile"))
            case .removePhone(let value):
                let target = PhoneNumber.parse(value, region: region)
                contact.phones.removeAll { stored in
                    guard let target, let parsed = PhoneNumber.parse(stored.value, region: region) else { return stored.value == value }
                    return parsed.isSameEntry(target)
                }
            case .addEmail(let label, let value):
                contact.emails.append(Contact.Email(label: label ?? "home", value: value))
            case .removeEmail(let value):
                contact.emails.removeAll { $0.value.caseInsensitiveCompare(value) == .orderedSame }
            }
        }
        return contact
    }

    func vCard(id: String) throws -> Data {
        guard let contact = try fetch(id: id) else { throw ContactsError.notFound(id: id) }
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "N:\(contact.familyName);\(contact.givenName);\(contact.middleName);;", "FN:\(contact.displayName)"]
        if !contact.nickname.isEmpty { lines.append("NICKNAME:\(contact.nickname)") }
        if !contact.organization.isEmpty { lines.append("ORG:\(contact.organization)") }
        if !contact.jobTitle.isEmpty { lines.append("TITLE:\(contact.jobTitle)") }
        lines += contact.phones.map { "TEL;type=\(($0.label ?? "mobile").uppercased()):\($0.value)" }
        lines += contact.emails.map { "EMAIL;type=\(($0.label ?? "home").uppercased()):\($0.value)" }
        if let birthday = contact.birthday { lines.append("BDAY:\(birthday)") }
        lines.append("END:VCARD")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    // MARK: File format

    private struct File: Decodable {
        var authorization: ContactsAuthorization?
        var answerToRequest: ContactsAuthorization?
        var contacts: [Card]

        init(from decoder: Decoder) throws {
            if (try? decoder.unkeyedContainer()) != nil {
                contacts = try [Card](from: decoder)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            authorization = try container.decodeIfPresent(ContactsAuthorization.self, forKey: .authorization)
            answerToRequest = try container.decodeIfPresent(ContactsAuthorization.self, forKey: .answerToRequest)
            contacts = try container.decodeIfPresent([Card].self, forKey: .contacts) ?? []
        }

        enum CodingKeys: String, CodingKey { case authorization, answerToRequest, contacts }
    }

    private struct Card: Decodable {
        var id: String?
        var ref: String?
        var name: String?
        var givenName: String?
        var middleName: String?
        var familyName: String?
        var nickname: String?
        var organization: String?
        var jobTitle: String?
        var isOrganization: Bool?
        var phones: [Labeled]?
        var emails: [Labeled]?
        var birthday: String?
    }

    /// `"+14155550142"` or `{"label": "mobile", "value": "+14155550142"}`.
    private struct Labeled: Decodable {
        var label: String?
        var value: String

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                self.value = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            value = try container.decode(String.self, forKey: .value)
        }

        enum CodingKeys: String, CodingKey { case label, value }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static func contact(_ card: Card, index: Int, region: String?) -> Contact {
        let reference = card.ref.map { $0.hasPrefix("contact:") ? String($0.dropFirst(8)) : $0 }
        var given = card.givenName ?? ""
        var family = card.familyName ?? ""
        let organization = card.organization ?? ""
        // A card saved here keeps its display name in `name`: a company's is its own name,
        // not a first and last name.
        if given.isEmpty, family.isEmpty, card.isOrganization != true, let name = card.name, name != organization {
            let words = name.split(separator: " ").map(String.init)
            given = words.count > 1 ? words.dropLast().joined(separator: " ") : name
            family = words.count > 1 ? words.last ?? "" : ""
        }
        let provider = PhoneNormalizer(region: region)
        return Contact(
            id: card.id ?? reference ?? "file-\(index + 1)",
            givenName: given,
            middleName: card.middleName ?? "",
            familyName: family,
            nickname: card.nickname ?? "",
            organization: organization,
            jobTitle: card.jobTitle ?? "",
            isOrganization: card.isOrganization ?? (given.isEmpty && family.isEmpty && !organization.isEmpty),
            phones: (card.phones ?? []).map { provider.phone($0.value, label: $0.label ?? "mobile") },
            emails: (card.emails ?? []).map { Contact.Email(label: $0.label ?? "home", value: $0.value) },
            birthday: card.birthday
        )
    }

    private func phone(_ value: String, label: String?) -> Contact.Phone {
        PhoneNormalizer(region: region).phone(value, label: label)
    }

    private func save() throws {
        let cards = contacts.map(Payload.contact)
        do {
            try Self.encoder.encode(cards).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw ContactsError.saveFailed("could not write \(path): \(error.localizedDescription)")
        }
    }

    private func requireAccess() throws {
        guard authorization == .authorized || authorization == .limited else { throw ContactsError.notAuthorized(authorization) }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return (path.isEmpty ? "" : "at \(path): ") + context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }
}

/// Fills in the E.164 form of a number the way Apple Contacts cards are read.
private struct PhoneNormalizer {
    let region: String?

    func phone(_ value: String, label: String?) -> Contact.Phone {
        Contact.Phone(label: label, value: value, normalized: PhoneNumber.parse(value, region: region).flatMap { $0.isE164 ? $0.normalized : nil })
    }
}
