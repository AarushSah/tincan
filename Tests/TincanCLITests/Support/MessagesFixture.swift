// Copied from Tests/TincanKitTests/Support so the CLI tests build the same fixtures; test
// targets can't import each other. Keep the two copies in step.

import Foundation

@testable import TincanKit

/// Builds a temporary `chat.db` with Apple's schema and rows that look like the ones
/// Messages writes, then opens it with `MessagesDatabase` exactly as tincan does.
///
///     let fixture = try MessagesFixture()
///     let maya = try fixture.addHandle("+14155550142")
///     let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
///     let hello = try fixture.addMessage("Hello", in: chat, from: .handle(maya), at: .minute(1))
///     try fixture.addReaction(.love, to: hello, in: chat, from: .me, at: .minute(2))
///     let messages = try fixture.open().messages(inChats: [chat])
///
/// `MessagesDatabase` caches handles and participants, so add every row before `open()`.
/// Addresses and names are invented; fixtures never contain anyone's real data.
final class MessagesFixture {
    enum Sender {
        /// Someone else, by `handle.ROWID`. `.handle(0)` is a row with no handle.
        case handle(Int64)
        /// You, with `handle_id` 0 (typical for group chats).
        case me
        /// You, with `handle_id` naming the recipient, as Messages records one-to-one sends.
        case meTo(Int64)
    }

    enum Tapback: Int {
        case love = 2000
        case like, dislike, laugh, emphasize, question, emoji, sticker
    }

    enum ChatStyle: Int {
        case group = 43
        case direct = 45
    }

    /// A message row: its `ROWID` (tincan's `m:<id>`) and its GUID (what reactions target).
    struct Row {
        let rowID: Int64
        let guid: String
    }

    /// Every `message` column a test may want to set. `addMessage` fills the common ones;
    /// its `configure` closure sets the rest.
    struct MessageColumns {
        var guid: String
        var text: String?
        /// Store `text` only in the `text` column, as older macOS versions did, instead of
        /// in `attributedBody` as current ones do.
        var textColumnOnly = false
        var attributedBody: Data?
        var handleID: Int64 = 0
        var isFromMe = false
        var date: Date
        var service = "iMessage"
        var account: String?
        var destinationCallerID: String?
        var isRead = true
        var isFinished = true
        var isSent: Bool?
        var isDelivered = false
        var dateRead: Date?
        var dateDelivered: Date?
        var error = 0
        var itemType = 0
        var groupActionType = 0
        var otherHandle: Int64 = 0
        var groupTitle: String?
        var associatedType = 0
        var associatedGUID: String?
        var associatedEmoji: String?
        var balloonBundleID: String?
        var isAudioMessage = false
        var threadOriginatorGUID: String?
        var replyToGUID: String?
        /// Stored as a binary property list, like Messages does (`ep` edited parts, `rp`
        /// retracted parts).
        var summaryInfo: [String: Any]?
        var dateEdited: Date?
        var dateRetracted: Date?
        var subject: String?
        var expressiveSendStyleID: String?
    }

    let database: FixtureDatabase
    var path: String { database.path }
    private var nextGUID = 1
    private var textByGUID: [String: String] = [:]

    /// A fixture with the current schema, or with `omitting` columns removed to imitate an
    /// older macOS release (keys are table names).
    init(omitting: [String: [String]] = [:]) throws {
        database = try FixtureDatabase(fileName: "chat.db", schema: Schemas.messagesTables + Schemas.messagesIndexes)
        for (table, columns) in omitting.sorted(by: { $0.key < $1.key }) {
            try database.dropColumns(columns, from: table)
        }
    }

    /// Opens the fixture read-only through tincan's own reader.
    func open(excluding excludedChatIDs: Set<Int64> = []) throws -> MessagesDatabase {
        try MessagesDatabase(path: path, excludedChatIDs: excludedChatIDs)
    }

    // MARK: Handles and chats

    @discardableResult
    func addHandle(_ address: String, service: String = "iMessage") throws -> Int64 {
        try database.insert(
            into: "handle",
            [
                "id": .text(address),
                "service": .text(service),
                "uncanonicalized_id": .text(address),
            ])
    }

