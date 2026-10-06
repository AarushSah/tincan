import AppKit
import Foundation
import Testing

@testable import TincanKit

/// Builds `attributedBody` blobs the way Messages does: an NSArchiver typedstream.
enum AttributedBodyFixture {
    /// `NSArchiver` is deprecated, but it is the only writer of the format Messages stores.
    /// Calling it through the Objective-C runtime keeps its deprecation out of every build.
    static func archive(_ attributed: NSAttributedString) -> Data {
        let archiver: AnyObject = NSClassFromString("NSArchiver")!
        let archived = archiver.perform(NSSelectorFromString("archivedDataWithRootObject:"), with: attributed)
        return archived!.takeUnretainedValue() as! Data
    }

    static func plain(_ text: String, part: Int = 0) -> Data {
        archive(
            NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: part)
                ]))
    }
}

@Suite("Message bodies")
struct MessageBodyTests {
    @Test func decodesTextFromTheAttributedBody() {
        let body = MessageBody.decode(text: nil, attributedBody: AttributedBodyFixture.plain("On my way 🚲"))
        #expect(body.text == "On my way 🚲")
        #expect(body.source == .attributedBody)
    }

    @Test func prefersTheAttributedBodyOverTheTextColumn() {
        let body = MessageBody.decode(text: "stale", attributedBody: AttributedBodyFixture.plain("fresh"))
        #expect(body.text == "fresh")
    }

    @Test func fallsBackToTheTextColumn() {
        let body = MessageBody.decode(text: "Plain text", attributedBody: nil)
        #expect(body.text == "Plain text")
        #expect(body.source == .text)
    }

    @Test func recordsAttachmentPlaceholdersInOrderWithTheirParts() {
        let attributed = NSMutableAttributedString()
        attributed.append(
            NSAttributedString(
                string: "\u{FFFC}",
                attributes: [
                    NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"): "AT-1",
                    NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: 0),
                ]))
        attributed.append(
            NSAttributedString(
                string: "Look at this",
                attributes: [
                    NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: 1)
                ]))
        let body = MessageBody.decode(text: nil, attributedBody: AttributedBodyFixture.archive(attributed))
        #expect(body.attachmentGUIDs == ["AT-1"])
        #expect(body.text == "Look at this")
        #expect(body.text(ofPart: 1) == "Look at this")
        #expect(body.text(ofPart: 0) == "")
    }

    @Test func recordsMentions() {
        let attributed = NSMutableAttributedString(string: "hey ", attributes: [:])
        attributed.append(
            NSAttributedString(
                string: "Maya",
                attributes: [
                    NSAttributedString.Key("__kIMMentionConfirmedMention"): "+14155550142"
                ]))
        let body = MessageBody.decode(text: nil, attributedBody: AttributedBodyFixture.archive(attributed))
        #expect(body.text == "hey Maya")
        #expect(body.mentions == [MessageBody.Mention(handle: "+14155550142", text: "Maya")])
    }

    @Test func corruptDataDoesNotCrashAndFallsBack() {
        let garbage = Data([0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64, 0xFF, 0x00, 0x13])
        let body = MessageBody.decode(text: "from text", attributedBody: garbage)
        #expect(body.text == "from text")
    }

    @Test func recoversTextFromATypedStreamByteScan() {
        let data = AttributedBodyFixture.plain(String(repeating: "long message ", count: 30))
        let recovered = MessageBody.recoverText(fromTypedStream: data)
        #expect(recovered == String(repeating: "long message ", count: 30).trimmingCharacters(in: .whitespaces))
    }

    @Test func emptyRowsHaveNoBody() {
        #expect(MessageBody.decode(text: nil, attributedBody: nil) == .empty)
        #expect(MessageBody.decode(text: "", attributedBody: Data()) == .empty)
    }
}
