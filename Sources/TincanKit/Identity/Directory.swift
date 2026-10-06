import Foundation

/// How certain a match between an address and a contact is.
public enum MatchQuality: String, Sendable, Codable, Comparable {
    /// Same E.164 number or the same email address.
    case exact
    /// Same national number, where one side had no country code.
    case national

    public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool {
        lhs == .national && rhs == .exact
    }
}

/// An address normalized for comparison: an E.164 number, a lowercased email, or the raw
/// text for short codes and business ids.
public struct Address: Hashable, Sendable, Comparable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable {
        case phone, email
        case shortCode = "short_code"
        case other
    }

    public let kind: Kind
    /// The canonical form used as an identity key.
    public let value: String
    let phone: PhoneNumber?

    public var description: String { value }

    /// A phone number written without a country code that the region couldn't complete,
    /// such as `09012345678` on a Mac set to the US. Its digits alone name no line.
    public var lacksCountryCode: Bool {
        guard kind == .phone, let phone else { return false }
        return !phone.isE164 && !phone.normalized.hasPrefix("+")
    }

    public static func < (lhs: Address, rhs: Address) -> Bool { lhs.value < rhs.value }

    public init(_ raw: String, region: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@"), !trimmed.hasPrefix("urn:") {
            kind = .email
            value = trimmed.lowercased()
            phone = nil
        } else if let number = PhoneNumber.parse(trimmed, region: region) {
            phone = number
            if number.isShortCode {
                kind = .shortCode
            } else {
                kind = .phone
            }
            value = number.normalized
        } else {
            kind = .other
            value = trimmed
            phone = nil
        }
    }

    /// Human formatting: `+1 (415) 555-0142`, `+44 20 7946 0000`, emails unchanged.
    public var formatted: String {
        guard kind == .phone, let phone, let code = phone.countryCode else { return value }
        let national = phone.nationalNumber
        if code == "1", national.count == 10 {
            let digits = Array(national)
            return "+1 (\(String(digits[0..<3]))) \(String(digits[3..<6]))-\(String(digits[6..<10]))"
        }
        // Numbering plans differ by country; groups of four from the right read well everywhere.
        var groups: [String] = []
        var remaining = Substring(national)
        while remaining.count > 4 {
            groups.insert(String(remaining.suffix(4)), at: 0)
            remaining = remaining.dropLast(4)
        }
        if !remaining.isEmpty { groups.insert(String(remaining), at: 0) }
        return "+\(code) " + groups.joined(separator: " ")
    }
}

/// Everything tincan knows about who is behind an address.
///
/// Built from Apple Contacts (through Contacts.framework) and the addresses Messages and call
/// history use. A match between an address and a contact is a fact about the address book,
/// not proof of who wrote a message; tincan reports ambiguity instead of guessing.
public final class Directory {
    public struct Match: Sendable {
        public let contact: Contact
        public let quality: MatchQuality
    }

    public let contacts: [Contact]
    public let region: String?
    private var byID: [String: Contact] = [:]
    private var exactIndex: [String: Set<String>] = [:]
    /// Numbers saved without a country code, by their digits.
    private var withoutCountryIndex: [String: Set<String>] = [:]
    /// Numbers saved with a country code, by each of their `PhoneNumber.nationalForms`.
    private var nationalFormIndex: [String: Set<String>] = [:]
    private var matchCache: [String: [Match]] = [:]

    public init(contacts: [Contact], region: String?) {
        self.contacts = contacts
        self.region = region
        for contact in contacts {
            byID[contact.id] = contact
            for phone in contact.phones {
                let address = Address(phone.value, region: region)
                // A number with an extension reaches this person through a shared line; calls
                // and texts from that line's main number are not from them.
                guard address.kind == .phone || address.kind == .shortCode, address.phone?.phoneExtension == nil else { continue }
                exactIndex[address.value, default: []].insert(contact.id)
                guard address.kind == .phone, let number = address.phone else { continue }
                if number.isE164 {
                    for form in number.nationalForms where form.count >= 7 {
                        nationalFormIndex[form, default: []].insert(contact.id)
                    }
                } else if number.nationalNumber.count >= 7 {
                    withoutCountryIndex[number.nationalNumber, default: []].insert(contact.id)
                }
            }
            // Only real addresses: a blank email would claim every sender Messages did not record.
            for email in contact.emails {
                let address = Address(email.value, region: region)
                if address.kind == .email { exactIndex[address.value, default: []].insert(contact.id) }
            }
        }
    }

    public func contact(id: String) -> Contact? { byID[id] }

