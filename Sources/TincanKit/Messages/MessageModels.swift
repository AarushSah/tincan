import Foundation

/// The transport a message or conversation used.
public enum MessageService: String, Sendable, Codable, CaseIterable {
    case iMessage = "imessage"
    case sms
    case rcs
    case satellite = "satellite_sms"
    case other

    public init(databaseValue: String?) {
        switch databaseValue?.lowercased() {
        case "imessage", "imessagelite": self = .iMessage
        case "sms": self = .sms
        case "rcs": self = .rcs
        case "satellitesms": self = .satellite
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .iMessage: return "iMessage"
        case .sms: return "SMS"
        case .rcs: return "RCS"
        case .satellite: return "Satellite"
        case .other: return "Messages"
        }
    }

}

/// How one message in a conversation went: its service and direction, without its content.
public struct ServiceUse: Sendable, Equatable {
    public let service: MessageService
    public let isFromMe: Bool
    public let date: Date

    public init(service: MessageService, isFromMe: Bool, date: Date) {
        self.service = service
        self.isFromMe = isFromMe
        self.date = date
    }
}

/// A phone number, email address or business id that Messages exchanges messages with.
public struct Handle: Sendable, Hashable, Codable {
    /// `handle.ROWID`. One address can have several rows, one per service.
    public let rowID: Int64
    /// The address as Messages stores it: E.164, email, short code or business id.
    public let address: String
    public let service: MessageService

    public init(rowID: Int64, address: String, service: MessageService) {
        self.rowID = rowID
        self.address = address
        self.service = service
    }
}

/// A Messages conversation (one row of the `chat` table).
public struct Chat: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case direct
        case group
    }

    /// `chat.ROWID`, shown to people as `chat:<id>`.
    public let id: Int64
    public let guid: String
    public let kind: Kind
    public let service: MessageService
    /// The group name someone set, if any.
    public let displayName: String?
    /// `chat.chat_identifier`: the other address for a direct chat, a group id otherwise.
    public let identifier: String
    /// Participant addresses other than you, in database order.
    public let participants: [String]
    public let isArchived: Bool
    /// Messages files it under Unknown Senders or Junk.
    public let isFiltered: Bool
    /// Whether you send read receipts in this chat, when set per chat.
    public let sendsReadReceipts: Bool?

    public init(
        id: Int64, guid: String, kind: Kind, service: MessageService, displayName: String?, identifier: String,
        participants: [String], isArchived: Bool, isFiltered: Bool, sendsReadReceipts: Bool?
    ) {
        self.id = id
        self.guid = guid
        self.kind = kind
        self.service = service
        self.displayName = displayName
        self.identifier = identifier
        self.participants = participants
        self.isArchived = isArchived
        self.isFiltered = isFiltered
        self.sendsReadReceipts = sendsReadReceipts
    }

    public var reference: String { "chat:\(id)" }
}

/// A conversation reference as people and configs write it: `chat:42`, `Chat:42`,
/// ` chat:any;-;+14155550142 ` or a bare GUID. Every command parses references the same way.
public enum ChatReference: Equatable, Sendable {
    case id(Int64)
    case guid(String)

    /// Parses `text`, or returns nil when it is empty. `requirePrefix` refuses bare values.
    public static func parse(_ text: String, requirePrefix: Bool = false) -> ChatReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPrefix = trimmed.lowercased().hasPrefix("chat:")
        if requirePrefix && !hasPrefix { return nil }
        let value = (hasPrefix ? String(trimmed.dropFirst(5)) : trimmed).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if let id = Int64(value) { return .id(id) }
        return .guid(value)
    }

    /// Whether `chat` is the conversation this refers to.
    public func matches(_ chat: Chat) -> Bool {
        switch self {
        case .id(let id): return chat.id == id
        case .guid(let guid): return chat.guid == guid
        }
    }
}

/// What a message row represents, beyond ordinary text and attachments.
public enum MessageKind: String, Sendable, Codable {
    /// Text and/or attachments someone sent.
    case message
    /// A rich link preview.
    case link
    /// An iMessage app bubble: games, Apple Cash, Find My, polls, stickers from apps.
    case app
    /// A voice message.
    case audio
    /// A group change: someone joined, left, renamed the group or changed its photo.
    case event
}

public struct Attachment: Sendable, Hashable, Codable {
    public let guid: String
    /// The name the sender gave the file.
    public let name: String?
    public let mimeType: String?
    public let uti: String?
    public let bytes: Int64
    /// Path on this Mac, when the file has been downloaded.
    public let path: String?
    public let isSticker: Bool
    /// Genmoji and other inline emoji images.
    public let isEmojiImage: Bool
    /// Apple's short description for emoji images and stickers.
    public let summary: String?

    public init(
        guid: String, name: String?, mimeType: String?, uti: String?, bytes: Int64, path: String?, isSticker: Bool, isEmojiImage: Bool, summary: String?
    ) {
        self.guid = guid
        self.name = name
        self.mimeType = mimeType
        self.uti = uti
        self.bytes = bytes
        self.path = path
        self.isSticker = isSticker
        self.isEmojiImage = isEmojiImage
        self.summary = summary
    }

