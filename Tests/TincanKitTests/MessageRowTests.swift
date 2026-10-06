import Foundation
import Testing

@testable import TincanKit

/// How one `message` row becomes a `Message`: who sent it, what kind of bubble it is, its
/// attachments, edits, unsends and delivery facts.
@Suite("Message rows")
struct MessageRowTests {
    let fixture: MessagesFixture
    let maya: Int64
    let sam: Int64
    /// One-to-one chat with Maya.
    let direct: Int64
    /// Group chat with Maya and Sam.
    let group: Int64

    init() throws {
        fixture = try MessagesFixture()
        maya = try fixture.addHandle("+14155550142")
        sam = try fixture.addHandle("+14155550143")
        direct = try fixture.addChat("any;-;+14155550142", participants: [maya])
        group = try fixture.addChat("any;+;chat100200300", participants: [maya, sam])
    }

    private func load(_ row: MessagesFixture.Row) throws -> Message {
        try #require(try fixture.open().message(id: row.rowID))
    }

    // MARK: Senders

    @Test func incomingMessagesNameTheSendersAddress() throws {
        let row = try fixture.addMessage("Hi", in: group, from: .handle(sam), at: .minute(1))
        let message = try load(row)
        #expect(message.sender == "+14155550143")
        #expect(!message.isFromMe)
    }

    @Test func aDirectRowWithoutAHandleFallsBackToTheOnlyParticipant() throws {
        let row = try fixture.addMessage("Hi", in: direct, from: .handle(0), at: .minute(1))
        #expect(try load(row).sender == "+14155550142")
    }

    @Test func aGroupRowWithoutAHandleHasNoSender() throws {
        let row = try fixture.addMessage("Hi", in: group, from: .handle(0), at: .minute(1))
        #expect(try load(row).sender == nil)
    }

    @Test func aGroupWithOneParticipantLeftDoesNotLendThemRowsWithoutAHandle() throws {
        let dwindled = try fixture.addChat("any;+;chat400500600", participants: [maya])
        let row = try fixture.addMessage("Hi", in: dwindled, from: .handle(0), at: .minute(1))
        #expect(try load(row).sender == nil)
    }

    @Test func yourMessagesHaveNoSenderEvenWhenTheRowNamesTheRecipient() throws {
        let row = try fixture.addMessage("On my way", in: direct, from: .meTo(maya), at: .minute(1))
        let message = try load(row)
        #expect(message.isFromMe)
        #expect(message.sender == nil)
    }

    // MARK: Bodies

    @Test func textFromEitherColumnIsRead() throws {
        let archived = try fixture.addMessage("From attributedBody", in: direct, from: .handle(maya), at: .minute(1))
        let plain = try fixture.addMessage("From the text column", in: direct, from: .handle(maya), at: .minute(2)) {
            $0.textColumnOnly = true
        }
        #expect(try load(archived).body.source == .attributedBody)
        #expect(try load(archived).text == "From attributedBody")
        #expect(try load(plain).body.source == .text)
        #expect(try load(plain).text == "From the text column")
    }

    @Test func servicesAreRecognized() throws {
        let sms = try fixture.addMessage("sms", in: direct, from: .handle(maya), at: .minute(1)) { $0.service = "SMS" }
        let rcs = try fixture.addMessage("rcs", in: direct, from: .handle(maya), at: .minute(2)) { $0.service = "RCS" }
        let imessage = try fixture.addMessage("imessage", in: direct, from: .handle(maya), at: .minute(3))
        #expect(try load(sms).service == .sms)
        #expect(try load(rcs).service == .rcs)
        #expect(try load(imessage).service == .iMessage)
    }

    // MARK: Group events

    @Test func addingSomeoneIsAnAddedEvent() throws {
        let row = try fixture.addMessage(nil, in: group, from: .handle(maya), at: .minute(1)) {
            $0.itemType = 1
            $0.groupActionType = 0
            $0.otherHandle = sam
        }
        let message = try load(row)
        #expect(message.kind == .event)
        #expect(message.event == ConversationEvent(kind: .added, subject: "+14155550143", title: nil))
        #expect(message.sender == "+14155550142")
    }

