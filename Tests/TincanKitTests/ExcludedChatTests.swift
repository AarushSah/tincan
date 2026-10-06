import Foundation
import Testing

@testable import TincanKit

/// People can exclude conversations from tincan. Excluded chats may be listed by id, but no
/// query may return their messages, reactions or timing.
@Suite("Excluded chats")
struct ExcludedChatTests {
    let fixture: MessagesFixture
    /// The person in the allowed chat.
    let maya: Int64
    /// The person in the excluded chat.
    let doctor: Int64
    /// A chat tincan may read.
    let allowed: Int64
    /// A chat the person excluded. Every message in it contains "secret".
    let excluded: Int64
    let excludedIncoming: MessagesFixture.Row
    let excludedOutgoing: MessagesFixture.Row

    init() throws {
        fixture = try MessagesFixture()
        maya = try fixture.addHandle("+14155550142")
        doctor = try fixture.addHandle("+14155550177")
        allowed = try fixture.addChat("any;-;+14155550142", participants: [maya])
        excluded = try fixture.addChat("any;-;+14155550177", participants: [doctor])

        try fixture.addMessage("Not a secret: lunch at noon", in: allowed, from: .handle(maya), at: .minute(1)) { $0.isRead = false }
        excludedIncoming = try fixture.addMessage("The secret results", in: excluded, from: .handle(doctor), at: .minute(2)) { $0.isRead = false }
        excludedOutgoing = try fixture.addMessage("Thanks, keep it secret", in: excluded, from: .meTo(doctor), at: .minute(3))
        try fixture.addReaction(.love, to: excludedIncoming, in: excluded, from: .me, at: .minute(4))
        try fixture.addMessage("See you at lunch", in: allowed, from: .meTo(maya), at: .minute(5))
    }

    private func open() throws -> MessagesDatabase {
        try fixture.open(excluding: [excluded])
    }

    @Test func conversationHistorySkipsExcludedChats() throws {
        let database = try open()
        #expect(try database.messages(inChats: [excluded]).isEmpty)
        #expect(try database.messages(inChats: [allowed, excluded]).allSatisfy { $0.chatID == allowed })
    }

    @Test func theCursorSkipsExcludedChats() throws {
        let page = try open().messages(afterRowID: 0, limit: 100)
        #expect(page.count == 2)
        #expect(page.allSatisfy { $0.chatID == allowed })
    }

    /// Messages can lack a conversation, as rows left behind by older macOS releases do. No
    /// conversation can exclude them, so the person they are from or to does.
    @Test func messagesInNoConversationFollowTheirPersonsExclusion() throws {
        try fixture.addMessage("An orphaned secret", in: nil, from: .handle(doctor), at: .minute(6))
        try fixture.addMessage("Another orphaned secret", in: nil, from: .meTo(doctor), at: .minute(7))
        try fixture.addMessage("From nobody we can tell", in: nil, from: .handle(0), at: .minute(8))
        let mine = try fixture.addMessage("An orphan from Maya", in: nil, from: .handle(maya), at: .minute(9)).rowID
        let page = try open().messages(afterRowID: 0, limit: 100)
        #expect(!page.contains { $0.text.contains("orphaned") })
        #expect(!page.contains { $0.text.contains("nobody") })
        #expect(page.contains { $0.id == mine })
        let found = try open().search("orphan", limit: 10)
        #expect(!found.contains { $0.text.contains("orphaned") }, "\(found.map(\.text))")
        // An excluded address excludes them too, before any conversation with it exists.
        let byAddress = try MessagesDatabase(path: fixture.path, excluding: ["address:+14155550177"], region: "US")
        #expect(!(try byAddress.messages(afterRowID: 0, limit: 100)).contains { $0.text.contains("orphaned") })
        // With nothing excluded, every message is readable.
        #expect(try fixture.open().messages(afterRowID: 0, limit: 100).contains { $0.text.contains("nobody") })
    }

    @Test func reactionRowsSkipExcludedChats() throws {
        #expect(try open().reactionRows(afterRowID: 0, limit: 100).isEmpty)
    }

