import Foundation
import Testing

/// Messages the person deleted sit in Recently Deleted, linked to their conversation only
/// through `chat_recoverable_message_join`. No command shows them, quotes them, pages from
/// them or reports reactions to them, including one deleted from an excluded conversation.
@Suite("Recently deleted messages in commands")
struct RecentlyDeletedCommandTests {
    let world: World
    let fixture: MessagesFixture
    let maya: Int64
    let doorCode: MessagesFixture.Row
    let pin: MessagesFixture.Row
    let fromExcluded: MessagesFixture.Row
    /// What tincan may show: two messages from Maya and your reply to the door code.
    let visible: [MessagesFixture.Row]

    /// Words only the deleted messages contain.
    static let secrets = ["4417", "9021", "pineapple"]

    init() throws {
        // Sam Rivera's conversation is excluded, as the person set it up.
        world = try World(settings: "region = \"US\"\n[privacy]\nexclude = [\"iMessage;-;+16285550131\"]\n")
        fixture = try MessagesFixture()
        let mayaPhone = try fixture.addHandle("+14155550142")
        let rivera = try fixture.addHandle("+16285550131")
        maya = try fixture.addChat("iMessage;-;+14155550142", participants: [mayaPhone])
        let excluded = try fixture.addChat("iMessage;-;+16285550131", participants: [rivera])

        let first = try fixture.addMessage("are we still on for dinner?", in: maya, from: .handle(mayaPhone), at: World.ago(hours: 3))
        let code = try fixture.addMessage("the door code is 4417", in: maya, from: .handle(mayaPhone), at: World.ago(hours: 2, minutes: 50)) {
            $0.isRead = false
        }
        doorCode = code
        let reply = try fixture.addMessage("noted, thanks", in: maya, from: .meTo(mayaPhone), at: World.ago(hours: 2, minutes: 40)) {
            $0.threadOriginatorGUID = code.guid
        }
        pin = try fixture.addMessage("my pin is 9021", in: maya, from: .meTo(mayaPhone), at: World.ago(hours: 2, minutes: 30))
        try fixture.addReaction(.love, to: pin, in: maya, from: .handle(mayaPhone), at: World.ago(hours: 2, minutes: 20))
        fromExcluded = try fixture.addMessage("pineapple plans for friday", in: excluded, from: .handle(rivera), at: World.ago(hours: 2)) { $0.isRead = false }
        let last = try fixture.addMessage("see you at 7", in: maya, from: .handle(mayaPhone), at: World.ago(hours: 1)) { $0.isRead = false }
        visible = [first, reply, last]

        try fixture.moveToRecentlyDeleted(doorCode, from: maya, at: World.ago(minutes: 30))
        try fixture.moveToRecentlyDeleted(pin, from: maya, at: World.ago(minutes: 30))
        try fixture.moveToRecentlyDeleted(fromExcluded, from: excluded, at: World.ago(minutes: 30))
    }

    private var environment: [String: String] { ["TINCAN_MESSAGES_DB": fixture.path] }
    private var deleted: [MessagesFixture.Row] { [doorCode, pin, fromExcluded] }

    /// Every `m:<id>` reference anywhere in a JSON document.
    private func references(_ value: Any) -> Set<String> {
        switch value {
        case let object as [String: Any]:
            var found = Set<String>()
            for (key, item) in object {
                if key == "ref", let text = item as? String, text.hasPrefix("m:") { found.insert(text) }
                found.formUnion(references(item))
            }
            return found
        case let array as [Any]:
            return array.reduce(into: Set<String>()) { $0.formUnion(references($1)) }
        default:
            return []
        }
    }