    @Test func removingSomeoneIsARemovedEvent() throws {
        let row = try fixture.addMessage(nil, in: group, from: .me, at: .minute(1)) {
            $0.itemType = 1
            $0.groupActionType = 1
            $0.otherHandle = sam
        }
        #expect(try load(row).event == ConversationEvent(kind: .removed, subject: "+14155550143", title: nil))
    }

    @Test func renamingTheGroupCarriesTheNewName() throws {
        let row = try fixture.addMessage(nil, in: group, from: .handle(sam), at: .minute(1)) {
            $0.itemType = 2
            $0.groupTitle = "Climbing crew"
        }
        #expect(try load(row).event == ConversationEvent(kind: .renamed, subject: nil, title: "Climbing crew"))
    }

    @Test func leavingAndChangingThePhotoAreEvents() throws {
        let left = try fixture.addMessage(nil, in: group, from: .handle(sam), at: .minute(1)) { $0.itemType = 3 }
        let photo = try fixture.addMessage(nil, in: group, from: .handle(maya), at: .minute(2)) {
            $0.itemType = 3
            $0.groupActionType = 1
        }
        #expect(try load(left).event?.kind == .left)
        #expect(try load(photo).event?.kind == .photoChanged)
    }

    @Test func ordinaryMessagesHaveNoEvent() throws {
        let row = try fixture.addMessage("Hi", in: group, from: .handle(sam), at: .minute(1))
        #expect(try load(row).event == nil)
        #expect(try load(row).kind == .message)
    }

    // MARK: Edits and unsends

    @Test func editedPartsInTheSummaryMarkAMessageEdited() throws {
        let row = try fixture.addMessage("Dinner at 8:30?", in: direct, from: .me, at: .minute(1)) {
            $0.summaryInfo = ["ep": [0], "ec": ["0": [["d": 1]]]]
        }
        #expect(try load(row).isEdited)
    }

    @Test func anEditDateMarksAMessageEdited() throws {
        let row = try fixture.addMessage("Dinner at 8:30?", in: direct, from: .me, at: .minute(1)) {
            $0.dateEdited = .minute(2)
        }
        #expect(try load(row).isEdited)
    }

    @Test func untouchedMessagesAreNeitherEditedNorUnsent() throws {
        let message = try load(try fixture.addMessage("Hi", in: direct, from: .me, at: .minute(1)))
        #expect(!message.isEdited)
        #expect(!message.isUnsent)
        #expect(message.unsentParts.isEmpty)
    }

    @Test func aMessageWhoseOnlyPartWasUnsentIsUnsent() throws {
        let row = try fixture.addMessage(nil, in: direct, from: .me, at: .minute(1)) {
            $0.summaryInfo = ["rp": [0]]
            $0.dateEdited = .minute(2)
        }
        let message = try load(row)
        #expect(message.isUnsent)
        #expect(!message.isEdited)
        #expect(message.unsentParts == [0])
        #expect(message.text.isEmpty)
    }

    @Test func aRetractionDateWithAnEmptyBodyIsUnsent() throws {
        let row = try fixture.addMessage(nil, in: direct, from: .handle(maya), at: .minute(1)) {
            $0.dateRetracted = .minute(2)
        }
        #expect(try load(row).isUnsent)
    }

    @Test func unsendingOnePartKeepsTheRestVisible() throws {
        let row = try fixture.addMessage("This part stays", in: direct, from: .me, at: .minute(1)) {
            $0.summaryInfo = ["rp": [1]]
            $0.dateEdited = .minute(2)
        }
        let message = try load(row)
        #expect(!message.isUnsent)
        #expect(!message.isEdited)
        #expect(message.unsentParts == [1])
        #expect(message.text == "This part stays")
    }

    // MARK: Attachments

