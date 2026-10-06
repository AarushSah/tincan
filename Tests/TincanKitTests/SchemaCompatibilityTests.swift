import Foundation
import Testing

@testable import TincanKit

/// Apple adds columns to chat.db in most macOS releases. tincan checks for optional columns
/// instead of assuming the newest schema, so an older database still reads.
@Suite("Older database schemas")
struct SchemaCompatibilityTests {
    /// Columns that older macOS releases do not have.
    static let missingColumns: [String: [String]] = [
        "message": [
            "message_summary_info", "date_edited", "date_retracted", "associated_message_emoji",
            "destination_caller_id", "thread_originator_guid", "expressive_send_style_id",
        ],
        "chat": ["is_filtered", "properties"],
        "attachment": ["emoji_image_content_identifier", "emoji_image_short_description", "hide_attachment"],
    ]
    /// Tables that older macOS releases do not have. Recently Deleted arrived in macOS 13.
    static let missingTables = ["chat_recoverable_message_join"]

    let fixture: MessagesFixture
    let chat: Int64
    let hello: MessagesFixture.Row

    init() throws {
        fixture = try MessagesFixture(omitting: Self.missingColumns)
        for table in Self.missingTables { try fixture.database.execute("DROP TABLE \(table)") }
        let maya = try fixture.addHandle("+14155550142")
        chat = try fixture.addChat("iMessage;-;+14155550142", participants: [maya])
        hello = try fixture.addMessage("Hello from an older Mac", in: chat, from: .handle(maya), at: .minute(1)) {
            $0.isRead = false
            $0.dateEdited = .minute(2) // dropped: the column does not exist
        }
        try fixture.addAttachment(to: hello, name: "photo.jpg", mimeType: "image/jpeg")
        try fixture.addReaction(.emoji, to: hello, in: chat, from: .me, at: .minute(3), emoji: "🎉")
        try fixture.addMessage("Reply", in: chat, from: .meTo(maya), at: .minute(4)) {
            $0.account = "P:+14155550100"
            $0.destinationCallerID = "+14155550100"
        }
    }

    @Test func theFixtureReallyLacksTheColumns() throws {
        let database = try fixture.open().database
        for (table, columns) in Self.missingColumns {
            for column in columns { #expect(!database.hasColumn(column, in: table), "\(table).\(column)") }
        }
        for table in Self.missingTables { #expect(!database.hasTable(table), "\(table)") }
        #expect(database.hasColumn("attributedBody", in: "message"))
    }

    @Test func messagesStillLoadWithReactionsAndAttachments() throws {
        let messages = try fixture.open().messages(inChats: [chat])
        #expect(messages.map(\.text) == ["Hello from an older Mac", "Reply"])
        let first = try #require(messages.first)
        #expect(first.sender == "+14155550142")
        #expect(!first.isEdited)
        #expect(!first.isUnsent)
        #expect(first.attachments.map(\.category) == ["image"])
        // Without associated_message_emoji the reaction is still an emoji reaction.
        #expect(first.reactions.map(\.kind) == [.emoji])
        #expect(first.reactions.first?.emoji == nil)
    }

    @Test func chatsSummariesSearchAndCursorsStillWork() throws {
        let database = try fixture.open()
        let chats = try database.allChats()
        #expect(chats.map(\.isFiltered) == [false])
        #expect(chats.first?.sendsReadReceipts == nil)
        #expect(try database.chatSummaries(limit: nil).map(\.unreadCount) == [1])
        #expect(try database.search("older mac", limit: 5).map(\.id) == [hello.rowID])
        #expect(try database.messages(afterRowID: 0, limit: 10).count == 2)
        #expect(try database.reactionRows(afterRowID: 0, limit: 10).count == 1)
        #expect(try database.unreadMessages(limit: 10).map(\.id) == [hello.rowID])
        #expect(try database.message(id: hello.rowID)?.text == "Hello from an older Mac")
        #expect(try database.messages(guids: [hello.guid]).map(\.id) == [hello.rowID])
        #expect(try database.lastActivityByChat()[chat] == .minute(4))
    }

    @Test func ownAddressesFallBackToTheAccountColumn() throws {
        #expect(try fixture.open().ownAddresses() == ["+14155550100"])
    }
}
