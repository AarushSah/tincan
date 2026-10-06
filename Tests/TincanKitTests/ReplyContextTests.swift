import Foundation
import Testing

@testable import TincanKit

@Suite("Reply references and parent previews")
struct ReplyContextTests {
    let fixture: MessagesFixture
    let chat: Int64
    let parent: MessagesFixture.Row

    init() throws {
        fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        chat = try fixture.addChat("iMessage;-;+14155550142", participants: [maya])
        parent = try fixture.addMessage("Dinner at seven?", in: chat, from: .handle(maya), at: .minute(1))
    }

    @Test(arguments: ["", "p:1/", "bp:"])
    func threadReferenceFormsResolveAReadableParent(prefix: String) throws {
        let reply = try fixture.addMessage("Yes!", in: chat, from: .me, at: .minute(2)) { $0.threadOriginatorGUID = prefix + parent.guid }
        let database = try fixture.open()
        let message = try #require(try database.message(id: reply.rowID))
        #expect(message.replyToGUID == parent.guid)
        #expect(message.replyToID == parent.rowID)
        #expect(message.replyToPreview?.text == "Dinner at seven?")
        #expect(message.replyToPreview?.truncated == false)
        #expect(try database.search("Yes!", limit: 10).first?.replyToPreview?.text == "Dinner at seven?")
    }

    @Test func threadMetadataWinsOverTheSequencingReference() throws {
        let middle = try fixture.addMessage("How about eight?", in: chat, from: .me, at: .minute(2))
        let reply = try fixture.addMessage("Agreed", in: chat, from: .me, at: .minute(3)) {
            $0.threadOriginatorGUID = parent.guid
            $0.replyToGUID = middle.guid
        }
        let message = try #require(try fixture.open().message(id: reply.rowID))
        #expect(message.replyToGUID == parent.guid)
        #expect(message.replyToPreview?.text == "Dinner at seven?")
    }

    @Test(arguments: [0, 2, 3, 100])
    func sequencingAndAssociationReferencesAloneAreNotInlineReplies(associatedType: Int) throws {
        let row = try fixture.addMessage("Another message", in: chat, from: .me, at: .minute(2)) {
            $0.replyToGUID = parent.guid
            $0.associatedGUID = parent.guid
            $0.associatedType = associatedType
        }
        let message = try #require(try fixture.open().message(id: row.rowID))
        #expect(message.replyToGUID == nil)
        #expect(message.replyToID == nil)
        #expect(message.replyToPreview == nil)
    }

    @Test func missingThreadParentsDoNotQuoteTheSequencingReference() throws {
        let reply = try fixture.addMessage("Agreed", in: chat, from: .me, at: .minute(3)) {
            $0.threadOriginatorGUID = "missing-parent"
            $0.replyToGUID = parent.guid
        }
        let message = try #require(try fixture.open().message(id: reply.rowID))
        #expect(message.replyToGUID == "missing-parent")
        #expect(message.replyToID == nil)
        #expect(message.replyToPreview == nil)
    }

    @Test func excludedAndDeletedParentsHaveNoReferenceOrPreview() throws {
        let other = try fixture.addChat("iMessage;-;+14155550143")
        let reply = try fixture.addMessage("Agreed", in: other, from: .me, at: .minute(3)) { $0.threadOriginatorGUID = parent.guid }
        let excluded = try #require(try fixture.open(excluding: [chat]).message(id: reply.rowID))
        #expect(excluded.replyToGUID == parent.guid)
        #expect(excluded.replyToID == nil)
        #expect(excluded.replyToPreview == nil)
        try fixture.moveToRecentlyDeleted(parent, from: chat, at: .minute(4))
        let deleted = try #require(try fixture.open().message(id: reply.rowID))
        #expect(deleted.replyToGUID == parent.guid)
        #expect(deleted.replyToID == nil)
        #expect(deleted.replyToPreview == nil)
    }

    @Test func longPreviewsAreBoundedAndCyclesDoNotRecurse() throws {
        let long = try fixture.addMessage(String(repeating: "🍜", count: 170), in: chat, from: .me, at: .minute(2)) {
            $0.threadOriginatorGUID = $0.guid
        }
        let message = try #require(try fixture.open().message(id: long.rowID))
        #expect(message.replyToID == long.rowID)
        #expect(message.replyToPreview?.text == String(repeating: "🍜", count: 160))
        #expect(message.replyToPreview?.truncated == true)
    }

    @Test func reactionsStayFoldedOntoTheirTarget() throws {
        let reaction = try fixture.addReaction(.love, to: parent, in: chat, from: .me, at: .minute(2))
        let database = try fixture.open()
        #expect(try database.message(id: reaction.rowID) == nil)
        let message = try #require(try database.message(id: parent.rowID))
        #expect(message.replyToGUID == nil)
        #expect(message.replyToPreview == nil)
        #expect(message.reactions.map(\.kind) == [.love])
    }
}