    @Test func attachmentsAreJoinedInOrder() throws {
        let row = try fixture.addMessage(nil, in: direct, from: .handle(maya), at: .minute(1))
        let photo = try fixture.addAttachment(to: row, name: "IMG_0001.HEIC", mimeType: "image/heic", uti: "public.heic", bytes: 2_400_000)
        let clip = try fixture.addAttachment(to: row, name: "clip.mov", mimeType: "video/quicktime", uti: "com.apple.quicktime-movie", bytes: 9_000_000)
        let message = try load(row)
        #expect(message.attachments.map(\.guid) == [photo, clip])
        #expect(message.attachments.map(\.category) == ["image", "video"])
        #expect(message.attachments.map(\.name) == ["IMG_0001.HEIC", "clip.mov"])
        #expect(message.attachments.map(\.bytes) == [2_400_000, 9_000_000])
        #expect(message.kind == .message)
    }

    @Test func appDataAttachmentsAreHidden() throws {
        let row = try fixture.addMessage(nil, in: direct, from: .handle(maya), at: .minute(1))
        try fixture.addAttachment(to: row, name: "payload", mimeType: nil, uti: "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu")
        let pdf = try fixture.addAttachment(to: row, name: "tickets.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf")
        let message = try load(row)
        #expect(message.attachments.map(\.guid) == [pdf])
        #expect(message.attachments.first?.category == "pdf")
    }

    @Test func stickersAndGenmojiAreRecognized() throws {
        let row = try fixture.addMessage(nil, in: direct, from: .handle(maya), at: .minute(1))
        try fixture.addAttachment(to: row, name: "sticker.heic", mimeType: "image/heic", isSticker: true)
        try fixture.addAttachment(
            to: row, name: "genmoji.heic", mimeType: "image/heic",
            emojiImageContentIdentifier: "genmoji-0001", emojiImageShortDescription: "cat in a party hat"
        )
        let attachments = try load(row).attachments
        #expect(attachments.map(\.category) == ["sticker", "genmoji"])
        #expect(attachments.map(\.isEmojiImage) == [false, true])
        #expect(attachments.last?.summary == "cat in a party hat")
    }

    @Test func anAttachmentPathIsReportedOnlyWhenTheFileExists() throws {
        let row = try fixture.addMessage(nil, in: direct, from: .handle(maya), at: .minute(1))
        let downloaded = fixture.database.directory.appendingPathComponent("IMG_0002.JPG").path
        try Data([0xFF, 0xD8, 0xFF]).write(to: URL(fileURLWithPath: downloaded))
        let missing = fixture.database.directory.appendingPathComponent("never-downloaded.jpg").path
        try fixture.addAttachment(to: row, name: "IMG_0002.JPG", mimeType: "image/jpeg", filename: downloaded)
        try fixture.addAttachment(to: row, name: "never-downloaded.jpg", mimeType: "image/jpeg", filename: missing)
        #expect(try load(row).attachments.map(\.path) == [downloaded, nil])
    }

    // MARK: Kinds

    @Test func richLinksAreLinks() throws {
        let row = try fixture.addMessage("https://example.com/menu", in: direct, from: .handle(maya), at: .minute(1)) {
            $0.balloonBundleID = "com.apple.messages.URLBalloonProvider"
        }
        let message = try load(row)
        #expect(message.kind == .link)
        #expect(message.appName == nil)
    }

    @Test(
        "Extension balloons are app messages with friendly names",
        arguments: [
            ("com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls", "Poll"),
            ("com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext", "GamePigeon"),
            ("com.apple.messages.MSMessageExtensionBalloonPlugin:ABCDE12345:com.example.board-game.ext", "com.example.board-game.ext"),
        ])
    func appBalloons(bundleID: String, name: String) throws {
        let row = try fixture.addMessage(nil, in: direct, from: .handle(maya), at: .minute(1)) {
            $0.balloonBundleID = bundleID
        }
        let message = try load(row)
        #expect(message.kind == .app)
        #expect(message.appName == name)
    }

