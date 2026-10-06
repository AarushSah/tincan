import Foundation
import Testing

@testable import TincanKit

/// Facts about what you sent: your own addresses, when you replied, and whether a send landed.
@Suite("Outgoing messages")
struct OutgoingMessageTests {
    @Test func ownAddressesAreRankedByHowOftenYouSendFromThem() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        for minute in 1...3 {
            try fixture.addMessage("from my phone", in: chat, from: .meTo(maya), at: .minute(minute)) {
                $0.destinationCallerID = "+14155550100"
                $0.account = "P:+14155550100"
            }
        }
        try fixture.addMessage("from my email", in: chat, from: .meTo(maya), at: .minute(4)) {
            $0.destinationCallerID = "me@example.com"
            $0.account = "E:me@example.com"
        }
        // Only the account column says which address sent this one (older rows).
        try fixture.addMessage("old style", in: chat, from: .meTo(maya), at: .minute(5)) {
            $0.account = "e:old@example.com"
        }
        // Incoming rows record the address they arrived at; they say nothing about sending.
        try fixture.addMessage("to my other number", in: chat, from: .handle(maya), at: .minute(6)) {
            $0.destinationCallerID = "+14155550111"
            $0.account = "P:+14155550111"
        }
        // Values that are not addresses are ignored.
        try fixture.addMessage("odd", in: chat, from: .meTo(maya), at: .minute(7)) {
            $0.destinationCallerID = "unknown"
            $0.account = "iMessage"
        }

        let own = try fixture.open().ownAddresses()
        #expect(own == ["+14155550100", "me@example.com", "old@example.com"])
    }

    @Test func firstOutgoingDateFindsYourFirstReplyAfterADate() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let question = try fixture.addMessage("Call me?", in: chat, from: .handle(maya), at: .minute(1))
        try fixture.addReaction(.like, to: question, in: chat, from: .me, at: .minute(2)) // a tapback is not a reply
        try fixture.addMessage("Calling now", in: chat, from: .meTo(maya), at: .minute(3))
        try fixture.addMessage("Try again?", in: chat, from: .meTo(maya), at: .minute(4))

        let database = try fixture.open()
        #expect(try database.firstOutgoingDate(inChat: chat, after: .minute(0)) == .minute(3))
        #expect(try database.firstOutgoingDate(inChat: chat, after: .minute(3)) == .minute(4))
        #expect(try database.firstOutgoingDate(inChat: chat, after: .minute(4)) == nil)
    }

    @Test func latestOutgoingListsYourRecentMessagesOldestFirst() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        let withMaya = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let withSam = try fixture.addChat("any;-;+14155550143", participants: [sam])
        try fixture.addMessage("earlier", in: withMaya, from: .meTo(maya), at: .minute(1))
        try fixture.addMessage("first bubble", in: withMaya, from: .meTo(maya), at: .minute(5))
        try fixture.addMessage("reply", in: withMaya, from: .handle(maya), at: .minute(6))
        let second = try fixture.addMessage("second bubble", in: withMaya, from: .meTo(maya), at: .minute(7))
        try fixture.addReaction(.love, to: second, in: withMaya, from: .me, at: .minute(8))
        try fixture.addMessage("to someone else", in: withSam, from: .meTo(sam), at: .minute(9))

        let database = try fixture.open()
        #expect(try database.latestOutgoing(inChat: withMaya, after: .minute(2)).map(\.text) == ["first bubble", "second bubble"])
        #expect(try database.latestOutgoing(inChat: nil, after: .minute(2)).map(\.text) == ["first bubble", "second bubble", "to someone else"])
    }

    @Test func latestOutgoingIncludesAttachmentsForFileSends() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let photo = try fixture.addMessage(nil, in: chat, from: .meTo(maya), at: .minute(1))
        try fixture.addAttachment(to: photo, name: "receipt.png", mimeType: "image/png", bytes: 1_024)
        let sent = try #require(try fixture.open().latestOutgoing(inChat: chat, after: .minute(0)).first)
        #expect(sent.attachments.map(\.name) == ["receipt.png"])
    }
}