    /// Adds a chat. `guid` follows Messages' `service;-;address` form for one-to-one chats
    /// and `service;+;chatNNN` for groups; the style and identifier are derived from it
    /// unless given.
    @discardableResult
    func addChat(
        _ guid: String,
        style: ChatStyle? = nil,
        service: String = "iMessage",
        displayName: String? = nil,
        participants: [Int64] = [],
        isFiltered: Bool = false,
        isArchived: Bool = false,
        properties: [String: Any]? = nil
    ) throws -> Int64 {
        let components = guid.components(separatedBy: ";")
        let resolvedStyle = style ?? (components.count == 3 && components[1] == "+" ? .group : .direct)
        var values: [String: SQLiteValue] = [
            "guid": .text(guid),
            "style": .integer(Int64(resolvedStyle.rawValue)),
            "chat_identifier": .text(components.last ?? guid),
            "service_name": .text(service),
            "is_filtered": .integer(isFiltered ? 1 : 0),
            "is_archived": .integer(isArchived ? 1 : 0),
        ]
        if let displayName { values["display_name"] = .text(displayName) }
        if resolvedStyle == .group { values["room_name"] = .text(components.last ?? guid) }
        if let properties {
            values["properties"] = .blob(try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0))
        }
        let chatID = try database.insert(into: "chat", values)
        for handle in participants {
            try database.insert(into: "chat_handle_join", ["chat_id": .integer(chatID), "handle_id": .integer(handle)])
        }
        return chatID
    }

    // MARK: Messages

    /// Adds a message to `chat` (or to no chat when nil). Text goes into `attributedBody`
    /// as an `NSArchiver` typedstream, the way current macOS stores it.
    @discardableResult
    func addMessage(
        _ text: String?,
        in chat: Int64?,
        from sender: Sender,
        at date: Date,
        configure: (inout MessageColumns) -> Void = { _ in }
    ) throws -> Row {
        var columns = MessageColumns(guid: makeGUID(), text: text, date: date)
        switch sender {
        case .handle(let handle): columns.handleID = handle
        case .me: columns.isFromMe = true
        case .meTo(let handle):
            columns.isFromMe = true
            columns.handleID = handle
        }
        configure(&columns)
        return try insert(columns, chat: chat)
    }

    /// Adds a tapback or emoji reaction targeting part `part` of `target` (`p:N/GUID`), or
    /// the whole balloon (`bp:GUID`) when `balloon` is true.
    @discardableResult
    func addReaction(
        _ tapback: Tapback,
        to target: Row,
        in chat: Int64,
        from sender: Sender,
        at date: Date,
        part: Int = 0,
        balloon: Bool = false,
        emoji: String? = nil
    ) throws -> Row {
        try reaction(type: tapback.rawValue, to: target, in: chat, from: sender, at: date, part: part, balloon: balloon, emoji: emoji)
    }

    /// Adds the row Messages writes when someone takes a reaction back (type + 1000).
    @discardableResult
    func removeReaction(
        _ tapback: Tapback,
        from target: Row,
        in chat: Int64,
        by sender: Sender,
        at date: Date,
        part: Int = 0,
        emoji: String? = nil
    ) throws -> Row {
        try reaction(type: tapback.rawValue + 1000, to: target, in: chat, from: sender, at: date, part: part, balloon: false, emoji: emoji)
    }

    /// Adds an attachment to `message`. `filename` is the on-disk path Messages records;
    /// pass a path inside `database.directory` to simulate a downloaded file.
    @discardableResult
    func addAttachment(
        to message: Row,
        name: String?,
        mimeType: String?,
        uti: String? = nil,
        bytes: Int64 = 0,
        filename: String? = nil,
        guid: String? = nil,
        isSticker: Bool = false,
        emojiImageContentIdentifier: String? = nil,
        emojiImageShortDescription: String? = nil,
        hidden: Bool = false
    ) throws -> String {
        let guid = guid ?? "AT-\(makeGUID())"
        var values: [String: SQLiteValue] = [
            "guid": .text(guid),
            "original_guid": .text(guid),
            "total_bytes": .integer(bytes),
            "is_sticker": .integer(isSticker ? 1 : 0),
            "hide_attachment": .integer(hidden ? 1 : 0),
            "transfer_state": .integer(5),
        ]
        values["transfer_name"] = name.map { .text($0) }
        values["mime_type"] = mimeType.map { .text($0) }
        values["uti"] = uti.map { .text($0) }
        values["filename"] = filename.map { .text($0) }
        values["emoji_image_content_identifier"] = emojiImageContentIdentifier.map { .text($0) }
        values["emoji_image_short_description"] = emojiImageShortDescription.map { .text($0) }
        let attachmentID = try database.insert(into: "attachment", values)
        try database.insert(into: "message_attachment_join", ["message_id": .integer(message.rowID), "attachment_id": .integer(attachmentID)])
        return guid
    }

    /// Moves `message` to Recently Deleted the way Messages does: its link to `chat` moves
    /// from `chat_message_join` to `chat_recoverable_message_join`. With `keepFiled` the old
    /// link stays as well, as in a database caught halfway through the move.
    func moveToRecentlyDeleted(_ message: Row, from chat: Int64, at date: Date, keepFiled: Bool = false) throws {
        try database.insert(
            into: "chat_recoverable_message_join",
            [
                "chat_id": .integer(chat),
                "message_id": .integer(message.rowID),
                "delete_date": .integer(Self.nanoseconds(date)),
            ])
        if !keepFiled {
            try database.execute("DELETE FROM chat_message_join WHERE chat_id = \(chat) AND message_id = \(message.rowID)")
        }
    }

    // MARK: Internals

    private func reaction(
        type: Int, to target: Row, in chat: Int64, from sender: Sender, at date: Date, part: Int, balloon: Bool, emoji: String?
    ) throws -> Row {
        // Messages also writes a readable fallback such as `Loved “Hello”` for old clients.
        let quoted = textByGUID[target.guid].map { "“\($0)”" } ?? "a message"
        return try addMessage("Reacted to \(quoted)", in: chat, from: sender, at: date) {
            $0.textColumnOnly = true
            $0.associatedType = type
            $0.associatedGUID = balloon ? "bp:\(target.guid)" : "p:\(part)/\(target.guid)"
            $0.associatedEmoji = emoji
        }
    }

    private func makeGUID() -> String {
        defer { nextGUID += 1 }
        let serial = String(nextGUID)
        return "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - serial.count) + serial
    }

    private func insert(_ columns: MessageColumns, chat: Int64?) throws -> Row {
        var values: [String: SQLiteValue] = [
            "guid": .text(columns.guid),
            "handle_id": .integer(columns.handleID),
            "is_from_me": .integer(columns.isFromMe ? 1 : 0),
            "date": .integer(Self.nanoseconds(columns.date)),
            "service": .text(columns.service),
            "is_read": .integer(columns.isRead ? 1 : 0),
            "is_finished": .integer(columns.isFinished ? 1 : 0),
            "is_sent": .integer((columns.isSent ?? columns.isFromMe) ? 1 : 0),
            "is_delivered": .integer(columns.isDelivered ? 1 : 0),
            "date_read": .integer(columns.dateRead.map(Self.nanoseconds) ?? 0),
            "date_delivered": .integer(columns.dateDelivered.map(Self.nanoseconds) ?? 0),
            "date_edited": .integer(columns.dateEdited.map(Self.nanoseconds) ?? 0),
            "date_retracted": .integer(columns.dateRetracted.map(Self.nanoseconds) ?? 0),
            "error": .integer(Int64(columns.error)),
            "item_type": .integer(Int64(columns.itemType)),
            "group_action_type": .integer(Int64(columns.groupActionType)),
            "other_handle": .integer(columns.otherHandle),
            "associated_message_type": .integer(Int64(columns.associatedType)),
            "is_audio_message": .integer(columns.isAudioMessage ? 1 : 0),
        ]
        if let text = columns.text {
            textByGUID[columns.guid] = text
            if columns.textColumnOnly {
                values["text"] = .text(text)
            } else {
                values["attributedBody"] = .blob(AttributedBodyFixture.plain(text))
            }
        }
        if let body = columns.attributedBody { values["attributedBody"] = .blob(body) }
        let optionalText: [String: String?] = [
            "account": columns.account,
            "destination_caller_id": columns.destinationCallerID,
            "group_title": columns.groupTitle,
            "associated_message_guid": columns.associatedGUID,
            "associated_message_emoji": columns.associatedEmoji,
            "balloon_bundle_id": columns.balloonBundleID,
            "thread_originator_guid": columns.threadOriginatorGUID,
            "reply_to_guid": columns.replyToGUID,
            "subject": columns.subject,
            "expressive_send_style_id": columns.expressiveSendStyleID,
        ]
        for case (let column, let value?) in optionalText { values[column] = .text(value) }
        if let summaryInfo = columns.summaryInfo {
            values["message_summary_info"] = .blob(try PropertyListSerialization.data(fromPropertyList: summaryInfo, format: .binary, options: 0))
        }
        let rowID = try database.insert(into: "message", values)
        if let chat {
            try database.insert(
                into: "chat_message_join",
                [
                    "chat_id": .integer(chat),
                    "message_id": .integer(rowID),
                    "message_date": .integer(Self.nanoseconds(columns.date)),
                ])
        }
        return Row(rowID: rowID, guid: columns.guid)
    }

    /// Nanoseconds since 2001-01-01, as current macOS stores message dates.
    static func nanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
    }
}