    /// Contacts whose phone numbers or email addresses match `raw`, best matches first.
    /// Several results mean the address is on several cards (a shared family line, or
    /// duplicates); callers must not pick one silently.
    public func matches(for raw: String) -> [Match] {
        if let cached = matchCache[raw] { return cached }
        let address = Address(raw, region: region)
        var result: [Match] = []
        if let ids = exactIndex[address.value], !ids.isEmpty {
            result = ids.compactMap { byID[$0] }.map { Match(contact: $0, quality: .exact) }
        } else if address.kind == .phone, let number = address.phone {
            // Only one side may lack the country code; the same digits in two countries are
            // two different lines (see `PhoneNumber.matches`).
            var ids = Set<String>()
            if number.isE164 {
                for form in number.nationalForms { ids.formUnion(withoutCountryIndex[form] ?? []) }
            } else if number.nationalNumber.count >= 7 {
                ids = nationalFormIndex[number.nationalNumber] ?? []
            }
            result = ids.compactMap { byID[$0] }.map { Match(contact: $0, quality: .national) }
        }
        result.sort { $0.contact.displayName.localizedStandardCompare($1.contact.displayName) == .orderedAscending }
        matchCache[raw] = result
        return result
    }

    /// The single contact for `raw`, or nil when there is none or more than one.
    public func uniqueContact(for raw: String) -> Contact? {
        let found = matches(for: raw)
        return found.count == 1 ? found[0].contact : nil
    }

    /// The name to show for an address: the contact's name when exactly one contact has it,
    /// otherwise the formatted address.
    public func displayName(for raw: String) -> String {
        if let contact = uniqueContact(for: raw) { return contact.displayName }
        return Address(raw, region: region).formatted
    }

    /// Shorter label for conversation views.
    public func shortName(for raw: String) -> String {
        if let contact = uniqueContact(for: raw) { return contact.shortName }
        return Address(raw, region: region).formatted
    }

    /// Canonical addresses on a contact card. Numbers with an extension are left out: they
    /// name a shared line, which cannot be texted to reach this person.
    public func addresses(of contact: Contact) -> [Address] {
        let phones = contact.phones.map { Address($0.value, region: region) }.filter { address in
            let dialable = address.kind == .phone || address.kind == .shortCode
            return dialable && address.phone?.phoneExtension == nil
        }
        let emails = contact.emails.map { Address($0.value, region: region) }.filter { $0.kind == .email }
        var seen = Set<String>()
        return (phones + emails).filter { seen.insert($0.value).inserted }
    }

    // MARK: Name search

    public struct NameCandidate: Sendable {
        public let contact: Contact
        /// Lower is better: 0 exact full name (in either order, with or without a space, as
        /// Japanese or Hungarian names are written), 1 exact nickname, 2 exact given or family
        /// name, 3 word prefix, 4 substring.
        public let rank: Int
    }

    /// Contacts whose name, nickname or organization matches `query`, best first. Ignores
    /// case and diacritics.
    public func search(name query: String) -> [NameCandidate] {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return [] }
        var candidates: [NameCandidate] = []
        for contact in contacts {
            let full = Self.fold([contact.givenName, contact.middleName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " "))
            let firstLast = Self.fold([contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " "))
            let lastFirst = Self.fold([contact.familyName, contact.givenName].filter { !$0.isEmpty }.joined(separator: " "))
            let spaceless = needle.replacingOccurrences(of: " ", with: "")
            let nickname = Self.fold(contact.nickname)
            let organization = Self.fold(contact.organization)
            let given = Self.fold(contact.givenName)
            let family = Self.fold(contact.familyName)
            let words = Set((full + " " + nickname + " " + organization).split(separator: " ").map(String.init))
            let rank: Int?
            let fullNames = [full, firstLast, lastFirst]
            if fullNames.contains(needle) || fullNames.contains(where: { $0.replacingOccurrences(of: " ", with: "") == spaceless })
                || (contact.isOrganization && needle == organization)
            {
                rank = 0
            } else if !nickname.isEmpty, needle == nickname {
                rank = 1
            } else if needle == given || needle == family || needle == organization {
                rank = 2
            } else if words.contains(where: { $0.hasPrefix(needle) }) || firstLast.hasPrefix(needle) || full.hasPrefix(needle) {
                rank = 3
            } else if full.contains(needle) || nickname.contains(needle) || organization.contains(needle) {
                rank = 4
            } else {
                rank = nil
            }
            if let rank { candidates.append(NameCandidate(contact: contact, rank: rank)) }
        }
        return candidates.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.contact.displayName.localizedStandardCompare($1.contact.displayName) == .orderedAscending
        }
    }

    /// The worst rank that matches `query` as well as the best one found. A one-word name
    /// matches a card's full name, nickname, first or last name alike: "Alex" could mean
    /// Alex Kim as much as Alexander nicknamed Alex, or a card named just Alex.
    public static func cutoff(best: Int, query: String) -> Int {
        best <= 2 && !fold(query).trimmingCharacters(in: .whitespaces).contains(" ") ? 2 : best
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
