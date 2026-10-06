import Foundation
import Testing

@testable import TincanKit

@Suite("Search")
struct MessageSearchTests {
    let fixture: MessagesFixture
    let withMaya: Int64
    let group: Int64

    init() throws {
        fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let sam = try fixture.addHandle("+14155550143")
        withMaya = try fixture.addChat("any;-;+14155550142", participants: [maya])
        group = try fixture.addChat("any;+;chat100200300", participants: [maya, sam])
        let first = try fixture.addMessage("Café at noon?", in: withMaya, from: .handle(maya), at: .minute(1))
        try fixture.addMessage("CAFE sounds good", in: withMaya, from: .meTo(maya), at: .minute(2))
        try fixture.addMessage("which cafe", in: group, from: .handle(sam), at: .minute(3))
        try fixture.addMessage("The café on 5th", in: group, from: .handle(maya), at: .minute(4))
        try fixture.addMessage("unrelated", in: group, from: .handle(sam), at: .minute(5))
        // Reaction rows quote their target, and renames carry a title; neither is a message to find.
        try fixture.addReaction(.love, to: first, in: withMaya, from: .me, at: .minute(6))
        try fixture.addMessage(nil, in: group, from: .handle(sam), at: .minute(7)) {
            $0.itemType = 2
            $0.groupTitle = "Cafe club"
        }
    }

    @Test func matchesIgnoreCaseAndDiacriticsNewestFirst() throws {
        let results = try fixture.open().search("café", limit: 10)
        #expect(results.map(\.text) == ["The café on 5th", "which cafe", "CAFE sounds good", "Café at noon?"])
    }

    @Test func typographicPunctuationMatchesItsPlainForm() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        try fixture.addMessage("Wie geht’s?", in: chat, from: .handle(maya), at: .minute(1))
        try fixture.addMessage("wie geht's dir", in: chat, from: .meTo(maya), at: .minute(2))
        try fixture.addMessage("“Soon” – maybe… see you", in: chat, from: .handle(maya), at: .minute(3))
        let database = try fixture.open()
        // Curly and straight apostrophes find each other, both ways.
        #expect(try database.search("wie geht’s", limit: 10).map(\.text) == ["wie geht's dir", "Wie geht’s?"])
        #expect(try database.search("geht's", limit: 10).map(\.text) == ["wie geht's dir", "Wie geht’s?"])
        #expect(try database.search("\"soon\" - maybe...", limit: 10).map(\.text) == ["“Soon” – maybe… see you"])
        #expect(try database.search("maybe…", limit: 10).count == 1)
    }

    @Test func foldedMatchesPointAtTheOriginalText() {
        let text = "Na, wie geht’s? “Gut” – danke…"
        #expect(TextFolding.range(of: "geht's", in: text).map { String(text[$0]) } == "geht’s")
        #expect(TextFolding.range(of: "\"gut\" - danke...", in: text).map { String(text[$0]) } == "“Gut” – danke…")
        #expect(TextFolding.range(of: "WIE", in: "Café wie").map { String("Café wie"[$0]) } == "wie")
        #expect(TextFolding.range(of: "cafe", in: "Café wie").map { String("Café wie"[$0]) } == "Café")
        #expect(TextFolding.range(of: "xyz", in: text) == nil)
    }

    @Test func fromMeOnlyChoosesYourMessagesOrTheirs() throws {
        let database = try fixture.open()
        #expect(try database.search("cafe", fromMeOnly: true, limit: 10).map(\.text) == ["CAFE sounds good"])
        #expect(try database.search("cafe", fromMeOnly: false, limit: 10).map(\.text) == ["The café on 5th", "which cafe", "Café at noon?"])
    }

    @Test func sendersKeepsMessagesFromThoseAddresses() throws {
        let results = try fixture.open().search("cafe", senders: ["+14155550142"], limit: 10)
        #expect(results.map(\.text) == ["The café on 5th", "Café at noon?"])
        #expect(results.allSatisfy { $0.sender == "+14155550142" })
    }

    @Test func afterAndInChatsNarrowTheSearch() throws {
        let database = try fixture.open()
        #expect(try database.search("cafe", after: .minute(2), limit: 10).map(\.text) == ["The café on 5th", "which cafe"])
        #expect(try database.search("cafe", inChats: [withMaya], limit: 10).map(\.text) == ["CAFE sounds good", "Café at noon?"])
    }

    @Test func theLimitStopsAtTheNewestMatches() throws {
        #expect(try fixture.open().search("cafe", limit: 2).map(\.text) == ["The café on 5th", "which cafe"])
    }

    @Test func pagingFromAMatchVisitsEveryMatchOnceEvenWhenTimestampsTie() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        var expected: [Int64] = []
        for (index, minute) in [1, 2, 2, 2, 3, 3, 4].enumerated() {
            expected.append(try fixture.addMessage("tie \(index)", in: chat, from: .handle(maya), at: .minute(minute)).rowID)
        }
        let database = try fixture.open()
        var seen: [Int64] = []
        var page = try database.search("tie", limit: 2)
        while let oldest = page.last {
            seen += page.map(\.id)
            page = try database.search("tie", beforeMessage: oldest.id, limit: 2)
        }
        #expect(seen == expected.reversed())
    }

    @Test func pagingFromAnUnknownOrExcludedMessageFindsNothing() throws {
        let database = try fixture.open(excluding: [group])
        #expect(try database.search("cafe", beforeMessage: 999, limit: 10).isEmpty)
        let excluded = try fixture.open().search("the café", limit: 1)
        #expect(try database.search("cafe", beforeMessage: try #require(excluded.first).id, limit: 10).isEmpty)
    }

    @Test func blankQueriesFindNothing() throws {
        #expect(try fixture.open().search("", limit: 10).isEmpty)
    }
}
