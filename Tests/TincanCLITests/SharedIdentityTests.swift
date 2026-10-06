import Foundation
import Testing

/// Jordan Lee and Riley Lee share the Lee family's home number. tincan must never decide
/// which of them a message or call came from: it names neither, lists both, and lets the
/// person or assistant choose.
@Suite("Shared numbers and duplicate cards")
struct SharedIdentityTests {
    let world: World

    init() throws { world = try World() }

    private func possibleNames(_ person: [String: Any]?) -> Set<String> {
        Set(((person?["possible_contacts"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
    }

    @Test func aSharedNumberNamesNobodyAndListsEveryCard() throws {
        let chats = try world.json(["chats", "--limit", "50"]).dataArray
        let lee = try #require(chats.first { $0["ref"] as? String == world.chat("lee") })
        let participant = try #require((lee["participants"] as? [[String: Any]])?.first)
        #expect(participant["contact"] == nil)
        #expect(participant["ambiguous"] as? Bool == true)
        #expect(participant["name"] as? String == "+1 (415) 555-0177")
        #expect(possibleNames(participant) == ["Jordan Lee", "Riley Lee"])
    }

    @Test func messagesFromASharedNumberAreNotAttributedToEitherCard() throws {
        let messages = try world.json(["read", world.chat("lee")]).dataObject["messages"] as? [[String: Any]] ?? []
        let incoming = try #require(messages.first { $0["from"] as? String != "me" })
        #expect(incoming["from"] as? String == "+1 (415) 555-0177")
        #expect(incoming["from_address"] as? String == "+14155550177")
    }

    @Test func whoOnASharedNumberWarnsAndListsTheCards() throws {
        let result = try world.json(["who", "+14155550177"])
        #expect(result.status == 0)
        let data = try result.dataObject
        #expect(data["contact"] == nil)
        let shared = Set(((data["shared_with"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        #expect(shared == ["Jordan Lee", "Riley Lee"])
        #expect(try result.warningCodes.contains("shared_address"))
    }

    /// A number read off one card is not that person's alone.
    @Test func showingACardWarnsWhenItsNumberIsOnAnother() throws {
        let jordan = try world.json(["contacts", "show", "Jordan Lee"])
        #expect(jordan.status == 0)
        try sharedWarning(jordan)
        #expect(try world.json(["contacts", "show", "Maya"]).warningCodes.isEmpty)
    }

    @Test func eitherNameStillResolvesToItsOwnCard() throws {
        let jordan = try world.json(["who", "Jordan Lee"]).dataObject
        #expect((jordan["contact"] as? [String: Any])?["ref"] as? String == "contact:jordan-lee")
    }

    private func refs(_ list: Any?) -> [String] {
        ((list as? [[String: Any]]) ?? []).compactMap { $0["contact"] as? String }
    }

    private func sharedWarning(_ result: CLIResult, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let warning = try #require(
            ((try result.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "shared_address" }, sourceLocation: sourceLocation)
        let message = warning["message"] as? String ?? ""
        #expect(message.contains("+1 (415) 555-0177"), sourceLocation: sourceLocation)
        #expect(message.contains("Riley Lee (contact:riley-lee)"), sourceLocation: sourceLocation)
    }

    @Test func sendingByNameWarnsThatTheNumberIsShared() throws {
        let preview = try world.json(["send", "Jordan Lee", "hi", "--dry-run", "--typing", "paced"])
        #expect(preview.status == 0)
        try sharedWarning(preview)
        let to = try preview.dataObject["to"] as? [String: Any]
        #expect(to?["name"] as? String == "Jordan Lee")
        #expect(refs(to?["shared_with"]) == ["contact:riley-lee"])
        #expect(refs(to?["possible_contacts"]) == ["contact:jordan-lee", "contact:riley-lee"])
        let human = try world.run(["send", "Jordan Lee", "hi", "--dry-run", "--typing", "paced"], columns: 200)
        #expect(human.stderr.contains("A message there reaches whoever uses it, not only Jordan Lee."))
        // The warning stays when the send itself is refused.
        let refused = try world.json(["send", "Jordan Lee", "hi", "--yes", "--typing", "paced"])
        #expect(try refused.errorCode == "sending_unavailable")
        try sharedWarning(refused)
        // The number itself names every card.
        let number = try world.json(["send", "+14155550177", "hi", "--dry-run", "--typing", "paced"])
        let numberTo = try number.dataObject["to"] as? [String: Any]
        #expect(numberTo?["ambiguous"] as? Bool == true)
        #expect(refs(numberTo?["possible_contacts"]) == ["contact:jordan-lee", "contact:riley-lee"])
        #expect(try number.warningCodes.contains("shared_address"))
    }

    @Test func readingByNameWarnsThatTheNumberIsShared() throws {
        let read = try world.json(["read", "Jordan Lee"])
        #expect(read.status == 0)
        try sharedWarning(read)
        let person = try (read.dataObject["conversation"] as? [String: Any])?["person"] as? [String: Any]
        #expect(refs(person?["shared_with"]) == ["contact:riley-lee"])
        try sharedWarning(try world.json(["search", "Lee house", "--from", "Jordan Lee"]))
        try sharedWarning(try world.json(["calls", "Jordan Lee", "--limit", "2"]))
        try sharedWarning(try world.json(["chats", "--with", "Jordan Lee"]))
        let who = try world.json(["who", "Jordan Lee"])
        try sharedWarning(who)
        #expect(refs(try who.dataObject["shared_with"]) == ["contact:riley-lee"])
        #expect(try world.json(["read", world.chat("lee")]).warningCodes.contains("shared_address"))
        // Maya's number is hers alone.
        #expect(try world.json(["read", "Maya"]).warningCodes.isEmpty)
    }

    /// Lifting an exclusion through one card lifts the number for every card that has it, so
    /// `exclude remove` names them, as `exclude add` does.
    @Test func removingAnExclusionOnASharedNumberNamesEveryCard() throws {
        let world = try World()
        try world.run(["exclude", "add", "Jordan Lee"])
        let result = try world.json(["exclude", "remove", "Riley Lee", "--yes"])
        #expect(result.status == 0)
        let warning = ((try result.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "shared_address" }
        #expect((warning?["message"] as? String)?.contains("Jordan Lee (contact:jordan-lee)") == true)
    }

    @Test func watchingByNameWarnsBeforeTheStream() throws {
        let running = try CLI.start(["watch", "--from", "Jordan Lee", "--json", "--interval", "0.2"], environment: world.environment)
        let deadline = Date().addingTimeInterval(10)
        while !running.output.contains("\n"), Date() < deadline { usleep(20_000) }
        let result = running.stop()
        let ready = try #require(try result.jsonLines.first)
        #expect(ready["type"] as? String == "ready")
        let codes = ((ready["warnings"] as? [[String: Any]]) ?? []).compactMap { $0["code"] as? String }
        #expect(codes == ["shared_address"])
    }

    /// An unscoped stream has no warning up front, so the event from the shared number carries it.
    @Test func watchWarnsOnEachEventFromASharedNumber() throws {
        let running = try CLI.start(["watch", "--after", "1", "--json", "--interval", "0.2"], environment: world.environment)
        let deadline = Date().addingTimeInterval(10)
        while !running.output.contains("Lee house"), Date() < deadline { usleep(20_000) }
        let lines = try running.stop().jsonLines
        #expect(lines.first?["warnings"] == nil)
        let lee = try #require(lines.first { ($0["message"] as? [String: Any])?["from_address"] as? String == "+14155550177" })
        let warning = try #require((lee["warnings"] as? [[String: Any]])?.first)
        #expect(warning["code"] as? String == "shared_address")
        #expect((warning["message"] as? String)?.contains("Riley Lee (contact:riley-lee)") == true)
        // Events from numbers on one card or none carry nothing.
        #expect(lines.filter { $0["warnings"] != nil }.count == 1)
    }

    /// Kenji's number on a second card too, so a group member is a shared number.
    @Test func readingAGroupWarnsWhenAMemberIsOnSeveralCards() throws {
        let contacts = World.contactsJSON.replacingOccurrences(
            of: #"{"id": "kenji","#,
            with: #"{"id": "kenji-work", "given_name": "Kenji", "family_name": "Sato", "phones": [{"label": "work", "value": "+819012345678"}]},"# + "\n      "
                + #"{"id": "kenji","#
        )
        let world = try World(contacts: contacts)
        let result = try world.json(["read", world.chat("crew")])
        #expect(result.status == 0)
        let warning = try #require(((try result.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "shared_address" })
        #expect((warning["message"] as? String)?.contains("Kenji Sato (contact:kenji-work)") == true)
        let messages = try result.dataObject["messages"] as? [[String: Any]] ?? []
        let kenji = messages.filter { $0["from_address"] as? String == "+819012345678" }
        #expect(!kenji.isEmpty)
        #expect(kenji.allSatisfy { !["健二 佐藤", "Kenji Sato"].contains($0["from"] as? String ?? "") })
        // Without the second card, the group says nothing.
        #expect(try World().json(["read", world.chat("crew")]).warningCodes.isEmpty)
    }

    /// The usual contacts, with a second number on Riley Lee's card only.
    static let rileyHasAMobile = World.contactsJSON.replacingOccurrences(
        of: #""riley-lee", "given_name": "Riley", "family_name": "Lee", "phones": [{"label": "home", "value": "+14155550177"}]"#,
        with:
            #""riley-lee", "given_name": "Riley", "family_name": "Lee", "phones": [{"label": "home", "value": "+14155550177"}, {"label": "mobile", "value": "+14155550178"}]"#
    )

    @Test func aFamilyNameSaysBothCardsShareOneConversation() throws {
        let world = try World(contacts: Self.rileyHasAMobile)
        let result = try world.json(["send", "Lee", "hi", "--dry-run"])
        #expect(result.status == 3)
        #expect(try result.errorCode == "ambiguous")
        let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
        let jordan = try #require(candidates.first { $0["reference"] as? String == "contact:jordan-lee" })
        #expect(jordan["detail"] as? String == "same number as Riley Lee · \(world.chat("lee"))")
        #expect(jordan["addresses"] as? [String] == ["+14155550177"])
        #expect(jordan["conversations"] as? Int == 1)
        #expect(jordan["last_activity"] is String)
        let shared = try #require((jordan["shares_address_with"] as? [[String: Any]])?.first)
        #expect(shared["contact"] as? String == "contact:riley-lee")
        #expect(shared["address"] as? String == "+14155550177")
        #expect(shared["chats"] as? [String] == [world.chat("lee")])
        let hint = try result.error?["hint"] as? String ?? ""
        #expect(hint.contains("Ask the person which one"))
        #expect(hint.contains("`tincan send <reference> …`"))
        #expect(hint.contains("share one conversation"))
        #expect(hint.contains("\"same number\""))
    }

    /// Two cards with one email: the hint names the mark the candidates carry.
    @Test func aSharedEmailIsCalledAnEmailInTheHint() throws {
        let contacts = World.contactsJSON.replacingOccurrences(
            of: #"{"id": "kenji","#,
            with: #"{"id": "maya-old", "given_name": "Maya", "family_name": "Chen", "emails": [{"label": "home", "value": "maya@example.com"}]},"# + "\n      "
                + #"{"id": "kenji","#
        )
        let world = try World(contacts: contacts)
        let result = try world.json(["who", "Maya"])
        #expect(result.status == 3)
        let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.allSatisfy { ($0["detail"] as? String)?.hasPrefix("same email") == true })
        let hint = try result.error?["hint"] as? String ?? ""
        #expect(hint.contains("\"same email\""))
        #expect(!hint.contains("same number"))
    }

    @Test func aFamilyNameIsAmbiguousWhenTheCardsDifferAtAll() throws {
        let world = try World(contacts: Self.rileyHasAMobile)
        for command in [["who", "Lee"], ["read", "Lee"], ["search", "house", "--in", "Lee"]] {
            let result = try world.json(command)
            #expect(result.status == 3, "tincan \(command.joined(separator: " "))")
            #expect(try result.errorCode == "ambiguous")
            let candidates = Set(((try result.error?["candidates"] as? [[String: Any]]) ?? []).compactMap { $0["reference"] as? String })
            #expect(candidates == ["contact:jordan-lee", "contact:riley-lee"])
        }
    }

    @Test func aFamilyNameForCardsWithOnlyTheSharedNumberIsTheNumber() throws {
        // Both Lee cards have only the home number, so "Lee" leads to one conversation
        // whichever card was meant: the number, on neither card.
        let who = try world.json(["who", "Lee"])
        #expect(who.status == 0)
        let data = try who.dataObject
        #expect(data["contact"] == nil)
        #expect(data["ref"] as? String == "+14155550177")
        #expect(Set(((data["shared_with"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }) == ["Jordan Lee", "Riley Lee"])
        #expect(try who.warningCodes.contains("shared_address"))

        let read = try world.json(["read", "Lee"])
        #expect(read.status == 0)
        let person = try (read.dataObject["conversation"] as? [String: Any])?["person"] as? [String: Any]
        #expect(person?["contact"] == nil)
        #expect(person?["ambiguous"] as? Bool == true)
        #expect(possibleNames(person) == ["Jordan Lee", "Riley Lee"])
        #expect(try read.warningCodes.contains("shared_address"))

        let send = try world.json(["send", "Lee", "hi", "--dry-run", "--typing", "paced"])
        #expect(send.status == 0)
        #expect(try send.dataObject["chat"] as? String == world.chat("lee"))
        let to = try send.dataObject["to"] as? [String: Any]
        #expect(to?["contact"] == nil)
        #expect(to?["ambiguous"] as? Bool == true)
        #expect(refs(to?["possible_contacts"]) == ["contact:jordan-lee", "contact:riley-lee"])
        let warning = try #require(((try send.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "shared_address" })
        #expect((warning["message"] as? String ?? "").contains("A message there reaches whoever uses it."))

        let search = try world.json(["search", "house", "--in", "Lee"])
        #expect(search.status == 0)
        #expect(try search.dataArray.count == 1)
        #expect(try search.warningCodes.contains("shared_address"))

        let running = try CLI.start(["watch", "--in", "Lee", "--json", "--interval", "0.2"], environment: world.environment)
        let deadline = Date().addingTimeInterval(10)
        while !running.output.contains("\n"), Date() < deadline { usleep(20_000) }
        let ready = try #require(try running.stop().jsonLines.first)
        #expect(ready["type"] as? String == "ready")
        #expect(((ready["warnings"] as? [[String: Any]]) ?? []).compactMap { $0["code"] as? String } == ["shared_address"])
    }

    @Test func duplicatesListsCardsSharingAnAddressWithTheEvidence() throws {
        let result = try world.json(["contacts", "duplicates"])
        #expect(result.status == 0)
        let groups = try result.dataArray
        let lee = try #require(groups.first { ($0["shared_addresses"] as? [String])?.contains("+14155550177") == true })
        #expect(lee["kind"] as? String == "shared_address")
        #expect(lee["names_match"] as? Bool == false)
        let cards = Set(((lee["cards"] as? [[String: Any]]) ?? []).compactMap { $0["ref"] as? String })
        #expect(cards == ["contact:jordan-lee", "contact:riley-lee"])
    }

    @Test func duplicatesShowHowMuchEachCardIsUsed() throws {
        // A second Maya Chen card, on a number nobody has messaged.
        var contacts = try JSONSerialization.jsonObject(with: Data(World.contactsJSON.utf8)) as? [[String: Any]] ?? []
        contacts.append(["id": "maya-old", "given_name": "Maya", "family_name": "Chen", "phones": [["label": "mobile", "value": "+14155550109"]]])
        let world = try World(contacts: String(decoding: try JSONSerialization.data(withJSONObject: contacts), as: UTF8.self))
        let result = try world.json(["contacts", "duplicates"])
        #expect(result.status == 0)
        let cards = try result.dataArray.flatMap { ($0["cards"] as? [[String: Any]]) ?? [] }
        func card(_ ref: String) throws -> [String: Any] { try #require(cards.first { $0["ref"] as? String == ref }) }
        let maya = try card("contact:maya")
        #expect(maya["conversations"] as? Int == 4)
        #expect(maya["last_activity"] is String)
        let old = try card("contact:maya-old")
        #expect(old["conversations"] as? Int == 0)
        #expect(old["last_activity"] == nil)
        #expect(try card("contact:jordan-lee")["conversations"] as? Int == 1)
        try JSONShape.expect(result.json, matches: "contacts-duplicates")
        // Facts only: tincan never says which card to keep.
        #expect(try result.dataArray.allSatisfy { $0["keep"] == nil && $0["recommended"] == nil })
        let human = try world.run(["contacts", "duplicates"], columns: 120).stdout
        #expect(human.contains("4 conversations, last "))
        #expect(human.contains("no conversations"))
        // Other commands' cards don't grow these fields.
        #expect(try world.json(["contacts", "show", "contact:maya"]).dataObject["conversations"] == nil)
    }

    @Test func duplicatesStillListCardsWithoutMessages() throws {
        let missing = world.directory.appendingPathComponent("no-chat.db").path
        let result = try world.json(["contacts", "duplicates"], environment: ["TINCAN_MESSAGES_DB": missing])
        #expect(result.status == 0)
        #expect(try result.warningCodes == ["messages_unavailable"])
        let cards = try result.dataArray.flatMap { ($0["cards"] as? [[String: Any]]) ?? [] }
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0["conversations"] == nil && $0["last_activity"] == nil })
        let human = try world.run(["contacts", "duplicates"], environment: ["TINCAN_MESSAGES_DB": missing])
        #expect(human.stdout.contains("contact:jordan-lee"))
        #expect(!human.stdout.contains("conversation"))
    }

    /// A bare number in `from` otherwise reads like someone who isn't in Contacts.
    @Test func inboxAndSearchWarnWhenASenderIsOnSeveralCards() throws {
        let inbox = try world.json(["inbox", "--since", "3d"])
        #expect(inbox.status == 0)
        try sharedWarning(inbox)
        let search = try world.json(["search", "Lee house"])
        #expect(search.status == 0)
        try sharedWarning(search)
        // Once per address, even when a named person already warned about it.
        let scoped = try world.json(["search", "house", "--in", "Jordan Lee"])
        #expect(try scoped.warningCodes.filter { $0 == "shared_address" }.count == 1)
        // Nothing to say when no sender shares a number.
        #expect(try world.json(["search", "dinner"]).warningCodes.isEmpty)
    }

    @Test func excludingOneCardOnASharedNumberSaysItCoversTheOthers() throws {
        let result = try world.json(["exclude", "add", "Jordan Lee"])
        #expect(result.status == 0)
        try sharedWarning(result)
        let entries = try result.dataArray
        #expect(entries.contains { $0["ref"] as? String == "address:+14155550177" && $0["added"] as? Bool == true })
    }

    @Test func addingACardWithAnExistingNameWarnsWithoutRefusing() throws {
        let result = try world.json(["contacts", "add", "--name", "Maya Chen", "--phone", "+14155550123", "--dry-run"])
        #expect(result.status == 0)
        #expect(try result.warningCodes.contains("same_name_exists"))
    }
}
