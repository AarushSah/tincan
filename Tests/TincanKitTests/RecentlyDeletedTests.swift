import Foundation
import Testing

@testable import TincanKit

/// Deleting a message in Messages moves it to Recently Deleted: its link to the conversation
/// moves from `chat_message_join` to `chat_recoverable_message_join`. The person deleted it,
/// so no query may return it, reactions to it or its timing, and a message deleted from an
/// excluded conversation must never come back without a conversation to exclude it by.
@Suite("Recently deleted messages")
struct RecentlyDeletedTests {
    let fixture: MessagesFixture
    /// A chat tincan may read.
    let allowed: Int64
    /// A chat the person excluded.
    let excluded: Int64
    /// Every deleted message contains "secret"; nothing else does.
    let deletedIncoming: MessagesFixture.Row
    let deletedOutgoing: MessagesFixture.Row
    let deletedFromExcluded: MessagesFixture.Row
    /// In Recently Deleted and still filed in the allowed chat, as in a database caught
    /// halfway through the move. It is the allowed chat's newest message.
    let halfMoved: MessagesFixture.Row
    let lunch: MessagesFixture.Row
    /// Your reply to `deletedIncoming`.
    let reply: MessagesFixture.Row
    let latest: MessagesFixture.Row

    init() throws {
        fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let doctor = try fixture.addHandle("+14155550177")
        allowed = try fixture.addChat("any;-;+14155550142", participants: [maya])
        excluded = try fixture.addChat("any;-;+14155550177", participants: [doctor])

        lunch = try fixture.addMessage("lunch at noon", in: allowed, from: .handle(maya), at: .minute(1))
        let doorCode = try fixture.addMessage("the secret door code", in: allowed, from: .handle(maya), at: .minute(2)) { $0.isRead = false }
        deletedIncoming = doorCode
        deletedOutgoing = try fixture.addMessage("my secret answer", in: allowed, from: .meTo(maya), at: .minute(3))
        deletedFromExcluded = try fixture.addMessage("the secret results", in: excluded, from: .handle(doctor), at: .minute(4)) { $0.isRead = false }
        reply = try fixture.addMessage("got it", in: allowed, from: .meTo(maya), at: .minute(5)) { $0.threadOriginatorGUID = doorCode.guid }
        try fixture.addReaction(.love, to: deletedIncoming, in: allowed, from: .handle(maya), at: .minute(6))
        try fixture.addReaction(.like, to: deletedOutgoing, in: allowed, from: .handle(maya), at: .minute(6), balloon: true)
        try fixture.addReaction(.laugh, to: lunch, in: allowed, from: .me, at: .minute(6))
        latest = try fixture.addMessage("see you there", in: allowed, from: .handle(maya), at: .minute(7)) { $0.isRead = false }
        halfMoved = try fixture.addMessage("a secret, half moved", in: allowed, from: .handle(maya), at: .minute(8)) { $0.isRead = false }

        try fixture.moveToRecentlyDeleted(deletedIncoming, from: allowed, at: .minute(9))
        try fixture.moveToRecentlyDeleted(deletedOutgoing, from: allowed, at: .minute(9))
        try fixture.moveToRecentlyDeleted(deletedFromExcluded, from: excluded, at: .minute(9))
        try fixture.moveToRecentlyDeleted(halfMoved, from: allowed, at: .minute(9), keepFiled: true)
    }

    private var deleted: [MessagesFixture.Row] { [deletedIncoming, deletedOutgoing, deletedFromExcluded, halfMoved] }
    private var deletedIDs: Set<Int64> { Set(deleted.map(\.rowID)) }

    /// The database with the excluded chat excluded, and with no exclusions at all: deleted
    /// messages stay out either way.
    private func databases() throws -> [MessagesDatabase] {
        [try fixture.open(excluding: [excluded]), try fixture.open()]
    }

    @Test func theFixtureMovesMessagesTheWayMessagesDoes() throws {
        // Without the Recently Deleted check, this row comes back with no conversation at all.
        let database = try fixture.open().database
        let filed = try database.scalarInteger("SELECT COUNT(*) FROM chat_message_join WHERE message_id = ?", [.integer(deletedFromExcluded.rowID)])
        #expect(filed == 0)
        let recoverable = try database.scalarInteger(
            "SELECT chat_id FROM chat_recoverable_message_join WHERE message_id = ?", [.integer(deletedFromExcluded.rowID)])
        #expect(recoverable == excluded)
    }