    @Test func searchSkipsExcludedChats() throws {
        let database = try open()
        #expect(try database.search("secret", limit: 10).map(\.chatID) == [allowed])
        #expect(try database.search("secret", inChats: [excluded], limit: 10).isEmpty)
    }

    @Test func unreadMessagesSkipExcludedChats() throws {
        #expect(try open().unreadMessages(limit: 10).map(\.chatID) == [allowed])
    }

    @Test func loadingByIDOrGUIDSkipsExcludedChats() throws {
        let database = try open()
        #expect(try database.message(id: excludedIncoming.rowID) == nil)
        #expect(try database.messages(guids: [excludedIncoming.guid, excludedOutgoing.guid]).isEmpty)
        #expect(try database.message(guid: excludedIncoming.guid) == nil)
        let reaction = try #require(try database.database.scalarInteger("SELECT ROWID FROM message WHERE associated_message_type = 2000"))
        #expect(try database.reactionTarget(id: reaction) == nil)
    }

    @Test func rowIDsByGUIDSkipExcludedChats() throws {
        let allowedRow = try #require(try open().messages(inChats: [allowed]).first)
        let ids = try open().rowIDs(guids: [allowedRow.guid, excludedIncoming.guid, excludedOutgoing.guid, "unknown"])
        #expect(ids == [allowedRow.guid: allowedRow.id])
        #expect(try fixture.open().rowIDs(guids: [excludedIncoming.guid]) == [excludedIncoming.guid: excludedIncoming.rowID])
    }

    @Test func replyTimingSkipsExcludedChats() throws {
        #expect(try open().firstOutgoingDate(inChat: excluded, after: .minute(0)) == nil)
        #expect(try fixture.open().firstOutgoingDate(inChat: excluded, after: .minute(0)) == .minute(3))
    }

    @Test func sendConfirmationSkipsExcludedChats() throws {
        let database = try open()
        #expect(try database.latestOutgoing(inChat: nil, after: .minute(0)).map(\.text) == ["See you at lunch"])
        #expect(try database.latestOutgoing(inChat: excluded, after: .minute(0)).isEmpty)
    }

    @Test func summariesListExcludedChatsWithoutTheirMessages() throws {
        let summaries = try open().chatSummaries(limit: nil)
        let summary = try #require(summaries.first { $0.chat.id == excluded })
        #expect(summary.lastMessage == nil)
        #expect(summaries.first { $0.chat.id == allowed }?.lastMessage?.text == "See you at lunch")
    }

    @Test func aMessageFiledInAnExcludedChatStaysExcludedWhenAlsoFiledElsewhere() throws {
        let incoming = try fixture.addMessage("secret, filed twice", in: allowed, from: .handle(maya), at: .minute(6)) { $0.isRead = false }
        let outgoing = try fixture.addMessage("my secret, filed twice", in: allowed, from: .meTo(maya), at: .minute(7))
        for row in [incoming, outgoing] {
            try fixture.database.insert(
                into: "chat_message_join",
                [
                    "chat_id": .integer(excluded), "message_id": .integer(row.rowID), "message_date": .integer(MessagesFixture.nanoseconds(.minute(6))),
                ])
        }
        let database = try open()
        let ids: Set<Int64> = [incoming.rowID, outgoing.rowID]
        #expect(try database.messages(afterRowID: 0, limit: 100).allSatisfy { !ids.contains($0.id) })
        #expect(try database.messages(inChats: [allowed]).allSatisfy { !ids.contains($0.id) })
        #expect(try database.messages(guids: [incoming.guid, outgoing.guid]).isEmpty)
        #expect(try database.message(id: incoming.rowID) == nil)
        #expect(try database.search("filed twice", limit: 10).isEmpty)
        #expect(try database.unreadMessages(limit: 10).allSatisfy { !ids.contains($0.id) })
        #expect(try database.unreadCountByChat() == [allowed: 1])
        #expect(try database.outgoing(inChat: nil, afterRowID: 0).allSatisfy { !ids.contains($0.id) })
        #expect(try database.firstOutgoingDate(inChat: allowed, after: .minute(5)) == nil)
    }

