import Foundation
import Testing

@testable import TincanKit

/// Tapbacks and emoji reactions are rows of their own in `message`, pointing at their target
/// through `associated_message_guid` (`p:<part>/<guid>` or `bp:<guid>`). tincan folds them
/// onto the message they target and never lists them as messages.
@Suite("Reactions")
struct ReactionTests {
    typealias Tapback = MessagesFixture.Tapback

    let fixture: MessagesFixture
    let maya: Int64
    let sam: Int64
    let chat: Int64
    /// "Dinner at 8?", sent by you at minute 1.
    let dinner: MessagesFixture.Row

    init() throws {
        fixture = try MessagesFixture()
        maya = try fixture.addHandle("+14155550142")
        sam = try fixture.addHandle("+14155550143")
        chat = try fixture.addChat("any;+;chat100200300", participants: [maya, sam])
        dinner = try fixture.addMessage("Dinner at 8?", in: chat, from: .me, at: .minute(1))
    }

    private func dinnerReactions() throws -> [Reaction] {
        let messages = try fixture.open().messages(inChats: [chat])
        return try #require(messages.first { $0.guid == dinner.guid }).reactions
    }

    @Test func reactionRowsAreNotListedAsMessages() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        try fixture.addReaction(.like, to: dinner, in: chat, from: .handle(sam), at: .minute(3))
        let messages = try fixture.open().messages(inChats: [chat])
        #expect(messages.map(\.guid) == [dinner.guid])
    }

    @Test func aReactionFoldsOntoItsTarget() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        let reactions = try dinnerReactions()
        #expect(reactions == [Reaction(kind: .love, emoji: nil, from: "+14155550142", at: .minute(2), part: 0)])
        #expect(reactions.first?.symbol == "❤️")
    }

    @Test(
        "Each tapback type maps to its kind",
        arguments: [
            (Tapback.love, Reaction.Kind.love), (.like, .like), (.dislike, .dislike), (.laugh, .laugh),
            (.emphasize, .emphasize), (.question, .question), (.sticker, .sticker),
        ])
    func tapbackKinds(tapback: Tapback, kind: Reaction.Kind) throws {
        try fixture.addReaction(tapback, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        #expect(try dinnerReactions().map(\.kind) == [kind])
    }

    @Test func legacyStickerRowsAreStickerReactions() throws {
        try fixture.addMessage(nil, in: chat, from: .handle(maya), at: .minute(2)) {
            $0.associatedType = 1000
            $0.associatedGUID = "p:0/\(dinner.guid)"
        }
        #expect(try dinnerReactions().map(\.kind) == [.sticker])
    }

    @Test func emojiReactionsCarryTheirEmoji() throws {
        try fixture.addReaction(.emoji, to: dinner, in: chat, from: .handle(maya), at: .minute(2), emoji: "🔥")
        let reaction = try #require(try dinnerReactions().first)
        #expect(reaction.kind == .emoji)
        #expect(reaction.emoji == "🔥")
        #expect(reaction.symbol == "🔥")
        #expect(reaction.verb == "Reacted 🔥")
    }

    @Test func removingAReactionCancelsIt() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        try fixture.removeReaction(.love, from: dinner, in: chat, by: .handle(maya), at: .minute(3))
        #expect(try dinnerReactions().isEmpty)
    }

    @Test func removingAnEmojiReactionCancelsIt() throws {
        try fixture.addReaction(.emoji, to: dinner, in: chat, from: .handle(maya), at: .minute(2), emoji: "🔥")
        try fixture.removeReaction(.emoji, from: dinner, in: chat, by: .handle(maya), at: .minute(3), emoji: "🔥")
        #expect(try dinnerReactions().isEmpty)
    }

    @Test func aRemovalOfAnotherKindLeavesTheReaction() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        try fixture.removeReaction(.like, from: dinner, in: chat, by: .handle(maya), at: .minute(3))
        #expect(try dinnerReactions().map(\.kind) == [.love])
    }

    @Test func aRemovalOnlyCancelsTheSamePersonsReaction() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(sam), at: .minute(3))
        try fixture.removeReaction(.love, from: dinner, in: chat, by: .handle(sam), at: .minute(4))
        #expect(try dinnerReactions().map(\.from) == ["+14155550142"])
    }

    @Test func eachPersonKeepsTheirLatestReactionPerPart() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        try fixture.addReaction(.laugh, to: dinner, in: chat, from: .handle(maya), at: .minute(3))
        try fixture.addReaction(.like, to: dinner, in: chat, from: .handle(sam), at: .minute(4))
        let reactions = try dinnerReactions()
        #expect(reactions.map(\.kind) == [.laugh, .like])
        #expect(reactions.map(\.from) == ["+14155550142", "+14155550143"])
    }

    @Test func yourOwnReactionsHaveNoSender() throws {
        let question = try fixture.addMessage("Are you coming?", in: chat, from: .handle(maya), at: .minute(2))
        try fixture.addReaction(.like, to: question, in: chat, from: .me, at: .minute(3))
        let messages = try fixture.open().messages(inChats: [chat])
        let reaction = try #require(messages.first { $0.guid == question.guid }?.reactions.first)
        #expect(reaction.from == nil)
        #expect(reaction.kind == .like)
    }

    @Test func aReactionFromSomeoneMessagesDidNotRecordIsNeverYours() throws {
        // A group row without a handle: tincan cannot say who reacted, and must not say you did.
        try fixture.addReaction(.love, to: dinner, in: chat, from: .me, at: .minute(2))
        try fixture.addReaction(.laugh, to: dinner, in: chat, from: .handle(0), at: .minute(3))
        try fixture.removeReaction(.love, from: dinner, in: chat, by: .handle(0), at: .minute(4))
        let reactions = try dinnerReactions()
        #expect(reactions.map(\.kind) == [.love])
        #expect(reactions.map(\.from) == [nil])
        #expect(try fixture.open().reactionRows(afterRowID: dinner.rowID, limit: 10).map(\.reaction.from) == [nil])
    }

    @Test func aDirectChatReactionWithoutAHandleIsFromTheOtherPerson() throws {
        let direct = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let hello = try fixture.addMessage("Hello", in: direct, from: .me, at: .minute(2))
        try fixture.addReaction(.like, to: hello, in: direct, from: .handle(0), at: .minute(3))
        let database = try fixture.open()
        let message = try #require(try database.messages(inChats: [direct]).first)
        #expect(message.reactions.map(\.from) == ["+14155550142"])
        #expect(try database.reactionRows(afterRowID: hello.rowID, limit: 10).map(\.reaction.from) == ["+14155550142"])
    }

    @Test func aReactionStampedBeforeItsTargetByAnotherClockStillFolds() throws {
        // Each device stamps its own rows, and a reactor's clock can run behind the sender's.
        try fixture.addReaction(.like, to: dinner, in: chat, from: .handle(maya), at: Date.minute(1).addingTimeInterval(-2))
        #expect(try dinnerReactions().map(\.kind) == [.like])
        #expect(try fixture.open().chatSummaries(limit: nil).first?.lastMessage?.reactions.map(\.kind) == [.like])
    }

    @Test func stickersPlacedOnAMessageKeepTheSendersTapback() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2))
        for minute in 3...4 {
            try fixture.addMessage(nil, in: chat, from: .handle(maya), at: .minute(minute)) {
                $0.associatedType = 1000
                $0.associatedGUID = "p:0/\(dinner.guid)"
            }
        }
        #expect(try dinnerReactions().map(\.kind) == [.love, .sticker, .sticker])
    }

    @Test func reactionsOnLaterPartsAreFoldedOntoYourSentMessages() throws {
        try fixture.addReaction(.laugh, to: dinner, in: chat, from: .handle(sam), at: .minute(2), part: 1)
        let sent = try #require(try fixture.open().outgoing(inChat: chat, afterRowID: 0).first)
        #expect(sent.reactions.map(\.part) == [1])
    }

    @Test func reactionsNameThePartTheyTarget() throws {
        // A photo with a caption is two parts: part 0 is the photo, part 1 the caption.
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2), part: 0)
        try fixture.addReaction(.laugh, to: dinner, in: chat, from: .handle(maya), at: .minute(3), part: 1)
        let reactions = try dinnerReactions()
        #expect(reactions.map(\.part) == [0, 1])
        #expect(reactions.map(\.kind) == [.love, .laugh])
    }

    @Test func balloonReactionsTargetTheFirstPart() throws {
        try fixture.addReaction(.like, to: dinner, in: chat, from: .handle(sam), at: .minute(2), balloon: true)
        let reaction = try #require(try dinnerReactions().first)
        #expect(reaction.part == 0)
        #expect(reaction.from == "+14155550143")
    }

    @Test func associatedGUIDsAreParsed() {
        #expect(MessagesDatabase.parseAssociatedGUID("p:0/ABC") == ("ABC", 0))
        #expect(MessagesDatabase.parseAssociatedGUID("p:2/ABC") == ("ABC", 2))
        #expect(MessagesDatabase.parseAssociatedGUID("bp:ABC") == ("ABC", 0))
        #expect(MessagesDatabase.parseAssociatedGUID("ABC") == ("ABC", 0))
    }

    @Test func reactionsAreFoldedWhenAMessageIsLoadedByIDOrGUID() throws {
        try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2), part: 0)
        try fixture.addReaction(.laugh, to: dinner, in: chat, from: .handle(sam), at: .minute(3), part: 1)
        let database = try fixture.open()
        let byID = try #require(try database.message(id: dinner.rowID))
        let byGUID = try #require(try database.messages(guids: [dinner.guid]).first)
        #expect(byID.reactions.map(\.kind) == [.love, .laugh])
        #expect(byGUID.reactions.map(\.kind) == [.love, .laugh])
    }

    @Test func aReactionIsNotLoadedAsAMessage() throws {
        let love = try fixture.addReaction(.love, to: dinner, in: chat, from: .handle(maya), at: .minute(2), part: 1)
        let sticker = try fixture.addReaction(.like, to: dinner, in: chat, from: .handle(sam), at: .minute(3), balloon: true)
        let later = try fixture.addMessage("See you there", in: chat, from: .handle(maya), at: .minute(4))
        let database = try fixture.open()
        for reaction in [love, sticker] {
            #expect(try database.message(id: reaction.rowID) == nil)
            #expect(try database.message(guid: reaction.guid) == nil)
            #expect(try database.messages(guids: [reaction.guid]).isEmpty)
            // It names the message it reacts to instead.
            #expect(try database.reactionTarget(id: reaction.rowID) == dinner.guid)
            #expect(try database.reactionTarget(guid: reaction.guid) == dinner.guid)
            // Nor is it a place to page from.
            #expect(try database.messages(inChats: [chat], beforeMessage: reaction.rowID).isEmpty)
            #expect(try database.messages(inChats: [chat], afterMessage: reaction.rowID).isEmpty)
            #expect(try database.search("e", beforeMessage: reaction.rowID, limit: 10).isEmpty)
        }
        #expect(try database.message(guid: dinner.guid)?.id == dinner.rowID)
        #expect(try database.reactionTarget(id: dinner.rowID) == nil)
        #expect(try database.reactionTarget(id: later.rowID) == nil)
    }
}