    /// A coarse type for display: image, video, audio, pdf, contact, file.
    public var category: String {
        let mime = mimeType ?? ""
        if isEmojiImage { return "genmoji" }
        if isSticker { return "sticker" }
        if mime.hasPrefix("image/") { return "image" }
        if mime.hasPrefix("video/") { return "video" }
        if mime.hasPrefix("audio/") { return "audio" }
        if mime == "application/pdf" { return "pdf" }
        if mime == "text/vcard" || mime == "text/x-vcard" { return "contact" }
        if (uti ?? "").hasPrefix("dyn.") { return "app_data" }
        return "file"
    }
}

/// A tapback or emoji reaction on a message.
public struct Reaction: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case love, like, dislike, laugh, emphasize, question, emoji, sticker
    }

    public let kind: Kind
    /// The emoji for `.emoji` reactions.
    public let emoji: String?
    /// The reactor's address, or nil for you.
    public let from: String?
    public let at: Date
    /// Message part the reaction targets (multi-part messages).
    public let part: Int

    public init(kind: Kind, emoji: String?, from: String?, at: Date, part: Int) {
        self.kind = kind
        self.emoji = emoji
        self.from = from
        self.at = at
        self.part = part
    }

    public var symbol: String {
        switch kind {
        case .love: return "❤️"
        case .like: return "👍"
        case .dislike: return "👎"
        case .laugh: return "😂"
        case .emphasize: return "‼️"
        case .question: return "❓"
        case .emoji: return emoji ?? "🙂"
        case .sticker: return "🏷️"
        }
    }

    public var verb: String {
        switch kind {
        case .love: return "Loved"
        case .like: return "Liked"
        case .dislike: return "Disliked"
        case .laugh: return "Laughed at"
        case .emphasize: return "Emphasized"
        case .question: return "Questioned"
        case .emoji: return "Reacted \(emoji ?? "")"
        case .sticker: return "Stuck a sticker on"
        }
    }
}

/// A group change recorded in a conversation.
public struct ConversationEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case joined, left, added, removed, renamed
        case photoChanged = "photo_changed"
        case other
    }

    public let kind: Kind
    /// The address the change applies to, when it names someone else.
    public let subject: String?
    /// The new group name for `.renamed`.
    public let title: String?

    public init(kind: Kind, subject: String?, title: String?) {
        self.kind = kind
        self.subject = subject
        self.title = title
    }
}

/// One message, with reactions folded onto it and its body decoded.
public struct Message: Sendable, Identifiable {
    /// `message.ROWID`, shown as `m:<id>`.
    public let id: Int64
    public let guid: String
    public let chatID: Int64?
    public let date: Date
    public let isFromMe: Bool
    /// Sender address for messages from other people. Nil for your own messages.
    public let sender: String?
    public let service: MessageService
    public let kind: MessageKind
    public let body: MessageBody
    public var attachments: [Attachment]
    public var reactions: [Reaction]
    /// GUID of the message this replies to, for inline replies.
    public let replyToGUID: String?
    /// Id of the message this replies to, when tincan may read it.
    public var replyToID: Int64?
    /// A bounded preview of a readable parent. Missing, excluded and deleted parents
    /// supply no preview; their GUID remains available on the reply itself.
    public var replyToPreview: ReplyPreview?

    public struct ReplyPreview: Sendable {
        public let text: String
        public let truncated: Bool

        init(text: String) {
            self.text = String(text.prefix(160))
            truncated = text.count > 160
        }
    }
    public let isEdited: Bool
    /// Parts of the message that were unsent; the whole message when the body is gone.
    public let unsentParts: [Int]
    public let isUnsent: Bool
    public let event: ConversationEvent?
    /// The app's name for `.app` messages. Link messages carry the link in their text.
    public let appName: String?
    public let subject: String?
    public let expressiveEffect: String?
    /// Delivery facts for your own messages.
    public let deliveredAt: Date?
    public let readAt: Date?
    public let isSent: Bool
    public let errorCode: Int
    /// For messages from others: whether you have read it.
    public let isRead: Bool
    /// One of yours that tincan sent and Messages confirmed, by the send ledger.
    public var sentByTincan = false

    public init(
        id: Int64, guid: String, chatID: Int64?, date: Date, isFromMe: Bool, sender: String?, service: MessageService,
        kind: MessageKind, body: MessageBody, attachments: [Attachment], reactions: [Reaction], replyToGUID: String?,
        isEdited: Bool, unsentParts: [Int], isUnsent: Bool, event: ConversationEvent?, appName: String?, subject: String?,
        expressiveEffect: String?, deliveredAt: Date?, readAt: Date?, isSent: Bool, errorCode: Int, isRead: Bool
    ) {
        self.id = id
        self.guid = guid
        self.chatID = chatID
        self.date = date
        self.isFromMe = isFromMe
        self.sender = sender
        self.service = service
        self.kind = kind
        self.body = body
        self.attachments = attachments
        self.reactions = reactions
        self.replyToGUID = replyToGUID
        self.isEdited = isEdited
        self.unsentParts = unsentParts
        self.isUnsent = isUnsent
        self.event = event
        self.appName = appName
        self.subject = subject
        self.expressiveEffect = expressiveEffect
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.isSent = isSent
        self.errorCode = errorCode
        self.isRead = isRead
    }

    public var reference: String { "m:\(id)" }
    /// `m:<id>` of the message this replies to, when tincan may read it.
    public var replyToReference: String? { replyToID.map { "m:\($0)" } }
    public var text: String { body.text }
    public var failed: Bool { isFromMe && errorCode != 0 }
}
