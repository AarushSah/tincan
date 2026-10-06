import Foundation

/// Contact cards that may describe the same person, or people who share an address.
///
/// tincan reports these with the evidence and never merges or picks between them: two cards
/// with one number can be a duplicate, a family line or a shared work phone, and only the
/// person who owns the address book knows which.
public struct ContactGroup: Sendable {
    public enum Kind: String, Sendable, Codable {
        /// The cards have a phone number or email in common.
        case sharedAddress = "shared_address"
        /// The cards have the same name and no address in common.
        case sameName = "same_name"
    }

    public let kind: Kind
    public let contacts: [Contact]
    /// Canonical addresses on more than one card in the group.
    public let sharedAddresses: [String]
    /// Whether every card has the same name (ignoring case, accents and spacing).
    public let namesMatch: Bool
}

extension Directory {
    /// Groups of cards that share an address, then groups of cards that share a name.
    /// Each card appears in at most one shared-address group; same-name groups only list
    /// cards not already grouped together by an address.
    public func contactGroups() -> [ContactGroup] {
        var cardsByAddress: [String: Set<String>] = [:]
        for contact in contacts {
            for address in addresses(of: contact) {
                cardsByAddress[address.value, default: []].insert(contact.id)
                for match in matches(for: address.value) where match.contact.id != contact.id {
                    cardsByAddress[address.value, default: []].insert(match.contact.id)
                }
            }
        }

        // Union cards that share any address.
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current { current = next }
            return current
        }
        for ids in cardsByAddress.values where ids.count > 1 {
            let sorted = ids.sorted()
            for id in sorted { if parent[id] == nil { parent[id] = id } }
            for id in sorted.dropFirst() { parent[root(id)] = root(sorted[0]) }
        }
        var members: [String: [String]] = [:]
        for id in parent.keys { members[root(id), default: []].append(id) }

        var groups: [ContactGroup] = []
        var grouped = Set<String>()
        for ids in members.values where ids.count > 1 {
            let cards = ids.compactMap { contact(id: $0) }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            let idSet = Set(ids)
            let shared = cardsByAddress.filter { $0.value.intersection(idSet).count > 1 }.map(\.key).sorted()
            let names = Set(cards.map { Self.fold($0.displayName) })
            groups.append(ContactGroup(kind: .sharedAddress, contacts: cards, sharedAddresses: shared, namesMatch: names.count == 1))
            grouped.formUnion(ids)
        }

        var byName: [String: [Contact]] = [:]
        for contact in contacts {
            let name = Self.fold(contact.displayName)
            guard !name.isEmpty, contact.displayName != "Unnamed contact" else { continue }
            byName[name, default: []].append(contact)
        }
        for cards in byName.values where cards.count > 1 {
            // Skip names whose cards are already one shared-address group.
            let roots = Set(cards.map { grouped.contains($0.id) ? root($0.id) : $0.id })
            guard roots.count > 1 else { continue }
            groups.append(ContactGroup(kind: .sameName, contacts: cards.sorted { $0.id < $1.id }, sharedAddresses: [], namesMatch: true))
        }

        return groups.sorted {
            if $0.kind != $1.kind { return $0.kind == .sharedAddress }
            return ($0.contacts.first?.displayName ?? "").localizedStandardCompare($1.contacts.first?.displayName ?? "") == .orderedAscending
        }
    }
}
