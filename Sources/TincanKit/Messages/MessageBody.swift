import Foundation
import TincanObjC

/// The readable content of one Messages row.
///
/// Current macOS versions leave `message.text` empty for most messages and keep the body in
/// `attributedBody`, an `NSArchiver` typedstream of an attributed string. The attributed
/// string also carries where attachments sit in the text, @mentions, links and which
/// "part" of a multi-part message each run belongs to (reactions target parts).
public struct MessageBody: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case text(String, part: Int)
        /// An inline attachment; `guid` matches `attachment.guid`.
        case attachment(guid: String, part: Int)
    }

    public struct Mention: Sendable, Equatable {
        /// The mentioned handle, such as `+14155550142` or an email address.
        public let handle: String
        public let text: String
    }

    public enum Source: String, Sendable, Codable {
        /// Decoded from `attributedBody` with Apple's archiver.
        case attributedBody = "attributed_body"
        /// `attributedBody` could not be decoded fully; text was recovered from its bytes.
        case recovered
        /// The plain `text` column.
        case text
        /// No body: attachment-only, reaction or system rows.
        case none
    }

    public var segments: [Segment]
    public var mentions: [Mention]
    public var links: [String]
    public var source: Source

    public static let empty = MessageBody(segments: [], mentions: [], links: [], source: .none)

    /// The text a person would read, without attachment placeholders.
    public var text: String {
        segments.compactMap {
            if case .text(let value, _) = $0 { return value }
            return nil
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attachment GUIDs in reading order.
    public var attachmentGUIDs: [String] {
        segments.compactMap {
            if case .attachment(let guid, _) = $0 { return guid }
            return nil
        }
    }

    /// The text of one message part, for quoting the target of a reaction or reply.
    public func text(ofPart part: Int) -> String {
        segments.compactMap {
            if case .text(let value, let index) = $0, index == part { return value }
            return nil
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Decoding

    /// The readable text of a row without building the attributed string, for scanning many
    /// rows (search). Matches `decode(text:attributedBody:).text` in practice; callers that
    /// need certainty decode the rows that match.
    public static func quickText(text: String?, attributedBody: Data?) -> String {
        if let data = attributedBody, !data.isEmpty, let recovered = recoverText(fromTypedStream: data) {
            return recovered
        }
        if let data = attributedBody, !data.isEmpty {
            return decode(text: text, attributedBody: data).text
        }
        return (text ?? "").replacingOccurrences(of: String(objectReplacement), with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let objectReplacement: Character = "\u{FFFC}"
    private static let partKey = NSAttributedString.Key("__kIMMessagePartAttributeName")
    private static let fileTransferKey = NSAttributedString.Key("__kIMFileTransferGUIDAttributeName")
    private static let mentionKey = NSAttributedString.Key("__kIMMentionConfirmedMention")
    private static let linkKey = NSAttributedString.Key("__kIMLinkAttributeName")

    /// Decodes a row from its `text` and `attributedBody` columns. The attributed body wins
    /// because it is the only place that records attachments, mentions and parts.
    public static func decode(text: String?, attributedBody: Data?) -> MessageBody {
        if let data = attributedBody, !data.isEmpty {
            // The archive's objects are autoreleased; release them with each message, not
            // after a whole page of thousands.
            if let body = autoreleasepool(invoking: { TCNUnarchiveAttributedString(data).map(decode) }) {
                return body
            }
            if let recovered = recoverText(fromTypedStream: data) {
                return MessageBody(segments: [.text(recovered, part: 0)], mentions: [], links: [], source: .recovered)
            }
        }
        if let text, !text.isEmpty {
            let cleaned = text.replacingOccurrences(of: String(objectReplacement), with: "")
            return MessageBody(segments: cleaned.isEmpty ? [] : [.text(cleaned, part: 0)], mentions: [], links: [], source: .text)
        }
        return .empty
    }

    static func decode(_ attributed: NSAttributedString) -> MessageBody {
        let string = attributed.string as NSString
        var segments: [Segment] = []
        var mentions: [Mention] = []
        var links: [String] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let part = (attributes[partKey] as? NSNumber)?.intValue ?? 0
            let run = string.substring(with: range)
            if let guid = attributes[fileTransferKey] as? String {
                // Each attachment occupies one placeholder character carrying its transfer GUID.
                segments.append(.attachment(guid: guid, part: part))
                let remainder = run.replacingOccurrences(of: String(objectReplacement), with: "")
                if !remainder.isEmpty { segments.append(.text(remainder, part: part)) }
                return
            }
            let visible = run.replacingOccurrences(of: String(objectReplacement), with: "")
            if !visible.isEmpty {
                if case .text(let previous, let previousPart)? = segments.last, previousPart == part {
                    segments[segments.count - 1] = .text(previous + visible, part: part)
                } else {
                    segments.append(.text(visible, part: part))
                }
            }
            if let handle = attributes[mentionKey] as? String {
                mentions.append(Mention(handle: handle, text: visible))
            }
            if let link = attributes[linkKey] {
                let value = (link as? URL)?.absoluteString ?? (link as? String) ?? String(describing: link)
                if !links.contains(value) { links.append(value) }
            }
        }
        return MessageBody(segments: segments, mentions: mentions, links: links, source: .attributedBody)
    }

    /// Extracts the first NSString payload from a typedstream when the archiver refuses it.
    /// The payload follows the class name as `+` then a length (one byte, or 0x81 and a
    /// little-endian UInt16, or 0x82 and a UInt32) and UTF-8 bytes.
    static func recoverText(fromTypedStream data: Data) -> String? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress, raw.count > 0 else { return nil }
            let bytes = raw.bindMemory(to: UInt8.self)
            // The string is the first object in the archive, as NSString or NSMutableString.
            let markers: [StaticString] = ["NSString", "NSMutableString"]
            var first: (start: Int, length: Int)?
            for marker in markers {
                let length = marker.utf8CodeUnitCount
                guard let found = memmem(base, raw.count, marker.utf8Start, length) else { continue }
                let start = base.distance(to: found)
                if first == nil || start < first!.start { first = (start, length) }
            }
            guard let first else { return nil }
            var index = first.start + first.length
            // Skip class version and type bytes up to the "+" that introduces the characters.
            let limit = min(bytes.count, index + 16)
            while index < limit, bytes[index] != 0x2B { index += 1 }
            guard index < bytes.count, bytes[index] == 0x2B else { return nil }
            index += 1
            guard index < bytes.count else { return nil }
            var length = 0
            switch bytes[index] {
            case 0x81:
                guard index + 2 < bytes.count else { return nil }
                length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8
                index += 3
            case 0x82:
                guard index + 4 < bytes.count else { return nil }
                length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]) << 16 | Int(bytes[index + 4]) << 24
                index += 5
            default:
                length = Int(bytes[index])
                index += 1
            }
            guard length > 0, index + length <= bytes.count,
                let text = String(bytes: UnsafeBufferPointer(rebasing: bytes[index..<(index + length)]), encoding: .utf8)
            else { return nil }
            let cleaned = text.contains(objectReplacement) ? text.replacingOccurrences(of: String(objectReplacement), with: "") : text
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
