import Foundation
import Testing

@testable import TincanKit

/// A one-to-one chat with Maya holding `count` messages, one a minute, alternating between
/// her and you: "Message 1" at minute 1 through "Message N" at minute N.
private func conversation(count: Int) throws -> (fixture: MessagesFixture, chat: Int64, rows: [MessagesFixture.Row]) {
    let fixture = try MessagesFixture()
    let maya = try fixture.addHandle("+14155550142")
    let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
    var rows: [MessagesFixture.Row] = []
    for index in 1...count {
        rows.append(try fixture.addMessage("Message \(index)", in: chat, from: index.isMultiple(of: 2) ? .meTo(maya) : .handle(maya), at: .minute(index)))
    }
    return (fixture, chat, rows)
}

@Suite("Message history")
struct MessageHistoryTests {
    @Test func returnsTheNewestMessagesOldestFirst() throws {
        let (fixture, chat, rows) = try conversation(count: 7)
        let page = try fixture.open().messages(inChats: [chat], limit: 3)
        #expect(page.map(\.text) == ["Message 5", "Message 6", "Message 7"])
        #expect(page.map(\.id) == rows.suffix(3).map(\.rowID))
        #expect(page.map(\.date) == [.minute(5), .minute(6), .minute(7)])
        #expect(page.allSatisfy { $0.chatID == chat })
    }

    @Test func pagesBackwardWithBefore() throws {
        let (fixture, chat, _) = try conversation(count: 7)
        let database = try fixture.open()
        let newest = try database.messages(inChats: [chat], limit: 3)
        let older = try database.messages(inChats: [chat], before: try #require(newest.first).date, limit: 3)
        let oldest = try database.messages(inChats: [chat], before: try #require(older.first).date, limit: 3)
        #expect(older.map(\.text) == ["Message 2", "Message 3", "Message 4"])
        #expect(oldest.map(\.text) == ["Message 1"])
        #expect(try database.messages(inChats: [chat], before: .minute(1), limit: 3).isEmpty)
    }

    @Test func afterKeepsOnlyLaterMessages() throws {
        let (fixture, chat, _) = try conversation(count: 7)
        let database = try fixture.open()
        #expect(try database.messages(inChats: [chat], after: .minute(4)).map(\.text) == ["Message 5", "Message 6", "Message 7"])
        // With both bounds and a limit, the newest matching messages win.
        let window = try database.messages(inChats: [chat], before: .minute(7), after: .minute(1), limit: 2)
        #expect(window.map(\.text) == ["Message 5", "Message 6"])
    }

    @Test func boundsAreExclusive() throws {
        let (fixture, chat, _) = try conversation(count: 3)
        let page = try fixture.open().messages(inChats: [chat], before: .minute(3), after: .minute(1))
        #expect(page.map(\.text) == ["Message 2"])
    }

    @Test func severalChatsAreMergedByDate() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        let withMaya = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let withSam = try fixture.addChat("any;-;+14155550143", participants: [sam])
        try fixture.addMessage("maya 1", in: withMaya, from: .handle(maya), at: .minute(1))
        try fixture.addMessage("sam 2", in: withSam, from: .handle(sam), at: .minute(2))
        try fixture.addMessage("maya 3", in: withMaya, from: .handle(maya), at: .minute(3))
        let merged = try fixture.open().messages(inChats: [withMaya, withSam])
        #expect(merged.map(\.text) == ["maya 1", "sam 2", "maya 3"])
        #expect(merged.map(\.chatID) == [withMaya, withSam, withMaya])
    }

    @Test func pagingFromAMessageVisitsEveryMessageOnceEvenWhenTimestampsTie() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        let withMaya = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let withSam = try fixture.addChat("any;-;+14155550143", participants: [sam])
        var expected: [Int64] = []
        for index in 1...7 {
            // Three messages share minute 2 and two share minute 3, split across chats.
            let minute = [1, 2, 2, 2, 3, 3, 4][index - 1]
            let chat = index.isMultiple(of: 2) ? withSam : withMaya
            expected.append(try fixture.addMessage("m\(index)", in: chat, from: .me, at: .minute(minute)).rowID)
        }
        let database = try fixture.open()
        var seen: [Int64] = []
        var page = try database.messages(inChats: [withMaya, withSam], limit: 2)
        while let oldest = page.first {
            seen = page.map(\.id) + seen
            page = try database.messages(inChats: [withMaya, withSam], beforeMessage: oldest.id, limit: 2)
        }
        #expect(seen == expected)
    }

    @Test func afterAMessageReturnsTheOldestFirst() throws {
        let (fixture, chat, rows) = try conversation(count: 7)
        let page = try fixture.open().messages(inChats: [chat], afterMessage: rows[1].rowID, limit: 3)
        #expect(page.map(\.text) == ["Message 3", "Message 4", "Message 5"])
        #expect(try fixture.open().messages(inChats: [chat], afterMessage: rows[6].rowID, limit: 3).isEmpty)
        #expect(try fixture.open().messages(inChats: [chat], afterMessage: 999, limit: 3).isEmpty)
    }