    @Test func pagingFromAnExcludedMessageRevealsNothing() throws {
        // Paging before or after an excluded message would reveal when it was sent.
        #expect(try open().messages(inChats: [allowed], beforeMessage: excludedIncoming.rowID).isEmpty)
        #expect(try open().messages(inChats: [allowed], afterMessage: excludedIncoming.rowID).isEmpty)
        #expect(try open().search("lunch", beforeMessage: excludedOutgoing.rowID, limit: 10).isEmpty)
    }

    @Test func unreadCountsSkipExcludedChats() throws {
        let database = try open()
        #expect(try database.unreadCountByChat() == [allowed: 1])
        #expect(try database.chatSummaries(limit: nil, unreadOnly: true).map(\.chat.id) == [allowed])
        #expect(try database.chatSummaries(limit: nil).first { $0.chat.id == excluded }?.unreadCount == 0)
    }

    @Test func excludedChatsAreListedWithoutTheirTiming() throws {
        let database = try open()
        #expect(try database.lastActivityByChat()[excluded] == nil)
        let summary = try database.chatSummaries(limit: nil).first { $0.chat.id == excluded }
        #expect(summary != nil)
        #expect(summary?.lastActivity == nil)
        #expect(summary?.lastMessage == nil)
    }

    @Test func messageCountsSkipExcludedChats() throws {
        #expect(try open().messageCounts(chatIDs: [allowed, excluded]) == [allowed: 2])
    }

    @Test("Exclusions ignore case and surrounding space", arguments: ["CHAT:", " chat:", "guid"])
    func exclusionReferences(form: String) throws {
        let reference = form == "guid" ? " any;-;+14155550177 " : "\(form)\(excluded) "
        #expect(try MessagesDatabase(path: fixture.path, excluding: [reference]).excludedChatIDs == [excluded])
    }

    @Test("An excluded address covers its one-to-one conversations, however it is written", arguments: ["address:+14155550177", " Address:(415) 555-0177 "])
    func excludedAddresses(entry: String) throws {
        let database = try MessagesDatabase(path: fixture.path, excluding: [entry], region: "US")
        #expect(database.excludedChatIDs == [excluded])
        // A conversation on it that starts later is excluded before it is read; a group is not.
        let doctorSMS = try fixture.addHandle("+14155550177", service: "SMS")
        let later = try fixture.addChat("SMS;-;+14155550177", service: "SMS", participants: [doctorSMS])
        let group = try fixture.addChat("any;+;chat1", style: .group, participants: [doctorSMS, maya])
        try database.refreshExclusions()
        #expect(database.excludedChatIDs == [excluded, later])
        #expect(!database.excludedChatIDs.contains(group))
    }

    @Test func aConversationRecreatedUnderAnExcludedGUIDStaysExcluded() throws {
        let database = try MessagesDatabase(path: fixture.path, excluding: ["any;-;+14155550177"])
        #expect(database.excludedChatIDs == [excluded])
        // Deleting the conversation in Messages and hearing from them again makes a new
        // chat row with the same GUID while `watch` keeps the database open.
        try fixture.database.execute("DELETE FROM chat_message_join WHERE chat_id = \(excluded)")
        try fixture.database.execute("DELETE FROM chat_handle_join WHERE chat_id = \(excluded)")
        try fixture.database.execute("DELETE FROM chat WHERE ROWID = \(excluded)")
        let doctor = try fixture.addHandle("+14155550177", service: "SMS")
        let recreated = try fixture.addChat("any;-;+14155550177", participants: [doctor])
        try fixture.addMessage("New results", in: recreated, from: .handle(doctor), at: .minute(6))
        try database.refreshExclusions()
        #expect(database.excludedChatIDs.contains(recreated))
        #expect(try database.messages(afterRowID: 0, limit: 100).allSatisfy { $0.chatID != recreated })
    }

    @Test func withoutExclusionsEverythingIsReadable() throws {
        let database = try fixture.open()
        #expect(try database.messages(afterRowID: 0, limit: 100).count == 4)
        #expect(try database.message(id: excludedIncoming.rowID)?.text == "The secret results")
    }
}
