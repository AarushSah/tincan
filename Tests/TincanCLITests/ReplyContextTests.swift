import Foundation
import Testing

@Suite("Reply context in command output")
struct ReplyContextTests {
    @Test func threadedRepliesIncludePreviewsAcrossReadingCommands() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("RCS;-;+14155550142", service: "RCS", participants: [maya])
        let parent = try fixture.addMessage("Dinner at seven?", in: chat, from: .handle(maya), at: Date().addingTimeInterval(-60))
        let reply = try fixture.addMessage("Yes!", in: chat, from: .me, at: Date()) { $0.threadOriginatorGUID = "p:0/" + parent.guid }
        let environment = try World.environment(fixture)
        let read = try CLI.run(["read", "chat:\(chat)", "--limit", "1", "--json"], environment: environment)
        #expect(read.status == 0)
        let messages = try #require(try read.dataObject["messages"] as? [[String: Any]])
        let message = try #require(messages.first)
        #expect(message["ref"] as? String == "m:\(reply.rowID)")
        #expect(message["reply_to"] as? String == parent.guid)
        #expect(message["reply_to_ref"] as? String == "m:\(parent.rowID)")
        let preview = try #require(message["reply_to_preview"] as? [String: Any])
        #expect(preview["text"] as? String == "Dinner at seven?")
        #expect(preview["truncated"] as? Bool == false)
        let search = try CLI.run(["search", "Yes!", "--json"], environment: environment)
        #expect(((try search.dataArray.first?["message"] as? [String: Any])?["reply_to_preview"] as? [String: Any])?["text"] as? String == "Dinner at seven?")
        let chats = try CLI.run(["chats", "--json"], environment: environment)
        let latest = try chats.dataArray.first?["last_message"] as? [String: Any]
        #expect((latest?["reply_to_preview"] as? [String: Any])?["text"] as? String == "Dinner at seven?")
        let human = try CLI.run(["read", "chat:\(chat)", "--limit", "1"], environment: environment)
        #expect(human.stdout.contains("Dinner at seven?"))
        // The thread's current service and each message's actual service are distinct.
        let conversation = try #require(try read.dataObject["conversation"] as? [String: Any])
        #expect(conversation["current_services"] as? [String] == ["rcs"])
        #expect(conversation["message_services"] as? [String] == ["imessage"])
        #expect(message["service"] as? String == "imessage")
        #expect(try chats.dataArray.first?["current_service"] as? String == "rcs")
        #expect(human.stdout.contains("Current: RCS") && human.stdout.contains("Shown: iMessage"))
        try JSONShape.expect(read.json, matches: "read-reply-context")
    }

    @Test func hiddenTextInAParentPreviewIsFlagged() throws {
        let fixture = try MessagesFixture()
        let chat = try fixture.addChat("iMessage;-;+14155550142")
        let text = "Dinner?" + HiddenTextOutputTests.tags("hidden words")
        let parent = try fixture.addMessage(text, in: chat, from: .me, at: .minute(1))
        try fixture.addMessage("Yes!", in: chat, from: .me, at: .minute(2)) { $0.threadOriginatorGUID = "p:0/" + parent.guid }
        let result = try CLI.run(["search", "Yes!", "--json"], environment: World.environment(fixture))
        #expect(try result.warningCodes == ["hidden_text"])
        let message = try #require(try result.dataArray.first?["message"] as? [String: Any])
        let preview = try #require(message["reply_to_preview"] as? [String: Any])
        #expect((preview["hidden_text"] as? [String: Any])?["decoded"] as? String == "hidden words")
    }
}