    @Test func pagingForwardFromAMessageVisitsEveryMessageOnceEvenWhenTimestampsTie() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        let withMaya = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let withSam = try fixture.addChat("any;-;+14155550143", participants: [sam])
        var expected: [Int64] = []
        for index in 1...7 {
            // Three messages share minute 2 and two share minute 3, split across chats.
            let minute = [1, 2, 2, 2, 3, 3, 4][index - 1]
            let chat = index.isMultiple(of: 2) ? withSam : withMaya
            expected.append(try fixture.addMessage("m\(index)", in: chat, from: .me, at: .minute(minute)).rowID)
        }
        let database = try fixture.open()
        var seen = [expected[0]]
        var page = try database.messages(inChats: [withMaya, withSam], afterMessage: expected[0], limit: 2)
        while let newest = page.last {
            seen += page.map(\.id)
            page = try database.messages(inChats: [withMaya, withSam], afterMessage: newest.id, limit: 2)
        }
        #expect(seen == expected)
    }

    @Test func aZeroLimitOrNoChatsReturnsNothing() throws {
        let (fixture, chat, _) = try conversation(count: 2)
        let database = try fixture.open()
        #expect(try database.messages(inChats: [chat], limit: 0).isEmpty)
        #expect(try database.messages(inChats: []).isEmpty)
    }
}

@Suite("Message cursor")
struct MessageCursorTests {
    /// Two chats with interleaved messages, reactions between them, and one message that
    /// belongs to no chat. Returns the ids a cursor must visit, in order.
    private func busyDatabase() throws -> (fixture: MessagesFixture, expected: [Int64]) {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        let withMaya = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let withSam = try fixture.addChat("any;-;+14155550143", participants: [sam])
        var expected: [Int64] = []
        for minute in 1...10 {
            let chat = minute.isMultiple(of: 2) ? withSam : withMaya
            let handle = minute.isMultiple(of: 2) ? sam : maya
            let row = try fixture.addMessage("m\(minute)", in: chat, from: minute.isMultiple(of: 3) ? .me : .handle(handle), at: .minute(minute))
            expected.append(row.rowID)
            if minute.isMultiple(of: 4) {
                try fixture.addReaction(.like, to: row, in: chat, from: .me, at: .minute(minute))
            }
        }
        expected.append(try fixture.addMessage("no chat", in: nil, from: .handle(maya), at: .minute(11)).rowID)
        return (fixture, expected)
    }

    @Test func pagingByRowIDVisitsEveryMessageOnce() throws {
        let (fixture, expected) = try busyDatabase()
        let database = try fixture.open()
        var cursor: Int64 = 0
        var seen: [Int64] = []
        while true {
            let page = try database.messages(afterRowID: cursor, limit: 3)
            guard let last = page.last else { break }
            seen += page.map(\.id)
            cursor = last.id
        }
        #expect(seen == expected)
    }

    @Test func theCeilingStopsTheCursor() throws {
        let (fixture, expected) = try busyDatabase()
        let ceiling = expected[4]
        let page = try fixture.open().messages(afterRowID: expected[1], through: ceiling, limit: 100)
        #expect(page.map(\.id) == Array(expected[2...4]))
    }

    @Test func yourOwnMessagesCanBeSkipped() throws {
        let (fixture, _) = try busyDatabase()
        let page = try fixture.open().messages(afterRowID: 0, limit: 100, includeFromMe: false)
        #expect(!page.isEmpty)
        #expect(page.allSatisfy { !$0.isFromMe })
        #expect(!page.map(\.text).contains("m3"))
    }

    @Test func rowIDsForStartingACursor() throws {
        let (fixture, expected) = try busyDatabase()
        let database = try fixture.open()
        #expect(try database.rowID(before: .minute(2)) == expected[1])
        #expect(try database.rowID(before: .minute(0)) == 0)
        #expect(try database.latestRowID() == expected.last)
    }

    @Test func aCursorFromATimeSkipsNothingThatArrivedOutOfOrder() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        try fixture.addMessage("before", in: chat, from: .handle(maya), at: .minute(1))
        try fixture.addMessage("after", in: chat, from: .handle(maya), at: .minute(5))
        // Stamped at minute 2 by the sender's phone, written after "after" (delivered late,
        // or synced from iCloud).
        try fixture.addMessage("late", in: chat, from: .handle(maya), at: .minute(2))
        let database = try fixture.open()
        let page = try database.messages(afterRowID: try database.rowID(before: .minute(3)), limit: 10)
        #expect(page.map(\.text).contains("after"))
        #expect(!page.map(\.text).contains("before"))
        #expect(try database.rowID(before: .minute(9)) == database.latestRowID())
    }

    @Test func reactionRowsReportAdditionsAndRemovalsAfterTheCursor() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let hello = try fixture.addMessage("Hello", in: chat, from: .me, at: .minute(1))
        let cursor = hello.rowID
        try fixture.addReaction(.love, to: hello, in: chat, from: .handle(maya), at: .minute(2), part: 1)
        try fixture.removeReaction(.love, from: hello, in: chat, by: .handle(maya), at: .minute(3), part: 1)

        let rows = try fixture.open().reactionRows(afterRowID: cursor, limit: 10)
        #expect(rows.map(\.targetGUID) == [hello.guid, hello.guid])
        #expect(rows.map(\.removed) == [false, true])
        #expect(rows.map(\.reaction.kind) == [.love, .love])
        #expect(rows.map(\.reaction.from) == ["+14155550142", "+14155550142"])
        #expect(rows.map(\.reaction.part) == [1, 1])
        #expect(rows.map(\.chatID) == [chat, chat])
    }
}