    @Test("App updates tied to an earlier bubble are app messages", arguments: [2, 3])
    func appUpdates(associatedType: Int) throws {
        let original = try fixture.addMessage(nil, in: direct, from: .me, at: .minute(1))
        let update = try fixture.addMessage("Your move", in: direct, from: .handle(maya), at: .minute(2)) {
            $0.associatedType = associatedType
            $0.associatedGUID = original.guid
        }
        let messages = try fixture.open().messages(inChats: [direct])
        #expect(messages.map(\.id) == [original.rowID, update.rowID])
        #expect(messages.last?.kind == .app)
    }

    @Test func voiceMessagesAreAudio() throws {
        let row = try fixture.addMessage(nil, in: direct, from: .handle(maya), at: .minute(1)) { $0.isAudioMessage = true }
        try fixture.addAttachment(to: row, name: "Audio Message.caf", mimeType: "audio/x-caf")
        let message = try load(row)
        #expect(message.kind == .audio)
        #expect(message.attachments.first?.category == "audio")
    }

    @Test func repliesEffectsAndSubjectsAreKept() throws {
        let original = try fixture.addMessage("Dinner?", in: direct, from: .handle(maya), at: .minute(1))
        let reply = try fixture.addMessage("Yes!", in: direct, from: .me, at: .minute(2)) {
            $0.threadOriginatorGUID = original.guid
            $0.expressiveSendStyleID = "com.apple.MobileSMS.expressivesend.impact"
            $0.subject = "Friday"
        }
        let message = try load(reply)
        #expect(message.replyToGUID == original.guid)
        #expect(message.replyToID == original.rowID)
        #expect(message.replyToReference == "m:\(original.rowID)")
        #expect(message.expressiveEffect == "slam")
        #expect(message.subject == "Friday")
    }

    @Test func aReplyToAMessageTincanCantReadHasNoReference() throws {
        let reply = try fixture.addMessage("Yes!", in: direct, from: .me, at: .minute(2)) { $0.threadOriginatorGUID = "0B9F3E52-1C44-4B8A-9E0D-7A61C2F5D301" }
        let message = try load(reply)
        #expect(message.replyToGUID == "0B9F3E52-1C44-4B8A-9E0D-7A61C2F5D301")
        #expect(message.replyToID == nil)
    }

    // MARK: Delivery and read state

    @Test func deliveryAndReadTimesAreReportedForYourMessages() throws {
        let row = try fixture.addMessage("See you soon", in: direct, from: .meTo(maya), at: .minute(1)) {
            $0.isDelivered = true
            $0.dateDelivered = .minute(2)
            $0.dateRead = .minute(5)
        }
        let message = try load(row)
        #expect(message.deliveredAt == .minute(2))
        #expect(message.readAt == .minute(5))
        #expect(message.isSent)
        #expect(message.isRead)
    }

    @Test func incomingMessagesHaveNoDeliveryOrReadTimes() throws {
        let row = try fixture.addMessage("Hi", in: direct, from: .handle(maya), at: .minute(1)) {
            $0.isDelivered = true
            $0.dateDelivered = .minute(1)
            $0.dateRead = .minute(3)
            $0.isRead = false
        }
        let message = try load(row)
        #expect(message.deliveredAt == nil)
        #expect(message.readAt == nil)
        #expect(!message.isRead)
    }

    @Test func aDeliveredFlagWithoutADateUsesTheSendTime() throws {
        let row = try fixture.addMessage("Sent", in: direct, from: .meTo(maya), at: .minute(4)) { $0.isDelivered = true }
        #expect(try load(row).deliveredAt == .minute(4))
    }

    @Test func aSendErrorMarksYourMessageFailed() throws {
        let failed = try fixture.addMessage("Did this go?", in: direct, from: .meTo(maya), at: .minute(1)) {
            $0.error = 22
            $0.isSent = false
        }
        let incoming = try fixture.addMessage("Error on their side", in: direct, from: .handle(maya), at: .minute(2)) { $0.error = 22 }
        #expect(try load(failed).failed)
        #expect(try load(failed).errorCode == 22)
        #expect(!(try load(incoming).failed))
    }
}
