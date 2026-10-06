import Foundation
import Testing

@testable import TincanKit

@Suite("Chats and summaries")
struct ChatListTests {
    @Test func chatsCarryTheirKindServiceNameAndParticipants() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("sam.lee@example.com")
        let direct = try fixture.addChat("SMS;-;+14155550142", service: "SMS", participants: [maya], isArchived: true)
        let group = try fixture.addChat("iMessage;+;chat100200300", displayName: "Climbing crew", participants: [maya, sam])
        let chats = try fixture.open().allChats()

        let one = try #require(chats.first { $0.id == direct })
        #expect(one.kind == .direct)
        #expect(one.service == .sms)
        #expect(one.identifier == "+14155550142")
        #expect(one.participants == ["+14155550142"])
        #expect(one.displayName == nil)
        #expect(one.isArchived)
        #expect(one.reference == "chat:\(direct)")

        let many = try #require(chats.first { $0.id == group })
        #expect(many.kind == .group)
        #expect(many.service == .iMessage)
        #expect(many.identifier == "chat100200300")
        #expect(many.displayName == "Climbing crew")
        #expect(many.participants == ["+14155550142", "sam.lee@example.com"])
        #expect(!many.isArchived)
    }

    @Test func anAddressOnSeveralServicesIsListedOnce() throws {
        let fixture = try MessagesFixture()
        let viaIMessage = try fixture.addHandle("+14155550142", service: "iMessage")
        let viaSMS = try fixture.addHandle("+14155550142", service: "SMS")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [viaIMessage, viaSMS])
        #expect(try fixture.open().chat(id: chat)?.participants == ["+14155550142"])
    }

    @Test func chatsCanBeFoundByIDOrGUID() throws {
        let fixture = try MessagesFixture()
        let chat = try fixture.addChat("any;-;+14155550142")
        let database = try fixture.open()
        #expect(try database.chat(id: chat)?.guid == "any;-;+14155550142")
        #expect(try database.chat(guid: "any;-;+14155550142")?.id == chat)
        #expect(try database.chat(id: 999) == nil)
    }

    @Test func theReadReceiptSettingComesFromChatProperties() throws {
        let fixture = try MessagesFixture()
        let on = try fixture.addChat("any;-;+14155550142", properties: ["EnableReadReceiptForChat": true])
        let off = try fixture.addChat("any;-;+14155550143", properties: ["EnableReadReceiptForChat": false])
        let unset = try fixture.addChat("any;-;+14155550144")
        let database = try fixture.open()
        #expect(try database.chat(id: on)?.sendsReadReceipts == true)
        #expect(try database.chat(id: off)?.sendsReadReceipts == false)
        #expect(try database.chat(id: unset)?.sendsReadReceipts == nil)
    }

    @Test func unreadCountsIncludeOnlyUnreadMessagesFromOthers() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        let chat = try fixture.addChat("any;+;chat100200300", participants: [maya, sam])
        let quiet = try fixture.addChat("any;-;+14155550143", participants: [sam])
        let first = try fixture.addMessage("one", in: chat, from: .handle(maya), at: .minute(1)) { $0.isRead = false }
        try fixture.addMessage("two", in: chat, from: .handle(sam), at: .minute(2)) { $0.isRead = false }
        try fixture.addMessage("read", in: chat, from: .handle(sam), at: .minute(3))
        // None of these count:
        try fixture.addMessage("mine", in: chat, from: .me, at: .minute(4)) { $0.isRead = false }
        try fixture.addReaction(.love, to: first, in: chat, from: .handle(sam), at: .minute(5))
        try fixture.addMessage(nil, in: chat, from: .handle(sam), at: .minute(6)) {
            $0.itemType = 2
            $0.groupTitle = "Renamed"
            $0.isRead = false
        }
        try fixture.addMessage("still arriving", in: chat, from: .handle(maya), at: .minute(7)) {
            $0.isRead = false
            $0.isFinished = false
        }
        try fixture.addMessage("read", in: quiet, from: .handle(sam), at: .minute(8))

        let counts = try fixture.open().unreadCountByChat()
        #expect(counts[chat] == 2)
        #expect(counts[quiet] == nil)
    }

    /// Three chats: `old` (minute 1), `recent` (minute 5, one unread) and `filtered`
    /// (minute 9, from an unknown sender that Messages filtered).
    private func threeChats() throws -> (fixture: MessagesFixture, old: Int64, recent: Int64, filtered: Int64) {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        let stranger = try fixture.addHandle("+14155550199")
        let old = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let recent = try fixture.addChat("any;-;+14155550143", participants: [sam])
        let filtered = try fixture.addChat("any;-;+14155550199", participants: [stranger], isFiltered: true)
        try fixture.addChat("any;-;+14155550100") // no messages
        try fixture.addMessage("old news", in: old, from: .handle(maya), at: .minute(1))
        try fixture.addMessage("hello", in: recent, from: .me, at: .minute(4))
        try fixture.addMessage("hi back", in: recent, from: .handle(sam), at: .minute(5)) { $0.isRead = false }
        try fixture.addMessage("Your code is 123456", in: filtered, from: .handle(stranger), at: .minute(9)) { $0.isRead = false }
        return (fixture, old, recent, filtered)
    }

    @Test func summariesAreOrderedByLatestActivity() throws {
        let (fixture, old, recent, _) = try threeChats()
        let summaries = try fixture.open().chatSummaries(limit: nil)
        #expect(summaries.map(\.chat.id) == [recent, old])
        let top = try #require(summaries.first)
        #expect(top.lastMessage?.text == "hi back")
        #expect(top.lastActivity == .minute(5))
        #expect(top.unreadCount == 1)
    }

    @Test func filteredChatsAreHiddenUnlessRequested() throws {
        let (fixture, old, recent, filtered) = try threeChats()
        let database = try fixture.open()
        #expect(try database.chatSummaries(limit: nil, includeFiltered: true).map(\.chat.id) == [filtered, recent, old])
        #expect(try database.chatSummaries(limit: nil, chatIDs: [filtered]).map(\.chat.id) == [filtered])
    }

    @Test func readersSkipConversationsBeforeCountingTheLimit() throws {
        let (fixture, _, recent, filtered) = try threeChats()
        let database = try fixture.open()
        #expect(try database.unreadMessages(limit: 1).map(\.chatID) == [filtered])
        #expect(try database.unreadMessages(limit: 1, skipping: [filtered]).map(\.chatID) == [recent])
        #expect(try database.messages(afterRowID: 0, limit: 10, skipping: [filtered]).map(\.text) == ["old news", "hello", "hi back"])
        #expect(try database.search("code", limit: 5).map(\.chatID) == [filtered])
        #expect(try database.search("code", skipping: [filtered], limit: 5).isEmpty)
    }

    @Test func summariesHonorTheLimitAndUnreadFilter() throws {
        let (fixture, _, recent, _) = try threeChats()
        let database = try fixture.open()
        #expect(try database.chatSummaries(limit: 1).map(\.chat.id) == [recent])
        #expect(try database.chatSummaries(limit: nil, unreadOnly: true).map(\.chat.id) == [recent])
    }

    @Test func chatsWithoutMessagesAreListedOnlyWhenAskedFor() throws {
        let (fixture, _, _, _) = try threeChats()
        let database = try fixture.open()
        let empty = try #require(try database.allChats().first { $0.identifier == "+14155550100" })
        #expect(try !database.chatSummaries(limit: nil, includeFiltered: true).contains { $0.chat.id == empty.id })
        let asked = try database.chatSummaries(limit: nil, chatIDs: [empty.id])
        #expect(asked.map(\.chat.id) == [empty.id])
        #expect(asked.first?.lastMessage == nil)
        #expect(asked.first?.lastActivity == nil)
    }

    @Test func aReactionCountsAsActivityButIsNotTheLastMessage() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let hello = try fixture.addMessage("Hello", in: chat, from: .me, at: .minute(1))
        try fixture.addReaction(.like, to: hello, in: chat, from: .handle(maya), at: .minute(7))
        let database = try fixture.open()
        let summary = try #require(try database.chatSummaries(limit: nil).first)
        #expect(summary.lastActivity == .minute(7))
        #expect(summary.lastMessage?.guid == hello.guid)
        #expect(summary.lastMessage?.reactions.map(\.kind) == [.like])
    }

    @Test func messageCountsSkipReactionsAndGroupEvents() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;+;chat100200300", participants: [maya])
        let hello = try fixture.addMessage("Hello", in: chat, from: .me, at: .minute(1))
        try fixture.addMessage("Hi", in: chat, from: .handle(maya), at: .minute(2))
        try fixture.addReaction(.like, to: hello, in: chat, from: .handle(maya), at: .minute(3))
        try fixture.addMessage(nil, in: chat, from: .handle(maya), at: .minute(4)) {
            $0.itemType = 2
            $0.groupTitle = "Renamed"
        }
        #expect(try fixture.open().messageCounts(chatIDs: [chat]) == [chat: 2])
    }
}