    @Test func theCursorSkipsDeletedMessages() throws {
        for database in try databases() {
            let page = try database.messages(afterRowID: 0, limit: 100)
            #expect(page.map(\.text) == ["lunch at noon", "got it", "see you there"])
            #expect(page.allSatisfy { $0.chatID == allowed })
            #expect(try database.messages(afterRowID: 0, limit: 100, includeFromMe: false).allSatisfy { !deletedIDs.contains($0.id) })
        }
    }

    @Test func historySkipsDeletedMessages() throws {
        for database in try databases() {
            #expect(try database.messages(inChats: [allowed]).map(\.text) == ["lunch at noon", "got it", "see you there"])
            #expect(try database.messages(inChats: [excluded]).isEmpty)
            let summary = try #require(try database.chatSummaries(limit: nil).first { $0.chat.id == allowed })
            #expect(summary.lastMessage?.id == latest.rowID)
            #expect(summary.unreadCount == 1)
        }
    }

    @Test func pagingFromADeletedMessageRevealsNothing() throws {
        for database in try databases() {
            for row in deleted {
                #expect(try database.messages(inChats: [allowed], beforeMessage: row.rowID).isEmpty)
                #expect(try database.messages(inChats: [allowed], afterMessage: row.rowID).isEmpty)
                #expect(try database.search("lunch", beforeMessage: row.rowID, limit: 10).isEmpty)
            }
        }
    }

    @Test func searchSkipsDeletedMessages() throws {
        for database in try databases() {
            #expect(try database.search("secret", limit: 10).isEmpty)
            #expect(try database.search("secret", inChats: [allowed], limit: 10).isEmpty)
            #expect(try database.search("e", limit: 100).allSatisfy { !deletedIDs.contains($0.id) })
        }
    }

    @Test func unreadMessagesAndCountsSkipDeletedMessages() throws {
        for database in try databases() {
            #expect(try database.unreadMessages(limit: 10).map(\.id) == [latest.rowID])
            #expect(try database.unreadCountByChat() == [allowed: 1])
            #expect(try database.messageCounts(chatIDs: [allowed]) == [allowed: 3])
        }
    }

    @Test func loadingByIDOrGUIDSkipsDeletedMessages() throws {
        for database in try databases() {
            for row in deleted { #expect(try database.message(id: row.rowID) == nil) }
            #expect(try database.messages(guids: deleted.map(\.guid)).isEmpty)
            // A reply keeps pointing at what it answered, but the quote can't be loaded.
            let answer = try #require(try database.message(id: reply.rowID))
            #expect(answer.replyToGUID == deletedIncoming.guid)
            #expect(try database.messages(guids: [deletedIncoming.guid]).isEmpty)
            #expect(try database.rowIDs(guids: deleted.map(\.guid) + [lunch.guid]) == [lunch.guid: lunch.rowID])
        }
    }

    @Test func reactionsToDeletedMessagesAreLeftOut() throws {
        for database in try databases() {
            let rows = try database.reactionRows(afterRowID: 0, limit: 100)
            #expect(rows.map(\.targetGUID) == [lunch.guid])
            #expect(try database.messages(inChats: [allowed]).first?.reactions.map(\.kind) == [.laugh])
        }
    }

    @Test func sendConfirmationAndReplyTimingSkipDeletedMessages() throws {
        for database in try databases() {
            #expect(try database.latestOutgoing(inChat: nil, after: .minute(0)).map(\.text) == ["got it"])
            #expect(try database.outgoing(inChat: nil, afterRowID: 0).map(\.id) == [reply.rowID])
            #expect(try database.firstOutgoingDate(inChat: allowed, after: .minute(0)) == .minute(5))
        }
    }

    @Test func lastActivityIgnoresDeletedMessages() throws {
        for database in try databases() {
            let activity = try database.lastActivityByChat()
            #expect(activity[allowed] == .minute(7))
            #expect(activity[excluded] == nil)
        }
    }
}
