import Foundation

public enum ContactsAuthorization: String, Sendable, Codable {
    case authorized
    case limited
    case denied
    case restricted
    case notDetermined = "not_determined"
}

/// Fields for a new contact.
public struct ContactDraft: Sendable, Equatable {
    public var givenName = ""
    public var middleName = ""
    public var familyName = ""
    public var nickname = ""
    public var organization = ""
    public var jobTitle = ""
    public var phones: [Contact.Phone] = []
    public var emails: [Contact.Email] = []
    public var birthday: String?

    public init() {}

    public var isEmpty: Bool {
        [givenName, middleName, familyName, nickname, organization].allSatisfy(\.isEmpty) && phones.isEmpty && emails.isEmpty
    }
}

/// One change to an existing contact. Edits are applied in order.
public enum ContactEdit: Sendable, Equatable {
    case setGivenName(String)
    case setMiddleName(String)
    case setFamilyName(String)
    case setNickname(String)
    case setOrganization(String)
    case setJobTitle(String)
    case setBirthday(String?)
    case addPhone(label: String?, value: String)
    /// Removes every stored number that matches `value` after normalization.
    case removePhone(String)
    case addEmail(label: String?, value: String)
    case removeEmail(String)
}

public enum ContactsError: Error, CustomStringConvertible, Sendable {
    case notAuthorized(ContactsAuthorization)
    case notFound(id: String)
    case invalidBirthday(String)
    case nothingToChange
    case saveFailed(String)

    public var description: String {
        switch self {
        case .notAuthorized(let status): return "Contacts access is \(status.rawValue.replacingOccurrences(of: "_", with: " "))"
        case .notFound(let id): return "no contact has id \(id)"
        case .invalidBirthday(let value): return "\"\(value)\" is not a birthday; use YYYY-MM-DD or MM-DD"
        case .nothingToChange: return "no changes were requested"
        case .saveFailed(let message): return "Contacts could not save the change: \(message)"
        }
    }
}

/// Access to the address book. `SystemContactsProvider` uses Contacts.framework; tests use
/// `InMemoryContactsProvider`.
public protocol ContactsProvider: AnyObject {
    var authorization: ContactsAuthorization { get }
    /// Shows the system prompt when access has not been decided. Blocks until answered.
    func requestAccess() -> ContactsAuthorization
    func fetchAll() throws -> [Contact]
    func fetch(id: String) throws -> Contact?
    func create(_ draft: ContactDraft) throws -> Contact
    func update(id: String, edits: [ContactEdit]) throws -> Contact
    /// A vCard of the contact as it is now, kept as a backup before a change.
    func vCard(id: String) throws -> Data
}

/// Birthday text used by drafts and edits: `YYYY-MM-DD`, `--MM-DD` or `MM-DD`.
public enum BirthdayText {
    /// The date in `text`, or nil when it is not one, including dates no calendar has, such
    /// as 02-30 or 1990-02-29. 02-29 without a year is a date.
    public static func components(_ text: String) -> DateComponents? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.hasPrefix("--") ? trimmed.dropFirst(2).split(separator: "-") : trimmed.split(separator: "-")
        var components = DateComponents()
        switch parts.count {
        case 3:
            guard let year = Int(parts[0]), parts[0].count == 4, let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
            components.year = year
            components.month = month
            components.day = day
        case 2:
            guard let month = Int(parts[0]), let day = Int(parts[1]) else { return nil }
            components.month = month
            components.day = day
        default:
            return nil
        }
        guard let month = components.month, (1...12).contains(month), let day = components.day,
            (1...daysInMonth[month - 1]).contains(day)
        else { return nil }
        // February 29 exists only in leap years; without a year it is a fine birthday.
        if month == 2, day == 29, let year = components.year, !isLeapYear(year) { return nil }
        return components
    }

    /// The most days each month can have.
    private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func text(_ components: DateComponents?) -> String? {
        guard let components, let month = components.month, let day = components.day else { return nil }
        let monthDay = String(format: "%02d-%02d", month, day)
        if let year = components.year, year != NSDateComponentUndefined { return String(format: "%04d-", year) + monthDay }
        return "--" + monthDay
    }
}
