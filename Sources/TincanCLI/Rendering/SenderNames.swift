import Foundation
import TincanKit

/// Labels for the people in one conversation: their short names (nickname or first name),
/// except where two people would share a label, who get their full names instead. The same
/// rule as `Resolver.shortNames(for:)`, with labels looked up by address.
struct SenderNames {
    private let directory: Directory
    private var labels: [String: String] = [:]

    init(_ addresses: [String], directory: Directory) {
        self.directory = directory
        let unique = Array(Set(addresses))
        // One entry per person, so a phone and an email of the same card don't collide.
        var people: [String: Set<String>] = [:]
        for address in unique {
            let person = directory.uniqueContact(for: address).map { "contact:\($0.id)" } ?? Address(address, region: directory.region).value
            people[directory.shortName(for: address), default: []].insert(person)
        }
        for address in unique {
            let short = directory.shortName(for: address)
            labels[address] = (people[short]?.count ?? 0) > 1 ? directory.displayName(for: address) : short
        }
    }

    /// The label for `address`, or "You" for your own messages.
    func label(_ address: String?) -> String {
        guard let address else { return "You" }
        return labels[address] ?? directory.shortName(for: address)
    }
}
