import Foundation

/// How exclusions are stored in the settings file. A conversation is stored by its GUID
/// (or `chat:<id>` in older settings). A person is stored by each of their addresses as
/// well, `address:+14155550142` or `address:maya@example.com`, which excludes every
/// one-to-one conversation with that address, including ones that start later.
public enum Exclusion {
    public static let addressPrefix = "address:"

    /// The stored form of an excluded address: canonical E.164 or lowercased email.
    public static func entry(for address: Address) -> String { addressPrefix + address.value }

    /// The address an entry excludes, or nil for a conversation entry. Case and surrounding
    /// space don't matter, so a hand-edited entry can't silently stop excluding.
    public static func address(in entry: String, region: String?) -> Address? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(addressPrefix) else { return nil }
        let value = String(trimmed.dropFirst(addressPrefix.count)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : Address(value, region: region)
    }

    /// The addresses of `person` that an exclusion stores: phone numbers with a country code,
    /// emails and short codes, canonical and without repeats.
    public static func addresses(of person: Person, region: String?) -> [Address] {
        var seen = Set<String>()
        return person.addresses.map { Address($0, region: region) }
            .filter { $0.kind != .other && !$0.lacksCountryCode && seen.insert($0.value).inserted }
    }
}