    @Test func noCommandShowsADeletedMessage() throws {
        let commands: [[String]] = [
            [], ["chats"], ["chats", "--all"], ["read", "Maya"], ["read", "chat:\(maya)"], ["who", "Maya"],
            ["inbox"], ["inbox", "--since", "1d", "--mine"], ["inbox", "--after", "0", "--mine"],
            ["search", "door code"], ["search", "pin is"], ["search", "plans for"], ["search", "e", "--limit", "500"],
        ]
        let hidden = Set(deleted.map { "m:\($0.rowID)" })
        for command in commands {
            for json in [false, true] {
                let result = try world.run(command + (json ? ["--json"] : []), environment: environment)
                #expect(result.status == 0, "tincan \(command.joined(separator: " ")): \(result.stderr)")
                for secret in Self.secrets {
                    #expect(!result.stdout.contains(secret), "tincan \(command.joined(separator: " ")) printed \(secret)")
                    #expect(!result.stderr.contains(secret))
                }
                // Reactions name their target by GUID; a deleted target must not appear.
                #expect(!result.stdout.contains(pin.guid), "tincan \(command.joined(separator: " ")) reported a reaction to a deleted message")
                #expect(!result.stdout.contains(fromExcluded.guid))
                if json {
                    #expect(references(try result.json).isDisjoint(with: hidden), "tincan \(command.joined(separator: " "))")
                }
            }
        }
    }

    @Test func theCursorReadsOnlyWhatIsLeft() throws {
        let inbox = try world.json(["inbox", "--after", "0", "--mine"], environment: environment).dataObject
        let conversations = inbox["conversations"] as? [[String: Any]] ?? []
        // Nothing comes back without a conversation.
        #expect(conversations.compactMap { $0["chat"] as? String } == ["chat:\(maya)"])
        let messages = conversations.first?["messages"] as? [[String: Any]] ?? []
        #expect(messages.compactMap { $0["ref"] as? String } == visible.map { "m:\($0.rowID)" })
        #expect((inbox["reactions"] as? [Any])?.isEmpty ?? true)

        let unread = try world.json(["inbox"], environment: environment).dataObject
        let unreadMessages = (unread["conversations"] as? [[String: Any]] ?? []).flatMap { $0["messages"] as? [[String: Any]] ?? [] }
        #expect(unreadMessages.compactMap { $0["text"] as? String } == ["see you at 7"])
    }

    @Test func aReplyKeepsItsLinkButNotTheDeletedQuote() throws {
        let read = try world.json(["read", "Maya"], environment: environment).dataObject
        let messages = read["messages"] as? [[String: Any]] ?? []
        #expect(messages.compactMap { $0["text"] as? String } == ["are we still on for dinner?", "noted, thanks", "see you at 7"])
        #expect(messages.first { $0["text"] as? String == "noted, thanks" }?["reply_to"] as? String == doorCode.guid)
        let human = try world.run(["read", "Maya"], environment: environment).stdout
        #expect(human.contains("noted, thanks"))
        #expect(!human.contains("4417"))
    }

    @Test func aDeletedMessageCantAnchorAPage() throws {
        for row in deleted {
            let reference = "m:\(row.rowID)"
            for command in [
                ["read", "Maya", "--around", reference], ["read", "Maya", "--after", reference], ["read", "Maya", "--before", reference],
                ["search", "e", "--before", reference],
            ] {
                let result = try world.json(command, environment: environment)
                #expect(result.status == 3, "tincan \(command.joined(separator: " "))")
                #expect(try result.errorCode == "unknown_message", "tincan \(command.joined(separator: " "))")
            }
        }
    }

    @Test func watchNeverStreamsADeletedMessage() throws {
        let running = try CLI.start(
            ["watch", "--json", "--after", "0", "--mine", "--interval", "0.2"],
            environment: world.environment.merging(environment) { $1 }
        )
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, running.output.components(separatedBy: "\"type\":\"message\"").count <= visible.count { usleep(50_000) }
        usleep(500_000)
        let result = running.stop()
        for secret in Self.secrets { #expect(!result.stdout.contains(secret)) }
        let events = try result.jsonLines
        let refs = events.compactMap { ($0["message"] as? [String: Any])?["ref"] as? String }
        #expect(refs == visible.map { "m:\($0.rowID)" })
        #expect(!events.contains { $0["type"] as? String == "reaction" })
    }
}
