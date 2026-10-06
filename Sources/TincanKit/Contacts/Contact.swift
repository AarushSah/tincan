import Foundation

/// A person or organization from Apple Contacts, reduced to the fields tincan uses.
public struct Contact: Sendable, Hashable, Codable, Identifiable {
    public struct Phone: Sendable, Hashable, Codable {
        /// Localized label such as "mobile", "home" or a custom label.
        public var label: String?
        /// The number as stored in Contacts.
        public var value: String
        /// E.164 when the number could be normalized.
        public var normalized: String?

        public init(label: String?, value: String, normalized: String?) {
            self.label = label
            self.value = value
            self.normalized = normalized
        }
    }

    public struct Email: Sendable, Hashable, Codable {
        public var label: String?
        public var value: String

        public init(label: String?, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Apple's contact identifier. Stable on this Mac; it differs across devices.
    public let id: String
    public var givenName: String
    public var middleName: String
    public var familyName: String
    public var nickname: String
    public var organization: String
    public var jobTitle: String
    public var isOrganization: Bool
    public var phones: [Phone]
    public var emails: [Email]
    /// `YYYY-MM-DD`, or `--MM-DD` when the year is unknown.
    public var birthday: String?

    public init(
        id: String, givenName: String = "", middleName: String = "", familyName: String = "", nickname: String = "",
        organization: String = "", jobTitle: String = "", isOrganization: Bool = false,
        phones: [Phone] = [], emails: [Email] = [], birthday: String? = nil
    ) {
        self.id = id
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.jobTitle = jobTitle
        self.isOrganization = isOrganization
        self.phones = phones
        self.emails = emails
        self.birthday = birthday
    }

    /// The name people see in Messages: full name, else nickname, organization, or a handle.
    public var displayName: String {
        if isOrganization, !organization.isEmpty { return organization }
        let full = [givenName, middleName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        if !nickname.isEmpty { return nickname }
        if !organization.isEmpty { return organization }
        if let phone = phones.first { return phone.value }
        if let email = emails.first { return email.value }
        return "Unnamed contact"
    }

    /// Shorter name for conversation views: nickname or given name when available.
    public var shortName: String {
        if !nickname.isEmpty { return nickname }
        if !givenName.isEmpty, !isOrganization { return givenName }
        return displayName
    }
}
